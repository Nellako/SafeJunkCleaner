# 深度探索接口与安全契约

## v0.14.0起的无模型协议／Host ContractVersion=3（v0.16.1沿用）

日期：2026-11-11。无模型启发式路线按已批准方案实施；状态不等于已验收。

- JSONL envelope仍ProtocolVersion1、输入32768字节／响应262144字节、分页上限64。新HostContract3，Health显式ModelMode=Absent、AlgorithmMode=Heuristic、HeuristicExploration=true，兼容Model布尔字段均false，不初始化／读取旧cache。
- Analyze `{TargetId:null|string,ExpectedEvidenceRevision,ExplorationMode:Scope|Selected}`：Scope只能null，Selected必须可信索引ID，不接受UseModel或Paths。共用全局预算与精确探针。GetAnalysisProgress返回AnalysisId／Status／Reason／Usage／HasResult／ExplorationMode／Progress（VisitedTargets、QueuedTargets、CompletedActions、CurrentTargetId、Reason、HasMore）。HasResult仅在结果／展示资格已完整发布时为true，Usage只记录实际调查用量，无结果的失败／超时也可带诊断计数，界面不能据Usage推断可查询建议。CancelAnalysis只收AnalysisId，终态无自动执行。
- QuerySpace `{AfterCursor:null|string,PageSize}`返回递归已观察量排行、未知分配、硬链接、覆盖、Revision与Semantics；仅稳定盘点查询。目录彼此重叠不能相加。
- QuerySuggestions／QuerySuggestionFiles的AfterId／NextAfterId是opaque HMAC游标，绑定task／revision／analysis／sort／suggestion上下文，不再是GUID／对象ID。建议按可复核优先、收益降序和稳定ID，TargetPath仅由可信库存映射；稳定游标保证不重不漏。
- 优先级、名称、大小与年龄不构成处理许可；目标动作只做一次，反例优先、无新证据停止、unknown不可批准。启发式正常完成为Complete，不使用ModelUnavailable冒充运行成功。
- 批量建议按完整候选集去重；不能减去重叠成员后冒充原结构证据。Prepare／Confirm／Execute仍只正向ID、准确成员与DisplayHash，分析代／观测变化或Invalidate使旧批准拒绝。通用重复包仅展示，不自动处理。
- 真实用户文件清理、UAC／DISM和回收站清空不在自动回归范围。成功回收可在独立验证中只对当轮登记人工文件执行，须核对系统回收项，不把替身或源文件消失当回收证明。回收失败不永久删除，未知不重放。

### v0.16.1可靠性修订

- 历史执行汇总以认证seal全集为准：最终ObjectId集合、Recycled终态和逐项逻辑大小均吻合且执行claim已存在才可报告Completed；仅成功前缀不能完成。空ledger且无claim为NotStarted；已消耗claim但无ledger为PartialOrInterrupted，不能重放旧批准。查询状态不重新授予执行资格。
- 库存启动补 `task_objects` 只是一项性能索引修复。先预检物理空间和状态预算，不足则延后、允许读取原有记录；`GetStorageInfo`与`ConfigureStorageBudget`附加可选布尔 `IndexRepairPending`。显式确认预算调整后重试补索引，仍不改变表中观测事实或新盘点写入限制。
- 后台复核Prepare、用户确认和实际执行保持分离。取消请求的回执不等于后台终态；界面丢弃迟到旧草稿时仍需结束其后台准备，不能让旧作业挡住新准备，也不能因迟到结果自动批准或执行。

### 0.15 体验修订：未覆盖对象不能使整份快照失效

库存可保留元数据失败的Unknown/NotCovered原始路径用于解释覆盖缺口；它不是可分析或执行的目标。适配器只对无身份/大小/时间/属性/链接/枚举证明且原因严格为`MetadataUnavailable:InvalidOperationException`的非根覆盖行容忍不支持路径，保留父子/范围/唯一性校验和祖先Partial，绝不规范化为新路径或打开它。普通文件、目录与根仍严格Canonical；不得把所有NotCovered路径视作可信文件。对应回归在Application.Tests中包含正反例和旧缺陷回置。

分析失败Reason仅向界面保留白名单内部错误码，不能直接转发可能带私人路径的异常Message；Timing记录失败前实际耗时。通道、分页上限、schema和批准集合格式不变。

### 批次持久化增量（库存schema v4）

- ProtocolVersion1／Host ContractVersion3保持，能力通过Health.Operations显式声明。新增CreateBatch、ListBatches、GetBatch、ContinueBatch、StartBatchEntry、PauseBatch、CancelBatch、StopBatch，外层TaskId均null；Start的TaskId位于Result。
- CreateBatch `{BatchId,Roots}`先保存1–26个有序、去重、受限本地根快照和目录/卷身份，不启动Worker；GUI仅从开始时可用固定磁盘取得生产范围。ListBatches `{AfterBatchId:null|Guid,PageSize:1..64}`分页；GetBatch `{BatchId}`只读，不授意图。
- ContinueBatch `{BatchId,ExpectedRevision,Confirmed:true}`是显式恢复入口；StartBatchEntry `{BatchId,EntryIndex,ExpectedRevision}`仅在本进程Create/Continue后按首个Pending/Paused顺序执行。重复/过期请求拒绝，不自动重放。每盘仍独立TaskId/Revision和批准范围。
- Start将tasks、根对象和条目绑定同事务提交，再启动单Worker。Paused恢复沿用同TaskId整代重建；旧Resume不得绕过批次入口。所有根初始Failed时直接终态，不占运行意图。
- PauseBatch／CancelBatch／StopBatch均只收BatchId和ExpectedRevision，由Host一次控制当前任务并停止后续推进；GUI不另发重复单任务控制。控制撤销不以新批次准入预留阻止，真实I/O失败仍明确报告。
- 重启将活动记录标Interrupted、盘点任务Paused，不自动开扫。磁盘中的Running不是授权；Get/List不会恢复进程内意图。历史查看也不继承分析、草稿、批准或执行资格。
- 释放单盘任务同事务保留Released条目及原TaskId，不重新变Pending。schema v1/v2/v3事务升级v4，旧任务不补造批次。旧Host不能打开v4；不混跑同一库存。整理/备份逐行校验覆盖tasks、objects、batches、batch_entries。

下文为历史0.13／模型设计，授权和执行安全原则继续适用，模型部署与动作状态部分被本节取代，不当作当前实现。

# 历史：深度探索接口与安全契约 v1（实施设计）

日期：2026-11-10。状态：基于已批准计划的接口设计，尚未实现；不得作为已通过验证的说明。模型前置门结果可能改变部署方式，不改变以下授权原则。

## 1. 独立任务与状态

现有快速清理保持原 Worker 和计划格式。探索使用独立任务类型、协议版本、索引和正向批准计划；旧快速清理计划不能作为探索授权，探索建议不能导入旧 Clean 的全部未排除语义。

建议任务阶段：Created → Inventory → Exploring → Ready/Partial/Paused/Cancelled/Failed → ApprovalPrepared → Approved → Executing → Completed/PartiallyCompleted/Cancelled/Failed。只读盘点可恢复；批准执行不可在崩溃后自动重放。模型失败与盘点失败分开记录。

每项持久化状态包含任务 ID、协议版本、创建/更新时间、范围版本和模型/探测器/策略版本。任务目录私有；默认历史任务条数不限制（MaxTasks=0），仍保留索引状态字节配额和单任务对象预算。释放须显式确认并检查任务锁，不自动淘汰记录、不删除正在使用的任务。全盘扫描由界面串行创建各固定盘的独立任务，不合成跨盘范围、不自动分析或批准执行。

## 2. 本地通信

- 进程标准输入输出或 ACL 受限命名管道，启动只绑定本地受控端点，不开 HTTP 端口。
- 每条消息含 ProtocolVersion、RequestId、TaskId、Operation、Payload；消息设大小限制，响应关联 RequestId，诊断走独立日志而非污染 JSON 通道。
- 盘点结果按页查询，进度是小消息；不发送完整目录树作为单条响应。
- 初始只读范围由界面用户选择后建立，执行端不能通过命令行/模型输出任意添加路径。
- 操作集合：Health、CreateInventory、GetProgress、QueryGroups、QueryEvidence、Pause、Resume、Cancel、PrepareApproval、ConfirmApproval、ExecuteApproved、GetExecutionResult、ReleaseTask。
- 未知版本、字段、动作、重复 request、非法 ID、未建立任务、阶段不匹配拒绝；查询也验证当前用户与任务所有权。

## 3. 盘点与证据

### 3.1 Scope

Scope 与清理授权不同。记录用户所选本地卷/目录、规范路径、卷类型、目录身份、排除范围、创建时间和范围版本。拒绝网络映射盘、UNC、设备路径及不支持路径；不自动提权访问其他账户或系统内部。

用户资料允许元数据展示但处理保护不可撤销；开发期真实只读验证更窄，仅已授权当前账户应用缓存/软件目录。云占位不读取内容、不触发下载；链接不跟随。

### 3.2 Observation / Evidence

记录对象 ID、父 ID、规范路径、卷与文件身份、元数据时间、逻辑大小、可得的分配大小、链接数/重解析/离线属性、观察时间。目录汇总明确完整、部分、未覆盖，不将错误折成零。

证据包含稳定 EvidenceId、对象 ID、探测器版本、事实类型、值、采样范围、反证和时间；提议引用 ID，不由模型自写“事实”。精确数字由程序比较与转换成布尔/分档事实，避免模型计算。

## 4. Laya 决策接口

固定多语言 checkpoint 和推理方案；初版一次只驻留一个模型。无运行时在线加载或自动模型路由。

输入：TaskId、TargetId、EvidenceRevision、QuestionTemplateVersion、短结构化 State、问题与允许选项。路径/文件名为不可信数据，不能改变问题或动作定义。

建议内部动作名：InspectLayout、InspectOwnership、InspectDuplicates、AskUser、Stop。分类名：Cache、BuildArtifact、UserData、Mixed、Unknown。保留 Unknown/Stop，不要求模型强行选择可处理类别。

输出：选择 key、完整选项分布、可用的参考置信字段、原输入摘要 hash、checkpoint/tokenizer/adapter/config hashes、时间、时延、截断/拒绝/错误信息。不要将 entropy confidence 与答案概率混为一个量，更不能显示为删除安全率。

调度器执行前检查：选择存在于当前允许集、目标属于已授权范围、证据版本未变化、动作有实现、预算足够、不重复无进展循环。预算包括遍历、深度、读取字节、hash、模型调用和耗时，分别可见。

规则能够确定的硬保护优先于模型；模型只决定类别/排序/后续检查与复核，不发执行指令。模型故障时保留基础盘点，状态明确为模型分析未完成；不使用基线输出冒充真实推理。

## 5. Suggestion / Group

建议组记录建议 ID、对象集合快照、类别、建议动作、影响描述 ID、支持/反对/缺失证据、完整性、模型决策引用和硬保护原因。

展示等级：VerifiedCache、ReviewSuggested、OrganizeOpportunity、Undetermined。未核验或有疑点可进入 ReviewSuggested，但默认不选中；UserData/Mixed/硬保护不得因此取得处理能力。

重复组记录每份副本身份与完整内容验证；不是默认按路径或时间自动留一删余。硬链接不重复计算释放量；程序依赖目录与个人资料重复只展示。

## 6. 批准集合与执行

### 6.1 PrepareApproval

界面提交选中的 Suggestion IDs。执行器从私有索引重新展开明确普通文件集合，验证无硬保护、无范围越界、无重叠重复。目录不作为“当前所有后代”执行授权。

生成不可执行草案：TaskId、ScopeRevision、SuggestionRevision、CandidateSetHash、批准候选数/逻辑大小、每项路径/身份/mtime/size、策略/探测器/模型引用、RecycleOnly=true、创建时间。展示内容和 hash 绑定。

### 6.2 ConfirmApproval

用户看到本次影响与具体集合后确认。提交的是草案 ID 与展示 hash，不是任意 Paths。准备后变化则失效并重新展示；切换范围/更新建议/清理旧结果使旧草案失效。确认后保存私有保护的批准工件与内容哈希。

### 6.3 ExecuteApproved

只收批准工件 ID，不收新路径/排除表/任意新增字段。验证工件、任务所有权、范围与集合 hash、单次 claim；先完整验证格式和批准集合再开始。

逐项重查祖先、链接、身份、大小、时间、只读、占用及适用限制。后代新增文件不处理；候选变化跳过/要求重新检查。重复文件处理还要确认未选保留副本仍存在且验证未失效。

仅移入回收站。回收 API 必须验证“不允许永久删除回退”的实现语义，不能认为带 AllowUndo 标记就保证回收；无法保证时跳过。中断保留逐项台账，不自动重试。默认不删除空父目录。

回收成功计入处理逻辑大小，不宣称释放同等空间；即时可用空间变化另行观测并说明系统其他活动可能影响。

## 7. 必测的拒绝路径

- 模型选择不存在动作、伪造 target、返回NaN/缺概率/超长输入、截断未显式处理。
- 建议集或证据变化，草案已展示后加入文件，批准工件被替换，跨任务ID或旧schema。
- 文件/祖先替换、重解析链接、硬链接、只读、占用、云占位/网络映射、权限不够。
- 重复文件保留副本消失或被修改；不能再删除其他副本。
- 不能回收、回收失败、取消、进程崩溃；无永久删除fallback、无旧计划自动重放。
- 超预算、无权目录、模型缺失，结果必须是明确的Partial/Skipped/Failed，而不是全绿。

## 8. 验证责任

原生/参考模型等价、领域评测和性能各自留证；成功调用不是质量通过。独立验证读取固定版本/模型hash后执行；实现者自查不替代。

先在本轮自有GUID人工沙箱验证完整闭环，再限定应用目录只读测试真实发现。既有Core/Release回归和桌面验收继续保留，构建/发布采用明确多组件清单与哈希，不靠删断言放行。
