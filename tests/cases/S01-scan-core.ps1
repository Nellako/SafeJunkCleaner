#requires -Version 5.1
# S01: scan core - age gate, pattern gate, exclusion patterns, category states,
# full JSONL persistence, progress file fields, sealed metadata and no deletion.
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

    # Age: SandboxOld needs 24h, SandboxLog needs 48h.
    New-TestFile -Path (Join-Path $files 'old23.tmp')  -Bytes 230 -AgeHours 23 | Out-Null
    New-TestFile -Path (Join-Path $files 'old25.tmp')  -Bytes 250 -AgeHours 25 | Out-Null
    New-TestFile -Path (Join-Path $files 'log47.log')  -Bytes 470 -AgeHours 47 | Out-Null
    New-TestFile -Path (Join-Path $files 'log49.log')  -Bytes 490 -AgeHours 49 | Out-Null
    New-TestFile -Path (Join-Path $files 'note.txt')   -Bytes 100 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'db.sqlite-wal') -Bytes 100 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'db.sqlite-shm') -Bytes 100 -AgeHours 100 | Out-Null
    New-TestFile -Path (Join-Path $files 'sub\deep\old30.tmp') -Bytes 300 -AgeHours 30 | Out-Null

    $task = New-SjcTaskDirectory -Context $context
    $progress = Join-Path $task 'progress.json'
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld', 'SandboxLog') -TaskDirectory $task -ProgressPath $progress -CustomEnabled $true
    [void](Save-Evidence 'scan-result' $scan)

    Assert-Equal 'scan status is Success' 'Success' $scan.Status $scan.Error
    Assert-Equal 'scan reports the version.json product version' (Get-SjcVersion) ([string]$scan.Version)
    Assert-Equal 'scan reports the Medium tier it was opened with' 'Medium' ([string]$scan.CleaningProfile)
    Assert-True 'scan reports CustomEnabled=true for a direct rule-list call' ($scan.CustomEnabled -eq $true) ([string]$scan.CustomEnabled)
    Assert-Equal 'scan TaskId equals the task directory GUID' ([IO.Path]::GetFileName($task)) ([string]$scan.TaskId)

    $candidates = @(Get-CandidateLines $scan.PlanPath)
    $names = @($candidates | ForEach-Object { [IO.Path]::GetFileName($_.Path) } | Sort-Object)
    Assert-Equal 'only files passing age must be candidates' 'log49.log|old25.tmp|old30.tmp' ($names -join '|')
    Assert-Equal 'CandidateCount matches persisted lines' $candidates.Count ([int64]$scan.CandidateCount)
    Assert-Equal 'CandidateBytes equals summed lengths' ([int64](($candidates | Measure-Object -Property Length -Sum).Sum)) ([int64]$scan.CandidateBytes)

    Assert-True 'scan never deletes candidate files' (@($candidates | Where-Object { -not [IO.File]::Exists($_.Path) }).Count -eq 0 -and [IO.File]::Exists((Join-Path $files 'sub\deep\old30.tmp'))) ''
    Assert-True 'files excluded from candidates all still exist' ((Test-Path (Join-Path $files 'old23.tmp')) -and (Test-Path (Join-Path $files 'log47.log')) -and (Test-Path (Join-Path $files 'note.txt')) -and (Test-Path (Join-Path $files 'db.sqlite-wal')) -and (Test-Path (Join-Path $files 'db.sqlite-shm'))) ''

    Assert-True 'candidate records carry exactly the contract fields' (@($candidates | Where-Object { @($_.PSObject.Properties.Name | Sort-Object) -join ',' -ne 'FileIdentity,Id,LastWriteUtc,Length,Path,RuleId' }).Count -eq 0) (@($candidates[0].PSObject.Properties.Name) -join ',')
    $badIds = @($candidates | Where-Object { $_.Id -cnotmatch '^[a-f0-9]{32}$' })
    Assert-True 'candidate ids are 32-hex GUIDs' ($badIds.Count -eq 0) ($badIds.Count)
    Assert-Equal 'candidate ids are unique' $candidates.Count (@($candidates | ForEach-Object Id | Select-Object -Unique).Count)
    Assert-Equal 'candidate paths are unique' $candidates.Count (@($candidates | ForEach-Object Path | Select-Object -Unique).Count)
    $badLengths = @($candidates | Where-Object { $_.Length -isnot [long] -and $_.Length -isnot [int] })
    Assert-True 'candidate lengths are integers' ($badLengths.Count -eq 0) ''
    $badStamps = @($candidates | Where-Object { $_.LastWriteUtc -isnot [string] -or $_.LastWriteUtc -notmatch '^\d{4}-\d{2}-\d{2}T' })
    Assert-True 'candidate timestamps are ISO round-trip strings' ($badStamps.Count -eq 0) ''
    Assert-True 'candidate rule ids are only the selected rules' (@($candidates | Where-Object { $_.RuleId -notin @('SandboxOld', 'SandboxLog') }).Count -eq 0) ''
    Assert-True 'every candidate is a regular file under the sandbox root' (@($candidates | Where-Object { -not [IO.File]::Exists($_.Path) -or -not $_.Path.StartsWith($files, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) ''

    $byRule = @{}
    foreach ($c in $candidates) { if (-not $byRule.ContainsKey($c.RuleId)) { $byRule[$c.RuleId] = 0 }; $byRule[$c.RuleId]++ }
    Assert-Equal 'SandboxOld category count' 2 $byRule['SandboxOld']
    Assert-Equal 'SandboxLog category count' 1 $byRule['SandboxLog']

    $categories = @($scan.Categories)
    Assert-Equal 'one category per selected rule' 2 $categories.Count
    # New contract: each category also exposes the sealing profile and the effective
    # minimum age that produced the candidate counts.
    $categoryProps = @('RuleId', 'Name', 'Group', 'Risk', 'Root', 'CleaningProfile', 'MinimumAgeHours', 'Count', 'Bytes', 'Status', 'Note') | Sort-Object
    $badCategoryShape = @($categories | Where-Object { $actual = (@($_.PSObject.Properties.Name | Sort-Object) -join ','); $actual -ne ($categoryProps -join ',') })
    Assert-True 'categories expose the contract fields' ($badCategoryShape.Count -eq 0) (@($categories[0].PSObject.Properties.Name) -join ',')
    $oldCat = @($categories | Where-Object { $_.RuleId -eq 'SandboxOld' })[0]
    Assert-Equal 'SandboxOld category bytes' 550 ([int64]$oldCat.Bytes)
    Assert-Equal 'SandboxOld category status' 'Success' $oldCat.Status

    $planBytes = [IO.File]::ReadAllBytes($scan.PlanPath)
    Assert-True 'candidate JSONL has no UTF-8 BOM' (-not ($planBytes.Length -ge 3 -and $planBytes[0] -eq 0xEF -and $planBytes[1] -eq 0xBB -and $planBytes[2] -eq 0xBF)) ''
    $planText = [Text.Encoding]::UTF8.GetString($planBytes)
    Assert-Equal 'plan has one JSON object per line (no sample truncation)' $candidates.Count (@(($planText -split "`r?`n") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count)

    $metaPath = Join-Path $task 'scan.meta.json'
    Assert-True 'scan.meta.json exists' ([IO.File]::Exists($metaPath)) $metaPath
    $metaRaw = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8
    Assert-True 'scan metadata is DPAPI-sealed, not readable JSON' (-not ($metaRaw -match '"PlanHash"')) ('length=' + $metaRaw.Length)
    Assert-Equal 'plan file is fixed at candidates.jsonl' 'candidates.jsonl' ([IO.Path]::GetFileName([string]$scan.PlanPath))

    Assert-True 'progress file was written' ([IO.File]::Exists($progress)) $progress
    if ([IO.File]::Exists($progress)) {
        $progressObj = Get-Content -LiteralPath $progress -Raw -Encoding UTF8 | ConvertFrom-Json
        $pNames = @($progressObj.PSObject.Properties.Name | Sort-Object)
        Assert-Equal 'progress has Text/Reviewed/CandidateCount/UpdatedUtc' 'CandidateCount,Reviewed,Text,UpdatedUtc' ($pNames -join ',')
        Assert-True 'progress CandidateCount is the final candidate count' ([int64]$progressObj.CandidateCount -eq [int64]$scan.CandidateCount) ([string]$progressObj.CandidateCount)
    }

    Assert-True 'scan log path exists and is unique-shaped' ($scan.LogPath -and [IO.File]::Exists($scan.LogPath) -and ([IO.Path]::GetFileName($scan.LogPath) -match '^scan-[0-9a-f-]{36}\.json$')) ([string]$scan.LogPath)

    # Missing root and channel misuse must be distinct states, never silent zero.
    $emptySandbox = New-OwnedSandbox
    $emptyContext = $emptySandbox.Context
    [void][IO.Directory]::Delete((Join-Path $emptySandbox.Root 'files'), $false)
    $emptyTask = New-SjcTaskDirectory -Context $emptyContext
    $missing = Invoke-SjcScan -Context $emptyContext -RuleIds @('SandboxOld') -TaskDirectory $emptyTask -CustomEnabled $true
    $missingCategories = @($missing.Categories)
    $missingCategory = @($missingCategories | Where-Object { $_.RuleId -eq 'SandboxOld' })[0]
    Assert-Equal 'missing root is reported as a distinct Missing category' 'Missing' $missingCategory.Status $missing.Error
    Assert-Equal 'missing root is not reported as zero candidates in a Success category' '0|0' ([string]$missingCategory.Count + '|' + [string]$missingCategory.Bytes)
    Assert-Equal 'missing root produces no candidates' 0 ([int64]$missing.CandidateCount)
    Assert-True 'missing root is never reported as Failed' ($missing.Status -ne 'Failed') ([string]$missing.Status)

    $freshTask = New-SjcTaskDirectory -Context $context
    $badChannel = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $freshTask -CustomEnabled $true -CancelPath (Join-Path $task 'shared.flag') -ProgressPath (Join-Path $task 'shared.flag')
    Assert-True 'overlapping channels fail the scan' ($badChannel.Status -eq 'Failed') $badChannel.Error
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
