# 构建与验证

本文是技术说明，不扩大 LICENSE 的源码授权范围。

## 结构

- `src/Version.ps1` 从根目录 `version.json` 读取产品版本；构建时将元信息嵌入单文件，不依赖外部版本文件。
- `Rules.ps1` 定义规则，`Core.ps1` 执行安全检查/扫描/清理/预览，`Discovery.ps1` 只读发现缓存位置并管理授权（v0.12.0 新增），`Maintenance.ps1` 定义固定的系统维护启动规格（v0.12.0 新增），`Worker.ps1` 定义严格后台协议，`Gui.ps1` 是WPF界面，`Main.ps1` 是入口。
- 单文件构建按 `Main`、`Version`、`Rules`、`Core`、`Discovery`、`Maintenance`、`Worker`、`Gui` 的顺序合并，共 8 个 src 模块（以 `scripts/build.ps1` 的源文件清单为准）。
- 模块导入不启动扫描。耗时预览与导出在后台runspace，清理任务在独立进程。

## 构建

需要Windows PowerShell 5.1和系统.NET组件。脚本使用UTF-8 BOM。

```powershell
powershell.exe -NoProfile -File .\scripts\build.ps1 -ScriptOnly
```

生成单文件脚本无需第三方打包工具。EXE构建需要显式准备 `ps2exe 1.0.18`；构建脚本通过模块发现查找该版本，也可指定：

```powershell
powershell.exe -NoProfile -File .\scripts\build.ps1 -Ps2ExeModulePath '<ps2exe.psd1的实际路径>'
```

脚本不自动安装依赖。每次输出新的 `artifacts/builds/<时间_GUID>/`，包括单文件、可选EXE、相对源路径和SHA-256构建清单。EXE文件版本来自version.json，不能只重命名程序冒充版本变化。

图标位于assets/app.ico，原立绘素材保存在assets/app-icon-source.png。generate-icon.ps1将透明区域合成为纯白方形背景，保留比例和主体，生成16/24/32/48/64/128/256尺寸；默认拒绝覆盖，替换现有文件需显式-Force。可用-OutputPath和-PreviewDirectory生成独立候选与预览。

构建清单包含assets/app.ico和build.ps1自身的SHA-256。单文件脚本嵌入SjcEmbeddedIconBase64供WPF窗口使用，EXE资源使用相同ICO；无需分发独立图标文件才能显示窗口图标。不要通过清理系统图标缓存来代替新产物验证。

## 回归

```powershell
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Core
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Release -ExePath '<本次构建EXE路径>'
```

- Core只验证引擎，不等于发布通过。
- Release还要求真实GUI自检、后台预览、Main和EXE独立进程自测。
- 任意非零退出、缺失JSON、零断言、失败项或覆盖缺口均失败，不接受KNOWN-RED当全绿。
- 用例只处理本实现自建、有所有权标记的GUID人工沙箱。不要替换成真实缓存或运行旧版固定目录测试。
- 默认证据写artifacts/verification；结果可能包含机器名与私有路径，只用于本地验证，不直接上传。
- SelfTest和失败路径会创建本地状态、人工沙箱、通道与日志；部分证据保留，不递归清理归属不明的历史目录。

可用 `scripts/gui-isolated.ps1` 创建人工450候选界面验收。`-Show`展示实际窗口；不带Show可渲染证据。TestMode不允许生产Worker。性能脚本仅处理人工数据，结果不等于真实应用吞吐保证。

## 版本与状态格式

公开产品版本由version.json统一控制；当前 develop 目标为0.12.0开发候选，不代表正式发布。任务还带独立planSchemaVersion。旧版本所有权标记、旧扫描计划或格式缺失均拒绝直接执行，要求重新扫描，不将旧计划自动迁移成删除授权。

`SafeJunkCleaner\v3`、`SafeJunkCleaner-v3-seal`和原生类型命名中的v3是内部兼容标识，不是对外版本。三档设置写入 `preferences-v4.json`；旧 `preferences-v3.json` 保留，迁移时回到低档并提示重新确认范围，不把旧 Deep 静默映射为范围更大的 High。高级自定义只在本会话显式启用，不在下次启动自动开启。这些内部格式标识不决定对外产品版本。

缓存位置授权保存在状态根下的 `cache-authorizations-v1.dpapi`（DPAPI 保护）。每条授权绑定展示时的来源、精确路径、目录身份和模板；保存授权、撤销授权或发现范围变化都会使当前旧计划失效，须重新扫描。该文件不是对同用户恶意程序的隔离边界。

## v0.12.0 候选的验证状态

- 候选范围见 [CANDIDATE-0.12.0](CANDIDATE-0.12.0.md)，待验证项和留待填写的记录表见 [VALIDATION-0.12.0](VALIDATION-0.12.0.md)。
- 初次 Core 基线的 9 个失败用例已按 v0.12.0 契约迁移并补专项；修订后完整 Core 28／28、1106 断言及完整 Release 34／34、1305 断言通过。固定提交后仍须重新捕获输入、构建、完整 Release 和真实桌面验收，不能把工作树预验收冒充固定提交证据。
- [v0.11.0 验收记录](VALIDATION-0.11.0.md)中的数字只适用于当时的构建，不能用作 v0.12.0 的证据。当前结果与未测范围见本版验证报告，最终产物以交付清单为准。
- 真实缓存删除、真实回收站清空、UAC 或 DISM 不在自动回归执行范围内，完整性能与多 DPI／多显示器矩阵也未验证。人工沙箱程序化检查不等于真实桌面观察。

## 本地发布门禁

`publish.ps1 -BuildDirectory ... -VerificationDirectory ... -GuiAcceptancePath ...` 检查完整用例、实际窗口证据及当前源码/EXE指纹，输出新的releases目录。GUI证据要求实际窗口、规则选择、候选翻页保留恢复、无生产删除、白底应用图标、紧凑布局、档位确认、单窗口清理流程、三档即时应用和高级自定义默认关闭检查，并绑定GuiSourceSHA256及IconSHA256。不能只创建一个JSON声称通过；没有实际观察的项必须阻塞发布。

**`scripts/publish.ps1` 与晋级工具共同要求 12 项桌面检查**，其中沿用的 10 项为：`DesktopWindowObserved`、`RuleSelectionObserved`、`CandidatePagingAndKeepRestore`、`NoProductionDeletion`、`WhiteBackgroundIconObserved`、`CompactLayoutObserved`、`CleaningProfileConfirmationObserved`、`SingleWindowFlowObserved`、`ThreePresetImmediateApplyObserved`、`AdvancedCustomOffByDefaultObserved`。

v0.12.0 新增 2 项：`DiscoveryAuthorizationCancelObserved`（取消“发现缓存位置…”窗口不改变授权与扫描）和 `MaintenanceCancelObserved`（关闭尚未启动的“系统维护…”说明窗口不触发 UAC 或 DISM）。两侧脚本已要求全部 12 项，并加入缺项阻塞的合成自测；不能用手写 JSON 代替真实观察。

`scripts/local-promotion-common.ps1` 在 manifest、构建前输入和回归来源清单中均显式要求 8 个 src 模块（包括 `Discovery.ps1`、`Maintenance.ps1`），并要求全部 12 项 GUI 检查。原有固定提交全仓快照与 runner AST 自动枚举机制继续保留；21 项数组只是最低基线，不会漏过新声明用例。工具自测使用合成证据，不是产品验收。

公开包只复制明确文档和相对路径清单，输出脱敏的通过摘要，不带本地日志、完整原始suite结果或截图。脚本仅整理本地包，不上传GitHub。上传、创建远程仓库、提交或推送必须另行执行并确认。

`package-local.ps1` 可在已有合格 publish 目录基础上生成最终 Windows ZIP、固定提交源码 ZIP、中文版说明、脱敏摘要、总清单与 `SHA256SUMS`。它要求干净的固定提交，并逐项校验 release 文件、构建来源、版本及 ZIP 内容；拒绝覆盖已有输出。它不会自动更新 `LATEST.json` 或晋级 main，更不会代替完整 Release 与实际桌面验收。

```powershell
powershell.exe -NoProfile -File .\scripts\package-local.ps1 `
  -SourceRepository '<develop 绝对路径>' -ExpectedSourceHead '<完整提交 ID>' `
  -ReleaseDirectory '<publish 产物目录>' -OutputDirectory '<父目录已存在的新交付目录>'
```

## 两个本地仓库的发布晋级

`develop`负责开发，`main`负责验收后的发布版本；父汇总目录本身不是Git仓库。日常在ZCode直接打开develop查看Git状态；尚未核实ZCode在父目录的嵌套仓库入口行为，不将项目脚本称为ZCode自身功能修复。

本地晋级工具的默认预检、固定提交与证据绑定、显式快进及失败处理见[本地晋级说明](LOCAL-PROMOTION.md)。维护者审阅并明确授权提交、固定输入和全部验收后，才可执行晋级；工具本身不会提交。未提交的工作树即使回归通过，也不能直接当成固定提交发布。
