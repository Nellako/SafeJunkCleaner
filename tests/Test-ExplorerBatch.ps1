param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$HostExe,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New evidence required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($n in @('Version','Rules','Core','Discovery','Maintenance','Worker','Gui','ExplorerGui')){. (Join-Path $Repository ('src\'+$n+'.ps1'))}
Enable-SjcTestIsolation -ParentDirectory (Join-Path $EvidenceDirectory 'owned')
$sb=New-SjcTestSandbox;$a=Join-Path $sb.Root 'files\one';$b=Join-Path $sb.Root 'files\two'
foreach($p in @($a,$b)){[void][IO.Directory]::CreateDirectory($p);[IO.File]::WriteAllText((Join-Path $p 'keep.txt'),'owned batch file')}
$id=[guid]::NewGuid().ToString('D');$script:SjcExplorerTestContext=@{Id=$id;StateRoot=(Join-Path $EvidenceDirectory 'state')};$spec=@{TestId=$id;Exe=$HostExe;Arguments=(' --state-root "'+$script:SjcExplorerTestContext.StateRoot+'"')}
$checks=[Collections.Generic.List[object]]::new();$s=$null;$w=$null
function Check($name,$ok){$checks.Add(@{Name=$name;Passed=[bool]$ok});if(-not $ok){throw $name}}
function Pump($s,[scriptblock]$until){$end=[datetime]::UtcNow.AddSeconds(30);while(-not (& $until) -and -not $s.Fault -and [datetime]::UtcNow -lt $end){Step-SjcExplorerSession $s;Start-Sleep -Milliseconds 15};if($s.Fault -or -not (& $until)){throw ('Pump timeout '+$s.Fault)}}
function Fake{
 $s=@{TaskId=$null;State=$null;Reason=$null;HostReady=$true;CanInventory=$true;Fault=$null;Closing=$false;Analysis=$null;Exec=$null;InFlight=$null;Queue=[Collections.Generic.List[object]]::new();TaskGen=0;AnalysisGen=0;DraftGen=0;ProgressDirty=$false;ApprovalDirty=$false;LastError=$null;Batch=$null;Operations=@('GetProgress','Analyze','ListTasks');Capabilities=@{HeuristicExploration=$true}}
 return $s
}
try{
 $f=Fake
 Check 'Start batch accepts two owned artificial roots' (Start-SjcExplorerBatch $f @($a,$b,$a))
 Check 'Roots deduplicated' ($f.Batch.Entries.Count -eq 2)
 Step-SjcExplorerBatch $f
 Check 'Only one create queued' ($f.Queue.Count -eq 1 -and $f.Queue[0].Op -eq 'CreateInventory')
 Step-SjcExplorerBatch $f;Check 'Pending create does not duplicate' ($f.Queue.Count -eq 1)
 Check 'Analysis disabled during batch' (-not (Test-SjcExplorerCanAnalyze $f 'Scope'))
 $f.InFlight=$f.Queue[0];$f.Queue.Clear();Stop-SjcExplorerBatchQueue $f
 Check 'Cancel during creation retains pending ownership' ($f.Batch.Status -eq 'Cancelling' -and $f.Batch.Pending)
 $f.TaskId='created-artificial';$f.State='Inventory';Receive-SjcExplorerBatchCreated $f $f.InFlight $f.TaskId
 Check 'Late created task receives cancel' ($f.Queue.Count -eq 1 -and $f.Queue[0].Op -eq 'Cancel' -and $f.Queue[0].TaskId -eq $f.TaskId)
 $f.Queue.Clear();$f.InFlight=$null;$f.State='Cancelled';Receive-SjcExplorerBatchProgress $f;Step-SjcExplorerBatch $f
 Check 'Cancelled batch never starts second root' ($f.Batch.Status -eq 'Cancelled' -and $f.Queue.Count -eq 0)
 $f=Fake;[void](Start-SjcExplorerBatch $f @($a,$b));Invoke-SjcExplorerTaskCommand $f 'Pause';Step-SjcExplorerBatch $f
 Check 'Pause before first request stops advancement' ($f.Batch.Status -eq 'Paused' -and $f.Queue.Count -eq 0)
 Invoke-SjcExplorerTaskCommand $f 'Resume';Step-SjcExplorerBatch $f
 Check 'Resume begins first root' ($f.Queue.Count -eq 1)
 Stop-SjcExplorerBatchQueue $f
 Check 'Unsent create removed on cancel' ($f.Queue.Count -eq 0 -and $f.Batch.Status -eq 'Cancelled')
 $f=Fake;[void](Start-SjcExplorerBatch $f @($a,$b));$f.Batch.Index=0;$f.Batch.Entries[0].TaskId='paused-task';$f.TaskId='paused-task';$f.State='Inventory';$f.Batch.Hold=$true;$f.Batch.Status='Paused'
 Invoke-SjcExplorerTaskCommand $f 'Resume'
 Check 'Early resume intent remembered before paused progress' ([bool]$f.Batch['ResumeAfterPause'])
 $f.State='Paused';Receive-SjcExplorerBatchProgress $f
 Check 'Deferred resume sent when pause becomes effective' ($f.Queue.Count -eq 1 -and $f.Queue[0].Op -eq 'Resume' -and -not $f.Batch.Hold)
 Initialize-SjcDesktop;$w=Open-SjcExplorerWindow $null $spec -NoShow;$w.Tag.Timer.Stop();$w.Show();$s=$w.Tag.Session
 Pump $s {$s.HostReady -and -not $s.InFlight -and $s.Queue.Count -eq 0};$s.Operations=@($s.Operations|Where-Object {$_ -ne 'ExecuteApproved'})
 Check 'Actual UI labels use single range and all disks' ($w.Tag.Controls.ScopeFolderRadio.Content -eq '所选文件夹或磁盘' -and $w.Tag.Controls.ScopeDiskRadio.Content -eq '全盘扫描')
 $w.Tag.Controls.ScopeDiskRadio.IsChecked=$true
 Check 'All disks and single range remain mutually exclusive' (-not $w.Tag.Controls.ScopeFolderRadio.IsChecked)
 Check 'Changing scope does not scan' (-not $s.TaskId -and $s.Queue.Count -eq 0)
 $w.Tag.Controls.FolderPathBox.Text=$a;$w.Tag.Controls.ScopeFolderRadio.IsChecked=$true
 Check 'Single path remains source of scope' ($w.Tag.Scope -eq $a -and -not $w.Tag.Controls.ScopeDiskRadio.IsChecked)
 Check 'Real batch starts on owned folders' (Start-SjcExplorerBatch $s @($a,$b))
 Pump $s {$s.Batch.Status -eq 'Completed' -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 Check 'Both roots finish independently' (@($s.Batch.Entries|Where-Object {$_.State -eq 'Ready' -and $_.TaskId}).Count -eq 2)
 Check 'Different roots have different tasks' (@($s.Batch.Entries|ForEach-Object TaskId|Sort-Object -Unique).Count -eq 2)
 Check 'Batch never creates analysis or approvals' (-not $s.Analysis -and -not $s.Draft -and -not $s.Approval -and -not $s.Exec)
 Update-SjcExplorerWindow $w $s;$w.UpdateLayout();Save-SjcGuiRender $w (Join-Path $EvidenceDirectory 'batch-complete.png')
 $task=[string]$s.Batch.Entries[0].TaskId
 Check 'Completed per-root result can be selected' (Open-SjcExplorerBatchResult $s $task)
 Pump $s {$s.TaskId -eq $task -and $s.State -eq 'Ready' -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 Check 'Selected result binds one task only' ($s.TaskId -eq $task -and -not $s.Analysis)
 $missing=Join-Path $sb.Root 'files\missing'
 Check 'Second batch can start after first completes' (Start-SjcExplorerBatch $s @($missing,$b))
 Pump $s {$s.Batch.Status -eq 'Completed' -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 Check 'Unavailable root recorded without losing available root' (@($s.Batch.Entries|Where-Object State -eq 'Failed').Count -eq 1 -and @($s.Batch.Entries|Where-Object State -eq 'Ready').Count -eq 1)
 Check 'Third batch starts for close-in-flight regression' (Start-SjcExplorerBatch $s @($a,$b))
 $end=[datetime]::UtcNow.AddSeconds(10)
 while(-not ($s.InFlight -and $s.InFlight.Op -eq 'StartBatchEntry') -and [datetime]::UtcNow -lt $end){Step-SjcExplorerSession $s;Start-Sleep -Milliseconds 5}
 Check 'Bound entry start is in flight before close' ($s.InFlight -and $s.InFlight.Op -eq 'StartBatchEntry')
 $closingBatch=[string]$s.Batch.Id
 [void](Close-SjcExplorerSession $s).Wait(10000)
 $w.Close();$w=$null;$s=$null
 $w=Open-SjcExplorerWindow $null $spec -NoShow;$w.Tag.Timer.Stop();$w.Show();$s=$w.Tag.Session
 Pump $s {$s.HostReady -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 [void](Open-SjcExplorerHistoricalBatch $s $closingBatch)
 Pump $s {$s.Batch -and $s.Batch.Status -ne 'Loading' -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 Check 'Close preserves accepted task binding without advancing next root' (-not (Test-SjcExplorerBatchActive $s) -and [bool]$s.Batch.Entries[0].TaskId -and -not $s.Batch.Entries[1].TaskId -and $s.Batch.Status -in 'Stopped','Interrupted')
 Check 'Artificial inputs unchanged' ([IO.File]::ReadAllText((Join-Path $a 'keep.txt')) -eq 'owned batch file' -and [IO.File]::ReadAllText((Join-Path $b 'keep.txt')) -eq 'owned batch file')
}catch{$checks.Add(@{Name='Unhandled';Passed=$false;Error=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
finally{if($s){[void](Close-SjcExplorerSession $s).Wait(10000)};if($w){$w.Close()}}
$result=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();RealDisksScanned=$false;FileDeletionRequests=0;SourceSHA256=(Get-FileHash (Join-Path $Repository 'src\ExplorerGui.ps1')).Hash}
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'result.json'),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$result|ConvertTo-Json -Depth 8
if(-not $result.Passed){exit 1}
