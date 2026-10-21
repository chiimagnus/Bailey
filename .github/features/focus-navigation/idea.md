# Focus：像 Zed 一样分离“显示、选中与输入”

需求归属：[Issue #13](https://github.com/chiimagnus/Bailey/issues/13)。本计划覆盖 Bailey 的窗口、Dock、Files、Git Manager/Graph 与原生输入焦点。Files 的多选、剪贴板、文件操作及拖放仍由 [#5](https://github.com/chiimagnus/Bailey/issues/5) 实现；快捷键自定义归 [#43](https://github.com/chiimagnus/Bailey/issues/43)。

## 用户要求与上游依据

- 对照用户提供的 Zed 截图（`/Users/chii_magnus/Downloads/截屏2026-10-21 03.14.53.png`、`/Users/chii_magnus/Downloads/截屏2026-10-21 03.15.00.png`），Bailey **不显示分屏蓝色外边框**；选中标签依然明确，当前活动组的标签文字/图标可略突出，其它组不整体变暗。
- [Zed Project Panel](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/project_panel/src/project_panel.rs) 将 `selection`（当前行）、`marked_entries`（多选集合）和 `focus_handle`（输入焦点）分开；单击文件时 `focus_opened_item=false`，显示文件但焦点留在文件树；双击文件时 `true`，焦点转编辑器。文件行边框条件是 `is_active && contains_focus`，并在鼠标按下的过渡中避免假边框。Zed 的临时预览标签另有设置；**不为复制焦点行为而提前实现预览标签体系**。
- [Zed Git Panel](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/git_ui/src/git_panel.rs) 同样独立处理选中行、列表焦点、提交输入框和右键菜单；变更行只在 `selected && focus_handle.is_focused` 时描边。点击文件可展示 Diff，列表继续接收方向键；输入提交说明时应由文本控件接收按键。
- [Zed Git Graph](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/git_ui/src/git_graph.rs) 分开提交的选中索引、表格交互焦点与搜索输入；[Pane](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/workspace/src/pane.rs) 区分当前显示的标签和焦点是否落在该 Pane/内容中。这里只借鉴行为，不移植 GPUI 状态管理。

## Bailey 已确认的根因

- **P1 已实现的基础**：`DockWorkspaceModel.activeGroupID` 与每组 `DockGroup.selected` 分离；`Project.selectedTabID` 仅记录工作标签上下文。`WindowRootView` 每窗口有自己的 `TerminalManager`；菜单使用 `focusedSceneValue`。这些不能重做。
- **P2 已落地的部分**：`WorkspaceDockView` 取消整组描边、保留各组已选标签；`DockGroupFocusView` 监听当前窗口的输入变化，Ghostty/TextKit/WebKit 原生视图各自持有第一响应者。工具组无实际文本输入时可接管空白焦点，不能在控件收到鼠标前强行抢占输入。
- **Files 的真实错误链**：`FileTreePanel.FileTreeRow.semanticRow` → `ToolPanelView.openFile` → `TerminalManager.openFile` → `Project.openFile` → `Project.selectTab` → `DockWorkspaceModel.select`。无论新建还是复用文件标签，都会**同时切换显示内容与活动组**。Git 的 `Project.openDiff/openHistoricalDiff` 也一样；在面板浏览文件时不应总把键盘移入编辑器。
- **Files 的行状态缺失**：`FileTreeModel` 没有独立当前行游标，`ToolPanelView.openFilePath` 提供的只是最近工作 FileTab 的路径；不能由此推断键盘选中的文件，尤其不能混淆本机/SSH 同名路径。
- **Git 的状态混同**：`GitPanel.GitEntryRow` 走无条件激活 Diff 的回调，当前 `GitPanel` 尚无独立的当前文件行游标；`RecentCommitsView.expandedCommitIDs` 是展开集合，不是焦点游标。Git Changes 文件可在 staged/unstaged/merge 中同路径重复；Git Graph 同路径可出现在不同 commit/stash/worktree，身份不能仅用路径或数组位置。
- **树行视觉原有缺陷**：旧 `TreeRowSurface.focused` 曾与 Hover 共用灰底；现由 `selected`、`focusRing`、Hover 分别控制灰底、描边、临时悬停。Files 行 `@FocusState`、Git 提交/过滤 `TextField`、Projects 重命名、Command Palette 搜索字段分别拥有真实输入焦点；一个 Dock 活动组里不等于所有行同时获得焦点。

## 必须满足的交互

| 当前动作 | 显示／选中结果 | 真正键盘焦点 |
| --- | --- | --- |
| 点击 Dock 的工作标签 | 该组展示目标标签，保留其他组各自的选中项 | 目标内容，或其有效原生输入控件 |
| Files 单击文件 | 打开/复用文件内容，**保留可见 Files 列表**并选中对应行 | Files 列表；当前行有细边框 |
| Files 双击、Return 或显式转到编辑器 | 激活该文件所在组，不复制 FileTab | 编辑器；Files 行焦点边框撤去 |
| Files 点击目录 | 原有展开/折叠语义，不强制打开文件 | Files 列表，所选行反馈正确 |
| Git Changes 单击文件／Return 浏览 Diff | 展示正确的 unstaged/staged/merge Diff，保留列表选择；显式 Open File 或点击工作标签再转焦内容 | Git 列表；行焦点有边框 |
| Git Graph 点击提交/文件 | 提交展开、图谱行选择、历史 Diff **分别记账** | 当前操作的 Git 列表；显式转编辑器才转焦点 |
| Git 提交说明／过滤、新建／重命名、原生 Sheet | 原控件完成输入与操作，不改变无关行选择 | 实际 TextField 或原生对话框；列表焦点环暂不显示 |
| 切窗口、⌘P、拖放、关闭/恢复 | 不改变无关 Dock 内容与文件，失效焦点回退到有效目标 | key window 的可见控件；失效、已停车及后台内容不得抢回 |

**Bailey 特有边界：** 工具和工作标签可停靠在**同一 Dock 组**。若点击后该组变成编辑器、Files 因而不再可见，不能宣称 Files 仍接收键盘，不能放一个隐藏焦点或自动分屏来伪装 Zed。优先复用已存在的可见编辑器组；确实没有独立目标时显式切入可见编辑器并说明这一可验证的合理退路。

**视觉：** Dock 不画蓝色外框，非活动组不整体降透明度。Files/Git 的行边框必须同时满足「当前游标对应的行」和「所属列表实际接收输入」，不能由 Hover、展开、活动标签或鼠标单击发生前推断。多选背景、当前工作文件/变更状态、行边框相互独立。

## 责任归属和排除项

- **P1/P2** 保留已经实现的 Dock 活动组、工作标签和原生焦点管理；先完成 P2 的真实窗口/拖放焦点恢复验证，不逆向引入蓝框。
- **P3** 在现有 `Project` / `DockWorkspaceModel` 提供最小「显示所选标签但不激活组」途径，Files 单/双击与稳定单行游标、真实行焦点边框接入。必须保持外部 Finder、⌘O、命令面板及明确标签选择默认激活行为，不能一刀切取消 `selectTab`。
- **P4** 复用 P3 的显示意图与共用 `TreeRowSurface`，给 Git Changes/Graph 提供自己的**最小行焦点状态**和原生输入归属；不借用 Files 的状态对象，不复制 Git 后端状态到另一管理器。
- **#5 File Manager** 在 P3 已建立的单行游标上扩展 Cmd/Shift 多选、选择锚点、剪贴板、批量文件操作和拖放；不再另造当前行游标或重做单击焦点修复。
- **不做：** Zed 预览标签生命周期、全局 FocusManager、第二套 Dock 树、额外 Focus bus/轮询、焦点主题设置、Git Graph 新搜索框、Git 列表全套多选或全部点击配置。保留现有 `ScrollView + LazyVStack + TreeRowSurface`：共享 Files/Git 树的可选中整行可改为**非 Button 的可聚焦条目**，独立 Stage/Discard 等操作仍是 Button；**不迁移到 `List`**。优先用 SwiftUI 单/双击、键盘和焦点能力实现，实测有问题再考虑必要的 AppKit；不为复制 Zed 的点击计数建立事件框架。没有真实 Red 证据时不引入新的世代号、回退链、响应者存储层或大范围快捷键改造。

**每个任务当次完成**：源码与真实触发入口、Red→Green→Refactor、删除确已被替代的旧路径、对应当前文档、中文原子提交。`todo.toml` 是任务状态唯一来源；历史审计和不再适用的原型不能覆盖当前用户决定。

## 最大可行验证边界

- **环境**：当前 macOS + 最低 15.6 的可得环境，Swift 6 / Xcode、明暗/系统主题、中英、常规/大字号、实际辅助功能、不同显示尺寸；本机与仅获授权的 SSH 测试主机（在线、断线、重连）。
- **布局与身份**：0/1/2/6+ Dock 组，横纵/复杂嵌套、两窗口、不同项目 A→B→A、Files 与编辑器同组/异组、空组、浏览器/终端/编辑器/Diff 同时可见，窗口失活/重新激活、拖动 hover/取消/完成、关闭/重新挂载/恢复、同本机/远端路径。
- **输入与容量**：单/双击、修饰键、右键多级菜单、长按与拖放、键盘连续 ↑↓/Return/Tab/Escape/⌘A/C/X/V/S/F/P/W、中文 IME、Undo、粘贴/复制、提交输入/过滤/重命名/查找、空列表/单项/千级项、目录折叠/压缩/软链、超长/Unicode/同名文件。
- **失败与时序**：文件未加载、权限错误、文件消失、Git 正在刷新/切分支、SSH 会话中断及旧异步结果、多个后台输入框或弹出 Sheet、窗口/项目已切换、快速重复点击与打开、原生停车的 Ghostty 与缓存编辑器、保存失败及脏文件保护。
- **实际判定**：观察 `DockGroup.selected`、`activeGroupID`、实际 `NSWindow.firstResponder` 与菜单目标、屏幕行焦点描边和用户可见文件/历史 Diff、原生 TextKit/Ghostty/WebKit 身份、最终文件字节/Undo、Git index/HEAD 是否只在明确操作下变动。仅报告确实执行过的 XCTest/原生窗口/完整 App GUI 层次；无法实测的具体系统/主机/物理输入逐项保留限制与补验条件，不冒称全部通过。

执行依赖：[P1 基础](plan-p1.md) → [P2 窗口与标签](plan-p2.md) → [P3 Files](plan-p3.md)。P3 的共用打开意图和行焦点基础验收后，[P4 Git](plan-p4.md) 与 [#5 文件多选](../file-manager/plan-p1.md#p1-t1) 可分别推进；同时修改 `TreeRowSurface` 时需共享回归，不人为把它们排成一条长队。

维护文档：`docs/features/{dock,files,git,editor,command-palette}.md`、`docs/ui.md`，以及确实受影响的终端/浏览器/Projects 交互文档。**计划是待做任务，不可提前把未来行为写进这些“当前实现”的文档。**
