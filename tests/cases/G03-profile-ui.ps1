#requires -Version 5.1
# G03: GUI cleaning-profile integration against the current popup advanced-draft GUI.
# The WPF surface exposes a profile radio selector (Low/Medium/High) plus a single
# "AdvancedButton" that opens a modal advanced-rule draft window. There is no inline
# advanced toggle/panel: this case asserts that contract and drives the REAL
# New-SjcGuiAdvancedDraftWindow / Confirm-SjcGuiAdvancedDraft functions on an
# unshown (never ShowDialog) window - no mouse, no UI automation.
# Contract covered: advanced draft closed by default, cancel keeps scan, same-set
# confirm keeps scan, changed-set confirm sets explicit CustomEnabled and invalidates
# (needs rescan), three-tier instant apply, Busy freeze, strict worker payload.
# Programmatic WPF/worker contract checks only; no production worker or desktop acceptance.
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
$app=$null;$freshApp=$null;$drafts=New-Object 'System.Collections.Generic.List[object]'
function Close-DraftWindow {
    param($Window)
    if ($null -eq $Window) { return }
    try { $Window.Close() } catch { }
}
function New-ClosedDraft {
    # Build the real draft window but NEVER show it (no mouse, no ShowDialog).
    param($App)
    $window=New-SjcGuiAdvancedDraftWindow $App
    [void]$drafts.Add($window)
    return $window
}
try {
    $sandbox=New-OwnedSandbox;$context=$sandbox.Context
    New-TestFile -Path (Join-Path $sandbox.Root 'files\old.tmp') -Bytes 30 -AgeHours 100|Out-Null
    $state=New-SjcGuiState $context -TestMode;$app=New-SjcGuiApp $state

    # --- contract: current popup GUI exposes AdvancedButton, never AdvancedToggle ---
    Assert-True 'main window exposes AdvancedButton (no inline toggle)' ($app.Ui.ContainsKey('AdvancedButton') -and -not $app.Ui.ContainsKey('AdvancedToggle'))
    Assert-True 'no inline advanced panel in main window' (-not $app.Ui.ContainsKey('AdvancedPanel'))
    Assert-Equal 'new user defaults to Medium' 'Medium' $state.Profile
    Assert-True 'advanced draft starts closed' (-not $state.CustomEnabled)
    foreach($name in @('NavHome','NavFiles','NavRules','NavLogs','ApplyRulesButton')) { Assert-True ($name+' removed') ($null -eq $app.Ui.Window.FindName($name)) }

    # --- three-tier instant apply: RadioButton Checked applies preset to UI and engine ---
    foreach($profile in @('Low','High','Medium')) {
        $app.Ui['Profile'+$profile].IsChecked=$true
        Assert-Equal ($profile+' Checked applies to UI') $profile $state.Profile
        Assert-Equal ($profile+' Checked applies to engine') $profile $context.CleaningProfile
        Assert-Equal ($profile+' selects exact preset automatically') ((@(Get-SjcPresetRuleIds $context $profile)|Sort-Object)-join ',') ((@($state.Selected)|Sort-Object)-join ',')
    }

    # --- Busy freezes presets and the advanced entry; only Cancel stays available ---
    $state.Busy=$true;Update-SjcGuiView $app
    Assert-True 'busy freezes presets and advanced button' (-not $app.Ui.ProfileLow.IsEnabled -and -not $app.Ui.AdvancedButton.IsEnabled)
    Assert-True 'busy enables cancel' ($app.Ui.CancelButton.IsEnabled -and $app.Ui.CancelButton.Visibility -eq 'Visible')
    Assert-Throws 'busy rejects advanced draft entry' {Show-SjcGuiAdvancedDraft $app} '结束'
    $state.Busy=$false;Update-SjcGuiView $app

    # --- strict Scan payload on the current preset ---
    $task=New-SjcTaskDirectory $context
    $payload=New-SjcGuiTaskPayload $state 'Scan' $task '' ''
    Assert-SjcWorkerPayload ([pscustomobject]$payload) 'Scan'
    Assert-True 'Scan carries explicit false custom mode' ($payload.CustomEnabled -is [bool] -and -not $payload.CustomEnabled)
    Assert-Equal 'Scan profile matches current tier' 'Medium' ([string]$payload.CleaningProfile)
    $scan=Invoke-SjcScan -Context $context -RuleIds $payload.RuleIds -TaskDirectory $task -CustomEnabled $false
    Assert-Equal 'preset scan succeeds' 'Success' $scan.Status
    $state.Scan=$scan;$state.ScanProfile=$scan.CleaningProfile;$state.ScanCustomEnabled=$false;$state.TaskDirectory=$task;$state.Stale=$false

    # --- advanced draft is CLOSED by default: building it mutates nothing ---
    $beforeProfile=$state.Profile;$beforeScan=$state.Scan.PlanPath
    $draftWindow=New-ClosedDraft $app
    $draft=$draftWindow.Tag
    Assert-True 'draft window constructed without showing' ($null -ne $draftWindow -and -not $draftWindow.IsLoaded)
    Assert-True 'draft starts from current preset set' (Test-SjcGuiSameIds @(Get-SjcGuiPresetIds $context $state.Profile) @($draft.Ids))
    Assert-True 'draft presence leaves custom disabled' (-not $state.CustomEnabled -and $state.Profile -ceq $beforeProfile)
    Assert-True 'draft presence keeps scan valid' ($null -ne $state.Scan -and -not $state.Stale)

    # --- CANCEL (window closed without accept): keep scan untouched ---
    $cancelButton=$draftWindow.FindName('DraftCancel')
    Assert-True 'cancel affordance is a real IsCancel dialog button' ($null -ne $cancelButton -and [bool]$cancelButton.IsCancel)
    Assert-True 'cancel does not accept the draft' (-not [bool]$draftWindow.Tag.Accepted)
    Close-DraftWindow $draftWindow;$draftWindow=$null
    Assert-True 'cancel keeps scan valid' ($null -ne $state.Scan -and -not $state.Stale -and $state.Scan.PlanPath -ceq $beforeScan)
    Assert-True 'cancel keeps custom disabled' (-not $state.CustomEnabled)

    # --- CONFIRM with UNCHANGED set returns false and keeps the sealed scan ---
    $sameDraft=New-ClosedDraft $app
    $sameIds=[string[]]@(Get-SjcGuiAdvancedDraftIds $sameDraft.Tag)
    $applied=Confirm-SjcGuiAdvancedDraft $app $sameIds
    Assert-True 'same-set confirm returns false (no apply)' (-not $applied)
    Assert-True 'same-set confirm keeps scan valid' ($null -ne $state.Scan -and -not $state.Stale)
    Assert-True 'same-set confirm keeps custom disabled' (-not $state.CustomEnabled)
    Close-DraftWindow $sameDraft;$sameDraft=$null

    # --- CONFIRM with CHANGED set applies explicit CustomEnabled and invalidates scan ---
    $drop=[string](@(Get-SjcGuiPresetIds $context $state.Profile)|Select-Object -First 1)
    $changedIds=[string[]]@($sameIds|Where-Object{$_ -cne $drop})
    Assert-True 'changed set is a strict subset' ($changedIds.Count -lt $sameIds.Count -and $changedIds.Count -gt 0)
    $applied2=Confirm-SjcGuiAdvancedDraft $app $changedIds
    Assert-True 'changed-set confirm returns true (applied)' $applied2
    Assert-True 'changed-set confirm enables custom' $state.CustomEnabled
    Assert-Equal 'changed-set confirm selects exactly draft ids' ((@($changedIds)|Sort-Object)-join ',') ((@($state.Selected)|Sort-Object)-join ',')
    Assert-True 'changed-set confirm clears scan (needs rescan)' ($null -eq $state.Scan -and $state.Stale)
    Assert-True 'changed-set invalidates sealed old plan' ([IO.File]::Exists((Join-Path $task 'profile.invalidated')))
    Assert-Throws 'old scan remains invalid after custom change' {Open-SjcPreviewSession $scan.PlanPath} '失效'

    # --- custom Scan payload carries explicit true custom mode and chosen ids ---
    $customTask=New-SjcTaskDirectory $context
    $customPayload=New-SjcGuiTaskPayload $state 'Scan' $customTask '' ''
    Assert-SjcWorkerPayload ([pscustomobject]$customPayload) 'Scan'
    Assert-True 'custom Scan carries explicit true custom mode' ($customPayload.CustomEnabled -is [bool] -and $customPayload.CustomEnabled)
    Assert-Equal 'custom Scan RuleIds equal chosen set' ((@($changedIds)|Sort-Object)-join ',') ((@($customPayload.RuleIds)|Sort-Object)-join ',')

    # --- selecting a tier shortcut exits custom mode and restores the exact preset ---
    $app.Ui.ProfileLow.IsChecked=$true
    Assert-True 'choosing a shortcut exits custom mode' (-not $state.CustomEnabled)
    Assert-Equal 'shortcut after custom uses exact Low preset' ((@(Get-SjcPresetRuleIds $context 'Low')|Sort-Object)-join ',') ((@($state.Selected)|Sort-Object)-join ',')

    # --- clean confirmation displays the sealed scan tier ---
    $lowTask=New-SjcTaskDirectory $context
    $cscan=Invoke-SjcScan -Context $context -RuleIds @(Get-SjcGuiPresetIds $context 'Low') -TaskDirectory $lowTask -CustomEnabled $false
    Assert-Equal 'post-shortcut scan succeeds' 'Success' $cscan.Status
    $state.Scan=$cscan;$state.ScanProfile=$cscan.CleaningProfile;$state.ScanCustomEnabled=$false;$state.TaskDirectory=$lowTask;$state.Stale=$false
    $clean=New-SjcGuiTaskPayload $state 'Clean' $lowTask '' ''
    Assert-SjcWorkerPayload ([pscustomobject]$clean) 'Clean'
    Assert-Equal 'Clean uses sealed profile' $cscan.CleaningProfile $clean.CleaningProfile
    Assert-True 'Clean uses sealed custom mode' (-not $clean.CustomEnabled)
    $summary=Get-SjcGuiCleanSummary $state;$confirm=New-SjcGuiCleanConfirmWindow $app $summary
    try { Assert-True 'confirmation displays scan tier' ($confirm.FindName('ProfileText').Text -match '低强度|Low') } finally {$confirm.Close()}

    # --- a fresh state never reopens advanced mode, even after building a draft ---
    $fresh=New-SjcGuiState $context -TestMode
    Assert-True 'new window never reopens advanced mode' (-not $fresh.CustomEnabled)
    $freshApp=New-SjcGuiApp $fresh
    $freshDraft=New-ClosedDraft $freshApp
    Assert-True 'fresh draft does not mutate fresh state' (-not $fresh.CustomEnabled)
    Close-DraftWindow $freshDraft
    Assert-True 'fresh state still on preset after draft close' (-not $fresh.CustomEnabled -and (Test-SjcGuiSameIds @(Get-SjcGuiPresetIds $context $fresh.Profile) @($fresh.Selected)))

    # --- invalid saved settings fall back to Low with a notice ---
    $bad=Join-Path $context.StateRoot 'preferences-v4.json'
    [IO.File]::WriteAllText($bad,'{"RecycleMode":true,"CleaningProfile":"Low","SelectedRuleIds":["Unknown"],"CustomEnabled":false}')
    $startup=Resolve-SjcGuiStartupPreferences $context
    Assert-Equal 'invalid saved settings fall back to Low' 'Low' $startup.Profile
    Assert-True 'invalid saved settings explain fallback' (-not [string]::IsNullOrWhiteSpace($startup.Notice))

    Assert-True 'GUI did not delete target' ([IO.File]::Exists((Join-Path $sandbox.Root 'files\old.tmp')))
    Add-Limitation 'Programmatic WPF checks only; actual desktop layout is verified separately.'
} catch {Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
finally {
    foreach($window in $drafts){Close-DraftWindow $window}
    if($freshApp){try{Remove-SjcGuiApp $freshApp}catch{};try{$freshApp.Ui.Window.Close()}catch{}}
    if($app){try{Remove-SjcGuiApp $app}catch{};try{$app.Ui.Window.Close()}catch{}}
}
Complete-TestCase
