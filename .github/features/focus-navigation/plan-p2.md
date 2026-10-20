# P2：焦点视觉、路由与全窗口验收

**Goal：** 前台活动组、组内 selected 标签、原生内容键盘焦点各有清楚但不冲突的反馈，并在完整停靠生命周期保持一致。

**Non-goals：** 不创建焦点样式设置、不改变未请求的 Tree/Git 外观、不实现 Files 多选集合（#5）、不实现可编辑快捷键映射（#43）。

**Approach：** `WorkspaceDockView` 直接消费 P1 的组目标与系统 key window 状态；复用 `Theme`、`TreeRowSurface` 原有 selected/focused 基础，不新增一套标签/树组件。菜单仍经 `BaileyApp` 当前窗口 focused manager 分发。

**Acceptance：** 后台不显示假活动焦点、前台仅一个组有可感知的强调；多选与键盘行焦点的不同由 #5 在共享树表面上接入；正常窗口切换、拖动、关组后快捷键与首响应者吻合。

**Rules：** 视觉不得冒充键盘焦点，拖放 hover/previews 不算已切焦点；不牺牲菜单目标、编辑保存、原生控件焦点。

---

<a id="p2-t1"></a>
## P2-T1 Dock 组与选中标签的统一焦点视觉

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView`（`header/content`）、`Bailey/UI/Components/WorkspaceChrome.swift.TabItemChrome`、`Bailey/Shared/Tree/TreeRowStyle.swift.TreeRowSurface`、`Bailey/App/Theme.swift` 及 `Bailey/UI/Panels/ToolPanelView.swift`。

1. **Red：** 对照当前 selected tab 背景与工具面板行态，验证旧 UI 只显示各自选中却不能标明窗口/区域级活动焦点；实测两窗口失焦后是否仍有高亮、Hover 是否能误判聚焦。涵盖深浅主题、窄宽区域、不同编辑/终端/Diff/工具组。
2. **Green：** 在当前活跃窗口仅为被 P1 选中的 Dock 组绘制克制的原生强调（例如统一边界/标题条对比），不改变它组的 `selected`。同组真正 selected 标签可加一层适量区别；其它组虽有 selected 但不显示 active。对于共享 `TreeRowSurface`，沿现有参数区分行选中与键盘聚焦，而不是把 `focused=true` 当成「Files 多选」或对全部 Git 行强行换样式。Files 选中集合仍待 #5 P1-T1 接入；基础焦点样式不得覆盖文件状态色。
3. **覆盖与闭环：** 单/多/6+ 组、浅暗、动态主题、缩放、超长标签/路径、窄栏、鼠标 hover/drag、不同窗口 key 状态、Settings/Sheet/菜单、辅助功能文字与形状提示；检查尺寸无抖动且 Terminal/TextKit/WebKit 实例不重建。更新 `docs/ui.md`、`docs/features/dock.md`；验证真实像素与输入接收者、跑 `DockWorkspaceTests` 和原生 GUI；清理被替代的旧视觉判断，独立中文提交。

---

<a id="p2-t2"></a>
## P2-T2 拖放、窗口与快捷键的焦点恢复联动

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabDragCoordinator.finish`、`Bailey/Workspace/DockWorkspaceModel.swift.move/place/removeTool/restore`、`Bailey/Workspace/TerminalManager.swift`（导航、窗口目标及 `restoreFocusAfterCommandPalette`）、`Bailey/App/BaileyApp.swift.BaileyCommands`、`Bailey/UI/CommandPaletteView.swift`、`Bailey/Editor/FileViewerView.swift.autoSaveOnFocusLoss`。

1. **Red：** 真正拖动工具面板与工作标签到不同组/边缘、关闭唯一活跃组、恢复带旧 group ID 的布局、打开/关闭 ⌘P、切前台和两个窗口，再执行 ⌘F/⌘S/⌘C/⌘V 与终端输入，确认实际路由、原生第一响应者和不丢未保存数据。Drag hover 期间不允许改变活跃组，落地后仅新有效组成为活动目标。
2. **Green：** 对现有 Dock 移动成功的唯一入口补齐 P1 的活动组转移或有效 fallback；使用现有 `@FocusedValue` 路由当前窗口，不实现第二个菜单目标或自定义快捷键框架。关闭临时焦点输入（palette/rename/sheet）后在其所属窗口恢复可用的内容焦点；不在 App 后台抢键盘，也不吞掉终端编辑快捷键。
3. **覆盖与闭环：** 纯横/纵/多层嵌套、合并/拆分/取消拖动、窗口和 App 激活、Files/Projects/Git/Browser/TextKit/Diff/终端、Settings 打开关闭、P1 文件未保存与重命名状态、SSH 断线时工具切换、五分屏长期运行。逐项对比 actual firstResponder、命令作用的项目/Tab、保存后真实文件内容、视图对象身份和帧率。用 `DockWorkspaceTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`、`WorkspaceContentIdentityTests` 与完整签名 App E2E 验证。相关 `docs/features/{dock,editor,command-palette,session-restore}.md` 当次同步；清理本任务替代路径，独立中文提交。

---

## Phase Audit

仅 P2 全部实施与最大可行测试覆盖真实完成后创建 `audit-p2.md`。完成本计划是 #5 文件多选键盘事件的**前置焦点契约**，不等于 #5 已具备任何批量文件操作。
