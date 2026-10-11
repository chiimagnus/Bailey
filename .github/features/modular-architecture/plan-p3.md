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

**已证实的冗余：** Project 构造函数读取 `AppSettings.shared.workspaceConfiguration`，`AppSettings.init` 在 TOML 缺失时还走 `legacyDefaults()` 从旧 `UserDefaults` 读取字体；`font-thicken` 是已由 `terminal.font-thicken` 取代的旧 TOML 键。现行配置已存于 `~/.config/kero/config.toml`。

**实施：** 由 `TerminalManager.makeProject()` 将当前 `DockWorkspaceConfiguration` 作为值传入 `Project.init`，其余业务状态不依赖 AppSettings 具体对象；移除旧 `legacyDefaults()` 分支、旧 `font-thicken` 读取分支，并把 `Project.swift` 中仍描述固定侧栏的过时注释改为自由停靠语义。保留当前配置默认值、类型校验、写回磁盘失败处理，不借此添加设置项或依赖注入框架。

**验证：** 先确认 TOML 当前文件可读且现行配置值已保存；临时复制进行默认/自定义配置读写验证，不修改用户实际文件。既有的 Dock 检查及签名 Debug 新项目/SSH 项目/重新启动恢复；无配置文件时使用现行默认值，不再迁移旧 UserDefaults。检查旧 helper/键引用已删除。

**提交边界：** 单向配置注入与直接关联的设置历史兼容清理一个原子提交。

---

<a id="p3-t2"></a>
## P3-T2 删除已淘汰的快照解码分支，只保留当前格式

**Files / 锚点：** `kero/Workspace/SessionStore.swift::ProjectSnapshot.TabSnapshot.init(from:)`、`ColumnSnapshot`、`PaneSnapshot.weight`、`TabSnapshot.layout(from:)` / `stack(...)`；`SessionStore.load()` 的早期单窗口 `SessionSnapshot` fallback；`kero/Terminal/TerminalManager.swift::makeWindowSnapshot/restore(from:)`。

**源码和本机证据：** 当前 `SessionStore.save` 只生成 `AppSnapshot(windows:)`；目前用户实际保存的数据根键已经是 `windows`，Tab 键有 `layout`、`focusedPaneIndex`，不是旧 `columns` 或单内容格式。`PaneSnapshot.weight` 只为旧列式布局使用，现行保存始终设置为 1。

**实施：**
1. 只读核对机器当前快照结构、备份可恢复原始 bytes（不提交私人窗口路径和历史内容）；用当前 snapshot 重放解码确认无旧格式依赖。
2. 删掉旧版 `ColumnSnapshot`、旧列/行转换 `layout/stack`、`TabSnapshot` 的三路 legacy decoder 和 `SessionStore.load` 单窗口 fallback；保留当前 `LayoutSnapshot` 必需字段与类型。当前 `TabSnapshot` 可使用符合现行字段的正常 Codable 解码/编码，不维持旧字段透传；删除只因历史格式而存在的 `PaneSnapshot.weight`，同时改掉 `TerminalManager.layoutSnapshot` 对 weight=1 的写入。
3. 保留 `DockSavedNode` 过滤无效标签引用、当前布局焦点索引保护、`historyKey` 的当前可选语义和拒绝坏数据行为；它们是现用数据完整性，不是“过度兼容”。

**验证：** 对备份的真实当前快照执行只读的现行解码，检查窗口/项目/两层布局数量与焦点；签名 Debug 正常关闭/重新打开后的当前快照可恢复，终端启动新 Shell 而不是伪造旧进程；有历史回放设置时不丢字段。旧 `columns/focusedRow/focusedColumn` 分支和旧单窗口 fallback 在同任务中消失，`git diff --check`。

**提交边界：** 当前快照格式收敛 + 清理旧解码和写入参数一个原子提交。不是删除用户的快照数据，也不创建迁移层。

---

<a id="p3-t3"></a>
## P3-T3 内层 Pane 数据模型与渲染分离

**Files：** `git mv kero/UI/Panes/Panes.swift kero/Workspace/Panes.swift`；渲染保留 `kero/UI/Panes/PaneLayoutView.swift` 与 `TabSwitcherView.swift`。

**依据与实施：** `Panes.swift` 实际定义 `PaneContent`、`Pane`、`PaneNode`、`PaneSplit`、`PaneTab` 的递归数据树和身份；它不是纯 UI。原样迁移，包括 Combine 观察、尺寸计算、分屏/关闭与现有 tab identity，不因为目标目录是 Workspace 就强行删掉它当前使用的 AppKit/其他类型依赖。旧路径和引用立即更新，不做第二份布局模型。

**验证：** Dock 模型回归及 Debug 签名构建；真机内层分屏、嵌套四向分屏、跨外层分组拖动、文件未保存状态、浏览器/Diff 与终端 PTY 的持续存在；保存/恢复焦点不变。旧 `UI/Panes/Panes.swift` 不再存在。

**提交边界：** Pane 数据归属和所有真实路径引用原子提交。

---

<a id="p3-t4"></a>
## P3-T4 窗口协调者归入 Workspace，不拆现用 owner

**Files：** `git mv kero/Terminal/TerminalManager.swift kero/Workspace/TerminalManager.swift`；检查 `kero/App/keroApp.swift::WindowRootView/KeroCommands`、`ContentView`、`WorkspaceDockView`、`Remote/KeroSSHBridge.swift`、`SessionStore` 的调用。

**依据：** 虽然名为 TerminalManager，它实际上负责每窗口的项目列表、选中项、文件/浏览器/Diff 命令及窗口快照聚合；终端 Shell 和 PTY 的真正状态仍属于 `TerminalSession`。当前保留此类型名和其唯一 window registry，不为了压缩行数新增 `WindowService`、`ProjectRepository` 或把同一个观察状态复制到多个 manager。

**实施：** 完整搬迁真实窗口协调实现，保留 `makeProject`、`saveAll/restore`、`KeroSSHBridge` 的前台窗口寻址；同步修正文档/旧文件引用，以及本文件中已不适用的“固定左侧栏/右侧栏”注释。不得碰 P3-T2 已经收敛的当前快照格式，不新增过时兼容层。

**验证：** 签名 Debug 多窗口、菜单作用目标、添加/关闭本地与 SSH 项目、恢复多个项目/标签、窗口聚合存档、终端输入/PTY 无异常重启。确认旧 Terminal 路径已删除，`git diff --check`。

**提交边界：** 窗口协调者物理归属一个原子提交。

---

<a id="p3-t5"></a>
## P3-T5 收敛 WorkspaceBackend 接口与具体实现的源码边界

**Files / 已核对锚点：** 当前 `kero/Workspace/WorkspaceBackend.swift` 包含 `WorkspaceEntry/WorkspaceStat/...`、`protocol WorkspaceBackend`、私有 `RunPipeData`、整个 `LocalWorkspaceBackend` 以及文件末尾的 `extension RemoteConnection.workspaceIdentity`、`extension TerminalSession.workspaceIdentity`。拆为保留契约与共享数据的 `kero/Workspace/WorkspaceBackend.swift`、新增 `kero/Workspace/LocalWorkspaceBackend.swift`；身份扩展分别归 `kero/Remote/RemoteConnection.swift` 和 `kero/Terminal/TerminalSession.swift`。

**当前原因：** 单一源码文件既定义多实现协议，又承载本地磁盘/进程的完整实现，还直接扩展了 RemoteConnection/TerminalSession；这是实际存在的依赖职责混杂，分开后无需新增协议。调用者包括 `Project.workspaceIdentity/connectedWorkspace`、`FileTab/DiffTab` 机器身份校验、`FileTreeModel`，以及基于独立源文件编译的导航回归。

**实施：** 原样迁移 `RunPipeData` 与完整 `LocalWorkspaceBackend` 到一个本地具体实现文件；接口文件保留所有 `WorkspaceBackend` 需要的数据类型、错误类型和协议。将两个 workspaceIdentity 扩展**原样**移回其定义类型，删除原文件旧实现；保留 `nil` 表示本机、`destination:port` 区分远程机器的逻辑，修正相关 `WorkspaceBackend`、`RemoteConnection`、`TerminalSession` 中已过时的固定侧栏/本地/SSH 注释。`scripts/check-file-tree-navigation.swift` 顶部只为当前跨域扩展而存在的 `RemoteConnection/TerminalSessionLocation/TerminalSession` 临时桩也要在同一任务删除，验证独立编译不再需要它们。不要拆成 Files/Processes/Git 三个新协议，也不要改变现有后台 I/O。

**验证：** **同步更新** `docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift` 的独立编译命令（此后需同时传 `WorkspaceBackend.swift`、`LocalWorkspaceBackend.swift`）和 `docs/PERFORMANCE.md` 对本地读取实现的源码链接；真实执行文件树导航检查并核对不再依赖上述 3 个测试桩，Debug 编译/签名、本地/远端同名路径不混淆、断线后文件与 Diff 不误写本机、重连后标签重新绑定。检查 LocalWorkspaceBackend 和两种身份属性各只有一份，无空壳转发与旧注释。

**提交边界：** Workspace 接口/本地实现分离、跨域身份扩展归位、受影响脚本与文档同步修正一个原子提交。

---

<a id="p3-t6"></a>
## P3-T6 把被 Dock 使用的底部工具栏抽成独立组件

**Files：** 从 `kero/UI/ContentView.swift` 移动 `BottomToolbarLayout`、`BottomToolbarView`、`BranchSearchField`、`ToolbarContextMenuMonitor`、`ToolbarContextMenuMonitorView`、`ToolbarContextMenuEvent`、`InstantPopoverPresenter` 及它们的私有 helper → `kero/UI/Components/BottomToolbarView.swift`。调用方 `WorkspaceDockView` 和 `ProjectsPanelView`。

**依据：** `ContentView` 并非底部工具栏的唯一消费者，控件内有分支菜单和原生 Popover 的 AppKit 桥。此处是**已经存在的共享 UI**，独立源码归属比新建协议合理。

**实施：** 一次性迁移工具栏和它独占的辅助类型，保留原始 GitStatusModel 观察、按钮动作、焦点与 24pt 高度唯一常量；立即删除根 View 中旧定义，不重写成新的配置系统。

**验证：** 签名 Debug 下分支搜索、弹窗关闭/焦点、底部栏显隐、Git 面板跳转、窄标签组与窗口缩放；唯一 `BottomToolbarLayout`、无新高度分支，`git diff --check`。

**提交边界：** 底部工具栏视图与其 helper 一次原子迁移。

---

<a id="p3-t7"></a>
## P3-T7 把标签胶囊、重命名和内容标签统一归入 Components

**Files：** 从 `kero/UI/ContentView.swift` 移出 `PaneTabItem`、`TabRenameChrome`、`SessionTabLabel`、`FileTabLabel`、`BrowserTabLabel`、`DiffTabLabel`、`TabItemChrome` → `kero/UI/Components/TabChrome.swift`；调用方 `WorkspaceDockView`。

**依据：** 外层自由停靠 Work/Tools 标签都使用同一个 `TabItemChrome`；原文件将长寿命标签对象的订阅和 hover-close UI 混在根 ContentView 文件末尾。迁移可改善组件归属，但**现有圆角、4pt padding、icon hover 替换 X 等行为必须原样保持**。

**实施：** 整组视图和必要的私有辅助类型原样迁移；保留 `PaneTab` 的 `@ObservedObject`、选中/关闭/重命名动作，修复必要可见性后删除旧定义。核对 `kero/Editor/SourceTextEditor.swift` 中仍写“⇧⌘B 关闭右侧面板”的过时说明并当场更正注释；不得创建第二套标签胶囊或统一类型擦除层。

**验证：** 签名 Debug 真实标签重排、跨组拖拽、四向分屏、hover 关闭、重命名焦点、标题与 dirty 状态、交通灯避让、键盘/无障碍；只有一个 `TabItemChrome`，与已有 UI 比对，`git diff --check`。

**提交边界：** 标签组件归属和旧实现删除一个原子提交。

---

## P3 完成条件

项目不再直接从 App 单例读取初始布局；历史 UserDefaults/旧窗格/单窗口快照兼容分支已在 P3-T1/T2 **即时删除**，当前快照正常恢复。Workspace 的接口和本地/SSH 具体实现边界清楚，Terminal 保留真实终端，UI 中共享组件不重复。P3-T5 之后所有独立编译命令必须使用新路径；后续不为保持老格式造适配层。
