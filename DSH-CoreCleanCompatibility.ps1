param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [ValidateSet('Apply', 'Remove', 'Status')][string]$Action = 'Apply'
)

$ErrorActionPreference = 'Stop'
$target = Join-Path $HarnessPath 'scripts\clean.ts'
$statePath = Join-Path $HarnessPath '.git\dsh-launcher-clean-compatibility.json'
$old = "          : typesDirectory === nativeEntryOutput`n            ? typesDirectory`n            : undefined"
$new = "          : typesDirectory === nativeEntryOutput || typesDirectory === join(this.root, 'lib/desktop-keyboard-test-types')`n            ? typesDirectory`n            : undefined"
if (-not (Test-Path -LiteralPath $target)) { throw "Harness clean script was not found: $target" }
$content = [IO.File]::ReadAllText($target)
$normalized = $content.Replace("`r`n", "`n")
$state = if (Test-Path -LiteralPath $statePath) {
    Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { $null }
$hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
$isManaged = $normalized.Contains($new) -and $null -ne $state -and $state.patchedSha256 -eq $hash
if ($Action -eq 'Apply' -and -not (Test-Path -LiteralPath (Join-Path $HarnessPath 'tsconfig.desktop-keyboard-tests.json'))) {
    if ($null -ne $state -and -not $normalized.Contains($new)) { Remove-Item -LiteralPath $statePath -Force }
    exit 0
}

if ($Action -eq 'Status') {
    if ($isManaged) { Write-Output '[DSH][CoreCleanCompatibility][CURRENT] Known TypeScript output is allowed.' }
    elseif ($normalized.Contains($old)) { Write-Output '[DSH][CoreCleanCompatibility][NEEDS-PATCH] Core clean script needs the known output path.' }
    else { Write-Output '[DSH][CoreCleanCompatibility][OFFICIAL] Core clean script has changed.' }
    exit 0
}
if ($Action -eq 'Apply') {
    if ($isManaged) { exit 0 }
    if ($normalized.Contains($new)) { throw 'The core clean compatibility edit was modified outside the launcher.' }
    if (-not $normalized.Contains($old)) { exit 0 }
    if (([regex]::Matches($normalized, [regex]::Escape($old))).Count -ne 1) { throw 'Ambiguous core clean script; refusing an automatic edit.' }
    $replacement = if ($content.Contains("`r`n")) { $new.Replace("`n", "`r`n") } else { $new }
    $originalText = if ($content.Contains("`r`n")) { $old.Replace("`n", "`r`n") } else { $old }
    [IO.File]::WriteAllText($target, $content.Replace($originalText, $replacement), (New-Object Text.UTF8Encoding($false)))
    @{ originalSha256 = $hash; patchedSha256 = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash } |
        ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Output '[DSH][CoreCleanCompatibility][APPLIED] Known TypeScript output is now accepted by clean.'
    exit 0
}
if ($null -eq $state) { exit 0 }
if (-not $isManaged) { throw 'Core clean script changed since the launcher patch; refusing to overwrite it.' }
$replacement = if ($content.Contains("`r`n")) { $old.Replace("`n", "`r`n") } else { $old }
$originalText = if ($content.Contains("`r`n")) { $new.Replace("`n", "`r`n") } else { $new }
[IO.File]::WriteAllText($target, $content.Replace($originalText, $replacement), (New-Object Text.UTF8Encoding($false)))
if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $state.originalSha256) {
    throw 'Original core clean script was not restored exactly.'
}
Remove-Item -LiteralPath $statePath -Force
Write-Output '[DSH][CoreCleanCompatibility][REMOVED] Original core clean script restored.'
