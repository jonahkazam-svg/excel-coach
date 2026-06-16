# prereqs.ps1 - reusable helpers to ensure Excel Coach prerequisites are present:
# the Microsoft Edge WebView2 Evergreen runtime, and ffmpeg.exe.
# This file is safe to dot-source: only function definitions run at import time.
# ASCII only. Windows PowerShell 5.1 compatible. Functions never throw.

function Test-WebView2Runtime {
    # Returns $true if the WebView2 Evergreen runtime is installed, else $false. Never throws.
    try {
        $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
        $keys = @(
            ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\' + $guid),
            ('HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\' + $guid),
            ('HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\' + $guid)
        )
        foreach ($key in $keys) {
            try {
                $item = Get-ItemProperty -Path $key -Name 'pv' -ErrorAction SilentlyContinue
            } catch {
                $item = $null
            }
            if ($item) {
                $pv = $item.pv
                if ($pv -and ($pv -ne '0.0.0.0')) {
                    return $true
                }
            }
        }
        return $false
    } catch {
        return $false
    }
}

function Install-WebView2Runtime {
    # Ensures the WebView2 Evergreen runtime is present. Returns $true on success, else $false. Never throws.
    try {
        if (Test-WebView2Runtime) {
            return $true
        }
        Write-Host 'Installing WebView2 runtime...'
        $url = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'
        $tmp = Join-Path -Path $env:TEMP -ChildPath ('MicrosoftEdgeWebview2Setup_' + [Guid]::NewGuid().ToString('N') + '.exe')
        try {
            Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 180
            $proc = Start-Process -FilePath $tmp -ArgumentList '/silent','/install' -Wait -PassThru
            $exit = -1
            if ($proc) {
                $exit = $proc.ExitCode
            }
            if ($exit -eq 0) {
                return $true
            }
            if (Test-WebView2Runtime) {
                return $true
            }
            return $false
        } finally {
            if (Test-Path -LiteralPath $tmp) {
                Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        return $false
    }
}

function Get-FfmpegPath {
    # Returns a path to a usable ffmpeg.exe, or $null if none found. Never throws.
    try {
        $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source) {
            return $cmd.Source
        }

        $toolsDir = $PSScriptRoot
        if (-not $toolsDir) {
            $toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        $repoRoot = Split-Path -Parent $toolsDir
        $binPath = Join-Path -Path $repoRoot -ChildPath 'bin\ffmpeg.exe'
        if (Test-Path -LiteralPath $binPath) {
            return $binPath
        }

        $pkgRoot = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Microsoft\WinGet\Packages'
        if (Test-Path -LiteralPath $pkgRoot) {
            $found = Get-ChildItem -Path $pkgRoot -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($found) {
                return $found.FullName
            }
        }

        return $null
    } catch {
        return $null
    }
}

function Install-Ffmpeg {
    # Ensures ffmpeg.exe is available, downloading a static build into $DestDir if needed.
    # Returns the ffmpeg.exe path, or $null on failure. Never throws.
    param(
        [string]$DestDir
    )
    try {
        $existing = Get-FfmpegPath
        if ($existing) {
            return $existing
        }

        if (-not $DestDir) {
            return $null
        }
        if (-not (Test-Path -LiteralPath $DestDir)) {
            New-Item -ItemType Directory -Path $DestDir -Force -ErrorAction SilentlyContinue | Out-Null
        }
        if (-not (Test-Path -LiteralPath $DestDir)) {
            return $null
        }

        $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        $stamp = [Guid]::NewGuid().ToString('N')
        $tmpZip = Join-Path -Path $env:TEMP -ChildPath ('ffmpeg_' + $stamp + '.zip')
        $tmpDir = Join-Path -Path $env:TEMP -ChildPath ('ffmpeg_extract_' + $stamp)
        try {
            Write-Host 'Downloading ffmpeg (one-time, ~80 MB)...'
            Invoke-WebRequest -Uri $url -OutFile $tmpZip -UseBasicParsing -TimeoutSec 600
            Write-Host 'Extracting ffmpeg...'
            Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

            $ffmpeg = Get-ChildItem -Path $tmpDir -Recurse -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $ffmpeg) {
                return $null
            }

            $destFfmpeg = Join-Path -Path $DestDir -ChildPath 'ffmpeg.exe'
            Copy-Item -LiteralPath $ffmpeg.FullName -Destination $destFfmpeg -Force

            $srcDir = Split-Path -Parent $ffmpeg.FullName
            $srcProbe = Join-Path -Path $srcDir -ChildPath 'ffprobe.exe'
            if (Test-Path -LiteralPath $srcProbe) {
                $destProbe = Join-Path -Path $DestDir -ChildPath 'ffprobe.exe'
                Copy-Item -LiteralPath $srcProbe -Destination $destProbe -Force
            }

            if (Test-Path -LiteralPath $destFfmpeg) {
                return $destFfmpeg
            }
            return $null
        } finally {
            if (Test-Path -LiteralPath $tmpZip) {
                Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
            }
            if (Test-Path -LiteralPath $tmpDir) {
                Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        return $null
    }
}
