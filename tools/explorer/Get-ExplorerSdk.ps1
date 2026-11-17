param([Parameter(Mandatory=$true)][string]$Repository)
$ErrorActionPreference='Stop'
$root=Join-Path $Repository 'artifacts\explorer'
$toolchain=Join-Path $root 'toolchain'
if(Test-Path $toolchain){throw 'Toolchain directory must be new.'}
[void](New-Item -ItemType Directory -Path $toolchain)
$download=Join-Path $toolchain 'download'; $sdk=Join-Path $toolchain 'sdk'
[void](New-Item -ItemType Directory -Path $download)
[void](New-Item -ItemType Directory -Path $sdk)
$metadata=Join-Path $download 'releases.json'
Invoke-WebRequest -UseBasicParsing 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json' -OutFile $metadata
$m=Get-Content -Raw $metadata | ConvertFrom-Json
$version='10.0.403'
$entry=@($m.releases | ForEach-Object {$_.sdks} | Where-Object {$_.version -eq $version})[0]
$file=@($entry.files | Where-Object {$_.rid -eq 'win-x64' -and $_.name -like '*.zip'})[0]
if(!$file -or $version -match '-' -or $m.'support-phase' -eq 'eol' -or $file.url -notmatch '^https://builds\.dotnet\.microsoft\.com/dotnet/Sdk/'){throw 'No supported stable official SDK.'}
$zip=Join-Path $download 'sdk.zip'
Invoke-WebRequest -UseBasicParsing $file.url -OutFile $zip
if((Get-Item $zip).Length -gt 1GB){throw 'Download budget exceeded.'}
$actual=(Get-FileHash $zip -Algorithm SHA512).Hash.ToLowerInvariant()
if($actual -ne $file.hash.ToLowerInvariant()){throw 'Official SHA512 mismatch.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::ExtractToDirectory($zip,$sdk)
@{Version=$version;Url=$file.url;Sha512=$actual;Bytes=(Get-Item $zip).Length;MetadataUrl='https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json';SupportPhase=$m.'support-phase';Eol=$m.'eol-date'} | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $root 'sdk-provenance.json')
& (Join-Path $sdk 'dotnet.exe') --info
