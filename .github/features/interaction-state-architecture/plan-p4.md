# P4：Projects、Dock 与暂态选择，以及完整回归

**Goal：** 统一可复用的列表视觉语义与键盘实际归属，同时保留
项目/标签/窗口的不同激活、展示、命令目标；清理被替代旧路径。
**Non-goals：** Settings `List` 不共享自定义样式；不实现 Electron DOM 服务，
不新增全 App FocusManager/SelectionStore。
**Approach：** 参考 VS Code editorGroupView 的 active/selected editor 区别，
以及 listWidget 的 Focus/Selection/Anchor；只复用已经存在的
`RowHighlightStyle`、`TreeKeyboardHost` 和领域模型。
**Acceptance：** Projects、Dock、Palette、Tab Switcher 的选中背景、
焦点/右键描边、失焦状态与真实动作一致；右键不意外激活，
关闭目标不丢未保存内容，多窗口不会借用后台焦点。

## P4-T1 Projects 游标/活动项目/菜单的单一事实

**锚点：** `Bailey/UI/Panels/ProjectsPanelView.swift` 的
`cursorProjectID`、`contextProjectID`、`focusProjectList`、
`handleProjectKey`、`SidebarProjectRow`；
`WorkspaceWindowModel.selectedProjectID`；
`BaileyUITests/Workspace/WorkspaceDockUITests.swift`。
**任务：** 核实上下键只移动游标，Return/Space 激活项目，右键不切活动，
长列表删除/重排后游标不残留；删除由旧实现重复拥有的视觉与焦点状态。
**验证：** 项目宿主与隔离 GUI，空/多项目、SSH、删除、重排、拖动、
两窗口/主题/宽度/Esc、实际活动项目；`make build:dev`；
更新 `docs/features/projects.md` 和 `docs/ui.md`。

## P4-T2 Dock 标签的展示/活动/焦点/菜单关闭

**锚点：** `DockWorkspaceModel.selected/activeGroupID/contextTarget`、
`Project.selectedTabID/selectTab`、`WorkspaceDockView`、
`WorkspaceChrome.TabItemChrome`。
**任务：** 对照 upstream EditorGroupView 的 active 与 selected，
禁止用鼠标 hover 或菜单命中推导激活；
确认标签组切换、右键非活动文件标签、⌘W、失焦与未保存保护正确，
合并重复的高亮与上下文状态转发，原子清理旧路径。
**验证：** `make test:DockWorkspaceTests,FileTabPersistenceTests`、
`make build:dev`、隔离 Dock GUI 的多组/窄宽/拖放/菜单/保存失败/窗口；
更新 `docs/features/dock.md`、`docs/ui.md`。

## P4-T3 命令面板与标签切换器，跨界面最终组合验收

**锚点：** `Bailey/UI/CommandPaletteView.swift`、
`Bailey/UI/Panes/TabSwitcherView.swift`、
`Bailey/UI/Components/WorkspaceChrome.swift`、
`TreeRowStyle.RowHighlightStyle`；
`BaileyUITests/Files/SharedTreeUITests.swift`、`WorkspaceRetentionUITests.swift`。
**任务：** 复核暂态输入接管与恢复，避免把 Palette 结果游标当文件 Selection，
避免 Tab Switcher 预览改变持久活动标签；
基于已完成模块仅在共享 owner 消除剩余重复分支，绝不把 Settings 拉进来。
**验证：** 各域宿主测试 + `make build:dev`；
隔离 GUI 交错 Files/Git/Projects/Dock/Palette/Tab Switcher，
Focus/Selection/Context/Displayed/Hover 多因素、明暗主题/中文英文、
原生输入/SSH/多窗口/恢复/改名删除/长列表与特殊字符；
逐项记载 macOS 15.6、触控板、富类型系统剪贴板及真实 SSH 若无法完成的原因与影响。
每一任务同步其所属功能文档；P4 全部完成后执行阶段审计。
