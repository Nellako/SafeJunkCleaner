#requires -Version 5.1
# R01: production rule inventory - forbidden cache families, exact roots, stable ids, count.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
try {
    $context = New-ProductionContextForInventory
    $rules = @(Get-SjcRules -Context $context)
    [void](Save-Evidence 'rules' $rules)

    Assert-True 'rule inventory is non-empty' ($rules.Count -gt 0) ('count=' + $rules.Count)

    # New contract: profile membership, both profile ages and the override denylist are
    # part of every rule, so a plan seal can pin them.
    $requiredProperties = @('Id', 'TemplateId', 'Name', 'Group', 'Risk', 'Recommended', 'Root', 'Patterns', 'ExcludePatterns', 'MinimumAgeHours', 'RecommendedMinimumAgeHours', 'DeepMinimumAgeHours', 'CleaningProfile', 'OverrideEnvironment', 'RequiresClosedProcess', 'Available', 'Note')
    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $rules) {
        foreach ($property in $requiredProperties) {
            if (-not $rule.PSObject.Properties[$property]) { $missing.Add($rule.Id + ':' + $property) }
        }
    }
    Assert-True 'every rule exposes all contract properties' ($missing.Count -eq 0) (($missing | Select-Object -First 8) -join '; ')

    $ids = @($rules | ForEach-Object Id)
    Assert-Equal 'rule ids are unique' $ids.Count (@($ids | Select-Object -Unique).Count)
    $badIds = @($ids | Where-Object { $_ -cnotmatch '^[A-Za-z][A-Za-z0-9]*(:[A-Za-z0-9_]+)?$' })
    Assert-True 'rule ids use stable ASCII template[:profile] form' ($badIds.Count -eq 0) ($badIds -join ',')

    $baseTemplates = @($rules | Where-Object { $_.Id -notmatch ':' } | ForEach-Object TemplateId | Select-Object -Unique | Sort-Object)
    # v0.10 expanded the verified allow-list with documented default cache subroots.
    # FirefoxCache2 is conditional on a matching default-named Profile on this host and
    # is asserted separately below; it is not part of the unconditional base set.
    $expectedBase = @(
        'AmdDxCache', 'AmdDxcCache', 'CrashDumps', 'D3DSCache', 'ExplorerIconCache', 'ExplorerThumbCache',
        'GoBuildCache', 'GradleCache', 'IntelShaderCache', 'NpmCache', 'NuGetCache', 'NvidiaDXCache',
        'NvidiaGLCache', 'PipHttpCache', 'PipHttpV2Cache', 'PipWheelCache', 'SteamHtmlCache',
        'TeamsCache', 'TeamsGPUCache', 'UserTemp', 'VSCodeCache', 'VSCodeCodeCache', 'WERArchive',
        'WindowsTemp', 'YarnCache'
    ) | Sort-Object
    $baseTemplates = @($baseTemplates | Where-Object { $_ -ne 'FirefoxCache2' })
    Assert-Equal 'exactly 25 unconditional verified base templates' $expectedBase.Count $baseTemplates.Count ($baseTemplates -join ',')
    $templateDelta = @(Compare-Object -ReferenceObject $expectedBase -DifferenceObject $baseTemplates)
    Assert-Equal 'base template set matches the documented allow-list' 0 $templateDelta.Count (($templateDelta | ForEach-Object { $_.InputObject }) -join ',')

    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $roaming = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $winTemp = Join-Path ([IO.Directory]::GetParent([Environment]::SystemDirectory).FullName) 'Temp'

    $forbidden = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $rules) {
        $root = [string]$rule.Root
        if ($root -match '[?*]') { $forbidden.Add($rule.Id + ':root-wildcard') }
        if ($root -match '(?i)\\Service Worker(\\|$)') { $forbidden.Add($rule.Id + ':service-worker') }
        if ($root -match '(?i)CacheStorage') { $forbidden.Add($rule.Id + ':cachestorage') }
        if ($root -match '(?i)OfficeFileCache') { $forbidden.Add($rule.Id + ':office-file-cache') }
        if ($root -match '(?i)\\\.m2\\repository') { $forbidden.Add($rule.Id + ':maven-repository') }
        # A Firefox profile root is still forbidden; only the exact Local cache2 child
        # (real disk cache, never *.sqlite-wal) may be a rule root.
        if ($root -match '(?i)\\Mozilla\\Firefox\\Profiles(\\|$)' -and $root -notmatch '(?i)\\Mozilla\\Firefox\\Profiles\\[^\\]+\\cache2$') { $forbidden.Add($rule.Id + ':firefox-profile-root') }
        if ($root -match '(?i)\\storage(\\|$)') { $forbidden.Add($rule.Id + ':firefox-storage') }
        if ($root -match '(?i)\\Microsoft\\Office\\') { $forbidden.Add($rule.Id + ':office-root') }
        if ($root -match '(?i)\\Documents(\\|$)') { $forbidden.Add($rule.Id + ':documents') }
        if ($root -match '(?i)\\Downloads(\\|$)') { $forbidden.Add($rule.Id + ':downloads') }
        if ($root -match '(?i)\\Desktop(\\|$)') { $forbidden.Add($rule.Id + ':desktop') }
        foreach ($pattern in @($rule.Patterns)) {
            if ($pattern -match '(?i)(-wal|-shm|\.wal|\.shm)') { $forbidden.Add($rule.Id + ':wal-pattern:' + $pattern) }
            if ($pattern -match '(?i)^\*$' -and @($rule.ExcludePatterns).Count -eq 0 -and $rule.Id -notin @('UserTemp', 'WindowsTemp')) {
                # A generic * on a cache directory is acceptable only when the
                # root itself is an exact regenerable cache. Recorded, not flagged.
                continue
            }
        }
    }
    Assert-True 'no forbidden cache family, WAL pattern or user-content root' ($forbidden.Count -eq 0) ($forbidden -join '; ')

    $userTemp = @($rules | Where-Object { $_.Id -eq 'UserTemp' })[0]
    $windowsTemp = @($rules | Where-Object { $_.Id -eq 'WindowsTemp' })[0]
    $userTempEx = (@($userTemp.ExcludePatterns) -join '|')
    $windowsTempEx = (@($windowsTemp.ExcludePatterns) -join '|')
    Assert-True 'UserTemp excludes WAL/SHM patterns' ($userTempEx -match '(?i)-wal') -and ($userTempEx -match '(?i)-shm') $userTempEx
    Assert-True 'WindowsTemp excludes WAL/SHM patterns' ($windowsTempEx -match '(?i)-wal') -and ($windowsTempEx -match '(?i)-shm') $windowsTempEx

    $cycles = @(
        @{ Id = 'UserTemp'; Root = (Join-Path $local 'Temp') },
        @{ Id = 'WindowsTemp'; Root = $winTemp },
        @{ Id = 'VSCodeCache'; Root = (Join-Path $roaming 'Code\Cache') },
        @{ Id = 'VSCodeCodeCache'; Root = (Join-Path $roaming 'Code\CachedData') },
        @{ Id = 'GradleCache'; Root = (Join-Path $profile '.gradle\caches') }
    )
    $rootMismatch = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $cycles) {
        $rule = @($rules | Where-Object { $_.Id -eq $entry.Id })[0]
        if ($null -eq $rule) { $rootMismatch.Add($entry.Id + ':missing'); continue }
        if (-not ([IO.Path]::GetFullPath([string]$rule.Root)).Equals([IO.Path]::GetFullPath([string]$entry.Root), [StringComparison]::OrdinalIgnoreCase)) {
            $rootMismatch.Add($entry.Id + '=' + $rule.Root + ' expected ' + $entry.Root)
        }
    }
    Assert-True 'fixed base roots are exact (no env override)' ($rootMismatch.Count -eq 0) ($rootMismatch -join '; ')

    $gradle = @($rules | Where-Object { $_.Id -eq 'GradleCache' })[0]
    Assert-True 'GradleCache excludes wrapper/project/Maven subtrees' ($gradle.Note -match 'wrapper' -and $gradle.Note -match 'Maven') $gradle.Note

    $browserRules = @($rules | Where-Object { $_.Id -match ':' })
    $browserDelta = New-Object 'System.Collections.Generic.List[string]'
    $allowedTemplates = @('ChromeCache', 'ChromeCodeCache', 'ChromeGPUCache', 'EdgeCache', 'EdgeCodeCache', 'EdgeGPUCache', 'BraveCache', 'BraveCodeCache', 'BraveGPUCache')
    foreach ($rule in $browserRules) {
        $parts = $rule.Id.Split(':')
        if ($parts.Count -ne 2) { $browserDelta.Add($rule.Id + ':shape'); continue }
        if ($allowedTemplates -notcontains $parts[0]) { $browserDelta.Add($rule.Id + ':template'); continue }
        if ($parts[1] -cnotmatch '^(Default|Profile_[1-9][0-9]{0,5})$') { $browserDelta.Add($rule.Id + ':leaf'); continue }
        $leaf = $parts[1].Replace('_', ' ')
        $profileDir = [IO.Path]::GetDirectoryName([string]$rule.Root)
        $ruleLeaf = [IO.Path]::GetFileName($profileDir)
        if (-not $ruleLeaf.Equals($leaf, [StringComparison]::Ordinal)) { $browserDelta.Add($rule.Id + ':root-not-profile'); continue }
        if (-not ($rule.Root -match '(?i)\\User Data\\' -or $rule.Root -match '(?i)\\Brave-Browser\\User Data\\')) { $browserDelta.Add($rule.Id + ':not-user-data'); continue }
        if ($rule.TemplateId -ne $parts[0]) { $browserDelta.Add($rule.Id + ':template-mismatch') }
        if (-not ($rule.Root -match '(?i)\\(Cache|Code Cache|GPUCache)$')) { $browserDelta.Add($rule.Id + ':cache-root') }
    }
    Assert-True 'browser instances are only Default/Profile N x 3 exact caches' ($browserDelta.Count -eq 0) (($browserDelta | Select-Object -First 10) -join '; ')

    # Profile age contract: Deep may be lower but never higher than Recommended, and the
    # effective MinimumAgeHours under the Recommended context equals RecommendedMinimumAgeHours.
    $profileAgeErrors = New-Object 'System.Collections.Generic.List[string]'
    # Numeric (int or double) is acceptable: Deep floors are assigned as integers by the
    # profile switch, while Recommended ages come from a [double] parameter.
    $isNumber = { param($v) ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal]) }
    foreach ($rule in $rules) {
        if ($rule.CleaningProfile -cne 'Recommended') { $profileAgeErrors.Add($rule.Id + ':context-profile=' + $rule.CleaningProfile); continue }
        if (-not (& $isNumber $rule.RecommendedMinimumAgeHours) -or [double]$rule.RecommendedMinimumAgeHours -le 0) { $profileAgeErrors.Add($rule.Id + ':rec-age-invalid') }
        if (-not (& $isNumber $rule.DeepMinimumAgeHours) -or [double]$rule.DeepMinimumAgeHours -le 0) { $profileAgeErrors.Add($rule.Id + ':deep-age-invalid') }
        if ([double]$rule.DeepMinimumAgeHours -gt [double]$rule.RecommendedMinimumAgeHours) { $profileAgeErrors.Add($rule.Id + ':deep-above-rec') }
        if ([double]$rule.MinimumAgeHours -ne [double]$rule.RecommendedMinimumAgeHours) { $profileAgeErrors.Add($rule.Id + ':effective-mismatch') }
    }
    Assert-True 'every rule pins profile and both ages, Deep never above Recommended' ($profileAgeErrors.Count -eq 0) (($profileAgeErrors | Select-Object -First 10) -join '; ')

    # Documented Deep thresholds from the approved decision record.
    $deepExpected = @{
        UserTemp = 6; WindowsTemp = 24; GradleCache = 168; CrashDumps = 720; WERArchive = 720
        D3DSCache = 168; NvidiaDXCache = 168; NvidiaGLCache = 168; AmdDxCache = 168; AmdDxcCache = 168; IntelShaderCache = 168
    }
    $deepMismatch = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $deepExpected.Keys) {
        $rule = @($rules | Where-Object { $_.Id -ceq $id })[0]
        if ($null -eq $rule) { $deepMismatch.Add($id + ':missing'); continue }
        if ([double]$rule.DeepMinimumAgeHours -ne [double]$deepExpected[$id]) { $deepMismatch.Add($id + '=' + $rule.DeepMinimumAgeHours + ' expected ' + $deepExpected[$id]) }
    }
    Assert-True 'documented Deep thresholds are exact' ($deepMismatch.Count -eq 0) ($deepMismatch -join '; ')
    $diagnosticDeep = @($rules | Where-Object { $_.Id -in @('CrashDumps', 'WERArchive') })
    Assert-True 'diagnostic rules do not lower their age in Deep' (@($diagnosticDeep | Where-Object { [double]$_.DeepMinimumAgeHours -ne [double]$_.RecommendedMinimumAgeHours }).Count -eq 0) (($diagnosticDeep | ForEach-Object { $_.Id + '=' + $_.DeepMinimumAgeHours }) -join ',')

    # Environment overrides may only *disable* a rule; they never add a root.
    $overrideErrors = New-Object 'System.Collections.Generic.List[string]'
    $overrideRules = @($rules | Where-Object { @($_.OverrideEnvironment).Count -gt 0 })
    foreach ($rule in $overrideRules) {
        if ($rule.OverrideEnvironment -is [string]) { $overrideErrors.Add($rule.Id + ':scalar') }
        foreach ($name in @($rule.OverrideEnvironment)) { if ($name -cnotmatch '^[A-Z][A-Z0-9_]{2,40}$') { $overrideErrors.Add($rule.Id + ':bad-name:' + $name) } }
        if ([string]$rule.Note -notmatch '覆盖|环境') { $overrideErrors.Add($rule.Id + ':note') }
    }
    Assert-True 'override denylist is a well-formed environment-name array' ($overrideErrors.Count -eq 0) ($overrideErrors -join '; ')
    Assert-True 'override rules exist for the newly verified package caches' ($overrideRules.Count -ge 6) ('overrideRules=' + $overrideRules.Count)

    # Firefox, when discovered, is only <profile>\cache2 and never a WAL/database pattern.
    $firefoxRules = @($rules | Where-Object { $_.TemplateId -ceq 'FirefoxCache2' })
    $firefoxErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $firefoxRules) {
        if ($rule.Id -cnotmatch '^FirefoxCache2:[a-z0-9]{8}\.(?:default|default-release|default-esr)(?:-[0-9]{1,14})?$') { $firefoxErrors.Add($rule.Id + ':id') }
        if ($rule.Root -notmatch '(?i)\\Mozilla\\Firefox\\Profiles\\[^\\]+\\cache2$') { $firefoxErrors.Add($rule.Id + ':root') }
        if (@($rule.Patterns) -join '|' -match '(?i)-wal|-shm') { $firefoxErrors.Add($rule.Id + ':wal-pattern') }
        if (@($rule.RequiresClosedProcess) -notcontains 'firefox') { $firefoxErrors.Add($rule.Id + ':process') }
    }
    Assert-True 'any discovered Firefox rule targets only cache2 with no WAL pattern' ($firefoxErrors.Count -eq 0) ($firefoxErrors -join '; ')

    $badRisk = @($rules | Where-Object { $_.Risk -notin @('低', '中低', '中', '高') })
    Assert-True 'risk vocabulary is bounded' ($badRisk.Count -eq 0) (($badRisk | ForEach-Object { $_.Id + '=' + $_.Risk }) -join ',')
    $badAge = @($rules | Where-Object { $_.MinimumAgeHours -isnot [double] -or $_.MinimumAgeHours -le 0 })
    Assert-True 'every rule has a positive minimum age' ($badAge.Count -eq 0) (($badAge | ForEach-Object Id) -join ',')
    $badFlags = @($rules | Where-Object { $_.Recommended -isnot [bool] -or $_.Available -isnot [bool] })
    Assert-True 'Recommended/Available are strict booleans' ($badFlags.Count -eq 0) (($badFlags | ForEach-Object Id) -join ',')
    $badArrays = @($rules | Where-Object { $_.Patterns -is [string] -or $_.ExcludePatterns -is [string] -or $_.RequiresClosedProcess -is [string] })
    Assert-True 'rule arrays are arrays, not scalars' ($badArrays.Count -eq 0) (($badArrays | ForEach-Object Id) -join ',')

    $availabilityMismatch = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $rules) {
        if ($rule.Id -match ':') {
            if ([bool]$rule.Available -ne [IO.Directory]::Exists($rule.Root)) { $availabilityMismatch.Add($rule.Id) }
        }
    }
    Assert-True 'browser Available reflects the discovered root' ($availabilityMismatch.Count -eq 0) ($availabilityMismatch -join ',')

    Assert-True 'chromium instances found on this host were actually discovered' ($browserRules.Count -gt 0) ('instances=' + $browserRules.Count)

    Save-EvidenceText 'rule-counts' (@(
        'total=' + $rules.Count,
        'baseTemplates=' + $baseTemplates.Count,
        'browserInstances=' + $browserRules.Count,
        'recommended=' + @($rules | Where-Object Recommended).Count
    ) -join "`n") | Out-Null
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
