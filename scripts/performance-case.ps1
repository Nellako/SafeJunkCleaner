#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [ValidateRange(10,10000)][int]$FileCount=1000,
    [string]$Label='current'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($name in @('Version.ps1','Rules.ps1','Core.ps1')){. (Join-Path $SourceDirectory $name)}
if([IO.File]::Exists($OutputPath)){throw 'Benchmark output must be a new file.'}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($OutputPath)))
$sandbox=New-SjcTestSandbox;$context=$sandbox.Context;$task=New-SjcTaskDirectory $context
$files=Join-Path $sandbox.Root 'files'
for($i=0;$i -lt $FileCount;$i++){
    $path=Join-Path $files ('synthetic-{0:D6}.tmp' -f $i)
    [IO.File]::WriteAllBytes($path,(New-Object byte[] 128))
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddDays(-5))
}
$watch=[Diagnostics.Stopwatch]::StartNew()
$scan=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @('SandboxOld','SandboxLog')
$scanMs=$watch.Elapsed.TotalMilliseconds
if($scan.Status -ne 'Success' -or $scan.CandidateCount -ne $FileCount){throw ('Scan failed: '+$scan.Error)}
$watch.Restart();$last=@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset ($FileCount-200) -Limit 200);$compatPageMs=$watch.Elapsed.TotalMilliseconds
if($last.Count -ne 200){throw 'Last-page count mismatch.'}
$pageTimes=New-Object 'System.Collections.Generic.List[double]';$ruleMs=$null;$openMs=$null;$session=$null
try{
    if(Get-Command Open-SjcPreviewSession -ErrorAction SilentlyContinue){
        $watch.Restart();$session=Open-SjcPreviewSession $scan.PlanPath;$openMs=$watch.Elapsed.TotalMilliseconds
        foreach($offset in @(0,[math]::Max(0,[int]($FileCount/2)-100),($FileCount-200))){$watch.Restart();$page=@(Get-SjcPreviewPage $session -Offset $offset -Limit 200);[void]$pageTimes.Add($watch.Elapsed.TotalMilliseconds);if($page.Count -ne 200){throw 'Indexed page count mismatch.'}}
        $watch.Restart();$ruleItems=@(Get-SjcPreviewRuleCandidates $session 'SandboxOld');$ruleMs=$watch.Elapsed.TotalMilliseconds
    }else{
        foreach($offset in @(0,[math]::Max(0,[int]($FileCount/2)-100),($FileCount-200))){$watch.Restart();$page=@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset $offset -Limit 200);[void]$pageTimes.Add($watch.Elapsed.TotalMilliseconds);if($page.Count -ne 200){throw 'Baseline page count mismatch.'}}
        $watch.Restart();$ruleItems=New-Object 'System.Collections.Generic.List[object]'
        for($offset=0;$offset -lt $FileCount;$offset+=1000){foreach($item in @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset $offset -Limit 1000)){if($item.RuleId -eq 'SandboxOld'){[void]$ruleItems.Add($item)}}}
        $ruleMs=$watch.Elapsed.TotalMilliseconds
    }
    if($ruleItems.Count -ne $FileCount){throw 'Rule selection count mismatch.'}
}finally{if($session){Close-SjcPreviewSession $session}}
$watch.Restart();$export=Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'synthetic.csv');$exportMs=$watch.Elapsed.TotalMilliseconds
if($export.ExportedCount -ne $FileCount){throw 'Full export count mismatch.'}
$probeRule=[pscustomobject]@{RequiresClosedProcess=@('SjcNonexistentProcessForBenchmark')}
$watch.Restart();for($i=0;$i -lt 100;$i++){if(-not (Test-SjcProcessesClosed $probeRule)){throw 'Unexpected benchmark process.'}};$processProbeMs=$watch.Elapsed.TotalMilliseconds
$watch.Restart();$clean=Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false;$cleanMs=$watch.Elapsed.TotalMilliseconds
if($clean.Status -ne 'Success' -or $clean.Deleted -ne $FileCount -or [IO.Directory]::GetFiles($files).Length -ne 0){throw ('Synthetic clean mismatch: '+$clean.Error)}
$process=[Diagnostics.Process]::GetCurrentProcess();$process.Refresh()
$result=[ordered]@{Status='Success';Label=$Label;Utc=[datetime]::UtcNow.ToString('o');PowerShell=$PSVersionTable.PSVersion.ToString();FileCount=$FileCount;BytesPerFile=128;ScanMs=$scanMs;CompatibilityLastPageMs=$compatPageMs;PreviewOpenMs=$openMs;PageMs=$pageTimes.ToArray();RuleSelectionMs=$ruleMs;ExportMs=$exportMs;ProcessProbe100Ms=$processProbeMs;CleanMs=$cleanMs;ProcessPeakWorkingSetBytes=$process.PeakWorkingSet64;SandboxRoot=$sandbox.Root;Sources=@(Get-ChildItem -LiteralPath $SourceDirectory -File -Filter '*.ps1'|ForEach-Object{[pscustomobject]@{Name=$_.Name;SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}});Limitations=@('Synthetic flat local directory; no production cache scan or real recycle-bin operation.','First and subsequent reads share a warm filesystem cache; not cold-start or whole-disk results.','Peak working set includes interpreter and setup, not an isolated engine delta.','Each process permanently deletes only its own GUID synthetic files; metadata retained.','Baseline rule selection repeatedly reads 1000-item pages as old GUI did; optimized selection uses read-only session index.','No assertion of fixed performance on other disks or third-party application layouts.')}
[IO.File]::WriteAllText($OutputPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
Write-Output ('PERF '+$Label+' files='+$FileCount+' output='+$OutputPath)
