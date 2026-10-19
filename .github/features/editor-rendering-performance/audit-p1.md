# Audit P1 - editor-rendering-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/editor-rendering-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 定位文档高度与滚动条跳变的布局反馈
- [x] P1-T2 稳定文档几何与可见内容滚动锚点
- [x] P1-T3 支持小文件首开与十万行代码完整编辑
- [x] P1-T4 降低编辑热路径的整文成本和内存占用
- [ ] P1-T5 验收四档文件的稳定滚动和低资源编辑

## 任务到文件的映射

- **P1-T1 · `f0a0cc0`**：`EditorNavigationTests.swift`、`TextCoordinateIndexTests.swift`、`docs/testing.md`；修改前 STTextView 的真实几何 Red 和输入成本已记录在 `evidence-p1.md` 的 T1 段。旧控件后来由 T4 完整淘汰；不能用新控件的绿灯改写旧基线。
- **P1-T2 · `9f11b53`**：旧 `SourceTextEditor.swift`、`Vendor/STTextView` 的视口、行号及滚动，`EditorNavigationTests.swift`、`TextCoordinateIndexTests.swift` 与编辑器文档；该实现已由 T4 的 `647dc44` 删除，继承的行为契约由当前原生 TextKit 2 的导航／重挂载／行号／像素回归验证。必须在当前控件判断是否回归，不复活旧补丁。
- **P1-T3 · `171cd1b`、`237f91e`**：`FileViewerView.swift` 的 8 MiB 文本上限、`LocalWorkspaceBackend.swift` 与 `SSHWorkspaceBackend.swift` 的有界读写、`SSHHostWorkspaces.swift` 压缩，`FileTabTests.swift`、`RemoteCommandsTests.swift`、`SSHFileTreeLiveTests.swift`；真实调用链：文件标签 → 后端 read/write；远程后端 → SSH 进程 → `ProcessStdinWriter`。本轮 F-01 已真实 Red→Green 修复管道超时，单独补测后仍保留完整 T3 测试链路。
- **P1-T4 · `e97494b`、`d237f20`、`4945666`、`647dc44`**：`FileTab` 精确判脏与串行保存；`TextCoordinateIndex.swift`；`SourceTextEditor.swift` → `NativeCodeTextView.swift`／`NativeTextLineIndex.swift`，`SyntaxHighlightConfiguration.swift` 与 `Vendor/Neon`；Diff 走 `DiffNativeSurface.swift` → `DiffTextView.swift` → 同一原生 NSTextView/TextKit 2；Xcode 工程中的 `Vendor/STTextView` 和插件运行依赖已删除，保留由该源码改编部分所需授权文件及独立语法资源。回归入口：`EditorTextInputTests`、`SyntaxHighlightingTests`、`FileTabTests`、`DiffTabTests`、`TextCoordinateIndexTests`。
- **P1-T5 · `f687758`、`561a0f3`、`2358cdb`、`d433d47`、`6e9342b`、`12a15b6`、`230b29c`、`08cf95b`、`817b0dd`、`380d762`**：四档滚动/输入 24 组合 ×30 对；行号、Diff 背景、查找栏、最长行、窗口重挂载的像素／语义回归；5 轮 ×5 原生编辑器弱引用释放；双窗口原生 AX 保存；外部重载后过期 NSScrollView 文档退役。历史 `458/458` 的授权 Windows SSH XCTest、Debug/Release 验签与已安装 Release、五分屏真实渲染/静置采样、前台独立 Release ⌘S 真写盘均见 `evidence-p1.md`，不代表本次审计重新跑过，也不代表 Release 实际关闭五分屏后的 Allocations 已通过。**`todo.toml` 仍为 in_progress。**

## 审核原则与历史边界

只将 `todo.toml`、各任务 Git diff、现行源码的真实调用者和最新可复核的运行结果作为判断依据；历史 `audit*.md` 未作为结论来源。原 plan 中对 STTextView 的几何修复被后续用户决定的原生迁移替代，属于需求演进，不是未安装的双轨代码。公开 C parser 生成源码按固定包来源/编译/版权确认，不逐行人为评审上百万行生成代码。避免影响并行 Bailey 工作和用户正式进程，所有本次测试仅使用隔离 DerivedData／测试目标；用户真实工作区、签名身份及 SSH master 不清理。

## 发现项

## 发现 F-08

- 任务：`P1-T5`
- 严重级别：`Low`
- 状态：`Open`
- 位置：`Bailey/UI/WorkspaceDockView.swift:467-470`
- 摘要：`独立优化 Release 反复停靠标签后，SwiftUI 原生标签菜单存在约 3.5KiB 的 ContextMenuResponder 根引用环`
- 风险：`在两次独立进程的真实 xcrun leaks 中重现约 31-32 对象的 ContextMenuResponder.AppKitMenuDelegate 与 ContextMenuResponder 强引用环，包含 pane-4.swift 的菜单字符串；当前未见 FileTab 或语法高亮对象被该链持有，尚不能确定 AppKit/SwiftUI 自身问题还是 Bailey 触发方式。单独 12 次右键取消出现的每次 32B _NSMenuIntelligentAssistantConfiguration 与此不同，只有小量资源影响证据。`
- 预期修复：`先用真实可见菜单／取消、Close Files、Dock 重挂载及短/长静置对照复现条件；通过 Instruments 持久对象反查实际分配与平台链路。仅在证实 Bailey 自有闭包或对象所有权导致环后从真正所有者修复，不为约 3.5KiB 的框架保留链直接重写原生菜单或破坏 UI/UX。`
- 验证：`复用隔离 Release 原生 GUI，分别测试 12 次菜单开关、执行 Close Files、关闭后重挂载五分屏及应用失焦；leaks/heap/vmmap/Allocations 每阶段取证，重复多个 PID，确认是否累积且文件内容不变；必要时按 AGENTS 执行完整 Debug/Release XCTest 与严格签名。`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-07

- 任务：`P1-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/Panels/ToolPanelView.swift:205-250; BaileyTests/NativeUI/Git/GitExternalRefreshTests.swift:309-356`
- 摘要：`真实 Windows SSH 外部 Git 已暂存成功，但可见面板在无需操作的空闲状态下持续显示旧未暂存快照`
- 风险：`完整 466 项回归外部 Git 自动刷新失败；完整 GitExternalRefreshTests 重复第 2 轮复现远端 status 已为 M staged、模型 staged=0/changed=1/isRefreshing=false/isBusy=false/statusError=nil；前台轮询任务或测试模拟的激活通知可能未实际运行，用户可被持续陈旧的远端 Git 视图误导。`
- 预期修复：`确认已挂载可见面板的 active notification 与 task 生命周期和实际远端命令结果；修复共有所有权/信号边界，而不是加长刷新超时或只重跑 XCTest。若确系模拟系统前后台的测试夹具缺陷，则以真实 onAppear/Task 生命周期握手取代固定 sleep，并验证真实最终 Git staged/ref 副作用。`
- 验证：`完整 GitExternalRefreshTests 重复、两种 Git 变更阶段及真实 Windows SSH 外部写入；远端 porcelain 与本地模型一致、前台可见自动刷新、后台停止、恢复补读、隐藏停止、错误恢复；完整有授权的 Windows SSH XCTest 与 Debug/Release 签名。`
- 解决证据：`提交 7aa3633：真实 Windows SSH 外部 git add 与正在进行的慢详情查询交错时，原 ToolPanelView 忽略当前 poll 丢失新状态；受控 NativeUI 旧代码连续两次 Red。改为可见 SwiftUI .task 内可取消等待，轮询结束补读；隐藏后不发新命令，中间全局 pendingRefresh 方案隐藏后额外 SSH 查询的 Red 已排除；最终 NativeUI 并发+隐藏五轮 Green。GitExternalRefreshTests 真实 Windows SSH 四轮 4/4=16/16，GitStatusModelTests 27/27；最终提交版完整 BAILEY_P4_TEST_SSH_HOST=windows make test 467/467、0 failure、0 skip、exit0、765.296s（audit-p1-final-full-windows-7aa3633.log）；make build 和 make build:release 同一提交均 BUILD SUCCEEDED，严格 codesign 退出0，macOS minos15.6/arm64 已验证。独立优化 Release 全量测试另行进行，F06 按 UI/UX 不变约束独立处理。`


## 发现 F-06

- 任务：`P1-T5`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`Bailey/Support/FPSCounter.swift:20-31,64-73; Bailey/UI/Components/WorkspaceChrome.swift:331-348`
- 摘要：`FPSBadge 把 CADisplayLink 的显示器回调频率标成 fps，无法证明 Bailey 确实绘制并呈现相同数量的新帧`
- 风险：`用户在 120Hz 内建屏或 60Hz 外接屏看到数值时会误以为编辑器达到了对应实际 FPS；跨屏移动时链接只在 start 时绑定 NSScreen.main，难以代表当前视图刷新。不能用该读数关闭 T5 性能 Gate`
- 预期修复：`保持本轮原生编辑器 UI/UX 不变；测量必须用 Instruments 实际合成帧/卡顿数据。以后如需产品 FPS HUD，必须对实际呈现帧取得可靠观测；否则把数字明确改称显示刷新回调/Hz，不伪称绘制 FPS`
- 验证：`CGDisplayCopyDisplayMode 与 NSScreen.maximumFramesPerSecond 核验屏幕 Hz；Core Animation Animation Hitches 真实 Release 窗口滚动期间追踪；区别 CADisplayLink tick 与新内容帧`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-05

- 任务：`P1-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift:435-546; Bailey/Editor/SourceTextEditor.swift:283-301; Bailey/UI/WorkspaceDockView.swift:453-472`
- 摘要：`连续两轮完整 Windows SSH XCTest 的真实 WorkspaceDockView 原生编辑器退役后存在未释放对象，且失败目标随顺序变化`
- 风险：`第一轮 466 项中旧视图退役释放超时，第二轮无并行编译仍在 Close Files 五编辑器 weak FileTab/editor 的回收失败；可能是 AppKit First Responder/SwiftUI 旧宿主或长生命周期强引用，真实 Release 前台也曾缓存单个旧 TextView，需要区分系统有界保留和应用残留`
- 预期修复：`在原有 XCTest 与受控窗口中记录究竟是哪类旧对象/窗口 First Responder 仍被强持有；以真正所有权边界修复，不扩大任意等待超时或用定时释放补丁；若只是系统正常短暂缓存则修正测试的不当假设并提供可证明确切最终回收/有界峰值的等价断言`
- 验证：`重复真实五分屏窗口关闭及外部重载，记录按 file/editor 分别统计的残留和引用树，Run focused + full PaneRetentionTests、完整 Windows SSH 466 项、Debug/Release 构建严格验签、独立 Release GUI 五轮和物理内存对照`
- 解决证据：`commit e0e147f: old Project.tabs ownership persists after TerminalManager.remove, and retireObsoleteDocument skipped previously detached FocusReportingTextView; both reproduced Red. Green: 5 complete PaneRetentionTests runs x15/15, 0 failures; full Windows SSH suite PaneRetentionTests 15/15 including former failing five-pane Close Files and retired editor release. Test checks immediate project tabs removal, parser deactivation, detach, and weak file/editor nil after host teardown; AppKit transient view cache not confused with a lasting owner. Latest full suite still has an unrelated SSH Git external refresh timeout under investigation.`


## 发现 F-04

- 任务：`P1-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/TerminalManager.swift:79-86,396-418`
- 摘要：`关闭项目或窗口时，另一个原本干净的编辑器在等待首个文件写入期间产生新草稿，关闭流程不再复查其脏状态`
- 风险：`单次批量关闭先采样待保存文件；等待远端写盘期间其它标签可被编辑，后续直接 project.terminateAll/remove 或返回允许窗口销毁，丢失刚产生的未保存编辑`
- 预期修复：`在项目与窗口关闭共同的最终销毁边界重新核验全部在场文件，不吞掉关闭期间新出现的 dirty；保持现有保存串行与失败阻止关闭语义`
- 验证：`EditorWorkspaceFixture 受控暂停第一个远端写入，另一个原本干净的本地文件修改，再继续写入；两入口先 Red、后 Green，并核对磁盘字节和关闭取消；运行 FileTabTests/WorkspaceWindowCloseTests 与全量 Windows SSH XCTest、Debug/Release 严格验签`
- 解决证据：`commit 2347f45: 受控远端写暂停覆盖 Project.closeFiles、关闭项目、关闭窗口和跨窗口 App 退出；Red 3 入口复现失效，Green FileTabTests 49/49、0 failures；最终提交版完整授权 Windows SSH XCTest 466 项中 F04 新增全部通过，但 PaneRetentionTests 既有弱引用时序一项间歇失败，独立列 F05；make build:release DERIVED_DATA=build/DerivedData-audit-f04-fps-release 退出0，codesign --verify --deep --strict 通过。不将全量 466 项误报为全部通过。`


## 发现 F-03

- 任务：`P1-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/WorkspaceDockView.swift:453-474,543-596`（旧 Tab 强引用）；`Bailey/Workspace/Project.swift:725-736,915-936` 为触发入口
- 摘要：`独立 Release 关闭全部五个文件标签后，原生编辑器和 FileTab 对象持续存活`
- 风险：`实际 Close Files 两轮后 AXTextArea=0、文件标签全部消失，但静置多次 heap 检查仍有 6 个 FileTab、FocusReportingTextView、SyntaxHighlightCoordinator 和 NSTextViewportLayoutController；可能随反复开关累积缓存和原始文档`
- 预期修复：`沿真实 Project.closeFiles→closeBatch→removeTabWithContent→Dock/SourceTextEditor 卸载所有权链确定具体强引用，修复单一 owner 的生命周期，不用每帧清空视口或定时 GC 补丁`
- 验证：`隔离 Release 五标签打开→Close Files→重开→再次关闭，使用真实 AX 数、heap 类实例与 vmmap/Allocations 对照；追加 WorkspaceDockView/Project 真实关闭生命周期 XCTest Red→Green、所有受影响回归与 Debug/Release 验签`
- 解决证据：`cd039a1: 实测真实 Release 五个 10k 行文档右键 Close Files，AXTextArea 5→0；4秒后 heap FileTab/FocusReportingTextView/SyntaxHighlightCoordinator 5→0，vmmap physical footprint 273.2MiB→99.7MiB；独立 PaneRetentionTests 先 Red（真实旧标签/项目强引用/旧 documentView），再 Green 15/15，含 Project.closeFiles 与 TerminalManager.close(Project)；最终提交后的 Windows SSH 全量 make test 462/462、0 failures、exit0，813.962s，日志 build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log；最终 Release make build:release 和 codesign --verify --deep --strict exit0，已通过相同签名整包安装 /Applications/Bailey.app，旧正式 PID86913 未退出。五轮连续 GUI 因用户 Space 切换导致精确窗口失效未测完，仍属于独立 T5 Gate 未满足条件，不宣称连续内存曲线全部通过。`


## 发现 F-02

- 任务：`P1-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/NativeUI/Editor/EditorNavigationTests.swift:18-44,650-692; Bailey/Editor/SyntaxHighlightConfiguration.swift:358-369`
- 摘要：`四档输入延迟回归使用未安装真实语法高亮的裸 NSTextView；100k 实际文件输入热路径缺基准`
- 风险：`真实 Swift 文件每次编辑还会进入 SyntaxHighlightCoordinator.didChangeContent 与 TreeSitterClient；裸视图 16/32 ms 预算通过不足以证明用户实际加载语法资源后的输入体验`
- 预期修复：`补充在真实原生 TextKit 2 + Neon/TreeSitter 安装并完成初次解析时的 100k 行文首／中／末输入延迟和源字节／语法树一致性回归，不复制第二套编辑器`
- 验证：`附带真实插件的量化输入日志、median/p95/worst 与完整修复后 XCTest；性能预算不满足即保持 Gate No-Go`
- 解决证据：`补测原 T1 混合长度真 FileTab + SourceTextEditor + Neon/Tree-sitter: make test ONLY_TESTING=BaileyTests/SyntaxHighlightingTests/testFourSizeRealFileTabHighlightedInputAndParserBudget (退出码0,1/1)。382/1000/10000/100000 行 × 折行两态 × 文首中末 ×30 次共720次；10万行最慢 median 1.044ms / p95 1.452ms,均低于16/32ms；每组原生正文与 FileTab 字节相同，解析树全文长度正确，撤回编辑后 isDirty=false。日志 build/performance/editor-rendering/audit-p1-real-file-highlight.log。完整版 make test 460/460 退出码0，早于补测增加，独立补测另计。`


## 发现 F-01

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:288-312`
- 摘要：`本机进程输出管道超时依赖后代关闭描述符，可能无法按 deadline 返回`
- 风险：`后代持有 stdout/stderr 而非 stdin 时，reader DispatchGroup 等待 EOF；超时后无界 readers.wait 并可能对已退出父进程 terminate，导致工作区命令卡死或原生异常`
- 预期修复：`在真实 runSync 所有者以非阻塞 poll 同时排空两条输出管道，使用单调时钟统一约束读取与父进程退出；超时仅终止本次启动的父进程，不等待后代 EOF`
- 验证：`RemoteCommandsTests 真实 Python fork/setsid 后代分别继承 stdout 与 stderr 的 Red→Green，并跑受影响回归、全部 make test、Debug/Release 验签`
- 解决证据：`真实独立 Python fork/setsid 子进程分别继承 stdout/stderr、父进程正常等待或立即退出，deadline=0.2s。原实现 Red 两失败: 1.612/1.640s（audit-p1-pipe-red-confirmed.log, make test exit2）；改 runSync 单调截止时间+双路 nonblocking poll，超时仅按精确 PID 结束所启动进程且关闭父侧 FD。Green 四种输入/父子时序的单次返回限0.85s，双路各256KiB 完整读取/无丢字节，RemoteCommandsTests 19/19（audit-p1-process-final.log exit0）；完整含 Windows SSH XCTest 460/460（audit-p1-full-windows.log exit0）、make build 和 make build:release + codesign --verify --deep --strict 全部退出码0（audit-p1-debug-sign.log/audit-p1-release-sign.log）。`


## 修复日志

- **F-07，P1-T5，提交 7aa3633，Resolved：** 远端 Git 在查询慢详情期间完成暂存时，旧可见面板直接跳过周期请求而遗漏新的核心状态；最小 NativeUI 两次 Red。全局模型排队的中间方案曾在面板隐藏后额外查询，再经隐藏后外部写入 Red 排除。最终将补读留在可取消的 SwiftUI 可见任务内，不增加超时或全局缓存。并发／隐藏组合五轮 Green、授权 Windows SSH GitExternalRefreshTests 四轮 16/16、GitStatusModelTests 27/27、完整 Debug XCTest 467/467、0 失败，Debug／Release 严格验签通过；UI 布局、颜色和交互不变。优化 Release 全量测试另证。
- **F-05，P1-T5，提交 `e0e147f`，根因修复完成、全量回归中：** Red 复现表明旧 Project 从 `TerminalManager.projects` 移除后仍保留 `tabs`；SwiftUI 旧宿主短暂引用项目时，文件不能及时释放。同时，旧原生文本视图先被 AppKit 从 `NSScrollView.documentView` 分离后，`Coordinator.retireObsoleteDocument()` 仅查当前 documentView，遗漏确切旧视图的 `syntaxCoordinator`。修复仅在**显式关闭项目**的 `TerminalManager.remove` 清空标签数组（不改通用 `terminateAll()` 的重挂载／恢复语义），并利用 Coordinator 既有弱 `textView` 清除语法资源。真实五分屏测试继续核对第一轮 `Close Files`、第二轮关闭整个 Project，立刻检查容器/语法资源脱钩；AppKit 的旧视图可被活窗口暂存，宿主关闭后对两代编辑器和文件全部要求弱引用归零。无超时扩容、无新缓存或兼容层。`audit-f05-closed-project-red.log` 和 `audit-f05-project-and-native-clean-green.log` 记录根因 Red 阶段，修复后 `audit-f05-root-green-one.log` 及 `audit-f05-lifecycle-green-{1..5}.log`：完整 `PaneRetentionTests` **5 次 × 15/15 = 75/75 Green**；当前授权 Windows SSH 全量回归进行中，仍需按最终结果核销。

- **F-04，P1-T5，提交 `2347f45`，全量回归进行中：** `TerminalManager.close(_:)` 原先只保存开始关闭时已脏的文件，在等待远端文件保存期间，另一原本干净的标签变脏后依然执行 `project.terminateAll()`，实际丢失未保存草稿；`saveBeforeWindowClose()` 和 `saveBeforeTermination()` 同样允许在首次扫描后遗漏新草稿。受控真实 `FileTab` + 暂停远端写盘测试复现 **Red**：`audit-f04-close-race-red-confirmed.log`（47 项中 2 项失败：项目/窗口关闭），`audit-f04-quit-race-red.log`（退出应用时跨两个窗口的新草稿，1/1 失败）。根因修复仅在三个最终销毁/退出边界重新核对当前所有标签的 `isDirty`，中止可能丢失草稿的关闭；不添加新的保存管线、超时轮询或兼容状态。**Green**：`audit-f04-close-race-expanded-green.log`（`FileTabTests` 49/49），包含原本干净的文件在其它文件异步保存期间发生编辑、关闭被阻止、再次关闭写入正确字节，以及 `Project.closeFiles()` 的同源入口。更新 `docs/features/editor.md` 和 `docs/testing.md`，独立提交 `2347f45`。首轮最终源码完整 Windows SSH XCTest 执行 466 项，仅 `PaneRetentionTests.testEditorRetainsScrollAndReleasesRetiredNativeResources` 一项超时失败（10s，`audit-f04-full-windows-final.log`）；该用例执行时不慎与另一个 Release 编译重叠，已终止并行编译，随后无并行任务独立复跑该用例 3 次均通过（1.267／1.237／1.264s，`audit-f04-retired-editor-isolated-{1,2,3}.log`）。为避免误报已启动独占式完整 Windows SSH 重跑（`audit-f04-full-windows-clean-rerun.log`），未在结果出现前宣称全量通过；Debug/Release 构建验签仍待核销。

- **F-03，T5，闭环验证中：** 本机旧 Release 真实显示五个 10k 行编辑器，精确右键标签执行 `Close Files`，0 个 `AXTextArea`；在相同 PID 重新打开五个文件、再次关闭后，`heap` 连续三次间隔采样仍有 **6 个 `FileTab`、`FocusReportingTextView`、`SyntaxHighlightCoordinator`、`NSTextViewportLayoutController`**。旧进程关闭后物理足迹虽从 287 MiB 降至 168 MiB，但存活对象数量没有随关闭减少。`leaks --traceTree=0x796f5bf600 43351` 证实保留链为 `PaneTab → SwiftUI 闭包 → HoverResponder → ContextMenuResponder / SwiftUI 视图缓存`，不是 TreeSitter parser 本身。`PaneRetentionTests.testClosingMountedFiveFileTabsReleasesTheirNativeDocuments` 在真正 `WorkspaceDockView/Project.closeFiles()` 中复现 Red（exit2，10.494s 后五份弱引用不释放）；UI 层的 tab close/context menu 回调改为按当前 UUID 解析 `project.tabs`，浏览器/文件菜单也只捕获 path/address 值，不继续强捕获已关闭的 Tab。原测试 Green（exit0，0.758s），日志 `build/performance/editor-rendering/audit-p1-release-memory/f03-red.log` 和 `f03-green-attempt1.log`；本轮全量 Windows 回归和改动后的独立 Release heap／Allocations 仍待终局核销，不据此提前标 Resolved。

- **F-03 第二层实证，闭环验证中：** 第一次修复后的独立 Release PID87374 在真实 `Close Files` 后 **`FileTab=0`**，但四秒后 `FocusReportingTextView=1`、`SyntaxHighlightCoordinator=1`、布局控制器仍 5 个（随后收敛到 1）；`leaks --traceTree` 指向窗口旧 First Responder／AppKit 焦点和暂存布局视图，而非标签闭包。增强原测试强持有 5 个旧 `NSScrollView` 并将编辑器设为窗口 First Responder，明确断言真正关闭后 `documentView=nil`，再次 Red（exit2，旧滚动视图仍持有原生正文且弱编辑器不能释放；`f03-retired-red.log`）。根因修复在 `FileTab.retireNativeEditor()` 统一处理已存在的 `Coordinator.retireObsoleteDocument()`；`Project.remove(tabID:)` 仅在语义关闭时调用，磁盘内容真正替换也复用同一方法，**普通 Dock 视图重挂载不退役**。`PaneRetentionTests` 完整 15/15、exit0（`f03-retired-green.log`）；本轮最终完整 Windows suite 和再次更新后的 Release 内存验证仍需核销，未提前关闭 F-03。

- **F-03 第三层，提交 `cd039a1`，最终 Release／项目关闭补验：** `Project.terminateAll()` 除停用终端外在真实项目或窗口关闭时统一退役所有文件原生文档；新增真实五 Dock 分屏关闭整个 Project 的 XCTest 先 Red（`f03-project-close-red.log`），后 `PaneRetentionTests` 15/15 Green（`f03-project-close-green.log`），不影响普通 Dock 重新挂载与未保存保护。最终源码独立 Release `make build:release`／严格验签 exit0（`audit-p1-bounded-release/release-final-build.log`）。用同一个 Release 窗口五个 10k 行 Swift 文件，精确后台右键 `Close Files`，Accessibility `AXTextArea` 从 5 降为 0，4 秒后 `heap` 显示 `FileTab`、`FocusReportingTextView`、`SyntaxHighlightCoordinator` 均 **0**，物理足迹 **273.2 MiB→99.7 MiB**（`audit-p1-bounded-release/heap-*.txt`、`vmmap-*.txt`），仅 AppKit 视口布局缓存尚存。重复打开第 1 个文件成功，但后续桌面 Space 变动使精确测试窗口不再可操作，五轮脚本在首次循环中止，**没有五轮通过结论**（`e2e-interruption.json`）；不强抢用户前台。另一轮含 Windows SSH 的完整 XCTest **462/462** 通过（`f03-final-full-windows.log`），但它在 `Project.terminateAll()` 修改前启动；后续独立 15/15 + 最终 Release 验证覆盖新增路径；修复代码已按 6 个指定文件原子提交 `cd039a1`（未推送）。随后使用已提交的同一源码重新执行完整授权 Windows SSH XCTest，462/462、0 failures、exit0、813.962s；证据 `build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log`。
- **F-01，T3，提交 `490beb9`：** 用真实 fork/setsid 子进程继承 stdout/stderr，构造父进程存活/先退出两种时序。旧实现 `readDataToEndOfFile` 与 `DispatchGroup.wait()` 无界等待后代 EOF；最小 Red 单轮 0.2s deadline 实际 1.61～1.64s。`LocalWorkspaceBackend.runSync` 改为同线程非阻塞 `poll` 并发排空两条管道，单调时钟约束退出与数据读取、SIGTERM/SIGKILL 只作用于本次启动的直接 PID；移除不再使用的 `RunPipeData` 和独立阻塞 reader 线程。Green 对齐 4 种继承管道/父退出时序，追加两路各 256 KiB 完整内容断言；既有远端写入/二进制/EOF/断线/父先退出回归仍通过。长期契约写入 `docs/features/ssh.md`。
- **F-02，T5，提交 `0ccf8ba`：** 恢复 T1 的混合长度／空行／Unicode／长行基准样本，使用真实磁盘 Swift 文件 → `FileTab` → `SourceTextEditor` → `NativeCodeTextView + TextKit 2`，实际安装 Neon／Tree-sitter 而非裸 NSTextView；补充四档、折行两态、三位置各 30 次的可持续回归。每组核对原文/原生 FileTab 完全一致、恢复干净及解析树长度，`docs/testing.md` 将真实高亮性能与裸控件明确分开。没有添加替代编辑器、快照状态机、生产性能开关或额外兜底。
- **清理结果：** T4 的 STTextView runtime、原插件及旧桥接调用在生产项目已移除，`git ls-files Vendor/STTextView Vendor/STTextView-Plugin-Neon` 无文件；Neon 本身仍是已实际调用的增量高亮实现，BaileyGrammars 保留合法语法来源；不能为表面清理删除正在使用的授权/原生边界保护。审计没有更改现有文件编辑器或 Diff 的 UI 布局／颜色逻辑。

## 验证日志

- **当前环境：** macOS 27.2／arm64、Xcode 27.2 (27B5038j)；原分支 `backup/local-main-20261019` 基线 `380d762`，独立构建目录 `build/DerivedData-native-parity`、既有 `build/SourcePackages`，不接管其他 Bailey 进程、项目或 SSH master。
- **T1/T2：** 旧 ST 路径经原生 T4 替代，不复活废弃的旧几何补丁；现有 `EditorNavigationTests`、行号像素/首字形、滚动条高度与 knob、查找栏、Diff 颜色、窗口重挂载/恢复均进入本次完整 XCTest，100k 17 次远距双向访问高度与 knob 波动均为零，真实控件保持文本和选择语义。
- **T3：** 先 Red：`audit-p1-pipe-red-confirmed.log` 命令退出 2，2 项预期失败（0.2s 超时实际 1.612/1.640s）；修复后 `make test ONLY_TESTING=BaileyTests/RemoteCommandsTests` 完整 exit0、19/19，`audit-p1-process-final.log`。stdout/stderr 各 256KiB 完整、父直接退出/先等待/后代保留管道的四种组合、stdin 关闭/继承、SSH 后端二进制及超限等已核对。
- **T4/T5：** `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-native-parity SOURCE_PACKAGES=build/SourcePackages` → 完整 exit0，**460/460、0 failures**，约 771.86 秒；`audit-p1-full-windows.log`。其中真实 Windows 文件树与 8MiB 双向传输已过，用户文件未参与。新增真实高亮性能 `make test ONLY_TESTING=BaileyTests/SyntaxHighlightingTests/testFourSizeRealFileTabHighlightedInputAndParserBudget` → exit0，1/1，24 组 ×30 = 720 次，`audit-p1-real-file-highlight.log`；100k 最慢 median **1.044ms**／p95 **1.452ms**／worst **1.617ms**，低于原 16／32ms Gate。输入测量不冒称为系统端到端帧率，单一测试成功不冒称旧 460 项曾包含此新增用例。

- **最终提交版实测：** 在提交 `cd039a1` 后重新运行 `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-native-parity SOURCE_PACKAGES=build/SourcePackages`，**462/462、0 failures、exit0**，耗时 813.962s（`build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log`）。覆盖 Windows SSH 文件树/8MiB 双向传输/断线恢复、真实 Dock 五编辑器关闭与整个 Project 关闭、原生 UI 颜色/几何和文本保存；远端主机不支持创建 symlink 的条件仍独立记录，未冒称通过。
- **优化 Release 生命周期 XCTest 补验：** 原生 Release `make test CONFIGURATION=Release` 首次未通过编译，因为优化模块没有 `-enable-testing`，`@testable import Bailey` 无法解析；这不是产品 Release 构建错误。随后仅在独立 XCTest 构建命令中传入 `ENABLE_TESTABILITY=YES`，完整 `PaneRetentionTests` **15/15、0 failures、`TEST SUCCEEDED`**，包括五轮各五个原生编辑器输入与释放、真实 Dock 关闭文件及关闭整个 Project 的回归；日志 `build/performance/editor-rendering/audit-p1-bounded-release/f03-release-xctest-testability.log`。正式 Release 配置未改变，该测试不等同于独立 App 五轮 GUI 内存趋势验收。
- **独立 Release 五轮真实文件标签开关：** 在同一个隔离签名 Release 进程 PID16723、同一窗口中，首轮同时挂载 5 个 10k 行原生文本视图；执行真实标签右键 `Close Files`，确认 0 个文件标签／`AXTextArea`。随后连续四轮通过 Files 面板重开 5 个文件标签再关闭：Dock 自动收拢，后四轮各只有 1 个同时挂载的编辑器，不能冒称 5 分屏循环。五轮结束时 `FileTab`／`SyntaxHighlightCoordinator` 始终为 0；第 2～5 轮 `NSTextViewportLayoutController=5`、`NSTextParagraph=745` 均不增长，物理足迹 85.7／90.0／90.1／83.0 MiB。前台保留 1 个 AppKit 文本视图，在应用失焦后与全部布局缓存一起回落到 0，失焦后物理足迹 86.5 MiB。每份测试文件 SHA-256 保持不变，测试进程及独立 UUID 设置域已清理。详细原始 `heap`、窗口快照与循环报告见 `evidence-p1.md` 最新小节和 `build/performance/editor-rendering/audit-p1-bounded-release/gui-five-cycles-d3a6e550-bf0e-4055-b575-7592c4a9d13d/`。未额外改动生产源码。
- **正式 App 整包安装：** 最终 Release 构建 `BUILD SUCCEEDED`，源包、同磁盘暂存包和 `/Applications/Bailey.app` 均通过 `codesign --verify --deep --strict`，安装后 executable SHA-256 与源包完全相同：`1da5c6d785e139dfa0a9339a886c1c0fb40116a95c90d6f03d642e5c136aa840`。整包替换、无残留安装暂存或旧包备份；原正式 PID `86913` 未退出、启动或重启，新版需用户自行重启后生效。

- **构建验签：** `make build` 与 `make build:release`（同独立 DerivedData）各退出 0，均 `BUILD SUCCEEDED`，后置 `codesign --verify --deep --strict` 成功；日志 `audit-p1-debug-sign.log`、`audit-p1-release-sign.log`。Release 仍有 Tree-sitter C/C++ 生成/第三方源码固有编译警告，未篡改 vendor 或误称无警告；该早期验证时尚未安装，最终安装证据见上条。
- **历史真实 App 证据的使用边界：** 原 `evidence-p1.md` 已有独立 Release 五个 10k 行分屏实际截图、120s/90s 静置 RSS/CPU 采样，以及前台真实 ⌘S 写盘/重启仍匹配字节的后续 E2E；此为之前运行的证据，**本次后续补做了上述独立 Release 关闭与内存验收，已完成同 PID 的五轮真实文件标签开关；但后四轮仅一个编辑器同时挂载，全程 FPS 仍未测**。本轮对 UI 生产绘制源码无修改，并复跑已有真实 AppKit/WorkspaceUI 文本、颜色、行号、Diff、找回、撤销及双窗口保存回归；不能据此宣称覆盖所有实体屏幕组合。
- **未测及 Gate 影响（逐项）：** (1) 独立 Release 首轮五分屏实际关闭、后续四轮五文件标签重开／关闭及每轮 `heap`／物理内存对照已通过，但关闭后 Dock 自动收拢，尚缺五个分屏同时挂载、编辑、反复关闭的完整 GUI Allocations 曲线；`leaks` 基线和本次五标签结果不能替代该组合，仍阻塞 T5 长周期资源 Gate。(2) 无可用于测试的 **macOS 15.6／CI26** 设备/系统；本轮只有 macOS 27.2，历史项目最低系统组合未经实测，补验需对应设备/CI，保留兼容性风险。(3) 当前无隔离可验证的**真实手指触控板、不同物理刷新率/显示缩放与 VoiceOver 完整交互**；AppKit 窗口像素、AX 与测试鼠标事件不能冒充实体条件；补验需对应硬件和辅助功能交互。(4) Windows SSH 主机返回 `P4_LIVE_SYMLINK_UNAVAILABLE status=1`，说明其权限环境不能创建 symlink；已验非符号链接的重命名/二进制/读写，不把专属符号链接能力写成通过；补验需具备 symlink 权限的授权 Windows 环境。(5) 未重跑独立 Release 的完整人工高帧率滚动 FPS，Debug 插入/布局回归与既有 Release 截图不等于物理显示帧时间；补验需独立显示采样。前三项及 FPS 限制尚使阶段无法无保留放行。
- **文档核对：** `docs/README.md` 索引、`docs/features/editor.md`/`diff.md`/`ssh.md`、`docs/testing.md` 与当前实际入口一致；保留前期历史 No-Go STTextView 原型作为取证时间线，不重新加入双轨兼容，`audit*.md` 不作为审查结论。审计文档后由并行流程独立提交 `0c9b1a2`；本轮最终证据追加到同一文档，未擅自推送。
- **最新优化 Release 验证／安装／真实 GUI**：最终 Debug／Release 两套 467/467 零失败（对应日志 audit-p1-final-full-windows-7aa3633.log 与 audit-p1-final-optimized-release-windows.log），独立 Release 五分屏真实 AX 和滚动／关闭、heap、vmmap、leaks 与测试文件 SHA-256，及新 Release 整包严格验签安装已经完成；具体物理内存未回落、7 个共 144B 的 OS 对象泄漏、独立界面五分屏重复生命周期缺口与截图目录见 evidence-p1.md 最新小节。保留 No-Go，不将 XCTest、UI 数量或显示回调当作全环境完成。
- **最新 Instruments 双轮取证：** 同一个独立优化 Release PID45322 已用原生 Allocations 录制 211s、211s、126s，真正五个各 10k 行编辑器重复打开／关闭两轮；关闭后物理足迹 **120.1/120.0 MiB**，FileTab／语法协调器归零。第三轮 PID56097 的 300.87s 录制只有四个同时挂载，不作五分屏成功证据。右键菜单 12 次呈现 Apple 菜单配置对象 32B/次；另见两进程中约 3.5KiB 的 SwiftUI ContextMenuResponder 引用环但未归因 Bailey 自有状态。详见 evidence-p1.md 最新小节。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（整个 P1 尚不能无保留完成）**；F-01～F-05、F-07 均已 Resolved，**F-06、F-08 Open**。最终生产源码 7aa3633 的 Debug 与优化 Release 授权 Windows SSH 全量 XCTest 分别 **467/467、467/467、均无失败或跳过**；Debug 和 Release 构建、严格个人签名及新版正式整包安装已通过。
- 理由：独立 Release 已有两个同 PID 的真实五分屏挂载／关闭 Allocations 周期，均核对五个文件全文、关闭对象释放和 120.1/120.0 MiB 物理足迹基线；目前数据未显示两轮累积泄漏，但第三轮只恢复四分屏，距离五轮以上真正五分屏长时曲线仍有差距。另有未归因的约 3.5KiB SwiftUI 菜单引用环、F-06 实际内容 FPS 不可直接由 CADisplayLink 证明，以及未具备的实体环境；P1-T5 继续 in_progress。

## 本轮补充核查（2026-10-20）

- **F-06 帧率合同：**`FPSCounter` 只计算 CADisplayLink 回调；用同一份 Instruments `Animation Hitches` 导出的 `hitches-frame-lifetimes` 又确认三种 surface ID 合计 1,982 行，缺少 Bailey 单个编辑器实际新内容帧的归属字段。显示表面频率不可用来关闭本 finding；保持 Open。
- **F-08 根链对照：**独立使用 macOS 27.2 SwiftUI + `NSHostingView`/WindowGroup 构造原生 `.contextMenu`，确认单次右键菜单显示、Escape 关闭及 `leaks` 基线/结束均为 0。12 次循环因共享 Space 前台身份变化中止；单次对照不能归因 3.5KiB 框架引用环。保留 Low/Open，不改 Bailey 菜单和原生编辑器，详见新增 `evidence-p1.md` 段落。
- **环境及副作用：**控制 App 单独使用 `dev.local.BaileyMenuProbeF08`，中间一次录制由后台任务 120s 超时结束，并非 Bailey 闪退。构建目录已被 `.gitignore` 忽略；本轮无正式 Bailey App 安装/重启、无远端推送或产品源码修改。已有双配置 467/467 测试证据继续有效，但本轮未重新声称全量执行；总体仍 No-Go。

## 最终状态与剩余风险

- 当前状态：**6/8 findings Resolved，F-06、F-08 Open**；P1-T1～T4 completed，P1-T5 in_progress。新 Release 已于 2026-10-20 整包安装至 /Applications/Bailey.app 并严格验签，源包／安装包 executable SHA-256 均为 f791514a1f5ea74a1c48c1167ab0720212b5b6a82154c67c8924d4c7bbdb2d；用户正式 PID 20461 在安装前后不变，未重启，旧运行时仍可能使用旧代码。
- 剩余风险：F-03／F-05 FileTab、编辑器、高亮对象退役的回归和两轮独立 Release GUI 已证明关闭文件后自有对象归零；AppKit 失焦前有短时原生视图缓存，不能误报 FileTab 泄漏。另见右键原生菜单固定增长 32B/次和两次 SwiftUI ContextMenuResponder 根引用环约 3.5KiB；当前无 FileTab 被该链持有的证据，须再区分框架问题和产品触发方式，不能通过改变 UI/UX 猜测修复。缺连续五轮完整五分屏的 Allocations、真实内容帧时间、macOS 15.6／CI26/触控板/屏幕组合、Windows 符号链接权限环境，故保留 No-Go。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

