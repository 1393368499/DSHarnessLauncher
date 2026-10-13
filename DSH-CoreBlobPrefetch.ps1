param(
    [Parameter(Mandatory)][string]$HarnessPath,
    [Parameter(Mandatory)][string]$Ref,
    [string]$GitPath = 'git.exe',
    [ValidateRange(1, 1000)][int]$BatchSize = 500
)

$ErrorActionPreference = 'Stop'
$HarnessPath = [IO.Path]::GetFullPath($HarnessPath)

function Get-MissingBlobs {
    param([string[]]$ObjectIds)
    if ($ObjectIds.Count -eq 0) { return @() }
    $previous = $env:GIT_NO_LAZY_FETCH
    $env:GIT_NO_LAZY_FETCH = '1'
    try {
        $states = @($ObjectIds | & $GitPath -C $HarnessPath cat-file --batch-check='%(objectname) %(objecttype)')
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect local Harness objects.' }
        return @($states | Where-Object { $_ -match '^[0-9a-f]{40} missing$' } |
            ForEach-Object { $_.Substring(0, 40) })
    } finally {
        $env:GIT_NO_LAZY_FETCH = $previous
    }
}

function Invoke-BlobBatchFetch {
    param([string[]]$ObjectIds, [switch]$Direct)
    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = $GitPath
    $route = if ($Direct) { '-c http.proxy= -c https.proxy= ' } else { '' }
    $startInfo.Arguments = '-c fetch.negotiationAlgorithm=noop -c http.version=HTTP/1.1 ' +
        '-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 ' + $route +
        '-C "' + $HarnessPath + '" fetch origin --no-tags --no-write-fetch-head ' +
        '--recurse-submodules=no --filter=blob:none --stdin'
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($startInfo)
    try {
        $errorTask = $process.StandardError.ReadToEndAsync()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $process.StandardInput.Write(($ObjectIds -join [char]10) + [char]10)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(180000)) {
            & taskkill.exe /PID $process.Id /T /F *> $null
            [void]$process.WaitForExit(5000)
            return [pscustomobject]@{ ExitCode = 124; Detail = 'Git blob download timed out.' }
        }
        [void]$outputTask.GetAwaiter().GetResult()
        $errorText = [string]$errorTask.GetAwaiter().GetResult()
        $lastError = @($errorText -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 1)
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Detail = if ($lastError.Count -gt 0) { $lastError[0].Trim() } else { '' }
        }
    } finally {
        $process.Dispose()
    }
}

$treeRows = @(& $GitPath -C $HarnessPath ls-tree -r --format='%(objecttype) %(objectname)' $Ref)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect the target Harness tree: $Ref" }
$objectIds = @($treeRows | Where-Object { $_ -match '^blob [0-9a-f]{40}$' } |
    ForEach-Object { $_.Substring(5) } | Sort-Object -Unique)
$missing = @(Get-MissingBlobs -ObjectIds $objectIds)
if ($missing.Count -eq 0) {
    Write-Output '[DSH][CorePrefetch][OK] All target core files are already local.'
    exit 0
}

$total = $missing.Count
Write-Output "[DSH][CorePrefetch] Downloading $total missing core files in batches of $BatchSize..."
for ($offset = 0; $offset -lt $total; $offset += $BatchSize) {
    $last = [Math]::Min($offset + $BatchSize - 1, $total - 1)
    $batch = @($missing[$offset..$last])
    $remaining = @(Get-MissingBlobs -ObjectIds $batch)
    for ($attempt = 1; $remaining.Count -gt 0 -and $attempt -le 3; $attempt++) {
        $result = Invoke-BlobBatchFetch -ObjectIds $remaining -Direct:($attempt -eq 3)
        $remaining = @(Get-MissingBlobs -ObjectIds $remaining)
        if ($remaining.Count -gt 0 -and $attempt -lt 3) {
            Write-Output "[DSH][CorePrefetch][WARN] Batch download was interrupted; retrying $($remaining.Count) file(s)..."
            Start-Sleep -Seconds 2
        }
    }
    if ($remaining.Count -gt 0) {
        throw "Could not download $($remaining.Count) core file(s) after three attempts. Last error: $($result.Detail)"
    }
    Write-Output "[DSH][CorePrefetch] Ready $([Math]::Min($last + 1, $total))/$total missing files."
}
Write-Output '[DSH][CorePrefetch][OK] Target core files are ready for the local update.'
