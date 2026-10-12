# P4：远端连接与长生命周期内容对象迁移

**Goal：** 在不重建底层 Shell、编辑器和 WebView 的前提下，让 SSH 连接、终端、文件编辑器、差异编辑器和浏览器的展示状态通过 Observation 传递，保留原生事件适配层。

**Non-goals：** 不重写 Ghostty、TextKit、Pierre/WebKit 内核，不切换远端 SSH 协议，不承诺跨进程恢复正在运行的 Shell 或网页表单。

**Approach：** 沿当前 `RemoteConnection → TerminalSession → Project` 和 `PaneTab → FileTab/DiffTab/BrowserTab` 两条可达链迁移。已有 `TerminalBackendSurface`、`SourceTextEditor`、`BrowserWebView` 和 `DiffWebHostingView` 就是原生桥接，**不预设再创建一套 NativeAdapter/ViewModel 类**；先把真实展示状态改为 Observation，只在 NSAlert、原生 View 创建或底层 IO 确实越过职责时做针对性抽离。第三方 KVO/原生 delegate 是有效事件源，按消费者是否真实存在决定保留，禁止盲删。

**Acceptance：** 已迁移内容对象在 Observation 下更新；拖动标签、项目切换和重挂载不重启 Shell、丢失表单、撤销、文本或滚动；远程断线、只读、恢复与转发无误，清理各对象原先的 UI 发布器和无用转发。

**Rules：** `docs/TERMINAL.md`、`docs/EDITOR.md`、`docs/BROWSER.md`、`docs/PROJECTS.md`、`docs/SECURITY.md`。不复制 Native View，不改变 WebKit KVO/JS 对话框、Ghostty OSC 52 剪贴板授权、脏文件保存与 SSH 主机/路径身份。SwiftUI 的 Observation 与框架 callback 两种机制不能混为一谈。终端输入/光标/滚动、编辑器选择/撤销、Diff/WebKit 表单、原生弹窗和标签视觉/动效均须与 P1 相同条件下的截图及真实交互一致；不因宏替换重建或改样式。

---

<a id="p4-t1"></a>
## P4-T1 SSH 断线事件与临时端口转发发布器清理

**Files／锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection.markConnected/markDisconnected/runSSH`；`kero/Remote/PortForwardController.swift::init/forward/forgetAll`；`kero/Terminal/TerminalSession.swift::beginRemoteConnection/endRemoteConnection/watchRemoteConnection`；`kero/Remote/SSHWorkspaceBackend.swift`、`KeroTests/RemoteLifetimeTests.swift`、`KeroTests/RemoteCommandsTests.swift`。

**当前依赖：** `PortForwardController` 订阅 `connection.$state` 后断开立即取消在途转发；`TerminalSession.remoteObservation` 仍通过 `connection.objectWillChange` 向未迁移的 `TerminalSession/Project/UI` 发布状态。**这两条链不能在不同 Task 的中间态被一起拔掉**，否则先编译失败，或连接状态变化时右侧 UI／远端重绑失效。

**实现：** **本 Task 先只闭合端口转发的真实副作用链**：让 `RemoteConnection.markDisconnected` 直接调用现有 `PortForwardController.forgetAll`（只在连接真实断开时触发；保留合并并发请求、断线取消及完成后重新核对 state，防止旧请求在重连后复写本地端口缓存），确认唯一实际断线入口；`localPortsByRemote` 没有 SwiftUI/$Publisher 消费者，改为普通私有字典，**立即删除 `PortForwardController: ObservableObject`、`@Published`、`stateObserver` 与无用 Combine import**。暂保留 `RemoteConnection` 当前 `ObservableObject/@Published` 和 `TerminalSession.remoteObservation`，因为下一 Task 才能把它们与原生终端、Project 及 UI 消费者一起原子换成 Observation；本 Task 不增加一套临时 `withObservationTracking` 中继。`RemoteCommandRunner`、控制 socket、跨 SSH host identity 与 `WorkspaceBackend: Sendable` 保持原样；不迁移进程 runner。

**验证：** `make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/RemoteCommandsTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；覆盖断线发生在 `forward` 等待期间、重复并发请求、旧连接复活不可回写新机器、同主机不同端口身份。受控测试不接触用户 SSH master；`make build` 并验签。

**提交：** 断线副作用与无消费者的端口转发发布器删除同一次提交；仍有消费者的 `RemoteConnection/TerminalSession` UI 发布器按 P4-T2 删除。

---

<a id="p4-t2"></a>
## P4-T2 终端会话和查找条的 Observation／原生事件桥

**Files／锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection`、`kero/Terminal/TerminalSession.swift::TerminalSession/terminalDidRequestClipboardConfirmation/clipboardPreview/probeRemoteWorkingDirectory/panelShellPid`、`kero/Terminal/TerminalFind.swift::TerminalFind`、`kero/Terminal/TerminalFindBar.swift`、`kero/Terminal/TerminalHostView.swift`、`kero/Terminal/KeroTerminalView+Ghostty.swift`、`kero/Terminal/TerminalSurface.swift::TerminalBackendEvents/TerminalClipboardRequest`、`kero/Workspace/Project.swift::sessionObservations/scheduleRemoteTabRebind`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前依赖：** Shell 进程、原生 surface、历史、查找及 SSH 事件由长生命周期 `TerminalSession` 所有；Project 借 `session.objectWillChange` 更新标题和远端重绑，ContentView／工具面板通过完成序列刷新 Git/Files。**P4-T1 保留的 `RemoteConnection` 发布器必须和这里的 Session、Find、UI、Project 一起切换，不得单独移除。**

**实现：** `TerminalSession` 已持有唯一 Ghostty `TerminalBackendSurface`（现成 service/adapter）及完整 `TerminalBackendEvents` 回调，不新建终端 runtime wrapper。将 `RemoteConnection.state/workingDirectory`、`TerminalSession` 标题／目录／命令完成／SSH 位置和 `TerminalFind` **同一 Task** 改成 Observation，并确认在 View 中读取嵌套可观察字段时能实际刷新，保持原生 surface、PTY、滚动和进程不动。`TerminalSession.init` 已经只通过现有 `KeroTerminalView` 建立唯一 native surface，**无需为这一行再造 TerminalFactory/Adapter**。`terminalDidRequestClipboardConfirmation` 的 `NSAlert`/预览是 Ghostty OSC 52 的必要系统 UI，保证由现有 native 事件边界在该 surface 的所属窗口呈现，`approve/deny` 必须回调一次；只在确有生命周期或窗口归属问题时抽出最小 AppKit UI 方法，不为“纯 SwiftUI”平白增加 Presenter 类。`TerminalFind` 直接改 `@Observable`，重复焦点、延迟首个命中和恢复 responder 保持。**同 Task 删除 `RemoteConnection/TerminalSession/TerminalFind.@Published`、`TerminalSession.remoteObservation`、对应旧 View wrapper 和已不再需要的 `Project.sessionObservations`，并让 P1 快照保存独立于旧 Publisher。对 SSH 状态、远端 cwd 更新／断线／重连，从原有状态变更入口显式触发**唯一的** `Project.scheduleRemoteTabRebind`；不能只靠 SwiftUI 读取属性来完成文件／diff 后端重绑，亦不得引入第二个轮询。旧 Info 面板没有任何消费者的 `TerminalSession.panelShellPid`、`RemoteConnection.shellProcessID` 及 PID 赋值在此直接删除；**保留远端 cwd 探测本身**，`SSHWorkspaceBackend.remoteWorkingDirectory → RemoteCommands.shellDiscoveryCommand` 内部使用远端 PID 寻找 cwd 仍有真实用途，不要误删整个进程发现逻辑；若调整返回 tuple／解析器，调用与相关解析测试同 Task 改完。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；新增或调整终端标题、命令完成事件、查找请求与远端断开恢复的最小测试。隔离原生检查停车宿主拖动后 Shell PID 和输入可用、通知跳转、⌘F 重复聚焦及选择不丢失；`make build`。

**提交：** 终端真实 owner + 观察边界 + 旧事件链移除同一原子提交。

---

<a id="p4-t3"></a>
## P4-T3 文件编辑标签的可观察状态与可靠保存

**Files／锚点：** `kero/Editor/FileViewerView.swift::FileTab/save/reloadFromDiskIfClean/refreshDirtyState`、`kero/Editor/SourceTextEditor.swift`、`kero/Editor/EditorFind.swift`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `FileTab` 持有编辑文本、保存基线和原生编辑视图；`text` 刻意不逐键发布，`isDirty` 变化却通过 `PaneTab.dirtyObservation` 驱动标签和保存按钮。旧读取不允许覆盖编辑中的缓冲区。

**实现：** `FileTab` **已经是长生命周期的文件展示状态与操作 owner**，`SourceTextEditor`/`STTextView` 已单独负责 Native View 创建，`FileTab.editorView` 只是用于 Dock 拖动预览的**弱引用**，无须另拆 `FileViewModel + Adapter`，更不能复制 text/baseline。`FileTab` 原类型改 `@Observable`，`path/isDirty/saveError/readOnlyReason/reloadRevision` 直接响应；`text`/`editorState` 可依原本低频 UI 消费方式采用 `@ObservationIgnored`，逐键写入不重绘整个窗口。真实读写保持在既有 `WorkspaceBackend`；缓存原工作区和 generation，避免重命名、写中继续编辑或断线后旧读覆盖新内容。`PaneTab`/工作区直接读取 dirty，**同 Task 删除 `FileTab.@Published`、`FileViewerView.@ObservedObject` 及 `PaneTab.dirtyObservation` 对 FileTab 的旧订阅**，不误删 DiffTab 尚未迁移的源。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；补脏标记转清、写中二次编辑、重命名后写新路径、断线只读、旧读取丢弃与保存失败不关闭。隔离原生检查 UTF-8／emoji／CRLF、撤销、查找、光标滚动；`make build`。

**提交：** 编辑状态链完整接入、旧 dirty Publisher 与重复状态删除同一提交。

---

<a id="p4-t4"></a>
## P4-T4 差异标签和 WebKit 渲染器的可观察状态

**Files／锚点：** `kero/Git/DiffViewerView.swift::DiffTab/DiffWebModel/DiffViewPreferences/DiffViewerView`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、相关 Git／Workspace／PaneRetention XCTest。

**当前依赖：** `DiffTab` 保留 repo、机器、提交元数据和可编辑工作区 diff；`DiffWebModel` 驱动独立渲染，`webHostView` 长期持有 WebKit 容器，`PaneTab` 通过 `diff.$isDirty` 显示编辑标记。

**实现：** `DiffTab` 已经唯一负责 diff 的 repo/路径/机器、加载、编辑/保存与错误；`DiffWebModel` 是长期 `DiffWebHostingView` 真正消费的**渲染输入状态**，两者本来职责不同，不能为了“只剩一个 Observable”就合并并触发 WebKit 全量渲染。对各自的现有 UI 状态改 `@Observable`，保留 `DiffWebHostingView` 一份真实实例；`DiffViewPreferences.shared` **也是实际 UI `ObservableObject`**（驱动统一／并列 diff 及编辑模式），必须在本 Task 同步改为 `@Observable`，原 UserDefaults 键、写入时机和唯一共享身份不变。`DiffWebRoot` 的 Pierre `diffStyle`/`overflowMode` 绑定用 `@Bindable` 或已有显式 `Binding` 接回真实 owner，不把偏好复制到 DiffTab。Git 读取继续走现有 `GitCommandExecution`／`WorkspaceBackend`，**不存在需要引入的 P3 Git Service**。真正的原生创建 `DiffTab.materializeWebHostView` 只在具体创建边界移给现有 host adapter（如保持长寿命身份可在同任务完成），无需额外包装类。仍须避免逐键改 `DiffWebModel.newContent` 触发丢失 undo，保留 editing buffer 与 saved baseline 的当前职责分工。**同 Task 删除被替换的 `@Published`、`@ObservedObject`、PaneTab 的 Diff 旧 dirty publisher、无消费者通知；不会删除真实 WebKit 局部渲染所需桥接。**

**验证：** 更新的 Git XCTest、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；工作区／暂存／历史、UTF-8/二进制/5MiB 限制、未保存 diff、断线重连。隔离原生验证 WKWebView 真实首屏、滚动、diff 编辑/保存、切换后重新显示；`make build`。

**提交：** 差异状态／原生桥接／旧观察代码删除与回归一起提交。

---

<a id="p4-t5"></a>
## P4-T5 浏览器标签 Observation 与 WKWebView delegate/KVO 适配

**Files／锚点：** `kero/Browser/BrowserView.swift::BrowserTab/BrowserView/BrowserWebView`、`kero/Workspace/Project.swift::browserObservations`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前依赖：** BrowserTab 同时是浏览器标签的唯一生命周期 owner 和 WKNavigationDelegate；`webView.publisher(for:)` 读取 WebKit **KVO 事件**，原 `@Published` 则供 SwiftUI 展示和 Project 的 `objectWillChange` 中继，两者用途不同。

**实现：** 已用本机 Swift 6.4／Xcode 27 最小编译验证：`@Observable final class X: NSObject, WKNavigationDelegate` **可以直接通过类型检查**，不需为宏兼容先新增 BrowserNativeAdapter 和重复 ViewModel。沿现有 BrowserTab（唯一页面身份/命令 owner）改 `@Observable`，页面本身仍只由 `BrowserWebView` 实例持有。`webView.publisher(for: \.url/title/isLoading/...)` 属于**真实 WebKit KVO 输入事件**，不是自有 UI 状态广播；保留必要 KVO，更新唯一可观察展示字段，禁止额外封装新的 WKWebView/Delegate 副本。WebKit JS alert/confirm/prompt 的 `WKUIDelegate` 必须如实回调，不能为了消灭 NSAlert 无谓迁移。导航 URL 变化必须继续触发 P1 自动保存；**同 Task 只删除 `BrowserTab.@Published`、Project 中不再有消费者的 `browserObservations` 和 UI `@ObservedObject`，保留仍运行的 KVO/Delegate。**

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`；本地临时 HTML（不上传私人内容）验证前进／后退、网址和标题变化、页面表单、滚动、favicon、重挂载和项目快照网址。隔离原生校验新标签、⌘L 聚焦与历史；`make build`。

**提交：** 浏览器 state、原生桥接、旧 UI 发布链删除和测试同一次提交。

---

## 阶段完成门槛

Native 资源仍由原长生命周期身份持有，界面只观察需要的展示字段；SSH、终端、编辑、浏览器和 diff 各条**已替换的**发布与回调路径都已在所属任务删除。进入窗口聚合阶段前，不得保留“已改 `@Observable` 但父层仍等待 `$isDirty`／`objectWillChange`”的断链。
