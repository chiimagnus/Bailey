# P2 · Integration 只负责真实协作，不当第二个 Unit

**Goal:** **让 463 项 Integration 实际减少到远少于 Unit 的规模**，而不是只整理几个重型 fixture。P1 先把能直接内存运行的 Model/ViewModel 放回 Unit；本阶段继续沿领域的真实 Git/文件/原生入口**拆开业务决策与 IO**，将异常、配置和时序矩阵交给大量 Unit。每个剩余 Integration 必须回答“它实际验证了哪一条无法在内存中证明的外部合同”。

**Source-backed baseline:** GitStatusModelTests 49 项、GitBranch/Commit/RemoteBranch/Stash/TagActionTests 13/14/15/12/8、FileTabPersistenceTests.swift 两个类合计 49、NativeDiffTabTests 36、NativeEditorLayoutTests 28、NativeSyntaxHighlightingTests 22、FileTreeTests 27、NativePaneRetentionIntegrationTests 20、FinderDeliveryIntegrationTests 17、WorkspaceIdentityTests 24 和 RemoteCommandsTests 19。**很多确实直接运行 Git、文件/窗口**；不能为了满足金字塔把这些硬归 Unit。也有一些测试虽不直接调用系统 API，却经共享 helper 挂载原生 View——必须追间接依赖，不凭关键词误判。

**方法：** 每个领域选一条可达源码调用链：用户/Model 动作 → 决策（身份、策略、边界、错误恢复）→ WorkspaceBackend 或系统 API → 真实 Ref/index/文件/Window/PTY 结果。没有真实副作用的内存状态归 Unit；真实边界由尽量少的 Integration 证明；**相同状态矩阵不重复为每种配置初始化 Git/NSWindow**。只有生产决策确实与 IO 耦合才原位抽最小纯规则并移除旧分支，绝不新增通用 Manager/协议/假 Git 或共享可变测试仓库。

**验收:** P2 后必须给出可比较的 **Unit / Integration 方法数、比例、真实 Git init/命令、文件创建、NSWindow/PTY 挂载和耗时**；目标是 Unit 显著超过 Integration。若 Integration 仍约 400+、只移动几十个方法，**P2 判 No-Go**，不准把“原生组件确实要测”当作全部 463 项无需优化的理由。反过来也不允许为降低数字删掉不同外部安全合同、异常恢复或内存释放验证。执行采用现有 Makefile 按受影响类定点验证，不做全量重测。

---

<a id="p2-t1"></a>

## P2-T1 Git：一条真实边界一套不重复的仓库验证

**Files:** BaileyTests/Integration/Git/GitStatusModelTests.swift、GitBranchActionTests.swift、GitRemoteBranchActionTests.swift、GitTagActionTests.swift、GitCommitActionTests.swift、GitStashActionTests.swift、GitWorkspaceActionTests.swift、NativeGitHistoryFileTests.swift、GitExecutionTests.swift；Unit/Git 的 P1 归属。

**Step:**
1. 从 GitStatusModel 的目标身份/旧 OID/Ref 保护、Commit/Branch/Tag/Stash 的决策规则与 GitCommandExecution 的真实执行边界切开检查：纯拓扑和策略归 Unit，后端/Ref/index/HEAD 真写入归 Integration。GitCommitActionTests 的纯 Drop 资格和 GitStatusModelTests 的 parser 已在 P1 下沉；同时继续查找**被 git init 包裹、其实只验证策略分支**的其它方法。重复的状态模型和 ActionTests 同一真实入口只保留必要的最终副作用 owner，立即删掉重复初始化、轮询、相同数据穷举和不再被用的 fixture；不删不同安全结果。
2. 确认 Branch/Tag 旧 Ref 替换、Fetch/Pull fast-forward/force/lease、Stash 旧 OID、Merge/Cherry-pick/Drop、冲突中断/恢复、SHA-1/256、Unicode/特殊路径和多个 bare remote 各自的**真实 Git**断言。仅存在具体空白时，在当前 ActionTest 中补一个真实边界测试；不把 E2E 的一长串后台 Git 命令原封复制进 Integration。
3. 有实际冗余时就地删除其测试/fixture helper，不把清理留给 P4。对需长期保持的 per-test 独立临时仓库不能改成共享可变仓库来换取速度。只在不降低隔离的前提下缩小初始化和无效轮询，禁止任意 sleep。

**Verify:** 分批运行 make test:GitStatusModelTests,GitBranchActionTests,GitRemoteBranchActionTests,GitTagActionTests,GitCommitActionTests,GitStashActionTests；NativeGitHistoryFileTests、GitExecutionTests 等按真实被修改的依赖定点补测。记录真实 Repo HEAD/Ref/index/worktree bytes、两个不同远端、旧请求和错误回退；不动用户 SSH/GitHub。未授权的 SSH Live suites 不运行且在阶段审计记录。

**Commit:** Git Integration 的可验证去重一个原子提交（若没有证据支持删除，保留并写明实测瓶颈，不强造变更）。

<a id="p2-t2"></a>

## P2-T2 Files/Editor/Diff：算法用 Unit，原生合同保留最小组件

**Files:** BaileyTests/Integration/Files/FileTabPersistenceTests.swift、FileTreeTests.swift；BaileyTests/Integration/Editor/NativeEditorLayoutTests.swift、NativeEditorCompositionTests.swift、NativeSyntaxHighlightingTests.swift；BaileyTests/Integration/Git/NativeDiffTabTests.swift；Unit/Editor/ 的相关几何和高亮纯算法。

**Step:**
1. 逐方法追踪 FileTab/NativeFileTab/TextKit2/Diff 的**间接**依赖，分离 UTF-16 偏移、line index、颜色范围、目录筛选、Diff token/行数以及由内存后端触发的保存决策/乱序状态机（全部归 Unit），和真实 NSTextView/IME markedText/Undo、Diff 像素、文件系统保存（保留必要 Integration）。复用 TextCoordinateIndexTests、HighlightQueryCacheTests、DiffEngineTests、P1 内存 Unit；不得把无直接 NSWindow 字符串、却通过 helper mount 的 Native 测试当 Unit。
2. 同一个输入矩阵由纯 Unit 覆盖多个字体/行数/Unicode/CRLF 组合；**一个最小原生 NSWindow/NSHostingView 合同**验证真正的 TextKit 视口、输入候选、颜色/行号、Find/Undo/重挂载；真实 disk write、冲突、断线/重读和 index/working diff 仍由文件/真实 Git Integration 覆盖。只有实际被证实完全重复的重型宿主初始化和等待才删，不能把 10k Unicode 和 100k ASCII 互认为同一验收。
3. 核对 FileTabPersistenceTests 与 NativeFileTabTests 同文件的真实类归属及是否反复挂载 PanelContentView；已有只挂**内容面板**而未挂完整 ContentView 的测试不是缺陷，不为缩短代码拆新组件。每次减法同任务删原测试及失效 helper，只有源代码证明原生对象释放/内存回落的测试才宣称资源生命周期通过。

**Verify:** 按改动运行 make test:TextCoordinateIndexTests,HighlightQueryCacheTests,DiffEngineTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,FileTabPersistenceTests,NativeFileTabTests,NativeDiffTabTests,FileTreeTests。覆盖空/长文本、10k/100k、Unicode/中文 IME/CRLF、颜色、撤销/重做、失败保存/重载/异常容量、Native weak refs 与真实文件字节。只在本阶段实际改到的类中选择；无变化不机械重跑所有类。

**Commit:** Editor/Files/Diff 真实组件职责精简一个原子提交。

<a id="p2-t3"></a>

## P2-T3 Workspace/Remote：消除伪工作区宿主与重复真实 IO

**Files:** BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift、PanelContextTests.swift、SessionStoreTests.swift、FinderDeliveryIntegrationTests.swift、NativePaneRetentionIntegrationTests.swift、WindowCloseIntegrationTests.swift、WindowOwnershipIntegrationTests.swift；Integration/Remote/RemoteCommandsTests.swift、RemoteLifetimeTests.swift、GitInteractiveRebaseIntegrationTests.swift 及确实有交叉的 Unit/Workspace。

**Step:**
1. PanelContext、WorkspaceIdentity、Window/Project 的身份判断与异步目标更替、Dock 选择、SessionStore 快照纯值在**内存 Unit** 充分测试；真实文件投递、窗口保存否决、SessionStore 写盘、PTY/WebKit DOM、TextKit 和 Native 弱引用归 Integration。审查多套测试是否为同一个 ViewModel 时序在不同最小 NSWindow 宿主反复执行，先用 Unit 承接矩阵，再在留存的组件用例里验证一次真实系统效果，立即删除冗余窗口构造/等待。
2. 核实原生测试确实使用最小 PanelContentView/NSWindow、实际 TerminalSession 或 WKWebView；**不把 PanelContentView 子串误当 ContentView 整个工作区**。确认窗口/Tab 原生对象身份必须实测同一引用、弱引用释放或进程归属；不能用 UI 标签消失代替内存释放。SessionStore 回放的真实文件及失败撤销必须保留。
3. RemoteCommandsTests 的纯解析已在 P1 迁走，真实 pipe/超时/进程退出/Socket、SSH 断线恢复仍在 Integration。可控失败先使用已有 WorkspaceBackend fixture 验证顺序与目标，**需要真实 SSH 的条件只有授权 Live 测试才能声称完成**；不用本地 fake 冒充 SSH。

**Verify:** 按实际受影响的类定点运行 make test:WorkspaceIdentityTests,PanelContextTests,SessionStoreTests,NativePaneRetentionIntegrationTests,FinderDeliveryIntegrationTests,RemoteCommandsTests,GitInteractiveRebaseIntegrationTests 等；检查真实窗口 mount/unmount、失联/拒写与恢复、文件字节、对象释放、PT​​Y/STDIO。最低 macOS、用户实体触控板、专用 SSH 主机缺位如实记录，不以 mock 或编译成功替代。

**Commit:** 仅有确切可删的重复真实宿主/fixture 时提交，否则在 P2 审计解释为什么这部分系统协作必须留在 Integration；不为了固定比例弱化验证。

## Phase Audit

audit-p2.md 对原 463 项 Integration **逐项给出内存 Unit / 真外部 Integration / 完整 App E2E 的归属及替代验证**，与 P1 已下沉的方法核对且不能重复计数。按实际 Xcode 发现和系统操作记录：少了多少真实 Git 仓库、文件 IO、NSWindow、PTY/Socket，保留了哪些不可由 Unit 替代的系统合同，真实异常/恢复是否仍能触发。**只是从 463 搬走几十个纯方法、继续让 Integration 主导整套测试，或只是把 E2E 塞到 Integration，P2 一律 No-Go**。如果独有外部合同确实无法再精简，列出方法与源码证据，不为配比牺牲安全。P3 只能在这些门禁真实有证据后开始删除顶层覆盖。
