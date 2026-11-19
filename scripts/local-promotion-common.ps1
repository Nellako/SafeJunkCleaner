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
        $output = @(& git --no-optional-locks --no-replace-objects -c core.longpaths=true -c core.quotepath=false -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false -c protocol.allow=never -c protocol.file.allow=always -C $Repository @Arguments 2>&1)
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

function Test-LpNoModelVersion {
    param([string]$Version)
    # Explicit capabilities, not an open-ended promise about future versions.
    return ($Version -cin @('0.14.0','0.15.0','0.16.0','0.16.1','0.17.0'))
}
function Get-LpProductSources {
    param([string]$Version)
    $sources=@('src/Main.ps1','src/Version.ps1','src/Rules.ps1','src/Core.ps1','src/Discovery.ps1','src/Maintenance.ps1','src/Worker.ps1','src/Gui.ps1')
    if($Version -ceq '0.17.0'){ $sources+='src/QuickCleanGuiBridge.ps1' }
    if ($Version -ceq '0.13.0' -or (Test-LpNoModelVersion $Version)) { $sources += 'src/ExplorerGui.ps1' }
    return @($sources + 'version.json')
}

function Get-LpEvidenceFacts {
    param($Repository, [string]$BuildManifestPath, [string]$SummaryPath, [string]$GuiAcceptancePath, [string]$BuildInputsPath, [int]$MaxAgeHours, [string]$FinalTestResultPath)
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
    $sources = @(Get-LpProductSources $manifest.Version)
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
    if ($manifest.Version -cin @('0.13.0','0.14.0','0.15.0','0.16.0','0.16.1')) {
        $buildRoot=Split-Path -Parent $BuildManifestPath
        $setHash=Assert-LpBuildSourceTree $Repository.Path $buildRoot $manifest
        if (-not $inputs.PSObject.Properties['FinalTestResultPath']) { throw 'Component promotion evidence requires explicit final test result path.' }
        if (-not $FinalTestResultPath -or (Get-LpPath $inputs.FinalTestResultPath) -ne (Get-LpPath $FinalTestResultPath)) { throw 'Final test result path differs from the pre-build capture/sealed envelope.' }
        $final=Get-LpJson $FinalTestResultPath
        $finalFinished=Assert-LpRecent $final.FinishedUtc $MaxAgeHours
        if ($finalFinished -lt $finished -or (Get-LpPath $final.ReleaseSummaryPath) -ne (Get-LpPath $SummaryPath)) { throw 'Final test result chronology/Release summary mismatch.' }
        foreach ($r in @(Get-LpComponentFacts $buildRoot $manifest $Repository.Path)) { $paths.Add((Get-LpPath (Join-Path $buildRoot $r.Path))) }
        foreach ($r in @(Assert-LpCandidateEvidence $Repository.Path $buildRoot $manifest $setHash $FinalTestResultPath $GuiAcceptancePath $null $MaxAgeHours)) { $paths.Add($r.Path) }
        $paths.Add((Get-LpPath (Join-Path $buildRoot 'source-manifest.json')))
    }
    if ($gui.Status -ne 'Passed' -or $gui.GuiSourceSHA256 -ne (Get-LpHash (Join-Path $Repository.Path 'src/Gui.ps1')) -or $gui.IconSHA256 -ne (Get-LpHash (Join-Path $Repository.Path 'assets/app.ico'))) { throw 'GUI acceptance source/icon mismatch.' }
    foreach ($name in @('DesktopWindowObserved','RuleSelectionObserved','CandidatePagingAndKeepRestore','NoProductionDeletion','WhiteBackgroundIconObserved','CompactLayoutObserved','CleaningProfileConfirmationObserved','SingleWindowFlowObserved','ThreePresetImmediateApplyObserved','AdvancedCustomOffByDefaultObserved','DiscoveryAuthorizationCancelObserved','MaintenanceCancelObserved')) {
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
    $componentVersion=(Get-LpJson (Join-Path $Repository.Path 'version.json')).version -cin @('0.13.0','0.14.0','0.15.0','0.16.0','0.16.1')
    if ($componentVersion -and (-not $e.PSObject.Properties['FinalTestResultPath'] -or -not $e.FinalTestResultPath)) { throw 'Component sealed envelope requires FinalTestResultPath.' }
    $finalPath=if ($e.PSObject.Properties['FinalTestResultPath']) { [string]$e.FinalTestResultPath } else { $null }
    $facts = Get-LpEvidenceFacts $Repository $e.BuildManifestPath $e.SummaryPath $e.GuiAcceptancePath $e.BuildInputsPath $MaxAgeHours $finalPath
    if (($facts.Files | ConvertTo-Json -Depth 5 -Compress) -cne ($e.Files | ConvertTo-Json -Depth 5 -Compress)) { throw 'Evidence file set changed.' }
    $snapshot = @(Get-LpSnapshot $Repository)
    if (($snapshot | ConvertTo-Json -Depth 5 -Compress) -cne ($e.Snapshot | ConvertTo-Json -Depth 5 -Compress)) { throw 'Committed source snapshot changed since acceptance sealing.' }
    return (Get-LpHash $EvidencePath)
}

function Get-LpCandidateName {
    param([string]$Path)
    $p=Get-LpRelativePath $Path
    foreach ($part in $p.Split('/')) {
        if (-not $part -or $part -match '[. ]$|^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Non-canonical candidate path.' }
    }
    if ($p -cne $Path) { throw 'Candidate paths must use canonical forward slashes.' }
    return $p
}

function Get-LpCandidateFiles {
    param([string]$Root,[switch]$SourceOnly)
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($SourceOnly -and $item.Name -match '^(?i:\.git|\.zcode|artifacts|releases|private|raw[-_]?logs?|logs?|screenshots?|venv|\.venv|__pycache__|cache|\.cache|bin|obj|node_modules|TestResults)$') { continue }
        $null=Get-LpPath $item.FullName
        if ($item.PSIsContainer) { Get-LpCandidateFiles $item.FullName -SourceOnly:$SourceOnly } else { $item }
    }
}

function Get-LpSourceSetHash {
    param($Records)
    $ordered=[Collections.Generic.SortedDictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($r in @($Records)) { $p=Get-LpCandidateName $r.Path;if ($ordered.ContainsKey($p)) { throw 'Duplicate source record.' };$ordered.Add($p,$r) }
    $lines=@(foreach ($p in $ordered.Keys) { $r=$ordered[$p];$p+"`t"+([string]$r.SHA256).ToUpperInvariant()+"`t"+([long]$r.Bytes)+"`n" })
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(($lines -join ''))))).Replace('-','') } finally { $sha.Dispose() }
}

function Get-LpWorkingSources {
    param([string]$Root)
    $records=@()
    $directories=@('src','scripts','tests','docs','engine','engine-tests','tools','assets')
    $files=@(Get-ChildItem -LiteralPath $Root -Force -File)
    foreach ($directory in $directories) {
        $path=Join-Path $Root $directory
        if ([IO.Directory]::Exists($path)) { $null=Get-LpPath $path;$files += @(Get-LpCandidateFiles $path -SourceOnly) }
    }
    foreach ($file in $files) {
        $p=Get-LpCandidateName ($file.FullName.Substring($Root.Length+1).Replace('\','/'))
        $parts=$p.Split('/')
        if ($parts.Count -gt 1 -and $parts[0] -notin $directories) { continue }
        if ($p -match '(?i)(^|/)(\.git|\.zcode|artifacts|releases|private|raw[-_]?logs?|logs?|screenshots?|venv|\.venv|__pycache__|cache|\.cache|bin|obj|node_modules|TestResults)(/|$)') { continue }
        if ($p -match '(?i)\.(gguf|zip|7z|exe|dll|pdb|log|dmp|etl|pyc)$') { continue }
        if ($p -match '(?i)\.(png|jpe?g|gif|bmp|webp)$' -and $p -cne 'assets/app-icon-source.png') { continue }
        if ($parts.Count -eq 1 -and $p -notmatch '(?i)\.(md|json|ps1|sln|props|targets|config|yml|yaml)$|^(LICENSE|THIRD-PARTY-NOTICES|\.gitignore|\.gitattributes|NuGet\.Config)$') { continue }
        $records += [pscustomobject]@{Path=$p;SHA256=(Get-LpHash $file.FullName);Bytes=$file.Length}
    }
    if (-not $records.Count) { throw 'Empty working source set.' }
    return @($records | Sort-Object -Property Path -CaseSensitive)
}

function Get-LpHostProjects([string]$Root){
    'Explorer.Core','Explorer.Analysis','Explorer.Execution','Explorer.Application','Explorer.Host'
    if((Get-LpJson (Join-Path $Root 'version.json')).version -ceq '0.17.0'){'QuickClean.Host'}
}
function Get-LpHostSources {
    param([string]$Root)
    $files=@(Get-Item -LiteralPath (Join-Path $Root 'engine/Directory.Build.props'))
    foreach ($project in @(Get-LpHostProjects $Root)) {
        $projectRoot=Join-Path $Root ('engine/'+$project)
        if (-not [IO.Directory]::Exists($projectRoot)) { throw "Required product project missing: $project" }
        $files += @(Get-LpCandidateFiles $projectRoot -SourceOnly | Where-Object { $_.Extension -in @('.cs','.csproj','.json') })
    }
    return @($files | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($Root.Length+1).Replace('\','/');SHA256=(Get-LpHash $_.FullName);Bytes=$_.Length} } | Sort-Object Path -CaseSensitive)
}

function Assert-LpHostSourceProvenance {
    param($Provenance,[string]$SourceRoot)
    $actual=@(Get-LpHostSources $SourceRoot);$hash=Get-LpSourceSetHash $actual
    if ($Provenance.SourceScope -cne 'ExplorerHostComponent' -or $Provenance.SourceSetSha256 -ne $hash -or $Provenance.ComponentSourceSetSha256 -ne $hash -or @($Provenance.Sources).Count -ne $actual.Count -or (Get-LpSourceSetHash $Provenance.Sources) -ne $hash) { throw 'Host component source provenance differs from the actual five projects/shared props.' }
    Assert-LpRecordSet $Provenance.Sources @($actual.Path) $SourceRoot
    return $hash
}

function Assert-LpExactFiles {
    param([string]$Root,$Records,[string[]]$Extra=@())
    $map=@{}
    foreach ($r in @($Records)) {
        $p=Get-LpCandidateName ([string]$r.Path)
        if ($map.ContainsKey($p) -or [string]$r.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid/duplicate component record.' }
        $file=Join-Path $Root $p
        if ((Get-LpHash $file) -ne $r.SHA256) { throw "Component hash mismatch: $p" }
        if ($r.PSObject.Properties['Bytes'] -and ([IO.FileInfo]$file).Length -ne [long]$r.Bytes) { throw 'Component length mismatch.' }
        $map[$p]=$true
    }
    foreach ($p in $Extra) { if ($map.ContainsKey($p)) { throw 'Manifest must not list itself.' }; $map[$p]=$true }
    $files=@(Get-LpCandidateFiles $Root)
    foreach ($f in $files) {
        $p=Get-LpCandidateName ($f.FullName.Substring($Root.Length+1).Replace('\','/'))
        if (-not $map.ContainsKey($p)) { throw "Undeclared component file: $p" }
    }
    if ($files.Count -ne $map.Count) { throw 'Component exact file set mismatch.' }
}

function Assert-LpNoModelPayload {
    param($Records)
    foreach ($r in @($Records)) {
        $p=Get-LpCandidateName ([string]$r.Path)
        if ($p -match '(?i)(^|/)(model|models)(/|$)|(^|/)[^/]*(llama|gguf|ggml)[^/]*(/|$)|(^|/)(Explorer\.Model[^/]*|model[^/]*\.(dll|exe)|[^/]*\.Model\.dll)$|\.(gguf|ggml)$') { throw "No-model payload rejects model/native experiment: $p" }
    }
}

function Get-LpVerificationIds {
    param([string]$Version)
    if (Test-LpNoModelVersion $Version) { return @('ReleaseRegression','ExplorerHost','HeuristicExploration') }
    if ($Version -ceq '0.13.0') { return @('ReleaseRegression','ExplorerHost','Model') }
    throw 'Unsupported component verification version.'
}

function Get-LpDesktopChecks {
    param([string]$Version)
    $checks=@('DesktopWindowObserved','RuleSelectionObserved','CandidatePagingAndKeepRestore','NoProductionDeletion','WhiteBackgroundIconObserved','CompactLayoutObserved','CleaningProfileConfirmationObserved','SingleWindowFlowObserved','ThreePresetImmediateApplyObserved','AdvancedCustomOffByDefaultObserved','DiscoveryAuthorizationCancelObserved','MaintenanceCancelObserved','ExplorerHostObserved')
    if (Test-LpNoModelVersion $Version) { return @($checks+@('NoModelPayloadObserved','HeuristicAnalysisObserved')) }
    if ($Version -ceq '0.13.0') { return @($checks+'ModelOfflineObserved') }
    throw 'Unsupported desktop verification version.'
}

function Assert-LpVerificationResults {
    param($Results,[string]$Version)
    $ids=@(Get-LpVerificationIds $Version)
    if ((Test-LpNoModelVersion $Version) -and @($Results).Count -ne $ids.Count) { throw 'No-model final verification must have exactly ReleaseRegression, ExplorerHost and HeuristicExploration.' }
    foreach ($id in $ids) {
        $r=@($Results | Where-Object Id -CEQ $id)
        if ($r.Count -ne 1 -or $r[0].Status -cne 'Passed' -or $r[0].Assertions -le 0 -or $r[0].Failed -ne 0 -or $r[0].Blocked -ne 0) { throw "Final verification missing/failed: $id" }
    }
}

function Assert-LpDesktopChecks {
    param($Checks,[string]$Version)
    if ((Test-LpNoModelVersion $Version) -and @($Checks | Where-Object Name -CEQ 'ModelOfflineObserved').Count) { throw 'No-model desktop cannot claim observation of a removed model.' }
    foreach ($name in @(Get-LpDesktopChecks $Version)) { if (@($Checks | Where-Object { $_.Name -ceq $name -and $_.Passed -is [bool] -and $_.Passed }).Count -ne 1) { throw "Missing desktop acceptance: $name" } }
    foreach ($c in @($Checks)) { if ($c.Passed -isnot [bool] -or -not $c.Passed) { throw 'Failed/invalid desktop acceptance check.' } }
}

function Test-LpHistoricalModelSource {
    param([string]$Path)
    return $Path -match '(?i)^(engine/Explorer\.Model/|engine-tests/Explorer\.Model[^/]*/|engine-tests/Explorer\.Bootstrap\.Tests/|tests/(laya-evaluation|model-exploration)/|tools/(laya|models?|model-trials)/)'
}

function Assert-LpPackageBudget {
    param([string]$Version,[string]$ZipPath,$Records)
    if (-not (Test-LpNoModelVersion $Version)) { return }
    Assert-LpNoModelPayload $Records
    $bytes=0L;foreach ($r in @($Records)) { $bytes += [long]$r.Bytes }
    if ($bytes -gt 100MB -or ([IO.FileInfo]$ZipPath).Length -gt 50MB) { throw "0.14 payload budget exceeded: extracted=$bytes; ZIP=$(([IO.FileInfo]$ZipPath).Length); limits=100MiB/50MiB. No trimming or alternate runtime is authorized." }
}

function Get-LpApprovedRuntimePacks {
    # Official NuGet bytes rechecked against .NET 10 release metadata and the five
    # November 2026 GHSA advisories. Pin bytes as well as version; never trust a
    # mutable cache/provenance file as the source of the approved digest.
    return @(
        [pscustomobject]@{Id='Microsoft.NETCore.App.Runtime.win-x64';Version='10.0.15';Commit='8e0f8ed2312954727f8919d7d1c2f78b483b4ee7';Bytes=39989758L;Sha512='304180911187AC05D8036B7F2E8D260F11FEFCEE4D2EA8164DC561EF488E6494E9A0E08BFE329F3A00EA6280E2DD6F56727BE22F80E1325FB99560BC731B6D4B'},
        [pscustomobject]@{Id='Microsoft.NETCore.App.Host.win-x64';Version='10.0.15';Commit='8e0f8ed2312954727f8919d7d1c2f78b483b4ee7';Bytes=5800874L;Sha512='57C812C49749DE9D7AEC1E0F6CD349C9372413CF62BFBE13E1A749997D55DDDF8AA3C1E65D52D9C42A1825E3633B998447DC261BCDCE5681732861B03DEEFBD8'}
    )
}

function Assert-LpHostDependencyProvenance {
    param($Provenance,[string]$SourceRoot)
    $runtime=@('Microsoft.NETCore.App.Runtime.win-x64','Microsoft.NETCore.App.Host.win-x64');$seen=@{}
    foreach ($p in @($Provenance.RuntimePacks)) {
        $approvedPack=@(Get-LpApprovedRuntimePacks | Where-Object Id -CEQ $p.Id)
        if ($p.Id -cnotin $runtime -or $seen.ContainsKey([string]$p.Id) -or $approvedPack.Count -ne 1 -or $p.Version -cne $approvedPack[0].Version -or $p.License -cne 'MIT' -or $p.Repository -cne 'https://github.com/dotnet/dotnet' -or $p.Commit -cne $approvedPack[0].Commit -or $p.Sha512 -ne $approvedPack[0].Sha512 -or $p.Bytes -ne $approvedPack[0].Bytes) { throw 'Fixed official runtime pack provenance required.' };$seen[[string]$p.Id]=$true
    }
    if ($seen.Count -ne 2) { throw 'Exactly two fixed runtime pack provenance records required.' }
    $projects=@(Get-LpHostProjects $SourceRoot);$seen=@{}
    foreach ($lock in @($Provenance.LockedRestore)) {
        if ($lock.Project -cnotin $projects -or $seen.ContainsKey([string]$lock.Project) -or [string]$lock.Sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid locked restore project provenance.' };$seen[[string]$lock.Project]=$true
        $original=Get-LpJson (Join-Path $SourceRoot ('engine/'+$lock.Project+'/packages.lock.json'))
        $approved=@{}
        foreach ($framework in $original.dependencies.PSObject.Properties) { foreach ($d in $framework.Value.PSObject.Properties) {
            if ($d.Value.type -ceq 'Project') { continue }
            $approved[$d.Name]=$d.Value
        } }
        foreach ($framework in $lock.Content.dependencies.PSObject.Properties) { foreach ($d in $framework.Value.PSObject.Properties) {
            if ($d.Name -match '(?i)Explorer\.Model|llama|gguf|ggml') { throw 'Locked graph includes model dependencies.' }
            if ($d.Value.type -ceq 'Project') { continue }
            if ($d.Name -cin $runtime) {
                $pin=@(Get-LpApprovedRuntimePacks | Where-Object Id -CEQ $d.Name)[0]
                $hashBytes=New-Object byte[] 64;for ($i=0;$i -lt 64;$i++) { $hashBytes[$i]=[Convert]::ToByte($pin.Sha512.Substring($i*2,2),16) }
                if ($d.Value.resolved -cne $pin.Version -or $d.Value.contentHash -cne [Convert]::ToBase64String($hashBytes)) { throw 'Unexpected runtime lock version/content hash.' };continue
            }
            if (-not $approved.ContainsKey($d.Name) -or $d.Value.resolved -cne $approved[$d.Name].resolved -or $d.Value.contentHash -cne $approved[$d.Name].contentHash) { throw 'Published dependency differs from approved fixed source lock.' }
        } }
        foreach ($name in $approved.Keys) {
            $matches=@($lock.Content.dependencies.PSObject.Properties | ForEach-Object { $_.Value.PSObject.Properties } | Where-Object Name -CEQ $name)
            if (-not $matches.Count) { throw 'Approved package was omitted from the published lock provenance.' }
        }
    }
    if ($seen.Count -ne $projects.Count) { throw 'All product project locked restores are required.' }
}

function Get-LpComponentFacts {
    param([string]$BuildRoot,$Build,[string]$SourceRoot,[switch]$ReleaseLayout)
    $noModel=Test-LpNoModelVersion $Build.Version
    if (-not $noModel -and $Build.Version -cne '0.13.0') { throw 'Explicit supported component version required.' }
    if ($noModel -and ($Build.ModelMode -cne 'Absent' -or $Build.AlgorithmMode -cne 'Heuristic')) { throw '0.14 requires explicit Absent/Heuristic product modes.' }
    if ($Build.ComponentSchema -cne 'SafeJunkCleaner.Components.v1' -or $Build.ComponentsComplete -isnot [bool] -or -not $Build.ComponentsComplete -or $Build.BuildStage -cne 'ComponentsBuilt' -or $Build.BuildTool.Name -cne 'ps2exe' -or $Build.BuildTool.Version -cne '1.0.18') { throw 'Explicit complete component build schema required.' }
    $version=[string]$Build.Version;$fileVersion=$version+'.0'
    $top=@($Build.Files)
    $required=@("星梦雨垃圾清理器_v$version.exe","SafeJunkCleaner_v$version.ps1")
    if ($noModel -and $Build.PSObject.Properties['LongPathRuntimeConfig'] -and $Build.LongPathRuntimeConfig -eq $true) { $required += "星梦雨垃圾清理器_v$version.exe.config" }
    if ($top.Count -ne $required.Count) { throw 'Exact top-level product artifact set required.' }
    $records=@()
    foreach ($r in $top) {
        if ($r.Name -cnotin $required) { throw 'Unexpected top-level executable/script.' }
        $path=Join-Path $BuildRoot $r.Name
        if ($r.Name.EndsWith('.exe',[StringComparison]::Ordinal)) {
            if ($r.FileVersion -cne $fileVersion -or [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion -cne $fileVersion) { throw 'Main executable file version mismatch.' }
        } elseif ($r.Name.EndsWith('.exe.config',[StringComparison]::Ordinal)) {
            $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            $expected='<?xml version="1.0" encoding="utf-8" ?>'+"`r`n"+'<configuration><startup><supportedRuntime version="v4.0" sku=".NETFramework,Version=v4.0" /></startup><runtime><AppContextSwitchOverrides value="Switch.System.IO.UseLegacyPathHandling=false;Switch.System.IO.BlockLongPaths=false" /></runtime></configuration>'
            $text=$text.TrimEnd([char]13,[char]10)
            if ($text -cne $expected) { throw 'Main runtime configuration mismatch.' }
        } else {
            $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            $marker='$script:SjcEmbeddedVersion = '+"[pscustomobject]@{version='$version';fileVersion='$fileVersion';planSchemaVersion=1}"
            if ($text.Split(@($marker),[StringSplitOptions]::None).Count -ne 2) { throw 'Combined script embedded version mismatch.' }
            $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            if (@($errors).Count) { throw 'Combined script parse failure.' }
        }
        $records += [pscustomobject]@{Path=$r.Name;SHA256=$r.SHA256;Bytes=$r.Bytes}
    }
    if (@($records.Path | Sort-Object -Unique).Count -ne $required.Count) { throw 'Duplicate product artifact.' }
    Assert-LpRecordSet $Build.Sources (@(Get-LpProductSources $Build.Version)+@('scripts/build.ps1','scripts/local-promotion-common.ps1','assets/app.ico')) $SourceRoot
    if (-not $ReleaseLayout) {
        $allowedRoots=if ($noModel) { @('explorer') } else { @('explorer','model') }
        foreach ($item in Get-ChildItem -LiteralPath $BuildRoot -Force) {
            if (($item.PSIsContainer -and $item.Name -cnotin $allowedRoots) -or (-not $item.PSIsContainer -and $item.Name -cnotin @($required+'build-manifest.json'+'source-manifest.json'))) { throw 'Unexpected build root entry.' }
        }
    }
    $componentCount=if ($noModel) { 1 } else { 2 }
    if (@($Build.Components).Count -ne $componentCount -or ($noModel -and $Build.Components[0].Name -cne 'ExplorerHost')) { throw 'Product component set does not match explicit version/modes.' }
    $seen=@{}
    foreach ($c in $Build.Components) {
        if ($seen.ContainsKey([string]$c.Name)) { throw 'Duplicate component.' };$seen[[string]$c.Name]=$true
        $rootName='';$manifestName=''
        switch -CaseSensitive ($c.Name) {
            'ExplorerHost' { $rootName='explorer';$manifestName='host-component-manifest.json' }
            'Model' { $rootName='model';$manifestName='component-manifest.json' }
            default { throw 'Unknown product component.' }
        }
        if ($c.Root -cne $rootName -or $c.ManifestPath -cne ($rootName+'/'+$manifestName)) { throw 'Component root/manifest is not the fixed product path.' }
        $path=Join-Path $BuildRoot $c.ManifestPath
        if ((Get-LpHash $path) -ne $c.ManifestSHA256) { throw 'Component manifest hash mismatch.' }
        $combined=[IO.File]::ReadAllText((Join-Path $BuildRoot "SafeJunkCleaner_v$version.ps1"),[Text.Encoding]::UTF8)
        if ($noModel -and $combined -match '\$script:SjcEmbeddedModelManifestSha256\s*=') { throw 'No-model combined script must not bind a model component.' }
        $variable=if ($c.Name -ceq 'ExplorerHost') { 'SjcEmbeddedExplorerManifestSha256' } else { 'SjcEmbeddedModelManifestSha256' }
        $binding='$script:'+$variable+" = '$($c.ManifestSHA256)'"
        if ($combined.Split(@($binding),[StringSplitOptions]::None).Count -ne 2) { throw 'Combined script component manifest binding mismatch.' }
        $m=Get-LpJson $path
        $local=@()
        if ($c.Name -ceq 'ExplorerHost') {
            $contract=if ($noModel) { 3 } else { 2 }
            if ($m.SchemaVersion -ne 1 -or $m.ContractVersion -ne $contract -or $m.SelfContained -isnot [bool] -or -not $m.SelfContained -or $m.RuntimeIdentifier -cne 'win-x64' -or $m.RuntimeRoot -cne '.' -or $m.Launch.Executable -cne 'sjc-explorer.exe' -or @($m.Launch.Arguments).Count -ne 0 -or $m.Launch.WorkingDirectory -cne '.') { throw 'Self-contained fixed ExplorerHost launch required.' }
            if ($noModel) {
                if ($m.ModelMode -cne 'Absent' -or $m.AlgorithmMode -cne 'Heuristic' -or $m.SourceProvenance.ContractVersion -ne 3) { throw '0.14 Host must bind Absent/Heuristic contract.' }
                $null=Assert-LpHostSourceProvenance $m.SourceProvenance $SourceRoot
                foreach ($property in @('ModelIncluded','ModelAssemblyIncluded','ModelReady','ModelAvailable')) { if ($m.PSObject.Properties[$property] -and ($m.$property -isnot [bool] -or $m.$property)) { throw 'No-model Host cannot declare model capability.' } }
                if ($m.PSObject.Properties['ModelComponentExpectedSibling'] -and $m.ModelComponentExpectedSibling) { throw 'No-model Host cannot expect sibling cache/payload.' }
                if ($m.SourceProvenance.Sources.Path -match '^engine/Explorer\.Model/') { throw 'No-model Host provenance includes a model project.' }
            }
            $hostRequired=@('engine/Directory.Build.props')
            $hostProjects=@(Get-LpHostProjects $SourceRoot)
            if (-not $noModel) { $hostProjects += 'Explorer.Model' }
            foreach ($project in $hostProjects) {
                $projectRoot=Join-Path $SourceRoot ('engine/'+$project)
                if ([IO.Directory]::Exists($projectRoot)) {
                    foreach ($f in @(Get-LpCandidateFiles $projectRoot -SourceOnly | Where-Object { $_.Extension -in @('.cs','.csproj','.json') })) { $hostRequired += $f.FullName.Substring($SourceRoot.Length+1).Replace('\','/') }
                } elseif ($noModel) { throw "Required product project missing: $project" }
            }
            if ($noModel -and @($m.SourceProvenance.Sources).Count -ne $hostRequired.Count) { throw 'Host source provenance must match exactly the five product projects and shared props.' }
            Assert-LpRecordSet $m.SourceProvenance.Sources $hostRequired $SourceRoot
            if ($m.SourceProvenance.GitCommit -ne ((Invoke-LpGit $SourceRoot @('rev-parse','--verify','HEAD')) -join '')) { throw 'Host Git provenance mismatch.' }
            foreach ($r in @($m.Components)) { $local += [pscustomobject]@{Path=$r.Path;SHA256=$r.Sha256;Bytes=$r.Bytes} }
            foreach ($p in @('sjc-explorer.exe','sjc-explorer.dll','coreclr.dll','hostfxr.dll','System.Private.CoreLib.dll','licenses/SafeJunkCleaner-LICENSE')) { if ($local.Path -cnotcontains $p) { throw "Incomplete self-contained ExplorerHost: $p" } }
            if ($noModel) {
                if($Build.Version -ceq '0.17.0'){foreach($p in @('sjc-quickclean.exe','sjc-quickclean.dll','sjc-quickclean.deps.json','sjc-quickclean.runtimeconfig.json')){if($p -cnotin $local.Path){throw "Independent QuickClean Host missing: $p"}}}
                Assert-LpNoModelPayload $local
                foreach ($p in @('hostpolicy.dll','sjc-explorer.runtimeconfig.json','sjc-explorer.deps.json','Microsoft.Data.Sqlite.dll','SQLitePCLRaw.core.dll','SQLitePCLRaw.provider.e_sqlite3.dll','e_sqlite3.dll')) { if ($local.Path -cnotcontains $p) { throw "Incomplete 0.14 runtime/SQLite: $p" } }
                if ($m.RuntimeVersion -cne '10.0.15') { throw 'Fixed repaired self-contained runtime required.' }
                foreach ($package in @('microsoft.netcore.app.runtime.win-x64-10.0.15','microsoft.netcore.app.host.win-x64-10.0.15','microsoft.data.sqlite-10.0.14','microsoft.data.sqlite.core-10.0.14','sqlitepclraw.core-2.1.13','sqlitepclraw.bundle_e_sqlite3-2.1.13','sqlitepclraw.provider.e_sqlite3-2.1.13','sqlitepclraw.lib.e_sqlite3-2.1.13')) {
                    $prefix='licenses/'+$package+'/'
                    $notices=@($local | Where-Object { $_.Path.StartsWith($prefix,[StringComparison]::Ordinal) -and $_.Path -match '(?i)license|third.party|\.nuspec$' })
                    if (-not $notices.Count) { throw "Missing runtime/SQLite license provenance: $package" }
                    foreach ($notice in $notices) { if ($notice.Bytes -le 0) { throw 'Empty package notice.' } }
                }
                $deps=[IO.File]::ReadAllText((Join-Path $BuildRoot ($rootName+'/sjc-explorer.deps.json')))
                if ($deps -match '(?i)Explorer\.Model|llama|gguf|ggml') { throw 'Host dependency graph references a model payload.' }
                $runtime=Get-LpJson (Join-Path $BuildRoot ($rootName+'/sjc-explorer.runtimeconfig.json'))
                if ($runtime.runtimeOptions.PSObject.Properties['framework'] -or $runtime.runtimeOptions.PSObject.Properties['frameworks']) { throw 'Framework-dependent Host is not permitted.' }
                $included=@($runtime.runtimeOptions.includedFrameworks | Where-Object { $_.name -ceq 'Microsoft.NETCore.App' -and $_.version -ceq $m.RuntimeVersion })
                if ($included.Count -ne 1) { throw 'Host runtime configuration differs from the fixed repaired runtime.' }
                Assert-LpHostDependencyProvenance $m.SourceProvenance $SourceRoot
            }
        } else {
            if ($m.SchemaVersion -ne 1 -or $m.ModelRevision -cne '91cad51170dc346986eccefdc2dd33a9da36ead9' -or $m.ModelSha256 -ne 'd7efb072e7724d25048a4fda0a3e10b04bdef5d06b1403a1c93bd9f1240a63c8' -or $m.RuntimeCommit -cne '5f490d7bfe78844e6390c869454c149fd7e003a8' -or $m.TemplateSha256 -ne 'd5495a1e5db0611132a97e46a65dbb64a642a499421228b9c8b93229097fa9a4' -or $m.ModelPath -cne 'model/qwen2.5-1.5b-instruct-q8_0.gguf') { throw 'Fixed model/runtime/template identity mismatch.' }
            # Literal official allowlist, parsed as data only; never execute source code.
            $native=@{}
            $nativeText=[IO.File]::ReadAllText((Join-Path $SourceRoot 'engine/Explorer.Model/OfficialNativeHashes.cs'))
            foreach ($match in [regex]::Matches($nativeText,'\["(runtime/[^"\r\n]+)"\]\s*=\s*"([a-f0-9]{64})"')) { $native[$match.Groups[1].Value]=$match.Groups[2].Value }
            if ($native.Count -lt 4) { throw 'Official runtime hash declaration missing.' }
            foreach ($r in @($m.Files)) {
                $p=Get-LpCandidateName $r.Path
                if ($p.StartsWith('runtime/',[StringComparison]::Ordinal) -and $p -notmatch '^runtime/LICENSE[^/]*$') {
                    if (-not $native.ContainsKey($p) -or $native[$p] -ne $r.Sha256) { throw 'Unapproved model native runtime.' }
                } elseif ($p -notin @($m.ModelPath,'chat-template.jinja','MODEL-LICENSE','LLAMA-LICENSE') -and $p -notmatch '^runtime/LICENSE[^/]*$') { throw 'Unexpected model component file.' }
                if (($p -ceq $m.ModelPath -and $r.Sha256 -ne $m.ModelSha256) -or ($p -ceq 'chat-template.jinja' -and $r.Sha256 -ne $m.TemplateSha256)) { throw 'Fixed model/template bytes mismatch.' }
                $local += [pscustomobject]@{Path=$p;SHA256=$r.Sha256}
            }
            foreach ($p in @($m.ModelPath,'chat-template.jinja','MODEL-LICENSE','LLAMA-LICENSE','runtime/llama-completion.exe','runtime/llama-completion-impl.dll','runtime/llama-tokenize.exe','runtime/llama.dll')) { if ($local.Path -cnotcontains $p) { throw "Missing model/runtime/license file: $p" } }
            foreach ($p in @('MODEL-LICENSE','LLAMA-LICENSE')) { if (([IO.FileInfo](Join-Path (Join-Path $BuildRoot $rootName) $p)).Length -le 0) { throw 'Empty redistribution license.' } }
        }
        Assert-LpExactFiles (Join-Path $BuildRoot $rootName) $local @($manifestName)
        foreach ($r in $local) { $records += [pscustomobject]@{Path=$rootName+'/'+$r.Path;SHA256=$r.SHA256;Bytes=([IO.FileInfo](Join-Path (Join-Path $BuildRoot $rootName) $r.Path)).Length} }
        $records += [pscustomobject]@{Path=$c.ManifestPath;SHA256=$c.ManifestSHA256;Bytes=([IO.FileInfo]$path).Length}
    }
    foreach ($r in @($records | Where-Object { -not $_.Path.Contains('/') })) { if ((Get-LpHash (Join-Path $BuildRoot $r.Path)) -ne $r.SHA256 -or ([IO.FileInfo](Join-Path $BuildRoot $r.Path)).Length -ne $r.Bytes) { throw 'Product artifact mismatch.' } }
    return $records
}

function Test-LpCandidateZip {
    param([string]$Path,$Records)
    $expected=@{};$seen=@{}
    foreach ($r in $Records) { $p=Get-LpCandidateName $r.Path;if ($expected.ContainsKey($p)) { throw 'Duplicate expected ZIP path.' };$expected[$p]=$r }
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($e in $zip.Entries) {
            $p=Get-LpCandidateName $e.FullName
            if ($seen.ContainsKey($p) -or -not $expected.ContainsKey($p)) { throw 'Unexpected/duplicate ZIP entry.' };$seen[$p]=$true
            $stream=$e.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try { $hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','') } finally { $stream.Dispose();$sha.Dispose() }
            if ($hash -ne $expected[$p].SHA256 -or $e.Length -ne [long]$expected[$p].Bytes) { throw 'ZIP entry hash/length mismatch.' }
        }
        if ($seen.Count -ne $expected.Count) { throw 'ZIP exact entry set mismatch.' }
    } finally { $zip.Dispose() }
}

function Assert-LpCandidateEvidence {
    param([string]$SourceRoot,[string]$BuildRoot,$Build,[string]$SourceSetSha256,[string]$FinalPath,[string]$DesktopPath,$ProductRecords=$null,[int]$MaxAgeHours=72)
    $final=Get-LpJson $FinalPath;$gui=Get-LpJson $DesktopPath
    $builtUtc=Assert-LpRecent $Build.BuiltUtc $MaxAgeHours
    $finalUtc=Assert-LpRecent $final.FinishedUtc $MaxAgeHours
    $desktopUtc=Assert-LpRecent $gui.AcceptedUtc $MaxAgeHours
    if ($finalUtc -lt $builtUtc -or $desktopUtc -lt $builtUtc) { throw 'Final/desktop acceptance predates the build.' }
    $buildHash=Get-LpHash (Join-Path $BuildRoot 'build-manifest.json')
    foreach ($e in @($final,$gui)) {
        if ($e.Status -cne 'Passed' -or $e.BuildId -cne $Build.BuildId -or $e.BuildManifestSHA256 -ne $buildHash -or $e.SourceSetSha256 -ne $SourceSetSha256 -or @($e.Checks).Count -eq 0) { throw 'Acceptance is not bound to the actual complete build/source set.' }
        foreach ($check in $e.Checks) { if ($check.Passed -isnot [bool] -or -not $check.Passed) { throw 'Failed/invalid final or desktop acceptance check.' } }
    }
    if ($final.Schema -cne 'SafeJunkCleaner.FinalTestResult.v1' -or (Get-LpSourceSetHash $final.SourceHashes) -ne $SourceSetSha256 -or @($final.SourceHashes).Count -ne @(Get-LpWorkingSources $SourceRoot).Count) { throw 'Final result must fingerprint the complete working source set.' }
    $product=if ($null -ne $ProductRecords) { @($ProductRecords) } else { @(Get-LpComponentFacts $BuildRoot $Build $SourceRoot) }
    if (@($final.Artifacts).Count -ne $product.Count) { throw 'Final result artifact set differs from the product.' }
    $seen=@{}
    foreach ($r in $final.Artifacts) {
        $p=Get-LpCandidateName $r.Path
        $match=@($product | Where-Object Path -CEQ $p)
        if ($seen.ContainsKey($p) -or $match.Count -ne 1 -or $r.SHA256 -ne $match[0].SHA256) { throw 'Final result artifact mismatch.' };$seen[$p]=$true
    }
    Assert-LpVerificationResults $final.Results $Build.Version
    $summary=Get-LpJson $final.ReleaseSummaryPath
    $summaryStarted=Assert-LpRecent $summary.StartedUtc $MaxAgeHours
    $summaryFinished=Assert-LpRecent $summary.FinishedUtc $MaxAgeHours
    if ($summaryStarted -lt $builtUtc -or $summaryFinished -lt $summaryStarted -or $finalUtc -lt $summaryFinished) { throw 'Final result chronology/Release summary mismatch.' }
    if ($summary.Scope -cne 'Release' -or $summary.Status -cne 'Passed' -or $summary.ExitCode -ne 0 -or $summary.Failed -ne 0 -or $summary.Blocked -ne 0 -or @($summary.CoverageGaps).Count -or @($summary.GateErrors).Count) { throw 'Complete Release regression required.' }
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'tests/run_all.ps1'),[ref]$tokens,[ref]$errors)
    $decl=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq '$script:AllCases'},$true))
    if (@($errors).Count -or $decl.Count -ne 1) { throw 'Unsupported regression declaration.' }
    $required=@()
    foreach ($table in @($decl[0].Right.FindAll({param($n) $n -is [Management.Automation.Language.HashtableAst]},$true))) {
        $ids=@($table.KeyValuePairs | Where-Object { $_.Item1.SafeGetValue() -ceq 'Id' })
        if ($ids.Count -ne 1) { throw 'Invalid regression declaration.' };$required += [string]$ids[0].Item2.SafeGetValue()
    }
    $baseline=@('R01-rule-inventory','R02-browser-discovery','R03-rule-approval-seal','P01-path-guards','P02-preference-guards','P03-preview-session','S01-scan-core','S02-same-root-dedupe','S03-scan-links','C01-clean-core','C02-clean-tamper','C03-clean-error-cap','C04-cancel','C05-pagination-export','L01-logging','W01-worker-boundary','V01-version-contract','G01-gui-selftest','G02-background-preview','W02-worker-selftest','X01-exe-selftest','E01-explorer-workbench')
    foreach ($id in $baseline) { if ($required -cnotcontains $id) { throw "Baseline Release case removed: $id" } }
    if (@($required | Sort-Object -Unique).Count -ne $required.Count -or @($summary.Results).Count -ne $required.Count -or $summary.Cases -ne $required.Count -or $summary.Passed -ne $required.Count) { throw 'Release case set/totals mismatch.' }
    $evidence=@($FinalPath,$DesktopPath,$final.ReleaseSummaryPath);$assertions=0
    foreach ($id in $required) {
        $r=@($summary.Results | Where-Object Id -CEQ $id)
        if ($r.Count -ne 1 -or $r[0].Status -cne 'Passed' -or $r[0].Assertions -le 0 -or $r[0].Passed -ne $r[0].Assertions -or $r[0].Failed -ne 0 -or $r[0].ExitCode -ne 0 -or $r[0].TimedOut -isnot [bool] -or $r[0].TimedOut -or @($r[0].CoverageGaps).Count) { throw "Required regression failed/missing: $id" }
        $detail=Get-LpJson $r[0].ResultPath
        if ($detail.Status -cne 'Passed' -or $detail.Assertions -ne $r[0].Assertions -or $detail.Passed -ne $r[0].Passed -or $detail.Failed -ne 0 -or @($detail.CoverageGaps).Count) { throw 'Regression detail mismatch.' }
        $assertions += $r[0].Assertions
        $evidence += @($r[0].ResultPath,$r[0].Stdout,$r[0].Stderr)
    }
    if ($summary.Assertions -ne $assertions) { throw 'Release assertion totals mismatch.' }
    foreach ($r in $summary.SourceHashes) {
        $path=[string]$r.Path
        if (-not [IO.Path]::IsPathRooted($path)) { $path=Join-Path $SourceRoot (Get-LpRelativePath $path) }
        if ((Get-LpHash $path) -ne $r.SHA256) { throw 'Release regression source changed.' }
    }
    Assert-LpRecordSet @($summary.SourceHashes | Where-Object { -not [IO.Path]::IsPathRooted([string]$_.Path) }) (@(Get-LpProductSources $Build.Version)+@('scripts/build.ps1')) $SourceRoot
    $exe=@($Build.Files | Where-Object Name -CEQ ("星梦雨垃圾清理器_v$($Build.Version).exe"))[0]
    if ((Get-LpHash $summary.Exe.Path) -ne $exe.SHA256 -or $summary.Exe.SHA256 -ne $exe.SHA256) { throw 'Regression EXE differs from actual build.' }
    Assert-LpDesktopChecks $gui.Checks $Build.Version
    if ($gui.GuiSourceSHA256 -ne (Get-LpHash (Join-Path $SourceRoot 'src/Gui.ps1')) -or $gui.IconSHA256 -ne (Get-LpHash (Join-Path $SourceRoot 'assets/app.ico')) -or -not @($gui.EvidenceFiles).Count) { throw 'Desktop source/icon/saved evidence mismatch.' }
    $evidence += @($gui.EvidenceFiles)
    return @($evidence | Sort-Object -Unique | ForEach-Object { [pscustomobject]@{Path=(Get-LpPath $_);SHA256=(Get-LpHash $_)} })
}

function New-LpCandidateZip {
    param([string]$Path,[string]$Root,$Records)
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $zip=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$false)
    try { foreach ($r in $Records) {
        $inputPath=if ($r.PSObject.Properties['InputPath']) { Get-LpPath $r.InputPath } else { Join-Path $Root $r.Path }
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$inputPath,$r.Path,[IO.Compression.CompressionLevel]::Optimal)
    } } finally { $zip.Dispose();$stream.Dispose() }
    Test-LpCandidateZip $Path $Records
}

function Assert-LpBuildSourceTree {
    param([string]$SourceRoot,[string]$BuildRoot,$Build)
    $records=@(Get-LpWorkingSources $SourceRoot)
    $setHash=Get-LpSourceSetHash $records
    if ($Build.SourceTree.ManifestPath -cne 'source-manifest.json' -or (Get-LpHash (Join-Path $BuildRoot 'source-manifest.json')) -ne $Build.SourceTree.SHA256 -or $Build.SourceTree.SourceSetSha256 -ne $setHash) { throw 'Build source tree manifest mismatch.' }
    $snapshot=Get-LpJson (Join-Path $BuildRoot 'source-manifest.json')
    $head=(Invoke-LpGit $SourceRoot @('rev-parse','--verify','HEAD')) -join ''
    if ($snapshot.Schema -cne 'SafeJunkCleaner.SourceManifest.v1' -or $snapshot.GitHead -ne $head -or $snapshot.Dirty -isnot [bool] -or $snapshot.SourceSetSha256 -ne $setHash -or (Get-LpSourceSetHash $snapshot.Sources) -ne $setHash -or @($snapshot.Sources).Count -ne $records.Count) { throw 'Actual working source differs from build capture.' }
    return $setHash
}

function Assert-LpPublicDocument {
    param([string]$Path)
    $text=[IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8)
    if ($text -match '(?i)[A-Z]:[\\/]Users[\\/][^\s\\/<>"\x27]+' -or $text -match '(?i)[A-Z]:[\\/][^\r\n]*[\\/](?:artifacts|rawlogs|screenshots)[\\/]') { throw 'User guide contains private machine/evidence paths; supply a separate public guide.' }
}

function Get-LpDeliveryDocuments {
    param([string]$Version)
    $files=@('README.md','LICENSE','THIRD-PARTY-NOTICES.md','assets/third-party/PS2EXE-LICENSE.txt','docs/RULES.md','docs/SAFETY.md','docs/DEVELOPMENT.md',('docs/RELEASE-'+$Version+'.zh-CN.md'))
    if (Test-LpNoModelVersion $Version) { $files += 'docs/使用手册.md' }
    return $files
}

function Test-LpCandidateEnvelope {
    param([string]$Directory)
    # All file names are relative to the ONE candidate directory containing this
    # manifest. The whole directory may be copied/moved; flattening is invalid.
    $root=Get-LpPath $Directory -Directory
    $manifest=Get-LpJson (Join-Path $root 'candidate-manifest.json')
    if ($manifest.Schema -cne 'SafeJunkCleaner.DevelopmentCandidate.v1' -or $manifest.Status -cnotin @('StageOnly','VerifiedCandidate') -or $manifest.DevelopmentCandidate -isnot [bool] -or -not $manifest.DevelopmentCandidate -or $manifest.ZipEntriesVerified -isnot [bool] -or -not $manifest.ZipEntriesVerified) { throw 'Unsupported candidate envelope.' }
    Assert-LpExactFiles $root $manifest.Files @('candidate-manifest.json')
    foreach ($name in @(('SafeJunkCleaner_v'+$manifest.Version+'_windows.zip'),('SafeJunkCleaner_v'+$manifest.Version+'_source.zip'))) {
        if (@($manifest.Files | Where-Object Path -CEQ $name).Count -ne 1) { throw 'Candidate ZIP missing from envelope.' }
    }
    foreach ($p in @(Get-LpDeliveryDocuments $manifest.Version)) {
        if (@($manifest.Files | Where-Object Path -CEQ ('documents/'+$p)).Count -ne 1) { throw "Candidate document missing from envelope: $p" }
    }
    return [pscustomobject]@{Status=$manifest.Status;Directory=$root;BuildId=$manifest.BuildId;SourceSetSha256=$manifest.SourceSetSha256;Files=@($manifest.Files).Count;Verified=$true;Scope='EnvelopeFileIntegrityOnly'}
}

function New-LpComponentRelease {
    param([string]$SourceRoot,[string]$BuildRoot,[string]$FinalPath,[string]$DesktopPath)
    $build=Get-LpJson (Join-Path $BuildRoot 'build-manifest.json')
    $setHash=Assert-LpBuildSourceTree $SourceRoot $BuildRoot $build
    $product=@(Get-LpComponentFacts $BuildRoot $build $SourceRoot)
    $null=Assert-LpCandidateEvidence $SourceRoot $BuildRoot $build $setHash $FinalPath $DesktopPath $product
    $final=Get-LpJson $FinalPath;$gui=Get-LpJson $DesktopPath
    $release=Join-Path $SourceRoot ('releases/v'+$build.Version+'-'+[guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $release) { throw 'Release directory already exists.' }
    $null=New-Item -ItemType Directory -Path $release
    foreach ($p in @('build-manifest.json','source-manifest.json')) { $product += [pscustomobject]@{Path=$p;SHA256=(Get-LpHash (Join-Path $BuildRoot $p));Bytes=([IO.FileInfo](Join-Path $BuildRoot $p)).Length} }
    foreach ($r in $product) {
        $target=Join-Path $release $r.Path;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $BuildRoot $r.Path),$target,$false)
        if ((Get-LpHash $target) -ne $r.SHA256) { throw 'Release copy changed.' }
    }
    foreach ($p in @(Get-LpDeliveryDocuments $build.Version)) {
        Assert-LpPublicDocument (Join-Path $SourceRoot $p)
        $target=Join-Path $release $p;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
        [IO.File]::Copy((Join-Path $SourceRoot $p),$target,$false)
    }
    $public=[ordered]@{Schema='SafeJunkCleaner.PublicVerification.v1';Status='Passed';Version=$build.Version;BuildId=$build.BuildId;BuildManifestSHA256=(Get-LpHash (Join-Path $BuildRoot 'build-manifest.json'));SourceSetSha256=$setHash;FinalResultSHA256=(Get-LpHash $FinalPath);DesktopAcceptanceSHA256=(Get-LpHash $DesktopPath);Results=@($final.Results | ForEach-Object { [pscustomobject]@{Id=$_.Id;Status=$_.Status;Assertions=$_.Assertions;Failed=$_.Failed;Blocked=$_.Blocked} });Checks=@($gui.Checks | ForEach-Object { [pscustomobject]@{Name=$_.Name;Passed=$_.Passed} })}
    if (Test-LpNoModelVersion $build.Version) { $public.ModelMode='Absent';$public.AlgorithmMode='Heuristic' }
    [IO.File]::WriteAllText((Join-Path $release 'verification-summary.json'),($public | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
    $records=@(Get-LpCandidateFiles $release | ForEach-Object { [pscustomobject]@{Path=$_.FullName.Substring($release.Length+1).Replace('\','/');SHA256=(Get-LpHash $_.FullName);Bytes=$_.Length} })
    $info=[ordered]@{Version=$build.Version;BuildId=$build.BuildId;ComponentSchema=$build.ComponentSchema;Status='Verified';SourceSetSha256=$setHash;Files=$records}
    if (Test-LpNoModelVersion $build.Version) { $info.ModelMode='Absent';$info.AlgorithmMode='Heuristic' }
    [IO.File]::WriteAllText((Join-Path $release 'release-manifest.json'),($info | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{ReleaseDirectory=$release;Files=$records.Count;Status='Verified'}
}

function New-LpFormalComponentPackage {
    param([string]$SourceRoot,[string]$ReleaseRoot,[string]$Output,[string]$Head)
    $build=Get-LpJson (Join-Path $ReleaseRoot 'build-manifest.json')
    $setHash=Assert-LpBuildSourceTree $SourceRoot $ReleaseRoot $build
    $product=@(Get-LpComponentFacts $ReleaseRoot $build $SourceRoot -ReleaseLayout)
    $manifest=Get-LpJson (Join-Path $ReleaseRoot 'release-manifest.json')
    if ($manifest.Version -cne $build.Version -or $manifest.ComponentSchema -cne $build.ComponentSchema -or $manifest.BuildId -cne $build.BuildId -or $manifest.Status -cne 'Verified' -or $manifest.SourceSetSha256 -ne $setHash) { throw 'Verified component release manifest required.' }
    if ((Test-LpNoModelVersion $build.Version) -and ($manifest.ModelMode -cne 'Absent' -or $manifest.AlgorithmMode -cne 'Heuristic')) { throw 'Formal release must explicitly declare Absent/Heuristic.' }
    Assert-LpExactFiles $ReleaseRoot $manifest.Files @('release-manifest.json')
    $allowed=@($product.Path)+@('build-manifest.json','source-manifest.json','verification-summary.json')+@(Get-LpDeliveryDocuments $build.Version)
    if (@($manifest.Files).Count -ne $allowed.Count) { throw 'Formal release file set differs from schema.' }
    foreach ($r in $manifest.Files) { if ($r.Path -cnotin $allowed) { throw 'Unexpected formal release file.' } }
    $public=Get-LpJson (Join-Path $ReleaseRoot 'verification-summary.json')
    if ($public.Schema -cne 'SafeJunkCleaner.PublicVerification.v1' -or $public.Status -cne 'Passed' -or $public.BuildId -cne $build.BuildId -or $public.BuildManifestSHA256 -ne (Get-LpHash (Join-Path $ReleaseRoot 'build-manifest.json')) -or $public.SourceSetSha256 -ne $setHash) { throw 'Public verification provenance mismatch.' }
    if ((Test-LpNoModelVersion $build.Version) -and ($public.ModelMode -cne 'Absent' -or $public.AlgorithmMode -cne 'Heuristic')) { throw 'Public verification must explicitly declare Absent/Heuristic.' }
    Assert-LpVerificationResults $public.Results $build.Version
    Assert-LpDesktopChecks $public.Checks $build.Version
    $sourceRecords=@(Get-LpWorkingSources $SourceRoot)
    $sourceZip=@();$exclusions=@()
    $docs=@(Get-LpDeliveryDocuments $build.Version | Where-Object { $_.StartsWith('docs/',[StringComparison]::Ordinal) })+@('docs/EXPLORATION-CONTRACT.md')
    foreach ($r in $sourceRecords) {
        if ((Test-LpNoModelVersion $build.Version) -and (Test-LpHistoricalModelSource $r.Path)) { $exclusions += [pscustomobject]@{Path=$r.Path;SHA256=$r.SHA256;Reason='HistoricalModelExperiment'} }
        elseif ($r.Path.StartsWith('docs/',[StringComparison]::Ordinal) -and $r.Path -cnotin $docs) { $exclusions += [pscustomobject]@{Path=$r.Path;SHA256=$r.SHA256;Reason='PrivateDiagnosticDocument'} } else { $sourceZip += $r }
    }
    $null=New-Item -ItemType Directory -Path $Output -ErrorAction Stop
    $releaseRecords=@($manifest.Files)+@([pscustomobject]@{Path='release-manifest.json';SHA256=(Get-LpHash (Join-Path $ReleaseRoot 'release-manifest.json'));Bytes=([IO.FileInfo](Join-Path $ReleaseRoot 'release-manifest.json')).Length})
    $windowsZip=Join-Path $Output ('SafeJunkCleaner_v'+$build.Version+'_windows.zip')
    New-LpCandidateZip $windowsZip $ReleaseRoot $releaseRecords
    Assert-LpPackageBudget $build.Version $windowsZip $releaseRecords
    New-LpCandidateZip (Join-Path $Output ('SafeJunkCleaner_v'+$build.Version+'_source.zip')) $SourceRoot $sourceZip
    if ((Assert-LpBuildSourceTree $SourceRoot $ReleaseRoot $build) -ne $setHash) { throw 'Source changed during formal package.' }
    $records=@(Get-LpCandidateFiles $Output | ForEach-Object { [pscustomobject]@{Path=$_.Name;SHA256=(Get-LpHash $_.FullName);Bytes=$_.Length} })
    $info=[ordered]@{Version=$build.Version;SourceHead=$Head;SourceSetSha256=$setHash;ZipEntriesVerified=$true;SourceZipExclusions=$exclusions;Files=$records;Limitations=@('Local offline packaging only; not promotion, product acceptance or a signature.')}
    if (Test-LpNoModelVersion $build.Version) { $info.ModelMode='Absent';$info.AlgorithmMode='Heuristic' }
    [IO.File]::WriteAllText((Join-Path $Output 'release-manifest.json'),($info | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($true))
    return [pscustomobject]@{Status='Packaged';OutputDirectory=$Output;SourceHead=$Head;Files=$records}
}

function New-LpIsolation {
    param([string]$Parent)
    if (-not $Parent) { $Parent=[IO.Path]::GetTempPath() }
    $Parent=Get-LpPath $Parent -Directory
    $path = Join-Path $Parent ('sjc-promotion-'+[guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($path)
    [IO.File]::WriteAllText((Join-Path $path '.isolation-owner'),('SafeJunkCleaner local promotion isolation; retained; '+$path),[Text.UTF8Encoding]::new($true))
    try { $null = Invoke-LpGit $path @('init','--bare','.'); return $path }
    catch { throw "Isolation initialization failed; inspect owned temporary path: $path. $_" }
}

function Assert-LpAncestor {
    param([string]$Isolation, $Source, $Target)
    $null = Invoke-LpGit $Isolation @('fetch','--no-tags','--no-write-fetch-head','--no-recurse-submodules','--', $Source.Path,$Source.Head)
    $null = Invoke-LpGit $Isolation @('fetch','--no-tags','--no-write-fetch-head','--no-recurse-submodules','--', $Target.Path,$Target.Head)
    $null = Invoke-LpGit $Isolation @('merge-base','--is-ancestor',$Target.Head,$Source.Head)
}
