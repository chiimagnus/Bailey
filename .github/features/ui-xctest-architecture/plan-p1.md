# P1｜让 Git 图谱与原生操作的验证回到正确层次

**交付：** 优先消除 Git UI 测试中已量化的多余 AX 往返，
再让已有真实 Git／原生宿主测试承担重复的状态与条件断言。
必须通过 Bailey Dev 验证的拖动、菜单、键盘、Sheet、跨窗及 Git 副作用原样保留，
不重新构建一套完整 Dock／Git Panel 宿主框架。

## 现状与技术选择

2026-11-15 [Actions #43720420544](https://github.com/chiimagnus/Bailey/actions/runs/43720420544)
在 UI Job 被取消前完成 **136** 个方法：用例耗时合计 **3,348 秒（55.8 分钟）**、
**3 项失败**；其中 `GitDialogUITests` 22 项累计 **726 秒**，
`GitGraphGeometryUITests` 14 项累计 **563 秒**，
`GitGraphUITests` 34 项累计 **714 秒**。
这是**不完整的运行样本**，不是全套执行时间，更不是硬性能预算。
当前源码有 **229 个** `test*` UI 方法（Git 116、Files 51、Workspace 59、Editor 3）。
`WorkspaceUITestSupport.launch()` 每项独立启动并在 teardown 退出 App；
老日志有约 **2,991** 条等待 App 空闲记录。
对完整旧日志逐项配对计时：136 项共出现 **1,244 次**带超时的元素存在性检查，
仅这些检查就累计约 **1,277.5 秒（21.3 分钟）**；
另有 2,991 条「等待 App 空闲」记录（并不等于 2,991 次实际阻塞）。
App 开始启动前的夹具准备耗时中位约 **0.76 秒**，
第一个窗口出现中位约 **2.49 秒**；不能将进程重启当作首要瓶颈。
本次优化优先针对可观察的重复 AX 查询，不把全部 21.3 分钟视为可删开销。

历史决定不可忽略：

- `6853d342` 曾删除旧 `RecentCommitsViewTests` 的 37 个孤立视图宿主方法，
  将真实 Dock 窄栏与原生菜单交给 App 测试；
  恢复旧整套宿主视图可能重现同样的假阳性。当前已有
  `NativeContentIdentityIntegrationTests.testEveryDockHeaderExposesARealBlankWindowSurface`
  和 `testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing` 的真实原生组件测试。
- `6506193c`、`d7b55e0d` 已将 Git 原生表单与图谱条件迁入宿主；
  `GitNativeDialogTests.testCommitActionsExposeNativeSafeDefaultsAndMergeParentSelection`
  检查真实 NSAlert 的 Checkout／Cherry-pick／Revert／Merge／Rebase／Reset 默认值。
  `CommitGraphLayoutTests.testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts`
  已覆盖宽度 48～800、9／18pt 和 0～1000 车道；`GitGraphPaletteTests`
  已遍历 60 个主题。**不能为重复这些矩阵再设计新宿主。**
- `0c64b23e`、`1113f6a8` 曾尝试跨方法复用 App，
  `add2a99b` 改为每项独立进程与项目预载；
  当前 `launch` 的同一方法内缓存仍由
  `WorkspaceSmokeUITests.testRepeatedLaunchDoesNotResetTheCurrentTestProject` 使用，
  不能把它误判为未删除的跨方法兼容分支。

真实路径为 `BaileyUITests/Support/WorkspaceUITestSupport.launch`
→ `Bailey Dev` 的 `WorkspaceDockView.DockTreeView`／`GitPanel`
→ `RecentCommitsView`、`Git*Dialog`、`GitStatusModel`
→ Git 的 HEAD／Ref／Index／Worktree 或具体窗口／菜单结果。
宿主已有 `CommitGraphLayoutTests`、`GitGraphPaletteTests`、
`GitNativeDialogTests`、`GitRemoteBranchActionTests`、
`GitStatusModelTests`、`NativeDiffTabTests`、`GitUncommittedActionTests`。
断言由哪一层负责，必须沿这条路径核对，不能按测试标题机械归类。

## 任务

<a id="p1-t1"></a>
### P1-T1｜固定全量方法账目和可比较的性能基线

- **位置：** `BaileyUITests/Editor`、`Files`、`Git`、`Workspace`；
  `BaileyUITests/Support/WorkspaceUITestSupport.swift`；
  `Makefile` 的 `test:ui`；现有 CI `.xcresult`。
- **实施：** 一次性列出 229 个真实 UI 方法及所有 18 个测试类，
  排除 `UITestSessionObserver.testBundleDidFinish`（不是 XCTest 方法）。
  按实际断言而非标题确认「已有宿主负责」「混合断言」「独占完整 App」；
  对准备改动的具体方法写出对应宿主方法和必须保留的 GUI 入口，
  **不为没有迁移打算的用例编造 229 行跨文件永久映射表**。
  用旧 CI 的实测耗时、1,244 次存在性检查、App 启动与等待日志
  定位最重的多余往返；每次修改一项时记录自身前后耗时和最终结果。
  旧工作流被取消，仅作为分组和方法的部分样本；取得完整可比基线后再估总耗时。
- **判据：** 所有源码方法都已清点；拟删／拟缩的每项断言可追到
  已存在或同任务新加的具体宿主测试，以及剩余的真实 App 接线。
  不迁移的 UI 方法保留原有测试与断言，不为填表而改造。
  可从 CI 日志独立重算数据；被取消的旧运行不写成完整基线。

<a id="p1-t2"></a>
### P1-T2｜消除 Git 图谱原生菜单的重复 AX 查询，保留真实命中

- **位置：** `BaileyUITests/Git/GitGraphGeometryUITests.swift` 的
  `testAllThirtyThreeRemoteReferencesRemainInTheNativeOverflowMenu`、
  `verifyDivider`、`verifySpecialGraphColors`、
  `testOverflowBranchWorktreeActionRebindsAfterExternalRefresh`；
  已有 `BaileyTests/Git/CommitGraphLayoutTests.swift`、
  `GitGraphPaletteTests.swift`、`GitGraphReferenceGroupTests.swift`、
  `GitGraphWorktreePresentationTests.swift`、
  `BaileyTests/Workspace/NativeContentIdentityIntegrationTests.swift`。
- **实施：** 当前 33 Remote 用例 55.8 秒，其中循环
  **33 次** `reference.waitForExistence(timeout: 8)`；
  先记录现有成功用例的菜单 AX 查询耗时，再在菜单真正展开后，
  从**当前原生菜单**读取一次可见项集合并核对 33 个不同名称。
  必须核实原生菜单是否懒加载、菜单项是否全量可见，以及新方法
  是否实际减少 AX 往返；若不成立，保留原有必要的逐项检查。
  最后一项仍要 hover／click／复制，检查剪贴板、真实 Ref／HEAD／Index。
  同时逐条核查 `verifyDivider` 是否有纯计算层重复检查；
  当前实际 App 的字号加载、分支宽度、像素与菜单仍是独立 GUI 证据，
  **不能**因底层 `CommitGraphLayoutTests`／`GitGraphPaletteTests` 已通过就删除。
  **保留**实际 420／260／150／320／150 pt 分隔条拖动、
  命中区五点点击、独立 Copy Hash 和真实主题／字号交互。
  `testOverflowBranchWorktreeActionRebindsAfterExternalRefresh` 的
  10 秒刷新停留有明确并发前提，不当作无用 sleep 删除。
  `GitGraphGeometryUITests` 的手动 Clipboard 备份与
  `WorkspaceUITestSupport.launch` 的统一恢复可能重叠；
  检查 teardown 顺序与实际写入时机，证实等效后在**本任务**删除冗余备份，
  保留原类型的系统剪贴板恢复。
- **判据：** 33/33 原生菜单项、最后一项可操作及拷贝、
  窄栏、真实拖动、整行与独立按钮命中、主题像素、最终 Git 字节不退步；
  比较单项耗时和 AX 往返次数，失败自动保留诊断。
  旧 CI 的 `testRealDividerResizePreservesCompactBranchMenuAndWholeCommitHitArea`
  必须重验；结合 `DockTreeView.divider` 的真实手势及
  `NSWindow.isMovable` 判断是产品问题还是用例前提错误，
  不通过增加超时或删测试制造绿色。
  同一任务移除被替代的循环／重复 helper；
  **不新建全量 Dock 宿主框架，不恢复旧 `RecentCommitsViewTests`**。

<a id="p1-t3"></a>
### P1-T3｜收紧 Git Graph 导航断言，保留真实 40 行可见性回归

- **位置：** `BaileyUITests/Git/GitGraphUITests.swift` 的
  `testGraphKeyboardNavigationKeepsFortyHistoricalFilesVisible`、
  `testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit`、
  `testChineseGraphNodeAndReferenceMenusRetainTheirExactCopyTargets`
  及其它当前图谱用例；
  `Bailey/Git/RecentCommitsView.swift` 的 `selectRow`、
  `focusRow`、`toggle`、`handleGraphKey`；
  `BaileyTests/Git/GitStatusModelTests.swift`、
  `CommitGraphLayoutTests.swift`、`GitGraphReferenceGroupTests.swift`。
- **实施：** 对照 34 项图谱 UI 中的每种真实输入，先确定哪些
  Git 拓扑、分页、历史文件、Stash／Worktree 身份和状态矩阵
  已由现有宿主测试覆盖；仅下沉缺失的真实数据断言。
  40 行用例虽在旧 CI 耗时 **68.8 秒**，但它每次真实按向下键后
  检查该行是否滚进窗口，属于宿主无法证明的**逐步 UI 滚动不变量**；
  保留 40 次键盘操作和必要的可见性／未选中检查，
  先在可重复环境记录每次 AX 请求时长再决定是否优化查询结构。
  对多处可重用的同一菜单，优先在单次真实展开中验证完整标签集合，
  不为每种静态状态重新启动 App；但右键目标、真实复制、滚动、
  Changes→Graph 焦点与不同项目之间的状态隔离仍必须由 Dev 验收。
  如果某个 UI 方法的所有数据断言已有充分宿主覆盖，且唯一真实入口
  也由其他 UI 方法证明，在**本任务**删除该方法及其专用 helper；
  其它混合方法只移除确实重复的 AX 步骤，不能整项删掉。
- **判据：** Git HEAD／OID、文件路径、Merge parent、
  `Focus`／`Selection`／`Context Target` 分离、
  历史列表可见范围、原生滚动、真实菜单和复制行为都不退步。
  保留密集车道、长中文和真正跨项目／窗口的原生接线，
  但不再在 UI 重做宿主已经遍历的全部数值组合。
  无充分替代证据时不减少 40 行真实按键／可见性检查。

<a id="p1-t4"></a>
### P1-T4｜删除重复的原生 Sheet 状态检查，保持各项实际路由

- **位置：** `BaileyUITests/Git/GitDialogUITests.swift`、
  `GitUncommittedUITests.swift`；
  `Bailey/Git/GitPanel.swift` 原生 Sheet 分发、
  `GitBranchDialog.swift`、`GitCommitDialog.swift`、
  `GitTagDialog.swift`、`GitStashDialog.swift`、
  `GitUncommittedDialog.swift`；
  `BaileyTests/Git/GitNativeDialogTests.swift`、
  `GitRemoteBranchActionTests.swift`、`GitUncommittedActionTests.swift`、
  `GitCommitActionTests.swift`。
- **实施：** 旧 CI 的
  `testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory`
  用例 **83.5 秒**，其中约 **47 次元素存在性检查累计 48.6 秒**。
  `GitNativeDialogTests.testCommitActionsExposeNativeSafeDefaultsAndMergeParentSelection`
  已实际构造 Checkout／Cherry-pick／Revert／Merge／Rebase／Reset／Drop 的
  NSAlert，核对各自默认开关、父提交选项、快捷键及危险模式。
  首先比对每项断言，既有宿主充分的状态不要再通过 GUI
  逐项打开 Sheet 查一遍；但需核对**七种菜单动作各自能否正确映射到对应 Sheet**：
  如没有其它 Dev E2E 覆盖某项路由，不能删除它在本用例中的唯一检查。
  检查可否一次展开实际 Commit 菜单完整核对所有动作，
  各 Sheet 只执行不可替代的前台提交、取消、键盘选择与目标窗口绑定。
  其他 21 个 Git Dialog UI 方法逐一按实际危险操作区分，
  Branch／Tag／Remote／Stash 的 Ref/OID 失效、重试输入、真实 Push
  和交互式 Rebase PTY 继续保留真正的 App 操作。
  迁移当次删除冗余 Sheet 展开／等待／仅为旧流程存在的本地函数；
  复用原生 `Git*Dialog`，不抽象新的统一 Dialog driver。
- **判据：** 七种 Commit Action 的菜单入口、各自原生 Sheet
  及独特操作状态仍可验证；未确认、取消或旧 Ref 被修改不能产生误写；
  实际确认后的 HEAD／Ref／Index／Worktree 与文件原字节正确。
  明确记录每种删除的 UI 断言对应的宿主方法和未删除的真实菜单→Sheet→Git 路由。
  单项耗时、AX 查找次数下降且不牺牲真实危险操作验收。

<a id="p1-t5"></a>
### P1-T5｜精简 Changes／History／Diff 的重复 AX 步骤，不缩减真实链路

- **位置：** `BaileyUITests/Git/GitChangesUITests.swift`、
  `GitHistoryUITests.swift`、`WorkspaceGitUITests.swift`、
  `GitIgnoreEditorUITests.swift`；
  `Bailey/Git/GitPanel.swift`、`GitStatusModel.swift`、
  `DiffViewerView.swift`；
  `BaileyTests/Git/GitStatusModelTests.swift`、
  `NativeDiffTabTests.swift`、`NativeGitHistoryFileTests.swift`、
  `GitExecutionTests.swift`、`GitIgnoreIntegrationTests.swift`。
- **实施：** 逐项核对 Git Changes **28**、History **5**、
  Workspace Git **9**、Ignore Editor **1** 个 UI 方法。
  通过已有真实 Git 宿主测试覆盖：分支与索引快照、变更区段、
  Staged／Worktree 同路径、Merge 冲突、目录批量多选、过滤器、
  CRLF／二进制、历史文件差异与过期目标操作。
  但 App 中的 Cmd／Shift 多选、右键菜单目标、快捷键、
  真实文件打开、Diff 编辑输入与 Dock／项目交接是独立用户入口，
  不能用模型数字正确就删掉。
  对已被宿主覆盖的重复完整 AX 遍历改用当前真实状态的单次有效检查，
  并在**同任务**删除因此失效的私有测试 helper／旧流程；
  如果长流程逐步验证不同实际焦点和时序，则保持其动作不变。
  `GitIgnoreEditorUITests` 的真正 ⌘Z、保存与最终字节继续保留。
  `testRealBaileySourceHistoryDiffLoadsAcrossIndexWorktreeAndOtherSource`
  使用真实历史提交，CI 必须保留 `fetch-depth: 0`。
  不额外修改 Git 模型或编辑器来迎合测试时长。
- **判据：** Git Status／Index／HEAD／Ref／Worktree、历史版本
  和 Diff 原字节保持正确；GUI 中不同键盘所有者／窗口、
  多选菜单、取消、重新加载和原生编辑动作仍有实际运行的证据。
  只在每个方法得到等效结果后移除冗余查询或方法，
  每项迁移即删除旧测试代码，而非留待 P3 统一清理。

## 阶段验收

按 [测试完成标准](../../../docs/testing.md#完成标准)
核对下列相互独立且适用的条件；有限可行组合全部执行，昂贵组合由宿主广覆盖，
由真实 App 验证只有完整进程能证明的那一层：

| 行为 | 必测条件与极端边界 | 最终证据 |
| --- | --- | --- |
| 图谱与命中 | 150／420 pt、9／18 pt、明／暗、短／长中文、0／12 Worktree、0／33 Remote、空仓库、复杂合并与密集车道 | 真实 Dock／NSWindow 像素、行可见与按钮可命中，UI 真实分隔条与菜单 |
| 历史／引用 | 普通／根／合并提交、Detached／Unborn、Tag／Stash、SHA-1／SHA-256、共享／失效 Worktree、分页与旧 Ref | 真实 OID、文件原字节、图谱连接和显示／展开／菜单目标 |
| Git 写操作 | Stage／Unstage／Discard／Commit、Branch／Tag／Remote、Reset／Clean／Stash、Push／Pull／Rebase；成功、取消、超时、竞争刷新及外部变更 | Index／HEAD／Ref／Worktree 逐项前后对照，失败不误写 |
| GUI 生命周期 | 菜单跟踪期间快捷键、焦点／Selection／Context 独立、跨 Dock／项目／窗口、深浅主题与语言 | Bailey Dev 前台键鼠、真实 Sheet／菜单、截图及目标窗口结果 |
| 数据与失败 | Unicode、CRLF、clean filter、二进制、同名不同路径、旧目标、SSH 断线／重连、非当前机器操作 | 文件原字节、路径与机器身份、禁止失效操作、可恢复草稿 |

- 宿主定点使用仓库已有 `make test:类名1,类名2`，至少覆盖
  `CommitGraphLayoutTests`、`GitGraphPaletteTests`、`GitNativeDialogTests`、
  `GitStatusModelTests`、`GitRemoteBranchActionTests`、
  `GitUncommittedActionTests`、`NativeDiffTabTests` 的受影响方法。
  相应 Red→Green 证据、`make build:ui` 与实际发现的测试方法均需保存。
- 真实 App 在**独占的隔离 GUI 会话**运行剩余相关
  `BaileyUITests`，包含已知真实失败；需要 CI 时使用既有
  `ci-ui-*` 入口，推送与触发另遵守授权边界。
- 没有可授权的真实 Windows SSH、系统深浅切换权限或独立 GUI 时，
  分别记录对应方法／条件、原因、宿主替代证据、影响与补验入口；
  关键前台路径未完成不得宣称 P1 全部通过。
  本阶段不因目标提速而跳过这类条件。
