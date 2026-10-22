# 执行前审查：工作区与焦点重构

本记录面向实施者，保存**原始三任务版计划**的执行前静态审查证据；不是产品实现审计，也不代替阶段 Gate。**2026-10-22 后已将任务分解为八项**，实时状态仅看 [todo.toml](todo.toml)，当前执行路径以 [P1](plan-p1.md)／[P2](plan-p2.md) 为准；本页的旧任务引用是历史语境，不作为现行任务清单。

## 后续设计复核（2026-10-22）

在不改变本页原始审查结论的前提下，按 [固定 Zed 源码修订](idea.md#设计依据与取舍) 重新审视架构：Zed 将选中、展开、预览、活动 Item 与真实焦点分别表示，但明确动作也可联动这些状态；这支持 Bailey 的“状态独立、动作意图显式”，**不支持引入 GPUI 式运行时或通用全局焦点管理器**。

原 P2-T1 同时迁移 Dock、Files、Git、Terminal、Editor、Diff、Browser 和 Palette，单次失败难以定位且无法按路径独立放行，现拆成 P2-T1～T5；P1 领域 API 的反向窗口依赖从 P1-T2 抽出为 P1-T3，避免应用路由和领域 API 同时产生不可区分的回归。**此次仅拆任务／修文档，未修改产品源代码或执行 GUI、XCTest。** 原始产品基线和 UI/UX 零变化硬门槛不变。

## 基线与方法

- **原始审查历史基线**：产品提交 `654cd5567df8a706f9b509b91e7ecdc1913d5608`；当时开始 HEAD `035e8ffc1787ad6ad71307612ae3c61e46160231`。2026-10-22 已将四个 Feature 提交重基到 `origin/main@097dac7a78b3308cde950d43446b635fcb1ff3d6`；本页原文件数量、哈希及源码阅读范围仅证明旧基线审查，**不能作为新 main 已被完整审查或完成原生 UI/UX 基线的证据**。现行实施基线见 [idea.md](idea.md#基线与证据)，P1-T1 应重新采集。
- 在已有独立 worktree 审查；不切换原 checkout、不创建分支、不修改产品代码。
- 先使用本地 CodeGraph，再以源码、现行文档和测试补齐动态入口、注入、原生响应者及最终副作用。未采用其它 Feature 的 audit 结论；历史 audit 不作为证明或实施前置条件。
- 逐文件枚举自有 Swift：89 个文件／40,944 行，其中 MaterialFileIcon.swift 为生成表；XCTest：51 个 Swift 文件／26,516 行。逐文件核对影响范围不等于逐行审计所有算法。
- 深读本次应用／窗口／焦点／保存／恢复的可达链路；其余文件核对类型、依赖和共享边界，未重审所有 Git 命令、Diff 算法、文本坐标和高亮内部实现。Vendor 生成 parser、第三方运行时及二进制资源只检查归属／接入，不声明数百万行第三方源码逐行通过。
- 以下“链路”表示阅读该文件与本次行为有关的实现及调用关系，不表示整文件所有函数逐行审计；“边界”表示影响范围核对。二者不能被机械清单或文件哈希替代。

审查开始时，按路径排序，对每个自有 Swift／测试文件计算内容 SHA-256，再对 `path + NUL + sha256 + LF` 拼接值计算总体指纹：

`5e44116989ee4bed59055a2e52fcb0c0fe5cda4d69fb339574d4ca69ce36d5fa`

结束前再次比对，避免移动基线或把其它任务改动当作本次证据。

## 已发现并写回计划的问题

| 问题 | 当前源码证据 | 本次修订 |
| --- | --- | --- |
| 应用所有者的创建时机原计划不明确 | BaileyApp 的 WindowRootView 创建每窗 manager；FinderService 在 willFinishLaunching 注册早到文件事件；main.swift 先分流 SSH helper | P1-T1 验证创建／认领次数，P1-T2 明确 delegate 持有同一应用对象并显式注入；helper 不启动 GUI 所有者 |
| State 保留值不等于构造副作用只执行一次 | TerminalManager.init 会读 store、消费恢复、登记并订阅退出；注入时机械使用 State(initialValue:) 会直接求值 | 增加真实宿主重复构造的最小验证；未复现前不宣称当前版本必然产生幽灵窗口，也不先加通用状态机 |
| 领域仍反向依赖完整窗口类型 | Project.syncFiles(in:)；GitStatusModel.syncSelectedProject(in:)；ContentView 和 GitPanel 两处 Retry 是后者入口 | P1 同任务收窄到项目及当前目标检查，保留异步身份／代次；Retry 不捕获过期项目 |
| 关闭弹窗不能仅从应用全局数组重新找窗口 | Project.closeSheetWindow 扫 activeManagers；新建／恢复走 makeProject，但测试也直接赋值或 append projects | 同任务移除全局扫描，所有项目安装路径接入所属窗呈现；读取当前附着窗口，不提前固定 nil，不回退后台 keyWindow |
| 漏掉独立原生弹窗 | BottomToolbarView 的 BranchSearchField 与 InstantPopoverPresenter；TunnelSettingsView 另有 Settings Sheet | P2 纳入分支搜索真实输入／快速重开；Settings／Sheet／NSPopover 不纳入工作区焦点栈 |
| “统一焦点”被扩大成管理所有文本框 | TerminalFindBar／ProjectsPanelView／WorkspaceChrome／FileTreePanel 各有局部 FocusState；EditorFind 使用 NSTextFinder；Git 对话框设置原生初始响应者 | 删除全输入角色枚举和每输入框 registry 要求；统一工作区许可与恢复，保留局部编辑／原生输入管理 |
| 行游标准备、自动取焦、视觉被混为一件事 | FileTreePanel.focusSelectedRow 与 GitPanel.focusGitChanges 都先准备行选择，再检查前台窗口；Palette 未就绪的屏蔽另有现成回归 | 明确分开状态更新和真正取焦；不能把新的统一前台 guard 提到局部状态更新前，或用其改变组标签样式 |
| 删除“重复守卫”没有替代前提 | TerminalHostView／SourceTextEditor 检查仍归当前宿主；Project／FileTab 有保存及机器保护；WindowChrome 转发 SwiftUI delegate | P1／P2 各列具体删除项与保留不变量；延迟闭包在最终 makeFirstResponder 前查询当前许可，不能缓存旧结果 |
| 把实际使用的数据字段当成兼容垃圾会串机器 | addSSHItems 仍创建 pinnedFile；SessionSnapshot.TabSnapshot.localFile 缺键有现行解释；restoreTab 据此选择后端 | 保留现存存储契约，不加新兼容壳，也不夹带破坏性数据迁移 |
| 类型迁移测试漏列多个真实调用方 | 自有测试中 20 类直接使用 TerminalManager，不止会话／窗口测试 | P1 两组命令包含全部 20 类，另覆盖 App 菜单／身份和远端生命周期；新类继续加入现有 target |
| socket 测试不能证明应用级服务装配正确 | RemoteLifetimeTests 的 handler 是自定义响应；GitInteractiveRebaseTests 实际创建自己的窗口并经 helper 握手；生产 BaileySSHService 是共享实例 | P1 补真实服务到会话的受控 socket 回归；fixture 的服务定位与窗口使用同一 owner，不能继续指向测试宿主另一个 owner；共享绑定结束后恢复 |
| 清理／提交／前置要求不一致 | 旧计划仍要求读历史 audit、计划本地不入库，并把过多环境作为开始迁移的准入 | 移除旧 audit 依赖；计划和脱敏证据按用户要求提交；受影响失败须诊断，缺环境不阻止独立工作但仍记录最终验收限制 |
| 焦点设计和验证存在过量规定 | 预定所有角色／所有输入接入新协作者；强制复制全套优化 XCTest | 不强制新 FocusManager 类型或角色框架；保留完整正式 make test，优化验证针对真实原生／actor 影响，不机械复制全套测试 |

关于 State，核对了本机 SDK 接口与 Apple 的[State 文档](https://developer.apple.com/documentation/swiftui/state)。本机 SDK 有特定 Observable 初始化重载，文档也提示初始化副作用问题；两者不能替代最低部署环境的真实运行验证。因此这里只把它列为装配必须验证的风险，不报告一个未经复现的当前产品缺陷。

## 删除、保留与另案边界

### 必须随替代同时删除

- P1：旧 TerminalManager 类型／文件、应用级可变静态状态及路由、activeManagers 公共窗口登记入口、每窗重复退出订阅、Project 全局扫描、两个刷新 API 对整窗类型的反向依赖。纯转换 helper 的 static 不属于此清理。
- P2：各处重复窗口级许可／恢复策略、窗口对具体原生控件类型的枚举与递归搜索、Browser 挂载轮询和被替代的旧接入。组件可以保留只查询唯一策略的 canFocus 回调；这不是双策略。
- 每项删除必须能指出替代入口及实际结果验证。没有发现旧 FocusManager 兼容 alias，不虚构可删除对象；不设最后统一清理 task。

### 仍有实际作用，不能笼统删除

- didCloseWindow：NSWindow 关闭通知与 SwiftUI 消失都可能调用清理；isQuitting：阻止最终整体快照被后续局部销毁覆盖。
- 表面仍属于当前宿主、有效可见区域、停车释放焦点、旧回调解除：这些来自真实重挂载，不是重复业务许可。
- 保存失败／保存中新编辑／关闭确认防重复／机器与连接目标校验；SSH token、端口和 PID 验证；剪贴板授权与控制字符拒绝。
- 原生 delegate 转发、AppKit field editor／NSTextFinder、局部改名防双提交、Find／Browser 重复请求计数、Git 最近键盘区域及列表等待首行。
- NSPopover.presentationGeneration：阻止旧关闭回调影响新呈现；其搜索重试只在同任务证明确有可靠挂载替代后删除，不顺带重写弹窗。
- 现有 TerminalBackendSurface 协议、SessionStore 与终端历史存储、SSH 普通透传及 Shell 自定义函数保护不是新的应用窗口兼容门面。

### 尚待单独验证，不夹带功能修复

`TerminalManager.isWorktreeInUse` 当前先按 project.panelContext.scope 过滤项目，随后才逐个检查 File／Diff 内容身份；而 SSH 项目可以放本机文件。现有 GitStatusModelTests 的使用保护用例覆盖项目根、符号链接、相邻路径和机器 scope，并未证明所有混合内容场景。P1 先保留算法并补特征证据，若确证漏查，单独定义缺陷及 Red→Green，不宣称重构已经修复。

`Project.panelRoot` 仍被 CommandPaletteView 用于当前本机搜索准备；不能仅因存在 PanelContext.resolvedRoot 就当成死 fallback 删除。它是否应统一异步根解析不属于本轮焦点／窗口职责迁移。

## 自有源文件核销

| 文件 | 层级 | 本次核对的职责 |
| --- | --- | --- |
| [Bailey/App/AppIdentity.swift](../../../Bailey/App/AppIdentity.swift) | 边界 | 设置／主题与启动装配边界 |
| [Bailey/App/AppSettings.swift](../../../Bailey/App/AppSettings.swift) | 边界 | 设置／主题与启动装配边界 |
| [Bailey/App/BaileyApp.swift](../../../Bailey/App/BaileyApp.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/App/FinderService.swift](../../../Bailey/App/FinderService.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/App/SettingsView.swift](../../../Bailey/App/SettingsView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/App/Theme.swift](../../../Bailey/App/Theme.swift) | 边界 | 设置／主题与启动装配边界 |
| [Bailey/App/main.swift](../../../Bailey/App/main.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Browser/BrowserView.swift](../../../Bailey/Browser/BrowserView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Editor/EditorFind.swift](../../../Bailey/Editor/EditorFind.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Editor/FileViewerView.swift](../../../Bailey/Editor/FileViewerView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Editor/MaterialFileIcon.swift](../../../Bailey/Editor/MaterialFileIcon.swift) | 生成 | 生成器归属；禁止手改，未逐项检查图标表 |
| [Bailey/Editor/NativeCodeTextView.swift](../../../Bailey/Editor/NativeCodeTextView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Editor/NativeTextLineIndex.swift](../../../Bailey/Editor/NativeTextLineIndex.swift) | 边界 | 坐标／高亮独立算法与生成资源 |
| [Bailey/Editor/SourceTextEditor.swift](../../../Bailey/Editor/SourceTextEditor.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Editor/SyntaxHighlightConfiguration.swift](../../../Bailey/Editor/SyntaxHighlightConfiguration.swift) | 边界 | 坐标／高亮独立算法与生成资源 |
| [Bailey/Editor/SyntaxHighlighting.swift](../../../Bailey/Editor/SyntaxHighlighting.swift) | 边界 | 坐标／高亮独立算法与生成资源 |
| [Bailey/Editor/TextCoordinateIndex.swift](../../../Bailey/Editor/TextCoordinateIndex.swift) | 边界 | 坐标／高亮独立算法与生成资源 |
| [Bailey/Files/FileTreeModel.swift](../../../Bailey/Files/FileTreeModel.swift) | 边界 | 树数据／后端及输入目标边界 |
| [Bailey/Files/FileTreePanel.swift](../../../Bailey/Files/FileTreePanel.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/CommitGraphLayout.swift](../../../Bailey/Git/CommitGraphLayout.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/DiffEngine.swift](../../../Bailey/Git/DiffEngine.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/DiffNativeSurface.swift](../../../Bailey/Git/DiffNativeSurface.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/DiffSyntaxHighlighter.swift](../../../Bailey/Git/DiffSyntaxHighlighter.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/DiffTextView.swift](../../../Bailey/Git/DiffTextView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/DiffViewerView.swift](../../../Bailey/Git/DiffViewerView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/GitBranchDialog.swift](../../../Bailey/Git/GitBranchDialog.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitCommandExecution.swift](../../../Bailey/Git/GitCommandExecution.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitCommitDialog.swift](../../../Bailey/Git/GitCommitDialog.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitFileEventWatcher.swift](../../../Bailey/Git/GitFileEventWatcher.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitHistoricalFileLocator.swift](../../../Bailey/Git/GitHistoricalFileLocator.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitPanel.swift](../../../Bailey/Git/GitPanel.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/GitStashDialog.swift](../../../Bailey/Git/GitStashDialog.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitStatusModel.swift](../../../Bailey/Git/GitStatusModel.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Git/GitTagDialog.swift](../../../Bailey/Git/GitTagDialog.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/GitUncommittedDialog.swift](../../../Bailey/Git/GitUncommittedDialog.swift) | 边界 | 原生对话框／命令／刷新／纯数据算法边界 |
| [Bailey/Git/RecentCommitsView.swift](../../../Bailey/Git/RecentCommitsView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Remote/BaileySSHBridge.swift](../../../Bailey/Remote/BaileySSHBridge.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Remote/BaileySSHPassthrough.swift](../../../Bailey/Remote/BaileySSHPassthrough.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Remote/RemoteCommands.swift](../../../Bailey/Remote/RemoteCommands.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/RemoteConnection.swift](../../../Bailey/Remote/RemoteConnection.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Remote/RemotePaneHeaderView.swift](../../../Bailey/Remote/RemotePaneHeaderView.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/RemoteReadOnlyBanner.swift](../../../Bailey/Remote/RemoteReadOnlyBanner.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/SSHHostWorkspaces.swift](../../../Bailey/Remote/SSHHostWorkspaces.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Remote/SSHWorkspaceBackend.swift](../../../Bailey/Remote/SSHWorkspaceBackend.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/Tunnels/TunnelDefinition.swift](../../../Bailey/Remote/Tunnels/TunnelDefinition.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/Tunnels/TunnelManager.swift](../../../Bailey/Remote/Tunnels/TunnelManager.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Remote/Tunnels/TunnelSettingsView.swift](../../../Bailey/Remote/Tunnels/TunnelSettingsView.swift) | 边界 | 独立远端效果／状态呈现；不迁移其内部算法 |
| [Bailey/Shared/Tree/TreeDisplayModel.swift](../../../Bailey/Shared/Tree/TreeDisplayModel.swift) | 边界 | 共享行数据与呈现 |
| [Bailey/Shared/Tree/TreeRowStyle.swift](../../../Bailey/Shared/Tree/TreeRowStyle.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| `Bailey/Support/FPSCounter.swift`（仅历史基线 `097dac7`，现已删除） | 历史边界 | 旧计时／主线程回调已随 FPS 功能移除；可通过 `git show 097dac7:Bailey/Support/FPSCounter.swift` 查原版 |
| [Bailey/Support/MainActorIsolation.swift](../../../Bailey/Support/MainActorIsolation.swift) | 边界 | 既有计时／主线程回调边界 |
| [Bailey/Terminal/BaileyTerminalView+Ghostty.swift](../../../Bailey/Terminal/BaileyTerminalView+Ghostty.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/BaileyTerminalView.swift](../../../Bailey/Terminal/BaileyTerminalView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/BarkPushService.swift](../../../Bailey/Terminal/BarkPushService.swift) | 边界 | 历史／推送／字体／进程查询边界 |
| [Bailey/Terminal/ProcessWorkingDirectory.swift](../../../Bailey/Terminal/ProcessWorkingDirectory.swift) | 边界 | 历史／推送／字体／进程查询边界 |
| [Bailey/Terminal/TerminalCursorSettings.swift](../../../Bailey/Terminal/TerminalCursorSettings.swift) | 边界 | 历史／推送／字体／进程查询边界 |
| [Bailey/Terminal/TerminalFind.swift](../../../Bailey/Terminal/TerminalFind.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/TerminalFindBar.swift](../../../Bailey/Terminal/TerminalFindBar.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/TerminalFont.swift](../../../Bailey/Terminal/TerminalFont.swift) | 边界 | 历史／推送／字体／进程查询边界 |
| [Bailey/Terminal/TerminalHistory.swift](../../../Bailey/Terminal/TerminalHistory.swift) | 边界 | 历史／推送／字体／进程查询边界 |
| [Bailey/Terminal/TerminalHostView.swift](../../../Bailey/Terminal/TerminalHostView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/TerminalNotificationService.swift](../../../Bailey/Terminal/TerminalNotificationService.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/TerminalSession.swift](../../../Bailey/Terminal/TerminalSession.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Terminal/TerminalSurface.swift](../../../Bailey/Terminal/TerminalSurface.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/CommandPaletteView.swift](../../../Bailey/UI/CommandPaletteView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Components/BottomToolbarView.swift](../../../Bailey/UI/Components/BottomToolbarView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Components/OverlayScrollbarView.swift](../../../Bailey/UI/Components/OverlayScrollbarView.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Components/Tooltip.swift](../../../Bailey/UI/Components/Tooltip.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Components/VisualEffectView.swift](../../../Bailey/UI/Components/VisualEffectView.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Components/WindowChrome.swift](../../../Bailey/UI/Components/WindowChrome.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Components/WorkspaceChrome.swift](../../../Bailey/UI/Components/WorkspaceChrome.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/ContentView.swift](../../../Bailey/UI/ContentView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Panels/PanelHeader.swift](../../../Bailey/UI/Panels/PanelHeader.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Panels/PanelSectionHeader.swift](../../../Bailey/UI/Panels/PanelSectionHeader.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Panels/PanelTypography.swift](../../../Bailey/UI/Panels/PanelTypography.swift) | 边界 | 无状态呈现／命中／滚动辅助 |
| [Bailey/UI/Panels/ProjectsPanelView.swift](../../../Bailey/UI/Panels/ProjectsPanelView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Panels/ToolPanelView.swift](../../../Bailey/UI/Panels/ToolPanelView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Panes/PanelContentView.swift](../../../Bailey/UI/Panes/PanelContentView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/Panes/TabSwitcherView.swift](../../../Bailey/UI/Panes/TabSwitcherView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/UI/WorkspaceDockView.swift](../../../Bailey/UI/WorkspaceDockView.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/DockWorkspaceModel.swift](../../../Bailey/Workspace/DockWorkspaceModel.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/LocalWorkspaceBackend.swift](../../../Bailey/Workspace/LocalWorkspaceBackend.swift) | 边界 | 后端及纯值边界 |
| [Bailey/Workspace/PaneTab.swift](../../../Bailey/Workspace/PaneTab.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/PanelContext.swift](../../../Bailey/Workspace/PanelContext.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/Project.swift](../../../Bailey/Workspace/Project.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/ProjectFileIndex.swift](../../../Bailey/Workspace/ProjectFileIndex.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/SessionStore.swift](../../../Bailey/Workspace/SessionStore.swift) | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| `Bailey/Workspace/TerminalManager.swift`（仅存在于 P1 实施前基线 `097dac7`；现行窗口类型见 [WorkspaceWindowModel.swift](../../../Bailey/Workspace/WorkspaceWindowModel.swift)） | 链路 | 沿本次入口／状态／焦点或生命周期执行链核对 |
| [Bailey/Workspace/WorkspaceBackend.swift](../../../Bailey/Workspace/WorkspaceBackend.swift) | 边界 | 后端及纯值边界 |

## 测试影响核销

全部 51 个测试文件均枚举了目标归属、测试入口及与本次代码的依赖。直接引用旧类型的 20 类须在 P1 迁移并运行，已核对其夹具／相关断言；窗口、焦点、保存、身份和原生保留测试追到实际响应者／写盘／资源结果。其它类只作相邻覆盖与最终完整 XCTest 的范围核对，不宣称其所有算法断言逐行审计，也未在本轮执行。

| 测试文件 | 本次关系 |
| --- | --- |
| [BaileyTests/Integration/Files/FileTreeTests.swift](../../../BaileyTests/Integration/Files/FileTreeTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Files/SSHFileTreeLiveTests.swift](../../../BaileyTests/Integration/Files/SSHFileTreeLiveTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitBranchActionTests.swift](../../../BaileyTests/Integration/Git/GitBranchActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitCommitActionTests.swift](../../../BaileyTests/Integration/Git/GitCommitActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitExecutionTests.swift](../../../BaileyTests/Integration/Git/GitExecutionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitRemoteBranchActionTests.swift](../../../BaileyTests/Integration/Git/GitRemoteBranchActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitStashActionTests.swift](../../../BaileyTests/Integration/Git/GitStashActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitStatusModelTests.swift](../../../BaileyTests/Integration/Git/GitStatusModelTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/Integration/Git/GitTagActionTests.swift](../../../BaileyTests/Integration/Git/GitTagActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitUncommittedActionTests.swift](../../../BaileyTests/Integration/Git/GitUncommittedActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitWorkspaceActionTests.swift](../../../BaileyTests/Integration/Git/GitWorkspaceActionTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/GitWorkspaceSSHTests.swift](../../../BaileyTests/Integration/Git/GitWorkspaceSSHTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Git/SSHGitRecoveryLiveTests.swift](../../../BaileyTests/Integration/Git/SSHGitRecoveryLiveTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Remote/RemoteCommandsTests.swift](../../../BaileyTests/Integration/Remote/RemoteCommandsTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Remote/RemoteLifetimeTests.swift](../../../BaileyTests/Integration/Remote/RemoteLifetimeTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Settings/AppSettingsTests.swift](../../../BaileyTests/Integration/Settings/AppSettingsTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Workspace/PanelContextTests.swift](../../../BaileyTests/Integration/Workspace/PanelContextTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/Integration/Workspace/ProjectFileIndexTests.swift](../../../BaileyTests/Integration/Workspace/ProjectFileIndexTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Integration/Workspace/SessionStoreTests.swift](../../../BaileyTests/Integration/Workspace/SessionStoreTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift](../../../BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/App/AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Editor/EditorNavigationTests.swift](../../../BaileyTests/NativeUI/Editor/EditorNavigationTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Editor/EditorTextInputTests.swift](../../../BaileyTests/NativeUI/Editor/EditorTextInputTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Editor/FileTabTests.swift](../../../BaileyTests/NativeUI/Editor/FileTabTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift](../../../BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Git/DiffTabTests.swift](../../../BaileyTests/NativeUI/Git/DiffTabTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Git/GitBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitBranchDialogTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Git/GitCommitDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitCommitDialogTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitExternalRefreshTests.swift](../../../BaileyTests/NativeUI/Git/GitExternalRefreshTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitHistoryFileTests.swift](../../../BaileyTests/NativeUI/Git/GitHistoryFileTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitInteractiveRebaseTests.swift](../../../BaileyTests/NativeUI/Git/GitInteractiveRebaseTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitRefReplacementTests.swift](../../../BaileyTests/NativeUI/Git/GitRefReplacementTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitRemoteBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitRemoteBranchDialogTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitStashDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitStashDialogTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitTagDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitTagDialogTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/GitWorkspaceMenuTests.swift](../../../BaileyTests/NativeUI/Git/GitWorkspaceMenuTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift](../../../BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift](../../../BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift](../../../BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/Unit/App/AppIdentityTests.swift](../../../BaileyTests/Unit/App/AppIdentityTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Editor/HighlightQueryCacheTests.swift](../../../BaileyTests/Unit/Editor/HighlightQueryCacheTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Editor/TextCoordinateIndexTests.swift](../../../BaileyTests/Unit/Editor/TextCoordinateIndexTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Git/CommitGraphLayoutTests.swift](../../../BaileyTests/Unit/Git/CommitGraphLayoutTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Git/DiffEngineTests.swift](../../../BaileyTests/Unit/Git/DiffEngineTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Remote/TunnelStoreTests.swift](../../../BaileyTests/Unit/Remote/TunnelStoreTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Terminal/BarkPushServiceTests.swift](../../../BaileyTests/Unit/Terminal/BarkPushServiceTests.swift) | 相邻边界／Feature 完整回归；不因本轮新增独立测试体系 |
| [BaileyTests/Unit/Workspace/DockWorkspaceTests.swift](../../../BaileyTests/Unit/Workspace/DockWorkspaceTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/WorkspaceUI/Tabs/WorkspaceContentIdentityTests.swift](../../../BaileyTests/WorkspaceUI/Tabs/WorkspaceContentIdentityTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift](../../../BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/WorkspaceUI/Windows/WorkspaceWindowCloseTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowCloseTests.swift) | P1 直接类型使用方；保留既有行为断言 |
| [BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift) | P1 直接类型使用方；保留既有行为断言 |

## 文档、工程和非自有代码

- **规则与架构**：AGENTS、CONTRIBUTING、docs/README、architecture、standards、ui、testing、development；核对 macOS 范围、真实所有者、原生适配和关闭保存边界。本轮只澄清 architecture 的焦点边界，未写成已经实施。
- **功能归属**：docs/features 下全部 13 页分别核对入口、约束和本计划是否触及；dock／session-restore／projects／settings／terminal／ssh 属于 P1，files／git／editor／diff／browser／command-palette 及 dock／terminal 属于 P2。tunnels 保持独立应用服务与 Settings 原生输入，不迁入工作区焦点管理。
- **用户／治理入口**：README 中英、SECURITY、NOTICE、release、signing、PR 模板及两个 Vendor README 核对导航／归属／隔离与发布边界，不重写无关说明。
- **构建／测试消费**：Makefile、Bailey.xcodeproj、Bailey scheme、Package.resolved、Info.plist、CI／Release workflow；后续仍使用现有工程／target。CI 忽略 .github/features 不能证明计划合法，本轮另查计划链接和锚点。
- **Shell／资源**：shell-integration/zsh/.zshenv、main.swift 的 ssh 分流、工程 ssh symlink 打包链；生成图标回到 scripts/generate-material-file-icons.ts，字体／本地化／图标／查询保留原归属。
- **Vendor／资产／其余配置**：全仓 manifest 中逐项枚举，归属和接入范围核对；生成 parser／第三方内部算法、二进制字体和图标视觉内容未逐行／逐像素重审。不因它们存在旧平台符号而加入本 Feature 删除清单。
- **其它 Feature 资料**：枚举目录以避免漏掉当前计划，但不读取旧 audit 内容或把其它 Feature 的任务引入本次。历史文件保留原语境，不全局替换类型名。

## 验证边界

本轮是执行前审查，仅允许静态文档／计划检查。没有产品编译、XCTest、GUI／实机 SSH、系统通知、Bark、安装或重启结果；本记录不代表产品 Gate。实际验证命令与结果在静态复核完成后追加，原有 3 个实施任务保持 pending。

静态验证记录：

- feature_tool 的 todo validate 退出 0；3 个任务仍为 pending，任务锚点存在。
- 现行文档与本 Feature 共 34 个 Markdown 页面，392 个相对链接／锚点检查无错误；不把远端 URL 和历史 Feature 当作已完成检查。
- 计划选择的 XCTest 类均存在；直接引用旧类型的 20 类全部进入 P1 验证集合。8 个不同 Make 入口／选择命令 dry-run 退出 0；没有实际执行构建或测试。
- Neat Freak exhaustive 复核退出 0，重新枚举 738 个当前路径；其默认 30 页文档候选无本地断链，Feature 页另由上项补查。清单枚举不代表所有文件语义审计通过。
- 再次计算 140 个自有 Swift／测试文件的内容指纹，与本轮开始完全一致；产品源码和测试未改。提交前同时检查 staged diff 的空白错误与文件范围。
