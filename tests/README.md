# 回归测试

Windows PowerShell 5.1，无Pester依赖，所有.ps1使用UTF-8 BOM。测试目录仅保留当前套件，不含历史固定目录清理测试。

```powershell
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Core
powershell.exe -NoProfile -STA -File .\tests\run_all.ps1 -Scope Release -ExePath '<本次EXE>'
```

默认Core。支持 `-OutputDirectory <新目录>`、`-Case id1,id2`、`-TimeoutSeconds`、`-KeepSandbox`。Release缺EXE或用例时失败，不静默跳过。

## 覆盖

- R01–R03：规则清单、受限Profile、审批与封存篡改。
- P01–P03：路径/祖先、偏好类型、预览会话锁与索引、取消导出、内部通道名。
- S01–S03：年龄/模式/同根枚举/去重/链接和硬链接。
- C01–C05：真实人工文件处理、保留、只读/变化、错误上限、实际部分删除后取消、完整分页和CSV。
- L01/W01：唯一日志、失败记账、严格Worker载荷与任务租约/生命周期。
- G01/G02：WPF控件、真实450候选、后台分页导出、保留恢复、失败/取消恢复。
- W02/X01：入口与EXE独立进程SelfTest、版本、退出码和人工目标存活。
- V01：产品版本与格式版本分离，旧任务/旧计划拒绝，新任务可用。

任何非零退出、超时、缺失/损坏JSON、0断言、Failed或CoverageGaps均不算通过。suite摘要包含具体用例结果和源文件哈希，不能只用exit0替代覆盖检查。

## 安全及副作用

只处理实现自身创建、有进程登记与所有权标记的GUID人工沙箱。不扫描真实缓存，不清空真实回收站。目录清理不跟随重解析点，不删除未登记的旧沙箱。

模块导入不启动任务。部分Worker失败测试会在本地生产Logs写失败审计，New-SjcContext可能创建状态根；SelfTest会留下自身人工沙箱、任务通道及日志。详细证据含路径，仅写入忽略的artifacts目录，不直接公开。

真实用户缓存、真实回收站清空、完整多DPI/多显示器、屏幕阅读器和所有第三方应用布局未由本套件认证；文件名TOCTOU不能用测试全绿证明消除。
