#requires -Version 5.1
# R02: browser profile discovery - only Default/Profile N immediate children, links and
# non-profile leaves rejected, production path is the same function (no test-only seam).
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
    $base = Join-Path $sandbox.Root 'chromium-user-data'
    [void][IO.Directory]::CreateDirectory($base)

    $valid = @('Default', 'Profile 1', 'Profile 12', 'Profile 123456')
    $invalid = @('Guest Profile', 'System Profile', 'Profile 0', 'Profile 01', 'Profile 1234567', 'default', 'Profile -1', 'Profile 1 backup')
    foreach ($name in ($valid + $invalid)) { [void][IO.Directory]::CreateDirectory((Join-Path $base $name)) }
    New-TestFile -Path (Join-Path $base 'Default\Cache\data_0') -Bytes 64 -AgeHours 100 | Out-Null

    $outside = Join-Path $sandbox.Root 'outside-profile-target'
    [void][IO.Directory]::CreateDirectory($outside)
    try { [void](New-Item -ItemType Junction -Path (Join-Path $base 'Profile 2') -Target $outside -ErrorAction Stop) }
    catch { Add-CoverageGap ('无法创建目录联接，链接 Profile 排除未验证：' + $_.Exception.Message) }
    try { [void](New-Item -ItemType Junction -Path (Join-Path $base 'Profile 13') -Target $outside -ErrorAction Stop) }
    catch { Add-CoverageGap ('无法创建 Profile 13 目录联接：' + $_.Exception.Message) }
    try { [void](New-Item -ItemType SymbolicLink -Path (Join-Path $base 'Profile 4') -Target $outside -ErrorAction SilentlyContinue) }
    catch { }

    $found = @(Get-SjcChromiumProfileDirectories -BaseRoot $base)
    $foundLeaves = @($found | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
    [void](Save-Evidence 'discovery' ([pscustomobject]@{ Found = $foundLeaves; Valid = $valid; Invalid = $invalid }))

    Assert-Equal 'discovery returns exactly the valid profile leaves' (($valid | Sort-Object) -join '|') ($foundLeaves -join '|')
    $isListedInvalid = @($foundLeaves | Where-Object { $leaf = $_; @($invalid | Where-Object { $leaf -ceq $_ }).Count -gt 0 })
    Assert-True 'discovery rejects Guest/System Profile, Profile 0/01/1234567, lowercase and suffixed names' ($isListedInvalid.Count -eq 0) ($foundLeaves -join ',')
    Assert-True 'discovery skips junction profile even when name matches' ($foundLeaves -notcontains 'Profile 2') ($foundLeaves -join ',')
    Assert-True 'discovery returns absolute existing directories' (@($found | Where-Object { -not [IO.Path]::IsPathRooted($_) -or -not [IO.Directory]::Exists($_) }).Count -eq 0) (($found | Select-Object -First 3) -join ',')

    $missing = Join-Path $sandbox.Root 'does-not-exist'
    Assert-Equal 'missing base returns empty array' 0 (@(Get-SjcChromiumProfileDirectories -BaseRoot $missing).Count)
    Assert-Throws 'relative base path is rejected by the absolute-path guard' { Get-SjcChromiumProfileDirectories -BaseRoot 'relative\path' } '本地驱动器绝对'

    $fileBase = Join-Path $sandbox.Root 'base-is-a-file'
    New-TestFile -Path $fileBase -Bytes 8 -AgeHours 100 | Out-Null
    Assert-Equal 'file as base returns empty array' 0 (@(Get-SjcChromiumProfileDirectories -BaseRoot $fileBase).Count)

    # Production reuse: the production rule builder must call this same function.
    $rulesText = [IO.File]::ReadAllText((Join-Path $RepoRoot 'src\Rules.ps1'))
    Assert-True 'production Get-SjcRules reuses Get-SjcChromiumProfileDirectories' ($rulesText -match 'Get-SjcChromiumProfileDirectories\s+-BaseRoot')

    # A test context must never yield browser instances (browser roots are fixed LocalAppData paths).
    $context = $sandbox.Context
    $testRules = @(Get-SjcRules -Context $context)
    Assert-True 'test context exposes only synthetic sandbox rules' (@($testRules | Where-Object { $_.Id -match ':' }).Count -eq 0) (($testRules | ForEach-Object Id) -join ',')

    # Production inventory: every browser instance root must be under a fixed user-data root and be absent when not discovered.
    $production = New-ProductionContextForInventory
    $productionRules = @(Get-SjcRules -Context $production)
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $allowedBases = @(
        (Join-Path $local 'Google\Chrome\User Data'),
        (Join-Path $local 'Microsoft\Edge\User Data'),
        (Join-Path $local 'BraveSoftware\Brave-Browser\User Data')
    )
    $badRoots = @($productionRules | Where-Object { $_.Id -match ':' } | Where-Object {
        $rule = $_
        @($allowedBases | Where-Object { $rule.Root.StartsWith($_ + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
    })
    Assert-True 'production browser roots only under fixed User Data bases' ($badRoots.Count -eq 0) (($badRoots | ForEach-Object { $_.Id + '=' + $_.Root }) -join '; ')

    $expectedInstances = New-Object 'System.Collections.Generic.List[string]'
    foreach ($basePath in $allowedBases) {
        if (-not [IO.Directory]::Exists($basePath)) { continue }
        foreach ($profile in @(Get-SjcChromiumProfileDirectories -BaseRoot $basePath)) {
            $leaf = [IO.Path]::GetFileName($profile).Replace(' ', '_')
            foreach ($cache in @('Cache', 'Code Cache', 'GPUCache')) {
                $prefix = switch -Regex ($basePath) { 'Chrome' { 'Chrome' } 'Edge' { 'Edge' } default { 'Brave' } }
                $expectedInstances.Add($prefix + ($cache -replace ' ', '') + ':' + $leaf)
            }
        }
    }
    $actualInstances = @($productionRules | Where-Object { $_.Id -match ':' } | ForEach-Object Id | Sort-Object)
    $expectedSorted = @($expectedInstances | Sort-Object)
    $delta = @(Compare-Object -ReferenceObject $expectedSorted -DifferenceObject $actualInstances)
    Assert-Equal 'production instances equal independent enumeration of this host' 0 $delta.Count (($delta | ForEach-Object { $_.SideIndicator + $_.InputObject }) -join ',')

    $badBrowserRule = @($productionRules | Where-Object { $_.Id -match ':' -and $_.Note -notmatch 'Service Worker' })
    Assert-True 'browser notes state Service Worker data is out of scope' ($badBrowserRule.Count -eq 0) (($badBrowserRule | ForEach-Object Id) -join ',')
    $badProcess = @($productionRules | Where-Object { $_.Id -match ':' -and @($_.RequiresClosedProcess).Count -eq 0 })
    Assert-True 'browser instances require the owning process closed' ($badProcess.Count -eq 0) (($badProcess | ForEach-Object Id) -join ',')
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
