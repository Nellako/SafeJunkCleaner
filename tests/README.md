# 回归与验证套件说明（v0.16.1｜仅源码仓库文档）

> 本文仅保留在源码仓库中供开发与验证人员使用，**不随普通用户 Windows 应用包分发**。文档描述当前 **v0.16.1** 的测试入口、用例组织与安全边界，**不代表本轮修改已完成全部实测或已取得最终通过结论**；实际通过状态以每次绑定固定 `SourceSet` 与 `BuildId` 的原始输出目录为准。

## 环境与目录前提

- **脚本运行环境**：Windows PowerShell 5.1（无 Pester 依赖），所有 `.ps1` 脚本须保留 UTF-8 BOM。C#引擎使用.NET 10；Python仅用于维护者的测试编排（`python -I`），不是产品运行依赖。
- **源目录与云盘限制**：若当前源码仓库位于云同步／重解析点路径（例如网盘挂载目录）下，不适合直接在该目录上运行带路径校验、构建或封存检查的回归；请先导出或复制为**普通本地盘冻结副本**后再执行。
- **输出目录硬规则**：`tests/run_all.ps1` 的 `-OutputDirectory` 必须是**源码仓库父目录下尚不存在的新独立目录**（禁止放在源码树内部，也禁止覆盖已有目录）；未指定时脚本会在源码父目录自动生成 `..\phase1-run_<时间>_<GUID>`。
- **禁止自动清理**：测试框架与各用例**不自动清理任何目录**；所有运行产物、沙箱夹具、失败日志与前后快照均原样保留，供独立审计与复核。

---

## 一、三大验证入口

### 1. PowerShell 产品回归（`tests/run_all.ps1`）

```powershell
# 核心隔离回归（仅覆盖 Core 作用域，不等于完整发布通过）
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Core

# 完整 Release 回归（无 -Case 筛选；遍历 $script:AllCases 全部 37 项声明用例）
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 `
  -Scope Release -ExePath '<本次构建 EXE 绝对路径>' `
  -OutputDirectory '<源码父目录下的新独立目录>' -KeepSandbox
```

- **动态全量声明**：`tests/run_all.ps1` 的 `$script:AllCases` 当前声明 **37 项**用例（含 `Core` 与 `Release` 作用域，含 `N06-local-promotion`、`E01`、`E02`、`F01` 等）。正式 Release 验收必须**不加 `-Case` 过滤**运行完整清单，并绑定当前 `SourceHashes` 与被测 `Exe`。
- **严格通过判据**：任意用例或子进程非零退出、超时、缺失或损坏 JSON、`Assertions <= 0`、`Failed > 0`、`Blocked > 0`、或存在 `CoverageGaps` 均判定整套失败；不得以部分筛选子集或 `KNOWN-RED` 冒充全通过。
- **N06-local-promotion 边界**：`tests/cases/N06-local-promotion.ps1` 恢复并执行旧版（`scripts/test-local-promotion.ps1`）与组件版（`tests/release/Test-ComponentPromotion.ps1`）全部安全合成晋级／封装／打包门禁情景及空仓库拒绝路径。其中所有 Git `commit` 与 `fast-forward` **仅发生在用例新建的 GUID 人工仓库中**，绝不向真实 `develop` 或 `main` 提交或晋级；其内部使用的运行时与桌面材料均为人工合成夹具，不替代真实应用验收。

### 2. C# 探索引擎套件（`tools/explorer/run-engine-suite-safe.py`）

```powershell
python -I .\tools\explorer\run-engine-suite-safe.py `
  --repository '<普通本地仓库副本路径>' `
  --evidence '<已建立的独立空证据目录>'
```

- 离线、无模型运行 `engine-tests/` 下全部 **14 个** C# 测试工程（`SelfTest`、`Space`、`Analysis`、`Analysis.Regression`、`Application`、`Execution.Tests`、`Execution.Verification`、`Host.Tests`、`Storage.Tests`、`ApprovalMaintenance.Tests`、`SimpleCache.Tests`、`ScanQueue.Tests`、`Batch.Tests`、`Progress.Tests`）。
- 运行时将 NuGet 与临时目录隔离到 `--evidence` 下，执行前后记录源码与 `packages.lock.json` 指纹并保留全部夹具。

### 3. 统一本地验证入口（`tests/run_p1p2.py`）

```powershell
python -I .\tests\run_p1p2.py `
  --repository '<普通本地仓库副本路径>' `
  --host-exe '<同批次 sjc-explorer.exe 绝对路径>' `
  --exe '<本次构建 星梦雨垃圾清理器_v0.16.1.exe 绝对路径>' `
  --runtime-cache '<包含 current.json 的运行时缓存目录>' `
  --evidence '<尚不存在的新独立证据目录>'
```

- **单入口全覆盖**：依次执行 Engine 套件（`run-engine-suite-safe.py`）、完整 Product Release（`tests/run_all.ps1 -Scope Release`，**无 `-Case` 过滤**，核对动态声明全集，含 `N06-local-promotion`）、候选打包验证，以及生产发布脚本的原生命令输出/退出码回归（`Test-ExplorerNativeInvocation.ps1`）。
- **Host 与运行时缓存严格绑定**：入口先核验 `--runtime-cache/current.json` 指向的 `host-component-manifest.json`、组件哈希以及 `--host-exe` 二进制 SHA-256 完全一致，再注入 `SJC_TEST_RUNTIME_CACHE`，防止测试实际加载的探索宿主与待测产物不一致。
- **源码不可变校验**：开始前记录 `source-before.json`，结束后核对工作树关键源码／脚本／lock 是否发生未授权变化；任一步失败、有 `CoverageGaps` 或源码变动均返回非零退出码。

---

## 二、用例覆盖总览（当前 `$script:AllCases`）

- **R01–R03**：规则清单、受限浏览器 Profile 发现、规则实例审批与封存篡改拒绝。
- **P01–P03**：路径／祖先与重解析守卫、偏好类型与迁移、预览会话锁／分页索引／独立通道保护。
- **S01–S03**：扫描年龄与模式、同根去重与 WAL 硬拒绝、链接／硬链接与重解析祖先守卫。
- **C01–C05**：人工夹具清理、篡改／变化／身份校验、错误上限、部分处理后协作取消、分页与 BOM CSV 导出。
- **L01 / W01 / V01**：唯一日志与记账、Worker 严格载荷与租约边界、产品版本与计划格式版本隔离。
- **N01–N11**：三档上下文／偏好／计划封存、覆盖变量闸门、白底图标、**N06 完整合成晋级链**、预设与自定义授权、档位真实清理布局、PureCache 白名单 0 小时与 Teams WebView2 归属（隔离 mock）、缓存位置发现绑定与失效撤销、固定 DISM 规格与启动契约（隔离 mock）。
- **G01–G04**：主窗口 WPF 自检、后台分页与导出、档位界面与严格载荷、发现／维护弹窗取消与状态。
- **E01–E02 / F01**：无模型深度探索工作台（ContractVersion=3）、建议与两步复核批准边界、全盘批次持久化／65 历史／资源整理／诊断隐私／逐项记录分页／按钮与过期响应处理。
- **W02 / X01**：`Main.ps1` 与编译后 `EXE` 的独立进程 SelfTest、文件版本、退出码与图标资源校验。

---

## 三、独立原生 WPF 补测与 Mock 测试的真实区别

`tests/` 根目录下另包含一批面向特定交互与回归场景的独立验证脚本（例如 `Test-ExplorerTaskButtons.ps1`、`Test-ExplorerResources.ps1`、`Test-ExplorerResponseState.ps1`、`Test-ExplorerQuotaRecovery.ps1`、`Test-ExplorerBatch.ps1`、`Test-ExplorerBatchBoundaries.ps1`、`Test-ExplorerBatchPersistence.ps1`、`Test-ExplorerMaintenanceIntegration.ps1`）。使用时须严格区分两类证明边界：

1. **Mock / 假 Host / 隔离替身测试**（如 `tests/lib/ExplorerFakeHost.ps1`、`N09`/`N11` 隔离 mock、`TestMode` 下的受控响应）：
   - 用于确定性复现超时、延迟响应、协议字段缺失、拒绝路径、进程守卫与状态机转换。
   - **不能**用来宣称真实 `Explorer.Host` 行为正常，也**不能**用内存 `Hashtable` 替身代替实际桥接返回对象（如 `Generic.Dictionary`）的回归。
2. **原生 WPF 真实窗口 + 同包 Host 测试**（如真实下拉展开／关闭与 Dispatcher 消息泵、`Escape` 键盘事件、最小允许窗口尺寸布局几何与可见高度检查、真实主机清单回放）：
   - 用于验证真实 WPF 控件事件顺序、布局可读性与跨进程桥接契约。
   - **仍不等于**人工手操作鼠标键盘全流程覆盖，也**不等于**多 DPI／多显示器兼容认证。

---

## 四、安全边界与未实测范围

- **GUID 沙箱与所有权约束**：文件与目录测试仅操作本次测试自行创建、带所有权标记的 GUID 人工沙箱，且不跟随重解析点；不触及真实用户目录或既有用户扫描库存，不删除归属不明的历史目录。
- **无破坏性外部动作**：本套件不执行真实系统缓存清理、不清空真实回收站、不触发真实 UAC 提权或真实 DISM、不向真实 `develop`/`main` 提交或晋级、不修改系统安全防护设置。
- **未由自动套件认证的范围**：真实用户环境清理效果、真实非空回收站清空、真实 UAC／DISM 执行、完整多 DPI／多显示器矩阵、屏幕阅读器无障碍支持、全部第三方软件版本布局、大规模真实文件内容分析，以及文件系统检查至处理之间的残余 TOCTOU 竞态，均不得以“测试全绿”宣称已消除或已认证。
