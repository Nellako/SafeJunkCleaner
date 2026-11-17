#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$ResultPath)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $ResultPath){throw 'New result path required.'}
. (Join-Path $Repository 'src\ExplorerGui.ps1')
$realApprovalView=${function:Update-SjcExplorerApprovalView}
function New-SjcExplorerSession { param($LaunchSpec,$AppRoot); throw 'UI-only regression: Host disabled.' }
function Get-SjcExplorerFixedDisks { @('C:\') }
function Update-SjcExplorerApprovalView { param($W,$S) }
function Get-SjcExplorerHeadline { param($S); 'synthetic task' }
$checks=[Collections.Generic.List[object]]::new()
function Check([string]$Name,[bool]$Passed){$checks.Add([pscustomobject]@{Name=$Name;Passed=$Passed});if(-not $Passed){throw ('Failed: '+$Name)}}
function Flush-DiskEvents {
    $frame=[Windows.Threading.DispatcherFrame]::new();$timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[timespan]::FromMilliseconds(60);$timer.Add_Tick({$frame.Continue=$false}.GetNewClosure());$timer.Start()
    try{[Windows.Threading.Dispatcher]::PushFrame($frame)}finally{$timer.Stop()}
}
$w=$null
try{
    $w=Open-SjcExplorerWindow $null $null -NoShow
    $w.Tag.Timer.Stop()
    $w.WindowStartupLocation='Manual';$w.Left=-32000;$w.Top=-32000;$w.ShowActivated=$false
    $w.Show()
    $c=$w.Tag.Controls;$c.StateText.Text='synthetic task'
    Check 'initial drive choice is the sole C drive without needing another value' ($c.DiskCombo.SelectedIndex -eq 0 -and [string]$c.DiskCombo.SelectedItem -eq 'C:\')
    $c.FolderPathBox.Text='E:\artificial-selection-not-scanned'
    $c.DiskCombo.IsDropDownOpen=$true;Flush-DiskEvents;$c.DiskCombo.IsDropDownOpen=$false;Flush-DiskEvents
    Check 'accepting already selected C drive writes it to folder input on first use' ($c.FolderPathBox.Text -eq 'C:\' -and $w.Tag.Scope -eq 'C:\' -and $c.ScopeFolderRadio.IsChecked)
    $c.FolderPathBox.Text='E:\manual-path-retained'
    $c.DiskCombo.IsDropDownOpen=$true;Flush-DiskEvents
    $escape=[Windows.Input.KeyEventArgs]::new([Windows.Input.Keyboard]::PrimaryDevice,[Windows.PresentationSource]::FromVisual($w),0,[Windows.Input.Key]::Escape)
    $escape.RoutedEvent=[Windows.Input.Keyboard]::PreviewKeyDownEvent;$c.DiskCombo.RaiseEvent($escape);$c.DiskCombo.IsDropDownOpen=$false;Flush-DiskEvents
    Check 'Escape closes quick drive menu without overwriting manual path' ($c.FolderPathBox.Text -eq 'E:\manual-path-retained')
    $s=@{State='Inventory';HostReady=$true;Fault=$null;Closing=$false;TaskId='11111111-2222-4333-8444-555555555555';InFlight=$null;Queue=[Collections.Generic.List[hashtable]]::new();Exec=$null;Analysis=$null;CanInventory=$true;ProgressDirty=$false;GroupsDirty=$false;SpaceDirty=$false;EvidenceDirty=$false}
    foreach($phase in 'Idle','Polling','Queued','Responded'){
        $s.Queue.Clear();$s.InFlight=$null
        if($phase -eq 'Polling'){$s.InFlight=@{Op='GetProgress'}}
        if($phase -eq 'Queued'){$s.Queue.Add(@{Op='QueryGroups'});$s.Queue.Add(@{Op='GetProgress'})}
        Update-SjcExplorerWindow $w $s
        Check ('pause stable during '+$phase) ([bool]$c.PauseButton.IsEnabled)
        Check ('cancel stable during '+$phase) ([bool]$c.CancelButton.IsEnabled)
        Check ('resume disabled during inventory '+$phase) (-not $c.ResumeButton.IsEnabled)
    }
    $s.Queue.Clear();$s.InFlight=@{Op='GetProgress'}
    Invoke-SjcExplorerTaskCommand $s 'Pause'
    Invoke-SjcExplorerTaskCommand $s 'Pause'
    Invoke-SjcExplorerTaskCommand $s 'Cancel'
    Check 'one control command while polling; repeated or conflicting clicks ignored' ($s.Queue.Count -eq 1 -and $s.Queue[0].Op -eq 'Pause')
    Update-SjcExplorerWindow $w $s
    Check 'pending control disables pause and cancel' (-not $c.PauseButton.IsEnabled -and -not $c.CancelButton.IsEnabled)
    $s.Queue.Clear();$s.InFlight=@{Op='Pause'}
    Update-SjcExplorerWindow $w $s
    Check 'in-flight control disables task controls' (-not $c.PauseButton.IsEnabled -and -not $c.ResumeButton.IsEnabled -and -not $c.CancelButton.IsEnabled)
    $s.InFlight=@{Op='GetProgress'};$s.State='Paused'
    Update-SjcExplorerWindow $w $s
    Check 'paused task enables resume and cancel even during polling' ($c.ResumeButton.IsEnabled -and $c.CancelButton.IsEnabled -and -not $c.PauseButton.IsEnabled)
    Invoke-SjcExplorerTaskCommand $s 'Resume'
    Invoke-SjcExplorerTaskCommand $s 'Resume'
    Check 'resume is deduplicated' ($s.Queue.Count -eq 1 -and $s.Queue[0].Op -eq 'Resume')
    $s.Queue.Clear();$s.InFlight=$null;$s.State='Ready'
    Update-SjcExplorerWindow $w $s
    Check 'terminal task disables all task controls' (-not $c.PauseButton.IsEnabled -and -not $c.ResumeButton.IsEnabled -and -not $c.CancelButton.IsEnabled)
    $s.State='Partial';$s.Reason='SkippedOrUncoveredObjects';$s.Coverage=@{ObservedObjects=30;PendingDirectories=0;SkippedObjects=3;ObservedLogicalBytes=10;ObservedAllocatedBytes=10;UnknownAllocationObjects=0};$s.SkippedReasons=[Collections.Generic.Dictionary[string,object]]::new();$s.SkippedReasons['LinkOrCloud']=2;$s.SkippedReasons['MetadataUnavailable']=1
    Check 'partial inventory headline distinguishes coverage gaps from a scan crash' ((Get-SjcExplorerCoverageExplanation $s) -match '链接或云占位 2' -and (Get-SjcExplorerCoverageExplanation $s) -match '路径或属性不可读 1')
    $s.Reason=$null;$s.State='Ready'
    $s.State='Inventory';$s.ScanMetrics=@{ElapsedMilliseconds=61000};$s.RecentObjectsPerSecond=125.0;$s.LastAdvanceAt=[datetime]::UtcNow;$s.ProgressDirty=$false
    Update-SjcExplorerWindow $w $s
    Check 'actual progress label shows Host elapsed and committed object speed' ($c.ProgressDetailText.Text -like '*00:01:01*' -and $c.ProgressDetailText.Text -like '*125*个对象/秒*' -and $c.PauseButton.IsEnabled -and $c.CancelButton.IsEnabled)
    $s.InFlight=@{Op='GetProgress'};$s.InFlightStartedAt=[datetime]::UtcNow.AddSeconds(-4)
    Update-SjcExplorerWindow $w $s
    Check 'waiting message updates without disabling controls' ($c.ProgressDetailText.Text -like '*等待扫描服务回应*' -and $c.PauseButton.IsEnabled -and $c.CancelButton.IsEnabled)
    $s.InFlight=$null;$s.State='Inventory';$s.Fault='synthetic failure'
    Update-SjcExplorerWindow $w $s
    Check 'fault disables task controls' (-not $c.PauseButton.IsEnabled -and -not $c.CancelButton.IsEnabled)
    $s.Fault=$null;$s.Closing=$true
    Update-SjcExplorerWindow $w $s
    Check 'closing disables task controls' (-not $c.PauseButton.IsEnabled -and -not $c.CancelButton.IsEnabled)

    # ---- UI-LAYOUT-01: native review list viewport readability at 1040x720 -> 820x560 -> 1040x720 ----
    Set-Item -Path 'Function:\Update-SjcExplorerApprovalView' -Value $realApprovalView -Force
    function Get-VisualDescendants($Node,[type]$TargetType){
        $found=@()
        for($ci=0;$ci -lt [Windows.Media.VisualTreeHelper]::GetChildrenCount($Node);$ci++){
            $child=[Windows.Media.VisualTreeHelper]::GetChild($Node,$ci)
            if($child -is $TargetType){$found+=,$child}
            $found+=@(Get-VisualDescendants $child $TargetType)
        }
        return $found
    }
    function Get-ListClippedVisibleHeight($Element){
        $rect=[Windows.Rect]::new(0,0,$Element.ActualWidth,$Element.ActualHeight)
        $rect=$Element.TransformToAncestor($w).TransformBounds($rect)
        $anc=[Windows.Media.VisualTreeHelper]::GetParent($Element)
        while($anc -and $anc -ne $w){
            if($anc -is [Windows.UIElement] -and $anc.ClipToBounds){
                $ar=[Windows.Rect]::new(0,0,$anc.RenderSize.Width,$anc.RenderSize.Height)
                $rect.Intersect($anc.TransformToAncestor($w).TransformBounds($ar))
            }
            $anc=[Windows.Media.VisualTreeHelper]::GetParent($anc)
        }
        $listBounds=$c.DraftList.TransformToAncestor($w).TransformBounds([Windows.Rect]::new(0,0,$c.DraftList.ActualWidth,$c.DraftList.ActualHeight))
        $rect.Intersect($listBounds)
        $anc=$Element
        while($anc -and $anc -ne $w){
            if($anc -is [Windows.Controls.ScrollContentPresenter]){
                $vp=$anc.TransformToAncestor($w).TransformBounds([Windows.Rect]::new(0,0,$anc.ActualWidth,$anc.ActualHeight))
                $rect.Intersect($vp)
            }
            $anc=[Windows.Media.VisualTreeHelper]::GetParent($anc)
        }
        if($rect.IsEmpty){return 0.0}
        return [double]$rect.Height
    }
    $ls=@{HostReady=$true;CanInventory=$true;Fault=$null;Closing=$false;InFlight=$null;Queue=[Collections.Generic.List[hashtable]]::new();TaskId='11111111-1111-4111-8111-111111111111';State='Ready';Revision=3;ParentId=$null;Operations=@('ConfirmApproval','ExecuteApproved');Capabilities=@{RecycleAvailable=$true};Stderr=[Collections.Generic.List[string]]::new();ProgressDirty=$false;GroupsDirty=$false;SpaceDirty=$false;EvidenceDirty=$false;Mode='LocalExploration';LastError=$null;Reason=$null;Coverage=$null}
    Initialize-SjcExplorerApprovalState $ls
    $h64='a'*64
    $ls.Draft=@{Pending=$false;DraftId='22222222-2222-4222-8222-222222222222';DisplayHash=$h64;DisplayedHash=$h64;CandidateSetHash=('b'*64);LogicalBytes=200;ItemCount=2;RecycleEnabled=$true;ConfirmError=$null}
    $ls.DraftItems=@(
        @{SuggestionId='33333333-3333-4333-8333-333333333333';File=@{ObjectId='11';Path='E:\synthetic-review\demo-project\bin\demo.dll';Identity='1:1';Size=100;ModifiedUtc='2026-11-17T00:00:00Z'};Ancestors=@();RetainedCopies=@()},
        @{SuggestionId='33333333-3333-4333-8333-333333333333';File=@{ObjectId='12';Path='E:\synthetic-review\demo-project\bin\demo.deps.json';Identity='1:2';Size=100;ModifiedUtc='2026-11-17T00:00:00Z'};Ancestors=@();RetainedCopies=@()}
    )
    $ls.DraftDirty=$true;$ls.Approval=@{ApprovalId='44444444-4444-4444-8444-444444444444';CanExecute=$true;RecycleEnabled=$true;DisplayHash=$h64};$ls.ApprovalDirty=$true
    $c.MainTabs.SelectedItem=$c.SuggestTab
    foreach($step in @(@('default-before',1040,720,2),@('minimum',820,560,1),@('default-restored',1040,720,2))){
        $w.Width=$step[1];$w.Height=$step[2];Update-SjcExplorerWindow $w $ls;$w.UpdateLayout();Flush-DiskEvents;$w.UpdateLayout()
        $readable=0
        for($ri=0;$ri -lt $c.DraftList.Items.Count;$ri++){
            $container=$c.DraftList.ItemContainerGenerator.ContainerFromIndex($ri)
            if($container -and (Get-ListClippedVisibleHeight $container) -ge 18){$readable++}
        }
        $scp=@(Get-VisualDescendants $c.DraftList ([Windows.Controls.ScrollContentPresenter]) | Where-Object {$_.Name -eq 'PART_ScrollContentPresenter'})
        $btnRect=$c.ExecuteButton.TransformToAncestor($w).TransformBounds([Windows.Rect]::new(0,0,$c.ExecuteButton.ActualWidth,$c.ExecuteButton.ActualHeight))
        Check ('review layout '+$step[0]+' keeps readable file rows and visible action bar') ($readable -ge $step[3] -and $scp.Count -eq 1 -and $scp[0].ActualHeight -ge 24 -and $c.ExecuteButton.IsEnabled -and $btnRect.Bottom -le $w.ActualHeight)
    }

    $result=@{Passed=$true;Assertions=$checks.Count;Checks=$checks.ToArray();HostStarted=$false;InventoryRequests=0;DeletionRequests=0;GuiSourceSHA256=(Get-FileHash -LiteralPath (Join-Path $Repository 'src\ExplorerGui.ps1') -Algorithm SHA256).Hash}
    [IO.File]::WriteAllText($ResultPath,($result|ConvertTo-Json -Depth 6),(New-Object Text.UTF8Encoding($false)))
    $result|ConvertTo-Json -Depth 6
}finally{if($w){$w.Close()}}
