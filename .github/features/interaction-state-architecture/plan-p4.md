# P4：Projects、Dock 标签/活动组、批量选择与暂态输入

**目标：** 对照 VS Code EditorGroup/EditorTabs 的真实状态机，把
活动组、展示标签、标签多选、范围 Anchor、菜单目标、鼠标 Hover、拖放意图、
临时 Ctrl+Tab/Palette 预览与真实 NSWindow.firstResponder 分开；
支持当前 Bailey 的文件、终端、浏览器、Diff 与工具 tab 全部参与任意 Dock 布局，
不复制 Electron 窗口或随 View 更新重新创建原生内容。

**上游已核对：**
- `editorGroupView.ts:setSelection/openEditor/doShowEditor/setActive`：
  ActiveEditor、SelectedEditors、PreviewEditor 与组 Active 独立；
- `multiEditorTabsControl.ts:registerTabListeners/selectEditor/`
  `selectEditorsBetween/unselectEditor/onDragStart`：
  Mac ⌘切换单个标签、Shift 范围选择、Anchor、批量拖动/右键；
- `editorTabsControl.ts:onTabContextMenu`：
  点击的 group/editorIndex 作为命令上下文，不强制激活后台 tab；
- `editorPart.ts:doSetGroupActive/addGroup/removeGroup` 和
  `editorDropTarget.ts:handleDrop`：活动组、真实布局、组/标签/外部文件 Drop；
- `editorParts.ts`：多窗口的焦点和最近激活组分开；
- `multieditortabscontrol.css`：活动/失焦/selected-but-inactive/hover
  四类标签背景文字，不能全部简单套树行样式。

**Bailey 域主：**
`WorkspaceWindowModel` 拥有当前窗口项目；
`Project.selectedTabID` 是最近的工作标签/MRU，不等于每组当前展示；
`DockWorkspaceModel.root/groups/activeGroupID/contextTarget`
管理停靠结构与活动组，每个 `DockGroup.selected` 决定组内显示；
`DockTabDragCoordinator` 管理拖放临时态；
`TabSwitcherController` 管理 Ctrl+Tab 暂态预览。
Settings 保持原生 List，完全不参与。

**重要产品边界：** VS Code 编辑器 tab 与 Bailey Dock **包含工具 tab** 不完全等价。
新增多选时必须分别约束 singleton 工具、文件、Diff、终端、浏览器等可复制/
可移动/可关闭性；不能复制运行中的 PTY/WebKit 或允许 Projects/Files/Git 工具重复实例。
如果没有安全可定义的“复制这个 DockItem”，就显示不可复制而不是误执行。
普通点击保持一个展示项，不重新引入 VS Code 自动替换预览文件标签。

---

## P4-T1 Projects 键盘游标、当前项目和菜单目标独立

**源：** VS Code List/Tree 的 Focus、Selection、Anchor 与 Scoped Context；
Projects 是 Bailey 固有列表，按相同列表行为验证，但不变成文件树/EditorTabs。

**锚点：** `Bailey/UI/Panels/ProjectsPanelView.swift` 的
`cursorProjectID`、`contextProjectID`、`keyboardOwner`、
`handleProjectKey`、`focusProjectList`、`SidebarProjectRow`、
`projectFrames/updateProjectDrag`；
`WorkspaceWindowModel.selectedProjectID`、`close(project)`、
`Project` 的固定目录/SSH 身份。

**步骤：**
1. 先记录真实事件：单击、↑↓、Return/Space、右键目标项目、
   Esc/关闭菜单、工具栏「＋」和项目拖动；每个事件对游标、当前项目、
   Dock/Terminal 当前组、NSWindow firstResponder 的影响必须明确。
2. Red：3+ 本机/SSH 项目，当前 A/游标 B/右键 C；
   上下键只移动游标，Return/Space 才切项目；
   菜单关闭不切项目，关闭 C 时保存失败必须保留原窗口及项目；
   删除游标项目/重排/拖动/失焦/切到其它 Dock 组后 cursor ID 无幽灵。
3. 在 ProjectsPanelView 局部 owner 清理镜像焦点/重复激活动作，
   项目切换仅调用已有 WorkspaceWindowModel 入口，
   不增加本机路径相同但机器不同的错误身份匹配。
4. AX 真实当前项目标记、Focus 轮廓和临时 Context 边框分开；
   与 Files/Git 共用仅确实相同的绘制语义，项目本身不支持无意义的文件多选。

**验证：** `DockWorkspaceTests`、`WorkspaceIdentityTests`、
`WorkspaceDockUITests`、`WorkspaceWindowsUITests`；
空/1/N 项目、SSH/本机同名、重排、关闭未保存、弹出选择器、
键盘/拖动/双窗、明暗/窄宽/中英/AX，
实际项目根目录与终端会话未被错误删除；
`make build:dev`。Docs `docs/features/projects.md`、必要 `docs/ui.md`；
一个提交。

---

## P4-T2 DockGroup 展示、活动、最近标签和菜单目标归属

**源码：**
`editorGroupView.ts:activeEditor/setSelection/setActive`；
`editorPart.ts:doSetGroupActive`；
`editorTabsControl.ts:onTabContextMenu`。
上游 `activeEditor`、`selectedEditors`、`groupActive` 独立，
右键未显示 tab 不必先打开。

**锚点：**
`Bailey/Workspace/DockWorkspaceModel.swift` 的
`DockNode/DockGroup.selected/root/activeGroupID/contextTarget/`
`closeTarget/select/activate/updateLayout/syncTabs`；
`Bailey/Workspace/Project.swift:selectedTabID/selectTab`、
`recentTabIDs`；
`Bailey/UI/WorkspaceDockView.swift:DockTabGroupView`、
`focusGroup/select/tabStrip`；
`Bailey/UI/Components/WorkspaceChrome.swift:TabItemChrome`。

**步骤：**
1. 先建立组级事实表：各组显示 A/B vs 活动组 C，
   Project.selectedTabID 只更新工作标签 MRU；
   一次 tab 单击不应同步覆盖其它组 displayed；
   右键 B 不应把 B 改成 active/current display；
   上游多选 `selectedEditors` 后续归 P4-T4。
2. Red：两组各有不同 File/Terminal/Tool，
   点击后台标签、空标签区/按钮、右键另组文件/工具、
   ⌘W、点击其它组后关闭原标签；
   关闭保存失败不挪动 current group，不丢 undo/terminal input。
3. 在 DockWorkspaceModel 唯一布局 owner 维护活动/展示/菜单目标；
   Project 的 MRU/selectedTabID 不能替代某组 `selected`，
   View 只转发明确 click/context/drop；
   删除旧的激活推断或多余视觉本地状态，
   保留 group-scoped autofocus 与用户既有无“蓝色整组外框”决定。
4. 菜单结束 Context 清空，AX 显示当前 tab 与键盘 Focus 各自真实，
   隐藏/失活 group 不伪造编辑器 firstResponder。

**验证：**
`make test:DockWorkspaceTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests`；
`WorkspaceDockUITests`、`WorkspaceRetentionUITests`；
同组/两组三组、空组、活动工具组、关闭背景/前台、脏文件保存失败、
双窗、窗口最小化/重新激活、宽度极小与 30+ tabs、
主题/字号/AX；`make build:dev`。文档 `docs/features/dock.md`、
`docs/architecture.md`（只在职责真源变化时）、`docs/ui.md`；一个提交。

---

## P4-T3 Command Palette 与 Ctrl+Tab 暂态选择/焦点恢复

**源码：** VS Code `listService.ts` 的 Focus/Selection/Context，
`editorQuickAccess.ts` 与 EditorGroup `openEditor` 的
`preserveFocus` 和 Group 激活；
临时 UI 不应写入 Files/SCM/Dock 的真实选择，直到操作被执行。

**锚点：**
`Bailey/UI/CommandPaletteView.swift` 的 `selection`、
`runSelected`、`onExitCommand`、临时 PointerEvent Monitor、
实际 NSTextField 输入；
`Bailey/UI/Panes/TabSwitcherView.swift:TabSwitcherController` 的
`highlightedTabID/originalTabID/orderedTabIDs/cycle/finish/cancel`；
`WorkspaceWindowModel.toggleCommandPalette`、
`TreeKeyboardHost` 焦点交接。

**步骤：**
1. 明确三个不同对象：Command Palette 高亮结果、
   Ctrl+Tab 待提交的临时 Tab、Dock 每组真正显示/选中标签；
   前两者不能直接更改 Files/Git Selection 或真实活动组。
2. Red：在 Files/Git/Editor/Terminal/浏览器各自的原生输入中打开 Palette，
   搜索框实际能输入，↑↓ 高亮结果、Esc 清查询/关面板，
   当前 group 已变/目标已删除/晚到搜索时不恢复旧 firstResponder；
   Ctrl+Tab 连续循环与 Esc 取消、不按 Control 松开时不提前提交。
3. 保留现有 `TabSwitcherController` 的唯一预览与 MRU，
   不为了统一“选中”把其状态写入 Dock Tab 多选集合；
   只修复已证明的过早提交、错误恢复和重复同步入口，
   删除过时 fallback，尊重 IME 与 keyWindow。
4. Ctrl+Tab 真正提交后必须激活正确现存 tab，
   取消后所有原先活动、显示和未保存数据不变。

**验证：** `DockWorkspaceTests`、`ProjectFileIndexTests`、
`FileTabPersistenceTests`、`WorkspaceSmokeUITests`、
`GitChangesUITests`、`WorkspaceDockUITests`、
`WorkspaceRetentionUITests`；
空/1/多个/删掉的 Tab，连续按键、焦点切窗、中文/英文/IME、
搜索晚到/SSH 失效、窄/宽布局/大量结果；
`make build:dev`。Docs `docs/features/command-palette.md`、
`docs/features/dock.md`；一个提交。

---

## P4-T4 VS Code 式同组多标签 Selection、Anchor 与键盘导航

**真实缺口：**
- `multiEditorTabsControl.ts:registerTabListeners` 中 Mac ⌘ 点击单项 toggle，
  Shift 使用 `lastSingleSelectSelectedEditor` 做 Anchor，
  `selectEditorsBetween` 合并连续范围；
  普通单击选中/激活，按鼠标松开时清理扩选。
- `editorGroupView.ts` 的 `selectedEditors` 不等于 `activeEditor`；
  失去组激活时多选集合可回退当前活动编辑器。
- Bailey 当前只有 `DockGroup.selected`（显示一个）及 Project 最近标签，
  **尚无标签多选集合/范围 Anchor**。

**锚点：**
`DockWorkspaceModel.swift:DockGroup/DockNode`、`select/activate/syncTabs`；
`Project.selectedTabID`；
`WorkspaceDockView.DockTabGroupView.tabStrip/tab/select`、
`WorkspaceChrome.TabItemChrome/PaneTabItem`；
单组/跨组/失活的 `activeGroupID`，`TabSwitcherController` 暂态不参与。

**步骤：**
1. 在 VSCodium/VS Code 实测 `⌘` 选非活动标签/取消活动标签、
   Shift 反向/缩放/离散组合、点击已多选某标签、
   点击工具栏按钮、菜单/键盘导航；
   同时在 Bailey 列出所有 `DockItem`（File、Terminal、Browser、
   Diff、Projects/Files/Git singleton 工具）的合法性与行为边界。
2. 设计**每个 DockGroup 单独的最小非持久选择集合 + Anchor**，
   归 DockWorkspaceModel 或 DockGroup 已存在所有者，
   用 UUID/DockItem identity 对齐列表与变更；绝不把 global selectedTabID
   或真实显示的 `DockGroup.selected` 替换成“多选集合”，也不创建全 App Manager。
   组删/Tab 关/项目换/拖动到别组时更新或清空对应 Anchor 和集合；
   不给多选临时态新增恢复快照。
3. Red→Green：同组单项/不连续/Shift多选、正反延伸、边界首尾、
   ⌘取消当前活动标签时仍保留一个实际显示内容；
   组失焦、多窗口、拖动前后，集合只包含当前合法项；
   工具标签不能被复制成第二个 singleton 实例。
4. 让 TabItemChrome 根据真正 **active displayed、selected-but-inactive、
   group focused/unfocused、hover、context** 绘制不同文字/背景，
   而不是继续用一个 `isSelected` 偷换多个事实。
   必要时使用 Tab 专属 ViewModifier；
   **不修改 Files/Git `TreeRowSurface`，不触及 Settings List**。
5. 恢复 Tab 的本机键盘可达性：Tab Strip 的 ←→/Home/End、
   Enter/Space、Shift+F10（实际系统支持时）、AX selected、
   中键关闭（可用实体鼠标）按上游对照逐项实现；
   不覆盖编辑器、终端原生快捷键或已分配的系统主菜单快捷键。
6. 删除单选假设的旧重复 View 状态，不引入旧版快照双轨；
   已保存文档、浏览器与终端视图必须存活。

**验证：** `DockWorkspaceTests` + 新的模型多选/Anchor 宿主断言、
`FileTabPersistenceTests`、`NativePaneRetentionIntegrationTests`、
`WorkspaceDockUITests`、`WorkspaceRetentionUITests`；
1/2/30+ Tabs、3+ Group、本机和 SSH、同名文件、混合工具/文件/Browser/Terminal/Diff、
多选/失活/关闭/恢复/窗口切换、主题/中英/AX/窄宽、缩放/自定义主题；
`make build:dev`。Docs `docs/features/dock.md`、`docs/ui.md`、
职责确实变更才更新 `docs/architecture.md`；
一个独立原子提交。

---

## P4-T5 多标签批量拖动、拆分/合并和 Copy/Move 约束

**源码：** VS Code `multiEditorTabsControl.ts:onDragStart/onDrop`
以 selectedEditors 为来源；`editorDropTarget.ts:handleDrop`
区分 Editor、Group、TreeItem、External URI，并在成功 Drop 才激活；
`editorTabsControl.ts:isMoveOperation` 对 Mac Option 复制有条件限制。

**Bailey 锚点：**
`Bailey/UI/WorkspaceDockView.swift:DockTabDragCoordinator`、
`DockTabGroupView.tabStrip`、`DockTreeView` 和 `DockGroupFocusReader`；
`Bailey/Workspace/DockWorkspaceModel.swift:move/place/syncTabs`、
`DockNode.inserting/removing/removingEmptyGroups`；
`Project.tabs`、`PaneTab`、`WorkspaceWindowModel` 关闭与移动；
`FinderWindowDrop`、Files 内部/外部拖动与目标空间。

**步骤：**
1. 先在上游测试和真实 UI 中确定：选中若干 tabs 后拖其中一项移动**整个集合**；
   未选中项拖动时只移动它；组内排序、组间搬运、靠边拆分、
   空组/最后 tab、跨窗拖动和 Option Copy 各自作用。
   这不是“拖动时仅显示 +N”视觉，而是目标组实际完整内容。
2. **产品安全边界**：singleton Projects/Files/Git 工具不复制；
   TerminalSession/WebView/Native Editor 的 Copy 只有真正有实现/安全克隆语义时才启用，
   否则拒绝并保持原内容，不借用另一实例或覆盖当前会话；
   文件标签/差异可复制时还要保留同一文档身份与保存所有权。
3. Red：构造 A/B/C 不连续选中，拖其中 B 到另一组/边缘，
   成功后只移动集合中的合法 tabs，原组顺序保持，
   各 PaneTab/TerminalSession/BrowserTab 对象身份正确；
   取消/拖出界/命中错误/分屏调整/源组被关闭时不产生部分移动或空悬浮组。
4. 在 `DockWorkspaceModel` 的原子布局操作/现有
   `DockTabDragCoordinator` 合并单项与多项移动的业务判断；
   只有 Drop 真正成功才更新活动组/Focus/Selection 和快照。
   删除重复的 tab 手势状态、无效预置占位或兼容分支。
5. 对外部 Finder 目录/文件投放、Files→Editor、
   Ghostty 路径插入与 WebKit Upload 保持原来的目标分派，不把
   “多选 Dock Item”传成多文件 Finder 数据；
   真实有脏文件时不在 move 前触发误关闭。

**验证：** `DockWorkspaceTests`、`NativePaneRetentionIntegrationTests`、
`FinderDeliveryIntegrationTests`、`WindowCloseIntegrationTests`；
隔离 `WorkspaceDockUITests`、`WorkspaceWindowsUITests`、
`WorkspaceRetentionUITests`；
1/N/多分屏、混合工具、多窗、跨 SSH、Option Copy、撤销拖动、
重复 Drop/目标失效、窗口尺寸边界、长标签滚动、中英/明暗；
核对最后 DockNode、Tab UUID、实际打开内容、原生 PTY/WebView/Undo 及未保存字节。
`make build:dev`。Docs `docs/features/dock.md`、
`docs/features/projects.md`（仅交互归属变更）、`docs/ui.md`；
一个提交。

---

## P4-T6 标签右键、批量关闭、键盘目标与“蓝框/底色”专属样式

**源码：** `editorTabsControl.ts:onTabContextMenu` 用 clicked group/editorIndex
作为上下文，不因此打开该编辑器；
`multiEditorTabsControl.ts` 对 Shift/⌘ 当前选择、双击、MiddleClick、
Shift+F10、菜单的关闭语义独立；
`multieditortabscontrol.css` 区分 active、selected-but-inactive、
unfocused active/inactive 的视觉，菜单期还有临时 Focus。

**Bailey 锚点：**
`DockWorkspaceModel.contextTarget/closeTarget`；
`WorkspaceDockView.DockTabGroupView.tab/projectTabMenu/handleMenuKeyDown/`
`closeTool/select`；
`PaneTabItem/TabItemChrome`；
`WorkspaceWindowModel.closePanel`、`Project.close(_:)`、
`FileTab.autoSaveOnFocusLoss` 与原生 NSMenu 跟踪。

**步骤：**
1. 先按真实 VS Code 源码/GUI 决定右键**单一 clicked tab**还是现有
   **选中标签集合**作为各菜单动作的合法目标：
   Close、Close Others、Move/Copy Group、Reveal/Copy Path 等
   不一定使用同一选择范围；菜单必须明确显示执行范围/启用状态。
   不让双击/右键导致隐藏工具重新出现或切换活动组。
2. Red→Green：在组 A 显示 File1、另一组显示 File2 时右键 Tool/File3、
   Cmd-W 或鼠标 Close 必须只按合法目标执行；
   多选 A/C 的批量关闭须遵守每个未保存/只读/运行中的 PTY 保护，
   中途保存失败不得移除未确认的标签。
3. 在 DockWorkspaceModel owner 保持上下文/多选/关闭目标解析唯一，
   `ContextMenuClickTarget` 只标记实际菜单作用域；
   禁止菜单按键与系统主菜单各执行一次、取消后留下另一个临时 closeTarget。
   菜单动作重新核对 Group 与 Tab ID，换窗口/项目后不能关闭旧目标。
4. 移除 Dock Tab 误套共享树行视觉时真正冲突的样式；
   由 Tab 自己按 upsteam 定义 focus/hover/selected/active/dirty/context 层级，
   但保留 Bailey 既有“整个分屏不画蓝外框”的决定。
   设置窗口继续原生 List，不加入高亮共享体系。

**验证：** `DockWorkspaceTests`、
`FileTabPersistenceTests`、`WindowCloseIntegrationTests`、
`WorkspaceDockUITests`、`WorkspaceWindowsUITests`、
`WorkspaceRetentionUITests`；
多选/单选/已显示/已失焦/禁用/中文/英文、明暗/宽窄/高对比，
未保存文件/浏览器输入/PTY、两窗口菜单目标及 NSMenu 键盘反馈；
每项检查真实关闭结果与字节，`make build:dev`。
Docs `docs/features/dock.md` 和 `docs/ui.md`；一个提交。

---

## P4-T7 多窗口/多组焦点交接与原生内容保留

**上游：** VS Code `editorParts.ts` 按窗口焦点+MRU 确定当前 EditorPart；
`editorPart.ts:shouldRestoreFocus/addGroup/removeGroup`
只在旧输入被布局操作打断时恢复；
`editorGroupView.ts` 不从单纯 Hover 或 selected 重建 editor pane。

**Bailey 锚点：**
`WorkspaceApplication` 的跨窗口登记/路由、
`WorkspaceWindowModel.attachedWindow`、
`ContentView`、`DockGroupFocusReader`、
`DockWorkspaceModel.activeGroupID`、
`TreeKeyboardOwner`、`TabSwitcherController`、
`FileTab`、`TerminalSession`、`BrowserTab`、`DiffTab`。

**步骤：**
1. 画出从 NSWindow key→当前组→当前 View firstResponder 的实际状态链；
   双窗同名项目/路径、一个窗口拖动另一个窗口不同时抢原生焦点；
   Palette/Sheet/renaming input 优先。
2. Red：键盘输入落在 Editor/Terminal/Browser/Files/Git 时
   连续右键 Dock/Projects、拖动多个标签、切/关分屏、
   展开 Git Graph、取消 TabSwitcher；
   恢复应指向事件完成后仍可见的控件，不是此前缓存的 NSView。
3. 仅在现有 `DockGroupFocusReader` 与窗口级交接入口修复
   错误的旧宿主验证/重复 focus 请求；
   App 不复制新的全局 FirstResponder 状态，
   当前 View 不向业务 Model 回调自己猜测的“活动组”。
4. 严格检查 Scene/窗口关闭/分屏移组与重挂载后
   NSTextView/TextKit、PTY/Ghostty、WebKit 的对象身份、光标和缓存未重建；
   保留所有既有保存失败防护，删除新增路径代替的旧逻辑。

**验证：** `DockWorkspaceTests`、
`WindowOwnershipIntegrationTests`、
`WindowCloseIntegrationTests`、
`NativePaneRetentionIntegrationTests`、
`FileTabPersistenceTests`；
`WorkspaceWindowsUITests`、`WorkspaceDockUITests`、
`WorkspaceRetentionUITests`；
双/多窗口、多个项目、同名标签、本机/SSH、快速关闭/拖动/重排、
重启恢复、IME/查找输入/Palette/菜单、长时间多标签资源；
键盘归属与真实未保存字节，`make build:dev`。
Docs `docs/features/dock.md`、
`docs/features/session-restore.md`（仅恢复格式/交接改变时）、`docs/architecture.md`；
一个提交。

---

## P4 阶段验收与审计

- 验收完整 VS Code editor tabs parity：⌘多选、Shift anchor/回缩、
  活动标签 vs 已选标签、失焦样式、右键非活动标签、
  快捷键/中键、拖动已选集合、按组关闭与结果；不是只看 Dock 背景。
- Projects 游标与选中项目、Palette/TabSwitcher 临时状态、
  NSWindow firstResponder、双窗/Finder/多分屏输入均有独立真机证据。
  Tools singleton/终端/浏览器批量操作的不可支持行为需明确禁用且不丢对象。
- 宿主 `DockWorkspaceTests` 与受影响 Files/Editor/Window
  全集，隔离 `WorkspaceDockUITests/WorkspaceWindowsUITests/`
  `WorkspaceRetentionUITests`；`make build:dev`、签名与 diff check。
- 检查各 task 同提交删除替代旧路径且及时更新 docs；
  `phase-complete --phase p4` 后必须由 `plan-task-auditor`
  完成 `audit-p4.md` 并判断 Go/No-Go；
  无法实际实测的触控板、OS 15.6、中键、跨窗拖动和 SSH 各留具体证据缺口。
