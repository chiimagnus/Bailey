# P2：Files 选择语义与共享树行视觉

**Goal：** 游标移动不夺走已选中的背景或正在显示文件的灰底，
同时保持右键／键盘命令目标准确，复用现有共享树行。

**Non-goals：** 不给 Git Graph 添加 Files 式多选；
不更改 Git 操作、图谱拓扑、文件单击／双击和拖放后端。

**Approach：** 以 `FileTreeModel.selectedPath`（游标）、
`selectedPaths`（显式选中）、`selectedCompactPath`（紧凑段）、
`selectionAnchorPath`（范围锚点）为唯一状态来源。
优先用现有字段计算命令目标，**不预建另一份 context selection Store**。
共享视觉只改 `TreeRowSurface` 和必要调用参数，
不依赖后台窗口的焦点标志决定数据状态。

**Acceptance：** A 选中蓝底、B 游标蓝框、C 展示灰底、D Hover 灰底
可分别呈现；菜单有效期内右键 B 的 Copy 操作 B；
Esc 后如果 Files 真实聚焦则继续按 Files 游标操作 B，
若 Terminal／Editor 仍聚焦则恢复其原生 Copy。
多选批量操作准确；Git 和 Dock 原有行为不倒退。

**前置：** P1 的原生菜单路由已经验证，P2 复用其命令入口；
不得为了改变视觉重新加第二套键盘处理。

---

## P2-T1 分离 Files 游标、选中与命令目标

**源码锚点：**
- `Bailey/Files/FileTreeModel.swift`：
  `select(_:extending:toggling:componentPath:)`、
  `selectForContextMenu(_:componentPath:)`、
  `moveSelection(by:extending:)`、`selectedOperationPaths`、
  `contextSelection(for:)`、`clearSelection()`、
  `sync(root:backend:scope:panelIdentity:connectionRevision:)`、
  `rebuild(refresh:)`、`revealFile(_:)`、
  文件移动／改名后重映射路径
- `Bailey/Files/FileTreePanel.swift`：
  `focusSelectedRow()`、`handleKey(_:)`、
  `FileTreeRow.selectForClick(componentPath:)`、
  `selectForContextMenu(_:)`、`activeMenuTarget`、
  `rowMenu(for:)` 的 `matchesKeyboardSelection`／`matchesNewItemTarget`
- `BaileyTests/Files/FileTreeTests.swift`、
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`

**代码事实：**
`moveSelection(by:extending: false)` 同时重写游标和
`selectedPaths`；未选中行的 `selectForContextMenu` 调用
`select()`，会覆盖显式选择。
`focusSelectedRow()` 还会在没有游标时自动调用 `select()`，
隐式制造选中；`selectedOperationPaths` 当前只读
`selectedPaths`。这些是同一个状态耦合问题。

**Red → Green → Refactor：**
1. 在宿主先断言四条不同语义：
   - 左键选 A → ↓ 到 B：A 保留于 `selectedPaths`，
     `selectedPath == B`。
   - A 仍选中时右键 B：A 保留，B 获得游标；菜单有效时 Copy B。
     Esc 后 Files 确实持有焦点则 Copy B；Terminal／Editor 持有焦点时
     Copy 恢复其原生内容，不能让保存的蓝框决定快捷键所有者。
   - 选中集合 A/C、游标 A 或 C：Copy/Cut/Trash
     用 A/C；游标 B（集合外）则作用于 B，
     不因视觉上 A/C 为蓝色就误操作它们。
   - Shift+↑/↓ 依原范围锚点扩选，⌘点击精确增删；
     Escape 按实际事件层次取消菜单／清空选择。
   - AX `isSelected` 继续表示实际持久选中集合：
     A 蓝底且 AX 已选中，B 仅有游标边框时不能被误报为已选中。
2. 只在现有模型区分“游标移动”和“显式改选”。
   将系统 Edit 命令的操作集合由**当前有效游标与已有选择**
   推导出来；菜单中的右键路径仍通过 `contextSelection(for:)`
   精确取目标，不维持第二份独立命令路由。
   紧凑段使用已有 `selectedCompactPath`，不能把父文件夹误作目标。
   维持 P1 已修正的菜单目标与快捷键提示，不以“持久选中集合相等”
   决定菜单是否可以复制 B。菜单关闭时不能将菜单对象残留成
   窗口下一次的隐式快捷键目标。
3. 逐个复核其它真实状态修改入口：`focusSelectedRow()`
   初始选中、`revealFile(_:)`、左右键进入子行、
   新建／改名、批量操作、删除／折叠／刷新、
   `sync()` 切根与同 SSH 根重连、
   空集合／无游标／不可见行。
   **只改被新契约取代的联动**，保留 SSH 重连时
   已确认可信行的保护和文件操作的目标验证。
4. 新计算已覆盖旧 `selectedOperationPaths` 路径后，
   **本任务立即删除**无效的选择重置／重复 fallback；
   修改而非盲删依赖旧语义的 `FileTreeTests`：
   `testFileTreeMultiSelectionRespectsVisibleOrderAndKeepsSingleCursor`、
   `testContextSelectionMovesKeyboardCursorWithoutDestroyingMultiSelection`。
   同步修订 `WorkspaceFilesUITests.testMultiSelectContextTargetsAndBulkTrashAgainstRealDisk`
   中“右键集合外 C 应取消 A/B AX 已选中”的旧断言；
   新断言应为 A/B 保留蓝底与 AX 选中，C 成为命令目标，
   菜单 Copy Path 仅复制 C，Esc 后 Copy 也指向 C。
   保留显式取消后不自动重新选中的现有回归。
   若一个状态不必持久化，就不要新增可观察存储。
5. 同时更新 `docs/features/files.md` 中键盘、
   多选、右键、失效和撤销的行为描述；
   `docs/ui.md` 的详细颜色规则仍由 P2-T2 维护。

**验证：**
- `make test:FileTreeTests,PanelContextTests`。
- 定点 GUI：`WorkspaceFilesUITests` 的
  `testModifierMultiSelectionDoesNotOpenOrCollapseFiles`、
  `testMultiSelectContextTargetsAndBulkTrashAgainstRealDisk`（旧 AX 断言须更新）、
  `testMultiSelectKeyboardCopyCutPasteWithoutMoveDialog`、
  `testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`，
  `SharedTreeUITests.testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt`，
  以及 P1 新增菜单仍开 ⌘C 用例。
- 覆盖普通／Shift／Command／Control 点击、左右／上下键、
  无选／单选／连续与不连续多选、菜单取消与重新打开、
  中文长路径与紧凑段、多窗口与远端失效；
  核对剪贴板实际路径、文件字节与 AX 选中集合。
- 此任务必须在 P2-T2 绘制新颜色之前完成，
  不能仅凭新的像素掩盖错误操作目标。

## P2-T2 共享树行蓝底、灰底与描边各归其位

**源码锚点：**
- `Bailey/Shared/Tree/TreeRowStyle.swift`：
  `TreeRowSurface`、`TreeFileRow`、`TreeFolderRow`、
  `TreeRowLabel` 的状态颜色与 AX traits
- `Bailey/Files/FileTreePanel.swift`：
  `FileTreeRow.semanticRow`、重命名／Draft 分支、
  紧凑段局部 Hover
- 使用方：`Bailey/Git/GitPanel.swift`、
  `Bailey/Git/RecentCommitsView.swift`
- `BaileyUITests/Files/SharedTreeUITests.swift`、
  `BaileyUITests/Git/GitGraphUITests.swift`

**代码事实：**
共享行已经用 `multiSelected ? accent.opacity(0.14)`
画出浅强调色背景；`selected` 在 Files／Git 中主要表达
**当前显示的文件或 Diff**，而非显式选择。
现有 `multiSelected → selected → hovering` 三选一背景
使某些同时成立的事实被遮住。
`TreeFileRow` 和 `TreeFolderRow` 的 AX `isSelected`
按 `multiSelectionEnabled` 使用不同判断，
不能一刀切改成“焦点永不算选中”。

**Red → Green → Refactor：**
1. 用已存在的轻量 `NSHostingView`／真实行组件测试
   证明当前背景优先级问题；真实 GUI 分别采样
   A 选中、B 游标、C 正在显示、D Hover，
   以及同一行选中＋游标、选中＋展示、菜单展开／取消。
   不要因当前蓝底透明度较低就宣称它不存在。
2. 在 `TreeRowSurface` 明确名称与覆盖优先级：
   主题蓝底属于显式选中、灰底属于显示内容或 Hover，
   细边框只标记焦点游标／有效右键上下文。
   **同一行不能同时显示两个互斥的纯色底**：显式选中蓝底优先，
   当前展示灰底这一事实仍保留；该行取消选中后重新显示灰底。
   Hover 仅在不会遮盖更明确的背景时变灰；描边独立叠加，
   必须检查文本与 Git 状态颜色在所有重叠组合下可辨认。
   优先复用现有 `Theme.terminal(dark:)` 颜色和行几何；
   不新增通用 `VisualState` 类型、配置项或多层背景宿主。
3. Files 使用显式选中集合驱动蓝底和 AX；
   Git Changes／Graph 保留既有单游标、Diff 灰底与
   原生 AX 语义。Git 提交展开不制造持久背景。
   菜单展开时的右键描边不伪装 `TreeKeyboardView`
   仍持有原生第一响应者。
   保留重命名输入、Draft、长行滚动、
   Git 状态文字颜色和右侧动作的命中范围。
4. **同任务**删除被取代的互斥背景分支、
   误导性的参数名称和测试断言；
   若只是更换共享参数，立即同步所有调用者，
   不保留 `selected`／`multiSelected` 含义互换的兼容别名。
5. 更新唯一的视觉规范 `docs/ui.md#共享树行`；
   Files／Git 的功能页只描述各自的动作语义，不重复颜色表。

**验证：**
- 宿主：共享行实际颜色／AX 组件断言，
  加 `make test:FileTreeTests,AppIdentityTests`。
- E2E：`SharedTreeUITests.testLightFileSelectionFillRemainsAfterCommandPaletteTakesFocus`
  和 `testDarkFileSelectionFillRemainsAfterCommandPaletteTakesFocus`
  按真实新语义修订，并增加 A/B/C/D 重叠样式断言。
- 在明暗模式、主题切换、字体上下限、窄宽停靠、
  鼠标离开、失焦与菜单打开、中文长名和大量行中检查
  行像素／AX 以及无重复系统焦点环；
  树线、文件 Git 状态、拖放、按钮、水平滚动不倒退。
- 若瞬态菜单高亮不可可靠截图，
  按 P1 已确认的原生验证方法补验，不使用 OCR 猜颜色。

## P2-T3 Git 共享行与跨组件回归

**源码锚点：**
- `Bailey/Git/GitPanel.swift`：
  `focusContextChange(_:)`、`handleGitChangeKey(_:)`、
  `GitEntryRow`／目录行、`isDisplayedChange(_:)`
- `Bailey/Git/RecentCommitsView.swift`：
  `selectRow(_:)`、`isFocusedRow(_:)`、
  历史／Worktree 文件、Stash、提交和标签菜单
- `Bailey/UI/Panels/ProjectsPanelView.swift`、
  `Bailey/UI/WorkspaceDockView.swift` 的现有右键／活动组状态
- 实际受影响的 `BaileyTests/Git`、
  `BaileyUITests/Git`／`Files`／`Workspace`

**本任务只负责 Git 的实际接入和交叉验证，
不是“最后一次清理”。** P1 和 P2-T1/T2 已分别移除
各自替代的旧代码与失效测试。
如果这里发现 Git 自身冗余的右键回调或布局兼容分支，
在修改其唯一所属调用链时同步删除，不能留给后续补丁。

**步骤：**
1. 检查共享树行样式对 Git Changes／Graph／历史文件的调用，
   核对提交展开、Diff 显示灰底、Stash／Worktree 标签、
   右键菜单及输入焦点；只修确实失效的 Git 局部链，
   不复制 Files 的多选集合或修改 Git 图谱拓扑。
2. 真实菜单和系统键盘验证 Git 行与 Files、
   Dock ⌘W、Projects、Editor、Terminal、
   Git 输入框、Palette／Sheet、双窗口之间的焦点交接；
   已有的 `WorkspaceDockUITests` 三文件关闭行为继续保留。
3. 对已识别适用边界进行覆盖：空 Git、冲突／暂存／未暂存、
   重命名与未跟踪、长中文路径、紧凑目录、
   窄面板／字体极值、悬停／右键／键盘组合、
   高频更新导致目标失效、SSH 断线／恢复；
   所有写操作必须核对真实 Git index／HEAD／工作树。
4. 只在 Git 自有回调有证据失效时进行最小修正，
   **当次**删除其旧路径、同步 `docs/features/git.md`；
   否则本 task 仅做回归与覆盖核销，
   不为“完成重构”制造 Git 生产代码改动。
5. 检查 `docs/features/dock.md`、
   `docs/features/files.md`、`docs/ui.md`、
   `AGENTS.md` 是否仍存在相互矛盾的现行规则，
   删除确实过时的描述；不迁移不相关文档。

**验证：**
- 相关宿主：`make test:FileTreeTests,DockWorkspaceTests,DockFocusIntegrationTests,AppIdentityTests`，
  加实际受影响的 Git 类。
- 定点 UI：`SharedTreeUITests` 对应右键／视觉用例、
  `GitChangesUITests.testRightClickAnotherGitChangeMovesKeyboardCursorWithoutOpeningDiff`、
  `GitGraphUITests.testRightClickDifferentCommitMovesGraphKeyboardCursorWithoutOpeningHistory`、
  `WorkspaceDockUITests.testRightClickFileTabAndCommandWCloseTheSameFile`，
  以及 P1 新增的菜单真实按键用例。
- 使用根 `Makefile` 做最终 Debug 构建／严格签名，
  遵循项目验收完成标准和本地安装规则；
  不重复执行整套无关 GUI 用例。
- 真实 SSH 仅在取得获授权的专用测试主机后验证，
  不借用用户 SSH master；不可获得的 macOS 15.6
  或独立图形会话逐项写明阻塞、影响和补验。
  GUI 自动化不能占用用户正在输入的桌面而假称隔离。

---

## P2 Gate

本功能全部已识别且可安全执行的条件和重要组合已核销；
模型游标、选中、菜单操作目标与最终副作用一致；
真实 GUI 的菜单打开期间快捷键、背景／边框、
Dock 原生反馈与未保存保护均已明确验收。

任一任务中被替代的旧代码、重复快捷键入口、
无效状态恢复分支和过时测试均在**所属任务内**清理；
不得将遗留问题集中推给最后一个 task。
不能实测的环境有清楚的限制及补验方式，
不把宿主绿色、构建或菜单右侧提示当作完整 E2E Go。
