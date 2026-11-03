#requires -Version 5.1
# N04: cache override configuration gates - a set override variable reports
# UnsupportedConfiguration (scan Partial), never authorizes the override path, and is
# re-read per file at clean time so a variable set after sealing blocks deletion.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$variableName = 'SJC_TEST_CACHE_OVERRIDE'
$originalVariable = [Environment]::GetEnvironmentVariable($variableName)
$originalRules = $null
try {
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    New-TestFile -Path (Join-Path $files 'override-old.tmp') -Bytes 64 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'override-old2.tmp') -Bytes 96 -AgeHours 120 | Out-Null

    # An attacker-controlled "override" directory that must never become a rule root.
    $outside = Join-Path $sandbox.Root 'override-outside'
    [void][IO.Directory]::CreateDirectory($outside)
    New-TestFile -Path (Join-Path $outside 'must-not-be-seen.tmp') -Bytes 128 -AgeHours 120 | Out-Null

    # Rule double: same sandbox root, but with an override denylist entry. Built through
    # the product constructor so every v0.12 seal field is present; only the override
    # environment name is added.
    $originalRules = ${function:Get-SjcRules}
    $script:n04Sandbox = $sandbox.Root
    $script:n04Active = $true
    $script:n04Variable = $variableName
    function New-N04OverrideRuleDouble {
        param([string]$Root, [string]$VariableName)
        $rule = New-SjcRule -Id 'SandboxOld' -TemplateId 'SandboxOld' -Name 'override-double' -Group 'test' -Root $Root -Patterns @('*.tmp') -MinimumAgeHours 24 -Recommended $true -OverrideEnvironment @($VariableName)
        $rule.PresetLevel = 'Low'; $rule.CleaningProfile = 'Medium'
        $rule.LowMinimumAgeHours = 24; $rule.MediumMinimumAgeHours = 24; $rule.HighMinimumAgeHours = 24
        $rule.MinimumAgeHours = 24; $rule.RecommendedMinimumAgeHours = 24; $rule.DeepMinimumAgeHours = 24
        return $rule
    }
    function Get-SjcRules {
        param($Context)
        if ($script:n04Active) {
            $root = Join-Path $script:n04Sandbox 'files'
            return @(New-N04OverrideRuleDouble -Root $root -VariableName $script:n04Variable)
        }
        & $script:n04OriginalRules -Context $Context
    }
    $script:n04OriginalRules = $originalRules

    # Baseline: no override variable -> normal scan.
    [Environment]::SetEnvironmentVariable($variableName, $null)
    $baselineTask = New-SjcTaskDirectory -Context $context
    $baselineScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $baselineTask -CustomEnabled $true
    Assert-Equal 'without an override variable the scan succeeds' 'Success' $baselineScan.Status $baselineScan.Error
    Assert-Equal 'without an override variable both sandbox files are candidates' 2 ([int64]$baselineScan.CandidateCount) ''

    # Set the override variable (current process only) and point it at an unrelated dir.
    try {
        [Environment]::SetEnvironmentVariable($variableName, $outside, 'Process')
        Assert-Equal 'the override variable is visible to this process' $outside ([Environment]::GetEnvironmentVariable($variableName))

        $blockedTask = New-SjcTaskDirectory -Context $context
        $blockedScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $blockedTask -CustomEnabled $true
        [void](Save-Evidence 'blocked-scan' $blockedScan)
        Assert-Equal 'scan with a set override is Partial, never Success' 'Partial' $blockedScan.Status $blockedScan.Error
        $blockedCategory = @($blockedScan.Categories)[0]
        Assert-Equal 'category reports UnsupportedConfiguration' 'UnsupportedConfiguration' ([string]$blockedCategory.Status)
        Assert-True 'category note states the override was not adopted' ([string]$blockedCategory.Note -match '覆盖配置|未读取|未采用') ([string]$blockedCategory.Note)
        Assert-Equal 'a set override yields zero candidates' 0 ([int64]$blockedScan.CandidateCount) ''
        $seen = @(Get-CandidateLines $blockedScan.PlanPath)
        Assert-Equal 'sealed plan contains no candidate lines' 0 $seen.Count ''
        Assert-True 'the override path itself is never scanned or reported' (-not (@($blockedScan.Categories | Where-Object { [string]$_.Root -like ($outside + '*') }).Count -gt 0)) ([string]$blockedCategory.Root)
        Assert-True 'outside file behind the override path is untouched' ([IO.File]::Exists((Join-Path $outside 'must-not-be-seen.tmp'))) ''
        Assert-True 'real sandbox files are untouched by a blocked scan' ([IO.File]::Exists((Join-Path $files 'override-old.tmp')) -and [IO.File]::Exists((Join-Path $files 'override-old2.tmp'))) ''

        # Unset: scanning works again, proving the gate is conditional.
        [Environment]::SetEnvironmentVariable($variableName, $null, 'Process')
        $recoveredTask = New-SjcTaskDirectory -Context $context
        $recoveredScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $recoveredTask -CustomEnabled $true
        Assert-Equal 'clearing the override restores a successful scan' 'Success' $recoveredScan.Status $recoveredScan.Error
        Assert-Equal 'clearing the override restores the two candidates' 2 ([int64]$recoveredScan.CandidateCount) ''

        # Set the override AFTER sealing: per-file revalidation must block all deletion.
        [Environment]::SetEnvironmentVariable($variableName, $outside, 'Process')
        $lateClean = Invoke-SjcClean -Context $context -TaskDirectory $recoveredTask -RecycleMode $false -CustomEnabled $true
        [void](Save-Evidence 'late-override-clean' $lateClean)
        Assert-True 'a clean with a late-set override does not report Success' ($lateClean.Status -ne 'Success') ([string]$lateClean.Status)
        Assert-Equal 'a clean with a late-set override deletes nothing' 0 ([int64]$lateClean.Deleted) ([string]$lateClean.Deleted)
        Assert-Equal 'both skipped files are counted as errors' 2 ([int64]$lateClean.ErrorCount) ([string]$lateClean.ErrorCount)
        $cleanErrorText = (@($lateClean.Errors) -join ' | ')
        Assert-True 'clean error names the override configuration guard' ($cleanErrorText -match '覆盖配置') $cleanErrorText
        Assert-True 'both sandbox files survive the blocked clean' ([IO.File]::Exists((Join-Path $files 'override-old.tmp')) -and [IO.File]::Exists((Join-Path $files 'override-old2.tmp'))) ''
        Assert-True 'outside override file still survives' ([IO.File]::Exists((Join-Path $outside 'must-not-be-seen.tmp'))) ''
    }
    finally {
        [Environment]::SetEnvironmentVariable($variableName, $originalVariable, 'Process')
    }

    # Restore the real rule table for any later step.
    $script:n04Active = $false
    ${function:Get-SjcRules} = $script:n04OriginalRules
    Assert-Equal 'the test override variable is restored to its original value' ([string]$originalVariable) ([string]([Environment]::GetEnvironmentVariable($variableName)))
    $normalTask = New-SjcTaskDirectory -Context $context
    $normalScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $normalTask -CustomEnabled $true
    Assert-Equal 'real rule table scans normally after the fixture is removed' 'Success' $normalScan.Status $normalScan.Error

    [void](Save-Evidence 'override-gate' ([pscustomobject]@{
        Variable = $variableName
        BaselineCandidates = $baselineScan.CandidateCount
        BlockedStatus = $blockedScan.Status
        BlockedCategory = $blockedCategory.Status
        LateCleanStatus = $lateClean.Status
        LateCleanDeleted = $lateClean.Deleted
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    [Environment]::SetEnvironmentVariable($variableName, $originalVariable, 'Process')
    if ($null -ne $originalRules) { ${function:Get-SjcRules} = $originalRules }
}
Complete-TestCase
