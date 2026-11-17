param([Parameter(Mandatory=$true)][string]$Repository,[switch]$SelfContained)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer';$run=Join-Path $base ('host-model-'+[guid]::NewGuid().ToString('D'));[void][IO.Directory]::CreateDirectory($run)
$local=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('SafeJunkCleaner-ModelHostTests\'+[guid]::NewGuid().ToString('D'));[void][IO.Directory]::CreateDirectory($local)
[IO.File]::WriteAllText((Join-Path $local '.sandbox-owner'),([Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'|'+$local))
$packages=Join-Path $local 'packages';$unknown=Join-Path $local 'unknown';$private=Join-Path $local 'private'
foreach($d in @($packages,$unknown,$private)){[void][IO.Directory]::CreateDirectory($d)}
[byte[]]$zip=0x50,0x4b,3,4,1,2,3,4,5,6
[IO.File]::WriteAllBytes((Join-Path $packages 'one.zip'),$zip);[IO.File]::WriteAllBytes((Join-Path $packages 'two.zip'),$zip)
[IO.File]::WriteAllText((Join-Path $unknown 'unclassified.bin'),'synthetic unknown');[IO.File]::WriteAllBytes((Join-Path $unknown 'other-one.zip'),$zip);[IO.File]::WriteAllBytes((Join-Path $unknown 'other-two.zip'),$zip);[IO.File]::WriteAllText((Join-Path $private 'photo.jpg'),'private synthetic never read')
$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk';$env:TEMP=Join-Path $base 'temp';$env:TMP=$env:TEMP
$s=New-Object Diagnostics.ProcessStartInfo;$s.FileName=Join-Path $env:DOTNET_ROOT 'dotnet.exe';$s.Arguments='"'+(Join-Path $base 'bin\Explorer.Host\Release\net10.0-windows\sjc-explorer.dll')+'" --state-root "'+(Join-Path $local 'state')+'"';$s.UseShellExecute=$false;$s.RedirectStandardInput=$true;$s.RedirectStandardOutput=$true;$s.RedirectStandardError=$true;$s.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
if($SelfContained){
 $publishedResult=Get-Content -Encoding UTF8 -Raw -LiteralPath (Join-Path $base 'publish-work-7d1b2e0f-f1c8-4c3f-926b-c2c049de8aea\evidence\result.json')|ConvertFrom-Json
 $hostDll=Join-Path $publishedResult.StagingDirectory 'sjc-explorer.dll';$s.FileName=Join-Path $publishedResult.StagingDirectory 'sjc-explorer.exe';$s.Arguments='--state-root "'+(Join-Path $local 'state')+'"';$s.EnvironmentVariables['DOTNET_ROOT']=Join-Path $local 'absent-dotnet';$s.EnvironmentVariables['DOTNET_MULTILEVEL_LOOKUP']='0';$s.EnvironmentVariables['PATH']=$env:SystemRoot+'\System32'
}else{$hostDll=Join-Path $base 'bin\Explorer.Host\Release\net10.0-windows\sjc-explorer.dll'}
$p=New-Object Diagnostics.Process;$p.StartInfo=$s;[void]$p.Start();$errors=$p.StandardError.ReadToEndAsync();$count=0
function Assert($ok,$name){if(!$ok){throw $name};$script:count++}
function Send($op,$task,$payload){$r=@{ProtocolVersion=1;RequestId=[guid]::NewGuid().ToString('D');TaskId=$task;Operation=$op;Payload=$payload}|ConvertTo-Json -Compress -Depth 8;[IO.File]::AppendAllText((Join-Path $run 'protocol.jsonl'),$r+"`n");$b=[Text.Encoding]::UTF8.GetBytes($r+"`n");$p.StandardInput.BaseStream.Write($b,0,$b.Length);$p.StandardInput.BaseStream.Flush();$read=$p.StandardOutput.ReadLineAsync();if(!$read.Wait(15000) -or !$read.Result){throw ('Protocol timeout '+$op)};[IO.File]::AppendAllText((Join-Path $run 'protocol.jsonl'),$read.Result+"`n");return $read.Result|ConvertFrom-Json}
try{
 for($i=0;$i -lt 100;$i++){$health=Send 'Health' $null @{};if($health.Result.Capabilities.ModelAvailabilityStatus -ne 'Checking'){break};Start-Sleep -Milliseconds 250}
 Assert $health.Result.Capabilities.ModelAvailable 'Verified native model available';Assert (!$health.Result.Capabilities.ModelEnabledByDefault) 'Model explicit opt-in'
 $results=@()
 $testDirs=if($SelfContained){@($packages,$private)}else{@($packages,$unknown,$private)}
 foreach($dir in $testDirs){
  $create=Send 'CreateInventory' $null @{SelectedPath=$dir};Assert $create.Ok 'Create inventory';$task=$create.TaskId
  for($i=0;$i -lt 100;$i++){$progress=Send 'GetProgress' $task @{};if($progress.Result.Task.State -ne 'Inventory'){break};Start-Sleep -Milliseconds 30}
  $e=Send 'QueryEvidence' $task @{AfterId=0;PageSize=1;ParentId=$null};$target=[string]$e.Result.Items[0].EvidenceId
  $a=Send 'Analyze' $task @{TargetId=$target;ExpectedEvidenceRevision=$progress.Result.Task.EvidenceRevision;UseModel=$true};Assert $a.Ok 'Explicit model analyze accepted'
  for($i=0;$i -lt 180;$i++){$result=Send 'GetAnalysisProgress' $task @{AnalysisId=$a.Result.AnalysisId};if($result.Result.Status -ne 'Running'){break};Start-Sleep -Milliseconds 1000}
  Assert ($result.Result.Status -ne 'Running') 'Bounded analysis completes';$results+=@{Directory=[IO.Path]::GetFileName($dir);Result=$result.Result}
  if($dir -eq $private){Assert ($result.Result.ModelStatus -eq 'NotCalledProgramPolicy' -and $result.Result.Decisions.Count -eq 0) 'Private policy stop is not model quality'}else{Assert (@($result.Result.Decisions|Where-Object {$_.Status -eq 'Completed'}).Count -gt 0) ('Real native decision '+($result|ConvertTo-Json -Depth 8))}
 }
 $p.StandardInput.Close();if(!$p.WaitForExit(15000)){throw 'Host exit timeout'}
 [IO.File]::WriteAllText((Join-Path $run 'stderr.log'),$errors.Result)
 @{Passed=$true;Assertions=$count;Sandbox=$local;Cases=$results;HostSha256=(Get-FileHash $hostDll -Algorithm SHA256).Hash;SelfContained=[bool]$SelfContained}|ConvertTo-Json -Depth 15|Set-Content -Encoding UTF8 (Join-Path $run 'result.json')
 Write-Output ('HOST REAL MODEL PASS '+$count+' assertions; evidence '+$run)
}finally{if(!$p.HasExited){$p.StandardInput.Close();if(!$p.WaitForExit(15000)){$p.Kill()}};$p.Dispose()}
