# P2：Files 选择语义与共享树行视觉

**Goal：** 以 VS Code Explorer 的 Focus、Selection、Hover、活动／非活动视觉规则为准，
分离 Files 的键盘游标、选中集合和菜单操作目标；保留 Bailey 现有浏览、打开与原生焦点边界。

**Non-goals：** 不给 Git Graph 添加 Files 式多选；
不更改 Git 操作、图谱拓扑、文件单击／双击和拖放后端。

**Approach：** 以 `FileTreeModel.selectedPath`（游标）、
`selectedPaths`（显式选中）、`selectedCompactPath`（紧凑段）、
`selectionAnchorPath`（范围锚点）为唯一状态来源。
优先用现有字段计算命令目标，**不预建另一份 context selection Store**。
共享视觉只改 `TreeRowSurface` 和必要调用参数，
不依赖后台窗口的焦点标志决定数据状态。

**实施前基线：** Git Graph 早已将蓝色细描边与灰色 Diff 背景分开：
`RecentCommitsView.isFocusedRow()` 传 `TreeRowSurface.focusRing`，
文件 Diff 的展示状态原由 `selected` 决定，P2-T2 已改名 `displayed`；
它并非缺少“仅蓝框”的组件。
但其 `selectRow()` 会在活动时 `keyboardOwner.focus()`，
因此不能直接把 Git Graph 的右键聚焦策略复制给 Terminal 活动时的 Files。

**VS Code 源码基线（microsoft/vscode `c5f99e8`）：**
- `src/vs/base/browser/ui/list/listWidget.ts`：`KeyboardController.onUpArrow/onDownArrow`
  只移动 Focus 和 Anchor；`onEnter` 才显式把 Focus 变为 Selection，`onEscape`
  清除 Selection 而不清除 Focus；`MouseController.onContextMenu` 移动 Focus，
  普通左键更新 Selection，macOS ⌘ 点击切换单项、Shift 点击扩展范围。
- `src/vs/workbench/contrib/files/browser/views/explorerView.ts`：Explorer 右键未选中项
  调用 `setSelection([stat])`，已在 Selection 内则保留整组。`getContext(true)`
  在 Selection 超过一项时无条件采用整个 Selection，即使 Focus 指向集合外；
  无多选时使用 Focus 决定操作目标。已打开编辑器的自动定位可同时设置
  Focus 与 Selection，但它们不是同一状态。
- `listWidget.ts` 的 `DefaultStyleController` 与
  `src/vs/platform/theme/browser/defaultStyles.ts`：独立绘制 Focus、Selection、
  Focus+Selection、Hover、失焦 Selection，以及菜单期间最后聚焦行的边框。
  不把正在展示的编辑器文件、AX Selection 和键盘 Focus 混作一份数据。

**Acceptance：** 选中 A → 普通 ↓ 聚焦 B，A 的 Selection 保留，B 仅移动 Focus；
右键多选 A/C 内部保留 A/C，右键外部 B 改为仅选 B；
Esc 在 Files 焦点下清空 Selection 而保留焦点游标。活动／失焦背景、
单独焦点轮廓、Hover 及菜单期右键轮廓与 VS Code 列表语义对齐；
菜单命令准确操作右键集合，Git 和 Dock 的原有业务功能不倒退。

**前置：** 复用 P1 已实现的菜单目标与动作派发，不为 P2 视觉状态再造键盘入口。
P1 菜单 ⌘C 蜂鸣与瞬时高亮按用户要求暂停，不冒充已核销，也不阻断 P2 独立审查。

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
  `selectForContextMenu(_:)`、`contextMenuPath`、
  `rowMenu(for:)` 的 `matchesKeyboardSelection`／`matchesNewItemTarget`
- `BaileyTests/Files/FileTreeTests.swift`、
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`

**代码事实：**
`6fe42c8` 已在 P1 的必要前置工作中调整 `selectForContextMenu`：
P1 已实现独立的键盘焦点、右键上下文与原生焦点边界；本阶段继续
对齐 VS Code 的持久 Selection：右键集合外会改为单选，方向键则不改选中集合。
`selectedOperationPaths` 对多选集合优先、单选时 Focus 优先的取舍来自
上游 `getContext(true)`，不能仅依据“游标不在集合内”判断目标。
P2-T1 必须维护已有的右键隔离，不再引回原始耦合。

**Red → Green → Refactor：**
1. 在宿主先断言四条不同语义：
   - 左键选 A → ↓ 到 B：A 保留于 `selectedPaths`，
     `selectedPath == B`。
   - A/C 仍选中时右键 A：保留 A/C；右键集合外 B：Selection 变为 B，
     Focus 指向 B，菜单有效时 Copy B；菜单 Esc 不撤销已确定的 Selection。
     Terminal／Editor 持有焦点时菜单关闭后恢复其原生输入，
     不能让保存的蓝框决定快捷键所有者。
   - 选中集合 A/C 时即使 Focus 在集合外 B，Copy/Cut/Trash 仍用 A/C；
     单选 A 且 Focus B（集合外）才改用 B；无 Selection、仅 Focus B 时
     以 B 为命令目标，但不虚构 B 的选中背景／AX 标记。
   - Shift+↑/↓ 按 Anchor 扩选，⌘点击精确增删；
     Escape 关闭菜单后在 Files 焦点下清空 Selection，但保留 Focus。
   - AX `isSelected` 只对应实际 Selection：A 选中且 AX 已选中，
     B 仅为 Focus 时不能被误报为已选中；右键集合外 B 后则相反。
2. 只在现有模型区分“游标移动”和“显式改选”。
   将系统 Edit 命令的操作集合由当前有效 Focus 与 Selection 推导；
   即使 Selection 为空也应允许有效 Focus 的命令，且不隐式恢复背景。
   右键菜单仍通过 `contextSelection(for:)` 精确取目标；
   右键集合外按 VS Code 改选，不能维护第二份可写菜单选择。
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
   `testContextSelectionPreservesSelectedGroupButReplacesOutsideSelectionLikeVSCode`。
   同步修订现有 Files／SharedTree GUI 中
   “右键集合外 C 必须保留 A/B AX 已选中”的旧断言：
   右键 C 后只选中 C；再次主动多选 A/B 后右键 A 保留整组；
   菜单 Copy Path 和 Esc 后的命令目标均对应真实 Selection。
   保留显式取消后不自动重新选中的现有回归。
   若一个状态不必持久化，就不要新增可观察存储。
5. 同时更新 `docs/features/files.md` 中键盘、
   多选、右键、失效和撤销的行为描述；
   `docs/ui.md` 的详细颜色规则仍由 P2-T2 维护。

**验证：**
- `make test:FileTreeTests,PanelContextTests`。
- P2-T1 审计补查：压缩目录真实组件右键改选与 Esc 取消拖动 token 的两项 Red→Green
  由 `26a2648` 修复；不得把“同一压缩行”误当“同一实际目录”。
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

**实施前的代码事实：**
共享行原来用 `multiSelected ? accent.opacity(0.14)`
画出浅强调色背景；参数 `selected` 在 Files／Git 中主要表达
**当前显示的文件或 Diff**，命名与 VS Code 的 Selection 不同。
P2-T2 应重命名误导的参数并对照上面的 `listWidget.ts` 样式优先级，
不强行把当前展示的内容染成选中背景。
现有 `multiSelected → selected → hovering` 三选一背景
使某些同时成立的事实被遮住。
`6fe42c8` 在 P1 中只给既有 stroke 增加菜单期 `contextRing` 输入，
并抑制未选中菜单目标的 Hover 灰底；**没有新增蓝框绘制组件**。
完整 P2-T2 仍要核对四态 A/B/C/D、普通导航、明暗主题、无障碍与像素，
不能将本次部分 UI 改动视为阶段完成。
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
   选中底色由 Selection 决定，活动／失焦有区分；Hover 只作用于
   未选中且未聚焦的普通行；Focus（包含菜单期间）有单独轮廓，
   Focus+Selection 取 VS Code 的组合样式。Bailey 当前显示文件的提示
   可保留为弱提示，但不得取代 Selection 或与 Hover 混淆。
   **同一行不能同时显示两个互斥的纯色底**：显式选中蓝底优先，
   当前展示灰底这一事实仍保留；该行取消选中后重新显示灰底。
   Hover 仅在不会遮盖更明确的背景时变灰；描边独立叠加，
   必须检查文本与 Git 状态颜色在所有重叠组合下可辨认。
   直接复用 Git Graph 已在用的 `TreeRowSurface.focusRing` 对应
   stroke 与 `Theme.terminal(dark:)` 颜色、行几何；
   `contextRing` 只表达菜单上下文且使用同一笔画，不建立第二套描边。
   若后续能进一步简化传参，必须保留“菜单上下文不等于原生焦点”的语义；
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
- P2-T2 审计由 `bcbe14e` 完整清理 Files `isMultiSelected` 与 Git Entry
  `selected` 的错误命名，现有像素测试核对 Focus+Selection、Displayed+Selection
  与菜单上下文轮廓重叠，无生产旧参数兼容分支。
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
1. 以 Git Graph 已有的“单独蓝框”作为基线，
   检查共享树行对 Git Changes／Graph／历史文件的调用，
   核对提交展开、Diff 显示灰底、Stash／Worktree 标签，
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
- P2-T3 审计由 `f43c0b5` 补充真实临时文件与命名剪贴板的多选
  Copy/Cut/Paste 完成结果；`ae672d1` 同步 SSH 同根重连时保留可信选择的文档与回归。
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
真实 GUI 中受 P2 影响的 Selection 背景、Focus／右键轮廓、
Git／Dock／Projects 操作目标及未保存保护均按适用范围验收。
P1 菜单蜂鸣和瞬时按压高亮按用户要求暂停，不混入 P2 完成判定；
但 P2 不能以此跳过自己修改过的菜单和焦点回归。

任一任务中被替代的旧代码、重复快捷键入口、
无效状态恢复分支和过时测试均在**所属任务内**清理；
不得将遗留问题集中推给最后一个 task。
不能实测的环境有清楚的限制及补验方式，
不把宿主绿色、构建或菜单右侧提示当作完整 E2E Go。
