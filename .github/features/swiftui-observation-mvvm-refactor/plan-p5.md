# P5：Dock、项目、工作标签与窗口层的 MVVM 收敛

**Goal：** 把窗口／项目／标签真正的唯一状态 owner 改为 Observation，移除跨级 `objectWillChange` 汇总，让项目、Dock、文件／Git 状态和原生内容由稳定窗口组合根管理。

**Non-goals：** 不新增第二套 Dock 树、窗口管理器、分屏模式或快照键；不在这个阶段重做 P3、P4 已完成的各业务后端。

**Approach：** 保留 `DockNode`、`Project`、`PaneTab`、`TerminalManager` 已有身份与唯一持有关系，直接把真实状态转成 Observation；调整业务/界面越界时以原生 UI owner 的最小闭包或现有 Service 承载，不强制拆出平行 WindowManager/ProjectStore/新协议。每个 Task 连同真正使用它的 View 与菜单接线更新，直接删除被替代的旧 Publisher。

**Acceptance：** `DockNode` 是唯一布局真源；所有项目／标签 UI 直接读取 Observation；已替换的 `Project.*Observations`、`TerminalManager.projectObservations` 等旧链消失，自动保存仍有效；多个窗口的菜单、拖动、关闭、恢复和焦点不串状态。

**Rules：** `docs/TERMINAL.md`、`docs/SETTINGS.md`、`docs/PROJECTS.md`、`docs/EDITOR.md`。一标签仅一内容，项目允许零标签；未保存文件／diff 的 Save、Don't Save、Cancel 三路保护及快捷键冲突修复不可退化。

---

<a id="p5-t1"></a>
## P5-T1 Dock 布局唯一状态与拖动手势改用 Observation

**Files／锚点：** `kero/Workspace/DockWorkspaceModel.swift::DockWorkspaceModel.root/select/syncTabs/move/place/removeTool/resize/restore`、同文件 `DockSavedItem.info` 与 `DockWorkspaceConfiguration.init` 的历史 `info` 分支、`kero/UI/WorkspaceDockView.swift::DockTabDragCoordinator/WorkspaceDockView/DockTreeView`、`kero/Workspace/Project.swift::dockObservation`、`KeroTests/DockWorkspaceTests.swift`、`KeroTests/SessionStoreTests.swift::testObsoleteInfoItemIsFilteredWithoutDiscardingLayout`、`KeroTests/TreeRowHitTestingTests.swift`。

**当前依赖：** `DockNode` 纯布局树已有唯一实现；`DockWorkspaceModel` 改动 `@Published root`，Project 用 `dock.objectWillChange` 转发；拖动控制器本身也靠 `@StateObject/@Published`。

**实现：** `DockWorkspaceModel.root` 保留唯一布局真源并改为 `@Observable`；`DockTabDragCoordinator` 仅保留真实拖动手势坐标/目标，用 `@Observable + @State` 呈现短暂预览，不增加第二份 Dock 树。`Project.selectedTabID` 仅记录最近标签选择，Dock 组选中仍由 `DockNode` 管理；root 变更沿 P1 入口保存。**这里有确切可删的过时兼容代码**：此前废弃的 Info 工具未出现在当前 `DockItem`，但 `DockSavedItem.info/resolve` 和 `DockWorkspaceConfiguration.init` 对文本 `"info"` 的跳过仍在运行。与本任务的布局新状态一起删除这些旧 Info 分支，并将只验证旧 Info 恢复的 XCTest 改为**当前布局格式/非法项边界的测试**；现行有效布局的编码值、Group ID 与 Tab 映射保持不变。本次不承诺继续加载不再支持的老 Info 快照，不清理用户真实保存数据。**同 Task 删除 `DockWorkspaceModel.@Published`、`Project.dockObservation`、DragCoordinator.@Published、旧 Info 分支、被替代旧测试及 View 包装器**。

**验证：** `make test ONLY_TESTING=KeroTests/DockWorkspaceTests`、`make test ONLY_TESTING=KeroTests/TreeRowHitTestingTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`；当前 `.projects/.files/.git/.tab` 的合法布局 round-trip、非法项拒绝、Group ID/选中内容恢复必须正确；不再使用旧 Info 专项测试证明兼容。覆盖组间移动、分割、重排、工具唯一性、保存恢复、取消拖动／切换项目。隔离原生核对尺寸、指针命中、焦点；`make build`。

**提交：** 布局状态＋实时 View／持久化消费＋旧订阅删除一次提交。

---

<a id="p5-t2"></a>
## P5-T2 PaneTab 和 Project 的身份、选择及关闭流程收敛

**Files／锚点：** `kero/Workspace/PaneTab.swift::PaneTab/PaneContent`、`kero/Workspace/Project.swift::Project.register/append/remove/closeContent/confirmCloseUnsaved/closeBatch/selectedTabID/makeSession/makeBrowser`；`kero/UI/Panes/PanelContentView.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift`；`KeroTests/PaneRetentionTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前依赖：** `Project` 既是项目与标签的唯一 owner，又收集当前尚未迁移的 `sessionObservations/tabObservations/browserObservations`，并在 `confirmCloseUnsaved` 直接弹 NSAlert；`PaneTab` 的展示标题依赖长寿命内容的状态。

**实现：** 在**原有** `Project`、`PaneTab` 对象上改 `@Observable`，不另造 ProjectViewModel、PaneViewModel 转发层；`PaneContent` 只引用一份长寿命 native 内容。`Project.makeSession/makeBrowser` 保留业务编排，Native 实例创建交给 P4 已有的终端/浏览器原生适配入口，不造新的工厂容器。原 `confirmCloseUnsaved` 在 Project 里创建 `NSAlert` 是真实职责越界：将确认展示委托给当前窗口的 UI presenter/最小注入闭包，Project 自身只决定目标、等待结果、调用 `content.save()`、在**保存成功后**关闭；批量关闭必须逐项串行并支持 Cancel。不得用 `NSApp.keyWindow` 猜关联窗口，避免多个窗口时在错误窗口确认。**本 Task 删除 `Project` 余留 `sessionObservations/tabObservations/browserObservations` 中继、`PaneTab` 旧 `@Published` 和直接生成 NSAlert 的项目业务路径，并替换对应 View `@ObservedObject`**；P4 已移除的订阅不再恢复。

**验证：** `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`；补脏标签提示、选中／关闭顺序、批量关闭中途 Cancel、保存失败继续保持标签、远端断开后拒绝保存和窗口状态一致性。隔离原生验证 NSAlert 中键盘等效键不会误触发 Don't Save；`make build`。

**提交：** Project／PaneTab 实际状态、确认 UI 路由、旧层级订阅移除、验证同一原子提交。

---

<a id="p5-t3"></a>
## P5-T3 窗口 TerminalManager 收敛成唯一窗口 ViewModel

**Files／锚点：** `kero/Workspace/TerminalManager.swift::TerminalManager.init/makeProject/remove/saveAll/windowClosed/restore/openRestoredWindows`；`kero/UI/ContentView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/WorkspaceDockView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/CommandPaletteView.swift`、`KeroTests/WorkspaceIdentityTests.swift`、`KeroTests/SessionStoreTests.swift`。

**当前依赖：** Manager 的 `projects/selectedProjectID` 使用 `@Published`，`projectObservations` 将每个项目的事件转为“整个窗口变了”。此外 manager 持有多个窗口 registry、Finder pending directories、恢复队列、用户命令与真正的进程 teardown，不可简单作为普通 Model 拆走。

**实现：** `TerminalManager` 是已有的**每窗口**唯一业务/选择/恢复协调者，改成 `@Observable`，并保留静态注册表服务于当前 Finder/通知和跨窗口持久化；不重命名或新建 WindowViewModel。**P3 的 Git 状态继续由同窗口 `ContentView.@State` 单独持有**，无需转移到 Manager。只把确实发生在 Manager 的 `NSOpenPanel`/SSH 选择对话框委托给 App/窗口原生 UI 接口（可用简洁闭包注入，不建协议或第二个窗口服务），选中 URL/host 的业务操作仍由 Manager 发起；`KeroCommands` 与命令面板继续走相同唯一操作入口。接入各 View 直接读取 `@Observable manager`；**同 Task 删除 Manager `@Published`、`projectObservations`、已替换的 NSOpenPanel/NSAlert 直接构造、旧无用 `objectWillChange` 中继与 UI 包装器**。对于实际系统 `willTerminate` 保留必要通知回调，与 UI 状态无关。

**验证：** `make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/SessionStoreTests`、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`；新建／关闭空项目、从 Finder 添加文件／目录、焦点命令作用域、窗口关闭和重启模拟均检查实际结果；`make build` 并严格验签。

**提交：** 唯一窗口 owner 切换与所有旧窗口观察链删除同一提交。

---

<a id="p5-t4"></a>
## P5-T4 App／WindowRoot 的 Observation 装配及多窗口菜单焦点

**Files／锚点：** `kero/App/keroApp.swift::keroApp/WindowRootView/KeroCommands`；`kero/Workspace/TerminalManager.swift::registerWindowOpener/openRestoredWindows/windowClosed`；必要的 SwiftUI 焦点值定义及 XCTest。

**当前依赖：** `WindowRootView.@StateObject` 以窗口为作用域创建 Manager，`.focusedSceneObject(manager)` 与 `@FocusedObject` 供菜单定位激活窗口。SwiftUI 的 View 出现和消失还驱动窗口恢复／终端结束，不能换包装器时破坏。

**实现：** 本机 **Xcode 27 / Swift 6.4** 已用独立临时文件实际 `swiftc -typecheck` 通过：`@Observable final class X: NSObject, WKNavigationDelegate`、`@Entry var manager: Manager?`、`.focusedSceneValue(\.manager, manager)`、`@FocusedValue(\.manager)` 可组合，**原计划的 `.focusedSceneValue(manager)` 实参错误**。本 Task 在 `FocusedValues` 定义单一针对 `TerminalManager?` 的键（命名按当前工程避免碰撞）；WindowRoot `@State private var manager=TerminalManager()`，调用 `.focusedSceneValue(\.keroManager, manager)`，KeroCommands 使用 `@FocusedValue(\.keroManager)`。保留 `WindowGroup` 当前恢复/关闭时序，焦点窗口不跨 scene，暂不创建 Navigation/Scene 子系统。**同 Task 删除旧 `@StateObject`、`.focusedSceneObject(manager)`、`@FocusedObject` 及因新路由不再使用的帮助类**。

**验证：** `make build` + `make test ONLY_TESTING=KeroTests/SessionStoreTests`，隔离 Debug **两窗口不同项目**的原生交互：切焦点后 New/Save/Close/Find/Show Panel 只修改选中窗口；最后关闭再开恢复，终端与编辑内容稳定。若 SwiftUI SDK 编译不接受 FocusedValues `@Entry`，直接用实际报错修正 key 定义，**不得回滚到旧 `@FocusedObject` 双轨**。

**提交：** Scene 组合根＋焦点命令迁移＋旧入口删除和必要测试一起提交。

---

<a id="p5-t5"></a>
## P5-T5 Ctrl-Tab 快速切换及标签／项目侧栏的局部状态收敛

**Files／锚点：** `kero/UI/Panes/TabSwitcherView.swift::TabSwitcherController/TabSwitcherOverlay/TabSwitcherEventMonitor`、`kero/UI/ContentView.swift::tabSwitcher`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Components/WorkspaceChrome.swift::FPSBadge`、`kero/Support/FPSCounter.swift::FPSCounter/start/stop/tick`，必要的 `KeroTests/PaneRetentionTests.swift`。

**当前依赖：** `TabSwitcherController` 用 `ObservableObject` 处理按住 Ctrl-Tab 后的预选与释放提交，持有原项目弱引用和预览任务；与项目的真正 `selectedTabID` 不应在按键未释放时混为一份状态。

**实现：** `TabSwitcherController` 保持窗口局部短时预选与真实 `Project.selectedTabID` 分离，改成 `@Observable` 配合 View 的 `@State`；保留 Esc 取消、释放 Ctrl 才提交、键盘优先、仅鼠标真实移动可选中。`PalettePointerSelectionController` 的空 `ObservableObject` 继承和指针输入清理由 P6-T2 统一处理，不重复修改。窗口局部 `FPSCounter` 继续拥有真实 `CADisplayLink`、弱代理/停止清理，将其唯一 `fps` 展示属性改为 `@Observable`，当前 badge `@StateObject` → `@State`；只改 UI 观察，不重写 FPS 原生采样。**本 Task 删除 TabSwitcher/FPS 的旧 `@Published` 与旧 `@StateObject`/`@ObservedObject`，不额外建 P6 辅助清理 Task**。

**验证：** `make build`、针对性标签选择检查和隔离原生键盘验收：正序／逆序 Ctrl-Tab、快速重复、Esc、中途关标签／换项目、鼠标静止悬停与滚动，真实项目选中和终端焦点应正确；已承载生命周期验证的 `KeroTests/PaneRetentionTests` 继续通过。

**提交：** 临时切换状态和旧发布器移除、行为验收同一提交。

---

## 阶段完成门槛

窗口／项目／标签／Dock 均有单一可观察 owner；原跨级 UI 广播路径已删除，菜单读取正确 scene 状态。该阶段已实现 UI 与业务确认分离，不允许留下“旧 Manager 仅为继续发布 objectWillChange”这种平行伪状态。
