#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Gui','Scan','Clean','Recycle','SelfTest')]
    [string]$WorkerMode = 'Gui',
    [string]$PayloadPath,
    [string]$OutputPath,
    [string]$SelfTestParentDirectory = ''
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ps2exe uses the framework host defaults, unlike powershell.exe. Keep ordinary
# long local paths usable without changing OS policy or the path safety checks.
[AppContext]::SetSwitch('Switch.System.IO.UseLegacyPathHandling',$false)
[AppContext]::SetSwitch('Switch.System.IO.BlockLongPaths',$false)

if ($SelfTestParentDirectory -and ($WorkerMode -ne 'SelfTest' -or $PayloadPath -or $OutputPath)) { throw 'SelfTestParentDirectory 仅允许无载荷、无外部输出通道的 SelfTest。' }
$script:SjcEntryPath = $PSCommandPath
$script:SjcIsPackaged = [string]::IsNullOrWhiteSpace($script:SjcEntryPath)
if ($script:SjcIsPackaged) {
    $script:SjcEntryPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# <SJC-MODULES>

if (-not (Get-Command Start-SjcGui -ErrorAction SilentlyContinue)) {
    foreach ($moduleName in @('Version.ps1','Rules.ps1','Core.ps1','Discovery.ps1','Maintenance.ps1','Worker.ps1','Gui.ps1','ExplorerGui.ps1')) {
        . (Join-Path $PSScriptRoot $moduleName)
    }
}

$script:SjcVersion = Get-SjcVersion

if ($WorkerMode -eq 'Gui') {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'Please launch the desktop application with Windows PowerShell -STA.'
    }
    Start-SjcGui
} else {
    try {
        $result = Invoke-SjcWorker -Mode $WorkerMode -PayloadPath $PayloadPath -OutputPath $OutputPath -SelfTestParentDirectory $SelfTestParentDirectory
        if ($null -eq $result) { throw 'Worker returned no result.' }
        if (-not $script:SjcIsPackaged) { $result | ConvertTo-Json -Depth 12 -Compress | Write-Output }
        if ($result.Status -ne 'Success') { exit 1 }
        exit 0
    } catch {
        if (-not $script:SjcIsPackaged) { [Console]::Error.WriteLine($_.Exception.Message) }
        exit 1
    }
}
