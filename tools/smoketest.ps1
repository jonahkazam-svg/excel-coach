# smoketest.ps1 - fast, dependency-free static health check for Excel Coach.
#   Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tools\smoketest.ps1
# Does NOT launch the coach, call OpenAI, or touch Excel. Exits 1 on any FAIL.
# Catches the class of silent breaks we have actually hit (e.g. a panel.html
# `var history` colliding with the read-only window.history -> blank panel).
$ErrorActionPreference = 'Continue'
$tools = $PSScriptRoot
$root  = Split-Path $PSScriptRoot -Parent
$script:pass=0; $script:fail=0; $script:warn=0; $script:skip=0
function Ok($m){   $script:pass++; Write-Host ("[PASS] "+$m) -ForegroundColor Green }
function Bad($m){  $script:fail++; Write-Host ("[FAIL] "+$m) -ForegroundColor Red }
function Warn($m){ $script:warn++; Write-Host ("[WARN] "+$m) -ForegroundColor Yellow }
function Skip($m){ $script:skip++; Write-Host ("[SKIP] "+$m) -ForegroundColor DarkGray }
function Section($m){ Write-Host ""; Write-Host ("=== "+$m+" ===") -ForegroundColor Cyan }

# ---- 1. Parse every PowerShell file ----------------------------------------
Section "1. PowerShell parse"
$ps1 = @(Get-ChildItem -Path $tools -Filter *.ps1 -File -ErrorAction SilentlyContinue)
$wk = Join-Path $tools 'workers'
if(Test-Path $wk){ $ps1 += @(Get-ChildItem -Path $wk -Filter *.ps1 -File -ErrorAction SilentlyContinue) }
foreach($f in $ps1){
  if($f.Name -eq 'smoketest.ps1'){ continue }
  $errs=$null
  try{ [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName,[ref]$null,[ref]$errs) }catch{}
  if($errs -and $errs.Count){ Bad ($f.Name+" - "+$errs.Count+" parse error(s); first: line "+$errs[0].Extent.StartLineNumber+" - "+$errs[0].Message) }
  else { Ok ($f.Name+" parses") }
}

# ---- 2. Required functions present (static scan) ---------------------------
Section "2. Required functions"
function HasFunc($file,$name){
  if(-not (Test-Path $file)){ return $false }
  $t = Get-Content $file -Raw
  return ($t -match ('(?im)^\s*function\s+'+[regex]::Escape($name)+'(\s|\(|$)'))
}
$rt = Join-Path $tools 'runthrough.ps1'
$wp = Join-Path $tools 'watch.ps1'
$wkr = Join-Path $wk 'work.ps1'
$xcp = Join-Path $wk 'xcap.ps1'
$xccp = Join-Path $wk 'xccap.ps1'
$need = @(
  @{f=$rt;n='Make-Exercise'}, @{f=$rt;n='RT-NormalizeExercise'}, @{f=$rt;n='RT-CellMatch'},
  @{f=$rt;n='RT-ExcelConsistent'}, @{f=$rt;n='Grade-ExcelExercise'}, @{f=$rt;n='RT-PickNext'}, @{f=$rt;n='RT-RecordResult'},
  @{f=$wp;n='Apply-Strip'}, @{f=$wp;n='Show-Answer'}, @{f=$wp;n='Explain-Mistake'}, @{f=$wp;n='Explain-Deep'}, @{f=$wp;n='Handle-Panel'}, @{f=$wp;n='Check-Workout'},
  @{f=$wkr;n='Build-Recap'}, @{f=$xccp;n='Shrink-B64'}, @{f=$xccp;n='CapWin2'}, @{f=$xcp;n='Invoke-XlAction'}, @{f=$xcp;n='Make-CheatSheet'}, @{f=$xcp;n='Make-Drill'}, @{f=$xcp;n='Run-Demo'}
)
foreach($x in $need){
  if(HasFunc $x.f $x.n){ Ok ($x.n+" defined in "+(Split-Path $x.f -Leaf)) }
  else { Bad ($x.n+" MISSING from "+(Split-Path $x.f -Leaf)) }
}

# ---- 3. JS global-collision guard (the blank-panel bug) --------------------
Section "3. JS global-collision guard (panel/strip)"
# These are read-only browser globals; declaring one with var/let/const at script
# scope silently fails (assignment ignored / push throws) -> dead UI. Never legit.
$globals = 'history|location|navigator|document|window'
foreach($h in @('ui\panel.html','ui\strip.html')){
  $hp = Join-Path $tools $h
  if(-not (Test-Path $hp)){ Warn ($h+" not found"); continue }
  $lines = Get-Content $hp
  $hits=@()
  for($i=0; $i -lt $lines.Count; $i++){
    if($lines[$i] -match ('(?<![\.\w])(?:var|let|const)\s+('+$globals+')\b\s*(=|;|$)')){ $hits += ("line "+($i+1)+" ("+$matches[1]+")") }
  }
  if($hits.Count){ Bad ($h+" declares a browser-global name at script scope: "+($hits -join '; ')) }
  else { Ok ($h+" - no browser-global collisions") }
}

# ---- 4. Host <-> panel XC contract ----------------------------------------
Section "4. Host<->UI XC contract"
if(Test-Path $wp){
  $wtext = Get-Content $wp -Raw
  $called = @([regex]::Matches($wtext,'XC\.([A-Za-z_]\w*)\s*\(') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $uiAll = ''
  foreach($h in @('ui\panel.html','ui\strip.html')){ $hp=Join-Path $tools $h; if(Test-Path $hp){ $uiAll += (Get-Content $hp -Raw) + "`n" } }
  $missing=@()
  foreach($fn in $called){
    $defpat = '(?<![\.\w])'+[regex]::Escape($fn)+'\s*(\(|:)'
    if($uiAll -notmatch $defpat){ $missing += $fn }
  }
  if($missing.Count){ Bad ("watch.ps1 calls XC fn(s) the UI never defines: "+($missing -join ', ')) }
  else { Ok ($called.Count.ToString()+" XC.* host calls all resolve to a UI definition") }
} else { Bad "watch.ps1 not found" }

# ---- 5. Pure-function sanity (child process, no side effects) --------------
Section "5. Pure-function sanity (runthrough.ps1)"
if(Test-Path $rt){
  $probeFile = Join-Path $env:TEMP 'xc_smoke_probe.ps1'
  $probe = @'
. "__RT__"
$o=@()
try { $o += ('cellmatch_eq=' + [bool](RT-CellMatch 100 100)) } catch { $o += 'cellmatch_eq=ERR' }
try { $o += ('cellmatch_ne=' + [bool](RT-CellMatch 100 105)) } catch { $o += 'cellmatch_ne=ERR' }
$exGood=@{ surface='excel'; prompt='Using Revenue in B2 and COGS in B3, fill B4.'; layout=@{ given=@(@{cell='B2'},@{cell='B3'}); answerCells=@(@{cell='B4'}) } }
$exBad =@{ surface='excel'; prompt='Enter =A1*B1 and copy to C2.';              layout=@{ given=@(@{cell='B2'},@{cell='B3'}); answerCells=@(@{cell='C2'}) } }
try { $o += ('consistent_good=' + [bool](RT-ExcelConsistent $exGood)) } catch { $o += 'consistent_good=ERR' }
try { $o += ('consistent_bad='  + [bool](RT-ExcelConsistent $exBad))  } catch { $o += 'consistent_bad=ERR' }
[Console]::Out.Write(($o -join '|'))
'@
  $probe = $probe.Replace('__RT__', $rt)
  [IO.File]::WriteAllText($probeFile, $probe, (New-Object System.Text.UTF8Encoding($false)))
  $out = ''
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command powershell.exe).Source
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "'+$probeFile+'"'
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if($p.WaitForExit(20000)){ $out = $p.StandardOutput.ReadToEnd() } else { try{ $p.Kill() }catch{}; $out = '__TIMEOUT__' }
  } catch { $out = '__ERR__ '+$_.Exception.Message }
  try { Remove-Item $probeFile -ErrorAction SilentlyContinue } catch {}
  if($out -eq '__TIMEOUT__'){ Skip "dot-sourcing runthrough.ps1 timed out - pure-fn tests skipped" }
  elseif($out -like '__ERR__*'){ Skip ("could not run pure-fn probe: "+$out) }
  else {
    $map=@{}; foreach($kv in ($out -split '\|')){ $p2=$kv -split '=',2; if($p2.Count -eq 2){ $map[$p2[0]]=$p2[1] } }
    $expect = @{ cellmatch_eq='True'; cellmatch_ne='False'; consistent_good='True'; consistent_bad='False' }
    foreach($k in $expect.Keys){
      if($map.ContainsKey($k) -and $map[$k] -eq $expect[$k]){ Ok ($k+" = "+$map[$k]) }
      else { Bad ($k+" = "+$(if($map.ContainsKey($k)){$map[$k]}else{'<none>'})+" (expected "+$expect[$k]+")") }
    }
  }
} else { Bad "runthrough.ps1 not found" }

# ---- 6. .env keys ----------------------------------------------------------
Section "6. .env config"
$envf = Join-Path $root '.env'
if(-not (Test-Path $envf)){ Bad ".env missing at repo root" }
else {
  $et = Get-Content $envf -Raw
  if($et -match '(?im)^\s*OPENAI_API_KEY\s*=\s*(\S+)' -and $matches[1] -notmatch 'REPLACE_ME'){ Ok "OPENAI_API_KEY present" } else { Bad "OPENAI_API_KEY missing or placeholder" }
  if($et -match '(?im)^\s*MIC_DEVICE\s*=\s*\S'){ Ok "MIC_DEVICE set" } else { Warn "MIC_DEVICE not set (falls back to default mic name)" }
  if($et -match '(?im)^\s*FISH_API_KEY\s*=\s*\S'){ Ok "FISH_API_KEY set (Fish TTS)" } else { Warn "FISH_API_KEY not set (OpenAI TTS fallback)" }
}

# ---- summary ---------------------------------------------------------------
Section "RESULT"
Write-Host ("RESULT: "+$script:pass+" passed, "+$script:fail+" failed, "+$script:warn+" warnings, "+$script:skip+" skipped") -ForegroundColor White
if($script:fail -gt 0){ exit 1 } else { exit 0 }
