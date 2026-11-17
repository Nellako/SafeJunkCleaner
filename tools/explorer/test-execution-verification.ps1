param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$root=Join-Path $Repository 'artifacts\explorer'
$evidenceRoot=Join-Path $root 'verification-execution'
$stamp=[Guid]::NewGuid().ToString('D')
$log=Join-Path $evidenceRoot ('verification-' + $stamp + '.log')
foreach($name in @('execution-home','execution-nuget','execution-cache','execution-temp','execution-sandboxes','verification-execution')){[void][IO.Directory]::CreateDirectory((Join-Path $root $name))}
$env:DOTNET_ROOT=Join-Path $root 'toolchain\sdk'
$env:DOTNET_CLI_HOME=Join-Path $root 'execution-home';$env:NUGET_PACKAGES=Join-Path $root 'execution-nuget'
$env:NUGET_HTTP_CACHE_PATH=Join-Path $root 'execution-cache';$env:TEMP=Join-Path $root 'execution-temp';$env:TMP=$env:TEMP
$env:DOTNET_CLI_TELEMETRY_OPTOUT='1';$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE='1';$env:DOTNET_NOLOGO='1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true';$env:MSBUILDDISABLENODEREUSE='1';$env:DOTNET_CLI_UI_LANGUAGE='en-US'
$dotnet=Join-Path $env:DOTNET_ROOT 'dotnet.exe'
$project=Join-Path $Repository 'engine-tests\Explorer.Execution.Verification\Explorer.Execution.Verification.csproj'
$env:DOTNET_CLI_HOME=$env:DOTNET_CLI_HOME
& $dotnet restore $project --source https://api.nuget.org/v3/index.json --disable-parallel 2>&1 | Tee-Object -FilePath $log
if($LASTEXITCODE -ne 0){throw 'Verification restore failed'}
& $dotnet build $project --no-restore --configuration Release --disable-build-servers 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw 'Verification build failed'}
$dll=Join-Path $root 'bin\Explorer.Execution.Verification\Release\net10.0-windows\Explorer.Execution.Verification.dll'
& $dotnet $dll (Join-Path $root 'execution-sandboxes\verification') 2>&1 | Tee-Object -FilePath $log -Append
if($LASTEXITCODE -ne 0){throw ('Verification cases failed: ' + $LASTEXITCODE)}
Write-Output ('Evidence: '+$log)
