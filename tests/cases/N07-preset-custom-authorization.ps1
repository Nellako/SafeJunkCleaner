#requires -Version 5.1
# N07: three-tier preset contract and custom authorization.
# Covers: exact profile ids/messages from Get-SjcCleaningProfiles, Low subset Medium
# subset High by real rule ids, per-level age table, CustomOnly exclusion, preset scans
# that require the exact member set, custom scans that may use any subset of trusted
# rules, sealed CustomEnabled, and clean validation against the scan-time rule set
# (a rule discovered after the scan must not invalidate the sealed plan).
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$originalRules = $null
try {
    # ---- 1. Profiles API -----------------------------------------------------
    $profiles = @(Get-SjcCleaningProfiles)
    Assert-Equal 'Get-SjcCleaningProfiles returns exactly three tiers' 3 $profiles.Count (($profiles | ForEach-Object Id) -join ',')
    Assert-Equal 'profile ids are Low/Medium/High in order' 'Low,Medium,High' (@($profiles | ForEach-Object { [string]$_.Id }) -join ',')
    $profileShape = New-Object 'System.Collections.Generic.List[string]'
    foreach ($profile in $profiles) {
        $names = @($profile.PSObject.Properties.Name | Sort-Object) -join ','
        if ($names -ne 'Description,Id,Impact,Label') { $profileShape.Add([string]$profile.Id + ':shape=' + $names); continue }
        foreach ($field in @('Id', 'Label', 'Description', 'Impact')) {
            $value = [string]$profile.$field
            if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { $profileShape.Add([string]$profile.Id + ':' + $field) }
        }
    }
    Assert-True 'each profile exposes non-empty Id/Label/Description/Impact strings' ($profileShape.Count -eq 0) ($profileShape -join '; ')
    Assert-Equal 'profile ids are unique' 3 (@($profiles | ForEach-Object { [string]$_.Id } | Select-Object -Unique).Count)
    Assert-Throws 'unknown profile id is refused by the preset API' { Get-SjcPresetRuleIds -Context (New-SjcRuleInventoryContext) -CleaningProfile 'Recommended' } 'Low|Medium|High'

    # ---- 2. Preset containment on the real production rule table --------------
    $production = New-ProductionContextForInventory
    $prodRules = @(Get-SjcRules -Context $production)
    $presets = @{}
    foreach ($level in @('Low', 'Medium', 'High')) { $presets[$level] = @(Get-SjcPresetRuleIds -Context $production -CleaningProfile $level) }
    Assert-True 'every preset is a non-empty string array' (@($presets.Values | Where-Object { $_ -is [string] -or @($_).Count -eq 0 }).Count -eq 0) (($presets.Keys | ForEach-Object { $_ + '=' + @($presets[$_]).Count }) -join ',')
    $lowSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $presets['Low']) { [void]$lowSet.Add($id) }
    $mediumSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $presets['Medium']) { [void]$mediumSet.Add($id) }
    $highSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $presets['High']) { [void]$highSet.Add($id) }
    $containment = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $lowSet) { if (-not $mediumSet.Contains($id)) { $containment.Add('low-not-medium:' + $id) } }
    foreach ($id in $mediumSet) { if (-not $highSet.Contains($id)) { $containment.Add('medium-not-high:' + $id) } }
    Assert-True 'Low is a strict subset of Medium and Medium of High' ($containment.Count -eq 0) ($containment -join '; ')
    Assert-True 'each tier is strictly larger than the previous' ($lowSet.Count -lt $mediumSet.Count -and $mediumSet.Count -lt $highSet.Count) ('low=' + $lowSet.Count + '; medium=' + $mediumSet.Count + '; high=' + $highSet.Count)
    $unknownPresetIds = @($presets.Values | ForEach-Object { $_ } | Where-Object { $_ -notin @($prodRules | ForEach-Object Id) })
    Assert-Equal 'preset ids all resolve to real production rules' 0 $unknownPresetIds.Count ($unknownPresetIds -join ',')

    # Membership is by PresetLevel, not by directory availability: a missing fixed
    # root must not silently drop the rule from the tier that owns it.
    $levelMembershipErrors = New-Object 'System.Collections.Generic.List[string]'
    $levels = @{ Low = 1; Medium = 2; High = 3 }
    foreach ($rule in $prodRules) {
        $level = [string]$rule.PresetLevel
        foreach ($tier in @('Low', 'Medium', 'High')) {
            $inPreset = $presets[$tier] -contains $rule.Id
            $expected = ($levels.ContainsKey($level) -and $levels[$level] -le $levels[$tier])
            if ($inPreset -ne $expected) { $levelMembershipErrors.Add($rule.Id + ':' + $tier + '=' + $inPreset + '/expected ' + $expected + ' level=' + $level) }
        }
    }
    Assert-True 'preset membership follows PresetLevel only (Available never filters)' ($levelMembershipErrors.Count -eq 0) (($levelMembershipErrors | Select-Object -First 10) -join '; ')
    $customOnly = @($prodRules | Where-Object { $_.PresetLevel -ceq 'CustomOnly' })
    Assert-True 'CustomOnly rules exist for advanced-only categories' ($customOnly.Count -ge 2) (($customOnly | ForEach-Object Id) -join ',')
    Assert-Equal 'no CustomOnly rule leaks into any preset' 0 (@($customOnly | Where-Object { $id = $_.Id; $presets.Values | Where-Object { $_ -contains $id } }).Count) (($customOnly | ForEach-Object Id) -join ',')
    foreach ($explorer in @('ExplorerThumbCache', 'ExplorerIconCache')) {
        $rule = @($prodRules | Where-Object { $_.Id -ceq $explorer })
        if ($rule.Count -gt 0) {
            Assert-Equal ($explorer + ' stays CustomOnly') 'CustomOnly' ([string]$rule[0].PresetLevel)
            Assert-True ($explorer + ' is absent from Low/Medium/High presets') (-not ($presets['High'] -contains $explorer)) ''
        }
    }

    # ---- 3. Per-level age table (real template ids) ---------------------------
    # Values come from the approved tier table, not from the implementation's own output.
    $ageTable = @{
        UserTemp           = @{ Low = 24; Medium = 24; High = 6 }
        WindowsTemp        = @{ Low = 48; Medium = 48; High = 24 }
        VSCodeCache        = @{ Low = 48; Medium = 48; High = 0 }
        VSCodeCodeCache    = @{ Low = 168; Medium = 168; High = 0 }
        TeamsCache         = @{ Low = 168; Medium = 168; High = 24 }
        TeamsGPUCache      = @{ Low = 168; Medium = 168; High = 0 }
        SteamHtmlCache     = @{ Low = 168; Medium = 168; High = 24 }
        NewTeamsCache      = @{ Low = 168; Medium = 168; High = 0 }
        NewTeamsGPUCache   = @{ Low = 168; Medium = 168; High = 0 }
        NewTeamsCodeCache  = @{ Low = 168; Medium = 168; High = 0 }
        NpmCache           = @{ Low = 168; Medium = 168; High = 24 }
        NuGetCache         = @{ Low = 168; Medium = 168; High = 24 }
        PipHttpCache       = @{ Low = 168; Medium = 168; High = 24 }
        PipHttpV2Cache     = @{ Low = 168; Medium = 168; High = 24 }
        PipWheelCache      = @{ Low = 168; Medium = 168; High = 24 }
        YarnCache          = @{ Low = 168; Medium = 168; High = 24 }
        GoBuildCache       = @{ Low = 168; Medium = 168; High = 24 }
        GradleCache        = @{ Low = 720; Medium = 720; High = 168 }
        CrashDumps         = @{ Low = 720; Medium = 720; High = 720 }
        WERArchive         = @{ Low = 720; Medium = 720; High = 720 }
        D3DSCache          = @{ Low = 168; Medium = 168; High = 168 }
        NvidiaDXCache      = @{ Low = 168; Medium = 168; High = 168 }
        NvidiaGLCache      = @{ Low = 168; Medium = 168; High = 168 }
        AmdDxCache         = @{ Low = 168; Medium = 168; High = 168 }
        AmdDxcCache        = @{ Low = 168; Medium = 168; High = 168 }
        IntelShaderCache   = @{ Low = 168; Medium = 168; High = 168 }
    }
    $ageErrors = New-Object 'System.Collections.Generic.List[string]'
    $pureCacheIds = @('VSCodeCache', 'VSCodeCodeCache', 'TeamsGPUCache', 'NewTeamsCache', 'NewTeamsGPUCache', 'NewTeamsCodeCache')
    foreach ($template in $ageTable.Keys) {
        $matches = @($prodRules | Where-Object { $_.TemplateId -ceq $template })
        if ($matches.Count -eq 0) { $ageErrors.Add($template + ':missing-template'); continue }
        foreach ($rule in $matches) {
            foreach ($level in @('Low', 'Medium', 'High')) {
                $expected = [double]$ageTable[$template][$level]
                $actual = [double]$rule.($level + 'MinimumAgeHours')
                if ($actual -ne $expected) { $ageErrors.Add($rule.Id + ':' + $level + '=' + $actual + '/expected ' + $expected) }
            }
            # Zero High is allowed only together with the PureCache policy.
            if ([double]$rule.HighMinimumAgeHours -eq 0 -and [string]$rule.AgePolicy -cne 'PureCache') { $ageErrors.Add($rule.Id + ':zero-without-purecache') }
            if ($pureCacheIds -contains $template -and [string]$rule.AgePolicy -cne 'PureCache') { $ageErrors.Add($rule.Id + ':missing-purecache') }
            if ([string]$rule.CleaningProfile -cne 'Medium') { $ageErrors.Add($rule.Id + ':profile=' + $rule.CleaningProfile) }
            if ([double]$rule.MinimumAgeHours -ne [double]$rule.MediumMinimumAgeHours) { $ageErrors.Add($rule.Id + ':effective-not-medium') }
        }
    }
    Assert-True 'the approved v0.12 per-tier age table is implemented exactly' ($ageErrors.Count -eq 0) (($ageErrors | Select-Object -First 12) -join '; ')
    # Effective age must follow the active profile, not a fixed field.
    $effectiveErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($level in @('Low', 'Medium', 'High')) {
        [void](Set-SjcCleaningProfile -Context $production -CleaningProfile $level)
        foreach ($rule in @(Get-SjcRules -Context $production)) {
            if ([double]$rule.MinimumAgeHours -ne [double]$rule.($level + 'MinimumAgeHours')) { $effectiveErrors.Add($rule.Id + ':' + $level) }
            if ([string]$rule.CleaningProfile -cne $level) { $effectiveErrors.Add($rule.Id + ':profile-tag:' + $level) }
        }
    }
    [void](Set-SjcCleaningProfile -Context $production -CleaningProfile 'Medium')
    Assert-True 'switching the context applies that tier''s effective MinimumAgeHours' ($effectiveErrors.Count -eq 0) (($effectiveErrors | Select-Object -First 12) -join '; ')
    # Browser families: Cache is Low, Code/GPU are Medium, and High drops to 0h because
    # every discovered browser rule is a reviewed PureCache template.
    $browserErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in @($prodRules | Where-Object { $_.Group -ceq '浏览器缓存' })) {
        $expectedLevel = if ($rule.TemplateId -in @('ChromeCache', 'EdgeCache', 'BraveCache', 'FirefoxCache2')) { 'Low' } else { 'Medium' }
        if ([string]$rule.PresetLevel -cne $expectedLevel) { $browserErrors.Add($rule.Id + ':level=' + $rule.PresetLevel + '/expected ' + $expectedLevel) }
        if ([double]$rule.HighMinimumAgeHours -ne 0) { $browserErrors.Add($rule.Id + ':high=' + $rule.HighMinimumAgeHours) }
        if ([string]$rule.AgePolicy -cne 'PureCache') { $browserErrors.Add($rule.Id + ':policy=' + $rule.AgePolicy) }
    }
    Assert-True 'browser Cache is Low, Code/GPU are Medium, High uses 0h pure-cache age' ($browserErrors.Count -eq 0) ($browserErrors -join '; ')
    Assert-True 'a browser Cache instance (or Firefox cache2) is present to assert the Low tier' ((@($prodRules | Where-Object { $_.Group -ceq '浏览器缓存' }).Count -gt 0)) 'no browser rule discovered on this host'

    # ---- 4. Preset scan requires the exact member set --------------------------
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    New-TestFile -Path (Join-Path $files 'preset-old.tmp') -Bytes 32 -AgeHours 96 | Out-Null
    New-TestFile -Path (Join-Path $files 'preset-old.log') -Bytes 48 -AgeHours 96 | Out-Null
    Assert-Equal 'sandbox context starts at Medium' 'Medium' ([string]$context.CleaningProfile)
    $sandboxPreset = @(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Medium')
    Assert-Equal 'sandbox Medium preset contains both synthetic rules' 'SandboxLog,SandboxOld' (@($sandboxPreset | Sort-Object) -join ',')
    Assert-Equal 'sandbox Low preset contains only SandboxOld' 'SandboxOld' (@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'Low') -join ',')
    Assert-Equal 'sandbox High preset equals Medium (no High-only sandbox rules)' ((@(Get-SjcPresetRuleIds -Context $context -CleaningProfile 'High') | Sort-Object) -join ',') (@($sandboxPreset | Sort-Object) -join ',')

    $presetTask = New-SjcTaskDirectory -Context $context
    $presetScan = Invoke-SjcScan -Context $context -RuleIds $sandboxPreset -TaskDirectory $presetTask -CustomEnabled $false
    Assert-Equal 'an exact preset scan succeeds' 'Success' ([string]$presetScan.Status) ([string]$presetScan.Error)
    Assert-True 'a preset scan reports CustomEnabled=false' ($presetScan.PSObject.Properties['CustomEnabled'] -and $presetScan.CustomEnabled -eq $false) ([string]$presetScan.CustomEnabled)
    $presetMeta = Unprotect-SjcText (Read-SjcSafeText (Join-Path $presetTask 'scan.meta.json')) | ConvertFrom-Json
    Assert-True 'sealed metadata records CustomEnabled=false' ($presetMeta.PSObject.Properties['CustomEnabled'] -and $presetMeta.CustomEnabled -eq $false) ([string]$presetMeta.CustomEnabled)
    Assert-Equal 'sealed metadata profile is Medium' 'Medium' ([string]$presetMeta.CleaningProfile)

    $missingTask = New-SjcTaskDirectory -Context $context
    $missingScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $missingTask -CustomEnabled $false
    Assert-Equal 'a preset scan with a missing member fails' 'Failed' ([string]$missingScan.Status)
    Assert-True 'missing-member failure names the preset set' ([string]$missingScan.Error -match '预设规则集合') ([string]$missingScan.Error)
    Assert-True 'a rejected preset scan writes no sealed plan' (-not [IO.File]::Exists((Join-Path $missingTask 'scan.meta.json'))) ''

    # Extra member: a CustomOnly rule must not be acceptable inside a preset scan.
    # The double only widens the trusted rule table to prove the gate; its shape mirrors
    # a production rule (root/patterns/ages) and it is never cleaned.
    $originalRules = ${function:Get-SjcRules}
    $script:n07Sandbox = $sandbox.Root
    $script:n07Extra = $false
    function Get-SjcRules {
        param($Context)
        $rules = @(& $script:n07OriginalRules -Context $Context)
        if ($script:n07Extra) {
            $copy = $rules[0].PSObject.Copy()
            $copy.Id = 'SandboxExtra'
            $copy.TemplateId = 'SandboxExtra'
            $copy.PresetLevel = 'CustomOnly'
            $copy.Recommended = $false
            $rules += $copy
        }
        return $rules
    }
    $script:n07OriginalRules = $originalRules
    $script:n07Extra = $true
    $extraTask = New-SjcTaskDirectory -Context $context
    $extraScan = Invoke-SjcScan -Context $context -RuleIds (@($sandboxPreset) + 'SandboxExtra') -TaskDirectory $extraTask -CustomEnabled $false
    Assert-Equal 'a preset scan with an extra CustomOnly member fails' 'Failed' ([string]$extraScan.Status)
    Assert-True 'extra-member failure names the preset set' ([string]$extraScan.Error -match '预设规则集合') ([string]$extraScan.Error)

    # ---- 5. Custom scan may use any subset of trusted rules --------------------
    $customTask = New-SjcTaskDirectory -Context $context
    $customScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $customTask -CustomEnabled $true
    Assert-Equal 'a custom subset scan succeeds when explicitly enabled' 'Success' ([string]$customScan.Status) ([string]$customScan.Error)
    Assert-True 'a custom scan reports CustomEnabled=true' ($customScan.CustomEnabled -eq $true) ([string]$customScan.CustomEnabled)
    $customMeta = Unprotect-SjcText (Read-SjcSafeText (Join-Path $customTask 'scan.meta.json')) | ConvertFrom-Json
    Assert-True 'sealed metadata records CustomEnabled=true' ($customMeta.PSObject.Properties['CustomEnabled'] -and $customMeta.CustomEnabled -eq $true) ([string]$customMeta.CustomEnabled)
    Assert-Equal 'sealed metadata pins only the scanned rule set' 'SandboxOld' (@(@($customMeta.Rules) | ForEach-Object { ($_ | ConvertFrom-Json).Id } | Sort-Object) -join ',')
    $unknownTask = New-SjcTaskDirectory -Context $context
    $unknownScan = Invoke-SjcScan -Context $context -RuleIds @('NotARule') -TaskDirectory $unknownTask -CustomEnabled $true
    Assert-Equal 'an unknown rule fails a custom scan with zero candidates' 'Failed|0' ([string]$unknownScan.Status + '|' + [string]$unknownScan.CandidateCount)
    Assert-True 'unknown-rule failure names the rule problem' ([string]$unknownScan.Error -match '未知或重复规则') ([string]$unknownScan.Error)
    Assert-True 'an unknown-rule custom scan writes no sealed plan' (-not [IO.File]::Exists((Join-Path $unknownTask 'scan.meta.json'))) ''

    # ---- 6. Clean validates the scan-time set, not later discovery -------------
    # A rule that appears after the scan must not invalidate the sealed custom plan.
    $script:n07Extra = $false
    $lateTask = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $files 'late-old.tmp') -Bytes 24 -AgeHours 96 | Out-Null
    $lateScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $lateTask -CustomEnabled $true
    Assert-Equal 'late-discovery baseline scan succeeds' 'Success' ([string]$lateScan.Status) ([string]$lateScan.Error)
    $script:n07Extra = $true
    $lateClean = Invoke-SjcClean -Context $context -TaskDirectory $lateTask -RecycleMode $false
    $script:n07Extra = $false
    Assert-Equal 'a clean is not invalidated by rules discovered after the scan' 'Success' ([string]$lateClean.Status) ([string]$lateClean.Error)
    Assert-True 'late-discovery clean deleted its own sealed candidate' ([int64]$lateClean.Deleted -ge 1) ([string]$lateClean.Deleted)
    Assert-True 'late-discovery clean kept the unselected synthetic log' ([IO.File]::Exists((Join-Path $files 'preset-old.log'))) ''

    # A sealed plan claiming preset mode must be refused if any sealed rule sits above
    # the sealed tier. Scan a Low context with the Medium-only SandboxLog in custom
    # mode, then re-seal it as preset mode: clean must reject the out-of-tier rule.
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Low')
    $forgedTask = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $files 'forged-old.log') -Bytes 40 -AgeHours 96 | Out-Null
    $forgedScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxLog') -TaskDirectory $forgedTask -CustomEnabled $true
    Assert-Equal 'forged-mode baseline custom scan succeeds' 'Success' ([string]$forgedScan.Status) ([string]$forgedScan.Error)
    $forgedMetaPath = Join-Path $forgedTask 'scan.meta.json'
    $forgedMeta = Unprotect-SjcText (Read-SjcSafeText $forgedMetaPath) | ConvertFrom-Json
    $forgedMeta.CustomEnabled = $false
    Write-SjcAtomicText $forgedMetaPath (Protect-SjcText ($forgedMeta | ConvertTo-Json -Depth 8 -Compress))
    $forgedClean = Invoke-SjcClean -Context $context -TaskDirectory $forgedTask -RecycleMode $false
    Assert-True 'a sealed preset mode with an out-of-tier rule fails closed' ($forgedClean.Status -eq 'Failed' -and [int64]$forgedClean.Deleted -eq 0) ('status=' + $forgedClean.Status + '; deleted=' + $forgedClean.Deleted + '; error=' + $forgedClean.Error)
    Assert-True 'forged-mode refusal names the tier/rule set' ([string]$forgedClean.Error -match '预设|档位|规则集合|封存') ([string]$forgedClean.Error)
    Assert-True 'forged-mode refusal deleted nothing' ([IO.File]::Exists((Join-Path $files 'forged-old.log'))) ''
    [void](Set-SjcCleaningProfile -Context $context -CleaningProfile 'Medium')

    [void](Save-Evidence 'preset-custom' ([pscustomobject]@{
        Profiles = @($profiles | ForEach-Object { [string]$_.Id })
        LowCount = $lowSet.Count
        MediumCount = $mediumSet.Count
        HighCount = $highSet.Count
        CustomOnly = @($customOnly | ForEach-Object Id)
        PresetScan = $presetScan.Status
        MissingRejected = $missingScan.Status
        ExtraRejected = $extraScan.Status
        CustomScan = $customScan.Status
        LateDiscoveryClean = $lateClean.Status
        ForgedModeClean = $forgedClean.Status
    }))
    Add-Limitation 'N07 的额外/自定义规则双仅在进程内扩充可信规则表以验证预设 vs 自定义闸门；真实生产规则表与年龄表由第 2、3 节单独断言。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($null -ne $originalRules) { ${function:Get-SjcRules} = $originalRules }
}
Complete-TestCase
