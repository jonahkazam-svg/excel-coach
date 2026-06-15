# setup.ps1 - first-run "bring your own API key" setup for distributed excel-coach.
#   Each end user supplies their OWN OpenAI API key. We prompt for it, validate it with a
#   cheap real API call, ask for the microphone device, and write the repo-root .env
#   (UTF-8, no BOM), preserving any existing keys. The key is stored ONLY in the local
#   .env and never transmitted anywhere except the OpenAI validation call.
#
# ASCII-only, PowerShell 5.1 compatible. Safe to dot-source: only function definitions
# run at import. watch.ps1 dot-sources this alongside curriculum.ps1.
#
# .env lives at the repo root (parent of tools/), KEY=value lines - same format/location
# watch.ps1 reads via its Read-EnvVal helper.

# Resolve the repo-root .env path the same way watch.ps1 does ($Vault\.env), but relative
# to this script so it works wherever the app is installed. $PSScriptRoot is the tools/
# folder; its parent is the repo root.
function Get-SetupEnvPath {
  $toolsDir=$PSScriptRoot
  if(-not $toolsDir){ $toolsDir=Split-Path -Parent $MyInvocation.MyCommand.Path }
  $repoRoot=Split-Path -Parent $toolsDir
  return (Join-Path $repoRoot ".env")
}

# Read one KEY=value line from the .env at $path. Mirrors watch.ps1's Read-EnvVal:
#   $l=Get-Content $EnvFile | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1
#   if($l){ ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { $default }
# Same anchor, same strip+trim+unquote, but takes an explicit path (watch.ps1 closes over
# its $EnvFile). Returns $default when the file or key is absent.
function Read-SetupEnvVal($path,$name,$default){
  if(-not (Test-Path $path)){ return $default }
  $l=Get-Content $path | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1
  if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default }
}

# True if first-run setup is needed: .env missing OR has no non-empty OPENAI_API_KEY
# (a placeholder like REPLACE_ME counts as missing, matching watch.ps1's
# "$sync.key -like '*REPLACE_ME*'" guard).
function Test-FirstRun {
  $envPath=Get-SetupEnvPath
  if(-not (Test-Path $envPath)){ return $true }
  $key=Read-SetupEnvVal $envPath "OPENAI_API_KEY" ""
  if(-not $key){ return $true }
  if($key -like '*REPLACE_ME*'){ return $true }
  return $false
}

# Validate an OpenAI API key with a cheap real call: GET /v1/models with a Bearer header,
# using the same curl.exe style watch.ps1 uses for its API calls. Returns $true if the key
# is accepted (HTTP 2xx), $false otherwise. Never throws.
function Test-OpenAIKey($key){
  if(-not $key){ return $false }
  if(-not (Get-Command curl.exe -ErrorAction SilentlyContinue)){
    # No curl.exe on this box - cannot validate. Treat as "could not verify" so the caller
    # can offer to save anyway rather than hard-failing a possibly-good key.
    return $null
  }
  $code=$null
  try{
    $code=& curl.exe -s -o NUL -w "%{http_code}" --max-time 30 "https://api.openai.com/v1/models" -H ("Authorization: Bearer "+$key)
  }catch{
    return $false
  }
  $code=([string]$code).Trim()
  if($code -match '^2\d\d$'){ return $true }
  return $false
}

# Atomically write/update the repo-root .env (UTF-8, no BOM), preserving every existing key
# and only setting the ones in $updates (a hashtable name->value). Mirrors watch.ps1's
# write style: [IO.File]::WriteAllText(path, text, (New-Object System.Text.UTF8Encoding($false))).
function Save-SetupEnv($path,$updates){
  $lines=@()
  if(Test-Path $path){ $lines=@(Get-Content $path) }
  $seen=@{}
  $out=New-Object System.Collections.ArrayList
  foreach($line in $lines){
    $replaced=$false
    foreach($name in $updates.Keys){
      if($line -match ("^\s*"+[regex]::Escape($name)+"\s*=")){
        [void]$out.Add($name+"="+[string]$updates[$name])
        $seen[$name]=$true
        $replaced=$true
        break
      }
    }
    if(-not $replaced){ [void]$out.Add($line) }
  }
  foreach($name in $updates.Keys){
    if(-not $seen.ContainsKey($name)){ [void]$out.Add($name+"="+[string]$updates[$name]) }
  }
  $text=($out -join "`r`n")+"`r`n"
  [IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($false)))
}

# Interactive console setup. Prompts for the user's OpenAI API key, validates it with a real
# API call (up to 3 tries, with a "save anyway" escape), prompts for the mic device (with a
# sensible default), then writes the .env preserving existing keys. Returns $true on success.
function Invoke-Setup {
  $envPath=Get-SetupEnvPath
  Write-Host ""
  Write-Host "=== Excel Coach - first-run setup ==="
  Write-Host ""
  Write-Host "Excel Coach uses your OWN OpenAI API key. It is stored only on this PC in:"
  Write-Host ("  "+$envPath)
  Write-Host "and is never sent anywhere except OpenAI. Get a key at https://platform.openai.com/api-keys"
  Write-Host ""

  $key=""
  $keyOk=$false
  for($try=1; $try -le 3; $try++){
    $entered=Read-Host "Paste your OpenAI API key (starts with sk-)"
    if($entered){ $entered=$entered.Trim().Trim('"') }
    if(-not $entered){
      Write-Host "No key entered."
      Write-Host ""
      continue
    }
    Write-Host "Checking the key with OpenAI..."
    $res=Test-OpenAIKey $entered
    if($res -eq $true){
      Write-Host "Key looks good."
      Write-Host ""
      $key=$entered
      $keyOk=$true
      break
    }
    if($null -eq $res){
      # Could not run curl.exe to verify. Let the user keep the key without a network check.
      Write-Host "Could not verify the key (curl.exe not available on this PC)."
      $ans=Read-Host "Save this key without checking it? (y/N)"
      if($ans -and ($ans.Trim().ToLower() -eq "y")){
        $key=$entered
        $keyOk=$true
        break
      }
      Write-Host ""
      continue
    }
    # res -eq $false: the call failed / unauthorized.
    Write-Host "That key looks invalid - OpenAI did not accept it (check for typos or a revoked key)."
    if($try -lt 3){
      Write-Host ("Try again ("+$try+" of 3).")
      Write-Host ""
    } else {
      Write-Host "That was the third attempt."
      $ans=Read-Host "Save this key anyway? (y/N)"
      if($ans -and ($ans.Trim().ToLower() -eq "y")){
        $key=$entered
        $keyOk=$true
      }
    }
  }

  if(-not $keyOk){
    Write-Host ""
    Write-Host "Setup did not complete - no usable API key was saved. You can run setup again any time."
    return $false
  }

  # Mic device. Default to whatever is already in .env, else the same default watch.ps1 uses
  # for MIC_DEVICE.
  $defaultMic=Read-SetupEnvVal $envPath "MIC_DEVICE" "Microphone (Logitech BRIO)"
  if(-not $defaultMic){ $defaultMic="Microphone (Logitech BRIO)" }
  Write-Host ""
  Write-Host "Which microphone should the coach listen through?"
  Write-Host "  This must match the device name Windows shows for your mic."
  $micEntered=Read-Host ("Microphone device name [default: "+$defaultMic+"]")
  if($micEntered){ $micEntered=$micEntered.Trim().Trim('"') }
  $mic=$defaultMic
  if($micEntered){ $mic=$micEntered }

  $updates=@{}
  $updates["OPENAI_API_KEY"]=$key
  $updates["MIC_DEVICE"]=$mic
  try{
    Save-SetupEnv $envPath $updates
  }catch{
    Write-Host ""
    Write-Host ("Could not write .env: "+$_.Exception.Message)
    return $false
  }

  Write-Host ""
  Write-Host "=== Setup complete ==="
  Write-Host ("Saved your settings to "+$envPath)
  Write-Host ("  OPENAI_API_KEY  (your key - kept only on this PC)")
  Write-Host ("  MIC_DEVICE      "+$mic)
  Write-Host ""
  Write-Host "You are ready to go. Launch the coach and start studying."
  return $true
}
