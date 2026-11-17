#requires -Version 5.1
# N02: preferences v4 contract - fresh readers see no file, v4 carries exactly
# RecycleMode/CleaningProfile/SelectedRuleIds/CustomEnabled, the saved selection is
# normalized to the tier preset with CustomEnabled forced false, unknown fields and
# invalid tier values are refused without touching the previous file, and a v3 file
# (Recommended/Deep) migrates to Low + CustomEnabled=false + MigrationNotice while the
# v3 file itself is preserved byte-for-byte.
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
    $context = $sandbox.Context      # Medium
    $stateRoot = $context.StateRoot
    $prefPath = Join-Path $stateRoot 'preferences-v4.json'
    $legacyPath = Join-Path $stateRoot 'preferences-v3.json'
    $allIds = @(Get-SjcRules -Context $context | ForEach-Object Id)

    # 1. No file at all: the reader returns null instead of inventing a tier.
    Assert-True 'a fresh state root has no preferences file' ($null -eq (Read-SjcPreferences -Context $context)) 'expected null'
    Assert-True 'reading defaults creates no preferences file' (-not [IO.File]::Exists($prefPath) -and -not [IO.File]::Exists($legacyPath)) ''

    # 2. Save normalizes to the tier preset and always stores CustomEnabled=false.
    $mediumPreset = @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Medium')
    $saveInput = [pscustomobject]@{ RecycleMode = $false; SelectedRuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $true }
    Assert-True 'saving a Medium preference succeeds' (Save-SjcPreferences -Context $context -Preferences $saveInput) ''
    Assert-True 'saving writes preferences-v4.json' ([IO.File]::Exists($prefPath)) $prefPath
    $written = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'persisted field set is exactly the four contract fields' 'CleaningProfile,CustomEnabled,RecycleMode,SelectedRuleIds' (@($written.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-Equal 'persisted tier is the saved tier' 'Medium' ([string]$written.CleaningProfile)
    Assert-True 'persisted CustomEnabled is forced false (a draft is never enabled by file)' ($written.CustomEnabled -is [bool] -and $written.CustomEnabled -eq $false) ([string]$written.CustomEnabled)
    Assert-Equal 'persisted SelectedRuleIds is the Medium preset, not the caller subset' (@($mediumPreset | Sort-Object) -join ',') (@($written.SelectedRuleIds | Sort-Object) -join ',')
    Assert-True 'no v3 file is created by a v4 save' (-not [IO.File]::Exists($legacyPath)) ''

    $readBack = Read-SjcPreferences -Context $context
    Assert-Equal 'v4 round-trips the tier' 'Medium' ([string]$readBack.CleaningProfile)
    Assert-True 'read CustomEnabled is false for a v4 file' ($readBack.CustomEnabled -eq $false) ([string]$readBack.CustomEnabled)
    Assert-Equal 'read MigrationNotice is empty for a v4 file' '' ([string]$readBack.MigrationNotice)
    Assert-True 'read RecycleMode round-trips as a boolean' ($readBack.RecycleMode -is [bool] -and -not $readBack.RecycleMode) ([string]$readBack.RecycleMode)

    # 3. Rejected writes leave the stored file byte-identical.
    $before = [IO.File]::ReadAllText($prefPath)
    $badCases = @(
        @{ Name = 'frozen Recommended tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Recommended'; CustomEnabled = $false } },
        @{ Name = 'frozen Deep tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Deep'; CustomEnabled = $false } },
        @{ Name = 'lowercase tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'medium'; CustomEnabled = $false } },
        @{ Name = 'unknown tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Max'; CustomEnabled = $false } },
        @{ Name = 'empty tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = ''; CustomEnabled = $false } },
        @{ Name = 'missing CustomEnabled is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Low' } },
        @{ Name = 'non-boolean CustomEnabled is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Low'; CustomEnabled = 'false' } },
        @{ Name = 'unknown extra field is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Low'; CustomEnabled = $false; ProfileEpoch = 3 } },
        @{ Name = 'unknown rule id is still rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('NotARule'); CleaningProfile = 'Low'; CustomEnabled = $false } },
        @{ Name = 'duplicate rule id is still rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('SandboxOld', 'SandboxOld'); CleaningProfile = 'Low'; CustomEnabled = $false } },
        @{ Name = 'scalar SelectedRuleIds is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = 'SandboxOld'; CleaningProfile = 'Low'; CustomEnabled = $false } }
    )
    foreach ($bad in $badCases) {
        $value = $bad.Value
        Assert-Throws $bad.Name { Save-SjcPreferences -Context $context -Preferences $value } ''
    }
    Assert-Equal 'rejected writes leave preferences-v4.json byte-identical' $before ([IO.File]::ReadAllText($prefPath))

    # 4. A stored v4 file with an invalid tier or an out-of-date rule id fails loudly.
    [IO.File]::WriteAllText($prefPath, '{"CleaningProfile":"Recommended","CustomEnabled":false,"RecycleMode":true,"SelectedRuleIds":["SandboxOld"]}', $Utf8NoBom)
    Assert-Throws 'stored v4 with a frozen tier fails loudly' { Read-SjcPreferences -Context $context } 'Low、Medium 或 High'
    $staleId = 'ChromeCache:Profile_99'
    [IO.File]::WriteAllText($prefPath, ('{"CleaningProfile":"Low","CustomEnabled":false,"RecycleMode":true,"SelectedRuleIds":["' + $staleId + '"]}'), $Utf8NoBom)
    Assert-Throws 'stored v4 referencing a rule discovered earlier fails loudly' { Read-SjcPreferences -Context $context } '未知或重复规则'
    [IO.File]::WriteAllText($prefPath, '{"CleaningProfile":"Low","CustomEnabled":false,"RecycleMode":true,"SelectedRuleIds":["SandboxOld"],"Extra":1}', $Utf8NoBom)
    Assert-Throws 'stored v4 with an unknown field fails loudly' { Read-SjcPreferences -Context $context } '未知字段'
    [IO.File]::WriteAllText($prefPath, '{not-json', $Utf8NoBom)
    Assert-Throws 'corrupt v4 JSON fails loudly' { Read-SjcPreferences -Context $context } ''
    Register-OwnedTestFile -Path $prefPath; Move-OwnedTestFileToEvidence -Path $prefPath

    # 5. v3 migration: Recommended/Deep -> Low, CustomEnabled=false, notice, v3 preserved.
    foreach ($legacyTier in @('Recommended', 'Deep')) {
        [IO.File]::WriteAllText($legacyPath, ('{"CleaningProfile":"' + $legacyTier + '","RecycleMode":true,"SelectedRuleIds":["SandboxOld"]}'), $Utf8NoBom)
        $legacyBytes = [IO.File]::ReadAllBytes($legacyPath)
        $migrated = Read-SjcPreferences -Context $context
        Assert-Equal ('v3 ' + $legacyTier + ' migrates to Low, never to a wider tier') 'Low' ([string]$migrated.CleaningProfile)
        Assert-True ('v3 ' + $legacyTier + ' migration leaves CustomEnabled false') ($migrated.CustomEnabled -eq $false) ([string]$migrated.CustomEnabled)
        Assert-True ('v3 ' + $legacyTier + ' migration returns a non-empty MigrationNotice') (-not [string]::IsNullOrWhiteSpace([string]$migrated.MigrationNotice)) ([string]$migrated.MigrationNotice)
        Assert-Equal ('v3 ' + $legacyTier + ' migration selects the Low preset') ((@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Low') | Sort-Object) -join ',') (@($migrated.SelectedRuleIds | Sort-Object) -join ',')
        Assert-True ('v3 ' + $legacyTier + ' migration preserves the original v3 file bytes') (@(Compare-Object ([byte[]]$legacyBytes) ([IO.File]::ReadAllBytes($legacyPath)) -SyncWindow 0).Count -eq 0) 'v3 bytes changed'
        $migratedV4 = Read-SjcPreferences -Context $context
        Assert-Equal ('after ' + $legacyTier + ' migration the v4 file is authoritative') 'Low' ([string]$migratedV4.CleaningProfile)
        Assert-Equal ('after ' + $legacyTier + ' migration no second notice is shown') '' ([string]$migratedV4.MigrationNotice)
        Register-OwnedTestFile -Path $prefPath; Move-OwnedTestFileToEvidence -Path $prefPath
        Register-OwnedTestFile -Path $legacyPath; Move-OwnedTestFileToEvidence -Path $legacyPath
    }

    # v3 without the field, and v3 with a frozen-invalid tier.
    [IO.File]::WriteAllText($legacyPath, '{"RecycleMode":false,"SelectedRuleIds":["SandboxOld"]}', $Utf8NoBom)
    $noTier = Read-SjcPreferences -Context $context
    Assert-Equal 'v3 without a tier still migrates to Low' 'Low' ([string]$noTier.CleaningProfile)
    Assert-True 'v3 without a tier still reports the migration notice' (-not [string]::IsNullOrWhiteSpace([string]$noTier.MigrationNotice)) ''
    Register-OwnedTestFile -Path $prefPath; Move-OwnedTestFileToEvidence -Path $prefPath; Register-OwnedTestFile -Path $legacyPath; Move-OwnedTestFileToEvidence -Path $legacyPath
    [IO.File]::WriteAllText($legacyPath, '{"CleaningProfile":"Max","RecycleMode":false,"SelectedRuleIds":["SandboxOld"]}', $Utf8NoBom)
    Assert-Throws 'v3 with an unknown tier is rejected, not silently defaulted' { Read-SjcPreferences -Context $context } '旧首选项档位无效'
    Assert-True 'a rejected v3 file is left untouched and un-migrated' ([IO.File]::Exists($legacyPath) -and -not [IO.File]::Exists($prefPath)) ''
    Register-OwnedTestFile -Path $legacyPath; Move-OwnedTestFileToEvidence -Path $legacyPath

    # 6. Reading preferences never changes the sandbox rule table tier or writes elsewhere.
    [void](Save-SjcPreferences -Context $context -Preferences ([pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @(); CleaningProfile = 'High'; CustomEnabled = $false }))
    $highPrefs = Read-SjcPreferences -Context $context
    Assert-Equal 'a saved High tier is stored and read back' 'High' ([string]$highPrefs.CleaningProfile)
    Assert-Equal 'reading preferences does not switch the live context tier' 'Medium' ([string]$context.CleaningProfile)

    [void](Save-Evidence 'preferences-v4' ([pscustomobject]@{
        PersistedFields = @($written.PSObject.Properties.Name)
        PersistedProfile = $written.CleaningProfile
        PersistedCustomEnabled = $written.CustomEnabled
        MediumPresetCount = @($mediumPreset).Count
        MigrationNoticeSample = $noTier.MigrationNotice
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
