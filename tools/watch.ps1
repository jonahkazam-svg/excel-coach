# watch.ps1 - Ambient live coach (async, non-freezing). Listens + watches.
#   A background thread continuously: records ~5s mic -> if silent => video PAUSED => active help on your Excel;
#   if playing => transcribes the instructor => knows your lesson position => nudges only if you've diverged.
#   The strip UI stays smooth (work runs off the UI thread). Overlay is invisible to screen recordings.
# Test: watch.ps1 -TestAsync   (spins the background worker for one check, prints, exits)
param([switch]$TestAsync, [int]$IntervalSec=35)

$Vault="C:\Users\jonah\Projects\excel-coach"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Win { [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint a); }
'@

function Read-EnvVal($name,$default){
  $l = Get-Content $EnvFile | Where-Object { $_ -match ("^\s*"+$name+"\s*=") } | Select-Object -First 1
  if($l){ return ($l -replace ("^\s*"+$name+"\s*=\s*"),'').Trim().Trim('"') } else { return $default }
}
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if(-not $ff){ $ff=(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

# shared state between UI thread and background worker
$sync = [hashtable]::Synchronized(@{})
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.status="starting"
$sync.text=""; $sync.lesson=""; $sync.isPaused=$false
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model="gpt-4o-mini"; $sync.interval=$IntervalSec
$sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.wav=Join-Path $env:TEMP "watch_audio.wav"
$sync.lastNudge=""
$sync.sys="You are an ambient tutor watching a student's full screen while they follow a Breaking Into Wall Street Excel lesson and rebuild it in their own Excel. You are given what the instructor is currently saying (or that the video is paused) and the screen. If the student is on track and nothing needs saying, reply EXACTLY: OK . Otherwise reply with ONE short, specific, actionable nudge: max 22 words, start with the fix."

$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (reference by name if you see one recurring): "+$bt }
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }

# ---- background worker (runs in its own runspace; uses only $sync) ----
$work = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
function Cap($path){
  $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $full=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($full); $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); $g.Dispose()
  $mw=1280.0; $s=[Math]::Min(1.0,$mw/$b.Width); $nw=[int]($b.Width*$s); $nh=[int]($b.Height*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g2=[System.Drawing.Graphics]::FromImage($sm)
  $g2.InterpolationMode='HighQualityBicubic'; $g2.DrawImage($full,0,0,$nw,$nh); $g2.Dispose()
  $sm.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $full.Dispose(); $sm.Dispose()
}
function Lvl($wav,$ff){
  if(-not (Test-Path $wav)){ return -100 }
  $e="$env:TEMP\watch_vol.txt"; & $ff -hide_banner -i $wav -af volumedetect -f null NUL 2>$e
  $ln=Get-Content $e | Where-Object { $_ -match 'mean_volume' } | Select-Object -First 1
  if($ln -match '(-?[0-9.]+) dB'){ return [double]$Matches[1] } else { return -100 }
}
function Trans($wav,$key){
  $r = & curl.exe -s --max-time 60 "https://api.openai.com/v1/audio/transcriptions" -H "Authorization: Bearer $key" -F "file=@$wav" -F "model=whisper-1" -F "response_format=json"
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}; if($j.text){ return ([string]$j.text).Trim() } else { return "" }
}
function VisionPost($payload,$key){
  $bf="$env:TEMP\watch_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r = & curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d "@$bf"
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}; if($j.choices){ return [string]$j.choices[0].message.content } else { return "OK" }
}
while(-not $sync.stop){
  if($sync.paused){ Start-Sleep -Milliseconds 300; continue }
  $sync.status="checking"
  if(Test-Path $sync.wav){ Remove-Item $sync.wav -Force -ErrorAction SilentlyContinue }
  & $sync.ff -hide_banner -loglevel error -f dshow -i ("audio="+$sync.mic) -t 5 -ac 1 -ar 16000 -y $sync.wav 2>$null
  $level = Lvl $sync.wav $sync.ff
  $paused = ($level -lt -45)
  $lesson = if($paused){ "" } else { Trans $sync.wav $sync.key }
  if(-not $paused -and $lesson.Length -lt 3){ $paused=$true; $lesson="" }
  Cap $sync.png
  $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($sync.png))
  if($paused){ $u="The lesson video is PAUSED (silence) - I'm doing the activity or stuck. Look at my Excel and the on-screen lesson example and tell me the specific next step or fix for exactly what I'm doing now." }
  else { $u="I'm watching the lesson. The instructor is currently saying: '" + $lesson + "'. Use it to know exactly where I am. Compare my Excel to the lesson; only nudge if I've clearly diverged." }
  if($sync.lastNudge -and $sync.lastNudge -ne "OK"){ $u += " You last told me: '" + $sync.lastNudge + "'. Don't repeat unless still unaddressed." }
  $payload=@{ model=$sync.model; max_tokens=80; messages=@(
    @{role="system";content=($sync.sys+$sync.brain)},
    @{role="user";content=@(@{type="text";text=$u},@{type="image_url";image_url=@{url=("data:image/png;base64,"+$b64)}})}
  )} | ConvertTo-Json -Depth 12
  $sync.text=(VisionPost $payload $sync.key).Trim(); $sync.lesson=$lesson; $sync.isPaused=$paused
  $sync.stamp=$sync.stamp+1; $sync.status="idle"
  $t=0.0; while($t -lt $sync.interval -and -not $sync.stop){ Start-Sleep -Milliseconds 300; $t+=0.3 }
}
'@

$rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync',$sync)
$psw=[powershell]::Create(); $psw.Runspace=$rs; [void]$psw.AddScript($work); [void]$psw.BeginInvoke()

if($TestAsync){
  $waited=0; while($sync.stamp -lt 1 -and $waited -lt 40){ Start-Sleep -Milliseconds 500; $waited+=0.5 }
  Write-Host ("stamp=" + $sync.stamp + " paused=" + $sync.isPaused + " lesson='" + $sync.lesson + "'")
  Write-Host ("Result: " + $sync.text)
  $sync.stop=$true; Start-Sleep -Milliseconds 800; $rs.Close(); exit
}

# ---- UI strip (stays smooth; just polls $sync) ----
function W-Append($file,$s){ [IO.File]::AppendAllText($file,$s,(New-Object System.Text.UTF8Encoding($false))) }
function Log-Watch($text,$lesson){
  New-Item -ItemType Directory -Force -Path $Coaching | Out-Null
  $date=(Get-Date).ToString("yyyy-MM-dd"); $time=(Get-Date).ToString("HH:mm")
  $daily=Join-Path $Coaching ($date+".md"); if(-not(Test-Path $daily)){ W-Append $daily ("# Coaching log - "+$date+"`n") }
  $ctx = if($lesson){ "_lesson: "+$lesson+"_`n`n" } else { "_(video paused / working)_`n`n" }
  W-Append $daily ("`n### "+$time+"  [WATCH]`n"+$ctx+$text+"`n`n---`n")
}
$strip=New-Object System.Windows.Forms.Form
$strip.FormBorderStyle='None'; $strip.TopMost=$true; $strip.ShowInTaskbar=$false; $strip.StartPosition='Manual'
$strip.Width=640; $strip.Height=54; $strip.Opacity=0.93; $strip.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-12
$status=New-Object System.Windows.Forms.Panel; $status.Dock='Left'; $status.Width=8; $status.BackColor=[System.Drawing.Color]::FromArgb(120,130,140)
$script:msg=New-Object System.Windows.Forms.Label
$script:msg.Dock='Fill'; $script:msg.ForeColor=[System.Drawing.Color]::White; $script:msg.Font=New-Object System.Drawing.Font("Segoe UI",10)
$script:msg.TextAlign='MiddleLeft'; $script:msg.Padding='12,0,0,0'; $script:msg.Text="Starting live coach..."
$btns=New-Object System.Windows.Forms.Panel; $btns.Dock='Right'; $btns.Width=180; $btns.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
function Mini($t,$x,$w){ $b=New-Object System.Windows.Forms.Button; $b.Text=$t; $b.Left=$x; $b.Top=12; $b.Width=$w; $b.Height=28; $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54); $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b }
$bPause=Mini "Pause" 6 70; $bAsk=Mini "Ask" 80 50; $bX=Mini "X" 134 40
$btns.Controls.AddRange(@($bPause,$bAsk,$bX))
$strip.Controls.Add($script:msg); $strip.Controls.Add($status); $strip.Controls.Add($btns)

$script:seen=0
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp
    $r=$sync.text
    if($r -eq "OK" -or $r -eq ""){ $status.BackColor=[System.Drawing.Color]::FromArgb(90,160,90); $script:msg.Text=$(if($sync.isPaused){"Working - looks fine"}else{"On track"}) }
    else {
      $status.BackColor=[System.Drawing.Color]::FromArgb(220,170,60); $script:msg.Text=$r
      if($r -ne $sync.lastNudge){ Log-Watch $r $sync.lesson; [System.Media.SystemSounds]::Asterisk.Play() }
      $sync.lastNudge=$r
    }
  } elseif($sync.status -eq "checking" -and $script:msg.Text -notmatch 'listening'){ }
})
$bPause.Add_Click({ $sync.paused = -not $sync.paused; $bPause.Text=$(if($sync.paused){"Resume"}else{"Pause"}); if($sync.paused){ $script:msg.Text="Paused"; $status.BackColor=[System.Drawing.Color]::FromArgb(120,130,140) } })
$bAsk.Add_Click({ Start-Process "C:\Users\jonah\Projects\excel-coach\tools\Coach me now.lnk" -ErrorAction SilentlyContinue })
$bX.Add_Click({ $sync.stop=$true; $ui.Stop(); Start-Sleep -Milliseconds 300; try{ $rs.Close() }catch{}; $strip.Close() })
$strip.Add_Shown({ try{ [Win]::SetWindowDisplayAffinity($strip.Handle, 0x11) | Out-Null }catch{}; $ui.Start() })
[void]$strip.ShowDialog()
try{ $sync.stop=$true; $rs.Close() }catch{}
