# SafeJunkCleaner: fixed templates; never import roots from environment/config/payload.
function New-SjcRule {
    param([string]$Id, [string]$TemplateId, [string]$Name, [string]$Group,
        [string]$Root, [string[]]$Patterns = @('*'), [string[]]$ExcludePatterns = @(),
        [double]$MinimumAgeHours = 24, [string[]]$RequiresClosedProcess = @(),
        [bool]$Recommended = $false, [string]$Risk = '中低', [string]$Note = '',
        [double]$DeepMinimumAgeHours = -1, [string[]]$OverrideEnvironment = @())
    if ($DeepMinimumAgeHours -lt 0) { $DeepMinimumAgeHours=$MinimumAgeHours }
    if ($MinimumAgeHours -le 0 -or $DeepMinimumAgeHours -le 0 -or $DeepMinimumAgeHours -gt $MinimumAgeHours) { throw '规则年龄必须为正数且深度档不得高于推荐档。' }
    [pscustomobject][ordered]@{ Id=$Id; TemplateId=$TemplateId; Name=$Name; Group=$Group; Risk=$Risk;
        Recommended=$Recommended; Root=$Root; Patterns=@($Patterns); ExcludePatterns=@($ExcludePatterns);
        MinimumAgeHours=$MinimumAgeHours; RecommendedMinimumAgeHours=$MinimumAgeHours; DeepMinimumAgeHours=$DeepMinimumAgeHours;
        CleaningProfile='Recommended'; RequiresClosedProcess=@($RequiresClosedProcess); OverrideEnvironment=@($OverrideEnvironment);
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
    # Exact, opt-in rebuildable graphics caches; recompilation can be expensive.
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

function Get-SjcRules {
    param([Parameter(Mandatory=$true)]$Context)
    $configuration=Get-SjcContextConfiguration $Context
    foreach($rule in @(Get-SjcRuleTemplates $Context)) {
        # Explicit nonzero Temp floors are independent from browser/cache policy.
        switch ($rule.TemplateId) {
            'UserTemp' { $rule.DeepMinimumAgeHours=6 }
            'WindowsTemp' { $rule.DeepMinimumAgeHours=24 }
            'GradleCache' { $rule.DeepMinimumAgeHours=168 }
            { $_ -in @('D3DSCache','NvidiaDXCache','NvidiaGLCache','AmdDxCache','AmdDxcCache','IntelShaderCache') } { $rule.DeepMinimumAgeHours=168 }
        }
        if ($rule.Group -eq '浏览器缓存') { $rule.DeepMinimumAgeHours=1 }
        $rule.CleaningProfile=$configuration.CleaningProfile
        if ($configuration.CleaningProfile -ceq 'Deep') { $rule.MinimumAgeHours=$rule.DeepMinimumAgeHours }
        if ($rule.TemplateId -eq 'UserTemp') { $rule.Note='至少24小时（推荐）/6小时（深度）未修改；排除数据库日志、链接和受保护内容。' }
        $rule
    }
}
