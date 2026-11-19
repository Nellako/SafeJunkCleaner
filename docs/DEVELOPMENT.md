# 构建与验证（v0.17.0 beta）

## v0.17 快速清理入口

生产主窗口通过包内可信清单定位独立的 `explorer/sjc-quickclean.exe`。它与 `sjc-explorer.exe` 共享同一套本地 .NET 10 Windows x64 运行时，但各自拥有独立的入口、任务格式和授权判断。快速清理任务的扫描、文件身份复核、回收和永久处理不依赖 PowerShell 子进程。界面和既有隔离测试仍使用 PowerShell。

`tools/explorer/Publish-Explorer.ps1` 对两个 Host 锁定还原、分别发布，合并前逐个校验同名运行时文件；随后用原有 `scripts/build.ps1 -ExplorerDirectory ...` 构建窗口。发布源码和交付包必须来自同一工作快照。QuickClean 专项验证方法见源码内 `tests/quickclean-beta/README.md`：将测试驱动绑定交付包中的 DLL，核对中断、重放、替换、回收和永久处理结果。通用 Release 套件中的历史 PowerShell 自检不能代替这项验证。

以下章节描述沿用的深度探索、Windows 包和旧版测试约定；凡涉及快速清理执行，以本节和本版交付记录为准。

本文面向维护与验证人员，说明当前源码树的构建方式、依赖边界、回归测试与本地发布门禁。本文是技术说明，不扩大 [LICENSE](../LICENSE) 的源码授权范围。

## 当前版本与架构基线（v0.16.1）

- **产品版本**：`0.16.1`（唯一配置源为根目录 `version.json`，`fileVersion` 为 `0.16.1.0`，`planSchemaVersion` 为 `1`）。可靠性修订使用新的 `BuildId`，旧历史包保留；版本号本身不代表正式验收通过。
- **产品模式**：`ModelMode=Absent`、`AlgorithmMode=Heuristic`（无模型启发式探索 + 三档快速清理）。不引用 `Explorer.Model`，不启动模型推理进程，不读取旧模型缓存。
- **宿主契约**：探索宿主 `Host ContractVersion=3`，JSONL envelope `ProtocolVersion=1`（输入上限 32768 字节、响应上限 262144 字节、分页上限 64）。生产 C# 工程为 `engine/` 下的 5 个项目：`Explorer.Core`、`Explorer.Analysis`、`Explorer.Execution`、`Explorer.Application`、`Explorer.Host`（共用 `engine/Directory.Build.props`）。
- **PowerShell 模块**：`src/` 下共 9 个脚本模块，按 `Main.ps1`、`Version.ps1`、`Rules.ps1`、`Core.ps1`、`Discovery.ps1`、`Maintenance.ps1`、`Worker.ps1`、`Gui.ps1`、`ExplorerGui.ps1` 顺序合并为单文件脚本（以 `scripts/build.ps1` 与 `scripts/local-promotion-common.ps1` 的清单为准）。模块导入不启动扫描。
- **探索与执行边界**：
  - 盘点支持单范围与逐盘串行的固定磁盘全盘批次（库存 schema v4）。
  - 分析阶段采用有界内存预算（取本机物理安装内存 1/8、当时空闲物理内存 1/2 与 4GiB 三者较小值），失败时释放大快照引用且丢弃可重建显示缓存，不删除已有扫描记录。
  - 会话记录空间预算默认 `512 MiB`，支持在当前会话内于 `512–16384 MiB` 之间调整（重开恢复默认），另保留至少 `256 MiB` 磁盘余量保护。
  - 旧版 schema 4 库存缺 `task_objects` 性能索引且余量不足时，暂缓建索引，仍可启动并查看记录。`GetStorageInfo` 的 `IndexRepairPending` 标明此状态；用户在“记录与帮助”的高级详情中确认调整本会话预算后，`ConfigureStorageBudget` 重试受预算约束的索引修复。原表数据、扫描范围与批准不改变，新盘点仍受原有配额保护。

## 依赖与运行时边界

- **快速清理**：Windows 桌面环境、Windows PowerShell 5.1 与系统 .NET Framework WPF 组件。脚本保持 UTF-8 BOM。
- **EXE 构建工具**：`ps2exe 1.0.18`（仅构建 EXE 时需要；`-ScriptOnly` 模式不需要）。仓库不内置该工具，不自动安装，构建时通过模块发现或 `-Ps2ExeModulePath` 显式指定，并随 Windows 分发包提供 `assets/third-party/PS2EXE-LICENSE.txt`。
- **探索宿主运行时与 NuGet 依赖**：使用隔离的 .NET 10 SDK 与 NuGet 缓存恢复锁定依赖（`packages.lock.json`），发布自包含（self-contained）`win-x64` 探索目录，禁止改为 framework-dependent 或跳过锁定还原。
  - 新CLI home运行前设置 `DOTNET_GENERATE_ASPNET_CERTIFICATE=false`、`DOTNET_ADD_GLOBAL_TOOLS_TO_PATH=false`，避免SDK首次运行安装开发证书或更改工具PATH。原生命令stderr保留作诊断，以实际退出码判断构建成功；不因stderr有内容就中止，也不忽略非零退出。
  - 自包含运行时与宿主包固定为 `10.0.15`，替换此前处于安全通告影响范围的 `10.0.14`。SQLite 托管依赖保持 `10.0.14`、SQLitePCLRaw 保持 `2.1.13`；不同组件不要求版本号相同。以组件清单、RID 锁定还原及官方包 SHA-512 校验记录核对实际载荷。

## 构建流程

```powershell
# 1. 仅生成合并单文件脚本（开发调试用，不含 ExplorerHost，不是完整产品包）
powershell.exe -NoProfile -File .\scripts\build.ps1 -ScriptOnly

# 2. 使用已发布并核验的自包含无模型 Explorer 目录构建完整 EXE（需 ps2exe 1.0.18）
powershell.exe -NoProfile -File .\scripts\build.ps1 -ExplorerDirectory '<无模型自包含Host目录>'
```

- 如需显式指定 `ps2exe 1.0.18` 路径，可附加 `-Ps2ExeModulePath '<ps2exe.psd1 的实际路径>'`。
- 禁止传入 `-ModelDirectory`（`ModelMode=Absent` 明确拒绝模型参数与旧模型缓存）。
- 每次构建生成独立目录 `artifacts/builds/<时间_GUID>/`，包含合并脚本 `SafeJunkCleaner_v0.16.1.ps1`、主程序 `星梦雨垃圾清理器_v0.16.1.exe`、长路径运行时配置 `星梦雨垃圾清理器_v0.16.1.exe.config`、`explorer/` 组件目录、`source-manifest.json` 与 `build-manifest.json`（含 `BuildId` 与精确文件哈希）。构建先绑定 `explorer/host-component-manifest.json` 哈希到合并脚本，再生成主 EXE 与总体指纹，避免哈希循环。
- 应用图标 `assets/app.ico` 由 `scripts/generate-icon.ps1` 从 `assets/app-icon-source.png` 生成（16/24/32/48/64/128/256 纯白底尺寸），单文件脚本嵌入 Base64 图标，EXE 嵌入同源 ICO 资源。

## 回归与独立验证要求

```powershell
# 核心隔离回归（仅验证引擎与隔离契约，不等于完整发布通过）
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Core

# 完整 Release 回归（含 GUI 自检、后台预览、Main 与 EXE 独立进程、探索工作台等）
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Release -ExePath '<本次构建EXE路径>'
```

- **严格通过标准**：任意非零退出码、超时、缺失或无法解析的 JSON、零断言、`Failed > 0`、`Blocked > 0` 或存在 `CoverageGaps` 均视为不通过，不得用子集通过或 `KNOWN-RED` 冒充全绿。注意当前完整 Release 注册表包含全部声明用例（含 `N06-local-promotion`），不得删除断言或用跳过子集代替完整回归。
- **三大最终测试结果组（`FinalTestResult`）**：对于无模型组件版本（`0.14.0`–`0.16.1`），正式验收结构要求提供完整且通过的三组独立验证结果：`ReleaseRegression`、`ExplorerHost`、`HeuristicExploration`。
- **15 项桌面观察（Desktop Acceptance）**：`publish.ps1`、`package-candidate.ps1`（非 `-StageOnly`）与本地晋级封装对 `0.14.0`–`0.16.1` 共同要求以下 **15 项**实际原生窗口观察全部为 `Passed: true`（并绑定当前 `GuiSourceSHA256`、`IconSHA256`、绝对路径 `EvidenceFiles` 与 `AcceptedUtc`），同时禁止出现 `ModelOfflineObserved`：
  - 沿用基础 12 项：`DesktopWindowObserved`、`RuleSelectionObserved`、`CandidatePagingAndKeepRestore`、`NoProductionDeletion`、`WhiteBackgroundIconObserved`、`CompactLayoutObserved`、`CleaningProfileConfirmationObserved`、`SingleWindowFlowObserved`、`ThreePresetImmediateApplyObserved`、`AdvancedCustomOffByDefaultObserved`、`DiscoveryAuthorizationCancelObserved`、`MaintenanceCancelObserved`。
  - 探索与无模型 3 项：`ExplorerHostObserved`、`NoModelPayloadObserved`、`HeuristicAnalysisObserved`。
- **真实原生窗口验证边界**：WPF 交互修复（如快捷选盘回填与 `Escape`、最小窗口 `820×560` 复核列表可读性、高级自定义 `Escape` 取消、准备期间返回取消）必须在真实原生 WPF 窗口与 Dispatcher 消息泵下验证，不能用 HTML/浏览器模拟、纯内存 Hashtable 替身或“换盘再换回”的绕行脚本代替。
- **沙箱与未实测声明**：自动测试仅操作本轮具备所有权标记的 GUID 人工沙箱；保留失败与部分证据目录，不递归清理归属不明的历史目录。真实用户缓存删除、真实非空回收站清空、真实 UAC／DISM、完整多 DPI／多显示器矩阵与大规模真实文件内容分析均未纳入自动验收，不得宣称已覆盖。

可用 `scripts/gui-isolated.ps1` 创建人工候选界面预览（`-Show` 展示原生窗口）；`TestMode` 下禁止启动生产清理 Worker。

## 打包与本地发布晋级

### 1. 候选打包（开发验证）

```powershell
# StageOnly：仅生成未验收开发候选包（不代表验证通过）
powershell.exe -NoProfile -File .\scripts\package-candidate.ps1 `
  -SourceRepository '<develop 仓库根>' -BuildDirectory '<本次 build 目录>' `
  -OutputParent '<与源码/构建分离的交付父目录>' -StageOnly

# VerifiedCandidate：绑定 FinalTestResult 与 15 项桌面验收证据
powershell.exe -NoProfile -File .\scripts\package-candidate.ps1 `
  -SourceRepository '<develop 仓库根>' -BuildDirectory '<本次 build 目录>' `
  -OutputParent '<与源码/构建分离的交付父目录>' `
  -FinalTestResultPath '<FinalTestResult JSON 绝对路径>' `
  -DesktopAcceptancePath '<15项桌面验收 JSON 绝对路径>'
```

- 无模型打包执行载荷体积上限检查（Windows ZIP ≤ 50 MiB、展开后产品文件 ≤ 100 MiB）与无模型载荷检查。
- 预期随 Windows 用户包分发的文档包括 `README.md`、`LICENSE`、`THIRD-PARTY-NOTICES.md`、`assets/third-party/PS2EXE-LICENSE.txt`、`docs/使用手册.md`、`docs/SAFETY.md`、`docs/RULES.md`、`docs/DEVELOPMENT.md`、`docs/RELEASE-0.16.1.zh-CN.md` 等公开必需文件；历史验证报告、内部决策记录与设计草案保留在源码仓库，不全部打入普通用户 Windows 包。

### 2. 正式本地发布与晋级

```powershell
# 正式发布目录整理（要求完整 FinalTestResultPath 与 15 项桌面验收）
powershell.exe -NoProfile -File .\scripts\publish.ps1 `
  -BuildDirectory '<本次 build 目录>' `
  -VerificationDirectory '<本次完整 Release 验证目录>' `
  -GuiAcceptancePath '<15项桌面验收 JSON 绝对路径>' `
  -FinalTestResultPath '<FinalTestResult JSON 绝对路径>'

# 在干净固定提交与已通过 publish 目录基础上生成最终交付压缩包
powershell.exe -NoProfile -File .\scripts\package-local.ps1 `
  -SourceRepository '<develop 绝对路径>' -ExpectedSourceHead '<完整 40 位提交 ID>' `
  -ReleaseDirectory '<publish 产物目录>' -OutputDirectory '<父目录已存在的新交付目录>'
```

- `develop` 负责开发，`main` 负责已验收版本；父汇总目录本身不是 Git 仓库。
- 提交前固定、构建前输入捕获（`-CaptureBuildInputs`）、证据封装（`seal-local-promotion.ps1`）与单向快进（`promote-local.ps1`）的完整契约见源码仓库中的 `docs/LOCAL-PROMOTION.md`。维护者未审阅、提交并批准前，不自动提交、不更新 `LATEST`、不晋级 `main` 或对外推送。

## 修订构建的绑定

组件版本的构建前捕获与证据封装都须传入同一个 `-FinalTestResultPath`。捕获时指定计划保存最终结果的位置，文件可以尚不存在；封装时必须存在并匹配本次构建、源码与全部验证结果。修改路径、换包或缺少记录均应拒绝。

候选输出目录整体保存：不要拆走 `documents/` 或移动 ZIP 后仍复用旧相对路径清单。运行与文档文件集合、内部链接、许可正文和 ZIP 内容都需校验。仓库 `.gitattributes` 保留实际字节，避免自动换行转换导致“工作文件与固定提交”指纹不同；`git diff --check` 仍检查真实尾空格。

每个新 `BuildId` 的实际已测／未测结论保存在其交付验收记录，不把本文中的实现说明当作已执行测试证据。

---

## 历史参考与源码仓库内部文档导航

以下材料保留在源码仓库中供维护者回溯历史背景与设计演进，**不作为当前 v0.16.1 产品的测试通过依据，也不全部随普通 Windows 用户包分发**（路径均相对于源码仓库根目录）：

- **随包公开文档**：`README.md`、`LICENSE`、`THIRD-PARTY-NOTICES.md`、`assets/third-party/PS2EXE-LICENSE.txt`、`docs/使用手册.md`、[安全说明](SAFETY.md)、[规则说明](RULES.md)、[v0.17.0 beta 说明](RELEASE-0.17.0.zh-CN.md)、`docs/DEVELOPMENT.md`
- **仅源码仓库文档（版本与修复）**：`CHANGELOG.md`、`docs/REPAIR-0.16.1.md`、`docs/VALIDATION-0.16.1.md`、`docs/LOCAL-PROMOTION.md`
- **仅源码仓库文档（契约与规则考据）**：`docs/EXPLORATION-CONTRACT.md`、`docs/RULE-MIGRATION.md`、`docs/CACHE-EVIDENCE.md`
- **仅源码仓库历史发布与验证归档（仅作背景）**：`docs/RELEASE-0.16.0.zh-CN.md`、`docs/VALIDATION-0.16.0.md`、`docs/RELEASE-0.15.0.zh-CN.md`、`docs/VALIDATION-0.15.0.md`、`docs/RELEASE-0.14.0.zh-CN.md`、`docs/VALIDATION-0.14.0.md`、`docs/RELEASE-0.13.0.zh-CN.md`、`docs/VALIDATION-0.13.0.md`、`docs/RELEASE-0.12.0.zh-CN.md`、`docs/VALIDATION-0.12.0.md`、`docs/VALIDATION-0.11.0.md`、`docs/RECOVERY-0.10.0.md`、`docs/VALIDATION-0.10.0.md`
- **仅源码仓库设计与决策记录**：`docs/decisions-*.md`、`docs/NO-MODEL-HEURISTIC-DESIGN.zh-CN.md`、`docs/PLAN-*.md`、`docs/PROPOSAL-*.md`、`docs/ENGINE-PERFORMANCE.md`、`docs/PERFORMANCE-DIAGNOSIS-0.15.0.md`、`docs/V015-IMPLEMENTATION-NOTES.md`、`docs/UI-COMPARISON.md`、`docs/SMALL-MODEL-COMPARISON.zh-CN.md`、`docs/LAYA-*.md`

### 历史版本格式兼容性备注

- `SafeJunkCleaner\v3`、`SafeJunkCleaner-v3-seal` 等为内部兼容命名，不代表当前对外版本；偏好配置文件为 `preferences-v4.json`（遇到旧版 `preferences-v3.json` 时迁移为低档预设并提示，原文件保留不删改）。
- 快速清理缓存位置授权保存在状态根下的 `cache-authorizations-v1.dpapi`（DPAPI 保护）；授权变更或范围变化均使旧扫描计划失效。
- `0.13.0`（多组件含本地模型）与 `0.12.0`（纯脚本／快速清理发布格式）构建路线保留在脚本兼容分支中，仅作历史兼容说明，不再用于当前 `0.16.1` 开发与交付。
