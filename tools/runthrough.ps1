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
function RT-NewState { return @{ topics = @{}; updatedAt = ''; clock = 0 } }
# Per-topic record. Original fields (level/streak/attempts/correct/mastered/lastSeen)
# are unchanged so old readers keep working. Scheduling fields added for the spaced
# -repetition scheduler; old JSON entries that lack them are tolerated by RT-TopicRec
# (they default in). reps = consecutive-correct count toward an interval; ease = SM-2
# -lite spacing multiplier; interval = picks to wait before due again; due = the global
# pick-clock value at/after which the topic is due; lapses = lifetime miss count.
function RT-NewTopicRec { return @{ level = 1; streak = 0; attempts = 0; correct = 0; mastered = @(); lastSeen = ''; reps = 0; ease = 2.3; interval = 0; due = 0; lapses = 0 } }

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
    $cl = $null; try{ $cl = $o.clock }catch{}
    if($null -ne $cl){ try{ $st.clock = [int]$cl }catch{ $st.clock = 0 } }
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
    # Old entries predate reps/ease/interval/due/lapses; only copy a field when the
    # stored record actually has it, so missing scheduling fields keep their defaults.
    foreach($k in @('level','streak','attempts','correct','mastered','lastSeen','reps','ease','interval','due','lapses')){
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
# Pure: true if every cell token (e.g. B2, AA10) mentioned in an excel exercise's prompt
# actually appears in its layout (given or answerCells). Guards against the model writing
# a question about cells the sheet never populates. Period tokens (Q1, H2, FY24) are not
# treated as cell refs. Non-excel exercises are always "consistent". No network.
function RT-ExcelConsistent($ex){
  try{
    if($null -eq $ex -or $ex.surface -ne 'excel'){ return $true }
    $cells=@{}
    foreach($g in @($ex.layout.given)){ $c=([string]$g.cell).ToUpper(); if($c){ $cells[$c]=$true } }
    foreach($a in @($ex.layout.answerCells)){ $c=([string]$a.cell).ToUpper(); if($c){ $cells[$c]=$true } }
    if($cells.Count -lt 1){ return $false }
    $refs = [regex]::Matches(([string]$ex.prompt).ToUpper(), '\b[A-Z]{1,3}[0-9]{1,4}\b')
    foreach($m in $refs){
      $v=$m.Value
      if($v -match '^(Q[1-4]|H[12]|FY[0-9]{1,4})$'){ continue }   # period tokens, not cell refs
      if(-not $cells.ContainsKey($v)){ return $false }
    }
    return $true
  }catch{ return $true }
}
# Deterministically recompute each excel answer cell's "expected" from the given inputs
# and that cell's plain-language "formula", then OVERRIDE the stored number with the
# computed value. This kills the class of bug where the model's self-reported answer
# disagrees with its own formula (e.g. EBITDA showing "should be 120000" under a formula
# that actually yields 200000) - after this, the graded answer ALWAYS matches the formula
# the student is shown. Substitutes labels->values (longest label first, word-bounded;
# also exposes earlier answer cells as labels for multi-step formulas), then evaluates the
# pure-arithmetic expression with DataTable.Compute (no code execution). Returns
# @{ ok=<every cell cleanly computed>; changed=<any expected overridden> } and mutates
# $ex.layout.answerCells[].expected. A formula with an unmatched label or a non-arithmetic
# leftover is left as-is and makes ok=$false so the caller can retry/flag. Pure (no network).
function RT-RecomputeExpected($ex){
  try{
    if($null -eq $ex -or $ex.surface -ne 'excel'){ return @{ ok=$true; changed=$false } }
    $vals = @{}
    $labels = New-Object System.Collections.ArrayList
    foreach($g in @($ex.layout.given)){
      $lab = ''; try{ $lab = ([string]$g.label).Trim() }catch{}
      if(-not $lab){ continue }
      $num = $null; try{ $num = [double](([string]$g.value) -replace '[\$,%\s]','') }catch{}
      if($null -ne $num){ $vals[$lab.ToLower()] = $num; [void]$labels.Add($lab) }
    }
    $allOk = $true; $changed = $false
    foreach($a in @($ex.layout.answerCells)){
      $formula = ''; try{ $formula = ([string]$a.formula).Trim() }catch{}
      if(-not $formula){ $allOk = $false; continue }
      $expr = $formula
      foreach($lab in ($labels | Sort-Object { $_.Length } -Descending)){
        $pat = '(?<![A-Za-z0-9])'+[regex]::Escape($lab)+'(?![A-Za-z0-9])'
        $expr = [regex]::Replace($expr, $pat, ([string]$vals[$lab.ToLower()]), 'IgnoreCase')
      }
      if($expr -match '[A-Za-z]'){ $allOk = $false; continue }   # an unmatched label remains -> cannot verify
      $clean = ($expr -replace '[^0-9\.\+\-\*\/\(\)\s]','').Trim()
      if(-not $clean){ $allOk = $false; continue }
      $val = $null
      try{ $val = (New-Object System.Data.DataTable).Compute($clean,'') }catch{ $val = $null }
      if($null -eq $val -or $val -is [System.DBNull]){ $allOk = $false; continue }
      $computed = 0.0; if(-not [double]::TryParse(([string]$val),[ref]$computed)){ $allOk = $false; continue }
      $ls = ''; try{ $ls = ([string]$a.expected) -replace '[\$,%\s]','' }catch{}
      $lp = 0.0; $haveLlm = [double]::TryParse($ls,[ref]$lp)
      $tol = [math]::Max(0.01, 0.005*[math]::Abs($computed))
      if((-not $haveLlm) -or ([math]::Abs($computed - $lp) -gt $tol)){
        if($a -is [hashtable]){ $a['expected'] = $computed }
        else { try{ $a.expected = $computed }catch{ try{ $a | Add-Member -NotePropertyName expected -NotePropertyValue $computed -Force }catch{ $allOk = $false } } }
        $changed = $true
      }
      $alab = ''; try{ $alab = ([string]$a.label).Trim() }catch{}
      if($alab){ $vals[$alab.ToLower()] = $computed; [void]$labels.Add($alab) }
    }
    return @{ ok=$allOk; changed=$changed }
  }catch{ return @{ ok=$false; changed=$false } }
}
function Make-Exercise($topicId,$level,$nonce='',$prior=$null,$mode='expand'){
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
  # OBSERVED CURRICULUM (v3): an id like 'obs-...' is a concept the coach watched + distilled.
  # Ground the exercise in EXACTLY what the source taught (its definition/method/example),
  # not the fixed finance deck - this is what lets the run-through drill any watched subject.
  $obsGround = ''
  if($topicId -like 'obs-*' -and (Get-Command Obs-Load -ErrorAction SilentlyContinue)){
    try{ foreach($o in @(Obs-Load)){ if([string]$o.id -eq $topicId){ $tName=[string]$o.title; if($o.domain){ $tCat=[string]$o.domain }; $tTier='observed'; $g=[string]$o.taught; if([string]$o.example){ $g=$g+"  Example as shown: "+[string]$o.example }; $obsGround=$g; break } } }catch{}
  }
  $sys = @'
You generate ONE exercise for a finance student prepping for an investment-banking fellowship. You are given a curriculum topic (id, category, name) and a difficulty level (1=atom, 2=step, 3=section, 4=whole). Decide whether the topic is best drilled as a CALCULATION (the student computes numbers in Excel) or as a DEFINITION/CLASSIFICATION (the student picks or types an answer).

Output ONLY a JSON object (no prose, no markdown, no code fences) with these fields:
  "id"      - a short slug like "rt-<topicId>-<level>-<n>". May be omitted.
  "topicId" - echo the given topic id.
  "level"   - echo the given level (integer).
  "surface" - "excel" for a calculation, "pill" for a definition/classification.
  "prompt"  - the question text shown to the student. Plain ASCII, tight, no preamble. For an "excel" exercise the prompt MUST describe the SAME scenario as "layout": refer to the given figures by their real labels and/or their cells, and ask the student to fill ONLY the highlighted answer cell(s). NEVER mention a cell that is not listed in "given" or "answerCells", and never reference values or formulas that are not in the layout. The student reads this prompt while looking at exactly the cells in "layout" - they must line up.
  "answer"  - for a pill: the correct answer string (or the correct choice text). For an excel exercise this may be empty.
  "choices" - for a pill MULTIPLE-CHOICE: an array of 3-4 distinct plausible strings, one correct. For a typed pill or an excel exercise: an empty array [].
  "worked"  - a short plain-text worked solution / explanation a student can learn from.
  "concept" - 1-2 plain-English sentences for a beginner explaining WHAT they are doing in this exercise and WHY (the method and the reasoning), e.g. "You subtract COGS and operating expenses from revenue to get operating income, because those are the costs of running the core business." Keep it simple. Do NOT reveal the specific numeric answer.
  "layout"  - REQUIRED when surface is "excel"; otherwise omit or null. An object:
        "title"       - a short sheet title string.
        "given"       - array of { "label": string, "value": number, "cell": "B2" } - the input figures, in real cells starting around B2, B3, ...
        "answerCells" - array of { "label": string, "cell": "B6", "expected": number, "formula": string } - each blank cell the student must fill. Each "expected" MUST be deterministically computable from the "given" values (do the arithmetic yourself and put the exact number). "formula" is a SHORT plain-language calculation for THAT cell using the given labels (NOT the raw numbers), e.g. "Revenue - COGS - Operating Expenses".

Rules:
- For an "excel" exercise the given values are concrete numbers and every expected answer is exactly derivable from them (e.g. Gross Profit = Revenue - COGS). Never ask for a number that is not computable from the given inputs.
- NO DOUBLE-COUNTING (critical for EBIT / EBITDA / operating income): use each given line item AT MOST ONCE. If Depreciation and/or Amortization are GIVEN as their own separate line items, they have ALREADY been subtracted in reaching operating profit - so EBITDA = Revenue - COGS - Operating Expenses (the D&A net out) and EBIT = Revenue - COGS - Operating Expenses - Depreciation - Amortization. Do NOT compute "Revenue - COGS - OpEx + Depreciation + Amortization" - that adds D&A back onto a base that never subtracted them (a double-count). Only "add back D&A" when D&A are embedded inside COGS/OpEx and are NOT listed as separate given inputs. When in doubt, do not list D&A as separate inputs for an EBITDA question.
- SELF-CONTAINED + COURSE-LEVEL: the exercise must use ONLY the basic, explicitly-stated method for this topic. The "expected" value MUST follow ONLY from the given values and the stated "formula", with NO hidden conventions or extra assumptions - NO mid-year convention, stub periods, day-count, inflation, terminal-value, tax adjustments, or rounding rules - unless the question text itself states them AND the topic is specifically about them. A student who applies the stated formula to the given numbers must get EXACTLY "expected". Keep numbers clean and the method singular; this is a foundational course, not an advanced modeling test.
- GROUND STRICTLY in the course content provided for this topic (the study cards in the user message, when present). Use ONLY the definitions, formulas, and methods shown there. If a concept, formula, convention, or method is NOT in that course content, treat it as OUT OF SCOPE and do not use it.
- Put given inputs and answer cells in DISTINCT cells (do not reuse a cell). Use column B for values.
- CONSISTENCY (excel): the sheet the student sees is built ENTIRELY from "layout". The "prompt", the "title", and every "label" must describe the SAME scenario and the SAME cells as "given"/"answerCells". A reader must be able to answer using ONLY the labelled given values and the highlighted answer cell(s) - the prompt must not reference any cell, value, or formula that is not in the layout. (Bad: prompt says "enter =A1*B1 and copy to C2" while the layout never defines A1 or B1. Good: prompt says "Using Revenue in B2 and COGS in B3, compute Gross Profit in the highlighted cell B4.")
- LABELS name WHAT the number is (e.g. "Revenue", "Units sold", "Tax rate"), NEVER the cell address. Never write a label like "Value in B1" or "Formula in C2".
- For a "pill" classification, prefer 4 plausible choices with exactly one correct; wrong choices are realistic confusions.
- Plain ASCII only: straight quotes, hyphens, -> for arrows. No characters outside basic ASCII.
- Output the JSON object and nothing else.
'@
  # For an OBSERVED concept the subject can be anything (Biology, History, Excel...), so drop
  # the finance/IB framing and tell the model to stay strictly inside what the source taught.
  if($topicId -like 'obs-*'){ $sys = $sys -replace 'You generate ONE exercise for a finance student prepping for an investment-banking fellowship\.', ('You generate ONE exercise for a student drilling a topic from their OWN study material (subject: '+$tCat+'). Work strictly within what the source taught (provided below) - do NOT assume finance or any domain the material does not indicate.') }
  $lvlMeaning = switch($lvl){ 1 {'atom: a single definition, classification, or one-number calculation'} 2 {'step: a short two or three line calculation'} 3 {'section: a small block of a statement'} 4 {'whole: a fuller worked statement'} default {'atom'} }
  # Ground STRICTLY in the course's OWN content for this topic (its study cards), so the
  # exercise can never introduce anything outside what the student is actually learning.
  $courseContent = ""
  if(Get-Command Get-TopicCards -ErrorAction SilentlyContinue){
    try { $cards = @(Get-TopicCards $topicId); $lines = @(); $cn = 0; foreach($c in $cards){ if($cn -ge 16){ break }; $f = [string]$c.front; $b = [string]$c.back; if($f){ $lines += ('- ' + $f + ': ' + $b); $cn++ } }; if($lines.Count){ $courseContent = ($lines -join "`n") } } catch {}
  }
  if($obsGround){ $courseContent = $obsGround }   # observed concept -> ground in EXACTLY what the source taught, not the fixed deck
  $user = "Topic to drill:`n  id: "+$topicId+"`n  subject: "+$tCat+"`n  topic: "+$tName+"`n  tier: "+$tTier+"`n"
  if($courseContent){ $user += "`nEXACTLY what was taught for this topic. Build the exercise using ONLY these definitions, formulas, and concepts - do NOT introduce anything not represented below:`n"+$courseContent+"`n" }
  $user += "`nDifficulty level: "+$lvl+" ("+$lvlMeaning+").`nGenerate ONE exercise for this topic at this level as a single JSON object per the rules."
  if($nonce){ $user = $user+"`nVariation token "+$nonce+": use DIFFERENT specific numbers than any previous version of this exercise." }
  # EXPANSION (adaptive ladder): when extending a just-passed exercise, keep the SAME
  # scenario, fold every prior value (inputs AND the answers the student computed) into the
  # 'given', and add exactly ONE new dependent step - one notch harder. This is what makes a
  # correct answer "grow" the exercise instead of jumping to an unrelated one.
  if($prior -and $prior.layout){
    $givenLines=""; $allLabels=@()
    try{ foreach($g in @($prior.layout.given)){ $givenLines += "  - "+[string]$g.label+" = "+[string]$g.value+"`n"; $allLabels += [string]$g.label } }catch{}
    $ansLines=""
    try{ foreach($a in @($prior.layout.answerCells)){ $ansLines += "  - "+[string]$a.label+" = "+[string]$a.expected+"`n"; $allLabels += [string]$a.label } }catch{}
    if($mode -eq 'vary'){
      # FAIL path: re-test the SAME thing with DIFFERENT numbers (the model can't see prior
      # calls, so we must show it exactly which numbers to avoid - otherwise it repeats them).
      if($givenLines){ $user += "`nThis is a RE-ATTEMPT: the student just missed a similar exercise, so build a FRESH VARIATION of the SAME concept at the SAME difficulty - same structure and the same thing to compute, but you MUST choose DIFFERENT specific input numbers. Do NOT reuse any of these values:`n"+$givenLines+"Pick new, clean numbers and keep the scenario equivalent.`n" }
    } else {
      # PASS path: grow the SAME scenario by exactly one new step.
      if($givenLines -or $ansLines){
        $lab = ($allLabels | Where-Object { $_ } | Select-Object -Unique) -join ', '
        $user += "`nEXPAND THIS EXERCISE - do NOT start a new unrelated one and do NOT just rephrase it. The student just correctly finished a step. Build an 'excel' exercise that:`n  1) lists EVERY one of these as a 'given' (copy them verbatim into 'given' with these exact values):`n"+$givenLines+$ansLines+"  2) adds EXACTLY ONE NEW answer cell whose label is NOT one of these ("+$lab+") - it must be the NEXT step up, one notch more complex (the next line of the calculation, a ratio/margin, or a small twist that USES the values above).`nKeep the SAME scenario and numbers; only add the one new step. If there is no meaningful next step for this concept, move to the closest follow-on calculation that builds on these values.`n"
      }
    }
  }
  # Generate, then for an excel exercise verify the prompt is consistent with the layout
  # (references only cells the sheet actually defines). Retry once if not - this is the
  # guard against "the question makes no sense vs the sheet" exercises. Never hard-fail on
  # inconsistency alone: keep the last candidate as a fallback so the drill still runs.
  $norm = $null
  for($attempt=0; $attempt -lt 2; $attempt++){
    $uMsg = $user
    if($attempt -gt 0){ $uMsg = $user + "`n`nIMPORTANT: the previous attempt was rejected as inconsistent. Either the prompt referenced cells/values not in the layout, OR an answerCell.formula used a name that is not one of the given labels so its answer could not be verified. Regenerate so that: (1) the prompt, title and labels reference ONLY cells listed in given/answerCells; (2) each answerCell.formula uses ONLY the exact given labels joined by + - * / and parentheses (no other words); and (3) each expected EQUALS that formula applied to the given numbers - do the arithmetic carefully and double-check it." }
    if($model -match '^gpt-5'){
      $payload = (@{ model=$model; max_completion_tokens=1400; reasoning_effort='medium'; messages=@(@{role='system';content=$sys},@{role='user';content=$uMsg}) } | ConvertTo-Json -Depth 10)
    } else {
      $payload = (@{ model=$model; max_tokens=1100; temperature=0; messages=@(@{role='system';content=$sys},@{role='user';content=$uMsg}) } | ConvertTo-Json -Depth 10)
    }
    $bf = Join-Path $env:TEMP ("xc_rt_"+($topicId -replace '[^A-Za-z0-9]','')+"_"+$lvl+".json")
    try { [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false))) } catch { return $null }
    $rr = $null
    try { $rr = & curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf) } catch {}
    try { Remove-Item $bf -ErrorAction SilentlyContinue } catch {}
    $jj = $null; try{ $jj = $rr | ConvertFrom-Json }catch{}
    if(-not $jj -or -not $jj.choices){ continue }
    $content = [string]$jj.choices[0].message.content
    if(-not $content){ continue }
    # Strip any accidental code fences and isolate the JSON object.
    $content = ($content -replace '(?s)^.*?```(?:json)?',''); $content = ($content -replace '(?s)```.*$','')
    $content = $content.Trim()
    $s = $content.IndexOf('{'); $e = $content.LastIndexOf('}')
    if($s -lt 0 -or $e -le $s){ continue }
    $content = $content.Substring($s,$e-$s+1)
    $obj = $null; try{ $obj = $content | ConvertFrom-Json }catch{}
    if($null -eq $obj){ continue }
    $cand = $null; try{ $cand = RT-NormalizeExercise $obj $topicId $lvl }catch{ $cand = $null }
    if($null -eq $cand){ continue }
    $norm = $cand                                   # remember best-effort fallback
    if($cand.surface -ne 'excel'){ break }          # pills have no layout to contradict
    # Numeric self-consistency: recompute each ARITHMETIC answer cell's expected from its
    # formula + the given inputs and OVERRIDE the stored number, so the graded answer can
    # never disagree with the formula shown (this is what fixes the EBITDA-class bug). Non-
    # arithmetic formulas (IF/logical/text) can't be evaluated and are left as-is - we do
    # NOT force a retry on them, or every logical exercise would regenerate ~2x for nothing.
    # Structural consistency (prompt references only real layout cells) still gates.
    [void](RT-RecomputeExpected $cand)
    if(RT-ExcelConsistent $cand){ break }
    # otherwise loop once more to try for a structurally consistent one
  }
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
# Column letter -> 1-based number ('A'->1, 'B'->2, 'AA'->27).
function Col-Num($col){
  $col = ([string]$col).ToUpper(); $num = 0
  foreach($ch in $col.ToCharArray()){ if($ch -ge 'A' -and $ch -le 'Z'){ $num = $num * 26 + ([int][char]$ch - 64) } }
  return $num
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
    # All notes go in ONE column, 2 to the right of the rightmost used cell, so a note
    # never overwrites a given or answer cell regardless of the AI's layout.
    $maxN = 2
    try{ foreach($g in @($exercise.layout.given)){ $n = Col-Num ([string]$g.cell -replace '[0-9]+',''); if($n -gt $maxN){ $maxN = $n } } }catch{}
    try{ foreach($a in @($exercise.layout.answerCells)){ $n = Col-Num ([string]$a.cell -replace '[0-9]+',''); if($n -gt $maxN){ $maxN = $n } } }catch{}
    $noteCol = Shift-Col 'A' ($maxN + 1)
    foreach($pc in $cells){
      if(-not $pc){ continue }
      $cell = ''; try{ $cell = ([string]$pc.cell).ToUpper() }catch{}
      if(-not $cell){ continue }
      $ok = $false; try{ $ok = [bool]$pc.ok }catch{}
      try{ $ac = $ws.Range($cell); $ac.Interior.Color = $(if($ok){ $GREEN }else{ $RED }); [void][Runtime.InteropServices.Marshal]::ReleaseComObject($ac) }catch{}
      $rowN = ($cell -replace '^[A-Za-z]+','')
      if($rowN){
        $note = $noteCol + $rowN
        # always clear the note cell so a re-check after a fix updates cleanly
        try{ $cc = $ws.Range($note); [void]$cc.ClearContents(); try{ $cc.Font.Italic = $false }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cc) }catch{}
        if(-not $ok){
          $wrong++
          $txt = 'should be ' + [string]$pc.expected
          $fm = ''; try{ $fm = [string]$pc.formula }catch{}
          if($fm){ $txt = $txt + '  (' + $fm + ')' }
          RT-SetCell $ws $note $txt
          try{ $cc = $ws.Range($note); try{ $cc.Font.Color = 192 }catch{}; try{ $cc.Font.Italic = $true }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cc) }catch{}
        }
      }
    }
    try{ [void]($ws.Columns.Item($noteCol).AutoFit()) }catch{}
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
  # GROUND IN WHAT THE STUDENT HAS ACTUALLY LEARNED. Only drill topics the watcher has
  # logged as covered in lessons - Mastery status exposed/shaky/solid. Topics never seen
  # in a lesson (unseen, or absent from Mastery) are excluded, so the run-through never
  # quizzes unlearned material. Cold-start safety: if nothing is covered yet, fall back to
  # the full in-scope set so the drill is never empty.
  $covered = @{}
  try{ if(Get-Command Get-Mastery -ErrorAction SilentlyContinue){ $mm = Get-Mastery; foreach($k in $mm.Keys){ $st=[string]$mm[$k].status; if($st -eq 'exposed' -or $st -eq 'shaky' -or $st -eq 'solid'){ $covered[[string]$k]=$true } } } }catch{}
  $gateToLearned = ($covered.Count -gt 0)
  $out = New-Object System.Collections.ArrayList
  foreach($t in $topics){
    if((Get-Command Test-DomainInScope -ErrorAction SilentlyContinue) -and -not (Test-DomainInScope $t.domain)){ continue }
    if($gateToLearned -and -not $covered.ContainsKey([string]$t.id)){ continue }   # not learned with me yet -> do not drill it
    $rec = RT-TopicRec $state $t.id
    [void]$out.Add(@{ id = [string]$t.id; name = [string]$t.topic; category = [string]$t.domain; state = $rec })
  }
  # v3 OBSERVED CURRICULUM: also drill what the coach actually watched + distilled. These
  # concepts ARE "what you learned with me," so they always belong in the pool (no gate),
  # alongside the covered curriculum. For a non-finance session the curriculum above is all
  # out-of-scope, so this becomes the entire pool - which is the whole point of v3. New ones
  # have no RT-state yet, so the picker treats them as unseen and drills them first.
  if(Get-Command Get-ObservedTopics -ErrorAction SilentlyContinue){
    try{ foreach($ot in @(Get-ObservedTopics)){ $oid=[string]$ot.id; if($oid){ [void]$out.Add(@{ id = $oid; name = [string]$ot.name; category = [string]$ot.category; state = $ot.state }) } } }catch{}
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

# Spaced-repetition tuning (SM-2-lite). Kept small and explicit.
$script:RTEaseStart = 2.3     # starting spacing multiplier for a fresh topic
$script:RTEaseMin   = 1.3     # floor so a lapsing topic never spaces out
$script:RTEaseDrop  = 0.2     # ease lost per miss
$script:RTEaseGain  = 0.1     # ease gained per spaced success (rep>=3)
$script:RTSolidReps = 2       # consecutive correct answers that make a level "solid"
$script:RTMissDue   = 1       # picks to wait before a missed topic is due again (re-drill soon)

# A2: Record one result into durable RT state and return the mastery transition.
# Returns @{ rec; becameSolid=[bool]; bumpedLevel=[bool] }.
# Scheduling (SM-2-lite over a global "pick clock" in state.clock that ticks once per
# recorded result, so "due" works independent of the in-memory sitting counter):
#   correct & not retry -> streak++, reps++; interval grows (rep1->1, rep2->3,
#     rep>=3 -> round(prev interval * ease)); due = clock + interval; ease nudges up
#     on a spaced success. reps>=RTSolidReps -> add level to mastered (dedupe),
#     becameSolid, bump level capped at 2 (bumpedLevel if changed). Streak resets on
#     becameSolid (kept from the original) but reps/interval continue the schedule.
#   correct & retry -> consolidation only (no streak/reps/interval progression).
#   wrong -> streak=0, reps=0, interval=0, lapses++, ease drops (floored), and
#     due = clock + RTMissDue so the miss resurfaces within the next pick or two.
# Always attempts++ / correct++ as appropriate; set lastSeen; tick clock; save.
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
  # Advance the global pick clock first so 'due' offsets are measured from "now".
  $clock = 0; try{ $clock = [int]$state.clock }catch{ $clock = 0 }
  $clock = $clock + 1; $state.clock = $clock
  # Normalize scheduling fields off whatever the (possibly old) record carried.
  $reps = 0; try{ $reps = [int]$rec.reps }catch{ $reps = 0 }
  $interval = 0; try{ $interval = [int]$rec.interval }catch{ $interval = 0 }
  $ease = $script:RTEaseStart; try{ if($null -ne $rec.ease){ $ease = [double]$rec.ease } }catch{}
  if($ease -lt $script:RTEaseMin){ $ease = $script:RTEaseMin }
  $lapses = 0; try{ $lapses = [int]$rec.lapses }catch{ $lapses = 0 }
  $mastered = @(); if($rec.mastered){ $mastered = @($rec.mastered | ForEach-Object { [int]$_ }) }
  $becameSolid = $false
  $bumpedLevel = $false
  if($ok -and -not $retry){
    $rec.streak = $rec.streak + 1
    $reps = $reps + 1
    if($reps -le 1){ $interval = 3 }       # after 1 correct, wait ~3 picks (was 1 - too soon, felt like a loop)
    elseif($reps -eq 2){ $interval = 8 }   # after 2 correct (now graduated), space out ~8 picks before any review
    else { $interval = [int][math]::Round([math]::Max(1,$interval) * $ease); $ease = [math]::Min(3.0, $ease + $script:RTEaseGain) }
    if($interval -lt 1){ $interval = 1 }
    if($reps -ge $script:RTSolidReps){
      if($mastered -notcontains $lvl){ $mastered = @($mastered + $lvl) }
      $becameSolid = $true
      $rec.streak = 0
      $newLevel = [math]::Min(2, $rec.level + 1)
      if($newLevel -ne $rec.level){ $rec.level = $newLevel; $bumpedLevel = $true }
    }
  } elseif($ok -and $retry){
    # consolidation only - no schedule progression.
  } else {
    $rec.streak = 0
    $reps = 0
    $interval = 0
    $lapses = $lapses + 1
    $ease = [math]::Max($script:RTEaseMin, $ease - $script:RTEaseDrop)
  }
  $rec.reps = [int]$reps
  $rec.interval = [int]$interval
  $rec.ease = [double]$ease
  $rec.lapses = [int]$lapses
  # Set the next due tick. A miss is due almost immediately; a correct answer waits
  # its interval; a consolidation retry keeps the existing due.
  if(-not $ok){ $rec.due = $clock + $script:RTMissDue }
  elseif(-not $retry){ $rec.due = $clock + $interval }
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
# Spaced-repetition ordering (first non-empty bucket wins); never returns
# $lastTopicId unless it is the only candidate. A topic is "due" when its scheduled
# due-tick has been reached (rec.due <= the global pick clock). "Solid" = its mastered
# list contains the ceiling (2). Buckets, in priority order:
#  (a) DUE REVIEW OF MISSES: seen + previously lapsed + due (most overdue first) -
#      served one level below current (min 1) so a miss comes back gentler and SOON.
#  (b) UNSEEN: attempts==0, tier-ordered (must first). The first few picks of a
#      sitting (itemsThisSitting<3) intro a must-tier unseen topic, as before.
#  (c) WEAK / DUE: due-but-not-yet-solid topics, plus perf's Get-WeakTopics, lowest
#      streak first - served one level below current (min 1).
#  (d) EVERYTHING ELSE: lowest streak, then most overdue, then least-recently-seen.
# Light randomization: within the chosen bucket we pick from the few front-runners
# rather than always index 0, so the drill does not repeat an identical order.
function RT-PickNext($state,$itemsThisSitting,$lastTopicId,$recentIds){
  $items = 0; try{ $items = [int]$itemsThisSitting }catch{ $items = 0 }
  $lastId = [string]$lastTopicId
  $recent = @(); try{ if($recentIds){ $recent = @($recentIds | ForEach-Object { [string]$_ }) } }catch{}   # last few served concepts, to avoid back-to-back repeats
  $topics = @(); try{ $topics = @(Get-RTTopics) }catch{}
  if($topics.Count -eq 0){ return @{ topicId=''; level=1 } }
  # The global pick clock: prefer the passed-in state, fall back to a fresh load.
  $clock = 0
  try{ if($state -and ($null -ne $state.clock)){ $clock = [int]$state.clock } }catch{}
  if($clock -le 0){ try{ $clock = [int](RT-LoadState).clock }catch{ $clock = 0 } }
  $tierMap = RT-TierMap
  # Annotate each in-scope topic with the fields the buckets sort on.
  $rows = New-Object System.Collections.ArrayList
  foreach($t in $topics){
    $id = [string]$t.id
    $rec = $t.state
    $lvl = 1; try{ $lvl = [int]$rec.level }catch{ $lvl = 1 }
    $streak = 0; try{ $streak = [int]$rec.streak }catch{ $streak = 0 }
    $att = 0; try{ $att = [int]$rec.attempts }catch{ $att = 0 }
    $seen = ''; try{ $seen = [string]$rec.lastSeen }catch{ $seen = '' }
    $due = 0; try{ if($null -ne $rec.due){ $due = [int]$rec.due } }catch{ $due = 0 }
    $lapses = 0; try{ if($null -ne $rec.lapses){ $lapses = [int]$rec.lapses } }catch{ $lapses = 0 }
    $mastered = @(); try{ if($rec.mastered){ $mastered = @($rec.mastered | ForEach-Object { [int]$_ }) } }catch{}
    $solid = (@($mastered).Count -ge 1)   # GRADUATED once the topic is mastered at ANY level (2 correct in a row). Fast graduation = understood concepts leave the active rotation instead of looping; they only return as spaced review (longer interval) at the bumped-up level.
    $isDue = (($att -gt 0) -and ($due -le $clock))     # seen and its scheduled wait elapsed
    $overdue = $clock - $due                            # bigger = more overdue
    $tier = ''; if($tierMap.ContainsKey($id)){ $tier = $tierMap[$id] }
    $tr=(RT-TierRank $tier); if($id -like 'obs-*'){ $tr=-1 }   # v3: a just-watched concept outranks the fixed curriculum, so "drill what I watched" surfaces first
    [void]$rows.Add(@{ id=$id; level=$lvl; streak=$streak; attempts=$att; lastSeen=$seen; due=$due; lapses=$lapses; solid=$solid; isDue=$isDue; overdue=$overdue; tierRank=$tr })
  }
  $rows = @($rows.ToArray())
  # Helper: pick from a candidate list honouring the never-repeat-last rule, with a
  # little randomization across the front-runners. $spread = how many of the leading
  # candidates are eligible for the random draw (1 = strict order, no randomization).
  $choose = {
    param($cands,$lvlOf,$spread)
    $cands = @($cands)
    if($cands.Count -eq 0){ return $null }
    # Prefer candidates that are neither the last-served nor recently served. If NOTHING here is
    # fresh, YIELD (return null) so the next bucket can add variety - this is what stops the
    # picker ping-ponging between the only two due topics instead of pulling in unseen ones. A
    # global fallback at the end guarantees a pick once every bucket has yielded.
    $use = @($cands | Where-Object { ($_.id -ne $lastId) -and ($recent -notcontains $_.id) })   # @() so a single match stays a list, not a bare hashtable
    if($use.Count -eq 0){ return $null }
    $sp = 1; try{ $sp = [int]$spread }catch{ $sp = 1 }
    if($sp -lt 1){ $sp = 1 }
    $top = [math]::Min($sp, $use.Count)
    $idx = 0; if($top -gt 1){ try{ $idx = Get-Random -Minimum 0 -Maximum $top }catch{ $idx = 0 } }
    $pick = $use[$idx]
    $lvl = 1; if($lvlOf){ $lvl = (& $lvlOf $pick) }
    return @{ topicId=$pick.id; level=$lvl }
  }
  $lvlBelow = { param($p) [math]::Max(1, [int]$p.level - 1) }
  $lvlAt    = { param($p) [math]::Max(1, [int]$p.level) }
  # (a0) v3: a JUST-WATCHED concept that hasn't been drilled yet is the TOP priority - the
  # whole point of the product is "drill what I just watched," so a fresh observed concept
  # outranks even due review of old misses. (Once drilled it leaves this bucket and follows
  # normal spaced-rep below.)
  $freshObs = @($rows | Where-Object { ([string]$_.id -like 'obs-*') -and ($_.attempts -le 0) } | Sort-Object @{Expression={$_.id}})
  $r = (& $choose $freshObs { param($p) 1 } 1)
  if($r){ return $r }
  # (a) Due review of previously-missed topics: most overdue first. Resurfaces misses.
  $dueMiss = @($rows | Where-Object { $_.isDue -and ($_.lapses -gt 0) } | Sort-Object @{Expression={$_.overdue};Descending=$true}, @{Expression={$_.streak}}, @{Expression={$_.id}})
  $r = (& $choose $dueMiss $lvlBelow 2)
  if($r){ return $r }
  # (b) Unseen topics, tier-ordered (must first), then by id for stability.
  $unseen = @($rows | Where-Object { $_.attempts -le 0 } | Sort-Object @{Expression={$_.tierRank}}, @{Expression={$_.id}})
  if($items -lt 3){
    $unseenMust = @($unseen | Where-Object { $_.tierRank -le 0 })
    $r = (& $choose $unseenMust { param($p) 1 } 1)
    if($r){ return $r }
  }
  $r = (& $choose $unseen { param($p) 1 } 2)
  if($r){ return $r }
  # (c) Weak/due: due-but-not-solid topics + perf's flagged weak topics, lowest streak.
  $weakIds = @()
  if(Get-Command Get-WeakTopics -ErrorAction SilentlyContinue){ try{ $weakIds = @(Get-WeakTopics 5) }catch{} }
  $weakRows = @($rows | Where-Object { (($_.isDue -and (-not $_.solid)) -or ($weakIds -contains $_.id)) } | Sort-Object @{Expression={$_.streak}}, @{Expression={$_.overdue};Descending=$true}, @{Expression={$_.id}})
  $r = (& $choose $weakRows $lvlBelow 2)
  if($r){ return $r }
  # (d) Everything else: lowest streak, then most overdue, then least-recently-seen.
  # Solid topics sort last here (they are not due), so mastered work spaces out.
  $rest = @($rows | Sort-Object @{Expression={$_.streak}}, @{Expression={$_.overdue};Descending=$true}, @{Expression={$_.lastSeen}}, @{Expression={$_.id}})
  $r = (& $choose $rest $lvlAt 2)
  if($r){ return $r }
  # Global fallback: every bucket yielded (all their candidates were the last/recent ones).
  # Pick the least-recently-served topic that isn't the very last one, ignoring the recency
  # window - guarantees a pick and still never repeats back-to-back.
  $rest2 = @($rows | Where-Object { $_.id -ne $lastId } | Sort-Object @{Expression={$_.lastSeen}}, @{Expression={$_.id}})
  if($rest2.Count -eq 0){ $rest2 = @($rows) }
  $only = $rest2[0]
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
  $total = 0
  $solid = 0
  $areaOrder = New-Object System.Collections.ArrayList
  $areaTotal = @{}
  $areaSolid = @{}
  foreach($t in $cur){
    $id = [string]$t.id
    $dom = [string]$t.domain; if(-not $dom){ $dom = '(other)' }
    if((Get-Command Test-DomainInScope -ErrorAction SilentlyContinue) -and -not (Test-DomainInScope $t.domain)){ continue }
    $total = $total + 1
    if(-not $areaTotal.ContainsKey($dom)){ [void]$areaOrder.Add($dom); $areaTotal[$dom] = 0; $areaSolid[$dom] = 0 }
    $areaTotal[$dom] = $areaTotal[$dom] + 1
    $rec = RT-TopicRec $state $id
    $mastered = @(); if($rec.mastered){ $mastered = @($rec.mastered | ForEach-Object { [int]$_ }) }
    $isSolid = (@($mastered).Count -ge 1)   # scoreboard counts a topic solid once mastered at any level (matches RT-PickNext graduation)
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
