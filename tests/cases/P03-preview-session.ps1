#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$session=$null
try {
    $sandbox=New-OwnedSandbox
    for($i=0;$i -lt 450;$i++) { New-TestFile -Path (Join-Path $sandbox.Root ('files\p{0:D4}.tmp' -f $i)) -Bytes 10 -AgeHours 100 | Out-Null }
    $task=New-SjcTaskDirectory $sandbox.Context
    $scan=Invoke-SjcScan -Context $sandbox.Context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'scan succeeds' 'Success' $scan.Status $scan.Error
    $session=Open-SjcPreviewSession $scan.PlanPath
    Assert-Equal 'full session count' 450 $session.Count
    $page1=@(Get-SjcPreviewPage $session -Offset 0 -Limit 200)
    $page2=@(Get-SjcPreviewPage $session -Offset 200 -Limit 200)
    $last=@(Get-SjcPreviewPage $session -Offset 400 -Limit 200)
    Assert-Equal 'first page' 200 $page1.Count
    Assert-Equal 'second page' 200 $page2.Count
    Assert-Equal 'last page' 50 $last.Count
    Assert-Equal 'unique items across pages' 450 (@(@($page1)+@($page2)+@($last) | Select-Object -ExpandProperty Id -Unique).Count)
    Assert-Equal 'rule index complete' 450 (@(Get-SjcPreviewRuleCandidates $session 'SandboxOld').Count)
    $cancelSource=[Threading.CancellationTokenSource]::new();$cancelSource.Cancel()
    $cancelledExport=Join-Path $sandbox.Root 'cancelled-export.csv'
    Assert-Throws 'cancelled export fails before publishing output' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination $cancelledExport -CancellationToken $cancelSource.Token } ''
    Assert-True 'cancelled export leaves no partial file' (-not [IO.File]::Exists($cancelledExport))
    Assert-Throws 'cancelled session creation rejects' { Open-SjcPreviewSession -PlanPath $scan.PlanPath -CancellationToken $cancelSource.Token } ''
    $cancelSource.Dispose()
    Assert-Throws 'locked plan cannot be appended' { [IO.File]::AppendAllText($scan.PlanPath,'tampered') } ''
    Register-OwnedTestFile -Path $scan.PlanPath
    Assert-Throws 'locked plan cannot be replaced' { Move-OwnedTestFileToEvidence -Path $scan.PlanPath } ''
    $clean=Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -ExcludedIds @($page1[0].Id) -RecycleMode $false
    Assert-Equal 'clean independently revalidates while read lock held' 'Success' $clean.Status $clean.Error
    Assert-Equal 'clean deletes only approved nonexcluded' 449 $clean.Deleted
    Assert-True 'kept target survives' ([IO.File]::Exists($page1[0].Path))
    Close-SjcPreviewSession $session
    Assert-Throws 'closed session rejected' { Get-SjcPreviewPage $session } '会话'
    Close-SjcPreviewSession $session
    [IO.File]::AppendAllText($scan.PlanPath,'tampered')
    Assert-Throws 'reopen revalidates integrity' { Open-SjcPreviewSession $scan.PlanPath } '完整性'
    foreach($name in @('worker.active','core.active','task.completed','task.deleting','clean.claimed')) { Assert-Throws ('reserved channel '+$name) { Assert-SjcChannel $task (Join-Path $task $name) } '保留' }
    $idle=New-SjcTaskDirectory $sandbox.Context
    [IO.File]::WriteAllText((Join-Path $idle 'task.deleting'),'')
    Assert-Throws 'tombstone prevents worker lease' { Open-SjcTaskLease $idle 'worker.active' } '移除'
} catch { Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace }
finally { if($session -and -not $session.Closed){Close-SjcPreviewSession $session} }
Complete-TestCase
