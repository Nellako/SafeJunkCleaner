param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer'
$run=Join-Path $base ('selftest-'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($run)
$files=Join-Path $run 'files';[void][IO.Directory]::CreateDirectory($files)
[IO.File]::WriteAllText((Join-Path $files 'sample.txt'),'synthetic inventory fixture')
[void][IO.Directory]::CreateDirectory((Join-Path $files 'cache'))
[IO.File]::WriteAllBytes((Join-Path $files 'cache\build.bin'),(New-Object byte[] 4096))
$stateParent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('SafeJunkCleaner\explorer-tests\'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($stateParent)
[IO.File]::WriteAllText((Join-Path $stateParent '.sandbox-owner'),([Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'|'+$stateParent))
$state=Join-Path $stateParent 'state';$transcript=Join-Path $run 'protocol.jsonl'
$env:TEMP=Join-Path $base 'temp';$env:TMP=$env:TEMP;$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk'
$exe=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$hostDll=Join-Path $base 'bin\Explorer.Host\Release\net10.0-windows\sjc-explorer.dll'
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$exe;$start.Arguments='"'+$hostDll+'" --state-root "'+$state+'"'
$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
$p=New-Object Diagnostics.Process;$p.StartInfo=$start
[void]$p.Start();$stderr=$p.StandardError.ReadToEndAsync()
$assertions=0
function Send($Operation,$TaskId,$Payload){
 $request=@{ProtocolVersion=1;RequestId=[guid]::NewGuid().ToString('D');TaskId=$TaskId;Operation=$Operation;Payload=$Payload}|ConvertTo-Json -Compress -Depth 8
 [IO.File]::AppendAllText($transcript,$request+[Environment]::NewLine)
 $p.StandardInput.Flush()
 $bytes=[Text.Encoding]::UTF8.GetBytes($request+"`n");$p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$p.StandardInput.BaseStream.Flush()
 $read=$p.StandardOutput.ReadLineAsync()
 if(!$read.Wait(15000)){throw 'Protocol response timeout'}
 $line=$read.Result;if(!$line){throw 'Host exited: '+$stderr.Result}
 [IO.File]::AppendAllText($transcript,$line+[Environment]::NewLine)
 return $line|ConvertFrom-Json
}
function Assert($Condition,$Message){if(!$Condition){throw $Message};$script:assertions++}
try{
 $h=Send 'Health' $null @{};Assert $h.Ok 'Health failed'
 $c=Send 'CreateInventory' $null @{SelectedPath=$files};Assert $c.Ok ('Create failed: '+($c|ConvertTo-Json -Compress -Depth 8));$task=$c.TaskId
 for($i=0;$i -lt 100;$i++){$progress=Send 'GetProgress' $task @{};if($progress.Result.Task.State -ne 'Inventory'){break};Start-Sleep -Milliseconds 30}
 Assert ($progress.Result.Task.State -eq 'Ready') 'Not Ready'
 $groups=Send 'QueryGroups' $task @{AfterId=0;PageSize=64};Assert ($groups.Ok -and $groups.Result.Items.Count -eq 2) 'Directory groups missing'
 $evidence=Send 'QueryEvidence' $task @{AfterId=0;PageSize=2;ParentId=$null};Assert ($evidence.Ok -and $evidence.Result.Items.Count -eq 2 -and $evidence.Result.NextAfter) 'Pagination failed'
 $page2=Send 'QueryEvidence' $task @{AfterId=$evidence.Result.NextAfter;PageSize=2;ParentId=$null};Assert ($page2.Result.Items.Count -eq 2) 'Second page failed'
 $bad=Send 'ExecuteApproved' $task @{};Assert (!$bad.Ok) 'Execution should not exist'
 $bad=Send 'Health' $null @{Unexpected=1};Assert (!$bad.Ok) 'Unknown field accepted'
 $bad=Send 'CreateInventory' $null @{SelectedPath='\\server\share'};Assert (!$bad.Ok) 'UNC accepted'
 $bad=Send 'CreateInventory' $null @{SelectedPath=$state};Assert (!$bad.Ok) 'State scope accepted'
 $bad=Send 'QueryGroups' $task @{AfterId=0;PageSize=65};Assert (!$bad.Ok) 'Oversized page accepted'
 $release=Send 'ReleaseTask' $task @{};Assert $release.Ok 'Release failed'
 $bad=Send 'GetProgress' $task @{};Assert (!$bad.Ok) 'Released task still accessible'
 $p.StandardInput.Close();if(!$p.WaitForExit(15000)){throw 'Host did not exit'}
 Assert ($p.ExitCode -eq 0) 'Host exit failure'
 $stderr.Result|Set-Content -Encoding UTF8 (Join-Path $run 'stderr.log')
 @{Passed=$true;Assertions=$assertions;FixtureRoot=$run;ScannedPath=$files;HostSha256=(Get-FileHash $hostDll -Algorithm SHA256).Hash;CoreSha256=(Get-FileHash (Join-Path (Split-Path $hostDll) 'SafeJunkCleaner.Explorer.dll') -Algorithm SHA256).Hash}|ConvertTo-Json|Set-Content -Encoding UTF8 (Join-Path $run 'result.json')
 Write-Output ('SELFTEST PASS '+$assertions+' assertions; evidence '+$run)
}finally{if(!$p.HasExited){$p.StandardInput.Close();if(!$p.WaitForExit(10000)){$p.Kill()}};$p.Dispose()}
