# Audit P3 - focus-navigation

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/focus-navigation/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 文件展示与活动 Dock 焦点解耦
- [x] P3-T2 Files 单行选择及键盘焦点边框

## 任务到文件的映射

- P3-T1（`e3104c6`）：`Bailey/Workspace/{DockWorkspaceModel,Project,TerminalManager}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/Files/FileTreePanel.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`；`DockWorkspaceTests`、`TreeRowHitTestingTests` 与原生隔离 App 单／双击；同步 `docs/features/{dock,files,editor}.md`、`docs/ui.md`。
- P3-T2（`dc2f77a`）：`Bailey/Files/{FileTreeModel,FileTreePanel}.swift`（唯一文件行游标＋原生 keyboard first responder）、`Bailey/Shared/Tree/TreeRowStyle.swift`（一层行环）、`Bailey/UI/Panels/ToolPanelView.swift`（工作区身份＋动态可见性）、`Bailey/UI/WorkspaceDockView.swift`（不抢 SwiftUI 宿主焦点）；`FileTreeTests`、`WorkspaceWindowIsolationTests`、`TreeRowHitTestingTests`、完整 XCTest；同步 `docs/features/{files,dock}.md`、`docs/ui.md`。

## 发现项

## 发现 F-02

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`Bailey/Files/FileTreePanel.swift:183`
- 摘要：`Command Palette 正在编辑查询时，切换/挂载 File Manager 会无视临时输入层并调用 makeFirstResponder 抢走搜索框键盘焦点`
- 风险：`命令面板仍显示但无法输入，键盘被不可交互的后层文件树接收；与 P2 原生当前输入焦点所有权相冲突`
- 预期修复：`在 Files 原有 canFocusKeyboard 权限入口要求没有激活的 Command Palette/Sheet；禁止按键属于临时输入框时接管，恢复仍交给既有 Palette dismiss 的有效归属逻辑，不重复构造全局焦点系统`
- 验证：`WorkspaceWindowIsolationTests.testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField 真实 NSWindow Red→Green；取消 Palette 后 Files 恢复；已有 Files/Git/Graph 混合回归、完整 make test 和签名 App GUI`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Shared/Tree/TreeRowStyle.swift:274`
- 摘要：`生产中 Files/Git 树行统一传入 focusRing，旧 nil fallback 的 @FocusState 与 .focusable 已无实际生产调用者`
- 风险：`双轨焦点逻辑仅由组件测试默认参数触发，与真实 TreeKeyboardHost 机制不一致，后续组件误用会重现系统与主题焦点环叠加`
- 预期修复：`共享 TreeFileRow/TreeFolderRow 使用明确 Bool 焦点外观，删除仅测试调用的旧 nil 分支与私有 @FocusState，并让组件测试明确以 false 传入`
- 验证：`覆盖 TreeRowHitTestingTests、Files/Git NativeUI、焦点环浅暗主题与双击、原生窗口键盘回归`
- 解决证据：`e37fe88 删除 TreeFileRow/TreeFolderRow 的 nil focusRing、SwiftUI @FocusState 和 .focusable 旧双轨，所有生产 Files/Git 使用方统一传 Bool 绘制单一环；/tmp/bailey-focus-audit-palette-red-tree.log TreeRowHitTestingTests 7 项/0 失败，/tmp/bailey-focus-audit-palette-extended.log 11 项/0 失败（含 Graph Space 与 Git Changes）。`


- 本阶段在本轮复核后无剩余满足准入标准的未解决 P3 finding。已复现并修复的真实故障：Files 单击后旧编辑器仍持有原生 `firstResponder`，SwiftUI 行状态未接管键盘；Dock 随后错误切回编辑器；原生 SwiftUI 自动焦点环叠加主题细环。Red/Green 的原生事件、隔离 App 截图及日志已核对。
- `GitPanel`/`RecentCommitsView` 单击变更或历史项的独立焦点问题归 **P4-T1/P4-T2**，此轮在真实隔离 App 中仍可见“Git 行打开内容同时激活编辑器”的行为。Git 不是 P3 文件树选中游标的所有者；不把尚未实施的 P4 冒称 P3 失败或已经完成。

## 修复日志

- `e3104c6`：区分 Files 预览与激活编辑器，复用标签、不拆 Dock、不引入 Zed Preview Tab。
- `dc2f77a`：Files 使用一份轻量原生键盘接收视图，原生 `firstResponder` 实际从编辑器移至 Files；同组 Files 被编辑器替换时不聚焦隐藏列表。清除旧 SwiftUI `focusedRow` 焦点双轨与临时诊断日志，保留共享树行、原生输入框/右键、Git 操作按钮及布局。
- 此后再次强化同组原生回归：窗口确为前台 key 时等待编辑器自动成为 `firstResponder`，否则只验证可见编辑器可接受输入；`make test ONLY_TESTING='BaileyTests/WorkspaceWindowIsolationTests/testFilesOpenedInItsOwnDockGroupDoNotRetainHiddenKeyboardFocus'` 退出 0；已纳入最终 `dc2f77a`，不是额外遗留工作。

## 验证日志

- **全量 XCTest：** `make test` → 588 tests，0 failures，8 skipped，完整命令退出码 **0**；结果 `/tmp/bailey-focus-p3-t2-fulltest-final-v2.log`。该轮覆盖 Files/Git 共享 TreeRow、Dock、多窗口、原生 TextKit/IME、Finder、拖放、Git 更新、窗口保存与终端资源释放。因最后加强了同组回归断言，又单独运行该测试 → 1 passed、退出码 0；`/tmp/bailey-focus-p3-t2-auto-focus-recheck.log`。
- **构建／签名：** `make build` → BUILD SUCCEEDED + `codesign --verify --deep --strict`；签名 Debug 包 `build/DerivedData/Build/Products/Debug/Bailey.app`，macOS 27.2 / Xcode 27.2 / Apple Silicon。
- **原生行为矩阵：** 独立 FileTreePanel 与完整 Dock（旧编辑器先持有键盘）；Files 单击浏览但不激活编辑器；↑↓真实键码、←→子目录/折叠/无子项、Return 明确打开、Space 预览、Escape 清游标、Cmd+方向键不接管；输入框与工具面板的原生第一响应者互斥；Git 共用树行不被这次 Files 改动破坏。单组 Files 被新文件替换时改为可见编辑器；双窗口隔离、明暗/不同窗尺寸/原生内容身份和资源回收；空列表、目录折叠、跨 scope/SSH 身份、1,024 普通文件＋3 Unicode/emoji/长文件名，均有 XCTest 覆盖。新焦点守卫还检查 `files.selected==.files` 而不只信赖旧 `activeGroupID`。
- **真实 App 终端副作用：** 通过用户桌面中**仅本次拥有的隔离 Bailey**（正式用户 App 未重启），从 Git Manager 切换到 File Manager 后，单击 `alpha.swift` 仍由 Files 接收输入、只见一个主题色细描边；按 ↓ 选中 `beta.swift`，编辑器不因预览抢焦点；双击 `beta.swift` 后 AX `AXTextArea` 获焦且编辑光标出现。证据 `/tmp/bailey-focus-verify.kniA3O/final-files-after-{click,down,double}.png`；两个临时源文件前后 SHA-256 不变，已有 `beta.swift` 标签数量没有增加。原系统双层焦点环已取消。这是原生 GUI 最终结果，不以事件派发成功冒充有效导航。
- **条件跳过（非通过，须专用获授权 SSH 主机）共 8 项：** `GitExternalRefreshTests.testVisibleSSHPanelRefreshesExternalGitChanges`、`GitInteractiveRebaseTests.testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`、`GitWorkspaceSSHTests.testAuthorizedSSHRefArchiveBinaryResetStashCleanAndIgnorePersistOnWindows`、`GitWorkspaceSSHTests.testAuthorizedSSHWorktreeCreationAndRemovalPreservesBranch`、`SSHFileTreeLiveTests.testAuthorizedWindowsSSHBatchDirectoryListingAndIndependentFailures`、`SSHFileTreeLiveTests.testAuthorizedWindowsSSHFileTabCapacityAndBytePreservingSave`、`SSHFileTreeLiveTests.testAuthorizedWindowsSSHRenamePreservesActualDirectoryEntries`、`SSHGitRecoveryLiveTests.testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`。原因：缺少显式授权的测试主机 `BAILEY_P4_TEST_SSH_HOST`，禁止借用用户 SSH master。影响是远端实际联机导航／断线恢复与真实 Git/文件字节能力未由这 8 项确认；以本地场景、scope 隔离和模拟远端测试替代；下次在授权测试主机运行 `BAILEY_P4_TEST_SSH_HOST=<专用主机> TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=<专用主机> make test`。不妨碍本轮已在本机证明的 Files 原生焦点修复，**不宣称远端全部验收完成**。
- **其它不可覆盖：** macOS 15.6 真机不可得（风险：最低系统的原生焦点环和 KeyDown 行为需要实机复核；以 Xcode 当前部署目标编译和 27.2 原生测试替代）；实体触控板、完整 VoiceOver 与中/英文×明暗×不同物理屏幕组合未逐一实测（影响：触控板双击/无障碍焦点环的物理输入效果还需补验；替代：NSWindow 事件＋同尺寸 GUI 截图＋共享行辅助功能单测）。均明确不等于‘已在这些环境通过’。
- **文档与清理：** 核对 `docs/features/{files,dock,editor}.md`、`docs/ui.md` 的当前职责，P3 新能力和明确未做的 P4/多选各有归属；`.github/features/focus-navigation/plan-p3.md` 同步修正 SwiftUI 焦点假设，`todo.toml` 持有唯一任务完成状态。相对链接／锚点校验通过；`git diff --check`、`todo validate` 通过。Feature 计划及审计仅保留本地，未混入源代码提交。

## P3-T2 补验：切回 Files 时的自动焦点

- **Red：** 真实隔离 App 从工作编辑器回 Files 仅在点击文件行时取得键盘输入；从 Git 切回 Files 时原生树重挂载，`onAppear` 早于 `NSView` 进入窗口，选中行仅灰底而无焦点环，方向键失效。旧 XCTest 曾把“选中行出现”误当鼠标点击成功，且后台测试窗口 `NSApp.isActive=false` 时不可验证前台焦点。
- **Green：** 继续复用 FileTreeModel 唯一 `selectedPath` 与 FileTreeKeyboardView。激活 Files 时先选原游标／当前工作文件／首条可见项，目录初次加载则等待行出现；窗口真实成为 key、Files 被激活或原生视图挂载后才尝试取原生第一响应者。不同项目、后台窗口、改名／新建输入框均不强抢，不新增全局监听或工作标签。
- **真实 GUI：** 编辑器 beta.swift → File Manager 自动描边 beta，直接 ↑ 到 alpha，编辑区仍是 beta；Git Manager → File Manager 重新挂载后自动描边 beta，直接 ↑ 到 alpha；图片 `/tmp/bailey-focus-verify.kniA3O/focus-reenter-{files-after,up}.png`、`focus-attached-{File-Manager-after,files-after-up}.png`。
- **针对性 XCTest：** 进入 Files 前无选中行、Git→Files 保留游标、旧编辑器键盘交接、异步目录加载及同组隐藏退路：**5 tests / 0 failures**，见 `/tmp/bailey-focus-reenter-final-targeted.log`。
- **最终完整回归：** `make test` → **590 tests / 8 skipped / 0 failures**，退出码 **0**，`/tmp/bailey-focus-reenter-full-final.log`；8 个跳过用例仍属于未授权的专用 SSH 主机环境，未冒称已测。此前 588 项的审计结果保留为历史，不替代本轮最新结果。
- **提交与安装：** `c40ac5a` 仅含 Files 焦点、原生窗口测试及 Files/Dock 文档；`make build` 成功，严格 `codesign --verify --deep --strict` 成功。完整签名 App 同卷暂存、整包替换并复验 `/Applications/Bailey.app` 成功；新包 `bailey.debug.dylib` SHA-256 为 `e87cbae93585fad512e88f82ab424ec631e572f407354d9e692efb39cf7f0615`，替换前用户正式 App PID `98949` 与替换后相同，未重启；新代码待用户自行重新打开正式 App 时加载。Feature 计划仍只在本地，不在源码提交。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（仅 P3 Files 两任务已完成，允许进入 P4 Git 专项实施）
- 理由：原生键盘输入和单层边框的**实际用户可见行为**、关键前置焦点冲突、同组消失退路、跨窗口/共享行和容量边界均有最终源码、自动测试、真机 GUI 证据。上列环境缺口清楚且未冒充已覆盖。

## 最终状态与剩余风险

- 当前状态：`Resolved`（P3 Gate Go；Git Changes / Git Graph P4 尚未实施）
- 剩余风险：专用 Windows SSH 真实联机、macOS 15.6、实体触控板及完整 VoiceOver 等环境未测；已列具体原因、替代证据和补验路径。P4 Git 焦点行仍待后续任务实现，不由 P3 代为宣称。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-21 独立按提交复核（不采用上方历史 Gate 作依据）

| Task | 独立核对的提交 | 当前真实调用链与不变量 |
| --- | --- | --- |
| P3-T1 | `e3104c6` | 共享 `TreeFileRow` 的文件整行使用 `.onTapGesture` 而非 Button，双击仍有单独的激活动作；`FileTreeRow` 单击经 `TerminalManager.openFile(...,activating:false)` 只在其它可见组展示文件，不改当前 Files 第一响应者；双击才激活编辑器。 |
| P3-T2 | `dc2f77a`、`c40ac5a`、本轮 `e37fe88` | `FileTreeModel.selectedPath` 是唯一列表游标；`TreeKeyboardHost` 接收真实方向键/空格并恢复当前文件；`isCurrentTarget`、当前 Dock 组及窗口有效性保护防止 SSH/项目串线。本轮删除所有生产使用方已淘汰的共享行 `@FocusState` 双轨及系统默认焦点环后备。 |

本轮 **F-01** 源码穷尽共享 `TreeFileRow/TreeFolderRow` 的所有生产调用方，皆显式传入 `focusRing: Bool`；只有旧组件测试曾走 `nil` 后备。删除后的 `TreeRowHitTestingTests` 7 项/0 失败，混合 Files、Git Changes、Git Graph 原生焦点测试 11 项/0 失败（`/tmp/bailey-focus-audit-palette-extended.log`）。共享行视觉现在只有显式 `selected` 灰底、`focusRing` 细环及 Hover 三状态，不再存在第二个系统聚焦路径。无证据支持删除原生键盘宿主或禁用真实输入框的原生焦点。


