#requires -Version 5.1
[CmdletBinding()]
param([switch]$ScriptOnly,[string]$Ps2ExeModulePath,[string]$ExplorerDirectory,[string]$ModelDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Version.ps1')
$metadata=Get-SjcVersionInfo;$version=$metadata.version;$fileVersion=$metadata.fileVersion
$encoding=[Text.UTF8Encoding]::new($true)
. (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
$noModel=Test-LpNoModelVersion $version;$componentVersion=($noModel -or $version -ceq '0.13.0')
if ($noModel -and $ModelDirectory) { throw '0.14 ModelMode=Absent forbids ModelDirectory, including old caches.' }
if (-not $noModel -and [bool]$ExplorerDirectory -ne [bool]$ModelDirectory) { throw '0.13 ExplorerDirectory and ModelDirectory must be supplied together.' }
if ($ExplorerDirectory -and -not $componentVersion) { throw 'Explicit components are supported only by component versions.' }
$componentInputs=@();$sourceSnapshot=@();$sourceSetHash=$null
if ($componentVersion) { $sourceSnapshot=@(Get-LpWorkingSources $root);$sourceSetHash=Get-LpSourceSetHash $sourceSnapshot }
if ($ExplorerDirectory) {
    $componentInputs=@([pscustomobject]@{Name='ExplorerHost';Root='explorer';Directory=(Get-LpPath $ExplorerDirectory -Directory);ManifestName='host-component-manifest.json'})
    if (-not $noModel) { $componentInputs += [pscustomobject]@{Name='Model';Root='model';Directory=(Get-LpPath $ModelDirectory -Directory);ManifestName='component-manifest.json'} }
    foreach ($c in $componentInputs) { $c | Add-Member NoteProperty ManifestSHA256 (Get-LpHash (Join-Path $c.Directory $c.ManifestName)) }
}
$sourceFiles=@(Get-LpProductSources $version | Where-Object { $_ -like 'src/*.ps1' } | ForEach-Object { $_.Replace('/','\') })
$sourceRecords=@()
foreach($relative in $sourceFiles){
    $file=Join-Path $root $relative
    if(-not [IO.File]::Exists($file)){throw "Missing source: $relative"}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw "Parser errors in ${relative}: $($errors -join '; ')"}
    $bytes=[IO.File]::ReadAllBytes($file)
    if($bytes.Length -lt 3 -or $bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191){throw "UTF-8 BOM required: $relative"}
    $sourceRecords += [pscustomobject]@{Path=$relative;SHA256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
}
$extraInputs=@('version.json','assets\app.ico','scripts\build.ps1')
if ($componentVersion) { $extraInputs += 'scripts\local-promotion-common.ps1' }
foreach($relative in $extraInputs){
    $file=Join-Path $root $relative
    if(-not [IO.File]::Exists($file)){throw "Missing build input: $relative"}
    $sourceRecords += [pscustomobject]@{Path=$relative;SHA256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
}
if ($componentVersion) { foreach ($r in $sourceRecords) { $r.Path=$r.Path.Replace('\','/') } }
$entry=[IO.File]::ReadAllText((Join-Path $root $sourceFiles[0]))
$modules=foreach($relative in $sourceFiles[1..($sourceFiles.Count-1)]){"`r`n# region $relative`r`n"+[IO.File]::ReadAllText((Join-Path $root $relative))+"`r`n# endregion`r`n"}
$marker='# <SJC-MODULES>'
if(($entry.Split(@($marker),[StringSplitOptions]::None)).Count -ne 2){throw 'Expected exactly one module marker.'}
$embedded='$script:SjcEmbeddedVersion = '+"[pscustomobject]@{version='$version';fileVersion='$fileVersion';planSchemaVersion=$($metadata.planSchemaVersion)}`r`n"
$displayVersion=Get-SjcDisplayVersion
if($displayVersion -cne $version){
    $embedded += '$script:SjcDisplayVersion = '+"'$displayVersion'`r`n"
}
$iconBase64=[Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $root 'assets\app.ico')))
$embedded += '$script:SjcEmbeddedIconBase64 = '+"'$iconBase64'`r`n"
if ($componentInputs.Count) {
    $embedded += '$script:SjcEmbeddedExplorerManifestSha256 = '+"'$($componentInputs[0].ManifestSHA256)'`r`n"
    if (-not $noModel) { $embedded += '$script:SjcEmbeddedModelManifestSha256 = '+"'$($componentInputs[1].ManifestSHA256)'`r`n" }
}
$combined=$entry.Replace($marker,$embedded+($modules -join "`r`n"))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw "Combined source parse errors: $($errors -join '; ')"}
$buildId=(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
$directory=Join-Path $root ("artifacts\builds\$buildId")
if (Test-Path -LiteralPath $directory) { throw 'Build directory must not already exist.' }
[void](New-Item -ItemType Directory -Path $directory -ErrorAction Stop)
if ($version -ceq '0.17.0') {
    # Keep C# source mode for isolated developer tests, but never compile it at
    # product startup. In WinPS CodeDOM needs a writable, stable TEMP directory.
    $compilerRoot=Join-Path $root ('artifacts\desktop-bridge-compiler\'+$buildId)
    [void][IO.Directory]::CreateDirectory($compilerRoot)
    $compiler=Join-Path ([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()) 'csc.exe'
    $sources=@()
    foreach($variable in '$nativeSource','$script:SjcExplorerBridgeSource'){
        $assign=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -ceq $variable},$true))
        if($assign.Count -ne 1){throw "Expected one desktop bridge assignment: $variable"}
        $p=Join-Path $compilerRoot ('Bridge'+$sources.Count+'.cs')
        [IO.File]::WriteAllText($p,$assign[0].Right.Expression.SafeGetValue(),$encoding);$sources+=$p
    }
    $library=Join-Path $compilerRoot 'SafeJunkCleaner.DesktopBridge.dll'
    & $compiler /nologo /target:library /optimize+ /debug- /reference:System.Web.Extensions.dll /reference:System.Runtime.Serialization.dll /reference:System.Xml.dll ("/out:"+$library) @sources
    if($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($library)){throw 'Desktop bridge compilation failed.'}
    $loader="[void][Reflection.Assembly]::Load([Convert]::FromBase64String('"+[Convert]::ToBase64String([IO.File]::ReadAllBytes($library))+"'))`r`n"
    $combined=$entry.Replace($marker,$embedded+$loader+($modules -join "`r`n"))
    [void][Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)
    if(@($errors).Count){throw 'Precompiled desktop bridge script did not parse.'}
}
$source=Join-Path $directory "SafeJunkCleaner_v$version.ps1"
[IO.File]::WriteAllText($source,$combined,$encoding)
$files=@([pscustomobject]@{Name=[IO.Path]::GetFileName($source);SHA256=(Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]$source).Length})
$exe=$null;$tool=$null
if(-not $ScriptOnly){
    if($Ps2ExeModulePath){$module=Get-Module -ListAvailable -Name $Ps2ExeModulePath|Where-Object Version -eq ([version]'1.0.18')|Select-Object -First 1}
    else{$module=Get-Module -ListAvailable -Name ps2exe|Where-Object Version -eq ([version]'1.0.18')|Select-Object -First 1}
    if(-not $module){throw 'ps2exe 1.0.18 is required. Install it explicitly or pass -Ps2ExeModulePath; -ScriptOnly does not require it.'}
    Import-Module -Name $module.Path -Force
    $icon=Join-Path $root 'assets\app.ico'
    if(-not [IO.File]::Exists($icon)){throw 'Application icon missing.'}
    $exe=Join-Path $directory "星梦雨垃圾清理器_v$version.exe"
    Invoke-ps2exe -inputFile $source -outputFile $exe -noConsole -STA -DPIAware -longPaths -iconFile $icon -title '星梦雨垃圾清理器' -description "星梦雨垃圾清理器 v$version" -product '星梦雨垃圾清理器' -version $fileVersion
    if(-not [IO.File]::Exists($exe)){throw 'EXE build was not created.'}
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    if($info.FileVersion -ne $fileVersion){throw 'Unexpected EXE version.'}
    $files += [pscustomobject]@{Name=[IO.Path]::GetFileName($exe);SHA256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]$exe).Length;FileVersion=$info.FileVersion;Signature=[string](Get-AuthenticodeSignature -LiteralPath $exe).Status}
    $runtimeConfig=$exe+'.config'
    if (-not [IO.File]::Exists($runtimeConfig)) { throw 'ps2exe long-path runtime configuration missing.' }
    $files += [pscustomobject]@{Name=[IO.Path]::GetFileName($runtimeConfig);SHA256=(Get-FileHash -LiteralPath $runtimeConfig -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]$runtimeConfig).Length}
    $tool=[pscustomobject]@{Name='ps2exe';Version=[string]$module.Version}
}
$manifest=[ordered]@{Version=$version;BuiltUtc=[datetime]::UtcNow.ToString('o');BuildId=$buildId;Sources=$sourceRecords;Files=$files;BuildTool=$tool;Verification='Build only; run regression and desktop acceptance before release.'}
if ($componentVersion) {
    $components=@()
    foreach ($c in $componentInputs) {
        $targetRoot=Join-Path $directory $c.Root;$null=New-Item -ItemType Directory -Path $targetRoot
        foreach ($f in @(Get-LpCandidateFiles $c.Directory)) {
            $relative=Get-LpCandidateName ($f.FullName.Substring($c.Directory.Length+1).Replace('\','/'))
            $target=Join-Path $targetRoot $relative;$null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
            [IO.File]::Copy($f.FullName,$target,$false)
        }
        if ((Get-LpHash (Join-Path $c.Directory $c.ManifestName)) -ne $c.ManifestSHA256 -or (Get-LpHash (Join-Path $targetRoot $c.ManifestName)) -ne $c.ManifestSHA256) { throw 'Component manifest changed during build copy.' }
        $components += [pscustomobject]@{Name=$c.Name;Root=$c.Root;ManifestPath=($c.Root+'/'+$c.ManifestName);ManifestSHA256=$c.ManifestSHA256}
    }
    if ((Get-LpSourceSetHash @(Get-LpWorkingSources $root)) -ne $sourceSetHash) { throw 'Source changed during build.' }
    $snapshot=[ordered]@{Schema='SafeJunkCleaner.SourceManifest.v1';GitHead=((Invoke-LpGit $root @('rev-parse','--verify','HEAD')) -join '');Dirty=(@(Invoke-LpGit $root @('status','--porcelain=v1','--untracked-files=all')).Count -gt 0);SourceSetSha256=$sourceSetHash;Sources=$sourceSnapshot}
    $snapshotPath=Join-Path $directory 'source-manifest.json'
    [IO.File]::WriteAllText($snapshotPath,($snapshot | ConvertTo-Json -Depth 8),$encoding)
    $manifest.LongPathRuntimeConfig=($noModel -and -not $ScriptOnly)
    $manifest.ComponentSchema='SafeJunkCleaner.Components.v1'
    $manifest.Components=$components
    $expectedCount=if ($noModel) { 1 } else { 2 }
    if ($noModel) { $manifest.ModelMode='Absent';$manifest.AlgorithmMode='Heuristic' }
    $manifest.ComponentsComplete=($componentInputs.Count -eq $expectedCount -and -not $ScriptOnly)
    $manifest.BuildStage=if ($manifest.ComponentsComplete) { 'ComponentsBuilt' } else { 'DevelopmentIncomplete' }
    $manifest.SourceTree=[pscustomobject]@{ManifestPath='source-manifest.json';SHA256=(Get-LpHash $snapshotPath);SourceSetSha256=$sourceSetHash}
    if ($manifest.ComponentsComplete) {
        $buildObject=[pscustomobject]$manifest
        $null=Get-LpComponentFacts $directory $buildObject $root
        foreach ($c in $componentInputs) {
            $m=Get-LpJson (Join-Path $c.Directory $c.ManifestName)
            $componentRecords=if ($c.Name -ceq 'ExplorerHost') { $m.Components } else { $m.Files }
            Assert-LpExactFiles $c.Directory $componentRecords @($c.ManifestName)
        }
    }
}
[IO.File]::WriteAllText((Join-Path $directory 'build-manifest.json'),($manifest|ConvertTo-Json -Depth 8),$encoding)
[pscustomobject]@{BuildDirectory=$directory;Source=$source;Exe=$exe;Manifest=(Join-Path $directory 'build-manifest.json')}|ConvertTo-Json
