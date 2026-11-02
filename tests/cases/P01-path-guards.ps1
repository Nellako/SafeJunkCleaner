#requires -Version 5.1
# P01: path canonicalization and containment guards (local drive only, no devices/UNC/ADS,
# dot segments, trailing space/dot), plus reparse root/ancestor rejection.
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
    $root = Join-Path $sandbox.Root 'root'
    [void][IO.Directory]::CreateDirectory($root)
    New-TestFile -Path (Join-Path $root 'a\b\old.tmp') -Bytes 100 -AgeHours 100 | Out-Null

    $drive = [IO.Path]::GetPathRoot($sandbox.Root).TrimEnd('\')
    Assert-Equal 'canonical local path keeps drive form' ($root) (Get-SjcFullPath $root)
    Assert-Equal 'trailing separators are trimmed' $root (Get-SjcFullPath ($root + '\'))
    Assert-Equal 'forward slashes are normalized' (Join-Path $root 'a\b') (Get-SjcFullPath ($root + '/a/b'))
    Assert-Equal 'duplicate separators collapse' (Join-Path $root 'a\b') (Get-SjcFullPath ($root + '\a\\b'))

    Assert-Throws 'relative path rejected' { Get-SjcFullPath 'relative\path' } '本地驱动器绝对'
    Assert-Throws 'UNC path rejected' { Get-SjcFullPath '\\server\share\file' } '本地驱动器绝对'
    Assert-Throws 'device path rejected' { Get-SjcFullPath '\\?\C:\Temp\file' } '本地驱动器绝对'
    Assert-Throws 'ADS rejected' { Get-SjcFullPath ($root + '\file.txt:stream') } 'ADS'
    Assert-Throws 'dot segment rejected' { Get-SjcFullPath ($root + '\a\.\b') } '非规范路径分段'
    Assert-Throws 'dot-dot segment rejected' { Get-SjcFullPath ($root + '\a\..\b') } '非规范路径分段'
    Assert-Throws 'trailing dot segment rejected' { Get-SjcFullPath ($root + '\a.\b') } '非规范路径分段'
    Assert-Throws 'trailing space segment rejected' { Get-SjcFullPath ($root + '\a \b') } '非规范路径分段'
    Assert-Throws 'control character rejected' { Get-SjcFullPath ($root + "\a`tb") } '本地驱动器绝对'

    $driverRoot = $drive + '\'
    Assert-True 'drive root itself canonicalizes' ($null -ne (Get-SjcFullPath $driverRoot)) $driverRoot

    Assert-True 'child is within root' (Test-SjcPathWithin (Join-Path $root 'a\b\old.tmp') $root) ''
    Assert-True 'root is not within root by default' (-not (Test-SjcPathWithin $root $root)) ''
    Assert-True 'root is within itself with AllowRoot' (Test-SjcPathWithin $root $root -AllowRoot) ''
    Assert-True 'sibling prefix is not within root' (-not (Test-SjcPathWithin ($root + '-evil\old.tmp') $root)) ''
    Assert-True 'case-insensitive containment' (Test-SjcPathWithin ((Join-Path $root 'a\b').ToUpperInvariant()) $root) ''

    $tree = Join-Path $sandbox.Root 'links'
    [void][IO.Directory]::CreateDirectory($tree)
    New-TestFile -Path (Join-Path $tree 'inside.tmp') -Bytes 32 -AgeHours 100 | Out-Null
    $outside = Join-Path $sandbox.Root 'outside'
    [void][IO.Directory]::CreateDirectory($outside)
    New-TestFile -Path (Join-Path $outside 'keep.tmp') -Bytes 32 -AgeHours 100 | Out-Null
    $link = Join-Path $tree 'junction'
    $linkCreated = $false
    try { [void](New-Item -ItemType Junction -Path $link -Target $outside -ErrorAction Stop); $linkCreated = $true }
    catch { Add-CoverageGap ('无法创建目录联接，重解析根/祖先用例未完整执行：' + $_.Exception.Message) }

    if ($linkCreated) {
        Assert-True 'plain directory has no reparse ancestor' (Test-SjcNoReparsePath $tree) $tree
        Assert-True 'junction itself is detected' (-not (Test-SjcNoReparsePath $link)) $link
        Assert-True 'child under junction is detected via ancestor' (-not (Test-SjcNoReparsePath (Join-Path $link 'keep.tmp'))) ''
        Assert-True 'missing path is rejected by default' (-not (Test-SjcNoReparsePath (Join-Path $tree 'missing.tmp'))) ''
        Assert-True 'missing path allowed with AllowMissing' (Test-SjcNoReparsePath (Join-Path $tree 'missing.tmp') -AllowMissing) ''
        Assert-True 'junction target file itself is still a plain path' (Test-SjcNoReparsePath (Join-Path $outside 'keep.tmp')) ''

        $linkTargets = @(Get-ChildItem -LiteralPath $link -Force)
        Assert-True 'junction target content was not deleted by this case' ([IO.File]::Exists((Join-Path $outside 'keep.tmp'))) (($linkTargets | ForEach-Object Name) -join ',')
    }

    $fileLinkCreated = $false
    try {
        [void](New-Item -ItemType SymbolicLink -Path (Join-Path $tree 'file-link.tmp') -Target (Join-Path $outside 'keep.tmp') -ErrorAction Stop)
        $fileLinkCreated = $true
    }
    catch {
        Add-DeclaredExclusion '文件符号链接创建需要管理员权限/开发者模式；以目录联接（同样带 ReparsePoint 属性）验证身份拒绝分支。'
    }
    if ($fileLinkCreated) {
        Assert-Throws 'file symlink is refused by identity check' { Get-SjcFileIdentity (Join-Path $tree 'file-link.tmp') } '重解析|硬链接'
    }
    else {
        $junctionAsFile = Join-Path $tree 'file-link.tmp'
        try { [void](New-Item -ItemType Junction -Path $junctionAsFile -Target $outside -ErrorAction Stop) } catch { }
        Assert-Throws 'reparse/directory entry is refused by identity check' { Get-SjcFileIdentity $junctionAsFile } '重解析|硬链接|目录'
    }

    # Hard link coverage: creating one needs no elevation and must be refused (Links>1).
    $hardLinkSource = Join-Path $tree 'hard-source.tmp'
    $hardLinkTarget = Join-Path $tree 'hard-target.tmp'
    New-TestFile -Path $hardLinkSource -Bytes 48 -AgeHours 100 | Out-Null
    $hardLinkCreated = $false
    try { [void](New-Item -ItemType HardLink -Path $hardLinkTarget -Target $hardLinkSource -ErrorAction Stop); $hardLinkCreated = $true }
    catch { Add-CoverageGap ('无法创建硬链接，多硬链接拒绝分支未验证：' + $_.Exception.Message) }
    if ($hardLinkCreated) {
        Assert-Throws 'hard link with Links>1 is refused by identity check' { Get-SjcFileIdentity $hardLinkSource } '重解析|硬链接'
        Assert-Throws 'hard link target is also refused' { Get-SjcFileIdentity $hardLinkTarget } '重解析|硬链接'
    }

    # Production task channel guard: reserved names and nesting.
    $task = New-SjcTaskDirectory -Context $sandbox.Context
    [void]$script:OwnedTaskDirectories.Add($task)
    Assert-Throws 'channel cannot be candidates.jsonl' { Assert-SjcChannel $task (Join-Path $task 'candidates.jsonl') } '保留或无效'
    Assert-Throws 'channel cannot be scan.meta.json' { Assert-SjcChannel $task (Join-Path $task 'scan.meta.json') } '保留或无效'
    Assert-Throws 'channel cannot be nested deeper' { Assert-SjcChannel $task (Join-Path $task 'sub\chan.json') } '直接子层'
    Assert-Throws 'channel cannot be outside task' { Assert-SjcChannel $task (Join-Path $sandbox.Root 'chan.json') } '直接子层'
    $taskDirChild = Join-Path $task 'dirlike'
    [void][IO.Directory]::CreateDirectory($taskDirChild)
    Assert-Throws 'channel cannot be a directory' { Assert-SjcChannel $task $taskDirChild } '不是普通文件'
    $chan = Assert-SjcChannel $task (Join-Path $task 'ok.json')
    Assert-Equal 'valid direct child channel accepted' (Join-Path $task 'ok.json') $chan
    Assert-Throws 'duplicate channels rejected' { Assert-SjcDistinctChannels @($chan, $chan.ToUpperInvariant()) } '不能重叠'
    $distinctOk = $true
    try { Assert-SjcDistinctChannels @($chan, (Join-Path $task 'other.json')) } catch { $distinctOk = $false }
    Assert-True 'distinct channels accepted' $distinctOk ''
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
