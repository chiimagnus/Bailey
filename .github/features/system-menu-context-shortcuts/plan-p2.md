# P2｜统一原生命令执行和右键目标生命周期

让 P1 已证实不一致的快捷键通过最短的 AppKit 正常路径执行，
不牺牲当前活动焦点、右键目标或 `⌘W` 已验收的原生菜单栏反馈。

## 方案与取舍

**以 P1 的实际结论为实施门槛**：AppKit 已经正确分发的命令不改。
对确实在右键菜单跟踪时被提前消费的应用命令，
优先在现有 `BaileyCommands`／`MainMenuPresentation` 边界恢复原始事件的正常分发，
只在确定必要时复用 `⌘W` 的默认 RunLoop 重投思路；
不能只触发动作、调用 `performActionForItem` 或绘制高亮来替代真实快捷键路径。
如果建立共享入口，必须在同一任务**取代**旧的 `pendingContextClose` 特例，
而不是新增一条可并行执行的路由；不引入全局事件 Tap、快捷键注册表或新的 FocusManager。

右键目标继续归属于现有 Dock／Files／Git 模型，系统菜单只在本次动作消费前取得它。
`NSApp.currentEvent` 的字符与组合键不等于动作已经执行：
目标的保留与清理应匹配实际有效命令和原生菜单跟踪结束时序，
不能因为按了一个形似路径快捷键的组合便永久保留失效目标。
原生 Edit 要先服从 Cocoa 第一响应者链；若 P1 证明 Files 的局部处理是必要例外，
仅保留它的最小事件作用域，不把其扩展成所有应用快捷键的第二通道。

## 任务

<a id="p2-t1"></a>
### P2-T1 已启用的应用命令只经系统菜单执行并反馈

- **位置**：`Bailey/App/BaileyApp.swift` 的 `BaileyCommands`、`MainMenuPresentation`，
  必要时 `Bailey/Shared/Tree/TreeRowStyle.swift` 的菜单跟踪边界；
  `Bailey/Workspace/WorkspaceWindowModel.swift` 仅在命令资格确有错误时调整。
- **实施**：根据 P1-T1 的事件证据修复应用级命令在上下文菜单展开时的入口，
  保留 SwiftUI `.keyboardShortcut` 的唯一注册和 `.disabled` 判定；
  不改正确的 `@FocusedValue`／第一响应者语义。若通用路径确实覆盖 `⌘W`，
  同步删除专用重投状态／重复监听，保留 Dock 的原生高亮和关闭次数约束。
  结合实际源代码重新核对 `⌘S`／查找、Panel／Project 切换、Git 全量暂存／提交、
  Diff 切换、Terminal／Browser 及 Window 命令，避免让右键背景项接管普通活动命令。
  更新 `docs/ui.md`、`docs/features/dock.md` 中真实改变的规则。
- **验证**：相同快捷键在普通模式、菜单展开、系统菜单鼠标点击三条路径只产生一次副作用；
  录屏核对首次原生高亮；禁用项不执行，快捷键仍可用于对应活动窗口；
  `⌘W` 的后台项、多选、连续关闭、保存确认与真实窗口关闭全部不回退。

<a id="p2-t2"></a>
### P2-T2 Files 的原生编辑命令与右键文件目标不再相互劫持

- **位置**：`Bailey/Files/FileTreePanel.swift` 的 `handleMenuKeyDown`／`dismissContextMenu`，
  `Bailey/Shared/Tree/TreeRowStyle.swift` 的 `ContextMenuClickView`／`TreeKeyboardView`，
  以及 `Bailey/Files/FileTreeModel.swift` 的右键选择与文件操作。
- **实施**：按 P1 的实测选择 AppKit 原生 responder／菜单动作；
  只保留 Files 右键时正确操作命中项所必需的局部拦截。
  清除任何重复应用级快捷键路由，并使 `⌘C`、`⌘X`、`⌘V`、Delete 与
  `⌘N`／`⌥⌘N` 的菜单结束时序能够正确恢复键盘焦点和选区。
  点击菜单与按键应走同一实际文件动作；同步 `docs/features/files.md`。
- **验证**：后台 Files 文件右键但终端仍为第一响应者时，
  复制／剪切／粘贴的是文件目标，首次按键也要核对系统原生菜单反馈；
  若动作正确却无原生反馈，不能作为本任务完成。菜单取消后普通 Edit 只作用于原第一响应者。
  新建进入准确的文件夹／紧凑目录段，粘贴与删除的磁盘副作用受原本的确认和远端身份限制；
  剪贴板多选、非法路径、无权限、空目录、失效目标及普通文本编辑不发生回归。

<a id="p2-t3"></a>
### P2-T3 Dock／Git 右键目标只在本次有效命令期间存在

- **位置**：`Bailey/UI/WorkspaceDockView.swift:finishTabContextMenu`、
  `Bailey/Git/GitPanel.swift:dismissContextChange`、
  `Bailey/Git/RecentCommitsView.swift:dismissContextRow`、
  `Bailey/App/BaileyApp.swift:FocusedPathActions`、
  `Bailey/Shared/Tree/TreeRowStyle.swift:PathMenuShortcut`；
  `DockWorkspaceModel`、`GitStatusModel` 仅在现有目标模型无法表达时改动。
- **实施**：保持 Dock Close 的组选区规则、Git Changes 当前仓库与节区规则、
  Git Graph 的历史文件／其它工作树／压缩目录目标。
  消除 P1 证明有问题的“只凭按键组合就保留目标”的逻辑；
  将失效清理放在原有菜单跟踪／实际消费位置，
  不为每个模块新增临时状态所有者。若原目标代码已正确工作则不改动。
  触及哪个模块就同步 `docs/features/dock.md` 或 `docs/features/git.md`，并移除被替代的旧路径。
- **验证**：第一次有效路径命令复制当前右键目标，第二次无菜单命令回到原选区；
  不可用／已失效命令不留下右键目标；跨工作树绝对与相对路径正确，
  Git index／提交和选区不会被路径复制污染；菜单退出、改项目、失焦、
  双窗口切换及快速重复按键不能错误消费旧上下文。

## 阶段验收

沿 P1 识别的**全部可达命令及目标场景**执行，不以本阶段列举的示例减少 P1 的验证范围。

- **原生事件**：每项已启用的应用级快捷键在普通与右键跟踪中均核对
  首次按键的菜单栏高亮、唯一动作、正确窗口；Files 原生 Edit 单独核对第一响应者与菜单动作。
- **最终结果**：文件内容、未保存编辑及确认、剪贴板、路径、Finder 本机资格、
  Git 暂存／提交字节、Diff 布局、终端输入及浏览器状态；
  禁用、撤销、取消、失败和重复触发后不发生多余副作用。
- **隔离与边界**：单项／多选、未选右键项、紧凑路径、特殊字符／Unicode、
  本地／SSH／其它工作树、双窗口／后台项目、输入法与文本编辑、
  Control-Click、菜单取消、快速连发、跨窗口时序及原生 Sheet；
  用安全临时文件与仓库，不能操作正式 Bailey 的用户数据。
- **性能与清理**：菜单打开／关闭不积累事件监听与悬挂目标，
  不重复投递命令、不额外重绘菜单；删除全部已被新路径替代的条件分支和测试假菜单，
  不更改快捷键布局或正常 UI 样式。

先运行受影响宿主测试（含 `AppIdentityTests`、`FileTreeTests`、`DockWorkspaceTests`、
`WindowCloseIntegrationTests`、Git 模型与真实临时仓库测试），
再运行 `make test`、`make build`、`make build:ui` 与
**独占图形会话**中的 `make test:ui`；逐项核对命令退出状态和签名。
GUI 必须包含真实菜单、首次原生高亮及最终副作用，不能以 `NSHostingMenu` 或 AX 枚举代替。
遇到 Git Graph 初始化历史列表失败，先核对夹具与真实前提，不能忽略失败或弱化断言。

每项可执行条件及其组合都应尽可能验收；
缺少可用的 macOS 15.6 环境、授权 SSH、独占图形会话或其它外部条件时，
逐项记录阻塞、风险、替代证据、补验方式及 Go／No-Go 影响，
不得把已跑通的子集写成完整通过。
本 Feature 只修改隔离 worktree；与正在进行的 Git 工作树变更共享文件时，
执行前复核最新 diff 与文件归属，禁止覆盖或暂存其他任务改动。
