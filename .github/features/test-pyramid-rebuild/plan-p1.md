# P1 · 先把 Unit 底座做实

**Goal:** 从当前 Unit 86 / Integration 463 的倒置分层出发，让**孤立模型和业务决策**而非真实 IO 承担绝大多数状态、容量、错误、乱序/取消测试。Unit 不限于纯静态函数：通过已有**内存 WorkspaceBackend** 只测试一个 Model/ViewModel 的 Observation、actor/协作时序也属于 Unit。把所有模型测试误算作 Integration 是此前计划的根本错误。

**Non-goals:** 不创建新 Test Target、通用测试宿主、Mock Git、Manager/Coordinator/Protocol；不复制生产规则进测试。真正的 Git/文件/Bundle、TextKit/IME/NSWindow/PTY 是必要 Integration，不以目录调包。唯一允许的生产代码调整，是源码证实业务判断被 IO 包住时在**原领域类型**抽出最小确定性规则/状态转移，保证行为零变。

**分类与执行门槛：** 现有 11 个 Unit 文件约 86 项、35 个 Integration 文件约 463 项（同文件可含多个 XCTest 类）。逐方法检查**间接**调用：A = 无 IO 的纯规则/值；B = 内存 backend 模型/actor 状态机（含可控失败）；C = 真 Git/磁盘/进程/网络；D = Native AppKit/TextKit/IME；E = 真完整 App 用户路径（不应留宿主）。**A+B 进入大量 Unit**；C/D 保留尽量少的 Integration，E 由 P3/P4 E2E 处理。不能仅凭方法名、async/throws、有无直接 FileManager 判断归属。记录测试发现数和 setup/真实 IO 成本，P1 不再以搬走几十个纯 parser 就宣称建成底座。

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

## P1-T3 模型时序状态成为 Unit，并解开真实 IO 对策略测试的绑架

**Source-backed entry points:** BaileyTests/Integration/Files/FileTabPersistenceTests.swift 的 FileTabPersistenceTests/NativeFileTabTests、Workspace/PanelContextTests.swift、Workspace/WorkspaceIdentityTests.swift、Git/GitStatusModelTests.swift、Remote/RemoteLifetimeTests.swift、Settings/AppSettingsTests.swift、Workspace/SessionStoreTests.swift；生产 FileTab、PanelContext、FileTreeModel、GitStatusModel、WorkspaceBackend。P1-T1/T2 已确认的 parser、图谱拓扑与远端安全字符串不重复增加测试。

**已确认候选不是已证实可迁数量：**
- FileTabPersistenceTests 的 49 项中 **22 项没有显式重型 IO**，很多用现有 EditorWorkspaceFixture 内存 actor 验证延迟 read/write、断线重连、旧刷新、保存失败和撤销；PanelContextTests 12 项中 **10 项**通过 DelayedWorkspaceFixture 验证后台目标切换和乱序发布。
- WorkspaceIdentityTests 中的 Terminal 文件拖入转义、控制 socket 命令构造；RemoteLifetimeTests 中的内存连接/观察状态；GitStatusModelTests 中的 Worktree 解析、Rename/Copy 路径；AppSettingsTests/SessionStoreTests 中的纯设置/快照规则也都要按实际依赖检查，不仅挑 22+10。
- NativeEditorLayoutTests 的多数方法虽然没有显式 NSWindow 调用，却可能通过 helper 实际构造 NSTextView/NSWindow；NativeFileTabTests.testNativeReadOnlyRejectsAXValueAndSelectionReplacement 即使没有显式文件 IO，也访问真实原生 View，**必须留 Integration**。这类误判必须通过追溯 helper 排除。

**Steps:**
1. 在不生成第二份冗长 TODO 的前提下，对 35 个 Integration 文件**每个 test 方法**核对调用方、shared setUp/tearDown、helper 和最终资源：把 A/B/C/D/E 标记到当前任务审计证据；证明某项无真实 OS 边界后，才作为 Unit 承接。
2. 逐项将 FileTab/PanelContext 等真正**只通过内存 Backend**的异步 Model/ViewModel 测试迁入 Unit；保留原每个异常、并发、取消/重试、Unicode/目标身份的 XCTAssert。复用唯一 EditorWorkspaceFixture / DelayedWorkspaceFixture 定义，避免为每层复制一套测试 Backend；不引入虚假 Git。
3. 对那些必须先 git init 或写磁盘、但实际只想验证 Git ref 合法性、FileTab 保存决策、目标身份/错误状态等**独立策略**的测试，沿现有 Model/Backend 边界定位原因；若当前已存在纯入口，直接调用它；否则在**原类型**抽出最小确定性判断，先补 Red Unit 再核对旧 Integration 行为和真实副作用。真正 IO（Ref 写入、文件字节、原生提交）仍由 Integration 测一次，不移入 Unit，也不为纯化引入另一套产品状态。
4. 新层次接入后**同一 task 删除旧 Integration 方法和失消费者 helper**，不保留两个目录各跑一份的重复测试；真正 Native/文件/网络测试原样保留。不能靠大量相同输入改名字增加 Unit 方法数。

**Verify:** 每个拆分批次先运行相关 Unit 类（如新 FileTabModel/PanelContextModel/WorkspaceIdentity/GitPolicy 类），再定点运行 FileTabPersistenceTests、NativeFileTabTests、PanelContextTests、GitStatusModelTests、RemoteLifetimeTests 等**真的受影响**的 Integration；Xcode 原方法的独有断言和错误路径均可发现并执行。验证内存后端：同时读/写、旧结果回写、断线/恢复、取消、初始加载、失败保存保留字节、Project/机器隔离；真实 IO 仍分别有临时文件/Git/原生窗口合同。记录可比较的**仓库初始化、磁盘、NSWindow、命令和测试耗时**；只迁路径没有减少成本则如实计为归属纠正。

**Commit:** 一个原子提交。若 35 个文件跨域过多，应按已有 P1-T1/P1-T2 的 owner 收拢，不做新的空抽象；文档只更新稳定的测试职责。

## Phase Audit

audit-p1.md 先核销原 86+463 个方法的真实调用依赖与分类，不以静态关键词扫描替代完整调用链。必须说明 **22+10 项内存模型候选的实际去向**、其它模型的新增 Unit、从 IO 中抽出的原有判断、以及哪些原生/文件/Git Integration 不可下沉。**P1 的 Go 只表示已将确认的纯/内存模型测试归到 Unit，并明确了 P2 需要进一步拆开的真实 IO/策略耦合，不能把它宣称为最终金字塔达标。** 若仅搬了几个 parser、没有核对其余状态模型和 P2 的具体耦合入口则 No-Go；最终 Unit 多于 Integration 的结构 Gate 在 P2/P4 核验，避免依赖后续阶段才能完成的 P1 死锁。
