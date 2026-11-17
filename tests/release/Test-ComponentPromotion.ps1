#requires -Version 5.1
<# Complete CURRENT component capture -> seal -> preflight -> fast-forward and
   publish/package adapters, on newly owned GUID artificial repositories ONLY.
   Fake runtime bytes/desktop reports test the gates, NOT product acceptance.
   No fixture, object store, failed output or evidence is automatically deleted. #>
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$FixtureParent)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/local-promotion-common.ps1')
Assert-LpEnvironment
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$FixtureParent=Get-LpPath $FixtureParent -Directory
$root=Join-Path $FixtureParent ('c-'+[guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $root) { throw 'Fixture root must be new.' }
[void][IO.Directory]::CreateDirectory($root)
$owner=Join-Path $root '.test-fixture-owner'
[IO.File]::WriteAllText($owner,$root,[Text.UTF8Encoding]::new($true))
$source=Join-Path $root 'develop';$target=Join-Path $root 'main';$evidence=Join-Path $root 'evidence';$buildRoot=Join-Path $root 'build';$packages=Join-Path $root 'packages'
foreach ($p in @($source,$target,$evidence,$buildRoot,$packages)) { [void][IO.Directory]::CreateDirectory($p) }
$script:checks=0;$script:rejects=0
function Owned([string]$Path) {
    $full=[IO.Path]::GetFullPath($Path)
    if ([IO.File]::ReadAllText($owner) -cne $root -or -not $full.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Not an owned fixture path.' }
    return (Get-LpPath $full)
}
function Put([string]$Path,[string]$Text) { $Path=Owned $Path;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path));[IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($true)) }
function Json([string]$Path,$Value) { Put $Path ($Value | ConvertTo-Json -Depth 35) }
function Check([bool]$Value,[string]$Label) { if (-not $Value) { throw "Assertion failed: $Label" };$script:checks++;Write-Output ('PASS '+$Label) }
function Reject([scriptblock]$Action,[string]$Label,[string]$Reason) {
    $message='';try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
    $script:rejects++;Json (Join-Path $evidence ('rejection-'+$script:rejects+'.json')) @{Label=$Label;Message=$message;Expected=$Reason;SyntheticOnly=$true}
    Check ($message -and $message -match $Reason) $Label
}
function Commit([string]$Path,[string]$Message) {
    $Path=Owned $Path;if ($Path -notin @($source,$target)) { throw 'Only the two newly initialized artificial repositories may commit.' }
    $null=Invoke-LpGit $Path @('add','--all')
    $null=Invoke-LpGit $Path @('-c','user.name=Owned component gate fixture','-c','user.email=fixture@example.invalid','-c',('core.hooksPath='+$evidence),'commit','--quiet','-m',$Message)
    return ((Invoke-LpGit $Path @('rev-parse','HEAD')) -join '')
}
function With-Mutation([string]$Path,[scriptblock]$Change,[scriptblock]$Action) {
    $Path=Owned $Path;$bytes=[IO.File]::ReadAllBytes($Path)
    try { $v=Get-LpJson $Path;& $Change $v;Json $Path $v;& $Action }
    finally { [IO.File]::Copy($Path,(Join-Path $evidence ('retained-mutation-'+[guid]::NewGuid().ToString('N')+'.json')),$false);[IO.File]::WriteAllBytes($Path,$bytes) }
}
try {
    foreach ($entry in @(@($source,'develop'),@($target,'main'))) {
        $null=Invoke-LpGit $entry[0] @('init','--quiet',('--initial-branch='+$entry[1]))
        $null=Invoke-LpGit $entry[0] @('config','core.autocrlf','false')
    }
    Put (Join-Path $source '.gitattributes') '* -text'
    Put (Join-Path $source '.gitignore') 'releases/'
    foreach ($p in @(Get-LpProductSources '0.16.1')+@('scripts/build.ps1','assets/app.ico')) { Put (Join-Path $source $p) '# SYNTHETIC GATE INPUT; NEVER RUN AS PRODUCT' }
    Put (Join-Path $source 'src/Version.ps1') "function Get-SjcVersion { return '0.16.1' }"
    Json (Join-Path $source 'version.json') @{version='0.16.1';fileVersion='0.16.1.0'}
    foreach ($p in @('scripts/local-promotion-common.ps1','scripts/seal-local-promotion.ps1','scripts/promote-local.ps1','scripts/publish.ps1','scripts/package-local.ps1','scripts/package-candidate.ps1','tests/run_all.ps1')) { Put (Join-Path $source $p) ([IO.File]::ReadAllText((Join-Path $Repository $p),[Text.Encoding]::UTF8)) }
    foreach ($p in @(Get-LpDeliveryDocuments '0.16.1')) { Put (Join-Path $source $p) ('Synthetic public document only: '+$p) }
    Put (Join-Path $source 'engine/Directory.Build.props') '<Project />'
    $projects=@('Explorer.Core','Explorer.Analysis','Explorer.Execution','Explorer.Application','Explorer.Host')
    foreach ($p in $projects) {
        Put (Join-Path $source ('engine/'+$p+'/'+$p+'.csproj')) '<Project />'
        Json (Join-Path $source ('engine/'+$p+'/packages.lock.json')) @{version=1;dependencies=@{'net10.0-windows7.0'=@{}}}
    }
    $base=Commit $source 'Synthetic baseline only'
    $null=Invoke-LpGit $target @('fetch','--quiet','--no-tags','--',$source,$base)
    $null=Invoke-LpGit $target @('merge','--ff-only',$base)
    Put (Join-Path $source 'src/Core.ps1') '# Synthetic revision under test'
    $head=Commit $source 'Synthetic component revision only'
    $seal=Join-Path $Repository 'scripts/seal-local-promotion.ps1';$promote=Join-Path $Repository 'scripts/promote-local.ps1'
    $capture=Join-Path $evidence 'build-inputs.json';$finalPath=Join-Path $evidence 'final-result.json';$summaryPath=Join-Path $evidence 'summary.json';$guiPath=Join-Path $evidence 'desktop.json';$buildPath=Join-Path $buildRoot 'build-manifest.json';$envelope=Join-Path $evidence 'promotion.json'
    Reject { & $seal -SourceRepository $source -ExpectedSourceHead $head -OutputPath (Join-Path $evidence 'missing-final-capture.json') -CaptureBuildInputs -Confirm:$false } 'current capture cannot omit final path' 'FinalTestResultPath'
    $null=& $seal -SourceRepository $source -ExpectedSourceHead $head -OutputPath $capture -CaptureBuildInputs -FinalTestResultPath $finalPath -Confirm:$false
    Check ((Get-LpJson $capture).FinalTestResultPath -eq $finalPath -and -not (Test-Path -LiteralPath $finalPath)) 'pre-build capture binds a not-yet-created planned final path'
    $repo=Get-LpRepository $source 'develop';$records=@(Get-LpWorkingSources $source);$setHash=Get-LpSourceSetHash $records
    Json (Join-Path $buildRoot 'source-manifest.json') @{Schema='SafeJunkCleaner.SourceManifest.v1';GitHead=$head;Dirty=$false;SourceSetSha256=$setHash;Sources=$records}
    $hostRoot=Join-Path $buildRoot 'explorer';[void][IO.Directory]::CreateDirectory($hostRoot)
    $hostNames=@('sjc-explorer.exe','sjc-explorer.dll','coreclr.dll','hostfxr.dll','hostpolicy.dll','System.Private.CoreLib.dll','Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','e_sqlite3.dll','licenses/SafeJunkCleaner-LICENSE')
    foreach ($pin in @(Get-LpApprovedRuntimePacks)) { $hostNames += ('licenses/'+$pin.Id.ToLowerInvariant()+'-'+$pin.Version+'/LICENSE.txt') }
    foreach ($p in @('microsoft.data.sqlite-10.0.14','microsoft.data.sqlite.core-10.0.14','sqlitepclraw.core-2.1.13','sqlitepclraw.bundle_e_sqlite3-2.1.13','sqlitepclraw.provider.e_sqlite3-2.1.13','sqlitepclraw.lib.e_sqlite3-2.1.13')) { $hostNames += ('licenses/'+$p+'/LICENSE.txt') }
    foreach ($p in $hostNames) { Put (Join-Path $hostRoot $p) 'FAKE RUNTIME BYTES FOR GATE TESTS ONLY; NEVER EXECUTED' }
    Json (Join-Path $hostRoot 'sjc-explorer.runtimeconfig.json') @{runtimeOptions=@{includedFrameworks=@(@{name='Microsoft.NETCore.App';version='10.0.15'})}}
    Json (Join-Path $hostRoot 'sjc-explorer.deps.json') @{}
    $hostNames += @('sjc-explorer.runtimeconfig.json','sjc-explorer.deps.json')
    $hostSources=@(Get-LpHostSources $source);$hostHash=Get-LpSourceSetHash $hostSources
    $pins=@(Get-LpApprovedRuntimePacks | ForEach-Object { $_ | Add-Member NoteProperty License 'MIT' -PassThru | Add-Member NoteProperty Repository 'https://github.com/dotnet/dotnet' -PassThru })
    $locks=@($projects | ForEach-Object { [pscustomobject]@{Project=$_;Sha256=(Get-LpHash (Join-Path $source ('engine/'+$_+'/packages.lock.json')));Content=(Get-LpJson (Join-Path $source ('engine/'+$_+'/packages.lock.json')))} })
    $components=@($hostNames | ForEach-Object { $p=Join-Path $hostRoot $_;[pscustomobject]@{Path=$_;Sha256=(Get-LpHash $p);Bytes=([IO.FileInfo]$p).Length} })
    $hostManifest=@{SchemaVersion=1;ContractVersion=3;ModelMode='Absent';AlgorithmMode='Heuristic';RuntimeVersion='10.0.15';ModelIncluded=$false;ModelAssemblyIncluded=$false;SelfContained=$true;RuntimeIdentifier='win-x64';RuntimeRoot='.';Launch=@{Executable='sjc-explorer.exe';Arguments=@();WorkingDirectory='.'};SourceProvenance=@{ContractVersion=3;GitCommit=$head;SourceSetSha256=$hostHash;ComponentSourceSetSha256=$hostHash;SourceScope='ExplorerHostComponent';Sources=$hostSources;RuntimePacks=$pins;LockedRestore=$locks};Components=$components}
    Json (Join-Path $hostRoot 'host-component-manifest.json') $hostManifest
    $hostManifestHash=Get-LpHash (Join-Path $hostRoot 'host-component-manifest.json')
    $exe=Join-Path $buildRoot '星梦雨垃圾清理器_v0.16.1.exe'
    Add-Type -TypeDefinition 'using System.Reflection; [assembly: AssemblyFileVersion("0.16.1.0")] public static class CurrentGateFixture { public static void Main() {} }' -OutputAssembly $exe -OutputType ConsoleApplication
    $scriptName='SafeJunkCleaner_v0.16.1.ps1'
    Put (Join-Path $buildRoot $scriptName) ('$script:SjcEmbeddedVersion = ' + "[pscustomobject]@{version='0.16.1';fileVersion='0.16.1.0';planSchemaVersion=1}`r`n" + '$script:SjcEmbeddedExplorerManifestSha256 = ' + "'$hostManifestHash'")
    $now=[datetime]::UtcNow.ToString('o');$buildId='synthetic-'+[guid]::NewGuid().ToString('N')
    $build=@{Version='0.16.1';BuiltUtc=$now;BuildId=$buildId;ModelMode='Absent';AlgorithmMode='Heuristic';ComponentSchema='SafeJunkCleaner.Components.v1';ComponentsComplete=$true;BuildStage='ComponentsBuilt';BuildTool=@{Name='ps2exe';Version='1.0.18'};Sources=$records;Files=@(@{Name=[IO.Path]::GetFileName($exe);SHA256=(Get-LpHash $exe);Bytes=([IO.FileInfo]$exe).Length;FileVersion='0.16.1.0'},@{Name=$scriptName;SHA256=(Get-LpHash (Join-Path $buildRoot $scriptName));Bytes=([IO.FileInfo](Join-Path $buildRoot $scriptName)).Length});Components=@(@{Name='ExplorerHost';Root='explorer';ManifestPath='explorer/host-component-manifest.json';ManifestSHA256=$hostManifestHash});SourceTree=@{ManifestPath='source-manifest.json';SHA256=(Get-LpHash (Join-Path $buildRoot 'source-manifest.json'));SourceSetSha256=$setHash}}
    Json $buildPath $build
    $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $source 'tests/run_all.ps1'),[ref]$tokens,[ref]$errors)
    $decl=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:AllCases'},$true))[0]
    $ids=@($decl.Right.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true) | ForEach-Object { @($_.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -ceq 'Id' })[0].Item2.SafeGetValue() })
    $results=@(foreach ($id in $ids) {
        $detail=Join-Path $evidence ($id+'.json');$out=Join-Path $evidence ($id+'.stdout');$err=Join-Path $evidence ($id+'.stderr')
        Json $detail @{Status='Passed';Assertions=1;Passed=1;Failed=0;CoverageGaps=@()};Put $out 'SYNTHETIC case record, NOT product results';Put $err ''
        [pscustomobject]@{Id=$id;Status='Passed';Assertions=1;Passed=1;Failed=0;ExitCode=0;TimedOut=$false;CoverageGaps=@();ResultPath=$detail;Stdout=$out;Stderr=$err}
    })
    $summary=@{Suite='SafeJunkCleaner independent regression';Status='Passed';Scope='Release';StartedUtc=$now;FinishedUtc=$now;ExitCode=0;Failed=0;Blocked=0;CoverageGaps=@();GateErrors=@();Results=$results;Passed=$ids.Count;Cases=$ids.Count;Assertions=$ids.Count;SourceHashes=@($records)+@([pscustomobject]@{Path=$exe;SHA256=(Get-LpHash $exe)});Exe=@{Path=$exe;SHA256=(Get-LpHash $exe)}}
    Json $summaryPath $summary
    $product=@(Get-LpComponentFacts $buildRoot (Get-LpJson $buildPath) $source)
    $buildHash=Get-LpHash $buildPath
    Json $finalPath @{Schema='SafeJunkCleaner.FinalTestResult.v1';Status='Passed';FinishedUtc=$now;BuildId=$buildId;BuildManifestSHA256=$buildHash;SourceSetSha256=$setHash;SourceHashes=$records;Artifacts=$product;Results=@(Get-LpVerificationIds '0.16.1' | ForEach-Object { @{Id=$_;Status='Passed';Assertions=1;Failed=0;Blocked=0} });Checks=@(@{Name='SyntheticGateShapeOnly';Passed=$true});ReleaseSummaryPath=$summaryPath}
    $screen=Join-Path $evidence 'desktop.synthetic.txt';Put $screen 'NOT a desktop observation; artificial gate schema only'
    Json $guiPath @{Status='Passed';AcceptedUtc=$now;BuildId=$buildId;BuildManifestSHA256=$buildHash;SourceSetSha256=$setHash;GuiSourceSHA256=(Get-LpHash (Join-Path $source 'src/Gui.ps1'));IconSHA256=(Get-LpHash (Join-Path $source 'assets/app.ico'));Checks=@(Get-LpDesktopChecks '0.16.1' | ForEach-Object { @{Name=$_;Passed=$true} });EvidenceFiles=@($screen)}
    $sealArgs=@{SourceRepository=$source;ExpectedSourceHead=$head;BuildManifestPath=$buildPath;SummaryPath=$summaryPath;GuiAcceptancePath=$guiPath;BuildInputsPath=$capture;FinalTestResultPath=$finalPath;Confirm=$false}
    $null=& $seal @sealArgs -OutputPath $envelope
    Check ((Get-LpJson $envelope).FinalTestResultPath -eq $finalPath) 'current seal writes the captured final path'
    $common=@{SourceRepository=$source;TargetRepository=$target;EvidencePath=$envelope}
    $before=@(Get-ChildItem -LiteralPath (Join-Path $target '.git') -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName+' '+(Get-LpHash $_.FullName) }) -join "`n"
    $ready=& $promote @common
    Check ($ready.Status -ceq 'Ready') 'current component preflight accepts the complete artificial evidence chain'
    $after=@(Get-ChildItem -LiteralPath (Join-Path $target '.git') -File -Recurse | Sort-Object FullName | ForEach-Object { $_.FullName+' '+(Get-LpHash $_.FullName) }) -join "`n"
    Check ($before -ceq $after) 'current preflight preserves target object store and refs'
    Check ([IO.File]::Exists((Join-Path $ready.IsolationDirectory '.isolation-owner'))) 'preflight isolation object store is retained with ownership marker'
    $missingArgs=$sealArgs.Clone();$missingArgs.Remove('FinalTestResultPath')
    Reject { & $seal @missingArgs -OutputPath (Join-Path $evidence 'missing-final-seal.json') } 'current sealing requires final parameter' 'FinalTestResultPath'
    $wrongArgs=$sealArgs.Clone();$wrongArgs.FinalTestResultPath=Join-Path $evidence 'another-final.json'
    Reject { & $seal @wrongArgs -OutputPath (Join-Path $evidence 'wrong-final-seal.json') } 'capture and seal cannot choose different final paths' 'path differs'
    With-Mutation $capture {param($v) $v.PSObject.Properties.Remove('FinalTestResultPath')} { Reject { & $seal @sealArgs -OutputPath (Join-Path $evidence 'capture-path-omitted.json') } 'capture cannot omit its bound final path' 'explicit final test result path' }
    With-Mutation $finalPath {param($v) $v.BuildId='different-package'} { Reject { & $seal @sealArgs -OutputPath (Join-Path $evidence 'swapped-final.json') } 'swapped final build cannot seal' 'not bound' }
    With-Mutation $finalPath {param($v) $v.FinishedUtc=[datetime]::UtcNow.AddHours(-73).ToString('o')} {
        Reject { & $seal @sealArgs -OutputPath (Join-Path $evidence 'expired-final.json') } 'expired final result cannot seal' 'Expired or future evidence'
        Reject { & (Join-Path $source 'scripts/publish.ps1') -BuildDirectory $buildRoot -VerificationDirectory $evidence -GuiAcceptancePath $guiPath -FinalTestResultPath $finalPath } 'formal publish cannot bypass expired final evidence' 'Expired or future evidence'
    }
    With-Mutation $finalPath {param($v) $v.Results=@($v.Results | Where-Object Id -CNE 'HeuristicExploration')} { Reject { & $seal @sealArgs -OutputPath (Join-Path $evidence 'missing-heuristic.json') } 'current verification cannot omit heuristic result' 'exactly|missing/failed' }
    With-Mutation $guiPath {param($v) $v.Checks=@($v.Checks | Where-Object Name -CNE 'HeuristicAnalysisObserved')} { Reject { & $seal @sealArgs -OutputPath (Join-Path $evidence 'missing-heuristic-desktop.json') } 'current desktop cannot omit actual heuristic check' 'Missing desktop acceptance' }
    With-Mutation $envelope {param($v) $v.PSObject.Properties.Remove('FinalTestResultPath')} { Reject { & $promote @common } 'consumer requires the sealed final path' 'requires FinalTestResultPath' }
    With-Mutation $finalPath {param($v) $v.Status='Failed'} { Reject { & $promote @common } 'post-seal final substitution refused' 'Sealed evidence changed' }
    # Test all three packaging adapters on this artificial source/build; there is
    # no application execution, user data or actual develop/main promotion.
    $candidateJson=& (Join-Path $Repository 'scripts/package-candidate.ps1') -SourceRepository $source -BuildDirectory $buildRoot -OutputParent $packages -StageOnly
    $candidate=$candidateJson | ConvertFrom-Json
    Check ($candidate.Status -ceq 'StageOnly') 'candidate CLI builds complete artificial layout'
    $null=Test-LpCandidateEnvelope $candidate.OutputDirectory
    $copied=Join-Path $packages ('r-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($copied)
    foreach ($f in @(Get-LpCandidateFiles $candidate.OutputDirectory)) { $relative=$f.FullName.Substring($candidate.OutputDirectory.Length+1);$to=Join-Path $copied $relative;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($to));[IO.File]::Copy($f.FullName,$to,$false) }
    $null=Test-LpCandidateEnvelope $copied;Check $true 'whole candidate directory remains valid after relocation'
    $manifestOnly=Join-Path $root 'invalid-flattened';[void][IO.Directory]::CreateDirectory($manifestOnly);[IO.File]::Copy((Join-Path $copied 'candidate-manifest.json'),(Join-Path $manifestOnly 'candidate-manifest.json'),$false)
    Reject { Test-LpCandidateEnvelope $manifestOnly } 'moving only the envelope is rejected' 'missing'
    $releaseResult=& (Join-Path $source 'scripts/publish.ps1') -BuildDirectory $buildRoot -VerificationDirectory $evidence -GuiAcceptancePath $guiPath -FinalTestResultPath $finalPath
    $release=$releaseResult | ConvertFrom-Json
    Check ($release.Status -ceq 'Verified' -and $release.ReleaseDirectory.StartsWith($source+'\',[StringComparison]::OrdinalIgnoreCase)) 'formal publish adapter succeeds only in artificial ignored releases'
    foreach ($p in @(Get-LpDeliveryDocuments '0.16.1')) { Check ([IO.File]::Exists((Join-Path $release.ReleaseDirectory $p))) ('formal and candidate document contract includes '+$p) }
    $formalResult=& (Join-Path $Repository 'scripts/package-local.ps1') -SourceRepository $source -ExpectedSourceHead $head -ReleaseDirectory $release.ReleaseDirectory -OutputDirectory (Join-Path $packages ('f-'+[guid]::NewGuid().ToString('N')))
    $formal=$formalResult | ConvertFrom-Json
    Check ($formal.Status -ceq 'Packaged') 'formal offline package adapter validates the same file contract'
    $r=& $promote @common -Execute -ExpectedSourceHead $head -ExpectedTargetHead $base -Confirm:$false
    Check ($r.Status -ceq 'FastForwarded' -and $r.Executed -and ((Invoke-LpGit $target @('rev-parse','HEAD')) -join '') -ceq $head) 'current complete chain fast-forwards only owned artificial main'
    Check ((& $promote @common).Status -ceq 'NoPromotionNeeded') 'current chain repeated invocation is a no-op'
    $result=@{Status='Passed';Assertions=$script:checks;FixtureDirectory=$root;Version='0.16.1';SyntheticOnly=$true;Retained=$true;BuildId=$buildId;SourceSetSha256=$setHash;CommitCount=2;ActualProductAcceptance=$false}
    Json (Join-Path $root 'result.json') $result;$result | ConvertTo-Json -Depth 5
} catch { Json (Join-Path $root 'failure.json') @{Status='Failed';Assertions=$script:checks;Message=$_.Exception.Message;Stack=$_.ScriptStackTrace;FixtureDirectory=$root;Retained=$true};throw }
