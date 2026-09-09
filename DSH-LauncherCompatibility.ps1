param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [string]$LauncherRoot = $PSScriptRoot,
    [switch]$RuntimeProbe,
    [switch]$Record
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$LauncherRoot = [System.IO.Path]::GetFullPath($LauncherRoot)
$manifestPath = Join-Path $LauncherRoot 'launcher-manifest.json'

function ConvertTo-SemVer {
    param([Parameter(Mandatory)][string]$Value)

    $match = [regex]::Match($Value.Trim(), '^(?<major>\d+)[.](?<minor>\d+)[.](?<patch>\d+)(?:-(?<pre>[0-9A-Za-z.-]+))?(?:[+][0-9A-Za-z.-]+)?$')
    if (-not $match.Success) { throw "Invalid semantic version: $Value" }
    [pscustomobject]@{
        Text = $Value.Trim()
        Core = @([int]$match.Groups['major'].Value, [int]$match.Groups['minor'].Value, [int]$match.Groups['patch'].Value)
        Pre = if ($match.Groups['pre'].Success) { @($match.Groups['pre'].Value.Split('.')) } else { @() }
    }
}

function Compare-SemVer {
    param([Parameter(Mandatory)]$Left, [Parameter(Mandatory)]$Right)

    for ($index = 0; $index -lt 3; $index++) {
        if ($Left.Core[$index] -gt $Right.Core[$index]) { return 1 }
        if ($Left.Core[$index] -lt $Right.Core[$index]) { return -1 }
    }
    if ($Left.Pre.Count -eq 0 -and $Right.Pre.Count -eq 0) { return 0 }
    if ($Left.Pre.Count -eq 0) { return 1 }
    if ($Right.Pre.Count -eq 0) { return -1 }
    $count = [Math]::Max($Left.Pre.Count, $Right.Pre.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $Left.Pre.Count) { return -1 }
        if ($index -ge $Right.Pre.Count) { return 1 }
        $leftNumber = 0
        $rightNumber = 0
        $leftNumeric = [int]::TryParse($Left.Pre[$index], [ref]$leftNumber)
        $rightNumeric = [int]::TryParse($Right.Pre[$index], [ref]$rightNumber)
        if ($leftNumeric -and $rightNumeric) {
            if ($leftNumber -gt $rightNumber) { return 1 }
            if ($leftNumber -lt $rightNumber) { return -1 }
            continue
        }
        if ($leftNumeric) { return -1 }
        if ($rightNumeric) { return 1 }
        $comparison = [string]::CompareOrdinal($Left.Pre[$index], $Right.Pre[$index])
        if ($comparison -ne 0) { return [Math]::Sign($comparison) }
    }
    return 0
}

if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Launcher compatibility manifest was not found: $manifestPath" }
$launcherManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$launcherManifest.schemaVersion -ne 1) { throw "Unsupported launcher compatibility manifest schema: $($launcherManifest.schemaVersion)" }

foreach ($relativePath in @($launcherManifest.launcher.requiredFiles)) {
    if (-not (Test-Path -LiteralPath (Join-Path $LauncherRoot ([string]$relativePath)))) {
        throw "Launcher file required by the compatibility contract is missing: $relativePath"
    }
}

$parseFailures = @()
foreach ($scriptFile in @(Get-ChildItem -LiteralPath $LauncherRoot -Filter '*.ps1' -File)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { $parseFailures += "$($scriptFile.Name): $($errors[0].Message)" }
}
if ($parseFailures.Count -gt 0) { throw "Launcher PowerShell validation failed: $($parseFailures -join '; ')" }

$corePackagePath = Join-Path $HarnessPath 'package.json'
if (-not (Test-Path -LiteralPath $corePackagePath)) { throw "Harness package manifest was not found: $corePackagePath" }
$corePackage = Get-Content -LiteralPath $corePackagePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$corePackage.name -ne [string]$launcherManifest.core.packageName) {
    throw "Unexpected Harness root package '$($corePackage.name)'; expected '$($launcherManifest.core.packageName)'."
}
$coreVersion = ConvertTo-SemVer ([string]$corePackage.version)
$minimumVersion = ConvertTo-SemVer ([string]$launcherManifest.core.minimumVersion)
if ((Compare-SemVer $coreVersion $minimumVersion) -lt 0) {
    throw "Harness $($coreVersion.Text) is older than the launcher compatibility floor $($minimumVersion.Text)."
}
foreach ($scriptName in @($launcherManifest.core.requiredScripts)) {
    if ($null -eq $corePackage.scripts.PSObject.Properties[[string]$scriptName]) { throw "Harness no longer exposes the required pnpm script: $scriptName" }
}
foreach ($relativePath in @($launcherManifest.core.requiredPaths)) {
    if (-not (Test-Path -LiteralPath (Join-Path $HarnessPath ([string]$relativePath)))) { throw "Harness no longer exposes the required launcher path: $relativePath" }
}

$coreCommit = ''
$git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
if ($null -ne $git -and (Test-Path -LiteralPath (Join-Path $HarnessPath '.git'))) {
    $coreCommit = (& $git.Source -C $HarnessPath rev-parse HEAD 2>$null).Trim()
}

if ($RuntimeProbe) {
    $pnpm = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
    if ($null -eq $pnpm) { throw 'pnpm was not found for the Harness CLI compatibility probe.' }
    Push-Location -LiteralPath $HarnessPath
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $probeOutput = @(& $pnpm.Source 'dsh' '--help' 2>&1 | ForEach-Object { $_.ToString() })
        $probeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
    if ($probeExitCode -ne 0) {
        $probeTail = @($probeOutput | Select-Object -Last 5) -join ' | '
        throw "Harness CLI compatibility probe failed with exit code $probeExitCode. $probeTail"
    }
}

if ($Record) {
    $stateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    [ordered]@{
        schemaVersion = 1
        checkedAt = (Get-Date).ToString('o')
        status = 'compatible'
        launcherVersion = [string]$launcherManifest.version
        coreVersion = $coreVersion.Text
        coreCommit = $coreCommit
        runtimeProbe = [bool]$RuntimeProbe
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateRoot 'launcher-core-compatibility.json') -Encoding UTF8
}

$commitLabel = if ([string]::IsNullOrWhiteSpace($coreCommit)) { 'unknown commit' } else { $coreCommit.Substring(0, 8) }
$probeLabel = if ($RuntimeProbe) { ' with CLI probe' } else { '' }
Write-Output "[DSH][Compatibility][OK] Launcher $($launcherManifest.version) supports Harness $($coreVersion.Text) ($commitLabel)$probeLabel."
