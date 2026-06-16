# Start-Coach.ps1 - the launcher the Start-menu shortcut points at.
# Runs on every launch. Responsibilities, in order:
#   1. Make sure the prerequisites are present (WebView2 runtime + ffmpeg).
#   2. First-run safety net: if there is no API key yet, run setup in a visible
#      window (normally setup already happened during install.ps1).
#   3. Silently check GitHub Releases for a newer version and apply it.
#   4. Launch the hidden live coach (tools\watch.ps1).
#
# ASCII only. Windows PowerShell 5.1. The shortcut launches this HIDDEN, so the
# common path (key present, no update) is completely silent. The only time a
# window appears is the first-run-recovery setup pass.

param([switch]$Setup)

$ErrorActionPreference = 'Continue'

# This script lives at the install root; tools\ is beside it.
$Root  = $PSScriptRoot
if(-not $Root){ $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Tools = Join-Path $Root 'tools'

# Load the helper modules (best-effort; each is independent).
try { . (Join-Path $Tools 'prereqs.ps1') } catch {}
try { . (Join-Path $Tools 'setup.ps1') }   catch {}
try { . (Join-Path $Tools 'updater.ps1') } catch {}

# --- 1. Prerequisites -------------------------------------------------------
# Both are no-ops when already present, so this is cheap on a normal launch.
try { if(Get-Command Install-WebView2Runtime -ErrorAction SilentlyContinue){ Install-WebView2Runtime | Out-Null } } catch {}
try { if(Get-Command Install-Ffmpeg -ErrorAction SilentlyContinue){ Install-Ffmpeg (Join-Path $Root 'bin') | Out-Null } } catch {}

# --- 2. First-run / key check ----------------------------------------------
$needsSetup = $false
try { if(Get-Command Test-FirstRun -ErrorAction SilentlyContinue){ $needsSetup = [bool](Test-FirstRun) } } catch {}

if($needsSetup -and -not $Setup){
  # We may be running hidden (no console to type into). Relaunch ourselves in a
  # visible window with -Setup so the user can enter their key, then stop here -
  # that visible instance will launch the coach when it finishes.
  try {
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$PSCommandPath+'"'),'-Setup') `
      -Wait
  } catch {}
  return
}

if($Setup -and $needsSetup){
  try { if(Get-Command Invoke-Setup -ErrorAction SilentlyContinue){ Invoke-Setup | Out-Null } } catch {}
  # Re-check: if the user bailed out of setup, do not launch a keyless coach.
  try { if(Get-Command Test-FirstRun -ErrorAction SilentlyContinue){ $needsSetup = [bool](Test-FirstRun) } } catch {}
  if($needsSetup){
    Write-Host "Setup was not completed - no API key saved. Run the shortcut again when ready."
    return
  }
}

# --- 3. Silent self-update --------------------------------------------------
# The user opted into updates by installing; apply newer versions quietly.
try {
  if(Get-Command Check-Update -ErrorAction SilentlyContinue){
    $u = Check-Update
    if($u -and $u.updateAvailable){
      if($Setup){ Write-Host ("Updating to "+$u.latestVersion+"...") }
      if(Get-Command Apply-Update -ErrorAction SilentlyContinue){ Apply-Update $u | Out-Null }
    }
  }
} catch {}

# --- 4. Launch the hidden coach ---------------------------------------------
$watch = Join-Path $Tools 'watch.ps1'
if(Test-Path $watch){
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$watch+'"')) `
    -WorkingDirectory $Root
} else {
  Write-Host "Could not find tools\watch.ps1 - the install looks incomplete."
}
