param([Parameter(Mandatory=$true)][string]$Repository,[switch]$Locked)
$ErrorActionPreference='Stop'
$root=Join-Path $Repository 'artifacts\explorer'
foreach($name in @('execution-home','execution-nuget','execution-cache','execution-temp','evidence')){[void][IO.Directory]::CreateDirectory((Join-Path $root $name))}
$env:DOTNET_ROOT=Join-Path $root 'toolchain\sdk'
$env:DOTNET_CLI_HOME=Join-Path $root 'execution-home';$env:NUGET_PACKAGES=Join-Path $root 'execution-nuget'
$env:NUGET_HTTP_CACHE_PATH=Join-Path $root 'execution-cache';$env:TEMP=Join-Path $root 'execution-temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_NOLOGO='1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true';$env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$project=Join-Path $Repository 'engine-tests\Explorer.Execution.Tests\Explorer.Execution.Tests.csproj'
$log=Join-Path $root ('evidence\execution-'+[Guid]::NewGuid().ToString('D')+'.log')
$restore=@('restore',$project,'--source','https://api.nuget.org/v3/index.json','--disable-parallel')
if($Locked){$restore+='--locked-mode'}
& $dotnet @restore 2>&1 | Tee-Object -FilePath $log
if($LASTEXITCODE -ne 0){throw 'Execution restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw 'Execution build failed'}
$dll=Join-Path $root 'bin\Explorer.Execution.Tests\Release\net10.0-windows\Explorer.Execution.Tests.dll'
& $dotnet $dll (Join-Path $root 'execution-sandboxes') 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw 'Execution self-test failed'}
Write-Output ('Evidence: '+$log)
