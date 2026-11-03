#requires -Version 5.1
# Auxiliary v0.12 contract probe (not a release acceptance).
# Verifies: Medium default, exact-case Low/Medium/High, frozen Recommended/Deep refusal,
# sealed scan metadata (PolicyRevision 3, legacy 2 refused + CustomEnabled + PresetLevel + three tier ages),
# plan invalidation on switch and on same-tier -Invalidate, preset exact-set enforcement,
# v4 preferences (four fields, normalized preset, CustomEnabled forced false) and v3
# migration to Low with the legacy file preserved, plus the Worker payload bool profile.
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId 'ProfileContract' -ResultPath (Join-Path $EvidenceDirectory 'profile-contract.json') -EvidenceDirectory $EvidenceDirectory
$sandbox=New-OwnedSandbox;$context=$sandbox.Context
Assert-Equal 'new context defaults to Medium' 'Medium' $context.CleaningProfile
foreach($bad in @('Recommended','Deep','medium','MEDIUM','Medium ','HighX','','Max')) {
    $value=$bad
    Assert-Throws ('reject invalid profile "' + $value + '"') { Set-SjcCleaningProfile -Context $context -CleaningProfile $value } 'Low、Medium 或 High'
}
Assert-Equal 'rejected switches leave the tier unchanged' 'Medium' $context.CleaningProfile

# Sealed scan metadata: tier, PolicyRevision, custom mode, PresetLevel and all tier ages.
$task=New-SjcTaskDirectory $context
[void](New-TestFile -Path (Join-Path $sandbox.Root 'files\owned-old.tmp') -AgeHours 120)
$scan=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @('SandboxOld') -CustomEnabled $true
Assert-Equal 'scan success' 'Success' $scan.Status $scan.Error
Assert-Equal 'scan seals Medium' 'Medium' ([string]$scan.CleaningProfile)
Assert-Equal 'scan seals custom mode' 'True' ([string]$scan.CustomEnabled)
$meta=Unprotect-SjcText (Read-SjcSafeText (Join-Path $task 'scan.meta.json'))|ConvertFrom-Json
Assert-Equal 'sealed PolicyRevision 3' 3 ([int]$meta.PolicyRevision)
Assert-Equal 'sealed profile' 'Medium' ([string]$meta.CleaningProfile)
Assert-True 'sealed CustomEnabled is an explicit boolean true' ($meta.PSObject.Properties['CustomEnabled'] -and $meta.CustomEnabled -is [bool] -and $meta.CustomEnabled) ([string]$meta.CustomEnabled)
Assert-Equal 'sealed RuleIds equal the scanned selection' 'SandboxOld' (@($meta.RuleIds) -join ',')
$snapshot=$meta.Rules[0]|ConvertFrom-Json
Assert-Equal 'sealed rule preset level' 'Low' ([string]$snapshot.PresetLevel)
Assert-Equal 'sealed actual threshold' 24 ([double]$snapshot.MinimumAgeHours)
Assert-Equal 'sealed low threshold' 24 ([double]$snapshot.LowMinimumAgeHours)
Assert-Equal 'sealed medium threshold' 24 ([double]$snapshot.MediumMinimumAgeHours)
Assert-Equal 'sealed high threshold' 24 ([double]$snapshot.HighMinimumAgeHours)

# A valid seal with the old policy revision must not be accepted as a current plan.
$legacyTask=New-SjcTaskDirectory $context
$legacyScan=Invoke-SjcScan -Context $context -TaskDirectory $legacyTask -RuleIds @('SandboxOld') -CustomEnabled $true
Assert-Equal 'legacy revision fixture scan succeeds' 'Success' $legacyScan.Status $legacyScan.Error
$legacyMetaPath=Join-Path $legacyTask 'scan.meta.json'
$legacyMeta=Unprotect-SjcText (Read-SjcSafeText $legacyMetaPath)|ConvertFrom-Json
$legacyMeta.PolicyRevision=2
Write-SjcAtomicText $legacyMetaPath (Protect-SjcText ($legacyMeta|ConvertTo-Json -Depth 8 -Compress))
Assert-Throws 'sealed PolicyRevision 2 is refused' { Open-SjcPlan -Context $context -TaskDirectory $legacyTask } '旧计划|策略|重新扫描'

# Preset scans must carry the exact tier member set; a subset is refused before sealing.
$preset=@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Medium')
Assert-Equal 'sandbox Medium preset is exactly both synthetic rules' 'SandboxLog,SandboxOld' (@($preset|Sort-Object) -join ',')
$presetTask=New-SjcTaskDirectory $context
$presetScan=Invoke-SjcScan -Context $context -TaskDirectory $presetTask -RuleIds $preset -CustomEnabled $false
Assert-Equal 'exact preset scan succeeds' 'Success' $presetScan.Status $presetScan.Error
Assert-Equal 'preset scan seals CustomEnabled false' 'False' ([string]$presetScan.CustomEnabled)
$missingTask=New-SjcTaskDirectory $context
$missingScan=Invoke-SjcScan -Context $context -TaskDirectory $missingTask -RuleIds @('SandboxOld') -CustomEnabled $false
Assert-Equal 'preset scan with a missing member fails' 'Failed' $missingScan.Status
Assert-True 'missing-member refusal names the preset set' ([string]$missingScan.Error -match '预设规则集合') ([string]$missingScan.Error)
Assert-True 'rejected preset scan writes no sealed plan' (-not [IO.File]::Exists((Join-Path $missingTask 'scan.meta.json'))) ''

# A tier switch invalidates the open preview session and the sealed plan, one-way.
$session=Open-SjcPreviewSession $scan.PlanPath
Set-SjcCleaningProfile -Context $context -CleaningProfile 'High'
Assert-Equal 'high context' 'High' ([string]$context.CleaningProfile)
Assert-Throws 'session invalid after profile switch' { Get-SjcPreviewPage $session -Limit 10 } '档位|失效|重新扫描'
Close-SjcPreviewSession $session
$clean=Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false -CustomEnabled $true
Assert-Equal 'old profile plan rejected' 'Failed' ([string]$clean.Status)
Assert-Equal 'no deletion for stale profile' 0 ([int64]$clean.Deleted)
Assert-True 'invalidated marker written' ([IO.File]::Exists((Join-Path $task 'profile.invalidated'))) ''
Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium'
Assert-Throws 'switch back does not revive plan' { Open-SjcPreviewSession $scan.PlanPath } '档位|失效|重新扫描'

# Same-tier -Invalidate must also deny earlier plans without switching the tier.
$reTask=New-SjcTaskDirectory $context
$reScan=Invoke-SjcScan -Context $context -TaskDirectory $reTask -RuleIds @('SandboxOld') -CustomEnabled $true
Assert-Equal 'rescan before same-tier invalidation succeeds' 'Success' $reScan.Status $reScan.Error
$epochBefore=(Get-SjcContextConfiguration $context).ProfileEpoch
Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium' -Invalidate
Assert-True 'same-tier -Invalidate advances the profile epoch' ((Get-SjcContextConfiguration $context).ProfileEpoch -gt $epochBefore) ('before=' + $epochBefore + '; after=' + (Get-SjcContextConfiguration $context).ProfileEpoch)
Assert-True 'same-tier -Invalidate writes the denial marker' ([IO.File]::Exists((Join-Path $reTask 'profile.invalidated'))) ''
$reClean=Invoke-SjcClean -Context $context -TaskDirectory $reTask -RecycleMode $false -CustomEnabled $true
Assert-True 'same-tier -Invalidate blocks the old plan with zero deletions' ($reClean.Status -eq 'Failed' -and [int64]$reClean.Deleted -eq 0) ('status=' + $reClean.Status + '; deleted=' + $reClean.Deleted)

# Preferences v4: exactly four fields, tier preset normalization, CustomEnabled forced false.
$prefPath=Join-Path $context.StateRoot 'preferences-v4.json'
$legacyPath=Join-Path $context.StateRoot 'preferences-v3.json'
$preferences=[pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='High';CustomEnabled=$true}
[void](Save-SjcPreferences $context $preferences)
$stored=Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8|ConvertFrom-Json
Assert-Equal 'preferences v4 stores exactly four fields' 'CleaningProfile,CustomEnabled,RecycleMode,SelectedRuleIds' (@($stored.PSObject.Properties.Name|Sort-Object) -join ',')
Assert-Equal 'preferences round-trip High' 'High' ([string](Read-SjcPreferences $context).CleaningProfile)
Assert-True 'saved CustomEnabled is forced false' ($stored.CustomEnabled -eq $false) ([string]$stored.CustomEnabled)
Assert-Equal 'saved selection is normalized to the High preset' ((@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'High')|Sort-Object) -join ',') (@($stored.SelectedRuleIds|Sort-Object) -join ',')
Assert-Throws 'preferences with an unknown field are rejected' { Save-SjcPreferences $context ([pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='High';CustomEnabled=$false;Root='C:\'}) } '未知字段'
Assert-Throws 'preferences with the frozen Recommended tier are rejected' { Save-SjcPreferences $context ([pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='Recommended';CustomEnabled=$false}) } 'Low、Medium 或 High'
Assert-Throws 'preferences with a non-boolean CustomEnabled are rejected' { Save-SjcPreferences $context ([pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='Low';CustomEnabled='false'}) } 'CustomEnabled'

# v3 migration: Low tier, CustomEnabled=false, non-empty notice, legacy bytes untouched.
Remove-Item -LiteralPath $prefPath -Force
[IO.File]::WriteAllText($legacyPath,'{"CleaningProfile":"Deep","RecycleMode":true,"SelectedRuleIds":["SandboxOld"]}',(New-Object Text.UTF8Encoding($false)))
$legacyBytes=[IO.File]::ReadAllBytes($legacyPath)
$migrated=Read-SjcPreferences $context
Assert-Equal 'v3 Deep migrates to Low' 'Low' ([string]$migrated.CleaningProfile)
Assert-True 'v3 migration keeps CustomEnabled false' ($migrated.CustomEnabled -eq $false) ([string]$migrated.CustomEnabled)
Assert-True 'v3 migration reports a notice' (-not [string]::IsNullOrWhiteSpace([string]$migrated.MigrationNotice)) ([string]$migrated.MigrationNotice)
Assert-Equal 'v3 migration selects the Low preset' ((@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Low')|Sort-Object) -join ',') (@($migrated.SelectedRuleIds|Sort-Object) -join ',')
Assert-True 'v3 file is preserved byte-for-byte' (@(Compare-Object ([byte[]]$legacyBytes) ([IO.File]::ReadAllBytes($legacyPath)) -SyncWindow 0).Count -eq 0) 'v3 bytes changed'
Remove-Item -LiteralPath $legacyPath -Force

# Worker payload: profile must be an exact-case string and CustomEnabled an explicit bool.
$deepTask=New-SjcTaskDirectory $context
Set-SjcCleaningProfile -Context $context -CleaningProfile 'High'
$deepScan=Invoke-SjcScan -Context $context -TaskDirectory $deepTask -RuleIds @('SandboxOld') -CustomEnabled $true
Assert-Equal 'High scan succeeds' 'Success' $deepScan.Status $deepScan.Error
$payload=[pscustomobject]@{TaskDirectory=$deepTask;CancelPath='';ProgressPath='';RuleIds=@('SandboxOld');CleaningProfile='High';CustomEnabled=$true}
$payloadOk=$true
try { Assert-SjcWorkerPayload $payload 'Scan' } catch { $payloadOk=('unexpected: ' + $_.Exception.Message) }
Assert-True 'worker valid profile payload accepted' ($payloadOk -is [bool] -and $payloadOk) ([string]$payloadOk)
$payload.CleaningProfile=@('High')
Assert-Throws 'worker array profile rejected' { Assert-SjcWorkerPayload $payload 'Scan' } 'Low、Medium 或 High'
$payload.CleaningProfile='high'
Assert-Throws 'worker lower case profile rejected' { Assert-SjcWorkerPayload $payload 'Scan' } 'Low、Medium 或 High'
$payload.CleaningProfile='Recommended'
Assert-Throws 'worker frozen Recommended profile rejected' { Assert-SjcWorkerPayload $payload 'Scan' } 'Low、Medium 或 High'
$payload.CleaningProfile='High'
$payload.PSObject.Properties.Remove('CustomEnabled')
Assert-Throws 'worker missing CustomEnabled rejected' { Assert-SjcWorkerPayload $payload 'Scan' } 'CustomEnabled'
$payload | Add-Member -NotePropertyName CustomEnabled -NotePropertyValue 'true'
Assert-Throws 'worker string CustomEnabled rejected' { Assert-SjcWorkerPayload $payload 'Scan' } 'CustomEnabled'
$payload.CustomEnabled=$true
Assert-SjcWorkerPayload $payload 'Scan'
Assert-True 'worker payload valid again after the boolean is restored' $true

$clean=Invoke-SjcClean -Context $context -TaskDirectory $deepTask -RecycleMode $false -CustomEnabled $true
Assert-Equal 'matching High plan clean' 'Success' $clean.Status $clean.Error
Assert-Equal 'only owned synthetic deletion' 1 ([int64]$clean.Deleted)
$policy=@(Get-SjcRules $context)
Assert-True 'Low and Medium ages remain positive on every rule' (@($policy|Where-Object{$_.LowMinimumAgeHours -le 0 -or $_.MediumMinimumAgeHours -le 0 -or [double]::IsNaN([double]$_.LowMinimumAgeHours) -or [double]::IsInfinity([double]$_.LowMinimumAgeHours) -or [double]::IsNaN([double]$_.MediumMinimumAgeHours) -or [double]::IsInfinity([double]$_.MediumMinimumAgeHours)}).Count -eq 0) ''
Assert-True 'only allowlisted PureCache templates may have a zero High age' (@($policy|Where-Object{
    $age=[double]$_.HighMinimumAgeHours
    $pureCache=(Get-SjcTemplateAgePolicy $_.TemplateId) -ceq 'PureCache' -and $_.AgePolicy -ceq 'PureCache'
    [double]::IsNaN($age) -or [double]::IsInfinity($age) -or $age -lt 0 -or ($age -eq 0 -and -not $pureCache)
}).Count -eq 0) ''
Assert-True 'every rule pins a PresetLevel' (@($policy|Where-Object{[string]$_.PresetLevel -notin @('Low','Medium','High','CustomOnly')}).Count -eq 0) ''
$probe=New-SjcRule -Id 'Probe' -TemplateId 'Probe' -Name 'probe' -Group 'test' -Root (Join-Path $sandbox.Root 'files') -OverrideEnvironment @('SJC_TEST_CACHE_OVERRIDE')
$previous=[Environment]::GetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE')
try{[Environment]::SetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE','C:\untrusted');Assert-True 'configuration override refuses default rule' (-not(Test-SjcRuleConfiguration $probe));Assert-True 'configuration override not confused with process' (Test-SjcProcessesClosed $probe)}finally{[Environment]::SetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE',$previous)}
[void](Save-Evidence 'checks' $script:Checks.ToArray())
$failed=@($script:Checks|Where-Object{-not $_.Passed})
Write-Output ('PROFILE CHECKS '+$script:Checks.Count+' failed='+$failed.Count)
if($failed.Count){$failed|Format-Table -AutoSize}
# Complete-TestCase writes the result JSON and removes this run's owned GUID sandboxes.
Complete-TestCase
