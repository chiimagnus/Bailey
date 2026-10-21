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

## 发现 F-04

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreePanel.swift:185`
- 摘要：`改名/新建输入框关闭时没有重新将键盘焦点交回仍可见 Files 树`
- 风险：`Return/Escape/失焦后 Files 当前行可见却无法直接接收方向键，直到用户再次点树或切组`
- 预期修复：`以模型的输入完成变化触发原有 focusSelectedRow，只在前台可见且无活动输入时恢复，沿用单一 TreeKeyboardOwner`
- 验证：`WorkspaceWindowIsolationTests：原生窗口取消改名、新建及完成操作后真实 firstResponder 与箭头键；make test / make build`
- 解决证据：`独立实机 NSWindow 原生回归 /tmp/bailey-p3-audit-scoped.log: WorkspaceWindowIsolationTests.testFilesInlineRenameAndDraftExitRestoreNativeTreeKeyboardFocus PASSED (0.673 s)，真实 native fieldEditor -> TreeKeyboardView -> Down 选择另一行；P3专项 123 tests、1 skipped、0 failures、make test 退出0。首轮 Red 未能执行（共享桌面抢占使 key window 条件不足），不可冒充 Red；复核入口逻辑确有缺少关闭时回交焦点的缺口。`


## 发现 F-03

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:279`
- 摘要：`改名成功后只迁移目录展开状态，没有迁移当前行游标；重建时会清空选中的改名文件或子项`
- 风险：`文件与目录改名后方向键焦点位置丢失，展开的子项不再连续可导航，违背 P3 选中行稳定性`
- 预期修复：`在成功 rename 的同一状态所有者中重映射选中行及目录后代路径，再重建显示树`
- 验证：`FileTreeTests：改名文件、目录及嵌套后代，核对实际文件字节与游标；make test / make build`
- 解决证据：`Red: /tmp/bailey-p3-audit-red-v2.log，FileTreeTests 1 failed/3 assertions；Green: /tmp/bailey-p3-audit-green-v1.log 同一模型测试 1 passed/0 failures，核对改名后磁盘字节与目录后代 selectedItem；Debug make build+strict codesign 成功 /tmp/bailey-p3-audit-build.log。全量回归另核对。`


## 发现 F-02

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Files/FileTreePanel.swift:183`
- 摘要：`Command Palette 正在编辑查询时，切换/挂载 File Manager 会无视临时输入层并调用 makeFirstResponder 抢走搜索框键盘焦点`
- 风险：`命令面板仍显示但无法输入，键盘被不可交互的后层文件树接收；与 P2 原生当前输入焦点所有权相冲突`
- 预期修复：`在 Files 原有 canFocusKeyboard 权限入口要求没有激活的 Command Palette/Sheet；禁止按键属于临时输入框时接管，恢复仍交给既有 Palette dismiss 的有效归属逻辑，不重复构造全局焦点系统`
- 验证：`WorkspaceWindowIsolationTests.testSwitchingToFilesBehindCommandPaletteDoesNotStealItsSearchField 真实 NSWindow Red→Green；取消 Palette 后 Files 恢复；已有 Files/Git/Graph 混合回归、完整 make test 和签名 App GUI`
- 解决证据：`根因路径已增加 Palette 可见性前置门槛：ToolPanelView 的 canFocusKeyboard 在 manager.isCommandPaletteVisible 时拒绝，FileTreeScrollView 许可恢复时才恢复游标；Sheet 仍在时禁止 makeFirstResponder。非前台实集成测试 /tmp/bailey-p3-palette-pending-green.log：testFilesCursorDoesNotActivateBehindPaletteBeforeSearchFieldFocus 1 通过（真实 ContentView/PanelContext，Palette 早于原生 fieldEditor 出现，Files 先不选行、撤销后选中且无新文件标签）。/tmp/bailey-p3-focus-scoped-v3.log：P3 相关 123 tests/0 failures/5 skipped、退出0。原生 Palette 覆盖切组测试 /tmp/bailey-p3-palette-race-red.log 因未获 key window 跳过，无真实前台 Red/Green，保留 Deferred。`


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

## 2026-10-21 P3 独立再审（取代上方历史 Gate）

### 原任务与提交核销

- **P3-T1 / e3104c6**：逐文件检查 DockWorkspaceModel、Project、TerminalManager、ToolPanelView、FileTreePanel、TreeRowStyle。Files 单击沿 TreeFileRow → manager.openFile(activating:false) → Project.openFile / selectTab → Dock，在可见的其它编辑器组浏览而不夺 Files 焦点，已有 FileTab 复用；双击才激活编辑器；同组无其它可见编辑器时正常切换内容，不留不可见响应者。
- **P3-T2 / dc2f77a**：核对 FileTreeModel.selectedPath、rebuild、toggle、sync、TreeKeyboardHost/handleKey、共享行样式和 XCTest，追溯 c40ac5a 重入 Files 焦点与 e37fe88 删除多余 SwiftUI 焦点后备。实际生产已只用唯一行游标和原生键盘视图；旧 @FocusState/.focusable fallback 无有效生产调用者，不再保留。
- **F-03 根因修复**：后端 rename 成功且身份有效时，连同 expanded 将 selectedPath 按原目录前缀迁移，再 rebuild。Red：/tmp/bailey-p3-audit-red-v2.log（1 case、3 断言失败）；Green：/tmp/bailey-p3-audit-green-v1.log（1 case 通过），核验文件内容及重命名目录下当前子项。
- **F-04 焦点生命周期修复**：最后一个内联改名／新建输入退出后才触发已有 focusSelectedRow；焦点归属仍检查当前 Dock 组、目标、key window 和 fieldEditor。首轮 Red 尝试因 key window 不可用而跳过，不伪报 Red；最终原生 NSWindow 测试通过，核对 fieldEditor → TreeKeyboardView 和真实 Down 后游标移动。
- **F-02 保留 Deferred**：Palette 已显示但原生搜索框尚未就绪时，原本仅靠 fieldEditor 检测会允许 Files 抢占焦点。现在 Files 的焦点资格首先受 `manager.isCommandPaletteVisible` 限制，恢复资格变化后仍由同一原生键盘宿主接管；原生 Sheet 存在时也禁止自动接管。真实 ContentView 非前台时序测试通过，但前台 Palette 覆盖切组用例受其它 AI 同时占用 key window 而跳过，不冒充 GUI 完整验证。

### 现行可验证证据

| 项目 | 结果 |
| --- | --- |
| P3 专项 | 初次 /tmp/bailey-p3-audit-scoped.log：**123 项、0 失败、1 skipped**；新增焦点门槛后 /tmp/bailey-p3-focus-scoped-v3.log：**123 项、0 失败、5 skipped，命令退出 0**，因共享前台窗口被其它 AI 测试占用，跳过的主要是原生焦点用例；非 GUI 逻辑及共享树行结果仍通过。 |
| Palette 前置时序 | /tmp/bailey-p3-palette-pending-green.log：**1 项通过**。真实 `ContentView` + ToolPanelView 在 Palette 早于搜索框获焦时切到 Files，确认不选树行；Palette 关闭后恢复游标且文件标签未新增。/tmp/bailey-p3-palette-race-red.log：原生前台测试 1 skipped（无 key window），不当作 Red。 |
| Debug / 严格签名 | 最后一次 /tmp/bailey-p3-focus-debug-final.log：`make build DERIVED_DATA=build/DerivedData-p3-audit` 退出 0，BUILD SUCCEEDED，`codesign --verify --deep --strict` 通过。 |
| Release / 严格签名 | /tmp/bailey-p3-audit-release.log：BUILD SUCCEEDED，codesign --verify --deep --strict 通过；第三方 parser 的旧 C/C++ 告警与无 App Intents 元数据提示保留，不误记 P3 Swift 新诊断。 |
| 修复提交 | cdd84524cf94c51e53225bac51ecae8ef7541397；只包含 FileTreeModel、FileTreePanel、两份回归测试和 docs/features/files.md（5 文件）；P1/P2/P4/CI 的未提交改动未包含。 |
| 正式 App | 用户本轮明确跳过正式 App 替换；没有替换、启动或重启 `/Applications/Bailey.app`。隔离 XCTest/AppKit 不等于正式 App 已部署。 |
| 全量首次 | /tmp/bailey-p3-audit-full.log：被 P2 并行新测试编译错误阻断。 |
| 全量再试 | /tmp/bailey-p3-audit-full-v2.log：P2 DockFocus、P4 GitWorkspaceMenu、P1 PaneRetention 等失败，P1 原生窗口关闭用例长期不进展，仅终止本轮自身测试进程；全量没有成功结束。 |
| 规范 | todo validate 通过；git diff --check 通过。 |

### 未验证条件及 Gate

共享前台窗口中的 Palette 覆盖切换（F-02）仍需独占 key window 原生测试；macOS 15.6 真机、实体触控板、完整 VoiceOver、语言／外观／显示器组合缺位；Windows SSH 真实联机／断线恢复／慢网络与符号链接导航没有本轮 E2E，当前 scope 及异步单测不等于远端验证。其他 AI 正在修改 P1/P2/P4，共享仓库尚未获得同一最终版本的全量 XCTest Green。

**本轮 Gate：No-Go（完整验收层面）。** P3 两任务真实调用链已落地，F-03/F-04 有模型及原生测试通过，F-02 的早期时序已有非前台集成回归；但 Palette 前台 E2E 和共享源码的完整 XCTest 尚未核销。只提交 P3 的源码、测试、特性文档和审计记录，不包含 P1/P2/P4 其它 AI 正在修改的内容。
