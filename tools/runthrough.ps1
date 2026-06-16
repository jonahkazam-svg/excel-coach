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
