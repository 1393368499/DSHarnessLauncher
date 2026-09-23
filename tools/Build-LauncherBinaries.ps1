[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$launcherRoot = Split-Path -Parent $PSScriptRoot
$framework = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319'
$csc = Join-Path $framework 'csc.exe'
$msbuild = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe'
$vcvars = 'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
$automation = 'C:\Windows\Microsoft.Net\assembly\GAC_MSIL\System.Management.Automation\v4.0_3.0.0.0__31bf3856ad364e35\System.Management.Automation.dll'

foreach ($required in @($csc, $msbuild, $vcvars, $automation)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Required build tool not found: $required" }
}

$runtimeOutput = Join-Path $launcherRoot 'DSH-Launcher.Runtime.next.dll'
& $csc /nologo /target:library /optimize+ /platform:anycpu `
    "/reference:$automation" `
    "/out:$runtimeOutput" `
    (Join-Path $launcherRoot 'DSH-LauncherRuntime.cs')
if ($LASTEXITCODE -ne 0) { throw "Runtime compilation failed with code $LASTEXITCODE." }
Move-Item -LiteralPath $runtimeOutput -Destination (Join-Path $launcherRoot 'DSH-Launcher.Runtime.dll') -Force

$xamlProject = Join-Path $launcherRoot 'build\DSH-Launcher.Xaml.csproj'
& $msbuild $xamlProject /t:Rebuild /p:Configuration=Release /m /nologo /v:minimal
if ($LASTEXITCODE -ne 0) { throw "XAML compilation failed with code $LASTEXITCODE." }
Copy-Item -LiteralPath (Join-Path $launcherRoot 'build\bin\Release\DSH-Launcher.Xaml.dll') `
    -Destination (Join-Path $launcherRoot 'DSH-Launcher.Xaml.dll') -Force

$hostOutput = Join-Path $launcherRoot 'DSH.next.exe'
$resourceOutput = Join-Path $launcherRoot 'DSH-LauncherHost.res'
$hostSource = Join-Path $launcherRoot 'DSH-LauncherHost.cpp'
$hostResource = Join-Path $launcherRoot 'DSH-LauncherHost.rc'
$nativeObjectDirectory = Join-Path $launcherRoot 'build\obj'
$nativeObject = Join-Path $nativeObjectDirectory 'DSH-LauncherHost.obj'
New-Item -ItemType Directory -Force -Path $nativeObjectDirectory | Out-Null
$nativeCommand = 'call "' + $vcvars + '" >nul && rc /nologo /fo "' + $resourceOutput +
    '" "' + $hostResource + '" && cl /nologo /EHsc /O2 /utf-8 /Fe:"' + $hostOutput +
    '" /Fo:"' + $nativeObject + '" "' + $hostSource + '" "' + $resourceOutput +
    '" user32.lib gdi32.lib shell32.lib'
& $env:ComSpec /d /s /c $nativeCommand
if ($LASTEXITCODE -ne 0) { throw "Native host compilation failed with code $LASTEXITCODE." }
Move-Item -LiteralPath $hostOutput -Destination (Join-Path $launcherRoot 'DSH.exe') -Force
if (Test-Path -LiteralPath $resourceOutput) { Remove-Item -LiteralPath $resourceOutput -Force }

Get-Item -LiteralPath @(
    (Join-Path $launcherRoot 'DSH-Launcher.Runtime.dll'),
    (Join-Path $launcherRoot 'DSH-Launcher.Xaml.dll'),
    (Join-Path $launcherRoot 'DSH.exe')
) | Select-Object Name, Length, LastWriteTime
