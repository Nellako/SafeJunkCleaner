#requires -Version 5.1
# N03: profile sealing and re-scan enforcement - scan metadata must carry
# CleaningProfile+PolicyRevision, a plan is refused under a different profile, the
# invalidated marker survives switching back, preview sessions are epoch-bound, and a
# clean takes its profile exclusively from the trusted context (never from the payload).
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
    # One file in each age band so Recommended and Deep produce different candidate sets.
    New-TestFile -Path (Join-Path $files 'age10h.tmp') -Bytes 10 -AgeHours 10 | Out-Null
    New-TestFile -Path (Join-Path $files 'age30h.tmp') -Bytes 30 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $files 'age60h.tmp') -Bytes 60 -AgeHours 60 | Out-Null

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'Recommended scan succeeds' 'Success' $scan.Status $scan.Error
    Assert-Equal 'Recommended scan seals its profile in the result' 'Recommended' ([string]$scan.CleaningProfile)
    Assert-Equal 'Recommended 24h rule sees only the 30h and 60h files' 'age30h.tmp|age60h.tmp' ((@(Get-CandidateLines $scan.PlanPath | ForEach-Object { [IO.Path]::GetFileName($_.Path) }) | Sort-Object) -join '|')
    $recommendedCategory = @($scan.Categories)[0]
    Assert-Equal 'category carries the sealing profile' 'Recommended' ([string]$recommendedCategory.CleaningProfile)
    Assert-Equal 'category carries the effective minimum age' 24 ([double]$recommendedCategory.MinimumAgeHours)

    # Sealed metadata must contain both new mandatory fields (decode the DPAPI seal).
    $metaPath = Join-Path $task 'scan.meta.json'
    $meta = Unprotect-SjcText (Read-SjcSafeText $metaPath) | ConvertFrom-Json
    Assert-Equal 'sealed metadata records CleaningProfile' 'Recommended' ([string]$meta.CleaningProfile)
    Assert-Equal 'sealed metadata records PolicyRevision 1' 1 ([int]$meta.PolicyRevision)
    Assert-True 'sealed metadata records the profile epoch' ($null -ne $meta.PSObject.Properties['ProfileEpoch']) ([string]$meta.ProfileEpoch)
    $sealedRule = @($meta.Rules)[0] | ConvertFrom-Json
    Assert-Equal 'each sealed rule pins its own profile' 'Recommended' ([string]$sealedRule.CleaningProfile)
    Assert-True 'each sealed rule pins both profile ages' ($sealedRule.RecommendedMinimumAgeHours -gt 0 -and $sealedRule.DeepMinimumAgeHours -gt 0) ([string]$sealedRule.RecommendedMinimumAgeHours + '/' + [string]$sealedRule.DeepMinimumAgeHours)

    # A plan opened under the other profile must be refused before any destructive step.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Deep')
    Assert-Throws 'sealed Recommended plan is refused under Deep' { Open-SjcPlan -Context $context -TaskDirectory $task } '档位已变化|失效|重新扫描'
    Assert-Throws 'candidate paging is refused across profiles' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 10 } '档位|失效|重新扫描'
    Assert-Throws 'preview session is refused across profiles' { Open-SjcPreviewSession -PlanPath $scan.PlanPath } '档位|失效|重新扫描'
    Assert-Throws 'export is refused across profiles' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'cross-profile.csv') } '档位|失效|重新扫描'

    $crossClean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    Assert-True 'clean across profiles fails closed' ($crossClean.Status -eq 'Failed' -and [int64]$crossClean.Deleted -eq 0) ('status=' + $crossClean.Status + '; deleted=' + $crossClean.Deleted + '; error=' + $crossClean.Error)
    Assert-Equal 'cross-profile clean removed no file at all' 3 ([IO.Directory]::GetFiles($files).Count) ''
    Assert-True 'cross-profile refusal names profile/rescan' ([string]$crossClean.Error -match '档位|重新扫描') ([string]$crossClean.Error)
    Assert-True 'profile.invalidated denial marker is written for the old task' ([IO.File]::Exists((Join-Path $task 'profile.invalidated'))) ''

    # Switching back must NOT resurrect the old plan: the denial marker is one-way.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Recommended')
    Assert-Throws 'switching back to Recommended still refuses the old plan' { Open-SjcPlan -Context $context -TaskDirectory $task } '档位|失效|重新扫描'
    $reopenedClean = Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
    Assert-True 'switching back still blocks cleaning the invalidated plan' ($reopenedClean.Status -eq 'Failed' -and [int64]$reopenedClean.Deleted -eq 0) ('status=' + $reopenedClean.Status + '; deleted=' + $reopenedClean.Deleted)

    # A fresh scan under Deep must apply the Deep threshold (6h for the sandbox temp rule families).
    $deepTask = New-SjcTaskDirectory -Context $context
    $deepScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $deepTask
    Assert-Equal 'Deep rescann succeeds' 'Success' $deepScan.Status $deepScan.Error
    Assert-Equal 'Deep scan records its profile' 'Recommended' ([string]$deepScan.CleaningProfile)
    $deepTask2 = New-SjcTaskDirectory -Context $context
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Deep')
    $deepScan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $deepTask2
    Assert-Equal 'explicit Deep scan succeeds' 'Success' $deepScan2.Status $deepScan2.Error
    Assert-Equal 'Deep scan records Deep' 'Deep' ([string]$deepScan2.CleaningProfile)
    Assert-Equal 'Deep category reports Deep' 'Deep' ([string](@($deepScan2.Categories)[0].CleaningProfile))

    # A clean under the same Deep context succeeds against its own plan.
    $deepClean = Invoke-SjcClean -Context $context -TaskDirectory $deepTask2 -RecycleMode $false
    Assert-True 'same-profile clean succeeds' ($deepClean.Status -in @('Success', 'Partial')) ('status=' + $deepClean.Status + '; error=' + $deepClean.Error)

    # Restore Recommended for the remaining assertions.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Recommended')

    # Legacy metadata without the new fields must be refused as a stale plan.
    $legacyTask = New-SjcTaskDirectory -Context $context
    $legacySource = Join-Path $files 'legacy60h.tmp'
    New-TestFile -Path $legacySource -Bytes 60 -AgeHours 60 | Out-Null
    $legacyScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $legacyTask
    Assert-Equal 'legacy-fixture scan succeeds' 'Success' $legacyScan.Status $legacyScan.Error
    $legacyMetaPath = Join-Path $legacyTask 'scan.meta.json'
    $legacyMeta = Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath) | ConvertFrom-Json
    $legacyMeta.PSObject.Properties.Remove('CleaningProfile')
    Write-SjcAtomicText $legacyMetaPath (Protect-SjcText ($legacyMeta | ConvertTo-Json -Depth 8 -Compress))
    Assert-Throws 'metadata without CleaningProfile is refused' { Open-SjcPlan -Context $context -TaskDirectory $legacyTask } '旧计划|档位'

    $legacyTask2 = New-SjcTaskDirectory -Context $context
    $legacyScan2 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $legacyTask2
    Assert-Equal 'second legacy-fixture scan succeeds' 'Success' $legacyScan2.Status $legacyScan2.Error
    $legacyMetaPath2 = Join-Path $legacyTask2 'scan.meta.json'
    $legacyMeta2 = Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath2) | ConvertFrom-Json
    $legacyMeta2.PSObject.Properties.Remove('PolicyRevision')
    Write-SjcAtomicText $legacyMetaPath2 (Protect-SjcText ($legacyMeta2 | ConvertTo-Json -Depth 8 -Compress))
    Assert-Throws 'metadata without PolicyRevision is refused' { Open-SjcPlan -Context $context -TaskDirectory $legacyTask2 } '旧计划|档位'

    $legacyTask3 = New-SjcTaskDirectory -Context $context
    $legacyScan3 = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $legacyTask3
    Assert-Equal 'third legacy-fixture scan succeeds' 'Success' $legacyScan3.Status $legacyScan3.Error
    $legacyMetaPath3 = Join-Path $legacyTask3 'scan.meta.json'
    $legacyMeta3 = Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath3) | ConvertFrom-Json
    $legacyMeta3.CleaningProfile = 'deep'
    Write-SjcAtomicText $legacyMetaPath3 (Protect-SjcText ($legacyMeta3 | ConvertTo-Json -Depth 8 -Compress))
    Assert-Throws 'sealed metadata with a non-contract profile value is refused' { Open-SjcPlan -Context $context -TaskDirectory $legacyTask3 } 'Recommended 或 Deep'

    # Preview sessions captured under one profile must die when the profile changes.
    $sessionTask = New-SjcTaskDirectory -Context $context
    $sessionScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $sessionTask
    Assert-Equal 'session-fixture scan succeeds' 'Success' $sessionScan.Status $sessionScan.Error
    $session = Open-SjcPreviewSession -PlanPath $sessionScan.PlanPath
    $firstPage = @(Get-SjcPreviewPage $session -Limit 10)
    Assert-True 'preview page works before the switch' ($firstPage.Count -ge 1) ([string]$firstPage.Count)
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Deep')
    Assert-Throws 'existing preview session is refused after a profile switch' { Get-SjcPreviewPage $session -Limit 10 } '档位已变化|重新扫描'
    Assert-Throws 'rule index is refused after a profile switch' { Get-SjcPreviewRuleCandidates $session 'SandboxOld' } '档位已变化|重新扫描'
    Close-SjcPreviewSession $session; $session = $null
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Recommended')

    [void](Save-Evidence 'profile-sealing' ([pscustomobject]@{
        SealedMetaProfile = $meta.CleaningProfile
        PolicyRevision = $meta.PolicyRevision
        RecommendedCandidates = @(Get-CandidateLines $scan.PlanPath).Count
        CrossProfileCleanStatus = $crossClean.Status
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
