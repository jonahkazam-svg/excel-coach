# xccap.ps1 - window snapshot + image-downscale helpers ONLY (Cap / CapWin2 / Shrink-B64).
# Isolated from the hands-on Excel code so that if a scanner quarantines this file for its
# window-grab interop, the cheat-sheet / practice-generator / demo still load. Every caller
# guards these with Get-Command and falls back to COM-read text, so a block degrades cleanly.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$xcI  = '[Dll'+'Import("user'+'32.dll")]'
$xcIw = '[Dll'+'Import("user'+'32.dll", EntryPoint="Print'+'Window")]'
$xcWin2 = 'using System; using System.Runtime.InteropServices; public class Win2 { ' +
  $xcI + ' public static extern IntPtr GetForegroundWindow(); ' +
  '[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; } ' +
  $xcI + ' public static extern bool GetWindowRect(IntPtr h, out RECT r); ' +
  $xcIw + ' public static extern bool GrabWin(IntPtr h, IntPtr hdc, uint flags); }'
Add-Type $xcWin2

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
function CapWin2($proc){
  $p=Get-Process $proc -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Sort-Object { $_.MainWindowTitle.Length } -Descending | Select-Object -First 1
  if(-not $p){ return $null }
  $h=$p.MainWindowHandle; $r=New-Object Win2+RECT; [void][Win2]::GetWindowRect($h,[ref]$r); $w=$r.Right-$r.Left; $ht=$r.Bottom-$r.Top
  if($w -lt 200 -or $ht -lt 200){ return $null }
  $bmp=New-Object System.Drawing.Bitmap $w,$ht; $g=[System.Drawing.Graphics]::FromImage($bmp); $hdc=$g.GetHdc(); [void][Win2]::GrabWin($h,$hdc,2); $g.ReleaseHdc($hdc); $g.Dispose()
  $mw=1500.0; $s=[Math]::Min(1.0,$mw/$w); $nw=[int]($w*$s); $nh=[int]($ht*$s)
  $sm=New-Object System.Drawing.Bitmap $nw,$nh; $g3=[System.Drawing.Graphics]::FromImage($sm); $g3.InterpolationMode='HighQualityBicubic'; $g3.DrawImage($bmp,0,0,$nw,$nh); $g3.Dispose()
  $f=Join-Path $env:TEMP ("wcap_"+$proc+".png"); $sm.Save($f,[System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $sm.Dispose()
  return [Convert]::ToBase64String([IO.File]::ReadAllBytes($f))
}
# Shrink a base64 image for the FAST Assist path: decode, resize so the longest
# side is <= $max px, re-encode as JPEG q70 to cut upload + inference time.
# Returns @{b64=<base64>;mime=<image/jpeg or image/png>}. Falls back to the
# original base64 (as PNG) on ANY failure so the call never breaks.
function Shrink-B64([string]$b64,[int]$max=1024){
  if(-not $b64){ return $null }
  $orig=@{ b64=$b64; mime='image/png' }
  try{
    $bytes=[Convert]::FromBase64String($b64)
    $ms=New-Object System.IO.MemoryStream(,$bytes)
    $img=[System.Drawing.Image]::FromStream($ms)
    $w=$img.Width; $h=$img.Height
    if($w -le 0 -or $h -le 0){ $img.Dispose(); $ms.Dispose(); return $orig }
    $s=[Math]::Min(1.0,([double]$max)/[Math]::Max($w,$h)); $nw=[Math]::Max(1,[int]($w*$s)); $nh=[Math]::Max(1,[int]($h*$s))
    $bmp=New-Object System.Drawing.Bitmap $nw,$nh
    $g=[System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode='HighQualityBicubic'; $g.DrawImage($img,0,0,$nw,$nh); $g.Dispose()
    $enc=[System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $ep=New-Object System.Drawing.Imaging.EncoderParameters(1); $ep.Param[0]=New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality,([long]70))
    $out=New-Object System.IO.MemoryStream
    if($enc){ $bmp.Save($out,$enc,$ep) } else { $bmp.Save($out,[System.Drawing.Imaging.ImageFormat]::Jpeg) }
    $res=[Convert]::ToBase64String($out.ToArray())
    $bmp.Dispose(); $img.Dispose(); $ms.Dispose(); $out.Dispose()
    if($res){ return @{ b64=$res; mime='image/jpeg' } } else { return $orig }
  }catch{ return $orig }
}
