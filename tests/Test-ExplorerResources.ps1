param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(Test-Path $EvidenceDirectory){throw 'New evidence'};[void][IO.Directory]::CreateDirectory($EvidenceDirectory)
foreach($n in @('Version','Rules','Core','Discovery','Maintenance','Worker','Gui','ExplorerGui')){. (Join-Path $Repository ('src\'+$n+'.ps1'))}
Enable-SjcTestIsolation -ParentDirectory (Join-Path $EvidenceDirectory 'owned');$sb=New-SjcTestSandbox
Initialize-SjcDesktop;Initialize-SjcExplorerBridge
$checks=[Collections.Generic.List[object]]::new();function C($n,$v){$checks.Add(@{Name=$n;Passed=[bool]$v});if(-not $v){throw $n}}
$s=@{HostReady=$true;CanInventory=$true;Fault=$null;Closing=$false;InFlight=$null;Queue=[Collections.Generic.List[object]]::new();Batch=$null;TaskId='11111111-2222-4333-8444-555555555555';State='Ready';Phase='Running';Reason=$null;Mode='LocalExploration';Revision=1;ParentId=$null;Stderr=[Collections.Generic.List[string]]::new();Coverage=$null;ProgressDirty=$true;GroupsDirty=$false;SpaceDirty=$false;EvidenceDirty=$false;Operations=@('GetStorageInfo','GetSessionInfo','ListTasks','CompactState','ReleaseFinishedSessions','ArchiveUnconfirmedDrafts','GetProgress');TaskGen=0;AnalysisGen=0;DraftGen=0;LastError=$null}
Initialize-SjcExplorerApprovalState $s
try{
 $sentinel='C:\private-secret\account-token=abc https://private.example/key'
 $s.LastError=$sentinel;$s.Stderr.Add($sentinel);$s.Analysis=@{Id='secret-task-id';Terminal=$true;Timing=@{TotalMilliseconds=20;Token=$sentinel};Usage=@{ReadFiles=3;MetadataObjects=8;Path=$sentinel}}
 $s.Exec=@{Status='PartialOrInterrupted';Entries=[Collections.Generic.List[object]]::new();Rejected=$false;Terminal=$true;RecycledBytes=69}
 for($i=0;$i -lt 70;$i++){$s.Exec.Entries.Add(@{ObjectId='entry-'+$i;Path=$sentinel;Status='Attempting';Reason=$sentinel;LogicalBytes=0});$s.Exec.Entries.Add(@{ObjectId='entry-'+$i;Path=$sentinel;Status=$(if($i -eq 69){'UnknownOrFailed'}else{'Recycled'});Reason=$sentinel;LogicalBytes=1})}
 $s.Draft=@{ItemCount=70};$rows=@(Get-SjcExplorerEntryRows $s)
 C 'All 140 ledger events retained, exact unredacted paths only in local result view' ($rows.Count -eq 140 -and $rows[139].Path -eq $sentinel)
 C 'Result summary deduplicates by object final record' ((Get-SjcExplorerExecutionText $s) -like '*70 项*' -and (Get-SjcExplorerExecutionText $s) -like '*69 项*' -and (Get-SjcExplorerExecutionText $s) -notlike '已完成*')
 $d=Join-Path $EvidenceDirectory 'diagnostic.json';[void](Export-SjcExplorerDiagnostic $s $d);$text=[IO.File]::ReadAllText($d)
 C 'Diagnostic omits all sensitive sentinels' ($text -notmatch 'private-secret|account-token|private.example|secret-task-id|entry-69')
  C 'Diagnostic contains useful numeric evidence' ($text -match 'MetadataObjects' -and $text -match '20' -and $text -match 'ExecutionStatusCounts')
  $s.Analysis.Reason='AnalysisMemoryPressure';$s.Analysis.Status='Failed'
  $failureDiagnostic=New-SjcExplorerDiagnostic $s
  C 'Problem report retains the safe analysis failure cause, not only LastError' ($failureDiagnostic.ErrorCode -eq 'AnalysisMemoryPressure' -and $failureDiagnostic.Analysis.ReasonCode -eq 'AnalysisMemoryPressure')
  C 'Memory failure recovery does not demand another full disk inventory' ((Get-SjcExplorerAnalysisFailureAction 'AnalysisMemoryPressure') -match '无需重扫' -and (Get-SjcExplorerAnalysisFailureAction 'AnalysisMemoryPressure') -match '只分析所选目录')
  $s.Analysis.Reason='AnalysisMemoryPressure|HostAnalysis:11111111-2222-4333-8444-555555555555';$s.Analysis.Status='BudgetExhausted'
  $budgetDiagnostic=New-SjcExplorerDiagnostic $s
  C 'Budget failure report preserves reason but strips generation identity' ($budgetDiagnostic.Analysis.ReasonCode -eq 'AnalysisMemoryPressure' -and ($budgetDiagnostic|ConvertTo-Json -Depth 10) -notmatch 'HostAnalysis|11111111-2222-4333-8444-555555555555')
  $realUsage=[Collections.Generic.Dictionary[string,object]]::new();$realUsage['MetadataObjects']=123;$realUsage['Path']=$sentinel
  $s.Analysis.Usage=$realUsage
  $realDiagnostic=New-SjcExplorerDiagnostic $s
  C 'Report handles the actual bridge generic dictionary type without leaking extra keys' ($realDiagnostic.Analysis.Usage.MetadataObjects -eq 123 -and ($realDiagnostic|ConvertTo-Json -Depth 10) -notmatch 'private-secret')
 $again=$false;try{Export-SjcExplorerDiagnostic $s $d}catch{$again=$_.Exception.Message -eq 'DiagnosticDestinationExists'};C 'Diagnostic never overwrites existing file' $again
 C 'All unconfirmed maintenance operations refused' (@('CompactState','ReleaseFinishedSessions','ArchiveUnconfirmedDrafts'|Where-Object {Request-SjcExplorerMaintenance $s $_ $false}).Count -eq 0)
 foreach($category in @('Protected','MixedMembers','Coverage','Budget','UnsupportedLayout')){C ('Specific reason explanation '+$category) ((Get-SjcExplorerReasonCategoryText $category) -notlike '受保护或证据不足*')}
 $s.Exec=$null;$s.Draft=$null;$s.Analysis=$null;$s.LastError=$null
 $s.TaskListStack.Clear();$s.TaskListStack.Add('');$s.HistoryFilter='new-filter'
 $request=@{Op='ListTasks';TaskId=$null;Payload=@{AfterTaskId=$null;PageSize=64;PathFilter='old-filter'}}
 Receive-SjcExplorerResponse $s $request @{Ok=$true;Result=@{Items=@(@{TaskId='old';RootPath='old'});NextAfterTaskId=$null}}
 C 'Old filter response cannot replace current history page' ($s.TaskList.Count -eq 0)
 $s.Storage=@{CanCompact=$true};$s.Analysis=@{Terminal=$false}
 C 'Active analysis blocks maintenance actions' (-not (Request-SjcExplorerMaintenance $s 'CompactState' $true))
 $s.Analysis=$null;$s.Batch=@{Status='Running'}
  C 'Active batch blocks maintenance actions' (-not (Request-SjcExplorerMaintenance $s 'CompactState' $true))
  $s.Batch=$null
  # Instantiate the real consumer page without running its timer/Host. The runtime
  # verifier may read only the explicit test runtime; never use the production state.
  if(-not $env:SJC_TEST_RUNTIME_CACHE){throw 'Explicit isolated runtime required for native help view'}
  $script:SjcExplorerTestContext=@{Id=[guid]::NewGuid().ToString('D');StateRoot=(Join-Path $EvidenceDirectory 'help-state');RuntimeCache=$env:SJC_TEST_RUNTIME_CACHE}
  $helpWindow=$null
  try{
   $helpWindow=Open-SjcExplorerWindow $null $null -NoShow;$helpWindow.Tag.Timer.Stop()
   $helpControls=$helpWindow.Tag.Controls
   C 'Consumer page is named Records and Help' ([string]$helpControls.ResourceTab.Header -eq '记录与帮助')
   C 'Database and session details are collapsed by default' (-not $helpControls.StorageDetailsExpander.IsExpanded)
   $parent=[Windows.LogicalTreeHelper]::GetParent($helpControls.SessionRelease);$underAdvanced=$false
   while($parent){if([object]::ReferenceEquals($parent,$helpControls.StorageDetailsExpander)){$underAdvanced=$true;break};$parent=[Windows.LogicalTreeHelper]::GetParent($parent)}
   C 'Session reset belongs under advanced details rather than the consumer landing page' $underAdvanced
   C 'Consumer page has a separate readable storage summary' (-not [string]::IsNullOrWhiteSpace($helpControls.StorageSummaryText.Text))
   C 'Help page offers an explicit local problem report action' ([string]$helpControls.DiagnosticExport.Content -match '问题报告')
   $nativeSession=$helpWindow.Tag.Session
   $nativeSession.TaskId='11111111-2222-4333-8444-555555555555';$nativeSession.State='Partial';$nativeSession.Revision=7
   $nativeSession.Analysis=@{Id='11111111-2222-4333-8444-555555555555';Status='Failed';Reason='AnalysisMemoryPressure';ErrorCode=$null;Terminal=$true;Ready=$false;CancelRequested=$false;Progress=$null;Usage=$null;Timing=$null;Outcome=$null}
   $nativeSession.ApprovalDirty=$true;Update-SjcExplorerWindow $helpWindow $nativeSession
   C 'Native failure view reads the actual Host Reason field and does not request a useless rescan' ($helpControls.AnalysisText.Text -match '无需重扫' -and $helpControls.AnalysisText.ToolTip -match 'AnalysisMemoryPressure')
   $baseStorage=@{DbBytes=4096;WalBytes=0;ShmBytes=0;LockBytes=0;TotalBytes=4096;MaxStateBytes=536870912;PageSize=4096;PageCount=1;FreePages=0;ReusableBytes=0;Tasks=1;Objects=5;CanCompact=$true;CompactionReason=$null;EstimatedBackupBytes=4096;EstimatedVacuumBytes=8192;SafetyReserveBytes=16777216;EstimatedExtraBytes=16789504;AvailableDriveBytes=1073741824;IndexRepairPending=$true}
   $nativeSession['Storage']=$baseStorage;$nativeSession['SessionInfo']=@{AnalysisSessions=0;AnalysisLimit=8;ActiveAnalyses=0;ExecutionSessions=0;ExecutionLimit=8;ActiveExecutions=0;DraftBindings=0;ApprovalStorage=$null}
   $nativeSession.ApprovalDirty=$true;Update-SjcExplorerWindow $helpWindow $nativeSession
   C 'Technical details note deferred performance index repair when IndexRepairPending is true' ($helpControls.StorageDetailText.Text -like '*记录可查看；空间预算不足，性能索引待重建。确认调整预算后重试。*')
   Receive-SjcExplorerResponse $nativeSession @{Op='ConfigureStorageBudget';TaskId=$null;Payload=@{Mebibytes=1024;Confirmed=$true}} @{Ok=$true;Result=@{MaxStateBytes=1073741824;SessionOnly=$true;IndexRepairPending=$false}}
   $nativeSession.Queue.Clear();$nativeSession.ApprovalDirty=$true;Update-SjcExplorerWindow $helpWindow $nativeSession
   C 'Technical details omit index repair note once IndexRepairPending is false' ($helpControls.StorageDetailText.Text -notlike '*性能索引待重建*')
  }finally{
   if($helpWindow){[void](Close-SjcExplorerSession $helpWindow.Tag.Session).Wait(10000);$helpWindow.Close()}
  }
  # Read-only dialog pages are driven without user/system actions: click its own Next/Prev controls with a Dispatcher callback.
 $s.Exec=@{Entries=[Collections.Generic.List[object]]::new();Status='Unknown';Terminal=$true;Rejected=$false;RecycledBytes=0}
 for($i=0;$i -lt 140;$i++){$s.Exec.Entries.Add(@{ObjectId='object-'+$i;Path=('E:\synthetic\file-'+$i);Status='Skipped';Reason='Test';LogicalBytes=0})}
 if(-not [Windows.Application]::Current){$app=[Windows.Application]::new();$app.ShutdownMode='OnExplicitShutdown'}
 $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(100);$deadline=[datetime]::UtcNow.AddSeconds(10)
 $timer.Add_Tick({
  if([datetime]::UtcNow -gt $deadline){$timer.Stop();foreach($ww in @([Windows.Application]::Current.Windows)){$ww.Close()};return}
  $window=@([Windows.Application]::Current.Windows|Where-Object Title -eq '逐项执行记录（只读）')
  if($window.Count){$ww=$window[0];$timer.Stop();try{C 'Execution first page has 64 events' ($ww.FindName('Rows').Items.Count -eq 64);$ww.FindName('Next').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent));C 'Execution second page has 64 events' ($ww.FindName('Rows').Items.Count -eq 64);$ww.FindName('Next').RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent));C 'Execution final page has 12 events without duplication' ($ww.FindName('Rows').Items.Count -eq 12 -and $ww.FindName('Rows').Items[0].Number -eq 129);Save-SjcGuiRender $ww (Join-Path $EvidenceDirectory 'execution-final-page.png')}finally{$ww.Close()}}
 }.GetNewClosure());$timer.Start()
 Show-SjcExplorerExecutionEntries $null $s;$timer.Stop()
}catch{$checks.Add(@{Name='Unhandled';Passed=$false;Error=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
$r=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();HostStarted=$false;NativeRecycleCalls=0};[IO.File]::WriteAllText((Join-Path $EvidenceDirectory 'result.json'),($r|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$r|ConvertTo-Json -Depth 8;if(-not $r.Passed){exit 1}
