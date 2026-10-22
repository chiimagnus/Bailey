# Plan P4 — Files、Dock、跨窗口焦点、Finder、生命周期

**Goal:** 核销旧共享 UI/工作区测试的 **83 个方法**：`TreeRowHitTestingTests` 7、`AppMenuIsolationTests` 2、`DockFocusP2RegressionTests` 3、`WorkspaceWindowIsolationTests` 42、`WorkspaceWindowCloseTests` 6、`WorkspaceContentIdentityTests` 3、`PaneRetentionTests` 20。另处理 `SessionStoreTests` 混入的 2 项真实窗口测试，并补足现有 UI Target 对设置、终端与浏览器的界面入口。

**Non-goals:** 不再重构 PR #50 刚明确的 `WorkspaceApplication`／`WorkspaceWindowModel` 所有权；不改变 Files、Git、Dock、Finder、Terminal 或 Browser 交互、不改为第二个 Bundle ID/独立测试 App。

**Approach:** 保持 `BaileyUITests/Workspace/WorkspaceWindowsUITests.swift` 与 `Files/WorkspaceFilesUITests.swift` 的真实 App 调用方式，按来源拆成 Files/共享行、焦点、Finder、窗口保存恢复和内容身份五项任务。`WorkspaceWindowIsolationTests.swift` 原 42 项按 [方法清单](migration-inventory.md)明确三组：焦点 19（P4-T2）、Finder 17（P4-T3）、窗口/身份/快照 6（P4-T4）；各 task 替代验证完成即移走负责方法，最后一组负责删空旧文件。

**Acceptance:**
- 83 个旧方法 + `SessionStoreTests` 2 项图形装配都有不弱于原断言的 UI/逻辑双链证据；本阶段需要删除 7 个混合 UI suite 及被替代的集成 UI 方法。
- 真正用户交互证明展开/选中/悬停/展示/激活/焦点分离，文件浏览/保存或 Git 操作不会串组/串项目/串窗口；同时证明真实 Finder 事件与窗口关闭恢复的最终数据归属。
- 多个编辑器、WebKit 与 Shell 资源在移动、停车、关闭、恢复期间保持原有身份和数据；资源释放与终端历史不以 mock callback 作为唯一证据。
- 所有 XCUITest 保留当前安全隔离，场景创建/关闭不会影响正式 Bailey。

**Rules:** 受 `docs/architecture.md` 唯一所有者、`docs/ui.md` 焦点和触控、`docs/features/{files,dock,command-palette,session-restore,terminal,browser,settings}.md` 各不变量约束。不能把全局鼠标焦点操作偷偷放回宿主 Unit Test。

---

<a id="p4-t1"></a>

## P4-T1 共享树行、Dock 点击、命令面板、App 菜单

**Own old tests:** `BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`（7）、`BaileyTests/NativeUI/App/AppMenuIsolationTests.swift` 的 `testFileMenuProvidesOpenFileKeyboardShortcut`（1）、`BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift`（3），合计 **11**。 **P1 已提前核销其中 1 条**：旧伪前台 Command Palette 焦点测试改为真实 E2E 并在 `9177817` 删除；本任务尚需核销 **10** 条，原 11 条历史基线保留。该菜单类另一方法 `testTestHostHasNoQuitKeyboardEquivalent`（1）移至 **P4-T5**，因为此时仍有 T2–T5 的原生宿主测试实际使用隔离宿主 ⌘Q 保护。

**Files/anchors:** `Bailey/Shared/Tree/{TreeRowStyle,TreeDisplayModel}.swift`、`Bailey/Files/{FileTreePanel,FileTreeModel}.swift`、`Bailey/UI/{CommandPaletteView,WorkspaceDockView,ContentView}.swift`、`Bailey/App/BaileyApp.swift` 与 `BaileyUITests/{Files,Workspace}/*UITests.swift`。

**Step 1 — 对照原始语义：**
- 树行完整命中、短文件名不弹性横滚/超长名独立横滚、右键仅打开菜单而不触发单击、单击 Files 预览/双击或 Return 打开、点击小按钮不误打开、选中底色与实际键盘焦点轮廓不同。
- Dock 空工具区点击与异组拖放不会错误激活，Palette → File Manager 跳转后用户真实键盘落入相应文件；菜单 `Open File` 的真实快捷键和目标窗口正确。
- `AppMenuIsolationTests.testTestHostHasNoQuitKeyboardEquivalent` 是**仍在被消费的**原生宿主保护断言，不属于本任务删除范围：`BaileyApp.swift` 的 `if BaileyInstanceMode.isIsolated { CommandGroup(replacing: .appTermination) {} }` 必须保持原样，直到 P4-T5 清空最后宿主 GUI 测试。源码历史明确该保护是为共享桌面的 XCTest 长测试避免意外退出而加，不是可提前删的无用分支。

**Step 2 — 实现/清理：**
- 用独立 `XCUIApplication` 的文件树、Git Changes、Dock 真实按钮与菜单、鼠标/键盘（真实双击/上下/Space/Return/右键）逐步验证。Files 作为独立 Finder 接收区时，只需必要的真实复制入口证明写入目标目录、不打开 Tab、不移动源文件，复杂冲突/链接/拒绝由文件后端 Integration 承担；不复制 P4-T3 的全套跨窗投递矩阵。短长 label、滚轮水平位置和焦点反馈用 AX 加相同条件截图证据。
- 稳定标识仅补真实控件需要的 AX；窗口路由以 PR #50 的 `WorkspaceWindowModel` 为准，不依赖原 `TerminalManager` 别名或 `NSWindow.sendEvent`。
- 复核 P1 已核销的 1 项并核销剩余 10 项后删除 `TreeRowHitTestingTests.swift`、`DockFocusP2RegressionTests.swift` 两个完整旧类及其专用 helper，只从 `AppMenuIsolationTests.swift` 删除已替代的 `testFileMenuProvidesOpenFileKeyboardShortcut`；**另一 ⌘Q 用例留在同一源文件直到 P4-T5**，不要先删后无测试地保留保护。对应 `docs/features/files.md`、`docs/features/dock.md`、`docs/features/command-palette.md`、`docs/ui.md` 测试入口及时更新。

**Step 3 — 验证：**
- 独立 GUI Runner 的 Files/Git 行命中与两个方向键路径；按当前 Makefile 运行共享树行纯模型回归；验证 `⌘O` 与正确窗口。`⌘Q` 拦截和最终删旧保护归 P4-T5，避免本阶段退出尚在测试中的宿主。
- Coverage：文件夹/文件/空行、短/长名称、中英、Unicode、窄宽、浅深、多级菜单、单/双/右键、Space/Return/Escape、同组/异组、空工具区、拖动释放点、命令面板搜索/取消/切换、异常和极端点击位置。
- Uncovered：无法由 XCUITest 精确再现的触控板滑动及原生 Hover 轨迹如有缺口，按 `idea.md` 报具体原因与独立补验，不能用 `NSWindow.sendEvent` 冒充。
- **Commit boundary:** 11 项原方法逐项替代、删两个完整旧套件和菜单类中已完成的 1 个旧方法及无用 mocks；不提前删除仍有实际用途的 ⌘Q 方法/守卫，同步当前功能文档。

<a id="p4-t2"></a>

## P4-T2 多窗口的实际键盘响应与焦点恢复

**Own old tests:** `BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift` 的**前 19 项**（清单 P4-T2）；仅删除已被本 task 证明替代的这些方法，保留其余部分给 P4-T3/T4。

**Files/anchors:** `Bailey/App/{WorkspaceApplication,BaileyApp}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project,DockWorkspaceModel}.swift`、`Bailey/UI/{ContentView,CommandPaletteView,WorkspaceDockView}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`；新增/扩展 `BaileyUITests/Workspace/WorkspaceFocusUITests.swift`。

**Step 1 — 原测试定位：**
- Files/Git 列表异步出现后的第一个选中行及真正焦点、切回 File Manager 时选中实际打开文件、不同 Dock 组焦点交接、Palette 早于 search field 焦点就绪时 Files/Git 不抢键盘；取消恢复原有效区域，执行命令转交目标区域。
- 文件树内改名/新建退出、Tab 前后台/编辑器焦点与 Find 搜索框、Space/Return 操作、未聚焦面板不夺取真实键盘；窗口失活/遮挡/恢复后由当前 key window 决定接收，不靠错误的 SwiftUI 选择态推测键盘目标。

**Step 2 — 实现/清理：**
- 使用 `XCUIApplication` 操作真实 windows、Dock、Files/Git 和 Palette，在每次交接后发送真实按键并核对**实际文件/选中行/正文输入**，而不是只检查 `firstResponder` 的类型；同时验证背景窗口没有变化。
- 对无需绘制的项目身份、过期焦点请求和乱序回调保留非 UI 测试；真实第一响应者等跨进程不可读的不变量在本任务直接验证可观察的按键去向。若 AX/输入无法证明旧断言，则不能先删除该旧方法，不为此另建预研 phase。
- 逐方法替代后删除旧 19 项和仅相关 fixture，暂不删除 `WorkspaceWindowIsolationTests.swift` 本体；同步 `docs/features/files.md`、`git.md`、`command-palette.md`、`dock.md` 中必要的验证说明。

**Step 3 — 验证：**
- 专用 GUI 会话操作两窗/三个 Dock 组、关闭/取消 Palette、同时存在 File/Terminal/Find/再切 Git 时的上下、Space/Return、文本插入结果；非 UI 层保留数据加载/身份测试。
- Coverage：空、1/1000+ 文件、深层 Git、异步延迟/取消/错误、窗口初建/激活/前后台、不同窗口焦点先后交错、File Manager 与 Git Manager、键盘快捷键连续和非法焦点动作、窄宽浅深、多语言/IME、输入期间视图重挂载；组合尽量覆盖所有可达时序。
- Uncovered：非前台专用 GUI 无法保证 AppKit key-window 时，不能将用例改为 `XCTSkip` 后报告通过；必须取得独占前台或记录 Gate 阻塞。
- **Commit boundary:** 第一组 19 项覆盖/移除与文档。

<a id="p4-t3"></a>

## P4-T3 Finder／Dock 外部文件打开和批量拖放的真实归属

**Own old tests:** `WorkspaceWindowIsolationTests.swift` **中间 17 项**（清单 P4-T3，原 `testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow` 到 `testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`）。

**Files/anchors:** `Bailey/App/{FinderService,WorkspaceApplication,BaileyApp}.swift`、`Bailey/Files/{FileTreePanel,FileTreeModel}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project,LocalWorkspaceBackend}.swift`、`Bailey/UI/{ContentView,WorkspaceDockView}.swift`、`Bailey/UI/Panels/ProjectsPanelView.swift`；需要的实际拖放分别追到 `Bailey/Terminal/TerminalHostView.swift` 和 `Bailey/Browser/BrowserView.swift`。优先扩展已有 `BaileyUITests/Workspace` 的测试类，仅职责复杂时新增 `WorkspaceFinderUITests.swift`。

**Step 1 — 用户入口与触发前提：**
- **按真实事件消费方分流，避免重复测试**。本任务的 17 个旧方法只覆盖 Finder／Launch Services 经 Workspace/空 Dock 组及 Projects 面板发生的文件打开、标签复用、目录添加、批次队列与原窗口归属；真正的入口还须走到磁盘/编辑器结果，不能只测试 `DropDelegate` 返回值。Files 文件树另执行复制到目标目录且保留原源文件，Ghostty 终端另执行本机路径插入／SSH 拒绝，WKWebView 另执行网页上传；这些独立接收方的代表性真实入口由 P4-T1 或 P4-T5 接手，不在本 Finder 任务重复整套组合。
- 本任务按原 17 项核对已开文件去重、原窗口优先、目标组跨窗、拖后项目/窗口变更、延迟 provider 返回/取消、50+/64+ 队列、同名本机/SSH 与恢复中身份；大量事件时序由无原生 View 的 Integration 精确测试，GUI 只验证实际 Finder 接线与目标文件/Tab。Files 复制冲突、字节、符号链接、只读/自复制等归 P4-T1 的共享树入口与既有文件后端测试，不重复作为这 17 项的 GUI 组合。
- 真正的 Finder 应用或 Launch Services 文件事件不是 `XCUIElement.typeText` 可以冒充的；在专用 GUI Runner 研究实际可用系统外部入口，要求检测有权的前台桌面与协议，否则安排具体人工 E2E，不能记作全部自动化。

**Step 2 — 实现/清理：**
- 用唯一临时目录、合法普通文件/符号链接/不存在路径/多文件与目录，向测试版 App 发起真实外部请求；守住唯一 Bundle ID 和前台 App 权限，不能把事件发送给用户正式 Bailey。
- XCUITest 在有 GUI 权限的 Runner 覆盖正常 Finder/系统投递和本任务负责的 Workspace/Projects 目标；复杂 provider 乱序、窗口消失、错误回调、64+ 事件队列由无视图依赖的非 UI 集成测试精确覆盖，另用必要的真实 App 入口验证接线。不为复制 64 次物理拖动另建驱动框架，也不在本阶段复测 Files/Terminal/Browser 的全部接收组合。
- 逐项核销负责的 17 条旧保障，再于**同一任务**删除对应旧方法和只用于原生 UI 宿主的 provider/helper；该类其他 25 项不动，直到 P4-T2/T4 各自迁完。同步 `docs/features/projects.md`、`files.md`、`dock.md`、`terminal.md`、`browser.md` 和 `docs/testing.md` 的现行测试入口（仅更新受影响的章节）。

**Step 3 — 验证：**
- 专用 GUI Runner 中真实 Finder/Launch Services 与 Dock/drop 证据（自动化可执行的全部场景）；目标窗口项目、Tabs identity、最终文件/内容和错误提示；非 UI 先后事件队列、身份和时序回归分别执行。
- Coverage：0/1/多窗、项目存在/不存在、单/多文件/目录、Workspace/Projects/Dock 真实接收、软链接/坏链接、二进制/Unicode/超长路径、同名复用、重复与 64+ 排队、迟到/取消、关闭/恢复交错、同名本机/SSH、双窗口文件投递，以及 Finder「打开方式」与 Dock 真拖放在可执行条件下的组合；Files/Terminal/Browser 独立接收者的适用安全边界另在 P4-T1/T5 验证，不遗漏但不重复遍历。
- Uncovered：XCUITest/Runner 无法控制 Finder 或真实拖放时，逐项记录自动化权限限制/人工补验方式和阻塞项，不删掉未有等价验证的重要历史测试。
- **Commit boundary:** 17 项方法对应证据、删除旧项/无用 fixtures、非 UI 事件逻辑保留及功能文档更新。

<a id="p4-t4"></a>

## P4-T4 窗口关闭、保存否决、状态恢复与原生对象身份

**Own old tests:** `WorkspaceWindowIsolationTests.swift` **最后 6 项**（旧方法序号 20/21/39–42）、`WorkspaceWindowCloseTests.swift`（6）、`WorkspaceContentIdentityTests.swift`（3）；再加 `BaileyTests/Integration/Workspace/SessionStoreTests.swift` 中真正图形依赖的 `testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction` 和 `testClosedWindowCannotBeUsedForLateFileOperationErrors`。共 15 个旧 UI 目录方法 + 2 个混入 Integration 的 UI 方法。

**Files/anchors:** `Bailey/App/WorkspaceApplication.swift`、`Bailey/Workspace/{WorkspaceWindowModel,SessionStore,PaneTab,Project}.swift`、`Bailey/UI/{ContentView,WorkspaceDockView}.swift`；已有 `BaileyUITests/Workspace/WorkspaceWindowsUITests.swift`，新增需要的窗口/恢复 UI suites；SessionStore 非 UI 测试仍归 `BaileyTests/Integration/Workspace`。

**Step 1 — 原始不变量：**
- 窗口 root 首次/离屏装配、场景 SwiftUI 重复构造、空窗口 Sheet 在正确 Window，文件/编辑器/Diff/Browser 身份不因横纵分组/标签交替/重新挂载重建、同一文件跨组/窗不会复制可写对象。
- 脏文件关闭前保存、其它标签等待保存时新编辑、失败否决、反复关闭同窗口/关所有窗口、后台项目确认 Sheet 所属、成功后再次关闭、应用退出汇总、两应用/窗口 Owner 不能共享 registry/工作树占用身份。
- SessionStore 两项真实原生 UI: 反复 WindowRootView construction 过程中仅一次登记和同一原生 editor；窗口关后过期文件错误不能回投。保留快照 JSON/恢复队列/用户历史 key 等非 UI 断言不搬到 UI Target。

**Step 2 — 实现/清理：**
- 在真实 App 完成打开多个文件和 Diff/Browser、停靠、关闭/取消/保存失败/再次编辑，再次启动同隔离 `BAILEY_UI_TEST_RUN_ID` 验证窗口/项目/标签/文件恢复和字节正确；覆盖无项目新窗口及多组组合。
- UI E2E 断言最终窗口数量、用户视图内容与磁盘，对原生 pointer identity 无法跨进程直接观测的部分用实测内容、Undo、滚动、实际资源测量和纯归属算法不变量补证；不能声称“同样看起来”即同一对象。
- 将 `SessionStoreTests` 中 2 项涉及原生 View 的断言拆为「E2E + 非 UI」两份，删除旧窗口依赖、保留其它 8 项；前述 15 项和这 2 项核销后删除 `WorkspaceWindowIsolationTests.swift`（已由 T2/T3 清空）与 `WorkspaceWindowCloseTests.swift`、`WorkspaceContentIdentityTests.swift`，不遗留旧 host helper。
- **正常退出不等于强制终止**：此阶段还有 P4-T5 的宿主原生测试，`BaileyApp` 仍会在隔离模式拦截 `⌘Q`。先从真实窗口/项目关闭路径验证 `WorkspaceApplication.windowClosed` → `SessionStore.save`，复用**同一个** `XCUIApplication` 及原 `BAILEY_UI_TEST_RUN_ID` 验证恢复；`XCUIApplication.terminate()` 只计强制结束，不能冒充用户正常退出及 `applicationWillTerminate`。最后的正常 ⌘Q 退出→保存→重启归 P4-T5 移除旧拦截后验收，不加新测试专用保存捷径。
- 同步 `docs/features/session-restore.md`、`dock.md`、`editor.md`、`docs/architecture.md` 和 `docs/testing.md` 的**验证归属变化**；不改变存储键/格式或原行为。

**Step 3 — 验证：**
- 专用 Runner 中通过 App 窗口菜单/关闭/重启、Sheet 和真实文件 bytes、终端历史配置验证；非 UI `SessionStoreTests`／`WorkspaceIdentityTests`／`DockWorkspaceTests` 继续检查保存状态单一性、缺失 snapshot、跨窗口错误结果。
- Coverage：0/1/多窗、干净/脏文件/保存失败/保存中新编辑、后台窗/关窗/退出并发、Shell/WebView/File/Diff 混合标签、分屏/窗口缩放/重挂载、窗口恢复队列 1/2/3+、关闭已失效 owner、缺失/损坏历史、初次/第二次启动、远端/本地同路径、重复关闭、外观主题/语言与错误/重试组合。
- Uncovered：跨进程恢复必须证明环境 suite 在重启前后完全相同；无法安全隔离普通配置或后台正式 App 时该场景阻塞，不能让 UI Runner 触及用户设置。
- **Commit boundary:** 15+2 项完整去向、旧 3 个 UI suite 和 Integration UI 方法删除、底层 SessionStore 保留、文档与验收证据。

<a id="p4-t5"></a>

## P4-T5 Terminal、Browser、编辑器原生资源、设置页

**Own old tests:** `BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`（20），以及此前仍有消费者的 `BaileyTests/NativeUI/App/AppMenuIsolationTests.testTestHostHasNoQuitKeyboardEquivalent`（1），合计 **21**。P1-T3 已负责清理配置初始化的多余原生副作用；本任务只补 Settings 的真实可见 UI 结果，保留非 UI 配置/Observation 断言。

**Files/anchors:** `Bailey/Terminal/{TerminalSession,TerminalHostView,TerminalFindBar,TerminalHistory}.swift`、`Bailey/Browser/BrowserView.swift`（`BrowserTab`、`BrowserWebView`、`BrowserView`）、`Bailey/UI/WorkspaceDockView.swift`、`Bailey/UI/Panes/TabSwitcherView.swift`、`Bailey/App/{SettingsView,AppSettings,AppIdentity}.swift`、`Bailey/Editor/{FileViewerView,SourceTextEditor}.swift`、`Bailey/Workspace/{PaneTab,WorkspaceWindowModel}.swift`；优先扩展已有 UI suite，确有职责需要时再新增 `BaileyUITests/Workspace/WorkspaceRetentionUITests.swift` 与设置 UI 测试。

**Step 1 — 旧的真实资源保障：**
- 20 项涵盖终端 surface 复用/parking/Find、Shell PID/历史，TabSwitcher 暂时选择与 Escape 取消不产生副作用、五编辑器同存与 10 万行释放、旧文档缓存/Undo/滚动、Pane 移动、Browser 导航/历史/Favicon/表单和 WebKit 弹窗、Native file/SSH 选择面板、关闭后资源释放。Ghostty／Browser 的文件拖放只覆盖本域真实入口与必要结果，**不重复 P4-T3 的全部 Finder 窗口路由组合**；无需把与这些测试无关的 Bark 实际远端推送、长期隧道创建或第三方服务成本纳入此次 UI 迁移，它们由现有安全/集成测试负责。
- Settings 当前 `⌘,` 只读入口已有独立 UI Test；真正修改偏好写入 `AppIdentity.configDirectory = homeDirectoryForCurrentUser/.config/bailey`，而非文档的 `.config/Bailey`。本机实测仅改 `HOME` 不改变 Foundation 用户主目录；**修改偏好的 App UI Test 只在隔离 CI 登录用户运行，先确认配置/UserDefaults/钥匙串归属**，不额外开发测试配置注入。`AppSettingsTests` 五个方法构造时都曾写 `NSApp.appearance`（不是只有显式访问的两项）；其不必要的初始化/测试副作用已归 P1-T3 提前清理。本任务核验实际主题、字号、保存和重启结果，而不重复重构配置逻辑。
- `AppMenuIsolationTests.testTestHostHasNoQuitKeyboardEquivalent` 原来保护 NativeUI 长时间占用共享桌面的 XCTest 免受 `⌘Q` 误退出；此时才能确认原生宿主 GUI 用例全部删除，再检查独立 CI UI Runner 是否需要屏蔽退出。若无消费者，**同任务同时删除这条原生测试和 `BaileyApp.swift` 仅为测试宿主存在的 `CommandGroup(replacing: .appTermination) {}`**，并在专用 UI Runner 验证正常 ⌘Q、`applicationWillTerminate` 的持久化、脏文件退出否决及同 `BAILEY_UI_TEST_RUN_ID` 重启后的数据恢复；这是 P4-T4 不能以强制终止冒充正常退出所缺的最后一段链路。保留整个 `BaileyInstanceMode` 的真实快照/历史/隧道隔离。
- 原始对象引用/ARC 释放、Task/callback 到期逻辑不等于纯 UI 可观察结果；需要非 UI 注入测试守护异步资源不变量，真实 UI 再用实际 Shell/文件/浏览器操作与 Instruments/进程测量补证。

**Step 2 — 新 UI 与非 UI：**
- 专用 CI Runner 构造真实 Shell marker、可控网页、5 个编辑器和 10 万行内容，经 Dock 停车/重挂载/关闭/重开观察内容与资源释放；**保留 `docs/testing.md` 五轮各五个编辑器、两轮宿主销毁、旧 `NSScrollView` 持有、`Close Files`/关闭项目等真实压力和生命周期触发条件**。旧测试能直接检查原生视图/文件弱引用归零，XCUITest 却不能跨进程读取这些指针；改以可纯化的资源所有权断言与真实 App 的 Instruments Allocations/生命周期及 heap 证据联合证明，**不能把内存总量回落自动等同于原逐对象析构断言**。不能证实的具体弱引用/文档缓存不变量保留为 No-Go，不新增私有测试反射通道。
- 关闭后旧 callback、窗口附着时序、Document 占用保护等可从数据不变量验证的部分留在非 UI 单元/集成；Settings 通过独立 CI 用户的真实 `XCUIApplication` 与 TOML 结果证明，若不能隔离偏好则只验证现有只读 Settings 打开，不修改真实用户配置。
- 21 项逐方法核销后同任务移除 `PaneRetentionTests.swift`、此前留下的 `AppMenuIsolationTests.swift` 与它们独占的 `NSHostingView`/Shell parking fixtures（仍被生产或非 UI 测试消费的逻辑不得删除）；保留已纯化的 `AppSettingsTests`。P1-T3 已负责改正 `AppSettings.swift` 和 `docs/features/settings.md`／`tunnels.md` 的大小写旧路径；本任务只复核 `docs/testing.md` 的 HOME 隔离说明及真实测试结果，并同步 `terminal.md`、`browser.md`、`dock.md`、`editor.md`、`docs/development.md` 的活跃测试入口。**本任务清空最后旧 UI suite 时**，核对 `AGENTS.md`、`CONTRIBUTING.md`、`.github/PULL_REQUEST_TEMPLATE.md` 及所有活跃文档的最终两个 Target 命名，不能把这项旧路清理推到 P5。

**Step 3 — 验证：**
- 专用 GUI Runner 的文件/终端/Browser/Settings 用户路径；本旧 suite 实际验证原生对象释放，按已有 `docs/testing.md` 必须保留可比较的打开/峰值/关闭后稳定 heap 与 Instruments Allocations 等证据（无可用环境则列为 No-Go），并核对保留在非 UI 的原生生命周期不变量。普通无资源变更的 UI 用例不用机械跑 Instruments。
- Coverage：终端/浏览器/编辑器同窗与跨窗、空/1/5 Tab 及五轮每轮五编辑器、100k 行/旧 5 MiB 限制边界、两轮销毁释放和旧 scroll view、窄/宽 Find、停车/重挂载、重复开关、多窗/浅深/中英、Unicode/大文件、多语法任务和内存回落、WebKit alert/confirm/导航历史、Shell PID/焦点/后台输出、设置失败/撤销/重启恢复、窗口断开及获准 SSH 机器归属。
- Uncovered：设备输入／本地 WebKit 权限／SSH 实机／Instruments 观测权限若不满足，记录受阻条件、尝试、非 UI 替代证据、内存/行为影响及补验 Gate，不以轻量 smoke 测试覆盖资源释放。
- **Commit boundary:** 21 条逐项核销、真正 E2E + 无窗口的逻辑测试、最后两份旧 suite 与孤立 ⌘Q 守卫同步删除、所属功能文档与资源证据。

---

## Phase Audit

实际执行完 P4 后生成 `audit-p4.md`。必须确认 83 条旧 UI 方法以及 `SessionStoreTests` 2 项混入的原生装配都已核销；本阶段旧 `NativeUI/WorkspaceUI` 类均被真实替代、没有留下只因 XCTest 只能访问内部对象而被静默删掉的断言。关键外部 Finder 拖放、保存否决、窗口/终端/浏览器原生身份和内存释放证据不足，标为明确阻塞而非通过。
