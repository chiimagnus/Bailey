# P1：菜单打开期间的快捷键与命令反馈

**目标：** 鼠标点菜单项和菜单保持打开时按实际快捷键，
作用于同一窗口、同一文件／面板，并呈现可观察的原生反馈。

**非目标：** 本阶段不改变 Files 持久选中背景、方向键语义或 Git 的展示状态；
这些属于 P2。

**实现原则：** 先证明 AppKit 对 SwiftUI `contextMenu`、`NSHostingMenu`
和系统主菜单快捷键的真实处理顺序，再选唯一的命令入口。
若实验推翻现有假设，先修正本计划，不制造第二套事件监听。
复用现有 `TreeKeyboardView` 和窗口关闭路由，不新建全局管理器。

**完成条件：** 菜单打开时按键不发出无效提示音、不执行两次、
不作用于旧文件／后台窗口；鼠标和快捷键最终结果一致；
Dock 的反馈在真实 App 中可见且不误关任何标签。

**遵守：** 仓库 `AGENTS.md` 的快捷键唯一所有者、窗口归属、
数据保护和 Dev App 测试隔离；若实测平台限制确实需要调整快捷键规范，
须在同一 task 用事实说明并同步对应规范，不能先违反再补文档。

---

## P1-T1 复现并确认原生菜单事件链

**涉及位置：**
- `Bailey/Files/FileTreePanel.swift`：`FileTreeRow.rowMenu(for:)`、
  `selectForContextMenu(_:)`、`focusKeyboard()`
- `Bailey/Shared/Tree/TreeRowStyle.swift`：`TreeContextClickView.menu(for:)`、
  `TreeKeyboardView.copy(_:)`、`validateMenuItem(_:)`
- `Bailey/App/FinderService.swift`：`formatShortcutHints(in:)`
- `Bailey/App/BaileyApp.swift`：系统 Edit／Panel 命令
- `BaileyUITests/Files/WorkspaceFilesUITests.swift`、
  `BaileyUITests/Files/SharedTreeUITests.swift`、
  `BaileyUITests/Workspace/WorkspaceDockUITests.swift`

**事实与未证实部分：**
- 已知：右键 Copy 使用仅供显示的 `\t⌘C`；
  `AppIdentityTests.testContextMenuShortcutHintsAreDisplayOnly`
  明确验证 `keyEquivalent` 为空。
- 已知：现有 `SharedTreeUITests.testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt`
  先按 Escape 才按 ⌘C，无法证明菜单打开期间的行为。
- 待验证：真实菜单打开后，事件由哪层消费、主菜单是否还处理
  `keyEquivalent`、`firstResponder` 是否保持 Files、
  菜单点击与键盘触发的高亮反馈由谁绘制。
  “提示音来自菜单拦截”是待验证机制，不预设已证明。

**步骤：**
1. 在隔离 Bailey Dev、真实本机临时目录中，
   建立 A、B 文件和可见 Files 树。先选 A，右键 B，
   确认菜单确实保持打开、B 可见且没有新文件标签。
2. 不按 Escape，直接发送真实 ⌘C；核对剪贴板
   `com.chiimagnus.bailey.files.transfer` 的路径与文本、
   菜单退出方式、是否有错误／重复命令。
   分别对照鼠标 Copy，以及 Escape 后 ⌘C。
3. 使用最小 AppKit／`NSHostingMenu` 宿主实验记录
   `NSMenuItem.keyEquivalent`、菜单 action、原生响应者和
   菜单高亮的实际行为；必要时对照 Apple SDK 契约。
   同样对照 Dock 右键菜单保持打开时的 ⌘W。
4. 明确唯一可行的命令路由、菜单目标捕获时机和反馈机制；
   删除实验临时代码／日志，不保留菜单层与按键层双轨。
   若需要改变当前“只在主菜单注册”的约束，
   必须说明为何无法单入口实现及如何避免冲突。

**验收：**
- Red 只能来自真实的“菜单仍打开 + 按键”前提，不把选择器启动、
  焦点争用或未打开菜单冒充缺陷复现。
- 记录键盘和鼠标两条路径的最终剪贴板／关闭结果、
  前台窗口身份、menu／responder 事件归属。
- 条件包含单选／多选／无有效目标、输入框优先、菜单取消、
  菜单目标删除以及不同窗口；平台差异单独注明。
- 没有足够运行证据时，停止推断具体 AppKit 修复策略，
  不提前开始 P1-T2。

**文档：** 实测后只更新本计划对应的设计决策与
`docs/ui.md` 中真正需要调整的菜单契约；
原始需求仍以 `idea.md` 为准。

## P1-T2 统一 Files 菜单点击与快捷键执行

**涉及位置：**
- `Bailey/Files/FileTreePanel.swift`：`rowMenu(for:)`、
  `FileTreeScrollView.performEdit(_:)`／`canPerformEdit(_:)`
- `Bailey/Files/FileTreeModel.swift`：`contextSelection(for:)`、
  `selectedOperationPaths`（仅当目标解析需要修改）
- `Bailey/Shared/Tree/TreeRowStyle.swift`：`TreeKeyboardView`
- `Bailey/App/FinderService.swift`、`Bailey/App/BaileyApp.swift`
  （仅按 T1 的原生事件证据修改）
- `BaileyTests/Files/FileTreeTests.swift`、
  `BaileyTests/App/AppIdentityTests.swift`、
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`

**恢复的不变量：**
文件操作始终匹配当前有效的文件集合和所属窗口／项目／连接；
右键菜单打开期间的 ⌘C 与菜单 Copy 最终写入同一条
`FileTreeClipboard.Record`，不能只显示提示或复制错误的编辑器文本。

**步骤：**
1. 将 T1 可重复复现的 E2E 纳入现有用例，先获得预期 Red。
   单独复核菜单项可用性、系统 Edit 路由和 Files 原生响应者，
   而非只对 `Text("Copy\t⌘C")` 做字符串断言。
2. 在已确认的 AppKit 原生接入点统一快捷键和鼠标命令的
   目标解析与 action；确保只有一个真正的快捷键拥有者。
   删除被新路径替代的假提示、事件补丁和重复条件分支。
3. 同根因核对菜单中的 Cut／Copy／Paste／Delete、
   文件夹 New File／New Folder、系统 Edit 菜单与快捷键；
   disabled 状态、快捷键显示和真实执行保持一致。
   后端继续使用原有权限、剪贴板和确认流程。
4. 先核对宿主的命令路由和真实剪贴板，再验完整 App
   右键菜单保持打开的键鼠操作，确认无提示音／重复动作。
   本阶段沿用当前 FileTree 选择集合语义；
   P2 改变选中状态后须重跑本任务的目标断言。

**宿主与 E2E：**
- `make test:FileTreeTests,AppIdentityTests`
- `make test:ui ONLY_TESTING='BaileyUITests/WorkspaceFilesUITests/testFocusedFilesKeyboardCopyPasteAndEditorCopyIsolation BaileyUITests/WorkspaceFilesUITests/testSystemEditMenuCopyPasteFollowsFileManagerFocus BaileyUITests/SharedTreeUITests/testRightClickUnselectedFileBecomesKeyboardTargetWithoutOpeningIt'`
- 新增“菜单保持打开 → ⌘C／⌘X”等 E2E，
  实际核对剪贴板类型／路径、磁盘、编辑器文本和是否错误路由。
- 增测本机、允许的 SSH、批量选择、目录、紧凑路径、
  中文与 emoji、空与失效目标、双窗口、切项目、
  重命名输入框和命令面板。
  SSH 无法连接时必须留下实际阻塞和补验条件。

**文档：** 更新 `docs/ui.md` 的菜单快捷键规则、
`docs/features/files.md` 的右键操作语义，
以及 `docs/testing.md` 的真菜单 E2E 用例；
不把短期诊断步骤写入长期规范。

## P1-T3 Dock ⌘W 菜单反馈与关闭保护

**涉及位置：**
- `Bailey/UI/WorkspaceDockView.swift`：Dock 标签右键
  `Close Panel`／`Close` 菜单与目标描边
- `Bailey/App/BaileyApp.swift`：系统 Panel → Close Panel
- `Bailey/Workspace/DockWorkspaceModel.swift`：`closeTarget`
- `Bailey/Workspace/WorkspaceWindowModel.swift`：
  `closeActivePanelOrWindow()`／`closePanel(_:in:)`
- `BaileyUITests/Workspace/WorkspaceDockUITests.swift`、
  `BaileyTests/Workspace/DockWorkspaceTests.swift`

**恢复的不变量：**
右键非活动 B 时，菜单仍打开的 ⌘W 与点击其 Close 使用相同目标，
有一致的原生视觉反馈；当前展示 C、剩余标签、未保存编辑与窗口不受误操作。

**步骤：**
1. 复用 P1-T1 确认的 AppKit 菜单机制，
   先记录右键菜单展开时鼠标 Close、⌘W 的高亮／关闭时序。
   加真实 A／B／C E2E 的失败断言。
2. 在菜单动作的唯一入口修复反馈，保留已经通过的关闭目标模型。
   不模拟鼠标事件，不人工制造被删除按钮的按压状态，
   不重复注册全局快捷键，不新增跨窗 FocusManager。
3. 覆盖工具 Files／Git／Projects、文件标签、多窗口、
   空组、后台标签、菜单取消、重复按键，
   以及未保存文件关闭保护；确认只执行一次。
   若平台本身不显示菜单激活动画，先记录验证证据与可行原生替代，
   不声称“像点击一样”已验收。
4. 同步 `docs/features/dock.md` 的交互契约，
   删除失效的右键提示或重复菜单路由路径。

**验证：**
- `make test:DockWorkspaceTests,WindowCloseIntegrationTests,AppIdentityTests`
- `make test:ui ONLY_TESTING='BaileyUITests/WorkspaceDockUITests/testRightClickFileTabAndCommandWCloseTheSameFile BaileyUITests/WorkspaceDockUITests/testRightClickInactiveFileTabClosesOnlyThatTab BaileyUITests/WorkspaceDockUITests/testCommandPaletteClosePanelUsesTheActiveTool'`
- 新增菜单展开期间的 ⌘W 可见反馈断言；
  对照用户可见高亮和实际剩余标签，不仅断言 `closeTarget`。

---

## Phase Gate

P1-T1 的 AppKit 原生事件结论已确定；
P1-T2 的文件操作真实 E2E 和 P1-T3 的关闭菜单反馈均通过；
没有破坏唯一快捷键拥有者、窗口归属及数据保护。
发现与当前规范相冲突的实测平台行为，先修改设计与规范，
不以仅显示 `⌘C／⌘W` 或宿主菜单结构通过代替真实交互。
