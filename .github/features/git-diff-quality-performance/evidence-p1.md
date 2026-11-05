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

## Git 对象读取

`testGitObjectReadPhaseLatencyAndBatchCompleteness` 对 1k／24k 各做 30 次。
每次核对真实 blob 字节、声明大小、batch OID／类型／大小头和终结 LF，
最后再次核对磁盘原文。

| 样本 | metadata 中位 / P95 | size 中位 / P95 | blob 中位 / P95 | 单次 batch 中位 / P95 |
| --- | --- | --- | --- | --- |
| 1k | 22.43 / 24.34 | 23.06 / 28.48 | 22.83 / 25.47 | 18.19 / 20.17 ms |
| 24k | 22.23 / 23.77 | 22.62 / 24.05 | 23.07 / 24.81 | 18.21 / 20.35 ms |

batch 是一次性 Git 原生命令，不是常驻服务。
实验首次将非绝对 `git` 直接传给本机后端而失败；核对 `runSync` 的 executable 契约后，
修正为 `/usr/bin/env git`，复测通过。原失败保留在 `build/git-diff-p1-io-dense.log`。

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

**结论：** 400-token 上限内的 Myers trace 是真实热点，不是推测；
不能用 0.172 ms 稀疏样本豁免 P3-T3。
提交 `644d2aa9` 经生产 `runBackgroundDiffWork` 建立进入前提后取消，
100 对、400 token 仍等待约 3709 ms 才真正结束；返回结果为 nil，未发布过期结果。
该测试为基线，不表示取消时延达标。
含共享 token 的密集替换、重复展开和分配峰值仍待补测。

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
因此 Windows 的 Git／clean／保存语义未被实机验证；
已经获授权，实际缺少的是可达连接，不再要求用户重复授权。

## GUI 外部阻塞

已经运行实际 UI 入口，不是仅凭开关状态推断：
多次 `make test:ui` 的原生枚举返回 0，所有命令均被 Makefile 正确判失败。
临时保留的实际枚举 JSON 为 `build/git-diff-p1-selected-tests.json`，错误为：
`The test runner failed to initialize for UI testing`，
底层 `Timed out while enabling automation mode`。
Runner 采样停在 `enableAutomationModeWithError`；
`automationmodetool` 明确报告模式关闭且需要用户认证。
用户的任务授权已经具备，但系统交互认证不能由智能体绕过。

已确认没有其它测试进程后恢复本轮 XCTest 服务，宿主重新通过；
UI 的模式认证超时仍存在。
没有修改 authorization database、TCC、安全策略、正式 Bailey 或用户 SSH master。
`make build:ui` 退出 0 只证明 UI Target 编译，不是 GUI 通过。
先前 GUI ⌘S 的超时原因没有在本轮得到完整 App 复现，
宿主焦点夹具的修复不能冒充该 GUI 问题已经解决。

## 尚未核销的验收

以下条件都没有被本页的宿主绿色替代：

- 独立 App 首帧、真实键盘／系统候选、连续滚动帧、GUI ⌘S 超时归因：
  被上文实际认证错误阻塞；组件像素、组合输入和 Undo 断言仅为替代证据，
  不替代 WindowServer 或系统候选验收，阻塞完整用户路径预算和阶段 Go。
- 最低 macOS 15.6 和其它显示比例：本机没有相应系统／显示硬件；
  只保留最低部署目标，不声称旧系统实机通过。
- Windows SSH 的真实 OID／保存、传输预算、RTT、断线恢复：
  已授权但现有两条独立连接超时；本机／受控后端不能替代，阻塞对应远端验收。
- Debug／Release 的全部冷／热、100k 折叠与长行、恰好 5 MiB ±1 byte、
  1／100／10k Changes、全部 Git 来源、混合换行、17 次远跳、字体／主题／滚动条组合：
  新测量只核销上文明确切片，其余继续由原任务负责，不能凭旧 172 项推断全部完成。
- 1／5／10／20 标签长期 heap／RSS、真实关闭后缓存旧 NSView、底层进程取消：
  已沿 owner 读到源码不对称，尚未完成新的资源断言与 Allocations 验收。
- Staged HEAD／Index 交叉变化、缓慢超预算 stdout／stderr、编辑前方换行与隐藏选区：
  原有测试不等于新前提已建立，仍需分别构造，不能先宣称恢复不变量。

P1-T5 的预算和生产准入尚未冻结；P2／P3／P4 没有实施完成。

### 16 项 SSH 跳过的具体归属

本机完整套件没有注入离线远端参数，跳过不是未获用户授权。
已授权目标的独立连接超时，故以下各自的远端副作用均不能由本机绿色替代。
补验统一前提是专用连接实际可用，再传 `BAILEY_P4_TEST_SSH_HOST=windows`；
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
