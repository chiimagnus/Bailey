# Audit P1 - workspace-focus-refactor

## 本轮独立复审（2026-10-22，并行审查）

本节结论来自逐笔 diff、当前生产调用链与本轮运行，不使用原有 audit 的发现或 Gate 推导正确性。原有记录及并行审查者的修改保留；本轮发现使用 F-10 至 F-17。`todo.toml` 的原有未提交改动不由本轮覆盖。生产验证截止 `b78ef1c`；随后并行审查者的文档与新增 Finder 关闭回归/生产修复不归入本轮已验证提交，也未混入本轮代码提交。

### 逐任务／逐提交映射

| 任务 | 核对提交 | 实际接入与最终结果 | 独立结论 |
| --- | --- | --- | --- |
| P1-T1 | `6189946c8dd67c23d776657c78a73e005b5192eb` | 仅写入原始测试证据和授权说明，无产品或测试实现；原始 76 项/6 skipped 是历史记录，不当作本轮复跑 | 基线没有完整 App 截图、逐帧输入和系统入口证据；原测试只构造模型，并未验证生产 SwiftUI 根视图，后由 F-12 补足宿主层证据，F-14 仍阻塞完整验收 |
| P1-T2 | `433c80fa9a2033e2d594053ffbbc29f16440a939` | delegate.workspace → WindowRootView / Commands / Settings；Finder Apple Event/Service → 同一 owner；SSH socket → service → owner.session → TerminalSession.beginRemoteConnection；通知标题/点击 → owner；GitPanel 两处删除许可 → owner.isWorktreeInUse；原生关闭 → 单窗保存 → owner 快照 → 内容销毁 | 生产路径实际接入，不是孤立新类；F-10 恢复中保存丢数据、F-11 SSH fixture 装配断链、F-13 混合机器检查与 F-15 重复归属维护均已独立修复 |
| P1-T3 | `0348d5f7dbed0bd2c1e47be2626b0421c7d7eef8` | ContentView.syncGit 与 GitPanel warning/failure 两处 Retry → WorkspaceWindowModel.syncGitStatus → GitStatusModel.syncSelectedProject；ToolPanelView.performSync → Project.syncFiles → FileTreeModel.sync/rebuild → 后端目录 → 可见树行 | 整窗形参已删除；Git 仍有 panelResolveGeneration/contextGeneration/PanelContext 身份核对，Files 保留根解析前后与 tree sync 后的目标判定；没有为删 guard 破坏机器/连接/保存边界 |

### 删除核对

- `TerminalManager` 旧类、旧文件、旧名 alias、`activeManagers`、应用级可变 static registry 与旧 `syncSelectedProject(in:)` / `syncFiles(in:)` 在生产 Swift 中均无现行入口。
- 不删除仍有职责的 `SessionStore`、TerminalHistoryStore、SSH token/端口/PID 校验、窗口关闭幂等、退出防覆盖、保存中新编辑检查及晚到目标核对。
- `49fdfaf` 删除按项目提前过滤全部内容的错误围栏；继续追到固定 SSH 终端后，以 F-16 收窄：目录与终端保留项目面板范围，File/Diff 按标签自身机器判断，不把别名、空身份与实际主机身份混为一谈。
- `956e9b1` 删除工厂预绑定及移除/关闭后的重复解绑，只由 `projects.didSet` 维护所属窗口及保存回调。
- `Project.panelRoot` 仍供 CommandPalette 读取，不能当作 Files/Git 旧 API 顺手删除；`pinnedFile` 和缺失 `localFile` 键仍承载可达快照语义，本轮不擅自改变数据解释。

### 本轮验证日志

环境：Apple Silicon arm64，macOS 27.2 (26B5101f)，Xcode 27.2 (27B5038j)，部署目标 15.6。只操作隔离 XCTest、临时文件/仓库与受控本机 Unix socket；正式 Bailey 进程保持运行，不发送通知/Bark，不连接真实 SSH，不更改设置/权限。

| 验证 | 实际结果及证据 |
| --- | --- |
| `make doctor` | 退出 0，Xcode 27.2；首次 rtk 包装输出未提供完整 XCTest 终结证据，不计作通过；后续全部原生 make 保留完整日志 |
| F-10 Red → Green | `/tmp/bailey-p1-review-snapshot-red.log`：9 项、40 条断言失败、make=2；`-snapshot-green.log`：9 项、0 失败、make=0 |
| F-13 Red → Green | `/tmp/bailey-p1-review-worktree-red.log`：单项、19 条断言失败、make=2；`-worktree-green.log`：GitStatusModelTests/GitWorkspaceMenuTests 共 59 项、0 跳过/失败、make=0 |
| F-11 Red → Green、F-12 | `/tmp/bailey-p1-review-services-red.log`：单项、4 条断言失败、make=2；`-services-green.log`：SessionStoreTests/RemoteLifetimeTests/GitInteractiveRebaseTests 共 19 项、1 跳过/0 失败、make=0 |
| F-15 | `/tmp/bailey-p1-review-bindings.log`：SessionStoreTests/WorkspaceWindowCloseTests/WorkspaceWindowIsolationTests 共 57 项、5 跳过/0 失败、make=0 |
| 首轮全量 XCTest | `/tmp/bailey-p1-review-full.log`：634 项、14 跳过/0 失败，make=0；该轮编译早于 F-16，不冒充最终源码全量，最终复跑见收尾 |
| F-16 Red → Green | `/tmp/bailey-p1-review-fixed-ssh-red.log`：单项、3 条断言失败、make=2；`-fixed-ssh-green.log`：GitStatusModelTests/GitWorkspaceMenuTests 共 60 项、0 跳过/失败、make=0；提交 `b78ef1c` |
| 最终 Debug/Release | `make build` 与 `make build:release DERIVED_DATA=build/DerivedData-p1-review` 均在 F-16 后构建并执行 `codesign --verify --deep --strict`，完整退出均为 0；日志 `/tmp/bailey-p1-review-final-debug.log`、`-final-release.log`；未将 Release 编译当作 Release GUI 验收 |
| 文档与旧入口 | 12 份受影响现行文档，100 个本地文件/标题链接通过；生产 Swift/现行 docs 无旧类型和整窗同步 API 引用；`git diff --check` 通过 |
| 最终源码全量 XCTest | `make test DERIVED_DATA=build/DerivedData-p1-review-services`：635 项、12 跳过、2 failures（1 unexpected），`TEST FAILED`，完整 make=2；日志 `/tmp/bailey-p1-review-final-full.log`。不能用首轮绿色覆盖该结果 |
| 失败隔离诊断 | 仅运行 `WorkspaceWindowIsolationTests/testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation`，实际 1 项/1 skipped/0 failures，make=0；原因是没有前台 XCTest key window，**不是通过**。日志 `/tmp/bailey-p1-review-palette-diagnosis.log`；F-17 保留 Open，已请求短暂前台验证许可 |

快照覆盖 1/2/3 窗口 × 防抖/重启保存/退出/提前关闭的全部 12 组，并核对重复关闭/退出后的快照和 sidecar。最终文件机器保护覆盖 2 种项目机器 × 3 种内容机器 × File/Diff 的全部 12 组，另核对相邻目录和本机符号链接；固定 SSH 终端单独建立生产 `Project.newSession` 的固定远端前提，覆盖握手前空身份/连接后不同主机身份 × 正确别名/本机/其它主机/相邻路径。连接状态为受控构造，不冒充真实 SSH。SSH 校验覆盖实际 socket、错误 token、跨 owner、关闭后拒绝及合法连接落入原 Session。生产根视图重复构造核对原生编辑器对象而非仅观察计数。

F-16 的证据校正：最初 18 组中的 6 组 Session 是不符合固定 SSH 生产构造的合成组合，初次 19 条 Red 不能全部归为有效产品缺陷。保留全部有效 File/Diff 断言，以真实固定远端构造替换错误 Session 假设，新增测试在 `49fdfaf` 上出现 3 条失败。此处记录审查纠错，不以修改预期隐藏真实失败，也不修改原项目已有测试断言。

首轮全量实际跳过的 14 项逐项列出如下；每项的原因、影响、替代证据和补验方法适用下表同名条件，不因分组而计作通过。最终复跑另核对是否变化：

- 前台 key window 缺位（6 项，阻塞完整原生输入验收）：`DockFocusP2RegressionTests.testPaletteNoTargetChangeLeavesNativeEditorReadyForTyping`；`WorkspaceWindowIsolationTests.testCancelingCommandPaletteRestoresFilesRowKeyboardNavigation`；`testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation`；`testEditorPaletteSwitchToFilesRestoresNewToolKeyboardFocus`；`testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus`；`testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField`。
- 未提供明确获授权的专用 SSH 主机/master（8 项，阻塞真实远端验收）：`GitExternalRefreshTests.testVisibleSSHPanelRefreshesExternalGitChanges`；`GitInteractiveRebaseTests.testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`；`GitWorkspaceSSHTests.testAuthorizedSSHRefArchiveBinaryResetStashCleanAndIgnorePersistOnWindows`；`testAuthorizedSSHWorktreeCreationAndRemovalPreservesBranch`；`SSHFileTreeLiveTests.testAuthorizedWindowsSSHBatchDirectoryListingAndIndependentFailures`；`testAuthorizedWindowsSSHFileTabCapacityAndBytePreservingSave`；`testAuthorizedWindowsSSHRenamePreservesActualDirectoryEntries`；`SSHGitRecoveryLiveTests.testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`。

首轮日志中 WebKit 的沙盒/XPC、粘贴板及 `RemoteCommandsTests` 的 stdin 线程 QoS 提示没有计为 XCTest failure；这些底层实现未在 P1 改动，不据此扩成 IO/WebKit 重构。Release 还报告未改动 Vendor parser/scanner 的精度、const 与运算符括号警告，以及未依赖 AppIntents 的元数据提取提示；Debug 无编译 warning，不借本任务修改第三方生成代码。

最终复跑的真实失败是 Git Palette 用例在 `wait` 中未满足“所属窗口已附着且第一响应者为 TreeKeyboardView”，8 秒后抛出 `WorkspaceError.timedOut`。随后 XCTest 同时记录 sanitized error 序列化失败与历史文件删除 NSError；`TerminalHistoryStore.save` 的删除本身是 `try?`，因此不能把这个附带 NSError 直接解释成已证实的生产数据删除故障。失败时持续的 key-window 状态没有日志，单独诊断又跳过：现有证据尚不能区分共享桌面干扰、夹具状态与生产焦点缺陷；不扩大等待、不改断言、不凭一次重跑绿色关闭发现。

### 未覆盖条件与 Gate

**本轮 Gate：No-Go。** F-14 的完整验收证据仍缺失，F-17 的最终全量真实失败也未核销。以下缺口不能用 XCTest 数量、部署目标或构建成功替代：

| 条件 | 具体原因／影响 | 替代证据与补验方式 | 阻塞 |
| --- | --- | --- | --- |
| 最低 macOS 15.6 运行时 | 本机只有 27.2，无法发现旧系统运行时差异 | 当前部署目标编译仅检查链接/可用性；需要 15.6 测试机复跑受影响原生与恢复路径 | 是 |
| CI 的 macOS 26/Xcode 26.6 工具链 | 现行 `.github/workflows/ci.yml` 声明该组合；本轮未启动远程 CI 或安装另一套 SDK，不能宣称兼容性通过 | 当前工具链 XCTest/Debug/Release；在该 workflow 环境补跑 | 是 |
| Release 原生交互 | 已构建并严格验签不等于 Release GUI/输入通过；现有 XCTest 使用 Debug testability，没有另建 Release 测试配置或启动正式包 | Debug 生产根视图及工作区集成是部分证据；独占 GUI 中实际运行 Release 配对验收 | 是 |
| 原始 GUI 与现行 GUI 的同环境逐像素/逐帧、完整动作对照 | T1 未采集所需旧版截图与录屏；共享桌面不能抢占用户窗口 | 实际生产根视图/原生内容身份与 WorkspaceUI 仅是部分替代；需受控 GUI 分别运行原始提交与新版本对照 | 是 |
| 前台 key window、物理键鼠、菜单焦点及被跳过的 Palette/Files 原生路径 | 正式 App 正在使用，不能抢输入；Skip 不计通过 | 非独占 NSWindow 测试；独占 GUI 中逐条补跑 skipped 与真实按键最终结果 | 是 |
| Finder 打开方式、Dock 投递、文件夹 Service 的系统投递 | 正式 Bundle ID 路由可能命中用户进程 | 进程内 Finder 队列、provider、真实 FileTab/机器/磁盘断言；正式 App 退出后的受控 Launch Services/Finder/Dock E2E | 是 |
| Settings 语言重启、真实退出再恢复 | 本轮不启动/退出/重启正式 Bailey | 直接保存路径、last-window/partial-restore、幂等与 sidecar 测试；受控 GUI 显式重启核对恢复 | 是 |
| 系统通知标题及点击投递 | 不向真实系统通知中心/设备发送，不修改通知权限 | 双服务同 owner、项目名/Session 定位及受控 socket；专用会话实际点击并核对目标终端 | 是 |
| 真实 Windows/SSH 握手、断线/重连、序列编辑器 PTY | 本轮无专用主机参数，不借用用户 master；SSH Rebase 条件跳过 | 本机 socket→真实服务→Session 和受控后端；提供明确获授权主机及专用 master 后补验 | 是 |
| Retina/非 Retina、多显示器、全屏/最小化、所有语言/字号/主题/窗口尺寸与输入法组合 | 没有独占显示环境，也不修改共享用户设置；本轮没有重录零差异基线 | 自动测试中的隔离配置和已测几何/对象身份不是全组合证明；专用 Home/GUI 按 idea 全集配对 | 是，属于零 UIUX 门槛 |
| 长时内存/CPU、真实资源耗尽/权限拒绝组合 | 不以资源耗尽或系统权限变更干扰用户环境，短时释放不代表长时稳定 | 现有隔离生命周期/失败测试；专用测试机做长时与受限资源复验，不把安全原因写成通过 | 完整验收仍待核销 |

P2 焦点行为尚未授权实施，本轮不把其未来重构代码写入 P1；P1 纯重构影响到的现有焦点与 UI 对照仍需上述验收。未进行正式包安装、重启、推送或发布；构建成功本身不改变 Gate。

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/workspace-focus-refactor/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 建立可重复的重构基线
- [x] P1-T2 分离应用级所有者并修正窗口命名
- [x] P1-T3 收窄领域依赖与验证异步目标

## 任务到文件的映射

- P1-T1（`6189946`）
  - `idea.md`、`evidence-p1.md`：原始产品源码基线、隔离原生测试、六项前台焦点跳过及其它外部系统限制；无生产代码改动
- P1-T2（`433c80f`）
  - `Bailey/App/{WorkspaceApplication,BaileyApp,FinderService,SettingsView}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project}.swift`：应用级与单窗注册、恢复、Finder、保存及项目呈现分界，删除旧 `TerminalManager.swift`
  - `Bailey/Remote/BaileySSHBridge.swift`、`Bailey/Terminal/TerminalNotificationService.swift`、`Bailey/UI/`：SSH/通知/菜单/拖放接入唯一应用所有者
  - `BaileyTests/` 中原有二十类与新窗口认领、跨 owner 隔离、实际私有 socket handoff 测试；`AGENTS.md`、`docs/architecture.md` 及相关功能文档
- P1-T3（`0348d5f`）
  - `Bailey/Workspace/{Project,WorkspaceWindowModel}.swift`、`Bailey/Git/{GitStatusModel,GitPanel}.swift`、`Bailey/UI/{ContentView,Panels/ToolPanelView}.swift`：Files/Git 异步接口由调用方传入项目和可撤销目标许可，不再传整个窗口
  - `BaileyTests/Integration/Workspace/PanelContextTests.swift`、所有相关 Git 对话框／外部刷新测试，`docs/architecture.md`、`docs/features/{files,git,projects,ssh}.md`

## 发现项

## 发现 F-23

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift`
- 摘要：`⌘P 焦点回归错误依赖 FPS 命令，且窗口焦点恢复路径被命令执行主动关闭`
- 根因：`原用例一并测试 FPS 开关、Palette 执行与编辑器焦点；先用 isKeyWindow/NSApp.isActive 不满足则跳过。取消跳过后发现用例把滚动容器 NSScrollView 当成原生文本输入视图，与真正的 FocusReportingTextView 第一响应者比较，因此即使 FPS 开关成功、Palette 关闭、输入焦点已恢复仍会错误失败。`
- 修复：`按用户最新决定，删除完整 FPS 功能（DisplayLink、Badge、Dock 状态和布局、命令项、专属测试、本地化文案）；将 ⌘P 测试改为执行实际 File Manager 命令，核对真实树行焦点与 ↑ 导航。CommandPaletteView.run() 恢复调用现有的 dismissCommandPalette()，使目标变化后现有焦点归属检查可交接给 TreeKeyboardView，仍禁止旧视图覆盖新的原生响应者。此前所有测试前台条件跳过均已删除，不重新引入。`
- 验证：`⌘P→File Manager 旧代码 3 条断言失败（面板已切但第一响应者停在 DockGroupFocusView）；复用原有焦点恢复后定向 TEST SUCCEEDED，TreeKeyboardView 接收 ↑，最终文件字节不变。最新 DockFocusP2RegressionTests、SessionStoreTests、ProjectFileIndexTests 共 15 项/0 失败；另外 4 项 Files/Git/Palette 交接通过；Debug/Release 均 BUILD SUCCEEDED 且 codesign --verify --deep --strict 通过。FPS 活动源码引用和 3 个本地化键归零，audit 仅保留历史文字。`


## 发现 F-22

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift:410-469`
- 摘要：`全量原生窗口测试中Git树焦点用例曾真实失败，根因与前台输入证据不足`
- 风险：`某次全量make test共635项出现Git树KeyboardNavigation用例NSHostingView渲染超时、测试清理历史文件时ENOENT两条失败断言，且另一次目标用例因不可取得前台key window而跳过；目前无法确定是AppKit生命周期故障、共享桌面焦点干扰还是P1功能回归，不能用其他绿灯掩盖。`
- 预期修复：`先在可独占的安全GUI会话重现并记录原生firstResponder、窗口与宿主装配的真实先后次序，和历史产品基线配对；确定根因后按受影响所有者作最小修复，不降低断言、不任意延长超时。`
- 验证：`重跑完整make test并明确区分skipped与passed；在受控GUI下执行该用例的正常/脏仓库两个分支，检查实际原生按键和可见树焦点、AppKit报错及历史临时文件生命周期。`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-17

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift:450`
- 摘要：`最终全量复跑中Git Palette取消恢复原生焦点用例失败`
- 风险：`635项中该用例窗口/TreeKeyboardView未就绪，并报告history sidecar删除异常；不能将首轮绿色或本轮其它通过代替该主路径`
- 预期修复：`先隔离重跑确认夹具、key window和所属窗口/目标，区分共享桌面干扰与生产缺陷；不放宽等待、不改断言或禁用测试，缺少受控前台条件时保留阻塞`
- 验证：`make test ONLY_TESTING=BaileyTests/WorkspaceWindowIsolationTests/testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation DERIVED_DATA=build/DerivedData-p1-review-services`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-21

- 任务：`P1-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`.github/features/workspace-focus-refactor/idea.md:23`
- 摘要：`当前 Feature 描述仍称 detached HEAD、未授权实施，且旧文件链接不可到达`
- 风险：`实际分支 feature/workspace-focus-refactor 已实施 P1，plan-p1 顶部仍称本轮不授权产品修改；review-preflight 中旧 TerminalManager.swift 链接指向已删除现行文件，读者无法分辨历史入口和现行入口。`
- 预期修复：`只更新当前状态描述并明确旧文件入口是历史基线；历史提交证据保留，不重写原始审查和验收约束；移除指向不存在工作区路径的 Markdown 链接。`
- 验证：`git status、git cat-file 验证原始源码归属、Feature 内 Markdown 相对路径核对、docs audit、git diff --check`
- 解决证据：`6ee5fdf：固定实施基线与当前分支分离，旧TerminalManager历史路径取消失效链接；Feature 162 个本地Markdown链接无断链，todo validate与git diff --check通过。`


## 发现 F-20

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:113-129`
- 摘要：`关闭尚未附着的已有文件窗口后，等待其认领的 Finder 请求永久滞留`
- 风险：`deliverPendingExternalFiles 将已开文件请求推回队列等待未附着 owner；windowClosed 只注销窗口和保存，不重试仍合法的其他窗口请求。该 owner 在附着前关闭时再无递送事件，系统打开文件请求既不完成也不在接收窗口创建文件标签。`
- 预期修复：`在实际所有者从窗口集合移除后，重试仍有效的待处理文件请求；保留已关闭首选窗口请求取消、其他文件复用和项目身份判定，不添加定时轮询。`
- 验证：`WorkspaceWindowIsolationTests：双窗口+未附着 owner 持有相同 Mac FileTab、优先接收者已附着、批量 Finder 请求被阻塞，owner 关闭后逐个完成且最终仅有一个正确 FileTab；另覆盖接收项目切换和多请求不重放；make test:WorkspaceWindowIsolationTests 及扩大回归、build`
- 解决证据：`a48593d：已验证未附着旧文件窗口关闭后，67份原生Finder FileTab请求全部正确完成，3份接收项目切换请求全部按原目标拒绝；修复前定向XCTest 3断言失败/TEST FAILED，修复后定向TEST SUCCEEDED；WorkspaceWindowIsolationTests/WorkspaceWindowCloseTests/SessionStoreTests/PanelContextTests/RemoteLifetimeTests 76项/5 skipped/0 failures；Debug与Release BUILD SUCCEEDED且codesign --verify --deep --strict退出0。`


## 发现 F-16

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:159`
- 摘要：`本轮49fdfaf将终端改按裸workspaceIdentity比较，破坏固定SSH项目的别名归属`
- 风险：`固定SSH终端在握手前identity为空，独立握手后也可能是user@host而非项目ssh:alias，原远端工作树占用保护会漏检`
- 预期修复：`将本轮修复收窄到File/Diff独立机器；目录与终端保留原项目scope语义，补固定SSH真实前提回归，修正不符合生产构造的合成session矩阵`
- 验证：`make test:GitStatusModelTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`固定SSH真实构造的回归在49fdfaf上3条失败；收窄后GitStatusModelTests/GitWorkspaceMenuTests共60项、0跳过/失败，make退出0；保留目录/终端原项目scope，不推广不符合生产事实的合成Session假设`


## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift:847-867`
- 摘要：`全量 XCTest 下五编辑器释放压力测试的夹具跳过实际原生文档退役，并打印虚假的释放计数`
- 风险：`完整 make test 629项/14跳过/2条失败断言，同一轮第二周期 FileTab/TextKit 弱引用未在10秒内归零；单独跑该类21项全过，无法区分宿主缓存和实际泄漏，虚假日志误导定位`
- 预期修复：`测试按现有 Project.close/terminateAll 的真正退出顺序显式调用 FileTab.retireNativeEditor，再释放宿主；核验实际弱引用数量，不增加等待或降低断言。未证明运行时资源泄漏前不改编辑器内核。`
- 验证：`旧完整 make test 日志保留；make test:PaneRetentionTests,WorkspaceWindowIsolationTests 再次实际验证；最终完整 make test Debug/Release签名和异常/多轮测试`
- 解决证据：`27edfb8: native close contract now retires TextKit before NSHostingView teardown; make test:PaneRetentionTests,WorkspaceWindowIsolationTests DERIVED_DATA=build/DerivedData-workspace-refactor -> exit 0, 62 executed/3 skipped/0 failed; all 5x5 editor and FileTab weak references released. Original make test failed 629/14 skipped/2 assertions; still requires final full rerun after concurrent P1 fixes.`


## 发现 F-15

- 任务：`P1-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/WorkspaceWindowModel.swift:371`
- 摘要：`项目归属已由 projects.didSet 维护，仍残留工厂预绑定及重复解绑`
- 风险：`两处维护同一回调归属，工厂未入集合即绑定，移除/关闭重复清理`
- 预期修复：`只保留项目集合成员关系这一处绑定/解绑真源`
- 验证：`make test:WorkspaceWindowCloseTests,SessionStoreTests,WorkspaceWindowIsolationTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`956e9b1；删除5行重复绑定/解绑，集合didSet唯一维护；SessionStoreTests+WorkspaceWindowCloseTests+WorkspaceWindowIsolationTests共57项/5项前台焦点跳过/0失败，make退出0`


## 发现 F-14

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Open`
- 位置：`.github/features/workspace-focus-refactor/evidence-p1.md:23`
- 摘要：`缺少硬门槛要求的原始 GUI 对照和系统入口证据，不能确认 P1 完整验收`
- 风险：`任务标 completed 不代表零 UIUX 和最低系统、真实远端等验收已经完成`
- 预期修复：`独立核销可安全执行的条件；保留逐项缺口与 No-Go，不以本机 XCTest 代替独占 GUI/最低系统/授权 SSH`
- 验证：`make test; make build; make build:release（均使用独立 DerivedData）；独占 GUI 与其它系统需外部条件`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-13

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:152`
- 摘要：`worktree 使用检查先按项目 scope 过滤，漏掉 SSH 项目中的本机内容`
- 风险：`已打开本机文件或 Diff 所属工作树仍可被删除；这是迁移保留的旧算法缺陷而非新增回归`
- 预期修复：`独立修复为逐目录/会话/标签按各自机器校验，保留目录边界和 symlink 语义`
- 验证：`make test:GitStatusModelTests,GitWorkspaceMenuTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`49fdfaf + b78ef1c；最终为12组File/Diff真实机器组合及固定SSH项目终端归属回归；GitStatusModelTests/GitWorkspaceMenuTests共60项、0跳过/失败，make退出0；初始合成Session夹具的证据校正见F-16`


## 发现 F-12

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift:2119`
- 摘要：`所谓 SwiftUI 推测构造测试未创建任何真实 SwiftUI 宿主`
- 风险：`只 new 模型不能验证 WindowRootView 的 State 重建、onAppear 与原生 attach 的组合；不满足 P1-T1 第4步`
- 预期修复：`通过生产 WindowRootView 的真实 NSHostingView 验证同场景重复求值只登记/认领一次`
- 验证：`make test:WorkspaceWindowIsolationTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`228e844；生产WindowRootView在NSHostingView中连续重新构造4次，仍是1个登记窗口、同一个NSTextView及1份恢复文件；SessionStoreTests 10项通过；此证据非WindowGroup系统恢复E2E`


## 发现 F-11

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/NativeUI/Git/GitInteractiveRebaseTests.swift:174`
- 摘要：`专用 SSH Rebase fixture 的 owner 未接入真实 BaileySSHService`
- 风险：`新终端的有效 token 在宿主 owner 找不到对应 Session，真实握手被拒绝；现有跳过隐藏该回归`
- 预期修复：`复用显式服务装配入口并恢复原绑定，补安全的真实 socket 握手回归`
- 验证：`make test:RemoteLifetimeTests,GitInteractiveRebaseTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`228e844；真实socket握手旧实现4条断言失败，修复后SessionStoreTests+RemoteLifetimeTests+GitInteractiveRebaseTests共19项/1项授权SSH跳过/0失败，make退出0；GUI与fixture共用connectServices，恢复双服务原绑定`


## 发现 F-10

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:108`
- 摘要：`整体保存及末窗关闭覆盖尚未认领的恢复快照`
- 风险：`只恢复首窗后保存/退出，或首窗提前关闭，会丢掉其余窗口及历史`
- 预期修复：`保存已登记窗口时合并未认领快照及历史，末窗保留同一队列，不增加第二份状态`
- 验证：`make test:SessionStoreTests DERIVED_DATA=build/DerivedData-p1-review`
- 解决证据：`b199082；SessionStoreTests旧实现40条断言失败，修复后9项/0失败，make退出0；1/2/3窗口×relaunch/terminate/close/debounce及重复关闭，核对保存快照与history sidecar`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:142-166`
- 摘要：`SSH 项目内保留的本机 FileTab 可能绕过本机 Worktree 使用保护（已存在于旧实现）`
- 风险：`先按 project.panelContext.scope 过滤 SSH 项目，导致随后对 tab.content.file.workspaceIdentity 的本机路径检查永远不可达；Worktree 删除时可能忽略仍在该 SSH 项目中的本机文件缓冲`
- 预期修复：`另案以跨机器 FileTab/ DiffTab 内容身份逐个判断占用；只有项目目录和会话适用项目层级 scope 过滤，不在 P1 纯职责迁移中暗改用户行为`
- 验证：`添加 Mac FileTab 属于 SSH Project 的实境回归；确认本机 Worktree Remove 对含未保存文本的该文件拒删，SSH 查询无误报，并核对相邻路径、软链接、清洁/锁定 Worktree`
- 解决证据：`Resolved by independent commit 49fdfaf (also tracked in F-13): removed project-scope early filter for File/Diff tabs; session checks use session workspaceIdentity; Red 19 assertions failed in 27 mixed scope/kind combinations, Green make test:GitStatusModelTests,GitWorkspaceMenuTests DERIVED_DATA=build/DerivedData-p1-review 59/0 failed/0 skipped, exit 0. A real local FileTab inside SSH Project through openExternalLocalItems passes WorkspaceWindowIsolationTests added scenario (62 tests/3 skipped/0 failed). Final full suite still pending.`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- `6ee5fdf` 修复当前计划状态与历史源码导航；`a48593d` 修复 Finder 等待已注销窗口的队列滞留。
- 独立复查删除 `BaileyTests` 中基于前台应用／Key Window 的跳过、断言降级与分支；不删除 AppKit 真实焦点断言，也不为单个用例引入重试状态机。
- 依用户最新要求完整删除 FPS 采样器、Badge、UI 状态、菜单、本地化键和专属用例，⌘P 新测试使用真实 File Manager 动作。旧版 `PaletteCommand.preservesCurrentFocus` 试验不复活；当前命令执行使用已有的原生焦点恢复逻辑交给最新有效接收者。

## 验证日志

- P1 当前最后一轮完整 `make test`（`a48593d` 基础、尚未移除前台守卫）：**636 项、14 skipped、0 failures、退出 0**；Debug／Release 严格验签通过。
- 清理测试绕行后 `make test:DockFocusP2RegressionTests,WorkspaceWindowIsolationTests,GitWorkspaceMenuTests,PaneRetentionTests,GitExternalRefreshTests DERIVED_DATA=build/DerivedData-p1-review-services`：**80 项、1 skipped、22 条断言失败（9 unexpected）、命令退出非零**。DockFocus、GitExternalRefresh、GitWorkspaceMenu 三类通过；PaneRetention 的五编辑器释放与 Dock 移动用例超时；WorkspaceWindowIsolation 的 Palette/Files 原生焦点用例部分超时，且观察到测试历史 JSON 删除时文件已不存在。该轮由共享桌面前台应用变化干扰，不足以断言全部是产品回归，也不能冒称验收通过。失败详情：`/tmp/bailey-p1-focus-no-guards-final.log`。
- 受控前台定向 `testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation` 曾 1 passed/0 skipped；但不足以替代反复、多窗口组合与真实用户输入验收。
- Mac 当前可验证 macOS 27.2、Xcode 27.2、arm64；macOS 15.6、专用授权 Windows SSH、完整正式 Bundle Finder/Dock/通知和独立 GUI 前后同条件像素／键盘回归尚缺证据，属于 No-Go。
- 现行参考：`docs/testing.md` 为统一测试要求、`docs/architecture.md` 为状态归属、`evidence-p1.md` 为任务测试证据；`todo.toml` 的 P1 三项已完成不等于最终 Gate 达标。

## Gate（是否允许进入下一阶段）

- 结论：`No-Go`
- 理由：现有原生焦点与五编辑器生命周期在移除条件绕过后的测试中仍出现失败，且独立 GUI／最低系统／授权远端的必要验收证据未收齐；不能用先前带跳过的绿色冒充当前通过。

## 最终状态与剩余风险

- 当前状态：`Open`（P1-T1～T3 已实施，阶段独立审计未完成放行）
- 剩余风险：F-14 正式 GUI／系统差异，F-17、F-22 的原生窗口焦点及测试历史清理偶发失败；五编辑器资源释放与窗口重挂载的极端时序需复现并排除实际持有者。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


## 本轮独立审查记录（2026-10-22；从当前源码和提交重新推导）

**审查方法：** 从 `todo.toml` 与 `plan-p1.md` 逐任务建立入口→所有者→副作用，阅读 `097dac7` 的旧实现、当前 App/窗口/项目/Git/远端/通知源码、逐笔 Git diff 和运行记录；旧 audit 的发现或 Gate **不是本节结论来源**。本节独有发现为 F-20、F-21、F-22，使用同一现有 audit 文件，不另造平行完成清单。

### P1 任务／提交核销

| 任务 | 原子提交与必要追补 | 真正生效的入口／最终副作用 |
| --- | --- | --- |
| P1-T1 | `6189946`；文档状态校正 `6ee5fdf` | 旧 `origin/main@097dac7` 的窗口与资源回归基线：76 项、6 skipped、0 failed，证据位于 `evidence-p1.md`。没有同条件完整原生视频／像素／前台输入对照，不以代码与绿色 XCTest 替代 |
| P1-T2 | `433c80f`；保存补漏 `b199082`；真实五编辑器夹具 `27edfb8`；跨机器 Worktree `49fdfaf`；服务／根视图 `228e844`；SSH 项目本机文件 `1fb5fba`；重复绑定删除 `956e9b1`；固定 SSH machine scope `b78ef1c`；Finder 关闭队列 `a48593d` | `BaileyApp`/delegate 的单一 `WorkspaceApplication` 通过 `WindowRootView`、`BaileyCommands`、Settings、Finder Apple Event 与 Service、认证 `BaileySSHService`、通知点击和 Git Graph 删除权限接线；每窗 `WorkspaceWindowModel` 持有项目与原生内容。快照最终写入 `SessionStore`、历史写入 `TerminalHistoryStore`，Finder 最终复用或新建真实 `FileTab`，Worktree 删除经项目/文件机器校验 |
| P1-T3 | `0348d5f` | `ContentView.syncGit` 和 GitPanel 两处 Retry → `WorkspaceWindowModel.syncGitStatus` → `GitStatusModel.syncSelectedProject(project:isCurrent:)` → 异步后核对 generation、`PanelContext.Identity` 和窗口当前选择；`ToolPanelView.performSync` → `Project.syncFiles(isCurrent:)` → `FileTreeModel.sync` → 实际树。原两个整窗形参全部调用方已迁移 |

### 已删除和必须保留的实现

- 当前 `Bailey/`、`BaileyTests/` 没有 `TerminalManager`、`activeManagers`、`syncSelectedProject(in:)`、`syncFiles(in:)` 运行引用；没有新旧窗口注册双轨、旧类 alias 或额外 ServiceLocator。UI 相关生产变更是类型注入和调用替换，未修改可见样式常量。
- `projects.didSet` 是项目与所属窗口回调的唯一维护处；已移除提前绑定和显式重复解绑。领域异步结果仍用请求代次、项目许可、路径、主机/连接身份防止旧结果越界。
- 不删除 `pinnedFile`、快照中可选 `localFile`、`SessionStore`、终端历史、认证 token／PID／socket 检查、文件保存否决、原生 willClose 通知、旧 Editor/Dock 原生对象保留路径：这些是目前可达且有数据或授权不变量支持的代码，不是多余兼容围栏。
- 计划中的旧路径是历史审查对象，不应全量替换为当前文件名；旧版源码仍可由 `git show 097dac7:...` 逐笔查阅。

### 本次新增 Red → Green 与环境验证

- F-20：`WorkspaceApplication.windowClosed` 的真正文件所有者注销后没再次递送 Finder 请求。新测试覆盖**67 次未换项目**及**3 次接收项目切换**，检查所有请求完成恰好一次、同一磁盘文件的目标 `FileTab`、无误投和最终文件字节。旧版本对应三条断言失败（`/tmp/bailey-p1-independent-owner-close-red.log`；make Error 65）；仅在原有窗口注销后调用 `deliverPendingExternalFiles()`，定向绿（`/tmp/bailey-p1-independent-owner-close-green.log`）。扩大至 `make test:WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,SessionStoreTests,PanelContextTests,RemoteLifetimeTests DERIVED_DATA=build/DerivedData-p1-review-services`：**76 项、5 skipped、0 failed、退出 0**。
- F-21：原 Feature 文档错称仍是游离 HEAD、未授权实施，且链接已删除的旧源文件。提交 `6ee5fdf`，Feature **162** 个本地 Markdown 路径全部可达，`todo validate` 与 `git diff --check` 通过。
- `make build DERIVED_DATA=build/DerivedData-p1-review-services` 与 `make build:release DERIVED_DATA=build/DerivedData-p1-review-services`：均退出 0、`BUILD SUCCEEDED` 且 `codesign --verify --deep --strict` 通过。只构建隔离 DerivedData，不重启／替换用户正式 Bailey、不改用户 SSH master。
- 较早全量测试 `/tmp/bailey-p1-review-full.log`：**634 项，14 skipped，0 failed**；后一次 `/tmp/bailey-p1-review-final-full.log`：**635 项，12 skipped，2 条失败（同一 Git 树原生焦点用例的渲染超时与测试历史文件清理异常）**。两次命令属于不同源码快照，不能取其一代替当前 HEAD 完整结论。F-22 保留为具体未解的原生焦点验收问题，**不凭日志直接断言产品存在 Git 焦点回归**。
- 最新 `a48593d` 全量重跑状态及退出码待命令完成后补入本节；上述定向绿灯不是此命令的完成证明。

### 全环境验收边界／Gate 原则

当前本机仅能实测 macOS 27.2／Xcode 27.2 arm64；macOS 15.6 真机、不同 CI SDK、同条件原始 GUI 的逐帧与像素证据、真实前台键鼠与 IME、Finder/Dock Launch Services、完整重启/通知点击、独立授权 Windows SSH、不同显示器及长时内存仍未取得。重用现有测试宿主或 `minimum deployment target` 无法替代其最终副作用。前台 key-window 依赖的 skipped 均明确记为**未通过条件**；不能为关闭审计而解除保存、认证、机器身份围栏或延长测试超时。P2 焦点设计仍是独立阶段；P1 完整“零 UI/UX 变化”放行须等主路径系统入口与当前实际失败原因核销。
