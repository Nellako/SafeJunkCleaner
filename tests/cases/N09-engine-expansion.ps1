#requires -Version 5.1
# N09: v0.12 engine expansion contract.
#   * High=0 is granted ONLY by the reviewed exact pure-cache template allow-list, and
#     zero age never bypasses the future-time, read-only, link, identity or path gates.
#   * Teams WebView2 ownership is classified from a read-only parent chain: a provably
#     unrelated host no longer blocks the whole class, unknown stays conservatively
#     skipped, and nothing is started, finished or read from command lines.
# Process records are mocked in-process; no real application is started or stopped and
# no production cache root is scanned.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$originalRules = $null
$originalProcessRecord = $null
try {
    # ---- 1. Exact PureCache allow-list --------------------------------------
    $pureCacheTemplates = @(
        'ChromeCache', 'ChromeCodeCache', 'ChromeGPUCache', 'EdgeCache', 'EdgeCodeCache', 'EdgeGPUCache',
        'BraveCache', 'BraveCodeCache', 'BraveGPUCache', 'FirefoxCache2',
        'VSCodeCache', 'VSCodeCodeCache', 'NewTeamsCache', 'NewTeamsCodeCache', 'NewTeamsGPUCache', 'TeamsGPUCache'
    ) | Sort-Object
    $probeTemplates = @(
        'ChromeCache', 'ChromeCodeCache', 'ChromeGPUCache', 'EdgeCache', 'EdgeCodeCache', 'EdgeGPUCache',
        'BraveCache', 'BraveCodeCache', 'BraveGPUCache', 'FirefoxCache2',
        'VSCodeCache', 'VSCodeCodeCache', 'NewTeamsCache', 'NewTeamsCodeCache', 'NewTeamsGPUCache', 'TeamsGPUCache',
        'UserTemp', 'WindowsTemp', 'GradleCache', 'CrashDumps', 'WERArchive', 'NpmCache', 'NuGetCache',
        'PipHttpCache', 'PipHttpV2Cache', 'PipWheelCache', 'YarnCache', 'GoBuildCache',
        'D3DSCache', 'NvidiaDXCache', 'NvidiaGLCache', 'AmdDxCache', 'AmdDxcCache', 'IntelShaderCache',
        'TeamsCache', 'SteamHtmlCache', 'ExplorerThumbCache', 'ExplorerIconCache', 'SandboxOld', 'SandboxLog'
    ) | Sort-Object -Unique
    $pureSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($id in $pureCacheTemplates) { [void]$pureSet.Add($id) }
    $whitelistErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($template in $probeTemplates) {
        $policy = [string](Get-SjcTemplateAgePolicy $template)
        $expected = if ($pureSet.Contains($template)) { 'PureCache' } else { 'AgeBounded' }
        if ($policy -cne $expected) { $whitelistErrors.Add($template + '=' + $policy + '/expected ' + $expected) }
    }
    Assert-True 'age policy is granted only by the exact documented pure-cache template ids' ($whitelistErrors.Count -eq 0) ($whitelistErrors -join '; ')
    # Names/groups that merely contain "Cache" must not earn the waiver.
    foreach ($decoy in @('Cache', 'TeamsCacheExtra', 'MyCache', 'ChromeCachex', 'CacheGPUCache')) {
        Assert-Equal ('decoy template ' + $decoy + ' stays AgeBounded') 'AgeBounded' ([string](Get-SjcTemplateAgePolicy $decoy))
    }
    Assert-Equal 'the pure-cache allow-list has exactly 16 templates' 16 $pureCacheTemplates.Count ''

    $production = New-ProductionContextForInventory
    $prodRules = @(Get-SjcRules -Context $production)
    $policyMismatch = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rule in $prodRules) {
        $expected = if ($pureSet.Contains([string]$rule.TemplateId)) { 'PureCache' } else { 'AgeBounded' }
        if ([string]$rule.AgePolicy -cne $expected) { $policyMismatch.Add($rule.Id + '=' + $rule.AgePolicy + '/expected ' + $expected) }
        if ($expected -ceq 'PureCache' -and [double]$rule.HighMinimumAgeHours -ne 0) { $policyMismatch.Add($rule.Id + ':pure-high=' + $rule.HighMinimumAgeHours) }
        if ($expected -ceq 'AgeBounded' -and [double]$rule.HighMinimumAgeHours -le 0) { $policyMismatch.Add($rule.Id + ':bounded-high=' + $rule.HighMinimumAgeHours) }
        # The factory-level guard must accept the production table as-is.
        try { Assert-SjcRuleAgePolicy $rule } catch { $policyMismatch.Add($rule.Id + ':policy-threw=' + $_.Exception.Message) }
    }
    Assert-True 'production rules carry the exact policy and age shape and pass the factory guard' ($policyMismatch.Count -eq 0) (($policyMismatch | Select-Object -First 10) -join '; ')

    # ---- 2. Tampered definitions are refused --------------------------------
    $baseRule = New-SjcRule -Id 'N09Base' -TemplateId 'NpmCache' -Name 'n09' -Group 'test' -Root 'C:\N09ContractProbe' -MinimumAgeHours 24
    $badZero = $baseRule.PSObject.Copy(); $badZero.AgePolicy = 'PureCache'; $badZero.HighMinimumAgeHours = 0
    Assert-Throws 'a non-whitelisted template cannot claim PureCache to reach zero' { Assert-SjcRuleAgePolicy $badZero } '年龄策略'
    $badName = $baseRule.PSObject.Copy(); $badName.TemplateId = 'SandboxOld'; $badName.AgePolicy = 'PureCache'; $badName.HighMinimumAgeHours = 0
    Assert-Throws 'a synthetic template cannot claim PureCache to reach zero' { Assert-SjcRuleAgePolicy $badName } '年龄策略'
    $badLow = $baseRule.PSObject.Copy(); $badLow.AgePolicy = 'AgeBounded'; $badLow.LowMinimumAgeHours = 0
    Assert-Throws 'zero is refused for the Low tier even on a pure cache' { Assert-SjcRuleAgePolicy $badLow } '零小时'
    $badMedium = $baseRule.PSObject.Copy(); $badMedium.AgePolicy = 'PureCache'; $badMedium.TemplateId = 'VSCodeCache'; $badMedium.MediumMinimumAgeHours = 0; $badMedium.HighMinimumAgeHours = 0
    Assert-Throws 'zero is refused for the Medium tier even on a pure cache' { Assert-SjcRuleAgePolicy $badMedium } '零小时'
    $badNegative = $baseRule.PSObject.Copy(); $badNegative.AgePolicy = 'PureCache'; $badNegative.TemplateId = 'VSCodeCache'; $badNegative.HighMinimumAgeHours = -1
    Assert-Throws 'a negative High age is refused' { Assert-SjcRuleAgePolicy $badNegative } '负数'
    $goodPure = $baseRule.PSObject.Copy(); $goodPure.TemplateId = 'VSCodeCache'; $goodPure.AgePolicy = 'PureCache'; $goodPure.HighMinimumAgeHours = 0
    $goodOk = $true; $why = ''
    try { Assert-SjcRuleAgePolicy $goodPure } catch { $goodOk = $false; $why = $_.Exception.Message }
    Assert-True 'a reviewed pure cache with High=0 is accepted' $goodOk $why

    # ---- 3. Zero age does not bypass the other file gates -------------------
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($files)
    $zeroRule = [pscustomobject][ordered]@{
        Id = 'N09Pure'; TemplateId = 'VSCodeCache'; Name = 'n09 pure'; Group = 'test'; Risk = '中'; Recommended = $false
        Root = $files; Patterns = @('*.tmp'); ExcludePatterns = @(); MinimumAgeHours = 0
        LowMinimumAgeHours = 1; MediumMinimumAgeHours = 1; HighMinimumAgeHours = 0; PresetLevel = 'Medium'
        CleaningProfile = 'High'; AgePolicy = 'PureCache'; ProcessPolicy = 'NameGuard'; AuthorizationId = ''
        AuthorizationBinding = ''; DiscoveryAdapter = ''; DiscoverySource = ''; DiscoverySourceValue = ''
        RootDirectoryIdentity = ''; RequiresClosedProcess = @(); OverrideEnvironment = @(); Available = $true; Note = ''
    }
    $freshPath = Join-Path $files 'n09-fresh.tmp'; New-TestFile -Path $freshPath -Bytes 8 -AgeHours 0 | Out-Null
    $futurePath = Join-Path $files 'n09-future.tmp'; New-TestFile -Path $futurePath -Bytes 8 -AgeHours 0 | Out-Null
    [IO.File]::SetLastWriteTimeUtc($futurePath, [datetime]::UtcNow.AddHours(2))
    $readOnlyPath = Join-Path $files 'n09-readonly.tmp'; New-TestFile -Path $readOnlyPath -Bytes 8 -AgeHours 0 -ReadOnly | Out-Null
    $walPath = Join-Path $files 'n09-x.sqlite-wal'; New-TestFile -Path $walPath -Bytes 8 -AgeHours 0 | Out-Null
    $outsidePath = Join-Path $sandbox.Root 'n09-outside.tmp'; New-TestFile -Path $outsidePath -Bytes 8 -AgeHours 0 | Out-Null
    $now = [datetime]::UtcNow
    $freshInfo = [IO.FileInfo]::new($freshPath); $futureInfo = [IO.FileInfo]::new($futurePath)
    $readOnlyInfo = [IO.FileInfo]::new($readOnlyPath); $walInfo = [IO.FileInfo]::new($walPath)
    $outsideInfo = [IO.FileInfo]::new($outsidePath)
    Assert-True '0-hour pure cache accepts a file written just now' (Test-SjcRuleFile $zeroRule $freshInfo $now) $freshPath
    Assert-True '0-hour pure cache still rejects a future timestamp' (-not (Test-SjcRuleFile $zeroRule $futureInfo $now)) $futurePath
    Assert-True '0-hour pure cache still rejects a read-only file' (-not (Test-SjcRuleFile $zeroRule $readOnlyInfo $now)) $readOnlyPath
    Assert-True '0-hour pure cache still rejects a WAL name' (-not (Test-SjcRuleFile $zeroRule $walInfo $now)) $walPath
    Assert-True '0-hour pure cache still rejects a path outside its root' (-not (Test-SjcRuleFile $zeroRule $outsideInfo $now)) $outsidePath

    # A real High-profile scan through the production engine with a pure-cache rule:
    # only writable, non-future files become candidates even though the age is zero.
    $originalRules = ${function:Get-SjcRules}
    $script:n09Files = $files
    $script:n09Active = $true
    function Get-SjcRules {
        param($Context)
        $stateRoot = Get-Variable -Scope Script -Name n09StateRoot -ValueOnly -ErrorAction SilentlyContinue
        $linkStateRoot = Get-Variable -Scope Script -Name n09LinkStateRoot -ValueOnly -ErrorAction SilentlyContinue
        $linkFiles = Get-Variable -Scope Script -Name n09LinkFiles -ValueOnly -ErrorAction SilentlyContinue
        if ($script:n09Active -and $linkStateRoot -and $linkFiles -and [string]$Context.StateRoot -eq [string]$linkStateRoot) {
            $linkRule = New-SjcRule -Id 'N09Links' -TemplateId 'VSCodeCache' -Name 'n09 links' -Group 'test' -Root $linkFiles -Patterns @('*.tmp') -MinimumAgeHours 24
            $linkRule.HighMinimumAgeHours = 0; $linkRule.LowMinimumAgeHours = 1; $linkRule.MediumMinimumAgeHours = 1; $linkRule.MinimumAgeHours = 0
            $linkRule.AgePolicy = 'PureCache'; $linkRule.PresetLevel = 'Medium'; $linkRule.CleaningProfile = 'High'
            return @($linkRule)
        }
        if ($script:n09Active -and $stateRoot -and [string]$Context.StateRoot -eq [string]$stateRoot) {
            $rule = New-SjcRule -Id 'N09Pure' -TemplateId 'VSCodeCache' -Name 'n09 pure' -Group 'test' -Root $script:n09Files -Patterns @('*.tmp') -MinimumAgeHours 24
            $rule.HighMinimumAgeHours = 0; $rule.LowMinimumAgeHours = 1; $rule.MediumMinimumAgeHours = 1; $rule.MinimumAgeHours = 0
            $rule.AgePolicy = 'PureCache'; $rule.PresetLevel = 'Medium'; $rule.CleaningProfile = 'High'
            return @($rule)
        }
        & $script:n09OriginalRules -Context $Context
    }
    $script:n09OriginalRules = $originalRules
    $highSandbox = New-OwnedSandbox
    $highContext = New-SjcContext -TestRoot $highSandbox.Root -CleaningProfile 'High'
    $script:n09StateRoot = [string]$highContext.StateRoot
    $script:n09Files = Join-Path $highSandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($script:n09Files)
    New-TestFile -Path (Join-Path $script:n09Files 'zero-now.tmp') -Bytes 16 -AgeHours 0 | Out-Null
    New-TestFile -Path (Join-Path $script:n09Files 'zero-old.tmp') -Bytes 16 -AgeHours 96 | Out-Null
    $hf = Join-Path $script:n09Files 'zero-future.tmp'; New-TestFile -Path $hf -Bytes 16 -AgeHours 0 | Out-Null
    [IO.File]::SetLastWriteTimeUtc($hf, [datetime]::UtcNow.AddHours(2))
    New-TestFile -Path (Join-Path $script:n09Files 'zero-readonly.tmp') -Bytes 16 -AgeHours 96 -ReadOnly | Out-Null
    $highTask = New-SjcTaskDirectory -Context $highContext
    $highScan = Invoke-SjcScan -Context $highContext -RuleIds @('N09Pure') -TaskDirectory $highTask -CustomEnabled $true
    [void](Save-Evidence 'n09-high-scan' $highScan)
    Assert-Equal 'a real High pure-cache scan succeeds' 'Success' $highScan.Status $highScan.Error
    $scanned = @(Get-CandidateLines $highScan.PlanPath | ForEach-Object { [IO.Path]::GetFileName([string]$_.Path) } | Sort-Object)
    Assert-Equal 'High=0 admits freshly written and old files but not future/read-only' 'zero-now.tmp|zero-old.tmp' ($scanned -join '|')
    # The same trusted rule table must still resolve at clean time: restore only after the
    # clean completes, so this proves the sealed zero-age plan round-trips through clean.
    $highClean = Invoke-SjcClean -Context $highContext -TaskDirectory $highTask -RecycleMode $false -CustomEnabled $true
    $script:n09Active = $false
    Assert-Equal 'the zero-age plan cleans successfully' 'Success|2' ($highClean.Status + '|' + $highClean.Deleted) $highClean.Error
    Assert-True 'future and read-only fixtures survive the zero-age clean' ([IO.File]::Exists($hf) -and [IO.File]::Exists((Join-Path $script:n09Files 'zero-readonly.tmp'))) ''
    Assert-True 'zero-age clean did not clear the read-only attribute' (((Get-TestFileState (Join-Path $script:n09Files 'zero-readonly.tmp')).ReadOnly)) ''

    # Hard link: the identity gate keeps a multi-link file out of the candidate set.
    $linkSandbox = New-OwnedSandbox
    $linkContext = $linkSandbox.Context
    $linkRoot = Join-Path $linkSandbox.Root 'links'
    [void][IO.Directory]::CreateDirectory($linkRoot)
    $linkSource = Join-Path $linkRoot 'n09-link-a.tmp'; New-TestFile -Path $linkSource -Bytes 32 -AgeHours 96 | Out-Null
    $linkName = Join-Path $linkRoot 'n09-link-b.tmp'
    $linkCreated = $false
    try { New-Item -ItemType HardLink -Path $linkName -Target $linkSource -ErrorAction Stop | Out-Null; $linkCreated = $true } catch { }
    if ($linkCreated) {
        $linkRule = [pscustomobject][ordered]@{
            Id = 'N09Links'; TemplateId = 'VSCodeCache'; Name = 'n09 links'; Group = 'test'; Risk = '中'; Recommended = $false
            Root = $linkRoot; Patterns = @('*.tmp'); ExcludePatterns = @(); MinimumAgeHours = 0
            LowMinimumAgeHours = 1; MediumMinimumAgeHours = 1; HighMinimumAgeHours = 0; PresetLevel = 'Medium'
            CleaningProfile = 'High'; AgePolicy = 'PureCache'; ProcessPolicy = 'NameGuard'; AuthorizationId = ''
            AuthorizationBinding = ''; DiscoveryAdapter = ''; DiscoverySource = ''; DiscoverySourceValue = ''
            RootDirectoryIdentity = ''; RequiresClosedProcess = @(); OverrideEnvironment = @(); Available = $true; Note = ''
        }
        Assert-Throws 'a multi-link file has no cleanable identity' { Get-SjcFileIdentity $linkSource } '多硬链接'
        Assert-True 'the rule-level file gate does not special-case links' (Test-SjcRuleFile $linkRule ([IO.FileInfo]::new($linkSource)) $now) ''
        # Executed scan: the multi-link file is refused at identity time and becomes a
        # warning, never a candidate, even with High=0.
        $script:n09LinkStateRoot = [string]$linkContext.StateRoot
        $script:n09LinkFiles = $linkRoot
        $script:n09Active = $true
        $linkTask = New-SjcTaskDirectory -Context $linkContext
        $linkScan = Invoke-SjcScan -Context $linkContext -RuleIds @('N09Links') -TaskDirectory $linkTask -CustomEnabled $true
        $script:n09Active = $false
        # The identity refusal aborts that entry, so the scan reports Partial (incomplete,
        # never "Success") and the file is not a candidate.
        Assert-Equal 'a multi-link file blocks candidate admission during a real scan' 'Partial|0' ($linkScan.Status + '|' + $linkScan.CandidateCount) $linkScan.Error
        Assert-True 'the scan is not silently reported as a complete Success' ($linkScan.Status -ne 'Success') ([string]$linkScan.Status)
        Assert-True 'the scan records the refused multi-link file as a warning' (@($linkScan.Warnings | Where-Object { $_ -match '多硬链接' }).Count -ge 1) (@($linkScan.Warnings) -join ' | ')
        Assert-True 'the multi-link file survives the scan' ([IO.File]::Exists($linkSource) -and [IO.File]::Exists($linkName)) ''
        Add-Limitation 'N09 硬链接边界已在真实 Invoke-SjcScan 上执行：Get-SjcFileIdentity 拒绝多硬链接，文件记警告且不入候选，分类因此标 Partial（不完整）；未执行删除。'
    }
    else { Add-Limitation 'N09 无法在当前卷创建硬链接，多硬链接身份拒绝未执行（未计通过）。' }

    # ---- 4. Teams WebView2 ownership classification (mocked records) --------
    $originalProcessRecord = ${function:Get-SjcReadOnlyProcessRecord}
    $script:n09Records = @{}
    $script:n09Calls = @{}
    function Get-SjcReadOnlyProcessRecord {
        param([int]$ProcessId)
        if (-not $script:n09Calls.ContainsKey($ProcessId)) { $script:n09Calls[$ProcessId] = 0 }
        $script:n09Calls[$ProcessId]++
        if (-not $script:n09Records.ContainsKey($ProcessId)) { throw '无法读取宿主身份或父链。' }
        $entry = $script:n09Records[$ProcessId]
        if ($script:n09Calls[$ProcessId] -gt 1 -and $entry.ContainsKey('Second')) { return $entry['Second'] }
        return $entry['First']
    }
    $dummyWebView = Join-Path $sandbox.Root 'msedgewebview2.exe'
    $dummyTeams = Join-Path $sandbox.Root 'ms-teams.exe'
    $dummyOther = Join-Path $sandbox.Root 'sjc-other-host.exe'
    foreach ($path in @($dummyWebView, $dummyTeams, $dummyOther)) { New-TestFile -Path $path -Bytes 4 -AgeHours 1 | Out-Null }
    $realMsExe = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'Internet Explorer\iexplore.exe'
    $childTime = [datetime]::UtcNow.AddMinutes(-10)
    $parentTime = [datetime]::UtcNow.AddMinutes(-20)
    function New-N09Record {
        param([int]$ProcessId, [int]$ParentProcessId, [string]$ExecutablePath, [datetime]$CreationDate)
        return [pscustomobject]@{ ProcessId = $ProcessId; ParentProcessId = $ParentProcessId; Name = [IO.Path]::GetFileName($ExecutablePath); ExecutablePath = $ExecutablePath; CreationDate = $CreationDate }
    }
    # Teams: webview2 child owned by ms-teams.
    $script:n09Records = @{
        1001 = @{ First = (New-N09Record 1001 5001 $dummyWebView $childTime) }
        5001 = @{ First = (New-N09Record 5001 1 $dummyTeams $parentTime) }
    }
    $script:n09Calls = @{}
    Assert-Equal 'an ms-teams parent makes the WebView2 host Teams-owned' 'Teams' (Get-SjcWebView2Ownership 1001) ''
    # Unrelated: a signed Microsoft host under Program Files is provably unrelated.
    if ([IO.File]::Exists($realMsExe)) {
        $script:n09Records = @{
            1002 = @{ First = (New-N09Record 1002 5002 $dummyWebView $childTime) }
            5002 = @{ First = (New-N09Record 5002 1 $realMsExe $parentTime) }
        }
        $script:n09Calls = @{}
        Assert-Equal 'a signed Microsoft Program Files host is provably unrelated' 'Unrelated' (Get-SjcWebView2Ownership 1002) $realMsExe
    }
    else { Add-Limitation 'N09 未找到 Program Files 下的微软签名宿主样本；Unrelated 分支未执行（未计通过）。' }
    # Unknown: an unsigned host outside Program Files cannot be proven unrelated.
    $script:n09Records = @{
        1003 = @{ First = (New-N09Record 1003 5003 $dummyWebView $childTime) }
        5003 = @{ First = (New-N09Record 5003 1 $dummyOther $parentTime) }
    }
    $script:n09Calls = @{}
    Assert-Equal 'an unsigned non-Program-Files host is Unknown, never Unrelated' 'Unknown' (Get-SjcWebView2Ownership 1003) ''
    # Unknown: missing executable path.
    $script:n09Records = @{ 1004 = @{ First = (New-N09Record 1004 5004 '' $childTime) } }
    $script:n09Calls = @{}
    Assert-Equal 'a missing executable path is Unknown' 'Unknown' (Get-SjcWebView2Ownership 1004) ''
    # Unknown: PID reuse while the chain was observed.
    $script:n09Records = @{
        1005 = @{
            First = (New-N09Record 1005 5005 $dummyWebView $childTime)
            Second = (New-N09Record 1005 5005 $dummyWebView $childTime.AddMinutes(5))
        }
        5005 = @{ First = (New-N09Record 5005 1 $dummyTeams $parentTime) }
    }
    $script:n09Calls = @{}
    Assert-Equal 'PID reuse detected by a fresh requery is Unknown' 'Unknown' (Get-SjcWebView2Ownership 1005) ''
    # Unknown: parent created after the child (impossible ancestry).
    $script:n09Records = @{
        1006 = @{ First = (New-N09Record 1006 5006 $dummyWebView $childTime) }
        5006 = @{ First = (New-N09Record 5006 1 $dummyTeams ([datetime]::UtcNow.AddMinutes(5))) }
    }
    $script:n09Calls = @{}
    Assert-Equal 'a parent created after the child is Unknown' 'Unknown' (Get-SjcWebView2Ownership 1006) ''
    # Unknown: parent chain cycle.
    $script:n09Records = @{
        1007 = @{ First = (New-N09Record 1007 5007 $dummyWebView $childTime) }
        5007 = @{ First = (New-N09Record 5007 1007 $dummyWebView $parentTime) }
    }
    $script:n09Calls = @{}
    Assert-Equal 'a cyclic parent chain is Unknown' 'Unknown' (Get-SjcWebView2Ownership 1007) ''
    # Unknown: unreadable record.
    $script:n09Records = @{}
    $script:n09Calls = @{}
    Assert-Equal 'an unreadable process record is Unknown' 'Unknown' (Get-SjcWebView2Ownership 1099) ''

    # ---- 5. Guard decisions from the ownership verdict ----------------------
    $teamsProd = @($prodRules | Where-Object { $_.Id -ceq 'NewTeamsCache' })[0]
    Assert-True 'the production new-Teams rule uses the WebView2 ownership policy' ([string]$teamsProd.ProcessPolicy -ceq 'NewTeamsWebView2' -and @($teamsProd.RequiresClosedProcess) -contains 'msedgewebview2') ([string]$teamsProd.ProcessPolicy)
    Assert-True 'non-Teams rules keep the plain name guard' (@($prodRules | Where-Object { $_.Id -notlike 'NewTeams*' -and [string]$_.ProcessPolicy -cne 'NameGuard' }).Count -eq 0) (($prodRules | Where-Object { [string]$_.ProcessPolicy -cne 'NameGuard' } | ForEach-Object { $_.Id + '=' + $_.ProcessPolicy }) -join ',')
    $webViewProcs = @([Diagnostics.Process]::GetProcessesByName('msedgewebview2'))
    $webViewCountBefore = $webViewProcs.Count
    foreach ($process in $webViewProcs) { $process.Dispose() }
    if ($webViewCountBefore -gt 0) {
        $guardRule = $teamsProd.PSObject.Copy()
        $guardRule.RequiresClosedProcess = @('msedgewebview2')
        $guardRule.MinimumAgeHours = 0
        $script:n09Records = @{}
        $script:n09Calls = @{}
        # Every enumerated live msedgewebview2 PID is treated as unrelated: class is not blocked.
        $script:n09OwnershipDefault = 'Unrelated'
        $originalOwnership = ${function:Get-SjcWebView2Ownership}
        function Get-SjcWebView2Ownership { param([int]$ProcessId) return [string]$script:n09OwnershipDefault }
        try {
            $unrelated = Get-SjcProcessGuard $guardRule
            Assert-True 'a provably unrelated WebView2 host no longer blocks the whole Teams class' ($unrelated.Closed -and $unrelated.Status -ceq 'Success') ([string]$unrelated.Status)
            $script:n09OwnershipDefault = 'Unknown'
            $unknown = Get-SjcProcessGuard $guardRule
            Assert-True 'an unknown WebView2 owner is skipped conservatively, not deleted' ((-not $unknown.Closed) -and $unknown.Status -ceq 'ProcessGuardUnknown') ([string]$unknown.Status + '; ' + [string]$unknown.Note)
            $script:n09OwnershipDefault = 'Teams'
            $owned = Get-SjcProcessGuard $guardRule
            Assert-True 'a Teams-owned WebView2 still blocks as a running process' ((-not $owned.Closed) -and $owned.Status -ceq 'RunningProcess') ([string]$owned.Status)
        }
        finally { ${function:Get-SjcWebView2Ownership} = $originalOwnership }
    }
    else {
        Add-Limitation 'N09 本机当前没有 msedgewebview2 进程，未直接执行真实枚举上的归属判定门；归属分类已由 mock 记录单独覆盖（未计为门级通过）。'
    }
    $afterProcs = @([Diagnostics.Process]::GetProcessesByName('msedgewebview2'))
    $webViewCountAfter = $afterProcs.Count
    foreach ($process in $afterProcs) { $process.Dispose() }
    Assert-Equal 'the ownership checks neither start nor stop WebView2 processes' $webViewCountBefore $webViewCountAfter ''
    # Unknown policy value is conservative.
    $unknownPolicy = $teamsProd.PSObject.Copy()
    $unknownPolicy.ProcessPolicy = 'FuturePolicy'
    $unknownPolicy.RequiresClosedProcess = @('SjcNoSuchProcess')
    $guardUnknown = Get-SjcProcessGuard $unknownPolicy
    Assert-True 'an unknown process policy is conservatively skipped' ((-not $guardUnknown.Closed) -and $guardUnknown.Status -ceq 'ProcessGuardUnknown') ([string]$guardUnknown.Status)
    # Non-webview2 live process still blocks a WebView2-policy rule.
    $liveName = [Diagnostics.Process]::GetProcessById($PID).ProcessName
    $liveRule = $teamsProd.PSObject.Copy()
    $liveRule.RequiresClosedProcess = @($liveName)
    $liveGuard = Get-SjcProcessGuard $liveRule
    Assert-True 'a live host process still blocks even under the WebView2 policy' ((-not $liveGuard.Closed) -and $liveGuard.Status -ceq 'RunningProcess') ([string]$liveGuard.Status)
    Add-Limitation ('N09 的归属/守卫判定使用 in-process mock 进程记录与真实存在的 msedgewebview2 进程枚举；未启动或结束任何真实 Teams/WebView2 应用，未读取命令行，未扫描生产缓存。当前观测 msedgewebview2=' + $webViewCountBefore)

    [void](Save-Evidence 'n09-summary' ([pscustomobject]@{
        PureCacheTemplates = $pureCacheTemplates
        HighZeroAdmitted = $scanned
        ZeroClean = $highClean.Status + '|' + $highClean.Deleted
        LiveWebView2 = $webViewCountBefore
        HardLinkCovered = $linkCreated
    }))
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($null -ne $originalRules) { ${function:Get-SjcRules} = $originalRules }
    if ($null -ne $originalProcessRecord) { ${function:Get-SjcReadOnlyProcessRecord} = $originalProcessRecord }
    Remove-Variable -Name n09Records, n09Calls, n09Files, n09Active, n09OwnershipDefault -Scope Script -ErrorAction SilentlyContinue
}
Complete-TestCase
