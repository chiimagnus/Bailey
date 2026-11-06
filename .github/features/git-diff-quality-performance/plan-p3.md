# P3：Git 来源、Diff 计算、异步更新与语法资源收敛

**Goal：** 保留 Git 正确性与工作区原始字节，在已证实的真实开销处消除冗余
子进程、行计算、过期任务及隐藏布局的无效派生工作。

**Non-goals：** 不偷换 HEAD／Index／Worktree 比较语义，
不重写全仓 Git 操作，也不在没有数据时先建批量 Git 服务、复杂 worker pool、
增量解析基础设施或三套缓存层。

**Approach：** 以 P1-T4 的每阶段耗时与 snapshot 反例为依据，
**先修已证实的远端输出预算缺口**；本机锁定 OID 后的两次
size／blob 读取约 47 ms，一次性 batch 约 19 ms，
已满足同链减少启动的实验前提，须用完整错误矩阵验证后替换；
然后处理初始 Git patch、编辑后的纯算法和任务生命周期，最后处理实际可见语法。
另有已证热点：1000 对 400-token 行内投影约 37 秒，
可见语法热查询单区间约 37 ms 中约 36 ms 属于全字节重复比较；
分别由 P3-T3／T4 的现有资源 owner 收敛，不新建通用缓存层。
数据边界按已有 `DiffTab`、`DiffCore`、
`GitWorktreeComparison` 和 `WorkspaceBackend` 执行。

**Acceptance：**
- Staged／Unstaged／历史来源不混淆，Index 和原始工作区快照一致；
  有 filter 的规范化只读结果不覆写原文。
- 当前真实瓶颈的同机可见模型准备与可输入延迟有量化改善；
  最差/P95 不因减少 Git 命令而恶化，SSH RTT 单独报告。
- 旧 Diff／语法计算任务取消后及时停止，不持有标签／文本或回写过期的折叠、颜色和编辑装饰。
- 必需的投影／语法路径复用同一内容版本；未使用的路径不产生重大 CPU／heap 成本，
  取消后无不完整差异结果。

**Rules：**
- P1-T4 对具体热点没有证明时，任务可以以“证明现实现无需改动”完成探索核销，
  但不得虚构性能提升或提交空包装。
- Git clean filter 和 index 校验顺序是正确性条件；不为省几十毫秒让不同时间的 Git 与文件被拼接。
- `DiffCore.computeIfActive` 已有协作式取消；复用并验证，
  不再复制 token/generation/retry 层级。
- 所有真实写操作只能发生在隔离临时仓库；Windows 远端需专门授权。
- 每个修改任务先用 CodeGraph 区分真实调用者、测试专用读者和仍必要的数据保护，
  在新链路完成的**同一提交**删除被替代旧代码并修订测试，不把清理推给 P4。
  相应文档 owner 同任务更新；没有产品变化的测试核销不制造假重构。

<a id="p3-t1"></a>
## P3-T1 修复 Git 输出预算与对象完整性

**结果：** 本机／SSH 的 Git stdout 上限在**命令执行和接收阶段**确实生效，
超限、截断或进程失败不发布伪造完整 Diff，
Blob 选择和 Git patch 保留锁定 OID、尺寸和真实错误语义。
若 P1 证明 Blob 元数据／对象读取的串行启动是显著模型延迟根因，
**在同一 Git 读取 owner 中消除已证实的多余启动**，而不是仅修输出边界后把性能问题延期。

**Files／实际路径：**
`Bailey/Git/DiffViewerView.swift` 的
`DiffTab.gitContent/gitObject/firstGitContent/requiredGitContent/reload`；
`Bailey/Git/GitCommandExecution.swift` 的 `runData/run/runProcess`；
`Bailey/Workspace/WorkspaceBackend.swift` 的 `WorkspaceBackend.run`；
`Bailey/Workspace/LocalWorkspaceBackend.swift` 的 `runSync`；
`Bailey/Remote/SSHWorkspaceBackend.swift` 的 `run` 与 `RemoteCommandRunner`，
对照现有 `ProcessRemoteCommandRunner` 的 stdout／stderr 接收。
`BaileyTests/Git/{GitExecutionTests,NativeDiffTabTests,NativeGitHistoryFileTests}.swift`、
`BaileyTests/Remote/{RemoteCommandsTests,RemoteLifetimeTests}.swift`；
协议接入还涉及 `Bailey/Remote/SSHHostWorkspaces.swift` 的 `SSHHostCommandRunner`，
以及交互式 SSH／Files／Git 状态的现有调用方与测试实现者。

**步骤：**
1. **先写真实失败前提：**`GitCommandExecution.runData(stdoutLimit:)` 在非本机 backend 上
   先完整取得 `WorkspaceRunResult.stdout`，随后才 `prefix(limit)`；
   注入远大于上限的 Git stdout／stderr、缓慢流、异常退出、取消和错误对象；
   另查 `DiffTab.gitComparisonBaseline` 的 `hash-object` 直接经 `WorkspaceBackend.run`
   收到完整结果后才检查 `stdout.count <= 128` 的旁路。
   记录接收字节、峰值内存、调用方是否误把截断 patch／Blob 当作完整结果。
   用 `RemoteCommandRunner` 受控测试验证真正的接收边界，不能只断言最终 Data 长度。
2. 在实际拥有进程 stdout／stderr 的最小正确层提供**受预算约束的读取／失败信号**；
   先核对现有 `RemoteCommandRunner` 能否复用已有读取及取消逻辑，
   只有实际接口确实不足时才添加必要的限定输出能力。
   `RemoteCommandRunner.run` 当前由 `SSHHostCommandRunner` 实现，另有多处测试替身；
   若触及共享 `WorkspaceBackend.run`／`RemoteCommandRunner`，必须沿
   `GitStatusModel`、SSH Files、交互式终端命令等可达调用者核对真实输出需求，
   不给所有命令加隐式统一截断（会破坏 Git 大仓状态与目录清单），
   也不为一个 Git Diff 创建常驻 SSH 代理、通用 ProcessManager 或旧 API 兼容双轨。
   已有 `adaptive-large-files` 的稳定分段 IO 如在实施前落地，
   必须复用它而非再建第二套流式读取。
   不能通过 SSH 命令后接 `head` 隐藏原 Git 退出状态；超限必须是明确失败，
   不能作为正常短输出或“无修改”成功发布。
3. 复核 `gitObject → cat-file -s → cat-file blob` 真实调用链，区分
   不可变 OID 的定位与可安全合并的大小／正文读取。
   **若 P1-T4 在同环境证明它是 1k／24k 模型中位／P95 的实质热点**，
   用最短、经 Red→Green 验证的 Git 原生对象读取路径减少进程／SSH 往返；
   继续验证类型、OID、byteCount、5 MiB 边界、短读、退出错误及状态取消。
   若实测开销不足以构成瓶颈，保留现有实现并明确证据，
   不创建 Git batch daemon、进程池或无实际消费的替代接口。
   Staged HEAD/Index 当前已并行；不能把既有优化重复计算为收益。
   P1 本机 24k 行 30 次测量：size／blob 各约 23 ms，
   一次性 `cat-file --batch` 约 18.21 ms（P95 20.35 ms），完整输出字节已核对。
   同条件可消除的启动已证实，采用锁定 OID 后的一次性 batch 作为实施候选，
   仍须先核销类型、缺失对象、短读、超限、异常退出和取消；不引入常驻进程。
4. 在 `gitContent` 已锁定 OID 之后接入经验证的最小实现；
   同时覆盖 `gitComparisonBaseline` 的 Git patch 输出（其预算不同于 Blob 5 MiB），
   保留 index／tree 原始 NUL path 解析、冲突阶段、无效提交、权限、
   超时、短读、二进制、非法 UTF-8、5 MiB 既有限制与快照代次。
   新读取确实替代旧路径时**本任务立即删除**旧子进程与多余失败包装；
   Staged／历史／Stash／Worktree 的显示数据须对应本次锁定 OID，不得跨源混用。

**验证：**
`make test:GitExecutionTests,NativeGitHistoryFileTests,NativeDiffTabTests,GitBrowsingRecoveryTests,RemoteCommandsTests,RemoteLifetimeTests,GitStatusModelTests,GitRemoteRefreshIntegrationTests`；
真实临时 Git 仓库中的空／删／增／重命名／mode-only／冲突 index 0、2、1、
无 HEAD、无效和缺失对象、5 MiB 前后一个字节、二进制、错误输出、
短读、超时、Unicode 和特殊路径；另外测试 Blob／patch 的超预算输出、
stdout 和 stderr 同时饱和、读满一字节越限、进程异常退出与取消，
逐项记录实际传输量、峰值持有量与错误状态，均需真实建成并测试。
核对 Git OID、字节、index、可见最后一行和错误反馈；
与 P1 的冷／热进程数量、SSH 往返、1k／24k 各 30 次
Staged／Unstaged 模型准备中位／P95／最差作**同条件前后对照**，
验证真实首帧和实际可输入延迟也没有退化。
没有证实串行进程是瓶颈时，记录否定结果而不追求无效重构。

**Uncovered：**
未授权 SSH 只能用受控后端测试命令边界与取消；真实 Windows Git、
SSH 传输上限和 RTT 在 P4-T3 补验。
本机读取若足够快，交付“保留当前实现”的证据，**不创造无收益重构**。

**文档：** 真实读取语义改变时同步 `docs/features/diff.md`；
后端职责变化才同步 `docs/development.md`／`docs/architecture.md`。
**提交：** **输出预算正确性属于必要修复，不依赖性能测量结果。**
先在接收边界做单一原子提交，按真实调用者迁移并立即删除被替代路径；
只有 P1 已证明 Git 对象读取启动是热点，再以另一原子提交在同 task 消除
有明确收益的多余启动并删除旧链路。不引入未证实必要的 Batch 服务或备用接口。

<a id="p3-t2"></a>
## P3-T2 证明并收紧 Git patch 与原始工作区的快照一致性

**结果：** 不因快路径或 clean filter 接受不同时间的行操作，
Git 无文本变化时不显示整篇删增，保存始终保留原始文件字节。

**Files／实际路径：**
`DiffTab.gitComparisonBaseline/reload/readWorktreeFile/writeCurrentText`，
`GitWorktreeComparison.resolve`、
`DiffCore.fromVerifiedOperations/computeIfActive`；
`BaileyTests/Git/DiffEngineTests.swift`、
`BaileyTests/Git/NativeDiffTabTests.swift`、
`BaileyTests/Git/NativeGitHistoryFileTests.swift`。

**步骤：**
1. 在真实临时仓库建立 HEAD A→Index B→Worktree C、仅 index 变更、
   **Staged 并行 `async let` 两侧读取时交错切换 HEAD 与 Index**、
   `core.autocrlf` 和 `.gitattributes` 的 `text`／`-text`／`eol`、
   clean filter 可逆／不可逆／改写文件副作用、加载期间 index 或工作区改写；
   夹具必须证明前后 OID 和原文确实发生预定变化。
2. 追 `hash-object → git diff` 的必要顺序，以及 `reload` 中
   Staged `async let` 同时读取 HEAD tree／Index 时的跨代次风险：
   选中两个不可变 OID 只锁住各自内容，并不保证这对 OID 是一次仓库状态。
   用可控读屏障在二者的 metadata 阶段插入 Git 更新，先观察现实现是否会发布错配；
   真发生才在负责读取的 `DiffTab.reload` 做最小同源快照校验／重试，
   不造全局事务或锁。
   同时核对 `GitWorktreeComparison.resolve` 的 hunk 坐标与规范化分支，
   `fromVerifiedOperations` 每个 equal/delete/insert 范围；
   无法逐行映射时保留 Git 规范化只读比较和独立真实 Worktree 编辑。
3. 已经可复现的失效快照先 Red 后修；
   共用 `gitComparisonBaseline` 执行必要重试／错误反馈，
   不加第二套全局 retry、不过期补写、不把失败当空内容。
4. 对照已验证 Git hunk 与实时 `DiffCore`：
   除首次加载外，覆盖 Git 状态刷新期间的 Changes 选择、Graph 历史文件、
   其它 Worktree 与读中再写；以真实变更、最终 Git 行、源数据和 raw 字节为验收；
   重复行可能有多个合法 Diff 匹配锚点，不要求机械的相同算法步骤。
   若当前正确，仅扩大覆盖而不修改生产代码。

**验证：**
`make test:DiffEngineTests,NativeDiffTabTests,NativeGitHistoryFileTests,GitExecutionTests`；
真实 Git 规范化与多 hunk、末行无 LF、空文件、完全删除、
Unicode 规范等价、冲突、**Staged HEAD／Index 元数据交错变化**、并发写入、
保存失败和过期 reload；
再以 `WorkspaceGitUITests` 从完整 GUI 编辑和保存，核对磁盘原文、Git index
和 Git `diff` 命令输出。不得通过模拟的无变化文件代替真正的 clean filter。

**Uncovered：**
真实 Windows `core.autocrlf` 及授权 SSH filter 在缺少目标时列为阻塞，
本机 `git -c` 不替代实机。
**文档：** 契约变更时同步 `docs/features/diff.md` 及实际受影响的 `docs/features/git.md`。
**提交：** 发现缺陷时同一任务修复＋测试＋删除废弃分支；否则只保留真实测试证据。

<a id="p3-t3"></a>
## P3-T3 收拢后台 Diff 计算与显示发布，消除实测的重复工作

**结果：** 同一内容版本只发布对应的 Diff、折叠和着色；
连续编辑、快速切文件或关闭标签时，不仅**旧结果不发布**，
无消费者的旧 Git／SSH 读取和 Diff 计算也应真实停止，且不阻塞新请求。

**Files／实际路径：**
`Bailey/Git/DiffViewerView.swift` 的
`reload/invalidateReload/deinit/refreshWhenSelected`、
`recomputeDisplay/refreshEditDecorations/expandRun/runBackgroundDiffWork`、
`displayGeneration/editGeneration/reloadGeneration`；
检查 `GitCommandExecution.runData`、`WorkspaceBackend.run` 的实际取消与进程退出边界，
并复用 P3-T1 已有的受预算读取改动，避免再改同一个共享后端；
`Bailey/Git/DiffEngine.swift` 的
`DiffCore.computeIfActive`、`DiffComputation.build`；
`Bailey/Git/DiffNativeSurface.swift` 的 `render`；
`DiffEngineTests`、`NativeDiffTabTests`、`NativeContentIdentityIntegrationTests`。

**步骤：**
1. 由 P1 Profile 量化从 Git `verifiedCore`、`recomputeDisplay`、
   编辑 `refreshEditDecorations`、`expandRun` 到语法完成后的二次 publish，
   每次计算与用户可见布局的真实关系；无重大开销的行投影不得只为“架构整洁”重写。
2. 复用现有 `DiffCore`、当前内容版本和取消 owner；
   只为正在展示的 Unified／Split／编辑态生成真正昂贵且被消费的派生结果。
   初次展开状态必须在第一帧正确，异步着色不应重新换掉整篇可写正文。
3. **先证明当前读取取消缺口：**`DiffTab.reload()` 创建未保留句柄的 `Task`，
   其中又等待独立 `Task.detached` 执行 Git 命令；`invalidateReload()` 仅推进
   `reloadGeneration`，`deinit` 只取消展示／语法任务。
   注入可控长读：打开 A→立刻切 B／编辑 A／关闭 A／断线再连，
   记录旧命令实际何时退出、是否仍占用 SSH 连接、同时存活的任务和 RSS。
   在**现有 DiffTab 生命周期 owner**最小化持有并取消读取任务，
   将真正取消传播到 Git 子任务及其拥有的 `Process`（若后端不支持先查其最小边界），
   **必须**在取消后尽快停止不再需要的 IO，而不只是 generation 阻止 publish。
   保留现有旧结果身份校验用于防数据混写；不要重复添加第二／第三套代次。
   被取消的 Myers／Patience、词级、语法查询和布局准备也不得长期占用 CPU。
   **关注 `DiffComputation.build` 的另一种成本分布：**
   `DiffBlocks.blockEmphasis` 对每个成对修改行执行 `DiffIntraline.myersTokens`，
   400-token 内仍可能生成较大 Myers trace；反复展开会重新 build。
   由 P1-T4 的 399／400／401 token、密集对行和取消时延实测决定，
   是否应在现有 DiffCore／展示版本内复用稳定行内结果，或在实际长循环增加取消检查。
   P1 已测 399／400 token 的 1000 对替换约 37 秒（Debug），
   401 token 则约 160 ms；该热点已证实，不再将其作为可忽略的小投影。
   补齐 Release、取消时延与分配证据后在现有算法内最小修复，
   不新建词级缓存中心或额外 Diff 引擎。
4. **立即删旧路径，而非追加兼容链：**
   执行前已独立移除 `DiffDisplay.hasCollapsedContext` 的测试专用字段并将断言迁入
   `display.computation.unified.rows`；本 task 不再重复计算此项收益。
   实施可靠的读取取消后，检查不再需要的无句柄 `Task.detached` 与旧 wait path，
   与其测试一起在本 task 删除，不能保留双轨以“兼容”。
   对 `displayInputs`、`displayCoreTask`、`editFoldsReady` 等状态先核对
   展开、取消和首帧真实调用者；仍必要的绝不删。
   不增生 coordinator、generation、fallback；新链路替代旧路径时同一提交清理。

**验证：**
`make test:DiffEngineTests,NativeDiffTabTests,NativeContentIdentityIntegrationTests,GitBrowsingRecoveryTests`。
受控慢后端与真实临时 Git 仓库交错“慢 A→快 B→关闭 B→编辑 A”
及 Staged／Unstaged／历史、Split 切换、快速点击、
删除／新增大量行、取消中途 Myers/Patience、
逐词 Myers 399／400／401 token 阈值与大量成对修改、反复展开及窗口重挂载；
增加**真实在途 Git/SSH 读**的关闭／重开／改机器／断线／超时，
以可控测试命令核对取消→底层退出→无旧结果／无错误写盘，
对已有 `GitCommandExecution` 的管道与 `SSHWorkspaceBackend` 的取消支持做兼容回归。
记录实际子进程结束时间、读到的字节、活跃任务数、最终当前源、
磁盘与 Index、已显示像素和关闭后 RSS／heap。
1k／24k／100k 行重复多次，记录 30 次热样本与真实首屏／输入时间。

**Uncovered：**
真实 SSH 乱序和断线只可用授权测试目标完整验收，
受控后端只证明模型逻辑。
**文档：** 同任务更新 `docs/features/diff.md` 的版本、取消与显示契约；
职责真正移动才同步 `docs/architecture.md`。
**提交：** 共享计算／发布链最小可验证原子提交。

<a id="p3-t4"></a>
## P3-T4 使高亮只为实际可见内容付费并证明缓存释放

**结果：** Staged／历史只读侧、Worktree 的 Neon 实时侧、
clean filter 规范化对照均着色准确；
折叠展开和主题切换不重复解析未变文本，关闭标签可释放缓存。

**Files／实际路径：**
`Bailey/Git/DiffSyntaxHighlighter.swift` 的
`DiffSyntaxSource.captures`、
`DiffSyntaxHighlighter.visibleRanges/queryCaptures/attributedDocument`；
`DiffTab.captureVisibleSyntax/recomputeDisplay/expandRun`；
`Bailey/Git/DiffNativeSurface.swift` 的 `render/apply/loadSourceText`；
`Bailey/Editor/SyntaxHighlighting.swift` 与 Neon 现有边界。
测试 `NativeDiffTabTests`、`NativeSyntaxHighlightingTests`、
`HighlightQueryCacheTests`、`NativeContentIdentityIntegrationTests`。

**步骤：**
1. 分别测冷解析、同树可见区查询、折叠展开、前方输入、语言切换、
   主题／字体重绘、关闭标签与多标签累计 heap；
   在 1／10／100／1000 个离散显示区间中确认
   `DiffSyntaxHighlighter.queryCaptures` **每个区间都会重新执行 query cursor**，
   区分真正命中的 capture 数量和游标初始化／排序成本；特别拆开
   `DiffSyntaxSource.captures` 每次的 `cachedText?.utf8.elementsEqual(text.utf8)`
   全文等价扫描与真正 Tree-sitter parse/capture 查询，不能把“复用树”当作零 CPU；
   不把约 1.5 秒的对照全文件解析称为当前 GUI 首屏。
2. 保留普通编辑新侧由 Neon 管理、只读两侧由 Tree-sitter
   捕获多行上下文的既有契约。
   同内容只改变显示范围时不重新解析；语法色变化不覆盖已应用的逐词颜色或重建编辑器。
3. 在**2 MB 边界两侧**分别验证同一原文连续展开 1／10／100 个折叠块，
   统计 Tree-sitter `parseCount`、一次全解析与局部 capture 的成本、
   主线程可见文字和多标签峰值内存。
   如果超过 2 MB 的文件每次展开都会重复整篇解析并造成可观用户延迟，
   **必须在现有 `DiffSyntaxSource` 资源 owner 内修复这项已证明的重复工作**，
   同时确保关闭标签释放缓存；不是简单无上限提高缓存阈值。
   如果没有实际性能收益证据，保留现有内存优先策略，
   不新增增量解析状态机。失效任务不能把旧语法属性写入新 UTF-16 坐标。
4. 清理明确无消费方的重复旧侧／新侧查询，同时核对
   `DiffSyntaxHighlighter.captures` 和 `highlightByteLimit`：
   当前 **仅作为宿主测试的独立参考路径**使用，生产无调用者；
   如果能将同等语义、边界和反例保存在测试专用夹具内，
   同 task 迁移测试并删去产品中的测试专用全文解析入口／旧预算。
   若它仍是独立于缓存实现的必要正确性 oracle，则保留并说明为什么，
   不能为了删几行牺牲回归。验证关闭多标签后树、query、富文本引用及 CPU 均回落。

**验证：**
`make test:NativeDiffTabTests,NativeSyntaxHighlightingTests,HighlightQueryCacheTests,NativeContentIdentityIntegrationTests`；
Swift／TSX／Markdown／HTML／CSS／纯文本、明暗和高对比、
编辑／只读／规范化比较、Unicode、多行注释、折叠和逐段展开、
文件改名、连续输入、取消和恢复；
真 GUI 使用 `docs/testing.md` 的像素色彩空间规则核验实际字形和逐词颜色。
进行 30 次冷／热复用测量及至少 10 标签内存和释放审计；
2 MB 前后、5 MiB 文本上限内的折叠连续展开，
必须同时核对 `parseCount`、UI 展示延迟和关闭后 retained heap。

**Uncovered：**
极限低内存通知如无法在现有 Mac 安全触发，
记录边界与替代测试，不声明已经验证全部 OOM 状态。
**文档：** 同任务更新 `docs/features/diff.md` 的语法缓存条件；
若 Neon 共用边界改变，同步 `docs/development.md`、`docs/features/editor.md`；
删除测试专用解析入口时同任务迁移对应宿主断言，不能留编译失败或双轨实现。
**提交：** 真实被消费的语法优化与旧路径清理、测试同一原子提交。

## Phase Gate

本阶段以 Git 原始字节、真实 OID、当前显示版本、旧任务终止、
资源释放和用户可见延迟为准；
只读测试或纯理论优化不得计为实现完成。
实际审计开始时才创建 `audit-p3.md`。
