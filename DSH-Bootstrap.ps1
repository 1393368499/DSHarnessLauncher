param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [switch]$GitOnly,
    [switch]$SkipNative
)

$ErrorActionPreference = 'Stop'
$toolRoot = Join-Path $env:LOCALAPPDATA 'DSH\tools'
New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null

function Install-VerifiedZip {
    param([string]$Name, [string]$Url, [string]$Sha256, [string]$Destination, [string]$Executable)
    if (Test-Path -LiteralPath (Join-Path $Destination $Executable)) { return }
    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    $archive = Join-Path $toolRoot "$Name.zip"
    $stage = Join-Path $toolRoot "$Name.stage"
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    try {
        Write-Host "[DSH] Downloading $Name from its official release..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $archive -TimeoutSec 180
        if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $Sha256) {
            throw "$Name download failed SHA-256 verification."
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $stage -Force
        if (-not (Test-Path -LiteralPath (Join-Path $stage $Executable))) {
            throw "$Name archive is missing $Executable."
        }
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
        Move-Item -LiteralPath $stage -Destination $Destination
    } finally {
        if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

$git = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $git) {
    $gitRoot = Join-Path $toolRoot 'mingit-2.55.0.5'
    Install-VerifiedZip -Name 'mingit-2.55.0.5' `
        -Url 'https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.5/MinGit-2.55.0.5-64-bit.zip' `
        -Sha256 '56D7B226B7693196CFC71FEF26568F536C4A021AB6C37FF2DB4287BED908E96E' `
        -Destination $gitRoot -Executable 'cmd\git.exe'
    $env:PATH = (Join-Path $gitRoot 'cmd') + ';' + $env:PATH
    Write-Host '[DSH] Portable Git is ready.'
}

if ($GitOnly) { return }

$node = Get-Command node.exe -ErrorAction SilentlyContinue
$nodeValid = $false
if ($null -ne $node) {
    try {
        $nodeVersion = [version]((& $node.Source --version).TrimStart('v'))
        $nodeValid = $nodeVersion -ge [version]'22.19.0' -and ($nodeVersion.Major -eq 22 -or $nodeVersion.Major -ge 24)
    } catch { }
}
if (-not $nodeValid) {
    $nodeRoot = Join-Path $toolRoot 'node-v22.23.0-win-x64'
    $nodeArchiveRoot = Join-Path $toolRoot 'node-v22.23.0'
    Install-VerifiedZip -Name 'node-v22.23.0' `
        -Url 'https://nodejs.org/dist/v22.23.0/node-v22.23.0-win-x64.zip' `
        -Sha256 '425A5BD68CC95E8EB16BCCCD0A75081B48983FC6A26F67126BD4D6C7198231E8' `
        -Destination $nodeArchiveRoot -Executable 'node-v22.23.0-win-x64\node.exe'
    $env:PATH = (Join-Path $nodeArchiveRoot 'node-v22.23.0-win-x64') + ';' + $env:PATH
    Write-Host '[DSH] Portable Node.js is ready.'
}

$package = Get-Content -LiteralPath (Join-Path $HarnessPath 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$pnpmSpec = [string]$package.packageManager
if ($pnpmSpec -notmatch '^pnpm@(\d+\.\d+\.\d+)$') { throw "Unsupported Harness package manager: $pnpmSpec" }
$pnpmVersion = $Matches[1]
$pnpmRoot = Join-Path $toolRoot "pnpm-$pnpmVersion"
$pnpmBin = Join-Path $pnpmRoot 'node_modules\.bin\pnpm.cmd'
$pnpm = Get-Command pnpm.cmd -ErrorAction SilentlyContinue
$pnpmValid = $false
if ($null -ne $pnpm) {
    try { $pnpmValid = ((& $pnpm.Source --version).Trim() -eq $pnpmVersion) } catch { }
}
if (-not $pnpmValid) {
    if (-not (Test-Path -LiteralPath $pnpmBin)) {
        $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($null -eq $npm) { throw 'Node.js npm.cmd is unavailable after bootstrap.' }
        Write-Host "[DSH] Installing pnpm $pnpmVersion for this user..."
        & $npm.Source install --prefix $pnpmRoot --no-audit --no-fund "pnpm@$pnpmVersion"
        if ($LASTEXITCODE -ne 0) { throw "Failed to install pnpm $pnpmVersion." }
    }
    $env:PATH = (Join-Path $pnpmRoot 'node_modules\.bin') + ';' + $env:PATH
}
if (-not (Test-Path -LiteralPath $pnpmBin) -and -not $pnpmValid) { throw "pnpm $pnpmVersion is still unavailable." }
$pnpmPathPrefix = if ($pnpmValid) { '' } else { "%LOCALAPPDATA%\DSH\tools\pnpm-$pnpmVersion\node_modules\.bin;" }
$activePathFile = Join-Path $toolRoot 'active-path.cmd'
$activePath = '@echo off' + "`r`n" + 'set "PATH=' + $pnpmPathPrefix +
    '%LOCALAPPDATA%\DSH\tools\node-v22.23.0\node-v22.23.0-win-x64;' +
    '%LOCALAPPDATA%\DSH\tools\mingit-2.55.0.5\cmd;%PATH%"' + "`r`n"
[IO.File]::WriteAllText($activePathFile, $activePath, (New-Object Text.ASCIIEncoding))
if ($SkipNative) { return }

# Native dependencies such as fs-ext are compiled during pnpm install.
$python = Get-Command python.exe -ErrorAction SilentlyContinue
$pythonReady = $false
if ($null -ne $python) {
    try { $pythonReady = ((& $python.Source --version 2>&1) -match '^Python 3\.') -and $LASTEXITCODE -eq 0 } catch { }
}
if (-not $pythonReady) {
    $pythonRoot = Join-Path $toolRoot 'python-3.13.5'
    $pythonExe = Join-Path $pythonRoot 'python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        $installer = Join-Path $toolRoot 'python-3.13.5-amd64.exe'
        try {
            Write-Host '[DSH] Installing Python for native Harness dependencies...'
            Invoke-WebRequest -UseBasicParsing -Uri 'https://www.python.org/ftp/python/3.13.5/python-3.13.5-amd64.exe' -OutFile $installer -TimeoutSec 180
            $signature = Get-AuthenticodeSignature -LiteralPath $installer
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Python Software Foundation') {
                throw 'Python installer publisher verification failed.'
            }
            $process = Start-Process -FilePath $installer -ArgumentList @('/quiet', 'InstallAllUsers=0',
                'Include_launcher=0', 'Include_pip=0', 'Include_test=0', 'Include_doc=0',
                'PrependPath=0', "TargetDir=`"$pythonRoot`"") -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "Python installer failed with code $($process.ExitCode)." }
        } finally {
            if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
        }
    }
    if (-not (Test-Path -LiteralPath $pythonExe)) { throw 'Python was not available after installation.' }
    $env:PYTHON = $pythonExe
    $env:npm_config_python = $pythonExe
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
$compilerReady = $false
if (Test-Path -LiteralPath $vswhere) {
    $vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $compilerReady = $LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$vsInstall) -and
        @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h') }).Count -gt 0
}
if (-not $compilerReady) {
    $installer = Join-Path $toolRoot 'vs_buildtools.exe'
    try {
        Write-Host '[DSH] Installing Microsoft C++ Build Tools and Windows SDK. Windows may request administrator approval.'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $installer -TimeoutSec 180
        $signature = Get-AuthenticodeSignature -LiteralPath $installer
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
            throw 'Microsoft Build Tools installer publisher verification failed.'
        }
        $process = Start-Process -FilePath $installer -Verb RunAs -ArgumentList @('--passive', '--wait', '--norestart',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended') -Wait -PassThru
        if ($process.ExitCode -notin @(0, 3010)) { throw "Microsoft Build Tools installation failed with code $($process.ExitCode)." }
    } finally {
        if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer -Force }
    }
    if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Microsoft C++ Build Tools were not available after installation.' }
    $vsInstall = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $sdkAvailable = @(Get-ChildItem -LiteralPath $sdkRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'um\Windows.h') }).Count -gt 0
    if ([string]::IsNullOrWhiteSpace([string]$vsInstall) -or -not $sdkAvailable) {
        throw 'Microsoft C++ compiler or Windows SDK is still unavailable after installation.'
    }
}
Write-Host '[DSH] Git, Node.js and pnpm are ready.'
