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

`assets/app.ico` 是本项目的简单几何图形，生成源为 `scripts/generate-icon.ps1`。没有嵌入旧立绘、第三方图片或字体。旧开发目录中的素材未纳入公开仓库。

## 未使用的运行时

应用不依赖 Node.js、Vue、Electron、Tauri 或 WebView2。讨论过的技术选型不属于本版实际依赖。
