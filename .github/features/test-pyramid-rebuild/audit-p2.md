# Audit P2 - test-pyramid-rebuild

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/test-pyramid-rebuild/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 宿主承接 Git Dialog 原生表单与真实 Git
- [x] P2-T2 宿主承接 Git Graph 几何与原生绘制
- [x] P2-T3 宿主承接 Git Changes History 等重复 UI
- [x] P2-T4 宿主承接 Files Editor 原生组件与数据验证
- [x] P2-T5 宿主承接 Workspace 生命周期与系统边界

## 任务到文件的映射

- P2-T1 (`6506193`)
  - `Bailey/Git/{GitBranchDialog,GitTagDialog,GitPanel}.swift`
  - `BaileyTests/Git/{GitNativeDialogTests,GitRemoteBranchActionTests}.swift`、`BaileyUITests/Git/GitDialogUITests.swift`
  - `docs/features/git.md`、`docs/testing.md`
- P2-T2 (`d7b55e0`)
  - `BaileyTests/Git/CommitGraphLayoutTests.swift`
  - `BaileyUITests/Git/{GitGraphGeometryUITests,GitGraphUITests}.swift`
  - `docs/features/git.md`、`docs/testing.md`
- P2-T3 (`2bef5a9`)
  - `BaileyUITests/Git/WorkspaceGitUITests.swift`
- P2-T4 (`300e087`)
  - `BaileyTests/Editor/NativeSyntaxHighlightingTests.swift`
  - `BaileyUITests/{Editor/EditorHighlightingUITests,Editor/EditorNavigationUITests,Files/WorkspaceFilesUITests}.swift`
  - `docs/features/editor.md`、`docs/testing.md`；`SharedTreeUITests` 8 项逐一复核后保留
- P2-T5 (`46d1e71`)
  - `BaileyUITests/Workspace/{WorkspaceRetentionUITests,WorkspaceWindowsUITests}.swift`
  - `docs/features/editor.md`、`docs/testing.md`

## 发现项

## 发现 F-01

- 任务：`P2-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/Editor/NativeEditorLayoutTests.swift:85-89`
- 摘要：`P1 合并宿主测试目录后使用 #filePath 上溯四级，遗漏同步更新资源路径深度，全量宿主测试读取不存在的 FileTreeModel.swift`
- 风险：`全量 make test 的原生编辑器真实源码视口回归失败，阶段测试门禁不能通过`
- 预期修复：`将当前源文件相对 #filePath 的仓库根目录上溯由四级改为三级，继续读取原有生产 FileTreeModel.swift；保留全部视口及命中断言`
- 验证：`make test ONLY_TESTING=BaileyTests/NativeEditorLayoutTests/testCurrentSourceFileKeepsCorrectViewportAndHitTesting; make test:NativeEditorLayoutTests; make test`
- 解决证据：`d7d374d: 旧路径由 P1 目录迁移的四级回溯导致，改为三级；make test:NativeEditorLayoutTests (28/28) PASS，原失败 testCurrentSourceFileKeepsCorrectViewportAndHitTesting PASS。`


- 本轮审计发现 1 项真实可复现的全量测试门禁错误（`F-01`），已定位根因并在 `d7d374d` 以单个路径层级调整修复；未另建无证据的防御代码或额外抽象。

## 修复日志

- 审计修复 `d7d374d`：P1 宿主测试目录移浅一层后，调整 `#filePath` 回溯深度，恢复真实生产源码文件夹夹具；`make test:NativeEditorLayoutTests` 28/28 通过，包含原失败项。
- 已在 `46d1e71` 的 amend 中排除误暂存的本地 `todo.toml`，保留原任务数据和独立代码提交。

## 验证日志

### 源码、职责与真实覆盖

- 代码基线：`6506193^`（`99be1e5`）到 `46d1e71` 的五项 P2 代码/文档任务提交（19 个变动文件），另加独立审计根因修复 `d7d374d`（1 个测试文件）；此前非本次 P2 的分支文档整理不混入审计。
- 源码法定数：`BaileyTests` 47 个文件、**559** 个测试方法（P1 的 549 加本阶段 10 项）；`BaileyUITests` 16 个测试类、**116** 个方法（P1 的 133 净删 17）。133 项原有 UI 方法逐条对应到附录；18 个旧方法名消失，其中 1 项 Branch Rename 改名并缩小职责，另 17 项是真正删除，未把改名当成删减。
- 已逐个检查 `BaileyUITests` 每个 `private func` 的使用，未发现零消费者 helper；保留 `SharedTreeUITests` 全 8 项真实 Dock 命中、菜单、滚动、Git Stage 和焦点测试；保留真实本地化、跨窗口 Sheet、Finder/LaunchServices、真实 Shell/Browser、退出保护等无法由宿主自动代替的入口。
- P2-T1 `6506193`：`make test:GitNativeDialogTests,GitRemoteBranchActionTests` **24/24**，真实 `NSAlert` 默认值、Delegate/Target、远端选择；真实 Git 验证过期 Fetch 目标、Force 保护与重新确认；`make test:ui ONLY_TESTING=...` **3/3**，Branch Rename／Remote Fetch+Pull／Tag Push 真正作用于选中 Git 仓库。
- P2-T2 `d7b55e0`：图谱宿主四类 **39/39**，宽度 48～800 pt、字号包括 9/14/18、0～1,000 车道；7 项 GUI 初测 **6/7**，唯一失败由系统 Control Center 弹窗抢占测试拖动并使 XCUITest 异常读取弹窗 AX 按钮快照，随后单独复跑该五档 Dock 宽度六处命中用例 **通过**；新增保留的 9 pt 24-lane 图谱真实 GUI **通过**。合计 **8 项不同图谱 UI 路径最终通过**，不是删掉失败断言。
- P2-T3 `2bef5a9`：`make test ONLY_TESTING=BaileyTests/GitStatusModelTests/testRecentCommitsKeepMergeParentsAndTypedReferences` **1/1**；保留的两条 WorkspaceGit GUI **2/2**，涵盖独立仓库、真实 Diff 编辑／Undo／Redo／写盘。
- P2-T4 `300e087`：宿主精确选择 **3/3**，Markdown/TSX/HTML/CSS 真正 `NativeCodeTextView` TextKit 染色和正文、10 万行文件加载与原生编辑/释放；保留的 Editor／Files／共享树 GUI **8/8**，包含 Swift 像素、远距按键、Unicode Undo/Redo、Files 同名两目标各自保存、中文长路径、文件树整行命中及 Git Stage 按钮无误击。
- P2-T5 `46d1e71`：宿主 **5/5**，五文件原生编辑器弱引用/释放、外部文件路由与跨窗、失败保存与会话快照；保留的 Workspace GUI **5/5**，真实 `⌘,` 打开设置、重启恢复主题、`⌘W` 只关闭设置、失败保存 `⌘Q` 不退出、成功保存后退出与重新打开、LaunchServices 去重/跨窗和窗口重启文件复原。
- 六份真实 UI 运行日志逐项解析后共有 **26 项唯一 `Class.testMethod` 通过**。该数字指本阶段实际定点运行，不是声称全部 116 UI E2E 均已完整跑过。
- 所有五项相关 `make build:ui` 均成功。独立 Debug Dev `Bailey.app`（Bundle ID `chiimagnus.bailey.dev`）及 `BaileyUITests-Runner.app` 在 Xcode 枚举完成、产物稳定后的 `codesign --verify --deep --strict` **均通过（退出码 0）**，Apple Development 签名、与正式 `/Applications/Bailey.app` 不同身份；正式 App 从未被停止、替换或安装。一次与 Xcode 枚举构建并行的签名核验曾提示资源目录正在变化，等待枚举结束后复验两份产物均通过，没有证据表明签名产物本身有缺陷。
- 本机环境 macOS **27.2**、arm64、Xcode **27.2**。`docs/testing.md`、`docs/features/git.md`、`docs/features/editor.md` 受影响归属已同步，相关 Markdown 相对链接审计 **0 断链**，`git diff --check` 通过。未新增 Target、兼容层、只为测试而写的业务抽象或多余登录环境保护。

### 阶段全量回归与受限条件

- 第一轮 `make test`：**559 项、8 skipped、1 failure、退出码 2**；唯一失败是 `NativeEditorLayoutTests.testCurrentSourceFileKeepsCorrectViewportAndHitTesting` 按旧 `#filePath` 深度读取不存在的文件。审计 `F-01` 在 `d7d374d` 根因修复后，`make test:NativeEditorLayoutTests` **28/28、0 failures、退出码 0**。
- 修复后最终 `make test`：**559 项、8 skipped、0 failures、退出码 0**，XCTest 总耗时 462.3 秒，`** TEST SUCCEEDED **`，且原来失败的真实源码视口测试在此全量中 **passed**。本轮全量运行无新增代码改动。
- `Bailey-UI` 全部 116 项：已用 Xcode 原生 `-enumerate-tests -test-enumeration-format json` **成功枚举 116 项、16 个 XCTest 类、0 重复标识，退出码 0**；**不是全量执行通过**。本机实际通过 26 项受影响的定点真实 GUI。完整 UI CI 需要分支推送并创建 PR 后触发；本轮审计截止时未执行，不能冒称已通过 CI。
- 真实 Windows SSH：首次全量回归的 **8 个 `skipped` 方法已逐项清点**：`GitInteractiveRebaseIntegrationTests`（1：双会话交互 Rebase）、`GitRemoteRefreshIntegrationTests`（1：实际远端变化）、`GitWorkspaceSSHTests`（2：Ref/归档/二进制/重置/储藏/清理及工作树管理）、`SSHFileTreeLiveTests`（3：目录批查询/失败隔离、文件 10 万行与字节保存、重命名）、`SSHGitRecoveryLiveTests`（1：真实 Git 断线恢复）。全部需要明确授权的 Windows SSH 测试主机和 `BAILEY_P4_TEST_SSH_HOST`；本机未获该授权，不借用用户的 Windows SSH。模拟和本机 Git 路径不能冒充真实 SSH 验收。
- macOS 15.6 真机、实体触控板、与当前主显示器不同的设备、实体中文输入法候选：本机条件缺失；保留现有 E2E／原生测试覆盖替代维度，正式发布前仍须在目标条件单独验证，不将其称为本轮完全验收。
- P2 测试归属重构没有生产性能收益的前后可比计时。本阶段仅证实减少了 17 条完整 App 自动化启动路径，**不虚构速度或内存改善百分比**。需要按 CI 全量结果另测跨版本耗时。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（完整 PR／跨环境验收）；本机 P2 代码实现、全部宿主测试及定点 GUI 检验已通过**。
- 理由：最终 `make test` 559 项 0 failures、8 个经授权条件跳过；26 项关键 GUI passed，Xcode 116 项枚举成功且 Dev／Runner 验签通过，但**116 项完整 GUI CI 及 8 个实机 SSH**尚未执行，不能宣称完整项目 QA 结束。阶段实现任务及 `F-01` 已完成；外部验证门槛仍待合法环境核销。

## 最终状态与剩余风险

- 当前状态：**Open（仅剩外部验收）；P2-T1～T5 和 F-01 均 Resolved**。
- 剩余风险：**①** 本轮审计尚无当前提交对应的 GitHub Actions 全量 UI 结果，需在 PR 中核销；**②** 未获授权的 8 项 Windows SSH 实机测试仍为 skipped；**③** 旧版 macOS、实体触控板及真实中文候选输入组合未在当前 27.2 ARM 主机执行；**④** 测试矩阵和完整 App 数量下降已真实核对，**跨版本 CI 耗时提升及资源指标未做对照测量**，不作性能收益声明。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板


---

## 附录：133 项原始 UI 方法逐项归属清单

基线：`105aa57` 133 项；现状：116 项。18 个原方法名不再出现，其中 1 个改名并合并断言，净删减 17 项。此清单只跟踪代码归属；具体运行证据见同阶段 audit。

| Task | 基线 Class.testMethod | 现状 | 原有断言的保留/替代责任 |
| --- | --- | --- | --- |
| P2-T4 | `EditorHighlightingUITests.testSwiftSyntaxColorsDifferFromPlainTextWithoutChangingFileBytes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `EditorHighlightingUITests.testEmbeddedAndTSXColorsReachTheRealEditor` | 删除（已转交） | NativeSyntaxHighlightingTests.testStandaloneMarkdownTSXHTMLAndCSSPaintRealTextKitSyntaxColors + remaining Swift UI pixel E2E |
| P2-T4 | `EditorNavigationUITests.testDistantNavigationKeepsBothEndsEditableAndPersistsBytes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `EditorNavigationUITests.testHundredThousandLineNavigationPreservesAllInterveningBytes` | 删除（已转交） | NativePaneRetentionIntegrationTests.testHundredThousandLineWorkspaceEditsSavesAndReleasesFile + remaining EditorNavigationUITests |
| P2-T4 | `EditorNavigationUITests.testUnicodeReplacementUndoRedoAndRealSave` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testFileAndFolderContextMenusDoNotBrowseOrOpen` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testSharedTreeHitAreasOpenExactFileWithoutDuplicateTabs` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testSharedTreeLongLabelsScrollButShortLabelsRemainStableAcrossRealDockResize` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testLongGitChangeScrollDoesNotMoveItsRealStageButton` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testGitFolderShortNameDoesNotBounceAndInlineStageKeepsTheExactDirectory` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testLightFileSelectionFillRemainsAfterCommandPaletteTakesFocus` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testDarkFileSelectionFillRemainsAfterCommandPaletteTakesFocus` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `SharedTreeUITests.testRealOpenFileMenuHasSingleItemAndCommandOUsesNativePicker` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testNativeFolderPickerRestoresMultipleClipboardItemsAndTypes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testAddFolderAndOpenFileThroughRealFileTree` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testCommandPaletteRestoresFileTreeKeyboardAfterDismissal` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testFileTreeRenameAndDraftCancellationRestoreKeyboardNavigation` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditorInChinese` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testNativeEditorSavesActualFileContentsToDisk` | 删除（已转交） | WorkspaceFilesUITests.testSameNamedFilesInSeparateFoldersSaveToTheirOwnPaths + FileTabPersistenceTests |
| P2-T4 | `WorkspaceFilesUITests.testSameNamedFilesInSeparateFoldersSaveToTheirOwnPaths` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testSameNamedFilesInDifferentFoldersHaveDistinctRowsAndTabs` | 删除（已转交） | WorkspaceFilesUITests.testSameNamedFilesInSeparateFoldersSaveToTheirOwnPaths |
| P2-T4 | `WorkspaceFilesUITests.testChinesePickerOpensFileWithLongUnicodePath` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T4 | `WorkspaceFilesUITests.testOpeningTheSameFileFromMenuReusesItsExistingTab` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testStagedAndUnstagedRowsPreviewTheirDistinctGitBaselines` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testGitGraphSpaceExpandsCommitWhenChangesListIsEmpty` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testNestedGitChangesTreeSupportsArrowSpaceReturnAndCollapseWithoutWritingIndex` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testCommandPaletteCancellationRestoresGitChangesKeyboardNavigation` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testChangingProjectsCannotDisplayOrWriteTheFormerGitRepository` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testExternalGitInitializationAppearsWithoutManualRefresh` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testExternalWorktreeIndexAndCommitRefreshTheRealGitPanel` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testIgnoreMenuRejectsTrackedChangesAndWritesLiteralUntrackedRule` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testMergeConflictMarkResolvedStagesOnlyTheActualConflictedPath` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testFolderInlineStageAndUnstageAreScopedToThatDirectory` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testFolderStageAndUnstageTouchesOnlyNestedSelectedDirectory` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitChangesUITests.testStageAndUnstageContextMenuChangeOnlyTheSelectedFixtureIndex` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testHistoricalBranchSheetCancelsThenCreatesAtChosenCommitWithoutCheckout` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testStashNativeApplyDropAndBranchUseSelectedOlderEntry` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testOlderStashNativePopCancelAndReinstateIndexUseCapturedOID` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testCurrentBranchNativeSheetDefaultsToCheckoutAndPreservesGitBytes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testBranchRenameAndNoRemotePushUseNativeRefMenuWithoutUnsafeChanges` | 合并改名 | testBranchRenameFromNativeRefMenuPreservesGitBytes; no-remote push transferred to GitNativeDialogTests |
| P2-T1 | `GitDialogUITests.testRemoteFetchRejectsMovedLocalDestinationThenAllowsFreshForceAndFastForward` | 删除（已转交） | GitRemoteBranchActionTests.testFetchConfirmationRejectsMovedDestinationEvenWithForceThenAcceptsFreshDecision + retained Fetch/Pull UI |
| P2-T1 | `GitDialogUITests.testLateBranchAndTagCollisionPreserveRetryInputsWithoutOverwritingRefs` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testHistoricalTagReplacementRejectsMovedRefAndRetainsAnnotation` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testHistoricalBranchReplacementRejectsMovedRefAndPreservesRetryName` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testDropCommitNativeConfirmationCancelsThenRewritesOnlySelectedHistory` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testInteractiveRebaseFromGitGraphOpensRealPTYAndAcceptsEditorInput` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testCommitSheetBelongsToItsWindowWhenAnotherWorkspaceTakesFocus` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testRemoteCheckoutNativeSheetValidatesNameAndCreatesTrackingBranch` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testRemoteFetchAndPullNativeDefaultsPreserveOrAdvanceOnlyExpectedRefs` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testBranchDeleteDefaultsPreserveRemoteAndCancelIsNoOp` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testBranchPushNativeSheetChoosesOnlySelectedBareRemote` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testTagPushWithoutRemoteCannotSubmitOrWriteRepository` | 删除（已转交） | GitNativeDialogTests.testTagDeleteAndPushNeverSelectAnImplicitOtherRemote + retained multi-remote Tag Push UI |
| P2-T1 | `GitDialogUITests.testTagPushUsesTagDefaultRemoteNotBranchPushRemote` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testTagDeleteNativeSheetDefaultsLocalOnlyAndPreservesBareRemote` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T1 | `GitDialogUITests.testHistoricalTagSheetPreservesAnnotationAndCreatesAtChosenCommit` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testRealDividerResizePreservesCompactBranchMenuAndWholeCommitHitArea` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testLightGraphAtMinimumPanelFontRetainsMenusAndFullRowHitArea` | 删除（已转交） | CommitGraphLayoutTests.testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts + retained actual Dock/Theme E2E |
| P2-T2 | `GitGraphGeometryUITests.testDarkGraphAtMinimumPanelFontRetainsMenusAndFullRowHitArea` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testLightGraphAtMaximumPanelFontRetainsMenusAndFullRowHitArea` | 删除（已转交） | CommitGraphLayoutTests.testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts + retained 18pt E2E |
| P2-T2 | `GitGraphGeometryUITests.testDarkGraphAtMaximumPanelFontRetainsMenusAndFullRowHitArea` | 删除（已转交） | CommitGraphLayoutTests.testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts + retained dark 18pt E2E |
| P2-T2 | `GitGraphGeometryUITests.testMaximumPanelFontWithSharedHeadWorktreesRetainsMenusAndFullRowHitArea` | 删除（已转交） | GitGraphWorktreePresentationTests + retained 12 shared Worktree E2E |
| P2-T2 | `GitGraphGeometryUITests.testMaximumPanelFontWithTwelveSharedWorktreesRetainsMenusAndFullRowHitArea` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testLightLongPrimaryBranchAtMinimumPanelFontRetainsItsMenuAndCommitTitle` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testDarkLongPrimaryBranchAtMinimumPanelFontRetainsItsMenuAndCommitTitle` | 删除（已转交） | CommitGraphLayoutTests geometry matrix + retained long branch light9 / dark18 E2E |
| P2-T2 | `GitGraphGeometryUITests.testLightLongPrimaryBranchAtMaximumPanelFontRetainsItsMenuAndCommitTitle` | 删除（已转交） | CommitGraphLayoutTests geometry matrix + retained long branch light9 / dark18 E2E |
| P2-T2 | `GitGraphGeometryUITests.testDarkLongPrimaryBranchAtMaximumPanelFontRetainsItsMenuAndCommitTitle` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testLightGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testDarkGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testDirtyWorktreeDiamondsAlignWithTheirOwnHeadsWithoutSelectingTheirHeaders` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testDarkTreeHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testLightListHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testDarkListHistoryAndWorktreeHeadersExpandWithoutPersistentSelectionFill` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testOverflowBranchWorktreeMenuSurvivesExternalRefreshBeforeOpeningItsExactCheckout` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testAllThirtyThreeRemoteReferencesRemainInTheNativeOverflowMenu` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphGeometryUITests.testUnreferencedSharedWorktreeMenuOpensTheSelectedCheckoutAndActualFile` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testChineseGraphNodeAndReferenceMenusRetainTheirExactCopyTargets` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testOverflowReferencesExposeTagAndBranchWithoutLosingGitRefs` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testGraphTreeKeyboardMovesFromChangesFocusToBothHistoricalFiles` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testDetachedHeadAndRealStashKeepSeparateNativeGraphActions` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testDirtyLinkedWorktreeUsesItsOwnGraphNodeAndSafeNativeMenu` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testRealGraphHistoryLoadsNextPageOnlyAfterScrollingToBottom` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testDenseRealGraphKeepsHistoryAndNodeVisibleAcrossMoreThanTwelveLanes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testLightDenseGraphAtMinimumPanelFontKeepsTitleAndRailsInsideThePanel` | 删除（已转交） | CommitGraphLayoutTests 24/30/150 lanes + retained dark9 dense UI |
| P2-T2 | `GitGraphUITests.testDarkDenseGraphAtMinimumPanelFontKeepsTitleAndRailsInsideThePanel` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testLightDenseGraphAtMaximumPanelFontKeepsTitleAndRailsInsideThePanel` | 删除（已转交） | CommitGraphLayoutTests 24/30/150 lanes + retained dark18 dense UI |
| P2-T2 | `GitGraphUITests.testDarkDenseGraphAtMaximumPanelFontKeepsTitleAndRailsInsideThePanel` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testHistoricalTagBadgeTogglesItsCommitAndKeepsOnlyTagActions` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testShortHashCopiesActualOIDWithoutExpandingGitCommit` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testSymbolicRemoteAliasCannotOfferDestructiveBranchActions` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testRealMergeShowsBothParentHistoriesAndTheirOwnFileDiffs` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testTwoRealBranchLanesPaintMatchingReferenceBadgesAndGraphNodes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testLongChineseGraphTitleScrollsButShortTitleAndGraphRailsStayFixed` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testDeepChineseHistoricalFolderScrollsInsideRowWithoutMovingGraph` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testUnbornEmptyRepositoryDoesNotInventCommitOrWorktreeGraphNodes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testDarkHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testMainWorktreeThirdLevelMenuDisablesRemovalInNativeApp` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T2 | `GitGraphUITests.testOtherWorktreeStagedAndWorkingFilesPreserveDistinctDiffBaselines` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitHistoryUITests.testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitHistoryUITests.testRenamedHistoricalFileComparesAndOpensActualWorkingFile` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitHistoryUITests.testBinaryAndOversizeHistoricalRevisionsShowNativeReadRestrictions` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitHistoryUITests.testHistoricalResetRejectsExternalEditAfterConfirmationOpens` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitHistoryUITests.testHistoricalResetConfirmationCancellationAndActualGitBytes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitIgnoreEditorUITests.testIgnoreUpdatesOpenNativeEditorAndCommandZCanUndoTheInsertedPatterns` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitUncommittedUITests.testResetCancelThenMixedThenHardPreservesCorrectGitBoundaries` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitUncommittedUITests.testStashCancelThenConfirmChangesOnlyTheIsolatedRepository` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `GitUncommittedUITests.testCleanWarningCancelAndConfirmedDirectoryRemovalPreserveIgnoredFiles` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `WorkspaceGitUITests.testGitGraphDisplaysTheRealCommitAndExpandsItsFiles` | 删除（已转交） | GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit + GitStatusModelTests |
| P2-T3 | `WorkspaceGitUITests.testGitChangesAreScopedToTheOpenedRepository` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T3 | `WorkspaceGitUITests.testWorktreeDiffEditsAndPersistsRealGitFile` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceDockUITests.testCrossGroupDragReleaseCannotSelectDestinationButRealClickCan` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceDockUITests.testClosingExplicitlyActivatedProjectsKeepsFilesWithoutDragging` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testIsolatedSettingsThemePersistsAcrossRealAppRestart` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testNormalQuitVetoesFailedSaveThenWritesAndRestoresSession` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testRealBrowserKeepsWebContentAcrossFileTabSwitches` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testRealTerminalKeepsSameShellAcrossFileTabAndFind` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testFiveRoundsOfFiveRealFileTabsRetireWithoutChangingDisk` | 删除（已转交） | NativePaneRetentionIntegrationTests.testClosingMountedFiveFileTabsReleasesTheirNativeDocuments + WorkspaceWindows LaunchServices/close E2E |
| P2-T5 | `WorkspaceRetentionUITests.testFinderNativeDropIntoWebKitUploadDoesNotOpenFileTab` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceRetentionUITests.testFinderNativeDropIntoGhosttyPastesButDoesNotExecute` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceSmokeUITests.testIsolatedLaunchAndPaletteKeyboardFocus` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testTwoEmptyWindowsHaveIndependentNativeLifecycle` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testSettingsOpensFromTheRealApplicationShortcut` | 删除（已转交） | WorkspaceRetentionUITests.testIsolatedSettingsThemePersistsAcrossRealAppRestart (real CMD-comma, CMD-W, relaunch) |
| P2-T5 | `WorkspaceWindowsUITests.testCancelingFolderPickerDoesNotCreateAnEmptyProject` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testLaunchServicesOpensAndReusesFilesInTheExistingDevWindow` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testLaunchServicesReusesTheOriginalFileOwnerAcrossWindows` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testNativeFolderPickersStayInsideTheirOwningWindows` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testNativeWindowCloseAndRelaunchRestoreTheSameFileAndBytes` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
| P2-T5 | `WorkspaceWindowsUITests.testKeyboardFocusAndPaletteRestorationStayWithTheOwningWindow` | 保留 | 宿主无法独立证明的真实 App 用户路径（本类原有系统行为断言） |
