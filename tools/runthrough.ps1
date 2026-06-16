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
function Make-Exercise($topicId,$level,$nonce=''){
  $topicId = [string]$topicId
  $lvl = 1; try{ $lvl = [int]$level }catch{ $lvl = 1 }
  $nonce = [string]$nonce
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
  "concept" - 1-2 plain-English sentences for a beginner explaining WHAT they are doing in this exercise and WHY (the method and the reasoning), e.g. "You subtract COGS and operating expenses from revenue to get operating income, because those are the costs of running the core business." Keep it simple. Do NOT reveal the specific numeric answer.
  "layout"  - REQUIRED when surface is "excel"; otherwise omit or null. An object:
        "title"       - a short sheet title string.
        "given"       - array of { "label": string, "value": number, "cell": "B2" } - the input figures, in real cells starting around B2, B3, ...
        "answerCells" - array of { "label": string, "cell": "B6", "expected": number, "formula": string } - each blank cell the student must fill. Each "expected" MUST be deterministically computable from the "given" values (do the arithmetic yourself and put the exact number). "formula" is a SHORT plain-language calculation for THAT cell using the given labels (NOT the raw numbers), e.g. "Revenue - COGS - Operating Expenses".

Rules:
- For an "excel" exercise the given values are concrete numbers and every expected answer is exactly derivable from them (e.g. EBIT = Revenue - COGS - OpEx). Never ask for a number that is not computable from the given inputs.
- Put given inputs and answer cells in DISTINCT cells (do not reuse a cell). Use column B for values.
- For a "pill" classification, prefer 4 plausible choices with exactly one correct; wrong choices are realistic confusions.
- Plain ASCII only: straight quotes, hyphens, -> for arrows. No characters outside basic ASCII.
- Output the JSON object and nothing else.
'@
  $lvlMeaning = switch($lvl){ 1 {'atom: a single definition, classification, or one-number calculation'} 2 {'step: a short two or three line calculation'} 3 {'section: a small block of a statement'} 4 {'whole: a fuller worked statement'} default {'atom'} }
  $user = "Curriculum topic:`n  id: "+$topicId+"`n  category: "+$tCat+"`n  topic: "+$tName+"`n  tier: "+$tTier+"`n`nDifficulty level: "+$lvl+" ("+$lvlMeaning+").`nGenerate ONE exercise for this topic at this level as a single JSON object per the rules."
  if($nonce){ $user = $user+"`nVariation token "+$nonce+": use DIFFERENT specific numbers than any previous version of this exercise." }
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
  $concept = [string](& $get $obj 'concept')
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
  return @{ id=$id; topicId=$topicId; level=$lvl; surface=$surface; prompt=$prompt; answer=$answer; choices=$choices; worked=$worked; concept=$concept; layout=$layout }
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
    # Header: a SHORT clean goal (title + a fill instruction) - not the full prompt,
    # which restates every number and clutters the cell. The full question + concept
    # live in the coach pill.
    $ttl = ''; try{ $ttl = [string]$layout.title }catch{}
    if(-not $ttl){ $ttl = 'Exercise' }
    $header = $ttl + ' - fill in the highlighted yellow cells, then press Done in the coach.'
    RT-SetCell $ws 'A1' $header; try{ $tc = $ws.Range('A1'); $tc.Font.Bold = $true; $tc.Font.Size = 12; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($tc) }catch{}
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
      $cell = ''; $expected = $null; $label = ''; $formula = ''
      try{ $cell = [string]$a.cell }catch{}; try{ $expected = $a.expected }catch{}; try{ $label = [string]$a.label }catch{}; try{ $formula = [string]$a.formula }catch{}
      if(-not $cell){ continue }
      $got = $null
      if($ws){ try{ $rc = $ws.Range($cell); $got = $rc.Value2; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($rc) }catch{} }
      $ok = RT-CellMatch $got $expected
      [void]$perCell.Add(@{ cell=$cell; got=$got; expected=$expected; ok=$ok; label=$label; formula=$formula })
    }
  } catch {} finally {
    foreach($o in @($ws,$wb)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }
  }
  $cells = @($perCell.ToArray())
  $correct = ($cells.Count -gt 0)
  foreach($c in $cells){ if(-not $c.ok){ $correct = $false } }
  return @{ correct=$correct; perCell=$cells; worked=$worked }
}

# Shift a column letter by n (e.g. ('B',2) -> 'D'). Handles multi-letter columns.
function Shift-Col($col, $n){
  $col = ([string]$col).ToUpper(); if(-not $col){ return 'A' }
  $num = 0; foreach($ch in $col.ToCharArray()){ $num = $num * 26 + ([int][char]$ch - 64) }
  $num += [int]$n; if($num -lt 1){ $num = 1 }
  $s = ''; while($num -gt 0){ $r = ($num - 1) % 26; $s = ([char](65 + $r)) + $s; $num = [int][math]::Floor(($num - 1) / 26) }
  return $s
}

# After grading, mark the "Workout" sheet so mistakes are visible IN EXCEL: wrong
# answer cells turn light red, correct ones light green, and 2 columns to the right
# of each WRONG cell write "should be <expected> (<formula>)" in red. Re-running on a
# re-check updates cleanly (clears the prior note; a now-correct cell goes green with
# no note). ONLY the "Workout" sheet is touched. Returns the count of wrong cells.
function Mark-ExcelMistakes($exercise, $xl, $perCell){
  $wrong = 0
  if(-not $exercise -or -not $xl){ return 0 }
  $cells = @(); try{ $cells = @($perCell) }catch{}
  if($cells.Count -lt 1){ return 0 }
  $wb = $null; $ws = $null
  try {
    if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb = Get-XlBook $xl } else { try{ $wb = $xl.ActiveWorkbook }catch{} }
    if(-not $wb){ return 0 }
    foreach($w in $wb.Worksheets){ try{ if($w.Name -eq 'Workout'){ $ws = $w; break } }catch{} }
    if(-not $ws){ return 0 }
    $RED = 13552127; $GREEN = 13562310
    foreach($pc in $cells){
      if(-not $pc){ continue }
      $cell = ''; try{ $cell = [string]$pc.cell }catch{}
      if(-not $cell){ continue }
      $ok = $false; try{ $ok = [bool]$pc.ok }catch{}
      try{ $ac = $ws.Range($cell); $ac.Interior.Color = $(if($ok){ $GREEN }else{ $RED }); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ac) }catch{}
      $colL = ($cell -replace '[0-9]+',''); $rowN = ($cell -replace '^[A-Za-z]+','')
      $corr = ''; if($colL -and $rowN){ $corr = (Shift-Col $colL 2) + $rowN }
      if($corr){
        # always clear any prior note so a re-check after a fix updates cleanly
        try{ $cc = $ws.Range($corr); $cc.ClearContents(); try{ $cc.Font.Italic = $false }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cc) }catch{}
        if(-not $ok){
          $wrong++
          $txt = 'should be ' + [string]$pc.expected
          $fm = ''; try{ $fm = [string]$pc.formula }catch{}
          if($fm){ $txt = $txt + '  (' + $fm + ')' }
          RT-SetCell $ws $corr $txt
          try{ $cc = $ws.Range($corr); try{ $cc.Font.Color = 192 }catch{}; try{ $cc.Font.Italic = $true }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cc) }catch{}
        }
      }
    }
  } catch {} finally {
    foreach($o in @($ws,$wb)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }
  }
  return $wrong
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

# --- Controller library (Phase A): grader, mastery transitions, picker, scoreboard. ---

# A1: Grade one PILL exercise (MC or numeric one-off). Returns
#   @{ correct=[bool]; expected; worked }.
# MC: $exercise.choices non-empty. $answer may be an int index OR the chosen choice
# text; $exercise.answer may be an int index OR the correct text. Resolve both sides
# to the chosen string and compare (and also accept index==index).
# Else if $exercise.answer parses numeric: RT-CellMatch. Else (free text): $false
# (typed free-text grading is deferred to a later AI judge; v1 pill items are MC).
function Grade-PillExercise($exercise,$answer){
  $worked = ''; try{ $worked = [string]$exercise.worked }catch{}
  $choices = @(); try{ if($null -ne $exercise.choices){ $choices = @($exercise.choices) } }catch{}
  $rawAns = $null; try{ $rawAns = $exercise.answer }catch{}
  # Resolve a value that is an int index OR a choice string to the chosen choice text.
  $resolve = {
    param($v,$ch)
    if($null -eq $v){ return $null }
    $vs = ([string]$v).Trim()
    $idx = 0
    if([int]::TryParse($vs,[ref]$idx)){
      if($ch.Count -gt 0 -and $idx -ge 0 -and $idx -lt $ch.Count){ return ([string]$ch[$idx]).Trim() }
    }
    return $vs
  }
  if($choices.Count -gt 0){
    # MC. Try index==index first (both numeric).
    $expected = ''
    $ai = 0; $hasAi = [int]::TryParse(([string]$rawAns).Trim(),[ref]$ai)
    if($hasAi -and $ai -ge 0 -and $ai -lt $choices.Count){ $expected = ([string]$choices[$ai]).Trim() } else { $expected = ([string]$rawAns).Trim() }
    $gi = 0; $hasGi = [int]::TryParse(([string]$answer).Trim(),[ref]$gi)
    $correct = $false
    if($hasAi -and $hasGi){ if($ai -eq $gi){ $correct = $true } }
    if(-not $correct){
      $chosenStr = (& $resolve $answer $choices)
      $expectStr = (& $resolve $rawAns $choices)
      if($null -ne $chosenStr -and $null -ne $expectStr -and $chosenStr -eq $expectStr){ $correct = $true }
    }
    return @{ correct=[bool]$correct; expected=$expected; worked=$worked }
  }
  # Numeric one-off.
  $xs = ([string]$rawAns).Trim() -replace '[\$,%]','' -replace '[\(]','-' -replace '[\)]',''
  $xn = 0.0
  if($xs -and [double]::TryParse($xs,[ref]$xn)){
    return @{ correct=[bool](RT-CellMatch $answer $rawAns); expected=([string]$rawAns); worked=$worked }
  }
  # Free text: deferred.
  return @{ correct=$false; expected=([string]$rawAns); worked=$worked }
}

# A2: Record one result into durable RT state and return the mastery transition.
# Returns @{ rec; becameSolid=[bool]; bumpedLevel=[bool] }.
# correct & not retry -> streak++; streak>=2 -> add level to mastered (dedupe),
#   becameSolid, reset streak, bump level capped at 2 (bumpedLevel if it changed).
# correct & retry -> consolidation only (streak stays 0, no promotion).
# wrong -> streak=0. Always attempts++ / correct++ as appropriate; set lastSeen; save.
function RT-RecordResult($topicId,$level,$correct,$isRetry){
  $topicId = [string]$topicId
  $lvl = 1; try{ $lvl = [int]$level }catch{ $lvl = 1 }
  $ok = [bool]$correct
  $retry = [bool]$isRetry
  $state = RT-LoadState
  $rec = RT-TopicRec $state $topicId
  $rec.level = [int]$rec.level
  $rec.streak = [int]$rec.streak
  $rec.attempts = [int]$rec.attempts + 1
  if($ok){ $rec.correct = [int]$rec.correct + 1 }
  $mastered = @(); if($rec.mastered){ $mastered = @($rec.mastered | ForEach-Object { [int]$_ }) }
  $becameSolid = $false
  $bumpedLevel = $false
  if($ok -and -not $retry){
    $rec.streak = $rec.streak + 1
    if($rec.streak -ge 2){
      if($mastered -notcontains $lvl){ $mastered = @($mastered + $lvl) }
      $becameSolid = $true
      $rec.streak = 0
      $newLevel = [math]::Min(2, $rec.level + 1)
      if($newLevel -ne $rec.level){ $rec.level = $newLevel; $bumpedLevel = $true }
    }
  } elseif($ok -and $retry){
    # consolidation only - no promotion progress.
  } else {
    $rec.streak = 0
  }
  $rec.mastered = @($mastered)
  $rec.lastSeen = (Get-Date).ToString('o')
  $state.topics[$topicId] = $rec
  RT-SaveState $state
  return @{ rec=$rec; becameSolid=[bool]$becameSolid; bumpedLevel=[bool]$bumpedLevel }
}

# Tier rank: lower = more foundational / higher priority. Strings (must/should/nice)
# map to 0/1/2; a numeric tier passes through (lower=more foundational); unknown -> 1.
function RT-TierRank($tier){
  $t = ([string]$tier).Trim().ToLower()
  switch($t){
    'must'   { return 0 }
    'should' { return 1 }
    'nice'   { return 2 }
    default  {
      $n = 0
      if([double]::TryParse($t,[ref]$n)){ return [int]$n }
      return 1
    }
  }
}

# Map a topic id -> its curriculum tier (string) so the picker can tier-order.
function RT-TierMap {
  if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    $cp = Join-Path $PSScriptRoot 'curriculum.ps1'
    if(Test-Path $cp){ try{ . $cp }catch{} }
  }
  $h = @{}
  if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){
    try{ foreach($t in (Get-Curriculum)){ $h[[string]$t.id] = [string]$t.tier } }catch{}
  }
  return $h
}

# A3: Pick the next topic + level. Returns @{ topicId; level }.
# Order (first match wins); never returns $lastTopicId unless it is the only candidate:
#  1. itemsThisSitting < 3 -> easiest UNSEEN must-tier topic at level 1.
#  2. Any UNSEEN topic (attempts==0), must-tier first then should then nice, at level 1.
#  3. A Get-WeakTopics topic, served at max(1, current level - 1).
#  4. Else the lowest-streak / least-recently-seen topic, at its current level.
function RT-PickNext($state,$itemsThisSitting,$lastTopicId){
  $items = 0; try{ $items = [int]$itemsThisSitting }catch{ $items = 0 }
  $lastId = [string]$lastTopicId
  $topics = @(); try{ $topics = @(Get-RTTopics) }catch{}
  if($topics.Count -eq 0){ return @{ topicId=''; level=1 } }
  $tierMap = RT-TierMap
  # Annotate each topic with rank/level/streak/attempts/lastSeen.
  $rows = New-Object System.Collections.ArrayList
  foreach($t in $topics){
    $id = [string]$t.id
    $rec = $t.state
    $lvl = 1; try{ $lvl = [int]$rec.level }catch{ $lvl = 1 }
    $streak = 0; try{ $streak = [int]$rec.streak }catch{ $streak = 0 }
    $att = 0; try{ $att = [int]$rec.attempts }catch{ $att = 0 }
    $seen = ''; try{ $seen = [string]$rec.lastSeen }catch{ $seen = '' }
    $tier = ''; if($tierMap.ContainsKey($id)){ $tier = $tierMap[$id] }
    [void]$rows.Add(@{ id=$id; level=$lvl; streak=$streak; attempts=$att; lastSeen=$seen; tierRank=(RT-TierRank $tier) })
  }
  $rows = @($rows.ToArray())
  # Helper: pick from a candidate list honouring the never-repeat-last rule.
  $choose = {
    param($cands,$lvlOf)
    $cands = @($cands)
    if($cands.Count -eq 0){ return $null }
    $nonLast = @($cands | Where-Object { $_.id -ne $lastId })
    $use = $(if($nonLast.Count -gt 0){ $nonLast } else { $cands })
    $pick = $use[0]
    $lvl = 1; if($lvlOf){ $lvl = (& $lvlOf $pick) }
    return @{ topicId=$pick.id; level=$lvl }
  }
  # 1 + 2: unseen topics, tier-ordered (must first), then by id for stability.
  $unseen = @($rows | Where-Object { $_.attempts -le 0 } | Sort-Object @{Expression={$_.tierRank}}, @{Expression={$_.id}})
  if($items -lt 3){
    $unseenMust = @($unseen | Where-Object { $_.tierRank -le 0 })
    $r = (& $choose $unseenMust { param($p) 1 })
    if($r){ return $r }
  }
  $r = (& $choose $unseen { param($p) 1 })
  if($r){ return $r }
  # 3: a weak topic flagged by perf, served one level below current (min 1).
  $weakIds = @()
  if(Get-Command Get-WeakTopics -ErrorAction SilentlyContinue){ try{ $weakIds = @(Get-WeakTopics 5) }catch{} }
  if($weakIds.Count -gt 0){
    $weakRows = @($rows | Where-Object { $weakIds -contains $_.id })
    $r = (& $choose $weakRows { param($p) [math]::Max(1, [int]$p.level - 1) })
    if($r){ return $r }
  }
  # 4: lowest streak, then least-recently-seen (empty lastSeen sorts first), then id.
  $rest = @($rows | Sort-Object @{Expression={$_.streak}}, @{Expression={$_.lastSeen}}, @{Expression={$_.id}})
  $r = (& $choose $rest { param($p) [math]::Max(1, [int]$p.level) })
  if($r){ return $r }
  # Fallback: the only/first candidate (e.g. when lastTopicId is the sole topic).
  $only = $rows[0]
  return @{ topicId=$only.id; level=[math]::Max(1,[int]$only.level) }
}

# A4: Progress scoreboard. Returns
#   @{ solid; total; areas=@(@{ name; solid; total; status }) }.
# total = curriculum topic count. ceiling=2 for all topics in v1; a topic is SOLID
# when its mastered list contains the ceiling (2). areas = distinct domain values;
# status: green=all solid, yellow=some, grey=none.
function Get-RTProgress {
  $ceiling = 2
  if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    $cp = Join-Path $PSScriptRoot 'curriculum.ps1'
    if(Test-Path $cp){ try{ . $cp }catch{} }
  }
  $cur = @(); if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ $cur = @(Get-Curriculum) }catch{} }
  $state = RT-LoadState
  $total = $cur.Count
  $solid = 0
  $areaOrder = New-Object System.Collections.ArrayList
  $areaTotal = @{}
  $areaSolid = @{}
  foreach($t in $cur){
    $id = [string]$t.id
    $dom = [string]$t.domain; if(-not $dom){ $dom = '(other)' }
    if(-not $areaTotal.ContainsKey($dom)){ [void]$areaOrder.Add($dom); $areaTotal[$dom] = 0; $areaSolid[$dom] = 0 }
    $areaTotal[$dom] = $areaTotal[$dom] + 1
    $rec = RT-TopicRec $state $id
    $mastered = @(); if($rec.mastered){ $mastered = @($rec.mastered | ForEach-Object { [int]$_ }) }
    $isSolid = ($mastered -contains $ceiling)
    if($isSolid){ $solid = $solid + 1; $areaSolid[$dom] = $areaSolid[$dom] + 1 }
  }
  $areas = New-Object System.Collections.ArrayList
  foreach($dom in $areaOrder){
    $at = [int]$areaTotal[$dom]; $as = [int]$areaSolid[$dom]
    $status = 'grey'
    if($at -gt 0 -and $as -ge $at){ $status = 'green' } elseif($as -gt 0){ $status = 'yellow' }
    [void]$areas.Add(@{ name=$dom; solid=$as; total=$at; status=$status })
  }
  return @{ solid=$solid; total=$total; areas=@($areas.ToArray()) }
}
