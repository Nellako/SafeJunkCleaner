#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
$app=$null
function Wait-PreviewJob {
    param($App)
    $limit=[datetime]::UtcNow.AddSeconds(30)
    while($App.State.Busy -and [datetime]::UtcNow -lt $limit){Invoke-SjcGuiTick $App;Start-Sleep -Milliseconds 10}
    if($App.State.Busy){throw 'Background preview timeout.'}
}
try {
    $sandbox=New-OwnedSandbox;$context=$sandbox.Context
    for($i=0;$i -lt 450;$i++){New-TestFile -Path (Join-Path $sandbox.Root ('files\gui-{0:D4}.tmp' -f $i)) -Bytes 12 -AgeHours 100|Out-Null}
    $task=New-SjcTaskDirectory $context;$scan=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @('SandboxOld')
    $state=New-SjcGuiState $context -TestMode;$state.Scan=$scan;$state.Stale=$false;$state.TaskDirectory=$task
    $app=New-SjcGuiApp $state
    $clock=[Diagnostics.Stopwatch]::StartNew();Start-SjcGuiLocalJob $app 'Open' @{PlanPath=$scan.PlanPath};$launchMs=$clock.Elapsed.TotalMilliseconds
    Assert-True 'opening schedules async work' ($null -ne $state.LocalJob -and $state.Busy)
    Assert-True 'scan and mode frozen during preview' (-not $app.Ui.ScanButton.IsEnabled -and -not $app.Ui.RecycleMode.IsEnabled)
    Set-SjcGuiPage $app 'Files';Assert-Equal 'navigation works while busy' 'Files' $state.Page
    Wait-PreviewJob $app
    Assert-Equal 'background opens full first page' 200 $state.PageItems.Count $state.Status
    Start-SjcGuiLocalJob $app 'Page' @{Offset=400};Wait-PreviewJob $app
    Assert-Equal 'background reaches final page' 50 $state.PageItems.Count $state.Status
    Assert-Equal 'page offset matches' 400 $state.PageOffset
    $app.Ui.CandidatesList.Items[0].IsSelected=$true
    Invoke-SjcGuiCommand $app 'KeepButton'
    Assert-Equal 'UI keep changes exclusion only' 1 $state.Excluded.Count
    Invoke-SjcGuiCommand $app 'RestoreButton'
    Assert-Equal 'UI restore removes exclusion' 0 $state.Excluded.Count
    Start-SjcGuiLocalJob $app 'RuleKeep' @{RuleId='SandboxOld';Keep=$true};Wait-PreviewJob $app
    Assert-Equal 'rule index keeps all candidates' 450 $state.Excluded.Count
    Start-SjcGuiLocalJob $app 'RuleKeep' @{RuleId='SandboxOld';Keep=$false};Wait-PreviewJob $app
    Assert-Equal 'rule index restores all candidates' 0 $state.Excluded.Count
    $export=Join-Path $sandbox.Root 'gui-export.csv'
    Start-SjcGuiLocalJob $app 'Export' @{PlanPath=$scan.PlanPath;Destination=$export;ExcludedIds=[string[]]@()};Wait-PreviewJob $app
    Assert-True 'async export writes complete output' ([IO.File]::Exists($export) -and @(Import-Csv -LiteralPath $export).Count -eq 450)
    Start-SjcGuiLocalJob $app 'Export' @{PlanPath=$scan.PlanPath;Destination=$export;ExcludedIds=[string[]]@()};Wait-PreviewJob $app
    Assert-True 'failed export restores controls' (-not $state.Busy -and $app.Ui.ScanButton.IsEnabled -and $state.Status -match '失败') $state.Status
    Start-SjcGuiLocalJob $app 'Open' @{PlanPath=$scan.PlanPath};Request-SjcGuiCancel $app;Wait-PreviewJob $app
    Assert-True 'cancelled local operation restores controls' (-not $state.Busy -and $app.Ui.ScanButton.IsEnabled -and $state.Status -match '取消') $state.Status
    Assert-Throws 'test mode cannot launch production worker' {Start-SjcGuiTask $app 'Clean'} '不允许'
    $state.Task=@{Action='Clean';TaskDirectory=$task}
    Complete-SjcGuiTask $app ([pscustomobject]@{Status='Unknown';Error='synthetic forced-stop result';LogPath=''})
    Assert-True 'forced-stop unknown is not zero' ($state.History[0].Summary -match '未知' -and $state.History[0].Summary -notmatch '0.00') $state.History[0].Summary
    Assert-True 'completed clean invalidates plan' $state.Stale
    Save-Evidence 'background' ([pscustomobject]@{LaunchMilliseconds=$launchMs;CandidateCount=$scan.CandidateCount;FinalStatus=$state.Status})|Out-Null
    Assert-Equal 'GUI did not delete synthetic targets' 450 ([IO.Directory]::GetFiles((Join-Path $sandbox.Root 'files')).Count)
} catch {Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
finally{if($app){Remove-SjcGuiApp $app;$app.Ui.Window.Close()}}
Complete-TestCase
