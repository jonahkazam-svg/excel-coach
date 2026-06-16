# perf.ps1 - the coach's performance memory. Records every flashcard / quiz
# answer per curriculum topic so the coach knows what you are good at, what you
# struggle with, and what to work on next. State lives in <repo>/data/perf.json.
# Separate from the SM-2 scheduler (practice.ps1): this is a plain right/wrong
# tally per topic. ASCII-only, PowerShell 5.1. Dot-sourced by watch.ps1.

function Perf-StatePath {
  $root = Split-Path $PSScriptRoot -Parent
  $dir = Join-Path $root 'data'
  if(-not (Test-Path $dir)){ try{ New-Item -ItemType Directory -Force -Path $dir | Out-Null }catch{} }
  return (Join-Path $dir 'perf.json')
}
function Perf-NewState { return @{ topics = @{}; updatedAt = '' } }
function Perf-NewRec { return @{ name=''; attempts=0; correct=0; wrong=0; lastSeen=''; recent=@() } }

function Perf-Load {
  $p = Perf-StatePath
  if(-not (Test-Path $p)){ return (Perf-NewState) }
  try {
    $raw = [IO.File]::ReadAllText($p)
    if(-not $raw -or $raw.Trim().Length -lt 2){ return (Perf-NewState) }
    $o = $raw | ConvertFrom-Json
    $st = Perf-NewState
    if($o.topics){
      foreach($prop in $o.topics.PSObject.Properties){
        $r = $prop.Value; $rec = Perf-NewRec
        foreach($k in @('name','attempts','correct','wrong','lastSeen','recent')){
          $v = $null; try{ $v = $r.$k }catch{}
          if($null -ne $v){ $rec[$k] = $v }
        }
        if($null -eq $rec.recent){ $rec.recent = @() }
        $st.topics[$prop.Name] = $rec
      }
    }
    if($o.updatedAt){ $st.updatedAt = [string]$o.updatedAt }
    return $st
  } catch { return (Perf-NewState) }
}

function Perf-Save($state){
  if(-not $state){ return }
  try {
    $state.updatedAt = (Get-Date).ToString('o')
    $json = $state | ConvertTo-Json -Depth 8
    [IO.File]::WriteAllText((Perf-StatePath), $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}

# Record one answer for a topic. $correct is coerced to bool. Returns the record.
function Record-Answer($topicId, $topicName, $correct){
  $topicId = [string]$topicId
  if(-not $topicId){ return $null }
  $ok = [bool]$correct
  $st = Perf-Load
  $rec = $null
  if($st.topics.ContainsKey($topicId)){ $rec = $st.topics[$topicId] } else { $rec = Perf-NewRec }
  if($topicName){ $rec.name = [string]$topicName }
  $rec.attempts = [int]$rec.attempts + 1
  if($ok){ $rec.correct = [int]$rec.correct + 1 } else { $rec.wrong = [int]$rec.wrong + 1 }
  $rec.lastSeen = (Get-Date).ToString('o')
  $r2 = @(); if($rec.recent){ $r2 = @($rec.recent) }
  $r2 += $(if($ok){ 1 }else{ 0 })
  if($r2.Count -gt 20){ $r2 = @($r2[($r2.Count-20)..($r2.Count-1)]) }
  $rec.recent = $r2
  $st.topics[$topicId] = $rec
  Perf-Save $st
  return $rec
}

# Accuracy of a record (0..1); -1 when no attempts.
function Perf-Acc($rec){
  $a = [int]$rec.attempts; if($a -le 0){ return -1.0 }
  return ([double]([int]$rec.correct) / [double]$a)
}

# Resolve a friendly topic name from the curriculum when one was not stored.
function Perf-TopicName($id){
  $id = [string]$id
  if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){
    try { foreach($t in @(Get-Curriculum)){ if([string]$t.id -eq $id){ return [string]$t.topic } } } catch {}
  }
  return $id
}

# Summary the coach references: overall accuracy, strengths (solid topics),
# weaknesses (struggling topics) - each sorted most-relevant first.
function Get-PerfSummary {
  $st = Perf-Load
  $totA = 0; $totC = 0
  $strengths = New-Object System.Collections.ArrayList
  $weak = New-Object System.Collections.ArrayList
  foreach($id in @($st.topics.Keys)){
    $rec = $st.topics[$id]; $a=[int]$rec.attempts; $c=[int]$rec.correct
    $totA += $a; $totC += $c
    $acc = Perf-Acc $rec
    if($acc -lt 0){ continue }
    $nm = [string]$rec.name; if(-not $nm){ $nm = Perf-TopicName $id }
    $entry = @{ id=[string]$id; name=$nm; acc=$acc; attempts=$a; correct=$c }
    if($a -ge 3 -and $acc -ge 0.8){ [void]$strengths.Add($entry) }
    elseif($a -ge 2 -and $acc -lt 0.6){ [void]$weak.Add($entry) }
  }
  $sa = @(@($strengths) | Sort-Object { $_.acc } -Descending)
  $wk = @(@($weak) | Sort-Object { $_.acc })
  $pct = $(if($totA -gt 0){ [int][math]::Round(100.0*$totC/$totA) }else{ 0 })
  return @{ totalAttempts=$totA; totalCorrect=$totC; pct=$pct; strengths=$sa; weaknesses=$wk }
}

# Lowest-accuracy topic ids (with enough attempts) for generators to target.
function Get-WeakTopics([int]$n=5){
  $s = Get-PerfSummary
  $ids = @(); foreach($w in @($s.weaknesses)){ $ids += [string]$w.id; if($ids.Count -ge $n){ break } }
  return $ids
}
