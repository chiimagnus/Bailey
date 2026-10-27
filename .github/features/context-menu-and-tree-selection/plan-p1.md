# P1：菜单跟踪中的快捷键与执行反馈

**Goal：** 菜单展开时按键与鼠标执行同一动作、同一有效目标；
Terminal／Editor 保留真正的输入焦点，菜单撤销后恢复它们的命令语义。
Dock ⌘W 的现有正确关闭行为不得倒退，并验证原生菜单反馈。

**Non-goals：** 不重构整个焦点架构；不改 Git 图谱及全局 Dock 布局。
右键菜单不得修改 Files 的显式选中集合或抢走 Terminal 原生焦点，
这是 P1 菜单目标正确性必需的前置条件；其它方向键／Shift 选择语义仍由 P2 完成。

**Approach：** 命令目标不能由 Dock 活动状态或树行 Focus 反向推导。
原生第一响应者继续负责普通编辑输入；菜单生效时，窗口的明确菜单上下文
优先指定本次文件操作目标。复用 `WorkspaceWindowModel.performFileTreeCommand`
的项目／SSH 身份保护，而非再造复制实现。
先在真实 AppKit 菜单跟踪中证明事件所有者，再选单一原生命令入口；
禁用覆盖 SwiftUI 自有菜单 delegate、定时轮询和新的全局键盘监听。

**Acceptance：** 菜单展开时按键准确执行一次；鼠标与键盘同目标；
失效／跨窗不可误操作；Dock 原生执行反馈得到实证。

**Rules：** 优先遵守 `AGENTS.md` 中主菜单唯一快捷键、原生第一响应者、
窗口有效身份、测试隔离及未保存保护。用户已明确授权架构重构；
若原生平台证实必须由菜单跟踪范围参与键等价处理，
只允许共享同一命令动作、同一目标解析与启用条件的最小改动，
并在所属任务同步修订冲突规范、删除旧显示-only 断言；
严禁主菜单与菜单跟踪时同时执行两次。

---

## P1-T1 确认原生菜单事件链

**源码锚点：**
- `Bailey/Files/FileTreePanel.swift`：
  `FileTreeRow.rowMenu(for:)`、`selectForContextMenu(_:)`、
  `FileTreeScrollView.performEdit(_:)`
- `Bailey/Shared/Tree/TreeRowStyle.swift`：
  `TreeContextClickView.hitTest(_:)`／`menu(for:)`、
  `TreeKeyboardView.copy(_:)`／`validateMenuItem(_:)`
- `Bailey/App/FinderService.swift`：
  `mainMenuItemAdded(_:)`／`formatShortcutHints(in:)`
- `Bailey/App/BaileyApp.swift`：系统 Edit／Panel 菜单
- 既有 `BaileyTests/App/AppIdentityTests.swift` 之
  `testContextMenuShortcutHintsAreDisplayOnly`；
  `BaileyUITests/Files/SharedTreeUITests.swift` 之
  `testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt`

**已知事实：**
Git Graph 在本 Feature 前就通过 `TreeRowSurface.focusRing` 独立显示蓝色边框，
只是它的 `selectRow()` 仍会主动聚焦 Git 树；Files 不可复制这种右键抢焦点动作。
右键菜单的 `Text("Copy\t⌘C")` 仅展示提示，
现有测试要求 `NSMenuItem.keyEquivalent` 为空。
文件树经 `TreeKeyboardView` 作为第一响应者处理系统 Edit，
鼠标菜单通过 `onCommand` 直接执行操作。
现有 UI 用例先 Escape 才按 ⌘C，不能证明菜单跟踪期间的命令。
此外，多处 Files／Git／Projects 依赖
`TreeContextClickView.menu(for:)` 更新右键游标；
先确认此回调在实际 SwiftUI `.contextMenu` 下是否触发，
不能假设它与 Dock 已修复的路径行为相同。

**步骤与可观察结果：**
1. 使用现有 `WorkspaceUITestFixture` 和隔离 Bailey Dev：
   Files 活动时右键 B、Terminal／Editor 活动时右键**仍可见**的 Files B，
   分别确认菜单仍展开并按 ⌘C；对照鼠标 Copy、Esc 取消后再按 ⌘C。
   检查菜单仍开时写入 `FileTreeClipboard.Record.paths` 与真实剪贴板；
   Esc 后 Terminal／Editor 仍按自己的原生 Copy 处理，Files 真实聚焦时
   仍复制其游标目标。测试必须核对点击目标和前台实际第一响应者。
2. 用既有 `AppIdentityTests` 的 `NSHostingMenu` 核对 action、
   `keyEquivalent`、SwiftUI 菜单 delegate 及跟踪生命周期；
   在真实 App 区分：`⌘C` 是否被菜单吞掉、是否到达 Edit 命令、
   是否找到 `TreeKeyboardView` 却被 `firstResponder` 检查拒绝。
   对照 `⌘W` 走主菜单关闭动作但不依赖第一响应者的完整调用链。
   只做诊断用的事件记录，验证完立即清理，不覆写 SwiftUI delegate。
3. 同样观察 Dock 右键 B → 菜单仍展开 → ⌘W，
   区分“实际关闭正确目标”与“菜单项真的显示被激活的反馈”。
   对照 Apple `NSMenu.performKeyEquivalent(with:)` 和
   菜单键等价处理契约，不能靠文字提示推断可执行。
4. 明确已验证的单一命令解析顺序：有效菜单上下文 → 本次菜单动作；
   菜单不在跟踪时 → 系统第一响应者。明确菜单结束／取消、
   切窗／切项目、断连、菜单目标被删除时的失效与回退。
   不把 FileTree 选中集合作为菜单上下文的替代品；
   不让 Terminal／Editor 被强制切焦点。
   已试过把 SwiftUI 右键菜单换成 `NSHostingMenu`，
   并给 `Button` 增加 `.keyboardShortcut`：真实菜单项虽有
   `keyEquivalent = c`，GUI 中按 ⌘C 仍没有复制右键目标。
   此方案已经撤销，不应重试或当作已完成。
   早期三项 GUI Red 证据保存在本地 `evidence-p1-menu-shortcut-red.patch`；
   后续已确证 `NSMenu.performKeyEquivalent(with:)` 返回 false，
   `performActionForItem(at:)` 能执行原有 SwiftUI Copy 菜单动作，
   再以 `cancelTracking()` 结束菜单跟踪。
   修复已提交 `8742a09`，英文／中文隔离 Bailey Dev 菜单键盘 E2E
   各通过，原文件操作后端收到右键 B；全部临时监听诊断／后端旁路已删除。
   真实系统剪贴板测试因当前剪贴板存在无法无损备份的富类型而跳过，
   不能将该跳过算作最终真实 Copy 验收。

**验证：** 真实菜单打开且真实 ⌘C 发生后，
检查正确剪贴板路径和完整命令退出状态；
对照英文／中文 UI、单项／多项／禁用项、
本机文件与目录；不依赖猜测提示音来源。
探索任务只保留可复用测试及结论，删除临时日志与试验代码；
不为此新增永久菜单管理器或新的测试框架。

## P1-T2 让 Files 菜单与 Edit 快捷键共用文件命令

**源码锚点：**
- `Bailey/Files/FileTreePanel.swift`：
  `rowMenu(for:)`、`canPerformEdit(_:)`／`performEdit(_:)`
- `Bailey/Files/FileTreeModel.swift`：
  `contextSelection(for:)`、`selectedOperationPaths`
- `Bailey/UI/Panels/ToolPanelView.swift`：
  `FileTreePanel.onCommand`／`isCurrentTarget`
- `Bailey/Workspace/WorkspaceWindowModel.swift`：
  `performFileTreeCommand(_:in:target:pasteboard:onChange:)`、
  `canPasteFileTree(in:target:pasteboard:)`
- 仅在 T1 已证明必要时修改 `TreeRowStyle.swift`、
  `BaileyApp.swift`、`FinderService.swift`

**要修的链：**
鼠标菜单目前在 `rowMenu` 取右键集合，系统 Edit 从
`TreeKeyboardView` 读取 `selectedOperationPaths`，两者只有选中状态间接相连。
修复后，菜单有效时鼠标与快捷键以同一个快照目标执行；
无菜单时 Edit 保持原生第一响应者语义。
跨组件仅由所属 `WorkspaceWindowModel` 协调菜单命令范围；
项目和连接保护继续复用现有 `performFileTreeCommand`，不能另写复制后端。

**Red → Green → Refactor：**
1. 真正“Terminal／Editor 活动，右键可见 Files B，菜单保持展开，⌘C”
   的 E2E Red 必须先触发；补 Files 聚焦时菜单打开的 Red。
   对照鼠标 Copy、Esc 后 Terminal／Editor ⌘C 仍保留原生目标、
   Esc 后 Files 聚焦 Copy B 的既有回归，验证剪贴板真实私有类型。
2. 在 `WorkspaceWindowModel` 的现有窗口归属边界协调有效菜单目标，
   Files 仍保留行选择与紧凑段细节。右键仅提供本次菜单目标和命令，
   **不调用 `focusKeyboard()` 抢走 Terminal／Editor**，不通过
   `FileTreeModel.select()` 重新写 `selectedPaths`。
   菜单本次路径和显式选中集合的关系由 `contextSelection(for:)` 计算；
   右键目标应在菜单跟踪时显示独立的细边框，关闭后撤销。
   描边直接复用 Git Graph 已有的 `TreeRowSurface` 同一条 stroke；
   P1 的 `contextRing` 只是独立的菜单状态输入，不是新的边框绘制器。
   中性 B 不能因为 Hover 或右键出现选中蓝底，既有显式选择 A 保留。
   必须同步改掉旧宿主／AX 测试里“右键 B 应清除 A 选中”的断言。
   使用 T1 已证实的原生菜单派发方式，主菜单／菜单按钮调用同一命令动作；
   菜单结束后立即不再覆盖第一响应者。
   不在 `onKeyDown` 逐个拦截 Command 组合，不引入全局 FocusManager。
3. 保留 `FileTreeClipboard` token、项目和 SSH connectionRevision、
   真实文件操作与远端删除 Sheet。Cut／Copy／Paste／Delete、
   新建文件／文件夹与复制路径各自使用同一窗口菜单上下文。
   保留编辑器、Terminal、Git 输入框、Sheet 的原生 Edit 命令；
   跨窗口菜单目标和过期身份不能覆盖当前真实键盘输入。
4. **本任务立即删除**以 `listFocused` 和选中集合等价为由
   隐藏可执行 `⌘C` 的旧提示条件、替代的焦点抢占逻辑与过时测试断言。
   既有桥接也被 Git／Projects 使用；P1-T3 在核对后统一更名为
   `ContextMenuClickTarget`，未删除它们的右键命中路径。
5. 在同一任务更新 `docs/ui.md` 与 `docs/features/files.md`
   的菜单优先级、焦点和目标生命周期契约。若 T1 实验确证原生菜单
   必须配备独立键等价入口，立即把 `AGENTS.md` 的绝对禁令
   收敛为“唯一命令动作，作用域内单次派发”，并更新对应宿主测试；
   不留显示-only 旧规范与真实产品行为相矛盾。

**验证：**
- 宿主：`make test:FileTreeTests,AppIdentityTests,WindowOwnershipIntegrationTests`，
  证明菜单 action、可用性、命令目标及剪贴板／文件身份。
- UI：新增 Terminal／Editor 活动且可见 Files 时菜单展开 ⌘C、
  Esc 后输入焦点回归；定点运行 `WorkspaceFilesUITests` 的
  `testFocusedFilesKeyboardCopyPasteAndEditorCopyIsolation`、
  `testSystemEditMenuCopyPasteFollowsFileManagerFocus`；
  以及 `SharedTreeUITests` 的右键目标用例和本 task 新增
  “菜单仍开 → ⌘C／⌘X／⌘V”用例。
- 视觉与焦点：Terminal／Editor 为第一响应者时，右键未选 B 只有菜单上下文细边框，
  B 不获得选中蓝底、AX `.isSelected` 或独立 Hover 灰底；A 旧蓝底保持。
  整棵 Files 树只允许一个当前右键蓝框，切换目标立即替换旧蓝框，
  菜单期间隐藏原键盘游标蓝框；菜单 Esc／点击后上下文边框消失，
  Terminal／Editor 焦点仍有效；
  明暗、紧凑段和 Git 共享行不倒退。
- 真实副作用：鼠标／键盘路径的私有剪贴板记录相同；
  Copy 不覆盖原件，Cut 延迟移动，Paste 保留原有重名／拒写规则；
  Editor／输入框／Palette／后台窗口不发生错误复制；
  菜单取消、禁用、过期对象／项目切换不能重放命令。
- `6fe42c8` 已为本任务提前落地必要的 P2 子集：保留显式选择、
  游标与右键菜单描边分离、Terminal 焦点回归；不代表 P1 菜单按键已完成。
  P2 继续接管普通方向键、选中范围、蓝／灰背景组合与完整视觉／AX 验收。
- P2 改变操作目标模型后，须重测这里的命令入口，
  **不再建立第二套投递实现**。

**2026-10-27 补验：** `a6ee864` 补齐右键命中时机与菜单内新建测试；
`19547bc` 将 Files 的右键描边收敛为树模型唯一目标，并防止旧菜单关闭误清新目标。
宿主 Files／AppIdentity／WindowOwnership 106/106 通过，追加跨机器重置断言后
Files 80/80 通过；连续右键、菜单内新建文件／文件夹、Dock 两种 ⌘W 的
隔离 Bailey Dev GUI 联合 4/4 通过，`make build` 与签名验证通过。
仍未核销的条件：系统富类型剪贴板的真实 Copy/Cut/Paste、
Delete 废纸篓副作用、双窗口与真实 SSH 失效组合；不能因此宣称 P1-T2 完成。

**菜单提示音补查：** 隔离 Bailey Dev 的 `NSBeep` 调用栈确认：Files 菜单内
`⌘C` 的 Copy 已执行，但系统 `NSMenuTrackingSession` 仍将按键识别为无效并响提示音。
`0dd22f2` 用 AppKit selector 替换了 Sendable 闭包通知，消除了共享桥接的 17 条 Swift
并发警告；宿主 88/88、隔离菜单内新建与 Dock 关闭 E2E 2/2、`make build` 均通过。
改变 `cancelTracking` 时机、临时注册原生按键等价项的实验已撤销，
未能形成无蜂鸣且焦点/单次执行均通过的证据。
终端输入 E2E 曾出现 XCUITest 丢首字符、旧 AX 菜单对象误报存在等问题，
必须独立厘清，不能把测试误判当作菜单本身的失败或成功。
系统蜂鸣仍为 P1-T2 的未解决缺陷，详见 `audit-p1.md` F-05。

## P1-T3 验证并修复 Dock ⌘W 的菜单反馈

**源码锚点：**
- `Bailey/UI/WorkspaceDockView.swift`：
  Dock 工具与文件标签的 `.contextMenu`、
  `DockGroupFocusView` 右键命中
- `Bailey/Workspace/DockWorkspaceModel.swift`：
  `contextTarget`／`closeTarget`
- `Bailey/Workspace/WorkspaceWindowModel.swift`：
  `closeActivePanelOrWindow()`／`closePanel(_:in:)`
- `Bailey/App/BaileyApp.swift`：唯一 Panel → Close Panel ⌘W

**步骤：**
1. 使用已存在的三文件 E2E 和菜单跟踪实验，
   Red 验证“右键 B → 菜单仍开 → ⌘W”
   与鼠标点击 Close 的目标、菜单高亮、退出过程不同在哪里。
2. 只修本次确证的原生命令反馈缺口，
   共享既有关闭入口与 `closeTarget`；
   不改动已经通过的右键命中／焦点切换和保护机制。
   若原生菜单无法提供预期按压反馈，先留下可重复证据，
   不用虚假的鼠标模拟或异步动画绕过要求。
3. **同任务**清理确证冗余的按钮动作／快捷键提示路径，
   不把 Dock 正常的关闭行为认定为重复执行。
   更新 `docs/features/dock.md`；
   不把此清理放到 P2 最后。
4. 验证工具 Files／Git／Projects、文件标签 A/B/C、
   后台标签、空组、跨窗口、连续 ⌘W、菜单 Esc、
   保存失败和终端未关闭；每次关闭恰有一个合法目标。

**已执行：** `e31c9a8` 让菜单展开期间的 ⌘W 调用本次已启用的
Close／Close Panel 原生菜单动作，然后结束菜单跟踪；不向右键菜单重复注册快捷键。
工具面板和非活动文件标签的两条真实 GUI E2E 复跑均通过（2/2），
宿主 Dock／窗口／AppIdentity 50/50 通过，UI Test Target 构建通过。
用户已手动确认菜单中 ⌘W 可关闭目标，但没有显示原生瞬时按压高亮。
这是实际未达到的视觉要求，不再记成单纯缺少截图证据；
不通过模拟鼠标或额外动画掩盖。

**验证：**
- 宿主：`make test:DockWorkspaceTests,WindowCloseIntegrationTests,AppIdentityTests`
- UI：`make test:ui ONLY_TESTING='BaileyUITests/WorkspaceDockUITests/testRightClickFileTabAndCommandWCloseTheSameFile BaileyUITests/WorkspaceDockUITests/testRightClickInactiveFileTabClosesOnlyThatTab BaileyUITests/WorkspaceDockUITests/testCommandPaletteClosePanelUsesTheActiveTool'`
  并补菜单展开期间的真实键盘及原生反馈检查。
  用户已在真实 GUI 中确认未出现瞬时高亮；如果修改原生反馈实现，
  须在独立图形会话重新观察，并证明一次按键只执行一次关闭动作。

---

## P1 Gate

P1-T1 原生结论与规范边界已证实，P1-T2 的真菜单快捷键
和 P1-T3 的 Dock 反馈均具有实际 App 证据；
宿主结果不冒充 GUI 菜单结果。
每项完成时即清除被替代的本地旧分支、测试与过期文档。
只有既有唯一快捷键归属、窗口／保存保护与用户交互全部满足，
才可进入 P2。
