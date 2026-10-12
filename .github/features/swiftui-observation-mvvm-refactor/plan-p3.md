# P3：Files 与 Git 的 MVVM／Observation 纵向迁移

**Goal：** 完成文件树、Git 状态、读写操作和破坏性动作确认的职责分离，形成可被当前及后续窗口层直接消费的 `@Observable` ViewModel；保留 Files/Git 共用的树交互。

**Non-goals：** 不修改 Git 语义、目录显示规则或新增 Git 功能；不以本阶段为由迁移整个窗口／终端；没有可验证收益不重写 Git 执行器。

**Approach：** 先迁移现有 `FileTreeModel`（已有 WorkspaceBackend 执行 IO），再迁移已具备完整 Git 业务编排的 `GitStatusModel`，最后把 GitPanel 真正越界的本机/远端文件指纹预检移入该模型。`GitCommandExecution`、`WorkspaceBackend` 和 `TreeDisplayModel` 已是足够的真实分层，**不新增 Git Service、Repository 协议或第二套执行器**。仅删除已被直接替代的代码，不因类名含 Model 就重命名所有文件。

**Acceptance：** Files/Git 在 Observation 下直接更新，rename/new/delete、Git refresh、stage/unstage、commit、discard、diff、提交历史和同名仓库身份行为不变；原本混在 View 中的底层文件系统访问与 Git 安全校验已迁走；共享树仍只有一套。

**Rules：** `docs/EDITOR.md`、`docs/GIT.md`、`docs/PROJECTS.md`、`docs/SECURITY.md`；远端读取、超时、目录切换、失败重试和用户确认必须保持，不能将远端失败降级成对本机执行。Files/Git 的树结构、行高/命中区、颜色、右键菜单、错误/确认弹窗和快捷键，必须与 P1 基线逐项一致，不增加提示或改交互。

---

<a id="p3-t1"></a>
## P3-T1 文件树状态转 Observation，文件操作归入 ViewModel／Backend

**Files／锚点：** `kero/Files/FileTreeModel.swift::FileTreeModel.sync/rebuild/rename/commitDraft/moveToTrash/delete/presentError`，`kero/Files/FileTreePanel.swift::FileTreePanel/FileTreeRow`，`kero/Workspace/Project.swift::fileTree`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/ContentView.swift::ContentView`，`KeroTests/FileTreeTests.swift`、`KeroTests/PanelContextTests.swift`。

**当前问题：** `FileTreeModel` 虽是状态与动作持有者，却把后台 Workspace IO、错误原生弹窗和 `@Published` 混在一起；`FileTreePanel` 依赖 `@ObservedObject`。

**实现：** `FileTreeModel` 已是文件树展示与动作的唯一 ViewModel，**保留名称和现有职责**，使用 `@Observable`，View 直接读取属性、绑定时才用 `@Bindable`。其真实文件 IO 本就委托给 `WorkspaceBackend`，不再增设文件 Service；仅把 `presentError` 里直接创建 `NSAlert` 的界面工作移到**本 Task 就建立且持续挂载的所属窗口 UI 入口**：在现有 WindowRoot/ContentView 上以最小闭包或可消费的操作错误状态呈现，不增设 ErrorBus、全局 AlertManager 或另一套 File ViewModel；后续 P5 的其它原生弹窗复用同一真实窗口归属。**搬迁 `NSAlert` 不等于更换 UI**：保持原有的模态/Sheet 方式、标题、正文、按钮顺序、默认操作、键盘等效键及出现时机；不可为了窗口归属改成新的警告样式、增加错误 Toast 或新增拦截。**不能只依赖 `FileTreePanel` 挂载**，因为 ⌘N、命令面板或外层标签工具栏也可在 Files 面板未显示时执行文件操作；异步失败时切换项目／窗口也不能将错误错投到别的窗口。保留远端删除由 View 向用户确认。保持 `sync` 的机器/根目录作用域、`rebuildPending` 合并，以及创建、重命名后的实际文件结果。**本 Task 同时删除 `FileTreeModel.@Published`、旧 `@ObservedObject`、VM 内旧 `NSAlert`/`AppKit` 引用与对应 Combine import**，不留兼容别名。

**验证：** `make test ONLY_TESTING=KeroTests/FileTreeTests`、`make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`，必要处补从 Files 面板可见和隐藏的两个命令入口出错时都确实能展示错误、取消不改盘的测试；`make build`、隔离 UI 中大目录、压缩树和内联重命名，并对照原生截图、右键菜单项、错误弹窗与键盘/鼠标操作基线。验证结果为实际文件创建／更名／删除，而不只检查视图状态。

**提交：** 新状态与真实操作、视图绑定、旧实现删除和测试一次提交。

---

<a id="p3-t2"></a>
## P3-T2 Git 状态／读取刷新统一成可观察 ViewModel

**Files／锚点：** `kero/Git/GitStatusModel.swift::GitStatusModel.sync/refresh/loadMoreCommits`；`kero/UI/ContentView.swift::git`、`kero/UI/Panels/ToolPanelView.swift`、`kero/Git/GitPanel.swift`、`kero/Git/RecentCommitsView.swift`、`kero/UI/Components/BottomToolbarView.swift`、`kero/Files/FileTreePanel.swift`；`KeroTests/GitStatusModelTests.swift`。

**当前事实：** Git 业务状态已由 `ContentView.@StateObject git` 在每个 WindowRoot 下持有，**不是多个 View 的临时状态**；Git 命令通过 `GitCommandExecution` 调用 `WorkspaceBackend`，`GitStatusModel` 只负责编排命令与更新展示状态。`statusRequestID/contextGeneration/refreshPending` 防止旧结果覆盖新仓库，必须保留。

**实现：** `GitStatusModel` 直接作为窗口作用域的 `@Observable` ViewModel，保留名称；由 `ContentView.@State` 稳定拥有（由 WindowRoot 安装），不要**无理由搬进 `TerminalManager`**，否则 Git 与窗口/恢复层反而耦合。读取、stage/unstage/commit/discard/fetch/pull/push 的命令顺序与 UI 结果仍通过已有 `GitCommandExecution` 和 `WorkspaceBackend`，不另做一层 Git Service；保留 `contextGeneration/statusRequestID/refreshPending/cachedStatusByRoot`、远端批处理、最近提交分页、仓库作用域的草稿和变更独占。同步更换 GitPanel、Files 装饰、工具栏、历史的直接数据读取；**在同 Task 删除全部 Git `@Published` 与相应 View 的 `@ObservedObject`/Combine import，不建立第二份 Git 状态**。纯 Git 解析结构只在确实与 UI 混用时小范围移动，不做无意义的重命名/分文件。

**验证：** `make test ONLY_TESTING=KeroTests/GitStatusModelTests` 与 `make test ONLY_TESTING=KeroTests/GitExecutionTests`，视影响复用 WorkspaceIdentityTests；临时真实 Git 仓库覆盖 stage/unstage/commit/撤销/初始无 HEAD、切仓库、在途刷新、草稿隔离和历史分页，检查实际 index/worktree/HEAD，而非只观察 `isBusy`。窗口内 Files 状态颜色和 Git 工具栏同步更新；此任务边界完成后 `make build`。

**提交：** Git 状态迁移、所有真实消费者接入、旧 Publisher/包装器删除和实际 Git 操作测试一并提交。

---

<a id="p3-t3"></a>
## P3-T3 把 GitPanel 的丢弃预检移出 View 并保留交互确认

**Files／锚点：** `kero/Git/GitPanel.swift::FileFingerprint/PendingDiscard/makePendingDiscard/discardSnapshotIsCurrent/fileFingerprint/remotePendingDiscard/remoteDiscardSnapshotIsCurrent/prepareRemoteDiscard`、`kero/Git/GitStatusModel.swift::discard/discardChanges/perform/trash`、`kero/Workspace/WorkspaceBackend.swift::stat/readSymlinkDestination`、`KeroTests/GitStatusModelTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前问题：** `GitPanel` 在 View 内执行 `FileManager` 指纹读取与 `WorkspaceBackend.stat` 远端预检；`PendingDiscard` 包含 HEAD、scope、指纹等业务核对，而 View 持有一次弹框的本地 `@State` 本身合理。`GitPanel` 里的创建分支 `NSAlert` 是正常 UI 呈现，不是需要迁走的业务 IO。

**实现：** 把 `FileFingerprint`、本机/远端 `PendingDiscard` 构建和**确认前重新校验**归入现有 GitStatusModel（使用已有 `WorkspaceBackend.stat/readSymlinkDestination` 或就地必需的本机元数据 API）；UI 的 `@State` 只保留弹框显示、过滤、展开等纯展示事实，不再持有一套业务校验算法，也不额外制造 `GitDiscardService`。用户确认时由 View 将已审核快照交回 Git Model，后者复验同一机器／仓库／HEAD／路径／指纹并执行；不能只检查 View 当前状态或先验证、挂起后切库又执行。**同 Task 删除 GitPanel 原有 `fileFingerprint/remoteFingerprint/makePendingDiscard/discardSnapshotIsCurrent/remoteDiscardSnapshotIsCurrent` 等 IO 与检查方法**，与 Git Model 原有 HEAD/仓库验证复用而非堆叠重复围栏。保留 Git 分支创建弹框和 remote 永久删除/本机移废纸篓两种确认说明。

**验证：** 更新的 Git XCTest 与 `KeroTests/TreeRowHitTestingTests.swift`；含等待确认时目标变化、远端连接失效、未跟踪文件／符号链接和取消无副作用；必要时隔离原生确认框检查，`make build`。用户不授权时不触碰真实工作树。

**提交：** 丢弃准备／执行链与确认 UI 接线、旧 View 业务清除和测试同一次提交。

---

## 阶段完成门槛

Files 和 Git 不再由短生命周期 View 执行低层文件/Git IO；两者沿用现有 Model/ViewModel 与 Backend/Execution，**不增加新的 Git Service 或窗口级 Git 镜像状态**。旧实现分别在 P3-T1、T2、T3 接替时即删，不留“最后清理”。
