#requires -Version 5.1
# N11: system maintenance launch contract.
# Real: the production launch-spec builder, Start-SjcMaintenance state machine, and the
# real system DISM path used by the spec. Mocked: Get-AuthenticodeSignature for every
# rejection branch and Invoke-SjcMaintenanceProcessStart for Running/Null/Canceled/Failed.
# This case must not trigger UAC, DISM, or any process start.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$LoadGui,
    [string]$ExePath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory
$originalProcessStart = $null
$signatureFunctionInstalled = $false
try {
    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $systemDirectory = [IO.Path]::GetFullPath([Environment]::SystemDirectory)
    $expectedFile = Join-Path $systemDirectory 'dism.exe'

    # ---- 1. Fixed launch spec (real builder, no mocks) -----------------------
    $actions = @(Get-SjcMaintenanceActions)
    Assert-Equal 'exactly one maintenance action is offered' 1 $actions.Count ('count=' + $actions.Count)
    Assert-Equal 'the only action id is ComponentCleanup' 'ComponentCleanup' ([string]$actions[0].Id) ([string]$actions[0].Id)
    Assert-True 'the action exposes a non-empty display name' (-not [string]::IsNullOrWhiteSpace([string]$actions[0].Name)) ([string]$actions[0].Name)

    $specCommand = Get-Command Get-SjcMaintenanceLaunchSpec -CommandType Function
    $actionIdMandatory = $false
    if ($specCommand.Parameters.ContainsKey('ActionId')) {
        $actionIdMandatory = @($specCommand.Parameters['ActionId'].Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and [bool]$_.Mandatory }).Count -gt 0
    }
    Assert-True 'launch spec builder takes a mandatory ActionId parameter' $actionIdMandatory 'ActionId'
    $startCommand = Get-Command Start-SjcMaintenance -CommandType Function
    Assert-True 'Start-SjcMaintenance exposes ActionId and a TestMode switch' ($startCommand.Parameters.ContainsKey('ActionId') -and $startCommand.Parameters.ContainsKey('TestMode') -and $startCommand.Parameters['TestMode'].SwitchParameter) 'ActionId/TestMode'

    $spec = Get-SjcMaintenanceLaunchSpec -ActionId 'ComponentCleanup'
    Assert-Equal 'spec is bound to ComponentCleanup' 'ComponentCleanup' ([string]$spec.ActionId) ([string]$spec.ActionId)
    Assert-True 'spec file is the real system dism.exe' ([string]$spec.FileName).Equals($expectedFile, [StringComparison]::OrdinalIgnoreCase) ('expected=' + $expectedFile + '; actual=' + [string]$spec.FileName)
    Assert-Equal 'spec file leaf is dism.exe' 'dism.exe' ([IO.Path]::GetFileName([string]$spec.FileName)) ([string]$spec.FileName)
    Assert-True 'spec file name is absolute and unquoted' ([IO.Path]::IsPathRooted([string]$spec.FileName) -and -not ([string]$spec.FileName).Contains('"')) ([string]$spec.FileName)
    Assert-True 'spec accumulates no extra switches' ([string]$spec.Arguments -ceq '/Online /Cleanup-Image /StartComponentCleanup') ('arguments=' + [string]$spec.Arguments)
    Assert-True 'spec never contains ResetBase (case-insensitive)' ([string]$spec.Arguments -notmatch '(?i)resetbase') ('arguments=' + [string]$spec.Arguments)
    Assert-True 'spec requests ShellExecute for the runas verb' ([bool]$spec.UseShellExecute) ('UseShellExecute=' + [bool]$spec.UseShellExecute)
    Assert-True 'spec verb is exactly runas' ([string]$spec.Verb -ceq 'runas') ('verb=' + [string]$spec.Verb)
    Assert-True 'spec working directory is the 64-bit system directory' ([string]$spec.WorkingDirectory).Equals($systemDirectory, [StringComparison]::OrdinalIgnoreCase) ('expected=' + $systemDirectory + '; actual=' + [string]$spec.WorkingDirectory)
    Assert-Equal 'spec exposes exactly the six launch fields' 'ActionId,Arguments,FileName,UseShellExecute,Verb,WorkingDirectory' ((@($spec.PSObject.Properties.Name) | Sort-Object) -join ',') ((@($spec.PSObject.Properties.Name) | Sort-Object) -join ',')
    Assert-True 'system dism.exe exists (read-only existence check)' ([IO.File]::Exists($expectedFile)) $expectedFile
    Add-Limitation 'N11 本次只在 64 位进程 + 64 位系统实测；WoW64/Sysnative 分支未测（该分支需 32 位进程，可另用 SysWOW64 PowerShell 独立模拟，本次未做）。'

    $rejectedIds = @('componentcleanup', 'Componentcleanup', 'COMPONENTCLEANUP', 'ComponentCleanUp', ' ComponentCleanup', 'ComponentCleanup ', 'Component-Cleanup', 'ResetBase')
    foreach ($badId in $rejectedIds) {
        Assert-Throws ('unknown action id is rejected case-sensitively: [' + $badId + ']') { Get-SjcMaintenanceLaunchSpec -ActionId $badId } '未知维护操作'
    }
    Assert-Throws 'TestMode does not bypass the unknown-action guard' { Start-SjcMaintenance -ActionId 'ResetBase' -TestMode } '未知维护操作'

    # ---- 2. Signature rejection before any process start --------------------
    $script:n11SignatureCalls = 0
    $script:n11SignatureMode = ''
    function Get-AuthenticodeSignature {
        [CmdletBinding()]
        param([Parameter(Mandatory = $true)][string]$LiteralPath)
        $script:n11SignatureCalls++
        switch ($script:n11SignatureMode) {
            'Invalid' { return [pscustomobject]@{ Status = 'Invalid'; SignerCertificate = $null; Path = $LiteralPath } }
            'ForeignSigner' { return [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Subject = 'CN=Evil, O=Evil Corporation, L=Nowhere, C=US' }; Path = $LiteralPath } }
            'Throw' { throw 'mock-signature-failure' }
            default { throw 'mock-signature-mode-not-set' }
        }
    }
    $signatureFunctionInstalled = $true
    if ((Get-Command Get-AuthenticodeSignature).CommandType -ne 'Function' -or (Get-Command Get-AuthenticodeSignature).Definition -notmatch 'mock-signature-mode-not-set') { throw '签名替身安装失败；禁止继续。' }
    Assert-True 'the signature probe is a test double, not the real cmdlet' ((Get-Command Get-AuthenticodeSignature).CommandType -eq 'Function') ([string](Get-Command Get-AuthenticodeSignature).CommandType)

    $dismBefore = @([Diagnostics.Process]::GetProcessesByName('dism')).Count
    $script:n11SignatureMode = 'Invalid'
    $beforeSignature = $script:n11SignatureCalls
    $invalidError = $null
    try { [void](Invoke-SjcMaintenanceProcessStart -ActionId 'ComponentCleanup') } catch { $invalidError = $_ }
    Assert-True 'an invalid DISM signature aborts the launch' ($null -ne $invalidError) 'expected a signature rejection exception'
    Assert-True 'the invalid-signature error names the signature guard' ($null -ne $invalidError -and $invalidError.Exception.Message -match '签名无效') ([string]$invalidError.Exception.Message)
    Assert-Equal 'the signature guard is consulted exactly once for the invalid status' 1 ($script:n11SignatureCalls - $beforeSignature) ([string]($script:n11SignatureCalls - $beforeSignature))

    $script:n11SignatureMode = 'ForeignSigner'
    $beforeSignature = $script:n11SignatureCalls
    $foreignError = $null
    try { [void](Invoke-SjcMaintenanceProcessStart -ActionId 'ComponentCleanup') } catch { $foreignError = $_ }
    Assert-True 'a valid signature from a non-Microsoft signer is rejected' ($null -ne $foreignError -and $foreignError.Exception.Message -match '签名无效') ([string]$foreignError.Exception.Message)
    Assert-Equal 'the signature guard is consulted exactly once for the foreign signer' 1 ($script:n11SignatureCalls - $beforeSignature) ([string]($script:n11SignatureCalls - $beforeSignature))

    $script:n11SignatureMode = 'Throw'
    $beforeSignature = $script:n11SignatureCalls
    Assert-Throws 'a signature-check failure stops the launch instead of being ignored' { Invoke-SjcMaintenanceProcessStart -ActionId 'ComponentCleanup' } 'mock-signature-failure'
    Assert-Equal 'the failing signature probe is called exactly once' 1 ($script:n11SignatureCalls - $beforeSignature) ([string]($script:n11SignatureCalls - $beforeSignature))

    $beforeSignature = $script:n11SignatureCalls
    Assert-Throws 'unknown action is rejected before the signature probe' { Invoke-SjcMaintenanceProcessStart -ActionId 'resetbase' } '未知维护操作'
    Assert-Equal 'the signature probe is not consulted for an unknown action' 0 ($script:n11SignatureCalls - $beforeSignature) ([string]($script:n11SignatureCalls - $beforeSignature))

    $dismAfter = @([Diagnostics.Process]::GetProcessesByName('dism')).Count
    Assert-Equal 'signature rejection paths start no dism process' $dismBefore $dismAfter ('before=' + $dismBefore + '; after=' + $dismAfter)

    Remove-Item -Path 'Function:\Get-AuthenticodeSignature' -Force
    $signatureFunctionInstalled = $false
    Assert-True 'restoring the signature probe exposes the real cmdlet again' ((Get-Command Get-AuthenticodeSignature).CommandType -eq 'Cmdlet') ([string](Get-Command Get-AuthenticodeSignature).CommandType)
    Add-DeclaredExclusion 'N11 不执行有效 Microsoft 签名后的真实启动路径（会触发 UAC/DISM/真实进程）；签名拒绝与参数契约以外的接受分支未验证。'

    # ---- 3. Start-SjcMaintenance state machine with a process-start double --
    $originalProcessStart = ${function:Invoke-SjcMaintenanceProcessStart}
    $script:n11StartCalls = New-Object 'System.Collections.Generic.List[string]'
    $script:n11StartMode = 'Running'
    $script:n11FakeProcess = [pscustomobject]@{ Id = 424242; HasExited = $false }
    function Invoke-SjcMaintenanceProcessStart {
        param([Parameter(Mandatory = $true)][string]$ActionId)
        [void]$script:n11StartCalls.Add($ActionId)
        switch ($script:n11StartMode) {
            'Running' { return $script:n11FakeProcess }
            'Null' { return $null }
            'Canceled' { throw (New-Object ComponentModel.Win32Exception 1223) }
            'WrappedCanceled' { throw ([System.Management.Automation.RuntimeException]::new('outer', [System.Management.Automation.RuntimeException]::new('middle', (New-Object ComponentModel.Win32Exception 1223)))) }
            'OtherWin32' { throw (New-Object ComponentModel.Win32Exception 5) }
            default { throw 'mock-start-failure' }
        }
    }
    Assert-True 'the process-start probe shadows the production function' ((Get-Command Invoke-SjcMaintenanceProcessStart).CommandType -eq 'Function') ([string](Get-Command Invoke-SjcMaintenanceProcessStart).CommandType)

    $script:n11StartMode = 'Running'
    $testModeError = $null
    $beforeStart = $script:n11StartCalls.Count
    try { [void](Start-SjcMaintenance -ActionId 'ComponentCleanup' -TestMode) } catch { $testModeError = $_ }
    Assert-True 'TestMode refuses to start system maintenance' ($null -ne $testModeError -and $testModeError.Exception.Message -match 'TestMode') ([string]$testModeError.Exception.Message)
    Assert-Equal 'TestMode never reaches the process-start function' 0 ($script:n11StartCalls.Count - $beforeStart) ([string]($script:n11StartCalls.Count - $beforeStart))

    if ((Get-Command Invoke-SjcMaintenanceProcessStart).Definition -notmatch 'mock-start-failure') { throw '维护启动替身安装失败；禁止继续。' }
    $running = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'Running result status is Running' 'Running' ([string]$running.Status) ([string]$running.Status)
    Assert-True 'Running result carries the started process handle' ([object]::ReferenceEquals($running.Process, $script:n11FakeProcess)) 'process reference'
    Assert-True 'Running result leaves ExitCode empty' ($null -eq $running.ExitCode) ([string]$running.ExitCode)
    Assert-Equal 'Running result has no error text' '' ([string]$running.Error) ([string]$running.Error)
    Assert-Equal 'the process-start function received the exact action id' 'ComponentCleanup' ([string]$script:n11StartCalls[$script:n11StartCalls.Count - 1]) ([string]$script:n11StartCalls[$script:n11StartCalls.Count - 1])
    Assert-Equal 'Start-SjcMaintenance returns exactly the four result fields' 'Error,ExitCode,Process,Status' ((@($running.PSObject.Properties.Name) | Sort-Object) -join ',') ((@($running.PSObject.Properties.Name) | Sort-Object) -join ',')

    $script:n11StartMode = 'Null'
    $nullResult = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'a null process handle is reported as Failed' 'Failed' ([string]$nullResult.Status) ([string]$nullResult.Status)
    Assert-True 'a null process handle yields no Process object' ($null -eq $nullResult.Process) 'Process'
    Assert-True 'a null process handle explains the missing handle' ([string]$nullResult.Error -match '未返回进程句柄') ([string]$nullResult.Error)

    $script:n11StartMode = 'Canceled'
    $canceled = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'a direct Win32Exception 1223 is reported as Canceled' 'Canceled' ([string]$canceled.Status) ([string]$canceled.Status)
    Assert-True 'Canceled result has no Process object' ($null -eq $canceled.Process) 'Process'
    Assert-True 'Canceled result keeps the error message' (-not [string]::IsNullOrWhiteSpace([string]$canceled.Error)) ([string]$canceled.Error)
    Assert-True 'Canceled result never reports an exit code' ($null -eq $canceled.ExitCode) ([string]$canceled.ExitCode)

    $script:n11StartMode = 'WrappedCanceled'
    $wrapped = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'a nested Win32Exception 1223 is still reported as Canceled' 'Canceled' ([string]$wrapped.Status) ([string]$wrapped.Status)
    Assert-True 'the nested Canceled error is preserved' (-not [string]::IsNullOrWhiteSpace([string]$wrapped.Error)) ([string]$wrapped.Error)

    $script:n11StartMode = 'OtherWin32'
    $otherWin32 = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'a different Win32 error is reported as Failed' 'Failed' ([string]$otherWin32.Status) ([string]$otherWin32.Status)
    Assert-True 'a different Win32 error keeps its message' (-not [string]::IsNullOrWhiteSpace([string]$otherWin32.Error)) ([string]$otherWin32.Error)

    $script:n11StartMode = 'Generic'
    $generic = Start-SjcMaintenance -ActionId 'ComponentCleanup'
    Assert-Equal 'a non-Win32 exception is reported as Failed' 'Failed' ([string]$generic.Status) ([string]$generic.Status)
    Assert-True 'a non-Win32 exception keeps its message' ([string]$generic.Error -match 'mock-start-failure') ([string]$generic.Error)
    Assert-True 'no failure path returns a process handle' ($null -eq $otherWin32.Process -and $null -eq $generic.Process -and $null -eq $wrapped.Process) 'null process on all failure paths'
    Assert-Equal 'every scenario called the process-start double with ComponentCleanup only' 'ComponentCleanup' ((@($script:n11StartCalls | Select-Object -Unique) -join ',')) ((@($script:n11StartCalls | Select-Object -Unique) -join ','))
    Assert-Equal 'the process-start double was called once per non-TestMode scenario' 6 $script:n11StartCalls.Count ([string]$script:n11StartCalls.Count)

    Set-Item -Path 'Function:\Invoke-SjcMaintenanceProcessStart' -Value $originalProcessStart -Force
    $restoredDefinition = (Get-Command Invoke-SjcMaintenanceProcessStart -CommandType Function).Definition
    Assert-True 'the production process-start function is restored after the double' ($restoredDefinition -eq $originalProcessStart.ToString()) 'definition comparison'

    [void](Save-Evidence 'launch-spec' ([pscustomobject]@{
                ActionId = [string]$spec.ActionId
                FileName = [string]$spec.FileName
                Arguments = [string]$spec.Arguments
                WorkingDirectory = [string]$spec.WorkingDirectory
                UseShellExecute = [bool]$spec.UseShellExecute
                Verb = [string]$spec.Verb
                Host64Bit = [bool][Environment]::Is64BitProcess
            }))
    [void](Save-Evidence 'start-results' ([pscustomobject]@{
                Running = $running.Status
                Null = $nullResult.Status
                Direct1223 = $canceled.Status
                Nested1223 = $wrapped.Status
                OtherWin32 = $otherWin32.Status
                Generic = $generic.Status
                StartCalls = @($script:n11StartCalls)
            }))
    Assert-True 'the sandbox had an ownership marker and no maintenance task was created' (-not [IO.Directory]::Exists((Join-Path $context.StateRoot 'Tasks'))) (Join-Path $context.StateRoot 'Tasks')
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($signatureFunctionInstalled) { try { Remove-Item -Path 'Function:\Get-AuthenticodeSignature' -Force -ErrorAction SilentlyContinue } catch { } }
    if ($originalProcessStart) { try { Set-Item -Path 'Function:\Invoke-SjcMaintenanceProcessStart' -Value $originalProcessStart -Force } catch { } }
}
Complete-TestCase
