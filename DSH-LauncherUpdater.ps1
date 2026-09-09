param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [string]$LauncherRoot = $PSScriptRoot,
    [string[]]$PortableManifestSources,
    [switch]$NoApply
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$LauncherRoot = [System.IO.Path]::GetFullPath($LauncherRoot)
$manifestName = 'launcher-manifest.json'
$manifestPath = Join-Path $LauncherRoot $manifestName
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Launcher update manifest was not found: $manifestPath" }
$localManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$corePackage = Get-Content -LiteralPath (Join-Path $HarnessPath 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function ConvertTo-LauncherVersion {
    param([string]$Value)
    $parsed = $null
    if (-not [version]::TryParse($Value, [ref]$parsed)) { return $null }
    return $parsed
}

function Get-PortableSourceText {
    param([Parameter(Mandatory)][string]$Source)
    if ($Source -match '^https?://') {
        return [string](Invoke-WebRequest -UseBasicParsing -Uri $Source -TimeoutSec 20).Content
    }
    $resolved = [Environment]::ExpandEnvironmentVariables($Source)
    if (-not [System.IO.Path]::IsPathRooted($resolved)) { $resolved = Join-Path $LauncherRoot $resolved }
    return Get-Content -LiteralPath $resolved -Raw -Encoding UTF8
}

function Resolve-PortablePackageSource {
    param([Parameter(Mandatory)][string]$ManifestSource, [Parameter(Mandatory)][string]$PackageSource)
    if ($PackageSource -match '^https?://') { return $PackageSource }
    if ($ManifestSource -match '^https?://') {
        return ([Uri]::new([Uri]$ManifestSource, $PackageSource)).AbsoluteUri
    }
    $manifestFile = [Environment]::ExpandEnvironmentVariables($ManifestSource)
    if (-not [System.IO.Path]::IsPathRooted($manifestFile)) { $manifestFile = Join-Path $LauncherRoot $manifestFile }
    return Join-Path (Split-Path -Parent $manifestFile) $PackageSource
}

function Invoke-PortableLauncherUpdate {
    $sources = @()
    $sources += @($PortableManifestSources | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_LAUNCHER_UPDATE_MANIFESTS)) {
        $sources += @($env:DSH_LAUNCHER_UPDATE_MANIFESTS -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($null -ne $localManifest.update -and $null -ne $localManifest.update.manifestSources) {
        $sources += @($localManifest.update.manifestSources | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
    $sources += @(
        (Join-Path $LauncherRoot 'updates\launcher-update.json'),
        (Join-Path $env:LOCALAPPDATA 'DSH\launcher-update.json')
    )
    $sources = @($sources | Select-Object -Unique)

    $localVersion = ConvertTo-LauncherVersion ([string]$localManifest.version)
    if ($null -eq $localVersion) { throw "Installed launcher version is invalid: $($localManifest.version)" }
    $candidates = @()
    $checkedFeeds = 0
    foreach ($source in $sources) {
        try {
            if ($source -notmatch '^https?://') {
                $sourcePath = [Environment]::ExpandEnvironmentVariables($source)
                if (-not [System.IO.Path]::IsPathRooted($sourcePath)) { $sourcePath = Join-Path $LauncherRoot $sourcePath }
                if (-not (Test-Path -LiteralPath $sourcePath)) { continue }
            }
            $feed = Get-PortableSourceText $source | ConvertFrom-Json
            $checkedFeeds++
            if ([int]$feed.schemaVersion -ne 1) { continue }
            $feedVersion = ConvertTo-LauncherVersion ([string]$feed.version)
            if ($null -eq $feedVersion -or $feedVersion -le $localVersion) { continue }
            if ([string]::IsNullOrWhiteSpace([string]$feed.packageUrl) -or [string]::IsNullOrWhiteSpace([string]$feed.sha256)) { continue }
            $candidates += [pscustomobject]@{ Source = [string]$source; Feed = $feed; Version = $feedVersion }
        } catch {
            Write-Output "[DSH][LauncherUpdate][WARN] Portable update source failed: $source ($($_.Exception.Message))"
        }
    }
    $candidate = $candidates | Sort-Object Version -Descending | Select-Object -First 1
    if ($null -eq $candidate) {
        if ($checkedFeeds -eq 0) {
            Write-Output "[DSH][LauncherUpdate][SKIP] Portable launcher $($localManifest.version) has no published update feed configured."
        } else {
            Write-Output "[DSH][LauncherUpdate][OK] Portable launcher $($localManifest.version) is current on all configured feeds."
        }
        return
    }
    if ($NoApply) {
        Write-Output "[DSH][LauncherUpdate][UPDATE] Portable launcher update is available: $($localManifest.version) -> $($candidate.Feed.version)."
        return
    }

    $operationRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dsh-launcher-update-" + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $operationRoot 'launcher.zip'
    $extractPath = Join-Path $operationRoot 'package'
    $backupRoot = $null
    $appliedFiles = @()
    New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
    try {
        $packageSource = Resolve-PortablePackageSource $candidate.Source ([string]$candidate.Feed.packageUrl)
        if ($packageSource -match '^https?://') {
            Invoke-WebRequest -UseBasicParsing -Uri $packageSource -OutFile $archivePath -TimeoutSec 120
        } else {
            Copy-Item -LiteralPath $packageSource -Destination $archivePath -Force
        }
        $actualHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        if ($actualHash -ne ([string]$candidate.Feed.sha256).ToUpperInvariant()) { throw 'Portable launcher package SHA-256 verification failed.' }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractPath -Force
        $candidateManifests = @(Get-ChildItem -LiteralPath $extractPath -Filter $manifestName -File -Recurse)
        if ($candidateManifests.Count -ne 1) { throw 'Portable launcher package must contain exactly one launcher-manifest.json.' }
        $packageRoot = $candidateManifests[0].Directory.FullName
        $packageManifest = Get-Content -LiteralPath $candidateManifests[0].FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([int]$packageManifest.schemaVersion -ne 1 -or [string]$packageManifest.version -ne [string]$candidate.Feed.version) { throw 'Portable package manifest does not match its update feed.' }
        if ([string]$packageManifest.core.packageName -ne [string]$corePackage.name) { throw 'Portable package targets a different Harness core.' }
        $requiredFiles = @($packageManifest.launcher.requiredFiles) + $manifestName
        foreach ($relativeFile in $requiredFiles) {
            if ([string]::IsNullOrWhiteSpace([string]$relativeFile) -or [System.IO.Path]::IsPathRooted([string]$relativeFile) -or ([string]$relativeFile) -match '(^|[\\/])\.\.([\\/]|$)') { throw "Unsafe portable package path: $relativeFile" }
            if (-not (Test-Path -LiteralPath (Join-Path $packageRoot ([string]$relativeFile)))) { throw "Portable package is missing required file: $relativeFile" }
        }
        $compatibilityScript = Join-Path $packageRoot 'DSH-LauncherCompatibility.ps1'
        & 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $compatibilityScript -HarnessPath $HarnessPath -LauncherRoot $packageRoot
        if ($LASTEXITCODE -ne 0) { throw 'Portable launcher package failed compatibility validation.' }
        $backupRoot = Join-Path $env:LOCALAPPDATA ("DSH\launcher-backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        foreach ($relativeFile in $requiredFiles) {
            $destination = Join-Path $LauncherRoot ([string]$relativeFile)
            $backup = Join-Path $backupRoot ([string]$relativeFile)
            if (Test-Path -LiteralPath $destination) {
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                Copy-Item -LiteralPath $destination -Destination $backup -Force
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath (Join-Path $packageRoot ([string]$relativeFile)) -Destination $destination -Force
            $appliedFiles += [string]$relativeFile
        }
        Write-Output "[DSH][LauncherUpdate][OK] Portable launcher updated: $($localManifest.version) -> $($packageManifest.version). Backup: $backupRoot"
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($backupRoot) -and (Test-Path -LiteralPath $backupRoot)) {
            foreach ($relativeFile in $appliedFiles) {
                $destination = Join-Path $LauncherRoot $relativeFile
                $backup = Join-Path $backupRoot $relativeFile
                if (Test-Path -LiteralPath $backup) {
                    Copy-Item -LiteralPath $backup -Destination $destination -Force
                } elseif (Test-Path -LiteralPath $destination) {
                    Remove-Item -LiteralPath $destination -Force
                }
            }
        }
        throw
    } finally {
        if ($operationRoot.StartsWith([System.IO.Path]::GetTempPath(), [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $operationRoot)) {
            Remove-Item -LiteralPath $operationRoot -Recurse -Force
        }
    }
}

$git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
if ($null -eq $git) { throw 'git.exe was not found for the launcher update check.' }
$repositoryRoot = $null
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $repositoryOutput = & $git.Source -C $LauncherRoot rev-parse --show-toplevel 2>$null
    if ($null -ne $repositoryOutput) { $repositoryRoot = ($repositoryOutput | Select-Object -First 1).ToString().Trim() }
} catch {
    $repositoryRoot = $null
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
    Invoke-PortableLauncherUpdate
    exit 0
}
$repositoryRoot = [System.IO.Path]::GetFullPath($repositoryRoot)
if ($repositoryRoot.TrimEnd('\') -ne $LauncherRoot.TrimEnd('\')) {
    Write-Output '[DSH][LauncherUpdate][SKIP] Launcher is nested in a larger Git checkout; automatic repository-wide updates are disabled.'
    exit 0
}

$originUrl = (& $git.Source -C $repositoryRoot remote get-url origin 2>$null).Trim()
$branch = (& $git.Source -C $repositoryRoot branch --show-current 2>$null).Trim()
if ([string]::IsNullOrWhiteSpace($originUrl) -or [string]::IsNullOrWhiteSpace($branch)) {
    Write-Output '[DSH][LauncherUpdate][SKIP] Launcher Git checkout has no usable origin branch.'
    exit 0
}
$trackedChanges = @(& $git.Source -C $repositoryRoot status --porcelain --untracked-files=no)
if ($trackedChanges.Count -gt 0) {
    Write-Output '[DSH][LauncherUpdate][SKIP] Launcher has tracked local changes; automatic update was skipped to preserve them.'
    exit 0
}

& $git.Source -c http.proxy= -c https.proxy= -C $repositoryRoot fetch --prune origin
if ($LASTEXITCODE -ne 0) { & $git.Source -C $repositoryRoot fetch --prune origin }
if ($LASTEXITCODE -ne 0) {
    Write-Output '[DSH][LauncherUpdate][WARN] Launcher update source could not be reached; the installed launcher will be used.'
    exit 0
}
$remoteRef = "origin/$branch"
& $git.Source -C $repositoryRoot rev-parse --verify $remoteRef *> $null
if ($LASTEXITCODE -ne 0) { Write-Output "[DSH][LauncherUpdate][SKIP] Remote launcher branch $remoteRef was not found."; exit 0 }
$localCommit = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim()
$remoteCommit = (& $git.Source -C $repositoryRoot rev-parse $remoteRef).Trim()
if ($localCommit -eq $remoteCommit) { Write-Output "[DSH][LauncherUpdate][OK] Launcher is already current ($($localCommit.Substring(0, 8)))."; exit 0 }
& $git.Source -C $repositoryRoot merge-base --is-ancestor HEAD $remoteRef
if ($LASTEXITCODE -ne 0) { Write-Output '[DSH][LauncherUpdate][SKIP] Launcher branch has diverged; automatic merge was skipped.'; exit 0 }

$candidateManifestText = & $git.Source -C $repositoryRoot show "${remoteRef}:$manifestName" 2>$null
if ($LASTEXITCODE -ne 0 -or @($candidateManifestText).Count -eq 0) {
    Write-Output '[DSH][LauncherUpdate][SKIP] Candidate launcher has no compatibility manifest; refusing an unverified update.'
    exit 0
}
$candidateManifest = ($candidateManifestText -join "`n") | ConvertFrom-Json
if ([int]$candidateManifest.schemaVersion -ne 1 -or [string]$candidateManifest.core.packageName -ne [string]$corePackage.name) {
    Write-Output "[DSH][LauncherUpdate][SKIP] Candidate launcher does not declare compatibility with Harness $($corePackage.version)."
    exit 0
}
if ($NoApply) {
    Write-Output "[DSH][LauncherUpdate][UPDATE] Compatible launcher update is available: $($localCommit.Substring(0, 8)) -> $($remoteCommit.Substring(0, 8))."
    exit 0
}
& $git.Source -C $repositoryRoot merge --ff-only $remoteRef
if ($LASTEXITCODE -ne 0) { throw 'Failed to fast-forward the launcher repository.' }
Write-Output "[DSH][LauncherUpdate][OK] Launcher updated: $($localCommit.Substring(0, 8)) -> $($remoteCommit.Substring(0, 8)). Restart the launcher to load its new UI code."
