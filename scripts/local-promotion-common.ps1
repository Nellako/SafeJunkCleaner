#requires -Version 5.1
# 本地晋级的独立公共实现；不加载或运行待验收仓库中的脚本。
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-LpGit {
    param([string]$Repository, [string[]]$Arguments, [int[]]$AllowedExitCodes = @(0))
    $old = $ErrorActionPreference
    $oldOutputEncoding=$OutputEncoding
    $oldConsoleEncoding=[Console]::OutputEncoding
    try {
        $OutputEncoding=[Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
        $ErrorActionPreference = 'Continue'
        $output = @(& git --no-optional-locks --no-replace-objects -c core.quotepath=false -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false -c protocol.allow=never -c protocol.file.allow=always -C $Repository @Arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old; $OutputEncoding=$oldOutputEncoding; [Console]::OutputEncoding=$oldConsoleEncoding }
    if ($AllowedExitCodes -notcontains $code) { throw "git failed ($code): $($Arguments -join ' '): $($output -join '; ')" }
    return @($output | ForEach-Object { [string]$_ })
}

function Assert-LpEnvironment {
    $benign=@('GIT_EDITOR','GIT_SEQUENCE_EDITOR','GIT_PAGER','GIT_TERMINAL_PROMPT','GIT_ASKPASS','GIT_MERGE_AUTOEDIT')
    foreach ($item in @(Get-ChildItem Env: | Where-Object { $_.Name -like 'GIT_*' })) {
        if ($benign -notcontains $item.Name) { throw "Remove Git identity/config/trace environment overrides before running: $($item.Name)" }
    }
}

function Test-LpCloudPlaceholder {
    param([string]$Path)
    if (-not ('SjcLocalPromotion.NativePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace SjcLocalPromotion {
    public static class NativePath {
        [StructLayout(LayoutKind.Sequential)] struct TagInfo { public uint Attributes; public uint Tag; }
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out TagInfo info, uint bytes);
        public static bool IsCloud(string path) {
            using (var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02200000,IntPtr.Zero)) {
                if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                TagInfo info;
                if (!GetFileInformationByHandleEx(handle,9,out info,8)) throw new Win32Exception(Marshal.GetLastWin32Error());
                // IO_REPARSE_TAG_CLOUD and CLOUD_1..F only; never name-surrogate tags.
                return IsCloudTag(info.Tag);
            }
        }
        public static bool IsCloudTag(uint tag) { return (tag & 0xffff0fffU)==0x9000001aU; }
    }
}
'@
    }
    return [SjcLocalPromotion.NativePath]::IsCloud($Path)
}

function Get-LpPath {
    param([string]$Path, [switch]$Directory)
    if (-not [IO.Path]::IsPathRooted($Path) -or $Path -notmatch '^[A-Za-z]:[\\/]') { throw "Absolute local drive path required: $Path" }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    $cursor = $full
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if (((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -and -not (Test-LpCloudPlaceholder $cursor)) { throw "Reparse redirection/unknown tag rejected: $cursor" }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
    if ($Directory -and -not [IO.Directory]::Exists($full)) { throw "Directory missing: $full" }
    return $full
}

function Assert-LpSeparate {
    param([string]$Source, [string]$Target)
    if ($Source -eq $Target -or $Source.StartsWith($Target+'\',[StringComparison]::OrdinalIgnoreCase) -or $Target.StartsWith($Source+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Same or nested repositories are forbidden.' }
}

function Get-LpRepository {
    param([string]$Path, [string]$Branch, [switch]$Target)
    $root = Get-LpPath $Path -Directory
    $git = Join-Path $root '.git'
    if (-not [IO.Directory]::Exists($git)) { throw "Independent repository with .git directory required: $root" }
    $null = Get-LpPath $git -Directory
    $top = (Invoke-LpGit $root @('rev-parse','--show-toplevel')) -join ''
    if ([IO.Path]::GetFullPath($top).TrimEnd('\','/') -ne $root) { throw 'Repository root identity mismatch.' }
    $actual = (Invoke-LpGit $root @('symbolic-ref','--quiet','--short','HEAD')) -join ''
    if ($actual -cne $Branch) { throw "Expected branch $Branch, found $actual" }
    if (((Invoke-LpGit $root @('rev-parse','--is-shallow-repository')) -join '') -ne 'false') { throw 'Shallow history rejected.' }
    foreach ($marker in @('MERGE_HEAD','CHERRY_PICK_HEAD','REVERT_HEAD','REBASE_HEAD','BISECT_LOG','rebase-merge','rebase-apply','sequencer','index.lock','HEAD.lock','shallow','info\grafts','objects\info\alternates','commondir')) {
        if (Test-Path -LiteralPath (Join-Path $git $marker)) { throw "Unfinished operation or unsupported repository state: $marker" }
    }
    if (@(Invoke-LpGit $root @('for-each-ref','--format=%(refname)','refs/replace')).Count) { throw 'Replacement objects rejected.' }
    if (@(Invoke-LpGit $root @('status','--porcelain=v1','--untracked-files=all')).Count) { throw "Dirty worktree/index or untracked files: $root" }
    foreach ($line in @(Invoke-LpGit $root @('ls-files','-v'))) {
        if (-not $line.StartsWith('H ')) { throw 'Assume-unchanged, sparse/skip-worktree or unmerged index rejected.' }
    }
    foreach ($line in @(Invoke-LpGit $root @('ls-files','--stage'))) {
        if ($line -notmatch '^100(644|755) ') { throw 'Symlinks, submodules or unsupported index mode rejected.' }
    }
    $head = (Invoke-LpGit $root @('rev-parse','--verify','HEAD^{commit}')) -join ''
    $tree = (Invoke-LpGit $root @('rev-parse','HEAD^{tree}')) -join ''
    return [pscustomobject]@{ Path=$root; GitDirectory=$git; Branch=$actual; Head=$head; Tree=$tree }
}

function Assert-LpIgnoredConflicts {
    param($Source, $Target)
    $incoming=@(Invoke-LpGit $Source.Path @('ls-tree','-r','--name-only',$Source.Head))
    # 比较 ignored 叶子路径，不把无关 ignored 目录整体视为冲突。
    $ignored=@(Invoke-LpGit $Target.Path @('ls-files','--others','--ignored','--exclude-standard'))
    foreach ($path in $incoming) {
        $relative=Get-LpRelativePath $path
        $existing=Join-Path $Target.Path $relative
        if ([IO.Directory]::Exists($existing)) {
            $answer=@(Invoke-LpGit $Target.Path @('check-ignore','--',$relative) @(0,1))
            if ($answer.Count) { throw "Ignored directory conflicts with incoming file: $relative" }
        }
    }
    foreach ($entry in @($ignored | Sort-Object -Unique)) {
        $p=(Get-LpRelativePath $entry.TrimEnd('/')).TrimEnd('/')
        foreach ($path in $incoming) {
            $q=Get-LpRelativePath $path
            if ($p -eq $q -or $p.StartsWith($q+'/',[StringComparison]::OrdinalIgnoreCase) -or $q.StartsWith($p+'/',[StringComparison]::OrdinalIgnoreCase)) { throw "Ignored path conflicts with incoming tree: $p <-> $q" }
        }
    }
}

function Assert-LpHead {
    param($Repository, [string]$Expected)
    if ($Expected -notmatch '^[0-9a-f]{40}$' -or $Repository.Head -cne $Expected) { throw "Expected HEAD mismatch: $($Repository.Path); actual=$($Repository.Head)" }
}

function Get-LpHash {
    param([string]$Path)
    $full = Get-LpPath $Path
    if (-not [IO.File]::Exists($full)) { throw "Evidence/input missing: $full" }
    return (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash
}

function Get-LpJson {
    param([string]$Path)
    $null = Get-LpHash $Path
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-LpRelativePath {
    param([string]$Path)
    $p = $Path.Replace('\','/')
    if ([IO.Path]::IsPathRooted($p) -or $p -match '(^|/)\.\.?(/|$)|[:\x00-\x1f"*?<>|]' -or $p.StartsWith('/') -or $p.Contains('//')) { throw "Unsafe relative input path: $Path" }
    return $p
}

function Get-LpBlobHash {
    param($Repository, [string]$Relative)
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName='git.exe'
    $info.Arguments='--no-replace-objects -C "'+$Repository.Path+'" cat-file blob "'+$Repository.Head+':'+$Relative+'"'
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$info
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        if (-not $process.Start()) { throw 'Cannot read committed blob.' }
        $err=$process.StandardError.ReadToEndAsync()
        $hash=$sha.ComputeHash($process.StandardOutput.BaseStream)
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw ('Cannot read committed blob: '+$err.GetAwaiter().GetResult()) }
        return ([BitConverter]::ToString($hash)).Replace('-','')
    } finally { $sha.Dispose(); $process.Dispose() }
}

function Get-LpSnapshot {
    param($Repository)
    $records = @()
    foreach ($path in @(Invoke-LpGit $Repository.Path @('ls-files'))) {
        $relative = Get-LpRelativePath $path
        $hash=Get-LpHash (Join-Path $Repository.Path $relative)
        if ((Get-LpBlobHash $Repository $relative) -cne $hash) { throw "Worktree bytes differ from fixed commit (including EOL/filter changes): $relative" }
        $records += [pscustomobject]@{ Path=$relative; SHA256=$hash }
    }
    if (-not $records.Count) { throw 'Empty source repository rejected.' }
    return $records
}

function Assert-LpRecordSet {
    param($Records, [string[]]$Required, [string]$Root)
    $seen = @{}
    foreach ($record in @($Records)) {
        $relative = Get-LpRelativePath ([string]$record.Path)
        if ($seen.ContainsKey($relative)) { throw "Duplicate input record: $relative" }
        $seen[$relative] = $true
        if ([string]$record.SHA256 -notmatch '^[0-9a-fA-F]{64}$' -or (Get-LpHash (Join-Path $Root $relative)) -ne $record.SHA256) { throw "Input hash mismatch: $relative" }
    }
    foreach ($path in $Required) { if (-not $seen.ContainsKey($path.Replace('\','/'))) { throw "Required input hash missing: $path" } }
}

function Assert-LpRecent {
    param([string]$Value, [int]$MaxAgeHours)
    $date = [DateTimeOffset]::Parse($Value).UtcDateTime
    $now = [datetime]::UtcNow
    if ($date -gt $now.AddMinutes(5) -or $date -lt $now.AddHours(-$MaxAgeHours)) { throw "Expired or future evidence: $Value" }
    return $date
}

function Get-LpEvidenceFacts {
    param($Repository, [string]$BuildManifestPath, [string]$SummaryPath, [string]$GuiAcceptancePath, [string]$BuildInputsPath, [int]$MaxAgeHours)
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in @($BuildManifestPath,$SummaryPath,$GuiAcceptancePath,$BuildInputsPath)) { $paths.Add((Get-LpPath $p)) }
    $manifest = Get-LpJson $BuildManifestPath
    $summary = Get-LpJson $SummaryPath
    $gui = Get-LpJson $GuiAcceptancePath
    $inputs = Get-LpJson $BuildInputsPath
    $version = Get-LpJson (Join-Path $Repository.Path 'version.json')
    if ($manifest.Version -ne $version.version -or $manifest.BuildTool.Name -ne 'ps2exe' -or $manifest.BuildTool.Version -ne '1.0.18') { throw 'Release build version/tool mismatch.' }
    $built = Assert-LpRecent $manifest.BuiltUtc $MaxAgeHours
    $started = Assert-LpRecent $summary.StartedUtc $MaxAgeHours
    $finished = Assert-LpRecent $summary.FinishedUtc $MaxAgeHours
    $accepted = Assert-LpRecent $gui.AcceptedUtc $MaxAgeHours
    $captured = Assert-LpRecent $inputs.CapturedUtc $MaxAgeHours
    if ($inputs.Schema -cne 'SafeJunkCleaner.BuildInputs.v1') { throw 'Unsupported build input capture schema.' }
    if ($started -lt $built -or $finished -lt $started -or $accepted -lt $built -or $captured -gt $built -or $inputs.SourceCommit -cne $Repository.Head -or $inputs.SourcePath -ne $Repository.Path) { throw 'Build/regression/GUI/input capture chronology or commit mismatch.' }
    if (($inputs.Sources | ConvertTo-Json -Depth 5 -Compress) -cne (@(Get-LpSnapshot $Repository) | ConvertTo-Json -Depth 5 -Compress)) { throw 'Build input snapshot differs from fixed committed source.' }
    if ($summary.Suite -ne 'SafeJunkCleaner independent regression' -or $summary.Scope -ne 'Release' -or $summary.Status -ne 'Passed' -or $summary.ExitCode -ne 0 -or $summary.Failed -ne 0 -or $summary.Blocked -ne 0 -or @($summary.CoverageGaps).Count -or @($summary.GateErrors).Count) { throw 'Complete successful Release regression required.' }
    $required = @('R01-rule-inventory','R02-browser-discovery','R03-rule-approval-seal','P01-path-guards','P02-preference-guards','P03-preview-session','S01-scan-core','S02-same-root-dedupe','S03-scan-links','C01-clean-core','C02-clean-tamper','C03-clean-error-cap','C04-cancel','C05-pagination-export','L01-logging','W01-worker-boundary','V01-version-contract','G01-gui-selftest','G02-background-preview','W02-worker-selftest','X01-exe-selftest')
    # 从固定提交的 runner AST 读取声明，不执行仓库代码；新增用例自动成为门禁。
    $tokens=$null; $parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository.Path 'tests/run_all.ps1'),[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count) { throw 'Cannot parse regression runner.' }
    $assignments=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$script:AllCases'},$true))
    if ($assignments.Count -ne 1) { throw 'Unsupported regression case declaration; update promotion adapter.' }
    $declared=@()
    foreach ($table in @($assignments[0].Right.FindAll({param($node) $node -is [Management.Automation.Language.HashtableAst]},$true))) {
        $ids=@($table.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -ceq 'Id' })
        if ($ids.Count -ne 1) { throw 'Unsupported regression case table.' }
        $declared += [string]$ids[0].Item2.SafeGetValue()
    }
    foreach ($id in $required) { if ($declared -cnotcontains $id) { throw "Baseline Release case removed: $id" } }
    if (@($declared | Sort-Object -Unique).Count -ne $declared.Count) { throw 'Duplicate regression declarations.' }
    $required=$declared
    $total = 0
    foreach ($id in $required) {
        $matches = @($summary.Results | Where-Object { $_.Id -ceq $id })
        if ($matches.Count -ne 1) { throw "Missing/duplicate Release case: $id" }
        $r = $matches[0]
        if ($r.Status -ne 'Passed' -or $r.Assertions -le 0 -or $r.Failed -ne 0 -or $r.Passed -ne $r.Assertions -or $r.ExitCode -ne 0 -or $r.TimedOut -isnot [bool] -or $r.TimedOut -or @($r.CoverageGaps).Count) { throw "Invalid Release case: $id" }
        $detail = Get-LpJson $r.ResultPath
        if ($detail.Status -ne 'Passed' -or $detail.Assertions -ne $r.Assertions -or $detail.Passed -ne $r.Passed -or $detail.Failed -ne 0 -or @($detail.CoverageGaps).Count) { throw "Case detail mismatch: $id" }
        foreach ($p in @($r.ResultPath,$r.Stdout,$r.Stderr)) { $paths.Add((Get-LpPath $p)) }
        $total += [int]$r.Assertions
    }
    if (@($summary.Results).Count -ne $required.Count -or $summary.Cases -ne $required.Count -or $summary.Passed -ne $required.Count -or $summary.Assertions -ne $total) { throw 'Release totals mismatch.' }
    $sources = @('src/Main.ps1','src/Version.ps1','src/Rules.ps1','src/Core.ps1','src/Worker.ps1','src/Gui.ps1','version.json')
    Assert-LpRecordSet $manifest.Sources ($sources + @('scripts/build.ps1','assets/app.ico')) $Repository.Path
    # 构建清单之外仍保存构建前全仓指纹，不能事后猜测验收时的未提交状态。
    Assert-LpRecordSet $inputs.Sources ($sources + @('scripts/build.ps1','assets/app.ico')) $Repository.Path
    $testInputs = @($sources + 'scripts/build.ps1' + @(Invoke-LpGit $Repository.Path @('ls-files','tests/*.ps1','tests/**/*.ps1')))
    # runner 的 SourceHashes 也包含 EXE（可能是仓库外绝对路径）。
    $relativeRecords = @()
    foreach ($r in @($summary.SourceHashes)) {
        if ([IO.Path]::IsPathRooted([string]$r.Path)) {
            if ((Get-LpPath $r.Path) -ne (Get-LpPath $summary.Exe.Path) -or (Get-LpHash $r.Path) -ne $r.SHA256) { throw 'Unexpected absolute regression input.' }
        } else { $relativeRecords += $r }
    }
    Assert-LpRecordSet $relativeRecords $testInputs $Repository.Path
    $exe = @($manifest.Files | Where-Object { $_.Name -like '*.exe' })
    if ($exe.Count -ne 1 -or @($manifest.Files).Count -lt 2) { throw 'EXE and script build artifacts required.' }
    $names = @{}
    foreach ($r in @($manifest.Files)) {
        if ([IO.Path]::GetFileName([string]$r.Name) -cne [string]$r.Name -or $names.ContainsKey([string]$r.Name)) { throw 'Invalid/duplicate build artifact name.' }
        $names[[string]$r.Name] = $true
        $p = Join-Path (Split-Path -Parent $BuildManifestPath) $r.Name
        if ((Get-LpHash $p) -ne $r.SHA256 -or ([IO.FileInfo]$p).Length -ne $r.Bytes) { throw 'Build artifact hash/length mismatch.' }
        $paths.Add($p)
    }
    if ((Get-LpHash $summary.Exe.Path) -ne $exe[0].SHA256 -or $summary.Exe.SHA256 -ne $exe[0].SHA256) { throw 'Tested EXE differs from build.' }
    $paths.Add((Get-LpPath $summary.Exe.Path))
    if ($gui.Status -ne 'Passed' -or $gui.GuiSourceSHA256 -ne (Get-LpHash (Join-Path $Repository.Path 'src/Gui.ps1')) -or $gui.IconSHA256 -ne (Get-LpHash (Join-Path $Repository.Path 'assets/app.ico'))) { throw 'GUI acceptance source/icon mismatch.' }
    foreach ($name in @('DesktopWindowObserved','RuleSelectionObserved','CandidatePagingAndKeepRestore','NoProductionDeletion','WhiteBackgroundIconObserved','CompactLayoutObserved','CleaningProfileConfirmationObserved')) {
        if (@($gui.Checks | Where-Object { $_.Name -ceq $name -and $_.Passed -is [bool] -and $_.Passed }).Count -ne 1) { throw "Missing actual desktop acceptance: $name" }
    }
    foreach ($check in @($gui.Checks)) { if ($check.Passed -isnot [bool] -or -not $check.Passed) { throw 'Failed/invalid GUI check.' } }
    if (-not @($gui.EvidenceFiles).Count) { throw 'Saved GUI evidence required.' }
    foreach ($p in @($gui.EvidenceFiles)) { $paths.Add((Get-LpPath $p)) }
    $files = @($paths | Sort-Object -Unique | ForEach-Object { [pscustomobject]@{Path=$_;SHA256=(Get-LpHash $_)} })
    return [pscustomobject]@{ Files=$files; OldestUtc=(@($built,$started,$finished,$accepted,$captured) | Sort-Object | Select-Object -First 1).ToString('o') }
}

function Test-LpEnvelope {
    param($Repository, [string]$EvidencePath, [int]$MaxAgeHours)
    $e = Get-LpJson $EvidencePath
    if ($e.Schema -cne 'SafeJunkCleaner.LocalPromotion.v1' -or $e.SourcePath -ne $Repository.Path -or $e.SourceGitDirectory -ne $Repository.GitDirectory -or $e.SourceBranch -cne $Repository.Branch -or $e.SourceCommit -cne $Repository.Head -or $e.SourceTree -cne $Repository.Tree) { throw 'Evidence is not bound to this source repository/commit.' }
    $null = Assert-LpRecent $e.SealedUtc $MaxAgeHours
    if ([DateTimeOffset]::Parse($e.ExpiresUtc).UtcDateTime -le [datetime]::UtcNow) { throw 'Promotion evidence expired.' }
    foreach ($r in @($e.Files)) { if ((Get-LpHash $r.Path) -ne $r.SHA256) { throw "Sealed evidence changed: $($r.Path)" } }
    $facts = Get-LpEvidenceFacts $Repository $e.BuildManifestPath $e.SummaryPath $e.GuiAcceptancePath $e.BuildInputsPath $MaxAgeHours
    if (($facts.Files | ConvertTo-Json -Depth 5 -Compress) -cne ($e.Files | ConvertTo-Json -Depth 5 -Compress)) { throw 'Evidence file set changed.' }
    $snapshot = @(Get-LpSnapshot $Repository)
    if (($snapshot | ConvertTo-Json -Depth 5 -Compress) -cne ($e.Snapshot | ConvertTo-Json -Depth 5 -Compress)) { throw 'Committed source snapshot changed since acceptance sealing.' }
    return (Get-LpHash $EvidencePath)
}

function New-LpIsolation {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('sjc-promotion-'+[guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($path)
    try { $null = Invoke-LpGit $path @('init','--bare','.'); return $path }
    catch { throw "Isolation initialization failed; inspect owned temporary path: $path. $_" }
}

function Assert-LpAncestor {
    param([string]$Isolation, $Source, $Target)
    $null = Invoke-LpGit $Isolation @('fetch','--no-tags','--no-write-fetch-head','--no-recurse-submodules','--', $Source.Path,$Source.Head)
    $null = Invoke-LpGit $Isolation @('fetch','--no-tags','--no-write-fetch-head','--no-recurse-submodules','--', $Target.Path,$Target.Head)
    $null = Invoke-LpGit $Isolation @('merge-base','--is-ancestor',$Target.Head,$Source.Head)
}
