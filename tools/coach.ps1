# coach.ps1 - Chat-based AI tutor that sees your screen. Logs everything into the Obsidian vault.
#   Type a question and press Enter -> it answers using your CURRENT screen + the conversation so far.
#   Buttons: Socratic (nudge me) | Just answer | Analyze session (weak points from last transcript)
#   Saves every turn to Coaching/<date>.md (+ screenshots); analyses also append Coaching/Weak Points.md
# Test:  coach.ps1 -Test -Mode socratic|answer|analyze   (single turn to console, still logs)
param([switch]$Test, [ValidateSet('socratic','answer','analyze')][string]$Mode='socratic')

$Vault    = "C:\Users\jonah\Projects\excel-coach"
$Sessions = Join-Path $Vault "Sessions"
$Coaching = Join-Path $Vault "Coaching"
$EnvFile  = Join-Path $Vault ".env"
$Model    = "gpt-4o"

$SystemPrompt = "You are a sharp, friendly Excel and financial-modeling tutor at Breaking Into Wall Street / investment-banking level. You can see the student's current screen in the latest image. Have a natural back-and-forth: answer their questions, and when they are working, help them learn - nudge them to think when that helps, but answer directly when they ask. Keep replies concise (a few sentences) unless they ask for more."
$AnalyzeSys  = "You are a financial-modeling study coach. You are given a transcript of a Breaking Into Wall Street study session that mixes the instructor's lesson with the student thinking aloud. Produce three short sections: WEAK POINTS - where the student was confused, guessed, made errors, or said they need to remember something (quote them briefly); COVERED - the key concepts/shortcuts taught; DRILLS - 2 or 3 specific 5-10 minute exercises. Be specific and concise."

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$script:history = @()
$script:png = Join-Path $env:TEMP "coach_shot.png"
$script:shotLeaf = $null

function Read-Key {
  $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
  return ($line -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"')
}
function Capture-Screen($path){
  $b=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp=New-Object System.Drawing.Bitmap $b.Width,$b.Height
  $g=[System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location,[System.Drawing.Point]::Empty,$b.Size)
  $bmp.Save($path,[System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
}
function W-Append($file,$s){ [IO.File]::AppendAllText($file,$s,(New-Object System.Text.UTF8Encoding($false))) }
function Save-Shot($tempPng){
  $d=Join-Path $Coaching "_shots"; New-Item -ItemType Directory -Force -Path $d | Out-Null
  $leaf="coach-"+(Get-Date).ToString("yyyyMMdd-HHmmss")+".png"
  Copy-Item $tempPng (Join-Path $d $leaf) -Force; return $leaf
}
function Log-Coaching($who,$text,$shotLeaf){
  New-Item -ItemType Directory -Force -Path $Coaching | Out-Null
  $date=(Get-Date).ToString("yyyy-MM-dd"); $time=(Get-Date).ToString("HH:mm")
  $daily=Join-Path $Coaching ($date+".md")
  if(-not(Test-Path $daily)){ W-Append $daily ("# Coaching log - "+$date+"`n") }
  $e="`n### "+$time+"  ["+$who.ToUpper()+"]`n"
  if($shotLeaf){ $e+="![["+$shotLeaf+"]]`n`n" }
  $e+=$text+"`n`n---`n"
  W-Append $daily $e
  if($who -eq 'analyze'){
    $wp=Join-Path $Coaching "Weak Points.md"
    if(-not(Test-Path $wp)){ W-Append $wp "# Weak Points (accumulating across sessions)`n" }
    W-Append $wp ("`n## "+$date+" "+$time+"`n"+$text+"`n")
  }
}
function Post-Json($payload){
  $bodyFile=Join-Path $env:TEMP "coach_body.json"
  [IO.File]::WriteAllText($bodyFile,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp = & curl.exe -s --max-time 120 "https://api.openai.com/v1/chat/completions" -H "Authorization: Bearer $script:key" -H "Content-Type: application/json" -d "@$bodyFile"
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ return [string]$j.choices[0].message.content }
  if($j.error){ return "Error: "+$j.error.message }
  return "Error: no response (check connection)."
}
function Chat($userText){
  $msgs = @(@{role="system";content=$SystemPrompt}) + $script:history
  Capture-Screen $script:png
  $script:shotLeaf = Save-Shot $script:png
  $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($script:png))
  $msgs += @{role="user";content=@(
    @{type="text";text=$userText},
    @{type="image_url";image_url=@{url=("data:image/png;base64,"+$b64)}}
  )}
  $payload=@{ model=$Model; max_tokens=500; messages=$msgs } | ConvertTo-Json -Depth 14
  $r = Post-Json $payload
  $script:history += @{role="user";content=$userText}
  $script:history += @{role="assistant";content=$r}
  return $r
}
function Analyze-Session {
  $md = Get-ChildItem $Sessions -Filter *.md -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $md){ return "No session transcript found yet. Record and transcribe a session first." }
  $content = Get-Content $md.FullName -Raw
  if($content.Length -gt 30000){ $content = $content.Substring(0,30000) }
  $payload=@{ model=$Model; max_tokens=700; messages=@(
    @{role="system";content=$AnalyzeSys},
    @{role="user";content=("Session file: "+$md.Name+"`n`n"+$content)}
  )} | ConvertTo-Json -Depth 8
  return ("[" + $md.Name + "]`n`n" + (Post-Json $payload))
}

$script:key = Read-Key
if(-not $script:key -or $script:key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }

if($Test){
  if($Mode -eq 'analyze'){ $r=Analyze-Session; Log-Coaching 'analyze' $r $null; Write-Host $r }
  else {
    $q = if($Mode -eq 'answer'){"Look at my screen and just tell me the next step."}else{"Coach me on my screen - flag the key thing and ask me one question."}
    $r = Chat $q; Log-Coaching $Mode $r $script:shotLeaf; Write-Host $r
  }
  exit
}

# ---------------- Chat window ----------------
$cf=New-Object System.Windows.Forms.Form
$cf.Text="Coach"; $cf.FormBorderStyle='Sizable'; $cf.StartPosition='Manual'
$cf.TopMost=$true; $cf.ShowInTaskbar=$false; $cf.Width=500; $cf.Height=520; $cf.MinimumSize=New-Object System.Drawing.Size(380,360)
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$cf.Left=$wa.Right-$cf.Width-20; $cf.Top=$wa.Bottom-$cf.Height-20
$cf.BackColor=[System.Drawing.Color]::FromArgb(22,24,30)

$script:title=New-Object System.Windows.Forms.Label
$script:title.Text="COACH - ask me anything about your screen"; $script:title.Dock='Top'; $script:title.Height=26
$script:title.ForeColor=[System.Drawing.Color]::FromArgb(120,200,255)
$script:title.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $script:title.Padding='10,5,0,0'

$script:conv=New-Object System.Windows.Forms.TextBox
$script:conv.Multiline=$true; $script:conv.ReadOnly=$true; $script:conv.Dock='Fill'; $script:conv.BorderStyle='None'
$script:conv.BackColor=[System.Drawing.Color]::FromArgb(22,24,30); $script:conv.ForeColor=[System.Drawing.Color]::White
$script:conv.Font=New-Object System.Drawing.Font("Segoe UI",11); $script:conv.ScrollBars='Vertical'

$modePanel=New-Object System.Windows.Forms.Panel
$modePanel.Dock='Bottom'; $modePanel.Height=36; $modePanel.BackColor=[System.Drawing.Color]::FromArgb(16,18,22)
function New-Btn($text,$x){
  $b=New-Object System.Windows.Forms.Button
  $b.Text=$text; $b.Left=$x; $b.Top=5; $b.Width=140; $b.Height=26; $b.FlatStyle='Flat'
  $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54)
  $b.FlatAppearance.BorderSize=0; $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b
}
$bSoc=New-Btn "Socratic" 6; $bAns=New-Btn "Just answer" 154; $bAna=New-Btn "Analyze session" 314
$modePanel.Controls.AddRange(@($bSoc,$bAns,$bAna))

$inputPanel=New-Object System.Windows.Forms.Panel
$inputPanel.Dock='Bottom'; $inputPanel.Height=42; $inputPanel.BackColor=[System.Drawing.Color]::FromArgb(16,18,22)
$script:input=New-Object System.Windows.Forms.TextBox
$script:input.Dock='Fill'; $script:input.BorderStyle='FixedSingle'
$script:input.BackColor=[System.Drawing.Color]::FromArgb(34,38,48); $script:input.ForeColor=[System.Drawing.Color]::White
$script:input.Font=New-Object System.Drawing.Font("Segoe UI",11)
$bSend=New-Object System.Windows.Forms.Button
$bSend.Text="Send"; $bSend.Dock='Right'; $bSend.Width=70; $bSend.FlatStyle='Flat'
$bSend.ForeColor=[System.Drawing.Color]::White; $bSend.BackColor=[System.Drawing.Color]::FromArgb(60,110,180); $bSend.FlatAppearance.BorderSize=0
$inputPanel.Controls.Add($script:input); $inputPanel.Controls.Add($bSend)

$cf.Controls.Add($script:title); $cf.Controls.Add($inputPanel); $cf.Controls.Add($modePanel); $cf.Controls.Add($script:conv)

function Say($who,$text){
  $t = ($text -replace "`r`n","`n") -replace "`n","`r`n"
  $script:conv.AppendText($who+": "+$t+"`r`n`r`n")
}
function Send-Input {
  $u=$script:input.Text.Trim(); if(-not $u){ return }
  $script:input.Clear(); Say "You" $u
  $script:title.Text="Coach is thinking..."; [System.Windows.Forms.Application]::DoEvents()
  $r = Chat $u; Say "Coach" $r; Log-Coaching 'chat' $r $script:shotLeaf
  $script:title.Text="COACH - ask me anything about your screen"; $script:input.Focus()
}
function Quick($mode){
  $script:title.Text="Coach is thinking..."; [System.Windows.Forms.Application]::DoEvents()
  if($mode -eq 'analyze'){ $r=Analyze-Session; Say "Coach (session analysis)" $r; Log-Coaching 'analyze' $r $null }
  else {
    $instr = if($mode -eq 'answer'){"Look at my screen and just tell me directly the correct answer or exact next step. Be concise."}else{"Coach me Socratically on my screen now: name what I'm doing, flag the key issue, and ask me ONE question. Don't give the full answer."}
    $r = Chat $instr; Say "Coach" $r; Log-Coaching $mode $r $script:shotLeaf
  }
  $script:title.Text="COACH - ask me anything about your screen"; $script:input.Focus()
}

$bSend.Add_Click({ Send-Input })
$script:input.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter){ $_.SuppressKeyPress=$true; Send-Input } })
$bSoc.Add_Click({ Quick 'socratic' })
$bAns.Add_Click({ Quick 'answer' })
$bAna.Add_Click({ Quick 'analyze' })
$cf.Add_Shown({ Quick $Mode; $script:input.Focus() })
[void]$cf.ShowDialog()
