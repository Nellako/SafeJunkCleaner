#requires -Version 5.1
# W01: worker boundary - payload schema is an allow-list (no TestRoot/Root), payload and
# output must be direct children of the task, failures are reported as Failed with an
# explicit error, and recycle is refused in test contexts / status codes are mapped.
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
    $context = $sandbox.Context
    $task = New-SjcTaskDirectory -Context $context

    # New contract: Scan/Clean payloads must carry an exact-case CleaningProfile.
    $validScan = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $true }
    $why = ''
    try { Assert-SjcWorkerPayload -Payload $validScan -Mode 'Scan'; $ok = $true } catch { $ok = $false; $why = $_.Exception.Message }
    Assert-True 'valid Scan payload with CleaningProfile is accepted' $ok ([string]$why)

    $validClean = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; ExcludedIds = @(); RecycleMode = $false; CleaningProfile = 'High'; CustomEnabled = $false }
    try { Assert-SjcWorkerPayload -Payload $validClean -Mode 'Clean'; $ok = $true } catch { $ok = $false; $why = $_.Exception.Message }
    Assert-True 'valid Clean payload with CleaningProfile is accepted' $ok ([string]$why)

    $badPayloads = @(
        @{ Name = 'TestRoot in payload is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $true; TestRoot = $sandbox.Root } },
        @{ Name = 'Root in payload is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; Root = 'C:\Temp'; CustomEnabled = $true } },
        @{ Name = 'ApprovedPath in payload is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; ApprovedPath = 'x'; CustomEnabled = $true } },
        @{ Name = 'RuleIds scalar string is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = 'SandboxOld'; CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'RuleIds int array is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @(1, 2); CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'TaskDirectory missing is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'CancelPath non-string is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = 1; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'Clean RecycleMode string is rejected'; Mode = 'Clean'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; ExcludedIds = @(); RecycleMode = 'true'; CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'Clean ExcludedIds scalar is rejected'; Mode = 'Clean'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; ExcludedIds = 'abc'; RecycleMode = $false; CleaningProfile = 'Medium'; CustomEnabled = $true } },
        @{ Name = 'Scan mode rejects Clean-only fields' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; ExcludedIds = @(); RecycleMode = $false; CustomEnabled = $true } },
        @{ Name = 'Scan payload without CleaningProfile is rejected' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CustomEnabled = $true } },
        @{ Name = 'Clean payload without CleaningProfile is rejected' ; Mode = 'Clean'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; ExcludedIds = @(); RecycleMode = $false; CustomEnabled = $true } },
        @{ Name = 'CleaningProfile lowercase is rejected' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'medium'; CustomEnabled = $true } },
        @{ Name = 'CleaningProfile unknown value is rejected' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Maximum'; CustomEnabled = $true } },
        @{ Name = 'CleaningProfile non-string is rejected' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 1; CustomEnabled = $true } },
        @{ Name = 'CleaningProfile empty string is rejected' ; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = ''; CustomEnabled = $true } }
    )
    # CustomEnabled is a mode, so the payload must state it explicitly and as a boolean.
    $modeCases = @(
        @{ Name = 'Scan payload without CustomEnabled is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium' } },
        @{ Name = 'Scan payload with string CustomEnabled is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = 'true' } },
        @{ Name = 'Scan payload with integer CustomEnabled is rejected'; Mode = 'Scan'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; RuleIds = @('SandboxOld'); CleaningProfile = 'Medium'; CustomEnabled = 1 } },
        @{ Name = 'Clean payload without CustomEnabled is rejected'; Mode = 'Clean'; Payload = [pscustomobject]@{ TaskDirectory = $task; CancelPath = ''; ProgressPath = ''; ExcludedIds = @(); RecycleMode = $false; CleaningProfile = 'Medium' } }
    )
    foreach ($bad in $modeCases) {
        $payload = $bad.Payload; $mode = $bad.Mode
        Assert-Throws $bad.Name { Assert-SjcWorkerPayload -Payload $payload -Mode $mode } 'CustomEnabled'
    }
    foreach ($bad in $badPayloads) {
        $payload = $bad.Payload; $mode = $bad.Mode
        Assert-Throws $bad.Name { Assert-SjcWorkerPayload -Payload $payload -Mode $mode } ''
    }
    Assert-Throws 'null payload is rejected' { Assert-SjcWorkerPayload -Payload $null -Mode 'Scan' } ''
    Assert-Throws 'JSON string payload is rejected' { Assert-SjcWorkerPayload -Payload '{"RuleIds":["SandboxOld"]}' -Mode 'Scan' } ''

    # Channels: direct child, reserved names, nesting.
    Assert-Throws 'payload nested in a subdirectory is refused' { Assert-SjcChannel $task (Join-Path $task 'sub\payload.json') } '直接子层'
    Assert-Throws 'payload outside the task is refused' { Assert-SjcChannel $task (Join-Path $sandbox.Root 'payload.json') } '直接子层'
    Assert-Throws 'reserved plan name is refused as a channel' { Assert-SjcChannel $task (Join-Path $task 'candidates.jsonl') } '保留或无效'
    $payloadOut = Assert-SjcChannel $task (Join-Path $task 'payload.json')
    Assert-Throws 'same channel repeated with different casing is refused' { Assert-SjcDistinctChannels @($payloadOut, $payloadOut.ToUpperInvariant()) } '不能重叠'
    $resultOut = Assert-SjcChannel $task (Join-Path $task 'result.json')
    $distinctOk = $true
    try { Assert-SjcDistinctChannels @($payloadOut, $resultOut) } catch { $distinctOk = $false }
    Assert-True 'distinct payload and result channels are accepted' $distinctOk ''

    # Invoke-SjcWorker rejects a payload that is not inside a trusted production task.
    $fakeTaskDir = Join-Path $sandbox.Root ('not-a-task-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($fakeTaskDir)
    $fakePayload = Join-Path $fakeTaskDir 'payload.json'
    [IO.File]::WriteAllText($fakePayload, '{"TaskDirectory":"' + $fakeTaskDir.Replace('\', '\\') + '","CancelPath":"","ProgressPath":"","RuleIds":["SandboxOld"],"CleaningProfile":"Medium","CustomEnabled":true}', $Utf8NoBom)
    $fakeOutput = Join-Path $fakeTaskDir 'result.json'
    $workerResult = Invoke-SjcWorker -TestContext $context -Mode 'Scan' -PayloadPath $fakePayload -OutputPath $fakeOutput
    Assert-True 'worker rejects a payload outside any trusted task directory' ($workerResult.Status -eq 'Failed') ('status=' + $workerResult.Status + '; error=' + $workerResult.Error)
    Assert-True 'rejection names the ownership/task problem' ([string]$workerResult.Error -match '任务|GUID|状态根') ([string]$workerResult.Error)
    Assert-True 'worker wrote no result JSON into an untrusted directory' (-not [IO.File]::Exists($fakeOutput)) $fakeOutput

    $missingResult = Invoke-SjcWorker -TestContext $context -Mode 'Scan' -PayloadPath (Join-Path $sandbox.Root 'missing-payload.json') -OutputPath (Join-Path $sandbox.Root 'out.json')
    Assert-True 'missing payload file yields Failed, not an exception escape' ($missingResult.Status -eq 'Failed') ([string]$missingResult.Error)

    # Recycle: test context is refused and nothing is emptied; status-code matrix is pure.
    $recycle = Invoke-SjcRecycle -Context $context
    Assert-Equal 'recycle in a test context is Failed' 'Failed' ([string]$recycle.Status)
    Assert-True 'recycle refusal names the test-context guard' ([string]$recycle.Error -match '测试上下文禁止') ([string]$recycle.Error)
    Assert-True 'recycle refusal still writes a log' ($recycle.LogPath -and [IO.File]::Exists($recycle.LogPath)) ([string]$recycle.LogPath)
    Add-DeclaredExclusion '生产上下文的 SHEmptyRecycleBin 未调用；只验证了测试上下文拒绝与纯函数状态映射。'
    Assert-Equal 'code 0 maps to Success' 'Success' (Get-SjcRecycleStatus -Code ([uint32]0))
    Assert-Equal 'code 2147500036 maps to Cancelled' 'Cancelled' (Get-SjcRecycleStatus -Code ([uint32]2147500036))
    Assert-Equal 'code 2147943623 maps to Cancelled' 'Cancelled' (Get-SjcRecycleStatus -Code ([uint32]2147943623))
    Assert-Equal 'unknown code maps to Failed' 'Failed' (Get-SjcRecycleStatus -Code ([uint32]5))
    Assert-Equal 'max uint32 maps to Failed, not success' 'Failed' (Get-SjcRecycleStatus -Code ([uint32]4294967295))

    # Task lifecycle: removal needs a completion marker and no active lease.
    $lifecycleTask = New-SjcTaskDirectory -Context $context
    New-TestFile -Path (Join-Path $sandbox.Root 'files\life.tmp') -Bytes 8 -AgeHours 96 | Out-Null
    $lifeScan = Invoke-SjcScan -Context $context -RuleIds @('SandboxOld') -TaskDirectory $lifecycleTask
    Assert-Equal 'lifecycle scan succeeds' 'Success' $lifeScan.Status $lifeScan.Error
    Assert-Throws 'task cannot be removed before it is marked complete' { Remove-SjcTaskDirectory -Context $context -TaskDirectory $lifecycleTask } ''
    Set-SjcTaskCompleted -Context $context -TaskDirectory $lifecycleTask -Status 'Success'
    $lease = Open-SjcTaskLease $lifecycleTask 'worker.active'
    Assert-Throws 'task cannot be removed while a worker lease is active' { Remove-SjcTaskDirectory -Context $context -TaskDirectory $lifecycleTask } ''
    $lease.Dispose()
    Assert-True 'failed active removal clears tombstone' (-not [IO.File]::Exists((Join-Path $lifecycleTask 'task.deleting'))) ''
    $lease = Open-SjcTaskLease $lifecycleTask 'core.active'
    Assert-Throws 'task cannot be removed while core lease is active' { Remove-SjcTaskDirectory -Context $context -TaskDirectory $lifecycleTask } ''
    $lease.Dispose()
    $removed = Remove-SjcTaskDirectory -Context $context -TaskDirectory $lifecycleTask
    Assert-True 'completed, unleased task is removed' ($removed -eq $true -and -not [IO.Directory]::Exists($lifecycleTask)) ([string]$removed)
    Assert-True 'removal does not touch candidate target files' ([IO.File]::Exists((Join-Path $sandbox.Root 'files\life.tmp'))) ''

    $retained=@(Get-ChildItem -LiteralPath (Join-Path $context.StateRoot 'RetainedTasks') -Directory)
    Assert-Equal 'completed test task is retained as one quarantined directory' 1 $retained.Count
    Assert-True 'retained task keeps its owner and completion records' ([IO.File]::Exists((Join-Path $retained[0].FullName '.task-owner')) -and [IO.File]::Exists((Join-Path $retained[0].FullName 'task.completed')))
    Assert-Equal 'retained task has a durable pre-move manifest' 1 (@(Get-ChildItem -LiteralPath (Join-Path $context.StateRoot 'RetainedTasks') -File -Filter '*.manifest.json').Count)
    Add-Limitation 'W01 通过现有 TestContext 调用 Worker；失败日志只写本轮沙箱。测试任务通过相同完成/租约闸门后整目录隔离保留，未删除目录；生产移除分支未执行。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
Complete-TestCase
