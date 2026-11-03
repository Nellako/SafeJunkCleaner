#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$RepoRoot,[string]$EngineRoot='', [ValidateSet(1000,10000)][int]$FileCount=1000,[ValidateRange(1,5)][int]$Rounds=3,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[string]$Label='current')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $EngineRoot){$EngineRoot=$RepoRoot}
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId 'IndependentBenchmark' -ResultPath (Join-Path $EvidenceDirectory 'harness.json') -EvidenceDirectory $EvidenceDirectory
Remove-Variable SjcEmbeddedVersion -Scope Script -ErrorAction SilentlyContinue
$sourceEvidence=@(Get-ChildItem -LiteralPath (Join-Path $EngineRoot 'src') -Filter '*.ps1' -File | ForEach-Object{[pscustomobject]@{Name=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$sourceEvidence += [pscustomobject]@{Name='version.json';SHA256=(Get-FileHash -LiteralPath (Join-Path $EngineRoot 'version.json') -Algorithm SHA256).Hash}
foreach($module in @('Version','Rules','Core','Worker')){. (Join-Path $EngineRoot ('src\'+$module+'.ps1'))}
$rows=New-Object 'System.Collections.Generic.List[object]'
for($round=1;$round -le $Rounds;$round++){
    $sandbox=New-OwnedSandbox;$context=$sandbox.Context;$files=Join-Path $sandbox.Root 'files'
    for($i=0;$i -lt $FileCount;$i++){[void](New-TestFile -Path (Join-Path $files ('owned-{0:D6}.tmp' -f $i)) -Bytes 128 -AgeHours 120)}
    $task=New-SjcTaskDirectory $context;$watch=[Diagnostics.Stopwatch]::StartNew()
    $scan=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @('SandboxOld','SandboxLog');$scanMs=$watch.Elapsed.TotalMilliseconds
    if($scan.Status -ne 'Success' -or $scan.CandidateCount -ne $FileCount){throw ('Scan mismatch: '+$scan.Error)}
    $session=$null
    try{
        $watch.Restart();$session=Open-SjcPreviewSession $scan.PlanPath;$openMs=$watch.Elapsed.TotalMilliseconds
        $watch.Restart();$page=@(Get-SjcPreviewPage $session -Offset 0 -Limit 200);$firstMs=$watch.Elapsed.TotalMilliseconds
        if($page.Count -ne 200){throw 'First preview mismatch.'}
        $pages=New-Object 'System.Collections.Generic.List[double]'
        foreach($offset in @([int]($FileCount/2),($FileCount-200),0)){$watch.Restart();$page=@(Get-SjcPreviewPage $session -Offset $offset -Limit 200);[void]$pages.Add($watch.Elapsed.TotalMilliseconds);if($page.Count -ne 200){throw 'Continuous preview mismatch.'}}
    }finally{if($session){Close-SjcPreviewSession $session}}
    $watch.Restart();$export=Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'owned-export.csv');$exportMs=$watch.Elapsed.TotalMilliseconds
    if($export.ExportedCount -ne $FileCount){throw 'Export mismatch.'}
    Assert-SjcSandbox $sandbox.Root
    $watch.Restart();$clean=Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false;$cleanMs=$watch.Elapsed.TotalMilliseconds
    if($clean.Status -ne 'Success' -or $clean.Deleted -ne $FileCount){throw ('Owned cleanup mismatch: '+$clean.Error)}
    $process=[Diagnostics.Process]::GetCurrentProcess();$process.Refresh()
    [void]$rows.Add([pscustomobject]@{Round=$round;Files=$FileCount;ScanMs=$scanMs;PreviewOpenMs=$openMs;FirstPageMs=$firstMs;ContinuousPageMs=$pages.ToArray();ExportMs=$exportMs;RevalidateAndDeleteMs=$cleanMs;WorkingSetBytes=$process.WorkingSet64;PeakWorkingSetBytes=$process.PeakWorkingSet64;SandboxRoot=$sandbox.Root})
    $process.Dispose()
    $result=[ordered]@{Label=$Label;PowerShell=$PSVersionTable.PSVersion.ToString();Utc=[datetime]::UtcNow.ToString('o');Rows=$rows.ToArray();Sources=$sourceEvidence;Limitations=@('Only process-owned GUID sandbox synthetic files deleted; evidence retained.','128-byte flat files; two same-root rules; no production cache or recycle-bin operation.','Repeated rounds share warm OS caches; not cold-start or whole-device throughput.','Memory is process working set including interpreter/setup, not engine-only allocation.','Preview paging is reported separately, never substituted for end-to-end speed.')}
    $output=Join-Path $EvidenceDirectory ($Label+'-'+$FileCount+'.json')
    [IO.File]::WriteAllText($output,($result|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
    Write-Output ('ROUND '+$round+' '+$FileCount+' '+$Label+' scan='+[math]::Round($scanMs)+' clean='+[math]::Round($cleanMs))
}
