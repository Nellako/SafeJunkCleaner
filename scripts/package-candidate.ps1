#requires -Version 5.1
<# Offline development candidate packaging. Inputs are trusted local maintainer build
output, never executed. StageOnly is NOT verification. No Git writes or promotion.
Every invocation creates a new GUID directory; failures retain partial output. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$BuildDirectory,
    [Parameter(Mandatory=$true)][string]$OutputParent,
    [string]$FinalTestResultPath,
    [string]$DesktopAcceptancePath,
    [switch]$StageOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
$output=$null
try {
    Assert-LpEnvironment
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source=Get-LpPath $SourceRepository -Directory
    $buildRoot=Get-LpPath $BuildDirectory -Directory
    $parent=Get-LpPath $OutputParent -Directory
    Assert-LpSeparate $source $parent
    Assert-LpSeparate $buildRoot $parent
    $top=((Invoke-LpGit $source @('rev-parse','--show-toplevel')) -join '').Replace('/','\')
    if ($top -ne $source) { throw 'Exact source Git root required.' }
    $head=(Invoke-LpGit $source @('rev-parse','--verify','HEAD')) -join ''
    $buildPath=Join-Path $buildRoot 'build-manifest.json'
    $build=Get-LpJson $buildPath
    $records=@(Get-LpWorkingSources $source)
    $setHash=Get-LpSourceSetHash $records
    $snapshotPath=Join-Path $buildRoot (Get-LpCandidateName $build.SourceTree.ManifestPath)
    if ($build.SourceTree.ManifestPath -cne 'source-manifest.json' -or (Get-LpHash $snapshotPath) -ne $build.SourceTree.SHA256 -or $setHash -ne $build.SourceTree.SourceSetSha256) { throw 'Build source tree manifest/hash mismatch.' }
    $snapshot=Get-LpJson $snapshotPath
    if ($snapshot.Schema -cne 'SafeJunkCleaner.SourceManifest.v1' -or $snapshot.GitHead -ne $head -or $snapshot.Dirty -isnot [bool] -or (Get-LpSourceSetHash $snapshot.Sources) -ne $setHash -or $snapshot.SourceSetSha256 -ne $setHash -or @($snapshot.Sources).Count -ne $records.Count) { throw 'Build snapshot differs from actual working source set.' }
    $product=@(Get-LpComponentFacts $buildRoot $build $source)
    $componentRecords=@($product)
    foreach ($p in @('build-manifest.json','source-manifest.json')) { $product += [pscustomobject]@{Path=$p;SHA256=(Get-LpHash (Join-Path $buildRoot $p));Bytes=([IO.FileInfo](Join-Path $buildRoot $p)).Length} }
    $evidence=@()
    if (-not $StageOnly) {
        if (-not $FinalTestResultPath -or -not $DesktopAcceptancePath) { throw 'Verified candidate requires final test result AND desktop acceptance; use -StageOnly for unverified staging.' }
        $evidence=@(Assert-LpCandidateEvidence $source $buildRoot $build $setHash $FinalTestResultPath $DesktopAcceptancePath $componentRecords)
    }
    # Source ZIP contains exact working bytes, not HEAD export; excluded diagnostic
    # documents remain fingerprinted and are listed explicitly in the envelope.
    $publicDocs=@(Get-LpDeliveryDocuments $build.Version | Where-Object { $_.StartsWith('docs/',[StringComparison]::Ordinal) })+@('docs/EXPLORATION-CONTRACT.md')
    $sourceZipRecords=@();$excluded=@()
    foreach ($r in $records) {
        if ((Test-LpNoModelVersion $build.Version) -and (Test-LpHistoricalModelSource $r.Path)) { $excluded += [pscustomobject]@{Path=$r.Path;SHA256=$r.SHA256;Reason='HistoricalModelExperiment; fingerprinted but excluded from no-model source ZIP'};continue }
        if ($r.Path.StartsWith('docs/',[StringComparison]::Ordinal) -and $r.Path -cnotin $publicDocs) { $excluded += [pscustomobject]@{Path=$r.Path;SHA256=$r.SHA256;Reason='PrivateDiagnosticDocument; fingerprinted but not copied to source ZIP'};continue }
        $sourceZipRecords += $r
    }
    $productDocs=@(Get-LpDeliveryDocuments $build.Version)
    foreach ($p in $productDocs) {
        $match=@($records | Where-Object Path -CEQ $p)
        if ($match.Count -ne 1) { throw "Required delivery document missing: $p" }
        Assert-LpPublicDocument (Join-Path $source $p)
        $product += [pscustomobject]@{Path=$p;SHA256=$match[0].SHA256;Bytes=$match[0].Bytes;InputPath=(Join-Path $source $p)}
    }
    $output=Join-Path $parent ('candidate-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $output) { throw 'Candidate directory already exists.' }
    $null=New-Item -ItemType Directory -Path $output -ErrorAction Stop
    $windowsZip=Join-Path $output ('SafeJunkCleaner_v'+$build.Version+'_windows.zip')
    New-LpCandidateZip $windowsZip $buildRoot $product
    Assert-LpPackageBudget $build.Version $windowsZip $product
    New-LpCandidateZip (Join-Path $output ('SafeJunkCleaner_v'+$build.Version+'_source.zip')) $source $sourceZipRecords
    $docs=Join-Path $output 'documents';$null=New-Item -ItemType Directory -Path $docs
    foreach ($p in $productDocs) {
        $target=Join-Path $docs $p;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target));[IO.File]::Copy((Join-Path $source $p),$target,$false)
    }
    if ((Get-LpSourceSetHash @(Get-LpWorkingSources $source)) -ne $setHash -or ((Invoke-LpGit $source @('rev-parse','--verify','HEAD')) -join '') -ne $head) { throw 'Working sources/HEAD changed while packaging.' }
    foreach ($r in $product) {
        $inputPath=if ($r.PSObject.Properties['InputPath']) { $r.InputPath } else { Join-Path $buildRoot $r.Path }
        if ((Get-LpHash $inputPath) -ne $r.SHA256) { throw 'Build/document changed while packaging.' }
    }
    foreach ($r in $evidence) { if ((Get-LpHash $r.Path) -ne $r.SHA256) { throw 'Acceptance evidence changed while packaging.' } }
    $files=@(Get-LpCandidateFiles $output | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($output.Length+1).Replace('\','/');SHA256=(Get-LpHash $_.FullName);Bytes=$_.Length} })
    $status=if ($StageOnly) {'StageOnly'} else {'VerifiedCandidate'}
    $envelope=[ordered]@{Schema='SafeJunkCleaner.DevelopmentCandidate.v1';Status=$status;DevelopmentCandidate=$true;Version=$build.Version;BuildId=$build.BuildId;GitHead=$head;Dirty=$true;SourceSetSha256=$setHash;BuildManifestSHA256=(Get-LpHash $buildPath);ZipEntriesVerified=$true;SourceZipExclusions=$excluded;Evidence=@($evidence | ForEach-Object { [pscustomobject]@{Name=[IO.Path]::GetFileName($_.Path);SHA256=$_.SHA256} });Files=$files;Limitations=@('Development candidate, not a formal release or promotion.','No application, download, scheduled task, publish or Git write was executed.','StageOnly is unverified; synthetic test fixtures are not deliverable models.')}
    if (Test-LpNoModelVersion $build.Version) { $envelope.ModelMode='Absent';$envelope.AlgorithmMode='Heuristic';$envelope.PayloadLimits=[pscustomobject]@{ZipBytes=50MB;ExtractedBytes=100MB} }
    [IO.File]::WriteAllText((Join-Path $output 'candidate-manifest.json'),($envelope | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($true))
    $null=Test-LpCandidateEnvelope $output
    [pscustomobject]@{Status=$status;OutputDirectory=$output;GitHead=$head;SourceSetSha256=$setHash} | ConvertTo-Json
} catch {
    [pscustomobject]@{Status='Failed';Message=$_.Exception.Message;OutputDirectory=$output;PartialOutputRetained=($null -ne $output)} | ConvertTo-Json
    exit 1
}
