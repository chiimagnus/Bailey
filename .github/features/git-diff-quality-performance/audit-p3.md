# Audit P3 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 修复 Git 输出预算与对象完整性
- [x] P3-T2 验证 Git patch 与原始工作区快照一致性
- [x] P3-T3 收拢可取消 Diff 计算和展示发布
- [x] P3-T4 核实可见语法着色缓存与释放

## 任务到文件的映射

- P3-T1 输出预算与对象读取
  - `Bailey/Git/GitCommandExecution.swift`、`DiffViewerView.swift`：bounded Git 执行与 `cat-file --batch` 的 OID／类型／长度校验；删除旧双进程和 Git 专有阻塞读线程。
  - `Bailey/Workspace/{WorkspaceBackend,LocalWorkspaceBackend}.swift`、`Bailey/Remote/{SSHWorkspaceBackend,SSHHostWorkspaces,RemoteConnection}.swift`：只为 opt-in 命令限流；真实进程接收超限即终止，普通状态／文件列表仍完整读取。
  - `BaileyTests/Git/{GitExecutionTests,NativeDiffTabTests}.swift`、`BaileyTests/Remote/RemoteLifetimeTests.swift`、`Bailey/Resources/Localization/Git.xcstrings`、`docs/features/diff.md`。
  - 提交 `97b8f6be`、`ad1e8a07`。
- P3-T2 Git / Worktree 快照
  - `Bailey/Git/DiffViewerView.swift`：并行 HEAD/Index OID 二次核对，沿已有代次重试；保留 `GitWorktreeComparison.resolve` 的规范化 Review 与原始编辑数据分离。
  - `BaileyTests/Git/NativeDiffTabTests.swift`：真实仓库 A/B reset 交错、index 更新、错误对象与过滤器；`docs/features/diff.md`；提交 `753e8b98`。
- P3-T3 计算与取消
  - `Bailey/Git/DiffEngine.swift`：显然高噪声词对预剪枝、Myers 取消；`DiffViewerView.swift`：`reloadTask` 唯一所有者与协作式子任务；删除已替代的后台 Git pipe 双线程。
  - `Bailey/Git/GitCommandExecution.swift`、`Bailey/Workspace/LocalWorkspaceBackend.swift`、`Bailey/Remote/{RemoteConnection,SSHHostWorkspaces,SSHWorkspaceBackend}.swift`：实际 PID 取消、超时与状态映射；`docs/architecture.md`。
  - `BaileyTests/Git/{DiffEngineTests,GitExecutionTests,NativeDiffTabTests}.swift`、`BaileyTests/Remote/RemoteLifetimeTests.swift`；提交 `d70ea53e`、`fd3a3f84`；审计 F-01 修复 `591764cd`。
- P3-T4 语法与资源寿命
  - `Bailey/Git/DiffSyntaxHighlighter.swift`：按 UTF-8 存储身份／逐字节验证后复用既有树，最多至文本 5 MiB 上限；普通 Worktree 仍用 Neon。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Editor/NativeSyntaxHighlightingTests.swift`：2／5 MiB、30 次冷热查询、十标签内存释放、退役后回调；`docs/features/diff.md`；提交 `d93ccc0e`。

## 发现项

## 发现 F-22

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Remote/SSHWindowsFileEventsTests.swift:81`
- 摘要：`Windows 文件监听取消实机夹具使用18秒READY等待和30秒远端租约，但生产协议允许30秒启动，且CIM进程核查每次至多20秒；冷启动与正常租约到期可误判为监听失败或误判取消成功`
- 风险：`实机16项矩阵首轮真实失败于READY与进程计数；不匹配的测试计时使SSH取消生命周期缺少可信的实际进程终止证据`
- 预期修复：`按生产启动协议验收READY，不改变生产超时；测试租约覆盖两次CIM检查，确保取消后的进程归零先于自然租约到期，保留READY、实际单监听实例和退出为零的断言`
- 验证：`build/p123-authorized-windows-16-live.log 首轮Red；build/p123-ssh-two-live-diagnostic.log 单独Green；build/p123-ssh-crosscase-20261109.log Rebase→Git刷新→Watcher顺序Green；按契约调整后重新运行16项授权Windows SSH，并核对0 failures、0 skipped和真实CIM进程数`
- 解决证据：`首轮 build/p123-authorized-windows-16-live.log 真实 Windows watcher READY 18秒夹具失败且CIM计数0；生产 SSHWindowsFileEvents.observe 在启动前允许30秒且监听任务远端有自然租约。旧夹具仅30秒租约，却在READY之后先后用CIM可各达20秒检测活动/退出，可能自然过期造成误判。测试改为契约32秒READY窗口、90秒有限租约确保两次CIM在自然过期前，仍断言真实唯一 powershell 进程与取消后0，不增加生产等待。独立 Green build/p123-ssh-two-live-diagnostic.log、原序三项 build/p123-ssh-crosscase-20261109.log，及完整实机 build/p123-authorized-windows-final-contract.log 16通过0失败0跳过退出0；本机宿主全量复验正在运行。`


## 发现 F-21

- 任务：`P3-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/Git/GitRemoteRefreshIntegrationTests.swift:224`
- 摘要：`授权 Windows SSH 真机 Git 自动刷新测试在核心仓库已就绪且 isRefreshing 结束后缺失首个历史提交 OID；旧测试只凭核心成功即取历史且实际历史明细未交付`
- 风险：`真实 SSH 首次加载时 Git Changes 核心可显示但 Graph 历史可能无法使用；可能是远端详情失败未恢复、远端批处理超时或测试对双阶段契约的错误前提，当前未确认根因`
- 预期修复：`基于实际远端 Git log、状态模型 detailError 与各阶段 readiness 复现；明确核心和历史的独立验收契约；若生产详情有真实失败或旧任务所有权问题，从 GitStatusModel 根因修复且不得只延长超时，保留核心可用性与真实历史字节断言`
- 验证：`保留 build/p123-authorized-windows-16-live.log 首次真实 Windows SSH Red，补测日志包含远端真实 git log/OID、hasCurrentHistory、detailError；定向 Windows SSH Red-Green 后回归 16 项真实 SSH 全覆盖、133 项 Git/SSH 与完整 make test，并执行 Bailey Dev GUI`
- 解决证据：`真实 Windows SSH 首轮16项中 GitRemoteRefresh 在核心可用后即解包可选历史元数据，1项失败；生产 GitStatusModel.runGitStatus/applyRepository 明确分 core 与 details，且 GitStatusModelTests.testDetailsQualificationFollowsCoreIdentityRatherThanRefreshActivity 真实验证详情失败可保留正确 core、呈现 detailError、后续刷新恢复。移除测试对首次必有 recentCommits 的错误前提，以核心 headOID 为初始身份；首次若详情成功则逐字核对历史OID，若失败须具有可见 detailError，后续真实外部 commit 与最新 Graph OID 一致仍是强制断言，停止轮询不得误发布。独立二项绿 build/p123-ssh-two-live-diagnostic.log，按原序三项绿 build/p123-ssh-crosscase-20261109.log；完整获授权16项 build/p123-authorized-windows-final-contract.log 16通过/0失败/0跳过/退出0。还捕捉到额外独立SSH真值查询偶发状态255，已移除该冗余往返，未把断线冒充空Git历史，未改生产超时或重试。`


## 发现 F-20

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Git/GitStatusModelTests.swift:2621`
- 摘要：`Detached Worktree 历史测试把本机 FSEvents 自刷新与 Graph 结果混合验收，没有明确 foreground 前提；生产在 App 后台会暂停 FSEvents，完整宿主测试出现等待外部 commit 超时的单项失败`
- 风险：`真实历史图谱的结果校验受用户切换桌面 App 和文件事件投递时序影响，失败无法直接区分 Git 快照错误和事件丢失；延长超时或增加本机轮询会掩盖问题`
- 预期修复：`先核对实际四象限 Git fixture 与 FSEvents 生命周期；分离 Graph 显式查询验证和独立真实 Worktree 外部提交的自动事件测试，不删除自动刷新覆盖，且加入事件与前台诊断`
- 验证：`保留 build/p123-audit-20261109-final-full.log Red 证据；在本机反复执行 sha1/sha256 × local/受控 SSH，验证专门本机 FileEvents 三项及本机后台/前台切换，最后使完整 make test 和隔离 Dev GUI 全绿`
- 解决证据：`First full regression build/p123-audit-20261109-final-full.log had one detached Worktree history test failure waiting on implicit FSEvents; separate Git graph snapshot refresh from native event contract, preserve all graph sha1/sha256 x local/controlled SSH and checked OIDs. build/p123-worktree-fsevents-green-v2.log five tests zero failures include new native FSEvents real external linked HEAD commit + three existing event/foreground tests. build/p123-audit-20261109-final-full-v2.log 920 tests zero failures 16 conditional skips; Bailey Dev build/p123-audit-20261109-git-ui-final.log 55 GUI tests zero failures incl real external Worktree Index/Commit refresh. No production polling, no wait length increase, no lowered Git correctness assertions.`


## 发现 F-19

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitStatusModel.swift:478`
- 摘要：`展开历史提交的二进制元数据与 Stash 文件列表仍由无所有者 Task.detached 读取；切换仓库、替换 SSH 通道或销毁 Git 面板只能丢弃结果，不能取消仍运行的请求`
- 风险：`真实可达的 GitPanel 展开入口会让过期 show/numstat 与 stash diff 后台命令持续占用旧 SSH 连接或本机进程；现有 stash 断线回归必须显式 release 旧请求才能结束，恰好暴露后台任务仍未取消`
- 预期修复：`复用 GitStatusModel 自身生命周期，给有并发请求的历史/储藏读取建立按对象键控的任务所有权，切换上下文与模型销毁时取消旧任务；删除已被任务映射替代的 pending 集合，不取消正在消费的有效当前请求，保留缓存和重试`
- 验证：`先以受控可取消 SSH 后端复现当前 Red，核对展开历史/储藏后切换通道及销毁模型时底层运行数和取消数；修复 Green 后验证仍可加载真实 commit/stash 字节、失败重试和无重复请求，并执行 GitStatusModelTests,NativeGitHistoryFileTests,GitStashActionTests,RemoteLifetimeTests 与全量 make test`
- 解决证据：`Red build/p123-optional-git-read-red.log: two real Git temporary repositories with blocked old SSH reads, 5 assertions failed; Green build/p123-optional-git-read-green.log 2/2 pass. Red build/p123-optional-git-prune-red.log: external Stash drop and Git history rewrite 2 failures / 4 assertions, final Green build/p123-optional-git-prune-green.log 3/3 including model deinit. GitStatusModel owns per-OID binary/stash tasks, cancels during switch/deinit and on removed visible OIDs, clears previous pendingBinaryCommits; real binary path/stash file bytes on reconnected channel and current successful reads asserted. Expanded 133 tests 0 failures 1 SSH skip and old UI 55/55 pass; full suite final recheck in progress.`


## 发现 F-18

- 任务：`P3-T4`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`docs/features/diff.md:109`
- 摘要：`P3 已将语法树缓存上限从 2 MB 改为 5 MiB，当前 Diff 功能文档却仍声称超过 2 MB 不缓存`
- 风险：`维护者依据过期文档错误理解 2–5 MiB 的解析重复成本与内存边界；本地测试名称仍强调旧 2MB 门槛`
- 预期修复：`将现行功能契约统一为最多 5 MiB 且关闭标签释放 Tree-sitter 解析树；保留 2 MiB 前后回归取值但将测试和日志标识更新为当前 5 MiB 语义`
- 验证：`核对 DiffSyntaxSource.maxCachedTextBytes 与文件展示上限，执行 testVisibleSyntax... 的 2MB 前后/5MiB 缓存测试及 release build；检查 docs 索引`
- 解决证据：`49fe04b4：生产 DiffSyntaxSource.maxCachedTextBytes=5<<20，文档改为5MiB；1,999,998/2,000,010/5,242,880字节1/10/100可见区间30次复用 parseCount=1，超过5MiB连续解析两次 parseCount=2；make test ONLY_TESTING=BaileyTests/NativeDiffTabTests/testVisibleSyntaxUpToFiveMiBReusesOneTreeAcrossThirtyFoldQueries 1/1成功，git diff --check通过`


## 发现 F-17

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitStatusModel.swift:1101`
- 摘要：`Git 状态刷新仍将实际 Git/SSH 读取放在无人持有的 detached Task；切换项目/通道或 watchdog 过期只更新代次而不取消底层 I/O`
- 风险：`旧项目和旧 SSH 通道的状态请求可以持续占用进程、连接、后台计算直至命令超时，虽不能覆写新结果，却违反 P3 资源释放与旧请求终止验收`
- 预期修复：`先用可取消且可观测真实工作中的后端复现旧命令未停止；在 GitStatusModel 唯一刷新 owner 持有并取消正在运行的状态读及 watchdog，取消传播到实际子进程，不复制 generation，不取消仍有消费者的当前刷新`
- 验证：`新增 GitStatusModelTests 的切仓库/更换 SSH 通道/超时/竞争时序 Red→Green，断言旧命令确实收到取消并停止、新项目 Git 字节正确；再执行相关 Git+SSH 宿主与完整 make test/隔离 GUI`
- 解决证据：`Red build/p123-status-cancel-red.log: canceled status read continued after repository switch; Green build/p123-status-cancel-green.log and GitStatusModelTests: GitStatusModel now directly owns statusRefreshTask plus timeout Task, invalidate/deinit cancels actual awaited Git/SSH I/O; new repo bytes, model deinit, 30-s watchdog and old-connection cancellation checked. build/p123-git-owners-final-expanded.log 133 tests 0 failures 1 conditional SSH skip; build/p123-audit-20261109-final-full-v2.log 920 tests 0 failures 16 conditional skips and exit 0; Bailey Dev git UI 55/55.`


## 发现 F-04

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:59`
- 摘要：`取消发生在子进程退出后的stdin写入者等待期时无法中断，SSH还错误映射为普通命令失败`
- 风险：`ProcessStdinWriter.finish无取消出口；子进程后代继承pipe但不消费2MiB输入时，已取消的本地或远端请求仍等待完整超时、保留写入缓冲和调度线程。`
- 预期修复：`共享ProcessStdinWriter实现线程安全的协作取消，实际进程所有者在所有退出路径完成停止和join；取消后返回CancellationError/-4而非超时/错误，不另建备用管道执行器。`
- 验证：`真实后台子进程分别触发本地和SSH runner取消的Red-Green；make test:GitExecutionTests,RemoteLifetimeTests；最终make test和make build。`
- 解决证据：`Red build/p3-audit-F04-red.log: local timedOut 3.046s and SSH commandFailed 3.047s; Green build/p3-audit-F04-green.log: 25/0, local 0.355s and SSH 0.208s; commit 8d33532c; full build/p3-audit-F04-full.log: 907/0/16 skips; build/p3-audit-F04-build.log: BUILD SUCCEEDED and codesign verify.`


## 发现 F-03

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/DiffViewerView.swift:1282`
- 摘要：`clean filter在hash-object到git diff间改写工作区但规范化OID不变时，成功路径不复核原始文件字节`
- 风险：`Git patch OID与规范化文本相符仍可让原生编辑器展示过时的raw正文；用户在旧字节上编辑保存会覆盖过滤器或外部写入的最新字节。`
- 预期修复：`用真实Git复现并在Diff读取所有者校验返回时的原始工作区快照；发生变化沿已有snapshotOutdated重读，不新增全局协调状态。`
- 验证：`make test:NativeDiffTabTests,DiffEngineTests,GitExecutionTests; make test; make build`
- 解决证据：`Red build/p3-audit-F03-red.log: raw first versus disk second; Green build/p3-audit-F03-matrix-green.log: Worktree and RevisionWorktree; commit 82b8c03b; final build/p3-audit-F04-full.log: 907 tests, 0 failures, 16 conditional skips; make build build/p3-audit-F04-build.log: BUILD SUCCEEDED and codesign verify.`


## 发现 F-02

- 任务：`P3-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift:1109`
- 摘要：`完整宿主回归中原生 FileTab 关闭后对象释放断言超时`
- 风险：`make test 在 NativePaneRetentionIntegrationTests 运行到最后一次旧/新 TextKit 表面退役与 FileTab 销毁后，10秒内弱引用未全部归零；需要区分实际生产对象泄漏与宿主 NSWindow/SwiftUI 缓存持有。`
- 预期修复：`先逐项定位哪个弱引用存活，隔离复现，沿 FileTab/SourceTextEditor 所有者处理，不能放宽原有释放断言。`
- 验证：`定向 NativePaneRetentionIntegrationTests 完整回归及最终全量 make test，核对视图和 FileTab 均实际释放`
- 解决证据：`根因：AppKit缓存无主NSTextView，弱引用在10秒内不保证nil，但FileTab全部释放；真实缺陷为缓存旧view保留200000 UTF-16字符。新增build/p3-audit-F02-text-red.log Red，Green build/p3-audit-F02-text-green.log；Source退役清除旧NSTextStorage/编辑观察者并重置行索引，5项归属测试0失败、完整影响范围268项0失败1 SSH跳过；提交9b8db08c。`


## 发现 F-01

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitCommandExecution.swift:4`
- 摘要：`进程级登录环境首次惰性初始化继承已取消 Git 任务，可能永久缓存取消错误`
- 风险：`GitCommandExecution.localEnvironment 是 static let；初始化走新改成可取消的 runProcess/runSync。若第一次同步 Git 调用处于取消态，返回 -4 并被永久缓存，后续未取消任务也无法运行 Git。`
- 预期修复：`将一次性的全局环境加载与单次可取消 Git 命令隔离；只修真实初始化 owner，不新增备用环境或双轨执行。`
- 验证：`新增取消态首读隔离 XCTest Red-Green，再运行 GitExecutionTests、NativeDiffTabTests 和完整 make test`
- 解决证据：`Red: build/p3-audit-F01-red.log 1项2断言失败,status=-4 且 PATH 缺失；Green: build/p3-audit-F01-green.log 5项0失败，commit 591764cd；静态环境加载免请求取消、单次 Git/SSH 保留取消。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-01：已记录 Red 后，在 `GitCommandExecution.loadLoginEnvironment` 单次全局初始化入口显式传入 `honorTaskCancellation: false`，并让共同 `LocalWorkspaceBackend.runSync` 仅为该初始化绕开调用方取消；每条普通 Git／SSH 命令仍默认受取消约束。旧的 Git 专有双阻塞读线程此前在 T3 同次提交删除。本修复 `591764cd`；取消态首读先返回 -4 缺失 PATH，后返回合法 PATH，5 项跨进程／Diff 取消回归通过。
- F-02：首轮 `make test` 在两项 `NativePaneRetentionIntegrationTests` 失败；逐项证实 `FileTab` 已释放，部分 AppKit 缓存的 `NSTextView` 虽脱离窗口并禁用语法／Undo，仍保留 **200000 UTF-16 字符**，是实际陈旧文本内存占用。尝试强行移除 SourceTextEditor 的 TextKit 布局管理器仍未让视图释放，且触发系统警告，已撤销。改在 `NativeCodeTextView.retireNativeDocument` 真正文档退役时移除编辑观察者、清空旧 `NSTextStorage` 并释放行索引；重置 Undo，再由 FileTab 关闭移除滚动宿主。原有两个测试改为断言文件所有者释放、旧视图不附着／不可写／无语法／无 Undo／零文本字节，保留另一测试验证真实完整窗口关闭时全部对象释放，不用延时或放松数据保护。新增明确保留旧 NSTextView 的 Red→Green 200000→0 字符测试，`9b8db08c`。

## 验证日志

- 环境：本机 Apple Silicon macOS 27.3 beta、Xcode-beta；源代码与测试均从 `fix/diff-review-viewport-and-syntax` 分支执行，Git、文件和权限测试使用随机隔离仓库／夹具，未操作用户真实仓库数据。
- T1：`make test:GitExecutionTests,NativeGitHistoryFileTests,NativeDiffTabTests,GitBrowsingRecoveryTests,RemoteCommandsTests,RemoteLifetimeTests,GitStatusModelTests,GitRemoteRefreshIntegrationTests` → 227 项，0 失败，2 项真实 SSH 环境跳过；追加 Git/SSH 边界与批量对象读取 124 项，0 失败。验证真实管道的 stdout／stderr 同时溢出、逐字节上限、5 MiB 前后一字节、批量 OID 类型长度／短读／非法内容／二进制及退出和超时，未把不完整字节发布为成功 Diff。
- T2：真实临时仓库先 HEAD/Index A 后 reset 至 B、两态均无 Staged 差异，Red 验证跨代次虚假修改、Green 拒绝混合快照；9 项快照／filter／CRLF 定向测试、127 项 Diff/历史测试均 0 失败（后者 1 项远端跳过）。其余覆盖 clean filter 有损与可逆、`text/-text/eol`、Unicode 正规化、无末行 LF、冲突／删改、保存原文／外部文件写入／撤销及历史来源。
- T3：399／400-token 的 1000 对密集行内比较由约 37 秒降至 0.42 秒（Debug）；`DiffEngineTests` 24 项 0 失败；取消中实际本机 Git、工作区、SSH PID，以及差异标签切换／关闭的 Red→Green 4 项，约 0.2–0.9 秒完成，随后范围扩至 145 项 0 失败（1 项无授权 SSH 跳过）。F-01 专项 `build/p3-audit-F01-red.log` → 1 项 2 断言失败；`build/p3-audit-F01-green.log` → 5 项 0 失败。
- T4：`build/p3-t4-green-all.log` → `make test:NativeDiffTabTests,NativeSyntaxHighlightingTests,HighlightQueryCacheTests,NativeContentIdentityIntegrationTests`，148 项 0 失败（1 项授权环境跳过），后续 `build/p3-t4-final-two.log` 对内存阈值与退役测试更新复测 2 项 0 失败。2 MiB 前后及 5 MiB 文件的 30 次折叠查询仅第一次解析；5 MiB 冷解析约 2.29 秒，热单区间约 0.08 ms。10 个 2.079 MB 解析器实际 malloc 由 384,263 KiB 升至 1,161,635 KiB，释放后回到 397,160 KiB，所有弱持有者释放；RSS 因分配器保留已映射页未立即下降，**不等同于仍活跃的树**。
- F-02：`build/p3-audit-F02-text-red.log` → 测试 `testRetiredNativeDocumentReleasesLargeTextFromCachedAppKitView` 真实失败（缓存视图还有 200000 UTF-16 字符）；`build/p3-audit-F02-text-green.log` → 同测试通过，退役后为零，文件模型和磁盘字节不变。`build/p3-audit-F02-owner-green.log` → 5 项窗口／退役矩阵 0 失败，`build/p3-audit-F02-targeted-all.log` → **268 项 0 失败，1 项无授权 SSH 跳过**（FileTab 持久化、编辑器布局／组合、Diff、Neon、窗口／TextKit 生存期）。
- `make build` → `build/p3-phase-build-final.log` 完整退出码 0、`** BUILD SUCCEEDED **` 且 `codesign --verify --deep --strict` 通过（F-02 后最后一次构建）。既有编译警告来自 vendored `BaileyGrammars`、`WorkspaceWindowModel.swift:1083` 以及缺少 AppIntents.framework 时 metadata 跳过，不是 P3 新 Swift 编译问题。
- 首轮 `make test` → `build/p3-phase-full-test-final.log`，退出码 2，903 项、16 项跳过、11 条失败断言全部在两条 NativePaneRetention 测试；已复现、修复且扩大回归转绿，不能计为阶段通过。
- F-02 修复后完整 `make test`：`build/p3-phase-full-test-final-green.log`，`** TEST SUCCEEDED **`，904 项、0 失败、16 项环境条件跳过；不存在持续运行的 xcodebuild/make 进程。`make build`：`build/p3-phase-build-final.log`，`** BUILD SUCCEEDED **` 且正式 Debug 包通过 `codesign --verify --deep --strict`。本阶段未运行 Release 构建（无发布相关改动）。
- 条件矩阵核销：本机 Git 真实仓库新建／增删／改名／mode-only／初始无 HEAD／冲突索引，字节级 Unicode／特殊路径／二进制／大小边界／损坏或缺失 OID；Worktree Raw 与规范化 Review 分离；数据加载期间的 index、HEAD 与工作区替换；文件保存、断线、错误反馈、取消、超时、过期 publish、恢复；1k/24k/100k 文档的 Unified/Split、折叠、原生输入与最深滚动；语法 2MB/5MiB、多区间与多标签释放，均由归属宿主回归构成。
- 未测边界：（1）真实 Windows SSH Git/网络 RTT、实机 `core.autocrlf`、远端 clean filter 及断线重连：无用户授权 SSH 测试主机/临时根目录；当前仅本机 Git + 仿真 SSH 命令边界与受控工作区后端验证，须 P4-T3 有授权机器后实测，影响远端验收。（2）完整 Bailey Dev GUI `WorkspaceGitUITests` 中的真实菜单、焦点与原文保存：本轮没有可安全独占的 macOS 图形会话，不为测试抢占用户现有桌面；原生宿主的 TextKit、保存和 Git 状态测试可证明组件不变量，但不能替代 App 级 UI E2E，需 P4 专用图形会话补验。
- 文档 owner：`docs/features/diff.md` 描述 Git Batch、Index 快照、过滤器、取消与语法缓存契约；`docs/features/editor.md` 补充真正退役时释放旧正文而非强制等待 AppKit 视图析构；后端职责调整同步 `docs/architecture.md`。`docs/testing.md` 仍是唯一测试完成标准；现行 P3 计划的 `todo.toml` 不提交。核对 `git diff --check` 与实际文件路径。


## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P3-T1～T4 全部按任务目标完成，F-01、F-02 经 Red→Green 修复；最终正式 Debug 编译/签名通过、904 项宿主测试 0 失败。真实 SSH 与专属 GUI E2E 明确归属 P4，不能将 P3 宿主测试结果替代这些验证。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 Windows SSH 主机与完整 GUI 操作尚未覆盖，按 P4-T2/T3/T4 继续验收。正式安装未执行：2026-11-08 17:41 确认 `/Applications/Bailey.app/Contents/MacOS/bailey` 仍在运行（PID 8571），根据 `AGENTS.md` 不替换正在使用的正式应用；本次只完成构建与签名，不声称已经安装、重启或发布。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 本轮独立逐提交复审（2026-11-08）

本轮先独立检查 `todo.toml`、P3 计划、每个实现提交与现行 CodeGraph 调用链，再读取既有审计记录；
下列勾选来自本轮源码与真实 Git 验证，并非沿用上次 Gate。受影响路径为实际
`GitPanel / RecentCommitsView → Project.openDiff → DiffTab → GitCommandExecution / DiffEngine / DiffSyntaxSource`。

- [x] P3-T1 `97b8f6be`：本机 `LocalWorkspaceBackend.runSync` 与真实 SSH 进程收包分别实施 stdout／stderr 上限；
  仅 opt-in 的 Blob／metadata／patch 启用限制，超限不能发布截断成功，普通状态列表不受影响。
- [x] P3-T1 `ad1e8a07`：OID 从 NUL metadata 精确选择，`cat-file --batch` 单次读取后检验 OID／类型／声明长度／正文／结束标记；
  生产不再执行旧的 size→content 两步读取。
- [x] P3-T2 `753e8b98`：Staged 并行 HEAD／Index 的 Blob 锁定后重新检验当前 OID；真实 reset A→B 交错时只接受一致代次。
- [x] P3-T3 `d70ea53e`：密集逐词 Myers 先执行安全下界判定、随后检查循环取消；共享词／Unicode／阈值边界仍保留。
- [x] P3-T3 `fd3a3f84`：Diff 加载与显示分别由标签拥有且取消；取消穿透本地与 SSH 的真实进程和 PID，
  移除旧 Git 私有读线程，不以丢弃过期结果替代进程结束。
- [x] P3-T4 `d93ccc0e`：旧／新侧分别复用带 UTF-8 身份验证的有界 Tree-sitter 树，
  编辑侧 Neon 不叠加离线着色，折叠可见区重复查询不重复 parse，关闭时释放缓存。
- [x] 后续 `591764cd`：首次全局登录环境初始化不能受某条 Git 请求取消污染。
- [x] 后续 `9b8db08c`：Files／Diff 真实退役会清空旧 TextKit 正文、观察者、Undo 和语法引用；
  AppKit 暂留已脱离的视图不等于仍持有正文。
- [x] 清理核对：产品内无旧 Git 私有读线程、无旧 `highlightByteLimit` 与测试用全文 `DiffSyntaxHighlighter.captures`；
  测试里的 `cat-file -s` 仅作旧方案延迟基准；快照／字节／取消保护具实际消费方，不属于可删除的兼容围栏。
- [x] 独立增补 F-03：clean filter 改写原文但保留相同规范化 OID，旧实现把陈旧原文交给编辑器；
  真实 Git 回归 Red（1 项 1 断言失败），新实现发布前再次核对原始字节，
  Worktree 与 Revision ↔ Worktree 两种入口均 Green（1 项含 2 工况），提交 `82b8c03b`。
- [x] 独立增补 F-04：退出的子进程留下仍持有 stdin 的后代，原 `ProcessStdinWriter.finish` 无法感知取消，
  已取消的本机与 SSH 命令分别超时／误报普通失败；两个实际进程测试 Red（3.046／3.047 秒），
  共享写入者及真实进程 owner 增加协作取消／清理，Green（0.355／0.208 秒）；
  `make test:GitExecutionTests,RemoteLifetimeTests` 25 项 0 失败，提交 `8d33532c`。
- [x] 原实现影响范围回归：`build/p3-audit-regression.log`，260 项、0 失败、1 项真实 SSH 环境跳过。
- [x] F-03 修复后完整宿主 `make test`：`build/p3-audit-F03-full.log`，905 项、0 失败、16 项环境跳过，退出码 0。
- [x] F-03 与 F-04 两次修复后的完整宿主回归：`make test` → `build/p3-audit-F04-full.log`，
  退出码 0，**907 项／0 失败／16 项环境跳过**；新增两个真实进程取消测试与原始快照测试均在全量中通过。
- [x] 最终正式调试版本 `make build` → `build/p3-audit-F04-build.log`，退出码 0，
  `BUILD SUCCEEDED`，`codesign --verify --deep --strict` 退出码 0。
- [x] F-03、F-04 均由 `finding resolve` 标为 `Resolved`，提交分别为 `82b8c03b`、`8d33532c`；
  两个功能提交各自原子化包含生产实现、真实回归与文档，未将本地审计文件提交到产品分支。

### 本轮独立 Gate

- **P3 结论：Go**。P3-T1～T4 的核心生产消费、关键不变量、跨代次与取消生命周期已逐提交核对；
  新发现的两处真实缺陷已 Red→Green 并完成最后全量测试及正式 Debug 构建／签名。
- **冗余清理：已核销**。旧 Git 双读取／管道专用实现、测试专用语法解析与预算均不存在于生产；
  其余看似重复的 OID、Raw 字节、超限和取消检查有不同职责，无证据支持删除。
  不为缩减行数而删除防止错误文本发布或遗留进程的正确性检查。
- **未覆盖**：独占图形会话下的完整 Bailey Dev GUI，以及授权真实 Windows SSH 网络／clean filter／断线恢复；
  这些仍归 P4 对应测试，而非以本机宿主回归推断已验收。
- **未安装正式应用**：本轮只编译及校验构建产物，不覆盖正在运行的 `/Applications/Bailey.app`。
- **审计产物状态**：此处记录 2026-11-08 的历史 Gate；本次新增源码与测试以 2026-11-09 复审段为准，不能沿用先前“所有生产修复已提交”结论。

## 2026-11-09 P3 后置审计与当前 Gate

- 原生与 Git／SSH：`build/p123-audit-20261109-923-final.log`，完整 `make test` 923 项、0 失败、16 项专用 Windows SSH 条件跳过、退出 0；`build/p123-git-owners-final-expanded.log` 133 项、0 失败、1 条件跳过。
- 真实 Bailey Dev GUI：`build/p123-audit-20261109-git-ui-final.log` 55 项、0 失败、0 跳过、退出 0，覆盖真实 Changes、历史、Stash、窗口归属和外部 Worktree 变更。
- F-17：状态刷新及超时由 `GitStatusModel` 任务持有，真正取消旧进程与连接；Red→Green、超时、切仓库、SSH 通道变更和模型销毁均已测试。
- F-19：历史二进制及 Stash 文件读取由同一状态所有者按 OID 持有并取消；已删除旧 `pendingBinaryCommits`／无所有者 `Task.detached`，补齐断线、新连、外部 Stash 删除、历史重写和模型释放 Red→Green。未失效的查询与缓存仍可复用。
- F-20：将真实 Git 图谱查询与原生 FSEvents 外部 HEAD 提交分开核验，5 项定向与完整 GUI 均通过，未用轮询或增加等待掩盖旧夹具隐含前台条件。
- 真实 Windows SSH：获授权的 `windows` 主机已核实 Windows 10/MSYS、Git 2.56、PowerShell 7；只使用测试自有临时仓库与专属 master。首次 `build/p123-authorized-windows-16-live.log` 16 项中 14 通过、2 失败，真实 Red 永久保留；后续原序交叉测试 `build/p123-ssh-crosscase-20261109.log` 三项通过。更正测试契约后 `build/p123-authorized-windows-final-contract.log` **16 项、0 失败、0 跳过、退出 0**，包含真实 Git 对象、CRLF／clean filter、Worktree、8 MiB 传输、断线恢复和 PowerShell watcher 取消。
- F-21：原测试把完成的 Git 核心快照误认为历史详情一定已交付，与现行两阶段契约冲突。现从核心 `headOID` 锁定初始身份，历史已验证时比较 OID，详情失败时要求公开 `detailError`，随后必须通过真实外部提交／Graph OID 与轮询取消的最终断言。额外 SSH 真值查询曾实际返回 255（连接被关闭），因非原测试目标且会制造多一次不必要的连接而移除；不能据此宣称已找到首轮历史缺失的唯一网络根因。生产所有权和正确性保护不变。
- F-22：独立 Windows watcher 测试先前 18 秒 READY 等待小于生产可允许的 30 秒启动；其 30 秒租约又可能短于启动及两个最长 20 秒的 CIM 查询，无法区分取消与自然结束。现按生产启动契约等待 READY，使用覆盖两次 CIM 查询的有界租约；同时断言唯一真实 PowerShell watcher、取消后进程归零及归零发生在租约自然到期前。最后新增的时间断言已在 `build/p123-ssh-watcher-lease-final.log` 定点实机复测，1 项通过、0 失败、退出 0。未更改生产超时或增加兼容分支。
- 本机最终闭环：`build/p123-final-post-windows-host.log`，完整 `make test` **923 项、0 失败、16 项真实 Windows SSH 条件跳过、退出 0**；这些 16 项在另一轮启用授权主机的 `build/p123-authorized-windows-final-contract.log` **16 项、0 失败、0 跳过、退出 0**，不以跳过冒充执行。`build/p123-final-post-windows-build.log` 的 `make build` 为 `BUILD SUCCEEDED`，后置 `codesign --verify --deep --strict` 退出 0。完整隔离 Bailey Dev GUI `build/p123-audit-20261109-git-ui-final.log` 55 项、0 失败、0 跳过。
- 提交：`1f3987d3`（Git 状态与历史详情的可取消任务所有权），`5dc33923`（两项 Windows SSH 实机验收契约校正及租约真实取消断言）。只提交对应生产／测试源码和同步功能文档；本 Feature `idea.md`／`todo.toml`／`plan-p2.md`／`audit-p*.md` 依 Skill 规范保留本地作为真源与证据，不误入 Git 提交。
- **当前 P3 Gate：Go**。逐项实现、老旧路径清理、真实副作用、Red→Green、完整宿主、正式构建与签名、55 项完整 App GUI，以及全部 16 项授权 Windows SSH 实机测试均已实际核对。F-17／19／20／21／22 已解决，无剩余 Open finding；首次失败及中途 SSH 255 日志仍保留。正式 Bailey 未替换或重启。**此结论只针对 P3：P2-T1 的可变高度首帧／滚动几何仍为 `blocked`（P2 Gate No-Go），P4 的额外精确窗口像素／IME 条件未在本轮验收，不得宣称 P1–P4 全部交付。**

