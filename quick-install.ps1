# quick-install.ps1 - one-line installer for Excel Coach.
#
#   In PowerShell, run:
#     irm https://raw.githubusercontent.com/jonahkazam-svg/excel-coach/main/quick-install.ps1 | iex
#
# Per-user, no admin. It pulls the latest version from the repo's main branch (so it does not
# depend on a published Release), installs the WebView2 runtime + ffmpeg if missing, asks for YOUR
# OpenAI API key (stored only in a local .env), creates a Desktop + Start-menu shortcut, and
# launches the coach. Re-running it updates the app while preserving your key and progress.
$ErrorActionPreference = 'Stop'
$Owner = 'jonahkazam-svg'
$Repo  = 'excel-coach'
$Test  = [bool]$env:XC_QI_TEST
$InstallDir = if($Test){ Join-Path $env:TEMP 'xc_qi_install' } else { Join-Path $env:LOCALAPPDATA 'ExcelCoach' }
$ZipUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/main.zip"

Write-Host ""
Write-Host "=== Excel Coach installer ==="
Write-Host ("Installing to: " + $InstallDir)
Write-Host ""
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$tmp = Join-Path $env:TEMP ('xc_qi_' + ([guid]::NewGuid().ToString('N')))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  # --- download + extract the latest code ---
  Write-Host "Downloading the latest version..."
  $zip = Join-Path $tmp 'app.zip'
  Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 600
  $stage = Join-Path $tmp 'stage'
  Expand-Archive -Path $zip -DestinationPath $stage -Force
  $src = $stage
  $entries = @(Get-ChildItem -LiteralPath $stage -Force)
  if($entries.Count -eq 1 -and $entries[0].PSIsContainer){ $src = $entries[0].FullName }

  # --- copy in, preserving the user's key + data on re-install ---
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
  $existingData = Join-Path $InstallDir 'data'
  foreach($item in @(Get-ChildItem -LiteralPath $src -Force)){
    if($item.Name -eq '.env'){ continue }   # never overwrite the user's API key
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

  if(-not $Test){
    # --- prerequisites (WebView2 runtime + ffmpeg for audio); no admin needed ---
    try { . (Join-Path $InstallDir 'tools\prereqs.ps1') } catch {}
    try { . (Join-Path $InstallDir 'tools\setup.ps1') }   catch {}
    try { if(Get-Command Install-WebView2Runtime -ErrorAction SilentlyContinue){ Write-Host "Checking WebView2 runtime..."; Install-WebView2Runtime | Out-Null } } catch {}
    try { if(Get-Command Install-Ffmpeg -ErrorAction SilentlyContinue){ Write-Host "Checking ffmpeg (for the voice/listening features)..."; Install-Ffmpeg (Join-Path $InstallDir 'bin') | Out-Null } } catch {}

    # --- first-run: enter YOUR OpenAI API key (this console can prompt) ---
    try {
      if((Get-Command Test-FirstRun -ErrorAction SilentlyContinue) -and (Test-FirstRun)){
        if(Get-Command Invoke-Setup -ErrorAction SilentlyContinue){ Invoke-Setup | Out-Null }
      }
    } catch {}
  }

  # --- shortcuts (Desktop + Start menu) ---
  $launcher = Join-Path $InstallDir 'tools\Launch-Coach.ps1'
  $psExe    = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $targets  = if($Test){ @($InstallDir) } else { @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Programs')) }
  foreach($dir in $targets){
    try {
      $lnkPath = Join-Path $dir 'Excel Coach.lnk'
      $wsh = New-Object -ComObject WScript.Shell
      $sc  = $wsh.CreateShortcut($lnkPath)
      $sc.TargetPath       = $psExe
      $sc.Arguments        = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '"'
      $sc.WorkingDirectory = $InstallDir
      $sc.Description      = 'Excel Coach - live study coach'
      $sc.Save()
    } catch { Write-Host ("Could not create a shortcut in " + $dir + ": " + $_.Exception.Message) }
  }
  if(-not $Test){ Write-Host "Shortcut created on your Desktop: Excel Coach" }

  if(-not $Test){
    Write-Host ""
    Write-Host "=== Installed. Starting Excel Coach... ==="
    Start-Process -FilePath $psExe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$launcher+'"')) -WorkingDirectory $InstallDir
  } else {
    Write-Host "TEST MODE: skipped prereqs/key/launch."
  }
}
finally {
  if($tmp -and (Test-Path -LiteralPath $tmp)){ try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {} }
}
