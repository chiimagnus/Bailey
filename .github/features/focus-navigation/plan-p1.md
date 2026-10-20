# P1：聚焦区域真源与原生内容焦点衔接

**Goal：** 把 `DockGroup.selected`、项目选中的工作标签、活动分屏与真正的原生键盘输入接收者区分开，使工具面板也能获得活动区域焦点。

**Non-goals：** 不做 Files 多选、文件操作、任意快捷键重映射、视觉配色可配置或新的窗口协调器。

**Approach：** 在当前 `Project.dock / DockWorkspaceModel` 上维护最小的**当前有效焦点组 ID**，系统 `NSWindow` key 状态决定是否显示活动焦点，`NSWindow.firstResponder` 是内容键盘焦点的真源。保留每组 `selected`、现有 `@FocusedValue` 和原生焦点回调；不引入全局并行状态管理。

**Acceptance：** 单一活动窗口/项目至多一个活动 Dock 组；切到 Files／Git／Projects 不再假装选中了旧工作标签，真实按键不落到旧原生控件；组移除后焦点自动指向有效组。

**Rules：** 先 Red→Green→Refactor；每个任务同步测试/文档/旧路径清理，不以 Task/SwiftUI State 变更冒充 first responder 已完成转移。

---

<a id="p1-t1"></a>
## P1-T1 区分 Dock 组选择与真实活动组

**源码锚点：** `Bailey/Workspace/DockWorkspaceModel.swift`（`DockGroup.selected`、`root`、`select/move/place/removeTool/syncTabs/restore`）、`Bailey/Workspace/Project.swift.selectedTabID/focusedContent`、`Bailey/Workspace/TerminalManager.swift`（`selectedProjectID` 及菜单目标）与 `Bailey/App/BaileyApp.swift.WindowRootView`（`focusedSceneValue`／key window）。

1. **Red：** `DockWorkspaceTests` 与 `WorkspaceWindowIsolationTests` 先证明当前一个项目可有多个独立 selected 组，但没有工具面板活动组标识；选择文件/工具不能由 `selectedTabID` 推导活动区域。测试单／多组、空组、切项目 A→B→A、组分割／移动／合并／删除、恢复无效组 ID、两个窗口的真实 key 状态，及后台命令不作用于其它窗口。
2. **Green：** 由项目原有 `DockWorkspaceModel` 持有唯一活动组目标（具体最少状态由测试确定）；选择一组中的标签时同时更新活动组，但不覆盖其它组的 `selected`；关闭或移动活动内容、树重排、恢复时按现存组与真实当前输入选择一个有效目标。Key Window/NSApp 是否激活从系统读取，不缓存成第二个永久真源。现有 `TerminalManager` 与 `Project` 仍是窗口/标签所有者。切标签导致的 `autoSaveOnFocusLoss` 调用序列保持原有语义。
3. **覆盖与闭环：** 组合 1/2/6+ 组、纯横/纵/嵌套、工具/工作标签/空组、快速切项目、两个窗口／独立注册、重排/删除后悬空 ID 和恢复时缺失内容、首次显示及多次切换；确认快照树格式、原生对象数量及未保存文件不被错误重建。更新 `docs/features/dock.md`、必要的 `docs/features/session-restore.md`；仅删除已被新焦点真源取代的旧判断。执行相应 XCTest 及能安全执行的原生 GUI，独立中文提交。

---

<a id="p1-t2"></a>
## P1-T2 原生内容与工具面板真实焦点一致

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView.tab/select/content`、`Bailey/UI/Panes/PanelContentView.swift`（`onFocused`）、`Bailey/UI/Panels/{ToolPanelView,ProjectsPanelView}.swift`、`Bailey/Files/FileTreePanel.swift`、`Bailey/Git/GitPanel.swift`、`Bailey/Terminal/TerminalHostView.swift`、`Bailey/Editor/SourceTextEditor.swift`、`Bailey/Browser/BrowserView.swift`、`Bailey/Git/DiffViewerView.swift` 及原生 first-responder 桥。

1. **Red：** 在真实主窗口验证点击编辑器、终端、浏览器、Diff 以及 Projects/Files/Git/区域空白的聚焦回调和 **`NSWindow.firstResponder` 实际对象**。当前工具面板没有 `PanelContentView.onFocused` 同等入口；测试点击 Files 后立即键入或使用菜单不能意外发给旧 Ghostty/编辑器。覆盖新建/重命名 TextField 获取焦点及失焦提交、窗口变 key、从弹窗关闭、输入法组合态。
2. **Green：** 现有的原生 `onBecomeFirstResponder`、`@FocusState` 和 SwiftUI 点击/键盘事件只负责**通知所属组取得活动焦点**；工具面板／空白区域按确实收到的输入激活其组，不能在每次重绘中抢 first responder。需要时为整个工具树建立最小可聚焦入口，不增加不可见遮罩或更换原生 Shell/TextKit/WebKit 宿主。并在原生焦点真实移出时触发已有失焦保存/终端 FocusOut；不能为了使界面变亮就主动派发写入。
3. **覆盖与闭环：** TextKit 中文输入/查找/Undo、Ghostty 输入和剪贴板、WebKit 地址栏/正文、Diff 输入、Files/Git/Projects 行和右键、重命名/新建编辑态、⌘P/Sheet/Settings、应用前后台与两窗口切换、窄面板/明暗/长文件名/语音辅助；验证**真实键入目标与最终编辑字节**。运行 `PaneRetentionTests`、`WorkspaceContentIdentityTests`、`WorkspaceWindowIsolationTests`、`TreeRowHitTestingTests` 和原生 App；发现同一调用链中的旧焦点桥重复处理即在本任务删掉。更新 `docs/features/dock.md` 和实际改变的工具文档，独立中文提交。

---

## Phase Audit

仅 P1 真正完成、所有适用条件及已执行测试有证据后创建 `audit-p1.md`；不能以代码已有 `onFocused` 声明跨面板 Focus 已实现。
