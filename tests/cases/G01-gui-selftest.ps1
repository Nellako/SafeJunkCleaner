#requires -Version 5.1
# G01: real Test-SjcGui against a 450-candidate sealed sandbox plan.
# Failures (including a missing GUI module) are failures, never skips.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$LoadGui,
    [string]$ExePath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui -ExePath $ExePath
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
try {
    $guiReady = Assert-ReleaseGuiModule
    if ($guiReady) {
        $command = Get-Command Test-SjcGui -CommandType Function
        Assert-True 'Test-SjcGui exposes -PlanPath' ($command.Parameters.ContainsKey('PlanPath')) (@($command.Parameters.Keys) -join ',')
        Assert-True 'Test-SjcGui exposes -ScreenshotDirectory' ($command.Parameters.ContainsKey('ScreenshotDirectory')) (@($command.Parameters.Keys) -join ',')
    }

    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $filesRoot = Join-Path $sandbox.Root 'files'
    for ($i = 0; $i -lt 450; $i++) {
        $extension = if ($i % 3 -eq 2) { '.log' } else { '.tmp' }
        $name = 'candidate{0:D3}{1}' -f $i, $extension
        New-TestFile -Path (Join-Path $filesRoot $name) -Bytes (100 + $i) -AgeHours 100 | Out-Null
    }
    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task
    Assert-Equal 'sandbox scan Status' 'Success' $scan.Status $scan.Error
    Assert-Equal 'sandbox scan seals all 450 candidates' 450 ([int64]$scan.CandidateCount) $scan.Error
    $planPath = [string]$scan.PlanPath
    $planHash = Get-FileSha256 $planPath
    $candidatePaths = @(Get-CandidateLines $planPath | ForEach-Object { [string]$_.Path })
    Assert-Equal 'sealed plan has 450 readable candidate lines' 450 $candidatePaths.Count ''
    Assert-True 'sealed plan is candidates.jsonl' ([IO.Path]::GetFileName($planPath) -eq 'candidates.jsonl') $planPath

    if ($guiReady) {
        $stateRoot = Get-SjcProductionStateRoot
        $entriesBefore = @(Get-ReleaseStateRootEntries $stateRoot)
        $preferenceBefore = Get-FileSha256 (Join-Path $stateRoot 'preferences-v3.json')
        $shotDirectory = Join-Path $EvidenceDirectory 'gui-shots'

        $sw = [Diagnostics.Stopwatch]::StartNew()
        $gui = Test-SjcGui -PlanPath $planPath -ScreenshotDirectory $shotDirectory
        $sw.Stop()
        [void](Save-Evidence 'g01-gui-result' $gui)

        Assert-True 'Test-SjcGui returned an object' ($null -ne $gui) 'null result'
        if ($null -ne $gui) {
            Assert-True 'Test-SjcGui Name is present' (-not [string]::IsNullOrWhiteSpace([string]$gui.Name)) ([string]$gui.Name)
            Assert-Equal 'Test-SjcGui Version matches version.json' (Get-SjcVersion) ([string]$gui.Version) ''
            Assert-Equal 'Test-SjcGui Status' 'Success' ([string]$gui.Status) (@($gui.Failed) -join ' | ')
            $passedOk = (Test-ReleaseStringList $gui.Passed) -and @($gui.Passed).Count -gt 0 -and @($gui.Passed | Where-Object { $_ -isnot [string] }).Count -eq 0
            Assert-True 'Test-SjcGui Passed is a non-empty string array (not a boolean)' $passedOk ('type=' + $(if ($null -eq $gui.Passed) { 'null' } else { $gui.Passed.GetType().Name }) + '; passed=' + @($gui.Passed).Count)
            Assert-True 'Test-SjcGui Failed is an empty array' ((Test-ReleaseStringList $gui.Failed) -and @($gui.Failed).Count -eq 0) (@($gui.Failed) -join ' | ')
            Assert-True 'Test-SjcGui Skipped is an array' (Test-ReleaseStringList $gui.Skipped) ('type=' + $(if ($null -eq $gui.Skipped) { 'null' } else { $gui.Skipped.GetType().Name }))
            Assert-True 'Test-SjcGui Passed includes a real sealed-plan pagination item' (@($gui.Passed | Where-Object { $_ -match '(?i)pagin|page|分页|T17|计划' }).Count -gt 0) (@($gui.Passed) -join ' | ')
            if (@($gui.Skipped).Count -gt 0) { Add-Limitation ('Test-SjcGui Skipped: ' + (@($gui.Skipped) -join ' | ')) }
            [void](Save-EvidenceText 'g01-duration' ('elapsedMs=' + $sw.ElapsedMilliseconds))
        }

        Assert-Equal 'sealed plan hash changed by GUI self-test not allowed' $planHash (Get-FileSha256 $planPath) $planPath
        $gone = @($candidatePaths | Where-Object { -not [IO.File]::Exists($_) })
        Assert-Equal 'GUI self-test deleted no candidate file' 0 $gone.Count (($gone | Select-Object -First 5) -join '; ')
        Assert-ReleaseStateRootStable -StateRoot $stateRoot -BeforeEntries $entriesBefore -BeforePreferenceHash $preferenceBefore -Tag 'Test-SjcGui' -AllowedNew @()

        $shots = @(Get-ChildItem -LiteralPath $shotDirectory -File -Filter '*.png' -ErrorAction SilentlyContinue)
        Assert-True 'GUI screenshots were written' ($shots.Count -ge 1) $shotDirectory
        $badPng = @($shots | Where-Object {
            $bytes = [IO.File]::ReadAllBytes($_.FullName)
            $bytes.Length -lt 1024 -or $bytes[0] -ne 0x89 -or $bytes[1] -ne 0x50 -or $bytes[2] -ne 0x4E -or $bytes[3] -ne 0x47
        })
        Assert-Equal 'every GUI screenshot is a real non-trivial PNG' 0 $badPng.Count (($badPng | ForEach-Object { $_.Name }) -join ',')
        if ($shots.Count -ge 2) {
            $uniqueHashes = @($shots | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } | Select-Object -Unique)
            Assert-True 'distinct GUI views are not byte-identical screenshots' ($uniqueHashes.Count -ge 2) ($uniqueHashes.Count)
        }
        [void](Save-Evidence 'g01-screenshots' ([pscustomobject]@{
            Count = $shots.Count
            Files = @($shots | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = [int64]$_.Length; SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } })
        }))
    }
    else {
        Add-Limitation 'src/Gui.ps1 或 Test-SjcGui 缺失：G01 以失败结束，不计跳过。'
    }
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
