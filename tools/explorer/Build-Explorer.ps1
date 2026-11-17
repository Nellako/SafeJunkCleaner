param([Parameter(Mandatory=$true)][string]$Repository,[switch]$Locked)
$ErrorActionPreference='Stop'
$root=Join-Path $Repository 'artifacts\explorer'
foreach($name in @('cache','temp','nuget','home','evidence')){[void][IO.Directory]::CreateDirectory((Join-Path $root $name))}
$env:DOTNET_ROOT=Join-Path $root 'toolchain\sdk'
$env:DOTNET_CLI_HOME=Join-Path $root 'home'; $env:NUGET_PACKAGES=Join-Path $root 'nuget'
$env:NUGET_HTTP_CACHE_PATH=Join-Path $root 'cache';$env:TEMP=Join-Path $root 'temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_UI_LANGUAGE='en-US'
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_NOLOGO='1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true';$env:MSBUILDDISABLENODEREUSE='1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE='false';$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH='false'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$packages=@(@('microsoft.data.sqlite','10.0.14','Microsoft','MIT'),@('microsoft.data.sqlite.core','10.0.14','Microsoft','MIT'),@('sqlitepclraw.bundle_e_sqlite3','2.1.13','Eric Sink','Apache-2.0'),@('sqlitepclraw.core','2.1.13','Eric Sink','Apache-2.0'),@('sqlitepclraw.provider.e_sqlite3','2.1.13','Eric Sink','Apache-2.0'),@('sqlitepclraw.lib.e_sqlite3','2.1.13','Eric Sink','Apache-2.0'))
$provenance=@()
foreach($p in $packages){
 $url='https://api.nuget.org/v3-flatcontainer/'+$p[0]+'/'+$p[1]+'/'+$p[0]+'.nuspec'
 $result=Invoke-WebRequest -UseBasicParsing $url
 [xml]$xml=$result.Content
 $metadata=$xml.package.metadata
 if($metadata.id.ToLowerInvariant() -ne $p[0] -or $metadata.version -ne $p[1] -or $metadata.authors -notlike ('*'+$p[2]+'*') -or $metadata.license.'#text' -ne $p[3]){throw ('Unexpected package identity/license: '+$p[0])}
 $provenance+=@{Id=$metadata.id;Version=$metadata.version;Authors=$metadata.authors;License=$metadata.license.'#text';Repository=$metadata.repository.url;MetadataUrl=$url;EffectiveUrl=$result.BaseResponse.ResponseUri.AbsoluteUri}
}
$provenance | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $root 'package-provenance.json')
$project=Join-Path $Repository 'engine\Explorer.Host\Explorer.Host.csproj'
$restore=@('restore',$project,'--source','https://api.nuget.org/v3/index.json','--disable-parallel')
if($Locked){$restore+='--locked-mode'}
& $dotnet @restore 2>&1 | Tee-Object -FilePath (Join-Path $root 'evidence\restore.log')
if($LASTEXITCODE -ne 0){throw 'Restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers 2>&1 | Tee-Object -FilePath (Join-Path $root 'evidence\build.log')
if($LASTEXITCODE -ne 0){throw 'Build failed'}
if ((Get-Content -Raw -LiteralPath (Join-Path $Repository 'version.json') | ConvertFrom-Json).version -ceq '0.14.0') {
 Write-Output 'Development compile completed; no runtime cache pointer written. Use Publish-Explorer.ps1 for self-contained Contract3 payload.'
} else { & (Join-Path $PSScriptRoot 'Write-HostManifest.ps1') -Repository $Repository }
