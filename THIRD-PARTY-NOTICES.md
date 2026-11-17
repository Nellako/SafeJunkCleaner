# 第三方说明

本项目自有应用程序和源码的授权见 [LICENSE](LICENSE)；该条款不覆盖、也不限制第三方软件自身授予的权利。本文仅整理随附组件与声明信息，不构成独立第三方权属证明或法律合规认证。

## Windows / .NET / PowerShell

运行依赖 Windows、Windows PowerShell 5.1、.NET Framework 的 WPF 与系统文件接口。它们由 Microsoft 提供，适用各自许可条款；应用包不重新分发 Windows、Windows PowerShell 或 .NET Framework。

自 v0.13.0 起的探索组件另随包提供 `.NET 10` 自包含 Windows x64 运行时，其许可与组件清单随包保留；自 v0.14.0 起（含当前 v0.16.1）已移除全部本地大模型及推理运行时。

Segoe MDL2 Assets 等系统字体只在运行时引用，不将字体文件嵌入仓库或应用包；界面字形显示取决于目标系统是否具备相应字体。

## ps2exe 1.0.18

- 用途：可选的 Windows EXE 构建工具。
- 作者／署名：Ingo Karstein；reworked and GUI support by Markus Scholtes。生成的宿主也保留这些上游署名的适用权利。
- 上游：https://github.com/MScholtes/PS2EXE
- 许可证：Microsoft Limited Public License version 1.1（MS-LPL）；以所使用版本及其上游许可为准。
- 官方正文：https://github.com/MScholtes/PS2EXE/blob/master/LICENSE
- 仓库策略：本仓库不内置该工具源码或二进制，不自动安装；维护者需显式准备依赖。
- 随包要求：使用该工具生成的 EXE 包含其宿主实现时，相应第三方部分仍受 MS-LPL 约束并保留上游署名与通知，不能以项目 `LICENSE` 收回第三方权利。Windows 分发包预期随附 [assets/third-party/PS2EXE-LICENSE.txt](assets/third-party/PS2EXE-LICENSE.txt)；实际文件存在性与哈希以交付包清单核验结果为准。

## 应用图标

应用图标恢复自旧版立绘素材，原素材保存为源码仓库中的 `assets/app-icon-source.png`，由 `scripts/generate-icon.ps1` 合成为纯白背景的多尺寸 `assets/app.ico`。2026-11-03，项目权利人确认本人原创或拥有覆盖应用及源码包分发的相应权利；此处仅记录权利人声明，不代表独立第三方权属认证。

图标素材的使用权限受项目 `LICENSE` 及适用权利约束，不因公开展示而获得额外许可。操作图标使用 Windows 自带 Segoe MDL2 Assets 字形，仅在运行时引用系统字体，不嵌入字体文件。

## 当前无模型探索组件（v0.14.0–v0.16.1）

当前 v0.16.1 成品仅随包提供独立探索宿主（`explorer/`）及其运行与本地索引依赖，不包含 GGUF、Qwen、llama.cpp、Python 或任何模型推理组件，也不读取旧模型缓存。应用自有条款不改变以下第三方组件各自的许可权利。

> **依赖与运行时说明**：本可靠性修订将自包含运行时与宿主包固定为 `10.0.15`，替换受已知安全通告影响的 `10.0.14`。具体组件、许可正文、版本和校验哈希，以本次 `explorer/host-component-manifest.json`、项目锁文件及组件清单中的 RID 锁定还原记录为准。SQLite 托管包保持 `10.0.14`、SQLitePCLRaw 保持 `2.1.13`；它们不是旧版 .NET 运行时。

| 组件 | 用途 | 许可与来源 |
|---|---|---|
| .NET 10 自包含 Windows x64 运行时与宿主包 | 运行独立 C# 探索宿主，最终用户无需另装 SDK | Microsoft / .NET Foundation；MIT 及运行时随附 `ThirdPartyNotices`；https://github.com/dotnet/runtime |
| Microsoft.Data.Sqlite / Microsoft.Data.Sqlite.Core | 本地 SQLite 盘点索引（精确版本见组件清单与锁文件） | Microsoft，MIT；https://github.com/dotnet/efcore |
| SQLitePCLRaw（core / bundle_e_sqlite3 / provider / lib.e_sqlite3） | SQLite 原生绑定与引擎（精确版本见组件清单与锁文件） | Eric Sink / SourceGear，Apache-2.0 及随附 SQLite 权利说明；https://github.com/ericsink/SQLitePCL.raw |

运行时、宿主及SQLite相关第三方正文与元数据位于 `explorer/licenses/`。Windows 包还须带 `assets/third-party/PS2EXE-LICENSE.txt`；构建与打包检查不能用顶层项目许可代替这些通知。

## 历史 v0.13.0 探索与本地模型组件（不属于当前成品）

以下仅为历史 v0.13.0 开发试验路线记录，**不属于 v0.14.0–v0.16.1 成品或当前无模型源码包的实际依赖**。

| 历史组件 | 历史用途 | 许可与来源 |
|---|---|---|
| .NET 10 自包含 Windows x64 运行时 | 运行早期探索宿主 | Microsoft / .NET Foundation；MIT；https://github.com/dotnet/runtime |
| Microsoft.Data.Sqlite / SQLitePCLRaw | 早期本地盘点索引 | Microsoft（MIT）/ Eric Sink（Apache-2.0） |
| Qwen2.5-1.5B-Instruct-GGUF Q8_0 | 历史只读辅助试验，不决定删除权限 | Qwen / Alibaba Cloud，Apache-2.0；https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF |
| llama.cpp b12233 Windows CPU | 历史本地 GGUF 纯进程推理试验 | ggml-org，MIT；https://github.com/ggml-org/llama.cpp |
| LLVM OpenMP（随上述历史原生资产携带时） | 历史 CPU 运行组件 | Apache-2.0 WITH LLVM-exception |

历史实验中的 Laya、其他 Qwen 规格、Python、PyTorch、Transformers 环境均不进入当前产品包。

## 未使用的运行时

本应用不依赖 Node.js、Vue、Electron、Tauri 或在主界面内嵌 WebView2；过往讨论过的技术选型不属于当前实际依赖。
