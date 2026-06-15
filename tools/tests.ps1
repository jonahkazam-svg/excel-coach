# tests.ps1 - assurance suite for excel-coach.
# Pure-logic checks: no Excel, no microphone, no API calls, no user needed.
# Run: powershell -NoProfile -ExecutionPolicy Bypass -File tools\tests.ps1
# Exit code 0 = all pass; 1 = something regressed. The loop runs this each
# iteration so a broken build path/route/parse is caught the moment it happens.

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$script:pass = 0; $script:fail = 0; $script:fails = @()
function Assert($name, $cond){
  if($cond){ $script:pass++; Write-Host ("  PASS  " + $name) -ForegroundColor DarkGreen }
  else { $script:fail++; $script:fails += $name; Write-Host ("  FAIL  " + $name) -ForegroundColor Red }
}
function Section($t){ Write-Host ""; Write-Host ("== " + $t + " ==") -ForegroundColor Cyan }

# ---------------------------------------------------------------------------
Section "Parse + ASCII gate (every PowerShell file)"
$ps1s = @('tools\watch.ps1','tools\curriculum.ps1','tools\deck.ps1','tools\practice.ps1','tools\updater.ps1','tools\setup.ps1','tools\build-deck.ps1')
foreach($rel in $ps1s){
  $fp = Join-Path $root $rel
  if(-not (Test-Path $fp)){ Assert ("exists: " + $rel) $false; continue }
  $src = [IO.File]::ReadAllText($fp)
  $bad = 0; for($i=0;$i -lt $src.Length;$i++){ if([int]$src[$i] -gt 127){ $bad++ } }
  $e = $null; [void][System.Management.Automation.PSParser]::Tokenize($src, [ref]$e)
  Assert ("ascii-only: " + $rel) ($bad -eq 0)
  Assert ("parses:     " + $rel) ($e.Count -eq 0)
  if($rel -eq 'tools\watch.ps1'){
    foreach($nm in @('work','xlWork','ttsWork')){
      $rx = [regex]("(?s)\$" + $nm + "=@'\r?\n(.*?)\r?\n'@")
      $mm = $rx.Match($src)
      if($mm.Success){ $ie = $null; [void][System.Management.Automation.PSParser]::Tokenize($mm.Groups[1].Value, [ref]$ie); Assert ("parses here-string `$" + $nm) ($ie.Count -eq 0) }
      else { Assert ("here-string `$" + $nm + " present") $false }
    }
  }
}

# ---------------------------------------------------------------------------
Section "Exercise routing (the real regexes from watch.ps1)"
# Pull the actual demo + drill intent regexes out of the live source and test
# them - so if anyone narrows them and breaks 'build an exercise', this fails.
$wsrc = [IO.File]::ReadAllText((Join-Path $root 'tools\watch.ps1'))
function Extract-Rx($src, $marker){
  foreach($line in ($src -split "`n")){
    if($line.Contains($marker)){
      $mm = [regex]::Match($line, "-match '([^']*)'")
      if($mm.Success){ return $mm.Groups[1].Value }
    }
  }
  return $null
}
$demoRx  = Extract-Rx $wsrc 'teach me|show me how|demonstrate'
$drillRx = Extract-Rx $wsrc 'similar (exercise|problem|question)'
Assert "demo regex found in source"  ($demoRx -ne $null)
Assert "drill regex found in source" ($drillRx -ne $null)
function Routes-Build($p){ if(-not $demoRx -or -not $drillRx){ return $false }; return (($p -match $demoRx) -or ($p -match $drillRx)) }
# These MUST build an exercise:
$buildPhrases = @(
  'generate me a demo workout from the excel sheet i have open',
  'make me a practice exercise and walk me through it',
  'walk me through one',
  'build me a drill',
  'give me a practice problem',
  'show me how to build a cash flow statement',
  'make me a workout'
)
foreach($p in $buildPhrases){ Assert ("builds:   '" + $p + "'") (Routes-Build $p) }
# These MUST stay questions (not hijacked into a build):
$questionPhrases = @(
  'explain this workout to me',
  'what is the next step on this workout',
  'why is net income in operating activities',
  'how do i calculate the change in AR',
  'what does CFO mean'
)
foreach($p in $questionPhrases){ Assert ("question: '" + $p + "'") (-not (Routes-Build $p)) }

# ---------------------------------------------------------------------------
Section "Modules load + key functions defined"
# Dot-source the LIBRARY modules (never watch.ps1 - it launches the coach) and
# confirm the functions the build paths depend on exist.
$loadErr = ''
try {
  . (Join-Path $root 'tools\curriculum.ps1')
  . (Join-Path $root 'tools\deck.ps1')
  . (Join-Path $root 'tools\practice.ps1')
  . (Join-Path $root 'tools\updater.ps1')
  . (Join-Path $root 'tools\setup.ps1')
} catch { $loadErr = $_.Exception.Message }
Assert ("all library modules dot-source cleanly" + $(if($loadErr){ " (" + $loadErr + ")" }else{ "" })) ($loadErr -eq '')
$need = @('Get-XlBook','Apply-XlOps','Read-ExcelLive','Get-Curriculum',
         'Build-Deck','Get-Deck','Get-TopicCards',
         'Get-DueCards','Rate-Card','New-Quiz','Get-PracticeStats',
         'Check-Update','Apply-Update','Test-FirstRun','Invoke-Setup')
foreach($f in $need){ Assert ("function defined: " + $f) ([bool](Get-Command $f -ErrorAction SilentlyContinue)) }
# Get-XlBook must be null-safe (the binding fix)
if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ Assert "Get-XlBook(null) returns null" ((Get-XlBook $null) -eq $null) }

# ---------------------------------------------------------------------------
Section "UI files (ASCII + present)"
foreach($rel in @('tools\ui\strip.html','tools\ui\panel.html')){
  $fp = Join-Path $root $rel
  if(-not (Test-Path $fp)){ Assert ("exists: " + $rel) $false; continue }
  $h = [IO.File]::ReadAllText($fp)
  $bad = 0; for($i=0;$i -lt $h.Length;$i++){ if([int]$h[$i] -gt 127){ $bad++ } }
  Assert ("ascii-only: " + $rel) ($bad -eq 0)
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host ("RESULT: " + $script:pass + " passed, " + $script:fail + " failed") -ForegroundColor $(if($script:fail -eq 0){'Green'}else{'Red'})
if($script:fail -gt 0){ Write-Host "FAILURES:"; foreach($f in $script:fails){ Write-Host ("  - " + $f) } ; exit 1 }
exit 0
