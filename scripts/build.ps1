#requires -Version 5.1
[CmdletBinding()]
param([switch]$ScriptOnly,[string]$Ps2ExeModulePath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\Version.ps1')
$metadata=Get-SjcVersionInfo;$version=$metadata.version;$fileVersion=$metadata.fileVersion
$encoding=[Text.UTF8Encoding]::new($true)
$sourceFiles=@('src\Main.ps1','src\Version.ps1','src\Rules.ps1','src\Core.ps1','src\Worker.ps1','src\Gui.ps1')
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
$sourceRecords += [pscustomobject]@{Path='version.json';SHA256=(Get-FileHash -LiteralPath (Join-Path $root 'version.json') -Algorithm SHA256).Hash}
$entry=[IO.File]::ReadAllText((Join-Path $root $sourceFiles[0]))
$modules=foreach($relative in $sourceFiles[1..5]){"`r`n# region $relative`r`n"+[IO.File]::ReadAllText((Join-Path $root $relative))+"`r`n# endregion`r`n"}
$marker='# <SJC-MODULES>'
if(($entry.Split(@($marker),[StringSplitOptions]::None)).Count -ne 2){throw 'Expected exactly one module marker.'}
$embedded='$script:SjcEmbeddedVersion = '+"[pscustomobject]@{version='$version';fileVersion='$fileVersion';planSchemaVersion=$($metadata.planSchemaVersion)}`r`n"
$combined=$entry.Replace($marker,$embedded+($modules -join "`r`n"))
$tokens=$null;$errors=$null
[void][Management.Automation.Language.Parser]::ParseInput($combined,[ref]$tokens,[ref]$errors)
if(@($errors).Count){throw "Combined source parse errors: $($errors -join '; ')"}
$buildId=(Get-Date -Format 'yyyyMMdd_HHmmss')+'_'+[guid]::NewGuid().ToString('N').Substring(0,8)
$directory=Join-Path $root ("artifacts\builds\$buildId")
[void][IO.Directory]::CreateDirectory($directory)
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
    Invoke-ps2exe -inputFile $source -outputFile $exe -noConsole -STA -DPIAware -iconFile $icon -title '星梦雨垃圾清理器' -description "星梦雨垃圾清理器 v$version" -product '星梦雨垃圾清理器' -version $fileVersion
    if(-not [IO.File]::Exists($exe)){throw 'EXE build was not created.'}
    $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
    if($info.FileVersion -ne $fileVersion){throw 'Unexpected EXE version.'}
    $files += [pscustomobject]@{Name=[IO.Path]::GetFileName($exe);SHA256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;Bytes=([IO.FileInfo]$exe).Length;FileVersion=$info.FileVersion;Signature=[string](Get-AuthenticodeSignature -LiteralPath $exe).Status}
    $tool=[pscustomobject]@{Name='ps2exe';Version=[string]$module.Version}
}
$manifest=[ordered]@{Version=$version;BuiltUtc=[datetime]::UtcNow.ToString('o');BuildId=$buildId;Sources=$sourceRecords;Files=$files;BuildTool=$tool;Verification='Build only; run regression and desktop acceptance before release.'}
[IO.File]::WriteAllText((Join-Path $directory 'build-manifest.json'),($manifest|ConvertTo-Json -Depth 8),$encoding)
[pscustomobject]@{BuildDirectory=$directory;Source=$source;Exe=$exe;Manifest=(Join-Path $directory 'build-manifest.json')}|ConvertTo-Json
