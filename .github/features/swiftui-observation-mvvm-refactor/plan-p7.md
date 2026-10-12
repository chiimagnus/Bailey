# P7：Swift 6 严格并发与最终验收

**Goal：** 用当前实际编译诊断修正自有 Git/SSH/原生桥接的 Swift 6 并发问题，正式切换目标语言模式并通过全套测试、Debug/Release 签名验证；不为 SwiftUI 修饰符做全项目无意义的格式化扫荡。

**Non-goals：** 不引入新的独立构建系统、SwiftPM Target、第三方状态管理框架或数据格式；不在最终任务集中删除积压的旧代码、不擅自安装／重启正式 Kero、不无故提高最低 macOS 版本。

**Approach：** P1 诊断与本阶段重跑的 Swift 6 编译是修复的事实依据；先修跨 actor Git/SSH/文件后端，再修 AppKit/Ghostty/WebKit callback，最终切换工程 Swift 6。只为**真实诊断**改变 GCD、delegate 或 actor 隔离，不替换为了防止管道堵塞而保留的线程模型。所有受影响的 SwiftUI 表达改动在**其所属 P2～P6 Task 内**按 AGENTS.md 顺手替换旧 API，不设独立 cosmetic sweep。全项目代码和旧观察路径的收敛核对随每个 phase 收口，最终只是核实证据，不允许遗留到这里集中清理。

**Acceptance：** App 和 XCTest 确实使用 Swift6 语言模式且测试、Debug/Release 编译和验签通过；所有自有 SwiftUI 可观察状态以 Observation 为主，多窗口菜单、快照、Git、Files、native 内容、SSH 隔离在可验证范围无回归；确需的 Combine 只限 WebKit KVO、AppKit table/原生通知；各 Task 替代的旧路径都在**同 Task** 删除，不允许把旧实现留到最终清理。

**Rules：** `AGENTS.md`、`docs/PERFORMANCE.md`、`docs/SECURITY.md`、`docs/RELEASE.md`、`docs/DEPENDENCIES.md` 是边界；只按当前部署目标选择可用 API，不靠 `nonisolated(unsafe)`、无证据的 `@unchecked Sendable` 或关掉严格诊断求通过；保留 Ghostty、WKWebView、TextKit 的必要原生适配。

---

<a id="p7-t1"></a>
## P7-T1 SSH、Git 和文件后端的 Swift 6 并发边界收敛

**Files／源码锚点：** `kero/Remote/RemoteConnection.swift::RemoteConnection.runSSH`、`kero/Remote/SSHWorkspaceBackend.swift`（后台进程执行）、`kero/Remote/KeroSSHBridge.swift`（socket／worker queue）、`kero/Remote/RemoteCommands.swift`、`kero/Workspace/LocalWorkspaceBackend.swift`、`kero/Workspace/WorkspaceBackend.swift::WorkspaceBackend`、`kero/Git/GitCommandExecution.swift`、`KeroTests/RemoteCommandsTests.swift`、`KeroTests/RemoteLifetimeTests.swift`、`KeroTests/GitExecutionTests.swift`。

**当前可达链：** SSH 的远端进程 runner 包含 `DispatchQueue.global` 包裹同步 `ProcessRemoteCommandRunner.run`；`KeroSSHBridge` 有专用 socket/worker queue；`WorkspaceBackend: Sendable` 是文件／Git／SSH 共同依赖的真实跨 actor 协议。

**实现：** 针对 P1 的真实 Swift6 编译诊断定位 `Sendable`、actor 隔离和闭包捕获根因；`GitCommandExecution` 的 stdout/stderr 并行 `Thread`/`DispatchGroup`、`ProcessRemoteCommandRunner` 的 `poll`、`KeroSSHBridge` 的 socket/worker queue、`LocalWorkspaceBackend` 的后台 `Task.detached/@concurrent` 都是当前避免死锁或主线程阻塞的**有效职责**，不主动改写。`RunPipeData` 等已有 `@unchecked Sendable` 需核对线程写入及 `join/wait` 同步是否足够，确有竞态才在本 Task 修复，不能直接加/删不安全标注骗编译。**同 Task 删除替代后的旧代码、重复 import（如 `SSHWorkspaceBackend.swift` 双 `import Darwin`）及真正无消费者的 wrapper**，但不要造另一套 Git/SSH runner。

**验证：** 使用 P1 的相同受控 Swift 6 编译覆盖命令核对这部分诊断已消失；`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests`、`make test ONLY_TESTING=KeroTests/RemoteCommandsTests`、`make test ONLY_TESTING=KeroTests/GitExecutionTests`；覆盖进程超时、字节输出、异常、SSH 断线、错误状态及 local/remote scope。真实 SSH 仅在用户已有授权的测试 master 可用时运行，不绕过认证。默认工具链下 `make build`。

**提交：** 同类后端并发根因、真实 IO 结果测试和被替代分发代码删除原子提交。

---

<a id="p7-t2"></a>
## P7-T2 终端、编辑器与 WebKit 的 Swift 6 actor／delegate 边界

**Files／源码锚点：** `kero/Terminal/TerminalSession.swift`、`kero/Terminal/KeroTerminalView+Ghostty.swift`、`kero/Terminal/TerminalSurface.swift::TerminalBackendSurface`、`kero/Terminal/TerminalFind.swift`、`kero/Editor/SourceTextEditor.swift`、`kero/Editor/FileViewerView.swift`、`kero/Git/DiffViewerView.swift`、`kero/Browser/BrowserView.swift::BrowserTab`、`kero/Support/FPSCounter.swift`、`KeroTests/PaneRetentionTests.swift`。

**当前可达链：** `TerminalSession`、`FileTab`、`DiffTab` 与 `BrowserTab` 是长寿命对象，其中终端事件、NSTextView delegate、WKNavigationDelegate／KVO、CADisplayLink 通过原生回调到达 `MainActor`；P4、P6 迁移 Observation 后仍需要这些原生边界正确隔离。

**实现：** 根据实测 Swift6 诊断只修必须修的 `@MainActor/nonisolated/Sendable`，保持 Ghostty `TerminalBackendEvents`、WebKit delegate/KVO、NSTextView delegate、CADisplayLink 的原生调用时序。当前 `TerminalHostView` 的 responder 焦点需要下一 runloop，BrowserAddressField 在新挂载后有有限次数的焦点重试，SourceTextEditor 的首次布局恢复必须同一首帧发生——这些原生 GCD 回调**不得仅因语法旧而删除**。如果诊断指向这些路径，修真正的 actor 捕获和任务生命周期，删除被替代的旧 dispatcher/重复适配但不要改掉已验证的 UX 行为。仍需要一份 native 视图、一份标签 identity；不引入新桥接状态。

**验证：** 用相同 Swift 6 编译诊断核查相关原生代码，再运行 `make test ONLY_TESTING=KeroTests/PaneRetentionTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`；隔离原生检查终端 PID、输入／焦点／scrollback、编辑撤销和错误保护、网页表单和滚动、Diff 首屏及焦点；`make build` 严格验签。原生结果未经检查不得因为编译通过而宣称完成。

**提交：** 原生 callback 隔离修复、旧回调胶水清理和重挂载回归同一提交。

---

<a id="p7-t3"></a>
## P7-T3 正式切换 Swift 6 语言模式并使构建／测试全通过

**Files／源码锚点：** `kero.xcodeproj/project.pbxproj::SWIFT_VERSION` 的应用与测试 target 配置、必要的自有 Swift 文件的**实际编译诊断位置**、`Makefile::build/test/build:release`、`kero.xcodeproj/xcshareddata/xcschemes/kero.xcscheme`、`docs/RELEASE.md`（如真实工具链契约发生变化）。

**当前事实：** Xcode App/Test 目标仍是 `SWIFT_VERSION=5.0`，已启用默认 `MainActor`。**本机使用 `/Applications/Xcode-beta.app`（Xcode 27.0、Swift 6.4），而 `.github/workflows/ci.yml` 与 `release.yml` 明确锁定 `/Applications/Xcode_26.6.app`**，且本机没有这个 Xcode 26.6 目录；不能将本机 Swift 6.4 的 `@Entry/FocusedValues` 类型检查当作 CI 26.6 的通过证明。CI／发布只用同一 `Makefile` 与单一 App Target，不能为了本次重构增加 scheme 或测试框架。

**实现：** 经 P7-T1/T2 根因修复后把 Xcode App/Test Target 真实 `SWIFT_VERSION` 改为 6，保持 macOS 15.6、Approachable Concurrency、默认 `MainActor`、Xcode scheme 与 CI/发布单一入口。剩余诊断回到其实际 owner 修复，禁止为骗过编译回落 Swift 5/禁用严格并发。**本 Task 不新建全仓 SwiftUI `foregroundStyle/.bold/clipShape` 美化任务；这些规则已在 P2～P6 对应 View 变更时逐项落实。** 终验再次按 CodeGraph 检查自有 UI `ObservableObject/@Published/objectWillChange/@StateObject/@ObservedObject`、SwiftUI View 直接 Git/文件 IO、非必要转发及手写兼容分支；若发现遗漏，回到所属前序 Task 当场改/验证/删旧代码并更新进展，不能在最终任务里为他们集中清理。

**验证：** `xcodebuild -showBuildSettings` 确认 App/Test 真实 Swift 6，运行 `make doctor`、`make test`、`make build`、`make build:release`，对 Debug/Release 包各自 `codesign --verify --deep --strict`。**必须额外确认 CI/Release 指定的 Xcode 26.6 下可构建、可运行测试**；可用真实 Actions PR 运行证明，或在装有 26.6 的受控设备用相同 Makefile 复验，不能因本机 27 通过就宣称发布兼容。若 26.6 不支持计划选用的具体 API，优先调整源码到两者和 macOS 15.6 都支持的方案，不擅自上调 CI Xcode 或最低系统版本。隔离 Debug 原生验多窗口焦点和快捷键、项目/Dock 恢复、终端 PID/焦点、未保存保护、Git/Files 目标身份、SSH 无本机回退、WebKit 表单与 diff；未授权真实 SSH、正式 App 重启标为未测。不做无关的 30 次性能压测，只对真正修改的热点遵循 docs/PERFORMANCE.md。核对 22 项 Task 的提交和原位旧代码删除；不引用已有 `audit*.md` 作为事实。

**提交：** Swift 6 模式切换、所需的直接编译修复和针对性验证作为原子提交，禁止额外 target／新 App 身份。

---

## 阶段完成门槛

Swift 6 的正式编译／测试／验签全部通过，Kero 自有的 UI 状态以 Observation 为主且 MVVM 职责完整；没有并行旧路径、伪兼容层或将遗留问题集中到末尾的清理工作。阶段审核在执行完毕后由 Skill 工具创建，本次规划**不预建 audit 文件**。
