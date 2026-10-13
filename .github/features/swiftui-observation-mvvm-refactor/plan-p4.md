# P4：远端连接与长生命周期内容对象迁移

**Goal：** 在不重建底层 Shell、编辑器和 WebView 的前提下，让 SSH 连接、终端、文件编辑器、差异编辑器和浏览器的展示状态通过 Observation 传递，保留原生事件适配层。

**Non-goals：** 不重写 Ghostty、TextKit、Pierre/WebKit 内核，不切换远端 SSH 协议，不承诺跨进程恢复正在运行的 Shell 或网页表单。

**Approach：** 沿当前 `RemoteConnection → TerminalSession → Project` 和 `PaneTab → FileTab/DiffTab/BrowserTab` 两条可达链迁移。复用既有终端、TextKit、WebKit 原生桥接，不另建平行 ViewModel。原生测试已证明旧编辑器桥接每次重挂载重建 STTextView，旧 Diff 的嵌套 HostingView 也不能保留 WKWebView；须在各标签真实资源所有权处修复，而非只保留外层 SwiftUI 宿主。第三方 KVO/原生 delegate 是有效事件源，按消费者是否真实存在决定保留，禁止盲删。

**Acceptance：** 已迁移内容对象在 Observation 下更新；拖动标签、项目切换和重挂载不重启 Shell、丢失表单、撤销、文本或滚动；远程断线、只读、恢复与转发无误，清理各对象原先的 UI 发布器和无用转发。

**Rules：** `docs/TERMINAL.md`、`docs/EDITOR.md`、`docs/BROWSER.md`、`docs/PROJECTS.md`、`docs/SECURITY.md`。不复制 Native View，不改变 WebKit KVO/JS 对话框、Ghostty OSC 52 剪贴板授权、脏文件保存与 SSH 主机/路径身份。SwiftUI 的 Observation 与框架 callback 两种机制不能混为一谈。终端输入/光标/滚动、编辑器选择/撤销、Diff/WebKit 表单、原生弹窗和标签视觉/动效均须与 P1 相同条件下的截图及真实交互一致；不因宏替换重建或改样式。

---

<a id="p4-t1"></a>
## P4-T1 清理未接入产品的 SSH 会话临时端口转发链

**源码核对：** 全部产品 Swift 源码没有 `connection.portForwards.forward(...)` 调用，`RemoteConnection.forward/requestForward/freeLocalPort` 也只有旧控制器使用。其唯一持有者 `RemoteConnection.portForwards` 是从未被实际 UI 读取的 lazy 属性，故 `PortForwardController` 的缓存、`Combine` 断线订阅和旧源码测试不是现存产品行为。**真正的用户端口转发**由 `keroApp.init → TunnelManager.start → TunnelRunner` 和 Settings 的 `TunnelSettingsView` 提供，具备独立生命周期，与 `RemoteConnection` 无关，必须保留；`RemoteCommands.isLocalPortFree` 仍被 `TunnelManager` 使用。

**实现：** 直接删除未接入的 `kero/Remote/PortForwardController.swift`、`RemoteConnection.portForwards/forward/requestForward/freeLocalPort` 和仅供其使用的 `.unexpectedOutput`，而不是给闲置对象重新安装 `markDisconnected → forgetAll`。同步清理只针对该死路径的 XCTests 和不参与构建的历史 `check-remote-lifetime.swift` 中的旧转发场景（保留真实 SSH mux 失联测试及现有 Xcode 例外清单）。保留 `RemoteConnection` 的真实连接/断线/复联事件、仍被 `SSHWorkspaceBackend` 使用的 `RemoteConnectionError.commandFailed` 和实际 `TunnelManager`；**不要在本 Task 删除 `RemoteConnection.@Published` 或 `TerminalSession.remoteObservation`**，消费者在 P4-T2 才成组迁移。

**验证：** `make test ONLY_TESTING=KeroTests/RemoteLifetimeTests` 验证真实 runner 流与 `SSHWorkspaceBackend` 对连接的所有权；`RemoteCommandsTests` 与 `WorkspaceIdentityTests` 验证仍在运行的连接身份、控制 socket 和本机端口判断；`make test`、`make build` 及严格验签。静态追溯 `keroApp/TunnelManager/TunnelSettingsView` 用户入口并确认没有任何活动源代码依赖删除的接口。**不建立测试 SSH master，不触碰用户端口转发或 SSH 进程。**

**提交：** 死代码及对应过期测试/工程引用同一任务立即清理；真正的 SSH Observation 变更留给 P4-T2。

---

<a id="p4-t2"></a>
## P4-T2 终端会话和查找条的 Observation／原生事件桥

**Files／锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection`、`kero/Terminal/TerminalSession.swift::TerminalSession/terminalDidRequestClipboardConfirmation/clipboardPreview/probeRemoteWorkingDirectory/panelShellPid`、`kero/Terminal/TerminalFind.swift::TerminalFind`、`kero/Terminal/TerminalFindBar.swift`、`kero/Terminal/TerminalHostView.swift`、`kero/Terminal/KeroTerminalView+Ghostty.swift`、`kero/Terminal/TerminalSurface.swift::TerminalBackendEvents/TerminalClipboardRequest`、`kero/Workspace/Project.swift::sessionObservations/scheduleRemoteTabRebind`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前依赖：** Shell 进程、原生 surface、历史、查找及 SSH 事件由长生命周期 `TerminalSession` 所有；Project 借 `session.objectWillChange` 更新标题和远端重绑，ContentView／工具面板通过完成序列刷新 Git/Files。**P4-T1 保留的 `RemoteConnection` 发布器必须和这里的 Session、Find、UI、Project 一起切换，不得单独移除。**

**实现：** `TerminalSession` 已持有唯一 Ghostty `TerminalBackendSurface`（现成 service/adapter）及完整 `TerminalBackendEvents` 回调，不新建终端 runtime wrapper。将 `RemoteConnection.state/workingDirectory`、`TerminalSession` 标题／目录／命令完成／SSH 位置和 `TerminalFind` **同一 Task** 改成 Observation，并确认在 View 中读取嵌套可观察字段时能实际刷新，保持原生 surface、PTY、滚动和进程不动。`TerminalSession.init` 已经只通过现有 `KeroTerminalView` 建立唯一 native surface，**无需为这一行再造 TerminalFactory/Adapter**。`terminalDidRequestClipboardConfirmation` 的 `NSAlert`/预览是 Ghostty OSC 52 的必要系统 UI，保证由现有 native 事件边界在该 surface 的所属窗口呈现，`approve/deny` 必须回调一次；只在确有生命周期或窗口归属问题时抽出最小 AppKit UI 方法，不为“纯 SwiftUI”平白增加 Presenter 类。`TerminalFind` 直接改 `@Observable`，重复焦点、延迟首个命中和恢复 responder 保持。**同 Task 删除 `RemoteConnection/TerminalSession/TerminalFind.@Published`、`TerminalSession.remoteObservation`、对应旧 View wrapper 和已不再需要的 `Project.sessionObservations`，并让 P1 快照保存独立于旧 Publisher。对 SSH 状态、远端 cwd 更新／断线／重连，从原有状态变更入口显式触发**唯一的** `Project.scheduleRemoteTabRebind`；不能只靠 SwiftUI 读取属性来完成文件／diff 后端重绑，亦不得引入第二个轮询。旧 Info 面板没有任何消费者的 `TerminalSession.panelShellPid`、`RemoteConnection.shellProcessID` 及 PID 赋值在此直接删除；**保留远端 cwd 探测本身**，`SSHWorkspaceBackend.remoteWorkingDirectory → RemoteCommands.shellDiscoveryCommand` 内部使用远端 PID 寻找 cwd 仍有真实用途，不要误删整个进程发现逻辑；若调整返回 tuple／解析器，调用与相关解析测试同 Task 改完。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；新增或调整终端标题、命令完成事件、查找请求与远端断开恢复的最小测试。隔离原生检查停车宿主拖动后 Shell PID 和输入可用、通知跳转、⌘F 重复聚焦及选择不丢失；`make build`。

**审计修正：** 同机器另一条通道已可用时，事件合并可跳过只读状态；不能仅以 readOnlyReason 判断是否重绑。RemoteConnection 弱复用仍被消费者持有的真实 workspace backend，FileTab/DiffTab 按该身份更换目标并失效旧读写。旧通道实际写入完成也不能清除新目标的 dirty。受控回归必须走 TerminalSession/RemoteConnection 的真实状态回调及 Project 原调度入口，不新增轮询或状态副本。

**提交：** 终端真实 owner + 观察边界 + 旧事件链移除同一原子提交。

---

<a id="p4-t3"></a>
## P4-T3 文件编辑标签的可观察状态与可靠保存

**Files／锚点：** `kero/Editor/FileViewerView.swift::FileTab/save/reloadFromDiskIfClean/refreshDirtyState`、`kero/Editor/SourceTextEditor.swift`、`kero/Editor/EditorFind.swift`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `FileTab` 持有编辑文本、保存基线和原生编辑视图；`text` 刻意不逐键发布，`isDirty` 变化却通过 `PaneTab.dirtyObservation` 驱动标签和保存按钮。旧读取不允许覆盖编辑中的缓冲区。

**实现：** `FileTab` **已经是长生命周期的文件展示状态与操作 owner**，`SourceTextEditor`/`STTextView` 已单独负责 Native View 创建，`FileTab.editorView` 只是用于 Dock 拖动预览的**弱引用**，无须另拆 `FileViewModel + Adapter`，更不能复制 text/baseline。`FileTab` 原类型改 `@Observable`，`path/isDirty/saveError/readOnlyReason/reloadRevision` 直接响应；`text`/`editorState` 可依原本低频 UI 消费方式采用 `@ObservationIgnored`，逐键写入不重绘整个窗口。真实读写保持在既有 `WorkspaceBackend`；缓存原工作区和 generation，避免重命名、写中继续编辑或断线后旧读覆盖新内容。`PaneTab`/工作区直接读取 dirty，**同 Task 删除 `FileTab.@Published`、`FileViewerView.@ObservedObject` 及 `PaneTab.dirtyObservation` 对 FileTab 的旧订阅**，不误删 DiffTab 尚未迁移的源。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；补脏标记转清、写中二次编辑、重命名后写新路径、断线只读、旧读取丢弃与保存失败不关闭。隔离原生检查 UTF-8／emoji／CRLF、撤销、查找、光标滚动；`make build`。

**审计修正：** `editorView` 的弱引用仅保留拖动预览用途，不能满足原生撤销保留。复用 `SourceTextEditor.Coordinator` 由文件标签持有唯一原生编辑器，协调器弱持有标签以避免环；临时容器不将真实编辑资源压为零尺寸。实际干净重载释放旧 owner，旧回调不再写入当前文档。原生回归覆盖重挂载后的撤销/重做、900px 滚动、中文/emoji/CRLF、磁盘变化替换、旧回调和释放。

**提交：** 编辑状态链完整接入、旧 dirty Publisher 与重复状态删除同一提交。

---

<a id="p4-t4"></a>
## P4-T4 差异标签和 WebKit 渲染器的可观察状态

**Files／锚点：** `kero/Git/DiffViewerView.swift::DiffTab/DiffWebModel/DiffViewPreferences/DiffViewerView`、`kero/Workspace/PaneTab.swift::dirtyObservation`、`kero/UI/Components/WorkspaceChrome.swift`、相关 Git／Workspace／PaneRetention XCTest。

**当前依赖：** `DiffTab` 保留 repo、机器、提交元数据和可编辑工作区 diff；`DiffWebModel` 驱动独立渲染，`webHostView` 长期持有 WebKit 容器，`PaneTab` 通过 `diff.$isDirty` 显示编辑标记。

**实现（按原生证据修正）：** 保留 DiffTab 的唯一缓冲区／保存基线及 DiffWebModel 的低频渲染输入，两者与 DiffViewPreferences 改成 Observation；默认偏好仍是唯一 shared，UserDefaults 键与写入时机不变，受控测试可注入专用 defaults。原生实验已证明保留 NSHostingView 或 NSHostingController 不能保住内部 WKWebView；只缓存 WebView 又会被 SwiftUI 的临时零尺寸布局丢掉网页内滚动。用户要求在所有权根因修复后，基于 PierreDiffsSwift 1.5.0 固定提交保留源码／资源／许可证，增加 PierreMultiDiffSurface 持有唯一 WebView 和协调器，临时原生容器只给它有效尺寸；最终 owner 释放才 cleanup，不加重试或滚动恢复缓存。删除 Kero 的多余 DiffWebHostingView、DiffWebHostView 及仅为分离宿主服务的外观中继，DiffWebRoot 直接进入当前窗口 SwiftUI 树，创建入口只 materialize 原生 surface。Git／文件仍走原后端，保存回写核对机器／连接代次，进入编辑后的旧读取不得重置编辑器。逐键内容仍不改 DiffWebModel.newContent；同 Task 删除旧 Published／ObservedObject、PaneTab 的 Diff dirty Publisher。改动只涉及上游两个原生适配文件，不改 JavaScript 内核；出处与升级规则写入 docs/DEPENDENCIES.md。

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
