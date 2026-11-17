param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer'
$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk';$env:DOTNET_CLI_HOME=Join-Path $base 'home'
$env:NUGET_PACKAGES=Join-Path $base 'nuget';$env:NUGET_HTTP_CACHE_PATH=Join-Path $base 'cache';$env:TEMP=Join-Path $base 'temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US';$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe';$project=Join-Path $Repository 'engine-tests\Explorer.SelfTest.csproj'
& $dotnet restore $project --source https://api.nuget.org/v3/index.json --disable-parallel
if($LASTEXITCODE -ne 0){throw 'Selftest restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers
if($LASTEXITCODE -ne 0){throw 'Selftest build failed'}
$ErrorActionPreference='Continue'
& $dotnet (Join-Path $base 'bin\Explorer.SelfTest\Release\net10.0-windows\Explorer.SelfTest.dll') $base 2>&1 | Tee-Object -FilePath (Join-Path $base 'evidence\boundaries.log')
$code=$LASTEXITCODE;$ErrorActionPreference='Stop'
if($code -ne 0){throw 'Boundary selftest failed'}
