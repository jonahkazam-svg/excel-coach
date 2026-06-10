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
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false; $sync.lessonlog=""; $sync.coaching=$Coaching; $sync.distillbuf=""; $sync.distillCount=0; $sync.micMode=$true; $sync.srcLabel=""; $sync.pcWanted=$false; $sync.ttsText=""; $sync.ttsStop=$false; $sync.ttsVoice=(Read-EnvVal "TTS_VOICE" "onyx"); $sync.ttsMode=(Read-EnvVal "TTS" "openai"); $sync.lastWb=""; $sync.muteSound=$false; $sync.sheetPurpose=""; $sync.typedAsk=""; $sync.typedDetail=$false; $sync.askLabel=""
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model=(Read-EnvVal "WATCH_MODEL" "gpt-5.5"); $sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.segdir=Join-Path $env:TEMP "watch_seg"
$sync.sys="You are a precise, helpful live study tutor for a student doing a Breaking Into Wall Street finance course. Work out what the student is ACTUALLY doing on screen (a quiz, a video, an Excel model, reading, etc.) and help with THAT. Be accurate and conservative: only say something is wrong if you can CLEARLY see it - never guess or nitpick. Refer to things by their on-screen label/name, not guessed cell coordinates. When you do speak, be clear and explain briefly so they understand. If nothing genuinely needs saying, reply EXACTLY: OK. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }
$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (call out by name if one recurs): "+$bt }
$kfb=Join-Path $Coaching "Knowledge.md"
if(Test-Path $kfb){ $kt=(Get-Content $kfb -Raw); if($kt.Length -gt 2000){ $kt=$kt.Substring($kt.Length-2000) }; $sync.brain=$sync.brain+" Concepts the student has already covered in lessons: "+$kt }
$WatchCur=(Read-EnvVal "WATCH_CURRICULUM" "1"); $sync.curr=""
if($WatchCur -eq "1"){ try{ . (Join-Path $PSScriptRoot "curriculum.ps1"); try{ Compact-File (Join-Path $Coaching "Mastery.md") 0 }catch{}; $sync.brain=$sync.brain+(Build-CurriculumBrain); $sync.curr=((Get-Curriculum | ForEach-Object { $_.id+": "+$_.topic }) -join "`n") }catch{} }

# audio source: microphone. (Capturing system/PC audio via loopback makes the tool
# look like spyware to Windows Defender, which hard-blocks it; the mic hears the lesson
# through the speakers anyway.) Override the device name with MIC_DEVICE in .env.
$sync.micMode=$true; $sync.srcLabel="Microphone ("+$sync.mic+")"
Write-Host ("Audio source: "+$sync.srcLabel)

# start NONSTOP segmented audio capture
if(Test-Path $sync.segdir){ Remove-Item $sync.segdir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sync.segdir | Out-Null
$ffArgs='-hide_banner -loglevel error -f dshow -i audio="'+$sync.mic+'" -f segment -segment_time 10 -ac 1 -ar 16000 -reset_timestamps 1 -y "'+(Join-Path $sync.segdir "seg_%03d.wav")+'"'
$ffp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
$sync.chime=Join-Path $env:TEMP "xc_chime.wav"; try{ & $ff -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=659:duration=0.10" -f lavfi -i "sine=frequency=988:duration=0.17" -filter_complex "[0]volume=0.15,afade=t=in:st=0:d=0.01,afade=t=out:st=0.05:d=0.05[a];[1]volume=0.17,afade=t=in:st=0:d=0.01,afade=t=out:st=0.10:d=0.07[b];[a][b]concat=n=2:v=0:a=1,aecho=0.8:0.9:40:0.2" -ar 44100 -ac 2 $sync.chime 2>$null }catch{}
$sync.ffpid=$ffp.Id

$work=@'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type 'using System; using System.Runtime.InteropServices; public class Win2 { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags); }'
try{ . "C:\Users\jonah\Projects\excel-coach\tools\curriculum.ps1" }catch{}
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
$lastSeg=-1; $rolling=New-Object System.Collections.ArrayList; $lastNudgeT=(Get-Date).AddDays(-1); $lastStruggleLogged=""; $flashed=@{}; $lastXlHash=0; $lastXlChange=(Get-Date); $stuckOffered=$false
while(-not $sync.stop){
  if($sync.typedAsk){
    try{
      $tq=$sync.typedAsk; $sync.typedAsk=""; $tdet=$sync.typedDetail; $isAssist=($tq -eq "__ASSIST__"); $isAudit=($tq -eq "__AUDIT__")
      $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" }
      $afgh=[Win2]::GetForegroundWindow(); $aexFg=$false; try{ $aexFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $afgh }) }catch{}
      $fbB=$null; if(-not $aexFg){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
      $xlA=$null; if(Get-Command Read-ExcelLive -ErrorAction SilentlyContinue){ try{ $xlA=Read-ExcelLive }catch{} }
      $sysA="You are a sharp, accurate finance and Excel tutor at Breaking Into Wall Street / investment-banking level. Answer the student's question or help with whatever they are doing right now. Work carefully and double-check before answering. Format cleanly with ## headers, **bold** for key terms and the final answer, - bullets, and thousands-separated numbers when useful."
      if($isAudit){
        $ua="Do a THOROUGH final audit of my Excel work, using the EXACT cell data below as the ground truth. Check EVERY cell that holds a formula or entered value against what this sheet is meant to practice and the standard investment-banking method: verify each formula's logic, references, and signs, and recompute the numbers to confirm them. Then report with these sections: '## Verdict' - one line, either correct and complete, or how many issues; '## Issues' - each one as the exact cell, what is wrong, and the exact fix (the correct formula or value); '## Still to do' - only if parts are unfinished; '## Done right' - one short line. Be rigorous; do not wave anything through."
      } else {
        $ua=$(if($isAssist){ "Help me with whatever I am working on right now." }else{ "I ask: "+$tq })
        $ua+=" My practice is NOT always an Excel build. Right now it may be a quiz, a multiple-choice question, or a written exercise in another window (browser, Word, a PDF) with no Excel involved. Use the images of what I am actually looking at and help with THAT. If there is no real Excel work in progress, read the question or exercise on my screen and answer or explain it directly - do not dismiss the other window as irrelevant. Cite exact Excel cells only when there is real Excel data. "+$(if($tdet){ "Explain in detail with the full reasoning and steps." }else{ "Be concise: the direct answer or fix in 1 to 3 short sentences." })
      }
      $ca=@(@{type='text';text=$ua})
      if($xlA){ $ca+=@{type='text';text=("[EXACT live Excel data, if relevant - authoritative]:`n"+$xlA)} }
      if($sync.sheetPurpose){ $ca+=@{type='text';text=("Excel sheet context: "+$sync.sheetPurpose)} }
      if($sync.lessonlog){ $les2=$sync.lessonlog; if($les2.Length -gt 600){ $les2=$les2.Substring($les2.Length-600) }; $ca+=@{type='text';text=("Recent lesson context: "+$les2)} }
      if($exB){ $ca+=@{type='text';text='[Image: Excel window]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail='high'}} }
      if($coB){ $ca+=@{type='text';text='[Image: browser window]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail='high'}} }
      if($fbB){ $ca+=@{type='text';text='[Image: my full screen - what I am actually looking at right now]'}; $ca+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail='high'}} }
      $ma=@(@{role='system';content=($sysA+$sync.brain)},@{role='user';content=$ca})
      $pa=@{ model=$sync.model; max_completion_tokens=$(if($isAudit){2800}elseif($tdet){3500}else{900}); reasoning_effort=$(if($isAudit){'high'}else{'medium'}); messages=$ma } | ConvertTo-Json -Depth 12
      $abf="$env:TEMP\xc_ask.json"; [IO.File]::WriteAllText($abf,$pa,(New-Object System.Text.UTF8Encoding($false)))
      $ar=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$abf)
      $aj=$null; try{ $aj=$ar|ConvertFrom-Json }catch{}
      $ans=if($aj.choices){ ([string]$aj.choices[0].message.content).Trim() }elseif($aj.error){ "Error: "+$aj.error.message }else{ "No response - check your connection." }
      if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $ans=Clean-Answer $ans }
      $sync.text=$ans; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1
    }catch{ $sync.text="Sorry - that question failed. Try again."; $sync.isAnswer=$true; $sync.stamp=$sync.stamp+1 }
    continue
  }
  if($sync.paused){ Start-Sleep -Milliseconds 400; continue }
  try {
    $segs=@(Get-ChildItem $sync.segdir -Filter "seg_*.wav" -ErrorAction SilentlyContinue | Sort-Object Name)
    if($segs.Count -ge 2){
      $newest=$segs[$segs.Count-2]; $segN=-1; try{ $segN=[int]($newest.BaseName.Substring(4)) }catch{}
      if($segN -lt $lastSeg){ $lastSeg=-1 }
      if($segN -gt $lastSeg){
        $lastSeg=$segN; $seg=$newest.FullName
        $e="$env:TEMP\watch_vol.txt"; & $sync.ff -hide_banner -i $seg -af volumedetect -f null NUL 2>$e
        $ln=Get-Content $e | Where-Object { $_ -match 'mean_volume' } | Select-Object -First 1
        $level=if($ln -match '(-?[0-9.]+) dB'){ [double]$Matches[1] } else { -100 }
        $silent=($level -lt -45); $txt=""
        if(-not $silent){
          $rr=& curl.exe -s --max-time 40 "https://api.openai.com/v1/audio/transcriptions" -H ("Authorization: Bearer "+$sync.key) -F ("file=@"+$seg) -F "model=whisper-1" -F "response_format=json"
          $jj=$null; try{ $jj=$rr|ConvertFrom-Json }catch{}; if($jj.text){ $txt=([string]$jj.text).Trim() }
        }
        $asked=($sync.micMode -and (-not $sync.muteMe) -and ($txt -match '(?i)\bcoach\b'))
        if(-not $asked -and $txt){ [void]$rolling.Add($txt); while($rolling.Count -gt 3){ $rolling.RemoveAt(0) }; $sync.lessonlog=($sync.lessonlog+" "+$txt).Trim(); if($sync.lessonlog.Length -gt 6000){ $sync.lessonlog=$sync.lessonlog.Substring($sync.lessonlog.Length-6000) }; try{ [IO.File]::WriteAllText("$env:TEMP\xc_live_lesson.txt",$sync.lessonlog,(New-Object System.Text.UTF8Encoding($false))) }catch{} }
        $lessonCtx=($rolling -join " "); $paused=($silent -or $lessonCtx.Length -lt 3)
        $fgh=[Win2]::GetForegroundWindow(); $excelFg=$false; try{ $excelFg=[bool](Get-Process EXCEL -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -eq $fgh }) }catch{}
        $working=($excelFg -or $paused)
        $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" }
        $fbB=$null; if((-not $exB -and -not $coB) -or (-not $excelFg)){ try{ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }catch{} }
        $xlLive=$null; if(($asked -or $working) -and (Get-Command Read-ExcelLive -ErrorAction SilentlyContinue)){ try{ $xlLive=Read-ExcelLive }catch{} }
        if($xlLive -and ($xlLive -match "Workbook '([^']+)'") -and ($Matches[1] -ne $sync.lastWb)){
          $sync.lastWb=$Matches[1]
          try{
            $les=$sync.lessonlog; if($les.Length -gt 700){ $les=$les.Substring($les.Length-700) }
            $sp=@{ model="gpt-4o-mini"; max_tokens=110; temperature=0; messages=@(@{role="system";content="In ONE concise line, state what this Excel sheet is for the student to practice and the method/goal, inferred from its cells, labels, any visible question or prompt, and the recent lesson. Format exactly: 'Practicing <topic> via <method>; goal: <goal>'. Be specific; no preamble."},@{role="user";content=("Recent lesson: "+$les+"`n`nThe Excel sheet:`n"+$xlLive)}) } | ConvertTo-Json -Depth 8
            $spbf="$env:TEMP\xc_sheet.json"; [IO.File]::WriteAllText($spbf,$sp,(New-Object System.Text.UTF8Encoding($false)))
            $spr=& curl.exe -s --max-time 20 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$spbf)
            $spj=$null; try{ $spj=$spr|ConvertFrom-Json }catch{}
            if($spj.choices){ $sync.sheetPurpose=([string]$spj.choices[0].message.content).Trim(); $sf=Join-Path $sync.coaching "Sheets.md"; if(-not(Test-Path $sf)){ [IO.File]::AppendAllText($sf,"# Sheets - what each practice workbook is for`r`n",(New-Object System.Text.UTF8Encoding($false))) }; [IO.File]::AppendAllText($sf,"`r`n- "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"  '"+$sync.lastWb+"': "+$sync.sheetPurpose,(New-Object System.Text.UTF8Encoding($false))) }
          }catch{}
        }
        if($asked){
          $u="The student spoke to you and asked: '"+$txt+"'. What the instructor has recently been teaching (lesson audio): '"+$sync.lessonlog+"'. You are given up to two labeled images: MY Excel sheet (my own work) and the course/lesson. Read the exact question carefully, work it out step by step and double-check any arithmetic, then answer clearly and helpfully in 1 to 4 sentences - explain it so they understand, like a good tutor. Use my Excel, the course image, this lesson context, and your memory of their weak points. If it was not a real question, reply EXACTLY: OK"
          $useModel=$sync.model; $det="high"; $maxtok=700; $effort="medium"
        } else {
          if($paused){ $u="The lesson video is paused - I'm working on something (a quiz, an exercise, my Excel). You are given up to two labeled images: MY Excel sheet and the course/lesson. Compare my Excel to what the lesson is teaching. ONLY if you can clearly see a real mistake or that I'm stuck, say specifically what's wrong or the next step (1-2 sentences), citing exact cell addresses ONLY from the EXACT live-Excel data block if one is provided (never guess a cell from the image). If it looks fine or you're unsure, reply EXACTLY: OK." }
          else { $u="Recent lesson audio: '"+$lessonCtx+"'. You are given up to two labeled images: MY Excel sheet and the course/lesson. ONLY if you can clearly see a real, specific mistake in MY Excel versus what the lesson is teaching, point it out (1-2 sentences). If it looks fine or you're not sure, reply EXACTLY: OK - do not guess or nitpick." }
          $u=$(if($working){ "I am working in my Excel right now." }else{ "I am watching the lesson. Recent lesson audio: '"+$lessonCtx+"'." })+" Speak up ONLY for a GENUINE ERROR: a wrong formula, a wrong cell reference, a clearly wrong number, a broken or incorrect link, a wrong sign, or a real conceptual mistake versus standard investment-banking practice. Do NOT comment on the ORDER I do things, building things in a different sequence, a valid alternative method or layout, work that is simply incomplete or in progress, or style. Standard conventions matter for correctness only, never for the order or method I choose. Do NOT compute quiz/test answers yourself; reply OK for those. If there is a genuine error, give ONE short sentence naming the exact cell (from the EXACT data block, never a guessed cell). Otherwise reply EXACTLY: OK."
          if($sync.lastNudge -and $sync.lastNudge -ne 'OK'){ $u+=" You last told me: '"+$sync.lastNudge+"'. Don't repeat it." }
          $useModel=$sync.model; $det="auto"; $maxtok=$(if($working){200}else{110}); $effort=$(if($working){"low"}else{"none"})
        }
        $content=@(@{type='text';text=$u})
        if($xlLive){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative; use these cell addresses, values and formulas; never guess a cell from the image]:`n"+$xlLive)} }
        if($sync.sheetPurpose){ $content+=@{type='text';text=("What this practice sheet is for (already understood): "+$sync.sheetPurpose)} }
        if($asked -or $working){ $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching right now and what I am trying to BUILD in my Excel, then connect them. When you help or flag something, cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."} }
        $content+=@{type='text';text="My practice is NOT always an Excel build - it may be a quiz, a multiple-choice question, or a written exercise in another window (browser, Word, a PDF). Consider what I am ACTUALLY looking at in the images; never dismiss the other window as irrelevant just because it is not Excel."}
        if($exB){ $content+=@{type='text';text='[Image: MY Excel sheet (my own work)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail=$det}} }
        if($coB){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail=$det}} }
        if($fbB){ $content+=@{type='text';text='[Image: my full screen - what I am actually looking at right now]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail=$det}} }
        $msgs=@(@{role='system';content=($sync.sys+$sync.brain)},@{role='user';content=$content})
        if($useModel -match '^gpt-5'){ $payload=@{ model=$useModel; max_completion_tokens=$maxtok; reasoning_effort=$effort; messages=$msgs } | ConvertTo-Json -Depth 12 }
        else { $payload=@{ model=$useModel; max_tokens=$maxtok; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 12 }
        $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
        $vr=& curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
        $vj=$null; try{ $vj=$vr|ConvertFrom-Json }catch{}
        $sync.text=if($vj.choices){ $at=([string]$vj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $at=Clean-Answer $at }; $at } else { "OK" }
        if((-not $asked) -and $working -and $sync.text -ne "OK" -and $sync.text -ne ""){
          $vu="A quick check flagged this about my Excel: '"+$sync.text+"'. Using the EXACT cell data, decide: is this a GENUINE error (wrong formula, wrong value, wrong reference, wrong sign, broken link, or a real conceptual mistake), or is it just a different-but-valid method, a different order of steps, incomplete work in progress, or style? If it is NOT a genuine error, reply EXACTLY: OK. If it IS, restate it in ONE short sentence naming the exact cell."
          $vc=@(@{type='text';text=$vu}); if($xlLive){ $vc+=@{type='text';text=("EXACT Excel data:`n"+$xlLive)} }
          $vpay=@{ model=$sync.model; max_completion_tokens=200; reasoning_effort="low"; messages=@(@{role='system';content="You are a strict checker for a finance student. Confirm ONLY genuine errors; never flag a valid alternative method, ordering, incomplete work, or style. When unsure, reply OK."},@{role='user';content=$vc}) } | ConvertTo-Json -Depth 12
          $vbf="$env:TEMP\xc_verify.json"; [IO.File]::WriteAllText($vbf,$vpay,(New-Object System.Text.UTF8Encoding($false)))
          $vrr=& curl.exe -s --max-time 30 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$vbf)
          $vjj=$null; try{ $vjj=$vrr|ConvertFrom-Json }catch{}
          if($vjj.choices){ $vt=([string]$vjj.choices[0].message.content).Trim(); if(($vt -match '^\s*OK') -or ($vt -eq "")){ $sync.text="OK" } else { if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $vt=Clean-Answer $vt }; $sync.text=$vt } }
        }
        if((-not $asked) -and $sync.text -ne "OK" -and $sync.text -ne ""){ if(((Get-Date)-$lastNudgeT).TotalSeconds -lt 25){ $sync.text="OK" } else { $lastNudgeT=(Get-Date) } }
        if((-not $asked) -and $working -and $sync.text -ne "OK" -and $sync.text -ne ""){ $newStr=$true; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $newStr=(-not (XC-SameIssue $sync.text $lastStruggleLogged)) }; if($newStr){ $lastStruggleLogged=$sync.text; if(Get-Command Log-Struggle -ErrorAction SilentlyContinue){ try{ Log-Struggle $sync.text }catch{} } } }
        if($xlLive){
          $xh=$xlLive.GetHashCode()
          if($xh -ne $lastXlHash){ $lastXlHash=$xh; $lastXlChange=(Get-Date); $stuckOffered=$false }
          elseif($excelFg -and (-not $asked) -and (-not $stuckOffered) -and (((Get-Date)-$lastXlChange).TotalSeconds -ge 240) -and ($sync.text -eq "OK" -or $sync.text -eq "")){
            $stuckOffered=$true
            $hu="I have been stuck on this sheet for a few minutes without making changes. Give ONE simple, helpful hint for my very next step: point me at the right cell/row or the concept/method to apply. Do NOT give the full answer or the finished formula - just the nudge I need to get moving. 1-2 short sentences."
            $hc=@(@{type='text';text=$hu},@{type='text';text=("[EXACT live data from MY Excel]:`n"+$xlLive)})
            if($sync.sheetPurpose){ $hc+=@{type='text';text=("What this sheet is for: "+$sync.sheetPurpose)} }
            if($lessonCtx){ $hc+=@{type='text';text=("Recent lesson: "+$lessonCtx)} }
            $hpay=@{ model=$sync.model; max_completion_tokens=400; reasoning_effort="low"; messages=@(@{role='system';content="You are a finance/Excel tutor giving a stuck student one gentle hint. Look at where their work stops or goes wrong and nudge the very next step. Never reveal the full solution or finished formula."},@{role='user';content=$hc}) } | ConvertTo-Json -Depth 12
            $hbf="$env:TEMP\xc_hint.json"; [IO.File]::WriteAllText($hbf,$hpay,(New-Object System.Text.UTF8Encoding($false)))
            $hr=& curl.exe -s --max-time 45 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$hbf)
            $hj=$null; try{ $hj=$hr|ConvertFrom-Json }catch{}
            if($hj.choices){ $ht=([string]$hj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $ht=Clean-Answer $ht }; if($ht){ $sync.text="Hint: "+$ht } }
          }
        }
        if((-not $asked) -and ($sync.text -eq "OK" -or $sync.text -eq "")){
          $flashTxt=($lessonCtx+" "+[string]$sync.sheetPurpose).Trim()
          if((Get-Command Find-WeakFlash -ErrorAction SilentlyContinue) -and $flashTxt.Length -gt 5){
            $fb=$null; try{ $fb=Find-WeakFlash $flashTxt }catch{}
            if($fb){ $fp=$fb -split '\|',2; if(-not $flashed.ContainsKey($fp[0])){ $flashed[$fp[0]]=$true; $sync.text="Heads up - '"+$fp[0]+"' tripped you up before"+$(if($fp.Count -gt 1 -and $fp[1]){ " ("+$fp[1]+")" }else{ "" })+". Take it slow here." } }
          }
        }
        $sync.lesson=$lessonCtx; $sync.isPaused=$working; $sync.isAnswer=$asked; $sync.stamp=$sync.stamp+1
        if($segs.Count -gt 20){ for($i=0;$i -lt ($segs.Count-20);$i++){ Remove-Item $segs[$i].FullName -Force -ErrorAction SilentlyContinue } }
        if(-not $asked -and $txt){ $sync.distillbuf=($sync.distillbuf+" "+$txt).Trim(); $sync.distillCount=$sync.distillCount+1 }
        if($sync.distillCount -ge 18 -and $sync.distillbuf.Length -gt 120){
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
            if($cj.choices){ $ct=([string]$cj.choices[0].message.content).Trim(); foreach($cl in ($ct -split "`n")){ $cpp=$cl.Trim() -split '\|'; if($cpp.Count -ge 2){ $nid=$cpp[0].Trim(); $kind=$cpp[1].Trim().ToUpper(); if($kind -eq 'COVERED' -and $cpp.Count -ge 3 -and $cpp[2].Trim().ToUpper() -eq 'HIGH'){ try{ Bump-Mastery $nid 'exposed' 'covered in lesson' }catch{} } elseif($kind -eq 'STRUGGLED'){ try{ Bump-Mastery $nid 'shaky' 'struggled in lesson' }catch{} } } } }
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
    if($sync.ttsMode -eq 'openai' -and $sync.key){
      try{
        $body=@{ model="gpt-4o-mini-tts"; voice=$sync.ttsVoice; input=$t; response_format="wav"; instructions="Speak like a warm, confident investment-banking tutor: clear, encouraging, natural pacing." } | ConvertTo-Json -Compress
        $bf="$env:TEMP\xc_tts_body.json"; [IO.File]::WriteAllText($bf,$body,(New-Object System.Text.UTF8Encoding($false)))
        $raw="$env:TEMP\xc_tts_raw.wav"; if(Test-Path $raw){ Remove-Item $raw -Force -ErrorAction SilentlyContinue }
        & curl.exe -s --max-time 30 "https://api.openai.com/v1/audio/speech" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf) -o $raw 2>$null
        if((Test-Path $raw) -and ((Get-Item $raw).Length -gt 1000)){
          $pcm="$env:TEMP\xc_tts_pcm.wav"; if(Test-Path $pcm){ Remove-Item $pcm -Force -ErrorAction SilentlyContinue }
          & $sync.ff -hide_banner -loglevel error -y -i $raw -ar 44100 -ac 2 -c:a pcm_s16le $pcm 2>$null
          if((Test-Path $pcm) -and ((Get-Item $pcm).Length -gt 1000) -and (-not $sync.mute)){ $cur=New-Object System.Media.SoundPlayer $pcm; try{ $cur.Play(); $spoke=$true }catch{} }
        }
      }catch{}
    }
    if((-not $spoke) -and (-not $sync.mute)){ try{ $sp.SpeakAsync($t)|Out-Null }catch{} }
  }
  Start-Sleep -Milliseconds 150
}
'@
$rsT=[runspacefactory]::CreateRunspace(); $rsT.ApartmentState='STA'; $rsT.Open(); $rsT.SessionStateProxy.SetVariable('sync',$sync)
$pst=[powershell]::Create(); $pst.Runspace=$rsT; [void]$pst.AddScript($ttsWork); [void]$pst.BeginInvoke()

function Kill-FF { try{ Stop-Process -Id $sync.ffpid -Force -ErrorAction SilentlyContinue }catch{} }

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
$script:statusText=""; $script:dotState=""; $script:lastTimer=""; $script:t0=(Get-Date)
$script:seen=0; $script:lastFull=""; $script:idle=$true; $script:baseStatus="Listening to the lesson"; $script:ffFails=0; $script:ffLastTry=(Get-Date); $script:lastHelpQ=""; $script:askBusy=$false; $script:lastActive=(Get-Date)
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
  $wa4=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  if($script:collapsed){ $nw=(Px 280); $nh=(Px 40) } else { $nw=(Px 600); $nh=(Px 80) }
  $nl=$wa4.Left+[int](($wa4.Width-$nw)/2); $nt=$wa4.Bottom-$nh-(Px 14)
  $strip.SetBounds($nl,$nt,$nw,$nh)
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
}
function Push-StripState {
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
  JS $script:wvS ("XC.setStatus("+(ConvertTo-Json $script:statusText)+")")
  JS $script:wvS ("XC.setToggle('pause',"+(BoolJs $sync.paused)+")")
  JS $script:wvS ("XC.setToggle('mute',"+(BoolJs $sync.mute)+")")
  JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")")
  JS $script:wvS ("XC.busy(false)")
  $hp=$script:dotState; $script:dotState=""; if($hp -ne ""){ $c=$hp.Substring(0,7); $p=$hp.Substring(7); JS $script:wvS ("XC.setDot('"+$c+"',"+$p+")") } else { Set-Dot '#22c55e' $true }
}
function Show-Answer($md){
  $script:lastFull=$md
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  if($script:panelReady){
    JS $script:wvP ("XC.setTime('"+(Get-Date).ToString("HH:mm")+"')")
    JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $md)+")")
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
function Set-Query($q){ if($script:panelReady){ JS $script:wvP ("XC.setQuery("+(ConvertTo-Json ([string]$q))+")") } else { $script:pendingQ=[string]$q } }
function Shutdown-Coach {
  $sync.stop=$true; try{ $ui.Stop() }catch{}; Start-Sleep -Milliseconds 300; Kill-FF
  try{ $rs.Close() }catch{}; try{ $rsT.Close() }catch{}
  try{ $panel.Close() }catch{}
  try{ $strip.Close() }catch{}
}
function Handle-Ask($q){
  if($script:askBusy){ return }
  $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
  JS $script:wvS ("XC.busy(true)")
  if($q -eq ""){ Set-Msg "Reading your Excel + the lesson..."; $script:lastHelpQ="" } else { Set-Msg ("Thinking: "+$q); $script:lastHelpQ=$q }
  Set-Dot '#2563eb' $false
  [System.Windows.Forms.Application]::DoEvents()
  $det=$false; if($q){ $det=[bool]($q -match '(?i)explain|in detail|elaborate|\bwhy\b') }
  $sync.askLabel=$(if($q){ $q }else{ "Help with my screen" })
  $sync.typedDetail=$det; $sync.typedAsk=$(if($q){ $q }else{ "__ASSIST__" })
}
function Handle-Act($k){
  $script:lastActive=(Get-Date)
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
    'sound'    { $sync.muteSound=-not $sync.muteSound; JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")") }
    'note'     {
      $script:idle=$false; Set-Msg "Noting this for later..."; Set-Dot '#2563eb' $false
      Show-PanelLoading
      [System.Windows.Forms.Application]::DoEvents()
      $nn=Add-Note; $script:lastFull=$nn; Show-Answer $nn; Set-Query "Note this"
      $script:baseStatus="Noted - saved to revisit"; $script:idle=$true; Set-Dot '#22c55e' $true; $script:seen=$sync.stamp
    }
    'audit'    {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Deep-checking your sheet..."; Set-Dot '#2563eb' $false
      Show-PanelLoading
      $sync.askLabel="Sheet audit"; $sync.typedDetail=$true; $sync.typedAsk="__AUDIT__"
    }
    'close'    { Shutdown-Coach }
  }
}
function Handle-Panel($k,$term){
  $script:lastActive=(Get-Date)
  switch($k){
    'close'   { try{ $panel.Hide() }catch{} }
    'copy'    { try{ if($script:lastFull){ [System.Windows.Forms.Clipboard]::SetText($script:lastFull) } }catch{} }
    'explain' {
      if($script:askBusy){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $sync.askLabel="Explain in detail"; $sync.typedDetail=$true; $sync.typedAsk=$(if($script:lastHelpQ){ $script:lastHelpQ }else{ "__ASSIST__" })
    }
    'define'  {
      if($script:askBusy -or -not $term){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $q2="Define '"+$term+"' clearly and simply in the context of my course and what I am working on. 2 to 4 sentences, with a tiny concrete example if useful."
      $script:lastHelpQ=$q2
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
    'panel' { Handle-Panel ([string]$m.k) ([string]$m.term) }
    'drag'  { $script:lastActive=(Get-Date); $script:panel.Left+=[int]([double]$m.dx*$script:S); $script:panel.Top+=[int]([double]$m.dy*$script:S) }
  }
})
$strip.Add_Shown({ Glass-On $script:strip; [void]$script:wvS.EnsureCoreWebView2Async($null) })
$panel.Add_Shown({ Glass-On $script:panel; [void]$script:wvP.EnsureCoreWebView2Async($null) })
# ---- tick: worker results -> UI ----
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){
    if(((Get-Date)-$script:ffLastTry).TotalSeconds -ge 10){
      $script:ffLastTry=(Get-Date); $script:ffFails++
      if($script:ffFails -le 3){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
      elseif($script:ffFails -eq 4){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Msg "Mic capture failed - check MIC_DEVICE in .env"; Set-Dot '#ef4444' $false }
    }
  } elseif($script:ffFails -ne 0){ $script:ffFails=0 }
  if($script:idle){ Set-Msg $script:baseStatus }
  if(-not $script:collapsed){
    $el=(Get-Date)-$script:t0; $tt=("{0:00}:{1:00}" -f [int][math]::Floor($el.TotalMinutes),$el.Seconds)
    if($tt -ne $script:lastTimer){ $script:lastTimer=$tt; JS $script:wvS ("XC.setTimer('"+$tt+"')") }
  }
  if((-not $script:collapsed) -and $script:idle -and (-not $script:askBusy) -and (-not $panel.Visible)){
    if(((Get-Date)-$script:lastActive).TotalSeconds -ge 45){ $script:collapsed=$true; Apply-Strip }
  }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($r -ne "OK" -and $r -ne ""){ $script:lastActive=(Get-Date) }
    if($sync.isAnswer){
      $script:askBusy=$false; JS $script:wvS ("XC.busy(false)")
      $lbl=[string]$sync.askLabel; $sync.askLabel=""
      if($r -ne "" -and $r -ne "OK"){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Dot '#2563eb' $false; Set-Msg "Answer ready"; Show-Answer $r; Set-Query $(if($lbl){ $lbl }else{ "Voice question" }); Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$r }; $script:baseStatus="On track" }
      else { $script:idle=$true; Set-Dot '#22c55e' $true }
    }
    elseif($r -eq "OK" -or $r -eq ""){
      Set-Dot '#22c55e' $true; $script:idle=$true
      if($sync.isPaused){ $script:baseStatus="Watching your work" }
      else { $lt=[string]$sync.lesson; if($lt.Length -gt 52){ $lt=$lt.Substring($lt.Length-52) }; $lt=$lt.Trim(); $script:baseStatus=if($lt){ "Hearing: ..."+$lt }else{ "Listening to the lesson" } }
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
$sync.mute=$false
$script:statusText="Listening to the lesson"
$strip.Add_Shown({
  $ui.Start()
  if($env:XC_UIPROBE){
    $pv=@('## PP&E roll-forward','Your **ending PP&E** looks off in cell **C39**.','- Ending PP&E = beginning PP&E + CapEx - depreciation','- **CapEx should exceed depreciation** for a growing company','1. Check **C37** - the beginning balance link','2. Re-add **C38** (CapEx) and subtract **C39** (depreciation)') -join "`n"
    $script:lastFull=$pv; $script:collapsed=$false; Apply-Strip; Show-Answer $pv; Set-Query "Check my PP&E roll-forward"
  }
})
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close(); $rsT.Close() }catch{}
