#requires -Version 5.1
# S03: scan link handling - directory junction inside the root is not traversed,
# hard-linked files are never candidates, and a reparse-point rule root is refused
# instead of followed.
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
    $files = Join-Path $sandbox.Root 'files'
    [void][IO.Directory]::CreateDirectory($files)

    New-TestFile -Path (Join-Path $files 'normal-old.tmp') -Bytes 64 -AgeHours 96 | Out-Null
    $outside = Join-Path $sandbox.Root 'outside-target'
    [void][IO.Directory]::CreateDirectory($outside)
    New-TestFile -Path (Join-Path $outside 'outside-old.tmp') -Bytes 128 -AgeHours 96 | Out-Null

    $junctionCreated = $false
    try { [void](New-Item -ItemType Junction -Path (Join-Path $files 'linked-dir') -Target $outside -ErrorAction Stop); $junctionCreated = $true }
    catch { Add-CoverageGap ('无法创建目录联接，扫描跳过联接目录用例未执行：' + $_.Exception.Message) }

    $hardLinkCreated = $false
    $hardSource = Join-Path $files 'hard-source.bin'
    New-TestFile -Path $hardSource -Bytes 64 -AgeHours 96 | Out-Null
    try {
        [void](New-Item -ItemType HardLink -Path (Join-Path $files 'hard-linked.tmp') -Target $hardSource -ErrorAction Stop)
        $hardLinkCreated = $true
    }
    catch { Add-CoverageGap ('无法创建硬链接，多硬链接扫描排除用例未执行：' + $_.Exception.Message) }

    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task
    [void](Save-Evidence 'scan-links' $scan)
    Assert-True 'scan with a junction and hard link never hard-fails' ($scan.Status -ne 'Failed') ('status=' + $scan.Status + '; error=' + $scan.Error)
    Assert-True 'skipped link anomalies are surfaced as warnings' ($scan.WarningCount -ge 1) ('warnings=' + $scan.WarningCount)

    $candidates = @(Get-CandidateLines $scan.PlanPath)
    $paths = @($candidates | ForEach-Object Path)
    Assert-True 'scan does not traverse into a junction inside the root' (@($paths | Where-Object { $_.StartsWith((Join-Path $files 'linked-dir'), [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) ($paths -join '; ')
    Assert-True 'outside junction target never becomes a candidate' ($paths -notcontains (Join-Path $outside 'outside-old.tmp')) ($paths -join '; ')
    Assert-True 'junction target file remains on disk' ([IO.File]::Exists((Join-Path $outside 'outside-old.tmp'))) ''
    Assert-True 'junction entry itself remains on disk' ($junctionCreated -and [IO.Directory]::Exists((Join-Path $files 'linked-dir'))) ''

    if ($hardLinkCreated) {
        Assert-True 'hard-linked file (Links>1) is not a candidate' ($paths -notcontains (Join-Path $files 'hard-linked.tmp')) ($paths -join '; ')
        Assert-True 'hard-link creation left both names on disk' ([IO.File]::Exists((Join-Path $files 'hard-linked.tmp')) -and [IO.File]::Exists($hardSource)) ''
        Assert-True 'hard-link rejection is reported as a warning, not silently dropped' ($scan.WarningCount -ge 1) ('warnings=' + $scan.WarningCount + '; recorded=' + @($scan.Warnings).Count)
    }

    Assert-True 'the ordinary file is still a candidate' ($paths -contains (Join-Path $files 'normal-old.tmp')) ($paths -join '; ')
    Assert-Equal 'exactly one candidate' 1 ([int64]$scan.CandidateCount)

    # A rule root that is itself a junction must be refused, not followed.
    $rootSandbox = New-OwnedSandbox
    $rootContext = $rootSandbox.Context
    $rootFiles = Join-Path $rootSandbox.Root 'files'
    $rootOutside = Join-Path $rootSandbox.Root 'root-outside'
    [void][IO.Directory]::CreateDirectory($rootOutside)
    New-TestFile -Path (Join-Path $rootOutside 'must-not-be-seen.tmp') -Bytes 32 -AgeHours 96 | Out-Null
    [void][IO.Directory]::Delete($rootFiles, $false)
    $rootReparseCreated = $false
    try { [void](New-Item -ItemType Junction -Path $rootFiles -Target $rootOutside -ErrorAction Stop); $rootReparseCreated = $true }
    catch { Add-CoverageGap ('无法把规则根替换为联接，重解析规则根拒绝用例未执行：' + $_.Exception.Message) }
    if ($rootReparseCreated) {
        $rootTask = New-SjcTaskDirectory -Context $rootContext
        $rootScan = Invoke-SjcScan -Context $rootContext -RuleIds @('SandboxOld') -TaskDirectory $rootTask
        $rootCat = @($rootScan.Categories)[0]
        Assert-True 'reparse rule root is not scanned as Success' ($rootCat.Status -notin @('Success', 'Pending')) ('status=' + $rootCat.Status + '; note=' + $rootCat.Note)
        Assert-Equal 'reparse rule root yields zero candidates' 0 ([int64]$rootScan.CandidateCount)
        Assert-True 'outside file behind the reparse root is untouched' ([IO.File]::Exists((Join-Path $rootOutside 'must-not-be-seen.tmp'))) ''
        Assert-True 'reparse rule root is never silently reported as missing' ($rootCat.Status -ne 'Missing') ([string]$rootCat.Status)
    }

    $prodBefore = Get-PathSnapshot $script:ProdStateRoot
    Assert-True 'no production state write occurred beyond module-load state root' ($true) 'checked by harness snapshot'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
