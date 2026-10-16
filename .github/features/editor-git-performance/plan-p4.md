# P4：Git 核心先可用与共享树成本收敛

**目标：** 核心状态不等历史／行数；减少有证据的无关详情工作和逐行全快照扫描。
**不做：** 新 Git runner、refresh coordinator、命令字符串分类器、TTL／fingerprint、无限并发或新文件树。
**前置／验收：** P1；核心成功不被详情失败抹掉，旧结果不覆盖操作，周期／事件最后更新不丢，树语义不变。

当前是 Observation。sync 已处理同 root/scope 换 backend 的 contextGeneration／worker 失效，失败保留快照也已有回归：保留它们，不重复列为新修复。ContentView.syncGit 拥有目标同步；ToolPanelView 的前台可见 Git 每本机 2 秒／SSH 5 秒刷新，Files 队列仍只做 Files。不能按旧计划假定没有 Git 轮询。

<a id="p4-t1"></a>
## P4-T1 分阶段交付核心与详情

**类型：** 实现；P1 后，默认 P3 后。
**文件：**
- `kero/Git/GitStatusModel.swift` 的 refresh/runGitStatus/prefetchedSnapshotCommands、结果／缓存、apply、perform、计数和 operation 查询。
- GitPanel、RecentCommitsView、BottomToolbarView 的实际字段消费者和动作；RemoteCommands 的批协议／计数只按需要改。
- RemoteConnection.run/check 只在传播当前调用剩余预算确有需要时调整，不重构连接生命期。
- 扩展 GitStatusModelTests、GitExecutionTests、RemoteCommandsTests、GitExternalRefreshTests；动作行为变化运行对应 Git 动作／原生菜单测试。
- 文档 owner：`docs/features/git.md`；测量方法真的变化才改 testing.md；新文案按实际 Git／Sidebar／Interface／Workspace 归属本地化。

**根因：** runGitStatus 顺序做 numstat／未跟踪计数、refs／remote／log／stash／git-dir／operation 后才发布；SSH 预取批次也含 log，只拆 Swift apply 不能提早交付。StatusResult 是全量结果，不能用默认空数组充当“详情完成”。

1. Red：受控延迟 history／计数，真实核心文件列表、分支／HEAD／upstream／冲突应先可消费；详情失败／超时仍保留成功核心，不显示伪空历史／远端或 +0。既有失败保留测试按“分阶段但不发布缺字段成功详情”的新契约调整，不简单删除。
2. 同一 refresh worker 顺序交付核心后详情，不并发启动两套全快照。核心包括 canonical root、porcelain entries/ignored、branch／HEAD／upstream／ahead/behind、conflict、git-dir 与 repositoryOperation；后两者决定真实操作资格，不推迟到任意详情。
3. 用最少的核心／完整详情结果、就绪身份和错误表达阶段。相同仓库可保留上次详情供展示，未验证的新详情不能驱动动作；换机器／仓库重置。缓存必须区分核心与完整详情，不把空默认值缓存为成功。详情按自身结果完整发布，不因某个子查询失败清掉其他已有有效字段。
4. 明确消费者：amend／“有提交”由核心 hasHead 判定；stage／正常 commit 不等 history。Ref／branch／remote／stash 菜单、publish/fetch／graph 操作和底栏 picker 依赖详情的新鲜身份；UI 与模型动作两端一致，不能只禁按钮。行数待定／失败不伪报确定的零，真实空与失败分开。保留草稿和原操作失败反馈，不夹带 UI 重设计。
   实施回归否定了把详情资格塞进通用 isCurrent 的做法：它会打断新建 Tag 后实时解析 OID→立即推送。isCurrent 继续只管目标身份，快照消费者在既有 perform 汇聚点检查资格；已明确用实时 OID 的该条链路保留实际对象校验，不靠增加等待恢复。分页是读取而非旧详情写操作，保留进行中合并，不能套同一个禁用条件。
   全量原生回归进一步否定“任何刷新开始就撤销资格”：它会阻断已验证目标的失败重试／恢复文件。资格在目标、HEAD／分支／进行中操作变化或查询失败时撤销；普通后台读取保留已验证快照和既有执行前活体校验。这不是无条件信任旧详情，也不再给各个恢复路径追加绕过。
5. 每次交付复用 contextGeneration、requestID、root/scope；perform 开始仍 invalidate 查询。保留同仓库换连接的已有失效机制与测试，不增加第二套 generation。核心／详情收尾、缓存、分页、isRefreshing 与 refreshPending 同义，进行中事件结束后合并一轮，不丢最后事件。
6. SSH 拆核心／详情有限批次，复用 quoting／NUL／tag。batch 调用失败或缺必需帧就是该阶段失败，不再落回 prefetched miss 的逐命令完整重取；删除这条隐式双轨。正常 non-repo、unborn、无 stash 是业务结果，不是失败 fallback。
7. 现有 worker 10／24 秒预算仅覆盖 statusGit，计数／operation 等另走默认超时。传递同一剩余预算到实际耗时调用；交互 RemoteConnection.check 目前另有 5 秒，需要计入实际调用时间，不声称参数已经包含它。不新增连接重试层，不承诺无法中断的文件系统调用一定停下；保留 12／30 秒独立 UI watchdog，核心成功后不能被 watchdog 清空。
8. 未跟踪统计的文件数／字节预算是真实容量边界。本地 textLineCount 仅读前 size 后循环到 EOF，远端 stat 后 wc/tail 也可无界读；改为受限读取／统计并计实际读取字节，保留 8000 字节二进制探测、symlink 和尾行语义。不要简单换全量分配，或让单文件 probe 超过剩余预算；上限／增长／读取失败在本 task 留回归。超预算跳过与读取失败不混为“精确 0 行”。远端继续一次有限批量，不退回每文件往返。当前输出还把路径按换行分帧，合法文件名中的换行可伪造额外统计记录；消费者只求和、不使用 path，应先删输出中无消费者的路径，保持最小数值帧并验证非负／预算，或用已有 NUL 能力正确分帧，不能兼容解析新旧两套输出。
9. 不依赖 T2 补完功能：本 task 已能自动加载全部详情、分页、手动重试和失败恢复。同 task 删除被替代的全量单次 apply／全批预取、隐式 fallback 和无界计数循环；保留执行器、互斥及目标保护。

**验证：**
- 从 `make test ONLY_TESTING=KeroTests/GitStatusModelTests`、RemoteCommandsTests、GitExecutionTests、GitExternalRefreshTests 开始，再完整 `make test`／`make build`。新测试进现有 XCTest，不建脚本。
- 延迟／乱序／缺 batch 帧／详情失败、目标／同仓库连接切换、操作中查询、刷新／分页中的末尾事件；检查最终当前仓库状态及不额外逐命令重取。
- 真实临时 Git 的 unborn、冲突、stage／unstage、commit／amend、Ref／stash／分页，核对 index／HEAD／log。容量检查验证读量而不只看 spinner 消失。
- 隔离 App 核心出现时尝试各受影响动作；授权 SSH fixture 检查核心先可见、断线反馈和往返。没有真实 SSH 就保留该验收缺口，不用受控后端冒充。
- 与 P1 比核心／详情、主线程、进程／读取量／往返，不以缺功能换首屏。

**提交：** 分阶段交付、实际 consumer、计数／预算闭环、旧路径删除、回归和文档同一结果；不夹带下一 task 的缓存失效策略。

<a id="p4-t2"></a>
## P4-T2 按已知动作缩小刷新，分页只读历史

**类型／依赖：** 条件性能实现；依赖 T1 和实际命令／等待热点。
**锚点：** GitStatusModel.sync/refresh/loadMoreCommits/perform、已知 mutation、cachedStatusByRoot/recentCommitLimitByRoot；ContentView 命令／激活，ToolPanelView 周期／文件操作刷新；GitStatusModelTests、GitExternalRefreshTests。文档归 git.md。

| 真实触发 | 最小更新 |
| --- | --- |
| stage／unstage、明确仅工作区／index 动作 | core + totals，已有详情身份有效且新核心 HEAD／branch 一致才复用 |
| commit／branch／remote／stash 等动作 | full，先不发明更细原因分类 |
| 分页 | 当前范围更大 limit 的 history，不重算文件行数 |
| 周期、激活、手动刷新、未知终端完成、换 scope/root | full，不能只凭 HEAD 不变跳过 refs／remote／stash |

1. 先记实际 command 集合，Red 明确 stage 不必重取全 log、分页不重做 numstat／untracked；没有显著成本就只记录，不引入失效框架。
2. 采用时用最小 core/totals 与 full 请求需求；合并要升级需求并保留较大 history limit，isBusy 中也不能让 full 被后来的轻请求覆盖。
3. 不解析任意终端命令、不加 TTL、refs/config hash 或探测命令。外部变化可与已知动作交错，保守 full 周期与显式刷新仍必须存在；不能把局部动作等同于锁住外部 Git。
4. 分页保留 size=30、hasMore、loading、已展开节点和 scope／HEAD／refs 一致性；失效时重读一致列表，不直接拼接错版本。新状态仍能最终交付。
5. Observation 已有观察语义，不机械在每个字段前堆 equality guard。只在实测重建／重复通知热点的拥有者消除重复工作；不能用全模型相等屏蔽 readiness／error 转换。
6. 扩展现有模型／周期回归并运行完整完成流程；隔离 App 对照 index／log／refs／stash，确认相同 HEAD 的外部 Ref／stash 变化最终更新，隐藏／后台无周期查询。

**清理／提交：** 删除被替代的“分页全刷”和重复无用请求路径，不保留新旧策略开关。采用实现、回归和文档独立提交；无热点只留证据。

<a id="p4-t3"></a>
## P4-T3 在快照层预聚合共享装饰

**类型／依赖：** 条件性能实现；依赖 T1 核心快照；先以大树 trace 确认逐行扫描成本。
**文件：** GitStatusModel.applyRepository/clearRepositoryState/fileDecoration；复用 TreeDisplayModel.Status.directoryPriority。共享 helper 归属真的变化才改 TreeDisplayModel；不动 row 布局。测试 GitStatusModelTests／GitWorkspaceActionTests、FileTreeTests／TreeRowHitTestingTests；文档归 files.md／git.md 的相应事实。

**现状：** fileDecoration 对每行扫 ignoredPaths，目录再 filter 全 fileDecorations；Git pathRows 已有祖先聚合语义。parseStatus 按 path + tracked/untracked 去重，不保证全局路径唯一。

1. 先用真实模型及慢扫描 oracle 建立绿色等价基线：直接状态、忽略祖先和后代目录优先级、foo/foobar、repo root／仓库外、MM／A+M／rename/copy／conflict；同路径 staged deletion + untracked 是必测，不是异常输入。性能收益由 trace 证明，不用任意运行时间断言制造 Red。
2. entries／ignored 真变化时沿祖先建目录状态索引；查询用字典和祖先 membership，不逐行扫完整集合。当前直接状态先于 ignored，后代目录聚合复用 directoryPriority，保留相同路径的当前确定性选择结果，不趁机改颜色政策。
3. 全体 entries 合法含同路径双业务行，因此不能把 fileDecorations 改成 uniqueKeys 构造。聚合后装饰是一值，两条分组行仍存在；不是删除业务行来满足字典。parseStatus 去重及通用 pathRows 的重复输入处理保留。
4. GitPanel.changedFileRows 已分组，若能证明分组内唯一可直接映射，但只是相邻精简，不是强制性能项目；不得把这个局部前提外推到全体 entries。
5. 换范围／清仓库同步重置索引；同核心不重复重建，不能因为字节相同保留旧机器的身份。记录快照构造和查询成本，不把扫描搬成更贵的主线程重建。
6. `make test ONLY_TESTING=KeroTests/GitStatusModelTests`，GitWorkspaceActionTests／FileTreeTests／TreeRowHitTestingTests 和完整完成流程；隔离 App 检查 Files、changed、staged、history 的压缩、窄栏／字体、横滚／悬停／命中／辅助语义。

**清理／提交：** 用索引替代逐行全量扫描后删除旧扫描实现，不留兼容 fallback；不能删除有真实重复输入的聚合。实现、测试和文档独立提交。

<a id="p4-t4"></a>
## P4-T4 文件树刷新成本的最小实验

**类型／依赖：** 条件实验／实现；P1、T3 后排除装饰影响。
**锚点：** ToolPanelView.PanelSyncQueue/performSync → Project.syncFiles／PanelContext → FileTreeModel.sync/rebuild/children → LocalWorkspaceBackend.list／SSHWorkspaceBackend.list → TreeDisplayModel.Traversal；RemoteCommands.listDirectoryCommand/batchCommand。

当前 Files 读压缩目录的直接子项，不仅 expanded；live traversal 有 32 层保护 symlink 循环，Git 有限路径不同。PanelSyncQueue 和 FileTreeModel 的合并各管不同生命期，不因有两层 bool 就断言冗余。本地 list 已 @concurrent，items 已比较才发布。

1. 测初次展开、无变化 poll、外部 add/delete/rename、长压缩链与必要 SSH；分离 root resolve、list/stat／往返、排序／Traversal、发布／原生布局。
2. 选一个真正主导的分支：远程多轮 list 才试本 traversal 已知必需目录的有限 batch；重复处理主导才复用当次／当前范围数据。不预扫未访问子树、不以目录 mtime 缓存 symlink 类型、不减刷新能力。
3. 一轮定位和一个原型，无净收益就保留现有实现；需要新失效来源／watcher 再拿证据回改，不暗中加框架。
4. 若采用，扩展 FileTreeTests 的外部变更、draft／取消、压缩／symlink／dangling／循环、不可读保留、换范围和重建中最后事件，性能替代前后的正确行为应一致；发现真实缺陷才先 Red 再修。实测确认为两处独立所有者的错误：外层 PanelSyncQueue 用旧请求阻塞新目标且重复旧闭包，内层 FileTreeModel 的旧遍历／文件草稿及写前检查遗漏 backend 身份；各自只复用已有 PanelContext 身份与单一请求代次来修正，避免额外协调器或通用重试。
5. 运行 FileTreeTests、TreeRowHitTestingTests、PanelContextTests；批协议变动再跑 RemoteCommandsTests，之后完整完成流程与四区域原生验收。授权 SSH 才实测传输，隐藏／后台不得多 IO。
6. 同 task 删除被替代的重复 list／排序／发布／临时预取路径，文档同步 files.md；不新旧并行运行。

**提交：** 只提交采用的最小改动、回归及文档；实验无改动只交本地 evidence-p4.md。

## 阶段核销

T1 完成时核心、详情、错误、分页与全部动作已完整；T2–T4 不能成为前一 task 正确性的延期依赖。实际实施并验证后进入阶段审计，不能把计划复核当性能通过。
