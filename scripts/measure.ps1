#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(10,10000)][int]$FileCount=1000,
    [string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('Version.ps1','Rules.ps1','Core.ps1')) { . (Join-Path (Join-Path $root 'src') $name) }
if (-not $OutputDirectory) { $OutputDirectory=Join-Path $root ('artifacts\benchmarks\' + [guid]::NewGuid().ToString('N')) }
if ([IO.Directory]::Exists($OutputDirectory) -or [IO.File]::Exists($OutputDirectory)) { throw 'Use a new benchmark output directory.' }
$null=[IO.Directory]::CreateDirectory($OutputDirectory)
$sandbox=New-SjcTestSandbox
$task=New-SjcTaskDirectory -Context $sandbox.Context
$files=Join-Path $sandbox.Root 'files'
for($i=0;$i -lt $FileCount;$i++) {
    $path=Join-Path $files ('synthetic-{0:D6}.tmp' -f $i)
    [IO.File]::WriteAllText($path,('x'*128),[Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddDays(-5))
}
$watch=[Diagnostics.Stopwatch]::StartNew()
$scan=Invoke-SjcScan -Context $sandbox.Context -TaskDirectory $task -RuleIds @('SandboxOld','SandboxLog')
$scanMs=$watch.Elapsed.TotalMilliseconds
if ($scan.Status -ne 'Success' -or $scan.CandidateCount -ne $FileCount) { throw ('Benchmark scan failed: ' + $scan.Error) }
$watch.Restart()
$page=@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset ([math]::Max(0,$FileCount-200)) -Limit 200)
$pageMs=$watch.Elapsed.TotalMilliseconds
$watch.Restart()
$exportPath=Join-Path $sandbox.Root 'synthetic-candidates.csv'
$export=Export-SjcCandidates -PlanPath $scan.PlanPath -Destination $exportPath
$exportMs=$watch.Elapsed.TotalMilliseconds
[IO.File]::Copy($exportPath,(Join-Path $OutputDirectory 'synthetic-candidates.csv'),$false)
$watch.Restart()
$clean=Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -RecycleMode $false
$cleanMs=$watch.Elapsed.TotalMilliseconds
if ($clean.Status -ne 'Success' -or $clean.Deleted -ne $FileCount -or [IO.Directory]::GetFiles($files).Length -ne 0) { throw ('Benchmark synthetic clean failed: ' + $clean.Error) }
$process=[Diagnostics.Process]::GetCurrentProcess(); $process.Refresh()
$result=[ordered]@{
    Version=(Get-SjcVersion); Status='Success'; RecordedUtc=[datetime]::UtcNow.ToString('o');
    PowerShell=$PSVersionTable.PSVersion.ToString(); FileCount=$FileCount; BytesPerFile=128;
    ScanMilliseconds=[math]::Round($scanMs,2); LastPageMilliseconds=[math]::Round($pageMs,2);
    FullExportMilliseconds=[math]::Round($exportMs,2); CleanMilliseconds=[math]::Round($cleanMs,2);
    ProcessPeakWorkingSetBytes=$process.PeakWorkingSet64; PlanBytes=([IO.FileInfo]$scan.PlanPath).Length;
    PageCount=$page.Count; ExportCount=$export.ExportedCount; Deleted=$clean.Deleted;
    SandboxRoot=$sandbox.Root; ProductionCleanerRootsScanned=$false; RealRecycleBinTouched=$false;
    Sources=@(Get-ChildItem -LiteralPath (Join-Path $root 'src') -File -Filter '*.ps1' | ForEach-Object { [pscustomobject]@{Name=$_.Name; SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} });
    Limitations=@('Single warm-run synthetic flat directory; not representative of all disks, third-party applications or user workloads.','Process peak includes PowerShell/module load and synthetic setup; not an isolated engine memory delta.','No v2 speedup comparison; synthetic targets permanently deleted only inside implementation-owned GUID sandbox.','Sandbox metadata retained for evidence; no automatic recursive cleanup.')
}
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'benchmark.json'),($result | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
$result | ConvertTo-Json -Depth 8
