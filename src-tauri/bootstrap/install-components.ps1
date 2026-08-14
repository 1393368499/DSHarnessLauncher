param([string]$BaseDir = "")

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step([string]$Message) { Write-Output "[DSHarness] $Message" }
function Write-State([int]$Percent, [string]$Stage) { Write-Output "@@DSH_PROGRESS@@$Percent|$Stage" }

function Assert-ChildPath([string]$Path, [string]$Parent) {
  $resolvedParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
  $resolvedPath = [IO.Path]::GetFullPath($Path)
  if (-not $resolvedPath.StartsWith($resolvedParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "拒绝访问 DSHarness 数据目录之外的路径：$resolvedPath"
  }
}

if ([string]::IsNullOrWhiteSpace($BaseDir)) { $BaseDir = Join-Path $env:LOCALAPPDATA 'DSHarness' }
$localRoot = [IO.Path]::GetFullPath($env:LOCALAPPDATA)
$BaseDir = [IO.Path]::GetFullPath($BaseDir)
Assert-ChildPath $BaseDir $localRoot

$runtimeDir = Join-Path $BaseDir 'runtime'
$stagingDir = Join-Path $BaseDir ("staging-" + [Guid]::NewGuid().ToString('N'))
$backupDir = Join-Path $BaseDir 'runtime-backup'
Assert-ChildPath $runtimeDir $BaseDir
Assert-ChildPath $stagingDir $BaseDir
Assert-ChildPath $backupDir $BaseDir
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
$published = $false

try {
  $headers = @{ 'User-Agent' = 'DSHarness/4.0'; 'Accept' = 'application/vnd.github+json' }

  Write-State 2 '准备安全安装目录'
  Write-Step '查询 Node.js 官方 v22 版本与校验清单…'
  Write-State 5 '读取 Node.js 官方校验清单'
  $nodeBase = 'https://nodejs.org/dist/latest-v22.x'
  $checksumText = (Invoke-WebRequest -UseBasicParsing -Uri "$nodeBase/SHASUMS256.txt").Content
  $checksumLine = ($checksumText -split "`n" | Where-Object { $_ -match ' node-v22\.[0-9]+\.[0-9]+-win-x64\.zip\s*$' } | Select-Object -First 1).Trim()
  if (-not $checksumLine) { throw '未在 Node.js 官方校验清单中找到 Windows x64 包。' }
  $parts = $checksumLine -split '\s+'
  $expectedNodeHash = $parts[0].ToLowerInvariant()
  $nodeFile = $parts[-1]
  $nodeVersion = [regex]::Match($nodeFile, 'node-(v[0-9.]+)-').Groups[1].Value
  $nodeZip = Join-Path $stagingDir $nodeFile
  Write-State 9 "下载 Node.js $nodeVersion"
  Invoke-WebRequest -UseBasicParsing -Uri "$nodeBase/$nodeFile" -OutFile $nodeZip
  Write-State 18 '校验 Node.js SHA-256'
  $actualNodeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $nodeZip).Hash.ToLowerInvariant()
  if ($actualNodeHash -ne $expectedNodeHash) { throw 'Node.js SHA-256 校验失败。' }

  Write-Step "安装 Node.js $nodeVersion…"
  Write-State 23 '解压 Node.js 运行时'
  $nodeUnpack = Join-Path $stagingDir 'node-unpack'
  Expand-Archive -LiteralPath $nodeZip -DestinationPath $nodeUnpack -Force
  $nodeExtracted = Get-ChildItem -LiteralPath $nodeUnpack -Directory | Select-Object -First 1
  if (-not $nodeExtracted) { throw 'Node.js 压缩包结构无效。' }
  $nodeDir = Join-Path $stagingDir 'node'
  Move-Item -LiteralPath $nodeExtracted.FullName -Destination $nodeDir

  Write-Step '查询 DeepSeek 官方 Harness 最新提交…'
  Write-State 28 '检查 Harness 核心更新'
  # 使用 GitHub 官方提交订阅获取 master 的精确提交，避免未登录 REST API 的低限额。
  $commitFeed = (Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri 'https://github.com/deepseek-ai/deepseek-harness/commits/master.atom').Content
  $coreCommit = [regex]::Match($commitFeed, '/commit/([0-9a-f]{40})').Groups[1].Value
  if ($coreCommit -notmatch '^[0-9a-f]{40}$') { throw 'GitHub 返回的 Harness 提交标识无效。' }
  $coreZip = Join-Path $stagingDir 'deepseek-harness.zip'
  Write-State 34 "下载完整 Harness 核心 $($coreCommit.Substring(0, 8))"
  Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://codeload.github.com/deepseek-ai/deepseek-harness/zip/$coreCommit" -OutFile $coreZip

  Write-Step "安装完整 Harness 核心 $($coreCommit.Substring(0, 8))…"
  Write-State 43 '解压完整 Harness 核心'
  $coreUnpack = Join-Path $stagingDir 'core-unpack'
  Expand-Archive -LiteralPath $coreZip -DestinationPath $coreUnpack -Force
  $coreExtracted = Get-ChildItem -LiteralPath $coreUnpack -Directory | Select-Object -First 1
  if (-not $coreExtracted) { throw 'Harness 官方源码压缩包结构无效。' }
  $coreDir = Join-Path $stagingDir 'harness-core'
  Move-Item -LiteralPath $coreExtracted.FullName -Destination $coreDir

  $nodeExe = Join-Path $nodeDir 'node.exe'
  $npmCmd = Join-Path $nodeDir 'npm.cmd'
  if (-not (Test-Path -LiteralPath $nodeExe) -or -not (Test-Path -LiteralPath $npmCmd)) { throw 'Node.js 安装不完整。' }
  $env:PATH = "$nodeDir;$env:PATH"
  $env:CI = 'true'
  $env:COREPACK_ENABLE_DOWNLOAD_PROMPT = '0'
  $pnpmPrefix = Join-Path $stagingDir 'pnpm'

  Write-Step '从 npm 官方源安装 pnpm 11.7.0…'
  Write-State 50 '准备完整依赖安装工具'
  & $npmCmd install --global pnpm@11.7.0 --prefix $pnpmPrefix --registry https://registry.npmjs.org/
  if ($LASTEXITCODE -ne 0) { throw "pnpm 安装失败，退出码 $LASTEXITCODE。" }
  $pnpmCmd = Join-Path $pnpmPrefix 'pnpm.cmd'
  if (-not (Test-Path -LiteralPath $pnpmCmd)) { throw 'pnpm 命令未生成。' }

  Write-Step '安装 Harness 全部工作区依赖（含联网搜索）…'
  Write-State 55 '下载并链接 Harness 全部依赖'
  Push-Location $coreDir
  try {
    & $pnpmCmd install --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw "Harness 依赖安装失败，退出码 $LASTEXITCODE。" }
    Write-Step '构建 Harness 全部核心与桌面 Web 工作台…'
    Write-State 82 '构建 Harness 完整核心与工作台'
    & $pnpmCmd run build
    if ($LASTEXITCODE -ne 0) { throw "Harness 构建失败，退出码 $LASTEXITCODE。" }
  } finally { Pop-Location }

  $marker = [ordered]@{
    schema = 1
    installedAt = (Get-Date).ToUniversalTime().ToString('o')
    sourceRepository = 'https://github.com/deepseek-ai/deepseek-harness'
    coreCommit = $coreCommit
    nodeVersion = $nodeVersion
    webSearch = 'included-in-full-core'
    pnpmVersion = '11.7.0'
  }
  $marker | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stagingDir 'install.json') -Encoding UTF8

  Write-Step '发布运行环境…'
  Write-State 91 '发布完整运行环境'
  if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
  if (Test-Path -LiteralPath $runtimeDir) { Move-Item -LiteralPath $runtimeDir -Destination $backupDir }
  Move-Item -LiteralPath $stagingDir -Destination $runtimeDir

  # pnpm 在 Windows 上会创建指向工作区绝对路径的链接。目录发布后用已下载的
  # 本地内容存储重建链接，避免链接仍指向 staging-* 临时目录。
  $published = $true
  $finalNodeDir = Join-Path $runtimeDir 'node'
  $finalPnpmCmd = Join-Path $runtimeDir 'pnpm\pnpm.cmd'
  $env:PATH = "$finalNodeDir;$env:PATH"
  Write-Step '刷新正式目录中的 Harness 工作区链接…'
  Write-State 95 '刷新正式运行环境链接'
  Push-Location (Join-Path $runtimeDir 'harness-core')
  try {
    & $finalPnpmCmd install --offline --frozen-lockfile
    if ($LASTEXITCODE -ne 0) { throw "Harness 正式目录链接刷新失败，退出码 $LASTEXITCODE。" }
  } finally { Pop-Location }

  if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
  Write-State 100 '完整 Harness 核心已就绪'
  Write-Step '完整 Harness 核心、Node.js 与联网搜索能力安装完成。'
  exit 0
} catch {
  Write-Error $_
  if (Test-Path -LiteralPath $stagingDir) { Remove-Item -LiteralPath $stagingDir -Recurse -Force }
  if ($published -and (Test-Path -LiteralPath $runtimeDir)) { Remove-Item -LiteralPath $runtimeDir -Recurse -Force }
  if (Test-Path -LiteralPath $backupDir) { Move-Item -LiteralPath $backupDir -Destination $runtimeDir }
  exit 1
}
