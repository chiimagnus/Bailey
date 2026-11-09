# P4：跨来源完整用户验收、远端场景与性能交付

**Goal：** 通过 `BaileyTests` 和必要的 `BaileyUITests`，
验证 P2／P3 的原生组件与完整 Bailey Dev 用户结果；核销原始字节、
渲染／输入、失败恢复以及现有性能和资源释放回归。

**Non-goals：** 不将自动化通过冒充已发布；不擅自合并 PR #78、推送主分支或更改用户数据；
不重复设计普通 Git 提交／Reset 或独立 `adaptive-large-files` 的 GB 数据模型。

**Approach：** 先由宿主 Swift XCTest 覆盖真实 Git、TextKit、AX、字节和资源边界，
再在 GitHub Actions 的隔离 macOS runner 上执行必要的完整 App `BaileyUITests`，
并核销获授权的 Windows SSH 与最终版本构建／测试、文档和源码审计。
现有性能日志用于诊断，不额外构建 WindowServer 精确首帧／30 次 GUI P95 测量流程。

**Acceptance：**
- 真实 Git 各比较来源的 old/new 与磁盘、Index、Git 命令一致；
  不因规范化、状态切换和重载出现虚假变更或草稿丢失。
- 真实完整 App 下折叠、行号、删除 ghost、Split 同步、浮动／传统滚动条、
  高亮、AX、输入、保存、恢复和焦点全部符合 `idea.md`。
- 首屏可见文字、滚动范围、输入、切标签和关闭后的资源释放，
  由相关 Swift XCTest 的结果断言；既有 P95／内存测量用于定位回归，
  不再要求独立 WindowServer 首像素、30 次冷热 GUI P95 或虚拟机。
- 全量测试、构建、签名、适用 GUI E2E 与远端缺口记录对应**最终提交版本**，
  无未解释回归、旧双轨、临时调试改动和无主文档状态。

**Rules：**
- 不在用户正在使用的 Mac 桌面运行抢焦点 UIXCTest；必要的完整 App UI XCTest
  优先在 GitHub Actions 隔离 runner 上进行，不创建 macOS 虚拟机。
  现有 Windows SSH 授权只覆盖指定测试仓库，不扩展为任意远端操作。
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
`NativeGitHistoryFileTests.testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`
已覆盖 SHA-256 基本 OID 流程，若扩大测试只补其不足，不重复造已有夹具；
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
3. 逐项组合 SHA-1／SHA-256 仓库对象（后者已有真实 Git 回归基础）、
   `core.autocrlf` true／false／input（按系统适用）、
   `text/-text/eol`、clean filter、无末行 LF、LF／CRLF／裸 CR／Unicode 分隔符、
   UTF-8 BOM、代理对／组合字符／规范等价不同字节、空文件／仅换行、
   重复短行无唯一锚点／超长 SVG 行、多 hunk／全部删除、
   5 MiB 恰好和 ±1 byte、二进制／NUL／非法 UTF-8／编码错误；
   真实 Git index stage 和文件原字节必须是测试已验证前提，
   不允许未经声明的空侧或错误状态冒充正常数据。
4. 测“文件外部改写→正在读取→用户编辑→用户保存→旧请求返回”，
   以及 Staged HEAD/Index 在两路并行元数据读取期间变更、
   HEAD/index 在 Git patch 读取期间变化、clean filter 修改实际文件、
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
`BaileyUITests/Git/{WorkspaceGitUITests,GitChangesUITests,GitHistoryUITests,GitGraphUITests}.swift`、
`BaileyUITests/Support/WorkspaceUITestSupport.swift` 的启动／焦点／输入辅助函数、
`BaileyTests/Git/NativeDiffTabTests.swift`。

**步骤：**
1. 在 GitHub Actions 独立 macOS runner 上启动 `chiimagnus.bailey.dev`，
   使用测试专属 Git 临时目录，验证 XCTest 真正启动 App 并完成目标动作。
   不在当前用户桌面抢焦点、修改个人系统外观／剪贴板或创建虚拟机。
   若测试输入合成失败，保留日志并区分 runner、夹具与产品错误，
   不通过 `sleep`、禁用焦点断言或吞事件制造绿色。
2. 真实 Git Changes、Git Graph、历史原文、Staged／Unstaged 快速切换、
   同文件多次打开、外部刷新、Dock 重挂载、多窗口选择、切文件及关窗恢复逐一操作。
   看得到文字与真正能输入、第一响应者属于哪个窗口是两项不同结果。
3. Unified／Split、普通 Worktree 可编辑／Staged 与历史只读／clean filter
   规范化只读对照和原始 Worktree 并列、明暗／高对比、
   两种原生滚动条风格、普通／完整长行设置，
   窄／宽窗口、顶部／中部／深处滚动／无变更非折叠深处，
   折叠按钮层级与 AX Press 实际坐标、长删除 ghost、
   语法色及词级强调、视口恢复、字体/主题切换；
   原生文字像素和几何由 `BaileyTests` 断言，完整 App 交互由必要的 UI XCTest 断言，
   不另外要求人工截图矩阵或 WindowServer 精确帧捕获。
4. 实际文本操作：普通输入不自动展开、手动折叠逐段展开、
   跨隐藏选区（端点落在可见区／隐藏区／文末）、粘贴、剪切、`⌘A`、Find/Replace、
   Undo/Redo、中文 IME 提交、`⌘S`、失焦自动保存、
   在途保存新增编辑、保存失败及关闭恢复；
   断言光标、可见内容、磁盘精确字节、Git 工作区状态与 Index 未意外改变。
5. 审查可视标记和 AX 树是否真实可点击，
   无按钮／空状态的只读 Diff 不声明可编辑；
   Changes 右键仅改变操作目标而不误触发 Diff 打开或其他组焦点，
   右键菜单期间快捷键作用于当前第一响应者而非后台窗口。
6. **专门追查已发生的 GUI 偶发失败，不以复测成功结案：**
   `build/git-diff-verified-hunks-ui.log` 中
   `WorkspaceGitUITests.testWorktreeDiffEditsAndPersistsRealGitFile`
   在 `WorkspaceGitUITests.swift:483` 的 `app.typeKey("s", modifierFlags: .command)`
   报 `Failed to synthesize event: Timed out while synthesizing event`，
   后续同组五用例复测成功。保留失败和成功日志，核对发送前
   Bailey Dev 是否为前台、原生 `NSTextView` 是否为第一响应者、
   UI Runner 的真实会话／键盘授权、菜单处理和在途 Diff 任务；
   用相同 App、相同测试顺序、单例和随机交错顺序进行连续复测，
   分清**XCTest 系统输入合成失败／测试夹具焦点问题／Bailey 产品事件问题**。
   若是产品或测试代码问题，回对应 owner 做 Red→Green 并重跑；
   如果只有系统合成失败证据，不修改产品添加 sleep、盲目重发或强制抢焦点。
   无法归因且仍不稳定时明确留作阻塞，绝不能因下一次绿色而抹去。
   P1 另有一次 Peekaboo `⌘Z` 回执成功但后续部分 AX 正文出现 `Q z`、
   未观察到撤销的现象，且之前 `type` 回执失败但输入实际生效；
   需用独立 XCTest 验证真实命令键、第一响应者与完整正文／Undo／Redo，
   排除自动化注入及输入法因素，证据见 `evidence-p1-status-events.md`。

**验证：**
`make build:ui` 仅负责确认 target 可编译，随后使用
`make test:ui` 的受影响 `BaileyUITests` 选择器执行真实完整 App 路径；
`make test:NativeDiffTabTests,NativeContentIdentityIntegrationTests,NativeEditorCompositionTests`
保留极端原生像素、IME、AX 组件级断言，
不重复整套 GUI 大规模数据矩阵。
每个失败对应截图、AX frame、前台进程、XCTest 日志与真实磁盘结果；
`testWorktreeDiffEditsAndPersistsRealGitFile` 至少做同样本连续重复回归，
并与其所在五用例全组重复执行互证；记录失败率、事件前后焦点、
保存命令是否实际发出及文件最终原字节，不以测试运行成功率代替保存结果。
单次合成超时须先归因并保留证据，不能直接定性为 Bailey 产品或系统故障；
无证据的重复超时不能宣称已解决。

**Uncovered：**
真实 macOS 15.6 与不可授权的系统候选输入测试按 `idea.md` 列明具体条件。
GitHub Actions 中必需的 GUI XCTest 若未执行或失败才形成当前范围的验收缺口；
不以用户桌面焦点或额外虚拟机可用性作为阻塞理由。

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
1. 先复核现有获授权的 `windows` 目标可达，
   通过既有 `BAILEY_P4_TEST_SSH_HOST` 选择目标，由 live fixture 创建并严格校验自有临时 Git 路径，
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
现有 Windows SSH 已获授权，但独立连接和显式 live test 均在连接阶段超时；
不得改动用户网络配置或借用活跃 master 来绕过，新增目标仍须相应授权。
具体影响是 Windows EOL/filter、
真实传输延迟与断线安全尚无闭环证据，
仅有受控后端替代测试且该场景不得无保留验收。
在 2026-11-05 19:47 的完整宿主测试（`a9fdb51b`）中，16 项因未传 SSH 目标参数跳过；
本轮显式提供授权目标的 Diff live test 实际执行后失败，不得改写成通过或跳过。
直接 Git Diff：`NativeDiffTabTests` 1 项，涉及 EOL、clean filter 与远端保存。
Git 状态／连接恢复：`GitRemoteRefreshIntegrationTests` 和 `SSHGitRecoveryLiveTests` 各 1 项，共 2 项。
相邻 Git Worktree／Ref：`GitWorkspaceSSHTests` 2 项；项目索引 `ProjectFileIndexTests` 1 项。
其它 10 项分别为交互式变基 1 项、SSH Files 4 项、Windows Files 事件 5 项，
属于全仓实机缺口而非 Git Diff 单项的全部阻塞。
合计 1+2+2+1+10=16；关联 Git Diff 的场景需在获准 Windows SSH 测试仓库补验，
不可把 skipped 计为 passed。

**文档：** `docs/features/diff.md` 与 `docs/features/ssh.md`
只有生产契约改变时在对应实施 owner 更新；
本任务保存实际测试环境与证据。
**提交：** 实际发现功能问题则返回 P2/P3 owner；
无新行为的实机核销不为提交而写代码。

<a id="p4-t4"></a>
## P4-T4 以 Swift XCTest 核验首屏、编辑、滚动与资源释放

**结果：** 以可执行的 Swift XCTest 证明首屏、输入、滚动、原生退役和资源释放
没有回归，而不是额外建立图形帧捕获或性能评测体系。

**Files／入口：**
`DiffCodePaneView.layout/applyContentHeightOverride`、
`DiffNativeSurface.editTextDidChange/render`、
`DiffTab.reload/invalidateReload/deinit`、`Project.remove/terminateAll`、
`DiffSyntaxSource.captures`；
现有 `BaileyTests/Git/NativeDiffTabTests.swift`、
`BaileyTests/Editor/NativeEditorLayoutTests.swift`、
`BaileyTests/Editor/TextCoordinateIndexTests.swift`、
`NativeContentIdentityIntegrationTests` 和 `NativePaneRetentionIntegrationTests`。

**步骤：**
1. 核对测试所用提交、Swift/Xcode 版本、Git 夹具和运行环境，
   已有同配置的成功证据可复用，不为形式重复执行。
   针对代码变更重新运行实际受影响的 XCTest，检查测试数量、跳过与退出码。
2. 对空／1k／24k／100k Git 行、Staged／Unstaged、LF／CRLF／裸 CR／Unicode、
   长行折行、删除 Ghost、折叠及编辑／只读，断言首次正确文字像素、
   滚动条完整高度、17 次远跳和末行命中。
   本机 AppKit 位图测试是有效的 Swift 组件测试，不冒充完整 App 用户操作。
3. 文首／中／末输入、Undo／Redo、删除／新增换行、语法重绘、字号／宽度变化、
   切 pane 和 Split 同步，以 Swift XCTest 断言最终原文、选区与几何。
   已有 30 次原生组件 P95 日志只作诊断，不新增 WindowServer 首像素、
   30 次冷热 GUI P95、固定 FPS 或独立 Profiler 放行要求。
4. 关闭标签、项目与窗口以及 Dock 重挂载，使用现有宿主 XCTest
   核验旧原生视图不保留可写全文、Undo 或语法任务，工作中编辑器不误退役。
   取消 Git／SSH 读取必须核验实际进程终止和字节接收边界；
   若测试出现真实性能或泄漏失败，再以 Instruments 定位根因。
5. 必需的 App 级输入、焦点、保存及 AX 动作复用 P4-T2 的
   `BaileyUITests`（GitHub Actions 独立 runner）。不得在用户工作桌面抢焦点，
   不创建 macOS 虚拟机。真实失败回对应源码 owner 修复并复测。

**验证：**
`make test:NativeDiffTabTests,NativeEditorLayoutTests,TextCoordinateIndexTests,NativeContentIdentityIntegrationTests,NativePaneRetentionIntegrationTests,DiffEngineTests`；
必要的 App 用户操作通过 P4-T2 `make test:ui` 选例核销。
所有通过证据记录具体提交、执行数量、失败／跳过项、退出码和真实副作用。
如无新产品代码变化，不重复运行全量构建；最终全量归 P4-T5。

**Uncovered：**
未获授权的真实 SSH 或旧版 macOS 环境按 `idea.md` 明确记录，
但缺少独立 GUI 帧捕获或性能虚拟机不构成当前验收缺口。

**文档：** 产品行为或测试契约实际变化时同步其单一文档 owner，
既有性能曲线保留在本 feature 证据，非强制验收门禁。
**提交：** 新增必要 Swift 回归或修复根因时原子提交；纯证据／计划更正保留本地。

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
   `stdoutLimit` 真实传输预算、文本变更前后回调、
   **Staged 跨代 HEAD/Index、取消后底层进程停止、Diff 原生文档真关闭退役**
   与已清除的测试专用旧字段。
   所有适用值和极端条件有精确测试入口、有效前提、可见结果及环境证据；
   未执行者列原因、影响、替代证据与必需补验，
   无法完成必需路径则明确 **No-Go**。
3. 以**最终实现提交**运行完整 `make test`，核对 XCTest 总数、
   跳过原因、完整 Make 命令状态。
   目前执行前清理提交 `a9fdb51b` 已完成新一次完整宿主测试：
   `build/git-diff-preflight-full-host-after-cleanup.log`，843 项、16 项授权 SSH 跳过、
   0 失败（2026-11-05 19:47 完成）；它有效证明此清理版本的宿主回归，
   **不能代替 P2/P3 未来代码改动后的最终 HEAD 全量测试**。
   16 项实际归属已在 P4-T3 逐项分类；未执行的相关 Windows SSH 实机不可计入通过。
   2026-11-09 较新的 GitHub Actions 完整宿主作业在
   `GitStatusModelTests` 和 `RemoteCommandsTests` 出现失败，
   有一次选择性 UI 作业 XCTest 已输出 1 项通过，但结果摘要检查得到 `unknown` 而失败。
   P4-T5 必须核对对应提交、runner 和原始 `.xcresult`，
   区分实际测试错误与 CI 结果读取错误；不能用旧的 9 项 UI 绿色覆盖这些失败。
   执行 `make build`、`make build:ui`、适用 `make test:ui`；
   在 GitHub Actions 独立 runner 上运行受影响的 `BaileyUITests` 选择器；
   全量 UI Target 仅在最终明确需要时执行，选择性成功不冒充全量绿色。
   未执行的方法、失败和影响须记录，不能用宿主测试替代必需的真实用户操作。
   功能优化仍核对适用的 `make build:release` 与现有 Swift 资源回归；
   不要求额外独立 GUI 性能仪器或冷热 30 次 P95 才能交付。
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
`make test:ui` 的适用用户路径（包括此前 ⌘S 合成失败用例的归因与回归）、
适用的 `make build:release` 与 `codesign`、
`git diff --check`、`feature_tool.py todo validate`；
所有统计与当前 HEAD 一一匹配。
任何新产品修复先回 owner 重测，再重新跑受影响项目及最终全量验收。
阶段审计实际开始才生成 `audit-p4.md`。

**Uncovered：**
真实旧系统、Windows SSH 可达性、系统 GUI 自动化认证、
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
