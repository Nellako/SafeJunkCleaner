#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$EvidenceDirectory)
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId 'ProfileContract' -ResultPath (Join-Path $EvidenceDirectory 'profile-contract.json') -EvidenceDirectory $EvidenceDirectory
$sandbox=New-OwnedSandbox;$context=$sandbox.Context
Assert-Equal 'default profile' 'Recommended' $context.CleaningProfile
Assert-Throws 'reject lower case profile' {Set-SjcCleaningProfile $context 'deep'}
$task=New-SjcTaskDirectory $context
[void](New-TestFile -Path (Join-Path $sandbox.Root 'files\owned-old.tmp') -AgeHours 120)
$scan=Invoke-SjcScan -Context $context -TaskDirectory $task -RuleIds @('SandboxOld')
Assert-Equal 'scan success' 'Success' $scan.Status
Assert-Equal 'scan profile' 'Recommended' $scan.CleaningProfile
$session=Open-SjcPreviewSession $scan.PlanPath
Set-SjcCleaningProfile $context 'Deep'
Assert-Equal 'deep context' 'Deep' $context.CleaningProfile
Assert-Throws 'session invalid after profile switch' {Get-SjcPreviewPage $session}
Close-SjcPreviewSession $session
$clean=Invoke-SjcClean -Context $context -TaskDirectory $task -RecycleMode $false
Assert-Equal 'old profile plan rejected' 'Failed' $clean.Status
Assert-Equal 'no deletion for stale profile' 0 $clean.Deleted
Set-SjcCleaningProfile $context 'Recommended'
Assert-Throws 'switch back does not revive plan' {Open-SjcPreviewSession $scan.PlanPath}
$deepTask=New-SjcTaskDirectory $context
Set-SjcCleaningProfile $context 'Deep'
$deepScan=Invoke-SjcScan -Context $context -TaskDirectory $deepTask -RuleIds @('SandboxOld')
Assert-Equal 'deep scan success' 'Success' $deepScan.Status
$meta=Unprotect-SjcText (Read-SjcSafeText (Join-Path $deepTask 'scan.meta.json'))|ConvertFrom-Json
Assert-Equal 'sealed deep profile' 'Deep' $meta.CleaningProfile
$snapshot=$meta.Rules[0]|ConvertFrom-Json
Assert-Equal 'sealed actual threshold' 24 $snapshot.MinimumAgeHours
Assert-Equal 'sealed policy deep threshold' 24 $snapshot.DeepMinimumAgeHours
$preferences=[pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='Deep'}
[void](Save-SjcPreferences $context $preferences)
Assert-Equal 'preferences roundtrip' 'Deep' (Read-SjcPreferences $context).CleaningProfile
Assert-Throws 'preferences unknown root rejected' {Save-SjcPreferences $context ([pscustomobject]@{RecycleMode=$true;SelectedRuleIds=@('SandboxOld');CleaningProfile='Deep';Root='C:\'})}
$payload=[pscustomobject]@{TaskDirectory=$deepTask;CancelPath='';ProgressPath='';RuleIds=@('SandboxOld');CleaningProfile='Deep'}
Assert-SjcWorkerPayload $payload 'Scan'
Assert-True 'worker valid profile payload' $true
$payload.CleaningProfile=@('Deep')
Assert-Throws 'worker array profile rejected' {Assert-SjcWorkerPayload $payload 'Scan'}
$payload.CleaningProfile='deep'
Assert-Throws 'worker lower case profile rejected' {Assert-SjcWorkerPayload $payload 'Scan'}
$payload.PSObject.Properties.Remove('CleaningProfile')
Assert-Throws 'worker missing profile rejected' {Assert-SjcWorkerPayload $payload 'Scan'}
$clean=Invoke-SjcClean -Context $context -TaskDirectory $deepTask -RecycleMode $false
Assert-Equal 'matching deep plan clean' 'Success' $clean.Status
Assert-Equal 'only owned synthetic deletion' 1 $clean.Deleted
$policy=@(Get-SjcRules $context)
Assert-True 'both age values positive' (@($policy|Where-Object{$_.MinimumAgeHours -le 0 -or $_.DeepMinimumAgeHours -le 0}).Count -eq 0)
$probe=New-SjcRule -Id 'Probe' -TemplateId 'Probe' -Name 'probe' -Group 'test' -Root (Join-Path $sandbox.Root 'files') -OverrideEnvironment @('SJC_TEST_CACHE_OVERRIDE')
$previous=[Environment]::GetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE')
try{[Environment]::SetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE','C:\untrusted');Assert-True 'configuration override refuses default rule' (-not(Test-SjcRuleConfiguration $probe));Assert-True 'configuration override not confused with process' (Test-SjcProcessesClosed $probe)}finally{[Environment]::SetEnvironmentVariable('SJC_TEST_CACHE_OVERRIDE',$previous)}
[void](Save-Evidence 'checks' $script:Checks.ToArray())
$failed=@($script:Checks|Where-Object{-not $_.Passed})
Write-Output ('PROFILE CHECKS '+$script:Checks.Count+' failed='+$failed.Count)
if($failed.Count){$failed|Format-Table -AutoSize;exit 1}
