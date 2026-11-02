# 规则范围与来源

规则定义在src/Rules.ps1。数量会随本机受支持浏览器Profile发现而变化，不以规则数量代表清理效果。

| 范围 | 策略 |
|---|---|
| 当前用户/Windows临时文件 | 精确根、不同最小保留时间，排除WAL/SHM和受保护内容，不提权 |
| Chrome/Edge/Brave | 固定数据根下一层Default或Profile N；只处理Cache/Code Cache/GPUCache，不清整个用户数据目录 |
| VS Code | 默认Roaming下Code的精确缓存子根，要求相关进程关闭 |
| Gradle | 默认用户.gradle/caches精确根，保守保留时间和进程前置；不采用任意GRADLE_USER_HOME |
| 图形/Steam缓存 | 仅内置精确根；可引发重新编译或加载 |
| 崩溃/错误报告 | 删除会失去历史诊断信息，非用户文档，但仍需自行选择 |
| Explorer图标/缩略图 | 限定文件名模式，要求相关进程关闭；可能因此保守跳过 |

不提供Firefox数据库事务日志、Office待同步文档缓存、Maven混合仓库、网页离线数据的通用递归删除。关闭应用和增加年龄不能把业务数据变成安全垃圾。

## 权威参考

- [Chromium用户数据与Profile目录](https://chromium.googlesource.com/chromium/src/+/HEAD/docs/user_data_dir.md)
- [Gradle目录布局](https://docs.gradle.org/current/userguide/directory_layout.html)
- [VS Code用户数据位置](https://code.visualstudio.com/docs/setup/uninstall)
- [SQLite WAL持久状态](https://sqlite.org/wal.html)
- [Maven本地仓库的混合用途](https://maven.apache.org/repositories/local.html)
- [Office文档缓存设置](https://support.microsoft.com/en-us/office/collab-files/office-document-cache-settings)

目录来源说明不等于对所有版本删除语义的保证。便携版、自定义路径、其他账户和未支持Profile不自动扩大可信范围。
