# P1 · 先把 Unit 底座做实

**Goal:** 当前 Unit 86、Integration 463。把明确**不需要真实 IO/原生视图**的逻辑从 Integration 下沉，并把混在 Unit 的真实资源/文件操作纠正归属。重点不是数字，而是纯规则不再被昂贵的 Git、磁盘或 App setup 拖慢。

**Non-goals:** 不增加生产协议/Mock Git/新的 Target，不复制既有断言凑 Unit 数量；真实 TextKit、IME 和 Git 不能假扮纯 Unit。只测/改 P1 影响的代码，不提前调整 UI E2E。

**原则与门槛：** 必须审查 11 个现有 Unit 文件的 86 项及 35 个 Integration 文件内 463 项的真实依赖（包含同文件的多测试类，例如 FileTabPersistenceTests.swift 中的 NativeFileTabTests），不能只据文件夹或无 async/throws 推测是否纯。每项迁移有明确的计算入口；迁出后不能依赖旧类的 setUp/tearDown、NSWindow、真正文件或 Git。属于真实协作的 Integration 原样保留。

---

<a id="p1-t1"></a>

## P1-T1 让 Git、文件的纯规则脱离真实仓库和文件夹

**Files:** BaileyTests/Integration/Git/GitCommitActionTests.swift、GitStatusModelTests.swift；BaileyTests/Integration/Files/FileTreeTests.swift；BaileyTests/Unit/Git/、Unit/Files/ 下对应的少量职责类。业务实现只读核对 GitStatusModel.dropCommitPossible、parseWorktreeList、Entry.diffOriginalPath 与 LocalPathScope.contains。

**Source-backed cases:**
- GitCommitActionTests.testDropEligibilityUsesChildrenAndHeadNotReferenceCount **只访问静态拓扑表**，却继承该类每次都会执行 git init/commit 的 async setUp；这是已确认的成本错误。
- GitStatusModelTests.testWorktreeListParserPreservesExactPathsAndRejectsMalformedMetadata 和 testIndexedRenameAndCopyDiffPathsPreserveBothCorrectStages 只解析内存输入，不需要启动 Git 或观察模型刷新。
- FileTreeTests.testFinderImportDirectoryBoundaryIncludesRootButNotSiblingNames 只做路径边界判断、testSharedTreeStatusAndCompaction 只做树行规则，却继承 FileTreeTests 的临时目录 setUpWithError。

**Step:** 保持原断言与极值输入，在现有 Unit/Git 中选择合适的 owner 或新建最小 GitParsing/ActionPolicy Unit 类；纯路径/树规则归 Unit/Files。移动后**当场删除**旧 Integration 方法，消除其 Git/目录 setup 成本；不把 Git 解析实现复制进测试。不因编译通过就声称真实 Git 行为已验证，现有 GitAction/FileTree 真实集成继续保留。

**Verify:** 使用 make test:受影响Unit类,GitCommitActionTests,GitStatusModelTests,FileTreeTests；额外核对新纯用例的测试进程不执行 git init/commit、未创建临时目录或系统窗口，Xcode 的方法发现数未丢。原来的 SHA-1/256、Unicode/CRLF、0/1/N lane、Rename/Copy、符号链接与根目录边界仍由 Unit 快速跑全输入。真实 Git 冲突与 FileTree 后端行为仍由 Integration 证明。

**Commit:** 纯 Git/文件规则移动与旧方法删除一个原子提交。没有行为变化则不改产品文档。

<a id="p1-t2"></a>

## P1-T2 远端解析、终端输入及双向归属纠正

**Files:** BaileyTests/Integration/Remote/RemoteCommandsTests.swift、Integration/Workspace/WorkspaceIdentityTests.swift；BaileyTests/Unit/Remote/、Unit/Terminal/；BaileyTests/Unit/App/AppIdentityTests.swift、Unit/Workspace/DockWorkspaceTests.swift 及它们真实依赖的 Integration owner。

**Source-backed cases:**
- RemoteCommandsTests.testDirectoryStatAndProcessParsers、testGitBatchAndPortParsers、testUntrackedCountsRejectForgedFilenameRecordsAndNegativeCounts、testSSHStartupDestinationSeparatorKeepsRemoteCommandsUnfollowable 只验证输入字节/字符串/解析；testLocalLineReaderNeverReadsPastRemainingBudgetAndPropagatesFailure 通过内存 reader closure 验证读取预算。它们可在 Unit 运行，不需要远端 SSH/子进程。真正启动 shell、超时、Socket 和物理文件的用例留 Integration。
- WorkspaceIdentityTests.testFinderTerminalDropDoesNotInjectControlCharactersOrExecute、testProjectSSHAndWorkspaceCommandsUseTheSameScopedControlSocket 仅验证本地编码与命令构造；其它需要 TerminalSession、Project/RemoteConnection 生命周期或真实文件/SSH 的方法不能因为名称相似一起移动。
- 反向检查：AppIdentityTests 的 LICENSE 文件、Info.plist/Finder 文档注册和 AppleEvent 描述符属于 Bundle/系统 API Integration；DockWorkspaceTests 中会真正写临时文件的用例也不是真正纯内存 Unit。按方法处理，不能把整类不加区分地迁移。

**Step:** 选最少的新 Unit 文件承载纯 parser/escape/输入规则；若原 Integration 类共用不必要的 fixture，移动后删除旧 helper 的该消费者。实际资源归属只在能复用已有 Integration 类且发现路径不变时调整。**不为在统计上增加 Unit 数而移动耗时完全相同的真实协作方法**；其中确定的字符串纯用例迁移主要改善日常选择性快速回归。

**Verify:** make test:受影响Unit类,RemoteCommandsTests,WorkspaceIdentityTests,AppIdentityTests,DockWorkspaceTests（Xcode 实际名称逐一确认）。覆盖错误命令、NUL/换行/Unicode、超预算、无/多远端端口、控制字符注入、真实 Bundle 资源、临时文件/真实进程的边界；新的 Unit 测试不能以 XCTest skip 或假远端替代真实系统集成。记录方法数量与可比运行时间，**搬文件但未减少成本不单独计为“提速”**。

**Commit:** 一个原子提交；对 docs/testing.md 只更新稳定的现行测试职责，不写迁移状态。

<a id="p1-t3"></a>

## P1-T3 让纯内存异步模型测试成为 Unit 主力

**Files:** BaileyTests/Integration/Files/FileTabPersistenceTests.swift（其中 FileTabPersistenceTests 与 NativeFileTabTests 两个类）、Integration/Workspace/PanelContextTests.swift、Integration/Remote/RemoteLifetimeTests.swift；Unit/Files、Unit/Workspace 的真实模型测试 owner。生产 FileTab、PanelContext、FileTreeModel、WorkspaceBackend 实现只读审查。

**Source-backed candidates:**
- FileTabPersistenceTests.swift 49 项中有 **22 项没有直接的重型 IO 调用**；其中大量用 EditorWorkspaceFixture 这一现有**内存 actor backend**验证异步 read/write、断线、旧请求、保存失败、Undo/重连；例如 testQueuedRefreshCannotResurrectAfterDirtyEdit、testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry、testDisconnectDuringSavePreservesBufferAndBaseline、testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures。
- PanelContextTests 12 项中有 **10 项没有直接重型 IO 调用**，大多使用 DelayedWorkspaceFixture 模拟异步目标变化；例如 testPanelSyncQueueRapidThreeTargetSwitchesPublishOnlyNewestTree、testBackendSwitchDuringFileCreationAndRenameRejectsOldOperations、testOldTraversalCannotPublishAfterSwitchingRootOnSameBackend。
- 这些数字只是**静态候选数，不是已判定可搬数**：NativeFileTabTests.testNativeReadOnlyRejectsAXValueAndSelectionReplacement 虽无明显文件 IO，仍依赖真实原生 View，**必须留 Integration**；若某项间接调用 UserDefaults、NSWindow、Shell 或实际文件，也留在 Integration。RemoteLifetimeTests 同样逐方法核对其看似内存的 actor/connection 状态是否需要真实进程，不能只凭没有 throws 判定。

**Step:** 沿上述每项实际 FileTab/PanelContext→WorkspaceBackend/Project→最终状态，确认全程只用内存 fixture、无磁盘/窗口/网络副作用后，将模型状态与时间顺序测试放到最小 Unit 类，保留原 assert 和并发异常组合。已有 EditorWorkspaceFixture/DelayedWorkspaceFixture **只能有一个实际定义**：若 Unit 与 Integration 两边都用，则在同一 XCTest Target 中复用一次 test-only helper，不复制一套 Backend 或给产品新增接口。移出旧类的方法当场删除；仍需真实 AppKit/磁盘的 NativeFileTabTests 和文件保存保持 Integration。

**Verify:** 定点 make test:FileTabPersistenceTests,NativeFileTabTests,PanelContextTests、实际新增 Unit 类，以及与之共用 fixture 的受影响类；Xcode 必须发现全部原方法和真实异常分支。针对读/写同时进行、旧请求回来、重新连接、失败保留未保存文本、同路径不同机器、初始/重试和 N 次快速目标切换执行内存矩阵；检查 new Unit 不创建 NSWindow/真实 Git 仓库或网络。如果只是移动而没有改变耗时，记为“正确归属/快选”，不能报告为提速。

**Commit:** 一条原子提交；本任务补充到 P1 下层，优先处理确实可独立跑的模型测试，不为倒金字塔凑数字。

## Phase Audit

使用 audit-p1.md 核对 86+463 方法的真实归属，并明确 P1 减少了哪些 Git init、目录创建和进程/窗口前置操作。特别报告 **22+10 项内存候选的实际去向**，区分真的 Unit 与必须留在 Native Integration 的方法。所有应迁移的已证实模型逻辑与原本真实 Integration 都必须被 Xcode 发现；不能以“Unit 数增加”为唯一 Go 证据。
