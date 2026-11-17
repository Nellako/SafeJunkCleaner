#requires -Version 5.1
# L01: every operation gets a GUID-unique log with real status/counts, scan and clean
# logs never collide, and a missing log path is surfaced as an explicit failure.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
try {
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($files)
    New-TestFile -Path (Join-Path $files 'log-a.tmp') -Bytes 11 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'log-b.tmp') -Bytes 22 -AgeHours 96 | Out-Null

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'scan succeeds' 'Success' $scan.Status $scan.Error
    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    Assert-Equal 'clean succeeds' 'Success' $clean.Status $clean.Error

    $logs = @($scan.LogPath, $clean.LogPath)
    Assert-True 'both operations produced a log' (@($logs | Where-Object { [string]::IsNullOrWhiteSpace($_) -or -not [IO.File]::Exists($_) }).Count -eq 0) ($logs -join '; ')
    Assert-Equal 'scan and clean log paths are different' 2 (@($logs | Select-Object -Unique).Count) ($logs -join '; ')
    Assert-True 'log names are Operation-GUID.json' ((@($logs | Where-Object { [IO.Path]::GetFileName($_) -notmatch '^(scan|clean)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.json$' }).Count) -eq 0) ($logs -join '; ')

    $scanLog = Get-Content -LiteralPath $scan.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'scan log Status is Success' 'Success' ([string]$scanLog.Status)
    Assert-Equal 'scan log TaskId matches' ([string]$scan.TaskId) ([string]$scanLog.TaskId)
    Assert-Equal 'scan log CandidateCount matches' ([int64]$scan.CandidateCount) ([int64]$scanLog.CandidateCount)
    Assert-True 'scan log has no deletion counters that could be mistaken for work done' (@($scanLog.PSObject.Properties.Name | Where-Object { $_ -match '^(?i:Deleted|Released|Freed|SpaceSaved)$' }).Count -eq 0) (@($scanLog.PSObject.Properties.Name) -join ',')

    $cleanLog = Get-Content -LiteralPath $clean.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'clean log Status is Success' 'Success' ([string]$cleanLog.Status)
    Assert-Equal 'clean log Deleted matches' ([int64]$clean.Deleted) ([int64]$cleanLog.Deleted)
    Assert-Equal 'clean log ProcessedBytes matches' ([int64]$clean.ProcessedBytes) ([int64]$cleanLog.ProcessedBytes)
    Assert-Equal 'clean log ErrorCount matches' ([int64]$clean.ErrorCount) ([int64]$cleanLog.ErrorCount)
    Assert-True 'clean log never says actual freed' (-not ($cleanLog | ConvertTo-Json -Depth 8 | Select-String -Pattern '(?i)实际释放|actual freed' -Quiet)) ''
    $logNames = @($cleanLog.PSObject.Properties.Name)
    Assert-True 'clean log uses ProcessedBytes, not Released/Freed/SpaceSaved' (@($logNames | Where-Object { $_ -match '^(?i:Released|Freed|SpaceSaved|ActualReleased)$' }).Count -eq 0) ($logNames -join ',')

    # Logs are unique even for identical operations and same-second runs.
    $secondLog = New-SjcOperationLog -Context $context 'scan'
    $thirdLog = New-SjcOperationLog -Context $context 'scan'
    Assert-True 'new operation logs are unique' ($secondLog -ne $thirdLog -and $secondLog -ne $scan.LogPath) ($secondLog + ' | ' + $thirdLog)
    Assert-True 'new operation log starts in Running state' (((Get-Content -LiteralPath $secondLog -Raw -Encoding UTF8) | ConvertFrom-Json).Status -eq 'Running') ''
    Complete-SjcOperationLog -Result ([pscustomobject]@{ Status = 'Failed'; Error = 'synthetic'; LogPath = $secondLog })
    Assert-Equal 'completing a log overwrites Running with the real status' 'Failed' (((Get-Content -LiteralPath $secondLog -Raw -Encoding UTF8) | ConvertFrom-Json).Status)

    # A result whose LogPath cannot be written must be surfaced as Failed, not Success.
    $missingLogParent=Join-Path $sandbox.Root ('missing-log-parent-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $missingLogParent) { throw '人工不存在日志目录意外已存在。' }
    $result = [pscustomobject]@{ Status = 'Success'; Error = ''; LogPath = (Join-Path $missingLogParent 'log.json') }
    Complete-SjcOperationLog -Result $result
    Assert-Equal 'unwritable log downgrades the result to Failed' 'Failed' ([string]$result.Status)
    Assert-True 'unwritable log records a failure reason' (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) ([string]$result.Error)

    # A clean whose operation-log directory cannot be created must report Failed with an error.
    $noLogSandbox = New-OwnedSandbox
    $noLogContext = $noLogSandbox.Context
    $noLogFiles = Join-Path $noLogSandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($noLogFiles)
    New-TestFile -Path (Join-Path $noLogFiles 'no-log.tmp') -Bytes 8 -AgeHours 96 | Out-Null
    $noLogTask = New-SjcTaskDirectory -Context $noLogContext
    $scanNoLog = Invoke-SjcScan -Context $noLogContext -RuleIds @('SandboxOld') -TaskDirectory $noLogTask
    # Block the log directory by placing a file where the Logs directory must be.
    $logDir = Join-Path $noLogContext.StateRoot 'Logs'
    [void](Move-OwnedTestDirectoryToEvidence -Path $logDir)
    [IO.File]::WriteAllText($logDir, 'not-a-directory', $Utf8NoBom)
    $blocked = Invoke-SjcClean -Context $noLogContext -TaskDirectory $noLogTask -RecycleMode $false
    Assert-Equal 'clean without a creatable log is Failed' 'Failed' ([string]$blocked.Status) ([string]$blocked.Error)
    Assert-True 'clean without a log states the log problem' ([string]$blocked.Error -match '日志|Logs') ([string]$blocked.Error)
    Assert-Equal 'clean without a log deletes nothing' 0 ([int64]$blocked.Deleted)
    Assert-True 'candidate survives the failed clean' ([IO.File]::Exists((Join-Path $noLogFiles 'no-log.tmp'))) ''
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
