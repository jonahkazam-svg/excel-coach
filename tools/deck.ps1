# deck.ps1 - content engine. Generates a structured flashcard "deck" from the
# 57-node curriculum (curriculum.ps1 nodes / Curriculum.md) using the OpenAI API
# and caches it to data/deck.json. ASCII only. PowerShell 5.1. JSON is UTF-8, no BOM.
#
# Public functions:
#   Build-Deck [-Force]      - for each curriculum topic, call the model to produce
#                              cards; write data/deck.json. No-op (returns existing
#                              path) if deck.json already exists unless -Force.
#   Get-Deck                 - load and return deck.json as a PS object (cached).
#   Get-TopicCards($topicId) - return the cards array for one topic id (empty if none).
#
# This module is standalone but is also dot-sourced by watch.ps1 alongside
# curriculum.ps1. It matches watch.ps1's API pattern exactly: the same curl.exe
# invocation, the same Bearer-key auth, the same payload-to-temp-file approach, and
# the same model string (WATCH_MODEL, default gpt-5.5) with the gpt-5 payload shape
# (max_completion_tokens + reasoning_effort) vs the legacy shape (max_tokens + temperature).

# Repo root is the parent of tools/. data/ lives there.
$script:XCDeckRoot = Split-Path $PSScriptRoot -Parent
$script:XCDeckEnv  = Join-Path $script:XCDeckRoot ".env"
$script:XCDeckDataDir = Join-Path $script:XCDeckRoot "data"
$script:XCDeckPath = Join-Path $script:XCDeckDataDir "deck.json"
$script:XCDeckCache = $null

# Read a value from .env (mirrors watch.ps1's Read-EnvVal). Named XCDeck- to avoid
# clobbering watch.ps1's own Read-EnvVal when both are dot-sourced into one scope.
function XCDeck-ReadEnv($name,$default){
  if(-not (Test-Path $script:XCDeckEnv)){ return $default }
  $l = Get-Content $script:XCDeckEnv | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1
  if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default }
}

function XCDeck-WriteUtf8NoBom($path,$text){
  [IO.File]::WriteAllText($path,$text,(New-Object System.Text.UTF8Encoding($false)))
}

# Make sure Get-Curriculum is available. When dot-sourced by watch.ps1 it already is
# (the guard skips re-loading); when run standalone, pull in curriculum.ps1 from the
# same tools/ folder. This runs at module load so the curriculum functions land in
# this scope (a dot-source inside a function would only populate that function scope).
if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
  $script:XCDeckCurrPs1 = Join-Path $PSScriptRoot "curriculum.ps1"
  if(Test-Path $script:XCDeckCurrPs1){ try{ . $script:XCDeckCurrPs1 }catch{} }
}

# Build the OpenAI chat payload for one topic, matching watch.ps1's content-generation
# calls: gpt-5 models use max_completion_tokens + reasoning_effort (no temperature);
# older models use max_tokens + temperature. $model defaults to WATCH_MODEL (gpt-5.5).
function XCDeck-BuildPayload($model,$sys,$user){
  if($model -match '^gpt-5'){
    return (@{ model=$model; max_completion_tokens=2000; reasoning_effort='medium'; messages=@(@{role='system';content=$sys},@{role='user';content=$user}) } | ConvertTo-Json -Depth 10)
  } else {
    return (@{ model=$model; max_tokens=1600; temperature=0; messages=@(@{role='system';content=$sys},@{role='user';content=$user}) } | ConvertTo-Json -Depth 10)
  }
}

# The generation prompt. Plain ASCII. Demands concise, IB-accurate cards; formulas as
# plain text; for quiz-able cards exactly 4 plausible choices and one correct answer index.
$script:XCDeckSys = @'
You generate study flashcards for a finance student prepping for an investment-banking fellowship. You will be given ONE curriculum topic (an id, a category, and a topic name). Produce a small set of high-quality cards covering the most important things an analyst must know cold about THAT topic.

Output ONLY a JSON array (no prose, no markdown, no code fences). Each element is an object with these fields:
  "type"    - one of: "flashcard", "definition", "formula"
  "front"   - for a definition/flashcard card, JUST THE TERM ITSELF (e.g. "Revenue", "Working capital", "Accounts receivable", "WACC", "Free cash flow") - NOT a "what is..." question. For a formula card, the concept name. For a quiz card, the classification prompt.
  "back"    - a clear, plain-English DEFINITION of that term, plus a short note on why it matters or how an analyst uses it. Complete enough to actually learn from - a full sentence or two, never a single word.
  "choices" - OPTIONAL. Include ONLY when the card works as a multiple-choice question. When present it MUST be an array of exactly 4 plausible, distinct answer strings, exactly one of which is correct.
  "answer"  - OPTIONAL. Include ONLY when "choices" is present. An integer 0..3 that is the index of the correct choice in "choices".

Rules:
- Produce 4 to 7 cards for the topic.
- Cover FOUR things for the topic, mixed across the cards: (1) DEFINITIONS - front = the term itself, back = its plain-English meaning; (2) FORMULAS - the key calculations written as plain text; (3) CATEGORIES / CLASSIFICATIONS - what counts as what (e.g. operating vs investing vs financing, asset vs liability vs equity, increases vs decreases cash, current vs non-current); (4) CONTEXT - what a concept means or does in a specific situation (e.g. front "An increase in accounts receivable - effect on cash?", back "Decreases cash - you sold but have not collected"). NEVER phrase a definition's front as a "What is...?" question - just state the term.
- Write all formulas as PLAIN TEXT (for example: EBIT = Revenue - COGS - Operating Expenses; or Enterprise Value = Equity Value + Total Debt - Cash). Never use special symbols.
- Use quiz cards (exactly 4 "choices" + the correct "answer" index) for the CATEGORY/CLASSIFICATION and CONTEXT cards especially - test what classifies as what and how a concept behaves in a situation. Wrong choices must be plausible common confusions, never silly. Aim for at least 2-3 quiz cards per topic where the subject supports it.
- Keep "front" and "back" tight: no filler, no preamble, accurate to standard IB/accounting convention.
- Plain ASCII only. No characters outside basic ASCII. Use straight quotes, hyphens, and -> for arrows if needed.
- Output the JSON array and nothing else.
'@

# Call the model for one topic and return an array of validated card hashtables, or
# $null on any failure. Card ids are assigned by the caller (<topicId>-<n>).
function XCDeck-GenerateCards($node,$key,$model){
  $user = "Curriculum topic:`n  id: "+[string]$node.id+"`n  category: "+[string]$node.domain+"`n  topic: "+[string]$node.topic+"`n`nGenerate the cards for this topic as a JSON array per the rules."
  $pay = XCDeck-BuildPayload $model $script:XCDeckSys $user
  $bf = Join-Path $env:TEMP ("xc_deck_"+([string]$node.id -replace '[^A-Za-z0-9]','')+".json")
  XCDeck-WriteUtf8NoBom $bf $pay
  $rr = & curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf)
  try{ Remove-Item $bf -ErrorAction SilentlyContinue }catch{}
  $jj = $null; try{ $jj = $rr | ConvertFrom-Json }catch{}
  if(-not $jj -or -not $jj.choices){ return $null }
  $content = [string]$jj.choices[0].message.content
  if(-not $content){ return $null }
  # Strip any accidental code fences and isolate the JSON array.
  $content = ($content -replace '(?s)^.*?```(?:json)?',''); $content = ($content -replace '(?s)```.*$','')
  $content = $content.Trim()
  $s = $content.IndexOf('['); $e = $content.LastIndexOf(']')
  if($s -lt 0 -or $e -le $s){ return $null }
  $content = $content.Substring($s,$e-$s+1)
  $parsed = $null; try{ $parsed = $content | ConvertFrom-Json }catch{}
  if($null -eq $parsed){ return $null }
  if($parsed -isnot [System.Array]){ $parsed = @($parsed) }
  return ,$parsed
}

# Coerce/validate one raw model card object into the deck.json card schema. Returns a
# hashtable or $null if the card is unusable.
function XCDeck-NormalizeCard($raw,$cardId){
  if($null -eq $raw){ return $null }
  $type  = [string]$raw.type
  $front = [string]$raw.front
  $back  = [string]$raw.back
  if(-not $front -or -not $back){ return $null }
  if($type -ne 'flashcard' -and $type -ne 'definition' -and $type -ne 'formula'){ $type = 'flashcard' }
  $card = [ordered]@{ id=$cardId; type=$type; front=$front.Trim(); back=$back.Trim() }
  # Quiz-able only when there are exactly 4 choices and a valid answer index.
  $choices = $null
  if($null -ne $raw.choices){ $choices = @($raw.choices | ForEach-Object { [string]$_ }) }
  if($choices -and $choices.Count -eq 4){
    $ans = $null
    try{ $ans = [int]$raw.answer }catch{ $ans = $null }
    if($null -ne $ans -and $ans -ge 0 -and $ans -le 3){
      $card.choices = $choices
      $card.answer = $ans
    }
  }
  return $card
}

# Build the deck: one model call per curriculum topic, assembled into the deck.json
# schema and written UTF-8 (no BOM). Resilient - a single topic's failure is logged
# and the build continues. No-op (returns existing path) if deck.json exists unless -Force.
function Build-Deck {
  [CmdletBinding()]
  param([switch]$Force)

  if((Test-Path $script:XCDeckPath) -and (-not $Force)){
    Write-Host ("deck.json already exists at "+$script:XCDeckPath+" (use -Force to rebuild).")
    return $script:XCDeckPath
  }

  if(-not (Test-Path $script:XCDeckDataDir)){ New-Item -ItemType Directory -Force -Path $script:XCDeckDataDir | Out-Null }

  $key = XCDeck-ReadEnv "OPENAI_API_KEY" ""
  if(-not $key -or $key -like '*REPLACE_ME*'){ Write-Host "Build-Deck: no OPENAI_API_KEY in .env - cannot build."; return $null }
  $model = XCDeck-ReadEnv "DECK_MODEL" "gpt-4o-mini"

  if(-not (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){ Write-Host "Build-Deck: Get-Curriculum not available - is curriculum.ps1 present?"; return $null }
  $cur = @(Get-Curriculum)
  if($cur.Count -eq 0){ Write-Host "Build-Deck: curriculum is empty - nothing to build."; return $null }

  $topics = New-Object System.Collections.ArrayList
  $okCount = 0; $failCount = 0
  foreach($n in $cur){
    $cards = New-Object System.Collections.ArrayList
    try{
      $raw = XCDeck-GenerateCards $n $key $model
      if($null -ne $raw){
        $i = 1
        foreach($rc in $raw){
          $cid = ([string]$n.id)+"-"+$i
          $card = XCDeck-NormalizeCard $rc $cid
          if($null -ne $card){ [void]$cards.Add($card); $i++ }
        }
      }
    }catch{
      Write-Host ("Build-Deck: topic '"+[string]$n.id+"' failed: "+$_.Exception.Message)
    }
    if($cards.Count -gt 0){ $okCount++ } else { $failCount++; Write-Host ("Build-Deck: topic '"+[string]$n.id+"' produced no cards - continuing.") }
    [void]$topics.Add([ordered]@{ id=[string]$n.id; name=[string]$n.topic; category=[string]$n.domain; cards=@($cards.ToArray()) })
  }

  $deck = [ordered]@{
    version     = 1
    generatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    topics      = @($topics.ToArray())
  }
  $json = $deck | ConvertTo-Json -Depth 12
  XCDeck-WriteUtf8NoBom $script:XCDeckPath $json
  $script:XCDeckCache = $null  # invalidate in-process cache
  Write-Host ("Build-Deck: wrote "+$script:XCDeckPath+" ("+$okCount+" topics with cards, "+$failCount+" empty).")
  return $script:XCDeckPath
}

# Load and return deck.json as a PS object. Cached in a script-scope variable so repeat
# calls do not re-read disk. Returns $null if deck.json does not exist.
function Get-Deck {
  if($null -ne $script:XCDeckCache){ return $script:XCDeckCache }
  if(-not (Test-Path $script:XCDeckPath)){ return $null }
  try{
    $raw = Get-Content $script:XCDeckPath -Raw
    $script:XCDeckCache = ($raw | ConvertFrom-Json)
  }catch{
    $script:XCDeckCache = $null
  }
  return $script:XCDeckCache
}

# Return the cards array for one topic id (empty array if the topic/deck is missing).
function Get-TopicCards($topicId){
  if(-not $topicId){ return @() }
  $deck = Get-Deck
  if($null -eq $deck -or $null -eq $deck.topics){ return @() }
  foreach($t in $deck.topics){
    if([string]$t.id -eq [string]$topicId){
      if($null -eq $t.cards){ return @() }
      return @($t.cards)
    }
  }
  return @()
}
