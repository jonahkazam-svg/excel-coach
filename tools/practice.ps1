# practice.ps1 - spaced-repetition (SM-2) + quiz engine for excel-coach.
# Dot-sourced by watch.ps1 alongside curriculum.ps1 / deck.ps1. ASCII-only,
# PowerShell 5.1 compatible. State lives in data/review-state.json (UTF-8, no BOM).
# Card pool comes from the deck: Get-Deck if defined at runtime, else data/deck.json.
# Never hard-fails at load time if the deck or state is missing/corrupt - starts fresh.

# Resolve <repo>/data relative to this file (tools/practice.ps1 -> ../data).
if($PSScriptRoot){ $script:XPRoot = Split-Path $PSScriptRoot -Parent } else { $script:XPRoot = Split-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) -Parent }
$script:XPDataDir   = Join-Path $script:XPRoot "data"
$script:XPDeckPath  = Join-Path $script:XPDataDir "deck.json"
$script:XPStatePath = Join-Path $script:XPDataDir "review-state.json"

function XP-Utf8NoBom { return (New-Object System.Text.UTF8Encoding($false)) }

# ISO 8601 round-trip ("o") timestamp for "now" (or a supplied DateTime).
function XP-NowIso($d){ if($d -is [datetime]){ return $d.ToString("o") } return (Get-Date).ToString("o") }

# Parse an ISO timestamp back to a DateTime; $null on anything unparseable.
function XP-ParseIso($s){
  if(-not $s){ return $null }
  try{ return [datetime]::Parse([string]$s,[System.Globalization.CultureInfo]::InvariantCulture,[System.Globalization.DateTimeStyles]::RoundtripKind) }catch{ return $null }
}

function XP-EnsureDataDir {
  try{ if(-not (Test-Path $script:XPDataDir)){ New-Item -ItemType Directory -Force -Path $script:XPDataDir | Out-Null } }catch{}
}

# Load the deck as a PS object. Prefer a Get-Deck function if one exists at
# runtime (deck.ps1), otherwise read data/deck.json directly. Returns $null
# (never throws) if the deck is missing or unreadable.
function XP-LoadDeck {
  $g = Get-Command Get-Deck -ErrorAction SilentlyContinue
  if($g){ try{ $d = Get-Deck; if($d){ return $d } }catch{} }
  if(-not (Test-Path $script:XPDeckPath)){ return $null }
  try{
    $raw = [IO.File]::ReadAllText($script:XPDeckPath)
    if(-not $raw -or -not $raw.Trim()){ return $null }
    return ($raw | ConvertFrom-Json)
  }catch{ return $null }
}

# Flatten the deck into a single list of card objects, each tagged with its
# owning topicId so callers can group/filter without re-walking the deck.
function XP-AllCards {
  $deck = XP-LoadDeck
  $out = New-Object System.Collections.ArrayList
  if(-not $deck -or -not $deck.topics){ return $out }
  foreach($t in $deck.topics){
    if(-not $t){ continue }
    $tid = [string]$t.id
    if(-not $t.cards){ continue }
    foreach($c in $t.cards){
      if(-not $c){ continue }
      $cid = [string]$c.id
      if(-not $cid){ continue }
      [void]$out.Add([PSCustomObject]@{
        id      = $cid
        topicId = $tid
        type    = [string]$c.type
        front   = [string]$c.front
        back    = [string]$c.back
        choices = $c.choices
        answer  = $c.answer
        raw     = $c
      })
    }
  }
  return $out
}

# Load review-state.json into a normalized hashtable-backed object. Robust to a
# missing, empty, or corrupt file - in any of those cases it returns a fresh,
# valid state. The shape mirrors the spec schema:
#   { cards = @{ <id> = @{ ease; intervalDays; due; reps; lapses; lastRated } };
#     history = @( @{ cardId; quality; at } ); streakDays; lastStudied }
function XP-LoadState {
  $state = @{ cards = @{}; history = (New-Object System.Collections.ArrayList); streakDays = 0; lastStudied = $null }
  if(-not (Test-Path $script:XPStatePath)){ return $state }
  $obj = $null
  try{
    $raw = [IO.File]::ReadAllText($script:XPStatePath)
    if(-not $raw -or -not $raw.Trim()){ return $state }
    $obj = $raw | ConvertFrom-Json
  }catch{ return $state }
  if(-not $obj){ return $state }
  # cards (ConvertFrom-Json yields a PSCustomObject; copy into a hashtable)
  if($obj.cards){
    foreach($p in $obj.cards.PSObject.Properties){
      $c = $p.Value
      if(-not $c){ continue }
      $ease = 2.5; if($null -ne $c.ease){ try{ $ease = [double]$c.ease }catch{} }
      $iv = 0;     if($null -ne $c.intervalDays){ try{ $iv = [int]$c.intervalDays }catch{} }
      $reps = 0;   if($null -ne $c.reps){ try{ $reps = [int]$c.reps }catch{} }
      $lap = 0;    if($null -ne $c.lapses){ try{ $lap = [int]$c.lapses }catch{} }
      $state.cards[[string]$p.Name] = @{
        ease         = $ease
        intervalDays = $iv
        due          = $(if($c.due){ [string]$c.due } else { $null })
        reps         = $reps
        lapses       = $lap
        lastRated    = $(if($c.lastRated){ [string]$c.lastRated } else { $null })
      }
    }
  }
  # history
  if($obj.history){
    foreach($h in $obj.history){
      if(-not $h){ continue }
      [void]$state.history.Add(@{ cardId = [string]$h.cardId; quality = $(try{ [int]$h.quality }catch{ 0 }); at = [string]$h.at })
    }
  }
  if($null -ne $obj.streakDays){ try{ $state.streakDays = [int]$obj.streakDays }catch{} }
  if($obj.lastStudied){ $state.lastStudied = [string]$obj.lastStudied }
  return $state
}

# Persist state to review-state.json as UTF-8 with NO BOM. Builds an ordered
# PSCustomObject so the JSON keys come out stable and readable.
function XP-SaveState($state){
  if(-not $state){ return }
  XP-EnsureDataDir
  $cardsObj = [ordered]@{}
  foreach($id in ($state.cards.Keys | Sort-Object)){
    $c = $state.cards[$id]
    $cardsObj[$id] = [ordered]@{
      ease         = [double]$c.ease
      intervalDays = [int]$c.intervalDays
      due          = $c.due
      reps         = [int]$c.reps
      lapses       = [int]$c.lapses
      lastRated    = $c.lastRated
    }
  }
  $histArr = @()
  foreach($h in $state.history){ $histArr += [ordered]@{ cardId = [string]$h.cardId; quality = [int]$h.quality; at = [string]$h.at } }
  $root = [ordered]@{
    cards       = $cardsObj
    history     = $histArr
    streakDays  = [int]$state.streakDays
    lastStudied = $state.lastStudied
  }
  $json = $root | ConvertTo-Json -Depth 8
  try{ [IO.File]::WriteAllText($script:XPStatePath, $json, (XP-Utf8NoBom)) }catch{}
}

# Return a fresh per-card review record (a brand-new/unseen card). Such a card
# is due immediately (due = now) so it gets surfaced on the next review.
function XP-NewCardRecord($nowIso){
  return @{ ease = 2.5; intervalDays = 0; due = $nowIso; reps = 0; lapses = 0; lastRated = $null }
}

# ----------------------------------------------------------------------------
# Public: Get-DueCards
# Return up to $limit cards whose review record is due (due <= now). New/unseen
# cards (no record yet) count as due and are SEEDED into state so their due date
# is tracked from now on. Cards no longer present in the deck are skipped. Pull
# the pool from the deck; if the deck is missing, returns an empty list.
# ----------------------------------------------------------------------------
function Get-DueCards([int]$limit = 20){
  $cards = XP-AllCards
  $result = New-Object System.Collections.ArrayList
  if($cards.Count -eq 0){ return $result }
  $state = XP-LoadState
  $now = Get-Date
  $nowIso = XP-NowIso $now
  $seeded = $false
  # Course-scope filter: if a scope is set, build the in-scope topic-id set once and
  # skip out-of-scope cards. No scope -> no filtering (current behavior preserved).
  $scopeIds = $null
  if((Get-Command Get-ScopeDomains -ErrorAction SilentlyContinue) -and (@(Get-ScopeDomains).Count -gt 0)){
    $scopeIds = @{}
    foreach($t in (Get-Curriculum)){ if(Test-DomainInScope $t.domain){ $scopeIds[[string]$t.id] = $true } }
  }
  # Ground in what the student has actually learned: only surface cards for topics the
  # watcher logged as covered in lessons (Mastery exposed/shaky/solid). Cold-start: if
  # nothing is covered yet, skip this filter so practice is never empty.
  $learnedIds = $null
  try{ if(Get-Command Get-Mastery -ErrorAction SilentlyContinue){ $mm=Get-Mastery; $tmp=@{}; foreach($k in $mm.Keys){ $st=[string]$mm[$k].status; if($st -eq 'exposed' -or $st -eq 'shaky' -or $st -eq 'solid'){ $tmp[[string]$k]=$true } }; if($tmp.Count -gt 0){ $learnedIds=$tmp } } }catch{}
  foreach($card in $cards){
    $cid = $card.id
    if($scopeIds -and -not $scopeIds.ContainsKey([string]$card.topicId)){ continue }
    if($learnedIds -and -not $learnedIds.ContainsKey([string]$card.topicId)){ continue }   # not learned with me yet -> skip
    $rec = $state.cards[$cid]
    if(-not $rec){
      # unseen -> seed as due now
      $rec = XP-NewCardRecord $nowIso
      $state.cards[$cid] = $rec
      $seeded = $true
    }
    $dueDt = XP-ParseIso $rec.due
    $isDue = $true
    if($dueDt){ $isDue = ($dueDt -le $now) }
    if($isDue){
      [void]$result.Add([PSCustomObject]@{
        id           = $cid
        topicId      = $card.topicId
        type         = $card.type
        front        = $card.front
        back         = $card.back
        choices      = $card.choices
        answer       = $card.answer
        due          = $rec.due
        ease         = [double]$rec.ease
        intervalDays = [int]$rec.intervalDays
        reps         = [int]$rec.reps
        lapses       = [int]$rec.lapses
      })
    }
  }
  if($seeded){ XP-SaveState $state }
  if($limit -lt 0){ $limit = 0 }
  if($result.Count -gt $limit){ $result = $result.GetRange(0, $limit) }
  return $result
}

# ----------------------------------------------------------------------------
# Public: Rate-Card
# Grade a single card (quality 0..5) and apply SM-2, persisting to state.
# Maintains the append-only history, the study streak, and lastStudied.
# Returns the updated per-card record (or $null if cardId was empty).
# ----------------------------------------------------------------------------
function Rate-Card($cardId, [int]$quality){
  if(-not $cardId){ return $null }
  $cardId = [string]$cardId
  if($quality -lt 0){ $quality = 0 }
  if($quality -gt 5){ $quality = 5 }
  $state = XP-LoadState
  $now = Get-Date
  $nowIso = XP-NowIso $now
  $rec = $state.cards[$cardId]
  if(-not $rec){ $rec = XP-NewCardRecord $nowIso }

  $ease = [double]$rec.ease
  $reps = [int]$rec.reps
  $lapses = [int]$rec.lapses
  $interval = [int]$rec.intervalDays

  if($quality -lt 3){
    # lapse: reset reps, short interval, count the lapse
    $reps = 0
    $interval = 1
    $lapses = $lapses + 1
  } else {
    if($reps -eq 0){ $interval = 1 }
    elseif($reps -eq 1){ $interval = 6 }
    else { $interval = [int][math]::Round($interval * $ease, 0, [System.MidpointRounding]::AwayFromZero) }
    $reps = $reps + 1
  }

  # SM-2 ease update (always applied), floored at 1.3
  $ease = $ease + (0.1 - (5 - $quality) * (0.08 + (5 - $quality) * 0.02))
  if($ease -lt 1.3){ $ease = 1.3 }
  if($interval -lt 1){ $interval = 1 }

  $dueDt = $now.AddDays($interval)
  $rec.ease = $ease
  $rec.intervalDays = $interval
  $rec.reps = $reps
  $rec.lapses = $lapses
  $rec.lastRated = $nowIso
  $rec.due = XP-NowIso $dueDt
  $state.cards[$cardId] = $rec

  # append-only history
  [void]$state.history.Add(@{ cardId = $cardId; quality = $quality; at = $nowIso })

  # streak: increment when studying on a new calendar day that is the day after
  # the last study day; same day = no change; any gap = reset to 1.
  $today = $now.Date
  $last = XP-ParseIso $state.lastStudied
  if(-not $last){
    $state.streakDays = 1
  } else {
    $lastDay = $last.Date
    $diff = [int]($today - $lastDay).TotalDays
    if($diff -le 0){ if($state.streakDays -lt 1){ $state.streakDays = 1 } }
    elseif($diff -eq 1){ $state.streakDays = $state.streakDays + 1 }
    else { $state.streakDays = 1 }
  }
  $state.lastStudied = $nowIso

  XP-SaveState $state
  return $rec
}

# ----------------------------------------------------------------------------
# Public: New-Quiz
# Build an n-question multiple-choice quiz from the deck's quiz-able cards
# (cards that carry a non-empty choices[] array AND an integer answer index in
# range) for the given topic. Questions are returned in random order. Each
# question object exposes the prompt, the choices, the correct index, and ids.
# Returns an empty list if the topic has no quiz-able cards / the deck is gone.
# ----------------------------------------------------------------------------
function New-Quiz($topicId, [int]$n = 10){
  $out = New-Object System.Collections.ArrayList
  if(-not $topicId){ return $out }
  $topicId = [string]$topicId
  $cards = XP-AllCards
  if($cards.Count -eq 0){ return $out }
  $pool = New-Object System.Collections.ArrayList
  foreach($card in $cards){
    if($card.topicId -ne $topicId){ continue }
    $choices = $card.choices
    if(-not $choices){ continue }
    $count = 0
    try{ $count = @($choices).Count }catch{ $count = 0 }
    if($count -lt 2){ continue }
    if($null -eq $card.answer){ continue }
    $ans = -1
    try{ $ans = [int]$card.answer }catch{ continue }
    if($ans -lt 0 -or $ans -ge $count){ continue }
    [void]$pool.Add([PSCustomObject]@{
      id       = $card.id
      topicId  = $card.topicId
      question = $(if($card.front){ $card.front } else { $card.back })
      choices  = @($choices)
      answer   = $ans
    })
  }
  if($pool.Count -eq 0){ return $out }
  $shuffled = @($pool | Sort-Object { Get-Random })
  if($n -lt 0){ $n = 0 }
  $take = [Math]::Min($n, $shuffled.Count)
  for($i = 0; $i -lt $take; $i++){ [void]$out.Add($shuffled[$i]) }
  return $out
}

# ----------------------------------------------------------------------------
# Public: Get-PracticeStats
# Snapshot for the UI / struggle profile:
#   dueCount    - how many cards are currently due (incl. unseen)
#   totalCards  - total cards in the deck
#   streakDays  - current study streak (from state)
#   weakTopics  - topic ids ordered by total lapses (most-lapsed first)
# Does not mutate state (no seeding side effects).
# ----------------------------------------------------------------------------
function Get-PracticeStats {
  $cards = XP-AllCards
  $total = $cards.Count
  $state = XP-LoadState
  $now = Get-Date

  # map cardId -> topicId for lapse attribution
  $cardTopic = @{}
  foreach($card in $cards){ $cardTopic[$card.id] = $card.topicId }

  $due = 0
  foreach($card in $cards){
    $rec = $state.cards[$card.id]
    if(-not $rec){ $due++; continue }
    $dueDt = XP-ParseIso $rec.due
    if(-not $dueDt){ $due++ }
    elseif($dueDt -le $now){ $due++ }
  }

  # weak topics: sum lapses per topic across all recorded cards
  $lapsesByTopic = @{}
  foreach($id in $state.cards.Keys){
    $rec = $state.cards[$id]
    $lap = 0; try{ $lap = [int]$rec.lapses }catch{}
    if($lap -le 0){ continue }
    $tid = $cardTopic[$id]
    if(-not $tid){ $tid = "(unknown)" }
    if($lapsesByTopic.ContainsKey($tid)){ $lapsesByTopic[$tid] = $lapsesByTopic[$tid] + $lap }
    else { $lapsesByTopic[$tid] = $lap }
  }
  $weak = @()
  if($lapsesByTopic.Count -gt 0){
    $weak = @($lapsesByTopic.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object { $_.Key })
  }

  return [PSCustomObject]@{
    dueCount   = $due
    totalCards = $total
    streakDays = [int]$state.streakDays
    weakTopics = $weak
  }
}
