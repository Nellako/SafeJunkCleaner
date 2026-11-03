# Worker is an untrusted-message boundary, not an arbitrary path execution API.
function Assert-SjcWorkerPayload {
    param($Payload,[string]$Mode)
    if ($null -eq $Payload -or $Payload -isnot [pscustomobject]) { throw '任务载荷必须是JSON对象。' }
    $allowed=@('TaskDirectory','CancelPath','ProgressPath')
    if ($Mode -eq 'Scan') { $allowed += @('RuleIds','CleaningProfile','CustomEnabled') }
    if ($Mode -eq 'Clean') { $allowed += @('ExcludedIds','RecycleMode','CleaningProfile','CustomEnabled') }
    foreach($property in $Payload.PSObject.Properties.Name) {
        if ($property -notin $allowed) { throw ('未知或不允许的载荷字段：' + $property) }
    }
    foreach($field in @('TaskDirectory','CancelPath','ProgressPath')) {
        if (-not $Payload.PSObject.Properties[$field] -or $Payload.$field -isnot [string]) { throw ($field + ' 必须是字符串。') }
    }
    if ($Mode -in @('Scan','Clean')) {
        if (-not $Payload.PSObject.Properties['CleaningProfile']) { throw '缺少 CleaningProfile，拒绝旧任务载荷。' }
        Assert-SjcCleaningProfile $Payload.CleaningProfile
        if (-not $Payload.PSObject.Properties['CustomEnabled'] -or $Payload.CustomEnabled -isnot [bool]) { throw 'CustomEnabled 必须是显式布尔值，拒绝旧任务载荷。' }
    }
    if ($Mode -eq 'Scan') { Assert-SjcStringArray $Payload.RuleIds 'RuleIds' 10000 }
    if ($Mode -eq 'Clean') {
        Assert-SjcStringArray $Payload.ExcludedIds 'ExcludedIds'
        if ($Payload.RecycleMode -isnot [bool]) { throw 'RecycleMode 必须为布尔值。' }
    }
}
function Invoke-SjcSelfTest {
    param()
    $checks=New-Object 'System.Collections.Generic.List[object]'
    $errors=New-Object 'System.Collections.Generic.List[string]'
    $sandbox=$null; $scan=$null; $clean=$null; $gui=$null
    try {
        $sandbox=New-SjcTestSandbox
        $files=Join-Path $sandbox.Root 'files'
        $old=Join-Path $files 'owned-old.tmp'; $new=Join-Path $files 'owned-new.tmp'; $keep=Join-Path $files 'owned-kept.tmp'
        foreach($path in @($old,$new,$keep)) { Write-SjcAtomicText -Path $path -Text 'SafeJunkCleaner GUID synthetic file only' -NoOverwrite }
        [IO.File]::SetLastWriteTimeUtc($old,[datetime]::UtcNow.AddDays(-4)); [IO.File]::SetLastWriteTimeUtc($keep,[datetime]::UtcNow.AddDays(-4))
        $task=New-SjcTaskDirectory $sandbox.Context
        $scan=Invoke-SjcScan -Context $sandbox.Context -RuleIds @('SandboxOld','SandboxLog') -TaskDirectory $task
        if ($scan.Status -ne 'Success' -or $scan.CandidateCount -ne 2) { throw ('合成扫描失败：' + $scan.Error) }
        [void]$checks.Add([pscustomobject]@{ Name='OwnedSandboxScan'; Passed=$true })
        $candidates=@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 1)
        $all=@(Get-SjcCandidatePage -PlanPath $scan.PlanPath -Limit 1000)
        if ($candidates.Count -ne 1 -or $all.Count -ne 2) { throw '完整封存/分页计数失败。' }
        $exclude=@($all | Where-Object { $_.Path -eq $keep } | ForEach-Object Id)
        if ($exclude.Count -ne 1) { throw '未找到人工保留候选。' }
        $clean=Invoke-SjcClean -Context $sandbox.Context -TaskDirectory $task -ExcludedIds $exclude -RecycleMode $false
        if ($clean.Status -ne 'Success' -or $clean.Deleted -ne 1 -or $clean.Skipped -ne 1 -or [IO.File]::Exists($old) -or -not [IO.File]::Exists($new) -or -not [IO.File]::Exists($keep)) { throw ('合成清理/保留失败：' + $clean.Error) }
        [void]$checks.Add([pscustomobject]@{ Name='OwnedOldFileOnlyDeletionAndExclusion'; Passed=$true })
        [void]$checks.Add([pscustomobject]@{ Name='NewFilePreserved'; Passed=$true })
    } catch { [void]$errors.Add($_.Exception.Message); [void]$checks.Add([pscustomobject]@{Name='CoreSyntheticSmoke'; Passed=$false; Error=$_.Exception.Message}) }
    try {
        if (-not (Get-Command Test-SjcGui -CommandType Function -ErrorAction SilentlyContinue)) { throw '缺少 Test-SjcGui，不计通过。' }
        if ($null -eq $scan -or -not $scan.PlanPath) { throw '缺少真实封存分页计划，GUI自检不能计通过。' }
        $gui=Test-SjcGui -PlanPath $scan.PlanPath
        $passed=$false
        if ($null -ne $gui) {
            if ($gui.PSObject.Properties['Status']) { $passed=($gui.Status -eq 'Success') }
            elseif ($gui.PSObject.Properties['Passed']) { $passed=($gui.Passed -is [bool] -and $gui.Passed) }
        }
        if (-not $passed) { throw 'GUI 无破坏性状态自检未通过。' }
        [void]$checks.Add([pscustomobject]@{Name='GuiStateSmoke'; Passed=$true})
    } catch { [void]$errors.Add($_.Exception.Message); [void]$checks.Add([pscustomobject]@{Name='GuiStateSmoke'; Passed=$false; Error=$_.Exception.Message}) }
    $status=if ($errors.Count -eq 0) { 'Success' } else { 'Failed' }
    $logPath=''
    try {
        if ($sandbox) { $logPath=New-SjcOperationLog $sandbox.Context 'selftest' }
        else { throw '未建立自有测试上下文。' }
    } catch { [void]$errors.Add($_.Exception.Message); $status='Failed' }
    $result=[pscustomobject][ordered]@{ Version=(Get-SjcVersion); Status=$status; Checks=@($checks.ToArray()); Errors=@($errors.ToArray()); Error=($errors -join '; '); LogPath=$logPath; SandboxRoot=$(if($sandbox){$sandbox.Root}else{''}); Scan=$scan; Clean=$clean; Gui=$gui; Boundary='仅删除本进程自建GUID沙箱旧人工文件；保留新文件/排除文件与证据；未清空真实回收站。' }
    if ($logPath) { Complete-SjcOperationLog $result }
    return $result
}
function Invoke-SjcWorker {
    param([ValidateSet('Scan','Clean','Recycle','SelfTest')][string]$Mode,[string]$PayloadPath,[string]$OutputPath)
    $result=$null; $safeOutput=''; $context=$null; $workerLease=$null; $task=''
    try {
    try {
        # Never deserialize a Context, TestRoot or rule Root supplied by a caller.
        $context=New-SjcContext
        if ($Mode -eq 'SelfTest' -and [string]::IsNullOrWhiteSpace($PayloadPath)) {
            if ($OutputPath) {
                $out=Get-SjcFullPath $OutputPath
                $task=Assert-SjcTaskDirectory $context ([IO.Path]::GetDirectoryName($out))
                $safeOutput=Assert-SjcChannel $task $out
                $workerLease=Open-SjcTaskLease $task 'worker.active'
            }
            $result=Invoke-SjcSelfTest
        } else {
            # Derive task from the payload LOCATION first; never its JSON TaskDirectory field.
            $payloadFile=Get-SjcFullPath $PayloadPath
            $task=Assert-SjcTaskDirectory $context ([IO.Path]::GetDirectoryName($payloadFile))
            $payloadFile=Assert-SjcChannel $task $payloadFile
            $output=Assert-SjcChannel $task $OutputPath
            Assert-SjcDistinctChannels @($payloadFile,$output)
            $safeOutput=$output
            $workerLease=Open-SjcTaskLease $task 'worker.active'
            $payload=Read-SjcSafeText $payloadFile | ConvertFrom-Json -ErrorAction Stop
            Assert-SjcWorkerPayload $payload $Mode
            if ($Mode -in @('Scan','Clean')) {
                Set-SjcCleaningProfile -Context $context -CleaningProfile $payload.CleaningProfile
                # Re-discover from this process's trusted sources and the private authorization store, never payload roots.
                [void](Refresh-SjcAuthorizedRules -Context $context)
            }
            if ((Get-SjcFullPath $payload.TaskDirectory) -cne $task) { throw '载荷任务目录与已验证通道目录不一致。' }
            $cancel=Assert-SjcChannel $task $payload.CancelPath -Optional
            $progress=Assert-SjcChannel $task $payload.ProgressPath -Optional
            Assert-SjcDistinctChannels @($payloadFile,$output,$cancel,$progress)
            switch ($Mode) {
                'Scan' { $result=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @($payload.RuleIds) -CancelPath $cancel -ProgressPath $progress -CustomEnabled $payload.CustomEnabled }
                'Clean' { $result=Invoke-SjcClean -Context $context -TaskDirectory $task -ExcludedIds @($payload.ExcludedIds) -RecycleMode $payload.RecycleMode -CancelPath $cancel -ProgressPath $progress -CustomEnabled $payload.CustomEnabled }
                'Recycle' { $result=Invoke-SjcRecycle -Context $context }
                'SelfTest' { $result=Invoke-SjcSelfTest }
            }
        }
    } catch {
        $result=[pscustomobject]@{Version=(Get-SjcVersion); Status='Failed'; Error=$_.Exception.Message; LogPath=''}
        if ($context) {
            try { $result.LogPath=New-SjcOperationLog $context 'worker-failure'; Complete-SjcOperationLog $result }
            catch { $result.Error += '; 无法创建失败日志：' + $_.Exception.Message }
        }
    }
    if ($workerLease) {
        try { Set-SjcTaskCompleted -Context $context -TaskDirectory $task -Status $result.Status }
        catch { $result.Status='Failed'; $result.Error += '; 完成标记写入失败：' + $_.Exception.Message }
    }
    if ($safeOutput) {
        try { Write-SjcAtomicText -Path $safeOutput -Text ($result | ConvertTo-Json -Depth 16 -Compress) }
        catch { $result.Status='Failed'; $result.Error += '; 结果通道写入失败：' + $_.Exception.Message }
    } elseif ($Mode -ne 'SelfTest') {
        $result.Status='Failed'; $result.Error += '; 未验证输出通道，未写入任意外部路径。'
    }
    return $result
    } finally { if ($workerLease) { $workerLease.Dispose() } }
}
