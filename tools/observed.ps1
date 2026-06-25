# observed.ps1 - THE OBSERVED CURRICULUM (v3).
# The v2 coach matched what it watched onto a FIXED, pre-authored finance syllabus
# (Curriculum.md) - so it could only teach those ~57 topics. v3 inverts that: it distills
# what the coach ACTUALLY watched (lesson transcript + on-screen text) into a structured,
# drillable concept list, and THAT becomes the curriculum. This is what lets it teach the
# exact thing you studied - any subject - instead of a generic, pre-written course.
#
# Store: Coaching/Observed.json - an array of concepts, each:
#   id, title, kind(concept|calculation|definition|procedure), taught(the definition/method
#   AS PRESENTED, incl. any formula), example, domain, seenAt(iso), hits(times reinforced)
#
# Dot-sourced alongside curriculum.ps1 (reuses $script:XCCoaching / $script:XCEnv from it).
# Pure-ish: only Obs-Distill hits the network; everything else is local file IO.

function Obs-Path { if(-not $script:XCCoaching){ return $null }; return (Join-Path $script:XCCoaching "Observed.json") }

# API key: prefer the live worker's $sync.key, else read OPENAI_API_KEY from the .env.
function Obs-Key {
  try{ if($sync -and $sync.key){ return [string]$sync.key } }catch{}
  try{ $f=$script:XCEnv; if($f -and (Test-Path $f)){ $l=Get-Content $f | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1; if($l){ return (($l -replace '^\s*OPENAI_API_KEY\s*=\s*','')).Trim().Trim('"') } } }catch{}
  return ''
}

function Obs-NormTitle($t){ return (([string]$t).ToLower() -replace '[^a-z0-9]','') }

function Obs-Load {
  $p=Obs-Path; if(-not $p -or -not (Test-Path $p)){ return @() }
  try{ $j=(Get-Content $p -Raw) | ConvertFrom-Json; return @($j) }catch{ return @() }
}

function Obs-Save($items){
  $p=Obs-Path; if(-not $p){ return }
  try{ $dir=Split-Path $p -Parent; if(-not (Test-Path $dir)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null } }catch{}
  # Hand-roll the JSON array so a single concept doesn't collapse to a bare object.
  $parts=@(); foreach($it in @($items)){ $parts += ($it | ConvertTo-Json -Depth 6 -Compress) }
  $json='[' + ($parts -join ',') + ']'
  try{ [IO.File]::WriteAllText($p,$json,(New-Object System.Text.UTF8Encoding($false))) }catch{}
}

# Merge freshly-distilled concepts into the store: dedupe by normalized title, bump hit
# count, keep the richer definition/example. Returns the new total count.
function Obs-Merge($newItems){
  $items=@(Obs-Load)
  $byNorm=@{}; foreach($it in $items){ $k=Obs-NormTitle $it.title; if($k){ $byNorm[$k]=$it } }
  $now=(Get-Date).ToString('o')
  foreach($n in @($newItems)){
    $title=[string]$n.title; if(-not $title){ continue }
    $nk=Obs-NormTitle $title; if(-not $nk){ continue }
    if($byNorm.ContainsKey($nk)){
      $ex=$byNorm[$nk]
      try{ $ex.hits=[int]$ex.hits + 1 }catch{ $ex | Add-Member -NotePropertyName hits -NotePropertyValue 2 -Force }
      try{ $ex.seenAt=$now }catch{}
      if(([string]$n.taught).Length -gt ([string]$ex.taught).Length){ try{ $ex.taught=[string]$n.taught }catch{} }
      if((-not [string]$ex.example) -and [string]$n.example){ try{ $ex.example=[string]$n.example }catch{} }
    } else {
      $obj=[pscustomobject]@{ id=('obs-'+$nk); title=$title; kind=([string]$n.kind); taught=([string]$n.taught); example=([string]$n.example); domain=([string]$n.domain); seenAt=$now; hits=1 }
      $items+=$obj; $byNorm[$nk]=$obj
    }
  }
  Obs-Save $items
  return @($items).Count
}

# THE distiller: turn an observed excerpt (transcript and/or on-screen text) into structured,
# drillable concepts. Network call (gpt-4o-mini, cheap/fast - this is extraction, not
# reasoning). Returns an array of concept objects (possibly empty). No state change.
function Obs-Distill($text){
  $text=[string]$text; if($text.Trim().Length -lt 40){ return @() }
  $key=Obs-Key; if(-not $key -or $key -like '*REPLACE_ME*'){ return @() }
  $model='gpt-4o-mini'
  $sys=@'
You distill what a lesson or research session ACTUALLY TAUGHT into structured, drillable concepts.
From the excerpt, output ONLY a JSON array (no prose, no code fences). Each element:
{"title": short concept name,
 "kind": one of "concept" | "calculation" | "definition" | "procedure",
 "taught": the definition or method EXACTLY as presented, including any formula, in 1-2 sentences,
 "example": a concrete example shown or clearly implied (else ""),
 "domain": the subject area (e.g. Accounting, Excel, Biology, History)}
Include ONLY concepts genuinely taught or explained in the excerpt. Skip chatter, navigation,
filler, and anything not actually taught. Capture it the way THIS source presented it, even if
that differs from the textbook. If nothing substantive was taught, output [].
'@
  $payload=@{ model=$model; max_tokens=800; temperature=0; messages=@(@{role='system';content=$sys},@{role='user';content=$text}) } | ConvertTo-Json -Depth 8
  $bf=Join-Path $env:TEMP ("xc_obs_"+([Math]::Abs(($text+'').GetHashCode()))+".json")
  try{ [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false))) }catch{ return @() }
  $r=$null; try{ $r=& curl.exe -s --max-time 45 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf) }catch{}
  try{ Remove-Item $bf -ErrorAction SilentlyContinue }catch{}
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if(-not $j.choices){ return @() }
  $c=[string]$j.choices[0].message.content
  $c=($c -replace '(?s)^.*?```(?:json)?',''); $c=($c -replace '(?s)```.*$',''); $c=$c.Trim()
  $s=$c.IndexOf('['); $e=$c.LastIndexOf(']'); if($s -lt 0 -or $e -le $s){ return @() }
  $c=$c.Substring($s,$e-$s+1)
  $arr=$null; try{ $arr=$c|ConvertFrom-Json }catch{}
  if($null -eq $arr){ return @() }
  return @($arr)
}

# Distill an excerpt AND merge it into the store in one call (what the live watcher uses).
function Obs-Observe($text){
  $new=@(Obs-Distill $text)
  if($new.Count -eq 0){ return @(Obs-Load).Count }
  return (Obs-Merge $new)
}

# Topic rows for the run-through picker - SAME shape as Get-RTTopics (id/name/category/state)
# plus the grounding (taught/example/kind) so Make-Exercise can build a question from exactly
# what was observed. Excludes nothing here; the picker/gate decides what to drill.
function Get-ObservedTopics {
  $items=@(Obs-Load)
  $state=$null; if(Get-Command RT-LoadState -ErrorAction SilentlyContinue){ try{ $state=RT-LoadState }catch{} }
  $out=New-Object System.Collections.ArrayList
  foreach($it in $items){
    $id=[string]$it.id; if(-not $id){ continue }
    $rec=$null; if($state -and (Get-Command RT-TopicRec -ErrorAction SilentlyContinue)){ try{ $rec=RT-TopicRec $state $id }catch{} }
    [void]$out.Add(@{ id=$id; name=[string]$it.title; category=([string]$it.domain); state=$rec; taught=[string]$it.taught; example=[string]$it.example; kind=[string]$it.kind })
  }
  return $out
}
