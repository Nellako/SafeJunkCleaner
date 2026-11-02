# 构建与验证

本文是技术说明，不扩大 LICENSE 的源码授权范围。

## 结构

- `src/Version.ps1` 从根目录 `version.json` 读取产品版本；构建时将元信息嵌入单文件，不依赖外部版本文件。
- `Rules.ps1` 定义规则，`Core.ps1` 执行安全检查/扫描/清理/预览，`Worker.ps1` 定义严格后台协议，`Gui.ps1` 是WPF界面，`Main.ps1` 是入口。
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

图标位于assets/app.ico；如需重新生成，先检查现有文件并另行决定替换，再使用generate-icon.ps1。默认拒绝覆盖。

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

公开产品版本由version.json统一控制；任务还带独立planSchemaVersion。旧版本所有权标记、旧扫描计划或格式缺失均拒绝直接执行，要求重新扫描，不将旧计划自动迁移成删除授权。

`SafeJunkCleaner\v3`、`preferences-v3.json`、`SafeJunkCleaner-v3-seal`和原生类型命名中的v3是内部兼容标识，不是对外版本。保持用途标识以避免误处理既有私有数据；它们不改变0.9.0公开版本。

## 本地发布门禁

`publish.ps1 -BuildDirectory ... -VerificationDirectory ... -GuiAcceptancePath ...` 检查完整用例、实际窗口证据及当前源码/EXE指纹，输出新的releases目录。GUI证据要求实际窗口、规则选择、候选翻页保留恢复和无生产删除检查，不能只创建一个JSON声称通过。

公开包只复制明确文档和相对路径清单，输出脱敏的通过摘要，不带本地日志、完整原始suite结果或截图。脚本仅整理本地包，不上传GitHub。上传、创建远程仓库、提交或推送必须另行执行并确认。
