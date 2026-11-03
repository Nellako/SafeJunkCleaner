# v0.12.0 验证记录

## 结论与证据层次

2026-11-04，v0.12.0 修订后的完整预验收通过：**Core 28／28 用例、1106 断言；Release 34／34 用例、1305 断言**，两轮失败、阻塞、门禁错误和覆盖缺口均为 0。

上述结果绑定本次候选源码和构建哈希，不冒充固定提交后的最终交付。最终本地发布还要求：干净提交、构建前输入捕获、重新构建、完整 Release、真实桌面 12 项检查及晋级封存全部通过。最终提交、构建、测试及发布包哈希由交付目录的 `release-manifest.json`、`test-summary.json` 和 `SHA256SUMS` 记录；未满足门禁则不得更新正式 LATEST 或晋级 main。

本次仅本地交付，不推送远端，不创建线上 Release。旧 [v0.11.0 记录](VALIDATION-0.11.0.md)仅为历史，不能作为本版本证据。

## 1. 环境与版本

- Windows 10.0.26200 x64，Windows PowerShell 5.1.26100.6584，WPF 用例使用 STA；无 Pester 依赖。
- 产品版本 `0.12.0`，EXE 文件版本 `0.12.0.0`，计划格式版本 `1`；内部状态根的 `v3` 不是产品版本。
- 8 个 src 模块均通过解析与 UTF-8 BOM 检查：Main、Version、Rules、Core、Discovery、Maintenance、Worker、Gui。
- 构建工具 ps2exe 1.0.18；单文件脚本与 EXE 使用相同源码、版本及图标。应用未签名，不能把哈希校验当作签名认证。

## 2. 实测记录

| 轮次 | 用例数 | 断言数 | 结果 |
|---|---:|---:|---|
| 初次 Core 基线 | 25 | 821 | 16 用例通过、9 失败；794 断言通过、27 失败 |
| 旧 9 项与 N09 定向复测 | 10 | 425 | 全通过 |
| 初次诊断 Release 定向 | 5 | 82 | 4 通过、G03 因旧控件契约中止 |
| G03 迁移后定向复测 | 1 | 58 | 全通过 |
| N10 缓存发现直接 case | 1 | 143 | 全通过，人工布局范围 |
| N11／G04 直接 case | 2 | 129 | N11 66／G04 63，全通过 |
| 修订后完整 Core | 28 | 1106 | 全通过，exit 0 |
| 修订后完整 Release | 34 | 1305 | 全通过，exit 0 |
| 晋级工具合成自测 | 42 场景 | — | 全通过；不构成产品验收 |
| 最终打包工具独立合成驱动 | 42 场景 | 42 | 全通过；不执行合成 EXE |
| 档位辅助探针 | — | 69 检查 | 修正旧策略期望后全通过；非发布验收 |
| 首次固定提交完整 Release | 34 | 1305 | 全通过，但记录的 EXE 为相对路径，封存拒绝 |
| 绝对路径补验收 | 34 | 1268（运行器汇总） | 32 通过；C05 读锁失败、N08 真实应用进程依赖造成缺口 |

完整 Core／Release 均未使用 `-Case` 筛选。每个声明用例必须正断言、退出码 0、结果 JSON 可解析且无失败/缺口；缺 EXE、超时、零断言和 blocked 不算通过。

### 私有证据索引（仓库内相对路径）

- 基线：`artifacts/verification/cb4ed3b9-b0cc-46e8-8cf3-7660abdffe5b/summary.json`，SHA-256 `2bfd864ab457b62f4e237427e9ab8adfeb10e99aaad43414a5cf4f638b2deadf`。
- 定向 Core：`artifacts/verification/targeted_core_20261104/summary.json`。
- G03：`artifacts/verification/g03final_666f8ef5-01e6-47d7-aef6-30ac6e1b9193/summary.json`。
- N10：`artifacts/verification/n10-cache-discovery_4d14f1c3-6860-42f9-8309-de68ce3e24cc/`。
- N11／G04：`artifacts/verification/n11g04-346abe248567/`。
- 完整预验收 Core：`artifacts/verification/final_core_82255c71-b32d-471a-a4fa-f0e1c3f7d02e/summary.json`。
- 完整预验收 Release：`artifacts/verification/final_release_9ffac10a-5539-4056-9261-519e723284a8/summary.json`。
- 打包工具独立驱动：`artifacts/verification/bd3376af-de8c-49a0-8629-10f5b00853f8/package-synthetic-result.json`。

原始逐用例结果、stdout/stderr、桌面观察、构建前捕获和晋级封存保留在本地。公开包只含脱敏摘要，不包含机器名、私有绝对路径或截图。

## 3. 问题、修复及复测

| 问题 | 处理 | 验证 |
|---|---|---|
| R01／N01／N07／N08 仍要求旧 High 正数年龄 | 按精确 PureCache 白名单允许 High=0；其他规则继续有限正数，并加禁止伪造策略的反向断言 | 定向及完整回归通过 |
| R03 封存字段与 N03 策略版本期望滞后 | 精确验证扩展授权字段与 PolicyRevision=3；保留旧格式拒绝 | 定向及完整回归通过 |
| S02／N04 的测试替身缺少新必需字段 | 补齐规则契约，不放宽生产校验 | 定向及完整回归通过 |
| C01 仍要求扫描前只读文件进入候选 | 验证扫描前只读排除；另加扫描后变只读、清理拒绝、Partial/计数/属性不变 | 52 断言及完整回归通过 |
| G03 仍访问 AdvancedToggle | 按真实 AdvancedButton／草稿函数迁移；验证取消、同集合确定与变化后重扫 | 58 断言及完整回归通过 |
| GUI 测试模式可绑定生产上下文 | 状态创建前校验可信上下文及 IsTest | G04 通过 |
| 失效授权提示与重新确认按钮不一致 | 仅 Supported 且 StaleAuthorization 可用当前 Binding 再确认；有效授权不重复直接授权 | G04 按钮矩阵、N10 绑定变更与重确认通过 |
| 维护视图异常可能残留 Busy | 先清维护状态并释放句柄，再更新视图；3010 单列 RebootRequired，不 Kill | G04 异常及释放测试通过 |
| 晋级必需输入与 GUI 清单落后 | 显式要求 8 模块；发布与晋级统一 12 桌面检查；保留 AST 自动读取所有声明用例 | 42 场景负向自测及 N06 通过 |
| 档位辅助探针仍要求 PolicyRevision=2 | 改验 3，并增加旧 2 被拒绝的合成计划 | 69 检查通过 |
| 打包器初版误拒非路径替身云标签 | 复用精确 CLOUD 标签白名单；junction/symlink/未知标签继续拒绝 | 实机源路径只读检查及独立拒绝测试通过 |
| 高级提示“中强度强度”重复 | 去掉标签后重复后缀 | 固定源码实际桌面已显示“基于中强度。” |
| 相对 EXE 路径可回归通过但不合封存契约 | 运行器入口规范为绝对路径；不改写旧 JSON | 修订后完整回归重新绑定 |
| 云目录瞬时共享锁导致结果 JSON 读取失败 | 对共享/锁定 I/O 错误最多读 5 次并记录重试；语法错误、缺失文件、非零退出及缺口仍失败 | 辅助函数 10／10 通过；短锁重试成功、长锁超预算失败均实测 |
| N08 必需覆盖依赖用户恰好运行真实应用 | 必需守卫采用当前自有进程的真实查询，明确映射测试字段；真实应用观察单列限制 | N08 定向 81 断言通过；RunningProcess／Success／未知策略均实际调用验证，不启动或结束用户应用 |

## 4. 专项覆盖与实际观察

- N09：精确 16 个纯缓存模板、伪造白名单拒绝、0 小时的新/旧文件、未来/只读/硬链接拒绝及人工清理；Teams 归属采用隔离进程记录覆盖所属、明确无关、未知、PID/父链变化等情况，不启动或结束真实应用。
- N10：NuGet/pip 人工精确布局，发现不授权、展示绑定、目录替换、来源变化、撤销和消失授权、32/33 数量上限；真实调用人工 scan/clean 验证旧绑定/旧计划拒绝且文件保留。Worker 载荷只接受 ID 等白名单字段，不接受 Root/TestRoot/Binding 注入。
- N11：固定 DISM 路径/参数/runas、无 ResetBase、签名拒绝、TestMode、成功句柄/空句柄、直接及嵌套 1223 取消和启动失败。接受启动分支使用替身，不实际提权。
- G04：可信测试上下文、有效/失效授权按钮、关闭发现/维护窗口、维护 0/3010/非零/Unknown、Dispose/view 异常、运行中不释放、退出时仅 Dispose 不 Kill。
- 主对话另用 32 位 PowerShell 只读调用启动规格：64 位 Windows 下选择 `Sysnative\dism.exe`，工作目录 System32，固定参数；没有启动 DISM。

实际桌面诊断使用本实现自建 GUID 人工 450 文件：主窗 v0.12.0、白底图标、默认高级关闭；第 1／3 页到第 2／3 页、跨页勾选与保留恢复；发现窗口未默认授权；维护说明为“尚未启动”，关闭不触发 UAC；取消高级草稿后仍为 450 候选、中强度 2 条规则。清理确认窗正确展示封存档位、数量、路径、影响与回收站说明，取消后主窗仍可用。三档切换即时改变集合并清除旧预览，不自动扫描。

这些预提交观察不能代替最终构建后的真实桌面封存。最终记录必须有实际观察、源码/图标哈希、AcceptedUtc 与可核实证据文件，12 项分别为：DesktopWindowObserved、RuleSelectionObserved、CandidatePagingAndKeepRestore、NoProductionDeletion、WhiteBackgroundIconObserved、CompactLayoutObserved、CleaningProfileConfirmationObserved、SingleWindowFlowObserved、ThreePresetImmediateApplyObserved、AdvancedCustomOffByDefaultObserved、DiscoveryAuthorizationCancelObserved、MaintenanceCancelObserved。

## 5. 未验证及残余边界

- 未执行真实用户缓存删除、真实回收站清空、真实 UAC 或 DISM；人工文件的回收站移动不等于清空真实回收站。
- 没有完整多 DPI、多显示器、屏幕阅读器及所有第三方应用布局认证。
- 生产环境覆盖变量发现未用真实缓存实跑；pip 已授权规则的实际 scan/clean 未在运行中的 Python 宿主上强行执行，守卫保守拒绝。
- 未验证 NTFS 身份复用极端场景；不把全绿当作消除文件名 TOCTOU 或隔离同用户恶意代码的证明。
- 有效微软签名后的真实系统维护执行及耗时、释放量、更新回退影响未验证，不作效果保证。
- 原始日志、扫描计划与授权记录可能含完整路径，必须私有保留，不能随公开源码包或应用包发布。

本版不宣称性能提升。许可与第三方条款不变，源码公开不等于获得修改或再分发许可。
