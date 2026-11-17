param([Parameter(Mandatory=$true)][string]$Repository)

# Independent verifier negative/schema/unicode/path/ID/index-resume checks.
# Drives the already-built Host over stdio. Never scans real caches or real disks;
# fixtures are created inside a new GUID evidence sandbox. State lives under
# LocalAppData (non-cloud); evidence lives under artifacts\explorer\verification-<guid>.

$ErrorActionPreference='Stop'
$repo=(Resolve-Path $Repository).Path
$base=Join-Path $repo 'artifacts\explorer'
$vid=[guid]::NewGuid().ToString('D')
$ev=Join-Path $base ('verification-'+$vid)
$fixtureRoot=Join-Path $ev 'fixtures'
[void][IO.Directory]::CreateDirectory($fixtureRoot)

# Non-cloud private state parent; keep the same convention as the boundary selftest.
$stateParent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('SafeJunkCleaner\explorer-tests\'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($stateParent)
[IO.File]::WriteAllText((Join-Path $stateParent '.sandbox-owner'),([Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'|'+$stateParent))
$state=Join-Path $stateParent 'state'

# Keep process temp off any cloud-synced directory.
$procTemp=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('Temp\sjc-verify-'+[guid]::NewGuid().ToString('D'))
[void][IO.Directory]::CreateDirectory($procTemp)

$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk'
$env:TEMP=$procTemp;$env:TMP=$procTemp
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$hostDll=Join-Path $base 'bin\Explorer.Host\Release\net10.0-windows\sjc-explorer.dll'
$coreDll=Join-Path $base 'bin\Explorer.Host\Release\net10.0-windows\SafeJunkCleaner.Explorer.dll'
$transcript=Join-Path $ev 'protocol.jsonl'
[IO.File]::WriteAllText($transcript,'')
$script:total=0;$script:failed=@();$script:checks=@()
function Check($name,$condition,$detail=''){
 $script:total++
 if($condition){$script:checks+=@{Name=$name;Passed=$true}}
 else{$script:checks+=@{Name=$name;Passed=$false;Detail=$detail};$script:failed+=$name}
}
function StartHost($stateRoot){
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$dotnet;$start.Arguments='"'+$hostDll+'" --state-root "'+$stateRoot+'"'
 $start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
 $p=New-Object Diagnostics.Process;$p.StartInfo=$start;[void]$p.Start()
 $script:p=$p;$script:stderrTask=$p.StandardError.ReadToEndAsync()
}
function StopHost(){
 if($script:p -and !$script:p.HasExited){$script:p.StandardInput.Close();if(!$script:p.WaitForExit(15000)){$script:p.Kill()}}
 if($script:p){$script:p.Dispose();$script:p=$null}
}
function SendBytes([byte[]]$bytes,$label){
 [IO.File]::AppendAllText($transcript,'#REQ '+$label+' '+[Convert]::ToBase64String($bytes)+"`n")
 $script:p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length)
 $script:p.StandardInput.BaseStream.WriteByte(10)
 $script:p.StandardInput.BaseStream.Flush()
 $read=$script:p.StandardOutput.ReadLineAsync()
 if(!$read.Wait(20000)){throw ('Protocol response timeout: '+$label)}
 $line=$read.Result
 if(!$line){throw ('Host exited without response: '+$label)}
 [IO.File]::AppendAllText($transcript,$line+"`n")
 return ($line|ConvertFrom-Json)
}
function SendJson([string]$json,$label){
 return SendBytes ([Text.Encoding]::UTF8.GetBytes($json)) $label
}
function Send($Operation,$TaskId,$Payload,$RequestId=$null){
 if($null -eq $RequestId){$RequestId=[guid]::NewGuid().ToString('D')}
 $req=[ordered]@{ProtocolVersion=1;RequestId=$RequestId;TaskId=$TaskId;Operation=$Operation;Payload=$Payload}
 $json=$req|ConvertTo-Json -Compress -Depth 12
 $r=SendJson $json ($Operation+' '+$RequestId)
 Check ('RequestIdEcho:'+$Operation) ($r.RequestId -ceq $RequestId.ToLowerInvariant()) ('echo='+$r.RequestId)
 return $r
}
function Code($r){if($r.Ok){return $null};return $r.Error.Code}
function RejectCode($r,$expected,$name){Check $name ((!$r.Ok) -and ((Code $r) -eq $expected)) ('Ok='+$r.Ok+' Code='+(Code $r)+' expected='+$expected)}
function WaitTerminal($task,$expected,$ms){
 $sw=[Diagnostics.Stopwatch]::StartNew()
 while($sw.ElapsedMilliseconds -lt $ms){
  $g=Send 'GetProgress' $task @{}
  if(!$g.Ok){throw ('GetProgress rejected: '+(Code $g))}
  $st=$g.Result.Task.State
  if($st -ne 'Inventory'){Check ('StateIn:'+($expected -join '/')) ($expected -contains $st) ('state='+$st);return $g}
  Start-Sleep -Milliseconds 40
 }
 throw ('Timed out waiting for state '+($expected -join '/'))
}
function EvidenceAll($task){
 $after=[int64]0;$items=@();$pages=0
 while($true){
  $r=Send 'QueryEvidence' $task @{AfterId=$after;PageSize=64;ParentId=$null}
  if(!$r.Ok){throw ('QueryEvidence rejected: '+(Code $r))}
  $page=@($r.Result.Items)
  Check ('EvidencePageNonEmpty:'+$pages) ($page.Count -gt 0) ('count='+$page.Count)
  foreach($it in $page){$items+=$it}
  $next=$r.Result.NextAfter
  if($null -eq $next){break}
  Check ('EvidenceCursorAdvances:'+$pages) ([int64]$next -gt $after) ('next='+$next+' after='+$after)
  $after=[int64]$next;$pages++
  if($pages -gt 200){throw 'Evidence pagination runaway'}
 }
 return ,$items
}
function FindByPath($items,$path){return @($items|Where-Object{$_.Path -ceq $path})}

$preCore=(Get-FileHash $coreDll -Algorithm SHA256).Hash
$preHost=(Get-FileHash $hostDll -Algorithm SHA256).Hash
Check 'FrozenCoreDllBefore' ($preCore -eq 'DB369DF32246423D1A1073DFE6AF2831E86C59C55310415BFBB074ED6CF2C532') ('actual='+$preCore)
Check 'FrozenHostDllBefore' ($preHost -eq 'F9EECE199B876A3FDBA8B52C49E7838D647AB5A20570D64D31C1FDDE6DFA8612') ('actual='+$preHost)

try{
 StartHost $state
 $h=Send 'Health' $null @{}
 Check 'HealthOk' $h.Ok ('code='+(Code $h))
 Check 'HealthTaskIdNull' ($null -eq $h.TaskId) ('TaskId='+$h.TaskId)
 Check 'HealthSchema' ($h.Result.SchemaVersion -eq 1 -and $h.Result.Mode -eq 'ReadOnly' -and $h.Result.MaxPageSize -eq 64 -and $h.Result.MaxMessageBytes -eq 32768 -and $h.Result.MaxResponseBytes -eq 262144) ('result='+($h.Result|ConvertTo-Json -Compress))
 $ops=@($h.Result.Operations|Sort-Object)
 $expectedOps=@('Cancel','CreateInventory','GetProgress','Health','Pause','QueryEvidence','QueryGroups','ReleaseTask','Resume')|Sort-Object
 Check 'HealthOperationSet' (($ops -join ',') -eq ($expectedOps -join ',')) ('ops='+($ops -join ','))
 Check 'NoExecuteOperation' ($ops -notcontains 'ExecuteApproved' -and $ops -notcontains 'PrepareApproval' -and $ops -notcontains 'ConfirmApproval')('ops='+($ops -join ','))

 # Uppercase RequestId is canonicalized to lowercase D format in the echo.
 $upper=[guid]::NewGuid().ToString('D').ToUpperInvariant()
 $u=Send 'Health' $null @{} $upper
 Check 'UppercaseRequestIdCanonicalized' ($u.RequestId -ceq $upper.ToLowerInvariant()) ('echo='+$u.RequestId)

 # Schema: wrong protocol version, wrong type, missing/extra/duplicate fields.
 $bad=SendJson ('{"ProtocolVersion":2,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Payload":{}}') 'ProtocolVersion2'
 RejectCode $bad 'ProtocolVersionMismatch' 'ProtocolVersion2Rejected'
 $bad=SendJson ('{"ProtocolVersion":"1","RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Payload":{}}') 'ProtocolVersionString'
 Check 'ProtocolVersionWrongTypeRejected' (!$bad.Ok) ('Ok='+$bad.Ok)
 $okAfter=Send 'Health' $null @{}
 Check 'FramingSurvivesSchemaReject' $okAfter.Ok ('code='+(Code $okAfter))
 $bad=SendJson ('{"ProtocolVersion":1,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health"}') 'MissingPayload'
 RejectCode $bad 'MissingField' 'MissingPayloadRejected'
 $bad=SendJson ('{"ProtocolVersion":1,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Payload":{},"Extra":1}') 'ExtraTopLevelField'
 RejectCode $bad 'UnknownOrDuplicateField' 'TopLevelExtraRejected'
 $bad=SendJson ('{"ProtocolVersion":1,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Operation":"Health","Payload":{}}') 'DuplicateOperationField'
 RejectCode $bad 'UnknownOrDuplicateField' 'DuplicateFieldRejected'
 $bad=SendJson ('{"ProtocolVersion":1,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Payload":{"Unexpected":1}}') 'HealthPayloadExtra'
 RejectCode $bad 'UnknownOrDuplicateField' 'PayloadExtraRejected'
 $bad=Send 'UnknownOperationProbe' ([guid]::NewGuid().ToString('D')) @{}
 RejectCode $bad 'UnknownOperation' 'UnknownOperationRejected'
 $bad=Send 'Health' $null @{} 'not-a-guid'
 RejectCode $bad 'InvalidId' 'MalformedRequestIdRejected'

 # RequestId duplicate inside one session.
 $dup=[guid]::NewGuid().ToString('D')
 $d1=Send 'Health' $null @{} $dup;$d2=Send 'Health' $null @{} $dup
 Check 'DuplicateRequestIdFirstOk' $d1.Ok ('code='+(Code $d1));RejectCode $d2 'DuplicateRequestId' 'DuplicateRequestIdSecondRejected'

 # Invalid UTF-8 must be rejected without killing framing.
 $invalid=[Text.Encoding]::UTF8.GetBytes('{"ProtocolVersion":1,"RequestId":"'+[guid]::NewGuid().ToString('D')+'","TaskId":null,"Operation":"Health","Payload":{}}')
 $bytes=New-Object byte[] ($invalid.Length+1)
 [Array]::Copy($invalid,0,$bytes,0,$invalid.Length);$bytes[$invalid.Length]=0xFF
 $r=SendBytes $bytes 'InvalidUtf8'
 Check 'InvalidUtf8Rejected' (!$r.Ok) ('Ok='+$r.Ok+' Code='+(Code $r))
 $okAfter=Send 'Health' $null @{}
 Check 'FramingSurvivesInvalidUtf8' $okAfter.Ok ('code='+(Code $okAfter))

 # ID/Task relation: random GUID not owned, malformed task id, unexpected TaskId.
 $random=[guid]::NewGuid().ToString('D')
 $r=Send 'QueryGroups' $random @{AfterId=0;PageSize=1}
 RejectCode $r 'TaskNotOwnedOrMissing' 'UnknownTaskRejected'
 Check 'UnknownTaskIdEchoed' ($r.TaskId -ceq $random) ('TaskId='+$r.TaskId)
 $r=Send 'QueryGroups' 'not-a-guid' @{AfterId=0;PageSize=1}
 RejectCode $r 'InvalidId' 'MalformedTaskIdRejected'
 $r=Send 'CreateInventory' $random @{SelectedPath=$fixtureRoot}
 RejectCode $r 'UnexpectedTaskId' 'CreateInventoryUnexpectedTaskIdRejected'
 $r=Send 'QueryEvidence' $random @{AfterId=0;PageSize=1;ParentId=0}
 RejectCode $r 'InvalidParentId' 'ParentIdZeroRejected'
 $r=Send 'QueryEvidence' $random @{AfterId=0;PageSize=1;ParentId=-3}
 RejectCode $r 'InvalidParentId' 'NegativeParentIdRejected'
 $r=Send 'QueryGroups' $random @{AfterId=-1;PageSize=1}
 RejectCode $r 'InvalidPage' 'NegativeCursorRejected'
 $r=Send 'QueryGroups' $random @{AfterId=0;PageSize=0}
 RejectCode $r 'InvalidPage' 'PageSizeZeroRejected'
 $r=Send 'QueryGroups' $random @{AfterId=0;PageSize=65}
 RejectCode $r 'InvalidPage' 'PageSizeOverMaxRejected'
 $r=Send 'QueryGroups' $random @{AfterId=0;PageSize=-5}
 RejectCode $r 'InvalidPage' 'PageSizeNegativeRejected'

 # Path canonicalization and scope negatives.
 foreach($case in @(
  @('UncPath','\\server\share','UnsupportedPath'),
  @('DevicePath','\\?\C:\','UnsupportedPath'),
  @('DotDotPath','C:\a\..\b','NonCanonicalPath'),
  @('TrailingDot','C:\a.','NonCanonicalPath'),
  @('TrailingSpace','C:\a ','NonCanonicalPath'),
  @('AdsStream','C:\a\b:c','UnsupportedPath'),
  @('RelativePath','relative\dir','UnsupportedPath'),
  @('ReservedName','C:\CON','NonCanonicalPath'),
  @('EmbeddedNul','C:\a'+[char]0+'b','UnsupportedPath')
 )){
  $r=Send 'CreateInventory' $null @{SelectedPath=$case[1]}
  RejectCode $r $case[2] ('PathRejected:'+$case[0])
 }
 $r=Send 'CreateInventory' $null @{SelectedPath=$state}
 RejectCode $r 'ApplicationState' 'StateRootScopeRejected'
 $missing=Join-Path $fixtureRoot ('missing-'+[guid]::NewGuid().ToString('D'))
 $r=Send 'CreateInventory' $null @{SelectedPath=$missing}
 Check 'MissingLocalPathRejected' (!$r.Ok) ('Code='+(Code $r))

 # Unicode fixture scan and complete ID/parent/byte relationships.
 $uni=Join-Path $fixtureRoot 'unicode'
 [void][IO.Directory]::CreateDirectory($uni)
 $u1=Join-Path $uni ('中文-测试.txt');$u2=Join-Path $uni ('emoji-😀.bin');$u3=Join-Path $uni ('combining-e'+[char]0x0301+'.txt')
 $ud=Join-Path $uni '子目录';[void][IO.Directory]::CreateDirectory($ud);$u4=Join-Path $ud '深层.txt'
 [IO.File]::WriteAllBytes($u1,(New-Object byte[] 123));[IO.File]::WriteAllBytes($u2,(New-Object byte[] 77))
 [IO.File]::WriteAllBytes($u3,(New-Object byte[] 5));[IO.File]::WriteAllBytes($u4,(New-Object byte[] 11))
 $c=Send 'CreateInventory' $null @{SelectedPath=$uni}
 Check 'UnicodeCreateOk' $c.Ok ('code='+(Code $c))
 $uniTask=$c.TaskId
 Check 'CreateTaskIdIsGuidD' ((([string]$uniTask) -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') -and (([guid]::Parse([string]$uniTask)) -ne [guid]::Empty)) ('TaskId='+$uniTask)
 $g=WaitTerminal $uniTask @('Ready') 60000
 Check 'UnicodeTaskIdMatches' ($g.Result.Task.TaskId -eq $uniTask) ('progressTask='+$g.Result.Task.TaskId)
 Check 'UnicodeReadySemantics' ($g.Result.Task.State -eq 'Ready' -and $g.Result.Task.Reason -eq $null -and $g.Result.Coverage.PendingDirectories -eq 0 -and $g.Result.Coverage.SkippedObjects -eq 0) ('Task='+($g.Result.Task|ConvertTo-Json -Compress)+' Coverage='+($g.Result.Coverage|ConvertTo-Json -Compress))
 Check 'UnicodeObservedLogicalBytes' ($g.Result.Coverage.ObservedLogicalBytes -eq (123+77+5+11)) ('actual='+$g.Result.Coverage.ObservedLogicalBytes)
 $items=EvidenceAll $uniTask
 Check 'UnicodeEvidenceCount' ($items.Count -eq 6) ('count='+$items.Count)
 foreach($path in @($uni,$u1,$u2,$u3,$ud,$u4)){
  $found=FindByPath $items $path
  Check ('UnicodePathExact:'+[IO.Path]::GetFileName($path)) ($found.Count -eq 1) ('matches='+$found.Count)
 }
 $root=FindByPath $items $uni;$sub=FindByPath $items $ud
 Check 'RootParentNull' (($root[0].ParentId -eq $null) -and $root[0].EvidenceId -eq 1) ('root='+($root[0]|ConvertTo-Json -Compress))
 foreach($path in @($u1,$u2,$u3)){Check ('UnicodeFileParent:'+[IO.Path]::GetFileName($path)) ((FindByPath $items $path)[0].ParentId -eq $root[0].EvidenceId) ('parent='+(FindByPath $items $path)[0].ParentId)}
 Check 'UnicodeNestedParent' ((FindByPath $items $u4)[0].ParentId -eq $sub[0].EvidenceId) ('parent='+(FindByPath $items $u4)[0].ParentId)
 foreach($p in @(@($u1,123),@($u2,77),@($u3,5),@($u4,11))){
  $row=(FindByPath $items $p[0])[0]
  Check ('UnicodeLogicalBytes:'+[IO.Path]::GetFileName($p[0])) ($row.LogicalBytes -eq $p[1] -and $row.Kind -eq 'File' -and $row.LinkCount -eq 1) ('row='+($row|ConvertTo-Json -Compress))
 }
 foreach($it in $items){if($it.ParentId -ne $null){Check ('ParentLessThanChild:'+$it.EvidenceId) ([int64]$it.ParentId -lt [int64]$it.EvidenceId) ('parent='+$it.ParentId+' id='+$it.EvidenceId)}}
 $q=Send 'QueryGroups' $uniTask @{AfterId=0;PageSize=64}
 Check 'UnicodeGroupsOk' ($q.Ok -and @($q.Result.Items).Count -eq 2) ('items='+@($q.Result.Items).Count)
 $gr=@($q.Result.Items|Where-Object{$_.Path -ceq $uni})[0]
 Check 'UnicodeGroupFacts' ($gr.ObservedDirectChildren -eq 4 -and $gr.DirectLogicalBytes -eq 205 -and $gr.Classification -eq 'Undetermined' -and $gr.SuggestedAction -eq 'None' -and $gr.Protection -eq 'ReadOnlyNoProcessingAuthorization' -and $gr.Coverage -eq 'Complete') ('group='+($gr|ConvertTo-Json -Compress))
 $r=Send 'Resume' $uniTask @{}
 RejectCode $r 'StageMismatch' 'ResumeReadyRejected'
 $rel=Send 'ReleaseTask' $uniTask @{}
 Check 'ReleaseReadyOk' $rel.Ok ('code='+(Code $rel))
 $r=Send 'GetProgress' $uniTask @{}
 RejectCode $r 'TaskNotOwnedOrMissing' 'ReleasedTaskAccessRejected'

 # Offline placeholder: null bytes, Partial, not zero, source untouched.
 $off=Join-Path $fixtureRoot 'offline'
 [void][IO.Directory]::CreateDirectory($off)
 $normal=Join-Path $off 'normal.txt';[IO.File]::WriteAllText($normal,'1234567')
 $offlineFile=Join-Path $off 'offline.bin';[IO.File]::WriteAllText($offlineFile,'synthetic-offline')
 [IO.File]::SetAttributes($offlineFile,[IO.FileAttributes]::Offline)
 $osub=Join-Path $off 'sub';[void][IO.Directory]::CreateDirectory($osub);$nested=Join-Path $osub 'nested.bin';[IO.File]::WriteAllBytes($nested,(New-Object byte[] 3))
 $c=Send 'CreateInventory' $null @{SelectedPath=$off}
 Check 'OfflineCreateOk' $c.Ok ('code='+(Code $c));$offTask=$c.TaskId
 $g=WaitTerminal $offTask @('Partial') 60000
 Check 'OfflinePartialReason' ($g.Result.Task.State -eq 'Partial' -and $g.Result.Task.Reason -eq 'SkippedOrUncoveredObjects' -and $g.Result.Coverage.SkippedObjects -eq 1) ('Task='+($g.Result.Task|ConvertTo-Json -Compress)+' Skipped='+$g.Result.Coverage.SkippedObjects)
 Check 'OfflineBytesExcludedFromTotals' ($g.Result.Coverage.ObservedLogicalBytes -eq 10) ('actual='+$g.Result.Coverage.ObservedLogicalBytes)
 $items=EvidenceAll $offTask
 $orow=(FindByPath $items $offlineFile)[0]
 Check 'OfflineSkipReason' ($orow.Coverage -eq 'NotCovered' -and $orow.SkippedReason -eq 'ReparseOfflineOrCloudPlaceholder') ('row='+($orow|ConvertTo-Json -Compress))
 Check 'OfflineNullLogical' ($orow.LogicalBytes -eq $null) ('LogicalBytes='+$orow.LogicalBytes)
 Check 'OfflineNullAllocated' ($orow.AllocatedBytes -eq $null) ('AllocatedBytes='+$orow.AllocatedBytes)
 Check 'OfflineSourceUntouched' ((Test-Path $offlineFile) -and ([IO.File]::ReadAllText($offlineFile) -eq 'synthetic-offline')) 'content changed or missing'
 $rel=Send 'ReleaseTask' $offTask @{};Check 'OfflineReleaseOk' $rel.Ok ('code='+(Code $rel))

 # Junction/reparse point must be recorded but never followed.
 $jroot=Join-Path $fixtureRoot 'jroot';[void][IO.Directory]::CreateDirectory($jroot)
 $keep=Join-Path $jroot 'keep.txt';[IO.File]::WriteAllText($keep,'keep')
 $target=Join-Path $fixtureRoot 'outside-target';[void][IO.Directory]::CreateDirectory($target)
 $secret=Join-Path $target 'secret.txt';[IO.File]::WriteAllText($secret,'secret')
 $link=Join-Path $jroot 'junction-to-outside'
 & cmd.exe /c mklink /J $link $target 2>&1 | Out-Null
 Check 'JunctionCreated' (Test-Path $link) ('mklinkExit='+$LASTEXITCODE)
 $c=Send 'CreateInventory' $null @{SelectedPath=$jroot}
 Check 'JunctionCreateOk' $c.Ok ('code='+(Code $c));$jTask=$c.TaskId
 $g=WaitTerminal $jTask @('Partial') 60000
 Check 'JunctionPartial' ($g.Result.Task.State -eq 'Partial') ('state='+$g.Result.Task.State)
 $items=EvidenceAll $jTask
 $jrow=(FindByPath $items $link)[0]
 Check 'JunctionRecordedNotCovered' ($jrow.Coverage -eq 'NotCovered' -and $jrow.SkippedReason -eq 'ReparseOfflineOrCloudPlaceholder' -and $jrow.Kind -eq 'Directory') ('row='+($jrow|ConvertTo-Json -Compress))
 Check 'JunctionTargetNotRecorded' ((FindByPath $items $secret).Count -eq 0) 'target child leaked into evidence'
 Check 'JunctionHasNoChildren' (@($items|Where-Object{$_.ParentId -eq $jrow.EvidenceId}).Count -eq 0) 'junction was traversed'
 Check 'JunctionSourceUntouched' ((Test-Path $secret) -and ([IO.File]::ReadAllText($secret) -eq 'secret')) 'target changed'
 $rel=Send 'ReleaseTask' $jTask @{};Check 'JunctionReleaseOk' $rel.Ok ('code='+(Code $rel))

 # Pause mid-scan, mutate, Resume must rebuild a new observed generation.
 $many=Join-Path $fixtureRoot 'many';[void][IO.Directory]::CreateDirectory($many)
 for($i=0;$i -lt 1200;$i++){
  $d=Join-Path $many ([string]$i);[void][IO.Directory]::CreateDirectory($d)
  [IO.File]::WriteAllText((Join-Path $d 'fixture.txt'),('synthetic-'+$i))
  [IO.File]::WriteAllBytes((Join-Path $d 'extra.bin'),(New-Object byte[] 4))
 }
 $c=Send 'CreateInventory' $null @{SelectedPath=$many}
 Check 'ResumeCreateOk' $c.Ok ('code='+(Code $c));$manyTask=$c.TaskId
 $pz=Send 'Pause' $manyTask @{}
 Check 'PauseAcceptedMidScan' ($pz.Ok -and $pz.Result.State -eq 'PauseRequested') ('code='+(Code $pz))
 WaitTerminal $manyTask @('Paused') 60000 | Out-Null
 $before=Send 'GetProgress' $manyTask @{}
 $revBefore=[int64]$before.Result.Task.EvidenceRevision
 $stale=Join-Path $many ('0\fixture.txt');$added=Join-Path $many 'new.txt';$newDir=Join-Path $many 'newdir';$nested2=Join-Path $newDir 'nested.txt'
 [IO.File]::Delete($stale);[IO.File]::WriteAllText($added,'new-generation')
 [void][IO.Directory]::CreateDirectory($newDir);[IO.File]::WriteAllText($nested2,'nested')
 $ttarget=Join-Path $fixtureRoot 'outside-target-2';[void][IO.Directory]::CreateDirectory($ttarget);$tsecret=Join-Path $ttarget 'never.txt';[IO.File]::WriteAllText($tsecret,'never')
 $j2=Join-Path $many 'junction-out';& cmd.exe /c mklink /J $j2 $ttarget 2>&1 | Out-Null
 Check 'ResumeJunctionCreated' (Test-Path $j2) ('mklinkExit='+$LASTEXITCODE)
 $r=Send 'Resume' $manyTask @{}
 Check 'ResumeAccepted' ($r.Ok -and $r.Result.Accepted -eq $true) ('code='+(Code $r))
 $g=WaitTerminal $manyTask @('Partial') 120000
 Check 'ResumePartialDueJunction' ($g.Result.Task.State -eq 'Partial' -and $g.Result.Task.Reason -eq 'SkippedOrUncoveredObjects') ('Task='+($g.Result.Task|ConvertTo-Json -Compress))
 Check 'ResumeRevisionAdvanced' ([int64]$g.Result.Task.EvidenceRevision -gt $revBefore) ('before='+$revBefore+' after='+$g.Result.Task.EvidenceRevision)
 $items=EvidenceAll $manyTask
 Check 'ResumeStaleDeletedPathAbsent' ((FindByPath $items $stale).Count -eq 0) ('stale='+$stale)
 Check 'ResumeNewFilePresent' ((FindByPath $items $added).Count -eq 1) ('added='+$added)
 Check 'ResumeNestedFilePresent' ((FindByPath $items $nested2).Count -eq 1) ('nested='+$nested2)
 $jrow2=(FindByPath $items $j2)[0]
 Check 'ResumeJunctionNotCovered' ($jrow2.Coverage -eq 'NotCovered' -and $jrow2.SkippedReason -eq 'ReparseOfflineOrCloudPlaceholder') ('row='+($jrow2|ConvertTo-Json -Compress))
 Check 'ResumeJunctionTargetNotRecorded' ((FindByPath $items $tsecret).Count -eq 0) 'junction target leaked'
 Check 'ResumeExpectedObjectCount' ($items.Count -eq 3604) ('count='+$items.Count)
 $ids=@{};foreach($it in $items){$ids[[int64]$it.EvidenceId]=$true}
 foreach($it in $items){if($it.ParentId -ne $null){Check ('ResumeParentExists:'+$it.EvidenceId) ($ids.ContainsKey([int64]$it.ParentId) -and [int64]$it.ParentId -lt [int64]$it.EvidenceId) ('parent='+$it.ParentId+' id='+$it.EvidenceId)}}
 Check 'ResumeObservedLogicalBytes' ((@($items|Where-Object{$_.Kind -eq 'File' -and $_.LogicalBytes -ne $null}|ForEach-Object{$_.LogicalBytes}|Measure-Object -Sum).Sum) -gt 0) 'file bytes missing'
 $rel=Send 'ReleaseTask' $manyTask @{};Check 'ResumeReleaseOk' $rel.Ok ('code='+(Code $rel))

 # Unknown state entry is rejected at startup and not deleted.
 $p=Get-Process -Id $script:p.Id -ErrorAction SilentlyContinue
 $script:p.StandardInput.Close()
 if(!$script:p.WaitForExit(15000)){throw 'Host did not exit after stdin close'}
 Check 'CleanHostExit' ($script:p.ExitCode -eq 0) ('exit='+$script:p.ExitCode)
 $stderrText=$script:stderrTask.Result
 StopHost
 $unknown=Join-Path $state 'unknown.file';[IO.File]::WriteAllText($unknown,'leave unknown intact')
 $unknownHash=(Get-FileHash $unknown -Algorithm SHA256).Hash
 try{
  StartHost $state
  if(!$script:p.WaitForExit(15000)){$script:p.Kill();throw 'Host accepted unknown state entry without exiting'}
  $text=$script:stderrTask.Result
  Check 'UnknownStateEntryRejected' ($script:p.ExitCode -ne 0 -and $text -match 'UnknownStateEntry') ('exit='+$script:p.ExitCode+' stderr='+$text)
  Check 'UnknownStateFilePreserved' ((Test-Path $unknown) -and ((Get-FileHash $unknown -Algorithm SHA256).Hash -eq $unknownHash)) 'unknown file deleted or modified'
 } finally { StopHost }
 [IO.File]::Delete($unknown)
}
catch{
 Check 'VerificationRunCompleted' $false ($_.Exception.Message)
}
finally{
 if($script:p){try{StopHost}catch{}}
}

$postCore=(Get-FileHash $coreDll -Algorithm SHA256).Hash
$postHost=(Get-FileHash $hostDll -Algorithm SHA256).Hash
Check 'FrozenCoreDllAfter' ($postCore -eq 'DB369DF32246423D1A1073DFE6AF2831E86C59C55310415BFBB074ED6CF2C532') ('actual='+$postCore)
Check 'FrozenHostDllAfter' ($postHost -eq 'F9EECE199B876A3FDBA8B52C49E7838D647AB5A20570D64D31C1FDDE6DFA8612') ('actual='+$postHost)

# Source manifest must stay frozen through the run.
$manifest=Join-Path $base 'source-freeze-hashes.json'
$entries=Get-Content -Raw $manifest|ConvertFrom-Json
$manifestOk=$true;$manifestDetail=@()
foreach($e in $entries){
 if(!(Test-Path $e.Path)){$manifestOk=$false;$manifestDetail+='MISSING '+$e.Path;continue}
 $h=(Get-FileHash -Algorithm SHA256 $e.Path).Hash
 if($h -ne $e.Hash){$manifestOk=$false;$manifestDetail+=('MISMATCH '+$e.Path+' expected='+$e.Hash+' actual='+$h)}
}
Check 'SourceManifestStable' ($manifestOk -and @($entries).Count -eq 18) ('entries='+@($entries).Count+' detail='+($manifestDetail -join '; '))
Check 'SourceManifestFileCount' (@($entries).Count -eq 18) ('count='+@($entries).Count)

$result=@{
 Passed=($script:failed.Count -eq 0)
 TotalAssertions=$script:total
 FailedAssertions=$script:failed
 Checks=$script:checks
 VerificationId=$vid
 VerificationDir=$ev
 FixtureRoot=$fixtureRoot
 StateRoot=$state
 StateParent=$stateParent
 CoreSha256Pre=$preCore
 CoreSha256Post=$postCore
 HostSha256Pre=$preHost
 HostSha256Post=$postHost
 SourceManifestStable=$manifestOk
 TimestampUtc=(Get-Date).ToUniversalTime().ToString('O')
}
$result|ConvertTo-Json -Depth 10|Set-Content -Encoding UTF8 (Join-Path $ev 'result.json')
if($script:failed.Count -eq 0){
 Write-Output ('NEGATIVE SELFTEST PASS '+$script:total+' assertions; evidence '+$ev)
 exit 0
}
Write-Output ('NEGATIVE SELFTEST FAIL '+$script:failed.Count+'/'+$script:total+' assertions: '+($script:failed -join ', ')+'; evidence '+$ev)
exit 1
