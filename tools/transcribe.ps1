# transcribe.ps1 - robust, any-length audio transcription for the Excel Coach vault.
# - Compresses audio (mono 16k) so size is never an issue
# - Splits into sub-25MB chunks automatically
# - Transcribes each chunk via OpenAI Whisper with retries on network errors
# - Writes a clean transcript note into Sessions/
# Usage: transcribe.ps1 [-Audio "C:\path\to\recording.webm"]   (omit -Audio to use the latest recording)
param([string]$Audio)

$Vault    = Split-Path $PSScriptRoot -Parent
$Sessions = Join-Path $Vault "Sessions"
$EnvFile  = Join-Path $Vault ".env"
$Endpoint = "https://api.openai.com/v1/audio/transcriptions"
$Model    = "whisper-1"

function Fail($m){ Write-Host "`n[X] $m" -ForegroundColor Red; exit 1 }

# --- key ---
if(-not (Test-Path $EnvFile)){ Fail ".env not found at $EnvFile" }
$line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*OPENAI_API_KEY\s*=' } | Select-Object -First 1
$key  = ($line -replace '^\s*OPENAI_API_KEY\s*=\s*','').Trim().Trim('"')
if(-not $key -or $key -like '*REPLACE_ME*'){ Fail "Add your OpenAI key to $EnvFile (OPENAI_API_KEY=sk-...)" }

# --- ffmpeg ---
$ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source
if(-not $ff){ $ff = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
if(-not $ff){ Fail "ffmpeg not found" }

# --- input ---
if(-not $Audio -or -not (Test-Path $Audio)){
  $Audio = (Get-ChildItem $Vault -Recurse -Include *.webm,*.mp3,*.m4a,*.ogg,*.wav,*.mp4 -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
  if(-not $Audio){ Fail "No audio file found in the vault to transcribe." }
  Write-Host "Latest recording: $(Split-Path $Audio -Leaf)"
}
$base = [System.IO.Path]::GetFileNameWithoutExtension($Audio)
Write-Host "Transcribing: $base"

# --- compress + chunk ---
$work = Join-Path $env:TEMP ("xc_" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $work | Out-Null
$comp = Join-Path $work "audio.mp3"
Write-Host "Compressing..."
& $ff -hide_banner -loglevel error -i $Audio -ac 1 -ar 16000 -b:a 32k -y $comp
if(-not (Test-Path $comp)){ Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue; Fail "Compression failed (bad/locked audio file?)" }
& $ff -hide_banner -loglevel error -i $comp -f segment -segment_time 2400 -c copy -y (Join-Path $work "chunk_%03d.mp3")
$chunks = @(Get-ChildItem $work -Filter "chunk_*.mp3" | Sort-Object Name)
if($chunks.Count -eq 0){ $chunks = @(Get-Item $comp) }
Write-Host ("Chunks to transcribe: " + $chunks.Count)

function Transcribe-Chunk($path){
  for($i=1; $i -le 4; $i++){
    Write-Host ("  sending " + (Split-Path $path -Leaf) + " (try $i of 4)")
    $resp = & curl.exe -s --max-time 600 $Endpoint -H "Authorization: Bearer $key" -F "file=@$path" -F "model=$Model" -F "response_format=json"
    if($LASTEXITCODE -eq 0 -and $resp){
      $j = $null; try { $j = $resp | ConvertFrom-Json } catch {}
      if($j -and ($null -ne $j.text)){ return [string]$j.text }
      if($j -and $j.error){ Write-Host ("     API error: " + $j.error.message) -ForegroundColor Yellow }
    } else { Write-Host "     network error, retrying" -ForegroundColor Yellow }
    Start-Sleep -Seconds ([Math]::Min(30, 3*$i))
  }
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  Fail "Failed after 4 tries on $(Split-Path $path -Leaf). Check the key/connection and run again."
}

$parts = @()
foreach($c in $chunks){ $parts += (Transcribe-Chunk $c.FullName).Trim() }
$text = ($parts -join "`n`n").Trim()

# --- write note ---
$date = (Get-Date).ToString("yyyy-MM-dd")
$note = Join-Path $Sessions ($base + ".md")
$leaf = Split-Path $Audio -Leaf
$body = "---`ndate: $date`ntopic: `nsource: BIWS`ntype: session`n---`n`n# Session $base`n`n## Transcript`n`n$text`n`n## Audio`n![[$leaf]]`n"
Set-Content -LiteralPath $note -Value $body -Encoding UTF8
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "`n[OK] Transcript saved -> $note" -ForegroundColor Green
Write-Host ("Words: " + (($text -split '\s+') | Where-Object { $_ }).Count)
