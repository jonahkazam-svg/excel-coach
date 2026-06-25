# Launch-Coach.ps1 - ROBUST launcher. Guarantees the coach starts every time on this PC.
# The single-instance mutex makes a 2nd launch quietly exit - great for avoiding double
# bars, but if a previous instance is stuck, zombied, or broken it still holds the mutex,
# so a fresh click would silently do nothing. This launcher fixes that: it force-clears any
# existing coach + its leftover helpers FIRST (which frees the mutex), waits until they're
# truly gone, then starts a clean instance. A click always ends in a running coach.
$ErrorActionPreference = 'Continue'
$tools = $PSScriptRoot
$root  = Split-Path $tools -Parent
$log   = Join-Path $env:TEMP 'xc_launch.log'
function L($m){ try{ [IO.File]::AppendAllText($log, ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')+'  '+$m+"`r`n"), (New-Object System.Text.UTF8Encoding($false))) }catch{} }
L ("launch requested: " + $root)

# 1) Kill any existing coach (watch.ps1) + its ffmpeg segmenter + its orphaned WebView2.
#    NOTE: this script is Launch-Coach.ps1 - it does NOT match 'coach v4\\tools\\watch\.ps1', so it won't
#    kill itself.
$killed = 0
try{ foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'coach v4\\tools\\watch\.ps1' })){ try{ Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue; $killed++ }catch{} } }catch{}
try{ foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'watch_seg' })){ try{ Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }catch{} } }catch{}
try{ foreach($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'xc4_wv2' })){ try{ Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }catch{} } }catch{}
L ("cleared $killed existing watch.ps1 instance(s)")

# 2) Wait until the old watch.ps1 is really gone (so the named mutex is released before the
#    new instance checks it). Poll up to ~4s, then a small settle.
for($i=0; $i -lt 20; $i++){
  $n = 0; try{ $n = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'coach v4\\tools\\watch\.ps1' }).Count }catch{}
  if($n -eq 0){ break }
  Start-Sleep -Milliseconds 200
}
Start-Sleep -Milliseconds 500

# 2b) Clear the coach's WebView2 user-data folder. A prior session that was killed (rather
#     than closed cleanly) can leave a stale Chromium lock here, which makes the new
#     WebView2 init stall or never paint - i.e. a bar that "won't start." Best-effort: if a
#     stray webview still holds it, we just proceed with the existing folder.
$wv2 = Join-Path $env:TEMP 'xc4_wv2_data'
if(Test-Path $wv2){ try{ Remove-Item $wv2 -Recurse -Force -ErrorAction Stop; L "cleared xc4_wv2_data (fresh WebView2 init)" }catch{ L ("could not clear xc4_wv2_data (still in use) - " + $_.Exception.Message) } }

# 3) Start a fresh hidden instance.
$watch = Join-Path $tools 'watch.ps1'
if(-not (Test-Path $watch)){ L ("ERROR: watch.ps1 not found at " + $watch); return }
try{
  Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$watch+'"') -WorkingDirectory $root -WindowStyle Hidden
  L "started watch.ps1"
}catch{
  L ("ERROR: could not start watch.ps1 - " + $_.Exception.Message)
}
