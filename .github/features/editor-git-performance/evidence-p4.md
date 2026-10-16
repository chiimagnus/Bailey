# P4 执行证据

## T1：核心先可用，不伪造详情

源码沿 `sync → refresh → runGitStatus → apply`、真实菜单／底栏、`perform`、后端命令和原始文件读取复核。保留现有 requestID、contextGeneration、刷新合并与独立 watchdog，不新增刷新协调器。

- 同一个 worker 先交付状态、HEAD／上游及 operation，再读取详情；核心和完整详情用可选详情值区分，不以空数组冒充成功。当前核心进入缓存，同时保留同仓库上次完整详情供恢复。
- 详情失败保留已成功核心和旧详情；当前动作资格与展示分开。普通暂存／取消暂存／提交／Amend 不等历史，引用类写操作在既有 perform 汇聚点检查详情资格。新建 Tag→真实 OID→推送不依赖旧 Ref 缓存，保留原链路与最终远端对象验证。
- SSH 拆核心／详情批次，缺帧或失败不再逐命令重取；默认分支直接用已取 Ref 的 symbolic 值，删除额外 symbolic-ref 查询。
- numstat、operation、统计和交互 master 检查计入原预算。不可中断的文件系统调用仍由独立 UI watchdog 结束等待，不能承诺内核调用硬取消。
- 本地和远端按剩余字节限制实际读取。保留 8000 字节 NUL 探测、symlink 与末行语义；远端改为纯数值帧并校验负数、容量、记录数和完整标志，不兼容旧路径输出。超容量是未知统计，不是精确 +0；读取失败仍报告错误。

### Red／Green 和相邻路径

- `p4-core-red.log`：暂停实际 history 批次时旧模型仍没有仓库／分支／文件列表，5 项断言失败。`p4-core-first.log`：13 项模型回归通过。
- `p4-count-red.log`：旧统计接受负值及文件名伪造记录，2 项断言失败。新协议回归拒绝它们；实际 shell 读取验证换行／tab 文件名、binary、NUL 在探测后、symlink、超限及 stat 后增长，输出字节不超过预算。
- `p4-t1-focused.log` 的 75 项联合中，新鲜度统一塞进 isCurrent 导致既有“新建 Tag 后立即推送”3 项断言失败。这是过度围栏，不接受延迟／等待掩盖；改回身份职责，并在真正消费详情的 perform 入口检查资格。`p4-t1-focused2.log` 的35项通过，含实际新 Tag 远端 OID。
- `p4-t1-boundaries.log`：29 项通过，含核心可用时 Amend 的真实 HEAD／文件、缺批次只调用一次而非重取、恶意统计、读取异常和零预算检查。之后又补了容量恢复和目录记录边界；最终结果以下方最终验证为准。
- 第一轮全量暴露了“任何刷新一开始就撤销资格”仍过度限制：历史文件恢复和 Branch／Tag 失败重试被挡住。撤销规则改回详情的真实身份／失败边界；没有给这些恢复路径逐个增加绕过或等待。该次 `p4-t1-full.log` 是失败证据，不计最终通过。
- `p4-directory-red.log` 实际验证远端遇到合法目录记录会误报整体失败。普通目录／非文本节点现在明确返回不完整统计，缺失／读取失败仍报错，和本地语义一致；不会打开 FIFO 或把目录伪报成精确零。

测试远端 shell 时仅将 GNU stat 格式翻译为本机 BSD stat，其余脚本实际执行；这是受控协议／后端集成，不是真实 SSH 网络验收。

### 同机前后测量

macOS 27.2（26B5101f），MacBookPro18,3／arm64；Xcode beta 27.0（27A5209h），Debug。同一份 P1 的 `a/git-many`、`git-history`、`git-unborn`，每份30次新建模型、同一顺序，文件系统为重复访问，不称冷磁盘或冷 App。轮询1ms，终点分别为核心状态发布和刷新结束，**不是绘制首屏／E2E**。

旧实现取 HEAD `3a13753` 的8个受影响源码／测试文件临时回放，通过根 Makefile 执行相同 XCTest；finally 已恢复当前实现。临时测试随后移回 build/performance，不进入产品／永久测试集。

| fixture／阶段 | 旧 median／p95／max ms | 当前 median／p95／max ms |
| --- | --- | --- |
| git-many 核心 | 297.775／317.980／563.854 | 89.954／131.918／381.193 |
| git-many 全部详情 | 297.776／317.981／563.859 | 302.620／370.684／606.192 |
| git-history 核心 | 206.850／230.177／237.101 | 74.884／96.763／97.593 |
| git-history 全部详情 | 206.852／230.179／237.105 | 203.063／236.136／264.375 |
| git-unborn 核心 | 223.452／242.347／259.882 | 74.549／79.473／80.664 |
| git-unborn 全部详情 | 223.454／242.348／259.883 | 223.504／238.012／244.863 |

原始样本：`p4-baseline-performance.log`、`p4-current-performance2.log`，实验源码 `GitRefreshPerformanceTests.swift`。核心确实不再等详情，但没有减少完整快照的主要工作量；不宣称总完成时间普遍变快。进程环境首次初始化保留在各自第一个样本里。

独立第一轮当前样本期间采了精确 XCTest PID 802 的5秒 sample（`p4-current-sample.txt`）；该轮 `p4-current-performance.log` 不作为无干扰 p95 对照。采样中主线程主要在测试 RunLoop 等待，Git／IO 不在主 actor。Instruments 的既有 beta 签名限制仍在，不用 sample 冒充 Allocations／RSS。

## T2：按已知动作消除重复刷新工作

先读取真实 `refresh/perform/loadMoreCommits` 和 Ref、Stash、log、numstat 的调用路径。使用固定 P1 仓库，各命令 30 次独立执行（当前 Mac、重复访问；仅判断重复工作成本，不冒充 App 可见延迟）：`git-many` 的 status／numstat／history／refs／stash 中位分别约 25.855／94.879／18.169／17.398／16.626 ms，`git-history` 对应 18.329／17.679／24.365／19.117／16.671 ms。总耗时尚未做同流程重复 A/B，不声称速度倍率。

`p4-t2-red.log`：受控后端记录实际命令，暂存后仍执行 log、Ref 和 Stash，分页再做 numstat，4 项断言 Red。改为 `.full`／`.indexOnly`／`.historyOnly` 明确刷新请求，在同一请求失效机制下合并不同需求时升级 full；局部索引变更只读 core+totals，分页只读 core+Ref+更大 limit 的 log。固定 HEAD／scope 及引用一致性才保留已有已验证详情；外部 Ref 或 core 不一致时补全快照。已知动作不推断未知终端命令，显式刷新及前台周期仍完整执行。

`p4-t2-green1.log`：暂存／分页的真实仓库 Green。`p4-t2-suite.log` 19 项 0 失败，随后补上分页间 Ref、工作区事件竞态；后一项测试明确模拟外部写入**后**发来的完整刷新事件，不能要求已经结束的 core 扫描凭空获知未来写入。`p4-t2-concurrent-fix.log` 定向测试 1 项通过。最终 `p4-t2-final-full.log`：294 项，0 失败，3 项专用 SSH skipped；`p4-t2-final-debug.log`／`p4-t2-final-release.log`：Debug／Release 构建和严格验签通过。均用真实 Git 临时仓库，不以受控 SSH 冒充真机。

## T3：共享文件树装饰预聚合

先取旧 `fileDecoration` 完整扫描作为行为 oracle，使用临时 1000 个修改文件、200 个工作目录、200 个忽略目录的 Git 仓库做每类 30 次真实模型查询；原始数据 `p4-t3-baseline.log`、`p4-t3-final-benchmark.log` 和本地忽略的 `GitDecorationPerformanceTests.swift`。同一台 Mac、同一固定 fixture、Debug／重复访问，测的是状态装饰查询，不是屏幕帧时间。单位 ms，数值为 median／p95：

| 每组查询 | 旧 | 新 |
| --- | --- | --- |
| 200 变更目录 | 14.876／14.945 | 0.690／0.718 |
| 1000 变更文件 | 22.654／22.709 | 3.027／3.072 |
| 200 忽略目录 | 4.546／4.583 | 0.619／0.631 |
| 200 无状态目录 | 14.508／14.705 | 0.645／0.671 |

核心状态变化时预聚合各级目录的最大优先级颜色，无变化不重新构建；忽略规则沿路径祖先做集合查询，不再每行扫描全量集合。同路径 staged 删除 + untracked 仍按原两条记录处理；只保留一份最终装饰，冲突优先级保持原语义。测试 `testFileDecorationsMatchFullScan...` 使用真实重命名／删除／暂存与老扫描 oracle；另补真实 Merge 冲突和结束状态。Red 阶段发现 fixture 所有基础文件内容一样会被 Git 重命名启发式交叉配对，改为每文件内容唯一。随后发现生产级路径问题：`NSString.standardizingPath` 对存在的 `/private/var/...` 根目录解析为 `/var/...`，但不存在的删除叶子会保留 `/private/var/...`，造成字典有删除记录而绝对路径查不到；用 Git 原始根路径优先匹配、仅对别名／需要规范化的路径走已有规范化逻辑，不以文件是否存在改变 Git 状态查询。对应 Red `p4-t3-debugdeleted.log`，Green `p4-t3-deleted-identity-green.log`。基准 XCTest 临时文件从正式测试目录移回忽略的实验区，没有永久新增独立基准类。

## T4：Files 刷新成本与同范围后端替换

沿真实 `ToolPanelView.PanelSyncQueue → Project.syncFiles → FileTreeModel.sync/rebuild/children → WorkspaceBackend.list → TreeDisplayModel.Traversal` 阅读。外层队列合并 UI 更新，内层模型合并重建请求；本地 `list` 已在后台调用，且 `traversal.rows != items` 时才发布。展开／压缩树需要读取可见目录的直接子项（包括判断未展开目录能否压缩），不是无意重复 IO；不合并两层不同职责的队列，也不把逐目录读取改成对隐藏子树的预扫描。

隔离 XCTest `p4-t4-local-experiment.log` 在临时 150 个含 3 文件子目录的根下测量：首次读取 18.350 ms；同根无变化 30 次中位 18.209／p95 19.776／最大 20.060 ms；24 层压缩目录 2.848 ms。其余在同一次实验真实创建、重命名、删除文件并观察文件树跟随，均通过。结果是原生模型扫描的计时，不是完整 App UI，且远端每目录 SSH 往返尚无获准主机测量；无法证明新增批协议具有净收益，因此**没有引入远端预取、mtime 缓存、watcher 或第二套树状态机**。临时基准测试已从正式测试目标移回忽略的实验目录。

真正发现的正确性缺陷是：同路径／scope 换 SSH backend 时，旧 `rebuild` 可以把旧连接的项发布到当前树，且新连接必须排队等待旧连接返回。新增 `PanelContextTests.testFileTreeDoesNotPublishOldChannelAtSameRootAndScope` 在受控暂停旧、新 `list` 时先 Red (`p4-t4-channel-red.log`)，修复在 `FileTreeModel` 所有者中：目标或实际 backend 身份变化时递增单一遍历代次，允许新遍历开始，旧异步调用返回后立即停止，旧完成不能清掉新请求；同目标的事件仍由原来的 `rebuildPending` 合并。`p4-t4-channel-final.log` 验证新树不等旧通道且旧结果晚到不覆盖（Green）；增加同 backend 不同 root 异步切换测试，及真实 symlink 目录／悬空链接／自循环与压缩树正确性。

继续追到用户入口发现：`PanelSyncQueue.run` 无条件等旧 `performSync` 结束，且多次事件只重复运行最初的闭包；即使模型正确，新目录仍可能等待旧 SSH 超时。`p4-t4-panel-queue-red.log` 在旧列表持续等待时切换 panel target，明确 Red（新目标不显示）。改为同一 `PanelContext.Identity` 合并最新动作、不同 identity 立即启动新任务并取消旧等待；旧任务结束不得重置新队列。`p4-t4-panel-queue-green.log` 在旧后端仍阻塞时完成新树并通过；另增加同目标末次事件保留测试。真实文件新增／重命名／删除、临时不可读根目录保持已有行，作为正式 FileTreeTests 回归。

继续核对同路径、同 scope 更换 backend 的真实读写结果，发现另一条错误：旧已加载行和 inline draft 仍留在新连接，`commitDraft` 和 `rename` 只检查 scope/root，相同路径换通道时仍可能对旧 backend 写入或返回伪成功。`p4-t4-channel-operations-red2.log` 9 项中新增两例共 7 个断言 Red；`p4-t4-channel-operations-green.log` 两例及其余 7 项全部 Green。新连接先清除旧行和草稿，已有遍历代次也用于文件动作从元数据读取到真实写入／回传路径的身份校验；同连接临时读取失败仍保留原列表。没有终止用户连接或更改 SSH 协议；受控后端不构成真实远端 E2E。

**最终复核：** `p4-t4-PanelContextTests-final.log` 9/9、`p4-t4-FileTreeTests-final.log` 7/7、`p4-t4-TreeRowHitTestingTests-final.log` 5/5、`p4-t4-RemoteCommandsTests-final.log` 10/10；`p4-t4-verified-full.log` **304 项、0 失败、3 个需专用主机的 SSH 跳过**。`p4-t4-verified-debug.log`、`p4-t4-verified-release.log` 均 BUILD SUCCEEDED，均严格 codesign 验签。补充的 PanelSyncQueue 目标切换先 Red 再 Green，文件草稿／创建／重命名跨 backend 旧目标写入亦先 Red 后 Green。`git diff --check` 无误。

独立签名 Debug 实例使用 `--isolated-ui-test` 启动，PID 35438，窗口 96844；Peekaboo 4.6.0 具有 Accessibility／Screen Recording 权限并读到了文件选择按钮，但后台 AXPress 返回 `INTERACTION_FAILED`、`effect=unverifiable`，重新取树只得到 application-scoped partial semantics，无法确认真实点击或四区域滚动命中，因此**不能声称完整 App 菜单／键盘／滚动 E2E 通过**；其下层真实原生测试与受控功能测试另有证据。用户运行中 `/Applications/Kero.app` PID 18952 未被重启或操作。正式安装将当前签名 Debug App 在同磁盘暂存，验证后整包替换并严格验签，已安装二进制 SHA-256 为 `65cce98d1c311c4e934d20a9303af7f45ea449e21df2dacbf694450a1b5bdefb`，原进程未重启，安装并不等于新代码已在该进程生效。真实 SSH 需获准独立主机；当前不能以受控 actor 代替传输验收。

## 最终验证与未测范围

T1 最终重验：`p4-t1-recheck.log` 的 GitStatusModelTests 16/0，`p4-t1-full-recheck.log` 全量 290 项、0 失败、3 项专用 SSH skipped，`p4-t1-build.log` 和 `p4-t1-release.log` 的 Debug／Release 构建与严格验签均通过。

独立签名 Debug App 使用 `--isolated-ui-test` 启动（PID 55587），确认属于独立进程、主窗存在且没有已开项目；Peekaboo 的窗口匹配只返回部分 AX 语义，精确交互因窗口 receipt 缺失被拒绝，因此**没有声称完成 Git 菜单／键盘 E2E**。没有触及用户当前 `/Applications/Kero.app`（PID 91920）。真实 SSH 仍无本轮获准专用主机，受控后端测试不冒充真实 SSH。
