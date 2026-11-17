#requires -Version 5.1
# S02: one enumeration per exact root, candidate dedupe with rule attribution, hard
# WAL/SHM rejection independent of rule patterns, and per-rule age gates.
# The rule table is substituted only in-process for the overlap/WAL assertions;
# scanning still runs through production Invoke-SjcScan/Test-SjcRuleFile.
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

    New-TestFile -Path (Join-Path $files 'overlap-a.tmp') -Bytes 10 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'overlap-b.tmp') -Bytes 20 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'young.tmp') -Bytes 30 -AgeHours 20 | Out-Null
    New-TestFile -Path (Join-Path $files 'wal.sqlite-wal') -Bytes 40 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'extra-wal') -Bytes 50 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'shm.sqlite-shm') -Bytes 60 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'extra-shm') -Bytes 70 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'plain.tmp') -Bytes 80 -AgeHours 30 | Out-Null

    $originalRules = ${function:Get-SjcRules}
    $script:ruleOverrideApplied = $false
    # Rule doubles are built through the product constructor so every v0.12 seal field
    # (AgePolicy, ProcessPolicy, authorization/discovery bindings) is present; only the
    # id/root/patterns differ, making the overlap/dedupe verdict meaningful.
    function New-S02RuleDouble {
        param([string]$Id, [string]$TemplateId, [string]$Root)
        $rule = New-SjcRule -Id $Id -TemplateId $TemplateId -Name ($Id + '-double') -Group 'test' -Root $Root -Patterns @('*.tmp', '*') -MinimumAgeHours 24 -Recommended ($Id -eq 'SandboxOld')
        $rule.PresetLevel = 'Low'; $rule.CleaningProfile = 'Medium'
        $rule.LowMinimumAgeHours = 24; $rule.MediumMinimumAgeHours = 24; $rule.HighMinimumAgeHours = 24
        $rule.MinimumAgeHours = 24; $rule.RecommendedMinimumAgeHours = 24; $rule.DeepMinimumAgeHours = 24
        return $rule
    }
    function Get-SjcRules {
        param($Context)
        if ($script:ruleOverrideApplied) {
            $root = Join-Path $script:s02Sandbox 'files'
            @(
                (New-S02RuleDouble -Id 'SandboxOld' -TemplateId 'SandboxOld' -Root $root)
                (New-S02RuleDouble -Id 'SandboxLog' -TemplateId 'SandboxLog' -Root $root)
            )
            return
        }
        & $script:s02OriginalRules -Context $Context
    }
    $script:s02OriginalRules = $originalRules
    $script:s02Sandbox = $sandbox.Root
    $script:ruleOverrideApplied = $true

    $task = New-SjcTaskDirectory -Context $context
    $progressPath=Join-Path $task 'progress.json'
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task -ProgressPath $progressPath -CustomEnabled $true
    $script:ruleOverrideApplied = $false
    [void](Save-Evidence 'overlap-scan' $scan)

    Assert-Equal 'overlap scan succeeds' 'Success' $scan.Status $scan.Error
    $candidates = @(Get-CandidateLines $scan.PlanPath)
    $paths = @($candidates | ForEach-Object Path)
    $names = @($candidates | ForEach-Object { [IO.Path]::GetFileName([string]$_.Path) } | Sort-Object)
    Assert-Equal 'each physical file is a candidate exactly once despite two matching rules' $paths.Count (@($paths | Select-Object -Unique).Count)
    Assert-Equal 'CandidateCount equals the unique file count' $paths.Count ([int64]$scan.CandidateCount)
    $overlapProgress=Read-SjcSafeText $progressPath | ConvertFrom-Json
    Assert-Equal 'shared-root inspection count is eight files, not multiplied by two matching rules' 8 ([int64]$overlapProgress.Reviewed)
    Assert-Equal 'only old regular non-WAL/SHM files qualify' 'overlap-a.tmp|overlap-b.tmp|plain.tmp' ($names -join '|')
    Assert-True 'WAL/SHM names are rejected even when a rule pattern is *' (@($names | Where-Object { $_ -match '(?i)(-wal|-shm|\.wal|\.shm)$' }).Count -eq 0) ($names -join ',')
    Assert-True 'every overlap candidate is attributed to exactly one rule' (@($candidates | Where-Object { $_.RuleId -notin @('SandboxOld', 'SandboxLog') }).Count -eq 0) ''
    $owners = @($candidates | ForEach-Object RuleId | Sort-Object -Unique)
    Assert-Equal 'dedupe keeps a single owning rule for identical patterns' 'SandboxOld' ($owners -join ',')

    $categories = @($scan.Categories | Where-Object { $_.RuleId -in @('SandboxOld', 'SandboxLog') })
    $sumCount = 0
    foreach ($category in $categories) { $sumCount += [int64]$category.Count }
    Assert-Equal 'category counts sum to CandidateCount without double counting' ([int64]$scan.CandidateCount) $sumCount
    $sumBytes = 0
    foreach ($category in $categories) { $sumBytes += [int64]$category.Bytes }
    Assert-Equal 'category bytes sum to CandidateBytes without double counting' ([int64]$scan.CandidateBytes) $sumBytes

    # Restore the real rule table and verify rule-level ages on the same root.
    $script:ruleOverrideApplied = $false
    New-TestFile -Path (Join-Path $files 'age24.tmp') -Bytes 24 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'age24.log') -Bytes 47 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'age48.log') -Bytes 48 -AgeHours 50 | Out-Null

    $ageTask = New-SjcTaskDirectory -Context $context
    $ageScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $ageTask
    Assert-Equal 'rule-level age scan succeeds' 'Success' $ageScan.Status $ageScan.Error
    $ageCandidates = @(Get-CandidateLines $ageScan.PlanPath | Where-Object { $_.Path -like '*age2*' -or $_.Path -like '*age4*' })
    $ageByRule = @{}
    foreach ($c in $ageCandidates) { if (-not $ageByRule.ContainsKey($c.RuleId)) { $ageByRule[$c.RuleId] = New-Object 'System.Collections.Generic.List[string]' }; $ageByRule[$c.RuleId].Add([IO.Path]::GetFileName($c.Path)) }
    $oldList = if ($ageByRule.ContainsKey('SandboxOld')) { ($ageByRule['SandboxOld'] | Sort-Object) -join ',' } else { '' }
    $logList = if ($ageByRule.ContainsKey('SandboxLog')) { ($ageByRule['SandboxLog'] | Sort-Object) -join ',' } else { '' }
    Assert-Equal '24h rule picks the 30h tmp and not the 20h tmp' 'age24.tmp' $oldList
    Assert-Equal '48h rule picks only the 50h log' 'age48.log' $logList
    Assert-True 'rule age thresholds are applied independently on one root' ($oldList -eq 'age24.tmp' -and $logList -eq 'age48.log') ('old=' + $oldList + '; log=' + $logList)

    # Identical root must appear once in the enumeration grouping: duplicate selections
    # are already refused outright.
    $duplicateTask = New-SjcTaskDirectory -Context $context
    $duplicateScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxOld') -TaskDirectory $duplicateTask
    Assert-True 'selecting the same rule twice fails the scan instead of double counting' ($duplicateScan.Status -eq 'Failed' -and [string]$duplicateScan.Error -match '未知或重复规则') ('status=' + $duplicateScan.Status + '; error=' + $duplicateScan.Error)

    # Restore the original function for the remainder of the process.
    ${function:Get-SjcRules} = $script:s02OriginalRules
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
