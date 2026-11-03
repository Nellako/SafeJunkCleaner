#requires -Version 5.1
# N08: real three-tier cleanup against production-shaped synthetic layouts.
#
# What is real here:
#   * Rule definitions come from the production template table (real ids, patterns,
#     PresetLevel, per-tier ages, process lists, override lists). Only the ROOT is
#     re-anchored into this process' GUID sandbox, and only the process names are
#     swapped for an absent sentinel so a running Chrome/WebView2 cannot mask layout
#     behaviour. Section 2 separately evaluates the real process guards on the real rules.
#   * NewTeams is exercised through the three new exact WebView2 subroots, with sibling
#     business data (Service Worker / CacheStorage / WebStorage / Network / app files)
#     placed next to them and required to survive scan and clean.
#   * Each tier uses its own owned sandbox + context, because switching the profile of a
#     context invalidates its existing plans by design.
#   * Files are created, scanned and permanently deleted only inside the owned sandboxes.
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
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $windowsDir = [IO.Directory]::GetParent([Environment]::SystemDirectory).FullName
    $teamsRelative = 'Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw'

    # ---- 1. Production contract for the new Teams rules (no scanning) ----------
    $production = New-ProductionContextForInventory
    $prodRules = @(Get-SjcRules -Context $production)
    $teamsExpect = [ordered]@{
        NewTeamsCache     = @{ Sub = 'Cache';      Level = 'Medium'; Low = 168; Medium = 168; High = 0 }
        NewTeamsGPUCache  = @{ Sub = 'GPUCache';   Level = 'Medium'; Low = 168; Medium = 168; High = 0 }
        NewTeamsCodeCache = @{ Sub = 'Code Cache'; Level = 'High';   Low = 168; Medium = 168; High = 0 }
    }
    $teamsErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $teamsExpect.Keys) {
        $expected = $teamsExpect[$id]
        $matches = @($prodRules | Where-Object { $_.Id -ceq $id })
        if ($matches.Count -ne 1) { $teamsErrors.Add($id + ':count=' + $matches.Count); continue }
        $rule = $matches[0]
        $expectedRoot = Join-Path $local ($teamsRelative + '\' + $expected.Sub)
        if (-not ([string]$rule.Root).Equals($expectedRoot, [StringComparison]::OrdinalIgnoreCase)) { $teamsErrors.Add($id + ':root=' + $rule.Root + '/expected ' + $expectedRoot) }
        if ([string]$rule.PresetLevel -cne $expected.Level) { $teamsErrors.Add($id + ':level=' + $rule.PresetLevel) }
        foreach ($tier in @('Low', 'Medium', 'High')) {
            if ([double]$rule.($tier + 'MinimumAgeHours') -ne [double]$expected[$tier]) { $teamsErrors.Add($id + ':' + $tier + '=' + $rule.($tier + 'MinimumAgeHours')) }
        }
        if ((@($rule.Patterns) -join '|') -ne '*') { $teamsErrors.Add($id + ':patterns=' + (@($rule.Patterns) -join '|')) }
        foreach ($process in @('ms-teams', 'Teams', 'msedgewebview2')) {
            if (@($rule.RequiresClosedProcess) -notcontains $process) { $teamsErrors.Add($id + ':missing-process:' + $process) }
        }
        if ([string]$rule.Note -notmatch 'Service Worker' -or [string]$rule.Note -notmatch 'CacheStorage' -or [string]$rule.Note -notmatch 'WebStorage') { $teamsErrors.Add($id + ':note-missing-scope') }
        if (-not ([string]$rule.Group -ceq '应用缓存')) { $teamsErrors.Add($id + ':group=' + $rule.Group) }
    }
    Assert-True 'the three new Teams rules target only the official WebView2 subroots with approved levels/ages/processes' ($teamsErrors.Count -eq 0) ($teamsErrors -join '; ')
    Assert-True 'Teams rule root sits strictly below the WebView2 profile (never the app root)' (@($prodRules | Where-Object { $_.Id -like 'NewTeams*' -and ([string]$_.Root).ToLowerInvariant().EndsWith('\ebwebview\wv2profile_tfw\cache') -or ([string]$_.Root).ToLowerInvariant().EndsWith('\ebwebview\wv2profile_tfw\gpucache') -or ([string]$_.Root).ToLowerInvariant().EndsWith('\ebwebview\wv2profile_tfw\code cache') }).Count -eq 3) (($prodRules | Where-Object { $_.Id -like 'NewTeams*' } | ForEach-Object { $_.Id + '=' + $_.Root }) -join '; ')
    Assert-True 'Chrome Cache instances keep their real chrome process guard' (@($prodRules | Where-Object { $_.TemplateId -eq 'ChromeCache' }).Count -eq 0 -or @($prodRules | Where-Object { $_.TemplateId -eq 'ChromeCache' -and @($_.RequiresClosedProcess) -contains 'chrome' }).Count -gt 0) ''

    # ---- 2. RunningProcess is a real, live verdict for real roots -------------
    # Optional observation: if a real installed rule's application happens to be
    # running, evaluate its real guard too. The user may close the app at any time,
    # so a miss is an observation limitation, never a coverage gap: the mandatory
    # RunningProcess branch is exercised by the controlled guard below.
    $runningNames = @('chrome', 'msedge', 'ms-teams', 'Teams', 'msedgewebview2') | Where-Object { @([Diagnostics.Process]::GetProcessesByName($_)).Count -gt 0 }
    $guardRules = @($prodRules | Where-Object { $_.Available -and @($_.RequiresClosedProcess).Count -gt 0 -and @($_.RequiresClosedProcess | Where-Object { $runningNames -contains $_ }).Count -gt 0 })
    if ($guardRules.Count -gt 0) {
        $guardRule = $guardRules[0]
        Assert-True ('a running application is detected for ' + $guardRule.Id) (-not (Test-SjcProcessesClosed $guardRule)) (@($guardRule.RequiresClosedProcess) -join ',')
        Add-Limitation ('N08 在本机观察到运行中的应用：' + ($runningNames -join ',') + '；真实规则 ' + $guardRule.Id + ' 的进程闸门返回"未关闭"。本用例不扫描真实缓存根。')
    }
    else {
        Add-Limitation 'N08 可选实测：本机没有"已安装且要求关闭进程"的真实规则命中正在运行的应用（用户可随时关闭应用，属环境波动）；RunningProcess 必需分支由下一段的受控真实进程守卫覆盖，未计为覆盖缺口。'
    }

    # Mandatory RunningProcess coverage, owned and deterministic. The controllable
    # double is the test process' own live ProcessName (PID $PID), which is harmless
    # and never started/stopped by this case. Rule objects are copies of the
    # production template table (ids/patterns/levels/ages unchanged); only the
    # RequiresClosedProcess field is mapped onto the double, and ProcessPolicy is
    # retained, so the production guard implementation is the code under test.
    $livePid = $PID
    $liveName = [Diagnostics.Process]::GetProcessById($livePid).ProcessName
    $guardTemplate = @($prodRules | Where-Object { $_.Id -ceq 'NewTeamsCache' })[0]
    Assert-True 'the controlled guard rule comes from the production template table' ($null -ne $guardTemplate -and [string]$guardTemplate.ProcessPolicy -ceq 'NewTeamsWebView2') ([string]$guardTemplate.ProcessPolicy)
    $runningRule = $guardTemplate.PSObject.Copy()
    $runningRule.RequiresClosedProcess = @($liveName)
    $runningGuard = Get-SjcProcessGuard $runningRule
    Assert-True 'a live owned process (current PowerShell ProcessName) yields Closed=false/RunningProcess' ((-not [bool]$runningGuard.Closed) -and [string]$runningGuard.Status -ceq 'RunningProcess') ('closed=' + [string]$runningGuard.Closed + '; status=' + [string]$runningGuard.Status + '; note=' + [string]$runningGuard.Note)
    Assert-True 'the RunningProcess guard result carries a conservative Note' (-not [string]::IsNullOrWhiteSpace([string]$runningGuard.Note)) ([string]$runningGuard.Note)
    $absentRule = $guardTemplate.PSObject.Copy()
    $absentRule.RequiresClosedProcess = @('SjcNoSuchProcess_' + [guid]::NewGuid().ToString('N'))
    $absentGuard = Get-SjcProcessGuard $absentRule
    Assert-True 'an absent process yields Closed=true/Success' ([bool]$absentGuard.Closed -and [string]$absentGuard.Status -ceq 'Success') ('closed=' + [string]$absentGuard.Closed + '; status=' + [string]$absentGuard.Status)
    $unknownRule = $guardTemplate.PSObject.Copy()
    $unknownRule.ProcessPolicy = 'FuturePolicy'
    $unknownGuard = Get-SjcProcessGuard $unknownRule
    Assert-True 'an unknown process policy stays Closed=false/ProcessGuardUnknown' ((-not [bool]$unknownGuard.Closed) -and [string]$unknownGuard.Status -ceq 'ProcessGuardUnknown') ('closed=' + [string]$unknownGuard.Closed + '; status=' + [string]$unknownGuard.Status)

    # The three new Teams rules must skip whenever any of ms-teams / Teams /
    # msedgewebview2 is running. Each production guard position is exercised with the
    # same controllable double (the live PowerShell process name), so no real
    # application is started or stopped. Layout/roots/preset level still come from the
    # production Teams rules; WebView2 ownership classification belongs to N09.
    $teamsProcessNames = @('ms-teams', 'Teams', 'msedgewebview2')
    $teamsGateErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($teamsId in @('NewTeamsCache', 'NewTeamsGPUCache', 'NewTeamsCodeCache')) {
        $productionTeamsRule = @($prodRules | Where-Object { $_.Id -ceq $teamsId })[0]
        foreach ($processName in $teamsProcessNames) {
            $gateRule = $productionTeamsRule.PSObject.Copy()
            # Exercise each production guard position independently with one live process.
            $gateRule.RequiresClosedProcess = @($productionTeamsRule.RequiresClosedProcess | ForEach-Object {
                if ($_ -ceq $processName) { $liveName }
                else { 'SjcAbsent_' + [guid]::NewGuid().ToString('N') }
            })
            $gateResult = Get-SjcProcessGuard $gateRule
            if ([bool]$gateResult.Closed -or [string]$gateResult.Status -cne 'RunningProcess') { $teamsGateErrors.Add($teamsId + ':' + $processName + ':closed=' + [string]$gateResult.Closed + ',status=' + [string]$gateResult.Status) }
        }
        # Control: an absent sentinel must let the same rule through (the gate is real).
        $freeRule = $productionTeamsRule.PSObject.Copy()
        $freeRule.RequiresClosedProcess = @('SjcNoSuchProcess_' + [guid]::NewGuid().ToString('N'))
        $freeGuard = Get-SjcProcessGuard $freeRule
        if (-not [bool]$freeGuard.Closed -or [string]$freeGuard.Status -cne 'Success') { $teamsGateErrors.Add($teamsId + ':sentinel-not-success:' + [string]$freeGuard.Status) }
        $realNamesOk = @($productionTeamsRule.RequiresClosedProcess | Where-Object { $teamsProcessNames -contains $_ }).Count -eq 3
        if (-not $realNamesOk) { $teamsGateErrors.Add($teamsId + ':production-names=' + (@($productionTeamsRule.RequiresClosedProcess) -join '/')) }
    }
    Assert-True 'a running ms-teams/Teams/msedgewebview2 process blocks every new Teams rule (controllable double)' ($teamsGateErrors.Count -eq 0) (($teamsGateErrors | Select-Object -First 6) -join '; ')
    Add-Limitation ('N08 的进程跳过分支用当前 PowerShell 的 ProcessName ' + $liveName + '（PID ' + $livePid + '）作为受控测试替身，映射字段为 RequiresClosedProcess，ProcessPolicy 保留生产值；未启动或结束任何真实 Teams/WebView2/浏览器应用。')

    # ---- 3. Layout builder (real templates, sandbox-anchored roots) -----------
    $originalRules = ${function:Get-SjcRules}
    $script:n08OriginalRules = $originalRules
    $script:n08RuleTables = @{}
    function Get-SjcRules {
        param($Context)
        $key = [string]$Context.StateRoot
        if ($script:n08RuleTables.ContainsKey($key)) { return $script:n08RuleTables[$key] }
        & $script:n08OriginalRules -Context $Context
    }

    $templates = @('UserTemp', 'ChromeCache', 'WindowsTemp', 'D3DSCache', 'NpmCache', 'NewTeamsCache', 'NewTeamsGPUCache', 'NewTeamsCodeCache')
    $buildLayout = {
        param([string]$Tier)
        $sandbox = New-OwnedSandbox
        $context = New-SjcContext -TestRoot $sandbox.Root -CleaningProfile $Tier
        $mirror = Join-Path $sandbox.Root 'mirror'
        $mirrorLocal = Join-Path $mirror 'Local'
        $mirrorWindows = Join-Path $mirror 'Windows'
        $rules = New-Object 'System.Collections.Generic.List[object]'
        $errors = New-Object 'System.Collections.Generic.List[string]'
        foreach ($template in $templates) {
            $source = @($prodRules | Where-Object { $_.TemplateId -ceq $template } | Sort-Object { $_.Id } | Select-Object -First 1)
            if ($source.Count -ne 1) { $errors.Add($template + ':missing'); continue }
            $rule = $source[0].PSObject.Copy()
            $rule.CleaningProfile = $Tier
            $rule.MinimumAgeHours = $rule.($Tier + 'MinimumAgeHours')
            $root = [string]$rule.Root
            if ($root.StartsWith($local + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $rule.Root = Join-Path $mirrorLocal $root.Substring($local.Length + 1)
            }
            elseif ($root.StartsWith($windowsDir + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $rule.Root = Join-Path $mirrorWindows $root.Substring($windowsDir.Length + 1)
            }
            else { $errors.Add($template + ':unanchored:' + $root); continue }
            # Neutralize only the process gate; the real gate is evaluated in section 2.
            $rule.RequiresClosedProcess = @('SjcNoSuchProcess_' + ([guid]::NewGuid().ToString('N')))
            $rule.Available = $false
            $rules.Add($rule)
        }
        $script:n08RuleTables[[string]$context.StateRoot] = $rules.ToArray()
        [pscustomobject]@{ Tier = $Tier; Sandbox = $sandbox; Context = $context; Mirror = $mirror; MirrorLocal = $mirrorLocal; Rules = $rules.ToArray(); Errors = $errors.ToArray() }
    }

    $tierLayouts = @{}
    $layoutErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $layout = & $buildLayout $tier
        $tierLayouts[$tier] = $layout
        foreach ($e in $layout.Errors) { $layoutErrors.Add($tier + ':' + $e) }
        $byId = @{}
        foreach ($rule in $layout.Rules) { $byId[[string]$rule.Id] = $rule }
        Assert-True ($tier + ' layout mirrors all eight production templates') ($layout.Rules.Count -eq 8) ([string]$layout.Rules.Count)
        $layout | Add-Member -NotePropertyName RuleById -NotePropertyValue $byId
    }
    Assert-True 'every layout rule maps onto its sandbox mirror with its production root shape' ($layoutErrors.Count -eq 0) ($layoutErrors -join '; ')

    # Common assertion: the Teams roots mirror the WebView2 profile subroots.
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $l = $tierLayouts[$tier]
        $c = $l.RuleById['NewTeamsCache']
        $g = $l.RuleById['NewTeamsGPUCache']
        $k = $l.RuleById['NewTeamsCodeCache']
        Assert-True ($tier + ' NewTeams roots mirror the WebView2 profile subroots') ($c.Root -like ('*' + $teamsRelative + '\Cache') -and $g.Root -like ('*' + $teamsRelative + '\GPUCache') -and $k.Root -like ('*' + $teamsRelative + '\Code Cache')) ($c.Root + ' | ' + $g.Root + ' | ' + $k.Root)
    }

    # ---- 4. Fixtures: per-tier expected sets + shared sibling business data ---
    # Common file names; ages are 200h (>= every Low/Medium age, > High's 6/24/168 where
    # relevant) and 400h where a High threshold of 720 would otherwise exclude the file.
    $names = [ordered]@{
        UserTemp          = 'sjc-usertemp.tmp'
        ChromeCache       = 'sjc-chrome-cache.bin'
        WindowsTemp       = 'sjc-windowstemp.tmp'
        Shader            = 'sjc-shader-cache.bin'
        TeamsCache        = 'sjc-teams-cache.bin'
        TeamsGpu          = 'sjc-teams-gpu.bin'
        TeamsCode         = 'sjc-teams-code.bin'
        Npm               = 'sjc-npm-content.bin'
    }
    $expectByTier = @{
        Low    = @('UserTemp', 'ChromeCache')
        Medium = @('UserTemp', 'ChromeCache', 'WindowsTemp', 'Shader', 'TeamsCache', 'TeamsGpu')
        High   = @('UserTemp', 'ChromeCache', 'WindowsTemp', 'Shader', 'TeamsCache', 'TeamsGpu', 'TeamsCode', 'Npm', 'RecentTemp', 'RecentBrowser')
    }
    $tierState = @{}
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $l = $tierLayouts[$tier]
        $paths = @{}
        $paths['UserTemp'] = Join-Path $l.RuleById['UserTemp'].Root $names['UserTemp']
        $paths['ChromeCache'] = Join-Path $l.RuleById['ChromeCache:Default'].Root $names['ChromeCache']
        $paths['WindowsTemp'] = Join-Path $l.RuleById['WindowsTemp'].Root $names['WindowsTemp']
        $paths['Shader'] = Join-Path $l.RuleById['D3DSCache'].Root $names['Shader']
        $paths['TeamsCache'] = Join-Path $l.RuleById['NewTeamsCache'].Root $names['TeamsCache']
        $paths['TeamsGpu'] = Join-Path $l.RuleById['NewTeamsGPUCache'].Root $names['TeamsGpu']
        $paths['TeamsCode'] = Join-Path $l.RuleById['NewTeamsCodeCache'].Root $names['TeamsCode']
        $paths['Npm'] = Join-Path $l.RuleById['NpmCache'].Root $names['Npm']
        foreach ($key in $paths.Keys) { New-TestFile -Path $paths[$key] -Bytes 128 -AgeHours 200 | Out-Null }
        $paths['RecentTemp'] = Join-Path $l.RuleById['UserTemp'].Root 'sjc-recent-temp.tmp'
        $paths['RecentBrowser'] = Join-Path $l.RuleById['ChromeCache:Default'].Root 'sjc-recent-browser.bin'
        New-TestFile -Path $paths['RecentTemp'] -Bytes 128 -AgeHours 12 | Out-Null
        New-TestFile -Path $paths['RecentBrowser'] -Bytes 128 -AgeHours 2 | Out-Null
        Assert-Equal ($tier + ' mirrored rules carry their actual tier') 0 (@($l.Rules | Where-Object { $_.CleaningProfile -cne $tier -or $_.MinimumAgeHours -ne $_.($tier + 'MinimumAgeHours') }).Count)

        $teamsProfile = [IO.Path]::GetDirectoryName([string]$l.RuleById['NewTeamsCache'].Root)
        $business = @(
            (Join-Path $teamsProfile 'Service Worker\sw.js'),
            (Join-Path $teamsProfile 'CacheStorage\offline.bin'),
            (Join-Path $teamsProfile 'WebStorage\local.leveldb'),
            (Join-Path $teamsProfile 'Network\Cookies-wal'),
            (Join-Path $teamsProfile 'Network\Preferences'),
            (Join-Path (Split-Path -Parent (Split-Path -Parent $teamsProfile)) 'MSTeams\settings.json'),
            (Join-Path $l.MirrorLocal 'Documents\sjc-business.docx'),
            (Join-Path $l.MirrorLocal 'Documents\sjc-business.xlsx'),
            (Join-Path $l.RuleById['UserTemp'].Root 'sjc-business.sqlite-wal')
        )
        foreach ($path in $business) { New-TestFile -Path $path -Bytes 64 -AgeHours 500 | Out-Null }
        $tierState[$tier] = [pscustomobject]@{ Layout = $l; Paths = $paths; Business = $business; TeamsProfile = $teamsProfile; Scan = $null; Task = $null }
    }
    # Non-target business data must never be in a tier's expected set.
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $expectedPaths = @($expectByTier[$tier] | ForEach-Object { $tierState[$tier].Paths[$_] })
        Assert-Equal ($tier + ' expected fixture count') (@($expectByTier[$tier]).Count) $expectedPaths.Count
        Assert-True ($tier + ' business files are distinct from the expected fixtures') (@($tierState[$tier].Business | Where-Object { $expectedPaths -contains $_ }).Count -eq 0) ''
    }

    # ---- 5. Tier progression: candidate sets and bytes grow -------------------
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $s = $tierState[$tier]
        $presetIds = @(Get-SjcPresetRuleIds -Context $s.Layout.Context -CleaningProfile $tier)
        $task = New-SjcTaskDirectory -Context $s.Layout.Context
        $scan = Invoke-SjcScan -Context $s.Layout.Context -RuleIds $presetIds -TaskDirectory $task -CustomEnabled $false
        $s.Scan = $scan; $s.Task = $task
        Assert-Equal ($tier + ' preset scan succeeds') 'Success' ([string]$scan.Status) ([string]$scan.Error)
        Assert-True ($tier + ' preset scan reports CustomEnabled=false') ($scan.CustomEnabled -eq $false) ([string]$scan.CustomEnabled)
        $candidatePaths = @(Get-CandidateLines $scan.PlanPath | ForEach-Object { [string]$_.Path })
        $expectedPaths = @($expectByTier[$tier] | ForEach-Object { $s.Paths[$_] })
        $missing = @($expectedPaths | Where-Object { $candidatePaths -notcontains $_ })
        $unexpected = @($candidatePaths | Where-Object { $expectedPaths -notcontains $_ })
        Assert-True ($tier + ' scan returns exactly the tier fixtures') ($missing.Count -eq 0 -and $unexpected.Count -eq 0) ('missing=' + ($missing -join ',') + '; unexpected=' + ($unexpected -join ','))
        Assert-Equal ($tier + ' candidate count matches the expected set') $expectedPaths.Count ([int64]$scan.CandidateCount)
        Assert-Equal ($tier + ' candidate bytes match the fixture sizes') ([int64]($expectedPaths.Count * 128)) ([int64]$scan.CandidateBytes)
        Assert-True ($tier + ' scan never returns sibling business data') (@($candidatePaths | Where-Object { $s.Business -contains $_ }).Count -eq 0) (@($candidatePaths | Where-Object { $s.Business -contains $_ }) -join ',')
        if ($tier -ne 'High') {
            Assert-True ($tier + ' excludes the High-only Teams Code Cache fixture') ($candidatePaths -notcontains $s.Paths['TeamsCode']) ''
            Assert-True ($tier + ' excludes the High-only npm fixture') ($candidatePaths -notcontains $s.Paths['Npm']) ''
        }
    }
    $counts = @($tierState['Low'].Scan.CandidateCount, $tierState['Medium'].Scan.CandidateCount, $tierState['High'].Scan.CandidateCount)
    $bytes = @([int64]$tierState['Low'].Scan.CandidateBytes, [int64]$tierState['Medium'].Scan.CandidateBytes, [int64]$tierState['High'].Scan.CandidateBytes)
    Assert-True 'candidate count grows strictly Low<Medium<High' ($counts[0] -lt $counts[1] -and $counts[1] -lt $counts[2]) ($counts -join ',')
    Assert-True 'candidate bytes grow strictly Low<Medium<High' ($bytes[0] -lt $bytes[1] -and $bytes[1] -lt $bytes[2]) ($bytes -join ',')
    $mediumCategories = @(@($tierState['Medium'].Scan.Categories) | ForEach-Object { [string]$_.RuleId })
    $highCategories = @(@($tierState['High'].Scan.Categories) | ForEach-Object { [string]$_.RuleId })
    Assert-True 'Medium scan has no Teams Code Cache category' ($mediumCategories -notcontains 'NewTeamsCodeCache') ($mediumCategories -join ',')
    Assert-True 'High scan includes the Teams Code Cache category' ($highCategories -contains 'NewTeamsCodeCache') ''
    $teamsCodeCategory = @(@($tierState['High'].Scan.Categories) | Where-Object { $_.RuleId -ceq 'NewTeamsCodeCache' })[0]
    Assert-Equal 'Teams Code Cache category found its fixture' 1 ([int64]$teamsCodeCategory.Count) ([string]$teamsCodeCategory.Status)

    # ---- 6. Real cleanup per tier; only that tier's fixtures disappear --------
    foreach ($tier in @('Low', 'Medium', 'High')) {
        $s = $tierState[$tier]
        $clean = Invoke-SjcClean -Context $s.Layout.Context -TaskDirectory $s.Task -RecycleMode $false -CustomEnabled $false
        Assert-Equal ($tier + ' clean succeeds') 'Success' ([string]$clean.Status) ([string]$clean.Error)
        Assert-Equal ($tier + ' clean deleted exactly its fixtures') (@($expectByTier[$tier]).Count) ([int64]$clean.Deleted) ([string]$clean.Deleted)
        $survivors = @($expectByTier[$tier] | ForEach-Object { $s.Paths[$_] } | Where-Object { [IO.File]::Exists($_) })
        Assert-Equal ($tier + ' clean removed every tier fixture') 0 $survivors.Count ($survivors -join ',')
        $outsideExpected = @($s.Paths.Keys | Where-Object { $expectByTier[$tier] -notcontains $_ } | ForEach-Object { $s.Paths[$_] } | Where-Object { -not [IO.File]::Exists($_) })
        Assert-Equal ($tier + ' clean left files outside the tier preset untouched') 0 $outsideExpected.Count ($outsideExpected -join ',')
        $businessGone = @($s.Business | Where-Object { -not [IO.File]::Exists($_) })
        Assert-Equal ($tier + ' clean left all sibling business data untouched') 0 $businessGone.Count ($businessGone -join ',')
        Assert-True ($tier + ' Teams profile directory survives') ([IO.Directory]::Exists($s.TeamsProfile)) $s.TeamsProfile
        Assert-True ($tier + ' Teams Service Worker / CacheStorage / WebStorage / Network survive') ((Test-Path (Join-Path $s.TeamsProfile 'Service Worker\sw.js')) -and (Test-Path (Join-Path $s.TeamsProfile 'CacheStorage\offline.bin')) -and (Test-Path (Join-Path $s.TeamsProfile 'WebStorage\local.leveldb')) -and (Test-Path (Join-Path $s.TeamsProfile 'Network\Cookies-wal')) -and (Test-Path (Join-Path $s.TeamsProfile 'Network\Preferences'))) ''
    }

    # ---- 7. Used plans cannot be replayed; late files stay untouched ----------
    $low = $tierState['Low']
    New-TestFile -Path $low.Paths['Npm'] -Bytes 96 -AgeHours 300 | Out-Null
    $lowReplay = Invoke-SjcClean -Context $low.Layout.Context -TaskDirectory $low.Task -RecycleMode $false -CustomEnabled $false
    Assert-True 'a used Low plan cannot be replayed' ($lowReplay.Status -eq 'Failed' -and [int64]$lowReplay.Deleted -eq 0) ('status=' + $lowReplay.Status + '; deleted=' + $lowReplay.Deleted + '; error=' + $lowReplay.Error)
    Assert-True 'a High-only file created after the Low scan survives' ([IO.File]::Exists($low.Paths['Npm'])) ''

    [void](Save-Evidence 'tier-layout' ([pscustomobject]@{
        Counts = [ordered]@{ Low = $counts[0]; Medium = $counts[1]; High = $counts[2] }
        Bytes = [ordered]@{ Low = $bytes[0]; Medium = $bytes[1]; High = $bytes[2] }
        TeamsProfiles = @($tierState.Values | ForEach-Object { $_.TeamsProfile })
        BusinessSurvivors = @($tierState.Values | ForEach-Object { @($_.Business | Where-Object { [IO.File]::Exists($_) }) })
    }))
    Add-Limitation 'N08 的布局规则表以生产模板为源（ID/Patterns/PresetLevel/三档年龄/根相对布局均取自 Get-SjcRules），仅把根重定位到 GUID 沙箱镜像并把进程闸门替换为不存在的哨兵进程；生产进程闸门在真实规则上单独求值（第 2 节），未扫描或删除任何真实缓存。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($null -ne $originalRules) { ${function:Get-SjcRules} = $originalRules }
}
Complete-TestCase
