#requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$BuildRoot,[Parameter(Mandatory=$true)][string]$Evidence)
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if(Test-Path -LiteralPath $Evidence){throw 'New evidence directory required'}
$root=[IO.Path]::GetFullPath($BuildRoot);$exe=Join-Path $root '星梦雨垃圾清理器_v0.17.0.exe'
$combined=Join-Path $root 'SafeJunkCleaner_v0.17.0.ps1'
$source=[IO.File]::ReadAllText($combined);$tokens=$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Invalid packaged script'}
# Load exactly the shipped function bodies, without starting the application or
# replacing the production routing/manifest checks. No job payload is executed.
foreach($node in $ast.EndBlock.Statements){if($node -is [Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create($node.Extent.Text))}}
$assignment=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.AssignmentStatementAst] -and $_.Left.Extent.Text -ceq '$script:SjcExplorerBridgeSource'})
if($assignment.Count -ne 1){throw 'Missing shipped verifier source'};$script:SjcExplorerBridgeSource=$assignment[0].Right.Expression.SafeGetValue()
$bind=[regex]::Match($source,"(?m)^\`$script:SjcEmbeddedExplorerManifestSha256 = '([0-9A-Fa-f]{64})'");if(!$bind.Success){throw 'Missing package manifest binding'}
$script:SjcEmbeddedExplorerManifestSha256=$bind.Groups[1].Value;$script:SjcEntryPath=$exe;$script:SjcIsPackaged=$true
$null=[IO.Directory]::CreateDirectory($Evidence);$payload=Join-Path $Evidence 'unused-payload.json';$output=Join-Path $Evidence 'unused-output.json'
$expected=Join-Path $root 'explorer\sjc-quickclean.exe';$jobs=@()
foreach($action in 'Scan','Clean','Recycle'){
 $spec=Get-SjcGuiLaunchSpec $action $payload $output
 if($spec.FileName -cne $expected -or -not $spec.Arguments.StartsWith(('job '+$action+' '))){throw "Unexpected GUI launch target for $action"}
 $jobs+=$action
}
$actual=Invoke-SjcQuickCleanQuery -Operation History -Request @{};if($actual.Items -isnot [Collections.IList]){throw 'History did not return an array'}
$result=@{Passed=$true;VerifiedJobRoutes=$jobs;HostSha256=(Get-FileHash $expected).Hash;EmbeddedManifest=$script:SjcEmbeddedExplorerManifestSha256;PackagedScriptSha256=(Get-FileHash $combined).Hash;HistoryQueryCompleted=$true;RealDeleteRequested=$false}
[IO.File]::WriteAllText((Join-Path $Evidence 'result.json'),($result|ConvertTo-Json),[Text.UTF8Encoding]::new($true))
