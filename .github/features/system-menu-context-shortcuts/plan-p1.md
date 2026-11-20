# P1｜确认原生分发边界与失败范围

交付可复现的「首次按键 → 系统菜单反馈 → 实际结果」证据，以及每类命令的目标归属。
不预先设计新的快捷键路由；没有证据证明需要改动的路径保持原样。

## 方案与依据

当前入口有三类，不能直接套用 `⌘W` 的实现：

- 应用级命令在 `Bailey/App/BaileyApp.swift` 的 `BaileyCommands` 中注册；
  仅 Dock 的 `Close Panel` 在 `MainMenuPresentation.pendingContextClose` 中暂存并重投原始事件。
- `Bailey/Shared/Tree/TreeRowStyle.swift` 的 `ContextMenuClickView` 监听原生菜单跟踪；
  `Bailey/Files/FileTreePanel.swift` 仅为 Files 剪切／复制／粘贴／删除使用局部按键处理。
- `FocusedPathActions`、`DockWorkspaceModel.closeTarget`、Files／Git 的局部右键目标与
  `WorkspaceWindowModel` 负责命令目标；`NSApp.currentEvent` 的按键匹配只用来短暂保留这些目标。

AppKit 的 [`postEvent`](https://developer.apple.com/documentation/appkit/nsapplication/postevent%28_%3Aatstart%3A%29)
只保证事件进入队列；[`performKeyEquivalent`](https://developer.apple.com/documentation/appkit/nsmenu/performkeyequivalent%28with%3A%29)
与 [`performActionForItem`](https://developer.apple.com/documentation/appkit/nsmenu/performactionforitem%28at%3A%29)
也不能被当作「真正经过系统快捷键分发」的等价证据。
先在完整 App 的原生菜单跟踪中判明可用路径，
再决定 P2 能否复用 AppKit 自身行为、是否仅需消除局部拦截，
或必须将少量已命中的原始事件延后交回默认 RunLoop。

## 任务

<a id="p1-t1"></a>
### P1-T1 取得首次按键的真实事件与视觉证据

- **位置**：`BaileyCommands`／`MainMenuPresentation`、`ContextMenuClickView`、
  `WorkspaceDockView.finishTabContextMenu`、`FileTreePanel.handleMenuKeyDown`、
  `GitPanel`／`RecentCommitsView` 的右键目标。
- **实施**：隔离 Bailey Dev 对比「正常按快捷键」与「右键菜单展开后的第一次按键」；
  记录是否到达系统菜单命令、原生菜单栏短暂高亮、菜单结束时序、第一响应者、
  执行次数及磁盘／剪贴板／Git 的最终结果。仅在现有测试无法判定时加临时事件追踪，
  实验结束即删除，不建立常驻监听或第二套追踪框架。
- **样例**：Dock 后台 `⌘W`；Files 目录 `⌘N`、文件 `⌥⌘C`／`⌘C`；
  Git Changes／Graph 路径复制；Git `⇧⌘Y`、`⌘↩`、Diff `⌥⌘U`；
  以及右键期间的活动命令 `⌘S`、`⌘P`、`⌘T` 和不可用命令。
- **判据**：对每项区分「键已被消费」「动作成功」「菜单栏首次高亮」；
  明确哪些已由 AppKit 正确处理、哪些被提前执行或局部监听拦截，以及
  哪些原生编辑动作必须经第一响应者。若实验没有命中预期入口，不以重试相同方案代替调查。

<a id="p1-t2"></a>
### P1-T2 固定命令目标与过期上下文的回归前提

- **位置**：`BaileyTests/App/AppIdentityTests.swift`、`BaileyTests/Files/FileTreeTests.swift`、
  `BaileyTests/Workspace/DockWorkspaceTests.swift`；
  `BaileyUITests/Workspace/WorkspaceDockUITests.swift`、
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`、`BaileyUITests/Files/SharedTreeUITests.swift`、
  `BaileyUITests/Git/GitChangesUITests.swift`、`BaileyUITests/Git/GitGraphUITests.swift`。
- **实施**：对照 `FocusedPathActions`、`WorkspaceWindowModel.newItem`、
  `GitPanel.focusedStageAllAction/focusedCommitAction` 和
  `GitPanel.dismissContextChange`、`RecentCommitsView.dismissContextRow` 等目标清理路径，
  明确**右键目标优先**与**活动内容／第一响应者优先**的命令集合。
  仅为 P1-T1 证明的失败补充可复现的 Red 用例，夹具必须先证明菜单项存在、启用状态和目标身份正确；
  不把已有正确行为重写为重复测试。
- **判据**：禁用或没有匹配菜单项的快捷键不执行，也不能让旧目标流入下次命令；
  右键未选中的文件、多选集合、紧凑目录、Git 其它工作树文件、远端资源均命中正确身份；
  取消菜单或切换窗口后下一次普通命令恢复当前活动／第一响应者语义。

## 阶段验收

- **命令类别**：Panel／Project／File／Edit／Terminal／Browser／Window 已注册的快捷键，
  分别检查已启用、禁用、只属于第一响应者、以及右键菜单显示 `.badge` 的场景。
- **菜单与目标**：Dock 工具／文件标签、同组多选与选区外；
  Files 根／文件／紧凑目录及多选；Git Changes 的不同分区与标题；
  Git Graph 历史文件、工作树文件、紧凑目录及多选；
  普通系统菜单、右键菜单及 Control-Click。
- **上下文变化**：同窗不同分组、双窗口与设置窗口、活动／后台项目、
  本机／SSH（含 SSH 项目中的本机文件）、菜单取消与重复右键、
  按键重复／连发、菜单失效及目标删除；终端和原生编辑器分别持有第一响应者。
- **可观察结果**：首次按键录屏与没有弹出菜单的对照；
  快捷键动作及剪贴板、真实磁盘内容、Git index／提交、保存确认的最后结果，
  不把一次方法调用或 AX 菜单存在当成完成。

在独占图形会话使用 `make test:ui ONLY_TESTING="BaileyUITests/类名/方法名"`
复现真实菜单；宿主用 `make test:AppIdentityTests,FileTreeTests,DockWorkspaceTests`
核对模型，`make build:ui` 核对 UI Test Target。
对最低 macOS 15.6、当前 macOS 与不同输入法等适用但不可执行的环境，
逐项记录实际阻塞、替代证据、回补条件及是否阻塞阶段结论。
若首次原生反馈无法在允许的 AppKit 路径中实现，保留问题为未解，
不得通过假高亮或改变用户目标来通过本阶段。
