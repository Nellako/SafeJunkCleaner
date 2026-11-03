#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='High')]
param(
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][string]$TargetRepository,
    [string]$EvidencePath,
    [string]$ExpectedSourceHead,
    [string]$ExpectedTargetHead,
    [ValidateRange(1,168)][int]$MaxEvidenceAgeHours = 72,
    [switch]$Execute
)
. (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
Assert-LpEnvironment
$source = Get-LpRepository $SourceRepository 'develop'
$target = Get-LpRepository $TargetRepository 'main' -Target
Assert-LpSeparate $source.Path $target.Path
if ($ExpectedSourceHead) { Assert-LpHead $source $ExpectedSourceHead }
if ($ExpectedTargetHead) { Assert-LpHead $target $ExpectedTargetHead }
if ($Execute -and (-not $ExpectedSourceHead -or -not $ExpectedTargetHead)) { throw 'Execute requires both full expected HEADs.' }
if ($source.Head -ceq $target.Head) {
    [pscustomobject]@{Status='NoPromotionNeeded';Source=$source;Target=$target;Executed=$false}
    return
}
if (-not $EvidencePath) { throw 'Commit-bound evidence is required; seal existing acceptance first.' }
$evidenceHash = Test-LpEnvelope $source $EvidencePath $MaxEvidenceAgeHours
$isolation = New-LpIsolation
try {
    Assert-LpAncestor $isolation $source $target
    Assert-LpIgnoredConflicts $source $target
    $plan = [pscustomobject]@{Status='Ready';Source=$source;Target=$target;EvidenceSHA256=$evidenceHash;Executed=$false}
    if (-not $Execute) { $plan; return }
    if (-not $PSCmdlet.ShouldProcess($target.Path, "Fast-forward main $($target.Head) -> $($source.Head) from local develop")) {
        $plan.Status='NotExecuted'; $plan; return
    }
    # 确认等待后重新检查；任何变化都停止，不借当前 HEAD 重新决定验收对象。
    $sourceAgain = Get-LpRepository $source.Path 'develop'
    $targetAgain = Get-LpRepository $target.Path 'main' -Target
    Assert-LpHead $sourceAgain $source.Head
    Assert-LpHead $targetAgain $target.Head
    Assert-LpIgnoredConflicts $sourceAgain $targetAgain
    if ((Test-LpEnvelope $sourceAgain $EvidencePath $MaxEvidenceAgeHours) -cne $evidenceHash) { throw 'Evidence changed during confirmation.' }
    Assert-LpAncestor $isolation $sourceAgain $targetAgain
    # 从自己的隔离对象库取固定提交；不设置 remote，不写 FETCH_HEAD，不更新其他 refs。
    $null = Invoke-LpGit $target.Path @('fetch','--no-tags','--no-write-fetch-head','--no-recurse-submodules','--',$isolation,$source.Head)
    $sourceAgain = Get-LpRepository $source.Path 'develop'
    $targetAgain = Get-LpRepository $target.Path 'main' -Target
    Assert-LpHead $sourceAgain $source.Head
    Assert-LpHead $targetAgain $target.Head
    Assert-LpIgnoredConflicts $sourceAgain $targetAgain
    if ((Test-LpEnvelope $sourceAgain $EvidencePath $MaxEvidenceAgeHours) -cne $evidenceHash) { throw 'Evidence changed before fast-forward.' }
    $null = Invoke-LpGit $target.Path @('-c',('core.hooksPath='+$isolation),'-c','merge.autoStash=false','-c','submodule.recurse=false','merge','--ff-only','--no-edit','--no-autostash','--no-overwrite-ignore',$source.Head)
    $after = Get-LpRepository $target.Path 'main' -Target
    Assert-LpHead $after $source.Head
    $plan.Status='FastForwarded'; $plan.Target=$after; $plan.Executed=$true; $plan
} catch {
    throw "Promotion stopped. No rollback was attempted; inspect target HEAD/worktree and object store before retrying. $($_.Exception.Message)"
} finally {
    # 只删除本次创建的 GUID 隔离目录；不清理任何项目目录。
    if ($isolation -and [IO.Directory]::Exists($isolation)) { Remove-Item -LiteralPath $isolation -Recurse -Force -WhatIf:$false -Confirm:$false }
}
