#requires -Version 5.1
# N01: cleaning profile context contract - Recommended/Deep construction, exact-case
# validation, direct field assignment refusal, rule table rebuild on switch, and the
# documented Deep thresholds applied to effective MinimumAgeHours.
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

    # Default profile for a context created without an explicit profile.
    $defaultContext = New-SjcContext -TestRoot $root
    Assert-Equal 'context defaults to Recommended' 'Recommended' ([string]$defaultContext.CleaningProfile)
    Assert-Equal 'default context rules carry the Recommended profile' 'Recommended' ([string](@(Get-SjcRules -Context $defaultContext)[0].CleaningProfile))

    # Explicit construction of both profiles.
    $deepContext = New-SjcContext -TestRoot $root -CleaningProfile 'Deep'
    Assert-Equal 'explicit Deep context is accepted' 'Deep' ([string]$deepContext.CleaningProfile)
    $deepRules = @(Get-SjcRules -Context $deepContext)
    Assert-True 'every Deep rule instance reports Deep' (@($deepRules | Where-Object { $_.CleaningProfile -cne 'Deep' }).Count -eq 0) (($deepRules | ForEach-Object { $_.Id + '=' + $_.CleaningProfile }) -join ',')

    # Exact-case and unknown values are refused at construction.
    $badProfiles = @('deep', 'DEEP', 'Recommended ', 'Deepest', '', 'RecommendedX')
    foreach ($bad in $badProfiles) {
        $value = $bad
        Assert-Throws ('New-SjcContext rejects profile "' + $value + '"') { New-SjcContext -TestRoot $root -CleaningProfile $value } 'Recommended 或 Deep'
    }
    Assert-Throws 'New-SjcContext rejects a non-string profile' { New-SjcContext -TestRoot $root -CleaningProfile 1 } 'Recommended 或 Deep'

    # Set-SjcCleaningProfile returns nothing and replaces the rule table.
    $context = New-SjcContext -TestRoot $root -CleaningProfile 'Recommended'
    $beforeIds = @(Get-SjcRules -Context $context | ForEach-Object Id)
    $beforeRecommended = @{}
    foreach ($rule in @(Get-SjcRules -Context $context)) { $beforeRecommended[$rule.Id] = [double]$rule.RecommendedMinimumAgeHours }
    $returnValue = Set-SjcCleaningProfile -Context $context -CleaningProfile 'Deep'
    Assert-True 'Set-SjcCleaningProfile returns no value' ($null -eq $returnValue) ([string]$returnValue)
    Assert-Equal 'context reflects the new profile' 'Deep' ([string]$context.CleaningProfile)
    $afterRules = @($context.Rules)
    Assert-True 'switching rebuilds Context.Rules' ($afterRules.Count -gt 0 -and @($afterRules | Where-Object { $_.CleaningProfile -cne 'Deep' }).Count -eq 0) ('rules=' + $afterRules.Count)
    Assert-Equal 'switching does not add or remove rule ids' (($beforeIds | Sort-Object) -join '|') ((@($afterRules | ForEach-Object Id) | Sort-Object) -join '|')
    # Sandbox templates keep Deep == Recommended (no sandbox-specific Deep floors).
    $sandboxDeep = @($afterRules | Where-Object { [double]$_.DeepMinimumAgeHours -ne [double]$_.RecommendedMinimumAgeHours })
    Assert-Equal 'sandbox templates keep the Deep floor equal to Recommended' 0 $sandboxDeep.Count (($sandboxDeep | ForEach-Object { $_.Id + ':' + $_.MinimumAgeHours + '/' + $_.RecommendedMinimumAgeHours }) -join ',')

    # Documented production Deep thresholds are checked on the production template table.
    # This reads fixed rule definitions only; it never scans a user cache directory.
    $production = New-ProductionContextForInventory
    $recommendedAges = @{}
    foreach ($rule in @(Get-SjcRules -Context $production)) { $recommendedAges[$rule.Id] = [double]$rule.RecommendedMinimumAgeHours }
    [void](Set-SjcCleaningProfile -Context $production -CleaningProfile 'Deep')
    $productionDeep = @(Get-SjcRules -Context $production)
    $deepExpected = @{ UserTemp = 6; WindowsTemp = 24; GradleCache = 168; CrashDumps = 720; WERArchive = 720; D3DSCache = 168; NvidiaDXCache = 168; NvidiaGLCache = 168; AmdDxCache = 168; AmdDxcCache = 168; IntelShaderCache = 168 }
    $ageErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $deepExpected.Keys) {
        $rule = @($productionDeep | Where-Object { $_.Id -ceq $id } | Select-Object -First 1)
        if ($rule.Count -eq 0) { $ageErrors.Add($id + ':missing'); continue }
        $one = $rule[0]
        if ([double]$one.MinimumAgeHours -ne [double]$deepExpected[$id]) { $ageErrors.Add($id + '=' + $one.MinimumAgeHours + ' expected ' + $deepExpected[$id]) }
        if ([double]$one.RecommendedMinimumAgeHours -ne $recommendedAges[$id]) { $ageErrors.Add($id + ':recommended-age-mutated') }
    }
    Assert-True 'production Deep applies documented effective ages and preserves RecommendedMinimumAgeHours' ($ageErrors.Count -eq 0) ($ageErrors -join '; ')
    $browserDeep = @($productionDeep | Where-Object { $_.Group -ceq '浏览器缓存' -and [double]$_.MinimumAgeHours -ne 1 })
    Assert-Equal 'production browser caches use the documented 1h Deep floor' 0 $browserDeep.Count (($browserDeep | ForEach-Object { $_.Id + '=' + $_.MinimumAgeHours }) -join ',')
    Add-Limitation 'N01 仅在内存中切换生产上下文档位以核对规则阈值；未扫描生产缓存、未写生产首选项。'
    [void](Set-SjcCleaningProfile -Context $production -CleaningProfile 'Recommended')

    # Switching back restores the recommended ages.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Recommended')
    $backRules = @(Get-SjcRules -Context $context)
    $backMismatch = @($backRules | Where-Object { [double]$_.MinimumAgeHours -ne [double]$_.RecommendedMinimumAgeHours })
    Assert-True 'switching back restores RecommendedMinimumAgeHours as the effective age' ($backMismatch.Count -eq 0) (($backMismatch | ForEach-Object { $_.Id + '=' + $_.MinimumAgeHours + '/' + $_.RecommendedMinimumAgeHours }) -join ',')

    # Idempotent switch is a no-op (same profile must not throw or duplicate rules).
    $countBefore = @(Get-SjcRules -Context $context).Count
    $noop = Set-SjcCleaningProfile -Context $context -CleaningProfile 'Recommended'
    Assert-True 'repeating the current profile is a silent no-op' ($null -eq $noop -and @(Get-SjcRules -Context $context).Count -eq $countBefore) ([string]$noop)

    # Direct assignment to Context.CleaningProfile must be refused by the trust check.
    # The tamper guard is fail-closed: the poisoned context stays untrusted and cannot be
    # "repaired" by calling the setter, so a fresh context is used for later steps.
    $tampered = New-SjcContext -TestRoot $root -CleaningProfile 'Recommended'
    $tampered.CleaningProfile = 'Deep'
    Assert-Throws 'direct Context.CleaningProfile assignment is refused' { Get-SjcContextConfiguration $tampered } 'Set-SjcCleaningProfile'
    Assert-Throws 'trusted calls also refuse a tampered context field' { Get-SjcRules -Context $tampered } 'Set-SjcCleaningProfile'
    Assert-Throws 'the setter cannot silently repair a tampered context' { Set-SjcCleaningProfile -Context $tampered -CleaningProfile 'Recommended' } 'Set-SjcCleaningProfile'
    Assert-Equal 'tampered context is not trust-laundered back to a valid profile' 'Deep' ([string]$tampered.CleaningProfile)

    # Supported setter still works on an untampered context, with no return value.
    $freshContext = New-SjcContext -TestRoot $root -CleaningProfile 'Recommended'
    $setterReturn = Set-SjcCleaningProfile -Context $freshContext -CleaningProfile 'Deep'
    Assert-True 'setter on an untampered context returns no value' ($null -eq $setterReturn) ([string]$setterReturn)
    Assert-Equal 'setter on an untampered context applies Deep' 'Deep' ([string]$freshContext.CleaningProfile)

    # Invalid values are refused by the setter too, and leave the context untouched.
    foreach ($bad in @('deep', '', 'Deepest')) {
        $value = $bad
        Assert-Throws ('Set-SjcCleaningProfile rejects "' + $value + '"') { Set-SjcCleaningProfile -Context $context -CleaningProfile $value } 'Recommended 或 Deep'
    }
    Assert-Equal 'rejected switches leave the profile unchanged' 'Recommended' ([string]$context.CleaningProfile)

    # A context that this process did not create must never be trusted.
    $foreign = [pscustomobject]@{ Version = (Get-SjcVersion); StateRoot = $root; Rules = @(); CleaningProfile = 'Recommended' }
    Assert-Throws 'foreign context cannot be switched' { Set-SjcCleaningProfile -Context $foreign -CleaningProfile 'Deep' } '可信上下文'

    [void](Save-Evidence 'profile-context' ([pscustomobject]@{
        DefaultProfile = $defaultContext.CleaningProfile
        DeepRuleCount = $deepRules.Count
        DeepAges = @($afterRules | Select-Object Id, RecommendedMinimumAgeHours, DeepMinimumAgeHours, MinimumAgeHours)
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
