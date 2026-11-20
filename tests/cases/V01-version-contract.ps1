#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
try{
    $version=Get-SjcVersionInfo
    # The product version is owned by version.json. Assert the declared contract and
    # internal consistency instead of a frozen literal, so a version bump is not
    # itself a regression. Old-task/old-plan refusal assertions below are unchanged.
    Assert-True 'public version is three numeric components' ([string]$version.version -match '^\d+\.\d+\.\d+$') ([string]$version.version)
    Assert-Equal 'Windows file version derives from the public version' (([string]$version.version) + '.0') $version.fileVersion
    Assert-Equal 'result version equals the metadata version' ([string]$version.version) (Get-SjcVersion)
    Assert-Equal 'schema independent from display version' 1 (Get-SjcPlanSchemaVersion)
    if($version.PSObject.Properties['channel'] -and $version.channel -cmatch '^(?:beta|rc)(?:\.[1-9][0-9]*)?$'){
        Assert-Equal 'prerelease display version includes channel' "$($version.version)-$($version.channel)" (Get-SjcDisplayVersion)
        $missing=Join-Path $EvidenceDirectory ([guid]::NewGuid().ToString('N'))
        Assert-Throws 'prerelease is refused by stable publish before evidence is read' {
            & (Join-Path $RepoRoot 'scripts\publish.ps1') -BuildDirectory $missing -VerificationDirectory $missing -GuiAcceptancePath $missing
        } 'prerelease; use package-candidate\.ps1'
    }else{
        Assert-Equal 'stable display version equals numeric version' ([string]$version.version) (Get-SjcDisplayVersion)
    }
    $sandbox=New-OwnedSandbox;$context=$sandbox.Context
    $target=Join-Path $sandbox.Root 'files\version.tmp';New-TestFile -Path $target -Bytes 8 -AgeHours 100|Out-Null
    $oldTask=New-SjcTaskDirectory $context
    $ownerPath=Join-Path $oldTask '.task-owner'
    $owner=Unprotect-SjcText (Read-SjcSafeText $ownerPath)|ConvertFrom-Json
    $owner.Version='3.0.0'
    Write-SjcAtomicText $ownerPath (Protect-SjcText ($owner|ConvertTo-Json -Compress))
    Assert-Throws 'old task refuses adoption' {Assert-SjcTaskDirectory $context $oldTask} '所有权'
    Assert-True 'rejected old task does not touch target' ([IO.File]::Exists($target))
    $task=New-SjcTaskDirectory $context
    $scan=Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'new scan works' 'Success' $scan.Status $scan.Error
    Assert-Equal 'new result product version' (Get-SjcVersion) $scan.Version
    $metaPath=Join-Path $task 'scan.meta.json'
    $meta=Unprotect-SjcText (Read-SjcSafeText $metaPath)|ConvertFrom-Json
    Assert-Equal 'new plan schema explicit' 1 $meta.SchemaVersion
    $meta.Version='3.0.0'
    Write-SjcAtomicText $metaPath (Protect-SjcText ($meta|ConvertTo-Json -Depth 8 -Compress))
    $clean=Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    Assert-Equal 'old plan clean fails closed' 'Failed' $clean.Status
    Assert-Equal 'old plan never deletes target' 0 $clean.Deleted
    Assert-True 'old plan target survives' ([IO.File]::Exists($target))
    $fresh=New-SjcTaskDirectory $context
    $freshScan=Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $fresh
    $freshClean=Invoke-SjcClean -Context $context -TaskDirectory $fresh -RecycleMode $false
    Assert-Equal 'new plan executes normally' 'Success' $freshClean.Status $freshClean.Error
    Assert-Equal 'only own synthetic file deleted' 1 $freshClean.Deleted
}catch{Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
Complete-TestCase
