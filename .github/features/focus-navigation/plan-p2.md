# P2：焦点视觉、路由与全窗口验收

**Goal：** 前台活动组、组内 selected 标签、原生内容键盘焦点各有清楚但不冲突的反馈，并在完整停靠生命周期保持一致。

**Non-goals：** 不创建焦点样式设置、不改变未请求的 Tree/Git 外观、不实现 Files 多选集合（#5）、不实现可编辑快捷键映射（#43）。

**Approach：** `WorkspaceDockView` 消费 P1 的瞬时活动组与系统 key window 状态，不将焦点放进布局快照。复用 `Theme` 与共享树行，不新增标签/树组件。菜单经 `BaileyApp` 当前窗口 focused manager 分发，但**实际内容目标必须匹配活动组**。

**Acceptance：** 默认无全组描边、非活动组不整体降透明度，只有前台真实活动组的 selected 标签文字和图标强调；多选与键盘行焦点的不同由 #5 在共享树表面上接入；正常窗口切换、拖动、关组后快捷键与首响应者吻合。

**Rules：** 用户当前偏好 Zed 焦点层级而非旧蓝框原型，视觉不得冒充键盘焦点，拖放 hover/previews 不算已切焦点；不牺牲菜单目标、编辑保存、原生控件焦点。

---

<a id="p2-t1"></a>
## P2-T1 Dock 组与选中标签的统一焦点视觉

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView`（`header/content`）、`Bailey/UI/Components/WorkspaceChrome.swift.TabItemChrome`、`Bailey/Shared/Tree/TreeRowStyle.swift.TreeRowSurface`、`Bailey/App/Theme.swift` 及 `Bailey/UI/Panels/ToolPanelView.swift`。

1. **Red：** 对照当前 selected tab 背景与工具面板行态，验证旧 UI 只显示各自选中却不能标明窗口/区域级活动焦点；实测两窗口失焦后是否仍有高亮、Hover 是否能误判聚焦。涵盖深浅主题、窄宽区域、不同编辑/终端/Diff/工具组。
2. **Green（用户 2026-10-21 最新反馈覆盖旧原型）：** 参考 [Zed Pane 官方实现](https://github.com/zed-industries/zed/blob/main/crates/workspace/src/pane.rs) 的 `has_focus` 和标签 `deemphasized`，以及 Zed 的默认零边框/完整不透明度，不再绘制任何整组蓝色描边或叠加独立标签栏强调。各分屏原有 selected 标签背景保留，活动组仅对 selected 标签的文字、图标保持高对比度，其余组去强调，不额外复制主题配置或装饰；后台、Palette、Sheet 不显示虚假输入焦点。`TreeRowSurface.focused` 当前只是与 hover 相同的 0.05 透明度填充，**不是可辨认的键盘焦点环**：#13 仅负责 Dock 组视觉，不预先给 Git/Files 所有行加外观；#5 P1-T1 按实际 Files 键盘导航需要，复用行组件的 `focused` 参数并补可识别的行焦点反馈。
3. **覆盖与闭环：** 单/多/6+ 组、浅暗、动态主题、缩放、超长标签/路径、窄栏、鼠标 hover/drag、不同窗口 key 状态、Settings/Sheet/菜单、辅助功能文字与形状提示；检查尺寸无抖动且 Terminal/TextKit/WebKit 实例不重建。更新 `docs/ui.md`、`docs/features/dock.md`；验证真实像素与输入接收者、跑 `DockWorkspaceTests` 和原生 GUI；清理被替代的旧视觉判断，独立中文提交。

---

<a id="p2-t2"></a>
## P2-T2 拖放、窗口与快捷键的焦点恢复联动

**源码锚点：** `Bailey/UI/WorkspaceDockView.swift.DockTabDragCoordinator.finish`、`Bailey/Workspace/DockWorkspaceModel.swift.move/place/removeTool/restore`、`Bailey/Workspace/TerminalManager.swift`（导航、窗口目标及 `restoreFocusAfterCommandPalette`）、`Bailey/App/BaileyApp.swift.BaileyCommands`、`Bailey/UI/CommandPaletteView.swift`、`Bailey/Editor/FileViewerView.swift.autoSaveOnFocusLoss`。

1. **Red：** 真正拖动工具与工作标签到其它组/边缘、关闭活动组、恢复布局、打开/关闭 ⌘P、切前台与两个窗口，再执行 ⌘F/S/K/W/L/R、⌘C/V 及终端输入，核对实际命令目标、first responder、文件字节与快照。特别复现 `TerminalManager.restoreFocusAfterCommandPalette` 目前仅判断旧 responder 类型仍稳定：旧终端**可能被 `TerminalParkingContainerView` 挂在同一窗口但已非可见活动组**；`TerminalFind.restoreTerminalFocus` 也只核对 window key，不核对源组是否仍活动。`CommandPaletteView.run` 会先 dismiss 再执行命令，因此 **Palette 执行「显示 Files」「切项目／终端」「打开文件」后 onDisappear 的旧 responder 恢复，不能覆盖新命令设置的真正活动组**。Drag hover 不能切焦点，落地后应转到实际有效组。
2. **Green：** 在既有 `DockWorkspaceModel.move/place/removeTool/syncTabs/restore` 与 `DockTabDragCoordinator.finish` 的实际成功路径维护 P1 的唯一活动组/有效 fallback，不因预览改变。`DockGroupFocusView` 鼠标事件监听只报告区域变化，不能在鼠标按下、原生文本/查找框收到输入前调用 `window.makeFirstResponder`；需让原生控件先获得响应者，工具/空组的必要补位在随后进行。沿现有 `@FocusedValue`/`TerminalManager` 路由菜单，**修正仍按旧 `selectedTabID` 错投的命令**；用户明确选择标签的动作继续以其显式目标为准。⌘P/查找栏/rename/sheet 关闭时，恢复的原生 responder 必须仍在**当前 key window 的实际活动组与可见视图层级**，并且属于本次打开临时界面时实际被打断的内容；Palette 内从列表执行菜单动作时必须以命令产生的新目标为准；否则交给当前活动内容或保持无焦点，不能把 parked Ghostty、旧编辑器或后台窗口抢回。先复用现有焦点恢复入口并删除重复抢焦点分支，不创建统一恢复协调器。
3. **覆盖与闭环：** 纯横/纵/6+ 嵌套、合并/拆分/拖放取消、活动组被删除/替换、窗口和 App 激活、Files/Projects/Git/Browser/TextKit/Diff/Ghostty、Settings/Sheet/原生 Find/Palette/rename 间转换，特别包含 **Palette 取消 vs 执行命令、关闭后立刻切项目、终端被停车、旧编辑器已关闭、旧窗口已关闭、窗口切走又返回**；双窗口、SSH 断线、五分屏长用、保留失焦前脏缓冲、Undo 与中文输入。逐项比对真实 first responder、前台组、命令所作用的文件/标签/机器、最终字节、原生对象身份与资源；不能以 `isFocused=true` 或 `NSView.window != nil` 代替输入焦点。用现有 `DockWorkspaceTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`、`WorkspaceContentIdentityTests` 及完整签名 App GUI 验收。`docs/features/{dock,editor,command-palette,session-restore}.md` 按实际改变同步，本任务即刻删除被取代的旧恢复逻辑；中文提交。

---

## Phase Audit

执行取证补充：P2-T2 的真实窄分屏验收发现终端查找框固定单行宽度会把输入框推出窗口（150/210 pt、明暗两态均有原生 Red）。本任务用 `ViewThatFits` 在窄栏保留完整两行控件、宽栏保持原样；同时约束查找栏的延迟聚焦/全选与重挂载恢复，不能把“仍开启的查找栏消失了一次”当作关闭并抢回正文。属于原有窄面板与临时输入恢复验收，不改变用户功能或最低系统。

仅 P2 全部实施与最大可行测试覆盖真实完成后创建 `audit-p2.md`。完成本计划是 #5 文件多选键盘事件的**前置焦点契约**，不等于 #5 已具备任何批量文件操作。
