# P2 · Integration 只负责真实协作，不当第二个 Unit

**Goal:** 463 项 Integration 中逐方法区分必要真实边界和重复规则矩阵。**有真实 Git/文件/系统/Native 状态才保留 Integration；无 IO 的状态矩阵回 Unit，同一边界的重复完整 fixture 删除或合并**。避免先把 133 项 GUI 全移入 Integration，反而让中层继续膨胀。

**证据：** GitStatusModelTests 49、GitBranch/Commit/RemoteBranch/Stash/TagActionTests 分别 13/14/15/12/8；FileTabPersistenceTests.swift 内有 FileTabPersistenceTests 和 NativeFileTabTests，合计 49；NativeDiffTabTests 36、NativeEditorLayoutTests 28、NativeSyntaxHighlightingTests 22、FileTreeTests 27；NativePaneRetentionIntegrationTests 20、FinderDeliveryIntegrationTests 17、WorkspaceIdentityTests 24、RemoteCommandsTests 19。这些方法大量涉及真实 OS 或最小 NSWindow，**不能按名称或目录一锅端**。已核对部分使用 PanelContentView 的原生宿主，不把它误判成整个 App E2E。

**Non-goals:** 不为减少 Integration 数量假造解析器、假 Git 结果或变更业务 API；不以循环中更多 XCTAssert 代替真实 Git 原子性；不增加“性能采样框架”、第三个 Target、自动选择脚本。

**共同验收：** 每个被删/降层的 Integration 方法都要有**相同触发前提、最终副作用和异常恢复**的现存或新实测替代。统计原方法数、真实 Git 子进程/文件创建/NSWindow attach/等待调用及同条件 XCTest 耗时；方法移进另一个文件、只删冗余断言却仍多次开原生宿主均不能算降低成本。所有必要 TextKit/IME、WebKit/Ghostty/PTY 弱引用和实体 Git 仍在中层验证。

---

<a id="p2-t1"></a>

## P2-T1 Git：一条真实边界一套不重复的仓库验证

**Files:** BaileyTests/Integration/Git/GitStatusModelTests.swift、GitBranchActionTests.swift、GitRemoteBranchActionTests.swift、GitTagActionTests.swift、GitCommitActionTests.swift、GitStashActionTests.swift、GitWorkspaceActionTests.swift、NativeGitHistoryFileTests.swift、GitExecutionTests.swift；Unit/Git 的 P1 归属。

**Step:**
1. 逐方法比较“领域规则已在 Unit 测过”和“真实临时 Git 执行”两类断言：例如 GitCommitActionTests 已有丢弃资格纯拓扑，真正 Drop 仍必须对 HEAD/ref/index; GitStatusModelTests 的解析从 P1 离开后，保留 Git 状态刷新、真实工作树与 OID/Ref 漂移。比较状态类和 Action 类是否在同一临时仓库重复对同一 API 做完全相同的正常/失败路径；保留能证明最终副作用的唯一 owner，并删除重复的完整初始化、轮询与相同数据穷举。
2. 确认 Branch/Tag 旧 Ref 替换、Fetch/Pull fast-forward/force/lease、Stash 旧 OID、Merge/Cherry-pick/Drop、冲突中断/恢复、SHA-1/256、Unicode/特殊路径和多个 bare remote 各自的**真实 Git**断言。仅存在具体空白时，在当前 ActionTest 中补一个真实边界测试；不把 E2E 的一长串后台 Git 命令原封复制进 Integration。
3. 有实际冗余时就地删除其测试/fixture helper，不把清理留给 P4。对需长期保持的 per-test 独立临时仓库不能改成共享可变仓库来换取速度。只在不降低隔离的前提下缩小初始化和无效轮询，禁止任意 sleep。

**Verify:** 分批运行 make test:GitStatusModelTests,GitBranchActionTests,GitRemoteBranchActionTests,GitTagActionTests,GitCommitActionTests,GitStashActionTests；NativeGitHistoryFileTests、GitExecutionTests 等按真实被修改的依赖定点补测。记录真实 Repo HEAD/Ref/index/worktree bytes、两个不同远端、旧请求和错误回退；不动用户 SSH/GitHub。未授权的 SSH Live suites 不运行且在阶段审计记录。

**Commit:** Git Integration 的可验证去重一个原子提交（若没有证据支持删除，保留并写明实测瓶颈，不强造变更）。

<a id="p2-t2"></a>

## P2-T2 Files/Editor/Diff：算法用 Unit，原生合同保留最小组件

**Files:** BaileyTests/Integration/Files/FileTabPersistenceTests.swift、FileTreeTests.swift；BaileyTests/Integration/Editor/NativeEditorLayoutTests.swift、NativeEditorCompositionTests.swift、NativeSyntaxHighlightingTests.swift；BaileyTests/Integration/Git/NativeDiffTabTests.swift；Unit/Editor/ 的相关几何和高亮纯算法。

**Step:**
1. 逐方法分开“纯 UTF-16 偏移/line index、解析/高亮范围、目录筛选、Diff token/行数”与“真实 NSTextView/TextKit2 几何、IME markedText、Undo、Diff 像素、FileTab 保存/异常”。复用 TextCoordinateIndexTests、HighlightQueryCacheTests、DiffEngineTests、P1 Unit 不在中层再建同义大矩阵。
2. 同一个输入矩阵由纯 Unit 覆盖多个字体/行数/Unicode/CRLF 组合；**一个最小原生 NSWindow/NSHostingView 合同**验证真正的 TextKit 视口、输入候选、颜色/行号、Find/Undo/重挂载；真实 disk write、冲突、断线/重读和 index/working diff 仍由文件/真实 Git Integration 覆盖。只有实际被证实完全重复的重型宿主初始化和等待才删，不能把 10k Unicode 和 100k ASCII 互认为同一验收。
3. 核对 FileTabPersistenceTests 与 NativeFileTabTests 同文件的真实类归属及是否反复挂载 PanelContentView；已有只挂**内容面板**而未挂完整 ContentView 的测试不是缺陷，不为缩短代码拆新组件。每次减法同任务删原测试及失效 helper，只有源代码证明原生对象释放/内存回落的测试才宣称资源生命周期通过。

**Verify:** 按改动运行 make test:TextCoordinateIndexTests,HighlightQueryCacheTests,DiffEngineTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,FileTabPersistenceTests,NativeFileTabTests,NativeDiffTabTests,FileTreeTests。覆盖空/长文本、10k/100k、Unicode/中文 IME/CRLF、颜色、撤销/重做、失败保存/重载/异常容量、Native weak refs 与真实文件字节。只在本阶段实际改到的类中选择；无变化不机械重跑所有类。

**Commit:** Editor/Files/Diff 真实组件职责精简一个原子提交。

<a id="p2-t3"></a>

## P2-T3 Workspace/Remote：消除伪工作区宿主与重复真实 IO

**Files:** BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift、PanelContextTests.swift、SessionStoreTests.swift、FinderDeliveryIntegrationTests.swift、NativePaneRetentionIntegrationTests.swift、WindowCloseIntegrationTests.swift、WindowOwnershipIntegrationTests.swift；Integration/Remote/RemoteCommandsTests.swift、RemoteLifetimeTests.swift、GitInteractiveRebaseIntegrationTests.swift 及确实有交叉的 Unit/Workspace。

**Step:**
1. 身份判断、Dock 选择、快照纯值在 Unit；真实文件转交、窗口保存否决、SessionStore 写盘、终端 PTY、WebKit DOM、TextKit/原生弱引用保留 Integration。按方法对照同一窗口/项目身份是否被多个 AppKit 宿主**重复构造**、仅因重挂载而执行相同操作；只删除已经有同样系统效果证明的重复场景。
2. 核实原生测试确实使用最小 PanelContentView/NSWindow、实际 TerminalSession 或 WKWebView；**不把 PanelContentView 子串误当 ContentView 整个工作区**。确认窗口/Tab 原生对象身份必须实测同一引用、弱引用释放或进程归属；不能用 UI 标签消失代替内存释放。SessionStore 回放的真实文件及失败撤销必须保留。
3. RemoteCommandsTests 的纯解析已在 P1 迁走，真实 pipe/超时/进程退出/Socket、SSH 断线恢复仍在 Integration。可控失败先使用已有 WorkspaceBackend fixture 验证顺序与目标，**需要真实 SSH 的条件只有授权 Live 测试才能声称完成**；不用本地 fake 冒充 SSH。

**Verify:** 按实际受影响的类定点运行 make test:WorkspaceIdentityTests,PanelContextTests,SessionStoreTests,NativePaneRetentionIntegrationTests,FinderDeliveryIntegrationTests,RemoteCommandsTests,GitInteractiveRebaseIntegrationTests 等；检查真实窗口 mount/unmount、失联/拒写与恢复、文件字节、对象释放、PT​​Y/STDIO。最低 macOS、用户实体触控板、专用 SSH 主机缺位如实记录，不以 mock 或编译成功替代。

**Commit:** 仅有确切可删的重复真实宿主/fixture 时提交，否则在 P2 审计解释为什么这部分系统协作必须留在 Integration；不为了固定比例弱化验证。

## Phase Audit

在 audit-p2.md 对 463 原有方法逐一分层核销，与 P1 移走的纯方法对账。列出真正减少的**真实 Git/文件/原生组件操作及可比耗时**，明示无法缩减而必须保留的 Integration 合同。如果只是目录数变化或追加新的同义测试，不批准 P3 的 UI 删除。
