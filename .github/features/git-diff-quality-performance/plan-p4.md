# P4：Git Diff 本机回归、远端数据与性能收口

**Goal：** 以本机 Swift XCTest、获授权 Windows SSH 实机、
实际构建与验签核销 P2／P3 的 Git Diff 字节、原生布局、
输入／保存、失败恢复和资源释放，不把未运行的完整 App GUI 声称为通过。

**Non-goals：** 不把自动化绿色等同发布；PR #78 已于 2026-11-05 合并，本阶段不再安排其合并；
不推送主分支、不修改用户数据、不重复实现普通 Git 操作或 `adaptive-large-files` 的 GB 级方案。

**Approach：** 先按当前 HEAD、现行 `docs/testing.md` 与真实调用链，逐项对照
`idea.md` 的条件矩阵、现有 XCTest 的**实际断言与执行记录**；有证据缺口才新增用例。
宿主验证 Git／TextKit／字节／资源，获授权 Windows SSH 在独立测试连接核对真实磁盘。
2026-11-11 用户确认本次 P4 以**本机测试通过**收口：沿用 `b76d4fa4` 的
955 项完整 Host 全绿证据，并在最终代码 `ae049476` 对受影响的 `NativeDiffTabTests`
136 项重新验证；再核对 Debug／Release、UI Target 编译和签名。
旧 CI 失败、独立 GUI 及旧系统性能证据保留但不再要求本轮补跑；
不额外建 WindowServer 首帧、30 次 GUI P95、虚拟机或重复测试框架。

**Acceptance：**
- 真实 Git 各比较来源的 old/new 与磁盘、Index、Git 命令一致；
  不因规范化、状态切换和重载出现虚假变更或草稿丢失。
- 通过本机 Swift XCTest 的真实原生字形、滚动、AX、折叠、编辑、Undo／保存、
  Split 和资源退出断言，结合已有真实 App GUI 历史证据；
  不以组件测试冒充最新版本完整 App GUI E2E。
- 首屏可见文字、滚动范围、输入、切标签和关闭后的资源释放，
  由相关 Swift XCTest 的结果断言；既有 P95／内存测量用于定位回归，
  不再要求独立 WindowServer 首像素、30 次冷热 GUI P95 或虚拟机。
- 记录**完整本机 Host 955 项在 `b76d4fa4` 全绿**，随后新代码限于原生布局与
  语法树释放测试，最终 `ae049476` 对受影响的 136 项复验（2 条 SSH 用例环境跳过，
  曾在前述授权完整 Host 中实际通过）；Debug／Release、UI Target 编译及验签全绿。
  未执行的完整 GUI、云端及旧版系统明确列出，不伪称通过。
  无新增旧双轨、临时调试改动和无主文档状态。

**Rules：**
- 不在用户正在使用的 Mac 桌面运行抢焦点 UIXCTest；
  本次 P4 不再启动新的独立 GUI runner 或虚拟机。
  现有 Windows SSH 授权只覆盖指定测试仓库，不扩展为任意远端操作。
- Windows SSH 测试只针对明确授权的专属目标、独立临时仓库；
  测试不借 SSH master，不操作工作中用户文件。
- 缺少必需条件必须分项说明影响及补验，不能用 `XCTSkip`、“反正主机测试通过”掩盖。
- 发现问题时沿当前调用链在**同一发现任务**修复真实 owner，必要时先 Red→Green；
  同时删除已证实无消费者的旧路径／重复状态，更新对应文档并原子提交、复测。
  P1–P3 已完成任务不重新伪造进行中状态，也不把旧代码清理留到 P4-T5。
  对仍有调用者或保护原始字节、SSH 目标、保存、取消、TextKit 资源的校验不得仅凭名称删除。
- 完整 App GUI 只验证宿主无法证明的前台响应者、快捷键、菜单／跨窗与真实保存；
  组件级像素／极端规模不重复在每个 UI 用例中跑一遍。

<a id="p4-t1"></a>
## P4-T1 核销所有 Git Diff 来源与文件／Index／历史完整结果

**结果：** 逐来源核对可信 OID、Git index/HEAD、Worktree 原始字节、Diff 渲染和保存结果；
以当前测试的真实断言核销已覆盖条件，只补证据缺口。

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
1. 先检查下列状态在 `NativeDiffTabTests`、`NativeGitHistoryFileTests`、
   `GitStatusModelTests`、`GitBrowsingRecoveryTests`、`GitExecutionTests` 的**实际前提和后置断言**；
   未覆盖的才用真实临时仓库创建：
   HEAD 对 Index、Index 对 Worktree、相同文件已暂存后再编辑、
   未跟踪、初始提交前、detached HEAD、Merge 冲突阶段 0／1／2／3、
   新增／删除／复制／重命名／mode-only、符号链接／悬空链接／子模块、
   历史对首父、两提交比较、Stash、历史原文、历史对 Worktree、
   多 Git Worktree 及相同相对路径不同机器／仓库。
2. 分清**Git 状态初次加载／文件事件刷新／远端轮询／当前缓存重用**与
   **Changes 行选择／Graph 选中历史文件／导航打开 Diff** 分开建立前提；
   1／100／10k 级状态项下核对当前行、所选机器及项目，避免列表性能掩盖单文件 Diff。
   对照 Git 命令和 OID，检查显示结果、行号、折叠、行内高亮、无变更判断，
   对应源是否具有安全写入资格、点击保存是否只写 Worktree；
   真实 `git diff --cached`、`git diff`、Index／磁盘字节均核对。
3. 按 `idea.md` 的适用条件逐项核销、缺口再补：SHA-1／SHA-256 仓库对象、
   `core.autocrlf` true／false／input（按系统适用）、
   `text/-text/eol`、clean filter、无末行 LF、LF／CRLF／裸 CR／Unicode 分隔符、
   UTF-8 BOM、代理对／组合字符／规范等价不同字节、空文件／仅换行、
   重复短行无唯一锚点／超长 SVG 行、多 hunk／全部删除、
   5 MiB 恰好和 ±1 byte、二进制／NUL／未声明的非 UTF-8 文本、
   Windows MBCS/CP936、手动选择编码、不可编码字符的拒写与 UTF BOM；
   真实 Git index stage 和文件原字节必须是测试已验证前提，
   不允许未经声明的空侧或错误状态冒充正常数据。
4. 测“文件外部改写→正在读取→用户编辑→用户保存→旧请求返回”，
   以及 Staged HEAD/Index 在两路并行元数据读取期间变更、
   HEAD/index 在 Git patch 读取期间变化、clean filter 修改实际文件、
   超大 Git stdout 被接收中断；旧结果不能影响当前项目、机器、路径和可写 buffer。
   核对关闭窗口后不向新窗口写入、脏草稿不被 Git 后台刷新抹除。

**验证：** 优先选现有的真实测试方法，例如
`make test ONLY_TESTING='BaileyTests/NativeGitHistoryFileTests/testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree'`；
受共享实现影响时扩大到上述相关类；完成本任务时按环境核对该任务覆盖的实际方法、
XCTest 结果、最终 Git/磁盘字节与跳过原因。不机械重复 `NativeDiffTabTests` 的全部性能测试。
完整 App 入口的旧版本 GUI 实测证据归 P4-T2 如实核销；
最终提交的真实前台选择、窗口焦点和 ⌘S E2E 在本轮未重跑。
Staged／Unstaged、Changes／Graph 来源及保存后的 Git／磁盘字节，
按本阶段授权范围以实际 Host 与既有 GUI 记录分别证明，
不重复创建四套 GUI 大规模矩阵。
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

**文档／提交：** 行为改变时在本任务同步 `docs/features/{diff,git}.md` 与受影响测试；
真实生产缺陷在当前 owner 修复并移除被替代路径，原子提交；仅核销证据不制造代码提交。

<a id="p4-t2"></a>
## P4-T2 核销已有 App GUI 证据与本轮验收边界

**结果：** 已有完整 App GUI 测试仅按实际运行的提交、系统和断言引用；
不把本机 `NSWindow`／原生像素宿主测试或 `make build:ui` 误称完整 App E2E。
2026-11-11 用户明确本阶段以本机 Swift 测试为完成依据，不额外启动
GitHub Actions GUI 或占用当前桌面，原 P4-T2 完整 GUI 矩阵退出本次门禁。

**核销：**
1. `WorkspaceGitUITests` 等历史真实 Bailey Dev 操作已有旧版本成功证据，
   但不可外推为最终 `ae049476` 的完整 GUI 验收。
2. 旧 SHA `c9111491` 的云端完整 UI Job 执行 225 项、8 跳过、
   26 个失败方法（40 条失败断言）；保留可追溯的真实失败，不按通过处理。
3. GitHub UI Job 真实源码历史夹具需要完整 Git 历史，
   已在提交 `5e4a7660` 修复 shallow checkout，并由本地浅／完整克隆实验证实；
   未在最终提交复跑云端 UI，不声称云端已绿。
4. `make build:ui` 在最终 `ae049476` 通过、退出码 0；
   原生字形、滚动、折叠 AX、键入与真实 Git／文件字节由受影响 Host 测试核对。

**未覆盖（用户接受为非门禁）：** 最终提交的完整 App 前台菜单、
第一响应者、跨窗快捷键和远端 GUI 断线／重连；
旧云端 UI 失败与用户前台现状之间的归因尚未全部完成。
不删或禁用现有 UI 测试、不放松断言、不称这些功能已通过 E2E。
详见 `evidence-p4.md` 与 `audit-p4.md`。

**文档／提交：** UI 测试夹具的历史前提修复在 `5e4a7660` 已提交；
本次只据实更新 Feature 计划、审计与测试边界，不为已豁免的 GUI 创建替代实现。

<a id="p4-t3"></a>
## P4-T3 核验获授权 SSH 实机数据与受控恢复

**结果：** 通过获授权 Windows SSH 实机宿主测试，核对远端文件来源、
原始字节、保存资格与模拟故障恢复；不以宿主模拟断线冒充完整 App 物理断网 GUI。

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
1. **先核销既有实机证据，不重建整套 SSH 夹具。** `idea.md` 已记录
   2026-11-09 授权 Windows SSH 16 项实际通过；后续 `a79c97c8` 增补真实 Split
   失焦自动保存回归，`162d1369` 修复专用 socket 误改共享连接状态。
   这些是当时提交的证据，不等于当前 HEAD 自动通过；本任务先核对变更影响再定点补测。
   用现有获授权 `BAILEY_P4_TEST_SSH_HOST=windows`，只创建经过路径验证的临时仓库，
   使用测试专属 socket；不得碰用户工作文件、master 或网络配置。
2. 复核 `NativeDiffTabTests.testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`
   的真实 `core.autocrlf=true`、`text/-text`、clean filter、CRLF Split、Unicode 失焦自动保存、
   Staged 只读与真实远端字节断言；新增
   `testAuthorizedWindowsSSHLegacyMBCSFileAndStagedDiffKeepCP936Bytes`
   直接验证独立 Windows 代码页、Staged/Worktree 和原字节保存，
   不能把真实 CP936 文本误判为 Binary file；`WorkspaceGitUITests.testAuthorizedWindowsSSHGitReviewThroughRealUI`
   已覆盖远端项目选择、规范化对照、编辑及 ⌘S 落盘。只补当前 HEAD 未覆盖的配置，
   不另造一套 EOL/filter 远端数据矩阵。
3. 沿 `GitCommandExecution.runData → SSHWorkspaceBackend.runLimited →
   SSHHostCommandRunner.execute → ProcessRemoteCommandRunner.launch` 核对实际字节预算、
   输出超限、异常 stderr、取消与超时；生产链已经有有界读取，不能为假定问题
   重建传输层或去掉真实上限。`SSHGitRecoveryLiveTests` 通过隔离 runner 模拟断连，
   已验证保留 Git 快照、拒写及恢复后重新暂存；它**不等于真实物理网络故障 GUI**。
   剩余缺口重点是完整 App 在远端失联／恢复、旧请求回写、切机及路径消失时，
   当前编辑草稿／连接状态与本机文件的真实结果，必要时增加针对性组件测试。
4. 有实测慢路径或内存回归才启动已有 `BAILEY_SSH_BENCHMARK=1`
   的 30 次测量／Instruments 定位；不无条件新增 SSH P95、慢速网络模拟、
   进程日志或首屏专用采样系统。

**验证：**
只对专属授权目录运行相关现有授权 live tests；
以现有真实方法选择器运行宿主测试，例如
`make test ONLY_TESTING='BaileyTests/NativeDiffTabTests/testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules BaileyTests/SSHGitRecoveryLiveTests/testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery'`；
`BaileyUITests/WorkspaceGitUITests/testAuthorizedWindowsSSHGitReviewThroughRealUI`
在最终代码未于独立 GUI 会话重跑，按用户当前验收决策记录为非门禁。
宿主测试选择器必须通过 Makefile 的原生枚举预检；
核对最终远端文件、Index、HEAD、
本机同名文件不变。执行超时、断线、重连、切别的窗口、远端路径改名／文件删除、
多标签切换与取消后旧结果不得发布。

**Uncovered：** 2026-11-05 的 Windows 连接超时和 16 项条件跳过已被
2026-11-09 的授权实机 16 项通过证据超越，不能继续列为现行阻塞。
尚不能从现有宿主／真实 SSH UI 用例推出**完整 App 在断线期间的隐藏／重开／跨窗、
保存失败后重连和过期结果**全已验收；`docs/testing.md` 已明确记录该限制。
本轮不再为此占用独立 GUI 会话；在 `evidence-p4.md` 逐项保留真实
断线期间的隐藏／重开／跨窗／过期请求未验收，**非 P4 本地门禁**。
不可把模型恢复用例冒充完整 App GUI。实机跳过仍须明确记作 skipped。

**文档／提交：** 合约变更在本任务更新 `docs/features/{diff,ssh}.md`
及 `docs/testing.md`；发现根因时连同旧路径清理、定点回归原子提交。
纯实机核销只记证据，不为提交制造产品代码。

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

**执行前新增实证（2026-11-10 GitHub Actions run `42792227500`，SHA `162d1369`）：**
Host 执行 941 项、16 skipped、11 条失败断言（2 unexpected）。其中 P4-T4 直接负责
`NativeDiffTabTests` 的 4 个失败方法，不能以本机绿色或系统版本不同直接豁免：
- `testFoldedEditorUpdatesSourceOffsetsWithoutRevealingHiddenParagraphs`：
  编辑后文档高度 330 vs 324，两个位置检查失败；核对 TextKit 布局和折叠隐藏数。
- `testFoldedNativeDiffScrollbarHasCompleteHeightBeforeDeepScrolling`：
  冷滚目标行不存在、展开后高度 16260 vs 17715、末行不可达；优先沿
  `setEditingFolds → NativeCodeTextView`、`applyContentHeightOverride → documentY →
  materializeNativeViewport/visibleRows` 核对真实行位置，不放宽断言或滚动补刷新。
- `testThirtyColdParsesAndTenSyntaxOwnersReleaseTheirTrees`：弱引用虽释放，
  `malloc` 释放后超出基线 117095 KiB（阈值 32768 KiB）；区分真实树/缓冲存活、
  parser allocator 缓存与 CI 进程内其它持有者，不能只调高内存阈值。
- `testWorktreeFoldedEditorKeepsFoldsOnClickAndExpandsOnlyOnSeparator`：
  展开后 AX 折叠标签更新等待超时；区分真实未更新与测试只检查首个标签的假设。
以上是旧于当前 HEAD 的真实失败证据，**不是当前 HEAD 已复现的结论**；
上述旧 CI 失败的修复已用本机真实 TextKit 与解析树生命周期回归验证；
同系统 CI 复验不在本次用户确定的验收范围，不以本机转绿宣称旧 CI 已复现通过。

**步骤：**
1. 核对测试所用提交、Swift/Xcode 版本、Git 夹具和运行环境，
   已有同配置的成功证据可复用，不为形式重复执行。
   针对代码变更重新运行实际受影响的 XCTest，检查测试数量、跳过与退出码。
2. 对照现有 `NativeDiffTabTests` 的十万行折叠／非折叠冷滚动、
   17 次深处跳转、稀疏长行、CR／Unicode 原生段落、Ghost、末尾空行、
   明暗颜色和像素断言，核对**确实检查了原始文字、滚动末端和段落命中**。
   再对照 Staged／Unstaged、空／1k／24k 文件；缺少的组合才增补针对性测试。
   宿主离屏 AppKit 位图不能冒充独立 App 的前台用户操作。
3. 复核 `testNativeDiffInputCostsAndUndoByteIntegrityMatrix`、
   `testTwentyTrueDiffClosesReleaseLayoutsEvenWithCachedScrollViews`、
   `testFoldedNativeCommandsMatchFullDocumentAndSaveExactBytes`、
   以及 Shared Editor 的 `NativeEditorLayoutTests` 与 `TextCoordinateIndexTests`：
   输入／Undo、结构编辑、主题／字体、Split 同步、实时 LF/UTF-16 坐标、
   语法资源在对应版本是否一致。只对真实缺口补测；现有原生性能指标用于诊断，
   不新增 WindowServer 精确帧捕获、冷热 GUI P95 或额外 profiler 门禁。
4. 对照 `Project.remove/terminateAll → DiffTab.retireNativeSurface →
   DiffNativeSurface.retireNativeDocument` 与临时 `dismantleNSView` 的不同生命周期；
   核对标签、项目、窗口真关闭和 Dock 重挂载的现有测试是否保留／释放唯一正文、
   Undo、布局与语法资源。Git／SSH 取消核对进程和字节读入边界，不能只看代次失效。
   有真实性能／泄漏失败再用 Instruments 找根因，不重复建一套测量平台。
5. App 级输入、焦点、保存和 AX 的历史证据由 P4-T2 单独记录；
   本轮以本机原生 TextKit／文件／Git XCTest 的实际后置断言验收，
   不将未执行的最新完整 App GUI 计作通过。不占用用户工作桌面或创建虚拟机。

**验证：** 优先选择上述已存在的具体 `BaileyTests` 方法，并在修改
TextKit／共享行索引时扩大到 `NativeDiffTabTests`、`NativeEditorLayoutTests`、
`TextCoordinateIndexTests`、`NativeContentIdentityIntegrationTests`、
`NativePaneRetentionIntegrationTests` 和 `DiffEngineTests` 的受影响集合；
历史完整 App 用户动作由 P4-T2 按当时版本独立记证，
本轮最终提交的 GUI 未验证内容明示为非门禁。
所有通过证据记录具体提交、执行数量、失败／跳过项、退出码和真实副作用。
如无新产品代码变化，不重复运行全量构建；P4-T5 按本机旧版完整
Host 与最终受影响范围的定点回归分别核销，并明示 SHA 不一致。

**Uncovered：**
真实 SSH、输入法等环境不可用时按 `idea.md` 记录适用缺口；
旧系统实机、独立 GUI 帧捕获或虚拟机都不构成本轮验收门禁。

**文档／提交：** 修改实际契约时在本任务同步 `docs/features/{diff,editor}.md`
与 `docs/testing.md`，删除失效的同职责旧路径后定点回归并原子提交；
纯测试核销或性能证据不制造代码提交。

<a id="p4-t5"></a>
## P4-T5 本机回归、源码与计划双向审计及交付判定

**结果：** 当前 HEAD 对应的全部必须条件能逐项追溯，
没有未提交旧路径、虚假完成声明、未处理冲突或损坏正式用户环境。

**Files／责任归属：**
本 feature `idea.md`、`todo.toml`、各 `plan-pX.md`；
现行 `docs/features/diff.md`、`docs/features/editor.md`、
`docs/features/git.md`、`docs/ui.md`、`docs/architecture.md`、`docs/testing.md`；
真实受影响的 `Bailey/Git/`、`Bailey/Editor/` 与现有测试；
`Makefile` 和当前 Git PR。

**步骤：**
1. 对照 P1–P3 的实际代码与 Git 历史复核替代路径是否已删除；
   **不能等待本任务才清理**：T1–T4 每次发现无消费者的旧状态／兼容层／重复流程，
   当场在真实 owner 删除、迁移测试与文档并原子提交。
   本步骤只复查是否仍有遗漏；不因 `review` 命名删除 Git clean filter
   所需的规范化只读比较，也不删除 OID、符号链接、目标身份、保存队列、取消
   及原生 TextKit 生命周期的可达正确性边界。
2. 对照 `idea.md` 的完整来源／状态／文本／显示／编辑／时序／性能矩阵，
   核销 Changes／Graph 刷新、非折叠深处行号、远端 `stdoutLimit` 真正限流、
   编辑事件、**Staged 跨代 HEAD/Index、取消后底层进程停止、真关闭原生文档退役**。
   已删除且无生产消费者的字段不重新列为待实现任务。
   所有适用值和极端条件有精确测试入口、有效前提、可见结果及环境证据；
   未执行者列原因、影响、替代证据与必需补验，
   无法完成必需路径则明确 **No-Go**。
3. 本轮用户验收决定：保留 `b76d4fa4` 的本机授权完整 `make test`
   **955 项／0 失败／0 跳过／退出 0**；后续仅改动 `DiffFixedRowFragment`
   与原生语法资源测试，在最终实现提交 `ae049476` 重新运行受影响的
   `NativeDiffTabTests` **136 项／0 失败／2 项 SSH 条件跳过／退出 0**。
   此处是“旧提交完整 Host ＋新提交受影响类”的证据组合，
   **不是最终 SHA 的完整 955 项再次执行**；跳过的 2 项在旧授权 Host 已实际通过。
   `ae049476` 的 `make build`、`make build:ui`、`make build:release`
   以及正式 Debug／Release 签名验证均通过、退出码 0。
   在本次限定的本机范围内不追加完整重跑，未测条件逐项记录。
   旧 macOS 27.0.1 的首次布局超 200 ms、GitHub GUI 失败和远端完整 App
   断线／跨窗均属于尚未复验事实，已由用户明确排除本次 P4 门禁；
   不推断这些问题已经修复，也不关闭或禁用相应 XCTest。
4. P4 预审不构建、安装或重启正式 App。进入实施收口后按
   `docs/development.md#本地安装` 的适用授权与验签规则处理，
   **不主动退出或重启正在运行的正式 Bailey**；已构建／验签／安装／重启／发布分别报告。
5. 检查受影响文档 owner、链接与锚点、`git diff --check`、
   `feature_tool.py todo validate`、每次生产修复的原子提交和复测；
   `todo.toml` 仍为唯一实时状态，不建第二份看板、不凭历史 `audit*.md` 下结论。
6. 只复核 `adaptive-large-files` 是否**实际改动了当前共享源码**；
   有真实交叉依赖才补对应集成测试，未实施不阻塞当前 5 MiB Diff。
   PR #78 已合并，不再安排重复 PR／合并；无明确授权不推送主分支。

**验证与退出：**
`b76d4fa4` 完整 Host 955 项全绿、`ae049476` 受影响原生 Diff 全类
136 项全绿（2 项 SSH 条件跳过，已有授权实机通过记录）；
`ae049476` 的 `make build`、`make build:ui`、`make build:release` 与正式签名通过，
另有真实 SSH 读取、编码与故障注入结果；`git diff --check`、
`feature_tool.py todo validate` 通过。
本次不重复运行完整 GUI／旧系统云端验证，不把未执行项目记成通过。
只因新的生产修改影响验证范围时才重跑受影响项目；本次仅更新计划不重构 App。
阶段审计使用既有 `audit-p4.md`。

**Uncovered：**
Windows SSH 可达性、系统 GUI 自动化认证、资源安全上限、
其它项目仍执行的大文件分段功能，
必须分别说明是阻塞当前 Diff 本身还是跨 feature 非目标；
不能用“宿主 0 失败”统一抹掉。
**文档／提交：** 仅归集真实证据与缺口；代码根因修复和旧路径清理
发生在发现该问题的 T1–T4 同次变更中，不为收尾建立兼容壳、额外协调者或永久诊断框架。

## 完成 Gate

2026-11-11 用户确认以本机 Host 的完整基线和最终改动的定点回归、
获授权 Windows SSH 实机、Debug／Release 构建验签作为 P4 收口依据。
此范围内核验 Git 原文字节／Index、原生 TextKit 像素、滚动、输入、保存、
异常恢复与语法树释放后，阶段 Gate 可以为 `Go（本机范围）`。
最新 SHA 的完整 App E2E、旧系统与云端失败未重新验证，
单独保留风险说明，不虚构全面 GUI／跨环境通过。
