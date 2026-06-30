# watch.ps1 - LIVE ambient coach. Continuously listens + watches (non-freezing).
#   A background ffmpeg records the lesson audio NONSTOP into 10s segments. A worker thread transcribes
#   each new segment the moment it's ready (rolling ~30s lesson context), checks your screen every ~10s,
#   detects PAUSE via silence (=> you're doing the activity/stuck => active help), and uses your memory
#   (Weak Points). Strip overlay stays smooth and is invisible to recordings.
# Test: watch.ps1 -TestAsync   (starts capture, processes one segment, prints, exits)
param([switch]$TestAsync)

# --- single-instance guard ---------------------------------------------------------
# Only one live coach at a time. A second launch (e.g. an accidental double-click of the
# shortcut) would stack a second overlay bar on top of the first. A named mutex is the
# race-free way to detect "already running"; it is held for the life of the process and
# the OS releases it automatically on exit, so a Repair/kill-then-relaunch can reclaim it.
# We wait briefly (not 0) so a relaunch where the old process is still dying acquires the
# mutex the instant it dies, instead of falsely bailing. (Skipped in -TestAsync.)
if(-not $TestAsync){
  $script:singleInst = New-Object System.Threading.Mutex($false, "Global\ExcelCoachWatchV4")   # v3 has its own mutex so it doesn't block / isn't blocked by a running v2
  $haveInst = $false
  try{ $haveInst = $script:singleInst.WaitOne(2500) }catch{ $haveInst = $true }  # abandoned mutex => prior instance died holding it => we may proceed
  if(-not $haveInst){ exit }   # another coach is already running -> bow out quietly
}

$Vault=Split-Path $PSScriptRoot -Parent; $Coaching=Join-Path $Vault "Coaching"; $EnvFile=Join-Path $Vault ".env"
try{ [Console]::OutputEncoding=[System.Text.Encoding]::UTF8; $OutputEncoding=[System.Text.Encoding]::UTF8 }catch{}
Add-Type 'using System; using System.Runtime.InteropServices; public class DpiBoot { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[void][DpiBoot]::SetProcessDPIAware()  # MUST run before any window/USER32 call or the process locks DPI-unaware (blurry 150 percent bitmap stretch)
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
if(-not $ff){ $bf=Join-Path (Split-Path $PSScriptRoot -Parent) "bin\ffmpeg.exe"; if(Test-Path $bf){ $ff=$bf } }
if(-not $ff){ $ff=(Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }

$sync=[hashtable]::Synchronized(@{})
$sync.stop=$false; $sync.paused=$false; $sync.stamp=0; $sync.text=""; $sync.lesson=""; $sync.isPaused=$false; $sync.lastNudge=""; $sync.muteMe=$false; $sync.isAnswer=$false; $sync.lessonlog=""; $sync.coaching=$Coaching; $sync.distillbuf=""; $sync.distillCount=0; $sync.micMode=$true; $sync.srcLabel=""; $sync.pcWanted=$false; $sync.ttsText=""; $sync.ttsStop=$false; $sync.ttsVoice=(Read-EnvVal "TTS_VOICE" "onyx"); $sync.ttsMode=(Read-EnvVal "TTS" "openai"); $sync.lastWb=""; $sync.muteSound=$false; $sync.sheetPurpose=""; $sync.typedAsk=""; $sync.typedDetail=$false; $sync.askLabel=""; $sync.ackPing=$false; $sync.ttsBusyUntil=(Get-Date).AddDays(-1); $sync.xlText=""; $sync.xlStamp=0; $sync.formReq=$false; $sync.formText=""; $sync.formStamp=0; $sync.lessonModel=""; $sync.teachOn=$true; $sync.demoActive=$false; $sync.cancelled=$false; $sync.streamText=""; $sync.streamStamp=0; $sync.sheetHasImg=$false; $sync.xlDismissed=[System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); $sync.undoStack=[System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.fishKey=(Read-EnvVal "FISH_API_KEY" ""); $sync.fishVoice=(Read-EnvVal "FISH_VOICE" ""); $sync.chatModel=(Read-EnvVal "CHAT_MODEL" "gpt-4o-mini"); $sync.chatOn=$false; $sync.lastXl=""
$sync.idReq=$false; $sync.idText=""; $sync.idStamp=0; $sync.handsOn=$true; $sync.company=""; $sync.companyCtx=""; $sync.formatOn=$true; $sync.guideOn=$false; $sync.ttsVol=1.0; $sync.micMute=$true; $sync.woActive=$false; $sync.wHB=(Get-Date)
if($sync.fishKey){ $sync.ttsMode="fish" }
$sync.key=(Read-EnvVal "OPENAI_API_KEY" ""); $sync.mic=(Read-EnvVal "MIC_DEVICE" "Microphone (Logitech BRIO)")
$sync.ff=$ff; $sync.model=(Read-EnvVal "WATCH_MODEL" "gpt-5.5"); $sync.fastModel=(Read-EnvVal "FAST_MODEL" "gpt-5-mini"); $sync.auditModel=(Read-EnvVal "AUDIT_MODEL" $sync.model); $sync.auditEff=(Read-EnvVal "AUDIT_EFFORT" "high"); $sync.png=Join-Path $env:TEMP "watch_shot.png"; $sync.segdir=Join-Path $env:TEMP "watch_seg"; $sync.tools=$PSScriptRoot
$sync.sys="You are a precise, helpful live study tutor for a student doing a Breaking Into Wall Street finance course. Work out what the student is ACTUALLY doing on screen (a quiz, a video, an Excel model, reading, etc.) and help with THAT. Be accurate and conservative: only say something is wrong if you are HIGHLY CONFIDENT and can CLEARLY see the error in the data in front of you - never guess, never invent a mistake, never nitpick. If you are not sure, or it could be a valid alternative method, a different order of steps, or just unfinished work, stay silent and reply EXACTLY: OK. Do NOT introduce or require any method, convention, formula, or step the student has not been shown in their lesson or sheet. Refer to things by their on-screen label/name, not guessed cell coordinates. When you do speak, be clear and explain briefly so they understand. If nothing genuinely needs saying, reply EXACTLY: OK. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
if(-not $sync.key -or $sync.key -like '*REPLACE_ME*'){ Write-Host "NO KEY in .env"; exit }
if(-not $sync.ff){ Write-Host "ffmpeg not found"; exit }
try{ . (Join-Path $PSScriptRoot "curriculum.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "deck.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "practice.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "runthrough.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "observed.ps1") }catch{}   # v3 observed curriculum (needs curriculum + runthrough loaded first)
try{ . (Join-Path $PSScriptRoot "perf.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "updater.ps1") }catch{}
try{ . (Join-Path $PSScriptRoot "setup.ps1") }catch{}
$wpf=Join-Path $Coaching "Weak Points.md"; $sync.brain=""
if(Test-Path $wpf){ $bt=(Get-Content $wpf -Raw); if($bt.Length -gt 1600){ $bt=$bt.Substring($bt.Length-1600) }; $sync.brain=" The student's known recurring weak points (call out by name if one recurs): "+$bt }
$spf=Join-Path $Coaching "Struggle Profile.md"
if(Test-Path $spf){ $spt=(Get-Content $spf -Raw); if($spt.Length -gt 1200){ $spt=$spt.Substring($spt.Length-1200) }; $sync.brain=$sync.brain+" The student's weakest categories and where to start (use this to prioritize help and to know where they struggle most): "+$spt.Trim() }
$kfb=Join-Path $Coaching "Knowledge.md"
if(Test-Path $kfb){ $kt=(Get-Content $kfb -Raw); if($kt.Length -gt 2000){ $kt=$kt.Substring($kt.Length-2000) }; $sync.brain=$sync.brain+" Concepts the student has already covered in lessons: "+$kt }
$WatchCur=(Read-EnvVal "WATCH_CURRICULUM" "1"); $sync.curr=""
if($WatchCur -eq "1"){ try{ . (Join-Path $PSScriptRoot "curriculum.ps1"); try{ Compact-File (Join-Path $Coaching "Mastery.md") 0 }catch{}; $sync.brain=$sync.brain+(Build-CurriculumBrain); $sync.curr=((Get-Curriculum | ForEach-Object { $_.id+": "+$_.topic }) -join "`n") }catch{} }
# Course scope gate: confine ALL live coaching/guiding/flagging to the in-scope
# domains from data\scope.json (read via Get-ScopeDomains). Empty/missing scope =
# no restriction (preserves prior behavior). $sync.scopeNote is shared with the
# Excel-watcher and guide threads (xlwork.ps1) so every path knows the boundary.
$sync.scopeNote=""
try{
  $scopeDoms=@(); if(Get-Command Get-ScopeDomains -ErrorAction SilentlyContinue){ $scopeDoms=@(Get-ScopeDomains) }
  if($scopeDoms.Count -gt 0){
    $sync.scopeNote=" SCOPE - this course currently covers ONLY these domains: "+($scopeDoms -join ", ")+". Teach, guide, flag, or answer ONLY within these domains. If the student is working on, watching, or asking about material OUTSIDE these domains (for example cost of equity, CAPM, beta, WACC, or a DCF when those domains are not listed above), do NOT coach or flag it - stay completely silent and reply EXACTLY: OK. Never walk the student through an out-of-scope workout or method."
  }
}catch{}
$sync.sys=$sync.sys+$sync.scopeNote

# audio source: microphone. (Capturing system/PC audio via loopback makes the tool
# look like spyware to Windows Defender, which hard-blocks it; the mic hears the lesson
# through the speakers anyway.) Override the device name with MIC_DEVICE in .env.
$sync.micMode=$true; $sync.srcLabel="Microphone ("+$sync.mic+")"
Write-Host ("Audio source: "+$sync.srcLabel)

# takeover: a new launch replaces any previous coach - kill stale watch.ps1
# instances and orphaned mic recorders so exactly one coach runs after any start
try{
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match '-File\b[^|;]*watch\.ps1' } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'watch_seg' } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
  # Also clear the previous coach's OWN orphaned WebView2 helpers (identified by our
  # UserDataFolder, xc4_wv2_data). A dead coach can leave these holding the UI data
  # folder, which makes the next launch come up blank / "won't run". Only ours are
  # matched, so other apps' WebView2 is untouched.
  Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match 'xc4_wv2_data' } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }
  Start-Sleep -Milliseconds 600
}catch{}

# start NONSTOP segmented audio capture
if(Test-Path $sync.segdir){ Remove-Item $sync.segdir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $sync.segdir | Out-Null
$ffArgs='-hide_banner -loglevel error -f dshow -i audio="'+$sync.mic+'" -y -map 0:a -f segment -segment_time 5 -ac 1 -ar 16000 -reset_timestamps 1 "'+(Join-Path $sync.segdir "seg_%03d.wav")+'" -map 0:a -f segment -segment_time 1 -segment_wrap 8 -ac 1 -ar 16000 -reset_timestamps 1 "'+(Join-Path $sync.segdir "lvl_%01d.wav")+'"'
$ffp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru
$sync.chime=Join-Path $env:TEMP "xc_chime.wav"; try{ & $ff -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=659:duration=0.10" -f lavfi -i "sine=frequency=988:duration=0.17" -filter_complex "[0]volume=0.15,afade=t=in:st=0:d=0.01,afade=t=out:st=0.05:d=0.05[a];[1]volume=0.17,afade=t=in:st=0:d=0.01,afade=t=out:st=0.10:d=0.07[b];[a][b]concat=n=2:v=0:a=1,aecho=0.8:0.9:40:0.2" -ar 44100 -ac 2 $sync.chime 2>$null }catch{}
$sync.ffpid=$ffp.Id

# Load workers by DOT-SOURCING their file PATH, not an in-memory string copy. A Defender
# folder exclusion can only suppress the AMSI script-scan when the script has a real file
# path to match; an in-memory AddScript(content) has none, so the exclusion would miss it.
# The $*Path vars are reused by the watchdog reloads below.
$workPath = (Join-Path $PSScriptRoot "workers\work.ps1")
$rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='STA'; $rs.ThreadOptions='ReuseThread'; $rs.Open()
$rs.SessionStateProxy.SetVariable('sync',$sync)
$psw=[powershell]::Create(); $psw.Runspace=$rs; [void]$psw.AddScript(". `"$workPath`""); [void]$psw.BeginInvoke()

# --- Excel watcher: dedicated thread that ONLY catches mistakes. Polls the live
# workbook via COM (no screenshots), checks the exact cells the moment they change,
# and is never blocked by transcription, asks, audits or distillation. ---
$xlWorkPath = (Join-Path $PSScriptRoot "workers\xlwork.ps1")
$rsX=[runspacefactory]::CreateRunspace(); $rsX.ApartmentState='STA'; $rsX.ThreadOptions='ReuseThread'; $rsX.Open()
$rsX.SessionStateProxy.SetVariable('sync',$sync)
$psx=[powershell]::Create(); $psx.Runspace=$rsX; [void]$psx.AddScript(". `"$xlWorkPath`""); [void]$psx.BeginInvoke()

# --- voice thread: OpenAI TTS (natural) with Windows-voice fallback; non-blocking ---
$ttsWorkPath = (Join-Path $PSScriptRoot "workers\ttswork.ps1")
$rsT=[runspacefactory]::CreateRunspace(); $rsT.ApartmentState='STA'; $rsT.Open(); $rsT.SessionStateProxy.SetVariable('sync',$sync)
$pst=[powershell]::Create(); $pst.Runspace=$rsT; [void]$pst.AddScript(". `"$ttsWorkPath`""); [void]$pst.BeginInvoke()

function Kill-FF { try{ Stop-Process -Id $sync.ffpid -Force -ErrorAction SilentlyContinue }catch{} }

# Live mic level: read the tail of the segment ffmpeg is CURRENTLY writing and
# return average amplitude 0..1 (-1 = unavailable). Lets the strip show that it
# hears the user the instant they speak, instead of after transcription.
function Get-MicLevel {
  try{
    $f=Get-ChildItem $sync.segdir -Filter "lvl_*.wav" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 9000 } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if(-not $f){ return -1 }
    if((((Get-Date)-$f.LastWriteTime).TotalSeconds) -gt 4){ return 0 }
    $fs=[IO.File]::Open($f.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    try{
      $len=$fs.Length
      $take=4800
      $off=$len-$take; if($off -lt 44){ $off=44 }; if(($off % 2) -eq 1){ $off=$off-1 }
      [void]$fs.Seek($off,[IO.SeekOrigin]::Begin)
      $buf=New-Object byte[] $take
      $read=$fs.Read($buf,0,$take)
      if($read -lt 200){ return 0 }
      $sum=0.0; $cnt=0
      for($i=0;$i -lt ($read-1);$i+=4){ $v=[BitConverter]::ToInt16($buf,$i); $sum+=[Math]::Abs([double]$v); $cnt++ }
      if($cnt -eq 0){ return 0 }
      return [Math]::Min(1.0,($sum/$cnt)/3000.0)
    } finally { $fs.Close() }
  }catch{ return -1 }
}

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
function ColLetter($n){ $r=""; do { $n--; $r=[string][char]([int][char]'A'+($n%26))+$r; $n=[int][math]::Floor($n/26) } while($n -gt 0); return $r }
function Read-ExcelLive {
  $xl=$null; try { $xl=[System.Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") } catch { return $null }
  if(-not $xl){ return $null }
  $out=$null
  try {
    $wb=$null; if(Get-Command Get-XlBook -ErrorAction SilentlyContinue){ $wb=Get-XlBook $xl } else { $wb=$xl.ActiveWorkbook }; if(-not $wb){ return $null }
    $sh=$wb.ActiveSheet; $ur=$sh.UsedRange
    $rows=[int]$ur.Rows.Count; $cols=[int]$ur.Columns.Count; $r0=[int]$ur.Row; $c0=[int]$ur.Column
    $rr=[Math]::Min($rows,400); $cc=[Math]::Min($cols,80); if($rr -lt $rows -or $cc -lt $cols){ $ur=$ur.Resize($rr,$cc) }; $rows=$rr; $cols=$cc
    $act=""; $sel=""; try{ $act=$xl.ActiveCell.Address($false,$false) }catch{}; try{ $sel=$xl.Selection.Address($false,$false) }catch{}
    $sb=New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("Workbook '"+$wb.Name+"' sheet '"+$sh.Name+"'. Active cell "+$act+", selection "+$sel+".")
    [void]$sb.AppendLine("Non-empty cells (ADDRESS = value   [formula if any]):")
    $n=0; $cap=300
    if($rows*$cols -eq 1){
      $v=$ur.Value2; $fm=[string]$ur.Formula; $addr=(ColLetter $c0)+$r0
      if($null -ne $v -or $fm){ $ln=$addr+" = "+([string]$v); if($fm.StartsWith("=")){ $ln+="   "+$fm }; [void]$sb.AppendLine($ln); $n=1 }
    } else {
      $vals=$ur.Value2; $forms=$ur.Formula
      for($i=1;$i -le $rows -and $n -lt $cap;$i++){ for($j=1;$j -le $cols -and $n -lt $cap;$j++){
        $v=$vals.GetValue($i,$j); $fm=$forms.GetValue($i,$j)
        if($null -eq $v -and [string]::IsNullOrEmpty([string]$fm)){ continue }
        $addr=(ColLetter ($c0+$j-1))+($r0+$i-1)
        $vs=if($v -is [double]){ $v.ToString("0.######") }else{ [string]$v }
        $ln=$addr+" = "+$vs; if(($fm -is [string]) -and $fm.StartsWith("=")){ $ln+="   "+$fm }
        [void]$sb.AppendLine($ln); $n++
      }}
      if($n -ge $cap){ [void]$sb.AppendLine("...(more cells not shown)") }
    }
    $out=$sb.ToString()
  } catch { $out=$null } finally { try{ [System.Runtime.InteropServices.Marshal]::ReleaseComObject($xl)|Out-Null }catch{} }
  return $out
}
function Add-Note {
  $xl=$null; if(Get-Command Read-ExcelLive -ErrorAction SilentlyContinue){ try{ $xl=Read-ExcelLive }catch{} }
  $lesson=""; if($sync.lessonlog){ $lesson=$sync.lessonlog; if($lesson.Length -gt 1500){ $lesson=$lesson.Substring($lesson.Length-1500) } }
  $u="The student pressed NOTE to flag what they are doing right now as important to remember and come back to for practice. Write a concise study note in markdown: a '## ' one-line title naming the topic/skill, then 2-4 bullets - what they were working on, the key concept or formula, and exactly what to practice when they return. Use their real cells/values if provided. Be specific and useful."
  $content=@(@{type='text';text=$u})
  if($lesson){ $content+=@{type='text';text=("Recent lesson context: "+$lesson)} }
  if($xl){ $content+=@{type='text';text=("Their live Excel right now:`n"+$xl)} }
  $sysN="You write concise, specific study notes for a finance/Excel student preparing for an investment-banking fellowship."
  $msgs=@(@{role='system';content=($sysN+$sync.brain)},@{role='user';content=$content})
  $payload=@{ model="gpt-4o-mini"; max_tokens=380; temperature=0.2; messages=$msgs } | ConvertTo-Json -Depth 12
  $bf="$env:TEMP\xc_note.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  $note="## Flagged for review`r`n- Revisit what you were working on here."
  if($j.choices){ $note=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $note=Clean-Answer $note } }
  $nf=Join-Path $Coaching "Notes.md"
  if(-not(Test-Path $nf)){ [IO.File]::AppendAllText($nf,"# Notes - things I flagged to revisit and practice`r`n",(New-Object System.Text.UTF8Encoding($false))) }
  [IO.File]::AppendAllText($nf,"`r`n### "+(Get-Date).ToString("yyyy-MM-dd HH:mm")+"`r`n"+$note+"`r`n",(New-Object System.Text.UTF8Encoding($false)))
  return $note
}
function Get-Help($question,$detail){
  $xlData=Read-ExcelLive
  $ex=Cap-Win "EXCEL"; $co=Cap-Win "chrome"; if(-not $co){ $co=Cap-Win "msedge" }; if(-not $co){ $co=Cap-Win "firefox" }
  if(-not $ex -and -not $co -and -not $xlData){ return "Couldn't find your Excel or browser window to read." }
  $sysH="You are a sharp finance and Excel tutor (Breaking Into Wall Street level). The student follows a course and rebuilds it in Excel. You may be given: the EXACT live contents of their Excel (every non-empty cell's address, value and formula, read straight from the workbook), an image of their Excel, and/or an image of the course/lesson. When the exact Excel data is present, treat it as the ground truth for ALL cell references, values and formulas - never guess a cell address from the image. METHOD for getting it right: (1) first read the exact question or task carefully and be sure you understand precisely what is being asked; (2) work it out step by step using the actual cell values and formulas; (3) double-check your arithmetic and logic; (4) then give the correct answer with a brief clear explanation, citing exact cell addresses (e.g. C39). If there is a quiz/question, work out the correct answer and, if it is multiple choice, state exactly which option to pick. If it is an Excel exercise, give the specific next step or fix and the exact cell(s) and formula to use. If the student typed a specific question, answer THAT directly. Accuracy above all - if you are not sure, say what you would check rather than guessing. Format your answer cleanly: a '## ' header when it helps, '**bold**' for key terms and the final answer, '- ' bullets for lists, numbered steps when there is an order, and write numbers with thousands separators like 6,550.0. Well-structured and easy to read."
  $uh=if($question){ "The student asks: "+$question }else{ "Help me with my work right now." }; if($sync.lessonlog){ $uh+=" (What the instructor has recently been teaching: '"+$sync.lessonlog+"'.)" }
  $uh+=$(if($detail){ " Explain in detail: the full reasoning, the steps, and why - take the space you need." }else{ " Keep it SHORT and useful: lead with the direct answer or the exact fix in 1 to 3 short sentences (a tiny list only if truly needed). Do not over-explain or pad - I can ask to explain in detail if I want." })
  $content=@(@{type='text';text=$uh})
  if($xlData){ $content+=@{type='text';text=("[EXACT live data from MY Excel - authoritative, use these cell addresses/values/formulas; do not guess cells from the image]:`n"+$xlData)} }
  if($sync.sheetPurpose){ $content+=@{type='text';text=("What this practice sheet is for (already understood): "+$sync.sheetPurpose)} }
  $content+=@{type='text';text="Identify the SPECIFIC skill the lesson is teaching and what I am trying to BUILD in my Excel, then connect them: cite the exact cell/formula from the data above (never a guessed cell) and give the precise next step toward that goal."}
  if($ex){ $content+=@{type='text';text='[Image: MY Excel sheet (visual context only)]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$ex);detail='high'}} }
  if($co){ $content+=@{type='text';text='[Image: the course / lesson]'}; $content+=@{type='image_url';image_url=@{url=('data:image/png;base64,'+$co);detail='high'}} }
  $msgs=@(@{role='system';content=($sysH+$sync.brain)},@{role='user';content=$content})
  if($sync.model -match '^gpt-5'){ $payload=@{ model=$sync.model; max_completion_tokens=$(if($detail){3500}else{900}); reasoning_effort='medium'; messages=$msgs } | ConvertTo-Json -Depth 14 }
  else { $payload=@{ model=$sync.model; max_tokens=700; temperature=0; messages=$msgs } | ConvertTo-Json -Depth 14 }
  $bf="$env:TEMP\help_body.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $resp=& curl.exe -s --max-time 150 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$resp|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a } elseif($j.error){ return "Error: "+$j.error.message } else { return "No response (check connection)." }
}
function Set-Round($ctl,$rad){ $d=$rad*2; $w=$ctl.Width; $h=$ctl.Height; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $ctl.Region=New-Object System.Drawing.Region($gp) }
function Draw-Border($g,$w,$h,$rad,$col){ $g.SmoothingMode='AntiAlias'; $pen=New-Object System.Drawing.Pen($col,1); $d=$rad*2; $gp=New-Object System.Drawing.Drawing2D.GraphicsPath; $gp.AddArc(0,0,$d,$d,180,90); $gp.AddArc($w-$d-1,0,$d,$d,270,90); $gp.AddArc($w-$d-1,$h-$d-1,$d,$d,0,90); $gp.AddArc(0,$h-$d-1,$d,$d,90,90); $gp.CloseAllFigures(); $g.DrawPath($pen,$gp); $pen.Dispose(); $gp.Dispose() }
# ---- Liquid-glass UI v4: WebView2 surfaces (tools/ui/strip.html + panel.html, snipzy liquid glass) over Win11 acrylic ----
Add-Type @'
using System; using System.Runtime.InteropServices;
public class GlassW {
  [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int l; public int r; public int t; public int b; }
  [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
  [DllImport("dwmapi.dll")] public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS m);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static int Backdrop(IntPtr hwnd, int type){
    MARGINS m = new MARGINS(); m.l = -1; m.r = -1; m.t = -1; m.b = -1;
    DwmExtendFrameIntoClientArea(hwnd, ref m);
    int dark = 1; DwmSetWindowAttribute(hwnd, 20, ref dark, 4);
    int r = 1; DwmSetWindowAttribute(hwnd, 33, ref r, 4);
    return 0;
  }
}
'@
[void][GlassW]::SetProcessDPIAware()
$gd=[System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:S=$gd.DpiX/96.0; $gd.Dispose()
function Px($v){ return [int][math]::Round($v*$script:S) }
function Glass-On($f0){ $hr=[GlassW]::Backdrop($f0.Handle,3); if($hr -ne 0){ $f0.BackColor=[System.Drawing.Color]::FromArgb(244,246,249) } }
$wvDir=Join-Path $PSScriptRoot "webview2"
try{
  Add-Type -Path (Join-Path $wvDir "Microsoft.Web.WebView2.Core.dll")
  Add-Type -Path (Join-Path $wvDir "Microsoft.Web.WebView2.WinForms.dll")
}catch{ Write-Host ("WebView2 SDK load failed: "+$_.Exception.Message); exit }
$uiDir=Join-Path $PSScriptRoot "ui"
$script:stripUrl="file:///"+((Join-Path $uiDir "strip.html") -replace '\\','/')
$script:panelUrl="file:///"+((Join-Path $uiDir "panel.html") -replace '\\','/')
function BoolJs($b){ if($b){ return 'true' } else { return 'false' } }
function JS($wv,$code){ try{ if($wv -and $wv.CoreWebView2){ [void]$wv.CoreWebView2.ExecuteScriptAsync($code) } }catch{} }
function New-GlassWebForm($w,$h){
  $f=New-Object System.Windows.Forms.Form
  $f.FormBorderStyle='None'; $f.TopMost=$true; $f.ShowInTaskbar=$false; $f.StartPosition='Manual'; $f.Width=$w; $f.Height=$h; $f.BackColor=[System.Drawing.Color]::Black
  $wv=New-Object Microsoft.Web.WebView2.WinForms.WebView2
  $cp=New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
  $cp.UserDataFolder=Join-Path $env:TEMP "xc4_wv2_data"
  $wv.CreationProperties=$cp
  $wv.DefaultBackgroundColor=[System.Drawing.Color]::Transparent
  $wv.Dock='Fill'
  $f.Controls.Add($wv)
  return @{f=$f;wv=$wv}
}
function Tune-WebView($wv){
  try{
    $st=$wv.CoreWebView2.Settings
    $st.AreDefaultContextMenusEnabled=$false; $st.IsZoomControlEnabled=$false; $st.AreDevToolsEnabled=$false; $st.IsStatusBarEnabled=$false
  }catch{}
}
# ---- persisted strip position: remember where the user last dragged the pill so it
# reopens there every launch (instead of snapping back to screen center each time) ----
function Strip-PosFile { return (Join-Path $env:APPDATA 'ExcelCoach\strip.txt') }
function Load-StripPos { try{ $f=(Strip-PosFile); if(Test-Path $f){ $v=([string](Get-Content $f -Raw)).Trim(); $n=0; if([int]::TryParse($v,[ref]$n)){ return $n } } }catch{}; return $null }
function Save-StripPos($x){ try{ $d=Split-Path (Strip-PosFile) -Parent; if(-not(Test-Path $d)){ New-Item -ItemType Directory -Force -Path $d | Out-Null }; [IO.File]::WriteAllText((Strip-PosFile),[string][int]$x,(New-Object System.Text.UTF8Encoding($false))) }catch{} }
# ---- persisted panel size: remember the size the user dragged the big panel to (device px) ----
function Panel-SizeFile { return (Join-Path $env:APPDATA 'ExcelCoach\panelsize.txt') }
function Load-PanelSize { try{ $f=(Panel-SizeFile); if(Test-Path $f){ $p=(([string](Get-Content $f -Raw)).Trim()) -split ','; if($p.Count -eq 2){ $w=0;$h=0; if([int]::TryParse($p[0].Trim(),[ref]$w) -and [int]::TryParse($p[1].Trim(),[ref]$h)){ return @{ w=$w; h=$h } } } } }catch{}; return $null }
function Save-PanelSize($w,$h){ try{ $d=Split-Path (Panel-SizeFile) -Parent; if(-not(Test-Path $d)){ New-Item -ItemType Directory -Force -Path $d | Out-Null }; [IO.File]::WriteAllText((Panel-SizeFile),([string][int]$w+','+[string][int]$h),(New-Object System.Text.UTF8Encoding($false))) }catch{} }
# ---- state ----
$script:collapsed=$true; $script:stripReady=$false; $script:panelReady=$false; $script:pendingAns=$null; $script:pendingLoad=$false; $script:pendingExercise=$null
$script:statusText=""; $script:dotState=""; $script:lastTimer=""; $script:t0=(Get-Date); $script:lastXWdog=(Get-Date); $script:curIssue=0; $script:pracList=@(); $script:pracIdx=0; $script:cardHelpBusy=$false; $script:rtCur=$null; $script:woActive=$false; $script:woBusy=$false; $script:woIdx=0; $script:woSeq=0; $script:woNext=$null; $script:woLast=''; $script:rtSession=$false; $script:userLeft=(Load-StripPos); $script:lastSavedLeft=$script:userLeft; $script:woLastResult=$null; $script:woLastCorrect=$false; $script:woConcept=''; $script:woRung=1; $script:woRungMiss=0; $script:woLadderTop=3; $script:woPendingLadder=$null; $script:woConceptMiss=0; $script:woRecent=@(); $script:woMissKind=''
$script:seen=0; $script:seenStream=0; $script:lastFull=""; $script:idle=$true; $script:baseStatus="Listening to the lesson"; $script:ffFails=0; $script:ffLastTry=(Get-Date); $script:lastHelpQ=""; $script:askBusy=$false; $script:lastActive=(Get-Date); $script:busySince=$null; $script:busyLabel="Thinking"; $script:seenXl=0; $script:xlNudgeShown=$false; $script:seenForm=0; $script:fxCache=@{}; $script:seenId=0; $script:idCache=@{ key=""; json="" }; $script:idPendingKey=""; $script:heardAt=$null; $script:listenState=$false
# ---- forms ----
$mkS=New-GlassWebForm (Px 280) (Px 40)
$strip=$mkS.f; $wvS=$mkS.wv; $script:strip=$strip; $script:wvS=$wvS
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$strip.Left=$wa.Left+[int](($wa.Width-$strip.Width)/2); $strip.Top=$wa.Bottom-$strip.Height-(Px 14)
$mkP=New-GlassWebForm (Px 600) (Px 400)
$panel=$mkP.f; $wvP=$mkP.wv; $script:panel=$panel; $script:wvP=$wvP
# Fit the big panel to THIS screen (it's DPI-scaled, so 600x400 can be too big on a small
# high-DPI laptop) and restore the size the user last dragged it to. Always clamped to fit.
$waP=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$pw=$panel.Width; $ph=$panel.Height
$psz=Load-PanelSize; if($psz){ $pw=[int]$psz.w; $ph=[int]$psz.h }
$pmaxW=$waP.Width-(Px 12); $pmaxH=$waP.Height-(Px 12); $pminW=(Px 280); $pminH=(Px 170)
if($pw -gt $pmaxW){ $pw=$pmaxW }; if($ph -gt $pmaxH){ $ph=$pmaxH }
if($pw -lt $pminW){ $pw=$pminW }; if($ph -lt $pminH){ $ph=$pminH }
$panel.Width=$pw; $panel.Height=$ph
function Place-PanelHome {
  $wa3=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $panel.SetBounds(($wa3.Right-$panel.Width-(Px 16)),($wa3.Bottom-$panel.Height-(Px 14)),$panel.Width,$panel.Height)
}
function Set-Msg($t){ if($script:statusText -ne $t){ $script:statusText=$t; JS $script:wvS ("XC.setStatus("+(ConvertTo-Json $t)+")") } }
function Set-Dot($hex,$pulse){ $k=$hex+(BoolJs $pulse); if($script:dotState -ne $k){ $script:dotState=$k; JS $script:wvS ("XC.setDot('"+$hex+"',"+(BoolJs $pulse)+")") } }
function Apply-Strip {
  if($script:animating){ return }
  $wa4=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  if($script:collapsed){ $script:menuOpen=$false; $nw=(Px 280); $nh=(Px 40) } else { $nw=(Px 780); $nh=(Px 80)+$(if($script:menuOpen){ Px 320 }else{ 0 }) }
  # Honor the user's dragged horizontal position (clamped fully on-screen for the new
  # width) instead of always re-centering - else opening the menu / expanding snaps the
  # strip back to screen center every time. $script:userLeft is $null until first drag.
  if($null -ne $script:userLeft){
    $nl=[int]$script:userLeft; $maxL=$wa4.Right-$nw; $minL=$wa4.Left
    if($nl -gt $maxL){ $nl=$maxL }; if($nl -lt $minL){ $nl=$minL }
  } else {
    $nl=$wa4.Left+[int](($wa4.Width-$nw)/2)
  }
  $nt=$wa4.Bottom-$nh-(Px 14)
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
  $sb=$strip.Bounds; $ox=$sb.X; $oy=$sb.Y; $ow=$sb.Width; $oh=$sb.Height
  if($ow -eq $nw -and $oh -eq $nh -and $ox -eq $nl -and $oy -eq $nt){ return }
  # Instant resize. The old eased loop used a blocking Start-Sleep on the UI thread,
  # which stutters when the thread is busy AND made the panel open at a mid-animation
  # position (the double-press-to-open bug). A clean snap is smoother than a janky glide.
  $strip.SetBounds($nl,$nt,$nw,$nh)
}
function Push-StripState {
  JS $script:wvS ("XC.setMode('"+$(if($script:collapsed){'pill'}else{'bar'})+"')")
  JS $script:wvS ("XC.setStatus("+(ConvertTo-Json $script:statusText)+")")
  JS $script:wvS ("XC.setToggle('pause',"+(BoolJs $sync.paused)+")")
  JS $script:wvS ("XC.setToggle('mute',"+(BoolJs $sync.mute)+")")
  JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")")
  JS $script:wvS ("XC.setToggle('format',"+(BoolJs $sync.formatOn)+")")
  JS $script:wvS ("XC.setToggle('hands',"+(BoolJs $sync.handsOn)+")")
  JS $script:wvS ("XC.setToggle('teach',"+(BoolJs $sync.teachOn)+")")
  JS $script:wvS ("XC.setToggle('guide',"+(BoolJs $sync.guideOn)+")")
  JS $script:wvS ("XC.setToggle('micmute',"+(BoolJs $sync.micMute)+")")
  JS $script:wvS ("XC.setVol("+[int]([double]$sync.ttsVol*100)+")")
  JS $script:wvS ("XC.busy(false)")
  $hp=$script:dotState; $script:dotState=""; if($hp -ne ""){ $c=$hp.Substring(0,7); $p=$hp.Substring(7); JS $script:wvS ("XC.setDot('"+$c+"',"+$p+")") } else { Set-Dot '#22c55e' $true }
}
function Show-Answer($md,$kind='answer',$id=0){
  $script:lastFull=$md
  # A normal answer/nudge takes over the pill, so step out of the drill view (but keep
  # rtSession + rtCur so picking Run-through resumes the exercise where you left off).
  if($script:woActive){ $script:woActive=$false; $sync.woActive=$false }
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  if($script:panelReady){
    JS $script:wvP ("XC.setTime('"+(Get-Date).ToString("HH:mm")+"')")
    JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $md)+","+(ConvertTo-Json (@{kind=$kind;id=$id}))+")")
  } else { $script:pendingAns=$md; $script:pendingLoad=$false }
}
# Open the dedicated exercise view, queuing if the panel's WebView2 is not ready yet
# (the first panel use of a session) so the pill never pops up empty.
function Open-Ex($plObj){
  $j = (ConvertTo-Json $plObj -Depth 6)
  if($script:panelReady){ JS $script:wvP ("XC.openExercise("+$j+")") } else { $script:pendingExercise=$j }
  WO-SaveSession   # crash-resume: persist the in-flight sitting every time an exercise is shown
}
# --- Run-through crash-resume: persist the in-flight sitting so a coach restart drops the
# student back into the exact exercise (topic mastery already persists; this saves the
# CURRENT exercise + ladder position). Cleared on End; only resumed if recent (<24h). ---
function WO-SessionPath {
  $root = Split-Path $PSScriptRoot -Parent; $d = Join-Path $root 'data'
  if(-not (Test-Path $d)){ try{ New-Item -ItemType Directory -Force -Path $d | Out-Null }catch{} }
  return (Join-Path $d 'runthrough-session.json')
}
function WO-SaveSession {
  try{
    if(-not $script:rtCur){ return }
    $o = @{ rtCur=$script:rtCur; woConcept=[string]$script:woConcept; woRung=[int]$script:woRung; woRungMiss=[int]$script:woRungMiss; woConceptMiss=[int]$script:woConceptMiss; woIdx=[int]$script:woIdx; woSeq=[int]$script:woSeq; woLast=[string]$script:woLast; woRecent=@($script:woRecent); woLadderTop=[int]$script:woLadderTop; savedAt=(Get-Date).ToString('o') }
    [IO.File]::WriteAllText((WO-SessionPath), ($o | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
  }catch{}
}
function WO-ClearSession { try{ $p=WO-SessionPath; if(Test-Path $p){ Remove-Item $p -Force -ErrorAction SilentlyContinue } }catch{} }
function WO-LoadSession {
  try{
    $p = WO-SessionPath; if(-not (Test-Path $p)){ return }
    $o = (Get-Content $p -Raw) | ConvertFrom-Json
    if(-not $o -or -not $o.rtCur){ return }
    $age = 999.0; try{ $age = ((Get-Date)-[datetime]::Parse([string]$o.savedAt)).TotalHours }catch{}
    if($age -gt 24){ WO-ClearSession; return }   # stale sitting - start fresh
    $ex = $o.rtCur
    if(Get-Command RT-NormalizeExercise -ErrorAction SilentlyContinue){ try{ $ex = RT-NormalizeExercise $o.rtCur ([string]$o.rtCur.topicId) ([int]$o.rtCur.level) }catch{} }
    $script:rtCur = $ex
    $script:woConcept=[string]$o.woConcept; $script:woRung=[int]$o.woRung; $script:woRungMiss=[int]$o.woRungMiss; $script:woConceptMiss=[int]$o.woConceptMiss
    $script:woIdx=[int]$o.woIdx; $script:woSeq=[int]$o.woSeq; $script:woLast=[string]$o.woLast
    try{ $script:woRecent=@($o.woRecent | ForEach-Object { [string]$_ }) }catch{}
    try{ if($o.woLadderTop){ $script:woLadderTop=[int]$o.woLadderTop } }catch{}
    $script:rtSession=$true; $script:woActive=$false   # resumes when the student next opens Run-through (existing Start-Workout resume path)
  }catch{}
}
# --- Dismissed-issue persistence (dismiss trains the brain across restarts): a flag the
# student marks "not an error" is saved and reloaded, so the watcher keeps avoiding it (and
# similar ones) in future sessions, not just for 20 minutes. ---
function Dismiss-Path {
  $root = Split-Path $PSScriptRoot -Parent; $d = Join-Path $root 'data'
  if(-not (Test-Path $d)){ try{ New-Item -ItemType Directory -Force -Path $d | Out-Null }catch{} }
  return (Join-Path $d 'dismissed.json')
}
function Dismiss-Save {
  try{
    if(-not $sync.xlDismissed){ return }
    $arr = @(@($sync.xlDismissed.ToArray()) | Select-Object -Last 30 | ForEach-Object { @{ text=[string]$_.text; t=([datetime]$_.t).ToString('o') } })
    [IO.File]::WriteAllText((Dismiss-Path), ($arr | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
  }catch{}
}
function Dismiss-Load {
  try{
    $p = Dismiss-Path; if(-not (Test-Path $p)){ return }
    $a = (Get-Content $p -Raw) | ConvertFrom-Json
    foreach($it in @($a)){ if(-not $it.text){ continue }; $tt=(Get-Date).AddDays(-1); try{ $tt=[datetime]::Parse([string]$it.t) }catch{}; [void]$sync.xlDismissed.Add(@{ text=[string]$it.text; t=$tt }) }
    while($sync.xlDismissed.Count -gt 30){ $sync.xlDismissed.RemoveAt(0) }
  }catch{}
}
function Show-PanelLoading {
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  if($script:panelReady){ JS $script:wvP ("XC.setAnswerLoading()") } else { $script:pendingLoad=$true }
}
# --- Demo showcase -----------------------------------------------------------------
# Instantly fills the panel with three polished, realistic notifications (a next-step
# guide, a caught mistake, and a deep chained explanation) so the panel quality AND the
# notification switcher both show well on demand - no waiting for live events to pile up.
# Triggered by the "Demo Coach" desktop shortcut (writes act:demo to the cmd file). The
# content is canned but true-to-form: it's exactly what the live coach surfaces.
function Start-Demo {
  $script:lastActive=(Get-Date)
  # Show the panel FIRST so its WebView2 navigates, then WAIT until it's live. Only then
  # push - otherwise the three setAnswer calls collapse into one pending answer (last
  # wins) and the switcher shows 1 entry instead of 3.
  Place-PanelHome
  if(-not $panel.Visible){ $panel.Show() }
  $tries=0
  while(-not $script:panelReady -and $tries -lt 120){ [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50; $tries++ }
  [System.Windows.Forms.Application]::DoEvents()
  if($script:panelReady){ try{ JS $script:wvP ("XC.resetNotifs()") }catch{} }   # clean slate so each run shows exactly these three
  $guide=@'
## Next step - build the depreciation schedule
You've got revenue and EBITDA flowing. The next block that unlocks the model is **D&A**.

- Lay out a small schedule below the model: opening PP&E, **+ CapEx**, **- depreciation**, = closing PP&E
- Drive depreciation off a simple **% of opening PP&E** (or a useful-life assumption) for now
- Then link the closing balance back to the **PP&E line on the balance sheet**

Do this and the three statements start talking to each other - which is exactly what the other two notes are about.
'@
  $issue=@'
## Heads up - your balance sheet won't balance
**Assets exceed Liabilities + Equity by ~$40 (cell C28).**

The culprit is **Retained Earnings** in C24. You rolled it forward as:

> `prior RE + Net Income`

but left out the dividend. Retained earnings should be:

**prior RE + Net Income - Dividends paid**

Add the dividend subtraction and the sheet ties. A broken balance check is almost always retained earnings, working capital, or a sign error - worth burning into muscle memory.
'@
  $answer=@'
## Why depreciation is the classic 3-statement question
This is *the* interview question because one number touches all three statements. Follow $100 of depreciation through, at a 25% tax rate:

1. **Income statement** - it's an expense, so pre-tax income drops $100. Tax falls by $25, and **Net Income drops $75**.
2. **Cash flow statement** - depreciation is **non-cash**, so you **add the full $100 back** at the top of CFO. Net effect on cash: **+$25** - the tax shield. Cash actually *rises*.
3. **Balance sheet** - accumulated depreciation cuts **PP&E by $100**, cash is **up $25**, retained earnings is **down $75**. Assets fall $75, equity falls $75 - **it balances.**

**The connective tissue:** a non-cash expense is really a *timing and tax* story. You spent the cash years ago on CapEx; depreciation just spreads that cost across the income statement, and the only live cash effect today is the tax it saves. Lock this in and DCF, LBO, and the cash flow statement all click - same mechanic underneath.
'@
  Show-Answer $guide  'guide'  0
  [System.Windows.Forms.Application]::DoEvents()
  Show-Answer $issue  'issue'  0
  [System.Windows.Forms.Application]::DoEvents()
  Show-Answer $answer 'answer' 0
  $script:lastFull=$answer
  $script:baseStatus="Demo loaded - tap the list icon to switch between notes"; $script:idle=$true
  Set-Dot '#22c55e' $true; Set-Msg "Demo loaded - 3 notifications ready"
}
function Simplify-Answer($text){
  $sysS="You simplify finance/Excel explanations for a beginner. Keep all cell references and numbers exactly. Use the same markdown style (optional ## header, - bullets, **bold** for key terms) but plainer words and shorter sentences. Output only the simplified explanation."
  $payload=@{ model="gpt-4o-mini"; max_tokens=450; temperature=0.2; messages=@(@{role="system";content=$sysS},@{role="user";content=("Simplify this explanation:`n`n"+$text)}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_simplify.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return "Could not simplify right now (connection issue) - the original answer is unchanged."
}
# Plain-English re-explanation of a single flashcard for a confused beginner.
# Used by the practice card's "Explain it simpler" button. Quick helper call
# (gpt-4o-mini, same as Simplify-Answer/define) - the live coach is untouched.
function Explain-Card($front,$back,$type){
  if(-not $sync.key){ return "Set your API key to use Explain (no key found)." }
  $front=[string]$front; $back=[string]$back; $type=[string]$type
  $sysC="You are a patient finance tutor helping a beginner who is confused by an investment-banking flashcard. Re-explain it from scratch in the simplest plain English: say what it means in everyday terms, unpack any jargon, and give ONE tiny concrete example with small round numbers. Keep it to 2-4 short sentences. Be warm and clear, no preamble, no restating the question. You may use **bold** for a key term."
  $usr="Flashcard ("+$type+")`nTerm / front: "+$front+"`nGiven answer / back: "+$back+"`n`nExplain this simply for someone who does not get it yet."
  $payload=@{ model="gpt-4o-mini"; max_tokens=320; temperature=0.3; messages=@(@{role="system";content=$sysC},@{role="user";content=$usr}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_cardhelp.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return "Could not load a simpler explanation right now (connection issue). Try again in a moment."
}
function Set-Query($q){ if($script:panelReady){ JS $script:wvP ("XC.setQuery("+(ConvertTo-Json ([string]$q))+")") } else { $script:pendingQ=[string]$q } }
function Shutdown-Coach {
  $sync.stop=$true; try{ $ui.Stop() }catch{}; Start-Sleep -Milliseconds 300; Kill-FF
  try{ $rs.Close() }catch{}; try{ $rsT.Close() }catch{}; try{ $rsX.Close() }catch{}
  try{ $panel.Close() }catch{}
  try{ $strip.Close() }catch{}
}
function Handle-Ask($q){
  # RESOLVE the current watcher nudge by voice/typing: "that's not an error", "dismiss", "it's fine",
  # "false alarm". Marks the flag dismissed (persisted + fed back so the watcher stops raising it and
  # similar ones) instead of sending it to the model. The other ways to resolve: the X on the issue
  # row in the panel, or the dismiss button.
  if($q -and ($q.Length -lt 46) -and ($q -match "(?i)^\s*(that.?s? ?(not an error|correct|right|fine|ok|good)|not an error|no error|it.?s (fine|right|correct|ok)|dismiss( that| it)?|ignore( that| it)?|leave it( alone)?|false alarm|wrong flag|resolve( that| it)?|mark resolved)\s*\.?\s*$")){
    if($script:askBusy){ return }
    $dt=[string]$sync.lastNudge
    if($dt -and $dt -ne 'OK'){ if($sync.xlDismissed){ [void]$sync.xlDismissed.Add(@{ text=$dt; t=(Get-Date) }); while($sync.xlDismissed.Count -gt 30){ $sync.xlDismissed.RemoveAt(0) }; Dismiss-Save }; $sync.lastNudge='' }
    $script:xlNudgeShown=$false; $script:idle=$true; Set-Dot '#22c55e' $true; Set-Msg "Got it - dismissed, not an error"; $script:baseStatus="Dismissed - not an error"
    return
  }
  if($script:askBusy){ return }
  $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
  JS $script:wvS ("XC.busy(true)")
  if($q -eq ""){ Set-Msg "Reading your Excel + the lesson..."; $script:lastHelpQ=""; $script:busyLabel="Reading your screen" }
  elseif($sync.handsOn -and ($q -match '(?i)\b(set ?up|build|fill|create|write|put|insert|add|enter|make|lay ?out|fix|change|update|correct|replace|populate|complete|finish|redo|do it|format|re-?format|colou?r|highlight|style|clean ?up)\b')){ Set-Msg "Building your sheet - careful pass, can take a minute..."; $script:lastHelpQ=$q; $script:busyLabel="Building the sheet" }
  else { Set-Msg ("Thinking: "+$q); $script:lastHelpQ=$q; $script:busyLabel="Thinking" }
  $script:busySince=(Get-Date)
  Set-Dot '#2563eb' $false
  [System.Windows.Forms.Application]::DoEvents()
  $det=$false; if($q){ $det=[bool]($q -match '(?i)explain|in detail|elaborate|\bwhy\b') }
  $sync.askLabel=$(if($q){ $q }else{ "Help with my screen" })
  $sync.typedDetail=$det; $sync.typedAsk=$(if($q){ $q }else{ "__ASSIST__" })
}
# Compact performance snapshot for the practice end screen (top strengths/weak spots).
function Perf-Payload {
  if(-not (Get-Command Get-PerfSummary -ErrorAction SilentlyContinue)){ return $null }
  try {
    $s = Get-PerfSummary
    $str=@(); foreach($x in @($s.strengths)){ $str += @{ name=[string]$x.name; pct=[int][math]::Round($x.acc*100) }; if($str.Count -ge 3){ break } }
    $wk=@(); foreach($x in @($s.weaknesses)){ $wk += @{ name=[string]$x.name; pct=[int][math]::Round($x.acc*100) }; if($wk.Count -ge 3){ break } }
    return @{ pct=[int]$s.pct; attempts=[int]$s.totalAttempts; strengths=$str; weaknesses=$wk }
  } catch { return $null }
}
function Start-Practice {
  if(-not (Get-Command Get-DueCards -ErrorAction SilentlyContinue)){ Show-Answer "Practice deck is not built yet - run build-deck.ps1 once to generate your flashcards, then click Practice again." 'note' 0; Set-Query "Practice"; return }
  $deck=$null; if(Get-Command Get-Deck -ErrorAction SilentlyContinue){ try{ $deck=Get-Deck }catch{} }
  $due=@(); try{ $due=@(Get-DueCards 20) }catch{}
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  if(@($due).Count -eq 0){
    $empty=$(if($deck){ 'caughtup' }else{ 'nodeck' })
    JS $script:wvP ("XC.openPractice("+(ConvertTo-Json (@{mode='review';dueCount=0;empty=$empty;perf=(Perf-Payload)}) -Depth 6)+")")
    $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus=$(if($deck){ "All caught up - no cards due" }else{ "No deck yet - run build-deck" }); return
  }
  $script:pracList=@($due); $script:pracIdx=0; Show-PracticeCard
}
function Show-PracticeCard {
  if(($null -eq $script:pracList) -or ($script:pracIdx -ge @($script:pracList).Count)){
    JS $script:wvP ("XC.openPractice("+(ConvertTo-Json (@{mode='review';dueCount=0;empty='caughtup';perf=(Perf-Payload)}) -Depth 6)+")")
    $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="Practice complete - nice work"; return
  }
  $c=@($script:pracList)[$script:pracIdx]
  $hasCh=($c.choices -and (@($c.choices).Count -ge 2) -and ($null -ne $c.answer))
  $mode=$(if($hasCh){ 'quiz' }else{ 'review' })
  $card=@{ id=[string]$c.id; type=[string]$c.type; front=[string]$c.front; back=[string]$c.back }
  if($hasCh){ $card['choices']=@($c.choices); $card['answer']=[int]$c.answer }
  $payload=@{ mode=$mode; dueCount=@($script:pracList).Count; index=$script:pracIdx; total=@($script:pracList).Count; card=$card }
  JS $script:wvP ("XC.openPractice("+(ConvertTo-Json $payload -Depth 6)+")")
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  $script:idle=$false; $script:lastActive=(Get-Date)
}
function Handle-Practice($action,$cardId,$quality,$choice){
  switch([string]$action){
    'rate' {
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      if($cc -and (Get-Command Record-Answer -ErrorAction SilentlyContinue)){ try{ Record-Answer $cc.topicId $null ([int]$quality -ge 3) | Out-Null }catch{} }
      if(Get-Command Rate-Card -ErrorAction SilentlyContinue){ try{ Rate-Card $cardId ([int]$quality) }catch{} }
      $script:pracIdx=([int]$script:pracIdx)+1; Show-PracticeCard
    }
    'quizAnswer' {
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      $ok=($cc -and ([int]$choice -eq [int]$cc.answer))
      if($cc -and (Get-Command Record-Answer -ErrorAction SilentlyContinue)){ try{ Record-Answer $cc.topicId $null $ok | Out-Null }catch{} }
      if(Get-Command Rate-Card -ErrorAction SilentlyContinue){ try{ Rate-Card $cardId ([int]$(if($ok){4}else{1})) }catch{} }
    }
    'practiceNext' { $script:pracIdx=([int]$script:pracIdx)+1; Show-PracticeCard }
    'simplify' {
      if($script:cardHelpBusy){ return }
      $cc=$null; foreach($x in @($script:pracList)){ if([string]$x.id -eq [string]$cardId){ $cc=$x; break } }
      if(-not $cc){ $cc=@($script:pracList)[$script:pracIdx] }
      if(-not $cc){ return }
      $script:cardHelpBusy=$true
      JS $script:wvP ("XC.setCardHelpLoading()")
      [System.Windows.Forms.Application]::DoEvents()
      try{ $ex=Explain-Card $cc.front $cc.back $cc.type; JS $script:wvP ("XC.setCardHelp("+(ConvertTo-Json ([string]$ex))+")") }catch{}
      $script:cardHelpBusy=$false
    }
    'practiceClose' { try{ $panel.Hide() }catch{}; $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="On track" }
  }
}
# Excel exercise: generate an AI calc drill, render it into a "Workout" sheet, and
# (on the next click) grade what the student typed. Toggles generate <-> check.
# When a Workout answer is wrong, generate a SHORT contextual explanation of WHY it
# is wrong (the likely mistake + the correct reasoning in context), specific to the
# student's numbers. gpt-4o-mini helper - the live coach model is untouched.
function Explain-Mistake($exercise, $perCell){
  if(-not $sync.key){ return "" }
  $wrong=@(); foreach($pc in @($perCell)){ try{ if(-not $pc.ok){ $wrong+=$pc } }catch{} }
  if($wrong.Count -lt 1){ return "" }
  $given=""; try{ foreach($g in @($exercise.layout.given)){ $given += [string]$g.label+" = "+[string]$g.value+"; " } }catch{}
  $miss=""; foreach($pc in $wrong){ $miss += "- "+[string]$pc.label+": they entered "+[string]$pc.got+", correct = "+[string]$pc.expected+" ("+[string]$pc.formula+")`n" }
  $sysM="You are a patient finance/Excel tutor. The student just got a calculation WRONG (this was confirmed by an exact grader - the cells listed below are genuinely wrong). In 2-3 short sentences, explain WHY their specific answer is likely wrong (what they probably did or forgot) and the correct REASONING in context - WHY the right approach is right here. CRITICAL: explain the mistake ONLY in terms of the GIVEN formula and values. Do NOT invent or introduce any method, convention, or concept that is not in the given formula (e.g. do NOT mention mid-year convention, extra steps, or anything the question did not ask for), and do NOT claim anything else on the sheet is wrong beyond the cells listed below. Identify which part of the stated calculation they likely got wrong. Be specific to their numbers and encouraging. No preamble. Plain ASCII only."
  $usr="Question: "+[string]$exercise.prompt+"`nGiven values: "+$given+"`nWhat they got wrong:`n"+$miss
  $payload=@{ model="gpt-4o-mini"; max_tokens=220; temperature=0.3; messages=@(@{role="system";content=$sysM},@{role="user";content=$usr}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_whymistake.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return ""
}
# ADAPTIVE TEACHING: diagnose WHY the student missed, not just that they did, so the coach
# can respond differently to each cause. Returns @{ kind; teach }. kind drives the ladder:
#   method     - values right, just hardcoded (no AI needed) -> redo as a formula, no penalty
#   conceptual - wrong idea/method -> scaffold DOWN + re-teach the concept (the "I do")
#   arithmetic - right method, math slip -> same rung, "just recompute"
#   sign       - magnitude right, +/- flipped -> same rung, sign rule
#   reference  - used the wrong input/cell -> same rung, point at the right input
function Diagnose-Miss($exercise, $perCell){
  $cells=@($perCell)
  $wrongVal=@($cells | Where-Object { -not $_.ok })
  $methodOnly=@($cells | Where-Object { $_.ok -and ($null -ne $_.methodOk) -and (-not $_.methodOk) })
  # Cheap path: every value is right and only the FORMULA is missing (hardcoded). No AI call.
  if($wrongVal.Count -eq 0 -and $methodOnly.Count -gt 0){
    $fm=''; try{ $fm=[string]$methodOnly[0].formula }catch{}
    return @{ kind='method'; teach=("You have the right number - now build it as a formula (= "+$fm+") so the cell recomputes from its inputs. Getting the answer is good; making Excel DO the calc is the skill that carries into a real model.") }
  }
  if($wrongVal.Count -lt 1){ return @{ kind='unknown'; teach='' } }
  if(-not $sync.key){ return @{ kind='unknown'; teach='' } }
  $given=""; try{ foreach($g in @($exercise.layout.given)){ $given += [string]$g.label+" = "+[string]$g.value+"; " } }catch{}
  $miss=""; foreach($pc in $wrongVal){ $miss += "- "+[string]$pc.label+": entered "+[string]$pc.got+", correct = "+[string]$pc.expected+" ("+[string]$pc.formula+")`n" }
  $sysM="You are a patient finance/Excel tutor diagnosing ONE wrong calculation (an exact grader already confirmed it is wrong). FIRST classify the single most likely cause as exactly one of: conceptual (used the wrong method or idea), arithmetic (right method, slipped on the math), sign (right magnitude but a flipped +/- or subtraction), reference (used the wrong input or cell). THEN teach. Reply EXACTLY one line in this form: KIND: <conceptual|arithmetic|sign|reference> | <2-3 sentences: why their answer is wrong and the correct reasoning, ONLY in terms of the given formula and values - introduce no new method or convention, and do not claim anything else on the sheet is wrong>. Be specific to their numbers, encouraging, plain ASCII."
  $usr="Question: "+[string]$exercise.prompt+"`nGiven: "+$given+"`nWrong:`n"+$miss
  $payload=@{ model="gpt-4o-mini"; max_tokens=240; temperature=0.3; messages=@(@{role="system";content=$sysM},@{role="user";content=$usr}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_diagnose.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 40 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  $kind='unknown'; $teach=''
  if($j.choices){
    $a=([string]$j.choices[0].message.content).Trim()
    if($a -match '(?im)^\s*KIND:\s*([A-Za-z]+)\s*\|\s*(.+)$'){ $kind=$Matches[1].ToLower(); $teach=$Matches[2].Trim() } else { $teach=$a }
    if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $teach=Clean-Answer $teach }
  }
  return @{ kind=$kind; teach=$teach }
}
# FULL teach-from-the-ground-up explanation of the current exercise, on demand ("Go
# deeper"). Unlike Explain-Mistake (deliberately terse, introduces nothing new), this
# IS allowed to teach the underlying concept and walk every step - for when the short
# "Why" left the student still not understanding. $perCell may be $null (pill answers).
function Explain-Deep($exercise, $perCell){
  if(-not $sync.key){ return "I can't reach the model right now to go deeper - check your connection and try again." }
  $given=""; try{ foreach($g in @($exercise.layout.given)){ $given += "  - "+[string]$g.label+" ("+[string]$g.cell+") = "+[string]$g.value+"`n" } }catch{}
  $cells=""; try{ foreach($a in @($exercise.layout.answerCells)){ $cells += "  - "+[string]$a.cell+" ("+[string]$a.label+"): correct answer = "+[string]$a.expected+", computed as "+[string]$a.formula+"`n" } }catch{}
  $mine=""; try{ foreach($pc in @($perCell)){ if(-not $pc.ok){ $mine += "  - "+[string]$pc.cell+": I entered "+[string]$pc.got+" (correct = "+[string]$pc.expected+")`n" } } }catch{}
  $ansLine=""; if([string]$exercise.answer){ $ansLine="`nCorrect answer: "+[string]$exercise.answer }
  # --- CHAINING CONTEXT: place this concept in the course (what comes before/after),
  # tie to what the student already knows, and aim it at the sheet's end goal, so the
  # explanation can connect the dots instead of teaching an isolated fact. ---
  $chain=""
  try{
    $tid=[string]$exercise.topicId
    if($sync.curr -and $tid){
      $lines=@([string]$sync.curr -split "`r?`n" | Where-Object { $_.Trim() })
      $idx=-1; for($i=0;$i -lt $lines.Count;$i++){ if($lines[$i] -match ('^\s*'+[regex]::Escape($tid)+'\s*:')){ $idx=$i; break } }
      if($idx -ge 0){
        $lo=[Math]::Max(0,$idx-3); $hi=[Math]::Min($lines.Count-1,$idx+3); $win=@()
        for($i=$lo;$i -le $hi;$i++){ $win += ($(if($i -eq $idx){ "  >> " }else{ "     " })+$lines[$i]) }
        $chain="Where this sits in the course (>> = this topic; items above are earlier/prerequisite, below are what it leads into):`n"+($win -join "`n")+"`n"
      }
    }
  }catch{}
  $covered=""; try{ if($sync.brain){ $b=[string]$sync.brain; if($b.Length -gt 1400){ $b=$b.Substring($b.Length-1400) }; $covered="What the student has already covered + known weak points (connect to these; do not re-teach from zero what they already know, and call out a relevant weak point if this touches one):`n"+$b+"`n" } }catch{}
  $goal=""; try{ if([string]$sync.sheetPurpose){ $goal="Overall goal of the current sheet (chain this step toward this end goal): "+[string]$sync.sheetPurpose+"`n" } }catch{}
  $sysM="You are an exceptional finance/Excel tutor for a student in a Breaking Into Wall Street course. The student did an exercise and wants to TRULY understand it - not as an isolated fact but as part of the whole picture. Give a COMPLETE, CONNECTED explanation that CHAINS the ideas together: show how this concept builds on what comes before it, how it feeds into what comes next, and how the numbers flow through the broader model (for example how an income-statement item flows into the cash flow statement and the balance sheet, or how a driver rolls forward period to period). You MAY teach necessary background. Use markdown with these sections: '## What it's really asking' (restate plainly), '## The idea' (the underlying concept and WHY the approach is right), '## Step by step' (plug the ACTUAL given numbers in and show every step to the exact answer, thousands separators; if they got it wrong, fold their specific slip in here), '## How it all connects' (THE KEY SECTION - the chain: what this builds on, what it feeds into, and where these numbers flow in the bigger model and toward the sheet's goal; tie it explicitly to concepts the student has already covered), and '## Remember this' (the one-line rule plus the most common pitfall). Be concrete with THEIR numbers, genuinely connected (not a list of disconnected facts), and encouraging. Plain ASCII only."
  $usr="Exercise question: "+[string]$exercise.prompt+"`n`nWhat it's teaching: "+[string]$exercise.concept+$ansLine+"`n`nGiven values:`n"+$given+"`nAnswer cells:`n"+$cells+$(if($mine){ "`nWhat I got wrong:`n"+$mine }else{ "" })+$(if([string]$exercise.worked){ "`nReference worked solution: "+[string]$exercise.worked+"`n" }else{ "" })+$(if($chain){ "`n"+$chain }else{ "" })+$(if($goal){ "`n"+$goal }else{ "" })+$(if($covered){ "`n"+$covered }else{ "" })
  $payload=@{ model="gpt-4o-mini"; max_tokens=1200; temperature=0.3; messages=@(@{role="system";content=$sysM},@{role="user";content=$usr}) } | ConvertTo-Json -Depth 8
  $bf="$env:TEMP\xc_deepwhy.json"; [IO.File]::WriteAllText($bf,$payload,(New-Object System.Text.UTF8Encoding($false)))
  $r=& curl.exe -s --max-time 60 "https://api.openai.com/v1/chat/completions" -H ("Authorization: Bearer "+$sync.key) -H "Content-Type: application/json" -d ("@"+$bf)
  $j=$null; try{ $j=$r|ConvertFrom-Json }catch{}
  if($j.choices){ $a=[string]$j.choices[0].message.content; if(Get-Command Clean-Answer -ErrorAction SilentlyContinue){ $a=Clean-Answer $a }; return $a }
  return "I couldn't generate a deeper explanation just now (connection issue). Try again in a moment."
}
# Pick the next workout topic FROM MEMORY (unseen topics first, then weak ones, via
# the run-through picker) and generate it with a fresh nonce so numbers always differ.
function Gen-WorkoutEx {
  $script:woSeq=([int]$script:woSeq)+1
  # ADAPTIVE LADDER: if Check-Workout queued a move on the CURRENT concept, honor it instead
  # of picking a new topic. 'expand' grows the just-passed exercise one step harder (same
  # scenario); 'vary' serves a fresh variation of the same concept+rung after a miss.
  if($script:woPendingLadder){
    $d=$script:woPendingLadder; $script:woPendingLadder=$null
    $tid=[string]$d.concept; $rg=[int]$d.rung; if($rg -lt 1){ $rg=1 }
    $ex=$null
    if($d.prior){ try{ $ex=Make-Exercise $tid $rg ("v"+$script:woSeq) $d.prior ([string]$d.mode) }catch{} }   # expand or vary, both use the prior
    if(-not $ex){ try{ $ex=Make-Exercise $tid $rg ("v"+$script:woSeq) }catch{} }   # fallback: plain generation
    if($ex){ try{ $ex.phase=[string]$d.mode }catch{} }   # 'expand' (one step harder) or 'vary' (retry, fresh numbers)
    return $ex
  }
  # PICKER: move to a NEW concept and start a fresh ladder for it.
  $topicId=$null; $lvl=1
  if(Get-Command RT-PickNext -ErrorAction SilentlyContinue){
    try{ $pick=RT-PickNext (RT-LoadState) ([int]$script:woIdx) ([string]$script:woLast) ([string[]]$script:woRecent); if($pick){ $topicId=[string]$pick.topicId; $lvl=[int]$pick.level } }catch{}
  }
  if(-not $topicId -and (Get-Command Get-Curriculum -ErrorAction SilentlyContinue)){
    try{ $cur=@(Get-Curriculum | Where-Object { (-not (Get-Command Test-DomainInScope -ErrorAction SilentlyContinue)) -or (Test-DomainInScope $_.domain) }); if($cur.Count){ $topicId=[string]$cur[($script:woIdx % $cur.Count)].id } }catch{}
  }
  if(-not $topicId){ return $null }
  if($lvl -lt 1){ $lvl=1 }
  $script:woIdx=([int]$script:woIdx)+1; $script:woLast=$topicId
  # Recency queue: remember the last few concepts so the picker can avoid re-serving them
  # back-to-back (stops the run-through ping-ponging between two topics).
  $script:woRecent=@(@($script:woRecent) + $topicId | Select-Object -Last 6)
  $script:woConcept=$topicId; $script:woRung=$lvl; $script:woRungMiss=0; $script:woConceptMiss=0   # new concept -> fresh ladder, starting at the picker's level
  # Difficulty TRACKS mastery + the fresh nonce keeps numbers different each time.
  $ex=$null; try{ $ex=Make-Exercise $topicId $lvl ("v"+$script:woSeq) }catch{}
  if($ex){ try{ $ex.phase='teach' }catch{} }   # fresh concept from the picker -> teach it first
  return $ex
}
# Frame the concept callout as a teach beat: a NEW concept is taught before the first drill;
# an expansion/retry is labelled so the student knows it builds on what they just did.
function WO-ConceptText($ex){
  $c=''; try{ $c=[string]$ex.concept }catch{}
  $ph=''; try{ $ph=[string]$ex.phase }catch{}
  if($ph -eq 'teach'){ return ('New concept - learn this, then try it. '+$c).Trim() }
  elseif($ph -eq 'expand'){ return ('Next step up, building on what you just did. '+$c).Trim() }
  elseif($ph -eq 'vary'){ return ('Same idea, fresh numbers - try it again. '+$c).Trim() }
  return $c
}
# Re-open the CURRENT run-through exercise's pill view - used to RESUME after the
# student used another feature (which closes the view). Does NOT re-render the Excel
# Workout sheet, so any in-progress work is preserved.
function Show-CurrentEx($ex){
  if(-not $ex){ return }
  $script:woActive=$true; $sync.woActive=$true
  $tn=''; if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq [string]$ex.topicId){ $tn=[string]$t.topic; break } } }catch{} }
  if([string]$ex.surface -eq 'excel'){
    $ttl=[string]$ex.layout.title; if(-not $ttl){ $ttl='Excel exercise' }
    $pl=@{ mode='excel'; title=$ttl; topicName=$tn; progress=('Level '+[string]$ex.level); prompt=[string]$ex.prompt; concept=(WO-ConceptText $ex); scoreboard=(WO-Scoreboard) }
    Open-Ex $pl
  } else {
    $chs=@(); if($ex.choices){ $chs=@($ex.choices | ForEach-Object { [string]$_ }) }
    $pl=@{ mode='pill'; title=$(if($tn){ $tn }else{ 'Concept' }); topicName=$tn; progress=('Level '+[string]$ex.level); prompt=[string]$ex.prompt; concept=(WO-ConceptText $ex); scoreboard=(WO-Scoreboard) }
    if($chs.Count -ge 2){ $pl['choices']=$chs } else { $pl['answer']=[string]$ex.answer }
    Open-Ex $pl
  }
}
function Start-Workout {
  if($script:woBusy){ return }
  # Resume a paused run-through (the view was closed by using another feature)
  # instead of generating a new one - keeps your place AND your Excel work.
  if($script:rtSession -and $script:rtCur -and (-not $script:woActive)){
    Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
    Set-Query "Run-through"; Show-CurrentEx $script:rtCur; return
  }
  if(-not (Get-Command Make-Exercise -ErrorAction SilentlyContinue)){ Show-Answer "The run-through is not available in this build yet." 'note' 0; return }
  $script:woBusy=$true
  Place-PanelHome; if(-not $panel.Visible){ $panel.Show() }
  Set-Query "Run-through"
  # Use the preloaded next exercise for an instant jump; otherwise generate now.
  $ex=$null
  if($script:woNext){ $ex=$script:woNext; $script:woNext=$null }
  else { JS $script:wvP ("XC.setAnswerLoading()"); [System.Windows.Forms.Application]::DoEvents(); $ex=Gen-WorkoutEx }
  if(-not $ex){ $script:woBusy=$false; Show-Answer "I could not build the next exercise right now (connection issue). Try again in a moment." 'note' 0; return }
  # Lock the ladder state to the exercise actually shown. This matters for SKIPPING via "Next"
  # (no Check in between): without it woRung never advances, so the speculative preload keeps
  # regenerating the SAME rung and you see the same concept forever. With it, skipping climbs
  # the rung and tops out into a new concept. (On the Check path these already match.)
  try{ if([string]$ex.topicId){ $script:woConcept=[string]$ex.topicId }; if($null -ne $ex.level -and [int]$ex.level -ge 1){ $script:woRung=[int]$ex.level } }catch{}
  if([string]$ex.surface -eq 'excel'){
    $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
    if(-not $xl){ $script:woBusy=$false; $script:woActive=$false; $sync.woActive=$false; Show-Answer "Open Excel first, then pick **Run-through** in the menu so I can set up the Workout sheet." 'note' 0; return }
    try{ RT-RenderExcel $ex $xl | Out-Null }catch{}
    $script:rtCur=$ex; $script:woActive=$true; $sync.woActive=$true; $script:rtSession=$true
    $ttl=[string]$ex.layout.title; if(-not $ttl){ $ttl="Excel exercise" }
    $tn=''; if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq [string]$ex.topicId){ $tn=[string]$t.topic; break } } }catch{} }
    $pl=@{ mode='excel'; title=$ttl; topicName=$tn; progress=("Level "+[string]$ex.level); prompt=[string]$ex.prompt; concept=(WO-ConceptText $ex); scoreboard=(WO-Scoreboard) }
    Open-Ex $pl
  } else {
    $script:rtCur=$ex; $script:woActive=$true; $sync.woActive=$true; $script:rtSession=$true
    $tn=''; if(Get-Command Get-Curriculum -ErrorAction SilentlyContinue){ try{ foreach($t in (Get-Curriculum)){ if([string]$t.id -eq [string]$ex.topicId){ $tn=[string]$t.topic; break } } }catch{} }
    $chs=@(); if($ex.choices){ $chs=@($ex.choices | ForEach-Object { [string]$_ }) }
    $pl=@{ mode='pill'; title=$(if($tn){ $tn }else{ "Concept" }); topicName=$tn; progress=("Level "+[string]$ex.level); prompt=[string]$ex.prompt; concept=(WO-ConceptText $ex); scoreboard=(WO-Scoreboard) }
    if($chs.Count -ge 2){ $pl['choices']=$chs } else { $pl['answer']=[string]$ex.answer }
    Open-Ex $pl
  }
  # Preload the LIKELY next exercise NOW, while you start working on this one, so "Next" is
  # instant on the common path. We assume a pass -> the next is THIS exercise expanded one
  # rung. A miss regenerates a fresh variation at Check time (masked by the explanation);
  # the top rung graduates to a new concept at Check time. This is what keeps the run-through
  # from stalling between questions.
  [System.Windows.Forms.Application]::DoEvents()
  if([int]$script:woRung -lt [int]$script:woLadderTop){
    try{ $script:woPendingLadder=@{ mode='expand'; concept=[string]$script:woConcept; rung=([int]$script:woRung+1); prior=$script:rtCur }; $script:woNext=Gen-WorkoutEx }catch{ $script:woNext=$null }
  } else { $script:woNext=$null }
  $script:woBusy=$false
}
function Check-Workout {
  if((-not $script:rtCur) -or $script:woBusy){ return }
  $script:woBusy=$true
  [System.Windows.Forms.Application]::DoEvents()
  $xl=$null; try{ $xl=[Runtime.InteropServices.Marshal]::GetActiveObject("Excel.Application") }catch{}
  if(-not $xl){ $script:woBusy=$false; JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md="I could not reach Excel to check. Make sure the Workout sheet is open, then press Check answer again."}) -Depth 4)+")"); return }
  $res=$null; try{ $res=Grade-ExcelExercise $script:rtCur $xl }catch{}
  if(-not $res){ $script:woBusy=$false; JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md="I could not read your answers. Make sure the Workout sheet is open, then press Check answer again."}) -Depth 4)+")"); return }
  $script:woLastResult=$res; $script:woLastCorrect=[bool]$res.correct   # keep for the "Go deeper" follow-up
  if(Get-Command Record-Answer -ErrorAction SilentlyContinue){ try{ Record-Answer $script:rtCur.topicId $null ([bool]$res.correct) | Out-Null }catch{} }
  if(Get-Command RT-RecordResult -ErrorAction SilentlyContinue){ try{ RT-RecordResult ([string]$script:rtCur.topicId) ([int]$script:rtCur.level) ([bool]$res.correct) $false | Out-Null }catch{} }
  $nw=0; try{ if(Get-Command Mark-ExcelMistakes -ErrorAction SilentlyContinue){ $nw=Mark-ExcelMistakes $script:rtCur $xl $res.perCell } }catch{}
  $tail="`n`nPress **Next exercise** to continue, or **End** to save and exit."
  if($res.correct){
    $script:woMissKind=''
    $body="Every answer cell checks out - nice work. (Marked green on the sheet.)"
    if($res.worked){ $body+="`n`n**How it's done:** "+[string]$res.worked }
    JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$true; md=($body+$tail)}) -Depth 6)+")")
  } else {
    $body="Here is what is off:`n"
    foreach($pc in @($res.perCell)){
      $lbl=[string]$pc.label; $tag=$(if($lbl){ " ("+$lbl+")" }else{ "" })
      $pmok=$true; try{ if($null -ne $pc.methodOk){ $pmok=[bool]$pc.methodOk } }catch{}
      if(-not $pc.ok){ $body+="`n- "+[string]$pc.cell+$tag+": you have "+[string]$pc.got+", it should be "+[string]$pc.expected }
      elseif(-not $pmok){ $fm=[string]$pc.formula; $body+="`n- "+[string]$pc.cell+$tag+": right number, but you typed it in - enter it as a **formula** (= "+$fm+") so it recalculates from the inputs." }
    }
    if([int]$nw -gt 0){ $body+="`n`nOn the sheet: **red** = wrong number, **amber** = right number but typed in (build it as a formula)." }
    if($res.worked){ $body+="`n`n**How it's done:** "+[string]$res.worked }
    # show the comparison immediately, then add the contextual WHY (an AI call)
    JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md=($body+"`n`n_Working out why..._")}) -Depth 6)+")")
    [System.Windows.Forms.Application]::DoEvents()
    # ADAPTIVE TEACHING: diagnose the cause and lead the explanation by it (this also drives
    # how the ladder responds below). The 'method' (hardcoded) case needs no AI call.
    $why=""; $script:woMissKind=''
    try{ $dg=Diagnose-Miss $script:rtCur $res.perCell; if($dg){ $why=[string]$dg.teach; $script:woMissKind=[string]$dg.kind } }catch{}
    if(-not $why){ try{ $why=Explain-Mistake $script:rtCur $res.perCell }catch{} }   # fallback
    if($why){
      $lead=switch([string]$script:woMissKind){ 'conceptual'{"**Let's rebuild the idea:** "} 'method'{""} 'sign'{"**Watch the sign:** "} 'reference'{"**Check your inputs:** "} 'arithmetic'{"**Just a slip - your method is right:** "} default{"**Why:** "} }
      $body+="`n`n"+$lead+$why
    }
    JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$false; md=($body+$tail)}) -Depth 6)+")")
  }
  # ADAPTIVE LADDER: decide the next exercise from THIS result and preload it (so "Next
  # exercise" is instant; the latency is masked while the student reads the result). A pass
  # grows the same concept one rung (expand the scenario); the top rung graduates it (the
  # picker serves a new concept). A miss serves a FRESH variation at the same rung; a 2nd
  # miss in a row drops a rung to scaffold down.
  if($script:woConcept){
    $top=[int]$script:woLadderTop; if($top -lt 1){ $top=3 }
    if($script:woLastCorrect){
      $script:woRungMiss=0; $script:woConceptMiss=0   # progress on this concept -> reset the give-up counter
      if([int]$script:woRung -lt $top){
        # PASS below the top: the expansion we already preloaded WHILE YOU WORKED is the right
        # next - keep it (so Next is instant), just advance the rung to match. Only regenerate
        # if the speculative preload had failed.
        $script:woRung=[int]$script:woRung+1
        if(-not $script:woNext){ $script:woPendingLadder=@{ mode='expand'; concept=[string]$script:woConcept; rung=[int]$script:woRung; prior=$script:rtCur }; try{ $script:woNext=Gen-WorkoutEx }catch{} }
      } else {
        # PASS at the top rung: concept mastered -> move to a new one (regenerated now).
        $script:woPendingLadder=$null; try{ $script:woNext=Gen-WorkoutEx }catch{ $script:woNext=$null }
      }
    } elseif([string]$script:woMissKind -eq 'method'){
      # NOT a real miss: the answer was right, only the formula was missing. Don't penalize the
      # concept or scaffold down - just serve a fresh variation so they redo it AS a formula.
      $script:woRungMiss=0; $script:woConceptMiss=0
      $script:woPendingLadder=@{ mode='vary'; concept=[string]$script:woConcept; rung=[int]$script:woRung; prior=$script:rtCur }
      try{ $script:woNext=Gen-WorkoutEx }catch{ $script:woNext=$null }
    } else {
      # MISS: route by the DIAGNOSED cause. A CONCEPTUAL miss = they don't get the idea, so
      # scaffold DOWN a rung right away (gentler) - we just showed the worked solution (the
      # "I do"); the next is an easier fresh variation (the "you do"). An arithmetic/sign/
      # reference SLIP keeps the same rung (the idea is fine; it was a slip). After 3 misses on
      # the SAME concept, stop hammering it and move on (spaced-rep resurfaces it later, lower).
      $script:woRungMiss=[int]$script:woRungMiss+1
      $script:woConceptMiss=[int]$script:woConceptMiss+1
      if([string]$script:woMissKind -eq 'conceptual' -and [int]$script:woRung -gt 1){ $script:woRung=[int]$script:woRung-1; $script:woRungMiss=0 }
      if($script:woConceptMiss -ge 3){
        $script:woConcept=''; $script:woRungMiss=0; $script:woConceptMiss=0; $script:woPendingLadder=$null
        try{ $script:woNext=Gen-WorkoutEx }catch{ $script:woNext=$null }   # picker serves a DIFFERENT concept (avoids recent)
      } else {
        if($script:woRungMiss -ge 2 -and [int]$script:woRung -gt 1){ $script:woRung=[int]$script:woRung-1; $script:woRungMiss=0 }
        $script:woPendingLadder=@{ mode='vary'; concept=[string]$script:woConcept; rung=[int]$script:woRung; prior=$script:rtCur }
        try{ $script:woNext=Gen-WorkoutEx }catch{ $script:woNext=$null }
      }
    }
  }
  $script:woBusy=$false
}
# Compact "X of N solid" scoreboard for the exercise header.
function WO-Scoreboard {
  if(-not (Get-Command Get-RTProgress -ErrorAction SilentlyContinue)){ return "" }
  try{ $p=Get-RTProgress; return ([string]$p.solid+" of "+[string]$p.total+" solid") }catch{ return "" }
}
# Grade a multiple-choice pill answer chosen in the dedicated exercise view.
function Handle-WorkoutAnswer($choice){
  if((-not $script:rtCur) -or $script:woBusy){ return }
  if(-not (Get-Command Grade-PillExercise -ErrorAction SilentlyContinue)){ return }
  $script:woBusy=$true
  $g=$null; try{ $g=Grade-PillExercise $script:rtCur ([int]$choice) }catch{}
  $ok=$false; if($g){ $ok=[bool]$g.correct }
  $script:woLastResult=$null; $script:woLastCorrect=$ok   # keep for the "Go deeper" follow-up (pills have no per-cell grid)
  if(Get-Command Record-Answer -ErrorAction SilentlyContinue){ try{ Record-Answer $script:rtCur.topicId $null $ok | Out-Null }catch{} }
  if(Get-Command RT-RecordResult -ErrorAction SilentlyContinue){ try{ RT-RecordResult ([string]$script:rtCur.topicId) ([int]$script:rtCur.level) $ok $false | Out-Null }catch{} }
  $body=""
  if($ok){ $body="Correct." } else { $body="Not quite - the correct answer is: "+[string]$g.expected+"." }
  if($g -and $g.worked){ $body+="`n`n"+[string]$g.worked }
  $body+="`n`nPress **Next exercise** to continue, or **End** to save and exit."
  JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$ok; md=$body}) -Depth 6)+")")
  $script:woBusy=$false
}
function Handle-Act($k){
  $script:lastActive=(Get-Date)
  if($k -ne 'workout'){ $script:woActive=$false; $sync.woActive=$false; if($script:panelReady){ try{ JS $script:wvP ("XC.closeExercise()") }catch{} } }
  switch($k){
    'collapse' { $script:collapsed=$true; Apply-Strip }
    'expand'   { $script:collapsed=$false; Apply-Strip }
    'reopen'   { if($script:lastFull){ Show-Answer $script:lastFull } }
    'pause'    {
      $sync.paused=-not $sync.paused
      JS $script:wvS ("XC.setToggle('pause',"+(BoolJs $sync.paused)+")")
      if($sync.paused){ $script:idle=$false; Set-Msg "Paused"; Set-Dot '#969aa2' $false } else { $script:baseStatus="Listening to the lesson"; $script:idle=$true; Set-Dot '#22c55e' $true }
    }
    'mute'     { $sync.mute=-not $sync.mute; JS $script:wvS ("XC.setToggle('mute',"+(BoolJs $sync.mute)+")"); if($sync.mute){ $sync.ttsStop=$true } }
    'micmute'  { $sync.micMute=-not $sync.micMute; JS $script:wvS ("XC.setToggle('micmute',"+(BoolJs $sync.micMute)+")"); $script:lastActive=(Get-Date); Set-Msg $(if($sync.micMute){ "Mic muted - not listening" }else{ "Mic on - listening" }) }
    'sound'    { $sync.muteSound=-not $sync.muteSound; JS $script:wvS ("XC.setToggle('sound',"+(BoolJs $sync.muteSound)+")") }
    'cancel'   {
      try{ Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ParentProcessId -eq $PID } | ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} } }catch{}
      $sync.cancelled=$true; $sync.typedAsk=""
      $script:askBusy=$false; $script:busySince=$null; $script:idle=$true
      JS $script:wvS ("XC.busy(false)"); Set-Msg "Cancelled"; Set-Dot '#22c55e' $true; $script:baseStatus="Cancelled"
    }
    'hands'    {
      $sync.handsOn=-not $sync.handsOn
      JS $script:wvS ("XC.setToggle('hands',"+(BoolJs $sync.handsOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.handsOn){ "Hands ON - tell me what to build (empty cells only)" }else{ "Hands off - watching only" }); Set-Dot $(if($sync.handsOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'teach'    {
      $sync.teachOn=-not $sync.teachOn
      JS $script:wvS ("XC.setToggle('teach',"+(BoolJs $sync.teachOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.teachOn){ "Teach mode ON - ask me to show you something" }else{ "Teach mode off" }); Set-Dot $(if($sync.teachOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'format'   {
      $sync.formatOn=-not $sync.formatOn
      JS $script:wvS ("XC.setToggle('format',"+(BoolJs $sync.formatOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.formatOn){ "Formatting ON - I'll style what I build (IB conventions)" }else{ "Formatting off - I'll build plain cells" }); Set-Dot $(if($sync.formatOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'guide'    {
      $sync.guideOn=-not $sync.guideOn
      JS $script:wvS ("XC.setToggle('guide',"+(BoolJs $sync.guideOn)+")")
      $script:idle=$false; Set-Msg $(if($sync.guideOn){ "Guide ON - I'll walk you through the next step" }else{ "Guide off - reactive checking only" }); Set-Dot $(if($sync.guideOn){ '#22c55e' }else{ '#969aa2' }) $false
      $script:lastActive=(Get-Date); $script:idle=$true
    }
    'note'     {
      $script:idle=$false; Set-Msg "Noting this for later..."; Set-Dot '#2563eb' $false
      Show-PanelLoading
      [System.Windows.Forms.Application]::DoEvents()
      $nn=Add-Note; $script:lastFull=$nn; Show-Answer $nn 'note' 0; Set-Query "Note this"
      $script:baseStatus="Noted - saved to revisit"; $script:idle=$true; Set-Dot '#22c55e' $true; $script:seen=$sync.stamp
    }
    'audit'    {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Deep-checking your sheet..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Deep-checking"
      Show-PanelLoading
      $sync.askLabel="Sheet audit"; $sync.typedDetail=$true; $sync.typedAsk="__AUDIT__"
    }
    'kick'     {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Getting you going..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Kick incoming"
      Show-PanelLoading
      $sync.askLabel="Kick-start"; $sync.typedDetail=$false; $sync.typedAsk="__KICK__"
    }
    'workout' { Start-Workout }
    'practice' {
      if(Get-Command Start-Practice -ErrorAction SilentlyContinue){ Start-Practice } else { Handle-Ask "make me a practice exercise and walk me through it" }
    }
    'why'      {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Explaining this cell..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Why this"
      Show-PanelLoading
      $sync.askLabel="Why this cell"; $sync.typedDetail=$false; $sync.typedAsk="__WHY__"
    }
    'cheat'    {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Building a cheat sheet..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Cheat sheet"
      Show-PanelLoading
      $sync.askLabel="Cheat sheet"; $sync.typedDetail=$false; $sync.typedAsk="__CHEAT__"
    }
    'demopractice' {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Building a demo + practice sheet..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Demo + practice"
      Show-PanelLoading
      $sync.askLabel="Demo + practice"; $sync.typedDetail=$false; $sync.typedAsk="__DEMO__"
    }
    'undo'     {
      if($script:askBusy){ return }
      $script:askBusy=$true; $script:idle=$false; $script:lastActive=(Get-Date)
      JS $script:wvS ("XC.busy(true)")
      Set-Msg "Reverting my last edit..."; Set-Dot '#2563eb' $false; $script:busySince=(Get-Date); $script:busyLabel="Undo"
      $sync.askLabel="Undo"; $sync.typedDetail=$false; $sync.typedAsk="__UNDO__"
    }
    'demo'     { Start-Demo }
    'close'    { Shutdown-Coach }
  }
}
function Handle-Panel($k,$term){
  $script:lastActive=(Get-Date)
  switch($k){
    'close'   { $sync.woActive=$false; try{ $panel.Hide() }catch{} }
    'dismississue' {
      # User says a flagged "issue" is a false positive. Record its text so the watcher stops
      # re-flagging the same thing (auto-released after 20 min), and clear the current nudge.
      $dt=[string]$term
      if($dt){
        if($sync.xlDismissed){ [void]$sync.xlDismissed.Add(@{ text=$dt; t=(Get-Date) }); while($sync.xlDismissed.Count -gt 30){ $sync.xlDismissed.RemoveAt(0) }; Dismiss-Save }
        if((Get-Command XC-SameIssue -ErrorAction SilentlyContinue) -and (XC-SameIssue $dt $sync.lastNudge)){ $sync.lastNudge="" }
        $script:xlNudgeShown=$false; if(-not $script:askBusy){ Set-Dot '#22c55e' $true; $script:idle=$true; $script:baseStatus="Dismissed - not an error" }
      }
    }
    'copy'    { try{ if($script:lastFull){ [System.Windows.Forms.Clipboard]::SetText($script:lastFull) } }catch{} }
    'copytext' { try{ if($term){ [System.Windows.Forms.Clipboard]::SetText([string]$term) } }catch{} }
    'workoutcheck' { if(Get-Command Check-Workout -ErrorAction SilentlyContinue){ Check-Workout } }
    'workoutnext'  { if(Get-Command Start-Workout -ErrorAction SilentlyContinue){ Start-Workout } }
    'workoutdeep'  {
      if($script:woBusy -or -not $script:rtCur){ return }
      $script:woBusy=$true
      JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$script:woLastCorrect; md="_Going deeper - one moment..._"}) -Depth 4)+")")
      [System.Windows.Forms.Application]::DoEvents()
      $deep=""; try{ $deep=Explain-Deep $script:rtCur $script:woLastResult }catch{}
      if(-not $deep){ $deep="I couldn't go deeper just now - try again in a moment." }
      $tail="`n`nPress **Next exercise** to continue, or **End** to save and exit."
      JS $script:wvP ("XC.showExerciseResult("+(ConvertTo-Json (@{correct=$script:woLastCorrect; md=($deep+$tail)}) -Depth 6)+")")
      $script:woBusy=$false
    }
    'workoutend'   { $script:woActive=$false; $sync.woActive=$false; $script:rtSession=$false; $script:rtCur=$null; $script:woNext=$null; WO-ClearSession; JS $script:wvP ("XC.closeExercise()"); $sb=(WO-Scoreboard); Show-Answer ("Run-through ended - your progress is saved."+$(if($sb){ "  You're at "+$sb+" of the course." }else{ "" })+"  Open the ... menu and pick Run-through any time to keep going.") 'note' 0 }
    'formulas' {
      $fxKey=[string]$sync.sheetPurpose
      if($fxKey -and $script:fxCache.ContainsKey($fxKey)){ JS $script:wvP ("XC.setFormulas("+$script:fxCache[$fxKey]+")") }
      else { $sync.formReq=$true }
    }
    'idents' {
      $idKey=([string]$sync.sheetPurpose)+"|"+([string]$sync.lastXl).GetHashCode()
      if($script:idCache.key -eq $idKey -and $script:idCache.json){ JS $script:wvP ("XC.setIdents("+$script:idCache.json+")") }
      else { $script:idPendingKey=$idKey; $sync.idReq=$true }
    }
    'explain' {
      if($script:askBusy){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $script:busySince=(Get-Date); $script:busyLabel="Explaining"
      $sync.askLabel="Explain in detail"; $sync.typedDetail=$true; $sync.typedAsk=$(if($script:lastHelpQ){ $script:lastHelpQ }else{ "__ASSIST__" })
    }
    'define'  {
      if($script:askBusy -or -not $term){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()")
      $q2="Define '"+$term+"' clearly and simply in the context of my course and what I am working on. 2 to 4 sentences, with a tiny concrete example if useful."
      $script:lastHelpQ=$q2
      $script:busySince=(Get-Date); $script:busyLabel="Defining"
      $sync.askLabel="Define "+$term; $sync.typedDetail=$false; $sync.typedAsk=$q2
    }
    'simplify' {
      if($script:askBusy -or -not $script:lastFull){ return }
      $script:askBusy=$true
      JS $script:wvP ("XC.setAnswerLoading()"); Set-Query "Simplify"
      [System.Windows.Forms.Application]::DoEvents()
      try{
        $src=$script:lastFull; if($src.Length -gt 1600){ $src=$src.Substring(0,1600) }
        $dd=Simplify-Answer $src; $script:lastFull=$dd; JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $dd)+")")
        if(-not $sync.mute){ $sync.ttsText=$dd }
      }catch{}
      $script:askBusy=$false
    }
  }
}
$wvS.add_CoreWebView2InitializationCompleted({
  param($s,$e)
  if($e.IsSuccess){ Tune-WebView $script:wvS; $script:wvS.CoreWebView2.Navigate($script:stripUrl) }
})
$wvS.add_WebMessageReceived({
  param($s,$e)
  $m=$null; try{ $m=$e.TryGetWebMessageAsString() | ConvertFrom-Json }catch{ return }
  if(-not $m){ return }
  switch([string]$m.type){
    'ready' { $script:stripReady=$true; Push-StripState }
    'act'   { Handle-Act ([string]$m.k) }
    'ask'   { Handle-Ask ([string]$m.q) }
    'drag'  { $script:lastActive=(Get-Date); $script:strip.Left+=[int]([double]$m.dx*$script:S); $script:strip.Top+=[int]([double]$m.dy*$script:S); $script:userLeft=$script:strip.Left }
    'panel' { if(([string]$m.k) -eq 'close'){ try{ $script:panel.Hide() }catch{} } }
    'menu'  { $script:menuOpen=[bool]$m.open; Apply-Strip }
    'vol'   { try{ $sync.ttsVol=[math]::Max(0.0,[math]::Min(1.0,[double]$m.value/100.0)) }catch{} }
  }
})
$wvP.add_CoreWebView2InitializationCompleted({
  param($s,$e)
  if($e.IsSuccess){ Tune-WebView $script:wvP; $script:wvP.CoreWebView2.Navigate($script:panelUrl) }
})
$wvP.add_WebMessageReceived({
  param($s,$e)
  $m=$null; try{ $m=$e.TryGetWebMessageAsString() | ConvertFrom-Json }catch{ return }
  if(-not $m){ return }
  switch([string]$m.type){
    'ready' {
      $script:panelReady=$true
      JS $script:wvP ("XC.setTime('"+(Get-Date).ToString("HH:mm")+"')")
      if($script:pendingLoad){ $script:pendingLoad=$false; JS $script:wvP ("XC.setAnswerLoading()") }
      if($script:pendingAns){ $a=$script:pendingAns; $script:pendingAns=$null; JS $script:wvP ("XC.setAnswer("+(ConvertTo-Json $a)+")") }
      if($script:pendingExercise){ $px=$script:pendingExercise; $script:pendingExercise=$null; JS $script:wvP ("XC.openExercise("+$px+")") }
      if($null -ne $script:pendingQ){ JS $script:wvP ("XC.setQuery("+(ConvertTo-Json $script:pendingQ)+")"); $script:pendingQ=$null }
    }
    'panel' { $pk=[string]$m.k; if($pk -eq 'practice'){ Handle-Practice ([string]$m.action) ([string]$m.cardId) $m.quality $m.choice } elseif($pk -eq 'workoutanswer'){ Handle-WorkoutAnswer $m.choice } else { Handle-Panel $pk ([string]$m.term) } }
    'drag'  { $script:lastActive=(Get-Date); $script:panel.Left+=[int]([double]$m.dx*$script:S); $script:panel.Top+=[int]([double]$m.dy*$script:S) }
    'panelresize' {
      $script:lastActive=(Get-Date)
      try{
        $nw=$script:panel.Width + [int]([double]$m.dw*$script:S)
        $nh=$script:panel.Height + [int]([double]$m.dh*$script:S)
        $war=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $mnW=(Px 280); $mnH=(Px 170); $mxW=$war.Width-(Px 12); $mxH=$war.Height-(Px 12)
        if($nw -lt $mnW){ $nw=$mnW }; if($nw -gt $mxW){ $nw=$mxW }
        if($nh -lt $mnH){ $nh=$mnH }; if($nh -gt $mxH){ $nh=$mxH }
        $script:panel.Width=$nw; $script:panel.Height=$nh
        Place-PanelHome                 # keep the bottom-right corner anchored as it resizes
        Save-PanelSize $nw $nh          # remember it for next launch
      }catch{}
    }
  }
})
$strip.Add_Shown({ Glass-On $script:strip; [void]$script:wvS.EnsureCoreWebView2Async($null) })
$panel.Add_Shown({ Glass-On $script:panel; [void]$script:wvP.EnsureCoreWebView2Async($null) })
# ---- tick: worker results -> UI ----
$ui=New-Object System.Windows.Forms.Timer; $ui.Interval=400
$ui.Add_Tick({
  try{
    # persist the pill's dragged X (throttled: only when it changed since last save)
    if($null -ne $script:userLeft -and $script:userLeft -ne $script:lastSavedLeft){ Save-StripPos $script:userLeft; $script:lastSavedLeft=$script:userLeft }
    $cmdF=(Join-Path $env:TEMP "xc4_cmd.txt")
    if([IO.File]::Exists($cmdF)){
      $cmdLine=""; try{ $cmdLine=([IO.File]::ReadAllText($cmdF)).Trim() }catch{}
      try{ [IO.File]::Delete($cmdF) }catch{}
      if($cmdLine){
        if($cmdLine -match '(?i)^act:(.+)$'){ Handle-Act ($Matches[1].Trim()) }
        elseif($cmdLine -match '(?i)^ask:(.+)$'){ Handle-Ask ($Matches[1].Trim()) }
        else{ Handle-Ask $cmdLine }
      }
    }
  }catch{}
  if(-not (Get-Process -Id $sync.ffpid -ErrorAction SilentlyContinue)){
    if(((Get-Date)-$script:ffLastTry).TotalSeconds -ge 10){
      $script:ffLastTry=(Get-Date); $script:ffFails++
      if($script:ffFails -le 3){ try{ $rp=Start-Process -FilePath $ff -ArgumentList $ffArgs -WindowStyle Hidden -PassThru; $sync.ffpid=$rp.Id }catch{} }
      elseif($script:ffFails -eq 4){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Msg "Mic capture failed - check MIC_DEVICE in .env"; Set-Dot '#ef4444' $false }
    }
  } elseif($script:ffFails -ne 0){ $script:ffFails=0 }
  if(-not $sync.stop){
    $wS=[string]$psw.InvocationStateInfo.State
    if($wS -eq 'Completed' -or $wS -eq 'Failed' -or $wS -eq 'Stopped'){
      try{ $script:rs=[runspacefactory]::CreateRunspace(); $script:rs.ApartmentState='STA'; $script:rs.ThreadOptions='ReuseThread'; $script:rs.Open(); $script:rs.SessionStateProxy.SetVariable('sync',$sync); $script:psw=[powershell]::Create(); $script:psw.Runspace=$script:rs; [void]$script:psw.AddScript(". `"$workPath`""); [void]$script:psw.BeginInvoke(); $script:baseStatus="Coach engine restarted - back up" }catch{}
    }
    $xS=[string]$psx.InvocationStateInfo.State
    $xHung=$false
    try{ if($sync.wHB -and (((Get-Date)-[datetime]$sync.wHB).TotalSeconds -gt 300) -and (((Get-Date)-$script:lastXWdog).TotalSeconds -gt 180)){ $xHung=$true } }catch{}
    if($xS -eq 'Completed' -or $xS -eq 'Failed' -or $xS -eq 'Stopped' -or $xHung){
      if($xHung){ try{ $script:psx.BeginStop($null,$null) }catch{}; try{ [IO.File]::AppendAllText((Join-Path $env:TEMP 'xc_watcher.log'),((Get-Date).ToString('HH:mm:ss')+"  WATCHDOG: watcher hung (no stamp 5min+) - force-restarting`r`n")) }catch{} }
      try{ $script:rsX=[runspacefactory]::CreateRunspace(); $script:rsX.ApartmentState='STA'; $script:rsX.ThreadOptions='ReuseThread'; $script:rsX.Open(); $script:rsX.SessionStateProxy.SetVariable('sync',$sync); $script:psx=[powershell]::Create(); $script:psx.Runspace=$script:rsX; [void]$script:psx.AddScript(". `"$xlWorkPath`""); [void]$script:psx.BeginInvoke(); $script:lastXWdog=(Get-Date); $sync.wHB=(Get-Date); $script:baseStatus="Mistake-watcher restarted - back up" }catch{}
    }
  }
  $lv=-1; if((-not $sync.paused) -and (-not $sync.micMute)){ $lv=Get-MicLevel }
  if($lv -ge 0){ JS $script:wvS ("XC.setEq("+[string]::Format([Globalization.CultureInfo]::InvariantCulture,"{0:0.00}",$lv)+")") } else { JS $script:wvS ("XC.setEq(-1)") }
  if($lv -ge 0.12){ $script:heardAt=(Get-Date) }
  $listenNow=[bool]$sync.chatOn
  if($listenNow -ne $script:listenState){ $script:listenState=$listenNow; JS $script:wvS ("XC.setListening("+(BoolJs $listenNow)+")") }
  if($script:idle){
    if($script:heardAt -and (((Get-Date)-$script:heardAt).TotalSeconds -lt 1.6)){ Set-Msg $(if($sync.chatOn){ "Hearing you (chat)..." }else{ "Hearing you..." }) }
    elseif($sync.lessonNoteAt -and (((Get-Date)-[datetime]$sync.lessonNoteAt).TotalSeconds -lt 2.5)){ Set-Msg "Noting the lesson..." }
    elseif($script:baseStatus -eq "Listening to the lesson"){ if($sync.micMute){ Set-Msg "Mic off - open the ... menu to start listening" } else { $cw=$false; try{ if(($sync.lessonNoteAt -and (((Get-Date)-[datetime]$sync.lessonNoteAt).TotalSeconds -lt 45)) -or ($sync.courseSeenAt -and (((Get-Date)-[datetime]$sync.courseSeenAt).TotalSeconds -lt 120))){ $cw=$true } }catch{}; Set-Msg $(if($cw){ "Watching the course" }else{ "Listening for the course" }) } }
    else { Set-Msg $script:baseStatus }
  }
  if(-not $script:collapsed){
    $el=(Get-Date)-$script:t0; $tt=("{0:00}:{1:00}" -f [int][math]::Floor($el.TotalMinutes),$el.Seconds)
    if($tt -ne $script:lastTimer){ $script:lastTimer=$tt; JS $script:wvS ("XC.setTimer('"+$tt+"')") }
  }
  if((-not $script:collapsed) -and $script:idle -and (-not $script:askBusy) -and (-not $panel.Visible)){
    if(((Get-Date)-$script:lastActive).TotalSeconds -ge 45){ $script:collapsed=$true; Apply-Strip }
  }
  if($sync.ackPing){
    $sync.ackPing=$false; $script:askBusy=$true; $script:busySince=(Get-Date); $script:busyLabel="Heard you - thinking"
    $script:idle=$false; Set-Dot '#2563eb' $false; Set-Msg "Heard you - thinking..."; JS $script:wvS ("XC.busy(true)")
    if(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{} }
  }
  if($script:askBusy -and $script:busySince){
    $es=[int]((Get-Date)-$script:busySince).TotalSeconds
    # Stuck-ask watchdog: if a request never completes (hung worker / dropped network), auto-release
    # the busy lock so the UI doesn't stay frozen and block every future Assist. The deep audit
    # ("Check my sheet") legitimately runs much longer (high reasoning over the whole model), so it
    # gets a 220s budget; everything else 90s.
    $stuckLimit=$(if([string]$script:busyLabel -match 'Deep-check|Building the sheet'){300}else{90})
    if($es -ge $stuckLimit){
      $script:askBusy=$false; $script:busySince=$null; $script:idle=$true; $sync.typedAsk=""
      JS $script:wvS ("XC.busy(false)"); Set-Msg "That took too long - please try again"; Set-Dot '#22c55e' $true; $script:baseStatus="Ready"
    } elseif($es -ge 4){ Set-Msg ($script:busyLabel+"... "+$es+"s") }
  }
  if($sync.formStamp -gt $script:seenForm){
    $script:seenForm=$sync.formStamp
    $fxItems=@()
    foreach($ln in ([string]$sync.formText -split "`r?`n")){
      $fp=$ln -split '\|'
      if($fp.Count -ge 2 -and $fp[0].Trim() -and $fp[1].Trim()){ $fxItems+=@{ n=$fp[0].Trim(); f=$fp[1].Trim(); d=$(if($fp.Count -ge 3){ $fp[2].Trim() }else{ "" }) } }
    }
    $fxJson=$(if($fxItems.Count -gt 0){ ConvertTo-Json @($fxItems) -Compress -Depth 4 }else{ "[]" })
    if($fxItems.Count -gt 0 -and $sync.sheetPurpose){ $script:fxCache[[string]$sync.sheetPurpose]=$fxJson }
    JS $script:wvP ("XC.setFormulas("+$fxJson+")")
  }
  if($sync.idStamp -gt $script:seenId){
    $script:seenId=$sync.idStamp
    $idItems=@()
    foreach($ln in ([string]$sync.idText -split "`r?`n")){
      $ip=$ln -split '\|'
      if($ip.Count -ge 2 -and $ip[0].Trim() -and $ip[1].Trim()){ $idItems+=@{ c=$ip[0].Trim(); n=$ip[1].Trim(); d=$(if($ip.Count -ge 3){ $ip[2].Trim() }else{ "" }) } }
    }
    $idJson=$(if($idItems.Count -gt 0){ ConvertTo-Json @($idItems) -Compress -Depth 4 }else{ "[]" })
    if($idItems.Count -gt 0){ $script:idCache=@{ key=$script:idPendingKey; json=$idJson } }
    JS $script:wvP ("XC.setIdents("+$idJson+")")
  }
  if($sync.xlStamp -gt $script:seenXl){
    $script:seenXl=$sync.xlStamp; $rx=[string]$sync.xlText
    if($rx -match '^GUIDE: '){
      $gmsg=$rx.Substring(7)
      $script:xlNudgeShown=$true; $script:lastActive=(Get-Date)
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#2563eb' $false
      Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $gmsg }else{ $gmsg }); $script:lastFull=$gmsg
      if(Get-Command Show-Answer -ErrorAction SilentlyContinue){ Show-Answer $gmsg 'guide' 0; Set-Query "Your next step" }
      if(-not $sync.mute){ $sync.ttsText=$gmsg }
      $script:baseStatus="On track - guiding"
    }
    elseif($rx -eq "OK"){
      if($script:xlNudgeShown){ $script:xlNudgeShown=$false; if($script:curIssue){ try{ JS $script:wvP ("XC.markFixed("+[int]$script:curIssue+")") }catch{} }; if(-not $script:askBusy){ Set-Dot '#22c55e' $true; $script:idle=$true; $script:baseStatus="Fixed - nice." } }
    }
    elseif($rx -ne ""){
      $script:xlNudgeShown=$true; $script:lastActive=(Get-Date)
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#d4a017' $false; Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $rx }else{ $rx }); $script:lastFull=$rx
      $dupX=$false; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $dupX=(XC-SameIssue $rx $sync.lastNudge) } else { $dupX=($rx -eq $sync.lastNudge) }
      if(-not $dupX){ Log-Watch $rx $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$rx } elseif(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{ [System.Media.SystemSounds]::Asterisk.Play() } } }
      $sync.lastNudge=$rx
      if(Get-Command Show-Answer -ErrorAction SilentlyContinue){ $script:curIssue=([int]$script:curIssue)+1; Show-Answer $rx 'issue' $script:curIssue; Set-Query "Issue to fix" }
    }
  }
  # v4 streaming: while the worker streams tokens, push the growing partial to the panel (no TTS /
  # no history entry). The guard stops once the final answer (stamp) is ready - the block below then
  # renders the full markdown + speaks it, replacing the partial.
  if(($sync.streamStamp -gt $script:seenStream) -and ($sync.stamp -le $script:seen)){
    $script:seenStream=$sync.streamStamp; $sp=[string]$sync.streamText
    if($sp){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; if(-not $panel.Visible){ Place-PanelHome; $panel.Show() }; JS $script:wvP ("XC.streamAnswer("+(ConvertTo-Json $sp)+")") }
  }
  if($sync.stamp -gt $script:seen){
    $script:seen=$sync.stamp; $r=$sync.text
    if($r -ne "OK" -and $r -ne ""){ $script:lastActive=(Get-Date) }
    if($sync.isAnswer){
      $script:askBusy=$false; $script:busySince=$null; JS $script:wvS ("XC.busy(false)")
      $lbl=[string]$sync.askLabel; $sync.askLabel=""
      if($sync.cancelled){ $sync.cancelled=$false; $script:idle=$true; Set-Dot '#22c55e' $true; $script:baseStatus="Cancelled" }
      elseif($r -ne "" -and $r -ne "OK"){ if($script:collapsed){ $script:collapsed=$false; Apply-Strip }; $script:idle=$false; Set-Dot '#2563eb' $false; Set-Msg $(if($lbl){ "Answer ready" }else{ "Answer ready - I'm listening if you have a follow-up" }); Show-Answer $r; Set-Query $(if($lbl){ $lbl }else{ "Voice question" }); Log-Watch ("[you asked] "+$r) $sync.lesson; if(-not $sync.mute){ $sync.ttsText=$r }; $script:baseStatus="On track" }
      else { $script:idle=$true; Set-Dot '#22c55e' $true }
    }
    elseif($r -eq "OK" -or $r -eq ""){
      if(-not $script:xlNudgeShown){
        Set-Dot '#22c55e' $true; $script:idle=$true
        if($sync.chatOn){ $script:baseStatus="Chat - just talk (say 'thanks coach' to end)" }
        elseif($sync.isPaused){ $script:baseStatus="Watching your work" }
        else { $lt=[string]$sync.lesson; if($lt.Length -gt 52){ $lt=$lt.Substring($lt.Length-52) }; $lt=$lt.Trim(); $script:baseStatus=if($lt){ "Hearing: ..."+$lt }else{ "Listening to the lesson" } }
      }
    }
    else {
      if($script:collapsed){ $script:collapsed=$false; Apply-Strip }
      $script:idle=$false; Set-Dot '#d4a017' $false; Set-Msg $(if(Get-Command Speakable -ErrorAction SilentlyContinue){ Speakable $r }else{ $r }); $script:lastFull=$r
      $dup=$false; if(Get-Command XC-SameIssue -ErrorAction SilentlyContinue){ $dup=(XC-SameIssue $r $sync.lastNudge) } else { $dup=($r -eq $sync.lastNudge) }
      if(-not $dup){ Log-Watch $r $sync.lesson; if($sync.isPaused -and -not $sync.mute){ $sync.ttsText=$r } elseif(-not $sync.muteSound){ try{ (New-Object System.Media.SoundPlayer $sync.chime).Play() }catch{ [System.Media.SystemSounds]::Asterisk.Play() } } }
      $sync.lastNudge=$r
    }
  }
})
$sync.mute=$true
$script:statusText="Listening to the lesson"
$strip.Add_Shown({
  Dismiss-Load     # reload "not an error" flags so the watcher keeps respecting them across restarts
  WO-LoadSession   # crash-resume: restore an in-flight run-through sitting (resumes when the student next opens Run-through)
  $ui.Start()
  # NOTE: the old XC_UIPROBE env-var auto-demo was removed - if that var was ever left set it
  # stranded a live coach in a fake "PP&E error" demo on every launch. The real demo is the
  # Demo Coach shortcut (writes act:demo -> Start-Demo), which is explicit and one-shot.
})
[void]$strip.ShowDialog()
try{ $sync.stop=$true; Kill-FF; $rs.Close(); $rsT.Close(); $rsX.Close() }catch{}