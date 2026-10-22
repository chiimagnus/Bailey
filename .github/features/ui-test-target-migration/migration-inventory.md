# 迁移清单：方法级零遗漏基线

> 2026-10-22，规划分支 `019765f`，仅为源码静态快照。这里登记**迁移责任**，不是已通过结果；完成／阻塞状态唯一归 `todo.toml`。迁移时每个 task 必须逐方法写下实际替代测试（或移入 Unit/Integration 的方法）、命令、输出与原因。方法可能合并成同一 E2E 路径，但不能丢失原断言。改动前后都要重新生成清单做集合差分。

基线：`BaileyTests/NativeUI` 19 文件／275 个 test 方法；`WorkspaceUI` 4 文件／54 个；合计 **329 方法**。清单编排顺序来自源码而非目标测试数量。`UI+逻辑` 表示需逐条鉴别，不能认为全部适合纯 XCUITest。

## 旧 NativeUI / WorkspaceUI：329 个逐方法锚点

### P2-T1 — 38 条

**[EditorNavigationTests.swift](../../../BaileyTests/NativeUI/Editor/EditorNavigationTests.swift)：28 条** — 编辑器键盘、滚动、导航与几何。初判：UI+逻辑，执行前核对每项真实断言。

- `testNativeViewportOnlyMaterializesVisibleParagraphsAfterDistantVisits`（旧 L67）
- `testCurrentSourceFileKeepsCorrectViewportAndHitTesting`（旧 L84）
- `testGutterParagraphNumbersMatchNativeSeparatorsAndCRLF`（旧 L103）
- `testNativeGutterKeepsEditorThemeBackgroundInBothAppearances`（旧 L120）
- `testNativeGutterSelectedLineAndLargeDocumentWidth`（旧 L150）
- `testSelectedTextRangeKeepsAllTouchedGutterNumbersHighlighted`（旧 L178）
- `testEmptyNativeEditorStillPaintsFirstGutterNumber`（旧 L233）
- `testFinalBlankLineRetainsVisibleGutterNumber`（旧 L257）
- `testSelectedFinalBlankLineHighlightsItsOwnTextRow`（旧 L288）
- `testEmptyEditorPaintsSelectedLineAtTheCaret`（旧 L319）
- `testGutterWidthUsesTheSameUserFontAsSourceText`（旧 L340）
- `testGutterTransitionsAcrossDigitBoundariesWithoutShiftingTextUnderIt`（旧 L354）
- `testWrappingAndUnwrappedLongUnicodeLinesKeepRealCharacterHitTargets`（旧 L391）
- `testWrappedUnicodeTailReallyScrollsIntoShortViewport`（旧 L443）
- `testMountedSourceEditorActuallyPaintsVisibleTextInBothAppearances`（旧 L467）
- `testAvailableEditorFontsKeepUsableGeometry`（旧 L527）
- `testVariableHeightUndoDeleteAllAndRestore`（旧 L543）
- `testSourceRestoresScrollSelectionAndResizesWithoutRecreatingDocument`（旧 L562）
- `testGeometryConfigurationBoundaries`（旧 L602）
- `testScrollingPreservesVisibleTextAndSelection`（旧 L614）
- `testVariableLengthUnwrappedCodeKeepsLongLineVisible`（旧 L625）
- `testSourceGeometryAndEditCosts`（旧 L639）
- `testUnwrappedDocumentGeometryAcrossNewViewports`（旧 L662）
- `testLongDocumentRevealsForwardAndReverseTargets`（旧 L677）
- `testFourSizesWrappingAndThreeInputPositionsKeepDataAndLatency`（旧 L693）
- `testDeletingLongestUnwrappedLineRestoresHorizontalExtent`（旧 L737）
- `testColdAndWarmScrollbarGeometryAcrossFourFileSizes`（旧 L761）
- `testShortAndFixedRowDocumentsKeepEndAndBeginningVisible`（旧 L797）

**[EditorTextInputTests.swift](../../../BaileyTests/NativeUI/Editor/EditorTextInputTests.swift)：10 条** — 原生文本输入／IME／Undo。初判：UI+逻辑，执行前核对每项真实断言。

- `testUnmarkAcceptsCompositionLikeSystemTextViewAndClearsMarking`（旧 L23）
- `testCompositionWithImplicitReplacementReplacesSelectedTextAndRestoresUndo`（旧 L47）
- `testAttachedInputGeometryRemainsUsable`（旧 L76）
- `testInputGeometryAfterEditorDetachesDoesNotUseDisposedWindow`（旧 L98）
- `testUnicodeCompositionSelectionMatrixMatchesSystem`（旧 L112）
- `testDirectUnmarkUndoMatchesNativeTextView`（旧 L160）
- `testCompositionReplacingExistingTextRestoresOriginalOnUndo`（旧 L199）
- `testFinalCompositionDefaultAndExplicitRangesMatchSystemAndKeepUndo`（旧 L232）
- `testNativeMultipleSelectionsShareDocumentAndUndo`（旧 L253）
- `testOrdinaryInputAndSelectedReplacementKeepUndo`（旧 L275）

### P2-T2 — 49 条

**[FileTabTests.swift](../../../BaileyTests/NativeUI/Editor/FileTabTests.swift)：49 条** — 文件读写、失效／重连、保存／关闭。初判：UI+逻辑，执行前核对每项真实断言。

- `testMountedNativeMultipleSelectionsPreserveBytesDirtyStateAndUndo`（旧 L94）
- `testNativeFindBarRoutesThroughMountedFileEditor`（旧 L138）
- `testNativeFindBarKeepsSelectedGutterAndTextRowsPixelAligned`（旧 L167）
- `testDetachedEditorAppendKeepsSameNativeDocumentAndUndo`（旧 L366）
- `testNativeReorderAndInFlightSaveKeepExactDirtyBytes`（旧 L408）
- `testCanonicalEquivalentNativeReplacementUndoAndSavePreserveBytes`（旧 L451）
- `testCanonicalEquivalentCleanReloadInstallsNewBytes`（旧 L492）
- `testCanonicalEquivalentEditDuringWriteRemainsDirty`（旧 L513）
- `testUnconsumedTabDoesNotReadAndWaitLoadsExactlyOnce`（旧 L532）
- `testInitialReadFollowsRenameAndOldReadCannotWin`（旧 L551）
- `testLocalTextReadCapacityAndFailureKinds`（旧 L569）
- `testHundredThousandLineSwiftFileCanLoadAbovePreviousCapacity`（旧 L619）
- `testLocalSymbolicLinkUsesTargetContents`（旧 L674）
- `testInvalidUTF8AndImageFallbackRespectTextCapacity`（旧 L690）
- `testNativeReadOnlyRejectsAXValueAndSelectionReplacement`（旧 L737）
- `testWritableNativeAXValueReplacementUpdatesDirtyStateAndDisk`（旧 L750）
- `testMountedEditorDisconnectReconnectKeepsNativeBufferAndUndo`（旧 L779）
- `testFixedHostDisconnectRebindsDirtyFileWithoutLosingDraft`（旧 L823）
- `testUnconsumedRemoteTabRemainsLazyAcrossReconnect`（旧 L848）
- `testVisibleRemoteTabRecoversWhenConnectionReturns`（旧 L864）
- `testWindowFocusRefreshesOnlyItsMountedFile`（旧 L878）
- `testImagePreviewReloadIsScopedToItsWindow`（旧 L915）
- `testRepeatedWindowFocusCoalescesInFlightCleanRefresh`（旧 L963）
- `testQueuedRefreshCannotResurrectAfterDirtyEdit`（旧 L983）
- `testQueuedRefreshCannotResurrectAfterSSHDisconnect`（旧 L1002）
- `testTransientCleanRefreshErrorPreservesLoadedTextAndRecovers`（旧 L1027）
- `testAppendRejectsStaleCachedTextWhenFreshReadFails`（旧 L1054）
- `testFailedRefreshBlocksStaleWritesUntilSuccessfulRetry`（旧 L1081）
- `testNativeEditorSurvivesTransientRefreshFailureWithUndo`（旧 L1120）
- `testWindowActivationDoesNotRestartInFlightInitialRead`（旧 L1167）
- `testFixedHostDisconnectBeforeLoadShowsReasonWithoutReading`（旧 L1190）
- `testAppendWaitsForReplacementReadWithoutUsingLoadingOrCachedText`（旧 L1204）
- `testAppendWaitsForRemoteReadAndRetainsTextOnSaveFailure`（旧 L1242）
- `testGitPreparationWaitsForWritesAndNeverClosesOrLosesEditedTab`（旧 L1280）
- `testGitPreparationMatchesNativePrivatePathAliasWithoutSavingOtherRepository`（旧 L1318）
- `testProjectCloseWaitsForFileSaveAndRetainsUnsavedOnFailure`（旧 L1347）
- `testCloseFilesSavesOriginallyCleanTabEditedDuringAnotherTabWrite`（旧 L1398）
- `testProjectCloseKeepsNewDraftCreatedInAnotherTabDuringPendingSave`（旧 L1431）
- `testWindowCloseVetoesNewDraftCreatedInAnotherTabDuringPendingSave`（旧 L1482）
- `testApplicationTerminationRechecksEarlierWindowAfterAnotherWindowSave`（旧 L1528）
- `testProjectTabSwitchAndCloseAutomaticallySaveBeforeRemoving`（旧 L1577）
- `testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget`（旧 L1603）
- `testNativeEditorResignFirstResponderWritesRealFile`（旧 L1697）
- `testFocusTriggeredSaveSerializesConcurrentEditsAndKeepsFailures`（旧 L1728）
- `testAnotherLiveChannelTakesOverWithoutTransientReadOnlyState`（旧 L1768）
- `testDirtyUndoSaveDuringEditRenameFailureAndStaleReload`（旧 L1818）
- `testBinaryAndLargeTextAreNotTreatedAsEditable`（旧 L1903）
- `testDisconnectDuringSavePreservesBufferAndBaseline`（旧 L1927）
- `testCleanReloadPublishesOnlyNewBytesAndDropsRenamedRead`（旧 L1950）

### P2-T3 — 22 条

**[SyntaxHighlightingTests.swift](../../../BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift)：22 条** — 高亮、解析失效、颜色与撤销。初判：UI+逻辑，执行前核对每项真实断言。

- `testEmbeddedRequestsStayWithinRequestedRangeAndMatchFreshCaptures`（旧 L25）
- `testEmbeddedSameLengthEditLanguageRemovalAndUndoKeepCurrentColors`（旧 L77）
- `testClosingEmbeddedEditorReleasesPendingHighlightRequests`（旧 L123）
- `testClosingFirstEditorDoesNotPreventSecondEditorAndDiffColors`（旧 L140）
- `testThemeCapturesMatchBundledPaletteAcrossAppearances`（旧 L164）
- `testClosingEditorDuringQueuedParsingReleasesItsContent`（旧 L191）
- `testQueuedSemanticEditAndEarlierInsertionRecolorCurrentViewport`（旧 L210）
- `testParserReadsAcrossUTF16ChunkBoundariesAndEditShift`（旧 L278）
- `testFourSizeRealFileTabHighlightedInputAndParserBudget`（旧 L321）
- `testOldSuccessIsNotDeliveredWhenContentChangesDuringPredicateRead`（旧 L443）
- `testCompositionFinalReplacementKeepsParserAndCurrentColors`（旧 L467）
- `testOldFailureIsNotDeliveredAfterNewEdit`（旧 L495）
- `testEmbeddedQueryReadyDropsInFlightEarlierTokens`（旧 L513）
- `testInjectionReadCannotDeliverOldBaseAndCurrentViewportRecolors`（旧 L542）
- `testRealPluginTailDeleteAllDeleteAndQueuedEditsMatchFreshParserAndColors`（旧 L581）
- `testPluginColorsPreserveTextFontCleanStateAndUndo`（旧 L644）
- `testSelectedCompositionFlowsIntoActualFileBytesAndUndo`（旧 L698）
- `testRepeatedGrammarSwitchReleasesPriorCoordinators`（旧 L743）
- `testRenamingMountedFileChangesGrammarWithoutDiscardingUndo`（旧 L772）
- `testRapidNativeUnicodeReplacementsKeepParserAndBytesAligned`（旧 L824）
- `testAtomicMultiCursorUnicodeEditAndUndoKeepParserAndNativeStorageAligned`（旧 L857）
- `testProductionTransformerMatchesUTF16ParserPoints`（旧 L888）

### P2-T4 — 35 条

**[DiffTabTests.swift](../../../BaileyTests/NativeUI/Git/DiffTabTests.swift)：35 条** — Diff 展示、编辑与内容一致性。初判：UI+逻辑，执行前核对每项真实断言。

- `testNativeDiffRendersRowsThroughTransparentTextSurface`（旧 L126）
- `testSplitAndUnifiedDiffRowTintsReachPixelsInBothThemes`（旧 L169）
- `testNativeEditableDiffPaintsDeletedGhostRowsInBothThemes`（旧 L240）
- `testLongCRLogicalRowDoesNotPutEOFGhostsAtViewportBoundary`（旧 L294）
- `testUnicodeLineSeparatorsDecorateEveryNativeVisualSegment`（旧 L334）
- `testDeletingEveryEditLineKeepsEOFRemovalGhostScrollAccessible`（旧 L375）
- `testDeletedGhostSpacingStaysOnOneTextKitParagraphWithBareCR`（旧 L423）
- `testEditGeometryUsesGitLFLinesAcrossNativeBareCRParagraphs`（旧 L491）
- `testBareCRReviewUsesTextKitParagraphHeightInsteadOfLFOnlyHeight`（旧 L542）
- `testStagedDeletionShowsDeletedLinesInsteadOfMissingRevision`（旧 L589）
- `testStagedConflictWithoutStageZeroIsNotADeletion`（旧 L626）
- `testAppearanceChangeAfterReadErrorKeepsLastSuccessfulDiff`（旧 L655）
- `testIncompleteSelectedGitBlobFailsInsteadOfPublishingTruncatedContent`（旧 L709）
- `testFoldingPreviousDisplayCannotOverrideNewLoadedDiff`（旧 L727）
- `testIndexMutationDuringGitContentReadUsesSelectedImmutableBlob`（旧 L760）
- `testCanonicalEquivalentEditDuringDiffWriteRemainsDirty`（旧 L778）
- `testCanonicalEquivalentGitContentIsARealDiff`（旧 L799）
- `testCanonicalEquivalentNativeDiffEditSaveModeSwitchAndReload`（旧 L830）
- `testSwitchingLoadedDiffTabsKeepsEachNativeDocument`（旧 L928）
- `testNativeDiffEditorFocusLossSavesThroughBackend`（旧 L969）
- `testFocusTriggeredDiffSavePreservesNewestBufferAndFailure`（旧 L1002）
- `testAnotherLiveChannelInvalidatesInFlightDiffSave`（旧 L1038）
- `testWorktreeStagedHistoryBinarySizeAndSymlink`（旧 L1087）
- `testSaveDuringEditFailureAndDisconnectKeepUnsavedContent`（旧 L1147）
- `testNativeDiffRendersAndRetainsTextKitSurface`（旧 L1187）
- `testBackgroundSyntaxCapturesReachNativeDiffColors`（旧 L1229）
- `testCRLFNativeReviewRowsAndEditUndoSavePreserveBytes`（旧 L1255）
- `testNativeDiffUnicodeAndSplitAlignmentWithFoldExpansion`（旧 L1321）
- `testCollapsedDiffAccessibilityPressReachesNativeExpansion`（旧 L1350）
- `testNativeDiffSplitLayoutPreservesPaneIdentity`（旧 L1391）
- `testSplitDiffSynchronizesHorizontalAndVerticalScrolling`（旧 L1454）
- `testReadInFlightCannotReplaceEditingOrDisconnectedContent`（旧 L1540）
- `testGitReloadUpdatesCleanMountedEditSurfaceWithoutLosingDirtyText`（旧 L1578）
- `testNativeDiffEditUndoScrollSaveAndReparent`（旧 L1612）
- `testEnteringEditModeDiscardsInFlightReadAndKeepsSharedPreferenceIdentity`（旧 L1690）

### P3-T1 — 21 条

**[GitHistoryFileTests.swift](../../../BaileyTests/NativeUI/Git/GitHistoryFileTests.swift)：21 条** — 历史快照、只读、恢复与文件重置。初判：UI+逻辑，执行前核对每项真实断言。

- `testRevisionIsNativeReadonlyTextOfSelectedCommitEvenWithSharedEditPreference`（旧 L50）
- `testNativeDiffAccessibilityAllowsOnlyEditableTextChanges`（旧 L98）
- `testRevisionToWorktreeFollowsRenameAndRefreshesWithoutWritingHistoricalBlob`（旧 L113）
- `testHistoricalDiffPreviewKeepsGitActiveAndExplicitActivationStillWorks`（旧 L138）
- `testReopeningLoadedImmutableRevisionDoesNotRepeatGitRead`（旧 L189）
- `testUnmergedWorktreeUsesStageTwoAndPreservesConflictStatus`（旧 L221）
- `testUnbornIndexAndLiteralSpecialPathResolveCorrectBlobs`（旧 L248）
- `testReadFailureDoesNotEraseAlreadyLoadedHistoricalText`（旧 L291）
- `testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`（旧 L316）
- `testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected`（旧 L364）
- `testInvalidRevisionIsNotMisreportedAsAFileMissingFromValidCommit`（旧 L390）
- `testDanglingHeadRefIsNotMistakenForUnbornStagedDiff`（旧 L407）
- `testDeletedHistoricalDiffValidatesTheSelectedCommit`（旧 L430）
- `testMissingSelectedRevisionReportsErrorButRootAndDeletedSidesMayBeEmpty`（旧 L460）
- `testResetHistoricalBinaryFileUpdatesIndexAndWorktreeWithoutChangingHead`（旧 L490）
- `testResetHistoricalFileRefusesStaleWorkingBytesAfterConfirmation`（旧 L528）
- `testResetFileSavesDirtyTabThenOverwritesIndexDiskAndReloadsSameTab`（旧 L558）
- `testResetFileRejectsIndexChangeDuringPreparation`（旧 L607）
- `testProjectRestoresDistinctNativeTabsForHistoricalDiffModes`（旧 L634）
- `testExpandingCommitLoadsBinaryMetadataOnceAndPreservesGitRenamePaths`（旧 L684）
- `testSelectedBinaryAndLargeRevisionsExplainWhyTheyCannotRenderAsText`（旧 L711）

### P3-T2 — 15 条

**[GitExternalRefreshTests.swift](../../../BaileyTests/NativeUI/Git/GitExternalRefreshTests.swift)：4 条** — Git 外部变更驱动的实际列表。初判：UI+逻辑，执行前核对每项真实断言。

- `testVisibleLocalPanelDetectsExternalInitialization`（旧 L23）
- `testVisibleGitPanelRefreshesTwoExternalMutationsWithoutActivation`（旧 L70）
- `testVisibleGitPanelKeepsRefreshPendingWhileRemoteDetailsAreSlow`（旧 L255）
- `testVisibleSSHPanelRefreshesExternalGitChanges`（旧 L356）

**[GitWorkspaceMenuTests.swift](../../../BaileyTests/NativeUI/Git/GitWorkspaceMenuTests.swift)：11 条** — Git Changes、工作树与菜单。初判：UI+逻辑，执行前核对每项真实断言。

- `testUncommittedDialogDefaultsAndPermanentCleanWarning`（旧 L18）
- `testIgnoreAppendsNativeBufferSavesAndCanUndoWithoutRemounting`（旧 L35）
- `testIgnoreReloadsCleanCachedFileBeforeAppendingWithoutMountedView`（旧 L84）
- `testIgnoreCreatesOrdinaryFileTabAndRejectsStaleTarget`（旧 L112）
- `testIgnoreContextMenuIsOnlyOfferedForUntrackedFiles`（旧 L134）
- `testGitChangeRowPreviewKeepsNativeKeyboardAndUsesCorrectIndexSide`（旧 L213）
- `testStaleGitChangeClickCannotOpenDiffInAnotherProject`（旧 L455）
- `testGitChangesTreeKeyboardBrowsesNestedFilesWithoutWritingIndex`（旧 L585）
- `testGitGraphIsKeyboardReadyWhenRepositoryHasNoChangedFiles`（旧 L690）
- `testUncommittedSheetCancelAndConfirmReachRealStash`（旧 L771）
- `testFolderInlineStageAndUnstageAffectOnlyThatDirectory`（旧 L826）

### P3-T3 — 18 条

**[GitBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitBranchDialogTests.swift)：4 条** — Git Branch 表单、默认值与动作。初判：UI+逻辑，执行前核对每项真实断言。

- `testBranchCreateAndRenameUseNativeFieldsAndPreserveRetryInput`（旧 L7）
- `testRemoteCheckoutFetchAndPullExposeNativeDefaults`（旧 L27）
- `testPushWithoutConfiguredRemotesHasNoPossibleSubmit`（旧 L53）
- `testDeleteAndPushHaveGitGraphDefaultsWithExplicitDangerousChoices`（旧 L63）

**[GitCommitDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitCommitDialogTests.swift)：3 条** — Commit Sheet 与仓库身份。初判：UI+逻辑，执行前核对每项真实断言。

- `testNativeFieldsAndMainlineDefaults`（旧 L21）
- `testSheetStaysInInitiatingWindowAndRejectsSameRepositoryProjectSwitch`（旧 L53）
- `testProjectResolutionCannotAuthorizeOldRepositorySnapshot`（旧 L164）

**[GitInteractiveRebaseTests.swift](../../../BaileyTests/NativeUI/Git/GitInteractiveRebaseTests.swift)：3 条** — 原生 PTY／interactive rebase 与 SSH。初判：UI+逻辑，执行前核对每项真实断言。

- `testSSHHelperHandoffUsesTheRebaseFixturesApplication`（旧 L23）
- `testInteractiveRebaseNewPTYUsesRepositoryAndWaitsForRealEditorInput`（旧 L55）
- `testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`（旧 L130）

**[GitRefReplacementTests.swift](../../../BaileyTests/NativeUI/Git/GitRefReplacementTests.swift)：1 条** — Ref 替换、重试与过期输入。初判：UI+逻辑，执行前核对每项真实断言。

- `testBranchAndTagReplacementPreserveRetryInputAndRejectRefMovedDuringConfirmation`（旧 L21）

**[GitRemoteBranchDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitRemoteBranchDialogTests.swift)：1 条** — Remote Branch 操作确认。初判：UI+逻辑，执行前核对每项真实断言。

- `testFetchBindsLocalDestinationAcrossExternalChangesAndStillAllowsFreshForceAndFastForward`（旧 L21）

**[GitStashDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitStashDialogTests.swift)：2 条** — Stash 表单与确认。初判：UI+逻辑，执行前核对每项真实断言。

- `testSpecificStashIdentityIndexDefaultsAndBranchInputValidation`（旧 L9）
- `testNativePopCancellationAndConfirmationUseCapturedSecondStashAndIndexChoice`（旧 L41）

**[GitTagDialogTests.swift](../../../BaileyTests/NativeUI/Git/GitTagDialogTests.swift)：4 条** — Tag 表单与危险选择。初判：UI+逻辑，执行前核对每项真实断言。

- `testPanelTagPushUsesConfiguredDefaultAndRejectsFailedContainmentQuery`（旧 L21）
- `testCreationDefaultsAndEditedFieldsSurviveTypeChanges`（旧 L105）
- `testDeleteRemoteChoicesAreExplicitAndInitiallyLocalOnly`（旧 L128）
- `testPushSelectionAndNoRemoteSafety`（旧 L141）

### P3-T4 — 48 条

**[RecentCommitsViewTests.swift](../../../BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift)：48 条** — Git Graph 拓扑、标签、键盘与绘制。初判：UI+逻辑，执行前核对每项真实断言。

- `testDisplayedHistoricalDiffHasGreySelectionIndependentOfGraphFocus`（旧 L120）
- `testExpandedHistoryAndUncommittedNodesHaveNoPersistentSelectionFill`（旧 L169）
- `testGraphReferenceBadgeTakesKeyboardFocusFromAnotherTree`（旧 L236）
- `testGraphClickRecordsFocusIntentBeforeMovingNativeResponder`（旧 L260）
- `testGraphSpaceUsesTheSelectedCommitAndFileWithoutStealingKeyboard`（旧 L292）
- `testGraphTreeKeyboardTraversesFoldersAndBothHistoricalFiles`（旧 L347）
- `testGraphPaletteKeepsTwelveLaneColors`（旧 L399）
- `testColoredBadgeIconsRemainReadableOverEveryGraphLaneColor`（旧 L414）
- `testTagStashDetachedAndStandaloneWorktreeIconsMatchGraphColors`（旧 L434）
- `testHeadAndStashGraphGutterRemainsClickableInBothAppearances`（旧 L503）
- `testCompositeReferencesUseLongestConfiguredRemoteAndPreserveEveryTarget`（旧 L534）
- `testCompositeReferencesNeverJoinDifferentCommitRowsOrUnknownRemotes`（旧 L569）
- `testCompositeOverflowKeepsRealReferencesAvailableWithoutWholeRowScrolling`（旧 L586）
- `testCurrentAndFeatureUncommittedDiamondsAlignAndToggleInNativeGraph`（旧 L609）
- `testShortCommitHashCopiesWithoutExpandingDetails`（旧 L672）
- `testCompactPrimaryBranchTogglesCommitAndKeepsContextMenu`（旧 L689）
- `testShortPrimaryBranchBadgeKeepsIntrinsicWidth`（旧 L729）
- `testPrimaryBranchContextMenuRemainsAvailableThroughWidthChanges`（旧 L772）
- `testGraphNodeHelpOnlyStatesConfirmedHEADMembershipAndActualReferences`（旧 L810）
- `testNodeHoverTargetRetainsSingleClickAndCommitContextMenu`（旧 L845）
- `testLongCommitMessageCanScrollHorizontallyInNarrowSidebar`（旧 L877）
- `testGraphGutterLeavesRoomForCommitContentAtExtremeLaneCounts`（旧 L890）
- `testDenseRealNativeGraphRetainsVisibleTitleScrollerInBothThemes`（旧 L917）
- `testManyParallelBranchesDoNotScrollWholeGraphSideways`（旧 L954）
- `testShortCommitMessagesDoNotBounceHorizontally`（旧 L977）
- `testExpandedHistoryKeepsLongFolderPathsScrollable`（旧 L999）
- `testRecentCommitHistoryOnlyPagesAtBottom`（旧 L1017）
- `testEntireCommitRowTogglesIncludingGraphMetadataAndBlankSpace`（旧 L1070）
- `testMergedHistoryOpensItsRealFileAfterExpansion`（旧 L1102）
- `testCommitTitleExpandsFilesInWideAndNarrowPanels`（旧 L1160）
- `testNativeContextMenuAtDirectReferencesContainsOnlyTheSelectedObjectActions`（旧 L1216）
- `testDetachedHeadBadgeExpandsCommitAndKeepsCopyHashInMenu`（旧 L1262）
- `testSymbolicRemoteAliasOnlyCopiesFromMenuAndTogglesCommit`（旧 L1292）
- `testDirtyWorktreeDoesNotRepeatLongBranchBadgeInNarrowSidebar`（旧 L1324）
- `testWorktreeDisplayPathsStayUniqueWithSameCheckoutDirectoryNames`（旧 L1370）
- `testWorktreeConflictStatusAlwaysUsesUInTreeAndList`（旧 L1389）
- `testDenseWorktreeGraphKeepsCommitTitlesReadableAcrossThemes`（旧 L1406）
- `testGraphBadgeRowsStayCompactAcrossAppearanceAndFontSizes`（旧 L1529）
- `testGraphBadgesUseCompactSharedMetrics`（旧 L1591）
- `testLocalBranchTakesPriorityOverRemoteDefaultAliasWithoutLosingReferences`（旧 L1598）
- `testUnassociatedWorktreeLabelChineseTranslationPreservesDirectoryName`（旧 L1624）
- `testRealWorktreeHistoryRendersNamedLabelsAndPreservesSharedHeadActions`（旧 L1631）
- `testWorktreePrimaryLabelsReplaceAliasAndIconOnlyCombinations`（旧 L1701）
- `testDetachedAndUnreferencedWorktreesRetainNativeActionsWithoutDuplicatePills`（旧 L1772）
- `testCleanWorktreeBadgesAreSeparateFromUncommittedChangesInBothThemes`（旧 L1848）
- `testUncommittedWorktreeNodeHasSafeMenuAndNativeStageAwareFileActions`（旧 L1950）
- `testStashIsANodeInTheSameGraphWithOnlyStashActions`（旧 L2051）
- `testTagBadgeTogglesSameCommitAsOtherReferences`（旧 L2088）

### P4-T1 — 11 条

**[AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift)：1 条** — 真正用户可见的 Open File 菜单。原有隔离宿主 ⌘Q 断言仍有后续 NativeUI 消费者，归 P4-T5。

- `testFileMenuProvidesOpenFileKeyboardShortcut`（旧 L7）

**[TreeRowHitTestingTests.swift](../../../BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift)：7 条** — 共享 Files／Git 行命中与滚动。初判：UI，执行前核对每项真实断言。

- `testSelectionFillAndKeyboardOutlineRenderIndependently`（旧 L24）
- `testTreeFileAndFolderNamesOpenNativeContextMenuWithoutPrimaryAction`（旧 L74）
- `testShortNamesDoNotBounceInFilesFoldersAndGitChanges`（旧 L234）
- `testLongNamesScrollWithoutMovingGitActions`（旧 L255）
- `testSharedLabelStopsBouncingAfterPanelWidens`（旧 L286）
- `testSharedFileRowSeparatesImmediateBrowseFromDoubleClickActivation`（旧 L322）
- `testFilesAndGitRowsOwnTheirFullHitArea`（旧 L349）

**[DockFocusP2RegressionTests.swift](../../../BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift)：3 条** — Dock 点击／拖放、命令面板交接。初判：UI，执行前核对每项真实断言。

- `testClickingEmptyToolPaneReleasesHostingRootResponder`（旧 L22）
- `testDragReleasedOverAnotherDockGroupDoesNotActivateIt`（旧 L78）
- `testPaletteFileManagerCommandTransfersKeyboardFocusToVisibleFileTree`（旧 L128）

### P4-T2 — 19 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：19 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testAsyncFilesTargetBecomingCurrentRestoresVisibleFileCursor`（旧 L32）
- `testFilesCursorDoesNotActivateBehindPaletteBeforeSearchFieldFocus`（旧 L71）
- `testCancelingCommandPaletteRestoresFilesRowKeyboardNavigation`（旧 L116）
- `testCurrentToolTreeResponderFollowsDockGroupAfterPanelSwitch`（旧 L197）
- `testEditorPaletteSwitchToFilesRestoresNewToolKeyboardFocus`（旧 L251）
- `testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField`（旧 L315）
- `testCancelingCommandPaletteRestoresGitTreeKeyboardNavigation`（旧 L393）
- `testFilesActivationBeforeDirectoryListingFocusesFirstVisibleRowWhenLoaded`（旧 L452）
- `testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus`（旧 L489）
- `testFilesTreeClickTransfersNativeKeyboardAndArrowsMoveTheVisibleCursor`（旧 L548）
- `testDockIntegratedFilesRowsKeepNativeFocusWhenOpeningAnotherPane`（旧 L645）
- `testSwitchingToFileManagerSelectsVisibleCurrentFileAndTakesNativeKeyboard`（旧 L762）
- `testFilesOpenedInItsOwnDockGroupDoNotRetainHiddenKeyboardFocus`（旧 L814）
- `testDockGroupClickDoesNotPreemptNativeFieldFocus`（旧 L874）
- `testNarrowTerminalFindFieldEditorBelongsOnlyToItsActualDockGroup`（旧 L911）
- `testRestoredGroupIDsReplaceOnlyTheFocusScopesNotTheEditor`（旧 L956）
- `testFocusAcrossAppearancesAndSizesKeepsTheNativeDocument`（旧 L994）
- `testResponderOwnershipRejectsInactiveProjectsHiddenTabsAndParking`（旧 L1040）
- `testDockToolsTakeNativeFocusWithoutReplacingVisibleEditors`（旧 L1100）

### P4-T3 — 17 条

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：17 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow`（旧 L1293）
- `testProjectsDropFilesOpenTabsAndFoldersAddProjects`（旧 L1334）
- `testFinderDropIntoAnotherTabStripKeepsNewTabsInTheActualTargetGroup`（旧 L1377）
- `testFinderDropIntoEmptyTabGroupKeepsGroupAndDoesNotMoveFilesAcrossProjects`（旧 L1431）
- `testQueuedFinderBatchRejectsChangedReceivingProjectBeforeRestoredOwnerAttaches`（旧 L1480）
- `testFinderProjectsDropDoesNotSwitchTargetDuringProviderLoading`（旧 L1532）
- `testFinderEmptyStateDropCannotOpenIntoFolderAddedWhileProviderLoads`（旧 L1568）
- `testFinderDropDoesNotRouteLateProvidersIntoAnotherOrClosedWindow`（旧 L1597）
- `testExternalBatchRoutesToActualMountedFileBuffers`（旧 L1629）
- `testExternalOpenFindsExistingFileInOtherWindowBeforeCreatingAnEditor`（旧 L1709）
- `testFinderReusesMacFileInsideRemoteProjectInAnotherWindow`（旧 L1774）
- `testExternalOpenDefersUntilAllCreatedWindowsHaveAttached`（旧 L1819）
- `testExternalOpenKeepsOneDirectoryProjectAcrossInterleavedWindowBatch`（旧 L1863）
- `testExternalOpenCancelledWhenOwningWindowClosesBeforeRestoreCompletes`（旧 L1906）
- `testClosingAnUnattachedFileOwnerDrainsAllWaitingFinderEventsWithoutRetargeting`（旧 L1940）
- `testAnUnattachedUnrelatedManagerCannotHoldFinderRequestsForever`（旧 L1990）
- `testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`（旧 L2014）

### P4-T4 — 15 条

**[WorkspaceContentIdentityTests.swift](../../../BaileyTests/WorkspaceUI/Tabs/WorkspaceContentIdentityTests.swift)：3 条** — 标签和编辑器／Diff／Browser 身份。初判：UI，执行前核对每项真实断言。

- `testDockTabStripOnlyBouncesWhenTabsOverflowAfterResizing`（旧 L48）
- `testFileDiffFileReturnsToSameEditorAndDiffDocument`（旧 L127）
- `testBrowserTabBetweenTwoFilesDoesNotStealTheirNativeEditors`（旧 L185）

**[WorkspaceWindowCloseTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowCloseTests.swift)：6 条** — 多窗关闭、保存否决与 Sheet 归属。初判：UI，执行前核对每项真实断言。

- `testEmptyWorkspaceAttachesToWindowWhenHostingViewWasRenderedOffscreen`（旧 L81）
- `testTwoNativeWorkspacesAttachOwnWindowsAndKeepFolderPickerIsolated`（旧 L117）
- `testBackgroundProjectDirtyCloseSheetStaysInItsOwningWindow`（旧 L178）
- `testRepeatedCloseAllKeepsCleanTabsUntilDirtyConfirmationResolves`（旧 L297）
- `testProjectCloseCannotBypassAnActiveTabClose`（旧 L343）
- `testNativeCloseDoesNotDiscardFailedSaveThenClosesAfterRetry`（旧 L367）

**[WorkspaceWindowIsolationTests.swift](../../../BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift)：6 条** — 跨窗焦点／Finder／恢复。初判：UI+逻辑，执行前核对每项真实断言。

- `testWindowFocusLossSavesAllDirtyBuffersNotOnlyTheMostRecentTab`（旧 L1161）
- `testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers`（旧 L1208）
- `testClosingOneWorkspaceWindowKeepsOtherManagerEditorAndSnapshot`（旧 L2057）
- `testSpeculativeSceneConstructionDoesNotRegisterOrConsumeRestoredWindows`（旧 L2124）
- `testLocalWorktreeUseProtectsMacFileInsideAnSSHProject`（旧 L2172）
- `testTwoApplicationOwnersNeverShareWorkspaceRegistryOrWorktreeProtection`（旧 L2205）

### P4-T5 — 21 条

**[PaneRetentionTests.swift](../../../BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift)：20 条** — Terminal／Browser／Editor 原生资源生命周期。初判：UI+逻辑，执行前核对每项真实断言。

- `testParkingDropsObsoleteHostActionsBeforeDelayedDismantle`（旧 L12）
- `testTerminalFindFieldStaysInsideNarrowAndWidePanes`（旧 L47）
- `testProjectAndPaneTabObservationsReplacePublisherRelays`（旧 L94）
- `testNativeUnsavedConfirmationPreservesSheetAndButtonSemantics`（旧 L124）
- `testNativeFileAndSSHChoosersStayOnOwningWindow`（旧 L157）
- `testTabSwitcherKeepsProvisionalSelectionAndCancelsWithoutSideEffects`（旧 L232）
- `testBrowserKVOUpdatesObservationHistoryFaviconAndRepeatedFocus`（旧 L304）
- `testWebKitJavaScriptDialogsInvokeNativeDelegateSheets`（旧 L373）
- `testBrowserAndEditorStateSurviveViewRemount`（旧 L419）
- `testClosingMountedFiveFileTabsReleasesTheirNativeDocuments`（旧 L515）
- `testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears`（旧 L647）
- `testHundredThousandLineWorkspaceEditsSavesAndReleasesFile`（旧 L690）
- `testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks`（旧 L777）
- `testExternalReloadReleasesObsoleteDocumentEvenWhenOldScrollViewIsCached`（旧 L859）
- `testEditorRetainsScrollAndReleasesRetiredNativeResources`（旧 L942）
- `testObservedDockMoveReparentsRealEditorAndPreservesUndoAndScroll`（旧 L1028）
- `testTerminalAndFindObservationPreserveNativeSurfaceIdentity`（旧 L1124）
- `testUnmanagedForegroundSSHRejectsLocalFinderPathsBeforeAnyRemoteHandoff`（旧 L1177）
- `testUnmanagedExecSSHRejectsLocalFinderPathsEvenWhenForegroundPIDIsShellPID`（旧 L1181）
- `testTerminalKeepsSameShellAcrossParkingAndRemount`（旧 L1236）

**[AppMenuIsolationTests.swift](../../../BaileyTests/NativeUI/App/AppMenuIsolationTests.swift)：1 条** — 前期 NativeUI 宿主仍需防止 ⌘Q 意外结束测试；直到最后一条原生宿主测试迁走才一起删除覆盖与产品中的测试专属拦截。

- `testTestHostHasNoQuitKeyboardEquivalent`（旧 L23）

## 非 UI Target 的混入检查

原有 Unit 8 文件／75 方法、Integration 20 文件／231 方法；目录名不能证明没有图形依赖。P1-T3 对 306 个方法及其 transitive fixtures 复核：以「实际创建窗口、绘制、聚焦、事件输入、UI 表现」而非单独 `import AppKit` 判断。

**额外重点：[`SessionStoreTests.swift`](../../../BaileyTests/Integration/Workspace/SessionStoreTests.swift)**：原有 10 方法，其中下列两项具有明确原生窗口/视图依赖，归 `P4-T4` 完整替代；其余方法亦须逐项检查：

- `testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction`（`NSHostingView`／`NSWindow`／`NSTextView` 身份）：P4-T4 将用户可见保留行为归 UI，快照单一性逻辑归非 UI。
- `testClosedWindowCannotBeUsedForLateFileOperationErrors`（真实 `NSWindow` 装配）：P4-T4 将窗口关后错误不可回送的最终行为归 UI，目标识别不变量可保留非 UI。

**[`AppSettingsTests.swift`](../../../BaileyTests/Integration/Settings/AppSettingsTests.swift)**：5 方法，**全部都需审查隐藏的全局 UI 副作用**。源码 `AppSettings.init(configURL:)` 最后无条件执行 `applyAppearance()`（写 `NSApp?.appearance`）和 `reloadThemeSelection()`（写 `Theme` 全局选择），即使某条测试只验证 TOML 解析也会触发；其中两项还显式在 teardown 恢复 `NSApp?.appearance`，一项设置 `.theme = .dark` 再次写入。P1-T3 先查明并清理可安全去掉的非 UI 初始化/测试副作用，证明共享 `AppSettings.shared` 启动外观不变；P4-T5 再验真实 Settings GUI。保留具有实质断言的配置/Observation/Theme 回归，不能以“仅两条触及 NSApp”漏掉其余三条。

## 已存在的 BaileyUITests：必须重验的 10 条

**[WorkspaceFilesUITests.swift](../../../BaileyUITests/Files/WorkspaceFilesUITests.swift) — 4 条：P1-T2 实测基线，按后续领域任务补足断言**
- `testAddFolderAndOpenFileThroughRealFileTree`
- `testCommandPaletteRestoresFileTreeKeyboardAfterDismissal`
- `testNativeEditorSavesActualFileContentsToDisk`
- `testOpeningTheSameFileFromMenuReusesItsExistingTab`

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

