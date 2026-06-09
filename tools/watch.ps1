# watch.ps1 - Ambient live coach. Watches your whole screen every ~40s while you follow a lesson
#   (video on one side) and rebuild it in Excel (other side). Pipes up with ONE short nudge only
#   when you diverge from the lesson or look stuck; stays quiet ("On track") otherwise.
#   Keep the video AND your Excel both visible so it can compare.
# Test: watch.ps1 -Once   (one check, prints to console, no overlay)
param([switch]$Once, [int]$IntervalSec=40)

$Vault="C:\Users\jonah\Projects\excel-coach"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"; $Model="gpt-4o"
$WatchSys = "You are an ambient tutor watching a student's full screen while they follow a Breaking Into Wall Street Excel lesson (usually a video on one side) and replicate it in their own Excel (other side). Compare what they are building to the lesson. If they made a mistake, diverged from the lesson, mislabeled or mislinked something, or look stuck, reply with ONE short, specific, actionable nudge: max 22 words, start with the fix. If they look on track, reply with EXACTLY: OK"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$script:png = Join-Path $env:TEMP "watch_shot.png"
$script:lastNudge = ""
$script:paused = $false

function Read-Key {
  $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
  return ($line -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"')
}
function W-Append($file,$s){ [IO.File]::AppendAllText($file,$s,(New-Object System.Text.UTF8Encoding($false))) }
function Log-Watch($text){
  New-Item -ItemType Directory -Force -Path $Coaching | Out-Null
  $date=(Get-Date).ToString("yyyy-MM-dd"); $time=(Get-Date).ToString("HH:mm")
  $daily=Join-Path $Coaching ($date+".md")
  if(-not(Test-Path $daily)){ W-Append $daily ("# Coaching log - "+$date+"`n") }
  W-Append $daily ("`n### "+$time+"  [WATCH]`n"+$text+"`n`n---`n")
}
function Capture-Desktop($path){
  $b=[System.Windows.Forms.SystemInformation]::VirtualScreen
  $full=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); $g.Dispose()
  $maxW=1600.0; $scale=[Math]::Min(1.0,$maxW/$b.Width)
  $nw=[int]($b.Width*$scale); $nh=[int]($b.Height*$scale)
  $small=New-Object System.Drawing.Bitmap $nw,$nh
  $g2=[System.Drawing.Graphics]::FromImage($small); $g2.InterpolationMode='HighQualityBicubic'
  $g2.DrawImage($full,0,0,$nw,$nh); $g2.Dispose()
  $small.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $full.Dispose(); $small.Dispose()
}
function Post-Json($payload){
  $bodyFile=Join-Path $env:TEMP "watch_body.json"
  [IO.File]::WriteAllText($bodyFile,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp = & curl.exe -s --max-time 90 "https://api.openai.com/v1/chat/completions" -H "Authorization: Bearer $script:key" -H "Content-Type: application/json" -d "@$bodyFile"
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ return [string]$j.choices[0].message.content }
  if($j.error){ return "OK" }
  return "OK"
}
function Check {
  Capture-Desktop $script:png
  $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($script:png))
  $u="Watch my screen and compare my Excel to the lesson."
  if($script:lastNudge -and $script:lastNudge -ne "OK"){ $u+=" You last told me: '"+$script:lastNudge+"'. Don't repeat it unless it's still unaddressed." }
  $payload=@{ model=$Model; max_tokens=80; messages=@(
    @{role="system";content=$WatchSys},
    @{role="user";content=@(@{type="text";text=$u},@{type="image_url";image_url=@{url=("data:image/png;base64,"+$b64)}})}
  )} | ConvertTo-Json -Depth 12
  return (Post-Json $payload).Trim()
}

$script:key = Read-Key
if(-not $script:key -or $script:key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }

if($Once){ Write-Host ("Result: " + (Check)); exit }

# ---------------- Coach strip overlay ----------------
$strip=New-Object System.Windows.Forms.Form
$strip.FormBorderStyle='None'; $strip.TopMost=$true; $strip.ShowInTaskbar=$false; $strip.StartPosition='Manual'
$strip.Width=620; $strip.Height=54; $strip.Opacity=0.93; $strip.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$strip.Left=$wa.Left + [int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-12

$status=New-Object System.Windows.Forms.Panel; $status.Dock='Left'; $status.Width=8; $status.BackColor=[System.Drawing.Color]::FromArgb(90,160,90)
$script:msg=New-Object System.Windows.Forms.Label
$script:msg.Dock='Fill'; $script:msg.ForeColor=[System.Drawing.Color]::White; $script:msg.Font=New-Object System.Drawing.Font("Segoe UI",10)
$script:msg.TextAlign='MiddleLeft'; $script:msg.Padding='12,0,0,0'; $script:msg.Text="Starting watch..."

$btns=New-Object System.Windows.Forms.Panel; $btns.Dock='Right'; $btns.Width=180; $btns.BackColor=[System.Drawing.Color]::FromArgb(20,22,28)
function Mini($t,$x,$w){
  $b=New-Object System.Windows.Forms.Button; $b.Text=$t; $b.Left=$x; $b.Top=12; $b.Width=$w; $b.Height=28
  $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.ForeColor=[System.Drawing.Color]::White
  $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54); $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b
}
$bPause=Mini "Pause" 6 70; $bAsk=Mini "Ask" 80 50; $bX=Mini "X" 134 40
$btns.Controls.AddRange(@($bPause,$bAsk,$bX))

$strip.Controls.Add($script:msg); $strip.Controls.Add($status); $strip.Controls.Add($btns)

$timer=New-Object System.Windows.Forms.Timer; $timer.Interval=[Math]::Max(15,$IntervalSec)*1000

function Do-Check {
  if($script:paused){ return }
  $script:msg.Text="checking..."; [System.Windows.Forms.Application]::DoEvents()
  $r = Check
  if($r -eq "OK" -or $r -eq ""){ $status.BackColor=[System.Drawing.Color]::FromArgb(90,160,90); $script:msg.Text="On track" }
  else {
    $status.BackColor=[System.Drawing.Color]::FromArgb(220,170,60); $script:msg.Text=$r
    if($r -ne $script:lastNudge){ Log-Watch $r; [System.Media.SystemSounds]::Asterisk.Play() }
  }
  $script:lastNudge=$r
}
$bPause.Add_Click({ $script:paused = -not $script:paused; $bPause.Text = if($script:paused){"Resume"}else{"Pause"}; if($script:paused){ $script:msg.Text="Paused" } })
$bAsk.Add_Click({ Start-Process "C:\Users\jonah\Projects\excel-coach\tools\Coach me now.lnk" -ErrorAction SilentlyContinue })
$bX.Add_Click({ $timer.Stop(); $strip.Close() })
$timer.Add_Tick({ Do-Check })
$strip.Add_Shown({ Do-Check; $timer.Start() })
[void]$strip.ShowDialog()
