#requires -Version 5.1
# SafeJunkCleaner independent regression entry (no Pester, Windows PowerShell 5.1).
# Strict rule: a case passes only when its process exits 0 AND its result JSON is
# parseable, Status=Passed, Failed=0 and Assertions>0. Exit 3, -1, 4294967295,
# missing JSON, timeout or a parse error are all failures. Any failure exits 1.
[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [ValidateSet('Core', 'Release')][string]$Scope = 'Core',
    [string]$ExePath = '',
    [int]$TimeoutSeconds = 900,
    [string[]]$Case = @(),
    [switch]$KeepSandbox
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:RepoRoot 'src\Version.ps1')
$script:SuiteVersion = Get-SjcVersion
$script:StartedUtc = [datetime]::UtcNow
$script:PowerShellPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8Bom = New-Object Text.UTF8Encoding($true)
$script:GateErrors = [System.Collections.Generic.List[string]]::new()
$script:Limitations = [System.Collections.Generic.List[string]]::new()
$script:DeclaredExclusions = [System.Collections.Generic.List[string]]::new()

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd_HHmmss')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $OutputDirectory = Join-Path $script:RepoRoot ('artifacts\verification\run_' + $stamp + '_' + $suffix)
}
if (-not [IO.Directory]::Exists($OutputDirectory)) { [void][IO.Directory]::CreateDirectory($OutputDirectory) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$script:OutputDirectory = $OutputDirectory

$script:AllCases = @(
    [pscustomobject]@{ Id = 'R01-rule-inventory'; Name = '规则清单/禁止项/精确根/数量'; File = 'R01-rule-inventory.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'R02-browser-discovery'; Name = '浏览器受限 Profile 发现 + 生产复用'; File = 'R02-browser-discovery.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'R03-rule-approval-seal'; Name = '规则实例审批/封存计划篡改拒绝'; File = 'R03-rule-approval-seal.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'P01-path-guards'; Name = '路径规范/包含/重解析根与祖先'; File = 'P01-path-guards.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'P02-preference-guards'; Name = '偏好类型/未知字段/未知规则/旧文件'; File = 'P02-preference-guards.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'P03-preview-session'; Name = '锁定预览会话/分页索引/独立清理/通道保护'; File = 'P03-preview-session.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'S01-scan-core'; Name = '扫描年龄/模式/同根单次枚举/计划字段/进度'; File = 'S01-scan-core.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'S02-same-root-dedupe'; Name = '同根重叠规则去重/WAL 硬拒绝/规则级年龄'; File = 'S02-same-root-dedupe.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'S03-scan-links'; Name = '链接/硬链接/重解析根与祖先'; File = 'S03-scan-links.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'C01-clean-core'; Name = '永久清理/排除保留/只读/单次声明/日志'; File = 'C01-clean-core.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'C02-clean-tamper'; Name = '候选篡改/规则封存篡改/变化/身份'; File = 'C02-clean-tamper.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'C03-clean-error-cap'; Name = '错误 200 条上限/准确总数/部分结果'; File = 'C03-clean-error-cap.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'C04-cancel'; Name = '预置取消 + 实际部分删除后协作取消'; File = 'C04-cancel.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'C05-pagination-export'; Name = '超过400候选分页/完整CSV/BOM/特殊字符'; File = 'C05-pagination-export.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'L01-logging'; Name = '日志唯一/JSON/无日志明确失败'; File = 'L01-logging.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'W01-worker-boundary'; Name = 'Worker 通道/载荷边界/失败传播'; File = 'W01-worker-boundary.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'V01-version-contract'; Name = '公开版本/计划格式/旧任务拒绝'; File = 'V01-version-contract.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N01-profile-context'; Name = '档位上下文/精确大小写/直接改拒绝/规则重建/Deep年龄'; File = 'N01-profile-context.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N02-profile-preferences'; Name = '偏好档位默认/往返/未知字段/非法值'; File = 'N02-profile-preferences.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N03-plan-profile-seal'; Name = '封存档位/跨档拒绝/切回仍拒/会话epoch/旧meta拒绝'; File = 'N03-plan-profile-seal.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N04-override-gate'; Name = '覆盖变量仅禁用/UnsupportedConfiguration/逐文件重验'; File = 'N04-override-gate.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N05-icon-white-background'; Name = '白底图标 7 尺寸/纯白角/不透明/居中/PNG256'; File = 'N05-icon-white-background.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N06-local-promotion'; Name = '晋级工具独立自测 30 项 + 真实只读预检 + 云标签静态守卫'; File = 'N06-local-promotion.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N07-preset-custom-authorization'; Name = '三档预设集合包含关系/年龄表/CustomOnly/预设精确集合/Custom 授权/封存模式'; File = 'N07-preset-custom-authorization.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N08-tier-cleanup-layout'; Name = '三档真实新增布局扫描/NewTeams三子根/旁路业务文件保护/逐档清理'; File = 'N08-tier-cleanup-layout.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N09-engine-expansion'; Name = '精确PureCache白名单0/零年龄不绕过其他闸门/Teams WebView2归属(隔离mock)'; File = 'N09-engine-expansion.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N10-cache-discovery'; Name = 'NuGet/pip精确布局/展示绑定/失效撤销/Worker拒绝路径注入'; File = 'N10-cache-discovery.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'N11-maintenance-contract'; Name = '固定DISM规格/签名拒绝/TestMode/启动结果(隔离mock)'; File = 'N11-maintenance-contract.ps1'; Scope = 'Core'; RequiresGui = $false; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'G01-gui-selftest'; Name = 'Test-SjcGui 无破坏状态/冻结/快照/分页'; File = 'G01-gui-selftest.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $false; Sta = $true }
    [pscustomobject]@{ Id = 'G02-background-preview'; Name = '真实后台分页/导出/保留/失败取消恢复'; File = 'G02-background-preview.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $false; Sta = $true }
    [pscustomobject]@{ Id = 'G03-profile-ui'; Name = '档位控件/严格载荷/失效重扫/确认窗口档位'; File = 'G03-profile-ui.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $false; Sta = $true }
    [pscustomobject]@{ Id = 'G04-expansion-ui'; Name = '测试上下文/失效授权/发现维护取消/维护结果与释放'; File = 'G04-expansion-ui.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $false; Sta = $true }
    [pscustomobject]@{ Id = 'W02-worker-selftest'; Name = 'Main SelfTest 完整沙箱 + 严格退出码'; File = 'W02-worker-selftest.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $false; Sta = $false }
    [pscustomobject]@{ Id = 'X01-exe-selftest'; Name = 'EXE 版本/签名/SelfTest 输出/图标资源'; File = 'X01-exe-selftest.ps1'; Scope = 'Release'; RequiresGui = $true; RequiresExe = $true; Sta = $false }
)

function Add-GateError {
    param([string]$Message)
    [void]$script:GateErrors.Add($Message)
}

function Get-RelativeRepoPath {
    param([string]$FullPath)
    if ($FullPath.StartsWith($script:RepoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return $FullPath.Substring($script:RepoRoot.Length + 1)
    }
    return $FullPath
}

function Get-SourceRecord {
    param([string]$FullPath, [switch]$Optional)
    if (-not [IO.File]::Exists($FullPath)) {
        if (-not $Optional) { Add-GateError ('缺少必需源文件：' + $FullPath) }
        return $null
    }
    $bytes = [IO.File]::ReadAllBytes($FullPath)
    $info = [IO.FileInfo]::new($FullPath)
    return [pscustomobject]@{
        Path    = Get-RelativeRepoPath $FullPath
        SHA256  = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash
        Bytes   = [int64]$info.Length
        BOM     = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    }
}

function Test-ScriptFileGate {
    param([string]$FullPath)
    $relative = Get-RelativeRepoPath $FullPath
    $bytes = [IO.File]::ReadAllBytes($FullPath)
    if ($bytes.Length -lt 3 -or $bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) {
        Add-GateError ('UTF-8 BOM 缺失：' + $relative)
    }
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($FullPath, [ref]$tokens, [ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        Add-GateError ('Parser 错误 ' + $relative + '：' + (@($parseErrors | ForEach-Object { $_.Message }) -join '; '))
        return $null
    }
    return $ast
}

function Test-ModuleDefinitionOnly {
    param([string]$FullPath)
    $ast = Test-ScriptFileGate $FullPath
    if ($null -eq $ast) { return }
    $relative = Get-RelativeRepoPath $FullPath
    foreach ($statement in @($ast.EndBlock.Statements)) {
        $type = $statement.GetType().Name
        if ($type -eq 'FunctionDefinitionAst') { continue }
        if ($type -eq 'AssignmentStatementAst') {
            $left = $statement.Left.Extent.Text
            if ($left -match '^\$script:[A-Za-z_][A-Za-z0-9_]*$' -or $left -match '^\$global:[A-Za-z_][A-Za-z0-9_]*$') { continue }
        }
        Add-GateError ('模块顶层可执行/非函数语句：' + $relative + ' -> ' + $statement.Extent.Text.Substring(0, [math]::Min(120, $statement.Extent.Text.Length)))
    }
}

function Get-SourceHashes {
    $records = [System.Collections.Generic.List[object]]::new()
    # Icon and build-script bytes are acceptance inputs: changing either must invalidate a
    # previous acceptance, so they belong in the same hash set publish/promotion compare.
    foreach ($relative in @('version.json', 'src\Version.ps1', 'src\Main.ps1', 'src\Rules.ps1', 'src\Core.ps1', 'src\Discovery.ps1', 'src\Maintenance.ps1', 'src\Worker.ps1', 'src\Gui.ps1', 'scripts\build.ps1', 'assets\app.ico')) {
        $record = Get-SourceRecord (Join-Path $script:RepoRoot $relative) -Optional
        if ($null -ne $record) { $records.Add($record) }
    }
    # Additional executed/derived inputs: N06 runs the promotion scripts, and the icon is
    # generated from app-icon-source.png by generate-icon.ps1. Hashing them means a change
    # to any of these invalidates an existing acceptance instead of reusing a stale pass.
    foreach ($relative in @('scripts\generate-icon.ps1', 'assets\app-icon-source.png', 'scripts\local-promotion-common.ps1', 'scripts\promote-local.ps1', 'scripts\seal-local-promotion.ps1', 'scripts\test-local-promotion.ps1', 'scripts\publish.ps1')) {
        $record = Get-SourceRecord (Join-Path $script:RepoRoot $relative) -Optional
        if ($null -ne $record) { $records.Add($record) }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'tests') -Recurse -File -Filter '*.ps1' | Sort-Object FullName)) {
        $record = Get-SourceRecord $file.FullName
        if ($null -ne $record) { $records.Add($record) }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExePath) -and [IO.File]::Exists($ExePath)) {
        $exeRecord = Get-SourceRecord $ExePath
        if ($null -ne $exeRecord) { $records.Add($exeRecord) }
    }
    return @($records)
}

function Get-ExeFacts {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return $null }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return [pscustomobject]@{
        Path = $Path
        SHA256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        FileVersion = $info.FileVersion
        ProductVersion = $info.ProductVersion
        Signature = [string](Get-AuthenticodeSignature -LiteralPath $Path).Status
        Bytes = ([IO.FileInfo]$Path).Length
    }
}

function Quote-Arg {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

# PowerShell 5.1 unwraps empty/single-element arrays coming out of an `if` or a
# pipeline into $null/scalar. That serializes as `{}` or a bare string and breaks
# JSON consumers that expect arrays (e.g. publish.ps1 CoverageGaps Count checks).
# Returning a typed array with the unary comma keeps the shape stable.
function ConvertTo-StringArrayValue {
    param($Value)
    $items = @()
    if ($null -ne $Value) { $items = @($Value | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ }) }
    return ,([string[]]$items)
}

function ConvertTo-ObjectArrayValue {
    param($Value)
    $items = @()
    if ($null -ne $Value) { $items = @($Value | Where-Object { $null -ne $_ }) }
    return ,([object[]]$items)
}

function Write-Summary {
    param([string]$Status, $Results, [int]$ExitCode)
    $passed = @($Results | Where-Object { $_.Status -eq 'Passed' }).Count
    $failed = @($Results | Where-Object { $_.Status -eq 'Failed' }).Count
    $blocked = @($Results | Where-Object { $_.Status -eq 'Blocked' }).Count
    $assertions = 0
    foreach ($r in $Results) { $assertions += [int]$r.Assertions }
    $summary = [ordered]@{
        Suite = 'SafeJunkCleaner independent regression'
        SuiteVersion = $script:SuiteVersion
        Scope = $Scope
        Status = $Status
        StartedUtc = $script:StartedUtc.ToString('o')
        FinishedUtc = [datetime]::UtcNow.ToString('o')
        Host = [ordered]@{
            PowerShell = $PSVersionTable.PSVersion.ToString()
            OS = [Environment]::OSVersion.VersionString
            Machine = [Environment]::MachineName
            Entry = $PSCommandPath
        }
        Entry = $PSCommandPath
        Passed = $passed
        Failed = $failed
        Blocked = $blocked
        Cases = @($Results).Count
        Assertions = $assertions
        Results = (ConvertTo-ObjectArrayValue $Results)
        SourceHashes = (ConvertTo-ObjectArrayValue (Get-SourceHashes))
        HashFormat = 'SHA256 uppercase hex; Path relative to repository root'
        Exe = Get-ExeFacts $ExePath
        Limitations = (ConvertTo-StringArrayValue $script:Limitations)
        DeclaredExclusions = (ConvertTo-StringArrayValue $script:DeclaredExclusions)
        CoverageGaps = (ConvertTo-StringArrayValue ($Results | ForEach-Object { @($_.CoverageGaps) } | Where-Object { $_ }))
        GateErrors = (ConvertTo-StringArrayValue $script:GateErrors)
        OutputDirectory = $script:OutputDirectory
        ExitCode = $ExitCode
    }
    $summaryPath = Join-Path $script:OutputDirectory 'summary.json'
    [IO.File]::WriteAllText($summaryPath, ($summary | ConvertTo-Json -Depth 12), $script:Utf8Bom)
    return $summaryPath
}

# ---- source gates -----------------------------------------------------------
if (-not [IO.File]::Exists($script:PowerShellPath)) { Add-GateError ('缺少 Windows PowerShell 5.1：' + $script:PowerShellPath) }
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { Add-GateError '本套件只支持 Windows。' }
$requiredModules = @('src\Rules.ps1', 'src\Core.ps1', 'src\Discovery.ps1', 'src\Maintenance.ps1', 'src\Worker.ps1')
foreach ($relative in $requiredModules) {
    $full = Join-Path $script:RepoRoot $relative
    if (-not [IO.File]::Exists($full)) { Add-GateError ('缺少模块：' + $relative); continue }
    Test-ModuleDefinitionOnly $full | Out-Null
}
$mainPath = Join-Path $script:RepoRoot 'src\Main.ps1'
if (-not [IO.File]::Exists($mainPath)) { Add-GateError '缺少入口 src\Main.ps1' } else { Test-ScriptFileGate $mainPath | Out-Null }
$guiPresent = [IO.File]::Exists((Join-Path $script:RepoRoot 'src\Gui.ps1'))

# ---- case selection ---------------------------------------------------------
# Scope=Core (default) selects only Core cases and is NOT a release acceptance.
# Scope=Release selects every case. An explicit -Case naming a Release-only case
# under Scope=Core is a usage error, not a silent skip.
$selected = [System.Collections.Generic.List[object]]::new()
# -File passes "-Case a,b" as one string; accept both comma lists and repeated values.
$casePatterns = @(@($Case) | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$explicitFilter = $casePatterns.Count -gt 0
$filtered = $script:AllCases
if ($explicitFilter) {
    $filtered = @($script:AllCases | Where-Object { $id = $_.Id; @($casePatterns | Where-Object { $id -like $_ }).Count -gt 0 })
    if ($filtered.Count -eq 0) { Add-GateError ('-Case 未匹配任何用例：' + ($casePatterns -join ',')) }
}
foreach ($item in $filtered) {
    if ($Scope -eq 'Core' -and $item.Scope -ne 'Core') {
        if ($explicitFilter) { Add-GateError ('用例 ' + $item.Id + ' 属于 Release 范围；请使用 -Scope Release') }
        continue
    }
    $selected.Add($item)
}
if ($selected.Count -eq 0 -and $script:GateErrors.Count -eq 0) { Add-GateError 'Scope=Core 未选中任何用例。' }

# BOM/parse gate for test sources. Core checks only the shared harness plus the
# selected case files, so an unrelated in-progress Release helper cannot block a
# core run; Release checks every test script to keep the release gate strict.
$gateFiles = [System.Collections.Generic.List[string]]::new()
foreach ($libFile in @('lib\Harness.ps1', 'lib\cancel_watch.ps1')) {
    $full = Join-Path (Join-Path $script:RepoRoot 'tests') $libFile
    if ([IO.File]::Exists($full)) { $gateFiles.Add($full) } else { Add-GateError ('缺少测试库：' + $libFile) }
}
if ($Scope -eq 'Release') {
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:RepoRoot 'tests') -Recurse -File -Filter '*.ps1' | Sort-Object FullName)) {
        if (-not $gateFiles.Contains($file.FullName)) { $gateFiles.Add($file.FullName) }
    }
}
else {
    foreach ($item in $selected) {
        $full = Join-Path (Join-Path $script:RepoRoot 'tests\cases') $item.File
        if ([IO.File]::Exists($full)) { $gateFiles.Add($full) }
    }
}
foreach ($full in $gateFiles) { Test-ScriptFileGate $full | Out-Null }

$script:Limitations.Add('真实回收站清空未执行：属于 DeclaredExclusion，仅验证测试上下文拒绝、系统确认标志未被关闭与接口返回形状。')
$script:Limitations.Add('真实 GUI 窗口/DPI/多显示器视觉未由本套件观测：需要单独进行桌面验收；本套件只执行 Test-SjcGui 无破坏状态自检。')
$script:Limitations.Add('文件名竞态与路径 TOCTOU 无法由测试全绿证明；用例只验证已实现的重解析/身份/封存复核分支。')
$script:Limitations.Add('Main 对 Cancelled/Partial 的退出码未能在不扫描生产目录的前提下独立触发；已实测 Failed 与 SelfTest 成功路径，源码契约要求仅 Success 返回 0。')
if ($Scope -eq 'Core') {
    $script:Limitations.Add('Scope=Core 未执行 GUI/Test-SjcGui、完整 SelfTest、EXE、真实回收站或真实桌面观察；不得据此声称本版本已发布验收。')
}
if ($KeepSandbox) { $script:Limitations.Add('本次使用 -KeepSandbox：GUID 沙箱保留在 artifacts 之外的生产 StateRoot\Sandboxes 下，需人工确认后清理。') }
$script:DeclaredExclusions.Add('真实回收站清空（Invoke-SjcRecycle 以测试上下文拒绝；生产调用需 OS 确认）未执行。')
$script:DeclaredExclusions.Add('DPI/真实窗口视觉观察未由 suite 执行。')

$results = [System.Collections.Generic.List[object]]::new()
if ($script:GateErrors.Count -gt 0) {
    $path = Write-Summary -Status 'Failed' -Results @() -ExitCode 1
    Write-Output ('SUITE GATE FAILED; summary=' + $path)
    foreach ($e in $script:GateErrors) { Write-Output ('[GATE] ' + $e) }
    exit 1
}

if ($Scope -eq 'Release' -and [string]::IsNullOrWhiteSpace($ExePath)) {
    $script:Limitations.Add('Release 模式未提供 -ExePath；EXE 用例不会执行。')
}
if ($Scope -eq 'Release' -and -not $guiPresent) {
    $script:Limitations.Add('src/Gui.ps1 未落盘；GUI 与完整 SelfTest 用例将阻塞。')
}
if ($KeepSandbox) { $env:SJC_KEEP_SANDBOX = '1' } else { Remove-Item Env:SJC_KEEP_SANDBOX -ErrorAction SilentlyContinue }

Write-Output ('SUITE START scope=' + $Scope + ' cases=' + $selected.Count + ' output=' + $OutputDirectory)
foreach ($item in $selected) {
    $caseId = $item.Id
    $resultPath = Join-Path $OutputDirectory ($caseId + '.result.json')
    $stdoutPath = Join-Path $OutputDirectory ($caseId + '.stdout.log')
    $stderrPath = Join-Path $OutputDirectory ($caseId + '.stderr.log')
    $evidenceDir = Join-Path $OutputDirectory ('evidence\' + $caseId)
    if (-not [IO.Directory]::Exists($evidenceDir)) { [void][IO.Directory]::CreateDirectory($evidenceDir) }

    $skipReason = ''
    if ($item.RequiresGui -and -not $guiPresent) { $skipReason = 'src/Gui.ps1 未落盘' }
    if ($item.RequiresExe -and [string]::IsNullOrWhiteSpace($ExePath)) { $skipReason = '未提供 -ExePath' }
    if ($item.RequiresExe -and -not [string]::IsNullOrWhiteSpace($ExePath) -and -not [IO.File]::Exists($ExePath)) { $skipReason = 'EXE 不存在：' + $ExePath }
    if ($skipReason) {
        $blocked = [pscustomobject]@{ Id = $caseId; Name = $item.Name; Status = 'Blocked'; ExitCode = $null; Assertions = 0; Passed = 0; Failed = 0; DurationSeconds = 0; ResultPath = ''; Stdout = ''; Stderr = ''; CoverageGaps = @($skipReason); DeclaredExclusions = @(); Error = $skipReason }
        $results.Add($blocked)
        Write-Output ('[BLOCKED] ' + $caseId + ' :: ' + $skipReason)
        continue
    }

    $casePath = Join-Path (Join-Path $script:RepoRoot 'tests\cases') $item.File
    if (-not [IO.File]::Exists($casePath)) {
        $blocked = [pscustomobject]@{ Id = $caseId; Name = $item.Name; Status = 'Failed'; ExitCode = $null; Assertions = 0; Passed = 0; Failed = 0; DurationSeconds = 0; ResultPath = ''; Stdout = ''; Stderr = ''; CoverageGaps = @(); DeclaredExclusions = @(); Error = '用例文件缺失：' + $casePath }
        $results.Add($blocked)
        Write-Output ('[FAIL] ' + $caseId + ' :: case file missing')
        continue
    }

    $arguments = '-NoProfile -ExecutionPolicy Bypass '
    if ($item.Sta) { $arguments += '-Sta ' }
    $arguments += ('-File ' + (Quote-Arg $casePath) + ' -RepoRoot ' + (Quote-Arg $script:RepoRoot) + ' -CaseId ' + (Quote-Arg $caseId) + ' -ResultPath ' + (Quote-Arg $resultPath) + ' -EvidenceDirectory ' + (Quote-Arg $evidenceDir))
    if ($item.RequiresGui) { $arguments += ' -LoadGui' }
    if ($item.RequiresExe -and -not [string]::IsNullOrWhiteSpace($ExePath)) { $arguments += (' -ExePath ' + (Quote-Arg $ExePath)) }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $script:PowerShellPath; $startInfo.Arguments = $arguments
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::new(); $proc.StartInfo = $startInfo
    if (-not $proc.Start()) { throw ('无法启动用例：' + $caseId) }
    $null = $proc.Handle
    $stdoutRead = $proc.StandardOutput.ReadToEndAsync(); $stderrRead = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        $timedOut = $true
        try { $proc.Kill() } catch { }
        [void]$proc.WaitForExit(10000)
    }
    $sw.Stop()
    $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { $null }
    if ($proc.HasExited) {
        [IO.File]::WriteAllText($stdoutPath,$stdoutRead.GetAwaiter().GetResult(),$script:Utf8Bom)
        [IO.File]::WriteAllText($stderrPath,$stderrRead.GetAwaiter().GetResult(),$script:Utf8Bom)
    }
    $proc.Dispose()
    $caseResult = $null
    $parseError = ''
    if ([IO.File]::Exists($resultPath)) {
        try { $caseResult = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $parseError = $_.Exception.Message }
    }
    $status = 'Failed'
    $errorText = ''
    if ($timedOut) { $errorText = '用例超时：' + $TimeoutSeconds + 's' }
    elseif ($exitCode -ne 0) { $errorText = '退出码非零：' + [string]$exitCode }
    elseif ($null -eq $caseResult) { $errorText = '结果 JSON 缺失或不可解析：' + $parseError }
    elseif ($caseResult.Status -ne 'Passed') { $errorText = '结果 Status=' + [string]$caseResult.Status + '；Failed=' + [string]$caseResult.Failed }
    elseif ($null -eq $caseResult.PSObject.Properties['Assertions'] -or [int]$caseResult.Assertions -le 0) { $errorText = 'Assertions<=0，不能计为通过' }
    elseif ([int]$caseResult.Failed -ne 0) { $errorText = 'Failed=' + [string]$caseResult.Failed }
    elseif (([int]$caseResult.Passed + [int]$caseResult.Failed) -ne [int]$caseResult.Assertions) { $errorText = 'Passed+Failed != Assertions' }
    elseif ($null -ne $caseResult.PSObject.Properties['CoverageGaps'] -and @($caseResult.CoverageGaps).Count -gt 0) { $errorText = '存在 CoverageGaps，不能计为通过：' + (@($caseResult.CoverageGaps) -join '; ') }
    else { $status = 'Passed' }

    $entry = [pscustomobject]@{
        Id = $caseId
        Name = $item.Name
        Status = $status
        ExitCode = $exitCode
        TimedOut = $timedOut
        Assertions = if ($null -ne $caseResult -and $null -ne $caseResult.PSObject.Properties['Assertions']) { [int]$caseResult.Assertions } else { 0 }
        Passed = if ($null -ne $caseResult -and $null -ne $caseResult.PSObject.Properties['Passed']) { [int]$caseResult.Passed } else { 0 }
        Failed = if ($null -ne $caseResult -and $null -ne $caseResult.PSObject.Properties['Failed']) { [int]$caseResult.Failed } else { 0 }
        DurationSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        ResultPath = $resultPath
        Stdout = $stdoutPath
        Stderr = $stderrPath
        CoverageGaps = $(if ($null -ne $caseResult -and $null -ne $caseResult.PSObject.Properties['CoverageGaps']) { ConvertTo-StringArrayValue $caseResult.CoverageGaps } else { [string[]]@() })
        DeclaredExclusions = $(if ($null -ne $caseResult -and $null -ne $caseResult.PSObject.Properties['DeclaredExclusions']) { ConvertTo-StringArrayValue $caseResult.DeclaredExclusions } else { [string[]]@() })
        Error = $errorText
    }
    $results.Add($entry)
    foreach ($ex in @($entry.DeclaredExclusions)) { if ($ex -and -not $script:DeclaredExclusions.Contains($ex)) { [void]$script:DeclaredExclusions.Add($ex) } }
    Write-Output ('[' + $status.ToUpperInvariant() + '] ' + $caseId + ' assertions=' + $entry.Assertions + ' failed=' + $entry.Failed + ' exit=' + [string]$exitCode + ' ' + $errorText)
}

$failedCount = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
$blockedCount = @($results | Where-Object { $_.Status -eq 'Blocked' }).Count
if ($failedCount -gt 0) { $suiteStatus = 'Failed' }
elseif ($blockedCount -gt 0) { $suiteStatus = 'Incomplete' }
elseif ($results.Count -ne $selected.Count) { $suiteStatus = 'Incomplete' }
else { $suiteStatus = 'Passed' }
$exit = if ($suiteStatus -eq 'Passed') { 0 } else { 1 }
$summaryPath = Write-Summary -Status $suiteStatus -Results $results.ToArray() -ExitCode $exit
Write-Output ('SUITE RESULT: ' + $suiteStatus + ' passed=' + @($results | Where-Object { $_.Status -eq 'Passed' }).Count + ' failed=' + $failedCount + ' blocked=' + $blockedCount + ' summary=' + $summaryPath)
exit $exit
