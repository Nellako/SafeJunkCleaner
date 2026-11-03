#requires -Version 5.1
# P02: preferences are strictly typed, reject unknown/duplicate/unknown-rule ids and
# out-of-contract fields, never treat a legacy v2 file as authority, and never persist
# into production. The v4 contract additionally requires an explicit boolean
# CustomEnabled and a Low/Medium/High tier.
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
    $prefPath = Join-Path $stateRoot 'preferences-v4.json'
    $legacyPath = Join-Path $stateRoot 'preferences-v3.json'
    $rules = @(Get-SjcRules -Context $context)
    $allIds = @($rules | ForEach-Object Id)
    $mediumPreset = @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Medium')

    # Strict typing on save. A missing file is reported as null so the caller applies
    # its own default; reading must not create any preference file.
    Assert-True 'missing preferences file returns null (no implicit value)' ($null -eq (Read-SjcPreferences -Context $context)) 'null'
    Assert-True 'reading defaults does not create a v4 preferences file' (-not [IO.File]::Exists($prefPath)) $prefPath
    Assert-True 'reading defaults does not create a v3 preferences file' (-not [IO.File]::Exists($legacyPath)) $legacyPath

    $valid = [pscustomobject]@{ RecycleMode = $false; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = $false }
    Assert-True 'Save-SjcPreferences returns true for valid input' (Save-SjcPreferences -Context $context -Preferences $valid) ''
    Assert-True 'preferences file written under the sandbox state root' ([IO.File]::Exists($prefPath)) $prefPath
    $written = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'persisted object has exactly the four contract fields' 'CleaningProfile,CustomEnabled,RecycleMode,SelectedRuleIds' (@($written.PSObject.Properties.Name | Sort-Object) -join ',')
    $readBack = Read-SjcPreferences -Context $context
    Assert-True 'recycle mode round-trips as boolean false' ($readBack.RecycleMode -is [bool] -and -not $readBack.RecycleMode) ([string]$readBack.RecycleMode)
    Assert-Equal 'the stored selection is normalized to the Medium preset' ((@($mediumPreset) | Sort-Object) -join '|') ((@($readBack.SelectedRuleIds) | Sort-Object) -join '|')
    Assert-True 'stored CustomEnabled is forced false' ($readBack.CustomEnabled -eq $false) ([string]$readBack.CustomEnabled)

    $before = [IO.File]::ReadAllText($prefPath)
    $badCases = @(
        @{ Name = 'RecycleMode string is rejected'; Value = [pscustomobject]@{ RecycleMode = 'true'; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'RecycleMode integer is rejected'; Value = [pscustomobject]@{ RecycleMode = 1; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'RecycleMode null is rejected'; Value = [pscustomobject]@{ RecycleMode = $null; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'SelectedRuleIds scalar string is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = 'SandboxOld'; CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'SelectedRuleIds null is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = $null; CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'unknown rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('SandboxOld', 'NotARule'); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'duplicate rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('SandboxOld', 'SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'unknown extra field is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = $false; ScopeMode = 'Old' } },
        @{ Name = 'empty-string rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @(''); CleaningProfile = 'Medium'; CustomEnabled = $false } },
        @{ Name = 'missing CustomEnabled is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium' } },
        @{ Name = 'string CustomEnabled is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Medium'; CustomEnabled = 'false' } },
        @{ Name = 'frozen Recommended tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Recommended'; CustomEnabled = $false } },
        @{ Name = 'frozen Deep tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'Deep'; CustomEnabled = $false } },
        @{ Name = 'lowercase tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CleaningProfile = 'medium'; CustomEnabled = $false } },
        @{ Name = 'missing tier is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); CustomEnabled = $false } }
    )
    foreach ($bad in $badCases) {
        $badValue = $bad.Value
        Assert-Throws $bad.Name { Save-SjcPreferences -Context $context -Preferences $badValue } ''
    }
    Assert-Equal 'rejected preferences leave the previous file byte-identical' $before ([IO.File]::ReadAllText($prefPath))

    # A stored v4 with an out-of-date discovered rule id must fail loudly: the GUI then
    # falls back to the safe Low tier instead of silently keeping a wider scope.
    $staleId = 'ChromeCache:Profile_98'
    [IO.File]::WriteAllText($prefPath, ('{"CleaningProfile":"High","CustomEnabled":false,"RecycleMode":true,"SelectedRuleIds":["' + $staleId + '"]}'), $Utf8NoBom)
    Assert-Throws 'stored v4 with a stale discovered rule id fails loudly' { Read-SjcPreferences -Context $context } '未知或重复规则'
    Assert-True 'a stale v4 file is left untouched for the GUI fallback path' ([IO.File]::Exists($prefPath)) $prefPath
    Remove-Item -LiteralPath $prefPath -Force

    # Legacy v2 preferences must never override the v3/v4 selection and must never grant
    # legacy advanced ids. The file is not migrated because its schema is unknown.
    [IO.File]::WriteAllText($legacyPath, '{"RecycleMode":false,"ScopeMode":"自定义","AdvancedRuleIds":["SandboxOld"]}', $Utf8NoBom)
    $legacyAccepted = $false
    $legacyResult = $null
    try { $legacyResult = Read-SjcPreferences -Context $context; $legacyAccepted = $true } catch { }
    if ($legacyAccepted) {
        $legacyIds = @($legacyResult.SelectedRuleIds)
        Assert-True 'legacy file does not grant legacy advanced ids' (($legacyIds -join '|') -ne 'SandboxOld') ($legacyIds -join '|')
        Assert-True 'legacy file cannot widen beyond the Low preset' ((@($legacyIds | Where-Object { @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Low') -notcontains $_ })).Count -eq 0) ($legacyIds -join '|')
        Assert-Equal 'legacy file migrates at most to Low' 'Low' ([string]$legacyResult.CleaningProfile)
    }
    else {
        Assert-True 'legacy file is rejected (failure feedback) instead of silently applied' $true 'Read-SjcPreferences threw'
    }
    Assert-True 'legacy file read never mutates the file' ([IO.File]::ReadAllText($legacyPath) -like '*AdvancedRuleIds*') ''

    # Corrupt v4 JSON must surface as failure, not defaults.
    [IO.File]::WriteAllText($prefPath, '{not-json', $Utf8NoBom)
    Assert-Throws 'corrupt preferences fail loudly' { Read-SjcPreferences -Context $context } ''

    # Production preference file was never touched by this case.
    $prodPref = Join-Path $script:ProdStateRoot 'preferences-v4.json'
    $prodHash = if ([IO.File]::Exists($prodPref)) { Get-FileSha256 $prodPref } else { 'absent' }
    [void](Save-EvidenceText 'production-pref' ('path=' + $prodPref + '; sha256=' + $prodHash))
    [void](Save-Evidence 'preferences' ([pscustomobject]@{ Written = $written; AllIds = $allIds; MediumPreset = $mediumPreset }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
