# P4：Git 管理器、图谱与输入框的焦点语义

**Goal：** 使 Git Changes、Git Graph 的文件行/提交行按照 Zed 的“选择归列表、输入归输入框、打开归目标内容”工作；行焦点边框不等于展开详情，也不等于已打开 Diff 标签。不要因开 Diff 直接抢走 Git 的方向键和提交框。

**Non-goals：** 不移植 Zed 的 GPUI、Git Graph 新搜索框、全部 Git 列表多选/批量操作、可配置的点击行为与焦点颜色；不改变 Bailey 的 Git 拓扑、Commit/Branch/Tag/Stash 真实操作及既有“点击展开”交互。

**上游证据：** [Zed GitPanel](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/git_ui/src/git_panel.rs) 单独持有 `selected_entry` 与提交信息编辑器的焦点；文件行描边只在 `selected && focus_handle.is_focused(window)` 时显示；`open_diff` 在部署 Project Diff 后仍将焦点留回 Git 列表。 [Zed GitGraph](https://github.com/zed-industries/zed/blob/1d8a29e1e2f65b6be6c176f90af801286ac11cc4/crates/git_ui/src/git_graph.rs) 分离提交表格的选中索引、表格键盘焦点和搜索输入焦点。只吸收这些正确性关系，不机械复制其它 UI。

**Approach：** 复用 P3-T1 的「展示内容 vs 激活编辑器」能力、P3 将共享文件/目录行改为**非 Button 可选择条目**的结构，以及 P3-T2 的行焦点绘制；保留 Git Changes/Graph 自身的滚动、目录压缩和 Git DAG，不迁移到 List。Git Changes 当前没有独立行游标，在现有 `GitPanel` View 状态增加一个稳定当前行身份；Git Graph 在已有 `RecentCommitsView` 视图状态中维持自身的行游标。二者不共享全局焦点存储，也不把 UI 选择写进 `DockWorkspaceModel` 或 `GitStatusModel` 的 Git 查询事实，不新增全局 Focus Manager；原生 TextField / NSAlert 仍保留实际 first responder。

**Acceptance：** 在 Git 仍可见且存在独立 Diff 目标组时，单击变更文件显示 Diff 后仍能用方向键继续选变更；若 Git 面板与文件原本共组且被 Diff 替换，按 P3 的可见编辑器退路转移焦点，绝不保留隐藏 Git 的假焦点；当前行且列表真正聚焦时有细边框。Git 图谱的提交展开、提交/文件行选择、文件 Diff 是三种独立状态；过滤/提交输入框得到焦点后，列表边框自动撤销，键入不触发 Git 行或编辑器命令。

---

<a id="p4-t1"></a>
## P4-T1 Git Changes 的文件行与 Diff 焦点

**源码锚点：** `Bailey/Git/GitPanel.swift`（`row/directoryRow/GitEntryRow/openIfPossible/filterBar`）、`Bailey/UI/Panels/ToolPanelView.swift`（`openFile/openDiff`）、`Bailey/Workspace/{TerminalManager,Project,DockWorkspaceModel}.swift`（`openDiff/selectTab`）、`Bailey/Shared/Tree/TreeRowStyle.swift.TreeFileRow`。目前 `GitEntryRow` 复用单一打开回调，`Project.openDiff` 无条件 `selectTab`，因此点击一条变更即激活 Diff 组。

1. **Red：** **当前 `GitPanel` 有 `filterText` 等 View 状态，但并没有现成的当前 Git 文件行游标；`GitEntryRow` 当前靠共享 `TreeFileRow` 整行 Button 打开 Diff；P3 去掉共享行 Button 后，Git 应接通自己的行选择与打开意图，不能恢复整行 Button。** 在真实 Git 临时仓库建立 unstaged/staged/merge/untracked、同路径多分组、目录压缩、空状态和外部刷新，检查点击变更行后：Diff 已实际显示、Git 组仍活动、列表实际接收 ↑/↓/Space/Return、当前行有焦点边框；切到编辑器/提交框或另一个窗口，边框不应继续假亮。右侧 Stage/Unstage/Discard 按钮及右键不能既执行 Git 操作又打开 Diff；右键弹出菜单期间选中目标保持一致，菜单关闭后只恢复仍可见且属于当前 Git 的焦点行；失败或目标刷新后不能继续操作旧文件。
2. **Green：** 利用 P3 已提供的打开意图区分，在 Git 列表默认的点击/浏览操作中调用现有 `openDiff`，**只要 Git 仍可见就不激活 Diff 分屏**；同组展示覆盖原 Git 时转向可见目标，不造额外分屏；**普通单击与键盘 Space/Return 的 Git Project Diff 浏览应保留 Git 列表焦点**（参照 Zed `GitPanel.open_diff`）；明确「Open File」或点击已经展示的 Diff 标签才转向内容焦点。双击不得凭空新造 Zed 的另一类 FileDiff 业务类型，现有右键「Open Changes」和动作菜单语义保留并单独实测。Git 列表当前游标仅通过 `GitPanel` 的最小 View 状态扩展承载，身份包含仓库/机器/section/路径，不能只按文件名或索引；行焦点细边框复用 `TreeRowSurface.focusRing`，`selected` 仅代表当前展示的 Diff，Hover 独立绘制，不在 Git Row 重复绘制；Stage/Unstage/Discard 等行内独立 Button 仍只执行自身动作，不触发打开 Diff。仅当前 Git 列表真正具有键盘焦点时绘制。
3. **覆盖：** staged/unstaged/merge、同一路径同时出现在多个 section、目录行与文件行、过滤前/后、status 新旧列表、仓库切换、本机/授权 SSH/失联恢复、只读 Git 状态、大小写/Unicode 路径、0/1/千级项，点击/双击/菜单/键盘、外部 Git 写入/异步详情、双窗口、多组、主题/缩放/窄栏、Copy/Paste/快捷键路由、危险动作 Sheet、旧缓冲保存。验证实际 Diff 内容（源仓库、staged side、字节）、Git index/HEAD 只有被明确操作时改变，首响应者是当前 Git 列表而非旧 Diff/编辑器。相关 `RecentCommitsViewTests`、`GitStatusModelTests`、`WorkspaceWindowIsolationTests`、`TreeRowHitTestingTests` 与真实完整 App GUI。
4. **同任务清理：** 删除这一条路径上多余的「开 Diff 即激活」和重复焦点补救；不改变 Git 后端原子操作、不引入新的仓库缓存。更新 `docs/features/git.md`、`docs/features/dock.md` 与 `docs/ui.md` 的真实实现，中文原子提交。

---

<a id="p4-t2"></a>
## P4-T2 Git Graph 提交/文件选择与面板内部输入焦点

**源码锚点：** `Bailey/Git/RecentCommitsView.swift`（`commitRow/toggle/commitFiles/changedFile`、`expandedCommitIDs`）、`Bailey/Git/GitPanel.swift`（`commitBox/filterBar/handleHistoricalFile` 与实际 Sheet）、`Bailey/Workspace/Project.swift.openCommitDiff/openHistoricalDiff`、`Bailey/UI/Panels/ProjectsPanelView.swift`（行与改名框）、`Bailey/Files/FileTreePanel.swift.nameField`、`Bailey/UI/CommandPaletteView.swift`（`searchFocused`）、`Bailey/Shared/Tree/TreeRowStyle.swift`。`RecentCommitsView` 的**提交主行本来就是 `.onTapGesture { toggle(commit) }`，不是整行 Button**，但 `expandedCommitIDs` 同时驱动展开与背景，缺少独立键盘行游标；历史文件点击 `openDiff` 也会激活编辑器。`GitPanel` 的提交/过滤输入框是 SwiftUI `TextField`，并不等价于 Git 列表拥有焦点。**Zed GitGraph 有自己的搜索输入框，但 Bailey 当前没有；本任务只覆盖已存在的提交说明、过滤、新建/重命名以及原生对话框，不新增 Git Graph 搜索框。**

1. **Red：** 实际点击 Git Graph 提交/Branch/Tag/Stash 和其展开文件，分别记录：展开状态、唯一键盘游标、可见边框、真实 Diff 内容、`NSWindow.firstResponder`、命令目标。一个提交展开后点击另一提交，原来展开的节点**不应被错误认为仍有焦点**；图谱轨道/引用标签点击仍执行原有「展开详情」，右侧菜单保持原功能。Space 在当前提交/文件/目录行上执行与单击相同的展开、Diff 浏览或目录展开动作，方向键能在当前可见的提交、目录和文件行之间导航；独立 Git Changes 列表与图谱的上次选中行和实际键盘响应者互不覆盖。历史文件单击或 Space 展示 Diff 但不夺走 Git；明确转编辑器时才转焦点。证明用 `commit.id`/提交哈希+文件路径+阶段/储藏身份区分同名、不同提交和其它 worktree，不能用展开状态或当前 FileTab 推断行焦点。
2. **Green：** 在 `RecentCommitsView` 自己记录最小、稳定的图谱行游标；展开集合继续独立持有展开状态；树行焦点描边复用 P3 的 `TreeRowSurface.focusRing`，灰色背景仍只由已展开提交或正在展示的 Diff 驱动，图谱提交主行保留**已经存在的非 Button `.onTapGesture`**，只复用共享行的焦点绘制机制，不能为追求统一把它重新包装成 `TreeFileRow`、`List` 或重画 Git DAG。`Project.openHistoricalDiff/openCommitDiff` 沿用 P3 的打开意图区分，并覆盖 Git Graph 工作树节点的 Diff 入口；不能只改 Git Changes 的 `openDiff`。Git 变更列表、Git 图谱、提交信息 `TextField`、过滤 `TextField`、历史详情中的原生控件，分别响应真实输入焦点：进入 TextField 时行环撤去，⌘A/C/X/V、中文 IME、Return/⌘Return/Escape 发给正确控件；退出有效输入后才按需要恢复仍存在的 Git 行，不抢正在操作的 Diff、终端或浏览器。复杂的 `NSAlert/Sheet/ContextMenu` 继续沿当前窗口的原生焦点链，不复制 Zed 的 GPUI 菜单焦点 workaround。
3. **闭环测试：** 多提交/合并/截断历史、多引用+N/折叠/分页、工作树 Uncommitted Changes、Stash、graph tree/flat、历史文件重复路径、Git 状态刷新时选中对象消失/引用移位、SSH 换仓库与断线；提交框/过滤/新建重命名/确认 Sheet/右键嵌套菜单/命令面板/Settings/Projects 行和项目改名/终端查找/浏览器地址栏之间来回切换；连按键、输入法组合、Cmd/Shift、方向键、Tab、焦点前后台、双窗口、极窄与 6+ 分屏、明暗/字体及 VoiceOver 基础命中。使用 `RecentCommitsViewTests`、`WorkspaceWindowIsolationTests`、`PaneRetentionTests`、`TreeRowHitTestingTests`、Git 对话框相关 XCTest 和实际 GUI；验证展开/选择/真正输入、Git index/HEAD、未保存字节与原生对象身份。对 Projects/Palette 等未证实故障的入口先作真实回归，**有 Red 证据才补最小修复，不添空泛的新焦点状态机**。
4. **同任务清理：** 删除 Git 图谱的旧“展开等于选中/聚焦”视觉假设、无法到达的焦点后备路径及被替换的重复键盘分发（若本任务确已替代），但保留当前实际负责键盘和 Sheet 的原生保护。同步 `docs/features/git.md`、`docs/ui.md` 和实际触及的输入所属文档；中文原子提交。

---

## Phase Audit

每个 task 均需完成 Red→Green→Refactor、实际键盘输入和最终内容/操作结果验证、即时文档与旧路径清理；P4 全部完成后再进入阶段审计。不得以“绘制了选中边框”“事件已发送”或完整 XCTest 绿灯替代从 Files/Git 点击到实际焦点/字节的 App 级验收。
