#requires -Version 5.1
# C01: clean core - permanent clean only removes sealed candidates, excluded ids are
# preserved, read-only files are skipped without attribute changes, plan is single-use,
# and the log records logical processed bytes (never "actual freed").
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

    $keepReadOnly = Join-Path $files 'keep-readonly.tmp'
    New-TestFile -Path $keepReadOnly -Bytes 64 -AgeHours 96 -ReadOnly | Out-Null
    New-TestFile -Path (Join-Path $files 'excluded.tmp') -Bytes 128 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'delete-a.tmp') -Bytes 256 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'delete-b.log') -Bytes 512 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'untouched.txt') -Bytes 32 -AgeHours 96 | Out-Null

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task
    Assert-Equal 'scan succeeds' 'Success' $scan.Status $scan.Error
    $candidates = @(Get-CandidateLines $scan.PlanPath)
    # v0.12 contract: a read-only file is never a candidate. It is excluded by the same
    # read-only gate during scanning, so the plan (and the preview the user approves)
    # never contains files the cleaner would have to skip.
    $readOnlyBefore = Get-TestFileState $keepReadOnly
    Assert-True 'read-only fixture is actually read-only' $readOnlyBefore.ReadOnly ''
    Assert-Equal 'scan sees three candidates and pre-excludes the read-only file' 3 $candidates.Count
    Assert-True 'read-only file is absent from the sealed plan' (@($candidates | Where-Object { $_.Path -eq $keepReadOnly }).Count -eq 0) (($candidates | ForEach-Object Path) -join '; ')
    $readOnlyAfterScan = Get-TestFileState $keepReadOnly
    Assert-True 'scanning does not change the read-only attribute' ($readOnlyAfterScan.ReadOnly -and $readOnlyAfterScan.Attributes -eq $readOnlyBefore.Attributes) ($readOnlyBefore.Attributes + ' -> ' + $readOnlyAfterScan.Attributes)
    Assert-Equal 'scanning does not change the read-only file timestamp/length' ($readOnlyBefore.LastWriteUtc + '|' + $readOnlyBefore.Length) ($readOnlyAfterScan.LastWriteUtc + '|' + $readOnlyAfterScan.Length)
    $excludedCandidate = @($candidates | Where-Object { $_.Path -eq (Join-Path $files 'excluded.tmp') })[0]
    Assert-True 'excluded candidate exists in the plan' ($null -ne $excludedCandidate) ''

    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -ExcludedIds @($excludedCandidate.Id) -RecycleMode $false
    [void](Save-Evidence 'clean-result' $clean)

    # Every plan candidate can be processed: the only skip is the explicit exclusion.
    Assert-Equal 'clean status is Success because the read-only file never became a candidate' 'Success' $clean.Status $clean.Error
    # Version is owned by version.json; the case asserts the product single source, not a frozen literal.
    Assert-Equal 'clean reports the version.json product version' (Get-SjcVersion) ([string]$clean.Version)
    Assert-Equal 'clean TaskId equals task GUID' ([IO.Path]::GetFileName($task)) ([string]$clean.TaskId)
    Assert-Equal 'exactly two sealed files deleted' 2 ([int64]$clean.Deleted)
    Assert-Equal 'processed bytes are the sum of deleted logical lengths' 768 ([int64]$clean.ProcessedBytes)
    Assert-Equal 'reviewed equals all plan candidates' 3 ([int64]$clean.Reviewed)
    Assert-Equal 'skipped counts only the explicit exclusion' 1 ([int64]$clean.Skipped)
    Assert-Equal 'no errors are recorded when the read-only file was pre-excluded' 0 ([int64]$clean.ErrorCount) ((@($clean.Errors) -join ' | '))

    Assert-True 'sealed normal files were removed' (-not [IO.File]::Exists((Join-Path $files 'delete-a.tmp')) -and -not [IO.File]::Exists((Join-Path $files 'delete-b.log'))) ''
    Assert-True 'excluded candidate was preserved' ([IO.File]::Exists((Join-Path $files 'excluded.tmp'))) ''
    Assert-True 'read-only candidate was preserved' ([IO.File]::Exists($keepReadOnly)) ''
    $readOnlyAfter = Get-TestFileState $keepReadOnly
    Assert-True 'read-only attribute was not modified' ($readOnlyAfter.ReadOnly -and $readOnlyAfter.Attributes -eq $readOnlyBefore.Attributes) ($readOnlyBefore.Attributes + ' -> ' + $readOnlyAfter.Attributes)
    Assert-True 'non-candidate file untouched' ([IO.File]::Exists((Join-Path $files 'untouched.txt'))) ''
    Assert-Equal 'no read-only error text exists in a pre-excluded scan' 0 (@($clean.Errors | Where-Object { $_ -match '只读' }).Count) (@($clean.Errors) -join ' | ')

    Assert-True 'clean writes a unique operation log' ($clean.LogPath -and [IO.File]::Exists($clean.LogPath)) ([string]$clean.LogPath)
    Assert-True 'clean log filename is operation+guid shaped' (([IO.Path]::GetFileName([string]$clean.LogPath)) -match '^clean-[0-9a-f-]{36}\.json$') ([IO.Path]::GetFileName([string]$clean.LogPath))
    $logObj = Get-Content -LiteralPath $clean.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'log status mirrors the Success result' 'Success' ([string]$logObj.Status)
    Assert-Equal 'log Deleted mirrors the result' 2 ([int64]$logObj.Deleted)
    Assert-Equal 'log uses ProcessedBytes naming, not Released' 0 (@($logObj.PSObject.Properties.Name | Where-Object { $_ -match '(?i)released|freed|actual' }).Count) (@($logObj.PSObject.Properties.Name) -join ',')
    Assert-True 'log never claims actual freed space' (-not ((Get-Content -LiteralPath $clean.LogPath -Raw -Encoding UTF8) -match '(?i)实际释放|actual freed|actually freed')) ''

    $claim = Join-Path $task 'clean.claimed'
    Assert-True 'single-use claim marker persisted' ([IO.File]::Exists($claim)) $claim

    $again = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    Assert-True 'replaying the same plan is refused' ($again.Status -eq 'Failed' -and [int64]$again.Deleted -eq 0) ('status=' + $again.Status + '; deleted=' + $again.Deleted)

    # Unknown exclusion ids are rejected before any deletion.
    $task2 = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $files 'second-a.tmp') -Bytes 40 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'second-b.tmp') -Bytes 40 -AgeHours 96 | Out-Null
    $scan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task2
    $badExclude = Invoke-SjcClean -Context $context -TaskDirectory $task2 -ExcludedIds @('ffffffffffffffffffffffffffffffff') -RecycleMode $false
    Assert-True 'unknown exclusion id fails the clean before deleting' ($badExclude.Status -eq 'Failed' -and [int64]$badExclude.Deleted -eq 0) ('status=' + $badExclude.Status + '; error=' + $badExclude.Error)
    Assert-True 'all candidates survive the rejected clean' ([IO.File]::Exists((Join-Path $files 'second-a.tmp')) -and [IO.File]::Exists((Join-Path $files 'second-b.tmp'))) ''

    $dup = Invoke-SjcClean -Context $context -TaskDirectory $task2 -ExcludedIds @($excludedCandidate.Id, $excludedCandidate.Id) -RecycleMode $false
    Assert-True 'duplicate exclusion ids fail the clean' ($dup.Status -eq 'Failed') ('status=' + $dup.Status + '; error=' + $dup.Error)

    # v0.12: read-only protection is still enforced at clean time, not only at scan time.
    # A file that becomes read-only AFTER the scan is sealed as a candidate and must be
    # refused per-file, producing Partial with one recorded error and no deletion.
    $lateSandbox = New-OwnedSandbox
    $lateContext = $lateSandbox.Context
    $lateDir = Join-Path $lateSandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($lateDir)
    $lateTask = New-SjcTaskDirectory -Context $lateContext
    $lateFile = Join-Path $lateDir 'late-readonly.tmp'
    $lateNormal = Join-Path $lateDir 'late-normal.tmp'
    New-TestFile -Path $lateFile -Bytes 24 -AgeHours 96 | Out-Null
    New-TestFile -Path $lateNormal -Bytes 40 -AgeHours 96 | Out-Null
    $lateScan = Invoke-SjcScan -Context $lateContext -RuleIds @('SandboxOld') -TaskDirectory $lateTask
    Assert-Equal 'post-scan fixture scan succeeds' 'Success' $lateScan.Status $lateScan.Error
    $lateCandidates = @(Get-CandidateLines $lateScan.PlanPath)
    Assert-Equal 'both writable fixtures are sealed as candidates' 2 $lateCandidates.Count (($lateCandidates | ForEach-Object { [IO.Path]::GetFileName($_.Path) }) -join ',')
    $lateBefore = Get-TestFileState $lateFile
    [IO.File]::SetAttributes($lateFile, [IO.FileAttributes]::ReadOnly)
    $lateAfterScan = Get-TestFileState $lateFile
    Assert-True 'fixture became read-only after the scan' (-not $lateBefore.ReadOnly -and $lateAfterScan.ReadOnly) ($lateBefore.Attributes + ' -> ' + $lateAfterScan.Attributes)
    $lateClean = Invoke-SjcClean -Context $lateContext -TaskDirectory $lateTask -RecycleMode $false
    [void](Save-Evidence 'late-readonly-clean' $lateClean)
    Assert-Equal 'clean reports Partial when a sealed candidate became read-only' 'Partial' $lateClean.Status $lateClean.Error
    Assert-Equal 'the writable sealed candidate is still deleted' 1 ([int64]$lateClean.Deleted) ([string]$lateClean.Deleted)
    Assert-Equal 'the read-only candidate is skipped and counted once' 1 ([int64]$lateClean.Skipped) ([string]$lateClean.Skipped)
    Assert-Equal 'exactly one read-only error is recorded' 1 ([int64]$lateClean.ErrorCount) ((@($lateClean.Errors) -join ' | '))
    Assert-True 'the recorded error is attributed to the exact read-only candidate' ((@($lateClean.Errors) -join ' ') -and (@($lateClean.Errors) -join ' ').StartsWith($lateFile + ':', [StringComparison]::OrdinalIgnoreCase)) (@($lateClean.Errors) -join ' | ')
    Add-Limitation 'C01 后置只读重验的记录文本为通用再校验消息（“文件不存在、模式或保留年龄不符合规则”）；Invoke-SjcClean 的专门“只读文件保留”分支被 Test-SjcRuleFile 的只读判定先命中，故只读文本未单独出现。保护行为与计数已断言，文本措辞未计入通过。'
    Assert-True 'the read-only candidate file survives' ([IO.File]::Exists($lateFile)) ''
    $lateAfterClean = Get-TestFileState $lateFile
    Assert-True 'clean did not clear the read-only attribute to force deletion' ($lateAfterClean.ReadOnly -and $lateAfterClean.Attributes -eq $lateAfterScan.Attributes) ($lateAfterScan.Attributes + ' -> ' + $lateAfterClean.Attributes)
    Assert-True 'the writable candidate is gone' (-not [IO.File]::Exists($lateNormal)) ''
    $lateLog = Get-Content -LiteralPath $lateClean.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'log status mirrors the Partial result' 'Partial' ([string]$lateLog.Status)
    Assert-Equal 'log records the single skip' 1 ([int64]$lateLog.Skipped)
    Assert-Equal 'log records the read-only error count' 1 ([int64]$lateLog.ErrorCount)

    # Recycle mode on the test context is exercised only through a real sandbox file,
    # never a production path. The file must leave the sandbox (moved to the bin).
    $thirdTask = New-SjcTaskDirectory -Context $context
    $recycleFile = Join-Path $files 'recycle-me.tmp'
    New-TestFile -Path $recycleFile -Bytes 16 -AgeHours 96 | Out-Null
    $scan3 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $thirdTask
    $recycleClean = Invoke-SjcClean -Context $context -TaskDirectory $thirdTask -RecycleMode $true
    Assert-True 'recycle-mode clean moves the owned sandbox file out of place' ([int64]$recycleClean.Deleted -ge 1 -and $recycleClean.Status -ne 'Failed') ('status=' + $recycleClean.Status + '; deleted=' + $recycleClean.Deleted + '; error=' + $recycleClean.Error)
    Assert-True 'recycle-mode file is no longer at its path' (-not [IO.File]::Exists($recycleFile)) ''
    Add-DeclaredExclusion '回收站清空（Invoke-SjcRecycle/SHEmptyRecycleBin）未执行；仅对自有沙箱文件做过移到回收站的单文件操作，未清空用户回收站。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
