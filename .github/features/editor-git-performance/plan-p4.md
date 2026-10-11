# P4：Git 状态先可用与共享树成本收敛

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
- loadedDetails 已在 StatusResult/applyRepository 中存在，优先复用。只增加表达实际未就绪数据的最小标记，不展开完整状态枚举。
- runGit 的 stdout/stderr 独立 reader threads、共享 deadline、GIT_OPTIONAL_LOCKS=0、禁交互 prompt 保留。
- SSH 当前把含 log 的整套 snapshot 一次批取，仍需等待完整 backend.run 返回；不能只在 Swift 层分两次 publish 而不拆远程关键批次。
- 并行停靠修改已让工具面板可能同时显示在多个区域；当前 caller 是 WorkspaceDockView 的 DockTabGroupView.content → RightSidebarView(panel:)。签名随并行工作已变化；源码稳定后核对可见性、实际 panel 与 syncQueue，不把并行布局 bug 顺手纳入本 feature，也不能仍假设只有一个 manager.panelTab 可见。
- 写操作仅合成仓库；真实远端不 push，不修改用户 repo 或 global config。真实 SSH 需现有授权测试目录。

<a id="p4-t1"></a>
## P4-T1 关键状态与次要结果分阶段交付

**类型 / 依赖:** 实现；依赖 P1，默认 P3 后。

**Files / 锚点:**
- Modify: kero/Git/GitStatusModel.swift：refresh/runGitStatus/prefetchedSnapshotCommands、StatusResult/StatusLoadResult、apply/applyRepository、invalidateStatusRefresh、perform。
- Modify: kero/UI/Sidebar/RightSidebarView.swift 的 GitPanel、kero/UI/ContentView.swift 的 BottomToolbarView/分支入口：实际详情依赖与加载表示。
- Modify only as needed: kero/Remote/RemoteCommands.swift 的现有 batchCommand/parseBatch 使用；新文案按 docs/LOCALIZATION.md 更新 kero/Resources/Localization/Git.xcstrings、Sidebar.xcstrings 或 Workspace.xcstrings 对应归属。
- New: scripts/check-git-refresh.swift，编译真实模型、backend、TreeDisplayModel 和 RemoteCommands，不复制 parseStatus/refresh 算法。
- Modify: docs/PERFORMANCE.md、docs/GIT.md；本地 evidence-p4.md。

**现状与失效边界:** runGitStatus 完成 numstat、未跟踪文件行数、refs/remote/log/stash/git-dir 后才 publish。StatusResult 已有 loadedDetails，但当前一次全部取齐。刷新结果可能在用户操作、root/scope 切换后返回；现有 generation/requestID 会拒绝，拆阶段不能绕开这些保护。

**实施:**
1. 保留仓库解析与精确 non-repo/失败判断。建立一个现有 worker 内的顺序交付：先核心状态，再行数/展示详情；不同时启动多套全量 snapshot。
2. 核心包括 root、porcelain entries/ignored、branch/HEAD/upstream/ahead/behind、conflict 与 repositoryOperation。git-dir/operation 仍校验真实仓库，不能因为它原在详情末尾而省掉。
3. numstat/未跟踪计数、history、branches/remotes/default branch、stash 明确哪些 consumer 等待。复用 loadedDetails；最小数据就绪标记保证初次未加载不被当作“0 行/没有远端/没有 stash”。
4. 现有详情仍可在同 repo 刷新中保留展示，但只有身份匹配、有效的详情可驱动动作。GitPanel fetch/publish/stash/amend、BottomToolbar 分支菜单一起接入：依赖未就绪时禁相应动作并说明更新中；stage/unstage 和准确核心状态不被无关 history 阻塞。
5. 每次阶段回写都检查原 root/scope/contextGeneration/requestID；perform 开始仍 invalidate 全部前操作结果。清理、timeout、isRefreshing/isLoadingMoreCommits、缓存和 refreshPending 定义一致：保留运行中事件，结束后仅合并一轮最后刷新。
6. 核心成功后详情失败只保留成功核心，显示适当失败/可再刷新；初次核心失败仍显示原错误，不误导成空仓库。不丢操作失败条和用户草稿。
7. SSH 拆为核心批次与所需详情批次，复用 RemoteCommands 的 quoting/NUL/envelope；不要让核心 batch 包含慢 log。复用每次 worker 的实际 deadline，次要计数也不能突破它。比对真实往返数，避免为“先显示”将每个 command 变一轮 SSH。
8. 不依赖后续失效优化：本 task 完成时，完整详情依然能自动加载、分页和出错恢复。

**针对性验证:**
- 最小检查编译入口：
  xcrun swiftc -swift-version 5 -o build/check-git-refresh kero/Workspace/WorkspaceBackend.swift kero/Workspace/TreeDisplayModel.swift kero/Remote/RemoteCommands.swift kero/Git/GitStatusModel.swift scripts/check-git-refresh.swift && build/check-git-refresh。
  app-only 类型壳仿现有脚本；本地真实 Git fixture 为主，乱序/故意延迟复用现有 WorkspaceBackend 或 RemoteCommandRunner 测试边界，不新增生产 protocol。
- 在脚本延迟详情，断言核心已可消费；核心错误 vs 详情错误分开；切 root/scope、操作开始、末尾事件和分页中事件的结果最终对应当前仓库。
- 真实 app：小仓库/上千文件、unborn、冲突、stage/unstage、commit/amend、分支切换、stash/pop 与 loaded-more history；核对磁盘、index、log，不只检查 UI success。
- 详情未到时尝试每个受影响按钮；真实合成 SSH repo 检查核心先出现、错误与断线，不向网络远端发布。
- 同机比较状态可用/全部详情、process/读取/往返与主线程；证明延后的是非关键工作而非功能缺失。

**提交边界:** 分阶段交付、UI 接入、检查、必要本地化/文档一次原子提交；不捎带 P4-T2 的缓存政策。

<a id="p4-t2"></a>
## P4-T2 缩小详情失效与历史分页工作

**类型 / 依赖:** 实现；依赖 P4-T1。

**Files / 锚点:** GitStatusModel.sync/refresh/loadMoreCommits/perform、stage/unstage/discard/trash/commit/fetch/switchBranch/createBranch/stash、cachedStatusByRoot/recentCommitLimitByRoot；ContentView 的 commandCompletionSequences/激活入口与 syncGit；扩展 scripts/check-git-refresh.swift。

**设计决定:** 缓存有效性来自真实数据或已知动作，不由延时 TTL 决定。HEAD 没变不证明 refs/remote/stash 没变；任意终端命令不安全可分类。先最小两类失效及现有状态表达，再测需要的数据身份校验是否比重取更划算。

| 当前事件 | 必须更新 | 可复用的前提 |
| --- | --- | --- |
| stage/unstage、tracked restore、untracked trash | core + totals | 新 core HEAD/branch 一致且详情本来有效；不重取未改变 history |
| commit/amend、branch/create/switch、init | core + totals + 相关详情/history | 不依赖旧 HEAD |
| stash/pop、fetch/remote 操作 | core + totals + stash/refs/upstream 等相关详情 | 只复用有证据未变的部分 |
| history 加载更多 | 更大 limit 的 history | scope/root/HEAD/refs 未失效，不重新计算全部 numstat/untracked |
| 新 scope/root、激活、未知终端 command completion | core + 必要保守校验/详情 | 不仅靠相同 HEAD 跳过 remote/stash/refs |

**实施与验证:**
1. 用当前 known caller 传最小失效信息；unknown 保守默认保持兼容。不写 shell 命令解析器。
2. coalescing 合并失效需求而非用最后一条覆盖前面：详情刷新需求和更大 history limit 到达时不丢；isBusy 期间也保留。
3. 如果选择廉价 refs/config 身份探测，先用现有 Git 输出/批次验证 command 数与耗时净收益。必须包含 branch/remote refs、stash 与配置变化，不用 status 内容 hash 证明详情没变；敏感配置值不进日志。
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
- Modify: scripts/check-git-refresh.swift 的装饰检查；仅需要共享算法归属时才改 kero/Workspace/TreeDisplayModel.swift 和现有树检查。
- Consumers to verify: FileTreeRow、GitEntryRow、RecentCommitsView；不独立修改 row 布局。

**现状与根因:** fileDecoration 先 direct path，再扫描全部 ignoredPaths，目录再 filter 全部 fileDecorations。每行重绘可重复扫描同快照；Git pathRows 已在构造时聚合父目录状态，不能在 Files 另发明优先级。

**实施与验证:**
1. 核心 entries/ignored 实际变化时，沿路径祖先构建目录状态索引，复用 directoryPriority；逐行查询用字典和祖先路径 membership，不扫描全变更集或忽略集。
2. 保持“直接状态优先、再忽略祖先、再后代目录最高优先级”，忽略 trailing slash 与文件名区分，repo root/仓库外路径与无 repo 行为不变。foo 与 foobar 不串前缀。
3. 清理与切 scope 清掉/重建索引；不得拿 A 机器同路径给 B 装饰。相同核心结果不要重新建索引/发布。
4. 脚本用真实模型比较慢扫描 oracle：MM、A+M、D、rename/copy、conflict、ignored 目录子孙、仓库根/外、空集与路径边界；10k 文件 × 多层目录。
5. 若修改共享树 helper，立即运行开发文档的 file-tree-navigation 和 tree-row-hit-testing 两项命令，再真机一起检查 Files/changed/staged/history、窄栏/字体/横滚/悬停/命中/无障碍。
6. 比较快照构造成本与大树滚动/更新的查找成本；不把工作从 row 移进更慢的主线程全量重建后就宣布优化。

**提交边界:** 索引与检查/事实文档一个提交，不复制树或改懒加载。

<a id="p4-t4"></a>
## P4-T4 文件树刷新与远程往返的证据门

**类型 / 依赖:** 定向实验后条件最小实现；依赖 P1、P4-T3，用来排除装饰影响。

**Files / 锚点:** RightSidebarView.pollsSelectedPanel/syncQueue/performSync、FileTreeModel.sync/rebuild/children、WorkspaceBackend.list、SSHWorkspaceBackend.list、RemoteCommands.listDirectoryCommand/batchCommand、TreeDisplayModel.Traversal.nextDirectory/receive；scripts/check-file-tree-navigation.swift。

**必须纠正的简化:** 当前 Traversal 为判断压缩目录也会读取未展开目录的直接子项，不仅访问 expanded 集合。范围仍有限，不是递归读取整棵树。原布局两秒 poll 只在前台可见 Files/Info，remote heading 是廉价状态读取，不能误当网络 poll。当前 pollsSelectedPanel 已改读 panel，而 performSync 仍读 manager.panelTab，入口正在并行修改；P1 固定实际布局后核对多个可见 Files/Info 的请求汇聚和有效性，不依赖未完成修改的假设。

**实验与分支:**
1. 同一固定大树测初次展开、重复无变化 poll、外部创建/删除、压缩长目录链与 SSH，分别计目录 list/stat、main thread、排序/Traversal、实际读量和往返。
2. 若 local list 在当前编译语义下占主线程，首先在 LocalWorkspaceBackend.list 的公共入口明确后台边界，复用 P2 的 executor 验证，不让 UI 各包自己的 Task。
3. 若主要是远程已知目录的多轮 list，原型仅对“本次 traversal 必定需要”的有限目录批取，复用现有 batch 协议；单次 rebuild 预取结果不能变成长期 stale cache。未知下一层保持需求驱动，预算/批次大小由实际输出上限决定，不预扫未访问子树。
4. 若主要是重复数据处理，优先重用单次/当前范围已知数据并避免重复排序/发布。目录 mtime 不能单独证明 symlink 目标类型没变；不直接以它缓存整个目录，也不减少外部变化检测能力。
5. 一轮定位加一个选中分支原型后停止。若最小措施不够，明确需要的新 invalidation 来源与净收益，先回改本 task/需求再实现；不得默默加入 watcher 框架。没有成本证据就保留已有 serial coalescing/poll。

**针对性验证:** task 内扩展现有真实文件系统脚本，覆盖 external add/delete/rename、draft/取消、压缩链、symlink/dangling/循环、unreadable 保留、root/scope 变化和重建中最终事件。若批协议变化，检查空/换行/引号路径、批次失败与真实 SSH 输出。运行两项共享树检查并安装真机验收四区域、大树响应；关闭/隐藏/后台后无额外网络/I/O。

**提交边界:** 被测量选中的最小刷新改动、检查与性能说明独立提交；探索无改动只保留本地证据，不能把探索结束冒称已修复卡顿。

## 阶段自审与交接

- 基线和各 task 都核对核心结果/操作副作用；相同 scope、partial readiness 与最后事件是共享不变量。
- P4-T1 完成时功能已完整，不依赖 T2 才补详情/失败/分页；T3/T4 不改变共享树语义。
- 实际完成后进入 plan-task-auditor 并创建 audit-p4.md；规划时不创建。
