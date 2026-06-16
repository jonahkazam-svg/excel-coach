# install.ps1 - one-line web installer for Excel Coach.
#
#   Run it with:
#     irm https://raw.githubusercontent.com/jonahkazam-svg/excel-coach/main/install.ps1 | iex
#
# What it does (no admin required - installs per-user):
#   1. Reads the latest release manifest from GitHub Releases.
#   2. Downloads the release bundle and verifies its SHA-256 before touching disk.
#   3. Extracts it to %LOCALAPPDATA%\ExcelCoach, preserving any existing .env / data.
#   4. Installs the WebView2 runtime and ffmpeg if missing.
#   5. Runs first-run setup so you enter YOUR OWN OpenAI API key (stored only locally).
#   6. Creates a Start-menu shortcut and launches the coach.
#
# ASCII only. Windows PowerShell 5.1. Self-contained: relies on nothing already
# installed (it dot-sources the helper modules only AFTER extracting them).

$ErrorActionPreference = 'Stop'

$Owner       = 'jonahkazam-svg'
$Repo        = 'excel-coach'
$InstallDir  = Join-Path $env:LOCALAPPDATA 'ExcelCoach'
$ManifestUrl = "https://github.com/$Owner/$Repo/releases/latest/download/latest.json"

Write-Host ""
Write-Host "=== Excel Coach installer ==="
Write-Host ("Installing to: " + $InstallDir)
Write-Host ""

# Modern TLS so the GitHub download works on older PowerShell defaults.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$tmp = Join-Path $env:TEMP ('xc_install_' + ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

try {
  # --- 1. Manifest --------------------------------------------------------
  Write-Host "Checking for the latest release..."
  $m = Invoke-RestMethod -Uri $ManifestUrl -UseBasicParsing -TimeoutSec 30
  $url = [string]$m.url
  $sha = ([string]$m.sha256).Trim()
  $ver = [string]$m.version
  if(-not $url){ throw "Release manifest has no download url." }
  if($sha.Length -ne 64){ throw "Release manifest has no valid sha256." }
  Write-Host ("Latest version: " + $ver)

  # --- 2. Download + verify ----------------------------------------------
  $zip = Join-Path $tmp 'app.zip'
  Write-Host "Downloading..."
  Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
  $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
  if($actual.ToLower() -ne $sha.ToLower()){
    throw ("Checksum mismatch - refusing to install. expected " + $sha.ToLower() + " got " + $actual.ToLower())
  }
  Write-Host "Checksum verified."

  # --- 3. Extract + copy (preserving user state) -------------------------
  $stage = Join-Path $tmp 'stage'
  Expand-Archive -Path $zip -DestinationPath $stage -Force
  $src = $stage
  $entries = @(Get-ChildItem -LiteralPath $stage -Force)
  if($entries.Count -eq 1 -and $entries[0].PSIsContainer){ $src = $entries[0].FullName }

  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $existingData = Join-Path $InstallDir 'data'
  foreach($item in @(Get-ChildItem -LiteralPath $src -Force)){
    # Never overwrite the user's API key.
    if($item.Name -eq '.env'){ continue }
    # For data\, only add files that do not already exist (keep their scope, deck,
    # review history, progress) so a reinstall does not wipe their state.
    if($item.Name -eq 'data' -and (Test-Path -LiteralPath $existingData)){
      foreach($df in @(Get-ChildItem -LiteralPath $item.FullName -Force)){
        $dst = Join-Path $existingData $df.Name
        if(-not (Test-Path -LiteralPath $dst)){ Copy-Item -LiteralPath $df.FullName -Destination $dst -Recurse -Force }
      }
      continue
    }
    Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $InstallDir $item.Name) -Recurse -Force
  }
  Write-Host "Files installed."

  # --- 4. Prerequisites (use the just-installed helpers) -----------------
  try { . (Join-Path $InstallDir 'tools\prereqs.ps1') } catch {}
  try { . (Join-Path $InstallDir 'tools\setup.ps1') }   catch {}
  try { if(Get-Command Install-WebView2Runtime -ErrorAction SilentlyContinue){ Install-WebView2Runtime | Out-Null } } catch {}
  try { if(Get-Command Install-Ffmpeg -ErrorAction SilentlyContinue){ Install-Ffmpeg (Join-Path $InstallDir 'bin') | Out-Null } } catch {}

  # --- 5. First-run setup (this console can prompt) ----------------------
  try {
    if((Get-Command Test-FirstRun -ErrorAction SilentlyContinue) -and (Test-FirstRun)){
      if(Get-Command Invoke-Setup -ErrorAction SilentlyContinue){ Invoke-Setup | Out-Null }
    }
  } catch {}

  # --- 6. Shortcut + launch ----------------------------------------------
  $launcher = Join-Path $InstallDir 'Start-Coach.ps1'
  $psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  try {
    $programs = [Environment]::GetFolderPath('Programs')
    $lnkPath  = Join-Path $programs 'Excel Coach.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $sc  = $wsh.CreateShortcut($lnkPath)
    $sc.TargetPath       = $psExe
    $sc.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
    $sc.WorkingDirectory = $InstallDir
    $sc.Description      = 'Excel Coach - live study coach'
    $sc.Save()
    Write-Host "Start-menu shortcut created: Excel Coach"
  } catch {
    Write-Host ("Could not create the shortcut: " + $_.Exception.Message)
  }

  Write-Host ""
  Write-Host "=== Installed. Starting Excel Coach... ==="
  Start-Process -FilePath $psExe `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$launcher+'"')) `
    -WorkingDirectory $InstallDir
}
finally {
  if($tmp -and (Test-Path -LiteralPath $tmp)){ try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}
