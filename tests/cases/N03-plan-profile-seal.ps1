#requires -Version 5.1
# N03: plan sealing and re-scan enforcement - scan metadata must carry
# CleaningProfile + CustomEnabled + RuleIds + PolicyRevision 3 (+ the per-tier rule ages),
# a plan is refused under a different tier, the invalidated marker survives switching
# back, preview sessions are epoch-bound, and a clean takes its mode from the sealed plan
# and its tier from the trusted context (never from the payload).
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$session = $null
try {
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    # One file in each age band so Low and High produce different candidate sets.
    New-TestFile -Path (Join-Path $files 'age10h.tmp') -Bytes 10 -AgeHours 10 | Out-Null
    New-TestFile -Path (Join-Path $files 'age30h.tmp') -Bytes 30 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'age60h.tmp') -Bytes 60 -AgeHours 60 | Out-Null

    # Medium context (default). SandboxOld keeps 24h at Low/Medium/High, so of the three
    # fixtures only the 30h and 60h files qualify; the assertion below is about sealing.
    $task = New-SjcTaskDirectory -Context $context
    $presetIds = @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Medium')
    $scan = Invoke-SjcScan -Context $context -RuleIds $presetIds -TaskDirectory $task -CustomEnabled $false
    Assert-Equal 'Medium preset scan succeeds' 'Success' $scan.Status $scan.Error
    Assert-Equal 'scan seals its tier in the result' 'Medium' ([string]$scan.CleaningProfile)
    Assert-True 'scan seals CustomEnabled=false for a preset scan' ($scan.CustomEnabled -eq $false) ([string]$scan.CustomEnabled)
    Assert-Equal 'Medium preset scan honours the 24h floor' 'age30h.tmp|age60h.tmp' ((@(Get-CandidateLines $scan.PlanPath | ForEach-Object { [IO.Path]::GetFileName($_.Path) }) | Sort-Object) -join '|')
    $mediumCategories = @($scan.Categories)
    Assert-Equal 'one category per preset rule' $presetIds.Count $mediumCategories.Count
    Assert-True 'every category carries the sealing tier' (@($mediumCategories | Where-Object { $_.CleaningProfile -cne 'Medium' }).Count -eq 0) (($mediumCategories | ForEach-Object { $_.RuleId + '=' + $_.CleaningProfile }) -join ',')
    $oldCat = @($mediumCategories | Where-Object { $_.RuleId -ceq 'SandboxOld' })[0]
    Assert-Equal 'SandboxOld category carries the Medium effective age' 24 ([double]$oldCat.MinimumAgeHours)

    # Sealed metadata must contain the new policy fields (decode the DPAPI seal).
    $metaPath = Join-Path $task 'scan.meta.json'
    $meta = Unprotect-SjcText (Read-SjcSafeText $metaPath) | ConvertFrom-Json
    Assert-Equal 'sealed metadata records the tier' 'Medium' ([string]$meta.CleaningProfile)
    Assert-Equal 'sealed metadata records PolicyRevision 3' 3 ([int]$meta.PolicyRevision)
    Assert-True 'sealed metadata records CustomEnabled=false' ($meta.PSObject.Properties['CustomEnabled'] -and $meta.CustomEnabled -eq $false) ([string]$meta.CustomEnabled)
    Assert-True 'sealed metadata records the profile epoch' ($null -ne $meta.PSObject.Properties['ProfileEpoch']) ([string]$meta.ProfileEpoch)
    Assert-Equal 'sealed metadata RuleIds equal the scanned preset set' ((@($presetIds) | Sort-Object) -join ',') ((@($meta.RuleIds) | Sort-Object) -join ',')
    Assert-Equal 'sealed Rules count equals the scanned rule count' (@($presetIds).Count) (@($meta.Rules).Count)
    $sealedRule = @($meta.Rules | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.Id -ceq 'SandboxOld' })[0]
    Assert-Equal 'each sealed rule pins the active tier' 'Medium' ([string]$sealedRule.CleaningProfile)
    Assert-True 'each sealed rule pins PresetLevel and all three tier ages' ($null -ne $sealedRule.PSObject.Properties['PresetLevel'] -and [double]$sealedRule.LowMinimumAgeHours -gt 0 -and [double]$sealedRule.MediumMinimumAgeHours -gt 0 -and [double]$sealedRule.HighMinimumAgeHours -gt 0) ([string]$sealedRule.PresetLevel)
    Assert-True 'the sealed effective age equals the sealed Medium age' ([double]$sealedRule.MinimumAgeHours -eq [double]$sealedRule.MediumMinimumAgeHours) ([string]$sealedRule.MinimumAgeHours + '/' + [string]$sealedRule.MediumMinimumAgeHours)

    # A plan opened under another tier must be refused before any destructive step.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'High')
    Assert-Throws 'sealed Medium plan is refused under High' { Open-SjcPlan -Context $context -TaskDirectory $task } '档位已变化|失效|重新扫描'
    Assert-Throws 'candidate paging is refused across tiers' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 10 } '档位|失效|重新扫描'
    Assert-Throws 'preview session is refused across tiers' { Open-SjcPreviewSession -PlanPath $scan.PlanPath } '档位|失效|重新扫描'
    Assert-Throws 'export is refused across tiers' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'cross-tier.csv') } '档位|失效|重新扫描'

    $crossClean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false -CustomEnabled $false
    Assert-True 'clean across tiers fails closed' ($crossClean.Status -eq 'Failed' -and [int64]$crossClean.Deleted -eq 0) ('status=' + $crossClean.Status + '; deleted=' + $crossClean.Deleted + '; error=' + $crossClean.Error)
    Assert-Equal 'cross-tier clean removed no file at all' 3 ([IO.Directory]::GetFiles($files).Count) ''
    Assert-True 'cross-tier refusal names tier/rescan' ([string]$crossClean.Error -match '档位|重新扫描') ([string]$crossClean.Error)
    Assert-True 'profile.invalidated denial marker is written for the old task' ([IO.File]::Exists((Join-Path $task 'profile.invalidated'))) ''

    # Switching back must NOT resurrect the old plan: the denial marker is one-way.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium')
    Assert-Throws 'switching back to Medium still refuses the old plan' { Open-SjcPlan -Context $context -TaskDirectory $task } '档位|失效|重新扫描'
    $reopenedClean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false -CustomEnabled $false
    Assert-True 'switching back still blocks cleaning the invalidated plan' ($reopenedClean.Status -eq 'Failed' -and [int64]$reopenedClean.Deleted -eq 0) ('status=' + $reopenedClean.Status + '; deleted=' + $reopenedClean.Deleted)

    # A fresh scan under High must seal High and use the High threshold.
    $highTask = New-SjcTaskDirectory -Context $context
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'High')
    $highPreset = @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'High')
    $highScan = Invoke-SjcScan -Context $context -RuleIds $highPreset -TaskDirectory $highTask -CustomEnabled $false
    Assert-Equal 'explicit High scan succeeds' 'Success' $highScan.Status $highScan.Error
    Assert-Equal 'High scan records High' 'High' ([string]$highScan.CleaningProfile)
    $highOldCat = @(@($highScan.Categories) | Where-Object { $_.RuleId -ceq 'SandboxOld' })[0]
    Assert-Equal 'High category reports High' 'High' ([string](@($highScan.Categories)[0].CleaningProfile))
    Assert-Equal 'High category applies the High effective age' 24 ([double]$highOldCat.MinimumAgeHours)

    # Clean must receive the same mode that was sealed.
    $wrongModeClean = Invoke-SjcClean -Context $context -TaskDirectory $highTask -RecycleMode $false -CustomEnabled $true
    Assert-True 'a clean whose mode differs from the sealed mode fails closed' ($wrongModeClean.Status -eq 'Failed' -and [int64]$wrongModeClean.Deleted -eq 0) ('status=' + $wrongModeClean.Status + '; deleted=' + $wrongModeClean.Deleted + '; error=' + $wrongModeClean.Error)
    Assert-True 'mode-mismatch refusal names the custom mode' ([string]$wrongModeClean.Error -match '自定义模式') ([string]$wrongModeClean.Error)

    # A same-mode clean under the same tier succeeds against its own plan.
    $highClean = Invoke-SjcClean -Context $context -TaskDirectory $highTask -RecycleMode $false -CustomEnabled $false
    Assert-True 'same-tier same-mode clean succeeds' ($highClean.Status -in @('Success', 'Partial')) ('status=' + $highClean.Status + '; error=' + $highClean.Error)

    # Legacy metadata without the new fields must be refused as a stale plan.
    $legacyCases = @(
        @{ Name = 'CleaningProfile'; Remove = 'CleaningProfile'; Pattern = '旧计划|档位|策略' },
        @{ Name = 'PolicyRevision'; Remove = 'PolicyRevision'; Pattern = '旧计划|档位|策略' },
        @{ Name = 'CustomEnabled'; Remove = 'CustomEnabled'; Pattern = '旧计划|档位|策略' },
        @{ Name = 'RuleIds'; Remove = 'RuleIds'; Pattern = '旧计划|档位|策略' }
    )
    foreach ($legacyCase in $legacyCases) {
        $legacyTask = New-SjcTaskDirectory -Context $context
        $legacyScan = Invoke-SjcScan -Context $context -RuleIds $highPreset -TaskDirectory $legacyTask -CustomEnabled $false
        Assert-Equal ('legacy-fixture scan without ' + $legacyCase.Name + ' succeeds') 'Success' $legacyScan.Status $legacyScan.Error
        $legacyMetaPath = Join-Path $legacyTask 'scan.meta.json'
        $legacyMeta = Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath) | ConvertFrom-Json
        $legacyMeta.PSObject.Properties.Remove([string]$legacyCase.Remove)
        Write-SjcAtomicText $legacyMetaPath (Protect-SjcText ($legacyMeta | ConvertTo-Json -Depth 8 -Compress))
        $pattern = [string]$legacyCase.Pattern
        $label = 'metadata without ' + $legacyCase.Name + ' is refused'
        Assert-Throws $label { Open-SjcPlan -Context $context -TaskDirectory $legacyTask } $pattern
    }

    $legacyTask3 = New-SjcTaskDirectory -Context $context
    $legacyScan3 = Invoke-SjcScan -Context $context -RuleIds $highPreset -TaskDirectory $legacyTask3 -CustomEnabled $false
    Assert-Equal 'third legacy-fixture scan succeeds' 'Success' $legacyScan3.Status $legacyScan3.Error
    $legacyMetaPath3 = Join-Path $legacyTask3 'scan.meta.json'
    $legacyMeta3 = Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath3) | ConvertFrom-Json
    $legacyMeta3.CleaningProfile = 'Recommended'
    Write-SjcAtomicText $legacyMetaPath3 (Protect-SjcText ($legacyMeta3 | ConvertTo-Json -Depth 8 -Compress))
    Assert-Throws 'sealed metadata with the frozen Recommended value is refused' { Open-SjcPlan -Context $context -TaskDirectory $legacyTask3 } 'Low、Medium 或 High'

    # Preview sessions captured under one tier must die when the tier changes.
    # New fixture: the earlier High clean already removed the first batch.
    New-TestFile -Path (Join-Path $files 'session60h.tmp') -Bytes 60 -AgeHours 60 | Out-Null
    $sessionTask = New-SjcTaskDirectory -Context $context
    $sessionScan = Invoke-SjcScan -Context $context -RuleIds $highPreset -TaskDirectory $sessionTask -CustomEnabled $false
    Assert-Equal 'session-fixture scan succeeds' 'Success' $sessionScan.Status $sessionScan.Error
    Assert-True 'session-fixture scan produced at least one candidate' ([int64]$sessionScan.CandidateCount -ge 1) ([string]$sessionScan.CandidateCount)
    $session = Open-SjcPreviewSession -PlanPath $sessionScan.PlanPath
    $firstPage = @(Get-SjcPreviewPage $session -Limit 10)
    Assert-True 'preview page works before the switch' ($firstPage.Count -ge 1) ([string]$firstPage.Count)
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium')
    Assert-Throws 'existing preview session is refused after a tier switch' { Get-SjcPreviewPage $session -Limit 10 } '档位已变化|重新扫描'
    Assert-Throws 'rule index is refused after a tier switch' { Get-SjcPreviewRuleCandidates $session 'SandboxOld' } '档位已变化|重新扫描'
    Close-SjcPreviewSession $session; $session = $null
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium')

    [void](Save-Evidence 'plan-sealing' ([pscustomobject]@{
        SealedMetaProfile = $meta.CleaningProfile
        PolicyRevision = $meta.PolicyRevision
        SealedCustomEnabled = $meta.CustomEnabled
        SealedRuleIds = @($meta.RuleIds)
        MediumCandidates = @(Get-CandidateLines $scan.PlanPath).Count
        CrossTierCleanStatus = $crossClean.Status
        WrongModeCleanStatus = $wrongModeClean.Status
        InvalidatedMarker = [IO.File]::Exists((Join-Path $task 'profile.invalidated'))
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($session -and -not $session.Closed) { try { Close-SjcPreviewSession $session } catch { } }
}
Complete-TestCase
