# P3：打开内容与 Files 列表焦点解耦

**Goal：** 像 Zed 一样，单击 Files 文件时展示目标内容而键盘仍属于 Files；明确双击／显式打开时才转入编辑器。聚焦的树行可见，已打开文件、行选择与输入框不再混同。

**Non-goals：** 不实现 Zed 的临时 Preview Tab 生命周期、不自动新增分屏、不复制全局 Focus Manager；Files 的 ⌘/Shift 多选集合、文件剪贴板与拖放仍归 [#5](../file-manager/plan-p1.md#p1-t1)。

**上游证据：** [Zed ProjectPanel](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/project_panel/src/project_panel.rs)：单击文件传 `focus_opened_item = false`，双击传 `true`；`Event::OpenedEntry` 用 `open_path_preview` 打开内容，再在不聚焦编辑器时明确把焦点留给 Project Panel。Zed 的 Preview Tab 是可配置的独立功能，Bailey 不能为复制这个焦点语义先造一套预览标签。

**Approach：** 只扩展现有 `DockWorkspaceModel`、`Project` 的「展示所选标签」与「激活其 Dock 组」能力，由 Files 明确提供打开意图。`FileTreeModel` 只保存自身的文件行焦点／选择游标；`NSWindow.firstResponder` 和所属 key window 仍是真正的键盘归属。保留现有 `ScrollView + LazyVStack` 与 `TreeRowSurface`，让共享文件/目录整行成为**非 Button 的可选择、可聚焦条目**；实际执行独立操作的控件仍为 Button。行焦点与文件打开分离，不迁移到 SwiftUI `List`，不新增颜色设置或平行输入路由。

**Acceptance：** 同时可见 Files 与编辑器时，单击 A / B 会更新编辑器展示、不会让 Files 丢失上下文；P3-T2 完成后 Files 的方向键、输入框和菜单仍按焦点生效。双击、按 Return 执行明确打开或用户主动切换文件标签才聚焦编辑器；不存在「标签展示了新文件，所以自动切活动 Dock 组」的副作用。

**边界：** Bailey 的工具面板可与文件标签停靠在**同一组**，不同于 Zed 固定侧面板。若打开目标会替换当前 Files 组的可见内容、找不到可同时显示的独立目标组，就不能声称不可见 Files 仍有键盘焦点：明确激活可见编辑器；**不偷偷自动拆分、搬走已有标签或挂虚假的 first responder**。这个场景须真实复现和验收。

---

<a id="p3-t1"></a>
## P3-T1 文件展示、标签选中与活动组分离

**真实调用链：** `Bailey/Files/FileTreePanel.swift.FileTreeRow.semanticRow` → `Bailey/UI/Panels/ToolPanelView.swift` 的 Files `openFile` → `Bailey/Workspace/TerminalManager.swift.openFile` → `Bailey/Workspace/Project.swift.openFile` → `Project.selectTab` → `Bailey/Workspace/DockWorkspaceModel.swift.select`。`Project.openFile` 的**新建和复用**分支均无条件调用 `selectTab`，其内部 `dock.select` 自动激活编辑器组。还须追 `Project.insertNextToSelected`、`DockWorkspaceModel.syncTabs` 和 `PanelContentView/FileViewerView/SourceTextEditor` 的挂载/异步首响应者请求。

1. **Red 与真正结果：** 在 `WorkspaceWindowIsolationTests` 和 `DockWorkspaceTests` 建两个可见组（Files / FileTab），先复现当前整行 `Button` 点击立即打开并转焦编辑器的问题；**不再以保留 Button 或迁移到 List 为前提**。直接验证共享非 Button 行的 SwiftUI 单/双击与原生右键、拖放、独立动作按钮的事件顺序，若出现重复触发则在唯一行交互入口修正，不叠加两套手势。再通过 Files 实际树行触发单击、双击及已打开文件复用，检查 `DockGroup.selected`、`activeGroupID`、`NSWindow.firstResponder`、菜单 `focusedContent` 与编辑器文字：基线单击会错误激活编辑器，必须让此用例先失败。验证文件加载慢、点击后马上切另一组、编辑器已经打开在别组时没有重建内容。**分别建立**：有独立可见内容组、只有 Files、Files 与多个工作标签共组、存在空组、工具占满所有组、目标组关闭的情形，并证明新标签 `syncTabs` 与已有标签 `selectTab` 都没有在 Files 仍可见时意外切走活动组，或在源 Files 被隐藏后错误保留其输入焦点。
2. **Green：** 在现有 `DockWorkspaceModel.select` / `Project.selectTab` 中提供**最小的“选择展示但不激活该组”途径**，追查 `Project.insertNextToSelected`、`tabs.didSet` 的 `syncTabs`（新标签默认落在最近工作标签组，且会将该组的 `selected` 变成新标签）、`DockWorkspaceModel.place/updateLayout`（默认激活）和 `onDeactivate`，避免新增或复用标签时偷偷激活目标；**落点优先遵守现有最近工作标签的组和用户显式选择，不为保焦点擅自把标签移动到另一组；若实际落点覆盖了源 Files，则使用可见编辑器焦点退路，绝不为隐藏的 Files 保持虚假键盘焦点或自动拆分**；让 `Project.openFile` 新建/复用和 `TerminalManager.openFile` 可以按来源传“是否把焦点交给打开项”，默认仍保持外部 Finder、⌘P、顶部标签栏、显式跳转等入口原有激活行为。**本任务在共享树行中去掉整行用于打开的 Button，采用普通可交互行分发单击选择/展示与双击明确打开，避免双击触发两次打开和不必要的焦点跳变；保留独立按钮及所有原有真实命中区域**；不能推给 P3-T2 或叠加旧 Button/新 Gesture；Files 单击不激活源组以外的 Dock，双击/显式打开才聚焦文件。P3-T1 只建立不误激活的可见组/响应者契约，不以尚待 P3-T2 实现的行方向键导航作为本任务 Green 的前提。复用 `onDeactivate`、`focusedContent`、原生 first responder 保护，不能为了留焦点跳过真正的失焦保存或在旧项目/错误机器开文件。
3. **副作用验收：** 刚创建和已复用的 `FileTab` 都只有一份可写内容；单击后 Files 的实际按键不会写到编辑器，双击后编辑输入/Undo/⌘S 生效；**仅有一组且新文件替换 Files 显示时，测试退路应明确转向可见编辑器，而不是假称留在 Files**。Finder / Dock 拖入、菜单 ⌘O、命令面板 ⌘P、Git 显式「Open File」、新建文件完成后打开、从终端链接打开文件应保持各自**明确的焦点意图**，不得统一强制保留 Files 焦点。验证同名本机/SSH、跨窗口不同项目、晚到读取/窗口失活、失败保留未保存字节、脏文件失焦保存；纯横/纵、多标签、0/1/6+ 组、合并拆分及无独立目标组的合法 fallback。
4. **同任务清理：** 新入口接通当次删掉任何与“先激活，再抢回 Files”有关的多余重聚焦逻辑（若已存在）；不重构 `SessionStore`、不持久化瞬时焦点。同步 `docs/features/{dock,files,editor,command-palette}.md` 中实际变化的契约；在相同 XCTest 目标复跑 `DockWorkspaceTests`、`WorkspaceWindowIsolationTests`、`WorkspaceContentIdentityTests`、`PaneRetentionTests`，用真实 UI 验证单击前后的键盘目标，再中文原子提交。

---

<a id="p3-t2"></a>
## P3-T2 Files 选中行、键盘游标与焦点边框

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`FileTreeScrollView/FileTreeRow` 的 `isCurrent/semanticRow/nameField/commitDraft`）、`Bailey/Files/FileTreeModel.swift`（`items/sync/expanded/rootPath`）、`Bailey/Shared/Tree/TreeRowStyle.swift`（`TreeRowSurface/TreeFileRow/TreeFolderRow` 的 `focused` 与行内 `@FocusState`）、`Bailey/UI/Panels/ToolPanelView.swift.openFilePath`。目前 Files **没有行选择游标**，文件背景来自最近 `FileTab` 的路径，`focused` 与 hover 都只有 0.05 的背景色；文本改名另有焦点，但不能当作行已聚焦。

1. **Red：** 真实点击文件/目录后验证“行焦点”独立于“当前打开文件”；窗口聚焦且 Files 实际持有键盘时，只有当前选择游标所在行显示边框；点击其他组后边框消失，选择仍可恢复。单击显示文件但不让焦点跑到编辑器；双击转编辑器；目录单击保留原展开/折叠。以 P3-T1 已替换的非 Button 共享行作为基线，不重复迁移；验证点击、修饰键、输入框及行内独立 Button 只执行各自动作，未选中的行不冒充焦点。
2. **Green：** 在 `FileTreeModel` 保持**一个**稳定行游标及其所属根/机器范围，作为 [#5 P1-T1](../file-manager/plan-p1.md#p1-t1) 扩展多选、锚点的基础，**不再叠加独立的私有 SelectedFileStore**；移除整行 Button 焦点依赖，先验证 SwiftUI `.focusable()`／`@FocusState` 能否真正从旧编辑器转交 `NSWindow.firstResponder`；实际隔离 App 已证实它仅产生行外观、不能可靠接收实体方向键，因此 Files 容器内使用**唯一不拦鼠标命中的原生 `NSView` 键盘响应者**，直接分发原生方向键；`FileTreeModel` 仍是唯一行游标数据源，不新增全局输入事件监听或第二套选中状态。`TreeRowSurface.focusRing` 仅对真正取得键盘焦点的当前 Files 行绘制细描边；`selected` 只代表当前显示的文件，Hover 独立绘制临时背景，不再以 `focused` 决定底色。Files 改名/新建 `TextField` 真正聚焦时仅输入框描边，行焦点环撤去；非 Button 行仍提供辅助功能名称、选中状态和显式打开/展开动作，右侧独立 Button 不得触发行的打开；Return/Escape/失焦后仅恢复仍有效的原行。
3. **交互与身份：** ↑/↓、→/←、Return/Space/Escape 按现有 Mac 原生键盘语义确认（**Bailey 未实现 Zed Preview Tab，Files 的 Return 属于显式打开并转焦编辑器**），不抢文本输入、终端、浏览器或 Git 快捷键；单击／双击／右键的语义与 P3-T1 一致；上下文菜单属于被右击的那一行，菜单展开/关闭后不能让未选中行伪装为键盘游标，也不能在菜单操作打开目标时恢复已过期的 Files 焦点。`currentFilePath` 只是标签上下文，不能以路径文字把 **本机文件与 SSH 同名文件**混成一个选中行；不同项目、根目录、SSH 通道/工作区、压缩目录/软链、刷新重排、重命名/删除、折叠使游标隐藏时都要以真实 `PanelContext` 身份维持或清除游标。⌘／Shift 多选集合以及批量文件操作由 #5 完成，**不在本任务实现半套多选**。
4. **最大可行验收和清理：** 本机/授权 SSH、断线/重连、0/1/千级行、大量深层/压缩目录、同名路径、空文件/长路径/中文/emoji/Unicode、浅暗/字号缩放/150pt 窄栏、2/6+ 分屏和双窗口；组合输入框、菜单、焦点前后台、重建/恢复、快速连续点击与滚动，检查真实行边框、键盘输入归属、打开后文件内容和 Undo。`FileTreeTests`、`TreeRowHitTestingTests`、`WorkspaceWindowIsolationTests` 加 Red→Green；保留 Files/Git 共有树行语义，不污染 Git 选择状态。代码替代时当次删除将 `currentFilePath` **直接当键盘焦点或列表游标**的旧判断；当前已打开文件的非焦点位置提示仍应保留、由文件自身本机/SSH 身份校正，不能为了清除假焦点误删文件定位。更新 `docs/features/files.md` 与 `docs/ui.md`，中文提交。

**P3-T2 追加验收：** 用户通过顶部 File Manager 标签从编辑器或 Git 切回 Files 时，无需再次点击文件行就应接收 ↑/↓，优先恢复已选中行，否则定位当前可见工作文件或第一条可见行；初次异步读取后再选中。列表重挂载或窗口恢复为 key 后交接真实第一响应者，不抢改名／新建输入框或后台窗口，也不额外打开文件。后台 XCTest 不可冒充前台焦点证据，需隔离 App GUI 实测。

**P3 与 #5 的边界：** P3 修改共享行以去掉整行 Button，建立最小焦点游标和点击/打开契约；#5 P1-T1 **复用并扩展**这一个游标为多选集合与选择锚点，不另建一套状态，不重复实现单击焦点修复。完成 P3 之后才能据此验证 #5 的快捷键、批量操作和拖放。

---

## Phase Audit

P3 两项均实现、每项完成真实验证和即时旧代码清理后，才进入本阶段审计；尚未实现的行为不得写入 `docs/features` 的“当前已支持”章节。
