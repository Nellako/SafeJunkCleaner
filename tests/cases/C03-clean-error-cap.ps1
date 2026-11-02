#requires -Version 5.1
# C03: error cap - every skipped file is counted, at most 200 error records are stored,
# the log/summary stays accurate, and useful partial results survive.
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

    $total = 250
    for ($i = 1; $i -le $total; $i++) {
        New-TestFile -Path (Join-Path $files ('cap-' + $i.ToString('000') + '.tmp')) -Bytes (10 + $i) -AgeHours 96 | Out-Null
    }
    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'scan seals 250 candidates' 'Success|250' ($scan.Status + '|' + [int64]$scan.CandidateCount) $scan.Error

    # All candidates change after sealing -> every one is skipped with an error.
    $stamp = [datetime]::UtcNow.AddHours(-2)
    for ($i = 1; $i -le $total; $i++) { [IO.File]::SetLastWriteTimeUtc((Join-Path $files ('cap-' + $i.ToString('000') + '.tmp')), $stamp) }

    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    [void](Save-Evidence 'cap-clean' $clean)
    Assert-Equal 'clean is Partial after 250 skips' 'Partial' $clean.Status $clean.Error
    Assert-Equal 'nothing was deleted' 0 ([int64]$clean.Deleted)
    Assert-Equal 'Skipped counts all 250 failures' 250 ([int64]$clean.Skipped) ([string]$clean.Skipped)
    Assert-Equal 'ErrorCount is the true total 250' 250 ([int64]$clean.ErrorCount) ([string]$clean.ErrorCount)
    Assert-Equal 'stored Errors are capped at 200' 200 (@($clean.Errors).Count) ([string]$clean.Errors.Count)
    Assert-True 'all 250 files still exist' (@(1..$total | Where-Object { -not [IO.File]::Exists((Join-Path $files ('cap-' + $_.ToString('000') + '.tmp'))) }).Count -eq 0) ''

    Assert-True 'log exists' ($clean.LogPath -and [IO.File]::Exists($clean.LogPath)) ([string]$clean.LogPath)
    $log = Get-Content -LiteralPath $clean.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'log keeps the accurate ErrorCount 250' 250 ([int64]$log.ErrorCount)
    Assert-Equal 'log stores at most 200 error records' 200 (@($log.Errors).Count)
    Assert-Equal 'log Skipped equals 250' 250 ([int64]$log.Skipped)
    Assert-Equal 'log Status is Partial' 'Partial' ([string]$log.Status)

    # A fresh scan still works after the capped run (state not poisoned), and a clean
    # with no changed files is Success.
    $task2 = New-SjcTaskDirectory -Context $context
    for ($i = 1; $i -le 5; $i++) { New-TestFile -Path (Join-Path $files ('ok-' + $i + '.tmp')) -Bytes 20 -AgeHours 96 | Out-Null }
    # Age them past the rule again but leave timestamps different from the previous scan,
    # so the new scan seals all 255 and only the 5 fresh fixtures match afterwards.
    $stamp2 = [datetime]::UtcNow.AddHours(-30)
    for ($i = 1; $i -le $total; $i++) { [IO.File]::SetLastWriteTimeUtc((Join-Path $files ('cap-' + $i.ToString('000') + '.tmp')), $stamp2) }
    $scan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task2
    Assert-Equal 'fresh scan after capped run sees 255 candidates' 255 ([int64]$scan2.CandidateCount) $scan2.Error
    # Change only the 250 cap files after sealing: the 5 ok fixtures stay valid.
    $stamp3 = [datetime]::UtcNow.AddHours(-28)
    for ($i = 1; $i -le $total; $i++) { [IO.File]::SetLastWriteTimeUtc((Join-Path $files ('cap-' + $i.ToString('000') + '.tmp')), $stamp3) }
    $clean2 = Invoke-SjcClean -Context $context -TaskDirectory $task2 -RecycleMode $false
    Assert-Equal 'second clean is Partial (250 changed + 5 ok)' 'Partial|5|250' ($clean2.Status + '|' + [int64]$clean2.Deleted + '|' + [int64]$clean2.ErrorCount) $clean2.Error
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
