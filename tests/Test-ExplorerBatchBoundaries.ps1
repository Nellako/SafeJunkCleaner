param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New evidence required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
$Source=Join-Path $Repository 'src\ExplorerGui.ps1'
$Evidence=$EvidenceDirectory
$before=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
$started=[datetime]::UtcNow.ToString('o')
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed,$Actual){$checks.Add(@{Name=$Name;Passed=$Passed;Actual=$Actual})}
try {
 $tokens=$null;$errors=$null
 $ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
 Check 'Production GUI parses' ($errors.Count -eq 0) ($errors|Out-String)
 foreach($fn in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){
  if($fn.Name -notin 'New-SjcExplorerSession','Open-SjcExplorerWindow'){. ([scriptblock]::Create($fn.Extent.Text))}
 }
 function Session {
  $bridge=[pscustomobject]@{Fault=$null;Sent=[Collections.Generic.List[object]]::new();Responses=[Collections.Generic.List[object]]::new()}
  $bridge|Add-Member ScriptMethod TakeStderr {return @()}
  $bridge|Add-Member ScriptMethod Poll {if($this.Responses.Count){$r=$this.Responses[0];$this.Responses.RemoveAt(0);return $r};return $null}
  $bridge|Add-Member ScriptMethod BeginRequest {param($op,$tid,$payload,$timeout) $this.Sent.Add(@{Op=$op;TaskId=$tid;Payload=$payload});return $true}
  $s=@{TaskId='22222222-2222-4222-8222-222222222222';State='Ready';Revision=7;GroupsRevision=7;GroupsTick=0;ParentId=$null;Coverage=@{};Semantics=@{};Queue=[Collections.Generic.List[object]]::new();GroupsStack=[Collections.Generic.List[long]]::new();EvidenceStack=[Collections.Generic.List[long]]::new();SpaceStack=[Collections.Generic.List[string]]::new();Groups=@();Evidence=@();Space=@();Analysis=$null;TaskGen=1;AnalysisGen=1;DraftGen=1;BatchGen=1;BatchListGen=1;Fault=$null;HostReady=$true;CanInventory=$true;Closing=$false;InFlight=$null;LastError=$null;Operations=@('CreateBatch','ListBatches','GetBatch','ContinueBatch','StartBatchEntry','PauseBatch','CancelBatch','StopBatch');Bridge=$bridge;StepCount=0;Stderr=[Collections.Generic.List[string]]::new();Phase='Ready';ProgressTick=[Environment]::TickCount;StaleDropped=0}
  $s.GroupsStack.Add(0);$s.EvidenceStack.Add(0);$s.SpaceStack.Add('')
  Initialize-SjcExplorerApprovalState $s
  return $s
 }
 function Snapshot($id,$state='Running',$revision=1,$task=$null,$entryState='Pending') {
  return @{BatchId=$id;State=$state;Reason=$null;Revision=$revision;CanContinue=($state -eq 'Paused');Entries=@(@{EntryIndex=0;RootPath=(Join-Path $Evidence 'artificial-first');TaskId=$task;State=$entryState;Reason=$null},@{EntryIndex=1;RootPath=(Join-Path $Evidence 'artificial-second');TaskId=$null;State='Pending';Reason=$null})}
 }
 function TakeReq($s,$op) {
  $req=@($s.Queue|Where-Object Op -eq $op)[0];if(-not $req){throw "Missing queued $op"};[void]$s.Queue.Remove($req);return $req
 }
 function Reply($s,$req,$result){$s.InFlight=$null;Receive-SjcExplorerResponse $s $req @{Ok=$true;Result=$result}}
 function NewCreating {
  $s=Session
  if(-not (Start-SjcExplorerBatch $s @((Join-Path $Evidence 'artificial-first'),(Join-Path $Evidence 'artificial-second')))){throw 'Start rejected'}
  $req=TakeReq $s 'CreateBatch';$s.InFlight=$req
  return $s
 }
 function NewStarting {
  $s=NewCreating;$req=$s.InFlight;Reply $s $req (Snapshot $s.Batch.Id)
  $s.Queue.Clear();Step-SjcExplorerBatch $s
  $req=TakeReq $s 'StartBatchEntry';$s.InFlight=$req
  return $s
 }
 foreach($phase in 'CreateBatch','StartBatchEntry') {
  foreach($control in 'Pause','Cancel') {
   $s=if($phase -eq 'CreateBatch'){NewCreating}else{NewStarting}
   $req=$s.InFlight;$id=$s.Batch.Id;$oldTask=$s.TaskId
   Invoke-SjcExplorerTaskCommand $s $control
   Check "$phase in-flight $control defers control until response" (@($s.Queue|Where-Object Op -in 'PauseBatch','CancelBatch','StartBatchEntry').Count -eq 0 -and $s.TaskId -eq $oldTask) @($s.Queue|ForEach-Object Op)
   Check "$phase in-flight $control preserves response ownership" (Test-SjcExplorerReqOwned $s $req) $s.Batch
   $task='55555555-5555-4555-8555-555555555555'
   if($phase -eq 'CreateBatch') {Reply $s $req (Snapshot $id 'Running' 3)}
   else {Reply $s $req @{BatchId=$id;Revision=3;EntryIndex=0;TaskId=$task;State='Inventory';Reason=$null}}
   $expected=if($control -eq 'Pause'){'PauseBatch'}else{'CancelBatch'}
   $controls=@($s.Queue|Where-Object Op -eq $expected)
   Check "$phase $control queues exactly one control at acknowledged revision" ($controls.Count -eq 1 -and $controls[0].Payload.ExpectedRevision -eq 3 -and $controls[0].Payload.BatchId -eq $id) @($s.Queue|ForEach-Object {@{Op=$_.Op;Revision=$_.Payload.ExpectedRevision}})
   if($phase -eq 'StartBatchEntry') {Check "$phase $control adopts returned task before controlling" ($s.TaskId -eq $task -and $s.Batch.Entries[0].TaskId -eq $task -and $s.Batch.Pending -eq $true) $s.TaskId}
   # Keep a current-task progress request issued before the control response; deliver it late as Ready.
   $late=@{Op='GetProgress';TaskId=$s.TaskId;Payload=@{};Gen=(Get-SjcExplorerGenSnapshot $s)}
   $ctrl=TakeReq $s $expected;$s.InFlight=$ctrl
   $state=if($control -eq 'Pause'){'Paused'}else{'Cancelled'}
   $es=if($phase -eq 'StartBatchEntry'){$state}else{'Pending'}
   $tid=if($phase -eq 'StartBatchEntry'){$task}else{$null}
   Reply $s $ctrl (Snapshot $id $state 4 $tid $es)
   if($phase -eq 'StartBatchEntry') {
    Receive-SjcExplorerResponse $s $late @{Ok=$true;Result=@{Task=@{TaskId=$task;State='Ready';Reason=$null;EvidenceRevision=9};Coverage=@{}}}
   }
   $s.Queue.Clear();for($i=0;$i -lt 15;$i++){Step-SjcExplorerBatch $s}
   Check "$phase $control and late progress never advance second root" (-not $s.Batch.ActiveIntent -and -not $s.Batch.SyncNeeded -and -not $s.Batch.Entries[1].TaskId -and @($s.Queue|Where-Object Op -in 'StartBatchEntry','ContinueBatch','CreateInventory').Count -eq 0) @{State=$s.Batch.Status;Second=$s.Batch.Entries[1];Queue=@($s.Queue|ForEach-Object Op)}
  }
 }
 # Passive running snapshot must never confer intent or change the current task.
 $s=Session;$id='33333333-3333-4333-8333-333333333333';$task=$s.TaskId
 Check 'Historical open accepted' (Open-SjcExplorerHistoricalBatch $s $id) $null
 $req=TakeReq $s 'GetBatch';Reply $s $req (Snapshot $id 'Running' 8)
 for($i=0;$i -lt 12;$i++){Step-SjcExplorerBatch $s}
 Check 'Historical Running Get is passive and preserves selected task' (-not $s.Batch.ActiveIntent -and $s.TaskId -eq $task -and $s.Queue.Count -eq 0) @{Task=$s.TaskId;Active=$s.Batch.ActiveIntent}
 # Stale queued requests are tested through real session dispatcher, not ownership predicate only.
 foreach($op in 'GetBatch','StartBatchEntry','CreateBatch') {
  $s=if($op -eq 'StartBatchEntry'){NewStarting}else{NewCreating}
  if($op -eq 'GetBatch'){$s.InFlight=$null;$s.Queue.Clear();Add-SjcExplorerRequest $s 'GetBatch' $null @{BatchId=$s.Batch.Id};$req=TakeReq $s 'GetBatch'}else{$req=$s.InFlight}
  $s.InFlight=$null;$s.Queue.Clear();$s.Batch.ActiveIntent=$false;$s.Batch.Creating=$false;$s.Batch.Status='Stopped';Step-SjcExplorerGen $s 'Batch';$old=$s.TaskId
  $s.Queue.Add($req);Step-SjcExplorerSession $s
  Check "Stale queued $op is not sent" ($s.Bridge.Sent.Count -eq 0 -and $s.StaleDropped -eq 1 -and $s.TaskId -eq $old) $s.LastStale
  $result=if($op -eq 'StartBatchEntry'){@{BatchId=$s.Batch.Id;Revision=20;EntryIndex=0;TaskId='66666666-6666-4666-8666-666666666666';State='Inventory'}}else{Snapshot $s.Batch.Id 'Running' 20}
  Receive-SjcExplorerResponse $s $req @{Ok=$true;Result=$result}
  Check "Stale $op response never switches task or restores intent" ($s.TaskId -eq $old -and -not $s.Batch.ActiveIntent -and $s.StaleDropped -eq 2) $s.LastStale
 }
 # Each failed mutating operation gets a single passive read; even failure of that read never retries.
 foreach($op in 'StartBatchEntry','PauseBatch','CancelBatch','ContinueBatch') {
  $s=NewStarting;$req=$s.InFlight;$s.InFlight=$null;$s.Queue.Clear()
  $req.Op=$op;$req.Payload.ExpectedRevision=$s.Batch.Revision
  Receive-SjcExplorerFailure $s $req 'BatchRevisionChanged'
  Check "$op failure queues exactly one passive Get" ($s.Queue.Count -eq 1 -and $s.Queue[0].Op -eq 'GetBatch' -and $s.Queue[0].PassiveView -eq $true -and -not $s.Batch.ActiveIntent) @($s.Queue|ForEach-Object Op)
  Step-SjcExplorerSession $s
  $s.Bridge.Responses.Add(@{Ok=$false;ErrorCode='InjectedReadFailure'})
  for($i=0;$i -lt 20;$i++){Step-SjcExplorerSession $s}
  Check "$op recovery Get failure is not resent or restarted" ($s.Bridge.Sent.Count -eq 1 -and $s.Bridge.Sent[0].Op -eq 'GetBatch' -and -not $s.InFlight -and $s.Queue.Count -eq 0) @($s.Bridge.Sent|ForEach-Object Op)
 }
} catch {$checks.Add(@{Name='Unhandled';Passed=$false;Actual=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
$after=(Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
Check 'GUI hash remained frozen throughout test' ($before -eq $after) @{Before=$before;After=$after}
$result=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();Source=$Source;SourceSHA256Before=$before;SourceSHA256After=$after;StartedUtc=$started;EndedUtc=[datetime]::UtcNow.ToString('o');Method='Independent AST-extracted production functions with deterministic fake transport';RealHostExecuted=$false;ProductionWritten=$false;RealUserStateTouched=$false;RealDisksScanned=$false;NativeRecycleCalls=0;FixturesRetained=$true}
$json=$result|ConvertTo-Json -Depth 15
[IO.File]::WriteAllText((Join-Path $Evidence 'result.json'),$json,(New-Object Text.UTF8Encoding($false)))
$json
if(-not $result.Passed){exit 1}
