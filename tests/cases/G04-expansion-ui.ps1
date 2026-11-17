#requires -Version 5.1
# G04: v0.12.0 popup/authorization/maintenance UI contract. STA + real WPF construction,
# no UI automation, no MessageBox, no production worker, no real DISM/UAC.
# Windows are built and closed programmatically; the main window gets a native handle
# (WindowInteropHelper.EnsureHandle) but is never shown, so nothing appears on screen.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$LoadGui,
    [string]$ExePath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui
$app = $null
$mainWindow = $null
try {
    Assert-True 'GUI module is loaded for real WPF construction' ($script:GuiModuleLoaded) 'src/Gui.ps1'
    Assert-True 'the case runs on an STA thread (WPF requirement)' ([Threading.Thread]::CurrentThread.ApartmentState -eq 'STA') ([string][Threading.Thread]::CurrentThread.ApartmentState)

    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $files = Join-Path $sandbox.Root 'files'

    # ---- 1. TestMode refuses production / fabricated contexts ----------------
    $prodRootBytesBefore = if ([IO.File]::Exists((Join-Path $script:ProdStateRoot 'preferences-v4.json'))) { (Get-FileHash -LiteralPath (Join-Path $script:ProdStateRoot 'preferences-v4.json') -Algorithm SHA256).Hash } else { '<absent>' }
    $fabricated = [pscustomobject]@{ Version = 'fake'; StateRoot = (Join-Path $sandbox.Root 'fake-state'); Rules = @(); CleaningProfile = 'Medium' }
    Assert-Throws 'a fabricated context is rejected even with -TestMode' { New-SjcGuiState $fabricated -TestMode } '可信上下文'
    Assert-Throws 'a fabricated context is rejected without -TestMode' { New-SjcGuiState $fabricated } '可信上下文'

    $originalContextConfig = ${function:Get-SjcContextConfiguration}
    $script:g04IsTest = $false
    function Get-SjcContextConfiguration {
        param($Context)
        return [pscustomobject]@{ IsTest = $script:g04IsTest; TestRoot = ''; StateRoot = (Join-Path $sandbox.Root 'fake-state'); CleaningProfile = 'Medium' }
    }
    try {
        $script:g04IsTest = $false
        $prodGate = $null
        $received = $null
        try { $received = New-SjcGuiState $fabricated -TestMode } catch { $prodGate = $_ }
        Assert-True 'TestMode rejects a context whose configuration is not a test context' ($null -ne $prodGate) 'expected a rejection'
        Assert-True 'the production-context rejection names IsTest and forgery' ($null -ne $prodGate -and $prodGate.Exception.Message -match 'IsTest|伪造') ([string]$prodGate.Exception.Message)
        Assert-True 'a refused TestMode returns no state object at all' ($null -eq $received) ('received=' + [string]$received)
    }
    finally {
        Set-Item -Path 'Function:\Get-SjcContextConfiguration' -Value $originalContextConfig -Force
    }
    Assert-True 'the context-configuration probe is restored to the production definition' ((Get-Command Get-SjcContextConfiguration).Definition -eq $originalContextConfig.ToString()) 'definition comparison'
    $prodRootBytesAfter = if ([IO.File]::Exists((Join-Path $script:ProdStateRoot 'preferences-v4.json'))) { (Get-FileHash -LiteralPath (Join-Path $script:ProdStateRoot 'preferences-v4.json') -Algorithm SHA256).Hash } else { '<absent>' }
    Assert-Equal 'refused TestMode attempts leave the production preferences file untouched' $prodRootBytesBefore $prodRootBytesAfter ('before=' + [string]$prodRootBytesBefore + '; after=' + [string]$prodRootBytesAfter)
    Add-Limitation 'G04 只在证据目录下的自有沙箱写入；正式 preferences-v4.json 哈希及 Harness 正式状态树前后快照均需不变，未创建正式上下文。'

    $state = New-SjcGuiState $context -TestMode
    $app = New-SjcGuiApp $state
    $mainWindow = $app.Ui.Window
    Assert-True 'TestMode is recorded on the state' ([bool]$state.TestMode) ([string]$state.TestMode)
    [void]([Windows.Interop.WindowInteropHelper]::new($mainWindow)).EnsureHandle()
    Assert-True 'the main window has a native handle but is never shown' (-not $mainWindow.IsVisible -and -not $mainWindow.IsLoaded) ('IsVisible=' + $mainWindow.IsVisible + '; IsLoaded=' + $mainWindow.IsLoaded)
    Add-Limitation 'G04 用 WindowInteropHelper.EnsureHandle 给主窗建立原生句柄以便设置子窗 Owner，但不调用 Show/ShowDialog，不产生可见桌面窗口；真实桌面布局与 DPI 由主对话验收。'

    $draft = @{ App = $app; Window = $mainWindow }

    # A scan stand-in so window lifecycles can be proven to leave scans untouched.
    $scanSentinel = [pscustomobject]@{ Status = 'Success'; CleaningProfile = $state.Profile; CustomEnabled = $false; CandidateCount = 0; CandidateBytes = [int64]0; PlanPath = ''; Categories = @() }
    $state.Scan = $scanSentinel
    $state.Stale = $false
    $state.TaskDirectory = 'sentinel-task'

    # ---- 2. Discovery: stale authorization enables, valid authorization does not
    $source = Join-Path $files 'nuget-http'
    $layoutLeaf = ('a' * 40) + '$TestPkg'
    $layout = Join-Path $source $layoutLeaf
    [void][IO.Directory]::CreateDirectory($layout)
    [IO.File]::WriteAllText((Join-Path $layout 'list_testpkg.dat'), 'x')
    Set-SjcTestDiscoverySources -Context $context -Sources @([pscustomobject]@{ Adapter = 'NuGetHttp'; Value = $source })

    $initialLocations = @(Get-SjcDiscoveredCacheLocations -Context $context)
    Assert-Equal 'the sandbox discovery source yields a supported pending candidate' 'PendingAuthorization' ([string]$initialLocations[0].Status) ([string]$initialLocations[0].Status)
    Assert-True 'the pending candidate is supported and not yet authorized' ([bool]$initialLocations[0].Supported -and -not [bool]$initialLocations[0].Authorized) ('Supported=' + $initialLocations[0].Supported + '; Authorized=' + $initialLocations[0].Authorized)

    $discovery = New-SjcGuiDiscoveryWindow $draft
    $list = $discovery.Tag.List
    Assert-Equal 'the discovery window lists every discovered candidate' $initialLocations.Count (@($list.Items).Count) ([string](@($list.Items).Count))
    $pendingItem = @($list.Items)[0]
    $list.SelectedItem = $pendingItem
    Assert-True 'a pending supported candidate can be approved' ([bool]$discovery.Tag.ApproveButton.IsEnabled) ('status=' + [string]$pendingItem.Tag.Status)
    $revisionBeforeDiscoveryClose = (Read-SjcCacheAuthorizations -Context $context).Revision
    $discovery.Close()
    Assert-Equal 'closing the discovery window writes no authorization' $revisionBeforeDiscoveryClose (Read-SjcCacheAuthorizations -Context $context).Revision ([string](Read-SjcCacheAuthorizations -Context $context).Revision)

    # Valid authorization: Supported=true, Authorized=true, Status=Authorized.
    $null = Approve-SjcCacheLocations -Context $context -Ids ([string[]]@($initialLocations[0].Id)) -ExpectedBindings ([string[]]@($initialLocations[0].Binding))
    $authorizedLocations = @(Get-SjcDiscoveredCacheLocations -Context $context)
    Assert-Equal 'the approved candidate reports Authorized' 'Authorized' ([string]$authorizedLocations[0].Status) ([string]$authorizedLocations[0].Status)
    Assert-True 'the approved candidate keeps its supported binding' ([bool]$authorizedLocations[0].Supported -and -not [string]::IsNullOrWhiteSpace([string]$authorizedLocations[0].Binding)) ([string]$authorizedLocations[0].Binding)
    $authorizationAfterApprove = (Read-SjcCacheAuthorizations -Context $context).Revision

    $discoveryValid = New-SjcGuiDiscoveryWindow $draft
    $validItem = @($discoveryValid.Tag.List.Items)[0]
    $discoveryValid.Tag.List.SelectedItem = $validItem
    Assert-True 'a currently authorized candidate cannot be approved again (button disabled)' (-not [bool]$discoveryValid.Tag.ApproveButton.IsEnabled) ('status=' + [string]$validItem.Tag.Status + '; authorized=' + [bool]$validItem.Tag.Authorized)
    # Approve via the change entry must not write while TestMode is on (no MessageBox path).
    Invoke-SjcGuiDiscoveryChange $discoveryValid.Tag 'Approve'
    Assert-Equal 'TestMode Approve on a valid authorization writes no authorization' $authorizationAfterApprove (Read-SjcCacheAuthorizations -Context $context).Revision ([string](Read-SjcCacheAuthorizations -Context $context).Revision)
    $discoveryValid.Close()

    # Stale authorization: Supported=true, Authorized=true, Status=StaleAuthorization.
    [void](Move-OwnedTestDirectoryToEvidence -Path $source)
    [void][IO.Directory]::CreateDirectory($layout)
    [IO.File]::WriteAllText((Join-Path $layout 'list_testpkg.dat'), 'x')
    $staleLocations = @(Get-SjcDiscoveredCacheLocations -Context $context)
    Assert-Equal 'replacing the directory identity invalidates the old authorization' 'StaleAuthorization' ([string]$staleLocations[0].Status) ([string]$staleLocations[0].Status)
    Assert-True 'a stale authorization is still Supported=true (layout matches again)' ([bool]$staleLocations[0].Supported) ('Supported=' + $staleLocations[0].Supported)
    Assert-True 'the stale candidate keeps Authorized=true for the revoke/confirm flow' ([bool]$staleLocations[0].Authorized) ('Authorized=' + $staleLocations[0].Authorized)
    Assert-True 'the stale binding differs from the approved binding' ([string]$staleLocations[0].Binding -cne [string]$authorizedLocations[0].Binding) 'binding changed'

    $discoveryStale = New-SjcGuiDiscoveryWindow $draft
    $staleItem = @($discoveryStale.Tag.List.Items)[0]
    $discoveryStale.Tag.List.SelectedItem = $staleItem
    Assert-True 'a stale but supported candidate may be re-confirmed (button enabled)' ([bool]$discoveryStale.Tag.ApproveButton.IsEnabled) ('status=' + [string]$staleItem.Tag.Status + '; supported=' + [bool]$staleItem.Tag.Supported)
    $authorizationBeforeStaleClick = (Read-SjcCacheAuthorizations -Context $context).Revision
    Invoke-SjcGuiDiscoveryChange $discoveryStale.Tag 'Approve'
    Assert-Equal 'TestMode Approve on a stale candidate writes no authorization' $authorizationBeforeStaleClick (Read-SjcCacheAuthorizations -Context $context).Revision ([string](Read-SjcCacheAuthorizations -Context $context).Revision)
    Assert-True 'TestMode Approve leaves the discovery window open and state idle' ($null -ne $discoveryStale.Tag.List.SelectedItem -and -not [bool]$state.Busy) ('Busy=' + $state.Busy)
    $discoveryStale.Close()

    # Selection-handler matrix on constructed entries (no MessageBox, no product write).
    $matrixWindow = New-SjcGuiDiscoveryWindow $draft
    $matrixList = $matrixWindow.Tag.List
    $matrixCases = @(
        @{ Name = 'supported pending'; Supported = $true; Authorized = $false; Status = 'PendingAuthorization'; Binding = ('b' * 64); Expect = $true }
        @{ Name = 'valid authorized'; Supported = $true; Authorized = $true; Status = 'Authorized'; Binding = ('b' * 64); Expect = $false }
        @{ Name = 'stale authorized'; Supported = $true; Authorized = $true; Status = 'StaleAuthorization'; Binding = ('b' * 64); Expect = $true }
        @{ Name = 'unsupported pending'; Supported = $false; Authorized = $false; Status = 'Unsupported'; Binding = ('b' * 64); Expect = $false }
        @{ Name = 'stale without binding'; Supported = $true; Authorized = $true; Status = 'StaleAuthorization'; Binding = ''; Expect = $false }
    )
    $matrixErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($case in $matrixCases) {
        $entry = [Windows.Controls.ListBoxItem]::new()
        $entry.Tag = [pscustomobject]@{ Id = 'Discovered:test'; Application = 'test'; Source = 'NUGET_HTTP_CACHE_PATH'; Root = 'C:\test'; Status = $case.Status; Supported = $case.Supported; Authorized = $case.Authorized; Note = ''; Adapter = 'NuGetHttp'; TemplateId = 'NuGetCache'; SourceValue = ''; DirectoryIdentity = ''; Binding = $case.Binding; AuthorizationId = '' }
        $matrixList.Items.Add($entry) | Out-Null
        $matrixList.SelectedItem = $entry
        $actual = [bool]$matrixWindow.Tag.ApproveButton.IsEnabled
        if ($actual -ne [bool]$case.Expect) { $matrixErrors.Add($case.Name + ': expected=' + $case.Expect + '; actual=' + $actual) }
    }
    Assert-True 'approve availability follows supported + stale-only + binding rules' ($matrixErrors.Count -eq 0) ($matrixErrors -join '; ')
    $matrixWindow.Close()

    # ---- 3. Closing windows leaves authorization and scan untouched -----------
    $authorizationBeforeClose = (Read-SjcCacheAuthorizations -Context $context).Revision
    $scanBeforeClose = $state.Scan
    $staleBeforeClose = $state.Stale
    $taskBeforeClose = [string]$state.TaskDirectory
    $busyBeforeClose = [bool]$state.Busy
    $maintenanceBeforeCloseEntry = $app.Maintenance
    $discoveryForClose = New-SjcGuiDiscoveryWindow $draft
    $discoveryForClose.Close()
    $maintenanceForClose = New-SjcGuiMaintenanceWindow $draft
    $maintenanceForClose.Close()
    Assert-True 'closing discovery and an idle maintenance window keeps the scan object' ([object]::ReferenceEquals($scanBeforeClose, $state.Scan)) 'scan reference'
    Assert-Equal 'closing the windows keeps the stale flag' $staleBeforeClose $state.Stale ([string]$state.Stale)
    Assert-Equal 'closing the windows keeps the task directory' $taskBeforeClose ([string]$state.TaskDirectory) ([string]$state.TaskDirectory)
    Assert-Equal 'closing the windows keeps Busy unchanged' $busyBeforeClose ([bool]$state.Busy) ([string]$state.Busy)
    Assert-True 'closing an idle maintenance window creates no maintenance entry' ($null -eq $maintenanceBeforeCloseEntry -and $null -eq $app.Maintenance) ('before=' + [string]($null -ne $maintenanceBeforeCloseEntry) + '; after=' + [string]($null -ne $app.Maintenance))
    Assert-Equal 'closing the windows writes no authorization' $authorizationBeforeClose (Read-SjcCacheAuthorizations -Context $context).Revision ([string](Read-SjcCacheAuthorizations -Context $context).Revision)

    $idleMaintenance = New-SjcGuiMaintenanceWindow $draft
    Assert-Equal 'the maintenance window starts in the not-started state' '尚未启动。' ([string]$idleMaintenance.Tag.Status.Text) ([string]$idleMaintenance.Tag.Status.Text)
    Assert-True 'the maintenance window is an owned window of the main window' ([object]::ReferenceEquals($idleMaintenance.Owner, $mainWindow)) 'Owner'
    Assert-True 'opening an idle maintenance window changes nothing yet' ([object]::ReferenceEquals($scanBeforeClose, $state.Scan) -and [bool]$state.Busy -eq $busyBeforeClose) 'scan/Busy'
    $idleMaintenance.Close()

    # ---- 4. Maintenance window TestMode gate (no MessageBox, no start) -------
    $maintenanceGate = New-SjcGuiMaintenanceWindow $draft
    $startCalls = 0
    $originalStart = ${function:Start-SjcMaintenance}
    function Start-SjcMaintenance {
        param([Parameter(Mandatory = $true)][string]$ActionId, [switch]$TestMode)
        $script:g04StartCalls++
        return [pscustomobject]@{ Status = 'Running'; Process = [pscustomobject]@{ HasExited = $false }; ExitCode = $null; Error = '' }
    }
    $script:g04StartCalls = 0
    try {
        $maintenanceGate.Tag.Button.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent))
        Assert-Equal 'TestMode refuses to start system maintenance from the window' '测试模式禁止启动。' ([string]$maintenanceGate.Tag.Status.Text) ([string]$maintenanceGate.Tag.Status.Text)
        Assert-Equal 'TestMode never calls Start-SjcMaintenance' 0 $script:g04StartCalls ([string]$script:g04StartCalls)
        Assert-True 'TestMode leaves the app idle and without a maintenance entry' ((-not [bool]$state.Busy) -and $null -eq $app.Maintenance) ('Busy=' + $state.Busy)
    }
    finally {
        Set-Item -Path 'Function:\Start-SjcMaintenance' -Value $originalStart -Force
    }
    Assert-True 'Start-SjcMaintenance is restored after the double' ((Get-Command Start-SjcMaintenance).Definition -eq $originalStart.ToString()) 'definition comparison'
    $maintenanceGate.Close()

    # ---- 5. Maintenance result ticks with a process stub ---------------------
    $disposeCount = 0
    $killCount = 0
    $script:g04HasExited = $true
    $script:g04ExitCode = 0
    $processStub = [pscustomobject]@{}
    $processStub | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $script:g04HasExited }
    $processStub | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { $script:g04ExitCode }
    $processStub | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:g04DisposeCount++ }
    $processStub | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:g04KillCount++ }
    $script:g04DisposeCount = 0
    $script:g04KillCount = 0

    function New-G04ResultView {
        return [pscustomobject]@{ Status = [pscustomobject]@{ Text = '' }; Button = [pscustomobject]@{ IsEnabled = $false } }
    }

    $tickExpectations = @(
        @{ Name = 'exit code 0'; Code = 0; Expected = '系统维护 Success,退出代码 0；实际释放空间未知。' }
        @{ Name = 'exit code 3010'; Code = 3010; Expected = '系统维护 RebootRequired,退出代码 3010；操作已完成但需要重启后生效,不会自动重启；实际释放空间未知。' }
        @{ Name = 'non-zero exit code'; Code = 7; Expected = '系统维护 Failed,退出代码 7；实际释放空间未知。' }
        @{ Name = 'negative exit code'; Code = -1; Expected = '系统维护 Failed,退出代码 -1；实际释放空间未知。' }
    )
    $tickErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($case in $tickExpectations) {
        $view = New-G04ResultView
        $script:g04HasExited = $true
        $script:g04ExitCode = $case.Code
        $state.Busy = $true
        $disposeBefore = $script:g04DisposeCount
        $app.Maintenance = @{ Process = $processStub; View = $view }
        Invoke-SjcGuiMaintenanceTick $app
        if ([string]$view.Status.Text -cne $case.Expected) { $tickErrors.Add($case.Name + ': view=[' + [string]$view.Status.Text + ']') }
        if ([string]$state.Status -cne $case.Expected) { $tickErrors.Add($case.Name + ': status=[' + [string]$state.Status + ']') }
        if ([bool]$state.Busy -or $null -ne $app.Maintenance) { $tickErrors.Add($case.Name + ': state not cleared') }
        if (-not [bool]$view.Button.IsEnabled) { $tickErrors.Add($case.Name + ': button not re-enabled') }
        if (($script:g04DisposeCount - $disposeBefore) -ne 1) { $tickErrors.Add($case.Name + ': dispose=' + ($script:g04DisposeCount - $disposeBefore)) }
    }
    Assert-True 'exit code 0/3010/non-zero/-1 map to Success/RebootRequired/Failed/Failed and clear Busy+Maintenance' ($tickErrors.Count -eq 0) ($tickErrors -join '; ')
    Assert-Equal 'a completed maintenance process is never killed' 0 $script:g04KillCount ([string]$script:g04KillCount)

    # Unreadable process state: under Harness StrictMode a missing HasExited member is a
    # terminating PropertyNotFoundException, which exercises the product's catch branch.
    $unreadable = [pscustomobject]@{ Note = 'no HasExited member' }
    $viewThrow = New-G04ResultView
    $state.Busy = $true
    $app.Maintenance = @{ Process = $unreadable; View = $viewThrow }
    $tickThrew = $null
    try { Invoke-SjcGuiMaintenanceTick $app } catch { $tickThrew = $_ }
    $tickThrewText = if ($null -eq $tickThrew) { 'no exception propagated' } else { [string]$tickThrew.Exception.Message }
    Assert-True 'an unreadable process state is handled, not propagated' ($null -eq $tickThrew) $tickThrewText
    Assert-True 'an unreadable process state reports Unknown' ([string]$viewThrow.Status.Text -match '系统维护结果 Unknown') ([string]$viewThrow.Status.Text)
    Assert-True 'an unreadable process state clears Busy and Maintenance' ((-not [bool]$state.Busy) -and $null -eq $app.Maintenance) ('Busy=' + $state.Busy)
    Assert-True 'an unreadable process state still re-enables the window button' ([bool]$viewThrow.Button.IsEnabled) ([string]$viewThrow.Button.IsEnabled)

    # View update throwing must not leave Busy/Maintenance set (clear happens first).
    $throwingView = [pscustomobject]@{}
    $throwingView | Add-Member -MemberType NoteProperty -Name Status -Value ([pscustomobject]@{})
    $throwingView.Status | Add-Member -MemberType ScriptProperty -Name Text -Value { '' } -SecondValue { throw 'g04-view-boom' }
    $throwingView | Add-Member -MemberType NoteProperty -Name Button -Value ([pscustomobject]@{ IsEnabled = $false })
    $script:g04HasExited = $true
    $script:g04ExitCode = 0
    $state.Busy = $true
    $app.Maintenance = @{ Process = $processStub; View = $throwingView }
    $viewThrew = $null
    try { Invoke-SjcGuiMaintenanceTick $app } catch { $viewThrew = $_ }
    $viewThrewText = if ($null -eq $viewThrew) { 'no exception propagated' } else { [string]$viewThrew.Exception.Message }
    Assert-True 'a view/status update failure is contained' ($null -eq $viewThrew) $viewThrewText
    Assert-True 'a failed view update still leaves Busy false and Maintenance empty' ((-not [bool]$state.Busy) -and $null -eq $app.Maintenance) ('Busy=' + $state.Busy + '; Maintenance=' + [string]($null -ne $app.Maintenance))

    # Dispose throwing must also be contained.
    $badDispose = [pscustomobject]@{}
    $badDispose | Add-Member -MemberType ScriptProperty -Name HasExited -Value { $true }
    $badDispose | Add-Member -MemberType ScriptProperty -Name ExitCode -Value { 0 }
    $badDispose | Add-Member -MemberType ScriptMethod -Name Dispose -Value { throw 'g04-dispose-boom' }
    $badDispose | Add-Member -MemberType ScriptMethod -Name Kill -Value { $script:g04KillCount++ }
    $viewBadDispose = New-G04ResultView
    $state.Busy = $true
    $app.Maintenance = @{ Process = $badDispose; View = $viewBadDispose }
    $disposeThrew = $null
    try { Invoke-SjcGuiMaintenanceTick $app } catch { $disposeThrew = $_ }
    $disposeThrewText = if ($null -eq $disposeThrew) { 'no exception propagated' } else { [string]$disposeThrew.Exception.Message }
    Assert-True 'a Dispose failure is contained' ($null -eq $disposeThrew) $disposeThrewText
    Assert-True 'a Dispose failure still clears Busy and Maintenance' ((-not [bool]$state.Busy) -and $null -eq $app.Maintenance) ('Busy=' + $state.Busy)

    # Running process (HasExited false) must leave everything in place.
    $script:g04HasExited = $false
    $viewRunning = New-G04ResultView
    $state.Busy = $true
    $disposeBeforeRunning = $script:g04DisposeCount
    $app.Maintenance = @{ Process = $processStub; View = $viewRunning }
    Invoke-SjcGuiMaintenanceTick $app
    Assert-True 'a still-running process keeps Busy and Maintenance' ([bool]$state.Busy -and $null -ne $app.Maintenance) ('Busy=' + $state.Busy)
    Assert-Equal 'a still-running process leaves the mode-specific text untouched' '' ([string]$viewRunning.Status.Text) ([string]$viewRunning.Status.Text)
    Assert-Equal 'a still-running process is not disposed' 0 ($script:g04DisposeCount - $disposeBeforeRunning) ([string]($script:g04DisposeCount - $disposeBeforeRunning))
    $app.Maintenance = $null
    $state.Busy = $false

    # ---- 6. Remove-SjcGuiApp only disposes and never kills -------------------
    $removalContext = New-OwnedSandbox
    $removalState = New-SjcGuiState $removalContext.Context -TestMode
    $removalApp = New-SjcGuiApp $removalState
    try {
        $script:g04KillCount = 0
        $script:g04DisposeCount = 0
        $removalState.Busy = $true
        $removalApp.Maintenance = @{ Process = $processStub; View = $null }
        Remove-SjcGuiApp $removalApp
        Assert-Equal 'Remove-SjcGuiApp disposes the maintenance handle once' 1 $script:g04DisposeCount ([string]$script:g04DisposeCount)
        Assert-Equal 'Remove-SjcGuiApp never kills the maintenance process' 0 $script:g04KillCount ([string]$script:g04KillCount)
        Assert-True 'Remove-SjcGuiApp clears the maintenance entry' ($null -eq $removalApp.Maintenance) 'Maintenance'
        Assert-True 'Remove-SjcGuiApp reset Busy' (-not [bool]$removalState.Busy) ('Busy=' + $removalState.Busy)
        Remove-SjcGuiApp $removalApp
        Assert-Equal 'Remove-SjcGuiApp is idempotent (no second Dispose)' 1 $script:g04DisposeCount ([string]$script:g04DisposeCount)
    }
    finally {
        Remove-SjcGuiApp $removalApp
        try { $removalApp.Ui.Window.Close() } catch { }
    }

    [void](Save-Evidence 'discovery-matrix' ([pscustomobject]@{ Cases = @($matrixCases | ForEach-Object { $_.Name + '=>' + $_.Expect }); Ready = ($matrixErrors.Count -eq 0) }))
    [void](Save-Evidence 'maintenance-ticks' ([pscustomobject]@{ ExitCodes = @($tickExpectations | ForEach-Object { [string]$_.Code }); TickErrors = @($tickErrors); KillCount = $script:g04KillCount; DisposeCount = $script:g04DisposeCount }))
    Add-DeclaredExclusion 'G04 不点击真实 MessageBox 的“是/否”：授权写入、撤销写入与维护确认后启动都经过 MessageBox，本用例为避免真实对话框只验证到 TestMode/守卫分支；这些写入路径由主对话做真实桌面验收。'
    Add-Limitation 'G04 以代码构造 Window 并 RaiseEvent/SelectItem 触发产品处理器，不操作桌面、鼠标、键盘或 UI 自动化；窗口不 Show。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($app) { try { Remove-SjcGuiApp $app } catch { } }
    if ($mainWindow) { try { $mainWindow.Close() } catch { } }
}
Complete-TestCase
