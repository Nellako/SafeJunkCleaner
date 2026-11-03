# v2.2.1 到当前规则逐项对照

事实基线：仓库旁备份 `backups/20261102_230206/moved-workspace-materials/SafeJunkCleaner_v2.2.1.ps1` 的Get-CleanRules规则表（232–288行），全局MinimumFileAgeMinutes=60（197行，扫描/清理均应用）。旧源文件只读，不执行。中间基线是本轮修改前模块化Rules/Core/Worker（保存在artifacts/engine-baseline-20261103）。旧表合计51项，含独立回收站。不是“少了一个显示项就实际少了一个清理能力”。

下表“当前”指 v0.10.0（正式稳定版）的推荐／深度两档。当前待验证候选 v0.12.0 的档位归属见文末“v0.11.0 三档映射”，高档零保留期与发现授权的变化见其后的“v0.12.0 变更”，均不改写下表历史记录。

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

## v0.11.0 三档映射（本地开发候选，实现与验收进行中）

推荐／深度由低／中／高替代，每条规则以 `PresetLevel` 标明最低纳入档位。“默认勾选”概念改为档位成员：选择档位即应用，无需逐项勾选。阈值详表见 [RULES](RULES.md)。

| 纳入档位 | 规则（沿用上表已有类别，除注明外） |
|---|---|
| 低 | UserTemp；Chrome/Edge/Brave Cache；FirefoxCache2 |
| 中 | WindowsTemp；Chrome/Edge/Brave Code Cache、GPUCache；VSCodeCache、VSCodeCodeCache；TeamsCache、TeamsGPUCache（经典版）；SteamHtmlCache；六项着色器缓存；**新增** NewTeamsCache、NewTeamsGPUCache |
| 高 | NpmCache、NuGetCache、PipHttpCache、PipHttpV2Cache、PipWheelCache、YarnCache、GoBuildCache；GradleCache；CrashDumps、WERArchive（不可重建的诊断资料）；**新增** NewTeamsCodeCache |
| 仅高级自定义 | ExplorerThumbCache、ExplorerIconCache |

v0.11.0 未改变上表“无规则”项的状态：INetCache、FontCache、ServiceWorker、Vivaldi、Opera、Discord、TeamsCodeCache（经典版）、WERQueue、Maven、pnpm、Java部署缓存、Office缓存仍未支持。WERQueue当前查到的微软证据是系统级 ProgramData 下的 ReportQueue，不能推广到用户级。扩大的覆盖主要来自已有类别被预设自动纳入，以及新版Teams三个精确缓存，不是旧版51项的全面恢复。

偏好迁移：新偏好文件为 `preferences-v4.json`，新用户默认中档。只有 `preferences-v3.json` 时迁移为低档预设，高级自定义保持关闭，不沿用旧版可选勾选，显示迁移提示，旧文件保留。旧档位名 `Recommended`／`Deep` 的计划拒绝执行，必须重扫。

## v0.12.0 变更（待验证的本地开发候选）

本节只记录相对 v0.11.0 三档映射的差别，档位成员不变；阈值以 [RULES](RULES.md) 为准。

- **高档零保留期（`AgePolicy=PureCache`）**：仅精确模板白名单的 High 阈值为 0 小时，即 Chrome／Edge／Brave 的 Cache、Code Cache、GPUCache，FirefoxCache2，VSCodeCache、VSCodeCodeCache，NewTeamsCache、NewTeamsGPUCache、NewTeamsCodeCache，以及经典 TeamsGPUCache。其余规则的高档阈值不变且仍为正数：UserTemp 6、WindowsTemp 24、包／构建缓存 24 或 168、CrashDumps／WERArchive 720、着色器 168，经典 TeamsCache 与 SteamHtmlCache 也不在白名单内。Low／Medium 阈值不变。
- **自定义缓存位置**：NuGet HTTP 与 pip 子根除内置默认位置外，可经只读发现和用户授权进入规则，来源仅限当前进程环境变量 `NUGET_HTTP_CACHE_PATH`、`PIP_CACHE_DIR`；授权随规则 ID 管理，不改变上表旧 ID 的对应关系，也不使旧计划迁移成授权。
- **新增非规则入口**：系统维护（DISM 组件清理）不是扫描规则，不对应旧 51 项中的任何条目，不进入候选或释放量统计。
- **新版 Teams**：进程策略改为按 WebView2 归属判定，规则成员与目录不变。归属未知时仍跳过。

v0.12.0 不新增对 Vivaldi、Opera、Discord、经典 Teams Code Cache、WER 队列、INetCache、FontCache、Java 部署缓存、Maven、pnpm、Delivery Optimization 或便携浏览器自定义 Profile 的支持，也不宣称旧版 51 项已全部恢复。
