# P1：确认真瓶颈、编辑语义与原生布局技术准入

**Goal：** 用当前真实 Bailey、Git、TextKit 2 和生产输入回调建立可复验基线；
在生产重构前证实首屏准确布局和局部编辑可行路线。

**Non-goals：** 本阶段不改变正式 App、不删除安全快照校验、不擅自引入虚拟文本控件、
不以“跑完性能实验”宣布 Git Diff 已完成。

**Approach：** 逐条追踪本机文件事件／SSH 轮询、Git 状态核心与详情、Changes／Graph 路由、
打开／读取、Diff 计算、原生排版、实际绘制、输入、保存与释放；
用现有 XCTest、隔离 Bailey Dev、Instruments 比较候选方案。
唯一决定后续结构的未知（完整滚动范围且不强制全文 TextKit 布局、
编辑回调如何只传真实增量）先做最小实验再冻结实现。

**Acceptance：**
- 获得同机同数据的 Debug／Release、冷／热、模型准备／首屏／可输入／稳定着色分阶段数字；
  输入、滚动、内存和 Git 子进程成本可归因于具体调用路径。
- TextKit 方案有原生末尾坐标、滑块、折叠、Undo／IME／选择和资源结果，
  成功或失败都可复现；有明确生产准入与停止条件。
- 现有 Git 快照安全及原始字节不变量有真实 Git 测试证据，
  不因为快路径收益好就假定可以移除校验。
- P2／P3 具体实现路线与首帧预算在本阶段由实测固定，而非凭直觉选择。

**Rules：**
- 本轮授权**只写计划**，下述测试、原型和重构在后续执行时才进行。
- 遵守 `AGENTS.md`、`docs/testing.md` 的隔离、Red→Green、全条件覆盖和主线程约束。
- 已有独立 `adaptive-large-files` 拥有 GB 级分页模型；本阶段只测当前有界 Diff，
  不建立另一个分页数据层。
- 使用根 `Makefile` 和现有 XCTest；调试产物写 `build/`，
  原型代码不得偷渡生产路径。记录实测日志及当前 HEAD，不把旧日志当最终版本证明。
- 未授权真实 SSH、正式 Bailey 和用户 Git 仓库均不得用于测试。

## 已读实现与证据锚点

| 入口／所有者 | 当前源码与可观测结果 | 主要测试 |
| --- | --- | --- |
| `GitFileEventWatcher → GitStatusModel.refresh → GitPanel.browseGitChange → WorkspaceWindowModel/Project.openDiff` | 本机事件合并、Git 核心与详情、当前行焦点及标签复用；Graph 经 `RecentCommitsView` 进入 `Project.openCommitDiff/openHistoricalDiff` | `GitStatusModelTests`、`GitBrowsingRecoveryTests`、`GitChangesUITests`、`GitGraphUITests` |
| `Project.openDiff → DiffTab.reload` | `Bailey/Workspace/Project.swift`、`Bailey/Git/DiffViewerView.swift`；打开、复用、读取和代次 | `NativeDiffTabTests`、`GitBrowsingRecoveryTests` |
| `DiffTab.gitContent/gitComparisonBaseline` | 锁定 Blob OID、raw worktree 与 Git patch；clean filter 重读和重试 | `NativeDiffTabTests`、`NativeGitHistoryFileTests`、`GitExecutionTests` |
| `GitCommandExecution.runData(stdoutLimit:) → SSHWorkspaceBackend.run` | 远端先完整接收输出再截取返回前缀；本地 `LocalWorkspaceBackend.runSync` 也有独立无输出限额的命令路径 | `GitExecutionTests`、`RemoteCommandsTests`，需补超量 stdout/stderr 和命令失败的传输／内存断言 |
| `DiffCore.computeIfActive / fromVerifiedOperations` | 可取消行比较及已验证 Git hunk；`DiffComputation.build` 仍有三种投影 | `DiffEngineTests` |
| `NativeCodeTextView.processStorageEdit → onCharacterEdit → DiffNativeSurface.editTextDidChange` | 原生层已有编辑范围、替换文本和增量行索引；零参回调使 Diff 逐键再取 `textView.string` 并全字节比较 | `NativeEditorCompositionTests`、`NativeDiffTabTests`、`WorkspaceGitUITests` |
| `DiffCodePaneView.layout/applyContentHeightOverride` | 首次 `ensureLayout(documentRange)`，独立高度覆盖逻辑、折叠和 ghost；`applyGhostSpacing` 还会操作真实段落属性 | `NativeDiffTabTests` 中的滚动和长文件用例 |
| `DiffRowGeometry.visibleRows` / `DiffTextView.hasNativeNonLFSeparators` | 非折叠编辑会从文首列举到当前 viewport，且换行扫描缓存随字符变更失效 | `NativeDiffTabTests`、`NativeEditorLayoutTests`，须补深处热视口开销断言 |
| `DiffTextView.setEditingFolds / DiffRowGeometry.visibleRows` | TextKit 隐藏布局、LF／UTF-16 映射、可视片段绘制及 AX | `NativeDiffTabTests`、`NativeEditorLayoutTests` |
| `DiffNativeSurface.render` | 工作区可写、规范化只读比较、Split／Unified、滚动同步与原生生命周期 | `NativeContentIdentityIntegrationTests`、`WorkspaceGitUITests` |
| `DiffTab.writeCurrentText` | 真实工作区保存与保存后重载；失联和目标身份校验 | `NativeDiffTabTests`、`GitUncommittedActionTests` |

历史性能日志：`build/git-diff-verified-hunks-final-targeted.log`
（24k 行模型 Staged 约 199 ms、Unstaged 约 243 ms，30 次中位）；
`build/git-diff-cold-layout-before.log`（24k 行首次全文布局约 206 ms）；
`build/git-diff-verified-hunks-full-host.log`（843 项，16 跳过、0 失败）；
`build/git-diff-verified-hunks-ui-repeat.log`（5 项 GUI 复测通过）。
这些日志只能用作**同机重测前的历史对照**，与最终合并验收严格分开。

## 验证执行契约

`idea.md#验证条件全集（所有任务分摊核销）` 是本 feature 的完整适用条件集合。
每个任务执行时须逐项明确：哪个来源／输入／状态组合已验证、哪条真实调用链被覆盖、
前提如何成立、最后核对的是磁盘字节／Git OID／TextKit 像素／运行资源中的哪一项。
覆盖尽可能遍历所有适用边界，再扩充两两、已知失效和多因素组合。
记录无法执行的场景及**具体**阻塞和后续补验，不得笼统“风险可接受”。

<a id="p1-t1"></a>
## P1-T1 建立可复现的完整 Git Diff 体验与性能基线

**结果：** 首先知道真正的等待发生在哪个阶段，而不是继续优化“模型就绪”单项。

**Files／稳定锚点：**
`Bailey/Git/GitFileEventWatcher.swift` 的事件通知与
`GitStatusModel.configureLocalWatcher/refresh/runGitStatus`；
`GitPanel.browseGitChange/selectGitChangeForPointer`、`RecentCommitsView` 的历史选择、
`WorkspaceWindowModel.openDiff`、`Project.openDiff/openHistoricalDiff`；
`Bailey/Git/DiffViewerView.swift` 的 `reload/recomputeDisplay/refreshEditDecorations`；
`Bailey/Git/DiffNativeSurface.swift` 的 `render/layout`；
`Bailey/Git/DiffTextView.swift` 的 `DiffCodePaneView.layout`；
`BaileyTests/Git/NativeDiffTabTests.swift` 中
`testLocalGitStagedAndUnstagedDiffReadyLatencyMatrix`、
`testFoldedNativeDiffScrollbarHasCompleteHeightBeforeDeepScrolling`、
`testFoldedWorktreeViewportGeometryBudgetWithManyChanges`；
`BaileyUITests/Git/WorkspaceGitUITests.swift` 的真实文件输入／保存路径。

**步骤：**
1. 复核提交、分支、用户未提交修改、实际 macOS／Xcode／屏幕／字体／长行设置；
   保留当前程序和原生 GUI 截图。分别建立 Staged／Unstaged／历史及其它 Worktree、
   Unified／Split／编辑，1k／24k／100k／5 MiB 内更多极短行、少量与密集修改、
   长行、Unicode、空文件及多标签真实样本；仓库状态项规模取 1／100／10k 级，
   不以文件行数代替 Git 列表复杂度。
2. 先把**文件事件发生 → Git 核心状态可用 → 详情可用 → 行出现在 Changes**
   与**点击已显示的行 → 打开标签 → Git 读取 → DiffCore → TextKit 排版 →
   WindowServer 首像素 → 实际可输入 → 语法色稳定**分为两条计时链。
   现有定点测试测模型／投影／语法；用 Instruments Time Profiler／Allocations
   及必要的轻量 signpost 归因 `GitStatusModel`、`GitPanel` 选择、
   `DiffTab` 和原生布局，避免把 400 ms 事件合并误算为每次点击的加载成本。
3. 输入测量分开：裸 `NSTextView`、真实有 Neon 的编辑、包含折叠／ghost 的 Worktree；
   记录文首／中／末 30 次编辑、整篇字符串提取与比较、行索引、后台 Diff、
   main actor 连续占用、Undo 和保存后原字节。
4. 冷启动与重复打开分开；至少 30 次热测试记录中位／P95／最差，
   带样本 hash、system build、Debug／Release 配置及 CPU／RSS／heap。
   单独测非折叠 `DiffRowGeometry.visibleRows` 在远距滚动时的文首前缀枚举、
   普通输入后非 LF 换行标记扫描及 `applyGhostSpacing` 属性更新，
   对比视口顶／中／底，不能只测第一屏或折叠路径。

**验证：**
`make test:NativeDiffTabTests,DiffEngineTests,GitExecutionTests,GitStatusModelTests,GitBrowsingRecoveryTests`；
用 `make test:ui ONLY_TESTING=...` 选择现有真实 Git GUI 项
（按 `Makefile` 正确的 `BaileyUITests/类名/方法` 选择器）；
另按 `docs/testing.md` 在隔离 Dev GUI 中测首帧、真焦点、真实窗口像素。
无产品修改的测量允许新增必要的 XCTest 断言，不能为计时搭独立测试系统。

**覆盖：** 本机所有 Diff 来源、状态缓存有效／失效、首次刷新／外部 Git 改变／Git 视图已打开，
仓库行规模、变更稀疏／密集、文首／中／末、主题／窗口尺寸／两种布局；
资源开销、冷／热、单／多标签、长行、空和边界极值。
**Uncovered：** 授权 Windows SSH 的网络／断线时间在缺少专属主机前未测，
不能转写成本机结果；P4-T3 补验。历史版本的完整正式 App 未必持有独立焦点，
当前专用 Dev 验收为准。

**文档：** 仅在 `docs/testing.md` 已有性能定义确实不完整时更新测量方法；
本次实验数值留本 feature 证据／`todo.toml` note，不复制进长期功能文档。
**提交：** 若仅保留测量证据不提交代码；必要的自动化断言按仓库规则原子提交。

<a id="p1-t2"></a>
## P1-T2 反证 TextKit 准确滚动范围能否避免首次全文布局

**结果：** 用原生 `NSTextLayoutManager` 证明一种可执行的低成本几何契约，
或交付准确的失败边界与替代决策，而不是把“虚拟化”作为未经证明的方案名称。

**Files／稳定锚点：**
`DiffCodePaneView.layout/invalidateDocumentLayout/applyContentHeightOverride/applyGhostSpacing`、
`DiffTextView.setEditingFolds/hasNativeNonLFSeparators/storageCharactersDidChange`、
`DiffRowGeometry.visibleRows`、现有 `NativeTextLineIndex`、
`NativeCodeTextView.configureWrapping`；
现有 `NativeDiffTabTests` 的折叠／Unfolded／CR 原生滚动、
`testUnfoldedGitDiffScrollbarReachesEndWithoutHeightGrowth`、
`testNativeCRDiffScrollbarUsesFinalNativeParagraphHeight`、
`testLongDeletedBlockRemainsVisibleInsideFoldedEditorViewport`。

**步骤：**
1. 先用独立最小 `NSWindow + DiffCodePaneView` 记录不同文本形态下：
   `documentRange` 完整布局耗时、系统预估高度与实际高度、
   覆盖高度、最后一行的真实布局矩形、滚动条 `knob` 变化以及文本命中；
   将非折叠深处滚动的 `textElements(documentStart..<viewportStart)` O(前缀) 枚举、
   逐键失效后的 `hasNativeNonLFSeparators` 全篇扫描和 ghost 段落属性重排分别测量。
2. **先验证最短原生路线**：已有固定行高、Git LF 行偏移及折叠／ghost 几何
   能否在首次展示前给出准确完整高度，再只布局当前原生可视范围。
   只有裸 CR／Unicode 分隔符或长行折行证明此路线不适用时，
   才对必要的可变段落使用 TextKit 实际片段与局部测量；
   不为了“完整设计”固定实现两套通用布局引擎，
   更不以尾端刷新／错误行数修正原生坐标。
   Apple SDK 契约不明时再查对应接口，避免自行发明布局规则。
3. 优先验证是否能复用编辑器已有 `NativeTextLineIndex` 及 Diff 已维护的
   UTF-16 行偏移来解析可视行，避免每帧从文首枚举原生段落；
   非 LF 换行种类只随相关编辑范围变化而更新，不能另建全文缓存体系。
   同时验证左右 Split 同步、深处点击折叠／AX、窗口宽度变化与整段插入删除、
   拖动滑块直接跳底、17 次远跳、恢复滚动锚点、修改字号与长行显示，
   真实光标和最后的删除 ghost 都可达到。
4. 同机对比首帧主线程最长阻塞、P95、滚动 P95、峰值 RSS、全篇布局触发次数；
   除第一次挂载，还检查内容／折叠／字号／ghost 变化引起的**重复全文布局**。
   Gate 必须同时证明 LF 固定行高快路径、CR／Unicode／折行等可变行高路径
   的原生末行真实坐标、首屏阻塞和无额外全文布局。
   如果现有原生几何路径均失败，记录最小不变量冲突并检索当前 SDK／原生接口契约，
   验证更低层的**单一 TextKit 2 布局归属**是否可行；无可行实现时明确
   `No-Go：P0 首屏根因未解决` 并修订 P2-T1，**不能**把阻塞放到后台、
   换成估算高度或在首次滚动时补齐布局后宣称通过。

**验证：** `make test:NativeDiffTabTests,NativeEditorLayoutTests`
的现有真实组件场景，新增实验测试只在现有测试目标内；
窗口截图、滚动条长度与尾行文本的**真实位置**同时断言。
覆盖 LF／CRLF／裸 CR／Unicode 段落、超长折行、0／多处 ghost、
只读／编辑、两种滚动条、浅／深及高对比、首次／重排／恢复。

**Uncovered：** P1 的原生窗口不证明完整 App 前台焦点和 WindowServer 叠加；
后续 P2-T4／P4-T2 负责。大于 5 MiB 的分页布局归 `adaptive-large-files`，
此实验结果作为其接口约束，不等同 GB 验收。

**文档：** 若实验改变可接受的布局契约，先修订本 feature `idea.md` 与 P2-T1，
产品 `docs/features/diff.md` 在生产实现同任务再更新。
**提交：** 实验代码若无后续维护价值不入库；复现测试有长期价值才原子提交。

<a id="p1-t3"></a>
## P1-T3 实证编辑事件、全文复制与隐藏区间编辑语义

**结果：** 找到每次按键造成的同步正文开销，并冻结不破坏原生编辑的增量更新边界。

**Files／稳定锚点：**
`NativeCodeTextView.processStorageEdit/storageCharactersDidChange/onCharacterEdit`、
`SourceTextEditor.Coordinator.textView(_:shouldChangeTextIn:replacementString:)/handleNativeCharacterEdit`、
`FileTab.recordNativeReplacement/nativeTextChangedWithoutReplacement/refreshDirtyState`、
`DiffNativeSurface.makeEditPane/editTextDidChange`、
`DiffTab.updateEditedContent/writeCurrentText`、
`DiffTextView.setEditingFolds`、
`DiffCodePaneView.setEditingFolds/applyGhostSpacing`；
对照文件编辑现有 `NativeCodeTextView` 原生 `NSTextStorage.didProcessEditing` 路径；
`NativeDiffTabTests.testNativeDiffEditUndoScrollSaveAndReparent`、
`testFoldedEditorUpdatesSourceOffsetsWithoutRevealingHiddenParagraphs`、
`testNativeDiffEditorFocusLossSavesThroughBackend`。

**步骤：**
1. 用真实 TextKit 组件确认一次普通输入、批量粘贴、中文 IME 未完成／提交、
   Undo／Redo、替换与键盘删除究竟触发几次 `onCharacterEdit`；
   对照 `NativeCodeTextView.processStorageEdit` 已取得的 `editedRange`、
   `previousRange`、`replacement` 与传到 Diff 的**零参数** `onCharacterEdit`，
   量化 `textView.string` 桥接／可能的物化、全串 UTF-8 比较、
   非 LF 换行缓存失效与 `refreshEditDecorations` 次数。
   不把强制全串更新误写成“Neon 不够快”。
2. 对照现有文件编辑器真实路径：
   `SourceTextEditor.Coordinator.textView(_:shouldChangeTextIn:replacementString:)`
   在变更前捕获移除文本和替换文本，`handleNativeCharacterEdit` 在变更后提交；
   无前置通知（如 Undo）回落到 `FileTab.nativeTextChangedWithoutReplacement`。
   `NativeCodeTextView.processStorageEdit` 虽拿到新范围，却不能凭它还原所有被删原文。
   验证**最小**复用此原生边界与现有行索引，保持唯一 TextKit buffer，
   局部更新脏标记和 Diff 计算版本；避免直接复制文件编辑器的整套复杂缓存状态；
   仅在必要保存／真实外部快照阶段读取全文。原型须证明异步读旧快照不会盖新编辑。
3. **先实测再决定用户语义：**点击普通源码／只选可见行／跨折叠拖选／
   Shift 选择／`⌘A`／替换全部／Find 下一个／普通 Delete／粘贴／IME／多选区。
   区分隐含“只改看得见的东西”和用户显式发出的全文命令；
   保持系统 `⌘A`、Find、Undo 的基本习惯，
   不以粗暴禁止全部隐藏区内容换取一条测试变绿。
4. 记录 Red 的真实磁盘和隐藏原文字节及折叠状态；
   P2-T2／P2-T3 按事实分别收敛输入成本与编辑边界。
   若原生 API 无法提供足够变更信息，说明替代成本和数据竞争边界，不先复制整套 buffer。

**验证：** `make test:NativeDiffTabTests,NativeEditorCompositionTests,TextCoordinateIndexTests`；
组合窗口内光标、不同插入位置、折叠状态、Undo、失败保存的真实输出。
100k 短行须在当前 5 MiB 内构造；
对照 Debug／Release 输入 P95 与正文字节不变性。

**Uncovered：** XCUITest 对真实中文输入法候选验证有系统权限和桌面条件；
受控宿主先测组合事件，完整用户路径留 P4-T2；
不可冒充已通过真实中文系统候选。

**文档：** 需求取舍只在 `idea.md` 固定；如需改变 UI 操作语义，
生产任务同步 `docs/features/diff.md`、`docs/ui.md` 和 `docs/features/editor.md`。
**提交：** 探索有测试资产价值时提交测试；不提交未验证生产改造。

<a id="p1-t4"></a>
## P1-T4 定位 Git 快照、子进程、Diff 派生与高亮的剩余成本

**结果：** 获得准确的“值得改”和“不值得改”清单；
完整保留已证实的快照、过滤器、异常与取消路径。

**Files／稳定锚点：**
`DiffTab.gitContent/gitObject/gitComparisonBaseline/readWorktreeFile`、
`GitCommandExecution.runData/run`、`WorkspaceBackend.run`、
`LocalWorkspaceBackend.runSync`、`SSHWorkspaceBackend.run`、`RemoteCommandRunner.run`、
`GitWorktreeComparison.resolve`、`DiffCore.fromVerifiedOperations`、
`DiffTab.recomputeDisplay/refreshEditDecorations`、`DiffSyntaxSource.captures`；
`DiffEngineTests`、`NativeDiffTabTests`、`NativeGitHistoryFileTests`、`GitExecutionTests`。

**步骤：**
1. 用与旧日志完全对应的 1k／24k 真实 Git 临时仓库，
   分别测 Staged／Unstaged 冷／热模型准备，复核 30 次样本的
   69.8／102.3 ms、199.1／242.9 ms 中位，以及 24k P95 351.2／328.5 ms。
   逐调用记录 `ls-tree/ls-files`、`cat-file -s/blob`、`hash-object`、
   `git diff --unified=0` 的启动次数、CPU／等待／排队、stdin／stdout 字节数，
   并把可优化的 Git 元数据／Blob 读取与**不可破坏快照顺序**的 hash→diff 拆开；
   Staged、Unstaged、历史、clean filter、已打开重新选择与获授权 SSH 分开计。
   **先测试输出上限的真实性：**`GitCommandExecution.runData(stdoutLimit:)` 本机、远端
   分别施加大于 cap 的 stdout／stderr、Git 退出失败、阻塞与被取消命令；
   远端不能以“最终只返回 `.prefix(limit)`”冒充传输／峰值内存有界。
2. 对照已优化的 `LocalWorkspaceBackend` 子进程等待机制，
   区分 Blob 单对象 5 MiB、Git patch 20 MiB、远端整个进程管道这三个不同预算；
   验证是否在完整接收远端输出后才截断，或丢失被截断的失败状态。
   输出预算缺口属于**已确认正确性问题**，P3-T1 必须修复。
   另以同机 profile 判定 `gitObject → cat-file -s → cat-file blob` 的串行启动
   是否对模型中位／P95 构成实质成本；若成立，在 P3-T1 的同一读取链中给出
   **可以实施的最短对象读取方案及其完整性反例**，不得只写“未来再研究”。
   Git batch／常驻进程只有收益超过自身资源和状态复杂度时才考虑。
3. 复盘已验证 Git hunk 快路径是否在 0 上下文、重复行、CRLF、clean filter
   及并发编辑时保持 `DiffCore.compute` 等价；
   不改变 `hash-object → diff` 必须保持的顺序；
   用可复现的 Git index／工作区并发改写证明重试安全。
4. 测 `DiffComputation.build` 的全部投影和 `captureVisibleSyntax`／Neon，
   比较当前仅显示某一布局时真实新增分配、缓存版本、树重建、关闭标签后的 retained heap。
   若三份行投影仍约 0.17 ms，**不因设计洁癖重构**；
   若主线程富文本构造或过期解析大，记录具体输入和调用栈。

**验证：** `make test:DiffEngineTests,NativeDiffTabTests,NativeGitHistoryFileTests,GitExecutionTests,RemoteCommandsTests`；
真实 Git 临时仓库反复重跑包含 `core.autocrlf`、
`.gitattributes`、clean filter 改内容／行数、
无 HEAD、rename、delete、mode-only、索引并发改写的矩阵。
核对 Git OID／index、磁盘内容、显示行和分割后最后一行；错误不能变空。

**Uncovered：** 远端真实 RTT 与授权 Windows clean 过滤器要 P4-T3 的专用测试目标；
受控 `RemoteCommandRunner` 可验证返回预算，但不能替代 Windows 实际 SSH 内存与传输证据。
`cat-file` 批处理若无法安全在 SSH 目标运行，不进入生产准入；
不以本机压测代替跨机器证明。

**文档：** 暂只保留实验证据，不篡改 `docs/features/diff.md` 的现行保证；
生产改变时 P3 所属任务同步。
**提交：** 若需要追加真实 Git 永久回归测试，独立提交测试；原型不落产品。

<a id="p1-t5"></a>
## P1-T5 固定预算、技术决定与后续阶段准入

**结果：** 把 P1 的技术未知变成可执行决定；不让 P2／P3 执行者重新凭感觉选路线。

**Files：** 本 feature `idea.md`、`plan-p2.md`、`plan-p3.md`、
`plan-p4.md` 和 `todo.toml`（状态由工具维护，不手改）。
无需在此 task 新增生产代码或长期架构文档。

**步骤：**
1. 汇集 T1–T4 的测量环境、证据与相矛盾结论；明确真实根因与排除的假设。
   分开固定 1k／24k／100k、Debug／Release、冷／热、
   Staged／Unstaged、首屏／可输入／编辑／滚动／关闭后的目标与测量方式。
2. 对 TextKit 几何路线作 **Go/No-Go**；失败要给出最小失败用例、Apple 原生接口限制、
   可接受的替代路线和成本，**必须修订 P2-T1 才可实施**。
3. 对编辑增量事件作独立 Go/No-Go，锁定 `⌘A`、隐藏行及 Find/Replace 的可观察语义；
   如果改动会改变既有安全预期，先在需求真源写清决策而非埋在实现备注。
4. 对 Git／高亮／投影按可归因收益决定“实施／只补测试／不动”；
   必须交付 Git 模型**剩余延迟的归因表**：可消除的进程／IO 工作进入 P3-T1，
   不可并行的 `hash-object → diff` 保持现顺序，
   `DiffComputation.build` 约 0.17 ms 时不得投入大重构。
   远端无效 `stdoutLimit` 属**已由源码证明的正确性缺口**，不能与可选的 `cat-file` 优化同级。
   同时交付 CodeGraph 调用者核对后的删改分类：
   例如 `DiffDisplay.hasCollapsedContext` 仅有一个宿主测试读者，
   可在相关实现 task 直接以 `DiffComputation.unified.rows` 断言替代；
   `showsCanonicalComparison`、OID 校验、symlink 拒写及保存／请求代次必须保留。
   仅有想象的性能收益或尚未复现的问题不得强制产生生产改造。
5. 分配 `idea.md` 覆盖全集的每个适用值给 P2／P3／P4，
   未获授权的远端条件说明阻塞、后果、补验路径；
   核对 `adaptive-large-files` 不存在重复写入同一数据模型的待执行冲突。

**验证：** P1 所有实验日志可重放；
计划锚点、决策条件、适用测试环境与修改 owner 一致；
`feature_tool.py todo validate` 通过，**不等于 P2/P3 功能已验收**。

**Uncovered：** 本 task 没有进行生产实现或最终 GUI 验收；它们由 P2–P4 承接。
**文档／提交：** 仅维护本 feature 需求与计划，按 Skill 约定本地存储、不提交 Git。

## Phase Gate

全部 P1 tasks 核销后，按仓库流程进入阶段审计；实际审计开始时才创建
`audit-p1.md`。TextKit P0 与原生编辑链的实验若无可验证方案，
**不能以“探索完成”判定生产问题已解决**；保留 No-Go 及反证，
修订当前 P2 实施方案再进行下一轮准入。
Git 延迟如果已证实由可消除的串行启动主导，P3-T1 必须给出相应实现与
同条件中位／P95 验收；不准把该根因留为不明确的“以后优化”。
任何已否决路线同步从实施计划移除，不保留兼容后门。
