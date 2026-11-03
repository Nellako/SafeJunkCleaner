# 规则范围、档位与来源

**结论：仅支持内置精确缓存根；深度档不是全选，更不是清空全部目录。** 风险为中：包缓存会导致重新下载/编译，诊断文件不可重建。默认仍只勾选推荐项，其他项目必须自行选择。

## 两种档位

`CleaningProfile` 仅接受区分大小写的 `Recommended` / `Deep`。档位改变最低年龄，不改变规则的 `Recommended` 标志，也不自动选择诊断、系统或开发缓存。

| 范围 | 推荐最低小时 | 深度最低小时 | 前置条件/边界 |
|---|---:|---:|---|
| UserTemp | 24 | 6 | 独立非零下限；排除WAL/SHM/Office/网页离线存储 |
| WindowsTemp | 48 | 24 | 不提权；权限不足保留 |
| Chrome/Edge/Brave Cache、Code Cache、GPUCache | 24 | 1 | 固定根下一层Default/Profile N；浏览器关闭 |
| Firefox cache2 | 24 | 1 | 仅Local默认命名Profile；Firefox关闭；默认不勾选 |
| VS Code Cache / CachedData | 48 / 168 | 48 / 168 | Roaming\Code；Code关闭 |
| npm/NuGet/pip/Yarn Classic/Go | 168 | 24 | 明确子根、进程关闭、覆盖配置保守拒绝；默认不勾选 |
| Gradle caches | 720 | 168 | UserProfile\.gradle\caches；Java/IDE关闭 |
| 图形着色器缓存 | 336 | 168 | 旧普通文件；重建可能卡顿；默认不勾选 |
| Steam htmlcache | 168 | 168 | steam/steamwebhelper关闭 |
| Teams Classic Cache/GPUCache | 168 | 24 | Roaming\Microsoft\Teams；Teams/ms-teams关闭 |
| 崩溃转储 / WER归档 | 720 | 720 | 丢失诊断证据；WER进程关闭；不含队列 |
| Explorer图标/缩略图 | 168 | 168 | 精确文件名模式；explorer关闭 |

年龄是本项目的保守产品策略，不是厂商“超过此时间就安全”的承诺；只读、身份、祖先路径、进程校验两档一致。所有规则实际阈值、两档阈值和档位写入规则快照；旧计划缺少新策略字段即拒绝，必须重扫。

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

检测到 `NPM_CONFIG_CACHE`、`NUGET_HTTP_CACHE_PATH`、`PIP_CACHE_DIR`、`YARN_CACHE_FOLDER` 或 `GOCACHE/GOCACHEPROG/GOENV` 时，对应规则返回 `UnsupportedConfiguration`，而非误称应用运行中。变量绝不直接授权目录；未检测配置文件中的覆盖并不意味着采用其路径，工具只处理已知默认位置。不会运行npm/pip/go/yarn或执行应用配置。Yarn只支持已核验的Classic v6布局，不宣称支持Berry。

Firefox只发现 `Local\Mozilla\Firefox\Profiles` 一层 `xxxxxxxx.default/default-release/default-esr`（可带数字后缀）目录中的 `cache2`，不递归寻找任意同名目录，不读profiles.ini/prefs.js，不支持自定义/便携布局。Chrome/Edge/Brave只发现Default和Profile N，不读取用户任意配置。

## 未支持与审计材料

- Vivaldi、Opera、Discord：本轮未恢复；已查官方资料，但精确Windows缓存子根/版本布局证据不足，详见[核验依据与待办](CACHE-EVIDENCE.md)。
- Teams新版MSIX、经典Code Cache：未恢复；不把整个LocalCache、IndexedDB或Local Storage当垃圾。
- INetCache、FontCache、Java部署缓存、WER队列：本轮继续不支持，逐项理由见核验文档。
- 不提供Firefox SQLite事务日志、Maven/pnpm混合仓库、Office待同步缓存、Service Worker/CacheStorage通用递归删除。

[逐项旧新对照](RULE-MIGRATION.md)以指定旧v2.2.1脚本为事实基线；历史动机没有证据时明确标为未知。[性能依据](ENGINE-PERFORMANCE.md)单独列扫描/预览/导出/复核删除，不把分页速度等同整体清理速度。

既有参考：[Chromium目录](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)、[Gradle布局](https://docs.gradle.org/current/userguide/directory_layout.html)、[VS Code数据](https://code.visualstudio.com/docs/setup/uninstall)、[SQLite WAL](https://sqlite.org/wal.html)、[Maven本地仓库](https://maven.apache.org/repositories/local.html)。新增官方引用、来源等级和未证明事项见CACHE-EVIDENCE。
