$ErrorActionPreference = 'Stop'

$launcherRoot = $PSScriptRoot
$runtimeAssemblyPath = Join-Path $launcherRoot 'DSH-Launcher.Runtime.dll'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not (Test-Path -LiteralPath $runtimeAssemblyPath)) {
    throw "Launcher runtime assembly not found: $runtimeAssemblyPath"
}
Add-Type -LiteralPath $runtimeAssemblyPath

$stateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
$statePath = Join-Path $stateRoot 'launcher.json'
$launcherLogPath = Join-Path $stateRoot 'logs\launcher.log'
$defaultHarnessPath = Join-Path $launcherRoot 'deepseek-harness'
$xamlPath = Join-Path $launcherRoot 'LauncherWindow.xaml'
$compiledXamlPath = Join-Path $launcherRoot 'DSH-Launcher.Xaml.dll'
$launcherManifestPath = Join-Path $launcherRoot 'launcher-manifest.json'
$updateScript = Join-Path $launcherRoot 'DSH-Launcher.ps1'
$diagnosticsScript = Join-Path $launcherRoot 'DSH-Diagnostics.ps1'
$serverScript = Join-Path $launcherRoot 'Start-DSH-Web.cmd'
$appUserModelId = 'DeepSeek.DSH.WhaleMaidLauncher'
$launcherExecutable = Join-Path $launcherRoot 'DSH.exe'
$launcherIconPath = Join-Path $launcherRoot 'DSH-unified-v5.ico'
$launcherRelaunchCommand = '"' + $launcherExecutable + '"'
$launcherIconResource = $launcherIconPath + ',0'
$launcherVersion = 'unknown'
if (Test-Path -LiteralPath $launcherManifestPath) {
    try {
        $launcherManifest = Get-Content -LiteralPath $launcherManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not [string]::IsNullOrWhiteSpace([string]$launcherManifest.version)) {
            $launcherVersion = [string]$launcherManifest.version
        }
    } catch { }
}
$launcherVersionLabel = if ($launcherVersion -eq 'unknown') { 'v—' } else { "v$launcherVersion" }

New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
$instanceLockPath = Join-Path $stateRoot 'launcher.instance'
try {
    $script:instanceLockStream = [IO.File]::Open(
        $instanceLockPath,
        [IO.FileMode]::OpenOrCreate,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None)
} catch [IO.IOException] {
    [DshApplicationIdentity]::ActivateExistingWindow() | Out-Null
    exit 0
}

$script:backgroundRunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
$script:backgroundRunspacePool.ApartmentState = [Threading.ApartmentState]::MTA
$script:backgroundRunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
$script:backgroundRunspacePool.Open()
$script:runspaceWarmupTask = [DshRunspaceWarmup]::Begin($script:backgroundRunspacePool)

$restartArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
[DshApplicationIdentity]::EnableApplicationRestart($restartArguments) | Out-Null

[DshApplicationIdentity]::SetCurrentProcessExplicitAppUserModelID($appUserModelId) | Out-Null

function Test-HarnessInstallation {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path '.git')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'package.json')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'pnpm-lock.yaml'))
}

function Save-HarnessPath {
    param([Parameter(Mandatory)][string]$Path)

    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    [pscustomobject]@{
        harnessPath = [System.IO.Path]::GetFullPath($Path)
        updatedAt = (Get-Date).ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Get-SavedHarnessPath {
    if (-not (Test-Path -LiteralPath $statePath)) { return $null }
    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$state.harnessPath
    } catch {
        return $null
    }
}

function Resolve-HarnessPath {
    $projectRoot = Split-Path -Parent $launcherRoot
    $parentDirs = @($projectRoot, (Split-Path -Parent $projectRoot)) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $candidates = @(
        (Get-SavedHarnessPath),
        $defaultHarnessPath
    ) + @($parentDirs | ForEach-Object { Join-Path $_ 'deepseek-harness' }) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (Test-HarnessInstallation $candidate) {
            $resolved = [System.IO.Path]::GetFullPath($candidate)
            Save-HarnessPath $resolved
            return $resolved
        }
    }

    while ($true) {
        $picker = New-Object System.Windows.Forms.FolderBrowserDialog
        $picker.Description = "未检测到 DeepSeek Harness。请选择安装目录；启动器会在所选位置创建 deepseek-harness 文件夹。"
        $picker.SelectedPath = $launcherRoot
        $picker.ShowNewFolderButton = $true
        $result = $picker.ShowDialog()
        $selected = $picker.SelectedPath
        $picker.Dispose()

        if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
            [System.Windows.Forms.MessageBox]::Show(
                '未选择安装位置，DSH 启动器将退出。',
                'DSH',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return $null
        }

        $target = if ((Split-Path -Leaf $selected) -ieq 'deepseek-harness') {
            $selected
        } else {
            Join-Path $selected 'deepseek-harness'
        }
        $target = [System.IO.Path]::GetFullPath($target)

        if ((Test-Path -LiteralPath $target) -and -not (Test-HarnessInstallation $target)) {
            $entries = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue)
            if ($entries.Count -gt 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "所选目标不是有效的 Harness，且文件夹不为空：`n$target`n`n请重新选择。",
                    'DSH',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                continue
            }
        }

        Save-HarnessPath $target
        return $target
    }
}

function Test-MaidThemeInstalled {
    $themePath = @(
        (Join-Path $launcherRoot 'maid-atelier'),
        (Join-Path $launcherRoot 'plugins\maid-atelier'),
        (Join-Path (Split-Path -Parent $launcherRoot) 'maid-atelier')
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'package.json') } | Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($themePath)) { return $false }

    $profileRoot = if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
    } else {
        $env:DSH_HOME
    }
    $profileManifest = Join-Path $profileRoot 'profiles\web\package.json'
    if (-not (Test-Path -LiteralPath $profileManifest)) { return $false }

    try {
        $profile = Get-Content -LiteralPath $profileManifest -Raw -Encoding UTF8 | ConvertFrom-Json
        $themePackage = '@dsh-external/dsh-client-ui-skin-maid-atelier'
        $themeProperty = $profile.dependencies.PSObject.Properties[$themePackage]
        if ($null -eq $themeProperty) { return $false }
        $expected = [IO.Path]::GetFullPath($themePath) -replace '[\\/]+', '/'
        $registered = (([string]$themeProperty.Value) -replace '^(link:|file:)', '') -replace '[\\/]+', '/'
        return $registered.TrimEnd('/') -eq $expected.TrimEnd('/')
    } catch {
        return $false
    }
}

$repoPath = Resolve-HarnessPath
if ([string]::IsNullOrWhiteSpace($repoPath)) { exit 0 }
$script:harnessWasInstalled = Test-HarnessInstallation $repoPath
$webLogPath = Join-Path $repoPath 'dsh-web.log'

if (Test-Path -LiteralPath $compiledXamlPath) {
    Add-Type -LiteralPath $compiledXamlPath
    $window = [DshCompiledXaml]::LoadWindow()
} else {
    [xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $window = [Windows.Markup.XamlReader]::Load($reader)
}
$application = New-Object Windows.Application
$application.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown

function Write-LauncherCrashLog {
    param([Parameter(Mandatory)][Exception]$Exception)

    try {
        $logRoot = Join-Path $stateRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        $crashPath = Join-Path $logRoot 'launcher-crash.log'
        if ((Test-Path -LiteralPath $crashPath) -and (Get-Item -LiteralPath $crashPath).Length -gt 2MB) {
            $archivePath = $crashPath + '.1'
            if (Test-Path -LiteralPath $archivePath) { Remove-Item -LiteralPath $archivePath -Force }
            Move-Item -LiteralPath $crashPath -Destination $archivePath -Force
        }
        $entry = "[{0}] {1}`r`n{2}`r`n" -f (Get-Date).ToString('o'), $Exception.Message, $Exception.ToString()
        [IO.File]::AppendAllText($crashPath, $entry, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

$application.add_DispatcherUnhandledException({
    param($sender, $eventArgs)
    Write-LauncherCrashLog -Exception $eventArgs.Exception
    [Windows.MessageBox]::Show(
        "启动器遇到异常，已记录到：`n$stateRoot\logs\launcher-crash.log`n`n$($eventArgs.Exception.Message)",
        'DSH 启动器异常',
        [Windows.MessageBoxButton]::OK,
        [Windows.MessageBoxImage]::Error) | Out-Null
    $eventArgs.Handled = $true
})

function Get-Control {
    param([string]$Name)
    return $window.FindName($Name)
}

$dragArea = Get-Control 'DragArea'
$minimizeButton = Get-Control 'MinimizeButton'
$closeButton = Get-Control 'CloseButton'
$openWebButton = Get-Control 'OpenWebButton'
$stopButton = Get-Control 'StopButton'
$restartButton = Get-Control 'RestartButton'
$updateButton = Get-Control 'UpdateButton'
$pluginManagerButton = Get-Control 'PluginManagerButton'
$diagnosticsButton = Get-Control 'DiagnosticsButton'
$openFolderButton = Get-Control 'OpenFolderButton'
$terminalButton = Get-Control 'TerminalButton'
$terminalButtonText = Get-Control 'TerminalButtonText'
$openWebButtonText = Get-Control 'OpenWebButtonText'
$openWebButtonIcon = Get-Control 'OpenWebButtonIcon'
$terminalPanel = Get-Control 'TerminalPanel'
$terminalOutput = Get-Control 'TerminalOutput'
$terminalInput = Get-Control 'TerminalInput'
$activityProgress = Get-Control 'ActivityProgress'
$statusDot = Get-Control 'StatusDot'
$statusTitle = Get-Control 'StatusTitle'
$statusDetail = Get-Control 'StatusDetail'
$serviceStateLabel = Get-Control 'ServiceStateLabel'
$portStateLabel = Get-Control 'PortStateLabel'
$commitLabel = Get-Control 'CommitLabel'
$harnessPathLabel = Get-Control 'HarnessPathLabel'
$brandIcon = Get-Control 'BrandIcon'
$maidImage = Get-Control 'MaidImage'
$maidImageBrush = Get-Control 'MaidImageBrush'
$headerVersionLabel = Get-Control 'HeaderVersionLabel'
$launcherVersionText = Get-Control 'LauncherVersionLabel'

function New-OptimizedBitmapImage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$DecodePixelWidth = 0
    )

    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.CreateOptions = [System.Windows.Media.Imaging.BitmapCreateOptions]::IgnoreImageCache
    if ($DecodePixelWidth -gt 0) { $bitmap.DecodePixelWidth = $DecodePixelWidth }
    $bitmap.UriSource = [Uri]$Path
    $bitmap.EndInit()
    $bitmap.Freeze()
    return $bitmap
}

if ($null -ne $headerVersionLabel) { $headerVersionLabel.Text = $launcherVersionLabel }
if ($null -ne $launcherVersionText) { $launcherVersionText.Text = $launcherVersionLabel }

$iconPath = Join-Path $launcherRoot 'DSH-unified-v5.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch { }
}

$maidImagePath = Join-Path $launcherRoot 'assets\DSH-office-maid-display.jpg'
$brandIconPath = Join-Path $launcherRoot 'assets\DSHarness-v2-display.png'
if (Test-Path -LiteralPath $brandIconPath) {
    try {
        $brandIcon.Source = New-OptimizedBitmapImage -Path $brandIconPath -DecodePixelWidth 96
        $brandIcon.Visibility = 'Visible'
    } catch { }
}
if (Test-Path -LiteralPath $maidImagePath) {
    try {
        $maidImageBrush.ImageSource = New-OptimizedBitmapImage -Path $maidImagePath -DecodePixelWidth 560
        $maidImage.Visibility = 'Visible'
    } catch { }
}

$script:activeJob = $null
$script:activeJobKind = ''
$script:startupLogJob = $null
$script:allowExit = $false
$script:trayHintShown = $false
$script:updateWasInstall = $false
$script:launcherLogOffset = 0L
$script:webLogOffset = 0L
$script:isBusy = $false
$script:isWebRunning = $false
$script:serviceProbeTask = $null
$webAddress = 'http://127.0.0.1:3080/'

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = New-Object System.Drawing.Icon -ArgumentList (Join-Path $launcherRoot 'DSH-unified-v5.ico')
$trayIcon.Text = "DSH $launcherVersionLabel - DeepSeek Harness"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem('显示 DSH')
$openWebTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem('启动 WebUI')
$restartTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem('重启 WebUI')
$exitTrayItem = New-Object System.Windows.Forms.ToolStripMenuItem('彻底退出')
[void]$trayMenu.Items.Add($showTrayItem)
[void]$trayMenu.Items.Add($openWebTrayItem)
[void]$trayMenu.Items.Add($restartTrayItem)
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$trayMenu.Items.Add($exitTrayItem)
$trayIcon.ContextMenuStrip = $trayMenu

function Start-BackgroundOperation {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $shell = [System.Management.Automation.PowerShell]::Create()
    $inputBuffer = New-Object 'System.Management.Automation.PSDataCollection[System.Management.Automation.PSObject]'
    $outputBuffer = New-Object 'System.Management.Automation.PSDataCollection[System.Management.Automation.PSObject]'
    try {
        $shell.RunspacePool = $script:backgroundRunspacePool
        [void]$shell.AddScript($ScriptBlock.ToString())
        foreach ($argument in $ArgumentList) { [void]$shell.AddArgument($argument) }
        $inputBuffer.Complete()
        $asyncResult = [DshAsyncPowerShell]::Begin($shell, $inputBuffer, $outputBuffer)
        return [pscustomobject]@{
            Shell       = $shell
            Input       = $inputBuffer
            Output      = $outputBuffer
            OutputIndex = 0
            AsyncResult = $asyncResult
        }
    } catch {
        $shell.Dispose()
        $inputBuffer.Dispose()
        $outputBuffer.Dispose()
        throw
    }
}

function Receive-BackgroundOperation {
    param([Parameter(Mandatory)][object]$Operation)

    $items = New-Object System.Collections.Generic.List[object]
    # PSDataCollection's PowerShell index adapter can return $null even when Count
    # reports buffered objects. ReadAll is the thread-safe consumer API and removes
    # only the items returned in this snapshot while the producer keeps running.
    foreach ($item in @($Operation.Output.ReadAll())) {
        # PowerShell already exposes PSDataCollection items as their adapted base
        # objects. Testing `-is [PSObject]` is misleading here (even strings match)
        # and reading BaseObject then yields $null.
        $items.Add($item)
    }
    return $items.ToArray()
}

function Complete-BackgroundOperation {
    param([Parameter(Mandatory)][object]$Operation)

    $reason = $null
    try {
        $null = $Operation.Shell.EndInvoke($Operation.AsyncResult)
    } catch {
        $reason = $_.Exception
    }
    $state = $Operation.Shell.InvocationStateInfo.State.ToString()
    if ($null -eq $reason) { $reason = $Operation.Shell.InvocationStateInfo.Reason }
    $remaining = @(Receive-BackgroundOperation -Operation $Operation)
    $Operation.Shell.Dispose()
    $Operation.Input.Dispose()
    $Operation.Output.Dispose()
    return [pscustomobject]@{ State = $state; Reason = $reason; Output = $remaining }
}

function Stop-BackgroundOperation {
    param([object]$Operation)

    if ($null -eq $Operation) { return }
    try { $Operation.Shell.Stop() } catch { }
    try { $null = $Operation.Shell.EndInvoke($Operation.AsyncResult) } catch { }
    $Operation.Shell.Dispose()
    $Operation.Input.Dispose()
    $Operation.Output.Dispose()
}

function Append-TerminalLines {
    param([object[]]$Lines)

    if ($null -eq $Lines -or $Lines.Count -eq 0) { return }
    $builder = New-Object Text.StringBuilder
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $text = $line.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        [void]$builder.AppendLine($text)
    }
    if ($builder.Length -eq 0) { return }
    $terminalOutput.AppendText($builder.ToString())
    if ($terminalOutput.Text.Length -gt 750000) {
        $terminalOutput.Text = $terminalOutput.Text.Substring($terminalOutput.Text.Length - 500000)
        $terminalOutput.CaretIndex = $terminalOutput.Text.Length
    }
    $terminalOutput.ScrollToEnd()
}

function Append-TerminalLine {
    param([object]$Line)
    Append-TerminalLines -Lines @($Line)
}


function Read-LauncherLogDelta {
    if (-not (Test-Path -LiteralPath $launcherLogPath)) { return }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $launcherLogPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        if ($stream.Length -lt $script:launcherLogOffset) {
            $script:launcherLogOffset = 0L
        }
        if ($stream.Length -eq $script:launcherLogOffset) { return }

        [void]$stream.Seek($script:launcherLogOffset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $true, 4096, $true)
        $text = $reader.ReadToEnd()
        $script:launcherLogOffset = $stream.Position
        $displayLines = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($text -split '\r?\n|\r')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $displayLines.Add(($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''))
            }
        }
        Append-TerminalLines -Lines $displayLines.ToArray()
    } catch {
        # The updater may rotate or reopen the file. The next timer tick retries.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}


function Read-WebLogDelta {
    if (-not (Test-Path -LiteralPath $webLogPath)) { return }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $webLogPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        if ($stream.Length -lt $script:webLogOffset) {
            $script:webLogOffset = 0L
        }
        if ($stream.Length -eq $script:webLogOffset) { return }

        [void]$stream.Seek($script:webLogOffset, [IO.SeekOrigin]::Begin)
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $true, 4096, $true)
        $text = $reader.ReadToEnd()
        $script:webLogOffset = $stream.Position
        $displayLines = New-Object System.Collections.Generic.List[object]
        foreach ($line in ($text -split '\r?\n|\r')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $displayLines.Add(($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''))
            }
        }
        Append-TerminalLines -Lines $displayLines.ToArray()
    } catch {
        # A writer may briefly rotate or reopen the file. The next timer tick retries.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-WebUiUrl {
    # The Harness CLI prints the tokenized handoff URL once the Loader tree is
    # ready to serve the browser, and that token is what the WebUI exchanges for
    # its session cookie. The canonical address alone lands on a page the user
    # has to refresh, so prefer the last URL the current server logged.
    if (-not (Test-Path -LiteralPath $webLogPath)) { return $webAddress }

    $stream = $null
    $reader = $null
    try {
        $stream = [IO.File]::Open(
            $webLogPath,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        if ($stream.Length -gt 131072) {
            [void]$stream.Seek(-131072, [IO.SeekOrigin]::End)
        }
        $reader = New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false)), $true)
        $matches = [regex]::Matches($reader.ReadToEnd(), 'dsh web:\s+(http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+)')
        if ($matches.Count -gt 0) {
            return $matches[$matches.Count - 1].Groups[1].Value
        }
    } catch {
        # A rotated or unreadable log only costs the tokenized handoff.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }

    return $webAddress
}


function Start-ServiceProbe {
    if ($null -eq $script:serviceProbeTask) {
        $script:serviceProbeTask = [DshNetworkProbe]::Begin(80)
    }
}

function Set-ServiceState {
    param([bool]$Running)

    $script:isWebRunning = $Running
    if ($Running) {
        $openWebButtonText.Text = '打开 WebUI'
        $openWebButtonIcon.Text = '↗'
        $serviceStateLabel.Text = '服务运行中'
        $serviceStateLabel.Foreground = '#18794E'
        $portStateLabel.Text = '3080 · 监听中'
        $portStateLabel.Foreground = '#18794E'
        $statusDot.Background = '#22A06B'
        $openWebTrayItem.Text = '打开 WebUI'
    } else {
        $openWebButtonText.Text = '启动 WebUI'
        $openWebButtonIcon.Text = '▶'
        $serviceStateLabel.Text = '服务未运行'
        $serviceStateLabel.Foreground = '#526078'
        $portStateLabel.Text = '3080 · 空闲'
        $portStateLabel.Foreground = '#526078'
        $statusDot.Background = '#8A98AD'
        $openWebTrayItem.Text = '启动 WebUI'
    }

    $stopButton.IsEnabled = $Running -and -not $script:isBusy
    $restartButton.IsEnabled = (Test-HarnessInstallation $repoPath) -and -not $script:isBusy
}

function Set-LauncherBusy {
    param(
        [bool]$Busy,
        [string]$Title,
        [string]$Detail
    )

    $script:isBusy = $Busy
    $openWebButton.IsEnabled = -not $Busy
    $stopButton.IsEnabled = $script:isWebRunning -and -not $Busy
    $restartButton.IsEnabled = (Test-HarnessInstallation $repoPath) -and -not $Busy
    $updateButton.IsEnabled = -not $Busy
    $pluginManagerButton.IsEnabled = -not $Busy
    $diagnosticsButton.IsEnabled = -not $Busy
    $openFolderButton.IsEnabled = -not $Busy
    $terminalInput.IsEnabled = -not $Busy
    $activityProgress.Visibility = if ($Busy) { 'Visible' } else { 'Collapsed' }
    $statusTitle.Text = $Title
    $statusDetail.Text = $Detail
    if ($Busy) {
        $statusDot.Background = '#E7A83E'
        $serviceStateLabel.Text = '正在处理'
        $serviceStateLabel.Foreground = '#9A6700'
    } else {
        Set-ServiceState $script:isWebRunning
    }
}

function Invoke-ExactLogRotation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaximumBytes = 20MB,
        [int]$Keep = 3
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
    $script:webLogOffset = 0L
}

function Show-DshWindow {
    if ($null -ne $webLogTimer) { $webLogTimer.Start() }
    if ($null -ne $serviceStateTimer) { $serviceStateTimer.Start() }
    $window.ShowInTaskbar = $true
    $window.Show()
    if ($window.WindowState -eq [Windows.WindowState]::Minimized) {
        $window.WindowState = [Windows.WindowState]::Normal
    }
    $window.Activate() | Out-Null
    $window.Topmost = $true
    $window.Topmost = $false
    $window.Focus() | Out-Null
}

function Hide-DshToTray {
    if ($null -ne $webLogTimer) { $webLogTimer.Stop() }
    if ($null -ne $serviceStateTimer) { $serviceStateTimer.Stop() }
    $window.ShowInTaskbar = $false
    $window.Hide()
    if (-not $script:trayHintShown) {
        $trayIcon.BalloonTipTitle = 'DSH 仍在运行'
        $trayIcon.BalloonTipText = '已最小化到系统托盘。双击鲸鱼娘图标即可恢复。'
        $trayIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        $trayIcon.ShowBalloonTip(2500)
        $script:trayHintShown = $true
    }
}

function Update-CommitLabel {
    if (-not (Test-HarnessInstallation $repoPath)) {
        $commitLabel.Text = 'INSTALL'
        return
    }
    try {
        $gitMarker = Join-Path $repoPath '.git'
        $gitDirectory = $gitMarker
        if (-not (Test-Path -LiteralPath $gitMarker -PathType Container)) {
            $pointer = [IO.File]::ReadAllText($gitMarker).Trim()
            if ($pointer -notmatch '^gitdir:\s*(.+)$') { throw 'Invalid .git pointer.' }
            $gitDirectory = $matches[1]
            if (-not [IO.Path]::IsPathRooted($gitDirectory)) {
                $gitDirectory = Join-Path $repoPath $gitDirectory
            }
            $gitDirectory = [IO.Path]::GetFullPath($gitDirectory)
        }

        $head = [IO.File]::ReadAllText((Join-Path $gitDirectory 'HEAD')).Trim()
        $commit = $head
        if ($head -match '^ref:\s*(.+)$') {
            $refName = $matches[1]
            $refPath = Join-Path $gitDirectory ($refName -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (Test-Path -LiteralPath $refPath) {
                $commit = [IO.File]::ReadAllText($refPath).Trim()
            } else {
                $packedRefsPath = Join-Path $gitDirectory 'packed-refs'
                $packedLine = if (Test-Path -LiteralPath $packedRefsPath) {
                    [IO.File]::ReadLines($packedRefsPath) |
                        Where-Object { $_ -match ('^([0-9a-fA-F]{40})\s+' + [regex]::Escape($refName) + '$') } |
                        Select-Object -First 1
                }
                if ($packedLine -match '^([0-9a-fA-F]{40})') { $commit = $matches[1] }
            }
        }
        if ($commit -match '^[0-9a-fA-F]{8,}$') {
            $commitLabel.Text = $commit.Substring(0, 8).ToUpperInvariant()
        } else {
            $commitLabel.Text = 'LOCAL'
        }
    } catch {
        $commitLabel.Text = 'LOCAL'
    }
}

function Get-CompatibilityStatus {
    $statusPath = Join-Path $stateRoot 'launcher-core-compatibility.json'
    if (-not (Test-Path -LiteralPath $statusPath)) { return $null }
    try {
        return Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Get-LastUpdateResult {
    $resultPath = Join-Path $stateRoot 'last-update-result.json'
    if (-not (Test-Path -LiteralPath $resultPath)) { return $null }
    try {
        return Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Start-UpdateCheck {
    if ($null -ne $script:activeJob) { return }

    $installing = -not (Test-HarnessInstallation $repoPath)
    Append-TerminalLine ''
    Append-TerminalLine $(if ($installing) {
        "[DSH] Installing the complete official Harness to $repoPath ..."
    } else {
        '[DSH] Checking for official Harness updates...'
    })
    if ($installing) {
        Set-LauncherBusy $true '正在安装 Harness' "完整核心将安装到：$repoPath"
    } else {
        Set-LauncherBusy $true '正在检查更新' '正在检查 Harness 核心与已安装的 Web 插件'
    }
    $script:updateWasInstall = $installing
    $script:activeJobKind = 'update'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($PowerShellPath, $UpdateScriptPath, $HarnessPath)
        & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $UpdateScriptPath `
            -CheckOnly -HarnessPath $HarnessPath 2>&1 |
            ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw "Update helper exited with code $LASTEXITCODE"
        }
    } -ArgumentList 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', $updateScript, $repoPath
}

function Start-SystemDiagnostics {
    if ($null -ne $script:activeJob) { return }

    Append-TerminalLine ''
    Append-TerminalLine '[DSH] Running full launcher, core, profile, network and disk diagnostics...'
    $terminalPanel.Visibility = 'Visible'
    $terminalButtonText.Text = '收起终端'
    Set-LauncherBusy $true '正在系统诊断' '正在检查启动器、核心、插件、端口与运行环境'
    $script:activeJobKind = 'diagnostics'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($PowerShellPath, $DiagnosticsScriptPath, $HarnessPath, $LauncherPath)
        & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $DiagnosticsScriptPath `
            -HarnessPath $HarnessPath -LauncherRoot $LauncherPath 2>&1 |
            ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw "Diagnostics helper exited with code $LASTEXITCODE"
        }
    } -ArgumentList 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', $diagnosticsScript, $repoPath, $launcherRoot
}

function Start-WebUi {
    if ($null -ne $script:activeJob) { return }
    if (-not (Test-HarnessInstallation $repoPath)) {
        Append-TerminalLine '[ERROR] Harness is not installed. Run the update/install action first.'
        Set-LauncherBusy $false 'Harness 尚未安装' '请先点击检查更新以完成安装'
        $statusDot.Background = '#FF6B72'
        return
    }

    Set-LauncherBusy $true '正在检查 WebUI' '正在确认本地服务状态'
    if ($script:isWebRunning) {
        Set-ServiceState $true
        Set-LauncherBusy $false '服务运行中' '已在系统默认浏览器中打开 WebUI'
        try { Start-Process (Get-WebUiUrl) | Out-Null } catch {
            Append-TerminalLine ("[WARN] Unable to open the browser: " + $_.Exception.Message)
        }
        return
    }

    Invoke-ExactLogRotation -Path $webLogPath
    Append-TerminalLine ''
    Append-TerminalLine '[DSH] Preparing the WebUI...'
    Set-LauncherBusy $true '正在启动 WebUI' '正在启动本地服务，准备就绪后将打开浏览器'
    $script:activeJobKind = 'web'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($RepoPath, $ServerScriptPath, $WebLogPath)

        $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        $wasRunning = $null -ne $listener
        if (-not $wasRunning) {
            '[DSH] Starting pnpm dsh web in the background...'
            Start-Process -FilePath $env:ComSpec `
                -ArgumentList @('/d', '/s', '/c', ('""{0}" "{1}""' -f $ServerScriptPath, $RepoPath)) `
                -WorkingDirectory $RepoPath `
                -WindowStyle Hidden | Out-Null

            for ($attempt = 0; $attempt -lt 90; $attempt++) {
                Start-Sleep -Seconds 1
                $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $listener) { break }
                if (($attempt + 1) % 5 -eq 0) {
                    "[DSH] Waiting for WebUI... $($attempt + 1)s"
                }
            }
        } else {
            "[DSH] WebUI is already running (PID $($listener.OwningProcess))."
        }

        if ($null -eq $listener) {
            throw "WebUI did not become ready on port 3080. Check $RepoPath\dsh-web.log."
        }

        # The listening port appears before the Loader tree settles, and the CLI
        # logs the tokenized handoff URL only once the host can serve the
        # browser. Opening the canonical address inside that window is what
        # forces a manual refresh, so wait for the logged URL.
        $handoffLogged = $false
        $handoffAttempts = if ($wasRunning) { 1 } else { 60 }
        $handoffPattern = 'dsh web:\s+http://127\.0\.0\.1:\d+/\?token=[A-Za-z0-9_\-]+'
        for ($attempt = 0; $attempt -lt $handoffAttempts; $attempt++) {
            $logTail = ''
            if (Test-Path -LiteralPath $WebLogPath) {
                $logStream = $null
                $logReader = $null
                try {
                    $logStream = [IO.File]::Open($WebLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
                    $logReader = New-Object IO.StreamReader($logStream, (New-Object Text.UTF8Encoding($false)), $true)
                    $logText = $logReader.ReadToEnd()
                    $logTail = if ($logText.Length -gt 65536) { $logText.Substring($logText.Length - 65536) } else { $logText }
                } catch {
                    $logTail = ''
                } finally {
                    if ($null -ne $logReader) { $logReader.Dispose() }
                    if ($null -ne $logStream) { $logStream.Dispose() }
                }
            }
            if ($logTail -match $handoffPattern) { $handoffLogged = $true; break }
            if ($attempt + 1 -ge $handoffAttempts) { break }
            Start-Sleep -Seconds 1
            if (($attempt + 1) % 5 -eq 0) {
                "[DSH] Waiting for the WebUI handoff URL... $($attempt + 1)s"
            }
        }

        if ($handoffLogged) {
            '[DSH] Harness is ready. The launcher will open the browser.'
        } else {
            '[DSH] The WebUI port is open but the handoff URL is not in the log yet. Opening the canonical address.'
        }
    } -ArgumentList $repoPath, $serverScript, $webLogPath
}

function Stop-WebUi {
    if ($null -ne $script:activeJob) { return }

    Append-TerminalLine '[DSH] Stopping the WebUI service...'
    Set-LauncherBusy $true '正在停止 WebUI' '正在结束本地 Harness 服务进程'
    $script:activeJobKind = 'stop'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $listener) {
            '[DSH] WebUI is not running (port 3080 is free).'
            return
        }
        $processId = $listener.OwningProcess
        & taskkill.exe /PID $processId /T /F 2>&1 | ForEach-Object { $_.ToString() }
        Start-Sleep -Seconds 1
        $after = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $after) {
            "[DSH] WebUI stopped (PID $processId)."
        } else {
            throw "WebUI is still listening on port 3080 (PID $($after.OwningProcess))."
        }
    }
}

function Restart-WebUi {
    if ($null -ne $script:activeJob) { return }
    if (-not (Test-HarnessInstallation $repoPath)) {
        Append-TerminalLine '[ERROR] Harness is not installed. Run the update/install action first.'
        Set-LauncherBusy $false 'Harness 尚未安装' '请先点击检查更新以完成安装'
        $statusDot.Background = '#FF6B72'
        return
    }

    Append-TerminalLine ''
    Append-TerminalLine '[DSH] Restarting the WebUI service...'
    Set-LauncherBusy $true '正在重启 WebUI' '正在停止旧服务并重新启动本地 Harness'
    $script:activeJobKind = 'restart'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($RepoPath, $ServerScriptPath, $WebLogPath)

        # 1) Stop whatever is listening on 3080 (if anything)
        $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $listener) {
            $processId = $listener.OwningProcess
            '[DSH] Stopping the old WebUI service...'
            & taskkill.exe /PID $processId /T /F 2>&1 | ForEach-Object { $_.ToString() }
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                Start-Sleep -Milliseconds 500
                $after = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -eq $after) { break }
            }
            $after = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $after) {
                throw "WebUI is still listening on port 3080 (PID $($after.OwningProcess))."
            }
            "[DSH] Old WebUI stopped (PID $processId)."
        } else {
            '[DSH] WebUI was not running — starting a fresh instance.'
        }

        if ((Test-Path -LiteralPath $WebLogPath) -and (Get-Item -LiteralPath $WebLogPath).Length -gt 20MB) {
            for ($index = 3; $index -ge 1; $index--) {
                $destination = "$WebLogPath.$index"
                if ($index -eq 3 -and (Test-Path -LiteralPath $destination)) { Remove-Item -LiteralPath $destination -Force }
                $source = if ($index -eq 1) { $WebLogPath } else { "$WebLogPath.$($index - 1)" }
                if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $destination -Force }
            }
        }

        # 2) Start it again
        '[DSH] Starting pnpm dsh web in the background...'
        Start-Process -FilePath $env:ComSpec `
            -ArgumentList @('/d', '/s', '/c', ('""{0}" "{1}""' -f $ServerScriptPath, $RepoPath)) `
            -WorkingDirectory $RepoPath `
            -WindowStyle Hidden | Out-Null

        for ($attempt = 0; $attempt -lt 90; $attempt++) {
            Start-Sleep -Seconds 1
            $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $listener) { break }
            if (($attempt + 1) % 5 -eq 0) {
                "[DSH] Waiting for WebUI... $($attempt + 1)s"
            }
        }

        if ($null -eq $listener) {
            throw "WebUI did not become ready on port 3080. Check $RepoPath\dsh-web.log."
        }

        '[DSH] Harness restarted.'
    } -ArgumentList $repoPath, $serverScript, $webLogPath
}
$script:pluginManagerScript = Join-Path $launcherRoot 'DSH-PluginManager.ps1'
$script:pluginCachePath = Join-Path $stateRoot 'plugin-list-cache.json'
$script:pluginListData = @()
if (Test-Path -LiteralPath $script:pluginCachePath) {
    try {
        $script:pluginListData = @(Get-Content -LiteralPath $script:pluginCachePath -Raw -Encoding UTF8 |
            ConvertFrom-Json | ForEach-Object { $_ })
    } catch {
        $script:pluginListData = @()
    }
}

function Invoke-PluginManager {
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Name
    )

    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $script:pluginManagerScript,
        '-Action', $Action,
        '-HarnessPath', $repoPath
    )
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $arguments += @('-Name', $Name)
    }
    $output = @(& 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' @arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($LASTEXITCODE -ne 0) {
        throw (($output | Select-Object -Last 8) -join [Environment]::NewLine)
    }
    return $output
}

function Refresh-PluginList {
    if ($null -ne $script:pluginLoadJob) {
        if ($null -ne $script:pluginManagerDialogStatus) { $script:pluginManagerDialogStatus.Text = '正在加载插件列表…' }
        return
    }
    if (-not (Test-Path -LiteralPath $script:pluginManagerScript)) {
        if ($null -ne $script:pluginManagerDialogStatus) { $script:pluginManagerDialogStatus.Text = '插件管理脚本未找到' }
        return
    }
    if (-not (Test-HarnessInstallation $repoPath)) {
        if ($null -ne $script:pluginManagerDialogStatus) { $script:pluginManagerDialogStatus.Text = 'Harness 未安装，无法读取插件' }
        return
    }
    if ($null -ne $script:pluginManagerDialogStatus) { $script:pluginManagerDialogStatus.Text = '正在加载插件列表…' }

    # 在后台任务中运行插件管理器，避免在 UI 线程上同步启动 powershell.exe 造成卡顿
    $script:pluginLoadJob = Start-BackgroundOperation -ScriptBlock {
        param($ManagerScriptPath, $HarnessPath)
        # The list action is read-only and safe to run in the existing pool. Avoiding a
        # second powershell.exe removes most of the first-open latency.
        & $ManagerScriptPath -Action list -HarnessPath $HarnessPath 2>&1 |
            ForEach-Object { $_.ToString() }
    } -ArgumentList $script:pluginManagerScript, $repoPath
}

function Start-PluginManagerAction {
    param(
        [Parameter(Mandatory)][ValidateSet('enable', 'disable', 'update')][string]$Action,
        [Parameter(Mandatory)][object]$Plugin
    )

    if ($null -ne $script:activeJob) { return }
    $isUpdate = $Action -eq 'update'
    Set-LauncherBusy $true $(if ($isUpdate) { '正在更新插件' } else { '正在更新插件状态' }) "正在$Action $($Plugin.Name)"
    $script:activeJobKind = if ($isUpdate) { 'plugin-update' } else { 'plugin-toggle' }
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($PowerShellPath, $ManagerScriptPath, $HarnessPath, $RequestedAction, $PluginName)
        & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $ManagerScriptPath `
            -Action $RequestedAction -Name $PluginName -HarnessPath $HarnessPath 2>&1 |
            ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw "Plugin manager exited with code $LASTEXITCODE"
        }
    } -ArgumentList 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', $script:pluginManagerScript, $repoPath, $Action, $Plugin.Name
}

function Show-PluginManager {
    if ($null -ne $script:activeJob) { return }

    $dialog = New-Object Windows.Window
    $dialog.Title = 'Web 插件管理'
    $dialog.Width = 840
    $dialog.Height = 620
    $dialog.MinWidth = 760
    $dialog.MinHeight = 520
    $dialog.Owner = $window
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $dialog.WindowStyle = 'None'
    $dialog.AllowsTransparency = $false
    $dialog.ResizeMode = 'NoResize'
    $dialog.Background = '#F5F5F7'
    $dialog.FontFamily = 'Segoe UI Variable, Microsoft YaHei UI'

    # 标题栏 / 任务栏图标从 PowerShell 默认图标换成 DSH 黑鲸图标
    $dialogIconPath = Join-Path $launcherRoot 'DSH-unified-v5.ico'
    if (Test-Path -LiteralPath $dialogIconPath) {
        try { $dialog.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$dialogIconPath) } catch { }
    }

    # ---------- 与启动器一致的配色 ----------
    $pageBg     = '#F5F5F7'
    $headerBg   = '#FBFBFD'
    $surface    = '#FFFFFF'
    $border     = '#E5E5EA'
    $cardBorder = '#EBEBF0'
    $textPri    = '#1D1D1F'
    $textSec    = '#6E6E73'
    $textMuted  = '#86868B'

    # ---------- 按钮模板（贴近启动器 SecondaryButton / DangerButton / PrimaryButton） ----------
    $tplSecondary = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="B" Property="Background" Value="#EAF3FC"/>
      <Setter TargetName="B" Property="BorderBrush" Value="#6FA8DC"/>
      <Setter Property="Foreground" Value="#005FB8"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="B" Property="Background" Value="#DCEAF7"/>
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter Property="Opacity" Value="0.45"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@

    $tplPrimary = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="B" Property="Background" Value="#0077ED"/>
      <Setter TargetName="B" Property="BorderBrush" Value="#0077ED"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="B" Property="Background" Value="#005FC1"/>
      <Setter TargetName="B" Property="BorderBrush" Value="#005FC1"/>
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter Property="Opacity" Value="0.45"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@

    $tplDanger = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}" RecognizesAccessKey="True"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="B" Property="Background" Value="#FDE8E7"/>
      <Setter TargetName="B" Property="BorderBrush" Value="#D96A63"/>
    </Trigger>
    <Trigger Property="IsPressed" Value="True">
      <Setter TargetName="B" Property="Background" Value="#F6D4D1"/>
    </Trigger>
    <Trigger Property="IsEnabled" Value="False">
      <Setter Property="Foreground" Value="#B42318"/>
      <Setter Property="Opacity" Value="0.45"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@

    $tplClose = @'
<ControlTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" TargetType="Button">
  <Border x:Name="C" Background="{TemplateBinding Background}" CornerRadius="0">
    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
  </Border>
  <ControlTemplate.Triggers>
    <Trigger Property="IsMouseOver" Value="True">
      <Setter TargetName="C" Property="Background" Value="#FDECEB"/>
      <Setter Property="Foreground" Value="#B42318"/>
    </Trigger>
  </ControlTemplate.Triggers>
</ControlTemplate>
'@

    $secTpl = [System.Windows.Markup.XamlReader]::Parse($tplSecondary)
    $priTpl = [System.Windows.Markup.XamlReader]::Parse($tplPrimary)
    $dngTpl = [System.Windows.Markup.XamlReader]::Parse($tplDanger)
    $clsTpl = [System.Windows.Markup.XamlReader]::Parse($tplClose)

    function New-ThemeButton {
        param([string]$Text, [string]$Kind = 'Secondary', [object]$Template)
        $b = New-Object Windows.Controls.Button
        $b.Content = $Text
        $b.MinWidth = 76
        $b.Height = 36
        $b.Margin = '8,0,0,0'
        $b.Padding = '14,0'
        $b.FontSize = 13
        $b.FontWeight = [Windows.FontWeights]::SemiBold
        $b.Cursor = [Windows.Input.Cursors]::Hand
        $b.BorderThickness = '1'
        $b.Focusable = $false
        $b.Template = $Template
        if ($Kind -eq 'Primary') {
            $b.Foreground = '#FFFFFF'
            $b.Background = '#0071E3'
            $b.BorderBrush = '#0068D1'
        } elseif ($Kind -eq 'Danger') {
            $b.Foreground = '#B42318'
            $b.Background = '#FFFFFF'
            $b.BorderBrush = '#E2B8B5'
        } else {
            $b.Foreground = $textPri
            $b.Background = '#FFFFFF'
            $b.BorderBrush = '#D1D1D6'
        }
        return $b
    }

    # ---------- 外框：保持无边框样式，但使用普通不透明窗口以启用硬件合成 ----------
    $outer = New-Object Windows.Controls.Grid
    $outer.Background = $pageBg

    $chrome = New-Object Windows.Controls.Border
    $chrome.Margin = '0'
    $chrome.CornerRadius = '0'
    $chrome.Background = $pageBg
    $chrome.BorderBrush = '#E4E4E8'
    $chrome.BorderThickness = '1'
    $outer.Children.Add($chrome) | Out-Null

    $clipGrid = New-Object Windows.Controls.Grid
    $clipGrid.ClipToBounds = $true
    $chrome.Child = $clipGrid
    [void]$clipGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '56' }))
    [void]$clipGrid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))

    # ---------- 顶栏：黑鲸图标 + 标题 + 关闭按钮 ----------
    $headerBorder = New-Object Windows.Controls.Border
    $headerBorder.Background = $headerBg
    $headerBorder.BorderBrush = $border
    $headerBorder.BorderThickness = '0,0,0,1'
    $headerBorder.CornerRadius = '0'
    [Windows.Controls.Grid]::SetRow($headerBorder, 0)
    $clipGrid.Children.Add($headerBorder) | Out-Null

    $headerGrid = New-Object Windows.Controls.Grid
    $headerBorder.Child = $headerGrid

    $dragArea = New-Object Windows.Controls.Grid
    $dragArea.Background = 'Transparent'
    $dragArea.Margin = '0,0,96,0'
    $headerGrid.Children.Add($dragArea) | Out-Null

    $brandStack = New-Object Windows.Controls.StackPanel
    $brandStack.Orientation = 'Horizontal'
    $brandStack.VerticalAlignment = 'Center'
    $brandStack.Margin = '20,0,0,0'
    $dragArea.Children.Add($brandStack) | Out-Null

    $whale = New-Object Windows.Controls.Image
    $whale.Width = 26
    $whale.Height = 26
    $whale.Stretch = 'Uniform'
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($whale, [Windows.Media.BitmapScalingMode]::HighQuality)
    $whalePath = Join-Path $launcherRoot 'assets\DSHarness-v2-display.png'
    if (Test-Path -LiteralPath $whalePath) {
        try { $whale.Source = New-OptimizedBitmapImage -Path $whalePath -DecodePixelWidth 64 } catch { }
    }
    $brandStack.Children.Add($whale) | Out-Null

    $titleBlock = New-Object Windows.Controls.TextBlock
    $titleBlock.Text = 'Web 插件管理'
    $titleBlock.Foreground = $textPri
    $titleBlock.FontSize = 15
    $titleBlock.FontWeight = [Windows.FontWeights]::SemiBold
    $titleBlock.Margin = '10,0,0,0'
    $titleBlock.VerticalAlignment = 'Center'
    $brandStack.Children.Add($titleBlock) | Out-Null

    $subBlock = New-Object Windows.Controls.TextBlock
    $subBlock.Text = '管理本地 DeepSeek Harness 的 Web 插件'
    $subBlock.Foreground = $textMuted
    $subBlock.FontSize = 11
    $subBlock.Margin = '10,0,0,0'
    $subBlock.VerticalAlignment = 'Center'
    $brandStack.Children.Add($subBlock) | Out-Null

    $closeStack = New-Object Windows.Controls.StackPanel
    $closeStack.Orientation = 'Horizontal'
    $closeStack.HorizontalAlignment = 'Right'
    $closeStack.Margin = '0,7,8,7'
    $headerGrid.Children.Add($closeStack) | Out-Null

    $closeButton = New-Object Windows.Controls.Button
    $closeButton.Content = '×'
    $closeButton.Width = 44
    $closeButton.Height = 42
    $closeButton.Foreground = '#526078'
    $closeButton.Background = 'Transparent'
    $closeButton.BorderThickness = '0'
    $closeButton.FontSize = 16
    $closeButton.Cursor = [Windows.Input.Cursors]::Hand
    $closeButton.Template = $clsTpl
    $closeStack.Children.Add($closeButton) | Out-Null

    # ---------- 内容区 ----------
    $content = New-Object Windows.Controls.Grid
    $content.Margin = '24,20,24,20'
    [Windows.Controls.Grid]::SetRow($content, 1)
    $clipGrid.Children.Add($content) | Out-Null
    [void]$content.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = '*' }))
    [void]$content.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition -Property @{ Height = 'Auto' }))

    $listWrap = New-Object Windows.Controls.Border
    $listWrap.CornerRadius = '12'
    $listWrap.Background = $surface
    $listWrap.BorderBrush = $cardBorder
    $listWrap.BorderThickness = '1'
    [Windows.Controls.Grid]::SetRow($listWrap, 0)
    $content.Children.Add($listWrap) | Out-Null

    $list = New-Object Windows.Controls.ListView
    $list.Background = 'Transparent'
    $list.BorderThickness = '0'
    $list.Padding = '0'
    $list.Margin = '0'
    $listWrap.Child = $list

    # 列表列头样式
    $colHeaderStyleXml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="GridViewColumnHeader">
  <Setter Property="Background" Value="#F5F5F7"/>
  <Setter Property="Foreground" Value="#6E6E73"/>
  <Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Padding" Value="12,9"/>
  <Setter Property="BorderBrush" Value="#E5E5EA"/>
  <Setter Property="BorderThickness" Value="0,0,0,1"/>
</Style>
'@
    $colHeaderStyle = [System.Windows.Markup.XamlReader]::Parse($colHeaderStyleXml)

    # 列表行样式
    $rowStyleXml = @'
<Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="ListViewItem">
  <Setter Property="Padding" Value="12,9"/>
  <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
</Style>
'@
    $rowStyle = [System.Windows.Markup.XamlReader]::Parse($rowStyleXml)

    $list.Resources.Add([Windows.Controls.GridViewColumnHeader], $colHeaderStyle)
    $list.Resources.Add([Windows.Controls.ListViewItem], $rowStyle)

    $view = New-Object Windows.Controls.GridView
    foreach ($columnSpec in @(
        @{ Header = '插件'; Path = 'Name'; Width = 340 },
        @{ Header = '版本'; Path = 'Version'; Width = 115 },
        @{ Header = '状态'; Path = 'State'; Width = 90 },
        @{ Header = '入口'; Path = 'EntryCount'; Width = 60 }
    )) {
        $column = New-Object Windows.Controls.GridViewColumn
        $column.Header = $columnSpec.Header
        $column.Width = $columnSpec.Width
        $column.DisplayMemberBinding = New-Object Windows.Data.Binding($columnSpec.Path)
        [void]$view.Columns.Add($column)
    }
    $list.View = $view

    # ---------- 底栏：状态 + 操作按钮 ----------
    $footer = New-Object Windows.Controls.DockPanel
    $footer.Margin = '0,14,0,0'
    [Windows.Controls.Grid]::SetRow($footer, 1)
    $content.Children.Add($footer) | Out-Null

    $status = New-Object Windows.Controls.TextBlock
    $status.Foreground = $textSec
    $status.VerticalAlignment = 'Center'
    [Windows.Controls.DockPanel]::SetDock($status, 'Left')
    $footer.Children.Add($status) | Out-Null

    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'
    $buttons.HorizontalAlignment = 'Right'
    $footer.Children.Add($buttons) | Out-Null

    foreach ($spec in @(
        @{ Text = '刷新'; Action = 'refresh'; Kind = 'Secondary'; Template = $secTpl },
        @{ Text = '启用'; Action = 'enable'; Kind = 'Secondary'; Template = $secTpl },
        @{ Text = '停用'; Action = 'disable'; Kind = 'Danger'; Template = $dngTpl },
        @{ Text = '更新'; Action = 'update'; Kind = 'Secondary'; Template = $secTpl },
        @{ Text = '关闭'; Action = 'close'; Kind = 'Primary'; Template = $priTpl }
    )) {
        $button = New-ThemeButton $spec.Text $spec.Kind $spec.Template
        $button.Tag = [string]$spec.Action
        $button.Add_Click({
            param($sender, $eventArgs)
            $actionName = [string]$sender.Tag
            if ($actionName -eq 'refresh') {
                Refresh-PluginList
                return
            }
            if ($actionName -eq 'close') {
                $dialog.Close()
                return
            }
            $selected = $list.SelectedItem
            if ($null -eq $selected) {
                $status.Text = '请先选择一个插件'
                return
            }
            if ($actionName -eq 'disable') {
                $choice = [System.Windows.MessageBox]::Show(
                    "确认停用 $($selected.Name)？",
                    'Web 插件管理',
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Warning)
                if ($choice -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            Start-PluginManagerAction -Action $actionName -Plugin $selected
            $dialog.Close()
        }.GetNewClosure())
        $buttons.Children.Add($button) | Out-Null
    }

    $dialog.Content = $outer

    # 无边框窗口：拖拽移动 + 关闭
    $dragArea.Add_MouseLeftButtonDown({
        if ($_.ChangedButton -eq [Windows.Input.MouseButton]::Left) {
            try { $dialog.DragMove() } catch { }
        }
    })
    $closeButton.Add_Click({ $dialog.Close() })
    $dialog.Add_KeyDown({
        if ($_.Key -eq [Windows.Input.Key]::Escape) { $dialog.Close() }
    })

    $script:pluginManagerDialogList = $list
    $script:pluginManagerDialogStatus = $status
    if (@($script:pluginListData).Count -gt 0) {
        $list.ItemsSource = $script:pluginListData
        $status.Text = "已显示缓存的 $(@($script:pluginListData).Count) 个插件，正在刷新…"
    }
    $dialog.Add_ContentRendered({ Refresh-PluginList })
    $dialog.Add_Closed({
        $script:pluginManagerDialogList = $null
        $script:pluginManagerDialogStatus = $null
    })
    $dialog.ShowDialog() | Out-Null
}

function Start-TerminalCommand {
    param([string]$CommandText)

    if ($null -ne $script:activeJob -or [string]::IsNullOrWhiteSpace($CommandText)) { return }
    if ($CommandText.Trim().ToLowerInvariant() -eq 'clear') {
        $terminalOutput.Clear()
        $terminalInput.Clear()
        return
    }

    Append-TerminalLine ("PS $repoPath> " + $CommandText)
    $terminalInput.Clear()
    Set-LauncherBusy $true '终端命令运行中' $CommandText
    $script:activeJobKind = 'terminal'
    $script:activeJob = Start-BackgroundOperation -ScriptBlock {
        param($WorkingDirectory, $Command)
        Set-Location -LiteralPath $WorkingDirectory
        & $env:ComSpec /d /c $Command 2>&1 | ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw "Terminal command exited with code $LASTEXITCODE"
        }
    } -ArgumentList $repoPath, $CommandText
}

function Start-InitialLogLoad {
    if ($null -ne $script:startupLogJob) { return }
    $script:startupLogJob = Start-BackgroundOperation -ScriptBlock {
        param($LauncherLogPath, $WebLogPath)

        $displayLines = New-Object System.Collections.Generic.List[object]
        $launcherOffset = 0L
        $webOffset = 0L

        if (Test-Path -LiteralPath $LauncherLogPath) {
            try {
                $lines = @(Get-Content -LiteralPath $LauncherLogPath -Tail 400 -Encoding UTF8 -ErrorAction Stop)
                $lastRunStart = -1
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    if ($lines[$index] -match '^\[\d{4}-\d{2}-\d{2} .+\] (Checking the official Harness repository|Local Harness was not found)') {
                        $lastRunStart = $index
                    }
                }
                if ($lastRunStart -ge 0) { $lines = @($lines[$lastRunStart..($lines.Count - 1)]) }
                elseif ($lines.Count -gt 80) { $lines = @($lines[($lines.Count - 80)..($lines.Count - 1)]) }
                $displayLines.Add('[DSH] Recent launcher/update output:')
                foreach ($line in $lines) { $displayLines.Add(($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '')) }
                $launcherOffset = (Get-Item -LiteralPath $LauncherLogPath).Length
            } catch { }
        }

        if (Test-Path -LiteralPath $WebLogPath) {
            try {
                $lines = @(Get-Content -LiteralPath $WebLogPath -Tail 250 -Encoding UTF8 -ErrorAction Stop)
                $lastRunStart = -1
                for ($index = 0; $index -lt $lines.Count; $index++) {
                    if ($lines[$index] -match '^\$ node .*"web"') { $lastRunStart = $index }
                }
                if ($lastRunStart -ge 0) { $lines = @($lines[$lastRunStart..($lines.Count - 1)]) }
                elseif ($lines.Count -gt 60) { $lines = @($lines[($lines.Count - 60)..($lines.Count - 1)]) }
                $displayLines.Add('[DSH] Current Harness runtime output:')
                foreach ($line in $lines) { $displayLines.Add(($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '')) }
                $webOffset = (Get-Item -LiteralPath $WebLogPath).Length
            } catch { }
        }

        [pscustomobject]@{
            Lines = $displayLines.ToArray()
            LauncherOffset = $launcherOffset
            WebOffset = $webOffset
        }
    } -ArgumentList $launcherLogPath, $webLogPath
}

$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$jobTimer.Add_Tick({
    if ($null -ne $script:serviceProbeTask -and $script:serviceProbeTask.IsCompleted) {
        $running = -not $script:serviceProbeTask.IsFaulted -and
            -not $script:serviceProbeTask.IsCanceled -and
            $script:serviceProbeTask.Result
        $script:serviceProbeTask = $null
        if ($running -ne $script:isWebRunning -and $null -eq $script:activeJob) {
            Set-ServiceState $running
            if ($running) {
                Set-LauncherBusy $false '服务运行中' '检测到 WebUI 正在本地端口 3080 运行'
            } else {
                Set-LauncherBusy $false '服务已停止' '本地端口 3080 当前处于空闲状态'
            }
        }
    }
    if ($null -ne $script:startupLogJob) {
        $logLoadState = $script:startupLogJob.Shell.InvocationStateInfo.State.ToString()
        if ($logLoadState -in @('Completed', 'Failed', 'Stopped')) {
            $logLoadResult = Complete-BackgroundOperation -Operation $script:startupLogJob
            $script:startupLogJob = $null
            if ($logLoadResult.State -eq 'Completed') {
                $logPayload = @($logLoadResult.Output | Select-Object -Last 1)[0]
                if ($null -ne $logPayload) {
                    Append-TerminalLines -Lines @($logPayload.Lines)
                    $script:launcherLogOffset = [long]$logPayload.LauncherOffset
                    $script:webLogOffset = [long]$logPayload.WebOffset
                }
            }
        }
    }
    if ($null -ne $script:pluginLoadJob) {
        $pluginLoadState = $script:pluginLoadJob.Shell.InvocationStateInfo.State.ToString()
        if ($pluginLoadState -in @('Completed', 'Failed', 'Stopped')) {
            $pluginLoadResult = Complete-BackgroundOperation -Operation $script:pluginLoadJob
            $pluginLoadOutput = $pluginLoadResult.Output
            $pluginLoadReason = $pluginLoadResult.Reason
            $pluginLoadState = $pluginLoadResult.State
            $script:pluginLoadJob = $null
            if ($pluginLoadState -eq 'Completed') {
                try {
                    $json = ($pluginLoadOutput | Where-Object { $_ -is [string] }) -join ''
                    if ([string]::IsNullOrWhiteSpace($json)) { throw '空插件列表' }
                    $script:pluginListData = @($json | ConvertFrom-Json | ForEach-Object { $_ })
                    try {
                        [IO.File]::WriteAllText(
                            $script:pluginCachePath,
                            ($script:pluginListData | ConvertTo-Json -Depth 8),
                            (New-Object Text.UTF8Encoding($false)))
                    } catch { }
                    if ($null -ne $script:pluginManagerDialogList) {
                        $script:pluginManagerDialogList.ItemsSource = $script:pluginListData
                    }
                    if ($null -ne $script:pluginManagerDialogStatus) {
                        if ($script:pluginListData.Count -eq 0) {
                            $script:pluginManagerDialogStatus.Text = '未发现已安装的 Web 插件'
                        } else {
                            $script:pluginManagerDialogStatus.Text = "共 $($script:pluginListData.Count) 个插件"
                        }
                    }
                } catch {
                    if ($null -ne $script:pluginManagerDialogStatus) {
                        $script:pluginManagerDialogStatus.Text = '插件列表加载失败：' + $_.Exception.Message
                    }
                }
            } else {
                $pluginLoadMsg = if ($null -ne $pluginLoadReason) { $pluginLoadReason.Message } else { '后台任务失败' }
                if ($null -ne $script:pluginManagerDialogStatus) {
                    $script:pluginManagerDialogStatus.Text = '插件列表加载失败：' + $pluginLoadMsg
                }
            }
        }
    }
    if ($null -eq $script:activeJob) { return }

    $output = @(Receive-BackgroundOperation -Operation $script:activeJob)
    if ($script:activeJobKind -ne 'update') {
        Append-TerminalLines -Lines $output
    }

    $operationState = $script:activeJob.Shell.InvocationStateInfo.State.ToString()
    if ($operationState -in @('Completed', 'Failed', 'Stopped')) {
        $result = Complete-BackgroundOperation -Operation $script:activeJob
        $state = $result.State
        $reason = $result.Reason
        if ($script:activeJobKind -ne 'update') {
            Append-TerminalLines -Lines $result.Output
        }
        $completedKind = $script:activeJobKind
        $script:activeJob = $null
        $script:activeJobKind = ''

        if ($state -eq 'Completed') {
            switch ($completedKind) {
                'update' {
                    Update-CommitLabel
                    Start-ServiceProbe
                    if ($script:updateWasInstall) {
                        Set-LauncherBusy $false 'Harness 安装完成' "完整核心位于：$repoPath"
                    } else {
                        $updateResult = Get-LastUpdateResult
                        $compat = Get-CompatibilityStatus
                        if ($null -ne $updateResult -and $updateResult.status -eq 'rolled-back') {
                            Set-LauncherBusy $false '已恢复原核心' '新核心未通过构建，已自动恢复到上一个可用版本'
                        } elseif ($null -ne $updateResult -and $updateResult.status -eq 'warning') {
                            $warningCount = @($updateResult.warnings).Count
                            Set-LauncherBusy $false '核心检查已完成' "核心可用 · $warningCount 项附加更新稍后可重试"
                        } elseif ($null -ne $compat -and $compat.status -eq 'compatible') {
                            Set-LauncherBusy $false '更新检查完成' "核心 $($compat.coreVersion) · 启动器适配正常"
                        } else {
                            Set-LauncherBusy $false '更新检查完成' '核心与已安装插件已检查，启动器适配待确认'
                        }
                    }
                    $script:updateWasInstall = $false
                }
                'web' {
                    Set-ServiceState $true
                    Set-LauncherBusy $false '服务运行中' 'WebUI 已在本地端口 3080 启动'
                    try { Start-Process (Get-WebUiUrl) | Out-Null } catch {
                        Append-TerminalLine ("[WARN] Unable to open the browser: " + $_.Exception.Message)
                    }
                }
                'stop' {
                    Set-ServiceState $false
                    Set-LauncherBusy $false '服务已停止' '本地 Harness 进程已经安全结束'
                }
                'restart' {
                    Set-ServiceState $true
                    Set-LauncherBusy $false '服务已重启' 'WebUI 正在本地端口 3080 运行'
                }
                'terminal' {
                    Start-ServiceProbe
                    Set-LauncherBusy $false '终端命令已完成' '可继续输入命令或启动 WebUI'
                }
                'plugin-toggle' {
                    Start-ServiceProbe
                    Set-LauncherBusy $false '插件状态已更新' 'Web 插件启停已生效'
                    Refresh-PluginList
                }
                'plugin-update' {
                    Start-ServiceProbe
                    Set-LauncherBusy $false '插件已更新' '已更新所选 Web 插件'
                    Refresh-PluginList
                }
                'diagnostics' {
                    Start-ServiceProbe
                    Set-LauncherBusy $false '系统诊断完成' "报告已保存到：$stateRoot\diagnostics-latest.json"
                }
            }
        } else {
            $message = if ($null -ne $reason) { $reason.Message } else { 'The background task failed.' }
            Append-TerminalLine ("[ERROR] " + $message)
            Start-ServiceProbe
            Set-LauncherBusy $false '操作没有完成' '打开终端查看详细信息后可以重试'
            $statusDot.Background = '#FF6B72'
            $serviceStateLabel.Text = '需要处理'
            $serviceStateLabel.Foreground = '#B42318'
            $terminalPanel.Visibility = 'Visible'
            $terminalButtonText.Text = '收起终端'
        }
    }
})

$webLogTimer = New-Object Windows.Threading.DispatcherTimer
$webLogTimer.Interval = [TimeSpan]::FromSeconds(1)
$webLogTimer.Add_Tick({
    Read-LauncherLogDelta
    Read-WebLogDelta
})

$serviceStateTimer = New-Object Windows.Threading.DispatcherTimer
$serviceStateTimer.Interval = [TimeSpan]::FromSeconds(5)
$serviceStateTimer.Add_Tick({
    if ($null -ne $script:activeJob) { return }
    Start-ServiceProbe
})

$dragArea.Add_MouseLeftButtonDown({
    if ($_.ChangedButton -eq [Windows.Input.MouseButton]::Left) {
        try { $window.DragMove() } catch { }
    }
})
$minimizeButton.Add_Click({ $window.WindowState = 'Minimized' })
$closeButton.Add_Click({ Hide-DshToTray })
$updateButton.Add_Click({ Start-UpdateCheck })
$pluginManagerButton.Add_Click({ Show-PluginManager })
$diagnosticsButton.Add_Click({ Start-SystemDiagnostics })
$openWebButton.Add_Click({ Start-WebUi })
$stopButton.Add_Click({ Stop-WebUi })
$restartButton.Add_Click({ Restart-WebUi })
$openFolderButton.Add_Click({
    $targetPath = if (Test-Path -LiteralPath $repoPath) { $repoPath } else { $launcherRoot }
    try { Start-Process explorer.exe -ArgumentList @($targetPath) | Out-Null } catch {
        Append-TerminalLine ("[WARN] Unable to open the Harness directory: " + $_.Exception.Message)
    }
})
$trayIcon.Add_DoubleClick({
    $window.Dispatcher.BeginInvoke([Action]{ Show-DshWindow }) | Out-Null
})
$showTrayItem.Add_Click({
    $window.Dispatcher.BeginInvoke([Action]{ Show-DshWindow }) | Out-Null
})
$restartTrayItem.Add_Click({
    $window.Dispatcher.BeginInvoke([Action]{
        Show-DshWindow
        Restart-WebUi
    }) | Out-Null
})
$openWebTrayItem.Add_Click({
    $window.Dispatcher.BeginInvoke([Action]{
        Show-DshWindow
        Start-WebUi
    }) | Out-Null
})
$exitTrayItem.Add_Click({
    $window.Dispatcher.BeginInvoke([Action]{
        $script:allowExit = $true
        $window.Close()
    }) | Out-Null
})
$terminalButton.Add_Click({
    if ($terminalPanel.Visibility -eq 'Visible') {
        $terminalPanel.Visibility = 'Collapsed'
        $terminalButtonText.Text = '日志与终端'
    } else {
        $terminalPanel.Visibility = 'Visible'
        $terminalButtonText.Text = '收起终端'
        $terminalInput.Focus() | Out-Null
    }
})

$terminalInput.Add_KeyDown({
    if ($_.Key -eq [Windows.Input.Key]::Enter) {
        $_.Handled = $true
        Start-TerminalCommand $terminalInput.Text
    }
})
$window.Add_ContentRendered({
    $harnessPathLabel.Text = $repoPath
    Update-CommitLabel
    Append-TerminalLine 'DSH Whale Maid Launcher'
    Append-TerminalLine 'Repository: https://github.com/deepseek-ai/deepseek-harness'
    Append-TerminalLine ("Harness path: " + $repoPath)
    Start-InitialLogLoad
    if (-not (Test-HarnessInstallation $repoPath)) {
        Set-ServiceState $false
        # 仅当 Harness 尚未安装时自动执行首次安装；已安装则跳过启动时的更新检查
        Start-UpdateCheck
    } else {
        Start-ServiceProbe
        Set-LauncherBusy $false '已就绪' '点击主按钮即可启动 WebUI'
    }
})
$window.Add_Closing({
    if (-not $script:allowExit) {
        $_.Cancel = $true
        Hide-DshToTray
    }
})
$window.Add_Closed({
    $jobTimer.Stop()
    $webLogTimer.Stop()
    $serviceStateTimer.Stop()
    if ($null -ne $script:activeJob) {
        Stop-BackgroundOperation -Operation $script:activeJob
    }
    if ($null -ne $script:pluginLoadJob) {
        Stop-BackgroundOperation -Operation $script:pluginLoadJob
    }
    if ($null -ne $script:startupLogJob) {
        Stop-BackgroundOperation -Operation $script:startupLogJob
    }
    if ($null -ne $script:backgroundRunspacePool) {
        $script:backgroundRunspacePool.Close()
        $script:backgroundRunspacePool.Dispose()
        $script:backgroundRunspacePool = $null
    }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $trayMenu.Dispose()
    [DshApplicationIdentity]::DisableApplicationRestart()
    if ($null -ne $script:instanceLockStream) {
        $script:instanceLockStream.Dispose()
        $script:instanceLockStream = $null
    }
    $application.Shutdown()
})

$jobTimer.Start()
$webLogTimer.Start()
$serviceStateTimer.Start()
$application.Run($window) | Out-Null
