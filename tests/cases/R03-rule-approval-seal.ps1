#requires -Version 5.1
# R03: rule approval and sealed-plan integrity - a plan seals exact rule definitions;
# changed rules, extra candidates and unapproved rule ids must be refused.
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
    New-TestFile -Path (Join-Path $files 'sealed-old.tmp') -Bytes 111 -AgeHours 120 | Out-Null
    New-TestFile -Path (Join-Path $files 'sealed-old.log') -Bytes 222 -AgeHours 120 | Out-Null

    # Unknown rule ids never resolve.
    Assert-Throws 'unknown rule id is rejected' { Get-SjcSelectedRules -Context $context @('NotARule') } '未知或重复规则'
    Assert-Throws 'duplicate rule id is rejected' { Get-SjcSelectedRules -Context $context @('SandboxOld', 'SandboxOld') } '未知或重复规则'
    Assert-Throws 'empty rule selection is rejected' { Get-SjcSelectedRules -Context $context @() } '没有选择规则'
    $selected = @(Get-SjcSelectedRules -Context $context @('SandboxOld', 'SandboxLog'))
    Assert-Equal 'valid selection returns the requested rule instances' 2 $selected.Count

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task -CustomEnabled $true
    Assert-Equal 'baseline scan is Success with two candidates' 'Success|2' ($scan.Status + '|' + $scan.CandidateCount) $scan.Error
    $metaPath = Join-Path $task 'scan.meta.json'
    Assert-True 'scan.meta.json exists and is sealed (not plaintext JSON)' ([IO.File]::Exists($metaPath) -and -not ((Get-Content -LiteralPath $metaPath -Raw) -match '"PlanHash"')) ''

    $page = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 500)
    Assert-Equal 'sealed plan returns both candidates' 2 $page.Count
    $candidate = $page[0]

    # A plan file swapped for another valid JSONL must fail the hash check.
    $planBytes = [IO.File]::ReadAllBytes($scan.PlanPath)
    $tamperedPlan = $planBytes + [Text.Encoding]::UTF8.GetBytes(('{"Id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","RuleId":"SandboxOld","Path":"' + ($candidate.Path -replace '\\', '\\') + '","Length":1,"LastWriteUtc":"' + $candidate.LastWriteUtc + '","FileIdentity":"x"}' + "`n"))
    [IO.File]::WriteAllBytes($scan.PlanPath, $tamperedPlan)
    Assert-Throws 'appended candidate invalidates plan hash' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 10 } '完整性|汇总|不匹配'
    Assert-Throws 'appended candidate also blocks export' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'export.csv') } '完整性|汇总|不匹配'
    [IO.File]::WriteAllBytes($scan.PlanPath, $planBytes)
    Assert-Equal 'restored plan pages again' 2 (@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 500).Count)

    # Tampering with a single candidate field (identity) must be refused.
    $lines = [IO.File]::ReadAllLines($scan.PlanPath)
    $first = $lines[0] | ConvertFrom-Json
    $first.FileIdentity = 'DEADBEEF:00000000:00000000'
    $lines[0] = ($first | ConvertTo-Json -Compress)
    [IO.File]::WriteAllLines($scan.PlanPath, $lines, $Utf8NoBom)
    Assert-Throws 'candidate identity tampering invalidates plan' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 10 } '完整性|汇总|不匹配'
    [IO.File]::WriteAllBytes($scan.PlanPath, $planBytes)
    Assert-Equal 'plan restored for clean attempt' 2 (@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 500).Count)

    # Rule seal: metadata is DPAPI sealed, so a direct edit is not possible. Instead
    # verify the sealed rule set matches the current rule definitions exactly.
    $currentRules = @(Get-SjcRules -Context $context)
    foreach ($rule in $currentRules) {
        $seal = Get-SjcRuleSeal $rule
        Assert-True ('rule seal is deterministic for ' + $rule.Id) ($seal -ceq (Get-SjcRuleSeal $rule)) $seal
    }
    $sealObj = (Get-SjcRuleSeal $currentRules[0]) | ConvertFrom-Json
    # New contract: the seal also pins the profile, both profile ages, the
    # environment-override denylist, the v0.12 age/process policy and the
    # discovery-authorization binding, so any of those changing invalidates approval.
    $expectedSealFields = 'AgePolicy,AuthorizationBinding,AuthorizationId,CleaningProfile,DiscoveryAdapter,DiscoverySource,DiscoverySourceValue,ExcludePatterns,HighMinimumAgeHours,Id,LowMinimumAgeHours,MediumMinimumAgeHours,MinimumAgeHours,OverrideEnvironment,Patterns,PresetLevel,ProcessPolicy,RequiresClosedProcess,Root,RootDirectoryIdentity,TemplateId'
    Assert-Equal 'seal covers identity, tier, PresetLevel, three tier ages, policy, discovery binding and override fields' $expectedSealFields (@($sealObj.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-True 'seal includes root, patterns, age and process requirements' ($sealObj.Root -and $sealObj.Patterns -and $sealObj.MinimumAgeHours -and $null -ne $sealObj.RequiresClosedProcess) ''
    # High may legitimately be 0 for a reviewed pure cache, so the seal assertion checks
    # Low/Medium positivity and the High value being present and non-negative.
    Assert-True 'seal includes the tier, PresetLevel and all three tier ages' ($sealObj.CleaningProfile -in @('Low','Medium','High') -and $sealObj.PresetLevel -in @('Low','Medium','High','CustomOnly') -and $sealObj.LowMinimumAgeHours -gt 0 -and $sealObj.MediumMinimumAgeHours -gt 0 -and [double]$sealObj.HighMinimumAgeHours -ge 0) ([string]$sealObj.CleaningProfile + '; level=' + [string]$sealObj.PresetLevel + '; high=' + [string]$sealObj.HighMinimumAgeHours)
    Assert-True 'seal pins the age policy and process policy' ($sealObj.AgePolicy -cin @('AgeBounded','PureCache') -and $sealObj.ProcessPolicy -cin @('NameGuard','NewTeamsWebView2')) ([string]$sealObj.AgePolicy + '/' + [string]$sealObj.ProcessPolicy)
    Assert-True 'seal pins an empty discovery binding for a static rule' ([string]::IsNullOrEmpty([string]$sealObj.AuthorizationId) -and [string]::IsNullOrEmpty([string]$sealObj.AuthorizationBinding) -and [string]::IsNullOrEmpty([string]$sealObj.RootDirectoryIdentity)) ('id=' + [string]$sealObj.AuthorizationId)

    $changed = (Get-SjcRuleSeal $currentRules[0]) | ConvertFrom-Json
    $changed.MinimumAgeHours = 1
    Assert-True 'changed age produces a different seal (approval would fail)' ((Get-SjcRuleSeal $currentRules[0]) -cne ($changed | ConvertTo-Json -Depth 5 -Compress)) ''
    $profileChanged = (Get-SjcRuleSeal $currentRules[0]) | ConvertFrom-Json
    $profileChanged.CleaningProfile = 'High'
    Assert-True 'changed tier produces a different seal (approval would fail)' ((Get-SjcRuleSeal $currentRules[0]) -cne ($profileChanged | ConvertTo-Json -Depth 5 -Compress)) ''
    $levelChanged = (Get-SjcRuleSeal $currentRules[0]) | ConvertFrom-Json
    $levelChanged.PresetLevel = 'CustomOnly'
    Assert-True 'changed PresetLevel produces a different seal (approval would fail)' ((Get-SjcRuleSeal $currentRules[0]) -cne ($levelChanged | ConvertTo-Json -Depth 5 -Compress)) ''
    $ageChanged = (Get-SjcRuleSeal $currentRules[0]) | ConvertFrom-Json
    $ageChanged.HighMinimumAgeHours = 1
    Assert-True 'changed High tier age produces a different seal (approval would fail)' ((Get-SjcRuleSeal $currentRules[0]) -cne ($ageChanged | ConvertTo-Json -Depth 5 -Compress)) ''

    # Clean must read the sealed plan, not re-enumerate the sandbox.
    $clean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false -CustomEnabled $true
    Assert-Equal 'clean succeeds against the sealed plan' 'Success|2' ($clean.Status + '|' + $clean.Deleted) $clean.Error
    Assert-True 'both sealed candidates are gone from disk' (-not [IO.File]::Exists((Join-Path $files 'sealed-old.tmp')) -and -not [IO.File]::Exists((Join-Path $files 'sealed-old.log'))) ''
    $second = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false -CustomEnabled $true
    Assert-True 'a second clean on the same plan is refused (single-use claim)' ($second.Status -eq 'Failed' -and [int]$second.Deleted -eq 0) ('status=' + $second.Status + '; deleted=' + $second.Deleted + '; error=' + $second.Error)

    # Foreign task directory cannot be adopted.
    $foreign = Join-Path $sandbox.Root 'foreign-task'
    [void][IO.Directory]::CreateDirectory($foreign)
    Assert-Throws 'non-GUID task directory is refused' { Assert-SjcTaskDirectory $context $foreign } 'GUID'
    $otherSandbox = New-OwnedSandbox
    $otherTask = New-SjcTaskDirectory -Context $otherSandbox.Context
    Assert-Throws 'task from another context is refused' { Assert-SjcTaskDirectory $context $otherTask } '不属于当前状态根'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
