#requires -Version 5.1
# E01: 深度探索（只读工作台）桥接、启动门禁与入口——0.14 无模型/启发式契约。
# 覆盖：重复键拒绝、按 Operation 的 Result 必需字段（ContractVersion=3、ModelMode=Absent、AlgorithmMode=Heuristic、
# Analyze/GetAnalysisProgress 的 ExplorationMode+Progress、CancelAnalysis、QuerySpace、opaque cursor 绑定）、
# 载荷白名单（UseModel 本地拒绝）、清单/hash 启动门禁（ContractVersion 3）、假 Host 信封严格性、
# 真实开发 Host 清点+递归空间分页+Scope 分析（runtime 未 ready 时记 CoverageGap 而非静默通过）、
# 真实 WPF 入口/单实例/DispatcherTimer/新控件（无模型开关）与关闭释放。
# 不扫描用户目录；本用例自建 sjc-e01-* 夹具保留供检查，不做自动递归清理。
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
. (Join-Path $RepoRoot 'src\ExplorerGui.ps1')
$base=$null;$s=$null;$app=$null;$windows=New-Object 'System.Collections.Generic.List[object]'
function Pump($S,[scriptblock]$Cond,[int]$Seconds=20){$end=[datetime]::UtcNow.AddSeconds($Seconds);while(-not (& $Cond) -and [datetime]::UtcNow -lt $end -and -not $S.Fault){[void](Step-SjcExplorerSession $S);Start-Sleep -Milliseconds 30}}
function Pump-Dispatcher([int]$Milliseconds,[scriptblock]$Until){
    $frame=[Windows.Threading.DispatcherFrame]::new();$end=[datetime]::UtcNow.AddMilliseconds($Milliseconds)
    $t=[Windows.Threading.DispatcherTimer]::new();$t.Interval=[TimeSpan]::FromMilliseconds(50)
    $t.Add_Tick({if(([datetime]::UtcNow -gt $end) -or ($Until -and (& $Until))){$frame.Continue=$false}}.GetNewClosure());$t.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame);$t.Stop()
}
function ConvertFrom-JsonLoose([string]$Text){(New-Object System.Web.Script.Serialization.JavaScriptSerializer).DeserializeObject($Text)}
function Test-Rejects([string]$Name,[string]$Op,[string]$Json,[string]$TaskId=$null){
    $threw=$false;$msg=''
    try{[SjcResultSchema]::Validate($Op,[Collections.Generic.IDictionary[string,object]](ConvertFrom-JsonLoose $Json),$TaskId)}catch{$threw=$true;$msg=$_.Exception.Message}
    Assert-True $Name $threw ('expected rejection; got acceptance; ' + $msg)
}
function Test-Accepts([string]$Name,[string]$Op,[string]$Json,[string]$TaskId=$null){
    $threw=$false;$msg=''
    try{[SjcResultSchema]::Validate($Op,[Collections.Generic.IDictionary[string,object]](ConvertFrom-JsonLoose $Json),$TaskId)}catch{$threw=$true;$msg=$_.Exception.Message}
    Assert-True $Name (-not $threw) $msg
}
function Read-RequestLog([string]$Log){
    $ser=New-Object System.Web.Script.Serialization.JavaScriptSerializer
    if(-not (Test-Path -LiteralPath $Log)){return @()}
    @(Get-Content -LiteralPath $Log -Encoding UTF8 | Where-Object {$_} | ForEach-Object {$ser.DeserializeObject($_)})
}
function Start-FakeHost([string]$Case){
    $log=Join-Path $base ('e01-'+$Case+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.log')
    $spec=@{TestId=$id;Exe=$psExe;Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$fake+'" '+$Case+' "'+$log+'"')}
    $f=New-SjcExplorerSession $spec $null
    Pump $f {$f.HostReady -or $f.Fault} 20
    return @{S=$f;Log=$log}
}
try{
    Add-Type -AssemblyName System.Web.Extensions
    Initialize-SjcExplorerBridge
    $id=[guid]::NewGuid().ToString('D'); $candidate=Join-Path ([IO.Path]::GetTempPath()) ('sjc-e01-'+$id)
    [void](New-Item -ItemType Directory -Path $candidate -ErrorAction Stop); $base=$candidate
    $folder=Join-Path $base 'scope'; [void](New-Item -ItemType Directory (Join-Path $folder 'sub'))
    1..5|ForEach-Object{Set-Content -LiteralPath (Join-Path $folder "f$_.txt") -Value ('x'*100)}; Set-Content (Join-Path $folder 'sub\a.txt') 'hello'; Set-Content (Join-Path $folder 'sjc-e01-marker.txt') $id
    $stateRoot=Join-Path $base 'state'
    $script:SjcExplorerTestContext=@{Id=$id;StateRoot=$stateRoot;RuntimeCache=$env:SJC_TEST_RUNTIME_CACHE}

    # ---- 1) 重复键 / 非法 JSON ----
    Assert-Equal 'duplicate top-level key rejected' 'ResponseDuplicateKey' ([SjcJsonGuard]::Check('{"a":1,"a":2}'))
    Assert-Equal 'duplicate nested key rejected' 'ResponseDuplicateKey' ([SjcJsonGuard]::Check('{"a":{"b":1,"b":2}}'))
    Assert-Equal 'duplicate key inside array item rejected' 'ResponseDuplicateKey' ([SjcJsonGuard]::Check('{"a":[{"x":1,"x":2}]}'))
    Assert-True 'same key in sibling objects allowed' ($null -eq [SjcJsonGuard]::Check('{"a":[{"x":1},{"x":2}],"b":{"x":1}}'))
    Assert-True 'truncated JSON rejected' ($null -ne [SjcJsonGuard]::Check('{"a":1'))

    # ---- 2) Result 必需字段（无模型 ContractVersion=3）----
    $tid='11111111-2222-4333-8444-555555555555'; $aid='33333333-2222-4333-8444-111111111111'
    $ops='["Health","CreateInventory","GetProgress","QueryGroups","QueryEvidence","QuerySpace","Pause","Resume","Cancel","ReleaseTask","Analyze","CancelAnalysis","GetAnalysisProgress","QuerySuggestions","QuerySuggestionFiles","InvalidateAnalysis","PrepareApproval","QueryApprovalItems","ConfirmApproval"]'
    $caps='{"InventoryReady":true,"AnalysisFactsReady":true,"HeuristicExploration":true,"ModelReady":false,"ModelAvailable":false,"ModelIncluded":false,"ModelEnabledByDefault":false,"ModelAvailabilityStatus":"NotIncluded","ApprovalReady":true,"RecycleAvailable":false,"RecycleEnabled":false}'
    $health='{"ProtocolVersion":1,"SchemaVersion":1,"ContractVersion":3,"Mode":"LocalExploration","ModelMode":"Absent","AlgorithmMode":"Heuristic","MaxMessageBytes":32768,"MaxResponseBytes":262144,"MaxPageSize":64,"MaxCursorLength":2048,"Operations":'+$ops+',"Capabilities":'+$caps+'}'
    Test-Accepts 'Health ContractVersion 3 with Absent/Heuristic and full Capabilities accepted' 'Health' $health
    Test-Rejects 'Health ContractVersion 2 rejected' 'Health' ($health.Replace('"ContractVersion":3','"ContractVersion":2'))
    Test-Rejects 'Health without ModelMode rejected' 'Health' $health.Replace('"ModelMode":"Absent",','')
    Test-Rejects 'Health with ModelMode Included rejected' 'Health' $health.Replace('"ModelMode":"Absent"','"ModelMode":"Included"')
    Test-Rejects 'Health without AlgorithmMode rejected' 'Health' $health.Replace('"AlgorithmMode":"Heuristic",','')
    Test-Rejects 'Health with legacy model algorithm rejected' 'Health' $health.Replace('"AlgorithmMode":"Heuristic"','"AlgorithmMode":"LocalModel"')
    Test-Rejects 'Health missing Operations rejected' 'Health' '{"ProtocolVersion":1,"SchemaVersion":1,"ContractVersion":3,"Mode":"LocalExploration","ModelMode":"Absent","AlgorithmMode":"Heuristic","MaxMessageBytes":32768,"MaxResponseBytes":262144,"MaxPageSize":64}'
    Test-Rejects 'Health Operations missing a required operation rejected' 'Health' $health.Replace($ops,'["Health"]')
    Test-Rejects 'Health page size above 64 rejected' 'Health' $health.Replace('"MaxPageSize":64','"MaxPageSize":65')
    Test-Rejects 'Health without Capabilities rejected' 'Health' $health.Replace(',"Capabilities":'+$caps,'')
    Test-Rejects 'Health without HeuristicExploration capability rejected' 'Health' $health.Replace('"HeuristicExploration":true,','')
    Test-Rejects 'Health declaring HeuristicExploration=false rejected' 'Health' $health.Replace('"HeuristicExploration":true','"HeuristicExploration":false')
    foreach($flag in 'ModelIncluded','ModelReady','ModelAvailable','ModelEnabledByDefault'){
        Test-Rejects ('Health declaring '+$flag+'=true rejected (model must not be advertised)') 'Health' $health.Replace('"'+$flag+'":false','"'+$flag+'":true')
    }
    Test-Rejects 'CreateInventory missing TaskId rejected' 'CreateInventory' '{}' $tid
    Test-Rejects 'CreateInventory TaskId differing from envelope rejected' 'CreateInventory' '{"TaskId":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}' $tid
    Test-Accepts 'CreateInventory matching TaskId accepted' 'CreateInventory' ('{"TaskId":"'+$tid+'"}') $tid
    $task='{"TaskId":"'+$tid+'","State":"Ready","Reason":null,"EvidenceRevision":3,"CreatedUtc":"2026-11-10T00:00:00Z","UpdatedUtc":"2026-11-10T00:00:01Z"}'
    $cov='{"ObservedObjects":4,"PendingDirectories":0,"SkippedObjects":0,"ObservedLogicalBytes":15,"ObservedAllocatedBytes":null,"UnknownAllocationObjects":0}'
    Test-Accepts 'GetProgress valid accepted' 'GetProgress' ('{"Task":'+$task+',"Coverage":'+$cov+',"Semantics":"x"}') $tid
    Test-Rejects 'GetProgress missing Coverage rejected' 'GetProgress' ('{"Task":'+$task+'}') $tid
    Test-Rejects 'GetProgress Task id differing from envelope rejected' 'GetProgress' ('{"Task":'+$task.Replace($tid,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')+',"Coverage":'+$cov+'}') $tid

    # 2a) 空间排行：递归观察摘要 + 不透明游标
    $spaceItem='{"ObjectId":"7","Path":"C:\\x\\dist","Kind":"Directory","ObservedLogicalBytes":200,"ObservedAllocatedBytes":null,"Coverage":"Complete","UnknownAllocationObjects":0,"HardLinkedFiles":0}'
    $cursor=('A'*64)
    Test-Accepts 'QuerySpace page accepted with opaque cursor' 'QuerySpace' ('{"Items":['+$spaceItem+'],"NextCursor":"'+$cursor+'","Revision":3,"Semantics":"recursive observed metadata"}') $tid
    Test-Accepts 'QuerySpace nullable allocation and null cursor accepted' 'QuerySpace' ('{"Items":['+$spaceItem+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace missing HardLinkedFiles rejected' 'QuerySpace' ('{"Items":['+$spaceItem.Replace(',"HardLinkedFiles":0','')+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace missing UnknownAllocationObjects rejected' 'QuerySpace' ('{"Items":['+$spaceItem.Replace(',"UnknownAllocationObjects":0','')+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace string byte count rejected' 'QuerySpace' ('{"Items":['+$spaceItem.Replace('"ObservedLogicalBytes":200','"ObservedLogicalBytes":"200"')+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace negative allocated bytes rejected' 'QuerySpace' ('{"Items":['+$spaceItem.Replace('"ObservedAllocatedBytes":null','"ObservedAllocatedBytes":-1')+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace missing Revision rejected' 'QuerySpace' ('{"Items":['+$spaceItem+'],"NextCursor":null,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace cursor longer than 2048 rejected' 'QuerySpace' ('{"Items":[],"NextCursor":"'+('A'*2049)+'","Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace cursor with non-base64url char rejected' 'QuerySpace' ('{"Items":[],"NextCursor":"abc=def","Revision":3,"Semantics":"s"}') $tid
    Test-Rejects 'QuerySpace 65 items rejected' 'QuerySpace' ('{"Items":['+(($spaceItem+',')*65).TrimEnd(',')+'],"NextCursor":null,"Revision":3,"Semantics":"s"}') $tid

    # 2b) Analyze / GetAnalysisProgress：ExplorationMode + Progress，无 ModelStatus/UseModel
    $prog='{"VisitedTargets":2,"QueuedTargets":1,"CompletedActions":4,"CurrentTargetId":"7","Reason":"Started","HasMore":true}'
    $usage='{"Steps":6,"MetadataObjects":64,"ReadFiles":2,"SampleBytes":1024,"HashBytes":2048,"HashFiles":1}'
    Test-Accepts 'Analyze Scope result (null TargetId, HasResult=false at start) accepted' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","Reason":null,"Usage":null,"HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Accepts 'Analyze Selected result accepted' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","Reason":null,"Usage":null,"HasResult":false,"ExplorationMode":"Selected","Progress":'+$prog+'}') $tid
    Test-Rejects 'Analyze without HasResult rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","Reason":null,"Usage":null,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'Analyze with non-boolean HasResult rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","Reason":null,"Usage":null,"HasResult":"false","ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'Analyze without ExplorationMode rejected (legacy model result)' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","ModelStatus":"NotRequested","Mode":"DeterministicFactsOnly"}') $tid
    Test-Rejects 'Analyze with unknown ExplorationMode rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","HasResult":false,"ExplorationMode":"All","Progress":'+$prog+'}') $tid
    Test-Rejects 'Analyze without Progress rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","HasResult":false,"ExplorationMode":"Scope"}') $tid
    Test-Rejects 'Analyze Progress without HasMore rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog.Replace(',"HasMore":true','')+'}') $tid
    Test-Rejects 'Analyze Progress with negative counter rejected' 'Analyze' ('{"AnalysisId":"'+$aid+'","Status":"Started","HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog.Replace('"VisitedTargets":2','"VisitedTargets":-1')+'}') $tid
    Test-Accepts 'GetAnalysisProgress Running accepted with null Usage and HasResult=false' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Running","Reason":null,"Usage":null,"HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Accepts 'GetAnalysisProgress Complete accepted with six usage counters and HasResult=true' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Complete","Reason":"NoFurtherEvidence","Usage":'+$usage+',"HasResult":true,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Accepts 'GetAnalysisProgress Cancelled accepted (HasResult=false)' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Cancelled","Reason":"ExplicitCancellation","Usage":'+$usage+',"HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog.Replace('"HasMore":true','"HasMore":false')+'}') $tid
    Test-Accepts 'GetAnalysisProgress scheduler BudgetExhausted accepted (HasResult=true)' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"BudgetExhausted","Reason":"HeuristicActionBudget","Usage":'+$usage+',"HasResult":true,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Accepts 'GetAnalysisProgress loading-timeout BudgetExhausted accepts diagnostic Usage with HasResult=false' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"BudgetExhausted","Reason":"DurationBudget","Usage":'+$usage+',"HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Accepts 'GetAnalysisProgress Failed accepts Usage and HasResult=false' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Failed","Reason":"AnalysisFailed:InvalidOperationException","Usage":'+$usage+',"HasResult":false,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'GetAnalysisProgress without HasResult rejected' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Complete","Reason":"NoFurtherEvidence","Usage":'+$usage+',"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'GetAnalysisProgress legacy ModelStatus result rejected' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Complete","Reason":null,"ModelStatus":"NotRequested","Usage":null}') $tid
    Test-Rejects 'GetAnalysisProgress usage missing HashFiles rejected' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Complete","Reason":null,"Usage":'+$usage.Replace(',"HashFiles":1','')+',"HasResult":true,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'GetAnalysisProgress usage with string counter rejected' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Complete","Reason":null,"Usage":'+$usage.Replace('"Steps":6','"Steps":"6"')+',"HasResult":true,"ExplorationMode":"Scope","Progress":'+$prog+'}') $tid
    Test-Rejects 'GetAnalysisProgress running without ExplorationMode rejected' 'GetAnalysisProgress' ('{"AnalysisId":"'+$aid+'","Status":"Running","Reason":null,"Usage":null,"HasResult":false,"Progress":'+$prog+'}') $tid
    Test-Accepts 'CancelAnalysis true accepted' 'CancelAnalysis' '{"CancellationRequested":true}' $tid
    Test-Rejects 'CancelAnalysis false rejected (cancellation must be requested)' 'CancelAnalysis' '{"CancellationRequested":false}' $tid
    Test-Rejects 'CancelAnalysis missing CancellationRequested rejected' 'CancelAnalysis' '{}' $tid

    # 2c) QuerySuggestions：opaque cursor + Revision/Sort/CursorSchema
    $sug='{"SuggestionId":"'+$aid+'","TargetId":"7","Classification":"BuildArtifact","Level":"ReviewSuggested","CandidateCount":2,"LogicalBytes":200,"Impact":"x","Doubts":["d"],"HardProtected":false,"SelectedByDefault":false,"EvidenceIds":["e1"],"MayPrepareForReview":true,"ApprovalBlockedReason":null,"DuplicateSummary":null}'
    $sugPage='{"Items":['+$sug+'],"NextAfterId":"'+$cursor+'","AnalysisStatus":"Complete","Revision":3,"Sort":"review-logical-desc-stableid-v1","CursorSchema":"opaque-hmac-v1"}'
    Test-Accepts 'QuerySuggestions page with cursor binding accepted' 'QuerySuggestions' $sugPage $tid
    Test-Rejects 'QuerySuggestions without Revision/Sort/CursorSchema rejected' 'QuerySuggestions' ('{"Items":['+$sug+'],"NextAfterId":null,"AnalysisStatus":"Complete"}') $tid
    Test-Rejects 'QuerySuggestions numeric NextAfterId rejected (no numeric offsets)' 'QuerySuggestions' ('{"Items":['+$sug+'],"NextAfterId":5,"AnalysisStatus":"Complete","Revision":3,"Sort":"s","CursorSchema":"opaque-hmac-v1"}') $tid
    Test-Rejects 'QuerySuggestions cursor longer than 2048 rejected' 'QuerySuggestions' ('{"Items":[],"NextAfterId":"'+('A'*2049)+'","AnalysisStatus":"Complete","Revision":3,"Sort":"s","CursorSchema":"opaque-hmac-v1"}') $tid
    Test-Rejects 'QuerySuggestions legacy ModelStatus-only status rejected' 'QuerySuggestions' ('{"Items":['+$sug+'],"NextAfterId":null,"AnalysisStatus":"Complete","ModelStatus":"NotRequested"}') $tid
    Test-Rejects 'QuerySuggestions integer CursorSchema rejected (current host shape is a token string)' 'QuerySuggestions' ($sugPage.Replace('"CursorSchema":"opaque-hmac-v1"','"CursorSchema":1')) $tid
    Test-Rejects 'suggestion selected by default rejected' 'QuerySuggestions' ($sugPage.Replace('"SelectedByDefault":false','"SelectedByDefault":true')) $tid
    Test-Rejects 'protected but reviewable suggestion rejected' 'QuerySuggestions' ($sugPage.Replace('"HardProtected":false','"HardProtected":true')) $tid
    Test-Rejects 'suggestion with string byte count rejected' 'QuerySuggestions' ($sugPage.Replace('"LogicalBytes":200','"LogicalBytes":"200"')) $tid
    Test-Accepts 'QuerySuggestionFiles page accepted with opaque cursor' 'QuerySuggestionFiles' ('{"Items":[{"ObjectId":"11","Path":"C:\\x","FileIdentity":"1:1","LogicalBytes":100,"ModifiedUtcTicks":1,"ContentSha256":null}],"NextAfterId":"'+$cursor+'"}') $tid
    Test-Rejects 'QuerySuggestionFiles numeric NextAfterId rejected' 'QuerySuggestionFiles' '{"Items":[],"NextAfterId":5}' $tid

    # 2d) PrepareApproval：AlgorithmMode=Heuristic，不再要求 ModelStatus
    $h1=('a'*64)
    $prep='{"DraftId":"'+$aid+'","DisplayHash":"'+$h1+'","CandidateSetHash":"'+$h1+'","LogicalBytes":5,"ItemCount":1,"RecycleOnly":true,"AlgorithmMode":"Heuristic","RecycleEnabled":false}'
    Test-Accepts 'Prepare result AlgorithmMode Heuristic accepted' 'PrepareApproval' $prep $tid
    Test-Rejects 'Prepare result without RecycleOnly=true rejected' 'PrepareApproval' $prep.Replace('"RecycleOnly":true','"RecycleOnly":false') $tid
    Test-Rejects 'Prepare result with short hash rejected' 'PrepareApproval' $prep.Replace('"DisplayHash":"'+$h1+'"','"DisplayHash":"abc"') $tid
    Test-Rejects 'Prepare result with model AlgorithmMode rejected' 'PrepareApproval' $prep.Replace('"AlgorithmMode":"Heuristic"','"AlgorithmMode":"LocalModel"') $tid
    Test-Rejects 'Prepare result without AlgorithmMode rejected' 'PrepareApproval' $prep.Replace(',"AlgorithmMode":"Heuristic"','') $tid
    Test-Accepts 'Confirm result with CanExecute accepted' 'ConfirmApproval' ('{"ApprovalId":"'+$aid+'","CanExecute":false,"RecycleEnabled":false}') $tid
    Test-Rejects 'Confirm result without RecycleEnabled rejected' 'ConfirmApproval' ('{"ApprovalId":"'+$aid+'"}') $tid
    Test-Rejects 'Execution result without Status rejected' 'GetExecutionResult' '{"Entries":[],"NextAfter":null}' $tid
    $storageBase='{"DbBytes":4096,"WalBytes":0,"ShmBytes":0,"LockBytes":0,"TotalBytes":4096,"MaxStateBytes":536870912,"PageSize":4096,"PageCount":1,"FreePages":0,"ReusableBytes":0,"Tasks":1,"Objects":5,"CanCompact":true,"CompactionReason":null,"EstimatedBackupBytes":4096,"EstimatedVacuumBytes":8192,"SafetyReserveBytes":16777216,"EstimatedExtraBytes":16789504,"AvailableDriveBytes":1073741824}'
    Test-Accepts 'GetStorageInfo without optional IndexRepairPending accepted' 'GetStorageInfo' $storageBase
    Test-Accepts 'GetStorageInfo with IndexRepairPending=true accepted' 'GetStorageInfo' ($storageBase.TrimEnd('}')+',"IndexRepairPending":true}')
    Test-Accepts 'GetStorageInfo with IndexRepairPending=false accepted' 'GetStorageInfo' ($storageBase.TrimEnd('}')+',"IndexRepairPending":false}')
    Test-Rejects 'GetStorageInfo with non-bool IndexRepairPending rejected' 'GetStorageInfo' ($storageBase.TrimEnd('}')+',"IndexRepairPending":"true"}')
    Test-Accepts 'ConfigureStorageBudget without optional IndexRepairPending accepted' 'ConfigureStorageBudget' '{"MaxStateBytes":536870912,"SessionOnly":true}'
    Test-Accepts 'ConfigureStorageBudget with IndexRepairPending=true accepted' 'ConfigureStorageBudget' '{"MaxStateBytes":1073741824,"SessionOnly":true,"IndexRepairPending":true}'
    Test-Accepts 'ConfigureStorageBudget with IndexRepairPending=false accepted' 'ConfigureStorageBudget' '{"MaxStateBytes":1073741824,"SessionOnly":true,"IndexRepairPending":false}'
    Test-Rejects 'ConfigureStorageBudget with non-bool IndexRepairPending rejected' 'ConfigureStorageBudget' '{"MaxStateBytes":1073741824,"SessionOnly":true,"IndexRepairPending":1}'

    # ---- 3) 启动门禁：缺清单/缺 hash/不匹配/旧契约一律拒绝 ----
    $script:SjcExplorerTestContext=$null
    Assert-Throws 'LaunchSpec without test context rejected' { Resolve-SjcExplorerLaunch @{TestId=$id;Exe='x';Arguments=''} $null } 'LaunchSpecNotAllowed'
    $script:SjcExplorerTestContext=@{Id=$id;StateRoot=$stateRoot;RuntimeCache=$env:SJC_TEST_RUNTIME_CACHE}
    Assert-Throws 'LaunchSpec with another test id rejected' { Resolve-SjcExplorerLaunch @{TestId=[guid]::NewGuid().ToString('D');Exe='x';Arguments=''} $null } 'LaunchSpecNotAllowed'
    $pkg=Join-Path $base 'pkg'; [void](New-Item -ItemType Directory (Join-Path $pkg 'explorer'))
    Set-Content -LiteralPath (Join-Path $pkg 'explorer\sjc-explorer.exe') -Value 'not a real exe'
    $script:SjcEmbeddedExplorerManifestSha256=$null
    Assert-Throws 'packaged host without embedded manifest hash rejected' { Resolve-SjcExplorerLaunch $null $pkg } 'PackagedManifestHashMissing'
    $script:SjcEmbeddedExplorerManifestSha256=('A'*64)
    Assert-Throws 'packaged host without manifest file rejected' { Resolve-SjcExplorerLaunch $null $pkg } 'JsonFileMissingOrLinked'
    $exeHash=(Get-FileHash -LiteralPath (Join-Path $pkg 'explorer\sjc-explorer.exe') -Algorithm SHA256).Hash
    $manifestPath=Join-Path $pkg 'explorer\host-component-manifest.json'
    [IO.File]::WriteAllText($manifestPath,(@{SchemaVersion=1;ContractVersion=3;ModelMode='Absent';AlgorithmMode='Heuristic';DevelopmentOnly=$true;SelfContained=$true;RuntimeIdentifier='win-x64';RuntimeRoot='.';Launch=@{Executable='sjc-explorer.exe';WorkingDirectory='.';Arguments=@()};Components=@(@{Path='sjc-explorer.exe';Sha256=$exeHash;Bytes=([IO.FileInfo](Join-Path $pkg 'explorer\sjc-explorer.exe')).Length})}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Assert-Throws 'packaged manifest differing from embedded hash rejected' { Resolve-SjcExplorerLaunch $null $pkg } 'PackagedManifestHashMismatch'
    $script:SjcEmbeddedExplorerManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $plan=Resolve-SjcExplorerLaunch $null $pkg
    Assert-Equal 'packaged unsealed self-contained Contract3 candidate resolves when embedded hash matches' 'Packaged' $plan.Kind
    $badManifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $badManifest.ContractVersion=2
    [IO.File]::WriteAllText($manifestPath,($badManifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $script:SjcEmbeddedExplorerManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Assert-Throws 'ContractVersion 2 packaged manifest rejected' { Resolve-SjcExplorerLaunch $null $pkg } 'PackagedManifestFieldsInvalid'
    $badManifest.ContractVersion=3; $badManifest.SelfContained=$false
    [IO.File]::WriteAllText($manifestPath,($badManifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $script:SjcEmbeddedExplorerManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    Assert-Throws 'SDK-dependent manifest is not accepted as packaged apphost' { Resolve-SjcExplorerLaunch $null $pkg } 'PackagedManifestFieldsInvalid'
    $badManifest.SelfContained=$true
    [IO.File]::WriteAllText($manifestPath,($badManifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $script:SjcEmbeddedExplorerManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $plan=Resolve-SjcExplorerLaunch $null $pkg
    $r=[SjcHostVerifier]::Verify([string]$plan.Verifications[0].Root,[string[]]$plan.Verifications[0].Paths,[string[]]$plan.Verifications[0].Hashes,[long[]]$plan.Verifications[0].Sizes,$true,$true,$false,'host-component-manifest.json')
    Assert-True 'packaged components verify' ($null -eq $r) $r
    Set-Content -LiteralPath (Join-Path $pkg 'explorer\extra.dll') -Value 'x'
    $r=[SjcHostVerifier]::Verify([string]$plan.Verifications[0].Root,[string[]]$plan.Verifications[0].Paths,[string[]]$plan.Verifications[0].Hashes,[long[]]$plan.Verifications[0].Sizes,$true,$true,$false,'host-component-manifest.json')
    Assert-True 'unlisted file in runtime root rejected' ($r -like 'UnlistedFile:*') $r
    $extra=Join-Path $pkg 'explorer\extra.dll';$retained=Join-Path $base 'retained-extra.dll'
    [IO.File]::WriteAllText((Join-Path $base 'extra-move.json'),(@{Source=$extra;Destination=$retained;SHA256=(Get-FileHash -LiteralPath $extra -Algorithm SHA256).Hash}|ConvertTo-Json))
    if([IO.File]::Exists($retained) -or -not (Test-SjcNoReparsePath $extra)){throw 'Unsafe test file move'}
    [IO.File]::Move($extra,$retained)
    Set-Content -LiteralPath (Join-Path $pkg 'explorer\sjc-explorer.exe') -Value 'tampered exe!'
    $r=[SjcHostVerifier]::Verify([string]$plan.Verifications[0].Root,[string[]]$plan.Verifications[0].Paths,[string[]]$plan.Verifications[0].Hashes,[long[]]$plan.Verifications[0].Sizes,$true,$true,$false,'host-component-manifest.json')
    Assert-True 'tampered component rejected (size or hash)' ($r -like 'ComponentSizeMismatch:*' -or $r -like 'ComponentHashMismatch:*') $r
    Assert-Throws 'component path traversal rejected' { Convert-SjcExplorerComponents @(@{Path='..\evil.dll';Sha256=('A'*64);Bytes=1}) } 'ComponentPathInvalid'
    Assert-Throws 'component with bad hash rejected' { Convert-SjcExplorerComponents @(@{Path='a.dll';Sha256='xyz';Bytes=1}) } 'ComponentHashInvalid'
    Assert-Throws 'component without Bytes rejected' { Convert-SjcExplorerComponents @(@{Path='a.dll';Sha256=('A'*64)}) } 'ComponentBytesInvalid'
    $real=Join-Path $base 'linkreal'; [void](New-Item -ItemType Directory $real); Set-Content (Join-Path $real 'a.dll') 'x'
    $junction=Join-Path $base 'junction'
    try{
        [void](New-Item -ItemType Junction -Path $junction -Target $real)
        $h=(Get-FileHash -LiteralPath (Join-Path $real 'a.dll') -Algorithm SHA256).Hash
        $r=[SjcHostVerifier]::Verify($junction,[string[]]@('a.dll'),[string[]]@($h),[long[]]@(-1),$true,$false,$false,'')
        Assert-True 'junction runtime root rejected' ($r -eq 'RootOrAncestorLinked') $r
    }finally{ Add-Limitation 'Artificial junction and its target retained; no cleanup performed.' }

    # ---- 4) 假 Host：信封严格 + Contract3 无模型能力声明 ----
    $psExe=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $fake=Join-Path $base 'fake-host.ps1'
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tests\lib\ExplorerFakeHost.ps1') -Destination $fake -ErrorAction Stop
    Assert-True 'fake host fixture present' (Test-Path -LiteralPath $fake)
    foreach($case in @(@('plain',$true),@('badid',$false),@('okstring',$false),@('dupkey',$false),@('missingops',$false),@('contract2',$false))){
        $r=Start-FakeHost $case[0]; $f=$r.S
        Assert-Equal ('fake host health case '+$case[0]+' accepted='+$case[1]) $case[1] ([bool]$f.HostReady) $f.Fault
        if($case[1]){ Assert-True 'accepted health leaves no fault' (-not [bool]$f.Fault) }
        else{ Assert-True ('fault set for '+$case[0]) ([bool]$f.Fault) }
        [void]((Close-SjcExplorerSession $f).Wait(10000))
    }
    # 会话层能力断言（用独立会话，避免上面反例污染）
    $r=Start-FakeHost 'plain'; $s=$r.S; $log=$r.Log
    Assert-True 'fake host ready' $s.HostReady $s.Fault
    Assert-Equal 'host Mode is LocalExploration' 'LocalExploration' $s.Mode
    Assert-True 'capability HeuristicExploration declared true' (Test-SjcExplorerHostCap $s 'HeuristicExploration')
    Assert-True 'capability AnalysisFactsReady declared true' (Test-SjcExplorerHostCap $s 'AnalysisFactsReady')
    Assert-True 'capability ModelIncluded is false' ($s.Capabilities.ContainsKey('ModelIncluded') -and $s.Capabilities['ModelIncluded'] -eq $false)
    Assert-True 'capability ModelReady is false' ($s.Capabilities.ContainsKey('ModelReady') -and $s.Capabilities['ModelReady'] -eq $false)
    Assert-True 'capability ModelAvailable is false' ($s.Capabilities.ContainsKey('ModelAvailable') -and $s.Capabilities['ModelAvailable'] -eq $false)
    Assert-True 'capability ModelEnabledByDefault is false' ($s.Capabilities.ContainsKey('ModelEnabledByDefault') -and $s.Capabilities['ModelEnabledByDefault'] -eq $false)
    Assert-Equal 'model availability status is NotIncluded' 'NotIncluded' ([string]$s.Capabilities['ModelAvailabilityStatus'])
    Assert-True 'no model capability can be treated as available' (-not (Test-SjcExplorerHostCap $s 'ModelAvailable') -and -not (Test-SjcExplorerHostCap $s 'ModelReady'))

    # ---- 5) 载荷白名单：无模型字段、Scope/Selected 目标、取消 ----
    # Analyze 载荷只允许 {TargetId,ExpectedEvidenceRevision,ExplorationMode}；UseModel 必须在本地被拒绝，不落盘到 Host。
    $threw=$false; $msg=''
    try{
        $p=[Collections.Generic.Dictionary[string,object]]::new(); $p['TargetId']=$null; $p['ExpectedEvidenceRevision']=[long]3; $p['ExplorationMode']='Scope'; $p['UseModel']=$true
        [void]$s.Bridge.BeginRequest('Analyze',[string]$s.TaskId,$p,1000)
    }catch{$threw=$true;$msg=$_.Exception.Message}
    Assert-True 'bridge rejects Analyze payload containing UseModel' ($threw -and $msg -like '*PayloadFieldNotAllowed:UseModel*') $msg
    $threw=$false; $msg=''
    try{
        $p=[Collections.Generic.Dictionary[string,object]]::new(); $p['TargetId']=$null; $p['ExpectedEvidenceRevision']=[long]3
        [void]$s.Bridge.BeginRequest('Analyze',[string]$s.TaskId,$p,1000)
    }catch{$threw=$true;$msg=$_.Exception.Message}
    Assert-True 'bridge rejects Analyze without ExplorationMode' ($threw -and $msg -like '*PayloadFieldMissing*') $msg
    $threw=$false; $msg=''
    try{
        $p=[Collections.Generic.Dictionary[string,object]]::new(); $p['AnalysisId']='not-a-guid'
        [void]$s.Bridge.BeginRequest('CancelAnalysis',[string]$s.TaskId,$p,1000)
    }catch{$threw=$true;$msg=$_.Exception.Message}
    Assert-True 'bridge rejects CancelAnalysis with invalid AnalysisId' $threw $msg
    Assert-Equal 'no rejected payload reached the host' 0 (@(Read-RequestLog $log | Where-Object {$_['Operation'] -in 'Analyze','CancelAnalysis'}).Count)
    # 会话层：Scope 无需选中分组；Selected 必须可信 ObjectId；非法模式拒绝。
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    Assert-True 'no group selected yet' ($null -eq $s.ParentId)
    Assert-True 'Scope analysis allowed without any selected group' (Test-SjcExplorerCanAnalyze $s 'Scope')
    Assert-True 'Selected analysis refused without a selected group' (-not (Test-SjcExplorerCanAnalyze $s 'Selected'))
    Assert-True 'unknown exploration mode refused' (-not (Test-SjcExplorerCanAnalyze $s 'All'))
    Select-SjcExplorerGroup $s $s.Groups[0]['GroupId']; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
    Assert-True 'Selected analysis allowed after selecting a directory' (Test-SjcExplorerCanAnalyze $s 'Selected')
    # 取消：CancelAnalysis 已声明时可在运行中请求；未运行/无分析时拒绝。
    Assert-True 'cancel refused without running analysis' (-not (Stop-SjcExplorerAnalysis $s))
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Id -and $s.Analysis.Status -eq 'Running'}
    Assert-True 'scope analyze payload uses null TargetId and Scope mode' ($s.Analysis.TargetId -eq $null -and $s.Analysis.Mode -eq 'Scope')
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 取消路径：假 Host 在第二次进度后返回 Cancelled 终态。
    $r=Start-FakeHost 'cancel'; $s=$r.S; $log=$r.Log
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Id -and $s.Analysis.Status -eq 'Running'} 15
    Assert-True 'cancel requested while running' (Stop-SjcExplorerAnalysis $s)
    Pump $s {$s.Analysis.Terminal} 15
    Assert-Equal 'cancelled status is terminal' 'Cancelled' $s.Analysis.Status
    Assert-True 'cancelled analysis is not ready for suggestions' (-not $s.Analysis.Ready)
    Assert-Equal 'exactly one CancelAnalysis sent' 1 (@(Read-RequestLog $log | Where-Object {$_['Operation'] -eq 'CancelAnalysis'}).Count)
    Assert-True 'second cancel is refused after request' (-not (Stop-SjcExplorerAnalysis $s))
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 预算：BudgetExhausted 是部分完成，不得渲染为成功。
    $r=Start-FakeHost 'budget'; $s=$r.S
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Terminal} 15
    Assert-Equal 'budget status preserved' 'BudgetExhausted' $s.Analysis.Status
    Assert-True 'budget progress reported' ($null -ne $s.Analysis.Progress -and $null -ne $s.Analysis.Usage)
    $txt=Get-SjcExplorerAnalysisStatusText $s.Analysis.Status
    Assert-True 'budget result is described as incomplete, not success' ($txt -like '*预算用尽*' -and $txt -like '*不完整*') $txt
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # 无进展：NoProgress 是正常结束的一种，同样不是“已完成”。
    $r=Start-FakeHost 'noprog'; $s=$r.S
    Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
    [void](Start-SjcExplorerAnalysis $s 'Scope'); Pump $s {$s.Analysis -and $s.Analysis.Terminal} 15
    Assert-Equal 'no-progress status preserved' 'NoProgress' $s.Analysis.Status
    $txt=Get-SjcExplorerAnalysisStatusText $s.Analysis.Status
    Assert-True 'no-progress result does not claim completion' ($txt -notlike '*完成*') $txt
    [void](Close-SjcExplorerSession $s).Wait(10000); $s=$null

    # ---- 6) 真实开发 Host（Contract3 runtime 未 ready 时记 CoverageGap，不静默通过）----
    if(-not $env:SJC_TEST_RUNTIME_CACHE){throw 'Explicit isolated test runtime required'}
    $cacheRoot=Join-Path $env:SJC_TEST_RUNTIME_CACHE 'current.json'
    $devReady=$false
    if(Test-Path -LiteralPath $cacheRoot){
        try{
            $pointer=Get-Content -LiteralPath $cacheRoot -Raw -Encoding UTF8 | ConvertFrom-Json
            $devReady=([int]$pointer.ContractVersion -eq 3)
            if(-not $devReady){ Add-CoverageGap ('真实开发 Host runtime 指针仍为 ContractVersion='+[string]$pointer.ContractVersion+'；Contract3 真实 Host 清点/空间排行/分析未执行。') }
        }catch{ $devReady=$false; Add-CoverageGap ('开发 runtime 指针不可解析：'+$_.Exception.Message) }
    } else { Add-CoverageGap '开发 runtime 指针缺失；Contract3 真实 Host 清点/空间排行/分析未执行。' }
    if($devReady){
        $s=New-SjcExplorerSession $null $RepoRoot
        Assert-Equal 'development plan uses pointer + manifest' 'Development' $s.Launch.Kind
        # 0.14：开发 runtime 也是 self-contained 固定 apphost，验证项只有 Runtime + SourceProvenance，
        # 不再二次验证 ProgramFiles 下的共享 .NET 运行时。
        Assert-Equal 'development plan verifies runtime and source provenance (self-contained apphost)' 2 @($s.Launch.Verifications).Count
        Assert-True 'development plan launches the bundled apphost, not dotnet.exe' ([IO.Path]::GetFileName([string]$s.Launch.Exe) -eq 'sjc-explorer.exe') ([string]$s.Launch.Exe)
        Assert-Equal 'development plan verification names are Runtime and SourceProvenance' 'Runtime,SourceProvenance' (@($s.Launch.Verifications | ForEach-Object {$_.Name}) -join ',')
        $rtv=@($s.Launch.Verifications | Where-Object {$_.Name -eq 'Runtime'})[0]
        Assert-True 'runtime verification lists the bundled host and hostfxr/coreclr' ((@($rtv.Paths) -contains 'sjc-explorer.exe') -and (@($rtv.Paths) -contains 'hostfxr.dll') -and (@($rtv.Paths) -contains 'coreclr.dll'))
        Pump $s {$s.HostReady} 40; Assert-True 'real host health ok' $s.HostReady $s.Fault
        Assert-True 'real host declares HeuristicExploration' (Test-SjcExplorerHostCap $s 'HeuristicExploration')
        Assert-True 'real host declares no model' (-not (Test-SjcExplorerHostCap $s 'ModelIncluded') -and [string]$s.Capabilities['ModelAvailabilityStatus'] -eq 'NotIncluded')
        Assert-True 'real host ListTasks gated by declaration' ((Test-SjcExplorerCanListTasks $s) -eq ($s.Operations -contains 'ListTasks'))
        Start-SjcExplorerInventory $s $folder; Pump $s {$s.State -in 'Ready','Partial','Failed'} 40
        Assert-Equal 'inventory ready' 'Ready' $s.State $s.LastError
        Pump $s {$s.Groups.Count -gt 0 -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
        Assert-True 'groups returned' ($s.Groups.Count -ge 1)
        Select-SjcExplorerGroup $s $s.Groups[0]['GroupId']; Pump $s {$s.Evidence.Count -gt 0}
        Assert-True 'evidence returned' ($s.Evidence.Count -ge 1)
        # 递归空间排行：分页 + 稳定游标，且目录行不得相加。
        Pump $s {$s.Space.Count -gt 0 -and -not $s.InFlight} 20
        Assert-True 'space ranking returned rows' ($s.Space.Count -ge 1)
        Assert-True 'space revision matches inventory revision' ([long]$s.SpaceRevision -eq [long]$s.Revision)
        if($null -ne $s.SpaceNext){
            $first=@($s.Space | ForEach-Object {[string]$_['ObjectId']})
            $firstCursor=[string]$s.SpaceNext
            Assert-True 'first space cursor is opaque base64url within 2048' ($firstCursor.Length -le 2048 -and $firstCursor -match '^[A-Za-z0-9_-]+$')
            Move-SjcExplorerSpacePage $s 1; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
            $second=@($s.Space | ForEach-Object {[string]$_['ObjectId']})
            Assert-True 'next space page differs from the first' ((@($second | Where-Object {$first -notcontains $_}).Count -gt 0) -or ($second.Count -eq 0))
            Move-SjcExplorerSpacePage $s -1; Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
            Assert-Equal 'space previous page restored' ($first -join ',') (@($s.Space | ForEach-Object {[string]$_['ObjectId']}) -join ',')
        } else { Add-Limitation '真实 Host 空间排行只有一页（小沙箱），跨页游标分支未覆盖。' }
        # Scope 分析：不需要选中分组；只要 Host 已 Ready。
        $s.ParentId=$null
        Assert-True 'real Scope analysis starts without a selected group' (Start-SjcExplorerAnalysis $s 'Scope')
        Pump $s {$s.Analysis -and $s.Analysis.Terminal} 60
        Assert-True 'real Scope analysis terminal' ($null -ne $s.Analysis -and $s.Analysis.Terminal) ($s.Analysis.Status+' '+$s.Analysis.ErrorCode)
        Assert-True 'real scope analysis is not Failed' ($s.Analysis.Status -ne 'Failed') ($s.Analysis.Status+' '+$s.Analysis.ErrorCode)
        Assert-True 'no stderr noise' ($s.Stderr.Count -eq 0) ($s.Stderr -join '|')
        $t=Close-SjcExplorerSession $s; Assert-True 'host closed' ($t.Wait(10000))
        Assert-True 'closing twice returns the same task' ([object]::ReferenceEquals($t,(Close-SjcExplorerSession $s)))
        Assert-Equal 'sandbox files untouched' 7 (@(Get-ChildItem -LiteralPath $folder -Recurse -File).Count)
        $s=$null
    }

    # ---- 7) 主窗入口、单实例、真实 DispatcherTimer、新控件（无模型开关）----
    if($LoadGui){
        $r=Start-FakeHost 'plain'; $ws=$r.S; $wlog=$r.Log
        $spec=@{TestId=$id;Exe=$psExe;Arguments=('-NoProfile -ExecutionPolicy Bypass -File "'+$fake+'" plain "'+$wlog+'"')}
        $w=Open-SjcExplorerWindow $null $spec -NoShow; $windows.Add($w); $c=$w.Tag.Controls
        $w.Show()
        Pump-Dispatcher 30000 { $w.Tag.Session.HostReady -or $w.Tag.Session.Fault }
        Assert-True 'window connected to fake host' ($w.Tag.Session.HostReady) $w.Tag.Session.Fault
        Assert-True 'window exposes scope analyze, cancel and space controls' ($c.ContainsKey('ScopeAnalyzeButton') -and $c.ContainsKey('CancelAnalysisButton') -and $c.ContainsKey('SpaceList') -and $c.ContainsKey('SpacePrev') -and $c.ContainsKey('SpaceNext') -and $c.ContainsKey('SpacePageText') -and $c.ContainsKey('SpaceTab') -and $c.ContainsKey('EngineNote'))
        Assert-True 'model checkbox removed from the workbench' (-not $c.ContainsKey('ModelCheck') -and -not $c.ContainsKey('ModelNote'))
        Assert-True 'engine note describes the heuristic engine' ($c.EngineNote.Text -like '*启发式*') $c.EngineNote.Text
        # 范围单选：folder / disk 必须互斥，且切换后 state.Scope 跟着变；全程不得发出 CreateInventory。
        Assert-True 'scope radio group is shared so the two options are mutually exclusive' ([string]$c.ScopeFolderRadio.GroupName -ceq [string]$c.ScopeDiskRadio.GroupName -and [string]$c.ScopeFolderRadio.GroupName -cne '') ([string]$c.ScopeFolderRadio.GroupName)
        Assert-True 'initial scope is the folder option' ($c.ScopeFolderRadio.IsChecked -eq $true -and $c.ScopeDiskRadio.IsChecked -ne $true) ('folder='+[string]$c.ScopeFolderRadio.IsChecked+' disk='+[string]$c.ScopeDiskRadio.IsChecked)
        $diskPick=[string]$c.DiskCombo.SelectedItem
        Assert-True 'disk combo has a selectable fixed disk' (-not [string]::IsNullOrWhiteSpace($diskPick)) $diskPick
        $createBefore=@(Read-RequestLog $wlog | Where-Object {$_['Operation'] -eq 'CreateInventory'}).Count
        # folder -> disk：disk 选中必须把 folder 置 false，且 state.Scope 变成所选磁盘
        $c.ScopeDiskRadio.IsChecked=$true
        Pump-Dispatcher 600 { $w.Tag.Scope -eq 'AllFixedDisks' }
        Assert-True 'selecting the disk option clears the folder option' ($c.ScopeFolderRadio.IsChecked -ne $true) ('folder='+[string]$c.ScopeFolderRadio.IsChecked)
        Assert-True 'disk option is checked' ($c.ScopeDiskRadio.IsChecked -eq $true)
        Assert-Equal 'scope switches to all fixed disks without scanning' 'AllFixedDisks' $w.Tag.Scope
        Assert-Equal 'single scope combines folder and disk' '所选文件夹或磁盘' $c.ScopeFolderRadio.Content
        Assert-Equal 'second scope is all disks' '全盘扫描' $c.ScopeDiskRadio.Content
        # disk -> folder：folder 选中必须把 disk 置 false，且 state.Scope 变回文件夹路径
        $c.FolderPathBox.Text=$folder
        $c.ScopeFolderRadio.IsChecked=$true
        Pump-Dispatcher 600 { $w.Tag.Scope -eq $folder }
        Assert-True 'selecting the folder option clears the disk option' ($c.ScopeDiskRadio.IsChecked -ne $true) ('disk='+[string]$c.ScopeDiskRadio.IsChecked)
        Assert-True 'folder option is checked' ($c.ScopeFolderRadio.IsChecked -eq $true)
        Assert-Equal 'scope switches back to the folder path' $folder $w.Tag.Scope
        # 浏览目录回选：程序设 IsChecked=true（Checked 事件路径，而非 Click）也要刷新 state.Scope
        $c.ScopeDiskRadio.IsChecked=$true
        Pump-Dispatcher 600 { $w.Tag.Scope -eq 'AllFixedDisks' }
        $c.FolderPathBox.Text=$folder
        $c.ScopeFolderRadio.IsChecked=$true
        Pump-Dispatcher 600 { $w.Tag.Scope -eq $folder }
        Assert-Equal 'programmatic re-check of the folder option refreshes scope (Checked, not Click)' $folder $w.Tag.Scope
        Assert-True 'folder and disk options are still mutually exclusive after programmatic changes' ($c.ScopeFolderRadio.IsChecked -eq $true -and $c.ScopeDiskRadio.IsChecked -ne $true)
        Assert-Equal 'switching scope options sends no CreateInventory' $createBefore (@(Read-RequestLog $wlog | Where-Object {$_['Operation'] -eq 'CreateInventory'}).Count)
        $c.FolderPathBox.Text=$folder; $c.ScopeFolderRadio.IsChecked=$true; $w.Tag.Scope=$folder
        Pump-Dispatcher 400 $null
        $c.StartButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 30000 { $w.Tag.Session.State -eq 'Ready' -and $w.Tag.Session.Groups.Count -gt 0 -and $w.Tag.Session.Queue.Count -eq 0 -and -not $w.Tag.Session.InFlight }
        Assert-True 'window inventory ready' ($w.Tag.Session.State -eq 'Ready') $w.Tag.Session.LastError
        Pump-Dispatcher 3000 { $w.Tag.Session.Space.Count -gt 0 -and $c.SpaceList.Items.Count -gt 0 }
        Assert-True 'space ranking listed in the window' ($c.SpaceList.Items.Count -ge 1)
        Assert-True 'space semantics state rows overlap and are not additive' ([string]$w.Tag.Session.Semantics['Space'] -like '*overlap*') ([string]$w.Tag.Session.Semantics['Space'])
        Assert-True 'space rows expose coverage/unknown/hardlink columns' ($null -ne $c.SpaceList.Items[0].Coverage -and $null -ne $c.SpaceList.Items[0].Unknown -and $null -ne $c.SpaceList.Items[0].HardLinks)
        Assert-True 'scope analyze enabled without selecting a group' ([bool]$c.ScopeAnalyzeButton.IsEnabled)
        Assert-True 'single-target analyze disabled without a selected group' (-not $c.AnalyzeButton.IsEnabled)
        $c.ScopeAnalyzeButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Pump-Dispatcher 15000 { $w.Tag.Session.Analysis -and $w.Tag.Session.Analysis.Id }
        $anReq=@(Read-RequestLog $wlog | Where-Object {$_['Operation'] -eq 'Analyze'})[0]
        Assert-True 'scope analyze payload has null TargetId and Scope mode' ($anReq -and $null -eq $anReq['Payload']['TargetId'] -and [string]$anReq['Payload']['ExplorationMode'] -eq 'Scope')
        Assert-True 'scope analyze payload carries no UseModel' (-not $anReq['Payload'].ContainsKey('UseModel'))
        Pump-Dispatcher 3000 { $w.Tag.Session.Analysis -and $w.Tag.Session.Analysis.Status -eq 'Running' }
        Assert-True 'cancel button enabled while analysis is running' ([bool]$c.CancelAnalysisButton.IsEnabled) ([string]$c.CancelAnalysisButton.IsEnabled)
        Assert-Equal 'cancelled analysis never claims completion in the window text' $true (($c.AnalysisText.Text -notlike '*完成*') -or ($w.Tag.Session.Analysis.Status -ne 'Cancelled'))
        $closed=$w.Tag.Session.Bridge
        $w.Close(); [void]$closed.ClosedTask.Wait(10000)
        Assert-True 'closing the window releases the host (task kept in persistent state, not released)' ($closed.ClosedTask.IsCompleted)
        Assert-True 'singleton cleared after close' ($null -eq $script:SjcExplorerSingleton.Window)
        Assert-Equal 'sandbox files untouched by window flow' 7 (@(Get-ChildItem -LiteralPath $folder -Recurse -File).Count)
        [void]((Close-SjcExplorerSession $ws).Wait(10000))
    } elseif(-not $LoadGui) { Add-Limitation 'GUI module not loaded; main-window entry assertions skipped.' }
}catch{Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
finally{
    foreach($w in $windows){ try{ if($w.IsLoaded){$w.Close()} }catch{} }
    if($app){ try{Remove-SjcGuiApp $app;$app.Ui.Window.Close()}catch{} }
    if($s){ try{[void](Close-SjcExplorerSession $s).Wait(10000)}catch{} }
    if($base){ Add-Limitation ('Owned E01 fixture retained for inspection; no automatic recursive cleanup: '+$base) }
}
Complete-TestCase
