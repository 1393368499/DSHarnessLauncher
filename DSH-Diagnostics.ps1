param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [string]$LauncherRoot = $PSScriptRoot,
    [string]$ProfileName = 'web'
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [System.IO.Path]::GetFullPath($HarnessPath)
$LauncherRoot = [System.IO.Path]::GetFullPath($LauncherRoot)
$stateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
$resultPath = Join-Path $stateRoot 'diagnostics-latest.json'
$checks = New-Object System.Collections.ArrayList

function Add-DiagnosticCheck {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )

    [void]$script:checks.Add([ordered]@{
        category = $Category
        name = $Name
        status = $Status
        detail = $Detail
    })
    Write-Output "[DSH][Diagnostics][$Status] $Category / $Name - $Detail"
}

function Get-CommandVersion {
    param([Parameter(Mandatory)][string]$CommandName, [Parameter(Mandatory)][string[]]$Arguments)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($null -eq $command) { return $null }
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = @(& $command.Source @Arguments 2>&1 | ForEach-Object { $_.ToString() }) -join ' '
        if ($LASTEXITCODE -ne 0) { return $null }
        return $text.Trim()
    } finally {
        $ErrorActionPreference = $previous
    }
}

New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null

try {
    $manifestPath = Join-Path $LauncherRoot 'launcher-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Add-DiagnosticCheck '启动器' '文件清单' 'FAIL' "缺少 $manifestPath"
    } else {
        try {
            $launcherManifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Add-DiagnosticCheck '启动器' '版本' 'OK' "v$($launcherManifest.version)"
            $missing = @($launcherManifest.launcher.requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $LauncherRoot ([string]$_))) })
            if ($missing.Count -gt 0) {
                Add-DiagnosticCheck '启动器' '文件完整性' 'FAIL' ("缺少：" + ($missing -join ', '))
            } else {
                Add-DiagnosticCheck '启动器' '文件完整性' 'OK' "$(@($launcherManifest.launcher.requiredFiles).Count) 个必需文件均存在"
            }
        } catch {
            Add-DiagnosticCheck '启动器' '文件清单' 'FAIL' $_.Exception.Message
        }
    }

    $parseFailures = @()
    foreach ($scriptFile in @(Get-ChildItem -LiteralPath $LauncherRoot -Filter '*.ps1' -File)) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors)
        if (@($errors).Count -gt 0) { $parseFailures += "$($scriptFile.Name): $($errors[0].Message)" }
    }
    try { [xml](Get-Content -LiteralPath (Join-Path $LauncherRoot 'LauncherWindow.xaml') -Raw -Encoding UTF8) | Out-Null } catch { $parseFailures += "LauncherWindow.xaml: $($_.Exception.Message)" }
    if ($parseFailures.Count -gt 0) {
        Add-DiagnosticCheck '启动器' '脚本与界面语法' 'FAIL' ($parseFailures -join '; ')
    } else {
        Add-DiagnosticCheck '启动器' '脚本与界面语法' 'OK' 'PowerShell 与 XAML 解析通过'
    }

    foreach ($tool in @(
        @{ Name = 'Git'; Command = 'git.exe'; Arguments = @('--version') },
        @{ Name = 'Node.js'; Command = 'node.exe'; Arguments = @('--version') },
        @{ Name = 'pnpm'; Command = 'pnpm.cmd'; Arguments = @('--version') }
    )) {
        $version = Get-CommandVersion $tool.Command $tool.Arguments
        if ([string]::IsNullOrWhiteSpace($version)) {
            Add-DiagnosticCheck '运行环境' $tool.Name 'FAIL' '未找到或无法运行'
        } else {
            Add-DiagnosticCheck '运行环境' $tool.Name 'OK' $version
        }
    }

    if (-not (Test-Path -LiteralPath (Join-Path $HarnessPath '.git'))) {
        Add-DiagnosticCheck 'Harness' '仓库' 'FAIL' "不是有效 Git 仓库：$HarnessPath"
    } else {
        $git = Get-Command 'git.exe' -ErrorAction SilentlyContinue
        if ($null -ne $git) {
            $origin = (& $git.Source -C $HarnessPath remote get-url origin 2>$null).Trim()
            $branch = (& $git.Source -C $HarnessPath branch --show-current 2>$null).Trim()
            $commit = (& $git.Source -C $HarnessPath rev-parse HEAD 2>$null).Trim()
            if ($origin -match 'github\.com[/:]deepseek-ai/deepseek-harness(?:\.git)?$') {
                Add-DiagnosticCheck 'Harness' '官方来源' 'OK' "$origin · $branch · $($commit.Substring(0, 8))"
            } else {
                Add-DiagnosticCheck 'Harness' '官方来源' 'WARN' "当前 origin：$origin"
            }
            $trackedChanges = @(& $git.Source -C $HarnessPath status --porcelain --untracked-files=no 2>$null)
            $managedCoreTarget = 'packages/core/tools/src/index.ts'
            $managedCoreState = Join-Path $HarnessPath '.git\dsh-launcher-core-compatibility.json'
            $onlyManagedCorePatch = $trackedChanges.Count -eq 1 -and
                ($trackedChanges[0].Substring(3) -replace '\\', '/') -eq $managedCoreTarget -and
                (Test-Path -LiteralPath $managedCoreState)
            if ($onlyManagedCorePatch) {
                Add-DiagnosticCheck 'Harness' '工作区' 'OK' '仅有启动器托管的核心兼容补丁；更新前会自动撤销，更新后自动重打'
            } elseif ($trackedChanges.Count -gt 0) {
                Add-DiagnosticCheck 'Harness' '工作区' 'WARN' "$($trackedChanges.Count) 项已跟踪修改会阻止自动更新"
            } else {
                Add-DiagnosticCheck 'Harness' '工作区' 'OK' '已跟踪文件干净，可安全快进更新'
            }
            $buildMarker = Join-Path $HarnessPath '.git\dsh-launcher-build-commit'
            $builtCommit = if (Test-Path -LiteralPath $buildMarker) { (Get-Content -LiteralPath $buildMarker -Raw -Encoding UTF8).Trim() } else { '' }
            if ($builtCommit -eq $commit -and (Test-Path -LiteralPath (Join-Path $HarnessPath 'apps\cli\lib\bin.js'))) {
                Add-DiagnosticCheck 'Harness' '构建状态' 'OK' "构建与提交 $($commit.Substring(0, 8)) 一致"
            } else {
                Add-DiagnosticCheck 'Harness' '构建状态' 'WARN' '构建标记缺失或与当前提交不一致；运行检查更新可自动修复'
            }
        }
        try {
            $core = Get-Content -LiteralPath (Join-Path $HarnessPath 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            Add-DiagnosticCheck 'Harness' '核心版本' 'OK' ([string]$core.version)
        } catch {
            Add-DiagnosticCheck 'Harness' '核心清单' 'FAIL' $_.Exception.Message
        }
        $coreCompatibility = Join-Path $LauncherRoot 'DSH-CoreCompatibility.ps1'
        if (Test-Path -LiteralPath $coreCompatibility) {
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $compatibilityOutput = @(& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -NoProfile -ExecutionPolicy Bypass -File $coreCompatibility -HarnessPath $HarnessPath -Action Status 2>&1 | ForEach-Object { $_.ToString() })
                $compatibilityExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $previous
            }
            if ($compatibilityExitCode -eq 0) {
                Add-DiagnosticCheck 'Harness' '工具调度器兼容性' 'OK' ($compatibilityOutput -join ' ')
            } else {
                Add-DiagnosticCheck 'Harness' '工具调度器兼容性' 'FAIL' ($compatibilityOutput -join ' ')
            }
        }
    }

    $profileRoot = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh' } else { $env:DSH_HOME }
    $profilePath = Join-Path $profileRoot "profiles\$ProfileName"
    $profileManifestPath = Join-Path $profilePath 'package.json'
    if (-not (Test-Path -LiteralPath $profileManifestPath)) {
        Add-DiagnosticCheck '插件' 'Web Profile' 'WARN' '尚未创建 Web profile'
    } else {
        try {
            $profile = Get-Content -LiteralPath $profileManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $bundles = @($profile.dsh.profile.bundles | ForEach-Object { [string]$_ })
            $dependencyNames = @($profile.dependencies.PSObject.Properties | ForEach-Object { [string]$_.Name })
            $managedBundles = @($bundles | Where-Object { $dependencyNames -contains $_ })
            $missingBundles = @($managedBundles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $profilePath "node_modules\$_\package.json")) })
            if ($missingBundles.Count -gt 0) {
                Add-DiagnosticCheck '插件' '已启用插件' 'FAIL' ("声明但未安装：" + ($missingBundles -join ', '))
            } else {
                Add-DiagnosticCheck '插件' '已启用插件' 'OK' "$($managedBundles.Count) 个第三方插件清单可解析"
            }
        } catch {
            Add-DiagnosticCheck '插件' 'Web Profile' 'FAIL' $_.Exception.Message
        }
    }

    $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $listener) {
        Add-DiagnosticCheck '服务' '端口 3080' 'OK' "正在监听，PID $($listener.OwningProcess)"
    } else {
        Add-DiagnosticCheck '服务' '端口 3080' 'WARN' '服务当前未运行'
    }

    $driveRoot = [System.IO.Path]::GetPathRoot($HarnessPath)
    $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($driveRoot.TrimEnd('\'))'" -ErrorAction SilentlyContinue
    if ($null -ne $drive) {
        $freeGb = [Math]::Round(([double]$drive.FreeSpace / 1GB), 1)
        if ($freeGb -lt 3) {
            Add-DiagnosticCheck '存储' '可用空间' 'WARN' "$freeGb GB；完整构建建议至少保留 3 GB"
        } else {
            Add-DiagnosticCheck '存储' '可用空间' 'OK' "$freeGb GB"
        }
    }
} catch {
    Add-DiagnosticCheck '诊断器' '未处理错误' 'FAIL' $_.Exception.Message
}

$failCount = @($checks | Where-Object { $_.status -eq 'FAIL' }).Count
$warningCount = @($checks | Where-Object { $_.status -eq 'WARN' }).Count
$overallStatus = if ($failCount -gt 0) { 'failed' } elseif ($warningCount -gt 0) { 'warning' } else { 'healthy' }
$result = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToString('o')
    status = $overallStatus
    harnessPath = $HarnessPath
    summary = [ordered]@{ passed = @($checks | Where-Object { $_.status -eq 'OK' }).Count; warnings = $warningCount; failed = $failCount }
    checks = @($checks)
}
[System.IO.File]::WriteAllText($resultPath, ($result | ConvertTo-Json -Depth 10) + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "[DSH][Diagnostics][SUMMARY] $overallStatus · $($result.summary.passed) 正常 · $warningCount 警告 · $failCount 失败 · 报告：$resultPath"
if ($failCount -gt 0) { exit 1 }
