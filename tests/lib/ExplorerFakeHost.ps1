#requires -Version 5.1
# 仅供 E01/E02 使用的假探索 Host（JSONL 协议，ContractVersion=3，无模型）。
# 永不触碰文件系统里的用户文件，也没有任何回收能力：回收「结果」只是脚本化的 JSON。
# 参数：Case = plain|hashchange|exec|execunknown|budget|noprog|loadingbudget|cancel|recancel|sugpages|spacestale；Log = 记录每个请求行的文件。
param([string]$Case='plain',[string]$Log='')
$ErrorActionPreference='Stop'
$task='aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'; $analysis='bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb'
$sugOk='cccccccc-3333-4333-8333-cccccccccccc'; $sugProt='dddddddd-4444-4444-8444-dddddddddddd'; $sugBlocked='eeeeeeee-5555-4555-8555-eeeeeeeeeeee'
$draft='ffffffff-6666-4666-8666-ffffffffffff'; $approval='99999999-7777-4777-8777-999999999999'
$hash=('a'*64); $set=('c'*64); $hash2=('b'*64)
$recycle=($Case -in 'exec','execunknown')
$spaceCursor1='c3BhY2UtcGFnZS0y'          # base64url("space-page-2")
$sugCursor1='c3VnLXBhZ2UtMg'             # base64url("sug-page-2")
$rev=[long]3
$progressPolls=0
$analyzeCount=0
$ops=@('Health','CreateInventory','GetProgress','QueryGroups','QueryEvidence','QuerySpace','Pause','Resume','Cancel','ReleaseTask','ListTasks','Analyze','CancelAnalysis','GetAnalysisProgress','QuerySuggestions','QuerySuggestionFiles','InvalidateAnalysis','PrepareApproval','QueryApprovalItems','ConfirmApproval','ExecuteApproved','GetExecutionResult','CancelExecution')
$root='C:\sjc-fake\scope'
$taskObj=@{TaskId=$task;State='Ready';Reason=$null;EvidenceRevision=$rev;CreatedUtc='2026-11-10T00:00:00Z';UpdatedUtc='2026-11-10T00:00:01Z'}
$files=@(
    @{ObjectId='11';Path=($root+'\dist\index.html');FileIdentity='1:1';LogicalBytes=100;ModifiedUtcTicks=1;ContentSha256=$null},
    @{ObjectId='12';Path=($root+'\dist\assets\index-12345678.js');FileIdentity='1:2';LogicalBytes=100;ModifiedUtcTicks=2;ContentSha256=$null})
function Suggestion($id,$cls,$level,$count,$bytes,$prot,$may,$blocked){
    @{SuggestionId=$id;TargetId='7';Classification=$cls;Level=$level;CandidateCount=$count;LogicalBytes=$bytes
      Impact='Exact generated output files only; removing them would require a rebuild/redeployment and may break launch until rebuilt; project/source excluded'
      Doubts=@('Restricted dist evidence only; custom scripts never executed');EvidenceIds=@('DistIndexAndHashedAssets');HardProtected=$prot;SelectedByDefault=$false
      MayPrepareForReview=$may;ApprovalBlockedReason=$blocked;DuplicateSummary=$null}
}
function Out-Line($rid,$tid,$result){
    $o=@{ProtocolVersion=1;RequestId=$rid;TaskId=$tid;Ok=$true;Result=$result}
    [Console]::Out.WriteLine(($o|ConvertTo-Json -Compress -Depth 10)); [Console]::Out.Flush()
}
function Out-Error($rid,$tid,$code){
    $o=@{ProtocolVersion=1;RequestId=$rid;TaskId=$tid;Ok=$false;Error=@{Code=$code}}
    [Console]::Out.WriteLine(($o|ConvertTo-Json -Compress -Depth 10)); [Console]::Out.Flush()
}
function Progress($visited,$queued,$actions,$current,$reason,$more){
    @{VisitedTargets=$visited;QueuedTargets=$queued;CompletedActions=$actions;CurrentTargetId=$current;Reason=$reason;HasMore=$more}
}
function Usage($steps,$meta,$read,$sample,$hashBytes,$hashFiles){
    @{Steps=$steps;MetadataObjects=$meta;ReadFiles=$read;SampleBytes=$sample;HashBytes=$hashBytes;HashFiles=$hashFiles}
}
function Check-Payload($p,[string[]]$required,[string[]]$optional){
    if($null -eq $p){return 'PayloadRequired'}
    $names=@($p.PSObject.Properties.Name)
    $allowed=@($required)+@($optional)
    foreach($k in $names){ if($allowed -notcontains [string]$k){ return 'PayloadFieldNotAllowed:'+$k } }
    foreach($k in $required){ if($names -notcontains $k){ return 'PayloadFieldMissing:'+$k } }
    return $null
}
function Is-ObjectId([string]$s){
    if([string]::IsNullOrEmpty($s) -or $s.Length -gt 80){return $false}
    foreach($c in $s.ToCharArray()){ if(-not ([char]::IsLetterOrDigit($c) -or $c -eq '-' -or $c -eq '_')){return $false} }
    return $true
}
while($true){
    $line=[Console]::In.ReadLine(); if($null -eq $line){break}
    if($Log){ [IO.File]::AppendAllText($Log,$line+"`n",[Text.UTF8Encoding]::new($false)) }
    $req=$line|ConvertFrom-Json; $rid=[string]$req.RequestId; $tid=$req.TaskId; $p=$req.Payload
    try{
        switch([string]$req.Operation){
            'Health'{
                $healthResult=@{ProtocolVersion=1;SchemaVersion=1;ContractVersion=3;Mode='LocalExploration';ModelMode='Absent';AlgorithmMode='Heuristic';MaxMessageBytes=32768;MaxResponseBytes=262144;MaxPageSize=64;MaxCursorLength=2048;Operations=$ops
                    Capabilities=@{InventoryReady=$true;AnalysisFactsReady=$true;HeuristicExploration=$true;ModelReady=$false;ModelAvailable=$false;ModelIncluded=$false;ModelEnabledByDefault=$false;ModelAvailabilityStatus='NotIncluded';ApprovalReady=$true;RecycleAvailable=$recycle;RecycleEnabledByDefault=$false;RecycleEnabled=$false}}
                # 仅用于 E01 信封/门禁反例：这些用例不描述产品行为，只制造畸形响应。
                $raw=$null
                switch($Case){
                    'badid'{ $raw=(@{ProtocolVersion=1;RequestId='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';TaskId=$null;Ok=$true;Result=$healthResult}|ConvertTo-Json -Compress -Depth 10) }
                    'okstring'{ $raw=('{"ProtocolVersion":1,"RequestId":"'+$rid+'","TaskId":null,"Ok":"true","Result":'+($healthResult|ConvertTo-Json -Compress -Depth 10)+'}') }
                    'dupkey'{ $raw=('{"ProtocolVersion":1,"RequestId":"'+$rid+'","TaskId":null,"Ok":true,"Result":{'+'"Mode":"LocalExploration","Mode":"LocalExploration","ProtocolVersion":1,"SchemaVersion":1,"ContractVersion":3,"ModelMode":"Absent","AlgorithmMode":"Heuristic","MaxMessageBytes":32768,"MaxResponseBytes":262144,"MaxPageSize":64,"Operations":'+($ops|ConvertTo-Json -Compress -Depth 4)+'}}') }
                    'missingops'{ $missing=$healthResult.Clone(); [void]$missing.Remove('Operations'); $raw=(@{ProtocolVersion=1;RequestId=$rid;TaskId=$null;Ok=$true;Result=$missing}|ConvertTo-Json -Compress -Depth 10) }
                    'contract2'{ $c2=$healthResult.Clone(); $c2['ContractVersion']=2; $raw=(@{ProtocolVersion=1;RequestId=$rid;TaskId=$null;Ok=$true;Result=$c2}|ConvertTo-Json -Compress -Depth 10) }
                }
                if($raw){ [Console]::Out.WriteLine($raw); [Console]::Out.Flush() }
                else{ Out-Line $rid $null $healthResult }
            }
            'CreateInventory'{ Out-Line $rid $task @{TaskId=$task} }
            'GetProgress'{ Out-Line $rid $task @{Task=$taskObj;Coverage=@{ObservedObjects=5;PendingDirectories=0;SkippedObjects=0;ObservedLogicalBytes=200;ObservedAllocatedBytes=$null;UnknownAllocationObjects=0};Semantics='fake'} }
            'QueryGroups'{ Out-Line $rid $task @{Items=@(
                        @{GroupId=7;Path=($root+'\dist');Coverage='Complete';Reason=$null;ObservedDirectChildren=2;DirectLogicalBytes=200;DirectAllocatedBytes=$null;FactType='DirectoryLayout';Classification='Undetermined';SuggestedAction='None';Protection='None'},
                        @{GroupId=8;Path=$root;Coverage='Complete';Reason=$null;ObservedDirectChildren=3;DirectLogicalBytes=300;DirectAllocatedBytes=$null;FactType='DirectoryLayout';Classification='Undetermined';SuggestedAction='None';Protection='None'});NextAfter=$null;Semantics='fake'} }
            'QueryEvidence'{ Out-Line $rid $task @{Items=@();NextAfter=$null} }
            'QuerySpace'{
                $bad=Check-Payload $p @('AfterCursor','PageSize') @()
                if($bad){ Out-Error $rid $task $bad; break }
                $size=[int]$p.PageSize; if($size -lt 1 -or $size -gt 64){ Out-Error $rid $task 'PageSizeInvalid'; break }
                $after=$p.AfterCursor
                if($null -eq $after){
                    $items=@(
                        @{ObjectId='7';Path=($root+'\dist');Kind='Directory';ObservedLogicalBytes=200;ObservedAllocatedBytes=$null;Coverage='Complete';UnknownAllocationObjects=0;HardLinkedFiles=0},
                        @{ObjectId='9';Path=($root+'\node_modules');Kind='Directory';ObservedLogicalBytes=$null;ObservedAllocatedBytes=$null;Coverage='Partial';UnknownAllocationObjects=3;HardLinkedFiles=1})
                    Out-Line $rid $task @{Items=$items;NextCursor=$spaceCursor1;Revision=$rev;Semantics='Recursive observed metadata, not reclaimable bytes. Directory rows overlap and must not be added together.'}
                } elseif([string]$after -eq $spaceCursor1){
                    $items=@(
                        @{ObjectId='11';Path=($root+'\dist\index.html');Kind='File';ObservedLogicalBytes=100;ObservedAllocatedBytes=4096;Coverage='Complete';UnknownAllocationObjects=0;HardLinkedFiles=0})
                    $shownRev=$rev; if($Case -eq 'spacestale'){$shownRev=$rev+1}
                    Out-Line $rid $task @{Items=$items;NextCursor=$null;Revision=$shownRev;Semantics='Recursive observed metadata, not reclaimable bytes.'}
                } else { Out-Error $rid $task 'InvalidCursor' }
            }
            { $_ -in 'Pause','Resume' }{ Out-Line $rid $task @{Accepted=$true;State='PauseRequested'} }
            'Cancel'{ Out-Line $rid $task @{Accepted=$true;State='CancelRequested'} }
            'ListTasks'{ Out-Line $rid $null @{Items=@($taskObj);NextAfterTaskId=$null} }
            'ReleaseTask'{ Out-Line $rid $task @{Released=$true} }
            'Analyze'{
                $bad=Check-Payload $p @('TargetId','ExpectedEvidenceRevision','ExplorationMode') @()
                if($bad){ Out-Error $rid $task $bad; break }
                $mode=[string]$p.ExplorationMode
                if($mode -notin 'Scope','Selected'){ Out-Error $rid $task 'InvalidExplorationMode'; break }
                if($null -eq $p.TargetId){
                    if($mode -ne 'Scope'){ Out-Error $rid $task 'InvalidExplorationModeTarget'; break }
                } else {
                    if($mode -ne 'Selected' -or -not (Is-ObjectId ([string]$p.TargetId))){ Out-Error $rid $task 'InvalidExplorationModeTarget'; break }
                }
                $progressPolls=0; $analyzeCount++
                # 'recancel'：第一次分析完成并给出建议，第二次分析保持等待取消，用于验证取消后旧建议不残留。
                $thisId=$analysis
                Out-Line $rid $task @{AnalysisId=$thisId;Status='Started';Reason=$null;Usage=$null;HasResult=$false;ExplorationMode=$mode;Progress=(Progress 0 2 0 $null 'Started' $true)}
            }
            'GetAnalysisProgress'{
                $bad=Check-Payload $p @('AnalysisId') @()
                if($bad){ Out-Error $rid $task $bad; break }
                if([string]$p.AnalysisId -ne $analysis){ Out-Error $rid $task 'AnalysisNotOwnedOrMissing'; break }
                $progressPolls++
                if($Case -eq 'recancel' -and $analyzeCount -ge 2){
                    Out-Line $rid $task @{AnalysisId=$analysis;Status='Cancelled';Reason='ExplicitCancellation';Usage=$null;HasResult=$false;ExplorationMode='Scope';Progress=(Progress 2 0 4 $null 'Cancelled' $false)}
                    break
                }
                switch($Case){
                    'cancel'{
                        if($progressPolls -le 2){
                            Out-Line $rid $task @{AnalysisId=$analysis;Status='Running';Reason=$null;Usage=$null;HasResult=$false;ExplorationMode='Scope';Progress=(Progress 2 1 4 '7' 'Running' $true)}
                        } else {
                            Out-Line $rid $task @{AnalysisId=$analysis;Status='Cancelled';Reason='ExplicitCancellation';Usage=$null;HasResult=$false;ExplorationMode='Scope';Progress=(Progress 2 0 4 $null 'Cancelled' $false)}
                        }
                    }
                    # 真正 scheduler 预算耗尽：有完整六计数 Usage，建议页可查询。
                    'budget'{
                        Out-Line $rid $task @{AnalysisId=$analysis;Status='BudgetExhausted';Reason='DurationBudget';Usage=(Usage 12 4096 24 65536 67108864 16);HasResult=$true;ExplorationMode='Scope';Progress=(Progress 12 5 12 '9' 'DurationBudget' $true)}
                    }
                    # 无进展正常结束：同样有 Usage，建议页可查询。
                    'noprog'{
                        Out-Line $rid $task @{AnalysisId=$analysis;Status='NoProgress';Reason='NoNewProbeEvidence';Usage=(Usage 3 20 1 64 0 0);HasResult=$true;ExplorationMode='Scope';Progress=(Progress 3 0 3 $null 'NoNewProbeEvidence' $false)}
                    }
                    # 异步 load/display 超时：终态 BudgetExhausted 但没有任何 Result，Usage=null。
                    # 客户端不得据此请求 QuerySuggestions（Host 会报 AnalysisNotReady）。
                    'loadingbudget'{
                        Out-Line $rid $task @{AnalysisId=$analysis;Status='BudgetExhausted';Reason='DurationBudget';Usage=(Usage 0 0 0 0 0 0);HasResult=$false;ExplorationMode='Scope';Progress=(Progress 0 0 0 $null 'LoadingInventorySnapshot' $false)}
                    }
                    default{
                        if($progressPolls -le 2){
                            Out-Line $rid $task @{AnalysisId=$analysis;Status='Running';Reason=$null;Usage=$null;HasResult=$false;ExplorationMode='Scope';Progress=(Progress 2 1 4 '7' 'Running' $true)}
                        } else {
                            Out-Line $rid $task @{AnalysisId=$analysis;Status='Complete';Reason='NoFurtherEvidence';Usage=(Usage 6 64 2 1024 2048 1);HasResult=$true;ExplorationMode='Scope';Progress=(Progress 5 0 6 $null 'NoFurtherEvidence' $false)}
                        }
                    }
                }
            }
            'CancelAnalysis'{
                $bad=Check-Payload $p @('AnalysisId') @()
                if($bad){ Out-Error $rid $task $bad; break }
                if([string]$p.AnalysisId -ne $analysis){ Out-Error $rid $task 'AnalysisNotOwnedOrMissing'; break }
                Out-Line $rid $task @{CancellationRequested=$true}
            }
            'QuerySuggestions'{
                $bad=Check-Payload $p @('AnalysisId','AfterId','PageSize') @()
                if($bad){ Out-Error $rid $task $bad; break }
                if([string]$p.AnalysisId -ne $analysis){ Out-Error $rid $task 'AnalysisNotOwnedOrMissing'; break }
                $all=@(
                    (Suggestion $sugOk 'BuildArtifact' 'ReviewSuggested' 2 200 $false $true $null),
                    (Suggestion $sugProt 'UserData' 'OrganizeOpportunity' 0 0 $true $false 'DeterministicProtectionOrExecutionPolicy'),
                    (Suggestion $sugBlocked 'Cache' 'ReviewSuggested' 1 50 $false $false 'DeterministicProtectionOrExecutionPolicy'))
                if($Case -eq 'sugpages'){
                    if($null -eq $p.AfterId){ $items=@($all[0]); $next=$sugCursor1 }
                    elseif([string]$p.AfterId -eq $sugCursor1){ $items=@($all[1],$all[2]); $next=$null }
                    else { Out-Error $rid $task 'InvalidCursor'; break }
                } else { $items=$all; $next=$null }
                Out-Line $rid $task @{Items=$items;NextAfterId=$next;AnalysisStatus='Complete';Revision=$rev;Sort='review-logical-desc-stableid-v1';CursorSchema='opaque-hmac-v1'}
            }
            'QuerySuggestionFiles'{
                $bad=Check-Payload $p @('AnalysisId','SuggestionId','AfterId','PageSize') @()
                if($bad){ Out-Error $rid $task $bad; break }
                if([string]$p.AnalysisId -ne $analysis){ Out-Error $rid $task 'AnalysisNotOwnedOrMissing'; break }
                Out-Line $rid $task @{Items=$files;NextAfterId=$null}
            }
            'InvalidateAnalysis'{ Out-Line $rid $task @{Invalidated=$true} }
            'PrepareApproval'{
                $bad=Check-Payload $p @('AnalysisId','SuggestionIds','ExpectedEvidenceRevision') @()
                if($bad){ Out-Error $rid $task $bad; break }
                Out-Line $rid $task @{DraftId=$draft;DisplayHash=$hash;CandidateSetHash=$set;LogicalBytes=200;ItemCount=2;RecycleOnly=$true;AlgorithmMode='Heuristic';RecycleEnabled=$recycle}
            }
            'QueryApprovalItems'{
                $shown=$hash; if($Case -eq 'hashchange'){$shown=$hash2}
                $items=@($files | ForEach-Object { @{SuggestionId=$sugOk;File=@{ObjectId=$_.ObjectId;Path=$_.Path;Identity=$_.FileIdentity;Size=$_.LogicalBytes;ModifiedUtc='2026-11-10T00:00:00Z'};Ancestors=@(@{Path=$root;Identity='1:0'});RetainedCopies=@()} })
                Out-Line $rid $task @{DisplayHash=$shown;CandidateSetHash=$set;LogicalBytes=200;Items=$items;NextAfter=$null}
            }
            'ConfirmApproval'{
                $bad=Check-Payload $p @('DraftId','DisplayHash') @()
                if($bad){ Out-Error $rid $task $bad; break }
                if([string]$p.DisplayHash -ne $hash){ Out-Error $rid $task 'DisplayedSnapshotMismatch' }
                else{ Out-Line $rid $task @{ApprovalId=$approval;RecycleEnabled=$recycle;CanExecute=$recycle} }
            }
            'ExecuteApproved'{
                if(-not $recycle){ Out-Error $rid $task 'RecycleDisabledNoClaimConsumed' }
                else{ Out-Line $rid $task @{ExecutionId=$approval;Status='Queued';RecycleEnabled=$true} }
            }
            'GetExecutionResult'{
                if($Case -eq 'execunknown'){ Out-Line $rid $task @{Status='Completed';Entries=@(@{ObjectId='11';Status='Recycled';Reason='';LogicalBytes=100});NextAfter=$null;RecycledLogicalBytes=100;RecycleEnabled=$true} }
                else{ Out-Line $rid $task @{Status='PartialOrInterrupted';Entries=@(@{ObjectId='11';Status='Recycled';Reason='';LogicalBytes=100},@{ObjectId='12';Status='Skipped';Reason='FileInUse';LogicalBytes=0});NextAfter=$null;RecycledLogicalBytes=100;RecycleEnabled=$true} }
            }
            'CancelExecution'{ Out-Line $rid $task @{CancellationRequested=$true} }
            default{ Out-Error $rid $task 'UnknownOperation' }
        }
    }catch{ Out-Error $rid $task 'FakeHostRequestInvalid' }
}
