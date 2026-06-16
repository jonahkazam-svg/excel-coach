# updater.ps1 - secure self-update for the distributed excel-coach desktop tool.
# Dot-sourced by watch.ps1 (alongside curriculum.ps1). ASCII-only, PowerShell 5.1.
# SECURITY BOUNDARY: HTTPS only; the SHA-256 in the manifest is MANDATORY and must
# match the downloaded bundle (case-insensitive) BEFORE anything is extracted or
# swapped in; only the single configured release host is trusted. No verified
# checksum => nothing is unpacked or executed. On ANY failure, the install is left
# untouched (download/extract happen in temp; the swap rolls back).

# --- Config -----------------------------------------------------------------
# REPLACE-ME: Jonah sets this to the real GitHub Releases manifest URL, e.g.
# https://github.com/<user>/excel-coach/releases/latest/download/latest.json
# It MUST be https:// and is the ONLY host this updater will ever trust.
$script:XCUpdateManifestUrl = 'https://github.com/jonahkazam-svg/excel-coach/releases/latest/download/latest.json'

# Repo root = parent of tools/. VERSION (single semver line) lives there.
$script:XCUpdateRoot    = Split-Path $PSScriptRoot -Parent
$script:XCVersionFile   = Join-Path $script:XCUpdateRoot "VERSION"
# Files/folders that hold the user's own state and MUST survive an update.
$script:XCUpdatePreserve = @(".env", "data")

# --- Helpers ----------------------------------------------------------------

# A URL is trusted only if it parses as an absolute https:// URL. Anything else
# (http, file, ftp, relative, junk) is rejected - this gates BOTH the manifest
# fetch and the bundle download.
function XC-IsHttpsUrl($url){
  if(-not $url){ return $false }
  $u=$null
  if(-not [Uri]::TryCreate([string]$url,[UriKind]::Absolute,[ref]$u)){ return $false }
  return ($u.Scheme -eq "https")
}

# Read the local version from VERSION; missing/blank => "0.0.0".
function Get-LocalVersion {
  try {
    if(-not (Test-Path $script:XCVersionFile)){ return "0.0.0" }
    $v=(Get-Content $script:XCVersionFile -Raw -ErrorAction Stop)
    if($null -eq $v){ return "0.0.0" }
    $v=([string]$v).Trim()
    if(-not $v){ return "0.0.0" }
    # take the first line only, strip any leading 'v'
    $v=(($v -split "`r?`n")[0]).Trim()
    $v=$v -replace '^[vV]',''
    if(-not $v){ return "0.0.0" }
    return $v
  } catch { return "0.0.0" }
}

# Compare two semver-ish strings by numeric components (split on '.').
# Non-numeric or missing components are treated as 0. Returns 1 if a>b, -1 if
# a<b, 0 if equal. Pre-release/build metadata after '-' or '+' is ignored.
function XC-CompareVersion($a,$b){
  $a=([string]$a).Trim(); $b=([string]$b).Trim()
  $a=($a -split '[-+]')[0]; $b=($b -split '[-+]')[0]
  $pa=$a -split '\.'; $pb=$b -split '\.'
  $len=[Math]::Max($pa.Count,$pb.Count)
  for($i=0;$i -lt $len;$i++){
    $na=0; $nb=0
    if($i -lt $pa.Count){ [void][int]::TryParse(($pa[$i].Trim()),[ref]$na) }
    if($i -lt $pb.Count){ [void][int]::TryParse(($pb[$i].Trim()),[ref]$nb) }
    if($na -gt $nb){ return 1 }
    if($na -lt $nb){ return -1 }
  }
  return 0
}

# --- Public: Check-Update ---------------------------------------------------
# HTTPS GET the manifest, parse {version,url,sha256,notes}, compare to local.
# NEVER throws: any network/parse/validation problem returns updateAvailable=$false
# with an explanatory 'note'.
function Check-Update {
  $current=Get-LocalVersion
  $result=[PSCustomObject]@{
    updateAvailable=$false
    latestVersion=$current
    currentVersion=$current
    url=$null
    sha256=$null
    notes=$null
    note=$null
  }
  try {
    if(-not (XC-IsHttpsUrl $script:XCUpdateManifestUrl)){
      $result.note="Manifest URL is not a valid https URL - refusing to fetch."
      return $result
    }
    $m=$null
    try {
      $m=Invoke-RestMethod -Uri $script:XCUpdateManifestUrl -Method Get -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
    } catch {
      $result.note=("Could not reach update server: "+$_.Exception.Message)
      return $result
    }
    if(-not $m){ $result.note="Empty manifest response."; return $result }

    $latest=$null; if($m.PSObject.Properties['version']){ $latest=[string]$m.version }
    $url=$null;    if($m.PSObject.Properties['url']){ $url=[string]$m.url }
    $sha=$null;    if($m.PSObject.Properties['sha256']){ $sha=[string]$m.sha256 }
    $notes=$null;  if($m.PSObject.Properties['notes']){ $notes=[string]$m.notes }

    if(-not $latest){ $result.note="Manifest missing 'version'."; return $result }
    $result.latestVersion=$latest.Trim()
    $result.url=$url
    $result.sha256=$sha
    $result.notes=$notes

    # The bundle URL must itself be https and the checksum must be present, or we
    # will never be able to apply this update safely - surface that now.
    if(-not (XC-IsHttpsUrl $url)){
      $result.note="Manifest 'url' is not a valid https URL - update will not be offered."
      return $result
    }
    if(-not $sha -or -not (([string]$sha).Trim())){
      $result.note="Manifest missing 'sha256' - update will not be offered."
      return $result
    }

    if((XC-CompareVersion $latest $current) -gt 0){
      $result.updateAvailable=$true
      $result.note=("Update "+$latest.Trim()+" available (current "+$current+").")
    } else {
      $result.note=("Up to date (current "+$current+", latest "+$latest.Trim()+").")
    }
    return $result
  } catch {
    $result.note=("Update check failed: "+$_.Exception.Message)
    return $result
  }
}

# --- Public: Apply-Update ---------------------------------------------------
# Download the bundle to a temp dir, verify SHA-256 against the manifest BEFORE
# extracting, extract to a staging dir, then atomically swap into the install
# dir while preserving .env and data/. Rolls back on any failure so the install
# is never left half-updated. Pass the object returned by Check-Update (or any
# object exposing version/url/sha256). Returns {applied,version,error}.
function Apply-Update($update){
  $version=$null; $url=$null; $sha=$null
  if($update){
    if($update.PSObject.Properties['latestVersion']){ $version=[string]$update.latestVersion }
    if(-not $version -and $update.PSObject.Properties['version']){ $version=[string]$update.version }
    if($update.PSObject.Properties['url']){ $url=[string]$update.url }
    if($update.PSObject.Properties['sha256']){ $sha=[string]$update.sha256 }
  }
  $res=[PSCustomObject]@{ applied=$false; version=$version; error=$null }

  # --- Pre-flight security checks (refuse early, touch nothing) ---
  if(-not (XC-IsHttpsUrl $url)){ $res.error="Refusing update: bundle url is not a valid https URL."; return $res }
  if(-not $sha -or -not (([string]$sha).Trim())){ $res.error="Refusing update: manifest has no sha256."; return $res }
  $expected=(([string]$sha).Trim() -replace '[^0-9A-Fa-f]','')
  if($expected.Length -ne 64){ $res.error="Refusing update: sha256 is not a 64-char hex digest."; return $res }

  $work=$null; $backup=$null
  try {
    # Isolated work area in TEMP - download + extract NEVER happen in the install dir.
    $work=Join-Path $env:TEMP ("xc_update_"+([guid]::NewGuid().ToString("N")))
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zipPath=Join-Path $work "bundle.zip"
    $stage=Join-Path $work "stage"

    # 1. Download the bundle over HTTPS to temp.
    try {
      Invoke-WebRequest -Uri $url -OutFile $zipPath -TimeoutSec 120 -UseBasicParsing -ErrorAction Stop
    } catch {
      $res.error=("Download failed: "+$_.Exception.Message)
      return $res
    }
    if(-not (Test-Path $zipPath)){ $res.error="Download produced no file."; return $res }

    # 2. SECURITY GATE: compute SHA-256 and require an exact (case-insensitive)
    #    match. If it does not match we ABORT here - nothing is ever extracted.
    $actual=$null
    try { $actual=(Get-FileHash -Path $zipPath -Algorithm SHA256 -ErrorAction Stop).Hash } catch {}
    if(-not $actual){ $res.error="Could not hash downloaded bundle."; return $res }
    if($actual.ToUpper() -ne $expected.ToUpper()){
      $res.error=("Checksum MISMATCH - refusing to install. expected "+$expected.ToLower()+" got "+$actual.ToLower())
      return $res
    }

    # 3. Checksum verified -> safe to extract (still in temp, not the install dir).
    try {
      New-Item -ItemType Directory -Force -Path $stage | Out-Null
      Expand-Archive -Path $zipPath -DestinationPath $stage -Force -ErrorAction Stop
    } catch {
      $res.error=("Extraction failed: "+$_.Exception.Message)
      return $res
    }
    # Some zips wrap everything in a single top-level folder; descend into it so
    # we swap the actual payload, not a wrapper directory.
    $src=$stage
    $entries=@(Get-ChildItem -LiteralPath $stage -Force)
    if($entries.Count -eq 1 -and $entries[0].PSIsContainer){ $src=$entries[0].FullName }

    # 4. Atomic-ish swap with rollback. Move the current install's replaceable
    #    files into a backup, copy the new files in, and PRESERVE user state
    #    (.env, data/) by simply never touching them. On any error, restore.
    $install=$script:XCUpdateRoot
    $backup=Join-Path $work "backup"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null

    # Lower-cased set of names we must never overwrite or remove.
    $preserve=@{}
    foreach($p in $script:XCUpdatePreserve){ $preserve[$p.ToLower()]=$true }

    $moved=@()   # @{ name=..; from=..; to=.. } for rollback
    try {
      # 4a. Back up every install item the new bundle will replace (skip preserved).
      foreach($item in @(Get-ChildItem -LiteralPath $install -Force)){
        if($preserve.ContainsKey($item.Name.ToLower())){ continue }
        $dest=Join-Path $backup $item.Name
        Move-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction Stop
        $moved+=@{ name=$item.Name; from=$item.FullName; to=$dest }
      }
      # 4b. Copy new files in (skip preserved names so we never clobber user state
      #     even if the bundle happens to contain them).
      foreach($item in @(Get-ChildItem -LiteralPath $src -Force)){
        if($preserve.ContainsKey($item.Name.ToLower())){ continue }
        $target=Join-Path $install $item.Name
        if($item.PSIsContainer){
          Copy-Item -LiteralPath $item.FullName -Destination $target -Recurse -Force -ErrorAction Stop
        } else {
          Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
        }
      }
    } catch {
      # ROLLBACK: remove anything partially copied, then move the backup back.
      $swapErr=$_.Exception.Message
      try {
        foreach($item in @(Get-ChildItem -LiteralPath $src -Force)){
          if($preserve.ContainsKey($item.Name.ToLower())){ continue }
          $target=Join-Path $install $item.Name
          if(Test-Path -LiteralPath $target){ Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
        }
      } catch {}
      foreach($mv in $moved){
        try {
          if(Test-Path -LiteralPath $mv.from){ Remove-Item -LiteralPath $mv.from -Recurse -Force -ErrorAction SilentlyContinue }
          Move-Item -LiteralPath $mv.to -Destination $mv.from -Force -ErrorAction Stop
        } catch {}
      }
      $res.error=("Update failed during swap; rolled back. "+$swapErr)
      return $res
    }

    $res.applied=$true
    $res.version=$version
    $res.error=$null
    return $res
  } catch {
    $res.error=("Update aborted: "+$_.Exception.Message)
    return $res
  } finally {
    # Clean the temp work area (best-effort). The install dir is never the work dir.
    if($work -and (Test-Path -LiteralPath $work)){
      try { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
  }
}
