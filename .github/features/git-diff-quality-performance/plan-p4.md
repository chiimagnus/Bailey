# P4：跨来源完整用户验收、远端场景与性能交付

**Goal：** 把 P2／P3 的局部正确性变成完整 Bailey Dev 中可观察、可复验的
Git Diff 结果；核销原始字节、真实渲染、输入、失败恢复、性能和资源释放。

**Non-goals：** 不将自动化通过冒充已发布；不擅自合并 PR #78、推送主分支或更改用户数据；
不重复设计普通 Git 提交／Reset 或独立 `adaptive-large-files` 的 GB 数据模型。

**Approach：** 先在隔离真实 Git 仓库验证不同来源的完整语义，
再在完整 App 核对真实视口、键盘、剪贴板、IME、AX、保存与窗口归属，
然后补齐获得授权的 Windows SSH 实机，最后按当前 HEAD 做完整回归、
Debug／Release 性能及内存、文档／删除代码审计与交付核销。

**Acceptance：**
- 真实 Git 各比较来源的 old/new 与磁盘、Index、Git 命令一致；
  不因规范化、状态切换和重载出现虚假变更或草稿丢失。
- 真实完整 App 下折叠、行号、删除 ghost、Split 同步、浮动／传统滚动条、
  高亮、AX、输入、保存、恢复和焦点全部符合 `idea.md`。
- 首屏、输入、滚动、切标签、多标签内存的冷／热、P95、峰值和关闭后稳定数据
  与冻结预算有可重放测量，未以降低测试覆盖或视觉正确性换取性能。
- 全量测试、构建、签名、适用 GUI E2E 与远端缺口记录对应**最终提交版本**，
  无未解释回归、旧双轨、临时调试改动和无主文档状态。

**Rules：**
- 当前授权仅写计划；将来执行 GUI 时必须独占键盘焦点，只启动 Bailey Dev。
- Windows SSH 测试只针对明确授权的专属目标、独立临时仓库；
  测试不借 SSH master，不操作工作中用户文件。
- 缺少必需条件必须分项说明影响及补验，不能用 `XCTSkip`、“反正主机测试通过”掩盖。
- 每个发现的新可复现生产缺陷回到其源码 owner 和对应实施 task，
  Red→Green、清理旧路径、文档同步、原子提交再重新执行受影响矩阵；
  不能在收尾阶段打临时补丁。

<a id="p4-t1"></a>
## P4-T1 核销所有 Git Diff 来源与文件／Index／历史完整结果

**结果：** Git 模型、原生行显示及真实 index/HEAD/worktree 一致，
包括最初点击、保存、刷新和外部 Git 操作后的状态。

**Files／入口：**
`GitFileEventWatcher`、`GitStatusModel.configureLocalWatcher/refresh/runGitStatus`、
`GitPanel.browseGitChange/handleHistoricalFile`、其 `openCommitDiff` 回调、
`RecentCommitsView`、
`WorkspaceWindowModel.openDiff`、`Project.openDiff/openCommitDiff/openHistoricalDiff`、
`DiffTab.reload/refreshWhenSelected/gitComparisonBaseline`、
`DiffCore.fromVerifiedOperations`、
`GitHistoricalFileLocator.resolve`；
`BaileyTests/Git/{NativeDiffTabTests,NativeGitHistoryFileTests,GitBrowsingRecoveryTests,GitStatusModelTests,GitExecutionTests}.swift`；
`BaileyUITests/Git/{GitChangesUITests,GitHistoryUITests,WorkspaceGitUITests}.swift`。

**步骤：**
1. 在真实临时仓库逐项创建：
   HEAD 对 Index、Index 对 Worktree、相同文件已暂存后再编辑、
   未跟踪、初始提交前、detached HEAD、Merge 冲突阶段 0／1／2／3、
   新增／删除／复制／重命名／mode-only、符号链接／悬空链接／子模块、
   历史对首父、两提交比较、Stash、历史原文、历史对 Worktree、
   多 Git Worktree 及相同相对路径不同机器／仓库。
2. 将**Git 状态初次加载／文件事件刷新／远端轮询／当前缓存重用**与
   **Changes 行选择／Graph 选中历史文件／导航打开 Diff** 分开建立前提；
   1／100／10k 级状态项下核对当前行、所选机器及项目，避免列表性能掩盖单文件 Diff。
   对照 Git 命令和 OID，检查显示结果、行号、折叠、行内高亮、无变更判断，
   对应源是否具有安全写入资格、点击保存是否只写 Worktree；
   真实 `git diff --cached`、`git diff`、Index／磁盘字节均核对。
3. 逐项组合 `core.autocrlf` true／false／input（按系统适用）、
   `text/-text/eol`、clean filter、无末行 LF、LF／CRLF／裸 CR／Unicode 分隔符、
   UTF-8 BOM、代理对／组合字符／规范等价不同字节、空文件／仅换行、
   重复短行无唯一锚点／超长 SVG 行、多 hunk／全部删除、
   5 MiB 恰好和 ±1 byte、二进制／NUL／非法 UTF-8／编码错误；
   真实 Git index stage 和文件原字节必须是测试已验证前提，
   不允许未经声明的空侧或错误状态冒充正常数据。
4. 测“文件外部改写→正在读取→用户编辑→用户保存→旧请求返回”，
   以及 HEAD/index 在 Git patch 读取期间变化、clean filter 修改实际文件、
   超大 Git stdout 被接收中断；旧结果不能影响当前项目、机器、路径和可写 buffer。
   核对关闭窗口后不向新窗口写入、脏草稿不被 Git 后台刷新抹除。

**验证：**
`make test:DiffEngineTests,NativeDiffTabTests,NativeGitHistoryFileTests,GitExecutionTests,GitBrowsingRecoveryTests,GitStatusModelTests`；
完整 App 至少核对 Staged／Unstaged 真实基线、Changes 列表目标、
Graph 历史／其它 Worktree 浏览与工作区保存结果；
选择已枚举的 `GitChangesUITests`、`GitGraphUITests`、
`GitHistoryUITests`、`WorkspaceGitUITests` 完整 App 用户方法，例如：
`make test:ui ONLY_TESTING='BaileyUITests/GitChangesUITests BaileyUITests/GitGraphUITests BaileyUITests/GitHistoryUITests BaileyUITests/WorkspaceGitUITests'`。
`Makefile` 已提供原生 XCTest 枚举预检，任何零匹配选择器必须失败；
不重复把底层全矩阵复制成冗长 GUI 脚本。
检查完整命令退出状态及真实 Git/文件后置副作用。

**覆盖约束：**
`idea.md` 中来源、文件状态、文字、Git 规则所有适用值与极值必须被分派；
组合尽量全覆盖，实在不能穷尽时记录执行过的两两／多因素及所有已知故障组合，
不只跑 5 项既有 UI 测试就宣称整体完成。

**Uncovered：**
GB 级 Diff 的完整性属于独立 `adaptive-large-files`；
本任务验证现有有界大小和准确超限提示。
Windows Git 专有配置的真实效果归 P4-T3 专属远端补验。

**文档：** 改动产品契约时在所属 P2/P3 任务同步，
本任务若只发现现有保证已满足不重复写长期文档。
**提交：** 新的永久真实 Git 回归用例可原子提交；生产问题回原 task 修复。

<a id="p4-t2"></a>
## P4-T2 完整 App 真实 GUI、交互、AX 和保存验收

**结果：** 用户在 Bailey Dev 实际看到和操作的行为成立，
不再只靠最小 `NSWindow` 宿主断言或一次成功的键盘事件推断正确。

**Files／入口：**
`DiffNativeRoot.updateNSView`、`DiffNativeSurface.render/requestFocus`、
`DiffCodePaneView.layout/setReviewDocument/activateFold`、
`DiffRowGeometry.visibleRows`、`DiffTab.save/autoSaveOnFocusLoss`；
`BaileyUITests/Git/WorkspaceGitUITests.swift`、
`GitChangesUITests.swift`、`GitHistoryUITests.swift`、
`BaileyTests/Git/NativeDiffTabTests.swift`。

**步骤：**
1. 独占图形会话，启动独立 `chiimagnus.bailey.dev`，使用一次性 Git 目录；
   不影响正式 `/Applications/Bailey.app` 或其它桌面 App。
   如果其它 App／系统通知占据键盘焦点，记录测试归因和实际日志；
   重新隔离后复跑，绝不通过 `sleep`、禁用焦点断言或吞事件保证绿色。
   测试不得偷偷切换用户当前系统外观或覆盖剪贴板；
   只在项目现有独立 GUI 配置中使用受控主题和恢复所有暂改设置。
2. 真实 Git Changes、Git Graph、历史原文、Staged／Unstaged 快速切换、
   同文件多次打开、外部刷新、Dock 重挂载、多窗口选择、切文件及关窗恢复逐一操作。
   看得到文字与真正能输入、第一响应者属于哪个窗口是两项不同结果。
3. Unified／Split、普通 Worktree 可编辑／Staged 与历史只读／clean filter
   规范化只读对照和原始 Worktree 并列、明暗／高对比、
   两种原生滚动条风格、普通／完整长行设置，
   窄／宽窗口、顶部／中部／深处滚动／无变更非折叠深处，
   折叠按钮层级与 AX Press 实际坐标、长删除 ghost、
   语法色及词级强调、视口恢复、字体/主题切换，取真实窗口截图比对像素。
4. 实际文本操作：普通输入不自动展开、手动折叠逐段展开、
   跨隐藏选区（端点落在可见区／隐藏区／文末）、粘贴、剪切、`⌘A`、Find/Replace、
   Undo/Redo、中文 IME 提交、`⌘S`、失焦自动保存、
   在途保存新增编辑、保存失败及关闭恢复；
   断言光标、可见内容、磁盘精确字节、Git 工作区状态与 Index 未意外改变。
5. 审查可视标记和 AX 树是否真实可点击，
   无按钮／空状态的只读 Diff 不声明可编辑；
   Changes 右键仅改变操作目标而不误触发 Diff 打开或其他组焦点，
   右键菜单期间快捷键作用于当前第一响应者而非后台窗口。

**验证：**
`make build:ui` 仅负责确认 target 可编译，随后使用
`make test:ui` 的受影响 `BaileyUITests` 选择器执行真实完整 App 路径；
`make test:NativeDiffTabTests,NativeContentIdentityIntegrationTests,NativeEditorCompositionTests`
保留极端原生像素、IME、AX 组件级断言，
不重复整套 GUI 大规模数据矩阵。
每个失败对应截图、AX frame、前台进程、XCTest 日志与真实磁盘结果；
单次组合用例超时须独立再测并保留证据，不能直接归为 Bailey 产品缺陷。

**Uncovered：**
真实 macOS 15.6 与不可授权的系统候选输入测试按 `idea.md` 列明具体条件。
无法独占桌面时真实 GUI 为阻塞，宿主结果不能替代。

**文档：** 真实交互契约变化在对应 P2 owner 同任务更新
`docs/features/diff.md`、`docs/ui.md`、`docs/testing.md`；
本验收只修文档中的已证实事实，不复制截图流水账。
**提交：** 纯 E2E 夹具修正单独提交；生产缺陷回 P2/T owner 原子修复。

<a id="p4-t3"></a>
## P4-T3 完成获授权 SSH 的 Git Diff 语义与断线恢复闭环

**结果：** 远端文件的来源、保存与取消从未回退本机，
Windows Git 与网络时序下保持同一 Diff 视觉和真实字节。

**Files／入口：**
`DiffTab.reload/gitContent/readWorktreeFile/writeCurrentText`、
`SSHWorkspaceBackend.run/read/write`、
`GitCommandExecution.runData`、
`Project.openDiff`；
`BaileyTests/Git/NativeDiffTabTests.swift` 中
`testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`，
`BaileyTests/Git/SSHGitRecoveryLiveTests.swift`、
`GitWorkspaceSSHTests.swift`、
`BaileyTests/Git/GitRemoteRefreshIntegrationTests.swift`；
GUI 路径 `BaileyUITests/Git/WorkspaceGitUITests.swift` 的
`testAuthorizedWindowsSSHGitReviewThroughRealUI`。
这些文件／方法已在源码核对，不留“执行时再找类名”的占位。

**步骤：**
1. 先取得**明确授权**的独立 SSH 测试主机及测试目录，
   通过既有 `BAILEY_P4_TEST_SSH_HOST` 完整列出将写入的临时 Git 路径，
   不借用用户活跃 master 或后台会话，最后只清理测试持有物。
2. 在真实 Windows Git 上创建有 staged 和 unstaged 的同一文件，
   设置 `core.autocrlf=true`、`.gitattributes` 的 LF／CRLF／text/eol 及专用 clean filter；
   确认 Git 真实 status／blob OID、Worktree 原始字节及过滤器输出与 Mac 期待一致。
3. 经实际 Bailey Backend 打开、逐段折叠、Split、编辑、保存、
   外部 Git 再暂存，确认同一路径没有 phantom 全删全增；
   针对 P3-T1 再验证 Git metadata／Blob／patch **真实 SSH 传输和接收上限**：
   预算内完整保留正文，预算外明确失败且峰值驻留受控，
   异常 stderr、连接失效不能变成伪造的短输出或空 diff。
   中断连接／超时／重连、并发旧请求与关闭标签后均不写错机器或本地磁盘。
4. 记录 SSH 往返次数、P95、低速连接下模型／首屏／输入、后台任务和 RSS，
   并对照 P1／P3 的本机与受控后端数据，不用它们推断远端用户感知延迟。

**验证：**
只对专属授权目录运行相关现有授权 live tests；
以现有真实方法选择器运行宿主测试，例如
`make test ONLY_TESTING='BaileyTests/NativeDiffTabTests/testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules BaileyTests/SSHGitRecoveryLiveTests/testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery'`；
再在专用桌面执行
`make test:ui ONLY_TESTING='BaileyUITests/WorkspaceGitUITests/testAuthorizedWindowsSSHGitReviewThroughRealUI'`。
这些选择器必须通过 Makefile 的原生枚举预检；
核对最终远端文件、Index、HEAD、
本机同名文件不变。执行超时、断线、重连、切别的窗口、远端路径改名／文件删除、
多标签切换与取消后旧结果不得发布。

**Uncovered：**
未获专属主机授权就**不能**执行实机写入；具体影响是 Windows EOL/filter、
真实传输延迟与断线安全尚无闭环证据，
仅有受控后端替代测试且该场景不得无保留验收。
完整套件的 16 项原 SSH 跳过中包含非 Diff 项，应分别列明：
本 feature 相关项是否阻塞 Git Diff 完成，
无关 SSH Files/终端项只属于全仓额外缺口，不能混淆。

**文档：** `docs/features/diff.md` 与 `docs/features/ssh.md`
只有生产契约改变时在对应实施 owner 更新；
本任务保存实际测试环境与证据。
**提交：** 实际发现功能问题则返回 P2/P3 owner；
无新行为的实机核销不为提交而写代码。

<a id="p4-t4"></a>
## P4-T4 完成真实首帧、热编辑、滚动和长期内存定量验收

**结果：** 证明改动不是把 CPU 等待从 Git 进程挪到主线程，
或者把首屏变快同时让滚动条、内存与后台任务变差。

**Files／入口：**
`DiffCodePaneView.layout/applyContentHeightOverride`、
`DiffNativeSurface.editTextDidChange/render`、
`DiffTab.reload/recomputeDisplay/refreshEditDecorations`、
`DiffSyntaxSource.captures`；
`BaileyTests/Git/NativeDiffTabTests.swift`、
`docs/testing.md` 现行性能规范，
以及 P1 阶段形成的同样本和同环境日志。

**步骤：**
1. 固定最终 HEAD、OS/Xcode/机型、Git 版本、字体、显示器、
   主题、窗口尺寸、长行偏好、Debug/Release、冷热定义与数据 hash，
   重新跑完整性能测量；只在相同硬件和同参数下比较改动前后。
2. **分别**记录文件事件→Git 状态核心→详情→Changes 行出现，
   以及鼠标／键盘点击已显示行→Diff 首像素→真实可输入→语法色稳定。
   `GitStatusModel.refresh`、Changes 选择计算、Git IO、DiffCore、投影、
   TextKit 布局、WindowServer 显示分开计时；
   1／100／10k 级状态项，1k／24k Staged／Unstaged 至少 30 次热，
   冷启动、首次挂载、历史与 SSH 分开统计，不能把 400 ms 事件 debounce 算进单击耗时。
3. 输入文首／中／末、不同折叠数量、普通字符与换行、Undo、IME、
   有/无 Neon、主题重绘、窗口改变、滑块拖动、17 次远跳、
   **无变更非折叠深处滚动的前缀枚举、编辑后非 LF 标记全篇扫描**、
   文件末尾、短侧／长侧 Split 联动；
   30 次热操作报中位／P95／最差、主线程连续占用和原生几何是否变形。
4. 以 Instruments Time Profiler、Allocations 在 1／5／10／20 标签负载
   下记录创建峰值、切换、折叠展开、语法重建、失焦自动保存、关闭后的稳定 RSS／heap、
   CPU／唤醒及 TextKit／Tree-sitter／NSAttributedString retained 对象；
   同时记录 Git stdout（含 stderr）大小／实际本机与 SSH 接收量／峰值缓冲，
   检查超过限额时没有临时接收完整大数据。
   不能仅证明 cache hit，必须证明独占资源可以释放。
5. 没达到 P1 冻结的首屏预算、`docs/testing.md` 的输入/滚动性能目标或正确性
   均退回相应 owner 修复并重测；不能通过缩减实际样本或只测 Debug 热缓存宣布完成。

**验证：**
`make test:NativeDiffTabTests,DiffEngineTests,NativeContentIdentityIntegrationTests`
以及独立 Dev GUI 和必要的 Release 构建／Profiler；必须附完整命令退出码、
环境、样本数、分布及原始证据路径。性能仪器不得修改正式 Bailey 会话。
并行文件／SSH 写入时保留输入和 Index 原字节验证，不以性能覆盖正确性。

**Uncovered：**
长期真实 SSH 断线压力与不同 macOS 设备需授权和环境，
具体补验入口依 `idea.md` 单项记录，不用本机值代替。

**文档：** 只有性能验收标准或可依赖的产品契约改变才更新 `docs/testing.md`、
`docs/features/diff.md`；实验数字在本 feature 证据，不写进永恒性能承诺。
**提交：** 如需长期保留自动断言，单独原子提交；数据证据按 feature policy 保留本地。

<a id="p4-t5"></a>
## P4-T5 最终回归、源码与计划双向审计及交付判定

**结果：** 当前 HEAD 对应的全部必须条件能逐项追溯，
没有未提交旧路径、虚假完成声明、未处理冲突或损坏正式用户环境。

**Files／责任归属：**
本 feature `idea.md`、`todo.toml`、各 `plan-pX.md`；
现行 `docs/features/diff.md`、`docs/features/editor.md`、
`docs/features/git.md`、`docs/ui.md`、`docs/architecture.md`、`docs/testing.md`；
真实受影响的 `Bailey/Git/`、`Bailey/Editor/` 与现有测试；
`Makefile` 和当前 Git PR。

**步骤：**
1. 最后一次检查工作区与并行开发改动，逐项核对本 feature **每个此前实施任务**：
   真实入口接通、状态只有一个 owner、已替代路径**已经在该 task 的提交中删除**，
   不是本阶段再集中清理；不存在重复完整正文、无效生成、旧 Review/Edit 模式、
   兼容别名或无证据围栏。确有遗留须退回其 owner 同任务修复及重测；
   **不得把 clean filter 的并列规范化视图误认成旧 Review/Edit，**
   也不能误删 Git OID、symlink、身份校验、保存队列等仍用于数据保护的可达路径。
2. 对照 `idea.md` 的完整来源／状态／文本／显示／编辑／时序／性能矩阵，
   还必须核对本轮新增的 Changes／Graph 状态刷新、非折叠深处行号、
   `stdoutLimit` 真实传输预算、文本变更前后回调与测试专用旧 API 删除。
   所有适用值和极端条件有精确测试入口、有效前提、可见结果及环境证据；
   未执行者列原因、影响、替代证据与必需补验，
   无法完成必需路径则明确 **No-Go**。
3. 以**最终实现提交**运行完整 `make test`，核对 XCTest 总数、
   跳过原因、完整 Make 命令状态；
   执行 `make build`、`make build:ui` 和必要的
   `make test:ui`，功能涉及签名或优化构建时执行 `make build:release`。
   构建、应用签名、GUI 实际验证和正式安装分别证明。
4. 只在本次实施授权含产品安装且满足 `docs/development.md#本地安装` 时，
   对正式 App 做整包安装／验签／文件一致性核对，
   **不主动退出或重启当前正式 Bailey**。
   已安装≠进程正在运行新版，已合并≠已发布，报告明确区分。
5. 核对所有现行文档 owner 与导航锚点、`git diff --check`、
   提交原子性（中文标题、原因、修改内容与实际验证），
   无计划模板占位符；阶段审计发现的新实质问题退回对应任务。
   本 feature 不要求创造第二份 TODO 或大段历史流水账。
6. 重新检查 `adaptive-large-files` 实际是否已实施；
   若已引入共同原生/数据模型，按当前可达链补回归，
   未实施则明确跨 feature 集成待验而不阻塞本计划已限定的 5 MiB 闭环。
   现有 PR #78 是否需要更新、是否继续合并必须按**当时**状态核对，
   未获授权不自动推送或合并。

**验证与退出：**
`make test` 完整 `TEST SUCCEEDED`、`make build`、`make build:ui`、
`make test:ui` 的适用用户路径、
必要 `make build:release` 与 `codesign`、
`git diff --check`、`feature_tool.py todo validate`；
所有统计与当前 HEAD 一一匹配。
任何新产品修复先回 owner 重测，再重新跑受影响项目及最终全量验收。
阶段审计实际开始才生成 `audit-p4.md`。

**Uncovered：**
真实旧系统、未授权 Windows SSH、无法取得独占图形会话、
资源安全上限、其它项目仍执行的大文件分段功能，
必须分别说明是阻塞当前 Diff 本身还是跨 feature 非目标；
不能用“宿主 0 失败”统一抹掉。
**文档／提交：** 本任务只维护真实验收证据及必要纠错，
不在 P4 新建清理代码 task、兼容转发层、总协调者或永久诊断框架；
新的生产修改不得混进所谓“收尾提交”，应回到对应职责 task。

## 完成 Gate

不是“看起来差不多”，也不是“843 项曾通过”：
以最新源码、完整 `idea.md` 适用条件和同机性能、
当前 App 用户操作、真实 Git 原文／Index、SSH 授权结果以及内存释放核销。
执行与审计阶段遵照仓库技能工作流；
若必要条件缺失，交付明确的部分完成／No-Go，不伪称全面结束。
