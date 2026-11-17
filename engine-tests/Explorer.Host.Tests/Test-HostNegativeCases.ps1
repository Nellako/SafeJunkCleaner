param([Parameter(Mandatory=$true)][string]$Repository)
# Minimal independent negatives against the frozen staged Host:
#   NEG-1 cross-task approval artifact ownership
#   NEG-2 cross-namespace ID (draft GUID presented as suggestion GUID)
#   NEG-3 wire schema version mismatch, then framing still healthy
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer'
$run=Join-Path $base ('verification-host-'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($run)
$local=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('SafeJunkCleaner-HostTests\'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($local)
[IO.File]::WriteAllText((Join-Path $local '.sandbox-owner'),([Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'|'+$local))
$files=Join-Path $local 'files';[void][IO.Directory]::CreateDirectory((Join-Path $files 'dist\assets'))
[IO.File]::WriteAllText((Join-Path $files 'package.json'),'{"scripts":{"build":"vite build"}}')
[IO.File]::WriteAllText((Join-Path $files 'dist\index.html'),'synthetic generated')
[IO.File]::WriteAllText((Join-Path $files 'dist\assets\index-12345678.js'),'synthetic generated')
$state=Join-Path $local 'state';$transcript=Join-Path $run 'protocol.jsonl'
$count=0;$p=$null
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
function Stop-Host{if($script:p -and !$script:p.HasExited){$script:p.StandardInput.Close();if(!$script:p.WaitForExit(15000)){throw 'Host stop timeout'}};if($script:p){$script:exitCode=$script:p.ExitCode;[IO.File]::AppendAllText((Join-Path $run 'stderr.log'),$script:errors.Result);$script:p.Dispose();$script:p=$null}}
function SendRaw($raw){
 [IO.File]::AppendAllText($transcript,$raw+"`n");$b=[Text.Encoding]::UTF8.GetBytes($raw+"`n");$p.StandardInput.BaseStream.Write($b,0,$b.Length);$p.StandardInput.BaseStream.Flush()
 $read=$p.StandardOutput.ReadLineAsync();if(!$read.Wait(15000)){throw 'Response timeout'};if(!$read.Result){throw ('Host exited '+$errors.Result)}
 [IO.File]::AppendAllText($transcript,$read.Result+"`n");return $read.Result|ConvertFrom-Json
}
function Send($op,$task,$payload){SendRaw (@{ProtocolVersion=1;RequestId=[guid]::NewGuid().ToString('D');TaskId=$task;Operation=$op;Payload=$payload}|ConvertTo-Json -Compress -Depth 8)}
function Assert($ok,$message){if(!$ok){throw $message};$script:count++}
try{
 Start-Host
 $h=Send 'Health' $null @{};Assert ($h.Ok -and !$h.Result.Capabilities.ModelReady -and !$h.Result.Capabilities.RecycleEnabled) 'Health capabilities'
 $a=Send 'CreateInventory' $null @{SelectedPath=$files};Assert $a.Ok 'Create A';$taskA=$a.TaskId
 for($i=0;$i -lt 100;$i++){$g=Send 'GetProgress' $taskA @{};if($g.Result.Task.State -ne 'Inventory'){break};Start-Sleep -Milliseconds 20};Assert ($g.Result.Task.State -eq 'Ready') 'A ready';$revision=$g.Result.Task.EvidenceRevision
 $ev=Send 'QueryEvidence' $taskA @{AfterId=0;PageSize=1;ParentId=$null};$root=[string]$ev.Result.Items[0].EvidenceId
 $an=Send 'Analyze' $taskA @{TargetId=$root;ExpectedEvidenceRevision=$revision};Assert $an.Ok 'Analyze A';$analysis=$an.Result.AnalysisId
 for($i=0;$i -lt 100;$i++){$s=Send 'GetAnalysisProgress' $taskA @{AnalysisId=$analysis};if($s.Result.Status -ne 'Running'){break};Start-Sleep -Milliseconds 20}
 Assert ($s.Result.Status -eq 'ModelUnavailable' -and $s.Result.ModelStatus -eq 'Unavailable') 'A facts-only model unavailable'
 $sug=Send 'QuerySuggestions' $taskA @{AnalysisId=$analysis;AfterId=$null;PageSize=64};Assert ($sug.Ok -and $sug.Result.Items.Count -ge 1) 'Suggestion A exists';$suggestion=[string]$sug.Result.Items[0].SuggestionId
 $draft=Send 'PrepareApproval' $taskA @{AnalysisId=$analysis;SuggestionIds=@($suggestion);ExpectedEvidenceRevision=$revision};Assert $draft.Ok 'Draft A prepared';$draftId=[string]$draft.Result.DraftId
 $b=Send 'CreateInventory' $null @{SelectedPath=$files};Assert $b.Ok 'Create B';$taskB=$b.TaskId
 for($i=0;$i -lt 100;$i++){$g=Send 'GetProgress' $taskB @{};if($g.Result.Task.State -ne 'Inventory'){break};Start-Sleep -Milliseconds 20};Assert ($g.Result.Task.State -eq 'Ready') 'B ready'
 # NEG-1: draft created under task A presented with task B.
 $n1=Send 'QueryApprovalItems' $taskB @{DraftId=$draftId;AfterId=0;PageSize=64}
 Assert (!$n1.Ok -and $n1.Error.Code -eq 'DraftNotOwnedByTask') ('NEG-1 cross-task draft not rejected: '+($n1|ConvertTo-Json -Depth 5))
 # NEG-2: a genuine GUID from the draft namespace presented as a suggestion ID.
 $n2=Send 'QuerySuggestionFiles' $taskA @{AnalysisId=$analysis;SuggestionId=$draftId;AfterId=$null;PageSize=1}
 Assert (!$n2.Ok -and $n2.Error.Code -eq 'SuggestionNotOwnedOrMissing') ('NEG-2 cross-namespace ID not rejected: '+($n2|ConvertTo-Json -Depth 5))
 # NEG-3: protocol schema version mismatch must be refused without breaking the session.
 $raw=@{ProtocolVersion=2;RequestId=[guid]::NewGuid().ToString('D');TaskId=$null;Operation='Health';Payload=@{}}|ConvertTo-Json -Compress -Depth 8
 $n3=SendRaw $raw
 Assert (!$n3.Ok -and $n3.Error.Code -eq 'ProtocolVersionMismatch') ('NEG-3 schema version not rejected: '+($n3|ConvertTo-Json -Depth 5))
 $h2=Send 'Health' $null @{};Assert $h2.Ok 'Framing healthy after schema rejection'
 $releaseA=Send 'ReleaseTask' $taskA @{};Assert $releaseA.Ok 'Release A'
 $releaseB=Send 'ReleaseTask' $taskB @{};Assert $releaseB.Ok 'Release B'
 Stop-Host
 Assert ($script:exitCode -eq 0) 'Host clean exit'
 @{Passed=$true;Assertions=$count;Negatives=3;Sandbox=$local;HostSha256=(Get-FileHash (Join-Path $runtime 'sjc-explorer.dll') -Algorithm SHA256).Hash;CoreSha256=(Get-FileHash (Join-Path $runtime 'SafeJunkCleaner.Explorer.dll') -Algorithm SHA256).Hash;RuntimeRoot=$runtime;ManifestSha256=$pointer.ManifestSha256}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $run 'result.json')
 Write-Output ('HOST NEGATIVE PASS '+$count+' assertions; evidence '+$run)
}finally{Stop-Host}
