#requires -Version 5.1
# G03: GUI cleaning-profile integration - the WPF surface must expose the engine's
# Recommended/Deep selector, write an exact-case CleaningProfile into every Scan and
# Clean worker payload, invalidate the current scan when the profile changes, and show
# the profile in the clean confirmation.
# Payloads are captured by stopping at the launch-spec step: no worker process is spawned.
# GUI self-test output is NOT desktop acceptance.
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [Parameter(Mandatory = $true)][string]$EvidenceDirectory,
    [switch]$LoadGui,
    [string]$ExePath = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui -ExePath $ExePath
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
$app = $null
$originalLaunchSpec = $null
try {
    $guiReady = Assert-ReleaseGuiModule
    Assert-True 'GUI module exposes the profile support probe' ($null -ne (Get-Command Test-SjcGuiProfileSupport -CommandType Function -ErrorAction SilentlyContinue)) 'missing Test-SjcGuiProfileSupport'
    Assert-True 'GUI module exposes the profile state updater' ($null -ne (Get-Command Update-SjcGuiProfile -CommandType Function -ErrorAction SilentlyContinue)) 'missing Update-SjcGuiProfile'
    Assert-True 'GUI module exposes the clean summary builder' ($null -ne (Get-Command Get-SjcGuiCleanSummary -CommandType Function -ErrorAction SilentlyContinue)) 'missing Get-SjcGuiCleanSummary'

    $sandbox = New-OwnedSandbox
    $context = $sandbox.Context
    $filesRoot = Join-Path $sandbox.Root 'files'
    New-TestFile -Path (Join-Path $filesRoot 'age10h.tmp') -Bytes 10 -AgeHours 10 | Out-Null
    New-TestFile -Path (Join-Path $filesRoot 'age30h.tmp') -Bytes 30 -AgeHours 30 | Out-Null
    New-TestFile -Path (Join-Path $filesRoot 'age60h.tmp') -Bytes 60 -AgeHours 60 | Out-Null

    # The engine owns the profile API; the GUI probe must recognise it.
    $engineSupports = ($null -ne (Get-Command Set-SjcCleaningProfile -CommandType Function -ErrorAction SilentlyContinue)) -and ($null -ne (Get-Command New-SjcContext -CommandType Function -ErrorAction SilentlyContinue))
    Assert-True 'engine exposes the cleaning-profile API used by the GUI' $engineSupports 'Set-SjcCleaningProfile/New-SjcContext missing'
    $supportProbe = $null
    try { $supportProbe = Test-SjcGuiProfileSupport } catch { Add-CoverageGap ('Test-SjcGuiProfileSupport threw: ' + $_.Exception.Message) }
    Assert-True 'GUI reports profile support when the engine provides it' ($supportProbe -eq $true) ('Test-SjcGuiProfileSupport=' + [string]$supportProbe)

    if ($guiReady) {
        $state = New-SjcGuiState $context -TestMode
        $app = New-SjcGuiApp $state
        Assert-True 'GUI state starts on the Recommended profile' ([string]$state.Profile -eq 'Recommended' -and [string]$state.DraftProfile -eq 'Recommended') ([string]$state.Profile + '/' + [string]$state.DraftProfile)
        Assert-True 'profile radios exist in the WPF tree' ($null -ne $app.Ui.ProfileRecommended -and $null -ne $app.Ui.ProfileDeep) ''
        Assert-True 'Deep radio is selectable once the engine supports it' ([bool]$app.Ui.ProfileDeep.IsEnabled) ('enabled=' + [string]$app.Ui.ProfileDeep.IsEnabled + '; supported=' + [string]$state.ProfileSupported)
        Assert-True 'profile hint explains the re-scan requirement' ([string]$app.Ui.ProfileHint.Text -match '重新扫描') ([string]$app.Ui.ProfileHint.Text)

        # Real selection path: flipping the radio's IsChecked is what both a mouse click and
        # UIAutomation SelectionPattern/TogglePattern end up doing. The handler must be
        # Checked (not Click), otherwise keyboard/UIA users leave the draft stuck on
        # Recommended while the dot moves to Deep. No manual State.DraftProfile assignment.
        $state.DraftProfile = 'Recommended'
        $state.Profile = 'Recommended'
        $app.Ui.ProfileRecommended.IsChecked = $true
        Update-SjcGuiProfile $app
        Update-SjcGuiDraftText $app
        $app.Ui.ProfileDeep.IsChecked = $true
        Assert-Equal 'checked Deep radio alone updates the draft profile (UIA/keyboard path)' 'Deep' ([string]$state.DraftProfile)
        Assert-Equal 'checked Deep radio alone still leaves the applied profile untouched' 'Recommended' ([string]$state.Profile)
        Assert-True 'checked Deep radio alone updates the draft text' ([string]$app.Ui.DraftText.Text -match '档位') ([string]$app.Ui.DraftText.Text)
        Assert-Equal 'checked Deep radio alone leaves the engine context untouched' 'Recommended' ([string]$context.CleaningProfile)
        $hintIsDeep = [string]$app.Ui.ProfileHint.Text -match '深度'
        Assert-True 'profile hint follows the checked radio, not the applied profile' $hintIsDeep ([string]$app.Ui.ProfileHint.Text)
        # Unchecking the radio must not silently look like "Deep is still pending".
        $app.Ui.ProfileRecommended.IsChecked = $true
        Assert-Equal 'checking Recommended radio returns the draft to Recommended' 'Recommended' ([string]$state.DraftProfile)

        # Now commit through the same public command a user clicks.
        $app.Ui.ProfileDeep.IsChecked = $true
        Assert-Equal 'draft Deep is pending before apply' 'Deep' ([string]$state.DraftProfile)
        Assert-Equal 'applied profile is still Recommended before apply' 'Recommended' ([string]$state.Profile)
        Update-SjcGuiDraftText $app
        Assert-True 'draft text shows the pending profile change' ([string]$app.Ui.DraftText.Text -match '档位') ([string]$app.Ui.DraftText.Text)
        $draftAges = @($state.Draft | ForEach-Object { [double]$_.DeepAge })
        Assert-True 'draft rows expose both profile ages from the engine rule table' (@($draftAges | Where-Object { $_ -le 0 }).Count -eq 0) ('rows=' + $draftAges.Count)
        Invoke-SjcGuiCommand $app 'ApplyRulesButton'
        Assert-Equal 'applying the draft switches the applied profile' 'Deep' ([string]$state.Profile)
        Assert-True 'applying the profile invalidates the current scan' ([bool]$state.Stale) ('stale=' + [string]$state.Stale)
        Assert-Equal 'applying the profile updates the engine context' 'Deep' ([string]$context.CleaningProfile)
        Assert-Equal 'applied rule table was rebuilt from the Deep context' 0 (@($state.Rules | Where-Object { $_.CleaningProfile -cne 'Deep' }).Count) ''
        Assert-True 'applying a profile clears the previous keep set' ($state.Excluded.Count -eq 0 -and $state.CandidateSelection.Count -eq 0) ('excluded=' + $state.Excluded.Count)

        # Capture the payload builder output without launching a worker: the payload file is
        # written before the launch specification is resolved, so stopping there is safe.
        $originalLaunchSpec = ${function:Get-SjcGuiLaunchSpec}
        $script:g03LastPayload = ''
        $script:g03LastMode = ''
        function Get-SjcGuiLaunchSpec { param([string]$Mode,[string]$PayloadPath,[string]$OutputPath) $script:g03LastMode = $Mode; $script:g03LastPayload = $PayloadPath; throw 'SJC-G03-PAYLOAD-CAPTURED' }
        $state.TestMode = $false
        $state.Selected.Clear(); [void]$state.Selected.Add('SandboxOld')

        $script:g03LastPayload = ''
        try { Start-SjcGuiTask $app 'Scan' | Out-Null } catch { }
        Assert-Equal 'GUI Scan reached the payload/launch boundary' 'Scan' ([string]$script:g03LastMode)
        $scanPayloadPath = [string]$script:g03LastPayload
        Assert-True 'GUI Scan wrote a payload channel inside a task directory' ($scanPayloadPath -and [IO.File]::Exists($scanPayloadPath)) $scanPayloadPath
        if ([IO.File]::Exists($scanPayloadPath)) {
            $scanPayload = Get-Content -LiteralPath $scanPayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [void](Save-Evidence 'gui-scan-payload' $scanPayload)
            Assert-True 'GUI Scan payload includes CleaningProfile' ($null -ne $scanPayload.PSObject.Properties['CleaningProfile']) (($scanPayload.PSObject.Properties.Name) -join ',')
            if ($null -ne $scanPayload.PSObject.Properties['CleaningProfile']) {
                Assert-Equal 'GUI Scan payload uses the applied Deep value' 'Deep' ([string]$scanPayload.CleaningProfile)
                Assert-True 'GUI Scan payload profile is a strict string' ($scanPayload.CleaningProfile -is [string]) ($scanPayload.CleaningProfile.GetType().Name)
                $why = ''; $ok = $false
                try { Assert-SjcWorkerPayload -Payload $scanPayload -Mode 'Scan'; $ok = $true } catch { $why = $_.Exception.Message }
                Assert-True 'GUI Scan payload passes the strict worker allow-list' $ok $why
            }
        }

        $cleanTask = New-SjcTaskDirectory -Context $context
        $state.TaskDirectory = $cleanTask
        $script:g03LastPayload = ''; $script:g03LastMode = ''
        try { Start-SjcGuiTask $app 'Clean' | Out-Null } catch { }
        Assert-Equal 'GUI Clean reached the payload/launch boundary' 'Clean' ([string]$script:g03LastMode)
        $cleanPayloadPath = [string]$script:g03LastPayload
        Assert-True 'GUI Clean wrote a payload channel inside the clean task' ($cleanPayloadPath -and [IO.File]::Exists($cleanPayloadPath) -and ([IO.Path]::GetDirectoryName($cleanPayloadPath) -eq $cleanTask)) $cleanPayloadPath
        if ([IO.File]::Exists($cleanPayloadPath)) {
            $cleanPayload = Get-Content -LiteralPath $cleanPayloadPath -Raw -Encoding UTF8 | ConvertFrom-Json
            [void](Save-Evidence 'gui-clean-payload' $cleanPayload)
            Assert-True 'GUI Clean payload includes CleaningProfile' ($null -ne $cleanPayload.PSObject.Properties['CleaningProfile']) (($cleanPayload.PSObject.Properties.Name) -join ',')
            if ($null -ne $cleanPayload.PSObject.Properties['CleaningProfile']) {
                Assert-Equal 'GUI Clean payload uses the applied Deep value' 'Deep' ([string]$cleanPayload.CleaningProfile)
                $why = ''; $ok = $false
                try { Assert-SjcWorkerPayload -Payload $cleanPayload -Mode 'Clean'; $ok = $true } catch { $why = $_.Exception.Message }
                Assert-True 'GUI Clean payload passes the strict worker allow-list' $ok $why
            }
        }
        ${function:Get-SjcGuiLaunchSpec} = $originalLaunchSpec
        $originalLaunchSpec = $null
        $state.TestMode = $true

        # Confirmation must display the profile that the sealed scan used.
        $state.Scan = [pscustomobject]@{ Status = 'Success'; CandidateCount = 2; CandidateBytes = 90; PlanPath = ''; Categories = @([pscustomobject]@{ RuleId = 'SandboxOld'; Name = '自有测试旧文件'; Group = '合成测试'; Risk = '中低'; Root = $filesRoot; Count = 2; Bytes = 90; Status = 'Success'; Note = '' }) }
        $state.Stale = $false
        $state.ScanProfile = 'Deep'
        $summary = Get-SjcGuiCleanSummary $state
        Assert-Equal 'clean summary carries the sealed scan profile' 'Deep' ([string]$summary.Profile)
        $confirm = New-SjcGuiCleanConfirmWindow $app $summary
        try {
            Assert-True 'confirmation window names the cleaning profile' ([string]$confirm.FindName('ProfileText').Text -match '深度|Deep') ([string]$confirm.FindName('ProfileText').Text)
        }
        finally { $confirm.Close() }
        [void](Save-Evidence 'gui-profile-state' ([pscustomobject]@{ AppliedProfile = $state.Profile; DraftProfile = $state.DraftProfile; SummaryProfile = $summary.Profile; ProfileSupported = $state.ProfileSupported }))
    }
    else {
        Add-Limitation 'src/Gui.ps1 或 Test-SjcGui 缺失：G03 以失败结束，不计跳过。'
    }
    Add-Limitation 'G03 只验证程序化控件/载荷/确认窗口；实际窗口外观与桌面观感由主对话现场观察，不由本用例认证。'
}
catch {
    Assert-True ('case completed without unhandled exception: ' + $_.Exception.Message) $false $_.ScriptStackTrace
}
finally {
    if ($null -ne $originalLaunchSpec) { ${function:Get-SjcGuiLaunchSpec} = $originalLaunchSpec }
    if ($app) { try { Remove-SjcGuiApp $app; $app.Ui.Window.Close() } catch { } }
}
Complete-TestCase
