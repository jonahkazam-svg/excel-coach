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
    "exposed" { if($cur -eq "unseen"){ $write=$true } }
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
    if($w -le 0){ continue }
    $tw = $tierW[$n.tier]; if($null -eq $tw){ $tw=2 }
    $pre = 1.0
    if($n.prereq){ $pst = $(if($m.ContainsKey($n.prereq)){ $m[$n.prereq].status } else { "unseen" }); if($pst -eq "unseen"){ $pre=0.4 } }
    $dl = 1.0
    if($n.tier -eq "must" -and $days -lt 14){ $dl = 1.0 + (14-$days)/14.0 }
    $scored += [PSCustomObject]@{ node=$n; status=$st; score=($tw*$w*$pre*$dl) }
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
  [void]$sb.Append(" When you help, be accurate and frame it against where the student stands versus what an investment-banking analyst needs to know cold; when it fits naturally, connect your help to closing these gaps. Do not lecture about the curriculum unprompted - just let it sharpen your help.")
  return $sb.ToString()
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
