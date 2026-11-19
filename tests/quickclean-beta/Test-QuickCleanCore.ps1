#requires -Version 5.1
<#
.SYNOPSIS
Runs isolated quick-clean behavior checks in Windows PowerShell 5.1 against the supplied source snapshot.
.DESCRIPTION
When ExePath is supplied, also runs packaged SelfTest, bound to sibling build/source manifests.
.EXAMPLE
powershell.exe -NoProfile -File .\Test-QuickCleanCore.ps1 -SourceRoot <snapshot> -EvidenceParent <authorized-GUID-directory>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceParent,
    [string]$ExePath,
    [ValidateSet('Permanent','Replacement','ScanCancel','CleanCancel','Crash','History')][string[]]$Cases = @('Permanent','Replacement','ScanCancel','CleanCancel','Crash','History'),
    [ValidateSet('Permanent','Replacement','ScanCancel','CleanCancel','Crash','History')][string]$ChildCase,
    [string]$RunDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Run this test in Windows PowerShell 5.1 (powershell.exe).' }
$script:Utf8 = [Text.UTF8Encoding]::new($true)
$script:SourceModules = @('Version.ps1','Rules.ps1','Core.ps1','Discovery.ps1','Maintenance.ps1','Worker.ps1')
$script:OwnerSid = [Security.Principal.WindowsIdentity]::GetCurrent().User

function Assert-Beta([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-BetaEqual($Expected,$Actual,[string]$Message) {
    Assert-Beta ($Expected -ceq $Actual) ('{0}; expected={1}; actual={2}' -f $Message,$Expected,$Actual)
}
function Get-BetaLocalPath([string]$Path) {
    Assert-Beta ($Path -match '^[A-Za-z]:[\\/]' -and $Path.Substring(2) -notmatch '[:"\x00-\x1f]') "Not a local absolute path: $Path"
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    Assert-Beta ($full.Length -gt 3) "Drive root refused: $Path"
    return $full
}
function Assert-BetaPlainPath([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while ($null -ne $item) {
        Assert-Beta (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) "Reparse point refused: $($item.FullName)"
        if ($item -is [IO.FileInfo]) { $item = $item.Directory } else { $item = $item.Parent }
    }
}
function Assert-BetaChildPath([string]$Path,[string]$Parent) {
    $full = Get-BetaLocalPath $Path
    Assert-Beta ([IO.Path]::GetDirectoryName($full).Equals($Parent,[StringComparison]::OrdinalIgnoreCase)) "Not a direct child of $Parent`: $full"
    return $full
}
function New-BetaDirectory([string]$Parent,[string]$Name) {
    Assert-BetaPlainPath $Parent
    $path = Assert-BetaChildPath (Join-Path $Parent $Name) $Parent
    Assert-Beta (-not (Test-Path -LiteralPath $path)) "Expected a fresh directory: $path"
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($script:OwnerSid)
    $security.SetAccessRuleProtection($true,$false)
    foreach ($sid in @($script:OwnerSid,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $security.AddAccessRule($rule)
    }
    [void][IO.Directory]::CreateDirectory($path,$security)
    Assert-BetaPlainPath $path
    Assert-BetaEqual $script:OwnerSid.Value ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value) "Test directory owner: $path"
    return $path
}
function Write-BetaNewText([string]$Path,[string]$Text) {
    Assert-BetaPlainPath ([IO.Path]::GetDirectoryName($Path))
    $stream = [IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $writer = [IO.StreamWriter]::new($stream,$script:Utf8,4096,$true)
        try { $writer.Write($Text) } finally { $writer.Dispose() }
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}
function Write-BetaJson([string]$Path,$Value) {
    Write-BetaNewText $Path ($Value | ConvertTo-Json -Depth 14)
}
function Read-BetaJson([string]$Path) {
    Assert-BetaPlainPath $Path
    return ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json)
}
function Get-BetaSourceFiles([string]$Root) {
    $paths = @(Join-Path $Root 'version.json')
    foreach ($module in $script:SourceModules) { $paths += Join-Path $Root ('src\' + $module) }
    if ($Cases -contains 'History') { $paths += Join-Path $Root 'src\Gui.ps1' }
    foreach ($path in $paths) {
        Assert-BetaPlainPath $path
        Get-FileHash -Algorithm SHA256 -LiteralPath $path | Select-Object Path,Hash
    }
}
function Get-BetaBuildFacts([string]$Binary,$SourceFiles) {
    $Binary = Get-BetaLocalPath $Binary
    Assert-BetaPlainPath $Binary
    $buildRoot = [IO.Path]::GetDirectoryName($Binary)
    $manifestPath = Join-Path $buildRoot 'build-manifest.json'
    $manifest = Read-BetaJson $manifestPath
    $sourceManifest = Assert-BetaChildPath (Join-Path $buildRoot $manifest.SourceTree.ManifestPath) $buildRoot
    Assert-BetaPlainPath $sourceManifest
    Assert-BetaEqual $manifest.SourceTree.SHA256 (Get-FileHash -LiteralPath $sourceManifest -Algorithm SHA256).Hash 'Source manifest hash'
    $source = Read-BetaJson $sourceManifest
    Assert-Beta ($manifest.BuildId -and $source.SourceSetSha256 -match '^[a-f0-9]{64}$') 'Build binding is incomplete'
    Assert-BetaEqual $manifest.SourceTree.SourceSetSha256 $source.SourceSetSha256 'Build/source set binding'
    foreach ($file in $SourceFiles) {
        $relative = $file.Path.Substring($SourceRoot.Length + 1).Replace('\','/')
        $entries = @($source.Sources | Where-Object Path -CEQ $relative)
        Assert-BetaEqual 1 $entries.Count "Missing or duplicate tested source: $relative"
        Assert-BetaEqual $entries[0].SHA256 $file.Hash "Build does not match tested source: $relative"
    }
    $artifacts = foreach ($path in @($Binary,($Binary+'.config'))) {
        Assert-BetaPlainPath $path
        $entry = @($manifest.Files | Where-Object Name -CEQ ([IO.Path]::GetFileName($path)))
        Assert-BetaEqual 1 $entry.Count "Build manifest has no unique entry for $path"
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        Assert-BetaEqual $entry[0].SHA256 $hash "Build artifact hash: $path"
        [pscustomobject]@{Path=$path;SHA256=$hash}
    }
    $version = Read-BetaJson (Join-Path $SourceRoot 'version.json')
    Assert-BetaEqual $version.version $manifest.Version 'Build product version'
    Assert-BetaEqual $version.fileVersion ([Diagnostics.FileVersionInfo]::GetVersionInfo($Binary).FileVersion) 'EXE file version'
    return [pscustomobject]@{BuildId=$manifest.BuildId;SourceSetSha256=$source.SourceSetSha256;Version=$version.version;Artifacts=@($artifacts);ManifestSha256=(Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash}
}
function Invoke-BetaExe([string]$Binary,[string]$Run,$Build) {
    $directory = New-BetaDirectory $Run 'ExeSelfTest'
    $temp = New-BetaDirectory $directory 'tmp'
    $parent = Join-Path $directory 'sandboxes'
    Assert-Beta (-not (Test-Path -LiteralPath $parent)) 'EXE SelfTest requires a new sandbox parent'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Binary
    $info.Arguments = '-end -WorkerMode SelfTest -SelfTestParentDirectory "' + $parent + '"'
    $info.WorkingDirectory = $directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.EnvironmentVariables['TEMP'] = $temp
    $info.EnvironmentVariables['TMP'] = $temp
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        Assert-Beta $started 'EXE SelfTest did not launch'
        $null = $process.Handle
        Assert-Beta ($process.WaitForExit(60000)) 'EXE SelfTest timed out'
        Assert-BetaEqual 0 $process.ExitCode "EXE SelfTest failed; logs under $parent"
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }

    Assert-BetaPlainPath $parent
    $reportPaths = @(
        foreach ($sandboxRoot in [IO.Directory]::GetDirectories($parent,'*',[IO.SearchOption]::TopDirectoryOnly)) {
            Assert-BetaPlainPath $sandboxRoot
            $logs = Join-Path $sandboxRoot 'state\Logs'
            if ([IO.Directory]::Exists($logs)) {
                Assert-BetaPlainPath $logs
                [IO.Directory]::GetFiles($logs,'selftest-*.json',[IO.SearchOption]::TopDirectoryOnly)
            }
        }
    )
    Assert-BetaEqual 1 $reportPaths.Count 'EXE SelfTest report must be unique'
    $report = Read-BetaJson $reportPaths[0]
    $root = Assert-BetaChildPath $report.SandboxRoot $parent
    Assert-BetaEqual (Join-Path $root 'state\Logs') ([IO.Path]::GetDirectoryName($reportPaths[0])) 'EXE log does not belong to its sandbox'
    Assert-BetaEqual $Build.Version $report.Version 'EXE SelfTest product version'
    Assert-BetaEqual 'Success' $report.Status ('EXE SelfTest: ' + $report.Error)
    Assert-BetaEqual 'Success' $report.Gui.Status 'EXE WPF self-test'
    Assert-BetaEqual 2 $report.Scan.CandidateCount 'EXE sealed candidate count'
    Assert-BetaEqual 1 $report.Clean.Deleted 'EXE permanent delete count'
    Assert-BetaEqual 1 $report.Clean.Skipped 'EXE excluded count'
    Assert-Beta (-not [IO.File]::Exists((Join-Path $root 'files\owned-old.tmp'))) 'EXE left its approved old file on disk'
    Assert-BetaFile (Join-Path $root 'files\owned-new.tmp') 'SafeJunkCleaner GUID synthetic file only'
    Assert-BetaFile (Join-Path $root 'files\owned-kept.tmp') 'SafeJunkCleaner GUID synthetic file only'
    Write-BetaJson (Join-Path $directory 'result.json') ([ordered]@{Case='ExeSelfTest';Outcome='Pass';Build=$Build;ReportPath=$reportPaths[0];Report=$report})
}
function Assert-BetaLog($Result,$Sandbox,[string]$Status,[string]$Task,[string]$Operation) {
    $logs = Join-Path $Sandbox.Context.StateRoot 'Logs'
    $path = Assert-BetaChildPath $Result.LogPath $logs
    Assert-Beta ([IO.Path]::GetFileName($path) -match ('^' + $Operation + '-[a-f0-9-]{36}\.json$')) "Unexpected operation log: $path"
    $log = Read-BetaJson $path
    Assert-BetaEqual $Status $log.Status 'Persisted log status'
    Assert-BetaEqual ([IO.Path]::GetFileName($Task)) $log.TaskId 'Persisted log task identity'
    Assert-BetaEqual $Result.Version $log.Version 'Persisted log version'
    if ($Operation -eq 'clean') {
        foreach ($key in @('Reviewed','Deleted','ProcessedBytes','Skipped','ErrorCount')) {
            Assert-BetaEqual $Result.$key $log.$key "Persisted clean counter: $key"
        }
    }
}
function New-BetaOldFile([string]$Directory,[string]$Name,[string]$Text) {
    $path = Assert-BetaChildPath (Join-Path $Directory $Name) $Directory
    Write-BetaNewText $path $Text
    [IO.File]::SetLastWriteTimeUtc($path,[datetime]::UtcNow.AddDays(-7))
    return $path
}
function Assert-BetaFile([string]$Path,[string]$Text) {
    Assert-Beta ([IO.File]::Exists($Path)) "Fixture missing: $Path"
    Assert-BetaPlainPath $Path
    Assert-BetaEqual $Text ([IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)) "Fixture contents: $Path"
}
function Save-BetaFixtures($Scan,[string]$Files,[string]$EvidenceDirectory) {
    if ($Scan.Status -ne 'Success') { throw 'Expected a successful scan before permanent deletion.' }
    $candidates = @(Get-SjcCandidatePage -PlanPath $Scan.PlanPath -Limit 1000)
    Assert-BetaEqual $Scan.CandidateCount $candidates.Count 'Fixture list must cover the entire plan'
    foreach ($item in $candidates) {
        $path = Assert-BetaChildPath $item.Path $Files
        Assert-BetaPlainPath $path
        Assert-BetaEqual $script:OwnerSid.Value ((Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value) "Candidate owner: $path"
    }
    Write-BetaJson (Join-Path $EvidenceDirectory 'planned-fixtures.json') ([ordered]@{RecycleMode=$false;Files=@($candidates.Path)})
    return $candidates
}
function Invoke-BetaScan($Sandbox,[string]$Task,[int]$ExpectedCount,[string]$CancelPath) {
    $result = Invoke-SjcScan -Context $Sandbox.Context -TaskDirectory $Task -RuleIds @('SandboxOld') -CancelPath $CancelPath -CustomEnabled $true
    $status = if ($CancelPath) { 'Cancelled' } else { 'Success' }
    Assert-BetaEqual $status $result.Status ('Scan failed: ' + $result.Error)
    Assert-BetaEqual $ExpectedCount $result.CandidateCount 'Scan candidate count'
    Assert-BetaEqual ([IO.Path]::GetFileName($Task)) $result.TaskId 'Scan result task identity'
    Assert-BetaLog $result $Sandbox $status $Task 'scan'
    return $result
}
function Assert-BetaReplay($Sandbox,[string]$Task) {
    $again = Invoke-SjcClean -Context $Sandbox.Context -TaskDirectory $Task -RecycleMode $false -CustomEnabled $true
    Assert-BetaEqual 'Failed' $again.Status 'Consumed task accepted replay'
    Assert-BetaEqual 0 $again.Reviewed 'Replay reviewed candidates'
    Assert-BetaEqual 0 $again.Deleted 'Replay deleted candidates'
    Assert-BetaEqual 0 $again.ProcessedBytes 'Replay reported processed bytes'
    Assert-BetaLog $again $Sandbox 'Failed' $Task 'clean'
    return $again
}
function Invoke-BetaWorkerClean($Sandbox,[string]$Task,[string]$CancelPath,[string[]]$ExcludedIds=@()) {
    $payload = Join-Path $Task 'beta.clean.payload.json'
    $output = Join-Path $Task 'beta.clean.output.json'
    Write-BetaJson $payload ([ordered]@{TaskDirectory=$Task;CancelPath=$CancelPath;ProgressPath='';ExcludedIds=$ExcludedIds;RecycleMode=$false;CleaningProfile='Medium';CustomEnabled=$true})
    $result = Invoke-SjcWorker -Mode Clean -TestContext $Sandbox.Context -PayloadPath $payload -OutputPath $output
    Assert-BetaEqual $result.Status (Read-BetaJson $output).Status 'Worker output status and return value disagree'
    return $result
}

$EvidenceParent = Get-BetaLocalPath $EvidenceParent
Assert-BetaPlainPath $EvidenceParent
$guid = [guid]::Empty
Assert-Beta ([guid]::TryParseExact([IO.Path]::GetFileName($EvidenceParent),'D',[ref]$guid)) 'EvidenceParent must be the existing, authorized GUID directory.'
$SourceRoot = Get-BetaLocalPath $SourceRoot

if ($ChildCase) {
    $RunDirectory = Assert-BetaChildPath $RunDirectory $EvidenceParent
    $caseDirectory = Assert-BetaChildPath (Join-Path $RunDirectory $ChildCase) $RunDirectory
    Assert-BetaPlainPath $caseDirectory
    $owner = Read-BetaJson (Join-Path $caseDirectory 'owner.json')
    Assert-Beta ($env:SJC_QUICK_BETA_NONCE -and $owner.Nonce -ceq $env:SJC_QUICK_BETA_NONCE) 'Missing launcher ownership token.'
    Assert-BetaEqual $ChildCase $owner.Case 'Launcher case'
    Assert-BetaEqual $SourceRoot $owner.SourceRoot 'Launcher source'
    $fixtureParent = Join-Path $caseDirectory 'sandboxes'
    Assert-Beta (-not (Test-Path -LiteralPath $fixtureParent)) 'Sandbox parent already exists.'
    try {
        foreach ($module in $script:SourceModules) { . (Join-Path $SourceRoot ('src\' + $module)) }
        $sandbox = New-SjcTestSandbox -ParentDirectory $fixtureParent
        $root = Assert-BetaChildPath $sandbox.Root $fixtureParent
        Assert-BetaPlainPath $root
        Assert-Beta ([guid]::TryParseExact([IO.Path]::GetFileName($root),'D',[ref]$guid)) 'Product did not create a GUID sandbox.'
        Assert-BetaEqual (Join-Path $root 'state') $sandbox.Context.StateRoot 'Sandbox state boundary'
        $files = Join-Path $root 'files'
        $task = New-SjcTaskDirectory -Context $sandbox.Context
        $cancel = Join-Path $task 'beta.cancel'
        $outside = New-BetaOldFile $root 'outside-rules.tmp' 'outside-rule sentinel'
        $nonCandidate = New-BetaOldFile $files 'not-selected.txt' 'non-candidate sentinel'
        $scan = $null; $clean = $null; $again = $null; $replacementProof = $null

        switch ($ChildCase) {
            'Permanent' {
                $target = New-BetaOldFile $files 'delete.tmp' 'permanent deletion fixture'
                $kept = New-BetaOldFile $files 'keep.tmp' 'excluded fixture'
                $expectedBytes = [IO.FileInfo]::new($target).Length
                $scan = Invoke-BetaScan $sandbox $task 2 ''
                Assert-BetaFile $target 'permanent deletion fixture'
                $keepIds = @(Save-BetaFixtures $scan $files $caseDirectory | Where-Object Path -CEQ $kept | ForEach-Object Id)
                Assert-BetaEqual 1 $keepIds.Count 'Explicit keep candidate count'
                $clean = Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -RecycleMode $false -ExcludedIds $keepIds -CustomEnabled $true
                Assert-BetaEqual 'Success' $clean.Status ('Permanent clean failed: ' + $clean.Error)
                Assert-BetaEqual 1 $clean.Deleted 'Permanent clean deleted count'
                Assert-BetaEqual 1 $clean.Skipped 'Permanent clean exclusion count'
                Assert-BetaEqual $expectedBytes $clean.ProcessedBytes 'Permanent clean logical bytes'
                Assert-Beta (-not [IO.File]::Exists($target)) "Permanent clean left the approved target: $target"
                Assert-BetaFile $kept 'excluded fixture'
                Assert-BetaLog $clean $sandbox 'Success' $task 'clean'
                # The excluded item is still the original eligible file and is not
                # excluded on replay. Zero deletes now is meaningful, not an empty plan.
                $again = Assert-BetaReplay $sandbox $task
                Assert-BetaFile $kept 'excluded fixture'
                Assert-Beta ($again.LogPath -cne $clean.LogPath) 'Replayed call overwrote the original clean log.'
                Assert-BetaLog $clean $sandbox 'Success' $task 'clean'
            }
            'Replacement' {
                $target = New-BetaOldFile $files 'replace.tmp' 'old-data'
                $good = New-BetaOldFile $files 'control.tmp' 'control candidate'
                $expectedBytes = [IO.FileInfo]::new($good).Length
                $scan = Invoke-BetaScan $sandbox $task 2 ''
                $candidate = @(Save-BetaFixtures $scan $files $caseDirectory | Where-Object Path -CEQ $target)
                Assert-BetaEqual 1 $candidate.Count 'Original replacement path was not sealed'
                $before = [IO.FileInfo]::new($target)
                $oldLength = $before.Length; $oldWrite = $before.LastWriteTimeUtc
                $original = Assert-BetaChildPath (Join-Path $files 'original-retained.bin') $files
                Assert-Beta (-not (Test-Path -LiteralPath $original)) 'Original retention path unexpectedly exists.'
                Assert-BetaFile $target 'old-data'
                [IO.File]::Move($target,$original)
                Write-BetaNewText $target 'new-data'
                [IO.File]::SetLastWriteTimeUtc($target,$oldWrite)
                $after = [IO.FileInfo]::new($target)
                Assert-BetaEqual $candidate[0].Path $after.FullName 'Same pathname collision'
                Assert-BetaEqual $oldLength $after.Length 'Same length collision'
                Assert-BetaEqual $oldWrite.Ticks $after.LastWriteTimeUtc.Ticks 'Exact same UTC mtime collision'
                Assert-BetaFile $original 'old-data'
                $replacementProof = [ordered]@{ Path=$target; OriginalRetained=$original; Length=$oldLength; LastWriteUtc=$oldWrite.ToString('o') }
                $clean = Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -RecycleMode $false -CustomEnabled $true
                Assert-BetaEqual 'Partial' $clean.Status ('Replacement clean status: ' + $clean.Error)
                Assert-BetaEqual 1 $clean.Deleted 'Only the unchanged control should be deleted'
                Assert-BetaEqual 1 $clean.Skipped 'Exactly the replacement should be skipped'
                Assert-BetaEqual 1 $clean.ErrorCount 'Exactly one replacement rejection should be recorded'
                Assert-BetaEqual $expectedBytes $clean.ProcessedBytes 'Replacement bytes must not be counted'
                Assert-Beta (-not [IO.File]::Exists($good)) 'Unchanged control candidate was not deleted.'
                Assert-BetaFile $target 'new-data'
                Assert-BetaFile $original 'old-data'
                Assert-BetaLog $clean $sandbox 'Partial' $task 'clean'
            }
            'ScanCancel' {
                $target = New-BetaOldFile $files 'cancel-scan.tmp' 'scan cancellation fixture'
                Write-BetaNewText $cancel 'cancel'
                $scan = Invoke-BetaScan $sandbox $task 0 $cancel
                $clean = Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -RecycleMode $false -CustomEnabled $true
                Assert-BetaEqual 'Failed' $clean.Status 'A cancelled scan must not authorize cleaning'
                Assert-BetaEqual 0 $clean.Deleted 'A cancelled scan authorized a deletion'
                Assert-BetaFile $target 'scan cancellation fixture'
                Assert-BetaLog $clean $sandbox 'Failed' $task 'clean'
            }
            'History' {
                $target = New-BetaOldFile $files 'history-approved.tmp' 'history permanent fixture'
                $kept = New-BetaOldFile $files 'history-kept.tmp' 'history excluded fixture'
                $scan = Invoke-BetaScan $sandbox $task 2 ''
                $keepIds = @(Save-BetaFixtures $scan $files $caseDirectory | Where-Object Path -CEQ $kept | ForEach-Object Id)
                Assert-BetaEqual 1 $keepIds.Count 'History keep candidate count'
                $clean = Invoke-BetaWorkerClean $sandbox $task '' $keepIds
                Assert-BetaEqual 'Success' $clean.Status 'History success fixture clean'
                Assert-BetaEqual 1 $clean.Deleted 'History success fixture deletion count'
                Assert-Beta (-not [IO.File]::Exists($target)) 'History success fixture still exists'
                Assert-BetaLog $clean $sandbox 'Success' $task 'clean'
                Assert-BetaFile $kept 'history excluded fixture'

                $cancelTask = New-SjcTaskDirectory $sandbox.Context
                $cancelTarget = New-BetaOldFile $files 'history-cancelled.tmp' 'history cancellation fixture'
                $cancelScan = Invoke-BetaScan $sandbox $cancelTask 2 ''
                $cancelEvidence = New-BetaDirectory $caseDirectory 'cancelled-plan'
                $null = Save-BetaFixtures $cancelScan $files $cancelEvidence
                $cancelChannel = Join-Path $cancelTask 'beta.cancel'
                Write-BetaNewText $cancelChannel 'cancel'
                $cancelClean = Invoke-BetaWorkerClean $sandbox $cancelTask $cancelChannel
                Assert-BetaEqual 'Cancelled' $cancelClean.Status 'History cancellation fixture clean'
                Assert-BetaEqual 0 $cancelClean.Deleted 'Pre-cancelled history fixture deletion count'
                Assert-BetaFile $cancelTarget 'history cancellation fixture'
                Assert-BetaLog $cancelClean $sandbox 'Cancelled' $cancelTask 'clean'

                $history = Get-SjcQuickHistory $sandbox.Context
                Assert-Beta ($history -is [System.Collections.IList]) 'History API must return a list'
                Assert-BetaEqual 2 $history.Count 'History must contain exactly one row per worker attempt'
                foreach ($entry in @(@{Task=$cancelTask;Result=$cancelClean;Status='已取消';Deleted=0},@{Task=$task;Result=$clean;Status='完成';Deleted=1})) {
                    $rows = @($history.ToArray() | Where-Object TaskDirectory -CEQ $entry.Task)
                    Assert-BetaEqual 1 $rows.Count 'History lost or duplicated a task'
                    $row = $rows[0]
                    Assert-BetaEqual '清理' $row.Action 'History action'
                    Assert-BetaEqual $entry.Status $row.Status 'History status'
                    Assert-BetaEqual $entry.Result.LogPath $row.LogPath 'History references the wrong actual operation log'
                    Assert-Beta ($row.Summary -match ('处理\s+{0}\s+个' -f $entry.Deleted)) 'History summary did not report the real processed count'
                    Assert-Beta ($row.Summary -match '逻辑大小' -and $row.Summary -notmatch '实际释放') 'History misstated logical size'
                }
                $reopened = Get-SjcQuickHistory $sandbox.Context
                Assert-BetaEqual ($history | ConvertTo-Json -Depth 9 -Compress) ($reopened | ConvertTo-Json -Depth 9 -Compress) 'Re-reading history changed recorded outcomes'
                $again = Assert-BetaReplay $sandbox $task
                Assert-BetaFile $kept 'history excluded fixture'
                Assert-BetaFile $cancelTarget 'history cancellation fixture'

                # New WPF state must reopen genuine history from disk, not inject rows.
                . (Join-Path $SourceRoot 'src\Gui.ps1')
                $state = New-SjcGuiState $sandbox.Context -TestMode
                $app = New-SjcGuiApp $state
                try {
                    $app.Ui.Window.Show()
                    $app.Ui.LogsToggle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                    $app.Ui.Window.UpdateLayout()
                    Assert-BetaEqual 'Visible' ([string]$app.Ui.LogsPanel.Visibility) 'Task records did not open'
                    Assert-BetaEqual 2 $app.Ui.HistoryList.Items.Count 'Two actual outcomes should appear in history'
                    $latest = $app.Ui.HistoryList.Items[0]
                    $earlier = $app.Ui.HistoryList.Items[1]
                    Assert-BetaEqual '已取消' $latest.Status 'Latest WPF record must identify cancellation'
                    Assert-BetaEqual '完成' $earlier.Status 'Earlier WPF record must identify success'
                    Assert-BetaEqual $cancelClean.LogPath $latest.LogPath 'Cancellation history references the wrong log'
                    Assert-BetaEqual $clean.LogPath $earlier.LogPath 'Success history references the wrong log'
                    Assert-Beta ($earlier.Summary -match '处理\s+1\s+个') 'History summary did not report the real processed count'
                    Assert-Beta ($earlier.Summary -match '逻辑大小' -and $earlier.Summary -notmatch '实际释放') 'History misstated logical size'
                    $app.Ui.HistoryList.SelectedIndex = 1
                    Update-SjcGuiView $app
                    Assert-BetaEqual $clean.LogPath $app.Ui.HistoryList.SelectedItem.LogPath 'Selecting completed history did not keep the intended row'
                    Save-SjcGuiRender $app.Ui.Window (Join-Path $caseDirectory 'history-900x680.png')
                    Write-BetaJson (Join-Path $caseDirectory 'history.json') @($latest,$earlier)
                } finally {
                    $state.Busy = $false
                    $app.Ui.Window.Close()
                }
            }
            { $_ -in 'CleanCancel','Crash' } {
                $count = 256
                for ($index = 0; $index -lt $count; $index++) {
                    [void](New-BetaOldFile $files ('batch-{0:D4}.tmp' -f $index) ('candidate ' + $index))
                }
                $scan = Invoke-BetaScan $sandbox $task $count ''
                $null = Save-BetaFixtures $scan $files $caseDirectory
                # Publish the identity and paths atomically before starting real clean.
                $ready = Join-Path $caseDirectory 'ready.json'
                $part = Join-Path $caseDirectory 'ready.part'
                Write-BetaJson $part ([ordered]@{Pid=$PID;Root=$root;Task=$task;Scan=$scan;Count=$count})
                [IO.File]::Move($part,$ready)
                $start = Join-Path $caseDirectory 'start.signal'
                $timer = [Diagnostics.Stopwatch]::StartNew()
                while (-not [IO.File]::Exists($start)) {
                    if ($timer.Elapsed.TotalSeconds -gt 30) { throw 'Owned supervisor did not release startup barrier.' }
                    Start-Sleep -Milliseconds 15
                }
                if ($ChildCase -eq 'Crash') {
                    $clean = Invoke-BetaWorkerClean $sandbox $task $cancel
                    Write-BetaJson (Join-Path $caseDirectory 'unexpected-return.json') $clean
                    throw 'Cleaner returned before interruption; no crash test passed.'
                }
                $clean = Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -RecycleMode $false -CancelPath $cancel -CustomEnabled $true
                Assert-BetaEqual 'Cancelled' $clean.Status ('Clean did not stop on cancellation: ' + $clean.Error)
                Assert-Beta ([int64]$clean.Deleted -lt $count) 'Cancellation allowed the entire plan to finish.'
                $survivors = @([IO.Directory]::GetFiles($files,'batch-*.tmp',[IO.SearchOption]::TopDirectoryOnly))
                Assert-BetaEqual ($count - $survivors.Count) $clean.Deleted 'Cancelled result must account for real file removals'
                Assert-BetaLog $clean $sandbox 'Cancelled' $task 'clean'
                $again = Assert-BetaReplay $sandbox $task
                $afterReplay = @([IO.Directory]::GetFiles($files,'batch-*.tmp',[IO.SearchOption]::TopDirectoryOnly))
                Assert-BetaEqual 0 (@(Compare-Object ($survivors | Sort-Object) ($afterReplay | Sort-Object)).Count) 'Replay changed survivor paths'
                Assert-BetaLog $clean $sandbox 'Cancelled' $task 'clean'
            }
        }
        Assert-BetaFile $outside 'outside-rule sentinel'
        Assert-BetaFile $nonCandidate 'non-candidate sentinel'
        Write-BetaJson (Join-Path $caseDirectory 'result.json') ([ordered]@{Case=$ChildCase;Outcome='Pass';Root=$root;Task=$task;Scan=$scan;Clean=$clean;Replay=$again;ReplacementProof=$replacementProof})
        exit 0
    } catch {
        Write-BetaJson (Join-Path $caseDirectory 'failure.json') ([ordered]@{Case=$ChildCase;Outcome='Fail';Message=$_.Exception.Message;Stack=$_.ScriptStackTrace})
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 1
    }
}

function Invoke-BetaChild([string]$Name,[string]$Run,[string]$Nonce) {
    $directory = New-BetaDirectory $Run $Name
    Write-BetaJson (Join-Path $directory 'owner.json') ([ordered]@{Nonce=$Nonce;Case=$Name;SourceRoot=$SourceRoot})
    $temp = New-BetaDirectory $directory 'tmp'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "{0}" -SourceRoot "{1}" -EvidenceParent "{2}" -RunDirectory "{3}" -ChildCase {4}' -f $PSCommandPath,$SourceRoot,$EvidenceParent,$Run,$Name
    $info.WorkingDirectory = $directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['SJC_QUICK_BETA_NONCE'] = $Nonce
    $info.EnvironmentVariables['TEMP'] = $temp
    $info.EnvironmentVariables['TMP'] = $temp
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false; $stdout = $null; $stderr = $null
    try {
        $started = $process.Start()
        Assert-Beta $started 'Failed to launch test child.'
        # Retain the OS handle; never find or kill a process by executable name or PID.
        $null = $process.Handle
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($Name -in 'Crash','CleanCancel') {
            $readyPath = Join-Path $directory 'ready.json'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (-not [IO.File]::Exists($readyPath)) {
                if ($process.WaitForExit(5)) { throw "Child exited before readiness ($($process.ExitCode))." }
                if ($clock.Elapsed.TotalSeconds -gt 60) { throw 'Child never reported its real scan was ready.' }
            }
            $ready = Read-BetaJson $readyPath
            Assert-BetaEqual $process.Id $ready.Pid 'Readiness must come from the owned child'
            $root = Assert-BetaChildPath $ready.Root (Join-Path $directory 'sandboxes')
            Assert-BetaPlainPath $root
            $task = Assert-BetaChildPath $ready.Task (Join-Path $root 'state\Tasks')
            Assert-BetaPlainPath $task
            $claim = Join-Path $task 'clean.claimed'
            Assert-Beta (-not [IO.File]::Exists($claim)) 'Plan was already claimed before launch barrier.'
            Write-BetaNewText (Join-Path $directory 'start.signal') 'start'
            $clock.Restart()
            while (-not [IO.File]::Exists($claim)) {
                if ($process.WaitForExit(5)) { throw "Child exited before real claim ($($process.ExitCode))." }
                if ($clock.Elapsed.TotalSeconds -gt 30) { throw 'No clean.claimed appeared after starting real clean.' }
            }
            $observedUtc = [datetime]::UtcNow.ToString('o')
            Assert-Beta (-not $process.HasExited) 'Claim appeared after child exit, not during work.'
            if ($Name -eq 'CleanCancel') {
                Write-BetaNewText (Join-Path $task 'beta.cancel') 'cancel'
                Write-BetaJson (Join-Path $directory 'signal.json') ([ordered]@{Pid=$ready.Pid;Claim=$claim;ObservedUtc=$observedUtc;Signal='CancelChannel'})
            } else {
                $process.Kill()
                Assert-Beta ($process.WaitForExit(5000)) 'Owned child did not exit after Kill.'
                Assert-Beta ($process.ExitCode -ne 0) 'Killed child reported exit zero.'
                Assert-Beta (-not [IO.File]::Exists((Join-Path $directory 'unexpected-return.json'))) 'Cleaner completed normally before termination.'
                Assert-BetaPlainPath $claim
                Assert-Beta (-not [IO.File]::Exists((Join-Path $task 'beta.clean.output.json'))) 'Killed worker published a terminal result.'
                # Public test contexts are process-local. Read the real, owned
                # authenticated recovery evidence without impersonating its context.
                . (Join-Path $SourceRoot 'src\Core.ps1')
                $records = @([IO.Directory]::GetFiles($task,'.history-*',[IO.SearchOption]::TopDirectoryOnly))
                Assert-BetaEqual 1 $records.Count 'Interrupted worker did not leave exactly one task history record'
                Assert-BetaPlainPath $records[0]
                $history = Unprotect-SjcText ([IO.File]::ReadAllText($records[0],[Text.Encoding]::UTF8)) | ConvertFrom-Json
                Assert-BetaEqual ([IO.Path]::GetFileName($task)) $history.TaskId 'Interrupted history task identity'
                Assert-BetaEqual 'Clean' $history.Action 'Interrupted history operation'
                Assert-BetaEqual 'Unknown' $history.Status 'Interrupted history asserted a definitive outcome'
                Assert-Beta ($history.Summary -match '结果未知' -and $history.Summary -match '可能') 'Interrupted history failed to disclose potential partial processing.'
                $survivors = @([IO.Directory]::GetFiles((Join-Path $root 'files'),'batch-*.tmp',[IO.SearchOption]::TopDirectoryOnly) | Sort-Object)
                Assert-Beta ($survivors.Count -gt 0) 'No fixtures survived: interruption missed the execution window.'
                Assert-BetaFile (Join-Path $root 'outside-rules.tmp') 'outside-rule sentinel'
                Assert-BetaFile (Join-Path $root 'files\not-selected.txt') 'non-candidate sentinel'
                foreach ($path in $survivors) {
                    $index = [int]([IO.Path]::GetFileNameWithoutExtension($path).Substring(6))
                    Assert-BetaFile $path ('candidate ' + $index)
                }
                $result = [ordered]@{Case=$Name;Outcome='Pass';Root=$root;Task=$task;Claim=$claim;ClaimObservedUtc=$observedUtc;Pid=$ready.Pid;ExitCode=$process.ExitCode;Planned=$ready.Count;Survivors=$survivors;Scan=$ready.Scan;History=$history}
                Write-BetaJson (Join-Path $directory 'result.json') $result
                return $result
            }
        }
        Assert-Beta ($process.WaitForExit(60000)) 'Owned child timed out.'
        Assert-BetaEqual 0 $process.ExitCode "Child returned failure; see $directory"
        $result = Read-BetaJson (Join-Path $directory 'result.json')
        Assert-BetaEqual 'Pass' $result.Outcome 'Child did not produce a passing result'
        return $result
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        if ($stdout -and $stdout.Wait(5000)) { Write-BetaNewText (Join-Path $directory 'stdout.txt') $stdout.Result }
        if ($stderr -and $stderr.Wait(5000)) { Write-BetaNewText (Join-Path $directory 'stderr.txt') $stderr.Result }
        $process.Dispose()
    }
}

Assert-Beta (-not $RunDirectory) 'RunDirectory is internal to the harness.'
$nonce = [guid]::NewGuid().ToString('N')
$run = New-BetaDirectory $EvidenceParent ('qc-' + $nonce)
Write-Host "Evidence: $run"
$before = @(Get-BetaSourceFiles $SourceRoot)
$build = $null
if ($ExePath) {
    $ExePath = Get-BetaLocalPath $ExePath
    $build = Get-BetaBuildFacts $ExePath $before
}
$testHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
Write-BetaJson (Join-Path $run 'inputs.json') ([ordered]@{SourceRoot=$SourceRoot;Files=$before;Build=$build;TestSha256=$testHash;Cases=$Cases;StartedUtc=[datetime]::UtcNow.ToString('o')})
$summary = @(
    foreach ($name in ($Cases | Select-Object -Unique)) {
        try {
            $result = Invoke-BetaChild $name $run $nonce
            Write-Host "PASS $name"
            [pscustomobject]@{Case=$name;Outcome=$result.Outcome;Detail=''}
        } catch {
            Write-Host "FAIL $name`: $($_.Exception.Message)"
            [pscustomobject]@{Case=$name;Outcome='Fail';Detail=$_.Exception.Message}
        }
    }
    if ($build) {
        try {
            Invoke-BetaExe $ExePath $run $build
            Write-Host 'PASS ExeSelfTest'
            [pscustomobject]@{Case='ExeSelfTest';Outcome='Pass';Detail=''}
        } catch {
            Write-Host "FAIL ExeSelfTest: $($_.Exception.Message)"
            [pscustomobject]@{Case='ExeSelfTest';Outcome='Fail';Detail=$_.Exception.Message}
        }
    }
)
$after = @(Get-BetaSourceFiles $SourceRoot)
$stable = ((($before | ConvertTo-Json -Compress) -ceq ($after | ConvertTo-Json -Compress)) -and $testHash -ceq (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash)
$artifactStable = $true
if ($build) {
    try { $artifactStable = (($build | ConvertTo-Json -Compress) -ceq ((Get-BetaBuildFacts $ExePath $after) | ConvertTo-Json -Compress)) }
    catch { $artifactStable = $false }
}
$failed = @($summary | Where-Object Outcome -EQ 'Fail').Count
Write-BetaJson (Join-Path $run 'summary.json') ([ordered]@{SourceAndTestStable=$stable;ArtifactStable=$artifactStable;Build=$build;Passed=($summary.Count - $failed);Failed=$failed;Cases=$summary;FinishedUtc=[datetime]::UtcNow.ToString('o')})
if (-not $stable -or -not $artifactStable) { throw 'Inputs changed during verification; results are invalid.' }
if ($failed -ne 0) { exit 1 }
exit 0
