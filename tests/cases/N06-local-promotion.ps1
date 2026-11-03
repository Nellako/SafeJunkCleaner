#requires -Version 5.1
# N06: local promotion tooling, executed independently of the author's self-check.
# 1) Runs scripts/test-local-promotion.ps1 (its own GUID repositories under %TEMP%) and
#    requires the scripted 30/30 result plus a zero exit code.
# 2) Runs a read-only preflight against the real develop/main repositories through a
#    harness-side wrapper that converts the returned object to JSON and preserves the real
#    exit code. Equal HEAD must yield NoPromotionNeeded with Executed=false; different HEAD
#    must stay blocked-with-diagnostic or Ready without execution. No promotion is
#    executed and neither repository HEAD may change.
# 3) Self-tests the same wrapper contract on a synthetic GUID pair that shares one HEAD:
#    it must return NoPromotionNeeded with Executed=false and leave the target unchanged.
#    Fixtures live in %TEMP% and are removed afterwards.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
try {
    $powerShell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-True 'Windows PowerShell 5.1 exists for child runs' ([IO.File]::Exists($powerShell)) $powerShell

    # ---- 1. independent run of the author-provided promotion self-test -------------
    $selfTest = Join-Path $RepoRoot 'scripts\test-local-promotion.ps1'
    Assert-True 'promotion self-test entry exists' ([IO.File]::Exists($selfTest)) $selfTest
    Assert-True 'promotion common module exists' ([IO.File]::Exists((Join-Path $RepoRoot 'scripts\local-promotion-common.ps1'))) ''
    Assert-True 'promote entry exists' ([IO.File]::Exists((Join-Path $RepoRoot 'scripts\promote-local.ps1'))) ''
    Assert-True 'seal entry exists' ([IO.File]::Exists((Join-Path $RepoRoot 'scripts\seal-local-promotion.ps1'))) ''

    if ([IO.File]::Exists($selfTest)) {
        $run = Invoke-ReleasePowerShellScript -ScriptPath $selfTest -Tag 'promotion-selftest' -TimeoutSeconds 600
        $stdout = Get-ReleaseTextFile $run.StdoutPath
        $stderr = Get-ReleaseTextFile $run.StderrPath
        [void](Save-EvidenceText 'promotion-selftest-stdout' $stdout)
        [void](Save-EvidenceText 'promotion-selftest-stderr' $stderr)
        Assert-True 'promotion self-test did not time out' (-not $run.TimedOut) ('timedOut=' + [string]$run.TimedOut)
        Assert-Equal 'promotion self-test exits zero' 0 $run.ExitCode $stderr
        Assert-True 'promotion self-test prints its RESULT summary' ($stdout -match 'RESULT passed=(\d+)') ('len=' + $stdout.Length)
        $passedMatch = [regex]::Match($stdout, 'RESULT passed=(\d+)')
        if ($passedMatch.Success) {
            # Never fewer than the 30 scenarios this suite was validated against; extra
            # scenarios are allowed and are still covered by the zero-FAIL requirement.
            $scenarioCount = [int]$passedMatch.Groups[1].Value
            Assert-True 'promotion self-test runs at least the 30 validated scenarios' ($scenarioCount -ge 30) ('passed=' + $scenarioCount)
            Assert-Equal 'promotion self-test reports no failures' 0 (@([regex]::Matches($stdout, '(?im)^FAIL\b')).Count) 'FAIL lines present'
            Assert-True 'promotion self-test ends without an unhandled error line' (-not ($stdout -match '(?im)^\s*(Exception|Unhandled|Traceback)')) $stdout.Substring(0, [math]::Min(200, $stdout.Length))
        }
        Assert-True 'promotion self-test states it is not product acceptance' ($stdout -match 'synthetic fixtures only') $stdout.Substring(0, [math]::Min(200, $stdout.Length))
        Add-Limitation '晋级工具自查使用其自建 GUID 合成仓库，不构成产品回归或真实晋级验收。'
    }

    # ---- 2. JSON-contract wrapper shared by the real preflight and the self-tests ----
    # The promotion entry returns PowerShell objects, whose default host rendering is a
    # formatted table, not JSON. Parsing that table was the previous N06 assumption and it
    # failed once main and develop shared a HEAD (NoPromotionNeeded). The wrapper keeps the
    # real exit code and serialises the returned object, so assertions read stable fields
    # instead of guessing at formatted text. A thrown preflight keeps its diagnostic on
    # stderr and exits 1.
    $wrapperPath = Join-Path $EvidenceDirectory 'promotion-preflight-wrapper.ps1'
    $wrapperSource = @'
#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$SourceRepository,
    [Parameter(Mandatory = $true)][string]$TargetRepository,
    [Parameter(Mandatory = $true)][string]$PromoteScript
)
$ErrorActionPreference = 'Stop'
try {
    $result = & $PromoteScript -SourceRepository $SourceRepository -TargetRepository $TargetRepository
    $result | ConvertTo-Json -Depth 8
    exit 0
}
catch {
    [Console]::Error.WriteLine([string]$_.Exception.Message)
    if ($_.ScriptStackTrace) { [Console]::Error.WriteLine([string]$_.ScriptStackTrace) }
    exit 1
}
'@
    [IO.File]::WriteAllText($wrapperPath, $wrapperSource, $script:Utf8Bom)

    function Invoke-PromotionPreflight {
        param([string]$SourceRepository, [string]$TargetRepository, [string]$Tag)
        $promote = Join-Path $RepoRoot 'scripts\promote-local.ps1'
        $arguments = '-SourceRepository "' + $SourceRepository + '" -TargetRepository "' + $TargetRepository + '" -PromoteScript "' + $promote + '"'
        $run = Invoke-ReleasePowerShellScript -ScriptPath $wrapperPath -ScriptArguments $arguments -Tag $Tag -TimeoutSeconds 300
        $stdout = Get-ReleaseTextFile $run.StdoutPath
        $stderr = Get-ReleaseTextFile $run.StderrPath
        [void](Save-EvidenceText ($Tag + '-wrapper-stdout') $stdout)
        [void](Save-EvidenceText ($Tag + '-wrapper-stderr') $stderr)
        $parsed = $null
        if ($run.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stdout)) {
            try { $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
        }
        return [pscustomobject]@{
            ExitCode = $run.ExitCode
            TimedOut = $run.TimedOut
            Stdout   = $stdout
            Stderr   = $stderr
            Parsed   = $parsed
        }
    }

    # ---- 2a. optional read-only preflight against this machine's real repositories ----
    # The generic suite must not require a sibling "main" checkout: the promotion tool's
    # own GUID fixtures already cover fast-forward, conflict and dirty blocking. When a
    # real sibling exists we add one extra observation; absence is a limitation, not a gap.
    $repositoriesRoot = Split-Path -Parent $RepoRoot
    $developPath = $RepoRoot
    $mainPath = Join-Path $repositoriesRoot 'main'
    $isGitDevelop = [IO.Directory]::Exists((Join-Path $developPath '.git'))
    $isGitMain = [IO.Directory]::Exists((Join-Path $mainPath '.git'))
    if (-not ($isGitDevelop -and $isGitMain)) {
        Add-Limitation ('本机无独立 develop/main 兄弟仓库（develop=' + $isGitDevelop + '; main=' + $isGitMain + '）；真实只读预检未观察，不影响通用套件结论。')
    }
    else {
        $developHeadBefore = (& git -C $developPath rev-parse HEAD 2>&1 | Out-String).Trim()
        $mainHeadBefore = (& git -C $mainPath rev-parse HEAD 2>&1 | Out-String).Trim()
        $headsEqual = ($developHeadBefore -ceq $mainHeadBefore)
        $preflight = Invoke-PromotionPreflight -SourceRepository $developPath -TargetRepository $mainPath -Tag 'real-preflight'
        $developHeadAfter = (& git -C $developPath rev-parse HEAD 2>&1 | Out-String).Trim()
        $mainHeadAfter = (& git -C $mainPath rev-parse HEAD 2>&1 | Out-String).Trim()
        Assert-Equal 'read-only preflight leaves develop HEAD unchanged' $developHeadBefore $developHeadAfter $developPath
        Assert-Equal 'read-only preflight leaves main HEAD unchanged' $mainHeadBefore $mainHeadAfter $mainPath
        Assert-True 'read-only preflight does not time out' (-not $preflight.TimedOut) ('timedOut=' + [string]$preflight.TimedOut)

        if ($headsEqual) {
            # Equal HEAD is the documented NoPromotionNeeded path, but the entry still
            # validates repository state first (Get-LpRepository runs in promote-local.ps1
            # before the equal-HEAD shortcut). A dirty worktree therefore produces the same
            # diagnostic refusal as the differing-HEAD case; both are legal, and both must
            # leave HEADs unchanged with nothing executed. A JSON success object is only
            # accepted when it is exactly NoPromotionNeeded with Executed=false.
            $diagnosticText = ($preflight.Stderr + "`n" + $preflight.Stdout)
            $blockedNonZero = ($null -ne $preflight.ExitCode -and [int]$preflight.ExitCode -ne 0 -and $diagnosticText -match '(?i)Dirty worktree|untracked|evidence|mismatch|failed|Required')
            if ($null -ne $preflight.Parsed) {
                $status = [string](Get-ReleasePropertyValue $preflight.Parsed 'Status')
                $executed = Get-ReleasePropertyValue $preflight.Parsed 'Executed'
                Assert-Equal 'real equal-HEAD preflight exits zero when it returns a JSON status' 0 $preflight.ExitCode $preflight.Stderr
                Assert-Equal 'real equal-HEAD preflight reports NoPromotionNeeded' 'NoPromotionNeeded' $status
                Assert-True 'real equal-HEAD preflight reports Executed=false' ($null -ne $executed -and [bool]$executed -eq $false) ([string]$executed)
                Add-Limitation '真实预检报告 NoPromotionNeeded（main 与 develop 同源）；未执行晋级。'
            }
            else {
                Assert-True 'real equal-HEAD preflight without JSON is a nonzero diagnostic refusal' $blockedNonZero $diagnosticText.Substring(0, [math]::Min(500, $diagnosticText.Length))
                Add-Limitation '真实预检在 main 与 develop 同源时仍被当前工作区状态阻止（同 HEAD 快捷分支位于仓库状态校验之后）；未执行晋级，未返回 JSON。'
            }
        }
        else {
            # Different HEAD: either the tool refuses with a diagnostic and nonzero exit, or
            # it returns Ready/NotExecuted with Executed=false. Executed fast-forward never
            # belongs in a preflight observation.
            if ($null -ne $preflight.Parsed) {
                $status = [string](Get-ReleasePropertyValue $preflight.Parsed 'Status')
                $executed = Get-ReleasePropertyValue $preflight.Parsed 'Executed'
                $readyNotExecuted = ($status -in @('Ready', 'NotExecuted') -and ($null -eq $executed -or [bool]$executed -eq $false))
                Assert-True 'real preflight reports Ready or NotExecuted without execution when heads differ' $readyNotExecuted ($status + '; executed=' + [string]$executed)
                Assert-True 'real preflight never reports an executed fast-forward' ($status -ne 'FastForwarded') $status
                Add-Limitation '真实预检报告 Ready/NotExecuted（工作区满足条件）；仍未执行晋级，两侧 HEAD 未变。'
            }
            else {
                $blockedNonZero = ($null -ne $preflight.ExitCode -and [int]$preflight.ExitCode -ne 0 -and (($preflight.Stderr + "`n" + $preflight.Stdout) -match '(?i)Dirty|untracked|evidence|mismatch|failed|Required'))
                Assert-True 'real preflight with differing heads is blocked-with-diagnostic or Ready without execution' $blockedNonZero (($preflight.Stdout + "`n" + $preflight.Stderr).Substring(0, [math]::Min(500, ($preflight.Stdout + "`n" + $preflight.Stderr).Length)))
                Add-Limitation '真实预检按预期被当前工作区状态阻止（非零退出并给出原因）；未执行任何晋级。'
            }
        }

        # Target must not have gained ignored-file blocking changes from this case.
        $targetIgnored = @(& git -C $mainPath ls-files --others --ignored --exclude-standard 2>&1)
        [void](Save-Evidence 'real-preflight-target-ignored' $targetIgnored)
    }

    # ---- 2b. wrapper contract self-test on synthetic GUID repositories ----------------
    # A guard only: equal HEAD must be NoPromotionNeeded with nothing executed. Fixtures live
    # in %TEMP% and are removed afterwards; no real repository or cache is touched.
    $fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sjc-n06-fixture-' + [guid]::NewGuid().ToString('N'))
    $fixtureSource = Join-Path $fixtureRoot 'develop'
    $fixtureTarget = Join-Path $fixtureRoot 'main'
    try {
        [void][IO.Directory]::CreateDirectory($fixtureRoot)
        & git init --quiet --initial-branch=develop $fixtureSource 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('fixture git init failed: ' + $fixtureSource) }
        Set-Content -LiteralPath (Join-Path $fixtureSource 'fixture.txt') -Value 'baseline' -Encoding ASCII
        & git -C $fixtureSource add --all 2>&1 | Out-Null
        & git -C $fixtureSource -c 'user.name=Local promotion test' -c 'user.email=local-test@example.invalid' -c 'commit.gpgsign=false' commit --quiet -m 'fixture baseline' 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('fixture git commit failed: ' + $fixtureSource) }
        # Clone so the target shares the exact baseline commit object, then rename its branch
        # to main; this keeps both HEADs byte-identical without inventing commit dates.
        & git clone --quiet $fixtureSource $fixtureTarget 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ('fixture git clone failed: ' + $fixtureTarget) }
        & git -C $fixtureTarget branch -m main 2>&1 | Out-Null
        & git -C $fixtureTarget checkout --quiet main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'fixture target branch rename failed' }
        $fixtureSourceHead = (& git -C $fixtureSource rev-parse HEAD 2>&1 | Out-String).Trim()
        $fixtureTargetHead = (& git -C $fixtureTarget rev-parse HEAD 2>&1 | Out-String).Trim()
        Assert-Equal 'fixture repositories share the same baseline HEAD' $fixtureSourceHead $fixtureTargetHead $fixtureRoot

        $equalRun = Invoke-PromotionPreflight -SourceRepository $fixtureSource -TargetRepository $fixtureTarget -Tag 'fixture-equal-head'
        Assert-Equal 'fixture equal-HEAD preflight exits zero' 0 $equalRun.ExitCode $equalRun.Stderr
        Assert-True 'fixture equal-HEAD preflight prints parseable JSON' ($null -ne $equalRun.Parsed) $equalRun.Stdout
        Assert-Equal 'fixture equal-HEAD preflight reports NoPromotionNeeded' 'NoPromotionNeeded' ([string](Get-ReleasePropertyValue $equalRun.Parsed 'Status'))
        Assert-True 'fixture equal-HEAD preflight reports Executed=false' ([bool](Get-ReleasePropertyValue $equalRun.Parsed 'Executed') -eq $false) ([string](Get-ReleasePropertyValue $equalRun.Parsed 'Executed'))
        $equalTargetAfter = (& git -C $fixtureTarget rev-parse HEAD 2>&1 | Out-String).Trim()
        Assert-Equal 'fixture equal-HEAD preflight leaves target HEAD unchanged' $fixtureTargetHead $equalTargetAfter $fixtureTarget
        Add-Limitation 'N06 自建 GUID 仓库仅守卫同 HEAD 的 NoPromotionNeeded JSON 契约；无证据拒绝、seal 与真实快进由晋级工具自测和真实预检分别覆盖。'
    }
    finally {
        if ([IO.Directory]::Exists($fixtureRoot)) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Assert-True 'synthetic promotion fixtures were removed' (-not [IO.Directory]::Exists($fixtureRoot)) $fixtureRoot

    # ---- 3. static guard: cloud placeholder tag mask cannot admit junctions -------
    $common = [IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts\local-promotion-common.ps1'))
    Assert-True 'promotion common defines an explicit cloud-tag predicate' ($common -match 'IsCloudTag') ''
    Assert-True 'cloud predicate is tag-based, not attribute-only' ($common -match 'GetFileInformationByHandleEx|FILE_ATTRIBUTE_TAG_INFO|TagInfo') ''
    Assert-True 'cloud predicate excludes name-surrogate tags in a comment or code' (($common -match '(?i)name.surrogate') -or ($common -match '0xA000')) '(no explicit exclusion found)'
    Assert-True 'reparse rejection still precedes the cloud allowance' ($common -match '(?is)ReparsePoint.*Test-LpCloudPlaceholder') ''
    Add-Limitation '云占位标签判定仅做静态检查；本机实际为 0x9000601a 无重定向，junction/symlink 由自测仓库覆盖。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
