#requires -Version 5.1
# N02: preference profile contract - a missing CleaningProfile defaults to Recommended,
# the field round-trips, unknown fields are still refused, and invalid profile values
# are rejected without mutating the previous file.
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
    $stateRoot = $context.StateRoot
    $prefPath = Join-Path $stateRoot 'preferences-v3.json'
    $allIds = @(Get-SjcRules -Context $context | ForEach-Object Id)

    # Legacy v0.9 preference file without CleaningProfile must read as Recommended.
    [IO.File]::WriteAllText($prefPath, ('{"RecycleMode":false,"SelectedRuleIds":["' + $allIds[0] + '"]}'), $Utf8NoBom)
    $legacy = Read-SjcPreferences -Context $context
    Assert-True 'legacy preferences without the field are accepted, not discarded' ($null -ne $legacy) 'null'
    Assert-Equal 'missing CleaningProfile defaults to Recommended' 'Recommended' ([string]$legacy.CleaningProfile)
    Assert-True 'default profile is a strict string' ($legacy.CleaningProfile -is [string]) ([string]$legacy.CleaningProfile)
    Assert-True 'reading defaults never rewrites the legacy file' ([IO.File]::ReadAllText($prefPath) -notmatch 'CleaningProfile') ''

    # Explicit Deep round-trips.
    $deepPrefs = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Deep' }
    Assert-True 'saving an explicit Deep preference succeeds' (Save-SjcPreferences -Context $context -Preferences $deepPrefs) ''
    $written = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'persisted field set includes CleaningProfile' 'CleaningProfile,RecycleMode,SelectedRuleIds' (@($written.PSObject.Properties.Name | Sort-Object) -join ',')
    Assert-Equal 'persisted CleaningProfile is Deep' 'Deep' ([string]$written.CleaningProfile)
    Assert-Equal 'Deep round-trips through the reader' 'Deep' ([string](Read-SjcPreferences -Context $context).CleaningProfile)
    $deepRulesForPrefs = @(Get-SjcRules -Context $context)
    $unknownDeep = @($deepPrefs.SelectedRuleIds | Where-Object { $_ -notin @($deepRulesForPrefs | ForEach-Object Id) })
    Assert-Equal 'Deep preference ids remain the same rule inventory (no extra selection)' 0 $unknownDeep.Count ($unknownDeep -join ',')

    # Invalid profile values are refused and do not touch the stored file.
    $before = [IO.File]::ReadAllText($prefPath)
    $badCases = @(
        @{ Name = 'lowercase profile is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'deep' } },
        @{ Name = 'unknown profile is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Max' } },
        @{ Name = 'empty profile is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = '' } },
        @{ Name = 'integer profile is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 2 } },
        @{ Name = 'null profile property is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = $null } },
        @{ Name = 'unknown extra field is still rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Deep'; ProfileEpoch = 3 } }
    )
    foreach ($bad in $badCases) {
        $value = $bad.Value
        Assert-Throws $bad.Name { Save-SjcPreferences -Context $context -Preferences $value } ''
    }
    Assert-Equal 'rejected preference writes leave the file byte-identical' $before ([IO.File]::ReadAllText($prefPath))

    # A stored file with an invalid profile must fail loudly on read, not silently default.
    [IO.File]::WriteAllText($prefPath, ('{"RecycleMode":true,"SelectedRuleIds":["' + $allIds[0] + '"],"CleaningProfile":"deep"}'), $Utf8NoBom)
    Assert-Throws 'stored lowercase profile fails loudly' { Read-SjcPreferences -Context $context } 'Recommended 或 Deep'
    [IO.File]::WriteAllText($prefPath, ('{"RecycleMode":true,"SelectedRuleIds":["' + $allIds[0] + '"],"CleaningProfile":"Deep","Extra":1}'), $Utf8NoBom)
    Assert-Throws 'stored unknown field fails loudly' { Read-SjcPreferences -Context $context } '未知字段'
    [IO.File]::WriteAllText($prefPath, ('{"RecycleMode":true,"SelectedRuleIds":["' + $allIds[0] + '"]}'), $Utf8NoBom)
    Assert-Equal 'repaired legacy file reads as Recommended again' 'Recommended' ([string](Read-SjcPreferences -Context $context).CleaningProfile)

    # Creating/using a Deep context must not rewrite preferences by itself, and Deep must
    # not add rule ids (it changes thresholds only, never the selection inventory).
    $prefHashBeforeDeep = Get-FileSha256 $prefPath
    $deepContext = New-SjcContext -TestRoot $sandbox.Root -CleaningProfile 'Deep'
    $deepIds = @(Get-SjcRules -Context $deepContext | ForEach-Object Id)
    [void](Get-SjcRules -Context $deepContext)
    Assert-Equal 'creating a Deep context does not rewrite preferences' $prefHashBeforeDeep (Get-FileSha256 $prefPath) $prefPath
    $recommendedIds = @(Get-SjcRules -Context $deepContext | Where-Object Recommended | ForEach-Object Id)
    Assert-Equal 'Deep keeps the same rule inventory as Recommended' (@($allIds | Sort-Object) -join '|') (@($deepIds | Sort-Object) -join '|')
    Assert-True 'Deep does not auto-select rules beyond the saved selection' ($recommendedIds.Count -le $deepIds.Count) ('recommended=' + $recommendedIds.Count + '; total=' + $deepIds.Count)

    [void](Save-Evidence 'preferences-profile' ([pscustomobject]@{
        LegacyDefault = $legacy.CleaningProfile
        PersistedFields = @($written.PSObject.Properties.Name)
        RecommendedCount = $recommendedIds.Count
        DeepRuleCount = $deepIds.Count
    }))}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
