#requires -Version 5.1
# N01: cleaning-profile context contract - Low/Medium/High construction, Medium default,
# exact-case validation, direct field assignment refusal, rule table rebuild on switch,
# per-tier effective MinimumAgeHours, same-tier -Invalidate re-scan enforcement, and the
# frozen Recommended/Deep values being refused everywhere.
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
    $root = $sandbox.Root

    # Default tier for a context created without an explicit profile.
    $defaultContext = New-SjcContext -TestRoot $root
    Assert-Equal 'new contexts default to Medium' 'Medium' ([string]$defaultContext.CleaningProfile)
    Assert-Equal 'default context rules carry the Medium profile' 'Medium' ([string](@(Get-SjcRules -Context $defaultContext)[0].CleaningProfile))

    # The three tiers come from a single engine-owned table.
    $profiles = @(Get-SjcCleaningProfiles)
    Assert-Equal 'engine exposes exactly Low/Medium/High' 'Low,Medium,High' (@($profiles | ForEach-Object { [string]$_.Id }) -join ',')
    Assert-Equal 'tier table exposes Id/Label/Description/Impact' 'Description,Id,Impact,Label' (@($profiles[0].PSObject.Properties.Name | Sort-Object) -join ',')

    # Explicit construction of all three tiers. Get-SjcRules returns the full trusted
    # table tagged with the active tier; preset membership is Get-SjcPresetRuleIds' job.
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $tierContext = New-SjcContext -TestRoot $root -CleaningProfile $tier
        Assert-Equal ('explicit ' + $tier + ' context is accepted') $tier ([string]$tierContext.CleaningProfile)
        $tierRules = @(Get-SjcRules -Context $tierContext)
        $offProfile = @($tierRules | Where-Object { [string]$_.CleaningProfile -cne $tier })
        Assert-Equal ($tier + ' rule instances all report the tier') 0 $offProfile.Count (($offProfile | ForEach-Object { $_.Id + '=' + $_.CleaningProfile }) -join ',')
        Assert-Equal ($tier + ' rule table is stable across tiers (only the profile tag moves)') 'SandboxLog,SandboxOld' (@($tierRules | ForEach-Object Id | Sort-Object) -join ',')
    }

    # Frozen Recommended/Deep values must be refused at construction, by the setter, and
    # by the preset API - no silent alias to Low or High.
    $badProfiles = @('Recommended', 'Deep', 'low', 'MEDIUM', 'Medium ', 'HighX', '', 'Max')
    foreach ($bad in $badProfiles) {
        $value = $bad
        Assert-Throws ('New-SjcContext rejects profile "' + $value + '"') { New-SjcContext -TestRoot $root -CleaningProfile $value } 'Low、Medium 或 High'
    }
    Assert-Throws 'New-SjcContext rejects a non-string profile' { New-SjcContext -TestRoot $root -CleaningProfile 1 } 'Low、Medium 或 High'

    # Set-SjcCleaningProfile rebuilds the rule table and returns nothing.
    $context = New-SjcContext -TestRoot $root -CleaningProfile 'Low'
    $beforeIds = @(Get-SjcRules -Context $context | ForEach-Object Id)
    $returnValue = Set-SjcCleaningProfile -Context $context -CleaningProfile 'High'
    Assert-True 'Set-SjcCleaningProfile returns no value' ($null -eq $returnValue) ([string]$returnValue)
    Assert-Equal 'context reflects the new tier' 'High' ([string]$context.CleaningProfile)
    $afterRules = @($context.Rules)
    Assert-True 'switching rebuilds Context.Rules' ($afterRules.Count -gt 0 -and @($afterRules | Where-Object { $_.CleaningProfile -cne 'High' }).Count -eq 0) ('rules=' + $afterRules.Count)
    Assert-Equal 'switching does not add or remove rule ids' (($beforeIds | Sort-Object) -join '|') ((@($afterRules | ForEach-Object Id) | Sort-Object) -join '|')
    foreach ($bad in @('Recommended', 'Deep', 'high', '')) {
        $value = $bad
        Assert-Throws ('Set-SjcCleaningProfile rejects "' + $value + '"') { Set-SjcCleaningProfile -Context $context -CleaningProfile $value } 'Low、Medium 或 High'
    }
    Assert-Equal 'rejected switches leave the tier unchanged' 'High' ([string]$context.CleaningProfile)

    # Idempotent switch is a no-op without -Invalidate.
    $countBefore = @(Get-SjcRules -Context $context).Count
    $epochBefore = (Get-SjcContextConfiguration $context).ProfileEpoch
    $noop = Set-SjcCleaningProfile -Context $context -CleaningProfile 'High'
    Assert-True 'repeating the current tier without -Invalidate is a silent no-op' ($null -eq $noop -and @(Get-SjcRules -Context $context).Count -eq $countBefore -and (Get-SjcContextConfiguration $context).ProfileEpoch -eq $epochBefore) ([string]$noop)

    # Per-tier effective age on the production table (context switched in memory only).
    # v0.12: reviewed PureCache templates drop to 0h at High; everything else keeps a
    # positive High age. Low/Medium are unchanged for all of these templates.
    $production = New-ProductionContextForInventory
    $tierAgeExpect = @{
        UserTemp = @{ Low = 24; Medium = 24; High = 6 }
        WindowsTemp = @{ Low = 48; Medium = 48; High = 24 }
        VSCodeCache = @{ Low = 48; Medium = 48; High = 0 }
        VSCodeCodeCache = @{ Low = 168; Medium = 168; High = 0 }
        GradleCache = @{ Low = 720; Medium = 720; High = 168 }
        CrashDumps = @{ Low = 720; Medium = 720; High = 720 }
        D3DSCache = @{ Low = 168; Medium = 168; High = 168 }
    }
    $ageErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($tier in @('Low', 'Medium', 'High')) {
        [void](Set-SjcCleaningProfile -Context $production -CleaningProfile $tier)
        $rulesNow = @(Get-SjcRules -Context $production)
        foreach ($template in $tierAgeExpect.Keys) {
            foreach ($rule in @($rulesNow | Where-Object { $_.TemplateId -ceq $template })) {
                $expected = [double]$tierAgeExpect[$template][$tier]
                if ([double]$rule.MinimumAgeHours -ne $expected) { $ageErrors.Add($rule.Id + ':' + $tier + '=' + $rule.MinimumAgeHours + '/expected ' + $expected) }
                if ([string]$rule.CleaningProfile -cne $tier) { $ageErrors.Add($rule.Id + ':profile=' + $rule.CleaningProfile) }
            }
        }
        # Browser Cache/Code/GPU and Firefox cache2 are pure caches: High=0, else 24.
        $browserExpected = if ($tier -ceq 'High') { 0 } else { 24 }
        foreach ($rule in @($rulesNow | Where-Object { $_.Group -ceq '浏览器缓存' -and [double]$_.MinimumAgeHours -ne $browserExpected })) {
            $ageErrors.Add($rule.Id + ':browser-' + $tier + '=' + $rule.MinimumAgeHours)
        }
        # Non-browser browser-cache templates must still keep a positive High age.
        if ($tier -ceq 'High') {
            foreach ($rule in @($rulesNow | Where-Object { $_.Group -ceq '浏览器缓存' -and [string]$_.AgePolicy -cne 'PureCache' })) { $ageErrors.Add($rule.Id + ':browser-not-pure') }
        }
    }
    [void](Set-SjcCleaningProfile -Context $production -CleaningProfile 'Medium')
    Assert-True 'each tier applies its own effective MinimumAgeHours (pure-cache browser High=0)' ($ageErrors.Count -eq 0) (($ageErrors | Select-Object -First 10) -join '; ')
    Add-Limitation 'N01 仅在内存中切换生产上下文档位以核对规则阈值；未扫描生产缓存、未写生产首选项。'

    # Same-tier -Invalidate: a scope change inside one tier must invalidate sealed plans.
    $scanContext = New-SjcContext -TestRoot $root -CleaningProfile 'Medium'
    New-TestFile -Path (Join-Path $root 'files\invalidate-old.tmp') -Bytes 64 -AgeHours 96 | Out-Null
    $scanTask = New-SjcTaskDirectory -Context $scanContext
    $scan = Invoke-SjcScan -Context $scanContext -RuleIds @('SandboxOld') -TaskDirectory $scanTask -CustomEnabled $true
    Assert-Equal 'baseline custom scan succeeds' 'Success' ([string]$scan.Status) ([string]$scan.Error)
    $epochBeforeInvalidate = (Get-SjcContextConfiguration $scanContext).ProfileEpoch
    $invalidateReturn = Set-SjcCleaningProfile -Context $scanContext -CleaningProfile 'Medium' -Invalidate
    Assert-True 'same-tier -Invalidate returns no value' ($null -eq $invalidateReturn) ([string]$invalidateReturn)
    Assert-True 'same-tier -Invalidate advances the profile epoch' ((Get-SjcContextConfiguration $scanContext).ProfileEpoch -gt $epochBeforeInvalidate) ('before=' + $epochBeforeInvalidate + '; after=' + (Get-SjcContextConfiguration $scanContext).ProfileEpoch)
    Assert-True 'same-tier -Invalidate writes the denial marker' ([IO.File]::Exists((Join-Path $scanTask 'profile.invalidated'))) ''
    $invalidatedClean = Invoke-SjcClean -Context $scanContext -TaskDirectory $scanTask -RecycleMode $false -CustomEnabled $true
    Assert-True 'same-tier -Invalidate blocks the old plan with zero deletions' ($invalidatedClean.Status -eq 'Failed' -and [int64]$invalidatedClean.Deleted -eq 0) ('status=' + $invalidatedClean.Status + '; deleted=' + $invalidatedClean.Deleted + '; error=' + $invalidatedClean.Error)
    Assert-True 'the invalidation reason names the profile/rescan requirement' ([string]$invalidatedClean.Error -match '档位|重新扫描') ([string]$invalidatedClean.Error)

    # Direct assignment to Context.CleaningProfile must be refused by the trust check.
    $tampered = New-SjcContext -TestRoot $root -CleaningProfile 'Low'
    $tampered.CleaningProfile = 'High'
    Assert-Throws 'direct Context.CleaningProfile assignment is refused' { Get-SjcContextConfiguration $tampered } 'Set-SjcCleaningProfile'
    Assert-Throws 'trusted calls also refuse a tampered context field' { Get-SjcRules -Context $tampered } 'Set-SjcCleaningProfile'
    Assert-Throws 'the setter cannot silently repair a tampered context' { Set-SjcCleaningProfile -Context $tampered -CleaningProfile 'Low' } 'Set-SjcCleaningProfile'
    Assert-Equal 'tampered context is not trust-laundered back to a valid tier' 'High' ([string]$tampered.CleaningProfile)

    # A context this process did not create must never be trusted.
    $foreign = [pscustomobject]@{ Version = (Get-SjcVersion); StateRoot = $root; Rules = @(); CleaningProfile = 'Low' }
    Assert-Throws 'foreign context cannot be switched' { Set-SjcCleaningProfile -Context $foreign -CleaningProfile 'High' } '可信上下文'

    [void](Save-Evidence 'profile-context' ([pscustomobject]@{
        DefaultProfile = $defaultContext.CleaningProfile
        Profiles = @($profiles | ForEach-Object { [string]$_.Id })
        HighRuleIds = @($afterRules | ForEach-Object Id)
        InvalidatedMarker = [IO.File]::Exists((Join-Path $scanTask 'profile.invalidated'))
        InvalidatedCleanStatus = $invalidatedClean.Status
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
