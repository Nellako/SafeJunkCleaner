# v2.2.1 到当前规则逐项对照

事实基线：仓库旁备份 `backups/20261102_230206/moved-workspace-materials/SafeJunkCleaner_v2.2.1.ps1` 的Get-CleanRules规则表（232–288行），全局MinimumFileAgeMinutes=60（197行，扫描/清理均应用）。旧源文件只读，不执行。中间基线是本轮修改前模块化Rules/Core/Worker（保存在artifacts/engine-baseline-20261103）。旧表合计51项，含独立回收站。不是“少了一个显示项就实际少了一个清理能力”。

以下年龄单位为小时。`关`指默认不勾选，不等于规则移除；`条件`指目录/Profile发现/权限/进程/配置不满足时不可处理。推荐/深度均不得绕过安全检查。历史迁移原因无提交材料，除旧代码注释能证明的事实外，一律**未知**；本轮选择理由不是对历史的推测。

| 旧ID（逐项） | 当前行为 | 旧默认→当前默认 | 旧龄→推荐/深度 | 类型与说明 |
|---|---|---|---|---|
| UserTemp | 保留 | 开→开 | 1→24/6 | 年龄变化；本轮独立非零下限 |
| WindowsTemp | 保留 | 开→关 | 1→48/24 | 默认关+年龄变化，不提权 |
| INetCache | 无规则 | 开→无 | 1→— | 实际移除；共享持久缓存/索引需专门API，历史原因未知 |
| ChromeCache | ChromeCache:Default/Profile_N | 开→开 | 1→24/1 | 环境发现、多Profile实例；缺目录不表示模板删除 |
| EdgeCache | EdgeCache:Default/Profile_N | 开→开 | 1→24/1 | 同上 |
| D3DSCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| NvidiaDXCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| NvidiaGLCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| AmdDxCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| AmdDxcCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| IntelShaderCache | 保留 | 关→关 | 1→336/168 | 年龄变化 |
| SteamHtmlCache | 保留旧版精确htmlcache | 关→关 | 1→168/168 | Steam关闭；不是游戏下载 |
| CrashDumps | 只*.dmp | 关→关 | 1→720/720 | 模式收窄；丢失诊断证据 |
| WERArchive | 保留 | 关→关 | 1→720/720 | WER进程关闭，诊断档位不降龄 |
| WERQueue | 无规则 | 关→无 | 1→— | 当前无规则；本轮未实现诊断资料丢失影响的单独确认流程，待扩展而非永久禁止 |
| ExplorerThumbCache | 保留thumbcache_*.db | 关→关 | 1→168/168 | explorer关闭；同根单枚举 |
| ExplorerIconCache | 保留iconcache_*.db | 关→关 | 1→168/168 | 同上 |
| FontCache | 无规则 | 关→无 | 1→— | 实际移除；旧用户路径待官方验证 |
| ChromeCodeCache | ChromeCodeCache:Profile实例 | 关→关 | 1→24/1 | 环境发现，chrome关闭 |
| ChromeGPUCache | ChromeGPUCache:Profile实例 | 关→关 | 1→24/1 | 同上 |
| EdgeCodeCache | EdgeCodeCache:Profile实例 | 关→关 | 1→24/1 | 环境发现，msedge关闭 |
| EdgeGPUCache | EdgeGPUCache:Profile实例 | 关→关 | 1→24/1 | 同上 |
| ChromeServiceWorkerCache | 无规则 | 关→无 | 1→— | 实际移除；网页离线业务数据，禁止恢复通用递归 |
| EdgeServiceWorkerCache | 无规则 | 关→无 | 1→— | 同上 |
| VivaldiCache | 无规则 | 关→无 | 1→— | 实际移除；本轮官方精确模板证据不足，待验证 |
| FirefoxCache2 | 新FirefoxCache2:Profile/cache2 | 关→关 | 1→24/1 | **旧*.sqlite-wal错误规则永久移除**；新增真正cache2，不是恢复事务日志 |
| VSCodeCache | Roaming\Code\Cache | 关→关 | 1→48/48 | Local→Roaming路径修正；Code关闭 |
| VSCodeCodeCache | Roaming\Code\CachedData | 关→关 | 1→168/168 | 同上 |
| NpmCache | npm-cache\_cacache | 关→关 | 1→168/24 | 中间移除、本轮精确子根恢复；不删整npm-cache |
| NuGetCache | NuGet\v3-cache（HTTP） | 关→关 | 1→168/24 | 中间移除、本轮恢复；名称纠正非global packages |
| NuGetHttpCache | 不恢复NuGet\http-cache | 关→无 | 1→— | 错误/未证实路径实际移除，正确HTTP根由NuGetCache承担 |
| PipCache | 分拆PipHttpCache/PipHttpV2Cache/PipWheelCache | 关→关 | 1→168/24 | 不恢复整Cache递归；明确http/http-v2/wheels |
| YarnCache | Yarn\Cache\v6 | 关→关 | 1→168/24 | 中间移除、本轮Classic受限恢复；不支持Berry |
| PnpmStore | 无规则 | 关→无 | 1→— | 当前无规则；本轮未实现专用回收方式，不递归混合/链接存储 |
| GoBuildCache | Local\go-build | 关→关 | 1→168/24 | 中间移除、本轮恢复默认build，不含模块库 |
| GradleCache | UserProfile\.gradle\caches | 关→关 | 1→720/168 | Local\.gradle路径修正；Java/IDE进程前置 |
| MavenCache | 无规则 | 关→无 | 1→— | 实际移除；可能含本地唯一安装产物 |
| JavaDeploymentCache | 无规则 | 关→无 | 1→— | 实际移除；JRE版本/配置/离线依赖待验证 |
| DiscordCache | 无规则 | 关→无 | 1→— | 实际移除；旧Local路径未证实，不猜Roaming |
| DiscordCodeCache | 无规则 | 关→无 | 1→— | 同上，逐项待验证 |
| DiscordGPUCache | 无规则 | 关→无 | 1→— | 同上，逐项待验证 |
| TeamsCache | Roaming\Microsoft\Teams\Cache | 关→关 | 1→168/24 | 中间移除、本轮路径修正受限恢复Classic |
| TeamsCodeCache | 无规则 | 关→无 | 1→— | 实际移除；本轮官方列举未证实此子根 |
| TeamsGPUCache | Roaming\Microsoft\Teams\GPUCache | 关→关 | 1→168/24 | 路径修正、受限恢复Classic；非新版Teams |
| BraveCache | BraveCache:Profile实例 | 关→开 | 1→24/1 | 环境发现；中间基线已变推荐，历史原因未知，本轮不扩选 |
| BraveCodeCache | BraveCodeCache:Profile实例 | 关→关 | 1→24/1 | 环境发现 |
| BraveGPUCache | BraveGPUCache:Profile实例 | 关→关 | 1→24/1 | 环境发现 |
| OperaCache | 无规则 | 关→无 | 1→— | 实际移除；Stable/GX当前布局待验证 |
| OperaGPUCache | 无规则 | 关→无 | 1→— | 同上，逐项待验证 |
| OfficeFileCache | 无规则 | 关→无 | 1→— | 实际移除；可能有待上传文档，不恢复 |
| RecycleBin | 独立Invoke-SjcRecycle | 关→独立操作 | — | 非扫描规则，不是功能删除；系统确认保留，测试上下文禁止真实清空 |

本轮新增的三个pip子根不与旧整根同时存在，Firefox不会扫描Profiles整根。生产规则ID可随发现而增减，但授权始终在清理前重新生成并比对封存根、模式、年龄、进程与档位。旧偏好未知ID拒绝（不盲目迁移到扩大范围），旧计划安全拒绝，内部v3命名保留。
