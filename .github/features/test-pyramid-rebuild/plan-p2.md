# P2 · 将重复 UI E2E 交给宿主测试

**目标**：在不改变产品行为或减少验证范围的前提下，尽可能由 `BaileyTests` 直接验证原生组件、数据和真实副作用；`BaileyUITests` 只保留宿主无法证明的完整 App 用户操作。减少的是重复 App 启动和测试维护成本，**不设置删减数量指标**。

## 范围与执行规则

源码基线：`Bailey` 89 个 Swift 文件；`BaileyTests` 47 个文件、549 个方法；`BaileyUITests` 17 个文件（含共享支持）、133 个 UI 方法。这是**执行前源码清点**，不是本轮运行测试的结果。

| Task | UI 基线 | 独立归属 |
| --- | ---: | --- |
| P2-T1 · Git Dialog | 21 | `GitDialogUITests.swift` |
| P2-T2 · Git Graph | 45 | `GitGraphGeometryUITests.swift` 20、`GitGraphUITests.swift` 25 |
| P2-T3 · 其它 Git | 24 | `GitChanges` 12、`GitHistory` 5、`GitIgnoreEditor` 1、`GitUncommitted` 3、`WorkspaceGit` 3 |
| P2-T4 · Files／Editor／共享树 | 24 | `WorkspaceFiles` 11、**`SharedTree` 全部 8**、`EditorNavigation` 3、`EditorHighlighting` 2 |
| P2-T5 · Workspace | 19 | `WorkspaceDock` 3、`WorkspaceRetention` 7、`WorkspaceSmoke` 1、`WorkspaceWindows` 8 |
| **合计** | **133** | 每个 UI 文件只由一个 Task 负责；跨领域的宿主类可复用 |

每个 Task 按同一顺序完成，不把清理放到 P2-T5：

1. **先逐条核对原断言与生产调用链**：用户入口 → `GitPanel`／Files／Editor／Dock／App 所有者 → 真实 Git／文件／原生组件 → 最终结果。与已有宿主测试逐项比较，区分“已经证明、宿主缺口、必须完整 App 才能证明”。不能仅因方法同名或都调用 Git 就认为等价。
2. **优先补宿主缺口**：复用现有业务测试类和真实隔离资源。直接实例化生产 `NSAlert`，或使用项目已有的最小 `NSView`／`NSHostingView`；不要复制生产逻辑、增加仅为测试而存在的协议／Coordinator、完整 `GitPanel` 假宿主或新的 Test Target。直接调用模型不等于验证菜单路由、真实键鼠与前台焦点。
3. **立即移除已替代 UI 和遗留代码**：先证明原断言全部有宿主证据；涉及独有系统入口时，还需有保留的 UI 路径。随后在**同一 Task**删除冗余 UI 方法及专用 helper／fixture／旧选择器、确认为无实际调用方的迁移兼容路径和重复代码。检查调用方、最终副作用及失败恢复后再删；不把仍可触发的保存保护、目标／Ref/OID 校验、远端隔离、原生无障碍或 Dev App 隔离当成“多余安全围栏”。没有证据就不改产品代码，不新增补丁式保护。
4. **只做受影响的验证**：新增宿主回归先核对真实触发前提，必要时 Red→Green；运行相关 `make test:类名1,类名2`。UI 文件更改后 `make build:ui` 并定点运行**仍需完整 App 的、受影响的** `make test:ui ONLY_TESTING=BaileyUITests/类名/方法名`；核对 Xcode 实际发现数、退出码和最终字节／Git 状态。阶段收口与 CI 再执行规定的全量回归，不在每次小改后全量跑 GUI。
5. **同任务更新事实文档并提交**：仅在测试职责或入口发生变化时更新 `docs/testing.md` 及受影响的 `docs/features/*.md`，移除已不存在的方法引用，不在 README 写迁移期说明。每 Task 一个可独立验收的中文提交；记录被删方法、对应宿主断言与留存 UI 的独有行为，避免另建长期看板。

**环境与不可替代边界**：宿主覆盖空值／非法名／Unicode、Git SHA-1／SHA-256、0／1／多 Remote、取消／失败／重试、Ref/OID 竞态、SSH 目标及本机文件权限、并发／容量／字号／主题等**实际适用**维度和关键组合。系统菜单／原生文件选择器、真实 App 第一响应者、跨窗 Sheet、Finder／LaunchServices 投递、WebKit/Ghostty 原生拖放、`⌘Q` 后完整重启等必须由独立 Bailey Dev E2E 验证。未具备的 macOS 15.6、授权 Windows SSH、实体触控板或中文输入法实机组合，逐项说明条件、影响和补验；不得用组件测试冒充完成。

---

<a id="p2-t1"></a>

## P2-T1 · Git Dialog（21 项）

**生产路径**：`Bailey/Git/GitPanel.swift` 的 `presentBranchCreate`、`presentTagCreate`、`presentRemoteBranchAction`、`presentCommitDialog`、`presentStashDialog` 等，将实际 `GitBranchDialog`、`GitTagDialog`、`GitCommitDialog`、`GitStashDialog`、`GitUncommittedDialog` 的选择传入 `GitStatusModel`。宿主复用 `BaileyTests/Git/GitBranchActionTests.swift`、`GitRemoteBranchActionTests.swift`、`GitTagActionTests.swift`、`GitCommitActionTests.swift`、`GitStashActionTests.swift`；PTY 已有 `BaileyTests/Remote/GitInteractiveRebaseIntegrationTests.swift`。

1. **原生表单可在宿主测**：直接构建上述生产 Dialog，检查默认 Checkout／Reset Mixed／Merge、Tag 注释／轻量类型、Stash 恢复 Index、Push 模式、0／1／多 Remote、首选 Remote 选择与取消；修改真实 `NSTextField`／`NSButton` 并触发实际 delegate／target 更新。`GitNameFieldValidator` **只禁止全空白输入**，不负责全部 Git Ref 格式：无效 Ref 被 Git 模型拒绝，不能错误要求表单按钮对所有非法名禁用。重点核对 Tag 与 Branch 的推送选择机制并不完全相同。
2. **Git 后置条件复用而不重造**：已有宿主验证 Branch／Tag 同名与多远端、Stash OID/selector、Commit Drop、Push/Fetch/Pull 等，先逐项看断言；再补实际缺口。已确认 `testRemoteFetchRejectsMovedLocalDestinationThenAllowsFreshForceAndFastForward` 的**确认期间本地目标 Ref 被外部移动、即使 Force 也不覆盖、重新确认成功**尚不能仅由现有正常／强制 Fetch 宿主用例替代；复用 `GitRemoteBranchActionTests` 对 `fetchIntoLocalBranch(_:force:destinationOID:target:)` 的真实 Git CAS 加测。检查远端另一个 bare 仓库、HEAD、index 和工作文件没有意外变化。
3. **仅剩真实用户接线**：Branch／Tag 的创建、冲突重开后表单内容保留，Stash 指定旧条目、危险 Commit 确认、Git Graph→交互 Rebase→真实 PTY、跨窗口 Sheet 都从实际剩余 UI 断言决定保留最短路径。`testCommitSheetBelongsToItsWindowWhenAnotherWorkspaceTakesFocus` 已存在实际切换第二窗口的动作，不再把它列成“尚未实现”；仍须保证该动作没有被迁移误删。不要假定 21 项全部可删。
4. 每删除一个 UI 立即检查并删除其本文件内的无消费者局部 helper；`GitPanel` 中的 Ref／窗口/项目比对属于当前可达业务保护，不能为精简测试而删除。同步 `docs/features/git.md` 中确实受影响的测试入口。

**验收**：适用的历史／当前 Branch、Tag、Stash、Commit、Remote 选择与竞态、取消、错误／恢复、真实数据和选定窗口均有宿主或必要 UI 证据；定点宿主与剩余 UI 通过，原 21 项逐个交代去向。一次提交。

<a id="p2-t2"></a>

## P2-T2 · Git Graph（45 项）

**生产路径**：`Bailey/Git/RecentCommitsView.swift`（行／菜单／轨道）、`CommitGraphLayout.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`。宿主先复用 `BaileyTests/Git/CommitGraphLayoutTests.swift`、`GitGraphPaletteTests.swift`、`GitGraphReferenceGroupTests.swift`、`GitGraphWorktreePresentationTests.swift`、`GitStatusModelTests.swift`。

1. `GitGraphGeometryUITests.verifyDivider` 有 **11 个**入口，每项按五档面板宽度重复菜单与六点 Commit 点击；`GitGraphUITests.verifyDenseGraph` 有 **5 个**入口，每项重新生成 24-lane Git 仓库并重复四次拖动。按原断言把拓扑／色位／引用组合、宽度计算、字体和标签尺寸放在上述宿主；在确实需要像素／布局时可复用已存在的最小组件宿主。
2. **不为了移植强行构建完整 Graph 假宿主**：`RecentCommitsView` 的初始化依赖大量状态和动作闭包，若要为此造一组虚拟 `GitPanel`／假动作，不如保留最少真实 App 几何 E2E。真实 Dock 分隔条、Commit 行多个命中区域、明暗切换接线、横滚时轨道不动、系统多级菜单悬停／外部刷新、33 个 Remote Ref 的实际菜单项、中文长标签与 Worktree 真实目标，必须通过能实际证明它的宿主组件或独立 App 测试，不凭纯算法推断 Native UI。
3. 复查英文 Badge／标题／节点与中文菜单测试中的共同点击；仅减重复交互，不误删中文本地化、剪贴板、真实键盘焦点和两父 Merge Diff、分页、其它工作树 Staged／Unstaged Diff 的独有入口。删除多余的主题×字号重复整套启动及其无消费的图谱 fixture/screenshot helper。
4. 同任务更新受影响的 `docs/features/git.md`／`docs/ui.md` 和测试选择入口，不挪到 P2-T5 才清理。

**验收**：0／1／12／24／30／150 车道的适用布局边界、明暗、字号极值、长中文、Worktree 共享/分离 HEAD、真实三层菜单、外部变化、横滚和实际 Git 状态不丢证据；定点宿主与必要 UI 通过，原 20+25 项逐个交代去向。一次提交。

<a id="p2-t3"></a>

## P2-T3 · 其它 Git（24 项）

**独占 UI 文件**：`GitChangesUITests.swift`（12）、`GitHistoryUITests.swift`（5）、`GitIgnoreEditorUITests.swift`（1）、`GitUncommittedUITests.swift`（3）、`WorkspaceGitUITests.swift`（3）。**不在本 Task 改 `SharedTreeUITests.swift`**，它全部归 P2-T4。

**生产／宿主 owner**：`Bailey/Git/GitPanel.swift`、`GitStatusModel.swift`、`DiffViewerView.swift`、`Bailey/Files/FileTreePanel.swift`；复用 `BaileyTests/Git/GitStatusModelTests.swift`、`GitWorkspaceActionTests.swift`、`GitUncommittedActionTests.swift`、`GitIgnoreIntegrationTests.swift`、`NativeGitHistoryFileTests.swift`、`NativeDiffTabTests.swift`。

1. 把仓库切换与旧数据拒写、真实本机事件／外部 Git 更新、Merge 冲突 Index、Staged／Unstaged、二进制／大文件／Rename 历史、Reset／Stash／Clean 失败及取消前后字节等数据矩阵交给现有宿主。**验证真实入口和副作用**；已有相同 Git 最终状态也不能自动替代 UI 的菜单操作。
2. 针对 `GitChangesUITests` 三条 Stage 路径（文件右键、目录右键、目录行尾按钮），分别检查独有的实际鼠标命中和“操作不打开文件”行为；后端目录范围可由 `GitWorkspaceActionTests` 验证。外部初始化、工作树改变和项目切换的真实 UI 刷新只保留未由其它路径证明的接线。
3. `GitHistoryUITests` 的 Revision 只读／重命名、Reset 确认前外部修改与实文件后置结果优先宿主；仅保留真正需要历史行菜单、确认 Sheet 与编辑器路由的 E2E。`GitIgnoreEditorUITests` 的 Undo／字节由原生文件宿主承接，Git 菜单→编辑器→系统 `⌘Z` 焦点若独有则保留。`GitUncommittedUITests` 区分危险 Reset／Clean／Stash 的确认语义，不将其误认为同一操作。
4. 每个删除的方法同步清理本类专用 fixture、局部选择器、无调用的旧分支；维护当前 `docs/features/git.md` 的测试入口，不新建不同的 Git 测试执行器。

**验收**：真实 HEAD/index/Ref/文件与未跟踪／忽略文件、仓库/机器切换、冲突三阶段、历史只读、危险操作取消与确认、原生文件行／菜单分别有实际证据；定点相关宿主及所需 UI。原 24 项逐个交代去向，一次提交。

<a id="p2-t4"></a>

## P2-T4 · Files／Editor／共享树（24 项）

**独占 UI 文件**：`WorkspaceFilesUITests.swift`（11）、`SharedTreeUITests.swift`（**8 项完整处理，含两项 Git 行**）、`EditorNavigationUITests.swift`（3）、`EditorHighlightingUITests.swift`（2）。共享树行逻辑同时影响 Files、Git Changes 和 Git Graph；P2-T3 只提供已有 Git 证据，不再二次编辑同一个 UI 文件。

**生产／宿主 owner**：`Bailey/Files/FileTreePanel.swift`、`FileTreeModel.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/Editor/SourceTextEditor.swift`、`SyntaxHighlightConfiguration.swift`、`Bailey/Editor/FileViewerView.swift`；复用 `BaileyTests/Files/FileTreeTests.swift`、`FileTabPersistenceTests.swift`、`BaileyTests/Editor/NativeEditorLayoutTests.swift`、`NativeEditorCompositionTests.swift`、`NativeSyntaxHighlightingTests.swift`、`BaileyTests/Workspace/DockFocusIntegrationTests.swift` 和 `FinderDeliveryIntegrationTests.swift`。

1. 文件树路径、同名文件／Tab 身份、目录压缩、异步游标、独立右侧动作的布局与真实文件复制/保存均先核对现有宿主。`SharedTreeUITests` 的长名称横滚和深浅背景可以在**生产共享树行的最小组件**里直接测时才下沉；右键不误打开、真实宽度行命中、Git Stage 行尾按钮与真实 Dock 拖动，则必须有对应的完整 App 系统行为证据。
2. `EditorNavigationUITests` 的 10k Unicode／100k ASCII 定位、Undo／Redo、TextKit 视口与原生高亮，由既有 `NativeEditorLayoutTests`／`NativeEditorCompositionTests`／`FileTabPersistenceTests` 承担适用矩阵；`NativeSyntaxHighlightingTests` 已挂载真实编辑器、检查嵌入语言颜色，不把 token 正确冒充实际像素。`EditorHighlightingUITests` 中仅保留还未由宿主证明的**完整 App 确实装配正确语法与字体**的入口；不要为此造新的截图 framework。
3. `WorkspaceFilesUITests` 的同名两个文件、重开复用标签和旧异步结果拒写先用宿主验证；系统文件选择器、剪贴板多类型恢复、真实 `⌘O`／`⌘S`、命令面板与 Files 的键盘焦点交接、长中文路径等按独有前台行为保留，不用程序调用绕过系统步骤。
4. 删除重复主题／字号／深度点击或长行测试后，同任务清理 `SharedTreeUITests` 的无用颜色／截图 helper、无消费者的文件树 fixture 与旧兼容路径；仅在现有生产功能确实不再调用时才删除相应实现。同步 `docs/features/files.md`、`editor.md` 和被改动的测试索引。

**验收**：实际行命中（目录、缩进、留白、行尾）、短/长名称与水平滚动、明暗／中英文／字号极值、10k／100k、IME/Undo/Redo、同名文件两路径、取消与保存、Finder/Picker、磁盘内容和键盘焦点都由对应实际宿主或必要 UI 证明；原 24 项逐个交代去向，一次提交。

<a id="p2-t5"></a>

## P2-T5 · Workspace（19 项）

**独占 UI 文件**：`WorkspaceDockUITests.swift`（3）、`WorkspaceRetentionUITests.swift`（7）、`WorkspaceSmokeUITests.swift`（1）、`WorkspaceWindowsUITests.swift`（8）。

**生产／宿主 owner**：`Bailey/App/WorkspaceApplication.swift`、`FinderService.swift`、`Bailey/Workspace/WorkspaceWindowModel.swift`、`DockWorkspaceModel.swift`、`SessionStore.swift`、`Bailey/UI/WorkspaceDockView.swift`、`Bailey/Terminal/TerminalHostView.swift`、`Bailey/Browser/BrowserView.swift`；复用 `BaileyTests/Workspace/DockWorkspaceTests.swift`、`DockFocusIntegrationTests.swift`、`WindowOwnershipIntegrationTests.swift`、`WindowCloseIntegrationTests.swift`、`FinderDeliveryIntegrationTests.swift`、`SessionStoreTests.swift`、`NativePaneRetentionIntegrationTests.swift` 和 `BaileyTests/Settings/AppSettingsTests.swift`。

1. Dock 选中/焦点意图、快照恢复、文件变脏时关闭、失败保存、WebKit／Ghostty 原生实例身份、设置持久化及多文件标签释放先核对已有宿主。`testFiveRoundsOfFiveRealFileTabsRetireWithoutChangingDisk` 重复五轮 `LaunchServices` 与 `⌘W`，原生文档释放已有宿主证据；**但**其真实 App 外部文件投递和窗口数是否另有独有回归，须先与 `WorkspaceWindowsUITests` 对比，不能只因为它“跑得慢”就删。
2. 真正的 `⌘P`／`⌘,`／`⌘W`／`⌘Q` 焦点、两窗口启动与系统窗口归属、Finder/LaunchServices 文件事件、原生 Picker Sheet、重启后的 App 状态、Finder→WebKit/Ghostty 拖放都需真实完整 App 路径。复核 `WorkspaceRetentionUITests` 的浏览器表单／终端 Shell 跨标签身份，宿主只能证明对象保留，不一定证明前台系统输入仍进原对象。
3. 清理与 `WorkspaceFilesUITests` 重复的“打开同一文件／关闭标签”操作；宿主覆盖组件生命周期，留存 UI 检查不同的系统事件。每个 UI 文件有唯一 Task owner；本任务不再次重写前面四项的业务测试，只核对跨任务重复覆盖。
4. 同任务清理 `WorkspaceRetentionUITests`、`WorkspaceWindowsUITests` 专用且无调用的重启／窗口辅助代码；保留当前可达的 Dev App 运行态检查、输入法／剪贴板恢复和临时文件清理（它们保护真实用户环境）。同步确实发生变化的 `docs/features/dock.md`、`session-restore.md`、`terminal.md` 和 `docs/testing.md`。

**验收**：窗口数／双窗目标、空／多文件、真实快捷键焦点、断网/保存失败／正常退出与重启、浏览器表单与 Shell 身份、外部文件投递和拖放结果有实际证据；原 19 项逐个交代去向。按 `docs/testing.md` 完成必要构建、签名、全量宿主、独立 UI CI 与不可用环境说明，一次提交。

## 阶段审计

使用项目既有 `feature_tool.py` 在 **P2 实际完成后** 创建 `audit-p2.md`，不在规划期预建另一份台账。依据本期基线 **133 项 `Class.testMethod`** 逐条追溯“保留/删除 → 同等宿主断言 → 剩余独有 UI → 真实运行证据”，核对代码中是否还存在已失去调用方的测试辅助、兼容路径及冗余执行器。报告 Xcode 实际发现的两类测试数、方法变动、完整 App 启动次数与可比耗时（仅当实测）、测试退出码、跨环境未测限制。**仅改目录、减少几个点击、无意义增加宿主测试或删掉独有系统行为都不算通过。** 保持 P1 已完成状态，不恢复 Unit／Integration 三层结构。
