#requires -Version 5.1
param([switch]$Show,[string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('Version.ps1','Rules.ps1','Core.ps1','Worker.ps1','Gui.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
$script:SjcEntryPath=Join-Path $root 'src\Main.ps1';$script:SjcIsPackaged=$false
$sandbox=New-SjcTestSandbox
for($i=0;$i -lt 450;$i++){$p=Join-Path $sandbox.Root ('files\preview-{0:D4}.tmp' -f $i);[IO.File]::WriteAllText($p,('demo-'+$i));[IO.File]::SetLastWriteTimeUtc($p,[datetime]::UtcNow.AddDays(-5))}
$task=New-SjcTaskDirectory $sandbox.Context
$scan=Invoke-SjcScan -Context $sandbox.Context -RuleIds @('SandboxOld','SandboxLog') -TaskDirectory $task
if($scan.Status -ne 'Success'){throw $scan.Error}
$state=New-SjcGuiState $sandbox.Context -TestMode;$state.Scan=$scan;$state.Stale=$false;$state.TaskDirectory=$task
$app=New-SjcGuiApp $state
$app.Ui.Window.Title='星梦雨垃圾清理器 v'+(Get-SjcVersion)+' · 隔离界面验收（人工沙箱）'
try{
    Start-SjcGuiLocalJob $app 'Open' @{PlanPath=$scan.PlanPath}
    if($Show){[void]$app.Ui.Window.ShowDialog()}
    else{
        $timeout=[datetime]::UtcNow.AddSeconds(30)
        while($state.Busy -and [datetime]::UtcNow -lt $timeout){Invoke-SjcGuiTick $app;Start-Sleep -Milliseconds 20}
        if($state.Busy -or $state.PageItems.Count -ne 200){throw ('后台分页未就绪：'+$state.Status)}
        if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory($EvidenceDirectory);foreach($page in @('Home','Files','Rules')){Set-SjcGuiPage $app $page;Save-SjcGuiRender $app.Ui.Window (Join-Path $EvidenceDirectory ($page+'.png'))}}
        [pscustomobject]@{Status='Success';BackgroundPageCount=$state.PageItems.Count;CandidateCount=$scan.CandidateCount;SandboxRoot=$sandbox.Root}|ConvertTo-Json
    }
}finally{Remove-SjcGuiApp $app;if(-not $Show){$app.Ui.Window.Close()}}
