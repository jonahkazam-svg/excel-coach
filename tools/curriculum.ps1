# curriculum.ps1 - shared engine for the curriculum-aware tutor (memory + steering).
# Dot-sourced by watch.ps1 (main scope AND the worker runspace) and coach.ps1.
# Flat files in the Coaching folder; ASCII; pipe-delimited. Curriculum.md is read-only;
# Mastery.md is append-only (last-write-wins, governed by the Bump-Mastery rules).
# No quiz/deck yet - that pillar is deferred.

if($Coaching){ $script:XCCoaching = $Coaching } else { $script:XCCoaching = "C:\Users\jonah\Projects\excel-coach\Coaching" }
$script:XCEnv = Join-Path (Split-Path $script:XCCoaching -Parent) ".env"
$script:XCRank = @{ unseen=0; exposed=1; shaky=2; solid=3 }

function XC-Append($path,$text){ [IO.File]::AppendAllText($path,$text,(New-Object System.Text.UTF8Encoding($false))) }

function XC-DaysToStart {
  try {
    $l = Get-Content $script:XCEnv -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*FELLOWSHIP_START\s*=' } | Select-Object -First 1
    if(-not $l){ return 999 }
    $v = ($l -replace '^\s*FELLOWSHIP_START\s*=\s*','').Trim().Trim('"')
    $d = [datetime]::ParseExact($v,'yyyy-MM-dd',$null)
    return [int][math]::Ceiling(($d - (Get-Date).Date).TotalDays)
  } catch { return 999 }
}

function XC-DaysSince($d){ if(-not $d){ return 999 }; try{ return [int]((Get-Date).Date - [datetime]::ParseExact($d,'yyyy-MM-dd',$null)).TotalDays }catch{ return 999 } }

# Decide whether two proactive-nudge messages are about the SAME underlying issue,
# so the coach flags a problem once and stays quiet until the situation actually changes.
# Same cell address referenced -> same issue. Otherwise fall back to word overlap.
function XC-SameIssue($a,$b){
  if(-not $a -or -not $b){ return $false }
  $a=[string]$a; $b=[string]$b
  if($a -eq $b){ return $true }
  $ca = @([regex]::Matches($a,'\b[A-Z]{1,3}[0-9]{1,4}\b') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique)
  $cb = @([regex]::Matches($b,'\b[A-Z]{1,3}[0-9]{1,4}\b') | ForEach-Object { $_.Value.ToUpper() } | Select-Object -Unique)
  if($ca.Count -gt 0 -and $cb.Count -gt 0){ foreach($c in $ca){ if($cb -contains $c){ return $true } }; return $false }
  $wa = @(($a.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_.Length -gt 3 } | Select-Object -Unique)
  $wb = @(($b.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_.Length -gt 3 } | Select-Object -Unique)
  if($wa.Count -eq 0 -or $wb.Count -eq 0){ return $false }
  $inter = @($wa | Where-Object { $wb -contains $_ }).Count
  $union = (@($wa + $wb | Select-Object -Unique)).Count
  if($union -eq 0){ return $false }
  return ((($inter / [double]$union)) -ge 0.5)
}

# Match what the student is currently doing (lesson audio + sheet purpose) against
# topics they previously struggled with (shaky mastery nodes). Returns "topic|note"
# for the strongest match so the coach can warn BEFORE they err, or $null.
function Find-WeakFlash($text){
  if(-not $text){ return $null }
  $tl=([string]$text).ToLower()
  $m=Get-Mastery; $cur=Get-Curriculum
  $best=$null; $bestHits=0
  foreach($n in $cur){
    if(-not $m.ContainsKey($n.id)){ continue }
    if($m[$n.id].status -ne 'shaky'){ continue }
    $words=@(($n.topic.ToLower() -replace '[^a-z0-9 ]',' ' -split '\s+') | Where-Object { $_.Length -gt 3 } | Select-Object -Unique)
    $hits=@($words | Where-Object { $tl.Contains($_) }).Count
    if($hits -ge 2 -and $hits -gt $bestHits){ $bestHits=$hits; $best=($n.topic+"|"+$m[$n.id].note) }
  }
  return $best
}

# Execute a tiny operation language against the LIVE Excel (the coach's "hands").
# Guardrails: writes ONLY to cells that are empty on the active sheet (or a NEW
# sheet it creates), max 80 writes per command, never deletes or overwrites.
# -Plan parses and validates without touching Excel (for testing).
# IB-convention styling for anything the coach BUILDS (worked examples, practice
# blocks, drills, hands) - never for cells the STUDENT fills. Blue font = hard-coded
# input, black = formula, accounting number format on figures, bold on total/header
# labels. Best-effort: every COM set is wrapped so a refusal never breaks a build.
$script:XCTotalRx='(?i)^(total|subtotal|net income|net cash|net change|net increase|net decrease|gross profit|operating income|ebit|cfo|cfi|cff|fcf)'
function Format-XlCell($cell,$val){
  if(-not $cell){ return }
  $v=([string]$val).Trim()
  try{
    if($v -match '^='){
      try{ $cell.Font.Color=0 }catch{}
      try{ $cell.NumberFormat='#,##0.00;(#,##0.00)' }catch{}
    }
    elseif($v -match '^\(?-?\$?\s*[0-9][0-9,]*(\.[0-9]+)?\)?%?$'){
      try{ $cell.Font.Color=16711680 }catch{}
      if($v -match '%'){ try{ $cell.NumberFormat='0.0%' }catch{} }
      elseif($v -match '^(19|20)[0-9]{2}$'){ try{ $cell.NumberFormat='General' }catch{} }
      else{ try{ $cell.NumberFormat='#,##0.00;(#,##0.00)' }catch{} }
    }
    else{
      if($v -match $script:XCTotalRx){ try{ $cell.Font.Bold=$true }catch{} }
    }
  }catch{}
}

# After a build: bold + top-border the total rows, then autofit columns so the
# sheet reads like a real model. $ops = flat list of @{addr=..;val=..;blank=..}.
function Polish-BuiltSheet($ws,$ops){
  if(-not $ws -or -not $ops){ return }
  try{
    $trows=@{}
    foreach($o in $ops){ if((-not $o.blank) -and ([string]$o.val -match $script:XCTotalRx)){ $rr=([string]$o.addr -replace '^[A-Za-z]+',''); if($rr){ $trows[$rr]=$true } } }
    foreach($o in $ops){ if($o.blank){ continue }; $rr=([string]$o.addr -replace '^[A-Za-z]+',''); if($rr -and $trows[$rr]){ try{ $tc=$ws.Range([string]$o.addr); $tc.Font.Bold=$true; $b=$tc.Borders(8); $b.LineStyle=1; $b.Weight=2; try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($b) }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($tc) }catch{} } }
    # visible structure: styled title (top-left cell) + shaded/bold header row (first row with 2+ cells)
    $rowCnt=@{}; $titleAddr=$null; $titleKey=$null; $minCi=9999; $maxCi=0
    foreach($o in $ops){
      $a=[string]$o.addr; if($a -notmatch '^([A-Za-z]+)([0-9]+)$'){ continue }
      $col=$Matches[1].ToUpper(); $row=[int]$Matches[2]; $ci=0; foreach($ch in $col.ToCharArray()){ $ci=$ci*26+([int][char]$ch-64) }
      if($ci -lt $minCi){ $minCi=$ci }; if($ci -gt $maxCi){ $maxCi=$ci }
      if($o.blank){ continue }
      if($rowCnt.ContainsKey($row)){ $rowCnt[$row]=$rowCnt[$row]+1 }else{ $rowCnt[$row]=1 }
      $key=$row*1000+$ci; if(($null -eq $titleKey) -or ($key -lt $titleKey)){ $titleKey=$key; $titleAddr=$a }
    }
    if($titleAddr){ try{ $tcell=$ws.Range($titleAddr); $tcell.Font.Bold=$true; $tcell.Font.Size=13; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($tcell) }catch{} }
    $hdrRow=$null; foreach($row in ($rowCnt.Keys | Sort-Object)){ if($rowCnt[$row] -ge 2){ $hdrRow=$row; break } }
    if($hdrRow){ foreach($o in $ops){ if($o.blank){ continue }; $a=[string]$o.addr; if($a -match '^[A-Za-z]+([0-9]+)$'){ if([int]$Matches[1] -eq $hdrRow){ try{ $hc=$ws.Range($a); $hc.Font.Bold=$true; $hc.Interior.Color=16115420; $hb=$hc.Borders(9); $hb.LineStyle=1; $hb.Weight=2; try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($hb) }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($hc) }catch{} } } } }
    try{ if(($maxCi -ge $minCi) -and ($minCi -ge 1)){ for($cc=$minCi;$cc -le $maxCi;$cc++){ try{ $colObj=$ws.Columns.Item($cc); $colObj.AutoFit(); try{ if($colObj.ColumnWidth -gt 45){ $colObj.ColumnWidth=45 } }catch{}; [void][Runtime.InteropServices.Marshal]::ReleaseComObject($colObj) }catch{} } } }catch{}
  }catch{}
}

function Apply-XlOps($ops,[switch]$Plan){
  $written=0; $skipped=0; $sheets=0; $done=""; $failed=@(); $planned=@(); $putUsed=0; $builtOps=New-Object System.Collections.ArrayList
  $xl=$null; $wb=$null; $sh=$null
  if(-not $Plan){
    try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{ return "Excel is not open - open your workbook first." }
    try{ $wb=$xl.ActiveWorkbook }catch{}
    if(-not $wb){ return "No active workbook in Excel." }
    $ready=$false
    for($w=0;$w -lt 8;$w++){ try{ $sh=$xl.ActiveSheet; $null=$sh.Name; $ready=$true; break }catch{ Start-Sleep -Milliseconds 500 } }
    if(-not $ready){ return "Excel would not let me in (are you editing a cell?) - press Enter or Esc and ask me again." }
  }
  foreach($ln in ([string]$ops -split "`r?`n")){
    $l=$ln.Trim(); if(-not $l){ continue }
    if($l -match '^(SET|PUT)\s+([A-Za-z]{1,3}[0-9]{1,5})\s+(.+)$'){
      $op=$Matches[1].ToUpper(); $addr=$Matches[2].ToUpper(); $val=$Matches[3].Trim()
      if($written -ge 80){ $skipped++; continue }
      if(($op -eq "PUT") -and ($putUsed -ge 15)){ $skipped++; continue }
      if($Plan){ $planned+=($op+" "+$addr+" "+$val); $written++; continue }
      $opOk=$false; $lastErr=""
      for($try=0;$try -lt 6;$try++){
        try{
          $cell=$sh.Range($addr)
          $cur=$cell.Value2
          $mayWrite=(($op -eq "PUT") -or ($null -eq $cur) -or (([string]$cur) -eq ""))
          if($mayWrite){
            try{ $cell.Formula=$val }catch{ $cell.Value2=$val }
            if($sync.formatOn){ Format-XlCell $cell $val }
            $written++; if($op -eq "PUT"){ $putUsed++ }; [void]$builtOps.Add(@{addr=$addr;val=$val})
          } else { $skipped++ }
          [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cell)
          $opOk=$true; break
        }catch{ $lastErr=$_.Exception.Message; Start-Sleep -Milliseconds 400 }
      }
      if(-not $opOk){ $failed+=($addr+$(if($lastErr){ " ("+$lastErr.Substring(0,[Math]::Min(70,$lastErr.Length)).Trim()+")" }else{ "" })) }
    }
    elseif($l -match '^SHEET\s+(.+)$'){
      $nm=($Matches[1].Trim() -replace '[\\/\?\*\[\]:]',''); if($nm.Length -gt 28){ $nm=$nm.Substring(0,28) }
      if($Plan){ $planned+=("SHEET "+$nm); $sheets++; continue }
      $shOk=$false
      for($try=0;$try -lt 3;$try++){
        try{ $ns=$wb.Worksheets.Add([Type]::Missing,$sh); if($nm){ try{ $ns.Name=$nm }catch{} }; if($sh){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($sh) }catch{} }; $sh=$ns; $sheets++; $shOk=$true; $builtOps.Clear(); break }catch{ Start-Sleep -Milliseconds 500 }
      }
      if(-not $shOk){ $failed+=("sheet '"+$nm+"'") }
    }
    elseif($l -match '^DONE\s*(.*)$'){ $done=$Matches[1].Trim() }
  }
  if((-not $Plan) -and $sync.formatOn -and ($builtOps.Count -gt 0) -and (Get-Command Polish-BuiltSheet -ErrorAction SilentlyContinue)){ try{ Polish-BuiltSheet $sh $builtOps }catch{} }
  if(-not $Plan){
    foreach($o in @($sh,$wb,$xl)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } }
  }
  if($Plan){ return ("PLAN: ops="+($written+$sheets)+"; done='"+$done+"'") }
  if(-not $done){ $done="Done." }
  $parts=@()
  if($written){ $parts+=("wrote "+$written+" cells") }
  if($sheets){ $parts+=([string]$sheets+" new sheet") }
  if($skipped){ $parts+=("skipped "+$skipped+" non-empty") }
  if($failed.Count -gt 0){ $parts+=("could NOT write "+($failed -join ", ")+" - Excel was busy; ask me to fill those again") }
  if($parts.Count -gt 0){ return ($done+" ("+($parts -join ", ")+")") }
  return $done
}

# Cross-workbook company ledger: persist the key figures from a sheet about a
# real company into the Obsidian vault (Coaching/Companies/<Name>.md) so any
# other spreadsheet about the same company can reference them.
function Save-CompanyData($company,$wbName,$text){
  if(-not $company -or -not $text){ return }
  $dir=Join-Path $script:XCCoaching "Companies"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $safe=(([string]$company) -replace '[\\/:*?"<>|]','').Trim(); if(-not $safe){ return }
  $f=Join-Path $dir ($safe+".md")
  if(-not (Test-Path $f)){ XC-Append $f ("# "+$safe+" - figures carried across my models`r`n") }
  XC-Append $f ("`r`n## "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"  (from '"+[string]$wbName+"')`r`n"+[string]$text+"`r`n")
}
function Get-CompanyData($company){
  if(-not $company){ return "" }
  $safe=(([string]$company) -replace '[\\/:*?"<>|]','').Trim(); if(-not $safe){ return "" }
  $f=Join-Path (Join-Path $script:XCCoaching "Companies") ($safe+".md")
  if(-not (Test-Path $f)){ return "" }
  $t=Get-Content $f -Raw
  if($t.Length -gt 2200){ $t=$t.Substring($t.Length-2200) }
  return $t
}

# Memory hygiene: Weak Points.md accumulates many near-duplicate entries which
# crowd out signal in the brain. Once per day, dedupe it into a clean list of
# DISTINCT recurring weak points via gpt-4o-mini; the raw history is archived,
# never deleted. Guarded by a date stamp so it runs at most once a day.
function Consolidate-WeakPoints {
  try{
    $f=Join-Path $script:XCCoaching "Weak Points.md"
    if(-not (Test-Path $f)){ return }
    $raw=Get-Content $f -Raw
    if($raw.Length -lt 3000){ return }
    $today=(Get-Date).ToString('yyyy-MM-dd')
    $stamp=Join-Path $script:XCCoaching ".wp_stamp"
    if(Test-Path $stamp){ if(((Get-Content $stamp -Raw).Trim()) -eq $today){ return } }
    $kl=Get-Content $script:XCEnv -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
    if(-not $kl){ return }
    $key=($kl -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"'); if(-not $key){ return }
    $src=$raw; if($src.Length -gt 9000){ $src=$src.Substring($src.Length-9000) }
    $pay=@{ model="gpt-4o-mini"; max_tokens=700; temperature=0; messages=@(@{role="system";content="You consolidate a finance student's accumulated weak-point notes, which contain many near-duplicate entries. Output a CLEAN, DEDUPED list of their DISTINCT recurring weak points - merge duplicates, keep the clearest phrasing, most recurring or important first. Each line starts with '- '. Max 15 lines. Plain ASCII. No preamble, no headers, nothing else."},@{role="user";content=$src}) } | ConvertTo-Json -Depth 8
    $bf=Join-Path $env:TEMP "xc_wpcons.json"; [IO.File]::WriteAllText($bf,$pay,(New-Object System.Text.UTF8Encoding($false)))
    $rr=& curl.exe -s --max-time 35 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf)
    $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}
    if(-not $jj.choices){ return }
    $clean=([string]$jj.choices[0].message.content).Trim()
    if(-not ($clean -match '(?m)^\s*-\s')){ return }
    $arch=Join-Path $script:XCCoaching "Weak Points.archive.md"
    XC-Append $arch ("`r`n# Archived "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"`r`n"+$raw+"`r`n")
    $new="# Weak Points (consolidated "+$today+")`r`n`r`n"+$clean+"`r`n`r`n## New since consolidation`r`n"
    [IO.File]::WriteAllText($f,$new,(New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stamp,$today,(New-Object System.Text.UTF8Encoding($false)))
  }catch{}
}

# Higher-order synthesizer: read ALL the behavioral signals we have on the student
# (consolidated weak points, Note-button flags, the practice-sheet types, the kick
# and revisit signals, and the shaky curriculum nodes) and have gpt-4o-mini distill
# them into the student's 3-4 WEAKEST CATEGORIES, whether each is a START vs EXECUTE
# problem, and the single highest-priority thing to drill next. Written to
# Struggle Profile.md and loaded into the brain so help is prioritized by category.
# Daily-stamped so it runs at most once a day; mirrors Consolidate-WeakPoints.
function Build-StruggleProfile {
  try{
    $today=(Get-Date).ToString('yyyy-MM-dd')
    $stamp=Join-Path $script:XCCoaching ".sp_stamp"
    if(Test-Path $stamp){ if(((Get-Content $stamp -Raw).Trim()) -eq $today){ return } }
    $kl=Get-Content $script:XCEnv -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
    if(-not $kl){ return }
    $key=($kl -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"'); if(-not $key){ return }
    $sb=New-Object System.Text.StringBuilder
    $wpf=Join-Path $script:XCCoaching "Weak Points.md"
    if(Test-Path $wpf){ $t=(Get-Content $wpf -Raw); if($t.Length -gt 3000){ $t=$t.Substring($t.Length-3000) }; [void]$sb.AppendLine("=== CONSOLIDATED WEAK POINTS ==="); [void]$sb.AppendLine($t) }
    $nf=Join-Path $script:XCCoaching "Notes.md"
    if(Test-Path $nf){ $t=(Get-Content $nf -Raw); if($t.Length -gt 1500){ $t=$t.Substring($t.Length-1500) }; [void]$sb.AppendLine("=== NOTES THE STUDENT FLAGGED TO REVISIT ==="); [void]$sb.AppendLine($t) }
    $sf=Join-Path $script:XCCoaching "Sheets.md"
    if(Test-Path $sf){ $sl=@(Get-Content $sf | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 12); if($sl.Count -gt 0){ [void]$sb.AppendLine("=== RECENT PRACTICE-SHEET TYPES ==="); [void]$sb.AppendLine(($sl -join "`r`n")) } }
    $gf=Join-Path $script:XCCoaching "Signals.md"
    if(Test-Path $gf){ $sl2=@(Get-Content $gf | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 40); if($sl2.Count -gt 0){ [void]$sb.AppendLine("=== BEHAVIORAL SIGNALS (kick = asked where to start; revisit = looped back to an already-covered topic) ==="); [void]$sb.AppendLine(($sl2 -join "`r`n")) } }
    try{
      $m=Get-Mastery; $cur=Get-Curriculum
      $shaky=@($cur | Where-Object { $m.ContainsKey($_.id) -and ($m[$_.id].status -eq 'shaky') } | ForEach-Object { "- "+$_.topic+" ["+$_.domain+"]" })
      if($shaky.Count -gt 0){ [void]$sb.AppendLine("=== SHAKY CURRICULUM NODES (auto-tracked as not yet solid) ==="); [void]$sb.AppendLine(($shaky -join "`r`n")) }
    }catch{}
    $src=$sb.ToString().Trim()
    if($src.Length -lt 40){ return }
    if($src.Length -gt 9000){ $src=$src.Substring($src.Length-9000) }
    $sys="From these signals about a finance student, identify their 3 to 4 WEAKEST CATEGORIES (e.g. cash flow statement, depreciation, working capital, Excel accelerator keys, DCF), and for each give the specific recurring problem AND whether they struggle to START the work or to EXECUTE it correctly. Most severe first, each line '- '. Then a final line exactly: 'START HERE: <the single highest-priority thing to drill next>'. Max 12 lines, plain ASCII, no preamble."
    $pay=@{ model="gpt-4o-mini"; max_tokens=500; temperature=0; messages=@(@{role="system";content=$sys},@{role="user";content=$src}) } | ConvertTo-Json -Depth 8
    $bf=Join-Path $env:TEMP "xc_sprofile.json"; [IO.File]::WriteAllText($bf,$pay,(New-Object System.Text.UTF8Encoding($false)))
    $rr=& curl.exe -s --max-time 35 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$key) -H "Content-Type: application/json" -d ("@"+$bf)
    $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}
    if(-not $jj.choices){ return }
    $clean=([string]$jj.choices[0].message.content).Trim()
    if(-not ($clean -match '(?m)^\s*-\s')){ return }
    $out=Join-Path $script:XCCoaching "Struggle Profile.md"
    $new="# Struggle Profile (updated "+$today+")`r`n`r`n"+$clean+"`r`n"
    [IO.File]::WriteAllText($out,$new,(New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stamp,$today,(New-Object System.Text.UTF8Encoding($false)))
  }catch{}
}

# Assemble the full context block the tutor leverages: recurring weak points,
# concepts already covered, and the curriculum/recency brain. Rebuilt periodically
# so struggles captured DURING a session are leveraged immediately, not after restart.
function Build-FullBrain {
  $brain=""
  $wpf=Join-Path $script:XCCoaching "Weak Points.md"
  if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1800){ $bt=$bt.Substring($bt.Length-1800) }; $brain=" The student's known recurring weak points and struggles (call one out by name if it recurs, and proactively reinforce it): "+$bt }
  $kfb=Join-Path $script:XCCoaching "Knowledge.md"
  if(Test-Path $kfb){ $kt=(Get-Content $kfb -Raw); if($kt.Length -gt 2000){ $kt=$kt.Substring($kt.Length-2000) }; $brain=$brain+" Concepts the student has already covered in lessons: "+$kt }
  try{ $brain=$brain+(Build-CurriculumBrain) }catch{}
  return $brain
}

# Record a struggle the coach caught while the student was working (a confirmed
# error, or a topic they got wrong) - not just things they said aloud. Feeds back
# into Weak Points so future help reinforces it.
function Log-Struggle($text){
  if(-not $text){ return }
  $t=([string]$text).Trim(); if($t -eq "" -or $t -match '^\s*OK\s*$'){ return }
  $wpf=Join-Path $script:XCCoaching "Weak Points.md"
  if(-not (Test-Path $wpf)){ XC-Append $wpf "# Weak Points (accumulating across sessions)`r`n" }
  XC-Append $wpf ("`r`n## (caught while working) "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"`r`n- "+$t+"`r`n")
}

function Get-Curriculum {
  $f = Join-Path $script:XCCoaching "Curriculum.md"
  if(-not (Test-Path $f)){ return @() }
  $out = @()
  foreach($line in (Get-Content $f)){
    $t = $line.Trim()
    if($t -eq "" -or $t.StartsWith("#")){ continue }
    $p = $line -split '\|'
    if($p.Count -lt 4){ continue }
    $out += [PSCustomObject]@{ id=$p[0].Trim(); domain=$p[1].Trim(); topic=$p[2].Trim(); tier=$p[3].Trim(); prereq=$(if($p.Count -ge 5){ $p[4].Trim() } else { "" }) }
  }
  return $out
}

function Get-Mastery {
  $f = Join-Path $script:XCCoaching "Mastery.md"
  $h = @{}
  if(-not (Test-Path $f)){ return $h }
  foreach($line in (Get-Content $f)){
    $t = $line.Trim()
    if($t -eq "" -or $t.StartsWith("#")){ continue }
    $p = $line -split '\|'
    if($p.Count -lt 2){ continue }
    $h[$p[0].Trim()] = [PSCustomObject]@{ status=$p[1].Trim(); conf=$(if($p.Count -ge 3){ $p[2].Trim() } else { "1" }); last_seen=$(if($p.Count -ge 4){ $p[3].Trim() } else { "" }); note=$(if($p.Count -ge 5){ $p[4].Trim() } else { "" }) }
  }
  return $h
}

function Bump-Mastery($id,$status,$note){
  if(-not $id -or -not $status){ return }
  $f = Join-Path $script:XCCoaching "Mastery.md"
  if(-not (Test-Path $f)){ XC-Append $f "# Mastery - auto-tracked competency status (ID|status|conf|last_seen|note); status=unseen/exposed/shaky/solid`r`n" }
  $m = Get-Mastery
  $cur = $(if($m.ContainsKey($id)){ $m[$id].status } else { "unseen" })
  $write = $false
  switch($status){
    "exposed" { if($cur -eq "unseen"){ $write=$true } elseif($cur -eq "exposed" -and $m[$id].last_seen -ne (Get-Date).ToString('yyyy-MM-dd')){ $write=$true } }
    "shaky"   { if($cur -ne "shaky" -and $cur -ne "solid"){ $write=$true } }
    "solid"   { $write=$true }
    default   { if($script:XCRank[$status] -gt $script:XCRank[$cur]){ $write=$true } }
  }
  if($write){
    $conf = $(switch($status){ "solid"{3} default{1} })
    XC-Append $f ($id+"|"+$status+"|"+$conf+"|"+(Get-Date).ToString('yyyy-MM-dd')+"|"+([string]$note)+"`r`n")
  }
}

function Get-NextGap([int]$top=3){
  $cur = Get-Curriculum; if($cur.Count -eq 0){ return @() }
  $m = Get-Mastery
  $days = XC-DaysToStart
  $weak = @{ unseen=3; exposed=1; shaky=3; solid=0 }
  $tierW = @{ must=3; should=2; nice=1 }
  $scored = @()
  foreach($n in $cur){
    $st = $(if($m.ContainsKey($n.id)){ $m[$n.id].status } else { "unseen" })
    $w = $weak[$st]; if($null -eq $w){ $w=2 }
    $rec = 1.0
    if(($st -eq 'exposed' -or $st -eq 'solid') -and $m.ContainsKey($n.id)){ $ds = XC-DaysSince $m[$n.id].last_seen; if($ds -ge 3){ $rec = 1.0 + [Math]::Min($ds,14)/4.0 }; if($st -eq 'solid'){ $w = $(if($ds -ge 5){ [Math]::Min($ds,15)/15.0 }else{ 0 }) } }
    if($w -le 0){ continue }
    $tw = $tierW[$n.tier]; if($null -eq $tw){ $tw=2 }
    $pre = 1.0
    if($n.prereq){ $pst = $(if($m.ContainsKey($n.prereq)){ $m[$n.prereq].status } else { "unseen" }); if($pst -eq "unseen"){ $pre=0.4 } }
    $dl = 1.0
    if($n.tier -eq "must" -and $days -lt 14){ $dl = 1.0 + (14-$days)/14.0 }
    $scored += [PSCustomObject]@{ node=$n; status=$st; score=($tw*$w*$pre*$dl*$rec) }
  }
  return ($scored | Sort-Object -Property score -Descending | Select-Object -First $top)
}

function Build-CurriculumBrain {
  $cur = Get-Curriculum; if($cur.Count -eq 0){ return "" }
  $m = Get-Mastery
  $musts = @($cur | Where-Object { $_.tier -eq "must" })
  $seenMust = @($musts | Where-Object { $m.ContainsKey($_.id) -and $m[$_.id].status -ne "unseen" }).Count
  $shaky = @($cur | Where-Object { $m.ContainsKey($_.id) -and $m[$_.id].status -eq "shaky" })
  $days = XC-DaysToStart
  $gaps = Get-NextGap 3
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append(" CURRICULUM CONTEXT (the student is prepping for an investment-banking fellowship that starts in "+$days+" days).")
  [void]$sb.Append(" Coverage: seen "+$seenMust+" of "+$musts.Count+" must-know topics; "+$shaky.Count+" marked shaky.")
  if($gaps -and @($gaps).Count -gt 0){
    [void]$sb.Append(" Their top gaps to close next:")
    $i=1; foreach($g in $gaps){ [void]$sb.Append(" ("+$i+") "+$g.node.topic+" ["+$g.node.domain+", "+$g.status+"];"); $i++ }
  }
  $nf=Join-Path $script:XCCoaching "Notes.md"
  if(Test-Path $nf){ $nt=(Get-Content $nf -Raw); if($nt.Length -gt 600){ $nt=$nt.Substring($nt.Length-600) }; $nt=(($nt -replace '(?m)^#{1,6}.*$','') -replace "\r?\n"," ").Trim(); if($nt){ [void]$sb.Append(" The student has FLAGGED these to revisit and practice (bring them up when relevant): "+$nt+".") } }
  $stale=@()
  foreach($n in $musts){ if($m.ContainsKey($n.id) -and ($m[$n.id].status -eq 'exposed' -or $m[$n.id].status -eq 'solid')){ $ds=XC-DaysSince $m[$n.id].last_seen; if($ds -ge 4){ $stale += [PSCustomObject]@{ topic=$n.topic; ds=$ds } } } }
  if(@($stale).Count -gt 0){ $sr=(@($stale | Sort-Object -Property ds -Descending | Select-Object -First 3) | ForEach-Object { $_.topic+" ("+$_.ds+"d ago)" }) -join "; "; [void]$sb.Append(" REVIEW RADAR - covered a while ago and worth a quick refresh before the program: "+$sr+".") }
  $sf=Join-Path $script:XCCoaching "Sheets.md"
  if(Test-Path $sf){ $sl=@(Get-Content $sf | Where-Object { $_ -match '^\s*-\s' } | Select-Object -Last 3); if($sl.Count -gt 0){ [void]$sb.Append(" Recent practice sheets (cross-session memory of what each was for): "+((($sl -join " ") -replace '\s+',' ').Trim())+".") } }
  [void]$sb.Append(" When you help, be accurate and frame it against where the student stands versus what an investment-banking analyst needs to know cold; when it fits naturally, connect your help to closing these gaps. Do not lecture about the curriculum unprompted - just let it sharpen your help.")
  return $sb.ToString()
}

# Mission control ("coach, how am I doing?"): a deterministic spoken progress
# report assembled purely from the vault flat files - NO API calls. Returns
# 4-6 sentences of plain ASCII prose, no markdown (it gets spoken aloud).
function Build-Scorecard {
  $parts = @()
  $cur = Get-Curriculum; $m = Get-Mastery
  $musts = @($cur | Where-Object { $_.tier -eq "must" })
  $seenMust = @($musts | Where-Object { $m.ContainsKey($_.id) -and $m[$_.id].status -ne "unseen" }).Count
  $shakyN = @($cur | Where-Object { $m.ContainsKey($_.id) -and $m[$_.id].status -eq "shaky" }).Count
  $days = XC-DaysToStart
  $s = "You've covered "+$seenMust+" of "+$musts.Count+" must-know topics so far, with "+$shakyN+" marked shaky"
  if($days -lt 999){ $s = $s+", and the fellowship starts in "+$days+" day"+$(if($days -ne 1){ "s" }else{ "" }) }
  $parts += ($s+".")
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $daily = Join-Path $script:XCCoaching ($today+".md")
  $asked = 0; $nudges = 0; $haveDaily = (Test-Path $daily)
  if($haveDaily){
    $raw = Get-Content $daily -Raw
    $asked = ([regex]::Matches($raw,'\[you asked')).Count
    $entries = ([regex]::Matches($raw,'(?m)^###\s+\d{1,2}:\d{2}\s+\[WATCH\]')).Count
    $nudges = $entries - $asked; if($nudges -lt 0){ $nudges = 0 }
  }
  $sheetsToday = 0
  $sf = Join-Path $script:XCCoaching "Sheets.md"
  if(Test-Path $sf){ $sheetsToday = @(Get-Content $sf | Where-Object { $_ -match ('^\s*-\s*'+[regex]::Escape($today)) }).Count }
  if($haveDaily -or ($sheetsToday -gt 0)){
    $parts += ("Today you asked "+$asked+" question"+$(if($asked -ne 1){ "s" }else{ "" })+", I jumped in with "+$nudges+" nudge"+$(if($nudges -ne 1){ "s" }else{ "" })+", and "+$sheetsToday+" practice sheet"+$(if($sheetsToday -ne 1){ "s" }else{ "" })+" came up.")
  } else {
    $parts += "I haven't logged anything with you today yet."
  }
  $gaps = @(Get-NextGap 2)
  if($gaps.Count -ge 2){ $parts += ("Next I'd hit: "+$gaps[0].node.topic+" ("+$gaps[0].node.domain+"), then "+$gaps[1].node.topic+".") }
  elseif($gaps.Count -eq 1){ $parts += ("Next I'd hit: "+$gaps[0].node.topic+" ("+$gaps[0].node.domain+").") }
  $wpf = Join-Path $script:XCCoaching "Weak Points.md"
  if(Test-Path $wpf){
    $sec = $null
    foreach($mt in [regex]::Matches((Get-Content $wpf -Raw),'(?ms)^##\s*\((live|caught while working)\)[^\r\n]*\r?\n(.*?)(?=^##\s*\(|\z)')){ $sec = $mt }
    if($sec){
      $b = @($sec.Groups[2].Value -split "\r?\n" | Where-Object { $_ -match '^\s*-\s*\S' } | Select-Object -First 1)
      if($b.Count -gt 0){
        $bt = (([string]$b[0]) -replace '^\s*-\s*','' -replace '`','' -replace '\s+',' ').Trim().Trim('"').Trim()
        if($bt.Length -gt 110){ $bt = $bt.Substring(0,110).TrimEnd()+"..." }
        if($bt){ if($bt -notmatch '[.!?]$'){ $bt = $bt+"." }; $parts += ("One recent trip-up to keep in mind: "+$bt) }
      }
    }
  }
  return ($parts -join " ")
}

function Compact-File($path,[int]$keyIndex){
  if(-not (Test-Path $path)){ return }
  $head = @(); $seen = [ordered]@{}; $started = $false
  foreach($line in (Get-Content $path)){
    $t = $line.Trim()
    if($t -eq "" -or $t.StartsWith("#")){ if(-not $started){ $head += $line }; continue }
    $p = $line -split '\|'
    if($p.Count -le $keyIndex){ continue }
    $started = $true; $seen[$p[$keyIndex].Trim()] = $line
  }
  $out = @($head) + @($seen.Values)
  [IO.File]::WriteAllText($path, (($out -join "`r`n").TrimEnd() + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# --- Live Excel reader (shared so the worker runspace can read exact cells too, not just Get-Help) ---
function ColLetter($n){ $r=""; do { $n--; $r=[string][char]([int][char]'A'+($n%26))+$r; $n=[int][math]::Floor($n/26) } while($n -gt 0); return $r }
function Read-ExcelLive {
  $xl=$null; try { $xl=[System.Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") } catch { return $null }
  if(-not $xl){ return $null }
  $out=$null
  try {
    $wb=$xl.ActiveWorkbook; if(-not $wb){ return $null }
    $sh=$xl.ActiveSheet; $ur=$sh.UsedRange
    $rows=[int]$ur.Rows.Count; $cols=[int]$ur.Columns.Count; $r0=[int]$ur.Row; $c0=[int]$ur.Column
    $rr=[Math]::Min($rows,400); $cc=[Math]::Min($cols,80); if($rr -lt $rows -or $cc -lt $cols){ $ur=$ur.Resize($rr,$cc) }; $rows=$rr; $cols=$cc
    $act=""; $sel=""; try{ $act=$xl.ActiveCell.Address($false,$false) }catch{}; try{ $sel=$xl.Selection.Address($false,$false) }catch{}
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Workbook '"+$wb.Name+"' sheet '"+$sh.Name+"'. Active cell "+$act+", selection "+$sel+".")
    [void]$sb.AppendLine("Non-empty cells (ADDRESS = value   [formula if any]):")
    $n=0; $cap=300
    if($rows*$cols -eq 1){
      $v=$ur.Value2; $fm=[string]$ur.Formula; $addr=(ColLetter $c0)+$r0
      if($null -ne $v -or $fm){ $ln=$addr+" = "+([string]$v); if($fm.StartsWith("=")){ $ln+="   "+$fm }; [void]$sb.AppendLine($ln); $n=1 }
    } else {
      $vals=$ur.Value2; $forms=$ur.Formula
      for($i=1;$i -le $rows -and $n -lt $cap;$i++){ for($j=1;$j -le $cols -and $n -lt $cap;$j++){
        $v=$vals.GetValue($i,$j); $fm=$forms.GetValue($i,$j)
        if($null -eq $v -and [string]::IsNullOrEmpty([string]$fm)){ continue }
        $addr=(ColLetter ($c0+$j-1))+($r0+$i-1)
        $vs=$(if($v -is [double]){ $v.ToString("0.######") }else{ [string]$v })
        $ln=$addr+" = "+$vs; if(($fm -is [string]) -and $fm.StartsWith("=")){ $ln+="   "+$fm }
        [void]$sb.AppendLine($ln); $n++
      }}
      if($n -ge $cap){ [void]$sb.AppendLine("...(more cells not shown)") }
    }
    $out=$sb.ToString()
  } catch { $out=$null } finally { foreach($o in @($ur,$sh,$wb,$xl)){ try{ if($o){ [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } }catch{} } }
  return $out
}

# Encoding-clean an answer to safe ASCII but KEEP markdown (so the popup can render it richly)
function Clean-Answer($s){
  if(-not $s){ return $s }
  $s=$s -replace ([char]0x2014),' - ' -replace ([char]0x2013),'-' -replace ([char]0x2018),"'" -replace ([char]0x2019),"'" -replace ([char]0x201C),'"' -replace ([char]0x201D),'"' -replace ([char]0x2026),'...' -replace ([char]0x2022),'- ' -replace ([char]0x2192),'->' -replace ([char]0x00A0),' ' -replace ([char]0x00D7),'x' -replace ([char]0x2264),'<=' -replace ([char]0x2265),'>='
  $s=$s -replace '[^\x09\x0A\x0D\x20-\x7E]',''
  $s=$s -replace '  +',' '
  $s=$s -replace "(\r?\n){3,}","`r`n`r`n"
  return $s.Trim()
}
# Plain prose for the spoken voice and the one-line strip label (strip all markdown)
function Speakable($s){
  $s=Clean-Answer $s
  if(-not $s){ return $s }
  $s=$s -replace '\*\*','' -replace '__','' -replace '`',''
  $s=$s -replace '(?m)^\s{0,3}#{1,6}\s*',''
  $s=$s -replace '(?m)^\s*[\*\-\+]\s+',''
  $s=$s -replace '[ ]{2,}',' '
  return ($s -replace "(\r?\n){2,}","`r`n").Trim()
}
