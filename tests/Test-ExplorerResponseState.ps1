param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tokens=$null;$errors=$null
$source=Join-Path $Repository 'src\ExplorerGui.ps1'
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Source parser errors'}
# Load function definitions only, not module initializers, WPF, native bridge or Host.
foreach($fn in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
    if($fn.Name -notin @('New-SjcExplorerSession','Open-SjcExplorerWindow')){. ([scriptblock]::Create($fn.Extent.Text))}
}
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed){$checks.Add(@{Name=$Name;Passed=$Passed})}
function Session{
    $s=@{TaskId='22222222-2222-4222-8222-222222222222';State='Ready';Revision=7;GroupsRevision=7;GroupsTick=0;ParentId=4;Coverage=@{};Semantics=@{};Queue=[Collections.Generic.List[object]]::new();GroupsStack=[Collections.Generic.List[long]]::new();EvidenceStack=[Collections.Generic.List[long]]::new();SpaceStack=[Collections.Generic.List[string]]::new();Groups=@();GroupsNext=$null;Space=@();SpaceNext=$null;SpaceRevision=7;SpaceDirty=$false;Analysis=$null;GroupsDirty=$false;EvidenceDirty=$false;ProgressDirty=$false;ApprovalDirty=$false;TaskGen=1;AnalysisGen=1;DraftGen=1;Fault=$null;HostReady=$true;Operations=@('GetProgress','ListTasks','PrepareApproval','InvalidateAnalysis','CancelExecution');Capabilities=@{};LastError='current-error';Evidence=@();InFlight=$null}
    $s.GroupsStack.Add(0);$s.EvidenceStack.Add(0);$s.SpaceStack.Add('')
    Initialize-SjcExplorerApprovalState $s
    $s.Analysis=@{Id='analysis-current';Revision=7;Terminal=$true;Ready=$true;Requested=$true}
    return $s
}
function Req($s,$op,$payload){return @{Op=$op;TaskId=$s.TaskId;Payload=$payload;Gen=(Get-SjcExplorerGenSnapshot $s)}}
$s=Session
$r=Req $s 'GetProgress' @{};$r.TaskId='11111111-1111-4111-8111-111111111111'
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{Task=@{TaskId=$r.TaskId;State='Cancelled';EvidenceRevision=7};Coverage=@{ObservedObjects=99}}}
Check 'Old task progress ignored' ($s.State -eq 'Ready' -and $s.Coverage.Count -eq 0)
Receive-SjcExplorerFailure $s $r 'old-error'
Check 'Old task failure preserves current error' ($s.LastError -eq 'current-error')
$r=Req $s 'QuerySuggestions' @{AnalysisId='analysis-old';AfterId=$null}
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{Revision=7;Items=@(@{SuggestionId='old'});NextAfterId=$null;AnalysisStatus='Complete'}}
Check 'Old analysis ignored even at same inventory revision' ($s.Suggestions.Count -eq 0)
$r=Req $s 'QuerySuggestions' @{AnalysisId=$s.Analysis.Id;AfterId=$null}
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{Revision=7;Items=@(@{SuggestionId='valid'});NextAfterId='next';AnalysisStatus='Complete'}}
Check 'Current suggestions accepted' ($s.Suggestions.Count -eq 1 -and $s.SugIndex.ContainsKey('valid'))
$s.SugStack.Add('next')
Check 'Old suggestion page rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$r=Req $s 'QueryEvidence' @{ParentId=3;AfterId=0}
Check 'Previous directory evidence rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$s.SugFilesFor='new-group'
$r=Req $s 'QuerySuggestionFiles' @{AnalysisId=$s.Analysis.Id;SuggestionId='old-group';AfterId=$null}
Check 'Previous group file response rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$s.Draft=@{Pending=$true;DraftId=$null}
$r=Req $s 'PrepareApproval' @{AnalysisId=$s.Analysis.Id}
Check 'Current prepare accepted' (Test-SjcExplorerReqOwned $s $r)
Undo-SjcExplorerDraft $s
$s.Draft=@{Pending=$true;DraftId=$null}
Check 'Withdrawn prepare rejected after new pending draft' (-not (Test-SjcExplorerReqOwned $s $r))
$s.Draft=@{Pending=$false;DraftId='new-draft'}
$r=Req $s 'ConfirmApproval' @{DraftId='old-draft'}
Check 'Previous draft confirmation rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$s.Exec=@{Terminal=$false;ApprovalId='new-approval';Entries=[Collections.Generic.List[object]]::new()}
$r=Req $s 'GetExecutionResult' @{ApprovalId='old-approval';AfterEntry=0}
Check 'Previous approval result rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$s.TaskList=@(@{TaskId='other-task';State='Ready'})
Check 'Restore rejected while execution active' (-not (Restore-SjcExplorerTask $s 'other-task'))
$g=$s.DraftGen;Undo-SjcExplorerDraft $s
Check 'Cannot withdraw running execution' ($s.Exec -and $s.DraftGen -eq $g)
$s=Session
$r=Req $s 'ReleaseTask' @{};$r.TaskId='historical-task'
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{Released=$true}}
Check 'Releasing history preserves current task' ($s.TaskId -eq '22222222-2222-4222-8222-222222222222')
$s.Space=@(@{ObjectId='old-space'});$s.SpaceNext='old-cursor'
$r=Req $s 'ReleaseTask' @{}
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{Released=$true}}
Check 'Releasing current task clears space and task state' (-not $s.TaskId -and $s.Space.Count -eq 0 -and $null -eq $s.SpaceNext -and $s.SpaceDirty)
$s=Session;$s.ProgressDirty=$false
$r=Req $s 'GetProgress' @{}
Set-SjcExplorerCurrentTask $s $s.TaskId 'Ready'
Check 'Same task view rebuild invalidates old generation' (-not (Test-SjcExplorerReqOwned $s $r))
Check 'Task restore refreshes progress immediately' $s.ProgressDirty
$r=Req $s 'InvalidateAnalysis' @{AnalysisId='previous'};$r.TaskId='previous-task'
Check 'Previous analysis invalidation remains deliverable' (Test-SjcExplorerReqOwned $s $r)
$r=Req $s 'GetProgress' @{}
Receive-SjcExplorerFailure $s $r 'current-failure'
Check 'Current failure remains visible' ($s.LastError -eq 'current-failure')
$r=@{Op='GetProgress';TaskId=$s.TaskId;Payload=@{}}
Check 'Direct test request without generation remains supported' (Test-SjcExplorerReqOwned $s $r)
$s=Session;$s.State='Paused';$s.TaskList=@(@{TaskId='other-task';State='Ready'})
Add-SjcExplorerRequest $s 'Resume' $s.TaskId @{}
Check 'Pending resume blocks historical task switch' (-not (Restore-SjcExplorerTask $s 'other-task'))
$s=Session;$s.Analysis=$null;$s.BatchGen=2;$s.BatchListGen=1
$s.Batch=@{Id='33333333-3333-4333-8333-333333333333';Persisted=$true;ActiveIntent=$false;Creating=$false;Revision=4;Status='Interrupted';Pending=$false;Entries=[Collections.Generic.List[object]]::new()}
$r=@{Op='GetBatch';TaskId=$null;Payload=@{BatchId=$s.Batch.Id};Gen=(Get-SjcExplorerGenSnapshot $s);PassiveView=$true}
$originalTask=$s.TaskId
$snapshot=@{BatchId=$s.Batch.Id;ScanMode='AllFixedDisks';State='Running';Reason=$null;Revision=5;CreatedUtc='now';UpdatedUtc='now';EntryCount=1;Entries=@(@{EntryIndex=0;RootPath='E:\artificial';TaskId=$null;State='Pending';Reason=$null});CanContinue=$false}
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=$snapshot}
Check 'Historical GetBatch never grants scan intent or changes task' (-not (Test-SjcExplorerBatchActive $s) -and -not $s.Batch.ActiveIntent -and $s.TaskId -eq $originalTask)
$r=Req $s 'GetBatch' @{BatchId=$s.Batch.Id};$r.TaskId=$null;Step-SjcExplorerGen $s 'Batch'
Check 'Previous batch generation rejected' (-not (Test-SjcExplorerReqOwned $s $r))
$s.Batch.ActiveIntent=$true;$s.Batch.Status='Running';$s.Batch.Revision=5
$r=Req $s 'StartBatchEntry' @{BatchId=$s.Batch.Id;EntryIndex=0;ExpectedRevision=5};$r.TaskId=$null
Receive-SjcExplorerResponse $s $r @{Ok=$true;Result=@{BatchId='44444444-4444-4444-8444-444444444444';Revision=6;EntryIndex=0;TaskId='55555555-5555-4555-8555-555555555555';State='Inventory';Reason=$null}}
Check 'Foreign start result cannot switch current task' ($s.TaskId -eq $originalTask)
$s.Queue.Clear();$s.Closing=$false
Receive-SjcExplorerFailure $s $r 'BatchRevisionChanged'
Check 'Revision conflict queues one read only refresh without restart' (-not $s.Batch.ActiveIntent -and @($s.Queue|Where-Object Op -eq 'GetBatch').Count -eq 1 -and @($s.Queue|Where-Object Op -in 'StartBatchEntry','ContinueBatch').Count -eq 0)
$s.TaskList=@();Check 'Missing historical task refuses restore and release without throwing' (-not (Restore-SjcExplorerTask $s 'absent') -and -not (Release-SjcExplorerTask $s 'absent' $true))
$s=Session;$s.Analysis=$null;$s.State='Inventory';$s.Semantics=@{}
$r=@{Task=@{State='Inventory';Reason=$null;EvidenceRevision=8};Coverage=@{ObservedObjects=100};Metrics=@{ElapsedMilliseconds=2000;CommittedBatches=1};Semantics='observed'}
Set-SjcExplorerTaskView $s $r
Check 'Progress consumes actual Host metrics without inventing initial speed' ($s.ScanMetrics.ElapsedMilliseconds -eq 2000 -and $null -eq $s.RecentObjectsPerSecond)
$s.ProgressSample.At=[datetime]::UtcNow.AddSeconds(-2);$r.Coverage.ObservedObjects=300;$r.Metrics.CommittedBatches=2;$r.Metrics.ElapsedMilliseconds=4000
Set-SjcExplorerTaskView $s $r
Check 'Recent speed reflects committed object delta' ($s.RecentObjectsPerSecond -gt 80 -and $s.RecentObjectsPerSecond -le 110 -and (Get-SjcExplorerProgressDisplayText $s) -like '*个对象/秒*')
$s.InFlight=@{Op='GetProgress'};$s.InFlightStartedAt=[datetime]::UtcNow.AddSeconds(-4)
Check 'Slow response is explained without cancelling or restarting' ((Get-SjcExplorerProgressDisplayText $s) -like '*等待扫描服务回应*' -and $s.Queue.Count -eq 0)
$r.Coverage.ObservedObjects=1;$r.Metrics.ElapsedMilliseconds=10
Set-SjcExplorerTaskView $s $r
Check 'Resume generation reset cannot reuse previous speed' ($null -eq $s.RecentObjectsPerSecond -and $s.ProgressSample.Observed -eq 1)
$s.State='Ready'
Check 'Terminal progress never shows live speed or remaining-time prediction' ((Get-SjcExplorerProgressDisplayText $s) -notlike '*个对象/秒*' -and (Get-SjcExplorerProgressDisplayText $s) -notlike '*剩余*')
Reset-SjcExplorerProgressDisplay $s
Check 'Task view reset clears previous metrics and rate' ($null -eq $s.ScanMetrics -and $null -eq $s.ProgressSample -and $null -eq $s.RecentObjectsPerSecond)

# ---- UI-PREP-01: early return before Begin response, priority cancel, and bounded terminal drain ----
function PrepSession {
    $ps=@{TaskId='11111111-1111-4111-8111-111111111111';HostReady=$true;Fault=$null;Closing=$false;State='Ready';Revision=3;Queue=[Collections.Generic.List[object]]::new();TaskGen=1;AnalysisGen=1;DraftGen=1;BatchGen=1;BatchListGen=1;Batch=$null;StaleDropped=0;LastError=$null;ProgressDirty=$false;ApprovalDirty=$false;InFlight=$null;Stderr=[Collections.Generic.List[string]]::new();Phase='Running';StepCount=0;ProgressTick=0;GroupsTick=0;Operations=@('GetProgress','PrepareApproval','BeginPrepareApproval','GetPreparationProgress','CancelPreparation','QueryApprovalItems','InvalidateAnalysis');Capabilities=@{}}
    $ps.GroupsStack=[Collections.Generic.List[long]]::new();$ps.GroupsStack.Add(0)
    $ps.EvidenceStack=[Collections.Generic.List[long]]::new();$ps.EvidenceStack.Add(0)
    $ps.SpaceStack=[Collections.Generic.List[string]]::new();$ps.SpaceStack.Add('')
    Initialize-SjcExplorerApprovalState $ps
    $ps.Analysis=@{Id='22222222-2222-4222-8222-222222222222';Ready=$true;Terminal=$true;Revision=3}
    $sid='33333333-3333-4333-8333-333333333333'
    $ps.SugIndex[$sid]=@{SuggestionId=$sid;Classification='BuildArtifact';CandidateCount=2;HardProtected=$false;MayPrepareForReview=$true}
    $ps.Selected[$sid]=$true
    return $ps
}
$prep1='44444444-4444-4444-8444-444444444444'
$prep2='55555555-5555-4555-8555-555555555555'
$running1=@{PreparationId=$prep1;Status='Running';Stage='CheckingFiles';CheckedFiles=1;TotalFiles=20;ElapsedMilliseconds=25.0;ErrorCode=$null;Prepared=$null}
$running2=@{PreparationId=$prep2;Status='Running';Stage='CheckingFiles';CheckedFiles=0;TotalFiles=10;ElapsedMilliseconds=5.0;ErrorCode=$null;Prepared=$null}
$cancelled1=@{PreparationId=$prep1;Status='Cancelled';Stage='Cancelled';CheckedFiles=2;TotalFiles=20;ElapsedMilliseconds=40.0;ErrorCode='ExplicitCancellation';Prepared=$null}
$lateReady1=@{PreparationId=$prep1;Status='Ready';Stage='Ready';CheckedFiles=20;TotalFiles=20;ElapsedMilliseconds=50.0;ErrorCode=$null;Prepared=@{DraftId='66666666-6666-4666-8666-666666666666';DisplayHash=('a'*64);CandidateSetHash=('b'*64);LogicalBytes=200;ItemCount=2;RecycleOnly=$true;RecycleEnabled=$false;AlgorithmMode='Heuristic'}}

# 1) Return after PreparationId received sends one CancelPreparation to original task
$ps=PrepSession;[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
Undo-SjcExplorerDraft $ps
$cancels=@($ps.Queue | Where-Object {$_.Op -eq 'CancelPreparation'})
Check 'Return after preparation ID queues single CancelPreparation and removes stale progress poll' ($cancels.Count -eq 1 -and $cancels[0].TaskId -eq $b1.TaskId -and $cancels[0].Payload.PreparationId -eq $prep1 -and $ps.Queue.Count -eq 1 -and -not $ps.Draft)

# 2) Return before Begin response -> late Begin response never resurrects overlay and queues CancelPreparation
$ps=PrepSession;[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
Undo-SjcExplorerDraft $ps
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
$lateCancels=@($ps.Queue | Where-Object {$_.Op -eq 'CancelPreparation' -and $_.Payload.PreparationId -eq $prep1 -and $_.TaskId -eq $b1.TaskId})
Check 'Return before Begin response drops stale overlay and queues compensatory CancelPreparation' (-not $ps.Draft -and $ps.StaleDropped -eq 1 -and $lateCancels.Count -eq 1)

# 3) New Begin already queued after Undo -> late old Begin response -> priority Cancel + bounded Running drain blocks new Begin until terminal
$sentOps=[Collections.Generic.List[string]]::new()
$fakeBridge=[pscustomobject]@{}
$fakeBridge | Add-Member -MemberType ScriptProperty -Name Fault -Value { $null }
$fakeBridge | Add-Member -MemberType ScriptMethod -Name TakeStderr -Value { @() }
$fakeBridge | Add-Member -MemberType ScriptMethod -Name Poll -Value { $null }
$fakeBridge | Add-Member -MemberType ScriptMethod -Name BeginRequest -Value { param($op,$tid,$payload,$timeout) $sentOps.Add($op+':'+$(if($payload.ContainsKey('PreparationId')){$payload['PreparationId']}else{'new'})); return [guid]::NewGuid().ToString('D') }

$ps=PrepSession;$ps['Bridge']=$fakeBridge
[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
Undo-SjcExplorerDraft $ps
Check 'Immediate re-Prepare after Undo queues new Begin' (Request-SjcExplorerPrepare $ps)
$newDraft=$ps.Draft
Check 'New Begin is queued before old Begin responds' ($ps.Queue.Count -eq 1 -and $ps.Queue[0].Op -eq 'BeginPrepareApproval')
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
Check 'Compensatory CancelPreparation is prioritized ahead of queued new Begin without touching new draft' ($ps.Queue.Count -eq 2 -and $ps.Queue[0].Op -eq 'CancelPreparation' -and $ps.Queue[0].Payload.PreparationId -eq $prep1 -and $ps.Queue[1].Op -eq 'BeginPrepareApproval' -and [object]::ReferenceEquals($newDraft,$ps.Draft) -and $null -eq $ps.Draft['PreparationId'])
# Step 1 sends CancelPreparation first, not new Begin
Step-SjcExplorerSession $ps
Check 'CancelPreparation is dispatched before queued new Begin' ($ps.InFlight.Op -eq 'CancelPreparation' -and $sentOps.Count -eq 1 -and $sentOps[0] -eq ('CancelPreparation:'+$prep1))
$cancelReq=$ps.InFlight;$ps.InFlight=$null
Receive-SjcExplorerResponse $ps $cancelReq @{Ok=$true;Result=@{CancellationRequested=$true}}
Check 'CancelPreparation acknowledgement queues abandoned drain poll ahead of new Begin and preserves new draft' ([object]::ReferenceEquals($newDraft,$ps.Draft) -and -not $ps.LastError -and $ps.Queue[0].Op -eq 'GetPreparationProgress' -and $ps.Queue[0]['AbandonedDrain'] -eq $true -and $ps.Queue[1].Op -eq 'BeginPrepareApproval')
# Step 2 sends drain poll; Host reports still Running -> new Begin MUST NOT be sent yet!
Step-SjcExplorerSession $ps
$drainReq1=$ps.InFlight;$ps.InFlight=$null
Receive-SjcExplorerResponse $ps $drainReq1 @{Ok=$true;Result=$running1}
Step-SjcExplorerSession $ps
Check 'While cancelled old preparation is still Running, new Begin is held back' ($null -eq $ps.InFlight -and $ps.AbandonedPrep -ne $null -and $ps.Queue.Count -eq 1 -and $ps.Queue[0].Op -eq 'BeginPrepareApproval' -and ($sentOps -notcontains 'BeginPrepareApproval:new'))
# Force poll interval elapsed; next drain poll returns Ready (or Cancelled) -> old Prepared MUST be discarded and new Begin finally released!
$ps.AbandonedPrep['LastPollUtc']=[datetime]::UtcNow.AddMilliseconds(-200)
Step-SjcExplorerSession $ps
Check 'Next bounded drain poll is sent for still-running old preparation' ($ps.InFlight.Op -eq 'GetPreparationProgress' -and $ps.InFlight['AbandonedDrain'] -eq $true)
$drainReq2=$ps.InFlight;$ps.InFlight=$null
Receive-SjcExplorerResponse $ps $drainReq2 @{Ok=$true;Result=$lateReady1}
Check 'Terminal response on abandoned preparation clears barrier without accepting old Prepared draft' ($null -eq $ps.AbandonedPrep -and [object]::ReferenceEquals($newDraft,$ps.Draft) -and $ps.Draft.Pending -and $null -eq $ps.Draft.DraftId -and -not $ps.Approval -and -not $ps.Exec)
Step-SjcExplorerSession $ps
Check 'Queued new Begin dispatches immediately once old preparation reaches terminal state' ($ps.InFlight.Op -eq 'BeginPrepareApproval' -and $sentOps[$sentOps.Count-1] -eq 'BeginPrepareApproval:new')
$b2=$ps.InFlight;$ps.InFlight=$null
Receive-SjcExplorerResponse $ps $b2 @{Ok=$true;Result=$running2}
Check 'New Begin response binds cleanly to the new draft' ([object]::ReferenceEquals($newDraft,$ps.Draft) -and $ps.Draft['PreparationId'] -eq $prep2 -and -not $ps.LastError)

# 4) Switching task before old Begin responds cancels on original TaskId; unconfirmed cancel failure revokes queued new Begin and reports explicit notice
$ps=PrepSession;$ps['Bridge']=$fakeBridge
[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
$ps.TaskList=@(@{TaskId='77777777-7777-4777-8777-777777777777';State='Ready'})
Check 'Task switch while Begin in flight succeeds' (Restore-SjcExplorerTask $ps '77777777-7777-4777-8777-777777777777')
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
Check 'Late Begin after task switch cancels on original TaskId ahead of InvalidateAnalysis' ($ps.TaskId -eq '77777777-7777-4777-8777-777777777777' -and -not $ps.Draft -and $ps.Queue[0].Op -eq 'CancelPreparation' -and $ps.Queue[0].TaskId -eq '11111111-1111-4111-8111-111111111111')
Receive-SjcExplorerFailure $ps $ps.Queue[0] 'CancelTransportFailure'
Check 'Unconfirmed cancel failure sets explicit PreparationCancelUnconfirmed error and notice' ($null -eq $ps.AbandonedPrep -and $ps.LastError -eq 'PreparationCancelUnconfirmed' -and (Get-SjcExplorerErrorText $ps.LastError) -match '取消未确认' -and $ps['StorageNotice'] -match '取消未确认')

# 5) Deadline / max-poll expiry while still Running: revokes queued new Begin and pending draft, sets explicit notice, never silently dispatches new Begin, and leaves manual retry available
$sentDeadline=[Collections.Generic.List[string]]::new()
$deadlineBridge=[pscustomobject]@{}
$deadlineBridge | Add-Member -MemberType ScriptProperty -Name Fault -Value { $null }
$deadlineBridge | Add-Member -MemberType ScriptMethod -Name TakeStderr -Value { @() }
$deadlineBridge | Add-Member -MemberType ScriptMethod -Name Poll -Value { $null }
$deadlineBridge | Add-Member -MemberType ScriptMethod -Name BeginRequest -Value { param($op,$tid,$payload,$timeout) $sentDeadline.Add($op); return [guid]::NewGuid().ToString('D') }

$ps=PrepSession;$ps['Bridge']=$deadlineBridge
[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
Undo-SjcExplorerDraft $ps
[void](Request-SjcExplorerPrepare $ps)
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
Step-SjcExplorerSession $ps
$cReq=$ps.InFlight;$ps.InFlight=$null
Receive-SjcExplorerResponse $ps $cReq @{Ok=$true;Result=@{CancellationRequested=$true}}
Step-SjcExplorerSession $ps
$dReq=$ps.InFlight;$ps.InFlight=$null
$ps.AbandonedPrep['Polls']=149
Receive-SjcExplorerResponse $ps $dReq @{Ok=$true;Result=$running1}
Step-SjcExplorerSession $ps
Check 'Drain poll budget expiry revokes queued BeginPrepareApproval, clears pending draft, and sets explicit unconfirmed-cancel error' (
    $null -eq $ps.AbandonedPrep -and
    $null -eq $ps.Draft -and
    $null -eq $ps.InFlight -and
    (@($ps.Queue | Where-Object {$_.Op -eq 'BeginPrepareApproval'}).Count -eq 0) -and
    ($sentDeadline -notcontains 'BeginPrepareApproval') -and
    $ps.LastError -eq 'PreparationCancelUnconfirmed' -and
    $ps['StorageNotice'] -eq '取消未确认，请关闭并重开探索后重试；未批准或处理文件。'
)
Check 'App is not permanently deadlocked after unconfirmed-cancel expiry: manual re-Prepare remains possible' (Request-SjcExplorerPrepare $ps)

# 6) Foreign TaskId with colliding PreparationId on CancelPreparation / AbandonedDrain cannot mutate current barrier or error
$ps=PrepSession;[void](Request-SjcExplorerPrepare $ps);$b1=$ps.Queue[0];$ps.Queue.Clear();$ps.InFlight=$b1
Undo-SjcExplorerDraft $ps
Receive-SjcExplorerResponse $ps $b1 @{Ok=$true;Result=$running1};$ps.InFlight=$null
$foreignCancel=@{Op='CancelPreparation';TaskId='99999999-9999-4999-8999-999999999999';Payload=@{PreparationId=$prep1}}
Receive-SjcExplorerResponse $ps $foreignCancel @{Ok=$true;Result=@{CancellationRequested=$true}}
Check 'Foreign-task CancelPreparation response cannot mark current AbandonedPrep as acknowledged' ($null -ne $ps.AbandonedPrep -and $ps.AbandonedPrep['CancelAcked'] -eq $false)
Receive-SjcExplorerFailure $ps $foreignCancel 'ForeignCancelFailure'
Check 'Foreign-task CancelPreparation failure cannot clear current AbandonedPrep or set LastError' ($null -ne $ps.AbandonedPrep -and $null -eq $ps.LastError)
$foreignDrain=@{Op='GetPreparationProgress';TaskId='99999999-9999-4999-8999-999999999999';Payload=@{PreparationId=$prep1};AbandonedDrain=$true}
Receive-SjcExplorerResponse $ps $foreignDrain @{Ok=$true;Result=$cancelled1}
Check 'Foreign-task AbandonedDrain response cannot release current AbandonedPrep barrier' ($null -ne $ps.AbandonedPrep)
$result=@{Passed=(@($checks | Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;SourceSHA256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;Checks=@($checks.ToArray());Mode='PureStateOnly';HostStarted=$false;FileOperations=$false}
$result | ConvertTo-Json -Depth 8
if(-not $result.Passed){exit 1}
