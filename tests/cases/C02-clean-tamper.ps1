#requires -Version 5.1
# C02: clean revalidation - size/time/identity changes, vanished files, plan and rule-seal
# tampering must all be refused without deleting anything unsealed.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
try {
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($files)

    New-TestFile -Path (Join-Path $files 'grow.tmp') -Bytes 100 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'touch.tmp') -Bytes 200 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'replace.tmp') -Bytes 300 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'gone.tmp') -Bytes 400 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'honest.tmp') -Bytes 500 -AgeHours 96 | Out-Null

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'scan succeeds with five candidates' 'Success|5' ($scan.Status + '|' + $scan.CandidateCount) $scan.Error

    # Mutate after sealing.
    $grow = Join-Path $files 'grow.tmp'
    $stream = [IO.File]::Open($grow, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write([Text.Encoding]::ASCII.GetBytes('EXTRA'), 0, 5); $stream.Dispose()
    [IO.File]::SetLastWriteTimeUtc((Join-Path $files 'touch.tmp'), [datetime]::UtcNow.AddHours(-1))
    $replacePath = Join-Path $files 'replace.tmp'
    $replaceStamp = ([IO.FileInfo]::new($replacePath)).LastWriteTimeUtc
    [IO.File]::Delete($replacePath)
    $stream = [IO.File]::Open($replacePath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write((New-Object byte[] 300), 0, 300); $stream.Dispose()
    [IO.File]::SetLastWriteTimeUtc($replacePath, $replaceStamp)
    [IO.File]::Delete((Join-Path $files 'gone.tmp'))

    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    [void](Save-Evidence 'tamper-clean' $clean)

    Assert-Equal 'clean ends Partial, not Success' 'Partial' $clean.Status $clean.Error
    Assert-Equal 'only the honest candidate is deleted' 1 ([int64]$clean.Deleted)
    Assert-Equal 'four candidates are skipped' 4 ([int64]$clean.Skipped)
    Assert-Equal 'four skip errors are recorded' 4 ([int64]$clean.ErrorCount)
    Assert-Equal 'ProcessedBytes counts only the honest file' 500 ([int64]$clean.ProcessedBytes)
    Assert-True 'grown file survives untouched' ([IO.File]::Exists($grow)) ''
    Assert-True 'timestamp-changed file survives' ([IO.File]::Exists((Join-Path $files 'touch.tmp'))) ''
    Assert-True 'identity-replaced file survives' ([IO.File]::Exists($replacePath)) ''
    Assert-True 'honest file removed' (-not [IO.File]::Exists((Join-Path $files 'honest.tmp'))) ''
    $errorText = (@($clean.Errors) -join ' | ')
    Assert-True 'size-change skip is explicit' ($errorText -match 'grow\.tmp') $errorText
    Assert-True 'time-change skip is explicit' ($errorText -match 'touch\.tmp') $errorText
    Assert-True 'identity-change skip is explicit' ($errorText -match 'replace\.tmp') $errorText
    Assert-True 'vanished-file skip is explicit' ($errorText -match 'gone\.tmp') $errorText

    # Plan tampering after sealing: append a forged candidate.
    $task2 = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $files 'plan-a.tmp') -Bytes 10 -AgeHours 96 | Out-Null
    $scan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task2
    Assert-Equal 'second scan succeeds' 'Success' $scan2.Status $scan2.Error
    $originalBytes = [IO.File]::ReadAllBytes($scan2.PlanPath)
    $fake = '{"Id":"ffffffffffffffffffffffffffffffff","RuleId":"SandboxOld","Path":"' + (($files + '\plan-a.tmp').Replace('\', '\\')) + '","Length":10,"LastWriteUtc":"2020-01-01T00:00:00.0000000Z","FileIdentity":"DEADBEEF"}'
    [IO.File]::WriteAllBytes($scan2.PlanPath, ($originalBytes + [Text.Encoding]::UTF8.GetBytes($fake + "`n")))
    $tampered = Invoke-SjcClean -Context $context -TaskDirectory $task2 -RecycleMode $false
    Assert-True 'appended candidate blocks the clean with zero deletions' ($tampered.Status -eq 'Failed' -and [int64]$tampered.Deleted -eq 0) ('status=' + $tampered.Status + '; error=' + $tampered.Error)
    Assert-True 'plan candidate survives tampered clean' ([IO.File]::Exists((Join-Path $files 'plan-a.tmp'))) ''

    # Rule seal change: substitute the rule table with a changed age after sealing.
    [IO.File]::WriteAllBytes($scan2.PlanPath, $originalBytes)
    $originalRulesFn = ${function:Get-SjcRules}
    $script:c02Changed = $false
    $script:c02Sandbox = $sandbox.Root
    function Get-SjcRules {
        param($Context)
        if ($script:c02Changed) {
            $root = Join-Path $script:c02Sandbox 'files'
            return @([pscustomobject]@{ Id = 'SandboxOld'; TemplateId = 'SandboxOld'; Name = '自有测试旧文件'; Group = '合成测试'; Risk = '中低'; Recommended = $true; Root = $root; Patterns = @('*.tmp'); ExcludePatterns = @(); MinimumAgeHours = 1; RequiresClosedProcess = @(); Available = $true; Note = '' })
        }
        & $script:c02OriginalRulesFn -Context $Context
    }
    $script:c02OriginalRulesFn = $originalRulesFn
    $script:c02Changed = $true
    $ruleChanged = Invoke-SjcClean -Context $context -TaskDirectory $task2 -RecycleMode $false
    $script:c02Changed = $false
    ${function:Get-SjcRules} = $originalRulesFn
    Assert-True 'rule-seal change blocks the clean with zero deletions' ($ruleChanged.Status -eq 'Failed' -and [int64]$ruleChanged.Deleted -eq 0) ('status=' + $ruleChanged.Status + '; error=' + $ruleChanged.Error)

    # Restore, and confirm the sealed plan still cleans (proves the blocks were conditional).
    # Unrelated sandbox files may also be legitimate sealed candidates; assert the target.
    $restored = Invoke-SjcClean -Context $context -TaskDirectory $task2 -RecycleMode $false
    Assert-True 'restored rule table allows the sealed plan to clean' ($restored.Status -eq 'Success' -and [int64]$restored.Deleted -ge 1 -and -not [IO.File]::Exists((Join-Path $files 'plan-a.tmp'))) ('status=' + $restored.Status + '; deleted=' + $restored.Deleted + '; skipped=' + $restored.Skipped + '; error=' + $restored.Error)
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
