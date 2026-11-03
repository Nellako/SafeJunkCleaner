#requires -Version 5.1
# 隔离界面验收：仅使用本进程自建 GUID 沙箱与人工文件；TestMode 禁止启动生产 Worker，不扫描/删除真实缓存，不写生产偏好。
# 用法：
#   -Show                     打开真实主窗口（可选 -Expand Files,Logs,Advanced：Files=主窗显示后打开文件明细窗，Advanced=以高级自定义（当前预设集合）启动）
#   -EvidenceDirectory <dir>  不显示窗口，按展开状态渲染 PNG 并输出 JSON
#   -Expand Confirm            与 -Show 同用：主窗显示后弹出与生产一致的清理确认窗（Owner=主窗）
#                            仅用于人工 450 候选的界面验收；该窗口不启动生产 Worker、不执行真实清理，
#                            点"永久删除"也仅关闭此测试窗，最终由主对话用 Computer 点击取消
#   -Profile Low|Medium|High  人工扫描使用的强度（默认 Medium，实际 Get-SjcPresetRuleIds 集合，CustomEnabled=false）
param([switch]$Show,[string]$EvidenceDirectory,[ValidateSet('Low','Medium','High')][string]$Profile='Medium',[ValidateSet('Files','Logs','Advanced','Confirm')][string[]]$Expand=@(),[int]$FileCount=450)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
foreach($name in @('Version.ps1','Rules.ps1','Core.ps1','Discovery.ps1','Maintenance.ps1','Worker.ps1','Gui.ps1')){. (Join-Path (Join-Path $root 'src') $name)}
$script:SjcEntryPath=Join-Path $root 'src\Main.ps1';$script:SjcIsPackaged=$false
if($Show -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw '请以 powershell.exe -STA 运行 -Show。'}
$sandbox=New-SjcTestSandbox
if($Profile -cne 'Medium'){Set-SjcCleaningProfile -Context $sandbox.Context -CleaningProfile $Profile}
for($i=0;$i -lt $FileCount;$i++){$ext=if($i%3 -eq 2){'.log'}else{'.tmp'};$p=Join-Path $sandbox.Root ('files\preview-{0:D4}{1}' -f $i,$ext);[IO.File]::WriteAllText($p,('demo-'+$i));[IO.File]::SetLastWriteTimeUtc($p,[datetime]::UtcNow.AddDays(-5))}
$ruleIds=[string[]]@(Get-SjcPresetRuleIds -Context $sandbox.Context -CleaningProfile $Profile)
$task=New-SjcTaskDirectory $sandbox.Context
$scan=Invoke-SjcScan -Context $sandbox.Context -RuleIds $ruleIds -TaskDirectory $task -CustomEnabled $false
if($scan.Status -ne 'Success'){throw $scan.Error}
$state=New-SjcGuiState $sandbox.Context -TestMode
$state.Scan=$scan;$state.ScanProfile=[string]$scan.CleaningProfile;$state.ScanCustomEnabled=[bool]$scan.CustomEnabled;$state.ScanRuleIds=$ruleIds;$state.Stale=$false;$state.TaskDirectory=$task
$state.Status=('隔离界面：人工沙箱 {0} 个候选（{1}预设，CustomEnabled=false）。TestMode 不启动生产 Worker。' -f $scan.CandidateCount,(Get-SjcGuiProfileLabel $Profile))
$app=New-SjcGuiApp $state
$app.Ui.Window.Title='星梦雨垃圾清理器 v'+(Get-SjcVersion)+' · 隔离界面验收（人工沙箱）'
try{
    Start-SjcGuiLocalJob $app 'Open' @{PlanPath=$scan.PlanPath}
    Wait-SjcGuiLocalJob $app 30
    if($state.PageItems.Count -ne [math]::Min(200,[int64]$scan.CandidateCount)){throw ('后台分页未就绪：'+$state.Status)}
    $state.History.Insert(0,[pscustomobject]@{Time=(Get-Date -Format 'MM-dd HH:mm:ss');Action='扫描';Status='完成';Summary=('人工沙箱候选 '+$scan.CandidateCount+' 个');LogPath=[string]$scan.LogPath;TaskDirectory=$task;Result=$scan})
    if($Expand -contains 'Advanced'){Set-SjcGuiCustomEnabled $app $true}
    if($Expand -contains 'Files'){
        if($Show){$app.Ui.Window.Add_ContentRendered({param($sender,$event) $a=$sender.Tag;if(-not $a.FilesWindow -and (Test-SjcGuiFilesAvailable $a.State)){[void](Open-SjcGuiFilesWindow $a)}})}
        else{Set-SjcGuiPanel $app 'Files' $true}
    }
    if($Expand -contains 'Confirm'){
        # 复用 Files 展开的 ContentRendered 事件模式：主窗真正渲染后再弹确认窗。
        # 仅人工沙箱 450 候选的界面验收：确认窗只展示范围，点击确认也不调用生产 Worker / 不做真实清理。
        if($Show){$app.Ui.Window.Add_ContentRendered({param($sender,$event) $a=$sender.Tag;if($a -and -not $a['ConfirmShown']){$a['ConfirmShown']=$true;$w=New-SjcGuiCleanConfirmWindow $a (Get-SjcGuiCleanSummary $a.State);$w.Owner=$a.Ui.Window;try{[void]$w.ShowDialog()}finally{$w.Close()}}})}
    }
    if($Expand -contains 'Logs'){Set-SjcGuiPanel $app 'Logs' $true}
    Update-SjcGuiView $app
    if($Show){[void]$app.Ui.Window.ShowDialog()}
    else{
        $images=@()
        if($EvidenceDirectory){
            [void][IO.Directory]::CreateDirectory($EvidenceDirectory)
            foreach($view in @(@{Name='Main';Files=$false;Logs=$false},@{Name='Files';Files=$true;Logs=$false},@{Name='Logs';Files=$false;Logs=$true})){
                foreach($size in @(@(900,680),@(760,600))){
                    Set-SjcGuiTestLayout $app $size[0] $size[1] $view.Files $view.Logs
                    $path=Join-Path $EvidenceDirectory ('{0}-{1}x{2}.png' -f $view.Name,$size[0],$size[1]);Save-SjcGuiRender $app.Ui.Window $path;$images+=$path
                    if($view.Files -and $app.FilesWindow){$path=Join-Path $EvidenceDirectory ('FilesWindow-{0}x{1}.png' -f $size[0],$size[1]);Save-SjcGuiRender $app.FilesWindow $path;$images+=$path}
                }
            }
        }
        [pscustomobject]@{Status='Success';Profile=$state.Profile;CustomEnabled=$state.CustomEnabled;RuleIds=$ruleIds;BackgroundPageCount=$state.PageItems.Count;CandidateCount=$scan.CandidateCount;SandboxRoot=$sandbox.Root;Images=$images}|ConvertTo-Json
    }
}finally{Remove-SjcGuiApp $app;if(-not $Show){$app.Ui.Window.Close()}}
