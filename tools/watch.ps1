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
public class Win { [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint a); }
'@
function Read-EnvVal($name,$default){ $l=Get-Content $EnvFile | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1; if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default } }
$ff=(Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if(-not $ff){ $ff=(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

$sync=[hashtable]::Synchronized(@{})
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model=(Read-EnvVal "WATCH_MODEL" "gpt-4o-mini"); $sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.segdir=Join-Path $env:TEMP "watch_seg"
$sync.sys="You are a precise, helpful live study tutor for a student doing a Breaking Into Wall Street finance course. Work out what the student is ACTUALLY doing on screen (a quiz, a video, an Excel model, reading, etc.) and help with THAT. Be accurate and conservative: only say something is wrong if you can CLEARLY see it - never guess or nitpick. Refer to things by their on-screen label/name, not guessed cell coordinates. When you do speak, be clear and explain briefly so they understand. If nothing genuinely needs saying, reply EXACTLY: OK."
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }
$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (call out by name if one recurs): "+$bt }

# start NONSTOP segmented audio capture
if(Test-Path $sync.segdir){ Remove-Item $sync.segdir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sync.segdir | Out-Null
$ffArgs='-hide_banner -loglevel error -f dshow -i audio="'+$sync.mic+'" -f segment -segment_time 10 -ac 1 -ar 16000 -reset_timestamps 1 -y "'+(Join-Path $sync.segdir "seg_%03d.wav")+'"'
$ffp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
$sync.ffpid=$ffp.Id

$work=@'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type 'using System; using System.Runtime.InteropServices; public class Win2 { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); }'
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
        $asked=((-not $sync.muteMe) -and ($txt -match '(?i)\bcoach\b'))
        if(-not $asked -and $txt){ [void]$rolling.Add($txt); while($rolling.Count -gt 3){ $rolling.RemoveAt(0) } }
        $lessonCtx=($rolling -join " "); $paused=($silent -or $lessonCtx.Length -lt 3)
        Cap $sync.png; $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png))
        if($asked){
          $u="The student spoke to you and asked: '"+$txt+"'. Look at their screen and answer clearly and helpfully in 1 to 4 sentences - actually explain it so they understand, like a good tutor. Use their screen and your memory of their weak points. If it was not a real question, reply EXACTLY: OK"
          $useModel="gpt-4o"; $det="high"; $maxtok=380
        } else {
          if($paused){ $u="The lesson video is paused - I'm working on something (a quiz, an exercise, my Excel). Look at what I'm actually doing and, ONLY if you can clearly see a real mistake or that I'm stuck, say specifically what's wrong or the next step (1-2 sentences). If it looks fine or you're unsure, reply EXACTLY: OK." }
          else { $u="Recent lesson audio: '"+$lessonCtx+"'. Look at what I'm doing on screen. ONLY if you can clearly see a real, specific mistake, point it out (1-2 sentences). If it looks fine or you're not sure, reply EXACTLY: OK - do not guess or nitpick." }
          if($sync.lastNudge -and $sync.lastNudge -ne 'OK'){ $u+=" You last told me: '"+$sync.lastNudge+"'. Don't repeat it." }
          $useModel=$sync.model; $det="auto"; $maxtok=120
        }
        $payload=@{ model=$useModel; max_tokens=$maxtok; temperature=0; messages=@(@{role='system';content=($sync.sys+$sync.brain)},@{role='user';content=@(@{type='text';text=$u},@{type='image_url';image_url=@{url=('data:image/png;base64,'+$b64);detail=$det}})}) } | ConvertTo-Json -Depth 12
        $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
        $vr=& curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
        $vj=$null; try{ $vj=$vr|ConvertFrom-Json }catch{}
        $sync.text=if($vj.choices){ ([string]$vj.choices[0].message.content).Trim() } else { "OK" }
        $sync.lesson=$lessonCtx; $sync.isPaused=$paused; $sync.isAnswer=$asked; $sync.stamp=$sync.stamp+1
        if($segs.Count -gt 6){ for($i=0;$i -lt ($segs.Count-6);$i++){ Remove-Item $segs[$i].FullName -Force -ErrorAction SilentlyContinue } }
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
$strip=New-Object System.Windows.Forms.Form
$strip.FormBorderStyle='None'; $strip.TopMost=$true; $strip.ShowInTaskbar=$false; $strip.StartPosition='Manual'; $strip.Width=720; $strip.Height=54; $strip.Opacity=0.93; $strip.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-12
$status=New-Object System.Windows.Forms.Panel; $status.Dock='Left'; $status.Width=8; $status.BackColor=[System.Drawing.Color]::FromArgb(120,130,140)
$script:msg=New-Object System.Windows.Forms.Label; $script:msg.Dock='Fill'; $script:msg.ForeColor=[System.Drawing.Color]::White; $script:msg.Font=New-Object System.Drawing.Font("Segoe UI",10); $script:msg.TextAlign='MiddleLeft'; $script:msg.Padding='12,0,0,0'; $script:msg.Text="Live coach starting (listening)..."
$btns=New-Object System.Windows.Forms.Panel; $btns.Dock='Right'; $btns.Width=294; $btns.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
function Mini($t,$x,$w){ $b=New-Object System.Windows.Forms.Button; $b.Text=$t; $b.Left=$x; $b.Top=12; $b.Width=$w; $b.Height=28; $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54); $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b }
$bPause=Mini "Pause" 6 52; $bMute=Mini "Mute" 60 50; $bMuteMe=Mini "Mute me" 112 66; $bAsk=Mini "Ask" 180 44; $bX=Mini "X" 226 34; $btns.Controls.AddRange(@($bPause,$bMute,$bMuteMe,$bAsk,$bX))
$speaker=New-Object System.Speech.Synthesis.SpeechSynthesizer; try{ $speaker.Rate=1 }catch{}; $sync.mute=$false
$strip.Controls.Add($script:msg); $strip.Controls.Add($status); $strip.Controls.Add($btns)
$script:seen=0
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($sync.isAnswer){
      if($r -ne "" -and $r -ne "OK"){ $status.BackColor=[System.Drawing.Color]::FromArgb(90,150,230); $script:msg.Text="A: "+$r; Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ try{ $speaker.SpeakAsyncCancelAll(); $speaker.SpeakAsync($r)|Out-Null }catch{} } }
    }
    elseif($r -eq "OK" -or $r -eq ""){ $status.BackColor=[System.Drawing.Color]::FromArgb(90,160,90); $script:msg.Text=$(if($sync.isPaused){"Working - looks fine"}else{"On track"}) }
    else {
      $status.BackColor=[System.Drawing.Color]::FromArgb(220,170,60); $script:msg.Text=$r
      if($r -ne $sync.lastNudge){ Log-Watch $r $sync.lesson; if($sync.isPaused -and -not $sync.mute){ try{ $speaker.SpeakAsyncCancelAll(); $speaker.SpeakAsync($r)|Out-Null }catch{} } else { [System.Media.SystemSounds]::Asterisk.Play() } }
      $sync.lastNudge=$r
    }
  }
})
$bPause.Add_Click({ $sync.paused=-not $sync.paused; $bPause.Text=$(if($sync.paused){"Resume"}else{"Pause"}); if($sync.paused){ $script:msg.Text="Paused"; $status.BackColor=[System.Drawing.Color]::FromArgb(120,130,140) } })
$bMute.Add_Click({ $sync.mute=-not $sync.mute; $bMute.Text=$(if($sync.mute){"Unmute"}else{"Mute"}); if($sync.mute){ try{ $speaker.SpeakAsyncCancelAll() }catch{} } })
$bMuteMe.Add_Click({ $sync.muteMe=-not $sync.muteMe; $bMuteMe.Text=$(if($sync.muteMe){"Unmute me"}else{"Mute me"}) })
$bAsk.Add_Click({ Start-Process "C:\Users\jonah\Projects\excel-coach\tools\Coach me now.lnk" -ErrorAction SilentlyContinue })
$bX.Add_Click({ $sync.stop=$true; $ui.Stop(); Start-Sleep -Milliseconds 300; Kill-FF; try{ $rs.Close() }catch{}; $strip.Close() })
$strip.Add_Shown({ try{ [Win]::SetWindowDisplayAffinity($strip.Handle,0x11)|Out-Null }catch{}; $ui.Start() })
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close() }catch{}
