#requires -Version 5.1
[CmdletBinding()]
param([switch]$KeepSandbox,[string]$FixtureParent)
. (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
Assert-LpEnvironment
if (-not $FixtureParent) { $FixtureParent=[IO.Path]::GetTempPath() }
$FixtureParent=Get-LpPath $FixtureParent -Directory
$homePath=Join-Path $FixtureParent ('l-'+[guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $homePath) { throw 'Owned test directory must be new.' }
$null=[IO.Directory]::CreateDirectory($homePath)
[IO.File]::WriteAllText((Join-Path $homePath '.test-fixture-owner'),$homePath,[Text.UTF8Encoding]::new($true))
$source=Join-Path $homePath '开发 develop'; $target=Join-Path $homePath '主线 main'; $evidence=Join-Path $homePath 'evidence'
foreach ($p in @($source,$target,$evidence)) { $null=[IO.Directory]::CreateDirectory($p) }
$promote=Join-Path $PSScriptRoot 'promote-local.ps1'; $seal=Join-Path $PSScriptRoot 'seal-local-promotion.ps1'
$script:passed=0
function Write-TestText([string]$Path,[string]$Text) {
    if (-not [IO.Path]::GetFullPath($Path).StartsWith($homePath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Not an owned test path.' }
    $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path,$Text,[Text.UTF8Encoding]::new($true))
}
function Write-TestJson([string]$Path,$Value) { Write-TestText $Path ($Value | ConvertTo-Json -Depth 15) }
function Test-Case([string]$Name,[scriptblock]$Action) {
    & $Action
    $script:passed++; Write-Output ('PASS '+$Name)
}
function Expect-Blocked([scriptblock]$Action,[string]$Reason) {
    $message=''
    try { & $Action | Out-Null } catch { $message=$_.Exception.Message }
    if (-not $message -or $message -notlike ('*'+$Reason+'*')) { throw "Expected blocked: $Reason; got: $message" }
}
function Commit-Test([string]$Repo,[string]$Message) {
    # 仅本脚本创建的 GUID 沙箱允许测试提交。
    if ($Repo -notin @($source,$target) -or -not $Repo.StartsWith($homePath+'\',[StringComparison]::OrdinalIgnoreCase) -or [IO.File]::ReadAllText((Join-Path $homePath '.test-fixture-owner')) -cne $homePath) { throw 'Not owned test repository.' }
    $null=Invoke-LpGit $Repo @('add','--all')
    $null=Invoke-LpGit $Repo @('-c','user.name=Local promotion test','-c','user.email=local-test@example.invalid','commit','-m',$Message)
    return ((Invoke-LpGit $Repo @('rev-parse','HEAD')) -join '')
}
function Retain-TestPath([string]$Path) {
    $full=Get-LpPath $Path
    if (-not $full.StartsWith($homePath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'Cannot retain non-owned fixture.' }
    $destination=Join-Path $evidence ('retained-'+[guid]::NewGuid().ToString('N'))
    Write-TestJson ($destination+'.json') @{Source=$full;Destination=$destination;Retained=$true}
    if ([IO.Directory]::Exists($full)) { [IO.Directory]::Move($full,$destination) } else { [IO.File]::Move($full,$destination) }
}
try {
    Test-Case 'cloud tag allowlist excludes redirections and unknown tags' {
        $null=Test-LpCloudPlaceholder $homePath
        foreach ($hex in @('9000001A','9000101A','9000601A','9000F01A')) {
            if (-not [SjcLocalPromotion.NativePath]::IsCloudTag([Convert]::ToUInt32($hex,16))) { throw 'Cloud tag rejected' }
        }
        foreach ($hex in @('A0000003','A000000C','8000001B','9001001A','00000000')) {
            if ([SjcLocalPromotion.NativePath]::IsCloudTag([Convert]::ToUInt32($hex,16))) { throw 'Unknown/redirection tag accepted' }
        }
    }
    Test-Case 'actual owned junction path rejected' {
        $link=Join-Path $homePath 'junction'
        $null=New-Item -ItemType Junction -Path $link -Target $evidence
        Expect-Blocked { Get-LpPath $link -Directory } 'Reparse redirection'
    }
    $null=Invoke-LpGit $source @('init','-b','develop')
    $null=Invoke-LpGit $source @('config','core.autocrlf','false')
    $ids=@('R01-rule-inventory','R02-browser-discovery','R03-rule-approval-seal','P01-path-guards','P02-preference-guards','P03-preview-session','S01-scan-core','S02-same-root-dedupe','S03-scan-links','C01-clean-core','C02-clean-tamper','C03-clean-error-cap','C04-cancel','C05-pagination-export','L01-logging','W01-worker-boundary','V01-version-contract','G01-gui-selftest','G02-background-preview','W02-worker-selftest','X01-exe-selftest','Z98-added-case','Z99-added-case')
    foreach ($p in @('src/Main.ps1','src/Version.ps1','src/Rules.ps1','src/Core.ps1','src/Discovery.ps1','src/Maintenance.ps1','src/Worker.ps1','src/Gui.ps1','scripts/build.ps1','assets/app.ico','tests/cases/synthetic.ps1')) { Write-TestText (Join-Path $source $p) ('synthetic fixture '+$p) }
    Write-TestText (Join-Path $source 'src/Version.ps1') "function Get-SjcVersion { '0.12.0' }`nfunction Get-SjcPrereleaseChannel { return }"
    Write-TestText (Join-Path $source 'scripts/publish.ps1') ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'publish.ps1')))
    Write-TestJson (Join-Path $source 'version.json') @{version='0.12.0'}
    Write-TestText (Join-Path $source '.gitignore') "ignored/`nincoming-*`n"
    $declaration='$script:AllCases = @(' + "`r`n" + (($ids | ForEach-Object { "[pscustomobject]@{Id='$_'}" }) -join "`r`n") + "`r`n)"
    Write-TestText (Join-Path $source 'tests/run_all.ps1') $declaration
    $base=Commit-Test $source 'synthetic base'
    $null=Invoke-LpGit $target @('init','-b','main')
    $null=Invoke-LpGit $target @('config','core.autocrlf','false')
    $null=Invoke-LpGit $target @('fetch','--no-tags','--',$source,$base)
    $null=Invoke-LpGit $target @('merge','--ff-only',$base)
    Test-Case 'same HEAD needs no evidence or promotion' {
        $r=& $promote -SourceRepository $source -TargetRepository $target
        if ($r.Status -ne 'NoPromotionNeeded') { throw 'Unexpected status' }
    }
    Write-TestText (Join-Path $source 'src/Core.ps1') 'synthetic next version'
    foreach ($p in @('incoming-same.txt','incoming-child/file.txt','incoming-parent')) { Write-TestText (Join-Path $source $p) 'incoming committed file' }
    $null=Invoke-LpGit $source @('add','-f','incoming-same.txt','incoming-child/file.txt','incoming-parent')
    $next=Commit-Test $source 'synthetic accepted next'
    $capture=Join-Path $evidence 'build-inputs.json'
    $null=& $seal -SourceRepository $source -ExpectedSourceHead $next -OutputPath $capture -CaptureBuildInputs -Confirm:$false
    $repo=Get-LpRepository $source 'develop'
    $sources=@('src/Main.ps1','src/Version.ps1','src/Rules.ps1','src/Core.ps1','src/Discovery.ps1','src/Maintenance.ps1','src/Worker.ps1','src/Gui.ps1','version.json','scripts/build.ps1','assets/app.ico') | ForEach-Object { [pscustomobject]@{Path=$_;SHA256=(Get-LpHash (Join-Path $source $_))} }
    $exe=Join-Path $evidence 'synthetic.exe'; $scriptArtifact=Join-Path $evidence 'synthetic.ps1'
    Write-TestText $exe 'NOT A REAL EXE - local gate fixture only'
    Write-TestText $scriptArtifact 'synthetic build artifact'
    $files=@($exe,$scriptArtifact) | ForEach-Object { [pscustomobject]@{Name=[IO.Path]::GetFileName($_);SHA256=(Get-LpHash $_);Bytes=([IO.FileInfo]$_).Length} }
    $now=[datetime]::UtcNow.ToString('o')
    $manifest=Join-Path $evidence 'build-manifest.json'
    Write-TestJson $manifest @{Version='0.12.0';BuiltUtc=$now;BuildId='synthetic';BuildTool=@{Name='ps2exe';Version='1.0.18'};Sources=@($sources);Files=@($files)}
    $results=@()
    foreach ($id in $ids) {
        $result=Join-Path $evidence ($id+'.json'); $out=Join-Path $evidence ($id+'.out'); $err=Join-Path $evidence ($id+'.err')
        Write-TestJson $result @{Status='Passed';Assertions=1;Passed=1;Failed=0;CoverageGaps=@()}
        Write-TestText $out 'synthetic stdout'; Write-TestText $err ''
        $results += [pscustomobject]@{Id=$id;Status='Passed';Assertions=1;Passed=1;Failed=0;ExitCode=0;TimedOut=$false;CoverageGaps=@();ResultPath=$result;Stdout=$out;Stderr=$err}
    }
    $summary=Join-Path $evidence 'summary.json'
    $sourceHashes=@(Get-LpSnapshot $repo | Where-Object { $_.Path -notin @('.gitignore','assets/app.ico') })
    $sourceHashes += [pscustomobject]@{Path=$exe;SHA256=(Get-LpHash $exe)}
    $summaryValue=@{Suite='SafeJunkCleaner independent regression';Status='Passed';Scope='Release';StartedUtc=$now;FinishedUtc=$now;ExitCode=0;Failed=0;Blocked=0;CoverageGaps=@();GateErrors=@();Results=$results;Passed=$ids.Count;Cases=$ids.Count;Assertions=$ids.Count;SourceHashes=$sourceHashes;Exe=@{Path=$exe;SHA256=(Get-LpHash $exe)}}
    Write-TestJson $summary $summaryValue
    $screen=Join-Path $evidence 'desktop.synthetic.txt'; Write-TestText $screen 'NOT actual GUI evidence - synthetic gate fixture'
    $gui=Join-Path $evidence 'gui.json'
    Write-TestJson $gui @{Status='Passed';AcceptedUtc=$now;GuiSourceSHA256=(Get-LpHash (Join-Path $source 'src/Gui.ps1'));IconSHA256=(Get-LpHash (Join-Path $source 'assets/app.ico'));Checks=@(@('DesktopWindowObserved','RuleSelectionObserved','CandidatePagingAndKeepRestore','NoProductionDeletion','WhiteBackgroundIconObserved','CompactLayoutObserved','CleaningProfileConfirmationObserved','SingleWindowFlowObserved','ThreePresetImmediateApplyObserved','AdvancedCustomOffByDefaultObserved','DiscoveryAuthorizationCancelObserved','MaintenanceCancelObserved') | ForEach-Object { @{Name=$_;Passed=$true} });EvidenceFiles=@($screen)}
    $envelope=Join-Path $evidence 'promotion.json'
    Test-Case 'seal complete commit-bound synthetic acceptance including added case' {
        $null=& $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $summary -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath $envelope -Confirm:$false
    }
    $common=@{SourceRepository=$source;TargetRepository=$target;EvidencePath=$envelope}
    Test-Case 'read-only fast-forward preflight preserves real object database' {
        $before=@(Get-ChildItem (Join-Path $target '.git') -Recurse -File | ForEach-Object { $_.FullName+' '+(Get-LpHash $_.FullName) }) -join "`n"
        $r=& $promote @common
        if ($r.Status -ne 'Ready') { throw 'Not ready' }
        $after=@(Get-ChildItem (Join-Path $target '.git') -Recurse -File | ForEach-Object { $_.FullName+' '+(Get-LpHash $_.FullName) }) -join "`n"
        if ($before -cne $after) { throw 'Read-only preflight changed target .git' }
    }
    Test-Case 'missing evidence blocked' { Expect-Blocked { & $promote -SourceRepository $source -TargetRepository $target } 'evidence is required' }
    Test-Case 'execute requires expected HEADs' { Expect-Blocked { & $promote @common -Execute -Confirm:$false } 'both full expected HEADs' }
    Test-Case 'HEAD changed/stale expectation blocked' { Expect-Blocked { & $promote @common -ExpectedSourceHead $base } 'Expected HEAD mismatch' }
    Test-Case 'target HEAD changed/stale expectation blocked' { Expect-Blocked { & $promote @common -ExpectedTargetHead $next } 'Expected HEAD mismatch' }
    Test-Case 'WhatIf does not promote' {
        $r=& $promote @common -Execute -ExpectedSourceHead $next -ExpectedTargetHead $base -WhatIf
        if ($r.Executed -or ((Invoke-LpGit $target @('rev-parse','HEAD')) -join '') -ne $base) { throw 'WhatIf wrote HEAD' }
    }
    Test-Case 'dirty source blocked' {
        $p=Join-Path $source 'untracked.txt'; Write-TestText $p 'dirty'
        try { Expect-Blocked { & $promote @common } 'Dirty' } finally { Retain-TestPath $p }
    }
    Test-Case 'dirty target index blocked' {
        $p=Join-Path $target 'untracked.txt'; Write-TestText $p 'dirty'
        try { Expect-Blocked { & $promote @common } 'Dirty' } finally { Retain-TestPath $p }
    }
    Test-Case 'staged target index blocked' {
        $p=Join-Path $target 'staged.txt'; Write-TestText $p 'staged'
        $null=Invoke-LpGit $target @('add','staged.txt')
        try { Expect-Blocked { & $promote @common } 'Dirty' } finally { $null=Invoke-LpGit $target @('rm','--cached','staged.txt'); Retain-TestPath $p }
    }
    Test-Case 'uncommitted source cannot capture acceptance inputs' {
        $p=Join-Path $source 'pending.txt'; Write-TestText $p 'pending'
        try { Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -OutputPath (Join-Path $evidence 'uncommitted.json') -CaptureBuildInputs -Confirm:$false } 'Dirty' } finally { Retain-TestPath $p }
    }
    Test-Case 'unrelated ignored target metadata allowed' {
        $p=Join-Path $target 'ignored/file.txt'; Write-TestText $p 'precious'
        if ((& $promote @common).Status -ne 'Ready') { throw 'Unrelated ignored file blocked' }
    }
    Test-Case 'same-path ignored target file blocked' {
        $p=Join-Path $target 'incoming-same.txt'; Write-TestText $p 'precious'
        try { Expect-Blocked { & $promote @common } 'Ignored path conflicts' } finally { Retain-TestPath $p }
    }
    Test-Case 'ignored parent file blocks incoming child path' {
        $p=Join-Path $target 'incoming-child'; Write-TestText $p 'precious'
        try { Expect-Blocked { & $promote @common } 'Ignored path conflicts' } finally { Retain-TestPath $p }
    }
    Test-Case 'ignored directory with child blocks incoming parent file' {
        $p=Join-Path $target 'incoming-parent/file.txt'; Write-TestText $p 'precious'
        try { Expect-Blocked { & $promote @common } 'Ignored directory conflicts' } finally { Retain-TestPath (Join-Path $target 'incoming-parent') }
    }
    Test-Case 'unfinished merge blocked' {
        $p=Join-Path $target '.git/MERGE_HEAD'; Write-TestText $p $base
        try { Expect-Blocked { & $promote @common } 'Unfinished' } finally { Retain-TestPath $p }
    }
    Test-Case 'same and nested identity rejected' {
        Expect-Blocked { Assert-LpSeparate $source $source } 'Same or nested'
        Expect-Blocked { Assert-LpSeparate $source (Join-Path $source 'nested') } 'Same or nested'
    }
    Test-Case 'artifact mutation invalidates evidence' {
        $bytes=[IO.File]::ReadAllBytes($exe); Write-TestText $exe 'tampered'
        try { Expect-Blocked { & $promote @common } 'Sealed evidence changed' } finally { [IO.File]::WriteAllBytes($exe,$bytes) }
    }
    Test-Case 'expired envelope blocked' {
        $bytes=[IO.File]::ReadAllBytes($envelope); $v=Get-LpJson $envelope; $v.ExpiresUtc=[datetime]::UtcNow.AddHours(-1).ToString('o'); Write-TestJson $envelope $v
        try { Expect-Blocked { & $promote @common } 'expired' } finally { [IO.File]::WriteAllBytes($envelope,$bytes) }
    }
    Test-Case 'arbitrary Passed JSON cannot seal' {
        $bad=Join-Path $evidence 'bad.json'; Write-TestJson $bad @{Status='Passed'}
        Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $bad -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath (Join-Path $evidence 'bad-seal.json') -Confirm:$false } 'StartedUtc'
    }
    foreach ($addedId in @('Z98-added-case','Z99-added-case')) {
    Test-Case "AST-declared runner case $addedId cannot be omitted" {
        $bytes=[IO.File]::ReadAllBytes($summary); $v=Get-LpJson $summary; $v.Results=@($v.Results | Where-Object Id -ne $addedId); Write-TestJson $summary $v
        try { Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $summary -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath (Join-Path $evidence 'missing-case.json') -Confirm:$false } 'Missing/duplicate Release case' } finally { [IO.File]::WriteAllBytes($summary,$bytes) }
    }
    }
    foreach ($inputPath in @('src/Discovery.ps1','src/Maintenance.ps1')) {
        foreach ($inputKind in @('manifest','summary','capture')) {
            Test-Case "missing $inputPath in $inputKind blocks sealing" {
                $inputFile=@{manifest=$manifest;summary=$summary;capture=$capture}[$inputKind]
                $bytes=[IO.File]::ReadAllBytes($inputFile); $v=Get-LpJson $inputFile
                if ($inputKind -eq 'summary') { $v.SourceHashes=@($v.SourceHashes | Where-Object Path -ne $inputPath) }
                else { $v.Sources=@($v.Sources | Where-Object Path -ne $inputPath) }
                Write-TestJson $inputFile $v
                $reason=if ($inputKind -eq 'capture') { 'Build input snapshot differs' } else { 'Required input hash missing: '+$inputPath }
                try { Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $summary -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath (Join-Path $evidence 'missing-input.json') -Confirm:$false } $reason } finally { [IO.File]::WriteAllBytes($inputFile,$bytes) }
            }
        }
    }
    foreach ($guiName in @('CompactLayoutObserved','SingleWindowFlowObserved','ThreePresetImmediateApplyObserved','AdvancedCustomOffByDefaultObserved','DiscoveryAuthorizationCancelObserved','MaintenanceCancelObserved')) {
    Test-Case "missing GUI observation $guiName cannot seal or publish" {
        $bytes=[IO.File]::ReadAllBytes($gui); $v=Get-LpJson $gui; $v.Checks=@($v.Checks | Where-Object Name -ne $guiName); Write-TestJson $gui $v
        try {
            Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $summary -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath (Join-Path $evidence 'missing-gui.json') -Confirm:$false } ('Missing actual desktop acceptance: '+$guiName)
            Expect-Blocked { & (Join-Path $source 'scripts/publish.ps1') -BuildDirectory $evidence -VerificationDirectory $evidence -GuiAcceptancePath $gui } ('Missing desktop acceptance check: '+$guiName)
        } finally { [IO.File]::WriteAllBytes($gui,$bytes) }
    }
    }
    Test-Case 'expired original acceptance cannot be re-sealed' {
        $bytes=[IO.File]::ReadAllBytes($summary); $v=Get-LpJson $summary; $v.StartedUtc=[datetime]::UtcNow.AddHours(-73).ToString('o'); Write-TestJson $summary $v
        try { Expect-Blocked { & $seal -SourceRepository $source -ExpectedSourceHead $next -BuildManifestPath $manifest -SummaryPath $summary -GuiAcceptancePath $gui -BuildInputsPath $capture -OutputPath (Join-Path $evidence 'old-summary.json') -Confirm:$false } 'Expired or future evidence' } finally { [IO.File]::WriteAllBytes($summary,$bytes) }
    }
    Test-Case 'explicit execution fast-forwards only owned test main' {
        $r=& $promote @common -Execute -ExpectedSourceHead $next -ExpectedTargetHead $base -Confirm:$false
        if ($r.Status -ne 'FastForwarded' -or -not $r.Executed) { throw 'Did not fast-forward' }
    }
    Test-Case 'post-promotion is no-op' {
        if ((& $promote @common).Status -ne 'NoPromotionNeeded') { throw 'Not noop' }
    }
    Write-TestText (Join-Path $target 'target-only.txt') 'diverged target'
    $diverged=Commit-Test $target 'synthetic target divergence'
    Test-Case 'diverged target cannot be promoted' { Expect-Blocked { & $promote @common } 'git failed' }
    Write-TestText (Join-Path $source 'src/Core.ps1') 'source changed after evidence'
    $changed=Commit-Test $source 'synthetic source moved'
    Test-Case 'source moved invalidates commit binding' { Expect-Blocked { & $promote @common } 'not bound' }
    Write-Output "RESULT passed=$script:passed sandbox=$homePath (synthetic fixtures only; no product regression/GUI certification)"
    Write-TestJson (Join-Path $homePath 'result.json') @{Status='Passed';Assertions=$script:passed;FixtureDirectory=$homePath;SyntheticOnly=$true;Retained=$true;Version='0.12.0'}
} finally {
    Write-Output ('Fixture retained (success or failure): '+$homePath)
}
