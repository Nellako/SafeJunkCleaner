#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
try {
    $context=New-SjcContext;$task=New-SjcTaskDirectory $context;$output=Join-Path $task 'selftest.json'
    $entry=Join-Path $RepoRoot 'src\Main.ps1';$hostPath=Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$hostPath;$info.Arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$entry+'" -WorkerMode SelfTest -OutputPath "'+$output+'"';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start();$null=$p.Handle;$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    $done=$p.WaitForExit(60000);if(-not $done){$p.Kill();[void]$p.WaitForExit(5000)}
    Assert-True 'source selftest exits within timeout' $done
    Assert-Equal 'source selftest exits zero' 0 $p.ExitCode
    Save-EvidenceText 'stdout' $stdout.GetAwaiter().GetResult()|Out-Null;Save-EvidenceText 'stderr' $stderr.GetAwaiter().GetResult()|Out-Null;$p.Dispose()
    Assert-True 'result on approved channel exists' ([IO.File]::Exists($output))
    $result=Get-Content -LiteralPath $output -Raw -Encoding UTF8|ConvertFrom-Json;Save-Evidence 'selftest' $result|Out-Null
    Assert-Equal 'source status success' 'Success' $result.Status $result.Error
    Assert-Equal 'all core and gui checks passed' 0 (@($result.Checks|Where-Object {-not $_.Passed}).Count)
    Assert-Equal 'real scan count' 2 $result.Scan.CandidateCount
    Assert-Equal 'real clean count' 1 $result.Clean.Deleted
    Assert-Equal 'real exclusion' 1 $result.Clean.Skipped
    Assert-Equal 'WPF gui selftest' 'Success' $result.Gui.Status (@($result.Gui.Failed)-join ';')
    Assert-True 'old synthetic target removed' (-not [IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-old.tmp')))
    Assert-True 'new synthetic target survives' ([IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-new.tmp')))
    Assert-True 'excluded synthetic target survives' ([IO.File]::Exists((Join-Path $result.SandboxRoot 'files\owned-kept.tmp')))
    $info.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$entry+'" -WorkerMode Bogus';$p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start();$null=$p.Handle;$o=$p.StandardOutput.ReadToEndAsync();$e=$p.StandardError.ReadToEndAsync();$done=$p.WaitForExit(15000);if(-not $done){$p.Kill()};Assert-True 'invalid mode fails' ($done -and $p.ExitCode -ne 0);$p.Dispose()
    Add-Limitation 'SelfTest owned sandbox retained; production cache roots and real recycle bin untouched.'
} catch {Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
Complete-TestCase
