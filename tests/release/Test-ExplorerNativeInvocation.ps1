#requires -Version 5.1
# Runs the actual production function AST, not a separate imitation of dotnet.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Repository,[Parameter(Mandatory=$true)][string]$FixtureParent)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'scripts/local-promotion-common.ps1')
$root=Join-Path (Get-LpPath $FixtureParent -Directory) ('native-'+[guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $root) { throw 'Native test fixture must be new.' }
[void][IO.Directory]::CreateDirectory($root)
[IO.File]::WriteAllText((Join-Path $root '.fixture-owner'),$root,[Text.UTF8Encoding]::new($true))
$source=Join-Path $Repository 'tools/explorer/Publish-Explorer.ps1'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if (@($errors).Count) { throw 'Cannot parse production publish tool.' }
$definitions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Invoke-ExplorerNative'},$true))
if ($definitions.Count -ne 1) { throw 'Exactly one production native invocation function required.' }
. ([scriptblock]::Create($definitions[0].Extent.Text))
$assemblyCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -ceq 'Add-Type' -and $n.Extent.Text -match '^Add-Type -AssemblyName System\.IO\.Compression(?:\.FileSystem)?$'},$true))
foreach ($call in $assemblyCalls) { & ([scriptblock]::Create($call.Extent.Text)) }
if (-not ('System.IO.Compression.ZipArchive' -as [type]) -or -not ('System.IO.Compression.ZipFile' -as [type])) { throw 'Production ZIP dependencies unavailable in a fresh PS5 process.' }
$child=Join-Path $root 'owned child with spaces.ps1'
$text=@'
param([int]$ExitCode,[string]$Probe)
[Console]::Out.WriteLine('PROBE='+$Probe)
[Console]::Error.WriteLine('')
[Console]::Error.WriteLine('NATIVE-STDERR-DIAGNOSTIC')
for ($i=0;$i -lt 128;$i++) {
 [Console]::Out.WriteLine(('O'*2048))
 [Console]::Error.WriteLine(('E'*2048))
}
[Console]::Out.WriteLine('STDOUT-END')
[Console]::Error.WriteLine('STDERR-END')
exit $ExitCode
'@
[IO.File]::WriteAllText($child,$text,[Text.UTF8Encoding]::new($true))
$script:checks=0
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('Assertion failed: '+$Name) };$script:checks++;Write-Host ('PASS '+$Name) }
$ps=Join-Path $PSHOME 'powershell.exe';$probe='owned path with spaces\'
foreach ($code in @(0,7)) {
 $log=Join-Path $root ('exit-'+$code+'.log');$message='';$result=$null
 try { $result=Invoke-ExplorerNative $ps @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$child,'-ExitCode',[string]$code,'-Probe',$probe) $log 'Expected native rejection' } catch { $message=$_.Exception.Message }
 $content=[IO.File]::ReadAllText($log,[Text.Encoding]::UTF8)
 Check ($content.Contains('NATIVE-STDERR-DIAGNOSTIC') -and $content.Contains('STDERR-END')) ('stderr retained through completion, exit '+$code)
 Check ($content.Contains('STDOUT-END')) ('stdout retained through completion, exit '+$code)
 Check ($content.Contains('PROBE='+$probe)) ('arguments preserve spaces and trailing slash, exit '+$code)
 Check ($content.Contains('ExitCode: '+$code)) ('actual exit code recorded, exit '+$code)
 Check ($ErrorActionPreference -ceq 'Stop') ('caller error policy unchanged, exit '+$code)
 if ($code -eq 0) { Check (-not $message -and $result.ExitCode -eq 0) 'blank/native stderr with exit zero succeeds under EAP Stop' }
 else { Check ($message -match 'Expected native rejection \(exit 7\)') 'nonzero native exit is not swallowed' }
}
$rejected=$false
try { $null=Invoke-ExplorerNative $ps @('-NoProfile','-Command','exit 0') (Join-Path $root 'exit-0.log') 'must not overwrite' } catch { $rejected=$true }
Check $rejected 'native log is never overwritten'
$result=@{Status='Passed';Assertions=$script:checks;FixtureDirectory=$root;PublishToolSHA256=(Get-LpHash $source);Retained=$true;ProductionFunctionExtracted=$true}
[IO.File]::WriteAllText((Join-Path $root 'result.json'),($result|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($true))
$result|ConvertTo-Json -Depth 5
