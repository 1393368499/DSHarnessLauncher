param(
    [Parameter(Mandatory)][ValidateSet('list', 'enable', 'disable', 'update')][string]$Action,
    [string]$Name,
    [Parameter(Mandatory)][string]$HarnessPath,
    [string]$ProfileName = 'web',
    [string]$LauncherRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$profileHome = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
} else {
    $env:DSH_HOME
}
$profilePath = Join-Path $profileHome "profiles\$ProfileName"
$profileManifestPath = Join-Path $profilePath 'package.json'
if (-not (Test-Path -LiteralPath $profileManifestPath)) { throw "Web profile was not found: $profileManifestPath" }
$profile = Get-Content -LiteralPath $profileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$bundleNames = @($profile.dsh.profile.bundles | ForEach-Object { [string]$_ })
$bundleSet = @{}
foreach ($bundleName in $bundleNames) { $bundleSet[$bundleName] = $true }
$pnpm = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
if ($null -eq $pnpm) { throw 'pnpm.cmd was not found.' }

function Invoke-DshCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)

    Push-Location -LiteralPath $HarnessPath
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $pnpm.Source @Arguments 2>&1 | ForEach-Object { $_.ToString() })
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
        Pop-Location
    }
    if ($exitCode -ne 0) {
        $tail = @($output | Select-Object -Last 12) -join [Environment]::NewLine
        throw "Harness plugin command failed with exit code $exitCode.`n$tail"
    }
    return $output
}

function Get-PluginInventory {
    $entriesByBundle = @{}
    $usedLiveInventory = $false
    try {
        $live = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/plugin-switch/list' -Method Get -TimeoutSec 2
        if ($live.ok -ne $true -or $null -eq $live.value -or $null -eq $live.value.entries) {
            throw 'The live plugin inventory returned an invalid response.'
        }
        foreach ($bundleName in $bundleNames) {
            $liveEntries = @($live.value.entries | Where-Object {
                $moduleName = [string]$_.moduleName
                $moduleName -eq $bundleName -or $moduleName.StartsWith($bundleName + '/', [StringComparison]::Ordinal)
            })
            if ($liveEntries.Count -eq 0) { continue }
            $entriesByBundle[$bundleName] = [System.Collections.ArrayList]::new()
            foreach ($entry in $liveEntries) {
                [void]$entriesByBundle[$bundleName].Add([pscustomobject]@{
                    Id = [string]$entry.entryId
                    Disabled = $entry.enabled -ne $true
                })
            }
        }
        $usedLiveInventory = $true
    } catch { }

    if (-not $usedLiveInventory) {
        $dump = Invoke-DshCommand @('dsh', '--profile', $ProfileName, '--dump-config')
        $currentBundle = $null
        $currentEntry = $null
        foreach ($line in $dump) {
            if ($line -match '^# == (?<bundle>[^,]+)(?:,.*)?$') {
                $currentBundle = $Matches.bundle.Trim()
                $currentEntry = $null
                continue
            }
            if ($null -eq $currentBundle -or -not $bundleSet.ContainsKey($currentBundle)) { continue }
            if ($line -match '^- id:\s*(?<id>.+?)\s*$') {
                $currentEntry = [pscustomobject]@{ Id = $Matches.id.Trim(' ', "'", '"'); Disabled = $false }
                if (-not $entriesByBundle.ContainsKey($currentBundle)) { $entriesByBundle[$currentBundle] = [System.Collections.ArrayList]::new() }
                [void]$entriesByBundle[$currentBundle].Add($currentEntry)
                continue
            }
            if ($null -ne $currentEntry -and $line -match '^  disabled:\s*(?<value>true|false)\s*$') {
                $currentEntry.Disabled = $Matches.value -eq 'true'
            }
        }
    }

    $items = @()
    foreach ($dependency in $profile.dependencies.PSObject.Properties) {
        $packageName = [string]$dependency.Name
        if (-not $bundleSet.ContainsKey($packageName)) { continue }
        $installedManifestPath = Join-Path $profilePath ("node_modules/" + $packageName + "/package.json")
        $installedVersion = if (Test-Path -LiteralPath $installedManifestPath) {
            [string](Get-Content -LiteralPath $installedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } else {
            '未安装'
        }
        $entries = if ($entriesByBundle.ContainsKey($packageName)) { @($entriesByBundle[$packageName]) } else { @() }
        $entryCount = @($entries).Count
        $disabledCount = @($entries | Where-Object { $_.Disabled }).Count
        $state = if ($entryCount -eq 0) {
            '无入口'
        } elseif ($disabledCount -eq $entryCount) {
            '已停用'
        } elseif ($disabledCount -gt 0) {
            '部分启用'
        } else {
            '已启用'
        }
        $items += [pscustomobject]@{
            Name = $packageName
            Version = $installedVersion
            State = $state
            EntryCount = $entryCount
            EntryIds = @($entries | ForEach-Object { $_.Id })
        }
    }
    return @($items | Sort-Object Name)
}

if ($Action -eq 'list') {
    @(Get-PluginInventory) | ConvertTo-Json -Depth 5
    return
}

if ([string]::IsNullOrWhiteSpace($Name)) { throw "Plugin name is required for action '$Action'." }
$dependencyProperty = $profile.dependencies.PSObject.Properties[$Name]
if ($null -eq $dependencyProperty -or -not $bundleSet.ContainsKey($Name)) {
    throw "Plugin is not an installed Web profile bundle: $Name"
}

if ($Action -eq 'update') {
    $updaterScript = Join-Path $LauncherRoot 'DSH-PluginUpdater.ps1'
    if (-not (Test-Path -LiteralPath $updaterScript)) {
        throw "Plugin release resolver was not found: $updaterScript"
    }
    $updaterOutput = @(& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
        -NoProfile -ExecutionPolicy Bypass -File $updaterScript `
        -HarnessPath $HarnessPath -ProfileName $ProfileName -ProfilePath $profilePath `
        -PluginName $Name -ReleaseChannel auto -NoCache 2>&1 | ForEach-Object { $_.ToString() })
    $updaterExitCode = $LASTEXITCODE
    foreach ($line in $updaterOutput) { Write-Output $line }
    if ($updaterExitCode -ne 0) {
        throw "Plugin release resolver failed with exit code $updaterExitCode."
    }
    $compatibilityScript = Join-Path $LauncherRoot 'DSH-PluginCompatibility.ps1'
    if (Test-Path -LiteralPath $compatibilityScript) {
        [void](& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $compatibilityScript)
        if ($LASTEXITCODE -ne 0) { throw "Plugin compatibility helper failed with exit code $LASTEXITCODE." }
    }
    Write-Output "[DSH][PluginManager][OK] Checked stable and compatible preview channels for $Name. Restart WebUI if the plugin does not hot-reload."
    return
}

$inventory = @(Get-PluginInventory)
$item = $inventory | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
if ($null -eq $item -or @($item.EntryIds).Count -eq 0) { throw "No configurable entries were found for plugin: $Name" }
$enable = $Action -eq 'enable'
$usedLiveApi = $false
try {
    $payload = [ordered]@{
        entries = @($item.EntryIds | ForEach-Object { [ordered]@{ id = [string]$_; enabled = $enable } })
    } | ConvertTo-Json -Depth 5
    $response = Invoke-RestMethod -Uri 'http://127.0.0.1:3080/plugin-switch/bulk' -Method Post -ContentType 'application/json' -Body $payload -TimeoutSec 12
    if ($response.ok -ne $true -or $response.value.persisted -ne $true) { throw 'Plugin switch API did not persist the requested state.' }
    $usedLiveApi = $true
} catch {
    $switchTool = Join-Path $profilePath 'node_modules\dsh-profile-plugin-switch\scripts\dsh-plugin-fix.mjs'
    if (-not (Test-Path -LiteralPath $switchTool)) { throw "Live toggle is unavailable and the offline recovery tool was not found. $($_.Exception.Message)" }
    $patchPath = Join-Path $profilePath 'cordis.patch.yml'
    $backupRoot = Join-Path $profilePath 'backups'
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $backupPath = Join-Path $backupRoot ("launcher-plugin-manager-{0}.yml" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    Copy-Item -LiteralPath $patchPath -Destination $backupPath
    foreach ($entryId in @($item.EntryIds)) {
        $offlineEntryId = ([string]$entryId -split ':')[-1]
        & node.exe $switchTool $Action $offlineEntryId *> $null
        if ($LASTEXITCODE -ne 0) { throw "Failed to $Action plugin entry '$entryId'. Backup: $backupPath" }
    }
}

$mode = if ($usedLiveApi) { 'live' } else { 'offline; restart WebUI to apply' }
$verb = if ($enable) { 'Enabled' } else { 'Disabled' }
Write-Output "[DSH][PluginManager][OK] $verb $Name ($mode)."
