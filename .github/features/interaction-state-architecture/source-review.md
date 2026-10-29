# 执行前独立源码复核

本页供实施者核对行为、取舍、删旧边界和验证条件，不是已经实现的功能报告。
基线审查日期：2026-10-27；P3 现行路径重核：2026-10-29（`ad020a2f`）。
旧基线的历史问题与测试记载不自动代表当前实现；P3 实施以这次修正的
源码映射及任务中的重新验证为准。实时任务状态以 `todo.toml` 为准。

## 依据与阅读边界

- 不读取、不继承 `audit*.md` 或 `vscode-source-audit.md` 的结论、失败数字与验收状态。
  本轮从现行计划、产品文档、当前源码和上游固定版本重新建立依据。
- Bailey 基线：`e0e29d2c323aa0f60c76ed1051543fcdc7ee8149`。
  先执行 `rtk codegraph sync`，沿调用关系定位，再用逐字源码补足索引遗漏；
  原生读取用于避免摘要遗漏关键分支。没有修改任何生产源码或测试。
- VS Code：重新下载并解压
  [固定提交的官方源码](https://github.com/microsoft/vscode/tree/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e)。
  Git Graph：重新下载并解压
  [固定提交的官方源码](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812)。
  不是从网页片段、二手说明或旧 audit 反推实现。
- 下载目录为 `/tmp/bailey-interaction-review.450eQG/`，只作为本轮缓存，不是后续任务的路径依赖。
  VS Code 压缩包 SHA-256：`0b334323919b30c30e2771865d18d9384e4536b4d465900e83f55999fdb7a716`；
  扩展压缩包：`c1dd1cee1d02f332e17c0f699eca4d6357cc12946da9aaaa139a80fe6d2f18b4`。
- 阅读范围按 Feature 的真实执行链扩展到共享行、原生宿主、文件/Git 后端、保存保护与恢复。
  下表列出核对的文件、符号和相邻控制流；不是声称逐行读完两座仓库或整个 Electron/SwiftUI。
  依赖未涉及的语法引擎、隧道、发布工作流不因“完整”而顺手重构。
- 源码能证明分支与状态因果关系，不能证明系统事件、像素、物理设备或真实 SSH 已通过。
  本轮没有运行 VS Code/Electron、Bailey Dev、XCTest、产品构建或安装。

### 上游源码地图

以下 VS Code 路径均相对固定提交仓库根；扩展路径单独标明。

| 源码 | 核对入口及结论 | 消费任务 |
| --- | --- | --- |
| `src/vs/base/browser/ui/list/listWidget.ts` | KeyboardController、MouseController.changeSelection/onContextMenu、getContiguousRangeContaining/disjunction/relativeComplement、DefaultStyleController、ListViewDragAndDrop；Focus/Selection/Anchor、鼠标范围、视觉和拖动来源各有职责 | P1、P2-T2/T4 |
| `src/vs/workbench/browser/actions/listCommands.ts` | navigate/updateFocus、expandMultiSelection、Shift+↑↓/Home/End 注册；工作台键盘不等于基础 List 的鼠标算法 | P1-T1/T5、P3-T3 |
| `src/vs/base/browser/ui/tree/abstractTree.ts` | Trait.onDidModelSplice、TreeNodeList.splice/setFocus/setSelection/setAnchor、TreeNodeListMouseController；模型 Trait 与渲染列表不同 | P1-T2/T3 |
| `src/vs/base/browser/ui/list/listView.ts` | onDragStart 调用 getDragElements 后发布集合，不由当前展示文件推断 | P2-T4 |
| `src/vs/platform/list/browser/listService.ts` | ResourceNavigator 的 keyboard/pointer/double-click/_open、WorkbenchListSelectionNavigation 与树上下文；preserveFocus 是显式意图 | P1-T5、P2-T1/T5 |
| `src/vs/workbench/contrib/files/browser/views/explorerView.ts` | getContext、onDidOpen、onContextMenu；`onDidActiveEditorChange → selectActiveFile → explorerService.select`，选中活动文件但不夺 DOM 键盘焦点 | P1-T3、P2-T1/T2/T3、P4-T2 |
| `src/vs/workbench/contrib/files/browser/views/explorerViewer.ts` | CompressedNavigationController、ExplorerCompressionDelegate、FileDragAndDrop 的真实段/drag/drop；压缩显示不是目录身份 | P1-T3、P2-T4 |
| `src/vs/workbench/contrib/files/browser/explorerService.ts`、`files.contribution.ts` | `selectResource` 展开父目录后 `setFocus([item]); setSelection([item])`；`explorer.autoReveal` 默认 true，存在 Exclude/不可见边界 | P2-T1、P4-T2 |
| `src/vs/workbench/contrib/files/browser/fileActions.ts` | copy/cut/delete/paste/getFilesToPaste/openFilePreserveFocus；动作接收资源集合，文件效果经既有 bulk edit 服务 | P2-T2/T4 |
| `src/vs/workbench/contrib/scm/browser/scmViewPane.ts`、`scm.contribution.ts` | createTree/open、RepositoryPaneActionRunner、onListContextMenu/getSelectedResources；`onDidActiveEditorChange` 在匹配资源时执行 `setSelection/setFocus`，`scm.autoReveal` 默认 true；SCM 右键不照搬 Explorer 改选 | P3-T1/T3、P4-T2 |
| `extensions/git/src/commands.ts` | stage/unstage/clean 对资源分组过滤及冲突处理；“集合里有资源”不等于每个动作对每项都合法 | P3-T3/T6 |
| `src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.ts` | SCMHistoryTreeIdentityProvider、_createTree/_onDidOpen/_onContextMenu；History 多选关闭，历史变化的两侧 URI 与 LoadMore 分开 | P3-T2/T4/T7 |
| `src/vs/workbench/contrib/scm/browser/scmHistory.ts` | swimlane 输入/输出、renderSCMHistoryItemGraph、颜色注册；上游固定五个图谱色位不等于 Bailey 十二色槽 | P3-T5 |
| `src/vs/workbench/common/editor/editorGroupModel.ts` | setSelection/doSetSelection、selectedEditors 顺序；active 是 Selection 成员，组激活另有事件 | P4-T2/T4 |
| `src/vs/workbench/browser/parts/editor/multiEditorTabsControl.ts` | registerTabListeners、selectEditor/selectEditorsBetween/unselectEditor、mousedown/mouseup、onDragStart、键盘可达性；不能复用树 Shift 算法 | P4-T4/T5/T6 |
| `src/vs/workbench/browser/parts/editor/media/multieditortabscontrol.css` | active group/tab、selected:not(active)、unfocused 背景文字分开；只对照状态，不复制 CSS 或现代标签肩部几何 | P4-T4/T6 |
| `src/vs/workbench/browser/parts/editor/editorTabsControl.ts` | isMoveOperation/onTabContextMenu；Singleton、同组 Copy 修饰按 Move，右键提供 group/editor context | P4-T2/T5/T6 |
| `src/vs/workbench/browser/parts/editor/editorDropTarget.ts` | handleDrop 按 Group/Editor/TreeItem/URI 分流；批量 editor 移动后才给目标焦点，最后项可整组移动 | P2-T4、P4-T5 |
| `src/vs/workbench/browser/parts/editor/editorCommandsContext.ts` | getCommandsContext/getMultiSelectContext/resolveCommandsContext；当前项在组选区内才扩展为该组集合 | P4-T6 |
| `src/vs/workbench/browser/parts/editor/editorActions.ts`、`editorCommands.ts` | CloseEditorTabAction 与关闭/移动命令消费上下文；不能只改菜单目标而漏掉关闭按钮、主菜单和中键 | P4-T5/T6 |
| `src/vs/workbench/browser/parts/editor/editorGroupView.ts`、`editorPart.ts` | setActive 清非活动组多选、setSelection、shouldRestoreFocus；恢复依据原输入是否被布局打断 | P2-T5、P4-T4/T7 |
| `src/vs/workbench/browser/parts/editor/editorParts.ts` | registerEditorPartListeners、doUpdateMostRecentActive、getPartByDocument；实际焦点、窗口关闭激活与 MRU 分开 | P4-T7 |
| `src/vs/workbench/browser/parts/editor/editorQuickAccess.ts`、`src/vs/platform/quickinput/browser/quickInputController.ts` | accept 才打开、hide 检查是否已有新输入再恢复；不移植 DOM 焦点链与定时动画 | P4-T3 |
| 扩展 `web/main.ts` | observeTableEvents/observeKeyboardEvents、getCommitOrder；ref 单击只结束菜单，双击分支会 checkout；提交游标与展开分别处理 | P3-T2/T4/T6 |
| 扩展 `web/contextMenu.ts` | show/close/refresh；刷新只在原 index 的 hash/ref 仍匹配时重绑，否则关闭，并不是全表按 hash 搜索恢复 | P2-T3、P3-T6/T7 |
| 扩展 `web/graph.ts` | loadCommits、第一/替代父子查询；子节点按同分支优先，不是简单取数组邻项 | P3-T4/T5 |
| 扩展 `web/styles/main.css` | commit:hover/contextMenuActive 与 commitDetailsOpen 的灰底不同；Bailey 明确保留“展开无持续底色” | P1-T4、P3-T5 |

上游测试核对重点：`src/vs/base/test/browser/ui/list/listWidget.test.ts` 的分页与样式，
`src/vs/base/test/browser/ui/tree/objectTree.test.ts` 的 identity，
`src/vs/workbench/contrib/files/test/browser/explorerView.test.ts` 的 getContext/真实树右键，
`src/vs/workbench/contrib/scm/test/browser/scmHistory.test.ts` 的线性/分叉/merge/颜色 DAG，
`src/vs/workbench/test/browser/parts/editor/multiEditorTabsControl.test.ts` 的 active/多选/失焦绘制。
测试本身是契约证据，本轮未执行它们；不声称上游已有测试覆盖这里所有新增需求。

### Bailey 执行链与文档归属

| 链路 | 追踪到的所有者和最终结果 | 同任务维护的文档 |
| --- | --- | --- |
| Files 输入/树 | `FileTreePanel` 的 FileTreeScrollView.handleKey、FileTreeRow.selectForClick/compactSegmentView/rowMenu → `FileTreeModel.select/focus/moveSelection/selectRange/contextSelection/rebuild/sync` → `TreeDisplayModel` / `TreeRowStyle` / AX | `docs/features/files.md`、共享视觉确有变化时 `docs/ui.md` |
| Files 打开/自动定位 | P2 已接通 `WorkspaceWindowModel` 的 Dock 活动项回调 → `FileTreeModel.revealFile(automatically:)`，按当前项目、窗口、机器及连接代次复验；`Project.selectedTabID` 仍只是最近工作标签。Files 不能因 Git 预览或隐藏组夺取编辑器原生输入 | files、dock、必要 editor |
| 文件修改/剪贴板/拖动 | `FileTreeNativeDragSurface/FileTreeDrag` → `WorkspaceWindowModel.receiveFileTreeDrop/performFileTreeCommand/performFileOperation` → `WorkspaceApplication.withProtectedFiles` → `FileTreeModel.performFileOperation/rename/commitDraft` → 当前本机或 SSH backend。P2 已移除旧 `makeFileTreeDragProvider`；不得将这条历史入口误作为 P3 兼容代码清理目标 | files、必要 projects/ssh |
| Finder 投递 | `ContentView` 中 FinderWindowDrop.receive → WorkspaceApplication 的外部请求队列 → WindowModel.openExternalLocalItems → Project.openLocalFile；Files 接收改为 importFromFinder，Ghostty/WebKit 正文不挂通用 Drop | projects、files、dock |
| Git Changes | `GitPanel.selectedChange` 是游标，`explicitlySelectedChange` 是单资源 Selection，`contextChange` 是右键临时目标，`isDisplayedChange` 另绘灰底；`displayedDiff` 当前取 `Project.selectedTab` 而非真实活动 Dock 组。Stage/Unstage 的 `Entry` 执行前须按当前 Section 重新解析；`PendingDiscard/perform` 与编辑保护继续保障本机/SSH 字节安全 | `docs/features/git.md`、必要 dock/ui/ssh |
| Graph/历史 Diff | `GitStatusModel.expandedCommitIDs` 通过 `GitPanel` Binding 给 `RecentCommitsView`；Graph 游标与临时菜单留在该 View，目录折叠在 GitStatusModel。Graph/历史文件/refs/stash/worktree → 当前 Git 目标校验 → `Project.openHistoricalDiff` → `DiffTab.Source.commit`/`reload` 的 immutable blobs | git、diff、dock；持久化实际变化时 session-restore |
| Dock/关闭 | WorkspaceDockView/DockTabGroupView/WorkspaceChrome → DockWorkspaceModel.select/activate/move/updateLayout/syncTabs → Project.selectTab/closeContent/closeBatch/saveBeforeClosing → 文件保存、Sheet 和受控资源释放 | dock、ui、必要 architecture/settings |
| Projects | ProjectsPanelView.cursorProjectID/contextProjectID/handleProjectKey → WindowModel.selectedProjectID/close/moveProject → 当前项目与其会话 | projects、dock |
| 暂态输入 | CommandPaletteView.run/dismiss、TabSwitcherController.cycle/dismiss/handle → WindowModel.toggleCommandPalette/restoreFocusAfterCommandPalette → 当前有效原生输入；Switcher 只提交现存当前项目 | command-palette、dock |
| 真实焦点 | DockGroupFocusView/TreeKeyboardOwner → PanelContentView → SourceEditorContainer、DiffNativeSurface、TerminalContainerView/停车容器、BrowserAddressField/WebView；各适配报告挂载与执行结果，窗口只作跨组件交接 | architecture、dock、editor、diff、terminal、browser |
| 窗口/持久化 | BaileyApp/WindowRootView 的 focusedSceneValue 与系统 Commands → WorkspaceApplication 登记/关闭保护 → WindowModel 快照 → SessionStore/DockSavedNode；多选暂态不扩张存储格式 | architecture、session-restore |

核心规则来自当前 `AGENTS.md`、`docs/README.md`、`architecture.md`、`standards.md`、
`ui.md`、`testing.md`、`development.md`，不是将计划里的期望写成现有能力。
已核对上述功能文档中的不变量与相关实现说明；仅更新计划，不提前改“当前实现”文档。

## 查出的计划问题与修订

这里记录的是源码支持的计划缺陷或缺项，不把尚未运行的产品行为猜测记成已复现 bug。

### 必须先修正的语义

1. **High：把鼠标 Shift 与键盘 Shift 共用范围算法。**
   基础 `MouseController.changeSelection` 替换 Anchor 连续岛；工作台
   `expandMultiSelection` 按前后 Focus 加/删一个成员，边界不移动时不变。
   Bailey 两入口当前共用 `selectRange`。P1-T1、P3-T3 已分开算法与反例。
   `selectRange` 的缺陷不能靠 View 记“旧选区”或在键盘入口重复套鼠标算法解决。

2. **High：把树 Shift 规则套给 Tab。**
   Tab 的 `selectEditorsBetween` 只移除 Anchor 另一侧的连续选区；同侧回点可以保留更远项。
   例如 A/C → Shift E → Shift D，Tab 仍是 A/C/D/E，树鼠标则回缩为 A/C/D。
   P4-T4 加入这个明确反例，不保留“统一 Anchor helper”的暗示。

3. **High：把 Explorer 右键改 Selection 误当所有列表规范。**
   Explorer 的 onContextMenu 会对集合外目标单选且不发 Open；
   SCM 的 onListContextMenu 不改 Selection，ActionRunner 决定集合内/外目标；
   Tab 菜单同样只建立 context。P2-T2、P3-T3、P4-T6 分别明确，
   菜单取消不等于恢复右键前选区。

4. **Medium：把折叠后删除 Selection 声称为 VS Code 同义。**
   上游 Explorer 测试在 collapse 后明确断言隐藏子项仍被选中；
   Bailey `rebuild` 可见求交与 `testFileTreeMultiSelectionTracksCollapseRenameAndWorkspaceSwitch`
   要求相反。P1-T2 明确保留 Bailey 已有规则，不凭空增加隐藏节点缓存或 inode identity。

5. **High：Git 多选缺少目录解析、动作过滤与真实批量完成。**
   上游 ResourceTree.collect 允许目录参与集合，再由 Git 扩展过滤合法分组。
   原计划排除目录，却又要求验证目录组合。Bailey 已有 stageEntries/unstageEntries，
   不需要重写 Git 服务；循环调用单项会遇到 isBusy，方法返回 void 也不证明完成。
   P3-T3 统一目录/叶子去重、跨 Section 合法目标、单次批量 runner 与实际 index 断言。

6. **Medium：混淆内置 Graph、扩展 Graph 和 Bailey 自有 Worktree。**
   内置 History 禁多选；扩展主要展示单一详情，ref 单击不展开、双击分支会 Checkout；
   Bailey 是多展开、ref 单击展开、普通箭头仅移动游标。扩展固定版本的 web/src 无 Worktree
   交互实现，不能用它给 Bailey Worktree 菜单背书。P3-T4/T6 已写清采用与不采用的规则。

### 必须闭合的执行链

7. **High：新增标签多选却仍按普通单项拖放和鼠标松开处理。**
   上游 mousedown 保留组选区供拖动，mouseup 才收单选；Bailey Button + DragGesture
   和 DockGroupFocusView.mouseUp 会重复影响激活。
   P4-T4 同时接通事件与批量 Move，删除单项业务旧路；P4-T5 不再是“以后补齐必要安全”。

8. **High：批量 Move 逐项调用 move 会发布中间状态。**
   当前 move 每次 updateLayout 会触发 active/deactivate/snapshot。
   P4-T4/T5 要求一次从旧 root 计算集合移除与插入，正确折算同组 index，最终只发布一次。
   删除 Position.item 的单项假设与重复 gesture，单项也经同一集合实现。

9. **High：批量关闭不能仅复制 Close 菜单。**
    VS Code 的命令上下文、CloseEditorTabAction、关闭按钮与中键都消费组选区。
    Bailey Project.closeBatch 已有保存/顺序 Sheet，取消不回滚已完成项。
    P4-T6 复用该路径并接上工具项，不逐项 fire-and-forget，不先终止 PTY 再发现脏稿保存失败。

10. **Medium：把未来 Copy/跨窗口传输当现成能力。**
    DockItem 全项目唯一，FileTab 去重，PTY/WebView 没有 Clone；拖动 coordinator 是窗口内手势。
    P4 明确 Move-only，不为理论 Clone 制作接口/权限表/兼容 fallback。
    不能把 Finder 跨窗打开文件的测试当作内部标签跨窗 Move 的通过证据。

11. **High：焦点治理只有口号，没有删掉反向依赖。**
    WindowModel.activeTreeResponder 搜全窗口子视图；ownsActiveResponder 识别具体控件、
    几何组和停车容器；各组件又重复判断自动聚焦许可。
    P2-T5 接通现有窗口 owner 与所属适配报告，删被替代的遍历/推断，P4-T7 补完各原生内容。
    布局/挂载时序、field editor、Find/IME 是真实责任，不可把所有 async/@FocusState 当垃圾删掉。

12. **Medium：本机多选内部拖动不等于完整对外导出。**
    makeFileTreeDragProvider 的私有记录含 paths，但公开仅注册 item.path 一个 NSURL。
    P2-T4 明确本机逐项 NSDraggingItem，SSH 只私有数据，私有 Drop 不降级 Finder。
    本机 SDK 的 NSView.h 已核对：event overload 自 macOS 10.7 可用，gesture overload 仅 27.0。
    使用 [原生多项拖动 API](https://developer.apple.com/documentation/appkit/nsview/begindraggingsession(with:event:source:))，
    不抬最低版本、不再建另一条 Copy/Move 后端。

13. **Medium：菜单生命周期安全不能晚于新目标解析。**
    ContextMenuClickView 接收下一次 begin-tracking 通知，Files/Dock 回调再核对菜单项。
    P2-T2 在同任务绑定本次合法菜单、动作一次与清理；P2-T3 只做真实事件/蜂鸣/反馈补验。
    当前生产缺陷是否实际发生仍须 Dev 复现，不沿用已删除计划的结论。

14. **Medium：Switcher 的旧 Project 检查不足。**
    dismiss 检查原 Project.selectedTabID，却不检查它是否仍为窗口当前项目；
    selectedProjectID.didSet 当前没有 cancel Switcher。同窗口切项目后 Control 释放可改旧项目 MRU。
    P4-T3 把取消接到现有显式切换/关闭动作，不加新的 request generation。

15. **Medium：验证/命令/交付说法漂移。**
    当前 UI 夹具入口是 WorkspaceUITestSupport.launch(in:project:)，不是假设的统一
    WorkspaceUITestFixture；Graph 自身不横滚，仅长文本横滚；历史分页每页 30；
    DockFocusIntegrationTests 是实际存在的原生焦点宿主类。
    P5 不机械为所有数据组合复制 GUI，Dev 测试不代替之后正式构建/整包安装。
    原计划中的历史 Red 数字移除，所有 runtime 结果重新取得。

16. **Medium：26 个任务链接只有短 fragment，却没有对应真实锚点。**
    `todo.toml` 指向 `#p1-t1` 等短 ID，而原 Markdown 标题还带完整任务名。
    只跑 todo validate 不会发现这种浏览导航缺陷。现为全部任务增加显式 ID，
    并单独校验 task、文件、短锚点和唯一标题的一一对应。

17. **Medium：将语义分开误写成禁止派生，或暗示 Bailey 尚未区分状态。**
    八类概念是分析词汇，不是 VS Code 官方统一状态模型；List 的三个 Trait、Tree 的展开、
    编辑器组状态和菜单上下文分别有自己的实现。固定版本 `editorGroupModel.ts` 的
    `active` getter 直接返回 `selection[0]`，`doSetSelection` 同时维护 active 与 selected；
    因而“独立语义”不能要求独立可写字段或禁止一切派生。
    Bailey 的 GitPanel 已分别持有 selectedChange 游标、explicitlySelectedChange 单项选择、
    contextChange，并从当前内容取得 displayedDiff；TreeRowSurface 已把 Hover 留在视图，
    RowHighlightStyle 也已接收六个独立视觉标志。不能因旧名字或上游颜色不同就推导出 Bug。
    idea 已明确术语边界，P1-T4 按适用组合核对现有共享样式及调用参数，P3-T1 保留正确路径，
    P4 保留 Displayed 与 Selection 的约束，P5 不以“八字段齐全”验收。
    新增多选只落在 Changes/Dock，不扩成 Projects/Graph 的通用集合；菜单期清底色保持现行约定。

18. **High：漏掉活动编辑器变化触发 Explorer/SCM Auto Reveal。**
    上游固定提交 `explorerView.ts:381-384,486-499` 订阅 `onDidActiveEditorChange`，
    `selectResource:909-969` 在父目录展开后同时更新 Focus/Selection；
    `files.contribution.ts:444-453` 的 `explorer.autoReveal` 默认 true。
    `scmViewPane.ts:1754-1799` 仅在找到对应资源时更新 Selection/Focus，
    `scm.contribution.ts:289-293` 的 `scm.autoReveal` 也默认 true。
    Bailey `Project.selectTab` 只切换 Dock，旧 Files/Changes Selection 保留，
    `ToolPanelView.openFilePath`、`GitPanel.isDisplayedChange` 又把新 Displayed 作为第二条灰底。
    P2-T1 接通 Files 同步并去掉其独立 Displayed 底色，P3-T1 对 Changes 做同样处理；
    P4-T2 检查 Dock 所有标签选择入口，P5 覆盖跨区域/窗口/连接与快速切换。
    同步只改模型游标与选择，不借其获取 NSWindow.firstResponder；
    外部路径/不可见资源/SCM 无匹配不得伪造选区，异步不得把旧标签写回。

## 每个替换任务必须当场删除什么

删除以新入口真实接通、回归通过为前提；不先删掉有职责的路径再用 fallback 顶上。

| 任务 | 同任务删掉/替换 | 必须保留的真实边界 |
| --- | --- | --- |
| P1-T1 | 共用单一区间覆盖的错误逻辑；View 侧重复推算范围；不适用的 by:2 键盘测试假设 | 路径成员校验、单一游标、draft 排除 |
| P1-T2/T3 | 重复的游标/Anchor 清理与错误压缩段 fallback；真实使用方遗漏的分段接入当场补上 | 读取失败保留可信行、连接核验、懒加载和深度限制 |
| P1-T4/T5 | 使用方重复背景/描边判定、无真实用途的备用树 FocusState | 各输入控件自身焦点和基础 AX，当前产品视觉 |
| P2-T1 | View/窗口/Project 重复解释 Browse/Open 的分支 | 同机同路径去重、未保存缓冲、同组隐藏工具的真实焦点交接 |
| P2-T2/T3 | 被替代的临时菜单 observer、平行按键动作与失效 Context fallback | 当前菜单/窗口/启用状态、执行一次、结束撤销；主菜单唯一注册 |
| P2-T4 | `.onDrag` 单 provider 的旧导出实现；第二条拖动触发路线 | 私有 token/project/window/connection/nonce、源目标边界和不可覆盖发布 |
| P2-T5 | 全窗口查找 TreeKeyboardView、窗口识别下层具体控件和几何归属的旧恢复路径 | 组件真实挂载/执行结果、当前 key window、Palette/Sheet/field editor 优先 |
| P3-T1/T3 | explicitlySelectedChange 单对象字段及其全部读写；单/多选两套动作解析 | Section/Repo/机器身份、冲突与 Discard 指纹、runner 互斥 |
| P3-T4 | 过期的点击状态分支与重复目标恢复 | 历史只读、父子提交 SHA、原生焦点与过期历史拒绝 |
| P3-T5/T6/T7 | 重复条件色、已替代菜单转发、按数组位置恢复业务身份的路径 | 有效 ref/HEAD/stash selector/Worktree 校验及失败旧数据显示 |
| P4-T1/T2 | View 中双重 dock.select/project.selectTab；模型不变量成立后删 selected 的 View fallback；运行配置中静默吞 info 名字的旧分支 | 现有配置无效处理与其它偏好；已写入快照的最小解码保护 |
| P4-T3 | 旧项目仍可提交的 Switcher 路径、重复恢复逻辑 | 暂态预览、现有 MRU、Control 松开才提交、IME 输入 |
| P4-T4/T5 | 单项 Position/Move 的平行业务实现、修饰键后再次普通选择的 mouseUp | singleton 唯一、原生内容身份、整次布局发布与取消不变 |
| P4-T6 | 仅单 closeTarget 的单双选双轨、并发逐项关闭入口、Tab 误套树外观 | 既有顺序保存/确认、失败保留、真正确认后才释放资源 |
| P4-T7 | containsResponder 的业务几何/控件识别、Browser 两处六次/50ms 轮询 | 原生就绪回调、停车/可见性、查找和地址栏局部语义 |
| P5 | 不接收前面遗留的已替代生产代码；发现漏项回其 owner 闭环 | 真实组合、负例、文档与实际证据 |

### 不是“多余围栏”的现存代码

以下不是为未来搭的防护，不能以“删兼容/删安全围栏”统一移除：

- `DockSavedItem.info` 只在读取已存快照时过滤旧项；删除 enum case 会令整份快照解码失败。
  `SessionStoreTests.testObsoleteInfoItemIsFilteredWithoutDiscardingLayout` 明确保护其它窗口/标签布局。
  它不是运行态面板或双轨渲染；不新增更多历史兼容，也不为了删一个 case 新造迁移器。
- `TabSnapshot.localFile` 缺省区分旧 SSH 归属与明确 Mac 文件，`Project.makeContent` 决定真实后端。
  随意改成默认本机或移除字段，会让恢复读写错机器；保持现有格式与最小读取。
- Files 的 project/机器/连接/根/nonce 校验有异步 provider、SSH 重连与跨窗路径的真实入口；
  不与 FileTab 自己的读取/保存代次混为一层。只合并同责任重复判断，不删跨 await 的执行前核对。
- LocalWorkspaceBackend 的同卷暂存 + RENAME_EXCL、SSH 防覆盖 rename、
  WorkspaceApplication.withProtectedFiles、PendingDiscard 指纹和保存失败否决直接保护用户数据。
- Native 宿主弱引用、挂载/停车/布局检查有实际生命周期；新路径未接通前不能删除。

## 复刻范围与已确定的差异

“吸收”以可观察语义和责任边界为单位，不是把 Electron/DOM 运行时搬到 Swift。

| 行为 | 本 Feature 的决定 |
| --- | --- |
| Focus / Selection / Anchor / Context / Hover 独立 | 采用；不建全局可写 SelectionStore |
| 三种范围选择算法 | 各自采用，不为代码复用强行同义 |
| Explorer / SCM / Tabs 右键 | 分别采用对应规则，Context 结束只撤销临时目标 |
| Dock 活动编辑器变化 → Explorer/SCM | 采用上游默认 Auto Reveal：匹配资源时替换相应树的 Selection/Focus，树不抢原生键盘；Files/Changes 不额外以 Displayed 常驻第二条灰底 |
| Explorer 隐藏 Selection、压缩多选展开所有段 | 保留 Bailey 可见求交及明确段/末级契约，记录非同义，不暗加模型树 |
| 单击 preserveFocus / 双击显式进入 | 保留 Bailey Browse/Open，无自动替换 preview-tab 生命周期 |
| Explorer 文件剪贴板与其它配置 | 保留现有私有剪贴板+字符串及项目/连接范围；富类型测试指无损保护系统剪贴板，不冒称已支持 Finder 文件 Paste；不新增多选修饰键设置、Tree type-ahead 或工作区文件操作 Undo 服务 |
| SCM 多选目录/资源和合法批量动作 | 采用；连接现有真实 Git runner，不造后端 |
| Graph 详情/父子 | 保留多展开/普通方向键仅移动游标，新增修饰键沿 DAG 父子导航 |
| Graph ref 双击 checkout | 不采用；保留显式菜单/原生确认 |
| Worktree 与十二主题色槽 | Bailey 自有契约，不伪称来自扩展或内置五色注册 |
| 标签 multi-selection 与批量 Close/Move | 采用；活动组/展示/实际输入独立，同组/同窗 Move-only |
| Dock Copy、跨窗转移、Electron preview editor | 不新增，当前没有文档/保存/原生会话克隆所有权 |
| 菜单期背景、Graph 展开底色、分屏整组描边 | 保持当前 docs/ui.md，不能用上游 CSS 推翻产品决定 |
| QuickInput/Switcher | 采用 commit/cancel/有效焦点恢复，不拷贝 DOM 保存/动画机制 |
| Settings | 不触及设置窗口布局或行样式；只有移除旧配置名字需更新其配置说明 |

VS Code 主仓库为 MIT；真正翻译或复制适用代码/测试表达时，同任务保留许可与更新 NOTICE。
Git Graph 扩展的 LICENSE 含不授予衍生作品发布/分发许可的限制；只独立实现行为，
不移植其算法、CSS、图标和测试资源，不把改写语言当成自动消除来源义务。
上游浏览器多窗口焦点不等于 AppKit firstResponder，系统语义仍由原生适配证明。

## 适用测试维度与核销方法

这是一份待执行的条件全集入口，不是已通过清单。新增场景随真实失败继续补充，
不以“跑过几个典型用例”或“整套 XCTest 全绿”代替逐项核销。
任务结果写回 todo，运行/失败/未覆盖条件写对应阶段证据，不维护第二份实时看板。

### 数据、状态与时序

| 维度 | 需覆盖的取值/边界 | 最终断言 |
| --- | --- | --- |
| Selection/Anchor | 空、1、连续、多岛；Anchor 已取消/消失；Focus 在集合内外；正反扩选、同侧回点、跨 Anchor、边界不移动；⌘A/Esc 后 Shift | Files/SCM/Tab 分别按自己的集合规则，AX 只反映真实 Selection |
| Context | 已选/未选/空白/压缩每段；鼠标/Control-click/键盘菜单；启用/禁用；取消/执行/重复键/卸载/失去 key | 一次动作、真实目标、无 Open/Activate；结束不残留临时关闭/删除权限 |
| 树结构 | 文件/目录/draft/改名输入；展开/折叠/过滤/exclude/重命名/移动/外部删除/同路径重建；缓存可读/部分失败/根失败 | 合法可见 identity、旧数据显示、操作不写错目录；不为压缩预读深层 |
| 压缩/共享使用方 | Files、Changes/staged/merge、历史文件；a/b/c 每段、留白、twistie、独立按钮、文字横滚与拖动 | 实际路径、正确展开、按钮不触发行事件、历史/Changes AX 不串线 |
| 文件副作用 | Copy/Cut/Paste/Move/Delete/New/Rename；父子重叠集合；同目录复制名序号；源/目标缺失、同名、软链/硬链、根外、权限失败、部分成功 | 磁盘字节/路径、防覆盖、未成功源保留、跨窗 File/Diff 路径与脏稿 |
| Git Changes | unborn/正常/detached；A/M/D/R/C/conflict/untracked/intent-to-add；同路径分两 Section；目录+叶子/过滤隐藏/跨 Section | 真实 index stages/bytes、HEAD、不相关文件不变；合法子集结果可说明 |
| Graph/导航 | 根/线性/分叉/双父/octopus/缺失父、真实提交与 Stash/Worktree；完整 SHA-1/SHA-256、跨屏滚动与已展开详情 | 游标指向有效可见节点，展开目标并滚动可见，不写 HEAD/index |
| Refs/特殊节点 | 本地/远端/别名/tag/annotated tag、同 SHA 多 refs；Stash 同 OID 不同 selector；Worktree 多路径/同 HEAD/移除/锁定/未提交 | 原生菜单目标、真实 refs/reflog/worktree 结果；无 ref 双击危险副作用 |
| Dock 多选/Move | 0/1/2/30+ 项、混合六类内容、1/2/3+ 组；同组前后/中间/选区内部/四边；整组/最后项/空组/无目标；取消/重复 drop/源组失效 | 一次最终布局、顺序/唯一身份/Selection、正确活动组；Move-only 不复制/跨窗转移 |
| 批量关闭 | 单项/集合内外；clean/dirty/正在保存；Save/Don't Save/Cancel/保存失败；file/diff/PTY/browser/tool 混合 | 顺序确认、取消即停、失败缓冲保留、未确认资源未释放、已完成项不伪回滚 |
| 暂态输入 | Palette 空/非空/无结果/50 结果边界、慢索引/目标改变；Switcher 空/1/N/目标删除/切项目/按住 Control/取消/失去 key | 不提前改真实显示或组选区；提交属于当前窗口项目；恢复不抢已有新输入 |
| 并发/刷新 | provider 晚到、乱序 Git/Files/历史结果、菜单中刷新、分页、快速三目标切换、关闭与重新挂载 | 只接受当前 owner 的有效结果，失效不跨机器回退，状态与已开 Diff 不串线 |

### 环境、呈现与原生结果

- macOS 15.6 与当前支持版本；Swift 6 / 当前 SDK；Debug、正式验收构建/签名。
  本机元数据为 macOS 27.2（26B5101f）、Xcode 27.2（27B5038j），不冒充最低系统实测。
- 本机、受控后端、获授权的真实 Windows SSH；健康/失联/重连/替换连接/切机器/同名根。
  backend stub 不等于 SSH 实测，断线须先证明真正断开，不借用或结束用户 master。
- 每种内容持焦点：Files/Changes/Graph/Projects、TextKit/IME/Find、Ghostty/Find、
  Browser 地址/正文/HTML input、Palette、Sheet、NSPopover、菜单；两个窗口交错 key。
  检查真实 firstResponder 与实际输入字节，不能只看 activeGroupID 或蓝框。
- 明/暗/自定义 Ghostty 明暗、切主题、字体最小/默认/最大、窄/常规/极宽、长中文/emoji/
  组合字符/空格/制表符/换行/同名与大小写路径；主题底色/描边/hover/context/dirty 各自组合。
  保持基本 AX 角色、名称、选中、展开和路径；一般 UI 改动不额外强制 VoiceOver 专项工程。
- 鼠标/Control-click/触控板/键盘/中键、中文/日文 IME；拖动阈值前后、按下/松开修饰键、
  中断与菜单嵌套；可用原生事件宿主证明的条件先自动化，真正硬件体验另记。
- 容量：Files/Changes 0/1/1k/10k，缓存模型可承受时继续 100k；深度 31/32/33；
  历史 29/30/31 及多页/1k+；12/13+ 轨、30+ Tabs；
  Diff 5 MiB−1/恰好/＋1 与文件 8 MiB 对应边界；大量 refs/批量事件与长时间重挂载。
  不为测试造另一套 UI 容量限制，也不将一次 100k 模型操作称为 100k 行原生 GUI 已验收。
- 外部剪贴板测试须可无损恢复原项目/全部类型，否则使用命名临时 NSPasteboard 做组件验证，
  系统富类型往返另记缺口；不能先毁掉用户剪贴板再宣称测试通过。

组合要求：有限可承受的组合尽可能跑尽；规模大时先确保每个取值、极值和已知故障都覆盖，
再系统扩展两两/多因素组合。不以“风险驱动抽样”删除本可执行的单项。
重点交互包括多岛+菜单+刷新、目录多选+filter+Stage、脏稿+批量关闭+切窗、
多选 Move+整组边缘+原生停车、历史分页晚到+SSH 重连、Palette 关闭+目标重挂载。

### 既有测试与执行入口

| 责任 | 现有宿主类 | 仅完整 App 能证明的补充 |
| --- | --- | --- |
| Files/行/菜单/Edit/真实文件 | FileTreeTests、PanelContextTests、FileTabPersistenceTests、NativeFileTabTests | SharedTreeUITests、WorkspaceFilesUITests |
| Git 集合/操作/历史/DAG | GitStatusModelTests、GitExecutionTests、GitUncommittedActionTests、NativeGitHistoryFileTests、NativeDiffTabTests、CommitGraphLayoutTests、GitGraphPaletteTests、GitGraphReferenceGroupTests、GitGraphWorktreePresentationTests、GitNativeDialogTests 及各实际操作类 | GitChangesUITests、GitGraphUITests、GitGraphGeometryUITests、GitHistoryUITests、GitDialogUITests、GitUncommittedUITests |
| Dock/关闭/窗口/Finder/恢复 | DockWorkspaceTests、DockFocusIntegrationTests、WindowOwnershipIntegrationTests、WindowCloseIntegrationTests、NativePaneRetentionIntegrationTests、NativeContentIdentityIntegrationTests、FinderDeliveryIntegrationTests、WorkspaceIdentityTests、SessionStoreTests | WorkspaceDockUITests、WorkspaceWindowsUITests、WorkspaceRetentionUITests |
| Palette/文件索引/配置 | ProjectFileIndexTests、DockWorkspaceTests、AppSettingsTests、AppIdentityTests | WorkspaceSmokeUITests、已有 Files/Git 的取消/真实输入用例 |
| 真实 SSH | SSHFileTreeLiveTests、SSHWindowsFileEventsTests、GitRemoteRefreshIntegrationTests 等须先核对本次环境授权 | 合法远端的真实 UI 行为不由本机 stub 替代 |

命令统一使用根 Makefile，不新增独立 shell 测试体系：

```sh
make test:FileTreeTests,PanelContextTests
make test:DockWorkspaceTests,DockFocusIntegrationTests,SessionStoreTests
make test:GitStatusModelTests,NativeGitHistoryFileTests,NativeDiffTabTests
make test:ui ONLY_TESTING=BaileyUITests/SharedTreeUITests
make build:dev
```

这些是后续实施命令，不是本轮已运行结果。共享树行修改补齐所有实际使用方的宿主测试；
本机 Dev build/test 不并行、不附着已有 Dev、不干扰正式 App；完整 GUI 仍需独占桌面焦点。
新增 API/文件时核对当前 Xcode 工程与实际 XCTest 枚举，不用测试类名存在冒充执行成功。

每个未覆盖条件在执行证据中逐项填写：条件/前置、尝试、阻塞原因、替代证据、潜在影响、
补验办法、是否阻塞本 task/phase。不能预先把最低系统、SSH 或物理设备写成“不可得”后跳过尝试。
必要条件缺失时不给无保留 Go。

## 本轮交付与后续门禁

本轮交付是现行 idea、P1～P5 的修订和本页独立源码依据；未把任何 task 标成 completed。
机械校验核对 todo 引用/标题锚点、Markdown 路径、测试类名、差异范围与 diff 空白。
它们只证明计划内部一致，不证明产品功能、系统菜单、视觉或网络验收。

本轮已运行 `feature_tool.py todo validate` 与 `git diff --check`，均通过；
补充机械检查确认 26 个任务均 pending、26 个短锚点一一对应、7 个本地 Markdown 链接可达、
计划引用的 XCTest 类均存在、28 个显式 VS Code 源码路径可在固定版本定位。
差异只在本 Feature，既有 audit 未改动。运行条件枚举并未转换为产品测试已通过。

实施时每 task 形成完整链：Red（可测试缺陷/新行为）→最小接入→同 task 删旧→
相称宿主/真实 GUI/最终副作用→当前文档→原子中文提交→todo 回写。
计划文件本地维护，不因实现提交自动把 Feature 证据一起入库；代码提交按 AGENTS 执行。
P1～P4 的数据保护、接入、旧路删除和文档不能延至 P5。

各 phase 真正完成后再运行 `feature_tool.py phase-complete` 与独立阶段审计。
本轮不创建伪 phase audit、不运行 phase-complete 冒充实现完成、不批准发布或推送。
