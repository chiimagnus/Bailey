# Git Diff 正确性、原生体验与性能收敛

本文件是需求、范围与验收的唯一真源；实施拆分见 `plan-p1.md` 至 `plan-p4.md`，
实时状态只在 `todo.toml`。计划编制于 2026-11-05；当前进度和结果须以 `todo.toml`、现行源码与实测为准。
P1 技术调查已完成；P1–P3 的实时完成状态以 `todo.toml` 为准，
实施事实需直接核对当前源码、真实测试与 Git 历史，不以旧 `audit*.md` 代替审查；
2026-11-09 明确验收口径：以覆盖实际 Swift 行为的 `BaileyTests` 和必要的
`BaileyUITests` 为准，不再把额外的 WindowServer 首像素、30 次冷热 GUI P95、
独立图形会话或 macOS 虚拟机作为阶段门禁；失败的 XCTest 仍须追查，不能豁免。
P3 的 Git／SSH 生命周期修复 `1f3987d3` 和实机验收契约更正 `5dc33923`
已提交。完整本机 923 项（16 项 Windows 条件跳过）、隔离 Bailey Dev GUI 55 项、
授权 Windows SSH 实机 16 项（0 跳过）当时通过，P3 阶段 Gate 为 `Go`。
2026-11-10 又合入真实远端 Split 自动保存及 SSH 测试 socket 隔离修复；
PR #78 已于 2026-11-05 合并。P4 必须按**最终 HEAD**重新核销受影响范围，
不能继续以 2026-11-05 连接超时／16 项跳过当作当前实机阻塞。
已独立验证并提交冗余字段清理（`a9fdb51b`）；原始布局反证、Git 对象和密集投影
测量仍保留在 `evidence-p1.md`。P4 的必要 Swift UI 交互、IME 与跨环境终验
仍按其测试覆盖核销；旧性能数字是诊断证据，不是新增的独立 GUI 门禁。

## 背景与触发

Bailey 的 Staged、Unstaged、历史 Diff 已共用核心算法与部分原生界面，
但连续修复暴露出更底层的性能和交互问题：
首次全文布局阻塞首屏、编辑回调反复获取整篇字符串、部分 UI 行为只靠宿主测试间接证明，
而 Git 读取和派生计算虽已优化，尚未用真正的可见首帧与输入延迟完成端到端验收。

目标不是再补几个症状，而是把**文件事件／状态刷新 → Changes 或 Graph 选择 → Git 读取 →
可信差异快照 → 折叠／TextKit 渲染 → 原生编辑 → 保存与再次刷新**
作为一个可追踪、可测量、有明确所有者的完整用户路径，
在不牺牲数据正确性、原生编辑与现有 UI 语义的前提下，消除已证实的重复工作与响应迟滞。

## 当前基线与证据边界

规划时分支为 `fix/diff-review-viewport-and-syntax`，
HEAD `5230f341`，工作区干净；PR #78 当时仍 OPEN。
这些是计划依据，不是实施时可免复核的永久事实。
仓库 `AGENTS.md`、`docs/features/diff.md`、
`docs/{architecture,standards,testing,development,ui}.md` 及 `Makefile` 为执行规范。

| 来源 | 已确认事实 | 不能由此推断的事 |
| --- | --- | --- |
| `GitFileEventWatcher → GitStatusModel.refresh → GitPanel.browseGitChange → Project.openDiff` | 本机事件通知合并等待约 400 ms；状态查询分别发布核心／详情，点击行还处理选择与焦点；历史与其它 Worktree 另走 Graph | 这与用户主动点击已显示行的 Diff 加载延迟是两条时间路径；不能混算或只测 `DiffTab.reload` |
| `DiffCodePaneView.layout` | `ensureLayout(for: documentRange)` 首次全篇布局；24,000 行折叠样本约 206 ms（Debug） | 不能只去掉该调用；旧实验曾使末行不可达 |
| `DiffRowGeometry.visibleRows / DiffTextView.hasNativeNonLFSeparators` | 非折叠、无只读行起点时会从文首枚举至视口；原生换行种类缓存每次字符编辑会失效，随后可能全篇扫描 | 需实测深处滚动与每键布局；优先复用与 Git LF 行号一致的现有 UTF-16 行起点，不把原生段落索引直接当 Git 行，也不新建第二套索引 |
| `NativeCodeTextView.processStorageEdit` | 已获取 `editedRange`／替换文本并增量维护行索引，但对 Diff 只调用零参数 `onCharacterEdit` | 增量信息在进入 `DiffTab` 前丢失；必须以真实 AppKit 事件和全文保存语义检验最小改动接口 |
| `DiffNativeSurface.editTextDidChange → DiffTab.updateEditedContent` | 每次编辑取 `textView.string`，随后比较保存基线并安排 Diff 刷新 | 不等于已测出输入 P95；必须分别量化取全文、比较、着色与布局 |
| `DiffTab.reload → gitContent/gitComparisonBaseline` | Staged 双基线可并行；Unstaged 仍需有序 `hash-object` 与 Git patch 快照校验；24k 行 30 次热测模型就绪中位 Staged 199.1 ms、Unstaged 242.9 ms，P95 为 351.2／328.5 ms；1k 中位 69.8／102.3 ms | 这些数值不是可见首帧；必须区分不可并行的快照顺序与可压缩的 Git 启动／对象读取 |
| `DiffTab.reload/invalidateReload/deinit → WorkspaceBackend.run` | `reload()` 用未保存句柄的 `Task` 等待独立 `Task.detached` 执行 Git／文件读取；`invalidateReload()` 仅推进代次，`deinit` 只取消 Diff／语法工作 | **旧结果不发布 ≠ 底层 Git/SSH 读取已取消**；需从关闭/切目标/编辑触发追到子进程实际结束，不为每层复制代次 |
| `NativeTextLineIndex` 与 `TextCoordinateIndex` | 前者可按 AppKit 自然段落或 Git LF 分行，后者仅以 LF 分行；只读 `DiffDecorations` 保存已构造的行起点，工作区编辑态改用唯一实时 Git-LF 索引，不持久保存过期快照偏移 | 裸 CR／U+2028／U+2029 等下原生段落与 Git 行**不能互换**；可见行只使用匹配语义的实时坐标，不复制可写索引 |
| `Project.remove/terminateAll → DiffTab.nativeSurface → DiffNativeRoot.dismantleNSView` | FileTab 关闭时明确 `retireNativeEditor`，但 DiffTab 分支仅清 `onSnapshotChange`；SwiftUI `dismantleNSView` 只撤销焦点回调，旧原生 pane 可仍被 AppKit 引用 | **已确认生命周期处理不对称，未证明实际泄漏**；需测试真关闭后旧 `NSView` 被缓存时的 NSTextStorage／Undo／语法保留，并只在真关闭退役，不在 Dock 重挂载退役 |
| `GitCommandExecution.runData(stdoutLimit:) → WorkspaceBackend.run / ProcessRemoteCommandRunner.run` | 本地 stdout reader 限制保留字节，但 stderr 仍完整接收；SSH runner 的 stdout／stderr 都持续追加完整 Data，`backend.run()` 返回后才 `.prefix(limit)`；`hash-object` 另经无上限 `backend.run` | **远端输出上限并未约束传输与峰值内存**，截断也不自动标记失败；需在实际读取处设置调用者预算并验证 Git patch／状态输出完整性 |
| `GitWorktreeComparison.resolve → DiffCore.fromVerifiedOperations` | 能复用已验证 Git hunk；不能映射时回退算法；实时编辑仍重新计算 | 不代表全部 Git 来源、特殊文本与并发路径都已完成跨界面验收 |
| `DiffComputation.build → DiffBlocks.blockEmphasis → DiffIntraline.myersTokens` | 稀疏改动样本投影中位约 0.17 ms；但每次 build 对成对修改行运行逐词 Myers，token 上限 400，回溯轨迹随编辑距离增长且内部无独立取消点 | 简单样本不能代表密集改动；需先测 399／400／401 token、百／千行成对改动、反复展开及取消时延，实测有问题才优化 |
| `DiffSyntaxSource.captures` | 未变字节复用 Tree-sitter 树，修改侧 Worktree 由 Neon 着色；大于 2 MB 的源码不缓存树 | 未实现编辑增量解析，也尚未证明增量解析值得引入 |
| 2026-11-05 测试日志 | 独立清理提交 `a9fdb51b` 后的完整 `make test` 在 19:47 执行 843 项、16 项授权 SSH 跳过、0 失败；之前 105 项定点测试通过、5 项 Git GUI 一次 ⌘S 事件合成超时后复测通过 | 只证明 `a9fdb51b` 当时的宿主状态；2026-11-09 已有单独授权 Windows SSH 16 项实际通过。旧 GUI 合成超时仍需按发生时的 SHA 与最终字节归因；旧跳过与旧通过都不能代替当前 HEAD 的证据 |
| `docs/testing.md` | 输入 P95、滚动帧、热视口几何和本地 Git 30 次热样本均有现行测量标准 | 模型准备时间不是文本真正显示或可交互时间 |

## 必须交付的产品结果

### R1 一个 Diff 语义、一个可信状态所有者

- Staged = HEAD 对 Index，始终只读；Unstaged = Index 对 Worktree，
  仅真实存在的常规 Worktree 文件在当前连接允许时具有编辑资格；
  符号链接不得按普通文件保存，断线时只读并保留草稿，磁盘权限失败必须反馈且保留缓冲。
  合并冲突独立按 Git index stage 和真实文件资格处理，不能未经证实一概禁用编辑。
  历史提交（按首父）、Stash 对应的真实提交、两个选定提交、历史原文、
  历史对工作区比较及其它 Git Worktree 保留各自真实路径、机器与 Git 对象身份。
- Diff 算法、变更行、折叠计划、行内强调及绘制规则共用；
  各来源只在读取对象、写入资格及必要规范化视图上不同。
- 不恢复 Review/Edit 模式切换；同一工作区可写原文、选区、Undo、保存和 Native TextKit 身份只有一个真源。
- 快速切文件、改变项目／机器、窗口重挂载、停止任务或重连，
  较早结果都不能覆盖较新目标／草稿；每个 Task 的停止与资源释放可证明。
  **不仅**核对 `reloadGeneration` 阻止过期结果发布，还必须核对无消费者的 Git/SSH 读取
  是否仍在运行、是否占据进程和连接；按现有任务拥有者取消与进程生命周期解决，
  不新增无消费方的全局调度器。

### R2 首屏真实可见、滚动范围立即准确

- 打开有变更的 Diff 首次可见时已经正确折叠，不先显示完整文件再闪烁收起。
- 原生纵向滚动条首次出现就是完整有效范围；滚动到底不逐段缩短滑块，
  最末真实源码行及末尾删除虚拟行均可到达。
- 不以整篇同步布局换取表面正确：在 P1 以原生实验选出**既准确又低成本**的布局归属；
  不能把错误的固定高度、尾端补刷新或滚动时补全作为修复。
  若 TextKit 原生布局的正确性与首屏性能冲突，必须保留最小复现和真实 API 证据，
  **修订并验证新的原生方案后**才能通过 P2-T1；只删除 `ensureLayout(documentRange)`、
  把 206 ms 转移到后台或把完整布局推迟到首次滚动，都不能算根因修复。
- 支持 Unified／Split、可编辑／只读、长行截断／完整显示、
  原生 LF／CRLF／裸 CR／Unicode 段落、删除占位、改字号／折行宽度、窗口缩放、横纵滚动和滚动条两种样式。
- 文本、行号、背景、折叠标记、原生滚动条、AX 坐标和实际像素始终对齐。

### R3 可见编辑响应快、隐藏数据不受误操作破坏

- 点击普通源码、聚焦、选取可见文字、输入和滚动不自动展开；
  只有明确激活 `xx unmodified lines` 标记才逐步展开。
- 未展开的源码保留在真实缓冲中，不因折叠删除、截断或复制另一个可写文档。
  直接编辑可见行不应误改隐藏区域；跨折叠边界的选区、删除、粘贴、输入法、
  Find/Replace、`⌘A`、Undo/Redo 必须有确定、与原生文档一致的作用域。
  **P1 必须先实测并固定这些边界行为**；不预设“禁用 ⌘A”或引入弹窗。
- 每次普通按键不得仅为 Diff 装饰反复物化、比较或重建整篇编辑缓冲；
  编辑事件、行坐标、折叠与语法状态按同一内容版本推进。
- 保存成功后保留同一 Git 基线的展开状态；真正的基线变化才使其失效；
  编辑→撤销→保存→重读后原始字节、选区与折叠正确。
- 保存失败、外部覆盖、SSH 断线或后台过期结果均保留新编辑及真实目标身份。

### R4 Git 数据、行号与视觉反映真实变更

- 以 Git 实际 OID／index、clean filter、`core.autocrlf`、`.gitattributes` 为准；
  Git 认定无文本变化时，不能显示整篇删增。
  **Staged 并行读取 HEAD 和 Index 时**也要验证同一个用户动作的逻辑快照一致：
  HEAD、Index 在两项元数据读取之间变化时不能错误拼接两代结果；
  锁定 Blob OID 保证对象不变，**不能单独证明两个来源属于同一时点**。
- 初始 Git patch 复用仅在旧／新 OID、hunk、行操作、原始 UTF-8 快照全部匹配时成立；
  比较不同步必须重试或报告错误，不用静默空文档冒充成功。
- 多处修改、删除、新增、重命名／复制、冲突 index、无 HEAD、未跟踪、历史／Stash，
  空文件、末行无换行、Unicode 规范等价、长重复行、特殊路径均准确。
- 被 Git 过滤的规范化对照只能影响只读比较，不得写回、丢失或重排原始工作区字节。
- `stdoutLimit`、metadata、Blob 和 Git patch 的输出预算必须**约束实际接收／驻留**，
  而不是接收完整远端输出后截取前缀；超限、短读、错误退出和取消不能冒充完整结果。
  不给 SSH Files、Git 大仓状态或其它共享命令添加错误的全局输出上限。
- 针对 Git 模型准备的 1k／24k 行中位与 P95，P1 必须分离 Git 进程启动、
  `gitObject` 定位、`cat-file -s/blob`、不可破坏顺序的 `hash-object → git diff`、
  Diff 算法和语法成本；**已证实可消除的重复 Git 启动／读取**必须由 P3 同路径实施并量化收益，
  而不是只修输出限制后将原性能问题作为“待以后再做”。
  不为速度省略 OID／快照一致性检查，也不虚构任意性能优化的保证。
- 所有错误路径保留已显示内容，不让失败的来源变成空侧或意外写本机。

### R5 不以过度架构掩盖性能或正确性

- 先定位和测量，再改共用 owner；已有 `DiffCore`、TextKit、Neon、后端及取消机制可复用就复用。
- 不建第二套编辑器、全局调度器、推断式焦点管理或永久通用追踪平台。
- **每个实施 task 的第一步**确认调用者、测试使用者、现行产品需求和当前替代路径，
  分类为：确实无生产消费者／可合并重复路径／不可删除的数据保护或原生行为边界。
  已证实多余的旧分支、重复投影、状态镜像、适配别名、无消费者参数和临时围栏，
  在替代链落地的**同一 task** 删除并迁移测试；不得移到 P4 或另起“终局清理”任务。
- 执行前清理已核对 `DiffDisplay.hasCollapsedContext` 仅有宿主测试读者，
  用真实 `DiffComputation.unified.rows` 替换断言并删掉该字段；
  独立提交 `a9fdb51b`，`NativeDiffTabTests` 84 项（1 项授权 SSH 跳过）及
  相邻 37 项均 0 失败。该清理**不能冒充** P3-T3 整体完成或首屏性能改善。
  `DiffSyntaxHighlighter.captures` 全文件静态入口和 `highlightByteLimit` 也只被测试调用，
  只有确保独立 oracle 不丢失时才迁入测试并从生产删掉。
  现行源码没有 `afterGitAction` 和旧 Review/Edit 切换入口，**不能把不存在的旧代码
  再列为必须清理的工作量**。`DiffGhostGeometry` 已有视口定位优化，
  本轮发现的另一处 `DiffRowGeometry.visibleRows` 仍有前缀枚举，两者不可混淆。
  `showsCanonicalComparison`、Git OID／快照校验、`readOnlyReason`、保存队列、
  symlink 拒写、请求身份和取消边界目前均有真实业务消费方，**不能**当作旧 Review/Edit
  兼容代码或多余安全围栏直接删。具体删改必须有调用图和行为回归证据。
- 工作与内存随标签生命周期结束；关闭后的文本、语法树、布局与旧计算不会被后台任务长期持有。
  真实关闭 Diff 标签、整个项目、最后窗口和 App 退出，必须释放其独占 TextKit 正文；
  即使系统仍缓存 `NSScrollView`，旧文档也不得继续接受编辑或保持 Undo／Neon 解析；
  普通 Dock 重挂载和切标签则必须保留完全相同的编辑对象与 Undo，不能借机退役。
  对可复用解析树的每次 `capture` 必须把全文 `utf8.elementsEqual`、每个可见片段重复构造查询游标、
  Tree-sitter 解析成本分开计；真实热点才简化，不另起第二套解析器。
  还需把大量成对改动行的逐词 Myers 回溯分配和内部取消点缺口单独实测；
  不能拿稀疏改动的 `DiffComputation.build` 中位数证明所有输入都可忽略。
- 性能优化须通过覆盖原生布局、滚动、编辑与资源释放的 Swift XCTest；
  既有同机性能数据保留为诊断资料。没有实际失败的 Swift 性能回归时，
  不另要求独立 WindowServer 帧捕获或固定次数的 GUI 统计作为验收条件。
- GUI 输入合成曾出现一次 ⌘S 超时后复测通过：要调查实际前台焦点、第一响应者、
  XCTest 注入与 AppKit 事件接收，分清产品缺陷、测试夹具与系统环境；
  **重跑转绿不等于修复**。无法判定时保留失败证据与未通过结论。

## 范围与相邻计划

本 feature 覆盖**目前正式支持的文本 Git Diff 全部来源及完整用户路径**；
当前 `docs/features/diff.md` 规定每侧最大 5 MiB，本计划必须验证其边界和超限报错。

`.github/features/adaptive-large-files/` 已单独拥有取消 5 MiB 限制、GB 级分段文件模型、
分页保存与有界 Diff 的技术准入和实施。**不在此 feature 再建第二套 GB 编辑／缓存模型**。
执行两个计划如有共同代码改动，以当前已合并的真源检查冲突；
此计划的布局、编辑坐标及 Diff 所有权契约须能被大文件方案复用。
大文件 feature 真实完成后再做跨 feature 集成回归；未完成时不冒称 GB 验收通过。

不覆盖一般 Git 提交／分支／重置功能重新设计、Files 树重写、通用 Dock 重构、
SSH 认证、Monaco／Electron／WebKit 编辑器替换、LSP、正式发布以及未经要求的视觉改版。
后续需要跨上述边界的根因，先在证据与范围中说明后再调整计划。

## 默认与兼容决定

- 保留现有 Unified／Split 偏好，未改的折叠规则、颜色、快捷键、主题、字体及超长行设置。
- 默认折叠较长的未变区域；仅手动展开，不因普通编辑器焦点自动展开。
- 不为性能增加用户必须理解的新开关；内容大小、滚动高度和缓存策略先实验，再定实现。
- 保留 Apple Silicon、Swift 6、TextKit 2、Bailey Dev 隔离测试及既有部署目标；
  本轮以当前 Mac 与实际 GitHub runner 为验收环境，不要求 macOS 15.6 实机 GUI 测试。
- 纯优化零外观和语义变化；确需改变可见编辑的边界时，以 R3 的用户安全契约和真实测试为依据作出显式决定。

## P1 技术准入与性能预算（2026-11-06）

本节只冻结已验证的技术路线和实施门禁，不表示生产性能问题已解决。
分阶段原始数据见 `evidence-p1.md`、
`evidence-p1-100k-hot.md`、
`evidence-p1-process-lifetime.md` 和 `evidence-p1-textkit-transient.md`。

**基线分开比较：**

| 条件 | Staged 模型／组件像素中位 | Unstaged 模型／组件像素中位 |
| --- | --- | --- |
| 24k Release，30 次热态 | 178.9／187.6 ms | 278.7／797.7 ms |
| 100k Debug，30 次热态 | 432.2／440.1 ms | 531.3／5393.0 ms |
| 100k Release，30 次热态 | 163.5／171.2 ms | 280.7／2502.2 ms |

24k Release Unstaged 组件 P95 为 933.1 ms，100k Release 为 2634.9 ms。
它们是**离屏 NSWindow 的组件像素**，不是 WindowServer 的实际首像素。
真实冷进程 Split GUI 旧组因构建重叠剔除 3 次后各 29 次；
新同二进制组 Staged 16 次、Unstaged 15 次，低帧率采集只有上下界。
不同二进制、Unified 与 Split 的历史性能样本不得混算。
这些是诊断基线，不再要求 P4 另取高帧率 WindowServer 首像素、
首次可输入的独立量化样本或 30 次冷热 GUI P95。
首屏是否正确、滚动范围是否完整、是否仍发生全文同步布局，
以对应 Swift XCTest 的布局、可见文字、深跳和资源断言核对。

**P1 时被否决的旧 TextKit 快路径（历史结论）。**
纯 LF 24k 行固定 15 pt 时，未布局全文的原生估算高度 481,215 pt，
实际应为 360,000 pt；系统直接滚动或单段布局仅 4/17 次准确。
`relocateViewport` 虽能在 17/17 次恢复位置，
100k 行单次重定位中位约 181 ms、最慢约 310 ms，仍达不到热视口 32 ms。
折叠时跳过隐藏 `NSTextElement` 的单一存储实验把
24k 布局从约 253 ms 降为 50 ms，但没有覆盖未折叠末行、
Undo、IME、Find、Ghost 和 100k 反复远跳。
P1 当时要求 P2-T1 在同一 TextKit 所有者证明全部 17 次深跳、
完整滑块范围和真实末行，避免把错误原生快路径直接接入生产；
P2 的当前实现应直接核对 `DiffCodePaneView`、`NativeDiffTabTests`
及提交历史，不再以 P1 的旧 No-Go 描述已完成的 P2-T1。
P1 的 No-Go 是**已有快路径不可放行**，不是 Apple TextKit 2 一概不可行。

**可进入实现的已有证据与否决边界：**

- **编辑增量：有条件 Go（P2-T2／T3）**。原生编辑已有替换范围；
  Worktree 零参事件将它丢失，导致每次输入再次取全文并比较。
  100k Swift Debug 文首输入 P95 约 469 ms；Release 仍约 489 ms，
  高于 32 ms 目标。复用现有原生变更入口，Undo/IME/保存失败保持完整字节。
  普通点击不展开；显式 `⌘A`、Find／Replace 可以操作隐藏原文，
  不能擅自改成“只选择可见字符”或禁止系统命令。
- **Git 输出完整性：必须修复（P3-T1）**。
  `stdoutLimit` 的远端后截断在源码和受控实验中证实；
  超限需要接收端拒绝并报告错误，不能发布残缺 Blob／patch。
  锁定 OID 后的 size + blob 本机中位合计约 47 ms，
  一次性 `cat-file --batch` 约 19 ms；可验证后替代两次启动，
  但不能跳过 HEAD/Index 元数据或不可并行的 hash→diff。
- **Git 快照／后台资源：必须修复（P3-T2／T3）**。
  交错读取完整的 HEAD／Index OID 可拼接出虚假的 Staged 变化。
  关闭慢 Worktree Diff 后，五个独立 Git/filter 仍可继续运行，
  不可只靠 `reloadGeneration` 阻止结果写回。
- **高亮／投影：按已证热点收敛（P3-T3／T4）**。
  1000 对 400-token 密集逐词替换约 37 秒，取消仍有延迟；
  24k Swift 可见捕获热查询一次约 37 ms，
  主要是重复整篇 `utf8.elementsEqual`（独立中位约 36 ms）。
  稀疏约 0.17 ms 不代表密集；不重建第二套解析器。
- **内存／退役：必须修复（P2-T4、P4-T4）**。
  人为缓存旧原生滚动视图时仍持有已关闭 Diff 正文和语法资源；
  对确认真正关闭的布局管理器做 detach 消融后，
  五标签宿主在用 malloc 约 386→65 MiB。
  退役只发生在关闭所有权时；Dock 临时重挂载必须保留 Undo。
- **不删除的边界**：`showsCanonicalComparison`、OID/patch 校验、
  symlink 拒写、失联只读、保存队列和任务身份都有现实消费者。
  已删除的 `hasCollapsedContext`、`afterGitAction`、旧 Review/Edit
  不能再列为待清理任务；只在新路径取代老路径时同任务删除冗余。

**后续归属与门禁：** P2 独占原生布局／编辑／折叠／AX／真关闭；
P3 独占 Git IO、快照、取消及语法成本；P4 核销
`idea.md` 的全部来源、文本、环境、UX、失败与生命周期组合，
以及当前 HEAD 的 Release／Debug、整机 GUI／Windows SSH 验收。
当前 `adaptive-large-files` 只有规划授权，
不复用其尚未落地的代码，也不在本 feature 自行实现 GB 数据模型。
`docs/testing.md` 的输入、滚动与资源指标保留为性能诊断参考；
本 feature 的强制验收是相关 Swift XCTest 的正确性和已有可复现性能回归。
不因缺少额外 GUI 精确帧测量、固定 P95 采样或专属虚拟机阻塞阶段；
任何真实失败的测试或已证实的性能退化仍需修复。

## 验证条件全集（所有任务分摊核销）

| 维度 | 必须识别并尽可能执行的取值与组合 |
| --- | --- |
| 来源与入口 | Changes 首次点击／已打开再点／键盘浏览／右键仅改变目标，Graph 历史文件、首父提交、双提交、Stash、其它 Git Worktree、历史原文与历史对工作区；Staged、Unstaged、无变更工作区、未跟踪、Index 冲突及暂存后再次编辑；状态刷新核心就绪／详情未就绪／历史缓存失效 |
| Git 与文件状态 | 新建／删除／修改／重命名／复制（含大小写仅变化）、仅 mode 变化、空侧、无 HEAD／detached HEAD、Merge 的 index stage 0／1／2／3、符号链接／悬空链接／子模块／目录、同名跨项目及跨机器、大小写敏感／不敏感文件系统（实际可用时）、特殊字符／中文／空格／制表符／换行／前导短横路径（NUL 为非法路径内容） |
| 文本与规模 | 空文件／仅换行／1 行／1k／24k／100k／更多极短行（5 MiB 内资源允许的上界），0／1／多处／密集／全文差异、超长一行、极短重复行及无唯一锚点、连续删除与文件全部删除、LF／CRLF／裸 CR／U+0085／U+2028／U+2029、BOM、无末尾 LF、UTF-16 代理对／Emoji ZWJ／组合字符、NFC／NFD 规范等价不同字节、二进制／NUL／非法 UTF-8、恰好 5 MiB 与 ±1 byte，已达上限拒绝路径 |
| Git 规则 | `core.autocrlf` true／false／input（按环境适用）、`text`／`-text`／`eol`、clean filter 改写内容／行数／工作区副作用、Git diff 头与 OID 不匹配、HEAD 切换、index 变化、零上下文 hunk、补丁无变更／mode-only／截断／异常退出、`working-tree-encoding` 不可解码条件 |
| 显示与语言 | Unified／Split、编辑／只读、浅／深／高对比、中英文界面与中文输入法、系统两类滚动条、普通宽度／完整显示、窄／宽窗口、不同缩放／Retina 显示比例（环境具备时）、字体大小、视口顶／中／底、横纵滚动、拖动滑块、折叠点击、删除 ghost、行内色彩、AX 命中 |
| 编辑 | 普通字符／中文 IME／粘贴／多选区／跨隐藏行选区／`⌘A`／Find Replace／Delete／Undo／Redo／`⌘S`、自动保存、编辑前方增删换行、连续快速点击折叠、编辑后保存重载、外部修改、同时保存 |
| 异步与生命周期 | FSEvents（本机）／远端轮询刷新、首次挂载／重复打开／快速切文件／切 Git 来源／Split 切换／切主题／改字体／重挂载／标签关闭／项目及窗口关闭／恢复、AppKit **缓存已关闭 Diff 的旧 NSView**、同仓库大量状态行（1／100／10k 级）与历史分页、旧任务取消**及真实底层进程停止**、系统前台焦点干扰、读取中修改与索引切换（Staged HEAD 与 Index 交叉读取）、权限失败／超时／SSH 断线重连／流输出超预算；确认状态刷新与单文件打开分开测量 |
| 性能和资源 | Swift XCTest 覆盖 Debug／Release 适用配置、初装／重载、冷／热布局、深处滚动、折行、末行与 Ghost、编辑后缓存和多标签释放；本机原生组件测量和已有 P95 日志供回归诊断，不要求额外 WindowServer 帧捕获或固定 30 次 GUI 统计。Git 进程数、stdout 限额及真实 SSH 结果由既有 Swift 测试核对 |

每个适用且安全的取值都要有执行任务与最终结果证据；
有限可承受组合尽量穷尽，规模较大时先覆盖所有取值、所有极值，
再系统扩展两两、多因素和历史已复现组合。不能用“典型样本”豁免测试。

**暂时无法直接完成的条件与补验：**
- Windows SSH 实机：必须使用明确授权的独立测试仓库及现有 `BAILEY_P4_TEST_SSH_HOST`；
  未提供则以受控后端和本地临时仓库辅助验证，但远端真实 RTT、断线及保存仍属阻塞缺口。
- macOS 15.6 实机 GUI 不属于本轮验收门禁；仍维护现有部署目标及编译/API 兼容，
  但不对未实际运行的旧系统作 GUI 验收声明。
- 必需的完整 App GUI 行为：优先 GitHub Actions 的独立 macOS runner 上执行
  相关 `BaileyUITests`；不得在用户正在使用的本机桌面抢焦点，
  不创建 macOS 虚拟机。保留失败日志，按测试夹具／系统／产品归因，不靠固定等待制造绿色。
- 对内存极限的压力组合：先核对设备可用容量，超出安全资源的情形报告跳过原因、
  使用有限压力／失败注入替代，保留实际极限验收缺口而不以 OOM 影响日常环境。

## 完成验收与否决条件

1. 全部来源和用户动作的 Git OID、Index、工作区磁盘**原始字节**、折叠坐标、原生内容、Undo、选区
   均在操作后核对；只检查 `isLoading`、回调或行模型不算完成。
2. 首次滚动范围完整、末项可达、无缩短／闪烁，且 TextKit 不通过旧的全文同步布局掩盖几何错误；
   由覆盖真实原生视图、可见文字及滚动结果的 Swift XCTest 核验。
3. 普通输入、100k 行、折叠热视口、滚动及资源释放的正确性和已有性能回归由
   `BaileyTests` 覆盖；`docs/testing.md` 既有性能指标用作诊断目标，
   不作为必须另行测量 WindowServer 首像素或独立 30 次 GUI P95 的放行条件。
4. Git Staged／Unstaged 的 1k／24k／100k 及已知异常组合保持宿主 XCTest 回归；
   必要完整 App 动作由 `BaileyUITests` 验证，不重复底层全矩阵。
5. 每个实施 task 先适用的 Red→Green，处理同根因其它入口、
   及时删替代路径与更新其文档 owner，然后原子提交本任务改动。
6. 最终当前 HEAD 的完整 `make test`、`make build`、必要 `BaileyUITests`、
   签名和现有 Swift 内存／性能回归均需核对；GitHub Actions 选择性成功
   不等于完整测试成功。16 项 SSH 跳过逐项分类，
   失败的 Git/SSH/XCTest 测试必须处理或明确记录非当前阶段的归属，
   不以额外独立帧测量替代测试结论。
7. 计划与执行过程不得改动正在运行的正式 Bailey、不借用 SSH master、
   不触碰真实个人工作区测试文件、不得擅自推送／合并 PR。

**P1 的探索只是实现准入，不是功能完成。**
若原生 TextKit 2 无法在准确滚动几何下实现实质性首帧改善，
须提供失败输入、CPU／主线程和布局证据，再选择可证实的替代；
不能悄悄放弃末行可达性、原文编辑或折叠语义。
