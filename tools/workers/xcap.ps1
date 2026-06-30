# xcap.ps1 - hands-on Excel actions (the coach's "hands"): turn a request or the live sheet
# into SET/SHEET ops and run them via Apply-XlOps. Screen-capture + its window interop moved
# to xccap.ps1, so if a security scanner quarantines that file it cannot take the cheat-sheet,
# practice-generator (Make-Drill), or demo features here down with it.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# The coach's hands: turn a natural-language request into SET/SHEET ops and
# execute them via Apply-XlOps. Returns the spoken summary, or $null if the
# request was not really an Excel-building action (caller falls back to Q&A).
function Invoke-XlAction($req){
  try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  ACT INVOKED: "+$req+"`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  if(-not (Get-Command Apply-XlOps -ErrorAction SilentlyContinue)){ return $null }
  # FULL-model read (cap 1200), not a +-60 band around the cursor: "finish the net debt section" /
  # "fill out the cash flow statement" need the WHOLE model in view, or the action is blind to the
  # named section when the cursor is elsewhere and produces nothing. The active cell is still in the
  # data, so cursor-local commands ("finish this") still work.
  $fresh=$null; try{ $fresh=Read-ExcelLive 0 1200 }catch{}
  if(-not $fresh){ $fresh=[string]$sync.lastXl }
  $ac=@(@{type='text';text=("REQUEST: "+$req)})
  if($sync.sheetPurpose){ $ac+=@{type='text';text=("What the student is practicing: "+$sync.sheetPurpose)} }
  if($sync.companyCtx){ $ac+=@{type='text';text=("Use these saved figures when the request refers to them: "+[string]$sync.companyCtx)} }
  if($fresh){ $ac+=@{type='text';text=("EXACT current Excel data (active sheet):`n"+$fresh)} }
  $apay=@{ model=$sync.model; max_completion_tokens=6000; reasoning_effort='high'; messages=@(@{role='system';content="You control Microsoft Excel for a finance student via a tiny operation language. If the REQUEST asks you to build, fill, set up, label, write, fix, change, FORMAT, color-code, highlight, or style something in Excel, reply ONLY with operation lines:`nSET <cell> <label or number or =formula>   (writes only if the cell is empty)`nPUT <cell> <label or number or =formula>   (overwrites - use ONLY when the request explicitly asks to change, fix, replace or correct existing content)`nSHEET <NewSheetName>`nDONE <one short spoken confirmation of what you built>`nRules: work on the ACTIVE sheet shown in the data (or create a SHEET first if asked for a new one); do exactly what was asked - minimal, clean, laid out like an investment-banking model; formulas start with =; before writing the DONE line, double-check every formula so its cell references point at cells you actually wrote or that already exist in the data; the LAST line must be the DONE line. To FORMAT / color-code / highlight EXISTING cells WITHOUT changing their values, use lines: FMT <cell-or-range> <attrs> - where attrs are space-separated from: bold italic underline center border fill:<color> font:<color> (colors: yellow green red blue orange gray purple teal lightblue lightgreen lightred lightyellow white black, or a 6-digit hex). A range styles a whole section at once, e.g. FMT A3:E3 bold fill:lightblue (a header row) or FMT B12:C18 fill:lightgreen (an Assets block). Use PUT only to fix wrong values/formulas/typos and SET for new empty cells - never rewrite a cell just to color it. The student's cursor is on the ACTIVE cell named in the data; when the request says to finish/complete/fill out/do a section or the sheet (e.g. 'finish workout 2', 'fill out the cash flow statement', 'do it'), the section to act on is the relevant block (around the active cell, or the named statement). Work out the answers and write the correct =formula into EVERY answer cell in that block: use SET for empty cells, and use PUT for any answer cell that already holds a PARTIAL or WRONG value so it gets OVERWRITTEN - do NOT skip an answer cell just because it is non-empty (skipping non-empty cells is the #1 reason a 'fill it out' ends up writing almost nothing). NEVER overwrite a GIVEN input/assumption cell or a correct existing LABEL - only the computed answer/output cells. Writing many cells is fine; the student can undo. Only fill the answer cells the task needs - do NOT add extra helper, checking, or FORMULATEXT columns, and do NOT duplicate labels that are already on the sheet. If the REQUEST is a genuine question (explain / why / what is), reply EXACTLY: NOTACTION; if it is NOT asking you to write into or format Excel, also reply EXACTLY: NOTACTION"},@{role='user';content=$ac}) } | ConvertTo-Json -Depth 10
  $abf2="$env:TEMP\xc_act.json"; [IO.File]::WriteAllText($abf2,$apay,(New-Object System.Text.UTF8Encoding($false)))
  $arr2=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$abf2)
  $ajj2=$null; try{ $ajj2=$arr2|ConvertFrom-Json }catch{}
  if(-not $ajj2.choices){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  ACT no API response (timeout/error) - fell back to describe`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; return $null }
  $aops=([string]$ajj2.choices[0].message.content).Trim()
  try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  DIAG REQ: "+$req+"`r`nRAW REPLY (first 400): "+$(if($aops.Length -gt 400){ $aops.Substring(0,400) }else{ $aops })+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  if((-not $aops) -or ($aops -match '^\s*NOTACTION') -or ($aops -notmatch '(?m)^(SET|PUT|SHEET|FMT)\s')){
    # The router only calls this when an action verb is present, but the action model is flaky and
    # sometimes wimps out to NOTACTION / prose on a clear imperative ("finish workout 2", "fill the cells").
    # If the request is phrased as a genuine question, respect that and fall back to Q&A. Otherwise it is a
    # DIRECT COMMAND - force one more attempt with NOTACTION forbidden so it actually acts instead of describing.
    $isQ = ($req -match '\?') -or ($req -match "(?i)\b(explain|why|what|whats|what's|how|when|should i|is it|are these|are those|can you tell|walk me through|help me understand|tell me|clarify|which|where do|do i need|what do i need)\b")
    if($isQ){ return $null }
    $fc=@(@{type='text';text=("DIRECT COMMAND: "+$req)})
    if($sync.sheetPurpose){ $fc+=@{type='text';text=("What the student is practicing: "+$sync.sheetPurpose)} }
    if($sync.companyCtx){ $fc+=@{type='text';text=("Use these saved figures when the request refers to them: "+[string]$sync.companyCtx)} }
    if($fresh){ $fc+=@{type='text';text=("EXACT current Excel data (active sheet):`n"+$fresh)} }
    $fpay=@{ model=$sync.model; max_completion_tokens=6000; reasoning_effort='high'; messages=@(@{role='system';content="You control Microsoft Excel for a finance student via a tiny operation language. The student just gave you a DIRECT COMMAND to act on their sheet - this is NOT a question, and NOTACTION and prose are FORBIDDEN. You MUST reply with operation lines that carry it out:`nSET <cell> <label or number or =formula>   (for empty cells)`nPUT <cell> <label or number or =formula>   (only to fix/replace existing content the command says to change)`nSHEET <NewSheetName>`nFMT <cell-or-range> <attrs>   (attrs from: bold italic underline center border fill:<color> font:<color>)`nDONE <one short spoken confirmation>`nRules: formulas start with =; the LAST line is the DONE line; references must point at cells you wrote or that already exist in the data. The student's cursor is on the ACTIVE cell named in the data. 'finish/complete/do this workout/problem/section' means: find the workout block AROUND the active cell and FILL EVERY empty answer cell in that whole block with SET (compute formulas from the data shown) - fill them ALL, not just one. Only fill answer cells - do NOT add extra helper, checking, or FORMULATEXT columns, and do NOT duplicate labels already on the sheet. 'format/color-code/highlight/clean up' means apply FMT to the relevant ranges. Do exactly what the command asked, laid out cleanly like an investment-banking model. Reply ONLY with operation lines, ending in DONE."},@{role='user';content=$fc}) } | ConvertTo-Json -Depth 10
    $fbf="$env:TEMP\xc_actf.json"; [IO.File]::WriteAllText($fbf,$fpay,(New-Object System.Text.UTF8Encoding($false)))
    $frr=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$fbf)
    $fjj=$null; try{ $fjj=$frr|ConvertFrom-Json }catch{}
    if(-not $fjj.choices){ return $null }
    $aops=([string]$fjj.choices[0].message.content).Trim()
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  FORCED RETRY (NOTACTION forbidden) REQ: "+$req+"`r`nRAW REPLY (first 400): "+$(if($aops.Length -gt 400){ $aops.Substring(0,400) }else{ $aops })+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
    if((-not $aops) -or ($aops -match '^\s*NOTACTION') -or ($aops -notmatch '(?m)^(SET|PUT|SHEET|FMT)\s')){ return $null }
  }
  $r=$null; $applied=$false; try{ $r=Apply-XlOps $aops; $applied=$true }catch{ $r="Excel action failed: "+$_.Exception.Message }
  try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  REQ: "+$req+"`r`nOPS:`r`n"+$aops+"`r`nRESULT: "+$r+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  # self-verify: re-read the sheet, make the model confirm every requested item landed, repair if not (max 2 rounds)
  if($applied -and $r -and ($r -notmatch '^(Excel is not open|No active workbook|Excel would not let me in)')){
    $allOps=$aops; $lastRes=[string]$r; $verified=$false; $vfail=$false
    for($vround=1;$vround -le 2;$vround++){   # 2 verify rounds: correctness > speed - catch and repair anything that didn't land or is wrong
      Start-Sleep -Milliseconds 1500
      $after=$null; try{ $after=Read-ExcelLive 0 1200 }catch{}
      if(-not $after){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+": could not re-read the sheet - verification skipped`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; break }
      $vc=@(@{type='text';text=("ORIGINAL REQUEST: "+$req)})
      $vc+=@{type='text';text=("OPS APPLIED SO FAR:`n"+$allOps)}
      $vc+=@{type='text';text=("APPLY SUMMARY (names any cells that could NOT be written): "+$lastRes)}
      $vc+=@{type='text';text=("EXACT Excel data NOW, after the writes (active sheet):`n"+$after)}
      $vpay=@{ model=$sync.model; max_completion_tokens=4000; reasoning_effort='medium'; messages=@(@{role='system';content="You just wrote into a finance student's Excel using SET/PUT/SHEET operation lines and must now VERIFY your own work. You are given the ORIGINAL REQUEST, the ops applied so far, the apply summary (it lists any cells that could NOT be written - those cells are still empty), and the EXACT sheet data as it is NOW. Recompute every formula from this data and confirm EVERY item the request asked for actually landed with correct cell references, labels, numbers and formulas. If anything is missing or wrong, reply ONLY with repair operation lines, one per line:`nSET <cell> <label or number or =formula>   (for cells that are empty now, including the could-NOT-write ones)`nPUT <cell> <label or number or =formula>   (ONLY to fix a cell the ops above just wrote with wrong content - never touch any other cell)`nNo DONE line, no commentary. If every requested item is present and correct, reply EXACTLY: VERIFIED"},@{role='user';content=$vc}) } | ConvertTo-Json -Depth 10
      $vbf="$env:TEMP\xc_verify.json"; [IO.File]::WriteAllText($vbf,$vpay,(New-Object System.Text.UTF8Encoding($false)))
      $vrr=& curl.exe -s --max-time 120 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$vbf)
      $vjj=$null; try{ $vjj=$vrr|ConvertFrom-Json }catch{}
      if(-not $vjj.choices){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+": no API response`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; break }
      $vout=([string]$vjj.choices[0].message.content).Trim()
      if($vout -match '^\s*VERIFIED'){ $verified=$true; try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+": VERIFIED`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; break }
      if($vout -notmatch '(?m)^(SET|PUT)\s'){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+": unusable reply: "+$(if($vout.Length -gt 160){ $vout.Substring(0,160) }else{ $vout })+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; break }
      $vfail=$true
      $vres=$null; try{ $vres=Apply-XlOps $vout }catch{ $vres="Excel repair failed: "+$_.Exception.Message }
      $allOps=$allOps+"`n"+$vout; $lastRes=[string]$vres
      try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+" REPAIR`r`nOPS:`r`n"+$vout+"`r`nRESULT: "+$vres+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
    }
    if($verified){ $r=[string]$r+" - verified." }
    elseif($vfail){ $r=[string]$r+" - checked twice, may need a look." }
  }
  return $r
}
# Teach mode: build a MINIMAL worked example of the same scenario on a fresh
# throwaway sheet while Jarvis (TTS) narrates each step. Coordinated with the
# $ttsWork thread via $sync.ttsText (start narration) and $sync.ttsBusyUntil
# (when playback ends) so cells appear while the coach is speaking.
function Run-Demo($topic){
  try{
    $xlchk=$null; try{ $xlchk=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
    if(-not $xlchk){ $sync.text="Open your workbook in Excel first, then ask me to demonstrate."; $sync.askLabel="Teach demo"; if(-not $sync.mute){ $sync.ttsText="Open your workbook in Excel first." }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
    try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xlchk) }catch{}
    $ctx=@(@{type='text';text=("TOPIC the student asked about: "+[string]$topic)})
    $lx=[string]$sync.lastXl; if($lx.Length -gt 1600){ $lx=$lx.Substring($lx.Length-1600) }
    if($lx){ $ctx+=@{type='text';text=("The student's currently-open sheet - reuse its scenario/numbers ONLY if it is the SAME topic they are learning now; if it is a DIFFERENT topic, IGNORE this sheet and build a fresh worked example for the current topic:`n"+$lx)} }
    if($sync.sheetPurpose){ $ctx+=@{type='text';text=("What the student is practicing: "+[string]$sync.sheetPurpose)} }
    if($sync.lessonModel){ $ctx+=@{type='text';text=("What the instructor's build looks like: "+[string]$sync.lessonModel)} }
    if($sync.lessonlog){ $ll=[string]$sync.lessonlog; if($ll.Length -gt 900){ $ll=$ll.Substring($ll.Length-900) }; $ctx+=@{type='text';text=("WHAT THE STUDENT IS LEARNING RIGHT NOW (from the live lesson - build on THIS topic, not an old/open sheet from a different subject): "+$ll)} }
    if($sync.lastNudge -and ($sync.lastNudge -ne "OK")){ $ctx+=@{type='text';text=("The concept behind their most recent mistake (teach this): "+[string]$sync.lastNudge)} }
    if($sync.companyCtx){ $ctx+=@{type='text';text=("Saved figures you may reuse: "+[string]$sync.companyCtx)} }
    $dsys="You are a finance/Excel tutor giving a LIVE, INTERACTIVE lesson on a fresh blank sheet. Do TWO things SIDE BY SIDE about the concept the student just struggled with. ON THE LEFT (start around B2): build a small WORKED example - fully solved, using their scenario - narrating each step as you build it. ON THE RIGHT (start around H2, same rows so they line up): build a PARALLEL PRACTICE version of the SAME concept with DIFFERENT numbers/items, but LEAVE THE ANSWER CELLS BLANK for the student to fill in - mark each blank answer cell so it gets highlighted. Reply ONLY with a script of these line types, nothing else:`nSTEP <one short spoken sentence about what you are adding to the worked example on the left>`nSET <cell> <label or number or =formula>  (a FILLED cell - the whole worked example, plus the labels and given inputs of the practice block)`nBLANK <cell>  (an ANSWER cell in the practice block the student must fill - left empty and highlighted)`nDONE <one short spoken sentence telling them to fill in the highlighted yellow cells and that you will check each one>`nRules: worked example on the LEFT columns, practice block on the RIGHT columns with a gap, same row layout; formulas start with =; label rows; plain ASCII; 5 to 9 STEP groups; put the practice SET and BLANK lines under a final STEP that says you set one up for them to try; the LAST line is the DONE line. Never mention cell colors, fonts, borders, number formats or any styling in a STEP or DONE sentence - narrate only the finance and Excel logic."
    $dpay=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort='medium'; messages=@(@{role='system';content=$dsys},@{role='user';content=$ctx}) } | ConvertTo-Json -Depth 10
    $dbf="$env:TEMP\xc_demo.json"; [IO.File]::WriteAllText($dbf,$dpay,(New-Object System.Text.UTF8Encoding($false)))
    $drr=& curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$dbf)
    $djj=$null; try{ $djj=$drr|ConvertFrom-Json }catch{}
    $script=$null; if($djj.choices){ $script=([string]$djj.choices[0].message.content).Trim() }
    if((-not $script) -or ($script -notmatch '(?m)^\s*STEP\s')){
      $fb="I could not put together a demo just now. In short: "+[string]$topic+" - rebuild the same scenario on a clean sheet, label each row, and let each formula reference only cells you have already entered."
      $sync.askLabel="Teach demo"; $sync.text=$fb; if(-not $sync.mute){ $sync.ttsText=$fb }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      return
    }
    # parse the script into ordered steps: each step = narration + the SET/PUT lines that follow it
    $steps=New-Object System.Collections.ArrayList; $doneSay=""; $curStep=$null
    foreach($ln in ([string]$script -split "`r?`n")){
      $l=$ln.Trim(); if(-not $l){ continue }
      if($l -match '(?i)^STEP\s+(.+)$'){ if($curStep){ [void]$steps.Add($curStep) }; $curStep=@{say=$Matches[1].Trim();ops=(New-Object System.Collections.ArrayList)} }
      elseif($l -match '(?i)^DONE\s*(.*)$'){ if($curStep){ [void]$steps.Add($curStep); $curStep=$null }; $doneSay=$Matches[1].Trim() }
      elseif($l -match '^(SET|PUT)\s+([A-Za-z]{1,3}[0-9]{1,5})\s+(.+)$'){ if($curStep){ [void]$curStep.ops.Add(@{addr=$Matches[2].ToUpper();val=$Matches[3].Trim()}) } }
      elseif($l -match '(?i)^BLANK\s+([A-Za-z]{1,3}[0-9]{1,5})'){ if($curStep){ [void]$curStep.ops.Add(@{addr=$Matches[1].ToUpper();blank=$true}) } }
    }
    if($curStep){ [void]$steps.Add($curStep) }
    if($steps.Count -eq 0){
      $fb="I could not put together a demo just now. In short: "+[string]$topic+" - rebuild the same scenario on a clean sheet and reference only cells you have already entered."
      $sync.askLabel="Teach demo"; $sync.text=$fb; if(-not $sync.mute){ $sync.ttsText=$fb }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      return
    }
    $built=0
    $sync.demoActive=$true
    try{
      $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{ $sync.text="Open Excel first so I can demonstrate."; $sync.askLabel="Teach demo"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
      $wb=$null; if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb=Get-XlBook $xl } else { try{ $wb=$xl.ActiveWorkbook }catch{} }; if($wb){ try{ $wb.Activate() }catch{} }
      if(-not $wb){ $sync.text="Open a workbook in Excel first so I can demonstrate."; $sync.askLabel="Teach demo"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
      $ds=$wb.Worksheets.Add(); try{ $ds.Name=("Coach Demo "+(Get-Date).ToString("HHmm")) }catch{}
      foreach($st in $steps){
        $sayTxt=[string]$st.say
        if($sayTxt){ $sync.ttsText=$sayTxt }
        $t0=(Get-Date)
        while($sync.ttsBusyUntil -le $t0 -and ((Get-Date)-$t0).TotalSeconds -lt 6){ Start-Sleep -Milliseconds 200 }
        foreach($op in $st.ops){
          $addr=[string]$op.addr
          if(-not $addr){ continue }
          $cell=$null
          try{
            $cell=$ds.Range($addr)
            if($op.blank){ try{ $cell.Interior.Color=0x99FFFF }catch{}; try{ $cell.BorderAround() }catch{}; if($sync.formatOn){ try{ $cell.Font.Color=16711680 }catch{}; try{ $cell.NumberFormat='#,##0.00;(#,##0.00)' }catch{} } }
            else{ $val=[string]$op.val; try{ $cell.Formula=$val }catch{ $cell.Value2=$val }; if($sync.formatOn){ Format-XlCell $cell $val }; $built++ }
          }catch{}
          if($cell){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cell) }catch{} }
          Start-Sleep -Milliseconds 250
        }
        while((Get-Date) -lt $sync.ttsBusyUntil -and ((Get-Date)-$t0).TotalSeconds -lt 18){ Start-Sleep -Milliseconds 200 }
        Start-Sleep -Milliseconds 400
      }
      if($sync.formatOn){ $allOps=@(); foreach($s in $steps){ foreach($o in $s.ops){ $allOps+=$o } }; try{ Polish-BuiltSheet $ds $allOps }catch{} }
      if($doneSay){ $sync.ttsText=$doneSay }
      $shName=""; try{ $shName=[string]$ds.Name }catch{}
      $recap="Done on the '"+$shName+"' sheet: a worked example on the LEFT (fully solved"+$(if($sync.lastNudge -and ($sync.lastNudge -ne "OK")){ ", focused on the spot you just slipped on" }else{ "" })+") and a parallel PRACTICE version on the RIGHT with different numbers. Fill in the highlighted yellow cells yourself - I'll check each one as you go."
      $sync.text=$recap; $sync.askLabel="Teach demo"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      try{ foreach($o in @($ds,$wb,$xl)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } } }catch{}
    } finally { $sync.demoActive=$false }
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  TEACH REQ: "+[string]$topic+"`r`nSCRIPT:`r`n"+[string]$script+"`r`ndemo done ("+[string]$built+" cells)`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  }catch{
    $sync.demoActive=$false
    $sync.text="Sorry - the demo hit a snag."; $sync.askLabel="Teach demo"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  TEACH ERROR: "+$_.Exception.Message+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  }
}
# Cheat Sheet: drop a compact quick-reference card (the rules + categories for the
# concept the student is on) into EMPTY columns to the RIGHT of their work, so they
# can glance at it while they go. Reuses Apply-XlOps (empty-only writes + IB
# formatting + retries); demoActive guards the watcher during the multi-cell write.
# Column-letter <-> number helpers + a placement guard. The model is ASKED to lay the cheat
# sheet to the right of the data, but on sheets with scattered blocks it can still land amid
# the work. Shift-OpsRightOfData reads the sheet's rightmost USED column and slides the WHOLE
# card so its leftmost cell starts two columns past it - deterministically guaranteeing it
# never overlaps the student's model (the card's internal layout is preserved).
function Xc-ColToNum([string]$c){ $n=0; foreach($ch in $c.ToUpper().ToCharArray()){ $n=$n*26+([int][char]$ch-64) }; return $n }
function Xc-NumToCol([int]$n){ $s=''; while($n -gt 0){ $m=($n-1)%26; $s=([string][char](65+$m))+$s; $n=[int](($n-$m-1)/26) }; return $s }
# Rightmost USED column, parsed from the Read-ExcelLive text (lines look like "Q2 = ...").
# Parse the already-fetched sheet text instead of a second COM call - the live COM read from
# this worker proved flaky (it silently failed and the card stayed put), and reusing the
# proven text is deterministic.
function Xc-RightmostCol([string]$sheetText){
  if(-not $sheetText){ return 0 }
  $max=0
  foreach($l in ($sheetText -split '\r?\n')){ if($l -match '^\s*([A-Za-z]{1,3})[0-9]{1,5}\s*='){ $cn=Xc-ColToNum $Matches[1]; if($cn -gt $max){ $max=$cn } } }
  return $max
}
# Slide a block of SET/PUT ops so its leftmost column starts two past $lastCol (pure - no COM).
function Shift-OpsRightOfData([string]$ops,[int]$lastCol){
  if(-not $ops){ return $ops }
  if($lastCol -lt 1){ return $ops }
  $safeCol=$lastCol+2
  $minCol=0
  foreach($l in ($ops -split '\r?\n')){ if($l -match '^\s*(SET|PUT)\s+([A-Za-z]{1,3})[0-9]{1,5}\s'){ $cn=Xc-ColToNum $Matches[2]; if($minCol -eq 0 -or $cn -lt $minCol){ $minCol=$cn } } }
  if($minCol -eq 0){ return $ops }
  $shift=$safeCol-$minCol
  if($shift -le 0){ return $ops }   # already right of the data
  $out=foreach($l in ($ops -split '\r?\n')){
    if($l -match '^(\s*)(SET|PUT)\s+([A-Za-z]{1,3})([0-9]{1,5})(\s+.*)$'){ ($Matches[1]+$Matches[2]+' '+(Xc-NumToCol ((Xc-ColToNum $Matches[3])+$shift))+$Matches[4]+$Matches[5]) } else { $l }
  }
  return ($out -join "`r`n")
}
function Make-CheatSheet($topic){
  try{
    if(-not (Get-Command Apply-XlOps -ErrorAction SilentlyContinue)){ $sync.text="Open your workbook in Excel first so I can drop in a cheat sheet."; $sync.askLabel="Cheat sheet"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
    $xlchk=$null; try{ $xlchk=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
    if(-not $xlchk){ $sync.text="Open your workbook in Excel first, then ask me for a cheat sheet."; $sync.askLabel="Cheat sheet"; if(-not $sync.mute){ $sync.ttsText="Open your workbook in Excel first." }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
    try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xlchk) }catch{}
    $fresh=$null; try{ $fresh=Read-ExcelLive }catch{}
    if(-not $fresh){ $fresh=[string]$sync.lastXl }
    $ctx=@(@{type='text';text=("TOPIC the student wants a cheat sheet for: "+[string]$topic)})
    if($sync.sheetPurpose){ $ctx+=@{type='text';text=("What the student is practicing: "+[string]$sync.sheetPurpose)} }
    if($sync.lessonModel){ $ctx+=@{type='text';text=("What the instructor's build looks like: "+[string]$sync.lessonModel)} }
    if($sync.lessonlog){ $ll=[string]$sync.lessonlog; if($ll.Length -gt 900){ $ll=$ll.Substring($ll.Length-900) }; $ctx+=@{type='text';text=("WHAT THE STUDENT IS LEARNING RIGHT NOW (from the live lesson - build on THIS topic, not an old/open sheet from a different subject): "+$ll)} }
    if($sync.lastNudge -and ($sync.lastNudge -ne "OK")){ $ctx+=@{type='text';text=("The concept they most recently slipped on - emphasize it: "+[string]$sync.lastNudge)} }
    if($fresh){ $ctx+=@{type='text';text=("The student's CURRENT sheet - THIS is the exact task to build the cheat sheet for; read its title, row labels and sections to see precisely what they are doing, and make the card specific to it. Place the card in EMPTY columns to the RIGHT of this data - never overwrite it:`n"+$fresh)} }
    if($sync.companyCtx){ $ctx+=@{type='text';text=("Saved figures you may reference: "+[string]$sync.companyCtx)} }
    $sys="You are building a CHEAT SHEET - a compact quick-reference card - inside the student's open Excel sheet. FIRST read their CURRENT sheet below (its title, the row labels, the sections, and what is already filled in vs still blank) and pin down the SPECIFIC task they are doing RIGHT NOW. Build the card for EXACTLY that task: the concrete step-by-step process and the actual formulas needed to complete THIS sheet, referencing its real sections and line items - NOT a generic overview of the broad topic. Place the card starting about TWO columns to the RIGHT of their last used column, in empty cells, so you NEVER overwrite their work. Reply with ONLY these line types, one per line, nothing else. For each cell output a line formatted EXACTLY as: SET <cell> <short text, number, or =formula> - with NO trailing semicolon or punctuation after the value. Then one final line: DONE <one short spoken sentence>. Include a TITLE naming the specific task, then a numbered STEP-BY-STEP PROCESS that walks through THIS sheet in order (Step 1: do X in the named section/cells, Step 2: ... - the real order of operations for this exercise, not just definitions), then a short reference list of the key formulas or rules it uses. The PROCESS is the most important part - lead with it. Keep it SCANNABLE - short imperative lines, no long paragraphs. Plain ASCII. 12 to 26 SET lines. The LAST line is the DONE line."
    $pay=@{ model=$sync.model; max_completion_tokens=2500; reasoning_effort='medium'; messages=@(@{role='system';content=$sys},@{role='user';content=$ctx}) } | ConvertTo-Json -Depth 10
    $bf="$env:TEMP\xc_cheat.json"; [IO.File]::WriteAllText($bf,$pay,(New-Object System.Text.UTF8Encoding($false)))
    $rr=& curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
    $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}
    $ops=$null; if($jj.choices){ $ops=([string]$jj.choices[0].message.content).Trim() }
    if((-not $ops) -or ($ops -notmatch '(?im)^\s*SET\s')){
      $sync.text="I could not put a cheat sheet together just now - give it another go in a moment."; $sync.askLabel="Cheat sheet"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return
    }
    $cheatLastCol = Xc-RightmostCol $fresh
    $ops = Shift-OpsRightOfData $ops $cheatLastCol   # guarantee the card lands past the rightmost used column, never amid the work
    $r=$null; $sync.demoActive=$true
    try{ $r=Apply-XlOps $ops }catch{ $r="Cheat sheet write failed: "+$_.Exception.Message } finally { $sync.demoActive=$false }
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  CHEAT REQ: "+[string]$topic+" (data ends at col "+$cheatLastCol+" -> card shifted past it)`r`nOPS:`r`n"+[string]$ops+"`r`nRESULT: "+[string]$r+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
    if([string]$r -match '(?i)(Excel is not open|No active workbook|would not let me in|failed)'){
      $sync.text=[string]$r; $sync.askLabel="Cheat sheet"; if(-not $sync.mute){ $sync.ttsText="I could not write the cheat sheet - "+[string]$r }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    } else {
      $say="Dropped a cheat sheet to the right of your work - the key rules and categories for this, right there to glance at as you go."
      $sync.text=$say; $sync.askLabel="Cheat sheet"; if(-not $sync.mute){ $sync.ttsText=$say }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    }
  }catch{
    $sync.demoActive=$false
    $sync.text="Sorry - the cheat sheet hit a snag."; $sync.askLabel="Cheat sheet"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  CHEAT ERROR: "+$_.Exception.Message+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  }
}
# Drill mode: build a BLANK but parallel practice exercise on a fresh sheet for
# the student to solve THEMSELVES (not the worked answer - that is Run-Demo). We
# lay out labels, the GIVEN inputs and a clear question, and LEAVE the answer
# cells empty. demoActive returns to $false afterwards so the Excel watcher
# resumes and grades the student's attempt.
function Make-Drill($topic){
  try{
    $xlchk=$null; try{ $xlchk=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
    if(-not $xlchk){ $sync.text="Open your workbook in Excel first, then ask me for a practice problem."; $sync.askLabel="Practice"; if(-not $sync.mute){ $sync.ttsText="Open your workbook in Excel first." }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
    try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($xlchk) }catch{}
    $ctx=@(@{type='text';text=("TOPIC the student asked to practice: "+[string]$topic)})
    $lx=[string]$sync.lastXl; if($lx.Length -gt 1600){ $lx=$lx.Substring($lx.Length-1600) }
    if($lx){ $ctx+=@{type='text';text=("The student's currently-open sheet - make a parallel exercise ONLY if it is the SAME topic they are learning now; if it is a DIFFERENT topic, IGNORE this sheet and build a fresh exercise for the current topic:`n"+$lx)} }
    if($sync.sheetPurpose){ $ctx+=@{type='text';text=("What the student is practicing: "+[string]$sync.sheetPurpose)} }
    if($sync.lessonModel){ $ctx+=@{type='text';text=("What the instructor's build looks like: "+[string]$sync.lessonModel)} }
    if($sync.lessonlog){ $ll=[string]$sync.lessonlog; if($ll.Length -gt 900){ $ll=$ll.Substring($ll.Length-900) }; $ctx+=@{type='text';text=("WHAT THE STUDENT IS LEARNING RIGHT NOW (from the live lesson - build on THIS topic, not an old/open sheet from a different subject): "+$ll)} }
    if($sync.lastNudge -and ($sync.lastNudge -ne "OK")){ $ctx+=@{type='text';text=("The concept behind their most recent mistake (drill this): "+[string]$sync.lastNudge)} }
    if($sync.companyCtx){ $ctx+=@{type='text';text=("Saved figures you may reuse: "+[string]$sync.companyCtx)} }
    $dsys="You are a finance/Excel tutor setting up a practice exercise on a blank sheet. Create a SIMILAR but NEW practice exercise on a blank sheet to cement the concept the student just worked on (their last sheet and recent mistake are given). Use DIFFERENT numbers but the same structure/concept. Set up the labels, the GIVEN input values, and a clear question/instruction - but LEAVE THE ANSWER CELLS EMPTY for the student to fill in. Reply ONLY with lines, one per line, nothing else. For each setup cell a line: SET <cell> <label, given number, or question text> (only the setup - do NOT fill the cells the student should solve, and NO trailing semicolon or punctuation). Then a final line: DONE <one short spoken instruction telling them what to solve>. Rules: start around B2, label rows, plain ASCII, the LAST line is the DONE line, 5-14 SET lines. Never mention cell colors, fonts, borders, number formats or any styling - narrate only the finance and Excel logic."
    $dpay=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort='medium'; messages=@(@{role='system';content=$dsys},@{role='user';content=$ctx}) } | ConvertTo-Json -Depth 10
    $dbf="$env:TEMP\xc_drill.json"; [IO.File]::WriteAllText($dbf,$dpay,(New-Object System.Text.UTF8Encoding($false)))
    $drr=& curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$dbf)
    $djj=$null; try{ $djj=$drr|ConvertFrom-Json }catch{}
    $script=$null; if($djj.choices){ $script=([string]$djj.choices[0].message.content).Trim() }
    if((-not $script) -or ($script -notmatch '(?m)^\s*SET\s')){
      $fb="I could not set one up - try again."
      $sync.askLabel="Practice"; $sync.text=$fb; if(-not $sync.mute){ $sync.ttsText=$fb }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      return
    }
    # parse only SET lines for the setup; capture the DONE line as the spoken instruction
    $ops=New-Object System.Collections.ArrayList; $doneSay=""
    foreach($ln in ([string]$script -split "`r?`n")){
      $l=$ln.Trim(); if(-not $l){ continue }
      if($l -match '(?i)^DONE\s*(.*)$'){ $doneSay=$Matches[1].Trim() }
      elseif($l -match '^SET\s+([A-Za-z]{1,3}[0-9]{1,5})\s+(.+)$'){ [void]$ops.Add(@{addr=$Matches[1].ToUpper();val=$Matches[2].Trim()}) }
    }
    if($ops.Count -eq 0){
      $fb="I could not set one up - try again."
      $sync.askLabel="Practice"; $sync.text=$fb; if(-not $sync.mute){ $sync.ttsText=$fb }; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      return
    }
    $built=0; $shName=""
    $sync.demoActive=$true
    try{
      $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{ $sync.text="Open Excel first so I can set up a practice."; $sync.askLabel="Practice"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
      $wb=$null; if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb=Get-XlBook $xl } else { try{ $wb=$xl.ActiveWorkbook }catch{} }; if($wb){ try{ $wb.Activate() }catch{} }
      if(-not $wb){ $sync.text="Open a workbook in Excel first so I can set up a practice."; $sync.askLabel="Practice"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return }
      $ds=$wb.Worksheets.Add(); try{ $ds.Name=("Practice "+(Get-Date).ToString("HHmm")) }catch{}
      try{ $shName=[string]$ds.Name }catch{}
      foreach($op in $ops){
        $addr=[string]$op.addr; $val=[string]$op.val
        if(-not $addr){ continue }
        $cell=$null
        try{ $cell=$ds.Range($addr); try{ $cell.Formula=$val }catch{ $cell.Value2=$val }; if($sync.formatOn){ Format-XlCell $cell $val }; $built++ }catch{}
        if($cell){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($cell) }catch{} }
        Start-Sleep -Milliseconds 120
      }
      if($sync.formatOn){ try{ Polish-BuiltSheet $ds $ops }catch{} }
      if($doneSay -and (-not $sync.mute)){ $sync.ttsText=$doneSay }
      $sync.text="Set up a practice problem on the '"+$shName+"' sheet - fill in the blank cells and I'll check your answer."
      $sync.askLabel="Practice"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      try{ foreach($o in @($ds,$wb,$xl)){ if($o){ try{ [void][Runtime.InteropServices.Marshal]::ReleaseComObject($o) }catch{} } } }catch{}
    } finally { $sync.demoActive=$false }
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  DRILL REQ: "+[string]$topic+"`r`nSCRIPT:`r`n"+[string]$script+"`r`npractice set up ("+[string]$built+" cells) on '"+$shName+"'`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  }catch{
    $sync.demoActive=$false
    $sync.text="Sorry - I could not set up a practice."; $sync.askLabel="Practice"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  DRILL ERROR: "+$_.Exception.Message+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  }
}
