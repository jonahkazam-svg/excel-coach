# watch.ps1 - LIVE ambient coach. Continuously listens + watches (non-freezing).
#   A background ffmpeg records the lesson audio NONSTOP into 10s segments. A worker thread transcribes
#   each new segment the moment it's ready (rolling ~30s lesson context), checks your screen every ~10s,
#   detects PAUSE via silence (=> you're doing the activity/stuck => active help), and uses your memory
#   (Weak Points). Strip overlay stays smooth and is invisible to recordings.
# Test: watch.ps1 -TestAsync   (starts capture, processes one segment, prints, exits)
param([switch]$TestAsync)

$Vault="C:\Users\jonah\Projects\excel-coach"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"
try{ [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $OutputEncoding=[System.Text.Encoding]::UTF8 }catch{}
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
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false; $sync.lessonlog=""; $sync.coaching=$Coaching; $sync.distillbuf=""; $sync.distillCount=0; $sync.micMode=$true; $sync.srcLabel=""; $sync.pcWanted=$false; $sync.ttsText=""; $sync.ttsStop=$false; $sync.ttsVoice=(Read-EnvVal "TTS_VOICE" "onyx"); $sync.ttsMode=(Read-EnvVal "TTS" "openai")
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
$lastSeg=-1; $rolling=New-Object System.Collections.ArrayList
while(-not $sync.stop){
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
        $exB=CapWin2 "EXCEL"; $coB=CapWin2 "chrome"; if(-not $coB){ $coB=CapWin2 "msedge" }; if(-not $coB){ $coB=CapWin2 "firefox" }
        $fbB=$null; if(-not $exB -and -not $coB){ Cap $sync.png; $fbB=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png)) }
        $xlLive=$null; if(($asked -or $paused) -and (Get-Command Read-ExcelLive -ErrorAction SilentlyContinue)){ try{ $xlLive=Read-ExcelLive }catch{} }
        if($asked){
          $u="The student spoke to you and asked: '"+$txt+"'. What the instructor has recently been teaching (lesson audio): '"+$sync.lessonlog+"'. You are given up to two labeled images: MY Excel sheet (my own work) and the course/lesson. Read the exact question carefully, work it out step by step and double-check any arithmetic, then answer clearly and helpfully in 1 to 4 sentences - explain it so they understand, like a good tutor. Use my Excel, the course image, this lesson context, and your memory of their weak points. If it was not a real question, reply EXACTLY: OK"
          $useModel=$sync.model; $det="high"; $maxtok=2500; $effort="medium"
        } else {
          if($paused){ $u="The lesson video is paused - I'm working on something (a quiz, an exercise, my Excel). You are given up to two labeled images: MY Excel sheet and the course/lesson. Compare my Excel to what the lesson is teaching. ONLY if you can clearly see a real mistake or that I'm stuck, say specifically what's wrong or the next step (1-2 sentences), citing exact cell addresses ONLY from the EXACT live-Excel data block if one is provided (never guess a cell from the image). If it looks fine or you're unsure, reply EXACTLY: OK." }
          else { $u="Recent lesson audio: '"+$lessonCtx+"'. You are given up to two labeled images: MY Excel sheet and the course/lesson. ONLY if you can clearly see a real, specific mistake in MY Excel versus what the lesson is teaching, point it out (1-2 sentences). If it looks fine or you're not sure, reply EXACTLY: OK - do not guess or nitpick." }
          $u+=" Do NOT try to compute or answer quiz/test calculation questions yourself; reply OK for those (the student can ask for that)."
          if($sync.lastNudge -and $sync.lastNudge -ne 'OK'){ $u+=" You last told me: '"+$sync.lastNudge+"'. Don't repeat it." }
          $useModel=$sync.model; $det="auto"; $maxtok=$(if($paused){220}else{120}); $effort=$(if($paused){"low"}else{"none"})
        }
        $content=@(@{type='text';text=$u})
        if($xlLive){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative; use these cell addresses, values and formulas; never guess a cell from the image]:`n"+$xlLive)} }
        if($asked -or $paused){ $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching right now and what I am trying to BUILD in my Excel, then connect them. When you help or flag something, cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."} }
        if($exB){ $content+=@{type='text';text='[Image: MY Excel sheet (my own work)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail=$det}} }
        if($coB){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail=$det}} }
        if($fbB){ $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail=$det}} }
        $msgs=@(@{role='system';content=($sync.sys+$sync.brain)},@{role='user';content=$content})
        if($useModel -match '^gpt-5'){ $payload=@{ model=$useModel; max_completion_tokens=$maxtok; reasoning_effort=$effort; messages=$msgs } | ConvertTo-Json -Depth 12 }
        else { $payload=@{ model=$useModel; max_tokens=$maxtok; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 12 }
        $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
        $vr=& curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
        $vj=$null; try{ $vj=$vr|ConvertFrom-Json }catch{}
        $sync.text=if($vj.choices){ $at=([string]$vj.choices[0].message.content).Trim(); if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $at=Clean-Answer $at }; $at } else { "OK" }
        $sync.lesson=$lessonCtx; $sync.isPaused=$paused; $sync.isAnswer=$asked; $sync.stamp=$sync.stamp+1
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
function Get-Help($question){
  $xlData=Read-ExcelLive
  $ex=Cap-Win "EXCEL"; $co=Cap-Win "chrome"; if(-not $co){ $co=Cap-Win "msedge" }; if(-not $co){ $co=Cap-Win "firefox" }
  if(-not $ex -and -not $co -and -not $xlData){ return "Couldn't find your Excel or browser window to read." }
  $sysH="You are a sharp finance and Excel tutor (Breaking Into Wall Street level). The student follows a course and rebuilds it in Excel. You may be given: the EXACT live contents of their Excel (every non-empty cell's address, value and formula, read straight from the workbook), an image of their Excel, and/or an image of the course/lesson. When the exact Excel data is present, treat it as the ground truth for ALL cell references, values and formulas - never guess a cell address from the image. METHOD for getting it right: (1) first read the exact question or task carefully and be sure you understand precisely what is being asked; (2) work it out step by step using the actual cell values and formulas; (3) double-check your arithmetic and logic; (4) then give the correct answer with a brief clear explanation, citing exact cell addresses (e.g. C39). If there is a quiz/question, work out the correct answer and, if it is multiple choice, state exactly which option to pick. If it is an Excel exercise, give the specific next step or fix and the exact cell(s) and formula to use. If the student typed a specific question, answer THAT directly. Accuracy above all - if you are not sure, say what you would check rather than guessing. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
  $uh=if($question){ "The student asks: "+$question }else{ "Help me with my work right now." }; if($sync.lessonlog){ $uh+=" (What the instructor has recently been teaching: '"+$sync.lessonlog+"'.)" }
  $content=@(@{type='text';text=$uh})
  if($xlData){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative, use these cell addresses/values/formulas; do not guess cells from the image]:`n"+$xlData)} }
  $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching and what I am trying to BUILD in my Excel, then connect them: cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."}
  if($ex){ $content+=@{type='text';text='[Image: MY Excel sheet (visual context only)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$ex);detail='high'}} }
  if($co){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$co);detail='high'}} }
  $msgs=@(@{role='system';content=($sysH+$sync.brain)},@{role='user';content=$content})
  if($sync.model -match '^gpt-5'){ $payload=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort='medium'; messages=$msgs } | ConvertTo-Json -Depth 14 }
  else { $payload=@{ model=$sync.model; max_tokens=700; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 14 }
  $bf="$env:TEMP\help_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a } elseif($j.error){ return "Error: "+$j.error.message } else { return "No response (check connection)." }
}
function Set-Round($ctl,$rad){ $d=$rad*2; $w=$ctl.Width; $h=$ctl.Height; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $ctl.Region=New-Object System.Drawing.Region($gp) }
function Draw-Border($g,$w,$h,$rad,$col){ $g.SmoothingMode='AntiAlias'; $pen=New-Object System.Drawing.Pen($col,1); $d=$rad*2; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $g.DrawPath($pen,$gp); $pen.Dispose(); $gp.Dispose() }
function Append-Inline($rtb,$content,$base,$bld,$fg,$bw){
  if($content -eq ''){ return }
  $b=$false
  foreach($p in ($content -split '(\*\*)')){
    if($p -eq '**'){ $b=-not $b; continue }
    if($p -eq ''){ continue }
    $rtb.SelectionFont=$(if($b){$bld}else{$base}); $rtb.SelectionColor=$(if($b){$bw}else{$fg}); $rtb.AppendText($p)
  }
}
function Render-Rich($rtb,$text){
  $rtb.Clear()
  $fg=[System.Drawing.Color]::FromArgb(226,231,239); $acc=[System.Drawing.Color]::FromArgb(125,178,255); $bw=[System.Drawing.Color]::FromArgb(246,248,251)
  $base=New-Object System.Drawing.Font("Segoe UI",11.5); $bld=New-Object System.Drawing.Font("Segoe UI",11.5,[System.Drawing.FontStyle]::Bold)
  $h1=New-Object System.Drawing.Font("Segoe UI Semibold",15,[System.Drawing.FontStyle]::Bold); $h2=New-Object System.Drawing.Font("Segoe UI Semibold",13,[System.Drawing.FontStyle]::Bold)
  foreach($ln in (($text -replace "`r`n","`n") -split "`n")){
    $t=$ln
    if($t -match '^\s{0,3}(#{1,6})\s+(.*)$'){ $rtb.SelectionBullet=$false; $rtb.SelectionIndent=0; $rtb.SelectionFont=$(if($Matches[1].Length -le 1){$h1}else{$h2}); $rtb.SelectionColor=$acc; $rtb.AppendText(($Matches[2] -replace '\*\*','')+"`n"); continue }
    if($t -match '^\s*[\*\-\+]\s+(.*)$'){ $rtb.SelectionBullet=$true; $rtb.SelectionIndent=14; $rtb.BulletIndent=6; Append-Inline $rtb ($Matches[1]) $base $bld $fg $bw; $rtb.AppendText("`n"); $rtb.SelectionBullet=$false; $rtb.SelectionIndent=0; continue }
    if($t -match '^\s*(\d+)\.\s+(.*)$'){ $rtb.SelectionBullet=$false; $rtb.SelectionIndent=14; $rtb.SelectionFont=$bld; $rtb.SelectionColor=$acc; $rtb.AppendText($Matches[1]+". "); Append-Inline $rtb ($Matches[2]) $base $bld $fg $bw; $rtb.AppendText("`n"); $rtb.SelectionIndent=0; continue }
    $rtb.SelectionBullet=$false; $rtb.SelectionIndent=0; Append-Inline $rtb $t $base $bld $fg $bw; $rtb.AppendText("`n")
  }
  $rtb.SelectionStart=0; $rtb.SelectionLength=0
}
function Show-HelpPopup($text){
  if($script:helpPopup -and -not $script:helpPopup.IsDisposed){ try{ $script:helpPopup.Close() }catch{} }
  $f=New-Object System.Windows.Forms.Form; $f.Text="Coach"; $f.FormBorderStyle='None'; $f.TopMost=$true; $f.ShowInTaskbar=$false; $f.Width=600; $f.Height=400; $f.StartPosition='Manual'
  $wa2=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $f.Left=$wa2.Right-$f.Width-24; $f.Top=$wa2.Bottom-$f.Height-72; $f.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
  Set-Round $f 16
  $f.Add_Paint({ param($s,$e); Draw-Border $e.Graphics $s.ClientSize.Width $s.ClientSize.Height 16 ([System.Drawing.Color]::FromArgb(58,64,78)) })
  $head=New-Object System.Windows.Forms.Label; $head.Text="  COACH"; $head.Dock='Top'; $head.Height=42; $head.ForeColor=[System.Drawing.Color]::FromArgb(120,170,255); $head.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $head.TextAlign='MiddleLeft'; $head.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
  $body=New-Object System.Windows.Forms.RichTextBox; $body.Multiline=$true; $body.ReadOnly=$true; $body.Dock='Fill'; $body.BorderStyle='None'; $body.BackColor=[System.Drawing.Color]::FromArgb(28,31,38); $body.ForeColor=[System.Drawing.Color]::FromArgb(226,231,239); $body.Font=New-Object System.Drawing.Font("Segoe UI",11.5); $body.ScrollBars='Vertical'; $body.TabStop=$false; $body.DetectUrls=$false
  Render-Rich $body $text
  $pad=New-Object System.Windows.Forms.Panel; $pad.Dock='Fill'; $pad.Padding='18,4,18,8'; $pad.BackColor=[System.Drawing.Color]::FromArgb(28,31,38); $pad.Controls.Add($body)
  $hint=New-Object System.Windows.Forms.Label; $hint.Text="Esc to close   "; $hint.Dock='Bottom'; $hint.Height=24; $hint.ForeColor=[System.Drawing.Color]::FromArgb(120,126,140); $hint.TextAlign='MiddleRight'; $hint.BackColor=[System.Drawing.Color]::FromArgb(28,31,38)
  $bClose=New-Object System.Windows.Forms.Button; $bClose.Text=([char]0xE711); $bClose.Font=New-Object System.Drawing.Font("Segoe MDL2 Assets",10); $bClose.Width=36; $bClose.Height=28; $bClose.FlatStyle='Flat'; $bClose.FlatAppearance.BorderSize=0; $bClose.BackColor=[System.Drawing.Color]::FromArgb(24,26,32); $bClose.ForeColor=[System.Drawing.Color]::FromArgb(200,205,214); $bClose.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(210,70,70); $bClose.Cursor='Hand'; $bClose.Left=$f.Width-46; $bClose.Top=7; $bClose.Add_Click({ $script:helpPopup.Close() })
  $f.Controls.Add($head); $f.Controls.Add($hint); $f.Controls.Add($pad); $f.Controls.Add($bClose); $pad.BringToFront(); $bClose.BringToFront()
  $f.KeyPreview=$true; $f.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){ $script:helpPopup.Close() } })
  $head.Add_MouseDown({ $script:dragP=$_.Location; $script:dragOn=$true }); $head.Add_MouseUp({ $script:dragOn=$false }); $head.Add_MouseMove({ if($script:dragOn){ $script:helpPopup.Left += ($_.X-$script:dragP.X); $script:helpPopup.Top += ($_.Y-$script:dragP.Y) } })
  $f.Add_Shown({ try{ $body.SelectionStart=0; $body.SelectionLength=0 }catch{} })
  $script:helpPopup=$f; $f.Show()
}
$strip=New-Object System.Windows.Forms.Form
$strip.FormBorderStyle='None'; $strip.TopMost=$true; $strip.ShowInTaskbar=$false; $strip.StartPosition='Manual'; $strip.Width=600; $strip.Height=80; $strip.Opacity=0.97; $strip.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-14
Set-Round $strip 16
$strip.Add_Paint({ param($s,$e); Draw-Border $e.Graphics $s.ClientSize.Width $s.ClientSize.Height 16 ([System.Drawing.Color]::FromArgb(58,64,78)); $sep=New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(42,46,57)); $e.Graphics.DrawLine($sep,16,40,($s.ClientSize.Width-16),40); $sep.Dispose() })
$dot=New-Object System.Windows.Forms.Panel; $dot.Width=12; $dot.Height=12; $dot.Left=18; $dot.Top=15; $dot.BackColor=[System.Drawing.Color]::FromArgb(120,130,145)
$dgp=New-Object System.Drawing.Drawing2D.GraphicsPath; $dgp.AddEllipse(0,0,12,12); $dot.Region=New-Object System.Drawing.Region($dgp)
$script:msg=New-Object System.Windows.Forms.Label; $script:msg.Left=40; $script:msg.Top=2; $script:msg.Width=384; $script:msg.Height=36; $script:msg.ForeColor=[System.Drawing.Color]::FromArgb(236,239,244); $script:msg.Font=New-Object System.Drawing.Font("Segoe UI Semibold",10); $script:msg.TextAlign='MiddleLeft'; $script:msg.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
$tip=New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay=350
function Mini($glyph,$fontName,$fsize,$x,$accent){ $b=New-Object System.Windows.Forms.Button; $b.Text=$glyph; $b.Left=$x; $b.Top=6; $b.Width=34; $b.Height=34; $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.Font=New-Object System.Drawing.Font($fontName,$fsize); $b.Cursor='Hand'; if($accent){ $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(56,120,236); $b.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(74,140,255); $b.FlatAppearance.MouseDownBackColor=[System.Drawing.Color]::FromArgb(44,104,214) } else { $b.ForeColor=[System.Drawing.Color]::FromArgb(222,227,235); $b.BackColor=[System.Drawing.Color]::FromArgb(34,37,46); $b.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(50,55,68); $b.FlatAppearance.MouseDownBackColor=[System.Drawing.Color]::FromArgb(40,44,54) }; return $b }
$mdl="Segoe MDL2 Assets"
$bPause=Mini ([char]0xE769) $mdl 12 432 $false
$bMute=Mini ([char]0xE767) $mdl 12 472 $false
$bHelp=Mini "?" "Segoe UI Semibold" 14 512 $true
$bX=Mini ([char]0xE711) $mdl 10 552 $false
foreach($bb in @($bPause,$bMute,$bHelp,$bX)){ Set-Round $bb 9 }
$tip.SetToolTip($bPause,"Pause coaching"); $tip.SetToolTip($bMute,"Mute coach voice"); $tip.SetToolTip($bHelp,"Get help (reads your screen)"); $tip.SetToolTip($bX,"Close coach")
$script:askPH="Ask me anything - I can see your screen + Excel"
$ask=New-Object System.Windows.Forms.TextBox; $ask.Left=16; $ask.Top=44; $ask.Width=480; $ask.BorderStyle='FixedSingle'; $ask.BackColor=[System.Drawing.Color]::FromArgb(34,37,46); $ask.ForeColor=[System.Drawing.Color]::FromArgb(140,146,158); $ask.Font=New-Object System.Drawing.Font("Segoe UI",11); $ask.Text=$script:askPH
$bAsk=New-Object System.Windows.Forms.Button; $bAsk.Text="Ask"; $bAsk.Left=502; $bAsk.Top=43; $bAsk.Width=44; $bAsk.Height=26; $bAsk.FlatStyle='Flat'; $bAsk.FlatAppearance.BorderSize=0; $bAsk.ForeColor=[System.Drawing.Color]::White; $bAsk.BackColor=[System.Drawing.Color]::FromArgb(56,120,236); $bAsk.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(74,140,255); $bAsk.Font=New-Object System.Drawing.Font("Segoe UI Semibold",9); $bAsk.Cursor='Hand'; Set-Round $bAsk 7
$bNote=New-Object System.Windows.Forms.Button; $bNote.Text=([char]0xE718); $bNote.Left=552; $bNote.Top=43; $bNote.Width=34; $bNote.Height=26; $bNote.FlatStyle='Flat'; $bNote.FlatAppearance.BorderSize=0; $bNote.ForeColor=[System.Drawing.Color]::White; $bNote.BackColor=[System.Drawing.Color]::FromArgb(72,92,124); $bNote.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(92,116,154); $bNote.Font=New-Object System.Drawing.Font("Segoe MDL2 Assets",11); $bNote.Cursor='Hand'; Set-Round $bNote 7; $tip.SetToolTip($bNote,"Note this - flag what I'm doing now to revisit and practice later")
$speaker=New-Object System.Speech.Synthesis.SpeechSynthesizer; try{ $speaker.Rate=1 }catch{}; $sync.mute=$false
$strip.Controls.AddRange(@($script:msg,$dot,$bPause,$bMute,$bHelp,$bX,$ask,$bAsk,$bNote)); $dot.BringToFront()
$script:seen=0; $script:lastFull=""; $script:pulse=0; $script:idle=$true; $script:baseStatus="Listening to the lesson"; $script:ffFails=0; $script:ffLastTry=(Get-Date); $script:dotBase=[System.Drawing.Color]::FromArgb(76,180,120)
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){
    if(((Get-Date)-$script:ffLastTry).TotalSeconds -ge 10){
      $script:ffLastTry=(Get-Date); $script:ffFails++
      if($script:ffFails -le 3){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
      elseif($script:ffFails -eq 4){ $script:idle=$false; $script:msg.Text="Mic capture failed - check MIC_DEVICE in .env"; $dot.BackColor=[System.Drawing.Color]::FromArgb(210,80,80) }
    }
  } elseif($script:ffFails -ne 0){ $script:ffFails=0 }
  $script:pulse=($script:pulse+1)%8
  if($script:idle){ $script:msg.Text=$script:baseStatus; $tri=[math]::Abs($script:pulse-4)/4.0; $bf=0.5+0.5*(1-$tri); $bc=$script:dotBase; $dot.BackColor=[System.Drawing.Color]::FromArgb([int]($bc.R*$bf),[int]($bc.G*$bf),[int]($bc.B*$bf)) }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($sync.isAnswer){
      if($r -ne "" -and $r -ne "OK"){ $script:idle=$false; $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); $script:msg.Text="Answer ready - click to read"; $script:lastFull=$r; Show-HelpPopup $r; Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$r } }
    }
    elseif($r -eq "OK" -or $r -eq ""){
      $script:dotBase=[System.Drawing.Color]::FromArgb(76,180,120); $dot.BackColor=$script:dotBase; $script:idle=$true
      if($sync.isPaused){ $script:baseStatus="Watching your work" }
      else { $lt=[string]$sync.lesson; if($lt.Length -gt 52){ $lt=$lt.Substring($lt.Length-52) }; $lt=$lt.Trim(); $script:baseStatus=if($lt){ "Hearing: ..."+$lt }else{ "Listening to the lesson" } }
    }
    else {
      $script:idle=$false; $dot.BackColor=[System.Drawing.Color]::FromArgb(235,180,70); $script:msg.Text=$(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $r }else{ $r }); $script:lastFull=$r
      if($r -ne $sync.lastNudge){ Log-Watch $r $sync.lesson; if($sync.isPaused -and -not $sync.mute){ $sync.ttsText=$r } else { [System.Media.SystemSounds]::Asterisk.Play() } }
      $sync.lastNudge=$r
    }
  }
})
$script:askBusy=$false
$submitAsk={
  if($script:askBusy){ return }
  $q=$ask.Text.Trim(); if($q -eq "" -or $q -eq $script:askPH){ return }
  $script:askBusy=$true; $script:idle=$false; $ask.Text=""
  $script:msg.Text="Thinking: "+$q; $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); [System.Windows.Forms.Application]::DoEvents()
  $ans=Get-Help $q; $script:lastFull=$ans
  Show-HelpPopup $ans; Log-Watch ("[you asked: "+$q+"] "+$ans) ""
  if(-not $sync.mute){ $sync.ttsText=$ans }
  $script:baseStatus="On track"; $script:idle=$true; $dot.BackColor=[System.Drawing.Color]::FromArgb(76,180,120); $script:seen=$sync.stamp; $script:askBusy=$false
}
$ask.Add_GotFocus({ if($ask.Text -eq $script:askPH){ $ask.Text=""; $ask.ForeColor=[System.Drawing.Color]::FromArgb(236,239,244) } })
$ask.Add_LostFocus({ if($ask.Text.Trim() -eq ""){ $ask.Text=$script:askPH; $ask.ForeColor=[System.Drawing.Color]::FromArgb(140,146,158) } })
$ask.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){ $_.SuppressKeyPress=$true; & $submitAsk } })
$bAsk.Add_Click($submitAsk)
$bPause.Add_Click({ $sync.paused=-not $sync.paused; $bPause.Text=$(if($sync.paused){[char]0xE768}else{[char]0xE769}); $tip.SetToolTip($bPause,$(if($sync.paused){"Resume coaching"}else{"Pause coaching"})); if($sync.paused){ $script:idle=$false; $script:msg.Text="Paused"; $dot.BackColor=[System.Drawing.Color]::FromArgb(120,130,145) } else { $script:baseStatus="Listening to the lesson"; $script:dotBase=[System.Drawing.Color]::FromArgb(76,180,120); $script:idle=$true } })
$bMute.Add_Click({ $sync.mute=-not $sync.mute; $bMute.Text=$(if($sync.mute){[char]0xE74F}else{[char]0xE767}); $tip.SetToolTip($bMute,$(if($sync.mute){"Unmute coach voice"}else{"Mute coach voice"})); if($sync.mute){ $sync.ttsStop=$true } })
$bHelp.Add_Click({
  $script:idle=$false; $script:msg.Text="Reading your Excel + the lesson (~30-40s)..."; $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); [System.Windows.Forms.Application]::DoEvents()
  $ans=Get-Help; $script:lastFull=$ans
  Show-HelpPopup $ans; Log-Watch ("[help] "+$ans) ""
  if(-not $sync.mute){ $sync.ttsText=$ans }
  $script:baseStatus="On track"; $script:idle=$true; $dot.BackColor=[System.Drawing.Color]::FromArgb(76,180,120); $script:seen=$sync.stamp
})
$bX.Add_Click({ $sync.stop=$true; $ui.Stop(); Start-Sleep -Milliseconds 300; Kill-FF; try{ $rs.Close() }catch{}; try{ $rsT.Close() }catch{}; $strip.Close() })
$bNote.Add_Click({
  $script:idle=$false; $script:msg.Text="Noting this for later..."; $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); [System.Windows.Forms.Application]::DoEvents()
  $nn=Add-Note; $script:lastFull=$nn; Show-HelpPopup $nn
  $script:baseStatus="Noted - saved to revisit"; $script:dotBase=[System.Drawing.Color]::FromArgb(76,180,120); $script:idle=$true; $script:seen=$sync.stamp
})
$script:msg.Cursor='Hand'; $script:msg.Add_Click({ if($script:lastFull){ Show-HelpPopup $script:lastFull } })
$strip.Add_Shown({ $ui.Start() })
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close(); $rsT.Close() }catch{}
