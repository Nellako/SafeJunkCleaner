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

$script:ReviewedCoreCases=@(([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\cases\reviewed-core-cases.json')) | ConvertFrom-Json).Reviewed)
if ($CaseId -notin $script:ReviewedCoreCases) { throw '用例未列入已审查清单，直接调用亦阻断。' }
$expectedRepo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not ([IO.Path]::GetFullPath($RepoRoot)).Equals($expectedRepo,[StringComparison]::OrdinalIgnoreCase)) { throw 'RepoRoot 必须与当前测试模块所属仓库一致。' }
$evidenceBase=[IO.Path]::GetDirectoryName($expectedRepo)+'\'
$evidenceFull=[IO.Path]::GetFullPath($EvidenceDirectory)
$resultFull=[IO.Path]::GetFullPath($ResultPath)
foreach ($path in @($evidenceFull,$resultFull)) {
    if (-not $path.StartsWith($evidenceBase,[StringComparison]::OrdinalIgnoreCase) -or ($path.Equals($expectedRepo,[StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($expectedRepo+'\',[StringComparison]::OrdinalIgnoreCase))) { throw '测试证据通道必须位于授权证据目录，不能写源码树或外部路径。' }
}

$script:CaseId = $CaseId
$script:RepoRoot = $RepoRoot
$script:ResultPath = $ResultPath
$script:EvidenceDirectory = $EvidenceDirectory
$script:Checks = [System.Collections.Generic.List[object]]::new()
$script:CoverageGaps = [System.Collections.Generic.List[string]]::new()
$script:Limitations = [System.Collections.Generic.List[string]]::new()
$script:DeclaredExclusions = [System.Collections.Generic.List[string]]::new()
$script:OwnedSandboxes = [System.Collections.Generic.List[string]]::new()
$script:OwnedTestFiles=@{}
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
. (Join-Path $RepoRoot 'src\Discovery.ps1')
. (Join-Path $RepoRoot 'src\Maintenance.ps1')
. (Join-Path $RepoRoot 'src\Worker.ps1')
$script:IsolatedSandboxParent = Join-Path $EvidenceDirectory 'Sandboxes'
Enable-SjcTestIsolation -ParentDirectory $script:IsolatedSandboxParent
Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop

if ($LoadGui) {
    $guiModule = Join-Path $RepoRoot 'src\Gui.ps1'
    if ([IO.File]::Exists($guiModule)) {
        . $guiModule
        $explorerModule = Join-Path $RepoRoot 'src\ExplorerGui.ps1'
        if ([IO.File]::Exists($explorerModule)) { . $explorerModule }
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
    # Real production templates and the same tier/preset transformations. No execution
    # registration, state directory, authorization-store import, scan or preference IO.
    $context=New-SjcRuleInventoryContext
    Assert-Throws 'inventory context cannot create executable tasks' { New-SjcTaskDirectory -Context $context } '可信上下文'
    Assert-Throws 'inventory context cannot read or write preferences' { Read-SjcPreferences -Context $context } '可信上下文'
    Assert-Throws 'inventory context cannot create operation logs' { New-SjcOperationLog -Context $context -Operation 'inventory-denied' } '可信上下文'
    Add-Limitation '真实生产模板只读清单：复用固定模板/受限Profile发现及档位变换，不导入持久授权、不创建状态、不注册执行上下文；真实扫描/清理未测。'
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
    $sandbox = New-SjcTestSandbox -ParentDirectory $script:IsolatedSandboxParent
    $root = [string]$sandbox.Root
    $leaf = [IO.Path]::GetFileName($root)
    $guid = [guid]::Empty
    $isGuid = [guid]::TryParseExact($leaf, 'D', [ref]$guid)
    $ownerPath = Join-Path $root '.sandbox-owner'
    Assert-True 'sandbox root is a registered GUID under the isolated evidence parent' ($isGuid -and [IO.Path]::GetDirectoryName($root).Equals($script:IsolatedSandboxParent,[StringComparison]::OrdinalIgnoreCase)) $root
    Assert-True 'sandbox ownership marker exists' ([IO.File]::Exists($ownerPath)) $ownerPath
    if ($isGuid) { [void]$script:OwnedSandboxes.Add($root) }
    return $sandbox
}

function Remove-OwnedDirectoryNoFollow {
    param([string]$Path, [string]$RequiredMarker = '.sandbox-owner')
    throw ('本阶段禁止任何目录清理；保留测试证据：' + $Path)
}
function Remove-OwnedSandboxes {
    # Retain registry and all directories for independent review, unconditionally.
}

# Reversible fixture mutation only. Registration pins the real file identity;
# manifest is durable before moving, and all evidence/owned directories are retained.
function Register-OwnedTestFile {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=Get-SjcFullPath $Path
    $owner=''
    foreach($root in $script:OwnedSandboxes) {
        if (Test-SjcPathWithin $full $root) { Assert-SjcSandbox $root; $owner=$root; break }
    }
    if (-not $owner -or -not (Test-SjcNoReparsePath $full)) { throw '人工文件必须属于本用例已注册无重解析沙箱。' }
    $script:OwnedTestFiles[$full]=[pscustomobject]@{Root=$owner;Identity=(Get-SjcFileIdentity $full)}
}
function Move-OwnedTestFileToEvidence {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=Get-SjcFullPath $Path
    if (-not $script:OwnedTestFiles.ContainsKey($full)) { throw '人工文件未登记，拒绝移动。' }
    $entry=$script:OwnedTestFiles[$full]
    Assert-SjcSandbox $entry.Root
    if (-not (Test-SjcNoReparsePath $full) -or (Get-SjcFileIdentity $full) -cne $entry.Identity) { throw '人工文件身份变化或路径不安全，拒绝移动。' }
    $id=[guid]::NewGuid().ToString('N')
    $destination=Join-Path $script:EvidenceDirectory ('retained-'+$id+'.fixture')
    $manifest=Join-Path $script:EvidenceDirectory ('move-manifest-'+$id+'.json')
    Write-SjcAtomicText -Path $manifest -Text ([ordered]@{Source=$full;Destination=$destination;SandboxRoot=$entry.Root;Identity=$entry.Identity;SHA256=(Get-FileSha256 $full);CreatedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Compress) -NoOverwrite
    if ((Get-SjcFileIdentity $full) -cne $entry.Identity) { throw '移动前身份变化。' }
    [IO.File]::Move($full,$destination)
    [void]$script:OwnedTestFiles.Remove($full)
}

function Move-OwnedTestDirectoryToEvidence {
    param([Parameter(Mandatory=$true)][string]$Path)
    $full=Get-SjcFullPath $Path
    $owner=''
    foreach($root in $script:OwnedSandboxes) {
        if (Test-SjcPathWithin $full $root) { Assert-SjcSandbox $root; $owner=$root; break }
    }
    if (-not $owner -or -not [IO.Directory]::Exists($full) -or -not (Test-SjcNoReparsePath $full)) { throw '目录必须属于本用例已注册无重解析沙箱。' }
    $entries=@(Get-PathSnapshot $full)
    $manifestEntries=@(foreach($entry in $entries) {
        if ($entry.IsLink -or -not (Test-SjcNoReparsePath $entry.Path)) { throw '保留目录含链接，拒绝移动。' }
        [pscustomobject]@{Path=$entry.Path;IsDirectory=$entry.IsDirectory;Length=$entry.Length;SHA256=$(if(-not $entry.IsDirectory){Get-FileSha256 $entry.Path});Identity=$(if(-not $entry.IsDirectory){Get-SjcFileIdentity $entry.Path})}
    })
    $id=[guid]::NewGuid().ToString('N')
    $destination=Join-Path ([IO.Path]::GetDirectoryName($full)) ('retained-directory-'+$id)
    Write-SjcAtomicText -Path (Join-Path $script:EvidenceDirectory ('directory-move-manifest-'+$id+'.json')) -Text ([ordered]@{Source=$full;Destination=$destination;SandboxRoot=$owner;Entries=$manifestEntries;CreatedUtc=[datetime]::UtcNow.ToString('o')}|ConvertTo-Json -Depth 8) -NoOverwrite
    Assert-SjcSandbox $owner
    if (-not (Test-SjcNoReparsePath $full) -or ($entries|ConvertTo-Json -Depth 5 -Compress) -cne ((Get-PathSnapshot $full)|ConvertTo-Json -Depth 5 -Compress)) { throw '移动前目录发生变化。' }
    [IO.Directory]::Move($full,$destination)
    return $destination
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
    Register-OwnedTestFile -Path $Path
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
    # This child can only watch this case's owned files and publish cancellation to
    # an authenticated task of the very same sandbox. No payload-provided roots.
    $watchFull=Get-SjcFullPath $WatchPath
    $cancelFull=Get-SjcFullPath $CancelPath
    $owner=''; $context=$null
    foreach($root in $script:OwnedSandboxes) {
        if (Test-SjcPathWithin $watchFull $root) { Assert-SjcSandbox $root; $owner=$root; break }
    }
    if (-not $owner) { throw 'Watcher 观察路径必须属于本用例已登记沙箱。' }
    foreach($entry in (Get-SjcRegistry)) {
        if ($entry.IsTest -and $entry.TestRoot -ceq $owner) { $context=$entry.Context; break }
    }
    if ($null -eq $context) { throw 'Watcher 沙箱没有本进程测试上下文。' }
    $task=Assert-SjcTaskDirectory $context ([IO.Path]::GetDirectoryName($cancelFull))
    [void](Assert-SjcChannel $task $cancelFull)
    if ([IO.File]::Exists($cancelFull) -or [IO.Directory]::Exists($cancelFull)) { throw 'Watcher 取消标记必须为新文件。' }
    if ($Mode -eq 'RemainingCount') {
        if ($watchFull -cne (Join-Path $owner 'files') -or -not (Test-SjcNoReparsePath $watchFull)) { throw 'Watcher 只能计数同一沙箱的自有 files。' }
        foreach($file in [IO.Directory]::GetFiles($watchFull,'*.tmp')) {
            if (-not $script:OwnedTestFiles.ContainsKey($file) -or (Get-SjcFileIdentity $file) -cne $script:OwnedTestFiles[$file].Identity) { throw 'Watcher 文件未登记或身份变化。' }
        }
    } else {
        if ($watchFull -cne (Join-Path $task 'candidates.jsonl') -or -not (Test-SjcNoReparsePath $watchFull -AllowMissing)) { throw 'Watcher 只能观察同一认证任务计划。' }
    }
    $WatchPath=$watchFull; $CancelPath=$cancelFull
    [void](Save-Evidence ('cancel-watch-boundary-'+[guid]::NewGuid().ToString('N')) ([ordered]@{Mode=$Mode;WatchPath=$WatchPath;CancelPath=$CancelPath;SandboxRoot=$owner;TaskDirectory=$task;Threshold=$Threshold}))
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
    Add-Limitation '全部测试目录无条件保留；未执行目录清理。'
    Assert-Equal 'production state unchanged during case' ($script:ProdSnapshotBeforeLoad | ConvertTo-Json -Depth 5 -Compress) (Get-PathSnapshot $script:ProdStateRoot | ConvertTo-Json -Depth 5 -Compress)
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
