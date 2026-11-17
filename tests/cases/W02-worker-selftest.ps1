#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
try {
    $parent=Join-Path $EvidenceDirectory ('source-selftest-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $parent) { throw 'SelfTest 父目录必须不存在。' }
    if (-not (Test-SjcPathWithin $parent $EvidenceDirectory) -or -not (Test-SjcNoReparsePath $parent -AllowMissing)) { throw 'SelfTest 父目录越界或祖先不安全。' }
    $entry=Join-Path $RepoRoot 'src\Main.ps1'
    $run=Invoke-ReleasePowerShellScript -ScriptPath $entry -ScriptArguments ('-WorkerMode SelfTest -SelfTestParentDirectory '+(Quote-ReleaseArgument $parent)) -Tag 'source-selftest' -TimeoutSeconds 90
    Assert-True 'source selftest exits within timeout' (-not $run.TimedOut)
    Assert-Equal 'source selftest exits zero' 0 $run.ExitCode
    $result=Get-ReleaseTextFile $run.StdoutPath | ConvertFrom-Json
    [void](Save-Evidence 'selftest' $result)
    Assert-Equal 'source status success' 'Success' $result.Status $result.Error
    Assert-Equal 'source version matches current contract' (Get-SjcVersion) $result.Version
    Assert-Equal 'all core and gui checks passed' 0 (@($result.Checks|Where-Object {-not $_.Passed}).Count)
    Assert-True 'source selftest actually ran core and gui checks' (@($result.Checks).Count -ge 4)
    Assert-Equal 'real scan count' 2 $result.Scan.CandidateCount
    Assert-Equal 'real clean count' 1 $result.Clean.Deleted
    Assert-Equal 'real exclusion' 1 $result.Clean.Skipped
    Assert-Equal 'WPF gui selftest' 'Success' $result.Gui.Status (@($result.Gui.Failed)-join ';')
    $root=Get-SjcFullPath $result.SandboxRoot
    $guid=[guid]::Empty
    $owned=([IO.Path]::GetDirectoryName($root) -ceq $parent -and [guid]::TryParseExact([IO.Path]::GetFileName($root),'D',[ref]$guid) -and (Test-SjcNoReparsePath $root) -and [IO.File]::Exists((Join-Path $root '.sandbox-owner')))
    Assert-True 'child sandbox is a marked GUID directly under the requested evidence parent' $owned $root
    if (-not $owned) { throw '子进程自测返回的沙箱路径未通过边界验证。' }
    Assert-True 'old synthetic target removed' (-not [IO.File]::Exists((Join-Path $root 'files\owned-old.tmp')))
    Assert-True 'new synthetic target survives' ([IO.File]::Exists((Join-Path $root 'files\owned-new.tmp')))
    Assert-True 'excluded synthetic target survives' ([IO.File]::Exists((Join-Path $root 'files\owned-kept.tmp')))
    Assert-True 'child wrote a pre-deletion manifest within its own task' ([IO.File]::Exists((Join-Path ([IO.Path]::GetDirectoryName($result.Scan.PlanPath)) 'test-deletion-manifest.json')))
    Assert-True 'selftest log stays inside child sandbox state' (Test-SjcPathWithin $result.LogPath (Join-Path $root 'state')) $result.LogPath

    $invalid=Invoke-ReleasePowerShellScript -ScriptPath $entry -ScriptArguments '-WorkerMode Bogus' -Tag 'invalid-mode' -TimeoutSeconds 15
    Assert-ReleaseNonZeroRun $invalid 'invalid mode'
    foreach($invalidMode in @('Scan','Clean','Recycle','Gui')) {
        $rejectedParent=Join-Path $EvidenceDirectory ('rejected-'+$invalidMode)
        $rejected=Invoke-ReleasePowerShellScript -ScriptPath $entry -ScriptArguments ('-WorkerMode '+$invalidMode+' -SelfTestParentDirectory '+(Quote-ReleaseArgument $rejectedParent)) -Tag ('invalid-isolation-'+$invalidMode) -TimeoutSeconds 15
        Assert-ReleaseNonZeroRun $rejected ('isolation parameter rejects '+$invalidMode)
        Assert-True ($invalidMode+' rejection creates no isolation directory') (-not (Test-Path -LiteralPath $rejectedParent))
    }
    $rejectedOutput=Join-Path $EvidenceDirectory 'forbidden-selftest-output.json'
    $badChannel=Invoke-ReleasePowerShellScript -ScriptPath $entry -ScriptArguments ('-WorkerMode SelfTest -SelfTestParentDirectory '+(Quote-ReleaseArgument (Join-Path $EvidenceDirectory 'rejected-output-parent'))+' -OutputPath '+(Quote-ReleaseArgument $rejectedOutput)) -Tag 'invalid-selftest-output' -TimeoutSeconds 15
    Assert-ReleaseNonZeroRun $badChannel 'isolated selftest cannot use an external output channel' $rejectedOutput
    Add-Limitation '源码 SelfTest 只使用现有 SelfTestParentDirectory 新父目录和 stdout JSON；未创建正式任务、未启用真实回收/UAC，所有子进程自有目录保留。'
} catch {Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
Complete-TestCase
