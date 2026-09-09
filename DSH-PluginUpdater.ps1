param(
    [Parameter(Mandatory)]
    [string]$HarnessPath,
    [string]$ProfileName = 'web',
    [string]$ProfilePath,
    [string]$ApiBaseUrl = 'https://api.github.com',
    [string]$CachePath,
    [int]$CacheTtlMinutes = 15,
    [string]$PluginName,
    [ValidateSet('auto', 'stable', 'preview')][string]$ReleaseChannel = 'auto',
    [switch]$NoApply,
    [switch]$NoCache
)

$ErrorActionPreference = 'Stop'

function Write-PluginStatus {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'UPDATE', 'WARN', 'SKIP')][string]$Level = 'INFO'
    )

    Write-Output "[DSH][Plugins][$Level] $Message"
}

function ConvertTo-PluginCommandOutputLine {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Management.Automation.ErrorRecord]) {
        $line = [string]$Value.Exception.Message
        if ([string]::IsNullOrWhiteSpace($line) -and $null -ne $Value.ErrorDetails) {
            $line = [string]$Value.ErrorDetails.Message
        }
        if ([string]::IsNullOrWhiteSpace($line)) { $line = [string]$Value.TargetObject }
    } else {
        $line = $Value.ToString()
    }
    return [regex]::Replace($line, "`e\[[0-?]*[ -/]*[@-~]", '')
}

function Get-ProfileRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
        return [System.IO.Path]::GetFullPath($env:DSH_HOME)
    }
    return Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dsh'
}

function ConvertTo-SemVer {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $match = [regex]::Match(
        $Value.Trim(),
        '(?i)(?<version>\d+\.\d+\.\d+(?:-[0-9a-z.-]+)?(?:\+[0-9a-z.-]+)?)$'
    )
    if (-not $match.Success) { return $null }

    $version = $match.Groups['version'].Value
    $withoutBuild = $version.Split('+')[0]
    $parts = $withoutBuild.Split('-', 2)
    $core = $parts[0].Split('.')
    return [pscustomobject]@{
        Text = $version
        Core = @([int]$core[0], [int]$core[1], [int]$core[2])
        Pre = if ($parts.Count -gt 1) { @($parts[1].Split('.')) } else { @() }
    }
}

function Compare-SemVer {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Right
    )

    for ($index = 0; $index -lt 3; $index++) {
        if ($Left.Core[$index] -gt $Right.Core[$index]) { return 1 }
        if ($Left.Core[$index] -lt $Right.Core[$index]) { return -1 }
    }
    if ($Left.Pre.Count -eq 0 -and $Right.Pre.Count -eq 0) { return 0 }
    if ($Left.Pre.Count -eq 0) { return 1 }
    if ($Right.Pre.Count -eq 0) { return -1 }

    $count = [Math]::Max($Left.Pre.Count, $Right.Pre.Count)
    for ($index = 0; $index -lt $count; $index++) {
        if ($index -ge $Left.Pre.Count) { return -1 }
        if ($index -ge $Right.Pre.Count) { return 1 }
        $leftPart = $Left.Pre[$index]
        $rightPart = $Right.Pre[$index]
        $leftNumber = 0
        $rightNumber = 0
        $leftNumeric = [int]::TryParse($leftPart, [ref]$leftNumber)
        $rightNumeric = [int]::TryParse($rightPart, [ref]$rightNumber)
        if ($leftNumeric -and $rightNumeric) {
            if ($leftNumber -gt $rightNumber) { return 1 }
            if ($leftNumber -lt $rightNumber) { return -1 }
            continue
        }
        if ($leftNumeric -and -not $rightNumeric) { return -1 }
        if (-not $leftNumeric -and $rightNumeric) { return 1 }
        $comparison = [string]::CompareOrdinal($leftPart, $rightPart)
        if ($comparison -gt 0) { return 1 }
        if ($comparison -lt 0) { return -1 }
    }
    return 0
}

function Test-SemVerRange {
    param(
        [Parameter(Mandatory)]$Version,
        [Parameter(Mandatory)][string]$Range
    )

    $trimmed = $Range.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -eq '*') { return $true }

    foreach ($alternative in @($trimmed -split '\s*\|\|\s*')) {
        $comparators = [regex]::Matches(
            $alternative,
            '(?<operator>\^|~|>=|<=|>|<|=)?\s*v?(?<version>\d+\.\d+\.\d+(?:-[0-9a-z.-]+)?(?:\+[0-9a-z.-]+)?)',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
        if ($comparators.Count -eq 0) { continue }
        if ($Version.Pre.Count -gt 0 -and $alternative -notmatch '\d+\.\d+\.\d+-') { continue }

        $matches = $true
        foreach ($comparator in $comparators) {
            $required = ConvertTo-SemVer ([string]$comparator.Groups['version'].Value)
            if ($null -eq $required) { $matches = $false; break }
            $comparison = Compare-SemVer $Version $required
            $operator = [string]$comparator.Groups['operator'].Value
            switch ($operator) {
                '^' {
                    if ($required.Core[0] -gt 0) {
                        $upperText = "$(($required.Core[0]) + 1).0.0"
                    } elseif ($required.Core[1] -gt 0) {
                        $upperText = "0.$(($required.Core[1]) + 1).0"
                    } else {
                        $upperText = "0.0.$(($required.Core[2]) + 1)"
                    }
                    $upper = ConvertTo-SemVer $upperText
                    if ($comparison -lt 0 -or (Compare-SemVer $Version $upper) -ge 0) { $matches = $false }
                }
                '~' {
                    $upper = ConvertTo-SemVer "$($required.Core[0]).$(($required.Core[1]) + 1).0"
                    if ($comparison -lt 0 -or (Compare-SemVer $Version $upper) -ge 0) { $matches = $false }
                }
                '>=' { if ($comparison -lt 0) { $matches = $false } }
                '<=' { if ($comparison -gt 0) { $matches = $false } }
                '>' { if ($comparison -le 0) { $matches = $false } }
                '<' { if ($comparison -ge 0) { $matches = $false } }
                default { if ($comparison -ne 0) { $matches = $false } }
            }
            if (-not $matches) { break }
        }
        if ($matches) { return $true }
    }
    return $false
}

function ConvertTo-GitHubPath {
    param([string]$Path)

    $segments = @($Path.Trim('/') -split '/' | ForEach-Object {
        [Uri]::EscapeDataString($_)
    })
    return ($segments -join '/')
}

function Resolve-GitHubSource {
    param(
        [Parameter(Mandatory)][string]$Spec,
        $InstalledManifest
    )

    if ($Spec -match '^(?i)(?:file|link):' -or $Spec -match '^[.]?[.][/\\]') {
        $normalizedLocalSpec = $Spec.Replace('\\', '/').Replace('//', '/')
        $managedSkin = [regex]::Match(
            $normalizedLocalSpec,
            '(?i)/plugin-sources/dsh-deep-whale/(?<commit>[0-9a-f]{40})/dsh-deep-whale-[0-9a-f]{40}/(?<path>skin-manager|maid-atelier|orca-link)/?$'
        )
        if ($managedSkin.Success) {
            return [pscustomobject]@{
                Local = $false
                Repo = 'Small-tailqwq/dsh-deep-whale'
                Path = $managedSkin.Groups['path'].Value
                Direct = $true
                Pinned = $false
                ManagedCache = $true
                InstalledCommit = $managedSkin.Groups['commit'].Value.ToLowerInvariant()
            }
        }
        return [pscustomobject]@{ Local = $true; Repo = $null; Path = $null; Direct = $false; Pinned = $false; ManagedCache = $false; InstalledCommit = $null }
    }

    $repo = $null
    $fragment = ''
    $direct = $false
    $specMatch = [regex]::Match($Spec, '^(?i)github:(?<owner>[^/#]+)[/](?<repo>[^#]+?)(?:[.]git)?(?:#(?<fragment>.*))?$')
    if ($specMatch.Success) {
        $repo = "$($specMatch.Groups['owner'].Value)/$($specMatch.Groups['repo'].Value)"
        $fragment = $specMatch.Groups['fragment'].Value
        $direct = $true
    } else {
        $specMatch = [regex]::Match(
            $Spec,
            '^(?i)git\+https://github[.]com/(?<owner>[^/]+)/(?<repo>[^#]+?)(?:[.]git)?(?:#(?<fragment>.*))?$'
        )
        if ($specMatch.Success) {
            $repo = "$($specMatch.Groups['owner'].Value)/$($specMatch.Groups['repo'].Value)"
            $fragment = $specMatch.Groups['fragment'].Value
            $direct = $true
        }
    }

    $repository = if ($null -ne $InstalledManifest) { $InstalledManifest.repository } else { $null }
    $repositoryUrl = if ($repository -is [string]) {
        [string]$repository
    } elseif ($null -ne $repository) {
        [string]$repository.url
    } else {
        ''
    }
    if ([string]::IsNullOrWhiteSpace($repo) -and -not [string]::IsNullOrWhiteSpace($repositoryUrl)) {
        $repoMatch = [regex]::Match(
            $repositoryUrl,
            '(?i)github[.]com[:/](?<owner>[^/]+)/(?<repo>[^/#]+?)(?:[.]git)?(?:[/#]|$)'
        )
        if ($repoMatch.Success) {
            $repo = "$($repoMatch.Groups['owner'].Value)/$($repoMatch.Groups['repo'].Value)"
        }
    }

    $packagePath = ''
    $pathMatch = [regex]::Match($fragment, '(?i)(?:^|&)path:(?<path>/[^&]+)')
    if ($pathMatch.Success) {
        $packagePath = $pathMatch.Groups['path'].Value.Trim('/')
    } elseif ($repository -isnot [string] -and $null -ne $repository -and
              -not [string]::IsNullOrWhiteSpace([string]$repository.directory)) {
        $packagePath = ([string]$repository.directory).Trim('/').Replace('\', '/')
    }

    $nonPathFragment = @($fragment -split '&' | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^(?i)path:'
    })
    return [pscustomobject]@{
        Local = $false
        Repo = $repo
        Path = $packagePath
        Direct = $direct
        Pinned = $direct -and $nonPathFragment.Count -gt 0
        ManagedCache = $false
        InstalledCommit = $null
    }
}

function Get-InstalledCommit {
    param(
        [Parameter(Mandatory)][string]$LockText,
        [Parameter(Mandatory)][string]$PackageName
    )

    $importerEnd = $LockText.IndexOf("`npackages:")
    $importer = if ($importerEnd -ge 0) { $LockText.Substring(0, $importerEnd) } else { $LockText }
    $escapedName = [regex]::Escape($PackageName)
    $blockMatch = [regex]::Match(
        $importer,
        "(?ms)^\s{6}(?:'$escapedName'|$escapedName):\r?\n(?<block>(?:\s{8}[^\r\n]*\r?\n){1,5})"
    )
    if (-not $blockMatch.Success) { return $null }
    $shaMatch = [regex]::Match($blockMatch.Groups['block'].Value, '(?i)(?<sha>[0-9a-f]{40})')
    if (-not $shaMatch.Success) { return $null }
    return $shaMatch.Groups['sha'].Value.ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $ProfilePath = Join-Path (Get-ProfileRoot) "profiles\$ProfileName"
}
$ProfilePath = [System.IO.Path]::GetFullPath($ProfilePath)
$manifestPath = Join-Path $ProfilePath 'package.json'
$lockPath = Join-Path $ProfilePath 'pnpm-lock.yaml'
if ([string]::IsNullOrWhiteSpace($CachePath)) {
    $CachePath = Join-Path $env:LOCALAPPDATA 'DSH\github-plugin-cache.json'
}

$harnessManifestPath = Join-Path $HarnessPath 'package.json'
if (-not (Test-Path -LiteralPath $harnessManifestPath)) {
    throw "Harness package manifest was not found: $harnessManifestPath"
}
$harnessManifest = Get-Content -LiteralPath $harnessManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:harnessVersion = ConvertTo-SemVer ([string]$harnessManifest.version)
if ($null -eq $script:harnessVersion) {
    throw "Harness version is not semantic: $($harnessManifest.version)"
}

if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-PluginStatus "Profile '$ProfileName' has no installed plugin manifest; skipped." 'SKIP'
    exit 0
}

Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$client = New-Object System.Net.Http.HttpClient($handler)
$client.Timeout = [TimeSpan]::FromSeconds(30)
$client.DefaultRequestHeaders.UserAgent.ParseAdd('DSH-Launcher/1.0')
$client.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
$client.DefaultRequestHeaders.Add('X-GitHub-Api-Version', '2026-03-10')
$token = if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
    $env:GH_TOKEN
} elseif (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    $env:GITHUB_TOKEN
} elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GH_TOKEN', 'User'))) {
    [Environment]::GetEnvironmentVariable('GH_TOKEN', 'User')
} elseif (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User'))) {
    [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'User')
} else {
    $null
}
if ($null -ne $token) {
    $client.DefaultRequestHeaders.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue('Bearer', $token)
}

$script:cacheEntries = @{}
$script:cacheDirty = $false
if (-not $NoCache -and (Test-Path -LiteralPath $CachePath)) {
    try {
        $cacheDocument = Get-Content -LiteralPath $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $cacheDocument.entries) {
            foreach ($property in $cacheDocument.entries.PSObject.Properties) {
                $script:cacheEntries[$property.Name] = $property.Value
            }
        }
    } catch {
        $script:cacheEntries = @{}
    }
}

function Save-ApiCache {
    if ($NoCache -or -not $script:cacheDirty) { return }
    $cacheDirectory = Split-Path -Parent $CachePath
    New-Item -ItemType Directory -Force -Path $cacheDirectory | Out-Null
    [ordered]@{
        version = 1
        entries = $script:cacheEntries
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $CachePath -Encoding UTF8
}

function Get-GitHubJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Accept = 'application/vnd.github+json'
    )

    $url = $ApiBaseUrl.TrimEnd('/') + $Path
    $cacheKey = "$Accept $url"
    if (-not $NoCache -and $script:cacheEntries.ContainsKey($cacheKey)) {
        $entry = $script:cacheEntries[$cacheKey]
        $fetchedAt = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$entry.fetchedAt, [ref]$fetchedAt) -and
            $fetchedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(-$CacheTtlMinutes)) {
            if ([int]$entry.status -eq 404) { return $null }
            return ([string]$entry.body | ConvertFrom-Json)
        }
    }

    $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
    $request.Headers.Accept.Clear()
    $request.Headers.Accept.ParseAdd($Accept)
    try {
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        try {
            $status = [int]$response.StatusCode
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            if (-not $NoCache -and $status -in @(200, 404)) {
                $script:cacheEntries[$cacheKey] = [ordered]@{
                    fetchedAt = [DateTimeOffset]::UtcNow.ToString('o')
                    status = $status
                    body = $body
                }
                $script:cacheDirty = $true
            }
            if ($status -eq 404) { return $null }
            if ($status -lt 200 -or $status -ge 300) {
                $message = "GitHub API returned HTTP $status"
                try {
                    $errorDocument = $body | ConvertFrom-Json
                    if (-not [string]::IsNullOrWhiteSpace([string]$errorDocument.message)) {
                        $message += ": $($errorDocument.message)"
                    }
                } catch { }
                throw $message
            }
            return ($body | ConvertFrom-Json)
        } finally {
            $response.Dispose()
        }
    } finally {
        $request.Dispose()
    }
}

function Get-InstalledHarnessPackageVersion {
    param([Parameter(Mandatory)][string]$PackageName)

    foreach ($root in @($ProfilePath, $HarnessPath)) {
        $candidate = Join-Path $root "node_modules\$PackageName\package.json"
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            return [string](Get-Content -LiteralPath $candidate -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } catch { }
    }
    return $null
}

function Test-PluginCoreCompatibility {
    param([Parameter(Mandatory)]$RemoteManifest)

    if ($null -eq $RemoteManifest.peerDependencies) { return $true }
    $corePeers = @($RemoteManifest.peerDependencies.PSObject.Properties | Where-Object {
        $_.Name -match '^@deepseek-ai/dsh(?:-|$)'
    })
    foreach ($peer in $corePeers) {
        $installedText = Get-InstalledHarnessPackageVersion ([string]$peer.Name)
        if ([string]::IsNullOrWhiteSpace($installedText)) { $installedText = $script:harnessVersion.Text }
        $installed = ConvertTo-SemVer $installedText
        if ($null -eq $installed -or -not (Test-SemVerRange $installed ([string]$peer.Value))) {
            return $false
        }
    }
    return $true
}

function Get-GitHubManifestAtTag {
    param(
        [Parameter(Mandatory)]$Plugin,
        [Parameter(Mandatory)][string]$Tag
    )

    $encodedRepo = (($Plugin.Source.Repo -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $manifestRelativePath = if ([string]::IsNullOrWhiteSpace($Plugin.Source.Path)) {
        'package.json'
    } else {
        "$($Plugin.Source.Path.Trim('/'))/package.json"
    }
    $encodedManifestPath = ConvertTo-GitHubPath $manifestRelativePath
    $encodedTag = [Uri]::EscapeDataString($Tag)
    return Get-GitHubJson "/repos/$encodedRepo/contents/$encodedManifestPath`?ref=$encodedTag" 'application/vnd.github.raw+json'
}

function Get-LatestGitHubVersion {
    param(
        [Parameter(Mandatory)]$Plugin,
        [Parameter(Mandatory)]$InstalledVersion
    )

    $repoPath = $Plugin.Source.Repo
    $encodedRepo = (($repoPath -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
    $includePrerelease = $ReleaseChannel -eq 'preview' -or
        ($ReleaseChannel -eq 'auto' -and $script:harnessVersion.Pre.Count -gt 0) -or
        $InstalledVersion.Pre.Count -gt 0
    $candidates = @()

    $releases = if ($includePrerelease) {
        @(Get-GitHubJson "/repos/$encodedRepo/releases?per_page=30")
    } else {
        @(Get-GitHubJson "/repos/$encodedRepo/releases/latest")
    }
    foreach ($release in $releases) {
        if ($null -eq $release -or $release.draft -eq $true) { continue }
        $version = ConvertTo-SemVer ([string]$release.tag_name)
        if ($null -eq $version -or (-not $includePrerelease -and $version.Pre.Count -gt 0)) { continue }
        $candidates += [pscustomobject]@{ Version = $version; Tag = [string]$release.tag_name }
    }

    if ($candidates.Count -eq 0) {
        $tags = @(Get-GitHubJson "/repos/$encodedRepo/tags?per_page=30")
        foreach ($tag in $tags) {
            if ($null -eq $tag) { continue }
            $version = ConvertTo-SemVer ([string]$tag.name)
            if ($null -eq $version -or (-not $includePrerelease -and $version.Pre.Count -gt 0)) { continue }
            $candidates += [pscustomobject]@{ Version = $version; Tag = [string]$tag.name }
        }
    }
    if ($candidates.Count -eq 0) { return $null }

    $best = $null
    foreach ($candidate in $candidates) {
        try {
            $remoteManifest = Get-GitHubManifestAtTag $Plugin $candidate.Tag
            if ($null -eq $remoteManifest -or [string]$remoteManifest.name -ne $Plugin.Name) { continue }
            $manifestVersion = ConvertTo-SemVer ([string]$remoteManifest.version)
            if ($null -eq $manifestVersion -or (Compare-SemVer $manifestVersion $candidate.Version) -ne 0) { continue }
            if (-not (Test-PluginCoreCompatibility $remoteManifest)) { continue }
            if ($null -eq $best -or (Compare-SemVer $manifestVersion $best.Version) -gt 0) {
                $best = [pscustomobject]@{
                    Version = $manifestVersion
                    Tag = $candidate.Tag
                    Channel = if ($manifestVersion.Pre.Count -gt 0) { 'preview' } else { 'stable' }
                }
            }
        } catch { }
    }
    return $best
}

try {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $bundleNames = @($manifest.dsh.profile.bundles)
    $bundleSet = @{}
    foreach ($bundleName in $bundleNames) { $bundleSet[[string]$bundleName] = $true }

    $plugins = @()
    foreach ($dependency in $manifest.dependencies.PSObject.Properties) {
        $name = [string]$dependency.Name
        if (-not [string]::IsNullOrWhiteSpace($PluginName) -and $name -ne $PluginName) { continue }
        if (-not $bundleSet.ContainsKey($name)) { continue }
        $installedManifestPath = Join-Path $ProfilePath "node_modules\$name\package.json"
        if (-not (Test-Path -LiteralPath $installedManifestPath)) {
            Write-PluginStatus "$name is declared but not installed." 'WARN'
            continue
        }
        $installedManifest = Get-Content -LiteralPath $installedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $plugins += [pscustomobject]@{
            Name = $name
            Spec = [string]$dependency.Value
            InstalledVersion = [string]$installedManifest.version
            Source = Resolve-GitHubSource ([string]$dependency.Value) $installedManifest
        }
    }

    if ($plugins.Count -eq 0) {
        Write-PluginStatus "Profile '$ProfileName' has no third-party bundles to check." 'OK'
        exit 0
    }

    $channelText = if ($ReleaseChannel -eq 'auto' -and $script:harnessVersion.Pre.Count -gt 0) {
        'stable and compatible preview releases'
    } elseif ($ReleaseChannel -eq 'preview') {
        'stable and compatible preview releases'
    } else {
        'stable releases'
    }
    Write-PluginStatus "Checking $($plugins.Count) installed bundle(s) through GitHub ($channelText; Harness $($script:harnessVersion.Text))..."
    $lockText = if (Test-Path -LiteralPath $lockPath) {
        Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
    } else {
        ''
    }
    $updates = @()
    $checked = 0
    $skipped = 0
    $failed = 0

    foreach ($plugin in $plugins) {
        if ($plugin.Source.Local) {
            Write-PluginStatus "$($plugin.Name): local file/link source." 'SKIP'
            $skipped++
            continue
        }
        if ([string]::IsNullOrWhiteSpace([string]$plugin.Source.Repo)) {
            Write-PluginStatus "$($plugin.Name): package metadata has no GitHub repository." 'SKIP'
            $skipped++
            continue
        }
        if ($plugin.Source.Pinned) {
            Write-PluginStatus "$($plugin.Name): GitHub source is pinned to an explicit ref." 'SKIP'
            $skipped++
            continue
        }

        try {
            if ($plugin.Source.Direct) {
                $encodedRepo = (($plugin.Source.Repo -split '/') | ForEach-Object {
                    [Uri]::EscapeDataString($_)
                }) -join '/'
                $head = Get-GitHubJson "/repos/$encodedRepo/commits/HEAD"
                $installedCommit = if (-not [string]::IsNullOrWhiteSpace([string]$plugin.Source.InstalledCommit)) {
                    [string]$plugin.Source.InstalledCommit
                } else {
                    Get-InstalledCommit $lockText $plugin.Name
                }
                if ($null -eq $head -or [string]::IsNullOrWhiteSpace([string]$head.sha)) {
                    throw 'default-branch commit was not returned'
                }
                if ([string]::IsNullOrWhiteSpace($installedCommit)) {
                    throw 'installed commit was not found in pnpm-lock.yaml'
                }
                $checked++
                if ($installedCommit -ne ([string]$head.sha).ToLowerInvariant()) {
                    Write-PluginStatus "$($plugin.Name): $($installedCommit.Substring(0, 8)) -> $(([string]$head.sha).Substring(0, 8))" 'UPDATE'
                    $updates += [pscustomobject]@{
                        Plugin = $plugin
                        Kind = 'commit'
                        Expected = ([string]$head.sha).ToLowerInvariant()
                    }
                } else {
                    Write-PluginStatus "$($plugin.Name): latest commit $($installedCommit.Substring(0, 8))." 'OK'
                }
                continue
            }

            $installedVersion = ConvertTo-SemVer $plugin.InstalledVersion
            if ($null -eq $installedVersion) { throw "installed version is not semantic: $($plugin.InstalledVersion)" }
            $latest = Get-LatestGitHubVersion $plugin $installedVersion
            if ($null -eq $latest) { throw 'no matching semantic GitHub release or tag was found' }
            $checked++
            $comparison = Compare-SemVer $latest.Version $installedVersion
            if ($comparison -gt 0) {
                Write-PluginStatus "$($plugin.Name): $($installedVersion.Text) -> $($latest.Version.Text) ($($latest.Channel), $($latest.Tag))" 'UPDATE'
                $updates += [pscustomobject]@{
                    Plugin = $plugin
                    Kind = 'version'
                    Expected = $latest.Version.Text
                    Channel = $latest.Channel
                }
            } elseif ($comparison -eq 0) {
                Write-PluginStatus "$($plugin.Name): latest version $($installedVersion.Text)." 'OK'
            } else {
                Write-PluginStatus "$($plugin.Name): installed $($installedVersion.Text) is newer than GitHub $($latest.Version.Text)." 'WARN'
            }
        } catch {
            Write-PluginStatus "$($plugin.Name): $($_.Exception.Message)" 'WARN'
            $failed++
        }
    }

    Save-ApiCache

    if ($updates.Count -eq 0) {
        Write-PluginStatus "Check complete: $checked checked, $skipped skipped, $failed unavailable; no plugin update is required." 'OK'
        exit 0
    }

    $updateNames = @($updates | ForEach-Object { $_.Plugin.Name } | Select-Object -Unique)
    if ($NoApply) {
        Write-PluginStatus "Updates available for: $($updateNames -join ', ')." 'UPDATE'
        Write-PluginStatus 'NoApply is set; installed files were not changed.' 'SKIP'
        exit 0
    }

    $pnpm = Get-Command 'pnpm.cmd' -ErrorAction SilentlyContinue
    if ($null -eq $pnpm) { $pnpm = Get-Command 'pnpm' -ErrorAction SilentlyContinue }
    if ($null -eq $pnpm) { throw 'pnpm was not found on PATH' }

    function Restore-PluginActivationList {
        if (-not (Test-Path -LiteralPath $manifestPath)) { return }
        $manifestAfterUpdate = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $bundlesAfterUpdate = @($manifestAfterUpdate.dsh.profile.bundles)
        if (($bundlesAfterUpdate -join "`0") -ne ($bundleNames -join "`0")) {
            $manifestAfterUpdate.dsh.profile.bundles = @($bundleNames)
            $manifestJson = $manifestAfterUpdate | ConvertTo-Json -Depth 100
            [System.IO.File]::WriteAllText($manifestPath, $manifestJson + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            Write-PluginStatus 'Restored the Web plugin activation list after package updates.' 'OK'
        }
    }

    # The API client above owns its direct-connection policy. Package downloads
    # and Git must retain the user's proxy settings; forcing NO_PROXY here can
    # strand git ls-remote even when the core updater's configured route works.
    function Invoke-HarnessPluginUpdate {
        param(
            [Parameter(Mandatory)][string[]]$Names,
            [string]$TargetVersion,
            [string]$Registry,
            [ValidateSet('update', 'add')][string]$Operation = 'update'
        )

        $operation = $Operation
        $targets = if ([string]::IsNullOrWhiteSpace($TargetVersion)) {
            @($Names)
        } else {
            @($Names | ForEach-Object { "$_@$TargetVersion" })
        }
        $arguments = @(
            'dsh', 'plugin', '--profile', $ProfileName, $operation,
            '--fetch-timeout=300000',
            '--fetch-retries=2',
            '--fetch-retry-mintimeout=10000',
            '--fetch-retry-maxtimeout=60000',
            '--network-concurrency=1'
        )
        if ($Operation -eq 'update' -and [string]::IsNullOrWhiteSpace($TargetVersion)) { $arguments += '--latest' }
        $arguments += $targets
        Push-Location -LiteralPath $HarnessPath
        $previousErrorActionPreference = $ErrorActionPreference
        $previousConsoleEncoding = [Console]::OutputEncoding
        $previousRegistry = [Environment]::GetEnvironmentVariable('npm_config_registry', 'Process')
        $gitConfigCountText = [Environment]::GetEnvironmentVariable('GIT_CONFIG_COUNT', 'Process')
        $gitConfigCount = 0
        if (-not [int]::TryParse($gitConfigCountText, [ref]$gitConfigCount)) { $gitConfigCount = 0 }
        $gitConfigKeyName = "GIT_CONFIG_KEY_$gitConfigCount"
        $gitConfigValueName = "GIT_CONFIG_VALUE_$gitConfigCount"
        $previousGitConfigKey = [Environment]::GetEnvironmentVariable($gitConfigKeyName, 'Process')
        $previousGitConfigValue = [Environment]::GetEnvironmentVariable($gitConfigValueName, 'Process')
        try {
            # Windows PowerShell 5.1 wraps every native stderr line in an ErrorRecord.
            # pnpm writes its normal command banner to stderr, so Stop would abort the
            # pipeline before pnpm can finish. Preserve the merged output and judge the
            # native command solely by its exit code.
            $ErrorActionPreference = 'Continue'
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
            if (-not [string]::IsNullOrWhiteSpace($Registry)) {
                [Environment]::SetEnvironmentVariable('npm_config_registry', $Registry, 'Process')
            }
            # pnpm resolves github: shorthand refs through git+ssh by default. This
            # process-scoped Git config keeps public plugin updates on
            # authentication-free HTTPS without changing global Git configuration.
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', [string]($gitConfigCount + 1), 'Process')
            [Environment]::SetEnvironmentVariable($gitConfigKeyName, 'url.https://github.com/.insteadOf', 'Process')
            [Environment]::SetEnvironmentVariable($gitConfigValueName, 'git+ssh://git@github.com/', 'Process')
            & $pnpm.Source @arguments 2>&1 | ForEach-Object { ConvertTo-PluginCommandOutputLine $_ }
            $updateExitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
            [Console]::OutputEncoding = $previousConsoleEncoding
            [Environment]::SetEnvironmentVariable('npm_config_registry', $previousRegistry, 'Process')
            [Environment]::SetEnvironmentVariable('GIT_CONFIG_COUNT', $gitConfigCountText, 'Process')
            [Environment]::SetEnvironmentVariable($gitConfigKeyName, $previousGitConfigKey, 'Process')
            [Environment]::SetEnvironmentVariable($gitConfigValueName, $previousGitConfigValue, 'Process')
            Pop-Location
        }
        if ($updateExitCode -ne 0) {
            throw "Harness plugin manager exited with code $updateExitCode"
        }
    }

    function Install-ManagedGitHubBundleGroup {
        param([Parameter(Mandatory)][object[]]$GroupUpdates)

        $first = $GroupUpdates[0]
        $repo = [string]$first.Plugin.Source.Repo
        $commit = [string]$first.Expected
        $repoName = ($repo -split '/')[-1]
        $sourceRoot = Join-Path (Get-ProfileRoot) "plugin-sources\$repoName\$commit"
        $packageRoot = Join-Path $sourceRoot "$repoName-$commit"
        if (-not (Test-Path -LiteralPath $packageRoot)) {
            New-Item -ItemType Directory -Force -Path $sourceRoot | Out-Null
            $archivePath = Join-Path $sourceRoot "$repoName-$commit.tar.gz"
            $archiveUrl = "https://codeload.github.com/$repo/tar.gz/$commit"
            Write-PluginStatus "Downloading the $repo source archive once for all bundled packages..." 'UPDATE'
            $archiveHandler = New-Object System.Net.Http.HttpClientHandler
            $archiveHandler.UseProxy = $false
            $archiveClient = New-Object System.Net.Http.HttpClient($archiveHandler)
            $archiveClient.Timeout = [TimeSpan]::FromMinutes(3)
            try {
                $archiveBytes = $archiveClient.GetByteArrayAsync($archiveUrl).GetAwaiter().GetResult()
            } finally {
                $archiveClient.Dispose()
                $archiveHandler.Dispose()
            }
            [System.IO.File]::WriteAllBytes($archivePath, $archiveBytes)
            $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
            if ($null -eq $tar) { throw 'tar.exe was not found for the managed GitHub bundle update.' }
            & $tar.Source '-xzf' $archivePath '-C' $sourceRoot
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract the $repo source archive." }
        }
        foreach ($groupUpdate in $GroupUpdates) {
            $bundlePath = Join-Path $packageRoot ([string]$groupUpdate.Plugin.Source.Path)
            $bundleManifestPath = Join-Path $bundlePath 'package.json'
            if (-not (Test-Path -LiteralPath $bundleManifestPath)) { throw "Managed GitHub source is missing $($groupUpdate.Plugin.Source.Path)/package.json." }
            $bundleManifest = Get-Content -LiteralPath $bundleManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$bundleManifest.name -ne [string]$groupUpdate.Plugin.Name -or $null -eq $bundleManifest.dsh.bundle) {
                throw "Managed GitHub source path $($groupUpdate.Plugin.Source.Path) is not bundle $($groupUpdate.Plugin.Name)."
            }
            Invoke-HarnessPluginUpdate -Names @($bundlePath) -Operation add
        }
    }

    Write-PluginStatus "Updating $($updateNames.Count) bundle(s) through the Harness plugin manager..." 'UPDATE'
    $applyFailures = New-Object System.Collections.ArrayList
    $commitUpdates = @($updates | Where-Object { $_.Kind -eq 'commit' })
    # A repository can publish several bundle names (for example, the three whale
    # skins). Updating those names in one pnpm transaction avoids downloading and
    # resolving the same Git repository repeatedly.
    $commitGroups = @($commitUpdates | Group-Object { $_.Plugin.Source.Repo })
    foreach ($commitGroup in $commitGroups) {
        $groupNames = @($commitGroup.Group | ForEach-Object { $_.Plugin.Name })
        $groupLabel = $groupNames -join ', '
        try {
            if (@($commitGroup.Group | Where-Object { $_.Plugin.Source.ManagedCache }).Count -eq $commitGroup.Count) {
                Write-PluginStatus "Updating managed GitHub bundle group $groupLabel from one verified source archive..." 'UPDATE'
                Install-ManagedGitHubBundleGroup -GroupUpdates @($commitGroup.Group)
                continue
            }
            $groupUpdated = $false
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    $registry = if ($attempt -eq 1) { '' } else { 'https://registry.npmjs.org/' }
                    $route = if ($attempt -eq 1) { 'configured registry' } else { 'official npm registry' }
                    Write-PluginStatus "Updating GitHub bundle group $groupLabel (attempt $attempt/3, $route)..." 'UPDATE'
                    Invoke-HarnessPluginUpdate -Names $groupNames -Registry $registry
                    $groupUpdated = $true
                    break
                } catch {
                    if ($attempt -eq 3) { throw }
                    Write-PluginStatus "$groupLabel`: transient package download failed; retrying through another registry." 'WARN'
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
            if (-not $groupUpdated) { throw "Failed to update $groupLabel" }
        } catch {
            [void]$applyFailures.Add($groupLabel)
            Write-PluginStatus "$groupLabel`: update failed and was isolated; remaining plugins will continue. $($_.Exception.Message)" 'WARN'
        }
    }
    $versionUpdates = @($updates | Where-Object { $_.Kind -eq 'version' })
    foreach ($versionUpdate in $versionUpdates) {
        try {
            $versionUpdated = $false
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                try {
                    $registry = if ($attempt -eq 1) { '' } else { 'https://registry.npmjs.org/' }
                    $route = if ($attempt -eq 1) { 'configured registry' } else { 'official npm registry' }
                    Write-PluginStatus "Installing $($versionUpdate.Plugin.Name)@$($versionUpdate.Expected) from the $($versionUpdate.Channel) channel ($route)..." 'UPDATE'
                    Invoke-HarnessPluginUpdate -Names @($versionUpdate.Plugin.Name) -TargetVersion $versionUpdate.Expected -Registry $registry
                    $versionUpdated = $true
                    break
                } catch {
                    if ($attempt -eq 2) { throw }
                    Write-PluginStatus "$($versionUpdate.Plugin.Name): configured registry failed; retrying through the official npm registry." 'WARN'
                }
            }
            if (-not $versionUpdated) { throw 'The requested version was not installed.' }
        } catch {
            [void]$applyFailures.Add([string]$versionUpdate.Plugin.Name)
            Write-PluginStatus "$($versionUpdate.Plugin.Name): update failed and was isolated; remaining plugins will continue. $($_.Exception.Message)" 'WARN'
        }
    }

    # Harness currently removes a bundle from dsh.profile.bundles while updating
    # it and does not always add it back. An update must never change the user's
    # enabled/disabled state, so restore the exact activation list captured before
    # any package transaction.
    Restore-PluginActivationList

    $newLockText = if (Test-Path -LiteralPath $lockPath) {
        Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8
    } else {
        ''
    }
    foreach ($update in $updates) {
        if ($update.Kind -eq 'commit') {
            $installedCommit = Get-InstalledCommit $newLockText $update.Plugin.Name
            if ($installedCommit -eq $update.Expected) {
                Write-PluginStatus "$($update.Plugin.Name): updated to commit $($installedCommit.Substring(0, 8))." 'OK'
            } else {
                Write-PluginStatus "$($update.Plugin.Name): pnpm did not reach GitHub commit $($update.Expected.Substring(0, 8))." 'WARN'
            }
            continue
        }

        $installedManifestPath = Join-Path $ProfilePath "node_modules\$($update.Plugin.Name)\package.json"
        $newVersion = if (Test-Path -LiteralPath $installedManifestPath) {
            [string](Get-Content -LiteralPath $installedManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json).version
        } else {
            ''
        }
        if ($newVersion -eq $update.Expected) {
            Write-PluginStatus "$($update.Plugin.Name): updated to $newVersion." 'OK'
        } else {
            Write-PluginStatus "$($update.Plugin.Name): pnpm installed '$newVersion'; GitHub latest is $($update.Expected)." 'WARN'
        }
    }
    if ($applyFailures.Count -gt 0) {
        Write-PluginStatus "Plugin update completed with isolated failures: $($applyFailures -join ', '). The Harness core remains usable." 'WARN'
        exit 2
    } else {
        Write-PluginStatus "Plugin update complete: $($updates.Count) update candidate(s) processed." 'OK'
    }
} finally {
    try {
        if ($null -ne (Get-Command Restore-PluginActivationList -ErrorAction SilentlyContinue)) {
            Restore-PluginActivationList
        }
    } catch { }
    try { Save-ApiCache } catch { }
    $client.Dispose()
    $handler.Dispose()
}
