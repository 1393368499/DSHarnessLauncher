$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$source = Join-Path (Split-Path -Parent $PSScriptRoot) 'DSH-PluginUpdater.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
$names = @('ConvertTo-SemVer', 'Compare-SemVer', 'Test-SemVerRange',
    'Test-PluginCoreCompatibility', 'Get-LatestNpmVersion',
    'Get-LatestGitHubVersion', 'Get-LatestPublishedVersion')
foreach ($function in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($function.Name -in $names) { Invoke-Expression $function.Extent.Text }
}
function Get-GitHubJson { return @() }
function Get-InstalledHarnessPackageVersion { return $script:harnessVersion.Text }
function Get-NpmPackageDocument { return $script:document }
function Assert-Version {
    param([string]$Expected, [string]$Scenario)
    $result = Get-LatestPublishedVersion $plugin (ConvertTo-SemVer '0.6.4')
    if ($null -eq $result -or $result.Version.Text -ne $Expected -or $result.Tag -ne 'npm') {
        throw "$Scenario did not select $Expected from npm"
    }
    Write-Output "PASS: $Scenario"
}

$plugin = [pscustomobject]@{ Name = 'dsh-session-manager'; Source = [pscustomobject]@{ Repo = 'example/session-manager' } }
$script:document = @'
{"versions":{
  "0.6.4":{"name":"dsh-session-manager","version":"0.6.4"},
  "0.7.4":{"name":"dsh-session-manager","version":"0.7.4","peerDependencies":{"@deepseek-ai/dsh-settings":"^0.2.1-rc.1"}},
  "0.8.0-rc.1":{"name":"dsh-session-manager","version":"0.8.0-rc.1","peerDependencies":{"@deepseek-ai/dsh-settings":"^0.2.1-rc.1"}},
  "2.0.0":{"name":"dsh-session-manager","version":"2.0.0","peerDependencies":{"@deepseek-ai/dsh-settings":"^0.3.0"}},
  "3.0.0":{"name":"different-package","version":"3.0.0"},
  "4.0.0":{"name":"dsh-session-manager","version":"4.0.0","deprecated":"withdrawn"}
}}
'@ | ConvertFrom-Json
$script:harnessVersion = ConvertTo-SemVer '0.2.1-rc.2'
$ReleaseChannel = 'stable'
Assert-Version '0.7.4' 'Missing GitHub tags select a compatible stable npm release'
$ReleaseChannel = 'preview'
Assert-Version '0.8.0-rc.1' 'Preview channel selects a compatible preview'
$ReleaseChannel = 'auto'
Assert-Version '0.8.0-rc.1' 'Preview core enables preview candidates in auto mode'
$script:harnessVersion = ConvertTo-SemVer '0.2.1'
Assert-Version '0.7.4' 'Stable core excludes preview candidates in auto mode'
$script:document = '{"versions":{"2.0.0":{"name":"dsh-session-manager","version":"2.0.0","peerDependencies":{"@deepseek-ai/dsh-settings":"^0.3.0"}}}}' | ConvertFrom-Json
if ($null -ne (Get-LatestPublishedVersion $plugin (ConvertTo-SemVer '0.6.4'))) {
    throw 'An incompatible npm-only release was accepted'
}
Write-Output 'PASS: Incompatible npm-only releases are rejected'
