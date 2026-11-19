#requires -Version 5.1
# Read-only desktop smoke: open the main window, history and the maintenance
# information dialog. Never invoke the cleanup/maintenance confirmation button.
param([Parameter(Mandatory=$true)][string]$Exe,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName UIAutomationClient,UIAutomationTypes,System.Drawing
if(Test-Path -LiteralPath $Evidence){throw 'New evidence directory required'}
[void][IO.Directory]::CreateDirectory($Evidence)
$app=Start-Process -FilePath $Exe -WorkingDirectory ([IO.Path]::GetDirectoryName($Exe)) -PassThru
function Find-OwnElement($property,$value){
    $condition=[Windows.Automation.AndCondition]::new([Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$app.Id),[Windows.Automation.PropertyCondition]::new($property,$value));$deadline=[datetime]::UtcNow.AddSeconds(25)
    do{$item=[Windows.Automation.AutomationElement]::RootElement.FindFirst([Windows.Automation.TreeScope]::Descendants,$condition);if($item){return $item};if($app.HasExited){throw "Product exited: $($app.ExitCode)"};[Threading.Thread]::Sleep(100)}while([datetime]::UtcNow -lt $deadline);throw "Control unavailable: $value"
}
function Click-Id([string]$id){$item=Find-OwnElement ([Windows.Automation.AutomationElement]::AutomationIdProperty) $id; $item.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()}
function Save-Window($window,$name){$r=$window.Current.BoundingRectangle;if($r.Width -le 0 -or $r.Height -le 0){throw 'No window bounds'};$b=[Drawing.Bitmap]::new([int]$r.Width,[int]$r.Height);$g=[Drawing.Graphics]::FromImage($b);try{$g.CopyFromScreen([int]$r.Left,[int]$r.Top,0,0,$b.Size);$b.Save((Join-Path $Evidence $name),[Drawing.Imaging.ImageFormat]::Png)}finally{$g.Dispose();$b.Dispose()}}
try{
    $button=Find-OwnElement ([Windows.Automation.AutomationElement]::AutomationIdProperty) 'AdvancedButton';$app.Refresh();$main=[Windows.Automation.AutomationElement]::FromHandle($app.MainWindowHandle);Save-Window $main 'main.png'
    Click-Id 'LogsToggle';Click-Id 'AdvancedButton';Click-Id 'MaintenanceButton'
    $dialog=Find-OwnElement ([Windows.Automation.AutomationElement]::NameProperty) '系统维护';Save-Window $dialog 'maintenance.png';$name=$main.Current.Name
    $dialog.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();Click-Id 'DraftCancel';$end=[datetime]::UtcNow.AddSeconds(10);while(-not $button.Current.IsEnabled -and [datetime]::UtcNow -lt $end){[Threading.Thread]::Sleep(75)};$main.GetCurrentPattern([Windows.Automation.WindowPattern]::Pattern).Close();if(-not $app.WaitForExit(15000)){throw 'Window failed to exit'}
    [IO.File]::WriteAllText((Join-Path $Evidence 'result.json'),(@{Passed=$true;Window=$name;EXESha256=(Get-FileHash -LiteralPath $Exe).Hash;ProcessId=$app.Id;HistoryOpened=$true;MaintenanceDialogOpened=$true;DismStarted=$false;OrdinaryExit=$true}|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
}finally{if(-not $app.HasExited){[void]$app.CloseMainWindow();if(-not $app.WaitForExit(2000)){$app.Kill();$app.WaitForExit()}};$app.Dispose()}
