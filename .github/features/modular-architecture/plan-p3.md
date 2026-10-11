# P3：窗口/项目/窗格的状态与源码归属

**Goal：** 让项目初始化不主动读取 App 设置；移除个人项目已废弃的历史布局/设置兼容；让内层窗格、窗口协调者和跨域扩展归位，再抽离真正被 Dock 复用的两类 UI 组件。

**Non-goals：** 不改变会话快照的当前格式语义、UI 操作、项目对象身份；不发明新的 Manager/Service/Protocol，不做跨工程模块拆包。

**Approach：** 每次改动沿当前真实调用链实施：`TerminalManager.makeProject → Project.init → DockWorkspaceModel`；`TerminalManager.makeWindowSnapshot/restore → SessionStore`；`Project.tabs → PaneTab/PaneNode`；最后移动跨文件重用的 UI 组件。任何被替代的旧兼容代码在相应 Task 当场删除，而非 P5 才清理。

**Acceptance：** 当前磁盘快照可安全恢复；项目与窗口对象仍在原来的生命周期，Ghostty PTY 不因 UI 重建而销毁；`WorkspaceBackend` 基础文件不再包含 TerminalSession/RemoteConnection 类型扩展；工具栏和标签外观只有一份定义，样式不变。

**Rules：** App 仍为单一 Target；`WindowRootView` 每个窗口持有一个 `TerminalManager`；窗口中的 `ContentView` 持有当前 GitStatusModel。允许删除早期存档格式兼容，但不得删除**现用**快照解码、异常数据拒绝、SSH 机器身份校验、恢复选中项目的有效保护。正式进程正在运行时不替换应用或覆盖持久化数据。

---

<a id="p3-t1"></a>
## P3-T1 项目显式接收布局初始值，同步清理设置旧格式

**Files / 锚点：** `kero/Workspace/Project.swift::init(fallbackName:)`；`kero/Terminal/TerminalManager.swift::makeProject()`（当前唯一 `Project(fallbackName:)` 工厂）；`kero/App/AppSettings.swift::init/save/legacyDefaults`；`DockWorkspaceConfiguration`。

**已证实的冗余：** Project 构造函数读取 `AppSettings.shared.workspaceConfiguration`，`AppSettings.init` 在 TOML 缺失或不可解析时还走 `legacyDefaults()` 从旧 `UserDefaults` 读取字体；`font-thicken` 是已由 `terminal.font-thicken` 取代的旧 TOML 键。2026-10-12 只读检查确认本机配置文件可读；这不等于默认/自定义配置往返验证已完成。

**实施：** 由 `TerminalManager.makeProject()` 将当前 `DockWorkspaceConfiguration` 作为值传入 `Project.init`，只消除这里的布局设置依赖，不声称 TerminalFont/Ghostty 等实际配置消费者也已去全局化。移除旧 `legacyDefaults()` 分支、旧 `font-thicken` 读取分支，并把 `Project.swift` 中仍描述固定侧栏的过时注释改为自由停靠语义。保留当前配置默认值、类型校验、原子写回失败处理，以及 `save()` 重读磁盘 workspace 设置以保留用户手工修改的行为。当前语言、Diff 偏好的 UserDefaults 不是旧字体迁移，不删除。同步更正 `docs/SETTINGS.md` 的配置说明，删掉为未来 API 复用布局而写的推测，不借此添加设置项或依赖注入框架。

**验证：** 先确认 TOML 当前文件可读且现行配置值已保存；临时复制进行默认/自定义配置读写验证，不修改用户实际文件。既有的 Dock 检查及签名 Debug 新项目/SSH 项目/重新启动恢复；无配置文件时使用现行默认值，不再迁移旧 UserDefaults。检查旧 helper/键引用已删除。

**提交边界：** 单向配置注入与直接关联的设置历史兼容清理一个原子提交。

---

<a id="p3-t2"></a>
## P3-T2 删除已淘汰的快照解码分支，只保留当前格式

**Files / 锚点：** `kero/Workspace/SessionStore.swift::ProjectSnapshot.TabSnapshot.init(from:)`、`ColumnSnapshot`、`PaneSnapshot.weight`、`TabSnapshot.layout(from:)` / `stack(...)`；`SessionStore.load()` 的早期单窗口 `SessionSnapshot` fallback；`kero/Terminal/TerminalManager.swift::makeWindowSnapshot/restore(from:)`。

**源码和本机证据：** 当前 `SessionStore.save` 只生成 `AppSnapshot(windows:)`。2026-10-12 只读检查 `sh.kero/sessionSnapshot` 的结构：根键为 `windows`，1 个窗口、4 个项目、7 个标签；Tab 键集合为 `layout/focusedPaneIndex/contextSessionIndex`，没有 `columns`，所有项目都有 `dock`。仅输出结构与数量，没有输出私人路径/内容；这尚不是 App 恢复验收。`PaneSnapshot.weight` 只为旧列式布局使用，现行保存始终设置为 1。

**实施：**
1. 只读核对机器当前快照结构、备份可恢复原始 bytes（不提交私人窗口路径和历史内容）；用当前 snapshot 重放解码确认无旧格式依赖。
2. 删掉旧版 `ColumnSnapshot`、旧列/行转换 `layout/stack`、`TabSnapshot` 的三路 legacy decoder 和 `SessionStore.load` 单窗口 fallback；保留当前 `LayoutSnapshot` 必需字段与类型。当前 `TabSnapshot` 可使用符合现行字段的正常 Codable 解码/编码，不维持旧字段透传；删除只因历史格式而存在的 `PaneSnapshot.weight`，同时改掉 `TerminalManager.layoutSnapshot` 对 weight=1 的写入。
3. 保留 `DockSavedNode` 过滤无效标签引用、当前布局焦点索引保护及拒绝坏数据行为。`historyKey/customName/contextSessionIndex/customDirectory/sshHost/pinnedFile` 和 `SourceTextEditor.swift::EditorState` 的缺省也有当前真实含义；保留其可选语义，删除“为了旧版本可解码”的过时解释，不把 optional 全部改成必填。焦点与上下文索引仍按当前恢复路径检查，不用强制解包。旧布局/旧顶层格式明确不再接收，不添加版本号、迁移器或兼容透传。

**验证：** 同任务留下现行快照的最小可运行往返检查：两层布局、空/非空 optional、焦点/上下文索引越界、无效 Dock 标签引用、损坏必需字段拒绝，以及旧顶层/旧列格式不再接收。对备份的真实当前快照执行只读解码，检查窗口/项目/两层布局数量与焦点；签名 Debug 正常关闭/重新打开后的当前快照可恢复，终端启动新 Shell 而不是伪造旧进程；有历史回放设置时不丢字段。旧 `columns/focusedRow/focusedColumn` 分支和旧单窗口 fallback 在同任务中消失，`git diff --check`。

**提交边界：** 当前快照格式收敛 + 清理旧解码和写入参数一个原子提交。不是删除用户的快照数据，也不创建迁移层。

---

<a id="p3-t3"></a>
## P3-T3 内层 Pane 数据模型与渲染分离

**Files：** `git mv kero/UI/Panes/Panes.swift kero/Workspace/Panes.swift`；渲染保留 `kero/UI/Panes/PaneLayoutView.swift` 与 `TabSwitcherView.swift`。

**依据与实施：** `Panes.swift` 实际定义 `PaneContent`、`Pane`、`PaneNode`、`PaneSplit`、`PaneTab` 的递归数据树和身份；它不是纯 UI。原样迁移，包括 Combine 观察、尺寸计算、分屏/关闭与现有 tab identity，不因为目标目录是 Workspace 就强行删掉它当前使用的 AppKit/其他类型依赖。同步更正 `PaneTab.canSplit` 与 `PaneLayoutView` 关于“始终挂载 Diff stack/web view”的旧注释：当前单窗格 Diff 由 Dock 直接挂载，Diff 不支持内层分屏。不借此增加 Diff 分屏能力。旧路径和引用立即更新，不做第二份布局模型。

**验证：** Dock 模型回归及 Debug 签名构建；真机内层分屏、嵌套四向分屏、跨外层分组拖动、文件未保存状态、浏览器/Diff 与终端 PTY 的持续存在；保存/恢复焦点不变。旧 `UI/Panes/Panes.swift` 不再存在。

**提交边界：** Pane 数据归属和所有真实路径引用原子提交。

---

<a id="p3-t4"></a>
## P3-T4 窗口协调者归入 Workspace，不拆现用 owner

**Files：** `git mv kero/Terminal/TerminalManager.swift kero/Workspace/TerminalManager.swift`；检查 `kero/App/keroApp.swift::WindowRootView/KeroCommands`、`ContentView`、`WorkspaceDockView`、`Remote/KeroSSHBridge.swift`、`SessionStore` 的调用。

**依据：** 虽然名为 TerminalManager，它实际上负责每窗口的项目列表、选中项、文件/浏览器/Diff 命令及窗口快照聚合；终端 Shell 和 PTY 的真正状态仍属于 `TerminalSession`。当前保留此类型名和其唯一 window registry，不为了压缩行数新增 `WindowService`、`ProjectRepository` 或把同一个观察状态复制到多个 manager。

**实施：** 完整搬迁真实窗口协调实现，保留 `makeProject`、`saveAll/restore`、`KeroSSHBridge` 和终端通知的窗口/会话寻址。删除无调用方的 `refreshAllAppearances()`（旧 CLI 主题预览入口）及 `ProcessWorkingDirectory.swift::processArguments(pid:)`（旧 Agent 识别遗留）；实际使用的 cwd、可执行路径查询保留。同步修正文档/旧文件引用，以及相关类型中已不适用的固定侧栏、CLI 创建项目/automation socket、Agent 识别注释。不得碰 P3-T2 已经收敛的当前快照格式，不新增过时兼容层。

**验证：** 签名 Debug 多窗口、菜单作用目标、添加/关闭本地与 SSH 项目、恢复多个项目/标签、窗口聚合存档、终端输入/PTY 无异常重启。确认旧 Terminal 路径已删除，`git diff --check`。

**提交边界：** 窗口协调者物理归属一个原子提交。

---

<a id="p3-t5"></a>
## P3-T5 收敛 WorkspaceBackend 接口与具体实现的源码边界

**Files / 已核对锚点：** 当前 `kero/Workspace/WorkspaceBackend.swift` 包含 `WorkspaceEntry/WorkspaceStat/...`、`protocol WorkspaceBackend`、私有 `RunPipeData`、整个 `LocalWorkspaceBackend` 以及文件末尾的 `extension RemoteConnection.workspaceIdentity`、`extension TerminalSession.workspaceIdentity`。拆为保留契约与共享数据的 `kero/Workspace/WorkspaceBackend.swift`、新增 `kero/Workspace/LocalWorkspaceBackend.swift`；身份扩展分别归 `kero/Remote/RemoteConnection.swift` 和 `kero/Terminal/TerminalSession.swift`。

**当前原因：** 单一源码文件既定义多实现协议，又承载本地磁盘/进程的完整实现，还直接扩展了 RemoteConnection/TerminalSession；这是实际存在的依赖职责混杂，分开后无需新增协议。调用者包括 `Project.workspaceIdentity/connectedWorkspace`、`FileTab/DiffTab` 机器身份校验、`FileTreeModel`，以及基于独立源文件编译的导航回归。

**实施：** 原样迁移 `RunPipeData` 与完整 `LocalWorkspaceBackend` 到一个本地具体实现文件；接口文件保留所有 `WorkspaceBackend` 需要的数据类型、错误类型和协议。将两个 workspaceIdentity 扩展**原样**移回其定义类型，删除原文件旧实现；保留 `nil` 表示本机、`destination:port` 区分远程机器的逻辑，修正相关 `WorkspaceBackend`、`RemoteConnection`、`TerminalSession` 中已过时的固定侧栏/本地/SSH 注释。`scripts/check-file-tree-navigation.swift` 顶部只为当前跨域扩展而存在的 `RemoteConnection/TerminalSessionLocation/TerminalSession` 临时桩也要在同一任务删除，验证独立编译不再需要它们。不要拆成 Files/Processes/Git 三个新协议，也不要改变现有后台 I/O。

**同一边界必须收敛的真实错误：** `FileTab/DiffTab.init` 把显式传入的 `workspaceIdentity == nil` 当成“未提供”，再回退到 `session.workspaceIdentity`。项目固定到本机目录、上下文终端正处于 SSH 时，Project 已传入本地 backend，却得到远程身份；随后复用/只读判定及 `TerminalManager.isSnapshotable` 均会错配。两种标签的构造函数都要求调用方显式提供 backend 与可选机器身份，删除 optional backend/default/session 回退参数；全部构造者都是 `Project`，同步切换所有新建和恢复路径。`PaneTab.contextSession` 仍保留作工具面板的上下文，不再决定文件存放在哪台机器。不新增第二份机器状态或“修正身份”补丁。

**远端契约的无消费者实现同步删除：** 现有 `RemoteCommandRunner` 的实际实现是 `RemoteConnection` 与 `SSHHostCommandRunner`。`ProcessRemoteCommandRunner` 从未实例化，只有其静态 `launch` 被 SSHHostCommandRunner 使用；保留原进程执行，收敛为普通静态 helper，删除无消费者的 conformance、实例属性/实例 run，不新建 runner 协议。`RemoteConnection.run(_:cwd:stdin:timeout:)` 的 argv 便利重载及独占的 `remoteScript/shellQuoted` 也无消费者，同任务删除，修正其旧说明；真正的协议 run、SSHWorkspaceBackend 的转义/环境/错误映射保持。安全检查不随死重载一起删除。

**验证：** **同步更新** `docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift` 的独立编译命令（此后需同时传 `WorkspaceBackend.swift`、`LocalWorkspaceBackend.swift`）和 `docs/PERFORMANCE.md` 对本地读取实现的源码链接；真实执行文件树导航检查并核对不再依赖上述 3 个测试桩。针对标签身份，验证固定本机目录 + SSH 上下文创建的 File/Diff 仍为本机、可复用且保存/重启后仍在；相同路径不同远端不混淆，断线保留内容但不误写本机、重连可重新绑定。保留这组回归步骤/断言在本任务验证证据中，不能只看构造函数编译通过。检查 LocalWorkspaceBackend 和两种身份属性各只有一份，无空壳转发与旧注释，Debug 编译/签名。

**提交边界：** Workspace 接口/本地实现分离、跨域身份扩展归位、受影响脚本与文档同步修正一个原子提交。

---

<a id="p3-t6"></a>
## P3-T6 把被 Dock 使用的底部工具栏抽成独立组件

**Files：** 从 `kero/UI/ContentView.swift` 移动 `BottomToolbarLayout`、`BottomToolbarView`、`BranchSearchField`、`ToolbarContextMenuMonitor`、`ToolbarContextMenuMonitorView`、`ToolbarContextMenuEvent`、`InstantPopoverPresenter` 及它们的私有 helper → `kero/UI/Components/BottomToolbarView.swift`。调用方 `WorkspaceDockView` 和 `ProjectsPanelView`。

**依据：** `ContentView` 并非底部工具栏的唯一消费者，控件内有分支菜单和原生 Popover 的 AppKit 桥。此处是**已经存在的共享 UI**，独立源码归属比新建协议合理。

**实施：** 一次性迁移工具栏和它独占的辅助类型，保留原始 GitStatusModel 观察、按钮动作、焦点与 24pt 高度唯一常量；立即删除根 View 中旧定义。删除 `ContentView.emptyState` 中不可达的“已选项目但没有会话”旧分支：有 selectedProject 时根 View 始终进入 Dock，空分组提示已有 Dock 的实现；同步删除 `Resources/Localization/Interface.xcstrings` 中仅由该分支使用的 `No open sessions`、`New Session  ⌘T` 两条旧文案。保留真正无项目时的入口，不重写成新的配置系统。

**验证：** 签名 Debug 下分支搜索、弹窗关闭/焦点、底部栏显隐、Git 面板跳转、窄标签组与窗口缩放；唯一 `BottomToolbarLayout`、无新高度分支，`git diff --check`。

**提交边界：** 底部工具栏视图与其 helper 一次原子迁移。

---

<a id="p3-t7"></a>
## P3-T7 把标签胶囊、重命名和内容标签统一归入 Components

**Files：** 从 `kero/UI/ContentView.swift` 移出 `PaneTabItem`、`TabRenameChrome`、`SessionTabLabel`、`FileTabLabel`、`BrowserTabLabel`、`DiffTabLabel`、`TabItemChrome` → `kero/UI/Components/WorkspaceChrome.swift`；同一文件接收 `ProjectsPanelView.swift` 中被 Projects 与 Dock 共用的 `ChromeIconButton`，以及实际仅由 Dock 标题栏挂载的 `FPSBadge`。项目列表不再承载窗口工作区依赖的通用 chrome，不另建按钮体系。

**依据：** 外层自由停靠 Work/Tools 标签都使用同一个 `TabItemChrome`；原文件将长寿命标签对象的订阅和 hover-close UI 混在根 ContentView 文件末尾。迁移可改善组件归属，但**现有圆角、4pt padding、icon hover 替换 X 等行为必须原样保持**。

**实施：** 整组视图和必要的私有辅助类型原样迁移；保留 `PaneTab` 的 `@ObservedObject`、选中/关闭/重命名动作，以及 FPS 只在可见时启停的 View 生命周期，修复必要可见性后删除旧定义。`ChromeIconButton` 保持现有 tooltip/hover/命中行为，不新增样式协议。更正 `kero/Editor/SourceTextEditor.swift` 中“⇧⌘B 关闭右侧面板”的旧说明，并删除明确标为临时的 `RestorableScrollView.logScroller/KERO_SCROLLER_DEBUG` 与调用；保留真实的滚动几何重算、selection/scroll 恢复和布局边界。不得创建第二套标签胶囊或统一类型擦除层。

**验证：** 签名 Debug 真实标签重排、跨组拖拽、四向分屏、hover 关闭、重命名焦点、标题与 dirty 状态、交通灯避让、键盘/无障碍；只有一个 `TabItemChrome`，与已有 UI 比对，`git diff --check`。

**提交边界：** 标签组件归属和旧实现删除一个原子提交。

---

## P3 完成条件

项目不再直接从 App 单例读取初始布局；历史 UserDefaults/旧窗格/单窗口快照兼容分支已在 P3-T1/T2 **即时删除**，当前快照正常恢复。Workspace 的接口和本地/SSH 具体实现边界清楚，Terminal 保留真实终端，UI 中共享组件不重复。P3-T5 之后所有独立编译命令必须使用新路径；后续不为保持老格式造适配层。
