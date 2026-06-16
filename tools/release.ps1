# release.ps1 - build-and-publish tool for Excel Coach (Windows desktop app)
# Packages shippable files into a versioned zip, computes SHA-256, writes
# latest.json update manifest, and optionally publishes a GitHub release.
# Windows PowerShell 5.1 compatible. ASCII only.

$script:RelOwner = 'jonahkazam-svg'
$script:RelRepo  = 'excel-coach'

function Get-RepoRoot {
    $root = $null
    if ($PSScriptRoot) {
        $root = Split-Path -Parent $PSScriptRoot
    }
    if (-not $root) {
        $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
    }
    return $root
}

function Read-Version {
    $root = Get-RepoRoot
    $verPath = Join-Path $root 'VERSION'
    if (-not (Test-Path -LiteralPath $verPath)) {
        return '0.0.0'
    }
    $raw = Get-Content -LiteralPath $verPath -Raw
    if (-not $raw) {
        return '0.0.0'
    }
    $first = (($raw -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 } | Select-Object -First 1)
    if ($null -eq $first) {
        return '0.0.0'
    }
    $first = $first.Trim()
    if ($first.StartsWith('v')) {
        $first = $first.Substring(1)
    }
    return $first.Trim()
}

function Set-Version {
    param([string]$v)
    if ($v -notmatch '^\d+\.\d+\.\d+$') {
        throw "Invalid version '$v'. Expected semver like 2.0.0 (MAJOR.MINOR.PATCH)."
    }
    $root = Get-RepoRoot
    $verPath = Join-Path $root 'VERSION'
    [IO.File]::WriteAllText($verPath, $v, (New-Object System.Text.UTF8Encoding($false)))
    return $v
}

function Build-Release {
    param(
        [string]$Version,
        [string]$Notes
    )

    if ($Version) {
        $Version = Set-Version $Version
    } else {
        $Version = Read-Version
    }

    $root = Get-RepoRoot

    # Staging: $env:TEMP\xc_rel_<version>\excel-coach
    $stageBase = Join-Path $env:TEMP ('xc_rel_' + $Version)
    if (Test-Path -LiteralPath $stageBase) {
        Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue
    }
    $stageApp = Join-Path $stageBase 'excel-coach'
    New-Item -ItemType Directory -Path $stageApp -Force | Out-Null

    # Subfolders inside the staged app
    $stageTools    = Join-Path $stageApp 'tools'
    $stageUi       = Join-Path $stageTools 'ui'
    $stageWebview2 = Join-Path $stageTools 'webview2'
    $stageData     = Join-Path $stageApp 'data'
    New-Item -ItemType Directory -Path $stageTools -Force | Out-Null
    New-Item -ItemType Directory -Path $stageUi -Force | Out-Null
    New-Item -ItemType Directory -Path $stageWebview2 -Force | Out-Null
    New-Item -ItemType Directory -Path $stageData -Force | Out-Null

    # Source folders
    $srcTools    = Join-Path $root 'tools'
    $srcUi       = Join-Path $srcTools 'ui'
    $srcWebview2 = Join-Path $srcTools 'webview2'
    $srcData     = Join-Path $root 'data'

    # tools\*.ps1 (all .ps1 files in tools\)
    $psFiles = Get-ChildItem -LiteralPath $srcTools -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    foreach ($f in $psFiles) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stageTools $f.Name) -Force
    }

    # tools\ui\* (panel.html, strip.html and anything else there)
    if (Test-Path -LiteralPath $srcUi) {
        $uiFiles = Get-ChildItem -LiteralPath $srcUi -File -ErrorAction SilentlyContinue
        foreach ($f in $uiFiles) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stageUi $f.Name) -Force
        }
    }

    # tools\webview2\* (the .dll files)
    if (Test-Path -LiteralPath $srcWebview2) {
        $wvFiles = Get-ChildItem -LiteralPath $srcWebview2 -File -ErrorAction SilentlyContinue
        foreach ($f in $wvFiles) {
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $stageWebview2 $f.Name) -Force
        }
    }

    # data\deck.json and data\scope.json
    $dataFiles = @('deck.json', 'scope.json')
    foreach ($name in $dataFiles) {
        $srcFile = Join-Path $srcData $name
        if (Test-Path -LiteralPath $srcFile) {
            Copy-Item -LiteralPath $srcFile -Destination (Join-Path $stageData $name) -Force
        }
    }

    # VERSION (repo root) - copy current value
    $verSrc = Join-Path $root 'VERSION'
    if (Test-Path -LiteralPath $verSrc) {
        Copy-Item -LiteralPath $verSrc -Destination (Join-Path $stageApp 'VERSION') -Force
    } else {
        # Ensure a VERSION file exists in the package even if root one is absent
        [IO.File]::WriteAllText((Join-Path $stageApp 'VERSION'), $Version, (New-Object System.Text.UTF8Encoding($false)))
    }

    # Optional root files: copy only if present
    $optionalRootFiles = @('Start-Coach.ps1', 'install.ps1', 'README.md')
    foreach ($name in $optionalRootFiles) {
        $srcFile = Join-Path $root $name
        if (Test-Path -LiteralPath $srcFile) {
            Copy-Item -LiteralPath $srcFile -Destination (Join-Path $stageApp $name) -Force
        }
    }

    # dist\ folder
    $distDir = Join-Path $root 'dist'
    if (-not (Test-Path -LiteralPath $distDir)) {
        New-Item -ItemType Directory -Path $distDir -Force | Out-Null
    }

    # Zip the staged 'excel-coach' folder so archive top entry is excel-coach\...
    $zipName = 'excel-coach-' + $Version + '.zip'
    $zipPath = Join-Path $distDir $zipName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
    Compress-Archive -Path $stageApp -DestinationPath $zipPath -Force

    # SHA-256 (lower-case)
    $hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLower()

    # Download URL built from config + version
    $tag = 'v' + $Version
    $downloadUrl = 'https://github.com/' + $script:RelOwner + '/' + $script:RelRepo + '/releases/download/' + $tag + '/' + $zipName

    # Notes default
    $notesValue = $Notes
    if (-not $notesValue) {
        $notesValue = 'Release v' + $Version
    }

    # latest.json manifest (UTF-8 no BOM)
    $manifest = [PSCustomObject]@{
        version = $Version
        url     = $downloadUrl
        sha256  = $hash
        notes   = $notesValue
    }
    $manifestJson = $manifest | ConvertTo-Json
    $manifestPath = Join-Path $distDir 'latest.json'
    [IO.File]::WriteAllText($manifestPath, $manifestJson, (New-Object System.Text.UTF8Encoding($false)))

    # Best-effort cleanup of temp staging
    if (Test-Path -LiteralPath $stageBase) {
        Remove-Item -LiteralPath $stageBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    $result = [PSCustomObject]@{
        version      = $Version
        zipPath      = $zipPath
        manifestPath = $manifestPath
        sha256       = $hash
        url          = $downloadUrl
    }

    Write-Host ('Built Excel Coach release v' + $Version)
    Write-Host ('  zip:    ' + $zipPath)
    Write-Host ('  sha256: ' + $hash)

    return $result
}

function Publish-Release {
    param(
        [string]$Version,
        [string]$Notes
    )

    $build = Build-Release -Version $Version -Notes $Notes

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) {
        Write-Host 'ERROR: gh CLI not found on PATH. Skipping publish. Build artifacts are in dist\.'
        return $build
    }

    $tag = 'v' + $build.version
    $repoArg = $script:RelOwner + '/' + $script:RelRepo
    $titleArg = 'Excel Coach v' + $build.version

    $notesValue = $Notes
    if (-not $notesValue) {
        $notesValue = 'Release v' + $build.version
    }

    $ghArgs = @(
        'release', 'create', $tag,
        $build.zipPath, $build.manifestPath,
        '--repo', $repoArg,
        '--title', $titleArg,
        '--notes', $notesValue
    )

    & gh @ghArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host ('ERROR: gh release create failed with exit code ' + $LASTEXITCODE + '. Build artifacts are in dist\.')
    } else {
        Write-Host ('Published GitHub release ' + $tag + ' to ' + $repoArg)
    }

    return $build
}

# ENTRY POINT
# Running directly: build only (no publish). Publishing is done explicitly by
# calling Publish-Release. Dot-sourcing does NOT auto-run.
if($MyInvocation.InvocationName -ne '.' -and $MyInvocation.Line -notmatch '^\s*\.\s'){
    Build-Release | Out-Null
}
