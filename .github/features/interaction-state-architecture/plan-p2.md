# P2：Explorer 打开、操作上下文与原生菜单事件

**目标：** 与 VS Code Explorer 一样，将“在列表里改变 Focus/Selection”、
“预览/打开文件”、“上下文动作目标”和“真正执行文件系统操作”分层；
相同用户意图只解释一次，原生 NSMenu/firstResponder 不借错误的状态代替。
本阶段在 P1 完成并审计 Go 后开始。

**上游源：**
`listService.ts:ResourceNavigator` 的 `onDidOpen`（single/double,
`preserveFocus/pinned/sideBySide`）、
`explorerView.ts:onDidOpen/getContext/onContextMenu`、
`explorerViewer.ts` 的真实压缩段以及 `fileActions.ts` 的文件操作。
使用 VS Code 语义，不移植 DOM 事件系统、Preview 标签生命周期或 ContextKey 服务。
菜单在 Bailey 必须使用 NSMenu/SwiftUI 原生机制。
本轮独立依据、明确保留的差异和逐任务删除清单见 [source-review.md](source-review.md)，
不继承既有 audit 的判断或运行结果。

**Bailey 现有入口与副作用：**
`FileTreePanel` → `ToolPanelView` 的 onOpenFile/onCommand
→ `Project.openFile`、`WorkspaceWindowModel.openFile/performFileTreeCommand`
→ `FileTab`、`DockWorkspaceModel`、本机/SSH 后端；
原生输入为 `TreeKeyboardView/ContextMenuClickView` 和 `NSWindow.firstResponder`。
在每 task 内继续核对完整调用者、错误和取消路径，不能只修改第一个 View。

**约束：** 旧 `context-menu-and-tree-selection` 计划已由 `304fd7df` 删除，
其原生菜单 Cmd-C 蜂鸣、Cmd-W 瞬间反馈和富类型剪贴板等未验收事项由本阶段重新独立取证；
不得恢复已删除计划或无条件宣称这些问题还存在/已经解决。
菜单只有一个命令动作实现、一个有效目标、一个 NSMenu 跟踪范围。
Files、Editor、Terminal 与 Git 的原生文本输入不得互相夺焦。

---

<a id="p2-t1"></a>

## P2-T1 收敛 Files 浏览与打开事件链

**上游：**
- `listService.ts:ResourceNavigator.onPointer/onMouseDblClick/onSelectionFromKeyboard/_open`
  只产生显式 `onDidOpen`，并传递保留 Focus/固定打开等意图。
- `explorerView.ts:onDidOpen` 只处理真实文件，
  折叠目录/Shift 区间/编辑新文件中禁止误打开。

**Bailey 锚点：**
- `Bailey/Files/FileTreePanel.swift` 的 `FileTreeScrollView.handleKey`、
  `FileTreeRow.selectForClick`、`TreeFileRow.open`、
  `openFile` 回调；
- `Bailey/UI/Panels/ToolPanelView.swift` 打开闭包；
- `Bailey/Workspace/Project.swift:openFile`、`selectTab`；
- `Bailey/Workspace/WorkspaceWindowModel.swift:openFile`；
- `Bailey/UI/WorkspaceDockView.swift:DockTabGroupView.select`、
  `DockWorkspaceModel.activate`。

**对齐前先实测与明确取舍：**
1. 表列出“左键文件/双击/Space/Return/⌘点击/Shift点击/右键/目录 twistie、
   工具按钮/Finder 外部投递/Command Palette”各自产生的
   Focus、Selection、Displayed FileTab、Dock activeGroup、firstResponder 的状态差。
2. VS Code 单击 preview 与双击 pinned 是其真实行为；Bailey 的单击
   在另一个可见组浏览、双击切入编辑器且**不自动替换临时 preview 标签**，
   属现有产品契约。把用户意图层对齐，不因复刻资源导航器就暗加 preview 生命周期。
   若 UI 对照认为必须改 preview，先在 `idea.md` 单列决定与安全验收，而不是顺手塞进本 task。

**步骤：**
- Red：在真实临时目录准备未打开和已打开两个文件，
  重现任一入口“选择但意外打开/打开两次/焦点转给隐藏组/已打开文件不复用”；
  输入框、中文/英文键盘、修饰键、连续双击分别建断言。
- Green：在原有模型 owner 或唯一文件打开协调入口
  合并重复点击判断；显式 Browse 只展示，Open 明确激活，
  目录展开不推导文件打开，修饰键不发 Open；
  保持文件标签 UUID、未保存缓冲和本机/SSH 身份。
- Refactor：删除刚被取代的重复激活/打开转发、过时注释和测试，
  不额外建立 OpenActionManager 或全局回调队列。

**验证：** `make test:FileTreeTests,FileTabPersistenceTests,DockWorkspaceTests,NativeFileTabTests`；
隔离 `WorkspaceFilesUITests`、`SharedTreeUITests`、
`WorkspaceDockUITests` 断言实际内容、文件原始字节、当前组与 firstResponder；
多窗口/跨项目/同名本机和 Windows SSH 文件、重复打开、慢响应/晚到恢复。
`make build:dev`。同提交更新 `docs/features/files.md` 和 `docs/features/dock.md`，
一个提交。

---

<a id="p2-t2"></a>

## P2-T2 收敛 Files 系统 Edit 与右键操作目标

**上游：**
- `explorerView.ts:getContext` 在 respectMultiSelection 时先保留多选集合，
  单选和无选择按当前有效 Focus/真实压缩段；
- `explorerView.ts:onContextMenu` 右键集合内保留集合、集合外切目标；
  不转发菜单导致的 Selection 变更为文件 Open；
- `fileActions.ts` 不从正在显示的编辑器文件猜 Explorer 命令目标。

**Bailey 锚点：** `FileTreeModel.selectedOperationPaths`、
`contextSelection(for:)`、`selectForContextMenu`、`selectedCompactPath`；
`FileTreePanel.rowMenu(for:)`、`canPerformEdit`、`performEdit`、
`handleMenuKeyDown`；
`TreeKeyboardView` 的系统 `cut/copy/paste/delete/selectAll/validateMenuItem`；
`WorkspaceWindowModel.performFileTreeCommand/canPasteFileTree`、
现有 `FileTreeClipboard` 与本机/SSH 后端。

**步骤：**
1. 先绘制操作解析优先级：**真正跟踪中的合法 NSMenu 上下文**
   → 此次右键命中的一项或多选集合；
   菜单关闭 → 当前 key window 的 firstResponder 决定标准 Edit；
   Files 实际聚焦时：Selection 大于 1 优先集合，
   否则有效 Focus/压缩目录段；编辑器/终端持焦点则继续原生 Copy/Paste。
2. Red：A/C 多选，右键 A 保持整组、右键集合外 B 仅 B；
   Focus 在集合外但 Selection >1，Edit 仍作用多选；
   单选 A/Focus B，则作用 B；菜单打开与取消前后，
   Copy/Cut/Paste/Delete/SelectAll、⌘C/⌘X/⌘V/⌘W，
   启用/禁用项都验证唯一真正可执行目标。
3. Green：只在已有 owner 收敛目标解析，避免
   `selectedOperationPaths` 和 `contextSelection` 各自复制跨域判断；
   修改行为前追踪 `WorkspaceWindowModel` 到后端实际数据修改、取消与错误。
4. 保持工作区、真实 Git 状态、SSH 机器路径、远端权限和剪贴板的最终效果；
   删除被替代的平行 target/fallback，不取消真正防写错的校验。

**同任务完成菜单边界：** 当前 `ContextMenuClickView.menuDidBeginTracking` 接收任意菜单通知，
具体 Files/Dock 的 `handleMenuKeyDown` 再检查菜单项与动作。迁移必须把“本次菜单”绑定与
结束/卸载撤销一起验证；不能先引入新的目标解析，再等 P2-T3 来使它安全。
P2-T3 只补真实系统事件、蜂鸣/瞬时反馈和相邻使用方回归，不新建第二套监听。
菜单内 action 与普通 Edit target 不是同一种解析，不为了函数合并删掉这条区别。
菜单关闭只清 Context；右键集合外造成的新 Selection 保留，不恢复右键前的旧 Selection。

**验证：** `make test:FileTreeTests,DockWorkspaceTests,PanelContextTests`、
最小原生 NSMenu/NSHostingView 测试和隔离 `SharedTreeUITests`／
`WorkspaceFilesUITests`；
临时文件 Copy/Cut/Paste/Move/Delete 的**目标路径与真实磁盘字节**、
不可覆盖已有文件/失效符号链接、空目录、Unicode/emoji、
本机与受控 SSH、断连/错根/跨项目/双窗/过期目标；
真实剪贴板不能无损恢复时不覆盖用户数据，在相应审计 Deferred。
`make build:dev`；同提交更新 `docs/features/files.md`、`docs/ui.md`，一个提交。

---

<a id="p2-t3"></a>

## P2-T3 原生菜单跟踪生命周期、快捷键、焦点回交与旧路径清理

**上游对照：**
- VS Code Explorer/SCM/Tab ContextMenu 的 getActionsContext/onHide
  代表**业务目标**与**菜单结束**，但事件实现是 DOM，不可复用；
- Git Graph 扩展 `web/contextMenu.ts` 维护独立临时目标并在
  Close/Refresh 时撤销或按身份重绑，仅学习行为。
- Bailey `ContextMenuClickView` 以 AppKit
  `prepareContextClick`、`NSMenu.didBeginTrackingNotification`、
  `didEndTrackingNotification` 和临时键盘监听实现；
  `ContextMenuClickTarget` 经 SwiftUI `.contextMenu` 真实展示菜单。

**步骤：**
1. 在单一窗口、两窗口和真实控制键右键中复现菜单跟踪：
   点击右键 → 菜单真的开始 → 点击命令/⌘键等价 → 取消/完成 → 清理所有相关临时目标；
   区分右键菜单 **视觉短暂按压反馈** 与**动作是否执行/NSBeep**，
   不能以日志或模拟点击代替。
2. Red（存在时）：用户曾反馈菜单 Cmd-C 虽复制成功仍有系统蜂鸣，
   Dock Cmd-W 动作正确但瞬时菜单反馈欠缺；目前旧 plan 已删除，
   需用当前独立 Dev 真正复测才可定“仍存在/已不存在”。
   复现时核对系统菜单动作一次、剪贴板字节/目标、未保存文件的关闭否决。
3. 对出现的根因，在 `ContextMenuClickView` 或
   `TreeKeyboardView` **唯一必要的原生边界**修正；
   菜单外不截获键盘、菜单内只有已启用项可以执行，
   作用域按 NSWindow 与项目身份；保留唯一必要的 `NSEvent.addLocalMonitorForEvents`，
   它是进程内监听，必须按事件窗口过滤，并非可改成不存在的“窗口级 monitor API”。
   禁止系统级全局监听及同一按键的平行命令实现。
4. 执行/取消/窗口失焦/切项目/SSH 断线/节点已删除/刷新重绑后，
   再次点击/按键不能沿旧菜单执行；与 Dock/context scope 的复用
   必须同源，不为每个 Panel 再造一个 MenuManager。
   结束时删除确实被替代的通知 observer、fallback 或多路按键处理。

**验证：** `make test:FileTreeTests,DockWorkspaceTests,AppIdentityTests`，
隔离 `SharedTreeUITests`、`WorkspaceDockUITests` 的实际菜单开/关、
Control-click、Shift+F10（支持的原生控件时）、同组/跨组、
中英/明暗/连续重复键和双窗；
实际最后文件字节/标签数量、焦点归属、禁用菜单不执行；
`make build:dev`。无真实系统菜单视觉/系统剪贴板证据不得宣称完整通过。
**文档/提交：** `docs/ui.md`、`docs/features/files.md`、
真实涉及 Dock 才改 `docs/features/dock.md`；一个提交。

---

<a id="p2-t4"></a>

## P2-T4 文件拖放/复制/移动与 Selection 目标一致

**上游：** VS Code `explorerViewer.ts` 的 Drag/Drop、
`explorerView.ts` 的资源目标、`editorDropTarget.ts` 的
Tree item / 外部 URI 来源隔离。文件树拖动对象是被真实选中的集合，
不是当前显示文件或焦点边框。

**Bailey 锚点：**
`FileTreeModel.beginDrag/consumeDrag`、`activeDrag`；
`FileTreePanel` 的 `makeDragProvider/receiveInternalDrop/importFromFinder` 注入闭包、
`FileTreeRow` 的 `.onDrag/.onDrop`、
`WorkspaceWindowModel.makeFileTreeDragProvider/receiveFileTreeDrop/performFileTreeCommand`、
`FinderWindowDrop` 和后端受控 Copy/Move；工具栏独立 Drop。

**任务：**
1. 列出单选/不连续多选/压缩目录段、拖动起点是否已选、
   当前活动/非活动组、Finder 外部/Files 内部的目标解析；
   明确 Option Copy 和默认 Move，禁止 macOS Finder 本地 URL 由 SSH 冒充。
2. Red：多选 A/C 拖动应只传 A/C；从未选 B 开拖是否只传 B，
   由 VS Code 源规则及 Bailey 产品约定核定；拖压缩中间父目录时
   不能错把末级目录移走；按 Option 的副本路径和原文件字节正确。
3. 仅在模型实际 Drag 记录与目标的唯一验证入口收敛路径/集合；
   完成前不提前改变 Selection、Dock activeGroup 或删除源文件；
   Drop 失败/取消/拒绝时撤销临时 drag nonce、保留源数据。
   现有公开 fileURL 仅注册被拖行的单一 URL，不能据此宣称多选外拖到 Finder 已等价；
   本任务补齐本机多选的逐项公开 URL 表示，SSH 仍只发布私有类型。
   采用最低系统已支持的 `NSView.beginDraggingSession(with:event:source:)` +
   多个 `NSDraggingItem`；本机每个合法源一项公开 URL，私有记录仍只解释一次。
   在现有树行原生边界接入并替代 `.onDrag` 的单 provider 路径，不并行发起两场拖动；
   不使用 SDK 中仅 macOS 27 支持的 gesture overload，不提高 15.6 部署目标。
   只替换拖动呈现/事件边界，内部移动仍复用 `receiveFileTreeDrop` 与文件保护动作。
   不能把 `.ownProcess` 的完整私有 JSON 原样放进 AppKit 的公开 pasteboard：
   本机对外只提供合法文件 URL，内部身份由本次本地 drag source 持有，
   接收原生 `NSDraggingInfo.draggingSource` 后交给同一窗口命令入口验证；SSH 不导出公开 Mac URL。
   需要迁移内部收包适配时与源端一起替换，不留下 SwiftUI/AppKit 两条内部 Drop 动作。
   取消/结束/异步 provider 完成分别测试；不能在有效 Drop 解码之前先清掉其 nonce，
   也不能将拖动操作返回成功当成磁盘操作成功。本机向外导出不删除源。
   不新增跨窗/跨项目/跨机器内部移动：当前 coordinator/token 的范围明确只支持同一树。
4. 检查同树、跨窗口/跨项目/跨机器、目标自身或子目录、同名/符号链接、
   外部 Finder/编辑器/WebKit/Ghostty 接收者；
   不用测试机制篡改用户 Finder/剪贴板或远端 master。

**验证：** `FileTreeTests`、`FinderDeliveryIntegrationTests`、
`PanelContextTests`、`WorkspaceFilesUITests`、
`WorkspaceWindowsUITests`，真实文件字节/源目标路径与目标布局；
空/大量/Unicode/SSH/不支持 Drop/中断恢复，
`make build:dev`。Docs `docs/features/files.md`、
涉及投放归属时 `docs/features/projects.md`、`docs/features/dock.md`。
一个提交。

---

<a id="p2-t5"></a>

## P2-T5 浏览文件后原生焦点交接、恢复和编辑器存活

**上游：** VS Code `ResourceNavigator._open` 的 `preserveFocus`；
`editorPart.ts:shouldRestoreFocus/addGroup/removeGroup` 在布局变动时
只恢复真正被该布局打断的 Focus；
`editorGroupView.ts:doShowEditor` 的取消/失败不会把失效内容当输入目标。

**Bailey 锚点：** `FileTreePanel.focusSelectedRow`、
`TreeKeyboardView`、`DockGroupFocusReader`、
`DockWorkspaceModel.activeGroupID`、
`WorkspaceWindowModel` 的 focused scene/input handoff；
`Project.openFile`、`FileTab.autoSaveOnFocusLoss`、
`ContentView`、各原生编辑器和 Ghostty host 的焦点报告。

**步骤：**
1. 建立 Focus 真值链：可见且 key 的 NSWindow → firstResponder →
   当前 Dock 组身份 → 真实 Files/Editor/Terminal/Git 内容。
   区分“列表键盘游标亮”与“这个列表真的拿到原生输入”。
2. Red：Files 单击时另一可见组展示文件但 Files 保留键盘；
   双击/Return 进入编辑器；回 Files 切换时 firstResponder 回到当前游标；
   查找栏、rename/new TextField、中文 IME、Ctrl+Tab/Palette/Sheet、
   后台窗口和已移走的 Dock 组不会把焦点归给隐藏内容。
3. Green：在既有 `WorkspaceWindowModel` 内收敛此链的跨组件许可/恢复；
   `ToolPanelView`/`DockTabGroupView` 装配所属 project/group/item 与
   实际挂载的聚焦、归属判断闭包，仍用 `TreeKeyboardOwner` 执行原生动作。
   Git 内 Changes/Graph 的 `lastKeyboardRegion` 留在 Git；Browser 的地址/网页留在 Browser。
   不新建 FocusManager/协议层，不复制可写 activeGroup/firstResponder。
   从触发事件而不是 SwiftUI 视图重渲染交接输入；
   延迟请求要核对当前窗口/可见组，不能用重复 async DispatchQueue 补丁。
   浏览文件失败、保存失败、窗口关闭或远程断线保留有效原始内容。
4. 同 task 删除 `activeTreeResponder` 的全窗口子视图搜索，
   及 `ownsActiveResponder/isStableWorkspaceResponder` 对本链控件类型、
   `DockGroupFocusView` 几何中心和停车容器的业务识别；归属由所属适配报告。
   Files `focusSelectedRow` 的局部选游标/等待首行保留，
   其中窗口/Palette 自动聚焦许可不再和窗口重复判定。
   `restoreFocusAfterCommandPalette` 复用当前有效目标，不保留遍历式备用恢复路径。
   同 task 删除重复、不再可达的备用 FocusState/后挂载重试路径；
   不创建新的 App-wide FocusManager 或对所有 NSView 的遍历规则。

**不可删错的原生时序：** `SourceTextEditor` 的挂载回调、Diff 的 layout pendingFocus、
终端停车后布局激活和 Palette 搜索框移除事务确有不同原生生命周期。
只删除已被新接入替代的重试，不以“禁用 DispatchQueue”为验收。
挂载未就绪时保留一个当前请求，挂载/布局回调重试，成功或目标失效即结束；
不为每层再叠 generation、超时或轮询。P4-T7 承接其它内容的迁移，不重新设计本链。

**验证：** `FileTabPersistenceTests`、`NativePaneRetentionIntegrationTests`、
`DockWorkspaceTests`、`WorkspaceRetentionUITests`、
`WorkspaceDockUITests`、`WorkspaceFilesUITests`；
实际键盘输入落在正确视图，磁盘字节/Undo 和五标签资源不丢，
窗口重开后无虚假 firstResponder，连续多组快速切换，
`make build:dev`。文档 `docs/features/files.md`、
`docs/features/editor.md`（仅编辑器契约改变）、`docs/features/dock.md`，
一个提交。

---

## P2 阶段验收与审计

- 在每 task 完成后定点执行相应类并逐步扩大到 Files 与窗口相关宿主全集；
  执行 `make build:dev`，实际签名检查；共用菜单改动补 Git/Dock 菜单宿主和 UI。
- 实机核对 `source-review.md` 中 Files 的单击/双击/多选/目录压缩/
  右键菜单/键盘/拖动/复制/保存与用户最终结果；
  后台刷新/断线与两个窗口没有错误命令。
- 不因以前的测试曾通过而跳过当前真实 E2E；
  不因无法无损备份系统富类型剪贴板就破坏用户内容；
  不可实测项用明确 Deferred 证据保留在任务/审计。
- 验证各 task 的 Git 原子提交或已验收无变更证据和最新 docs；运行
  `feature_tool.py phase-complete ... --phase p2`，
  立即调用 `plan-task-auditor` 审核 `audit-p2.md`；
  Go 才进入 P3。
