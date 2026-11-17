param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer'
$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk';$env:DOTNET_CLI_HOME=Join-Path $base 'home'
$env:NUGET_PACKAGES=Join-Path $base 'nuget';$env:NUGET_HTTP_CACHE_PATH=Join-Path $base 'cache';$env:TEMP=Join-Path $base 'temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US';$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe';$project=Join-Path $Repository 'engine-tests\Explorer.Analysis.Tests\Explorer.Analysis.Tests.csproj'
& $dotnet restore $project --source (Join-Path $base 'nuget') --disable-parallel
if($LASTEXITCODE -ne 0){throw 'Analysis test restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers
if($LASTEXITCODE -ne 0){throw 'Analysis test build failed'}
& $dotnet (Join-Path $base 'bin\Explorer.Analysis.Tests\Release\net10.0-windows\Explorer.Analysis.Tests.dll') $base
if($LASTEXITCODE -ne 0){throw 'Analysis test failed'}
