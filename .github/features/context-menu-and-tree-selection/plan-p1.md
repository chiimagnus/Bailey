# P1：菜单跟踪中的快捷键与执行反馈

**Goal：** 菜单展开时，键盘和鼠标执行同一项动作、同一目标；
Dock 的 ⌘W 正确关闭并有可观察的原生菜单反馈。

**Non-goals：** 不重构完整焦点架构；不提前修改 Files 的持久选中语义。
P2 负责游标／选中分离，届时复用本阶段的命令入口。

**Approach：** 从真实 App 复现出发，
沿 `NSMenu` → 原生响应者／系统主菜单 → Files／Dock 命令
追到剪贴板和窗口最终结果；优先现有 AppKit 与 SwiftUI 能力。
决策依赖真实菜单跟踪实验，不预先规定新 `keyEquivalent` 或事件拦截。

**Acceptance：** 菜单展开时按键准确执行一次；鼠标与键盘同目标；
失效／跨窗不可误操作；Dock 原生执行反馈得到实证。

**Rules：** 严格遵守 `AGENTS.md` 中应用命令仅在主菜单注册、
右键菜单不额外注册／拦截快捷键、原生第一响应者、测试隔离、
未保存数据保护。若平台证据证明这些约束与需求不能同时满足，
记录具体冲突并保持本任务阻塞；不得通过改写规范为双轨开绿灯。

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
   A 处于活动状态，右键 B，确认菜单仍展开；按 ⌘C；
   对照鼠标 Copy、Escape 后 ⌘C，分别核对
   `FileTreeClipboard.Record.paths`、系统剪贴板文本和打开的文件标签。
2. 用既有 `AppIdentityTests` 的 `NSHostingMenu` 宿主条件
   核对 `NSMenuItem` 的 action、`keyEquivalent` 和菜单委托行为；
   真实 App 中核对菜单跟踪开始／结束、窗口和第一响应者归属，
   以及 `TreeContextClickView` 回调是否可靠。
   只有宿主不足以回答的问题才加最小临时原生实验。
3. 同样观察 Dock 右键 B → 菜单仍展开 → ⌘W，
   区分“实际关闭正确目标”与“菜单项真的显示被激活的反馈”。
   对照 Apple `NSMenu.performKeyEquivalent(with:)` 和
   菜单键等价处理契约，不能靠文字提示推断可执行。
4. 在本 plan 的下一 task 决策说明中明确：
   唯一命令拥有者、菜单有效期、键盘和鼠标共用的动作入口、
   目标失效时如何拒绝，以及何时清理无效右键回调。
   原生方案必须满足当前 `AGENTS.md`，不能用“临时重复注册”
   或局部事件拦截伪装为唯一命令入口；
   无法满足时注明阻塞原因，未解决不得进入 P1-T2。

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
鼠标菜单在 `rowMenu` 决定文件集合，
系统 Edit 从 `TreeKeyboardView` 读取当前操作集合；
最后均通过 `WorkspaceWindowModel.performFileTreeCommand`
写入剪贴板或真实文件操作。
必须在拥有目标的现有组件汇聚，不能新建一条绕过
项目／连接校验的菜单命令链。

**Red → Green → Refactor：**
1. 新增真正“右键 B、菜单保持打开、⌘C”的 E2E Red，
   同时验证鼠标菜单和 Escape 后 ⌘C 的 B 路径，
   以及原本正常的编辑器 Copy 不受干扰。
2. 按 T1 证实的原生菜单方案，仅在需要的
   `NSMenu`／`TreeKeyboardView` 层实现同一目标解析和命令投递，
   让显示的快捷键与实际菜单启用条件一致。
   不在 `onKeyDown` 为每个 Command 键写一组手工分支。
3. 保留现有 `FileTreeClipboard`、目标 token、
   SSH connectionRevision、实际文件操作和远端删除 Sheet。
   对 Cut、Paste、Delete、New File／Folder 检查已有系统主菜单
   是否确有快捷键；没有的不虚构提示或键绑定。
4. **本任务立即删除**被替代的旧菜单显示／命中路径、
   无效匹配检查及对应过时测试断言。
   `TreeContextClickTarget` 若仍为 Git／Projects 使用，
   先核对对应事件链，不为清理 Files 而盲删整个共享类型。
5. 在同一任务更新 `docs/ui.md` 与 `docs/features/files.md`
   的真实菜单／焦点契约；保持 `AGENTS.md` 现有唯一快捷键规则。
   若平台无法在此规则下完成用户需求，应按 P1-T1 的阻塞结论收敛，
   不擅自放宽长期规范或保留互相冲突的两套规则。

**验证：**
- 宿主：`make test:FileTreeTests,AppIdentityTests,WindowOwnershipIntegrationTests`，
  证明菜单 action、可用性、命令目标及剪贴板／文件身份。
- UI：定点运行 `WorkspaceFilesUITests` 的
  `testFocusedFilesKeyboardCopyPasteAndEditorCopyIsolation`、
  `testSystemEditMenuCopyPasteFollowsFileManagerFocus`；
  以及 `SharedTreeUITests` 的右键目标用例和本 task 新增
  “菜单仍开 → ⌘C／⌘X／⌘V”用例。
- 真实副作用：鼠标／键盘路径的私有剪贴板记录相同；
  Copy 不覆盖原件，Cut 延迟移动，Paste 保留原有重名／拒写规则；
  Editor／输入框／Palette／后台窗口不发生错误复制；
  菜单取消、禁用、过期对象／项目切换不能重放命令。
- 本任务的视觉暂按现行选中规则；P2 改变操作目标模型后，
  须重测这里的命令入口，**不再建立第二套投递实现**。

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
3. **同任务**清理替代的重复按钮动作／快捷键提示路径
   （存在且有实证时），更新 `docs/features/dock.md`；
   不把此清理放到 P2 最后。
4. 验证工具 Files／Git／Projects、文件标签 A/B/C、
   后台标签、空组、跨窗口、连续 ⌘W、菜单 Esc、
   保存失败和终端未关闭；每次关闭恰有一个合法目标。

**验证：**
- 宿主：`make test:DockWorkspaceTests,WindowCloseIntegrationTests,AppIdentityTests`
- UI：`make test:ui ONLY_TESTING='BaileyUITests/WorkspaceDockUITests/testRightClickFileTabAndCommandWCloseTheSameFile BaileyUITests/WorkspaceDockUITests/testRightClickInactiveFileTabClosesOnlyThatTab BaileyUITests/WorkspaceDockUITests/testCommandPaletteClosePanelUsesTheActiveTool'`
  并补菜单展开期间的真实键盘及原生反馈检查。
  瞬时高亮若 XCUI 无法稳定截取，须在独立图形会话进行
  可复验的原生／人工观察；不能仅由最终关闭成功推断高亮已发生。

---

## P1 Gate

P1-T1 原生结论与规范边界已证实，P1-T2 的真菜单快捷键
和 P1-T3 的 Dock 反馈均具有实际 App 证据；
宿主结果不冒充 GUI 菜单结果。
每项完成时即清除被替代的本地旧分支、测试与过期文档。
只有既有唯一快捷键归属、窗口／保存保护与用户交互全部满足，
才可进入 P2。
