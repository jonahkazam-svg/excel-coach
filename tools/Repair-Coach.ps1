# Repair-Coach.ps1 - force a clean reset when the coach is wedged or won't appear.
# Kills every coach process + its own WebView2 helpers, clears the (possibly locked)
# WebView2 data folder, then relaunches the coach clean. Safe to run anytime.
$tools = $PSScriptRoot
Write-Host "Resetting Excel Coach..."
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\b[^|;]*watch\.ps1' } |
  ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'watch_seg' } |
  ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'xc_wv2_data' } |
  ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
Start-Sleep -Seconds 2
try{ Remove-Item (Join-Path $env:TEMP 'xc_wv2_data') -Recurse -Force -ErrorAction SilentlyContinue }catch{}
Write-Host "Relaunching the coach..."
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',(Join-Path $tools 'watch.ps1') -WorkingDirectory $tools -WindowStyle Hidden
Write-Host "Done - the coach should reappear in a few seconds."
Start-Sleep -Seconds 2
