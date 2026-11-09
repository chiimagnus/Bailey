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
- 当前进入 **P1 技术准入**，生产技术重构仍需经过 P1 门禁；
  已确认独立、可验证的死代码清理可以就地删除并单独提交，
  不把完成这项清理等同于启动后续性能实施任务。
- 遵守 `AGENTS.md`、`docs/testing.md` 的隔离、Red→Green、全条件覆盖和主线程约束。
- 已有独立 `adaptive-large-files` 拥有 GB 级分页模型；本阶段只测当前有界 Diff，
  不建立另一个分页数据层。
- 使用根 `Makefile` 和现有 XCTest；调试产物写 `build/`，
  原型代码不得偷渡生产路径。记录实测日志及当前 HEAD，不把旧日志当最终版本证明。
- 未授权真实 SSH、正式 Bailey 和用户 Git 仓库均不得用于测试。

## 已读实现与证据锚点

| 入口／所有者 | 当前源码与可观测结果 | 主要测试 |
| --- | --- | --- |
| `GitFileEventWatcher → GitStatusModel.refresh → GitPanel.browseGitChange → WorkspaceWindowModel/Project.openDiff` | 本机事件合并、Git 核心与详情、当前行焦点及标签复用；`GitStatusModel.refresh` 的超时 watchdog 和 `runGitStatus` 目前分别用未持有句柄的 Task／detached worker，只校验代次；Graph 经 `RecentCommitsView` 进入 `Project.openCommitDiff/openHistoricalDiff` | `GitStatusModelTests`、`GitRemoteRefreshIntegrationTests`、`GitBrowsingRecoveryTests`、`GitChangesUITests`、`GitGraphUITests` |
| `Project.openDiff → DiffTab.reload/invalidateReload/deinit` | `Bailey/Workspace/Project.swift`、`Bailey/Git/DiffViewerView.swift`；打开／复用／读取，未持有句柄的 `Task` 中再启动 `Task.detached`，失效代次不取消 Git/SSH 子进程 | `NativeDiffTabTests`、`GitBrowsingRecoveryTests`、`SSHGitRecoveryLiveTests`，补宿主假慢命令取消／真实资源释放 |
| `DiffTab.gitContent/gitComparisonBaseline` | 锁定 Blob OID、raw worktree 与 Git patch；clean filter 重读和重试 | `NativeDiffTabTests`、`NativeGitHistoryFileTests`、`GitExecutionTests` |
| `GitCommandExecution.runData(stdoutLimit:) → SSHWorkspaceBackend.run` | 远端先完整接收输出再截取返回前缀；本地 `LocalWorkspaceBackend.runSync` 也有独立无输出限额的命令路径 | `GitExecutionTests`、`RemoteCommandsTests`，需补超量 stdout/stderr 和命令失败的传输／内存断言 |
| `DiffCore.computeIfActive / fromVerifiedOperations` | 可取消行比较及已验证 Git hunk；`DiffComputation.build` 仍有三种投影 | `DiffEngineTests` |
| `NativeCodeTextView.processStorageEdit → onCharacterEdit → DiffNativeSurface.editTextDidChange` | 原生层已有编辑范围、替换文本和增量行索引；零参回调使 Diff 逐键再取 `textView.string` 并全字节比较 | `NativeEditorCompositionTests`、`NativeDiffTabTests`、`WorkspaceGitUITests` |
| `DiffCodePaneView.layout/applyContentHeightOverride` | 首次 `ensureLayout(documentRange)`，独立高度覆盖逻辑、折叠和 ghost；`applyGhostSpacing` 还会操作真实段落属性 | `NativeDiffTabTests` 中的滚动和长文件用例 |
| `DiffRowGeometry.visibleRows` / `DiffTextView.hasNativeNonLFSeparators` | 非折叠编辑会从文首列举到当前 viewport，且换行扫描缓存随字符变更失效 | `NativeDiffTabTests`、`NativeEditorLayoutTests`，须补深处热视口开销断言 |
| `DiffTextView.setEditingFolds / DiffRowGeometry.visibleRows` | TextKit 隐藏布局、LF／UTF-16 映射、可视片段绘制及 AX；`NativeTextLineIndex` 的自然段落与 `TextCoordinateIndex` 的 LF 行是**不同概念** | `NativeDiffTabTests`、`NativeEditorLayoutTests`、`TextCoordinateIndexTests`，必须覆盖裸 CR／Unicode 分隔符 |
| `DiffNativeSurface.render` | 工作区可写、规范化只读比较、Split／Unified、滚动同步与原生生命周期 | `NativeContentIdentityIntegrationTests`、`WorkspaceGitUITests` |
| `Project.remove/terminateAll → DiffNativeRoot.dismantleNSView` | FileTab 真实关闭时退役原生编辑器，但 DiffTab 仅清快照回调；SwiftUI 卸载只撤销焦点回调，AppKit 可缓存旧视图 | `NativePaneRetentionIntegrationTests`、`WindowCloseIntegrationTests`；P2-T4 须验证保留旧 NSView 时资源释放，不可在 Dock 重挂载清空 Undo |
| `DiffTab.writeCurrentText` | 真实工作区保存与保存后重载；失联和目标身份校验 | `NativeDiffTabTests`、`GitUncommittedActionTests` |

历史性能日志：`build/git-diff-verified-hunks-final-targeted.log`
（24k 行模型 Staged 约 199 ms、Unstaged 约 243 ms，30 次中位）；
`build/git-diff-cold-layout-before.log`（24k 行首次全文布局约 206 ms）；
`build/git-diff-verified-hunks-full-host.log`（旧提交的 843 项，16 跳过、0 失败）；
`build/git-diff-verified-hunks-ui-repeat.log`（5 项 GUI 复测通过）；
`build/git-diff-preflight-full-host-after-cleanup.log`（`a9fdb51b` 清理后完整宿主
843 项、16 SSH 跳过、0 失败、约 592 秒）；另有 `build/git-diff-preflight-dead-display-test.log`
（84 项，1 SSH 跳过）和 `build/git-diff-preflight-dead-display-adjacent.log`（37 项）。
以上只能证明对应代码提交和环境的当前结果，不是未来实施提交、独立 GUI／SSH／Release 的验收。

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
   附加打开慢仓库→马上切换／关闭→连续重开，分别观察
   `DiffTab.reloadGeneration` 与 `GitStatusModel.statusRequestID` 已失效后，
   实际 Git/SSH 进程仍运行的数量、传输字节和完成时间；
   区分后台状态刷新仍被其它 Git 面板消费、与无人再需要的旧 Diff 读取，
   不能因某一视图不显示就贸然取消共享状态任务。
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
**Uncovered：** Windows SSH 已获授权且现可连接；真实 Git 状态刷新、受控故障恢复及
Diff 编辑保存已有独立证据，但尚未覆盖真实物理断线、SSH 在途取消与全部来源／边界，
由 P4-T3 补验。历史版本的完整正式 App 未必持有独立焦点，当前专用 Dev 验收为准。

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
3. 先辨清**自然段落与 Git LF 行是两种索引**：
   `NativeTextLineIndex` 利用 `NSString.getLineStart` 计入原生段落分隔符，
   `TextCoordinateIndex` 按 LF 计行；Diff 的 `lineStartOffsets/editSnapshotOffsets`
   已经保存来源 UTF-16 行起点。验证采用哪个现有数据可正确反查当前片段的 Git 行号，
   只在没有稳定起点的路径设计最小增量映射，绝不把裸 CR／U+2028 段落数直接当 Git 行号。
   消除每帧从文首枚举原生段落；非 LF 换行种类只随相关编辑范围变化而更新，
   不另建第二套全文索引。
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
4. 实机与窗口级源码共同确认：`WorkspaceWindowModel.canFind/canReplace`
   仍按旧“Diff 只读”模型禁用原生 Find，`performFindAction` 也忽略 `.diff`。
   这使 P1 无法验证真实 Find/Replace 输入语义；将**现有原生查找栏的菜单接线**
   作为本任务必要的测试前提先 Red→Green 修复，复用 FileTab 的
   `NSTextFinder` 行为和当前可见 Diff TextKit pane，
   覆盖 Staged／历史只读、Worktree 可编辑、Split 焦点和切回隐藏 pane。
   不在此重写折叠坐标或另造查找引擎；新的可达 Find 的复杂隐藏区作用域
   仍归 P2-T3。测试及生产的最小改动原子提交并同步实际文档。
5. 记录 Red 的真实磁盘和隐藏原文字节及折叠状态；
   P2-T2／P2-T3 按事实分别收敛输入成本与编辑边界。
   若原生 API 无法提供足够变更信息，说明替代成本和数据竞争边界，不先复制整套 buffer。

**验证：** `make test:NativeDiffTabTests,NativeEditorCompositionTests,TextCoordinateIndexTests,WindowOwnershipIntegrationTests,FileTabPersistenceTests`；
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
3. 复盘已验证 Git hunk 快路径在 0 上下文、重复行、CRLF、clean filter
   及并发编辑时的字节和行号语义；`hash-object → git diff` 保持必需顺序。
   **另设 Staged 反例**：在并行的 HEAD tree 与 Index blob 读取之间移动 HEAD／重写 Index，
   测两侧虽各自 OID 完整但共同逻辑快照可能已过期；必须验证是否需要最小再校验，
   不把两个独立不变 Blob 误称为一个原子仓库快照。
   验证实际 index／工作区并发改写后的重试安全，不只断言某单个 Blob 不变。
4. 测 `DiffComputation.build` 的全部投影和 `captureVisibleSyntax`／Neon，
   比较当前仅显示某一布局时真实新增分配、缓存版本、树重建、关闭标签后的 retained heap。
   额外量化 `DiffSyntaxHighlighter.queryCaptures` 为每个离散可见区间重新创建 query cursor
   的成本（1／10／100／1000 块）；验证解析复用不能只靠树缓存命中率。
   **补独立高成本候选：**`DiffComputation.build → DiffBlocks.blockEmphasis`
   会为每对修改行调用 `DiffIntraline.myersTokens`，它在 400-token 边界保存
   Myers trace，内部缺少单独的任务取消点；分别测每行 399／400／401 token、
   1／100／1000 对密集替换、重复折叠展开和中途取消的 CPU、峰值分配与结束时间。
   简单稀疏改动投影约 0.17 ms，**不能直接推断极端行内差异也如此**；
   只对实测高成本的重复计算与不可及时取消作最小修复，不为设计洁癖重构。

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
   当前 `DiffDisplay` 已没有 `hasCollapsedContext`，不再把已删除的旧字段列为待清理；
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

<a id="p1-t6"></a>
## P1-T6 移除生产语法高亮中的测试专用全量入口

**依据：** R5 明确允许在技术准入前清理独立、已证实的无生产消费者代码。
CodeGraph 与全文引用均证明 `DiffSyntaxHighlighter.captures`、
`highlightByteLimit` 只被宿主测试调用；生产只经 `DiffSyntaxSource.captures` 查询显式区间。
本任务不算 P3-T4 完成，也不声称改善首屏性能。

**实施：** 删除生产静态全文入口、1.5 MB 旧限制及可选区间回退；
全文测试 oracle 放在 `BaileyTests/Git/DiffSyntaxOracle.swift`，直接完整解析和查询，
不调用生产的范围查询函数；实际可见捕获、语言颜色和大文件断言改测 `DiffSyntaxSource`。
保留当前 2 MB 解析树缓存边界与 5 MiB Diff 输入上限。

**验证：** 先运行原有高亮／Diff 基线，迁移后定点运行相关原生语法测试与
完整 `NativeDiffTabTests`，再执行全量宿主、Debug 构建及签名。
没有产品行为或文档契约变化；不能把实验候选代码加入本任务提交。

**提交：** 仅生产死代码、测试 oracle 和原断言迁移；其余 P1 计时断言另行提交。

## Phase Gate

全部 P1 tasks 核销后，按仓库流程进入阶段审计；实际审计开始时才创建
`audit-p1.md`。TextKit P0 与原生编辑链的实验若无可验证方案，
**不能以“探索完成”判定生产问题已解决**；保留 No-Go 及反证，
修订当前 P2 实施方案再进行下一轮准入。
Git 延迟如果已证实由可消除的串行启动主导，P3-T1 必须给出相应实现与
同条件中位／P95 验收；不准把该根因留为不明确的“以后优化”。
任何已否决路线同步从实施计划移除，不保留兼容后门。
