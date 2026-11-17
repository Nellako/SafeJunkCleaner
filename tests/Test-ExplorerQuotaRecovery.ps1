param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$HostExe,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New evidence required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($n in @('Version','Rules','Core','Discovery','Maintenance','Worker','Gui','ExplorerGui')){. (Join-Path $Repository ('src\'+$n+'.ps1'))}
Enable-SjcTestIsolation -ParentDirectory (Join-Path $EvidenceDirectory 'owned')
$sb=New-SjcTestSandbox;$folder=Join-Path $sb.Root 'files';[IO.File]::WriteAllText((Join-Path $folder 'keep.txt'),'owned history file')
$id=[guid]::NewGuid().ToString('D');$state=Join-Path $EvidenceDirectory 'state';$script:SjcExplorerTestContext=@{Id=$id;StateRoot=$state};$spec=@{TestId=$id;Exe=$HostExe;Arguments=(' --state-root "'+$state+'"')}
$checks=[Collections.Generic.List[object]]::new();$w=$null;$s=$null
function Check($name,$ok){$checks.Add(@{Name=$name;Passed=[bool]$ok});if(-not $ok){throw $name}}
function Pump($s,[scriptblock]$until){$end=[datetime]::UtcNow.AddSeconds(30);while(-not (& $until) -and -not $s.Fault -and [datetime]::UtcNow -lt $end){Step-SjcExplorerSession $s;Start-Sleep -Milliseconds 5};if($s.Fault -or -not (& $until)){throw ('Pump timeout '+$s.Fault)}}
try{
 Initialize-SjcDesktop;$w=Open-SjcExplorerWindow $null $spec -NoShow;$w.Tag.Timer.Stop();$w.Show();$s=$w.Tag.Session
 Pump $s {$s.HostReady -and $s.Queue.Count -eq 0 -and -not $s.InFlight};$s.Operations=@($s.Operations|Where-Object {$_ -ne 'ExecuteApproved'})
 $ids=[Collections.Generic.List[string]]::new()
 for($i=0;$i -lt 65;$i++){
  Start-SjcExplorerInventory $s $folder
  Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
  $ids.Add([string]$s.TaskId)
 }
 Check 'More than eight task creations succeed' ($ids.Count -eq 65 -and @($ids|Sort-Object -Unique).Count -eq 65 -and -not $s.LastError)
 Request-SjcExplorerTaskList $s 0;Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
 $first=@($s.TaskList|ForEach-Object {$_['TaskId']});Check 'First page has sixty-four history records' ($first.Count -eq 64 -and $s.TaskListNext)
 Request-SjcExplorerTaskList $s 1;Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
 $last=@($s.TaskList|ForEach-Object {$_['TaskId']});Check 'Second page has remaining history' ($last.Count -eq 1 -and -not $s.TaskListNext)
 Check 'Pages are disjoint and complete' (@(@($first)+@($last)|Sort-Object -Unique).Count -eq 65)
 Update-SjcExplorerWindow $w $s
 Check 'History label does not imply count limit or global total' ($w.Tag.Controls.HistoryNote.Text -like '*本页 1 条*' -and $w.Tag.Controls.HistoryNote.Text -like '*不限制*' -and $w.Tag.Controls.HistoryNote.Text -notlike '*/8*')
 Check 'Release requires explicit confirmation' (-not (Release-SjcExplorerTask $s ([string]$last[0]) $false))
 [void](Close-SjcExplorerSession $s).Wait(10000);$w.Close();$s=$null;$w=$null
 $w=Open-SjcExplorerWindow $null $spec -NoShow;$w.Tag.Timer.Stop();$w.Show();$s=$w.Tag.Session
 Pump $s {$s.HostReady -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
 $first=@($s.TaskList|ForEach-Object {$_['TaskId']});Request-SjcExplorerTaskList $s 1;Pump $s {$s.Queue.Count -eq 0 -and -not $s.InFlight}
 $all=@($first)+@($s.TaskList|ForEach-Object {$_['TaskId']})
 Check 'All records survive restart' ($all.Count -eq 65 -and @($all|Where-Object {$ids -notcontains $_}).Count -eq 0)
 Start-SjcExplorerInventory $s $folder;Pump $s {$s.State -eq 'Ready' -and $s.Queue.Count -eq 0 -and -not $s.InFlight}
 Check 'New inventory after restart remains possible' ($ids -notcontains $s.TaskId -and -not $s.LastError)
 Check 'No automatic release and no input change' ([IO.File]::ReadAllText((Join-Path $folder 'keep.txt')) -eq 'owned history file')
}catch{$checks.Add(@{Name='Unhandled';Passed=$false;Error=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
finally{if($s){[void](Close-SjcExplorerSession $s).Wait(10000)};if($w){$w.Close()}}
$r=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();RealUserStateTouched=$false;FileDeletionRequests=0}
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'result.json'),($r|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$r|ConvertTo-Json -Depth 8
if(-not $r.Passed){exit 1}
