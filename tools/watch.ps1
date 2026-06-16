# watch.ps1 - LIVE ambient coach. Continuously listens + watches (non-freezing).
#   A background ffmpeg records the lesson audio NONSTOP into 10s segments. A worker thread transcribes
#   each new segment the moment it's ready (rolling ~30s lesson context), checks your screen every ~10s,
#   detects PAUSE via silence (=> you're doing the activity/stuck => active help), and uses your memory
#   (Weak Points). Strip overlay stays smooth and is invisible to recordings.
# Test: watch.ps1 -TestAsync   (starts capture, processes one segment, prints, exits)
param([switch]$TestAsync)

$Vault="C:\Users\jonah\Projects\excel-coach"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"
try{ [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $OutputEncoding=[System.Text.Encoding]::UTF8 }catch{}
Add-Type 'using System; using System.Runtime.InteropServices; public class DpiBoot { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[void][DpiBoot]::SetProcessDPIAware()  # MUST run before any window/USER32 call or the process locks DPI-unaware (blurry 150 percent bitmap stretch)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Speech
Add-Type @'
using System; using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
}
'@
function Read-EnvVal($name,$default){ $l=Get-Content $EnvFile | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1; if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default } }
$ff=(Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if(-not $ff){ $ff=(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

$sync=[hashtable]::Synchronized(@{})
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false; $sync.lessonlog=""; $sync.coaching=$Coaching; $sync.distillbuf=""; $sync.distillCount=0; $sync.micMode=$true; $sync.srcLabel=""; $sync.pcWanted=$false; $sync.ttsText=""; $sync.ttsStop=$false; $sync.ttsVoice=(Read-EnvVal "TTS_VOICE" "onyx"); $sync.ttsMode=(Read-EnvVal "TTS" "openai"); $sync.lastWb=""; $sync.muteSound=$false; $sync.sheetPurpose=""; $sync.typedAsk=""; $sync.typedDetail=$false; $sync.askLabel=""; $sync.ackPing=$false; $sync.ttsBusyUntil=(Get-Date).AddDays(-1); $sync.xlText=""; $sync.xlStamp=0; $sync.formReq=$false; $sync.formText=""; $sync.formStamp=0; $sync.lessonModel=""; $sync.teachOn=$true; $sync.demoActive=$false; $sync.cancelled=$false
$sync.fishKey=(Read-EnvVal "FISH_API_KEY" ""); $sync.fishVoice=(Read-EnvVal "FISH_VOICE" ""); $sync.chatModel=(Read-EnvVal "CHAT_MODEL" "gpt-4o-mini"); $sync.chatOn=$false; $sync.lastXl=""
$sync.idReq=$false; $sync.idText=""; $sync.idStamp=0; $sync.handsOn=$true; $sync.company=""; $sync.companyCtx=""; $sync.formatOn=$true; $sync.guideOn=$true; $sync.ttsVol=1.0; $sync.micMute=$false; $sync.woActive=$false; $sync.wHB=(Get-Date)
if($sync.fishKey){ $sync.ttsMode="fish" }
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model=(Read-EnvVal "WATCH_MODEL" "gpt-5.5"); $sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.segdir=Join-Path $env:TEMP "watch_seg"
$sync.sys="You are a precise, helpful live study tutor for a student doing a Breaking Into Wall Street finance course. Work out what the student is ACTUALLY doing on screen (a quiz, a video, an Excel model, reading, etc.) and help with THAT. Be accurate and conservative: only say something is wrong if you can CLEARLY see it - never guess or nitpick. Refer to things by their on-screen label/name, not guessed cell coordinates. When you do speak, be clear and explain briefly so they understand. If nothing genuinely needs saying, reply EXACTLY: OK. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }
try{ . (Join-Path $PSScriptRoot "curriculum.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "deck.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "practice.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "runthrough.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "perf.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "updater.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "setup.ps1") }catch{}
$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (call out by name if one recurs): "+$bt }
$spf=Join-Path $Coaching "Struggle Profile.md"
if(Test-Path $spf){ $spt=(Get-Content $spf -Raw); if($spt.Length -gt 1200){ $spt=$spt.Substring($spt.Length-1200) }; $sync.brain=$sync.brain+" The student's weakest categories and where to start (use this to prioritize help and to know where they struggle most): "+$spt.Trim() }
$kfb=Join-Path $Coaching "Knowledge.md"
if(Test-Path $kfb){ $kt=(Get-Content $kfb -Raw); if($kt.Length -gt 2000){ $kt=$kt.Substring($kt.Length-2000) }; $sync.brain=$sync.brain+" Concepts the student has already covered in lessons: "+$kt }
$WatchCur=(Read-EnvVal "WATCH_CURRICULUM" "1"); $sync.curr=""
if($WatchCur -eq "1"){ try{ . (Join-Path $PSScriptRoot "curriculum.ps1"); try{ Compact-File (Join-Path $Coaching "Mastery.md") 0 }catch{}; $sync.brain=$sync.brain+(Build-CurriculumBrain); $sync.curr=((Get-Curriculum | ForEach-Object { $_.id+": "+$_.topic }) -join "`n") }catch{} }

# audio source: microphone. (Capturing system/PC audio via loopback makes the tool
# look like spyware to Windows Defender, which hard-blocks it; the mic hears the lesson
# through the speakers anyway.) Override the device name with MIC_DEVICE in .env.
$sync.micMode=$true; $sync.srcLabel="Microphone ("+$sync.mic+")"
Write-Host ("Audio source: "+$sync.srcLabel)

# takeover: a new launch replaces any previous coach - kill stale watch.ps1
# instances and orphaned mic recorders so exactly one coach runs after any start
try{
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\b[^|;]*watch\.ps1' } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'watch_seg' } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
  Start-Sleep -Milliseconds 600
}catch{}

# start NONSTOP segmented audio capture
if(Test-Path $sync.segdir){ Remove-Item $sync.segdir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sync.segdir | Out-Null
$ffArgs='-hide_banner -loglevel error -f dshow -i audio="'+$sync.mic+'" -y -map 0:a -f segment -segment_time 5 -ac 1 -ar 16000 -reset_timestamps 1 "'+(Join-Path $sync.segdir "seg_%03d.wav")+'" -map 0:a -f segment -segment_time 1 -segment_wrap 8 -ac 1 -ar 16000 -reset_timestamps 1 "'+(Join-Path $sync.segdir "lvl_%01d.wav")+'"'
$ffp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
$sync.chime=Join-Path $env:TEMP "xc_chime.wav"; try{ & $ff -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=659:duration=0.10" -f lavfi -i "sine=frequency=988:duration=0.17" -filter_complex "[0]volume=0.15,afade=t=in:st=0:d=0.01,afade=t=out:st=0.05:d=0.05[a];[1]volume=0.17,afade=t=in:st=0:d=0.01,afade=t=out:st=0.10:d=0.07[b];[a][b]concat=n=2:v=0:a=1,aecho=0.8:0.9:40:0.2" -ar 44100 -ac 2 $sync.chime 2>$null }catch{}
$sync.ffpid=$ffp.Id

$work=@'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type 'using System; using System.Runtime.InteropServices; public class Win2 { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags); }'
try{ . "C:\Users\jonah\Projects\excel-coach\tools\curriculum.ps1" }catch{}
try{ if(Get-Command Consolidate-WeakPoints -ErrorAction SilentlyContinue){ Consolidate-WeakPoints }; if(Get-Command Build-StruggleProfile -ErrorAction SilentlyContinue){ Build-StruggleProfile } }catch{}

# The coach's hands: turn a natural-language request into SET/SHEET ops and
# execute them via Apply-XlOps. Returns the spoken summary, or $null if the
# request was not really an Excel-building action (caller falls back to Q&A).
function Invoke-XlAction($req){
  if(-not (Get-Command Apply-XlOps -ErrorAction SilentlyContinue)){ return $null }
  $fresh=$null; try{ $fresh=Read-ExcelLive }catch{}
  if(-not $fresh){ $fresh=[string]$sync.lastXl }
  $ac=@(@{type='text';text=("REQUEST: "+$req)})
  if($sync.sheetPurpose){ $ac+=@{type='text';text=("What the student is practicing: "+$sync.sheetPurpose)} }
  if($sync.companyCtx){ $ac+=@{type='text';text=("Use these saved figures when the request refers to them: "+[string]$sync.companyCtx)} }
  if($fresh){ $ac+=@{type='text';text=("EXACT current Excel data (active sheet):`n"+$fresh)} }
  $apay=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort='medium'; messages=@(@{role='system';content="You control Microsoft Excel for a finance student via a tiny operation language. If the REQUEST asks you to build, fill, set up, label, write, fix, or change something in Excel, reply ONLY with operation lines:`nSET <cell> <label or number or =formula>   (writes only if the cell is empty)`nPUT <cell> <label or number or =formula>   (overwrites - use ONLY when the request explicitly asks to change, fix, replace or correct existing content)`nSHEET <NewSheetName>`nDONE <one short spoken confirmation of what you built>`nRules: work on the ACTIVE sheet shown in the data (or create a SHEET first if asked for a new one); do exactly what was asked - minimal, clean, laid out like an investment-banking model; formulas start with =; before writing the DONE line, double-check every formula so its cell references point at cells you actually wrote or that already exist in the data; the LAST line must be the DONE line. If the REQUEST is NOT asking you to write into Excel, reply EXACTLY: NOTACTION"},@{role='user';content=$ac}) } | ConvertTo-Json -Depth 10
  $abf2="$env:TEMP\xc_act.json"; [IO.File]::WriteAllText($abf2,$apay,(New-Object System.Text.UTF8Encoding($false)))
  $arr2=& curl.exe -s --max-time 60 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$abf2)
  $ajj2=$null; try{ $ajj2=$arr2|ConvertFrom-Json }catch{}
  if(-not $ajj2.choices){ return $null }
  $aops=([string]$ajj2.choices[0].message.content).Trim()
  if((-not $aops) -or ($aops -match '^\s*NOTACTION')){ return $null }
  if($aops -notmatch '(?m)^(SET|PUT|SHEET)\s'){ return $null }
  $r=$null; $applied=$false; try{ $r=Apply-XlOps $aops; $applied=$true }catch{ $r="Excel action failed: "+$_.Exception.Message }
  try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  REQ: "+$req+"`r`nOPS:`r`n"+$aops+"`r`nRESULT: "+$r+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
  # self-verify: re-read the sheet, make the model confirm every requested item landed, repair if not (max 2 rounds)
  if($applied -and $r -and ($r -notmatch '^(Excel is not open|No active workbook|Excel would not let me in)')){
    $allOps=$aops; $lastRes=[string]$r; $verified=$false; $vfail=$false
    for($vround=1;$vround -le 2;$vround++){
      Start-Sleep -Milliseconds 1500
      $after=$null; try{ $after=Read-ExcelLive }catch{}
      if(-not $after){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  VERIFY round "+$vround+": could not re-read the sheet - verification skipped`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}; break }
      $vc=@(@{type='text';text=("ORIGINAL REQUEST: "+$req)})
      $vc+=@{type='text';text=("OPS APPLIED SO FAR:`n"+$allOps)}
      $vc+=@{type='text';text=("APPLY SUMMARY (names any cells that could NOT be written): "+$lastRes)}
      $vc+=@{type='text';text=("EXACT Excel data NOW, after the writes (active sheet):`n"+$after)}
      $vpay=@{ model=$sync.model; max_completion_tokens=2500; reasoning_effort='medium'; messages=@(@{role='system';content="You just wrote into a finance student's Excel using SET/PUT/SHEET operation lines and must now VERIFY your own work. You are given the ORIGINAL REQUEST, the ops applied so far, the apply summary (it lists any cells that could NOT be written - those cells are still empty), and the EXACT sheet data as it is NOW. Recompute every formula from this data and confirm EVERY item the request asked for actually landed with correct cell references, labels, numbers and formulas. If anything is missing or wrong, reply ONLY with repair operation lines, one per line:`nSET <cell> <label or number or =formula>   (for cells that are empty now, including the could-NOT-write ones)`nPUT <cell> <label or number or =formula>   (ONLY to fix a cell the ops above just wrote with wrong content - never touch any other cell)`nNo DONE line, no commentary. If every requested item is present and correct, reply EXACTLY: VERIFIED"},@{role='user';content=$vc}) } | ConvertTo-Json -Depth 10
      $vbf="$env:TEMP\xc_verify.json"; [IO.File]::WriteAllText($vbf,$vpay,(New-Object System.Text.UTF8Encoding($false)))
      $vrr=& curl.exe -s --max-time 60 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$vbf)
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
    if($fresh){ $ctx+=@{type='text';text=("The student's CURRENT sheet. Place the cheat sheet in EMPTY columns to the RIGHT of this data - never overwrite it:`n"+$fresh)} }
    if($sync.companyCtx){ $ctx+=@{type='text';text=("Saved figures you may reference: "+[string]$sync.companyCtx)} }
    $sys="You are building a CHEAT SHEET - a compact quick-reference card - inside the student's open Excel sheet for the concept they are working on. Look at their current data and place the card starting about TWO columns to the RIGHT of their last used column, in empty cells, so you NEVER overwrite their work. Reply with ONLY these line types, one per line, nothing else. For each cell output a line formatted EXACTLY as: SET <cell> <short text, number, or =formula> - with NO trailing semicolon or punctuation after the value. Then one final line: DONE <one short spoken sentence>. Include a TITLE, then a numbered STEP-BY-STEP PROCESS for completing this kind of task in order (Step 1: do X, Step 2: do Y, ... - the actual order of operations someone follows, not just definitions), then a short reference list of the key formulas or rules. The PROCESS is the most important part - lead with it. Keep it SCANNABLE - short imperative lines, no long paragraphs. Plain ASCII. 12 to 26 SET lines. The LAST line is the DONE line."
    $pay=@{ model=$sync.model; max_completion_tokens=2500; reasoning_effort='medium'; messages=@(@{role='system';content=$sys},@{role='user';content=$ctx}) } | ConvertTo-Json -Depth 10
    $bf="$env:TEMP\xc_cheat.json"; [IO.File]::WriteAllText($bf,$pay,(New-Object System.Text.UTF8Encoding($false)))
    $rr=& curl.exe -s --max-time 70 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
    $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}
    $ops=$null; if($jj.choices){ $ops=([string]$jj.choices[0].message.content).Trim() }
    if((-not $ops) -or ($ops -notmatch '(?im)^\s*SET\s')){
      $sync.text="I could not put a cheat sheet together just now - give it another go in a moment."; $sync.askLabel="Cheat sheet"; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1; return
    }
    $r=$null; $sync.demoActive=$true
    try{ $r=Apply-XlOps $ops }catch{ $r="Cheat sheet write failed: "+$_.Exception.Message } finally { $sync.demoActive=$false }
    try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_hands.log"),((Get-Date).ToString("HH:mm:ss")+"  CHEAT REQ: "+[string]$topic+"`r`nOPS:`r`n"+[string]$ops+"`r`nRESULT: "+[string]$r+"`r`n`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{}
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
function Cap($path){
  $h=[Win2]::GetForegroundWindow(); $r=New-Object Win2+RECT; [void][Win2]::GetWindowRect($h,[ref]$r)
  $w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
  if($w -gt 300 -and $ht -gt 200){
    $cap=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($cap)
    try{ $g.CopyFromScreen($r.Left,$r.Top,0,0,(New-Object System.Drawing.Size($w,$ht))) }catch{}; $g.Dispose()
  } else {
    $b=[System.Windows.Forms.SystemInformation]::VirtualScreen; $w=$b.Width; $ht=$b.Height
    $cap=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($cap); $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); $g.Dispose()
  }
  $mw=1700.0; $s=[Math]::Min(1.0,$mw/$w); $nw=[int]($w*$s); $nh=[int]($ht*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g2=[System.Drawing.Graphics]::FromImage($sm); $g2.InterpolationMode='HighQualityBicubic'; $g2.DrawImage($cap,0,0,$nw,$nh); $g2.Dispose()
  $sm.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $cap.Dispose(); $sm.Dispose()
}
function CapWin2($proc){
  $p=Get-Process $proc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Sort-Object { $_.MainWindowTitle.Length } -Descending | Select-Object -First 1
  if(-not $p){ return $null }
  $h=$p.MainWindowHandle; $r=New-Object Win2+RECT; [void][Win2]::GetWindowRect($h,[ref]$r); $w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
  if($w -lt 200 -or $ht -lt 200){ return $null }
  $bmp=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($bmp); $hdc=$g.GetHdc(); [void][Win2]::PrintWindow($h,$hdc,2); $g.ReleaseHdc($hdc); $g.Dispose()
  $mw=1500.0; $s=[Math]::Min(1.0,$mw/$w); $nw=[int]($w*$s); $nh=[int]($ht*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g3=[System.Drawing.Graphics]::FromImage($sm); $g3.InterpolationMode='HighQualityBicubic'; $g3.DrawImage($bmp,0,0,$nw,$nh); $g3.Dispose()
  $f=Join-Path $env:TEMP ("wcap_"+$proc+".png"); $sm.Save($f,[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $sm.Dispose()
  return [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
}
$lastSeg=-1; $rolling=New-Object System.Collections.ArrayList; $lastNudgeT=(Get-Date).AddDays(-1); $lastStruggleLogged=""; $flashed=@{}; $seenNodes=@{}; $revisitLogged=@{}; $lastXlHash=0; $lastXlChange=(Get-Date); $stuckOffered=$false; $askHist=New-Object System.Collections.ArrayList; $followUntil=(Get-Date).AddDays(-1); $seenWb=@{}; $lastCheckT=(Get-Date).AddDays(-1); $lastJumpT=(Get-Date).AddDays(-1); $chatUntil=(Get-Date).AddDays(-1); $lastLessonCap=(Get-Date).AddDays(-1)
while(-not $sync.stop){
  if($sync.typedAsk){
    try{
      $tq=$sync.typedAsk; $sync.typedAsk=""; $tdet=$sync.typedDetail; $isAssist=($tq -eq "__ASSIST__"); $isAudit=($tq -eq "__AUDIT__"); $isKick=($tq -eq "__KICK__"); $isWhy=($tq -eq "__WHY__"); $isCheat=($tq -eq "__CHEAT__")
      if($isCheat){ Make-CheatSheet "the concept on this sheet"; continue }
      $isTrace=((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(where (does|do) .*(come|comes) from|trace (cell )?[a-z]{1,3}[0-9]{1,4}|what feeds|how (is|are) .*(calculated|computed|derived)|break (it )?down|walk me back|explain (cell )?[a-z]{1,3}[0-9]{1,4})')); if($isTrace){ $tdet=$true }
      if((-not $isAssist) -and (-not $isAudit) -and (-not $isKick) -and ($tq -match '(?i)(how (am i|did i) do|how.s my progress|scorecard|progress report|where do i stand)') -and (Get-Command Build-Scorecard -ErrorAction SilentlyContinue)){
        $sync.askLabel="Scorecard"; $sync.text=(Build-Scorecard); $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
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
      $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" }
      $afgh=[Win2]::GetForegroundWindow(); $aexFg=$false; try{ $aexFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $afgh }) }catch{}
      $fbB=$null; if(-not $aexFg){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
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
        $ua+=" My practice is NOT always an Excel build. Right now it may be a quiz, a multiple-choice question, or a written exercise in another window (browser, Word, a PDF) with no Excel involved. Use the images of what I am actually looking at and help with THAT. If there is no real Excel work in progress, read the question or exercise on my screen and answer or explain it directly - do not dismiss the other window as irrelevant. Cite exact Excel cells only when there is real Excel data. "+$(if($tdet){ "Explain in detail with the full reasoning and steps." }else{ "Be concise: the direct answer or fix in 1 to 3 short sentences." })
        if($sync.handsOn){ $ua+=" NOTE: your hands are enabled - you genuinely CAN write into my Excel yourself. Never say you cannot edit Excel; if I am asking you to build or change something, say you can do it and ask me to give it as a direct command." }
        if($isTrace){ $ua+=" TRACE MODE: I want to understand where a value comes from. Identify the exact cell(s) I am asking about, then follow the formula dependency chain BACKWARD step by step using the EXACT cell data, explaining each link in plain English (for example: 'C39 = gross PP&E in C37 minus accumulated depreciation in C38; C38 rolls forward from last period C30 plus this period's depreciation D12'). Finish with one line on what the number ultimately represents." }
      }
      $ca=@(@{type='text';text=$ua})
      if($xlA){ $ca+=@{type='text';text=("[EXACT live Excel data, if relevant - authoritative]:`n"+$xlA)} }
      if($sync.sheetPurpose){ $ca+=@{type='text';text=("Excel sheet context: "+$sync.sheetPurpose)} }
      if($sync.lessonModel){ $ca+=@{type='text';text=("What the instructor's build looks like (from the lesson video): "+$sync.lessonModel)} }
      if($sync.companyCtx){ $ca+=@{type='text';text=[string]$sync.companyCtx} }
      if($sync.lessonlog){ $les2=$sync.lessonlog; if($les2.Length -gt 600){ $les2=$les2.Substring($les2.Length-600) }; $ca+=@{type='text';text=("Recent lesson context: "+$les2)} }
      if($exB){ $ca+=@{type='text';text='[Image: Excel window]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail='high'}} }
      if($coB){ $ca+=@{type='text';text='[Image: browser window]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail='high'}} }
      if($fbB){ $ca+=@{type='text';text='[Image: my full screen - what I am actually looking at right now]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail='high'}} }
      $hm=@(); foreach($h in $askHist){ $hm+=@{role='user';content=[string]$h.q}; $hm+=@{role='assistant';content=[string]$h.a} }
      $ma=@(@{role='system';content=($sysA+$sync.brain)})+$hm+@(@{role='user';content=$ca})
      $pa=@{ model=$sync.model; max_completion_tokens=$(if($isAudit){4500}elseif($tdet){3500}elseif($isKick){600}elseif($isWhy){1100}else{900}); reasoning_effort=$(if($isKick){'low'}else{'medium'}); messages=$ma } | ConvertTo-Json -Depth 12
      $abf="$env:TEMP\xc_ask.json"; [IO.File]::WriteAllText($abf,$pa,(New-Object System.Text.UTF8Encoding($false)))
      $ar=& curl.exe -s --max-time 220 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$abf)
      $aj=$null; try{ $aj=$ar|ConvertFrom-Json }catch{}
      $ans=if($aj.choices){ ([string]$aj.choices[0].message.content).Trim() }elseif($aj.error){ "Error: "+$aj.error.message }else{ "No response - check your connection." }
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
        $fgh=[Win2]::GetForegroundWindow(); $excelFg=$false; try{ $excelFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $fgh }) }catch{}
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
        $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" }; if($coB){ $sync.courseSeenAt=(Get-Date) }
        $fbB=$null; if((-not $exB -and -not $coB) -or (-not $excelFg)){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
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
'@
$rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync',$sync)
$psw=[powershell]::Create(); $psw.Runspace=$rs; [void]$psw.AddScript($work); [void]$psw.BeginInvoke()

# --- Excel watcher: dedicated thread that ONLY catches mistakes. Polls the live
# workbook via COM (no screenshots), checks the exact cells the moment they change,
# and is never blocked by transcription, asks, audits or distillation. ---
$xlWork=@'
function XLog($m){ try{ [IO.File]::AppendAllText(($env:TEMP+"\xc_watcher.log"),((Get-Date).ToString("HH:mm:ss")+"  "+$m+"`r`n"),(New-Object System.Text.UTF8Encoding($false))) }catch{} }
function HashOf($s){ $i=([string]$s).IndexOf("`n"); if($i -gt 0){ return $s.Substring($i).GetHashCode() }; return ([string]$s).GetHashCode() }
try{ . "C:\Users\jonah\Projects\excel-coach\tools\curriculum.ps1" }catch{ XLog ("curriculum load FAILED: "+$_.Exception.Message) }
try{ Add-Type 'using System; using System.Runtime.InteropServices; public class WinX { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); }' -ErrorAction Stop }catch{}
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
  if($sync.guideOn -and $sync.sheetPurpose -and (-not $sync.demoActive) -and ($guideOverviewSheet -ne $sync.lastWb)){
    $guideOverviewSheet=$sync.lastWb; $guideT=(Get-Date)
    try{
      $ou=@(@{type='text';text=("Goal of this sheet: "+[string]$sync.sheetPurpose)})
      $ou+=@{type='text';text=("The student's sheet:`n"+$xl)}
      $ou+=@{type='text';text="This is UNFAMILIAR material for the student. In 3 to 4 short sentences, paint the FULL PICTURE of this whole exercise before they start the steps: what it is overall, its major parts or sections and how they connect, and the end goal - how they will know the whole thing is complete (the final tie-out or check). Plain language, no numeric answers, no preamble - just orient them to the whole."}
      $opay=@{ model="gpt-4o-mini"; max_tokens=350; temperature=0; messages=@(@{role='system';content="You orient a student to an unfamiliar finance/Excel exercise by giving the big picture - the whole structure and the end goal - before any individual step."},@{role='user';content=$ou}) } | ConvertTo-Json -Depth 10
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
      $gpay=@{ model="gpt-4o-mini"; max_tokens=450; temperature=0; messages=@(@{role='system';content="You are a finance/Excel tutor guiding a student through a worksheet ONE step at a time. For the current step you explain WHAT, WHERE, HOW (the process, referencing their actual cells), and WHY - enough that someone who has no idea how to do it can follow - but you NEVER give the final numeric answer; you point at the cells and let them compute it."},@{role='user';content=$gu}) } | ConvertTo-Json -Depth 10
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
    $inst="Below is the EXACT live data from my Excel practice sheet (every non-empty cell: address, value, formula). Check ONLY for a GENUINE ERROR: a wrong formula, a wrong cell reference, a clearly wrong number, a broken or incorrect link, a wrong sign, or a real conceptual mistake versus standard investment-banking practice. RECOMPUTE the values yourself from the data before flagging anything - if it could be a valid alternative method, a different order of steps, or just unfinished work, it is NOT an error (unfinished is fine). Focus FIRST on the cells I just changed (listed below if any) - recompute those carefully. PREDICT AND COMPARE: for each number or formula I have entered, independently work out what that cell SHOULD be from the model's logic; if the instructor's build (lesson structure) is in your context, treat it as the intended target for the matching cells. If my value MATERIALLY differs from what it should be, that is an error. Pay EXTRA attention to mistakes matching my known weak points (in your context). Never reveal the answer to an exercise I have not attempted yet; once I HAVE entered an answer or formula, verify it by computing the correct result yourself. If a genuine error exists: name the exact cell, the EXPECTED value or formula it should be, the fix, and briefly WHY, in one or two short sentences; if it repeats one of my known weak points, add one short sentence stating the underlying rule so I stop repeating it. Otherwise reply EXACTLY: OK."
    if($mode -eq "sweep"){ $inst="This is a periodic DEEP RE-CHECK: do a full careful pass over EVERY formula and entered value on the sheet, recomputing each one - a fast earlier check may have missed something. "+$inst }
    $uc=@(@{type='text';text=$inst})
    if($diffTxt){ $uc+=@{type='text';text=$diffTxt} }
    if($sync.sheetPurpose){ $uc+=@{type='text';text=("What this sheet practices: "+$sync.sheetPurpose)} }
    if($sync.lessonModel){ $uc+=@{type='text';text=("What the instructor's build looks like (from the lesson video): "+$sync.lessonModel)} }
    if($sync.companyCtx){ $uc+=@{type='text';text=[string]$sync.companyCtx} }
    if($les2){ $uc+=@{type='text';text=("Recent lesson context: "+$les2)} }
    if($sync.lastNudge -and $sync.lastNudge -ne "OK"){ $uc+=@{type='text';text=("You last told me: '"+$sync.lastNudge+"'. If I fixed it and nothing else is wrong, reply OK. If it is STILL not fixed, flag it again.")} }
    $uc+=@{type='text';text=("EXACT Excel data:`n"+$xl)}
    $pay=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort="medium"; messages=@(@{role='system';content=("You are a precise, conservative checker and tutor for a finance student rebuilding course models in Excel."+$sync.brain)},@{role='user';content=$uc}) } | ConvertTo-Json -Depth 12
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
'@
$rsX=[runspacefactory]::CreateRunspace(); $rsX.ApartmentState='STA'; $rsX.ThreadOptions='ReuseThread'; $rsX.Open()
$rsX.SessionStateProxy.SetVariable('sync',$sync)
$psx=[powershell]::Create(); $psx.Runspace=$rsX; [void]$psx.AddScript($xlWork); [void]$psx.BeginInvoke()

# --- voice thread: OpenAI TTS (natural) with Windows-voice fallback; non-blocking ---
$ttsWork=@'
Add-Type -AssemblyName System.Speech
$sp=New-Object System.Speech.Synthesis.SpeechSynthesizer; try{ $sp.Rate=1 }catch{}
$cur=$null
while(-not $sync.stop){
  if($sync.ttsStop){ $sync.ttsStop=$false; if($cur){ try{ $cur.Stop() }catch{} }; try{ $sp.SpeakAsyncCancelAll() }catch{} }
  $t=$sync.ttsText
  if($t){
    $sync.ttsText=""
    $t=$t -replace '\*\*','' -replace '__','' -replace '`','' -replace '(?m)^\s{0,3}#{1,6}\s*','' -replace '(?m)^\s*[\*\-\+]\s+',''
    if($cur){ try{ $cur.Stop() }catch{} }; try{ $sp.SpeakAsyncCancelAll() }catch{}
    $spoke=$false
    if($sync.ttsMode -eq 'fish' -and $sync.fishKey){
      try{
        $fb=@{ text=$t; format="mp3" }
        if($sync.fishVoice){ $fb.reference_id=$sync.fishVoice }
        $fbody=$fb | ConvertTo-Json -Compress
        $fbf="$env:TEMP\xc_fish_body.json"; [IO.File]::WriteAllText($fbf,$fbody,(New-Object System.Text.UTF8Encoding($false)))
        $fraw="$env:TEMP\xc_fish_raw.mp3"; if(Test-Path $fraw){ Remove-Item $fraw -Force -ErrorAction SilentlyContinue }
        & curl.exe -s --max-time 30 "https://api.fish.audio/v1/tts" -H ("Authorization: Bearer "+$sync.fishKey) -H "Content-Type: application/json" -d ("@"+$fbf) -o $fraw 2>$null
        if((Test-Path $fraw) -and ((Get-Item $fraw).Length -gt 800)){
          $pcm="$env:TEMP\xc_tts_pcm.wav"; if(Test-Path $pcm){ Remove-Item $pcm -Force -ErrorAction SilentlyContinue }
          & $sync.ff -hide_banner -loglevel error -y -i $fraw -af ("volume="+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.##}",[double]$sync.ttsVol)) -ar 44100 -ac 2 -c:a pcm_s16le $pcm 2>$null
          if((Test-Path $pcm) -and ((Get-Item $pcm).Length -gt 1000) -and (-not $sync.mute)){ $cur=New-Object System.Media.SoundPlayer $pcm; try{ $cur.Play(); $spoke=$true; $sync.ttsBusyUntil=(Get-Date).AddSeconds(((Get-Item $pcm).Length/176400.0)+1.5) }catch{} }
        }
      }catch{}
    }
    if((-not $spoke) -and $sync.key){
      try{
        $body=@{ model="gpt-4o-mini-tts"; voice=$sync.ttsVoice; input=$t; response_format="wav"; instructions="Speak like a warm, confident investment-banking tutor: clear, encouraging, natural pacing." } | ConvertTo-Json -Compress
        $bf="$env:TEMP\xc_tts_body.json"; [IO.File]::WriteAllText($bf,$body,(New-Object System.Text.UTF8Encoding($false)))
        $raw="$env:TEMP\xc_tts_raw.wav"; if(Test-Path $raw){ Remove-Item $raw -Force -ErrorAction SilentlyContinue }
        & curl.exe -s --max-time 30 "https://api.openai.com/v1/audio/speech" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf) -o $raw 2>$null
        if((Test-Path $raw) -and ((Get-Item $raw).Length -gt 1000)){
          $pcm="$env:TEMP\xc_tts_pcm.wav"; if(Test-Path $pcm){ Remove-Item $pcm -Force -ErrorAction SilentlyContinue }
          & $sync.ff -hide_banner -loglevel error -y -i $raw -af ("volume="+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.##}",[double]$sync.ttsVol)) -ar 44100 -ac 2 -c:a pcm_s16le $pcm 2>$null
          if((Test-Path $pcm) -and ((Get-Item $pcm).Length -gt 1000) -and (-not $sync.mute)){ $cur=New-Object System.Media.SoundPlayer $pcm; try{ $cur.Play(); $spoke=$true; $sync.ttsBusyUntil=(Get-Date).AddSeconds(((Get-Item $pcm).Length/176400.0)+1.5) }catch{} }
        }
      }catch{}
    }
    if((-not $spoke) -and (-not $sync.mute)){ try{ $sp.Volume=[int]([math]::Max(0,[math]::Min(100,[double]$sync.ttsVol*100))) }catch{}; try{ $sp.SpeakAsync($t)|Out-Null; $sync.ttsBusyUntil=(Get-Date).AddSeconds(($t.Length/12.0)+1.5) }catch{} }
  }
  Start-Sleep -Milliseconds 150
}
'@
$rsT=[runspacefactory]::CreateRunspace(); $rsT.ApartmentState='STA'; $rsT.Open(); $rsT.SessionStateProxy.SetVariable('sync',$sync)
$pst=[powershell]::Create(); $pst.Runspace=$rsT; [void]$pst.AddScript($ttsWork); [void]$pst.BeginInvoke()

function Kill-FF { try{ Stop-Process -Id $sync.ffpid -Force -ErrorAction SilentlyContinue }catch{} }

# Live mic level: read the tail of the segment ffmpeg is CURRENTLY writing and
# return average amplitude 0..1 (-1 = unavailable). Lets the strip show that it
# hears the user the instant they speak, instead of after transcription.
function Get-MicLevel {
  try{
    $f=Get-ChildItem $sync.segdir -Filter "lvl_*.wav" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 9000 } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(-not $f){ return -1 }
    if((((Get-Date)-$f.LastWriteTime).TotalSeconds) -gt 4){ return 0 }
    $fs=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
      $len=$fs.Length
      $take=4800
      $off=$len-$take; if($off -lt 44){ $off=44 }; if(($off % 2) -eq 1){ $off=$off-1 }
      [void]$fs.Seek($off,[IO.SeekOrigin]::Begin)
      $buf=New-Object byte[] $take
      $read=$fs.Read($buf,0,$take)
      if($read -lt 200){ return 0 }
      $sum=0.0; $cnt=0
      for($i=0;$i -lt ($read-1);$i+=4){ $v=[BitConverter]::ToInt16($buf,$i); $sum+=[Math]::Abs([double]$v); $cnt++ }
      if($cnt -eq 0){ return 0 }
      return [Math]::Min(1.0,($sum/$cnt)/3000.0)
    } finally { $fs.Close() }
  }catch{ return -1 }
}

if($TestAsync){
  $waited=0; while($sync.stamp -lt 1 -and $waited -lt 50){ Start-Sleep -Milliseconds 500; $waited+=0.5 }
  Write-Host ("stamp="+$sync.stamp+" paused="+$sync.isPaused); Write-Host ("rolling lesson: '"+$sync.lesson+"'"); Write-Host ("Result: "+$sync.text)
  $sync.stop=$true; Start-Sleep -Milliseconds 800; Kill-FF; try{ $rs.Close() }catch{}; exit
}

# ---- UI strip ----
function W-Append($file,$s){ [IO.File]::AppendAllText($file,$s,(New-Object System.Text.UTF8Encoding($false))) }
function Log-Watch($text,$lesson){
  New-Item -ItemType Directory -Force -Path $Coaching|Out-Null
  $date=(Get-Date).ToString("yyyy-MM-dd"); $time=(Get-Date).ToString("HH:mm"); $daily=Join-Path $Coaching ($date+".md")
  if(-not(Test-Path $daily)){ W-Append $daily ("# Coaching log - "+$date+"`n") }
  $ctx=if($lesson){ "_lesson: "+$lesson+"_`n`n" } else { "_(paused / working)_`n`n" }
  W-Append $daily ("`n### "+$time+"  [WATCH]`n"+$ctx+$text+"`n`n---`n")
}
function Cap-Win($proc){
  $p=Get-Process $proc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Sort-Object { $_.MainWindowTitle.Length } -Descending | Select-Object -First 1
  if(-not $p){ return $null }
  $h=$p.MainWindowHandle; $r=New-Object Win+RECT; [void][Win]::GetWindowRect($h,[ref]$r); $w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
  if($w -lt 200 -or $ht -lt 200){ return $null }
  $bmp=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($bmp); $hdc=$g.GetHdc(); [void][Win]::PrintWindow($h,$hdc,2); $g.ReleaseHdc($hdc); $g.Dispose()
  $mw=1500.0; $s=[Math]::Min(1.0,$mw/$w); $nw=[int]($w*$s); $nh=[int]($ht*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g3=[System.Drawing.Graphics]::FromImage($sm); $g3.InterpolationMode='HighQualityBicubic'; $g3.DrawImage($bmp,0,0,$nw,$nh); $g3.Dispose()
  $f=Join-Path $env:TEMP ("cap_"+$proc+".png"); $sm.Save($f,[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $sm.Dispose()
  return [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
}
function ColLetter($n){ $r=""; do { $n--; $r=[string][char]([int][char]'A'+($n%26))+$r; $n=[int][math]::Floor($n/26) } while($n -gt 0); return $r }
function Read-ExcelLive {
  $xl=$null; try { $xl=[System.Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") } catch { return $null }
  if(-not $xl){ return $null }
  $out=$null
  try {
    $wb=$null; if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb=Get-XlBook $xl } else { $wb=$xl.ActiveWorkbook }; if(-not $wb){ return $null }
    $sh=$wb.ActiveSheet; $ur=$sh.UsedRange
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
        $vs=if($v -is [double]){ $v.ToString("0.######") }else{ [string]$v }
        $ln=$addr+" = "+$vs; if(($fm -is [string]) -and $fm.StartsWith("=")){ $ln+="   "+$fm }
        [void]$sb.AppendLine($ln); $n++
      }}
      if($n -ge $cap){ [void]$sb.AppendLine("...(more cells not shown)") }
    }
    $out=$sb.ToString()
  } catch { $out=$null } finally { try{ [System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl)|Out-Null }catch{} }
  return $out
}
function Add-Note {
  $xl=$null; if(Get-Command Read-ExcelLive -ErrorAction SilentlyContinue){ try{ $xl=Read-ExcelLive }catch{} }
  $lesson=""; if($sync.lessonlog){ $lesson=$sync.lessonlog; if($lesson.Length -gt 1500){ $lesson=$lesson.Substring($lesson.Length-1500) } }
  $u="The student pressed NOTE to flag what they are doing right now as important to remember and come back to for practice. Write a concise study note in markdown: a '## ' one-line title naming the topic/skill, then 2-4 bullets - what they were working on, the key concept or formula, and exactly what to practice when they return. Use their real cells/values if provided. Be specific and useful."
  $content=@(@{type='text';text=$u})
  if($lesson){ $content+=@{type='text';text=("Recent lesson context: "+$lesson)} }
  if($xl){ $content+=@{type='text';text=("Their live Excel right now:`n"+$xl)} }
  $sysN="You write concise, specific study notes for a finance/Excel student preparing for an investment-banking fellowship."
  $msgs=@(@{role='system';content=($sysN+$sync.brain)},@{role='user';content=$content})
  $payload=@{ model="gpt-4o-mini"; max_tokens=380; temperature=0.2; messages=$msgs } | ConvertTo-Json -Depth 12
  $bf="$env:TEMP\xc_note.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  $note="## Flagged for review`r`n- Revisit what you were working on here."
  if($j.choices){ $note=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $note=Clean-Answer $note } }
  $nf=Join-Path $Coaching "Notes.md"
  if(-not(Test-Path $nf)){ [IO.File]::AppendAllText($nf,"# Notes - things I flagged to revisit and practice`r`n",(New-Object System.Text.UTF8Encoding($false))) }
  [IO.File]::AppendAllText($nf,"`r`n### "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"`r`n"+$note+"`r`n",(New-Object System.Text.UTF8Encoding($false)))
  return $note
}
function Get-Help($question,$detail){
  $xlData=Read-ExcelLive
  $ex=Cap-Win "EXCEL"; $co=Cap-Win "chrome"; if(-not $co){ $co=Cap-Win "msedge" }; if(-not $co){ $co=Cap-Win "firefox" }
  if(-not $ex -and -not $co -and -not $xlData){ return "Couldn't find your Excel or browser window to read." }
  $sysH="You are a sharp finance and Excel tutor (Breaking Into Wall Street level). The student follows a course and rebuilds it in Excel. You may be given: the EXACT live contents of their Excel (every non-empty cell's address, value and formula, read straight from the workbook), an image of their Excel, and/or an image of the course/lesson. When the exact Excel data is present, treat it as the ground truth for ALL cell references, values and formulas - never guess a cell address from the image. METHOD for getting it right: (1) first read the exact question or task carefully and be sure you understand precisely what is being asked; (2) work it out step by step using the actual cell values and formulas; (3) double-check your arithmetic and logic; (4) then give the correct answer with a brief clear explanation, citing exact cell addresses (e.g. C39). If there is a quiz/question, work out the correct answer and, if it is multiple choice, state exactly which option to pick. If it is an Excel exercise, give the specific next step or fix and the exact cell(s) and formula to use. If the student typed a specific question, answer THAT directly. Accuracy above all - if you are not sure, say what you would check rather than guessing. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
  $uh=if($question){ "The student asks: "+$question }else{ "Help me with my work right now." }; if($sync.lessonlog){ $uh+=" (What the instructor has recently been teaching: '"+$sync.lessonlog+"'.)" }
  $uh+=$(if($detail){ " Explain in detail: the full reasoning, the steps, and why - take the space you need." }else{ " Keep it SHORT and useful: lead with the direct answer or the exact fix in 1 to 3 short sentences (a tiny list only if truly needed). Do not over-explain or pad - I can ask to explain in detail if I want." })
  $content=@(@{type='text';text=$uh})
  if($xlData){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative, use these cell addresses/values/formulas; do not guess cells from the image]:`n"+$xlData)} }
  if($sync.sheetPurpose){ $content+=@{type='text';text=("What this practice sheet is for (already understood): "+$sync.sheetPurpose)} }
  $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching and what I am trying to BUILD in my Excel, then connect them: cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."}
  if($ex){ $content+=@{type='text';text='[Image: MY Excel sheet (visual context only)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$ex);detail='high'}} }
  if($co){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$co);detail='high'}} }
  $msgs=@(@{role='system';content=($sysH+$sync.brain)},@{role='user';content=$content})
  if($sync.model -match '^gpt-5'){ $payload=@{ model=$sync.model; max_completion_tokens=$(if($detail){3500}else{900}); reasoning_effort='medium'; messages=$msgs } | ConvertTo-Json -Depth 14 }
  else { $payload=@{ model=$sync.model; max_tokens=700; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 14 }
  $bf="$env:TEMP\help_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a } elseif($j.error){ return "Error: "+$j.error.message } else { return "No response (check connection)." }
}
function Set-Round($ctl,$rad){ $d=$rad*2; $w=$ctl.Width; $h=$ctl.Height; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $ctl.Region=New-Object System.Drawing.Region($gp) }
function Draw-Border($g,$w,$h,$rad,$col){ $g.SmoothingMode='AntiAlias'; $pen=New-Object System.Drawing.Pen($col,1); $d=$rad*2; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $g.DrawPath($pen,$gp); $pen.Dispose(); $gp.Dispose() }
# ---- Liquid-glass UI v4: WebView2 surfaces (tools/ui/strip.html + panel.html, snipzy liquid glass) over Win11 acrylic ----
Add-Type @'
using System; using System.Runtime.InteropServices;
public class GlassW {
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l; public int r; public int t; public int b; }
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static int Backdrop(IntPtr hwnd, int type){
    MARGINS m = new MARGINS(); m.l = -1; m.r = -1; m.t = -1; m.b = -1;
    DwmExtendFrameIntoClientArea(hwnd, ref m);
    int dark = 1; DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
    int r = 1; DwmSetWindowAttribute(hwnd, 33, ref r, 4);
    return 0;
  }
}
'@
[void][GlassW]::SetProcessDPIAware()
$gd=[System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:S=$gd.DpiX/96.0; $gd.Dispose()
function Px($v){ return [int][math]::Round($v*$script:S) }
function Glass-On($f0){ $hr=[GlassW]::Backdrop($f0.Handle,3); if($hr -ne 0){ $f0.BackColor=[System.Drawing.Color]::FromArgb(244,246,249) } }
$wvDir=Join-Path $PSScriptRoot "webview2"
try{
  Add-Type -Path (Join-Path $wvDir "Microsoft.Web.WebView2.Core.dll")
  Add-Type -Path (Join-Path $wvDir "Microsoft.Web.WebView2.WinForms.dll")
}catch{ Write-Host ("WebView2 SDK load failed: "+$_.Exception.Message); exit }
$uiDir=Join-Path $PSScriptRoot "ui"
$script:stripUrl="file:///"+((Join-Path $uiDir "strip.html") -replace '\\','/')
$script:panelUrl="file:///"+((Join-Path $uiDir "panel.html") -replace '\\','/')
function BoolJs($b){ if($b){ return 'true' } else { return 'false' } }
function JS($wv,$code){ try{ if($wv -and $wv.CoreWebView2){ [void]$wv.CoreWebView2.ExecuteScriptAsync($code) } }catch{} }
function New-GlassWebForm($w,$h){
  $f=New-Object System.Windows.Forms.Form
  $f.FormBorderStyle='None'; $f.TopMost=$true; $f.ShowInTaskbar=$false; $f.StartPosition='Manual'; $f.Width=$w; $f.Height=$h; $f.BackColor=[System.Drawing.Color]::Black
  $wv=New-Object Microsoft.Web.WebView2.WinForms.WebView2
  $cp=New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
  $cp.UserDataFolder=Join-Path $env:TEMP "xc_wv2_data"
  $wv.CreationProperties=$cp
  $wv.DefaultBackgroundColor=[System.Drawing.Color]::Transparent
  $wv.Dock='Fill'
  $f.Controls.Add($wv)
  return @{f=$f;wv=$wv}
}
function Tune-WebView($wv){
  try{
    $st=$wv.CoreWebView2.Settings
    $st.AreDefaultContextMenusEnabled=$false; $st.IsZoomControlEnabled=$false; $st.AreDevToolsEnabled=$false; $st.IsStatusBarEnabled=$false
  }catch{}
}
# ---- state ----
$script:collapsed=$true; $script:stripReady=$false; $script:panelReady=$false; $script:pendingAns=$null; $script:pendingLoad=$false
$script:statusText=""; $script:dotState=""; $script:lastTimer=""; $script:t0=(Get-Date); $script:lastXWdog=(Get-Date); $script:curIssue=0; $script:pracList=@(); $script:pracIdx=0; $script:cardHelpBusy=$false; $script:rtCur=$null; $script:woActive=$false; $script:woBusy=$false; $script:woIdx=0; $script:woSeq=0; $script:woNext=$null; $script:woLast=''
$script:seen=0; $script:lastFull=""; $script:idle=$true; $script:baseStatus="Listening to the lesson"; $script:ffFails=0; $script:ffLastTry=(Get-Date); $script:lastHelpQ=""; $script:askBusy=$false; $script:lastActive=(Get-Date); $script:busySince=$null; $script:busyLabel="Thinking"; $script:seenXl=0; $script:xlNudgeShown=$false; $script:seenForm=0; $script:fxCache=@{}; $script:seenId=0; $script:idCache=@{ key=""; json="" }; $script:idPendingKey=""; $script:heardAt=$null; $script:listenState=$false
# ---- forms ----
$mkS=New-GlassWebForm (Px 280) (Px 40)
$strip=$mkS.f; $wvS=$mkS.wv; $script:strip=$strip; $script:wvS=$wvS
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-(Px 14)
$mkP=New-GlassWebForm (Px 600) (Px 400)
$panel=$mkP.f; $wvP=$mkP.wv; $script:panel=$panel; $script:wvP=$wvP
function Place-PanelHome {
  $wa3=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $panel.SetBounds(($wa3.Right-$panel.Width-(Px 16)),($wa3.Bottom-$panel.Height-(Px 14)),$panel.Width,$panel.Height)
}
function Set-Msg($t){ if($script:statusText -ne $t){ $script:statusText=$t; JS $script:wvS ("XC.setStatus("+(ConvertTo-Json $t)+")") } }
function Set-Dot($hex,$pulse){ $k=$hex+(BoolJs $pulse); if($script:dotState -ne $k){ $script:dotState=$k; JS $script:wvS ("XC.setDot('"+$hex+"',"+(BoolJs $pulse)+")") } }
function Apply-Strip {
  if($script:animating){ return }
  $wa4=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  if($script:collapsed){ $script:menuOpen=$false; $nw=(Px 280); $nh=(Px 40) } else { $nw=(Px 780); $nh=(Px 80)+$(if($script:menuOpen){ Px 400 }else{ 0 }) }
  $nl=$wa4.Left+[int](($wa4.Width-$nw)/2); $nt=$wa4.Bottom-$nh-(Px 14)
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
  $sb=$strip.Bounds; $ox=$sb.X; $oy=$sb.Y; $ow=$sb.Width; $oh=$sb.Height
  if($ow -eq $nw -and $oh -eq $nh -and $ox -eq $nl -and $oy -eq $nt){ return }
  $script:animating=$true
  try{
    for($i=1;$i -le 10;$i++){
      $p=$i/10.0; $e=1.0-[Math]::Pow(1.0-$p,3)
      $cw=[int]($ow+($nw-$ow)*$e); $ch=[int]($oh+($nh-$oh)*$e); $cx=[int]($ox+($nl-$ox)*$e); $cy=[int]($oy+($nt-$oy)*$e)
      $strip.SetBounds($cx,$cy,$cw,$ch)
      [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 12
    }
    $strip.SetBounds($nl,$nt,$nw,$nh)
  } finally { $script:animating=$false }
}
function Push-StripState {
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
  JS $script:wvS ("XC.setStatus("+(ConvertTo-Json $script:statusText)+")")
  JS $script:wvS ("XC.setToggle('pause',"+(BoolJs $sync.paused)+")")
  JS $script:wvS ("XC.setToggle('mute',"+(BoolJs $sync.mute)+")")
  JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")")
  JS $script:wvS ("XC.setToggle('format',"+(BoolJs $sync.formatOn)+")")
  JS $script:wvS ("XC.setToggle('hands',"+(BoolJs $sync.handsOn)+")")
  JS $script:wvS ("XC.setToggle('teach',"+(BoolJs $sync.teachOn)+")")
  JS $script:wvS ("XC.setToggle('guide',"+(BoolJs $sync.guideOn)+")")
  JS $script:wvS ("XC.setToggle('micmute',"+(BoolJs $sync.micMute)+")")
  JS $script:wvS ("XC.setVol("+[int]([double]$sync.ttsVol*100)+")")
  JS $script:wvS ("XC.busy(false)")
  $hp=$script:dotState; $script:dotState=""; if($hp -ne ""){ $c=$hp.Substring(0,7); $p=$hp.Substring(7); JS $script:wvS ("XC.setDot('"+$c+"',"+$p+")") } else { Set-Dot '#22c55e' $true }
}
function Show-Answer($md,$kind='answer',$id=0){
  $script:lastFull=$md
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  if($script:panelReady){
    JS $script:wvP ("XC.setTime('"+(Get-Date).ToString("HH:mm")+"')")
    JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $md)+","+(ConvertTo-Json (@{kind=$kind;id=$id}))+")")
  } else { $script:pendingAns=$md; $script:pendingLoad=$false }
}
function Show-PanelLoading {
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  if($script:panelReady){ JS $script:wvP ("XC.setAnswerLoading()") } else { $script:pendingLoad=$true }
}
function Simplify-Answer($text){
  $sysS="You simplify finance/Excel explanations for a beginner. Keep all cell references and numbers exactly. Use the same markdown style (optional ## header, - bullets, **bold** for key terms) but plainer words and shorter sentences. Output only the simplified explanation."
  $payload=@{ model="gpt-4o-mini"; max_tokens=450; temperature=0.2; messages=@(@{role="system";content=$sysS},@{role="user";content=("Simplify this explanation:`n`n"+$text)}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_simplify.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return "Could not simplify right now (connection issue) - the original answer is unchanged."
}
# Plain-English re-explanation of a single flashcard for a confused beginner.
# Used by the practice card's "Explain it simpler" button. Quick helper call
# (gpt-4o-mini, same as Simplify-Answer/define) - the live coach is untouched.
function Explain-Card($front,$back,$type){
  if(-not $sync.key){ return "Set your API key to use Explain (no key found)." }
  $front=[string]$front; $back=[string]$back; $type=[string]$type
  $sysC="You are a patient finance tutor helping a beginner who is confused by an investment-banking flashcard. Re-explain it from scratch in the simplest plain English: say what it means in everyday terms, unpack any jargon, and give ONE tiny concrete example with small round numbers. Keep it to 2-4 short sentences. Be warm and clear, no preamble, no restating the question. You may use **bold** for a key term."
  $usr="Flashcard ("+$type+")`nTerm / front: "+$front+"`nGiven answer / back: "+$back+"`n`nExplain this simply for someone who does not get it yet."
  $payload=@{ model="gpt-4o-mini"; max_tokens=320; temperature=0.3; messages=@(@{role="system";content=$sysC},@{role="user";content=$usr}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_cardhelp.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return "Could not load a simpler explanation right now (connection issue). Try again in a moment."
}
function Set-Query($q){ if($script:panelReady){ JS $script:wvP ("XC.setQuery("+(ConvertTo-Json ([string]$q))+")") } else { $script:pendingQ=[string]$q } }
function Shutdown-Coach {
  $sync.stop=$true; try{ $ui.Stop() }catch{}; Start-Sleep -Milliseconds 300; Kill-FF
  try{ $rs.Close() }catch{}; try{ $rsT.Close() }catch{}; try{ $rsX.Close() }catch{}
  try{ $panel.Close() }catch{}
  try{ $strip.Close() }catch{}
}
function Handle-Ask($q){
  if($script:askBusy){ return }
  $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
  JS $script:wvS ("XC.busy(true)")
  if($q -eq ""){ Set-Msg "Reading your Excel + the lesson..."; $script:lastHelpQ=""; $script:busyLabel="Reading your screen" } else { Set-Msg ("Thinking: "+$q); $script:lastHelpQ=$q; $script:busyLabel="Thinking" }
  $script:busySince=(Get-Date)
  Set-Dot '#2563eb' $false
  [System.Windows.Forms.Application]::DoEvents()
  $det=$false; if($q){ $det=[bool]($q -match '(?i)explain|in detail|elaborate|\bwhy\b') }
  $sync.askLabel=$(if($q){ $q }else{ "Help with my screen" })
  $sync.typedDetail=$det; $sync.typedAsk=$(if($q){ $q }else{ "__ASSIST__" })
}
# Compact performance snapshot for the practice end screen (top strengths/weak spots).
function Perf-Payload {
  if(-not (Get-Command Get-PerfSummary -ErrorAction SilentlyContinue)){ return $null }
  try {
    $s = Get-PerfSummary
    $str=@(); foreach($x in @($s.strengths)){ $str += @{ name=[string]$x.name; pct=[int][math]::Round($x.acc*100) }; if($str.Count -ge 3){ break } }
    $wk=@(); foreach($x in @($s.weaknesses)){ $wk += @{ name=[string]$x.name; pct=[int][math]::Round($x.acc*100) }; if($wk.Count -ge 3){ break } }
    return @{ pct=[int]$s.pct; attempts=[int]$s.totalAttempts; strengths=$str; weaknesses=$wk }
  } catch { return $null }
}
function Start-Practice {
  if(-not (Get-Command Get-DueCards -ErrorAction SilentlyContinue)){ Show-Answer "Practice deck is not built yet - run build-deck.ps1 once to generate your flashcards, then click Practice again." 'note' 0; Set-Query "Practice"; return }
  $deck=$null; if(Get-Command Get-Deck -ErrorAction SilentlyContinue){ try{ $deck=Get-Deck }catch{} }
  $due=@(); try{ $due=@(Get-DueCards 20) }catch{}
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  if(@($due).Count -eq 0){
    $empty=$(if($deck){ 'caughtup' }else{ 'nodeck' })
    JS $script:wvP ("XC.openPractice("+(ConvertTo-Json (@{mode='review';dueCount=0;empty=$empty;perf=(Perf-Payload)}) -Depth 6)+")")
    $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus=$(if($deck){ "All caught up - no cards due" }else{ "No deck yet - run build-deck" }); return
  }
  $script:pracList=@($due); $script:pracIdx=0; Show-PracticeCard
}
function Show-PracticeCard {
  if(($null -eq $script:pracList) -or ($script:pracIdx -ge @($script:pracList).Count)){
    JS $script:wvP ("XC.openPractice("+(ConvertTo-Json (@{mode='review';dueCount=0;empty='caughtup';perf=(Perf-Payload)}) -Depth 6)+")")
    $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="Practice complete - nice work"; return
  }
  $c=@($script:pracList)[$script:pracIdx]
  $hasCh=($c.choices -and (@($c.choices).Count -ge 2) -and ($null -ne $c.answer))
  $mode=$(if($hasCh){ 'quiz' }else{ 'review' })
  $card=@{ id=[string]$c.id; type=[string]$c.type; front=[string]$c.front; back=[string]$c.back }
  if($hasCh){ $card['choices']=@($c.choices); $card['answer']=[int]$c.answer }
  $payload=@{ mode=$mode; dueCount=@($script:pracList).Count; index=$script:pracIdx; total=@($script:pracList).Count; card=$card }
  JS $script:wvP ("XC.openPractice("+(ConvertTo-Json $payload -Depth 6)+")")
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  $script:idle=$false; $script:lastActive=(Get-Date)
}
function Handle-Practice($action,$cardId,$quality,$choice){
  switch([string]$action){
    'rate' {
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      if($cc -and (Get-Command Record-Answer -ErrorAction SilentlyContinue)){ try{ Record-Answer $cc.topicId $null ([int]$quality -ge 3) | Out-Null }catch{} }
      if(Get-Command Rate-Card -ErrorAction SilentlyContinue){ try{ Rate-Card $cardId ([int]$quality) }catch{} }
      $script:pracIdx=([int]$script:pracIdx)+1; Show-PracticeCard
    }
    'quizAnswer' {
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      $ok=($cc -and ([int]$choice -eq [int]$cc.answer))
      if($cc -and (Get-Command Record-Answer -ErrorAction SilentlyContinue)){ try{ Record-Answer $cc.topicId $null $ok | Out-Null }catch{} }
      if(Get-Command Rate-Card -ErrorAction SilentlyContinue){ try{ Rate-Card $cardId ([int]$(if($ok){4}else{1})) }catch{} }
    }
    'practiceNext' { $script:pracIdx=([int]$script:pracIdx)+1; Show-PracticeCard }
    'simplify' {
      if($script:cardHelpBusy){ return }
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      if(-not $cc){ $cc=@($script:pracList)[$script:pracIdx] }
      if(-not $cc){ return }
      $script:cardHelpBusy=$true
      JS $script:wvP ("XC.setCardHelpLoading()")
      [System.Windows.Forms.Application]::DoEvents()
      try{ $ex=Explain-Card $cc.front $cc.back $cc.type; JS $script:wvP ("XC.setCardHelp("+(ConvertTo-Json ([string]$ex))+")") }catch{}
      $script:cardHelpBusy=$false
    }
    'practiceClose' { try{ $panel.Hide() }catch{}; $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="On track" }
  }
}
# Excel exercise: generate an AI calc drill, render it into a "Workout" sheet, and
# (on the next click) grade what the student typed. Toggles generate <-> check.
# Pick the next workout topic FROM MEMORY (unseen topics first, then weak ones, via
# the run-through picker) and generate it with a fresh nonce so numbers always differ.
function Gen-WorkoutEx {
  $topicId=$null
  if(Get-Command RT-PickNext -ErrorAction SilentlyContinue){
    try{ $pick=RT-PickNext (RT-LoadState) ([int]$script:woIdx) ([string]$script:woLast); if($pick){ $topicId=[string]$pick.topicId } }catch{}
  }
  if(-not $topicId -and (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    try{ $cur=@(Get-Curriculum); if($cur.Count){ $topicId=[string]$cur[($script:woIdx % $cur.Count)].id } }catch{}
  }
  if(-not $topicId){ return $null }
  $script:woIdx=([int]$script:woIdx)+1; $script:woLast=$topicId
  $script:woSeq=([int]$script:woSeq)+1
  $ex=$null; try{ $ex=Make-Exercise $topicId 2 ("v"+$script:woSeq) }catch{}
  return $ex
}
function Start-Workout {
  if($script:woBusy){ return }
  if(-not (Get-Command Make-Exercise -ErrorAction SilentlyContinue)){ Show-Answer "The run-through is not available in this build yet." 'note' 0; return }
  $script:woBusy=$true
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  Set-Query "Run-through"
  # Use the preloaded next exercise for an instant jump; otherwise generate now.
  $ex=$null
  if($script:woNext){ $ex=$script:woNext; $script:woNext=$null }
  else { JS $script:wvP ("XC.setAnswerLoading()"); [System.Windows.Forms.Application]::DoEvents(); $ex=Gen-WorkoutEx }
  if(-not $ex){ $script:woBusy=$false; Show-Answer "I could not build the next exercise right now (connection issue). Try again in a moment." 'note' 0; return }
  if([string]$ex.surface -eq 'excel'){
    $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
    if(-not $xl){ $script:woBusy=$false; $script:woActive=$false; $sync.woActive=$false; Show-Answer "Open Excel first, then pick **Run-through** in the menu so I can set up the Workout sheet." 'note' 0; return }
    try{ RT-RenderExcel $ex $xl | Out-Null }catch{}
    $script:rtCur=$ex; $script:woActive=$true; $sync.woActive=$true
    $ttl=[string]$ex.layout.title; if(-not $ttl){ $ttl="Excel exercise" }
    $tn=''; if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq [string]$ex.topicId){ $tn=[string]$t.topic; break } } }catch{} }
    $pl=@{ mode='excel'; title=$ttl; topicName=$tn; progress=("Level "+[string]$ex.level); prompt=[string]$ex.prompt; concept=[string]$ex.concept; scoreboard=(WO-Scoreboard) }
    JS $script:wvP ("XC.openExercise("+(ConvertTo-Json $pl -Depth 6)+")")
  } else {
    $script:rtCur=$ex; $script:woActive=$true; $sync.woActive=$true
    $tn=''; if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq [string]$ex.topicId){ $tn=[string]$t.topic; break } } }catch{} }
    $chs=@(); if($ex.choices){ $chs=@($ex.choices | ForEach-Object { [string]$_ }) }
    $pl=@{ mode='pill'; title=$(if($tn){ $tn }else{ "Concept" }); topicName=$tn; progress=("Level "+[string]$ex.level); prompt=[string]$ex.prompt; concept=[string]$ex.concept; scoreboard=(WO-Scoreboard) }
    if($chs.Count -ge 2){ $pl['choices']=$chs } else { $pl['answer']=[string]$ex.answer }
    JS $script:wvP ("XC.openExercise("+(ConvertTo-Json $pl -Depth 6)+")")
  }
  # Preload the NEXT exercise now (memory-driven), while the student works on this
  # one - so the Next button is instant. The latency is masked by their working time.
  [System.Windows.Forms.Application]::DoEvents(); try{ if(-not $script:woNext){ $script:woNext=Gen-WorkoutEx } }catch{}
  $script:woBusy=$false
}
function Check-Workout {
  if((-not $script:rtCur) -or $script:woBusy){ return }
  $script:woBusy=$true
  [System.Windows.Forms.Application]::DoEvents()
  $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
  if(-not $xl){ $script:woBusy=$false; JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md="I could not reach Excel to check. Make sure the Workout sheet is open, then press Check answer again."}) -Depth 4)+")"); return }
  $res=$null; try{ $res=Grade-ExcelExercise $script:rtCur $xl }catch{}
  if(-not $res){ $script:woBusy=$false; JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md="I could not read your answers. Make sure the Workout sheet is open, then press Check answer again."}) -Depth 4)+")"); return }
  if(Get-Command Record-Answer -ErrorAction SilentlyContinue){ try{ Record-Answer $script:rtCur.topicId $null ([bool]$res.correct) | Out-Null }catch{} }
  if(Get-Command RT-RecordResult -ErrorAction SilentlyContinue){ try{ RT-RecordResult ([string]$script:rtCur.topicId) ([int]$script:rtCur.level) ([bool]$res.correct) $false | Out-Null }catch{} }
  $body=""
  if($res.correct){ $body="Every answer cell checks out - nice work." }
  else {
    $body="Here is how your answer cells compare:`n"
    foreach($pc in @($res.perCell)){ $mk=$(if($pc.ok){"[ok]"}else{"[x]"}); $body+="`n- "+$mk+" "+[string]$pc.cell+": you have "+[string]$pc.got+", expected "+[string]$pc.expected }
  }
  if($res.worked){ $body+="`n`n**How it's done:** "+[string]$res.worked }
  $body+="`n`nPress **Next exercise** to continue, or **End** to save and exit."
  JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=[bool]$res.correct; md=$body}) -Depth 6)+")")
  $script:woBusy=$false
}
# Compact "X of N solid" scoreboard for the exercise header.
function WO-Scoreboard {
  if(-not (Get-Command Get-RTProgress -ErrorAction SilentlyContinue)){ return "" }
  try{ $p=Get-RTProgress; return ([string]$p.solid+" of "+[string]$p.total+" solid") }catch{ return "" }
}
# Grade a multiple-choice pill answer chosen in the dedicated exercise view.
function Handle-WorkoutAnswer($choice){
  if((-not $script:rtCur) -or $script:woBusy){ return }
  if(-not (Get-Command Grade-PillExercise -ErrorAction SilentlyContinue)){ return }
  $script:woBusy=$true
  $g=$null; try{ $g=Grade-PillExercise $script:rtCur ([int]$choice) }catch{}
  $ok=$false; if($g){ $ok=[bool]$g.correct }
  if(Get-Command Record-Answer -ErrorAction SilentlyContinue){ try{ Record-Answer $script:rtCur.topicId $null $ok | Out-Null }catch{} }
  if(Get-Command RT-RecordResult -ErrorAction SilentlyContinue){ try{ RT-RecordResult ([string]$script:rtCur.topicId) ([int]$script:rtCur.level) $ok $false | Out-Null }catch{} }
  $body=""
  if($ok){ $body="Correct." } else { $body="Not quite - the correct answer is: "+[string]$g.expected+"." }
  if($g -and $g.worked){ $body+="`n`n"+[string]$g.worked }
  $body+="`n`nPress **Next exercise** to continue, or **End** to save and exit."
  JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$ok; md=$body}) -Depth 6)+")")
  $script:woBusy=$false
}
function Handle-Act($k){
  $script:lastActive=(Get-Date)
  if($k -ne 'workout'){ $script:woActive=$false; $sync.woActive=$false; if($script:panelReady){ try{ JS $script:wvP ("XC.closeExercise()") }catch{} } }
  switch($k){
    'collapse' { $script:collapsed=$true; Apply-Strip }
    'expand'   { $script:collapsed=$false; Apply-Strip }
    'reopen'   { if($script:lastFull){ Show-Answer $script:lastFull } }
    'pause'    {
      $sync.paused=-not $sync.paused
      JS $script:wvS ("XC.setToggle('pause',"+(BoolJs $sync.paused)+")")
      if($sync.paused){ $script:idle=$false; Set-Msg "Paused"; Set-Dot '#969aa2' $false } else { $script:baseStatus="Listening to the lesson"; $script:idle=$true; Set-Dot '#22c55e' $true }
    }
    'mute'     { $sync.mute=-not $sync.mute; JS $script:wvS ("XC.setToggle('mute',"+(BoolJs $sync.mute)+")"); if($sync.mute){ $sync.ttsStop=$true } }
    'micmute'  { $sync.micMute=-not $sync.micMute; JS $script:wvS ("XC.setToggle('micmute',"+(BoolJs $sync.micMute)+")"); $script:lastActive=(Get-Date); Set-Msg $(if($sync.micMute){ "Mic muted - not listening" }else{ "Mic on - listening" }) }
    'sound'    { $sync.muteSound=-not $sync.muteSound; JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")") }
    'cancel'   {
      try{ Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $PID } | ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} } }catch{}
      $sync.cancelled=$true; $sync.typedAsk=""
      $script:askBusy=$false; $script:busySince=$null; $script:idle=$true
      JS $script:wvS ("XC.busy(false)"); Set-Msg "Cancelled"; Set-Dot '#22c55e' $true; $script:baseStatus="Cancelled"
    }
    'hands'    {
      $sync.handsOn=-not $sync.handsOn
      JS $script:wvS ("XC.setToggle('hands',"+(BoolJs $sync.handsOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.handsOn){ "Hands ON - tell me what to build (empty cells only)" }else{ "Hands off - watching only" }); Set-Dot $(if($sync.handsOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'teach'    {
      $sync.teachOn=-not $sync.teachOn
      JS $script:wvS ("XC.setToggle('teach',"+(BoolJs $sync.teachOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.teachOn){ "Teach mode ON - ask me to show you something" }else{ "Teach mode off" }); Set-Dot $(if($sync.teachOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'format'   {
      $sync.formatOn=-not $sync.formatOn
      JS $script:wvS ("XC.setToggle('format',"+(BoolJs $sync.formatOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.formatOn){ "Formatting ON - I'll style what I build (IB conventions)" }else{ "Formatting off - I'll build plain cells" }); Set-Dot $(if($sync.formatOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'guide'    {
      $sync.guideOn=-not $sync.guideOn
      JS $script:wvS ("XC.setToggle('guide',"+(BoolJs $sync.guideOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.guideOn){ "Guide ON - I'll walk you through the next step" }else{ "Guide off - reactive checking only" }); Set-Dot $(if($sync.guideOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'note'     {
      $script:idle=$false; Set-Msg "Noting this for later..."; Set-Dot '#2563eb' $false
      Show-PanelLoading
      [System.Windows.Forms.Application]::DoEvents()
      $nn=Add-Note; $script:lastFull=$nn; Show-Answer $nn 'note' 0; Set-Query "Note this"
      $script:baseStatus="Noted - saved to revisit"; $script:idle=$true; Set-Dot '#22c55e' $true; $script:seen=$sync.stamp
    }
    'audit'    {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Deep-checking your sheet..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Deep-checking"
      Show-PanelLoading
      $sync.askLabel="Sheet audit"; $sync.typedDetail=$true; $sync.typedAsk="__AUDIT__"
    }
    'kick'     {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Getting you going..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Kick incoming"
      Show-PanelLoading
      $sync.askLabel="Kick-start"; $sync.typedDetail=$false; $sync.typedAsk="__KICK__"
    }
    'workout' { Start-Workout }
    'practice' {
      if(Get-Command Start-Practice -ErrorAction SilentlyContinue){ Start-Practice } else { Handle-Ask "make me a practice exercise and walk me through it" }
    }
    'why'      {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Explaining this cell..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Why this"
      Show-PanelLoading
      $sync.askLabel="Why this cell"; $sync.typedDetail=$false; $sync.typedAsk="__WHY__"
    }
    'cheat'    {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Building a cheat sheet..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Cheat sheet"
      Show-PanelLoading
      $sync.askLabel="Cheat sheet"; $sync.typedDetail=$false; $sync.typedAsk="__CHEAT__"
    }
    'close'    { Shutdown-Coach }
  }
}
function Handle-Panel($k,$term){
  $script:lastActive=(Get-Date)
  switch($k){
    'close'   { $sync.woActive=$false; try{ $panel.Hide() }catch{} }
    'copy'    { try{ if($script:lastFull){ [System.Windows.Forms.Clipboard]::SetText($script:lastFull) } }catch{} }
    'copytext' { try{ if($term){ [System.Windows.Forms.Clipboard]::SetText([string]$term) } }catch{} }
    'workoutcheck' { if(Get-Command Check-Workout -ErrorAction SilentlyContinue){ Check-Workout } }
    'workoutnext'  { if(Get-Command Start-Workout -ErrorAction SilentlyContinue){ Start-Workout } }
    'workoutend'   { $script:woActive=$false; $sync.woActive=$false; $script:rtCur=$null; $script:woNext=$null; JS $script:wvP ("XC.closeExercise()"); $sb=(WO-Scoreboard); Show-Answer ("Run-through paused - your progress is saved."+$(if($sb){ "  You're at "+$sb+" of the course." }else{ "" })+"  Open the ... menu and pick Run-through any time to keep going.") 'note' 0 }
    'formulas' {
      $fxKey=[string]$sync.sheetPurpose
      if($fxKey -and $script:fxCache.ContainsKey($fxKey)){ JS $script:wvP ("XC.setFormulas("+$script:fxCache[$fxKey]+")") }
      else { $sync.formReq=$true }
    }
    'idents' {
      $idKey=([string]$sync.sheetPurpose)+"|"+([string]$sync.lastXl).GetHashCode()
      if($script:idCache.key -eq $idKey -and $script:idCache.json){ JS $script:wvP ("XC.setIdents("+$script:idCache.json+")") }
      else { $script:idPendingKey=$idKey; $sync.idReq=$true }
    }
    'explain' {
      if($script:askBusy){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $script:busySince=(Get-Date); $script:busyLabel="Explaining"
      $sync.askLabel="Explain in detail"; $sync.typedDetail=$true; $sync.typedAsk=$(if($script:lastHelpQ){ $script:lastHelpQ }else{ "__ASSIST__" })
    }
    'define'  {
      if($script:askBusy -or -not $term){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $q2="Define '"+$term+"' clearly and simply in the context of my course and what I am working on. 2 to 4 sentences, with a tiny concrete example if useful."
      $script:lastHelpQ=$q2
      $script:busySince=(Get-Date); $script:busyLabel="Defining"
      $sync.askLabel="Define "+$term; $sync.typedDetail=$false; $sync.typedAsk=$q2
    }
    'simplify' {
      if($script:askBusy -or -not $script:lastFull){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()"); Set-Query "Simplify"
      [System.Windows.Forms.Application]::DoEvents()
      try{
        $src=$script:lastFull; if($src.Length -gt 1600){ $src=$src.Substring(0,1600) }
        $dd=Simplify-Answer $src; $script:lastFull=$dd; JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $dd)+")")
        if(-not $sync.mute){ $sync.ttsText=$dd }
      }catch{}
      $script:askBusy=$false
    }
  }
}
$wvS.add_CoreWebView2InitializationCompleted({
  param($s,$e)
  if($e.IsSuccess){ Tune-WebView $script:wvS; $script:wvS.CoreWebView2.Navigate($script:stripUrl) }
})
$wvS.add_WebMessageReceived({
  param($s,$e)
  $m=$null; try{ $m=$e.TryGetWebMessageAsString() | ConvertFrom-Json }catch{ return }
  if(-not $m){ return }
  switch([string]$m.type){
    'ready' { $script:stripReady=$true; Push-StripState }
    'act'   { Handle-Act ([string]$m.k) }
    'ask'   { Handle-Ask ([string]$m.q) }
    'drag'  { $script:lastActive=(Get-Date); $script:strip.Left+=[int]([double]$m.dx*$script:S); $script:strip.Top+=[int]([double]$m.dy*$script:S) }
    'panel' { if(([string]$m.k) -eq 'close'){ try{ $script:panel.Hide() }catch{} } }
    'menu'  { $script:menuOpen=[bool]$m.open; Apply-Strip }
    'vol'   { try{ $sync.ttsVol=[math]::Max(0.0,[math]::Min(1.0,[double]$m.value/100.0)) }catch{} }
  }
})
$wvP.add_CoreWebView2InitializationCompleted({
  param($s,$e)
  if($e.IsSuccess){ Tune-WebView $script:wvP; $script:wvP.CoreWebView2.Navigate($script:panelUrl) }
})
$wvP.add_WebMessageReceived({
  param($s,$e)
  $m=$null; try{ $m=$e.TryGetWebMessageAsString() | ConvertFrom-Json }catch{ return }
  if(-not $m){ return }
  switch([string]$m.type){
    'ready' {
      $script:panelReady=$true
      JS $script:wvP ("XC.setTime('"+(Get-Date).ToString("HH:mm")+"')")
      if($script:pendingLoad){ $script:pendingLoad=$false; JS $script:wvP ("XC.setAnswerLoading()") }
      if($script:pendingAns){ $a=$script:pendingAns; $script:pendingAns=$null; JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $a)+")") }
      if($null -ne $script:pendingQ){ JS $script:wvP ("XC.setQuery("+(ConvertTo-Json $script:pendingQ)+")"); $script:pendingQ=$null }
    }
    'panel' { $pk=[string]$m.k; if($pk -eq 'practice'){ Handle-Practice ([string]$m.action) ([string]$m.cardId) $m.quality $m.choice } elseif($pk -eq 'workoutanswer'){ Handle-WorkoutAnswer $m.choice } else { Handle-Panel $pk ([string]$m.term) } }
    'drag'  { $script:lastActive=(Get-Date); $script:panel.Left+=[int]([double]$m.dx*$script:S); $script:panel.Top+=[int]([double]$m.dy*$script:S) }
  }
})
$strip.Add_Shown({ Glass-On $script:strip; [void]$script:wvS.EnsureCoreWebView2Async($null) })
$panel.Add_Shown({ Glass-On $script:panel; [void]$script:wvP.EnsureCoreWebView2Async($null) })
# ---- tick: worker results -> UI ----
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  try{
    $cmdF=(Join-Path $env:TEMP "xc_cmd.txt")
    if([IO.File]::Exists($cmdF)){
      $cmdLine=""; try{ $cmdLine=([IO.File]::ReadAllText($cmdF)).Trim() }catch{}
      try{ [IO.File]::Delete($cmdF) }catch{}
      if($cmdLine){
        if($cmdLine -match '(?i)^act:(.+)$'){ Handle-Act ($Matches[1].Trim()) }
        elseif($cmdLine -match '(?i)^ask:(.+)$'){ Handle-Ask ($Matches[1].Trim()) }
        else{ Handle-Ask $cmdLine }
      }
    }
  }catch{}
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){
    if(((Get-Date)-$script:ffLastTry).TotalSeconds -ge 10){
      $script:ffLastTry=(Get-Date); $script:ffFails++
      if($script:ffFails -le 3){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
      elseif($script:ffFails -eq 4){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Msg "Mic capture failed - check MIC_DEVICE in .env"; Set-Dot '#ef4444' $false }
    }
  } elseif($script:ffFails -ne 0){ $script:ffFails=0 }
  if(-not $sync.stop){
    $wS=[string]$psw.InvocationStateInfo.State
    if($wS -eq 'Completed' -or $wS -eq 'Failed' -or $wS -eq 'Stopped'){
      try{ $script:rs=[runspacefactory]::CreateRunspace(); $script:rs.ApartmentState='STA'; $script:rs.ThreadOptions='ReuseThread'; $script:rs.Open(); $script:rs.SessionStateProxy.SetVariable('sync',$sync); $script:psw=[powershell]::Create(); $script:psw.Runspace=$script:rs; [void]$script:psw.AddScript($work); [void]$script:psw.BeginInvoke(); $script:baseStatus="Coach engine restarted - back up" }catch{}
    }
    $xS=[string]$psx.InvocationStateInfo.State
    $xHung=$false
    try{ if($sync.wHB -and (((Get-Date)-[datetime]$sync.wHB).TotalSeconds -gt 300) -and (((Get-Date)-$script:lastXWdog).TotalSeconds -gt 180)){ $xHung=$true } }catch{}
    if($xS -eq 'Completed' -or $xS -eq 'Failed' -or $xS -eq 'Stopped' -or $xHung){
      if($xHung){ try{ $script:psx.BeginStop($null,$null) }catch{}; try{ [IO.File]::AppendAllText((Join-Path $env:TEMP 'xc_watcher.log'),((Get-Date).ToString('HH:mm:ss')+"  WATCHDOG: watcher hung (no stamp 5min+) - force-restarting`r`n")) }catch{} }
      try{ $script:rsX=[runspacefactory]::CreateRunspace(); $script:rsX.ApartmentState='STA'; $script:rsX.ThreadOptions='ReuseThread'; $script:rsX.Open(); $script:rsX.SessionStateProxy.SetVariable('sync',$sync); $script:psx=[powershell]::Create(); $script:psx.Runspace=$script:rsX; [void]$script:psx.AddScript($xlWork); [void]$script:psx.BeginInvoke(); $script:lastXWdog=(Get-Date); $sync.wHB=(Get-Date); $script:baseStatus="Mistake-watcher restarted - back up" }catch{}
    }
  }
  $lv=-1; if((-not $sync.paused) -and (-not $sync.micMute)){ $lv=Get-MicLevel }
  if($lv -ge 0){ JS $script:wvS ("XC.setEq("+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.00}",$lv)+")") } else { JS $script:wvS ("XC.setEq(-1)") }
  if($lv -ge 0.12){ $script:heardAt=(Get-Date) }
  $listenNow=[bool]$sync.chatOn
  if($listenNow -ne $script:listenState){ $script:listenState=$listenNow; JS $script:wvS ("XC.setListening("+(BoolJs $listenNow)+")") }
  if($script:idle){
    if($script:heardAt -and (((Get-Date)-$script:heardAt).TotalSeconds -lt 1.6)){ Set-Msg $(if($sync.chatOn){ "Hearing you (chat)..." }else{ "Hearing you..." }) }
    elseif($sync.lessonNoteAt -and (((Get-Date)-[datetime]$sync.lessonNoteAt).TotalSeconds -lt 2.5)){ Set-Msg "Noting the lesson..." }
    elseif($script:baseStatus -eq "Listening to the lesson"){ $cw=$false; try{ if(($sync.lessonNoteAt -and (((Get-Date)-[datetime]$sync.lessonNoteAt).TotalSeconds -lt 45)) -or ($sync.courseSeenAt -and (((Get-Date)-[datetime]$sync.courseSeenAt).TotalSeconds -lt 120))){ $cw=$true } }catch{}; Set-Msg $(if($cw){ "Watching the course" }else{ "Listening for the course" }) }
    else { Set-Msg $script:baseStatus }
  }
  if(-not $script:collapsed){
    $el=(Get-Date)-$script:t0; $tt=("{0:00}:{1:00}" -f [int][math]::Floor($el.TotalMinutes),$el.Seconds)
    if($tt -ne $script:lastTimer){ $script:lastTimer=$tt; JS $script:wvS ("XC.setTimer('"+$tt+"')") }
  }
  if((-not $script:collapsed) -and $script:idle -and (-not $script:askBusy) -and (-not $panel.Visible)){
    if(((Get-Date)-$script:lastActive).TotalSeconds -ge 45){ $script:collapsed=$true; Apply-Strip }
  }
  if($sync.ackPing){
    $sync.ackPing=$false; $script:askBusy=$true; $script:busySince=(Get-Date); $script:busyLabel="Heard you - thinking"
    $script:idle=$false; Set-Dot '#2563eb' $false; Set-Msg "Heard you - thinking..."; JS $script:wvS ("XC.busy(true)")
    if(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{} }
  }
  if($script:askBusy -and $script:busySince){ $es=[int]((Get-Date)-$script:busySince).TotalSeconds; if($es -ge 4){ Set-Msg ($script:busyLabel+"... "+$es+"s") } }
  if($sync.formStamp -gt $script:seenForm){
    $script:seenForm=$sync.formStamp
    $fxItems=@()
    foreach($ln in ([string]$sync.formText -split "`r?`n")){
      $fp=$ln -split '\|'
      if($fp.Count -ge 2 -and $fp[0].Trim() -and $fp[1].Trim()){ $fxItems+=@{ n=$fp[0].Trim(); f=$fp[1].Trim(); d=$(if($fp.Count -ge 3){ $fp[2].Trim() }else{ "" }) } }
    }
    $fxJson=$(if($fxItems.Count -gt 0){ ConvertTo-Json @($fxItems) -Compress -Depth 4 }else{ "[]" })
    if($fxItems.Count -gt 0 -and $sync.sheetPurpose){ $script:fxCache[[string]$sync.sheetPurpose]=$fxJson }
    JS $script:wvP ("XC.setFormulas("+$fxJson+")")
  }
  if($sync.idStamp -gt $script:seenId){
    $script:seenId=$sync.idStamp
    $idItems=@()
    foreach($ln in ([string]$sync.idText -split "`r?`n")){
      $ip=$ln -split '\|'
      if($ip.Count -ge 2 -and $ip[0].Trim() -and $ip[1].Trim()){ $idItems+=@{ c=$ip[0].Trim(); n=$ip[1].Trim(); d=$(if($ip.Count -ge 3){ $ip[2].Trim() }else{ "" }) } }
    }
    $idJson=$(if($idItems.Count -gt 0){ ConvertTo-Json @($idItems) -Compress -Depth 4 }else{ "[]" })
    if($idItems.Count -gt 0){ $script:idCache=@{ key=$script:idPendingKey; json=$idJson } }
    JS $script:wvP ("XC.setIdents("+$idJson+")")
  }
  if($sync.xlStamp -gt $script:seenXl){
    $script:seenXl=$sync.xlStamp; $rx=[string]$sync.xlText
    if($rx -match '^GUIDE: '){
      $gmsg=$rx.Substring(7)
      $script:xlNudgeShown=$true; $script:lastActive=(Get-Date)
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#2563eb' $false
      Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $gmsg }else{ $gmsg }); $script:lastFull=$gmsg
      if(Get-Command Show-Answer -ErrorAction SilentlyContinue){ Show-Answer $gmsg 'guide' 0; Set-Query "Your next step" }
      if(-not $sync.mute){ $sync.ttsText=$gmsg }
      $script:baseStatus="On track - guiding"
    }
    elseif($rx -eq "OK"){
      if($script:xlNudgeShown){ $script:xlNudgeShown=$false; if($script:curIssue){ try{ JS $script:wvP ("XC.markFixed("+[int]$script:curIssue+")") }catch{} }; if(-not $script:askBusy){ Set-Dot '#22c55e' $true; $script:idle=$true; $script:baseStatus="Fixed - nice." } }
    }
    elseif($rx -ne ""){
      $script:xlNudgeShown=$true; $script:lastActive=(Get-Date)
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#d4a017' $false; Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $rx }else{ $rx }); $script:lastFull=$rx
      $dupX=$false; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $dupX=(XC-SameIssue $rx $sync.lastNudge) } else { $dupX=($rx -eq $sync.lastNudge) }
      if(-not $dupX){ Log-Watch $rx $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$rx } elseif(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{ [System.Media.SystemSounds]::Asterisk.Play() } } }
      $sync.lastNudge=$rx
      if(Get-Command Show-Answer -ErrorAction SilentlyContinue){ $script:curIssue=([int]$script:curIssue)+1; Show-Answer $rx 'issue' $script:curIssue; Set-Query "Issue to fix" }
    }
  }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($r -ne "OK" -and $r -ne ""){ $script:lastActive=(Get-Date) }
    if($sync.isAnswer){
      $script:askBusy=$false; $script:busySince=$null; JS $script:wvS ("XC.busy(false)")
      $lbl=[string]$sync.askLabel; $sync.askLabel=""
      if($sync.cancelled){ $sync.cancelled=$false; $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="Cancelled" }
      elseif($r -ne "" -and $r -ne "OK"){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Dot '#2563eb' $false; Set-Msg $(if($lbl){ "Answer ready" }else{ "Answer ready - I'm listening if you have a follow-up" }); Show-Answer $r; Set-Query $(if($lbl){ $lbl }else{ "Voice question" }); Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$r }; $script:baseStatus="On track" }
      else { $script:idle=$true; Set-Dot '#22c55e' $true }
    }
    elseif($r -eq "OK" -or $r -eq ""){
      if(-not $script:xlNudgeShown){
        Set-Dot '#22c55e' $true; $script:idle=$true
        if($sync.chatOn){ $script:baseStatus="Chat - just talk (say 'thanks coach' to end)" }
        elseif($sync.isPaused){ $script:baseStatus="Watching your work" }
        else { $lt=[string]$sync.lesson; if($lt.Length -gt 52){ $lt=$lt.Substring($lt.Length-52) }; $lt=$lt.Trim(); $script:baseStatus=if($lt){ "Hearing: ..."+$lt }else{ "Listening to the lesson" } }
      }
    }
    else {
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#d4a017' $false; Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $r }else{ $r }); $script:lastFull=$r
      $dup=$false; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $dup=(XC-SameIssue $r $sync.lastNudge) } else { $dup=($r -eq $sync.lastNudge) }
      if(-not $dup){ Log-Watch $r $sync.lesson; if($sync.isPaused -and -not $sync.mute){ $sync.ttsText=$r } elseif(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{ [System.Media.SystemSounds]::Asterisk.Play() } } }
      $sync.lastNudge=$r
    }
  }
})
$sync.mute=$true
$script:statusText="Listening to the lesson"
$strip.Add_Shown({
  $ui.Start()
  if($env:XC_UIPROBE){
    $pv=@('## PP&E roll-forward','Your **ending PP&E** looks off in cell **C39**.','- Ending PP&E = beginning PP&E + CapEx - depreciation','- **CapEx should exceed depreciation** for a growing company','1. Check **C37** - the beginning balance link','2. Re-add **C38** (CapEx) and subtract **C39** (depreciation)') -join "`n"
    $script:lastFull=$pv; $script:collapsed=$false; Apply-Strip; Show-Answer $pv; Set-Query "Check my PP&E roll-forward"
  }
})
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close(); $rsT.Close(); $rsX.Close() }catch{}
