# Metadata-only adapters. Discovery is NOT approval; DPAPI is not same-user malware isolation.
function Get-SjcDiscoveryHash {
    param([string]$Value)
    $sha=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Get-SjcDirectoryIdentity {
    param([string]$Path)
    if (-not (Test-SjcNoReparsePath $Path)) { throw '缓存目录或祖先不安全。' }
    Initialize-SjcNative
    $identity=[SjcV3.Native]::ReadIdentity((Get-SjcFullPath $Path))
    if (($identity.Attributes -band 0x400) -ne 0 -or ($identity.Attributes -band 0x10) -eq 0) { throw '缓存根不是普通目录。' }
    return $identity.Key
}
function Get-SjcDiscoverySources {
    param($Context)
    $configuration=Get-SjcContextConfiguration $Context
    if ($configuration.IsTest) {
        # Only the registered GUID sandbox may supply synthetic sources. No production Root/TestRoot input.
        if ($configuration.PSObject.Properties['DiscoveryTestSources']) { return @($configuration.DiscoveryTestSources) }
        return @()
    }
    foreach($item in @(@('NuGetHttp','NUGET_HTTP_CACHE_PATH'),@('Pip','PIP_CACHE_DIR'))) {
        $value=[Environment]::GetEnvironmentVariable($item[1])
        if (-not [string]::IsNullOrWhiteSpace($value)) { [pscustomobject]@{ Adapter=$item[0]; Source=$item[1]; Value=$value } }
    }
}
function Set-SjcTestDiscoverySources {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][object[]]$Sources)
    $configuration=Get-SjcContextConfiguration $Context
    if (-not $configuration.IsTest) { throw '发现测试源仅允许本进程自建 GUID 沙箱。' }
    $checked=@(foreach($source in $Sources) {
        if ($source.Adapter -cnotin @('NuGetHttp','Pip')) { throw '测试 adapter 无效。' }
        $value=Get-SjcFullPath $source.Value
        if (-not (Test-SjcPathWithin $value (Join-Path $configuration.TestRoot 'files'))) { throw '测试发现源必须位于自有沙箱 files 内。' }
        [pscustomobject]@{Adapter=$source.Adapter; Source=$(if($source.Adapter -ceq 'Pip'){'PIP_CACHE_DIR'}else{'NUGET_HTTP_CACHE_PATH'}); Value=$value}
    })
    $configuration | Add-Member -NotePropertyName DiscoveryTestSources -NotePropertyValue $checked -Force
}
function Test-SjcDiscoveredRootSafety {
    param($Context,[string]$Root)
    try {
        $rootPath=Get-SjcFullPath $Root
        if ($rootPath.Length -le 3 -or -not [IO.Directory]::Exists($rootPath) -or -not (Test-SjcNoReparsePath $rootPath)) { return $false }
        $configuration=Get-SjcContextConfiguration $Context
        if ($configuration.IsTest) { return (Test-SjcPathWithin $rootPath (Join-Path $configuration.TestRoot 'files')) }
        $home=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
        if ($rootPath.Equals($home,[StringComparison]::OrdinalIgnoreCase)) { return $false }
        $protected=@([Environment]::GetFolderPath([Environment+SpecialFolder]::MyDocuments),(Join-Path $home 'Downloads'),[IO.Directory]::GetParent([Environment]::SystemDirectory).FullName,[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),$configuration.StateRoot)
        if ($script:SjcDiscoveryModuleRoot) { $protected += $script:SjcDiscoveryModuleRoot }
        $process=[Diagnostics.Process]::GetCurrentProcess()
        try { $protected += [IO.Path]::GetDirectoryName($process.MainModule.FileName) } finally { $process.Dispose() }
        foreach($path in $protected) {
            if (-not $path) { continue }
            if ((Test-SjcPathWithin $rootPath $path -AllowRoot) -or (Test-SjcPathWithin $path $rootPath -AllowRoot)) { return $false }
        }
        return $true
    } catch { return $false }
}
function Test-SjcCacheLayoutFile {
    param([string]$TemplateId,[string]$Root,[string]$Path)
    if (-not (Test-SjcPathWithin $Path $Root)) { return $false }
    $relative=(Get-SjcFullPath $Path).Substring((Get-SjcFullPath $Root).Length+1)
    switch -CaseSensitive ($TemplateId) {
        'NuGetCache' { return ($relative -cmatch '^[0-9a-f]{40}\$[^\\/:*?"<>|]+\\(?:service_index|list_[A-Za-z0-9_.+-]+|nupkg_[A-Za-z0-9_.+-]+)\.dat$') }
        'PipHttpCache' { if($relative -cmatch '^(?:[0-9a-f]\\){5}[0-9a-f]{56}$'){ $parts=$relative.Split('\'); return (($parts[0..4] -join '') -ceq $parts[5].Substring(0,5)) }; return $false }
        'PipHttpV2Cache' { if($relative -cmatch '^(?:[0-9a-f]\\){5}[0-9a-f]{56}(?:\.body)?$'){ $parts=$relative.Split('\'); return (($parts[0..4] -join '') -ceq $parts[5].Substring(0,5)) }; return $false }
        'PipWheelCache' { return ($relative -cmatch '^(?:[0-9a-f]{2}\\){3}[0-9a-f]{50}\\[A-Za-z0-9_.+!-]+\.whl$') }
    }
    return $false
}
function Test-SjcCacheLayout {
    param([string]$TemplateId,[string]$Root)
    # Bounded metadata evidence, not a cache-content scan. Unexpected files never become candidates.
    try {
        $queue=New-Object 'System.Collections.Generic.Queue[object]'
        $queue.Enqueue([pscustomobject]@{Path=$Root;Depth=0}); $visited=0
        $maxDepth=if($TemplateId -ceq 'NuGetCache'){1}elseif($TemplateId -ceq 'PipWheelCache'){4}else{5}
        while($queue.Count -gt 0 -and $visited -lt 512) {
            $current=$queue.Dequeue()
            $iterator=([IO.DirectoryInfo]::new($current.Path)).EnumerateFileSystemInfos().GetEnumerator()
            try {
                while($iterator.MoveNext()) {
                    $entry=$iterator.Current
                    $visited++; if($visited -gt 512){return $false}
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
                    if ($entry -is [IO.FileInfo]) {
                        if (Test-SjcCacheLayoutFile $TemplateId $Root $entry.FullName) { return $true }
                    } elseif ($current.Depth -lt $maxDepth) {
                        $valid=if($TemplateId -ceq 'NuGetCache'){$entry.Name -cmatch '^[0-9a-f]{40}\$[^\\/:*?"<>|]+$'}elseif($TemplateId -ceq 'PipWheelCache'){$entry.Name -cmatch $(if($current.Depth -lt 3){'^[0-9a-f]{2}$'}else{'^[0-9a-f]{50}$'})}else{$entry.Name -cmatch '^[0-9a-f]$'}
                        if($valid){$queue.Enqueue([pscustomobject]@{Path=$entry.FullName;Depth=($current.Depth+1)})}
                    }
                }
            } finally { $iterator.Dispose() }
        }
    } catch { return $false }
    return $false
}
function Read-SjcCacheAuthorizations {
    param($Context)
    $configuration=Get-SjcContextConfiguration $Context
    Assert-SjcPrivateDirectory $configuration.StateRoot
    $path=Join-Path $configuration.StateRoot 'cache-authorizations-v1.dpapi'
    if (-not [IO.File]::Exists($path)) { return [pscustomobject]@{Schema=1; Revision='none'; Entries=@()} }
    try {
        $value=Unprotect-SjcText (Read-SjcSafeText $path) | ConvertFrom-Json -ErrorAction Stop
        if ($value.Schema -ne 1 -or $value.Revision -isnot [string] -or $value.Entries -isnot [System.Collections.IList] -or $value.Entries.Count -gt 32) { throw 'schema' }
        $seen=@{}
        foreach($entry in $value.Entries) {
            if ($entry.Id -isnot [string] -or $entry.Id -cnotmatch '^Discovered:[a-f0-9]{64}$' -or $entry.Binding -isnot [string] -or $entry.Binding -cnotmatch '^[a-f0-9]{64}$' -or $entry.AuthorizationId -isnot [string] -or $entry.AuthorizationId -cnotmatch '^[a-f0-9]{32}$' -or $seen.ContainsKey($entry.Id)) { throw 'entry' }
            $seen[$entry.Id]=$true
        }
        return $value
    } catch { throw '缓存授权文件无效；未授权任何发现位置。' }
}
function Get-SjcCacheLocationCandidates {
    param($Context)
    foreach($source in @(Get-SjcDiscoverySources $Context)) {
        $sourceValue=''; $sourceSafe=$false
        try { $sourceValue=(Get-SjcFullPath $source.Value).ToLowerInvariant(); $sourceSafe=Test-SjcDiscoveredRootSafety $Context $sourceValue } catch { }
        $templates=if($source.Adapter -ceq 'NuGetHttp'){@('NuGetCache')}else{@('PipHttpCache','PipHttpV2Cache','PipWheelCache')}
        foreach($template in $templates) {
            $root=$sourceValue
            if ($root -and $source.Adapter -ceq 'Pip') {
                $leaf=switch -CaseSensitive ($template){'PipHttpCache'{'http'}'PipHttpV2Cache'{'http-v2'}'PipWheelCache'{'wheels'}}
                $root=Join-Path $root $leaf
            }
            $key=$source.Adapter+'|'+$source.Source+'|'+$sourceValue+'|'+$template+'|'+$root
            $id='Discovered:'+(Get-SjcDiscoveryHash $key)
            $supported=$false; $identity=''; $note='路径或缓存布局无法证明；未授权，未扫描内容。'
            if($sourceSafe -and (Test-SjcDiscoveredRootSafety $Context $root)) {
                try {
                    $identity=Get-SjcDirectoryIdentity $root
                    $supported=Test-SjcCacheLayout $template $root
                    if($supported){$note='仅元数据布局匹配；需单独确认。包/构建缓存仍保留正数年龄，进程守卫不放宽。'}
                } catch { }
            }
            $binding=Get-SjcDiscoveryHash ($key+'|'+$identity+'|PolicyRevision=3|AdapterRevision=1|AgeBounded|NameGuard')
            [pscustomobject]@{Id=$id; Application=$(if($source.Adapter -ceq 'Pip'){'pip'}else{'NuGet HTTP'}); Source=$source.Source; Root=$root; Status=$(if($supported){'PendingAuthorization'}else{'Unsupported'}); Supported=[bool]$supported; Authorized=$false; Note=$note; Adapter=$source.Adapter; TemplateId=$template; SourceValue=$sourceValue; DirectoryIdentity=$identity; Binding=$binding; AuthorizationId=''}
        }
    }
}
function Get-SjcDiscoveredCacheLocations {
    param([Parameter(Mandatory=$true)]$Context)
    $authorizations=Read-SjcCacheAuthorizations $Context
    $seen=@{}
    foreach($candidate in @(Get-SjcCacheLocationCandidates $Context)) {
        $seen[$candidate.Id]=$true
        foreach($entry in $authorizations.Entries) {
            if($candidate.Supported -and $entry.Id -ceq $candidate.Id -and $entry.Binding -ceq $candidate.Binding) {
                $candidate.Authorized=$true; $candidate.AuthorizationId=$entry.AuthorizationId; $candidate.Status='Authorized'; $candidate.Note='已确认精确缓存子根；Worker 将自主重新发现、复核环境与目录身份。'
            }
        }
        if (-not $candidate.Authorized -and @($authorizations.Entries | Where-Object { $_.Id -ceq $candidate.Id }).Count -gt 0) { $candidate.Authorized=$true; $candidate.Status='StaleAuthorization'; $candidate.Note='环境布局或目录身份已变化，原授权无效；可撤销或重新确认当前绑定。' }
        $candidate
    }
    foreach($entry in $authorizations.Entries) {
        if (-not $seen.ContainsKey($entry.Id)) {
            [pscustomobject]@{Id=$entry.Id; Application='已失效缓存授权'; Source='Unavailable'; Root=''; Status='StaleAuthorization'; Supported=$false; Authorized=$true; Note='发现源已不再存在；不可清理，可撤销旧授权。'; Binding=$entry.Binding; AuthorizationId=$entry.AuthorizationId}
        }
    }
}
function Get-SjcDiscoveryScopeSeal {
    param($Context)
    $authorization=Read-SjcCacheAuthorizations $Context
    $locations=@(Get-SjcDiscoveredCacheLocations $Context | Sort-Object Id | ForEach-Object { $_.Id+'|'+$_.Binding+'|'+$_.Supported+'|'+$_.AuthorizationId })
    return (Get-SjcDiscoveryHash ($authorization.Revision+'|'+($locations -join ';')))
}
function Refresh-SjcAuthorizedRules {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration=Get-SjcContextConfiguration $Context
    $seal=Get-SjcDiscoveryScopeSeal $Context
    if ($configuration.PSObject.Properties['DiscoveryScopeSeal'] -and $configuration.DiscoveryScopeSeal -cne $seal) {
        Set-SjcCleaningProfile -Context $Context -CleaningProfile $configuration.CleaningProfile -Invalidate
    }
    $configuration | Add-Member -NotePropertyName DiscoveryScopeSeal -NotePropertyValue $seal -Force
    $Context.Rules=@(Get-SjcRules $Context)
    return $Context.Rules
}
function Approve-SjcCacheLocations {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string[]]$Ids,[Parameter(Mandatory=$true)][string[]]$ExpectedBindings)
    Assert-SjcStringArray $Ids 'Ids' 32
    Assert-SjcStringArray $ExpectedBindings 'ExpectedBindings' 32
    if ($Ids.Count -ne $ExpectedBindings.Count) { throw '授权 ID 和展示时绑定必须严格一一对应。' }
    $current=@{}; foreach($location in @(Get-SjcDiscoveredCacheLocations $Context)){$current[$location.Id]=$location}
    $authorizations=Read-SjcCacheAuthorizations $Context
    $entries=New-Object 'System.Collections.Generic.List[object]'
    $selected=@{}
    for($index=0;$index -lt $Ids.Count;$index++) {
        $id=$Ids[$index]
        if($selected.ContainsKey($id) -or -not $current.ContainsKey($id) -or $current[$id].Id -cne $id -or -not $current[$id].Supported -or $current[$id].Binding -cne $ExpectedBindings[$index]){throw '发现位置已变化、重复或不支持；请刷新后重新确认。'}
        $selected[$id]=$true
    }
    foreach($entry in $authorizations.Entries){if(-not $selected.ContainsKey($entry.Id)){[void]$entries.Add($entry)}}
    foreach($id in $Ids){[void]$entries.Add([pscustomobject]@{Id=$id;Binding=$current[$id].Binding;AuthorizationId=[guid]::NewGuid().ToString('N')})}
    if($entries.Count -gt 32){throw '缓存授权数量超过限制；请先撤销旧授权。'}
    # A denial marker is written before changing approval, including approval of a previously empty scope.
    Set-SjcCleaningProfile -Context $Context -CleaningProfile (Get-SjcContextConfiguration $Context).CleaningProfile -Invalidate
    Write-SjcAtomicText -Path (Join-Path (Get-SjcContextConfiguration $Context).StateRoot 'cache-authorizations-v1.dpapi') -Text (Protect-SjcText ([pscustomobject]@{Schema=1;Revision=[guid]::NewGuid().ToString('N');Entries=@($entries.ToArray())}|ConvertTo-Json -Depth 5 -Compress))
    [void](Refresh-SjcAuthorizedRules $Context)
    return @(Get-SjcDiscoveredCacheLocations $Context)
}
function Revoke-SjcCacheLocations {
    param([Parameter(Mandatory=$true)]$Context,[Parameter(Mandatory=$true)][string[]]$Ids)
    Assert-SjcStringArray $Ids 'Ids' 32
    $authorizations=Read-SjcCacheAuthorizations $Context
    $known=@{};foreach($entry in $authorizations.Entries){$known[$entry.Id]=$true}
    foreach($id in $Ids){if(-not $known.ContainsKey($id)){throw '没有对应的已保存缓存授权。'}}
    $entries=@($authorizations.Entries|Where-Object {$_.Id -cnotin $Ids})
    Set-SjcCleaningProfile -Context $Context -CleaningProfile (Get-SjcContextConfiguration $Context).CleaningProfile -Invalidate
    Write-SjcAtomicText -Path (Join-Path (Get-SjcContextConfiguration $Context).StateRoot 'cache-authorizations-v1.dpapi') -Text (Protect-SjcText ([pscustomobject]@{Schema=1;Revision=[guid]::NewGuid().ToString('N');Entries=$entries}|ConvertTo-Json -Depth 5 -Compress))
    [void](Refresh-SjcAuthorizedRules $Context)
    return @(Get-SjcDiscoveredCacheLocations $Context)
}
function Get-SjcAuthorizedCacheRuleTemplates {
    param($Context)
    foreach($location in @(Get-SjcDiscoveredCacheLocations $Context)) {
        if(-not $location.Supported -or -not $location.Authorized -or $location.Status -cne 'Authorized'){continue}
        $processes=if($location.Adapter -ceq 'NuGetHttp'){@('dotnet','nuget','MSBuild','devenv')}else{@('python','pythonw','pip','pip3','uv')}
        $rule=New-SjcRule -Id $location.Id -TemplateId $location.TemplateId -Name ($location.Application+' / 已确认覆盖缓存') -Group '开发工具' -Root $location.Root -MinimumAgeHours 168 -DeepMinimumAgeHours 24 -RequiresClosedProcess $processes -Note '单独授权的精确覆盖缓存根；仅匹配已验证布局文件，不读取缓存内容；离线使用前保留。'
        $rule.AuthorizationId=$location.AuthorizationId; $rule.AuthorizationBinding=$location.Binding
        $rule.DiscoveryAdapter=$location.Adapter; $rule.DiscoverySource=$location.Source
        $rule.DiscoverySourceValue=$location.SourceValue; $rule.RootDirectoryIdentity=$location.DirectoryIdentity
        if ((Get-SjcContextConfiguration $Context).IsTest) { $rule | Add-Member -NotePropertyName DiscoveryTestContext -NotePropertyValue $Context }
        $rule
    }
}
function Test-SjcDiscoveredRuleCurrent {
    param($Rule)
    try {
        $value=[Environment]::GetEnvironmentVariable($Rule.DiscoverySource)
        # Synthetic rules remain limited to registered GUID roots and use the same fresh discovery path below.
        if($Rule.PSObject.Properties['DiscoveryTestContext'] -and $Rule.DiscoveryTestContext){$locations=@(Get-SjcDiscoveredCacheLocations $Rule.DiscoveryTestContext)}
        else {
            if((Get-SjcFullPath $value).ToLowerInvariant() -cne $Rule.DiscoverySourceValue){return $false}
            if((Get-SjcDirectoryIdentity $Rule.Root) -cne $Rule.RootDirectoryIdentity){return $false}
            $path=Join-Path (Get-SjcProductionStateRoot) 'cache-authorizations-v1.dpapi'
            $state=Unprotect-SjcText (Read-SjcSafeText $path)|ConvertFrom-Json -ErrorAction Stop
            return (@($state.Entries|Where-Object {$_.Id -ceq $Rule.Id -and $_.Binding -ceq $Rule.AuthorizationBinding -and $_.AuthorizationId -ceq $Rule.AuthorizationId}).Count -eq 1)
        }
        return (@($locations|Where-Object {$_.Id -ceq $Rule.Id -and $_.Authorized -and $_.Binding -ceq $Rule.AuthorizationBinding -and $_.AuthorizationId -ceq $Rule.AuthorizationId}).Count -eq 1)
    } catch { return $false }
}
# Source mode only; bundled applications additionally protect their executable directory above.
$script:SjcDiscoveryModuleRoot=if($PSScriptRoot){[IO.Path]::GetDirectoryName($PSScriptRoot)}else{''}
