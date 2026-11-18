$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $root 'DSH-Launcher.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw $parseErrors[0] }
foreach ($function in $ast.FindAll({
    param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
    if ($function.Name -in @('Get-HarnessDependencyInstallArguments', 'Invoke-CheckedCommand', 'ConvertTo-CommandOutputLine')) {
        Invoke-Expression $function.Extent.Text
    }
}
function Write-LauncherLogLine { param($Line) }
$fixture = Join-Path $root ('reports\dependency-install-test-' + [guid]::NewGuid().ToString('N'))
$modules = Join-Path $fixture 'node_modules'
$store = Join-Path $fixture 'cache with spaces\v11'
New-Item -ItemType Directory -Path $modules, $store -Force | Out-Null
$metadata = Join-Path $modules '.modules.yaml'
$expected = '--config.store-dir=' + (Split-Path -Parent $store)

$argsWithoutMetadata = @(Get-HarnessDependencyInstallArguments $fixture)
if (($argsWithoutMetadata -join '|') -ne 'install|--frozen-lockfile') { throw 'Cold installation arguments changed.' }
@{ storeDir = $store } | ConvertTo-Json | Set-Content -LiteralPath $metadata -Encoding UTF8
$jsonArgs = @(Get-HarnessDependencyInstallArguments $fixture)
if ($jsonArgs.Count -ne 3 -or $jsonArgs[2] -ne $expected) { throw 'JSON store reuse failed.' }
('storeDir: ' + $store) | Set-Content -LiteralPath $metadata -Encoding UTF8
if (@(Get-HarnessDependencyInstallArguments $fixture)[2] -ne $expected) { throw 'YAML store reuse failed.' }
'{"storeDir":"relative/path"}' | Set-Content -LiteralPath $metadata -Encoding UTF8
$refused = $false
try { Get-HarnessDependencyInstallArguments $fixture | Out-Null } catch { $refused = $true }
if (-not $refused) { throw 'Invalid store metadata was accepted.' }

# The native child must see a closed pipe, including on Windows PowerShell 5.1.
$node = (Get-Command node.exe).Source
$probe = Join-Path $fixture 'stdin-probe.cjs'
@'
if (process.stdin.isTTY) process.exit(7);
process.stdin.resume();
process.stdin.on('end', () => process.exit(0));
setTimeout(() => process.exit(8), 3000).unref();
'@ | Set-Content -LiteralPath $probe -Encoding UTF8
Invoke-CheckedCommand -FilePath $node -Arguments @($probe) -NoInput

# Reproduce the actual pnpm mismatch on disposable dependencies. Refusal must
# preserve the sentinel, rather than silently approving a purge or waiting.
$pnpmScript = Join-Path $env:LOCALAPPDATA 'DSH\tools\pnpm-11.28.5\node_modules\pnpm\bin\pnpm.mjs'
if (-not (Test-Path -LiteralPath $pnpmScript)) { throw 'The installed pnpm regression fixture is unavailable.' }
'{"name":"launcher-purge-regression","private":true}' | Set-Content -LiteralPath (Join-Path $fixture 'package.json') -Encoding UTF8
@'
lockfileVersion: '9.0'
settings:
  autoInstallPeers: true
  excludeLinksFromLockfile: false
importers:
  .: {}
'@ | Set-Content -LiteralPath (Join-Path $fixture 'pnpm-lock.yaml') -Encoding UTF8
@{
    storeDir = $store; layoutVersion = 5; packageManager = 'pnpm@11.28.5'
    nodeLinker = 'isolated'; hoistPattern = @('*'); publicHoistPattern = @()
    virtualStoreDir = (Join-Path $modules '.pnpm'); virtualStoreDirMaxLength = 60
    included = @{ dependencies = $true; devDependencies = $true; optionalDependencies = $true }
} | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $metadata -Encoding UTF8
$sentinel = Join-Path $modules 'preserve-me.txt'
'preserve' | Set-Content -LiteralPath $sentinel -Encoding UTF8
$refused = $false
$previousCi = $env:CI
$env:CI = 'true'
try {
    Invoke-CheckedCommand -FilePath $node -Arguments @(
        $pnpmScript, '--dir', $fixture, 'install', '--frozen-lockfile', '--ignore-scripts',
        ('--config.store-dir=' + (Join-Path $fixture 'different-cache'))
    ) -NoInput
} catch { $refused = $true }
finally {
    if ($env:CI -ne 'true') { throw 'The caller CI setting was not restored.' }
    $env:CI = $previousCi
}
if (-not $refused -or -not (Test-Path -LiteralPath $sentinel)) { throw 'pnpm did not preserve dependencies on refusal.' }
Write-Output 'PASS: cold install, JSON/YAML cache reuse, invalid metadata, closed stdin, pnpm purge refusal.'
