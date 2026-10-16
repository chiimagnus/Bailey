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

## 最终验证与未测范围

T1 最终重验：`p4-t1-recheck.log` 的 GitStatusModelTests 16/0，`p4-t1-full-recheck.log` 全量 290 项、0 失败、3 项专用 SSH skipped，`p4-t1-build.log` 和 `p4-t1-release.log` 的 Debug／Release 构建与严格验签均通过。

独立签名 Debug App 使用 `--isolated-ui-test` 启动（PID 55587），确认属于独立进程、主窗存在且没有已开项目；Peekaboo 的窗口匹配只返回部分 AX 语义，精确交互因窗口 receipt 缺失被拒绝，因此**没有声称完成 Git 菜单／键盘 E2E**。没有触及用户当前 `/Applications/Kero.app`（PID 91920）。真实 SSH 仍无本轮获准专用主机，受控后端测试不冒充真实 SSH。
