# coach.ps1 - Chat tutor that sees your whole screen, remembers your weak points, and streams replies.
#   Type a question + Enter -> it captures your full desktop (lesson video + your Excel), loads your
#   memory (Coaching/Weak Points.md + recent log), and answers live (streaming).
#   Buttons: Socratic | Just answer | Analyze session. Logs every turn to Coaching/.
# Test: coach.ps1 -Test -Mode socratic|answer|analyze   (streams to console, still logs)
param([switch]$Test, [ValidateSet('socratic','answer','analyze')][string]$Mode='socratic')

$Vault="C:\Users\jonah\Projects\excel-coach"; $Sessions=Join-Path $Vault "Sessions"; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"; $Model="gpt-5.5"
$SystemPrompt="You are a sharp Excel and financial-modeling tutor at Breaking Into Wall Street / investment-banking level. The screenshot shows the student's WHOLE desktop - usually the lesson (video/example) on one side and their own Excel on the other. Compare the two. Have a natural back-and-forth: nudge them to think when it helps, answer directly when they ask. Reference their known weak points by name when relevant. Keep replies concise unless they ask for more."
$AnalyzeSys="You are a financial-modeling study coach. Given a transcript of a Breaking Into Wall Street session (instructor + the student thinking aloud), produce: WEAK POINTS (where they were confused/guessed/erred - quote briefly), COVERED (key concepts/shortcuts), DRILLS (2-3 specific 5-10 min exercises). Be specific and concise."

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http
Add-Type 'using System; using System.Runtime.InteropServices; public class W4 { [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow(); [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r); }'
$script:history=@(); $script:png=Join-Path $env:TEMP "coach_shot.png"; $script:shotLeaf=$null; $script:brain=""

function Read-Key { $l=Get-Content $EnvFile | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1; return ($l -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"') }
function Capture-Desktop($path){
  $h=[W4]::GetForegroundWindow(); $r=New-Object W4+RECT; [void][W4]::GetWindowRect($h,[ref]$r); $w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
  if($w -gt 300 -and $ht -gt 200){
    $full=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($full); try{ $g.CopyFromScreen($r.Left,$r.Top,0,0,(New-Object System.Drawing.Size($w,$ht))) }catch{}; $g.Dispose()
  } else {
    $b=[System.Windows.Forms.SystemInformation]::VirtualScreen; $w=$b.Width; $ht=$b.Height
    $full=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($full); $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size); $g.Dispose()
  }
  $mw=2000.0; $s=[Math]::Min(1.0,$mw/$w); $nw=[int]($w*$s); $nh=[int]($ht*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g2=[System.Drawing.Graphics]::FromImage($sm); $g2.InterpolationMode='HighQualityBicubic'; $g2.DrawImage($full,0,0,$nw,$nh); $g2.Dispose()
  $sm.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $full.Dispose(); $sm.Dispose()
}
function W-Append($f,$s){ [IO.File]::AppendAllText($f,$s,(New-Object System.Text.UTF8Encoding($false))) }
function Save-Shot($t){ $d=Join-Path $Coaching "_shots"; New-Item -ItemType Directory -Force -Path $d|Out-Null; $leaf="coach-"+(Get-Date).ToString("yyyyMMdd-HHmmss")+".png"; Copy-Item $t (Join-Path $d $leaf) -Force; return $leaf }
function Log-Coaching($who,$text,$shotLeaf){
  New-Item -ItemType Directory -Force -Path $Coaching|Out-Null
  $date=(Get-Date).ToString("yyyy-MM-dd"); $time=(Get-Date).ToString("HH:mm"); $daily=Join-Path $Coaching ($date+".md")
  if(-not(Test-Path $daily)){ W-Append $daily ("# Coaching log - "+$date+"`n") }
  $e="`n### "+$time+"  ["+$who.ToUpper()+"]`n"; if($shotLeaf){ $e+="![["+$shotLeaf+"]]`n`n" }; $e+=$text+"`n`n---`n"; W-Append $daily $e
  if($who -eq 'analyze'){ $wp=Join-Path $Coaching "Weak Points.md"; if(-not(Test-Path $wp)){ W-Append $wp "# Weak Points (accumulating across sessions)`n" }; W-Append $wp ("`n## "+$date+" "+$time+"`n"+$text+"`n") }
}
function Load-Brain {
  $parts=@()
  $wp=Join-Path $Coaching "Weak Points.md"
  if(Test-Path $wp){ $t=(Get-Content $wp -Raw); if($t.Length -gt 2500){ $t=$t.Substring($t.Length-2500) }; $parts+=("KNOWN WEAK POINTS (recurring):`n"+$t) }
  $today=Join-Path $Coaching ((Get-Date).ToString("yyyy-MM-dd")+".md")
  if(Test-Path $today){ $t=(Get-Content $today -Raw); if($t.Length -gt 1400){ $t=$t.Substring($t.Length-1400) }; $parts+=("RECENT COACHING TODAY:`n"+$t) }
  if($parts.Count -eq 0){ return "" }
  return ("`n`nMEMORY - what you know about this student from past sessions (reference recurring weaknesses by name):`n"+($parts -join "`n`n"))
}
function Stream-Chat($messages,$onToken){
  if($Model -match '^gpt-5'){ $payload=@{ model=$Model; max_completion_tokens=3500; reasoning_effort='medium'; stream=$true; messages=$messages } | ConvertTo-Json -Depth 14 }
  else { $payload=@{ model=$Model; max_tokens=600; temperature=0; stream=$true; messages=$messages } | ConvertTo-Json -Depth 14 }
  $client=New-Object System.Net.Http.HttpClient; $client.Timeout=[TimeSpan]::FromSeconds(120)
  $req=New-Object System.Net.Http.HttpRequestMessage('Post','https://api.openai.com/v1/chat/completions')
  $req.Headers.Authorization=New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer',$script:key)
  $req.Content=New-Object System.Net.Http.StringContent($payload,[System.Text.Encoding]::UTF8,'application/json')
  $full=New-Object System.Text.StringBuilder
  try {
    $resp=$client.SendAsync($req,[System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    $rd=New-Object System.IO.StreamReader($resp.Content.ReadAsStreamAsync().Result)
    while(-not $rd.EndOfStream){
      $line=$rd.ReadLine()
      if($line -and $line.StartsWith('data: ')){
        $d=$line.Substring(6); if($d -eq '[DONE]'){ break }
        $o=$null; try{ $o=$d|ConvertFrom-Json }catch{}
        $tok=$o.choices[0].delta.content
        if($tok){ [void]$full.Append($tok); if($onToken){ & $onToken $tok } }
      }
    }
  } catch { $m="(stream error: "+$_.Exception.Message+")"; if($onToken){ & $onToken $m }; [void]$full.Append($m) } finally { $client.Dispose() }
  return $full.ToString()
}
function Chat($userText,$onToken){
  Capture-Desktop $script:png
  $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($script:png))
  $msgs=@(@{role="system";content=($SystemPrompt+$script:brain)})+$script:history+@(@{role="user";content=@(@{type="text";text=$userText},@{type="image_url";image_url=@{url=("data:image/png;base64,"+$b64);detail="high"}})})
  $r=Stream-Chat $msgs $onToken
  $script:history+=@{role="user";content=$userText}; $script:history+=@{role="assistant";content=$r}; $script:shotLeaf=Save-Shot $script:png
  return $r
}
function Analyze-Session {
  $md=Get-ChildItem $Sessions -Filter *.md -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $md){ return "No session transcript yet." }
  $c=Get-Content $md.FullName -Raw; if($c.Length -gt 30000){ $c=$c.Substring(0,30000) }
  $msgs=@(@{role="system";content=$AnalyzeSys},@{role="user";content=("Session: "+$md.Name+"`n`n"+$c)})
  return ("["+$md.Name+"]`n`n"+(Stream-Chat $msgs $null))
}

$script:key=Read-Key
if(-not $script:key -or $script:key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
$script:brain=Load-Brain

if($Test){
  Write-Host ("[memory loaded: "+$script:brain.Length+" chars]")
  if($Mode -eq 'analyze'){ $r=Analyze-Session; Log-Coaching 'analyze' $r $null; Write-Host $r }
  else {
    $q= if($Mode -eq 'answer'){"Look at my screen and tell me the next step."}else{"Coach me on my screen - flag the key thing and ask me one question."}
    $r=Chat $q { param($t) Write-Host -NoNewline $t }; Write-Host ""; Log-Coaching $Mode $r $script:shotLeaf
  }
  exit
}

# ---------------- Chat window ----------------
$cf=New-Object System.Windows.Forms.Form
$cf.Text="Coach"; $cf.FormBorderStyle='Sizable'; $cf.StartPosition='Manual'; $cf.TopMost=$true; $cf.ShowInTaskbar=$false
$cf.Width=500; $cf.Height=520; $cf.MinimumSize=New-Object System.Drawing.Size(380,360)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea; $cf.Left=$wa.Right-$cf.Width-20; $cf.Top=$wa.Bottom-$cf.Height-20
$cf.BackColor=[System.Drawing.Color]::FromArgb(22,24,30)
$script:title=New-Object System.Windows.Forms.Label
$script:title.Text="COACH - ask me anything (I see your whole screen + remember your weak points)"; $script:title.Dock='Top'; $script:title.Height=38
$script:title.ForeColor=[System.Drawing.Color]::FromArgb(120,200,255); $script:title.Font=New-Object System.Drawing.Font("Segoe UI",9,[System.Drawing.FontStyle]::Bold); $script:title.Padding='10,5,6,0'
$script:conv=New-Object System.Windows.Forms.TextBox
$script:conv.Multiline=$true; $script:conv.ReadOnly=$true; $script:conv.Dock='Fill'; $script:conv.BorderStyle='None'
$script:conv.BackColor=[System.Drawing.Color]::FromArgb(22,24,30); $script:conv.ForeColor=[System.Drawing.Color]::White; $script:conv.Font=New-Object System.Drawing.Font("Segoe UI",11); $script:conv.ScrollBars='Vertical'
$modePanel=New-Object System.Windows.Forms.Panel; $modePanel.Dock='Bottom'; $modePanel.Height=36; $modePanel.BackColor=[System.Drawing.Color]::FromArgb(16,18,22)
function New-Btn($t,$x){ $b=New-Object System.Windows.Forms.Button; $b.Text=$t; $b.Left=$x; $b.Top=5; $b.Width=140; $b.Height=26; $b.FlatStyle='Flat'; $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54); $b.FlatAppearance.BorderSize=0; $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b }
$bSoc=New-Btn "Socratic" 6; $bAns=New-Btn "Just answer" 154; $bAna=New-Btn "Analyze session" 314
$modePanel.Controls.AddRange(@($bSoc,$bAns,$bAna))
$inputPanel=New-Object System.Windows.Forms.Panel; $inputPanel.Dock='Bottom'; $inputPanel.Height=42; $inputPanel.BackColor=[System.Drawing.Color]::FromArgb(16,18,22)
$script:input=New-Object System.Windows.Forms.TextBox; $script:input.Dock='Fill'; $script:input.BorderStyle='FixedSingle'; $script:input.BackColor=[System.Drawing.Color]::FromArgb(34,38,48); $script:input.ForeColor=[System.Drawing.Color]::White; $script:input.Font=New-Object System.Drawing.Font("Segoe UI",11)
$bSend=New-Object System.Windows.Forms.Button; $bSend.Text="Send"; $bSend.Dock='Right'; $bSend.Width=70; $bSend.FlatStyle='Flat'; $bSend.ForeColor=[System.Drawing.Color]::White; $bSend.BackColor=[System.Drawing.Color]::FromArgb(60,110,180); $bSend.FlatAppearance.BorderSize=0
$inputPanel.Controls.Add($script:input); $inputPanel.Controls.Add($bSend)
$cf.Controls.Add($script:title); $cf.Controls.Add($inputPanel); $cf.Controls.Add($modePanel); $cf.Controls.Add($script:conv)

$script:streamTok={ param($t) $script:conv.AppendText((($t -replace "`r`n","`n") -replace "`n","`r`n")); [System.Windows.Forms.Application]::DoEvents() }
function Say($who,$text){ $t=($text -replace "`r`n","`n") -replace "`n","`r`n"; $script:conv.AppendText($who+": "+$t+"`r`n`r`n") }
function Send-Input {
  $u=$script:input.Text.Trim(); if(-not $u){ return }
  $script:input.Clear(); $script:conv.AppendText("You: "+$u+"`r`n`r`nCoach: ")
  $script:title.Text="Coach is thinking..."; [System.Windows.Forms.Application]::DoEvents()
  $r=Chat $u $script:streamTok; $script:conv.AppendText("`r`n`r`n"); Log-Coaching 'chat' $r $script:shotLeaf
  $script:title.Text="COACH - ask me anything (I see your whole screen + remember your weak points)"; $script:input.Focus()
}
function Quick($mode){
  $script:title.Text="Coach is thinking..."; [System.Windows.Forms.Application]::DoEvents()
  if($mode -eq 'analyze'){ $script:conv.AppendText("Coach (session analysis): "); $r=Analyze-Session; Say "" $r; Log-Coaching 'analyze' $r $null }
  else {
    $instr= if($mode -eq 'answer'){"Look at my whole screen and just tell me directly the correct answer or exact next step. Be concise."}else{"Coach me Socratically on my screen now: name what I'm doing, flag the key issue, ask me ONE question. Don't give the full answer."}
    $script:conv.AppendText("Coach: "); $r=Chat $instr $script:streamTok; $script:conv.AppendText("`r`n`r`n"); Log-Coaching $mode $r $script:shotLeaf
  }
  $script:title.Text="COACH - ask me anything (I see your whole screen + remember your weak points)"; $script:input.Focus()
}
$bSend.Add_Click({ Send-Input })
$script:input.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){ $_.SuppressKeyPress=$true; Send-Input } })
$bSoc.Add_Click({ Quick 'socratic' }); $bAns.Add_Click({ Quick 'answer' }); $bAna.Add_Click({ Quick 'analyze' })
$cf.Add_Shown({ if($script:brain){ Say "Coach" ("Loaded your memory - I know your weak points so far. Ask me anything, or hit a button.") }; $script:input.Focus() })
[void]$cf.ShowDialog()
