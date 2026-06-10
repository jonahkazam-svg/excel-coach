# watch.ps1 - LIVE ambient coach. Continuously listens + watches (non-freezing).
#   A background ffmpeg records the lesson audio NONSTOP into 10s segments. A worker thread transcribes
#   each new segment the moment it's ready (rolling ~30s lesson context), checks your screen every ~10s,
#   detects PAUSE via silence (=> you're doing the activity/stuck => active help), and uses your memory
#   (Weak Points). Strip overlay stays smooth and is invisible to recordings.
# Test: watch.ps1 -TestAsync   (starts capture, processes one segment, prints, exits)
param([switch]$TestAsync)

$Vault="C:\Users\jonah\Projects\excel-coach"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"
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
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false; $sync.lessonlog=""; $sync.coaching=$Coaching; $sync.distillbuf=""; $sync.distillCount=0; $sync.micMode=$true; $sync.srcLabel=""; $sync.pcWanted=$false
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model=(Read-EnvVal "WATCH_MODEL" "gpt-5.5"); $sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.segdir=Join-Path $env:TEMP "watch_seg"
$sync.sys="You are a precise, helpful live study tutor for a student doing a Breaking Into Wall Street finance course. Work out what the student is ACTUALLY doing on screen (a quiz, a video, an Excel model, reading, etc.) and help with THAT. Be accurate and conservative: only say something is wrong if you can CLEARLY see it - never guess or nitpick. Refer to things by their on-screen label/name, not guessed cell coordinates. When you do speak, be clear and explain briefly so they understand. If nothing genuinely needs saying, reply EXACTLY: OK."
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }
$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (call out by name if one recurs): "+$bt }
$kfb=Join-Path $Coaching "Knowledge.md"
if(Test-Path $kfb){ $kt=(Get-Content $kfb -Raw); if($kt.Length -gt 2000){ $kt=$kt.Substring($kt.Length-2000) }; $sync.brain=$sync.brain+" Concepts the student has already covered in lessons: "+$kt }

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
$processed=-1; $rolling=New-Object System.Collections.ArrayList
while(-not $sync.stop){
  if($sync.paused){ Start-Sleep -Milliseconds 400; continue }
  try {
    $segs=@(Get-ChildItem $sync.segdir -Filter "seg_*.wav" -ErrorAction SilentlyContinue | Sort-Object Name)
    if($segs.Count -ge 2){
      $idx=$segs.Count-2
      if($idx -gt $processed){
        $processed=$idx; $seg=$segs[$idx].FullName
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
        if($asked){
          $u="The student spoke to you and asked: '"+$txt+"'. What the instructor has recently been teaching (lesson audio): '"+$sync.lessonlog+"'. You are given up to two labeled images: MY Excel sheet (my own work) and the course/lesson. Read the exact question carefully, work it out step by step and double-check any arithmetic, then answer clearly and helpfully in 1 to 4 sentences - explain it so they understand, like a good tutor. Use my Excel, the course image, this lesson context, and your memory of their weak points. If it was not a real question, reply EXACTLY: OK"
          $useModel=$sync.model; $det="high"; $maxtok=2500; $effort="medium"
        } else {
          if($paused){ $u="The lesson video is paused - I'm working on something (a quiz, an exercise, my Excel). You are given up to two labeled images: MY Excel sheet and the course/lesson. Compare my Excel to what the lesson is teaching. ONLY if you can clearly see a real mistake or that I'm stuck, say specifically what's wrong or the next step (1-2 sentences), referring to cells/labels you can actually see. If it looks fine or you're unsure, reply EXACTLY: OK." }
          else { $u="Recent lesson audio: '"+$lessonCtx+"'. You are given up to two labeled images: MY Excel sheet and the course/lesson. ONLY if you can clearly see a real, specific mistake in MY Excel versus what the lesson is teaching, point it out (1-2 sentences). If it looks fine or you're not sure, reply EXACTLY: OK - do not guess or nitpick." }
          $u+=" Do NOT try to compute or answer quiz/test calculation questions yourself; reply OK for those (the student can ask for that)."
          if($sync.lastNudge -and $sync.lastNudge -ne 'OK'){ $u+=" You last told me: '"+$sync.lastNudge+"'. Don't repeat it." }
          $useModel=$sync.model; $det="auto"; $maxtok=120; $effort="none"
        }
        $content=@(@{type='text';text=$u})
        if($exB){ $content+=@{type='text';text='[Image: MY Excel sheet (my own work)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$exB);detail=$det}} }
        if($coB){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$coB);detail=$det}} }
        if($fbB){ $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$fbB);detail=$det}} }
        $msgs=@(@{role='system';content=($sync.sys+$sync.brain)},@{role='user';content=$content})
        if($useModel -match '^gpt-5'){ $payload=@{ model=$useModel; max_completion_tokens=$maxtok; reasoning_effort=$effort; messages=$msgs } | ConvertTo-Json -Depth 12 }
        else { $payload=@{ model=$useModel; max_tokens=$maxtok; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 12 }
        $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
        $vr=& curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
        $vj=$null; try{ $vj=$vr|ConvertFrom-Json }catch{}
        $sync.text=if($vj.choices){ ([string]$vj.choices[0].message.content).Trim() } else { "OK" }
        $sync.lesson=$lessonCtx; $sync.isPaused=$paused; $sync.isAnswer=$asked; $sync.stamp=$sync.stamp+1
        if($segs.Count -gt 6){ for($i=0;$i -lt ($segs.Count-6);$i++){ Remove-Item $segs[$i].FullName -Force -ErrorAction SilentlyContinue } }
        if(-not $asked -and $txt){ $sync.distillbuf=($sync.distillbuf+" "+$txt).Trim(); $sync.distillCount=$sync.distillCount+1 }
        if($sync.distillCount -ge 18 -and $sync.distillbuf.Length -gt 120){
          $dp=@{ model="gpt-4o-mini"; max_tokens=220; temperature=0; messages=@(@{role="system";content="Extract the 1-3 most important finance/Excel concepts or facts taught in this lesson excerpt as concise one-line bullets starting with '- '. No preamble; skip trivial chatter."},@{role="user";content=$sync.distillbuf}) } | ConvertTo-Json -Depth 6
          $dbf="$env:TEMP\xc_distill.json"; [IO.File]::WriteAllText($dbf,$dp,(New-Object System.Text.UTF8Encoding($false)))
          $dr=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$dbf)
          $dj=$null; try{ $dj=$dr|ConvertFrom-Json }catch{}
          if($dj.choices){ $kf=Join-Path $sync.coaching "Knowledge.md"; if(-not(Test-Path $kf)){ [IO.File]::AppendAllText($kf,"# Knowledge - concepts from the lessons`n",(New-Object System.Text.UTF8Encoding($false))) }; [IO.File]::AppendAllText($kf,"`n"+([string]$dj.choices[0].message.content).Trim()+"`n",(New-Object System.Text.UTF8Encoding($false))) }
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
function Get-Help {
  $ex=Cap-Win "EXCEL"; $co=Cap-Win "chrome"; if(-not $co){ $co=Cap-Win "msedge" }; if(-not $co){ $co=Cap-Win "firefox" }
  if(-not $ex -and -not $co){ return "Couldn't find your Excel or browser window to read." }
  $sysH="You are a sharp finance and Excel tutor (Breaking Into Wall Street level). The student follows a course and rebuilds it in Excel. You are given an image of THEIR Excel sheet and/or an image of the course/lesson (each labeled). METHOD for getting it right: (1) first read the exact question or task carefully and be sure you understand precisely what is being asked; (2) work it out step by step using the actual numbers and cells you can see; (3) double-check your arithmetic and logic; (4) then give the correct answer with a brief clear explanation, referring to cells by their visible labels. If there is a quiz/question, work out the correct answer and, if it is multiple choice, state exactly which option to pick. If it is an Excel exercise, give the specific next step or fix for THEIR sheet. Accuracy above all - if you are not sure, say what you would check rather than guessing."
  $uh="Help me with my work right now."; if($sync.lessonlog){ $uh+=" What the instructor has recently been teaching: '"+$sync.lessonlog+"'." }
  $content=@(@{type='text';text=$uh})
  if($ex){ $content+=@{type='text';text='[Image: MY Excel sheet (my work)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$ex);detail='high'}} }
  if($co){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$co);detail='high'}} }
  $msgs=@(@{role='system';content=($sysH+$sync.brain)},@{role='user';content=$content})
  if($sync.model -match '^gpt-5'){ $payload=@{ model=$sync.model; max_completion_tokens=3500; reasoning_effort='medium'; messages=$msgs } | ConvertTo-Json -Depth 14 }
  else { $payload=@{ model=$sync.model; max_tokens=700; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 14 }
  $bf="$env:TEMP\help_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ return [string]$j.choices[0].message.content } elseif($j.error){ return "Error: "+$j.error.message } else { return "No response (check connection)." }
}
function Set-Round($ctl,$rad){ $d=$rad*2; $w=$ctl.Width; $h=$ctl.Height; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $ctl.Region=New-Object System.Drawing.Region($gp) }
function Draw-Border($g,$w,$h,$rad,$col){ $g.SmoothingMode='AntiAlias'; $pen=New-Object System.Drawing.Pen($col,1); $d=$rad*2; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $g.DrawPath($pen,$gp); $pen.Dispose(); $gp.Dispose() }
function Show-HelpPopup($text){
  if($script:helpPopup -and -not $script:helpPopup.IsDisposed){ try{ $script:helpPopup.Close() }catch{} }
  $f=New-Object System.Windows.Forms.Form; $f.Text="Coach"; $f.FormBorderStyle='None'; $f.TopMost=$true; $f.ShowInTaskbar=$false; $f.Width=600; $f.Height=400; $f.StartPosition='Manual'
  $wa2=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $f.Left=$wa2.Right-$f.Width-24; $f.Top=$wa2.Bottom-$f.Height-72; $f.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
  Set-Round $f 16
  $f.Add_Paint({ param($s,$e); Draw-Border $e.Graphics $s.ClientSize.Width $s.ClientSize.Height 16 ([System.Drawing.Color]::FromArgb(58,64,78)) })
  $head=New-Object System.Windows.Forms.Label; $head.Text="  COACH"; $head.Dock='Top'; $head.Height=42; $head.ForeColor=[System.Drawing.Color]::FromArgb(120,170,255); $head.Font=New-Object System.Drawing.Font("Segoe UI Semibold",11); $head.TextAlign='MiddleLeft'; $head.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
  $body=New-Object System.Windows.Forms.TextBox; $body.Multiline=$true; $body.ReadOnly=$true; $body.Dock='Fill'; $body.BorderStyle='None'; $body.BackColor=[System.Drawing.Color]::FromArgb(28,31,38); $body.ForeColor=[System.Drawing.Color]::FromArgb(232,236,242); $body.Font=New-Object System.Drawing.Font("Segoe UI",12); $body.ScrollBars='Vertical'; $body.TabStop=$false
  $body.Text=(($text -replace "`r`n","`n") -replace "`n","`r`n")
  $pad=New-Object System.Windows.Forms.Panel; $pad.Dock='Fill'; $pad.Padding='18,4,18,8'; $pad.BackColor=[System.Drawing.Color]::FromArgb(28,31,38); $pad.Controls.Add($body)
  $hint=New-Object System.Windows.Forms.Label; $hint.Text="Esc to close   "; $hint.Dock='Bottom'; $hint.Height=24; $hint.ForeColor=[System.Drawing.Color]::FromArgb(120,126,140); $hint.TextAlign='MiddleRight'; $hint.BackColor=[System.Drawing.Color]::FromArgb(28,31,38)
  $bClose=New-Object System.Windows.Forms.Button; $bClose.Text=([char]0xE711); $bClose.Font=New-Object System.Drawing.Font("Segoe MDL2 Assets",10); $bClose.Width=36; $bClose.Height=28; $bClose.FlatStyle='Flat'; $bClose.FlatAppearance.BorderSize=0; $bClose.BackColor=[System.Drawing.Color]::FromArgb(24,26,32); $bClose.ForeColor=[System.Drawing.Color]::FromArgb(200,205,214); $bClose.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(210,70,70); $bClose.Cursor='Hand'; $bClose.Left=$f.Width-46; $bClose.Top=7; $bClose.Add_Click({ $f.Close() })
  $f.Controls.Add($head); $f.Controls.Add($hint); $f.Controls.Add($pad); $f.Controls.Add($bClose); $pad.BringToFront(); $bClose.BringToFront()
  $f.KeyPreview=$true; $f.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){ $f.Close() } })
  $head.Add_MouseDown({ $script:dragP=$_.Location; $script:dragOn=$true }); $head.Add_MouseUp({ $script:dragOn=$false }); $head.Add_MouseMove({ if($script:dragOn){ $f.Left += ($_.X-$script:dragP.X); $f.Top += ($_.Y-$script:dragP.Y) } })
  $f.Add_Shown({ try{ $body.SelectionStart=0; $body.SelectionLength=0 }catch{} })
  $script:helpPopup=$f; $f.Show()
}
$strip=New-Object System.Windows.Forms.Form
$strip.FormBorderStyle='None'; $strip.TopMost=$true; $strip.ShowInTaskbar=$false; $strip.StartPosition='Manual'; $strip.Width=560; $strip.Height=46; $strip.Opacity=0.97; $strip.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-14
Set-Round $strip 16
$strip.Add_Paint({ param($s,$e); Draw-Border $e.Graphics $s.ClientSize.Width $s.ClientSize.Height 16 ([System.Drawing.Color]::FromArgb(58,64,78)) })
$dot=New-Object System.Windows.Forms.Panel; $dot.Width=12; $dot.Height=12; $dot.Left=18; $dot.Top=[int](($strip.Height-12)/2); $dot.BackColor=[System.Drawing.Color]::FromArgb(120,130,145)
$dgp=New-Object System.Drawing.Drawing2D.GraphicsPath; $dgp.AddEllipse(0,0,12,12); $dot.Region=New-Object System.Drawing.Region($dgp)
$script:msg=New-Object System.Windows.Forms.Label; $script:msg.Left=40; $script:msg.Top=0; $script:msg.Width=344; $script:msg.Height=$strip.Height; $script:msg.ForeColor=[System.Drawing.Color]::FromArgb(236,239,244); $script:msg.Font=New-Object System.Drawing.Font("Segoe UI Semibold",10); $script:msg.TextAlign='MiddleLeft'; $script:msg.BackColor=[System.Drawing.Color]::FromArgb(24,26,32)
$tip=New-Object System.Windows.Forms.ToolTip; $tip.InitialDelay=350
function Mini($glyph,$fontName,$fsize,$x,$accent){ $b=New-Object System.Windows.Forms.Button; $b.Text=$glyph; $b.Left=$x; $b.Top=6; $b.Width=34; $b.Height=34; $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.Font=New-Object System.Drawing.Font($fontName,$fsize); $b.Cursor='Hand'; if($accent){ $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(56,120,236); $b.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(74,140,255); $b.FlatAppearance.MouseDownBackColor=[System.Drawing.Color]::FromArgb(44,104,214) } else { $b.ForeColor=[System.Drawing.Color]::FromArgb(222,227,235); $b.BackColor=[System.Drawing.Color]::FromArgb(34,37,46); $b.FlatAppearance.MouseOverBackColor=[System.Drawing.Color]::FromArgb(50,55,68); $b.FlatAppearance.MouseDownBackColor=[System.Drawing.Color]::FromArgb(40,44,54) }; return $b }
$mdl="Segoe MDL2 Assets"
$bPause=Mini ([char]0xE769) $mdl 12 392 $false
$bMute=Mini ([char]0xE767) $mdl 12 432 $false
$bHelp=Mini "?" "Segoe UI Semibold" 14 472 $true
$bX=Mini ([char]0xE711) $mdl 10 512 $false
foreach($bb in @($bPause,$bMute,$bHelp,$bX)){ Set-Round $bb 9 }
$tip.SetToolTip($bPause,"Pause coaching"); $tip.SetToolTip($bMute,"Mute coach voice"); $tip.SetToolTip($bHelp,"Get help right now"); $tip.SetToolTip($bX,"Close coach")
$speaker=New-Object System.Speech.Synthesis.SpeechSynthesizer; try{ $speaker.Rate=1 }catch{}; $sync.mute=$false
$strip.Controls.AddRange(@($script:msg,$dot,$bPause,$bMute,$bHelp,$bX)); $dot.BringToFront()
$script:msg.Text="Listening to the lesson..."
$script:seen=0; $script:lastFull=""
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($sync.isAnswer){
      if($r -ne "" -and $r -ne "OK"){ $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); $script:msg.Text="Answer ready - click to read"; $script:lastFull=$r; Show-HelpPopup $r; Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ try{ $speaker.SpeakAsyncCancelAll(); $speaker.SpeakAsync($r)|Out-Null }catch{} } }
    }
    elseif($r -eq "OK" -or $r -eq ""){ $dot.BackColor=[System.Drawing.Color]::FromArgb(76,180,120); $script:msg.Text=$(if($sync.isPaused){"Working - looks fine"}else{"On track"}) }
    else {
      $dot.BackColor=[System.Drawing.Color]::FromArgb(235,180,70); $script:msg.Text=$r; $script:lastFull=$r
      if($r -ne $sync.lastNudge){ Log-Watch $r $sync.lesson; if($sync.isPaused -and -not $sync.mute){ try{ $speaker.SpeakAsyncCancelAll(); $speaker.SpeakAsync($r)|Out-Null }catch{} } else { [System.Media.SystemSounds]::Asterisk.Play() } }
      $sync.lastNudge=$r
    }
  }
})
$bPause.Add_Click({ $sync.paused=-not $sync.paused; $bPause.Text=$(if($sync.paused){[char]0xE768}else{[char]0xE769}); $tip.SetToolTip($bPause,$(if($sync.paused){"Resume coaching"}else{"Pause coaching"})); if($sync.paused){ $script:msg.Text="Paused"; $dot.BackColor=[System.Drawing.Color]::FromArgb(120,130,145) } })
$bMute.Add_Click({ $sync.mute=-not $sync.mute; $bMute.Text=$(if($sync.mute){[char]0xE74F}else{[char]0xE767}); $tip.SetToolTip($bMute,$(if($sync.mute){"Unmute coach voice"}else{"Mute coach voice"})); if($sync.mute){ try{ $speaker.SpeakAsyncCancelAll() }catch{} } })
$bHelp.Add_Click({
  $script:msg.Text="Reading your Excel + the lesson (~30-40s)..."; $dot.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); [System.Windows.Forms.Application]::DoEvents()
  $ans=Get-Help; $script:lastFull=$ans
  Show-HelpPopup $ans; Log-Watch ("[help] "+$ans) ""
  if(-not $sync.mute){ try{ $speaker.SpeakAsyncCancelAll(); $speaker.SpeakAsync($ans)|Out-Null }catch{} }
  $script:msg.Text="On track"; $dot.BackColor=[System.Drawing.Color]::FromArgb(76,180,120); $script:seen=$sync.stamp
})
$bX.Add_Click({ $sync.stop=$true; $ui.Stop(); Start-Sleep -Milliseconds 300; Kill-FF; try{ $rs.Close() }catch{}; $strip.Close() })
$script:msg.Cursor='Hand'; $script:msg.Add_Click({ if($script:lastFull){ Show-HelpPopup $script:lastFull } })
$strip.Add_Shown({ $ui.Start() })
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close() }catch{}
