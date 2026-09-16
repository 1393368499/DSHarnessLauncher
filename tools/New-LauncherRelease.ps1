<#
.SYNOPSIS
    Builds the DSH Launcher release archive.

.DESCRIPTION
    Packages the release file set of this checkout into
    DSH-Launcher-v<version>-win-x64.zip. The version comes from
    launcher-manifest.json unless -Version overrides it.

    Archive entries always use forward slashes, matching the earlier published
    archives: Windows Explorer, Expand-Archive and .NET's ExtractToDirectory
    accept that form, and string comparisons against entry names stay stable.

    The archive is written to artifacts\ and, unless -NoRootCopy is given, also
    to the repository root, where the published download lives. A staging
    directory is created beside the archive and removed afterwards.

.PARAMETER Version
    Release version, for example 2.0.1. Defaults to launcher-manifest.json.

.PARAMETER OutputDirectory
    Directory that receives the archive. Defaults to artifacts\ in the checkout.

.PARAMETER NoRootCopy
    Skip copying the archive to the repository root.

.EXAMPLE
    .\tools\New-LauncherRelease.ps1

.EXAMPLE
    .\tools\New-LauncherRelease.ps1 -Version 2.1.0 -OutputDirectory D:\tmp
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$OutputDirectory,

    [switch]$NoRootCopy
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$launcherRoot = Split-Path -Parent $PSScriptRoot
$manifestPath = Join-Path $launcherRoot 'launcher-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "launcher-manifest.json not found under $launcherRoot."
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = [string]$manifest.version }
if ([string]::IsNullOrWhiteSpace($Version)) {
    throw 'No version available: set launcher.version in launcher-manifest.json or pass -Version.'
}
if ([string]$manifest.version -ne $Version) {
    Write-Warning "launcher-manifest.json declares $($manifest.version); packaging $Version instead."
}

# The payload must mirror the published archive: launcher scripts, the compiled
# entry point, the window markup, the manifest, the runtime icon, the readme and
# the two images DSH-UI.ps1 resolves at runtime.
$payload = @(
    'DSH.exe'
    'DSH-Launcher.ps1'
    'DSH-LauncherCompatibility.ps1'
    'DSH-LauncherUpdater.ps1'
    'DSH-Diagnostics.ps1'
    'DSH-PluginManager.ps1'
    'DSH-PluginUpdater.ps1'
    'DSH-PluginCompatibility.ps1'
    'DSH-UI.ps1'
    'LauncherWindow.xaml'
    'Start-DSH-Web.cmd'
    'launcher-manifest.json'
    'DSH-unified-v5.ico'
    'README.md'
    'assets\DSH-white-frame-v5.png'
    'assets\DSHarness-v2.png'
)

$missing = @($payload | Where-Object { -not (Test-Path -LiteralPath (Join-Path $launcherRoot $_)) })
if ($missing.Count -gt 0) {
    throw "Release payload is incomplete: $($missing -join ', ')"
}

$packageName = "DSH-Launcher-v$Version-win-x64"
$outputRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    Join-Path $launcherRoot 'artifacts'
} else {
    $OutputDirectory
}
New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $outputRoot).Path

$stage = Join-Path $outputRoot "_stage\$packageName"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

foreach ($relative in $payload) {
    $target = Join-Path $stage $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $launcherRoot $relative) -Destination $target -Force
}

$archivePath = Join-Path $outputRoot "$packageName.zip"
if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }

$stream = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::CreateNew)
try {
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in (Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName)) {
            $relative = ($file.FullName.Substring($stage.Length + 1)) -replace '\\', '/'
            $entry = $archive.CreateEntry("$packageName/$relative", [System.IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $file.LastWriteTime
            $entryStream = $entry.Open()
            try {
                $source = [System.IO.File]::OpenRead($file.FullName)
                try { $source.CopyTo($entryStream) } finally { $source.Dispose() }
            } finally {
                $entryStream.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $stream.Dispose()
}

Remove-Item -LiteralPath $stage -Recurse -Force

# Verify the archive against the manifest before it can be published.
$verify = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $entryNames = @($verify.Entries | ForEach-Object { $_.FullName })
} finally {
    $verify.Dispose()
}
$absent = @($manifest.launcher.requiredFiles | Where-Object { $entryNames -notcontains "$packageName/$_" })
if ($absent.Count -gt 0) {
    Remove-Item -LiteralPath $archivePath -Force
    throw "Archive verification failed, missing: $($absent -join ', ')"
}

$archive = Get-Item -LiteralPath $archivePath
$hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
$rootCopy = Join-Path $launcherRoot $archive.Name
if (-not $NoRootCopy) { Copy-Item -LiteralPath $archivePath -Destination $rootCopy -Force }

Write-Host ''
Write-Host "package   : $packageName" -ForegroundColor Cyan
Write-Host "version   : $Version (launcher-manifest.json: $($manifest.version))"
Write-Host "entries   : $($entryNames.Count)"
Write-Host "size      : $('{0:N0}' -f $archive.Length) bytes"
Write-Host "sha256    : $hash"
Write-Host "archive   : $archivePath"
if (-not $NoRootCopy) { Write-Host "root copy : $rootCopy" }
Write-Host ''
