# P2：文件打开、操作目标与原生键盘职责

**Goal：** 让 Files 的选择、浏览、打开和 Edit/菜单命令从明确事件出发，
只在当前领域位置写入状态；消除 View 和窗口模型对同一事件的重复解释。
**Non-goals：** 不改文件存储后端、终端或编辑器模型，不再建一套快捷键注册/菜单监听器。
**Approach：** 对照 VS Code `listService.ts`、`explorerView.ts`、
`fileActions.ts` 的用户意图分层；沿 Bailey 现有
`FileTreePanel` → `ToolPanelView` → `Project.openFile` /
`WorkspaceWindowModel.performFileTreeCommand` 核对副作用，
优先收敛已有路径而非增加 Coordinator。
**Acceptance：** 仅显式事件打开；行选择、焦点移动、右键、折叠都不会打开；
菜单/键盘命令针对合法同项目、同机器路径；真实数据/未保存编辑保持安全。
**Rules：** 当前旧 Feature 的 P1 菜单按键与反馈未验收，必须先核对它的
`todo.toml`、`audit-p1.md`，不得重做或虚报；Settings 不动。

---

## P2-T1 消除 Files 单击／双击／键盘打开动作的重复解释

**锚点：** `Bailey/Files/FileTreePanel.swift` 的 `FileTreeRow.selectForClick`、
`FileTreeScrollView.handleKey`、`openFile`；
`Bailey/UI/Panels/ToolPanelView.swift` 文件打开闭包；
`Bailey/Workspace/Project.swift` 的 `openFile`、
`Bailey/UI/WorkspaceDockView.swift` 的组选择。
**任务：** 对照 VS Code Explorer `onDidOpen`，读清从点击/双击到 FileTab
显示、Dock 活动组、真实编辑器第一响应者的完整链。
一个事件仅执行一次“浏览/打开/激活”意图：普通单击显示但保留 Files Focus，
双击/Return 明确激活编辑器；Space 只浏览；修饰键点击不打开；
目录点击只折叠/展开；触发后检查是否真正显示正确 FileTab。
在已实现路径合并重复转发，连同删掉的旧分支一起提交。
**验证：** `make test:FileTreeTests,FileTabPersistenceTests,DockWorkspaceTests`，
`make build:dev`；隔离 UI：单/双击、Space/Return、输入框接管、
同组替换/异组展示、未保存编辑、第二窗口、SSH 路径。
更新 `docs/features/files.md`、`docs/features/dock.md`；不可取得的环境逐项记录。

## P2-T2 收敛 Files 系统 Edit 和菜单命令的真实目标解析

**锚点：** `FileTreeModel.selectedOperationPaths/contextSelection(for:)`、
`FileTreePanel.rowMenu/performEdit/canPerformEdit/handleMenuKeyDown`、
`TreeKeyboardView`、
`WorkspaceWindowModel.performFileTreeCommand/canPasteFileTree`。
**任务：** 根据 VS Code Explorer `getContext(true)` 明确集合>1、
单选/无选时 Focus、紧凑目录实际层级和菜单期 Context 的优先级。
不能从“哪个 View 画蓝底”逆推命令对象。
在已有动作所有者收敛重复解析、清掉旧分支；
已有 P1 菜单蜂鸣／反馈继续追踪原 feature，任何改动先复验该链。
**验证：** 先 Red→Green（如发现失败），`make test:FileTreeTests,DockWorkspaceTests`，
隔离 GUI 逐项验证本机/SSH 的 Copy/Cut/Paste/Move/Delete/Trash、
失效行、两窗口、焦点编辑框、菜单关闭与确认、真实字节/剪贴板；
不得覆盖不可恢复的用户剪贴板。
更新 `docs/features/files.md`、`docs/ui.md`、必要时 `docs/features/dock.md`。

## P2-T3 菜单生命周期与聚焦交接验收、删旧分支

**锚点：** `TreeKeyboardOwner/TreeKeyboardView`、
`ContextMenuClickView.prepareContextClick/menuDidBeginTracking/menuDidEndTracking`、
`FileTreePanel` 和 `DockWorkspaceView` 的菜单 `onMenuClosed`；
`BaileyUITests/Files/SharedTreeUITests.swift`、`WorkspaceDockUITests.swift`。
**任务：** 追原生 NSMenu 生命周期至操作完成/取消、切窗/切项目，
检查右键临时 target 无泄漏、原生输入不被抢；核销同源菜单路由的后续清理，
不再叠加 another monitor/state machine。旧 Feature 未完成的蜂鸣/反馈
只能经真实 GUI 验收后核销，不以代码重构视为通过。
**验证：** `make test:FileTreeTests,DockWorkspaceTests`、
`make test:ui ONLY_TESTING=BaileyUITests/SharedTreeUITests`（独占图形会话），
`make build:dev`；明暗/中文/英文、多选、连续菜单、Esc、越窗、SSH 断连/重连、
焦点输入框/原生剪贴板与已执行命令只发生一次。
更新 `docs/ui.md`、`docs/features/files.md` 及现有菜单 Feature 的现行交叉引用。
