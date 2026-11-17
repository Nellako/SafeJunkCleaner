# SafeJunkCleaner release-layer test helpers (PS 5.1, no Pester).
# Dot-source AFTER Harness.ps1. Functions here only add assertions/evidence and
# build bounded child-process/task-channel plumbing; they never clean user data.
# All self-test cleanup is limited to GUID paths with ownership markers.

function Get-ReleasePropertyValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Test-ReleaseStringList {
    param($Value)
    if ($null -eq $Value -or $Value -is [string]) { return $false }
    return ($Value -is [System.Collections.IList])
}

function Quote-ReleaseArgument {
    param([string]$Value)
    return '"' + $Value + '"'
}

function Get-ReleaseFileLength {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return [int64]0 }
    return [int64]([IO.FileInfo]::new($Path)).Length
}

function Get-ReleaseTextFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.File]::Exists($Path)) { return '' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Copy-ReleaseEvidenceFile {
    param([string]$Source, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Source) -or -not [IO.File]::Exists($Source)) { return '' }
    $safe = ($Name -replace '[^A-Za-z0-9._-]', '_')
    $destination = Join-Path $script:EvidenceDirectory ($safe + '.raw')
    [IO.File]::Copy($Source, $destination, $true)
    return $destination
}

function Invoke-ReleaseProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [Parameter(Mandatory = $true)][string]$Tag,
        [int]$TimeoutSeconds = 300
    )
    $safeTag = ($Tag -replace '[^A-Za-z0-9._-]', '_')
    $stdout = Join-Path $script:EvidenceDirectory ($safeTag + '.stdout.log')
    $stderr = Join-Path $script:EvidenceDirectory ($safeTag + '.stderr.log')
    # Diagnostics.Process gives a trustworthy ExitCode (Start-Process -PassThru can leave
    # ExitCode null for redirected children) and preserves non-ASCII arguments verbatim
    # because they are passed as a single argument string, not re-quoted by the shell.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $timedOut = $false
    $redirected = $true
    $startedUtc = [datetime]::UtcNow
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not $process.Start()) { throw ('Cannot start child: ' + $Tag) }
        $null = $process.Handle
        $stdoutRead = $process.StandardOutput.ReadToEndAsync()
        $stderrRead = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(10000)
        }
        $exitCode = if ($process.HasExited) { [int]$process.ExitCode } else { $null }
        if ($process.HasExited) {
            [IO.File]::WriteAllText($stdout, $stdoutRead.GetAwaiter().GetResult(), (New-Object Text.UTF8Encoding($true)))
            [IO.File]::WriteAllText($stderr, $stderrRead.GetAwaiter().GetResult(), (New-Object Text.UTF8Encoding($true)))
        }
    }
    catch {
        $redirected = $false
        $exitCode = $null
    }
    finally { $watch.Stop(); $process.Dispose() }
    return [pscustomobject]@{
        Tag = $Tag
        FilePath = $FilePath
        Arguments = $Arguments
        ExitCode = $exitCode
        TimedOut = $timedOut
        Redirected = $redirected
        StartedUtc = $startedUtc.ToString('o')
        FinishedUtc = [datetime]::UtcNow.ToString('o')
        DurationSeconds = $watch.Elapsed.TotalSeconds
        StdoutPath = $stdout
        StderrPath = $stderr
    }
}

function Invoke-ReleasePowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string]$ScriptArguments = '',
        [Parameter(Mandatory = $true)][string]$Tag,
        [int]$TimeoutSeconds = 300
    )
    $powershell = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File ' + (Quote-ReleaseArgument $ScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($ScriptArguments)) { $arguments += ' ' + $ScriptArguments }
    return Invoke-ReleaseProcess -FilePath $powershell -Arguments $arguments -Tag $Tag -TimeoutSeconds $TimeoutSeconds
}

function New-ReleaseRunEvidence {
    param($Run, [string]$Tag, [string]$RejectedPath = '')
    if ($null -eq $Run) { return [pscustomobject]@{ Tag = $Tag; Started = $false } }
    $stdoutCopy = Copy-ReleaseEvidenceFile $Run.StdoutPath ($Tag + '-stdout')
    $stderrCopy = Copy-ReleaseEvidenceFile $Run.StderrPath ($Tag + '-stderr')
    return [pscustomobject][ordered]@{
        Tag = $Tag
        Started = $true
        ExitCode = $Run.ExitCode
        TimedOut = $Run.TimedOut
        Redirected = $Run.Redirected
        StartedUtc = $Run.StartedUtc
        FinishedUtc = $Run.FinishedUtc
        DurationSeconds = $Run.DurationSeconds
        StdoutPath = $Run.StdoutPath
        StderrPath = $Run.StderrPath
        StdoutBytes = Get-ReleaseFileLength $Run.StdoutPath
        StderrBytes = Get-ReleaseFileLength $Run.StderrPath
        StdoutCopy = $stdoutCopy
        StderrCopy = $stderrCopy
        RejectedPath = $RejectedPath
        RejectedPathExists = $(if ([string]::IsNullOrWhiteSpace($RejectedPath)) { $null } else { [IO.File]::Exists($RejectedPath) })
    }
}

function Assert-ReleaseNonZeroRun {
    param($Run, [string]$Tag, [string]$RejectedPath = '')
    if ($null -eq $Run) {
        Assert-True ($Tag + ' child process was started') $false 'null run'
        return
    }
    Assert-True ($Tag + ' child did not time out') (-not [bool]$Run.TimedOut) ('TimedOut=' + [string]$Run.TimedOut)
    Assert-True ($Tag + ' child exited nonzero') ($null -ne $Run.ExitCode -and [int]$Run.ExitCode -ne 0) ('ExitCode=' + [string]$Run.ExitCode)
    if (-not [string]::IsNullOrWhiteSpace($RejectedPath)) {
        Assert-True ($Tag + ' did not write the rejected output path') (-not [IO.File]::Exists($RejectedPath)) $RejectedPath
    }
    $stdoutLength = Get-ReleaseFileLength $Run.StdoutPath
    $stderrLength = Get-ReleaseFileLength $Run.StderrPath
    Assert-True ($Tag + ' produced an error/diagnostic output') ($stdoutLength -gt 0 -or $stderrLength -gt 0) ('stdoutBytes=' + $stdoutLength + '; stderrBytes=' + $stderrLength)
}

function New-ReleaseProductionTask {
    param([string]$Tag = 'release')
    throw '第一阶段禁止生产任务通道；跨进程测试通道尚未审查。'
    $stateRoot = Get-SjcProductionStateRoot
    $existed = [IO.Directory]::Exists($stateRoot)
    $context = New-SjcContext
    if (-not $existed) {
        Add-Limitation ($Tag + ' 为自检结果创建了生产状态根空目录；未扫描用户缓存目录、未写首选项。')
    }
    Add-Limitation ($Tag + ' 仅使用生产 New-SjcContext/New-SjcTaskDirectory 建立合法结果通道；未扫描或清理真实用户目录。')
    $task = New-SjcTaskDirectory -Context $context
    return [pscustomobject]@{ Context = $context; TaskDirectory = $task; StateRoot = $stateRoot }
}

function Remove-ReleaseProductionTaskBounded {
    param([string]$TaskDirectory, [string]$StateRoot)
    throw '第一阶段禁止任务目录清理，全部目录保留。'
    # Test-only cleanup for a task directory this case created. Bounded to one
    # validated GUID task directly under StateRoot\Tasks; no directory recursion.
    if ([string]::IsNullOrWhiteSpace($TaskDirectory) -or -not [IO.Directory]::Exists($TaskDirectory)) { return $true }
    $full = [IO.Path]::GetFullPath($TaskDirectory)
    $tasksRoot = [IO.Path]::GetFullPath((Join-Path $StateRoot 'Tasks'))
    $leaf = [IO.Path]::GetFileName($full)
    $guid = [guid]::Empty
    if (-not [IO.Path]::GetDirectoryName($full).Equals($tasksRoot, [StringComparison]::OrdinalIgnoreCase)) { throw '拒绝清理非本状态根任务目录。' }
    if (-not [guid]::TryParseExact($leaf, 'D', [ref]$guid)) { throw '拒绝清理非GUID任务目录。' }
    if (-not [IO.File]::Exists((Join-Path $full '.task-owner'))) { throw '拒绝清理缺少所有权标记的任务目录。' }
    if (@([IO.Directory]::GetDirectories($full)).Count -gt 0) { throw '任务目录含子目录，拒绝测试清理。' }
    foreach ($file in @([IO.Directory]::GetFiles($full))) {
        if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '任务文件是链接，拒绝测试清理。' }
    }
    foreach ($file in @([IO.Directory]::GetFiles($full))) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($full, $false)
    return $true
}

function Remove-ReleaseProductionTask {
    param($TaskInfo, [string]$Tag = 'release')
    Add-Limitation '第一阶段不执行任务目录清理，保留全部证据。'
    return $false
    if ($null -eq $TaskInfo) { return $false }
    try {
        [void](Remove-SjcTaskDirectory -Context $TaskInfo.Context -TaskDirectory $TaskInfo.TaskDirectory)
        return $true
    }
    catch {
        try {
            [void](Remove-ReleaseProductionTaskBounded -TaskDirectory $TaskInfo.TaskDirectory -StateRoot $TaskInfo.StateRoot)
            Add-Limitation ($Tag + ' 任务目录通过测试侧受限清理移除（生产删除被拒：' + $_.Exception.Message + '）。')
            return $true
        }
        catch {
            Add-Limitation ($Tag + ' 任务目录未能自动清理（保留供人工检查）：' + $_.Exception.Message)
            return $false
        }
    }
}

function Get-ReleaseTaskFileNames {
    param([string]$TaskDirectory)
    if ([string]::IsNullOrWhiteSpace($TaskDirectory) -or -not [IO.Directory]::Exists($TaskDirectory)) { return @() }
    return @([IO.Directory]::GetFiles($TaskDirectory) | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
}

function Assert-ReleaseTaskChannelContents {
    param([string]$TaskDirectory, [string]$OutputPath, [string]$Tag)
    $names = @(Get-ReleaseTaskFileNames $TaskDirectory)
    Assert-True ($Tag + ' task directory exists') ([IO.Directory]::Exists($TaskDirectory)) $TaskDirectory
    Assert-True ($Tag + ' task ownership marker exists') ($names -contains '.task-owner') ($names -join ',')
    Assert-True ($Tag + ' task completion marker exists') ($names -contains 'task.completed') ($names -join ',')
    Assert-True ($Tag + ' result channel is a direct child of the task') ([IO.Path]::GetDirectoryName($OutputPath) -eq $TaskDirectory) $OutputPath
    Assert-True ($Tag + ' result channel exists in the task') ($names -contains [IO.Path]::GetFileName($OutputPath)) ($names -join ',')
    $residue = @($names | Where-Object { $_ -like '.write-*' -or $_ -like '.backup-*' })
    Assert-Equal ($Tag + ' has no atomic-write residue in the task') 0 $residue.Count ($residue -join ',')
}

function Assert-ReleaseOutputChannel {
    param([string]$TaskDirectory, [string]$OutputPath, [string]$Tag)
    Assert-True ($Tag + ' result channel is a direct child of the verified task directory') ([IO.Path]::GetDirectoryName($OutputPath) -eq $TaskDirectory) $OutputPath
    $exists = [IO.File]::Exists($OutputPath)
    Assert-True ($Tag + ' result channel file exists') $exists $OutputPath
    if (-not $exists) { return $null }
    Assert-True ($Tag + ' result channel is non-empty') ((Get-ReleaseFileLength $OutputPath) -gt 0) ([string](Get-ReleaseFileLength $OutputPath))
    $parsed = $null
    $parseError = ''
    try { $parsed = Get-Content -LiteralPath $OutputPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop }
    catch { $parseError = $_.Exception.Message }
    Assert-True ($Tag + ' result channel parses as JSON') ($null -ne $parsed) $parseError
    return $parsed
}

function Assert-ReleasePassedContains {
    param($PassedList, [string]$Pattern, [string]$Tag)
    $hits = @(@($PassedList) | Where-Object { $_ -is [string] -and $_ -match $Pattern })
    Assert-True ($Tag + ' passed includes ' + $Pattern) ($hits.Count -gt 0) (($hits -join ' | '))
}

function Assert-ReleaseGuiModule {
    Assert-True 'src/Gui.ps1 is present and was loaded by the harness' ([bool]$script:GuiModuleLoaded) ('GuiModuleLoaded=' + [string]$script:GuiModuleLoaded)
    $command = Get-Command Test-SjcGui -CommandType Function -ErrorAction SilentlyContinue
    Assert-True 'Test-SjcGui is defined as a function' ($null -ne $command) 'missing Test-SjcGui; this is a failure, not a skip'
    return ($null -ne $command)
}

function Get-ReleaseSandboxInfo {
    param([string]$SandboxRoot)
    $info = [pscustomobject][ordered]@{
        Ok = $false
        FullPath = ''
        Leaf = ''
        MarkerExists = $false
        FilesDirectoryExists = $false
    }
    if ([string]::IsNullOrWhiteSpace($SandboxRoot)) { return $info }
    $full = $SandboxRoot
    try { $full = Get-SjcFullPath $SandboxRoot } catch { return $info }
    $productionRoot = Get-SjcProductionStateRoot
    $sandboxParent = Join-Path $productionRoot 'Sandboxes'
    $leaf = [IO.Path]::GetFileName($full)
    $guid = [guid]::Empty
    $shape = $full.StartsWith($sandboxParent + '\', [StringComparison]::OrdinalIgnoreCase)
    $isGuid = [guid]::TryParseExact($leaf, 'D', [ref]$guid)
    $info.FullPath = $full
    $info.Leaf = $leaf
    $info.Ok = ($shape -and $isGuid)
    $info.MarkerExists = [IO.File]::Exists((Join-Path $full '.sandbox-owner'))
    $info.FilesDirectoryExists = [IO.Directory]::Exists((Join-Path $full 'files'))
    return $info
}

function Register-ReleaseSelftestSandbox {
    param([string]$SandboxRoot, [string]$Tag = 'release')
    $info = Get-ReleaseSandboxInfo $SandboxRoot
    if (-not $info.Ok -or -not $info.MarkerExists) {
        Add-Limitation ($Tag + ' SelfTest 沙箱未通过 GUID/所有权标记形状验证，未登记自动清理：' + [string]$SandboxRoot)
        return $false
    }
    if (-not $script:OwnedSandboxes.Contains($info.FullPath)) {
        [void]$script:OwnedSandboxes.Add($info.FullPath)
    }
    return $true
}

function Get-ReleaseStateRootEntries {
    param([string]$StateRoot)
    if ([string]::IsNullOrWhiteSpace($StateRoot) -or -not [IO.Directory]::Exists($StateRoot)) { return @() }
    return @(Get-ChildItem -LiteralPath $StateRoot -Force | ForEach-Object {
        [pscustomobject]@{ Name = $_.Name; IsDirectory = [bool]$_.PSIsContainer }
    } | Sort-Object Name)
}

function Assert-ReleaseStateRootStable {
    param([string]$StateRoot, $BeforeEntries, [string]$BeforePreferenceHash, [string]$Tag, [string[]]$AllowedNew = @('Sandboxes', 'Logs'))
    $after = @(Get-ReleaseStateRootEntries $StateRoot)
    $beforeNames = @($BeforeEntries | ForEach-Object { [string]$_.Name })
    $afterNames = @($after | ForEach-Object { [string]$_.Name })
    $removed = @($beforeNames | Where-Object { $_ -notin $afterNames })
    $added = @($afterNames | Where-Object { $_ -notin $beforeNames })
    $unexpected = @($added | Where-Object { $_ -notin $AllowedNew })
    Assert-Equal ($Tag + ' removed no pre-existing production state entries') 0 $removed.Count ($removed -join ',')
    Assert-Equal ($Tag + ' added no unexpected production state entries') 0 $unexpected.Count ('added=' + ($added -join ',') + '; allowed=' + ($AllowedNew -join ','))
    $preferencePath = Join-Path $StateRoot 'preferences-v4.json'
    $preferenceAfter = Get-FileSha256 $preferencePath
    Assert-Equal ($Tag + ' production preference hash is unchanged') ([string]$BeforePreferenceHash) ([string]$preferenceAfter) ('path=' + $preferencePath)
}

function Assert-ReleaseSelfTestResult {
    param($Result, [string]$Tag)
    Assert-True ($Tag + ' result is an object') ($null -ne $Result) 'null self-test result'
    if ($null -eq $Result) { return $null }

    $version = [string](Get-ReleasePropertyValue $Result 'Version')
    $status = [string](Get-ReleasePropertyValue $Result 'Status')
    $errorText = [string](Get-ReleasePropertyValue $Result 'Error')
    $errors = @(Get-ReleasePropertyValue $Result 'Errors')
    $checks = @(Get-ReleasePropertyValue $Result 'Checks')
    Assert-Equal ($Tag + ' result Version matches version.json') (Get-SjcVersion) $version
    Assert-Equal ($Tag + ' result Status') 'Success' $status
    Assert-True ($Tag + ' result Error field is empty') ([string]::IsNullOrWhiteSpace($errorText)) $errorText
    Assert-Equal ($Tag + ' result Errors array is empty') 0 $errors.Count (($errors | ForEach-Object { [string]$_ }) -join '; ')
    Assert-True ($Tag + ' result contains at least three checks') ($checks.Count -ge 3) ('checks=' + [string]$checks.Count)
    $failedChecks = @($checks | Where-Object { (Get-ReleasePropertyValue $_ 'Passed') -ne $true })
    Assert-Equal ($Tag + ' all SelfTest checks passed') 0 $failedChecks.Count (($failedChecks | ForEach-Object { [string](Get-ReleasePropertyValue $_ 'Name') }) -join '; ')
    $checkNames = (@($checks | ForEach-Object { [string](Get-ReleasePropertyValue $_ 'Name') }) -join ' | ')
    Assert-True ($Tag + ' checks cover sandbox/scan work') ($checkNames -match '(?i:sandbox|scan|沙箱|扫描)') $checkNames
    Assert-True ($Tag + ' checks cover deletion/retention behavior') ($checkNames -match '(?i:delet|clean|keep|preserv|exclu|删除|保留|排除)') $checkNames
    Assert-True ($Tag + ' checks cover GUI state') ($checkNames -match '(?i:gui|界面)') $checkNames
    $boundary = [string](Get-ReleasePropertyValue $Result 'Boundary')
    Assert-True ($Tag + ' Boundary statement is present') (-not [string]::IsNullOrWhiteSpace($boundary)) $boundary

    $sandboxRoot = [string](Get-ReleasePropertyValue $Result 'SandboxRoot')
    $sandboxInfo = Get-ReleaseSandboxInfo $sandboxRoot
    Assert-True ($Tag + ' SandboxRoot is a GUID under production StateRoot\Sandboxes') ([bool]$sandboxInfo.Ok) $sandboxRoot
    Assert-True ($Tag + ' SelfTest sandbox ownership marker exists') ([bool]$sandboxInfo.MarkerExists) ([string]$sandboxInfo.FullPath)
    Assert-True ($Tag + ' SelfTest sandbox files directory exists') ([bool]$sandboxInfo.FilesDirectoryExists) ([string]$sandboxInfo.FullPath)

    $scan = Get-ReleasePropertyValue $Result 'Scan'
    $clean = Get-ReleasePropertyValue $Result 'Clean'
    $gui = Get-ReleasePropertyValue $Result 'Gui'
    Assert-True ($Tag + ' SelfTest includes a Scan result') ($null -ne $scan) ''
    Assert-True ($Tag + ' SelfTest includes a Clean result') ($null -ne $clean) ''
    Assert-True ($Tag + ' SelfTest includes a GUI result') ($null -ne $gui) ''

    if ($null -ne $scan) {
        Assert-Equal ($Tag + ' scan Status') 'Success' ([string](Get-ReleasePropertyValue $scan 'Status')) ([string](Get-ReleasePropertyValue $scan 'Error'))
        Assert-Equal ($Tag + ' scan CandidateCount') 2 ([int64](Get-ReleasePropertyValue $scan 'CandidateCount')) ''
        $categories = @(Get-ReleasePropertyValue $scan 'Categories')
        Assert-Equal ($Tag + ' scan category count') 2 $categories.Count ''
        $scanLog = [string](Get-ReleasePropertyValue $scan 'LogPath')
        Assert-True ($Tag + ' scan log exists') ([IO.File]::Exists($scanLog)) $scanLog
        if ($sandboxInfo.Ok) {
            Assert-True ($Tag + ' scan log is inside the owned sandbox') ($scanLog.StartsWith($sandboxInfo.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)) $scanLog
            $outsideCategories = @($categories | Where-Object {
                $root = [string](Get-ReleasePropertyValue $_ 'Root')
                -not $root.StartsWith($sandboxInfo.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-Equal ($Tag + ' every scan category root is inside the owned sandbox') 0 $outsideCategories.Count (($outsideCategories | ForEach-Object { [string](Get-ReleasePropertyValue $_ 'Root') }) -join '; ')
        }
        $planPath = [string](Get-ReleasePropertyValue $scan 'PlanPath')
        Assert-True ($Tag + ' scan plan is candidates.jsonl') ([IO.File]::Exists($planPath) -and [IO.Path]::GetFileName($planPath) -eq 'candidates.jsonl') $planPath
        if ($sandboxInfo.Ok -and [IO.File]::Exists($planPath)) {
            Assert-True ($Tag + ' sealed plan is inside the owned sandbox task') ($planPath.StartsWith($sandboxInfo.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)) $planPath
            $candidates = @(Get-CandidateLines $planPath)
            Assert-Equal ($Tag + ' sealed plan candidate count') 2 $candidates.Count ''
            $outsideCandidates = @($candidates | Where-Object {
                -not ([string]$_.Path).StartsWith($sandboxInfo.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)
            })
            Assert-Equal ($Tag + ' every sealed candidate is inside the owned sandbox') 0 $outsideCandidates.Count (($outsideCandidates | ForEach-Object { [string]$_.Path }) -join '; ')
        }
    }

    if ($null -ne $clean) {
        Assert-Equal ($Tag + ' clean Status') 'Success' ([string](Get-ReleasePropertyValue $clean 'Status')) ([string](Get-ReleasePropertyValue $clean 'Error'))
        Assert-Equal ($Tag + ' clean Deleted count') 1 ([int64](Get-ReleasePropertyValue $clean 'Deleted')) ''
        Assert-Equal ($Tag + ' clean Skipped count') 1 ([int64](Get-ReleasePropertyValue $clean 'Skipped')) ''
        $cleanLog = [string](Get-ReleasePropertyValue $clean 'LogPath')
        Assert-True ($Tag + ' clean log exists') ([IO.File]::Exists($cleanLog)) $cleanLog
        if ($sandboxInfo.Ok) {
            Assert-True ($Tag + ' clean log is inside the owned sandbox') ($cleanLog.StartsWith($sandboxInfo.FullPath + '\', [StringComparison]::OrdinalIgnoreCase)) $cleanLog
        }
    }

    if ($sandboxInfo.Ok -and $sandboxInfo.FilesDirectoryExists) {
        $filesDirectory = Join-Path $sandboxInfo.FullPath 'files'
        $oldPath = Join-Path $filesDirectory 'owned-old.tmp'
        $newPath = Join-Path $filesDirectory 'owned-new.tmp'
        $keptPath = Join-Path $filesDirectory 'owned-kept.tmp'
        Assert-True ($Tag + ' old owned file was deleted') (-not [IO.File]::Exists($oldPath)) $oldPath
        Assert-True ($Tag + ' new owned file was preserved') ([IO.File]::Exists($newPath)) $newPath
        Assert-True ($Tag + ' excluded owned file was preserved') ([IO.File]::Exists($keptPath)) $keptPath
        $names = @(Get-ChildItem -LiteralPath $filesDirectory -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
        Assert-Equal ($Tag + ' sandbox files after SelfTest') 'owned-kept.tmp,owned-new.tmp' ($names -join ',') ($names -join ',')
        if ([IO.File]::Exists($newPath) -and $null -ne $clean) {
            $newLength = ([IO.FileInfo]::new($newPath)).Length
            $processedBytes = [int64](Get-ReleasePropertyValue $clean 'ProcessedBytes')
            Assert-Equal ($Tag + ' ProcessedBytes matches the deleted synthetic file size') $newLength $processedBytes ('newLength=' + $newLength + '; processed=' + $processedBytes)
        }
    }

    if ($null -ne $gui) {
        $guiName = [string](Get-ReleasePropertyValue $gui 'Name')
        $guiVersion = [string](Get-ReleasePropertyValue $gui 'Version')
        $guiStatus = [string](Get-ReleasePropertyValue $gui 'Status')
        $guiPassedRaw = Get-ReleasePropertyValue $gui 'Passed'
        $guiFailedRaw = Get-ReleasePropertyValue $gui 'Failed'
        $guiSkippedRaw = Get-ReleasePropertyValue $gui 'Skipped'
        Assert-True ($Tag + ' Gui.Name is present') (-not [string]::IsNullOrWhiteSpace($guiName)) $guiName
        Assert-Equal ($Tag + ' Gui.Version matches version.json') (Get-SjcVersion) $guiVersion
        Assert-Equal ($Tag + ' Gui.Status') 'Success' $guiStatus
        $guiPassedOk = (Test-ReleaseStringList $guiPassedRaw) -and @($guiPassedRaw).Count -gt 0 -and @($guiPassedRaw | Where-Object { $_ -isnot [string] }).Count -eq 0
        Assert-True ($Tag + ' Gui.Passed is a non-empty string array, not a boolean') $guiPassedOk ('type=' + $(if ($null -eq $guiPassedRaw) { 'null' } else { $guiPassedRaw.GetType().Name }) + '; value=' + (@($guiPassedRaw) -join ' | '))
        $guiFailedOk = (Test-ReleaseStringList $guiFailedRaw) -and @($guiFailedRaw).Count -eq 0
        Assert-True ($Tag + ' Gui.Failed is an empty array') $guiFailedOk ('type=' + $(if ($null -eq $guiFailedRaw) { 'null' } else { $guiFailedRaw.GetType().Name }) + '; value=' + (@($guiFailedRaw) -join ' | '))
        Assert-True ($Tag + ' Gui.Skipped is an array') (Test-ReleaseStringList $guiSkippedRaw) ('type=' + $(if ($null -eq $guiSkippedRaw) { 'null' } else { $guiSkippedRaw.GetType().Name }))
        if (@($guiSkippedRaw).Count -gt 0) {
            Add-Limitation ($Tag + ' Test-SjcGui Skipped entries: ' + (@($guiSkippedRaw) -join ' | '))
        }
    }

    return [pscustomobject]@{
        SandboxRoot = $sandboxRoot
        SandboxInfo = $sandboxInfo
        Scan = $scan
        Clean = $clean
        Gui = $gui
        Checks = $checks
    }
}

function New-ReleaseSentinel {
    param([string]$Prefix = 'sjc')
    $directory = Join-Path ([IO.Path]::GetTempPath()) ($Prefix + '-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($directory)
    $file = Join-Path $directory 'user-file.txt'
    [IO.File]::WriteAllText($file, ('sentinel-' + [guid]::NewGuid().ToString('N')), [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Directory = $directory; File = $file; Hash = (Get-FileSha256 $file) }
}

function Assert-ReleaseSentinelUnchanged {
    param($Sentinel, [string]$Tag)
    if ($null -eq $Sentinel) {
        Assert-True ($Tag + ' external sentinel was created') $false 'null sentinel'
        return
    }
    Assert-True ($Tag + ' external sentinel file still exists') ([IO.File]::Exists($Sentinel.File)) $Sentinel.File
    Assert-Equal ($Tag + ' external sentinel hash is unchanged') ([string]$Sentinel.Hash) ([string](Get-FileSha256 $Sentinel.File)) $Sentinel.File
}

function Remove-ReleaseSentinel {
    param($Sentinel)
    if ($null -eq $Sentinel) { return }
    try {
        $full = [IO.Path]::GetFullPath($Sentinel.Directory)
        $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        $leaf = [IO.Path]::GetFileName($full)
        if ($full.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and $leaf -match '^sjc-[0-9a-f]{32}$') {
            [IO.Directory]::Delete($full, $true)
        }
    }
    catch { }
}

function Get-ExeIconDelta {
    param([string]$ExePath, [byte[]]$IconBytes)
    # PE resource storage keeps each RT_ICON frame as its own resource blob, so the ICO
    # directory is not copied verbatim. Verify every frame payload is present as a
    # contiguous byte run in the EXE. Returns $null on success, else a diagnostic string.
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not [IO.File]::Exists($ExePath)) { return 'EXE missing' }
    if ($null -eq $IconBytes -or $IconBytes.Length -lt 6) { return 'icon bytes missing' }
    # ISO-8859-1 gives a lossless 1:1 byte<->char map, letting String.IndexOf (native,
    # optimised) search multi-megabyte binaries without a PowerShell byte loop.
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $exeText = $latin1.GetString([IO.File]::ReadAllBytes($ExePath))
    $count = [int][BitConverter]::ToUInt16($IconBytes, 4)
    if ($count -le 0) { return 'icon has no frames' }
    $missing = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $count; $i++) {
        $o = 6 + $i * 16
        $size = $IconBytes[$o]; if ($size -eq 0) { $size = 256 }
        $length = [int][BitConverter]::ToUInt32($IconBytes, $o + 8)
        $offset = [int][BitConverter]::ToUInt32($IconBytes, $o + 12)
        if ($length -le 0 -or ($offset + $length) -gt $IconBytes.Length) { $missing.Add($size.ToString() + ':bad-ico-entry'); continue }
        $frame = New-Object byte[] $length
        [Array]::Copy($IconBytes, $offset, $frame, 0, $length)
        $frameText = $latin1.GetString($frame)
        if ($exeText.IndexOf($frameText, [StringComparison]::Ordinal) -lt 0) { $missing.Add($size.ToString() + ':' + $length + 'B') }
    }
    if ($missing.Count -gt 0) { return ('missing icon frames in EXE: ' + ($missing -join ',')) }
    return $null
}
