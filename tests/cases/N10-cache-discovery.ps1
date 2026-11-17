#requires -Version 5.1
# N10: cache discovery and approval boundary (synthetic NuGet/pip layouts only).
#
# Scope (targeted, not a full audit):
#   * Discovery never grants approval: candidates are metadata only and create no rule.
#   * Supported vs unsupported synthetic layouts (NuGet HTTP; pip http/http-v2/wheels).
#   * Approve rejects wrong Id/Binding cardinality, duplicate ids, stale bindings and the
#     32-entry cap; approved rules carry exact root/ages/processes/binding/identity.
#   * A displayed binding change, a source change and a directory replacement invalidate
#     the old authorization; approve with the old binding must be refused.
#   * Revoke, including revoking an authorization whose source has disappeared; an old
#     sealed plan cannot be cleaned after any scope change and its file stays on disk.
#   * Rule file matching is a strict layout allow-list (age/reparse/read-only still apply).
#   * Worker boundary is exercised only through Assert-SjcWorkerPayload: callers cannot
#     inject roots, test roots, bindings, discovery sources or a scope seal.
#
# Boundaries: every file lives in a Harness-owned GUID sandbox under StateRoot\Sandboxes;
# no real NuGet/pip cache is read, no production Worker is started, no production state is
# written. The pip rule's real process guard may block scan/clean when python is running;
# that is reported as a limitation, never bypassed.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory

$script:H40 = '0123456789abcdef0123456789abcdef01234567'
$script:Hex56Valid = 'abcde' + ('0' * 51)
$script:Hex56Bad = 'abcdf' + ('1' * 51)
$script:Dirs56Bad = ('abcde' + ('2' * 51))

function Join-Parts {
    param([string]$Base, [string]$Child)
    return [IO.Path]::Combine($Base, $Child)
}
function New-LayoutFile {
    param([string]$Path, [double]$AgeHours = 200, [int]$Bytes = 64)
    New-TestFile -Path $Path -Bytes $Bytes -AgeHours $AgeHours | Out-Null
    return $Path
}
function New-NuGetLayoutFile {
    param([string]$Root, [string]$Leaf, [double]$AgeHours = 200)
    return (New-LayoutFile -Path (Join-Parts (Join-Parts $Root ($script:H40 + '$synthetic')) $Leaf) -AgeHours $AgeHours)
}
function Get-SingleItem {
    param($Items)
    $list = @($Items)
    if ($list.Count -eq 1) { return $list[0] }
    return $null
}
function Get-NuGetCandidate {
    param($Context)
    return (Get-SingleItem @(Get-SjcCacheLocationCandidates -Context $Context | Where-Object { $_.Adapter -ceq 'NuGetHttp' }))
}
function Get-PipCandidate {
    param($Context, [string]$TemplateId)
    return (Get-SingleItem @(Get-SjcCacheLocationCandidates -Context $Context | Where-Object { $_.Adapter -ceq 'Pip' -and $_.TemplateId -ceq $TemplateId }))
}
function Get-LocationById {
    param($Context, [string]$Id)
    return (Get-SingleItem @(Get-SjcDiscoveredCacheLocations -Context $Context | Where-Object { $_.Id -ceq $Id }))
}
function New-PipHttpTree {
    param([string]$Root, [string]$Prefix56, [string]$Leaf56 = '', [switch]$Body, [double]$AgeHours = 200)
    # Relative path must use backslashes; [IO.Path]::Combine flattens an array argument
    # into a single space-joined string and would never match the production regex.
    # Leaf56 defaults to Prefix56; pass a different hex prefix to build a real
    # "directory chain does not match the leaf name" fixture.
    if ([string]::IsNullOrEmpty($Leaf56)) { $Leaf56 = $Prefix56 }
    $leaf = $Leaf56
    if ($Body) { $leaf = $leaf + '.body' }
    $relative = ($Prefix56[0..4] -join '\') + '\' + $leaf
    return (New-LayoutFile -Path ([IO.Path]::Combine($Root, $relative)) -AgeHours $AgeHours)
}

try {
    # =====================================================================
    # S0/S1: NuGet discovery seam, non-approval, approval, strict filter,
    #        sealed scan/clean, worker payload boundary.
    # =====================================================================
    $s1 = New-OwnedSandbox
    $c1 = $s1.Context
    $files1 = Join-Path $s1.Root 'files'
    $nuget1 = Join-Path $files1 'nuget-http'
    [void][IO.Directory]::CreateDirectory($nuget1)

    Assert-Equal 'a fresh test context exposes no discovery sources' 0 (@(Get-SjcDiscoverySources -Context $c1).Count)
    Assert-Throws 'a non-NuGet/pip adapter is refused by the test seam' { Set-SjcTestDiscoverySources -Context $c1 -Sources @([pscustomobject]@{ Adapter = 'Npm'; Value = $nuget1 }) } 'adapter 无效'
    Assert-Throws 'a source outside the sandbox files root is refused' { Set-SjcTestDiscoverySources -Context $c1 -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = (Join-Path $s1.Root 'state') }) } '自有沙箱 files'
    $production = New-ProductionContextForInventory
    Assert-Equal 'inventory context has no writable StateRoot' '' ([string]$production.StateRoot)
    Assert-Throws 'read-only production inventory cannot enter the execution registry' { Get-SjcContextConfiguration $production } '^上下文不是本实现创建的可信上下文。$'
    Assert-Throws 'discovery source injection is refused for read-only production inventory' { Set-SjcTestDiscoverySources -Context $production -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $nuget1 }) } '^上下文不是本实现创建的可信上下文。$'
    Set-SjcTestDiscoverySources -Context $c1 -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $nuget1 })
    $sources1 = @(Get-SjcDiscoverySources -Context $c1)
    Assert-Equal 'the injected source is visible to discovery only in the sandbox' 1 $sources1.Count
    Assert-Equal 'the injected NuGet adapter maps to NUGET_HTTP_CACHE_PATH' 'NuGetHttp|NUGET_HTTP_CACHE_PATH' ([string]$sources1[0].Adapter + '|' + [string]$sources1[0].Source)

    # Scan-relevant files in the injected root: exactly one must survive the layout/age filters.
    $valid1 = New-NuGetLayoutFile -Root $nuget1 -Leaf 'list_pkg.dat' -AgeHours 200
    $recent1 = New-NuGetLayoutFile -Root $nuget1 -Leaf 'list_recent.dat' -AgeHours 2
    $readonly1 = New-NuGetLayoutFile -Root $nuget1 -Leaf 'list_readonly.dat' -AgeHours 200
    [IO.File]::SetAttributes($readonly1, [IO.FileAttributes]::ReadOnly)
    $future1 = New-NuGetLayoutFile -Root $nuget1 -Leaf 'list_future.dat' -AgeHours (-1)
    $stray1 = New-LayoutFile -Path (Join-Path $nuget1 'stray.tmp')
    $notes1 = New-LayoutFile -Path (Join-Parts (Join-Parts $nuget1 ($script:H40 + '$synthetic')) 'notes.txt')
    $nested1 = New-LayoutFile -Path (Join-Parts (Join-Parts (Join-Parts $nuget1 ($script:H40 + '$synthetic')) 'sub') 'list_nested.dat')
    $noSuffix1 = New-LayoutFile -Path (Join-Parts (Join-Parts $nuget1 ($script:H40 + '-nosuffix')) 'list_nosuffix.dat')
    $upper1 = New-LayoutFile -Path (Join-Parts (Join-Parts $nuget1 ($script:H40.ToUpperInvariant() + '$upper')) 'list_upper.dat')
    $long1 = New-LayoutFile -Path (Join-Parts (Join-Parts $nuget1 ($script:H40 + 'a$long')) 'list_long.dat')

    # Pure layout matrix on an unrelated root (never injected, never scanned).
    $matrix = Join-Path $files1 'nuget-layout-matrix'
    $mService = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'service_index.dat'))
    $mList = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'list_a.b+c-d.dat'))
    $mNupkg = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'nupkg_pkg.1.0.dat'))
    $mUpperLeaf = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'LIST_x.dat'))
    $mUpperExt = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'list_x.DAT'))
    $mSuffix = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'list_x.dat.bak'))
    $mNoSuffix = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '-nosuffix'), 'list_x.dat'))
    $mUpperHex = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40.ToUpperInvariant() + '$upper'), 'list_x.dat'))
    $mLongHex = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + 'a$long'), 'list_x.dat'))
    $mNested = New-LayoutFile -Path ([IO.Path]::Combine($matrix, ($script:H40 + '$name'), 'sub', 'list_x.dat'))
    $mRootFile = New-LayoutFile -Path ([IO.Path]::Combine($matrix, 'list_root.dat'))

    Assert-True 'NuGet layout accepts service_index/list_*/nupkg_* .dat files' ((Test-SjcCacheLayoutFile 'NuGetCache' $matrix $mService) -and (Test-SjcCacheLayoutFile 'NuGetCache' $matrix $mList) -and (Test-SjcCacheLayoutFile 'NuGetCache' $matrix $mNupkg)) ''
    $layoutFalse = @($mUpperLeaf, $mUpperExt, $mSuffix, $mNoSuffix, $mUpperHex, $mLongHex, $mNested, $mRootFile)
    $layoutTrueCount = @($layoutFalse | Where-Object { Test-SjcCacheLayoutFile 'NuGetCache' $matrix $_ }).Count
    Assert-Equal 'NuGet layout rejects wrong case/extension/nesting/hash-shape names' 0 $layoutTrueCount ($layoutFalse -join '; ')
    Assert-True 'NuGet layout rejects a file outside the supplied root' (-not (Test-SjcCacheLayoutFile 'NuGetCache' $matrix $valid1)) $valid1
    Assert-True 'a populated valid NuGet tree proves layout' (Test-SjcCacheLayout 'NuGetCache' $matrix) ''

    # Discovery only: supported metadata, but no rule may exist before approval.
    $candidate1 = Get-NuGetCandidate $c1
    Assert-True 'NuGet discovery returns one candidate for the injected source' ($null -ne $candidate1) ''
    if ($null -ne $candidate1) {
        Assert-True 'candidate id has the Discovered:64-hex shape' ([string]$candidate1.Id -cmatch '^Discovered:[a-f0-9]{64}$') ([string]$candidate1.Id)
        Assert-True 'candidate binding is 64 lowercase hex' ([string]$candidate1.Binding -cmatch '^[a-f0-9]{64}$') ([string]$candidate1.Binding)
        Assert-True 'candidate root is the injected root (normalized case)' ([string]$candidate1.Root -ceq $nuget1.ToLowerInvariant()) ([string]$candidate1.Root)
        Assert-True 'a supported layout is still PendingAuthorization and not authorized' ($candidate1.Supported -eq $true -and $candidate1.Authorized -eq $false -and [string]$candidate1.Status -ceq 'PendingAuthorization') ('supported=' + $candidate1.Supported + '; authorized=' + $candidate1.Authorized + '; status=' + $candidate1.Status)
        Assert-Equal 'candidate maps to the NuGetCache template' 'NuGetCache' ([string]$candidate1.TemplateId)
        Assert-True 'candidate records a directory identity but no authorization id' (-not [string]::IsNullOrWhiteSpace([string]$candidate1.DirectoryIdentity) -and [string]::IsNullOrEmpty([string]$candidate1.AuthorizationId)) ([string]$candidate1.DirectoryIdentity)
    }
    $discoveredBefore = @(Get-SjcRules -Context $c1 | Where-Object { ([string]$_.Id).StartsWith('Discovered:') })
    Assert-Equal 'discovery without confirmation creates no rule' 0 $discoveredBefore.Count
    Assert-Equal 'discovery without confirmation exposes no authorized template' 0 (@(Get-SjcAuthorizedCacheRuleTemplates $c1).Count)
    $presetHighBefore = @(Get-SjcPresetRuleIds -Context $c1 -CleaningProfile 'High')
    Assert-True 'an unconfirmed candidate never enters a preset' ($null -ne $candidate1 -and $presetHighBefore -notcontains $candidate1.Id) ''
    $preScanTask = New-SjcTaskDirectory -Context $c1
    $preScan = Invoke-SjcScan -Context $c1 -RuleIds @([string]$candidate1.Id) -TaskDirectory $preScanTask -CustomEnabled $true
    Assert-True 'an unconfirmed candidate id is not a scannable rule' ($preScan.Status -eq 'Failed' -and [string]$preScan.Error -match '未知或重复规则') ('status=' + $preScan.Status + '; error=' + $preScan.Error)
    Assert-True 'the rejected pre-approval scan wrote no sealed plan' (-not [IO.File]::Exists((Join-Path $preScanTask 'scan.meta.json'))) ''

    # Approval arithmetic: cardinality, duplicates, stale binding, unknown revoke.
    Assert-Throws 'approve refuses mismatched id/binding counts' { Approve-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id)) -ExpectedBindings ([string[]]@($candidate1.Binding, $candidate1.Binding)) } '一一对应'
    Assert-Throws 'approve refuses duplicate ids in one call' { Approve-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id, $candidate1.Id)) -ExpectedBindings ([string[]]@($candidate1.Binding, $candidate1.Binding)) } '重复或不支持'
    Assert-Throws 'approve refuses a stale/incorrect displayed binding' { Approve-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id)) -ExpectedBindings ([string[]]@(('0' * 64))) } '重复或不支持'
    Assert-Throws 'revoke refuses an id that was never authorized' { Revoke-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id)) } '没有对应的已保存缓存授权'
    Assert-Equal 'failed approvals wrote no authorization store' $false ([IO.File]::Exists((Join-Path $c1.StateRoot 'cache-authorizations-v1.dpapi')))

    $approved1 = @(Approve-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id)) -ExpectedBindings ([string[]]@($candidate1.Binding)))
    $approvedLoc1 = Get-LocationById -Context $c1 -Id $candidate1.Id
    Assert-True 'approve returns the location as Authorized with a 32-hex authorization id' ($null -ne $approvedLoc1 -and [string]$approvedLoc1.Status -ceq 'Authorized' -and $approvedLoc1.Authorized -eq $true -and [string]$approvedLoc1.AuthorizationId -cmatch '^[a-f0-9]{32}$') ('status=' + $(if ($null -ne $approvedLoc1) { $approvedLoc1.Status } else { 'missing' }))
    $store1 = Read-SjcCacheAuthorizations $c1
    Assert-Equal 'the approval store holds exactly one entry' 1 (@($store1.Entries).Count)
    Assert-True 'the stored entry pins the displayed id and binding' ($null -ne $approvedLoc1 -and [string]$store1.Entries[0].Id -ceq $candidate1.Id -and [string]$store1.Entries[0].Binding -ceq $candidate1.Binding -and [string]$store1.Entries[0].AuthorizationId -ceq $approvedLoc1.AuthorizationId) ''
    $raw1 = Read-SjcSafeText (Join-Path $c1.StateRoot 'cache-authorizations-v1.dpapi')
    Assert-True 'the authorization store is DPAPI-protected (no plaintext id)' ($raw1 -notmatch [regex]::Escape([string]$candidate1.Id)) ''

    $rule1 = Get-SingleItem @(Get-SjcRules -Context $c1 | Where-Object { $_.Id -ceq $candidate1.Id })
    Assert-True 'approval adds exactly one discovered rule' ($null -ne $rule1) ''
    if ($null -ne $rule1) {
        Assert-Equal 'the discovered rule uses the NuGetCache template' 'NuGetCache' ([string]$rule1.TemplateId)
        Assert-True 'the discovered rule root equals the confirmed exact root' ([string]$rule1.Root -ceq [string]$candidate1.Root) ([string]$rule1.Root)
        Assert-Equal 'the discovered rule keeps a positive 168h medium age' 168 ([double]$rule1.MinimumAgeHours) ([string]$rule1.MinimumAgeHours)
        Assert-Equal 'the discovered rule keeps a 24h high-tier age' 24 ([double]$rule1.HighMinimumAgeHours) ([string]$rule1.HighMinimumAgeHours)
        Assert-Equal 'the discovered rule is a High preset member after confirmation' 'High' ([string]$rule1.PresetLevel)
        $processes = @($rule1.RequiresClosedProcess)
        Assert-True 'the discovered rule guards dotnet/nuget/MSBuild/devenv' (@($processes | Where-Object { $_ -in @('dotnet', 'nuget', 'MSBuild', 'devenv') }).Count -eq 4) ($processes -join ',')
        Assert-True 'the discovered rule pins authorization id, binding, adapter, source and identity' ([string]$rule1.AuthorizationId -ceq $approvedLoc1.AuthorizationId -and [string]$rule1.AuthorizationBinding -ceq $candidate1.Binding -and [string]$rule1.DiscoveryAdapter -ceq 'NuGetHttp' -and [string]$rule1.DiscoverySource -ceq 'NUGET_HTTP_CACHE_PATH' -and [string]$rule1.RootDirectoryIdentity -ceq [string]$candidate1.DirectoryIdentity) ''
        Assert-True 'the discovered rule is current under the injected source' (Test-SjcDiscoveredRuleCurrent $rule1) ''
    }
    $presetHighAfter = @(Get-SjcPresetRuleIds -Context $c1 -CleaningProfile 'High')
    $presetMediumAfter = @(Get-SjcPresetRuleIds -Context $c1 -CleaningProfile 'Medium')
    Assert-True 'the confirmed rule joins the High preset only' (($presetHighAfter -contains $candidate1.Id) -and (-not ($presetMediumAfter -contains $candidate1.Id))) ('high=' + ($presetHighAfter -contains $candidate1.Id) + '; medium=' + ($presetMediumAfter -contains $candidate1.Id))

    # Strict per-file rule filter on the real approved rule object.
    $fileChecks = @(
        @{ Name = 'rule filter accepts the old layout file'; Expected = $true; Path = $valid1 },
        @{ Name = 'rule filter rejects a fresh layout file'; Expected = $false; Path = $recent1 },
        @{ Name = 'rule filter rejects a read-only layout file'; Expected = $false; Path = $readonly1 },
        @{ Name = 'rule filter rejects a future-dated layout file'; Expected = $false; Path = $future1 },
        @{ Name = 'rule filter rejects a non-layout file at the root'; Expected = $false; Path = $stray1 },
        @{ Name = 'rule filter rejects a non-layout sibling name'; Expected = $false; Path = $notes1 },
        @{ Name = 'rule filter rejects a nested layout-like file'; Expected = $false; Path = $nested1 },
        @{ Name = 'rule filter rejects a directory without the $ suffix'; Expected = $false; Path = $noSuffix1 },
        @{ Name = 'rule filter rejects an uppercase hash directory'; Expected = $false; Path = $upper1 },
        @{ Name = 'rule filter rejects a 41-hex directory'; Expected = $false; Path = $long1 }
    )
    $fileFilterErrors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -ne $rule1) {
        foreach ($case in $fileChecks) {
            $info = [IO.FileInfo]::new([string]$case.Path)
            $actual = Test-SjcRuleFile -Rule $rule1 -File $info -NowUtc ([datetime]::UtcNow)
            if ([bool]$actual -ne [bool]$case.Expected) { $fileFilterErrors.Add($case.Name + '=' + $actual) }
        }
    }
    else { $fileFilterErrors.Add('rule1-missing') }
    Assert-True 'the approved rule accepts only the exact supported layout file' ($fileFilterErrors.Count -eq 0) ($fileFilterErrors -join '; ')

    # Sealed scan: only the strict-layout old file becomes a candidate.
    $task1 = New-SjcTaskDirectory -Context $c1
    $scan1 = Invoke-SjcScan -Context $c1 -RuleIds @([string]$candidate1.Id) -TaskDirectory $task1 -CustomEnabled $true
    Assert-Equal 'the approved rule scan succeeds' 'Success' ([string]$scan1.Status) ([string]$scan1.Error)
    $candidatePaths1 = @(Get-CandidateLines $scan1.PlanPath | ForEach-Object { [string]$_.Path })
    Assert-Equal 'the sealed scan has exactly one candidate' 1 ([int64]$scan1.CandidateCount) ($candidatePaths1 -join ',')
    Assert-True 'the only candidate is the strict-layout file' ($candidatePaths1.Count -eq 1 -and $candidatePaths1[0].Equals($valid1, [StringComparison]::OrdinalIgnoreCase)) ($candidatePaths1 -join ',')

    # Worker payload boundary (no worker process is started).
    $workerScan = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true }
    $workerScanOk = $true
    try { Assert-SjcWorkerPayload -Payload $workerScan -Mode 'Scan' } catch { $workerScanOk = $false }
    Assert-True 'worker accepts a scan payload that carries only the discovered rule id' $workerScanOk ''
    $workerClean = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; ExcludedIds = @('0123456789abcdef0123456789abcdef'); RecycleMode = $false; CleaningProfile = 'Medium'; CustomEnabled = $true }
    $workerCleanOk = $true
    try { Assert-SjcWorkerPayload -Payload $workerClean -Mode 'Clean' } catch { $workerCleanOk = $false }
    Assert-True 'worker accepts a clean payload with exclusion ids only' $workerCleanOk ''
    $workerRejects = @(
        @{ Name = 'worker rejects a caller-supplied Root'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true; Root = [string]$candidate1.Root } },
        @{ Name = 'worker rejects a caller-supplied TestRoot'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true; TestRoot = $s1.Root } },
        @{ Name = 'worker rejects caller-supplied expected bindings'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true; ExpectedBindings = @([string]$candidate1.Binding) } },
        @{ Name = 'worker rejects caller-supplied discovery sources'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true; DiscoveryTestSources = @() } },
        @{ Name = 'worker rejects caller-supplied discovery scope seal'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium'; CustomEnabled = $true; DiscoveryScopeSeal = 'x' } },
        @{ Name = 'worker rejects a scalar RuleIds string'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = [string]$candidate1.Id; CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'worker rejects a scan payload without CustomEnabled'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; RuleIds = @([string]$candidate1.Id); CleaningProfile = 'Medium' } },
        @{ Name = 'worker rejects a clean payload with a non-array ExcludedIds'; Mode = 'Clean'; Payload = [pscustomobject]@{ TaskDirectory = $task1; CancelPath = ''; ProgressPath = ''; ExcludedIds = '0123456789abcdef0123456789abcdef'; RecycleMode = $false; CleaningProfile = 'Medium'; CustomEnabled = $true } }
    )
    foreach ($case in $workerRejects) {
        $payload = $case.Payload; $mode = $case.Mode
        Assert-Throws $case.Name { Assert-SjcWorkerPayload -Payload $payload -Mode $mode } ''
    }

    $clean1 = Invoke-SjcClean -Context $c1 -TaskDirectory $task1 -RecycleMode $false -CustomEnabled $true
    Assert-Equal 'clean succeeds for the sealed approved scope' 'Success' ([string]$clean1.Status) ([string]$clean1.Error)
    Assert-Equal 'clean deleted exactly the one strict-layout candidate' 1 ([int64]$clean1.Deleted) ([string]$clean1.Deleted)
    Assert-True 'the cleaned layout file is gone' (-not [IO.File]::Exists($valid1)) ''
    Assert-True 'fresh, read-only, future, non-layout, nested and wrong-shape files survive' ([IO.File]::Exists($recent1) -and [IO.File]::Exists($readonly1) -and [IO.File]::Exists($future1) -and [IO.File]::Exists($stray1) -and [IO.File]::Exists($notes1) -and [IO.File]::Exists($nested1) -and [IO.File]::Exists($noSuffix1) -and [IO.File]::Exists($upper1) -and [IO.File]::Exists($long1)) ''
    Assert-True 'clean leaves the read-only attribute untouched' ((Get-TestFileState $readonly1).ReadOnly -eq $true) ''

    # Repeated approval must replace, not duplicate, the stored entry.
    $oldAuth1 = [string]$approvedLoc1.AuthorizationId
    [void](Approve-SjcCacheLocations -Context $c1 -Ids ([string[]]@($candidate1.Id)) -ExpectedBindings ([string[]]@($candidate1.Binding)))
    $storeAfterRepeat = Read-SjcCacheAuthorizations $c1
    Assert-Equal 're-approving the same id keeps a single store entry' 1 (@($storeAfterRepeat.Entries).Count)
    Assert-True 're-approval issues a new authorization id' ([string]$storeAfterRepeat.Entries[0].AuthorizationId -cne $oldAuth1) ([string]$storeAfterRepeat.Entries[0].AuthorizationId)

    [void](Save-Evidence 'nuget-approval-scan-clean' ([pscustomobject]@{
        Candidate = [string]$candidate1.Id
        Binding = [string]$candidate1.Binding
        AuthorizationId = [string]$approvedLoc1.AuthorizationId
        ScanStatus = [string]$scan1.Status
        CandidateCount = [int64]$scan1.CandidateCount
        CleanStatus = [string]$clean1.Status
        Deleted = [int64]$clean1.Deleted
        WorkerScanAccepted = $workerScanOk
        WorkerCleanAccepted = $workerCleanOk
    }))

    # =====================================================================
    # S2: directory identity replacement invalidates the old binding and the
    #     old sealed plan; approve with the old binding must fail.
    # =====================================================================
    $s2 = New-OwnedSandbox
    $c2 = $s2.Context
    $files2 = Join-Path $s2.Root 'files'
    $nuget2 = Join-Path $files2 'nuget-http'
    [void][IO.Directory]::CreateDirectory($nuget2)
    $file2 = New-NuGetLayoutFile -Root $nuget2 -Leaf 'list_before.dat' -AgeHours 200
    Set-SjcTestDiscoverySources -Context $c2 -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $nuget2 })
    $candidate2 = Get-NuGetCandidate $c2
    Assert-True 'replacement baseline candidate is supported' ($null -ne $candidate2 -and $candidate2.Supported -eq $true) ''
    [void](Approve-SjcCacheLocations -Context $c2 -Ids ([string[]]@($candidate2.Id)) -ExpectedBindings ([string[]]@($candidate2.Binding)))
    $auth2 = [string](Get-LocationById -Context $c2 -Id $candidate2.Id).AuthorizationId
    $seal2Before = Get-SjcDiscoveryScopeSeal $c2
    $task2 = New-SjcTaskDirectory -Context $c2
    $scan2 = Invoke-SjcScan -Context $c2 -RuleIds @([string]$candidate2.Id) -TaskDirectory $task2 -CustomEnabled $true
    Assert-Equal 'baseline scan before replacement succeeds' 'Success' ([string]$scan2.Status) ([string]$scan2.Error)
    $rule2Old = Get-SingleItem @(Get-SjcRules -Context $c2 | Where-Object { $_.Id -ceq $candidate2.Id })
    Assert-True 'baseline rule is current before replacement' ($null -ne $rule2Old -and (Test-SjcDiscoveredRuleCurrent $rule2Old)) ''

    $moved2 = Move-OwnedTestDirectoryToEvidence -Path $nuget2
    [void][IO.Directory]::CreateDirectory($nuget2)
    $file2After = New-NuGetLayoutFile -Root $nuget2 -Leaf 'list_after.dat' -AgeHours 200
    $candidate2New = Get-NuGetCandidate $c2
    Assert-True 'the replaced directory keeps the same displayed candidate id' ($null -ne $candidate2New -and [string]$candidate2New.Id -ceq [string]$candidate2.Id) ([string]$candidate2New.Id)
    Assert-True 'the replaced directory yields a different binding' ($null -ne $candidate2New -and [string]$candidate2New.Binding -cne [string]$candidate2.Binding) ([string]$candidate2New.Binding)
    $stale2 = Get-LocationById -Context $c2 -Id $candidate2.Id
    Assert-True 'the old authorization is shown as stale after directory replacement' ($null -ne $stale2 -and [string]$stale2.Status -ceq 'StaleAuthorization' -and $stale2.Authorized -eq $true -and $stale2.Supported -eq $true) ('status=' + $(if ($null -ne $stale2) { $stale2.Status } else { 'missing' }))
    Assert-True 'the stale candidate no longer matches the rule binding' ($null -ne $rule2Old -and -not (Test-SjcDiscoveredRuleCurrent $rule2Old)) ''
    Assert-Throws 'approve with the old displayed binding is refused after replacement' { Approve-SjcCacheLocations -Context $c2 -Ids ([string[]]@($candidate2.Id)) -ExpectedBindings ([string[]]@([string]$candidate2.Binding)) } '重复或不支持'
    $seal2After = Get-SjcDiscoveryScopeSeal $c2
    Assert-True 'the discovery scope seal changes after directory replacement' ($seal2Before -cne $seal2After) ''

    $clean2 = Invoke-SjcClean -Context $c2 -TaskDirectory $task2 -RecycleMode $false -CustomEnabled $true
    Assert-True 'the old sealed plan is refused after directory replacement' ($clean2.Status -eq 'Failed' -and [int64]$clean2.Deleted -eq 0) ('status=' + $clean2.Status + '; deleted=' + $clean2.Deleted + '; error=' + $clean2.Error)
    Assert-True 'the refusal names the changed discovery scope/plan' ([string]$clean2.Error -match '发现源、目录身份或授权范围已变化|旧计划失效') ([string]$clean2.Error)
    Assert-True 'the pre-replacement file survives inside the moved directory' ([IO.File]::Exists((Join-Parts (Join-Parts $moved2 ($script:H40 + '$synthetic')) 'list_before.dat'))) ''
    Assert-True 'the post-replacement file is untouched by the refused plan' ([IO.File]::Exists($file2After)) ''

    $reapproved2 = @(Approve-SjcCacheLocations -Context $c2 -Ids ([string[]]@($candidate2.Id)) -ExpectedBindings ([string[]]@([string]$candidate2New.Binding)))
    $reLoc2 = Get-LocationById -Context $c2 -Id $candidate2.Id
    Assert-True 'the current binding can be re-confirmed as Authorized' ($null -ne $reLoc2 -and [string]$reLoc2.Status -ceq 'Authorized') ('status=' + $(if ($null -ne $reLoc2) { $reLoc2.Status } else { 'missing' }))
    Assert-True 're-approval rotates the authorization id' ([string]$reLoc2.AuthorizationId -cne $auth2) ([string]$reLoc2.AuthorizationId)
    Assert-True 'the store still holds a single entry for the replaced root' (@((Read-SjcCacheAuthorizations $c2).Entries).Count -eq 1) ''

    [void](Save-Evidence 'binding-replacement' ([pscustomobject]@{
        Id = [string]$candidate2.Id
        OldBinding = [string]$candidate2.Binding
        NewBinding = [string]$candidate2New.Binding
        OldAuthorizationId = $auth2
        NewAuthorizationId = [string]$reLoc2.AuthorizationId
        OldPlanClean = [string]$clean2.Status
        SealBefore = $seal2Before
        SealAfter = $seal2After
    }))

    # =====================================================================
    # S3: revoke refuses old scans/cleans and keeps files; source change makes
    #     the old authorization disappear, which must still be revocable.
    # =====================================================================
    $s3 = New-OwnedSandbox
    $c3 = $s3.Context
    $files3 = Join-Path $s3.Root 'files'
    $rootA = Join-Path $files3 'nuget-a'
    $rootB = Join-Path $files3 'nuget-b'
    [void][IO.Directory]::CreateDirectory($rootA)
    [void][IO.Directory]::CreateDirectory($rootB)
    $fileA = New-NuGetLayoutFile -Root $rootA -Leaf 'list_a.dat' -AgeHours 200
    $fileB = New-NuGetLayoutFile -Root $rootB -Leaf 'list_b.dat' -AgeHours 200
    Set-SjcTestDiscoverySources -Context $c3 -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $rootA })
    $candidateA = Get-NuGetCandidate $c3
    [void](Approve-SjcCacheLocations -Context $c3 -Ids ([string[]]@($candidateA.Id)) -ExpectedBindings ([string[]]@($candidateA.Binding)))
    $authA = [string](Get-LocationById -Context $c3 -Id $candidateA.Id).AuthorizationId
    $ruleA = Get-SingleItem @(Get-SjcRules -Context $c3 | Where-Object { $_.Id -ceq $candidateA.Id })
    $task3 = New-SjcTaskDirectory -Context $c3
    $scan3 = Invoke-SjcScan -Context $c3 -RuleIds @([string]$candidateA.Id) -TaskDirectory $task3 -CustomEnabled $true
    Assert-Equal 'the pre-revoke scan succeeds' 'Success' ([string]$scan3.Status) ([string]$scan3.Error)
    Assert-Equal 'the pre-revoke scan finds the old layout file' 1 ([int64]$scan3.CandidateCount) ''

    $revoked3 = @(Revoke-SjcCacheLocations -Context $c3 -Ids ([string[]]@($candidateA.Id)))
    $revokedLoc3 = Get-SingleItem @($revoked3 | Where-Object { $_.PSObject.Properties['Adapter'] -and $_.Id -ceq $candidateA.Id })
    Assert-True 'revoke returns the location as unapproved and pending' ($null -ne $revokedLoc3 -and $revokedLoc3.Authorized -eq $false -and [string]$revokedLoc3.Status -ceq 'PendingAuthorization') ('status=' + $(if ($null -ne $revokedLoc3) { $revokedLoc3.Status } else { 'missing' }))
    Assert-Equal 'revoking removes the discovered rule from the rule table' 0 (@(Get-SjcRules -Context $c3 | Where-Object { ([string]$_.Id).StartsWith('Discovered:') }).Count)
    Assert-True 'the revoked rule object is no longer current' ($null -ne $ruleA -and -not (Test-SjcDiscoveredRuleCurrent $ruleA)) ''

    $clean3 = Invoke-SjcClean -Context $c3 -TaskDirectory $task3 -RecycleMode $false -CustomEnabled $true
    Assert-True 'an old sealed plan cannot be cleaned after revoke' ($clean3.Status -eq 'Failed' -and [int64]$clean3.Deleted -eq 0) ('status=' + $clean3.Status + '; deleted=' + $clean3.Deleted + '; error=' + $clean3.Error)
    Assert-True 'the post-revoke refusal names the changed discovery scope/plan' ([string]$clean3.Error -match '发现源、目录身份或授权范围已变化|旧计划失效|清理档位已变化') ([string]$clean3.Error)
    Assert-True 'the revoked file is still on disk' ([IO.File]::Exists($fileA)) ''
    $scan3After = Invoke-SjcScan -Context $c3 -RuleIds @([string]$candidateA.Id) -TaskDirectory (New-SjcTaskDirectory -Context $c3) -CustomEnabled $true
    Assert-True 'a revoked rule id cannot be scanned again' ($scan3After.Status -eq 'Failed' -and [string]$scan3After.Error -match '未知或重复规则') ('status=' + $scan3After.Status + '; error=' + $scan3After.Error)
    [void](Refresh-SjcAuthorizedRules -Context $c3)
    Assert-Equal 'refresh (the worker re-discovery path) exposes no discovered rule after revoke' 0 (@(Get-SjcRules -Context $c3 | Where-Object { ([string]$_.Id).StartsWith('Discovered:') }).Count)
    Assert-Throws 'revoke refuses an already revoked id' { Revoke-SjcCacheLocations -Context $c3 -Ids ([string[]]@($candidateA.Id)) } '没有对应的已保存缓存授权'

    # Re-approve A, scan, then move the discovery source to B: A's authorization disappears.
    [void](Approve-SjcCacheLocations -Context $c3 -Ids ([string[]]@($candidateA.Id)) -ExpectedBindings ([string[]]@($candidateA.Binding)))
    $authA2 = [string](Get-LocationById -Context $c3 -Id $candidateA.Id).AuthorizationId
    Assert-True 're-approval after revoke issues a fresh authorization id' ($authA2 -cne $authA) $authA2
    $task3b = New-SjcTaskDirectory -Context $c3
    $scan3b = Invoke-SjcScan -Context $c3 -RuleIds @([string]$candidateA.Id) -TaskDirectory $task3b -CustomEnabled $true
    Assert-Equal 'the scan before the source change succeeds' 'Success' ([string]$scan3b.Status) ([string]$scan3b.Error)
    $seal3Before = Get-SjcDiscoveryScopeSeal $c3
    Set-SjcTestDiscoverySources -Context $c3 -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $rootB })
    $candidateB = Get-NuGetCandidate $c3
    Assert-True 'the new source yields a different displayed candidate id' ($null -ne $candidateB -and [string]$candidateB.Id -cne [string]$candidateA.Id) ([string]$candidateB.Id)
    $locations3 = @(Get-SjcDiscoveredCacheLocations -Context $c3)
    $unavailable3 = Get-SingleItem @($locations3 | Where-Object { -not $_.PSObject.Properties['Adapter'] -and $_.Id -ceq $candidateA.Id })
    Assert-True 'the disappeared source authorization is surfaced as a stale unavailable entry' ($null -ne $unavailable3 -and [string]$unavailable3.Application -ceq '已失效缓存授权' -and [string]$unavailable3.Source -ceq 'Unavailable' -and [string]$unavailable3.Root -ceq '' -and [string]$unavailable3.Status -ceq 'StaleAuthorization' -and $unavailable3.Supported -eq $false -and $unavailable3.Authorized -eq $true) ('status=' + $(if ($null -ne $unavailable3) { $unavailable3.Status } else { 'missing' }))
    Assert-True 'the unavailable entry still carries the old authorization id' ($null -ne $unavailable3 -and [string]$unavailable3.AuthorizationId -ceq $authA2) ([string]$unavailable3.AuthorizationId)
    Assert-True 'the source change moves the discovery scope seal' ($seal3Before -cne (Get-SjcDiscoveryScopeSeal $c3)) ''
    $clean3b = Invoke-SjcClean -Context $c3 -TaskDirectory $task3b -RecycleMode $false -CustomEnabled $true
    Assert-True 'the pre-source-change plan is refused after the source changed' ($clean3b.Status -eq 'Failed' -and [int64]$clean3b.Deleted -eq 0) ('status=' + $clean3b.Status + '; deleted=' + $clean3b.Deleted + '; error=' + $clean3b.Error)
    Assert-True 'the file from the old source survives the source change' ([IO.File]::Exists($fileA)) ''
    Assert-True 'the file from the new source is untouched (never approved)' ([IO.File]::Exists($fileB)) ''
    $revokedUnavailable = @(Revoke-SjcCacheLocations -Context $c3 -Ids ([string[]]@($candidateA.Id)))
    $afterRevoke3 = @(Get-SjcDiscoveredCacheLocations -Context $c3)
    Assert-True 'a disappeared authorization can be revoked' (@($afterRevoke3 | Where-Object { $_.Id -ceq $candidateA.Id }).Count -eq 0) ''
    Assert-Equal 'revoking the disappeared authorization empties the store' 0 (@((Read-SjcCacheAuthorizations $c3).Entries).Count)
    Assert-True 'the current source candidate remains pending, never implicitly approved' ($null -ne $candidateB -and (@($afterRevoke3 | Where-Object { $_.Id -ceq $candidateB.Id })[0].Status -ceq 'PendingAuthorization')) ''

    [void](Save-Evidence 'revoke-and-source-change' ([pscustomobject]@{
        CandidateA = [string]$candidateA.Id
        CandidateB = [string]$candidateB.Id
        AuthorizationA = $authA2
        RevokedClean = [string]$clean3.Status
        SourceChangeClean = [string]$clean3b.Status
        SealBefore = $seal3Before
        UnavailableEntries = @($locations3 | Where-Object { -not $_.PSObject.Properties['Adapter'] } | ForEach-Object { [string]$_.Id })
    }))

    # =====================================================================
    # S4: pip layout allow-list (http/http-v2/wheels), unsupported approval
    #     rejection, approved rule shape, and the real process guard.
    # =====================================================================
    $s4 = New-OwnedSandbox
    $c4 = $s4.Context
    $files4 = Join-Path $s4.Root 'files'
    $pipRoot = Join-Path $files4 'pip-cache'
    $pipHttp = Join-Path $pipRoot 'http'
    $pipHttpV2 = Join-Path $pipRoot 'http-v2'
    $pipWheels = Join-Path $pipRoot 'wheels'
    [void][IO.Directory]::CreateDirectory($pipHttp)
    [void][IO.Directory]::CreateDirectory($pipHttpV2)
    [void][IO.Directory]::CreateDirectory($pipWheels)

    $pipHttpFile = New-PipHttpTree -Root $pipHttp -Prefix56 $script:Hex56Valid
    # Directory chain uses the valid prefix while the leaf name starts with the other
    # prefix: a real "chain does not match the leaf" layout, which must be rejected.
    $pipV2BadFile = New-PipHttpTree -Root $pipHttpV2 -Prefix56 $script:Hex56Valid -Leaf56 $script:Hex56Bad -Body
    $pipV2GoodBody = New-PipHttpTree -Root $pipHttp -Prefix56 $script:Hex56Valid -Body
    $pipWheelFile = New-LayoutFile -Path ([IO.Path]::Combine($pipWheels, 'aa', 'bb', 'cc', ('d' * 50), 'pkg-1.0-py3-none-any.whl'))
    $pipWheelBadExt = New-LayoutFile -Path ([IO.Path]::Combine($pipWheels, 'aa', 'bb', 'cc', ('d' * 50), 'pkg-1.0.zip'))
    $pipWheelBadHash = New-LayoutFile -Path ([IO.Path]::Combine($pipWheels, 'aa', 'bb', 'cc', ('d' * 49), 'pkg-2.0-py3-none-any.whl'))
    $pipHttpBadLink = New-PipHttpTree -Root $pipHttp -Prefix56 $script:Hex56Valid -Leaf56 $script:Hex56Bad
    Set-SjcTestDiscoverySources -Context $c4 -Sources @([pscustomobject]@{ Adapter = 'Pip'; Value = $pipRoot })

    Assert-True 'pip http layout accepts a matching six-hex-level file' (Test-SjcCacheLayoutFile 'PipHttpCache' $pipHttp $pipHttpFile) ''
    Assert-True 'pip http layout rejects a mismatched hash prefix' (-not (Test-SjcCacheLayoutFile 'PipHttpCache' $pipHttp $pipHttpBadLink)) ''
    Assert-True 'pip http-v2 layout accepts a .body file with a matching prefix' (Test-SjcCacheLayoutFile 'PipHttpV2Cache' $pipHttp $pipV2GoodBody) ''
    Assert-True 'pip http-v2 layout rejects a mismatched hash chain' (-not (Test-SjcCacheLayoutFile 'PipHttpV2Cache' $pipHttpV2 $pipV2BadFile)) ''
    Assert-True 'pip wheels layout accepts a 50-hex directory with a .whl file' (Test-SjcCacheLayoutFile 'PipWheelCache' $pipWheels $pipWheelFile) ''
    Assert-True 'pip wheels layout rejects a non-.whl file' (-not (Test-SjcCacheLayoutFile 'PipWheelCache' $pipWheels $pipWheelBadExt)) ''
    Assert-True 'pip wheels layout rejects a 49-hex directory' (-not (Test-SjcCacheLayoutFile 'PipWheelCache' $pipWheels $pipWheelBadHash)) ''
    Assert-True 'pip layout scanning proves the valid http tree' (Test-SjcCacheLayout 'PipHttpCache' $pipHttp) ''
    Assert-True 'pip layout scanning rejects the mismatched http-v2 tree' (-not (Test-SjcCacheLayout 'PipHttpV2Cache' $pipHttpV2)) ''
    Assert-True 'pip layout scanning proves the valid wheels tree' (Test-SjcCacheLayout 'PipWheelCache' $pipWheels) ''

    $pipCandidates = @(Get-SjcCacheLocationCandidates -Context $c4)
    Assert-Equal 'pip discovery returns exactly the three pip cache templates' 3 $pipCandidates.Count
    $pcHttp = Get-PipCandidate $c4 'PipHttpCache'
    $pcV2 = Get-PipCandidate $c4 'PipHttpV2Cache'
    $pcWheels = Get-PipCandidate $c4 'PipWheelCache'
    Assert-True 'pip http is supported and pending' ($null -ne $pcHttp -and $pcHttp.Supported -eq $true -and [string]$pcHttp.Status -ceq 'PendingAuthorization') ''
    Assert-True 'pip http-v2 with a mismatched layout is Unsupported' ($null -ne $pcV2 -and $pcV2.Supported -eq $false -and [string]$pcV2.Status -ceq 'Unsupported') ''
    Assert-True 'pip wheels is supported and pending' ($null -ne $pcWheels -and $pcWheels.Supported -eq $true -and [string]$pcWheels.Status -ceq 'PendingAuthorization') ''
    Assert-True 'pip candidate roots are the exact http/http-v2/wheels subroots' ($null -ne $pcHttp -and [string]$pcHttp.Root -ceq $pipHttp.ToLowerInvariant() -and [string]$pcV2.Root -ceq $pipHttpV2.ToLowerInvariant() -and [string]$pcWheels.Root -ceq $pipWheels.ToLowerInvariant()) ''
    Assert-Throws 'an unsupported pip layout cannot be approved' { Approve-SjcCacheLocations -Context $c4 -Ids ([string[]]@($pcV2.Id)) -ExpectedBindings ([string[]]@($pcV2.Binding)) } '重复或不支持'
    Assert-Equal 'the refused unsupported approval wrote no store' $false ([IO.File]::Exists((Join-Path $c4.StateRoot 'cache-authorizations-v1.dpapi')))

    [void](Approve-SjcCacheLocations -Context $c4 -Ids ([string[]]@($pcHttp.Id, $pcWheels.Id)) -ExpectedBindings ([string[]]@($pcHttp.Binding, $pcWheels.Binding)))
    Assert-Equal 'two supported pip layouts can be approved together' 2 (@((Read-SjcCacheAuthorizations $c4).Entries).Count)
    $pipRules = @(Get-SjcAuthorizedCacheRuleTemplates $c4)
    Assert-Equal 'only the two approved pip templates become rules' 2 $pipRules.Count
    $pipRuleHttp = Get-SingleItem @($pipRules | Where-Object { $_.TemplateId -ceq 'PipHttpCache' })
    $pipRuleWheels = Get-SingleItem @($pipRules | Where-Object { $_.TemplateId -ceq 'PipWheelCache' })
    Assert-True 'the approved pip rules keep the exact subroots and adapter/source' ($null -ne $pipRuleHttp -and $null -ne $pipRuleWheels -and [string]$pipRuleHttp.Root -ceq $pipHttp.ToLowerInvariant() -and [string]$pipRuleWheels.Root -ceq $pipWheels.ToLowerInvariant() -and [string]$pipRuleHttp.DiscoveryAdapter -ceq 'Pip' -and [string]$pipRuleHttp.DiscoverySource -ceq 'PIP_CACHE_DIR') ''
    Assert-True 'the approved pip rules guard python/pythonw/pip/pip3/uv' ($null -ne $pipRuleHttp -and @(@('python', 'pythonw', 'pip', 'pip3', 'uv') | Where-Object { @($pipRuleHttp.RequiresClosedProcess) -notcontains $_ }).Count -eq 0) (@($pipRuleHttp.RequiresClosedProcess) -join ',')
    Assert-True 'the approved pip rules keep 168h medium and 24h high ages' ($null -ne $pipRuleHttp -and [double]$pipRuleHttp.MinimumAgeHours -eq 168 -and [double]$pipRuleHttp.HighMinimumAgeHours -eq 24) ''
    Assert-True 'the approved pip rules are High preset members' ($null -ne $pipRuleHttp -and [string]$pipRuleHttp.PresetLevel -ceq 'High') ''

    $runningPip = @('python', 'pythonw', 'pip', 'pip3', 'uv') | Where-Object { @([Diagnostics.Process]::GetProcessesByName($_)).Count -gt 0 }
    $pipGuard = Get-SjcProcessGuard $pipRuleHttp
    if (@($runningPip).Count -gt 0) {
        Assert-True 'a live python/pip process keeps the approved pip rule blocked' ($pipGuard.Closed -eq $false -and [string]$pipGuard.Status -ceq 'ProcessGuardUnknown') ([string]$pipGuard.Status + ': ' + [string]$pipGuard.Note)
        Add-Limitation ('N10 未对已授权的 pip 规则执行真实 scan/clean：检测到运行中的进程 ' + (@($runningPip) -join ',') + '，真实 NameGuard 会保守跳过（已单独断言该守卫）。')
    }
    else {
        Assert-True 'no live python/pip process lets the approved pip rule pass its guard' ($pipGuard.Closed -eq $true) ([string]$pipGuard.Status)
        $pipTask = New-SjcTaskDirectory -Context $c4
        $pipScan = Invoke-SjcScan -Context $c4 -RuleIds @([string]$pipRuleHttp.Id) -TaskDirectory $pipTask -CustomEnabled $true
        Assert-Equal 'the approved pip HTTP rule scans its old layout file' 'Success|1' ([string]$pipScan.Status + '|' + [string]$pipScan.CandidateCount) ([string]$pipScan.Error)
        $pipClean = Invoke-SjcClean -Context $c4 -TaskDirectory $pipTask -RecycleMode $false -CustomEnabled $true
        Assert-True 'the approved pip HTTP rule cleans only its layout file' ($pipClean.Status -eq 'Success' -and [int64]$pipClean.Deleted -eq 1 -and -not [IO.File]::Exists($pipHttpFile) -and [IO.File]::Exists($pipWheelFile)) ('status=' + $pipClean.Status + '; deleted=' + $pipClean.Deleted)
    }
    [void](Revoke-SjcCacheLocations -Context $c4 -Ids ([string[]]@($pcHttp.Id, $pcWheels.Id)))
    Assert-Equal 'revoking both pip approvals empties the store' 0 (@((Read-SjcCacheAuthorizations $c4).Entries).Count)

    [void](Save-Evidence 'pip-layouts' ([pscustomobject]@{
        Http = [string]$pcHttp.Status
        HttpV2 = [string]$pcV2.Status
        Wheels = [string]$pcWheels.Status
        HttpSupported = $pcHttp.Supported
        V2Supported = $pcV2.Supported
        WheelsSupported = $pcWheels.Supported
        RunningGuardProcesses = @($runningPip)
        GuardStatus = [string]$pipGuard.Status
    }))

    # =====================================================================
    # S5: approval count arithmetic - 32 entries allowed, a 33rd is refused.
    # =====================================================================
    $s5 = New-OwnedSandbox
    $c5 = $s5.Context
    $files5 = Join-Path $s5.Root 'files'
    $sources5 = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt 33; $i++) {
        $dir = Join-Path $files5 ('nuget-' + $i.ToString('00'))
        [void][IO.Directory]::CreateDirectory($dir)
        New-NuGetLayoutFile -Root $dir -Leaf 'list_pkg.dat' -AgeHours 200 | Out-Null
        $sources5.Add([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $dir })
    }
    Set-SjcTestDiscoverySources -Context $c5 -Sources $sources5.ToArray()
    $candidates5 = @(Get-SjcCacheLocationCandidates -Context $c5)
    Assert-Equal '33 injected roots produce 33 supported candidates' 33 $candidates5.Count
    Assert-Equal 'every one of the 33 synthetic roots is supported' 33 (@($candidates5 | Where-Object { $_.Supported -eq $true }).Count)
    $ids5 = @($candidates5 | ForEach-Object { [string]$_.Id })
    $bindings5 = @($candidates5 | ForEach-Object { [string]$_.Binding })
    Assert-Throws 'approve refuses more than 32 ids in one call' { Approve-SjcCacheLocations -Context $c5 -Ids ([string[]]$ids5) -ExpectedBindings ([string[]]$bindings5) } '超出数量限制'
    $firstIds5 = [string[]]@($ids5[0..31])
    $firstBindings5 = [string[]]@($bindings5[0..31])
    [void](Approve-SjcCacheLocations -Context $c5 -Ids $firstIds5 -ExpectedBindings $firstBindings5)
    Assert-Equal 'approving exactly 32 entries succeeds' 32 (@((Read-SjcCacheAuthorizations $c5).Entries).Count)
    Assert-Equal '32 approved entries yield 32 authorized templates' 32 (@(Get-SjcAuthorizedCacheRuleTemplates $c5).Count)
    Assert-Throws 'a 33rd approval is refused by the entry cap' { Approve-SjcCacheLocations -Context $c5 -Ids ([string[]]@($ids5[32])) -ExpectedBindings ([string[]]@($bindings5[32])) } '缓存授权数量超过限制'
    [void](Revoke-SjcCacheLocations -Context $c5 -Ids $firstIds5)
    Assert-Equal 'revoking the 32 approved entries empties the store' 0 (@((Read-SjcCacheAuthorizations $c5).Entries).Count)

    [void](Save-Evidence 'approval-limits' ([pscustomobject]@{
        Candidates = $candidates5.Count
        Approved = 32
        OverflowRejected = $true
    }))

    Add-DeclaredExclusion '未启动生产 Worker、未调用 Invoke-SjcWorker：Worker 边界只用 Assert-SjcWorkerPayload 验证载荷白名单。'
    Add-DeclaredExclusion '未读取、扫描或清理任何真实 NuGet HTTP / pip 缓存；发现源全部为本进程自建 GUID 沙箱内的合成布局。'
    Add-DeclaredExclusion '生产环境变量发现分支（NUGET_HTTP_CACHE_PATH/PIP_CACHE_DIR）未执行：本机两变量为空，测试通过 Set-SjcTestDiscoverySources 注入沙箱源。'
    Add-Limitation '生产规则清单使用只读库存工厂，无 StateRoot、不注册执行上下文；注入明确因可信上下文校验而拒绝，未创建正式上下文或写正式授权库。生产执行上下文的 GUID 沙箱拒注入分支本轮未运行。'
    Add-Limitation '目录身份替换用同一源根改名后重建模拟，未替换真实缓存目录，也未验证 NTFS 卷序列号复用等极端场景。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
