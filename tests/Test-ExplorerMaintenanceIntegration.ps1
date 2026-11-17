param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[string]$HostExe='',[string]$DotnetExe=$env:SJC_DOTNET_EXE)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
$repo=$Repository;$out=$EvidenceDirectory
if(Test-Path $out){throw 'New evidence'};[void][IO.Directory]::CreateDirectory($out)
foreach($n in @('Version','Rules','Core','Discovery','Maintenance','Worker','Gui','ExplorerGui')){. (Join-Path $repo ('src\'+$n+'.ps1'))}
Enable-SjcTestIsolation -ParentDirectory (Join-Path $out 'owned');$sb=New-SjcTestSandbox;$files=Join-Path $sb.Root 'files';[IO.File]::WriteAllText((Join-Path $files 'keep.txt'),'synthetic')
$id=[guid]::NewGuid().ToString('D');$state=Join-Path $out 'state';$script:SjcExplorerTestContext=@{Id=$id;StateRoot=$state};$dll=Join-Path $repo 'artifacts\explorer\bin\Explorer.Host\Release\net10.0-windows\sjc-explorer.dll'
if($HostExe){$spec=@{TestId=$id;Exe=$HostExe;Arguments=(' --state-root "'+$state+'"')}}else{
 if(-not $DotnetExe){$DotnetExe=(Get-Command dotnet -ErrorAction Stop).Source}
 if(-not(Test-Path -LiteralPath $DotnetExe -PathType Leaf)){throw 'Provide -DotnetExe, SJC_DOTNET_EXE, or dotnet on PATH'}
 $spec=@{TestId=$id;Exe=$DotnetExe;Arguments=('"'+$dll+'" --state-root "'+$state+'"')}
}
$checks=[Collections.Generic.List[object]]::new();$s=$null;$w=$null
function C($n,$v){$checks.Add(@{Name=$n;Passed=[bool]$v});if(-not $v){throw $n}}
function Pump($s,[scriptblock]$u){$end=[datetime]::UtcNow.AddSeconds(45);while(-not (& $u) -and -not $s.Fault -and [datetime]::UtcNow -lt $end){Step-SjcExplorerSession $s;Start-Sleep -Milliseconds 15};if($s.Fault -or -not (& $u)){throw ('Pump failed '+$s.Fault+' '+$s.LastError)}}
try{
 Initialize-SjcDesktop;$w=Open-SjcExplorerWindow $null $spec -NoShow;$w.Tag.Timer.Stop();$w.Show();$s=$w.Tag.Session
 Pump $s {$s.HostReady -and -not $s.InFlight -and $s.Queue.Count -eq 0};$s.Operations=@($s.Operations|Where-Object {$_ -ne 'ExecuteApproved'})
 Start-SjcExplorerInventory $s $files;Pump $s {$s.State -eq 'Ready' -and -not $s.InFlight -and $s.Queue.Count -eq 0}
 Request-SjcExplorerTaskList $s 0;Pump $s {-not $s.InFlight -and $s.Queue.Count -eq 0}
 Update-SjcExplorerWindow $w $s
 C 'Root path and source mode from trusted history' ($w.Tag.Controls.TaskList.Items[0].Root -eq $files -and $w.Tag.Controls.TaskList.Items[0].Mode -eq '所选范围')
 Set-SjcExplorerHistoryFilter $s 'does-not-match';Pump $s {-not $s.InFlight -and $s.Queue.Count -eq 0};C 'Server filter excludes unrelated history' ($s.TaskList.Count -eq 0)
 Set-SjcExplorerHistoryFilter $s 'files';Pump $s {-not $s.InFlight -and $s.Queue.Count -eq 0};C 'Server filter restores matching path' ($s.TaskList.Count -eq 1)
 Request-SjcExplorerStorage $s;Pump $s {-not $s.InFlight -and $s.Queue.Count -eq 0};Update-SjcExplorerWindow $w $s
 C 'Resource statistics available' ($s.Storage['Tasks'] -eq 1 -and $s.SessionInfo['AnalysisLimit'] -eq 8)
 C 'Compact action needs explicit confirmation' (-not (Request-SjcExplorerMaintenance $s 'CompactState' $false))
 C 'Confirmed compact accepted' (Request-SjcExplorerMaintenance $s 'CompactState' $true)
 Pump $s {-not $s.InFlight -and $s.Queue.Count -eq 0};Update-SjcExplorerWindow $w $s
 C 'Compaction result shows retained backup' ($s.StorageNotice -like '*备份保留于*' -and -not $s.LastError)
 $w.Tag.Controls.MainTabs.SelectedItem=$w.Tag.Controls.ResourceTab;$w.UpdateLayout();Save-SjcGuiRender $w (Join-Path $out 'resource.png')
 $w.Tag.Controls.MainTabs.SelectedItem=$w.Tag.Controls.HistoryTab;$w.UpdateLayout();Save-SjcGuiRender $w (Join-Path $out 'history.png')
 $s.Exec=@{Status='PartialOrInterrupted';Entries=[Collections.Generic.List[object]]::new();RecycledBytes=10;Terminal=$true;Rejected=$false;ErrorCode=$null};$s.Draft=@{ItemCount=70}
 for($n=0;$n -lt 70;$n++){$s.Exec.Entries.Add(@{ObjectId='object-'+$n;Path=('E:\synthetic-only\file-'+$n);Status='Attempting';Reason='WriteAheadIntent';LogicalBytes=0});$s.Exec.Entries.Add(@{ObjectId='object-'+$n;Path=('E:\synthetic-only\file-'+$n);Status=$(if($n -lt 69){'Recycled'}else{'UnknownOrFailed'});Reason='Artificial';LogicalBytes=$(if($n -lt 69){10}else{0})})}
 $rows=@(Get-SjcExplorerEntryRows $s);C 'All ledger rows visible with exact paths' ($rows.Count -eq 140 -and $rows[0].Path -eq 'E:\synthetic-only\file-0')
 $text=Get-SjcExplorerExecutionText $s;C 'Summary counts final file records not attempting entries' ($text -like '*70 项*' -and $text -like '*69 项*' -and $text -notlike '已完成*')
 $d=Join-Path $out 'diagnostic.json';[void](Export-SjcExplorerDiagnostic $s $d);$j=[IO.File]::ReadAllText($d);C 'Diagnostic omits ledger paths and IDs' ($j -notmatch 'synthetic-only|object-69')
 C 'Original input unchanged' ([IO.File]::ReadAllText((Join-Path $files 'keep.txt')) -eq 'synthetic')
}catch{$checks.Add(@{Name='Unhandled';Passed=$false;Error=$_.Exception.Message;Stack=$_.ScriptStackTrace})}
finally{if($s){$s.Draft=$null;$s.Exec=$null;[void](Close-SjcExplorerSession $s).Wait(10000)};if($w){$w.Close()}}
$r=@{Passed=(@($checks|Where-Object {-not $_.Passed}).Count -eq 0);Assertions=$checks.Count;Checks=$checks.ToArray();NativeRecycleCalls=0;RealUserStateTouched=$false};[IO.File]::WriteAllText((Join-Path $out 'result.json'),($r|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)));$r|ConvertTo-Json -Depth 8;if(-not $r.Passed){exit 1}
