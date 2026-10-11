# P3：项目、窗格与窗口协调的所有权边界

**Goal：** 消除 `Project` 对 App 设置单例的直接依赖，将窗格数据类型与窗口协调者放到真正拥有它们的 Workspace 域；独立归置被工作区复用的底部工具栏与标签外观，保持当前两层分屏、项目和会话恢复。

**Non-goals：** 不把 `Project`、`TerminalManager` 强行拆成多个小服务，不重命名所有调用点，不把 `DockNode` 与 `PaneNode` 合并，不建立通用 ViewModel/Coordinator/Repository 接口层。

**Approach：** 先从 `TerminalManager.makeProject()` 与 `Project.init` 的真实创建路径下手，把必需的配置值显式传入；再将窗格数据与窗口协调实现移至 Workspace，保留类型名、对象身份和现有持久化入口。随后仅将根 `ContentView` 中的独立底部工具栏与标签外观移到 `UI/Components`，不修改交互。

**Acceptance：**
- `Project` 初始化不读取 `AppSettings.shared`；新项目仍按用户工作区配置建立默认布局，已有项目按各自快照恢复。
- `DockNode` 与 `PaneNode` 仍为不同层次；分屏、焦点、拖动、跨项目切换均不重建现存 TerminalSession/Editor/Diff。
- `TerminalManager` 仍由 `WindowRootView` 每窗口创建；跨窗口保存/恢复、SSH 文件请求与命令菜单仍到正确窗口，不增加第二套全局窗口注册或存档机制。
- `ContentView` 不再承载被其它 View 使用的底部工具栏和整套标签外观；弹窗、焦点、鼠标悬停与 Kero 标签样式不变。

**Rules：** 现有 `SessionStore` / `TerminalHistoryStore` 已有磁盘读写职责；`TerminalManager` 负责聚合各窗口快照。若移动文件，先证明现有 owner 边界确实在这里，不能为了减少行数拆分状态。更改持久化路径前先保护真实快照。

---

<a id="p3-t1"></a>
## P3-T1 让项目显式接收初始工作区配置

**类型 / 依赖：** 原子依赖方向调整；依赖 P2 完成。

**Files / 锚点：**
- `kero/Workspace/Project.swift::init(fallbackName:)` 当前直接访问 `AppSettings.shared.workspaceConfiguration`。
- `kero/Terminal/TerminalManager.swift::makeProject()` 创建所有项目，包括新建和 `restore(from:)` 复原。
- `kero/App/AppSettings.swift::workspaceConfiguration` 及 `DockWorkspaceModel(configuration:)`。

**当前依据：** `Project` 是业务状态持有者，不负责解析 TOML；AppSettings 是应用设置输入。现在由项目直接读取单例，造成了反向依赖，而调用方已经拥有集中创建路径。

**实施：**
1. 给 `Project` 构造函数增加所需的 `DockWorkspaceConfiguration` 值；在 `TerminalManager.makeProject()` 这个实际组装入口传入现有配置，不把整个 `AppSettings` 对象注入项目。
2. 核对所有 `Project` 构造路径（新项目、SSH/本地添加、窗口恢复），保证配置默认值与以前相同；保留 `DockWorkspaceModel.restore` 对已保存布局的优先级。
3. 删除 `Project` 中已不需要的设置单例访问和因此产生的无用代码；不在此任务扩展配置格式或添加 DI 框架。

**验证：** `scripts/check-dock-workspace.swift` 回归默认/自定义配置与恢复；签名 Debug 新建、重启、添加本地/SSH 项目、恢复多个窗口/项目时布局与标签顺序不变；按项目配置只影响新建项目的现有约定验收；`git diff --check`。

**提交边界：** 单向注入项目初始配置和删除反向依赖，一个提交。

---

<a id="p3-t2"></a>
## P3-T2 窗格状态模型与渲染源码分离

**类型 / 依赖：** 原子文件归属迁移；依赖 P3-T1。

**Files / 锚点：**
- Move: `kero/UI/Panes/Panes.swift` → `kero/Workspace/Panes.swift`（`PaneContent`、`PaneNode`、`PaneSplit`、`PaneTab` 的实际状态/操作）。
- Keep: `kero/UI/Panes/PaneLayoutView.swift` 与 `TabSwitcherView.swift` 在 UI 层。
- Consumers: `Project.tabs/selectedTabID`、`DockWorkspaceModel`、`WorkspaceDockView`、`SessionSnapshot.ProjectSnapshot.TabSnapshot`。

**当前依据：** `Panes.swift` 声明业务布局树和长寿命 PaneTab 状态，而不是 SwiftUI 视图；单一 Target 允许它位于 Workspace。一个工作标签内部的分割树与外层 Dock 树有不同的持有者。

**实施：** 不改 `PaneNode` 的递归规则、节点 UUID、`PaneTab.layout` 的 Combine 发布和保存/恢复编码；直接迁移整个模型文件，先不为“纯模型”拆出一套第二份内容枚举。删除旧路径、核对所有编译调用点与文档引用，继续由 `PaneLayoutView` 绘制。

**验证：** Debug 编译/签名；窗口中上下左右拆 Pane，移动已分割标签、跨项目选中/关闭、编辑器未保存标记与 Diff/WebKit 保持挂载；重启后内部焦点与布局仍正确。变更前后签名 Debug 对照 P1 基线，`git diff --check`。

**提交边界：** 内部窗格模型迁移与必要引用更新一个提交。

---

<a id="p3-t3"></a>
## P3-T3 窗口协调者从 Terminal 目录归入 Workspace

**类型 / 依赖：** 原子归属迁移和职责核对；依赖 P3-T2。

**Files / 锚点：**
- Move: `kero/Terminal/TerminalManager.swift` → `kero/Workspace/TerminalManager.swift`（暂保留已有类型名，避免更名波及全仓）。
- Consumers: `kero/App/keroApp.swift::WindowRootView/KeroCommands`、`kero/UI/ContentView.swift`、`kero/UI/WorkspaceDockView.swift`、`Remote/KeroSSHBridge.swift`。
- Persistence: `TerminalManager.snapshot/restore(from:)/saveAll` 及 `kero/Workspace/SessionStore.swift`、`kero/Terminal/TerminalHistory.swift`。

**当前依据：** 尽管类型名为 `TerminalManager`，它实际拥有项目列表、窗口焦点/注册、恢复请求、文件/浏览器/Diff 命令及快照聚合；它是窗口协调者，不是 Ghostty 终端驱动。现有存档写入由 SessionStore/TerminalHistoryStore 执行，未发现为此另建持久化 Service 的理由。

**实施：**
1. 原样迁移文件并核对 Xcode 同步、调用者、文档路径；不借迁移同时做大规模 API 更名、切断 Combine 发布或改变 `static registry`。
2. 对照项目和终端的状态归属，保留窗口级选择/菜单/恢复协调；具体终端会话仍由 `TerminalSession` 及 Ghostty 适配负责，项目标签/布局仍由 `Project`。
3. 如果在审查中发现**确实属于别的已存在模型**的纯操作，只允许在另一个明确任务中处理；本任务不为缩短文件拆出空壳 `WindowService`。

**验证：** 签名 Debug 多窗口、新增/删除/移动项目、菜单定位到前台窗口、恢复多个窗口和各自项目/标签/历史、SSH Finder/本地路径请求等现有可到达路径；核对调用结果而非事件发送成功。保护当前任务/未保存文件，运行 `git diff --check`。

**提交边界：** 窗口协调者的物理归属和必要路径引用一个提交；逻辑分层审查结论留在阶段证据，不借此引入新服务。

---

<a id="p3-t4"></a>
## P3-T4 将底部工具栏及其原生控件移出 ContentView

**类型 / 依赖：** 单一 UI 组件归属调整；依赖 P3-T3。

**Files / 锚点：**
- Extract from `kero/UI/ContentView.swift`: `BottomToolbarLayout`、`BottomToolbarView`、`BranchSearchField`、`ToolbarContextMenuMonitor`、`ToolbarContextMenuMonitorView`、`ToolbarContextMenuEvent`、`InstantPopoverPresenter`。
- New: `kero/UI/Components/BottomToolbarView.swift`。
- Consumer: `kero/UI/WorkspaceDockView.swift::DockTabGroupView` 的 `BottomToolbarView`，以及 `UI/Panels/ProjectsPanelView.swift` 对 `BottomToolbarLayout.height` 的引用。

**当前依据：** 根 `ContentView` 仅创建工作区并呈现空状态；底部 Git 工具栏（分支选择、按钮上下文菜单、原生 Popover）是被 Dock 视图复用的独立 UI 组件，与根 View 的生命周期管理不是同一职责。

**实施：** 整体迁移既有工具栏及其私有 AppKit bridge/Popover 组件，移动后删除旧定义；原 `BottomToolbarLayout` 仍是唯一高度来源，不复制高度常量。保持 GitStatusModel 的窗口级持有者不变，工具栏只接收现有 `@ObservedObject model` 和操作闭包，不借机新增 Git 命令或状态所有者。

**验证：** Debug 编译签名；底部工具栏的分支搜索、键盘焦点、悬停、Git 面板切换、Popover 关闭、窗口缩放与顶底栏高度均和 P1 基线一致；窄面板与深浅主题不偏移。确认旧类型只有一份，`git diff --check`。

**提交边界：** 底部工具栏组件的一个原子迁移提交。

---

<a id="p3-t5"></a>
## P3-T5 将标签外观与重命名控件收敛为复用组件

**类型 / 依赖：** 单一 UI 组件归属调整；依赖 P3-T4。

**Files / 锚点：**
- Extract from `kero/UI/ContentView.swift`: `PaneTabItem`、`TabRenameChrome`、`SessionTabLabel`、`FileTabLabel`、`BrowserTabLabel`、`DiffTabLabel`、`TabItemChrome`。
- New: `kero/UI/Components/TabChrome.swift`。
- Consumer: `kero/UI/WorkspaceDockView.swift::DockTabGroupView`（工作标签与工具标签）；`UI/Panes/TabSwitcherView.swift` 等实际调用者按源码核对。

**当前依据：** `PaneTabItem` 和 `TabItemChrome` 被自由停靠视图调用，却定义在根视图 `ContentView.swift` 的末尾；标签 hover 替换图标为关闭、选中样式、未保存标记、名称变化及焦点都是共同的现有设计语义。

**实施：** 将完整的标签视图和各内容类型 label 一并移入唯一组件文件，保留真实 `PaneTab` 对象订阅与原有按钮动作，不新建第二套标签样式；需要跨文件可见的最小声明才调整作用域。原根 `ContentView` 只保留其布局/空状态职责。

**验证：** 签名 Debug 真机检查新建/关闭、hover 显示左侧关闭、标签重排与跨分屏拖动、重命名焦点、浏览器/编辑器/Diff 的标题及 dirty 状态、键盘与无障碍；左右/上下嵌套分屏和交通灯避让不退化。确认只有一个 `TabItemChrome` 实现、`git diff --check`。

**提交边界：** 标签外观与重命名控件一个原子提交，不进行设计稿改版。

---

## 阶段审查准入

- `Workspace` 管理项目、外层/内层分屏数据与窗口协调；`Terminal` 保留终端会话和 Ghostty。
- 不因更名/搬迁改变 `Project`、`PaneTab`、`TerminalSession` 身份和会话快照格式。
- 不为让 `TerminalManager.swift` 变短而拆细生命周期状态；经 P3-T3 后仍有重职责须以真实调用链证据决定下个独立 Feature。
- 实施完成才创建 `audit-p3.md`，规划时不预建。
