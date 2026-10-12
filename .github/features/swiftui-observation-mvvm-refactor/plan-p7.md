# P7：Swift 6、现代 SwiftUI 与全项目验收收口

**Goal：** 在 P1～P6 已完成真实架构迁移的前提下，落实 Swift 6 语言模式与严格并发检查，更新适用的现代 SwiftUI／Foundation API，最后只读核对全项目 MVVM + Observation 与运行行为的交付质量。

**Non-goals：** 不引入新的独立构建系统、SwiftPM Target、第三方状态管理框架或数据格式；不在最终任务集中删除积压的旧代码、不擅自安装／重启正式 Kero、不无故提高最低 macOS 版本。

**Approach：** 使用 P1-T1 真实 Swift 6 诊断及本阶段再次编译定位根因，优先解决 SSH 进程与后台文件 IO 的并发边界，再修原生对象跨 actor 生命周期；两条边界独立验证后切换 Xcode App/Test Target 到 Swift 6。与架构迁移无关的纯 API 更新只做语义等价的可验证修改。最后检查全仓消费者链和证据，任何此前遗漏的旧路径直接返回对应所属 Task 补齐，而不是新增一个大扫除 Task。

**Acceptance：** Xcode App 和 XCTest 实际在 Swift 6 语言模式成功构建、运行，严格验签；真实 UI 的状态／焦点／保存／远端行为符合 `idea.md`；不再通过旧 Combine 嵌套广播支撑已经换到 Observation 的界面；生产旧路径均已在各自变更任务内清理。

**Rules：** `AGENTS.md`、`docs/PERFORMANCE.md`、`docs/SECURITY.md`、`docs/RELEASE.md`、`docs/DEPENDENCIES.md` 是边界；只按当前部署目标选择可用 API，不靠 `nonisolated(unsafe)`、无证据的 `@unchecked Sendable` 或关掉严格诊断求通过；保留 Ghostty、WKWebView、TextKit 的必要原生适配。

---

<a id="p7-t1"></a>
## P7-T1 SSH、Git 和文件后端的 Swift 6 并发边界收敛

**Files／源码锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection.runSSH`、`kero/Remote/SSHWorkspaceBackend.swift`（后台进程执行）、`kero/Remote/KeroSSHBridge.swift`（socket／worker queue）、`kero/Remote/RemoteCommands.swift`、`kero/Workspace/LocalWorkspaceBackend.swift`、`kero/Workspace/WorkspaceBackend.swift::WorkspaceBackend`、`kero/Git/GitCommandExecution.swift`、`KeroTests/RemoteCommandsTests.swift`、`KeroTests/RemoteLifetimeTests.swift`、`KeroTests/GitExecutionTests.swift`。

**当前可达链：** SSH 的远端进程 runner 包含 `DispatchQueue.global` 包裹同步 `ProcessRemoteCommandRunner.run`；`KeroSSHBridge` 有专用 socket/worker queue；`WorkspaceBackend: Sendable` 是文件／Git／SSH 共同依赖的真实跨 actor 协议。

**实现：** 针对 P1 诊断列出的真实 Sendable、非隔离 actor、闭包捕获及进程回调问题，在具体 runner owner 修正隔离；可用结构化并发替换**语义等价**的旧 GCD 包装，但进程等待、stdout/stderr 同步排空、超时取消和 SSH socket 的线程要求必须先实测。仍需保留的 GCD 说明其真实平台／协议边界；删除取代的旧 dispatch helper 和多余包装，**同 Task 不留下可达的双路进程执行实现**。不为了 Swift 6 把密钥、路径、远端输出写进新诊断日志，也不通过扩大 `@MainActor` 把阻塞调用搬到 UI 线程。

**验证：** 使用 P1 的相同受控 Swift 6 编译覆盖命令核对这部分诊断已消失；`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/RemoteCommandsTests`、`make test ONLY_TESTING=KeroTests/GitExecutionTests`；覆盖进程超时、字节输出、异常、SSH 断线、错误状态及 local/remote scope。真实 SSH 仅在用户已有授权的测试 master 可用时运行，不绕过认证。默认工具链下 `make build`。

**提交：** 同类后端并发根因、真实 IO 结果测试和被替代分发代码删除原子提交。

---

<a id="p7-t2"></a>
## P7-T2 终端、编辑器与 WebKit 的 Swift 6 actor／delegate 边界

**Files／源码锚点：** `kero/Terminal/TerminalSession.swift`、`kero/Terminal/KeroTerminalView+Ghostty.swift`、`kero/Terminal/TerminalSurface.swift::TerminalBackendSurface`、`kero/Terminal/TerminalFind.swift`、`kero/Editor/SourceTextEditor.swift`、`kero/Editor/FileViewerView.swift`、`kero/Git/DiffViewerView.swift`、`kero/Browser/BrowserView.swift::BrowserTab`、`kero/Support/FPSCounter.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前可达链：** `TerminalSession`、`FileTab`、`DiffTab` 与 `BrowserTab` 是长寿命对象，其中终端事件、NSTextView delegate、WKNavigationDelegate／KVO、CADisplayLink 通过原生回调到达 `MainActor`；P4、P6 迁移 Observation 后仍需要这些原生边界正确隔离。

**实现：** 按 Swift 6 诊断和真实回调线程修正 `@MainActor`／`nonisolated`／`Sendable`，使用 Swift Concurrency 或原生事件适配把 UI 更新明确送到正确 actor；谨慎处理 `NSObject` delegate 与原生资源析构，避免强引用循环和视图重建时重复连接。编译允许且不损害内核生命周期时删除取代的旧 GCD 跳转或异步包装；**同 Task 移除实际被修复路径的失效 dispatcher／重复回调桥接，不添加额外 shell、WebView 或编辑器实例**。纯展示操作可继续使用原生 SwiftUI，但不能为过渡引入原生视图双份状态。

**验证：** 用相同 Swift 6 编译诊断核查相关原生代码，再运行 `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；隔离原生检查终端 PID、输入／焦点／scrollback、编辑撤销和错误保护、网页表单和滚动、Diff 首屏及焦点；`make build` 严格验签。原生结果未经检查不得因为编译通过而宣称完成。

**提交：** 原生 callback 隔离修复、旧回调胶水清理和重挂载回归同一提交。

---

<a id="p7-t3"></a>
## P7-T3 正式切换 Swift 6 语言模式并使构建／测试全通过

**Files／源码锚点：** `kero.xcodeproj/project.pbxproj::SWIFT_VERSION` 的应用与测试 target 配置、必要的自有 Swift 文件的**实际编译诊断位置**、`Makefile::build/test/build:release`、`kero.xcodeproj/xcshareddata/xcschemes/kero.xcscheme`、`docs/RELEASE.md`（如真实工具链契约发生变化）。

**当前事实：** App Target 当前 `SWIFT_VERSION=5.0`，Xcode 支持 Swift 6 且启用默认 `MainActor`；CI／发布依赖原生 Xcode 和 Makefile，单一 App 身份不允许引入新的 scheme 或 build wrapper。仓库可能同时有其他人的 pbxproj/workflow 改动，执行时必须重新检查当前状态，不能覆盖并行工作。

**实现：** 在 P7-T1／T2 的根因修复验证后，将应用及 XCTest 的 `SWIFT_VERSION` 实际设为 6，保留项目既有 Approachable Concurrency、默认 `MainActor`、部署目标和 CI 构建入口。**本 Task 必须修完模式切换在当前可编译生产／测试路径暴露的残余 Swift 6 诊断**；涉及其它 Task 的逻辑不变量时回到对应拥有者同一次修复／测试，不把旧 Swift 5 兼容标注或未解决警告留下。避免 `nonisolated(unsafe)` 或关闭检查以取得假通过；第三方 package 不受本仓库控制的语言模式保持其原有配置，仅按实际诊断处理自有适配。

**验证：** 用 `rg` 及 `xcodebuild -showBuildSettings` 核对 App／Test target 的真实 `SWIFT_VERSION=6`；运行 `make doctor`、`make test`、`make build`、`make build:release`，对 Debug／Release 产物 `codesign --verify --deep --strict`。如 CI 工具链与本机不同，须以当时工作流为准进一步验证 CI 兼容，未经实际 Actions 通过不宣称远端成功。

**提交：** Swift 6 模式切换、所需的直接编译修复和针对性验证作为原子提交，禁止额外 target／新 App 身份。

---

<a id="p7-t4"></a>
## P7-T4 适用的现代 SwiftUI、Foundation、交互与无障碍规范收敛

**Files／源码锚点：** `kero/UI/WorkspaceDockView.swift`、`kero/UI/Components/WorkspaceChrome.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/App/SettingsView.swift`、`kero/Files/FileTreePanel.swift`、`kero/Git/GitPanel.swift`、`kero/Terminal/TerminalFindBar.swift`、其它经过实际 consumer 检索发现的 SwiftUI View；`AGENTS.md::Swift / SwiftUI 约定`。

**当前约束：** Kero 当前支持 macOS 15.6+，自定义 `DockNode` 不是系统导航；有些几何读取用于真正拖动命中，原生组件承担 Ghostty、TextKit、WebKit 等 SwiftUI 无法等价实现的行为。

**实现：** 对可达生产代码先筛出**语义等价且部署目标支持**的现代 API 替换：`foregroundStyle`、`clipShape(.rect(cornerRadius:))`、`.scrollIndicators(.hidden)`、`.bold()`、适当的 static member、原生 Swift/Foundation URL 和格式化、`Task.sleep(for:)`。普通用户文本匹配优先 `localizedStandardContains`，但 Git 精确路径、机器标识、模糊搜索不按用户文本匹配处理。保持 `Button` 语义、图标无障碍标签、键盘焦点及用户字号；必要 Dock 命中可保留 GeometryReader、系统菜单不强套 TabView／NavigationStack。**同 Task 删除被取代的旧修饰符、无用 helper 和冗余旧式实现**，不为了“使用新 API”新造 compat wrapper 或设计 Token 系统。

**验证：** `make test`、`make build`、`make build:release` 与验签；受影响的 `KeroTests/TreeRowHitTestingTests`、`KeroTests/PaneRetentionTests`、`KeroTests/DockWorkspaceTests`；隔离原生验证窄面板、长路径、动态字号、拖动、焦点、SwiftUI 色彩、主题和辅助功能，升级前后交互相同。性能收益未经 `docs/PERFORMANCE.md` 测量不宣称改进。

**提交：** 同一处现代 API 接入及旧实现删除，在这一 Task 的完整验证内原子提交；若相互独立的地方过多，可按同一结果类别细分小提交／回写 Task，而非堆积到最终清理。

---

<a id="p7-t5"></a>
## P7-T5 只读核验全项目架构、任务清理和可观察行为

**类型：** 最终只读检查与证据交付；不是集中清理任务，不为总结制造功能提交。

**检查范围／源码锚点：** `AGENTS.md`；`kero/App/keroApp.swift` 的 Scene／窗口焦点；`kero/Workspace/TerminalManager.swift`、`kero/Workspace/Project.swift`、`kero/Workspace/PaneTab.swift`、`kero/Workspace/DockWorkspaceModel.swift`；`kero/Files/`、`kero/Git/`、`kero/Terminal/`、`kero/Editor/`、`kero/Browser/`、`kero/Remote/`、`kero/UI/`；`KeroTests/`、`docs/` 内维护文档，以及 P1～P7 的计划和 `todo.toml`。

**步骤：** 用 CodeGraph 与实际源码全面核对所有自有 UI 状态、ObservableObject／@Published／objectWillChange／@StateObject／@ObservedObject、View 直接 IO、重复状态与过时回调、公开入口及调用者，不机械地将 **确有 Publisher 或第三方原生桥接用途**的 Combine 判为缺陷；为每个保留的例外提供实际消费者／必要边界。验证所有已移除路径在前序所属 Task 完成时就已删除，不能把缺口记作 P7 “最后再清理”；发现残留或行为回归，**重新打开其源码所有者对应的前序 Task，在那里修复、测试、提交和回写状态后再继续核验**。文档的变化在相应原子任务及时修正，勿使用历史 feature 当当前事实。

**验证与交付：** 机械检查所有 plan task anchor 与 `todo.toml` 状态关联、所有代码修改有对应原子 commit；运行 `make test`、`make build`、`make build:release` 并复验签名及 Swift 6 build setting，按照 `idea.md` 的窗口／菜单／项目／Dock／Files／Git／diff／终端／浏览器／SSH／设置／恢复功能逐项记录 XCTest／隔离原生／未授权无法测的证据。只在获授权后才碰真实 SSH master 或正式 App。性能按 `docs/PERFORMANCE.md` 记录真实对比，不能以 FPS 或编译通过冒充端到端。

**提交：** 只读核验无源码提交；通过 `todo.toml` note 与实际 phase audit 记录证据和未测项，Skill 状态工具使用 `no-commit-reason`。若核验发现问题，先返回拥有者 Task，不在这里修代码。

---

## 阶段完成门槛

Swift 6 的正式编译／测试／验签全部通过，Kero 自有的 UI 状态以 Observation 为主且 MVVM 职责完整；没有并行旧路径、伪兼容层或将遗留问题集中到末尾的清理工作。阶段审核在执行完毕后由 Skill 工具创建，本次规划**不预建 audit 文件**。
