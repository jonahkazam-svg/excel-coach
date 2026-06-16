# runthrough.ps1 - the adaptive run-through mastery drill: state model + per-topic
# mastery tracker (Phase 1, Task 1). Controller / generator / grader land in later
# tasks. Dot-sourced by watch.ps1. State lives in <repo>/data/runthrough-state.json.
# ASCII-only, PowerShell 5.1.

function RT-StatePath {
  $root = Split-Path $PSScriptRoot -Parent
  $dir = Join-Path $root 'data'
  if(-not (Test-Path $dir)){ try{ New-Item -ItemType Directory -Force -Path $dir | Out-Null }catch{} }
  return (Join-Path $dir 'runthrough-state.json')
}
function RT-NewState { return @{ topics = @{}; updatedAt = '' } }
function RT-NewTopicRec { return @{ level = 1; streak = 0; attempts = 0; correct = 0; mastered = @(); lastSeen = '' } }

function RT-LoadState {
  $p = RT-StatePath
  if(-not (Test-Path $p)){ return (RT-NewState) }
  try {
    $raw = [IO.File]::ReadAllText($p)
    if(-not $raw -or $raw.Trim().Length -lt 2){ return (RT-NewState) }
    $o = $raw | ConvertFrom-Json
    $st = RT-NewState
    if($o.topics){ foreach($prop in $o.topics.PSObject.Properties){ $st.topics[$prop.Name] = $prop.Value } }
    if($o.updatedAt){ $st.updatedAt = [string]$o.updatedAt }
    return $st
  } catch { return (RT-NewState) }
}

function RT-SaveState($state){
  if(-not $state){ return }
  try {
    $state.updatedAt = (Get-Date).ToString('o')
    $json = $state | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((RT-StatePath), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

function Get-RTState { return (RT-LoadState) }

# Normalize a per-topic record from state (JSON gives PSCustomObject; new gives hashtable).
function RT-TopicRec($state,$topicId){
  $topicId = [string]$topicId
  $rec = RT-NewTopicRec
  if($state -and $state.topics -and $state.topics.ContainsKey($topicId)){
    $r = $state.topics[$topicId]
    foreach($k in @('level','streak','attempts','correct','mastered','lastSeen')){
      $v = $null; try{ $v = $r.$k }catch{}
      if($null -ne $v){ $rec[$k] = $v }
    }
    if($null -eq $rec.mastered){ $rec.mastered = @() }
  }
  return $rec
}

# --- Exercise engine (Tasks 2/8/9/10): unified exercise object is
#   @{ id; topicId; level; surface; prompt; answer; choices; worked; layout }
#   surface='pill' (definition/classification) or 'excel' (calculation, with
#   layout.given + layout.answerCells). Make-Exercise hits the network and is NOT
#   tested; the rest are pure/COM and defensive. ---

# Read OPENAI_API_KEY and DECK_MODEL from <repo>/.env (own helper so it works
# standalone and when dot-sourced alongside watch.ps1/deck.ps1).
function RT-ReadEnv($name,$default){
  $envp = Join-Path (Split-Path $PSScriptRoot -Parent) '.env'
  if(-not (Test-Path $envp)){ return $default }
  try {
    $l = Get-Content $envp | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1
    if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default }
  } catch { return $default }
}

# AI generator. For a CALCULATION topic ask for surface='excel' with a deterministic
# layout (given inputs in real cells, each answer cell's expected computable from
# them); for a definition/classification topic ask for surface='pill' with choices.
# Matches deck.ps1's curl/Bearer/temp-file pattern + gpt-4o-mini. Returns the
# normalized hashtable or $null on any failure. NOT exercised by tests (network).
function Make-Exercise($topicId,$level){
  $topicId = [string]$topicId
  $lvl = 1; try{ $lvl = [int]$level }catch{ $lvl = 1 }
  $key = RT-ReadEnv 'OPENAI_API_KEY' ''
  if(-not $key -or $key -like '*REPLACE_ME*'){ return $null }
  $model = RT-ReadEnv 'DECK_MODEL' 'gpt-4o-mini'
  # Resolve the topic name/category/tier for context.
  $tName = $topicId; $tCat = ''; $tTier = ''
  if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    $cp = Join-Path $PSScriptRoot 'curriculum.ps1'
    if(Test-Path $cp){ try{ . $cp }catch{} }
  }
  if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){
    try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq $topicId){ $tName=[string]$t.topic; $tCat=[string]$t.domain; $tTier=[string]$t.tier; break } } }catch{}
  }
  $sys = @'
You generate ONE exercise for a finance student prepping for an investment-banking fellowship. You are given a curriculum topic (id, category, name) and a difficulty level (1=atom, 2=step, 3=section, 4=whole). Decide whether the topic is best drilled as a CALCULATION (the student computes numbers in Excel) or as a DEFINITION/CLASSIFICATION (the student picks or types an answer).

Output ONLY a JSON object (no prose, no markdown, no code fences) with these fields:
  "id"      - a short slug like "rt-<topicId>-<level>-<n>". May be omitted.
  "topicId" - echo the given topic id.
  "level"   - echo the given level (integer).
  "surface" - "excel" for a calculation, "pill" for a definition/classification.
  "prompt"  - the question text shown to the student. Plain ASCII, tight, no preamble.
  "answer"  - for a pill: the correct answer string (or the correct choice text). For an excel exercise this may be empty.
  "choices" - for a pill MULTIPLE-CHOICE: an array of 3-4 distinct plausible strings, one correct. For a typed pill or an excel exercise: an empty array [].
  "worked"  - a short plain-text worked solution / explanation a student can learn from.
  "layout"  - REQUIRED when surface is "excel"; otherwise omit or null. An object:
        "title"       - a short sheet title string.
        "given"       - array of { "label": string, "value": number, "cell": "B2" } - the input figures, in real cells starting around B2, B3, ...
        "answerCells" - array of { "label": string, "cell": "B6", "expected": number } - each blank cell the student must fill. Each "expected" MUST be deterministically computable from the "given" values (do the arithmetic yourself and put the exact number).

Rules:
- For an "excel" exercise the given values are concrete numbers and every expected answer is exactly derivable from them (e.g. EBIT = Revenue - COGS - OpEx). Never ask for a number that is not computable from the given inputs.
- Put given inputs and answer cells in DISTINCT cells (do not reuse a cell). Use column B for values.
- For a "pill" classification, prefer 4 plausible choices with exactly one correct; wrong choices are realistic confusions.
- Plain ASCII only: straight quotes, hyphens, -> for arrows. No characters outside basic ASCII.
- Output the JSON object and nothing else.
'@
  $lvlMeaning = switch($lvl){ 1 {'atom: a single definition, classification, or one-number calculation'} 2 {'step: a short two or three line calculation'} 3 {'section: a small block of a statement'} 4 {'whole: a fuller worked statement'} default {'atom'} }
  $user = "Curriculum topic:`n  id: "+$topicId+"`n  category: "+$tCat+"`n  topic: "+$tName+"`n  tier: "+$tTier+"`n`nDifficulty level: "+$lvl+" ("+$lvlMeaning+").`nGenerate ONE exercise for this topic at this level as a single JSON object per the rules."
  $payload = $null
  if($model -match '^gpt-5'){
    $payload = (@{ model=$model; max_completion_tokens=1400; reasoning_effort='medium'; messages=@(@{role='system';content=$sys},@{role='user';content=$user}) } | ConvertTo-Json -Depth 10)
  } else {
    $payload = (@{ model=$model; max_tokens=1100; temperature=0; messages=@(@{role='system';content=$sys},@{role='user';content=$user}) } | ConvertTo-Json -Depth 10)
  }
  $bf = Join-Path $env:TEMP ("xc_rt_"+($topicId -replace '[^A-Za-z0-9]','')+"_"+$lvl+".json")
  try { [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false))) } catch { return $null }
  $rr = $null
  try { $rr = & curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf) } catch {}
  try { Remove-Item $bf -ErrorAction SilentlyContinue } catch {}
  $jj = $null; try{ $jj = $rr | ConvertFrom-Json }catch{}
  if(-not $jj -or -not $jj.choices){ return $null }
  $content = [string]$jj.choices[0].message.content
  if(-not $content){ return $null }
  # Strip any accidental code fences and isolate the JSON object.
  $content = ($content -replace '(?s)^.*?```(?:json)?',''); $content = ($content -replace '(?s)```.*$','')
  $content = $content.Trim()
  $s = $content.IndexOf('{'); $e = $content.LastIndexOf('}')
  if($s -lt 0 -or $e -le $s){ return $null }
  $content = $content.Substring($s,$e-$s+1)
  $obj = $null; try{ $obj = $content | ConvertFrom-Json }catch{}
  if($null -eq $obj){ return $null }
  $norm = $null; try{ $norm = RT-NormalizeExercise $obj $topicId $lvl }catch{ return $null }
  return $norm
}

# Pure: coerce a raw exercise object (PSCustomObject from JSON, or a hashtable) into
# the canonical exercise hashtable. Generates a deterministic id from the prompt if
# missing. Ensures choices is an array; surface is 'pill' or 'excel'; for excel,
# layout.given and layout.answerCells are arrays. No network. Tested.
function RT-NormalizeExercise($obj,$topicId,$level){
  $topicId = [string]$topicId
  $lvl = 1; try{ $lvl = [int]$level }catch{ $lvl = 1 }
  # Tolerant field read across hashtable and PSCustomObject.
  $get = {
    param($o,$name)
    if($null -eq $o){ return $null }
    if($o -is [hashtable]){ if($o.ContainsKey($name)){ return $o[$name] } else { return $null } }
    $v = $null; try{ $v = $o.$name }catch{}; return $v
  }
  $prompt = [string](& $get $obj 'prompt')
  $answer = [string](& $get $obj 'answer')
  $worked = [string](& $get $obj 'worked')
  $surface = [string](& $get $obj 'surface')
  if($surface -ne 'excel' -and $surface -ne 'pill'){ $surface = 'pill' }
  # choices -> array (possibly empty)
  $rawChoices = (& $get $obj 'choices')
  $choices = @()
  if($null -ne $rawChoices){ $choices = @($rawChoices | ForEach-Object { [string]$_ }) }
  # id -> deterministic from prompt if missing
  $id = [string](& $get $obj 'id')
  if(-not $id){ $id = "rt-"+$topicId+"-"+$lvl+"-"+([math]::Abs(($prompt+'').GetHashCode()) % 100000) }
  # layout (excel only)
  $layout = $null
  if($surface -eq 'excel'){
    $rawLayout = (& $get $obj 'layout')
    $title = ''; $given = @(); $ans = @()
    if($null -ne $rawLayout){
      $title = [string](& $get $rawLayout 'title')
      $rg = (& $get $rawLayout 'given'); if($null -ne $rg){ $given = @($rg) }
      $ra = (& $get $rawLayout 'answerCells'); if($null -ne $ra){ $ans = @($ra) }
    }
    $layout = @{ title = $title; given = $given; answerCells = $ans }
  }
  return @{ id=$id; topicId=$topicId; level=$lvl; surface=$surface; prompt=$prompt; answer=$answer; choices=$choices; worked=$worked; layout=$layout }
}

# Pure: tolerant numeric compare. True when both parse to double AND
# abs(got-expected) <= 0.01 OR abs(got-expected) <= 0.005 * abs(expected). Else false.
function RT-CellMatch($got,$expected){
  $g = 0.0; $x = 0.0
  $gs = ([string]$got).Trim() -replace '[\$,%]','' -replace '[\(]','-' -replace '[\)]',''
  $xs = ([string]$expected).Trim() -replace '[\$,%]','' -replace '[\(]','-' -replace '[\)]',''
  if(-not [double]::TryParse($gs,[ref]$g)){ return $false }
  if(-not [double]::TryParse($xs,[ref]$x)){ return $false }
  $d = [math]::Abs($g - $x)
  if($d -le 0.01){ return $true }
  if($d -le (0.005 * [math]::Abs($x))){ return $true }
  return $false
}

# Type-stable cell write. PowerShell caches a COM member's parameter type from its
# first use, so writing a string to Range.Value2 then a number throws "cast Int32 to
# String" (and the number is lost). InvokeMember binds the type explicitly each call,
# so labels stay text and numeric values become real numbers in any order.
function RT-SetCell($ws,$addr,$value){
  if(-not $ws -or -not $addr){ return }
  $r = $null
  try {
    $r = $ws.Range($addr)
    $num = 0.0
    if([double]::TryParse(([string]$value),[ref]$num)){ $obj = [double]$num } else { $obj = [string]$value }
    [void]$r.GetType().InvokeMember('Value2',[System.Reflection.BindingFlags]::SetProperty,$null,$r,@($obj))
  } catch {} finally { if($r){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($r) }catch{} } }
}

# Render an excel exercise into a dedicated reused worksheet named "Workout" in the
# workbook from Get-XlBook($xl). Creates the sheet if missing; clears ONLY that sheet.
# Writes title, given label+value pairs, and blank highlighted (light yellow) answer
# cells. Returns @(@{ cell; expected; label }) for grading. All COM guarded. NOT tested.
function RT-RenderExcel($exercise,$xl){
  $out = New-Object System.Collections.ArrayList
  if(-not $exercise -or -not $xl){ return @($out.ToArray()) }
  $layout = $null; try{ $layout = $exercise.layout }catch{}
  if(-not $layout){ return @($out.ToArray()) }
  $wb = $null; $ws = $null
  try {
    if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb = Get-XlBook $xl } else { try{ $wb = $xl.ActiveWorkbook }catch{} }
    if(-not $wb){ return @($out.ToArray()) }
    # Find or create the "Workout" sheet.
    foreach($w in $wb.Worksheets){ try{ if($w.Name -eq 'Workout'){ $ws = $w; break } }catch{} }
    if(-not $ws){ try{ $ws = $wb.Worksheets.Add(); try{ $ws.Name = 'Workout' }catch{} }catch{ return @($out.ToArray()) } }
    try{ $ws.Activate() }catch{}
    # Clear ONLY this sheet (never any other sheet, never the student's cells).
    try{ $ws.Cells.Clear() }catch{}
    # Title.
    $title = ''; try{ $title = [string]$layout.title }catch{}
    if($title){ RT-SetCell $ws 'A1' $title; try{ $tc = $ws.Range('A1'); $tc.Font.Bold = $true; $tc.Font.Size = 13; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($tc) }catch{} }
    # Given inputs: label in col A, value in the stated cell (default col B).
    $given = @(); try{ $given = @($layout.given) }catch{}
    foreach($g in $given){
      if(-not $g){ continue }
      $cell = ''; $label = ''; $val = $null
      try{ $cell = [string]$g.cell }catch{}; try{ $label = [string]$g.label }catch{}; try{ $val = $g.value }catch{}
      if(-not $cell){ continue }
      $rowNum = ($cell -replace '^[A-Za-z]+',''); $lblAddr = $(if($rowNum){ 'A'+$rowNum }else{ '' })
      if($lblAddr -and $label){ RT-SetCell $ws $lblAddr $label }
      RT-SetCell $ws $cell $val
      try{ $vc = $ws.Range($cell); $vc.NumberFormat='#,##0.00;(#,##0.00)'; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($vc) }catch{}
    }
    # Answer cells: label in col A, the answer cell left BLANK + highlighted yellow.
    $ans = @(); try{ $ans = @($layout.answerCells) }catch{}
    foreach($a in $ans){
      if(-not $a){ continue }
      $cell = ''; $label = ''; $expected = $null
      try{ $cell = [string]$a.cell }catch{}; try{ $label = [string]$a.label }catch{}; try{ $expected = $a.expected }catch{}
      if(-not $cell){ continue }
      $rowNum = ($cell -replace '^[A-Za-z]+',''); $lblAddr = $(if($rowNum){ 'A'+$rowNum }else{ '' })
      if($lblAddr -and $label){ RT-SetCell $ws $lblAddr $label; try{ $lc = $ws.Range($lblAddr); $lc.Font.Bold = $true; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($lc) }catch{} }
      try{ $ac = $ws.Range($cell); try{ $ac.ClearContents() }catch{}; try{ $ac.Interior.Color = 65535 }catch{}; try{ $b = $ac.Borders; $b.LineStyle = 1; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($b) }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ac) }catch{}
      [void]$out.Add(@{ cell = $cell; expected = $expected; label = $label })
    }
    try{ $ws.Columns.Item(1).AutoFit() }catch{}
  } catch {} finally {
    foreach($o in @($ws,$wb)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }
  }
  return @($out.ToArray())
}

# Grade an excel exercise: read each answer cell's value from the "Workout" sheet via
# Get-XlBook($xl) and compare with RT-CellMatch. Returns
# @{ correct=[bool]; perCell=@(@{ cell; got; expected; ok }); worked=<string> }.
# correct is true only if every cell matches. All COM guarded. NOT tested.
function Grade-ExcelExercise($exercise,$xl){
  $perCell = New-Object System.Collections.ArrayList
  $worked = ''; try{ $worked = [string]$exercise.worked }catch{}
  if(-not $exercise -or -not $xl){ return @{ correct=$false; perCell=@($perCell.ToArray()); worked=$worked } }
  $layout = $null; try{ $layout = $exercise.layout }catch{}
  $ans = @(); if($layout){ try{ $ans = @($layout.answerCells) }catch{} }
  $wb = $null; $ws = $null
  try {
    if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb = Get-XlBook $xl } else { try{ $wb = $xl.ActiveWorkbook }catch{} }
    if($wb){
      foreach($w in $wb.Worksheets){ try{ if($w.Name -eq 'Workout'){ $ws = $w; break } }catch{} }
    }
    foreach($a in $ans){
      if(-not $a){ continue }
      $cell = ''; $expected = $null
      try{ $cell = [string]$a.cell }catch{}; try{ $expected = $a.expected }catch{}
      if(-not $cell){ continue }
      $got = $null
      if($ws){ try{ $rc = $ws.Range($cell); $got = $rc.Value2; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rc) }catch{} }
      $ok = RT-CellMatch $got $expected
      [void]$perCell.Add(@{ cell=$cell; got=$got; expected=$expected; ok=$ok })
    }
  } catch {} finally {
    foreach($o in @($ws,$wb)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }
  }
  $cells = @($perCell.ToArray())
  $correct = ($cells.Count -gt 0)
  foreach($c in $cells){ if(-not $c.ok){ $correct = $false } }
  return @{ correct=$correct; perCell=$cells; worked=$worked }
}

# The 57 curriculum topics merged with their mastery state.
function Get-RTTopics {
  if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    $cp = Join-Path $PSScriptRoot 'curriculum.ps1'
    if(Test-Path $cp){ try{ . $cp }catch{} }
  }
  $topics = @()
  if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ $topics = @(Get-Curriculum) }catch{} }
  $state = RT-LoadState
  $out = New-Object System.Collections.ArrayList
  foreach($t in $topics){
    $rec = RT-TopicRec $state $t.id
    [void]$out.Add(@{ id = [string]$t.id; name = [string]$t.topic; category = [string]$t.domain; state = $rec })
  }
  return $out
}
