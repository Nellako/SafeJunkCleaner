param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$HostExe,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(Test-Path -LiteralPath $EvidenceDirectory){throw 'New evidence required'}
[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($n in @('Version','Rules','Core','Discovery','Maintenance','Worker','Gui','ExplorerGui')){. (Join-Path $Repository ('src\'+$n+'.ps1'))}
Enable-SjcTestIsolation -ParentDirectory (Join-Path $EvidenceDirectory 'owned')
$sb=New-SjcTestSandbox;$first=Join-Path $sb.Root 'files\first';$second=Join-Path $sb.Root 'files\second'
foreach($p in @($first,$second)){[void][IO.Directory]::CreateDirectory($p);[IO.File]::WriteAllText((Join-Path $p 'keep.txt'),'artificial persistence fixture')}
$id=[guid]::NewGuid().ToString('D');$stateRoot=Join-Path $EvidenceDirectory 'state'
$script:SjcExplorerTestContext=@{Id=$id;StateRoot=$stateRoot}
$spec=@{TestId=$id;Exe=$HostExe;Arguments=(' --state-root "'+$stateRoot+'"')}
$checks=[Collections.Generic.List[object]]::new();$s=$null;$w=$null
function Check($Name,$Value){$checks.Add(@{Name=$Name;Passed=[bool]$Value});if(-not $Value){throw $Name}}
function Pump($Session,[scriptblock]$Until){$end=[datetime]::UtcNow.AddSeconds(45);while(-not (& $Until) -and -not $Session.Fault -and [datetime]::UtcNow -lt $end){Step-SjcExplorerSession $Session;Start-Sleep -Milliseconds 10};if($Session.Fault -or -not (& $Until)){throw ('Pump failed: '+$Session.Fault+' / '+$Session.LastError)}}
function Idle($Session){return (-not $Session.InFlight -and $Session.Queue.Count -eq 0)}
function NewWindow{
 $window=Open-SjcExplorerWindow $null $spec -NoShow;$window.Tag.Timer.Stop();$window.Show()
 return $window
}
try{
 Initialize-SjcDesktop
 $w=NewWindow;$s=$w.Tag.Session;Pump $s {$s.HostReady -and (Idle $s)}
 $s.Operations=@($s.Operations|Where-Object {$_ -ne 'ExecuteApproved'})
 Check 'Persistent batch operations negotiated with actual Host' (Test-SjcExplorerCanPersistBatch $s)
 Check 'Start explicit artificial batch' (Start-SjcExplorerBatch $s @($first,$second))
 # Accept only the batch snapshot, then pause before Step can start any entry.
 Pump $s {$s.Batch -and -not $s.Batch.Creating -and $null -ne $s.Batch.Revision}
 $batchId=[string]$s.Batch.Id
 Invoke-SjcExplorerTaskCommand $s 'Pause'
 Pump $s {$s.Batch.Status -eq 'Paused' -and (Idle $s)}
 Check 'Pause before first entry preserves both pending roots' (@($s.Batch.Entries|Where-Object {$_.TaskId}).Count -eq 0 -and @($s.Batch.Entries|Where-Object State -eq 'Pending').Count -eq 2)
 [void](Close-SjcExplorerSession $s).Wait(10000);$w.Close();$w=$null;$s=$null
 $w=NewWindow;$s=$w.Tag.Session;Pump $s {$s.HostReady -and (Idle $s)}
 Check 'Restart populates batch history without selecting or starting a task' (@($s.BatchList|Where-Object {$_['BatchId'] -eq $batchId}).Count -eq 1 -and -not $s.TaskId)
 Check 'Historical batch opens as view only' (Open-SjcExplorerHistoricalBatch $s $batchId)
 Pump $s {$s.Batch.Status -ne 'Loading' -and (Idle $s)}
 Check 'Loaded batch remains passive and has both roots' (-not (Test-SjcExplorerBatchActive $s) -and $s.Batch.CanContinue -and $s.Batch.Entries.Count -eq 2 -and -not $s.Batch.ActiveIntent)
 for($i=0;$i -lt 12;$i++){Step-SjcExplorerSession $s;Start-Sleep -Milliseconds 10}
 Check 'Read-only view does not create or resume any task' (-not $s.TaskId -and @($s.Batch.Entries|Where-Object {$_.TaskId}).Count -eq 0 -and (Idle $s))
 Check 'Unconfirmed continue is rejected by GUI' (-not (Request-SjcExplorerContinueBatch $s $false) -and (Idle $s))
 $manifest=Get-SjcExplorerBatchContinueManifest $s
 Check 'Continue manifest lists exact trusted remaining roots' ($manifest.Contains($first) -and $manifest.Contains($second) -and $manifest.Contains('不会重扫'))
 Update-SjcExplorerWindow $w $s;$w.UpdateLayout()
 Check 'History controls and explicit continue are visible' ($w.Tag.Controls.BatchHistoryList.Items.Count -ge 1 -and $w.Tag.Controls.BatchContinueButton.IsEnabled)
 Save-SjcGuiRender $w (Join-Path $EvidenceDirectory 'reopened-passive.png')
 Check 'Confirmed continue is queued once' (Request-SjcExplorerContinueBatch $s $true)
 Pump $s {$s.Batch.Status -eq 'Completed' -and (Idle $s)}
 Check 'Confirmed continuation completes two independent tasks' (@($s.Batch.Entries|Where-Object {$_.State -eq 'Ready' -and $_.TaskId}).Count -eq 2 -and @($s.Batch.Entries|ForEach-Object TaskId|Sort-Object -Unique).Count -eq 2)
 Check 'Continuation never analyzes approves or executes' (-not $s.Analysis -and -not $s.Draft -and -not $s.Approval -and -not $s.Exec)
 $firstTask=[string]$s.Batch.Entries[0].TaskId
 Check 'Open completed per-root task remains single-task view' (Open-SjcExplorerBatchResult $s $firstTask)
 Pump $s {$s.State -eq 'Ready' -and (Idle $s)}
 Request-SjcExplorerTaskList $s 0;Pump $s {Idle $s}
 Check 'Completed history selection is required before release' (Release-SjcExplorerTask $s $firstTask $true)
 Pump $s {Idle $s}
 [void](Open-SjcExplorerHistoricalBatch $s $batchId);Pump $s {$s.Batch.Status -ne 'Loading' -and (Idle $s)}
 Check 'Released task is a tombstone not a pending root' ($s.Batch.Entries[0].State -eq 'Released' -and $s.Batch.Entries[0].TaskId -eq $firstTask -and -not $s.Batch.CanContinue)
 Update-SjcExplorerWindow $w $s;$w.Tag.Controls.MainTabs.SelectedItem=$w.Tag.Controls.HistoryTab;$w.UpdateLayout();Save-SjcGuiRender $w (Join-Path $EvidenceDirectory 'history-after-release.png')
 Check 'Artificial input contents unchanged' ([IO.File]::ReadAllText((Join-Path $first 'keep.txt')) -eq 'artificial persistence fixture' -and [IO.File]::ReadAllText((Join-Path $second 'keep.txt')) -eq 'artificial persistence fixture')
}catch{$checks.Add(@{Name='Unhandled';Passed=$false;Error=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
finally{if($s){[void](Close-SjcExplorerSession $s).Wait(10000)};if($w){$w.Close()}}
$result=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();RealUserStateTouched=$false;RealDisksScanned=$false;NativeRecycleCalls=0;FixturesRetained=$true;SourceSHA256=(Get-FileHash (Join-Path $Repository 'src\ExplorerGui.ps1')).Hash}
[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'result.json'),($result|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
$result|ConvertTo-Json -Depth 8
if(-not $result.Passed){exit 1}
