Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# v4: fastest VALID reasoning_effort per model family - they DISAGREE. gpt-5.5/5.4 take 'none' (reject
# 'minimal'); gpt-5-mini/nano take 'minimal' (reject 'none'); gpt-4o* take no reasoning_effort at all.
# Returns '' to mean "omit reasoning_effort". A wrong value here errors the entire call (silent break).
function XW-FastEff($m){ $m=[string]$m; if($m -match '5\.5|5\.4'){ return 'none' }; if($m -match '^gpt-5'){ return 'minimal' }; return '' }
try{ . (Join-Path $sync.tools "curriculum.ps1") }catch{}
try{ . (Join-Path $sync.tools "observed.ps1") }catch{}   # v3: lets the watcher distill what it sees into the observed curriculum
try{ if(Get-Command Consolidate-WeakPoints -ErrorAction SilentlyContinue){ Consolidate-WeakPoints }; if(Get-Command Build-StruggleProfile -ErrorAction SilentlyContinue){ Build-StruggleProfile } }catch{}

try{ . (Join-Path $sync.tools "workers\xcap.ps1") }catch{}
try{ . (Join-Path $sync.tools "workers\xccap.ps1") }catch{}   # window-capture helpers (Cap/CapWin2/Shrink-B64) live apart so a scanner that quarantines THIS file can't take the cheat-sheet / practice-generator / demo (in xcap.ps1) down with it; every caller guards these with Get-Command and falls back to COM-read text
try{ . (Join-Path $sync.tools "workers\xcshot.ps1") }catch{}   # MANAGED (P/Invoke-free) screen capture - ALWAYS loads even when xccap is AMSI-blocked, so the coach can SEE image/screenshot-based workouts (financials pasted into Excel) without the Defender exclusion
$lastSeg=-1; $rolling=New-Object System.Collections.ArrayList; $lastNudgeT=(Get-Date).AddDays(-1); $lastStruggleLogged=""; $flashed=@{}; $seenNodes=@{}; $revisitLogged=@{}; $lastXlHash=0; $lastXlChange=(Get-Date); $stuckOffered=$false; $askHist=New-Object System.Collections.ArrayList; $followUntil=(Get-Date).AddDays(-1); $seenWb=@{}; $lastCheckT=(Get-Date).AddDays(-1); $lastJumpT=(Get-Date).AddDays(-1); $chatUntil=(Get-Date).AddDays(-1); $lastLessonCap=(Get-Date).AddDays(-1)
# Connect-the-dots recap: synthesize what the student has covered into a CONNECTED concept
# map (big picture -> how it links -> what to shore up), not a list of facts. Pulls their
# knowledge/weak-points (brain), the course sequence (curr), today's session log, and the
# recent lesson. On-demand via a "recap"/"connect the dots" ask.
function Build-Recap {
  if(-not $sync.key){ return "I can't reach the model to build a recap right now - check your connection and try again." }
  $ctx=""
  if($sync.brain){ $b=[string]$sync.brain; if($b.Length -gt 2500){ $b=$b.Substring($b.Length-2500) }; $ctx+="What I have covered + my known weak points:`n"+$b+"`n`n" }
  if($sync.curr){ $cl=[string]$sync.curr; if($cl.Length -gt 1500){ $cl=$cl.Substring(0,1500) }; $ctx+="Course topic sequence:`n"+$cl+"`n`n" }
  try{ $dlog=Join-Path ([string]$sync.coaching) ((Get-Date).ToString("yyyy-MM-dd")+".md"); if(Test-Path $dlog){ $dt=[string](Get-Content $dlog -Raw); if($dt.Length -gt 2000){ $dt=$dt.Substring($dt.Length-2000) }; $ctx+="Today's session log (what I actually worked on):`n"+$dt+"`n`n" } }catch{}
  if($sync.lessonlog){ $ll=[string]$sync.lessonlog; if($ll.Length -gt 800){ $ll=$ll.Substring($ll.Length-800) }; $ctx+="Most recent lesson context:`n"+$ll+"`n" }
  $sysR="You are a finance/Excel tutor helping a Breaking Into Wall Street student CONSOLIDATE and CONNECT what they have been learning. Produce a tight, genuinely connected synthesis - a concept map in prose, NOT a list of disconnected facts. Use markdown with: '## The big picture' (how the pieces they covered fit into the overall financial model and the course's end goal), '## How it connects' (THE KEY SECTION: trace the chain - how each concept builds on and feeds into the others, and how the numbers flow across the three statements), '## Shore these up' (the 1-3 weak spots from their context most worth reviewing next, and why), and '## Remember this' (the single most important linking idea). Be specific to what they actually covered, concise, and genuinely connective. Plain ASCII only."
  $usrR="Here is everything about what I have been studying. Tie it together for me:`n`n"+$(if($ctx){ $ctx }else{ "(not much captured yet - give me a high-level map of how the core accounting / 3-statement / Excel concepts connect, and what to focus on first.)" })
  if([string]$sync.model -match '^gpt-5'){ $payload=@{ model=$sync.model; max_completion_tokens=1600; reasoning_effort='low'; messages=@(@{role='system';content=$sysR},@{role='user';content=$usrR}) } | ConvertTo-Json -Depth 8 }
  else { $payload=@{ model=$sync.model; max_tokens=1600; temperature=0.3; messages=@(@{role='system';content=$sysR},@{role='user';content=$usrR}) } | ConvertTo-Json -Depth 8 }
  $bf="$env:TEMP\xc_recap.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  if($j.error){ return "Recap error: "+[string]$j.error.message }
  return "I couldn't build a recap just now (connection issue). Try again in a moment."
}
while(-not $sync.stop){
  if($sync.typedAsk){
    try{
      $tq=$sync.typedAsk; $sync.typedAsk=""; $tdet=$sync.typedDetail; $isAssist=($tq -eq "__ASSIST__"); $isAudit=($tq -eq "__AUDIT__"); $isKick=($tq -eq "__KICK__"); $isWhy=($tq -eq "__WHY__"); $isCheat=($tq -eq "__CHEAT__"); $isDemo=($tq -eq "__DEMO__")
      if($isCheat){ Make-CheatSheet "the concept on this sheet"; continue }
      if($isDemo){ Run-Demo "the concept on this sheet"; continue }   # Demo+practice button: worked example + blank practice on a new tab
      $isTrace=((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(where (does|do) .*(come|comes) from|trace (cell )?[a-z]{1,3}[0-9]{1,4}|what feeds|how (is|are) .*(calculated|computed|derived)|break (it )?down|walk me back|explain (cell )?[a-z]{1,3}[0-9]{1,4})')); if($isTrace){ $tdet=$true }
      # FAST Assist routing: quick typed asks / Assist (not "Explain in detail", not an audit/kick/why) go to the fast vision model with a small budget and downscaled images. Everything thorough stays on the heavy model.
      $askFast=((-not $tdet) -and (-not $isAudit) -and (-not $isKick) -and (-not $isWhy))
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(how (am i|did i) do|how.s my progress|scorecard|progress report|where do i stand)') -and (Get-Command Build-Scorecard -ErrorAction SilentlyContinue)){
        $sync.askLabel="Scorecard"; $sync.text=(Build-Scorecard); $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
        continue
      }
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(\brecap\b|tie (it|this|them|everything) together|connect the dots|how (does|do) (it|this|these|they|everything) (all )?(connect|fit|link|tie)|big picture (of )?(the |my )?(session|lesson|day|material|everything)|what (have|did) i (learn|cover)|sum(marize|up) (my|the|this|today) ?s?(session|day|lesson|learning|material))')){
        $sync.askLabel="Connect the dots"; $sync.text=(Build-Recap); $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
        continue
      }
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(cheat ?sheet|reference (card|table|sheet)|quick reference|summary (table|card)|give me the rules|rules (table|card)|lesson sheet)')){
        Make-CheatSheet $tq
        continue
      }
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)\b(teach me|show me how|demonstrate|walk me through|walk ?through|how do (i|you) build|show me a|demo|worked example)\b')){
        Run-Demo $tq
        continue
      }
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)\b(similar (exercise|problem|question)|practice (problem|question|this|exercise)|practice exercise|let me (try|practice)|give me (a|another) (problem|exercise|practice|drill|workout)|generate (me )?(a|an|one)?\s*(demo|practice|drill|workout|exercise|problem)|build (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|make (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|drill me|quiz me on this|make me a|make me one|build me one)\b')){
        Make-Drill $tq
        continue
      }
      if($sync.handsOn -and (-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)\b(set ?up|build|fill|create|write|put|label|insert|add|enter|make|lay ?out|fix|change|update|correct|replace|populate|complete|finish|redo|do it)\b')){
        $axr=Invoke-XlAction $tq
        if($axr){
          $sync.text=$axr; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
          [void]$askHist.Add(@{q=$tq;a=$axr}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) }
          continue
        }
      }
      # Screen capture lives in xcap.ps1, which Defender's AMSI heuristic sometimes blocks
      # from loading. Guard EVERY capture call so a missing capture fn/type degrades to "no
      # image" instead of throwing and killing the whole answer - the audit/Assist then run
      # on the EXACT live Excel COM text ($xlA) below, which is the authoritative ground
      # truth anyway. (Durable full-fidelity fix is still the Defender folder exclusion.)
      $exB=$null; $coB=$null
      if(Get-Command CapWin2 -ErrorAction SilentlyContinue){ try{ $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" } }catch{} }
      $aexFg=$false; try{ $afgh=[Win2]::GetForegroundWindow(); $aexFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $afgh }) }catch{}
      $fbB=$null; if((-not $aexFg) -and (Get-Command Cap -ErrorAction SilentlyContinue)){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
      $xlA=$null; if(Get-Command Read-ExcelLive -ErrorAction SilentlyContinue){ try{ $xlA=Read-ExcelLive }catch{} }
      $sysA="You are a sharp, accurate finance and Excel tutor at Breaking Into Wall Street / investment-banking level. Answer the student's question or help with whatever they are doing right now. Work carefully and double-check before answering. Format cleanly with ## headers, **bold** for key terms and the final answer, - bullets, a markdown table (| col | col |) whenever the data is tabular (a comparison, a categorization, or a line-by-line breakdown), and thousands-separated numbers when useful."
      if($isKick){
        $ua="I want a kick-start on the sheet I have open. Look at my Excel and tell me, briefly and directly: what this sheet is asking me to do and the FIRST concrete step to get moving (name the actual starting cell or row from the data). If I have clearly already started, point me at the NEXT step instead. 2-3 sentences, direct and encouraging - do not solve it for me, just get me going."
      } elseif($isWhy){
        $ua="I am STUCK on the single cell my cursor is in right now - the ACTIVE CELL named on the first line of the Excel data (for example 'Active cell D14'). Find that cell's row and read its row label to see what item or decision it is. Teach me JUST this one thing: explain the REASONING for what this specific cell should be, and give me the general RULE I can reuse for cells like it - lead with the concept and the rule, then use the specific answer only as the example that illustrates it. Keep it to 3-5 sentences. Do NOT audit, solve, or comment on the rest of the sheet. Be concrete about WHY, at Breaking Into Wall Street level. If the active cell is empty because I have not answered it yet, that is expected - teach me how to reason it out rather than just stating the answer."
      } elseif($isAudit){
        $ua="Do a THOROUGH final audit of my Excel work, using the EXACT cell data below as the ground truth. Check EVERY cell that holds a formula or entered value against what this sheet is meant to practice and the standard investment-banking method: verify each formula's logic, references, and signs, and recompute the numbers to confirm them. Then report with these sections: '## Verdict' - one line, either correct and complete, or how many issues; '## Issues' - each one as the exact cell, what is wrong, and the exact fix (the correct formula or value); '## Still to do' - only if parts are unfinished; '## Done right' - one short line. Be rigorous; do not wave anything through."
      } else {
        $ua=$(if($isAssist){ "Help me with whatever I am working on right now." }else{ "I ask: "+$tq })
        $ua+=" My practice is NOT always an Excel build. Right now it may be a quiz, a multiple-choice question, or a written exercise in another window (browser, Word, a PDF) with no Excel involved. Use the images of what I am actually looking at and help with THAT. If there is no real Excel work in progress, read the question or exercise on my screen and answer or explain it directly - do not dismiss the other window as irrelevant. Cite exact Excel cells only when there is real Excel data. "+$(if($tdet){ "Explain in detail with the full reasoning and steps, and CHAIN it to the bigger picture: connect it to related concepts I have already covered (in your context), say what it builds on and what it feeds into, and show how these numbers flow through the rest of the model (for example how an income-statement item flows to the cash flow statement and balance sheet). End with a short '## How it connects' that ties it together instead of leaving it as an isolated fact." }else{ "Be concise: the direct answer or fix in 1 to 3 short sentences." })
        if($sync.handsOn){ $ua+=" NOTE: your hands are enabled - you genuinely CAN write into my Excel yourself. Never say you cannot edit Excel; if I am asking you to build or change something, say you can do it and ask me to give it as a direct command." }
        if($isTrace){ $ua+=" TRACE MODE: I want to understand where a value comes from. Identify the exact cell(s) I am asking about, then follow the formula dependency chain BACKWARD step by step using the EXACT cell data, explaining each link in plain English (for example: 'C39 = gross PP&E in C37 minus accumulated depreciation in C38; C38 rolls forward from last period C30 plus this period's depreciation D12'). Finish with one line on what the number ultimately represents." }
      }
      $ca=@(@{type='text';text=$ua})
      if($xlA){ $ca+=@{type='text';text=("[EXACT live Excel data, if relevant - authoritative]:`n"+$xlA)} }
      if($sync.sheetPurpose){ $ca+=@{type='text';text=("Excel sheet context: "+$sync.sheetPurpose)} }
      if($sync.lessonModel){ $ca+=@{type='text';text=("What the instructor's build looks like (from the lesson video): "+$sync.lessonModel)} }
      if($sync.companyCtx){ $ca+=@{type='text';text=[string]$sync.companyCtx} }
      if($sync.lessonlog){ $les2=$sync.lessonlog; if($les2.Length -gt 600){ $les2=$les2.Substring($les2.Length-600) }; $ca+=@{type='text';text=("Recent lesson context: "+$les2)} }
      if($tdet -and $sync.curr){ $cl=[string]$sync.curr; if($cl.Length -gt 1200){ $cl=$cl.Substring(0,1200) }; $ca+=@{type='text';text=("Course topic sequence (use to connect this to what comes before and after it):`n"+$cl)} }
      # v4 TWO-TIER ROUTING (#1 cascade + #2 text-first):
      #  FAST tier (Assist, Kick, simple typed Qs) -> cheap fast model ($sync.fastModel, e.g. gpt-5-mini)
      #    answered TEXT-ONLY off the live Excel COM text ($xlA), which is the authoritative ground truth.
      #  DEEP tier (Audit, "Explain in detail", Why) -> frontier model ($sync.model, gpt-5.5) WITH images.
      $fastTier = ((-not $isAudit) -and (-not $tdet) -and (-not $isWhy))
      # Send a screenshot when we need PIXELS: a deep path, OR no live Excel text (e.g. a browser quiz),
      # OR the sheet has a PASTED IMAGE - a screenshot of financials/charts where the data lives in the
      # picture, not cells ($sync.sheetHasImg, set by Read-ExcelLive). Otherwise stay text-only = faster+cheaper.
      $sendImg = ((-not $fastTier) -or (-not $xlA) -or [bool]$sync.sheetHasImg)
      # High detail when there's a pasted image (tiny 10-K numbers must be legible) or on a deep path.
      $imgDet=$(if($fastTier -and (-not $sync.sheetHasImg)){'low'}else{'high'})
      if($sendImg){
        # Prefer the P/Invoke window grab if it loaded (sharper, Excel-only); else the MANAGED full-screen
        # capture (xcshot.ps1) which ALWAYS works even when xccap is AMSI-blocked. ONE image (cheaper).
        $shotB64=$null
        if($exB){ $shotB64=$exB } elseif($coB){ $shotB64=$coB } elseif($fbB){ $shotB64=$fbB }
        elseif(Get-Command Cap-ScreenB64 -ErrorAction SilentlyContinue){ try{ $shotB64=Cap-ScreenB64 }catch{} }
        if($shotB64 -and (Get-Command Shrink-B64 -ErrorAction SilentlyContinue)){
          $iE=$(if($imgDet -eq 'high'){ Shrink-B64 $shotB64 1536 }else{ Shrink-B64 $shotB64 1024 })
          $ca+=@{type='text';text='[Image: my screen right now - includes Excel and any pasted financial statements / charts / other windows]'}
          $ca+=@{type='image_url';image_url=@{url=('data:'+$iE.mime+';base64,'+$iE.b64);detail=$imgDet}}
        }
      }
      $hm=@(); foreach($h in $askHist){ $hm+=@{role='user';content=[string]$h.q}; $hm+=@{role='assistant';content=[string]$h.a} }
      # #3 prompt caching: the big static system prompt is the cacheable prefix (kept first + stable);
      # volatile data (question, Excel text, screenshot) rides in the user message after it.
      $ma=@(@{role='system';content=($sysA+$sync.brain)})+$hm+@(@{role='user';content=$ca})
      $askModel=$(if($fastTier){ [string]$sync.fastModel }else{ [string]$sync.model })
      if($fastTier){ $askTok=700; $askEff=(XW-FastEff $askModel) }
      else { $askTok=$(if($isAudit){2800}elseif($tdet){2000}elseif($isWhy){1100}else{900}); $askEff=$(if($isAudit){'medium'}else{'low'}) }
      if($askModel -match '^gpt-5'){ $pa=@{ model=$askModel; max_completion_tokens=$askTok; stream=$true; messages=$ma }; if($askEff){ $pa['reasoning_effort']=$askEff }; $pa=($pa | ConvertTo-Json -Depth 12) }
      else { $pa=@{ model=$askModel; max_tokens=$askTok; temperature=0; stream=$true; messages=$ma } | ConvertTo-Json -Depth 12 }
      $abf="$env:TEMP\xc_ask.json"; [IO.File]::WriteAllText($abf,$pa,(New-Object System.Text.UTF8Encoding($false)))
      # #4 STREAMING + progressive render: read the SSE stream and publish the growing text to
      # $sync.streamText each chunk; the main UI loop pushes partials to the panel (XC.streamAnswer)
      # so the answer types out live. The final answer below (via $sync.stamp) then replaces the
      # partial with the full markdown render + TTS. (Verified curl -N streams live in PowerShell.)
      $sbuf=New-Object System.Text.StringBuilder; $aerr=$null
      $sync.streamText=""; $sync.streamStamp=[int]$sync.streamStamp+1
      try{
        & curl.exe -s -N --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$abf) | ForEach-Object {
          $ln=$_
          if($ln -like 'data: *'){
            $dd=$ln.Substring(6); if($dd -eq '[DONE]'){ return }
            try{ $jd=$dd|ConvertFrom-Json; if($jd.error){ $aerr=[string]$jd.error.message }; $delta=[string]$jd.choices[0].delta.content; if($delta){ [void]$sbuf.Append($delta); $sync.streamText=$sbuf.ToString(); $sync.streamStamp=[int]$sync.streamStamp+1 } }catch{}
          } elseif($ln -and $ln.TrimStart().StartsWith('{')){ try{ $je=$ln|ConvertFrom-Json; if($je.error){ $aerr=[string]$je.error.message } }catch{} }
        }
      }catch{ $aerr=$_.Exception.Message }
      $ans=$sbuf.ToString().Trim()
      if(-not $ans){ $ans=$(if($aerr){ "Error: "+$aerr }else{ "No response - check your connection." }) }
      if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $ans=Clean-Answer $ans }
      if(-not $ans){ $ans="That check came back empty - the sheet may be large or the model was slow. Try Check my sheet again." }
      $sync.text=$ans; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
      if($ans -and ($ans -notmatch '^(Error|No response|Sorry)')){
        $qrec=$(if($isAudit){ "(deep audit of my sheet)" }elseif($isKick){ "(kick-start on this sheet)" }elseif($isWhy){ "(why is this cell what it is)" }elseif($isAssist){ "(help with what is on my screen)" }else{ $tq })
        $arec=$(if($ans.Length -gt 1200){ $ans.Substring(0,1200) }else{ $ans })
        [void]$askHist.Add(@{q=$qrec;a=$arec}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) }
        try{ $alog=$(if($ans.Length -gt 600){ $ans.Substring(0,600) }else{ $ans }); [IO.File]::AppendAllText(($env:TEMP+"\xc_ask.log"),((Get-Date).ToString("HH:mm:ss")+"  "+[string]$qrec+" => "+$alog+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
      }
      if($isKick){
        try{
          $sigF=Join-Path $sync.coaching "Signals.md"
          if(-not (Test-Path $sigF)){ [IO.File]::AppendAllText($sigF,"# Signals - behavioral struggle signals`r`n",(New-Object System.Text.UTF8Encoding($false))) }
          $sigP=[string]$sync.sheetPurpose; if(-not $sigP){ $sigP="unknown" }
          [IO.File]::AppendAllText($sigF,("- "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+" | kick | "+$sigP+"`r`n"),(New-Object System.Text.UTF8Encoding($false)))
        }catch{}
      }
      if($isAudit -and $ans -and ($ans -match '##\s*Issues')){
        try{
          $isec=([regex]::Match($ans,'(?s)##\s*Issues(.*?)(?=##|$)')).Groups[1].Value.Trim()
          if($isec -and ($isec -notmatch '^\s*(none|no issues)')){
            if($isec.Length -gt 700){ $isec=$isec.Substring(0,700) }
            if(Get-Command Log-Struggle -ErrorAction SilentlyContinue){ try{ Log-Struggle ("Sheet audit found: "+(($isec -replace '\s+',' ').Trim())) }catch{} }
            if($sync.curr){
              $mp=@{ model="gpt-4o-mini"; max_tokens=40; temperature=0; messages=@(@{role="system";content="Given a CURRICULUM (lines 'ID: topic') and ISSUES found auditing a student's practice sheet, reply with ONLY the single best-matching node ID (like DCF-02), or NONE."},@{role="user";content=("CURRICULUM:`n"+$sync.curr+"`n`nISSUES:`n"+$isec)}) } | ConvertTo-Json -Depth 6
              $mbf="$env:TEMP\xc_amap.json"; [IO.File]::WriteAllText($mbf,$mp,(New-Object System.Text.UTF8Encoding($false)))
              $mr=& curl.exe -s --max-time 20 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$mbf)
              $mj=$null; try{ $mj=$mr|ConvertFrom-Json }catch{}
              if($mj.choices){ $mid=([string]$mj.choices[0].message.content).Trim(); if(($mid -match '^[A-Z]{2,3}-\d{2}$') -and (Get-Command Bump-Mastery -ErrorAction SilentlyContinue)){ try{ Bump-Mastery $mid 'shaky' 'sheet audit found issues' }catch{} } }
            }
          }
        }catch{}
      }
    }catch{ $sync.text="Sorry - that question failed. Try again."; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1 }
    continue
  }
  if($sync.formReq){
    $sync.formReq=$false
    try{
      $fl=[string]$sync.lessonlog; if($fl.Length -gt 500){ $fl=$fl.Substring($fl.Length-500) }
      $fc=@(@{type='text';text="List the 6 to 8 most relevant Excel formulas for what I am practicing right now, most useful first. Reply with ONE formula per line, each line EXACTLY in this format: Name | =FORMULA(example cell refs) | very short when-to-use. Plain ASCII. No preamble, no numbering, nothing else."})
      if($sync.sheetPurpose){ $fc+=@{type='text';text=("What I am practicing: "+$sync.sheetPurpose)} }
      if($fl){ $fc+=@{type='text';text=("Recent lesson: "+$fl)} }
      $fpay=@{ model=$sync.model; max_completion_tokens=900; reasoning_effort='low'; messages=@(@{role='system';content="You are a finance/Excel tutor. Output exactly the requested lines and nothing else."},@{role='user';content=$fc}) } | ConvertTo-Json -Depth 10
      $fbf="$env:TEMP\xc_form.json"; [IO.File]::WriteAllText($fbf,$fpay,(New-Object System.Text.UTF8Encoding($false)))
      $fr=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$fbf)
      $fj=$null; try{ $fj=$fr|ConvertFrom-Json }catch{}
      if($fj.choices){ $ft=([string]$fj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $ft=Clean-Answer $ft }; $sync.formText=$ft } else { $sync.formText="" }
    }catch{ $sync.formText="" }
    $sync.formStamp=$sync.formStamp+1
    continue
  }
  if($sync.idReq){
    $sync.idReq=$false
    try{
      $il=[string]$sync.lessonlog; if($il.Length -gt 400){ $il=$il.Substring($il.Length-400) }
      $ixl=[string]$sync.lastXl; if($ixl.Length -gt 3500){ $ixl=$ixl.Substring(0,3500) }
      $ic=@(@{type='text';text="Below is the EXACT data from my Excel practice sheet. Categorize the line items I am looking at into the buckets that actually fit THIS exercise (for example: current assets vs current liabilities vs long-term items; or operating vs investing vs financing flows; or debt vs cash vs equity in an EV bridge; or inputs vs calculations vs outputs - whichever categories genuinely apply). IMPORTANT: use the classification scheme and the exact terminology MY COURSE has taught me - my covered concepts and the recent lesson are in your context; bucket items the way the instructor would, not generic textbook labels. Reply ONE item per line, EXACTLY in this format: Category | Item name (cell) | very short note on what it contributes to. Put lines of the same category together, most important category first. Plain ASCII. No preamble, nothing else."})
      if($sync.sheetPurpose){ $ic+=@{type='text';text=("What I am practicing: "+$sync.sheetPurpose)} }
      if($il){ $ic+=@{type='text';text=("Recent lesson: "+$il)} }
      if($ixl){ $ic+=@{type='text';text=("EXACT Excel data:`n"+$ixl)} }
      $ipay=@{ model=$sync.model; max_completion_tokens=1100; reasoning_effort='low'; messages=@(@{role='system';content=("You are a finance/Excel tutor who teaches with the student's own course conventions."+$sync.brain)},@{role='user';content=$ic}) } | ConvertTo-Json -Depth 10
      $ibf="$env:TEMP\xc_ident.json"; [IO.File]::WriteAllText($ibf,$ipay,(New-Object System.Text.UTF8Encoding($false)))
      $ir=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$ibf)
      $ij=$null; try{ $ij=$ir|ConvertFrom-Json }catch{}
      if($ij.choices){ $it=([string]$ij.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $it=Clean-Answer $it }; $sync.idText=$it } else { $sync.idText="" }
    }catch{ $sync.idText="" }
    $sync.idStamp=$sync.idStamp+1
    continue
  }
  if($sync.paused -or $sync.micMute){ Start-Sleep -Milliseconds 400; continue }
  try {
    $segs=@(Get-ChildItem $sync.segdir -Filter "seg_*.wav" -ErrorAction SilentlyContinue | Sort-Object Name)
    if($segs.Count -ge 2){
      $newest=$segs[$segs.Count-2]; $segN=-1; try{ $segN=[int]($newest.BaseName.Substring(4)) }catch{}
      if($segN -lt $lastSeg){ $lastSeg=-1 }
      if($segN -gt $lastSeg){
        $lastSeg=$segN; $seg=$newest.FullName; $segT=$newest.LastWriteTime
        $e="$env:TEMP\watch_vol.txt"; & $sync.ff -hide_banner -i $seg -af volumedetect -f null NUL 2>$e
        $ln=Get-Content $e | Where-Object { $_ -match 'mean_volume' } | Select-Object -First 1
        $level=if($ln -match '(-?[0-9.]+) dB'){ [double]$Matches[1] } else { -100 }
        $silent=($level -lt -45); $txt=""
        if(-not $silent){
          $rr=& curl.exe -s --max-time 40 "https://api.openai.com/v1/audio/transcriptions" -H ("Authorization: Bearer "+$sync.key) -F ("file=@"+$seg) -F "model=whisper-1" -F "response_format=json"
          $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}; if($jj.text){ $txt=([string]$jj.text).Trim() }
        }
        $heyHit=($txt -and ($txt -match '(?i)\bhey,?\s*coach\b'))
        $inChatWin=((Get-Date) -lt $chatUntil); $sync.chatOn=$inChatWin
        $isFollow=($txt -and ($txt -notmatch '(?i)\bcoach\b') -and (-not $inChatWin) -and ($txt.Trim().Length -ge 12) -and ($segT -gt $sync.ttsBusyUntil) -and ((Get-Date) -lt $followUntil))
        $asked=($sync.micMode -and (-not $sync.muteMe) -and (-not $heyHit) -and (-not $inChatWin) -and (($txt -match '(?i)\bcoach\b') -or $isFollow))
        if($asked){ $sync.ackPing=$true }
        try{ if($txt -and $txt.Length -gt 2){ [IO.File]::AppendAllText(($env:TEMP+"\xc_voice.log"),((Get-Date).ToString("HH:mm:ss")+"  hey="+[int][bool]$heyHit+" ask="+[int][bool]$asked+" chat="+[int][bool]$inChatWin+" | "+$txt+"`r`n"),(New-Object System.Text.UTF8Encoding($false))) } }catch{}
        if($asked -and ($txt -match '(?i)\b(teach me|show me how|demonstrate|walk me through|walk ?through|how do (i|you) build|show me a|demo|worked example)\b')){
          Run-Demo $txt
          continue
        }
        if($asked -and ($txt -match '(?i)\b(similar (exercise|problem|question)|practice (problem|question|this|exercise)|practice exercise|let me (try|practice)|give me (a|another) (problem|exercise|practice|drill|workout)|generate (me )?(a|an|one)?\s*(demo|practice|drill|workout|exercise|problem)|build (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|make (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|drill me|quiz me on this|make me a|make me one|build me one)\b')){
          Make-Drill $txt
          continue
        }
        if($asked -and $sync.handsOn -and ($txt -match '(?i)\b(set ?up|build|fill|create|write|put|label|insert|add|enter|make|lay ?out|fix|change|update|correct|replace|populate|complete|finish|redo|do it)\b')){
          $axr3=Invoke-XlAction $txt
          if($axr3){
            [void]$askHist.Add(@{q=$txt;a=$axr3}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) }
            $sync.askLabel="Excel action"; $sync.text=$axr3; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
            continue
          }
        }
        $isChat=$false; $chatQ=""
        if($sync.micMode -and (-not $sync.muteMe) -and $txt -and ($segT -gt $sync.ttsBusyUntil) -and (-not $asked)){
          if($heyHit){
            $chatUntil=(Get-Date).AddSeconds(75); $sync.chatOn=$true
            $cq=($txt -replace '(?i)^.*?\bhey,?\s*coach\b[\s,.!?]*','').Trim()
            if($cq.Length -gt 3){ $isChat=$true; $chatQ=$cq }
            else{
              $sync.askLabel="Chat"; $sync.text="I'm here - what's up?"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
              continue
            }
          }
          elseif($inChatWin -and $txt.Trim().Length -ge 3){
            if($txt -match '(?i)(thanks,?\s*coach|thank you,?\s*coach|that.s all|i.m good|\bim good\b|never ?mind|back to work)'){
              $chatUntil=(Get-Date).AddDays(-1); $sync.chatOn=$false
              $sync.askLabel="Chat"; $sync.text="Got it - back to watching."; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
              continue
            }
            $isChat=$true; $chatQ=$txt.Trim()
          }
        }
        if($isChat -and ($chatQ -match '(?i)(how (am i|did i) do|how.s my progress|scorecard|progress report|where do i stand)') -and (Get-Command Build-Scorecard -ErrorAction SilentlyContinue)){
          $sync.ackPing=$true; $chatUntil=(Get-Date).AddSeconds(75); $sync.chatOn=$true
          $sync.askLabel="Scorecard"; $sync.text=(Build-Scorecard); $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
          continue
        }
        if($isChat -and ($chatQ -match '(?i)\b(teach me|show me how|demonstrate|walk me through|walk ?through|how do (i|you) build|show me a|demo|worked example)\b')){
          $sync.ackPing=$true; $chatUntil=(Get-Date).AddSeconds(75)
          Run-Demo $chatQ
          continue
        }
        if($isChat -and ($chatQ -match '(?i)\b(similar (exercise|problem|question)|practice (problem|question|this|exercise)|practice exercise|let me (try|practice)|give me (a|another) (problem|exercise|practice|drill|workout)|generate (me )?(a|an|one)?\s*(demo|practice|drill|workout|exercise|problem)|build (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|make (me )?(a|an|one)?\s*(demo|drill|workout|practice|exercise|problem)|drill me|quiz me on this|make me a|make me one|build me one)\b')){
          $sync.ackPing=$true; $chatUntil=(Get-Date).AddSeconds(75)
          Make-Drill $chatQ
          continue
        }
        if($isChat -and $sync.handsOn -and ($chatQ -match '(?i)\b(set ?up|build|fill|create|write|put|label|insert|add|enter|make|lay ?out|fix|change|update|correct|replace|populate|complete|finish|redo|do it)\b')){
          $sync.ackPing=$true; $chatUntil=(Get-Date).AddSeconds(75)
          $axr2=Invoke-XlAction $chatQ
          if($axr2){
            [void]$askHist.Add(@{q=$chatQ;a=$axr2}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) }
            $sync.askLabel="Excel action"; $sync.text=$axr2; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
            continue
          }
        }
        if($isChat){
          $sync.ackPing=$true; $chatUntil=(Get-Date).AddSeconds(75); $sync.chatOn=$true
          $hm3=@(); foreach($h in $askHist){ $hm3+=@{role='user';content=[string]$h.q}; $hm3+=@{role='assistant';content=[string]$h.a} }
          $cctx="You are a sharp, friendly finance and Excel tutor having a QUICK spoken conversation with a student mid-study. Answer in 1-3 short conversational sentences - direct and natural, like speech. No markdown, no lists, no headers. If they ask about their sheet, use the Excel data provided."
          if($sync.handsOn){ $cctx=$cctx+" NOTE: your hands are enabled - you genuinely CAN write into their Excel. Never say you cannot edit Excel; if they wanted you to build or change something, say you can do it and ask them to give it as a direct command (like: fill row 5 with years, or: fix D24)." }
          $cxl=[string]$sync.lastXl; if($cxl.Length -gt 1500){ $cxl=$cxl.Substring(0,1500) }
          $cmsg=$chatQ
          if($sync.sheetPurpose){ $cmsg=$cmsg+"`n(Context - what I am practicing: "+$sync.sheetPurpose+")" }
          if($sync.companyCtx){ $cmsg=$cmsg+"`n("+[string]$sync.companyCtx+")" }
          if($cxl){ $cmsg=$cmsg+"`n(My Excel right now:`n"+$cxl+")" }
          if($chatQ -match '(?i)(where (does|do) .*(come|comes) from|trace (cell )?[a-z]{1,3}[0-9]{1,4}|what feeds|how (is|are) .*(calculated|computed|derived)|break (it )?down|walk me back|explain (cell )?[a-z]{1,3}[0-9]{1,4})'){ $cmsg=$cmsg+" TRACE MODE: I want to understand where a value comes from. Identify the exact cell(s) I am asking about, then follow the formula dependency chain BACKWARD step by step using the EXACT cell data, explaining each link in plain English (for example: 'C39 = gross PP&E in C37 minus accumulated depreciation in C38; C38 rolls forward from last period C30 plus this period's depreciation D12'). Finish with one line on what the number ultimately represents." }
          $cmsgs=@(@{role='system';content=$cctx})+$hm3+@(@{role='user';content=$cmsg})
          if($sync.chatModel -match '^gpt-5'){ $cpay=@{ model=$sync.chatModel; max_completion_tokens=600; reasoning_effort='none'; messages=$cmsgs } | ConvertTo-Json -Depth 10 }
          else { $cpay=@{ model=$sync.chatModel; max_tokens=220; temperature=0.5; messages=$cmsgs } | ConvertTo-Json -Depth 10 }
          $cbf="$env:TEMP\xc_chat.json"; [IO.File]::WriteAllText($cbf,$cpay,(New-Object System.Text.UTF8Encoding($false)))
          $crr=& curl.exe -s --max-time 25 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$cbf)
          $cjj=$null; try{ $cjj=$crr|ConvertFrom-Json }catch{}
          $cans=if($cjj.choices){ ([string]$cjj.choices[0].message.content).Trim() }else{ "Sorry - say that again?" }
          if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $cans=Clean-Answer $cans }
          if($cans){ [void]$askHist.Add(@{q=$chatQ;a=$cans}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) } }
          $sync.askLabel="Chat"; $sync.text=$cans; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
          continue
        }
        if(-not $asked -and $txt){ [void]$rolling.Add($txt); while($rolling.Count -gt 6){ $rolling.RemoveAt(0) }; $sync.lessonlog=($sync.lessonlog+" "+$txt).Trim(); if($sync.lessonlog.Length -gt 6000){ $sync.lessonlog=$sync.lessonlog.Substring($sync.lessonlog.Length-6000) }; try{ [IO.File]::WriteAllText("$env:TEMP\xc_live_lesson.txt",$sync.lessonlog,(New-Object System.Text.UTF8Encoding($false))) }catch{}; $sync.lessonNoteAt=(Get-Date); $sync.lessonNotes=([int]$sync.lessonNotes)+1 }
        $lessonCtx=($rolling -join " "); $paused=($silent -or $lessonCtx.Length -lt 3)
        $excelFg=$false; try{ $fgh=[Win2]::GetForegroundWindow(); $excelFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $fgh }) }catch{}   # [Win2] inside try: if xcap was AMSI-blocked the type is missing - don't crash the loop
        $working=($excelFg -or $paused)
        if((-not $asked) -and $excelFg -and $txt -and ($txt.Trim().Length -gt 15) -and (-not $sync.typedAsk) -and (((Get-Date)-$lastJumpT).TotalSeconds -ge 120) -and ($txt -match '(?i)(\bwhy\b|how come|\bwait\b|what does|what is|how do|how does|confus|don.t get|do not get|don.t understand|not sure|no idea|i thought|doesn.t make sense)')){
          try{
            $jp=@{ model="gpt-4o-mini"; max_tokens=90; temperature=0; messages=@(@{role="system";content="A finance student is working in Excel and thinking aloud (mic transcription). Decide if they are GENUINELY voicing confusion or a question they would want answered - not reading exercise text aloud, not casual muttering, not talking to someone else. Reply EXACTLY with 'YES: <their question restated clearly>' or 'NO'."},@{role="user";content=$txt}) } | ConvertTo-Json -Depth 6
            $jbf="$env:TEMP\xc_jump.json"; [IO.File]::WriteAllText($jbf,$jp,(New-Object System.Text.UTF8Encoding($false)))
            $jr=& curl.exe -s --max-time 15 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$jbf)
            $jj2=$null; try{ $jj2=$jr|ConvertFrom-Json }catch{}
            if($jj2.choices){ $jt=([string]$jj2.choices[0].message.content).Trim(); if($jt -match '(?s)^YES:\s*(.+)$'){ $lastJumpT=(Get-Date); $sync.ackPing=$true; $sync.askLabel="You sounded unsure - jumping in"; $sync.typedDetail=$false; $sync.typedAsk=$Matches[1].Trim() } }
          }catch{}
        }
        $exB=$null; $coB=$null
        if(Get-Command CapWin2 -ErrorAction SilentlyContinue){ try{ $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" } }catch{} }
        if($coB){ $sync.courseSeenAt=(Get-Date) }
        $fbB=$null; if(((-not $exB -and -not $coB) -or (-not $excelFg)) -and (Get-Command Cap -ErrorAction SilentlyContinue)){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
        $xlLive=$null; if($asked -and (Get-Command Read-ExcelLive -ErrorAction SilentlyContinue)){ try{ $xlLive=Read-ExcelLive }catch{} }
        $doCheck=($asked -or (-not $working))
        if($doCheck){
        if($asked){
          $u="The student spoke to you and asked: '"+$txt+"'. What the instructor has recently been teaching (lesson audio): '"+$sync.lessonlog+"'. You are given up to two labeled images: MY Excel sheet (my own work) and the course/lesson. Read the exact question carefully, work it out step by step and double-check any arithmetic, then answer clearly and helpfully in 1 to 4 sentences - explain it so they understand, like a good tutor. Use my Excel, the course image, this lesson context, and your memory of their weak points. If it was not a real question, reply EXACTLY: OK"
          if($sync.handsOn){ $u+=" NOTE: your hands are enabled - you genuinely CAN write into the student's Excel yourself; never say you cannot edit Excel." }
          if($txt -match '(?i)(where (does|do) .*(come|comes) from|trace (cell )?[a-z]{1,3}[0-9]{1,4}|what feeds|how (is|are) .*(calculated|computed|derived)|break (it )?down|walk me back|explain (cell )?[a-z]{1,3}[0-9]{1,4})'){ $u+=" TRACE MODE: I want to understand where a value comes from. Identify the exact cell(s) I am asking about, then follow the formula dependency chain BACKWARD step by step using the EXACT cell data, explaining each link in plain English (for example: 'C39 = gross PP&E in C37 minus accumulated depreciation in C38; C38 rolls forward from last period C30 plus this period's depreciation D12'). Finish with one line on what the number ultimately represents." }
          $useModel=$sync.model; $det="high"; $maxtok=700; $effort="medium"
        } else {
          if($paused){ $u="The lesson video is paused - I'm working on something (a quiz, an exercise, my Excel). You are given up to two labeled images: MY Excel sheet and the course/lesson. Compare my Excel to what the lesson is teaching. ONLY if you can clearly see a real mistake or that I'm stuck, say specifically what's wrong or the next step (1-2 sentences), citing exact cell addresses ONLY from the EXACT live-Excel data block if one is provided (never guess a cell from the image). If it looks fine or you're unsure, reply EXACTLY: OK." }
          else { $u="Recent lesson audio: '"+$lessonCtx+"'. You are given up to two labeled images: MY Excel sheet and the course/lesson. ONLY if you can clearly see a real, specific mistake in MY Excel versus what the lesson is teaching, point it out (1-2 sentences). If it looks fine or you're not sure, reply EXACTLY: OK - do not guess or nitpick." }
          $u=$(if($working){ "I am working in my Excel right now." }else{ "I am watching the lesson. Recent lesson audio: '"+$lessonCtx+"'." })+" Speak up ONLY for a GENUINE ERROR: a wrong formula, a wrong cell reference, a clearly wrong number, a broken or incorrect link, a wrong sign, or a real conceptual mistake versus standard investment-banking practice. Do NOT comment on the ORDER I do things, building things in a different sequence, a valid alternative method or layout, work that is simply incomplete or in progress, or style. Standard conventions matter for correctness only, never for the order or method I choose. Do NOT compute quiz/test answers yourself; reply OK for those. Before flagging anything, RECOMPUTE it yourself from the EXACT data block and confirm it is truly wrong - if it could be a valid alternative method, a different order, or just unfinished work, it is NOT an error. If there is a genuine error, give ONE short sentence naming the exact cell (from the EXACT data block, never a guessed cell). Otherwise reply EXACTLY: OK."
          if($sync.lastNudge -and $sync.lastNudge -ne 'OK'){ $u+=" You last told me: '"+$sync.lastNudge+"'. Don't repeat it." }
          $useModel=$sync.model; $det=$(if($working){"low"}else{"auto"}); $maxtok=$(if($working){320}else{110}); $effort=$(if($working){"low"}else{"none"})
        }
        $content=@(@{type='text';text=$u})
        if($xlLive){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative; use these cell addresses, values and formulas; never guess a cell from the image]:`n"+$xlLive)} }
        if($sync.sheetPurpose){ $content+=@{type='text';text=("What this practice sheet is for (already understood): "+$sync.sheetPurpose)} }
        if($sync.companyCtx){ $content+=@{type='text';text=[string]$sync.companyCtx} }
        if($asked -or $working){ $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching right now and what I am trying to BUILD in my Excel, then connect them. When you help or flag something, cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."} }
        $content+=@{type='text';text="My practice is NOT always an Excel build - it may be a quiz, a multiple-choice question, or a written exercise in another window (browser, Word, a PDF). Consider what I am ACTUALLY looking at in the images; never dismiss the other window as irrelevant just because it is not Excel."}
        if($exB){ $content+=@{type='text';text='[Image: MY Excel sheet (my own work)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail=$det}} }
        if($coB){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail=$det}} }
        if($fbB){ $content+=@{type='text';text='[Image: my full screen - what I am actually looking at right now]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail=$det}} }
        $hm2=@(); if($asked){ foreach($h in $askHist){ $hm2+=@{role='user';content=[string]$h.q}; $hm2+=@{role='assistant';content=[string]$h.a} } }
        $msgs=@(@{role='system';content=($sync.sys+$sync.brain)})+$hm2+@(@{role='user';content=$content})
        if($useModel -match '^gpt-5'){ $payload=@{ model=$useModel; max_completion_tokens=$maxtok; reasoning_effort=$effort; messages=$msgs } | ConvertTo-Json -Depth 12 }
        else { $payload=@{ model=$useModel; max_tokens=$maxtok; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 12 }
        $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
        $vr=& curl.exe -s --max-time 45 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
        $vj=$null; try{ $vj=$vr|ConvertFrom-Json }catch{}
        $sync.text=if($vj.choices){ $at=([string]$vj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $at=Clean-Answer $at }; $at } else { "OK" }
        if($asked -and $sync.text -and $sync.text -ne "OK"){ $arec2=$(if($sync.text.Length -gt 1200){ $sync.text.Substring(0,1200) }else{ $sync.text }); [void]$askHist.Add(@{q=$txt;a=$arec2}); while($askHist.Count -gt 3){ $askHist.RemoveAt(0) }; $followUntil=(Get-Date).AddSeconds(60) }
        } else { $sync.text="OK" }
        if((-not $asked) -and $sync.text -ne "OK" -and $sync.text -ne ""){ if(((Get-Date)-$lastNudgeT).TotalSeconds -lt 25){ $sync.text="OK" } else { $lastNudgeT=(Get-Date) } }
        if((-not $asked) -and $working -and $sync.text -ne "OK" -and $sync.text -ne ""){ $newStr=$true; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $newStr=(-not (XC-SameIssue $sync.text $lastStruggleLogged)) }; if($newStr){ $lastStruggleLogged=$sync.text; if(Get-Command Log-Struggle -ErrorAction SilentlyContinue){ try{ Log-Struggle $sync.text }catch{} } } }
        if((-not $asked) -and ($sync.text -eq "OK" -or $sync.text -eq "")){
          $flashTxt=($lessonCtx+" "+[string]$sync.sheetPurpose).Trim()
          if((Get-Command Find-WeakFlash -ErrorAction SilentlyContinue) -and $flashTxt.Length -gt 5){
            $fb=$null; try{ $fb=Find-WeakFlash $flashTxt }catch{}
            if($fb){ $fp=$fb -split '\|',2; if(-not $flashed.ContainsKey($fp[0])){ $flashed[$fp[0]]=$true; $sync.text="Heads up - '"+$fp[0]+"' tripped you up before"+$(if($fp.Count -gt 1 -and $fp[1]){ " ("+$fp[1]+")" }else{ "" })+". Take it slow here." } }
          }
        }
        $sync.lesson=$lessonCtx; $sync.isPaused=$working; $sync.isAnswer=$asked; $sync.stamp=$sync.stamp+1
        if((-not $asked) -and (-not $working) -and $txt -and $coB -and (((Get-Date)-$lastLessonCap).TotalSeconds -ge 90)){
          $lastLessonCap=(Get-Date)
          try{
            $lmC=@(@{type='text';text="This is a frame from a finance course video. If the instructor is showing a spreadsheet/model being built, extract its STRUCTURE compactly: each visible row as '<label>: <formula or value>' lines, plus a one-line note of what is being built. If no spreadsheet is visible reply EXACTLY: NOLESSON."})
            $lmC+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail='high'}}
            $lmPay=@{ model=$sync.model; max_completion_tokens=1200; reasoning_effort='low'; messages=@(@{role='system';content="You extract spreadsheet structure from a single course-video frame for a finance student."},@{role='user';content=$lmC}) } | ConvertTo-Json -Depth 10
            $lmBf="$env:TEMP\xc_lesmodel.json"; [IO.File]::WriteAllText($lmBf,$lmPay,(New-Object System.Text.UTF8Encoding($false)))
            $lmR=& curl.exe -s --max-time 60 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$lmBf)
            $lmJ=$null; try{ $lmJ=$lmR|ConvertFrom-Json }catch{}
            if($lmJ.choices){
              $lmT=([string]$lmJ.choices[0].message.content).Trim()
              if($lmT -and ($lmT -notmatch '^\s*NOLESSON')){
                $lmBlk="["+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"]`n"+$lmT
                $lmRoll=([string]$sync.lessonModel+"`n`n"+$lmBlk).Trim()
                if($lmRoll.Length -gt 2500){ $lmRoll=$lmRoll.Substring($lmRoll.Length-2500) }
                $sync.lessonModel=$lmRoll
                try{
                  $lmDir=Join-Path $sync.coaching "LessonModels"; New-Item -ItemType Directory -Force -Path $lmDir | Out-Null
                  $lmF=Join-Path $lmDir ((Get-Date).ToString("yyyy-MM-dd")+".md")
                  if(-not(Test-Path $lmF)){ [IO.File]::AppendAllText($lmF,("# Lesson models - "+(Get-Date).ToString("yyyy-MM-dd")+"`r`n"),(New-Object System.Text.UTF8Encoding($false))) }
                  [IO.File]::AppendAllText($lmF,("`r`n## "+(Get-Date).ToString("HH:mm")+"`r`n"+$lmT+"`r`n"),(New-Object System.Text.UTF8Encoding($false)))
                }catch{}
              }
            }
          }catch{}
        }
        if($segs.Count -gt 40){ for($i=0;$i -lt ($segs.Count-40);$i++){ Remove-Item $segs[$i].FullName -Force -ErrorAction SilentlyContinue } }
        if(-not $asked -and $txt){ $sync.distillbuf=($sync.distillbuf+" "+$txt).Trim(); $sync.distillCount=$sync.distillCount+1 }
        if($sync.distillCount -ge 36 -and $sync.distillbuf.Length -gt 120){
          # v3: distill this excerpt into the structured OBSERVED CURRICULUM (drillable concepts),
          # so the run-through can teach exactly what was just watched - any subject.
          if(Get-Command Obs-Observe -ErrorAction SilentlyContinue){ try{ Obs-Observe $sync.distillbuf | Out-Null }catch{} }
          $dp=@{ model="gpt-4o-mini"; max_tokens=220; temperature=0; messages=@(@{role="system";content="Extract the 1-3 most important finance/Excel concepts or facts taught in this lesson excerpt as concise one-line bullets starting with '- '. No preamble; skip trivial chatter."},@{role="user";content=$sync.distillbuf}) } | ConvertTo-Json -Depth 6
          $dbf="$env:TEMP\xc_distill.json"; [IO.File]::WriteAllText($dbf,$dp,(New-Object System.Text.UTF8Encoding($false)))
          $dr=& curl.exe -s --max-time 15 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$dbf)
          $dj=$null; try{ $dj=$dr|ConvertFrom-Json }catch{}
          if($dj.choices){ $kf=Join-Path $sync.coaching "Knowledge.md"; if(-not(Test-Path $kf)){ [IO.File]::AppendAllText($kf,"# Knowledge - concepts from the lessons`n",(New-Object System.Text.UTF8Encoding($false))) }; [IO.File]::AppendAllText($kf,"`n"+([string]$dj.choices[0].message.content).Trim()+"`n",(New-Object System.Text.UTF8Encoding($false))) }
          $wp=@{ model="gpt-4o-mini"; max_tokens=160; temperature=0; messages=@(@{role="system";content="This is a transcript of a study session: an instructor teaching, plus the STUDENT reacting and thinking aloud. Output ONLY genuine signs the STUDENT was confused, unsure, guessed, or struggled, as 1-2 short bullets starting with '- ' (quote the student's words if useful). Ignore the instructor's explanations. If there are no real struggle signs, reply exactly: NONE"},@{role="user";content=$sync.distillbuf}) } | ConvertTo-Json -Depth 6
          $wbf="$env:TEMP\xc_wp.json"; [IO.File]::WriteAllText($wbf,$wp,(New-Object System.Text.UTF8Encoding($false)))
          $wr=& curl.exe -s --max-time 15 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$wbf)
          $wj=$null; try{ $wj=$wr|ConvertFrom-Json }catch{}
          if($wj.choices){ $wpt=([string]$wj.choices[0].message.content).Trim(); if($wpt -and ($wpt -match '(?m)^\s*-\s') -and ($wpt -notmatch '(?i)\bnone\b')){ $wpf2=Join-Path $sync.coaching "Weak Points.md"; if(-not(Test-Path $wpf2)){ [IO.File]::AppendAllText($wpf2,"# Weak Points (accumulating across sessions)`n",(New-Object System.Text.UTF8Encoding($false))) }; [IO.File]::AppendAllText($wpf2,"`n## (live) "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"`n"+$wpt+"`n",(New-Object System.Text.UTF8Encoding($false))) } }
          if($sync.curr){
            $cp=@{ model="gpt-4o-mini"; max_tokens=180; temperature=0; messages=@(@{role="system";content="You map a study-session transcript to a finance curriculum. Given the CURRICULUM (lines 'ID: topic') and a TRANSCRIPT EXCERPT, output one line per relevant node: '<ID>|COVERED|HIGH' if the excerpt clearly teaches or practices it (HIGH only if unambiguous, else use LOW), or '<ID>|STRUGGLED' if the STUDENT seemed confused or unsure about it. Only list nodes with real evidence. If none, reply exactly: NONE"},@{role="user";content=("CURRICULUM:`n"+$sync.curr+"`n`nTRANSCRIPT EXCERPT:`n"+$sync.distillbuf)}) } | ConvertTo-Json -Depth 6
            $cbf="$env:TEMP\xc_curr.json"; [IO.File]::WriteAllText($cbf,$cp,(New-Object System.Text.UTF8Encoding($false)))
            $cr=& curl.exe -s --max-time 15 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$cbf)
            $cj=$null; try{ $cj=$cr|ConvertFrom-Json }catch{}
            if($cj.choices){ $ct=([string]$cj.choices[0].message.content).Trim(); foreach($cl in ($ct -split "`n")){ $cpp=$cl.Trim() -split '\|'; if($cpp.Count -ge 2){ $nid=$cpp[0].Trim(); $kind=$cpp[1].Trim().ToUpper();
              if($nid){
                if($seenNodes.ContainsKey($nid)){
                  if(-not $revisitLogged.ContainsKey($nid)){
                    $revisitLogged[$nid]=$true
                    try{
                      $rtopic=$nid
                      if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ $cn=Get-Curriculum | Where-Object { $_.id -eq $nid } | Select-Object -First 1; if($cn){ $rtopic=$cn.topic } }
                      if($rtopic -eq $nid -and $sync.curr){ foreach($crl in ($sync.curr -split "`n")){ if($crl -match ('^\s*'+[regex]::Escape($nid)+'\s*:\s*(.+)$')){ $rtopic=$Matches[1].Trim(); break } } }
                      $sigF2=Join-Path $sync.coaching "Signals.md"
                      if(-not (Test-Path $sigF2)){ [IO.File]::AppendAllText($sigF2,"# Signals - behavioral struggle signals`r`n",(New-Object System.Text.UTF8Encoding($false))) }
                      [IO.File]::AppendAllText($sigF2,("- "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+" | revisit | "+$rtopic+"`r`n"),(New-Object System.Text.UTF8Encoding($false)))
                    }catch{}
                  }
                } else { $seenNodes[$nid]=$true }
              }
              if($kind -eq 'COVERED' -and $cpp.Count -ge 3 -and $cpp[2].Trim().ToUpper() -eq 'HIGH'){ try{ Bump-Mastery $nid 'exposed' 'covered in lesson' }catch{} } elseif($kind -eq 'STRUGGLED'){ try{ Bump-Mastery $nid 'shaky' 'struggled in lesson' }catch{} } } } }
          }
          $sync.distillbuf=""; $sync.distillCount=0
          if(Get-Command Build-FullBrain -ErrorAction SilentlyContinue){ try{ $sync.brain=Build-FullBrain }catch{} }
        }
      }
    }
  } catch {}
  Start-Sleep -Milliseconds 700
}
