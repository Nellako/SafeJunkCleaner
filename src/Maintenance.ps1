function Get-SjcMaintenanceActions {
    return [pscustomobject]@{Id='ComponentCleanup';Name='Windows 组件存储清理'}
}
function Get-SjcMaintenanceLaunchSpec {
    param([Parameter(Mandatory=$true)][string]$ActionId)
    if($ActionId -cne 'ComponentCleanup'){throw '未知维护操作。'}
    $system=[IO.Path]::GetFullPath([Environment]::SystemDirectory)
    $executableDirectory=$system
    if([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess){
        $windows=[IO.Path]::GetFullPath([Environment]::GetFolderPath('Windows'))
        $system=Join-Path $windows 'System32'
        $executableDirectory=Join-Path $windows 'Sysnative'
    }
    return [pscustomobject]@{ActionId='ComponentCleanup';FileName=(Join-Path $executableDirectory 'dism.exe');Arguments='/Online /Cleanup-Image /StartComponentCleanup';WorkingDirectory=$system;UseShellExecute=$true;Verb='runas'}
}
function Invoke-SjcMaintenanceProcessStart {
    param([Parameter(Mandatory=$true)][string]$ActionId)
    $spec=Get-SjcMaintenanceLaunchSpec -ActionId $ActionId
    if(-not [IO.File]::Exists($spec.FileName)){throw '系统 DISM 不存在。'}
    $signature=Get-AuthenticodeSignature -LiteralPath $spec.FileName -ErrorAction Stop
    if($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)'){throw '系统 DISM 签名无效或签名者不是 Microsoft Corporation。'}
    $psi=[Diagnostics.ProcessStartInfo]::new()
    $psi.FileName=$spec.FileName;$psi.Arguments=$spec.Arguments;$psi.WorkingDirectory=$spec.WorkingDirectory;$psi.UseShellExecute=$true;$psi.Verb='runas'
    if (Get-Variable -Scope Script -Name SjcTestIsolationParent -ErrorAction SilentlyContinue) { throw '隔离测试禁止真实维护进程启动（UAC/DISM）。' }
    return [Diagnostics.Process]::Start($psi)
}
function Start-SjcMaintenance {
    param([Parameter(Mandatory=$true)][string]$ActionId,[switch]$TestMode)
    $spec=Get-SjcMaintenanceLaunchSpec -ActionId $ActionId
    if($TestMode){throw 'TestMode 不允许启动系统维护。'}
    try {
        $process=Invoke-SjcMaintenanceProcessStart -ActionId $spec.ActionId
        if($null -eq $process){throw '系统未返回进程句柄。'}
        return [pscustomobject]@{Status='Running';Process=$process;ExitCode=$null;Error=''}
    } catch {
        $e=$_.Exception
        while($e.InnerException){if($e -is [ComponentModel.Win32Exception]){break};$e=$e.InnerException}
        $status=if($e -is [ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223){'Canceled'}else{'Failed'}
        return [pscustomobject]@{Status=$status;Process=$null;ExitCode=$null;Error=$_.Exception.Message}
    }
}
