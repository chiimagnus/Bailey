# P3：Files 与 Git 的 MVVM／Observation 纵向迁移

**Goal：** 完成文件树、Git 状态、读写操作和破坏性动作确认的职责分离，形成可被当前及后续窗口层直接消费的 `@Observable` ViewModel；保留 Files/Git 共用的树交互。

**Non-goals：** 不修改 Git 语义、目录显示规则或新增 Git 功能；不以本阶段为由迁移整个窗口／终端；没有可验证收益不重写 Git 执行器。

**Approach：** 先完成文件树的独立状态与 UI，再以“查询、写操作、确认”三个已经存在的职责边界收敛 Git。已有 `WorkspaceBackend`、`GitCommandExecution`、`TreeDisplayModel` 是唯一复用起点；若确需新增 Git service 只承载实际 IO，不制造空协议或第二个 runner。每个 Task 自带接入与旧代码删除。

**Acceptance：** Files/Git 在 Observation 下直接更新，rename/new/delete、Git refresh、stage/unstage、commit、discard、diff、提交历史和同名仓库身份行为不变；原本混在 View 中的底层文件系统访问与 Git 安全校验已迁走；共享树仍只有一套。

**Rules：** `docs/EDITOR.md`、`docs/GIT.md`、`docs/PROJECTS.md`、`docs/SECURITY.md`；远端读取、超时、目录切换、失败重试和用户确认必须保持，不能将远端失败降级成对本机执行。

---

<a id="p3-t1"></a>
## P3-T1 文件树状态转 Observation，文件操作归入 ViewModel／Backend

**Files／锚点：** `kero/Files/FileTreeModel.swift::FileTreeModel.sync/rebuild/rename/commitDraft/moveToTrash/delete/presentError`，`kero/Files/FileTreePanel.swift::FileTreePanel/FileTreeRow`，`kero/Workspace/Project.swift::fileTree`、`kero/UI/Panels/ToolPanelView.swift`，`KeroTests/FileTreeTests.swift`、`KeroTests/PanelContextTests.swift`。

**当前问题：** `FileTreeModel` 虽是状态与动作持有者，却把后台 Workspace IO、错误原生弹窗和 `@Published` 混在一起；`FileTreePanel` 依赖 `@ObservedObject`。

**实现：** 明确它是视图模型，可按真实命名需要统一为 `FileTreeViewModel`；域树 `TreeDisplayModel` 保持纯数据和唯一共用。转换 `@Observable`、用 `@State`／`@Bindable`／直接读取更新 Files 视图；后端 IO 继续走已有 `WorkspaceBackend`，在 ViewModel 记录操作错误并由 View 负责实际对话框，不让 VM 调 `NSAlert`。保持 `sync` 的机器与根目录作用域、`rebuildPending` 单路合并及 rename/创建失败的真实结果。**同 Task 删除旧模型类型与 `@Published`、视图旧包装器和 `presentError` 中的 UI 调用**；不留下同名兼容转发类。

**验证：** `make test ONLY_TESTING=KeroTests/FileTreeTests`、`make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`，必要处补错误／取消后 View 更新测试；`make build`、隔离 UI 中大目录、压缩树和内联重命名。验证结果为实际文件创建／更名／删除，而不只检查视图状态。

**提交：** 新状态与真实操作、视图绑定、旧实现删除和测试一次提交。

---

<a id="p3-t2"></a>
## P3-T2 Git 状态／读取刷新统一成可观察 ViewModel

**Files／锚点：** `kero/Git/GitStatusModel.swift::GitStatusModel.sync/refresh/loadMoreCommits`；`kero/UI/ContentView.swift::git`、`kero/UI/Panels/ToolPanelView.swift`、`kero/Git/GitPanel.swift`、`kero/Git/RecentCommitsView.swift`、`kero/UI/Components/BottomToolbarView.swift`、`kero/Files/FileTreePanel.swift`；`KeroTests/GitStatusModelTests.swift`。

**当前问题：** 窗口级 Git 状态目前由临时 `ContentView.@StateObject` 持有，多个 UI 通过 `@ObservedObject` 消费；仓库身份、刷新批次、折叠与草稿状态在一个混合类里。全链路迁移必须保持**窗口级唯一持有者**，并保护在途刷新不会覆盖操作后的状态。

**实现：** 让既有 Git presentation owner 成为 `@Observable` ViewModel（若重命名为 `GitViewModel`，同 Task 改完所有引用和测试，无旧类 alias），纯 Git 数据类型可留在同一文件或按确有职责边界移动。窗口唯一 owner 不再放在短生命周期 `ContentView`；用现有 `TerminalManager` 窗口实例持有该状态并从 UI 读取，供 P5 正式窗口 MVVM 收敛。查询仍复用现有 Git 执行通路，保留 `contextGeneration`、`statusRequestID`、`refreshPending`、`cachedStatusByRoot`、远端批量请求以及最近提交分页。**移除所有已迁移 Git 视图的 `@ObservedObject`／`@Published` 和废弃状态别名，不复制第二份 Git 状态。**

**验证：** 更新后的 Git XCTest（原 `KeroTests/GitStatusModelTests.swift`），`KeroTests/GitExecutionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`；补在途刷新、提交后事件、仓库切换和无 HEAD 仓库的结果检验。验证内容包括仓库字节、真实索引／工作区状态与历史分页；`make build`。

**提交：** Git 窗口 owner、观察方式、所有消费者同步迁移及旧 UI 状态接线清除。

---

<a id="p3-t3"></a>
## P3-T3 将 Git 变更操作与执行副作用收敛到既有服务边界

**Files／锚点：** `kero/Git/GitStatusModel.swift::stage/unstage/discardChanges/commit/fetch/pull/push`（重命名后使用新 ViewModel 文件）、`kero/Git/GitCommandExecution.swift`、`kero/Workspace/WorkspaceBackend.swift::run`、`kero/Remote/SSHWorkspaceBackend.swift`、相关 Git XCTest。

**当前问题：** 现有状态类直接编排底层 Git 读写与进程执行，UI 动作、错误和运行状态耦合；不能因为换用 Observation 就继续把低层 IO 留在 ViewModel 内。

**实现：** ViewModel 负责用户动作、状态、业务命令顺序和异常呈现；需要 IO 的路径委托现有 `GitCommandExecution`／`WorkspaceBackend`，如果现有接口不足只在真实共同执行处补一个具体 Git service，不能复制进程 runner 或为唯一实现造 protocol。迁出原底层调用时**同 Task 删除原 ViewModel 中被替换的 IO 分支**；保留本机 login-shell PATH 获取、argv/literal pathspec、二进制和 NUL 解析、限流、超时、锁与重试边界，以及远端语义。写前重新验证机器、仓库、HEAD、路径、操作独占与请求代次，成功后刷新，失败保留草稿与可读的输出。

**验证：** `make test ONLY_TESTING=KeroTests/GitExecutionTests`、更新后的 Git XCTest；用临时真实仓库验证 stage、unstage、首次提交、重命名、discard、超时、commit 期间改草稿、错误输出和切仓库；不能通过“命令发出”代替 Git 实际结果。执行后 `make build` 并验签。

**提交：** Git IO 收敛、旧执行路径删除、测试同一次提交。

---

<a id="p3-t4"></a>
## P3-T4 把 GitPanel 的丢弃预检移出 View 并保留交互确认

**Files／锚点：** `kero/Git/GitPanel.swift::FileFingerprint/PendingDiscard/makePendingDiscard/discardSnapshotIsCurrent/fileFingerprint/remotePendingDiscard/remoteDiscardSnapshotIsCurrent/prepareRemoteDiscard`；当前 Git ViewModel／`WorkspaceBackend`；`kero/Git/RecentCommitsView.swift`、相关 Git XCTest。

**当前问题：** `GitPanel` 自己读取本机元数据、向远端发 stat，并在异步准备过程中生成待丢弃快照；`NSAlert` 仍在 View。把所有这些都留在 View 会违反 MVVM，直接移动弹框到 VM 又违反 UI 边界。

**实现：** 把指纹、目录和历史状态防护放到 Git ViewModel／既有文件后端，呈现可供 View 消费的待确认操作与忙碌／失败状态；View 只负责显示确认、取消及把确认结果回传。按准备时的机器／仓库／HEAD／文件指纹在**执行前**再校验，不允许切仓库后确认旧动作；保留本机垃圾篓与远端彻底删除的不同提示。**同 Task 从 GitPanel 删除 `FileFingerprint`、`PendingDiscard` 的业务计算、`FileManager.stat`／远端 IO、旧 loading 状态和重复检查**；与 `RecentCommitsView` 共用的树行不复制。

**验证：** 更新的 Git XCTest 与 `KeroTests/TreeRowHitTestingTests.swift`；含等待确认时目标变化、远端连接失效、未跟踪文件／符号链接和取消无副作用；必要时隔离原生确认框检查，`make build`。用户不授权时不触碰真实工作树。

**提交：** 丢弃准备／执行链与确认 UI 接线、旧 View 业务清除和测试同一次提交。

---

## 阶段完成门槛

Files 和 Git 不再由短生命周期 View 直接执行后台文件／Git IO；状态仅有一份，UI 与命令路径都使用新 owner。所有旧代码清理随对应 T1～T4 即时完成，不留“最后统一清理”的任务。
