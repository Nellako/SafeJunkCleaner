# SafeJunkCleaner: fixed templates; never import roots from environment/config/payload.
function New-SjcRule {
    param([string]$Id, [string]$TemplateId, [string]$Name, [string]$Group,
        [string]$Root, [string[]]$Patterns = @('*'), [string[]]$ExcludePatterns = @(),
        [double]$MinimumAgeHours = 24, [string[]]$RequiresClosedProcess = @(),
        [bool]$Recommended = $false, [string]$Risk = '中低', [string]$Note = '')
    [pscustomobject][ordered]@{ Id=$Id; TemplateId=$TemplateId; Name=$Name; Group=$Group; Risk=$Risk;
        Recommended=$Recommended; Root=$Root; Patterns=@($Patterns); ExcludePatterns=@($ExcludePatterns);
        MinimumAgeHours=$MinimumAgeHours; RequiresClosedProcess=@($RequiresClosedProcess);
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

function Get-SjcRules {
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
