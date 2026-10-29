# P4：Projects、Dock 标签/活动组、批量选择与暂态输入

**目标：** 对照 VS Code EditorGroup/EditorTabs 的真实状态机，把
活动组、展示标签、标签多选、范围 Anchor、菜单目标、鼠标 Hover、拖放意图、
临时 Ctrl+Tab/Palette 预览与真实 NSWindow.firstResponder 分开；
支持当前 Bailey 的文件、终端、浏览器、Diff 与工具 tab 全部参与任意 Dock 布局，
不复制 Electron 窗口或随 View 更新重新创建原生内容。

**上游已核对：**
- `editorGroupView.ts:setSelection/openEditor/doShowEditor/setActive`：
  ActiveEditor、SelectedEditors、PreviewEditor 与组 Active 含义不同，不能混用；
  不要求各自独立存储：`editorGroupModel.ts` 的 active getter 直接取 Selection 首项；
- `multiEditorTabsControl.ts:registerTabListeners/selectEditor/`
  `selectEditorsBetween/unselectEditor/onDragStart`：
  Mac ⌘切换单个标签、Shift 范围选择、Anchor、批量拖动/右键；
- `editorTabsControl.ts:onTabContextMenu`：
  点击的 group/editorIndex 作为命令上下文，不强制激活后台 tab；
- `editorGroupModel.ts:doSetSelection`、
  `editorCommandsContext.ts:getMultiSelectContext`、
  `editorActions.ts:CloseEditorTabAction` 和 `editorCommands.ts`：
  active 必须属于 Selection；实际关闭/移动目标不是仅由右键菜单 View 决定；
- `editorPart.ts:doSetGroupActive/addGroup/removeGroup` 和
  `editorDropTarget.ts:handleDrop`：活动组、真实布局、组/标签/外部文件 Drop；
- `editorParts.ts`：多窗口的焦点和最近激活组分开；
- `multieditortabscontrol.css`：活动/失焦/selected-but-inactive/hover
  四类标签背景文字，不能全部简单套树行样式。

**P4 执行前独立复核（2026-10-30）：**
本轮从 `rhc@e355b362` 的当前源码、`AGENTS.md`、功能文档、
现有宿主/原生 GUI 测试重新沿入口、状态所有者和最终副作用取证；
不引用已有 `audit*.md` 的发现或完成判断。逐任务源码与删除边界在
[source-review.md](source-review.md#p4-current-source-review) 中对应。
上游行为以本计划列出的固定版本源码为比较目标；
未经重新运行的上游原生交互与设备行为不能算作本机验收。

**已有改动边界：** P4-T1 曾开始实施，当前工作区尚有 Projects 视图、
WorkspaceIdentityTests、projects 文档与 `todo.toml` 的未提交修改。
此前 51 项相关宿主和 2 项已有 GUI 测试通过，
但未单独证明「删除后台项目后游标清理」的真实界面路径；
预审不把该任务标成完成，也不把这些改动混入其它 task。

**Bailey 域主：**
`WorkspaceWindowModel` 拥有当前窗口项目；
`Project.selectedTabID` 是最近的工作标签/MRU，不等于每组当前展示；
`DockWorkspaceModel.root/groups/activeGroupID/contextTarget`
管理停靠结构与活动组，每个 `DockGroup.selected` 决定组内显示；
`DockTabDragCoordinator` 管理拖放临时态；
`TabSwitcherController` 管理 Ctrl+Tab 暂态预览。
Settings 保持原生 List，完全不参与。

**重要产品边界：** VS Code 编辑器 tab 与 Bailey Dock **包含工具 tab** 不完全等价。
新增多选只实现合法的 Move/Close；不能复制运行中的 PTY/WebKit，
也不能允许 Projects/Files/Git 工具重复实例。
当前没有 Dock Copy 操作，不为一个不存在的菜单新增禁用项、
可复制性矩阵、复制协议或兼容转发；Option 按已确定范围保持 Move。
普通点击保持一个展示项，不重新引入 VS Code 自动替换预览文件标签。

**确定的范围：** 当前 `DockNode` 中每个 DockItem 唯一，Project 对同机同路径文件复用标签，
PTY/WebView 也没有克隆契约。本 Feature 实现**同项目、同窗口 Move**（含混合工具多选），
不新增任何 Dock Copy 或跨窗/跨项目的内容转移；Option 不伪装复制，保持 Move 并显示一致预览。
上游 `isMoveOperation` 对 Singleton/同组 Copy 修饰也直接按 Move，不需要理论性的复制协议/禁用矩阵。
跨窗口 Finder 文件打开仍属于现有外部打开路径，不等于内部标签可跨窗口搬运。
独立源码依据与逐任务删除清单见 [source-review.md](source-review.md)。

---

<a id="p4-t1"></a>

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
4. `manager.projects` 发生添加、关闭或重排时，以稳定 UUID 核对
   cursor/context/drag 的成员资格；有效游标不因重排或失焦被强制改为当前项目，
   失效游标才回到当前合法项目，全部删除时清空。
   `handleProjectKey` 的 Return/Space 在真正切换前也必须按现存项目 ID 解析，
   不能依赖尚未触发的 SwiftUI `onChange` 清理旧 ID；
   拖动源消失时同时结束真实拖动光标，而不是只置空状态。
   保存失败未实际移除项目时不得预清游标；
   右键 Context 结束只能清本次目标，不能变相切换项目。
   不新建额外 Focus/Selection Store、可写项目身份镜像或跨项目匹配器。
5. 仅在 `ProjectsPanelView` 的原生已挂载 `TreeKeyboardHost`
   核验键盘游标/当前项目/Context 三种 AX 和实际点击结果。
   `WorkspaceWindowModel.close(project)` 是保存与终端销毁的唯一入口；
   终端/SSH 真实身份及后台窗口不被该 View 反向控制。

**验证：** `DockWorkspaceTests`、`WorkspaceIdentityTests`、
`WorkspaceDockUITests`、`WorkspaceWindowsUITests`；
空/1/N 项目、SSH/本机同名、重排、关闭未保存、弹出选择器、
键盘/拖动/双窗、明暗/窄宽/中英/AX；
**必须新增真实挂载 Projects 输入的 GUI/原生测试**：当前 A、游标 B、右键 C，
删除 B 后 ↑/↓/Return 不可切到旧 ID，删除后台 C 不改变 A，
保存失败不删除目标；单靠 WindowModel 项目顺序宿主断言不能证明游标行为。
检查实际项目根目录、编辑字节与终端会话未被错误删除；
`make build:dev`。Docs `docs/features/projects.md`、必要 `docs/ui.md`；
一个提交。

---

<a id="p4-t2"></a>

## P4-T2 DockGroup 展示、活动、最近标签和菜单目标归属

**源码：**
`editorGroupView.ts:activeEditor/setSelection/setActive`；
`editorPart.ts:doSetGroupActive`；
`editorTabsControl.ts:onTabContextMenu`，并对照
`explorerView.ts:selectActiveFile`、`scmViewPane.ts:onDidActiveEditorChange`：
编辑器变化通知属于可观察的跨组件同步触发，不是单纯的绘制事件。
上游 `activeEditor`、`selectedEditors`、`groupActive` 语义分开，前两者有成员与顺序约束，
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
   Dock A→B、Palette、Switcher、关闭当前项后激活后继标签应使 P2/P3 已接入的
   Explorer/SCM Auto Reveal 按**真实活动展示项变化**执行一次，
   非活动组单纯更换显示项仍保持现有 Browse/预览语义；
   菜单、Hover、组内多选但未更换 Displayed、布局无效操作与 View 重绘不应产生此事件。
   追踪 `DockWorkspaceModel.updateLayout/activate` →
   `WorkspaceWindowModel.bind/autoRevealActiveFile` 和 Git 当前项目同步，
   不用 `Project.selectedTabID` 或多选集合伪造活动事件。
2. Red：两组各有不同 File/Terminal/Tool，
   点击后台标签、空标签区/按钮、右键另组文件/工具、
   ⌘W、点击其它组后关闭原标签；
   关闭保存失败不挪动当前组，不丢 Undo/Terminal 输入。
   核对 `Project.tabs.didSet` → `dock.syncTabs` 和
   `Project.onSnapshotChange` 是否因一次实际状态变化发出重复快照通知；
   只有确有重复才在对应 owner 收敛，不为减少回调丢真实恢复数据。
3. 在 DockWorkspaceModel 唯一布局 owner 维护活动/展示/菜单目标；
   Project 的 MRU/selectedTabID 不能替代某组 `selected`，
   但已有明确标签选择事件必须正确交给 P2/P3 的资源同步逻辑；
   不能让 Dock 和 Files/Git 各自观察 View 重绘而重复发起 Auto Reveal，
   View 只转发明确 click/context/drop；
   删除旧的激活推断或多余视觉本地状态，
   保留 group-scoped autofocus 与用户既有无“蓝色整组外框”决定。
4. 菜单结束 Context 清空，AX 显示当前 tab 与键盘 Focus 各自真实，
   隐藏/失活 group 不伪造编辑器 firstResponder。

**同任务删旧：** 工作标签选择只经 `Project.selectTab`，
移除 `DockTabGroupView.select` 先 `dock.select` 再 `project.selectTab` 的重复调用；
工具仍直接调 Dock 所属动作。`active` 的 `group.selected ?? group.items.first` fallback
只有在模型已保证非空组有合法 selected、所有 restore/remove 路径测试通过后才删除，
不能用 View 备用展示掩盖无效模型。
`DockWorkspaceConfiguration.init` 中三处静默接受已移除 `info` 的分支在本任务移除，
配置按现有无效 workspace 配置规则处理（日志并使用默认布局），不加旧名 alias 或新迁移器。
`AppSettings.workspace(from:)` 的类型校验及 `persist` 会在其它偏好保存时重新读取 workspace 配置，
因此要分别检查：**启动仅读**不改写原 TOML、旧 `info` 被明确判为无效、
其它字体/主题偏好继续可用，以及**下一次修改普通偏好并保存时**配置文件的完整结果；
不能只测首次载入成功就遗漏手工工作区布局被静默覆盖的情况。
现行合法 workspace 字段在保存其它偏好时必须保留；
含已删除 `info` 的配置属于**无效布局**，启动时以默认布局运行且不写盘，
后续实际保存其它偏好时允许按现有 `persist` 规则写成当前标准布局，
测试应明确此结果并保留独立字体/语言等偏好，不能把旧无效布局称作已迁移。
不增加旧格式迁移器或独立原样保留无效布局的双轨状态。
把 `AppSettingsTests.testDefaultsAndRoundTrip` 改为现行合法格式，
旧名回归以独立非法配置用例断言，不生成向后兼容写回器或用户可见错误 Sheet。
`DockSavedItem.info` 和快照 `localFile` 缺省读取有现存数据保护用途，
删除会使整份旧快照解码失败或把 Mac 文件错绑 SSH；不把它们混同运行态死代码，
本 Feature 不改存储格式、不删原始快照、不新增迁移器。具体边界见 source-review 的删除表。

**验证：**
`make test:DockWorkspaceTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests,AppSettingsTests,SessionStoreTests`；
`WorkspaceDockUITests`、`WorkspaceRetentionUITests`；
同组/两组三组、空组、活动工具组、关闭背景/前台、脏文件保存失败、
特别核对 A→B→A 与两组各展示文件、Diff/普通文件交错、
后台窗口/隐藏树重挂载及同名其它项目路径时树选择与实际活动编辑器一致，
且不额外抢 keyboard firstResponder；
双窗、窗口最小化/重新激活、宽度极小与 30+ tabs、
主题/字号/AX；`make build:dev`。文档 `docs/features/dock.md`、`docs/features/settings.md`（配置旧名）、
`docs/architecture.md`（只在职责真源变化时）、`docs/ui.md`；一个提交。

---

<a id="p4-t3"></a>

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
`WorkspaceWindowModel.toggleCommandPalette/restoreFocusAfterCommandPalette`、
`WorkspaceWindowModel.selectedProjectID/close(project)`、
`ContentView` 的 Switcher Overlay 挂载、
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
   当前 `dismiss(commitSelection:)` 只核对旧 Project 自己的 selectedTabID，
   `selectedProjectID.didSet` 尚未取消 Switcher；同窗口切项目后释放 Control
   仍可能改旧项目的标签/MRU。`ContentView` 又以**新** `selectedProject`
   绘制仍属于**旧** `activeProject` 的 Switcher Overlay。
   在窗口已有的项目切换/关闭生命周期立即取消旧 Switcher，
   让提交入口只接受**当前窗口仍选中的原项目及合法标签**；
   不再加另一份 Project generation 或重复监听。
   覆盖鼠标卡片提交、Control 释放、Tab 被关闭和失去 key 的取消路径。
   现有键盘/鼠标监听、终端预览任务与输入焦点守护仍按真实用途保留。
4. Command Palette 的“切换项目”命令目前从 `manager.projects.enumerated()`
   捕获**下标**后执行 `selectProject(index:)`。如果面板显示期间另一个入口插入、
   关闭或重排项目，下标可能指向不同项目。
   改用当次捕获的 Project UUID，在真正执行时按现存项目身份解析，
   已不存在即拒绝；不靠冻结整个项目列表或新增请求代次。
   搜索晚到继续沿已有 `FileIndexKey`、项目身份和连接代次校验。
5. Ctrl+Tab 真正提交后必须激活正确现存 tab；
   取消后所有原先活动、显示和未保存数据不变。
   Palette 的 Search/IME/TextField 保持真实 firstResponder，
   新目标已取得焦点时不执行迟到旧响应者恢复。

**验证：** `DockWorkspaceTests`、`ProjectFileIndexTests`、
`FileTabPersistenceTests`、`WorkspaceSmokeUITests`、
`GitChangesUITests`、`WorkspaceDockUITests`、
`WorkspaceRetentionUITests`；
空/1/多个/删掉的 Tab，连续按键、焦点切窗、中文/英文/IME、
搜索晚到/SSH 失效、窄/宽布局/大量结果；
必须包含项目 A 的 Switcher 在预览期间切到 B，再松 Control/点击旧卡片，
确认 B 的实际显示与 A 的 MRU 都未被旧请求改写；
Palette 显示 A/B/C 时重排/关闭 B 后执行原 B 结果，
确保不打开新占据该数组位置的项目。
`make build:dev`。Docs `docs/features/command-palette.md`、
`docs/features/dock.md`；一个提交。

---

<a id="p4-t4"></a>

## P4-T4 VS Code 式同组多标签 Selection、Anchor 与键盘导航

**真实缺口：**
- `multiEditorTabsControl.ts:registerTabListeners` 中 Mac ⌘ 点击单项 toggle，
  Shift 使用仍在 Selection 内的 `lastSingleSelectSelectedEditor`，失效时取 active；
  `selectEditorsBetween` 只撤销 Anchor **另一侧**的连续选择，再合并目标范围，
  不等于 Files 的范围替换；同侧回点也不保证回缩；
  普通单击选中/激活，按鼠标松开时清理扩选。
- `editorGroupView.ts` 的 `selectedEditors` 不等于 `activeEditor`；
  失去组激活时多选集合可回退当前活动编辑器。
- Bailey 当前只有 `DockGroup.selected`（显示一个）及 Project 最近标签，
  **尚无标签多选集合/范围 Anchor**。

**可执行规则，而非“参照上游”占位：**
- 非空组的 Displayed 必须在该组 Selection 中；空组二者皆空。
  ⌘加选 B 会展示 B 并保留其它选择；⌘取消非展示项不改展示；
  取消展示项时在剩余已选工作标签中按既有 Project MRU 筛选，工具无 MRU 时按组顺序，
  不能取消最后唯一展示项。不为工具增加全新 MRU 服务。
- A/C 已选、Anchor=C，Shift E → A/C/D/E，再 Shift D **仍为 A/C/D/E**；
  Shift B → A/B/C。必须覆盖这条与 List 算法不同的序列。
- 普通按下已选项时保留集合供拖动；未触发拖动的普通松开才收成展示项。
  从未选项开始拖动先改成该项；右键、关闭按钮、重命名输入不执行普通选择。
  空白区与右键未选项只建立 Context，不自行建立第二份 Selection。
  真正切到另一个 Dock 活动组时，原组 Selection 收成其 Displayed；
  仅 NSWindow 失焦/Palette 接管不伪装成切组。

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
2. 在 **DockWorkspaceModel** 持有按 groupID 索引的非持久 Selection + Anchor，
   单项默认可从 `DockGroup.selected` 派生，**仅多选/锚点有必要时保存扩展集合**，
   不为每个组持续复制一个等价的单项 Selection；
   `DockGroup.selected` 继续是唯一 Displayed；
   不为对齐八类术语再增加 displayed/activeEditor 的可写镜像。
   用 UUID/DockItem identity 对齐列表与变更；绝不把 global selectedTabID
   或真实显示的 `DockGroup.selected` 替换成“多选集合”，也不创建全 App Manager。
   组删/Tab 关/项目换/拖动到别组时更新或清空对应 Anchor 和集合；
   不给多选临时态新增恢复快照。
   不把这组暂态字段塞入触发 `onSnapshotChange` 的 `root.didSet`；
   单纯 Selection/Anchor 变化不得写快照，真正展示/布局变化仍按原流程写。
3. Red→Green：同组单项/不连续/Shift多选、正反延伸、边界首尾、
   ⌘取消当前活动标签时仍保留一个实际显示内容；
   组失焦、多窗口、拖动前后，集合只包含当前合法项；
   工具标签不能被复制成第二个 singleton 实例。
4. 让 TabItemChrome 根据真正 **active displayed、selected-but-inactive、
   group focused/unfocused、hover、context** 绘制不同文字/背景，
   而不是继续用一个 `isSelected` 偷换多个事实。
   必要时使用 Tab 专属 ViewModifier；
   **不修改 Files/Git `TreeRowSurface`，不触及 Settings List**。
5. 同任务接通选中集合拖动的最小完整闭环：
   `Position.item` 改成真实源组、按组内原顺序排列的来源集合与拖动项，
   模型由**同一个**单项/多项 Move 动作一次计算/发布布局；
   现有 `DockWorkspaceModel.move(item,...)` 的单项分支随接入删除或
   直接变为新动作的唯一简单入口，不能留下同时可写布局的单双轨。
   `Project.tabs` 保留原始 PaneTab/PTY/WebView 对象，不引入复制能力。
   现有 `DockGroupFocusView` 的 mouseUp/focusGroup 不能再把修饰键多选或已完成 Drop
   误当普通选择重放；把事件因果关系与 TabItemChrome 的 Button、DragGesture 一起迁移。
   P4-T5 补全布局组合与边界，不是多选上线后才修复丢项拖动。
   同时让现有 Close/⌘W/关闭按钮消费本组 Selection，
   从当前 `DockWorkspaceModel.closeTarget` 统一解析组选区内/外的动作目标。
   `WorkspaceWindowModel.closePanel` 现仅逐项关闭，`Project.closeBatch` 只处理
   `[PaneContent]` 且返回 `Void`，**并不能直接处理混合工具和脏文件批量关闭**。
   本 task 在既有 `Project.closeBatch` 的顺序保存/确认边界接入一条
   可等待或回调完成的必要路径；工具移除必须晚于脏文件的可接受结果，
   若取消则保留未处理项目且不先销毁 PTY；不新建全局 CloseManager，
   不保留“界面能多选，关闭仍按旧单项”的过渡分支。
   P4-T6 负责其它菜单、中键与视觉组合复核。
6. 恢复 Tab Strip 的**自身**原生键盘可达性：只有标签条真实拥有
   键盘焦点时，←→/Home/End 移动标签游标，Enter/Space 激活，
   实际支持时 Shift+F10 打开菜单；AX 应分别反映显示和多选。
   中键关闭需先通过实体鼠标/原生测试证明事件命中，再接入同一关闭动作。
   禁止为此在 DockGroupFocusView 中增加全局拦截键盘、
   不覆盖编辑器/终端/浏览器原生快捷键或系统主菜单命令。
7. 删除单选假设的旧重复 View 状态，不引入旧版快照双轨；
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

<a id="p4-t5"></a>

## P4-T5 多标签批量拖动、拆分/合并和 Move 边界

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
   空组/最后 tab、跨窗拒绝和 Option 仍 Move 各自作用。
   这不是“拖动时仅显示 +N”视觉，而是目标组实际完整内容。
2. 按阶段已确定的 Move-only 范围测试：Option 仍 Move，不创建 Clone/copy fallback，
   不新增跨窗/项目/机器的 transfer service；跨窗内部拖动拒绝且原组保持不变。
3. Red：构造 A/B/C 不连续选中，拖其中 B 到另一组/边缘，
   成功后只移动集合中的合法 tabs，原组顺序保持，
   各 PaneTab/TerminalSession/BrowserTab 对象身份正确；
   取消/拖出界/命中错误/分屏调整/源组被关闭时不产生部分移动或空悬浮组。
4. 在 `DockWorkspaceModel` 的原子布局操作/现有
   `DockTabDragCoordinator` 合并单项与多项移动的业务判断；
   只有 Drop 真正成功才更新活动组/Focus/Selection 和快照。
   删除重复的 tab 手势状态、无效预置占位或兼容分支。
   批量 Move 不能循环调用旧 `move(item)`，否则会产生中间布局、焦点/自动保存和多个快照。
   从**同一次有效拖动开始时**的 sourceGroup、窗口、项目及当前 DockNode
   核对全部成员和目标；只有源组里当前合法的完整集合才能一同移动，
   不在失效状态退化为「只移动被拖的一个」。
   在旧 root 上先移除，再按源组原顺序插入；
   同组插入索引减去原索引之前的被移除项数，目标在选中区间内按 no-op 处理，
   不因 SwiftUI 布局重算复用失效的目标 CGRect/组 ID。
   只在最终 root 调一次 `updateLayout`，目标组展示拖动项、
   Selection 包含完整移动集合；**失败或 no-op 不发布新布局/快照/焦点事件**。
   分割目标是源组且整组已选时不制造空分割；
   其它有效边缘移动一次建一个新组。
   保留未被搬走的 Tool/Tab 与有效组内 Displayed；
   `DockNode.removingEmptyGroups` 只能在全部成员处理之后决定实际空组的命运。
   当前 `DockTabDragCoordinator.finish` 移动成功后还调用 `Project.selectTab`，
   需检查其是否再次改动 MRU/重复激活并收敛为一个真实提交动作。
   本 task 发现的根因继续在唯一实现修，不恢复单双轨。
5. 对外部 Finder 目录/文件投放、Files→Editor、
   Ghostty 路径插入与 WebKit Upload 保持原来的目标分派，不把
   “多选 Dock Item”传成多文件 Finder 数据；
   真实有脏文件时不在 move 前触发误关闭。

**验证：** `DockWorkspaceTests`、`NativePaneRetentionIntegrationTests`、
`FinderDeliveryIntegrationTests`、`WindowCloseIntegrationTests`；
隔离 `WorkspaceDockUITests`、`WorkspaceWindowsUITests`、
`WorkspaceRetentionUITests`；
1/N/多分屏、混合工具、多窗/跨项目/跨机器拒绝、Option 仍 Move、撤销拖动、
重复 Drop/目标失效、窗口尺寸边界、长标签滚动、中英/明暗；
核对最后 DockNode、Tab UUID、实际打开内容、原生 PTY/WebView/Undo 及未保存字节。
`make build:dev`。Docs `docs/features/dock.md`、
`docs/features/projects.md`（仅交互归属变更）、`docs/ui.md`；
一个提交。

---

<a id="p4-t6"></a>

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
1. 按 `getMultiSelectContext` / `CloseEditorTabAction` 的规则：
   Close/⌘W/标签关闭按钮/中键命中组选中项时关闭该组 Selection，
   命中未选项时仅关闭它，右键本身不修改显示或 Selection。
   Close Others 保留该合法目标集合，Close to Right 的范围由明确右键项的组内位置确定；
   两者沿现有契约只将工作 `PaneTab` 视为被关闭候选，
   不能暗中移除同组 singleton 工具；显式组选区批量 Close 才可包含工具。
   当前 `Project.closeOthers(_:)` **先 `selectTab(keep.id)`**，
   会把后台右键目标意外激活；必须在本 task 删除这条选择副作用，
   与 `closeToRight` 一起只按源组/真实成员计算关闭目标。
   Rename/Reveal/Copy Path 只用 clicked item，不把非文件工具传给文件动作。
   本 task 从 P4-T4 已接通的集合/顺序关闭入口继续核销；
   菜单明确显示执行范围/启用状态，不新增 Copy Group 动作。
   不让双击/右键导致隐藏工具重新出现或切换活动组。
2. Red→Green：在组 A 显示 File1、另一组显示 File2 时右键 Tool/File3、
   Cmd-W 或鼠标 Close 必须只按合法目标执行；
   多选 A/C 的批量关闭须遵守每个未保存/只读/运行中的 PTY 保护，
   中途保存失败不得移除未确认的标签。
   **顺序关闭不是回滚事务：** 复用 `Project.closeBatch` 的保存/确认顺序与取消即停，
   已确认关闭的内容不复活，失败项与尚未处理项保留；
   若集合包含 Tools 与未保存文件，在真正取得保存/确认结果前不先移除 Tool，
   也不先终止选中的 Terminal；现有 `closeBatch` 无完成回调的事实已由
   P4-T4 负责修改，T6 验证它的完整用户路径。
   不逐项 fire-and-forget 调 `closePanel` 产生并发 Sheet，
   也不为此创建全 App 关闭事务/回滚服务。
3. 在 `DockWorkspaceModel` owner 保持上下文/多选/关闭目标解析唯一，
   将 `closeTarget` 的**单项值**扩展为一次合法命令所需的组内集合解析，
   复用 `WorkspaceWindowModel.closePanel` 的唯一执行入口。
   右键集合外只关闭命中项，集合内才消费该组成员；
   点击另一组后旧组合法多选按 P4-T4 的失活规则归约。
   `ContextMenuClickTarget` 只标记实际菜单作用域；
   保持 P2 已有的 NSMenu 与窗口、启用状态核验，以及
   AppKit 先结束菜单跟踪再派发主菜单 ⌘W 的单次消费语义。
   禁止菜单按键与系统主菜单各执行一次、取消后留下临时 closeTarget。
   菜单动作重新核对 Group 与 Tab ID，换窗口/项目后不能关闭旧目标。
4. 移除 Dock Tab 误套共享树行视觉时真正冲突的样式；
   由 Tab 自己按上游可观察语义定义 focus/hover/selected/active/dirty/context 层级，
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

<a id="p4-t7"></a>

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
3. 仅在现有 `DockGroupFocusReader`、`WorkspaceWindowModel.ownsActiveResponder`
   与窗口级交接入口修复证实错误的旧宿主归属/重复 Focus 请求；
   App 不复制新的全局 FirstResponder 状态，
   当前 View 不向业务 Model 回调自己猜测的“活动组”。
   P2-T5 已接通窗口许可与 Files/Git/Palette 归属，本任务直接复用；
   在 `PanelContentView` 装配 SourceTextEditor、DiffNativeSurface、TerminalHostView、
   BrowserAddressField/WebView 的挂载与聚焦结果，不重新增加另一层协调器。
   `DockGroupFocusView.containsResponder` 目前通过 native view 可见区域中点
   判断组归属，另有 field editor/TerminalParking 类型分支；
   仅当所属原生控件真实提供可用的挂载/组身份时移除该业务几何猜测，
   不能改成只看 `NSWindow` 而把邻组或停车容器误当当前输入。
   拖放所需 Geometry/点击命中与原生可见性仍保留。
   BrowserAddressField/BrowserWebView 两处当前都是 **6 次/50ms** 重试，
   且在实际聚焦成功前就标记 `handledFocusRequest`。
   按挂载、有效窗口和真实聚焦成功处理一个**尚未消费的请求**，
   失败不提前清 pending，切组/失去 key/请求换代时取消旧请求；
   不另外引入 6 次重试的替代轮询或全 App FocusManager。
   SourceEditorContainer/TerminalContainerView/Diff 的原生就绪检查保留，
   删除的是重复策略与无依据轮询，不是所有异步调用或所有本地 `@FocusState`。
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

- 验收 **P4 已选定的 VS Code Tab 行为子集**，不宣称 Electron EditorTabs
  与 Bailey 含 singleton 工具、终端、浏览器的 Dock 完全同构：
  ⌘多选、Tab 独立 Shift Anchor、活动展示 vs 已选标签、失焦样式、
  右键非活动标签、标签条自身键盘/中键、拖动已选集合、按组关闭与结果；
  不只是看 Dock 背景或多选视觉。
- Projects 游标与选中项目、Palette/TabSwitcher 临时状态、
  NSWindow firstResponder、双窗/Finder/多分屏输入均有独立真机证据。
  Tools singleton/终端/浏览器批量操作的不可支持行为需明确禁用且不丢对象。
- 宿主覆盖 `DockWorkspaceTests` 与受影响 Files/Editor/Window/Settings
  的合法目标、保存、原生视图身份、无效配置、快照及焦点组合；
  完整 App GUI 保留宿主无法证明的真实鼠标按下/松开、菜单跟踪、
  Shift/⌘ 键、原生首响应者、Finder 目标、双窗口与 PTY/WebKit 可见结果。
  不在每个 task 为同一组合复制整套 UI 夹具。
  `WorkspaceDockUITests`、`WorkspaceWindowsUITests`、
  `WorkspaceRetentionUITests` 的最终适用路径逐条执行；
  `make build:dev`、签名、`git diff --check` 与 todo validate 均需通过。
- **每个 task 在新入口实际接通、定向 Red→Green 及回归通过的同一提交**
  移除对应旧策略，不能把旧拖动、重复选择、单项关闭、过期焦点轮询
  统一推给 P4-T7/P5。不可删的连接身份、脏稿保存否决、
  历史快照最低限度解码、Finder 外部投放目标保护单列为保留边界。
- 阶段任务完成、提交及 `phase-complete --phase p4` 通过后，
  再由 `plan-task-auditor` 独立审计 P4 并给出 Go/No-Go；
  预审不能预填审计结论。触控板、OS 15.6、中键、
  跨窗口真实拖动与 SSH 仅在确实没有执行条件时逐项记录
  影响、替代证据和补验步骤，不直接写成已通过或自动豁免。
