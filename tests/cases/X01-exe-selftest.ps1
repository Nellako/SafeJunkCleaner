#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui -ExePath $ExePath
. (Join-Path $RepoRoot 'tests\lib\release-support.ps1')
try {
    Assert-True 'EXE exists' ([IO.File]::Exists($ExePath)) $ExePath
    $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
    $expectedVersion=Get-SjcVersionInfo
    Assert-Equal 'EXE file version matches version.json' $expectedVersion.fileVersion $version.FileVersion
    # ps2exe writes a 4-part ProductVersion (x.y.z.0), so bind it to the declared product
    # version instead of requiring the 3-part display string verbatim.
    $productOk = ([string]$version.ProductVersion -eq ([string]$expectedVersion.version)) -or ([string]$version.ProductVersion -eq ([string]$expectedVersion.fileVersion))
    Assert-True 'EXE product version matches version.json (3- or 4-part form)' $productOk ([string]$version.ProductVersion + ' vs ' + [string]$expectedVersion.version + '/' + [string]$expectedVersion.fileVersion)
    # The EXE must carry the same white-background multi-size icon as assets/app.ico.
    $iconPath=Join-Path $RepoRoot 'assets\app.ico'
    Assert-True 'source icon exists for EXE comparison' ([IO.File]::Exists($iconPath)) $iconPath
    if([IO.File]::Exists($iconPath)){
        $iconBytes=[IO.File]::ReadAllBytes($iconPath)
        $iconDelta=Get-ExeIconDelta $ExePath $iconBytes
        [void](Save-Evidence 'exe-icon' ([pscustomobject]@{SourceIconSHA256=(Get-FileHash -LiteralPath $iconPath -Algorithm SHA256).Hash;ExePath=$ExePath;IconDelta=$iconDelta}))
        Assert-True 'EXE resource icon matches assets\app.ico bytes' ($null -eq $iconDelta) ([string]$iconDelta)
    }
    $signature=[string](Get-AuthenticodeSignature -LiteralPath $ExePath).Status
    Save-Evidence 'exe-facts' ([pscustomobject]@{SHA256=(Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash;FileVersion=$version.FileVersion;Signature=$signature})|Out-Null
    if($signature -ne 'Valid'){Add-Limitation ('Authenticode='+$signature+'; unsigned is disclosed, not proof of trust.')}
    $parent=Join-Path $EvidenceDirectory ('exe-owned-'+[guid]::NewGuid().ToString('N'))
    if(Test-Path -LiteralPath $parent){throw 'New EXE test parent required'}
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ExePath;$info.Arguments='-end -WorkerMode SelfTest -SelfTestParentDirectory "'+$parent+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start();$null=$p.Handle;$done=$p.WaitForExit(60000);if(-not $done){$p.Kill();[void]$p.WaitForExit(5000)}
    Assert-True 'EXE completes within timeout' $done
    Assert-Equal 'EXE exit zero' 0 $p.ExitCode;$p.Dispose()
    $logs=@(Get-ChildItem -LiteralPath $parent -Recurse -File -Filter 'selftest-*.json')
    Assert-Equal 'EXE writes exactly one owned selftest log' 1 $logs.Count
    if($logs.Count -ne 1){throw 'SelfTest output missing or ambiguous'}
    $output=$logs[0].FullName
    $result=Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json;Save-Evidence 'exe-result' $result|Out-Null
    Assert-True 'EXE result stays under requested test parent' (Test-SjcPathWithin $result.SandboxRoot $parent)
    $task=[IO.Path]::GetDirectoryName($result.Scan.PlanPath)
    Assert-Equal 'EXE selftest success' 'Success' $result.Status $result.Error
    Assert-Equal 'all EXE checks passed' 0 (@($result.Checks|Where-Object {-not $_.Passed}).Count)
    Assert-Equal 'EXE GUI success' 'Success' $result.Gui.Status (@($result.Gui.Failed)-join ';')
    Assert-Equal 'EXE real candidate count' 2 $result.Scan.CandidateCount
    Assert-Equal 'EXE real deleted count' 1 $result.Clean.Deleted
    Assert-Equal 'EXE real excluded count' 1 $result.Clean.Skipped
    Assert-True 'EXE new target survives' ([IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-new.tmp')))
    Assert-True 'EXE excluded target survives' ([IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-kept.tmp')))
    Assert-True 'EXE old target removed' (-not [IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-old.tmp')))
    Assert-True 'EXE records artificial deletion before execution' ([IO.File]::Exists((Join-Path $task 'test-deletion-manifest.json')))
    Assert-True 'EXE preserves single-use cleanup claim' ([IO.File]::Exists((Join-Path $task 'clean.claimed')))
    Add-DeclaredExclusion 'No real recycle-bin empty or production cache scan/clean; EXE selftest uses its own GUID sandbox.'
} catch {Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
Complete-TestCase
