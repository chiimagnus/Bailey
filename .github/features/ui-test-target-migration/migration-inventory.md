# 迁移清单：方法级零遗漏基线

> 2026-10-22，规划分支 `019765f`，仅为源码静态快照。这里登记**迁移责任**，不是已通过结果；完成／阻塞状态唯一归 `todo.toml`。迁移时每个 task 必须逐方法写下实际替代测试（或移入 Unit/Integration 的方法）、命令、输出与原因。方法可能合并成同一 E2E 路径，但不能丢失原断言。改动前后都要重新生成清单做集合差分。

**2026-10-23 最新 P2 本机证据：** 完整独立 Bailey Dev `make test:ui DERIVED_DATA=build/DerivedData-P2-MultiLanguage` **21/21 Passed、0 failed、0 skipped、exit 0**，真机 Xcode `.xcresult` 已核对。含新 Markdown／TSX／HTML／CSS 着色与纯文本截图、实际文件字节；原生编辑器字符/Undo/Redo/保存；文件、Git Diff 和窗口。P2 原始144条方法逐一映射，旧 NativeUI 五套源码已删除。跨环境 CI、macOS15.6、真实 SSH/实体输入法不由本机结果代替。

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

**2026-10-23 P2-T3 验收：** 原22个 `test*` 方法与原类方法体、私有夹具逐字等价，仅类名更换；位置为 `Integration/Editor`。已真实执行签名宿主22/22通过；`EditorHighlightingUITests` 在独立 Bailey Dev 中完成 Swift、Markdown/TSX/HTML/CSS 对照纯文本的真实截图差异及最终字节检查（新增多语言用例与原 Swift 用例 2/2 PASS）。完整 Bailey Dev GUI 20/20 通过，高亮真实截图和字节 E2E 通过；其他真实 IME 候选、CI／其他 OS 与主题极端组合须分别核销。

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

**原 `BaileyTests/NativeUI/Git/GitHistoryFileTests.swift`：21 条** — 历史快照、只读、恢复与文件重置。现保留 20 项模型／后端断言于 [NativeGitHistoryFileTests.swift](../../../BaileyTests/Integration/Git/NativeGitHistoryFileTests.swift)，一项原生 `setAccessibilityValue` 安全契约归 [NativeDiffTabTests.swift](../../../BaileyTests/Integration/Git/NativeDiffTabTests.swift)；原生挂载交互由 [GitHistoryUITests.swift](../../../BaileyUITests/Git/GitHistoryUITests.swift) 从真实 App 验证。新 E2E 使用专属 `bailey.git.history.file` AX 标识，不与工作区 Changes 中同名路径混淆。

- `testRevisionIsNativeReadonlyTextOfSelectedCommitEvenWithSharedEditPreference`（旧 L50） · `C` → `NativeGitHistoryFileTests.testRevisionRemainsReadonlyWhenSharedPreferencesEnableEditing` + `GitHistoryUITests.testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile`
- `testNativeDiffAccessibilityAllowsOnlyEditableTextChanges`（旧 L98） · `C` → `NativeDiffTabTests.testNativeDiffAccessibilityAllowsOnlyEditableTextChanges`（原生 AX 安全契约）+ `GitHistoryUITests.testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile`（真实键入后仍只读）
- `testRevisionToWorktreeFollowsRenameAndRefreshesWithoutWritingHistoricalBlob`（旧 L113） · `B` → `NativeGitHistoryFileTests.testRevisionToWorktreeFollowsRenameAndRefreshesWithoutWritingHistoricalBlob` + `GitHistoryUITests.testRenamedHistoricalFileComparesAndOpensActualWorkingFile`（真实 GUI 待验）
- `testHistoricalDiffPreviewKeepsGitActiveAndExplicitActivationStillWorks`（旧 L138） · `C` → `NativeGitHistoryFileTests.testHistoricalDiffPreviewKeepsGitActiveAndExplicitActivationStillWorks` + `GitHistoryUITests.testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile`
- `testReopeningLoadedImmutableRevisionDoesNotRepeatGitRead`（旧 L189） · `C` → `NativeGitHistoryFileTests.testReopeningLoadedImmutableRevisionDoesNotRepeatGitRead`
- `testUnmergedWorktreeUsesStageTwoAndPreservesConflictStatus`（旧 L221） · `B` → `NativeGitHistoryFileTests.testUnmergedWorktreeUsesStageTwoAndPreservesConflictStatus`
- `testUnbornIndexAndLiteralSpecialPathResolveCorrectBlobs`（旧 L248） · `B` → `NativeGitHistoryFileTests.testUnbornIndexAndLiteralSpecialPathResolveCorrectBlobs`
- `testReadFailureDoesNotEraseAlreadyLoadedHistoricalText`（旧 L291） · `B` → `NativeGitHistoryFileTests.testReadFailureDoesNotEraseAlreadyLoadedHistoricalText`
- `testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`（旧 L316） · `B` → `NativeGitHistoryFileTests.testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`
- `testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected`（旧 L364） · `B` → `NativeGitHistoryFileTests.testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected`
- `testInvalidRevisionIsNotMisreportedAsAFileMissingFromValidCommit`（旧 L390） · `B` → `NativeGitHistoryFileTests.testInvalidRevisionIsNotMisreportedAsAFileMissingFromValidCommit`
- `testDanglingHeadRefIsNotMistakenForUnbornStagedDiff`（旧 L407） · `B` → `NativeGitHistoryFileTests.testDanglingHeadRefIsNotMistakenForUnbornStagedDiff`
- `testDeletedHistoricalDiffValidatesTheSelectedCommit`（旧 L430） · `B` → `NativeGitHistoryFileTests.testDeletedHistoricalDiffValidatesTheSelectedCommit`
- `testMissingSelectedRevisionReportsErrorButRootAndDeletedSidesMayBeEmpty`（旧 L460） · `B` → `NativeGitHistoryFileTests.testMissingSelectedRevisionReportsErrorButRootAndDeletedSidesMayBeEmpty`
- `testResetHistoricalBinaryFileUpdatesIndexAndWorktreeWithoutChangingHead`（旧 L490） · `B` → `NativeGitHistoryFileTests.testResetHistoricalBinaryFileUpdatesIndexAndWorktreeWithoutChangingHead` + `GitHistoryUITests.testHistoricalResetConfirmationCancellationAndActualGitBytes`
- `testResetHistoricalFileRefusesStaleWorkingBytesAfterConfirmation`（旧 L528） · `B` → `NativeGitHistoryFileTests.testResetHistoricalFileRefusesStaleWorkingBytesAfterConfirmation` + `GitHistoryUITests.testHistoricalResetConfirmationCancellationAndActualGitBytes`
- `testResetFileSavesDirtyTabThenOverwritesIndexDiskAndReloadsSameTab`（旧 L558） · `B` → `NativeGitHistoryFileTests.testResetFileSavesDirtyTabThenOverwritesIndexDiskAndReloadsSameTab` + `GitHistoryUITests.testHistoricalResetConfirmationCancellationAndActualGitBytes`
- `testResetFileRejectsIndexChangeDuringPreparation`（旧 L607） · `B` → `NativeGitHistoryFileTests.testResetFileRejectsIndexChangeDuringPreparation` + `GitHistoryUITests.testHistoricalResetConfirmationCancellationAndActualGitBytes`
- `testProjectRestoresDistinctNativeTabsForHistoricalDiffModes`（旧 L634） · `C` → `NativeGitHistoryFileTests.testProjectRestoresDistinctNativeTabsForHistoricalDiffModes` + `GitHistoryUITests.testRealCommitHistoryOpensImmutableRevisionWithoutChangingWorkingFile`
- `testExpandingCommitLoadsBinaryMetadataOnceAndPreservesGitRenamePaths`（旧 L684） · `B` → `NativeGitHistoryFileTests.testExpandingCommitLoadsBinaryMetadataOnceAndPreservesGitRenamePaths`
- `testSelectedBinaryAndLargeRevisionsExplainWhyTheyCannotRenderAsText`（旧 L711） · `B` → `NativeGitHistoryFileTests.testSelectedBinaryAndLargeRevisionsExplainWhyTheyCannotRenderAsText`


**P3-T1 验证记录（2026-10-23）**：最终拆分后的 20 项 `NativeGitHistoryFileTests` 已 20/20 通过；AX setter 契约在 `NativeDiffTabTests`，其新增 setter 测试及其它原生 Diff 回归 36/36 通过；联动 `GitStatusModelTests`、`GitExecutionTests` 合计 89/89 通过。完整 Bailey Dev `GitHistoryUITests` 已 5/5 通过、0 跳过（`Test-Bailey-UI-2026.10.23_12-34-58-+0800.xcresult`）；逐项执行了只读 revision、重命名后真实工作区文件、二进制／超限提示、重置取消／确认、外部修改后拒绝覆写，均核对临时 Git 仓库的磁盘／index／HEAD。此前两个 GUI 中断分别来自测试远程命令的 120 秒超时和遗留的隔离 Dev 进程，不属于产品失败；已使用更长执行预算并只清理经过命令行确认的测试进程。正式 App 未操作；真实 SSH、macOS 15.6 及跨主题／显示设备组合无本轮实机证据。P3-T1 已于 `f0f8699fab6340bedfe203b73cc9ad5180bb80cb` 原子提交，Feature 计划证据按规则仅本地维护。

### P3-T2 — 15 条

**原 `GitExternalRefreshTests.swift`：4 条，按实际事件源迁移**

- `testVisibleLocalPanelDetectsExternalInitialization`（旧 L23） · `C` → `GitChangesUITests.testExternalGitInitializationAppearsWithoutManualRefresh`（真实 App 已通过）。
- `testVisibleGitPanelRefreshesTwoExternalMutationsWithoutActivation`（旧 L70） · `C` → `GitChangesUITests.testExternalWorktreeIndexAndCommitRefreshTheRealGitPanel`（已通过）+ `GitStatusModelTests.testLocalFileEventsPauseInBackgroundAndRestoreOnActivation`、`testLocalFileChangesRefreshWithoutPollingOrManualRefresh`、`testLocalWatcherStopsFollowingPreviousWorkspace`（宿主已通过）。
- `testVisibleGitPanelKeepsRefreshPendingWhileRemoteDetailsAreSlow`（旧 L255） · `C` → `GitRemoteRefreshIntegrationTests.testRemotePollQueuesSlowDetailRefreshAndStopsOnCancellation`（受控慢响应、模型定时触发与任务取消；审计后 15.127 秒测试通过，不再挂载 SwiftUI 面板）。
- `testVisibleSSHPanelRefreshesExternalGitChanges`（旧 L356） · `C` → `GitRemoteRefreshIntegrationTests.testAuthorizedSSHRemotePollDetectsExternalChangesAndStopsWhenCancelled`（获准 `windows` 的专用 SSH 临时仓库，审计后真实刷新、暂停／恢复及取消通过，56.108 秒）。

**原 `GitWorkspaceMenuTests.swift`：11 条，按真实用户操作归属迁移**

- `testUncommittedDialogDefaultsAndPermanentCleanWarning`（旧 L18） · `A` → `GitUncommittedUITests` 的 Reset／Stash／Clean 原生 Sheet（真实 GUI 完整套件 3/3 通过，Clean Escape 取消、Reset Mixed/Hard、Stash 及 Git 字节均已验）。
- `testIgnoreAppendsNativeBufferSavesAndCanUndoWithoutRemounting`（旧 L35） · `C` → `GitIgnoreEditorUITests.testIgnoreUpdatesOpenNativeEditorAndCommandZCanUndoTheInsertedPatterns`（完整 App 1/1 通过：复用文件标签、原生 Undo 和保存）+ `GitIgnoreIntegrationTests.testIgnoreEscapesSpecialFileNamesAndPreservesUnsavedCRLFBuffer`（3/3 集成通过：CRLF、转义与错误输入）。不保留重复的 NativeUI 挂载测试。
- `testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView`（旧 L84） · `B` → `GitIgnoreIntegrationTests.testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView`（已通过）。
- `testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget`（旧 L112） · `B` → `GitIgnoreIntegrationTests.testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget`（已通过）。
- `testIgnoreContextMenuIsOnlyOfferedForUntrackedFiles`（旧 L134） · `C` → `GitChangesUITests.testIgnoreMenuRejectsTrackedChangesAndWritesLiteralUntrackedRule`（含 intent-to-add 必须不能忽略的边界定点 GUI 1/1 通过）。
- `testGitChangeRowPreviewKeepsNativeKeyboardAndUsesCorrectIndexSide`（旧 L213） · `C` → `GitChangesUITests.testStagedAndUnstagedRowsPreviewTheirDistinctGitBaselines`（Staged 只读／Unstaged 可编辑的不同控件结构与 HEAD/index/worktree 字节纠正后定点 GUI 1/1 通过）+ `testGitChangeKeyboardDownAndSpacePreviewTheNextFileWithoutGitWrites`（已通过）；Graph 焦点转移详见 P3-T4。
- `testStaleGitChangeClickCannotOpenDiffInAnotherProject`（旧 L455） · `C` → `GitChangesUITests.testChangingProjectsCannotDisplayOrWriteTheFormerGitRepository`（已通过）+ `GitStatusModelTests.testContextChangeDuringMutationPreflightDoesNotSwitchOldRepository`（已通过）。
- `testGitChangesTreeKeyboardBrowsesNestedFilesWithoutWritingIndex`（旧 L585） · `C` → `GitChangesUITests.testNestedGitChangesTreeSupportsArrowSpaceReturnAndCollapseWithoutWritingIndex`（已通过）。
- `testGitGraphIsKeyboardReadyWhenRepositoryHasNoChangedFiles`（旧 L690） · `C` → `GitChangesUITests.testGitGraphSpaceExpandsCommitWhenChangesListIsEmpty`（已通过）。
- `testUncommittedSheetCancelAndConfirmReachRealStash`（旧 L771） · `C` → `GitUncommittedUITests.testStashCancelThenConfirmChangesOnlyTheIsolatedRepository`（已通过）。
- `testFolderInlineStageAndUnstageAffectOnlyThatDirectory`（旧 L826） · `C` → `GitChangesUITests.testFolderStageAndUnstageTouchesOnlyNestedSelectedDirectory`（右键菜单已通过）+ `testFolderInlineStageAndUnstageAreScopedToThatDirectory`（真正的文件夹行尾按钮 GUI 定点 1/1 通过）。

**P3-T2 实测证据（2026-10-23）**：旧 `GitWorkspaceMenuTests` 11 项和 `GitExternalRefreshTests` 4 项已逐方法映射；删除原有两份宿主 UI 测试文件。独立 Bailey Dev 的 `GitChangesUITests` 完整 11/11（`/tmp/bailey-p3-t2-gitchanges-final-full.log`），额外 merge-conflict 的「标记已解决」真实 index/工作区/HEAD 验证 1/1（`/tmp/bailey-p3-t2-merge-conflict-gui.log`），`GitUncommittedUITests` 3/3、`GitIgnoreEditorUITests` 1/1。受控慢 SSH/真实授权 `windows` 外部 Git 刷新、`.gitignore` 特殊路径、Clean／Reset／Stash 操作在定点宿主中已 10/10 通过；删除了与 E2E 重复、违反分层目标的新增 NativeUI TextKit 挂载夹具，改用真实 App Undo 与纯后端 CRLF 分层守护。最终复测 `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:GitRemoteRefreshIntegrationTests,GitIgnoreIntegrationTests,GitUncommittedActionTests,GitStatusModelTests DERIVED_DATA=build/DerivedData` → **58/58 通过、0 失败、0 跳过、exit 0**（`/tmp/bailey-p3-t2-split-fixture-host.log`），真实远端文件刷新 3.21 秒、提交刷新 1.28 秒。Swift 6.4.2 将原测试文件共享 actor 与新 SSH 测试编入同批时误报 actor 合成 `nonisolated init`；单独添加 `init()` 无效，故将现有 `DiscardRemoteWorkspaceFixture` 原样抽到独立 Integration/Git 文件，最终编译和测试恢复正常。

**全量宿主限制**：`/tmp/bailey-p3-t2-host-full-windows.log` 发现 626 项、616 Pass／10 Fail／0 Skip。10 个失败中 9 项为 `WorkspaceWindowIsolationTests` 原生窗口焦点等待超时，1 项为 `PaneRetentionTests` Dock 重挂后 firstResponder 未恢复；单独跑这 62 项时也再次发生同样 10 项失败（`/tmp/bailey-p3-t2-focus-isolation.log`）。不归因于 P3-T2 Git 生产代码（本任务无 Git 生产改动），但同样不冒称全量宿主成功；其原生窗口焦点所有权需要在 P5 迁移和最终 Gate 中继续根因修复与完整 GUI 补验。

### P3-T3 — 18 条

**2026-10-23 完成证据**：P3-T3 → Git `5f7d512`，旧 18 方法分层迁移并删除七份旧原生对话框测试。完整 Bailey Dev GUI `GitDialogUITests` **21/21**（`/tmp/bailey-p3-t3-gitdialog-full.log`，exit 0）；此前真实 Git 五组后端 **61/61**，末次仅重测受改动影响的 `GitBranchActionTests,GitTagActionTests` **21/21**（`/tmp/bailey-p3-t3-targeted-branch-tag-final.log`，exit 0）；独立 PTY／授权 Windows SSH **3/3**（`/tmp/bailey-p3-t3-rebase-integration.log`）。不重复跑未受影响的 GUI 和宿主测试。目标 App 仅 `chiimagnus.bailey.dev`，产品代码及正式 Bailey 未改。Xcode 27.2 偶发菜单栏无窗口，启动器仅在缺失窗口时调用原生「新建窗口」。本地 bare remote 未覆盖互联网网络故障或真实 provider；非法名称错误 UI 展示、真实用户交互时的跨窗口焦点抢占及 PTY EOF 组合未独立实测，不能据此宣称外部环境全部验证。

**`GitBranchDialogTests.swift` 原 4 条均已由独立 Dev GUI 加 Git Action 集成测试核销，旧文件已删除**。涵盖从历史／当前 HEAD 创建、重命名、Remote Checkout/Fetch/Pull、Push 无 remote 禁用与多远端选择、Delete Force/Remote 默认关闭、Git refs/index/HEAD/工作区最终结果，详见下列逐项证据。

- `testBranchCreateAndRenameUseNativeFieldsAndPreserveRetryInput`（旧 L7） · `A` → `GitDialogUITests.testCurrentBranchNativeSheetDefaultsToCheckoutAndPreservesGitBytes` + `testBranchRenameAndNoRemotePushUseNativeRefMenuWithoutUnsafeChanges`（真实 Sheet 预填、禁用空名、Checkout 默认、重命名和 Git Ref／索引字节通过）。非法名称由 `GitBranchActionTests.testBranchRefValidationAndOtherWorktreeCheckoutGuard` 检查真实 `git check-ref-format` 拒绝及 HEAD／Ref 不变；原生错误展示不冒称 E2E 已测。
- `testRemoteCheckoutFetchAndPullExposeNativeDefaults`（旧 L27） · `A` → `GitDialogUITests.testRemoteFetchAndPullNativeDefaultsPreserveOrAdvanceOnlyExpectedRefs` 真实 Fetch 非强制、Pull 非强制建提交/非 Squash、取消无副作用、确认后 branch、HEAD 和磁盘字节正确（1/1，`/tmp/bailey-p3-t3-remote-fetch-pull-overflow.log`）；`testRemoteCheckoutNativeSheetValidatesNameAndCreatesTrackingBranch` 已验证远端检出名称预填、空白禁止、取消不写入、创建跟踪分支后上游配置、HEAD 与文件字节（1/1，`/tmp/bailey-p3-t3-remote-checkout.log`）。Fetch 后同 OID 的远端 Ref 被合并至 `+N` 子菜单，测试已按 AX 结构修正入口。
- `testPushWithoutConfiguredRemotesHasNoPossibleSubmit`（旧 L53） · `A` → `GitDialogUITests.testBranchRenameAndNoRemotePushUseNativeRefMenuWithoutUnsafeChanges`（真实 Git Graph 右键，无 Remote 的 Push Sheet 提交按钮禁用、实际 Git 无写入，1/1，`/tmp/bailey-p3-t3-branch-push-rename-gui.log`）。
- `testDeleteAndPushHaveGitGraphDefaultsWithExplicitDangerousChoices`（旧 L63） · `A` → `GitDialogUITests.testBranchPushNativeSheetChoosesOnlySelectedBareRemote` 验证多远端优选、设置上游默认开启、全部取消时禁用提交与选定 bare remote 实际推送（1/1，`/tmp/bailey-p3-t3-branch-multiremote-push.log`）；`testBranchDeleteDefaultsPreserveRemoteAndCancelIsNoOp` 又验证 Force/Delete Remote 两项默认关闭、取消无副作用、确认后仅删本地已合并分支而保留远端 Ref（1/1，`/tmp/bailey-p3-t3-branch-delete-defaults.log`）。

**`GitCommitDialogTests.swift` 原 3 条已核销，旧文件删除**；模型身份测试已先迁往 `GitCommitActionTests`，其余两个旧 UI 方法由如下真实 App 路径接替。

- `testNativeFieldsAndMainlineDefaults`（旧 L21） · `A` → `GitDialogUITests.testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory`（双父提交、各项默认、取消、真实 Checkout）+ `testDropCommitNativeConfirmationCancelsThenRewritesOnlySelectedHistory`（原生 Drop 取消／确认后真实提交图与文件），均 1/1 通过；`/tmp/bailey-p3-t3-commit-dialogs-gui.log`、`/tmp/bailey-p3-t3-drop-real-gui.log`。
- `testSheetStaysInInitiatingWindowAndRejectsSameRepositoryProjectSwitch`（旧 L53） · `C` → `GitDialogUITests.testCommitSheetBelongsToItsWindowWhenAnotherWorkspaceTakesFocus`：两真实窗口、原生 Sheet 属主、取消不写、确认正确 Checkout、另窗未变，1/1（`/tmp/bailey-p3-t3-commit-two-windows-final.log`）；同仓库项目切换与关闭窗口造成的过期 action 由 `GitCommitActionTests` 的目标身份拒绝链及生产 `GitPanel.presentCommitDialog` 的项目／窗口双重判定约束。原旧测试通过直接修改 manager／关闭挂着 Sheet 的窗口注入了不可通过 Sheet 模态交互直接触发的状态，不能把 GUI 覆盖冒称该注入情形也实测。
- `testProjectResolutionCannotAuthorizeOldRepositorySnapshot`（旧 L164） · `B` → [GitCommitActionTests.swift](../../../BaileyTests/Integration/Git/GitCommitActionTests.swift) 原完整模型拒绝链，测试切走与返回的旧 target 均拒绝危险 Checkout；`make test:GitCommitActionTests DERIVED_DATA=build/DerivedData` 14/14（含本项，0 失败／0 跳过，2026-10-23）。原 NativeUI 类仅留两条真正需要表单／窗口的用例。

**[GitInteractiveRebaseIntegrationTests.swift](../../../BaileyTests/Integration/Remote/GitInteractiveRebaseIntegrationTests.swift)：原 3 条完整迁入 Integration/Remote（2026-10-23）**。只测试测试实例的 SSH 服务归属、真实 PTY 组件挂载、远端终端与 Git 副作用；不是完整 App 菜单 E2E。

- `testSSHHelperHandoffUsesTheRebaseFixturesApplication`（旧 L23） · `B` → 原断言完整保留，验证专属 `BAILEY_SSH_SOCKET`／token 和通知服务归属（passed）。
- `testInteractiveRebaseNewPTYUsesRepositoryAndWaitsForRealEditorInput`（旧 L55） · `C` → Integration/Remote 仍验证原生终端挂载、TTY、等待真实编辑器输入、提交重写和终端生命周期；另由 `GitDialogUITests.testInteractiveRebaseFromGitGraphOpensRealPTYAndAcceptsEditorInput` 从完整 App 图谱打开 Rebase Sheet、启动真正 PTY、键盘回车后确认 Git DAG／工作区（`/tmp/bailey-p3-t3-rebase-clean-production.log`，1/1，36.841 秒）。Runner 沙盒内的编辑器脚本不能被 Dev App `exec`（真实 Git 报 `Operation not permitted`），测试改用 Git 配置中的原生 `/bin/sh -c` 内联编辑器，无产品后门或额外权限。
- `testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`（旧 L130） · `C` → Integration/Remote 保留真实授权 `windows` 临时仓库、固定与自动跟随 SSH 独立握手（两条路径 passed，已清理测试 master）。

验证：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:GitInteractiveRebaseIntegrationTests DERIVED_DATA=build/DerivedData` → 3/3、0 失败、0 跳过，56.314 秒，`/tmp/bailey-p3-t3-rebase-integration.log`。

**`GitRefReplacementTests.swift` 原 1 条已核销并删除旧文件**。

- `testBranchAndTagReplacementPreserveRetryInputAndRejectRefMovedDuringConfirmation`（旧 L21） · `C` → `GitDialogUITests.testHistoricalBranchReplacementRejectsMovedRefAndPreservesRetryName` 与 `testHistoricalTagReplacementRejectsMovedRefAndRetainsAnnotation` 各 1/1：Ref 同名时 Choose Another Name 保留输入／Tag 注释，确认已出现后外部 `git update-ref`，旧确认 CAS 拒绝且 2 秒反向监听无延迟写入，再重新确认才能指向旧 Commit。日志 `/tmp/bailey-p3-t3-branch-stale-inverted.log`、`/tmp/bailey-p3-t3-tag-stale-replace-gui.log`。新增 `GitDialogUITests.testLateBranchAndTagCollisionPreserveRetryInputsWithoutOverwritingRefs` 再覆盖创建 Sheet 打开后外部竞争的同名 Ref，重试前后的输入和实际 Ref／HEAD 未被误写（`/tmp/bailey-p3-t3-late-collision.log` 1/1）。

**`GitRemoteBranchDialogTests.swift` 原 1 条已核销并删除旧文件**。

- `testFetchBindsLocalDestinationAcrossExternalChangesAndStillAllowsFreshForceAndFastForward`（旧 L21） · `C` → `GitDialogUITests.testRemoteFetchRejectsMovedLocalDestinationThenAllowsFreshForceAndFastForward`（原生 Force Fetch 默认关闭，Sheet 期间外部移动本地 Ref 后旧确认拒绝；重新 Force／正常 fast-forward 均真实成功，HEAD／文件／index 未误改，`/tmp/bailey-p3-t3-remote-fetch-stale-recovery.log`，1/1）。

**`GitStashDialogTests.swift` 原 2 条均已由 `GitDialogUITests` 与 `GitStashActionTests` 核销，旧文件已删除**。原生 Sheet selector/OID 用 `StaticText.value` 验证，Esc 取消、第二条 Stash 的 Pop／索引恢复与 Branch 创建均验证真实 Git 结果；补验证据 `/tmp/bailey-p3-t3-stash-oid-value-escape.log`。

- `testSpecificStashIdentityIndexDefaultsAndBranchInputValidation`（旧 L9） · `A` → `GitDialogUITests.testStashNativeApplyDropAndBranchUseSelectedOlderEntry`：旧 Stash 的 Apply/Drop 取消无副作用，Pop 索引默认关闭，分支名空白禁止提交，Create Branch 实际仅消耗所选旧 selector 而保留最新 Stash，恢复 index/文件/HEAD（1/1，`/tmp/bailey-p3-t3-stash-branch-all-actions.log`）。
- `testNativePopCancellationAndConfirmationUseCapturedSecondStashAndIndexChoice`（旧 L41） · `C` → `GitDialogUITests.testOlderStashNativePopCancelAndReinstateIndexUseCapturedOID`（原生 Sheet、旧 selector 身份、取消、勾选恢复 index 后真实 Git/Stash 列表/文件，`/tmp/bailey-p3-t3-gitdialogs-native-full.log` 整组 4/4）。

**`GitTagDialogTests.swift` 原 4 条已核销并删除旧文件**；原生 Tag UI 的实际选择、取消、写入及后端失败分层验证。

- `testPanelTagPushUsesConfiguredDefaultAndRejectsFailedContainmentQuery`（旧 L21） · `C` → `GitDialogUITests.testTagPushUsesTagDefaultRemoteNotBranchPushRemote` 验证真实多远端 Push 只写选定的 bare remote；`GitTagActionTests.testFailedTagContainmentQueryStopsBeforeAnyRemotePush` 模拟真实 `.git` 查询失败，断言错误且远端 Tag 未创建、恢复后查询正常（`/tmp/bailey-p3-t3-tag-containment-integration-v2.log`，全类 passed）。
- `testCreationDefaultsAndEditedFieldsSurviveTypeChanges`（旧 L105） · `A` → `GitDialogUITests.testHistoricalTagSheetPreservesAnnotationAndCreatesAtChosenCommit`（类型切换前后的注释文本不丢、取消无 Ref、确认后旧 Commit 的 annotated Tag OID、注释和工作区），另由 `testHistoricalTagReplacementRejectsMovedRefAndRetainsAnnotation` 验证同名重试的预填字段（`/tmp/bailey-p3-t3-gitdialogs-native-full.log`、`/tmp/bailey-p3-t3-tag-stale-replace-gui.log`）。
- `testDeleteRemoteChoicesAreExplicitAndInitiallyLocalOnly`（旧 L128） · `A` → `GitDialogUITests.testTagDeleteNativeSheetDefaultsLocalOnlyAndPreservesBareRemote`：两远端中默认“不删除远端”，可以显式选择 `backup` 再改回本地；取消保留全部 Ref，确认只删除本地 Tag，两个真实 bare remote 不变（`/tmp/bailey-p3-t3-tag-delete-two-remotes-fixed.log`，1/1）。
- `testPushSelectionAndNoRemoteSafety`（旧 L141） · `A` → `GitDialogUITests.testTagPushUsesTagDefaultRemoteNotBranchPushRemote`（多远端偏好、全不选禁用、只推选定目标）+ `testTagPushWithoutRemoteCannotSubmitOrWriteRepository`（无 Remote 的真实 Sheet 禁止确认、取消后 Ref／HEAD／文件字节不变；`/tmp/bailey-p3-t3-tag-no-remote-fixed.log`，1/1）。

### P3-T4 — 48 条

**2026-10-23 P3-T4 在做：11/48 旧方法已逐项迁入纯 Unit，另 37 条仍保留旧 NativeUI 宿主；19 个新的独立 Bailey Dev Git Graph E2E 合集已实际通过，暂不可核销全部 48 条。**

续执行验证：`make test:CommitGraphLayoutTests,GitGraphPaletteTests,GitGraphReferenceGroupTests,GitGraphWorktreePresentationTests` 39/39、exit 0；`make test:ui ONLY_TESTING=BaileyUITests/GitGraphUITests` 19/19、0 skipped、exit 0，599.086 秒，xcresult `Test-Bailey-UI-2026.10.23_21-39-05-+0800.xcresult`，完整日志 `/tmp/bailey-migration-graph-exclusive-ui.log`。此前 21:30 的运行与另一轮同 Bundle ID GUI 重叠，3 passed / 2 failed / 1 cancelled，不能作产品回归依据；两项失败在独占复测中均通过。Makefile 四入口互斥的修复及验证见 P1 审计 F-06/F-07。新增几何用例的真实同名无引用工作树菜单打开、选定文件路径与正文已 1/1 通过（`/tmp/bailey-migration-graph-geometry-padded.log`），整行边角及真实分隔条缩放仍在校验；后者不混入已通过的 19 项。

新增根因证据：`CFFIXED_USER_HOME` 的 Foundation 合约探针与真实 Dev App 都确认 `.config/bailey-dev/config.toml` 位于每例临时主目录，原 Dev 配置 SHA-256 始终为 `2d560d12a91d3863e0b5c564c59da50ee65226bc2401db13a524c918019e083d`。此能力不等于 UserDefaults/钥匙串全部隔离；CFPreferences 探针未在临时主目录生成 plist，因此语言持久化仍不得假定安全。公共启动器与剪贴板修复已提交 `0ae7397`。真实分隔条必须使用 `click(forDuration:thenDragTo:)` 鼠标 API，触摸 `press` 不会调整。Red：18pt + 150pt 面板时标题移到窗口外（`/tmp/bailey-migration-graph-geometry-isolated-matrix.log`）；只移除 64pt 下限仍失败（`/tmp/bailey-migration-graph-max-font-native-paste.log`）。真实根因是标签条固定理想宽度及高布局优先级与标题下限共同超出行宽；采用原生弹性分配后，短标签又被拉宽，因此同时以实际 NSFont 字形宽度约束标签的最大宽度，保留其原有窄窗截断。最终受影响宿主模型及全部 37 旧原生用例 125/125 通过，几何新类首批 **13/13、0 失败、exit 0**（`/tmp/bailey-migration-graph-geometry-complete.log`，1040.6 秒）：浅/深×9/18pt、5宽×6边角、共享 HEAD 2/12 个 Worktree、特殊标签四色、两实际菱形对齐及无选择底色、33 remote、多级 hover 菜单在外部 Ref 刷新后驻留10秒并真正打开正确 checkout、无引用同名工作树打开文件。正式 Debug `make build` 与严格验签 exit0。2026-10-24 扩展后的独立完整 UI Suite 前半段又有 20/20 条 `GitGraphGeometryUITests` 真实通过（新增长主分支双色×9/18pt、Tree/List 双色、12 工作树等）；`/tmp/bailey-migration-complete-ui-suite.log`。该 Suite 最终 **57 passed / 45 failed**，其中 `GitDialogUITests.testHistoricalBranchReplacementRejectsMovedRefAndPreservesRetryName` 的第二次提交右键在按钮外坐标未命中菜单、`GitGraphUITests.testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus` 在全 App 范围选到非本工作树的同名 `Remove` 项；之后 `GitGraphUITests.testDarkDenseGraphAtMaximumPanelFontKeepsTitleAndRailsInsideThePanel` 丢失 App AX 连接，余下大部分方法遭 AX 拒绝，不得冒充执行过业务断言。现已将前者改为真实图谱节点右键，后者改为选中三级 Worktree 菜单的作用域查询，**仅 `make build:ui` 编译通过，仍欠实际 UI 复测**。重启专属 `testmanagerd`，并分别用 ad-hoc／Apple Development 签名进行单例初始化，均出现 `Timed out while enabling automation mode`，见 `/tmp/bailey-migration-ui-auth-recovered.log`、`/tmp/bailey-migration-ui-default-signing-fresh-service.log`；未改用户权限、未声称修复此 macOS/XCTest 初始化故障。

2026-10-24 补充验证：受影响图谱布局/旧宿主 `make test:CommitGraphLayoutTests,GitGraphPaletteTests,GitGraphReferenceGroupTests,GitGraphWorktreePresentationTests,RecentCommitsViewTests SIGNING=adhoc` **76/76 exit 0**（`/tmp/bailey-migration-graph-model-targeted.log`）；`make test:GitStatusModelTests SIGNING=adhoc` **49/49 exit 0**（`/tmp/bailey-migration-graph-status-model.log`）。本轮修订后的 `make build:ui SIGNING=adhoc` 和 `make build:release SIGNING=adhoc` 均成功并严格验签（`/tmp/bailey-migration-p3-final-ui-compile.log`、`/tmp/bailey-migration-release-final.log`）。XCTest xcresult 导出诊断显示 `testmanagerd` 已回复 Runner 授权，但 `enabling automation mode` 60 秒未返回；原始记录 `/tmp/bailey-ui-test-automation-diagnostics`。额外完整宿主 `make test SIGNING=adhoc` 在 `_prepareTestConfigurationAndIDESession` 阶段超过三分钟没有启动任何用例，采样记录 `/tmp/bailey-migration-full-host-sample.txt`，已精确停止该测试及孤立 Dev 宿主、释放锁，**不计为完整宿主通过**。运行中的正式 Bailey 未被停止，Dev 配置 SHA-256 未变化；需要新的正常 XCTest 图形会话再做修正后的完整 UI E2E 与全量宿主验收。

- 纯 Unit：`GitGraphPaletteTests`、`GitGraphReferenceGroupTests`、`GitGraphWorktreePresentationTests` 和现有 `CommitGraphLayoutTests`；色值、引用分组、路径、状态字母、节点提示、车道边距原断言迁移。删旧类后运行 `make test:CommitGraphLayoutTests,GitStatusModelTests,GitGraphPaletteTests,GitGraphReferenceGroupTests,GitGraphWorktreePresentationTests`，**88/88、0 失败、exit 0**（`/tmp/bailey-p3t4-unit-after-old-delete.log`），其中 `GitStatusModelTests` 49/49、`CommitGraphLayoutTests` 29/29，另三类共 10/10。
- 真实 GUI：原 `GitGraphUITests` 19/19 exit 0；2026-10-24 扩展后的 `GitGraphGeometryUITests` 20/20 通过（`/tmp/bailey-p3t4-graph-two-classes-complete.log`），含复杂菜单、阴影、字体、颜色和窄宽实拖。与 `GitGraphUITests` 合计 45 项首次 42 通过/3 失败：24 并行 Lane 的 150pt 面板标题溢出。沿 `GitPanel.changeList → RecentCommitsView.commitRow → TreeRowSurface` 定位到 VStack 的固有宽度未受可视视口约束，改为 GeometryReader 读取真实行宽并约束内部内容；原三项分别在 `/tmp/bailey-p3t4-dense-single-geometry.log` 和 `/tmp/bailey-p3t4-targeted-regression-final.log` 真实 App 转绿。最终受影响十项定点 **10/10、0 跳过、exit 0**（含两个原失败案例、明暗、9/18pt、键盘、长标题、十二 Worktree、特殊图标与原始 Git 字节）；另 `/tmp/bailey-p3t4-33ref-150pt.log` 验证真实最窄面板下 33 个 Remote 全部原生菜单可达，**1/1、exit 0**。原 45 项没有在最终宽度修复后机械全量重复运行，未受影响项目采用修复前绿色 E2E 证据。
- 发现并排除的测试误判：XCUITest `MenuButton.title` 不等于 `label`；同名 Dev 项目在菜单栏存在隐藏零尺寸项，必须选择真正可见的 Worktree 子菜单；标题截图必须比较原始像素并控制 hover；文件名和总路径遵循 APFS 长度限制。以上未修改 Bailey 产品行为。
- **方法级核销**：原 48 条按下列清单逐项保留断言归属，先前 11 条迁入纯 Unit；本次删掉原文件中剩余的 37 条 `NSWindow/NSHostingView` 宿主 GUI 测试及其私有辅助代码。已通过的真实 App 覆盖长 Branch、双色×9/18pt、Tree/List、24 Lane 密集图、历史 Diff 选中、原生菜单及复杂 Worktree/Remote 状态。原宿主直接注入不可达的 120pt、1.6/2 倍字号；实际产品分隔条最低 150pt、字号 9–18pt，算法极端 160 组由纯单元测试维护；未冒称旧内部 callback 发生先后能跨进程直接观察。剩余 macOS 15.6 实机、物理触控板及额外显示设备须在各自具备条件时补验，不影响已验证本机目标。

**原 `BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift`：48 条（现已删除）** — 图谱拓扑、标签、键盘与绘制，原来属于 UI+逻辑混合。11 条转纯 Unit，37 条由独立 Bailey Dev 图形回归替代。

- `testDisplayedHistoricalDiffHasGreySelectionIndependentOfGraphFocus`（旧 L120） · `C` → `GitGraphUITests.testHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor` 与 `testDarkHistoricalDiffRowRetainsSelectionFillAfterMovingFocusToEditor`：真实历史 Diff 选中背景像素、移交焦点后的选中持续，浅色差 0.323；明暗两项均通过。
- `testExpandedHistoryAndUncommittedNodesHaveNoPersistentSelectionFill`（旧 L169） · `C` → `GitGraphGeometryUITests.testDirtyWorktreeDiamondsAlignWithTheirOwnHeadsWithoutSelectingTheirHeaders` 及 Tree/List×明暗四组：对真实 Commit/Worktree 展开前后 9 个空白像素采样，确认不产生持久选中底色，20/20 几何 GUI 合集已验。
- `testGraphReferenceBadgeTakesKeyboardFocusFromAnotherTree`（旧 L236） · `C` → `GitGraphUITests.testGraphTreeKeyboardMovesFromChangesFocusToBothHistoricalFiles`：从 Changes 文件行点击主 Branch 标签并以方向／Space／Return 操作真实 Git Graph（1/1）。
- `testGraphClickRecordsFocusIntentBeforeMovingNativeResponder`（旧 L260） · `C` → 真实 Changes → Branch Badge → Git Graph Space/Return 文件导航已验证最终焦点；内部 callback 时序尚未从真实 App 直接证明。
- `testGraphSpaceUsesTheSelectedCommitAndFileWithoutStealingKeyboard`（旧 L292） · `C` → 同一 `GitGraphUITests.testGraphTreeKeyboardMovesFromChangesFocusToBothHistoricalFiles`，真实 Tab、Git 与磁盘最终结果（1/1）。
- `testGraphTreeKeyboardTraversesFoldersAndBothHistoricalFiles`（旧 L347） · `C` → 同一真实嵌套目录、两历史文件、Left 折叠验证（1/1）。
- `testGraphPaletteKeepsTwelveLaneColors`（旧 L399） · `B` → `GitGraphPaletteTests`，12 色 RGB 逐项数值对照，2/2（同类包括图标对比度）。
- `testColoredBadgeIconsRemainReadableOverEveryGraphLaneColor`（旧 L414） · `B` → `GitGraphPaletteTests`，全部车道前景与底色 WCAG 对比度下限 4.5，2/2。
- `testTagStashDetachedAndStandaloneWorktreeIconsMatchGraphColors`（旧 L434） · `C` → `GitGraphGeometryUITests.testLightGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes` 与 `testDarkGraphPaintsTagStashDetachedAndUnreferencedWorktreeIconsLikeTheirNodes`：真实 Tag、Stash、Detached HEAD、独立无引用 Worktree 对照各自 DAG 节点像素色相，并点击双方展开/折叠；明暗双测已通过。
- `testHeadAndStashGraphGutterRemainsClickableInBothAppearances`（旧 L503） · `C` → `GitGraphGeometryUITests` 明暗特殊标签/节点测试验证 Head 与 Stash 各自节点及徽标切换，`GitGraphUITests.testDetachedHeadAndRealStashKeepSeparateNativeGraphActions` 验证真实专用菜单；明暗节点真实操作已通过。
- `testCompositeReferencesUseLongestConfiguredRemoteAndPreserveEveryTarget`（旧 L534） · `B` → `GitGraphReferenceGroupTests`，最长远端名匹配、完整 Ref 保留，3/3。
- `testCompositeReferencesNeverJoinDifferentCommitRowsOrUnknownRemotes`（旧 L569） · `B` → `GitGraphReferenceGroupTests`，跨行不误合并、未知远端不合并、Unicode 名称，3/3。
- `testCompositeOverflowKeepsRealReferencesAvailableWithoutWholeRowScrolling`（旧 L586） · `C` → `GitGraphUITests.testOverflowReferencesExposeTagAndBranchWithoutLosingGitRefs`（Ref 不丢）＋`GitGraphGeometryUITests.testAllThirtyThreeRemoteReferencesRemainInTheNativeOverflowMenu`（33 个真实 Remote 菜单、最后一项复制准确）＋24-lane 整图不横滚，GUI 已验证。
- `testCurrentAndFeatureUncommittedDiamondsAlignAndToggleInNativeGraph`（旧 L609） · `C` → `GitGraphGeometryUITests.testDirtyWorktreeDiamondsAlignWithTheirOwnHeadsWithoutSelectingTheirHeaders` 及明暗×Tree/List：两个不同 HEAD 的真实脏 Worktree 菱形 X 坐标与所属提交节点一致，点击展开/折叠、状态文件与 Git index 不变，GUI 已验证。
- `testShortCommitHashCopiesWithoutExpandingDetails`（旧 L672） · `C` → `testShortHashCopiesActualOIDWithoutExpandingGitCommit`，剪贴板完整 OID、展开状态不变，1/1。
- `testCompactPrimaryBranchTogglesCommitAndKeepsContextMenu`（旧 L689） · `C` → `GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit` ＋ `GitGraphGeometryUITests` 5 宽（420/260/150/320/150）×明暗/9–18pt 原生菜单、整行展开测试；最低 150pt 为产品实际分隔条限制，GUI 已验。
- `testShortPrimaryBranchBadgeKeepsIntrinsicWidth`（旧 L729） · `C` → `GitGraphGeometryUITests` 真正拖动 Dock 分隔条，在 150–420pt、明暗、9/18pt 下对比 NSFont 字形宽度与 Branch AX 实际宽度上限，确认短徽标不会随着面板拉宽而伸长，GUI 已验。
- `testPrimaryBranchContextMenuRemainsAvailableThroughWidthChanges`（旧 L772） · `C` → `GitGraphGeometryUITests` 真实分隔条拖动、窄→宽→窄反复恢复后右键有 Rename/Copy；明暗×9/18pt、长分支及 12 Worktree 组合已通过（120pt 是旧宿主合成的不可达宽度，产品最低 150pt）。
- `testGraphNodeHelpOnlyStatesConfirmedHEADMembershipAndActualReferences`（旧 L810） · `B` → `GitGraphReferenceGroupTests`，真实 OID、引用、stash 与 HEAD 可证实历史提示的两种分支，定点 4/4。
- `testNodeHoverTargetRetainsSingleClickAndCommitContextMenu`（旧 L845） · `C` → `GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit` 与 `testChineseGraphNodeAndReferenceMenusRetainTheirExactCopyTargets`：真实节点 hover/rightClick 可打开提交专属原生菜单，左右单击各自切换而不误触菜单；中文 E2E 当前 batch 已通过，英文此前 19/19 合集通过。
- `testLongCommitMessageCanScrollHorizontallyInNarrowSidebar`（旧 L877） · `C` → `testLongChineseGraphTitleScrollsButShortTitleAndGraphRailsStayFixed`；长中文标题滚动但节点 X 不变。
- `testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts`（旧 L890） · `B` → `CommitGraphLayoutTests.testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts`，5 宽×4 字号×8 车道=160 组全部原样迁移，29/29、exit 0。
- `testDenseRealNativeGraphRetainsVisibleTitleScrollerInBothThemes`（旧 L917） · `C` → `GitGraphUITests` 24 真实并行 Lane＋明暗×9/18pt 窄宽组合全部实测，初次发现 150pt 下标题越界，现用真实行宽约束修复；原失败 3 项重新定点验证通过（深色18pt独立及浅色18pt/普通字号在10项合集），明暗9pt也在10项合集通过。
- `testManyParallelBranchesDoNotScrollWholeGraphSideways`（旧 L954） · `C` → `GitGraphUITests.testDenseRealGraphKeepsHistoryAndNodeVisibleAcrossMoreThanTwelveLanes` 构造 24 条真实独立提交，横向滚动后 Gutter 节点 X 不移位、25 个 Ref 未丢（1/1）；视觉布局极端范围另归 Unit 的宽度／车道验证。
- `testShortCommitMessagesDoNotBounceHorizontally`（旧 L977） · `C` → `testLongChineseGraphTitleScrollsButShortTitleAndGraphRailsStayFixed`；短标题稳定原始像素。
- `testExpandedHistoryKeepsLongFolderPathsScrollable`（旧 L999） · `C` → `testDeepChineseHistoricalFolderScrollsInsideRowWithoutMovingGraph`；六级合法长中文目录滚动且图谱不动。
- `testRecentCommitHistoryOnlyPagesAtBottom`（旧 L1017） · `C` → `GitGraphUITests.testRealGraphHistoryLoadsNextPageOnlyAfterScrollingToBottom`：35 条真实提交首次 30 条、滚到底后显示第 35 条（1/1）；分页纯命令不重读无关数据由既有 `GitStatusModelTests.testIndexMutationAndPaginationAvoidUnrelatedGitQueries` 覆盖。
- `testEntireCommitRowTogglesIncludingGraphMetadataAndBlankSpace`（旧 L1070） · `C` → `GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit` 核对标签／标题／节点／元信息；`GitGraphGeometryUITests` 实际 38pt 整行 6 个边角/留白坐标×5宽、明暗×9/18pt，每次点击准确展开/折叠、Git 未改，GUI 已验。
- `testMergedHistoryOpensItsRealFileAfterExpansion`（旧 L1102） · `C` → `testRealMergeShowsBothParentHistoriesAndTheirOwnFileDiffs`；真实双父 Merge 及两父各自历史文件可打开。
- `testCommitTitleExpandsFilesInWideAndNarrowPanels`（旧 L1160） · `C` → `GitGraphGeometryUITests` 窄宽及 9/18pt 真实窗口验证提交标题可见、整行点击/文件展开及宽度变化后仍可用；GUI 已验。
- `testNativeContextMenuAtDirectReferencesContainsOnlyTheSelectedObjectActions`（旧 L1216） · `C` → `GitGraphUITests.testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit`（Branch）、`testHistoricalTagBadgeTogglesItsCommitAndKeepsOnlyTagActions`（Tag）、`testSymbolicRemoteAliasCannotOfferDestructiveBranchActions`（Remote/符号 alias）；33 Remote 及其目标复制由 Geometry 真实验证，明暗 9/18pt×150–420pt 主分支右键亦全部通过；中文菜单定点当前 batch 通过。
- `testDetachedHeadBadgeExpandsCommitAndKeepsCopyHashInMenu`（旧 L1262） · `C` → `GitGraphGeometryUITests` 明暗双色特殊节点测试真实点击 Detached HEAD 展开/折叠、原生菜单复制完整 OID，`testDetachedHeadAndRealStashKeepSeparateNativeGraphActions` 验证不显示危险提交动作；新增复制断言定点 2/2 通过。
- `testSymbolicRemoteAliasOnlyCopiesFromMenuAndTogglesCommit`（旧 L1292） · `C` → `testSymbolicRemoteAliasCannotOfferDestructiveBranchActions`，真实符号引用复制且没有危险项，普通远端分支仍可操作。
- `testDirtyWorktreeDoesNotRepeatLongBranchBadgeInNarrowSidebar`（旧 L1324） · `C` → `GitGraphUITests.testDirtyLinkedWorktreeUsesItsOwnGraphNodeAndSafeNativeMenu` 实际构造超长 Unicode Branch、脏关联 Worktree，拉至真实 150pt，验证节点可见/右键专属操作且不重复 Branch 动作，最终文件字节和 HEAD 不变；修复后的10项合集验证通过。
- `testWorktreeDisplayPathsStayUniqueWithSameCheckoutDirectoryNames`（旧 L1370） · `B` → `GitGraphWorktreePresentationTests`，同名目录最短唯一后缀与 Unicode 名称，3/3。
- `testWorktreeConflictStatusAlwaysUsesUInTreeAndList`（旧 L1389） · `B` → `GitGraphWorktreePresentationTests`，冲突恒为 U，正常暂存／未暂存各保留原状态字母，3/3。
- `testDenseWorktreeGraphKeepsCommitTitlesReadableAcrossThemes`（旧 L1406） · `C` → `GitGraphGeometryUITests.testMaximumPanelFontWithTwelveSharedWorktreesRetainsMenusAndFullRowHitArea`（12 个真实 Worktree，最窄 150pt、18pt 标题可见）、明暗字号矩阵及 `GitGraphUITests.testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus`（同 SHA 的精确三级菜单）；相关 Geometry GUI 20/20 已通过。
- `testGraphBadgeRowsStayCompactAcrossAppearanceAndFontSizes`（旧 L1529） · `C` → `GitGraphGeometryUITests` 明暗×9/18pt、150–420pt、长 Branch＋12 Worktree；保持紧凑徽标宽度和标题可命中，无整图横滚，GUI 已验。
- `testGraphBadgesUseCompactSharedMetrics`（旧 L1591） · `B` → `GitGraphPaletteTests` 静态尺寸 16/16/9/4；`GitGraphGeometryUITests` 明暗×9/18pt×150–420pt 测量原生实际徽标与标题，20/20 GUI 已通过。
- `testLocalBranchTakesPriorityOverRemoteDefaultAliasWithoutLosingReferences`（旧 L1598） · `B` → `GitGraphReferenceGroupTests`，本地／远端别名排序、HEAD 及被检出 Worktree 优先且不丢 Ref，3/3。
- `testUnassociatedWorktreeLabelChineseTranslationPreservesDirectoryName`（旧 L1624） · `B` → `GitGraphWorktreePresentationTests`，真实 zh-Hans 资源串保留 Worktree 路径，3/3。
- `testRealWorktreeHistoryRendersNamedLabelsAndPreservesSharedHeadActions`（旧 L1631） · `C` → `testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus`；同名两路径正确区分、三级菜单可达、未产生 Git 写入。
- `testWorktreePrimaryLabelsReplaceAliasAndIconOnlyCombinations`（旧 L1701） · `C` → `GitGraphWorktreePresentationTests` 路径/唯一显示纯计算 + `GitGraphGeometryUITests` 明暗构造真实 `origin/HEAD` 符号引用、Detached 主 Worktree、无 Ref Worktree 和 Tag/Stash，多项主标签分别命中真实 HEAD；`GitGraphUITests.testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus` 验证同 SHA 关联标签无重复，UI 已通过。
- `testDetachedAndUnreferencedWorktreesRetainNativeActionsWithoutDuplicatePills`（旧 L1772） · `C` → `GitGraphGeometryUITests.testUnreferencedSharedWorktreeMenuOpensTheSelectedCheckoutAndActualFile`：无 Ref 共享 HEAD 的两条同名 Worktree 可精准打开各自文件；`GitGraphUITests.testMainWorktreeThirdLevelMenuDisablesRemovalInNativeApp` 证明主 Worktree 不可删除，真实 GUI 已验。
- `testCleanWorktreeBadgesAreSeparateFromUncommittedChangesInBothThemes`（旧 L1848） · `C` → `GitGraphUITests.testCleanSharedHEADWorktreesKeepDistinctThreeLevelNativeMenus`（两个干净标签）＋`GitGraphGeometryUITests` 明暗×Tree/List 实际脏节点、无持久底色与各自 HEAD 对齐；GUI 已验。
- `testUncommittedWorktreeNodeHasSafeMenuAndNativeStageAwareFileActions`（旧 L1950） · `C` → `testOtherWorktreeStagedAndWorkingFilesPreserveDistinctDiffBaselines`：真实 MM 文件分别展现 HEAD→Index、Index→Worktree，工作区与 Index 不变。
- `testStashIsANodeInTheSameGraphWithOnlyStashActions`（旧 L2051） · `C` → `GitGraphUITests.testDetachedHeadAndRealStashKeepSeparateNativeGraphActions` 真实 stash@{0}、专属菜单、文件展开、Git 状态不变（1/1）。
- `testTagBadgeTogglesSameCommitAsOtherReferences`（旧 L2088） · `C` → `GitGraphUITests.testHistoricalTagBadgeTogglesItsCommitAndKeepsOnlyTagActions`，旧提交主 Tag 标签／标题共同切换、原生 Tag 专属菜单和实际引用（1/1）。

### P4-T1 — 11 条

**2026-10-24 迁移核销：** 原 11 方法中 P1 已提前迁出 1 项，P4-T1 剩余 10 项逐行映射如下。本次删除旧 `TreeRowHitTestingTests`（7）、`DockFocusP2RegressionTests`（2）完整宿主类，以及 `AppMenuIsolationTests` 的 Open File 1 项；仍在消费的宿主 ⌘Q 保护方法保留到 P4-T5。新用户路径见 `SharedTreeUITests`（8）及 `WorkspaceDockUITests`（3），另复用旧 `WorkspaceFilesUITests` 与 `GitChangesUITests` 的真实 E2E。问题根因为默认 900pt 窗口左侧约 108pt Projects Dock 组中固定 76pt 标题拖动留白挤得项目标签 0pt：真实 ⌘W 发出时活动组为空，误关闭整个项目。拖动留白改为优先保证 80pt 标签区域、窄时自身收缩；修复后无拖动和跨组拖动的两项真实 ⌘W 路由 E2E 2/2 通过。宿主受影响 `DockWorkspaceTests,FileTreeTests,AppMenuIsolationTests` 42/42、0 skip、exit 0（`/tmp/bailey-p4t1-post-delete-model-menu.log`）。新 11 条完整合并回归进行中；本机外的 macOS 15.6／实体触控板／其它显示器不冒称已验。

**[AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift)：原 2 条中的 Open File 1 条已迁移** — 真正用户可见的菜单入口已归独立 App E2E；⌘Q 隔离宿主断言保留到 P4-T5。

- `testFileMenuProvidesOpenFileKeyboardShortcut`（旧 L7） · `A` → `SharedTreeUITests.testRealOpenFileMenuHasSingleItemAndCommandOUsesNativePicker`：真实 Bailey Dev File 菜单恰有一个 Open File… 项；⌘O 打开系统选择器并将实际文件读入标签、磁盘原字节不变；单项 E2E 1/1 通过。旧宿主方法已删，保留其 ⌘Q 安全断言。

**原 `BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`：7 条（已删除）** — 共享 Files／Git 行命中、颜色与滚动；由 `SharedTreeUITests` 的真实 Dev App 操作替代。

- `testSelectionFillAndKeyboardOutlineRenderIndependently`（旧 L24） · `A` → `SharedTreeUITests.testLightFileSelectionFillRemainsAfterCommandPaletteTakesFocus` 与 `testDarkFileSelectionFillRemainsAfterCommandPaletteTakesFocus`：浅／深同态选中和未选中背景像素差异、键盘 AX `.isSelected` 在 Palette 接管时撤销、取消后 ↓ 和 Space 正确打开目标且原文件字节不变；2/2、exit 0（`/tmp/bailey-p4t1-ax-focus-trait.log`）。
- `testTreeFileAndFolderNamesOpenNativeContextMenuWithoutPrimaryAction`（旧 L74） · `A` → `SharedTreeUITests.testFileAndFolderContextMenusDoNotBrowseOrOpen`：真实 Files 目录／文件右键打开系统菜单，退出菜单前后没有折叠、预览或误写 index/HEAD，0 新标签；1/1、exit 0。
- `testShortNamesDoNotBounceInFilesFoldersAndGitChanges`（旧 L234） · `A` → `SharedTreeUITests.testSharedTreeLongLabelsScrollButShortLabelsRemainStableAcrossRealDockResize`（短 Files 文件）与 `testGitFolderShortNameDoesNotBounceAndInlineStageKeepsTheExactDirectory`（Git Changes 短目录、18pt、右侧独立 Stage、实际 index 局部变化）及原 `GitChangesUITests` 的短文件和目录行验证；真实滚轮输入下截图像素不回弹，1/1+1/1、exit 0。
- `testLongNamesScrollWithoutMovingGitActions`（旧 L255） · `A` → `SharedTreeUITests.testLongGitChangeScrollDoesNotMoveItsRealStageButton`：真实 18pt 超长 Git Changes 文件名横滚但行和 Stage X 坐标不移动，点击 Stage 仅改变选定文件的 index、未错误打开 Tab；1/1、exit 0；Files 长标题见下项。
- `testSharedLabelStopsBouncingAfterPanelWidens`（旧 L286） · `A` → `SharedTreeUITests.testSharedTreeLongLabelsScrollButShortLabelsRemainStableAcrossRealDockResize`：真实 Files 面板先窄后拖动原生分隔条至 560pt，长标题不再横滚，短标题始终无横滚且没有重复标签；1/1、exit 0。
- `testSharedFileRowSeparatesImmediateBrowseFromDoubleClickActivation`（旧 L322） · `A` → `SharedTreeUITests.testSharedTreeHitAreasOpenExactFileWithoutDuplicateTabs`：完整 App 三个水平行内位置单击浏览，同一路径双击确切打开原文且只保留一份文件标签；1/1、exit 0。
- `testFilesAndGitRowsOwnTheirFullHitArea`（旧 L349） · `A` → `SharedTreeUITests` 文件／目录行三种真实坐标、18pt Git 文件／目录及右侧 Stage 操作（分别通过）+ `GitChangesUITests.testFolderInlineStageAndUnstageAreScopedToThatDirectory` 的原生行尾操作，仅影响所选文件和目录的 Git index；不再用合成 NSWindow.sendEvent 冒充 E2E。

**原 `BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift`：3 条（其中 1 条此前 P1 已迁移，本任务删剩余 2 条后删除文件）** — Dock 点击、拖放、命令面板交接均归真实 App。

- `testClickingEmptyToolPaneReleasesHostingRootResponder`（旧 L22） · `C` → `WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor`：真实编辑器先获键盘，点击 Files 工具空白，再输入字符不修改旧编辑器内容及磁盘字节；单项 1/1 通过。
- `testDragReleasedOverAnotherDockGroupDoesNotActivateIt`（旧 L78） · `C` → `WorkspaceDockUITests.testCrossGroupDragReleaseCannotSelectDestinationButRealClickCan` 与 `testClosingExplicitlyActivatedProjectsKeepsFilesWithoutDragging`：真实拖动、⌘W 只关闭原 Projects，明确单击 Files 后 ⌘W 才关闭目标；发现并从根因修复 900pt 窗口下仅约 108pt 左栏的 76pt 拖动留白压垮项目标签 AX 命中，改为按实际宽度弹性留白，修复后 2/2、exit 0（`/tmp/bailey-p4t1-dock-responsive-header-fixed.log`）。
- `testPaletteFileManagerCommandTransfersKeyboardFocusToVisibleFileTree`（旧 L128） · `C` · **已核销**：根因为伪前台 NSWindow；以 `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor` 的真实 E2E 操作、磁盘原文与标签数验证（`9177817`），旧宿主方法同提交删除。

### P4-T2 — 19 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：19 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testAsyncFilesTargetBecomingCurrentRestoresVisibleFileCursor`（旧 L32） · `C` → `FileTreeTests.testFilesPanelWaitsForCurrentTargetBeforeSelectingCurrentFile`
- `testFilesCursorDoesNotActivateBehindPaletteBeforeSearchFieldFocus`（旧 L71） · `C` → `WorkspaceFilesUITests.testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`、`FileTreeTests.testFilesPanelWaitsForCurrentTargetBeforeSelectingCurrentFile`
- `testCancelingCommandPaletteRestoresFilesRowKeyboardNavigation`（旧 L116） · `C` → `WorkspaceFilesUITests.testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`
- `testCurrentToolTreeResponderFollowsDockGroupAfterPanelSwitch`（旧 L197） · `C` → `WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor`
- `testEditorPaletteSwitchToFilesRestoresNewToolKeyboardFocus`（旧 L251） · `C` → `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor（中英文）`
- `testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField`（旧 L315） · `C` → `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor`、`WorkspaceWindowsUITests.testKeyboardFocusAndPaletteRestorationStayWithTheOwningWindow`
- `testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation`（旧 L393） · `C` → `GitChangesUITests.testCommandPaletteCancellationRestoresGitChangesKeyboardNavigation`
- `testFilesActivationBeforeDirectoryListingFocusesFirstVisibleRowWhenLoaded`（旧 L452） · `C` → `FileTreeTests.testFilesPanelSelectsFirstVisibleRowAfterAsyncListingWithoutOpeningIt`
- `testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus`（旧 L489） · `C` → `WorkspaceFilesUITests.testFileTreeRenameAndDraftCancellationRestoreKeyboardNavigation`
- `testFilesTreeClickTransfersNativeKeyboardAndArrowsMoveTheVisibleCursor`（旧 L548） · `C` → `WorkspaceFilesUITests.testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`、`FileTreeTests.testFocusedRowNavigationTracksVisibleItemsAndResetsOnRootChange`
- `testDockIntegratedFilesRowsKeepNativeFocusWhenOpeningAnotherPane`（旧 L645） · `C` → `WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor`
- `testSwitchingToFileManagerSelectsVisibleCurrentFileAndTakesNativeKeyboard`（旧 L762） · `C` → `WorkspaceFilesUITests.testPaletteFileManagerCommandRestoresKeyboardFocusFromEditor`
- `testFilesOpenedInItsOwnDockGroupDoNotRetainHiddenKeyboardFocus`（旧 L814） · `C` → `DockWorkspaceTests.testBrowsingSameGroupMustNotKeepFocusOnHiddenFilesPanel`、`WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor`
- `testDockGroupClickDoesNotPreemptNativeFieldFocus`（旧 L874） · `C` → `DockFocusIntegrationTests.testNativeFieldEditorWinsUntilDockFocusIsRequestedForEmptySpace`
- `testNarrowTerminalFindFieldEditorBelongsOnlyToItsActualDockGroup`（旧 L911） · `C` → `DockFocusIntegrationTests.testTerminalFindFieldEditorBelongsOnlyToItsDockGroup`
- `testRestoredGroupIDsReplaceOnlyTheFocusScopesNotTheEditor`（旧 L956） · `C` → `DockWorkspaceTests.testMoveReorderSnapshotAndRestore`、`NativePaneRetentionIntegrationTests.testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`
- `testFocusAcrossAppearancesAndSizesKeepsTheNativeDocument`（旧 L994） · `C` → `NativeEditorLayoutTests.testSourceRestoresScrollSelectionAndResizesWithoutRecreatingDocument`、`WorkspaceWindowsUITests.testKeyboardFocusAndPaletteRestorationStayWithTheOwningWindow`
- `testResponderOwnershipRejectsInactiveProjectsHiddenTabsAndParking`（旧 L1040） · `C` → `DockFocusIntegrationTests.testOnlyActiveMountedEditorOwnsNativeResponder`、`NativePaneRetentionIntegrationTests.testParkingDropsObsoleteHostActionsBeforeDelayedDismantle`
- `testDockToolsTakeNativeFocusWithoutReplacingVisibleEditors`（旧 L1100） · `C` → `WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor`、`NativePaneRetentionIntegrationTests.testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`

P4-T2 核销：旧 19 项及其专用 `FilesPanelReadiness`／`FocusRecordingWindow` 已移除；原文件的 23 项 P4-T3/T4 测试保留。验证：`make test:WorkspaceWindowIsolationTests,DockFocusIntegrationTests,FileTreeTests` 53/53；`make test:DockFocusIntegrationTests,DockWorkspaceTests,PanelContextTests` 31/31；定点 `make test:ui` 7/7，macOS 27.2、英文与简体中文。额外 `PaneRetentionTests` 20/20、`NativeEditorLayoutTests` 28/28、`NativeFileTabTests` 16/16（后两组先前测试无失败）。宿主迁移中的焦点假失败复现时窗口 `isKeyWindow=false` 且 `NSApp.isActive=false`；修正旧测试以实际前台边界断言，完整前台键盘路径由独立 UI 回归确认。GUI 与真实输入法/触控板、最低 macOS 15.6 的环境差异不冒充已实测。

### P4-T3 — 17 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：17 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow`（旧 L1293） · `C` → `FinderDeliveryIntegrationTests.testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow`
- `testProjectsDropFilesOpenTabsAndFoldersAddProjects`（旧 L1334） · `C` → `FinderDeliveryIntegrationTests.testProjectsDropFilesOpenTabsAndFoldersAddProjects`
- `testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup`（旧 L1377） · `C` → `FinderDeliveryIntegrationTests.testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup`
- `testFinderDropIntoEmptyTabGroupKeepsGroupAndDoesNotMoveFilesAcrossProjects`（旧 L1431） · `C` → `FinderDeliveryIntegrationTests.testFinderDropIntoEmptyTabGroupKeepsGroupAndDoesNotMoveFilesAcrossProjects`
- `testQueuedFinderBatchRejectsChangedReceivingProjectBeforeRestoredOwnerAttaches`（旧 L1480） · `C` → `FinderDeliveryIntegrationTests.testQueuedFinderBatchRejectsChangedReceivingProjectBeforeRestoredOwnerAttaches`
- `testFinderProjectsDropDoesNotSwitchTargetDuringProviderLoading`（旧 L1532） · `C` → `FinderDeliveryIntegrationTests.testFinderProjectsDropDoesNotSwitchTargetDuringProviderLoading`
- `testFinderEmptyStateDropCannotOpenIntoFolderAddedWhileProviderLoads`（旧 L1568） · `C` → `FinderDeliveryIntegrationTests.testFinderEmptyStateDropCannotOpenIntoFolderAddedWhileProviderLoads`
- `testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow`（旧 L1597） · `C` → `FinderDeliveryIntegrationTests.testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow`
- `testExternalBatchRoutesToActualMountedFileBuffers`（旧 L1629） · `C` → `FinderDeliveryIntegrationTests.testExternalBatchRoutesToFileBuffersWithoutDuplication`
- `testExternalOpenFindsExistingFileInOtherWindowBeforeCreatingAnEditor`（旧 L1709） · `C` → `FinderDeliveryIntegrationTests.testExternalOpenFindsExistingFileBufferInOtherWindow`
- `testFinderReusesMacFileInsideRemoteProjectInAnotherWindow`（旧 L1774） · `C` → `FinderDeliveryIntegrationTests.testFinderReusesMacFileInsideRemoteProjectInAnotherWindow`
- `testExternalOpenDefersUntilAllCreatedWindowsHaveAttached`（旧 L1819） · `C` → `FinderDeliveryIntegrationTests.testExternalOpenDefersUntilAllCreatedWindowsHaveAttached`
- `testExternalOpenKeepsOneDirectoryProjectAcrossInterleavedWindowBatch`（旧 L1863） · `C` → `FinderDeliveryIntegrationTests.testExternalOpenKeepsOneDirectoryProjectAcrossInterleavedWindowBatch`
- `testExternalOpenCancelledWhenOwningWindowClosesBeforeRestoreCompletes`（旧 L1906） · `C` → `FinderDeliveryIntegrationTests.testExternalOpenCancelledWhenOwningWindowClosesBeforeRestoreCompletes`
- `testClosingAnUnattachedFileOwnerDrainsAllWaitingFinderEventsWithoutRetargeting`（旧 L1940） · `C` → `FinderDeliveryIntegrationTests.testClosingAnUnattachedFileOwnerDrainsAllWaitingFinderEventsWithoutRetargeting`
- `testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever`（旧 L1990） · `C` → `FinderDeliveryIntegrationTests.testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever`
- `testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`（旧 L2014） · `C` → `FinderDeliveryIntegrationTests.testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`

P4-T3 的 17 项从旧 `WorkspaceWindowIsolationTests` 移至独立的 `FinderDeliveryIntegrationTests`，移除其中两处挂载完整 `ContentView` 的宿主 UI 操作；既有窗口测试保留 6 项供 P4-T4。验证：宿主 47/47（Finder 17、窗口 6、身份 24）；独立 Dev `WorkspaceWindowsUITests` 的真实 Launch Services 单窗重复／3 文件批次、双窗原所有者复用均通过，P4-T2 双窗焦点回归修正 AX 窗口索引后单项通过。真实 Finder 拖入空编辑区、Projects 面板文件与文件夹三次成功，核对文件标签／新增项目、原始文件 SHA-256 不变、未误写入目标目录；通过 Peekaboo 4.6.0 仅对隔离 Dev 作真实鼠标事件。macOS 15.6、物理触控板、所有显示器及 Finder 其它落点组合未覆盖，仍需阶段门禁按实际缺口判定。

### P4-T4 — 15 条

**`WorkspaceContentIdentityTests.swift`**：3 条 — 标签和编辑器／Diff／Browser 身份。初判：UI，执行前核对每项真实断言。

- `testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing`（旧 L48） · `C` → `NativeContentIdentityIntegrationTests.testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing`
- `testFileDiffFileReturnsToSameEditorAndDiffDocument`（旧 L127） · `C` → `NativeContentIdentityIntegrationTests.testFileDiffFileReturnsToSameEditorAndDiffDocument`
- `testBrowserTabBetweenTwoFilesDoesNotStealTheirNativeEditors`（旧 L185） · `C` → `NativeContentIdentityIntegrationTests.testBrowserTabBetweenTwoFilesDoesNotStealTheirNativeEditors`

**`WorkspaceWindowCloseTests.swift`**：6 条 — 多窗关闭、保存否决与 Sheet 归属。初判：UI，执行前核对每项真实断言。

- `testEmptyWorkspaceAttachesToWindowWhenHostingViewWasRenderedOffscreen`（旧 L81） · `C` → `WindowCloseIntegrationTests.testNativeChromeAttachesAfterPreviouslyDetachedViewMount`
- `testTwoNativeWorkspacesAttachOwnWindowsAndKeepFolderPickerIsolated`（旧 L117） · `C` → `WindowCloseIntegrationTests.testNativeChromeAttachesToTwoDistinctWindowsAndPickers`
- `testBackgroundProjectDirtyCloseSheetStaysInItsOwningWindow`（旧 L178） · `C` → `WindowCloseIntegrationTests.testBackgroundProjectDirtyCloseSheetStaysInItsOwningWindow`
- `testRepeatedCloseAllKeepsCleanTabsUntilDirtyConfirmationResolves`（旧 L297） · `C` → `WindowCloseIntegrationTests.testRepeatedCloseAllKeepsCleanTabsUntilDirtyConfirmationResolves`
- `testProjectCloseCannotBypassAnActiveTabClose`（旧 L343） · `B` → `WindowCloseIntegrationTests.testProjectCloseCannotBypassAnActiveTabClose`
- `testNativeCloseDoesNotDiscardFailedSaveThenClosesAfterRetry`（旧 L367） · `C` → `WindowCloseIntegrationTests.testNativeChromeCloseVetoesFailedWriteAndRetriesAfterRemount`

**`WorkspaceWindowIsolationTests.swift`**：6 条 — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab`（旧 L1161） · `C` → `WindowOwnershipIntegrationTests.testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab`
- `testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers`（旧 L1208） · `C` → `WindowOwnershipIntegrationTests.testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers`
- `testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot`（旧 L2057） · `C` → `WindowOwnershipIntegrationTests.testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot`
- `testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows`（旧 L2124） · `B` → `WindowOwnershipIntegrationTests.testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows`
- `testLocalWorktreeUseProtectsMacFileInsideAnSSHProject`（旧 L2172） · `B` → `WindowOwnershipIntegrationTests.testLocalWorktreeUseProtectsMacFileInsideAnSSHProject`
- `testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection`（旧 L2205） · `B` → `WindowOwnershipIntegrationTests.testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection`

**额外两条 SessionStore 混入测试：**
- `testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction` → `WindowOwnershipIntegrationTests.testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows`（重复登记和恢复认领）、`NativeContentIdentityIntegrationTests.testFileDiffFileReturnsToSameEditorAndDiffDocument`（原生对象身份）、`WorkspaceWindowsUITests.testNativeWindowCloseAndRelaunchRestoreTheSameFileAndBytes`（真实窗口、磁盘和重启）。旧完整 View 宿主已删除。
- `testClosedWindowCannotBeUsedForLateFileOperationErrors` → `SessionStoreTests.testClosedOwnerCannotReRegisterOrReceiveNewWindowIdentity`（注销后不得重复登记）、`WindowOwnershipIntegrationTests.testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot`（另一窗口和快照仍有效）、真实窗口关闭 E2E。旧 NSWindow 宿主已删除。

**验证：** 新组件 15 项逐项通过；加 `SessionStoreTests`、`WorkspaceIdentityTests`、`DockWorkspaceTests`、`FileTabPersistenceTests`、`NativeDiffTabTests` 联合回归 133/133。`WorkspaceWindowsUITests` 的双窗 Sheet、空窗生命周期、跨窗焦点及脏文件关闭→磁盘保存→相同 UUID 重启恢复已单项通过。禁用的仅是隔离 UI Runner 的 AppKit 系统旧窗口恢复，Bailey `SessionStore` 仍接受真实重启验收。正常 ⌘Q、终端/WebKit 资源压力与释放属 P4-T5；最低系统、实体触控板等留阶段 Gate 核销。

### P4-T5 — 21 条

**旧源 `PaneRetentionTests.swift`：20 条 → [NativePaneRetentionIntegrationTests.swift](../../../BaileyTests/Integration/Workspace/NativePaneRetentionIntegrationTests.swift)** — Terminal／Browser／Editor 原生资源生命周期。初判：UI+逻辑，执行前核对每项真实断言。

- `testParkingDropsObsoleteHostActionsBeforeDelayedDismantle`（旧 L12） · `C` → `NativePaneRetentionIntegrationTests.testParkingDropsObsoleteHostActionsBeforeDelayedDismantle`
- `testTerminalFindFieldStaysInsideNarrowAndWidePanes`（旧 L47） · `C` → `NativePaneRetentionIntegrationTests.testTerminalFindFieldStaysInsideNarrowAndWidePanes`
- `testProjectAndPaneTabObservationsReplacePublisherRelays`（旧 L94） · `B` → `NativePaneRetentionIntegrationTests.testProjectAndPaneTabObservationsReplacePublisherRelays`
- `testNativeUnsavedConfirmationPreservesSheetAndButtonSemantics`（旧 L124） · `C` → `NativePaneRetentionIntegrationTests.testNativeUnsavedConfirmationPreservesSheetAndButtonSemantics`
- `testNativeFileAndSSHChoosersStayOnOwningWindow`（旧 L157） · `C` → `NativePaneRetentionIntegrationTests.testNativeFileAndSSHChoosersStayOnOwningWindow`
- `testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects`（旧 L232） · `C` → `NativePaneRetentionIntegrationTests.testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects`
- `testBrowserKVOUpdatesObservationHistoryFaviconAndRepeatedFocus`（旧 L304） · `C` → `NativePaneRetentionIntegrationTests.testBrowserKVOUpdatesObservationHistoryFaviconAndRepeatedFocus`
- `testWebKitJavaScriptDialogsInvokeNativeDelegateSheets`（旧 L373） · `C` → `NativePaneRetentionIntegrationTests.testWebKitJavaScriptDialogsInvokeNativeDelegateSheets`
- `testBrowserAndEditorStateSurviveViewRemount`（旧 L419） · `C` → `NativePaneRetentionIntegrationTests.testBrowserAndEditorStateSurviveViewRemount`
- `testClosingMountedFiveFileTabsReleasesTheirNativeDocuments`（旧 L515） · `C` → `NativePaneRetentionIntegrationTests.testClosingMountedFiveFileTabsReleasesTheirNativeDocuments`
- `testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears`（旧 L647） · `C` → `NativePaneRetentionIntegrationTests.testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears`
- `testHundredThousandLineWorkspaceEditsSavesAndReleasesFile`（旧 L690） · `C` → `NativePaneRetentionIntegrationTests.testHundredThousandLineWorkspaceEditsSavesAndReleasesFile`
- `testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks`（旧 L777） · `C` → `NativePaneRetentionIntegrationTests.testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks`
- `testExternalReloadReleasesObsoleteDocumentEvenWhenOldScrollViewIsCached`（旧 L859） · `C` → `NativePaneRetentionIntegrationTests.testExternalReloadReleasesObsoleteDocumentEvenWhenOldScrollViewIsCached`
- `testEditorRetainsScrollAndReleasesRetiredNativeResources`（旧 L942） · `C` → `NativePaneRetentionIntegrationTests.testEditorRetainsScrollAndReleasesRetiredNativeResources`
- `testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`（旧 L1028） · `C` → `NativePaneRetentionIntegrationTests.testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`
- `testTerminalAndFindObservationPreserveNativeSurfaceIdentity`（旧 L1124） · `B` → `NativePaneRetentionIntegrationTests.testTerminalAndFindObservationPreserveNativeSurfaceIdentity`
- `testUnmanagedForegroundSSHRejectsLocalFinderPathsBeforeAnyRemoteHandoff`（旧 L1177） · `B` → `NativePaneRetentionIntegrationTests.testUnmanagedForegroundSSHRejectsLocalFinderPathsBeforeAnyRemoteHandoff`
- `testUnmanagedExecSSHRejectsLocalFinderPathsEvenWhenForegroundPIDIsShellPID`（旧 L1181） · `B` → `NativePaneRetentionIntegrationTests.testUnmanagedExecSSHRejectsLocalFinderPathsEvenWhenForegroundPIDIsShellPID`
- `testTerminalKeepsSameShellAcrossParkingAndRemount`（旧 L1236） · `C` → `NativePaneRetentionIntegrationTests.testTerminalKeepsSameShellAcrossParkingAndRemount`

**已删除旧源 `AppMenuIsolationTests.swift`：1 条** — 前期 NativeUI 宿主仍需防止 ⌘Q 意外结束测试；直到最后一条原生宿主测试迁走才一起删除覆盖与产品中的测试专属拦截。

- `testTestHostHasNoQuitKeyboardEquivalent`（旧 L23） · `A` → 已删除测试专属 `CommandGroup(replacing: .appTermination)`；由 `WorkspaceRetentionUITests.testNormalQuitVetoesFailedSaveThenWritesAndRestoresSession` 的真实 ⌘Q、写入失败否决、重试与重启取代。


**迁移核销（已执行）：**
- 原 20 条的旧对象身份、5×5 编辑器、十万行、两轮窗口销毁、旧 `NSScrollView` 强引用、Undo/滚动、WebKit 与 Shell PID 均保留为最小原生组件 Integration，旧完整 `WorkspaceDockView` 宿主 3 处已删除。迁移前 20/20、迁移后 20/20；受影响的原生资源、设置、窗口关闭和身份联合回归 35/35。
- `WorkspaceRetentionUITests` 新增完整 Bailey Dev：真实 Settings 主题的隔离 TOML 写入和重启选中、Shell PID 跨文件标签和 Find、WebKit 未提交表单跨标签保留、正常 ⌘Q 保存失败否决与重试及重启、五轮每轮 5 个 10k 行文件的真实打开/关闭与字节核对。五项分别已定点通过（Debug）；不得把观察到的标签数或进程 RSS 回落等同于进程内对象 ARC 释放。
- 独立 Release Bailey Dev 完整 GUI 压力 5/5 轮、25 次文件开关两次通过（每文件 10,000 行、每轮关闭后标签 0、磁盘逐文件原字节）。首次不附着 Instruments 的 RSS 56 点：峰值 259.2 MiB、末值 253.1 MiB。复测附着 **Release Allocations** 105.8 秒，录制约 1.3 GiB Trace，XML TOC 验证含 Statistics/Allocations List/Regions Map；同进程 RSS 124 点峰值 296.0 MiB、末值 252.0 MiB（含 Instruments 观测开销，不与未附着数值直接比较）。关闭全部五文件后 3 次 `heap -q -H`：50.3、50.9、50.1 MiB，各有 1 个 `RestorableScrollView` 与 `SyntaxHighlightCoordinator` 可达对象，没有逐轮累加；实测有缓存不宣称零残留或泄漏不存在。原生弱引用释放仍由 20 项 Integration 断言核对。Release Dev 与 Debug 构建和验签均通过。
- 补充 Finder 原生拖放：`fe8acb3` 在真实 Finder → Ghostty 核对转义路径粘贴、无自动执行、无新 FileTab、原文件字节不变；Finder → WKWebView 的真实 `input[type=file]` 收到准确文件名，亦无新 FileTab／字节改动。首次强制切换 Finder 视图的整组回归失败，改为仅缺失列表视图时切换后，完整 `WorkspaceRetentionUITests` **7/7、0 失败、0 跳过**（`/tmp/bailey-p4-audit-all-retention-fixed.log`）。
- 未在本轮实测：macOS 15.6 真机、实体触控板／其它显示设备、终端和 WebKit 跨窗混合长时间压力、授权 Windows SSH 实机的完整拖放。已用本机真实 GUI、原生对象释放 Integration、身份/路由/SSH 模型回归替代部分契约；这些环境差异不能宣称已通过，保留最终 P5 Gate 核对。

## 非 UI Target 的混入检查

原有 Unit 8 文件／75 方法、Integration 20 文件／231 方法；目录名不能证明没有图形依赖。P1-T3 对 306 个方法及其 transitive fixtures 复核：以「实际创建窗口、绘制、聚焦、事件输入、UI 表现」而非单独 `import AppKit` 判断。

**额外重点：[`SessionStoreTests.swift`](../../../BaileyTests/Integration/Workspace/SessionStoreTests.swift)**：原有 10 方法，其中下列两项具有明确原生窗口/视图依赖，归 `P4-T4` 完整替代；其余方法亦须逐项检查：

- `testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction`（`NSHostingView`／`NSWindow`／`NSTextView` 身份）：P4-T4 已由原生组件身份和真实 App 重启验证取代；重复登记与快照由非 UI 测试保留。
- `testClosedWindowCannotBeUsedForLateFileOperationErrors`（真实 `NSWindow` 装配）：P4-T4 已由已关闭所有者去注册的非 UI 测试和真实窗口关闭 E2E 取代。

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

