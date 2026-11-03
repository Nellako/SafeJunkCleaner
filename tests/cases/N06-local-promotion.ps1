#requires -Version 5.1
# N06: local promotion tooling, executed independently of the author's self-check.
# 1) Runs scripts/test-local-promotion.ps1 (its own GUID repositories under %TEMP%) and
#    requires the scripted 30/30 result plus a zero exit code.
# 2) Runs a read-only preflight against the real develop/main repositories: it must either
#    stop on the dirty worktree or (if clean) only report Ready with Executed=false.
#    No promotion is executed and main HEAD must be unchanged.
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

    # ---- 2. optional read-only preflight against this machine's real repositories -----
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
        $mainHeadBefore = (& git -C $mainPath rev-parse HEAD 2>&1 | Out-String).Trim()
        $promote = Join-Path $RepoRoot 'scripts\promote-local.ps1'
        $preflightArgs = '-SourceRepository "' + $developPath + '" -TargetRepository "' + $mainPath + '"'
        $preflight = Invoke-ReleasePowerShellScript -ScriptPath $promote -ScriptArguments $preflightArgs -Tag 'real-preflight' -TimeoutSeconds 300
        $out = Get-ReleaseTextFile $preflight.StdoutPath
        $err = Get-ReleaseTextFile $preflight.StderrPath
        [void](Save-EvidenceText 'real-preflight-stdout' $out)
        [void](Save-EvidenceText 'real-preflight-stderr' $err)
        $mainHeadAfter = (& git -C $mainPath rev-parse HEAD 2>&1 | Out-String).Trim()
        Assert-Equal 'read-only preflight leaves main HEAD unchanged' $mainHeadBefore $mainHeadAfter $mainPath
        Assert-True 'read-only preflight does not time out' (-not $preflight.TimedOut) ('timedOut=' + [string]$preflight.TimedOut)

        # Real contract: either the tool refuses the current worktree with a diagnostic
        # exit, or it emits JSON status NoPromotionNeeded / Ready(NotExecuted). No regex
        # guessing of unrelated text.
        $combined = ($out + "`n" + $err)
        $jsonText = ''
        $jsonStart = $out.IndexOf('{')
        if ($jsonStart -ge 0) { $jsonText = $out.Substring($jsonStart) }
        $preflightObject = $null
        if ($jsonText) { try { $preflightObject = $jsonText | ConvertFrom-Json -ErrorAction Stop } catch { $preflightObject = $null } }
        $blockedNonZero = ($null -ne $preflight.ExitCode -and [int]$preflight.ExitCode -ne 0 -and $combined -match '(?i)Dirty|untracked|evidence|mismatch|failed|Required')
        $noPromotion = ($null -ne $preflightObject -and [string]$preflightObject.Status -eq 'NoPromotionNeeded')
        $readyNotExecuted = ($null -ne $preflightObject -and [string]$preflightObject.Status -in @('Ready', 'NotExecuted') -and ($null -eq $preflightObject.PSObject.Properties['Executed'] -or [bool]$preflightObject.Executed -eq $false))
        Assert-True 'real preflight is blocked-with-diagnostic, NoPromotionNeeded, or Ready without execution' ($blockedNonZero -or $noPromotion -or $readyNotExecuted) $combined.Substring(0, [math]::Min(500, $combined.Length))
        if ($null -ne $preflightObject) {
            Assert-True 'real preflight never reports an executed fast-forward' ([string]$preflightObject.Status -ne 'FastForwarded') ([string]$preflightObject.Status)
        }
        if ($noPromotion) { Add-Limitation '真实预检报告 NoPromotionNeeded（main 已与 develop 同源）；未执行晋级。' }
        elseif ($readyNotExecuted) { Add-Limitation '真实预检报告 Ready/NotExecuted（工作区满足条件）；仍未执行晋级，main HEAD 未变。' }
        else { Add-Limitation '真实预检按预期被当前工作区状态阻止（非零退出并给出原因）；未执行任何晋级。' }

        # Target must not have gained ignored-file blocking changes from this case.
        $targetIgnored = @(& git -C $mainPath ls-files --others --ignored --exclude-standard 2>&1)
        [void](Save-Evidence 'real-preflight-target-ignored' $targetIgnored)
    }

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
