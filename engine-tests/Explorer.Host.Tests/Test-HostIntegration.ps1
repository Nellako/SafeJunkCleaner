param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer';$run=Join-Path $base ('host-integration-'+[guid]::NewGuid().ToString('D'));[void][IO.Directory]::CreateDirectory($run)
$local=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('SafeJunkCleaner-HostTests\'+[guid]::NewGuid().ToString('D'));[void][IO.Directory]::CreateDirectory($local)
[IO.File]::WriteAllText((Join-Path $local '.sandbox-owner'),([Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'|'+$local))
$files=Join-Path $local 'files';[void][IO.Directory]::CreateDirectory((Join-Path $files 'dist\assets'))
[IO.File]::WriteAllText((Join-Path $files 'package.json'),'{"scripts":{"build":"vite build"}}')
[IO.File]::WriteAllText((Join-Path $files 'dist\index.html'),'synthetic generated')
[IO.File]::WriteAllText((Join-Path $files 'dist\assets\index-12345678.js'),'synthetic generated')
$state=Join-Path $local 'state';$transcript=Join-Path $run 'protocol.jsonl';$count=0;$p=$null
$env:DOTNET_ROOT=Join-Path $env:ProgramFiles 'dotnet';$env:TEMP=Join-Path $base 'temp';$env:TMP=$env:TEMP
$cache=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJunkCleaner\explorer-dev-runtime'
$pointer=Get-Content -LiteralPath (Join-Path $cache 'current.json') -Raw|ConvertFrom-Json
$runtime=Join-Path $cache $pointer.BuildId
$manifestPath=Join-Path $runtime 'host-component-manifest.json'
if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $pointer.ManifestSha256){throw 'Staging manifest pointer mismatch'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
foreach($component in $manifest.Components){$componentPath=Join-Path $runtime $component.Path;if((Get-FileHash -LiteralPath $componentPath -Algorithm SHA256).Hash -ne $component.Sha256){throw 'Staging component mismatch'}}
function Start-Host{
 $s=New-Object Diagnostics.ProcessStartInfo;$s.FileName=Join-Path $env:DOTNET_ROOT 'dotnet.exe';$s.Arguments='"'+(Join-Path $runtime 'sjc-explorer.dll')+'" --state-root "'+$state+'"'
 $s.UseShellExecute=$false;$s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true;$s.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
 $script:p=New-Object Diagnostics.Process;$script:p.StartInfo=$s;[void]$script:p.Start();$script:errors=$script:p.StandardError.ReadToEndAsync()
}
function Stop-Host{if($script:p -and !$script:p.HasExited){$script:p.StandardInput.Close();if(!$script:p.WaitForExit(15000)){throw 'Host stop timeout'}};if($script:p){[IO.File]::AppendAllText((Join-Path $run 'stderr.log'),$script:errors.Result);$script:p.Dispose();$script:p=$null}}
function Send($op,$task,$payload){
 $r=@{ProtocolVersion=1;RequestId=[guid]::NewGuid().ToString('D');TaskId=$task;Operation=$op;Payload=$payload}|ConvertTo-Json -Compress -Depth 8
 [IO.File]::AppendAllText($transcript,$r+"`n");$b=[Text.Encoding]::UTF8.GetBytes($r+"`n");$p.StandardInput.BaseStream.Write($b,0,$b.Length);$p.StandardInput.BaseStream.Flush()
 $read=$p.StandardOutput.ReadLineAsync();if(!$read.Wait(15000)){throw ('Response timeout '+$op)};if(!$read.Result){throw ('Host exited '+$errors.Result)}
 [IO.File]::AppendAllText($transcript,$read.Result+"`n");return $read.Result|ConvertFrom-Json
}
function Assert($ok,$message){if(!$ok){throw $message};$script:count++}
try{
 Start-Host
 $h=Send 'Health' $null @{};Assert ($h.Ok -and $h.Result.ContractVersion -eq 2 -and !$h.Result.Capabilities.ModelEnabledByDefault -and !$h.Result.Capabilities.RecycleEnabled) 'Health capabilities'
 $c=Send 'CreateInventory' $null @{SelectedPath=$files};Assert $c.Ok 'Create';$task=$c.TaskId
 for($i=0;$i -lt 100;$i++){$g=Send 'GetProgress' $task @{};if($g.Result.Task.State -ne 'Inventory'){break};Start-Sleep -Milliseconds 20};Assert ($g.Result.Task.State -eq 'Ready') 'Inventory ready';$revision=$g.Result.Task.EvidenceRevision
 $list=Send 'ListTasks' $null @{AfterTaskId=$null;PageSize=64};Assert ($list.Ok -and $list.Result.Items.Count -eq 1 -and $list.Result.Items[0].TaskId -eq $task) 'Owned tasks listed'
 $ev=Send 'QueryEvidence' $task @{AfterId=0;PageSize=1;ParentId=$null};$root=[string]$ev.Result.Items[0].EvidenceId
 $a=Send 'Analyze' $task @{TargetId=$root;ExpectedEvidenceRevision=$revision};Assert $a.Ok ('Analyze '+($a|ConvertTo-Json -Depth 4));$analysis=$a.Result.AnalysisId
 for($i=0;$i -lt 100;$i++){$s=Send 'GetAnalysisProgress' $task @{AnalysisId=$analysis};if($s.Result.Status -ne 'Running'){break};Start-Sleep -Milliseconds 20}
 Assert ($s.Result.Status -eq 'ModelUnavailable' -and $s.Result.ModelStatus -eq 'NotRequested') ('Facts not model success '+($s|ConvertTo-Json -Depth 5))
 $suggestions=Send 'QuerySuggestions' $task @{AnalysisId=$analysis;AfterId=$null;PageSize=64};Assert ($suggestions.Ok -and $suggestions.Result.Items.Count -eq 1) 'Suggestion exists';$suggestion=$suggestions.Result.Items[0]
 Assert (!$suggestion.SelectedByDefault -and $suggestion.CandidateCount -eq 2 -and $suggestion.MayPrepareForReview) 'Exact default-unselected output'
 $sf=Send 'QuerySuggestionFiles' $task @{AnalysisId=$analysis;SuggestionId=$suggestion.SuggestionId;AfterId=$null;PageSize=1};Assert ($sf.Ok -and $sf.Result.Items.Count -eq 1 -and $sf.Result.Items[0].Path.StartsWith($files)) 'Trusted candidate path display'
 $second=Send 'Analyze' $task @{TargetId=$root;ExpectedEvidenceRevision=$revision};Assert (!$second.Ok -and $second.Error.Code -eq 'InvalidatePreviousAnalysisFirst') 'Single analysis binding'
 $draft=Send 'PrepareApproval' $task @{AnalysisId=$analysis;SuggestionIds=@($suggestion.SuggestionId);ExpectedEvidenceRevision=$revision};Assert $draft.Ok ('Prepare '+($draft|ConvertTo-Json -Depth 5))
 $items=Send 'QueryApprovalItems' $task @{DraftId=$draft.Result.DraftId;AfterId=0;PageSize=64};Assert ($items.Ok -and $items.Result.Items.Count -eq 2 -and $items.Result.DisplayHash -eq $draft.Result.DisplayHash) 'Bound draft items'
 $bad=Send 'ConfirmApproval' $task @{DraftId=$draft.Result.DraftId;DisplayHash=('0'*64)};Assert (!$bad.Ok) 'Wrong display hash rejected'
 $confirmed=Send 'ConfirmApproval' $task @{DraftId=$draft.Result.DraftId;DisplayHash=$draft.Result.DisplayHash};Assert $confirmed.Ok 'Confirm';$approval=$confirmed.Result.ApprovalId
 $exec=Send 'ExecuteApproved' $task @{ApprovalId=[guid]::NewGuid().ToString('D')};Assert (!$exec.Ok) 'Unsealed execution rejected without effects'
 Assert $confirmed.Result.CanExecute 'Confirmed seal may execute only on explicit later user action'
 $invalidated=Send 'InvalidateAnalysis' $task @{AnalysisId=$analysis};Assert $invalidated.Ok 'Explicit invalidation after draft history'
 $a2=Send 'Analyze' $task @{TargetId=$root;ExpectedEvidenceRevision=$revision};Assert $a2.Ok 'New explicit analysis generation';$analysis2=$a2.Result.AnalysisId
 for($i=0;$i -lt 100;$i++){$s2=Send 'GetAnalysisProgress' $task @{AnalysisId=$analysis2};if($s2.Result.Status -ne 'Running'){break};Start-Sleep -Milliseconds 20}
 $stale=Send 'ConfirmApproval' $task @{DraftId=$draft.Result.DraftId;DisplayHash=$draft.Result.DisplayHash};Assert (!$stale.Ok -and $stale.Error.Code -eq 'ApprovalRevisionChanged') 'Old draft invalid after same-revision reanalysis'
 $foreign=Send 'QuerySuggestions' ([guid]::NewGuid().ToString('D')) @{AnalysisId=$analysis2;AfterId=$null;PageSize=64};Assert (!$foreign.Ok) 'Cross task analysis denied'
 Stop-Host;Start-Host
 $list=Send 'ListTasks' $null @{AfterTaskId=$null;PageSize=64};Assert ($list.Ok -and $list.Result.Items[0].TaskId -eq $task) 'Tasks recover after restart'
 $exec=Send 'ExecuteApproved' $task @{ApprovalId=[guid]::NewGuid().ToString('D')};Assert (!$exec.Ok) 'Restart requires a real bound seal; no automatic execution'
 $release=Send 'ReleaseTask' $task @{};Assert $release.Ok 'History draft does not permanently block release'
 Assert ((Test-Path (Join-Path $files 'dist\index.html')) -and (Test-Path (Join-Path $files 'dist\assets\index-12345678.js'))) 'Synthetic outputs untouched'
 Stop-Host
 @{Passed=$true;Assertions=$count;Sandbox=$local;HostSha256=(Get-FileHash (Join-Path $runtime 'sjc-explorer.dll') -Algorithm SHA256).Hash;RuntimeRoot=$runtime;ManifestSha256=$pointer.ManifestSha256}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $run 'result.json')
 Write-Output ('HOST INTEGRATION PASS '+$count+' assertions; evidence '+$run)
}finally{Stop-Host}
