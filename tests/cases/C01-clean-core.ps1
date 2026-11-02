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
    Assert-Equal 'scan sees four candidates (read-only included)' 4 $candidates.Count
    $excludedCandidate = @($candidates | Where-Object { $_.Path -eq (Join-Path $files 'excluded.tmp') })[0]
    Assert-True 'excluded candidate exists in the plan' ($null -ne $excludedCandidate) ''

    $readOnlyBefore = Get-TestFileState $keepReadOnly
    Assert-True 'read-only fixture is actually read-only' $readOnlyBefore.ReadOnly ''

    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -ExcludedIds @($excludedCandidate.Id) -RecycleMode $false
    [void](Save-Evidence 'clean-result' $clean)

    # A read-only candidate is skipped and counted as an error, so the run is Partial.
    Assert-Equal 'clean status is Partial because the read-only candidate was skipped' 'Partial' $clean.Status $clean.Error
    Assert-Equal 'clean reports version 0.9.0' '0.9.0' ([string]$clean.Version)
    Assert-Equal 'clean TaskId equals task GUID' ([IO.Path]::GetFileName($task)) ([string]$clean.TaskId)
    Assert-Equal 'exactly two sealed files deleted' 2 ([int64]$clean.Deleted)
    Assert-Equal 'processed bytes are the sum of deleted logical lengths' 768 ([int64]$clean.ProcessedBytes)
    Assert-Equal 'reviewed equals all plan candidates' 4 ([int64]$clean.Reviewed)
    Assert-Equal 'skipped counts exclusion + read-only' 2 ([int64]$clean.Skipped)
    Assert-Equal 'one recorded skip error (read-only); exclusion is not an error' 1 ([int64]$clean.ErrorCount) ((@($clean.Errors) -join ' | '))

    Assert-True 'sealed normal files were removed' (-not [IO.File]::Exists((Join-Path $files 'delete-a.tmp')) -and -not [IO.File]::Exists((Join-Path $files 'delete-b.log'))) ''
    Assert-True 'excluded candidate was preserved' ([IO.File]::Exists((Join-Path $files 'excluded.tmp'))) ''
    Assert-True 'read-only candidate was preserved' ([IO.File]::Exists($keepReadOnly)) ''
    $readOnlyAfter = Get-TestFileState $keepReadOnly
    Assert-True 'read-only attribute was not modified' ($readOnlyAfter.ReadOnly -and $readOnlyAfter.Attributes -eq $readOnlyBefore.Attributes) ($readOnlyBefore.Attributes + ' -> ' + $readOnlyAfter.Attributes)
    Assert-True 'non-candidate file untouched' ([IO.File]::Exists((Join-Path $files 'untouched.txt'))) ''
    Assert-True 'read-only failure is recorded in Errors' (@($clean.Errors) -join ' ' -match '只读') (@($clean.Errors) -join ' | ')

    Assert-True 'clean writes a unique operation log' ($clean.LogPath -and [IO.File]::Exists($clean.LogPath)) ([string]$clean.LogPath)
    Assert-True 'clean log filename is operation+guid shaped' (([IO.Path]::GetFileName([string]$clean.LogPath)) -match '^clean-[0-9a-f-]{36}\.json$') ([IO.Path]::GetFileName([string]$clean.LogPath))
    $logObj = Get-Content -LiteralPath $clean.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'log status mirrors the Partial result' 'Partial' ([string]$logObj.Status)
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
