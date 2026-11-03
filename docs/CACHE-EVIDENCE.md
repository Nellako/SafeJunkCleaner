# 缓存规则核验依据与未完成项

核验时间：2026-11-03。**事实**与**判断**分开：官方记录目录/缓存语义不等于为本程序逐文件删除、年龄阈值背书。没有进行真实用户缓存清理，也未运行应用配置。网页的latest/master引用可能变化；本轮按当前可读内容核对，后续发布应补充固定版本/真实布局验证。

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
| Teams Classic | [Microsoft Learn训练文档](https://learn.microsoft.com/en-us/training/modules/troubleshoot-audio-video-client-issues/04-clear-microsoft-teams-client-cache)明确AppData\Microsoft\Teams\Cache及GPUCache，并要求退出 | 只恢复Roaming下两项，默认关、168/24h。文档也列其他存储，但本工具不扩大到数据库/离线内容或完整重置；不支持新版MSIX |

上述HTTP缓存的mtime不是最后使用时间；年龄仅缩小处理面，不是“无人需要”的证明。包/编译工具清理不应在离线工作或依赖源失效时使用。

## 本轮没有恢复的范围

| 项目 | 查得的事实与来源 | 结论/下一步 |
|---|---|---|
| Vivaldi Cache | [官方导入/导出文档](https://help.vivaldi.com/desktop/tools/import-and-export-browser-data/)要求从vivaldi:about确认Profile，说明Default携带业务数据；未核实当前所有Windows发行通道的精确缓存模板 | 待验证：固定普通安装/独立安装根与精确缓存子根的官方源码/文档。没有照抄旧Local\Vivaldi路径生成规则 |
| Opera Cache/GPUCache | [官方故障文档](https://help.opera.com/en/latest/crashes-and-issues/)要求opera:about查实际路径；未证明旧Opera Stable直接子根适用于新Profile布局 | 待验证：Stable/GX版本、Local/Roaming与Default布局。禁止猜根、禁止清整个Profile |
| Discord Cache/Code Cache/GPUCache | 本轮support.discord.com精确缓存子根搜索无结果。Electron的一般习惯不等于Discord官方路径保证 | 待验证：官方支持或应用源码的Windows精确位置和可删语义。旧Local\Discord三根未恢复，不以猜测改Roaming |
| Teams Code Cache | 已核验微软列举Cache/GPUCache，但未明确Code Cache | 未恢复；待精确官方依据。新版Teams官方整应用缓存重置不是此引擎的文件规则授权 |
| INetCache | [WinINet Caching](https://learn.microsoft.com/en-us/windows/win32/wininet/caching)明确同用户多应用共享、持久离线缓存、索引与DeleteUrlCacheEntry API | 中风险，不恢复通用递归：原始文件删除不能保证缓存索引一致性；应使用Windows/应用自身管理，需独立API设计与验证 |
| FontCache | [微软Q&A](https://learn.microsoft.com/en-us/answers/questions/2838192/why-wont-my-fonts-work-how-do-i-retrieve-old-fonts)故障重建示例涉及LocalService目录、系统DAT、停服务与管理员权限；并非规范产品路径保证 | 中风险，不能证明旧当前用户Local\FontCache模板。继续不支持，不自动停服务/提权。待产品级权威依据和版本矩阵 |
| JavaDeploymentCache | [Oracle Java 8部署属性](https://docs.oracle.com/javase/8/docs/technotes/guides/deploy/properties.html)存在deployment.user.cachedir/system.cachedir等配置，部署缓存与Java Web Start依赖版本/配置 | 中风险，旧Sun\Java路径不能覆盖所有发行版且离线应用依赖缓存。未恢复。待指定JRE版本、默认布局与完整性/离线影响验证 |
| WERQueue | [Microsoft WER历史说明](https://learn.microsoft.com/en-us/archive/blogs/yongrhee/drwtsn32-on-windows-vistawindows-server-2008windows-7windows-server-2008-r2)区分ReportArchive/ReportQueue；队列可能包含待提交转储 | 中风险，用户接受丢失影响后可设计专用清理。本轮未实现单独的诊断资料清理确认流程，待扩展；目前只保留默认关的30日归档，不以证据价值作为永久禁止理由，也不宣称该历史文档证明所有现代Windows布局 |
| Maven/pnpm | Maven本地仓库可含本地安装产物；pnpm store与依赖链接/实际使用有关系，不是普通HTTP缓存 | 本轮未实现专用清理方式，不执行混合存储递归；后续可使用工具支持的prune/回收机制单独设计验证 |
| Office/Service Worker | 可包含待同步文件或网页离线业务数据；SQLite WAL可能为尚未合并的已提交事务 | 禁止恢复通用规则。两档均保留全局拒绝逻辑 |

**未知历史原因**：旧v2.2.1到首次模块化版本移除/改龄的提交动机未提供，不能从本轮安全评价反推“当时就是这个原因”。逐项事实见RULE-MIGRATION。
