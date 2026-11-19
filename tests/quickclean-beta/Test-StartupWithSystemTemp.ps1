# Native startup check; no scan, delete, recycle or maintenance commands.
param([Parameter(Mandatory=$true)][string]$Exe,[Parameter(Mandatory=$true)][string]$Output)
$ErrorActionPreference='Stop'
if (Test-Path -LiteralPath $Output) { throw 'New evidence file required' }
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes
$psi=[Diagnostics.ProcessStartInfo]::new($Exe)
$psi.UseShellExecute=$false
$psi.WorkingDirectory=[IO.Path]::GetDirectoryName($Exe)
$psi.EnvironmentVariables['TEMP']='C:\WINDOWS\TEMP'
$psi.EnvironmentVariables['TMP']='C:\WINDOWS\TEMP'
$p=[Diagnostics.Process]::Start($psi)
function Find-OwnId([string]$id) {
    $cond=[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id),[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty,$id))
    return [Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$cond)
}
try {
    $deadline=[datetime]::UtcNow.AddSeconds(20)
    do { if($p.HasExited){throw "EXE exited at startup: $($p.ExitCode)"};$control=Find-OwnId 'LogsToggle';if($control){break};Start-Sleep -Milliseconds 150 } while([datetime]::UtcNow -lt $deadline)
    if(-not $control){throw 'Native main window did not become ready'}
    $p.Refresh();$window=[Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle);$title=$window.Current.Name
    $control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline=[datetime]::UtcNow.AddSeconds(6)
    do { $r=Find-OwnId 'HistoryList';if($r -and -not $r.Current.IsOffscreen){break};Start-Sleep -Milliseconds 100 } while([datetime]::UtcNow -lt $deadline)
    if(-not $r -or $r.Current.IsOffscreen){throw 'History panel did not open'}
    if(-not $p.CloseMainWindow() -or -not $p.WaitForExit(10000) -or $p.ExitCode -ne 0){throw 'EXE did not close normally'}
    [IO.File]::WriteAllText($Output,(@{Passed=$true;Temp=$psi.EnvironmentVariables['TEMP'];EXEsha256=(Get-FileHash -LiteralPath $Exe).Hash;MainWindow=$title;HistoryOpened=$true;NormalExit=$true;DestructiveActionRun=$false}|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
} finally {
    if(-not $p.HasExited){$null=$p.CloseMainWindow();if(-not $p.WaitForExit(2000)){$p.Kill();$p.WaitForExit()}}
    $p.Dispose()
}
