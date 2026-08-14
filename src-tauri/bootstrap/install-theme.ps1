param([Parameter(Mandatory = $true)][string]$Repository)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$uri = [Uri]$Repository
if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com') { throw '只允许 https://github.com/ 下的主题仓库。' }
$segments = $uri.AbsolutePath.Trim('/').Split('/')
if ($segments.Count -lt 2) { throw 'GitHub 地址必须包含仓库所有者和仓库名。' }
$owner = $segments[0]
$repo = $segments[1] -replace '\.git$', ''
if ($owner -notmatch '^[A-Za-z0-9_.-]+$' -or $repo -notmatch '^[A-Za-z0-9_.-]+$') { throw 'GitHub 仓库名称无效。' }

$headers = @{ 'User-Agent' = 'DSHarness/4.0'; 'Accept' = 'application/vnd.github+json' }
$sha = ''
try {
  $metadata = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$owner/$repo"
  $branch = [string]$metadata.default_branch
  $commit = Invoke-RestMethod -Headers $headers -Uri "https://api.github.com/repos/$owner/$repo/commits/$branch"
  $sha = [string]$commit.sha
} catch {
  # GitHub REST API 未登录时可能限流；主题仓库常用 main/master，改用官方 Atom 提交订阅。
  foreach ($candidate in @('main', 'master')) {
    try {
      $feed = (Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://github.com/$owner/$repo/commits/$candidate.atom").Content
      $sha = [regex]::Match($feed, '/commit/([0-9a-f]{40})').Groups[1].Value
      if ($sha -match '^[0-9a-f]{40}$') { break }
    } catch { }
  }
}
if ($sha -notmatch '^[0-9a-f]{40}$') { throw 'GitHub 返回的提交标识无效。' }

$base = Join-Path $env:LOCALAPPDATA 'DSHarness'
$themes = Join-Path $base 'themes'
$stage = Join-Path $base ("theme-stage-" + [Guid]::NewGuid().ToString('N'))
$target = Join-Path $themes ("$owner-$repo")
New-Item -ItemType Directory -Path $stage -Force | Out-Null
New-Item -ItemType Directory -Path $themes -Force | Out-Null

try {
  $zip = Join-Path $stage 'theme.zip'
  Invoke-WebRequest -UseBasicParsing -Headers $headers -Uri "https://codeload.github.com/$owner/$repo/zip/$sha" -OutFile $zip
  $unpack = Join-Path $stage 'unpack'
  Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
  $root = Get-ChildItem -LiteralPath $unpack -Directory | Select-Object -First 1
  if (-not $root) { throw '主题压缩包结构无效。' }
  $files = @(Get-ChildItem -LiteralPath $root.FullName -Recurse -File)
  if ($files.Count -gt 2000) { throw '主题文件超过 2000 个，已拒绝安装。' }
  $total = ($files | Measure-Object -Property Length -Sum).Sum
  if ($total -gt 52428800) { throw '主题解压后超过 50 MB，已拒绝安装。' }
  $blocked = @('.exe', '.dll', '.msi', '.cmd', '.bat', '.ps1', '.com', '.scr', '.vbs', '.js', '.mjs', '.cjs')
  $dangerous = $files | Where-Object { $blocked -contains $_.Extension.ToLowerInvariant() } | Select-Object -First 1
  if ($dangerous) { throw "主题包含可执行代码，已拒绝安装：$($dangerous.Name)" }
  $manifest = $files | Where-Object { $_.Name -in @('theme.json', 'plugin.json') } | Select-Object -First 1
  if (-not $manifest) { throw '仓库缺少 theme.json 或 plugin.json，不能识别为声明式主题。' }
  $manifestText = Get-Content -LiteralPath $manifest.FullName -Raw
  $manifestJson = $manifestText | ConvertFrom-Json
  $kind = [string]$manifestJson.kind
  if (-not $kind) { $kind = [string]$manifestJson.type }
  if ($kind -and $kind -ne 'theme') { throw '插件清单不是 theme 类型。' }
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  Move-Item -LiteralPath $root.FullName -Destination $target
  [ordered]@{ owner = $owner; repository = $repo; commit = $sha; installedAt = (Get-Date).ToUniversalTime().ToString('o'); audit = 'passed-declarative-theme' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $target '.dsharness-source.json') -Encoding UTF8
  Write-Output "主题已通过审计并安装：$owner/$repo@$($sha.Substring(0, 8))"
  exit 0
} catch {
  Write-Error $_
  exit 1
} finally {
  if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
