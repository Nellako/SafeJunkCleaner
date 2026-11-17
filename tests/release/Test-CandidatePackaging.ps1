#requires -Version 5.1
# Owned GUID fixtures only. Never launches any component, promotes or packages a real build.
[CmdletBinding()]
param([string]$Repository,[string]$FixtureParent)
if (-not $Repository) { $Repository=Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/local-promotion-common.ps1')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (-not $FixtureParent) { $FixtureParent=[IO.Path]::GetTempPath() }
$FixtureParent=Get-LpPath $FixtureParent -Directory
$root=Join-Path $FixtureParent ('sjc-release-fixtures-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
[IO.File]::WriteAllText((Join-Path $root '.test-fixture-owner'),$root,[Text.UTF8Encoding]::new($true))
$script:assertions=0
function Check([bool]$Value,[string]$Name) { if (-not $Value) { throw "Assertion failed: $Name" };$script:assertions++ }
function Reject([scriptblock]$Action,[string]$Label,[string]$ExpectedMessage) { $rejected=$false;$message='';try { &$Action | Out-Null } catch { $rejected=$true;$message=$_.Exception.Message };Check $rejected $Label;if ($ExpectedMessage) { Check ($message -match $ExpectedMessage) ($Label+' precise reason') } }
function Put([string]$Path,[string]$Text) { $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($true)) }
function Record([string]$Base,[string]$Name) { $p=Join-Path $Base $Name;return [pscustomobject]@{Path=$Name;SHA256=(Get-LpHash $p);Bytes=([IO.FileInfo]$p).Length} }
try {
    foreach ($bad in @('../escape','C:/absolute','a//b','a/./b','a/../b','a/b.','a/CON.txt','a\b','/root')) { Reject { Get-LpCandidateName $bad } ('canonical '+$bad) }
    Check ((Get-LpCandidateName 'model/runtime/llama.dll') -ceq 'model/runtime/llama.dll') 'canonical valid'
    Check (@(Get-LpProductSources '0.12.0').Count -eq 9) 'old eight PS plus version preserved'
    Check (@(Get-LpProductSources '0.13.0').Count -eq 10) 'new nine PS plus version'
    Check (@(Get-LpProductSources '0.14.0').Count -eq 10) '0.14 includes ExplorerGui not legacy omission'
    Check (@(Get-LpProductSources '0.15.0').Count -eq 10) '0.15 retains all nine PS modules and version'
    Check (Test-LpNoModelVersion '0.15.0') '0.15 explicitly no-model'
    Check (Test-LpNoModelVersion '0.16.0') '0.16 explicitly supports no-model completion'
    Check (Test-LpNoModelVersion '0.16.1') '0.16.1 retains no-model capabilities'
    Check (@(Get-LpProductSources '0.16.1').Count -eq 10) '0.16.1 retains complete module payload'
    Check (@(Get-LpProductSources '0.16.0').Count -eq 10) '0.16 retains complete GUI modules'
    Check (-not (Test-LpNoModelVersion '0.17.0')) 'unknown future version not implicitly supported'
    Check ((@(Get-LpVerificationIds '0.15.0') -join ',') -ceq 'ReleaseRegression,ExplorerHost,HeuristicExploration') '0.15 retains mandatory heuristic verification'
    Check (@(Get-LpDesktopChecks '0.15.0') -ccontains 'HeuristicAnalysisObserved') '0.15 retains actual desktop gate'
    Check ((@(Get-LpVerificationIds '0.13.0') -join ',') -ceq 'ReleaseRegression,ExplorerHost,Model') 'historical model verification preserved'
    Check ((@(Get-LpVerificationIds '0.14.0') -join ',') -ceq 'ReleaseRegression,ExplorerHost,HeuristicExploration') '0.14 heuristic verification mandatory'
    Check (@(Get-LpDesktopChecks '0.13.0') -ccontains 'ModelOfflineObserved') 'historical model desktop check preserved'
    Check (@(Get-LpDesktopChecks '0.14.0') -cnotcontains 'ModelOfflineObserved') '0.14 does not pretend to observe offline model'
    foreach ($name in @('NoModelPayloadObserved','HeuristicAnalysisObserved')) { Check (@(Get-LpDesktopChecks '0.14.0') -ccontains $name) ('0.14 capability evidence '+$name) }
    foreach ($payloadName in @('model/cache.json','model/runtime/llama.dll','explorer/Explorer.Model.dll','explorer/SafeJunkCleaner.Explorer.Model.dll','explorer/llama.dll','explorer/ggml-base.dll','explorer/weight.gguf','explorer/MODEL.dll','explorer/licenses/llama/LICENSE')) { Reject { Assert-LpNoModelPayload @([pscustomobject]@{Path=$payloadName}) } ('no model payload '+$payloadName) }
    foreach ($name in @('explorer/System.ObjectModel.dll','explorer/System.ComponentModel.dll','explorer/coreclr.dll','explorer/hostfxr.dll','explorer/SQLitePCLRaw.core.dll')) { Assert-LpNoModelPayload @([pscustomobject]@{Path=$name});Check $true ('legitimate runtime allowed '+$name) }
    foreach ($name in @('engine/Explorer.Model/Test.cs','engine-tests/Explorer.Model.Tests/Test.cs','engine-tests/Explorer.Bootstrap.Tests/Explorer.Bootstrap.Tests.csproj','tests/laya-evaluation/test.ps1','tests/model-exploration/test.ps1','tools/laya/tool.ps1','tools/models/tool.ps1')) { Check (Test-LpHistoricalModelSource $name) ('historical experiment excluded '+$name) }
    Check (-not (Test-LpHistoricalModelSource 'engine/Explorer.Analysis/HeuristicAnalyzer.cs')) 'heuristic product source retained'
    $verification=@(Get-LpVerificationIds '0.14.0' | ForEach-Object { [pscustomobject]@{Id=$_;Status='Passed';Assertions=1;Failed=0;Blocked=0} })
    Assert-LpVerificationResults $verification '0.14.0';Check $true 'synthetic result shape accepts heuristic evidence'
    Reject { Assert-LpVerificationResults @($verification | Where-Object Id -NE 'HeuristicExploration') '0.14.0' } 'heuristic evidence cannot be omitted'
    Reject { Assert-LpVerificationResults @($verification+[pscustomobject]@{Id='Model';Status='Passed';Assertions=1;Failed=0;Blocked=0}) '0.14.0' } 'historical model evidence cannot authorize 0.14'
    $syntheticChecks=@(Get-LpDesktopChecks '0.14.0' | ForEach-Object { [pscustomobject]@{Name=$_;Passed=$true} })
    Assert-LpDesktopChecks $syntheticChecks '0.14.0';Check $true 'synthetic desktop schema shape only'
    foreach ($checkName in @('NoModelPayloadObserved','HeuristicAnalysisObserved','DesktopWindowObserved')) { Reject { Assert-LpDesktopChecks @($syntheticChecks | Where-Object Name -CNE $checkName) '0.14.0' } ('cannot omit actual evidence '+$checkName) }
    Reject { Assert-LpDesktopChecks @($syntheticChecks+[pscustomobject]@{Name='ModelOfflineObserved';Passed=$true}) '0.14.0' } 'desktop cannot pretend model observed'
    $tree=Join-Path $root 'source';$null=New-Item -ItemType Directory -Path $tree
    Put (Join-Path $tree 'src/Main.ps1') '# test fixture only'
    Put (Join-Path $tree 'engine/Test/Test.cs') 'class Fixture {}'
    Put (Join-Path $tree 'tests/untracked.ps1') '# untracked included'
    Put (Join-Path $tree 'tools/tool.ps1') '# tooling included'
    Put (Join-Path $tree 'docs/diagnostic.md') 'private report fingerprinted'
    Put (Join-Path $tree 'artifacts/private.log') 'must not be traversed'
    Put (Join-Path $tree 'engine/Test/bin/private.dll') 'must not be traversed'
    Put (Join-Path $tree '.zcode/private.json') '{}'
    $records=@(Get-LpWorkingSources $tree)
    Check ($records.Count -eq 5) 'exact relevant source set includes untracked and diagnostic docs'
    $before=Get-LpSourceSetHash $records
    Put (Join-Path $tree 'tests/untracked.ps1') '# changed untracked'
    Check ((Get-LpSourceSetHash @(Get-LpWorkingSources $tree)) -ne $before) 'untracked content invalidates source identity'
    $records=@(Get-LpWorkingSources $tree)
    $reverse=@($records);[array]::Reverse($reverse)
    Check ((Get-LpSourceSetHash $records) -eq (Get-LpSourceSetHash $reverse)) 'source ordering canonical'
    $unicode=@('src/中.ps1','src/ä.ps1','src/Z.ps1','src/a.ps1')
    $ordinal=@($unicode);[array]::Sort($ordinal,[StringComparer]::Ordinal)
    $unicodeRecords=@($unicode | ForEach-Object { [pscustomobject]@{Path=$_;SHA256=('A'*64);Bytes=1} })
    $lines=(@($ordinal | ForEach-Object { $_+"`t"+('A'*64)+"`t1`n" }) -join '')
    $sha=[Security.Cryptography.SHA256]::Create();try { $expectedHash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines)))).Replace('-','') } finally { $sha.Dispose() }
    Check ((Get-LpSourceSetHash $unicodeRecords) -ceq $expectedHash) 'Unicode paths follow ordinal not culture order'
    Reject { Get-LpSourceSetHash @($records+$records[0]) } 'duplicate source records rejected'
    $payload=Join-Path $root 'payload';$null=New-Item -ItemType Directory -Path $payload
    Put (Join-Path $payload 'nested/fixture.txt') 'synthetic package, not product or model'
    Put (Join-Path $payload 'LICENSE') 'fixture license only'
    $expected=@((Record $payload 'nested/fixture.txt'),(Record $payload 'LICENSE'))
    Assert-LpExactFiles $payload $expected
    $zip=Join-Path $root 'synthetic-only.zip'
    New-LpCandidateZip $zip $payload $expected
    Check ([IO.File]::Exists($zip)) 'streamed synthetic package validated'
    Reject { New-LpCandidateZip $zip $payload $expected } 'ZIP never overwritten'
    $wrong=@([pscustomobject]@{Path='nested/fixture.txt';SHA256=('0'*64);Bytes=$expected[0].Bytes},$expected[1])
    Reject { Test-LpCandidateZip $zip $wrong } 'entry hash mismatch'
    Reject { Test-LpCandidateZip $zip @($expected[0]) } 'unexpected ZIP file'
    Reject { Test-LpCandidateZip $zip @($expected+$expected[0]) } 'duplicate expected set'
    foreach ($variant in @('traversal','duplicate','backslash','casecollision')) {
        $p=Join-Path $root ($variant+'.zip');$z=[IO.Compression.ZipFile]::Open($p,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $names=switch ($variant) { 'traversal' {@('../escape')} 'duplicate' {@('LICENSE','LICENSE')} 'backslash' {@('nested\fixture.txt')} 'casecollision' {@('LICENSE','license')} }
            foreach ($n in $names) { $e=$z.CreateEntry($n);$s=$e.Open();try { $bytes=[Text.Encoding]::UTF8.GetBytes('x');$s.Write($bytes,0,$bytes.Length) } finally { $s.Dispose() } }
        } finally { $z.Dispose() }
        Reject { Test-LpCandidateZip $p $expected } ('reject '+$variant)
    }
    Put (Join-Path $payload 'unexpected.exe') 'never executed'
    Reject { Assert-LpExactFiles $payload $expected } 'undeclared component EXE rejected'
    $fake=[pscustomobject]@{Version='0.13.0';ComponentSchema='SafeJunkCleaner.Components.v1';Files=@([pscustomobject]@{Name='arbitrary.exe';SHA256=('0'*64);Bytes=1},[pscustomobject]@{Name='SafeJunkCleaner_v0.13.0.ps1';SHA256=('0'*64);Bytes=1})}
    Reject { Get-LpComponentFacts $payload $fake $tree } 'arbitrary top-level EXE rejected'
    Put (Join-Path $root 'private-guide.md') 'C:\Users\Owner\AppData\Local\private'
    Reject { Assert-LpPublicDocument (Join-Path $root 'private-guide.md') } 'guide machine identity rejected'
    Put (Join-Path $root 'public-guide.md') 'Example C:\Windows\Temp and C:\Program Files are product documentation, not private logs.'
    Assert-LpPublicDocument (Join-Path $root 'public-guide.md');Check $true 'product path constants allowed'
    $legacy=[pscustomobject]@{Version='0.12.0';ComponentSchema='SafeJunkCleaner.Components.v1'}
    Reject { Get-LpComponentFacts $payload $legacy $tree } 'new schema cannot reinterpret legacy release'
    Reject { Assert-LpCandidateEvidence $tree $payload $fake ('0'*64) (Join-Path $root 'absent-final.json') (Join-Path $root 'absent-desktop.json') } 'verified cannot omit evidence'
    $component=Join-Path $root 'synthetic-component';$componentSource=Join-Path $root 'synthetic-component-source'
    $null=[IO.Directory]::CreateDirectory($component);$null=[IO.Directory]::CreateDirectory($componentSource)
    $productNames=@(Get-LpProductSources '0.14.0')+@('scripts/build.ps1','scripts/local-promotion-common.ps1','assets/app.ico','engine/Directory.Build.props')
    foreach ($name in $productNames) { Put (Join-Path $componentSource $name) '# SYNTHETIC UNIT INPUT ONLY' }
    foreach ($projectName in @('Explorer.Core','Explorer.Analysis','Explorer.Execution','Explorer.Application','Explorer.Host')) { $null=[IO.Directory]::CreateDirectory((Join-Path $componentSource ('engine/'+$projectName))) }
    $exePath=Join-Path $component '星梦雨垃圾清理器_v0.14.0.exe'
    Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("0.14.0.0")] public static class SyntheticReleaseFixture { public static void Main() {} }' -OutputAssembly $exePath -OutputType ConsoleApplication
    $hostRoot=Join-Path $component 'explorer';$null=[IO.Directory]::CreateDirectory($hostRoot)
    $hostNames=@('sjc-explorer.exe','sjc-explorer.dll','coreclr.dll','hostfxr.dll','hostpolicy.dll','System.Private.CoreLib.dll','Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','e_sqlite3.dll','licenses/SafeJunkCleaner-LICENSE')
    foreach ($package in @('microsoft.netcore.app.runtime.win-x64-10.0.15','microsoft.netcore.app.host.win-x64-10.0.15','microsoft.data.sqlite-10.0.14','microsoft.data.sqlite.core-10.0.14','sqlitepclraw.core-2.1.13','sqlitepclraw.bundle_e_sqlite3-2.1.13','sqlitepclraw.provider.e_sqlite3-2.1.13','sqlitepclraw.lib.e_sqlite3-2.1.13')) { $hostNames += 'licenses/'+$package+'/LICENSE.txt' }
    foreach ($name in $hostNames) { Put (Join-Path $hostRoot $name) 'SYNTHETIC NOT AN ACTUAL RUNTIME; NEVER EXECUTED' }
    Put (Join-Path $hostRoot 'sjc-explorer.deps.json') '{}'
    Put (Join-Path $hostRoot 'sjc-explorer.runtimeconfig.json') '{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"10.0.15"}]}}'
    $hostNames += @('sjc-explorer.deps.json','sjc-explorer.runtimeconfig.json')
    $hostRecords=@($hostNames | ForEach-Object { Record $hostRoot $_ })
    $sourceRecords=@($productNames | ForEach-Object { Record $componentSource $_ })
    $fixtureLocks=@()
    foreach ($projectName in @('Explorer.Core','Explorer.Analysis','Explorer.Execution','Explorer.Application','Explorer.Host')) {
        $lockName='engine/'+$projectName+'/packages.lock.json';Put (Join-Path $componentSource $lockName) '{"version":1,"dependencies":{"net10.0-windows7.0":{}}}'
        $sourceRecords += (Record $componentSource $lockName)
        $fixtureLocks += @{Project=$projectName;Sha256=('C'*64);Content=@{dependencies=@{'net10.0-windows7.0'=@{}}}}
    }
    $runtimePacks=@(Get-LpApprovedRuntimePacks | ForEach-Object { $_ | Add-Member NoteProperty License 'MIT' -PassThru | Add-Member NoteProperty Repository 'https://github.com/dotnet/dotnet' -PassThru })
    $componentSourceHash=Get-LpSourceSetHash @(Get-LpHostSources $componentSource)
    $hostManifest=[pscustomobject]@{SchemaVersion=1;ContractVersion=3;ModelMode='Absent';AlgorithmMode='Heuristic';ModelIncluded=$false;ModelAssemblyIncluded=$false;SelfContained=$true;RuntimeVersion='10.0.15';RuntimeIdentifier='win-x64';RuntimeRoot='.';Launch=@{Executable='sjc-explorer.exe';Arguments=@();WorkingDirectory='.'};SourceProvenance=@{ContractVersion=3;GitCommit=('f'*40);SourceSetSha256=$componentSourceHash;ComponentSourceSetSha256=$componentSourceHash;SourceScope='ExplorerHostComponent';Sources=@($sourceRecords | Where-Object Path -LIKE 'engine/*');RuntimePacks=$runtimePacks;LockedRestore=$fixtureLocks};Components=$hostRecords}
    $buildFixture=[pscustomobject]@{Version='0.14.0';ModelMode='Absent';AlgorithmMode='Heuristic';ComponentSchema='SafeJunkCleaner.Components.v1';ComponentsComplete=$true;BuildStage='ComponentsBuilt';BuildTool=@{Name='ps2exe';Version='1.0.18'};Sources=$sourceRecords;SourceTree=@{SourceSetSha256=('A'*64)};Files=@();Components=@()}
    function Seal-Fixture {
        Put (Join-Path $hostRoot 'host-component-manifest.json') ($hostManifest | ConvertTo-Json -Depth 20)
        $hash=Get-LpHash (Join-Path $hostRoot 'host-component-manifest.json')
        $text='$script:SjcEmbeddedVersion = '+"[pscustomobject]@{version='0.14.0';fileVersion='0.14.0.0';planSchemaVersion=1}`r`n"+'$script:SjcEmbeddedExplorerManifestSha256 = '+"'$hash'"
        Put (Join-Path $component 'SafeJunkCleaner_v0.14.0.ps1') $text
        $buildFixture.Files=@([pscustomobject]@{Name='星梦雨垃圾清理器_v0.14.0.exe';SHA256=(Get-LpHash $exePath);Bytes=([IO.FileInfo]$exePath).Length;FileVersion='0.14.0.0'},[pscustomobject]@{Name='SafeJunkCleaner_v0.14.0.ps1';SHA256=(Get-LpHash (Join-Path $component 'SafeJunkCleaner_v0.14.0.ps1'));Bytes=([IO.FileInfo](Join-Path $component 'SafeJunkCleaner_v0.14.0.ps1')).Length})
        $buildFixture.Components=@([pscustomobject]@{Name='ExplorerHost';Root='explorer';ManifestPath='explorer/host-component-manifest.json';ManifestSHA256=$hash})
    }
    $savedGit=${function:Invoke-LpGit}
    function Invoke-LpGit { param([string]$Repository,[string[]]$Arguments) if ($Repository -cne $componentSource -or ($Arguments -join ' ') -cne 'rev-parse --verify HEAD') { throw 'Fixture only permits synthetic provenance read.' };return ('f'*40) }
    try {
        Seal-Fixture
        $facts=@(Get-LpComponentFacts $component $buildFixture $componentSource)
        Check ($facts.Count -eq ($hostRecords.Count+3)) 'complete Absent/Heuristic single component validation'
        $buildFixture.ModelMode='Optional';Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'mode must explicitly be Absent';$buildFixture.ModelMode='Absent'
        $buildFixture.AlgorithmMode='Model';Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'algorithm must explicitly be Heuristic';$buildFixture.AlgorithmMode='Heuristic'
        $buildFixture.Components += $buildFixture.Components[0];Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'exactly one component not merely no model gate';Seal-Fixture
        foreach ($field in @('ContractVersion','ModelMode','AlgorithmMode','SelfContained')) {
            $old=$hostManifest.$field;$hostManifest.$field=switch ($field) { ContractVersion {2} ModelMode {'Optional'} AlgorithmMode {'Model'} SelfContained {$false} };Seal-Fixture
            Reject { Get-LpComponentFacts $component $buildFixture $componentSource } ('host manifest '+$field);$hostManifest.$field=$old
        }
        $hostManifest.SourceProvenance.SourceSetSha256='B'*64;Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'host component sourceSet binding';$hostManifest.SourceProvenance.SourceSetSha256=$componentSourceHash
        Put (Join-Path $componentSource 'docs/changed-after-host.md') 'GUI/docs need not force recompilation of unchanged Host sources.'
        $null=Assert-LpHostSourceProvenance $hostManifest.SourceProvenance $componentSource;Check $true 'Host component source binding independent of docs changes'
        $hostManifest.SourceProvenance.RuntimePacks=@($runtimePacks[0]);Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'both runtime packs mandatory';$hostManifest.SourceProvenance.RuntimePacks=$runtimePacks
        $runtimePacks[0].Version='10.0.14';Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'old vulnerable runtime pack cannot be reused' 'Fixed official runtime';$runtimePacks[0].Version='10.0.15'
        $oldDigest=$runtimePacks[0].Sha512;$runtimePacks[0].Sha512='D'*128;Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'cache-provided hash is not an approval root' 'Fixed official runtime';$runtimePacks[0].Sha512=$oldDigest
        $oldCommit=$runtimePacks[0].Commit;$runtimePacks[0].Commit='0'*40;Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'runtime source commit must match official repaired bytes' 'Fixed official runtime';$runtimePacks[0].Commit=$oldCommit
        $hostManifest.RuntimeVersion='10.0.14';Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'Host version cannot claim vulnerable runtime' 'Fixed repaired';$hostManifest.RuntimeVersion='10.0.15'
        $hostManifest.SourceProvenance.LockedRestore=@($fixtureLocks[0]);Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'all five project locks mandatory';$hostManifest.SourceProvenance.LockedRestore=$fixtureLocks
        $pin=@(Get-LpApprovedRuntimePacks | Where-Object Id -CEQ 'Microsoft.NETCore.App.Runtime.win-x64')[0]
        $pinBytes=New-Object byte[] 64;for ($i=0;$i -lt 64;$i++) { $pinBytes[$i]=[Convert]::ToByte($pin.Sha512.Substring($i*2,2),16) }
        $runtimeLock=@{type='Direct';resolved='10.0.15';contentHash=[Convert]::ToBase64String($pinBytes)}
        $fixtureLocks[0].Content.dependencies['net10.0-windows7.0']['Microsoft.NETCore.App.Runtime.win-x64']=$runtimeLock
        Seal-Fixture;$null=Get-LpComponentFacts $component $buildFixture $componentSource;Check $true 'runtime lock must resolve the pinned official package bytes'
        $runtimeLock.contentHash='forged-cache-hash';Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'runtime lock content hash cannot be replaced' 'runtime lock version/content hash'
        $runtimeLock.contentHash=[Convert]::ToBase64String($pinBytes);$runtimeLock.resolved='10.0.14';Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'runtime lock cannot select vulnerable old version' 'runtime lock version/content hash'
        $fixtureLocks[0].Content.dependencies['net10.0-windows7.0'].Remove('Microsoft.NETCore.App.Runtime.win-x64')
        $fixtureLocks[0].Content.dependencies['net10.0-windows7.0']['Unapproved.Package']=@{type='Transitive';resolved='1.0.0';contentHash='synthetic'}
        Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'unapproved package cannot enter lock provenance' 'Published dependency differs'
        $fixtureLocks[0].Content.dependencies['net10.0-windows7.0'].Remove('Unapproved.Package')
        $hostManifest.ModelAssemblyIncluded=$true;Seal-Fixture;Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'model assembly declaration rejected';$hostManifest.ModelAssemblyIncluded=$false
        Seal-Fixture
        Put (Join-Path $hostRoot 'Explorer.Model.dll') 'synthetic forbidden old cache residue'
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'undeclared old model DLL rejected'
        $hostManifest.Components += (Record $hostRoot 'Explorer.Model.dll');Seal-Fixture
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'declared old model DLL also rejected'
        $hostManifest.Components=$hostRecords
        $oldModel=Join-Path $hostRoot 'Explorer.Model.dll';$retainedModel=Join-Path $root 'retained-artificial-model.dll'
        Put (Join-Path $root 'model-move-manifest.json') (@{Source=$oldModel;Destination=$retainedModel;SHA256=(Get-LpHash $oldModel)}|ConvertTo-Json)
        if([IO.File]::Exists($retainedModel)){throw 'Retained fixture already exists'}
        [IO.File]::Move($oldModel,$retainedModel);Seal-Fixture
        Put (Join-Path $hostRoot 'sjc-explorer.deps.json') '{"libraries":{"Explorer.Model/1.0":{}}}'
        $hostManifest.Components=@($hostNames | ForEach-Object { Record $hostRoot $_ });Seal-Fixture
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'model dependency graph rejected'
        Put (Join-Path $hostRoot 'sjc-explorer.deps.json') '{}'
        Put (Join-Path $hostRoot 'sjc-explorer.runtimeconfig.json') '{"runtimeOptions":{"framework":{"name":"Microsoft.NETCore.App","version":"10.0.14"}}}'
        $hostManifest.Components=@($hostNames | ForEach-Object { Record $hostRoot $_ });Seal-Fixture
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'framework dependent Host rejected'
        Put (Join-Path $hostRoot 'sjc-explorer.runtimeconfig.json') '{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"10.0.15"}]}}'
        $hostManifest.Components=$hostRecords;Seal-Fixture
        $null=Get-LpComponentFacts $component $buildFixture $componentSource
        $hostManifest.Components=@($hostRecords | Where-Object Path -NE 'e_sqlite3.dll');Seal-Fixture
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'SQLite payload required' 'Incomplete 0.14 runtime/SQLite'
        $hostManifest.Components=@($hostRecords | Where-Object { $_.Path -notlike 'licenses/sqlitepclraw.core-*/LICENSE.txt' });Seal-Fixture
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } 'SQLite redistribution license required' 'Missing runtime/SQLite license provenance'
        $hostManifest.Components=$hostRecords;$buildFixture.Version='0.13.0'
        Reject { Get-LpComponentFacts $component $buildFixture $componentSource } '0.13 cannot adopt 0.14 single payload'
    } finally { ${function:Invoke-LpGit}=$savedGit }
    Assert-LpPackageBudget '0.14.0' $zip $expected;Check $true 'small no-model payload budget'
    Reject { Assert-LpPackageBudget '0.14.0' $zip @([pscustomobject]@{Path='too-big.txt';Bytes=(100MB+1)}) } 'unpacked target enforced'
    $oversized=Join-Path $root 'oversized-synthetic.zip';$stream=[IO.File]::Open($oversized,[IO.FileMode]::CreateNew);try { $stream.SetLength(50MB+1) } finally {$stream.Dispose()}
    Reject { Assert-LpPackageBudget '0.14.0' $oversized $expected } 'ZIP target enforced'
    foreach ($relative in @('scripts/build.ps1','scripts/package-candidate.ps1','scripts/local-promotion-common.ps1','scripts/package-local.ps1','scripts/publish.ps1','tools/explorer/Publish-Explorer.ps1','tools/explorer/Write-HostManifest.ps1','tools/explorer/Get-ExplorerSdk.ps1','tools/explorer/Build-Explorer.ps1','tests/release/Test-CandidatePackaging.ps1')) {
        $bytes=[IO.File]::ReadAllBytes((Join-Path $Repository $relative))
        Check ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) ('UTF8 BOM '+$relative)
        $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository $relative),[ref]$tokens,[ref]$errors)
        Check (@($errors).Count -eq 0) ('PS5 parse '+$relative)
    }
    $result=[ordered]@{Schema='SafeJunkCleaner.ReleaseToolSelfTest.v1';Status='Passed';Assertions=$script:assertions;FixtureDirectory=$root;SyntheticOnly=$true;Limitations=@('Synthetic ZIP/shared validation only; no fixed model weight or native runtime fabricated.','Not a verified product, StageOnly acceptance, formal package or promotion.')}
    Put (Join-Path $root 'result.json') ($result | ConvertTo-Json -Depth 5)
    $result | ConvertTo-Json -Depth 5
} catch { [pscustomobject]@{Status='Failed';Assertions=$script:assertions;FixtureDirectory=$root;Message=$_.Exception.Message;Stack=$_.ScriptStackTrace} | ConvertTo-Json;exit 1 }
