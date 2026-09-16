$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class DshApplicationIdentity
{
    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    private struct PROPERTYKEY
    {
        public Guid fmtid;
        public uint pid;

        public PROPERTYKEY(Guid formatId, uint propertyId)
        {
            fmtid = formatId;
            pid = propertyId;
        }
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct PROPVARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr pointerValue;

        public static PROPVARIANT FromString(string value)
        {
            PROPVARIANT result = new PROPVARIANT();
            result.vt = 31; // VT_LPWSTR
            result.pointerValue = Marshal.StringToCoTaskMemUni(value ?? String.Empty);
            return result;
        }
    }

    [ComImport]
    [Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint propertyCount);
        [PreserveSig] int GetAt(uint propertyIndex, out PROPERTYKEY key);
        [PreserveSig] int GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        [PreserveSig] int SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        [PreserveSig] int Commit();
    }

    private static readonly Guid AppUserModelFormatId = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
    private static readonly Guid PropertyStoreInterfaceId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID(string appID);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHGetPropertyStoreFromParsingName(
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        IntPtr bindContext,
        uint flags,
        ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IPropertyStore propertyStore);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void SHChangeNotify(
        uint eventId,
        uint flags,
        [MarshalAs(UnmanagedType.LPWStr)] string item1,
        IntPtr item2);

    [DllImport("ole32.dll")]
    private static extern int PropVariantClear(ref PROPVARIANT value);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string windowName);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr windowHandle);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr windowHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterApplicationRestart(string commandLineArgs, int flags);

    [DllImport("kernel32.dll")]
    private static extern int UnregisterApplicationRestart();

    private static void SetString(IPropertyStore store, uint propertyId, string value)
    {
        PROPERTYKEY key = new PROPERTYKEY(AppUserModelFormatId, propertyId);
        PROPVARIANT propertyValue = PROPVARIANT.FromString(value);
        try
        {
            Marshal.ThrowExceptionForHR(store.SetValue(ref key, ref propertyValue));
        }
        finally
        {
            PropVariantClear(ref propertyValue);
        }
    }

    private static void ApplyIdentity(
        IPropertyStore store,
        string appId,
        string relaunchCommand,
        string displayName,
        string iconResource)
    {
        SetString(store, 5, appId);          // System.AppUserModel.ID
        SetString(store, 2, relaunchCommand); // System.AppUserModel.RelaunchCommand
        SetString(store, 4, displayName);     // System.AppUserModel.RelaunchDisplayNameResource
        SetString(store, 3, iconResource);    // System.AppUserModel.RelaunchIconResource
        Marshal.ThrowExceptionForHR(store.Commit());
    }

    public static void SetShortcutIdentity(
        string shortcutPath,
        string appId,
        string relaunchCommand,
        string displayName,
        string iconResource)
    {
        IPropertyStore store;
        Guid interfaceId = PropertyStoreInterfaceId;
        SHGetPropertyStoreFromParsingName(shortcutPath, IntPtr.Zero, 2, ref interfaceId, out store); // GPS_READWRITE
        try
        {
            ApplyIdentity(store, appId, relaunchCommand, displayName, iconResource);
        }
        finally
        {
            if (store != null) Marshal.FinalReleaseComObject(store);
        }
        SHChangeNotify(0x00002000, 0x0005, shortcutPath, IntPtr.Zero); // SHCNE_UPDATEITEM, SHCNF_PATHW
    }

    public static bool ActivateExistingWindow()
    {
        IntPtr handle = FindWindow(null, "DSH");
        if (handle == IntPtr.Zero) return false;
        if (IsIconic(handle)) ShowWindow(handle, 9); // SW_RESTORE
        else ShowWindow(handle, 5); // SW_SHOW
        return SetForegroundWindow(handle);
    }

    public static int EnableApplicationRestart(string commandLineArgs)
    {
        return RegisterApplicationRestart(commandLineArgs, 0);
    }

    public static void DisableApplicationRestart()
    {
        UnregisterApplicationRestart();
    }
}
'@

$launcherRoot = $PSScriptRoot
$stateRoot = Join-Path $env:LOCALAPPDATA 'DSH'
$statePath = Join-Path $stateRoot 'launcher.json'
$defaultHarnessPath = Join-Path $launcherRoot 'deepseek-harness'
$xamlPath = Join-Path $launcherRoot 'LauncherWindow.xaml'
$updateScript = Join-Path $launcherRoot 'DSH-Launcher.ps1'
$diagnosticsScript = Join-Path $launcherRoot 'DSH-Diagnostics.ps1'
$serverScript = Join-Path $launcherRoot 'Start-DSH-Web.cmd'
$appUserModelId = 'DeepSeek.DSH.WhaleMaidLauncher'
$launcherExecutable = Join-Path $launcherRoot 'DSH.exe'
$launcherIconPath = Join-Path $launcherRoot 'DSH-unified-v5.ico'
$launcherRelaunchCommand = '"' + $launcherExecutable + '"'
$launcherIconResource = $launcherIconPath + ',0'

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

$restartArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '"'
[DshApplicationIdentity]::EnableApplicationRestart($restartArguments) | Out-Null

[DshApplicationIdentity]::SetCurrentProcessExplicitAppUserModelID($appUserModelId) | Out-Null
foreach ($shortcutPath in @(
    (Join-Path $launcherRoot 'DSH.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH.lnk')
)) {
    if (Test-Path -LiteralPath $shortcutPath) {
        try {
            [DshApplicationIdentity]::SetShortcutIdentity(
                $shortcutPath,
                $appUserModelId,
                $launcherRelaunchCommand,
                'DSH',
                $launcherIconResource)
        } catch { }
    }
}

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

[xml]$xaml = Get-Content -LiteralPath $xamlPath -Raw -Encoding UTF8
$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
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

$iconPath = Join-Path $launcherRoot 'DSH-unified-v5.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconPath) } catch { }
}

$maidImagePath = Join-Path $launcherRoot 'assets\DSH-white-frame-v5.png'
$brandIconPath = Join-Path $launcherRoot 'assets\DSHarness-v2.png'
if (Test-Path -LiteralPath $brandIconPath) {
    try {
        $brandIcon.Source = New-Object System.Windows.Media.Imaging.BitmapImage -ArgumentList ([Uri]$brandIconPath)
        $brandIcon.Visibility = 'Visible'
    } catch { }
}

if (Test-Path -LiteralPath $maidImagePath) {
    try {
        $maidImage.Source = New-Object System.Windows.Media.Imaging.BitmapImage -ArgumentList ([Uri]$maidImagePath)
        $maidImage.Visibility = 'Visible'
    } catch { }
}

$script:activeJob = $null
$script:activeJobKind = ''
$script:allowExit = $false
$script:trayHintShown = $false
$script:updateWasInstall = $false
$script:webLogOffset = 0L
$script:isBusy = $false
$script:isWebRunning = $false
$webAddress = 'http://127.0.0.1:3080/'

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = New-Object System.Drawing.Icon -ArgumentList (Join-Path $launcherRoot 'DSH-unified-v5.ico')
$trayIcon.Text = 'DSH - DeepSeek Harness'
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

function Append-TerminalLine {
    param([object]$Line)

    if ($null -eq $Line) { return }
    $text = $Line.ToString()
    if ([string]::IsNullOrWhiteSpace($text)) { return }
    $terminalOutput.AppendText($text + [Environment]::NewLine)
    $terminalOutput.ScrollToEnd()
}

function Initialize-WebLogView {
    if (-not (Test-Path -LiteralPath $webLogPath)) { return }
    try {
        $lines = @(Get-Content -LiteralPath $webLogPath -Tail 250 -Encoding UTF8 -ErrorAction Stop)
        $lastRunStart = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\$ node .*"web"') { $lastRunStart = $index }
        }
        if ($lastRunStart -ge 0) {
            $lines = @($lines[$lastRunStart..($lines.Count - 1)])
        } elseif ($lines.Count -gt 60) {
            $lines = @($lines[($lines.Count - 60)..($lines.Count - 1)])
        }

        Append-TerminalLine '[DSH] Current Harness runtime output:'
        foreach ($line in $lines) {
            Append-TerminalLine ($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '')
        }
        $script:webLogOffset = (Get-Item -LiteralPath $webLogPath -ErrorAction Stop).Length
    } catch {
        Append-TerminalLine ("[WARN] Unable to read Harness log: " + $_.Exception.Message)
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
        foreach ($line in ($text -split '\r?\n|\r')) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Append-TerminalLine ($line -replace '\x1B\[[0-?]*[ -/]*[@-~]', '')
            }
        }
    } catch {
        # A writer may briefly rotate or reopen the file. The next timer tick retries.
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Test-WebUiRunning {
    # Fast bounded socket probe: Get-NetTCPConnection is slow (hundreds of ms) and blocks the UI thread.
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync('127.0.0.1', 3080)
        if ($task.Wait(250)) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $client.Dispose()
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
    if (-not $script:isBusy) {
        Set-ServiceState (Test-WebUiRunning)
    }
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
        $commit = (& git.exe -C $repoPath rev-parse --short=8 HEAD 2>$null).Trim()
        if (-not [string]::IsNullOrWhiteSpace($commit)) {
            $commitLabel.Text = $commit.ToUpperInvariant()
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
    $script:activeJob = Start-Job -ScriptBlock {
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
    $script:activeJob = Start-Job -ScriptBlock {
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

    if (Test-WebUiRunning) {
        Set-ServiceState $true
        Set-LauncherBusy $false '服务运行中' '已在系统默认浏览器中打开 WebUI'
        try { Start-Process $webAddress | Out-Null } catch {
            Append-TerminalLine ("[WARN] Unable to open the browser: " + $_.Exception.Message)
        }
        return
    }

    Invoke-ExactLogRotation -Path $webLogPath
    Append-TerminalLine ''
    Append-TerminalLine '[DSH] Preparing the WebUI...'
    Set-LauncherBusy $true '正在启动 WebUI' '正在启动本地服务，页面将由官方 Harness 自动打开'
    $script:activeJobKind = 'web'
    $script:activeJob = Start-Job -ScriptBlock {
        param($RepoPath, $ServerScriptPath)

        $listener = Get-NetTCPConnection -LocalPort 3080 -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $listener) {
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

        '[DSH] Harness is ready. Browser handoff is owned by the official Web runtime.'
    } -ArgumentList $repoPath, $serverScript
}

function Stop-WebUi {
    if ($null -ne $script:activeJob) { return }

    Append-TerminalLine '[DSH] Stopping the WebUI service...'
    Set-LauncherBusy $true '正在停止 WebUI' '正在结束本地 Harness 服务进程'
    $script:activeJobKind = 'stop'
    $script:activeJob = Start-Job -ScriptBlock {
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
    $script:activeJob = Start-Job -ScriptBlock {
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

        '[DSH] Harness restarted. Browser handoff is owned by the official Web runtime.'
    } -ArgumentList $repoPath, $serverScript, $webLogPath
}
$script:pluginManagerScript = Join-Path $launcherRoot 'DSH-PluginManager.ps1'
$script:pluginListData = @()

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
    $script:pluginLoadJob = Start-Job -ScriptBlock {
        param($PowerShellPath, $ManagerScriptPath, $HarnessPath)
        $output = & $PowerShellPath -NoProfile -ExecutionPolicy Bypass -File $ManagerScriptPath `
            -Action list -HarnessPath $HarnessPath 2>&1 | ForEach-Object { $_.ToString() }
        if ($LASTEXITCODE -ne 0) {
            throw (($output | Select-Object -Last 8) -join [Environment]::NewLine)
        }
        $output
    } -ArgumentList 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe', $script:pluginManagerScript, $repoPath
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
    $script:activeJob = Start-Job -ScriptBlock {
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
    $dialog.AllowsTransparency = $true
    $dialog.ResizeMode = 'NoResize'
    $dialog.Background = [Windows.Media.Brushes]::Transparent
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

    # ---------- 外框：无边框圆角卡片 + 阴影 ----------
    $outer = New-Object Windows.Controls.Grid
    $outer.Background = 'Transparent'

    $chrome = New-Object Windows.Controls.Border
    $chrome.Margin = '14'
    $chrome.CornerRadius = '12'
    $chrome.Background = $pageBg
    $chrome.BorderBrush = '#E4E4E8'
    $chrome.BorderThickness = '1'
    $shadow = New-Object Windows.Media.Effects.DropShadowEffect
    $shadow.BlurRadius = 26
    $shadow.ShadowDepth = 7
    $shadow.Opacity = 0.16
    $shadow.Color = '#000000'
    $chrome.Effect = $shadow
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
    $headerBorder.CornerRadius = '12,12,0,0'
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
    $whalePath = Join-Path $launcherRoot 'assets\DSHarness-v2.png'
    if (Test-Path -LiteralPath $whalePath) {
        try { $whale.Source = New-Object Windows.Media.Imaging.BitmapImage -ArgumentList ([Uri]$whalePath) } catch { }
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
    $script:activeJob = Start-Job -ScriptBlock {
        param($WorkingDirectory, $Command)
        Set-Location -LiteralPath $WorkingDirectory
        & $env:ComSpec /d /c $Command 2>&1 | ForEach-Object { $_.ToString() }
        exit $LASTEXITCODE
    } -ArgumentList $repoPath, $CommandText
}

$jobTimer = New-Object Windows.Threading.DispatcherTimer
$jobTimer.Interval = [TimeSpan]::FromMilliseconds(220)
$jobTimer.Add_Tick({
    if ($null -ne $script:pluginLoadJob) {
        $pluginLoadState = $script:pluginLoadJob.State
        if ($pluginLoadState -in @('Completed', 'Failed', 'Stopped')) {
            $pluginLoadOutput = Receive-Job -Job $script:pluginLoadJob -ErrorAction SilentlyContinue
            $pluginLoadReason = $script:pluginLoadJob.ChildJobs[0].JobStateInfo.Reason
            Remove-Job -Job $script:pluginLoadJob -Force -ErrorAction SilentlyContinue
            $script:pluginLoadJob = $null
            if ($pluginLoadState -eq 'Completed') {
                try {
                    $json = ($pluginLoadOutput | Where-Object { $_ -is [string] }) -join ''
                    if ([string]::IsNullOrWhiteSpace($json)) { throw '空插件列表' }
                    $script:pluginListData = @($json | ConvertFrom-Json | ForEach-Object { $_ })
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

    $output = Receive-Job -Job $script:activeJob -ErrorAction SilentlyContinue
    foreach ($line in $output) { Append-TerminalLine $line }

    if ($script:activeJob.State -in @('Completed', 'Failed', 'Stopped')) {
        $state = $script:activeJob.State
        $remaining = Receive-Job -Job $script:activeJob -ErrorAction SilentlyContinue
        foreach ($line in $remaining) { Append-TerminalLine $line }

        $reason = $script:activeJob.ChildJobs[0].JobStateInfo.Reason
        Remove-Job -Job $script:activeJob -Force -ErrorAction SilentlyContinue
        $completedKind = $script:activeJobKind
        $script:activeJob = $null
        $script:activeJobKind = ''

        if ($state -eq 'Completed') {
            switch ($completedKind) {
                'update' {
                    Update-CommitLabel
                    Set-ServiceState (Test-WebUiRunning)
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
                    Set-ServiceState (Test-WebUiRunning)
                    Set-LauncherBusy $false '终端命令已完成' '可继续输入命令或启动 WebUI'
                }
                'plugin-toggle' {
                    Set-ServiceState (Test-WebUiRunning)
                    Set-LauncherBusy $false '插件状态已更新' 'Web 插件启停已生效'
                    Refresh-PluginList
                }
                'plugin-update' {
                    Set-ServiceState (Test-WebUiRunning)
                    Set-LauncherBusy $false '插件已更新' '已更新所选 Web 插件'
                    Refresh-PluginList
                }
                'diagnostics' {
                    Set-ServiceState (Test-WebUiRunning)
                    Set-LauncherBusy $false '系统诊断完成' "报告已保存到：$stateRoot\diagnostics-latest.json"
                }
            }
        } else {
            $message = if ($null -ne $reason) { $reason.Message } else { 'The background task failed.' }
            Append-TerminalLine ("[ERROR] " + $message)
            Set-ServiceState (Test-WebUiRunning)
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
$webLogTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$webLogTimer.Add_Tick({ Read-WebLogDelta })

$serviceStateTimer = New-Object Windows.Threading.DispatcherTimer
$serviceStateTimer.Interval = [TimeSpan]::FromSeconds(3)
$serviceStateTimer.Add_Tick({
    if ($null -ne $script:activeJob) { return }
    $running = Test-WebUiRunning
    if ($running -eq $script:isWebRunning) { return }

    Set-ServiceState $running
    if ($running) {
        Set-LauncherBusy $false '服务运行中' '检测到 WebUI 正在本地端口 3080 运行'
    } else {
        Set-LauncherBusy $false '服务已停止' '本地端口 3080 当前处于空闲状态'
    }
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
    Initialize-WebLogView
    if (-not (Test-HarnessInstallation $repoPath)) {
        Set-ServiceState $false
        # 仅当 Harness 尚未安装时自动执行首次安装；已安装则跳过启动时的更新检查
        Start-UpdateCheck
    } else {
        $running = Test-WebUiRunning
        Set-ServiceState $running
        if ($running) {
            Set-LauncherBusy $false '服务运行中' 'WebUI 已在本地端口 3080 运行'
        } else {
            Set-LauncherBusy $false '已就绪' '点击主按钮即可启动 WebUI'
        }
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
        Stop-Job -Job $script:activeJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:activeJob -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:pluginLoadJob) {
        Stop-Job -Job $script:pluginLoadJob -ErrorAction SilentlyContinue
        Remove-Job -Job $script:pluginLoadJob -Force -ErrorAction SilentlyContinue
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
