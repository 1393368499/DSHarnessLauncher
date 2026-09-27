param(
    [Parameter(Mandatory)][ValidateSet('Git', 'Portable')][string]$Mode,
    [Parameter(Mandatory)][string]$LauncherRoot,
    [Parameter(Mandatory)][int]$WaitForProcessId,
    [string]$GitPath,
    [string]$ExpectedCommit,
    [string]$PackageRoot,
    [string]$OperationRoot
)

$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
$pendingPath = Join-Path $stateRoot 'pending-launcher-update.json'
$logPath = Join-Path $stateRoot 'logs\launcher-update.log'
$launcherLogPath = Join-Path $stateRoot 'logs\launcher.log'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $logPath) | Out-Null
function Write-UpdateLog {
    param([string]$Line)
    foreach ($path in @($logPath, $launcherLogPath)) {
        for ($attempt = 0; $attempt -lt 6; $attempt++) {
            try {
                Add-Content -LiteralPath $path -Value $Line -Encoding UTF8 -ErrorAction Stop
                break
            } catch {
                if ($attempt -lt 5) { Start-Sleep -Milliseconds 50 }
            }
        }
    }
}
try {
    $process = Get-Process -Id $WaitForProcessId -ErrorAction SilentlyContinue
    if ($null -ne $process -and -not $process.WaitForExit(120000)) {
        throw 'The launcher window did not exit within two minutes; update was not applied.'
    }
    if ($Mode -eq 'Git') {
        if ($ExpectedCommit -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid expected launcher commit.' }
        if (-not (Test-Path -LiteralPath $GitPath -PathType Leaf)) { throw 'Git executable was not available after launcher exit.' }
        $changes = @(& $GitPath -C $LauncherRoot status --porcelain --untracked-files=no)
        if ($LASTEXITCODE -ne 0 -or $changes.Count -gt 0) { throw 'Launcher files changed before the update could be applied.' }
        & $GitPath -C $LauncherRoot merge --ff-only $ExpectedCommit 2>&1 | Out-File -LiteralPath $logPath -Append -Encoding UTF8
        if ($LASTEXITCODE -ne 0) { throw 'Failed to apply the launcher Git update after exit.' }
    } else {
        $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'launcher-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $files = @($manifest.launcher.requiredFiles) + 'launcher-manifest.json'
        $backupRoot = Join-Path $stateRoot ('launcher-backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $applied = @()
        try {
            foreach ($relative in $files) {
                if ([string]::IsNullOrWhiteSpace([string]$relative) -or [IO.Path]::IsPathRooted([string]$relative) -or ([string]$relative) -match '(^|[\\/])\.\.([\\/]|$)') {
                    throw "Unsafe launcher file path: $relative"
                }
                $source = Join-Path $PackageRoot $relative
                if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Launcher package is missing $relative" }
                $destination = Join-Path $LauncherRoot $relative
                $backup = Join-Path $backupRoot $relative
                if (Test-Path -LiteralPath $destination) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                    Copy-Item -LiteralPath $destination -Destination $backup -Force
                }
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
                $applied += $relative
                Copy-Item -LiteralPath $source -Destination $destination -Force
            }
            $oldBackups = @(Get-ChildItem -LiteralPath (Split-Path -Parent $backupRoot) -Directory | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5)
            foreach ($old in $oldBackups) { Remove-Item -LiteralPath $old.FullName -Recurse -Force }
        } catch {
            foreach ($relative in $applied) {
                $destination = Join-Path $LauncherRoot $relative
                $backup = Join-Path $backupRoot $relative
                if (Test-Path -LiteralPath $backup) { Copy-Item -LiteralPath $backup -Destination $destination -Force }
                elseif (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
            }
            throw
        }
    }
    $resultLine = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Launcher update applied successfully."
    Write-UpdateLog $resultLine
} catch {
    $resultLine = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Launcher update failed: $($_.Exception.Message)"
    Write-UpdateLog $resultLine
} finally {
    if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath -Force }
    if ($OperationRoot -and (Test-Path -LiteralPath $OperationRoot)) {
        Remove-Item -LiteralPath $OperationRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
    $launcherExe = Join-Path $LauncherRoot 'DSH.exe'
    if (Test-Path -LiteralPath $launcherExe) {
        try { Start-Process -FilePath $launcherExe -WorkingDirectory $LauncherRoot | Out-Null }
        catch { Write-UpdateLog "[$(Get-Date -Format o)] Launcher could not restart: $($_.Exception.Message)" }
    }
}
