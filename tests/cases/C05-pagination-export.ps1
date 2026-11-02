#requires -Version 5.1
# C05: candidate pagination and full CSV export - more than 400 candidates paged in
# full, ExcludedIds applied, UTF-8 BOM CSV with explicit candidate columns and correct
# quoting for commas/CJK/legal special characters, and export destination guards.
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

    $total = 450
    # NTFS forbids double quotes in names; CSV quoting is exercised with commas, CJK,
    # spaces, ampersands, semicolons and apostrophes.
    for ($i = 1; $i -le $total; $i++) {
        $name = 'page-' + $i.ToString('000') + '.tmp'
        if ($i -eq 7) { $name = 'comma,name7.tmp' }
        if ($i -eq 8) { $name = "amp&name8's.tmp" }
        if ($i -eq 9) { $name = '中文 名称9.tmp' }
        if ($i -eq 10) { $name = 'both;comma,10.tmp' }
        New-TestFile -Path (Join-Path $files $name) -Bytes (100 + $i) -AgeHours 96 | Out-Null
    }
    $task = New-SjcTaskDirectory -Context $context
    $scan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $task
    Assert-Equal 'scan seals 450 candidates' 'Success|450' ($scan.Status + '|' + [int64]$scan.CandidateCount) $scan.Error
    Assert-Equal 'CandidateCount above 400 is complete, not truncated' 450 ([int64]$scan.CandidateCount)

    $page1 = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 0 -Limit 200)
    $page2 = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 200 -Limit 200)
    $page3 = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 400 -Limit 200)
    $page4 = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 600 -Limit 200)
    Assert-Equal 'page 1 has 200 candidates' 200 $page1.Count
    Assert-Equal 'page 2 has 200 candidates' 200 $page2.Count
    Assert-Equal 'page 3 has the remaining 50 candidates' 50 $page3.Count
    Assert-Equal 'page beyond the end is empty' 0 $page4.Count
    $pagedIds = @($page1 + $page2 + $page3 | ForEach-Object Id)
    Assert-Equal 'concatenated pages cover every candidate exactly once' $total (@($pagedIds | Select-Object -Unique).Count)
    Assert-Equal 'pagination preserves plan order' (@($page1[0].Id) -join '') ((Get-CandidateLines $scan.PlanPath)[0].Id)
    $defaultPage = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath)
    Assert-True 'default page size is bounded and non-zero' ($defaultPage.Count -gt 0 -and $defaultPage.Count -le 200) ([string]$defaultPage.Count)
    $maxPage = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 0 -Limit 1000)
    Assert-Equal 'limit 1000 returns all 450' 450 $maxPage.Count
    Assert-Throws 'limit above 1000 is rejected' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 1001 } ''
    Assert-Throws 'negative offset is rejected' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset -1 } ''
    Assert-Throws 'zero limit is rejected' { Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 0 } ''

    $otherName = Join-Path $task 'not-candidates.jsonl'
    Copy-Item -LiteralPath $scan.PlanPath -Destination $otherName -Force
    Assert-Throws 'a JSONL not named candidates.jsonl is refused' { Get-SjcCandidatePage -PlanPath $otherName -Limit 10 } '固定封存计划'

    # Full export with an ordinary subset excluded, so every special-character path stays in.
    $all = @(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Offset 0 -Limit 1000)
    $excluded = @($all | Where-Object { $_.Path -match 'page-001\.tmp|page-002\.tmp|page-003\.tmp|page-004\.tmp' } | ForEach-Object Id)
    Assert-Equal 'four ordinary candidates exist to exclude' 4 $excluded.Count
    $destination = Join-Path $sandbox.Root 'export-full.csv'
    $export = Export-SjcCandidates -PlanPath $scan.PlanPath -Destination $destination -ExcludedIds $excluded
    Assert-Equal 'export reports Success' 'Success' ([string]$export.Status)
    Assert-Equal 'exported rows equal 450-4' 446 ([int64]$export.ExportedCount)
    Assert-True 'export destination exists' ([IO.File]::Exists($destination)) $destination
    if ([IO.File]::Exists($destination)) { Copy-Item -LiteralPath $destination -Destination (Join-Path $EvidenceDirectory 'export-full.csv') -Force }

    $bytes = [IO.File]::ReadAllBytes($destination)
    Assert-True 'CSV starts with a UTF-8 BOM' ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) ''
    $csvLines = [IO.File]::ReadAllLines($destination)
    Assert-Equal 'CSV header uses explicit candidate columns' 'CandidateId,RuleId,CandidatePath,CandidateLengthBytes,LastWriteUtc' $csvLines[0]
    Assert-Equal 'CSV has header + 446 data rows' 447 $csvLines.Count
    $csvText = [IO.File]::ReadAllText($destination, [Text.Encoding]::UTF8)
    Assert-True 'CSV header does not claim freed space' (-not ($csvLines[0] -match '(?i)freed|released|clean')) $csvLines[0]
    $parsed = @($csvText | ConvertFrom-Csv)
    Assert-Equal 'ConvertFrom-Csv parses every exported row' 446 $parsed.Count
    $excludedPaths = @($all | Where-Object { $excluded -contains $_.Id } | ForEach-Object Path)
    Assert-True 'excluded candidates are absent from CSV' (@($parsed | Where-Object { $excludedPaths -contains $_.CandidatePath }).Count -eq 0) ''
    $expectedIncluded = $total - $excluded.Count
    Assert-Equal 'all non-excluded candidates appear in CSV' $expectedIncluded $parsed.Count
    $csvTotalBytes = 0
    foreach ($row in $parsed) { $csvTotalBytes += [int64]$row.CandidateLengthBytes }
    $expectedBytes = [int64](($all | Where-Object { $excluded -notcontains $_.Id } | Measure-Object -Property Length -Sum).Sum)
    Assert-Equal 'CSV byte column sums the included candidates' $expectedBytes $csvTotalBytes
    Assert-True 'an apostrophe+ampersand path is preserved after CSV parsing' (@($parsed | Where-Object { $_.CandidatePath -like "*amp&name8's.tmp*" }).Count -eq 1) ''
    Assert-True 'a comma path is preserved after CSV parsing' (@($parsed | Where-Object { $_.CandidatePath -like '*comma,name7.tmp*' }).Count -eq 1) ''
    Assert-True 'a CJK path is preserved after CSV parsing' (@($parsed | Where-Object { $_.CandidatePath -like '*中文 名称9.tmp*' }).Count -eq 1) ''
    Assert-True 'a combined semicolon+comma path survives round-trip' (@($parsed | Where-Object { $_.CandidatePath -like '*both;comma,10.tmp*' }).Count -eq 1) ''

    Assert-Throws 'export refuses an existing destination' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination $destination } '新文件'
    Assert-Throws 'export refuses a destination inside the state root' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $context.StateRoot 'inside.csv') } '内部状态'
    Assert-Throws 'export refuses an unknown excluded id' { Export-SjcCandidates -PlanPath $scan.PlanPath -Destination (Join-Path $sandbox.Root 'export2.csv') -ExcludedIds @('ffffffffffffffffffffffffffffffff') } '不属于本计划'

    # The export itself must not delete candidates.
    Assert-True 'all 450 candidate files still exist after export' (@($all | Where-Object { -not [IO.File]::Exists($_.Path) }).Count -eq 0) ''
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
