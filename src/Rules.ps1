# SafeJunkCleaner: fixed templates; never import roots from environment/config/payload.
function New-SjcRule {
    param([string]$Id, [string]$TemplateId, [string]$Name, [string]$Group,
        [string]$Root, [string[]]$Patterns = @('*'), [string[]]$ExcludePatterns = @(),
        [double]$MinimumAgeHours = 24, [string[]]$RequiresClosedProcess = @(),
        [bool]$Recommended = $false, [string]$Risk = '中低', [string]$Note = '',
        [double]$DeepMinimumAgeHours = -1, [string[]]$OverrideEnvironment = @())
    if (-not $PSBoundParameters.ContainsKey('DeepMinimumAgeHours')) { $DeepMinimumAgeHours=$MinimumAgeHours }
    if ($MinimumAgeHours -le 0 -or $DeepMinimumAgeHours -le 0 -or $DeepMinimumAgeHours -gt $MinimumAgeHours) { throw '规则年龄必须为正数且深度档不得高于推荐档。' }
    [pscustomobject][ordered]@{ Id=$Id; TemplateId=$TemplateId; Name=$Name; Group=$Group; Risk=$Risk;
        Recommended=$Recommended; Root=$Root; Patterns=@($Patterns); ExcludePatterns=@($ExcludePatterns);
        MinimumAgeHours=$MinimumAgeHours; RecommendedMinimumAgeHours=$MinimumAgeHours; DeepMinimumAgeHours=$DeepMinimumAgeHours;
        LowMinimumAgeHours=$MinimumAgeHours; MediumMinimumAgeHours=$MinimumAgeHours; HighMinimumAgeHours=$DeepMinimumAgeHours;
        PresetLevel='High'; CleaningProfile='Medium'; AgePolicy='AgeBounded'; ProcessPolicy='NameGuard';
        AuthorizationId=''; AuthorizationBinding=''; DiscoveryAdapter=''; DiscoverySource=''; DiscoverySourceValue=''; RootDirectoryIdentity='';
        RequiresClosedProcess=@($RequiresClosedProcess); OverrideEnvironment=@($OverrideEnvironment);
        Available=[IO.Directory]::Exists($Root); Note=$Note }
}

# Read-only discovery seam, also used by isolated tests. It grants NO cleaning approval.
function Get-SjcChromiumProfileDirectories {
    param([Parameter(Mandatory=$true)][string]$BaseRoot)
    $base=Get-SjcFullPath $BaseRoot
    if (-not [IO.Directory]::Exists($base) -or -not (Test-SjcNoReparsePath $base)) { return @() }
    foreach($directory in @([IO.Directory]::GetDirectories($base) | Sort-Object)) {
        $leaf=[IO.Path]::GetFileName($directory)
        if ($leaf -cnotmatch '^(Default|Profile [1-9][0-9]{0,5})$') { continue }
        if (-not (Test-SjcNoReparsePath $directory)) { continue }
        $directory
    }
}

function Get-SjcRuleTemplates {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration = Get-SjcContextConfiguration $Context
    if ($configuration.IsTest) {
        @(
            New-SjcRule -Id 'SandboxOld' -TemplateId 'SandboxOld' -Name '自有测试旧文件' -Group '合成测试' -Root (Join-Path $configuration.TestRoot 'files') -Patterns @('*.tmp') -MinimumAgeHours 24 -Recommended $true
            New-SjcRule -Id 'SandboxLog' -TemplateId 'SandboxLog' -Name '自有测试日志' -Group '合成测试' -Root (Join-Path $configuration.TestRoot 'files') -Patterns @('*.log') -MinimumAgeHours 48
        )
        return
    }
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $roaming = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $windows = [IO.Directory]::GetParent([Environment]::SystemDirectory).FullName
    @(
        New-SjcRule -Id 'UserTemp' -TemplateId 'UserTemp' -Name '当前用户临时文件' -Group '临时文件' -Root (Join-Path $local 'Temp') -MinimumAgeHours 24 -Recommended $true -Risk '低' -ExcludePatterns @('*.sqlite-wal','*-wal','*.wal','*.sqlite-shm','*-shm') -Note '至少24小时未修改；不处理数据库日志或链接。'
        New-SjcRule -Id 'WindowsTemp' -TemplateId 'WindowsTemp' -Name 'Windows 临时文件' -Group '临时文件' -Root (Join-Path $windows 'Temp') -MinimumAgeHours 48 -ExcludePatterns @('*.sqlite-wal','*-wal','*.wal','*.sqlite-shm','*-shm') -Note '不提权；权限不足独立报告。'
        New-SjcRule -Id 'VSCodeCache' -TemplateId 'VSCodeCache' -Name 'VS Code 网页缓存' -Group '开发工具' -Root (Join-Path $roaming 'Code\Cache') -MinimumAgeHours 48 -RequiresClosedProcess @('Code') -Note '固定 Roaming\Code\Cache，不读取便携版或外部配置。'
        New-SjcRule -Id 'VSCodeCodeCache' -TemplateId 'VSCodeCodeCache' -Name 'VS Code 代码缓存' -Group '开发工具' -Root (Join-Path $roaming 'Code\CachedData') -MinimumAgeHours 168 -RequiresClosedProcess @('Code')
        New-SjcRule -Id 'GradleCache' -TemplateId 'GradleCache' -Name 'Gradle 可重建缓存' -Group '开发工具' -Root (Join-Path $profile '.gradle\caches') -MinimumAgeHours 720 -RequiresClosedProcess @('java','javaw','gradle','studio','studio64','idea','idea64','Code') -Note '固定 UserProfile\.gradle\caches；不含 wrapper、配置、项目、Maven；未采用 GRADLE_USER_HOME。'
    )
    # Officially documented default cache subroots only. Overrides never grant new roots.
    foreach($item in @(
        @('NpmCache','npm HTTP/包缓存','npm-cache\_cacache',@('node'),@('NPM_CONFIG_CACHE')),
        @('NuGetCache','NuGet HTTP 缓存','NuGet\v3-cache',@('dotnet','nuget','MSBuild','devenv'),@('NUGET_HTTP_CACHE_PATH')),
        @('PipHttpCache','pip 旧 HTTP 缓存','pip\Cache\http',@('python','pythonw','pip','pip3','uv'),@('PIP_CACHE_DIR')),
        @('PipHttpV2Cache','pip HTTP v2 缓存','pip\Cache\http-v2',@('python','pythonw','pip','pip3','uv'),@('PIP_CACHE_DIR')),
        @('PipWheelCache','pip 构建 wheel 缓存','pip\Cache\wheels',@('python','pythonw','pip','pip3','uv'),@('PIP_CACHE_DIR')),
        @('YarnCache','Yarn Classic 缓存','Yarn\Cache\v6',@('node'),@('YARN_CACHE_FOLDER')),
        @('GoBuildCache','Go 构建缓存','go-build',@('go','compile','link','gopls'),@('GOCACHE','GOCACHEPROG','GOENV'))
    )) {
        New-SjcRule -Id $item[0] -TemplateId $item[0] -Name $item[1] -Group '开发工具' -Root (Join-Path $local $item[2]) -MinimumAgeHours 168 -DeepMinimumAgeHours 24 -RequiresClosedProcess $item[3] -OverrideEnvironment $item[4] -Risk '中' -Note '仅受支持默认布局；不读写或执行工具配置，不含项目/环境/模块仓库；重建需网络或编译，离线工作前保留。设置覆盖变量时保守跳过。'
    }
    foreach($cache in @('Cache','GPUCache')) {
        $id='Teams'+$cache
        New-SjcRule -Id $id -TemplateId $id -Name ('Teams Classic / '+$cache) -Group '应用缓存' -Root (Join-Path $roaming ('Microsoft\Teams\'+$cache)) -MinimumAgeHours 168 -DeepMinimumAgeHours 24 -RequiresClosedProcess @('Teams','ms-teams') -Risk '中' -Note '仅经典版官方列出的Roaming缓存子根；不含数据库/离线存储，不处理新版MSIX或整个Teams目录。'
    }
    # Official new Teams WebView2 subroots only; never reset the whole app/profile.
    foreach($item in @(
        @('NewTeamsCache','Cache'),
        @('NewTeamsGPUCache','GPUCache'),
        @('NewTeamsCodeCache','Code Cache')
    )) {
        New-SjcRule -Id $item[0] -TemplateId $item[0] -Name ('新版 Teams / '+$item[1]) -Group '应用缓存' -Root (Join-Path $local ('Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw\'+$item[1])) -MinimumAgeHours 168 -DeepMinimumAgeHours 24 -RequiresClosedProcess @('ms-teams','Teams','msedgewebview2') -Risk '中' -Note '仅官方列出的精确WebView2缓存子根；不含Service Worker、CacheStorage、WebStorage或整个Teams根，不是整应用重置。可证明无关的WebView2宿主不阻断；归属未知仍保守跳过，不自动结束进程。'
    }
    # Exact rebuildable graphics caches; recompilation can be expensive.
    foreach($item in @(
        @('D3DSCache','DirectX 着色器缓存','D3DSCache'),
        @('NvidiaDXCache','NVIDIA DirectX 着色器缓存','NVIDIA\DXCache'),
        @('NvidiaGLCache','NVIDIA OpenGL 着色器缓存','NVIDIA\GLCache'),
        @('AmdDxCache','AMD DirectX 着色器缓存','AMD\DxCache'),
        @('AmdDxcCache','AMD DXC 着色器缓存','AMD\DxcCache'),
        @('IntelShaderCache','Intel 着色器缓存','Intel\ShaderCache')
    )) {
        New-SjcRule -Id $item[0] -TemplateId $item[0] -Name $item[1] -Group '图形缓存' -Root (Join-Path $local $item[2]) -MinimumAgeHours 336 -Risk '中' -Note '仅旧缓存普通文件；请先退出游戏/图形程序，重建可能造成首次运行卡顿；占用文件跳过。'
    }
    @(
        New-SjcRule -Id 'SteamHtmlCache' -TemplateId 'SteamHtmlCache' -Name 'Steam 网页界面缓存' -Group '应用缓存' -Root (Join-Path $local 'Steam\htmlcache') -MinimumAgeHours 168 -RequiresClosedProcess @('steam','steamwebhelper') -Risk '中' -Note '仅旧版精确 htmlcache，非游戏内容或下载。'
        New-SjcRule -Id 'CrashDumps' -TemplateId 'CrashDumps' -Name '应用崩溃转储' -Group '诊断文件' -Root (Join-Path $local 'CrashDumps') -Patterns @('*.dmp') -MinimumAgeHours 720 -Risk '中' -Note '不是可重建缓存；删除将丢失既往故障诊断证据。默认不选。'
        New-SjcRule -Id 'WERArchive' -TemplateId 'WERArchive' -Name 'Windows 已归档错误报告' -Group '诊断文件' -Root (Join-Path $local 'Microsoft\Windows\WER\ReportArchive') -MinimumAgeHours 720 -RequiresClosedProcess @('WerFault','WerFaultSecure','wermgr') -Risk '中' -Note '仅已归档报告，不清理待提交队列；删除将丢失历史诊断证据。'
        New-SjcRule -Id 'ExplorerThumbCache' -TemplateId 'ExplorerThumbCache' -Name '资源管理器缩略图缓存' -Group '图形缓存' -Root (Join-Path $local 'Microsoft\Windows\Explorer') -Patterns @('thumbcache_*.db') -MinimumAgeHours 168 -RequiresClosedProcess @('explorer') -Risk '中' -Note '仅固定数据库文件名；要求资源管理器关闭，不自动结束进程。'
        New-SjcRule -Id 'ExplorerIconCache' -TemplateId 'ExplorerIconCache' -Name '资源管理器图标缓存' -Group '图形缓存' -Root (Join-Path $local 'Microsoft\Windows\Explorer') -Patterns @('iconcache_*.db') -MinimumAgeHours 168 -RequiresClosedProcess @('explorer') -Risk '中' -Note '与缩略图规则同根单次枚举，要求资源管理器关闭。'
    )
    # Actual Firefox disk cache only; never the historic *.sqlite-wal misrule.
    $firefoxBase=Join-Path $local 'Mozilla\Firefox\Profiles'
    if ([IO.Directory]::Exists($firefoxBase) -and (Test-SjcNoReparsePath $firefoxBase)) {
        try {
            foreach($directory in @([IO.Directory]::GetDirectories($firefoxBase) | Sort-Object)) {
                $leaf=[IO.Path]::GetFileName($directory)
                if ($leaf -cnotmatch '^[a-z0-9]{8}\.(?:default|default-release|default-esr)(?:-[0-9]{1,14})?$' -or -not (Test-SjcNoReparsePath $directory)) { continue }
                New-SjcRule -Id ('FirefoxCache2:'+$leaf) -TemplateId 'FirefoxCache2' -Name ('Firefox / '+$leaf+' / cache2') -Group '浏览器缓存' -Root (Join-Path $directory 'cache2') -MinimumAgeHours 24 -DeepMinimumAgeHours 1 -RequiresClosedProcess @('firefox') -Risk '中' -Note '仅默认命名Local Profile中的cache2；不读取profiles.ini/prefs.js，不处理Roaming、WAL/SHM、storage或自定义Profile。'
            }
        } catch { }
    }
    # Only immediate Default / Profile N children of fixed Chromium user-data roots.
    $browsers = @(
        @{ Id='Chrome'; Name='Chrome'; Relative='Google\Chrome\User Data'; Process='chrome' },
        @{ Id='Edge'; Name='Edge'; Relative='Microsoft\Edge\User Data'; Process='msedge' },
        @{ Id='Brave'; Name='Brave'; Relative='BraveSoftware\Brave-Browser\User Data'; Process='brave' }
    )
    foreach ($browser in $browsers) {
        $base = Join-Path $local $browser.Relative
        if (-not [IO.Directory]::Exists($base) -or -not (Test-SjcNoReparsePath $base)) { continue }
        try {
            $profiles = @(Get-SjcChromiumProfileDirectories -BaseRoot $base)
            foreach ($directory in $profiles) {
                $leaf = [IO.Path]::GetFileName($directory)
                foreach ($cache in @('Cache','Code Cache','GPUCache')) {
                    $template = $browser.Id + ($cache -replace ' ','')
                    $id = $template + ':' + ($leaf -replace ' ','_')
                    New-SjcRule -Id $id -TemplateId $template -Name ($browser.Name + ' / ' + $leaf + ' / ' + $cache) -Group '浏览器缓存' -Root (Join-Path $directory $cache) -MinimumAgeHours 24 -RequiresClosedProcess @($browser.Process) -Recommended ($cache -eq 'Cache') -Note '只处理此 Profile 精确缓存根；不包括 Service Worker、数据库、登录或离线数据。'
                }
            }
        } catch {
            # Discovery failure does not authorize any guessed profile or external root.
        }
    }
}

function Get-SjcTemplateAgePolicy {
    param([string]$TemplateId)
    if ($TemplateId -cin @('ChromeCache','ChromeCodeCache','ChromeGPUCache','EdgeCache','EdgeCodeCache','EdgeGPUCache','BraveCache','BraveCodeCache','BraveGPUCache','FirefoxCache2','VSCodeCache','VSCodeCodeCache','NewTeamsCache','NewTeamsCodeCache','NewTeamsGPUCache','TeamsGPUCache')) { return 'PureCache' }
    return 'AgeBounded'
}
function Assert-SjcRuleAgePolicy {
    param($Rule)
    $expected=Get-SjcTemplateAgePolicy $Rule.TemplateId
    if ($Rule.AgePolicy -cne $expected) { throw '年龄策略不属于可信模板白名单。' }
    foreach($name in @('LowMinimumAgeHours','MediumMinimumAgeHours','HighMinimumAgeHours')) {
        $age=[double]$Rule.$name
        if ([double]::IsNaN($age) -or [double]::IsInfinity($age) -or $age -lt 0) { throw '规则年龄不得为负数或非有限值。' }
        if ($age -eq 0 -and ($name -cne 'HighMinimumAgeHours' -or $expected -cne 'PureCache')) { throw '仅高强度可信纯缓存允许零小时。' }
    }
}

function Get-SjcCleaningProfiles {
    @(
        [pscustomobject]@{ Id='Low'; Label='低强度'; Description='用户临时文件与浏览器磁盘缓存，至少保留24小时。'; Impact='范围较小；浏览器下次访问可能重新下载缓存。' }
        [pscustomobject]@{ Id='Medium'; Label='中强度'; Description='低强度范围，加系统临时文件、代码/应用及着色器缓存。'; Impact='部分应用需重建缓存；着色器保留168小时，首次运行仍可能卡顿。' }
        [pscustomobject]@{ Id='High'; Label='高强度'; Description='中强度范围，加包/构建缓存与720小时以上的历史诊断文件。'; Impact='精确纯缓存不按年龄保留（仍跳过未来时间、占用、只读、相关进程及不安全路径）；临时文件仍有正数年龄；包缓存需要重新下载/重新编译，可能影响离线依赖；删除旧诊断资料将丢失历史故障证据。着色器仍保留168小时。' }
    )
}
function Get-SjcPresetRuleIds {
    param([Parameter(Mandatory=$true)]$Context,$CleaningProfile=(Get-SjcContextConfiguration $Context).CleaningProfile)
    Assert-SjcCleaningProfile $CleaningProfile
    $levels=@{Low=1;Medium=2;High=3}
    foreach($rule in @(Get-SjcRules $Context)) {
        # Missing fixed roots remain in the preset. Discovery never guesses profiles.
        if ($levels.ContainsKey($rule.PresetLevel) -and $levels[$rule.PresetLevel] -le $levels[$CleaningProfile]) { $rule.Id }
    }
}
function Get-SjcRules {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration=Get-SjcContextConfiguration $Context
    $packages=@('NpmCache','NuGetCache','PipHttpCache','PipHttpV2Cache','PipWheelCache','YarnCache','GoBuildCache')
    $shaders=@('D3DSCache','NvidiaDXCache','NvidiaGLCache','AmdDxCache','AmdDxcCache','IntelShaderCache')
    $templates=@(Get-SjcRuleTemplates $Context)
    if (Get-Command Get-SjcAuthorizedCacheRuleTemplates -CommandType Function -ErrorAction SilentlyContinue) { $templates += @(Get-SjcAuthorizedCacheRuleTemplates $Context) }
    foreach($rule in $templates) {
        # Future templates are opt-in until assigned a reviewed preset level.
        $rule.PresetLevel='CustomOnly'
        switch ($rule.TemplateId) {
            'SandboxOld' { $rule.PresetLevel='Low' }
            'SandboxLog' { $rule.PresetLevel='Medium' }
            'UserTemp' { $rule.PresetLevel='Low'; $rule.HighMinimumAgeHours=6 }
            'WindowsTemp' { $rule.PresetLevel='Medium'; $rule.HighMinimumAgeHours=24 }
            'VSCodeCache' { $rule.PresetLevel='Medium'; $rule.HighMinimumAgeHours=24 }
            'VSCodeCodeCache' { $rule.PresetLevel='Medium'; $rule.HighMinimumAgeHours=24 }
            'GradleCache' { $rule.PresetLevel='High'; $rule.HighMinimumAgeHours=168 }
            { $_ -in $packages } { $rule.PresetLevel='High'; $rule.HighMinimumAgeHours=24 }
            { $_ -in $shaders } {
                $rule.PresetLevel='Medium'; $rule.LowMinimumAgeHours=168; $rule.MediumMinimumAgeHours=168; $rule.HighMinimumAgeHours=168
                $rule.Note += ' 中、高强度均保留168小时，避免频繁重编译。'
            }
            { $_ -in @('TeamsCache','TeamsGPUCache','SteamHtmlCache') } { $rule.PresetLevel='Medium'; $rule.HighMinimumAgeHours=24 }
            { $_ -in @('NewTeamsCache','NewTeamsGPUCache') } { $rule.PresetLevel='Medium'; $rule.HighMinimumAgeHours=24 }
            'NewTeamsCodeCache' { $rule.PresetLevel='High'; $rule.HighMinimumAgeHours=24 }
            { $_ -in @('CrashDumps','WERArchive') } { $rule.PresetLevel='High' }
        }
        if ($rule.Group -eq '浏览器缓存') {
            $rule.PresetLevel=if ($rule.TemplateId -eq 'FirefoxCache2' -or $rule.TemplateId -in @('ChromeCache','EdgeCache','BraveCache')) { 'Low' } else { 'Medium' }
            $rule.HighMinimumAgeHours=1
        }
        # Only reviewed exact template IDs can waive age at High; payload/group labels cannot.
        $rule.AgePolicy=Get-SjcTemplateAgePolicy $rule.TemplateId
        if ($rule.AgePolicy -ceq 'PureCache') {
            $rule.HighMinimumAgeHours=0
            $rule.Note += ' 高强度纯缓存不按年龄保留；仍跳过未来时间、占用、只读、进程守卫或路径校验不通过的文件。'
        }
        if ($rule.TemplateId -cin @('NewTeamsCache','NewTeamsGPUCache','NewTeamsCodeCache')) {
            $rule.ProcessPolicy='NewTeamsWebView2'
            $rule.Note += ' WebView2仅在只读父链及可信路径能证明归属时区分宿主；未知/无权限仍跳过，不读取命令行。'
        }
        Assert-SjcRuleAgePolicy $rule
        # Legacy properties describe the endpoints only; preset selection uses PresetLevel.
        $rule.Recommended=($rule.PresetLevel -ceq 'Low')
        $rule.RecommendedMinimumAgeHours=$rule.LowMinimumAgeHours; $rule.DeepMinimumAgeHours=$rule.HighMinimumAgeHours
        $rule.CleaningProfile=$configuration.CleaningProfile
        $rule.MinimumAgeHours=$rule.($configuration.CleaningProfile+'MinimumAgeHours')
        if ($rule.TemplateId -eq 'UserTemp') { $rule.Note='至少24小时（低/中）或6小时（高）未修改；排除数据库日志、链接和受保护内容。' }
        if ($rule.TemplateId -eq 'CrashDumps') { $rule.Note='仅720小时以上转储；删除将丢失历史故障诊断证据，高强度预设包含此类。' }
        $rule
    }
}
