param(
    [switch]$CheckOnly,
    [string]$HarnessPath
)

$ErrorActionPreference = 'Stop'
$launcherRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($HarnessPath)) {
    $HarnessPath = Join-Path $launcherRoot 'deepseek-harness'
}
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$repoUrl = 'https://github.com/deepseek-ai/deepseek-harness.git'
$serverScript = Join-Path $launcherRoot 'Start-DSH-Web.cmd'
$coreCompatibilityScript = Join-Path $launcherRoot 'DSH-CoreCompatibility.ps1'
$pluginUpdaterScript = Join-Path $launcherRoot 'DSH-PluginUpdater.ps1'
$pluginCompatibilityScript = Join-Path $launcherRoot 'DSH-PluginCompatibility.ps1'
$launcherLogRoot = Join-Path $env:LOCALAPPDATA 'DSH\logs'
$launcherLog = Join-Path $launcherLogRoot 'launcher.log'
$launcherStateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
$updateResultPath = Join-Path $launcherStateRoot 'last-update-result.json'
$webLog = Join-Path $HarnessPath 'dsh-web.log'
$buildEnvironmentBefore = @{}
$serviceWasRunning = $false
$serviceStoppedForUpdate = $false
$coreRolledBack = $false
$coreCompatibilityNeedsRestore = $false
$updateWarnings = New-Object System.Collections.ArrayList
$updateResult = [ordered]@{
    schemaVersion = 1
    startedAt = (Get-Date).ToString('o')
    finishedAt = $null
    status = 'running'
    coreStatus = 'checking'
    previousCoreCommit = ''
    currentCoreCommit = ''
    warnings = @()
}

function Invoke-LauncherLogRotation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaximumBytes = 8MB,
        [int]$Keep = 5
    )

    if (-not (Test-Path -LiteralPath $Path)) { return }
    if ((Get-Item -LiteralPath $Path).Length -le $MaximumBytes) { return }
    for ($index = $Keep; $index -ge 1; $index--) {
        $destination = "$Path.$index"
        if ($index -eq $Keep -and (Test-Path -LiteralPath $destination)) {
            Remove-Item -LiteralPath $destination -Force
        }
        $source = if ($index -eq 1) { $Path } else { "$Path.$($index - 1)" }
        if (Test-Path -LiteralPath $source) {
            Move-Item -LiteralPath $source -Destination $destination -Force
        }
    }
}

New-Item -ItemType Directory -Force -Path $launcherLogRoot | Out-Null
Invoke-LauncherLogRotation -Path $launcherLog

function Save-UpdateResult {
    $script:updateResult.warnings = @($script:updateWarnings)
    $json = $script:updateResult | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($script:updateResultPath, $json + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-UpdateWarning {
    param([Parameter(Mandatory)][string]$Message)
    [void]$script:updateWarnings.Add($Message)
    Write-LauncherStatus $Message Yellow
}

function Stop-WebServiceForCoreUpdate {
    $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $listener) { return }

    $script:serviceWasRunning = $true
    $ownerPid = [int]$listener.OwningProcess
    Write-LauncherStatus "Stopping the running Web service before replacing core files (PID $ownerPid)..." Cyan
    & "$env:SystemRoot\System32\taskkill.exe" /PID $ownerPid /T /F *> $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if ($null -eq (Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $script:serviceStoppedForUpdate = $true
            Write-LauncherStatus 'The Web service is stopped; the core can now be updated safely.' Green
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw 'The running Web service could not be stopped safely before the core update.'
}

function Start-WebServiceAfterCoreUpdate {
    if (-not $script:serviceWasRunning -or -not $script:serviceStoppedForUpdate) { return }
    if (-not (Test-Path -LiteralPath $script:serverScript)) {
        Add-UpdateWarning "The Web service was not restarted because its start script is missing: $script:serverScript"
        return
    }

    Write-LauncherStatus 'Restarting the Web service after the core update...' Cyan
    Start-Process -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/s', '/c', "`"`"$script:serverScript`" `"$script:HarnessPath`"`"") `
        -WorkingDirectory $script:HarnessPath `
        -WindowStyle Hidden | Out-Null
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $listener) {
            Write-LauncherStatus "The Web service is running again (PID $($listener.OwningProcess))." Green
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Add-UpdateWarning "The updated core was installed, but the Web service did not become ready automatically. Check $script:webLog."
}

function Write-LauncherStatus {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message" -ForegroundColor $Color
    Add-Content -LiteralPath $launcherLog -Value "[$timestamp] $Message" -Encoding UTF8
}

function Resolve-RequiredCommand {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Required command was not found: $Name"
    }

    return $command.Source
}

function ConvertTo-CommandOutputLine {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Management.Automation.ErrorRecord]) {
        $line = [string]$Value.Exception.Message
        if ([string]::IsNullOrWhiteSpace($line) -and $null -ne $Value.ErrorDetails) {
            $line = [string]$Value.ErrorDetails.Message
        }
        if ([string]::IsNullOrWhiteSpace($line)) { $line = [string]$Value.TargetObject }
    } else {
        $line = $Value.ToString()
    }

    # Build tools emit terminal color/control sequences. They do not render in the
    # WPF log view and can leave fragments such as "[39m", so store plain text.
    return [regex]::Replace($line, "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$FailureMessage = 'Command failed'
    )

    # Windows PowerShell can promote native stderr records (including Git progress)
    # to terminating errors when the caller uses ErrorActionPreference=Stop. Native
    # process success is authoritative here, so collect both streams and check its
    # exit code after the pipeline completes.
    $previousErrorActionPreference = $ErrorActionPreference
    $previousConsoleEncoding = [Console]::OutputEncoding
    $ErrorActionPreference = 'Continue'
    try {
        # Node, pnpm, Vite and Git emit UTF-8. Windows PowerShell otherwise decodes
        # their output with the active legacy code page, corrupting status symbols.
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = ConvertTo-CommandOutputLine $_
            Write-Host $line
            Add-Content -LiteralPath $launcherLog -Value $line -Encoding UTF8
        }
        $commandExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        [Console]::OutputEncoding = $previousConsoleEncoding
    }
    if ($commandExitCode -ne 0) {
        throw "$FailureMessage (exit code: $commandExitCode)"
    }
}

function Invoke-CoreCompatibility {
    param([Parameter(Mandatory)][ValidateSet('Apply', 'Remove', 'Status')][string]$Action)

    if (-not (Test-Path -LiteralPath $script:coreCompatibilityScript)) {
        throw "Core compatibility helper was not found: $script:coreCompatibilityScript"
    }
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -NoProfile -ExecutionPolicy Bypass -File $script:coreCompatibilityScript `
            -HarnessPath $script:HarnessPath -Action $Action 2>&1 | ForEach-Object { ConvertTo-CommandOutputLine $_ })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    foreach ($line in $output) {
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            Write-Host $line
            Add-Content -LiteralPath $script:launcherLog -Value $line -Encoding UTF8
        }
    }
    if ($exitCode -ne 0) { throw "Core compatibility action '$Action' failed (exit code: $exitCode)." }
    return @($output)
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [System.IO.File]::OpenRead($Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($stream)
        return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '')
    } finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Initialize-NativeBuildEnvironment {
    # node-gyp can miss a separately installed SDK when VS component metadata
    # is incomplete. Supply only verified developer-shell discovery variables.
    if ($env:OS -ne 'Windows_NT' -or $env:VCINSTALLDIR) { return }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    if (-not (Test-Path -LiteralPath $vswhere)) { return }
    $sdk = Get-ChildItem -LiteralPath (Join-Path $sdkRoot 'Include') -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '^10\.0\.\d+\.0$' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h')) -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'ucrt\stdio.h')) -and
            (Test-Path -LiteralPath (Join-Path $sdkRoot "Lib\$($_.Name)\um\x64\kernel32.lib")) -and
            (Test-Path -LiteralPath (Join-Path $sdkRoot "Lib\$($_.Name)\ucrt\x64\ucrt.lib"))
        } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if ($null -eq $sdk) { return }
    $instances = @(& $vswhere -all -products '*' -prerelease -format json | ConvertFrom-Json)
    foreach ($instance in $instances) {
        $vsRoot = [string]$instance.installationPath
        if (-not (Test-Path -LiteralPath (Join-Path $vsRoot 'MSBuild\Current\Bin\MSBuild.exe'))) { continue }
        $compiler = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\Hostx64\x64\cl.exe') } |
            Select-Object -First 1
        if ($null -eq $compiler) { continue }
        $variables = @{
            VCINSTALLDIR = (Join-Path $vsRoot 'VC') + '\'
            VSCMD_VER = [string]$instance.installationVersion
            WindowsSDKVersion = $sdk.Name + '\'
        }
        foreach ($name in $variables.Keys) {
            $script:buildEnvironmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $variables[$name], 'Process')
        }
        Write-LauncherStatus "Native builds will use Visual Studio $($instance.installationVersion) and Windows SDK $($sdk.Name)." DarkGray
        return
    }
}

try {
    Save-UpdateResult
    $gitPath = Resolve-RequiredCommand 'git.exe'
    $pnpmPath = Resolve-RequiredCommand 'pnpm.cmd'
    $freshInstall = $false

    if (-not (Test-Path -LiteralPath $HarnessPath)) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HarnessPath) | Out-Null
        Write-LauncherStatus 'Local Harness was not found. Cloning the official repository.' Cyan
        Invoke-CheckedCommand -FilePath $gitPath -Arguments @('clone', $repoUrl, $HarnessPath) -FailureMessage 'Failed to clone the official Harness repository'
        $freshInstall = $true
    }

    if (-not (Test-Path -LiteralPath (Join-Path $HarnessPath '.git'))) {
        throw "The directory is not a valid Git repository: $HarnessPath"
    }

    Set-Location -LiteralPath $HarnessPath

    $originUrl = (& $gitPath -C $HarnessPath remote get-url origin 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($originUrl)) {
        throw 'The repository does not have an origin remote.'
    }

    if ($originUrl -notmatch 'github\.com[/:]deepseek-ai/deepseek-harness(?:\.git)?$') {
        throw "The origin remote is not the official Harness repository: $originUrl"
    }

    $branch = (& $gitPath -C $HarnessPath branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'The repository is in detached HEAD state. Safe automatic update is unavailable.'
    }

    $localBefore = (& $gitPath -C $HarnessPath rev-parse HEAD).Trim()
    $updateResult.previousCoreCommit = $localBefore
    $lockFile = Join-Path $HarnessPath 'pnpm-lock.yaml'
    $lockHashBefore = if (Test-Path -LiteralPath $lockFile) {
        Get-FileSha256 -Path $lockFile
    } else {
        ''
    }

    Write-LauncherStatus "Checking the official Harness repository for updates (branch: $branch)..." Cyan
    # Prefer a direct GitHub connection. A stale machine-level loopback proxy is common on
    # Windows after a proxy client exits, and should not make every update look like a failure.
    $previousFetchErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $directFetchOutput = @(& $gitPath -c http.proxy= -c https.proxy= -C $HarnessPath fetch --prune origin 2>&1 | ForEach-Object { ConvertTo-CommandOutputLine $_ })
        $directFetchExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousFetchErrorPreference
    }
    $fetchSucceeded = $directFetchExitCode -eq 0
    $configuredFetchOutput = @()
    if (-not $fetchSucceeded) {
        Write-LauncherStatus 'The direct update check did not complete. Retrying with the configured Git network settings...' Yellow
        $ErrorActionPreference = 'Continue'
        try {
            $configuredFetchOutput = @(& $gitPath -C $HarnessPath fetch --prune origin 2>&1 | ForEach-Object { ConvertTo-CommandOutputLine $_ })
            $configuredFetchExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousFetchErrorPreference
        }
        $fetchSucceeded = $configuredFetchExitCode -eq 0
    }
    $updated = $false

    if (-not $fetchSucceeded) {
        $fetchDetail = @($configuredFetchOutput + $directFetchOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1)
        $detailSuffix = if ($fetchDetail.Count -gt 0) { " Detail: $($fetchDetail[0])" } else { '' }
        Add-UpdateWarning ("The official core could not be checked. The verified local version will remain available." + $detailSuffix)
        $updateResult.coreStatus = 'check-unavailable'
    } else {
        $remoteRef = "origin/$branch"
        & $gitPath -C $HarnessPath rev-parse --verify $remoteRef *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-LauncherStatus "Remote branch $remoteRef was not found. The local version will be used." Yellow
        } else {
            $remoteCommit = (& $gitPath -C $HarnessPath rev-parse $remoteRef).Trim()
            if ($localBefore -eq $remoteCommit) {
                Write-LauncherStatus 'Harness is already up to date.' Green
                $updateResult.coreStatus = 'current'
            } else {
                # The scheduler compatibility edit is intentionally tracked as a local diff.
                # Remove only that verified edit so upstream can fast-forward cleanly; unrelated
                # user changes remain protected by the normal dirty-worktree check below.
                [void](Invoke-CoreCompatibility -Action Remove)
                $coreCompatibilityNeedsRestore = $true
                $trackedChanges = @(& $gitPath -C $HarnessPath status --porcelain --untracked-files=no)
                & $gitPath -C $HarnessPath merge-base --is-ancestor HEAD $remoteRef
                $canFastForward = $LASTEXITCODE -eq 0

                if ($trackedChanges.Count -gt 0) {
                    Add-UpdateWarning 'Tracked local changes were detected. Automatic core update was skipped to protect them.'
                    $updateResult.coreStatus = 'skipped-local-changes'
                } elseif (-not $canFastForward) {
                    Add-UpdateWarning 'The local and official branches have diverged. Automatic core update was skipped.'
                    $updateResult.coreStatus = 'skipped-diverged'
                } else {
                    Write-LauncherStatus "Update found: $($localBefore.Substring(0, 8)) -> $($remoteCommit.Substring(0, 8))" Cyan
                    Stop-WebServiceForCoreUpdate
                    # Fetch already downloaded and verified origin/$branch. Fast-forward locally so a
                    # broken configured proxy cannot make a second, redundant network request fail.
                    Invoke-CheckedCommand -FilePath $gitPath -Arguments @('-C', $HarnessPath, 'merge', '--ff-only', $remoteRef) -FailureMessage 'Failed to apply the fetched Harness update'
                    $updated = $true
                    $updateResult.coreStatus = 'installing'
                    Write-LauncherStatus 'Harness update completed.' Green
                }
            }
        }
    }

    $coreCompatibilityStatus = @(Invoke-CoreCompatibility -Action Status)
    if (($coreCompatibilityStatus -join "`n") -match '\[VULNERABLE\]') {
        Stop-WebServiceForCoreUpdate
    }
    [void](Invoke-CoreCompatibility -Action Apply)
    $coreCompatibilityNeedsRestore = $false

    $lockHashAfter = if (Test-Path -LiteralPath $lockFile) {
        Get-FileSha256 -Path $lockFile
    } else {
        ''
    }
    $nodeModulesMissing = -not (Test-Path -LiteralPath (Join-Path $HarnessPath 'node_modules'))
    $dependenciesChanged = $lockHashBefore -ne $lockHashAfter
    $dependencyMarker = Join-Path $HarnessPath '.git\dsh-launcher-dependencies'
    $nodePath = Resolve-RequiredCommand 'node.exe'
    $nodeIdentity = & $nodePath -p "process.version + ':' + process.platform + ':' + process.arch"
    if ($LASTEXITCODE -ne 0) { throw 'Failed to inspect the Node.js runtime.' }
    $dependencyIdentity = "$lockHashAfter|$nodeIdentity"
    $installedIdentity = if (Test-Path -LiteralPath $dependencyMarker) {
        (Get-Content -LiteralPath $dependencyMarker -Raw -Encoding UTF8).Trim()
    } else { '' }
    Initialize-NativeBuildEnvironment

    $cliArtifact = Join-Path $HarnessPath 'apps\cli\lib\bin.js'
    $buildCommitMarker = Join-Path $HarnessPath '.git\dsh-launcher-build-commit'
    try {
        if ($nodeModulesMissing -or $dependenciesChanged -or $installedIdentity -ne $dependencyIdentity) {
            $reason = if ($nodeModulesMissing) { 'Dependencies are not installed' } elseif ($dependenciesChanged) { 'The dependency lock file changed' } else { 'Dependency installation has not been verified for this lockfile and Node.js version' }
            Write-LauncherStatus "$reason. Synchronizing dependencies..." Cyan
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('install', '--frozen-lockfile') -FailureMessage 'Failed to install Harness dependencies'
            Set-Content -LiteralPath $dependencyMarker -Value $dependencyIdentity -Encoding UTF8
            Write-LauncherStatus 'Dependency synchronization completed.' Green
        } elseif ($updated) {
            Write-LauncherStatus 'This update does not require dependency reinstallation.' DarkGray
        }

        $currentCommit = (& $gitPath -C $HarnessPath rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($currentCommit)) {
            throw 'Failed to resolve the current Harness commit before building.'
        }
        $builtCommit = if (Test-Path -LiteralPath $buildCommitMarker) {
            (Get-Content -LiteralPath $buildCommitMarker -Raw -Encoding UTF8).Trim()
        } else { '' }
        $buildStateMissingOrStale = $builtCommit -ne $currentCommit

        if ($freshInstall -or $updated -or $buildStateMissingOrStale -or -not (Test-Path -LiteralPath $cliArtifact)) {
            if ($buildStateMissingOrStale -and -not $freshInstall -and -not $updated) {
                Write-LauncherStatus 'The previous update did not complete its build. Recovering the Harness artifacts...' Yellow
            }
            Write-LauncherStatus 'Cleaning stale Harness build artifacts...' Cyan
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('run', 'clean') -FailureMessage 'Failed to clean stale Harness build artifacts'
            Write-LauncherStatus 'Building the complete Harness runtime and WebUI...' Cyan
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('run', 'build') -FailureMessage 'Failed to build Harness'
            Set-Content -LiteralPath $buildCommitMarker -Value $currentCommit -Encoding UTF8
            Write-LauncherStatus 'Harness build completed.' Green
        }
        if ($updated) { $updateResult.coreStatus = 'updated' }
    } catch {
        $coreFailure = $_.Exception.Message
        if (-not $updated -or $freshInstall) { throw }

        Write-LauncherStatus "The new core could not be prepared: $coreFailure" Red
        Write-LauncherStatus "Rolling the core back to the last working revision $($localBefore.Substring(0, 8))..." Yellow
        try {
            Invoke-CheckedCommand -FilePath $gitPath -Arguments @('-C', $HarnessPath, 'reset', '--hard', $localBefore) -FailureMessage 'Failed to restore the previous Harness revision'
            $restoredLockHash = if (Test-Path -LiteralPath $lockFile) { Get-FileSha256 -Path $lockFile } else { '' }
            $restoredDependencyIdentity = "$restoredLockHash|$nodeIdentity"
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('install', '--frozen-lockfile') -FailureMessage 'Failed to restore the previous Harness dependencies'
            Set-Content -LiteralPath $dependencyMarker -Value $restoredDependencyIdentity -Encoding UTF8
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('run', 'clean') -FailureMessage 'Failed to clean artifacts while restoring the previous Harness core'
            Invoke-CheckedCommand -FilePath $pnpmPath -Arguments @('run', 'build') -FailureMessage 'Failed to rebuild the previous Harness core'
            Set-Content -LiteralPath $buildCommitMarker -Value $localBefore -Encoding UTF8
            [void](Invoke-CoreCompatibility -Action Apply)
            $coreCompatibilityNeedsRestore = $false
            $updated = $false
            $coreRolledBack = $true
            $updateResult.coreStatus = 'rolled-back'
            [void]$updateWarnings.Add("The new core was rejected and the previous working core was restored: $coreFailure")
            Write-LauncherStatus 'Rollback completed. The previous Harness core remains usable.' Green
        } catch {
            throw "The new core failed, and automatic rollback also failed. Core error: $coreFailure. Rollback error: $($_.Exception.Message)"
        }
    }

    $themePath = @(
        (Join-Path $launcherRoot 'maid-atelier'),
        (Join-Path $launcherRoot 'plugins\maid-atelier'),
        (Join-Path (Split-Path -Parent $launcherRoot) 'maid-atelier')
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'package.json') } | Select-Object -First 1
    if (-not [string]::IsNullOrWhiteSpace($themePath)) {
        $profileRoot = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
            Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
        } else {
            $env:DSH_HOME
        }
        $profileManifest = Join-Path $profileRoot 'profiles\web\package.json'
        $themePackage = '@dsh-external/dsh-client-ui-skin-maid-atelier'
        $themeRegistered = $false
        $expectedThemePath = [IO.Path]::GetFullPath($themePath) -replace '[\\/]+', '/'
        if (Test-Path -LiteralPath $profileManifest) {
            try {
                $profile = Get-Content -LiteralPath $profileManifest -Raw -Encoding UTF8 | ConvertFrom-Json
                $themeProperty = $profile.dependencies.PSObject.Properties[$themePackage]
                if ($null -ne $themeProperty) {
                    $registeredThemePath = (([string]$themeProperty.Value) -replace '^(link:|file:)', '') -replace '[\\/]+', '/'
                    $themeRegistered = $registeredThemePath.TrimEnd('/') -eq $expectedThemePath.TrimEnd('/')
                }
            } catch {
                $themeRegistered = $false
            }
        }
        if (-not $themeRegistered) {
            Write-LauncherStatus 'Registering the project maid-atelier theme in the Web profile...' Cyan
            try {
                Invoke-CheckedCommand -FilePath $pnpmPath `
                    -Arguments @('dsh', 'plugin', '--profile', 'web', 'add', $themePath) `
                    -FailureMessage 'Failed to register the maid-atelier theme'
                Write-LauncherStatus 'Project theme registration completed.' Green
            } catch {
                Add-UpdateWarning ("The optional maid-atelier theme could not be registered; the core update remains valid. " + $_.Exception.Message)
            }
        }
    }

    if (Test-Path -LiteralPath $pluginUpdaterScript) {
        Write-LauncherStatus 'Checking installed Web profile plugins through the direct GitHub API...' Cyan
        try {
            Invoke-CheckedCommand -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                -Arguments @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $pluginUpdaterScript,
                    '-HarnessPath', $HarnessPath
                ) `
                -FailureMessage 'Failed to check or update installed Web profile plugins'
        } catch {
            Add-UpdateWarning ("Plugin update checking was unavailable; the core update remains valid. " + $_.Exception.Message)
        }
    } else {
        Add-UpdateWarning "Plugin update helper was not found: $pluginUpdaterScript"
    }

    if (Test-Path -LiteralPath $pluginCompatibilityScript) {
        Write-LauncherStatus 'Applying compatibility fixes for installed Web profile plugins...' Cyan
        try {
            Invoke-CheckedCommand -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                -Arguments @(
                    '-NoProfile',
                    '-ExecutionPolicy', 'Bypass',
                    '-File', $pluginCompatibilityScript
                ) `
                -FailureMessage 'Failed to apply Web profile plugin compatibility fixes'
        } catch {
            Add-UpdateWarning ("Some plugin compatibility repairs could not be applied; the core update remains valid. " + $_.Exception.Message)
        }
    } else {
        Add-UpdateWarning "Plugin compatibility helper was not found: $pluginCompatibilityScript"
    }

    if ($CheckOnly) {
        # Phase 2 of the update check: after the core is current, verify that
        # the launcher is compatible with the freshly updated core, and apply a
        # launcher self-update when one is available (guarded by the manifest).
        $launcherUpdater = Join-Path $launcherRoot 'DSH-LauncherUpdater.ps1'
        if (Test-Path -LiteralPath $launcherUpdater) {
            Write-LauncherStatus 'Checking launcher update channel...' Cyan
            try {
                Invoke-CheckedCommand -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherUpdater, '-HarnessPath', $HarnessPath, '-LauncherRoot', $launcherRoot) `
                    -FailureMessage 'Launcher update check failed'
            } catch {
                Add-UpdateWarning ("Launcher update check failed; this does not invalidate the core update. " + $_.Exception.Message)
            }
        }

        $launcherCompatibility = Join-Path $launcherRoot 'DSH-LauncherCompatibility.ps1'
        if (Test-Path -LiteralPath $launcherCompatibility) {
            Write-LauncherStatus 'Verifying launcher compatibility with the updated Harness core...' Cyan
            try {
                Invoke-CheckedCommand -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
                    -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $launcherCompatibility, '-HarnessPath', $HarnessPath, '-LauncherRoot', $launcherRoot, '-RuntimeProbe', '-Record') `
                    -FailureMessage 'Launcher compatibility verification failed'
            } catch {
                Add-UpdateWarning ("Launcher compatibility verification needs attention. " + $_.Exception.Message)
            }
        }

        Start-WebServiceAfterCoreUpdate
        $updateResult.currentCoreCommit = (& $gitPath -C $HarnessPath rev-parse HEAD).Trim()
        $updateResult.finishedAt = (Get-Date).ToString('o')
        $updateResult.status = if ($coreRolledBack) { 'rolled-back' } elseif ($updateWarnings.Count -gt 0) { 'warning' } else { 'ok' }
        Save-UpdateResult
        if ($updateWarnings.Count -gt 0) {
            Write-LauncherStatus "Core update processing completed with $($updateWarnings.Count) non-fatal warning(s)." Yellow
        } else {
            Write-LauncherStatus 'Harness, launcher, and plugin update checks completed.' Green
        }
        exit 0
    }

    $existingListener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $existingListener) {
        Write-LauncherStatus "DSH is already running on port 3080 (PID $($existingListener.OwningProcess))." Green
        exit 0
    }

    if (-not (Test-Path -LiteralPath $serverScript)) {
        throw "The background server script was not found: $serverScript"
    }

    Write-LauncherStatus 'Starting the DSH Web service in the background...' Cyan
    Start-Process -FilePath $env:ComSpec `
        -ArgumentList @('/d', '/s', '/c', "`"`"$serverScript`" `"$HarnessPath`"`"") `
        -WorkingDirectory $HarnessPath `
        -WindowStyle Hidden | Out-Null

    Start-Sleep -Seconds 2
    $startedListener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $startedListener) {
        Write-LauncherStatus "DSH started successfully: http://127.0.0.1:3080/ (PID $($startedListener.OwningProcess))" Green
    } else {
        Write-LauncherStatus "The start command was submitted. Open http://127.0.0.1:3080/ after initialization. Log: $webLog" Yellow
    }
} catch {
    if ($coreCompatibilityNeedsRestore) {
        try {
            [void](Invoke-CoreCompatibility -Action Apply)
            $coreCompatibilityNeedsRestore = $false
        } catch {
            [void]$updateWarnings.Add("The managed core compatibility patch could not be restored: $($_.Exception.Message)")
        }
    }
    $updateResult.status = 'failed'
    $updateResult.finishedAt = (Get-Date).ToString('o')
    try {
        if (Test-Path -LiteralPath (Join-Path $HarnessPath '.git')) {
            $updateResult.currentCoreCommit = (& git.exe -C $HarnessPath rev-parse HEAD 2>$null).Trim()
        }
        [void]$updateWarnings.Add($_.Exception.Message)
        Save-UpdateResult
    } catch { }
    try { Start-WebServiceAfterCoreUpdate } catch { }
    Write-LauncherStatus "Start failed: $($_.Exception.Message)" Red
    Write-LauncherStatus "Detailed log: $launcherLog" Yellow
    if (-not $CheckOnly) {
        Read-Host 'Press Enter to close'
    }
    exit 1
} finally {
    if ($coreCompatibilityNeedsRestore) {
        try { [void](Invoke-CoreCompatibility -Action Apply) } catch { }
    }
    foreach ($name in $buildEnvironmentBefore.Keys) {
        [Environment]::SetEnvironmentVariable($name, $buildEnvironmentBefore[$name], 'Process')
    }
}
