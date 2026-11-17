#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$BuildDirectory,
    [Parameter(Mandatory=$true)][string]$VerificationDirectory,
    [Parameter(Mandatory=$true)][string]$GuiAcceptancePath,
    [string]$FinalTestResultPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Version.ps1')
$version=Get-SjcVersion
$build=[IO.Path]::GetFullPath($BuildDirectory)
$verification=[IO.Path]::GetFullPath($VerificationDirectory)
if ($version -cin @('0.13.0','0.14.0','0.15.0','0.16.0','0.16.1')) {
    if (-not $FinalTestResultPath) { throw 'Component publish requires final test result; legacy summaries cannot replace complete evidence.' }
    . (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
    New-LpComponentRelease $root $build $FinalTestResultPath $GuiAcceptancePath | ConvertTo-Json -Depth 8
    return
}
$manifest=Get-Content -LiteralPath (Join-Path $build 'build-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$summary=Get-Content -LiteralPath (Join-Path $verification 'summary.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$gui=Get-Content -LiteralPath $GuiAcceptancePath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.Version -ne $version -or $summary.Status -ne 'Passed' -or $summary.Scope -ne 'Release' -or $summary.Blocked -ne 0 -or $summary.Failed -ne 0) { throw 'A matching current-version release regression is required.' }
if (@($summary.CoverageGaps).Count -gt 0) { throw 'Regression coverage gaps remain.' }
if ($gui.Status -ne 'Passed' -or @($gui.Checks).Count -eq 0 -or @($gui.Checks | Where-Object { -not $_.Passed }).Count -gt 0) { throw 'Actual desktop GUI acceptance evidence is required.' }
$guiSourceHash=(Get-FileHash -LiteralPath (Join-Path $root 'src\Gui.ps1') -Algorithm SHA256).Hash
if ($gui.GuiSourceSHA256 -ne $guiSourceHash) { throw 'GUI acceptance evidence does not match the current interface source.' }
$iconHash=(Get-FileHash -LiteralPath (Join-Path $root 'assets\app.ico') -Algorithm SHA256).Hash
if (-not $gui.PSObject.Properties['IconSHA256'] -or $gui.IconSHA256 -ne $iconHash) { throw 'GUI acceptance evidence does not match the current application icon.' }
foreach($name in @('DesktopWindowObserved','RuleSelectionObserved','CandidatePagingAndKeepRestore','NoProductionDeletion','WhiteBackgroundIconObserved','CompactLayoutObserved','CleaningProfileConfirmationObserved','SingleWindowFlowObserved','ThreePresetImmediateApplyObserved','AdvancedCustomOffByDefaultObserved','DiscoveryAuthorizationCancelObserved','MaintenanceCancelObserved')) {
    $check=@($gui.Checks | Where-Object { $_.Name -eq $name -and $_.Passed -is [bool] -and $_.Passed })
    if ($check.Count -ne 1) { throw "Missing desktop acceptance check: $name" }
}
if (@($gui.EvidenceFiles).Count -eq 0) { throw 'GUI acceptance requires saved evidence.' }
foreach($artifact in @($gui.EvidenceFiles)) {
    if (-not [IO.File]::Exists($artifact)) { throw "GUI evidence artifact missing: $artifact" }
}
$required=@('R01-rule-inventory','R02-browser-discovery','R03-rule-approval-seal','P01-path-guards','P02-preference-guards','P03-preview-session','S01-scan-core','S02-same-root-dedupe','S03-scan-links','C01-clean-core','C02-clean-tamper','C03-clean-error-cap','C04-cancel','C05-pagination-export','L01-logging','W01-worker-boundary','V01-version-contract','G01-gui-selftest','G02-background-preview','W02-worker-selftest','X01-exe-selftest')
$tokens=$null;$parseErrors=$null
$runnerAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'tests\run_all.ps1'),[ref]$tokens,[ref]$parseErrors)
if (@($parseErrors).Count) { throw 'Regression runner declaration cannot be parsed.' }
$declarations=@($runnerAst.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$script:AllCases'},$true))
if ($declarations.Count -ne 1) { throw 'Expected exactly one regression case declaration.' }
$declared=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
foreach($table in @($declarations[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true))) {
    $entries=@($table.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -ceq 'Id' })
    if ($entries.Count -ne 1) { throw 'Each regression declaration needs one literal Id.' }
    $caseId=$entries[0].Item2.SafeGetValue()
    if ($caseId -isnot [string] -or $caseId -cnotmatch '^[A-Z][0-9]{2}-[a-z0-9-]+$' -or -not $declared.Add($caseId)) { throw 'Invalid or duplicate regression case declaration.' }
}
foreach($caseId in $required) { if (-not $declared.Contains($caseId)) { throw "Baseline regression removed: $caseId" } }
$required=@($declared | Sort-Object)
foreach($caseId in $required) {
    $result=@($summary.Results | Where-Object { $_.Id -eq $caseId })
    if ($result.Count -ne 1 -or $result[0].Status -ne 'Passed' -or $result[0].Assertions -le 0 -or $result[0].Failed -ne 0) { throw "Missing or failed required regression: $caseId" }
}
foreach($record in $manifest.Sources) {
    $relative=([string]$record.Path).Replace('/','\')
    $current=Join-Path $root $relative
    $hash=(Get-FileHash -LiteralPath $current -Algorithm SHA256).Hash
    $tested=@($summary.SourceHashes | Where-Object { ([string]$_.Path).Replace('/','\') -eq $relative })
    if ($hash -ne $record.SHA256 -or $tested.Count -ne 1 -or $hash -ne $tested[0].SHA256) { throw "Source changed since build/regression: $relative" }
}
foreach($record in $summary.SourceHashes) {
    $path=[string]$record.Path
    if (-not [IO.Path]::IsPathRooted($path)) { $path=Join-Path $root $path }
    if (-not [IO.File]::Exists($path) -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $record.SHA256) { throw "Verified input changed: $path" }
}
$exeRecords=@($manifest.Files | Where-Object { $_.Name -like '*.exe' })
if ($exeRecords.Count -ne 1) { throw 'Expected exactly one built EXE.' }
$exePath=Join-Path $build $exeRecords[0].Name
if ($null -eq $summary.Exe -or [string]::IsNullOrWhiteSpace([string]$summary.Exe.Path) -or -not [IO.File]::Exists([string]$summary.Exe.Path)) { throw 'Verified EXE evidence is missing.' }
$testedExeHash=(Get-FileHash -LiteralPath $summary.Exe.Path -Algorithm SHA256).Hash
if ($testedExeHash -ne $exeRecords[0].SHA256 -or (Get-FileHash -LiteralPath $exePath -Algorithm SHA256).Hash -ne $testedExeHash) { throw 'EXE differs from independently verified artifact.' }
foreach($record in $manifest.Files) {
    if ((Get-FileHash -LiteralPath (Join-Path $build $record.Name) -Algorithm SHA256).Hash -ne $record.SHA256) { throw "Build artifact changed: $($record.Name)" }
}
$publicDocuments=@('README.md','LICENSE','CHANGELOG.md','THIRD-PARTY-NOTICES.md','docs\SAFETY.md','docs\DEVELOPMENT.md','docs\RULES.md','docs\CACHE-EVIDENCE.md','docs\RULE-MIGRATION.md','docs\ENGINE-PERFORMANCE.md','docs\UI-COMPARISON.md','docs\CANDIDATE-0.12.0.md','docs\VALIDATION-0.12.0.md','docs\VALIDATION-0.11.0.md','docs\RECOVERY-0.10.0.md','docs\VALIDATION-0.10.0.md','docs\decisions-popup-ui.md','docs\LOCAL-PROMOTION.md','docs\RELEASE-0.12.0.zh-CN.md','docs\decisions-engine-expansion.md','assets\third-party\PS2EXE-LICENSE.txt')
foreach($relative in $publicDocuments) {
    if (-not [IO.File]::Exists((Join-Path $root $relative))) { throw "Release documentation missing: $relative" }
}
$release=Join-Path $root ('releases\v'+$version+'-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$null=[IO.Directory]::CreateDirectory($release)
foreach($record in $manifest.Files) { [IO.File]::Copy((Join-Path $build $record.Name),(Join-Path $release $record.Name),$false) }
[IO.File]::Copy((Join-Path $build 'build-manifest.json'),(Join-Path $release 'build-manifest.json'),$false)
# Public artifacts contain no raw logs, machine names, absolute paths or screenshots.
$publicChecks=@($summary.Results|ForEach-Object{[pscustomobject]@{Id=$_.Id;Status=$_.Status;Assertions=$_.Assertions;Failed=$_.Failed}})
$publicSummary=[ordered]@{Version=$version;Status=$summary.Status;Cases=$summary.Cases;Assertions=$summary.Assertions;Failed=$summary.Failed;Results=$publicChecks;Limitations=@('Synthetic owned-sandbox regression; no production cache deletion or real recycle-bin emptying.','No full multi-DPI/multi-monitor certification.','Unsigned application; residual filesystem TOCTOU risk remains.')}
[IO.File]::WriteAllText((Join-Path $release 'test-summary.json'),($publicSummary|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($true))
foreach($relative in $publicDocuments){
    $target=Join-Path $release $relative
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
    [IO.File]::Copy((Join-Path $root $relative),$target,$false)
}
$records=@(Get-ChildItem -LiteralPath $release -File -Recurse | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($release.Length+1); SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash} })
$releaseInfo=[ordered]@{Version=$version; PublishedUtc=[datetime]::UtcNow.ToString('o'); BuildId=$manifest.BuildId; Signature=[string](Get-AuthenticodeSignature -LiteralPath $exePath).Status; Files=$records}
[IO.File]::WriteAllText((Join-Path $release 'release-manifest.json'),($releaseInfo | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
[pscustomobject]@{ReleaseDirectory=$release; Exe=(Join-Path $release $exeRecords[0].Name); Files=$records.Count} | ConvertTo-Json
