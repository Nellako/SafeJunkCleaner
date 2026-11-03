# 独立本地仓库：develop 单向快进 main

本文仅定义本地工具，不表示当前改动已提交、已验收或已晋级。脚本面向 Windows PowerShell 5.1、Git for Windows、两个独立且非浅克隆的本地普通仓库，不使用 remote、push、commit、reset 或文件复制覆盖来晋级。

## 工作区入口

当前 `SafeJunkCleaner-repositories` 父目录不是 Git 仓库，`develop/.git`、`main/.git` 才是两个独立仓库。需要查看开发变更时直接打开 `develop`，不要把“父目录未识别 Git”当作仓库丢失。ZCode 产品是否支持在父工作区自动发现嵌套仓库尚未核验；此工具没有修改或修复 ZCode 的仓库发现行为。

## 工具与门禁

- `scripts/promote-local.ps1`：默认只读预检；仅自建 GUID 临时裸仓库可 fetch 对象。真实源与目标不 fetch，不写 FETCH_HEAD、ref、索引或工作树。临时目录使用后清理。
- `scripts/seal-local-promotion.ps1`：捕获构建前输入，或把已有完整验收材料封装成固定提交的晋级证据。只写指定的新证据文件，不修改 Git。
- `scripts/local-promotion-common.ps1`：独立辅助实现，不调用待验收仓库的脚本，不借 publish 的复制动作完成晋级。
- `scripts/test-local-promotion.ps1`：独立测试，提交和快进只发生在其自行创建的 GUID 临时仓库；合成 EXE/GUI 记录不是产品验收。

预检要求绝对本地盘路径、精确仓库根、源当前分支 `develop`、目标当前分支 `main`、正常完整历史、干净工作树和索引，拒绝未跟踪文件、未完成 merge/rebase/cherry-pick 等操作、锁文件、替换对象、grafts、alternates、linked worktree、路径重定向、symlink/submodule 索引以及 assume-unchanged/skip-worktree。拒绝相同目录或目录嵌套。源可保留 ignored 构建产物；目标 ignored 文件只有与 incoming tree 同名、为其父路径或子路径时才阻塞，incoming 文件撞 ignored 目录也阻塞，无关 `.zcode` 元数据或 ignored 构建文件可保留，工具不删除它们。执行前再次检查冲突，Git `--no-overwrite-ignore` 作为最后防线。

Git identity/config/trace 环境变量覆盖被拒绝，避免 `GIT_DIR` 等重定向身份或更改传输/行为；允许与本次仓库识别无关且不参与非交互快进的 `GIT_EDITOR`、`GIT_SEQUENCE_EDITOR`、`GIT_PAGER`、`GIT_TERMINAL_PROMPT`、`GIT_ASKPASS`、`GIT_MERGE_AUTOEDIT`。未识别的 `GIT_*` 仍保守停止，不修改系统环境设置。

云盘有限支持：只读调用 Windows `FileAttributeTagInfo` 读取重解析标签，仅允许精确的 `IO_REPARSE_TAG_CLOUD` / `CLOUD_1..F`（非路径替身）标签，不把所有 ReparsePoint 一律当 junction。当前真实 develop 的标签为 `0x9000601a`，已只读确认可识别；junction、symlink 和未知标签仍拒绝。GUID 临时测试覆盖标签白名单与真实自建 junction 拒绝，但不代表所有云盘客户端/在线状态/同步竞态均获兼容认证，不修改属性或关闭同步。中文和空格仓库路径使用 UTF-8 Git 输出解码。

源和目标 HEAD 相同返回 `NoPromotionNeeded`，不要求重复验收，也不写真实仓库，但仍要求仓库状态安全。HEAD 不同时，必须有有效封装证据，且目标 HEAD 是固定源 HEAD 的祖先；分叉、目标领先、缺少历史或无证据均停止。

## 固定提交与证据流程

先由维护者另行审阅、提交开发改动，使 `develop` 干净。本工具**不会替维护者提交**。源码、测试或本工具自身仍有未提交修改时，捕获/封装/晋级均为 blocked，不允许把工作树绑定到旧 HEAD。本文没有授权实际提交或真实 main 晋级。

以下仅为未来人工使用的示例。路径用实际的绝对路径替换，示例不自动执行 Git 提交。证据目录应在源仓库外预先建立，保存私有日志与截图，不上传。

```powershell
$dev = 'E:\云端\90_软件驱动与编程项目\编程项目\90_已交付\SafeJunkCleaner-repositories\develop'
$main = 'E:\云端\90_软件驱动与编程项目\编程项目\90_已交付\SafeJunkCleaner-repositories\main'
$acceptedHead = (git -C $dev rev-parse HEAD).Trim()
$targetHead = (git -C $main rev-parse HEAD).Trim()
$private = 'D:\private-verification\this-acceptance' # 已人工建立的新目录

# 构建前全仓已跟踪文件指纹；必须先捕获再构建
& "$dev\scripts\seal-local-promotion.ps1" -SourceRepository $dev `
  -ExpectedSourceHead $acceptedHead -CaptureBuildInputs `
  -OutputPath "$private\build-inputs.json"

# 之后按 DEVELOPMENT.md 构建 EXE、执行完整 Release 回归并做真实桌面验收。
# 使用本次真实文件的绝对路径，不要复制下列占位字符串直接运行。
& "$dev\scripts\seal-local-promotion.ps1" -SourceRepository $dev `
  -ExpectedSourceHead $acceptedHead `
  -BuildInputsPath "$private\build-inputs.json" `
  -BuildManifestPath '<本次 build-manifest.json 绝对路径>' `
  -SummaryPath '<完整 Release summary.json 绝对路径>' `
  -GuiAcceptancePath '<人工桌面验收 JSON 绝对路径>' `
  -OutputPath "$private\promotion.json"

# 默认预检：不会对真实 main 获取对象或更新 HEAD
& "$dev\scripts\promote-local.ps1" -SourceRepository $dev -TargetRepository $main `
  -EvidencePath "$private\promotion.json" `
  -ExpectedSourceHead $acceptedHead -ExpectedTargetHead $targetHead

# 仅在未来另行批准真实晋级时使用；仍会显示 High 级确认
& "$dev\scripts\promote-local.ps1" -SourceRepository $dev -TargetRepository $main `
  -EvidencePath "$private\promotion.json" `
  -ExpectedSourceHead $acceptedHead -ExpectedTargetHead $targetHead -Execute
```

执行必须显式 `-Execute` 且两个期望值均为完整 40 位小写提交 ID；`-WhatIf` 预检但不晋级，`-Confirm:$false` 仅供获得授权的自动化（测试在自有沙箱中使用）。输出 `Ready` 不等于已经晋级；只有执行后的 HEAD/干净状态核对成功才返回 `FastForwarded`。

### 验收证据契约

封装不接受只有 `Status: Passed` 的 JSON。必须逐项满足以下要求。

1. 构建前捕获具有固定 SourcePath、SourceCommit、时间戳、全仓输入 SHA-256，当前所有已跟踪文件字节与固定提交 blob 完全相同（包括换行符）；封装期间再次检查 HEAD、工作树和输入。Git 自动换行或过滤后字节不同也会阻塞，不自动重写或 normalize。
2. 构建 manifest 匹配 `version.json`，包含六个 src 模块、version.json、build.ps1 和 assets/app.ico 的真实输入指纹，ps2exe 1.0.18、脚本与唯一 EXE 的产物名/长度/哈希。
3. 完整 Release summary：独立回归 Suite 标识，零失败/阻塞/缺口/门禁错误，正确总数、断言数；每个用例必须 Passed、正断言、非超时、退出码 0，并核对原始 result JSON 和保留 stdout/stderr。对固定提交 runner 的 `$script:AllCases` 做 AST 只读解析，将全部声明项作为必需用例，新用例不可被旧清单漏掉；旧 21 项作为最低不可删除基线。声明结构改变时保守停止，需更新适配器。summary.SourceHashes 必须覆盖源码、版本、build.ps1 及全部已跟踪 tests/*.ps1，EXE 哈希必须与构建产物一致。
4. GUI 记录除 `Status`、`GuiSourceSHA256`、`IconSHA256`、非空 `EvidenceFiles`（绝对本地文件路径）外，还要求可解析的 ISO 8601 `AcceptedUtc`。`Checks` 内下列各 Name 恰有一个布尔 `Passed: true`，所有检查都须通过：`DesktopWindowObserved`、`RuleSelectionObserved`、`CandidatePagingAndKeepRestore`、`NoProductionDeletion`、`WhiteBackgroundIconObserved`、`CompactLayoutObserved`、`CleaningProfileConfirmationObserved`。没有实际观察则记录未通过/blocked，不能制造通过材料。
5. 捕获在构建前，回归和 GUI 观察在构建后；回归完成不早于开始。默认所有时间在过去 72 小时内，最多可显式设置 `-MaxEvidenceAgeHours 168`，未来时间超过 5 分钟拒绝。封装到期时间从最早原始证据计算，重封装不能延长旧证据寿命。预检/执行会重新解析原始材料，校验封装文件集合、所有证据和产物哈希；原始材料必须保留原路径。

已有验收材料若同时具有构建前捕获、当前完整字段、原始结果/日志/桌面证据和一致指纹，可以直接使用封装步骤。旧 manifest 缺少 build.ps1/图标、缺少构建前快照、GUI 无可靠 AcceptedUtc 或缺新增观察，均不补写虚假的历史记录，应在提交固定后重新构建并验收。

## 执行与失败边界

确认之后二次复核身份、分支、期望 HEAD、干净状态、证据哈希及祖先关系。再从本次隔离对象库获取**固定对象**至目标（无 remote、不写 FETCH_HEAD、不更新旁支），获取之后再复核，最后以 `merge --ff-only --no-overwrite-ignore --no-autostash` 更新 main。禁用本次 merge 的 hooks 和子模块递归，不执行自定义合并。工具不会创建合并提交，不 push，不复制文件覆盖目标，也不以 reset 自动回滚。

失败可能已向目标写入对象，或者 merge 已成功而后置检查发现竞态；异常只报告停止，**不声称回滚**。人工检查 HEAD、索引、工作树及证据后再决定下一步。不要并发编辑、提交或运行另一个 Git 操作。该工具提供多次一致性检查，不是跨进程事务锁，无法隔离同权限恶意程序、瞬时变更后恢复、磁盘故障或最后一瞬间的文件系统竞态。来源为本地可信维护者材料，哈希绑定防止误用和意外篡改，不是第三方签名认证，也无法从 JSON 自动证明人确实观察过真实 GUI。

## 独立工具测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-local-promotion.ps1
# 可加 -KeepSandbox 保留本次 GUID 测试仓库和合成证据
```

测试在自有 GUID 临时目录中初始化、提交和快进，覆盖相同 HEAD、正常快进、分叉、缺失/过期/篡改证据、源和目标期望 HEAD 变化、脏工作树/暂存区、ignored 文件、未完成操作、路径重叠、未提交源码、漏新增回归/GUI 检查和 WhatIf，并比较只读预检前后目标 `.git` 的文件内容。测试不构建真实应用，不代替产品 Release 回归、真实 GUI 观察或 `code-verifier` 的独立验收。
