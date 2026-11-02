# Core deliberately rejects unknown paths, links and missing identity information.
# Path checks reduce risk but do not eliminate Windows pathname TOCTOU races.
function Get-SjcFullPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f]' -or $Path.Substring(2).Contains(':')) { throw '必须使用本地驱动器绝对路径，禁止设备路径、UNC 与 ADS。' }
    foreach ($part in ($Path.Substring(3) -split '[\\/]')) {
        if ($part -eq '.' -or $part -eq '..' -or $part -match '[ .]$') { throw '拒绝非规范路径分段。' }
    }
    $full = [IO.Path]::GetFullPath($Path).Replace('/','\')
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full
}
function Test-SjcPathWithin {
    param([string]$Path,[string]$Root,[switch]$AllowRoot)
    $p = Get-SjcFullPath $Path; $r = Get-SjcFullPath $Root
    return (($AllowRoot -and $p.Equals($r,[StringComparison]::OrdinalIgnoreCase)) -or $p.StartsWith($r.TrimEnd('\') + '\',[StringComparison]::OrdinalIgnoreCase))
}
function Test-SjcNoReparsePath {
    param([string]$Path,[switch]$AllowMissing)
    try {
        $current = Get-SjcFullPath $Path
        while ($true) {
            try {
                $attributes = [IO.File]::GetAttributes($current)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            } catch [IO.FileNotFoundException] { if (-not $AllowMissing) { return $false } }
              catch [IO.DirectoryNotFoundException] { if (-not $AllowMissing) { return $false } }
            $parent = [IO.Directory]::GetParent($current)
            if ($null -eq $parent) { break }
            $current = $parent.FullName
        }
        return $true
    } catch { return $false }
}
function Initialize-SjcNative {
    if ('SjcV3.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace SjcV3 {
 public sealed class Identity { public string Key; public uint Links; public uint Attributes; }
 public static class Native {
  [StructLayout(LayoutKind.Sequential)] struct Info {
   public uint Attributes; public System.Runtime.InteropServices.ComTypes.FILETIME Creation;
   public System.Runtime.InteropServices.ComTypes.FILETIME Access; public System.Runtime.InteropServices.ComTypes.FILETIME Write;
   public uint Volume; public uint SizeHigh; public uint SizeLow; public uint Links; public uint IndexHigh; public uint IndexLow;
  }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out Info info);
  public static Identity ReadIdentity(string path) {
   using (SafeFileHandle h = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02200000, IntPtr.Zero)) {
    if(h.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
    Info i; if(!GetFileInformationByHandle(h,out i)) throw new Win32Exception(Marshal.GetLastWin32Error());
    return new Identity { Key=String.Format("{0:X8}:{1:X8}{2:X8}:{3:X8}{4:X8}",i.Volume,i.IndexHigh,i.IndexLow,i.Creation.dwHighDateTime,i.Creation.dwLowDateTime), Links=i.Links, Attributes=i.Attributes };
   }
  }
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern uint SHEmptyRecycleBin(IntPtr hwnd, string root, uint flags);
 }
}
'@ -ErrorAction Stop
}
function Get-SjcFileIdentity {
    param([string]$Path)
    Initialize-SjcNative
    $id = [SjcV3.Native]::ReadIdentity((Get-SjcFullPath $Path))
    if ($id.Links -ne 1 -or ($id.Attributes -band 0x410) -ne 0) { throw '拒绝目录、重解析点或多硬链接文件。' }
    return $id.Key
}
function Set-SjcPrivateDirectory {
    param([string]$Path)
    if (-not (Test-SjcNoReparsePath $Path -AllowMissing)) { throw '状态目录祖先不安全。' }
    [void][IO.Directory]::CreateDirectory($Path)
    if (-not (Test-SjcNoReparsePath $Path)) { throw '状态目录不安全。' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true,$false)
    foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new($principal, [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit', [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        [void]$acl.AddAccessRule($rule)
    }
    [IO.Directory]::SetAccessControl($Path,$acl)
}
function Assert-SjcPrivateDirectory {
    param([string]$Path)
    if (-not (Test-SjcNoReparsePath $Path)) { throw '私有目录缺失或包含重解析点。' }
    $acl = [IO.Directory]::GetAccessControl($Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -ne $sid -or -not $acl.AreAccessRulesProtected) { throw '任务目录所有者/继承不符合私有目录约束。' }
    foreach ($entry in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])) {
        if ($entry.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and $entry.IdentityReference.Value -notin @($sid,'S-1-5-18')) { throw '私有目录存在额外授权。' }
    }
}
function Protect-SjcText {
    param([string]$Text)
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('SafeJunkCleaner-v3-seal'),[Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function Unprotect-SjcText {
    param([string]$Text)
    Add-Type -AssemblyName System.Security -ErrorAction Stop
    return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Text),[Text.Encoding]::UTF8.GetBytes('SafeJunkCleaner-v3-seal'),[Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function Read-SjcSafeText {
    param([string]$Path,[int64]$MaximumBytes=4194304)
    if (-not (Test-SjcNoReparsePath $Path)) { throw '文本通道缺失或包含重解析点。' }
    [void](Get-SjcFileIdentity $Path)
    $stream = [IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaximumBytes) { throw '文本通道超过限制。' }
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}
function Write-SjcAtomicText {
    param([string]$Path,[string]$Text,[switch]$NoOverwrite)
    $Path = Get-SjcFullPath $Path
    $parent = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-SjcNoReparsePath $parent)) { throw '输出通道祖先不安全。' }
    if ([IO.File]::Exists($Path)) { [void](Get-SjcFileIdentity $Path) }
    elseif ([IO.Directory]::Exists($Path)) { throw '输出通道是目录。' }
    $temp = Join-Path $parent ('.write-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $stream = [IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $bytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($Text)
        $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true)
    } finally { $stream.Dispose() }
    try {
        if (-not (Test-SjcNoReparsePath $parent)) { throw '输出目录在写入期间发生变化。' }
        if ([IO.File]::Exists($Path)) {
            if ($NoOverwrite) { throw '不允许覆盖封存文件。' }
            [void](Get-SjcFileIdentity $Path)
            # PS5.1 converts a null string argument to an empty backup path.
            $backup=Join-Path $parent ('.backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
            try { [IO.File]::Replace($temp,$Path,$backup) }
            finally { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } }
        } else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Get-SjcProductionStateRoot {
    return (Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'SafeJunkCleaner\v3')
}
function Get-SjcRegistry {
    if (-not (Get-Variable -Scope Script -Name SjcContexts -ErrorAction SilentlyContinue)) { $script:SjcContexts = New-Object 'System.Collections.Generic.List[object]' }
    return ,$script:SjcContexts
}
function Get-SjcContextConfiguration {
    param($Context)
    foreach ($entry in (Get-SjcRegistry)) {
        if ([object]::ReferenceEquals($entry.Context,$Context)) {
            if ($entry.IsTest) { Assert-SjcSandbox $entry.TestRoot }
            return $entry
        }
    }
    throw '上下文不是本实现创建的可信上下文。'
}
function New-SjcContext {
    param([string]$TestRoot)
    $isTest = -not [string]::IsNullOrWhiteSpace($TestRoot)
    if ($isTest) { $TestRoot=Get-SjcFullPath $TestRoot; Assert-SjcSandbox $TestRoot; $state = Join-Path $TestRoot 'state' }
    else { $state = Get-SjcProductionStateRoot }
    Set-SjcPrivateDirectory $state
    $context = [pscustomobject]@{ Version=(Get-SjcVersion); StateRoot=$state; Rules=@() }
    $configuration = [pscustomobject]@{ Context=$context; StateRoot=$state; IsTest=$isTest; TestRoot=$TestRoot }
    [void](Get-SjcRegistry).Add($configuration)
    $context.Rules = @(Get-SjcRules -Context $context)
    return $context
}
function New-SjcTestSandbox {
    $parent = Join-Path (Get-SjcProductionStateRoot) 'Sandboxes'
    Set-SjcPrivateDirectory $parent
    $root = Join-Path $parent ([guid]::NewGuid().ToString('D'))
    Set-SjcPrivateDirectory $root
    $token = [guid]::NewGuid().ToString('N')
    if (-not (Get-Variable -Scope Script -Name SjcSandboxes -ErrorAction SilentlyContinue)) { $script:SjcSandboxes=@{} }
    $script:SjcSandboxes[$root]=$token
    Write-SjcAtomicText -Path (Join-Path $root '.sandbox-owner') -Text (Protect-SjcText ($root + '|' + $token)) -NoOverwrite
    Set-SjcPrivateDirectory (Join-Path $root 'files')
    return [pscustomobject]@{ Root=$root; Context=(New-SjcContext -TestRoot $root) }
}
function Assert-SjcSandbox {
    param([string]$Root)
    $Root = Get-SjcFullPath $Root
    if (-not (Get-Variable -Scope Script -Name SjcSandboxes -ErrorAction SilentlyContinue) -or -not $script:SjcSandboxes.ContainsKey($Root)) { throw 'TestRoot 必须是本进程自建并注册的 GUID 沙箱。' }
    Assert-SjcPrivateDirectory $Root
    $owner = Unprotect-SjcText (Read-SjcSafeText (Join-Path $Root '.sandbox-owner'))
    if ($owner -cne ($Root + '|' + $script:SjcSandboxes[$Root])) { throw '沙箱所有权标记无效。' }
}
function New-SjcTaskDirectory {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration=Get-SjcContextConfiguration $Context
    $parent=Join-Path $configuration.StateRoot 'Tasks'
    Set-SjcPrivateDirectory $parent
    $id=[guid]::NewGuid().ToString('D'); $path=Join-Path $parent $id
    Set-SjcPrivateDirectory $path
    $owner=[ordered]@{ Version=(Get-SjcVersion); SchemaVersion=(Get-SjcPlanSchemaVersion); TaskId=$id; Path=$path; StateRoot=$configuration.StateRoot; IsTest=$configuration.IsTest; Nonce=[guid]::NewGuid().ToString('N') }
    Write-SjcAtomicText -Path (Join-Path $path '.task-owner') -Text (Protect-SjcText ($owner | ConvertTo-Json -Compress)) -NoOverwrite
    return $path
}
function Assert-SjcTaskDirectory {
    param($Context,[string]$TaskDirectory)
    $configuration=Get-SjcContextConfiguration $Context
    $path=Get-SjcFullPath $TaskDirectory
    $id=[IO.Path]::GetFileName($path)
    $guid=[guid]::Empty
    if (-not [guid]::TryParseExact($id,'D',[ref]$guid)) { throw '任务名必须是GUID。' }
    $expected=Join-Path (Join-Path $configuration.StateRoot 'Tasks') $id
    if (-not $path.Equals($expected,[StringComparison]::OrdinalIgnoreCase)) { throw '任务目录不属于当前状态根。' }
    Assert-SjcPrivateDirectory $path
    $owner=Unprotect-SjcText (Read-SjcSafeText (Join-Path $path '.task-owner')) | ConvertFrom-Json -ErrorAction Stop
    if ($owner.Version -cne (Get-SjcVersion) -or -not $owner.PSObject.Properties['SchemaVersion'] -or $owner.SchemaVersion -ne (Get-SjcPlanSchemaVersion) -or $owner.TaskId -cne $id -or $owner.Path -cne $path -or $owner.StateRoot -cne $configuration.StateRoot -or $owner.IsTest -isnot [bool] -or $owner.IsTest -ne $configuration.IsTest) { throw '任务所有权标记不匹配。' }
    return $path
}
function Assert-SjcChannel {
    param([string]$TaskDirectory,[string]$Path,[switch]$Optional)
    if ([string]::IsNullOrWhiteSpace($Path)) { if ($Optional) { return '' }; throw '缺少任务通道。' }
    $full=Get-SjcFullPath $Path
    if (-not ([IO.Path]::GetDirectoryName($full)).Equals($TaskDirectory,[StringComparison]::OrdinalIgnoreCase)) { throw '通道必须位于任务目录直接子层。' }
    $leaf=[IO.Path]::GetFileName($full)
    if ($leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$' -or $leaf -match '^(?i:candidates\.jsonl|scan\.meta\.json|clean\.claimed|core\.active|worker\.active|task\.completed|clean\.lock|task\.deleting|\.task-owner)$' -or $leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw '通道名称保留或无效。' }
    if (-not (Test-SjcNoReparsePath $full -AllowMissing)) { throw '通道包含链接或不安全祖先。' }
    if ([IO.File]::Exists($full)) { [void](Get-SjcFileIdentity $full) }
    elseif ([IO.Directory]::Exists($full)) { throw '通道不是普通文件。' }
    return $full
}
function Assert-SjcDistinctChannels {
    param([string[]]$Paths)
    $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $Paths) { if ($path -and -not $seen.Add($path)) { throw '任务通道不能重叠。' } }
}
function Assert-SjcStringArray {
    param($Value,[string]$Name,[int]$Maximum=1000000,[int]$MaximumStringLength=256)
    if ($null -eq $Value -or $Value -is [string] -or $Value -isnot [System.Collections.IList]) { throw ($Name + ' 必须为字符串数组。') }
    if ($Value.Count -gt $Maximum) { throw ($Name + ' 超出数量限制。') }
    foreach ($item in $Value) { if ($item -isnot [string] -or [string]::IsNullOrWhiteSpace($item) -or $item.Length -gt $MaximumStringLength) { throw ($Name + ' 含无效字符串。') } }
}
function Read-SjcPreferences {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration=Get-SjcContextConfiguration $Context
    $path=Join-Path $configuration.StateRoot 'preferences-v3.json'
    if (-not [IO.File]::Exists($path)) { return $null }
    $value=Read-SjcSafeText $path | ConvertFrom-Json -ErrorAction Stop
    Assert-SjcPreferences $Context $value
    return [pscustomobject]@{ RecycleMode=$value.RecycleMode; SelectedRuleIds=@($value.SelectedRuleIds) }
}
function Assert-SjcPreferences {
    param($Context,$Preferences)
    if ($null -eq $Preferences -or $Preferences.RecycleMode -isnot [bool]) { throw 'RecycleMode 必须为布尔值。' }
    Assert-SjcStringArray $Preferences.SelectedRuleIds 'SelectedRuleIds' 10000
    $properties=@($Preferences.PSObject.Properties.Name)
    if (@($properties | Where-Object { $_ -notin @('RecycleMode','SelectedRuleIds') }).Count -gt 0) { throw '首选项包含未知字段。' }
    $known=@{}; foreach($rule in @(Get-SjcRules $Context)) { $known[$rule.Id]=$true }
    $seen=@{}
    foreach($id in $Preferences.SelectedRuleIds) { if (-not $known.ContainsKey($id) -or $seen.ContainsKey($id)) { throw '首选项包含未知或重复规则。' }; $seen[$id]=$true }
}
function Save-SjcPreferences {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)]$Preferences)
    $configuration=Get-SjcContextConfiguration $Context
    Assert-SjcPreferences $Context $Preferences
    Write-SjcAtomicText -Path (Join-Path $configuration.StateRoot 'preferences-v3.json') -Text ($Preferences | ConvertTo-Json -Depth 4 -Compress)
    return $true
}
function Get-SjcRuleSeal {
    param($Rule)
    return ([pscustomobject][ordered]@{ Id=$Rule.Id; TemplateId=$Rule.TemplateId; Root=(Get-SjcFullPath $Rule.Root); Patterns=@($Rule.Patterns); ExcludePatterns=@($Rule.ExcludePatterns); MinimumAgeHours=$Rule.MinimumAgeHours; RequiresClosedProcess=@($Rule.RequiresClosedProcess) } | ConvertTo-Json -Depth 5 -Compress)
}
function Get-SjcSelectedRules {
    param($Context,[string[]]$RuleIds)
    if (@($RuleIds).Count -eq 0) { throw '没有选择规则。' }
    $rules=@{}; foreach($rule in @(Get-SjcRules $Context)) { if ($rules.ContainsKey($rule.Id)) { throw '规则实例ID冲突。' }; $rules[$rule.Id]=$rule }
    $seen=@{}
    foreach($id in $RuleIds) {
        if (-not $rules.ContainsKey($id) -or $seen.ContainsKey($id)) { throw ('未知或重复规则：' + $id) }
        $seen[$id]=$true; $rules[$id]
    }
}
function Test-SjcProcessesClosed {
    param($Rule)
    if (@($Rule.RequiresClosedProcess).Count -eq 0) { return $true }
    foreach($name in @($Rule.RequiresClosedProcess)) {
        $processes=[Diagnostics.Process]::GetProcessesByName($name)
        try { if ($processes.Length -gt 0) { return $false } }
        finally { foreach($process in $processes) { $process.Dispose() } }
    }
    return $true
}
function Test-SjcRuleFile {
    param($Rule,[IO.FileInfo]$File,[datetime]$NowUtc)
    if (-not (Test-SjcPathWithin $File.FullName $Rule.Root)) { return $false }
    if (($File.Attributes -band ([IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReparsePoint)) -ne 0) { return $false }
    # Never treat offline web data, Office sync data, Maven repository or WAL/SHM
    # as generic cleanup material, even if a nested copy appears under Temp.
    if ($File.FullName -match '(?i)\\(?:OfficeFileCache|Service Worker|CacheStorage)\\' -or $File.FullName -match '(?i)\\\.m2\\repository(?:\\|$)') { return $false }
    if ($File.Name -match '(?i)(?:-wal|-shm|\.wal|\.shm)$') { return $false }
    $matched=$false
    foreach($pattern in @($Rule.Patterns)) { if ($File.Name -like $pattern) { $matched=$true; break } }
    if (-not $matched) { return $false }
    foreach($pattern in @($Rule.ExcludePatterns)) { if ($File.Name -like $pattern) { return $false } }
    if ($File.LastWriteTimeUtc -gt $NowUtc.AddHours(-[double]$Rule.MinimumAgeHours)) { return $false }
    return $true
}
function New-SjcOperationLog {
    param($Context,[string]$Operation)
    $configuration=Get-SjcContextConfiguration $Context
    $root=Join-Path $configuration.StateRoot 'Logs'; Set-SjcPrivateDirectory $root
    $path=Join-Path $root ($Operation + '-' + [guid]::NewGuid().ToString('D') + '.json')
    Write-SjcAtomicText -Path $path -Text ('{"Operation":"' + $Operation + '","Status":"Running"}') -NoOverwrite
    return $path
}
function Complete-SjcOperationLog {
    param($Result)
    try { Write-SjcAtomicText -Path $Result.LogPath -Text ($Result | ConvertTo-Json -Depth 10 -Compress) }
    catch { $Result.Status='Failed'; $Result.Error='日志写入失败：' + $_.Exception.Message }
}
function Add-SjcWarning {
    param($Result,[string]$Message)
    $Result.WarningCount++
    if ($Result.Warnings.Count -lt 200) { [void]$Result.Warnings.Add($Message) }
}
function Add-SjcCleanError {
    param($Result,[string]$Message)
    $Result.ErrorCount++
    if ($Result.Errors.Count -lt 200) { [void]$Result.Errors.Add($Message) }
}
function Test-SjcCancelled {
    param([string]$CancelPath)
    if (-not $CancelPath) { return $false }
    if (-not (Test-SjcNoReparsePath $CancelPath -AllowMissing)) { throw '取消通道不安全。' }
    if ([IO.Directory]::Exists($CancelPath)) { throw '取消通道是目录。' }
    if ([IO.File]::Exists($CancelPath)) { [void](Get-SjcFileIdentity $CancelPath); return $true }
    return $false
}
function Write-SjcProgress {
    param([string]$Path,[string]$Text,[int64]$Reviewed,[int64]$CandidateCount,$Clock,[switch]$Force)
    if (-not $Path) { return }
    if (-not $Force -and $Clock.ElapsedMilliseconds -lt 250) { return }
    Write-SjcAtomicText -Path $Path -Text ([ordered]@{Text=$Text; Reviewed=$Reviewed; CandidateCount=$CandidateCount; UpdatedUtc=[datetime]::UtcNow.ToString('o')} | ConvertTo-Json -Compress)
    $Clock.Restart()
}
function Get-SjcStreamHash {
    param([IO.Stream]$Stream)
    $Stream.Position=0; $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose(); $Stream.Position=0 }
}

function Invoke-SjcScan {
    param([Parameter(Mandatory=$true)]$Context,[string[]]$RuleIds,[string]$TaskDirectory,[string]$CancelPath,[string]$ProgressPath)
    $result=[pscustomobject][ordered]@{ Version=(Get-SjcVersion); TaskId=''; Status='Failed'; Categories=@(); CandidateCount=[int64]0; CandidateBytes=[int64]0; PlanPath=''; LogPath=''; WarningCount=0; Warnings=(New-Object 'System.Collections.Generic.List[string]'); Error='' }
    $writer=$null; $stream=$null; $lease=$null
    try {
        $result.LogPath=New-SjcOperationLog $Context 'scan'
        $task=Assert-SjcTaskDirectory $Context $TaskDirectory; $result.TaskId=[IO.Path]::GetFileName($task)
        $lease=Open-SjcTaskLease $task 'core.active'
        $cancel=Assert-SjcChannel $task $CancelPath -Optional; $progress=Assert-SjcChannel $task $ProgressPath -Optional
        Assert-SjcDistinctChannels @($cancel,$progress)
        if ([IO.File]::Exists((Join-Path $task 'scan.meta.json')) -or [IO.File]::Exists((Join-Path $task 'candidates.jsonl'))) { throw '任务已含扫描计划，请创建新任务。' }
        $rules=@(Get-SjcSelectedRules $Context $RuleIds)
        $categories=New-Object 'System.Collections.Generic.List[object]'; $groups=@{}
        foreach($rule in $rules) {
            $cat=[pscustomobject]@{RuleId=$rule.Id; Name=$rule.Name; Group=$rule.Group; Risk=$rule.Risk; Root=$rule.Root; Count=[int64]0; Bytes=[int64]0; Status='Pending'; Note=$rule.Note}
            [void]$categories.Add($cat)
            try {
                if (-not (Test-SjcNoReparsePath $rule.Root -AllowMissing)) { throw '规则根或任一祖先不安全/无权限。' }
                if (-not [IO.Directory]::Exists($rule.Root)) {
                    # Attributes distinguishes missing from access denied and from a file at the root.
                    try { [void][IO.File]::GetAttributes($rule.Root); throw '规则根不是目录。' }
                    catch [IO.DirectoryNotFoundException] { $cat.Status='Missing'; continue }
                    catch [IO.FileNotFoundException] { $cat.Status='Missing'; continue }
                }
                if (-not (Test-SjcProcessesClosed $rule)) { $cat.Status='RunningProcess'; $cat.Note='要求相关应用全部关闭；本次未扫描。'; continue }
                $cat.Status='Success'; $root=Get-SjcFullPath $rule.Root
                if (-not $groups.ContainsKey($root)) { $groups[$root]=New-Object 'System.Collections.Generic.List[object]' }
                [void]$groups[$root].Add([pscustomobject]@{Rule=$rule; Category=$cat})
            } catch { $cat.Status='Failed'; $cat.Note=$_.Exception.Message; Add-SjcWarning $result ($rule.Id + ': ' + $_.Exception.Message) }
        }
        $result.Categories=@($categories.ToArray())
        $plan=Join-Path $task 'candidates.jsonl'
        $stream=[IO.File]::Open($plan,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),4096,$true)
        $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $clock=[Diagnostics.Stopwatch]::StartNew(); $cancelled=$false; $now=[datetime]::UtcNow
        foreach($root in @($groups.Keys | Sort-Object)) {
            $queue=New-Object 'System.Collections.Generic.Queue[string]'; $queue.Enqueue($root)
            while($queue.Count -gt 0) {
                if (Test-SjcCancelled $cancel) { $cancelled=$true; break }
                $folder=$queue.Dequeue()
                try {
                    if (-not (Test-SjcNoReparsePath $folder)) { throw '目录或祖先包含链接/不可读。' }
                    $directory=[IO.DirectoryInfo]::new($folder)
                    foreach($entry in $directory.EnumerateFileSystemInfos()) {
                        if (Test-SjcCancelled $cancel) { $cancelled=$true; break }
                        try {
                            $path=Get-SjcFullPath $entry.FullName
                            if (-not (Test-SjcPathWithin $path $root)) { throw '枚举路径越界。' }
                            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '跳过重解析条目。' }
                            if ($entry -is [IO.DirectoryInfo]) { $queue.Enqueue($path); continue }
                            if ($entry -isnot [IO.FileInfo]) { continue }
                            foreach($pair in $groups[$root]) {
                                if (-not (Test-SjcRuleFile $pair.Rule $entry $now)) { continue }
                                if ($seen.Contains($path)) { break }
                                if (-not (Test-SjcNoReparsePath $path)) { throw '候选全祖先检查失败。' }
                                $identity=Get-SjcFileIdentity $path
                                $entry.Refresh()
                                if (-not (Test-SjcRuleFile $pair.Rule $entry $now)) { continue }
                                $candidate=[ordered]@{ Id=([guid]::NewGuid().ToString('N')); RuleId=$pair.Rule.Id; Path=$path; Length=[int64]$entry.Length; LastWriteUtc=$entry.LastWriteTimeUtc.ToString('o'); FileIdentity=$identity }
                                $writer.WriteLine(($candidate | ConvertTo-Json -Compress)); [void]$seen.Add($path)
                                $pair.Category.Count++; $pair.Category.Bytes += [int64]$entry.Length
                                $result.CandidateCount++; $result.CandidateBytes += [int64]$entry.Length
                                break
                            }
                        } catch {
                            Add-SjcWarning $result ($entry.FullName + ': ' + $_.Exception.Message)
                            foreach($pair in $groups[$root]) { $pair.Category.Status='Partial' }
                        }
                        Write-SjcProgress $progress '正在扫描候选（未删除文件）' 0 $result.CandidateCount $clock
                    }
                } catch {
                    Add-SjcWarning $result ($folder + ': ' + $_.Exception.Message)
                    foreach($pair in $groups[$root]) { $pair.Category.Status='Partial' }
                }
                if ($cancelled) { break }
            }
            if ($cancelled) { break }
        }
        if ($cancelled) { $result.Status='Cancelled'; foreach($cat in $categories) { if ($cat.Status -in @('Success','Pending')) { $cat.Status='Cancelled' } } }
        elseif (@($categories | Where-Object { $_.Status -in @('Partial','Failed','RunningProcess') }).Count -gt 0) { $result.Status='Partial' }
        else { $result.Status='Success' }
        $writer.Flush(); $stream.Flush($true)
        $hash=Get-SjcStreamHash $stream
        $configuration=Get-SjcContextConfiguration $Context
        $meta=[ordered]@{ Version=(Get-SjcVersion); SchemaVersion=(Get-SjcPlanSchemaVersion); TaskId=$result.TaskId; TaskDirectory=$task; IsTest=$configuration.IsTest; Status=$result.Status; CreatedUtc=[datetime]::UtcNow.ToString('o'); PlanFile='candidates.jsonl'; PlanHash=$hash; PlanLength=$stream.Length; CandidateCount=$result.CandidateCount; CandidateBytes=$result.CandidateBytes; Rules=@($rules | ForEach-Object { Get-SjcRuleSeal $_ }) }
        Write-SjcAtomicText -Path (Join-Path $task 'scan.meta.json') -Text (Protect-SjcText ($meta | ConvertTo-Json -Depth 8 -Compress)) -NoOverwrite
        $result.PlanPath=$plan
        Write-SjcProgress $progress '扫描结束' 0 $result.CandidateCount $clock -Force
    } catch { $result.Status='Failed'; $result.Error=$_.Exception.Message }
    finally { if ($null -ne $writer) { $writer.Dispose() }; if ($null -ne $stream) { $stream.Dispose() }; if ($lease) { $lease.Dispose() } }
    if (-not $result.LogPath) { $result.Status='Failed'; if (-not $result.Error) { $result.Error='未能创建操作日志。' } }
    else { Complete-SjcOperationLog $result }
    return $result
}

function Get-SjcPlanContext {
    param([string]$TaskDirectory)
    $task=Get-SjcFullPath $TaskDirectory
    foreach($configuration in (Get-SjcRegistry)) {
        if (Test-SjcPathWithin $task (Join-Path $configuration.StateRoot 'Tasks')) { return $configuration.Context }
    }
    # GUI page/export may occur in a fresh process, but only production-owned tasks survive it.
    $context=New-SjcContext
    [void](Assert-SjcTaskDirectory $context $task)
    return $context
}
function Open-SjcPlan {
    param($Context,[string]$TaskDirectory)
    $task=Assert-SjcTaskDirectory $Context $TaskDirectory
    $path=Join-Path $task 'candidates.jsonl'; $metaPath=Join-Path $task 'scan.meta.json'
    $meta=Unprotect-SjcText (Read-SjcSafeText $metaPath) | ConvertFrom-Json -ErrorAction Stop
    $configuration=Get-SjcContextConfiguration $Context
    if ($meta.Version -cne (Get-SjcVersion) -or -not $meta.PSObject.Properties['SchemaVersion'] -or $meta.SchemaVersion -ne (Get-SjcPlanSchemaVersion) -or $meta.TaskId -cne [IO.Path]::GetFileName($task) -or $meta.TaskDirectory -cne $task -or $meta.IsTest -isnot [bool] -or $meta.IsTest -ne $configuration.IsTest -or $meta.PlanFile -cne 'candidates.jsonl' -or $meta.Status -notin @('Success','Partial','Cancelled')) { throw '扫描封存元信息不匹配。' }
    if (-not (Test-SjcNoReparsePath $path)) { throw '计划文件不安全。' }
    [void](Get-SjcFileIdentity $path)
    $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $meta.PlanLength -or (Get-SjcStreamHash $stream) -cne $meta.PlanHash) { throw '计划完整性校验失败。' }
        return [pscustomobject]@{ Stream=$stream; Metadata=$meta; TaskDirectory=$task }
    } catch { $stream.Dispose(); throw }
}
function Assert-SjcCandidate {
    param($Candidate,$RuleMap,$Ids,$Paths)
    foreach($property in @('Id','RuleId','Path','Length','LastWriteUtc','FileIdentity')) { if (-not $Candidate.PSObject.Properties[$property]) { throw ('候选缺少字段：' + $property) } }
    if ($Candidate.Id -isnot [string] -or $Candidate.Id -cnotmatch '^[a-f0-9]{32}$' -or -not $Ids.Add($Candidate.Id)) { throw '候选ID无效或重复。' }
    if ($Candidate.RuleId -isnot [string] -or -not $RuleMap.ContainsKey($Candidate.RuleId)) { throw '候选规则不属于封存审批。' }
    if ($Candidate.Path -isnot [string] -or (Get-SjcFullPath $Candidate.Path) -cne $Candidate.Path -or -not $Paths.Add($Candidate.Path)) { throw '候选路径非规范或重复。' }
    if (($Candidate.Length -isnot [long] -and $Candidate.Length -isnot [int]) -or $Candidate.Length -lt 0) { throw '候选大小无效。' }
    if ($Candidate.LastWriteUtc -isnot [string] -or $Candidate.FileIdentity -isnot [string] -or -not $Candidate.FileIdentity) { throw '候选时间/身份无效。' }
    [void][datetime]::ParseExact($Candidate.LastWriteUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    if (-not (Test-SjcPathWithin $Candidate.Path $RuleMap[$Candidate.RuleId].Root)) { throw '候选超出重新审批根。' }
}
function Get-SjcPlanRuleMap {
    param($Context,$Metadata)
    Assert-SjcStringArray $Metadata.Rules 'Rules' 10000 16384
    $rules=@{}; foreach($rule in @(Get-SjcRules $Context)) { $rules[$rule.Id]=$rule }
    $approved=@{}
    foreach($seal in $Metadata.Rules) {
        $snapshot=$seal | ConvertFrom-Json -ErrorAction Stop
        if (-not $rules.ContainsKey($snapshot.Id) -or $approved.ContainsKey($snapshot.Id) -or (Get-SjcRuleSeal $rules[$snapshot.Id]) -cne $seal) { throw '规则实例已变化或审批失败，请重新扫描。' }
        $approved[$snapshot.Id]=$rules[$snapshot.Id]
    }
    if ($approved.Count -eq 0) { throw '封存计划无审批规则。' }
    return $approved
}
function Open-SjcPreviewSession {
    param([Parameter(Mandatory=$true)][string]$PlanPath,[Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None)
    $path=Get-SjcFullPath $PlanPath
    if ([IO.Path]::GetFileName($path) -cne 'candidates.jsonl') { throw '只允许固定封存计划。' }
    $task=[IO.Path]::GetDirectoryName($path); $context=Get-SjcPlanContext $task
    $plan=Open-SjcPlan $context $task; $reader=$null
    try {
        $rules=Get-SjcPlanRuleMap $context $plan.Metadata
        $reader=[IO.StreamReader]::new($plan.Stream,[Text.UTF8Encoding]::new($false,$true),$true,65536,$true)
        $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $byRule=@{}; [int64]$count=0; [int64]$bytes=0
        while($null -ne ($line=$reader.ReadLine())) {
            $CancellationToken.ThrowIfCancellationRequested()
            $candidate=$line | ConvertFrom-Json -ErrorAction Stop
            Assert-SjcCandidate $candidate $rules $ids $paths
            if (-not $byRule.ContainsKey($candidate.RuleId)) { $byRule[$candidate.RuleId]=New-Object 'System.Collections.Generic.List[object]' }
            [void]$byRule[$candidate.RuleId].Add([pscustomobject]@{Id=$candidate.Id;Length=[int64]$candidate.Length})
            $count++; $bytes += [int64]$candidate.Length
        }
        if ($count -ne $plan.Metadata.CandidateCount -or $bytes -ne $plan.Metadata.CandidateBytes) { throw '候选汇总与封存不符。' }
        $reader.Dispose(); $reader=$null
        $offsets=New-Object 'System.Collections.Generic.List[long]'
        $plan.Stream.Position=0; $buffer=New-Object byte[] 65536; [int64]$position=0; [int64]$start=0
        while(($read=$plan.Stream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $CancellationToken.ThrowIfCancellationRequested()
            for($i=0;$i -lt $read;$i++) {
                if ($buffer[$i] -eq 10) { [void]$offsets.Add($start); $start=$position+$i+1 }
            }
            $position += $read
        }
        if ($start -lt $position) { [void]$offsets.Add($start) }
        if ($offsets.Count -ne $count) { throw '分页位置与完整候选计数不符。' }
        $session=[pscustomobject]@{Id=[guid]::NewGuid().ToString('N');PlanPath=$path;Count=$count;Bytes=$bytes;Closed=$false;Stream=$plan.Stream;Offsets=$offsets.ToArray();ByRule=$byRule;Gate=(New-Object object)}
        if (-not (Get-Variable -Scope Script -Name SjcPreviewSessions -ErrorAction SilentlyContinue)) { $script:SjcPreviewSessions=@{} }
        $script:SjcPreviewSessions[$session.Id]=$session
        return $session
    } catch { $plan.Stream.Dispose(); throw }
    finally { if ($reader) { $reader.Dispose() } }
}
function Assert-SjcPreviewSession {
    param($Session)
    if ($null -eq $Session -or -not (Get-Variable -Scope Script -Name SjcPreviewSessions -ErrorAction SilentlyContinue) -or -not $script:SjcPreviewSessions.ContainsKey($Session.Id) -or -not [object]::ReferenceEquals($Session,$script:SjcPreviewSessions[$Session.Id]) -or $Session.Closed) { throw '预览会话已关闭或不属于本进程。' }
}
function Get-SjcPreviewPage {
    param($Session,[ValidateRange(0,2147483647)][int]$Offset=0,[ValidateRange(1,1000)][int]$Limit=200)
    Assert-SjcPreviewSession $Session
    [Threading.Monitor]::Enter($Session.Gate)
    try {
        Assert-SjcPreviewSession $Session
        if ($Offset -ge $Session.Count) { return @() }
        $Session.Stream.Position=$Session.Offsets[$Offset]
        $reader=[IO.StreamReader]::new($Session.Stream,[Text.UTF8Encoding]::new($false,$true),$false,8192,$true)
        try {
            for($i=0;$i -lt $Limit -and ($Offset+$i) -lt $Session.Count;$i++) {
                $line=$reader.ReadLine()
                if ($null -eq $line) { throw '预览句柄意外截断。' }
                $line | ConvertFrom-Json -ErrorAction Stop
            }
        } finally { $reader.Dispose() }
    } finally { [Threading.Monitor]::Exit($Session.Gate) }
}
function Get-SjcPreviewRuleCandidates {
    param($Session,[string]$RuleId)
    Assert-SjcPreviewSession $Session
    if ($Session.ByRule.ContainsKey($RuleId)) { return $Session.ByRule[$RuleId].ToArray() }
    return @()
}
function Close-SjcPreviewSession {
    param($Session)
    if ($null -eq $Session -or $Session.Closed) { return }
    Assert-SjcPreviewSession $Session
    [Threading.Monitor]::Enter($Session.Gate)
    try { $Session.Stream.Dispose(); $Session.Closed=$true; $script:SjcPreviewSessions.Remove($Session.Id); $Session.ByRule.Clear(); $Session.Offsets=@() }
    finally { [Threading.Monitor]::Exit($Session.Gate) }
}
function Get-SjcCandidatePage {
    param([Parameter(Mandatory=$true)][string]$PlanPath,[ValidateRange(0,2147483647)][int]$Offset=0,[ValidateRange(1,1000)][int]$Limit=200)
    $path=Get-SjcFullPath $PlanPath
    if ([IO.Path]::GetFileName($path) -cne 'candidates.jsonl') { throw '只允许固定封存计划。' }
    $task=[IO.Path]::GetDirectoryName($path); $context=Get-SjcPlanContext $task; $plan=Open-SjcPlan $context $task
    $reader=$null
    try {
        $rules=Get-SjcPlanRuleMap $context $plan.Metadata
        $reader=[IO.StreamReader]::new($plan.Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        $items=New-Object 'System.Collections.Generic.List[object]'; [int64]$index=0; [int64]$bytes=0
        $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        while($null -ne ($line=$reader.ReadLine())) {
            $candidate=$line | ConvertFrom-Json -ErrorAction Stop
            Assert-SjcCandidate $candidate $rules $ids $paths
            if ($index -ge $Offset -and $items.Count -lt $Limit) { [void]$items.Add($candidate) }
            $index++; $bytes += [int64]$candidate.Length
        }
        if ($index -ne $plan.Metadata.CandidateCount -or $bytes -ne $plan.Metadata.CandidateBytes) { throw '候选汇总与封存不符。' }
        return $items.ToArray()
    } finally { if ($reader) { $reader.Dispose() }; $plan.Stream.Dispose() }
}
function Export-SjcCandidates {
    param([Parameter(Mandatory=$true)][string]$PlanPath,[Parameter(Mandatory=$true)][string]$Destination,[string[]]$ExcludedIds=@(),[Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None)
    $path=Get-SjcFullPath $PlanPath; $destinationPath=Get-SjcFullPath $Destination
    if ([IO.Path]::GetFileName($path) -cne 'candidates.jsonl') { throw '只允许固定封存计划。' }
    $task=[IO.Path]::GetDirectoryName($path); $context=Get-SjcPlanContext $task
    $configuration=Get-SjcContextConfiguration $context
    if (Test-SjcPathWithin $destinationPath $configuration.StateRoot -AllowRoot) { throw '导出不能覆盖内部状态或任务通道。' }
    if ([IO.File]::Exists($destinationPath) -or [IO.Directory]::Exists($destinationPath) -or -not (Test-SjcNoReparsePath ([IO.Path]::GetDirectoryName($destinationPath)))) { throw '请导出到安全目录中的新文件。' }
    $plan=Open-SjcPlan $context $task; $reader=$null; $writer=$null; $output=$null; $succeeded=$false
    $excluded=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($id in $ExcludedIds) { [void]$excluded.Add($id) }
    try {
        $rules=Get-SjcPlanRuleMap $context $plan.Metadata
        $reader=[IO.StreamReader]::new($plan.Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        $output=[IO.File]::Open($destinationPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $writer=[IO.StreamWriter]::new($output,[Text.UTF8Encoding]::new($true),4096,$true)
        $writer.WriteLine('CandidateId,RuleId,CandidatePath,CandidateLengthBytes,LastWriteUtc')
        [int64]$count=0; [int64]$bytes=0; [int64]$exported=0
        $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        while($null -ne ($line=$reader.ReadLine())) {
            $CancellationToken.ThrowIfCancellationRequested()
            $candidate=$line | ConvertFrom-Json -ErrorAction Stop; Assert-SjcCandidate $candidate $rules $ids $paths
            $count++; $bytes += [int64]$candidate.Length
            if ($excluded.Contains($candidate.Id)) { continue }
            $fields=@($candidate.Id,$candidate.RuleId,$candidate.Path,[string]$candidate.Length,$candidate.LastWriteUtc) | ForEach-Object { '"' + ([string]$_).Replace('"','""') + '"' }
            $writer.WriteLine(($fields -join ',')); $exported++
        }
        if ($count -ne $plan.Metadata.CandidateCount -or $bytes -ne $plan.Metadata.CandidateBytes) { throw '导出汇总不匹配。' }
        foreach($id in $excluded) { if (-not $ids.Contains($id)) { throw '排除项不属于本计划。' } }
        $writer.Flush(); $output.Flush($true); $succeeded=$true
        return [pscustomobject]@{ Status='Success'; Destination=$destinationPath; ExportedCount=$exported }
    } finally {
        if ($writer) { $writer.Dispose() }; if ($output) { $output.Dispose() }; if ($reader) { $reader.Dispose() }; $plan.Stream.Dispose()
        if (-not $succeeded -and [IO.File]::Exists($destinationPath) -and $null -ne $output) { [IO.File]::Delete($destinationPath) }
    }
}

function Invoke-SjcClean {
    param([Parameter(Mandatory=$true)]$Context,[string]$TaskDirectory,[string[]]$ExcludedIds=@(),[bool]$RecycleMode=$true,[string]$CancelPath,[string]$ProgressPath)
    $result=[pscustomobject][ordered]@{ Version=(Get-SjcVersion); TaskId=''; Status='Failed'; Reviewed=[int64]0; Deleted=[int64]0; ProcessedBytes=[int64]0; Skipped=[int64]0; Errors=(New-Object 'System.Collections.Generic.List[string]'); ErrorCount=0; LogPath=''; Error='' }
    $plan=$null; $reader=$null; $claim=$null; $lease=$null
    try {
        $result.LogPath=New-SjcOperationLog $Context 'clean'
        $task=Assert-SjcTaskDirectory $Context $TaskDirectory; $result.TaskId=[IO.Path]::GetFileName($task)
        $lease=Open-SjcTaskLease $task 'core.active'
        $cancel=Assert-SjcChannel $task $CancelPath -Optional; $progress=Assert-SjcChannel $task $ProgressPath -Optional
        Assert-SjcDistinctChannels @($cancel,$progress)
        $plan=Open-SjcPlan $Context $task
        if ($plan.Metadata.Status -eq 'Cancelled') { throw '取消的扫描不能清理，请重扫。' }
        $rules=Get-SjcPlanRuleMap $Context $plan.Metadata
        $excluded=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach($id in $ExcludedIds) { if (-not $excluded.Add($id)) { throw '排除ID重复。' } }
        $ids=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        $paths=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        # Validate every record and exclusion BEFORE the first destructive operation.
        $reader=[IO.StreamReader]::new($plan.Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        [int64]$count=0; [int64]$bytes=0
        while($null -ne ($line=$reader.ReadLine())) {
            if (Test-SjcCancelled $cancel) { $result.Status='Cancelled'; return $result }
            $candidate=$line | ConvertFrom-Json -ErrorAction Stop; Assert-SjcCandidate $candidate $rules $ids $paths
            $count++; $bytes += [int64]$candidate.Length
        }
        if ($count -ne $plan.Metadata.CandidateCount -or $bytes -ne $plan.Metadata.CandidateBytes) { throw '计划汇总校验失败。' }
        foreach($id in $excluded) { if (-not $ids.Contains($id)) { throw '排除项不属于本次计划。' } }
        $reader.Dispose(); $reader=$null; $plan.Stream.Position=0
        # Single-use claim persists even on cancellation/failure: no silent replay of a stale snapshot.
        $claim=[IO.File]::Open((Join-Path $task 'clean.claimed'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $claim.Dispose(); $claim=$null
        if ($RecycleMode) { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop }
        $reader=[IO.StreamReader]::new($plan.Stream,[Text.UTF8Encoding]::new($false,$true),$true,4096,$true)
        $clock=[Diagnostics.Stopwatch]::StartNew(); $cancelled=$false
        while($null -ne ($line=$reader.ReadLine())) {
            if (Test-SjcCancelled $cancel) { $cancelled=$true; break }
            $candidate=$line | ConvertFrom-Json -ErrorAction Stop; $result.Reviewed++
            if ($excluded.Contains($candidate.Id)) { $result.Skipped++; continue }
            try {
                $rule=$rules[$candidate.RuleId]; $path=$candidate.Path
                if (-not (Test-SjcNoReparsePath $path)) { throw '文件或全祖先检查失败。' }
                if (-not (Test-SjcProcessesClosed $rule)) { throw '规则要求的应用仍在运行。' }
                $file=[IO.FileInfo]::new($path); $file.Refresh()
                if (-not $file.Exists -or -not (Test-SjcRuleFile $rule $file ([datetime]::UtcNow))) { throw '文件不存在、模式或保留年龄不符合规则。' }
                if (($file.Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { throw '只读文件保留，不修改属性。' }
                $expected=[datetime]::ParseExact($candidate.LastWriteUtc,'o',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
                if ([int64]$file.Length -ne [int64]$candidate.Length -or $file.LastWriteTimeUtc.Ticks -ne $expected.Ticks) { throw '扫描后大小或修改时间已变化。' }
                if ((Get-SjcFileIdentity $path) -cne $candidate.FileIdentity) { throw '扫描后文件身份已变化。' }
                # Probe a readable, unshared handle; never change attributes/permissions to force deletion.
                $probe=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
                $probe.Dispose()
                if (-not (Test-SjcNoReparsePath $path) -or (Get-SjcFileIdentity $path) -cne $candidate.FileIdentity) { throw '删除前路径或身份复核失败。' }
                if ($RecycleMode) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path,[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) }
                else { [IO.File]::Delete($path) }
                $result.Deleted++; $result.ProcessedBytes += [int64]$candidate.Length
            } catch { $result.Skipped++; Add-SjcCleanError $result ($candidate.Path + ': ' + $_.Exception.Message) }
            Write-SjcProgress $progress '正在复核并处理封存候选（逻辑大小）' $result.Reviewed $count $clock
        }
        if ($cancelled) { $result.Status='Cancelled' }
        elseif ($result.ErrorCount -gt 0) { $result.Status='Partial' }
        else { $result.Status='Success' }
        Write-SjcProgress $progress '清理结束，需重新扫描' $result.Reviewed $count $clock -Force
    } catch { $result.Status='Failed'; $result.Error=$_.Exception.Message }
    finally {
        if ($reader) { $reader.Dispose() }; if ($plan) { $plan.Stream.Dispose() }; if ($claim) { $claim.Dispose() }; if ($lease) { $lease.Dispose() }
        if ($result.LogPath) { Complete-SjcOperationLog $result }
    }
    if (-not $result.LogPath) { $result.Status='Failed'; if (-not $result.Error) { $result.Error='未能创建操作日志。' } }
    return $result
}
function Get-SjcRecycleStatus {
    param([uint32]$Code)
    if ($Code -eq 0) { return 'Success' }
    if ($Code -eq 2147500036 -or $Code -eq 2147943623) { return 'Cancelled' }
    return 'Failed'
}
function Open-SjcTaskLease {
    param([string]$TaskDirectory,[ValidateSet('core.active','worker.active')][string]$Name)
    $path=Join-Path $TaskDirectory $Name
    if ([IO.File]::Exists($path)) { [void](Get-SjcFileIdentity $path) }
    if (-not (Test-SjcNoReparsePath $path -AllowMissing)) { throw '任务租约路径不安全。' }
    if ([IO.File]::Exists((Join-Path $TaskDirectory 'task.deleting'))) { throw '任务记录正在移除，拒绝启动。' }
    $lease=[IO.File]::Open($path,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    if ([IO.File]::Exists((Join-Path $TaskDirectory 'task.deleting'))) { $lease.Dispose(); throw '任务记录正在移除，拒绝启动。' }
    return $lease
}
function Set-SjcTaskCompleted {
    param($Context,[string]$TaskDirectory,[string]$Status)
    $task=Assert-SjcTaskDirectory $Context $TaskDirectory
    $value=[ordered]@{ TaskDirectory=$task; Status=$Status; UpdatedUtc=[datetime]::UtcNow.ToString('o') }
    Write-SjcAtomicText -Path (Join-Path $task 'task.completed') -Text (Protect-SjcText ($value | ConvertTo-Json -Compress))
}
# Explicit metadata cleanup only. Never reads/deletes candidate targets or recurses.
# It is safe to offer this after a worker exits; it refuses active core/worker leases.
function Remove-SjcTaskDirectory {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string]$TaskDirectory)
    $task=Assert-SjcTaskDirectory $Context $TaskDirectory
    $completed=Unprotect-SjcText (Read-SjcSafeText (Join-Path $task 'task.completed')) | ConvertFrom-Json -ErrorAction Stop
    if ($completed.TaskDirectory -cne $task -or $completed.Status -notin @('Success','Partial','Failed','Cancelled')) { throw '缺少已认证任务完成标记。' }
    $deletingPath=Join-Path $task 'task.deleting'
    $deleting=[IO.File]::Open($deletingPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $deleting.Dispose()
    $leases=New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach($name in @('core.active','worker.active','clean.lock')) {
            $path=Join-Path $task $name
            if ([IO.File]::Exists($path)) {
                if ($name -eq 'clean.lock') { throw '任务仍有清理锁。' }
                [void](Get-SjcFileIdentity $path)
                [void]$leases.Add([IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None))
            }
        }
        # Validate the whole finite flat directory before deleting ANY record.
        $files=@([IO.Directory]::GetFiles($task))
        if (@([IO.Directory]::GetDirectories($task)).Count -gt 0) { throw '任务目录出现未知子目录，拒绝递归删除。' }
        foreach($path in $files) {
            if (-not (Test-SjcNoReparsePath $path)) { throw '任务文件包含链接。' }
            [void](Get-SjcFileIdentity $path)
        }
    } catch {
        foreach($lease in $leases) { $lease.Dispose() }
        [IO.File]::Delete($deletingPath)
        throw
    }
    # Tombstone blocks new workers while existing leases were proved idle.
    foreach($lease in $leases) { $lease.Dispose() }
    foreach($path in $files) {
        if ([IO.Path]::GetFileName($path) -in @('.task-owner','task.deleting')) { continue }
        if (-not (Test-SjcNoReparsePath $path)) { throw '任务记录在清理前变化。' }
        [void](Get-SjcFileIdentity $path); [IO.File]::Delete($path)
    }
    [IO.File]::Delete((Join-Path $task '.task-owner'))
    [IO.File]::Delete($deletingPath)
    [IO.Directory]::Delete($task,$false)
    return $true
}
function Invoke-SjcRecycle {
    param([Parameter(Mandatory=$true)]$Context)
    $result=[pscustomobject]@{ Version=(Get-SjcVersion); Status='Failed'; Error=''; LogPath='' }
    try {
        $configuration=Get-SjcContextConfiguration $Context
        $result.LogPath=New-SjcOperationLog $Context 'recycle'
        if ($configuration.IsTest) { throw '测试上下文禁止清空真实回收站。' }
        Initialize-SjcNative
        # SHERB_NOCONFIRMATION (0x1) is intentionally NEVER set.
        $code=[SjcV3.Native]::SHEmptyRecycleBin([IntPtr]::Zero,$null,6)
        $result.Status=Get-SjcRecycleStatus $code
        if ($result.Status -eq 'Failed') { throw ('系统回收站操作返回：' + $code) }
    } catch { $result.Status='Failed'; $result.Error=$_.Exception.Message }
    if ($result.LogPath) { Complete-SjcOperationLog $result }
    return $result
}
