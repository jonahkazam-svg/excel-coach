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
    if($sync.ttsMode -eq 'fish' -and $sync.fishKey){
      try{
        $fb=@{ text=$t; format="mp3" }
        if($sync.fishVoice){ $fb.reference_id=$sync.fishVoice }
        $fbody=$fb | ConvertTo-Json -Compress
        $fbf="$env:TEMP\xc_fish_body.json"; [IO.File]::WriteAllText($fbf,$fbody,(New-Object System.Text.UTF8Encoding($false)))
        $fraw="$env:TEMP\xc_fish_raw.mp3"; if(Test-Path $fraw){ Remove-Item $fraw -Force -ErrorAction SilentlyContinue }
        & curl.exe -s --max-time 30 "https://api.fish.audio/v1/tts" -H ("Authorization: Bearer "+$sync.fishKey) -H "Content-Type: application/json" -d ("@"+$fbf) -o $fraw 2>$null
        if((Test-Path $fraw) -and ((Get-Item $fraw).Length -gt 800)){
          $pcm="$env:TEMP\xc_tts_pcm.wav"; if(Test-Path $pcm){ Remove-Item $pcm -Force -ErrorAction SilentlyContinue }
          & $sync.ff -hide_banner -loglevel error -y -i $fraw -af ("volume="+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.##}",[double]$sync.ttsVol)) -ar 44100 -ac 2 -c:a pcm_s16le $pcm 2>$null
          if((Test-Path $pcm) -and ((Get-Item $pcm).Length -gt 1000) -and (-not $sync.mute)){ $cur=New-Object System.Media.SoundPlayer $pcm; try{ $cur.Play(); $spoke=$true; $sync.ttsBusyUntil=(Get-Date).AddSeconds(((Get-Item $pcm).Length/176400.0)+1.5) }catch{} }
        }
      }catch{}
    }
    if((-not $spoke) -and $sync.key){
      try{
        $body=@{ model="gpt-4o-mini-tts"; voice=$sync.ttsVoice; input=$t; response_format="wav"; instructions="Speak like a warm, confident investment-banking tutor: clear, encouraging, natural pacing." } | ConvertTo-Json -Compress
        $bf="$env:TEMP\xc_tts_body.json"; [IO.File]::WriteAllText($bf,$body,(New-Object System.Text.UTF8Encoding($false)))
        $raw="$env:TEMP\xc_tts_raw.wav"; if(Test-Path $raw){ Remove-Item $raw -Force -ErrorAction SilentlyContinue }
        & curl.exe -s --max-time 30 "https://api.openai.com/v1/audio/speech" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf) -o $raw 2>$null
        if((Test-Path $raw) -and ((Get-Item $raw).Length -gt 1000)){
          $pcm="$env:TEMP\xc_tts_pcm.wav"; if(Test-Path $pcm){ Remove-Item $pcm -Force -ErrorAction SilentlyContinue }
          & $sync.ff -hide_banner -loglevel error -y -i $raw -af ("volume="+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.##}",[double]$sync.ttsVol)) -ar 44100 -ac 2 -c:a pcm_s16le $pcm 2>$null
          if((Test-Path $pcm) -and ((Get-Item $pcm).Length -gt 1000) -and (-not $sync.mute)){ $cur=New-Object System.Media.SoundPlayer $pcm; try{ $cur.Play(); $spoke=$true; $sync.ttsBusyUntil=(Get-Date).AddSeconds(((Get-Item $pcm).Length/176400.0)+1.5) }catch{} }
        }
      }catch{}
    }
    if((-not $spoke) -and (-not $sync.mute)){ try{ $sp.Volume=[int]([math]::Max(0,[math]::Min(100,[double]$sync.ttsVol*100))) }catch{}; try{ $sp.SpeakAsync($t)|Out-Null; $sync.ttsBusyUntil=(Get-Date).AddSeconds(($t.Length/12.0)+1.5) }catch{} }
  }
  Start-Sleep -Milliseconds 150
}