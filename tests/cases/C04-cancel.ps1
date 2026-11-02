#requires -Version 5.1
# C04: cancellation - a pre-created marker yields Cancelled with zero deletions; a real
# mid-run marker written by an external watcher after genuine partial deletion yields
# Cancelled with accurate partial results and surviving files.
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

    # --- preset cancel on scan ---
    New-TestFile -Path (Join-Path $files 'pre-scan.tmp') -Bytes 40 -AgeHours 96 | Out-Null
    $task = New-SjcTaskDirectory -Context $context
    $cancelScan = Join-Path $task 'cancel.flag'
    [IO.File]::WriteAllText($cancelScan, 'cancel', $Utf8NoBom)
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task -CancelPath $cancelScan
    Assert-Equal 'pre-cancelled scan reports Cancelled' 'Cancelled' $scan.Status $scan.Error
    Assert-Equal 'pre-cancelled scan produces no candidates' 0 ([int64]$scan.CandidateCount)
    Assert-True 'pre-cancelled scan still writes a log' ($scan.LogPath -and [IO.File]::Exists($scan.LogPath)) ([string]$scan.LogPath)

    # --- preset cancel on clean ---
    $task2 = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $files 'pre-clean-a.tmp') -Bytes 40 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'pre-clean-b.tmp') -Bytes 40 -AgeHours 96 | Out-Null
    $scan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task2
    Assert-Equal 'scan before preset clean succeeds' 'Success' $scan2.Status $scan2.Error
    $cancelClean = Join-Path $task2 'cancel.flag'
    [IO.File]::WriteAllText($cancelClean, 'cancel', $Utf8NoBom)
    $cleanPreset = Invoke-SjcClean -Context $context -TaskDirectory $task2 -CancelPath $cancelClean -RecycleMode $false
    Assert-Equal 'pre-cancelled clean reports Cancelled' 'Cancelled' $cleanPreset.Status $cleanPreset.Error
    Assert-Equal 'pre-cancelled clean deletes nothing' 0 ([int64]$cleanPreset.Deleted)
    Assert-True 'pre-cancelled clean leaves both files' ([IO.File]::Exists((Join-Path $files 'pre-clean-a.tmp')) -and [IO.File]::Exists((Join-Path $files 'pre-clean-b.tmp'))) ''
    Assert-True 'pre-cancelled clean still writes a log' ($cleanPreset.LogPath -and [IO.File]::Exists($cleanPreset.LogPath)) ([string]$cleanPreset.LogPath)

    # --- real mid-run cancel after genuine partial deletion ---
    $midSandbox = New-OwnedSandbox
    $midContext = $midSandbox.Context
    $midFiles = Join-Path $midSandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($midFiles)
    $total = 1400
    for ($i = 1; $i -le $total; $i++) {
        $path = Join-Path $midFiles ('bulk-' + $i.ToString('0000') + '.tmp')
        $fs = [IO.File]::Open($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $fs.WriteByte(65) } finally { $fs.Dispose() }
        [IO.File]::SetLastWriteTimeUtc($path, [datetime]::UtcNow.AddHours(-96))
    }
    $midTask = New-SjcTaskDirectory -Context $midContext
    $midScan = Invoke-SjcScan -Context $midContext -RuleIds @('SandboxOld') -TaskDirectory $midTask
    Assert-Equal 'mid-run scan seals 1400 candidates' 'Success|1400' ($midScan.Status + '|' + [int64]$midScan.CandidateCount) $midScan.Error

    $midCancel = Join-Path $midTask 'cancel.flag'
    $watcher = Start-CancelHelper -Mode RemainingCount -WatchPath $midFiles -CancelPath $midCancel -Threshold 1050 -TimeoutSeconds 120
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $cleanMid = Invoke-SjcClean -Context $midContext -TaskDirectory $midTask -CancelPath $midCancel -RecycleMode $false
    $sw.Stop()
    $helperWrote = Wait-CancelHelper -Helper $watcher -TimeoutSeconds 30
    [void](Save-Evidence 'mid-cancel' ([pscustomobject]@{ Result = $cleanMid; HelperWroteMarker = $helperWrote; ElapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); Total = $total; Remaining = @(Get-ChildItem -LiteralPath $midFiles -Filter '*.tmp').Count }))

    Assert-True 'external watcher actually wrote the cancel marker' $helperWrote ('marker=' + $midCancel)
    Assert-Equal 'mid-run clean reports Cancelled' 'Cancelled' $cleanMid.Status $cleanMid.Error
    Assert-True 'genuine partial deletion occurred before cancel (Deleted>=1)' ([int64]$cleanMid.Deleted -ge 1) ('deleted=' + $cleanMid.Deleted)
    Assert-True 'cancel happened before consuming the whole plan (Deleted<total)' ([int64]$cleanMid.Deleted -lt $total) ('deleted=' + $cleanMid.Deleted + '/' + $total)
    Assert-True 'Reviewed is between partial and full' ([int64]$cleanMid.Reviewed -ge [int64]$cleanMid.Deleted -and [int64]$cleanMid.Reviewed -lt $total) ('reviewed=' + $cleanMid.Reviewed + '/' + $total + '; deleted=' + $cleanMid.Deleted)
    $remaining = @(Get-ChildItem -LiteralPath $midFiles -Filter '*.tmp' -File)
    Assert-Equal 'remaining files equal total minus Deleted' ([int64]($total - [int64]$cleanMid.Deleted)) ([int64]$remaining.Count) ('remaining=' + $remaining.Count)
    Assert-True 'partial results are written to a log' ($cleanMid.LogPath -and [IO.File]::Exists($cleanMid.LogPath)) ([string]$cleanMid.LogPath)
    if ($cleanMid.LogPath -and [IO.File]::Exists($cleanMid.LogPath)) {
        $log = Get-Content -LiteralPath $cleanMid.LogPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Assert-Equal 'cancel log Status is Cancelled' 'Cancelled' ([string]$log.Status)
        Assert-Equal 'cancel log Deleted matches the partial result' ([int64]$cleanMid.Deleted) ([int64]$log.Deleted)
        Assert-True 'cancel log keeps the real partial counts' ([int64]$log.Reviewed -ge [int64]$log.Deleted) ('reviewed=' + $log.Reviewed + '; deleted=' + $log.Deleted)
    }
    Assert-True 'actual surviving files still contain the untouched candidates' (@($remaining | Where-Object { $_.Length -ne 1 }).Count -eq 0) ''

    # The cancelled clean still consumed the one-shot claim: no replay of the rest.
    $replay = Invoke-SjcClean -Context $midContext -TaskDirectory $midTask -RecycleMode $false
    Assert-True 'cancelled plan cannot be replayed' ($replay.Status -eq 'Failed' -and [int64]$replay.Deleted -eq 0) ('status=' + $replay.Status + '; deleted=' + $replay.Deleted)

    # A genuinely Cancelled scan (its own cancel channel, marker pre-created in that task)
    # produces a sealed plan that Clean must refuse.
    $cancelledScanTask = New-SjcTaskDirectory -Context $midContext
    $ownCancel = Join-Path $cancelledScanTask 'cancel.flag'
    [IO.File]::WriteAllText($ownCancel, 'cancel', $Utf8NoBom)
    $cancelledScan = Invoke-SjcScan -Context $midContext -RuleIds @('SandboxOld') -TaskDirectory $cancelledScanTask -CancelPath $ownCancel
    [void](Save-Evidence 'cancelled-scan' ([pscustomobject]@{ Task = $cancelledScanTask; Result = $cancelledScan }))
    Assert-Equal 'cancelled scan reports Cancelled' 'Cancelled' $cancelledScan.Status $cancelledScan.Error
    Assert-True 'cancelled scan still produces a sealed plan file' ([string]::IsNullOrWhiteSpace([string]$cancelledScan.PlanPath) -eq $false -and [IO.File]::Exists([string]$cancelledScan.PlanPath)) ([string]$cancelledScan.PlanPath)
    $cancelledScanClean = Invoke-SjcClean -Context $midContext -TaskDirectory $cancelledScanTask -RecycleMode $false
    Assert-True 'a Cancelled scan plan is refused by clean' ($cancelledScanClean.Status -eq 'Failed' -and [int64]$cancelledScanClean.Deleted -eq 0) ('scan=' + $cancelledScan.Status + '; clean=' + $cancelledScanClean.Status + '; deleted=' + $cancelledScanClean.Deleted + '; error=' + $cancelledScanClean.Error)
    Assert-True 'cancelled-plan refusal names the cancelled scan' ([string]$cancelledScanClean.Error -match '取消') ([string]$cancelledScanClean.Error)
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
