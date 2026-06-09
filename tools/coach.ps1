# coach.ps1 - Tap-to-coach. Captures your screen, asks a Socratic tutor, shows a popup.
# Run with -Test to print the answer to the console instead of a popup.
param([switch]$Test)

$Vault   = "C:\Users\jonah\Projects\excel-coach"
$EnvFile = Join-Path $Vault ".env"
$Model   = "gpt-4o"
$Sys = "You are a sharp Socratic Excel and financial-modeling tutor at Breaking Into Wall Street / investment-banking level. You are shown a screenshot of the student's screen. In 2 to 4 short sentences: (1) say what they appear to be doing, (2) flag the single most important mistake, risk, or improvement you can see, reading formulas and cells if visible, and (3) ask ONE pointed question that makes them think. Do NOT give the full answer outright. Be direct, specific, and brief."

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Read-Key {
  $line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
  return ($line -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"')
}

function Capture-Screen($path){
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

function Ask-Coach($key, $png){
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($png))
  $payload = @{ model=$Model; max_tokens=400; messages=@(
    @{ role="system"; content=$Sys },
    @{ role="user"; content=@(
      @{ type="text"; text="Here is my screen right now. Coach me." },
      @{ type="image_url"; image_url=@{ url=("data:image/png;base64,"+$b64) } }
    )}
  )} | ConvertTo-Json -Depth 12
  $bodyFile = Join-Path $env:TEMP "coach_body.json"
  [IO.File]::WriteAllText($bodyFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
  $resp = & curl.exe -s --max-time 120 "https://api.openai.com/v1/chat/completions" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -d "@$bodyFile"
  $j = $null; try { $j = $resp | ConvertFrom-Json } catch {}
  if($j.choices){ return [string]$j.choices[0].message.content }
  if($j.error){ return "Coach error: " + $j.error.message }
  return "Coach error: no response (check your connection)."
}

function Popup($text){
  $script:cf = New-Object System.Windows.Forms.Form
  $script:cf.Text="Coach"; $script:cf.FormBorderStyle='FixedToolWindow'; $script:cf.StartPosition='Manual'
  $script:cf.TopMost=$true; $script:cf.ShowInTaskbar=$false; $script:cf.Width=440; $script:cf.Height=270
  $wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $script:cf.Left=$wa.Right-$script:cf.Width-20; $script:cf.Top=$wa.Bottom-$script:cf.Height-20
  $script:cf.BackColor=[System.Drawing.Color]::FromArgb(22,24,30)
  $lbl=New-Object System.Windows.Forms.Label
  $lbl.Text="COACH"; $lbl.Dock='Top'; $lbl.Height=26; $lbl.ForeColor=[System.Drawing.Color]::FromArgb(120,200,255)
  $lbl.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $lbl.Padding='10,6,0,0'
  $tb=New-Object System.Windows.Forms.TextBox
  $tb.Multiline=$true; $tb.ReadOnly=$true; $tb.Dock='Fill'; $tb.BorderStyle='None'
  $tb.BackColor=[System.Drawing.Color]::FromArgb(22,24,30); $tb.ForeColor=[System.Drawing.Color]::White
  $tb.Font=New-Object System.Drawing.Font("Segoe UI",11); $tb.Text=$text; $tb.ScrollBars='Vertical'
  $hint=New-Object System.Windows.Forms.Label
  $hint.Text="Esc to close"; $hint.Dock='Bottom'; $hint.Height=20; $hint.ForeColor=[System.Drawing.Color]::Gray; $hint.Padding='10,0,0,0'
  $script:cf.Controls.Add($tb); $script:cf.Controls.Add($lbl); $script:cf.Controls.Add($hint)
  $script:cf.KeyPreview=$true
  $script:cf.Add_KeyDown({ if($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape){ $script:cf.Close() } })
  [void]$script:cf.ShowDialog()
}

$key = Read-Key
if(-not $key -or $key -like '*REPLACE_ME*'){ if($Test){ Write-Host "NO KEY" } else { Popup "No API key set in .env." }; exit }
$png = Join-Path $env:TEMP "coach_shot.png"
Capture-Screen $png
$answer = Ask-Coach $key $png
if($Test){ Write-Host "--- COACH ---"; Write-Host $answer } else { Popup $answer }
