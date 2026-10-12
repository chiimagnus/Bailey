# P4：远端连接与长生命周期内容对象迁移

**Goal：** 在不重建底层 Shell、编辑器和 WebView 的前提下，让 SSH 连接、终端、文件编辑器、差异编辑器和浏览器的展示状态通过 Observation 传递，保留原生事件适配层。

**Non-goals：** 不重写 Ghostty、TextKit、Pierre/WebKit 内核，不切换远端 SSH 协议，不承诺跨进程恢复正在运行的 Shell 或网页表单。

**Approach：** 首先迁移 remote connection 的生命周期事件，再转换依赖它的终端和各长寿命内容对象；每个任务**连同对应 View、PaneTab／Project 观察入口**一起改，替换的订阅在该任务清理。必须区分 `@Observable` 的展示／动作 ViewModel 与持有进程、原生 NSView／WKWebView／TextKit 的 runtime/service adapter；若现有类型混合两者，则在真实职责边界拆分，使用稳定一对一持有关系，不复制可写业务状态。用于 KVO、原生事件回调的适配可以继续存在。

**Acceptance：** 已迁移内容对象在 Observation 下更新；拖动标签、项目切换和重挂载不重启 Shell、丢失表单、撤销、文本或滚动；远程断线、只读、恢复与转发无误，清理各对象原先的 UI 发布器和无用转发。

**Rules：** `docs/TERMINAL.md`、`docs/EDITOR.md`、`docs/BROWSER.md`、`docs/PROJECTS.md`。native 视图由长生命周期身份持有；SwiftUI View 不拥有或重复创建这些实例。线程、WebKit delegate 与后台 SSH 事件必须按实际 actor 安全处理。

---

<a id="p4-t1"></a>
## P4-T1 SSH 连接和临时端口转发的可观察状态与断线事件

**Files／锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection.markConnected/markDisconnected/runSSH`；`kero/Remote/PortForwardController.swift::init/forward/forgetAll`；`kero/Terminal/TerminalSession.swift::beginRemoteConnection/endRemoteConnection/watchRemoteConnection`；`kero/Remote/SSHWorkspaceBackend.swift`、`KeroTests/RemoteLifetimeTests.swift`、`KeroTests/RemoteCommandsTests.swift`。

**当前依赖：** `PortForwardController` 订阅 `connection.$state` 后断开立即取消在途转发；`TerminalSession.remoteObservation` 转发 connection 的 `objectWillChange`，后续 Project 需要重绑文件／diff。直接移除 Publisher 将导致远端 UI 滞后或过期转发仍显示成功。

**实现：** `RemoteConnection` 的状态改用 Observation，但断线取消、子连接更新应在**实际状态变更处**调用已有会话／转发 owner 的明确回调。保留 connection 的唯一身份、control socket、RemoteCommandRunner、连接重绑定语义和端口请求合并；检查 `WorkspaceBackend` 的 `Sendable` 边界。**同 Task 移除 `PortForwardController.stateObserver`、`RemoteConnection.@Published`、已被明确事件替换的 `TerminalSession.remoteObservation`，同时更新受影响的 View／Project 触发点**，不能留下假定 Combine 仍然会推送的订阅。TerminalSession 仍需保留的其他 legacy UI 发布机制留给紧接的 P4-T2 迁移，不能再基于被删除的连接 publisher。

**验证：** `make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/RemoteCommandsTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；覆盖断线发生在 `forward` 等待期间、重复并发请求、旧连接复活不可回写新机器、同主机不同端口身份。受控测试不接触用户 SSH master；`make build` 并验签。

**提交：** 连接状态、明确副作用和所有失效订阅一次移除、验证后提交。

---

<a id="p4-t2"></a>
## P4-T2 终端会话和查找条的 Observation／原生事件桥

**Files／锚点：** `kero/Terminal/TerminalSession.swift::TerminalSession`、`kero/Terminal/TerminalFind.swift::TerminalFind`、`kero/Terminal/TerminalFindBar.swift`、`kero/Terminal/TerminalHostView.swift`、`kero/Terminal/KeroTerminalView+Ghostty.swift`、`kero/Workspace/Project.swift::sessionObservations/scheduleRemoteTabRebind`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前依赖：** Shell 进程、原生 surface、历史、查找及 SSH 事件由长生命周期 `TerminalSession` 所有；Project 借 `session.objectWillChange` 更新标题和远端重绑，ContentView／工具面板通过完成序列刷新 Git/Files。

**实现：** 保留 `TerminalSession` 当前长期进程与 `TerminalBackendSurface` 实际拥有的 Shell、NSView 和事件代理身份。沿生命周期边界决定：若 `TerminalSession` 作为 ViewModel，则把具体 native 创建／IO 委托给现有 surface/service 并仅持有展示状态；若仍承担 native runtime，则建立由同一 session 稳定持有、具有真实状态与动作职责的 `@Observable` 展示 ViewModel，不能把混合类直接改宏就称作 MVVM。用户可见标题、命令完成、连接状态单一归属且通过真实观察或语义事件供 Project／面板读取，不维护双份可写值；`TerminalFind` 同步迁移，重复聚焦与异步匹配保留 sequence/generation。**同 Task 删除被替换的 `TerminalSession/TerminalFind.@Published`、对应 View 的 `@ObservedObject` 与 `Project.sessionObservations` 旧订阅路径**，确保 P1 保存不依赖旧 Publisher。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`；新增或调整终端标题、命令完成事件、查找请求与远端断开恢复的最小测试。隔离原生检查停车宿主拖动后 Shell PID 和输入可用、通知跳转、⌘F 重复聚焦及选择不丢失；`make build`。

**提交：** 终端真实 owner + 观察边界 + 旧事件链移除同一原子提交。

---

<a id="p4-t3"></a>
## P4-T3 文件编辑标签的可观察状态与可靠保存

**Files／锚点：** `kero/Editor/FileViewerView.swift::FileTab/save/reloadFromDiskIfClean/refreshDirtyState`、`kero/Editor/SourceTextEditor.swift`、`kero/Editor/EditorFind.swift`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `FileTab` 持有编辑文本、保存基线和原生编辑视图；`text` 刻意不逐键发布，`isDirty` 变化却通过 `PaneTab.dirtyObservation` 驱动标签和保存按钮。旧读取不允许覆盖编辑中的缓冲区。

**实现：** 保留唯一长生命周期编辑会话／TextKit 视图；真实内容、基线、dirty、只读、saveError、reloadRevision 等展示与操作状态由 `@Observable` ViewModel 单独负责，底层 IO 走 `WorkspaceBackend`，原生编辑视图的创建／拖动预览指针留在 TextKit UI adapter，不让 ViewModel 持有或构建 NSView。可直接收敛 `FileTab` 的职责，若必须保留它为 native adapter 则由同一个标签稳定持有 ViewModel，禁止双份可写缓冲区；逐键编辑不使整个窗口重绘。读取／写入按发起路径、机器、代次校验。PaneTab／工作区**直接消费可观察 dirty 状态或接收语义通知**，不再依赖 `file.$isDirty`。**同 Task 删除 FileTab 旧发布属性、编辑 UI 的旧观察包装器、ViewModel 中不应出现的原生视图引用和 PaneTab 对 FileTab 的旧 Combine 订阅**。失败保存和关闭提示保留，不能在关闭前丢缓冲区。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；补脏标记转清、写中二次编辑、重命名后写新路径、断线只读、旧读取丢弃与保存失败不关闭。隔离原生检查 UTF-8／emoji／CRLF、撤销、查找、光标滚动；`make build`。

**提交：** 编辑状态链完整接入、旧 dirty Publisher 与重复状态删除同一提交。

---

<a id="p4-t4"></a>
## P4-T4 差异标签和 WebKit 渲染器的可观察状态

**Files／锚点：** `kero/Git/DiffViewerView.swift::DiffTab/DiffWebModel/DiffViewPreferences/DiffViewerView`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、相关 Git／Workspace／PaneRetention XCTest。

**当前依赖：** `DiffTab` 保留 repo、机器、提交元数据和可编辑工作区 diff；`DiffWebModel` 驱动独立渲染，`webHostView` 长期持有 WebKit 容器，`PaneTab` 通过 `diff.$isDirty` 显示编辑标记。

**实现：** 将差异内容、编辑标记、加载／错误等展示与业务动作交给唯一 `@Observable` ViewModel，Git 字节读取交给 P3 的真实 Git service／`WorkspaceBackend`；`DiffWebModel`／`webHostView` 承载的原生 WebKit 生命周期属于长期 native adapter，而非纯 Model 或 ViewModel。若拆分 `DiffTab`，保留原标签身份，并由其稳定持有 native adapter 与 ViewModel；可观察状态只由 ViewModel 一方写入，WebKit 的编辑回调仅做输入通知。保留按机器重绑、脏缓冲保护、渲染局部更新与完整 WKWebView 身份，不能因每次内容编辑重造渲染器。**同 Task 删除 DiffTab／DiffWebModel／DiffViewPreferences 被替换的 ObservableObject／@Published、DiffViewerView 旧包装器，以及 PaneTab 对 DiffTab 的旧 dirty Publisher**，不保留两套渲染状态。

**验证：** 更新的 Git XCTest、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；工作区／暂存／历史、UTF-8/二进制/5MiB 限制、未保存 diff、断线重连。隔离原生验证 WKWebView 真实首屏、滚动、diff 编辑/保存、切换后重新显示；`make build`。

**提交：** 差异状态／原生桥接／旧观察代码删除与回归一起提交。

---

<a id="p4-t5"></a>
## P4-T5 浏览器标签 Observation 与 WKWebView delegate/KVO 适配

**Files／锚点：** `kero/Browser/BrowserView.swift::BrowserTab/BrowserView/BrowserWebView`、`kero/Workspace/Project.swift::browserObservations`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前依赖：** `BrowserTab` 同时是 `NSObject`／`WKNavigationDelegate` 和持久 WKWebView owner；网页标题、地址、前进后退与 favicon 当前以 `@Published` 驱动，Project 还监听 `objectWillChange` 以便保存网址。

**实现：** 将 `BrowserTab` 的 WebView 持有、`NSObject`／`WKNavigationDelegate`／KVO 回调划为长寿命原生 adapter，把导航标题、URL、前后退、加载、图标、焦点请求等**展示状态与动作**划为同一标签稳定持有的 `@Observable` ViewModel；是否需要物理拆分为两个类由当前 delegate 与宏兼容性及真实职责决定，但不允许一个单纯改宏的混合 native 对象冒充已完成 MVVM。KVO／delegate 将结果投递给唯一可写 presentation 状态，页面本身只由既有 WKWebView 持有，不镜像网页状态；保留 `BrowserWebView` 实例、delegate 和原生交互。导航变化按 P1 的语义保存路径发出。**同 Task 移除 `BrowserTab.@Published`、Project 中已失效的 `browserObservations` 和 Browser View 的旧 `@ObservedObject`**，不误删实际需要的 WebKit KVO。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`；本地临时 HTML（不上传私人内容）验证前进／后退、网址和标题变化、页面表单、滚动、favicon、重挂载和项目快照网址。隔离原生校验新标签、⌘L 聚焦与历史；`make build`。

**提交：** 浏览器 state、原生桥接、旧 UI 发布链删除和测试同一次提交。

---

## 阶段完成门槛

Native 资源仍由原长生命周期身份持有，界面只观察需要的展示字段；SSH、终端、编辑、浏览器和 diff 各条**已替换的**发布与回调路径都已在所属任务删除。进入窗口聚合阶段前，不得保留“已改 `@Observable` 但父层仍等待 `$isDirty`／`objectWillChange`”的断链。
