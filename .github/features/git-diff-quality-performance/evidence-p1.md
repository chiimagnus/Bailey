# P1 执行证据

本页记录本次实际执行，不是功能完成声明。
实时状态仍以 `todo.toml` 为准；尚未通过 P1 技术准入，不能进入 P2／P3。

## 环境与保护边界

- 起始 HEAD：`d6eb3574`，分支未切换，起始工作区干净。
- Apple M1 Pro、32 GiB、10 核，内建 3024×1964 Retina 屏幕。
- macOS 27.3 / 26C5035r；Xcode 27.2 / 27B5038j；Swift 6 工程配置不变。
- 全部宿主和 GUI 验证使用 Bailey Dev；正式 Bailey 的原进程保持运行，未安装或重启正式包。
- 用户已明确授权独占 GUI 焦点和现有 Windows SSH 测试；不再需要重复申请同一授权。
- 已发现 `windows` 与 `wincrh` SSH 别名。各自独立连接均超时，
  `/Applications/Tailscale.app/Contents/MacOS/Tailscale status` 返回 `Tailscale is stopped.`。
  未修改 VPN 配置、借用 SSH master、创建远端文件或结束用户进程。

## 原有基线

命令：`make test:NativeDiffTabTests,DiffEngineTests,GitExecutionTests,GitStatusModelTests,GitBrowsingRecoveryTests`。

结果：172 项、1 项授权 SSH 跳过、0 失败，完整命令退出 0。
原始日志位于
`~/Library/Application Support/rtk/tee/1793879876_make_tes_a5e509.log`；
入口日志为 `build/git-diff-p1-baseline-host.log`。
rtk 的压缩输出省略了测量明细；后续通过原生 Make 入口保留完整日志。

| 样本 | Staged 模型中位 / P95 | Unstaged 模型中位 / P95 |
| --- | --- | --- |
| 1k | 83.65 / 101.38 ms | 124.67 / 163.75 ms |
| 24k | 224.82 / 378.04 ms | 282.00 / 424.05 ms |

折叠热视口几何：30 次，中位 6.77 ms、P95 7.07 ms、最差 7.09 ms。
24k 稀疏变化的投影中位 0.172 ms；这不能代表密集行内变化。

## 模型、原生布局和组件像素分测

在原基线测试内挂载真实 `DiffNativeSurface`，记录模型就绪、原生布局结束、
`cacheDisplay` 组件绘制结束三个累计时间，并核对实际源文件字节。
布局和绘制分别使用生产字号与语法插件。
这些是宿主组件数据，不等于 WindowServer 首帧或完整 App 的可输入时间。

日志：`build/git-diff-p1-layout-experiment.log`，对应首次扩展的计时测试。

| 样本／来源 | 模型中位 / P95 | 布局完成中位 / P95 | 组件像素中位 / P95 |
| --- | --- | --- | --- |
| 1k Staged | 91.08 / 132.22 | 96.30 / 137.29 | 100.11 / 142.81 ms |
| 1k Unstaged | 132.58 / 138.99 | 153.48 / 163.23 | 185.59 / 197.30 ms |
| 24k Staged | 231.32 / 250.95 | 236.60 / 256.00 | 240.12 / 259.54 ms |
| 24k Unstaged | 373.89 / 416.51 | 767.10 / 809.56 | 1495.57 / 1545.12 ms |

每组 30 次。此轮尚未单列第一次标签加载，随后测试已改为先报告进程内首次标签、
再做 30 次热测；后续日志不能与本表未经说明直接混用。

当前 HEAD `7874801e` 的完整 `make test` 实际执行 854 项、16 项 SSH 跳过、
0 失败，耗时 918.8 s，Make／Xcode 均退出 0；
日志 `build/git-diff-p1-current-head-full-host.log`，不是仅构建或部分列表。
该轮同机重新跑 30 次热测，以下均为 **Debug / 累计毫秒中位数／P95**：

| 样本／来源 | 模型 | TextKit 布局完成 | 原生组件绘制完成 |
| --- | ---: | ---: | ---: |
| 1k Staged | 86.0 / 106.3 | 91.1 / 111.5 | 94.5 / 115.1 |
| 1k Unstaged | 125.2 / 132.1 | 145.3 / 151.8 | 176.5 / 183.6 |
| 24k Staged | 233.5 / 252.3 | 238.4 / 257.2 | 242.0 / 260.7 |
| 24k Unstaged | 370.0 / 394.5 | 758.0 / 779.1 | 1474.8 / 1494.2 |

进程内首次标签 24k Staged 模型／布局／组件像素分别为
158.4／162.7／166.6 ms，Unstaged 为 270.3／658.9／1385.5 ms；
首次标签不是新的冷 App 进程，不能当冷开全链路。
本轮 100k Swift 文首／中／末输入 P95 为 435.4／291.2／140.8 ms；
24k 有 101 处折叠的热视口几何 P95 为 6.71 ms。
独立 RSS 轮询 `build/git-diff-p1-current-head-host-rss.csv` 仅取得连续 585 个样本，
已捕获峰值 4,994,720 KiB；采样随后因 MCP 会话中断提前停止，
不能称为全量测试 918 秒的完整最大峰值，更不是单个 Diff 的独占 heap。

**Release 独立基线（当前 HEAD）：** 首次使用环境变量 `ENABLE_TESTABILITY=YES`
启动 `make test CONFIGURATION=Release` 未生成可导入的可测试模块，
预检在测试方法执行前失败；按 `docs/testing.md` 将
`ENABLE_TESTABILITY=YES` 显式传给本次 Make 入口的 Xcode 构建设置后，
真正枚举 1 项，执行 `testLocalGitStagedAndUnstagedDiffReadyLatencyMatrix`
通过，Make 退出 0，正式 Release 产品配置未改。
日志：`build/git-diff-p1-release-ready-latency-explicit-testability.log`。
同机 30 次热测，以下均为 **Release / 累计毫秒中位数／P95**：

| 样本／来源 | 模型 | TextKit 布局完成 | 原生组件绘制完成 |
| --- | ---: | ---: | ---: |
| 1k Staged | 82.9 / 86.5 | 88.1 / 91.2 | 91.6 / 94.5 |
| 1k Unstaged | 122.5 / 126.2 | 134.7 / 139.0 | 152.1 / 156.6 |
| 24k Staged | 174.5 / 186.4 | 179.4 / 191.1 | 182.9 / 194.7 |
| 24k Unstaged | 247.1 / 297.2 | 430.4 / 501.9 | 772.2 / 881.1 |

进程内首个 24k Staged 标签模型／布局／像素 97.6／101.8／105.9 ms，
Unstaged 148.9／330.2／667.8 ms。虽然 Release 快于 Debug，
Unstaged 原生布局和组件绘制仍主导等待；本表不等于 WindowServer 首帧。

**Git 状态入口独立规模实验（本机真实 Git）：**
临时仓库 1／100／10,000 个未跟踪文件，真实 `GitStatusModel.sync(root:)`
后分别观察 `hasResolvedStatus + changedEntries.count`（Core 可见）、
`!isRefreshing`（详情完成），再从磁盘新增一个文件，
等待 FSEvents 自动更新实际 Changes 集合。
`build/git-diff-p1-status-count-and-fsevents-feasibility.log`：

| 未跟踪文件数 | Core 可见 | 详情完成 | FSEvents 新增到 Changes 可见 |
| --- | ---: | ---: | ---: |
| 1 | 88.3 ms | 243.4 ms | 748.0 ms |
| 100 | 66.7 ms | 243.8 ms | 749.2 ms |
| 10,000 | 120.7 ms | 408.8 ms | 1031.7 ms |

三个规模都精确显示全部文件，新增后变为 2／101／10,001；
无 Git 错误、真实新增文件原始字节保持，临时仓库回收。
此为每种规模**单次**宿主模型路径，不等于 GUI Changes 像素，
不把一次外部事件当 P95，必要的 30 次热态与像素分测仍归 P1-T1。

**真实 WindowServer 像素样本（非宿主组件像素）：**
使用只包含测试文件的 24k 行 Git 临时仓库，隔离 `Bailey Dev`
实际点击 Git Changes 行；Peekaboo `capture action --mode window`
对目标 PID 43536、窗口 11711 记录前／后帧、操作起点和保留原始截图。
先从空白编辑区域打开 Unstaged：操作起点相对采集为 310 ms，
首次有 Diff 加载骨架的帧为 765 ms、首次完整正文帧为 1663 ms；
即已采样到的上界分别为点击后 455 ms、1353 ms。
再从 Unstaged 内容点击 Staged：操作起点 313 ms，
骨架帧 934 ms，首次完整正文帧 1445 ms；
上界分别为 621 ms、1132 ms。
分别保存于 `build/git-diff-p1-pixels-unstaged-window-capture/` 和
`build/git-diff-p1-pixels-staged-window-capture/` 的 `action.json`、
`metadata.json`、`contact.png` 和 `keep-*.png`。
两次捕获的帧率实际只有 4.34／3.99 fps 且出现 `lowFps` 警告；
**它们是初次点击后观察到完整绘制的时间上界，不是精确首次像素或 P95**。
它们确认真实完整窗口绘制明显慢于宿主“模型可用”。
原始单次样本无法形成用户可见 P95；同机补充的 61 次来源正确的冷会话中，
有 3 次与另一轮构建／测试重叠，不能计作独占性能样本。
下面分别记录真正的有效样本和采样误差，不将上界冒充精确首帧或输入就绪。

**真实窗口独立冷 Dev 会话完整补测（2026-11-06）：**
每次以新进程启动隔离 `Bailey Dev` 和同一 24k 行一次性 Git 仓库，
先进入 Git，再点击 Changes 中 Staged 或 Unstaged 的 `latency.swift`。
使用 Peekaboo `capture action --no-remote --capture-engine cg` 的
原始帧时间戳，分别以真实 AX `bailey.diff.readonly-new`／
`bailey.diff.worktree` 确认最终打开的来源。
后两轮采集使用明确的进程 PID，测试期间排斥共用 Dev 构建锁，
并固定／检查每轮 App 二进制指纹；四轮的来源正确样本为 8、15、4、34。
经 `evidence-p1-status-events.md` 的实际命令启动时刻交叉核对，
其中第二轮 `sample-01` 至 `sample-03` 与构建／测试重叠。
剔除后旧组有 **58 次独占采样，Staged／Unstaged 各 29 次**：

| 来源 | 有效样本 | 首次完整正文采样帧上界中位数 | P95 上界 | 最差上界 | P95 前一帧下界 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Staged | 29 | 721 ms | 821 ms | 824 ms | 670 ms |
| Unstaged | 29 | 1544 ms | 1640 ms | 1647 ms | 1502 ms |

**本轮独立补测（当前 Dev 二进制指纹 `7a1ded05...`）：**
按原样重建 24,000 行 `let rowN = N` 文件、Git Index 第 100 行改动、
Worktree 第 12,000 行改动；磁盘基线／Index／Worktree 分别为
481780／481779／481776 UTF-8 字节，Worktree 的 AX 字节长度与旧组一致。
用仅限 Bailey Dev 的布局偏好临时选择 Split，并在测试结束后明确恢复
测试前的 `unified`；正式 Bailey 偏好没有修改。
首段 4 次脚本本身输出 `COMPLETED=4`，但其外层 zsh 包装命令误用只读
`status` 变量，最终退出 1；保留四行原始 CSV，不把外层命令误写成退出 0。
随后同一二进制、同一夹具的 60 次任务在第 28 次遇到 Peekaboo 报错：
`Window not found: live capture window changed identity before frame capture`。
点击在派发前被拒绝；不作为性能或产品失败，不盲目重试。
两段实际得到 **Staged 16 次、Unstaged 15 次**，同二进制指纹一致：

| 来源 | 有效样本 | 上界中位数 | P95 上界 | 最差上界 | P95 前一帧下界 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Staged | 16 | 758 ms | 873 ms | 873 ms | 732 ms |
| Unstaged | 15 | 1549 ms | 1760 ms | 1760 ms | 1609 ms |

另外 6 次默认 Unified 夹具（各来源 3 次，来源／截图正确）
由于布局、正文变更位置不同，不混入以上 Split 数值。
旧、新 Split 组的二进制指纹也不同，尽管生产源码未修改，
不将两个组强行合并伪造单二进制 30 次 P95。
当前需要每个 Split 来源再各补至少 14／15 次独占有效采样。

采样帧率实际约 4.64–6.99 FPS（新组约 6.04–6.91 FPS），
以首帧 PNG 与当前帧的正文大小变化确定首次完整 Diff 采样帧；
已人工核查 Staged 与 Unstaged 代表样本的前一帧确实仅为加载骨架，
后一帧真实显示修改代码、正确折叠标记及行号。
因此旧组 P95 的**可观察采样区间**分别约为 670–821 ms、
1502–1640 ms，新组分别约为 732–873 ms、1609–1760 ms，
而不是毫秒精确的真实首帧时间；新组样本不足计划的每来源 30 次。
未暂存 Diff 的显示时间明显高于已暂存，并且在不同冷会话中稳定复现；
这不是 `DiffTab` 模型或宿主像素就绪时间，
也不证明真实键盘可输入或最终语法色稳定。

有一次第 16 次启动仅通过 AX 取得菜单栏
（`semantic_scope=application_partial`，无 `snapshot_id` 和 Dock），
窗口仍在清单；该次**无效样本已排除**，
同期存在独立 Dev XCTest，是否是竞争造成仍未证实，
不得据此判定产品必然发生启动故障。
所有有效会话逐次核对了来源，异常没有被伪造为慢样本或正常通过。

原始旧组结果 `build/git-diff-p1-30gui-cold-{1793936787,1793936862,1793937267,1793937336}/results.csv`；
新组 Split 为 `1793946373`／`1793946471`，Unified 为 `1793946148`，
均具有单独的 `results.csv` 与 `capture/` 原始窗口 PNG。
第 28 次拒绝的回执在 `1793946471/sample-28/capture-output.txt`。
每个目录含实际 `action.json`、`metadata.json` 及可核对的完整结果。
第 16 次无效记录见第二轮 `sample-16/home-ax.json`。
测量脚本位于忽略的 `build/git-diff-p1-30gui-cold-bench.sh`，
未变更生产代码或正式 Bailey。
仍需以更高帧率补全精确首次像素／可输入时点、
独立 GUI 多标签内存、关闭后资源及特殊文本组合；
不得把本次 P95 采样上界当作产品性能达标。
P1-T1 仍在进行中，尤其缺少高帧率 WindowServer 首像素／可输入分时。

**十万行 Debug／Release 独立热态补测：**
在 100k 行真实 Swift Git 临时仓库按 Staged／Unstaged 各做 30 次，
原生组件像素累计中位数分别为 Debug 440／5393 ms、
Release 171／2502 ms；两种构建均实际执行 1 项、0 失败、退出 0。
原始每组中位／P95／最差、字节条件和一次性测试源码保存位置详见
`evidence-p1-100k-hot.md`；本实验不是 WindowServer 首像素。

## 原生输入与 Undo 的真实副作用

日志：`build/git-diff-p1-native-input-io.log`。
`testNativeDiffInputCostsAndUndoByteIntegrityMatrix` 直接使用生产 `DiffNativeSurface`
回调，1k／24k／100k 行、txt／Swift、文首／中／末，每组 30 次输入与 Undo。
每次 Undo 核对脏标记及完整 UTF-8 字节；最后插入中文、通过 `DiffTab.save()` 写盘，
核对磁盘字节并确认未跟踪文件没有被擅自加入 Index。
该矩阵未开启折叠，不冒充折叠输入、系统 IME 候选或完整 App 键盘 E2E。

| 文本 | 文首 P95 | 文中 P95 | 文末 P95 |
| --- | --- | --- | --- |
| 24k txt | 85.67 | 60.11 | 33.44 ms |
| 100k txt | 428.22 | 285.30 | 139.17 ms |
| 100k Swift | 469.24 | 302.77 | 140.57 ms |

**Release 100k 输入与原始字节矩阵复测：**
`build/git-diff-p1-release-input-100k.log` 通过现有 Make 入口，
仅本次测试构建使用 `ENABLE_TESTABILITY=YES`；实际枚举 1 项、
执行 148.883 秒、0 失败，完整 Make 退出 0。
100k txt 文首／中／末输入 P95 = 446.6／263.0／47.9 ms，
100k Swift = 468.4／256.3／71.7 ms。
各位置各 30 次原生 TextKit 编辑与 Undo，最后中文插入及磁盘 UTF-8
字节／Index 结果由该用例共同核验。
纯粹 `textView.string` getter P95 约 0.003–0.010 ms；
文末完整 UTF-8 比较 P95 约 46.3 ms。
即使 Release，编辑成本仍远高于 100k 行 32 ms 的目标，
不能指望只移除 String getter 就解决原生布局维护与大规模扫描。

`textView.string` getter 本身约 0.002–0.007 ms；不能将其描述为已证明的大块复制。
100k 行文末的整串 UTF-8 比较中位约 136 ms，独立构成热点。

同轮附加 Time Profiler：
`build/git-diff-p1-input-time-profiler.trace`，12 秒，仅附着本次测试宿主。
导出：`build/git-diff-p1-input-samples.xml`。
主线程 12325 个采样中，8399 个包含 `NSTextContentStorage processEditingForTextStorage`，
7697 个包含 `updateRangesForTextElement`，1797 个包含 `DiffTab.updateEditedContent`，
1676 个包含 `Sequence.elementsEqual`。调用链采样有重叠，不能相加当总占比。
采样含测试中的 Undo 和字节断言，不作为纯输入 P95 的替代。

**实现约束：** `NativeTextLineIndex` 已使用 Fenwick 索引，同长度行替换为局部更新；
不能凭文首较慢就错误改成另一套行索引。
P2 必须同时核实全篇 TextKit 布局造成的段落缓存维护与全文脏比较，
仅删一个 String getter 不能恢复输入预算。

新增真实事件契约测试见提交 `fe777a29`，日志
`build/git-diff-p1-events-cancel-focus.log`。
普通插入／粘贴／删除／全选替换各 1 次前置和 1 次字符回调；
组合输入前向有 3 次字符回调；多选区和程序追加没有单范围前置回调。
全部 Undo／Redo 都没有该前置回调，多选区撤销／重做各有 2 次字符回调。
7 种输入及其 Undo／Redo 共 21 个阶段逐次用真实 editedRange 重建并核对 UTF-8 字节。
因此不能只依赖 `shouldChangeTextIn`，也不能假定一条用户动作总是一次通知。

提交 `65152f3d` 追加折叠正文的八种命令矩阵：可见插入／粘贴／删除／组合输入、
显式跨折叠替换、显式隐藏匹配范围替换、全选替换与多选区。
每组均先证明隐藏／可见 Git 行和实际窗口挂载成立，再核对完整缓冲、领域正文、
Undo／Redo、保存后磁盘字节与未变化的 Git Index。
与相邻折叠偏移、手动展开、点击及全部组合输入测试共 15 项通过，命令退出 0；
日志为 `build/git-diff-p1-folded-native-commands-green.log`。
对照使用未折叠的文件编辑组件；多选区另有独立的两处替换字节断言。
最初使用普通 `NSTextView` 作多选区对照失败：它只改主选区，
而 Bailey 的共享编辑器明确一次修改全部选区，不能把这项夹具契约差异当产品缺陷。
原失败保留在 `build/git-diff-p1-folded-native-commands.log`。
显式全文命令操作完整原文，不是只改可见投影；
直接设置匹配范围不证明 Find UI、Shift 扩选或跨折叠拖选已通过。

**完整 Dev App 补充实测（2026-11-06，Peekaboo，非 XCTest）：**
以 `--isolated-ui-test`、隔离 HOME 和临时 Git 仓库启动 `Bailey Dev`；
临时 `scroll.swift` 24,000 行、492,902 字节，三处修改在第 100／12000／23990 行。
新标签在真实 900×600 窗口初次稳定观察到 4 个折叠（97／11893／11983／6 行），
原生 AX TextArea 为 `bailey.diff.worktree`；首次屏幕像素显示三处修改。
单击第二个折叠控件后展开对应 11,893 行，未删除磁盘内容；
随后在普通文字区单击，并未观察到其余折叠被自动展开。
该证据不能证明未捕获的初次过渡帧、所有跨隐藏边界输入或完整自动化。
相关截图／AX JSON 留在 `build/git-diff-p1-manual-*`（仅本机测试产物）。

**Find 路由 Red→Green（2026-11-06）：** 旧源码的
`WorkspaceWindowModel.performFindAction` 忽略 `.diff`，`canFind/canReplace`
仍假定 Diff 只读。原隔离 Dev App 的 `⌘F` 无界面是实测 Red。
现以窗口级菜单目标转发给 `DiffNativeSurface` 的当前可见 TextKit pane，
复用 `FileTab` 已有 `NSTextFinder` 动作。
Read-only Staged／历史允许查找但不允许替换；Split 查找跟踪真正获取焦点的列，
在 Find 字段有焦点时保留命令目标，Replace 回到有写入权限的工作区正文。
现有隐藏 pane 时关闭 Find 的路径保留。

`build/git-diff-p1-find-routing-targeted.log`：新增真实 Git + AppKit 宿主测试
`testWindowFindCommandsTargetNativeWritableAndStagedDiffPanes` 通过（1.432 s），
覆盖 Worktree、Staged、历史原文、Split 两列焦点、Unified 恢复、只读拒绝替换和
最终 Worktree 磁盘字节。扩展宿主回归
`build/git-diff-p1-find-routing-regressions.log` 执行 166 项、1 项 SSH 跳过、
0 失败，Make 退出 0。`make build:ui` 成功，
日志 `build/git-diff-p1-find-ui-build.log`。

完整 UI XCTest `make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testWorktreeDiffEditsAndPersistsRealGitFile`
仍在 `XCUIDevice.enableAutomationMode` 阶段无法初始化，选中 0 项、退出 2，
日志 `build/git-diff-p1-find-ui-e2e.log`；不计为 GUI XCTest 通过。
此失败现已通过重新建立正确的 XCTest Runner 会话解除，不能倒填先前结果。
`build/git-diff-p1-genuine-gui-e2e-retry.log`：同一用例独立真实执行 1 项，
25.640 s，通过，Make 退出 0。
`build/git-diff-p1-all-workspace-git-ui-e2e.log`：完整 `WorkspaceGitUITests`
实际枚举／执行 7 项，6 通过、1 项 Windows SSH 因缺少实际可用连接跳过、
0 失败，完整 Make 退出 0，103.442 s。
覆盖 Git Changes 所属仓库、clean filter 与原字节、CRLF 仅真实修改、
595 行附近显示、Split/Unified、主题重绘、Worktree 真实编辑保存，
并包含本次新增的真实 `⌘F` Find Bar 断言。
授权 SSH 主机 `windows` (100.101.55.94) 和 `wincrh` (192.168.137.1)
在禁用 SSH master、批量认证及 5 s 超时下再次均不可达；Mac Tailscale 处于停止状态，
未修改网络配置。这项真实 SSH GUI 尚未通过，归 P4-T3。
**纠正前次 GUI 归因：** `build/git-diff-p1-find-manual-*.json`
中的 `⌘F`／`⌘⌥F` 命令实际作用于 AX `bailey.tab.file`（Files 原生文本），
**不能**证明 Git Diff 的真实菜单快捷键。原记录将其误写成 Diff GUI 通过，予以撤回；
宿主 `NativeDiffTabTests` 通过的独立结论不受影响。

重新在一次性 Git 仓库的隔离 Bailey Dev 中先点击 `bailey.dock.git`，
再点击 Changes 行 `inspect.swift`；AX 同时出现
`bailey.diff.baseline` 与 `bailey.diff.worktree`，900×600 真实窗口显示 Split 的
`11,997／11,983／6 unmodified lines` 折叠带。
对 Split 右侧正文使用窗口 `⌘F` 后，截图确实出现位于右侧的原生 Find Bar；
AX 查找字段可读到查询值；通过针对字段的 AX `set-value` 输入
`marker5000`（处在未展开折叠区间）和 `marker12000`（当前可见变化处），
都显示 1 个匹配。随后真实 Diff 内按 `⌘⌥F`，右侧出现原生 Replace 输入；
未执行替换，编辑缓冲及磁盘均仍为 553,774 字节，Git 仍只有预计的两行变更。
`⌘G` 之后折叠标记数量未变化，当前截图未显示隐藏匹配被展开，
不将「查询返回匹配」冒充「隐藏匹配已在视口可见」。
真实 Diff Find 的可达性得到补验，仍须完成匹配可见性、跨隐藏区选取与 Replace 的
端到端断言和 UI XCTest。
原生回执保存在 `build/git-diff-p1-hidden-find-actual-*`；
Peekaboo 的 `type --clear --window-id` 曾误把测试工作区编辑器当作输入目标，
但测试隔离正文经原生 Undo 恢复（缓冲及磁盘均为 553,774 字节）；
后续必须优先按 AX 字段 ID 定位并核对结果，不能凭动作派发判断焦点。

## 全量回归中的语法资源释放

2026-11-06 原工作树全量 `make test`：852 项，16 项 SSH 跳过、
`NativeSyntaxHighlightingTests.testClosingEmbeddedEditorReleasesPendingHighlightRequests`
因 5 秒资源释放等待超时而失败，完整 Make 退出 2；
日志 `build/git-diff-p1-final-test.log`。
同一故障单方法和整个 Syntax 测试类此前独立通过，
说明不能凭定点绿灯证明全量环境没有跨任务生命周期问题。

源码 `SyntaxHighlightCoordinator.installTokenProvider` 在等待嵌入查询前
提前强持有 `self` 和 `textContentManager`，引入多余跨 `await` 的对象生命周期。
提交 `9840afc1` 将两个 query 都等待完成后才提升弱引用，
不改变颜色数据和缓存语义。
`make test:NativeSyntaxHighlightingTests,NativePaneRetentionIntegrationTests,HighlightQueryCacheTests`
49 项全绿、退出 0，日志 `build/git-diff-p1-lifetime-owner-green.log`。
在该修复提交与输出预算回归均进入工作树之后，
执行 `make build`、`make build:release` 与完整 `make test`，
三者退出均为 0；完整 853 项、16 项 SSH 跳过、0 失败，
此前超时的资源释放用例通过（3.482 s），
见 `build/git-diff-p1-after-lifetime-{debug,release,host}.log`。
附加 RSS 采样为宿主整个测试进程峰值约 4.91 GiB，
不能当作单个 Diff 标签的 retained heap 或内存泄漏证据。

## Git 对象读取

`testGitObjectReadPhaseLatencyAndBatchCompleteness` 对 1k／24k 各做 30 次。
每次核对真实 blob 字节、声明大小、batch OID／类型／大小头和终结 LF，
最后再次核对磁盘原文。

| 样本 | metadata 中位 / P95 | size 中位 / P95 | blob 中位 / P95 | 单次 batch 中位 / P95 |
| --- | --- | --- | --- | --- |
| 1k | 22.43 / 24.34 | 23.06 / 28.48 | 22.83 / 25.47 | 18.19 / 20.17 ms |
| 24k | 22.23 / 23.77 | 22.62 / 24.05 | 23.07 / 24.81 | 18.21 / 20.35 ms |

最新同机交叉复测 `build/git-diff-p1-output-budget-green.log`（30 次／样本）：
1k 行的 metadata／size／blob／batch 中位分别为
21.23／22.06／22.38／17.01 ms，
24k 行分别为 22.91／23.00／24.06／19.28 ms，
对应 24k P95 为 25.51／26.48／26.26／21.28 ms。
串行 size+blob 的中位合计约 47 ms，一次性 batch 约 19 ms；
metadata 保留，故这个实验只支持将**锁定 OID 后**的两次调用合并，
不支持跳过索引元数据校验或引入驻留 Git 子进程。
本机对照未验证 SSH 实际吞吐、stderr 峰值或多文件拥塞。

batch 是一次性 Git 原生命令，不是常驻服务。
实验首次将非绝对 `git` 直接传给本机后端而失败；核对 `runSync` 的 executable 契约后，
修正为 `/usr/bin/env git`，复测通过。原失败保留在 `build/git-diff-p1-io-dense.log`。

新增 `testInterleavedStagedMetadataCanDescribeNoCoherentGitSnapshot`，
单独提交 `b2d63928`，日志 `build/git-diff-p1-staged-metadata-targeted.log`。
受控仓库的两个 HEAD/Index 状态各自 `git diff --cached --quiet` 均为干净；
在第一次 `ls-tree HEAD` 和第二次 `ls-files --stage` 之间切换 HEAD，
两个分别能完整读取的 Blob 却形成了虚假的 Staged 修改。
这直接证明两条独立元数据请求不能保证同一次 Git 快照，
但不是生产 `DiffTab.reload` 竞态已修复；P3 须在快照所有者处理。
`GitExecutionTests` 7 项全绿，完整命令退出 0。

**P3-T1 路线：** 保留字面路径 metadata 选择和锁定 OID；
可在此后用一次性 `cat-file --batch` 合并 size／blob 两次启动，
但实施前还需完整测试缺失对象、非 blob、短读、超预算、异常退出及取消。
本机收益不能替代 Windows SSH 的往返和输出预算证明。

## 密集行内投影

日志：`build/git-diff-p1-io-dense.log`。
输入是每行 399／400／401 个互不相同的标点 token；
1／100／1000 对完全替换，构造已验证行操作排除行级算法噪声。
断言 Unified、Split 的实际增删行数和无意义词级强调为空。

| token 数 | 1 对 | 100 对 | 1000 对 |
| --- | --- | --- | --- |
| 399 | 38.05 | 3673.01 | 36875.78 ms |
| 400 | 36.90 | 3703.08 | 36957.68 ms |
| 401 | 0.18 | 16.00 | 159.50 ms |

补测共享词元与精确强调：提交 `4355a70b`，
日志 `build/git-diff-p1-shared-tokens-targeted.log`。
399／400／401 token 各配 1／10／100 对；
前半行完全替换、后半行完全相同，核对 Unified 和 Split 两侧相同的 UTF-16 强调范围，
401 token 按现有上限不生成词级强调。
100 对在 Debug 中分别耗时约 1591／1642／16 ms；
说明不仅全量替换，即使含共享词元仍在上限边缘出现数量级跃变。
`DiffEngineTests` 23 项全绿，完整命令退出 0。

同机最新复测 `build/git-diff-p1-dense-projection-rss-test.log`：
`make test ONLY_TESTING=BaileyTests/DiffEngineTests/testDenseIntralineProjectionTokenBoundaryCosts`
实际执行 1 项、0 失败、Make 退出 0；399／400／401 tokens、1／100／1000 对都核对
Unified／Split 的行数与无噪声词级强调。
其中 1000 对的耗时分别为 37,326／38,171／164 ms。
并发每 100 ms 采集测试宿主进程 RSS（464 个样本），峰值 181,680 KiB；
这是整个宿主的驻留内存而不是 Myers trace 的独占堆分配，
也未区分 `DiffComputation.build` 与 AppKit 运行时的 retained heap。
样本存于 `build/git-diff-p1-dense-projection-rss.csv`；
独占分配需在 P3-T3 的可取消生产路径中补归因。

**结论：** 400-token 上限内的 Myers trace 是真实热点，不是推测；
不能用 0.172 ms 稀疏样本豁免 P3-T3。
提交 `644d2aa9` 经生产 `runBackgroundDiffWork` 建立进入前提后取消，
100 对、400 token 仍等待约 3709 ms 才真正结束；返回结果为 nil，未发布过期结果。
该测试为基线，不表示取消时延达标。
含共享 token 的密集替换、重复展开和分配峰值仍待补测。

**远端输出上限反例：** `9111b61a`、
`build/git-diff-p1-output-budget-green.log`，
`GitExecutionTests` 8 项通过、Make 退出 0。
现有 WorkspaceBackend 测试夹具提供 8 MiB 标准输出和 1 MiB 标准错误，
`GitCommandExecution.runData(stdoutLimit: 1024, backend:)` 返回的 stdout 虽为 1 KiB，
但直到后台已经接收完整 8 MiB 才截断，stderr 1 MiB 仍完整物化。
这是受控后端替身对调用边界的实证，不等于已测到 SSH 真实网络字节；
P3-T1 必须让输出预算下沉到后端实际传输和读取层，
同时在本地／SSH、失败和取消条件下验证。

本机真实 Git 超预算补测（`build/git-diff-p1-local-output-limits-confirmed.log`）：
在隔离临时仓库执行真实 `git cat-file blob` 读取 8 MiB 对象，
`stdoutLimit=0` 和 `1024` 均返回 Git 成功状态 `0`，但保留输出仅有 0／1024 字节；
本机 `stdoutLimit=1024` 下写入 1 MiB stderr 的失败 Git 命令返回状态 `7`，
stderr 仍完整保留 1,048,576 字节。对照既有远端假后端 8 MiB stdout、1 MiB stderr，
`GitExecutionTests` 10 项、0 失败、完整 Make 退出 0。
因此返回前缀和 `status==0` **不能**共同证明 Blob／patch 内容完整，
远端还存在全部接收后截断的传输／峰值内存缺口。
本实验新增的两个测试是对当前错误行为的断言，不适合作为修复后永久回归；
实验结果已保存，原型在本次 P1 验证后撤回，P3-T1 必须针对
`超限→明确错误／停止接收→不发布不完整结果` 另写 Red→Green 测试。
先前两次新测试卡在 `XCTestDriver._prepareTestConfigurationAndIDESession`
（尚未运行任何测试方法），与 8 MiB 内容无关；本次重新运行已实际枚举并执行 10 项。

## 离散语法可见范围查询

提交 `af89df2d`：`testDisjointVisibleSyntaxQueryCostAndReuse`。
日志 `build/git-diff-p1-visible-query-final.log`；
24k 行 Swift 源码（793780 UTF-8 字节），1／10／100／1000 个非相邻可见区间。
缓存树解析仅一次，范围扩展后保留相同首行捕获；单项测试通过、退出 0。

| 条件 | 时间 |
| --- | ---: |
| 冷解析并查询首区间 | 290 ms |
| 独立同字节全文比较中位（17 次） | 36.47 ms |
| 热查询 1／10／100／1000 区间 | 36.69／37.13／42.23／94.99 ms |

单区间热查询几乎全部由 `DiffSyntaxSource.captures` 的
`cachedText?.utf8.elementsEqual(text.utf8)` 全文字节比较解释；
扩展到千区间还产生约 58 ms 的附加游标／捕获处理。
不能把一次解析树缓存命中误判为无成本的增量着色，
P3-T4 需要在同一文本版本下避免全文重复校验并保留字节一致性。

## TextKit 原型的证据边界

局部原型比较全文原生参考与 viewport-only、tail-range、relocate、
relocate+adjust、自定义 fragment frame 五条路线。
输入包含 LF、CRLF、裸 CR、U+0085、U+2028、U+2029；不改生产布局。
原型补丁：`build/git-diff-p1-native-before-cleanup.patch`。
原始日志：`build/git-diff-p1-layout-experiment.log`、
`build/git-diff-p1-native-input-io.log`、`build/git-diff-p1-fixed-fragment-retry.log`。

初版参考遗漏了滚动后 `layoutViewport()`，且比较包含视口外的终端虚拟空行；
已发现并修正，原始 `reachable` 列不得不加区别地作为尾行失败的验收证据。
后续改为多处修改和视口内真实 Git 行，再核对坐标。
自定义 LF fragment 坐标不适用于 CR／Unicode 原生段落；原型不进入产品。
新增 17 次跳转的原生反证实验（未提交测试代码，失败日志保留）：
`build/git-diff-p1-17jump-lazy-native-prototype.log`、
`build/git-diff-p1-17jump-range-layout-prototype.log`、
`build/git-diff-p1-17jump-style-pinned-prototype.log`。
24k 行纯 LF、固定字体和准确计算的全文高度下，
仅调用 `relocateViewport`／`layoutViewport`／`adjustViewport`，
即使只对目标段落调用 `ensureLayout(for: nativeRange)`，
17 次近远交错跳转中仍有 31 处坐标／可见性断言失败：
中部位置返回状态 `NSTextLayoutFragment.State.none` 且 `y=0`，
末行的已计算 `y≈415299` 与预期 `359985` 相差约 55k 点，
不能作为真实命中或滚动条几何。
单次操作中位约 110 ms，最差约 152 ms；
失败在准确性而不只是延迟。测试本身已从常规测试源移除，
生产 `ensureLayout(documentRange)` 保持不动。

Apple DTS 对同一类 TextKit 2 问题的官方解释也确认：
未完成布局时 `NSTextLayoutFragment` 的位置是动态估算值；
只确保目标段落布局、再调整 viewport 可以让目标文字可见，
但若滚动条要求**整篇真实最终高度**，没有先完成全篇布局的原生捷径。
见 [Apple Developer Forums：How can we performantly scroll to a target location using TextKit 2?](https://developer.apple.com/forums/thread/761364)，
DTS 2024-08 回答及评论末段。此为 TextKit 默认几何契约，
不能简单用估算值替代本产品的完整真实滚动范围；
仍可研究由同一布局所有者使用严格来源索引给出真实高度、
但必须在原生片段位置／焦点／折叠／变高段落上验证。

2026-11-06 原生样式控制反证：24,000 行全部字符明确写入 `.font` 和
`.paragraphStyle`，文首／中／末的 `minimumLineHeight` 与
`maximumLineHeight` 均为 15 pt。
不执行全文布局时 `usageBoundsForTextContainer.maxY` 仍估算为
481,215 pt，按行高的完整真实内容高度应为 360,000 pt。
`NSTextView.scrollRangeToVisible` 在 17 次远近交替跳转中，
4/17 次全局坐标准确、14/17 次片段落在视口，最后三次靠近末尾的片段不可见；
预先局部调用 `ensureLayout(for: NSTextRange)` 无改善。
`NSTextLayoutManager.layoutQueue` 的后台队列空闲等待 2 秒后，
同样只有 4/17 次坐标准确、4/17 次片段可见。
这些结果不能把“队列任务结束”或“位置接近”冒充完整文档几何正确。
证据：`build/git-diff-p1-scroll-native-style-diagnostic.log`、
`build/git-diff-p1-native-scrollrangetovisible-17jump-styled.log`、
`build/git-diff-p1-textkit-layoutqueue-17jump-idle2s.log`。
一次性原型源码留在 `build/git-diff-p1-native-navigation-experiment-source.swift`
和 `build/git-diff-p1-feasibility-experiment.swift`；失败实验已从正常测试集合移除。

**P1-T2 决策：对现有默认 TextKit viewport、单段布局和 layoutQueue 快路径 No-Go。**
固定正确的滚动高度与 TextKit 尚未布局片段的估算坐标缺少共同几何所有者。
P2-T1 需先在单一布局所有者验证 17 次深跳与真实尾行，再接生产并删除旧路径；
未经 Red→Green 不得移除 `ensureLayout(documentRange)`，更不能引入后台补齐或双份可写文本。
本反证不能证明所有原生布局方案均不可行，也不能算产品已修复。
Apple 的 WWDC21 TextKit 2 说明，视口外的位置可能仍是估计值，
原生非连续布局仅保证已布局视口片段；
2026 年的 WWDC 讲解了扩展 `NSTextView` 的 viewport delegate，
但它针对新的 2027 系统能力，不能未经最低 macOS 15.6 API 校验便作为通用方案。
参考：https://developer.apple.com/videos/play/wwdc2021/10061/ 和
https://developer.apple.com/videos/play/wwdc2026/370/ 。

**最新原生重定位消融与大规模反证（2026-11-06）：**
真实固定 15 pt 行高、24k 纯 LF、17 个远近交错目标，
在同一 `NSTextView` 上分别试验直接滚动、仅目标局部布局、
`relocateViewport`、其前后组合与缺少物理滚动。
每次核验原生片段的 **真实行文本**、`layoutAvailable` 状态、
片段 Y 坐标、ClipView 可见性、滚动条比例及全文 UTF-8 字节：

| 方案 | 坐标准确 / 17 | 可见 / 17 | 重定位 P95／最慢 |
| --- | ---: | ---: | ---: |
| 仅 NSClipView 滚动 | 4 | 4 | 不适用 |
| 局部目标 ensureLayout + 滚动 | 4 | 4 | 不适用 |
| NSClipView 滚动 + relocateViewport + layoutViewport | 17 | 17 | 约 75–89 ms（各轮有波动） |
| relocateViewport 无 NSClipView 物理滚动 | 4 | 12 | 约 170–193 ms |

引入 `relocateViewport` 后帧位置可从估算纠正为真实位置，
但 `relocateViewport` 调用本身每次约 20–90 ms，
在首次跳到 12k 行时该调用约 70 ms；
全篇 `usageBoundsForTextContainer` 在后续 `layoutViewport()`
由约 481,215 pt 变为 360,015 pt。
不能据此声称仅布局了当前可见区，或该操作对输入/滚动预算无影响。

扩大到 1k／24k／100k 行，每档 5 个远跳且均正确、真实末行可达，
滚动条比例与文档固定高度均稳定。
原生 `relocateViewport` 中位／最慢分别为：
1k 1.6／3.0 ms、24k 40.4／66.4 ms、
100k 181.3／309.7 ms；100k 的后续 `layoutViewport()`
单次最慢另有 60.3 ms。
耗时随规模显著增长，100k 场景不满足 32 ms；
**因此此路线是准确性候选而非达标生产快路径**。
原始日志 `build/git-diff-p1-textkit-ablation.log`、
`build/git-diff-p1-textkit-ablation-usage.log`、
`build/git-diff-p1-textkit-relocation-microsteps.log`、
`build/git-diff-p1-relocation-complexity-scale.log`。
Apple DTS 的目标片段对齐建议与此一致，但其文档也没有承诺
固定整篇滚动高度下任意距离都低于 32 ms。
https://developer.apple.com/forums/thread/761364 。

**同一 TextKit 元素所有者的折叠原型复测：**
使用临时 `SkippingFoldContentStorage` 子类，在原生枚举器到达
隐藏连续区间的边界时跳到已知下一个可见 NSTextLocation，
未创建第二份文本存储；其余原生视图和 Diff Edit Fold 保持一致。
24k 行、每 200 行一处变更、真实固定 JetBrainsMono 字体：

| 折叠场景 | 完整 native 布局 | 完整 skipping 布局 | 深度末行真实片段 |
| --- | ---: | ---: | --- |
| 约 120 组折叠，生产式默认枚举 | 253.3 ms | — | 正确，可见 |
| 相同折叠，跳过隐藏 NSTextElement | — | 50.1 ms | 正确，可见 |

该复测 `build/git-diff-p1-skip-hidden-layout-contract.log`
真正执行 1 项、XCTest 0 失败、Make 退出 0；
folded skipping 的 `setupMs` 为 106.8 ms，
仅布局部分 50.1 ms，不把它冒充实际 WindowServer 首帧。
未折叠路径在两组原型中全文布局约 866／895 ms，
且独立 raw NSTexView 固定高度会与原生计算的末行坐标冲突，
**不能**推断此优化解决未折叠深跳。
跳过隐藏枚举可能改变选区、Find、Undo、IME、编辑前方换行、
手动展开后的元素映射，因此它是 P2-T1 的候选实验，
必须从同一可写 TextKit 缓冲的完整行为与所有调用者验收后才可进入生产。

**更新的 P1-T2 Gate：** 可以用原生 API 保持文字与位置正确，
却尚无方案同时免去全部首屏布局、达到大规模滚动延迟目标。
必须优先在现有同一 TextKit 所有者/折叠元素枚举链中证明工作规模
可由实际可见行决定，再考虑生产替换；
不可把 O(文档规模) 的重定位转移到每帧或触发焦点时执行。

生产几何回归复核：移除失败原型后，
`build/git-diff-p1-existing-scroll-contract-regression.log`
中 4 项真实 `NativeDiffTabTests` 全部通过：折叠滚动高度稳定、
未折叠末行、原生 CR 段落高度、长删除 ghost 均通过；
Make 完整退出 0。与探索失败区分：现有生产行为未倒退，
但当前首帧性能问题仍然存在。

目前没有可放行的全条件原生几何方案，不删除生产全文布局保护。

进一步的局部枚举／单一段落所有者原型保存在
`build/git-diff-p1-direct-paragraph-experiment.patch`。
日志包括 `git-diff-p1-skipping-enumeration-experiment.log`、
`git-diff-p1-skipping-enumeration-pinned-style.log` 和
`git-diff-p1-direct-paragraph-owner-retry.log`，均位于 `build/`。
LF、24k、多处改动的折叠样本中，跳过隐藏元素可把显式全文布局从约 244 ms 降至约 50 ms，
但这不是完整首屏或全条件验收：未折叠原型没有复现生产 pane 的稳定参考几何，
不能据其错误尾坐标直接认定产品缺陷或宣称某 API 必然不可用。
直接构造 paragraph 的进一步原型触发 nil location 异常，说明它没有满足完整原生范围契约；
该原型失败保留，不进入产品或正常测试集合。
这些探索没有证明 Undo、IME、Ghost、可变段落、17 次跳转或最差输入预算成立。

SDK 契约核对：
`NSTextViewportLayoutController.h` 与 `NSTextLayoutFragment.h`；
`relocateViewport` 返回建议锚点，`adjustViewport` 只调整视口，
不能据此推断它会建立全文准确几何。

## 已确认的旧路径清理

`P1-T6` 单独核销：CodeGraph 和全文引用证明静态全量 capture、1.5 MB 旧预算
只有测试读者。生产仅保留 `DiffSyntaxSource` 的显式区间查询，
完整查询 oracle 转入测试且不复用生产的范围查询。
当前 2 MB 解析树缓存、5 MiB Diff 输入限制及所有数据保护不变。
这不是 P3-T4 完成，也不是首屏性能修复。

## 原子提交与当前 HEAD 验证

| 提交 | 独立结果 |
| --- | --- |
| `8ce6d0da` | 删除测试专用静态全文入口、旧预算和可选区间回退，保留独立测试 oracle |
| `fe777a29` | 原生编辑事件／Undo 字节契约及正确的宿主／E2E 文档边界 |
| `b0320924` | Git metadata／size／blob／batch 成本及完整字节基线 |
| `644d2aa9` | 密集逐词投影与真实后台取消基线 |
| `2dc1a37a` | 模型／原生布局／组件像素和 100k 行输入基线 |
| `9eb27356` | 修复焦点保存夹具的真实挂载前提，不改产品焦点行为 |
| `65152f3d` | 八种折叠编辑命令与完整原文、Undo／Redo、磁盘及 Index 字节回归 |
| `4355a70b` | 共享词元边界、逐词强调正确性和密集性能矩阵 |
| `b2d63928` | 两次干净的 Git 元数据读取组合成虚假 Staged 差异的并发反例 |
| `af89df2d` | 语法离散可见区间、树缓存复用及全文字节比较成本 |

初次完整 `make test`：846 项、16 SSH 跳过、同一焦点保存用例 2 处失败，退出 65。
AppKit 明确指出被设置的编辑器尚无 window，第一响应者被系统清空。
旧夹具只等 `nativeSurface` 创建，不能证明编辑器已经挂载。
修复后等待宿主视图树内的编辑器附着目标窗口，并断言真正的 firstResponder 进入与退出；
模型首帧基线后接焦点保存的组合 2 项通过，最终后端字节相符。

**提交 `9eb27356` 的完整 `make test`：848 项、16 SSH 跳过、0 失败，
完整命令退出 0，约 931 秒。**
日志：`build/git-diff-p1-final-full-host.log`。
`make build` 和其后的 `codesign --verify --deep --strict` 退出 0，
日志：`build/git-diff-p1-debug-build.log`。
此前的 846 项失败没有被删除或写成通过。

**最新 HEAD `65152f3d` 的完整 `make test`：849 项、16 SSH 跳过、0 失败，
完整命令退出 0，约 953 秒。**
日志：`build/git-diff-p1-final-full-host-with-fold-commands.log`；
Xcode 结果：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.05_22-38-55-+0800.xcresult`。
新增折叠命令矩阵和曾失败的焦点保存夹具均在本次全量中实际执行通过。
没有把先前 848 项结果冒充新增测试的完整验收。
随后在同一 HEAD 重跑 `make build`、`make build:release`，
两次构建及各自的严格验签均退出 0；
日志为 `build/git-diff-p1-final-debug-build.log` 与 `build/git-diff-p1-final-release-build.log`。
新增的八种折叠命令矩阵也另行通过 Release XCTest，1 项、0 失败、完整命令退出 0；
日志为 `build/git-diff-p1-release-folded-native-commands.log`。
正式包没有安装、启动或重启；现有正式进程仍保持运行。

样本字节数和 SHA-256：`build/git-diff-p1-sample-sha256.txt`。
实际字体为 JetBrains Mono Regular 13 pt，完整显示宽度档为 standard，Retina 2×，
计时测试在原生日志中逐次记录配置。

### Release 对照与构建

命令通过现有 Make 参数执行 Release 的四项性能／字节测试，
仅 Dev XCTest 附加 `VERSION_FLAGS=ENABLE_TESTABILITY=YES`；
4 项、0 失败，完整命令退出 0。
日志：`build/git-diff-p1-release-performance.log`。
同一进程先分列首次标签，再运行每组 30 次热测；这些不是操作系统冷启动。

| 样本／来源 | 模型中位 / P95 | 原生完成中位 / P95 | 组件像素中位 / P95 |
| --- | --- | --- | --- |
| 1k Staged | 88.43 / 95.94 | 93.43 / 101.05 | 97.12 / 104.60 ms |
| 1k Unstaged | 131.30 / 139.12 | 143.68 / 152.09 | 161.80 / 172.59 ms |
| 24k Staged | 178.88 / 191.49 | 184.09 / 196.37 | 187.64 / 199.86 ms |
| 24k Unstaged | 278.74 / 404.22 | 461.41 / 588.75 | 797.69 / 933.07 ms |

100k txt 输入 P95：文首 439.82／文中 245.94／文末 47.36 ms；
100k Swift：489.44／270.14／52.04 ms。
Release 并未使文首输入恢复预算，不能用优化构建掩盖 TextKit 的段落维护成本。
399／400 token × 1000 对投影分别为 2769.01／2740.06 ms，
401 token 为 105.79 ms；100 × 400 token 的真实取消仍等 277.42 ms。
这些是原实现基线，不是优化后的收益。

另行执行不带 `ENABLE_TESTABILITY` 覆盖的正式 `make build:release`，
构建及严格验签退出 0；日志为 `build/git-diff-p1-release-build.log`。
未安装、启动或重启正式 Bailey，P1 的正式 App 保护边界不变。

### 授权 Windows 实测

明确传入 `BAILEY_P4_TEST_SSH_HOST=windows` 及 XCTest 转发变量，
只运行 `testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`。
该方法实际被发现并执行，不是跳过；使用其自有 UUID socket。
约 8.49 秒后，连接目标的 22 端口超时，首个创建临时目录命令退出 255；
随后路径校验拒绝继续，未创建或清理任何远端用户目录。
1 项、2 处失败，Xcode 退出 65，Make 退出 2。
日志：`build/git-diff-p1-windows-live-attempt.log`。
因此**在当次连接超时的时间点**，Windows 的 Git／clean／保存语义未被实机验证；
已经获授权，不再要求用户重复授权。

**后续实机恢复与独立验收（同日）：** 用户明确授权开启 Tailscale 后，
禁用 SSH master 的 `windows` 连接恢复，`wincrh` 仍超时。
独立 Windows Diff／clean filter／原文写盘和 Git 字节测试 1 项通过，
`build/git-diff-p1-windows-live-connected.log`；
完整 `WorkspaceGitUITests` 在独占桌面下 7 项通过、无跳过，
`build/git-diff-p1-windows-ui-full-class-exclusive.log`；
真实远端故障注入与快照恢复 1 项通过，
`build/git-diff-p1-windows-recovery-benchmark.log`；
真实远端轮询／外部提交及取消验证 3 项通过，
`build/git-diff-p1-remote-refresh-windows-class.log`。
相关 GUI 与 SSH 夹具修复提交为 `33348f07`、`3c98b438`、`82d17ea8`。
完整测试前提、先前失败、隔离清理和实测范围见
`evidence-p1-process-lifetime.md`；这些成功**不等于**物理网络断连、
所有 SSH 来源、在途旧 Git 子进程取消或高帧率 GUI 已验收。

## GUI 认证历史失败与最新恢复

此前曾运行实际 UI 入口，不是仅凭开关状态推断：
多次 `make test:ui` 的原生枚举返回 0，所有命令均被 Makefile 正确判失败。
临时保留的实际枚举 JSON 为 `build/git-diff-p1-selected-tests.json`，错误为：
`The test runner failed to initialize for UI testing`，
底层 `Timed out while enabling automation mode`。
Runner 采样停在 `enableAutomationModeWithError`；
`automationmodetool` 明确报告模式关闭且需要用户认证。
用户的任务授权已经具备，但系统交互认证不能由智能体绕过。

已确认没有其它测试进程后恢复本轮 XCTest 服务，宿主重新通过；
**此处记录的认证失败是历史结果，现已恢复，不再构成当前阻塞。**
2026-11-06 重新启动隔离 Bailey Dev 的真实 XCTest 会话后，
`build/git-diff-p1-genuine-gui-e2e-retry.log` 的 Git Worktree 编辑／保存用例
实际执行并通过，随后 `build/git-diff-p1-all-workspace-git-ui-e2e.log`
实际执行 7 项，6 通过、1 项 SSH 因连接不可达跳过、0 失败，Make 退出 0。
真实 Split Git Diff 的 `⌘F`／`⌘⌥F` 也经 Peekaboo、
`bailey.diff.worktree` AX 和窗口截图核验查找／替换栏可达。
此前 Files Find 被误认作 Diff 的结论已在上文撤回。
没有修改 authorization database、TCC、安全策略、正式 Bailey 或用户 SSH master。
`make build:ui` 的成功仍只代表 UI Target 编译，以上完整 App XCTest
则是另外的真实 GUI 证据。
但 GUI ⌘S 的偶发超时尚缺连续复测与唯一根因归因，
跨隐藏查找、中文 IME 系统候选、真实输入 P95 与窗口首帧预算也未完全核销。

## 尚未核销的验收

以下条件都没有被本页的宿主绿色替代：

- 独立 App 真实窗口首次像素、系统中文候选、连续滚动帧、GUI ⌘S 偶发超时归因：
  现已恢复 GUI XCTest 并执行 7 项，但尚未测出这些阶段的可靠 P95，
  不以组件像素或一次 GUI 通过代替 WindowServer 首帧与完整用户路径性能验收。
- 最低 macOS 15.6 和其它显示比例：本机没有相应系统／显示硬件；
  只保留最低部署目标，不声称旧系统实机通过。
- Windows SSH：`windows` 已恢复独立连接，真实 Git clean／原始字节保存、
  完整 Git GUI 7 项、受控故障恢复和轮询测试各有独立通过证据；
  `wincrh` 仍不可达，真实物理断线、在途 Git/SSH 进程取消、全来源与传输预算
  仍未验证。连接成功不能替代这些远端验收。
- Debug／Release 已完成 1k／24k 及额外 100k Staged／Unstaged 的各 30 次组件热态基线，
  1／100／10k 未跟踪状态项已分别实测核心和详情；
  真实冷进程窗口已有低帧率分组记录，但同二进制 Split 每来源少于 30 次，
  高帧率首像素／可输入、100k 多折叠与长行、5 MiB 边界、全部来源／混合换行、
  17 次**准确**远跳、字体／主题／滚动条组合仍未核销。
  不能用单次状态事件、失败原型或当前全量宿主通过冒充这些条件已通过。
- 1／5／10／20 标签：20 个 24k 行独立原生 Diff 的瞬时 malloc／RSS
  已实测；关闭后故意保留 `NSScrollView` 时仍持有文本／Neon，
  原始布局 manager 在视图释放后仍可存活，针对性 detach 消融成功释放。
  尚未完成产品真正关闭、重挂载与持续时间的 retained heap／Allocations 验收；
  旧 Git 子进程取消已复现五次关闭可堆积，不表示已修复。
  详细结果见 `evidence-p1-process-lifetime.md`。
- Staged HEAD／Index 交叉变化、缓慢超预算 stdout／stderr、编辑前方换行与隐藏选区：
  原有测试不等于新前提已建立，仍需分别构造，不能先宣称恢复不变量。

P1-T5 的预算和生产准入尚未冻结；P2／P3／P4 没有实施完成。

### 16 项 SSH 跳过的具体归属

本机完整套件没有注入远端测试主机变量，跳过不是未获用户授权。
`windows` 现可独立连接，部分指定测试已另外通过；
**未指定主机的全套件中其余跳过仍是跳过**，不能直接算通过。
补验需核对每种测试的专用远端目录校验和清理后，
明确传入 `BAILEY_P4_TEST_SSH_HOST=windows`；
每项均保留在对应任务验收中，不算完整通过。

- `GitInteractiveRebaseIntegrationTests.testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`：独立握手与远端交互重排。
- `GitRemoteRefreshIntegrationTests.testAuthorizedSSHRemotePollDetectsExternalChangesAndStopsWhenCancelled`：远端轮询与真实取消。
- `GitWorkspaceSSHTests.testAuthorizedSSHRefArchiveBinaryResetStashCleanAndIgnorePersistOnWindows`：远端 refs／归档／二进制及修改字节。
- `GitWorkspaceSSHTests.testAuthorizedSSHWorktreeCreationAndRemovalPreservesBranch`：远端 Worktree 和分支保存。
- `NativeDiffTabTests.testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`：Windows Diff、clean 规则与原文保存。
- `ProjectFileIndexTests.testAuthorizedWindowsSSHProjectIndexGitAndPlainRealFiles`：远端文件索引的 Git／普通路径。
- `SSHFileTreeLiveTests.testAuthorizedWindowsSSHBatchDirectoryListingAndIndependentFailures`：批量目录和独立失败。
- `SSHFileTreeLiveTests.testAuthorizedWindowsSSHCopyMoveAndDeletePreserveRealDiskContents`：远端复制／移动／删除。
- `SSHFileTreeLiveTests.testAuthorizedWindowsSSHFileTabCapacityAndBytePreservingSave`：远端容量边界与保存字节。
- `SSHFileTreeLiveTests.testAuthorizedWindowsSSHRenamePreservesActualDirectoryEntries`：远端重命名后的真实目录。
- `SSHGitRecoveryLiveTests.testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`：Git 故障与恢复后写入。
- `SSHWindowsFileEventsTests.testAuthorizedWindowsCancellationReapsOnlyItsOwnWatcher`：只回收测试自有 watcher。
- `SSHWindowsFileEventsTests.testAuthorizedWindowsPinnedProjectUsesEventsAndSharesOneSubscription`：固定项目事件与共享订阅。
- `SSHWindowsFileEventsTests.testAuthorizedWindowsSSHExternalEventUpdatesRealFileTreeWithoutPolling`：真实事件到文件树。
- `SSHWindowsFileEventsTests.testAuthorizedWindowsSymlinkedRootKeepsFallbackPolling`：符号链接根目录的轮询回退。
- `SSHWindowsFileEventsTests.testAuthorizedWindowsWatcherReportsLostWhenRootMoves`：根目录移动后的 watcher 丢失恢复。
