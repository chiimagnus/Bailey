# P5：Dock、项目、工作标签与窗口层的 MVVM 收敛

**Goal：** 把窗口／项目／标签真正的唯一状态 owner 改为 Observation，移除跨级 `objectWillChange` 汇总，让项目、Dock、文件／Git 状态和原生内容由稳定窗口组合根管理。

**Non-goals：** 不新增第二套 Dock 树、窗口管理器、分屏模式或快照键；不在这个阶段重做 P3、P4 已完成的各业务后端。

**Approach：** 先将独立 Dock 结构作为纯 Model + 单一布局 ViewModel；再收敛标签、项目及需要用户确认的关闭流程；之后迁移窗口协调者、App Scene 菜单与临时切换器。迁移顺序遵守 P1 的显式持久化事件，不依赖子对象的旧 Publisher；每项连同消费它的 View 和测试一次完成。

**Acceptance：** `DockNode` 是唯一布局真源；所有项目／标签 UI 直接读取 Observation；已替换的 `Project.*Observations`、`TerminalManager.projectObservations` 等旧链消失，自动保存仍有效；多个窗口的菜单、拖动、关闭、恢复和焦点不串状态。

**Rules：** `docs/TERMINAL.md`、`docs/SETTINGS.md`、`docs/PROJECTS.md`、`docs/EDITOR.md`。一标签仅一内容，项目允许零标签；未保存文件／diff 的 Save、Don't Save、Cancel 三路保护及快捷键冲突修复不可退化。

---

<a id="p5-t1"></a>
## P5-T1 Dock 布局唯一状态与拖动手势改用 Observation

**Files／锚点：** `kero/Workspace/DockWorkspaceModel.swift::DockWorkspaceModel.root/select/syncTabs/move/place/removeTool/resize/restore`、`kero/UI/WorkspaceDockView.swift::DockTabDragCoordinator/WorkspaceDockView/DockTreeView`、`kero/Workspace/Project.swift::dockObservation`、`KeroTests/DockWorkspaceTests.swift`、`KeroTests/TreeRowHitTestingTests.swift`。

**当前依赖：** `DockNode` 纯布局树已有唯一实现；`DockWorkspaceModel` 改动 `@Published root`，Project 用 `dock.objectWillChange` 转发；拖动控制器本身也靠 `@StateObject/@Published`。

**实现：** `DockWorkspaceModel` 转为 `@Observable`，纯 `DockNode/DockGroup/DockSavedNode` 不放 UI 依赖；`DockTabDragCoordinator` 只保留其真实临时手势状态，使用 `@Observable + @State` 或更简单的局部状态。Dock View 直接读取真实 root；每次 root 的有效改变走 P1 语义保存信号。**同 Task 删除 Dock 的 `@Published`、`Project.dockObservation` 旧订阅和 DragCoordinator 的旧包装器**，保持项目选择和布局写入的唯一来源。

**验证：** `make test ONLY_TESTING=KeroTests/DockWorkspaceTests`、`make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`；覆盖拖动组间移动、分割、重排、工具唯一性、保存恢复、取消拖动／当前项目变化。隔离原生验收尺寸、指针命中、焦点、动态字号；`make build`。

**提交：** 布局状态＋实时 View／持久化消费＋旧订阅删除一次提交。

---

<a id="p5-t2"></a>
## P5-T2 PaneTab 和 Project 的身份、选择及关闭流程收敛

**Files／锚点：** `kero/Workspace/PaneTab.swift::PaneTab/PaneContent`、`kero/Workspace/Project.swift::Project.register/append/remove/closeContent/confirmCloseUnsaved/closeBatch/selectedTabID/makeSession/makeBrowser`；`kero/UI/Panes/PanelContentView.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift`；`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `Project` 既是项目与标签的唯一 owner，又收集当前尚未迁移的 `sessionObservations/tabObservations/browserObservations`，并在 `confirmCloseUnsaved` 直接弹 NSAlert；`PaneTab` 的展示标题依赖长寿命内容的状态。

**实现：** 让项目级 ViewModel 与单标签 presentation state 按 `@Observable` 暴露真实状态，保持 `PaneContent` 的稳定对象身份、选中项最近使用顺序、机器身份、单内容与 Dock 对应关系。View 直接读取需要的嵌套对象，不为强制更新所有界面保留重复 `objectWillChange` 转发。`Project.makeSession/makeBrowser` 必须调用 P4 已明确的 native runtime／service 创建入口，不允许项目 ViewModel 自己构建 Ghostty surface 或 WKWebView；关闭动作可以指令 runtime 终止，但不能在 ViewModel 里直接构造系统对话框。关闭前“是否保存／取消”由 Project／窗口动作明确请求 UI 来呈现，真正保存和关闭仍在 owner 中执行，沿用现有 `NSAlert` 平台行为或等价 SwiftUI 交互。**同 Task 清除 Project 中截至此时尚存的旧订阅字典和 sink、PaneTab 旧包装器、原生对话框业务混用路径及失效视图观察 wrapper**；P4 已删除的订阅不重新引入。保留对数据丢失真正必要的校验。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`；补脏标签提示、选中／关闭顺序、批量关闭中途 Cancel、保存失败继续保持标签、远端断开后拒绝保存和窗口状态一致性。隔离原生验证 NSAlert 中键盘等效键不会误触发 Don't Save；`make build`。

**提交：** Project／PaneTab 实际状态、确认 UI 路由、旧层级订阅移除、验证同一原子提交。

---

<a id="p5-t3"></a>
## P5-T3 窗口 TerminalManager 收敛成唯一窗口 ViewModel

**Files／锚点：** `kero/Workspace/TerminalManager.swift::TerminalManager.init/makeProject/remove/saveAll/windowClosed/restore/openRestoredWindows`；`kero/UI/ContentView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/WorkspaceDockView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/CommandPaletteView.swift`、`KeroTests/WorkspaceIdentityTests.swift`、`KeroTests/SessionStoreTests.swift`。

**当前依赖：** Manager 的 `projects/selectedProjectID` 使用 `@Published`，`projectObservations` 将每个项目的事件转为“整个窗口变了”。此外 manager 持有多个窗口 registry、Finder pending directories、恢复队列、用户命令与真正的进程 teardown，不可简单作为普通 Model 拆走。

**实现：** 将 manager 明确定位为窗口级 `@Observable` ViewModel；项目拥有项目状态，Service 保留 IO，Manager 只编排当前窗口的动作。P3 的 Git 展示状态继续由此窗口唯一持有、P1 的保存入口继续统一管理。检索 `chooseLocalItems/chooseSSHItems`、Finder 文件选择、原生窗口定位、通知和 SSH handoff 的真实调用者：UI 选择对话框由 App／View 发起并把结果交给窗口 ViewModel，底层 IO 走既有 adapter；窗口 registry／Finder pending request／系统通知保留必要的进程级系统适配，不作为额外可写窗口状态或另造第二个全局 manager。所有直接 `@ObservedObject manager` 的 View 改为正确读取 `@Observable`，绑定通过 `@Bindable`；**同 Task 删除 Manager `@Published`、`projectObservations`、原生选择框业务混用路径与旧取消路径、无用 `objectWillChange` 汇总及对应旧 View wrappers**。若仍有 Combine 用于真实 `willTerminate` 事件，要明确事件消费者而非把它当 UI 状态同步。

**验证：** `make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`；新建／关闭空项目、从 Finder 添加文件／目录、焦点命令作用域、窗口关闭和重启模拟均检查实际结果；`make build` 并严格验签。

**提交：** 唯一窗口 owner 切换与所有旧窗口观察链删除同一提交。

---

<a id="p5-t4"></a>
## P5-T4 App／WindowRoot 的 Observation 装配及多窗口菜单焦点

**Files／锚点：** `kero/App/keroApp.swift::keroApp/WindowRootView/KeroCommands`；`kero/Workspace/TerminalManager.swift::registerWindowOpener/openRestoredWindows/windowClosed`；必要的 SwiftUI 焦点值定义及 XCTest。

**当前依赖：** `WindowRootView.@StateObject` 以窗口为作用域创建 Manager，`.focusedSceneObject(manager)` 与 `@FocusedObject` 供菜单定位激活窗口。SwiftUI 的 View 出现和消失还驱动窗口恢复／终端结束，不能换包装器时破坏。

**实现：** 用 Observation 对象的 `@State` 在窗口入口保持唯一身份，通过平台支持的 `.focusedSceneValue(manager)` 与 `@FocusedValue` 或经实际编译验证的等价 scene-scoped API，让菜单只看当前窗口；先核对所用 SwiftUI SDK API 的实参和身份规则，不预设语法能直接替换。保留当前 WindowGroup／Settings／Commands 结构、窗口找回与生命周期回调，检验临时 View 重挂载不会误触发 `windowClosed`；**同 Task 删除原场景旧 `@StateObject`、`focusedSceneObject`、`@FocusedObject` 接线**，不保留两套菜单焦点路由。

**验证：** `make build`；隔离 Debug 原生多窗口实测两个不同项目：焦点切换后 New／Save／Close／Show Panel／Find 动作只作用于前台窗口，后台命令不中断。恢复和最后窗口关闭重开遵守 `KeroTests/SessionStoreTests` 与 `KeroTests/PaneRetentionTests`，签名验证；没有原生多窗口结果不能宣称菜单完成。

**提交：** Scene 组合根＋焦点命令迁移＋旧入口删除和必要测试一起提交。

---

<a id="p5-t5"></a>
## P5-T5 Ctrl-Tab 快速切换及标签／项目侧栏的局部状态收敛

**Files／锚点：** `kero/UI/Panes/TabSwitcherView.swift::TabSwitcherController/TabSwitcherOverlay/TabSwitcherEventMonitor`、`kero/UI/ContentView.swift::tabSwitcher`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift`，必要的 `KeroTests/PaneRetentionTests.swift`。

**当前依赖：** `TabSwitcherController` 用 `ObservableObject` 处理按住 Ctrl-Tab 后的预选与释放提交，持有原项目弱引用和预览任务；与项目的真正 `selectedTabID` 不应在按键未释放时混为一份状态。

**实现：** 保持独立的临时预选状态，按真实生命周期选用 `@Observable + @State`（非伪造业务 Model），Project 仍唯一拥有正式选择；保留 Esc 取消、连续按 Tab、鼠标真正移动后才覆盖键盘预选、释放 Control 提交的行为。**同 Task 删除 TabSwitcher 的 `@Published`、`@StateObject` 和受影响的旧观察包装器**，保留必要 AppKit 键盘事件桥接，不另建事件总线。

**验证：** `make build`、针对性标签选择检查和隔离原生键盘验收：正序／逆序 Ctrl-Tab、快速重复、Esc、中途关标签／换项目、鼠标静止悬停与滚动，真实项目选中和终端焦点应正确；已承载生命周期验证的 `KeroTests/PaneRetentionTests` 继续通过。

**提交：** 临时切换状态和旧发布器移除、行为验收同一提交。

---

## 阶段完成门槛

窗口／项目／标签／Dock 均有单一可观察 owner；原跨级 UI 广播路径已删除，菜单读取正确 scene 状态。该阶段已实现 UI 与业务确认分离，不允许留下“旧 Manager 仅为继续发布 objectWillChange”这种平行伪状态。
