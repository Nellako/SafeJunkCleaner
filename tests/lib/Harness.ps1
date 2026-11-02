# SafeJunkCleaner independent test harness (no Pester, PS 5.1).
# Dot-source from a case script with explicit -RepoRoot/-CaseId/-ResultPath/-EvidenceDirectory.
# Loads ONLY function-definition modules (Rules/Core/Worker). Main.ps1 (entry) is never dot-sourced.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$LoadGui,
    [string]$ExePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CaseId = $CaseId
$script:RepoRoot = $RepoRoot
$script:ResultPath = $ResultPath
$script:EvidenceDirectory = $EvidenceDirectory
$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:CoverageGaps = [System.Collections.Generic.List[string]]::new()
$script:Limitations = [System.Collections.Generic.List[string]]::new()
$script:DeclaredExclusions = [System.Collections.Generic.List[string]]::new()
$script:OwnedSandboxes = [System.Collections.Generic.List[string]]::new()
$script:OwnedTaskDirectories = [System.Collections.Generic.List[string]]::new()
$script:CancelHelpers = [System.Collections.Generic.List[object]]::new()
$script:StartedUtc = [datetime]::UtcNow
$script:Utf8Bom = New-Object Text.UTF8Encoding($true)
$script:Utf8NoBom = New-Object Text.UTF8Encoding($false)
$script:GuiModuleLoaded = $false
$script:ProdStateRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SafeJunkCleaner\v3'

if (-not [IO.Directory]::Exists($EvidenceDirectory)) { [void][IO.Directory]::CreateDirectory($EvidenceDirectory) }

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-PathSnapshot {
    param([string]$Root)
    $items = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Root) -or -not [IO.Directory]::Exists($Root)) { return @() }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try {
            foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)) {
                $isLink = (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
                $items.Add([pscustomobject]@{ Path = $entry.FullName; IsDirectory = [bool]$entry.PSIsContainer; IsLink = $isLink; Length = $(if ($entry.PSIsContainer) { [int64]-1 } else { [int64]$entry.Length }); LastWriteUtc = $entry.LastWriteTimeUtc.ToString('o') })
                if ($entry.PSIsContainer -and -not $isLink) { $stack.Push($entry.FullName) }
            }
        } catch { }
    }
    return @($items | Sort-Object Path)
}

# Snapshot of production state root BEFORE module load: proves module import does not scan/clean/write.
$script:ProdSnapshotBeforeLoad = Get-PathSnapshot $script:ProdStateRoot

. (Join-Path $RepoRoot 'src\Version.ps1')
. (Join-Path $RepoRoot 'src\Rules.ps1')
. (Join-Path $RepoRoot 'src\Core.ps1')
. (Join-Path $RepoRoot 'src\Worker.ps1')

if ($LoadGui) {
    $guiModule = Join-Path $RepoRoot 'src\Gui.ps1'
    if ([IO.File]::Exists($guiModule)) {
        . $guiModule
        $script:GuiModuleLoaded = $true
    }
    else {
        [void]$script:CoverageGaps.Add('src/Gui.ps1 未落盘，GUI/Test-SjcGui/完整 SelfTest 与 EXE 用例无法执行。')
    }
}

$script:ProdSnapshotAfterLoad = Get-PathSnapshot $script:ProdStateRoot

function Add-Check {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    $script:Checks.Add([pscustomobject]@{ Name = $Name; Passed = [bool]$Condition; Detail = [string]$Detail; TimeUtc = [datetime]::UtcNow.ToString('o') })
}

function Add-CoverageGap {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if (-not $script:CoverageGaps.Contains($Text)) { [void]$script:CoverageGaps.Add($Text) }
}

function Add-DeclaredExclusion {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if (-not $script:DeclaredExclusions.Contains($Text)) { [void]$script:DeclaredExclusions.Add($Text) }
}

function Add-Limitation {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    if (-not $script:Limitations.Contains($Text)) { [void]$script:Limitations.Add($Text) }
}

function New-ProductionContextForInventory {
    # Rule inventory only. Creates the v3 state root if absent; never writes
    # preferences, tasks, plans or logs, and never enumerates production caches.
    $existed = [IO.Directory]::Exists($script:ProdStateRoot)
    $context = New-SjcContext
    if (-not $existed) { Add-Limitation '生产状态根 %LOCALAPPDATA%\SafeJunkCleaner\v3 在规则清单读取时被创建（空目录），未写首选项/任务/日志。' }
    return $context
}

function Save-Evidence {
    param([string]$Name, $Value)
    $safe = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $script:EvidenceDirectory ($safe + '.json')
    [IO.File]::WriteAllText($path, ($Value | ConvertTo-Json -Depth 12), $script:Utf8Bom)
    return $path
}

function Save-EvidenceText {
    param([string]$Name, [string]$Text)
    $safe = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $script:EvidenceDirectory ($safe + '.txt')
    [IO.File]::WriteAllText($path, $Text, $script:Utf8Bom)
    return $path
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    Add-Check -Name $Name -Condition $Condition -Detail $Detail
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual, [string]$Detail = '')
    $ok = ($Expected -eq $Actual)
    $text = if ($Detail) { $Detail + '; expected=' + [string]$Expected + '; actual=' + [string]$Actual } else { 'expected=' + [string]$Expected + '; actual=' + [string]$Actual }
    Add-Check -Name $Name -Condition $ok -Detail $text
}

function Assert-Throws {
    param([string]$Name, [scriptblock]$Action, [string]$Pattern = '')
    try {
        & $Action | Out-Null
        Add-Check -Name $Name -Condition $false -Detail 'expected an exception, none was thrown'
    }
    catch {
        $message = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($Pattern)) {
            Add-Check -Name $Name -Condition $true -Detail ('threw: ' + $message)
        }
        else {
            $matches = $message -match $Pattern
            Add-Check -Name $Name -Condition ([bool]$matches) -Detail ('threw: ' + $message + '; pattern=' + $Pattern)
        }
    }
}

function New-OwnedSandbox {
    $sandbox = New-SjcTestSandbox
    $root = [string]$sandbox.Root
    $leaf = [IO.Path]::GetFileName($root)
    $guid = [guid]::Empty
    $isGuid = [guid]::TryParseExact($leaf, 'D', [ref]$guid)
    $ownerPath = Join-Path $root '.sandbox-owner'
    Assert-True 'sandbox root is GUID under production StateRoot\Sandboxes' ($isGuid -and $root.StartsWith($script:ProdStateRoot + '\Sandboxes\', [StringComparison]::OrdinalIgnoreCase)) $root
    Assert-True 'sandbox ownership marker exists' ([IO.File]::Exists($ownerPath)) $ownerPath
    if ($isGuid) { [void]$script:OwnedSandboxes.Add($root) }
    return $sandbox
}

function Remove-OwnedDirectoryNoFollow {
    param([string]$Path, [string]$RequiredMarker = '.sandbox-owner')
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Directory]::Exists($Path)) { return }
    if (-not [IO.File]::Exists((Join-Path $Path $RequiredMarker))) { throw ('refusing to remove unmarked test directory: ' + $Path) }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            $isLink = (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isLink) {
                try {
                    if ($entry.PSIsContainer) { [IO.Directory]::Delete($entry.FullName, $false) }
                    else { [IO.File]::Delete($entry.FullName) }
                } catch { }
                continue
            }
            if ($entry.PSIsContainer) { $stack.Push($entry.FullName); continue }
            try {
                if (($entry.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { $entry.Attributes = $entry.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly) }
                [IO.File]::Delete($entry.FullName)
            } catch { }
        }
    }
    $dirs = [System.Collections.Generic.List[string]]::new()
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $dirs.Add($dir)
        foreach ($entry in (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($entry.PSIsContainer -and (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { $stack.Push($entry.FullName) }
        }
    }
    foreach ($dir in ($dirs | Sort-Object Length -Descending)) {
        try { [IO.Directory]::Delete($dir, $false) } catch { try { [IO.Directory]::Delete($dir, $true) } catch { } }
    }
}

function Remove-OwnedSandboxes {
    foreach ($root in $script:OwnedSandboxes) {
        try { Remove-OwnedDirectoryNoFollow -Path $root -RequiredMarker '.sandbox-owner' } catch { }
    }
    $script:OwnedSandboxes.Clear()
}

function New-TestFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Bytes = 128,
        [double]$AgeHours = 72,
        [switch]$ReadOnly
    )
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not [IO.Directory]::Exists($dir)) { [void][IO.Directory]::CreateDirectory($dir) }
    $chunk = ('X' * [math]::Min($Bytes, 8192))
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $remaining = $Bytes
        while ($remaining -gt 0) {
            $n = [math]::Min($remaining, $chunk.Length)
            $stream.Write([Text.Encoding]::ASCII.GetBytes($chunk.Substring(0, $n)), 0, $n)
            $remaining -= $n
        }
    }
    finally { $stream.Dispose() }
    $stamp = [datetime]::UtcNow.AddHours(-1 * $AgeHours)
    [IO.File]::SetLastWriteTimeUtc($Path, $stamp)
    if ($ReadOnly) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]::ReadOnly) }
    return [IO.FileInfo]::new($Path)
}

function Get-TestFileState {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return [pscustomobject]@{ Exists = $false } }
    $f = [IO.FileInfo]::new($Path)
    return [pscustomobject]@{ Exists = $true; Length = [int64]$f.Length; LastWriteUtc = $f.LastWriteTimeUtc.ToString('o'); Attributes = [string]$f.Attributes; ReadOnly = (($f.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) }
}

function Get-CandidateLines {
    param([string]$PlanPath)
    if (-not [IO.File]::Exists($PlanPath)) { return @() }
    return @([IO.File]::ReadAllLines($PlanPath) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Start-CancelHelper {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('PlanBytes', 'RemainingCount')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$WatchPath,
        [Parameter(Mandatory = $true)][string]$CancelPath,
        [int]$Threshold = 0,
        [int]$TimeoutSeconds = 120
    )
    $helper = Join-Path $script:RepoRoot 'tests\lib\cancel_watch.ps1'
    $out = Join-Path $script:EvidenceDirectory ('cancelhelper-' + [guid]::NewGuid().ToString('N') + '.out')
    $err = Join-Path $script:EvidenceDirectory ('cancelhelper-' + [guid]::NewGuid().ToString('N') + '.err')
    $helperArgs = '-NoProfile -ExecutionPolicy Bypass -File "' + $helper + '" -Mode ' + $Mode + ' -WatchPath "' + $WatchPath + '" -CancelPath "' + $CancelPath + '" -Threshold ' + $Threshold + ' -TimeoutSeconds ' + $TimeoutSeconds
    $p = Start-Process -FilePath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -ArgumentList $helperArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err
    $record = [pscustomobject]@{ Process = $p; Output = $out; Error = $err; Mode = $Mode; CancelPath = $CancelPath }
    $script:CancelHelpers.Add($record)
    return $record
}

function Wait-CancelHelper {
    param($Helper, [int]$TimeoutSeconds = 120)
    if ($null -eq $Helper) { return $false }
    $proc = $Helper.Process
    if (-not $proc.HasExited) { [void]$proc.WaitForExit($TimeoutSeconds * 1000) }
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { }; return $false }
    # Start-Process + redirection can leave ExitCode unpopulated until WaitForExit is called.
    [void]$proc.WaitForExit(5000)
    $code = $null
    try { $code = [int]$proc.ExitCode } catch { }
    return ($code -eq 0 -and [IO.File]::Exists($Helper.CancelPath))
}

function Stop-CancelHelpers {
    foreach ($helper in $script:CancelHelpers) {
        try { if (-not $helper.Process.HasExited) { $helper.Process.Kill() } } catch { }
    }
    $script:CancelHelpers.Clear()
}

function Complete-TestCase {
    param([string]$StatusOverride = '')
    Stop-CancelHelpers
    if ($env:SJC_KEEP_SANDBOX -ne '1') { Remove-OwnedSandboxes }
    $failed = 0; $passed = 0
    foreach ($check in $script:Checks) { if ($check.Passed) { $passed++ } else { $failed++ } }
    $status = if ($StatusOverride) { $StatusOverride }
              elseif ($failed -gt 0) { 'Failed' }
              elseif ($script:CoverageGaps.Count -gt 0) { 'Blocked' }
              else { 'Passed' }
    $result = [ordered]@{
        CaseId = $script:CaseId
        Status = $status
        Assertions = $script:Checks.Count
        Passed = $passed
        Failed = $failed
        Checks = @($script:Checks)
        CoverageGaps = @($script:CoverageGaps)
        DeclaredExclusions = @($script:DeclaredExclusions)
        Limitations = @($script:Limitations)
        StartedUtc = $script:StartedUtc.ToString('o')
        FinishedUtc = [datetime]::UtcNow.ToString('o')
        EvidenceDirectory = $script:EvidenceDirectory
    }
    [IO.File]::WriteAllText($script:ResultPath, ($result | ConvertTo-Json -Depth 12), $script:Utf8Bom)
    if ($status -eq 'Passed') { exit 0 }
    exit 1
}
