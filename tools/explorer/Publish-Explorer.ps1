#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository,[string]$ResumeBuildId,[string]$SdkDirectory,[string]$NuGetPackagesDirectory,[switch]$AllowPackageDownload,[switch]$SizeProbe,[string]$RuntimePackFeed)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$Repository=[IO.Path]::GetFullPath($Repository).TrimEnd('\')
. (Join-Path $Repository 'scripts/local-promotion-common.ps1')
# A fresh Windows PowerShell process does not auto-load ZipArchive when only
# System.IO.Compression.FileSystem is loaded. Both are required by the ZIP gate.
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
function Invoke-ExplorerNative {
 param([string]$FilePath,[string[]]$Arguments,[string]$LogPath,[string]$FailureMessage)
 # Windows PowerShell 5.1 wraps redirected native stderr in ErrorRecords. With
 # EAP=Stop, even a successful dotnet first-run diagnostic used to abort before
 # Tee-Object created a log. Read BOTH pipes concurrently outside that pipeline;
 # preserve diagnostics and decide success exclusively from the real exit code.
 $log=Get-LpPath $LogPath
 $logStream=[IO.File]::Open($log,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
 $writer=[IO.StreamWriter]::new($logStream,[Text.UTF8Encoding]::new($true))
 $info=[Diagnostics.ProcessStartInfo]::new()
 $info.FileName=$FilePath
 $info.Arguments=(@($Arguments | ForEach-Object { '"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"' }) -join ' ')
 $info.WorkingDirectory=$Repository
 $info.UseShellExecute=$false;$info.CreateNoWindow=$true
 $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $info.StandardOutputEncoding=[Text.UTF8Encoding]::new($false);$info.StandardErrorEncoding=[Text.UTF8Encoding]::new($false)
 $process=[Diagnostics.Process]::new();$process.StartInfo=$info
 try {
  $writer.WriteLine('Command: '+$FilePath+' '+$info.Arguments);$writer.Flush()
  if (-not $process.Start()) { throw 'Native process did not start.' }
  $stdoutRead=$process.StandardOutput.ReadToEndAsync();$stderrRead=$process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $exitCode=$process.ExitCode
  $stdout=$stdoutRead.GetAwaiter().GetResult();$stderr=$stderrRead.GetAwaiter().GetResult()
  $writer.WriteLine('=== stdout ===');$writer.Write($stdout);$writer.WriteLine()
  $writer.WriteLine('=== stderr ===');$writer.Write($stderr);$writer.WriteLine()
  $writer.WriteLine('ExitCode: '+$exitCode);$writer.Flush()
  [Console]::Out.Write($stdout);[Console]::Out.Write($stderr)
  if ($exitCode -ne 0) { throw ($FailureMessage+' (exit '+$exitCode+'); retained log: '+$log) }
  return [pscustomobject]@{ExitCode=$exitCode;LogPath=$log}
 } catch {
  $writer.WriteLine('InvocationFailure: '+$_.Exception.Message);$writer.Flush();throw
 } finally { $writer.Dispose();$logStream.Dispose();$process.Dispose() }
}
$version=(Get-LpJson (Join-Path $Repository 'version.json')).version
$noModel=Test-LpNoModelVersion $version;$contract=if ($noModel) { 3 } else { 2 }
if (-not $noModel -and $version -cne '0.13.0') { throw 'Unsupported Host publish version.' }
if ($noModel -and $ResumeBuildId -and -not $SizeProbe) { throw '0.14 final/development publish always uses fresh GUID directories; only an incomplete SizeProbe may resume.' }
$sourceSnapshot=if ($noModel) { @(Get-LpHostSources $Repository) } else { @(Get-LpWorkingSources $Repository) };$sourceSetHash=Get-LpSourceSetHash $sourceSnapshot
if($ResumeBuildId -and ![guid]::TryParseExact($ResumeBuildId,'D',[ref]([guid]::Empty))){throw 'Invalid resume build ID'}
$artifact=Join-Path $Repository 'artifacts\explorer';$id=if($ResumeBuildId){$ResumeBuildId}else{[guid]::NewGuid().ToString('D')}
$scope=if ($SizeProbe) { 'SizeProbe' } else { 'publish' }
$work=Join-Path $artifact ($scope+'-work-'+$id);$output=Join-Path $artifact ($scope+'-'+$id)
if(!$ResumeBuildId -and ((Test-Path -LiteralPath $work) -or (Test-Path -LiteralPath $output))){throw 'Publish requires new empty directories'}
if($ResumeBuildId -and !(Test-Path -LiteralPath $work)){throw 'Resume only an existing private publish work ID'}
if ($SizeProbe -and $ResumeBuildId) {
 if ([IO.File]::Exists((Join-Path $work 'evidence/measurement.json')) -or [IO.File]::Exists((Join-Path $work 'host-measurement.zip')) -or @([IO.Directory]::EnumerateFileSystemEntries($output)).Count) { throw 'Only a pre-publish incomplete SizeProbe may resume; measured/compiled payload is retained unchanged.' }
 foreach ($name in @('restore.log','locked-restore.log','publish.log')) {
  $oldLog=Join-Path $work ('evidence/'+$name)
  if ([IO.File]::Exists($oldLog)) { [IO.File]::Move($oldLog,(Join-Path $work ('evidence/'+$name+'.failed-'+[guid]::NewGuid().ToString('N')))) }
 }
}
foreach($p in @($work,$output,(Join-Path $work 'feed'),(Join-Path $work 'evidence'))){[void][IO.Directory]::CreateDirectory($p)}
$env:DOTNET_ROOT=if ($SdkDirectory) { Get-LpPath $SdkDirectory -Directory } else { Join-Path $artifact 'toolchain\sdk' };$env:DOTNET_CLI_HOME=Join-Path $artifact 'home'
$env:NUGET_PACKAGES=if ($NuGetPackagesDirectory) { Get-LpPath $NuGetPackagesDirectory -Directory } else { Join-Path $artifact 'nuget' };$env:NUGET_HTTP_CACHE_PATH=Join-Path $artifact 'cache';$env:TEMP=Join-Path $artifact 'temp';$env:TMP=$env:TEMP
foreach ($p in @($env:DOTNET_CLI_HOME,$env:NUGET_PACKAGES,$env:NUGET_HTTP_CACHE_PATH,$env:TEMP)) { [void][IO.Directory]::CreateDirectory($p) }
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US';$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe';$runtimeVersion='10.0.15';$downloaded=0L;$provenance=@()
if (-not [IO.File]::Exists($dotnet)) { throw 'Explicit/local isolated SDK missing. Obtain the authorized fixed SDK separately; publish never installs one.' }
$env:DOTNET_MULTILEVEL_LOOKUP='0';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:MSBUILDDISABLENODEREUSE='1'
# Resolve only the approved, fixed Microsoft runtime/apphost packs; no install script.
$reusedPacks=@()
if ($RuntimePackFeed) {
 $RuntimePackFeed=Get-LpPath $RuntimePackFeed -Directory
 $reusedPacks=@(Get-LpJson (Join-Path (Split-Path -Parent $RuntimePackFeed) 'evidence/runtime-pack-provenance.json'))
 if ($noModel) {
  # Validate reused official pack identities and hashes without downloading again.
  foreach ($pack in $reusedPacks) { $p=Join-Path $RuntimePackFeed ($pack.Id.ToLowerInvariant()+'.'+$pack.Version+'.nupkg');if ((Get-FileHash -LiteralPath $p -Algorithm SHA512).Hash -ne $pack.Sha512) { throw 'Explicit reused runtime pack hash mismatch.' } }
 }
}
if(!$ResumeBuildId){
foreach($name in @('Microsoft.NETCore.App.Runtime.win-x64','Microsoft.NETCore.App.Host.win-x64')){
 $lower=$name.ToLowerInvariant();$download=Join-Path $work ('download-'+$lower);[void][IO.Directory]::CreateDirectory($download)
 $base='https://api.nuget.org/v3-flatcontainer/'+$lower+'/'+$runtimeVersion+'/'
 $cached=Join-Path $env:NUGET_PACKAGES ($lower+'/'+$runtimeVersion+'/'+$lower+'.'+$runtimeVersion+'.nupkg')
 $nupkg=Join-Path $download ($lower+'.'+$runtimeVersion+'.nupkg');$effective=$null
 $reused=@($reusedPacks | Where-Object { $_.Id -ceq $name -and $_.Version -ceq $runtimeVersion })
 if ($RuntimePackFeed -and $reused.Count -eq 1) {
  $pack=Join-Path $RuntimePackFeed ($lower+'.'+$runtimeVersion+'.nupkg');[IO.File]::Copy($pack,$nupkg,$false)
  $metadataText=[IO.File]::ReadAllText((Join-Path (Split-Path -Parent $RuntimePackFeed) ('download-'+$lower+'/package.nuspec')));$effective=$reused[0].EffectiveDownloadUrl
 }
 elseif ([IO.File]::Exists($cached)) { [IO.File]::Copy($cached,$nupkg,$false);$metadataText=[IO.File]::ReadAllText((Join-Path $env:NUGET_PACKAGES ($lower+'/'+$runtimeVersion+'/'+$lower+'.nuspec'))) }
 else {
  if (-not $AllowPackageDownload) { throw "Fixed runtime package missing; explicit -AllowPackageDownload required: $name $runtimeVersion" }
  $metadata=Invoke-WebRequest -UseBasicParsing ($base+$lower+'.nuspec');$metadataText=$metadata.Content
  $request=[Net.HttpWebRequest]::Create($base+$lower+'.'+$runtimeVersion+'.nupkg');$request.AllowAutoRedirect=$true;$request.Timeout=60000
  $response=$request.GetResponse()
  try{
   if($response.ContentLength -gt 500MB-$downloaded){throw 'Runtime download would exceed 500MB'}
   $input=$response.GetResponseStream();$file=[IO.File]::Open($nupkg,[IO.FileMode]::CreateNew)
   try{$buffer=New-Object byte[] 65536;while(($n=$input.Read($buffer,0,$buffer.Length)) -gt 0){$downloaded+=$n;if($downloaded -gt 500MB){throw 'Runtime download exceeds 500MB'};$file.Write($buffer,0,$n)}}finally{$file.Dispose();$input.Dispose()}
   $effective=$response.ResponseUri.AbsoluteUri
  }finally{$response.Dispose()}
 }
 [xml]$xml=$metadataText;$m=$xml.package.metadata
 if($m.id -ne $name -or $m.version -ne $runtimeVersion -or $m.authors -ne 'Microsoft' -or $m.license.'#text' -ne 'MIT' -or $m.repository.url -ne 'https://github.com/dotnet/dotnet'){throw 'Unexpected runtime pack identity/license/source'}
 [IO.File]::WriteAllText((Join-Path $download 'package.nuspec'),$metadataText)
  $hash=(Get-FileHash -LiteralPath $nupkg -Algorithm SHA512).Hash
  $pin=@(Get-LpApprovedRuntimePacks | Where-Object Id -CEQ $name)[0]
  if ($hash -ne $pin.Sha512 -or ([IO.FileInfo]$nupkg).Length -ne $pin.Bytes -or $m.repository.commit -cne $pin.Commit) { throw 'Runtime package bytes/source differ from the fixed official security repair.' }
 if ($RuntimePackFeed -and $reused.Count -eq 1 -and $hash -ne $reused[0].Sha512) { throw 'Reused runtime package changed during copy.' }
 $provenance+=@{Id=$name;Version=$runtimeVersion;License='MIT';Repository=$m.repository.url;Commit=$m.repository.commit;MetadataUrl=$base+$lower+'.nuspec';EffectiveDownloadUrl=$effective;Sha512=$hash;Bytes=(Get-Item -LiteralPath $nupkg).Length;ReusedCache=([IO.File]::Exists($cached) -or ($RuntimePackFeed -and $reused.Count -eq 1))}
 [IO.File]::Copy($nupkg,(Join-Path (Join-Path $work 'feed') ([IO.Path]::GetFileName($nupkg))),$false)
}
$provenance|ConvertTo-Json -Depth 5|Set-Content -Encoding UTF8 (Join-Path $work 'evidence\runtime-pack-provenance.json')
}else{
 $provenance=Get-Content -Raw -LiteralPath (Join-Path $work 'evidence\runtime-pack-provenance.json')|ConvertFrom-Json
 foreach($p in $provenance){$file=Join-Path (Join-Path $work 'feed') ($p.Id.ToLowerInvariant()+'.'+$p.Version+'.nupkg');if((Get-FileHash -LiteralPath $file -Algorithm SHA512).Hash -ne $p.Sha512){throw 'Cached runtime pack changed'};$downloaded+=$p.Bytes}
}
# Build a byte-identical source copy. RID-specific lock generation never mutates frozen source locks.
$projects=@(Get-LpHostProjects $Repository)
if (-not $noModel) { $projects += 'Explorer.Model' }
$sourceFiles=@(Get-Item -LiteralPath (Join-Path $Repository 'engine\Directory.Build.props'))
foreach($project in $projects){$sourceFiles+=@(Get-LpCandidateFiles (Join-Path $Repository ('engine\'+$project)) -SourceOnly | Where-Object {$_.Extension -in @('.cs','.csproj','.json')})}
if ($noModel) { foreach ($f in @($sourceFiles | Where-Object Extension -EQ '.csproj')) { if ([IO.File]::ReadAllText($f.FullName) -match '(?i)Explorer\.Model|llama|gguf') { throw 'Product project references a model experiment.' } } }
$sources=@()
foreach($f in $sourceFiles){
 $relative=$f.FullName.Substring($Repository.Length+1);$dest=Join-Path $work $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
 $hash=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash;if(Test-Path -LiteralPath $dest){if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $hash -and $f.Name -ne 'packages.lock.json'){[IO.File]::Copy($f.FullName,$dest,$true)}}else{[IO.File]::Copy($f.FullName,$dest,$false)}
 if($f.Name -ne 'packages.lock.json' -and (Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $hash){throw 'Frozen source copy mismatch'}
 $sources+=@{Path=$relative.Replace('\','/');Sha256=$hash;Bytes=$f.Length}
}
$project=Join-Path $work 'engine\Explorer.Host\Explorer.Host.csproj'
$props=@('-p:RuntimeIdentifier=win-x64','-p:SelfContained=true','-p:DisableTransitiveFrameworkReferenceDownloads=true',('-p:RuntimeFrameworkVersion='+$runtimeVersion),'-p:PublishSingleFile=false','-p:PublishTrimmed=false','-p:PublishReadyToRun=false')
# Isolated config avoids command-line source normalization turning HTTPS into a local Windows path.
$config=Join-Path $work 'NuGet.Config'
$feedXml=[Security.SecurityElement]::Escape((Join-Path $work 'feed'));$cacheXml=[Security.SecurityElement]::Escape($env:NUGET_PACKAGES)
$remoteXml=if ($AllowPackageDownload) { '<add key="official-nuget" value="https://api.nuget.org/v3/index.json" />' } else { '' }
[IO.File]::WriteAllText($config,('<?xml version="1.0" encoding="utf-8"?><configuration><packageSources><clear/><add key="fixed-runtime-feed" value="'+$feedXml+'"/><add key="isolated-package-cache" value="'+$cacheXml+'"/>'+$remoteXml+'</packageSources></configuration>'),[Text.UTF8Encoding]::new($false))
# Original fixed locks are retained in SourceProvenance; RID-specific locks are generated only in the isolated source copy.
$null=Invoke-ExplorerNative $dotnet (@('restore',$project,'--configfile',$config,'--disable-parallel')+$props) (Join-Path $work 'evidence\restore.log') 'Self-contained restore failed'
$null=Invoke-ExplorerNative $dotnet (@('restore',$project,'--configfile',$config,'--disable-parallel','--locked-mode')+$props) (Join-Path $work 'evidence\locked-restore.log') 'Locked runtime restore failed'
if($version -ceq '0.17.0'){
 $quick=Join-Path $work 'engine/QuickClean.Host/QuickClean.Host.csproj'
 $null=Invoke-ExplorerNative $dotnet (@('restore',$quick,'--locked-mode','--configfile',$config)+$props) (Join-Path $work 'evidence/quick-restore.log') 'QuickClean locked restore failed'
}
foreach($source in $sources){if((Get-FileHash -LiteralPath (Join-Path $Repository $source.Path) -Algorithm SHA256).Hash -ne $source.Sha256){throw 'Frozen sources changed during restore; candidate not sealed'}}
$locks=@();foreach($p in $projects){$lock=Join-Path $work ('engine\'+$p+'\packages.lock.json');$content=Get-Content -Raw -LiteralPath $lock|ConvertFrom-Json
  foreach ($framework in $content.dependencies.PSObject.Properties) { foreach ($dependency in $framework.Value.PSObject.Properties) { $d=$dependency.Value;if ($d.type -ceq 'Project') { continue };$allowed=@{'Microsoft.NETCore.App.Runtime.win-x64'='10.0.15';'Microsoft.NETCore.App.Host.win-x64'='10.0.15';'Microsoft.Data.Sqlite'='10.0.14';'Microsoft.Data.Sqlite.Core'='10.0.14';'SQLitePCLRaw.core'='2.1.13';'SQLitePCLRaw.bundle_e_sqlite3'='2.1.13';'SQLitePCLRaw.provider.e_sqlite3'='2.1.13';'SQLitePCLRaw.lib.e_sqlite3'='2.1.13'};if (-not $allowed.ContainsKey($dependency.Name) -or $d.resolved -cne $allowed[$dependency.Name]) { throw ('Dependency is outside fixed approved locks: '+$dependency.Name) } } }
 $locks+=@{Project=$p;Sha256=(Get-FileHash -LiteralPath $lock -Algorithm SHA256).Hash;Content=$content}}
if ($noModel) { Assert-LpHostDependencyProvenance ([pscustomobject]@{RuntimePacks=$provenance;LockedRestore=$locks}) $Repository }
$null=Invoke-ExplorerNative $dotnet (@('publish',$project,'--no-restore','--configuration','Release','--output',$output,'--disable-build-servers')+$props) (Join-Path $work 'evidence\publish.log') 'Self-contained publish failed'
if($version -ceq '0.17.0'){
 $qout=Join-Path $work 'quick-publish';$null=Invoke-ExplorerNative $dotnet (@('publish',$quick,'--no-restore','-c','Release','--output',$qout,'--disable-build-servers')+$props) (Join-Path $work 'evidence/quick-publish.log') 'QuickClean publish failed'
 foreach($f in @(Get-LpCandidateFiles $qout)){$r=$f.FullName.Substring($qout.Length+1);$p=Join-Path $output $r;if([IO.File]::Exists($p)){if((Get-LpHash $p) -ne (Get-LpHash $f.FullName)){throw "Shared runtime bytes differ: $r"}}else{[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p));[IO.File]::Copy($f.FullName,$p,$false)}}
}
foreach($source in $sources){if((Get-FileHash -LiteralPath (Join-Path $Repository $source.Path) -Algorithm SHA256).Hash -ne $source.Sha256){throw 'Frozen sources changed during publish; candidate not sealed'}}
$licenses=Join-Path $output 'licenses';[void][IO.Directory]::CreateDirectory($licenses)
foreach($p in @(@('microsoft.netcore.app.runtime.win-x64',$runtimeVersion),@('microsoft.netcore.app.host.win-x64',$runtimeVersion),@('microsoft.data.sqlite','10.0.14'),@('microsoft.data.sqlite.core','10.0.14'),@('sqlitepclraw.core','2.1.13'),@('sqlitepclraw.bundle_e_sqlite3','2.1.13'),@('sqlitepclraw.provider.e_sqlite3','2.1.13'),@('sqlitepclraw.lib.e_sqlite3','2.1.13'))){
 $cache=Join-Path $env:NUGET_PACKAGES ($p[0]+'\'+$p[1]);$dest=Join-Path $licenses ($p[0]+'-'+$p[1]);[void][IO.Directory]::CreateDirectory($dest)
 if(!(Test-Path -LiteralPath $cache) -and $p[0] -eq 'microsoft.netcore.app.host.win-x64'){
  $package=Join-Path (Join-Path $work 'feed') ($p[0]+'.'+$p[1]+'.nupkg');$extract=Join-Path $work 'host-pack-license'
  if(!(Test-Path -LiteralPath $extract)){[void][IO.Directory]::CreateDirectory($extract);Add-Type -AssemblyName System.IO.Compression.FileSystem;$zip=[IO.Compression.ZipFile]::OpenRead($package);try{foreach($entry in $zip.Entries){if($entry.FullName -notmatch '[/\\]' -and $entry.FullName -match '(?i)license|third.party|\.nuspec$'){[IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $extract $entry.FullName),$false)}}}finally{$zip.Dispose()}}
  $cache=$extract
 }
 $notices=@(Get-ChildItem -LiteralPath $cache -File | Where-Object {$_.Name -match '(?i)license|third.party|\.nuspec$'})
 if($notices.Count -eq 0){throw ('Missing package license metadata '+$p[0])}
 foreach($notice in $notices){if(Test-Path -LiteralPath (Join-Path $dest $notice.Name)){if((Get-FileHash -LiteralPath $notice.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $dest $notice.Name)).Hash){throw 'Existing license differs'}}else{[IO.File]::Copy($notice.FullName,(Join-Path $dest $notice.Name),$false)}}
}
if(!(Test-Path -LiteralPath (Join-Path $licenses 'SafeJunkCleaner-LICENSE'))){[IO.File]::Copy((Join-Path $Repository 'LICENSE'),(Join-Path $licenses 'SafeJunkCleaner-LICENSE'),$false)}
$encoding=New-Object Text.UTF8Encoding($false)
$startText=if ($noModel) { "Development self-contained win-x64 Host, ContractVersion 3, ModelMode=Absent, AlgorithmMode=Heuristic. Not desktop acceptance or a sealed release.`r`nExtract to an ordinary local non-cloud directory. No SDK/dotnet installation or network required to run sjc-explorer.exe.`r`nUTF-8 JSONL stdin/stdout, diagnostics stderr. Historical model caches are neither read nor activated. Only explicit sealed approvals may execute recycling. Runtime/SQLite notices are in licenses/.`r`n" } else { "Development self-contained win-x64 Host, ContractVersion 2. Model component supplied separately in sibling model/. Runtime/dependency notices in licenses/.`r`n" }
[IO.File]::WriteAllText((Join-Path $output 'START.txt'),$startText,$encoding)
$sourceProvenance=@{GitCommit=((Invoke-LpGit $Repository @('rev-parse','--verify','HEAD')) -join '');ContractVersion=$contract;SourceSetSha256=$sourceSetHash;ComponentSourceSetSha256=$sourceSetHash;SourceScope=if($noModel){'ExplorerHostComponent'}else{'HistoricalWorkingSources'};Sources=$sources;RuntimePacks=$provenance;LockedRestore=$locks;DownloadedBytes=$downloaded;Purpose=if($SizeProbe){'SizeProbe'}else{'DevelopmentPublish'};FinalSourceBinding=(-not $SizeProbe)}
[IO.File]::WriteAllText((Join-Path $work 'evidence\source-provenance.json'),($sourceProvenance|ConvertTo-Json -Depth 24),$encoding)
$published=@(Get-LpCandidateFiles $output | Where-Object {$_.Name -ne 'host-component-manifest.json'});$bytes=($published|Measure-Object Length -Sum).Sum
$payloadRecords=@($published | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($output.Length+1).Replace('\','/');SHA256=(Get-LpHash $_.FullName);Bytes=$_.Length} })
if ($noModel) { Assert-LpNoModelPayload $payloadRecords }
$measurementZip=Join-Path $work 'host-measurement.zip';Add-Type -AssemblyName System.IO.Compression.FileSystem
New-LpCandidateZip $measurementZip $output $payloadRecords
$measurement=@{Schema='SafeJunkCleaner.HostMeasurement.v1';Purpose=if($SizeProbe){'SizeProbe'}else{'DevelopmentPublish'};FinalSourceBinding=(-not $SizeProbe);Version=$version;ModelMode=if ($noModel) {'Absent'} else {'Historical'};AlgorithmMode=if ($noModel) {'Heuristic'} else {'Historical'};Files=$published.Count;ExtractedBytes=$bytes;ZipBytes=([IO.FileInfo]$measurementZip).Length;WithinTarget=($bytes -le 100MB -and ([IO.FileInfo]$measurementZip).Length -le 50MB);SourceSetSha256=$sourceSetHash;DesktopAcceptance='NotRun';PublishDirectory=$output;IncludesProductExe=$false;IncludesHostManifest=$false}
[IO.File]::WriteAllText((Join-Path $work 'evidence\measurement.json'),($measurement | ConvertTo-Json),$encoding)
if($bytes -gt 500MB){throw 'Published Host exceeds local staging budget'}
if ($SizeProbe) {
    [pscustomobject]@{Status='SizeProbeOnly';BuildId=$id;FinalSourceBinding=$false;PublishDirectory=$output;EvidenceDirectory=(Join-Path $work 'evidence');ExtractedBytes=$bytes;ZipBytes=([IO.FileInfo]$measurementZip).Length;DesktopAcceptance='NotRun';RuntimeStaged=$false;PointerWritten=$false} | ConvertTo-Json
    return
}
# Private non-cloud execution root. Never execute binaries inside downloaded package directories.
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$local=if($version -ceq '0.17.0'){Join-Path $work 'execution-staging'}else{Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'SafeJunkCleaner'}
if(!(Test-Path -LiteralPath $local)){[void][IO.Directory]::CreateDirectory($local)}
for($p=$local;$p;$p=[IO.Path]::GetDirectoryName($p)){if(([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Unsafe local staging ancestor'}}
$staging=Join-Path $local ('explorer-publish-'+$id)
if(Test-Path -LiteralPath $staging){$staging=Join-Path $local ('explorer-publish-'+$id+'-'+[guid]::NewGuid().ToString('N'))}
$acl=New-Object Security.AccessControl.DirectorySecurity;$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
[void][IO.Directory]::CreateDirectory($staging,$acl)
$components=@()
foreach($f in $published){
 $relative=$f.FullName.Substring($output.Length+1);$dest=Join-Path $staging $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
 $expected=(Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash;[IO.File]::Copy($f.FullName,$dest,$false)
 for($p=$dest;$p;$p=[IO.Path]::GetDirectoryName($p)){if(([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked staged component'}}
 if((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne $expected){throw 'Staged publish mismatch'}
 $components+=@{Path=$relative.Replace('\','/');Bytes=$f.Length;Sha256=$expected}
}
$manifest=@{SchemaVersion=1;ContractVersion=$contract;BuildId=$id;RuntimeRoot='.';SelfContained=$true;RuntimeIdentifier='win-x64';RuntimeVersion=$runtimeVersion;DevelopmentOnly=$true;SealedRelease=$false;ModelIncluded=$false;SourceProvenance=$sourceProvenance;Components=$components;Launch=@{Executable='sjc-explorer.exe';Arguments=@();WorkingDirectory='.'}}
if ($noModel) { $manifest.ModelMode='Absent';$manifest.AlgorithmMode='Heuristic';$manifest.ModelAssemblyIncluded=$false } else { $manifest.ModelAssemblyIncluded=$true;$manifest.ModelComponentExpectedSibling='../model' }
$manifestPath=Join-Path $staging 'host-component-manifest.json';[IO.File]::WriteAllText($manifestPath,($manifest|ConvertTo-Json -Depth 26),$encoding);$manifestSha256=Get-LpHash $manifestPath
[IO.File]::Copy($manifestPath,(Join-Path $output 'host-component-manifest.json'),[bool]$ResumeBuildId)
# Start apphost directly, with dotnet discovery disabled and a deliberately absent DOTNET_ROOT.
$testParent=Join-Path $local ('explorer-publish-test-'+$id);[void][IO.Directory]::CreateDirectory($testParent)
[IO.File]::WriteAllText((Join-Path $testParent '.sandbox-owner'),($sid.Value+'|'+$testParent),$encoding)
$start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=Join-Path $staging 'sjc-explorer.exe';$start.WorkingDirectory=$staging
$start.Arguments='--state-root "'+(Join-Path $testParent 'state')+'"';$start.UseShellExecute=$false;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true;$start.StandardOutputEncoding=New-Object Text.UTF8Encoding($false)
$start.EnvironmentVariables['DOTNET_ROOT']=Join-Path $testParent 'no-dotnet';$start.EnvironmentVariables['DOTNET_ROOT_X64']=$start.EnvironmentVariables['DOTNET_ROOT'];$start.EnvironmentVariables['DOTNET_MULTILEVEL_LOOKUP']='0';$start.EnvironmentVariables['PATH']=$env:SystemRoot+'\System32';$start.EnvironmentVariables['COREHOST_TRACE']='1';$start.EnvironmentVariables['COREHOST_TRACEFILE']=Join-Path $testParent 'apphost-trace.txt'
$process=New-Object Diagnostics.Process;$process.StartInfo=$start
try{
 for($p=$staging;$p;$p=[IO.Path]::GetDirectoryName($p)){if(([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Linked execution root'}}
 Assert-LpExactFiles $staging $components @('host-component-manifest.json')
 Assert-LpExactFiles $output $components @('host-component-manifest.json')
 foreach ($component in $components) { if ((Get-LpHash (Join-Path $staging $component.Path)) -ne $component.Sha256) { throw 'Staged executable input changed after manifest binding.' } }
 [void]$process.Start();$stderr=$process.StandardError.ReadToEndAsync()
 $request=@{ProtocolVersion=1;RequestId=[guid]::NewGuid().ToString('D');TaskId=$null;Operation='Health';Payload=@{}}|ConvertTo-Json -Compress
 $data=[Text.Encoding]::UTF8.GetBytes($request+"`n");$process.StandardInput.BaseStream.Write($data,0,$data.Length);$process.StandardInput.BaseStream.Flush()
 $read=$process.StandardOutput.ReadLineAsync();if(!$read.Wait(15000) -or !$read.Result){throw 'Self-contained Health timeout/exited'}
 $health=$read.Result|ConvertFrom-Json
 if(!$health.Ok -or $health.Result.ContractVersion -ne $contract -or $health.Result.Capabilities.ModelEnabledByDefault -or $health.Result.Capabilities.RecycleEnabled){throw 'Unexpected packaged capabilities'}
 if ($noModel) {
  $caps=$health.Result.Capabilities
  if ($health.Result.AlgorithmMode -cne 'Heuristic' -or $health.Result.ModelMode -cne 'Absent' -or $caps.HeuristicExploration -isnot [bool] -or -not $caps.HeuristicExploration) { throw 'Host does not declare Absent/Heuristic exploration.' }
  foreach ($property in @('ModelIncluded','ModelReady','ModelAvailable')) { if ($caps.$property -isnot [bool] -or $caps.$property) { throw 'No-model packaged capability must be false.' } }
 }
 $loaded=@($process.Modules|ForEach-Object {$_.FileName});$required=@('hostfxr.dll','hostpolicy.dll','coreclr.dll')
 foreach($name in $required){if(!($loaded|Where-Object {[IO.Path]::GetFileName($_) -eq $name -and $_.StartsWith($staging+'\',[StringComparison]::OrdinalIgnoreCase)})){throw ('Runtime module not from local package: '+$name)}}
 if($loaded|Where-Object {$_.StartsWith((Join-Path $env:ProgramFiles 'dotnet')+'\',[StringComparison]::OrdinalIgnoreCase) -or $_.StartsWith($env:DOTNET_ROOT+'\',[StringComparison]::OrdinalIgnoreCase)}){throw 'Package loaded global/SDK runtime'}
 if ($noModel -and @($loaded | Where-Object { [IO.Path]::GetFileName($_) -match '(?i)Explorer\.Model|llama|gguf|ggml' }).Count) { throw 'Host loaded a forbidden model native/managed module.' }
 $process.StandardInput.Close();if(!$process.WaitForExit(15000) -or $process.ExitCode -ne 0){throw 'Self-contained shutdown failed'}
 $currentSources=if ($noModel) { @(Get-LpHostSources $Repository) } else { @(Get-LpWorkingSources $Repository) }
 if ((Get-LpSourceSetHash $currentSources) -ne $sourceSetHash) { throw 'Host component source set changed during publish.' }
 Assert-LpExactFiles $staging $components @('host-component-manifest.json');Assert-LpExactFiles $output $components @('host-component-manifest.json')
 if ((Get-LpHash $manifestPath) -ne $manifestSha256 -or (Get-LpHash (Join-Path $output 'host-component-manifest.json')) -ne $manifestSha256) { throw 'Host manifest changed during self-check.' }
 [IO.File]::WriteAllText((Join-Path $work 'evidence\health.jsonl'),$request+"`n"+$read.Result+"`n",$encoding);[IO.File]::WriteAllText((Join-Path $work 'evidence\stderr.log'),$stderr.Result,$encoding)
 $result=@{Passed=$true;Scope='HostSelfContainedHealthSelfCheck';DesktopAcceptance='NotRun';ModelMode=if($noModel){'Absent'}else{'Historical'};AlgorithmMode=if($noModel){'Heuristic'}else{'Historical'};SourceSetSha256=$sourceSetHash;PublishDirectory=$output;StagingDirectory=$staging;PublishedFiles=$published.Count;PublishedBytes=$bytes;DownloadedBytes=$downloaded;RuntimeVersion=$runtimeVersion;ManifestSha256=$manifestSha256;ModelReady=$false;RecycleEnabled=$false;LoadedModules=$loaded;GlobalDotnetSearchDisabled=$true}
 [IO.File]::WriteAllText((Join-Path $work 'evidence\result.json'),($result|ConvertTo-Json -Depth 6),$encoding)
 Write-Output ('SELF-CONTAINED PUBLISH PASS; bytes='+$bytes+' downloaded='+$downloaded+' output='+$output+' staging='+$staging+' evidence='+(Join-Path $work 'evidence'))
}finally{if(!$process.HasExited){$process.StandardInput.Close();if(!$process.WaitForExit(10000)){$process.Kill()}};$process.Dispose()}
