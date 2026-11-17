param([Parameter(Mandatory=$true)][string]$Repository,[string]$PublishDirectory,[switch]$StageDevelopment,[ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedCurrentSHA256)
$ErrorActionPreference='Stop'
$version=(Get-Content -Raw -LiteralPath (Join-Path $Repository 'version.json') | ConvertFrom-Json).version
if ($version -cin @('0.14.0','0.15.0','0.16.0','0.16.1')) {
 . (Join-Path $Repository 'scripts/local-promotion-common.ps1')
 if (-not $PublishDirectory) { throw '0.14 forbids framework-dependent/system-runtime staging. Use Publish-Explorer.ps1 and pass its self-contained PublishDirectory.' }
 $publish=Get-LpPath $PublishDirectory -Directory;$manifestPath=Join-Path $publish 'host-component-manifest.json';$manifest=Get-LpJson $manifestPath
  if ($manifest.ContractVersion -ne 3 -or $manifest.ModelMode -cne 'Absent' -or $manifest.AlgorithmMode -cne 'Heuristic' -or $manifest.SelfContained -isnot [bool] -or -not $manifest.SelfContained -or $manifest.RuntimeVersion -cne '10.0.15' -or $manifest.RuntimeIdentifier -cne 'win-x64' -or $manifest.RuntimeRoot -cne '.' -or $manifest.Launch.Executable -cne 'sjc-explorer.exe') { throw 'Explicit repaired self-contained Absent/Heuristic Host required.' }
 $inputManifestHash=Get-LpHash $manifestPath
 Assert-LpNoModelPayload $manifest.Components
 Assert-LpExactFiles $publish $manifest.Components @('host-component-manifest.json')
 foreach ($p in @('coreclr.dll','hostfxr.dll','hostpolicy.dll','sjc-explorer.exe','e_sqlite3.dll')) { if ($manifest.Components.Path -cnotcontains $p) { throw 'Incomplete self-contained Host.' } }
 if (-not $StageDevelopment) {
  [pscustomobject]@{Manifest=$manifestPath;ManifestSHA256=(Get-LpHash $manifestPath);ModelMode='Absent';AlgorithmMode='Heuristic';PointerWritten=$false} | ConvertTo-Json
  return
 }
 if ($manifest.DevelopmentOnly -isnot [bool] -or -not $manifest.DevelopmentOnly -or $manifest.SealedRelease -isnot [bool] -or $manifest.SealedRelease -or @($manifest.Launch.Arguments).Count -ne 0 -or $manifest.Launch.WorkingDirectory -cne '.') { throw 'Only fixed apphost private development staging is accepted.' }
 if ($manifest.SourceProvenance.PSObject.Properties['Purpose'] -and $manifest.SourceProvenance.Purpose -ceq 'SizeProbe') { throw 'SizeProbe output is measurement only, not a development pointer source.' }
 $repositoryRoot=Get-LpPath $Repository -Directory
 Assert-LpHostDependencyProvenance $manifest.SourceProvenance $repositoryRoot
 foreach ($source in @($manifest.SourceProvenance.Sources)) { if ($source.Path -match '^engine/Explorer\.Model/') { throw 'Development source includes removed model project.' } }
 Assert-LpRecordSet $manifest.SourceProvenance.Sources @('engine/Directory.Build.props','engine/Explorer.Host/Explorer.Host.csproj') $repositoryRoot
 $null=Assert-LpHostSourceProvenance $manifest.SourceProvenance $repositoryRoot
 $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
 function Assert-PrivateDevelopmentPath([string]$Path,[switch]$PrivateRoot) {
  for ($p=[IO.Path]::GetFullPath($Path);$p;$p=[IO.Path]::GetDirectoryName($p)) { if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Linked private development execution path.' } }
  if ($PrivateRoot) {
   $acl=[IO.Directory]::GetAccessControl($Path)
   if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or -not $acl.AreAccessRulesProtected) { throw 'Development cache owner/inheritance mismatch.' }
   foreach ($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) { if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -ne $sid.Value) { throw 'Development cache is not private to this user.' } }
  }
 }
 function New-PrivateDevelopmentPath([string]$Path) {
  Assert-PrivateDevelopmentPath ([IO.Path]::GetDirectoryName($Path))
  if (Test-Path -LiteralPath $Path) { throw 'Development stage must be a new GUID directory.' }
  $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
  $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
  [void][IO.Directory]::CreateDirectory($Path);[IO.Directory]::SetAccessControl($Path,$acl)
  Assert-PrivateDevelopmentPath $Path -PrivateRoot
 }
 $parent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJunkCleaner'
 if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) };Assert-PrivateDevelopmentPath $parent
 $cache=Join-Path $parent 'explorer-dev-runtime'
 if ([IO.Directory]::Exists($cache)) { Assert-PrivateDevelopmentPath $cache -PrivateRoot } else { New-PrivateDevelopmentPath $cache }
 $current=Join-Path $cache 'current.json';$oldBytes=$null;$oldHash=$null
 if ([IO.File]::Exists($current)) {
  Assert-PrivateDevelopmentPath $current
  if (-not $ExpectedCurrentSHA256 -or (Get-LpHash $current) -ne $ExpectedCurrentSHA256) { throw 'Read known current.json first and pass its ExpectedCurrentSHA256; refusing blind overwrite.' }
  if ([IO.File]::GetAccessControl($current).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value) { throw 'Development pointer owner mismatch.' }
  $old=Get-LpJson $current;$oldGuid=[guid]::Empty
  if ($old.SchemaVersion -ne 1 -or $old.ContractVersion -notin @(2,3) -or $old.Manifest -cne 'host-component-manifest.json' -or -not [guid]::TryParseExact([string]$old.BuildId,'D',[ref]$oldGuid)) { throw 'Unrecognized project development pointer; refusing overwrite.' }
  $oldManifest=Join-Path (Join-Path $cache $old.BuildId) 'host-component-manifest.json'
  Assert-PrivateDevelopmentPath $oldManifest
  if ((Get-LpHash $oldManifest) -ne $old.ManifestSha256) { throw 'Previous known development pointer manifest hash mismatch.' }
  $oldHost=Get-LpJson $oldManifest
  if ($oldHost.BuildId -cne $old.BuildId -or $oldHost.SchemaVersion -ne 1 -or $oldHost.ContractVersion -ne $old.ContractVersion -or $oldHost.DevelopmentOnly -isnot [bool] -or -not $oldHost.DevelopmentOnly) { throw 'Previous pointer is not the recognized private project development manifest.' }
  $oldBytes=[IO.File]::ReadAllBytes($current);$oldHash=Get-LpHash $current
 } elseif ($ExpectedCurrentSHA256) { throw 'Expected current pointer disappeared.' }
 $id=[guid]::NewGuid().ToString('D');$runtimeRoot=Join-Path $cache $id;New-PrivateDevelopmentPath $runtimeRoot
 foreach ($record in @($manifest.Components)) {
  $relative=Get-LpCandidateName $record.Path;$dest=Join-Path $runtimeRoot $relative
  [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));[IO.File]::Copy((Join-Path $publish $relative),$dest,$false)
  Assert-PrivateDevelopmentPath $dest
  if ((Get-LpHash $dest) -ne $record.Sha256) { throw 'Development staged file hash mismatch.' }
 }
 $manifest.BuildId=$id;$manifest | Add-Member NoteProperty DevelopmentRepository $repositoryRoot -Force
 $stagedManifest=Join-Path $runtimeRoot 'host-component-manifest.json';$encoding=New-Object Text.UTF8Encoding($false)
 [IO.File]::WriteAllText($stagedManifest,($manifest|ConvertTo-Json -Depth 28),$encoding)
 Assert-LpExactFiles $runtimeRoot $manifest.Components @('host-component-manifest.json')
 Assert-LpExactFiles $publish $manifest.Components @('host-component-manifest.json')
 if ((Get-LpHash $manifestPath) -ne $inputManifestHash) { throw 'Input Host manifest changed during development staging.' }
 $null=Assert-LpHostSourceProvenance $manifest.SourceProvenance $repositoryRoot
 $hash=Get-LpHash $stagedManifest
 $pointer=@{SchemaVersion=1;ContractVersion=3;BuildId=$id;Manifest='host-component-manifest.json';ManifestSha256=$hash}
 $temp=Join-Path $cache ('.current-'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllText($temp,($pointer|ConvertTo-Json),$encoding)
 $backup=$null
 if ($null -ne $oldBytes) {
  if ((Get-LpHash $current) -ne $oldHash) { throw 'Known current pointer changed concurrently.' }
  $backup=Join-Path $cache ('.previous-'+[guid]::NewGuid().ToString('N')+'.json')
  [IO.File]::Replace($temp,$current,$backup)
  if ((Get-LpHash $backup) -ne $oldHash) { throw 'Original current pointer backup mismatch.' }
 } else { if (Test-Path -LiteralPath $current) { throw 'Concurrent development pointer creation.' };[IO.File]::Move($temp,$current) }
 [pscustomobject]@{Status='DevelopmentOnly';ContractVersion=3;ModelMode='Absent';AlgorithmMode='Heuristic';RuntimeRoot=$runtimeRoot;Manifest=$stagedManifest;ManifestSHA256=$hash;Pointer=$current;PointerWritten=$true;PreviousPointerBackup=$backup;FinalVerified=$false} | ConvertTo-Json
 return
}
if ($version -cne '0.13.0') { throw 'Unsupported development manifest version.' }
$artifact=[IO.Path]::GetFullPath((Join-Path $Repository 'artifacts\explorer'))
$sourceRoot=Join-Path $artifact 'bin\Explorer.Host\Release\net10.0-windows'
$runtimeVersion='10.0.15';$systemRoot=Join-Path $env:ProgramFiles 'dotnet';$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
function Assert-Unlinked([string]$Path){
 for($p=[IO.Path]::GetFullPath($Path);$p;$p=[IO.Path]::GetDirectoryName($p)){
  if(([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw ('Linked execution component/ancestor: '+$p)}
 }
}
function New-Private([string]$Path){
 $parent=[IO.Path]::GetDirectoryName($Path);Assert-Unlinked $parent
 if(!(Test-Path -LiteralPath $Path)){[void][IO.Directory]::CreateDirectory($Path)}
 Assert-Unlinked $Path
 $acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false)
 $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
 [IO.Directory]::SetAccessControl($Path,$acl)
}
$parent=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJunkCleaner'
if(!(Test-Path -LiteralPath $parent)){[void][IO.Directory]::CreateDirectory($parent)};Assert-Unlinked $parent
$cache=Join-Path $parent 'explorer-dev-runtime'
if(Test-Path -LiteralPath $cache){
 Assert-Unlinked $cache;$acl=[IO.Directory]::GetAccessControl($cache)
 if($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value -or !$acl.AreAccessRulesProtected){throw 'Existing runtime cache ownership/ACL mismatch'}
 foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -ne $sid.Value){throw 'Existing runtime cache is not private'}}
}else{New-Private $cache}
$buildId=[guid]::NewGuid().ToString('D');$runtimeRoot=Join-Path $cache $buildId
if(Test-Path -LiteralPath $runtimeRoot){throw 'Runtime destination must be new'};New-Private $runtimeRoot
$files=@(Get-ChildItem -LiteralPath $sourceRoot -File | Where-Object {$_.Extension -in @('.dll','.json')})
$native=Get-Item -LiteralPath (Join-Path $sourceRoot 'runtimes\win-x64\native\e_sqlite3.dll')
$total=($files|Measure-Object Length -Sum).Sum+$native.Length
if($total -gt 500MB){throw 'Runtime copy would exceed 500MB budget'}
$components=@()
foreach($f in $files){
 $expected=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
 $destination=Join-Path $runtimeRoot $f.Name;[IO.File]::Copy($f.FullName,$destination,$false);Assert-Unlinked $destination
 $actual=(Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
 if($actual -ne $expected){throw 'Staged component differs from built source'}
 $components+=@{Path=$f.Name;Sha256=$actual;Bytes=$f.Length}
}
$nativeRoot=Join-Path $runtimeRoot 'runtimes\win-x64\native';[void][IO.Directory]::CreateDirectory($nativeRoot)
$nativePath=Join-Path $nativeRoot 'e_sqlite3.dll';$expected=(Get-FileHash -LiteralPath $native.FullName -Algorithm SHA256).Hash
[IO.File]::Copy($native.FullName,$nativePath,$false);Assert-Unlinked $nativePath
if((Get-FileHash -LiteralPath $nativePath -Algorithm SHA256).Hash -ne $expected){throw 'Staged SQLite differs'}
$components+=@{Path='runtimes/win-x64/native/e_sqlite3.dll';Sha256=$expected;Bytes=$native.Length}
$systemFiles=@(Get-Item -LiteralPath (Join-Path $systemRoot 'dotnet.exe'),(Join-Path $systemRoot ('host\fxr\'+$runtimeVersion+'\hostfxr.dll')))
$systemFiles+=@(Get-ChildItem -LiteralPath (Join-Path $systemRoot ('shared\Microsoft.NETCore.App\'+$runtimeVersion)) -File)
$systemComponents=@($systemFiles|ForEach-Object {Assert-Unlinked $_.FullName;@{Path=$_.FullName.Substring($systemRoot.Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash;Bytes=$_.Length}})
$sources=@(Get-ChildItem -LiteralPath (Join-Path $Repository 'engine') -File -Recurse|Where-Object {$_.Extension -in @('.cs','.csproj','.props','.json')}|Sort-Object FullName|ForEach-Object {@{Path=$_.FullName.Substring($Repository.TrimEnd('\').Length+1).Replace('\','/');Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
$sha=[Security.Cryptography.SHA256]::Create();try{$sourceHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($sources|ConvertTo-Json -Compress -Depth 5))))).Replace('-','')}finally{$sha.Dispose()}
$git=(& git -C $Repository rev-parse HEAD).Trim();if($LASTEXITCODE -ne 0){throw 'Cannot bind git source'}
$manifest=@{SchemaVersion=1;ContractVersion=2;BuildId=$buildId;RuntimeRoot='.';DevelopmentOnly=$true;Trust='Private local development staging; not a signed distribution trust root';GeneratedUtc=[DateTime]::UtcNow.ToString('o');SourceProvenance=@{GitCommit=$git;SourceSetSha256=$sourceHash;Sources=$sources};Components=$components;SystemRuntime=@{RootKind='ProgramFilesDotnet';Framework='Microsoft.NETCore.App';Version=$runtimeVersion;Components=$systemComponents};Launch=@{ExecutableKind='ProgramFilesDotnet';Arguments=@('sjc-explorer.dll');WorkingDirectory='.'}}
$manifestPath=Join-Path $runtimeRoot 'host-component-manifest.json';$encoding=New-Object Text.UTF8Encoding($false)
[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 9),$encoding)
$hash=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
$pointer=@{SchemaVersion=1;ContractVersion=2;BuildId=$buildId;Manifest='host-component-manifest.json';ManifestSha256=$hash}
$temp=Join-Path $cache ('.current-'+[guid]::NewGuid().ToString('N')+'.tmp');[IO.File]::WriteAllText($temp,($pointer|ConvertTo-Json),$encoding)
$current=Join-Path $cache 'current.json'
if(Test-Path -LiteralPath $current){Assert-Unlinked $current;if([IO.File]::GetAccessControl($current).GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid.Value){throw 'Runtime pointer owner mismatch'};$backup=Join-Path $cache ('.previous-'+[guid]::NewGuid().ToString('N')+'.json');[IO.File]::Replace($temp,$current,$backup);[IO.File]::Delete($backup)}else{[IO.File]::Move($temp,$current)}
[IO.File]::WriteAllText((Join-Path $artifact 'host-component-manifest.json'),($manifest|ConvertTo-Json -Depth 9),$encoding)
[IO.File]::WriteAllText((Join-Path $artifact 'host-runtime-pointer.json'),(@{Pointer=$current;RuntimeRoot=$runtimeRoot;Manifest=$manifestPath;ManifestSha256=$hash;CopiedBytes=$total}|ConvertTo-Json),$encoding)
Write-Output ('Host runtime staged '+$total+' bytes; manifest '+$manifestPath+'; pointer '+$current)
