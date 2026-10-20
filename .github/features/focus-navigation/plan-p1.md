# P1：聚焦区域真源与原生内容焦点衔接

**Goal：** 把 `DockGroup.selected`、项目选中的工作标签、活动分屏与真正的原生键盘输入接收者区分开，使工具面板也能获得活动区域焦点。

**Non-goals：** 不做 Files 多选、文件操作、任意快捷键重映射、视觉配色可配置或新的窗口协调器。

**Approach：** 在每个 `Project.dock / DockWorkspaceModel` 中保存**一个瞬时活动组 ID**（独立于会触发快照保存的 `root`）；系统 `NSWindow` key 状态决定可否显示焦点，`NSWindow.firstResponder` 决定键盘实际输入目标。保留组内 `selected`、`Project.selectedTabID` 的 MRU/会话上下文、窗口的 `@FocusedValue` 和已有原生回调；**菜单从活动组解析内容而不是直接复用 `selectedTabID`**。不引入全局 Focus Manager 或新焦点事件总线。

**Acceptance：** 单一活动窗口/项目至多一个活动 Dock 组；切到 Files／Git／Projects 不再假装选中了旧工作标签，真实按键不落到旧原生控件；组移除后焦点自动指向有效组。

**Rules：** 先 Red→Green→Refactor；每个任务同步测试/文档/旧路径清理，不以 Task/SwiftUI State 变更冒充 first responder 已完成转移。

---

<a id="p1-t1"></a>
## P1-T1 区分 Dock 组选择与真实活动组

**源码锚点：** `Bailey/Workspace/DockWorkspaceModel.swift`（`DockGroup.selected`、`root`、`select/move/place/removeTool/syncTabs/restore`）、`Bailey/Workspace/Project.swift.selectedTabID/focusedContent`、`Bailey/Workspace/TerminalManager.swift`（`selectedProjectID` 及菜单目标）与 `Bailey/App/BaileyApp.swift.WindowRootView`（`focusedSceneValue`／key window）。

1. **Red：** `DockWorkspaceTests` 与 `WorkspaceWindowIsolationTests` 先证明当前一个项目可有多个独立 selected 组，但没有工具面板活动组标识；选择文件/工具不能由 `selectedTabID` 推导活动区域。**现有 `Project.focusedContent` 实际返回 `selectedTab?.content`**，直接供 `TerminalManager.clearActiveTerminal/canClearActiveTerminal/performFindAction/canFind/canReplace/saveSelectedFile/canSaveSelectedFile/selectedBrowser` 使用；`closeSelectedTab` 与项目切换自动保存又直接读取 selected work tab；`TerminalManager.autoSaveEditedTabs()` 在窗口 `didResignKey` 时也**只保存 selectedTab**，若同时可见两个脏编辑器会漏掉另一个。逐一测试焦点在工具时不得对旧工作标签做保存/清空/查找/浏览器操作，并区分显式「关闭标签」语义：前台活动组为工作标签时 `⌘W` 关闭该标签；活动组为可关闭的 Files/Git/Projects 时关闭该工具面板，不得关闭其它组的旧 selectedTab；非主窗口如 Settings 应只关闭自身。测试单／多组、空组、切项目 A→B→A、组分割／移动／合并／删除、恢复无效组 ID、两个窗口 key 状态及后台命令。
2. **Green：** 原有 `DockWorkspaceModel` 增加最小、可观察的**瞬时**活动组 ID 与选择/失效回退入口，**不复用 `root.didSet/onSnapshotChange` 写入快照**；组内 `selected` 只更新显示，活动组可切到 Projects/Files/Git/空组。先沿所有实际调用者区分「最近工作标签」和「当前活动内容」：供菜单的内容目标只能从有效的活动组 `selected .tab(id)` 推得，工具组为 nil；`selectedSession`、标签 MRU、项目工作目录等确需最近标签上下文者保留其语义，不盲目全量替换 `focusedContent`。`TerminalManager` 的菜单使能与最终操作目标必须一致；操作性快捷键在工具聚焦时不能落到隐藏工作标签。窗口 key 状态不复制存储；显式工作标签选择统一走 `Project.selectTab`；`selectedTabID` 只记最近标签，关闭记账不得隐式激活区域。保存保护由 Dock 的实际内容失活回调接续，转入工具组的**真实编辑失焦**同样保存，不让视图重挂载把保存触发重复或漏掉；窗口失去 key 时应覆盖同窗口**实际存在的所有脏文件与可编辑 Diff**，复用已有 `autoSaveOnFocusLoss`/保存队列，不假定仅有一个工作标签，更不能对后台窗口错误保存。
3. **覆盖与闭环：** 组合 1/2/6+ 组、纯横/纵/嵌套、工具/工作标签/空组、快速切项目、两个窗口／独立注册、重排/删除后悬空 ID、项目恢复及无效组回退；断言**纯活动组切换不触发 `onSnapshotChange/SessionStore` 写盘**、其它组 selected 不变、未保存编辑未丢、同一原生表面不重建。执行 `DockWorkspaceTests`、`SessionStoreTests`、`WorkspaceWindowIsolationTests` 及真实 GUI 的菜单目标验证，包含 `⌘W/S/F/K/L/R`、工具组中 `⌘W` 的可见关闭结果、Settings 的独立 `⌘W`、一个窗口同时两个脏工作分屏失去 key（最终核对两份磁盘内容）及原生窗口 key 切换。更新 `docs/features/dock.md`、必要的 `docs/features/session-restore.md`；同任务删除已取代的旧菜单/焦点目标判断，不保留兼容桥接；中文原子提交。

---

<a id="p1-t2"></a>
## P1-T2 原生内容与工具面板真实焦点一致

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView.tab/select/content`、`Bailey/UI/Panes/PanelContentView.swift`（`onFocused`）、`Bailey/UI/Panels/{ToolPanelView,ProjectsPanelView}.swift`、`Bailey/Files/FileTreePanel.swift`、`Bailey/Git/GitPanel.swift`、`Bailey/Terminal/TerminalHostView.swift`、`Bailey/Editor/SourceTextEditor.swift`、`Bailey/Browser/BrowserView.swift`、`Bailey/Git/DiffViewerView.swift` 及原生 first-responder 桥。

1. **Red：** 在真实主窗口验证点击编辑器、终端、浏览器、Diff 以及 Projects/Files/Git/区域空白的聚焦回调和 `NSWindow.firstResponder`。当前 `PanelContentView(isSelected: project.selectedTabID == id)` **误把项目最近标签当分屏焦点**，且 Diff 分支固定传 `isSelected: true`、工具面板无聚焦回调；测试同一项目两个可见工作分屏、切到 Files 后再键入/使用菜单、跨窗口激活、失焦编辑缓冲的真实保存。覆盖新建/重命名 TextField、Sheet、查找栏与输入法组合态。
2. **Green：** `DockTabGroupView` 的点击/原生 `onBecomeFirstResponder` 将所属组设为活动；`PanelContentView` 的工作内容 `isFocused` 应从**真实活动组 + 此组当前 `selected` + 前台窗口**取得，而不是全局 `selectedTabID`。保留已验证的 `TerminalHostView` 失焦→聚焦边缘请求、TextKit 焦点桥、WebKit 地址栏/正文焦点，不在 `body` 重绘时重新派发强制聚焦；Diff 的 `isSelected` 只表达其原有可见/刷新需求，确需操作焦点时通过实际编辑控件/明确动作通道建立，不把该 bool 改成误导的 Focus。工具面板、组标题/空白区域提供最小可聚焦交互，不增加透明覆盖层、另一套 `NSHostingView` 或事件总线；切离脏编辑器时沿现有失焦保存链触发一次正确保存。
3. **覆盖与闭环：** TextKit 中文输入/查找/Undo、Ghostty 输入/查找与剪贴板、WebKit 地址栏/正文、Diff 编辑、Files/Git/Projects 行和右键、重命名/新建编辑态、⌘P/Sheet/Settings、应用前后台/两个窗口/同时显示两个工作标签、窄面板/明暗/长文件名/基础无障碍；验证**真实键入目标、原生响应者与最终保存字节**，尤其 `NSWindow.didResignKey` 保存的是刚离开的实际编辑内容而非无关 selectedTab。运行 `PaneRetentionTests`、`WorkspaceContentIdentityTests`、`WorkspaceWindowIsolationTests`、`TreeRowHitTestingTests` 和原生 App；同任务删除本次取代的旧焦点判断/重复回调。更新 `docs/features/dock.md` 与实际改变的功能文档；中文原子提交。

---

## Phase Audit

仅 P1 真正完成、所有适用条件及已执行测试有证据后创建 `audit-p1.md`；不能以代码已有 `onFocused` 声明跨面板 Focus 已实现。
