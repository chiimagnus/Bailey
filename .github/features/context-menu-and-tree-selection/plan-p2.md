# P2：树行选中、浏览与焦点视觉分离

**目标：** 明确选中、当前展示、Hover、键盘游标、右键命令目标的归属，
让蓝底、灰底和边框按事实独立存在，并统一 Files／适用 Git 树行的绘制。

**非目标：** 不改变 Git 图谱拓扑、历史提交展开方式、
文件单／双击打开规则、目录结构、拖放与后端协议。

**实现原则：** `FileTreeModel` 已有 `selectedPath`、
`selectedPaths` 和 `selectionAnchorPath`，先复用这些状态，
仅在真实菜单生命周期无法表达右键目标时添加最小局部状态。
样式统一落在 `TreeRowSurface`，不为 Files 和 Git 各自复制一份。

**完成条件：** 左键选择 A 后，游标移至 B／右键 C，
A 的明确选中底色仍保留；当前展示文件的灰底不随游标消失；
命令指向正确目标，编辑器及 Git 不受劫持。

**前置：** P1 已确认原生菜单快捷键目标与响应者机制。
若 P1 结论影响右键目标生命周期，先将同一结论落到 P2 的状态边界。

---

## P2-T1 分离 Files 显式选择、游标和右键目标

**涉及位置：**
- `Bailey/Files/FileTreeModel.swift`：
  `select(_:extending:toggling:componentPath:)`、
  `selectForContextMenu(_:componentPath:)`、
  `moveSelection(by:extending:)`、`selectedOperationPaths`、
  `contextSelection(for:)`、`clearSelection()`
- `Bailey/Files/FileTreePanel.swift`：
  `focusSelectedRow()`、`selectForContextMenu(_:)`、
  `selectForClick(componentPath:)`、`handleKey(_:)`、
  `rowMenu(for:)`
- `BaileyTests/Files/FileTreeTests.swift`、
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`、
  `BaileyUITests/Files/SharedTreeUITests.swift`

**需修复的现状：**
`moveSelection(by:extending: false)` 同时改写 `selectedPath` 和
`selectedPaths`；对未选中行调用 `selectForContextMenu` 会改选整组，
导致持久选中无法独立于游标移动。
`rowMenu(for:)` 已有独立的 `selection` 计算，应复用而不是复制状态机。

**步骤：**
1. 宿主 Red：左键选 A 后，↓ 到 B，
   验证 `selectedPath == B`，但 `selectedPaths` 仍包含 A；
   右键 C 后游标到 C、选择仍为 A、菜单目标为 C；
   右键已选中集合成员则菜单目标为整组。
   在相同前提下核对“菜单外 ⌘C 按明确选中操作、
   菜单内 ⌘C 按右键上下文操作”。
2. 在现有 FileTree 模型里区分“移动游标”和“显式改变选择”。
   Shift＋方向键执行范围选择；普通方向键仅导航；
   Command 点击增删集合；普通左键改选单项。
   初始化／恢复焦点不应误把导航当成用户显式选择。
3. 右键更新当前游标与临时操作目标，
   不隐式取消 A 的持久选中；
   菜单动作与随后返回 Files 的原生输入各自解析目标。
   保留紧凑文件夹中间路径、批量选择和复制／移动保护。
   若目标不再有效，拒绝操作或按既有规则回退到仍有效的显式选择，
   绝不默默操作另一项目。
4. 删除被替代的“每次移动就覆盖多选集合”的分支，
   统一 Escape、折叠、根切换、重命名、删除、刷新
   对游标／选择／上下文的失效规则。
   不新增第二份可写模型或全局焦点表。
5. 同 task 更新 `docs/features/files.md` 的操作语义，
   纠正 `docs/ui.md` 中依赖旧的“右键未选中行即改选”说明。

**验证：**
- `make test:FileTreeTests`
- 重点 E2E：`WorkspaceFilesUITests.testModifierMultiSelectionDoesNotOpenOrCollapseFiles`、
  `testMultiSelectContextTargetsAndBulkTrashAgainstRealDisk`、
  `testMultiSelectKeyboardCopyCutPasteWithoutMoveDialog`、
  `testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`；
  `SharedTreeUITests.testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt`。
- 覆盖单选／零选／不连续多选／范围锚点；
  右键集合内外、Control-点击、菜单取消后再按键、
  长目录／紧凑目录、折叠后的隐藏行、文件刷新、
  重命名／新建输入框、当前显示文件与选中不一致、
  双窗口和切项目；每种命令核对真实剪贴板或磁盘结果。
- 文件变更与窗口切换时不得保留失效目标；远端断线不触发本地误操作。

## P2-T2 共享 TreeRowSurface 分层绘制与无障碍

**涉及位置：**
- `Bailey/Shared/Tree/TreeRowStyle.swift`：
  `TreeRowSurface`、`TreeFileRow`、`TreeFolderRow`
- `Bailey/Files/FileTreePanel.swift`：`FileTreeRow.semanticRow`、
  `hasKeyboardCursor`、`isCurrent`、`isMultiSelected`
- `Bailey/Git/GitPanel.swift`、`Bailey/Git/RecentCommitsView.swift`：
  共享组件参数及其实际展示语义
- `BaileyUITests/Files/SharedTreeUITests.swift`、
  `BaileyUITests/Git/GitGraphUITests.swift`

**需修复的现状：**
共享行表面通过 `multiSelected ? accent : selected ? gray : hovering ? gray`
一次性决定背景；其中 `selected` 实际代表“当前展示文件”，
`multiSelected` 才代表文件树显式选中，名称与事实不符。
边框仅由 `focusRing` 绘制，需避免将菜单临时目标误报为原生键盘焦点。

**步骤：**
1. 建立真实视觉 Red：A 显式选中、B 当前正在显示、
   游标 C、Hover D；切换鼠标与菜单后对照四行背景、
   主题边框和 AX。增加同行选中＋游标、
   选中＋Hover、显示＋Hover、失焦输入框等重叠组合。
2. 用清晰的属性名称表达“当前展示”“明确选中”
   “真实键盘焦点／菜单目标”和“悬停”；
   仅保留实际需要的共享参数，不新建通用 VisualState 状态机。
   背景按有意义的视觉层绘制：明确选中用主题色，
   当前展示独立保留灰底；Hover 不覆写持久事实，
   边框独立叠加，并保持文本、状态颜色可读。
3. 实际键盘焦点只由当前前台窗口的原生响应者决定；
   菜单临时右键描边按右键目标生命周期显示，
   不伪造 `TreeKeyboardView` 已成为第一响应者。
   维护文件、目录、紧凑目录和 Git 行的同一命中范围。
4. 更新共享行所有实际调用点，删除误导命名和失效样式路径。
   保留 Git Graph 的“展开不绘制持续灰底”契约，
   不将提交展开误标为文件选中。
   AX 选中 trait 必须反映实际显式选择，不只根据焦点描边决定。
5. 同 task 更新 `docs/ui.md` 的唯一树行视觉真源；
   不重复复制同一规则到每个面板文档。

**验证：**
- 宿主／原生轻量组件验证状态到背景、边框及 AX 映射，
  与动态主题切换同步；不只比对 Bool。
- E2E：`SharedTreeUITests.testLightFileSelectionFillRemainsAfterCommandPaletteTakesFocus`
  和 `testDarkFileSelectionFillRemainsAfterCommandPaletteTakesFocus`
  在新语义下更新断言，补 A/B/C/D 重叠行像素与 AX 验证。
- 使用当前 macOS 的浅／深色、暗色主题变换、
  长中文路径、窄／宽面板、字体最小／最大尺寸、
  悬停与选择交替、多文件大量行、首次与重新挂载。
  测试截图仅用于验收，不自动上传 PR。
- 验证背景变化不改变行高、拖放区域、右侧图标按钮、
  目录树线和横向滚动行为。

## P2-T3 核销 Git／Dock／窗口交叉行为并清理旧路径

**涉及位置：**
- `Bailey/Git/GitPanel.swift`：`focusContextChange(_:)`、
  Changes 行 `TreeFolderRow`／`GitEntryRow` 以及独立键盘焦点
- `Bailey/Git/RecentCommitsView.swift`：`selectRow(_:)`、
  历史文件、Stash、Worktree、引用标签与键盘游标
- `Bailey/UI/Panels/ProjectsPanelView.swift`、
  `Bailey/UI/WorkspaceDockView.swift`：右键不切换展示的既有边界
- 受影响的 `BaileyTests`、`BaileyUITests/Git`／`Files`／`Workspace`；
  `docs/features/git.md`、`docs/features/dock.md`

**步骤：**
1. 对照 P1、P2 的菜单与视觉新行为，
   检查 Git Changes／Graph 现有右键回调、
   历史文件与提交展开、Workspace／Worktree 标签；
   只修实际失效的共享入口，不为 Git 加一套选择系统。
2. 验证 Dock 的 ⌘W 关闭目标与 Files 的 ⌘C
   不会互相劫持；右键 Files 某行后切到另一个 Dock 组、
   Project 或窗口，旧文件命令失效，且不会误关新组。
   包含先右键后按 Esc、再键入及菜单仍开时按快捷键。
3. 检查焦点交接时的实际第一响应者：
   Editor、Terminal、Git 输入框、命令面板、原生 Sheet，
   及两窗口之间的菜单目标；以真实输入文本／剪贴板、
   Git index／文件内容和标签存活作为结果。
4. 逐项核查边界：无项目、无文件、只读、
   中文和 emoji、紧凑目录、大量行／窄侧栏、
   多选超过可见范围、拖动中右键、删除／恢复目标、
   本机／SSH 切换及远端中断、连续重复按键。
   结合实际可用的 macOS 15.6／当前系统、
   中／英文、浅／深主题和签名／辅助功能权限验收。
5. 对可复现且属同根因的问题在本 task 修复并加回归，
   同步对应功能文档；删除被替代的重复状态／处理分支。
   未能实测的每项环境在任务证据中记录原因、影响、
   替代证据与补验路径，不能笼统标记“全部通过”。

**验证：**
- 定点宿主：`make test:FileTreeTests,AppIdentityTests,DockWorkspaceTests,WindowCloseIntegrationTests`，
  及 Git 实际受影响的对应测试类；成功后检查 Debug 构建与严格签名。
- 定点 GUI：`make test:ui ONLY_TESTING='BaileyUITests/SharedTreeUITests/testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt BaileyUITests/GitChangesUITests/testRightClickAnotherGitChangeMovesKeyboardCursorWithoutOpeningDiff BaileyUITests/GitGraphUITests/testRightClickDifferentCommitMovesGraphKeyboardCursorWithoutOpeningHistory BaileyUITests/WorkspaceDockUITests/testRightClickFileTabAndCommandWCloseTheSameFile'`，
  并纳入 P1、P2 新增的真实菜单打开与状态叠加用例。
- Git 结果必须核对实际仓库 HEAD／index／工作树，
  文件结果核对原始字节、剪贴板、文件身份，
  GUI 核对实际菜单、高亮、焦点、当前展示和剩余标签。
- 全程只操作隔离 Bailey Dev 与临时项目；不借用
  正式 Bailey 进程、用户 SSH master 或真实仓库进行破坏性测试。

---

## Phase Gate

所有适用的文件树、Git、Dock 行都按清楚且唯一的状态绘制；
菜单打开时快捷键实际执行，取消／失焦／跨窗不错误执行；
新旧双轨、虚假快捷键提示、互斥背景和不必要补丁已清理。

所有已识别且可安全执行的条件与组合已按项目规范验证；
无法实测的系统／远端条件有逐项缺口和补验依据。
未取得真实 GUI 菜单键盘与视觉结果，不给无保留 Go。
