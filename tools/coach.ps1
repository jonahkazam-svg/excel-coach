# coach.ps1 - Multi-mode AI tutor popup.
#   Socratic (flag & ask) | Just answer (tell me now) | Analyze session (weak points from last transcript)
#   Switch modes with the buttons in the popup.
# Test:  coach.ps1 -Test -Mode socratic|answer|analyze   (prints to console, no popup)
param([switch]$Test, [ValidateSet('socratic','answer','analyze')][string]$Mode='socratic')

$Vault    = "C:\Users\jonah\Projects\excel-coach"
$Sessions = Join-Path $Vault "Sessions"
$EnvFile  = Join-Path $Vault ".env"
$Model    = "gpt-4o"

$SocraticSys = "You are a sharp Socratic Excel and financial-modeling tutor at Breaking Into Wall Street / investment-banking level. You see the student's screen. In 2 to 4 short sentences: say what they appear to be doing, flag the single most important mistake/risk/improvement (read formulas if visible), and ask ONE pointed question that makes them think. Do NOT give the full answer. Be direct and brief."
$AnswerSys   = "You are an expert Excel and financial-modeling tutor (Breaking Into Wall Street level). You see the student's screen. Tell them directly and concisely the correct answer or the exact next step. If you see a mistake, state the fix and a one-line reason. Be specific and brief - no fluff, no Socratic questions."
$AnalyzeSys  = "You are a financial-modeling study coach. You are given a transcript of a Breaking Into Wall Street study session that mixes the instructor's lesson with the student thinking aloud. Produce three short sections: WEAK POINTS - where the student was confused, guessed, made errors, or said they need to remember something (quote them briefly); COVERED - the key concepts/shortcuts taught; DRILLS - 2 or 3 specific 5-10 minute exercises to fix the weak points. Be specific and concise."

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

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
function Post-Json($key,$payload){
  $bodyFile=Join-Path $env:TEMP "coach_body.json"
  [IO.File]::WriteAllText($bodyFile,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp = & curl.exe -s --max-time 120 "https://api.openai.com/v1/chat/completions" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d "@$bodyFile"
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ return [string]$j.choices[0].message.content }
  if($j.error){ return "Error: "+$j.error.message }
  return "Error: no response (check connection)."
}
function Ask-Vision($key,$png,$sys){
  $b64=[Convert]::ToBase64String([IO.File]::ReadAllBytes($png))
  $payload=@{ model=$Model; max_tokens=450; messages=@(
    @{role="system";content=$sys},
    @{role="user";content=@(
      @{type="text";text="Here is my screen right now."},
      @{type="image_url";image_url=@{url=("data:image/png;base64,"+$b64)}}
    )}
  )} | ConvertTo-Json -Depth 12
  return Post-Json $key $payload
}
function Analyze-Session($key){
  $md = Get-ChildItem $Sessions -Filter *.md -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $md){ return "No session transcript found yet. Record and transcribe a session first." }
  $content = Get-Content $md.FullName -Raw
  if($content.Length -gt 30000){ $content = $content.Substring(0,30000) }
  $payload=@{ model=$Model; max_tokens=700; messages=@(
    @{role="system";content=$AnalyzeSys},
    @{role="user";content=("Session file: "+$md.Name+"`n`n"+$content)}
  )} | ConvertTo-Json -Depth 8
  return ("[" + $md.Name + "]`n`n" + (Post-Json $key $payload))
}

$script:key = Read-Key
if(-not $script:key -or $script:key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }

if($Test){
  if($Mode -eq 'analyze'){ Write-Host (Analyze-Session $script:key) }
  else {
    $p=Join-Path $env:TEMP "coach_shot.png"; Capture-Screen $p
    $sys = if($Mode -eq 'answer'){$AnswerSys}else{$SocraticSys}
    Write-Host (Ask-Vision $script:key $p $sys)
  }
  exit
}

# --- Live popup ---
$script:png = Join-Path $env:TEMP "coach_shot.png"
Capture-Screen $script:png

$script:tb = New-Object System.Windows.Forms.TextBox
$script:title = New-Object System.Windows.Forms.Label

function Run-Mode($mode){
  if($mode -eq 'answer'){ $script:title.Text="COACH - Answer"; $script:tb.Text="Thinking..." }
  elseif($mode -eq 'analyze'){ $script:title.Text="COACH - Session analysis"; $script:tb.Text="Reading your last session..." }
  else { $script:title.Text="COACH - Socratic"; $script:tb.Text="Thinking..." }
  [System.Windows.Forms.Application]::DoEvents()
  if($mode -eq 'analyze'){ $script:tb.Text = Analyze-Session $script:key }
  elseif($mode -eq 'answer'){ $script:tb.Text = Ask-Vision $script:key $script:png $AnswerSys }
  else { $script:tb.Text = Ask-Vision $script:key $script:png $SocraticSys }
  $script:tb.Select(0,0); $script:tb.ScrollToCaret()
}

$cf=New-Object System.Windows.Forms.Form
$cf.Text="Coach"; $cf.FormBorderStyle='FixedToolWindow'; $cf.StartPosition='Manual'
$cf.TopMost=$true; $cf.ShowInTaskbar=$false; $cf.Width=470; $cf.Height=330
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$cf.Left=$wa.Right-$cf.Width-20; $cf.Top=$wa.Bottom-$cf.Height-20
$cf.BackColor=[System.Drawing.Color]::FromArgb(22,24,30)

$script:title.Text="COACH - Socratic"; $script:title.Dock='Top'; $script:title.Height=26
$script:title.ForeColor=[System.Drawing.Color]::FromArgb(120,200,255)
$script:title.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $script:title.Padding='10,6,0,0'

$script:tb.Multiline=$true; $script:tb.ReadOnly=$true; $script:tb.Dock='Fill'; $script:tb.BorderStyle='None'
$script:tb.BackColor=[System.Drawing.Color]::FromArgb(22,24,30); $script:tb.ForeColor=[System.Drawing.Color]::White
$script:tb.Font=New-Object System.Drawing.Font("Segoe UI",11); $script:tb.ScrollBars='Vertical'; $script:tb.Text="Reading your screen..."

$panel=New-Object System.Windows.Forms.Panel
$panel.Dock='Bottom'; $panel.Height=40; $panel.BackColor=[System.Drawing.Color]::FromArgb(16,18,22)
function New-Btn($text,$x){
  $b=New-Object System.Windows.Forms.Button
  $b.Text=$text; $b.Left=$x; $b.Top=6; $b.Width=140; $b.Height=28; $b.FlatStyle='Flat'
  $b.ForeColor=[System.Drawing.Color]::White; $b.BackColor=[System.Drawing.Color]::FromArgb(40,44,54)
  $b.FlatAppearance.BorderSize=0; $b.Font=New-Object System.Drawing.Font("Segoe UI",9); return $b
}
$bSoc=New-Btn "Socratic" 6
$bAns=New-Btn "Just answer" 154
$bAna=New-Btn "Analyze session" 314
$bSoc.Add_Click({ Run-Mode 'socratic' })
$bAns.Add_Click({ Run-Mode 'answer' })
$bAna.Add_Click({ Run-Mode 'analyze' })
$panel.Controls.AddRange(@($bSoc,$bAns,$bAna))

$cf.Controls.Add($script:tb); $cf.Controls.Add($panel); $cf.Controls.Add($script:title)
$cf.KeyPreview=$true
$cf.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){ $cf.Close() } })
$cf.Add_Shown({ Run-Mode $Mode })
[void]$cf.ShowDialog()
