# 第三方说明

本项目自有应用和源码的授权见 LICENSE；该条款不覆盖或限制第三方软件自身授予的权利。

## Windows / .NET / PowerShell

运行依赖 Windows、Windows PowerShell 5.1、.NET Framework 的 WPF 与系统文件接口。它们由 Microsoft 提供，适用各自条款。本仓库不重新分发上述系统运行时。

Segoe MDL2 Assets 等系统字体只在运行时引用，不将字体文件嵌入仓库或应用包。图标字形是否显示取决于目标系统字体。

## ps2exe 1.0.18

- 用途：可选的 Windows EXE 构建工具。
- 作者/署名：Ingo Karstein；reworked and GUI support by Markus Scholtes。生成宿主也保留这些上游署名的适用权利。
- 上游：https://github.com/MScholtes/PS2EXE
- 许可证：Microsoft Limited Public License version 1.1；以所使用版本及其上游许可为准。
- 官方正文：https://github.com/MScholtes/PS2EXE/blob/master/LICENSE
- 本仓库不内置该工具源码或二进制，不自动安装。维护者需显式准备依赖。
- 使用该工具生成的 EXE 包含工具提供的宿主实现时，相应第三方部分仍受其许可约束，保留上游版权/署名与许可通知；不能用项目 LICENSE 将第三方权利收回。Release 随附 `assets/third-party/PS2EXE-LICENSE.txt`。

## 应用图标

应用图标恢复自旧版立绘素材，原素材保存为 `assets/app-icon-source.png`，由 `scripts/generate-icon.ps1` 合成为纯白背景的多尺寸 `assets/app.ico`。2026-11-03，项目权利人确认本人原创或拥有覆盖应用及源码包分发的相应权利；此处记录权利人声明，不代表独立第三方权属认证。

图标素材的使用权限受项目 LICENSE 及适用权利约束，不因公开展示而获得额外许可。操作图标使用 Windows 自带 Segoe MDL2 Assets 字形，仅在运行时引用系统字体，不嵌入字体文件。

## 未使用的运行时

应用不依赖 Node.js、Vue、Electron、Tauri 或 WebView2。讨论过的技术选型不属于本版实际依赖。
