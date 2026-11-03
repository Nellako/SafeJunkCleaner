# 规则范围、档位与来源

**结论：仅支持内置精确缓存根；高档不是全选，更不是清空全部目录。** 风险为中：包缓存会导致重新下载/编译，高档包含的诊断文件不可重建。

> 下表为 v0.12.0。三档预设自 v0.11.0 引入；本版将高档列中的精确纯缓存白名单改为 0 小时。实际验收范围见本版验证记录，最终本地成品以发布清单及 LATEST 为准。历史 v0.10.0 以其包内说明为准。
>
> **零保留期仅限精确纯缓存白名单**（`AgePolicy=PureCache`，只在 High 档取 0 小时）：Chrome／Edge／Brave 的 Cache、Code Cache、GPUCache，Firefox cache2，VS Code Cache／CachedData，新版 Teams 的 Cache、GPUCache、Code Cache，经典 Teams GPUCache。授予依据是精确模板 ID，不是“Cache”字样或分组。**经典 Teams Cache、Steam htmlcache、Temp、包／构建缓存、诊断资料和显卡着色器都不在白名单内，仍为正数保留期。** 0 小时不绕过进程、占用、未来时间、只读、链接或身份检查。Low／Medium 不变。
>
> 支持从当前进程环境变量 `NUGET_HTTP_CACHE_PATH` 和 `PIP_CACHE_DIR` 只读发现 NuGet HTTP 和受支持布局的 pip 子缓存，不遍历配置文件，不接受任意路径输入。发现位置不是清理权限：须用户确认，授权绑定来源、精确路径、目录身份和模板，变化后失效，可撤销。仅已授权且当前匹配的位置进入可信规则，普通 Worker 仍不接收任意 Root。详见 [SAFETY](SAFETY.md)。系统 DISM 维护为独立入口，不属于文件扫描规则，不统计为候选文件或已释放空间。

## 三档预设（v0.11.0 引入，v0.12.0 更新）

`CleaningProfile` 仅接受区分大小写的 `Low` / `Medium` / `High`；旧 `Recommended` / `Deep` 计划一律拒绝，必须重扫。每条规则用 `PresetLevel` 标明最低纳入档位，高档位包含低档位全部成员；阈值分别取 `LowMinimumAgeHours`、`MediumMinimumAgeHours`、`HighMinimumAgeHours`。未分配预设档位的规则为 `CustomOnly`，只能在高级自定义中选择。

选择档位即应用，普通使用无需逐项勾选；新用户默认中档。高级自定义默认关闭，重启后不会自动启用。下表“—”表示该档预设不纳入此规则。

| 范围 | 纳入档位 | 低 | 中 | 高 | 前置条件/边界 |
|---|---|---:|---:|---:|---|
| UserTemp | 低 | 24 | 24 | 6 | 独立非零下限；排除WAL/SHM/Office/网页离线存储 |
| Chrome/Edge/Brave Cache | 低 | 24 | 24 | **0** | 纯缓存白名单；固定根下一层Default/Profile N；浏览器关闭 |
| Firefox cache2 | 低 | 24 | 24 | **0** | 纯缓存白名单；仅Local默认命名Profile；Firefox关闭 |
| WindowsTemp | 中 | — | 48 | 24 | 不提权；权限不足保留 |
| Chrome/Edge/Brave Code Cache、GPUCache | 中 | — | 24 | **0** | 纯缓存白名单；同浏览器Cache |
| VS Code Cache / CachedData | 中 | — | 48 / 168 | **0** | 纯缓存白名单；Roaming\Code；Code关闭 |
| Teams Classic GPUCache | 中 | — | 168 | **0** | 纯缓存白名单；Roaming\Microsoft\Teams；Teams/ms-teams关闭 |
| Teams Classic Cache | 中 | — | 168 | 24 | 不在白名单，仍为正数；Teams/ms-teams关闭 |
| Steam htmlcache | 中 | — | 168 | 24 | 不在白名单；steam/steamwebhelper关闭 |
| 新版 Teams Cache / GPUCache | 中 | — | 168 | **0** | 纯缓存白名单；见下文新版Teams；ms-teams/Teams关闭，msedgewebview2按归属判定 |
| 图形着色器缓存 | 中 | — | 168 | 168 | 中、高均保留168小时，避免频繁重编译；重建可能卡顿 |
| 新版 Teams Code Cache | 高 | — | — | **0** | 纯缓存白名单；同新版Teams |
| npm/NuGet HTTP/pip/Yarn Classic/Go | 高 | — | — | 24 | 明确子根、进程关闭、覆盖配置保守拒绝 |
| Gradle caches | 高 | — | — | 168 | UserProfile\.gradle\caches；Java/IDE关闭 |
| 崩溃转储 / WER归档 | 高 | — | — | 720 | **不可重建，丢失历史故障诊断资料**；WER进程关闭；不含队列 |
| Explorer图标/缩略图 | 仅高级自定义 | — | — | — | 精确文件名模式；explorer关闭；任何预设都不纳入 |

高级自定义中手动加入预设外规则时，阈值以 `src/Rules.ps1` 中该规则的对应字段为准，本文不另列。年龄是本项目的保守产品策略，不是厂商“超过此时间就安全”的承诺；只读、身份、祖先路径、进程校验三档一致，高档也不绕过。档位、各档阈值和实际阈值写入规则快照；切换档位后旧计划失效，旧计划缺少新策略字段即拒绝，必须重扫。

## 新版 Teams 精确缓存

只处理 `Local\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView\WV2Profile_tfw` 下的 `GPUCache`、`Cache`、`Code Cache` 三个固定子目录，依据见 [CACHE-EVIDENCE](CACHE-EVIDENCE.md)。要求 ms-teams、Teams 已关闭。对 msedgewebview2，只有明确判定归属“无关”才不阻断；归属未知（含父链变化、权限不足或签名无法证明）时保守拒绝，工具不会读取命令行，也不会结束任何进程。进程是否存在、文件是否未被占用，都不是独立的安全证明。判定细节见 [SAFETY](SAFETY.md)。清理后 Teams 需重新获取网页资源、重新编译脚本，离线时可能受影响。不纳入整个 Teams 根目录重置、Service Worker、CacheStorage 或 WebStorage。本机未发现这些目录，实际清理覆盖未验证。

## 精确开发缓存模板

以下Local表示系统SpecialFolder LocalApplicationData，不直接信任环境变量作为清理根。

| ID | Local下精确根 | 不包含 |
|---|---|---|
| NpmCache | npm-cache\_cacache | npm-cache整根、_npx安装树、日志与项目 |
| NuGetCache | NuGet\v3-cache | global-packages、plugins、NuGet\http-cache误路径 |
| PipHttpCache / PipHttpV2Cache | pip\Cache\http / http-v2 | 虚拟环境、pip整根 |
| PipWheelCache | pip\Cache\wheels | 项目wheel输出目录 |
| YarnCache | Yarn\Cache\v6 | Yarn Berry .yarn/cache、全局安装/项目 |
| GoBuildCache | go-build | GOPATH、GOMODCACHE、源码/模块仓库 |

检测到 `NPM_CONFIG_CACHE`、`NUGET_HTTP_CACHE_PATH`、`PIP_CACHE_DIR`、`YARN_CACHE_FOLDER` 或 `GOCACHE/GOCACHEPROG/GOENV` 时，对应规则返回 `UnsupportedConfiguration`，而非误称应用运行中。变量绝不直接授权目录；固定规则只处理已知默认位置，不读取配置文件中的覆盖。其中 `NUGET_HTTP_CACHE_PATH` 与 `PIP_CACHE_DIR` 另有只读发现与用户授权流程（见上文提示和 [SAFETY](SAFETY.md)），来源仅限当前进程的这两个环境变量，不遍历任意配置文件或任意路径；`NPM_CONFIG_CACHE`、`YARN_CACHE_FOLDER`、`GOCACHE` 等仍不支持发现。不会运行npm/pip/go/yarn或执行应用配置。Yarn只支持已核验的Classic v6布局，不宣称支持Berry。

Firefox只发现 `Local\Mozilla\Firefox\Profiles` 一层 `xxxxxxxx.default/default-release/default-esr`（可带数字后缀）目录中的 `cache2`，不递归寻找任意同名目录，不读profiles.ini/prefs.js，不支持自定义/便携布局。Chrome/Edge/Brave只发现Default和Profile N，不读取用户任意配置。

## 未支持与审计材料

- Vivaldi、Opera、Discord：仍未恢复；精确Windows缓存子根/版本布局证据不足，本机也未发现相应目录，详见[核验依据与待办](CACHE-EVIDENCE.md)。
- Teams Classic Code Cache：仍未恢复，证据不足。新版Teams只支持上文三个固定子目录，不把整个LocalCache、IndexedDB、Local Storage、Service Worker或WebStorage当垃圾。
- WER队列：暂不支持。当前查到的微软资料描述的是系统级 ProgramData 下的 ReportQueue，不能推广为用户级队列布局。
- INetCache、FontCache、Java部署缓存：继续不支持，逐项理由见核验文档。
- 预设扩大的覆盖主要来自已有类别自动纳入档位，以及新版Teams精确缓存；不宣称已全面支持旧版51项。
- 不提供Firefox SQLite事务日志、Maven/pnpm混合仓库、Office待同步缓存、Service Worker/CacheStorage通用递归删除。

[逐项旧新对照](RULE-MIGRATION.md)以指定旧v2.2.1脚本为事实基线；历史动机没有证据时明确标为未知。[性能依据](ENGINE-PERFORMANCE.md)单独列扫描/预览/导出/复核删除，不把分页速度等同整体清理速度。

既有参考：[Chromium目录](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)、[Gradle布局](https://docs.gradle.org/current/userguide/directory_layout.html)、[VS Code数据](https://code.visualstudio.com/docs/setup/uninstall)、[SQLite WAL](https://sqlite.org/wal.html)、[Maven本地仓库](https://maven.apache.org/repositories/local.html)。新增官方引用、来源等级和未证明事项见CACHE-EVIDENCE。
