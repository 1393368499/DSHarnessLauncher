param(
    [string]$ProfilePath
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $dshRoot = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
    } else {
        $env:DSH_HOME
    }
    $ProfilePath = Join-Path $dshRoot 'profiles\web'
}
$ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath)

function Update-Utf8File {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$Replacements
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $original = [System.IO.File]::ReadAllText($Path)
    $updated = $original
    foreach ($entry in $Replacements.GetEnumerator()) {
        $updated = $updated.Replace([string]$entry.Key, [string]$entry.Value)
    }
    if ($updated -eq $original) { return $false }

    [System.IO.File]::WriteAllText(
        $Path,
        $updated,
        [System.Text.UTF8Encoding]::new($false)
    )
    return $true
}

$agentTeamsRoot = Join-Path $ProfilePath 'node_modules\@nanmicoder\dsh-agent-teams'
$agentTeamsManifestPath = Join-Path $agentTeamsRoot 'package.json'
if (Test-Path -LiteralPath $agentTeamsManifestPath) {
    $manifest = Get-Content -LiteralPath $agentTeamsManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sourceChanged = Update-Utf8File -Path (Join-Path $agentTeamsRoot 'lib\client\index.js') -Replacements @{
        "['conversationEvents', 'slots'" = "['uiConversation', 'slots'"
        'ctx.conversationEvents.register(' = 'ctx.uiConversation.events.register('
    }
    $bundleChanged = Update-Utf8File -Path (Join-Path $agentTeamsRoot 'lib\client.js') -Replacements @{
        '"conversationEvents",' = '"uiConversation",'
        'ctx.conversationEvents.register(' = 'ctx.uiConversation.events.register('
    }
    if ($sourceChanged -or $bundleChanged) {
        Write-Output "[DSH][Plugins][OK] Applied the Harness uiConversation compatibility patch to AgentTeams $($manifest.version)."
    } else {
        Write-Output "[DSH][Plugins][OK] AgentTeams $($manifest.version) already uses the compatible conversation service."
    }
}

$sidebarRoot = Join-Path $ProfilePath 'node_modules\dsh-better-sidebar'
$sidebarManifestPath = Join-Path $sidebarRoot 'package.json'
if (Test-Path -LiteralPath $sidebarManifestPath) {
    $manifest = Get-Content -LiteralPath $sidebarManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    # Harness 0.1.2-alpha.3 accepts a string namespace directly.  The helper
    # export used by Better Sidebar 0.17.1 was removed from dsh-settings.
    $sidebarChanged = Update-Utf8File -Path (Join-Path $sidebarRoot 'lib\index.js') -Replacements @{
        'import { SettingsConflictError, settingsNamespace } from "@deepseek-ai/dsh-settings";' = 'import { SettingsConflictError } from "@deepseek-ai/dsh-settings";'
        'const ns = settingsNamespace(SIDEBAR_PREFS_NS);' = 'const ns = SIDEBAR_PREFS_NS;'
    }
    if ($sidebarChanged) {
        Write-Output "[DSH][Plugins][OK] Applied the Harness settings compatibility patch to Better Sidebar $($manifest.version)."
    } else {
        Write-Output "[DSH][Plugins][OK] Better Sidebar $($manifest.version) already uses the compatible settings API."
    }
}

if (-not (Test-Path -LiteralPath $agentTeamsManifestPath) -and -not (Test-Path -LiteralPath $sidebarManifestPath)) {
    Write-Output '[DSH][Plugins][SKIP] No known compatibility patches are needed.'
}
