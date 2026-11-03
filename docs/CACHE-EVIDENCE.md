# 缓存规则核验依据与未完成项

核验时间：2026-11-03。**事实**与**判断**分开：官方记录目录/缓存语义不等于为本程序逐文件删除、年龄阈值背书。没有进行真实用户缓存清理，也未运行应用配置。网页的latest/master引用可能变化；本轮按当前可读内容核对，后续发布应补充固定版本/真实布局验证。

版本说明：下表“本轮实现”列中的“默认关”和“推荐/深度”小时数是 v0.10.0 记录。当前 v0.12.0 待验证候选的档位归属与低／中／高阈值（含高档纯缓存 0 小时）以 [RULES](RULES.md) 三档表为准；本文件只补充新版Teams、WER队列（v0.11.0 起）以及 v0.12.0 发现与维护的证据变化。上文核验时间 2026-11-03 对应既有条目；v0.12.0 新增条目的网页引用同样不是固定版本认证。

## v0.12.0 引擎扩展依据（开发候选）

- [NuGet 官方缓存管理](https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders)明确 `NUGET_HTTP_CACHE_PATH` 覆盖 HTTP 缓存，区别于项目直接引用的 global-packages。首轮只识别 HTTP 布局，不处理全局包仓库；文件名布局仍属具体实现，须匹配后确认。
- NuGet 元数据布局对照 [HttpCacheUtility.cs](https://github.com/NuGet/NuGet.Client/blob/dev/src/NuGet.Core/NuGet.Protocol/HttpSource/HttpCacheUtility.cs) 及 [CachingUtility.cs](https://github.com/NuGet/NuGet.Client/blob/dev/src/NuGet.Core/NuGet.Protocol/Utility/CachingUtility.cs)，只选匹配布局的文件，不把整个覆盖根内任意文件当缓存。
- pip 延续下表官方缓存文档与 [network/cache.py](https://github.com/pypa/pip/blob/main/src/pip/_internal/network/cache.py)、[cache.py](https://github.com/pypa/pip/blob/main/src/pip/_internal/cache.py)、[file_cache.py](https://github.com/pypa/pip/blob/main/src/pip/_vendor/cachecontrol/caches/file_cache.py) 的布局依据，覆盖源仅 `PIP_CACHE_DIR`，只认精确 http/http-v2/wheels 子根与支持的散列目录布局；不执行 Python 或配置脚本，不能证明的布局不授权。以上 dev/main 引用可变化，本轮没有把分支头视为固定版本认证。
- [微软 WinSxS 维护说明](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder?view=windows-11)明确支持提升权限执行 `DISM /Online /Cleanup-Image /StartComponentCleanup`，旧组件立即删除，不具有自动任务的30日缓冲。此工具不带 ResetBase，不直接删组件存储；实际释放量未知，未进行真实维护验证。
- 零龄纯缓存为本工具按精确模板白名单制定的高档策略（Chrome／Edge／Brave Cache、Code Cache、GPUCache，Firefox cache2，VS Code Cache／CachedData，新版 Teams 三个精确缓存，经典 Teams GPUCache），**不是厂商关于所有缓存可随时删的保证**，也没有为“缓存”分组整体背书。经典 Teams Cache、Steam htmlcache、Temp、包／构建缓存、诊断资料和显卡着色器不在白名单内，仍为正数保留期。业务数据、数据库事务日志和离线存储排除维持。
- 缓存位置发现的来源限定为当前进程环境变量 `NUGET_HTTP_CACHE_PATH` 和 `PIP_CACHE_DIR`。上述官方文档只证明这两个变量的含义，不证明可遍历 nuget.config、pip.ini 等配置文件，也不证明任意用户指定路径安全，因此本版不读取配置文件、不接受任意路径；`NPM_CONFIG_CACHE`、`YARN_CACHE_FOLDER`、`GOCACHE` 等不在发现范围。
- Teams WebView2 归属：本版证据只支持“父链与可信路径能证明归属时区分宿主”，不是微软对 msedgewebview2 宿主可随意判断的保证。归属未知、权限不足或签名无法证明时按未知处理并拒绝；npm／Python／Java 宿主未取得可证明无关的依据，保留原名称守卫。
- GitHub 参考材料：BleachBit 所查 `bleachbit/Action.py` 与 `cleaners/google_chrome.xml` 为 GPL-3.0-or-later；Winapp2 规则 `License.md` 为 CC BY-SA 4.0；BCUninstaller `Licence.txt` 及所查 ProgramFilesOrphans.cs 为 Apache-2.0，另有 NOTICE 和第三方例外。本轮只学习机制并独立实现，不直接复制代码或批量收编规则，不声称已审计全仓许可。

## 已实现的受限扩展

| 项目 | 官方依据（事实） | 本轮实现（判断与限制） |
|---|---|---|
| npm | [npm-cache](https://docs.npmjs.com/cli/v12/commands/npm-cache/)：Windows默认LocalAppData\npm-cache，包/HTTP内容在_cacache；缓存自校验、可重新取回 | 只恢复_cacache，不删整根或_npx。node关闭、168/24h、默认关。局部删除可留下失效索引；npm将重取，不宣称等同npm cache verify。离线依赖可能失效 |
| NuGet | [管理缓存](https://learn.microsoft.com/en-us/nuget/consume-packages/managing-the-global-packages-and-cache-folders)：http-cache实际为Local\NuGet\v3-cache，NUGET_HTTP_CACHE_PATH覆盖；global-packages被项目直接引用 | 使用旧ID NuGetCache但名称澄清HTTP。旧NuGetHttpCache的http-cache路径不恢复。dotnet/nuget/MSBuild/devenv关闭；不处理全局包库 |
| pip HTTP | [Caching](https://pip.pypa.io/en/stable/topics/caching/)：Windows Local\pip\Cache；23.3改用http-v2，旧目录http。明确声明内部目录结构为实现细节 | 分离两个明确子根，不清整个pip\Cache；python/pythonw/pip/pip3/uv关闭。不能证明所有pip版本，按已核验布局处理 |
| pip wheel | 同上说明缓存构建wheel；[官方cache.py](https://github.com/pypa/pip/blob/main/src/pip/_internal/cache.py) SimpleWheelCache.get_path_for_link使用cache_dir/wheels | 单独wheels规则；重新构建可能耗时或需要已不可得的构建环境，不承诺离线可用 |
| Go build | [官方default.go](https://go.dev/src/cmd/go/internal/cache/default.go)使用os.UserCacheDir()+go-build；[os/file.go](https://go.dev/src/os/file.go)Windows UserCacheDir使用LocalAppData | 仅默认go-build，不含模块库；go/compile/link/gopls关闭；GOCACHE、GOCACHEPROG、GOENV存在即禁用。未读取go env文件 |
| Yarn Classic | [user-dirs.js](https://github.com/yarnpkg/yarn/blob/master/src/util/user-dirs.js)Windows Local\Yarn\Cache；[constants.js](https://github.com/yarnpkg/yarn/blob/master/src/constants.js)CACHE_VERSION=6；[config.js](https://github.com/yarnpkg/yarn/blob/master/src/config.js)追加v6 | 仅Classic Cache/v6，node关闭；不是Berry/Zero-Installs项目缓存。不能从同名文件夹证明安装版本，默认关并限定目录 |
| Firefox真正cache2 | [官方源码CacheFileIOManager.cpp](https://github.com/mozilla/gecko-dev/blob/master/netwerk/cache2/CacheFileIOManager.cpp)缓存目录追加cache2；[Mozilla支持站讨论](https://support.mozilla.org/en-US/questions/1391075)区分Local cache2与Roaming个人数据 | 源码是产品实现，支持站讨论仅补充非规范解释。只发现Local默认Profile命名下cache2；firefox关闭。绝不恢复旧*.sqlite-wal规则 |
| Teams Classic | [Microsoft Learn训练文档](https://learn.microsoft.com/en-us/training/modules/troubleshoot-audio-video-client-issues/04-clear-microsoft-teams-client-cache)明确AppData\Microsoft\Teams\Cache及GPUCache，并要求退出 | 只恢复Roaming下两项，默认关、168/24h（此处为 v0.10.0 两档历史记录；v0.12.0 中档168小时，高档仅 GPUCache 属纯缓存白名单为0小时，Cache 仍168小时，见 [RULES](RULES.md)）。文档也列其他存储，但本工具不扩大到数据库/离线内容或完整重置；新版Teams另见下一行 |
| 新版Teams（v0.11.0新增） | [Microsoft Learn：Teams VDI 部署要求](https://learn.microsoft.com/en-us/microsoftteams/teams-client-vdi-requirements-deploy)在VDI缓存取舍中列出 LocalAppData\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw 下的 GPUCache、Cache、Code Cache | 该文档是VDI场景的缓存取舍依据，不是对逐文件删除的背书。只处理这三个固定子目录。**档位阈值为 v0.12.0 当前值**：中档168小时；高档三个子目录均为0小时（属精确纯缓存白名单）。v0.11.0 时的中档168／高档24 属历史记录，已被本次改动取代，以 [RULES](RULES.md) 为准。ms-teams/Teams须关闭；msedgewebview2按归属判定，无法证明无关时跳过，不结束进程。清理后网页资源与脚本需重建，离线时可能受影响。本机未发现这些目录，实际覆盖未验证 |

上述HTTP缓存的mtime不是最后使用时间；年龄仅缩小处理面，不是“无人需要”的证明。包/编译工具清理不应在离线工作或依赖源失效时使用。

## 本轮没有恢复的范围

| 项目 | 查得的事实与来源 | 结论/下一步 |
|---|---|---|
| Vivaldi Cache | [官方导入/导出文档](https://help.vivaldi.com/desktop/tools/import-and-export-browser-data/)要求从vivaldi:about确认Profile，说明Default携带业务数据；未核实当前所有Windows发行通道的精确缓存模板 | 待验证：固定普通安装/独立安装根与精确缓存子根的官方源码/文档。没有照抄旧Local\Vivaldi路径生成规则。v0.11.0时本机未发现相应目录，仍未恢复 |
| Opera Cache/GPUCache | [官方故障文档](https://help.opera.com/en/latest/crashes-and-issues/)要求opera:about查实际路径；未证明旧Opera Stable直接子根适用于新Profile布局 | 待验证：Stable/GX版本、Local/Roaming与Default布局。禁止猜根、禁止清整个Profile。v0.11.0时本机未发现相应目录，仍未恢复 |
| Discord Cache/Code Cache/GPUCache | 本轮support.discord.com精确缓存子根搜索无结果。Electron的一般习惯不等于Discord官方路径保证 | 待验证：官方支持或应用源码的Windows精确位置和可删语义。旧Local\Discord三根未恢复，不以猜测改Roaming。v0.11.0时本机未发现相应目录，仍未恢复 |
| Teams Classic Code Cache | 已核验微软列举经典版Cache/GPUCache，但未明确经典版Code Cache | 未恢复；待精确官方依据。新版Teams的Code Cache依据VDI文档单独实现，不能反推经典版布局 |
| 新版Teams整根重置、Service Worker、WebStorage | 新版Teams官方整应用缓存重置会处理更大范围；Service Worker与WebStorage可含网页离线业务数据 | 不纳入。整应用重置不是此引擎的文件规则授权，只保留上表三个固定子目录 |
| INetCache | [WinINet Caching](https://learn.microsoft.com/en-us/windows/win32/wininet/caching)明确同用户多应用共享、持久离线缓存、索引与DeleteUrlCacheEntry API | 中风险，不恢复通用递归：原始文件删除不能保证缓存索引一致性；应使用Windows/应用自身管理，需独立API设计与验证 |
| FontCache | [微软Q&A](https://learn.microsoft.com/en-us/answers/questions/2838192/why-wont-my-fonts-work-how-do-i-retrieve-old-fonts)故障重建示例涉及LocalService目录、系统DAT、停服务与管理员权限；并非规范产品路径保证 | 中风险，不能证明旧当前用户Local\FontCache模板。继续不支持，不自动停服务/提权。待产品级权威依据和版本矩阵 |
| JavaDeploymentCache | [Oracle Java 8部署属性](https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/properties.html)存在deployment.user.cachedir/system.cachedir等配置，部署缓存与Java Web Start依赖版本/配置 | 中风险，旧Sun\Java路径不能覆盖所有发行版且离线应用依赖缓存。未恢复。待指定JRE版本、默认布局与完整性/离线影响验证 |
| WERQueue | [Microsoft WER历史说明](https://learn.microsoft.com/en-us/archive/blogs/yongrhee/drwtsn32-on-windows-vistawindows-server-2008windows-7windows-server-2008-r2)区分ReportArchive/ReportQueue；队列可能包含待提交转储。v0.11.0复查时，当前查到的[微软 WER 故障排查文档](https://learn.microsoft.com/en-us/windows-server/failover-clustering/troubleshooting-using-wer-reports)描述的是服务器场景下系统级 ProgramData\Microsoft\Windows\WER\ReportQueue | 中风险，暂不支持。系统级ProgramData证据不能推广为当前用户LocalAppData下的队列布局；待取得用户级布局的权威依据后再设计专用确认流程。WER归档仍只在高档纳入，阈值720小时；不宣称历史文档证明所有现代Windows布局 |
| Maven/pnpm | Maven本地仓库可含本地安装产物；pnpm store与依赖链接/实际使用有关系，不是普通HTTP缓存 | 本轮未实现专用清理方式，不执行混合存储递归；后续可使用工具支持的prune/回收机制单独设计验证 |
| Office/Service Worker | 可包含待同步文件或网页离线业务数据；SQLite WAL可能为尚未合并的已提交事务 | 禁止恢复通用规则。各档位（v0.10.0两档、v0.11.0三档）均保留全局拒绝逻辑 |

**未知历史原因**：旧v2.2.1到首次模块化版本移除/改龄的提交动机未提供，不能从本轮安全评价反推“当时就是这个原因”。逐项事实见RULE-MIGRATION。
