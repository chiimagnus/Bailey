# P5：Dock、项目、工作标签与窗口层的 MVVM 收敛

**Goal：** 把窗口／项目／标签真正的唯一状态 owner 改为 Observation，移除跨级 `objectWillChange` 汇总，让项目、Dock、文件／Git 状态和原生内容由稳定窗口组合根管理。

**Non-goals：** 不新增第二套 Dock 树、窗口管理器、分屏模式或快照键；不在这个阶段重做 P3、P4 已完成的各业务后端。

**Approach：** 保留 `DockNode`、`Project`、`PaneTab`、`TerminalManager` 已有身份与唯一持有关系，直接把真实状态转成 Observation；调整业务/界面越界时以原生 UI owner 的最小闭包或现有 Service 承载，不强制拆出平行 WindowManager/ProjectStore/新协议。每个 Task 连同真正使用它的 View 与菜单接线更新，直接删除被替代的旧 Publisher。

**Acceptance：** `DockNode` 是唯一布局真源；所有项目／标签 UI 直接读取 Observation；已替换的 `Project.*Observations`、`TerminalManager.projectObservations` 等旧链消失，自动保存仍有效；多个窗口的菜单、拖动、关闭、恢复和焦点不串状态。

**Rules：** `docs/TERMINAL.md`、`docs/SETTINGS.md`、`docs/PROJECTS.md`、`docs/EDITOR.md`。一标签仅一内容，项目允许零标签；**当前已经提供的** Save、Don't Save、Cancel 操作及快捷键不得退化。Dock/标签/项目的外观、命中、动效、原生确认框和关闭结果都须与 P1 基线一致；不借架构重构新增确认或改变取消后的行为。

---

<a id="p5-t1"></a>
## P5-T1 Dock 布局唯一状态与拖动手势改用 Observation

**Files／锚点：** `kero/Workspace/DockWorkspaceModel.swift::DockWorkspaceModel.root/select/syncTabs/move/place/removeTool/resize/restore`、同文件 `DockSavedItem.info/resolve` 与 `DockWorkspaceConfiguration.init` 的历史 `info` 过滤、`kero/Workspace/SessionStore.swift::SessionStore.load`、`kero/UI/WorkspaceDockView.swift::DockTabDragCoordinator/WorkspaceDockView/DockTreeView`、`kero/Workspace/Project.swift::dockObservation`、`KeroTests/DockWorkspaceTests.swift`、`KeroTests/SessionStoreTests.swift::testObsoleteInfoItemIsFilteredWithoutDiscardingLayout`、`KeroTests/AppSettingsTests.swift`、`KeroTests/TreeRowHitTestingTests.swift`。

**当前依赖：** `DockNode` 纯布局树已有唯一实现；`DockWorkspaceModel` 改动 `@Published root`，Project 用 `dock.objectWillChange` 转发；拖动控制器本身也靠 `@StateObject/@Published`。

**实现：** `DockWorkspaceModel.root` 保留唯一布局真源并改为 `@Observable`；`DockTabDragCoordinator` 仅保留真实拖动手势坐标/目标，用 `@Observable + @State` 呈现短暂预览，不增加第二份 Dock 树。`Project.selectedTabID` 仅记录最近标签选择，Dock 组选中仍由 `DockNode` 管理；root 变更沿 P1 入口保存。**历史 Info 数据须最小化处理，而非生硬删除解码 case**：现行 `SessionStore.load` 对整个 `AppSnapshot` 一次 `Codable` 解码；删除 `DockSavedItem.info` 会使含 Info 的旧布局抛错，并让**整份窗口恢复结果退化为空**。保留仅用于读取和忽略此项的 `DockSavedItem.info/resolve`、配置 `info` 过滤，不恢复已废弃的 Info 面板、不新增新旧双路布局 Model；新保存的布局只编码当前有效项目。保留并增强旧 Info 过滤的 XCTest，加入包含两个窗口、一个窗口历史 Dock 含 Info 的**完整 `AppSnapshot` 解码和其余窗口／Group ID／标签保全验证**；同时验证当前配置和非法项边界。本 Task 删除 `DockWorkspaceModel.@Published`、`Project.dockObservation`、DragCoordinator.@Published、旧 View 包装器和**实际无消费者的旧 Info UI/说明**；不删除仍保护当前磁盘数据的最小解码入口，不碰用户实际数据。

**验证：** `make test ONLY_TESTING=KeroTests/DockWorkspaceTests`、`make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`、必要的 `KeroTests/AppSettingsTests`；当前 `.projects/.files/.git/.tab` 合法布局 round-trip、非法项拒绝、Group ID/选中内容恢复必须正确。旧 `info` 只验证**读取并过滤数据、绝不渲染旧面板**，且不能使其它窗口／标签恢复失败。覆盖组间移动、分割、重排、工具唯一性、保存恢复、取消拖动／切换项目；隔离原生核对尺寸、指针命中、焦点；`make build`。

**提交：** 布局状态＋实时 View／持久化消费＋旧订阅删除一次提交。

---

<a id="p5-t2"></a>
## P5-T2 PaneTab 和 Project 的身份、选择及关闭流程收敛

**Files／锚点：** `kero/Workspace/PaneTab.swift::PaneTab/PaneContent`、`kero/Workspace/Project.swift::Project.register/append/remove/closeContent/confirmCloseUnsaved/closeBatch/selectedTabID/makeSession/makeBrowser`、`kero/Workspace/TerminalManager.swift::close/remove`（两个项目关闭入口）以及`kero/UI/CommandPaletteView.swift`；`kero/UI/Panes/PanelContentView.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift`；`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `Project` 既是项目与标签的唯一 owner，又收集尚未迁移的 `sessionObservations/tabObservations/browserObservations`，并在 `confirmCloseUnsaved` 直接弹 NSAlert；`PaneTab` 标题依赖长寿命内容的状态。**源码已发现但本次不改变 UX 的既有缺陷**：`TerminalManager.close(project)` 不检查脏 File/Diff，直接 `terminateAll/remove`；`Project.closeBatch` 在逐个确认后立即移除标签，随后 Cancel 不会恢复已关标签；`confirmCloseUnsaved` 只检查 `saveError == nil`。此前新增项目关闭提示、调整批量取消行为的方案会改变现有体验，**从本次纯重构中剔除**，另案明确授权处理，不能将它们写成已修复。

**实现：** 在**原有** `Project`、`PaneTab` 对象上改 `@Observable`，不另造 ProjectViewModel、PaneViewModel 转发层；`PaneContent` 只引用一份长寿命 native 内容。`Project.makeSession/makeBrowser` 保留业务编排，Native 实例创建交给 P4 已有的终端/浏览器原生适配入口，不造新的工厂容器。`confirmCloseUnsaved` 中构造原生 `NSAlert` 属于职责越界，可委托 P3-T1 的最小 UI 呈现入口，**前提是保持现有窗口选择、Sheet/Modal 类型、按钮与文字、键盘等效键、展示顺序、Save/Don't Save/Cancel 后实际结果完全不变**；若无法证明等价，当前 Task 不得标为完成；继续寻找等价的职责迁移方式，不允许以架构目标为由牺牲 UX。`Close Others/Right/All/Files/Diffs` 的确认、逐项关闭和取消结果以 P1 记录的原行为为准，不改成“全部准备后统一拆除”；`TerminalManager.close(project)` 的侧栏／命令面板入口保持原有关闭行为，**不新增未保存确认框**。既有窗口归属错误、保存竞态或数据丢失风险记录为独立缺陷，需另案授权后修复，不在本 Task 偷改交互。**本 Task 删除 `Project` 余留 `sessionObservations/tabObservations/browserObservations` 中继、`PaneTab` 旧 `@Published` 和直接生成 NSAlert 的项目业务路径，并替换对应 View `@ObservedObject`**；P4 已移除的订阅不再恢复。`Project` 不再符合 `ObservableObject` 后，`TerminalManager.projectObservations` 无法继续存在，须在本 Task 原子删除，而不是为了等 P5-T3 再留临时旧协议。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`；在**隔离测试内容**中对照 P1 基线核查单标签关闭、批量关闭逐项弹窗／Cancel、侧栏和命令面板关闭项目的**实际现有结果**，包括按钮文案、顺序、模态方式、焦点与 Shell 是否终止。现存风险只记录，不添加以新 UX 为预期的测试；确认展示迁移后必须与旧方式一致。`make build`。

**提交：** Project／PaneTab 实际状态、确认 UI 路由、旧层级订阅移除、验证同一原子提交。

---

<a id="p5-t3"></a>
## P5-T3 窗口 TerminalManager 收敛成唯一窗口 ViewModel

**Files／锚点：** `kero/Workspace/TerminalManager.swift::TerminalManager.init/makeProject/remove/saveAll/windowClosed/restore/openRestoredWindows`；`kero/UI/ContentView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/WorkspaceDockView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/CommandPaletteView.swift`、`KeroTests/WorkspaceIdentityTests.swift`、`KeroTests/SessionStoreTests.swift`。

**当前依赖：** Manager 的 `projects/selectedProjectID` 仍用 `@Published`；原 `projectObservations` 广播链已随 P5-T2 原子删除，P5-T3 不应重新引入。此外 manager 持有多个窗口 registry、Finder pending directories、恢复队列、用户命令与真正的进程 teardown，不可简单作为普通 Model 拆走。

**实现：** `TerminalManager` 是已有的**每窗口**唯一业务/选择/恢复协调者，改成 `@Observable`，保留静态注册表供 Finder/通知和跨窗口持久化，不新建 WindowViewModel。**P3 的 Git 状态继续由同窗口 `ContentView.@State` 单独持有**。Manager 目前创建的 `NSOpenPanel` 和 SSH 选择 UI 改由已有 WindowRoot／P3-T1 的**明确所属窗口**原生呈现入口执行，选中 URL/host 的验证及业务写入仍归 Manager，不建协议／DialogService。同步核对 `ProjectsPanelView.SidebarProjectRow.pickProjectDirectory`：它本就是 UI 选择器，不必从 View 再搬出去，却不能继续用 `NSApp.keyWindow ?? NSApp.mainWindow` 猜窗口；由最小现有 UI 入口呈现并只传回选中目录；**必须保持 NSOpenPanel/SSH 选择器原本的窗口归属、模态方式、默认路径、可选类型、按钮与取消行为**，不能借路由迁移改变体验。菜单和命令面板保持同一操作入口。接入各 View 直接读取 `@Observable manager`；由于 Manager 已不再符合 `ObservableObject`，`WindowRootView` 的 `@State`、`KeroCommands` 的 `FocusedValues` 观察接口必须在同一原子变更中更新才能通过编译，P5-T4 负责该 Scene 路由的多窗口原生验证及修复，而非保留一套临时兼容包装。**同 Task 删除 Manager `@Published`、已替换的原生对话框构造、其它旧 `objectWillChange` 中继与包装器**；`projectObservations` 在 P5-T2 已删，不重复，并保留真正的 `willTerminate` 系统通知。

**验证：** `make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`；新建／关闭空项目、从 Finder 添加文件／目录、焦点命令作用域、窗口关闭和重启模拟均检查实际结果；`make build` 并严格验签。

**提交：** 唯一窗口 owner 切换与所有旧窗口观察链删除同一提交。

---

<a id="p5-t4"></a>
## P5-T4 App／WindowRoot 的 Observation 装配及多窗口菜单焦点

**Files／锚点：** `kero/App/keroApp.swift::keroApp/WindowRootView/KeroCommands`、`kero/App/FinderService.swift::KeroApplicationDelegate`（只核对现有退出行为，不加回调）、`kero/UI/Components/WindowChrome.swift::WindowChromeAccessor`（只核对现有关闭与窗口归属，不增拦截）、`kero/Workspace/TerminalManager.swift::registerWindowOpener/openRestoredWindows/windowClosed`；必要的 SwiftUI 焦点值定义及 XCTest。

**当前依赖：** P5-T3 已随 Manager Observation 原子迁移 `WindowRootView.@State`、`.focusedSceneValue(\.keroManager, manager)` 与 `@FocusedValue(\.keroManager)`，本 Task 不重复替换这些接口，重点验收真正的双窗口焦点与动作目标；SwiftUI 的 View 出现和消失仍驱动窗口恢复／终端结束，不能破坏。**另有已确认的关闭旁路**：`WindowRootView.onDisappear → TerminalManager.windowClosed()` 直接抓快照并终止 Shell；现行快照仅保存文件路径／编辑器位置，不保存未写盘的 File/Diff 编辑文本，点窗口红色关闭按钮时不能寄希望于 `onDisappear` 才检查脏文件。

**实现：** 本机 **Xcode 27 / Swift 6.4** 已用独立临时文件实际 `swiftc -typecheck` 通过：`@Observable final class X: NSObject, WKNavigationDelegate`、`@Entry var manager: Manager?`、`.focusedSceneValue(\.manager, manager)`、`@FocusedValue(\.manager)` 可组合，**原计划的 `.focusedSceneValue(manager)` 实参错误**。P5-T3 已按本方案定义 `FocusedValues.keroManager`，并在 WindowRoot／KeroCommands 中原子接入。当前 Task 须实测这条 Scene 焦点链，发现真实路由错误时修复，不额外造 Navigation/Scene 子系统；保留 `WindowGroup` 当前恢复/关闭时序。**窗口关闭与应用退出均须保持现有 UX**：只迁移 `WindowRootView` 的状态装配和菜单焦点读取，不修改 `WindowChromeAccessor`、`NSWindow` 关闭拦截、`WindowRootView.onDisappear → manager.windowClosed()` 和 `KeroApplicationDelegate` 的退出行为；不新增 `windowShouldClose`、`applicationShouldTerminate` 或关闭前弹窗。源码已证实的未保存编辑风险保留为独立缺陷记录，不在这次架构重构中默默更改红色关闭按钮、⌘W 或退出的结果。保留关闭后的窗口快照/终端历史保存时序，不允许迁移带来**新的**数据丢失或行为退化。**同 Task 删除旧 `@StateObject`、`.focusedSceneObject(manager)`、`@FocusedObject` 及失效焦点帮助类**。

**验证：** `make build` + `make test ONLY_TESTING=KeroTests/SessionStoreTests` 和 P5-T2 关闭行为回归。隔离 Debug **两窗口不同项目**核对切焦点后 New/Save/Close/Find/Show Panel 的原有可用条件、操作目标、快捷键与原生焦点；红色关闭按钮／⌘W／应用退出必须保持**基线中已有的**提示数量、关闭结果、终端退出和恢复时序，不能多出 Save/Don't Save/Cancel 对话框。涉及未保存数据只在临时文件中验并记录已知风险，绝不触碰正在运行的用户会话。若 SDK 编译不接受 FocusedValues `@Entry`，按真实报错调整 key 定义，不保留旧 `@FocusedObject` 双轨。

**提交：** Scene 组合根＋焦点命令迁移＋旧入口删除和必要测试一起提交。

---

<a id="p5-t5"></a>
## P5-T5 Ctrl-Tab 快速切换及标签／项目侧栏的局部状态收敛

**Files／锚点：** `kero/UI/Panes/TabSwitcherView.swift::TabSwitcherController/TabSwitcherOverlay/TabSwitcherEventMonitor`、`kero/UI/ContentView.swift::tabSwitcher`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift::FPSBadge`、`kero/Support/FPSCounter.swift::FPSCounter/start/stop/tick`，必要的 `KeroTests/PaneRetentionTests.swift`。

**当前依赖：** `TabSwitcherController` 用 `ObservableObject` 处理按住 Ctrl-Tab 后的预选与释放提交，持有原项目弱引用和预览任务；与项目的真正 `selectedTabID` 不应在按键未释放时混为一份状态。

**实现：** `TabSwitcherController` 保持窗口局部短时预选与真实 `Project.selectedTabID` 分离，改成 `@Observable` 配合 View 的 `@State`；保留 Esc 取消、释放 Ctrl 才提交、键盘优先、仅鼠标真实移动可选中。`PalettePointerSelectionController` 的空 `ObservableObject` 继承和指针输入清理由 P6-T2 统一处理，不重复修改。窗口局部 `FPSCounter` 继续拥有真实 `CADisplayLink`、弱代理/停止清理，将其唯一 `fps` 展示属性改为 `@Observable`，当前 badge `@StateObject` → `@State`；只改 UI 观察，不重写 FPS 原生采样。**本 Task 删除 TabSwitcher/FPS 的旧 `@Published` 与旧 `@StateObject`/`@ObservedObject`，不额外建 P6 辅助清理 Task**。

**验证：** `make build`、针对性标签选择检查和隔离原生键盘验收：对照 P1 相同窗口及内容下的预选浮层原生截图、出现/消失时机、动效与焦点；正序／逆序 Ctrl-Tab、快速重复、Esc、中途关标签／换项目、鼠标静止悬停与滚动，真实项目选中和终端焦点应与基线一致；已承载生命周期验证的 `KeroTests/PaneRetentionTests` 继续通过。

**提交：** 临时切换状态和旧发布器移除、行为验收同一提交。

---

## P5-T6 移除多余的 WebKit Diff 渲染与 Pierre 依赖

**依据：** 用户明确要求 WebKit 仅用于内置浏览器。Git 历史确认初始仓库曾依赖 PierreDiffsSwift，`ee243e0` 将其 vendoring 到 `Vendor/`；非 main 的 `native-diff` 历史分支 `e3f5b3d` 已有可复用的 TextKit 差异计算、语法高亮和行布局实现。

**实现：** 复用该原生实现，保留当前 `DiffTab` 的 Git/SSH 读取、保存、目标/请求代次与错误行为；以 `DiffNativeSurface` 由标签唯一持有原生视图，取消 WKWebView、Pierre 的 Xcode 包链接及本地源码，并即时清理旧编辑回调/旧测试。更新 `docs/GIT.md`、`docs/DEPENDENCIES.md`、`docs/PERFORMANCE.md` 和 AGENTS 的原生边界。

**验证：** Diff 9/9、全量 XCTest 68/68、Debug build、严格代码签名通过；隔离 Debug 真实打开 Git Diff，检查 Unified/Split 中文/Emoji、行号、增删色和左右对照；确认 App 二进制不链接 Pierre，只有浏览器及其焦点桥接依赖 WebKit，正式运行中的 Kero 未替换。

**提交：** `6b3081b`。

## 阶段完成门槛

窗口／项目／标签／Dock 均有单一可观察 owner；原跨级 UI 广播路径已删除，菜单读取正确 scene 状态。该阶段已实现 UI 与业务确认分离，不允许留下“旧 Manager 仅为继续发布 objectWillChange”这种平行伪状态。
