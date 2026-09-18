param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [ValidateSet('Apply', 'Remove', 'Status')][string]$Action = 'Apply'
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$relativeTarget = 'packages/core/tools/src/index.ts'
$targetPath = Join-Path $HarnessPath ($relativeTarget -replace '/', '\')
$statePath = Join-Path $HarnessPath '.git\dsh-launcher-core-compatibility.json'
$legacyDeclaration = "export const TOOL_RUNTIME_SCHEDULER: unique symbol = Symbol('@deepseek-ai/dsh-tools.scheduler')"
$stableDeclaration = "export const TOOL_RUNTIME_SCHEDULER: unique symbol = Symbol.for('@deepseek-ai/dsh-tools.scheduler')"

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-RepositoryCommit {
    $git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if ($null -eq $git) { return '' }
    $commit = (& $git.Source -C $HarnessPath rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) { return '' }
    return $commit
}

function Test-TargetIsClean {
    $git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
    if ($null -eq $git) { return $false }
    & $git.Source -C $HarnessPath diff --quiet -- $relativeTarget
    return $LASTEXITCODE -eq 0
}

function Read-State {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try {
        return Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "The managed core compatibility state is unreadable: $statePath"
    }
}

function Save-State {
    param([Parameter(Mandatory)][string]$OriginalSha, [Parameter(Mandatory)][string]$PatchedSha)

    $state = [ordered]@{
        schemaVersion = 1
        patchId = 'tool-runtime-scheduler-global-symbol-v1'
        target = $relativeTarget
        baseCommit = Get-RepositoryCommit
        originalSha256 = $OriginalSha
        patchedSha256 = $PatchedSha
        appliedAt = (Get-Date).ToString('o')
    }
    [System.IO.File]::WriteAllText(
        $statePath,
        ($state | ConvertTo-Json -Depth 5) + [Environment]::NewLine,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Get-CompatibilityStatus {
    if (-not (Test-Path -LiteralPath $targetPath)) {
        throw "Harness scheduler declaration was not found: $targetPath"
    }
    $content = [System.IO.File]::ReadAllText($targetPath)
    $hasLegacy = $content.Contains($legacyDeclaration)
    $hasStable = $content.Contains($stableDeclaration)
    if ($hasLegacy -and $hasStable) { throw 'Both legacy and stable scheduler declarations were found; refusing an ambiguous edit.' }
    if (-not $hasLegacy -and -not $hasStable) { return 'unsupported' }
    if ($hasLegacy) { return 'vulnerable' }
    if (Test-TargetIsClean) { return 'official-fixed' }

    $state = Read-State
    if ($null -ne $state -and [string]$state.patchId -eq 'tool-runtime-scheduler-global-symbol-v1' -and
        [string]$state.patchedSha256 -eq (Get-Sha256 -Path $targetPath)) {
        return 'managed-active'
    }
    return 'modified-unmanaged'
}

$status = Get-CompatibilityStatus
if ($Action -eq 'Status') {
    Write-Output "[DSH][CoreCompatibility][$($status.ToUpperInvariant())] $relativeTarget"
    if ($status -in @('unsupported', 'modified-unmanaged')) { exit 2 }
    exit 0
}

if ($Action -eq 'Apply') {
    if ($status -eq 'official-fixed') {
        Write-Output "[DSH][CoreCompatibility][OFFICIAL-FIXED] Upstream already provides a stable scheduler identity."
        exit 0
    }
    if ($status -eq 'managed-active') {
        Write-Output "[DSH][CoreCompatibility][CURRENT] Managed scheduler compatibility is already active."
        exit 0
    }
    if ($status -ne 'vulnerable') {
        throw "The scheduler source is '$status'; no automatic compatibility edit is safe."
    }

    $originalSha = Get-Sha256 -Path $targetPath
    $content = [System.IO.File]::ReadAllText($targetPath)
    $replacementCount = ([regex]::Matches($content, [regex]::Escape($legacyDeclaration))).Count
    if ($replacementCount -ne 1) { throw "Expected one legacy scheduler declaration, found $replacementCount." }
    $patched = $content.Replace($legacyDeclaration, $stableDeclaration)
    [System.IO.File]::WriteAllText($targetPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
    Save-State -OriginalSha $originalSha -PatchedSha (Get-Sha256 -Path $targetPath)
    Write-Output '[DSH][CoreCompatibility][APPLIED] Scheduler identity now survives duplicate module instances.'
    exit 0
}

if ($status -eq 'vulnerable') {
    Write-Output '[DSH][CoreCompatibility][REMOVED] Managed compatibility is already absent.'
    exit 0
}
if ($status -eq 'official-fixed') {
    Write-Output '[DSH][CoreCompatibility][OFFICIAL-FIXED] Upstream fix is clean and will not be removed.'
    exit 0
}
if ($status -ne 'managed-active') {
    throw "The scheduler source is '$status'; refusing to overwrite a non-managed edit."
}

$state = Read-State
$currentSha = Get-Sha256 -Path $targetPath
if ([string]$state.patchedSha256 -ne $currentSha) { throw 'The managed target changed after patching; refusing to remove it.' }
$content = [System.IO.File]::ReadAllText($targetPath)
$replacementCount = ([regex]::Matches($content, [regex]::Escape($stableDeclaration))).Count
if ($replacementCount -ne 1) { throw "Expected one stable scheduler declaration, found $replacementCount." }
$restored = $content.Replace($stableDeclaration, $legacyDeclaration)
[System.IO.File]::WriteAllText($targetPath, $restored, (New-Object System.Text.UTF8Encoding($false)))
if (-not (Test-TargetIsClean)) {
    [System.IO.File]::WriteAllText($targetPath, $content, (New-Object System.Text.UTF8Encoding($false)))
    throw 'Removing the managed patch did not restore the Git version; the patched file was put back.'
}
Write-Output '[DSH][CoreCompatibility][REMOVED] Managed patch was temporarily removed for a clean core update.'
