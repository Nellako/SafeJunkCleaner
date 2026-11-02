#requires -Version 5.1
# P02: preferences are strictly typed, reject unknown/duplicate/unknown-rule ids,
# do not accept legacy v2 fields, and never persist into production.
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
    $rules = @(Get-SjcRules -Context $context)
    $recommended = @($rules | Where-Object Recommended | ForEach-Object Id)
    $allIds = @($rules | ForEach-Object Id)

    # Contract requires strict types on save; a missing file may surface as $null
    # (caller applies defaults) or as a validated defaults object. Both are accepted,
    # but a returned object must still satisfy the strict shape.
    $default = Read-SjcPreferences -Context $context
    if ($null -eq $default) {
        Assert-True 'missing preferences file returns null (no implicit value)' $true 'null'
    }
    else {
        Assert-True 'default RecycleMode is strictly boolean' ($default.RecycleMode -is [bool]) ([string]$default.RecycleMode)
        $defaultIds = @($default.SelectedRuleIds)
        Assert-True 'default selection is an array of known rule ids' (@($defaultIds | Where-Object { $allIds -notcontains $_ }).Count -eq 0 -and $defaultIds.Count -le $allIds.Count) ($defaultIds -join '|')
    }
    Assert-True 'reading defaults does not create a preferences file' (-not [IO.File]::Exists($prefPath)) $prefPath

    $valid = [pscustomobject]@{ RecycleMode = $false; SelectedRuleIds = @($allIds) }
    Assert-True 'Save-SjcPreferences returns true for valid input' (Save-SjcPreferences -Context $context -Preferences $valid) ''
    Assert-True 'preferences file written under sandbox state root' ([IO.File]::Exists($prefPath)) $prefPath
    $written = Get-Content -LiteralPath $prefPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'persisted object has exactly RecycleMode+SelectedRuleIds' 'RecycleMode,SelectedRuleIds' (@($written.PSObject.Properties.Name) -join ',')
    $readBack = Read-SjcPreferences -Context $context
    Assert-True 'recycle mode round-trips as boolean false' ($readBack.RecycleMode -is [bool] -and -not $readBack.RecycleMode) ([string]$readBack.RecycleMode)
    Assert-Equal 'selected ids round-trip in order' ($allIds -join '|') (@($readBack.SelectedRuleIds) -join '|')

    $before = [IO.File]::ReadAllText($prefPath)
    $badCases = @(
        @{ Name = 'RecycleMode string is rejected'; Value = [pscustomobject]@{ RecycleMode = 'true'; SelectedRuleIds = @($allIds) } },
        @{ Name = 'RecycleMode integer is rejected'; Value = [pscustomobject]@{ RecycleMode = 1; SelectedRuleIds = @($allIds) } },
        @{ Name = 'RecycleMode null is rejected'; Value = [pscustomobject]@{ RecycleMode = $null; SelectedRuleIds = @($allIds) } },
        @{ Name = 'SelectedRuleIds scalar string is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = 'SandboxOld' } },
        @{ Name = 'SelectedRuleIds null is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = $null } },
        @{ Name = 'unknown rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('SandboxOld', 'NotARule') } },
        @{ Name = 'duplicate rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('SandboxOld', 'SandboxOld') } },
        @{ Name = 'unknown extra field is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @($allIds); ScopeMode = 'Deep' } },
        @{ Name = 'empty-string rule id is rejected'; Value = [pscustomobject]@{ RecycleMode = $true; SelectedRuleIds = @('') } }
    )
    foreach ($bad in $badCases) {
        $badValue = $bad.Value
        Assert-Throws $bad.Name { Save-SjcPreferences -Context $context -Preferences $badValue } ''
    }
    Assert-Equal 'rejected preferences leave the previous file byte-identical' $before ([IO.File]::ReadAllText($prefPath))
    [void](Save-Evidence 'preferences' ([pscustomobject]@{ Written = $written; AllIds = $allIds; Recommended = $recommended }))

    # Legacy v2 preferences must not override v3 selection.
    [IO.File]::WriteAllText($prefPath, '{"RecycleMode":false,"ScopeMode":"自定义","AdvancedRuleIds":["SandboxOld"]}', $Utf8NoBom)
    $legacyAccepted = $false
    $legacyResult = $null
    try { $legacyResult = Read-SjcPreferences -Context $context; $legacyAccepted = $true } catch { }
    if ($legacyAccepted) {
        $legacyIds = @($legacyResult.SelectedRuleIds)
        Assert-True 'legacy file does not grant legacy advanced ids' (($legacyIds -join '|') -ne 'SandboxOld') ($legacyIds -join '|')
    }
    else {
        Assert-True 'legacy file is rejected (failure feedback) instead of silently applied' $true 'Read-SjcPreferences threw'
    }
    Assert-True 'legacy file read never mutates the file' ([IO.File]::ReadAllText($prefPath) -like '*AdvancedRuleIds*') ''

    # Corrupt JSON must surface as failure, not defaults.
    [IO.File]::WriteAllText($prefPath, '{not-json', $Utf8NoBom)
    Assert-Throws 'corrupt preferences fail loudly' { Read-SjcPreferences -Context $context } ''

    # Production preference file was never touched by this case.
    $prodPref = Join-Path $script:ProdStateRoot 'preferences-v3.json'
    $prodHash = if ([IO.File]::Exists($prodPref)) { Get-FileSha256 $prodPref } else { 'absent' }
    [void](Save-EvidenceText 'production-pref' ('path=' + $prodPref + '; sha256=' + $prodHash))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
