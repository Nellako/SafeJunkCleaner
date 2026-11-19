# QuickClean GUI 与独立 .NET 10 Host (explorer/sjc-quickclean.exe) 桥接层。
# 与 Explorer 共享 explorer/host-component-manifest.json 与 SjcHostVerifier 全组件完整性校验；缺失或校验不通过一律拒绝，不回退旧版 PowerShell Worker。

if ($PSScriptRoot) {
    $script:SjcQuickCleanDefaultSrcRoot = $PSScriptRoot
    $script:SjcQuickCleanDefaultAppRoot = Split-Path -Parent $PSScriptRoot
}

function Initialize-SjcQuickCleanBridge {
    if (-not (Get-Command Get-SjcExplorerPackagedPlan -CommandType Function -ErrorAction SilentlyContinue)) {
        $srcRoot = if ($PSScriptRoot) { $PSScriptRoot } else { [string](Get-Variable -Name SjcQuickCleanDefaultSrcRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue) }
        if ($srcRoot -and [IO.File]::Exists((Join-Path $srcRoot 'ExplorerGui.ps1'))) {
            . (Join-Path $srcRoot 'ExplorerGui.ps1')
        }
    }
    if (-not (Get-Command Initialize-SjcExplorerBridge -CommandType Function -ErrorAction SilentlyContinue)) {
        throw 'QuickCleanBridgeUnavailable:ExplorerGuiMissing'
    }
    Initialize-SjcExplorerBridge
}

function Get-SjcQuickCleanTestContext {
    foreach ($varName in @('SjcQuickCleanTestContext', 'SjcExplorerTestContext')) {
        $ctx = Get-Variable -Name $varName -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $ctx) {
            $id = [Guid]::Empty
            $rawId = Get-SjcExplorerProp $ctx 'Id'
            if ([Guid]::TryParseExact([string]$rawId, 'D', [ref]$id) -and $id -ne [Guid]::Empty) {
                return $ctx
            }
        }
    }
    return $null
}

function Resolve-SjcQuickCleanAppRoot {
    param([string]$AppRoot = '')
    if (-not [string]::IsNullOrWhiteSpace($AppRoot)) {
        return [IO.Path]::GetFullPath($AppRoot).TrimEnd('\')
    }
    $packaged = [bool](Get-Variable -Name SjcIsPackaged -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    $entry = [string](Get-Variable -Name SjcEntryPath -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if ($packaged -and $entry) {
        return (Split-Path -Parent $entry)
    }
    if ($entry) {
        $entryDir = Split-Path -Parent $entry
        if ($entryDir -and (
            (Test-SjcExplorerPlainFile (Join-Path $entryDir 'explorer\host-component-manifest.json')) -or
            (Test-SjcExplorerPlainFile (Join-Path $entryDir 'explorer\sjc-quickclean.exe')) -or
            (Test-SjcExplorerPlainFile (Join-Path $entryDir 'explorer\sjc-explorer.exe'))
        )) {
            return $entryDir
        }
    }
    if ($PSScriptRoot) {
        if (
            (Test-SjcExplorerPlainFile (Join-Path $PSScriptRoot 'explorer\host-component-manifest.json')) -or
            (Test-SjcExplorerPlainFile (Join-Path $PSScriptRoot 'explorer\sjc-quickclean.exe')) -or
            (Test-SjcExplorerPlainFile (Join-Path $PSScriptRoot 'explorer\sjc-explorer.exe'))
        ) {
            return $PSScriptRoot
        }
        return (Split-Path -Parent $PSScriptRoot)
    }
    if ($entry) {
        $parent = Split-Path -Parent $entry
        if ($parent) { return (Split-Path -Parent $parent) }
    }
    $defaultRoot = [string](Get-Variable -Name SjcQuickCleanDefaultAppRoot -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($defaultRoot)) {
        return $defaultRoot
    }
    throw 'AppRootUnknown'
}

function Assert-SjcQuickCleanPlanVerified {
    param([Parameter(Mandatory = $true)]$Plan)
    $verifications = @(Get-SjcExplorerProp $Plan 'Verifications')
    if ($verifications.Count -eq 0) {
        throw 'QuickCleanVerificationMissing'
    }
    $primaryPaths = @($verifications[0].Paths | ForEach-Object { [string]$_ })
    if ($primaryPaths -notcontains 'sjc-explorer.exe' -or $primaryPaths -notcontains 'sjc-quickclean.exe') {
        throw 'ManifestQuickCleanHostMissing'
    }
    foreach ($v in $verifications) {
        $code = [SjcHostVerifier]::Verify(
            [string]$v.Root,
            [string[]]$v.Paths,
            [string[]]$v.Hashes,
            [long[]]$v.Sizes,
            [bool]$v.RejectLinks,
            [bool]$v.Extras,
            [bool]$v.Ancestors,
            [string]$v.AllowedExtra
        )
        if ($code) {
            throw ('LaunchVerifyFailed:' + [string]$v.Name + ':' + $code)
        }
    }
    $explorerExe = [string](Get-SjcExplorerProp $Plan 'Exe')
    if ([string]::IsNullOrWhiteSpace($explorerExe)) {
        throw 'QuickCleanHostExeMissing'
    }
    $runtimeDir = Split-Path -Parent $explorerExe
    $qcExe = Join-Path $runtimeDir 'sjc-quickclean.exe'
    if (-not (Test-SjcExplorerPlainFile $qcExe)) {
        throw 'QuickCleanHostExeMissing'
    }
    return @{
        Exe = $qcExe
        ExplorerExe = $explorerExe
        Directory = $runtimeDir
        Kind = [string](Get-SjcExplorerProp $Plan 'Kind')
        BuildId = (Get-SjcExplorerProp $Plan 'BuildId')
        ManifestSha256 = (Get-SjcExplorerProp $Plan 'ManifestSha256')
        Verifications = $verifications
    }
}

function Get-SjcQuickCleanPackagedPlanFromBuild {
    param([Parameter(Mandatory = $true)][string]$BuildRoot, $TestContext)
    $buildManifestFile = Read-SjcExplorerJsonFile (Join-Path $BuildRoot 'build-manifest.json')
    $buildManifest = $buildManifestFile.Object
    $components = @(Get-SjcExplorerProp $buildManifest 'Components')
    $explorerComp = @($components | Where-Object { [string](Get-SjcExplorerProp $_ 'Name') -ceq 'ExplorerHost' })
    if ($explorerComp.Count -ne 1) {
        throw 'BuildManifestExplorerHostMissing'
    }
    $manifestSha = [string](Get-SjcExplorerProp $explorerComp[0] 'ManifestSHA256')
    if ($manifestSha -notmatch '^[0-9A-Fa-f]{64}$') {
        throw 'BuildManifestExplorerHashInvalid'
    }
    $hadVar = [bool](Get-Variable -Name SjcEmbeddedExplorerManifestSha256 -Scope Script -ErrorAction SilentlyContinue)
    $oldVal = Get-Variable -Name SjcEmbeddedExplorerManifestSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    try {
        $script:SjcEmbeddedExplorerManifestSha256 = $manifestSha
        return (Get-SjcExplorerPackagedPlan $BuildRoot $TestContext)
    }
    finally {
        if ($hadVar) { $script:SjcEmbeddedExplorerManifestSha256 = $oldVal }
        else { Remove-Variable -Name SjcEmbeddedExplorerManifestSha256 -Scope Script -ErrorAction SilentlyContinue }
    }
}

function Get-SjcQuickCleanDevelopmentArtifactPlan {
    param([Parameter(Mandatory = $true)][string]$AppRoot, $TestContext)
    $buildsRoot = Join-Path $AppRoot 'artifacts\builds'
    if (Test-Path -LiteralPath $buildsRoot -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $buildsRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
        foreach ($dir in $candidates) {
            $bm = Join-Path $dir.FullName 'build-manifest.json'
            $qc = Join-Path $dir.FullName 'explorer\sjc-quickclean.exe'
            $hm = Join-Path $dir.FullName 'explorer\host-component-manifest.json'
            if ((Test-SjcExplorerPlainFile $bm) -and (Test-SjcExplorerPlainFile $qc) -and (Test-SjcExplorerPlainFile $hm)) {
                $plan = Get-SjcQuickCleanPackagedPlanFromBuild $dir.FullName $TestContext
                $plan.Kind = 'Development'
                return $plan
            }
        }
    }
    $explorerArtifacts = Join-Path $AppRoot 'artifacts\explorer'
    if (Test-Path -LiteralPath $explorerArtifacts -PathType Container) {
        $pubDirs = @(Get-ChildItem -LiteralPath $explorerArtifacts -Directory -Filter 'publish-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'publish-work-*' } | Sort-Object CreationTimeUtc -Descending)
        foreach ($dir in $pubDirs) {
            $qc = Join-Path $dir.FullName 'sjc-quickclean.exe'
            $hm = Join-Path $dir.FullName 'host-component-manifest.json'
            if ((Test-SjcExplorerPlainFile $qc) -and (Test-SjcExplorerPlainFile $hm)) {
                $file = Read-SjcExplorerJsonFile $hm
                $m = $file.Object
                $launch = Get-SjcExplorerProp $m 'Launch'
                $launchArgs = @(Get-SjcExplorerProp $launch 'Arguments')
                if ((Get-SjcExplorerProp $m 'ContractVersion') -ne 3 -or (Get-SjcExplorerProp $m 'SchemaVersion') -ne 1 -or (Get-SjcExplorerProp $m 'SelfContained') -ne $true -or [string](Get-SjcExplorerProp $m 'RuntimeIdentifier') -cne 'win-x64' -or [string](Get-SjcExplorerProp $m 'RuntimeRoot') -cne '.' -or [string](Get-SjcExplorerProp $launch 'Executable') -cne 'sjc-explorer.exe' -or $launchArgs.Count -ne 0 -or [string](Get-SjcExplorerProp $launch 'WorkingDirectory') -cne '.') {
                    throw 'ManifestLaunchInvalid'
                }
                $rt = Convert-SjcExplorerComponents (Get-SjcExplorerProp $m 'Components')
                foreach ($need in 'sjc-explorer.exe','sjc-explorer.dll','sjc-quickclean.exe','coreclr.dll','hostfxr.dll') {
                    if ($rt.Paths -notcontains $need) { throw 'ManifestHostRuntimeMissing' }
                }
                $verifications = @((New-SjcExplorerVerification 'Runtime' $dir.FullName $rt $true $true $false 'host-component-manifest.json'))
                $prov = Get-SjcExplorerProp $m 'SourceProvenance'
                if ($prov -and (Get-SjcExplorerProp $prov 'Sources')) {
                    $src = Convert-SjcExplorerComponents (Get-SjcExplorerProp $prov 'Sources') -NoSizes
                    $verifications += (New-SjcExplorerVerification 'SourceProvenance' $AppRoot $src $false $false $false '')
                }
                return @{
                    Exe = (Join-Path $dir.FullName 'sjc-explorer.exe')
                    Arguments = ((Get-SjcExplorerStateArgument $TestContext).Trim())
                    DotnetRoot = $null
                    Kind = 'Development'
                    BuildId = [string](Get-SjcExplorerProp $m 'BuildId')
                    ManifestSha256 = $file.Hash
                    Verifications = $verifications
                }
            }
        }
    }
    return $null
}

function Resolve-SjcQuickCleanHost {
    param($LaunchSpec = $null, [string]$AppRoot = '')
    Initialize-SjcQuickCleanBridge
    $ctx = Get-SjcQuickCleanTestContext
    if (-not $LaunchSpec -and $ctx -and (Get-SjcExplorerProp $ctx 'LaunchSpec')) {
        $LaunchSpec = Get-SjcExplorerProp $ctx 'LaunchSpec'
    }
    if ($LaunchSpec) {
        if (-not $ctx -or [string](Get-SjcExplorerProp $LaunchSpec 'TestId') -cne [string](Get-SjcExplorerProp $ctx 'Id')) {
            throw 'LaunchSpecNotAllowed'
        }
        $testExe = [string](Get-SjcExplorerProp $LaunchSpec 'Exe')
        if (-not (Test-SjcExplorerPlainFile $testExe)) {
            throw 'TestHostMissing'
        }
        $testVerifications = @(Get-SjcExplorerProp $LaunchSpec 'Verifications')
        foreach ($v in $testVerifications) {
            if ($null -eq $v) { continue }
            $code = [SjcHostVerifier]::Verify(
                [string]$v.Root,
                [string[]]$v.Paths,
                [string[]]$v.Hashes,
                [long[]]$v.Sizes,
                [bool]$v.RejectLinks,
                [bool]$v.Extras,
                [bool]$v.Ancestors,
                [string]$v.AllowedExtra
            )
            if ($code) {
                throw ('LaunchVerifyFailed:' + [string]$v.Name + ':' + $code)
            }
        }
        return @{
            Exe = $testExe
            ExplorerExe = $testExe
            Directory = (Split-Path -Parent $testExe)
            Kind = 'Test'
            BuildId = $null
            ManifestSha256 = $null
            Verifications = $testVerifications
        }
    }

    $packaged = [bool](Get-Variable -Name SjcIsPackaged -Scope Script -ValueOnly -ErrorAction SilentlyContinue)
    $resolvedRoot = Resolve-SjcQuickCleanAppRoot $AppRoot
    $hasExplorerDirHost = (
        (Test-SjcExplorerPlainFile (Join-Path $resolvedRoot 'explorer\sjc-explorer.exe')) -or
        (Test-SjcExplorerPlainFile (Join-Path $resolvedRoot 'explorer\sjc-quickclean.exe')) -or
        (Test-SjcExplorerPlainFile (Join-Path $resolvedRoot 'explorer\host-component-manifest.json'))
    )
    if ($hasExplorerDirHost) {
        $embedded = Get-Variable -Name SjcEmbeddedExplorerManifestSha256 -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ((-not $packaged) -and ([string]$embedded -notmatch '^[0-9A-Fa-f]{64}$') -and (Test-SjcExplorerPlainFile (Join-Path $resolvedRoot 'build-manifest.json'))) {
            $plan = Get-SjcQuickCleanPackagedPlanFromBuild $resolvedRoot $ctx
        }
        else {
            $plan = Get-SjcExplorerPackagedPlan $resolvedRoot $ctx
        }
        return (Assert-SjcQuickCleanPlanVerified $plan)
    }
    if ($packaged) {
        throw 'QuickCleanHostNotInstalled'
    }
    if ($ctx -and (Get-SjcExplorerProp $ctx 'RuntimeCache')) {
        $plan = Get-SjcExplorerDevelopmentPlan $resolvedRoot $ctx
        return (Assert-SjcQuickCleanPlanVerified $plan)
    }
    $devError = $null
    try {
        $plan = Get-SjcExplorerDevelopmentPlan $resolvedRoot $ctx
        return (Assert-SjcQuickCleanPlanVerified $plan)
    }
    catch {
        $devError = $_
    }
    $fallbackPlan = Get-SjcQuickCleanDevelopmentArtifactPlan $resolvedRoot $ctx
    if ($null -ne $fallbackPlan) {
        return (Assert-SjcQuickCleanPlanVerified $fallbackPlan)
    }
    if ($null -ne $devError) {
        throw $devError
    }
    throw 'QuickCleanHostNotFound'
}

function New-SjcQuickCleanProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [string]$WorkingDirectory = '',
        [switch]$RedirectStdio
    )
    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FileName
    $psi.Arguments = $Arguments
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $psi.WorkingDirectory = $WorkingDirectory
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $dropKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $psi.EnvironmentVariables) {
        $k = [string]$entry.Key
        if (
            $k.StartsWith('DOTNET_', [StringComparison]::OrdinalIgnoreCase) -or
            $k.StartsWith('COMPlus_', [StringComparison]::OrdinalIgnoreCase) -or
            $k.StartsWith('CORECLR_', [StringComparison]::OrdinalIgnoreCase) -or
            $k.StartsWith('CORE_', [StringComparison]::OrdinalIgnoreCase)
        ) {
            [void]$dropKeys.Add($k)
        }
    }
    foreach ($k in $dropKeys) {
        $psi.EnvironmentVariables.Remove($k)
    }
    $psi.EnvironmentVariables['DOTNET_NOLOGO'] = '1'
    $psi.EnvironmentVariables['DOTNET_CLI_TELEMETRY_OPTOUT'] = '1'
    $psi.EnvironmentVariables['DOTNET_GENERATE_ASPNET_CERTIFICATE'] = 'false'
    $psi.EnvironmentVariables['DOTNET_ADD_GLOBAL_TOOLS_TO_PATH'] = 'false'
    if ($RedirectStdio) {
        $utf8 = [Text.UTF8Encoding]::new($false)
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = $utf8
        $psi.StandardErrorEncoding = $utf8
    }
    return $psi
}

function Get-SjcQuickCleanJobLaunchSpec {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Scan','Clean','Recycle')][string]$Mode,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        $LaunchSpec = $null,
        [string]$AppRoot = '',
        $HostPlan = $null
    )
    $fullPayload = Get-SjcFullPath $PayloadPath
    $fullOutput = Get-SjcFullPath $OutputPath
    foreach ($p in @($fullPayload, $fullOutput)) {
        if ($p.Contains('"')) { throw '启动路径含无效字符。' }
    }
    $resolvedHost = if ($null -ne $HostPlan) { $HostPlan } else { Resolve-SjcQuickCleanHost $LaunchSpec $AppRoot }
    $exePath = [string]$resolvedHost.Exe
    if ([string]::IsNullOrWhiteSpace($exePath) -or $exePath.Contains('"')) {
        throw '启动路径含无效字符。'
    }
    $arguments = ('job {0} "{1}" "{2}"' -f $Mode, $fullPayload, $fullOutput)
    return @{
        FileName = $exePath
        Arguments = $arguments
        WorkingDirectory = [string]$resolvedHost.Directory
        HostPlan = $resolvedHost
    }
}

function Format-SjcQuickCleanQueryRequestJson {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Preview','Page','RuleKeep','Export','History')][string]$Operation,
        [hashtable]$Request = @{}
    )
    if ($Operation -ceq 'History') {
        if ($null -ne $Request -and $Request.Count -gt 0) {
            throw 'HistoryQueryTakesNoFields'
        }
        return '{}'
    }
    if ($null -eq $Request) {
        throw 'QueryRequestMissing'
    }
    $allowed = @('taskId', 'offset', 'limit', 'ruleId', 'excludedIds', 'destination')
    foreach ($key in $Request.Keys) {
        if ($allowed -cnotcontains [string]$key) {
            throw ('QueryFieldNotAllowed:' + [string]$key)
        }
    }
    $rawTaskId = [string]$Request['taskId']
    $tidGuid = [Guid]::Empty
    if (-not [Guid]::TryParseExact($rawTaskId, 'D', [ref]$tidGuid) -or $tidGuid -eq [Guid]::Empty) {
        throw 'QueryTaskIdInvalid'
    }
    $ordered = [ordered]@{
        taskId = $tidGuid.ToString('D')
    }
    if ($Request.ContainsKey('offset') -and $null -ne $Request['offset']) {
        $offsetVal = [int]$Request['offset']
        if ($offsetVal -lt 0) { throw 'QueryOffsetInvalid' }
        $ordered['offset'] = $offsetVal
    }
    if ($Request.ContainsKey('limit') -and $null -ne $Request['limit']) {
        $limitVal = [int]$Request['limit']
        if ($limitVal -le 0 -or $limitVal -gt 1000) { throw 'QueryLimitInvalid' }
        $ordered['limit'] = $limitVal
    }
    if ($Operation -ceq 'RuleKeep') {
        $ruleIdVal = [string]$Request['ruleId']
        if ([string]::IsNullOrWhiteSpace($ruleIdVal) -or $ruleIdVal.Length -gt 256) {
            throw 'QueryRuleIdInvalid'
        }
        $ordered['ruleId'] = $ruleIdVal
    }
    elseif ($Request.ContainsKey('ruleId') -and $null -ne $Request['ruleId']) {
        $ordered['ruleId'] = [string]$Request['ruleId']
    }
    if ($Operation -ceq 'Export') {
        $destVal = Get-SjcFullPath ([string]$Request['destination'])
        if (-not $destVal.EndsWith('.csv', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'QueryDestinationInvalid'
        }
        $exclRaw = if ($Request.ContainsKey('excludedIds') -and $null -ne $Request['excludedIds']) { @($Request['excludedIds']) } else { @() }
        [string[]]$exclArr = @($exclRaw | ForEach-Object { [string]$_ })
        Assert-SjcStringArray $exclArr 'excludedIds' 1000000
        $ordered['excludedIds'] = $exclArr
        $ordered['destination'] = $destVal
    }
    else {
        if ($Request.ContainsKey('excludedIds') -and $null -ne $Request['excludedIds']) {
            [string[]]$exclArr = @($Request['excludedIds'] | ForEach-Object { [string]$_ })
            Assert-SjcStringArray $exclArr 'excludedIds' 1000000
            $ordered['excludedIds'] = $exclArr
        }
        if ($Request.ContainsKey('destination') -and $null -ne $Request['destination']) {
            $ordered['destination'] = Get-SjcFullPath ([string]$Request['destination'])
        }
    }
    return ([pscustomobject]$ordered | ConvertTo-Json -Depth 5 -Compress)
}

function Assert-SjcQuickCleanQueryResponse {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Preview','Page','RuleKeep','Export','History')][string]$Operation,
        [Parameter(Mandatory = $true)]$Response
    )
    if ($null -eq $Response -or $Response -isnot [pscustomobject]) {
        throw ('QueryResponseNotObject:' + $Operation)
    }
    switch ($Operation) {
        'Preview' {
            if (-not $Response.PSObject.Properties['Count'] -or ($Response.Count -isnot [int] -and $Response.Count -isnot [long]) -or [int64]$Response.Count -lt 0) {
                throw 'QueryResponseInvalid:Preview.Count'
            }
            if (-not $Response.PSObject.Properties['Items'] -or $null -eq $Response.Items -or $Response.Items -is [string] -or $Response.Items -isnot [Collections.IList]) {
                throw 'QueryResponseInvalid:Preview.Items'
            }
            foreach ($item in @($Response.Items)) {
                if ($null -eq $item -or $item -isnot [pscustomobject]) { throw 'QueryResponseInvalid:Preview.Item' }
                foreach ($reqProp in @('Id','RuleId','Path','Length','LastWriteUtc')) {
                    if (-not $item.PSObject.Properties[$reqProp]) { throw ('QueryResponseInvalid:Preview.Item.' + $reqProp) }
                }
            }
        }
        'Page' {
            if (-not $Response.PSObject.Properties['Items'] -or $null -eq $Response.Items -or $Response.Items -is [string] -or $Response.Items -isnot [Collections.IList]) {
                throw 'QueryResponseInvalid:Page.Items'
            }
            foreach ($item in @($Response.Items)) {
                if ($null -eq $item -or $item -isnot [pscustomobject]) { throw 'QueryResponseInvalid:Page.Item' }
                foreach ($reqProp in @('Id','RuleId','Path','Length','LastWriteUtc')) {
                    if (-not $item.PSObject.Properties[$reqProp]) { throw ('QueryResponseInvalid:Page.Item.' + $reqProp) }
                }
            }
        }
        'RuleKeep' {
            if (-not $Response.PSObject.Properties['Items'] -or $null -eq $Response.Items -or $Response.Items -is [string] -or $Response.Items -isnot [Collections.IList]) {
                throw 'QueryResponseInvalid:RuleKeep.Items'
            }
            if (-not $Response.PSObject.Properties['HasMore'] -or $Response.HasMore -isnot [bool]) {
                throw 'QueryResponseInvalid:RuleKeep.HasMore'
            }
        }
        'Export' {
            if (-not $Response.PSObject.Properties['ExportedCount'] -or ($Response.ExportedCount -isnot [int] -and $Response.ExportedCount -isnot [long]) -or [int64]$Response.ExportedCount -lt 0) {
                throw 'QueryResponseInvalid:Export.ExportedCount'
            }
            if (-not $Response.PSObject.Properties['Destination'] -or $Response.Destination -isnot [string] -or [string]::IsNullOrWhiteSpace($Response.Destination)) {
                throw 'QueryResponseInvalid:Export.Destination'
            }
        }
        'History' {
            if (-not $Response.PSObject.Properties['Items'] -or $null -eq $Response.Items -or $Response.Items -is [string] -or $Response.Items -isnot [Collections.IList]) {
                throw 'QueryResponseInvalid:History.Items'
            }
            foreach ($item in @($Response.Items)) {
                if ($null -eq $item -or $item -isnot [pscustomobject]) {
                    throw 'QueryResponseInvalid:History.Item'
                }
                foreach ($reqProp in @('Time','Action','Status','Summary','LogPath','TaskDirectory','Result')) {
                    if (-not $item.PSObject.Properties[$reqProp]) {
                        throw ('QueryResponseInvalid:History.Item.' + $reqProp)
                    }
                }
            }
        }
    }
}

function Invoke-SjcQuickCleanQuery {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Preview','Page','RuleKeep','Export','History')][string]$Operation,
        [hashtable]$Request = @{},
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        $LaunchSpec = $null,
        [string]$AppRoot = '',
        $HostPlan = $null
    )
    $CancellationToken.ThrowIfCancellationRequested()
    $resolvedHost = if ($null -ne $HostPlan) { $HostPlan } else { Resolve-SjcQuickCleanHost $LaunchSpec $AppRoot }
    $requestJson = Format-SjcQuickCleanQueryRequestJson -Operation $Operation -Request $Request
    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    $requestBytes = $utf8NoBom.GetBytes($requestJson)

    $psi = New-SjcQuickCleanProcessStartInfo -FileName ([string]$resolvedHost.Exe) -Arguments ('query ' + $Operation) -WorkingDirectory ([string]$resolvedHost.Directory) -RedirectStdio
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    try {
        if (-not $process.Start()) {
            throw ('无法启动 QuickClean Host query ' + $Operation)
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        try {
            $stdin = $process.StandardInput.BaseStream
            $stdin.Write($requestBytes, 0, $requestBytes.Length)
            $stdin.Flush()
        }
        finally {
            try { $process.StandardInput.Close() } catch {}
        }
        while (-not $process.WaitForExit(40)) {
            if ($CancellationToken.IsCancellationRequested) {
                try {
                    if (-not $process.HasExited) {
                        $process.Kill()
                        [void]$process.WaitForExit(2000)
                    }
                }
                catch {}
                $CancellationToken.ThrowIfCancellationRequested()
            }
        }
        $process.WaitForExit()
        if ($CancellationToken.IsCancellationRequested) {
            $CancellationToken.ThrowIfCancellationRequested()
        }
        $exitCode = $process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        # 按真实退出码判断成败；保留 stderr 诊断信息，不将退出码为 0 时的 stderr 视为失败。
        if ($exitCode -ne 0) {
            $detail = if (-not [string]::IsNullOrWhiteSpace($stderr)) { $stderr.Trim() } elseif (-not [string]::IsNullOrWhiteSpace($stdout)) { $stdout.Trim() } else { '无错误详情' }
            throw ('QuickClean Host query ' + $Operation + ' 失败 (退出代码 ' + $exitCode + ')：' + $detail)
        }
        $lines = @($stdout -split "\r?\n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($lines.Count -ne 1) {
            throw ('QuickClean Host query ' + $Operation + ' 应返回单行 JSON，实际行数：' + $lines.Count)
        }
        $line = $lines[0].Trim()
        if ($line.Length -gt 0 -and [int][char]$line[0] -eq 0xFEFF) {
            $line = $line.Substring(1)
        }
        $parsed = $line | ConvertFrom-Json -ErrorAction Stop
        Assert-SjcQuickCleanQueryResponse -Operation $Operation -Response $parsed
        return $parsed
    }
    finally {
        try { $process.Dispose() } catch {}
    }
}

function Invoke-SjcQuickCleanRuleKeep {
    param(
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string[]]$RuleIds,
        [ValidateRange(1, 1000)][int]$PageSize = 1000,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        $LaunchSpec = $null,
        [string]$AppRoot = '',
        $HostPlan = $null
    )
    $CancellationToken.ThrowIfCancellationRequested()
    $resolvedHost = if ($null -ne $HostPlan) { $HostPlan } else { Resolve-SjcQuickCleanHost $LaunchSpec $AppRoot }
    $items = New-Object 'System.Collections.Generic.List[object]'
    foreach ($rid in @($RuleIds)) {
        if ([string]::IsNullOrWhiteSpace($rid)) { continue }
        $offset = 0
        while ($true) {
            $CancellationToken.ThrowIfCancellationRequested()
            $resp = Invoke-SjcQuickCleanQuery -Operation 'RuleKeep' -Request @{
                taskId = $TaskId
                ruleId = [string]$rid
                offset = $offset
                limit = $PageSize
            } -CancellationToken $CancellationToken -HostPlan $resolvedHost
            $page = @($resp.Items)
            foreach ($entry in $page) {
                if ($null -eq $entry -or -not $entry.PSObject.Properties['Id'] -or -not $entry.PSObject.Properties['Length']) {
                    throw 'QueryResponseInvalid:RuleKeep.Entry'
                }
                [void]$items.Add([pscustomobject]@{
                    Id = [string]$entry.Id
                    Length = [int64]$entry.Length
                    RuleId = [string]$rid
                })
            }
            $hasMore = [bool]$resp.HasMore
            if (-not $hasMore) { break }
            if ($page.Count -le 0) {
                throw 'QueryResponseInvalid:RuleKeep.EmptyPageWithHasMore'
            }
            $offset += $page.Count
        }
    }
    return [pscustomobject]@{ Items = $items.ToArray() }
}

function Close-SjcQuickCleanPreviewState {
    param($Shared)
    if ($null -eq $Shared -or -not $Shared.Preview) { return }
    $preview = $Shared.Preview
    try {
        if ($preview.PSObject.Properties['Stream'] -and (Get-Command Close-SjcPreviewSession -CommandType Function -ErrorAction SilentlyContinue)) {
            Close-SjcPreviewSession $preview
        }
        elseif ($preview.PSObject.Properties['Closed']) {
            $preview.Closed = $true
        }
    }
    finally {
        $Shared.Preview = $null
    }
}

function Resolve-SjcQuickCleanTaskIdFromArguments {
    param($Shared, [hashtable]$Arguments)
    if ($Arguments) {
        if ($Arguments.ContainsKey('TaskId') -and -not [string]::IsNullOrWhiteSpace([string]$Arguments['TaskId'])) {
            return [string]$Arguments['TaskId']
        }
        if ($Arguments.ContainsKey('TaskDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$Arguments['TaskDirectory'])) {
            return [IO.Path]::GetFileName(([string]$Arguments['TaskDirectory']).TrimEnd('\'))
        }
        if ($Arguments.ContainsKey('PlanPath') -and -not [string]::IsNullOrWhiteSpace([string]$Arguments['PlanPath'])) {
            $dir = [IO.Path]::GetDirectoryName([string]$Arguments['PlanPath'])
            if ($dir) { return [IO.Path]::GetFileName($dir.TrimEnd('\')) }
        }
    }
    if ($Shared -and $Shared.Preview -and $Shared.Preview.PSObject.Properties['TaskId'] -and -not [string]::IsNullOrWhiteSpace([string]$Shared.Preview.TaskId)) {
        return [string]$Shared.Preview.TaskId
    }
    throw '缺少有效的任务标识 (taskId)。'
}

function Invoke-SjcQuickCleanLocalJob {
    param(
        $Shared,
        [Parameter(Mandatory = $true)][ValidateSet('Open','Page','RuleKeep','Export','Close')][string]$Kind,
        [hashtable]$Arguments = @{},
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None
    )
    if ($Arguments) {
        if ($Arguments.ContainsKey('EmbeddedManifestSha256')) {
            $script:SjcEmbeddedExplorerManifestSha256 = $Arguments['EmbeddedManifestSha256']
        }
        if ($Arguments.ContainsKey('QuickCleanTestContext')) {
            $script:SjcQuickCleanTestContext = $Arguments['QuickCleanTestContext']
        }
        if ($Arguments.ContainsKey('ExplorerTestContext')) {
            $script:SjcExplorerTestContext = $Arguments['ExplorerTestContext']
        }
        if ($Arguments.ContainsKey('AppRoot') -and -not [string]::IsNullOrWhiteSpace([string]$Arguments['AppRoot'])) {
            $script:SjcQuickCleanDefaultAppRoot = [string]$Arguments['AppRoot']
        }
    }
    if ($Kind -ceq 'Close') {
        Close-SjcQuickCleanPreviewState $Shared
        return [pscustomobject]@{ Closed = $true }
    }
    $CancellationToken.ThrowIfCancellationRequested()
    $appRoot = if ($Arguments -and $Arguments.ContainsKey('AppRoot')) { [string]$Arguments['AppRoot'] } else { '' }
    $launchSpec = if ($Arguments -and $Arguments.ContainsKey('LaunchSpec')) { $Arguments['LaunchSpec'] } else { $null }
    $hostPlan = Resolve-SjcQuickCleanHost $launchSpec $appRoot
    $taskId = Resolve-SjcQuickCleanTaskIdFromArguments $Shared $Arguments
    $limit = if ($Arguments -and $Arguments.ContainsKey('Limit') -and [int]$Arguments['Limit'] -gt 0) { [int]$Arguments['Limit'] } else { 200 }

    switch ($Kind) {
        'Open' {
            Close-SjcQuickCleanPreviewState $Shared
            $resp = Invoke-SjcQuickCleanQuery -Operation 'Preview' -Request @{
                taskId = $taskId
                offset = 0
                limit = $limit
            } -CancellationToken $CancellationToken -HostPlan $hostPlan
            $Shared.Preview = [pscustomobject]@{
                Id = [guid]::NewGuid().ToString('N')
                Mode = 'Host'
                TaskId = $taskId
                Count = [int64]$resp.Count
                Closed = $false
            }
            return [pscustomobject]@{
                Items = @($resp.Items)
                Count = [int64]$resp.Count
            }
        }
        'Page' {
            $offset = if ($Arguments -and $Arguments.ContainsKey('Offset')) { [int]$Arguments['Offset'] } else { 0 }
            $resp = Invoke-SjcQuickCleanQuery -Operation 'Page' -Request @{
                taskId = $taskId
                offset = $offset
                limit = $limit
            } -CancellationToken $CancellationToken -HostPlan $hostPlan
            return [pscustomobject]@{
                Items = @($resp.Items)
            }
        }
        'RuleKeep' {
            [string[]]$ids = if ($Arguments -and $Arguments.ContainsKey('RuleIds')) {
                @($Arguments['RuleIds'] | ForEach-Object { [string]$_ })
            }
            elseif ($Arguments -and $Arguments.ContainsKey('RuleId')) {
                @([string]$Arguments['RuleId'])
            }
            else {
                @()
            }
            $pageSize = if ($Arguments -and $Arguments.ContainsKey('PageSize') -and [int]$Arguments['PageSize'] -gt 0) { [int]$Arguments['PageSize'] } else { 1000 }
            return (Invoke-SjcQuickCleanRuleKeep -TaskId $taskId -RuleIds $ids -PageSize $pageSize -CancellationToken $CancellationToken -HostPlan $hostPlan)
        }
        'Export' {
            [string[]]$excluded = if ($Arguments -and $Arguments.ContainsKey('ExcludedIds') -and $null -ne $Arguments['ExcludedIds']) {
                @($Arguments['ExcludedIds'] | ForEach-Object { [string]$_ })
            }
            else {
                @()
            }
            $dest = [string]$Arguments['Destination']
            $resp = Invoke-SjcQuickCleanQuery -Operation 'Export' -Request @{
                taskId = $taskId
                destination = $dest
                excludedIds = $excluded
            } -CancellationToken $CancellationToken -HostPlan $hostPlan
            return [pscustomobject]@{
                Status = 'Success'
                Destination = [string]$resp.Destination
                ExportedCount = [int64]$resp.ExportedCount
            }
        }
    }
}

function Get-SjcQuickCleanHistory {
    param(
        $LaunchSpec = $null,
        [string]$AppRoot = '',
        $HostPlan = $null
    )
    $resp = Invoke-SjcQuickCleanQuery -Operation 'History' -Request @{} -LaunchSpec $LaunchSpec -AppRoot $AppRoot -HostPlan $HostPlan
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($resp.Items)) {
        $logPath = [string]$item.LogPath
        $resultObj = $item.Result
        if ($null -eq $resultObj -and -not [string]::IsNullOrWhiteSpace($logPath) -and [IO.File]::Exists($logPath)) {
            try { $resultObj = Read-SjcSafeText $logPath | ConvertFrom-Json -ErrorAction Stop } catch { $resultObj = $null }
        }
        [void]$list.Add([pscustomobject]@{
            Time = [string]$item.Time
            Action = [string]$item.Action
            Status = [string]$item.Status
            Summary = [string]$item.Summary
            LogPath = $logPath
            TaskDirectory = [string]$item.TaskDirectory
            Result = $resultObj
        })
    }
    return ,$list
}

function Start-SjcQuickCleanMaintenance {
    param(
        [switch]$TestMode,
        $LaunchSpec = $null,
        [string]$AppRoot = '',
        $HostPlan = $null
    )
    if ($TestMode) {
        throw 'TestMode 不允许启动系统维护。'
    }
    if ((Get-Variable -Scope Script -Name SjcTestIsolationParent -ErrorAction SilentlyContinue) -and $null -eq $LaunchSpec -and $null -eq (Get-SjcQuickCleanTestContext)) {
        throw '隔离测试禁止真实维护进程启动（UAC/DISM）。'
    }
    try {
        $resolvedHost = if ($null -ne $HostPlan) { $HostPlan } else { Resolve-SjcQuickCleanHost $LaunchSpec $AppRoot }
        $psi = New-SjcQuickCleanProcessStartInfo -FileName ([string]$resolvedHost.Exe) -Arguments 'maintenance' -WorkingDirectory ([string]$resolvedHost.Directory)
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        try {
            if (-not $process.Start()) {
                throw '系统未返回进程句柄。'
            }
        }
        catch {
            $process.Dispose()
            throw
        }
        return [pscustomobject]@{
            Status = 'Running'
            Process = $process
            ExitCode = $null
            Error = ''
        }
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) {
            if ($e -is [ComponentModel.Win32Exception]) { break }
            $e = $e.InnerException
        }
        $status = if ($e -is [ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { 'Canceled' } else { 'Failed' }
        return [pscustomobject]@{
            Status = $status
            Process = $null
            ExitCode = $null
            Error = $_.Exception.Message
        }
    }
}
