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
$ps1s = @('tools\watch.ps1','tools\curriculum.ps1','tools\deck.ps1','tools\practice.ps1','tools\updater.ps1','tools\setup.ps1','tools\build-deck.ps1','tools\runthrough.ps1','tools\perf.ps1')
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
  . (Join-Path $root 'tools\runthrough.ps1')
  . (Join-Path $root 'tools\perf.ps1')
} catch { $loadErr = $_.Exception.Message }
Assert ("all library modules dot-source cleanly" + $(if($loadErr){ " (" + $loadErr + ")" }else{ "" })) ($loadErr -eq '')
$need = @('Get-XlBook','Apply-XlOps','Read-ExcelLive','Get-Curriculum',
         'Build-Deck','Get-Deck','Get-TopicCards',
         'Get-DueCards','Rate-Card','New-Quiz','Get-PracticeStats',
         'Check-Update','Apply-Update','Test-FirstRun','Invoke-Setup',
         'Get-RTState','Get-RTTopics','RT-LoadState','RT-SaveState',
         'Record-Answer','Get-PerfSummary','Get-WeakTopics','Perf-Load','Perf-Save')
foreach($f in $need){ Assert ("function defined: " + $f) ([bool](Get-Command $f -ErrorAction SilentlyContinue)) }
# Get-XlBook must be null-safe (the binding fix)
if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ Assert "Get-XlBook(null) returns null" ((Get-XlBook $null) -eq $null) }

# ---------------------------------------------------------------------------
Section "Run-through (state model + coverage)"
if(Get-Command Get-RTTopics -ErrorAction SilentlyContinue){
  $rtT = @(Get-RTTopics); $cur = @(Get-Curriculum)
  Assert ("covers every curriculum topic (" + $rtT.Count + " == " + $cur.Count + ")") (($rtT.Count -eq $cur.Count) -and ($cur.Count -gt 0))
  Assert "fresh topic record: level 1, streak 0" (((RT-NewTopicRec).level -eq 1) -and ((RT-NewTopicRec).streak -eq 0))
  $sp = RT-StatePath; $bak = $null
  if(Test-Path $sp){ $bak = [IO.File]::ReadAllText($sp) }
  try {
    $st = RT-NewState; $st.topics['TEST-99'] = @{ level=3; streak=1; attempts=4; correct=3; mastered=@(1,2); lastSeen='x' }
    RT-SaveState $st
    $ld = RT-LoadState
    Assert "state round-trips (saved topic returns)" ($ld.topics.ContainsKey('TEST-99'))
    Assert "round-tripped record keeps level 3" ([int]((RT-TopicRec $ld 'TEST-99').level) -eq 3)
  } finally {
    if($null -ne $bak){ [IO.File]::WriteAllText($sp,$bak,(New-Object System.Text.UTF8Encoding($false))) } elseif(Test-Path $sp){ Remove-Item $sp -Force }
  }
} else { Assert "Get-RTTopics defined" $false }

# ---------------------------------------------------------------------------
Section "Performance memory (record right/wrong per topic)"
if(Get-Command Record-Answer -ErrorAction SilentlyContinue){
  $pp = Perf-StatePath; $pbak = $null
  if(Test-Path $pp){ $pbak = [IO.File]::ReadAllText($pp) }
  try {
    if(Test-Path $pp){ Remove-Item $pp -Force }
    Record-Answer 'PERF-TEST' 'Perf Test Topic' $true  | Out-Null
    Record-Answer 'PERF-TEST' 'Perf Test Topic' $true  | Out-Null
    Record-Answer 'PERF-TEST' 'Perf Test Topic' $false | Out-Null
    $ld = Perf-Load
    Assert "perf attempts counted" ([int]$ld.topics['PERF-TEST'].attempts -eq 3)
    Assert "perf correct counted"  ([int]$ld.topics['PERF-TEST'].correct -eq 2)
    Assert "perf wrong counted"    ([int]$ld.topics['PERF-TEST'].wrong -eq 1)
    $sm = Get-PerfSummary
    Assert "perf summary totals"   ([int]$sm.totalAttempts -ge 3)
    Assert "perf pct in 0..100"    ([int]$sm.pct -ge 0 -and [int]$sm.pct -le 100)
    # a struggling topic (1/3) should be flagged as weak
    Record-Answer 'PERF-WEAK' 'Weak Topic' $false | Out-Null
    Record-Answer 'PERF-WEAK' 'Weak Topic' $false | Out-Null
    Record-Answer 'PERF-WEAK' 'Weak Topic' $true  | Out-Null
    Assert "weak topic surfaced" (@(Get-WeakTopics 5) -contains 'PERF-WEAK')
  } finally {
    if($null -ne $pbak){ [IO.File]::WriteAllText($pp,$pbak,(New-Object System.Text.UTF8Encoding($false))) } elseif(Test-Path $pp){ Remove-Item $pp -Force }
  }
} else { Assert "Record-Answer defined" $false }

# ---------------------------------------------------------------------------
Section "Run-through Excel"
# Pure-logic checks of the exercise engine - NO API, NO Excel.
if(Get-Command RT-NormalizeExercise -ErrorAction SilentlyContinue){
  # excel exercise object (hand-built; no choices)
  $xObj = @{
    topicId='cf-1'; level=2; surface='excel'; prompt='Compute EBIT.'; answer=''; worked='EBIT = Rev - COGS - OpEx';
    layout=@{ title='EBIT drill'; given=@(@{label='Revenue';value=1000;cell='B2'},@{label='COGS';value=400;cell='B3'},@{label='OpEx';value=200;cell='B4'}); answerCells=@(@{label='EBIT';cell='B6';expected=400}) }
  }
  $xn = RT-NormalizeExercise $xObj 'cf-1' 2
  Assert "excel: surface in {pill,excel}" (($xn.surface -eq 'excel') -or ($xn.surface -eq 'pill'))
  Assert "excel: surface is excel" ($xn.surface -eq 'excel')
  Assert "excel: id non-empty" ([bool]([string]$xn.id))
  Assert "excel: prompt present" ([bool]([string]$xn.prompt))
  Assert "excel: choices is array" ($xn.choices -is [array])
  Assert "excel: layout.given is array" ($xn.layout.given -is [array])
  Assert "excel: layout.answerCells is array" ($xn.layout.answerCells -is [array])

  # pill exercise object (hand-built; multiple choice)
  $pObj = @{
    topicId='def-1'; level=1; surface='pill'; prompt='Which is a current asset?'; answer='Accounts receivable';
    choices=@('Accounts receivable','Goodwill','Long-term debt','Common stock'); worked='AR is collected within a year.'
  }
  $pn = RT-NormalizeExercise $pObj 'def-1' 1
  Assert "pill: choices is array" ($pn.choices -is [array])
  Assert "pill: choices non-empty" (@($pn.choices).Count -gt 0)
  Assert "pill: id non-empty" ([bool]([string]$pn.id))

  # RT-CellMatch tolerance
  Assert "cellmatch: (20, 20.0) -> true"   (RT-CellMatch 20 20.0)
  Assert "cellmatch: (20, 25) -> false"    (-not (RT-CellMatch 20 25))
  Assert "cellmatch: (100, 100.4) -> true" (RT-CellMatch 100 100.4)
  Assert "cellmatch: ('abc', 5) -> false"  (-not (RT-CellMatch 'abc' 5))
} else { Assert "RT-NormalizeExercise defined" $false }

# ---------------------------------------------------------------------------
Section "Run-through controller"
# Pure-logic checks of the Phase A controller library - NO API, NO Excel.
# Any test that writes data/runthrough-state.json backs it up first and restores
# it in a finally block (mirrors the Run-through state-model section above).
if(Get-Command Grade-PillExercise -ErrorAction SilentlyContinue){
  # A1: Grade-PillExercise
  $mcEx = @{ choices=@('Accounts receivable','Goodwill','Long-term debt','Common stock'); answer=0; worked='AR is collected within a year.' }
  Assert "grade: MC correct index -> correct"   ((Grade-PillExercise $mcEx 0).correct)
  Assert "grade: MC wrong index -> not correct" (-not (Grade-PillExercise $mcEx 2).correct)
  $numEx = @{ choices=@(); answer='20'; worked='20.0' }
  Assert "grade: numeric 20 vs 20.0 -> correct" ((Grade-PillExercise $numEx 20.0).correct)
  $ftEx = @{ choices=@(); answer='it is an operating cash flow'; worked='free text' }
  Assert "grade: free text -> not correct (deferred)" (-not (Grade-PillExercise $ftEx 'it is an operating cash flow').correct)

  # A2 + A3 + A4 need a curriculum; guard on it and back up the RT state file.
  if((Get-Command RT-RecordResult -ErrorAction SilentlyContinue) -and (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    $cur = @(Get-Curriculum)
    $sp = RT-StatePath; $bak = $null
    if(Test-Path $sp){ $bak = [IO.File]::ReadAllText($sp) }
    try {
      $tid = 'RT-CTRL-TEST'
      # Start from a clean record for the test topic.
      $st = RT-LoadState; if($st.topics.ContainsKey($tid)){ $st.topics.Remove($tid) }; RT-SaveState $st
      $r1 = RT-RecordResult $tid 1 $true $false
      $r2 = RT-RecordResult $tid 1 $true $false
      Assert "record: two correct -> becameSolid"  ([bool]$r2.becameSolid)
      Assert "record: two correct -> level 2"       ([int]$r2.rec.level -eq 2)
      Assert "record: solid resets streak to 0"     ([int]$r2.rec.streak -eq 0)
      $lvlBefore = [int]$r2.rec.level
      $r3 = RT-RecordResult $tid 2 $true $true
      Assert "record: retry-correct -> not becameSolid" (-not $r3.becameSolid)
      Assert "record: retry-correct -> level unchanged" ([int]$r3.rec.level -eq $lvlBefore)
      $attBefore = [int]$r3.rec.attempts
      $r4 = RT-RecordResult $tid 1 $false $false
      Assert "record: wrong -> streak 0"            ([int]$r4.rec.streak -eq 0)
      Assert "record: wrong -> attempts incremented" ([int]$r4.rec.attempts -eq ($attBefore + 1))

      # A3: RT-PickNext on a fresh seeded state.
      $fresh = RT-NewState
      $pk = RT-PickNext $fresh 0 ''
      $curIds = @($cur | ForEach-Object { [string]$_.id })
      Assert "pick: topicId exists in curriculum" ($curIds -contains $pk.topicId)
      Assert "pick: level is 1 for first item"    ([int]$pk.level -eq 1)
      $pk2 = RT-PickNext $fresh 0 $pk.topicId
      Assert "pick: does not repeat lastTopicId"  ($pk2.topicId -ne $pk.topicId)

      # A4: Get-RTProgress.
      $prog = Get-RTProgress
      Assert "progress: total == curriculum count" ([int]$prog.total -eq $cur.Count)
      Assert "progress: solid in 0..total"         ([int]$prog.solid -ge 0 -and [int]$prog.solid -le [int]$prog.total)
      Assert "progress: areas array non-empty"     (@($prog.areas).Count -gt 0)
    } finally {
      if($null -ne $bak){ [IO.File]::WriteAllText($sp,$bak,(New-Object System.Text.UTF8Encoding($false))) } elseif(Test-Path $sp){ Remove-Item $sp -Force }
    }
  } else { Assert "RT-RecordResult + Get-Curriculum defined" $false }
} else { Assert "Grade-PillExercise defined" $false }

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
