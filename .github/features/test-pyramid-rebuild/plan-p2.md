# P2 · 最大限度将 UI E2E 转交宿主测试

**Goal:** 不是少点几次鼠标，而是让 `BaileyTests` 直接证明尽可能多的原 UI 断言，真正减少 `BaileyUITests` 的完整 App 启动。仅保留无法由宿主证明的系统级用户操作。**不设置数量配额**，但只改步骤而不删除可替代的 E2E，不算本阶段完成。

**已核对基线（当前源码，而非执行结果）**

| Task | 旧 UI 方法 | 对应文件 |
| --- | ---: | --- |
| P2-T1 Git Dialog | 21 | `GitDialogUITests.swift` |
| P2-T2 Git Graph | 45 | `GitGraphGeometryUITests.swift`（20）、`GitGraphUITests.swift`（25） |
| P2-T3 其它 Git | 26 | `GitChanges`（12）、`GitHistory`（5）、`GitIgnoreEditor`（1）、`GitUncommitted`（3）、`WorkspaceGit`（3）、`SharedTree` 中 Git 两项 |
| P2-T4 Files／Editor | 22 | `WorkspaceFiles`（11）、`SharedTree` 其余六项、`EditorNavigation`（3）、`EditorHighlighting`（2） |
| P2-T5 Workspace | 19 | `WorkspaceDock`（3）、`WorkspaceRetention`（7）、`WorkspaceSmoke`（1）、`WorkspaceWindows`（8） |
| **合计** | **133** | 现有 16 个 UI suite；`BaileyTests` 已有 549 项宿主测试 |

**唯一分类是宿主与完整 App UI**。宿主可以是真实 Git／文件／进程、直接构建生产 `NSAlert`、挂载最小 `NSHostingView`／`NSWindow`、读取原生颜色／TextKit 状态，不因用了 AppKit 就算 E2E。已有宿主类按业务复用，不再新建 Unit／Integration 目录、Target 或专用测试 App。

## 通用执行与删除门槛

1. **逐方法读原始断言**：记录触发前提、真实 UI 入口、输入／设置、取消／确认、最终磁盘字节或 Git index／HEAD／Ref／OID／窗口归属；标记哪些属于可由宿主直接证明的规则、组件交互和真实系统效果，哪些确实依赖完整 App。测试名带有 Native、Graph、Menu、Theme、Diff、Focus 不能成为自动保留理由。
2. **宿主优先实际验证**：已有同等断言就复用；缺失时在原有 `BaileyTests/<领域>/` owner 补测。生产组件可直接构造，最小 SwiftUI／AppKit 表面可单独挂载；真实 Git／文件测试使用隔离的临时资源。不复制被测实现、不造 Mock Git／生产测试后门，不把受控后端假装是真实 SSH 或磁盘。
3. **真正删除 UI 重复**：全部断言能由宿主证明的方法直接删；混合方法把可验证部分下沉，保留最短的**独有完整 App**用户链；若这条链已由别的 UI 用例守住，再删整个方法。每次同时清理专用 fixture/helper、失效选择器和不再调用的代码，不合并成一条巨型 E2E，也不使用 `XCTSkip` 或降低断言强度。
4. **按任务定点验收**：`make test:类名1,类名2` 先运行所有受影响宿主类；真实 App 行为确实变化时才用 `make test:ui ONLY_TESTING=BaileyUITests/类名/方法名` 运行相关剩余路径，确认非零发现数、零失败、退出码。`make build:ui` 用于仅需编译 UI Target 的任务；不因一次代码移动重复跑 133 项 GUI。最后按 `docs/testing.md` 完成必要的构建、签名、完整宿主和 CI 验收。
5. **留痕但不造第二套清单**：`audit-p2.md` 最终以当前 133 个 `Class.testMethod` 为键，逐项列保留／删除、原有独有断言、确切宿主替代、剩余用户入口、执行证据及未测边界。比较前后实际 UI 方法数、启动／重复 Git fixture 次数和可比耗时（测到才报告）。每任务在自身验收后提交一个原子代码提交，不把本期过程写入 README 或长期规范。

**不能由宿主冒充的行为**包括系统菜单与文件选择器真实路由、当前 App 作为前台接收的键盘／鼠标、跨窗口第一响应者／Sheet 归属、系统 Finder／LaunchServices／拖放交接、独立 App 的退出／重启；原生组件本身的状态、像素、默认值与数据保护则应尽量先由宿主证明。是否保留以**真实断言与执行路径**判定，不以先验白名单固定保留数量。

---

<a id="p2-t1"></a>

## P2-T1 Git Dialog：直接验证原生表单与真实 Git

**源码与宿主 owner**

- 生产 `Bailey/Git/GitBranchDialog.swift`、`GitTagDialog.swift`、`GitCommitDialog.swift`、`GitStashDialog.swift`、`GitUncommittedDialog.swift` 可直接实例化 `NSAlert` 及实际 `NSButton`／`NSTextField`／delegate／target。
- 已有 `BaileyTests/Git/GitBranchActionTests.swift`、`GitRemoteBranchActionTests.swift`、`GitTagActionTests.swift`、`GitCommitActionTests.swift`、`GitStashActionTests.swift`、`GitStatusModelTests.swift` 和 `BaileyTests/Remote/GitInteractiveRebaseIntegrationTests.swift` 真实验证 Ref、远端、Stash 和 PTY。新增内容仅补已有类没覆盖的确切缺口。

**步骤**

1. 将 21 项 UI 的表单选项、按钮启停、有效／无效／中文名称、默认 checkout／Reset Mixed／Merge／Tag 注释、Stash Index 以及 0／1／多 remote 选择转交生产 `NSAlert` 的宿主测试。**真实触发**现有校验器和状态联动，不写一份假的表单逻辑；覆盖创建／重命名／删除／推送／远端检出、Checkout／Cherry-pick／Revert／Merge／Rebase／Reset／Drop／Stash 选项。
2. 所有 Git 结果用已有真实隔离仓库和 bare remotes：旧 Ref／OID 在确认前移动（含 Force 和确认重试）、历史分支与 Tag 重名、Stash selector 漂移／同 OID 不同条目、Push 只到所选 remote、Fetch/Pull／删除／恢复等。明确补齐目前缺的 **旧 Fetch 本地目标被外部移动后拒写与重新确认** 等后端合同，再考虑删除其 UI 长流程。所有失败均核对 HEAD、index、working bytes、Ref 和另一个远端没有被改写。
3. 逐条优先核销 `testCurrentBranchNativeSheetDefaultsToCheckoutAndPreservesGitBytes`、`testStashNativeApplyDropAndBranchUseSelectedOlderEntry`、`testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory`、`testTagPushWithoutRemoteCannotSubmitOrWriteRepository`、`testBranchDeleteDefaultsPreserveRemoteAndCancelIsNoOp`、`testRemoteFetchRejectsMovedLocalDestinationThenAllowsFreshForceAndFastForward`；随后检查剩余 Push／Delete／Checkout／Stash 用例的每一个表单／后端矩阵，能在宿主完整验证就删，不仅局限于六条候选。
4. 真实菜单→Sheet→用户决定→选定仓库的路径仅保留必要的不同系统入口：历史 Branch／Tag、危险 Commit Drop、旧 Stash Pop、真实交互 Rebase 终端、跨窗口 Sheet 及经系统菜单选择实际 remote。`testCommitSheetBelongsToItsWindowWhenAnotherWorkspaceTakesFocus` 必须**真正激活第二窗口**后核对仍属于原窗口，而不能只创建第二个窗口。Branch 和 Tag 旧确认各自的唯一回填行为如果宿主无法证明，必须保留对应的真实 App 路径。

**验证与完成**：定点运行上述已有／新增宿主类及实际改到的 `GitDialogUITests` 方法，核对空／非法／Unicode、取消／失败／重试、多个 bare remote、Ref/OID 竞态、SSH 机器隔离的适用条件。报告原 21 项的逐方法去向、真正删掉的启动与 helper；一条原子提交。

<a id="p2-t2"></a>

## P2-T2 Git Graph：算法、原生绘制尽量在宿主完成

**源码与宿主 owner**：`Bailey/Git/RecentCommitsView.swift`、`CommitGraphLayout.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`；已有 `BaileyTests/Git/CommitGraphLayoutTests.swift`（车道拓扑／宽度）、`GitGraphPaletteTests.swift`、`GitGraphReferenceGroupTests.swift`、`GitGraphWorktreePresentationTests.swift`、`GitStatusModelTests.swift`（真实仓库／Worktree）。

**步骤**

1. `GitGraphGeometryUITests.verifyDivider` 被 **11 个** UI 方法调用：每例五次拖动，每档打开菜单并点击六个 Commit 命中点。将宽度／字号／多 Worktree／长中文／压缩 Badge／颜色几何等确定性矩阵移至已有宿主；确需原生帧、像素或 Accessibility 时，**优先尝试只挂载生产 `RecentCommitsView`／`TreeRowSurface` 的最小 `NSHostingView`**，不启动 Bailey App。原生滚动与菜单层级若确实无法在最小宿主验证，留一次对应真实 UI。
2. 最窄 150pt 真实 Commit 行**六处命中**保留一条完整 App 闭环，另用最少的真实 Dock 拖动确认分隔条连接；不要在每种主题／字号／Worktree 组合重新点六次。实际明暗位图像素、Tree/List 选中／焦点背景、Worktree 未关联图标的原生渲染优先宿主，剩余仅检查 App 主题／设置是否正确接线。
3. `GitGraphUITests.verifyDenseGraph` 被 **5 个** UI 方法调用，每项新建 24 lane 并四次横滚／拖动。拓扑／颜色／远端 33 Ref、30／150 lanes、5,000 commits 与空仓库由已有宿主验证，原生组件宽度若可单独挂载也交宿主；UI 只需一条真实密集图谱可见／水平滚动／轨道固定的连接验证。
4. 将英文 Badge／标题／Node／空白区域点击与中文菜单中的重复操作分开：中文路径保留其独有本地化／剪贴板，不再复做全部英文点击。`testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit` 与 Geometry 六点实际比较断言后只留互不重复的 App 合同。
5. 逐项核对原 45 个方法中的真实不可下沉部分：两父 Merge 历史 Diff、分页加载与滚动触发、三层 Worktree／Overflow 原生菜单、用户真正点中的工作树文件、系统键盘焦点、长行横滚、跨组 Diff 与实际路径。能由宿主＋已保留 UI 共同证明时删除旧完整 App 测试及截图／专用仓库生成 helper；不能证明的系统悬停／菜单存活仍保留，不拿静态菜单结构冒充系统交互。

**验证与完成**：定点运行上述宿主类及真的受影响的 `GitGraphUITests`／`GitGraphGeometryUITests`；核对 0／1／12／24／30／150 lanes、中文长标签、最小／最大字号、明暗、Worktree 独立 HEAD、首次与分页、失败缓存、真实多级菜单和图谱颜色。报告 20+25 项的去向、删除的 24-lane 仓库初始化和六点点击次数；一条原子提交。

<a id="p2-t3"></a>

## P2-T3 其它 Git：把文件与 Git 结果从完整 App 移走

**范围（26 项）**：`GitChangesUITests`（12）、`GitHistoryUITests`（5）、`GitIgnoreEditorUITests`（1）、`GitUncommittedUITests`（3）、`WorkspaceGitUITests`（3），以及 `SharedTreeUITests` 的两项 Git 行 Stage／横滚。

**宿主 owner**：`BaileyTests/Git/GitStatusModelTests.swift`、`GitWorkspaceActionTests.swift`、`GitUncommittedActionTests.swift`、`GitIgnoreIntegrationTests.swift`、`NativeGitHistoryFileTests.swift`、`NativeDiffTabTests.swift`，以及 `BaileyTests/Files/FileTreeTests.swift`。

**步骤**

1. 把 Git Status、index/HEAD、外部创建仓库与刷新、Merge 冲突、Staged／Unstaged Diff、Rename/Copy、历史 revision／二进制／超大文件、过期确认拒写和 Stash／Reset／Clean 的失败恢复尽量转交真实宿主 Git 与文件测试；确有缺口才在原有 owner 加一个真实边界回归，而不是复制整个 GUI Git fixture。
2. 单独验证共享树行的横滚、目录 Stage 右侧按钮的独立命中及选中目录范围：模型路径、视觉尺寸可在 `TreeRowSurface`／最小原生宿主证明；**不同入口的系统命中**（inline、目录右键、文件右键）只保留实际无法在宿主证明的最小完整 App 路径，不把它们直接视为同一按钮。
3. 对 `GitChangesUITests` 中外部刷新和项目切换、`GitHistoryUITests` 中只读版本／Rename／Reset、`GitUncommittedUITests` 中危险操作确认逐方法拆分：后端结果由宿主，UI 最少保留真实用户菜单／确认／异常提示／焦点与最终 Git 文件的接线。`GitIgnoreEditorUITests` 的原生 Undo 和写盘可由真实编辑组件宿主证明，只有 Git 菜单→编辑器／实际快捷键是必须保留的完整 App 行为。
4. 删除被宿主证明且没有唯一 App 入口的 UI；清理重复 Git 初始化、未使用的测试 helper 和无消费的菜单选择器，不弱化任何 index/ref/文件断言。

**验证与完成**：上述宿主类与实际改到的 Git UI 类定点运行；覆盖工作区／暂存区、旧分支／仓库、冲突与权限、跨机器目标、取消／确认、目录内外文件和中文／特殊路径。记录 26 项逐方法去向；一条原子提交。

<a id="p2-t4"></a>

## P2-T4 Files／Editor：让原生组件承担渲染与大文件验证

**范围（22 项）**：`WorkspaceFilesUITests`（11）、`SharedTreeUITests` 中其余六项、`EditorNavigationUITests`（3）、`EditorHighlightingUITests`（2）。

**宿主 owner**：`BaileyTests/Files/FileTreeTests.swift`、`FileTabPersistenceTests.swift`；`BaileyTests/Editor/NativeEditorLayoutTests.swift`、`NativeEditorCompositionTests.swift`、`NativeSyntaxHighlightingTests.swift`、`TextCoordinateIndexTests.swift`；`BaileyTests/Workspace/DockFocusIntegrationTests.swift`、`FinderDeliveryIntegrationTests.swift`。

**步骤**

1. 路径／同名身份、树行压缩、长名称横滚、选择后不额外打开、文件读写／拒写、异步加载与失败恢复交给宿主模型与真实临时文件。以最小原生树行检查命中、选中底色与 Accessibility；不用每个深浅／中英文组合重新启动 App。
2. Swift、Markdown、TSX、HTML、CSS 和纯文本的 token、真实 sRGB 着色／行号、TextKit 2 视口、IME/Undo/Redo、10k Unicode 与 100k ASCII 资源边界，优先复用**实际生产 NSTextView／SyntaxHighlighting 的宿主组件测试**；当前 `EditorHighlightingUITests` 的“完整 App 是否确实挂载了高亮组件”仅保留有独有接线断言的最小路径。不能把 token 列表等同于真实屏幕像素。
3. `WorkspaceFilesUITests` 的同名文件分别保存、重复打开复用 Tab 和脏文件关闭，可从宿主 FileTab/Workspace 证明大多数数据边界；仍需要完整 App 的 `⌘O` 系统 Picker／Clipboard 恢复、Files 焦点与快捷键、实际前台 `⌘S`、长中文 Picker、系统菜单入口才保留最少 E2E。
4. `SharedTreeUITests` 的 Tree/List 共享组件、行尾动作和 Files/Graph 重复全宽命中先查已有宿主与 P2-T2／T3 保留的 App 路径；跨 Feature 重复者只留一处，不制造一轮新的交叉测试矩阵。

**验证与完成**：受影响宿主类和真实独有 Files／Editor GUI 定点运行。核对中文路径／输入法、10k／100k、CRLF、Undo/Redo、保存前后字节、同名两路径、深浅/字体/窄宽、Picker 取消与系统键盘焦点、不同窗口的文件归属；记录 22 项去向与系统能力缺口。一个原子提交。

<a id="p2-t5"></a>

## P2-T5 Workspace：宿主生命周期与最小系统级用户闭环

**范围（19 项）**：`WorkspaceDockUITests`（3）、`WorkspaceRetentionUITests`（7）、`WorkspaceSmokeUITests`（1）、`WorkspaceWindowsUITests`（8）。

**宿主 owner**：`BaileyTests/Workspace/DockWorkspaceTests.swift`、`DockFocusIntegrationTests.swift`、`WindowOwnershipIntegrationTests.swift`、`WindowCloseIntegrationTests.swift`、`FinderDeliveryIntegrationTests.swift`、`SessionStoreTests.swift`、`NativePaneRetentionIntegrationTests.swift`、`BaileyTests/Settings/AppSettingsTests.swift`。

**步骤**

1. Dock 布局／活动组、窗口身份／取消关闭、Finder 文件队列、SessionStore 快照、设置读写、原生编辑器释放与 WebKit／Ghostty/PTY 挂载身份，在现有宿主模型、真实临时文件和最小组件中验证完整异常与状态矩阵。`testFiveRoundsOfFiveRealFileTabsRetireWithoutChangingDisk` 的重复切换／内存生命周期应优先由宿主弱引用与真实文件覆盖，不靠整套 App 的 25 次循环。
2. 按方法核对完整 App 独有行为：冷启动和 Palette 焦点；系统 `⌘,` Settings 菜单、Theme 真正重启；双窗口实际 key window 与焦点交接；Finder／LaunchServices 的真实文件事件；`⌘Q` 保存否决与重启恢复；系统 Finder→WebKit 文件上传和 Finder→Ghostty 粘贴但不回车。真正属于这类的 E2E 必须保留，不能用创建两个 `NSWindow` 或直接调用 API 冒充系统动作。
3. 对不同 Workspace UI 方法反复演示的文件 Tab 保存、同路径路由、窗口空状态或编辑器资源释放，先核对 `NativePaneRetentionIntegrationTests`／`WindowOwnershipIntegrationTests` 的实际原生结果，再删无独有 App 接线的重复方法和 5 轮夹具。跨窗口安全、第一响应者和窗口重启的实际用户证据仍要存在。
4. 完成后从 Xcode 实际枚举本次全部宿主与 UI 测试；核对原 133 项的删除／保留映射和无效选择器，统一更新因用例变化而过时的 `docs/testing.md` 选测表及真正受影响的 Feature 验证入口。收尾构建、签名、本地/CI 的完整验收按现行规范分别执行，UI 的本机图形会话测试不与用户正在输入的桌面抢焦点。

**验证与完成**：受影响的 Workspace／Settings 宿主类与必要真实 UI 定点通过，报告 19 项逐方法去向与完整 133 项的最终审计。明确设置、Finder、中文/英文、浅深、窗口数、保存失败／退出／重启、五标签资源与 WebKit/Ghostty 的可执行范围；真实 macOS 15.6、实体触控板、获授权 SSH 等条件缺位时逐项记录影响。一个原子提交。

## Phase Audit

`audit-p2.md` 对原 133 项逐一核销。**先让宿主承担原 UI 断言，再删重复 E2E**；没有真实方法／启动次数减少、或丢掉唯一系统用户路径与数据完整性保护，均不得标记 P2 完成。P1 已完成的目录迁移不重新做，不回到 Unit／Integration 三层比例。
