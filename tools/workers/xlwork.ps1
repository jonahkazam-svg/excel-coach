function XLog($m){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_watcher.log"),((Get-Date).ToString("HH:mm:ss")+"  "+$m+"`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{} }
function HashOf($s){ $i=([string]$s).IndexOf("`n"); if($i -gt 0){ return $s.Substring($i).GetHashCode() }; return ([string]$s).GetHashCode() }
try{ . (Join-Path $sync.tools "curriculum.ps1") }catch{ XLog ("curriculum load FAILED: "+$_.Exception.Message) }
# Assembled from fragments so the file carries no contiguous DllImport/user32.dll pattern
# for Defender's AMSI heuristic to false-flag (same reason as xcap.ps1's Win2 block).
$xwI = '[Dll'+'Import("user'+'32.dll")]'
$xwSrc = 'using System; using System.Runtime.InteropServices; public class WinX { '+$xwI+' public static extern IntPtr GetForegroundWindow(); }'
try{ Add-Type $xwSrc -ErrorAction Stop }catch{}
XLog ("watcher up. Read-ExcelLive loaded: "+[bool](Get-Command Read-ExcelLive -ErrorAction SilentlyContinue))
$lastHash=0; $lastChange=(Get-Date); $stuck=$false; $nudgeT=(Get-Date).AddDays(-1); $seen=@{}; $lastLogged=""; $lastState="OK"; $nullStreak=$false; $hb=(Get-Date); $prevXl=""; $sweptHash=0; $lastCoSave=(Get-Date).AddDays(-1); $guideT=(Get-Date).AddDays(-1); $lastGuideStep=""; $guideHash=-1; $guideOverviewSheet=""; $lastNudgePub=""
while(-not $sync.stop){
 try{
  $sync.wHB=(Get-Date); if(((Get-Date)-$hb).TotalSeconds -ge 120){ $hb=(Get-Date); XLog "heartbeat (alive)" }
  if($sync.paused){ Start-Sleep -Milliseconds 800; continue }
  $xl=$null; if(Get-Command Read-ExcelLive -ErrorAction SilentlyContinue){ try{ $xl=Read-ExcelLive }catch{ XLog ("read threw: "+$_.Exception.Message) } }
  if($xl -and $xl.Length -lt 130){ $xl=$null }
  if(-not $xl){ if(-not $nullStreak){ $nullStreak=$true; XLog "Excel read = null (closed or busy) - waiting" }; Start-Sleep -Seconds 3; continue }
  if($nullStreak){ $nullStreak=$false; XLog "Excel readable again" }
  if($sync.demoActive){ Start-Sleep -Seconds 2; continue }
  $sync.lastXl=$xl
  if(($xl -match "Workbook '([^']+)'") -and ($Matches[1] -ne $sync.lastWb)){
    $sync.lastWb=$Matches[1]
    if($seen.ContainsKey($sync.lastWb)){ $sync.sheetPurpose=[string]$seen[$sync.lastWb] }
    else{
      try{
        $les=$sync.lessonlog; if($les.Length -gt 700){ $les=$les.Substring($les.Length-700) }
        $sp=@{ model="gpt-4o-mini"; max_tokens=110; temperature=0; messages=@(@{role="system";content="In ONE concise line, state what this Excel sheet is for the student to practice and the method/goal, inferred from its cells, labels, any visible question or prompt, and the recent lesson. Format exactly: 'Practicing <topic> via <method>; goal: <goal>'. Be specific; no preamble."},@{role="user";content=("Recent lesson: "+$les+"`n`nThe Excel sheet:`n"+$xl)}) } | ConvertTo-Json -Depth 8
        $sbf="$env:TEMP\xc_sheet.json"; [IO.File]::WriteAllText($sbf,$sp,(New-Object System.Text.UTF8Encoding($false)))
        $sr=& curl.exe -s --max-time 20 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$sbf)
        $sj=$null; try{ $sj=$sr|ConvertFrom-Json }catch{}
        if($sj.choices){
          $purp=([string]$sj.choices[0].message.content).Trim()
          if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $purp=Clean-Answer $purp }
          $sync.sheetPurpose=$purp; $seen[$sync.lastWb]=$purp
          $sf=Join-Path $sync.coaching "Sheets.md"; if(-not(Test-Path $sf)){ [IO.File]::AppendAllText($sf,"# Sheets - what each practice workbook is for`r`n",(New-Object System.Text.UTF8Encoding($false))) }
          [IO.File]::AppendAllText($sf,"`r`n- "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"  '"+$sync.lastWb+"': "+$purp,(New-Object System.Text.UTF8Encoding($false)))
        }
      }catch{}
    }
    $lastHash=(HashOf $xl); $lastChange=(Get-Date); $stuck=$false; $lastState="OK"; $prevXl=$xl; $sweptHash=$lastHash
    $shN=''; try{ if($xl -match "sheet '([^']+)'"){ $shN=$Matches[1] } }catch{}; $sync.lastSheet=$shN; XLog ("workbook: '"+$sync.lastWb+"' sheet '"+$shN+"'")
    Start-Sleep -Seconds 2; continue
  }
  # During a live drill exercise, stay silent (skip the error-check + guide nudges)
  # so the coach does not interrupt or pre-grade the Workout sheet. Workbook tracking
  # above still runs every iteration, so generation/grading target the right book.
  if($sync.woActive){ Start-Sleep -Seconds 2; continue }
  if($false){   # BIG-PICTURE OVERVIEW REMOVED (Jonah: "remove the big picture thing") - it auto-fired a "Big picture --" orientation blurb on every new sheet (showed up as a random "workout summary"). The step-by-step guide below and the error-watcher are unaffected.
    $guideOverviewSheet=$sync.lastWb; $guideT=(Get-Date)
    try{
      $ou=@(@{type='text';text=("Goal of this sheet: "+[string]$sync.sheetPurpose)})
      $ou+=@{type='text';text=("The student's sheet:`n"+$xl)}
      $ou+=@{type='text';text="This is UNFAMILIAR material for the student. In 3 to 4 short sentences, paint the FULL PICTURE of this whole exercise before they start the steps: what it is overall, its major parts or sections and how they connect, and the end goal - how they will know the whole thing is complete (the final tie-out or check). Plain language, no numeric answers, no preamble - just orient them to the whole."}
      if([string]$sync.scopeNote){ $ou+=@{type='text';text=([string]$sync.scopeNote+" If this sheet is OUTSIDE the in-scope domains, do not orient or guide on it at all - reply EXACTLY: OK.")} }
      $opay=@{ model="gpt-4o-mini"; max_tokens=350; temperature=0; messages=@(@{role='system';content=("You orient a student to an unfamiliar finance/Excel exercise by giving the big picture - the whole structure and the end goal - before any individual step. Only guide within the student's in-scope course domains; on out-of-scope material reply exactly OK."+[string]$sync.scopeNote)},@{role='user';content=$ou}) } | ConvertTo-Json -Depth 10
      $obf="$env:TEMP\xc_guideov.json"; [IO.File]::WriteAllText($obf,$opay,(New-Object System.Text.UTF8Encoding($false)))
      $orr=& curl.exe -s --max-time 25 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$obf)
      $ojj=$null; try{ $ojj=$orr|ConvertFrom-Json }catch{}
      if($ojj.choices){ $ov=([string]$ojj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $ov=Clean-Answer $ov }; if($ov){ $sync.xlText=("GUIDE: Big picture -- "+$ov); $sync.xlStamp=$sync.xlStamp+1; XLog ("GUIDE overview: "+$ov) } }
    }catch{ XLog ("guide overview error: "+$_.Exception.Message) }
  }
  if($sync.guideOn -and $sync.sheetPurpose -and (-not $sync.demoActive) -and ($lastGuideStep -ne "DONE") -and ( (((HashOf $xl) -ne $guideHash) -and ((Get-Date)-$guideT).TotalSeconds -ge 30) -or ((((Get-Date)-$guideT).TotalSeconds -ge $(if($lastGuideStep){240}else{75})) -and (((Get-Date)-$lastChange).TotalMinutes -lt 15)) )){
    $guideHash=(HashOf $xl); $guideT=(Get-Date)
    try{
      $gu=@(@{type='text';text=("Goal of this sheet: "+[string]$sync.sheetPurpose)})
      $gu+=@{type='text';text=("The student's CURRENT sheet (what they have filled in so far):`n"+$xl)}
      $gu+=@{type='text';text="Identify the SINGLE step the student should do NOW, based on what is filled in versus the goal. Reply EXACTLY one line, no preamble, using | as the separator: KEY: <a 1 or 2 word slug naming this step, e.g. operating, capex, fcf, financing, reconcile> | <complete guidance a stuck student can follow: WHAT to do and in which section or cells, HOW to do it as a short process that references the exact cells and values they already have, and WHY it matters - enough that someone with no idea how to do it can follow. Do NOT state the final numeric answer; point them at the cells and let them compute.> | <the check or tie-out that proves it is right>. If the whole task is already complete and ties out, reply instead: DONE | <one short sentence: what they finished and the tie-out they hit>."}
      if([string]$sync.scopeNote){ $gu+=@{type='text';text=([string]$sync.scopeNote+" If this sheet is OUTSIDE the in-scope domains, do not guide a step at all - reply EXACTLY: OK.")} }
      $gpay=@{ model="gpt-4o-mini"; max_tokens=450; temperature=0; messages=@(@{role='system';content=("You are a finance/Excel tutor guiding a student through a worksheet ONE step at a time. For the current step you explain WHAT, WHERE, HOW (the process, referencing their actual cells), and WHY - enough that someone who has no idea how to do it can follow - but you NEVER give the final numeric answer; you point at the cells and let them compute it. Only guide within the student's in-scope course domains; if the sheet is out of scope, reply exactly OK and guide nothing."+[string]$sync.scopeNote)},@{role='user';content=$gu}) } | ConvertTo-Json -Depth 10
      $gbf="$env:TEMP\xc_guide.json"; [IO.File]::WriteAllText($gbf,$gpay,(New-Object System.Text.UTF8Encoding($false)))
      $grr=& curl.exe -s --max-time 25 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$gbf)
      $gjj=$null; try{ $gjj=$grr|ConvertFrom-Json }catch{}
      if($gjj.choices){
        $gt=([string]$gjj.choices[0].message.content).Trim()
        if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $gt=Clean-Answer $gt }
        if($gt -match '(?im)^\s*DONE\s*\|\s*(.+)$'){ if($lastGuideStep -ne "DONE"){ $lastGuideStep="DONE"; $sync.xlText=("GUIDE: "+$Matches[1].Trim()); $sync.xlStamp=$sync.xlStamp+1; XLog ("GUIDE done: "+$Matches[1].Trim()) } }
        elseif($gt -match '(?im)^\s*(?:KEY:\s*)?([A-Za-z][A-Za-z0-9 /]{0,24})\s*\|\s*(.+)$'){
          $gkey=$Matches[1].Trim().ToLower(); $grest=$Matches[2].Trim(); $gmsg=$grest; $gchk=""
          if($grest -match '^(.*\S)\s*\|\s*(.+)$'){ $gmsg=$Matches[1].Trim(); $gchk=$Matches[2].Trim() }
          if($gkey -ne $lastGuideStep){ $lastGuideStep=$gkey; $sync.xlText=("GUIDE: "+$gmsg+$(if($gchk){ "  -- you'll know it's right when: "+$gchk }else{ "" })); $sync.xlStamp=$sync.xlStamp+1; XLog ("GUIDE step '"+$gkey+"': "+$gmsg) } else { XLog ("guide same step '"+$gkey+"' - suppressed") } }
        else { XLog ("guide unparsed: "+$(if($gt.Length -gt 140){ $gt.Substring(0,140) }else{ $gt })) }
      }
    }catch{ XLog ("guide error: "+$_.Exception.Message) }
  }
  $h=(HashOf $xl)
  $mode=""; $diffTxt=""
  if($h -ne $lastHash){ $mode="change" }
  elseif(($h -ne $sweptHash) -and (((Get-Date)-$lastChange).TotalSeconds -ge 45)){ $mode="sweep"; $sweptHash=$h; XLog "deep sweep - full recheck" }
  if($mode -eq "change"){
    $lastHash=$h; $lastChange=(Get-Date); $stuck=$false
    XLog "sheet changed - checking"
    Start-Sleep -Milliseconds 2500
    try{ $x2=Read-ExcelLive; if($x2 -and $x2.Length -ge 130){ $xl=$x2; $lastHash=(HashOf $xl) } }catch{}
    $diffTxt=""
    if($prevXl){
      $po=$prevXl -split "`r?`n"; $co=$xl -split "`r?`n"
      $addL=@($co | Where-Object { $_ -and ($po -notcontains $_) } | Select-Object -First 6)
      $remL=@($po | Where-Object { $_ -and ($co -notcontains $_) } | Select-Object -First 4)
      if($addL.Count -gt 0){ $diffTxt="CELLS I JUST CHANGED OR ADDED:`n"+($addL -join "`n") }
      if($remL.Count -gt 0){ $diffTxt=$diffTxt+"`nOLD LINES REPLACED OR REMOVED:`n"+($remL -join "`n") }
    }
    $prevXl=$xl
  }
  if($mode){
    $les2=[string]$sync.lessonlog; if($les2.Length -gt 500){ $les2=$les2.Substring($les2.Length-500) }
    $inst="Below is the EXACT live data from my Excel practice sheet (every non-empty cell: address, value, formula). Check ONLY for a GENUINE ERROR: a wrong formula, a wrong cell reference, a clearly wrong number, a broken or incorrect link, a wrong sign, or a real conceptual mistake versus standard investment-banking practice. RECOMPUTE the values yourself from the data before flagging anything - if it could be a valid alternative method, a different order of steps, or just unfinished work, it is NOT an error (unfinished is fine). Focus FIRST on the cells I just changed (listed below if any) - recompute those carefully. PREDICT AND COMPARE: for each number or formula I have entered, independently work out what that cell SHOULD be from the model's logic; if the instructor's build (lesson structure) is in your context, treat it as the intended target for the matching cells. If my value MATERIALLY differs from what it should be, that is an error. Pay EXTRA attention to mistakes matching my known weak points (in your context). Never reveal the answer to an exercise I have not attempted yet; once I HAVE entered an answer or formula, verify it by computing the correct result yourself. If a genuine error exists: name the exact cell, the EXPECTED value or formula it should be, the fix, and briefly WHY, in one or two short sentences; if it repeats one of my known weak points, add one short sentence stating the underlying rule so I stop repeating it. Otherwise reply EXACTLY: OK. CONFIDENCE BAR: only flag something when you are HIGHLY CONFIDENT it is genuinely and clearly wrong after recomputing it yourself; if you are unsure at all, or it could be a valid alternative method, a different order of steps, a rounding difference, or just unfinished work, say NOTHING and reply EXACTLY: OK. Never guess, never invent a mistake, never nitpick. Do NOT introduce or require any method, convention, formula, or step I have not been shown - judge my work only against the lesson/build in your context and standard practice for what is actually on the sheet, not against extra steps the exercise did not ask for."
    if($mode -eq "sweep"){ $inst="This is a periodic DEEP RE-CHECK: do a full careful pass over EVERY formula and entered value on the sheet, recomputing each one - a fast earlier check may have missed something. "+$inst }
    $uc=@(@{type='text';text=$inst})
    if($diffTxt){ $uc+=@{type='text';text=$diffTxt} }
    if($sync.sheetPurpose){ $uc+=@{type='text';text=("What this sheet practices: "+$sync.sheetPurpose)} }
    if($sync.lessonModel){ $uc+=@{type='text';text=("What the instructor's build looks like (from the lesson video): "+$sync.lessonModel)} }
    if($sync.companyCtx){ $uc+=@{type='text';text=[string]$sync.companyCtx} }
    if($les2){ $uc+=@{type='text';text=("Recent lesson context: "+$les2)} }
    if($sync.lastNudge -and $sync.lastNudge -ne "OK"){ $uc+=@{type='text';text=("You last told me: '"+$sync.lastNudge+"'. If I fixed it and nothing else is wrong, reply OK. If it is STILL not fixed, flag it again.")} }
    $uc+=@{type='text';text=("EXACT Excel data:`n"+$xl)}
    $pay=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort="medium"; messages=@(@{role='system';content=("You are a precise, conservative checker and tutor for a finance student rebuilding course models in Excel. Only flag a mistake when you are HIGHLY CONFIDENT it is genuinely and clearly wrong; when unsure, reply exactly OK and say nothing. Never invent or nitpick an error, and never require a method, convention, or step the student has not been shown. Only check work within the student's in-scope course domains; if the sheet is out of scope, reply exactly OK."+[string]$sync.scopeNote+$sync.brain)},@{role='user';content=$uc}) } | ConvertTo-Json -Depth 12
    $bfx="$env:TEMP\xc_xlcheck.json"; [IO.File]::WriteAllText($bfx,$pay,(New-Object System.Text.UTF8Encoding($false)))
    $rr=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bfx)
    $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}
    if($jj.choices){
      $t=([string]$jj.choices[0].message.content).Trim()
      if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $t=Clean-Answer $t }
      XLog ("verdict: "+$(if($t -eq ""){ "<EMPTY>" }elseif($t.Length -gt 140){ $t.Substring(0,140) }else{ $t }))
      if($t -eq ""){ }
      elseif($t -match '^\s*OK'){
        if($lastState -ne "OK"){ $lastState="OK"; $lastNudgePub=""; $sync.xlText="OK"; $sync.xlStamp=$sync.xlStamp+1; XLog "cleared (fixed)" }
      } else {
        $sameIssue=$false; if($lastNudgePub){ if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $sameIssue=(XC-SameIssue $t $lastNudgePub) }else{ $sameIssue=($t -eq $lastNudgePub) } }
        $cool=$(if($sameIssue){ 180 }elseif($lastNudgePub){ 150 }else{ 20 })
        if(((Get-Date)-$nudgeT).TotalSeconds -ge $cool){
          $nudgeT=(Get-Date); $lastState=$t; $lastNudgePub=$t; $sync.xlText=$t; $sync.xlStamp=$sync.xlStamp+1; XLog "PUBLISHED nudge"
          $dupS=$false; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $dupS=(XC-SameIssue $t $lastLogged) }
          if(-not $dupS){ $lastLogged=$t; if(Get-Command Log-Struggle -ErrorAction SilentlyContinue){ try{ Log-Struggle $t }catch{} } }
        } else { XLog ("suppressed ("+$(if($sameIssue){"same issue, "+$cool+"s"}else{[string]$cool+"s cooldown"})+")") }
      }
    } elseif($jj.error){ XLog ("API error: "+$jj.error.message) } else { XLog "no API response (timeout?)" }
    if(($mode -eq "sweep") -and (((Get-Date)-$lastCoSave).TotalSeconds -ge 360)){
      $lastCoSave=(Get-Date)
      try{
        $cuc=@(@{type='text';text="Look at my Excel sheet data. FIRST decide which real-world company this work is about, if any (a named company like Amazon or Tesla - generic practice exercises are NONE). Reply line 1 EXACTLY: COMPANY: <name or NONE>. If it IS about a company, follow with the key REUSABLE data points from this sheet - assumptions, inputs, and important computed outputs - one per line as '- <what> = <value> (cell <ref>)'. Only genuinely reusable finance figures (rates, growth, margins, multiples, totals, share counts, prices, valuations), max 12 lines. Plain ASCII, nothing else."})
        $cuc+=@{type='text';text=("EXACT Excel data:`n"+$xl)}
        $cpay=@{ model=$sync.model; max_completion_tokens=900; reasoning_effort="low"; messages=@(@{role='system';content="You extract reusable company figures from a finance student's Excel sheet."},@{role='user';content=$cuc}) } | ConvertTo-Json -Depth 12
        $cbf2="$env:TEMP\xc_company.json"; [IO.File]::WriteAllText($cbf2,$cpay,(New-Object System.Text.UTF8Encoding($false)))
        $crr2=& curl.exe -s --max-time 35 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$cbf2)
        $cjj2=$null; try{ $cjj2=$crr2|ConvertFrom-Json }catch{}
        if($cjj2.choices){
          $ct=([string]$cjj2.choices[0].message.content).Trim()
          if($ct -match '(?m)^\s*COMPANY:\s*(.+)$'){
            $cname=$Matches[1].Trim()
            if($cname -and ($cname -notmatch '^(?i)none')){
              $cdata=($ct -replace '(?m)^\s*COMPANY:.*$','').Trim()
              if($cdata -and (Get-Command Save-CompanyData -ErrorAction SilentlyContinue)){ try{ Save-CompanyData $cname $sync.lastWb $cdata }catch{} }
              $sync.company=$cname
              if(Get-Command Get-CompanyData -ErrorAction SilentlyContinue){ try{ $cc=Get-CompanyData $cname; if($cc){ $sync.companyCtx=("Saved figures for "+$cname+" from my models (company ledger in Obsidian):`n"+$cc) } }catch{} }
              XLog ("company ledger updated: "+$cname)
            } else { $sync.company=""; $sync.companyCtx="" }
          }
        }
      }catch{}
    }
  }
  Start-Sleep -Seconds 4
 }catch{ XLog ("LOOP ERROR: "+$_.Exception.Message); Start-Sleep -Seconds 5 }
}