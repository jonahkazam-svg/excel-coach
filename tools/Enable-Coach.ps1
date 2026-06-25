# Enable-Coach.ps1 - ONE-TIME setup. Windows Defender periodically false-flags the
# coach's background worker (it watches the screen + mic, which looks "spyware-like" to
# Defender's heuristics) and blocks it from running - so Assist / typed questions / the
# hands-on Excel builder stop working, while the rest of the coach keeps going.
# This adds the coach folders to Defender's exclusion list (the documented fix), which
# lets the worker run. Requires administrator approval (a UAC prompt).
$ErrorActionPreference = 'Stop'

# --- self-elevate (re-launch as admin if we are not already) ---
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
  Write-Host "Asking for administrator approval (you'll see a Windows prompt)..." -ForegroundColor Cyan
  try { Start-Process powershell -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"') } catch { Write-Host "Elevation was declined - cannot add the exclusion without admin." -ForegroundColor Yellow; Start-Sleep 4 }
  return
}

# --- add both coach folders to Defender exclusions ---
$v2root  = Split-Path $PSScriptRoot -Parent          # ...\Excel coach v2
$desktop = Split-Path $v2root -Parent                # ...\Desktop
$folders = @($v2root, (Join-Path $desktop 'Excel coach transfer')) | Where-Object { Test-Path $_ } | Select-Object -Unique
Write-Host ""
foreach ($f in $folders) {
  try { Add-MpPreference -ExclusionPath $f -ErrorAction Stop; Write-Host ("  [OK]  excluded  " + $f) -ForegroundColor Green }
  catch { Write-Host ("  [!!]  could not exclude " + $f + " - " + $_.Exception.Message) -ForegroundColor Yellow }
}

# --- relaunch the coach (v2) clean ---
Write-Host ""
Write-Host "Restarting the coach so the worker picks up..." -ForegroundColor Cyan
try {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\b[^|;]*watch\.ps1' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'watch_seg' } | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  Start-Sleep -Seconds 2
} catch {}
$tools = $PSScriptRoot
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','watch.ps1' -WorkingDirectory $tools -WindowStyle Hidden

Write-Host ""
Write-Host "Done. The coach should reappear at the bottom of your screen in a few seconds." -ForegroundColor Green
Write-Host "Test it: open the bar, type a question, hit Assist - if it answers, you're set for the demo." -ForegroundColor Green
Start-Sleep -Seconds 6
