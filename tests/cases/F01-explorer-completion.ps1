#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$RepoRoot,[Parameter(Mandatory=$true)][string]$CaseId,[Parameter(Mandatory=$true)][string]$ResultPath,[Parameter(Mandatory=$true)][string]$EvidenceDirectory,[switch]$LoadGui,[string]$ExePath='')
. (Join-Path $RepoRoot 'tests\lib\Harness.ps1') -RepoRoot $RepoRoot -CaseId $CaseId -ResultPath $ResultPath -EvidenceDirectory $EvidenceDirectory -LoadGui:$LoadGui
$root=Join-Path $env:SJC_TEST_RUNTIME_CACHE 'current.json'
try{
    if(-not $env:SJC_TEST_RUNTIME_CACHE -or -not (Test-Path $root)){throw 'Explicit isolated runtime required'}
    $pointer=Get-Content -LiteralPath $root -Raw -Encoding UTF8|ConvertFrom-Json
    $runtime=Join-Path $env:SJC_TEST_RUNTIME_CACHE $pointer.BuildId
    $hostExe=Join-Path $runtime 'sjc-explorer.exe'
    $manifestPath=Join-Path $runtime 'host-component-manifest.json'
    Assert-Equal 'runtime manifest matches pointer' $pointer.ManifestSha256 (Get-FileHash $manifestPath).Hash
    $manifest=Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8|ConvertFrom-Json
    foreach($part in $manifest.Components){if((Get-FileHash (Join-Path $runtime $part.Path)).Hash -ne $part.Sha256){throw 'Runtime component changed'}}
    $ps='C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
    $names=@('Test-ExplorerBatch','Test-ExplorerBatchPersistence','Test-ExplorerBatchBoundaries','Test-ExplorerQuotaRecovery','Test-ExplorerResources','Test-ExplorerMaintenanceIntegration','Test-ExplorerTaskButtons','Test-ExplorerResponseState')
    foreach($name in $names){
        $output=Join-Path $EvidenceDirectory ($name+'-evidence')
        $scriptPath=Join-Path $RepoRoot ('tests\'+$name+'.ps1')
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -File "'+$scriptPath+'" -Repository "'+$RepoRoot+'"'
        if($name -in 'Test-ExplorerBatch','Test-ExplorerBatchPersistence','Test-ExplorerQuotaRecovery','Test-ExplorerMaintenanceIntegration'){$arguments+=' -HostExe "'+$hostExe+'"'}
        if($name -eq 'Test-ExplorerTaskButtons'){$output=Join-Path $EvidenceDirectory 'buttons.json';$arguments+=' -ResultPath "'+$output+'"'}
        elseif($name -ne 'Test-ExplorerResponseState'){$arguments+=' -EvidenceDirectory "'+$output+'"'}
        $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$ps;$info.Arguments=$arguments;$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
        $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start();$stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
        $done=$p.WaitForExit(180000);if(-not $done){$p.Kill();[void]$p.WaitForExit(5000)}
        $text=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $EvidenceDirectory ($name+'.stdout.log')),$text,$script:Utf8Bom);[IO.File]::WriteAllText((Join-Path $EvidenceDirectory ($name+'.stderr.log')),$err,$script:Utf8Bom)
        Assert-True ($name+' exits within timeout') $done
        Assert-Equal ($name+' exit zero') 0 $p.ExitCode $err;$p.Dispose()
        if($name -eq 'Test-ExplorerResponseState'){$result=$text|ConvertFrom-Json}
        else{$childResultPath=if($name -eq 'Test-ExplorerTaskButtons'){$output}else{Join-Path $output 'result.json'};$result=Get-Content -LiteralPath $childResultPath -Raw -Encoding UTF8|ConvertFrom-Json}
        Assert-True ($name+' produced nonzero passed evidence') ($result.Passed -eq $true -and $result.Assertions -gt 0)
        foreach($check in $result.Checks){Assert-True ($name+': '+$check.Name) ([bool]$check.Passed)}
    }
    Add-Limitation 'All fixtures retained; actual native recycling, production state and real disks excluded.'
}catch{Assert-True ('unhandled: '+$_.Exception.Message) $false $_.ScriptStackTrace}
Complete-TestCase
