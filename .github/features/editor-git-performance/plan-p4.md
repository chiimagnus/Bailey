# P4：Git 状态先可用与共享树成本收敛

> 本页保留旧实施方案，先读 [实施基线更新](idea.md#实施基线更新)。当前 Git ViewModel 已用 Observation；下文 `@Published`、旧检查脚本和当时的缺口不得直接作为现状。沿当前共享执行器、XCTest 与真实事件入口重新取证，不重复实施后续已落地的修复。

**Goal:** 仓库状态不等待历史/行数等次要信息；相同工作树事件不无条件重做无关详情，树行状态查询不逐行扫描整份快照。

**Non-goals:** 不重写 Git runner、不增加无限并发、不解析 shell 命令猜操作、不另建文件/Git 树，不默认引入 FSEvents/监听框架。

**Approach:** 在 GitStatusModel 现有范围、请求 ID、互斥与最终事件合并上分离关键状态/次要结果。再按真实动作和可检查的数据身份缩小失效范围，预聚合共享装饰。文件树的 I/O 和遍历单独归因，只有证据成立才选最小改动。

**Acceptance:**
- 故意延迟 history/行数时，实际 Git 文件列表、分支/HEAD/upstream 与冲突信息先正确出现。
- 详情失败不把已经成功的核心状态抹成“非仓库”；依赖未就绪详情的操作不会误导或使用旧仓库数据。
- 暂存/取消暂存及已知仅工作树变化不必完整重取历史；分页只增加需要的历史工作。未知终端命令保持保守校验。
- 操作/切仓库/刷新中最后事件不丢，旧状态/详情不覆盖新操作结果。
- 大树装饰保持已有优先级/忽略语义且减少逐行全量扫描；四个树区域仍共享交互与布局。

**Rules:**
- contextGeneration、statusRequestID、refreshPending、runningOperationID 与 scopedRoot 继续拥有各自现有职责。需要跨阶段回写也复用它们，不加通用 refresh coordinator。
- 关键状态不等于仅文件列表：canonical root、HEAD/branch/upstream、冲突与仓库操作标记都是当前 UI 的真实依赖。
- 当前 `StatusResult` 没有 loadedDetails/readiness，applyRepository 会无条件覆盖全部字段。拆阶段须显式表达详情尚未成功，不把不存在的字段当复用点；只加实际分阶段结果需要的最小数据就绪信息。
- 执行统一归 `GitCommandExecution`：登录 shell 环境、独立 stdout/stderr readers、共享进程 deadline、GIT_OPTIONAL_LOCKS=0 与禁 prompt 保留；模型内旧 runGit 已不存在。
- SSH 当前把含 log 的整套 snapshot 一次批取，仍需等待完整 backend.run 返回；不能只在 Swift 层分两次 publish 而不拆远程关键批次。
- 当前 caller 为 `WorkspaceDockView.DockTabGroupView.content → ToolPanelView`。Files/Git 各唯一且可同时可见；Git 同步由 `ContentView.syncGit` 拥有，ToolPanelView 的 syncQueue 仅刷新 Files。Info 与 manager.panelTab 已移除，不新增工具面板同步协调者。
- 写操作仅合成仓库；真实远端不 push，不修改用户 repo 或 global config。真实 SSH 需现有授权测试目录。

<a id="p4-t1"></a>
## P4-T1 关键状态与次要结果分阶段交付

**类型 / 依赖:** 实现；依赖 P1，默认 P3 后。

**Files / 锚点:**
- Modify: kero/Git/GitStatusModel.swift：refresh/runGitStatus/prefetchedSnapshotCommands、StatusResult/StatusLoadResult、apply/applyRepository、invalidateStatusRefresh、perform。
- Modify: `kero/Git/GitPanel.swift`、`kero/Git/RecentCommitsView.swift`、`kero/UI/Components/BottomToolbarView.swift`：真实详情 consumer 与加载/失败表示；调用入口是 `ContentView.syncGit` / `ToolPanelView`，按需要最小接入。
- Modify only as needed: kero/Remote/RemoteCommands.swift 的现有 batchCommand/parseBatch 使用；新文案按 docs/ui.md#本地化 更新 kero/Resources/Localization/Git.xcstrings、Sidebar.xcstrings 或 Workspace.xcstrings 对应归属。
- Only where deadline propagation requires it: `RemoteConnection.run/check` 的已有 master preflight。check 当前另有固定 5 秒预算，不能把传给 backend.run 的剩余时间当作整个调用已严格包含 preflight；沿当前 runner 传递同一剩余预算，不新增连接/重试层。
- Extend: `KeroTests/check-git-panel-state.swift` 现有真实模型/backend 检查，增加受控延迟结果，不另建同职责脚本。
- Modify: docs/testing.md#性能与内存测量、docs/features/git.md；本地 evidence-p4.md。

**现状与失效边界:** runGitStatus 完成 numstat、未跟踪行数、refs/remote/log/stash/git-dir 后才 publish。applyRepository 当前全量覆盖，不能以空数组补齐核心结果。worker 的 10/24 秒 deadline 目前只传给 statusGit；未跟踪计数和仓库标记另走无剩余时间的调用，外层 12/30 秒 watchdog 只能拒绝晚结果，并未停止实际工作。另有同 root/scope 更换连接后旧结果仍可能通过原 generation 的路径；拆阶段必须在同 task 验证并处理。

**实施:**
1. 保留仓库解析与精确 non-repo/失败判断。建立一个现有 worker 内的顺序交付：先核心状态，再行数/展示详情；不同时启动多套全量 snapshot。
2. 核心包括 root、porcelain entries/ignored、branch/HEAD/upstream/ahead/behind、conflict 与 repositoryOperation。git-dir/operation 仍校验真实仓库，不能因为它原在详情末尾而省掉。
3. 核心与详情使用明确结果，不把默认空值伪装成完成。最小就绪信息与详情错误归 GitStatusModel；核心 apply 不清 refs/history/totals，切机器/仓库才重置；初次未加载不被显示为“0 行/没有远端/没有 stash”。缓存须区分完整结果与仅核心，不能缓存空详情为成功全量快照。
4. 同 repo 有效详情可保留展示，失效详情不能驱动动作。GitPanel fetch/publish/stash-pop、BottomToolbar 分支列表按真实数据依赖接入；amend 的“有提交”直接用核心 hasHead，不继续依赖 recentCommits，也不因 history loading 禁用正常 commit/stage。行数正在更新/失败不显示确定的 +0/−0；真实空历史、unborn 和详情失败各自表达。菜单和模型动作一起核对，不能只禁一个按钮。
5. 每次阶段回写都检查原 root/scope/contextGeneration/requestID；perform 开始仍 invalidate 全部前操作结果。清理、timeout、isRefreshing/isLoadingMoreCommits、缓存和 refreshPending 定义一致：保留运行中事件，结束后仅合并一轮最后刷新。
6. 核心成功后详情失败只保留成功核心，显示适当失败/可再刷新；初次核心失败仍显示原错误，不误导成空仓库。不丢操作失败条和用户草稿。
7. SSH 拆核心/详情批次，沿用 quoting/NUL/envelope，核心 batch 不含 log。batch 传输失败或缺必需帧直接返回该阶段失败，不再落回旧的逐命令重取，删除 prefetched 字典 miss 的隐式备用路径；正常 non-repo/unborn/无 stash 是业务结果，不是传输 fallback。共享 worker 剩余 deadline 覆盖计数和 operation 查询，watchdog 在已有核心成功后不能清掉核心。记录往返数，不把每条命令拆一轮 SSH，也不造多层 retry。
8. 不依赖后续失效优化：本 task 完成时，完整详情依然能自动加载、分页和出错恢复。
9. 未跟踪计数按现有文件数/字节预算真正有界：local textLineCount 当前仅读前检查 size，后面循环读到 EOF；remote wc/tail 也在 stat 后再次无界读取。复用本地有界读、远程有限内容读及现有统计协议，读中增长不能绕过 per-file/总预算；至少加入增长/超限的回归。相应计数 helper 替换与旧无界循环删除同 task 完成，不把吞掉错误算“0 行成功”。

**针对性验证:**
- Run: `bash scripts/check.sh git-panel-state git-execution remote-commands panel-targets`。现有编译入口已经含 WorkspaceBackend、LocalWorkspaceBackend、RemoteCommands、Shared/Tree/TreeDisplayModel、GitCommandExecution 与真实模型，无 app-only 壳。本地真实 Git fixture 为主，延迟/乱序复用已有 WorkspaceBackend 或 RemoteCommandRunner seam，不新增生产 protocol。
- 延迟详情断言核心可消费、详情失败/超时不清核心、初次 readiness/缓存重访不串；切 root/scope、同 root/scope 更换连接、操作开始、末尾事件和分页中事件最终对应当前仓库。验证受控坏 batch 不额外发逐条命令；预算/timeout 看实际读量与剩余时间，不只检查 watchdog 消失。
- 真实 app：小仓库/上千文件、unborn、冲突、stage/unstage、commit/amend、分支切换、stash/pop 与 loaded-more history；核对磁盘、index、log，不只检查 UI success。
- 详情未到时尝试每个受影响按钮；真实合成 SSH repo 检查核心先出现、错误与断线，不向网络远端发布。
- 同机比较状态可用/全部详情、process/读取/往返与主线程；证明延后的是非关键工作而非功能缺失。

**提交边界:** 分阶段交付、UI 接入、检查、必要本地化/文档一次原子提交；不捎带 P4-T2 的缓存政策。

<a id="p4-t2"></a>
## P4-T2 缩小详情失效与历史分页工作

**类型 / 依赖:** 实现；依赖 P4-T1。

**Files / 锚点:** GitStatusModel.sync/refresh/loadMoreCommits/perform、stage/unstage/discard/trash/commit/fetch/switchBranch/createBranch/stash、cachedStatusByRoot/recentCommitLimitByRoot；ContentView 的 commandCompletionSequences/激活入口与 syncGit；ToolPanelView 的文件创建/rename/delete 后 refreshGitStatus；扩展 KeroTests/check-git-panel-state.swift。

**设计决定:** 缓存有效性来自真实数据或已知动作，不由延时 TTL 决定。HEAD 没变不证明 refs/remote/stash 没变；任意终端命令不安全可分类。先最小两类失效及现有状态表达，再测需要的数据身份校验是否比重取更划算。

| 当前事件 | 必须更新 | 可复用的前提 |
| --- | --- | --- |
| stage/unstage、tracked restore、untracked trash | core + totals | 新 core HEAD/branch 一致且详情本来有效；不重取未改变 history |
| commit/amend、branch/create/switch、init | core + totals + 相关详情/history | 不依赖旧 HEAD |
| stash/pop、fetch/remote 操作 | core + totals + stash/refs/upstream 等相关详情 | 只复用有证据未变的部分 |
| history 加载更多 | 更大 limit 的 history | scope/root/HEAD/refs 未失效，不重新计算全部 numstat/untracked |
| 新 scope/root、激活、未知终端 command completion | core + 必要保守校验/详情 | 不仅靠相同 HEAD 跳过 remote/stash/refs |

**实施与验证:**
1. 用当前 known caller 表达最小 core-only/full 失效需求；终端未知命令、手动刷新、激活仍 full，这是当前可达行为而非旧版本兼容层。不写 shell 命令解析器，不增加 TTL/多级原因框架；partial 失败不能把旧 details 标成有效。
2. coalescing 合并失效需求而非用最后一条覆盖前面：详情刷新需求和更大 history limit 到达时不丢；isBusy 期间也保留。
3. 默认不新增 refs/config fingerprint 探测。已知仅工作树/index 动作才复用有效详情，未知外部命令仍完整刷新；先测这个最小方案。只有后续证据证明 full 刷新仍主导且探测净收益成立，才回改本 task，不预建配置扫描与 hash 围栏。
4. 分页走当前范围的 history 更新，保留 page size=30、hasMore、isLoadingMore 和已展开行；HEAD/refs 改变时重新取得一致列表，不把新旧 log 直接拼错。
5. 相同字段/数组/装饰不重复 @Published 赋值；dirty/error/operation 的必要状态转换仍发布。先比较实际应用数据，不能用一条全模型相等守卫屏蔽需要变化的 readiness。
6. 脚本记录实际 command 集合：stage 后不执行不必要完整 log，pagination 不重做文件行数；branch/remote/stash 的外部变化、相同 HEAD 的 ref 变化、快速 root 切换和最终事件均得到最新正确结果。
7. 真机操作并对照 Git index/log/refs/stash，观察分页与菜单；比较 process 数、SSH 往返、状态尾延迟。失败过的操作仍有原反馈，不回退到旧 operation 成功。

**提交边界:** 失效/分页/相同发布收敛与对应检查一个提交，不引入新的 Git runner。

<a id="p4-t3"></a>
## P4-T3 在快照层预聚合文件树状态装饰

**类型 / 依赖:** 实现；依赖 P4-T1 的核心快照语义。

**Files / 锚点:**
- Modify: GitStatusModel.applyRepository/clearRepositoryState/fileDecoration。
- Reuse: TreeDisplayModel.Status.directoryPriority、pathRows 已有的目录聚合语义。
- Modify: KeroTests/check-git-panel-state.swift 的装饰检查；仅需要共享算法归属时才改 `kero/Shared/Tree/TreeDisplayModel.swift` 和现有树检查。
- Consumers to verify: FileTreeRow、GitEntryRow、RecentCommitsView；不独立修改 row 布局。

**现状与根因:** fileDecoration 先 direct path，再扫描全部 ignoredPaths，目录再 filter 全部 fileDecorations。每行重绘可重复扫描同快照；Git pathRows 已在构造时聚合父目录状态，不能在 Files 另发明优先级。

**实施与验证:**
1. 核心 entries/ignored 实际变化时，沿路径祖先构建目录状态索引，复用 directoryPriority；逐行查询用字典和祖先路径 membership，不扫描全变更集或忽略集。
2. 保持“直接状态优先、再忽略祖先、再后代目录最高优先级”，忽略 trailing slash 与文件名区分，repo root/仓库外路径与无 repo 行为不变。foo 与 foobar 不串前缀。
3. 清理与切 scope 清掉/重建索引；不得拿 A 机器同路径给 B 装饰。相同核心结果不要重新建索引/发布。
4. 脚本用真实模型比较慢扫描 oracle：MM、A+M、D、rename/copy、conflict、ignored 目录子孙、仓库根/外、空集与路径边界；10k 文件 × 多层目录。
5. 若修改共享树 helper，立即运行开发文档的 file-tree-navigation 和 tree-row-hit-testing 两项命令，再真机一起检查 Files/changed/staged/history、窄栏/字体/横滚/悬停/命中/无障碍。
6. 比较快照构造成本与大树滚动/更新的查找成本；不把工作从 row 移进更慢的主线程全量重建后就宣布优化。
7. parseStatus 已在真实 producer 去重；本 task 将 applyRepository 与 GitPanel.changedFileRows 中重复的 `uniquingKeysWith: first` 备用处理改为依赖该唯一性不变量的直接构造，并加 `git rm --cached`（staged deletion + untracked 同路径）真实回归。不要删除 parseStatus 的必需去重，也不要类推删除 history/通用 pathRows 的去重：后者已有显式重复输入契约。

**提交边界:** 索引与检查/事实文档一个提交，不复制树或改懒加载。

<a id="p4-t4"></a>
## P4-T4 文件树刷新与远程往返的证据门

**类型 / 依赖:** 定向实验后条件最小实现；依赖 P1、P4-T3，用来排除装饰影响。

**Files / 锚点:** ToolPanelView.pollsSelectedPanel/syncQueue/performSync、FileTreeModel.sync/rebuild/children、LocalWorkspaceBackend.list、SSHWorkspaceBackend.list、RemoteCommands.listDirectoryCommand/batchCommand、TreeDisplayModel.Traversal.nextDirectory/receive；KeroTests/check-file-tree-navigation.swift。

**当前事实:** Traversal 为压缩目录读取未展开目录的直接子项，不仅 expanded；live tree 有 32 层约束防 symlink 循环，Git 有限路径没有同一限制。ToolPanelView 两秒 poll 只在前台可见 Files，performSync 按自身 panel，Git 分支不执行同步；heading 只读发布状态。Info 已移除，工具面板不重复创建；既有 PanelSyncQueue 与 FileTreeModel.rebuild 都串行合并，各管不同生命周期，不据此认定两者冗余。

**实验与分支:**
1. 同一固定大树测初次展开、重复无变化 poll、外部创建/删除、压缩长目录链与 SSH，分别计目录 list/stat、main thread、排序/Traversal、实际读量和往返。
2. LocalWorkspaceBackend.list 已是 @concurrent；不重复增加后台边界。若 trace 仍有 main thread 成本，区分 PanelContext 根解析、返回后的 map/sort/Traversal 与 AppKit 构建，修实际拥有者，不再用“list 是 async”或增加 Task 猜测。
3. 若主要是远程已知目录的多轮 list，原型仅对“本次 traversal 必定需要”的有限目录批取，复用现有 batch 协议；单次 rebuild 预取结果不能变成长期 stale cache。未知下一层保持需求驱动，预算/批次大小由实际输出上限决定，不预扫未访问子树。
4. 若主要是重复数据处理，优先重用单次/当前范围已知数据并避免重复排序/发布。目录 mtime 不能单独证明 symlink 目标类型没变；不直接以它缓存整个目录，也不减少外部变化检测能力。
5. 一轮定位加一个选中分支原型后停止。若最小措施不够，明确需要的新 invalidation 来源与净收益，先回改本 task/需求再实现；不得默默加入 watcher 框架。没有成本证据就保留已有 serial coalescing/poll。

**针对性验证:** task 内扩展现有真实文件系统脚本，覆盖 external add/delete/rename、draft/取消、压缩链、symlink/dangling/循环、unreadable 保留、root/scope 变化和重建中最终事件。若批协议变化，检查空/换行/引号路径、批次失败与真实 SSH 输出。运行两项共享树检查并安装真机验收四区域、大树响应；关闭/隐藏/后台后无额外网络/I/O。

**提交边界:** 被测量选中的最小刷新改动、检查与性能说明独立提交；探索无改动只保留本地证据，不能把探索结束冒称已修复卡顿。

## 阶段自审与交接

- 基线和各 task 都核对核心结果/操作副作用；相同 scope、partial readiness 与最后事件是共享不变量。
- P4-T1 完成时功能已完整，不依赖 T2 才补详情/失败/分页；T3/T4 不改变共享树语义。
- 实际完成后进入 plan-task-auditor 并创建 audit-p4.md；规划时不创建。
