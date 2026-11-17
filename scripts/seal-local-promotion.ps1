#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Medium')]
param(
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$ExpectedSourceHead,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [switch]$CaptureBuildInputs,
    [string]$BuildManifestPath,
    [string]$SummaryPath,
    [string]$GuiAcceptancePath,
    [string]$BuildInputsPath,
    [string]$FinalTestResultPath,
    [ValidateRange(1,168)][int]$MaxEvidenceAgeHours = 72
)
. (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
Assert-LpEnvironment
$source=Get-LpRepository $SourceRepository 'develop'
Assert-LpHead $source $ExpectedSourceHead
$output=Get-LpPath $OutputPath
if (Test-Path -LiteralPath $output) { throw 'Output already exists; refusing to overwrite.' }
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($output))) { throw 'Create the output parent directory explicitly first.' }
if ($output.StartsWith($source.Path+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Keep input capture/sealed evidence outside the source repository.' }
$snapshot=@(Get-LpSnapshot $source)
$componentVersion=(Get-LpJson (Join-Path $source.Path 'version.json')).version -cin @('0.13.0','0.14.0','0.15.0','0.16.0','0.16.1')
if ($componentVersion -and -not $FinalTestResultPath) { throw 'Component capture/sealing requires explicit FinalTestResultPath (the planned result path may not exist before the build).' }
$finalPath=if ($FinalTestResultPath) { Get-LpPath $FinalTestResultPath } else { $null }
if ($CaptureBuildInputs) {
    $value=[ordered]@{ Schema='SafeJunkCleaner.BuildInputs.v1'; SourcePath=$source.Path; SourceCommit=$source.Head; CapturedUtc=[datetime]::UtcNow.ToString('o'); Sources=$snapshot }
    if ($finalPath) { $value.FinalTestResultPath=$finalPath }
} else {
    foreach ($p in @($BuildManifestPath,$SummaryPath,$GuiAcceptancePath,$BuildInputsPath)) { if (-not $p) { throw 'Sealing requires build manifest, Release summary, desktop acceptance and pre-build input capture.' } }
    $facts=Get-LpEvidenceFacts $source $BuildManifestPath $SummaryPath $GuiAcceptancePath $BuildInputsPath $MaxEvidenceAgeHours $finalPath
    $value=[ordered]@{
        Schema='SafeJunkCleaner.LocalPromotion.v1'; SourcePath=$source.Path; SourceGitDirectory=$source.GitDirectory
        SourceBranch=$source.Branch; SourceCommit=$source.Head; SourceTree=$source.Tree
        SealedUtc=[datetime]::UtcNow.ToString('o'); ExpiresUtc=([DateTimeOffset]::Parse($facts.OldestUtc).UtcDateTime.AddHours($MaxEvidenceAgeHours)).ToString('o')
        BuildManifestPath=(Get-LpPath $BuildManifestPath); SummaryPath=(Get-LpPath $SummaryPath)
        GuiAcceptancePath=(Get-LpPath $GuiAcceptancePath); BuildInputsPath=(Get-LpPath $BuildInputsPath)
        Snapshot=$snapshot; Files=@($facts.Files)
    }
    if ($finalPath) { $value.FinalTestResultPath=$finalPath }
}
$again=Get-LpRepository $source.Path 'develop'
Assert-LpHead $again $source.Head
if ((@(Get-LpSnapshot $again) | ConvertTo-Json -Depth 5 -Compress) -cne ($snapshot | ConvertTo-Json -Depth 5 -Compress)) { throw 'Source changed while sealing.' }
if (-not $CaptureBuildInputs) {
    $second=Get-LpEvidenceFacts $again $BuildManifestPath $SummaryPath $GuiAcceptancePath $BuildInputsPath $MaxEvidenceAgeHours $finalPath
    if (($second.Files | ConvertTo-Json -Depth 5 -Compress) -cne ($facts.Files | ConvertTo-Json -Depth 5 -Compress)) { throw 'Acceptance evidence changed while sealing.' }
}
if ($PSCmdlet.ShouldProcess($output,'Write new commit-bound local evidence (no Git writes)')) {
    $stream=[IO.File]::Open($output,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($true))
        try { $writer.Write(($value | ConvertTo-Json -Depth 12)); $writer.Flush() } finally { $writer.Dispose() }
    } finally { $stream.Dispose() }
    [pscustomobject]@{Status='Sealed';Path=$output;SourceCommit=$source.Head;SHA256=(Get-LpHash $output);CaptureBuildInputs=[bool]$CaptureBuildInputs}
}
