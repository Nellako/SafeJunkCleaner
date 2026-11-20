#requires -Version 5.1
<#
.SYNOPSIS
Runs isolated quick-clean behavior checks in Windows PowerShell 5.1 against the supplied source snapshot.
.DESCRIPTION
When ExePath is supplied, also runs packaged SelfTest, bound to sibling build/source manifests.
History and Crash require a staged QuickClean.Verification.exe alongside its DLL, runtime files and the input-bound Host DLL.
.EXAMPLE
powershell.exe -NoProfile -File .\Test-QuickCleanCore.ps1 -SourceRoot <snapshot> -EvidenceParent <authorized-GUID-directory> -VerificationExePath <staged-verifier> -VerificationHostSha256 <host-dll-hash>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceParent,
    [string]$ExePath,
    [string]$VerificationExePath,
    [string]$VerificationHostSha256,
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
    if ($Cases -contains 'History') {
        foreach ($name in @('Gui.ps1','QuickCleanGuiBridge.ps1','ExplorerGui.ps1')) { $paths += Join-Path $Root ('src\' + $name) }
    }
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
function Get-BetaPackagedHostHash([string]$Binary) {
    $root = [IO.Path]::GetDirectoryName($Binary)
    $buildManifest = Read-BetaJson (Join-Path $root 'build-manifest.json')
    $component = @($buildManifest.Components | Where-Object Name -CEQ 'ExplorerHost')
    Assert-BetaEqual 1 $component.Count 'Packaged dual-host component must be unique'
    $manifestPath = Join-Path $root 'explorer\host-component-manifest.json'
    $manifest = Read-BetaJson $manifestPath
    Assert-BetaEqual $component[0].ManifestSHA256 (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash 'Packaged Host manifest hash'
    $entry = @($manifest.Components | Where-Object Path -CEQ 'sjc-quickclean.dll')
    Assert-BetaEqual 1 $entry.Count 'Packaged QuickClean DLL must be unique'
    $dll = Join-Path $root 'explorer\sjc-quickclean.dll'
    Assert-BetaPlainPath $dll
    $hash = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
    Assert-BetaEqual $entry[0].SHA256 $hash 'Packaged QuickClean DLL hash'
    return $hash
}
function Get-BetaVerificationFacts {
    Assert-Beta ($VerificationHostSha256 -match '^[0-9A-Fa-f]{64}$') 'History/Crash require an expected QuickClean Host DLL SHA256.'
    $exe = Get-BetaLocalPath $VerificationExePath
    Assert-BetaEqual 'QuickClean.Verification.exe' ([IO.Path]::GetFileName($exe)) 'Expected the staged verifier apphost'
    $root = [IO.Path]::GetDirectoryName($exe)
    $files = @(foreach ($name in @('QuickClean.Verification.exe','QuickClean.Verification.dll','QuickClean.Verification.deps.json','QuickClean.Verification.runtimeconfig.json','sjc-quickclean.dll')) {
        $path = Join-Path $root $name
        Assert-BetaPlainPath $path
        [pscustomobject]@{Name=$name;Path=$path;SHA256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash;Bytes=[IO.FileInfo]::new($path).Length}
    })
    Assert-BetaEqual $VerificationHostSha256.ToUpperInvariant() $files[-1].SHA256 'Staged QuickClean Host DLL differs from the requested input'
    return [pscustomobject]@{Exe=$exe;Root=$root;Files=$files}
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
function Invoke-BetaHostCase([string]$Case,[string]$Directory,[string]$HostRun) {
    $facts = Get-BetaVerificationFacts
    $parent = $EvidenceParent
    $HostRun = Assert-BetaChildPath $HostRun $parent
    Assert-BetaPlainPath $HostRun
    $env:SJC_QC_CORE_CASE_DIRECTORY = $Directory
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $facts.Exe
    $info.Arguments = 'core-fixture "{0}" "{1}" {2} {3}' -f $parent,$HostRun,$Case,$VerificationHostSha256
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $started = $false
    try {
        $started = $process.Start()
        Assert-Beta $started 'Failed to start owned Host verification driver.'
        $null = $process.Handle
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        Assert-Beta ($process.WaitForExit(900000)) 'Owned Host verification driver exceeded its bounded job timeouts.'
        Write-BetaNewText (Join-Path $Directory 'host.stdout.txt') $stdout.GetAwaiter().GetResult()
        Write-BetaNewText (Join-Path $Directory 'host.stderr.txt') $stderr.GetAwaiter().GetResult()
        Assert-BetaEqual 0 $process.ExitCode "Owned Host verification failed; see $Directory"
        $result = $stdout.Result | ConvertFrom-Json
        Assert-BetaEqual $Case $result.Name 'Verification case mismatch'
        Assert-BetaEqual 'Passed' $result.Outcome 'Verification driver did not report pass'
        Assert-BetaEqual $parent $result.Parent 'Verification evidence parent mismatch'
        $run = Assert-BetaChildPath $result.Run $parent
        Assert-BetaEqual $HostRun $run 'Verification returned the wrong launcher-bound Host run'
        $root = Assert-BetaChildPath $result.Root $run
        $evidence = Join-Path $root ($Case + '.pass.json')
        $checks = Read-BetaJson $evidence
        if ($Case -eq 'History') {
            # The real WPF bridge invokes the read-only verifier apphost transport,
            # which freshly reopens this authenticated Host fixture; no injected rows.
            . (Join-Path $SourceRoot 'src\ExplorerGui.ps1')
            . (Join-Path $SourceRoot 'src\Gui.ps1')
            $env:SJC_TEST_DRIVER_TOKEN = $env:SJC_QUICK_BETA_NONCE
            $env:SJC_QC_VERIFY_PARENT = $parent
            $env:SJC_QC_VERIFY_RUN = $run
            $env:SJC_QC_VERIFY_ROOT = $root
            $env:SJC_QC_VERIFY_HOST_SHA256 = $VerificationHostSha256
            $id = [guid]::NewGuid().ToString('D')
            $verification = @{Name='QuickCleanVerification';Root=$facts.Root;Paths=$facts.Files.Name;Hashes=$facts.Files.SHA256;Sizes=$facts.Files.Bytes;RejectLinks=$true;Extras=$false;Ancestors=$true;AllowedExtra=''}
            $script:SjcQuickCleanTestContext = @{Id=$id;UseHostInTestMode=$true;LaunchSpec=@{TestId=$id;Exe=$facts.Exe;Verifications=@($verification)}}
            $guiOnly = New-SjcTestSandbox -ParentDirectory (Join-Path $Directory 'gui-sandboxes')
            $state = New-SjcGuiState $guiOnly.Context -TestMode
            Assert-Beta ($state.History -is [System.Collections.IList]) 'QuickClean GUI history must be a list'
            $app = New-SjcGuiApp $state
            try {
                $app.Ui.Window.Show()
                $app.Ui.LogsToggle.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
                $app.Ui.Window.UpdateLayout()
                Assert-BetaEqual 'Visible' ([string]$app.Ui.LogsPanel.Visibility) 'Task records did not open'
                $displayed = @($app.Ui.HistoryList.Items | ForEach-Object { $_ })
                Assert-BetaEqual $checks.AfterReplay.Count $displayed.Count 'WPF rows differ from persisted attempts'
                for ($i = 0; $i -lt $displayed.Count; $i++) {
                    foreach ($key in @('Time','Action','Status','Summary','TaskDirectory','LogPath')) {
                        Assert-BetaEqual $checks.AfterReplay[$i].$key $displayed[$i].$key "WPF row $i field $key differs from actual Host history"
                    }
                }
                $completedLog = $checks.Clean.Result.LogPath
                $selectedIndex = -1
                for ($i = 0; $i -lt $displayed.Count; $i++) { if ($displayed[$i].LogPath -ceq $completedLog) { $selectedIndex = $i } }
                Assert-Beta ($selectedIndex -ge 0) 'Completed WPF row missing'
                $app.Ui.HistoryList.SelectedIndex = $selectedIndex
                Update-SjcGuiView $app
                $selected = $app.Ui.HistoryList.SelectedItem
                Assert-BetaEqual $completedLog $selected.LogPath 'Selecting completed history did not keep the intended row'
                Assert-BetaEqual $checks.Clean.Result.ProcessedBytes $selected.Result.ProcessedBytes 'WPF did not load logical bytes from the actual clean log'
                Save-SjcGuiRender $app.Ui.Window (Join-Path $Directory 'history-900x680.png')
                Write-BetaJson (Join-Path $Directory 'history.json') $displayed
            } finally {
                $state.Busy = $false
                $app.Ui.Window.Close()
            }
        }
        Write-BetaJson (Join-Path $Directory 'result.json') ([ordered]@{Case=$Case;Outcome='Pass';Root=$root;HostEvidence=$evidence})
    } finally {
        if ($started -and -not $process.HasExited) { $process.Kill(); [void]$process.WaitForExit(5000) }
        $process.Dispose()
    }
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
        if ($ChildCase -in 'History','Crash') {
            Invoke-BetaHostCase $ChildCase $caseDirectory $owner.HostRun
            exit 0
        }
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
            'CleanCancel' {
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
    if ($Name -eq 'History') { $Name = 'History' }
    if ($Name -eq 'Crash') { $Name = 'Crash' }
    $directory = New-BetaDirectory $Run $Name
    $owner = [ordered]@{Nonce=$Nonce;Case=$Name;SourceRoot=$SourceRoot}
    if ($Name -in 'History','Crash') {
        # Keep real Host paths short while retaining a private, exclusive GUID tree.
        $owner['HostRun'] = New-BetaDirectory $EvidenceParent ([guid]::NewGuid().ToString('D'))
    }
    Write-BetaJson (Join-Path $directory 'owner.json') $owner
    $temp = New-BetaDirectory $directory 'tmp'
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $PSHOME 'powershell.exe'
    $info.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "{0}" -SourceRoot "{1}" -EvidenceParent "{2}" -RunDirectory "{3}" -ChildCase {4}' -f $PSCommandPath,$SourceRoot,$EvidenceParent,$Run,$Name
    if ($Name -in 'History','Crash') {
        $info.Arguments += ' -VerificationExePath "{0}" -VerificationHostSha256 {1}' -f $VerificationExePath,$VerificationHostSha256
    }
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
        if ($Name -eq 'CleanCancel') {
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
            Write-BetaNewText (Join-Path $task 'beta.cancel') 'cancel'
            Write-BetaJson (Join-Path $directory 'signal.json') ([ordered]@{Pid=$ready.Pid;Claim=$claim;ObservedUtc=$observedUtc;Signal='CancelChannel'})
        }
        $timeout = if ($Name -in 'History','Crash') { 960000 } else { 60000 }
        Assert-Beta ($process.WaitForExit($timeout)) 'Owned child timed out.'
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
$verification = $null
if ($ExePath) {
    $ExePath = Get-BetaLocalPath $ExePath
    $build = Get-BetaBuildFacts $ExePath $before
}
if ($Cases -contains 'History' -or $Cases -contains 'Crash') {
    if ($build) {
        $hostHash = Get-BetaPackagedHostHash $ExePath
        if ($VerificationHostSha256) { Assert-BetaEqual $hostHash $VerificationHostSha256.ToUpperInvariant() 'Requested Host differs from packaged Host' }
        $VerificationHostSha256 = $hostHash
    }
    $verification = Get-BetaVerificationFacts
    $VerificationExePath = $verification.Exe
}
$testHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
Write-BetaJson (Join-Path $run 'inputs.json') ([ordered]@{SourceRoot=$SourceRoot;Files=$before;Build=$build;Verification=$verification;HostSha256=$VerificationHostSha256;TestSha256=$testHash;Cases=$Cases;StartedUtc=[datetime]::UtcNow.ToString('o')})
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
if ($verification) {
    try {
        $artifactStable = $artifactStable -and (($verification | ConvertTo-Json -Depth 6 -Compress) -ceq ((Get-BetaVerificationFacts) | ConvertTo-Json -Depth 6 -Compress))
        if ($build) { $artifactStable = $artifactStable -and ($VerificationHostSha256 -ceq (Get-BetaPackagedHostHash $ExePath)) }
    } catch { $artifactStable = $false }
}
$failed = @($summary | Where-Object Outcome -EQ 'Fail').Count
Write-BetaJson (Join-Path $run 'summary.json') ([ordered]@{SourceAndTestStable=$stable;ArtifactStable=$artifactStable;Build=$build;Passed=($summary.Count - $failed);Failed=$failed;Cases=$summary;FinishedUtc=[datetime]::UtcNow.ToString('o')})
if (-not $stable -or -not $artifactStable) { throw 'Inputs changed during verification; results are invalid.' }
if ($failed -ne 0) { exit 1 }
exit 0
