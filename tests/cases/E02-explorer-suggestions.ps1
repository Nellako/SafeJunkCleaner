#requires -Version 5.1
# E02: 深度探索「建议 + 复核批准」——0.14 无模型/启发式契约。
# 全部在 GUID 沙箱内运行：假 Host（只用于测试上下文，永不真实回收）覆盖授权路径的严格反例；
# 真实开发 Host 只做到 Analyze -> 建议 -> Prepare -> Confirm，结构上移除 ExecuteApproved；
# 真实 WPF 窗口只做到「复核清单」与取消，不点击「第二步」。不扫描用户目录，只清理本用例自建的 sjc-e02-* 沙箱。
# 迁移自 0.13 模型版：删除 ModelCheck/ModelNote、UseModel、ModelStatus、Checking 轮询相关用例；
# 新增 Scope/Selected 双模式、CancelAnalysis 终态、预算/无进展非成功、QuerySpace revision 过期拒绝、
# QuerySuggestions opaque 游标分页。原有安全断言（默认不勾选/受保护不可选/哈希不匹配拒确认/
# 未 arm 拒执行/真实 Host 无执行入口/沙箱字节不变/模板 CheckBox 与草稿冻结）全部保留。
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
. (Join-Path $RepoRoot 'src\ExplorerGui.ps1')
$base=$null;$s=$null;$windows=New-Object 'System.Collections.Generic.List[object]'
function Pump($S,[scriptblock]$Cond,[int]$Seconds=20){$end=[datetime]::UtcNow.AddSeconds($Seconds);while(-not (& $Cond) -and [datetime]::UtcNow -lt $end -and -not $S.Fault){[void](Step-SjcExplorerSession $S);Start-Sleep -Milliseconds 20}}
function Pump-Dispatcher([int]$Milliseconds,[scriptblock]$Until){
    $frame=[Windows.Threading.DispatcherFrame]::new();$end=[datetime]::UtcNow.AddMilliseconds($Milliseconds)
    $t=[Windows.Threading.DispatcherTimer]::new();$t.Interval=[TimeSpan]::FromMilliseconds(50)
    $t.Add_Tick({if(([datetime]::UtcNow -gt $end) -or ($Until -and (& $Until))){$frame.Continue=$false}}.GetNewClosure());$t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame);$t.Stop()
}
function Read-Requests([string]$Log){
    $ser=New-Object System.Web.Script.Serialization.JavaScriptSerializer
    if(-not (Test-Path -LiteralPath $Log)){return @()}
    @(Get-Content -LiteralPath $Log -Encoding UTF8 | Where-Object {$_} | ForEach-Object {$ser.DeserializeObject($_)})
}
function Count-Op([string]$Log,[string]$Op){ @(Read-Requests $Log | Where-Object {$_['Operation'] -eq $Op}).Count }
function Find-VisualChild($Parent,[Type]$Type){
    $n=[Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent)
    for($i=0;$i -lt $n;$i++){ $ch=[Windows.Media.VisualTreeHelper]::GetChild($Parent,$i); if($ch -is $Type){return $ch}; $d=Find-VisualChild $ch $Type; if($d){return $d} }
    return $null
}
function Get-SuggestionCheckBox($List,$Row){
    # 模板行容器可能尚未生成/已虚拟化：先布局，再按 item/index 取容器，最后退化为整表扫描。
    try{ $List.UpdateLayout() }catch{}
    $container=$List.ItemContainerGenerator.ContainerFromItem($Row)
    if(-not $container){ $idx=$List.Items.IndexOf($Row); if($idx -ge 0){ try{$List.ScrollIntoView($Row);$List.UpdateLayout()}catch{}; $container=$List.ItemContainerGenerator.ContainerFromIndex($idx) } }
    if($container){ $found=Find-VisualChild $container ([Windows.Controls.CheckBox]); if($found){return $found} }
    $found=Find-VisualChild $List ([Windows.Controls.CheckBox])
    if($found -and ([string]$found.Tag -eq [string]$Row.Id)){return $found}
    return $null
}
function Start-FakeSession([string]$Case){
    $log=Join-Path $base ('req-'+$Case+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.log')
    $spec=@{TestId=$id;Exe=$psExe;Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$fake+'" '+$Case+' "'+$log+'"')}
    $f=New-SjcExplorerSession $spec $null
    Pump $f {$f.HostReady -or $f.Fault} 20
    Assert-True ('fake host ready: '+$Case) ($f.HostReady) $f.Fault
    return @{S=$f;Log=$log}
}
# 建议分类辅助：Set-StrictMode Latest 下空数组 [0] 会抛错，这里显式判空返回 $null。
function Get-SuggestionByKind($S,[string]$Kind){
    $match=@()
    switch($Kind){
        'Protected'{ $match=@($S.Suggestions | Where-Object {$_['HardProtected'] -eq $true}) }
        'Reviewable'{ $match=@($S.Suggestions | Where-Object {$_['MayPrepareForReview'] -eq $true -and $_['HardProtected'] -ne $true}) }
        'Blocked'{ $match=@($S.Suggestions | Where-Object {$_['MayPrepareForReview'] -ne $true -and $_['HardProtected'] -ne $true}) }
    }
    if($match.Count -eq 0){return $null}
    return $match[0]
}
# 把假 Host 会话推进到「已盘点、分析完成」。内部输出全部丢弃：Pump/Step 可能写出值，
# 若泄漏到调用方会把「函数返回 false」变成「返回非空数组」，让 if(...) 误判为真。
function Advance-ToSuggestions($S,[string]$Mode='Selected'){
    $null=Start-SjcExplorerInventory $S $folder; Pump $S {$S.State -eq 'Ready' -and $S.Groups.Count -gt 0 -and $S.Queue.Count -eq 0 -and -not $S.InFlight}
    if($Mode -eq 'Selected'){ $null=Select-SjcExplorerGroup $S $S.Groups[0]['GroupId']; Pump $S {$S.Queue.Count -eq 0 -and -not $S.InFlight} }
    $null=Start-SjcExplorerAnalysis $S $Mode
    Pump $S {$S.Analysis -and $S.Analysis.Terminal -and $S.Queue.Count -eq 0 -and -not $S.InFlight}
    Pump $S {$S.Suggestions.Count -gt 0 -or $S.Fault} 15
}
# 建议未加载时如实记为 CoverageGap（真实 Host 形状被客户端 schema 拒绝），
# 不用注入状态假装链已走通，也不把未执行项算作通过。返回严格布尔。
function Test-SuggestionsLoaded($S,[string]$Label){
    Advance-ToSuggestions $S 'Scope'
    $loaded=[bool]($S.Suggestions.Count -gt 0 -and -not $S.Fault)
    if(-not $loaded){ Add-CoverageGap ($Label+'：QuerySuggestions 被客户端 ResultSchema 拒绝（'+$S.Fault+'），建议页加载与后续批准链未执行。') }
    return $loaded
}
try{
    Add-Type -AssemblyName System.Web.Extensions
    Initialize-SjcExplorerBridge
    $id=[guid]::NewGuid().ToString('D'); $candidate=Join-Path ([IO.Path]::GetTempPath()) ('sjc-e02-'+$id)
    [void](New-Item -ItemType Directory -Path $candidate -ErrorAction Stop); $base=$candidate
    $folder=Join-Path $base 'scope'; [void](New-Item -ItemType Directory (Join-Path $folder 'dist\assets'))
    Set-Content -LiteralPath (Join-Path $folder 'package.json') -Value '{"scripts":{"build":"vite build"}}'
    Set-Content -LiteralPath (Join-Path $folder 'dist\index.html') -Value 'synthetic generated'
    Set-Content -LiteralPath (Join-Path $folder 'dist\assets\index-12345678.js') -Value 'synthetic generated'
    Set-Content -LiteralPath (Join-Path $folder 'sjc-e02-marker.txt') -Value $id
    $before=@(Get-ChildItem -LiteralPath $folder -Recurse -File | ForEach-Object {$_.FullName+'|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n"
    $script:SjcExplorerTestContext=@{Id=$id;StateRoot=(Join-Path $base 'state');RuntimeCache=$env:SJC_TEST_RUNTIME_CACHE}

    # ---- 1) 载荷白名单：无模型、双模式、取消 ----
    $tid='11111111-2222-4333-8444-555555555555'; $b=[SjcExplorerBridge]::new()
    function New-Payload([string]$Json){
        $p=[Collections.Generic.Dictionary[string,object]]::new()
        foreach($kv in (New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($Json).GetEnumerator()){$p[$kv.Key]=$kv.Value}
        return $p
    }
    $rejected=@(
        @('Analyze','{"TargetId":null,"ExpectedEvidenceRevision":1,"ExplorationMode":"Scope","UseModel":true}'),
        @('Analyze','{"TargetId":"7","ExpectedEvidenceRevision":1,"ExplorationMode":"Selected","UseModel":false}'),
        @('Analyze','{"TargetId":"7"}'),
        @('Analyze','{"TargetId":null,"ExpectedEvidenceRevision":1,"ExplorationMode":"Scope","Mode":"DeterministicFactsOnly"}'),
        @('CancelAnalysis','{"AnalysisId":"not-a-guid"}'),
        @('QuerySpace','{"AfterCursor":"x","PageSize":65}'),
        @('QuerySuggestions','{"AnalysisId":"x"}'),
        @('ConfirmApproval','{"DraftId":"x","DisplayHash":"y","Extra":true}'),
        @('NoSuchOperation','{}'))
    foreach($case in $rejected){
        $threw=$false
        try{[void]$b.BeginRequest($case[0],$tid,(New-Payload $case[1]),1000)}catch{$threw=$true}
        Assert-True ('bridge rejects bad payload/op before any process: '+$case[0]+' '+$case[1]) $threw
    }
    $threw=$false; try{$b.ArmExecution('not-a-guid')}catch{$threw=$true}; Assert-True 'ArmExecution rejects invalid approval id' $threw

    # ---- 2) 假 Host ----
    $psExe=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $fake=Join-Path $base 'fake-host.ps1'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests\lib\ExplorerFakeHost.ps1') -Destination $fake -ErrorAction Stop
    Assert-True 'fake host fixture present' (Test-Path -LiteralPath $fake)

    # 2a) 默认全部不勾选 / 保护不可选 / 无模型字段；Analysis 使用 Scope
    $r=Start-FakeSession 'plain'; $s=$r.S; $log=$r.Log
    [void](Advance-ToSuggestions $s 'Scope')
    $analyzeReq=@(Read-Requests $log | Where-Object {$_['Operation'] -eq 'Analyze'})[0]
    Assert-True 'Analyze carries no UseModel ever' (-not $analyzeReq['Payload'].ContainsKey('UseModel'))
    Assert-True 'Analyze payload carries null TargetId under Scope mode' ($null -eq $analyzeReq['Payload']['TargetId'])
    Assert-Equal 'Analyze payload ExplorationMode is Scope' 'Scope' ([string]$analyzeReq['Payload']['ExplorationMode'])
    Assert-True 'Analyze payload has no ModelStatus/legacy Mode' (-not $analyzeReq['Payload'].ContainsKey('ModelStatus') -and -not $analyzeReq['Payload'].ContainsKey('Mode'))
    Assert-Equal 'no Prepare/Confirm/Execute sent before user action' 0 ((Count-Op $log 'PrepareApproval')+(Count-Op $log 'ConfirmApproval')+(Count-Op $log 'ExecuteApproved'))
    Assert-Equal 'no suggestion selected by default' 0 $s.Selected.Count
    # 建议页加载依赖客户端接受 Host 的 QuerySuggestions 绑定字段形状（Revision/Sort/CursorSchema）。
    Assert-True 'fake host suggestions load under the current client schema' ($s.Suggestions.Count -eq 3) ('suggestions='+$s.Suggestions.Count+' fault='+$s.Fault)
    if($s.Suggestions.Count -eq 3){
        $prot=Get-SuggestionByKind $s 'Protected'; $ok1=Get-SuggestionByKind $s 'Reviewable'; $blocked=Get-SuggestionByKind $s 'Blocked'
        Assert-True 'protected suggestion cannot be selected' (-not (Set-SjcExplorerSuggestionSelected $s ([string]$prot['SuggestionId']) $true))
        Assert-True 'non-reviewable suggestion cannot be selected' (-not (Set-SjcExplorerSuggestionSelected $s ([string]$blocked['SuggestionId']) $true))
        Assert-Equal 'selection still empty after refused selects' 0 $s.Selected.Count
        Assert-True 'prepare refused with empty selection' (-not (Request-SjcExplorerPrepare $s))
        Assert-True 'impact text is translated, not raw English' ((Get-SjcExplorerSuggestionDetail $s.SugIndex[[string]$ok1['SuggestionId']]) -match '重新构建')
        Assert-True 'untranslated host text is labelled, never invented' ((Get-SjcExplorerImpactText 'Totally new text') -like '（未翻译的 Host 原文）*')
        # 勾选 -> Prepare（用户动作）
        Assert-True 'reviewable suggestion can be selected' (Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $true)
        Assert-True 'prepare accepted after user selection' (Request-SjcExplorerPrepare $s)
        Pump $s {$s.Draft -and $s.Draft.DraftId -and $s.Draft.DisplayedHash -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-Equal 'draft shows exact item count' 2 $s.Draft.ItemCount
        Assert-Equal 'draft shows exact logical bytes' 200 $s.Draft.LogicalBytes
        Assert-Equal 'draft items listed individually' 2 $s.DraftItems.Count
        Assert-Equal 'displayed hash equals draft hash' $s.Draft.DisplayHash $s.Draft.DisplayedHash
        Assert-True 'confirm refused without user click' (-not (Confirm-SjcExplorerApproval $s $false))
        Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 2
        Assert-Equal 'no ConfirmApproval sent without user click' 0 (Count-Op $log 'ConfirmApproval')
        Assert-True 'selection frozen after draft' (-not (Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $false))
        # recycle 不可用：确认后 CanExecute=false，执行被本地拒绝，请求不会发出
        Assert-True 'confirm accepted after user click' (Confirm-SjcExplorerApproval $s $true)
        Pump $s {$s.Approval -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-True 'approval received' ($null -ne $s.Approval)
        Assert-True 'CanExecute is false when recycle unavailable' ($s.Approval.CanExecute -eq $false)
        Assert-True 'execute refused locally when CanExecute false' (-not (Invoke-SjcExplorerExecute $s $true))
        Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 2
        Assert-Equal 'no ExecuteApproved ever sent to disabled host' 0 (Count-Op $log 'ExecuteApproved')
        $confirmReq=@(Read-Requests $log | Where-Object {$_['Operation'] -eq 'ConfirmApproval'})[0]
        Assert-Equal 'confirm bound to the displayed hash' $s.Draft.DisplayHash $confirmReq['Payload']['DisplayHash']
    } else { Add-CoverageGap ('建议链未执行：客户端 schema 拒绝 Host 的 QuerySuggestions 绑定字段（当前错误：'+$s.Fault+'）。') }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2a2) Selected 模式：TargetId 必须是可信 ObjectId，且只能来自已选分组
    $r=Start-FakeSession 'plain'; $s=$r.S; $log=$r.Log
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    Assert-True 'Selected refused while no group is selected' (-not (Start-SjcExplorerAnalysis $s 'Selected'))
    Select-SjcExplorerGroup $s $s.Groups[0]['GroupId']; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
    Assert-True 'Selected accepted after group selection' (Start-SjcExplorerAnalysis $s 'Selected')
    Pump $s {$s.Analysis -and $s.Analysis.Id}
    $selReq=@(Read-Requests $log | Where-Object {$_['Operation'] -eq 'Analyze'})[0]
    Assert-Equal 'Selected payload targets the selected group id' ([string]$s.ParentId) ([string]$selReq['Payload']['TargetId'])
    Assert-Equal 'Selected payload mode is Selected' 'Selected' ([string]$selReq['Payload']['ExplorationMode'])
    Assert-True 'Selected payload target is a plausible ObjectId' ([string]$selReq['Payload']['TargetId'] -match '^[A-Za-z0-9_-]{1,80}$')
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2b) DisplayHash 变化被拒绝：界面不会 Confirm
    $r=Start-FakeSession 'hashchange'; $s=$r.S; $log=$r.Log
    if(Test-SuggestionsLoaded $s '2b DisplayHash 变化'){
        $ok1=Get-SuggestionByKind $s 'Reviewable'
        [void](Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $true); [void](Request-SjcExplorerPrepare $s)
        Pump $s {$s.Draft -and $s.Draft.DraftId -and $s.DraftItems.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-Equal 'changed display hash recorded as mismatch' 'DisplayedSnapshotMismatch' $s.Draft.ConfirmError
        Assert-True 'confirm refused when displayed hash differs from draft' (-not (Confirm-SjcExplorerApproval $s $true))
        Assert-Equal 'no ConfirmApproval sent after hash mismatch' 0 (Count-Op $log 'ConfirmApproval')
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c) 取消：CancelAnalysis 请求一次，终态 Cancelled，且取消后建议为空/准备被拒
    $r=Start-FakeSession 'cancel'; $s=$r.S; $log=$r.Log
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Id -and $s.Analysis.Status -eq 'Running'} 15
    Assert-True 'cancel accepted while running' (Stop-SjcExplorerAnalysis $s)
    Pump $s {$s.Analysis.Terminal} 15
    Assert-Equal 'analysis terminal status is Cancelled' 'Cancelled' $s.Analysis.Status
    Assert-True 'cancelled analysis is not Ready' (-not $s.Analysis.Ready)
    Assert-Equal 'one CancelAnalysis request' 1 (Count-Op $log 'CancelAnalysis')
    Assert-True 'repeated cancel refused' (-not (Stop-SjcExplorerAnalysis $s))
    Assert-True 'cancelled analysis is not Ready (HasResult=false)' ($s.Analysis.Ready -eq $false)
    Assert-Equal 'no suggestions loaded after cancellation' 0 $s.Suggestions.Count
    Assert-Equal 'no QuerySuggestions sent for a cancelled analysis' 0 (Count-Op $log 'QuerySuggestions')
    Assert-True 'prepare refused after cancellation' (-not (Request-SjcExplorerPrepare $s))
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c1b) 已有建议后再次分析并取消：旧建议与勾选不得残留为可处理状态
    $r=Start-FakeSession 'recancel'; $s=$r.S; $log=$r.Log
    $firstLoaded=Test-SuggestionsLoaded $s '2c1b 取消后旧建议不残留（首次分析）'
    Assert-True 'first analysis produced suggestions before the cancelled re-analysis' $firstLoaded ('suggestions='+$s.Suggestions.Count+' fault='+$s.Fault)
    if($firstLoaded){
        $ok1=Get-SuggestionByKind $s 'Reviewable'
        [void](Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $true)
        $countBefore=$s.Suggestions.Count
        [void](Start-SjcExplorerAnalysis $s 'Scope')
        Pump $s {$s.Analysis -and $s.Analysis.Id -and $s.Analysis.Status -eq 'Running'} 15
        Assert-Equal 're-analysis clears the previous selection before running' 0 $s.Selected.Count
        Assert-Equal 're-analysis clears the previous suggestions' 0 $s.Suggestions.Count
        Assert-True 'cancel accepted for the second analysis' (Stop-SjcExplorerAnalysis $s)
        Pump $s {$s.Analysis.Terminal} 15
        Assert-Equal 'second analysis ends Cancelled' 'Cancelled' $s.Analysis.Status
        Assert-Equal 'suggestions from the cancelled analysis are not loaded' 0 $s.Suggestions.Count
        Assert-Equal 'nothing remains selected after cancellation' 0 $s.Selected.Count
        Assert-True 'prepare stays refused after cancellation' (-not (Request-SjcExplorerPrepare $s))
        Assert-True 'previous suggestion count was non-zero before cancellation' ($countBefore -gt 0)
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c2) 真实 scheduler 预算耗尽 / 无进展：HasResult=true（完整结果已发布）才允许翻页建议，
    # 但不得当作成功、不得默认勾选。
    foreach($case in @(@('budget','BudgetExhausted'),@('noprog','NoProgress'))){
        $r=Start-FakeSession $case[0]; $s=$r.S; $log=$r.Log
        Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Terminal} 15
        Assert-Equal ('terminal status preserved ('+$case[0]+')') $case[1] $s.Analysis.Status
        $u=$s.Analysis.Usage
        Assert-True ('six usage counters present ('+$case[0]+')') ($u -is [Collections.IDictionary] -and @(@('Steps','MetadataObjects','ReadFiles','SampleBytes','HashBytes','HashFiles') | Where-Object {$null -eq $u[$_]}).Count -eq 0)
        Assert-True ('progress present ('+$case[0]+')') ($s.Analysis.Progress -is [Collections.IDictionary] -and $s.Analysis.Progress.ContainsKey('HasMore'))
        Assert-True ('scheduler budget/no-progress result is Ready because HasResult=true ('+$case[0]+')') ($s.Analysis.Ready -eq $true)
        # HasResult=true => 允许页查询建议；空页也算正常响应，不能因 0 条就退回重试或当作失败。
        Pump $s {$s.Suggestions.Count -gt 0 -or $s.Fault} 15
        Assert-Equal ('suggestion page requested once for a published result ('+$case[0]+')') 1 (Count-Op $log 'QuerySuggestions')
        Assert-True ('no fault after querying suggestions ('+$case[0]+')') (-not $s.Fault) $s.Fault
        Assert-Equal ('nothing selected by default after partial result ('+$case[0]+')') 0 $s.Selected.Count
        $txt=Get-SjcExplorerAnalysisStatusText $s.Analysis.Status
        if($case[0] -eq 'budget'){ Assert-True 'budget exhaustion is labelled incomplete' ($txt -like '*预算用尽*' -and $txt -like '*不完整*') $txt }
        else{ Assert-True 'no-progress is not labelled complete' ($txt -notlike '*完成*') $txt }
        [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null
    }

    # 2c2b) 异步 load/display 超时：终态 BudgetExhausted、HasResult=false（无完整 Result）。
    # 诊断 Usage 可以为非 null，但 HasResult=false 时必须不请求 QuerySuggestions，也不得允许 Prepare。
    $r=Start-FakeSession 'loadingbudget'; $s=$r.S; $log=$r.Log
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Terminal} 15
    Assert-Equal 'loading-timeout keeps BudgetExhausted terminal status' 'BudgetExhausted' $s.Analysis.Status
    Assert-True 'loading-timeout carries diagnostic usage that may be non-null' ($s.Analysis.Usage -is [Collections.IDictionary] -and $s.Analysis.Usage['Steps'] -ge 0)
    Assert-True 'loading-timeout progress reason is a loading stage, not evidence' ([string]$s.Analysis.Progress['Reason'] -in 'LoadingInventorySnapshot','BuildingChargedInventoryIndex','PreparingSuggestionDisplay') ([string]$s.Analysis.Progress['Reason'])
    Assert-True 'loading-timeout analysis is not Ready (HasResult=false)' ($s.Analysis.Ready -eq $false)
    Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 5
    Assert-Equal 'no QuerySuggestions sent when HasResult is false' 0 (Count-Op $log 'QuerySuggestions')
    Assert-Equal 'no suggestions appear for a loading-timeout result' 0 $s.Suggestions.Count
    Assert-True 'prepare refused for a loading-timeout result' (-not (Request-SjcExplorerPrepare $s))
    Assert-True 'no fault: the client simply waits for a published result' (-not $s.Fault) $s.Fault
    Assert-True 'loading-timeout is labelled incomplete, not success' ((Get-SjcExplorerAnalysisStatusText $s.Analysis.Status) -like '*不完整*') (Get-SjcExplorerAnalysisStatusText $s.Analysis.Status)
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c3) 重复分析：先作废旧分析；新的分析仍使用无模型载荷
    # 建议页被客户端 schema 阻断时（会话已 Fault），重复分析/历史任务分支无法执行，如实记 Gap 不伪造。
    $r=Start-FakeSession 'plain'; $s=$r.S; $log=$r.Log
    $loaded2c3=Test-SuggestionsLoaded $s '2c3 重复分析'
    Assert-True 're-analysis scenario reached suggestions' $loaded2c3 ('suggestions='+$s.Suggestions.Count+' fault='+$s.Fault)
    if($loaded2c3){
        Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
        [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis.Terminal -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-Equal 're-analysis invalidates the previous analysis first' 1 (Count-Op $log 'InvalidateAnalysis')
        Assert-Equal 'selection cleared by re-analysis' 0 $s.Selected.Count
        Assert-True 'every Analyze request stays modelless' (@(Read-Requests $log | Where-Object {$_['Operation'] -eq 'Analyze' -and $_['Payload'].ContainsKey('UseModel')}).Count -eq 0)
        # 历史任务：恢复 / 显式释放
        Assert-True 'ListTasks declared and loaded' ($s.TaskListLoaded -and $s.TaskList.Count -ge 1)
        Assert-True 'release refused without user confirmation' (-not (Release-SjcExplorerTask $s ([string]$s.TaskList[0]['TaskId']) $false))
        Assert-True 'release accepted with user confirmation' (Release-SjcExplorerTask $s ([string]$s.TaskList[0]['TaskId']) $true)
        Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-Equal 'ReleaseTask sent exactly once' 1 (Count-Op $log 'ReleaseTask')
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c4) 建议分页：opaque 游标前进/后退，不出现数字 offset
    $r=Start-FakeSession 'sugpages'; $s=$r.S; $log=$r.Log
    Advance-ToSuggestions $s 'Scope'
    $loaded2c4=[bool]($s.Suggestions.Count -gt 0 -and -not $s.Fault -and $s.Queue.Count -eq 0 -and -not $s.InFlight)
    Assert-True 'suggestion pagination scenario reached suggestions' $loaded2c4 ('suggestions='+$s.Suggestions.Count+' fault='+$s.Fault)
    if($loaded2c4){
        Assert-Equal 'first suggestion page has one item' 1 $s.Suggestions.Count
        Assert-True 'next cursor is opaque base64url' ([string]$s.SugNext -match '^[A-Za-z0-9_-]+$' -and ([string]$s.SugNext).Length -le 2048)
        $firstCursor=[string]$s.SugNext
        Move-SjcExplorerSuggestionPage $s 1; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 15
        Assert-Equal 'second page has the remaining two suggestions' 2 $s.Suggestions.Count
        $pageReqs=@(Read-Requests $log | Where-Object {$_['Operation'] -eq 'QuerySuggestions'})
        Assert-True 'second page request passes the same opaque cursor returned by page 1' ($pageReqs.Count -ge 2 -and [string]$pageReqs[1]['Payload']['AfterId'] -eq $firstCursor)
        Move-SjcExplorerSuggestionPage $s -1; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 15
        Assert-Equal 'back to first suggestion page' 1 $s.Suggestions.Count
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2c5) 空间排行 revision 过期：客户端拒绝接受并保持旧数据，不静默替换
    $r=Start-FakeSession 'spacestale'; $s=$r.S
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight} 20
    Assert-True 'initial space page loaded' ($s.Space.Count -ge 1 -and [long]$s.SpaceRevision -eq [long]$s.Revision)
    $goodObjects=@($s.Space | ForEach-Object {[string]$_['ObjectId']})
    Move-SjcExplorerSpacePage $s 1; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 20
    Assert-Equal 'stale space revision is rejected with a visible error' 'SpaceRevisionChanged' $s.LastError
    Assert-Equal 'stale page does not replace the shown rows' ($goodObjects -join ',') (@($s.Space | ForEach-Object {[string]$_['ObjectId']}) -join ',')
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 2d) 假 Host 声明可回收（仅测试夹具）：两步确认、重复 Execute、Partial/Unknown 不当成功
    $r=Start-FakeSession 'exec'; $s=$r.S; $log=$r.Log
    if(Test-SuggestionsLoaded $s '2d 执行两步确认'){
        $ok1=Get-SuggestionByKind $s 'Reviewable'
        [void](Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $true); [void](Request-SjcExplorerPrepare $s)
        Pump $s {$s.Draft -and $s.Draft.DisplayedHash -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-True 'execute refused before confirm' (-not (Invoke-SjcExplorerExecute $s $true))
        [void](Confirm-SjcExplorerApproval $s $true); Pump $s {$s.Approval -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-True 'CanExecute true from fake host' ($s.Approval.CanExecute -eq $true)
        Assert-True 'execute refused without second explicit user confirmation' (-not (Invoke-SjcExplorerExecute $s $false))
        Assert-Equal 'no ExecuteApproved yet' 0 (Count-Op $log 'ExecuteApproved')
        # 结构保护：脚本直接调用 BeginRequest 而不 Arm，也发不出去
        $threw=$false; try{ $p=[Collections.Generic.Dictionary[string,object]]::new(); $p['ApprovalId']=[string]$s.Approval.ApprovalId; [void]$s.Bridge.BeginRequest('ExecuteApproved',[string]$s.TaskId,$p,1000) }catch{$threw=$true}
        Assert-True 'bridge refuses un-armed ExecuteApproved' $threw
        Assert-True 'second explicit confirmation sends execute' (Invoke-SjcExplorerExecute $s $true)
        Assert-True 'repeated execute refused while one is active/finished' (-not (Invoke-SjcExplorerExecute $s $true))
        Pump $s {$s.Exec -and $s.Exec.Terminal -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-Equal 'exactly one ExecuteApproved sent' 1 (Count-Op $log 'ExecuteApproved')
        Assert-Equal 'partial status kept' 'PartialOrInterrupted' $s.Exec.Status
        $txt=Get-SjcExplorerExecutionText $s
        Assert-True 'partial result is not reported as success' ($txt -like '部分完成*' -and $txt -notlike '已完成*') $txt
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null
    $r=Start-FakeSession 'execunknown'; $s=$r.S; $log=$r.Log
    if(Test-SuggestionsLoaded $s '2d 执行结果未知'){
        $ok1=Get-SuggestionByKind $s 'Reviewable'
        [void](Set-SjcExplorerSuggestionSelected $s ([string]$ok1['SuggestionId']) $true); [void](Request-SjcExplorerPrepare $s)
        Pump $s {$s.Draft -and $s.Draft.DisplayedHash -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        [void](Confirm-SjcExplorerApproval $s $true); Pump $s {$s.Approval -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        [void](Invoke-SjcExplorerExecute $s $true); Pump $s {$s.Exec -and $s.Exec.Terminal -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        $txt=Get-SjcExplorerExecutionText $s
        Assert-True 'Completed with fewer entries than the draft is rendered as unknown, not success' ($txt -like '*不一致*' -and $txt -notlike '已完成：*') $txt
    }
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # ---- 3) 真实开发 Host：Contract3 Analyze -> 建议 -> Prepare -> Confirm（不执行）----
    if(-not $env:SJC_TEST_RUNTIME_CACHE){throw 'Explicit isolated test runtime required'}
    $cacheRoot=Join-Path $env:SJC_TEST_RUNTIME_CACHE 'current.json'
    $devReady=$false
    if(Test-Path -LiteralPath $cacheRoot){
        try{
            $pointer=Get-Content -LiteralPath $cacheRoot -Raw -Encoding UTF8 | ConvertFrom-Json
            $devReady=([int]$pointer.ContractVersion -eq 3)
            if(-not $devReady){ Add-CoverageGap ('真实开发 Host runtime 指针仍为 ContractVersion='+[string]$pointer.ContractVersion+'；Contract3 真实 Host Analyze/Prepare/Confirm 未执行。') }
        }catch{ Add-CoverageGap ('开发 runtime 指针不可解析：'+$_.Exception.Message) }
    } else { Add-CoverageGap 'COVERAGE GAP (blocks E02 final): development Explorer runtime pointer is absent; real-host Analyze/Prepare/Confirm were NOT exercised.' }
    if($devReady){
        $s=New-SjcExplorerSession $null $RepoRoot
        Pump $s {$s.HostReady} 40; Assert-True 'real host ready' $s.HostReady $s.Fault
        if($s.HostReady){
            # 安全护栏：本测试在会话层永久移除 ExecuteApproved，任何路径都无法对真实 Host 发起执行。
            $declaredExecute=($s.Operations -contains 'ExecuteApproved')
            $s.Operations=@($s.Operations | Where-Object {$_ -ne 'ExecuteApproved'})
            Assert-True 'real host declares the analysis/approval operations' ($declaredExecute -and @(@('Analyze','CancelAnalysis','QuerySpace','QuerySuggestions','PrepareApproval','ConfirmApproval') | Where-Object {$s.Operations -notcontains $_}).Count -eq 0) ('ops='+(@($s.Operations) -join ','))
            Assert-True 'real host declares Contract3 heuristic modes' ((Test-SjcExplorerHostCap $s 'HeuristicExploration') -and -not (Test-SjcExplorerHostCap $s 'ModelIncluded'))
            # 任何后续 Health 都不得把移除的 ExecuteApproved 重新加入。
            # 0.14 已删除 Checking 轮询，没有自动重复 Health；这里显式重发一次 Health，
            # 验证会话对重复健康响应只收窄、不扩权。
            $healthBefore=@($s.Operations)
            Add-SjcExplorerRequest $s 'Health' $null @{}
            Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 20
            Assert-True 'real host structurally cannot execute after an explicit health refresh' (-not ($s.Operations -contains 'ExecuteApproved') -and -not (Test-SjcExplorerCanExecute $s)) ('ops='+(@($s.Operations) -join ','))
            Assert-True 'health refresh does not widen the operation set' (@($s.Operations | Where-Object {$healthBefore -notcontains $_}).Count -eq 0) ('ops='+(@($s.Operations) -join ','))
            Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -in 'Ready','Partial','Failed'} 40
            Assert-Equal 'real inventory ready' 'Ready' $s.State $s.LastError
            Pump $s {$s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
            $dist=@($s.Groups | Where-Object {[string]$_['Path'] -eq $folder})[0]; Assert-True 'scope root group listed (dist output is detected from its parent)' ($null -ne $dist)
            # Scope 模式：无需选中分组即可分析整个选定范围
            $s.ParentId=$null
            Assert-True 'scope analysis starts without a selected group' (Start-SjcExplorerAnalysis $s 'Scope')
            Pump $s {$s.Analysis.Terminal -and $s.Queue.Count -eq 0 -and -not $s.InFlight} 60
            Assert-Equal 'real scope analysis mode recorded' 'Scope' $s.Analysis.Mode
            Assert-True 'real scope analysis did not fail' ($s.Analysis.Status -ne 'Failed') ($s.Analysis.Status+' '+$s.Analysis.ErrorCode)
            Assert-True 'real scope analysis reports usage counters or explicit null' ($null -eq $s.Analysis.Usage -or $s.Analysis.Usage -is [Collections.IDictionary])
            Assert-True 'real analysis Ready is gated by HasResult, not Usage' ([bool]($s.Analysis.Ready -eq $false) -or ($s.Analysis.Ready -eq $true -and $s.Analysis.Status -in 'Complete','BudgetExhausted','NoProgress','AskedUser'))
            Assert-True 'real scope progress reported' ($s.Analysis.Progress -is [Collections.IDictionary])
            Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight} 10
            Assert-Equal 'real suggestions are never selected by default' 0 $s.Selected.Count
            Assert-True 'real suggestions never claim default selection' (@($s.Suggestions | Where-Object {$_['SelectedByDefault'] -ne $false}).Count -eq 0)
            $rev=@($s.Suggestions | Where-Object {Test-SjcExplorerSuggestionSelectable $_})
            if($rev.Count){
                $sid=[string]$rev[0]['SuggestionId']
                Select-SjcExplorerSuggestionFiles $s $sid; Pump $s {$s.SugFiles.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
                Assert-True 'suggestion files listed with paths inside the sandbox' ($s.SugFiles.Count -ge 1 -and @($s.SugFiles | Where-Object {([string]$_['Path']).StartsWith($folder,[StringComparison]::OrdinalIgnoreCase)}).Count -eq $s.SugFiles.Count)
                [void](Set-SjcExplorerSuggestionSelected $s $sid $true); Assert-True 'prepare from real host' (Request-SjcExplorerPrepare $s)
                Pump $s {$s.Draft -and $s.Draft.DisplayedHash -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
                Assert-True 'real draft is RecycleOnly with exact count' ($s.Draft.DraftId -and $s.Draft.ItemCount -ge 1 -and $s.DraftItems.Count -eq [Math]::Min(64,$s.Draft.ItemCount)) $s.LastError
                Assert-Equal 'real displayed hash equals draft hash' $s.Draft.DisplayHash $s.Draft.DisplayedHash
                Assert-True 'real draft files are all under the sandbox' (@($s.DraftItems | Where-Object {([string]$_['File']['Path']).StartsWith($folder,[StringComparison]::OrdinalIgnoreCase)}).Count -eq $s.DraftItems.Count)
                Assert-True 'confirm with user click on real host' (Confirm-SjcExplorerApproval $s $true)
                Pump $s {$s.Approval -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
                Assert-True 'real host returned an approval' ($null -ne $s.Approval -and $s.Approval.ApprovalId) $s.LastError
                Assert-True 'real host CanExecute is a boolean declaration (recorded, never acted on)' ($s.Approval.CanExecute -is [bool]) ('CanExecute='+$s.Approval.CanExecute+' declaredExecuteOp='+$declaredExecute)
                Assert-True 'execute is structurally unavailable in the real-host test session' (-not (Test-SjcExplorerCanExecute $s))
            } else { Add-CoverageGap '真实 Host 未给出可复核建议（沙箱布局未触发构建产物识别）；Prepare/Confirm 真实链路未执行。' }
            Assert-True 'real flow has no execution state and no queued ExecuteApproved' ($null -eq $s.Exec -and @($s.Queue | Where-Object {$_.Op -eq 'ExecuteApproved'}).Count -eq 0)
            Assert-True 'no stderr noise from real host' ($s.Stderr.Count -eq 0) ($s.Stderr -join '|')
        }
        [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null
    }

    # ---- 4) 真实 WPF 窗口（假 Host）：只到复核清单与取消 ----
    if($LoadGui){
        $spec=@{TestId=$id;Exe=$psExe;Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$fake+'" exec "'+(Join-Path $base 'req-window.log')+'"')}
        $w=Open-SjcExplorerWindow $null $spec -NoShow; $windows.Add($w); $c=$w.Tag.Controls; $w.Show()
        Pump-Dispatcher 30000 { $w.Tag.Session.HostReady -or $w.Tag.Session.Fault }
        Assert-True 'window connected to fake host' ($w.Tag.Session.HostReady) $w.Tag.Session.Fault
        Assert-True 'window has inventory, suggestion, space, history and consumer help tabs' ($c.MainTabs.Items.Count -eq 5 -and $c.SuggestTab.Header -eq '建议与处理' -and $c.SpaceTab.Header -eq '空间排行' -and $c.HistoryTab.Header -eq '历史任务' -and $c.ResourceTab.Header -eq '记录与帮助') ($c.MainTabs.Items.Count.ToString()+' tabs')
        Assert-True 'model checkbox and note are gone from the suggestion page' (-not $c.ContainsKey('ModelCheck') -and -not $c.ContainsKey('ModelNote'))
        Assert-True 'engine note explains heuristic exploration without a model' ($c.EngineNote.Text -like '*启发式*') $c.EngineNote.Text
        $c.FolderPathBox.Text=$folder; $c.ScopeFolderRadio.IsChecked=$true; $w.Tag.Scope=$folder
        Pump-Dispatcher 400 $null
        $c.StartButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 30000 { $w.Tag.Session.State -eq 'Ready' -and $w.Tag.Session.Groups.Count -gt 0 -and $w.Tag.Session.Queue.Count -eq 0 -and -not $w.Tag.Session.InFlight }
        # 单目录分析：先选分组，AnalyzeButton 才可用；分析走 Selected 模式。
        $c.GroupsList.SelectedIndex=0
        Pump-Dispatcher 5000 { $w.Tag.Session.ParentId -and $c.AnalyzeButton.IsEnabled }
        Assert-True 'single-target analyze enabled once a group is selected' ([bool]$c.AnalyzeButton.IsEnabled)
        $c.AnalyzeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 30000 { $c.SuggestionsList.Items.Count -ge 3 }
        Assert-Equal 'suggestions table shows all three suggestions' 3 $c.SuggestionsList.Items.Count
        Assert-True 'no suggestion row is checked' (@($c.SuggestionsList.Items | Where-Object {$_.Checked}).Count -eq 0)
        Assert-True 'protected rows are not selectable in the table' (@($c.SuggestionsList.Items | Where-Object {-not $_.Selectable}).Count -eq 2)
        Assert-True 'prepare button disabled with nothing selected' (-not $c.PrepareButton.IsEnabled)
        # 切到建议页并让列表完成布局：未激活页签中的 ListView 不会实化行容器。
        $c.MainTabs.SelectedItem=$c.SuggestTab
        Pump-Dispatcher 1200 { $c.SuggestionsList.Items.Count -eq 3 }
        try{ $c.SuggestionsList.UpdateLayout() }catch{}
        Pump-Dispatcher 400 $null
        # 真实模板 CheckBox：通过模板元素自身 IsChecked（不经 Set-SjcExplorerSuggestionSelected）驱动选择/取消。
        $okRow=@($c.SuggestionsList.Items | Where-Object {$_.Selectable})[0]
        $protRow=@($c.SuggestionsList.Items | Where-Object {-not $_.Selectable})[0]
        $okBox=Get-SuggestionCheckBox $c.SuggestionsList $okRow
        $protBox=Get-SuggestionCheckBox $c.SuggestionsList $protRow
        Assert-True 'template checkbox found for selectable row' ($null -ne $okBox) 'visual tree lookup'
        Assert-True 'template checkbox found for protected row' ($null -ne $protBox) 'visual tree lookup'
        if($okBox -and $protBox){
            Assert-True 'protected template checkbox is disabled' (-not $protBox.IsEnabled)
            Assert-True 'selectable template checkbox starts unchecked' ($okBox.IsChecked -eq $false)
            # 选中：真实 CheckBox 置位应同步 session.Selected、DataContext.Checked、summary 与 Prepare。
            $okBox.IsChecked=$true
            Pump-Dispatcher 800 { $w.Tag.Session.Selected.ContainsKey([string]$okRow.Id) -and $c.PrepareButton.IsEnabled }
            Assert-True 'template checkbox check updates selection set' ($w.Tag.Session.Selected.ContainsKey([string]$okRow.Id)) ('selected='+$w.Tag.Session.Selected.Count)
            Assert-True 'template checkbox check syncs row Checked flag' ($okRow.Checked -eq $true) ('Checked='+$okRow.Checked)
            Assert-True 'template checkbox check updates summary text' ($c.SelectionText.Text -like '*已勾选 1 项建议*') $c.SelectionText.Text
            Assert-True 'template checkbox check enables prepare' ([bool]$c.PrepareButton.IsEnabled)
            # 取消：再次置位应清除选择并通过下一次界面刷新禁用 Prepare。
            $okBox.IsChecked=$false
            Pump-Dispatcher 1500 { -not $w.Tag.Session.Selected.ContainsKey([string]$okRow.Id) -and -not $w.Tag.Session.InFlight }
            Assert-True 'template checkbox uncheck clears selection set' (-not $w.Tag.Session.Selected.ContainsKey([string]$okRow.Id))
            Assert-True 'template checkbox uncheck syncs row Checked flag' ($okRow.Checked -eq $false) ('Checked='+$okRow.Checked)
            Pump-Dispatcher 1500 { -not $c.PrepareButton.IsEnabled -or $w.Tag.Session.InFlight }
            Assert-True 'template checkbox uncheck disables prepare' (-not $c.PrepareButton.IsEnabled) ('enabled='+$c.PrepareButton.IsEnabled+' dirty='+$w.Tag.Session.ApprovalDirty)
            # 受保护行：即使强制置位 renderer/session 也不接受。
            $protBox.IsChecked=$true
            Pump-Dispatcher 500
            Assert-True 'protected row cannot become selected via template checkbox' (-not $w.Tag.Session.Selected.ContainsKey([string]$protRow.Id))
            Assert-True 'protected template checkbox reverted unchecked' ($protBox.IsChecked -ne $true)
            # 重新选中后可继续 Prepare，进入复核
            $okBox.IsChecked=$true
            Pump-Dispatcher 800 { $w.Tag.Session.Selected.ContainsKey([string]$okRow.Id) -and $c.PrepareButton.IsEnabled }
            Assert-True 're-check re-enables prepare' ([bool]$c.PrepareButton.IsEnabled)
            # 列表重绘不得自动勾选：触发 ItemsSource 重设，行仍保持已选状态且不新增选择。
            $selectedBefore=$w.Tag.Session.Selected.Count
            $w.Tag.Session.SugDirty=$true
            Pump-Dispatcher 900 { $c.SuggestionsList.Items.Count -eq 3 }
            Assert-Equal 'repaint keeps selection count unchanged' $selectedBefore $w.Tag.Session.Selected.Count
            $okRowAfter=@($c.SuggestionsList.Items | Where-Object {[string]$_.Id -eq [string]$okRow.Id})[0]
            Assert-True 'repaint keeps checked state in row data context' ($okRowAfter.Checked -eq $true)
            Assert-True 'repaint adds no default selection' (@($c.SuggestionsList.Items | Where-Object {$_.Checked}).Count -eq 1)
        } else { Add-CoverageGap '模板 CheckBox 未从虚拟化行容器取得，模板交互（选中/取消/重绘/冻结）断言未执行。'; Assert-True 'template checkbox interaction exercises real WPF template' $false 'no template CheckBox found' }
        $c.PrepareButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 15000 { $c.DraftList.Items.Count -ge 2 }
        Assert-Equal 'review overlay visible' 'Visible' ([string]$c.ApprovalOverlay.Visibility)
        # 复核清单生成后选择冻结：模板 CheckBox 再改也不能变更批准集合。
        $frozenSelected=$w.Tag.Session.Selected.Count
        $okBox2=Get-SuggestionCheckBox $c.SuggestionsList (@($c.SuggestionsList.Items | Where-Object {[string]$_.Id -eq [string]$okRow.Id})[0])
        if($okBox2){ $okBox2.IsChecked=$false; Pump-Dispatcher 500; Assert-Equal 'draft freezes selection against template checkbox uncheck' $frozenSelected $w.Tag.Session.Selected.Count }
        else { Add-CoverageGap '复核后模板 CheckBox 不可重新定位，draft 冻结的模板交互断言未执行。'; Assert-True 'draft freezes selection against template checkbox uncheck' $false 'CheckBox unavailable after draft' }
        Assert-Equal 'review list shows the exact files' 2 $c.DraftList.Items.Count
        Assert-True 'summary states recycle-only and that space is not freed immediately' ($c.DraftSummary.Text -like '*只移入回收站*' -and $c.DraftSummary.Text -like '*不会立即释放*') $c.DraftSummary.Text
        Assert-True 'execute button disabled before confirm' (-not $c.ExecuteButton.IsEnabled)
        Assert-True 'confirm button enabled for a matching DisplayHash' ([bool]$c.ConfirmButton.IsEnabled)
        # 取消：返回修改（不点击确认/第二步；按钮点击会弹模态框，窗口层不自动化）
        $c.BackButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 600 { $c.ApprovalOverlay.Visibility -eq 'Collapsed' }
        Assert-Equal 'back button closes the review overlay' 'Collapsed' ([string]$c.ApprovalOverlay.Visibility)
        Assert-Equal 'window flow sent no Confirm/Execute' 0 ((Count-Op (Join-Path $base 'req-window.log') 'ConfirmApproval')+(Count-Op (Join-Path $base 'req-window.log') 'ExecuteApproved'))
        $closed=$w.Tag.Session.Bridge; $w.Close(); [void]$closed.ClosedTask.Wait(10000)
        Assert-True 'window close releases the host without releasing tasks' ($closed.ClosedTask.IsCompleted -and (Count-Op (Join-Path $base 'req-window.log') 'ReleaseTask') -eq 0)
        Assert-True 'window analyze payload was modelless and Selected' (@(Read-Requests (Join-Path $base 'req-window.log') | Where-Object {$_['Operation'] -eq 'Analyze' -and $_['Payload'].ContainsKey('UseModel')}).Count -eq 0)
    } else { Add-CoverageGap 'COVERAGE GAP (stage only, not final): -LoadGui not set; WPF window assertions were NOT run. run_all declares RequiresGui.'; Assert-True 'WPF window assertions require -LoadGui (RequiresGui)' $false 'LoadGui not set' }

    $after=@(Get-ChildItem -LiteralPath $folder -Recurse -File | ForEach-Object {$_.FullName+'|'+$_.Length+'|'+(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}) -join "`n"
    Assert-True 'sandbox files byte-identical after every flow (nothing recycled)' ($before -eq $after)
}catch{Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
finally{
    foreach($w in $windows){ try{ if($w.IsLoaded){$w.Close()} }catch{} }
    if($s){ try{[void](Close-SjcExplorerSession $s).Wait(10000)}catch{} }
    if($base){ Add-Limitation ('Owned E02 fixture retained for inspection; no automatic recursive cleanup: '+$base) }
}
Complete-TestCase
