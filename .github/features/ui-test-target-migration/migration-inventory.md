# 迁移清单：方法级零遗漏基线

> 2026-10-22，规划分支 `019765f`，仅为源码静态快照。这里登记**迁移责任**，不是已通过结果；完成／阻塞状态唯一归 `todo.toml`。迁移时每个 task 必须逐方法写下实际替代测试（或移入 Unit/Integration 的方法）、命令、输出与原因。方法可能合并成同一 E2E 路径，但不能丢失原断言。改动前后都要重新生成清单做集合差分。

基线：`BaileyTests/NativeUI` 19 文件／275 个 test 方法；`WorkspaceUI` 4 文件／54 个；合计 **329 方法**。 现行 `WorkspaceUI` 已因 P1 提前核销原生焦点方法减少 1 条：**328 条尚待迁移**（其中 P4-T1 原 11 条已完成 1 条，余 10 条）；原始 329 行、旧行号与归属继续留存作追溯，不修改历史基线。清单编排顺序来自源码而非目标测试数量。`UI+逻辑` 表示需逐条鉴别，不能认为全部适合纯 XCUITest。

**P1-T1 方法级归属（2026-10-22，源码初判）：** `A`（19）：实际原生控件、菜单、像素/交互 → App UI；`B`（87）：只验证数据、文件、Git、后端或无视图状态 → Unit/Integration；`C`（223）：原生 UI 和逻辑混合、或经 helper 间接装配 UI → 执行相应 P2–P4 任务时拆分两条证据。共 329，不代表已经迁移。旧用例的方法名、精确原始行号与原有断言仍可直接核对；P2–P4 必须填写真实替代方法、前置夹具和结果，发现隐藏视图依赖立即调整分类，不为凑目标数量删测试。

**发现证据：** 本机 Xcode 27.2 使用 `xcodebuild -enumerate-tests ... test` 取得 `BaileyTests` 的 51 个测试类、**635 项已发现方法**，与 `BaileyTests/Unit` 75 + `Integration` 231 + `NativeUI` 275 + `WorkspaceUI` 54 项源码双向差集为零；枚举没有运行测试（xcresult `totalTestCount=0`），但 Xcode **仍短暂启动隔离宿主进程**。正式 `/Applications/Bailey.app` 进程仍存活。此行为说明同一用户会话不能继续以枚举取代安全隔离；后续完整 E2E、UI Target 的真实发现/运行及宿主测试均需独立 GUI Runner。当时 `BaileyUITests` 的 4 个 UI 类、10 项仅完成源码核对，不代表后续状态。2026-10-22 已在完整 App 上实际运行 16/16（含 P2 新增的 3 项），0 失败、0 跳过；P1 阶段审计见 `audit-p1.md`，P2 原始 38 条仍须逐方法替代。

## 旧 NativeUI / WorkspaceUI：329 个逐方法锚点

### P2-T1 — 38 条

**2026-10-22 组件迁移验收：** `git show HEAD:<原始文件>` 与迁移后文件逐字比较（仅 class 更名），原 28+10 个测试方法及原断言、fixture **一项未删**，旧两文件已删除。运行 `make test:NativeEditorLayoutTests,NativeEditorCompositionTests,TextCoordinateIndexTests SIGNING=adhoc` **47/47 Passed**（28+10+9，0 skipped）；`BaileyUITests/EditorNavigationUITests` 的 3 项真 App 检查 10k/100k 首尾交错导航、Unicode 撤销/重做与真实磁盘字节，含前次 `make test:ui` 的 16/16。普通键盘键入**不冒充**真实拼音候选框/输入法物理组合验收；旧 38 条精确内存布局/像素需继续由组件层保留。CI 已删除按文件猜类名的动态 `-only-testing` 策略，默认全量宿主 XCTest，本地用 `make test:类名1,类名2`。

**P2-T1 前期缺陷修复证据（现已完成原断言迁移）：** `d122154` 将系统文件选择器从整 App 盲打路径改为直接操作原生 `PathTextField` 并验证完整输入，消除路径截断引起的级联失败；`1f5e83b` 为文件编辑器和可编辑 Diff 补齐 AppKit 原生 UndoManager 委托，复现过“去掉委托失败／恢复委托通过”。现行 `EditorNavigationUITests` 在真实 App 验证万行及十万行 17 次首尾导航、Unicode 文本替换、键盘 Undo/Redo 和保存磁盘字节；完整 UI 套件 16/16 通过，修复当时相关旧类的宿主 94/94 通过；随后 28+10 项完整迁入下述组件测试、原断言不删。真实物理拼音候选/IME 验收仍属单独环境边界。

**原始 `NativeUI/Editor/EditorNavigationTests.swift`（28 条） → [NativeEditorLayoutTests.swift](../../../BaileyTests/Integration/Editor/NativeEditorLayoutTests.swift)**：保留逐像素、TextKit 2 视口、行号、折行/字体/滚动与 30 次热操作原断言；完整 App 菜单/键盘/磁盘结果由 `EditorNavigationUITests` 另验。

- `testNativeViewportOnlyMaterializesVisibleParagraphsAfterDistantVisits`（旧 L67） · `C` → `NativeEditorLayoutTests.testNativeViewportOnlyMaterializesVisibleParagraphsAfterDistantVisits`
- `testCurrentSourceFileKeepsCorrectViewportAndHitTesting`（旧 L84） · `C` → `NativeEditorLayoutTests.testCurrentSourceFileKeepsCorrectViewportAndHitTesting`
- `testGutterParagraphNumbersMatchNativeSeparatorsAndCRLF`（旧 L103） · `C` → `NativeEditorLayoutTests.testGutterParagraphNumbersMatchNativeSeparatorsAndCRLF`
- `testNativeGutterKeepsEditorThemeBackgroundInBothAppearances`（旧 L120） · `C` → `NativeEditorLayoutTests.testNativeGutterKeepsEditorThemeBackgroundInBothAppearances`
- `testNativeGutterSelectedLineAndLargeDocumentWidth`（旧 L150） · `C` → `NativeEditorLayoutTests.testNativeGutterSelectedLineAndLargeDocumentWidth`
- `testSelectedTextRangeKeepsAllTouchedGutterNumbersHighlighted`（旧 L178） · `C` → `NativeEditorLayoutTests.testSelectedTextRangeKeepsAllTouchedGutterNumbersHighlighted`
- `testEmptyNativeEditorStillPaintsFirstGutterNumber`（旧 L233） · `C` → `NativeEditorLayoutTests.testEmptyNativeEditorStillPaintsFirstGutterNumber`
- `testFinalBlankLineRetainsVisibleGutterNumber`（旧 L257） · `C` → `NativeEditorLayoutTests.testFinalBlankLineRetainsVisibleGutterNumber`
- `testSelectedFinalBlankLineHighlightsItsOwnTextRow`（旧 L288） · `C` → `NativeEditorLayoutTests.testSelectedFinalBlankLineHighlightsItsOwnTextRow`
- `testEmptyEditorPaintsSelectedLineAtTheCaret`（旧 L319） · `C` → `NativeEditorLayoutTests.testEmptyEditorPaintsSelectedLineAtTheCaret`
- `testGutterWidthUsesTheSameUserFontAsSourceText`（旧 L340） · `C` → `NativeEditorLayoutTests.testGutterWidthUsesTheSameUserFontAsSourceText`
- `testGutterTransitionsAcrossDigitBoundariesWithoutShiftingTextUnderIt`（旧 L354） · `C` → `NativeEditorLayoutTests.testGutterTransitionsAcrossDigitBoundariesWithoutShiftingTextUnderIt`
- `testWrappingAndUnwrappedLongUnicodeLinesKeepRealCharacterHitTargets`（旧 L391） · `C` → `NativeEditorLayoutTests.testWrappingAndUnwrappedLongUnicodeLinesKeepRealCharacterHitTargets`
- `testWrappedUnicodeTailReallyScrollsIntoShortViewport`（旧 L443） · `C` → `NativeEditorLayoutTests.testWrappedUnicodeTailReallyScrollsIntoShortViewport`
- `testMountedSourceEditorActuallyPaintsVisibleTextInBothAppearances`（旧 L467） · `C` → `NativeEditorLayoutTests.testMountedSourceEditorActuallyPaintsVisibleTextInBothAppearances`
- `testAvailableEditorFontsKeepUsableGeometry`（旧 L527） · `C` → `NativeEditorLayoutTests.testAvailableEditorFontsKeepUsableGeometry`
- `testVariableHeightUndoDeleteAllAndRestore`（旧 L543） · `C` → `NativeEditorLayoutTests.testVariableHeightUndoDeleteAllAndRestore`
- `testSourceRestoresScrollSelectionAndResizesWithoutRecreatingDocument`（旧 L562） · `C` → `NativeEditorLayoutTests.testSourceRestoresScrollSelectionAndResizesWithoutRecreatingDocument`
- `testGeometryConfigurationBoundaries`（旧 L602） · `C` → `NativeEditorLayoutTests.testGeometryConfigurationBoundaries`
- `testScrollingPreservesVisibleTextAndSelection`（旧 L614） · `C` → `NativeEditorLayoutTests.testScrollingPreservesVisibleTextAndSelection`
- `testVariableLengthUnwrappedCodeKeepsLongLineVisible`（旧 L625） · `C` → `NativeEditorLayoutTests.testVariableLengthUnwrappedCodeKeepsLongLineVisible`
- `testSourceGeometryAndEditCosts`（旧 L639） · `C` → `NativeEditorLayoutTests.testSourceGeometryAndEditCosts`
- `testUnwrappedDocumentGeometryAcrossNewViewports`（旧 L662） · `C` → `NativeEditorLayoutTests.testUnwrappedDocumentGeometryAcrossNewViewports`
- `testLongDocumentRevealsForwardAndReverseTargets`（旧 L677） · `C` → `NativeEditorLayoutTests.testLongDocumentRevealsForwardAndReverseTargets`
- `testFourSizesWrappingAndThreeInputPositionsKeepDataAndLatency`（旧 L693） · `C` → `NativeEditorLayoutTests.testFourSizesWrappingAndThreeInputPositionsKeepDataAndLatency`
- `testDeletingLongestUnwrappedLineRestoresHorizontalExtent`（旧 L737） · `C` → `NativeEditorLayoutTests.testDeletingLongestUnwrappedLineRestoresHorizontalExtent`
- `testColdAndWarmScrollbarGeometryAcrossFourFileSizes`（旧 L761） · `C` → `NativeEditorLayoutTests.testColdAndWarmScrollbarGeometryAcrossFourFileSizes`
- `testShortAndFixedRowDocumentsKeepEndAndBeginningVisible`（旧 L797） · `C` → `NativeEditorLayoutTests.testShortAndFixedRowDocumentsKeepEndAndBeginningVisible`

**原始 `NativeUI/Editor/EditorTextInputTests.swift`（10 条） → [NativeEditorCompositionTests.swift](../../../BaileyTests/Integration/Editor/NativeEditorCompositionTests.swift)**：保留与系统 `NSTextView` 对照的标记输入、replacementRange、撤销、多选区和输入法几何原断言；这属于 AppKit 组件集成而非真实输入法候选框实机验收。

- `testUnmarkAcceptsCompositionLikeSystemTextViewAndClearsMarking`（旧 L23） · `C` → `NativeEditorCompositionTests.testUnmarkAcceptsCompositionLikeSystemTextViewAndClearsMarking`
- `testCompositionWithImplicitReplacementReplacesSelectedTextAndRestoresUndo`（旧 L47） · `C` → `NativeEditorCompositionTests.testCompositionWithImplicitReplacementReplacesSelectedTextAndRestoresUndo`
- `testAttachedInputGeometryRemainsUsable`（旧 L76） · `C` → `NativeEditorCompositionTests.testAttachedInputGeometryRemainsUsable`
- `testInputGeometryAfterEditorDetachesDoesNotUseDisposedWindow`（旧 L98） · `C` → `NativeEditorCompositionTests.testInputGeometryAfterEditorDetachesDoesNotUseDisposedWindow`
- `testUnicodeCompositionSelectionMatrixMatchesSystem`（旧 L112） · `C` → `NativeEditorCompositionTests.testUnicodeCompositionSelectionMatrixMatchesSystem`
- `testDirectUnmarkUndoMatchesNativeTextView`（旧 L160） · `C` → `NativeEditorCompositionTests.testDirectUnmarkUndoMatchesNativeTextView`
- `testCompositionReplacingExistingTextRestoresOriginalOnUndo`（旧 L199） · `C` → `NativeEditorCompositionTests.testCompositionReplacingExistingTextRestoresOriginalOnUndo`
- `testFinalCompositionDefaultAndExplicitRangesMatchSystemAndKeepUndo`（旧 L232） · `C` → `NativeEditorCompositionTests.testFinalCompositionDefaultAndExplicitRangesMatchSystemAndKeepUndo`
- `testNativeMultipleSelectionsShareDocumentAndUndo`（旧 L253） · `C` → `NativeEditorCompositionTests.testNativeMultipleSelectionsShareDocumentAndUndo`
- `testOrdinaryInputAndSelectedReplacementKeepUndo`（旧 L275） · `C` → `NativeEditorCompositionTests.testOrdinaryInputAndSelectedReplacementKeepUndo`

### P2-T2 — 49 条

**本机验收（2026-10-23）：** 49 条旧方法逐项核销，所有保存／失败／竞态／原生断言保留；已运行 `make test:FileTabPersistenceTests,NativeFileTabTests,NativeSyntaxHighlightingTests,NativeDiffTabTests DERIVED_DATA=build/DerivedData-P2-Acceptance` 共106/106通过，其中本任务49/49。真实 Dev GUI 已验证不同目录同名文件独立保存、中文 Unicode 路径、编辑器文件写盘及文件树焦点；中英文命令面板重跑2/2通过。完整本机 `make test:ui DERIVED_DATA=build/DerivedData-P2-Acceptance` 在 Apple Development 签名下 **20/20 通过（0 skipped，exit 0）**；正式 Bailey 从未被替换或退出。模拟断线不等于真实 Windows SSH 图形验收。

**旧 `NativeUI/Editor/FileTabTests.swift`（49 条） → [Integration/Files/FileTabPersistenceTests.swift](../../../BaileyTests/Integration/Files/FileTabPersistenceTests.swift)**：33 条 `FileTabPersistenceTests` 验证受控后端时序、保存事务与数据；16 条 `NativeFileTabTests` 保留挂载后的 AppKit/AX/像素断言。两个 XCTest 类共用该文件内原有 `private actor EditorWorkspaceFixture`，避免创建对生产代码不可见的测试专用接口。原始文件可由提交 `b094047` 查看。

- `testMountedNativeMultipleSelectionsPreserveBytesDirtyStateAndUndo`（旧 L94） · `C` → `NativeFileTabTests.testMountedNativeMultipleSelectionsPreserveBytesDirtyStateAndUndo`
- `testNativeFindBarRoutesThroughMountedFileEditor`（旧 L138） · `C` → `NativeFileTabTests.testNativeFindBarRoutesThroughMountedFileEditor`
- `testNativeFindBarKeepsSelectedGutterAndTextRowsPixelAligned`（旧 L167） · `C` → `NativeFileTabTests.testNativeFindBarKeepsSelectedGutterAndTextRowsPixelAligned`
- `testDetachedEditorAppendKeepsSameNativeDocumentAndUndo`（旧 L366） · `C` → `NativeFileTabTests.testDetachedEditorAppendKeepsSameNativeDocumentAndUndo`
- `testNativeReorderAndInFlightSaveKeepExactDirtyBytes`（旧 L408） · `C` → `NativeFileTabTests.testNativeReorderAndInFlightSaveKeepExactDirtyBytes`
- `testCanonicalEquivalentNativeReplacementUndoAndSavePreserveBytes`（旧 L451） · `C` → `NativeFileTabTests.testCanonicalEquivalentNativeReplacementUndoAndSavePreserveBytes`
- `testCanonicalEquivalentCleanReloadInstallsNewBytes`（旧 L492） · `B` → `FileTabPersistenceTests.testCanonicalEquivalentCleanReloadInstallsNewBytes`
- `testCanonicalEquivalentEditDuringWriteRemainsDirty`（旧 L513） · `B` → `FileTabPersistenceTests.testCanonicalEquivalentEditDuringWriteRemainsDirty`
- `testUnconsumedTabDoesNotReadAndWaitLoadsExactlyOnce`（旧 L532） · `B` → `FileTabPersistenceTests.testUnconsumedTabDoesNotReadAndWaitLoadsExactlyOnce`
- `testInitialReadFollowsRenameAndOldReadCannotWin`（旧 L551） · `B` → `FileTabPersistenceTests.testInitialReadFollowsRenameAndOldReadCannotWin`
- `testLocalTextReadCapacityAndFailureKinds`（旧 L569） · `B` → `FileTabPersistenceTests.testLocalTextReadCapacityAndFailureKinds`
- `testHundredThousandLineSwiftFileCanLoadAbovePreviousCapacity`（旧 L619） · `C` → `NativeFileTabTests.testHundredThousandLineSwiftFileCanLoadAbovePreviousCapacity`
- `testLocalSymbolicLinkUsesTargetContents`（旧 L674） · `B` → `FileTabPersistenceTests.testLocalSymbolicLinkUsesTargetContents`
- `testInvalidUTF8AndImageFallbackRespectTextCapacity`（旧 L690） · `B` → `FileTabPersistenceTests.testInvalidUTF8AndImageFallbackRespectTextCapacity`
- `testNativeReadOnlyRejectsAXValueAndSelectionReplacement`（旧 L737） · `C` → `NativeFileTabTests.testNativeReadOnlyRejectsAXValueAndSelectionReplacement`
- `testWritableNativeAXValueReplacementUpdatesDirtyStateAndDisk`（旧 L750） · `C` → `NativeFileTabTests.testWritableNativeAXValueReplacementUpdatesDirtyStateAndDisk`
- `testMountedEditorDisconnectReconnectKeepsNativeBufferAndUndo`（旧 L779） · `C` → `NativeFileTabTests.testMountedEditorDisconnectReconnectKeepsNativeBufferAndUndo`
- `testFixedHostDisconnectRebindsDirtyFileWithoutLosingDraft`（旧 L823） · `B` → `FileTabPersistenceTests.testFixedHostDisconnectRebindsDirtyFileWithoutLosingDraft`
- `testUnconsumedRemoteTabRemainsLazyAcrossReconnect`（旧 L848） · `B` → `FileTabPersistenceTests.testUnconsumedRemoteTabRemainsLazyAcrossReconnect`
- `testVisibleRemoteTabRecoversWhenConnectionReturns`（旧 L864） · `B` → `FileTabPersistenceTests.testVisibleRemoteTabRecoversWhenConnectionReturns`
- `testWindowFocusRefreshesOnlyItsMountedFile`（旧 L878） · `C` → `NativeFileTabTests.testWindowFocusRefreshesOnlyItsMountedFile`
- `testImagePreviewReloadIsScopedToItsWindow`（旧 L915） · `C` → `NativeFileTabTests.testImagePreviewReloadIsScopedToItsWindow`
- `testRepeatedWindowFocusCoalescesInFlightCleanRefresh`（旧 L963） · `B` → `FileTabPersistenceTests.testRepeatedWindowFocusCoalescesInFlightCleanRefresh`
- `testQueuedRefreshCannotResurrectAfterDirtyEdit`（旧 L983） · `B` → `FileTabPersistenceTests.testQueuedRefreshCannotResurrectAfterDirtyEdit`
- `testQueuedRefreshCannotResurrectAfterSSHDisconnect`（旧 L1002） · `B` → `FileTabPersistenceTests.testQueuedRefreshCannotResurrectAfterSSHDisconnect`
- `testTransientCleanRefreshErrorPreservesLoadedTextAndRecovers`（旧 L1027） · `B` → `FileTabPersistenceTests.testTransientCleanRefreshErrorPreservesLoadedTextAndRecovers`
- `testAppendRejectsStaleCachedTextWhenFreshReadFails`（旧 L1054） · `B` → `FileTabPersistenceTests.testAppendRejectsStaleCachedTextWhenFreshReadFails`
- `testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry`（旧 L1081） · `B` → `FileTabPersistenceTests.testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry`
- `testNativeEditorSurvivesTransientRefreshFailureWithUndo`（旧 L1120） · `C` → `NativeFileTabTests.testNativeEditorSurvivesTransientRefreshFailureWithUndo`
- `testWindowActivationDoesNotRestartInFlightInitialRead`（旧 L1167） · `C` → `NativeFileTabTests.testWindowActivationDoesNotRestartInFlightInitialRead`
- `testFixedHostDisconnectBeforeLoadShowsReasonWithoutReading`（旧 L1190） · `B` → `FileTabPersistenceTests.testFixedHostDisconnectBeforeLoadShowsReasonWithoutReading`
- `testAppendWaitsForReplacementReadWithoutUsingLoadingOrCachedText`（旧 L1204） · `B` → `FileTabPersistenceTests.testAppendWaitsForReplacementReadWithoutUsingLoadingOrCachedText`
- `testAppendWaitsForRemoteReadAndRetainsTextOnSaveFailure`（旧 L1242） · `B` → `FileTabPersistenceTests.testAppendWaitsForRemoteReadAndRetainsTextOnSaveFailure`
- `testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab`（旧 L1280） · `B` → `FileTabPersistenceTests.testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab`
- `testGitPreparationMatchesNativePrivatePathAliasWithoutSavingOtherRepository`（旧 L1318） · `B` → `FileTabPersistenceTests.testGitPreparationMatchesNativePrivatePathAliasWithoutSavingOtherRepository`
- `testProjectCloseWaitsForFileSaveAndRetainsUnsavedOnFailure`（旧 L1347） · `B` → `FileTabPersistenceTests.testProjectCloseWaitsForFileSaveAndRetainsUnsavedOnFailure`
- `testCloseFilesSavesOriginallyCleanTabEditedDuringAnotherTabWrite`（旧 L1398） · `B` → `FileTabPersistenceTests.testCloseFilesSavesOriginallyCleanTabEditedDuringAnotherTabWrite`
- `testProjectCloseKeepsNewDraftCreatedInAnotherTabDuringPendingSave`（旧 L1431） · `B` → `FileTabPersistenceTests.testProjectCloseKeepsNewDraftCreatedInAnotherTabDuringPendingSave`
- `testWindowCloseVetoesNewDraftCreatedInAnotherTabDuringPendingSave`（旧 L1482） · `B` → `FileTabPersistenceTests.testWindowCloseVetoesNewDraftCreatedInAnotherTabDuringPendingSave`
- `testApplicationTerminationRechecksEarlierWindowAfterAnotherWindowSave`（旧 L1528） · `B` → `FileTabPersistenceTests.testApplicationTerminationRechecksEarlierWindowAfterAnotherWindowSave`
- `testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving`（旧 L1577） · `B` → `FileTabPersistenceTests.testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving`
- `testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget`（旧 L1603） · `C` → `NativeFileTabTests.testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget`
- `testNativeEditorResignFirstResponderWritesRealFile`（旧 L1697） · `C` → `NativeFileTabTests.testNativeEditorResignFirstResponderWritesRealFile`
- `testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures`（旧 L1728） · `B` → `FileTabPersistenceTests.testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures`
- `testAnotherLiveChannelTakesOverWithoutTransientReadOnlyState`（旧 L1768） · `B` → `FileTabPersistenceTests.testAnotherLiveChannelTakesOverWithoutTransientReadOnlyState`
- `testDirtyUndoSaveDuringEditRenameFailureAndStaleReload`（旧 L1818） · `B` → `FileTabPersistenceTests.testDirtyUndoSaveDuringEditRenameFailureAndStaleReload`
- `testBinaryAndLargeTextAreNotTreatedAsEditable`（旧 L1903） · `B` → `FileTabPersistenceTests.testBinaryAndLargeTextAreNotTreatedAsEditable`
- `testDisconnectDuringSavePreservesBufferAndBaseline`（旧 L1927） · `B` → `FileTabPersistenceTests.testDisconnectDuringSavePreservesBufferAndBaseline`
- `testCleanReloadPublishesOnlyNewBytesAndDropsRenamedRead`（旧 L1950） · `B` → `FileTabPersistenceTests.testCleanReloadPublishesOnlyNewBytesAndDropsRenamedRead`

### P2-T3 — 22 条

**2026-10-23 P2-T3 验收：** 原22个 `test*` 方法与原类方法体、私有夹具逐字等价，仅类名更换；位置为 `Integration/Editor`。已真实执行签名宿主22/22通过；`EditorHighlightingUITests` 通过独立 Bailey Dev 的 Swift／纯文本截图差异及最终字节检查。完整 Bailey Dev GUI 20/20 通过，高亮真实截图和字节 E2E 通过；其他真实 IME 候选、CI／其他 OS 与主题极端组合须分别核销。

**本轮源码复核修正：** 原始清单把 2 项误归为 `B`：`testEmbeddedRequestsStayWithinRequestedRangeAndMatchFreshCaptures` 和 `testParserReadsAcrossUTF16ChunkBoundariesAndEditShift` 实际均调用 `mountedPlugin()`，检查已经挂载的 TextKit 原生临时颜色。**真正无需挂载原生编辑器的仅 2 项**：`testThemeCapturesMatchBundledPaletteAcrossAppearances`（AppKit/资源颜色）和 `testProductionTransformerMatchesUTF16ParserPoints`（parser 坐标）；其余 **20/22** 为原生组件颜色、语法时序/生命周期验证。保留原像素/异步断言，迁移不能以 parser 绿色或 XCUITest 文本非空代替颜色；已授权使用共享桌面焦点的 Bailey Dev E2E 不触及正在运行的正式 Bailey。

**原始 `BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift` 的 22 条 → [NativeSyntaxHighlightingTests.swift](../../../BaileyTests/Integration/Editor/NativeSyntaxHighlightingTests.swift)**。新类保留全部原生挂载、渲染色、异步解析、Unicode 与 Undo 断言；`EditorHighlightingUITests` 新增 Swift 与纯文本同源像素对照，已在本机 GUI 通过。

- `testEmbeddedRequestsStayWithinRequestedRangeAndMatchFreshCaptures`（旧 L25） · `C` → `NativeSyntaxHighlightingTests.testEmbeddedRequestsStayWithinRequestedRangeAndMatchFreshCaptures`
- `testEmbeddedSameLengthEditLanguageRemovalAndUndoKeepCurrentColors`（旧 L77） · `C` → `NativeSyntaxHighlightingTests.testEmbeddedSameLengthEditLanguageRemovalAndUndoKeepCurrentColors`
- `testClosingEmbeddedEditorReleasesPendingHighlightRequests`（旧 L123） · `C` → `NativeSyntaxHighlightingTests.testClosingEmbeddedEditorReleasesPendingHighlightRequests`
- `testClosingFirstEditorDoesNotPreventSecondEditorAndDiffColors`（旧 L140） · `C` → `NativeSyntaxHighlightingTests.testClosingFirstEditorDoesNotPreventSecondEditorAndDiffColors`
- `testThemeCapturesMatchBundledPaletteAcrossAppearances`（旧 L164） · `B` → `NativeSyntaxHighlightingTests.testThemeCapturesMatchBundledPaletteAcrossAppearances`
- `testClosingEditorDuringQueuedParsingReleasesItsContent`（旧 L191） · `C` → `NativeSyntaxHighlightingTests.testClosingEditorDuringQueuedParsingReleasesItsContent`
- `testQueuedSemanticEditAndEarlierInsertionRecolorCurrentViewport`（旧 L210） · `C` → `NativeSyntaxHighlightingTests.testQueuedSemanticEditAndEarlierInsertionRecolorCurrentViewport`
- `testParserReadsAcrossUTF16ChunkBoundariesAndEditShift`（旧 L278） · `C` → `NativeSyntaxHighlightingTests.testParserReadsAcrossUTF16ChunkBoundariesAndEditShift`
- `testFourSizeRealFileTabHighlightedInputAndParserBudget`（旧 L321） · `C` → `NativeSyntaxHighlightingTests.testFourSizeRealFileTabHighlightedInputAndParserBudget`
- `testOldSuccessIsNotDeliveredWhenContentChangesDuringPredicateRead`（旧 L443） · `C` → `NativeSyntaxHighlightingTests.testOldSuccessIsNotDeliveredWhenContentChangesDuringPredicateRead`
- `testCompositionFinalReplacementKeepsParserAndCurrentColors`（旧 L467） · `C` → `NativeSyntaxHighlightingTests.testCompositionFinalReplacementKeepsParserAndCurrentColors`
- `testOldFailureIsNotDeliveredAfterNewEdit`（旧 L495） · `C` → `NativeSyntaxHighlightingTests.testOldFailureIsNotDeliveredAfterNewEdit`
- `testEmbeddedQueryReadyDropsInFlightEarlierTokens`（旧 L513） · `C` → `NativeSyntaxHighlightingTests.testEmbeddedQueryReadyDropsInFlightEarlierTokens`
- `testInjectionReadCannotDeliverOldBaseAndCurrentViewportRecolors`（旧 L542） · `C` → `NativeSyntaxHighlightingTests.testInjectionReadCannotDeliverOldBaseAndCurrentViewportRecolors`
- `testRealPluginTailDeleteAllDeleteAndQueuedEditsMatchFreshParserAndColors`（旧 L581） · `C` → `NativeSyntaxHighlightingTests.testRealPluginTailDeleteAllDeleteAndQueuedEditsMatchFreshParserAndColors`
- `testPluginColorsPreserveTextFontCleanStateAndUndo`（旧 L644） · `C` → `NativeSyntaxHighlightingTests.testPluginColorsPreserveTextFontCleanStateAndUndo`
- `testSelectedCompositionFlowsIntoActualFileBytesAndUndo`（旧 L698） · `C` → `NativeSyntaxHighlightingTests.testSelectedCompositionFlowsIntoActualFileBytesAndUndo`
- `testRepeatedGrammarSwitchReleasesPriorCoordinators`（旧 L743） · `C` → `NativeSyntaxHighlightingTests.testRepeatedGrammarSwitchReleasesPriorCoordinators`
- `testRenamingMountedFileChangesGrammarWithoutDiscardingUndo`（旧 L772） · `C` → `NativeSyntaxHighlightingTests.testRenamingMountedFileChangesGrammarWithoutDiscardingUndo`
- `testRapidNativeUnicodeReplacementsKeepParserAndBytesAligned`（旧 L824） · `C` → `NativeSyntaxHighlightingTests.testRapidNativeUnicodeReplacementsKeepParserAndBytesAligned`
- `testAtomicMultiCursorUnicodeEditAndUndoKeepParserAndNativeStorageAligned`（旧 L857） · `C` → `NativeSyntaxHighlightingTests.testAtomicMultiCursorUnicodeEditAndUndoKeepParserAndNativeStorageAligned`
- `testProductionTransformerMatchesUTF16ParserPoints`（旧 L888） · `B` → `NativeSyntaxHighlightingTests.testProductionTransformerMatchesUTF16ParserPoints`

### P2-T4 — 35 条

**2026-10-23 P2-T4 验收：** 35条旧测试方法及原有断言保留；像素样本按 sRGB 目标读取通道，未放宽原阈值；Diff 组件统一隔离 UserDefaults，验证折叠计算不会因先前 GUI 持久化编辑模式而超时。`NativeDiffTabTests` 35/35 宿主通过（含统一／分栏红绿背景、删除 ghost 浅深主题），`WorkspaceGitUITests.testWorktreeDiffEditsAndPersistsRealGitFile` 从真实 Git Changes 执行 Diff 编辑／Undo／Redo／⌘S 及字节核对 1/1 通过；两个原生 `NSSegmentedControl` 的实际 AX 类型是 `RadioGroup`，测试查询与平台一致。完整本机 GUI 20/20 通过；后续增强 Split→Unified 切换并核对两侧可见原生编辑区域的定点 E2E 1/1 再次通过；CI／真实 SSH 单独记边界。

**原始 `BaileyTests/NativeUI/Git/DiffTabTests.swift` 的 35 条 → [NativeDiffTabTests.swift](../../../BaileyTests/Integration/Git/NativeDiffTabTests.swift)**：全部原生渲染、Git read/write、撤销与生命周期方法逐字保留；新的真实 App 路径在 `WorkspaceGitUITests.testWorktreeDiffEditsAndPersistsRealGitFile`。

- `testNativeDiffRendersRowsThroughTransparentTextSurface`（旧 L126） · `C` → `NativeDiffTabTests.testNativeDiffRendersRowsThroughTransparentTextSurface`
- `testSplitAndUnifiedDiffRowTintsReachPixelsInBothThemes`（旧 L169） · `C` → `NativeDiffTabTests.testSplitAndUnifiedDiffRowTintsReachPixelsInBothThemes`
- `testNativeEditableDiffPaintsDeletedGhostRowsInBothThemes`（旧 L240） · `C` → `NativeDiffTabTests.testNativeEditableDiffPaintsDeletedGhostRowsInBothThemes`
- `testLongCRLogicalRowDoesNotPutEOFGhostsAtViewportBoundary`（旧 L294） · `C` → `NativeDiffTabTests.testLongCRLogicalRowDoesNotPutEOFGhostsAtViewportBoundary`
- `testUnicodeLineSeparatorsDecorateEveryNativeVisualSegment`（旧 L334） · `C` → `NativeDiffTabTests.testUnicodeLineSeparatorsDecorateEveryNativeVisualSegment`
- `testDeletingEveryEditLineKeepsEOFRemovalGhostScrollAccessible`（旧 L375） · `C` → `NativeDiffTabTests.testDeletingEveryEditLineKeepsEOFRemovalGhostScrollAccessible`
- `testDeletedGhostSpacingStaysOnOneTextKitParagraphWithBareCR`（旧 L423） · `C` → `NativeDiffTabTests.testDeletedGhostSpacingStaysOnOneTextKitParagraphWithBareCR`
- `testEditGeometryUsesGitLFLinesAcrossNativeBareCRParagraphs`（旧 L491） · `C` → `NativeDiffTabTests.testEditGeometryUsesGitLFLinesAcrossNativeBareCRParagraphs`
- `testBareCRReviewUsesTextKitParagraphHeightInsteadOfLFOnlyHeight`（旧 L542） · `C` → `NativeDiffTabTests.testBareCRReviewUsesTextKitParagraphHeightInsteadOfLFOnlyHeight`
- `testStagedDeletionShowsDeletedLinesInsteadOfMissingRevision`（旧 L589） · `C` → `NativeDiffTabTests.testStagedDeletionShowsDeletedLinesInsteadOfMissingRevision`
- `testStagedConflictWithoutStageZeroIsNotADeletion`（旧 L626） · `B` → `NativeDiffTabTests.testStagedConflictWithoutStageZeroIsNotADeletion`
- `testAppearanceChangeAfterReadErrorKeepsLastSuccessfulDiff`（旧 L655） · `C` → `NativeDiffTabTests.testAppearanceChangeAfterReadErrorKeepsLastSuccessfulDiff`
- `testIncompleteSelectedGitBlobFailsInsteadOfPublishingTruncatedContent`（旧 L709） · `B` → `NativeDiffTabTests.testIncompleteSelectedGitBlobFailsInsteadOfPublishingTruncatedContent`
- `testFoldingPreviousDisplayCannotOverrideNewLoadedDiff`（旧 L727） · `B` → `NativeDiffTabTests.testFoldingPreviousDisplayCannotOverrideNewLoadedDiff`
- `testIndexMutationDuringGitContentReadUsesSelectedImmutableBlob`（旧 L760） · `B` → `NativeDiffTabTests.testIndexMutationDuringGitContentReadUsesSelectedImmutableBlob`
- `testCanonicalEquivalentEditDuringDiffWriteRemainsDirty`（旧 L778） · `B` → `NativeDiffTabTests.testCanonicalEquivalentEditDuringDiffWriteRemainsDirty`
- `testCanonicalEquivalentGitContentIsARealDiff`（旧 L799） · `B` → `NativeDiffTabTests.testCanonicalEquivalentGitContentIsARealDiff`
- `testCanonicalEquivalentNativeDiffEditSaveModeSwitchAndReload`（旧 L830） · `C` → `NativeDiffTabTests.testCanonicalEquivalentNativeDiffEditSaveModeSwitchAndReload`
- `testSwitchingLoadedDiffTabsKeepsEachNativeDocument`（旧 L928） · `C` → `NativeDiffTabTests.testSwitchingLoadedDiffTabsKeepsEachNativeDocument`
- `testNativeDiffEditorFocusLossSavesThroughBackend`（旧 L969） · `C` → `NativeDiffTabTests.testNativeDiffEditorFocusLossSavesThroughBackend`
- `testFocusTriggeredDiffSavePreservesNewestBufferAndFailure`（旧 L1002） · `B` → `NativeDiffTabTests.testFocusTriggeredDiffSavePreservesNewestBufferAndFailure`
- `testAnotherLiveChannelInvalidatesInFlightDiffSave`（旧 L1038） · `B` → `NativeDiffTabTests.testAnotherLiveChannelInvalidatesInFlightDiffSave`
- `testWorktreeStagedHistoryBinarySizeAndSymlink`（旧 L1087） · `B` → `NativeDiffTabTests.testWorktreeStagedHistoryBinarySizeAndSymlink`
- `testSaveDuringEditFailureAndDisconnectKeepUnsavedContent`（旧 L1147） · `B` → `NativeDiffTabTests.testSaveDuringEditFailureAndDisconnectKeepUnsavedContent`
- `testNativeDiffRendersAndRetainsTextKitSurface`（旧 L1187） · `C` → `NativeDiffTabTests.testNativeDiffRendersAndRetainsTextKitSurface`
- `testBackgroundSyntaxCapturesReachNativeDiffColors`（旧 L1229） · `C` → `NativeDiffTabTests.testBackgroundSyntaxCapturesReachNativeDiffColors`
- `testCRLFNativeReviewRowsAndEditUndoSavePreserveBytes`（旧 L1255） · `C` → `NativeDiffTabTests.testCRLFNativeReviewRowsAndEditUndoSavePreserveBytes`
- `testNativeDiffUnicodeAndSplitAlignmentWithFoldExpansion`（旧 L1321） · `B` → `NativeDiffTabTests.testNativeDiffUnicodeAndSplitAlignmentWithFoldExpansion`
- `testCollapsedDiffAccessibilityPressReachesNativeExpansion`（旧 L1350） · `C` → `NativeDiffTabTests.testCollapsedDiffAccessibilityPressReachesNativeExpansion`
- `testNativeDiffSplitLayoutPreservesPaneIdentity`（旧 L1391） · `C` → `NativeDiffTabTests.testNativeDiffSplitLayoutPreservesPaneIdentity`
- `testSplitDiffSynchronizesHorizontalAndVerticalScrolling`（旧 L1454） · `C` → `NativeDiffTabTests.testSplitDiffSynchronizesHorizontalAndVerticalScrolling`
- `testReadInFlightCannotReplaceEditingOrDisconnectedContent`（旧 L1540） · `B` → `NativeDiffTabTests.testReadInFlightCannotReplaceEditingOrDisconnectedContent`
- `testGitReloadUpdatesCleanMountedEditSurfaceWithoutLosingDirtyText`（旧 L1578） · `C` → `NativeDiffTabTests.testGitReloadUpdatesCleanMountedEditSurfaceWithoutLosingDirtyText`
- `testNativeDiffEditUndoScrollSaveAndReparent`（旧 L1612） · `C` → `NativeDiffTabTests.testNativeDiffEditUndoScrollSaveAndReparent`
- `testEnteringEditModeDiscardsInFlightReadAndKeepsSharedPreferenceIdentity`（旧 L1690） · `B` → `NativeDiffTabTests.testEnteringEditModeDiscardsInFlightReadAndKeepsSharedPreferenceIdentity`

### P3-T1 — 21 条

**[GitHistoryFileTests.swift](../../../BaileyTests/NativeUI/Git/GitHistoryFileTests.swift)：21 条** — 历史快照、只读、恢复与文件重置。初判：UI+逻辑，执行前核对每项真实断言。

- `testRevisionIsNativeReadonlyTextOfSelectedCommitEvenWithSharedEditPreference`（旧 L50） · `C`
- `testNativeDiffAccessibilityAllowsOnlyEditableTextChanges`（旧 L98） · `C`
- `testRevisionToWorktreeFollowsRenameAndRefreshesWithoutWritingHistoricalBlob`（旧 L113） · `B`
- `testHistoricalDiffPreviewKeepsGitActiveAndExplicitActivationStillWorks`（旧 L138） · `C`
- `testReopeningLoadedImmutableRevisionDoesNotRepeatGitRead`（旧 L189） · `C`
- `testUnmergedWorktreeUsesStageTwoAndPreservesConflictStatus`（旧 L221） · `B`
- `testUnbornIndexAndLiteralSpecialPathResolveCorrectBlobs`（旧 L248） · `B`
- `testReadFailureDoesNotEraseAlreadyLoadedHistoricalText`（旧 L291） · `B`
- `testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`（旧 L316） · `B`
- `testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected`（旧 L364） · `B`
- `testInvalidRevisionIsNotMisreportedAsAFileMissingFromValidCommit`（旧 L390） · `B`
- `testDanglingHeadRefIsNotMistakenForUnbornStagedDiff`（旧 L407） · `B`
- `testDeletedHistoricalDiffValidatesTheSelectedCommit`（旧 L430） · `B`
- `testMissingSelectedRevisionReportsErrorButRootAndDeletedSidesMayBeEmpty`（旧 L460） · `B`
- `testResetHistoricalBinaryFileUpdatesIndexAndWorktreeWithoutChangingHead`（旧 L490） · `B`
- `testResetHistoricalFileRefusesStaleWorkingBytesAfterConfirmation`（旧 L528） · `B`
- `testResetFileSavesDirtyTabThenOverwritesIndexDiskAndReloadsSameTab`（旧 L558） · `B`
- `testResetFileRejectsIndexChangeDuringPreparation`（旧 L607） · `B`
- `testProjectRestoresDistinctNativeTabsForHistoricalDiffModes`（旧 L634） · `C`
- `testExpandingCommitLoadsBinaryMetadataOnceAndPreservesGitRenamePaths`（旧 L684） · `B`
- `testSelectedBinaryAndLargeRevisionsExplainWhyTheyCannotRenderAsText`（旧 L711） · `B`

### P3-T2 — 15 条

**[GitExternalRefreshTests.swift](../../../BaileyTests/NativeUI/Git/GitExternalRefreshTests.swift)：4 条** — Git 外部变更驱动的实际列表。初判：UI+逻辑，执行前核对每项真实断言。

- `testVisibleLocalPanelDetectsExternalInitialization`（旧 L23） · `C`
- `testVisibleGitPanelRefreshesTwoExternalMutationsWithoutActivation`（旧 L70） · `C`
- `testVisibleGitPanelKeepsRefreshPendingWhileRemoteDetailsAreSlow`（旧 L255） · `C`
- `testVisibleSSHPanelRefreshesExternalGitChanges`（旧 L356） · `C`

**[GitWorkspaceMenuTests.swift](../../../BaileyTests/NativeUI/Git/GitWorkspaceMenuTests.swift)：11 条** — Git Changes、工作树与菜单。初判：UI+逻辑，执行前核对每项真实断言。

- `testUncommittedDialogDefaultsAndPermanentCleanWarning`（旧 L18） · `A`
- `testIgnoreAppendsNativeBufferSavesAndCanUndoWithoutRemounting`（旧 L35） · `C`
- `testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView`（旧 L84） · `B`
- `testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget`（旧 L112） · `B`
- `testIgnoreContextMenuIsOnlyOfferedForUntrackedFiles`（旧 L134） · `C`
- `testGitChangeRowPreviewKeepsNativeKeyboardAndUsesCorrectIndexSide`（旧 L213） · `C`
- `testStaleGitChangeClickCannotOpenDiffInAnotherProject`（旧 L455） · `C`
- `testGitChangesTreeKeyboardBrowsesNestedFilesWithoutWritingIndex`（旧 L585） · `C`
- `testGitGraphIsKeyboardReadyWhenRepositoryHasNoChangedFiles`（旧 L690） · `C`
- `testUncommittedSheetCancelAndConfirmReachRealStash`（旧 L771） · `C`
- `testFolderInlineStageAndUnstageAffectOnlyThatDirectory`（旧 L826） · `C`

### P3-T3 — 18 条

**[GitBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitBranchDialogTests.swift)：4 条** — Git Branch 表单、默认值与动作。初判：UI+逻辑，执行前核对每项真实断言。

- `testBranchCreateAndRenameUseNativeFieldsAndPreserveRetryInput`（旧 L7） · `A`
- `testRemoteCheckoutFetchAndPullExposeNativeDefaults`（旧 L27） · `A`
- `testPushWithoutConfiguredRemotesHasNoPossibleSubmit`（旧 L53） · `A`
- `testDeleteAndPushHaveGitGraphDefaultsWithExplicitDangerousChoices`（旧 L63） · `A`

**[GitCommitDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitCommitDialogTests.swift)：3 条** — Commit Sheet 与仓库身份。初判：UI+逻辑，执行前核对每项真实断言。

- `testNativeFieldsAndMainlineDefaults`（旧 L21） · `A`
- `testSheetStaysInInitiatingWindowAndRejectsSameRepositoryProjectSwitch`（旧 L53） · `C`
- `testProjectResolutionCannotAuthorizeOldRepositorySnapshot`（旧 L164） · `B`

**[GitInteractiveRebaseTests.swift](../../../BaileyTests/NativeUI/Git/GitInteractiveRebaseTests.swift)：3 条** — 原生 PTY／interactive rebase 与 SSH。初判：UI+逻辑，执行前核对每项真实断言。

- `testSSHHelperHandoffUsesTheRebaseFixturesApplication`（旧 L23） · `B`
- `testInteractiveRebaseNewPTYUsesRepositoryAndWaitsForRealEditorInput`（旧 L55） · `C`
- `testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`（旧 L130） · `C`

**[GitRefReplacementTests.swift](../../../BaileyTests/NativeUI/Git/GitRefReplacementTests.swift)：1 条** — Ref 替换、重试与过期输入。初判：UI+逻辑，执行前核对每项真实断言。

- `testBranchAndTagReplacementPreserveRetryInputAndRejectRefMovedDuringConfirmation`（旧 L21） · `C`

**[GitRemoteBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitRemoteBranchDialogTests.swift)：1 条** — Remote Branch 操作确认。初判：UI+逻辑，执行前核对每项真实断言。

- `testFetchBindsLocalDestinationAcrossExternalChangesAndStillAllowsFreshForceAndFastForward`（旧 L21） · `C`

**[GitStashDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitStashDialogTests.swift)：2 条** — Stash 表单与确认。初判：UI+逻辑，执行前核对每项真实断言。

- `testSpecificStashIdentityIndexDefaultsAndBranchInputValidation`（旧 L9） · `A`
- `testNativePopCancellationAndConfirmationUseCapturedSecondStashAndIndexChoice`（旧 L41） · `C`

**[GitTagDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitTagDialogTests.swift)：4 条** — Tag 表单与危险选择。初判：UI+逻辑，执行前核对每项真实断言。

- `testPanelTagPushUsesConfiguredDefaultAndRejectsFailedContainmentQuery`（旧 L21） · `C`
- `testCreationDefaultsAndEditedFieldsSurviveTypeChanges`（旧 L105） · `A`
- `testDeleteRemoteChoicesAreExplicitAndInitiallyLocalOnly`（旧 L128） · `A`
- `testPushSelectionAndNoRemoteSafety`（旧 L141） · `A`

### P3-T4 — 48 条

**[RecentCommitsViewTests.swift](../../../BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift)：48 条** — Git Graph 拓扑、标签、键盘与绘制。初判：UI+逻辑，执行前核对每项真实断言。

- `testDisplayedHistoricalDiffHasGreySelectionIndependentOfGraphFocus`（旧 L120） · `C`
- `testExpandedHistoryAndUncommittedNodesHaveNoPersistentSelectionFill`（旧 L169） · `C`
- `testGraphReferenceBadgeTakesKeyboardFocusFromAnotherTree`（旧 L236） · `C`
- `testGraphClickRecordsFocusIntentBeforeMovingNativeResponder`（旧 L260） · `C`
- `testGraphSpaceUsesTheSelectedCommitAndFileWithoutStealingKeyboard`（旧 L292） · `C`
- `testGraphTreeKeyboardTraversesFoldersAndBothHistoricalFiles`（旧 L347） · `C`
- `testGraphPaletteKeepsTwelveLaneColors`（旧 L399） · `B`
- `testColoredBadgeIconsRemainReadableOverEveryGraphLaneColor`（旧 L414） · `B`
- `testTagStashDetachedAndStandaloneWorktreeIconsMatchGraphColors`（旧 L434） · `C`
- `testHeadAndStashGraphGutterRemainsClickableInBothAppearances`（旧 L503） · `C`
- `testCompositeReferencesUseLongestConfiguredRemoteAndPreserveEveryTarget`（旧 L534） · `B`
- `testCompositeReferencesNeverJoinDifferentCommitRowsOrUnknownRemotes`（旧 L569） · `B`
- `testCompositeOverflowKeepsRealReferencesAvailableWithoutWholeRowScrolling`（旧 L586） · `C`
- `testCurrentAndFeatureUncommittedDiamondsAlignAndToggleInNativeGraph`（旧 L609） · `C`
- `testShortCommitHashCopiesWithoutExpandingDetails`（旧 L672） · `C`
- `testCompactPrimaryBranchTogglesCommitAndKeepsContextMenu`（旧 L689） · `C`
- `testShortPrimaryBranchBadgeKeepsIntrinsicWidth`（旧 L729） · `C`
- `testPrimaryBranchContextMenuRemainsAvailableThroughWidthChanges`（旧 L772） · `C`
- `testGraphNodeHelpOnlyStatesConfirmedHEADMembershipAndActualReferences`（旧 L810） · `C`
- `testNodeHoverTargetRetainsSingleClickAndCommitContextMenu`（旧 L845） · `C`
- `testLongCommitMessageCanScrollHorizontallyInNarrowSidebar`（旧 L877） · `C`
- `testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts`（旧 L890） · `C`
- `testDenseRealNativeGraphRetainsVisibleTitleScrollerInBothThemes`（旧 L917） · `C`
- `testManyParallelBranchesDoNotScrollWholeGraphSideways`（旧 L954） · `C`
- `testShortCommitMessagesDoNotBounceHorizontally`（旧 L977） · `C`
- `testExpandedHistoryKeepsLongFolderPathsScrollable`（旧 L999） · `C`
- `testRecentCommitHistoryOnlyPagesAtBottom`（旧 L1017） · `C`
- `testEntireCommitRowTogglesIncludingGraphMetadataAndBlankSpace`（旧 L1070） · `C`
- `testMergedHistoryOpensItsRealFileAfterExpansion`（旧 L1102） · `C`
- `testCommitTitleExpandsFilesInWideAndNarrowPanels`（旧 L1160） · `C`
- `testNativeContextMenuAtDirectReferencesContainsOnlyTheSelectedObjectActions`（旧 L1216） · `C`
- `testDetachedHeadBadgeExpandsCommitAndKeepsCopyHashInMenu`（旧 L1262） · `C`
- `testSymbolicRemoteAliasOnlyCopiesFromMenuAndTogglesCommit`（旧 L1292） · `C`
- `testDirtyWorktreeDoesNotRepeatLongBranchBadgeInNarrowSidebar`（旧 L1324） · `C`
- `testWorktreeDisplayPathsStayUniqueWithSameCheckoutDirectoryNames`（旧 L1370） · `B`
- `testWorktreeConflictStatusAlwaysUsesUInTreeAndList`（旧 L1389） · `B`
- `testDenseWorktreeGraphKeepsCommitTitlesReadableAcrossThemes`（旧 L1406） · `C`
- `testGraphBadgeRowsStayCompactAcrossAppearanceAndFontSizes`（旧 L1529） · `C`
- `testGraphBadgesUseCompactSharedMetrics`（旧 L1591） · `B`
- `testLocalBranchTakesPriorityOverRemoteDefaultAliasWithoutLosingReferences`（旧 L1598） · `B`
- `testUnassociatedWorktreeLabelChineseTranslationPreservesDirectoryName`（旧 L1624） · `B`
- `testRealWorktreeHistoryRendersNamedLabelsAndPreservesSharedHeadActions`（旧 L1631） · `C`
- `testWorktreePrimaryLabelsReplaceAliasAndIconOnlyCombinations`（旧 L1701） · `C`
- `testDetachedAndUnreferencedWorktreesRetainNativeActionsWithoutDuplicatePills`（旧 L1772） · `C`
- `testCleanWorktreeBadgesAreSeparateFromUncommittedChangesInBothThemes`（旧 L1848） · `C`
- `testUncommittedWorktreeNodeHasSafeMenuAndNativeStageAwareFileActions`（旧 L1950） · `C`
- `testStashIsANodeInTheSameGraphWithOnlyStashActions`（旧 L2051） · `C`
- `testTagBadgeTogglesSameCommitAsOtherReferences`（旧 L2088） · `C`

### P4-T1 — 11 条

**[AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift)：1 条** — 真正用户可见的 Open File 菜单。原有隔离宿主 ⌘Q 断言仍有后续 NativeUI 消费者，归 P4-T5。

- `testFileMenuProvidesOpenFileKeyboardShortcut`（旧 L7） · `A`

**[TreeRowHitTestingTests.swift](../../../BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift)：7 条** — 共享 Files／Git 行命中与滚动。初判：UI，执行前核对每项真实断言。

- `testSelectionFillAndKeyboardOutlineRenderIndependently`（旧 L24） · `A`
- `testTreeFileAndFolderNamesOpenNativeContextMenuWithoutPrimaryAction`（旧 L74） · `A`
- `testShortNamesDoNotBounceInFilesFoldersAndGitChanges`（旧 L234） · `A`
- `testLongNamesScrollWithoutMovingGitActions`（旧 L255） · `A`
- `testSharedLabelStopsBouncingAfterPanelWidens`（旧 L286） · `A`
- `testSharedFileRowSeparatesImmediateBrowseFromDoubleClickActivation`（旧 L322） · `A`
- `testFilesAndGitRowsOwnTheirFullHitArea`（旧 L349） · `A`

**[DockFocusP2RegressionTests.swift](../../../BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift)：3 条** — Dock 点击／拖放、命令面板交接。初判：UI，执行前核对每项真实断言。

- `testClickingEmptyToolPaneReleasesHostingRootResponder`（旧 L22） · `C`
- `testDragReleasedOverAnotherDockGroupDoesNotActivateIt`（旧 L78） · `C`
- `testPaletteFileManagerCommandTransfersKeyboardFocusToVisibleFileTree`（旧 L128） · `C` · **已核销**：根因为伪前台 NSWindow；以 `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor` 的真实 E2E 操作、磁盘原文与标签数验证（`9177817`），旧宿主方法同提交删除。

### P4-T2 — 19 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：19 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testAsyncFilesTargetBecomingCurrentRestoresVisibleFileCursor`（旧 L32） · `C`
- `testFilesCursorDoesNotActivateBehindPaletteBeforeSearchFieldFocus`（旧 L71） · `C`
- `testCancelingCommandPaletteRestoresFilesRowKeyboardNavigation`（旧 L116） · `C`
- `testCurrentToolTreeResponderFollowsDockGroupAfterPanelSwitch`（旧 L197） · `C`
- `testEditorPaletteSwitchToFilesRestoresNewToolKeyboardFocus`（旧 L251） · `C`
- `testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField`（旧 L315） · `C`
- `testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation`（旧 L393） · `C`
- `testFilesActivationBeforeDirectoryListingFocusesFirstVisibleRowWhenLoaded`（旧 L452） · `C`
- `testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus`（旧 L489） · `C`
- `testFilesTreeClickTransfersNativeKeyboardAndArrowsMoveTheVisibleCursor`（旧 L548） · `C`
- `testDockIntegratedFilesRowsKeepNativeFocusWhenOpeningAnotherPane`（旧 L645） · `C`
- `testSwitchingToFileManagerSelectsVisibleCurrentFileAndTakesNativeKeyboard`（旧 L762） · `C`
- `testFilesOpenedInItsOwnDockGroupDoNotRetainHiddenKeyboardFocus`（旧 L814） · `C`
- `testDockGroupClickDoesNotPreemptNativeFieldFocus`（旧 L874） · `C`
- `testNarrowTerminalFindFieldEditorBelongsOnlyToItsActualDockGroup`（旧 L911） · `C`
- `testRestoredGroupIDsReplaceOnlyTheFocusScopesNotTheEditor`（旧 L956） · `C`
- `testFocusAcrossAppearancesAndSizesKeepsTheNativeDocument`（旧 L994） · `C`
- `testResponderOwnershipRejectsInactiveProjectsHiddenTabsAndParking`（旧 L1040） · `C`
- `testDockToolsTakeNativeFocusWithoutReplacingVisibleEditors`（旧 L1100） · `C`

### P4-T3 — 17 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：17 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow`（旧 L1293） · `C`
- `testProjectsDropFilesOpenTabsAndFoldersAddProjects`（旧 L1334） · `C`
- `testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup`（旧 L1377） · `C`
- `testFinderDropIntoEmptyTabGroupKeepsGroupAndDoesNotMoveFilesAcrossProjects`（旧 L1431） · `C`
- `testQueuedFinderBatchRejectsChangedReceivingProjectBeforeRestoredOwnerAttaches`（旧 L1480） · `C`
- `testFinderProjectsDropDoesNotSwitchTargetDuringProviderLoading`（旧 L1532） · `C`
- `testFinderEmptyStateDropCannotOpenIntoFolderAddedWhileProviderLoads`（旧 L1568） · `C`
- `testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow`（旧 L1597） · `C`
- `testExternalBatchRoutesToActualMountedFileBuffers`（旧 L1629） · `C`
- `testExternalOpenFindsExistingFileInOtherWindowBeforeCreatingAnEditor`（旧 L1709） · `C`
- `testFinderReusesMacFileInsideRemoteProjectInAnotherWindow`（旧 L1774） · `C`
- `testExternalOpenDefersUntilAllCreatedWindowsHaveAttached`（旧 L1819） · `C`
- `testExternalOpenKeepsOneDirectoryProjectAcrossInterleavedWindowBatch`（旧 L1863） · `C`
- `testExternalOpenCancelledWhenOwningWindowClosesBeforeRestoreCompletes`（旧 L1906） · `C`
- `testClosingAnUnattachedFileOwnerDrainsAllWaitingFinderEventsWithoutRetargeting`（旧 L1940） · `C`
- `testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever`（旧 L1990） · `C`
- `testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`（旧 L2014） · `C`

### P4-T4 — 15 条

**[WorkspaceContentIdentityTests.swift](../../../BaileyTests/WorkspaceUI/Tabs/WorkspaceContentIdentityTests.swift)：3 条** — 标签和编辑器／Diff／Browser 身份。初判：UI，执行前核对每项真实断言。

- `testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing`（旧 L48） · `C`
- `testFileDiffFileReturnsToSameEditorAndDiffDocument`（旧 L127） · `C`
- `testBrowserTabBetweenTwoFilesDoesNotStealTheirNativeEditors`（旧 L185） · `C`

**[WorkspaceWindowCloseTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowCloseTests.swift)：6 条** — 多窗关闭、保存否决与 Sheet 归属。初判：UI，执行前核对每项真实断言。

- `testEmptyWorkspaceAttachesToWindowWhenHostingViewWasRenderedOffscreen`（旧 L81） · `C`
- `testTwoNativeWorkspacesAttachOwnWindowsAndKeepFolderPickerIsolated`（旧 L117） · `C`
- `testBackgroundProjectDirtyCloseSheetStaysInItsOwningWindow`（旧 L178） · `C`
- `testRepeatedCloseAllKeepsCleanTabsUntilDirtyConfirmationResolves`（旧 L297） · `C`
- `testProjectCloseCannotBypassAnActiveTabClose`（旧 L343） · `B`
- `testNativeCloseDoesNotDiscardFailedSaveThenClosesAfterRetry`（旧 L367） · `C`

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：6 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab`（旧 L1161） · `C`
- `testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers`（旧 L1208） · `C`
- `testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot`（旧 L2057） · `C`
- `testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows`（旧 L2124） · `B`
- `testLocalWorktreeUseProtectsMacFileInsideAnSSHProject`（旧 L2172） · `B`
- `testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection`（旧 L2205） · `B`

### P4-T5 — 21 条

**[PaneRetentionTests.swift](../../../BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift)：20 条** — Terminal／Browser／Editor 原生资源生命周期。初判：UI+逻辑，执行前核对每项真实断言。

- `testParkingDropsObsoleteHostActionsBeforeDelayedDismantle`（旧 L12） · `C`
- `testTerminalFindFieldStaysInsideNarrowAndWidePanes`（旧 L47） · `C`
- `testProjectAndPaneTabObservationsReplacePublisherRelays`（旧 L94） · `B`
- `testNativeUnsavedConfirmationPreservesSheetAndButtonSemantics`（旧 L124） · `C`
- `testNativeFileAndSSHChoosersStayOnOwningWindow`（旧 L157） · `C`
- `testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects`（旧 L232） · `C`
- `testBrowserKVOUpdatesObservationHistoryFaviconAndRepeatedFocus`（旧 L304） · `C`
- `testWebKitJavaScriptDialogsInvokeNativeDelegateSheets`（旧 L373） · `C`
- `testBrowserAndEditorStateSurviveViewRemount`（旧 L419） · `C`
- `testClosingMountedFiveFileTabsReleasesTheirNativeDocuments`（旧 L515） · `C`
- `testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears`（旧 L647） · `C`
- `testHundredThousandLineWorkspaceEditsSavesAndReleasesFile`（旧 L690） · `C`
- `testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks`（旧 L777） · `C`
- `testExternalReloadReleasesObsoleteDocumentEvenWhenOldScrollViewIsCached`（旧 L859） · `C`
- `testEditorRetainsScrollAndReleasesRetiredNativeResources`（旧 L942） · `C`
- `testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`（旧 L1028） · `C`
- `testTerminalAndFindObservationPreserveNativeSurfaceIdentity`（旧 L1124） · `B`
- `testUnmanagedForegroundSSHRejectsLocalFinderPathsBeforeAnyRemoteHandoff`（旧 L1177） · `B`
- `testUnmanagedExecSSHRejectsLocalFinderPathsEvenWhenForegroundPIDIsShellPID`（旧 L1181） · `B`
- `testTerminalKeepsSameShellAcrossParkingAndRemount`（旧 L1236） · `C`

**[AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift)：1 条** — 前期 NativeUI 宿主仍需防止 ⌘Q 意外结束测试；直到最后一条原生宿主测试迁走才一起删除覆盖与产品中的测试专属拦截。

- `testTestHostHasNoQuitKeyboardEquivalent`（旧 L23） · `A`


## 非 UI Target 的混入检查

原有 Unit 8 文件／75 方法、Integration 20 文件／231 方法；目录名不能证明没有图形依赖。P1-T3 对 306 个方法及其 transitive fixtures 复核：以「实际创建窗口、绘制、聚焦、事件输入、UI 表现」而非单独 `import AppKit` 判断。

**额外重点：[`SessionStoreTests.swift`](../../../BaileyTests/Integration/Workspace/SessionStoreTests.swift)**：原有 10 方法，其中下列两项具有明确原生窗口/视图依赖，归 `P4-T4` 完整替代；其余方法亦须逐项检查：

- `testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction`（`NSHostingView`／`NSWindow`／`NSTextView` 身份）：P4-T4 将用户可见保留行为归 UI，快照单一性逻辑归非 UI。
- `testClosedWindowCannotBeUsedForLateFileOperationErrors`（真实 `NSWindow` 装配）：P4-T4 将窗口关后错误不可回送的最终行为归 UI，目标识别不变量可保留非 UI。

**[`AppSettingsTests.swift`](../../../BaileyTests/Integration/Settings/AppSettingsTests.swift)**：5 方法，**全部都需审查隐藏的全局 UI 副作用**。源码 `AppSettings.init(configURL:)` 最后无条件执行 `applyAppearance()`（写 `NSApp?.appearance`）和 `reloadThemeSelection()`（写 `Theme` 全局选择），即使某条测试只验证 TOML 解析也会触发；其中两项还显式在 teardown 恢复 `NSApp?.appearance`，一项设置 `.theme = .dark` 再次写入。P1-T3 先查明并清理可安全去掉的非 UI 初始化/测试副作用，证明共享 `AppSettings.shared` 启动外观不变；P4-T5 再验真实 Settings GUI。保留具有实质断言的配置/Observation/Theme 回归，不能以“仅两条触及 NSApp”漏掉其余三条。

**P1-T3 已实施的根因修正（仍待真实 XCTest）：** `AppSettings.shared` 成为唯一应用级外观/主题传播者。临时配置实例不再写 NSApp/Theme；多余的 NSApp 恢复测试代码已移除。`AppSettingsTests` 新增 1 项专门验证无全局主题污染，执行 `resetToDefaults()` 时使用临时 UserDefaults suite。原 306 条 Unit/Integration 基线现为 307 条；2 条 `SessionStoreTests` 原生窗口用例仍归 P4-T4。Debug App 和宿主 Test Bundle 已成功编译，**没有运行 XCTest**，真正的主题显示与重启仍归 P4-T5 独立 GUI Runner 核验。

## BaileyUITests：原有 10 条 + P1 新增 3 条（共 13 条）

P1-T2 实测：`make test:ui SIGNING=adhoc` 完整运行 **12/12 passed、0 failed、0 skipped**，xcresult `Test-Bailey-UI-2026.10.22_19-00-05-+0800.xcresult` 核验 `totalTestCount=12`。先前两条 Git 用例因沙盒中的 `/usr/bin/git` 调用 xcrun 失败，改为直接调用 Command Line Tools Git 后通过；中文 Sheet 按标准 `OKButton` 确认、Escape 取消。弱引用、双窗口并列相同树行和真实物理 IME 归后续领域任务，不虚报。

**[WorkspaceFilesUITests.swift](../../../BaileyUITests/Files/WorkspaceFilesUITests.swift) — 4 条：P1-T2 实测基线，按后续领域任务补足断言**
- `testAddFolderAndOpenFileThroughRealFileTree`
- `testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`
- `testNativeEditorSavesActualFileContentsToDisk`
- `testOpeningTheSameFileFromMenuReusesItsExistingTab`
- `testSameNamedFilesInDifferentFoldersHaveDistinctRowsAndTabs`（P1 新增）
- `testChinesePickerOpensFileWithLongUnicodePath`（P1 新增，中文界面、原生 Sheet、长 Unicode AX 路径；不是长中文路径输入面板验证）
- `testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor`（P1 提前核销 P4-T1 的原生焦点方法，真实从编辑器到 Files 的 Command Palette、键盘导航与磁盘内容）

**[WorkspaceGitUITests.swift](../../../BaileyUITests/Git/WorkspaceGitUITests.swift) — 2 条：P1-T2 实测基线，按后续领域任务补足断言**
- `testGitGraphDisplaysTheRealCommitAndExpandsItsFiles`
- `testGitChangesAreScopedToTheOpenedRepository`

**[WorkspaceSmokeUITests.swift](../../../BaileyUITests/Workspace/WorkspaceSmokeUITests.swift) — 1 条：P1-T2 实测基线，按后续领域任务补足断言**
- `testIsolatedLaunchAndPaletteKeyboardFocus`

**[WorkspaceWindowsUITests.swift](../../../BaileyUITests/Workspace/WorkspaceWindowsUITests.swift) — 3 条：P1-T2 实测基线，按后续领域任务补足断言**
- `testTwoEmptyWindowsHaveIndependentNativeLifecycle`
- `testSettingsOpensFromTheRealApplicationShortcut`
- `testCancelingFolderPickerDoesNotCreateAnEmptyProject`

## 执行核销准则

1. P1-T1 逐行读取旧断言和 fixture，在该方法的后续核销证据中补充三个互斥结果之一：①跨进程 UI 测试新方法与真实副作用，②保留／移至非 UI Unit/Integration 的新方法与逻辑断言，③混合拆分，分别列出上述两类。不能仅标「转移完成」或只填新文件名。
2. 迁移 task 针对自己负责的源方法逐一 Red→Green（适用时）；验证的触发条件、期望效果、失败恢复与原始断言一致或更强，才移除旧方法和测试支架。`WorkspaceWindowIsolationTests` 三个任务分别移走覆盖方法，最后一个任务清空原文件。
3. 对 Source／Xcode Target 的实际测试发现建立「旧集合 - 已落地目标集合」核销；若后续其他 PR 增删了测试，先更新基线和负责 task，不让清单冻结成盲点。
4. 原始用例包含平台底层暂不可由 XCUIApplication 直接读到的断言时，保留非 UI 不变量验证与真实用户副作用，并列出 UI 观测的能力差异、替代证据和是否阻塞；未验证的原生颜色、几何、IME 与生命周期不可擅自删除。

