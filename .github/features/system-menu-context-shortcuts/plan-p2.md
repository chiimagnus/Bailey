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
普通 Edit 仍服从 Cocoa 第一响应者链；Files 右键期间局部编辑按键由本次
`NSMenuItem.keyEquivalent` 执行已启用的文件动作，不抢第一响应者或要求顶部 Edit 高亮。
不新增菜单委托、目标映射、事件重投或局部 `NSEvent` 监听。

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
### P2-T2 核对 Files 局部编辑与原生 Edit 的边界

- **决定**：在 Files 右键菜单的 Cut／Copy／Paste／Delete 上直接注册局部
  `.keyboardShortcut`，删除 `FileTreeRow.handleMenuKeyDown` 和 `ContextMenuClickView`
  对这些按键的重复监听。应用级命令仍只由系统主菜单注册。
- **验收**：原生菜单消费按键，无额外系统提示音，执行一次正确的文件操作；
  右键目标、多选、禁用状态、取消菜单后的键盘焦点及本机／SSH 身份规则不变。
  普通 Edit 仍归原第一响应者，不要求 Files 局部动作触发顶部 Edit 高亮。
- **依据**：旧版 `.badge` 只显示组合键，不产生菜单的 `keyEquivalent`；
  局部监听虽能执行动作，系统却仍响未处理按键提示音。
  在隔离 Bailey Dev 中改用 `.keyboardShortcut` 后已确认生成原生 `keyEquivalent`，
  用户实测无提示音。

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

<a id="p2-t4"></a>
### P2-T4 合并同一次菜单跟踪的状态

删除分散的生命周期字段和重复判定；保留原事件重投与三个时点的资格校验。
复测原生反馈、关闭一次、取消、Files 普通复制和 Git 右键路径。

<a id="p2-t5"></a>
### P2-T5 删除文件新建中无间隔的重复取证

同一次同步接令只读取一次面板与树身份；不删除跨异步间隔的保护。
Files 局部编辑只比较真实 key window，关闭回调直接交给树模型。
复测草稿、磁盘目标、项目切换和真实剪贴板，不改变 Files 局部 Edit 规则。

<a id="p2-t6"></a>
### P2-T6 清理重复验收步骤

去掉不能证明实际效果的断言、重复操作和重复计划条目。
保留普通键、右键快捷键、鼠标菜单、禁用和取消恢复的区别；重跑改过的用例。

<a id="p2-t7"></a>
### P2-T7 删除重复失效的 SwiftUI 环境闭包

使用 SwiftUI 的类型化环境注入已有菜单对象。核对构建警告消失，并复测共享树、
菜单取消和隔离窗口；不新增状态所有者或转发对象。

## 阶段验收

复用 [P1 验收矩阵](plan-p1.md#阶段验收)及[需求验收](idea.md#验收)：
对照普通与右键期间应用级命令的首次原生高亮、唯一动作和实际副作用。
Files 局部 Edit 只核对右键目标、原第一响应者及文件结果，不要求主菜单闪亮。
补查特殊路径、原生 Sheet、Finder 本机资格、
Diff 布局及终端／浏览器状态；菜单结束后无残留监听或目标，不改变正常界面。

在隔离工作树先跑定点宿主测试，再运行 `make test`、`make build`、`make build:ui`。
`make test:ui` 只在独占图形会话用 Bailey Dev 和临时夹具运行。
核对实际测试数、退出码和签名；Git Graph 必须先证明真实历史已加载。
未测条件及其放行影响如实保留在 [P2 审计](audit-p2.md)，不以构建、AX 枚举或子集通过代替验收。
