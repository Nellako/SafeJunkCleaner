#requires -Version 5.1
<#
Offline packaging of maintainer-owned, trusted local publish output. Never runs
release scripts or the application. All four paths must be absolute; output must
not exist. A failure deliberately leaves the new output directory for diagnosis.
Example: .\scripts\package-local.ps1 -SourceRepository C:\src\sjc `
 -ExpectedSourceHead <40-hex> -ReleaseDirectory C:\release\v0.12 `
 -OutputDirectory C:\delivery\new-package
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceRepository,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedSourceHead,
    [Parameter(Mandatory=$true)][string]$ReleaseDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$encoding=[Text.UTF8Encoding]::new($true)

function Get-AbsolutePath([string]$Path) {
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f]') { throw 'An absolute local drive path is required.' }
    $full=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\','/')) { throw 'Drive roots are not accepted.' }
    return $full
}
function Test-Within([string]$Child,[string]$Parent) {
    return $Child.Equals($Parent,[StringComparison]::OrdinalIgnoreCase) -or $Child.StartsWith($Parent+'\',[StringComparison]::OrdinalIgnoreCase)
}
function Assert-NoLinks([string]$Path) {
    # Shared check permits only CLOUD/CLOUD_1..F non-name-surrogate tags.
    $null=Get-LpPath $Path
}
function Get-RelativeName([string]$Name) {
    $name=$Name.Replace('\','/')
    if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('/') -or $name -match '[\x00-\x1f<>:"|?*]' ) { throw 'Invalid relative file path.' }
    foreach ($part in $name.Split('/')) {
        if ($part -in @('','.','..') -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') { throw 'Unsafe relative file path.' }
    }
    return $name
}
function Assert-PublicPath([string]$Name) {
    if ($Name -match '(?i)(^|/)(\.git|private|raw[-_]?logs?|logs?|screenshots?|artifacts|releases)(/|$)' -or $Name -match '(?i)\.(log|png|jpe?g|gif|bmp|webp|dmp|etl)$') { throw "Private/raw evidence is not a delivery input: $Name" }
}
function Invoke-LocalGit([string[]]$Arguments) {
    # Process API preserves NUL-delimited tree names without shell interpretation.
    $all=@('--no-optional-locks','-c','core.quotepath=false','-C',$script:source)+$Arguments
    $quoted=@($all | ForEach-Object { '"'+($_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"' })
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName='git.exe';$start.Arguments=$quoted -join ' '
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    try {
        [void]$process.Start()
        $errorTask=$process.StandardError.ReadToEndAsync()
        $text=$process.StandardOutput.ReadToEnd()
        $process.WaitForExit()
        $errorText=$errorTask.Result
        if ($process.ExitCode -ne 0) { throw "Local git failed: $errorText" }
        return $text
    } finally { $process.Dispose() }
}
function Assert-Snapshot {
    $root=(Invoke-LocalGit @('rev-parse','--show-toplevel')).Trim().Replace('/','\')
    if (-not $source.Equals($root,[StringComparison]::OrdinalIgnoreCase)) { throw 'SourceRepository must be the exact Git working-tree root.' }
    if ((Invoke-LocalGit @('rev-parse','--is-bare-repository')).Trim() -ne 'false') { throw 'A working repository is required.' }
    if ((Invoke-LocalGit @('rev-parse','--verify','HEAD')).Trim() -ne $ExpectedSourceHead) { throw 'HEAD does not match ExpectedSourceHead.' }
    if ((Invoke-LocalGit @('status','--porcelain=v1','--untracked-files=all','--ignore-submodules=none')).Length -ne 0) { throw 'Source repository must be clean, including untracked files.' }
    if ((Invoke-LocalGit @('ls-files','-v')) -cmatch '(?m)^[a-zS] ') { throw 'Skip-worktree/assume-unchanged files are not accepted.' }
}
function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Read-Json([string]$Path) { return [IO.File]::ReadAllText($Path,[Text.Encoding]::UTF8) | ConvertFrom-Json }
function Write-NewText([string]$Path,[string]$Text) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $bytes=$encoding.GetPreamble()+$encoding.GetBytes($Text);$stream.Write($bytes,0,$bytes.Length) } finally { $stream.Dispose() }
}
function Get-Files([string]$Root) {
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and -not (Test-LpCloudPlaceholder $item.FullName)) { throw 'Linked/unknown-tag release entries are not accepted.' }
        if ($item.PSIsContainer) { Get-Files $item.FullName } else { $item }
    }
}
function Test-Zip([string]$Path,$Expected,[bool]$GitBlobs) {
    $seen=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $zip=[IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName.EndsWith('/')) {
                $dir=Get-RelativeName $entry.FullName.TrimEnd('/')
                if ($entry.Length -ne 0 -or @($Expected.Keys | Where-Object { $_.StartsWith($dir+'/',[StringComparison]::Ordinal) }).Count -eq 0) { throw 'Unexpected ZIP directory.' }
                continue
            }
            $name=Get-RelativeName $entry.FullName
            if ($entry.FullName -cne $name -or -not $seen.Add($name) -or -not $Expected.ContainsKey($name)) { throw 'Unexpected or duplicate ZIP entry.' }
            $record=$Expected[$name]
            $hash=if ($GitBlobs) { [Security.Cryptography.SHA1]::Create() } else { [Security.Cryptography.SHA256]::Create() }
            $stream=$entry.Open()
            try {
                if ($GitBlobs) {
                    $header=[Text.Encoding]::UTF8.GetBytes("blob $($entry.Length)"+[char]0)
                    [void]$hash.TransformBlock($header,0,$header.Length,$header,0)
                }
                $buffer=New-Object byte[] 65536;$length=0L
                while (($count=$stream.Read($buffer,0,$buffer.Length)) -gt 0) { [void]$hash.TransformBlock($buffer,0,$count,$buffer,0);$length+=$count }
                [void]$hash.TransformFinalBlock((New-Object byte[] 0),0,0)
                $actual=([BitConverter]::ToString($hash.Hash)).Replace('-','')
                if ($length -ne $entry.Length -or ($null -ne $record.Bytes -and $length -ne $record.Bytes) -or $actual -ne $record.Hash) { throw "ZIP entry content mismatch: $name" }
            } finally { $stream.Dispose();$hash.Dispose() }
        }
        if ($seen.Count -ne $Expected.Count) { throw 'ZIP file set differs from expected files.' }
    } finally { $zip.Dispose() }
}

try {
    # Load only the trusted helper beside this tool, never from release inputs.
    . (Join-Path $PSScriptRoot 'local-promotion-common.ps1')
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source=Get-AbsolutePath $SourceRepository
    $release=Get-AbsolutePath $ReleaseDirectory
    $output=Get-AbsolutePath $OutputDirectory
    foreach ($path in @($source,$release,$output)) { Assert-NoLinks $path }
    if (-not [IO.Directory]::Exists($source) -or -not [IO.Directory]::Exists($release)) { throw 'Source and release directories must exist.' }
    if ((Test-Within $output $source) -or (Test-Within $source $output) -or (Test-Within $output $release) -or (Test-Within $release $output)) { throw 'Output must not overlap source or release.' }
    if (Test-Path -LiteralPath $output) { throw 'OutputDirectory must not exist; existing packages are never overwritten.' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($output))) { throw 'Output parent must already exist.' }
    Assert-Snapshot
    $version=Read-Json (Join-Path $source 'version.json')
    if ($version.version -ne '0.12.0' -or $version.fileVersion -ne '0.12.0.0') { throw 'Only v0.12.0 source is supported.' }
    $manifest=Read-Json (Join-Path $release 'release-manifest.json')
    if ($manifest.Version -ne $version.version) { throw 'Release version mismatch.' }
    $expected=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($manifest.Files)) {
        $name=Get-RelativeName ([string]$record.Path)
        Assert-PublicPath $name
        if ($name -eq 'release-manifest.json' -or $expected.ContainsKey($name) -or [string]$record.SHA256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Invalid/duplicate release manifest record.' }
        $file=Join-Path $release $name
        if (-not [IO.File]::Exists($file) -or (Get-Hash $file) -ne $record.SHA256) { throw "Release hash mismatch: $name" }
        $expected.Add($name,[pscustomobject]@{Hash=$record.SHA256;Bytes=([IO.FileInfo]$file).Length})
    }
    $expected.Add('release-manifest.json',[pscustomobject]@{Hash=(Get-Hash (Join-Path $release 'release-manifest.json'));Bytes=([IO.FileInfo](Join-Path $release 'release-manifest.json')).Length})
    $actualFiles=@(Get-Files $release)
    foreach ($file in $actualFiles) {
        $name=Get-RelativeName $file.FullName.Substring($release.Length+1)
        if (-not $expected.ContainsKey($name)) { throw "Unknown release file: $name" }
    }
    if ($actualFiles.Count -ne $expected.Count) { throw 'Release file set mismatch.' }
    foreach ($name in @('build-manifest.json','test-summary.json','docs/RELEASE-0.12.0.zh-CN.md')) {
        if (-not $expected.ContainsKey($name)) { throw "Required release input missing: $name" }
    }
    $build=Read-Json (Join-Path $release 'build-manifest.json')
    $summary=Read-Json (Join-Path $release 'test-summary.json')
    if ($build.Version -ne $version.version -or $build.BuildId -ne $manifest.BuildId -or $build.BuildTool.Name -ne 'ps2exe' -or $build.BuildTool.Version -ne '1.0.18') { throw 'Build provenance/version mismatch.' }
    if ($summary.Version -ne $version.version -or $summary.Status -ne 'Passed' -or $summary.Failed -ne 0 -or $summary.Cases -le 0 -or $summary.Assertions -le 0) { throw 'A passed matching public regression summary is required.' }
    # publish.ps1 produces this public-only schema; do not copy private evidence.
    $summaryKeys=@('Version','Status','Cases','Assertions','Failed','Results','Limitations')
    foreach ($property in $summary.PSObject.Properties) { if ($property.Name -notin $summaryKeys) { throw 'Non-public summary property.' } }
    foreach ($result in @($summary.Results)) {
        foreach ($property in $result.PSObject.Properties) { if ($property.Name -notin @('Id','Status','Assertions','Failed')) { throw 'Non-public regression result.' } }
        if ($result.Status -ne 'Passed' -or $result.Failed -ne 0 -or $result.Assertions -le 0) { throw 'Failed public regression result.' }
    }
    $inputs=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($build.Sources)) {
        $name=Get-RelativeName ([string]$record.Path)
        if (-not $inputs.Add($name) -or [string]$record.SHA256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-Hash (Join-Path $source $name)) -ne $record.SHA256) { throw 'Build source does not match clean source repository.' }
    }
    foreach ($name in @('src/Main.ps1','src/Version.ps1','src/Rules.ps1','src/Core.ps1','src/Discovery.ps1','src/Maintenance.ps1','src/Worker.ps1','src/Gui.ps1','version.json','assets/app.ico','scripts/build.ps1')) {
        if (-not $inputs.Contains($name)) { throw "Missing build source record: $name" }
    }
    $artifacts=@($build.Files)
    if ($artifacts.Count -ne 2 -or @($artifacts | Where-Object { $_.Name -like '*.exe' }).Count -ne 1 -or @($artifacts | Where-Object { $_.Name -like '*.ps1' }).Count -ne 1) { throw 'Expected one EXE and one combined script.' }
    $artifactNames=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in $artifacts) {
        $name=Get-RelativeName ([string]$record.Name)
        if ($name.Contains('/') -or -not $artifactNames.Add($name) -or -not $expected.ContainsKey($name) -or $expected[$name].Hash -ne $record.SHA256 -or $expected[$name].Bytes -ne $record.Bytes -or $name -notlike '*_v0.12.0.*') { throw 'Build artifact mismatch.' }
        $path=Join-Path $release $name
        if ($name.EndsWith('.exe',[StringComparison]::OrdinalIgnoreCase)) {
            if ($record.FileVersion -ne $version.fileVersion -or [Diagnostics.FileVersionInfo]::GetVersionInfo($path).FileVersion -ne $version.fileVersion) { throw 'EXE file version mismatch.' }
        } else {
            $text=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
            $marker='$script:SjcEmbeddedVersion = '+"[pscustomobject]@{version='0.12.0';fileVersion='0.12.0.0';planSchemaVersion=1}"
            if (@($text.Split(@($marker),[StringSplitOptions]::None)).Count -ne 2) { throw 'Combined script embedded version mismatch.' }
            $tokens=$null;$errors=$null
            [void][Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            if (@($errors).Count) { throw 'Combined script has parser errors.' }
        }
    }
    foreach ($name in $expected.Keys) {
        if ($name -match '(?i)\.(exe|ps1)$' -and -not $artifactNames.Contains($name)) { throw 'Unexpected executable/script in release.' }
    }
    $tree=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($line in (Invoke-LocalGit @('ls-tree','-rlz','--full-tree',$ExpectedSourceHead)).Split([char]0)) {
        if (-not $line) { continue }
        if ($line -notmatch '^(100644|100755) blob ([a-f0-9]{40}) +([0-9]+)\t(.+)$') { throw 'Unsupported source tree entry (links/submodules are not packaged).' }
        $blob=$Matches[2];$blobLength=[long]$Matches[3];$name=Get-RelativeName $Matches[4]
        # Tracked product artwork is source, not private screenshot evidence.
        if ($name -cne 'assets/app-icon-source.png') { Assert-PublicPath $name }
        if ($tree.ContainsKey($name)) { throw 'Duplicate source path.' }
        $tree.Add($name,[pscustomobject]@{Hash=$blob;Bytes=$blobLength})
    }
    if ($tree.Count -eq 0) { throw 'Empty source tree.' }
    # Create only after validating all inputs. No cleanup or LATEST mutation.
    [void](New-Item -ItemType Directory -Path $output -ErrorAction Stop)
    $windowsName='SafeJunkCleaner_v0.12.0_windows.zip'
    $sourceName='SafeJunkCleaner_v0.12.0_source.zip'
    $windowsZip=Join-Path $output $windowsName
    $zip=[IO.Compression.ZipFile]::Open($windowsZip,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in @($expected.Keys | Sort-Object)) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,(Join-Path $release $name),$name,[IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    $sourceZip=Join-Path $output $sourceName
    # Git export-ignore/export-subst are not silently trusted: entry validation
    # against ls-tree blob IDs below rejects omitted or transformed tracked files.
    [void](Invoke-LocalGit @('archive','--format=zip',('--output='+$sourceZip),$ExpectedSourceHead))
    Test-Zip $windowsZip $expected $false
    Test-Zip $sourceZip $tree $true
    foreach ($pair in @(@('docs/RELEASE-0.12.0.zh-CN.md','RELEASE-0.12.0.zh-CN.md'),@('test-summary.json','test-summary.json'))) {
        $from=Join-Path $release $pair[0];$to=Join-Path $output $pair[1]
        [IO.File]::Copy($from,$to,$false)
        if ((Get-Hash $to) -ne $expected[$pair[0]].Hash) { throw 'Public document changed during copy.' }
    }
    Assert-Snapshot
    $records=@(Get-ChildItem -LiteralPath $output -File | Sort-Object Name | ForEach-Object { [pscustomobject]@{Path=$_.Name;SHA256=(Get-Hash $_.FullName);Bytes=$_.Length} })
    $delivery=[ordered]@{Version='0.12.0';SourceHead=$ExpectedSourceHead.ToLowerInvariant();PackagedUtc=[datetime]::UtcNow.ToString('o');ReleaseManifestSHA256=$expected['release-manifest.json'].Hash;ZipEntriesVerified=$true;Files=$records;Limitations=@('Local packaging validation only; not product acceptance or a signature.','No application, publish, maintenance or cleanup was executed.')}
    $manifestPath=Join-Path $output 'release-manifest.json'
    Write-NewText $manifestPath ($delivery | ConvertTo-Json -Depth 8)
    $sums=@($records | ForEach-Object { $_.SHA256.ToLowerInvariant()+'  '+$_.Path })
    $sums+=(Get-Hash $manifestPath).ToLowerInvariant()+'  release-manifest.json'
    Write-NewText (Join-Path $output 'SHA256SUMS') (($sums -join "`n")+"`n")
    [pscustomobject]@{Status='Packaged';OutputDirectory=$output;SourceHead=$ExpectedSourceHead;Files=@(Get-ChildItem -LiteralPath $output -File | Sort-Object Name | ForEach-Object { [pscustomobject]@{Path=$_.Name;SHA256=(Get-Hash $_.FullName);Bytes=$_.Length} })} | ConvertTo-Json -Depth 8
} catch {
    [pscustomobject]@{Status='Failed';Message=$_.Exception.Message;OutputDirectory=$OutputDirectory;PartialOutputRetained=$true} | ConvertTo-Json -Depth 4
    exit 1
}
