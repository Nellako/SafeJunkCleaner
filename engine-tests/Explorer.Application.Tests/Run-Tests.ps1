param([Parameter(Mandatory=$true)][string]$Repository,[switch]$Locked)
$ErrorActionPreference='Stop'
$base=Join-Path $Repository 'artifacts\explorer'
foreach($name in @('application-home','application-nuget','application-cache','application-temp','evidence')){[void][IO.Directory]::CreateDirectory((Join-Path $base $name))}
$env:DOTNET_ROOT=Join-Path $base 'toolchain\sdk';$env:DOTNET_CLI_HOME=Join-Path $base 'application-home'
$env:NUGET_PACKAGES=Join-Path $base 'application-nuget';$env:NUGET_HTTP_CACHE_PATH=Join-Path $base 'application-cache'
$env:TEMP=Join-Path $base 'application-temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_NOLOGO='1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true';$env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$project=Join-Path $Repository 'engine-tests\Explorer.Application.Tests\Explorer.Application.Tests.csproj'
$log=Join-Path $base ('evidence\application-'+[Guid]::NewGuid().ToString('D')+'.log')
$restore=@('restore',$project,'--source','https://api.nuget.org/v3/index.json','--disable-parallel')
if($Locked){$restore+='--locked-mode'}
& $dotnet @restore 2>&1 | Tee-Object -FilePath $log
if($LASTEXITCODE -ne 0){throw 'Application restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw 'Application build failed'}
& $dotnet (Join-Path $base 'bin\Explorer.Application.Tests\Release\net10.0-windows\Explorer.Application.Tests.dll') 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw 'Application tests failed'}
Write-Output ('Evidence: '+$log)
