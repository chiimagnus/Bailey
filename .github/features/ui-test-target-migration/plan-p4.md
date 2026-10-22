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

**Own old tests:** `BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`（7）、`BaileyTests/NativeUI/App/AppMenuIsolationTests.swift`（2）、`BaileyTests/WorkspaceUI/Windows/DockFocusP2RegressionTests.swift`（3），合计 12。

**Files/anchors:** `Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/UI/{CommandPaletteView,WorkspaceDockView,ContentView}.swift`、`Bailey/App/BaileyApp.swift` 与 `BaileyUITests/{Files,Workspace}/*UITests.swift`。

**Step 1 — 对照原始语义：**
- 树行完整命中、短文件名不弹性横滚/超长名独立横滚、右键仅打开菜单而不触发单击、单击 Files 预览/双击或 Return 打开、点击小按钮不误打开、选中底色与实际键盘焦点轮廓不同。
- Dock 空工具区点击与异组拖放不会错误激活，Palette → File Manager 跳转后用户真实键盘落入相应文件；菜单 `Open File` 快捷键及隔离 XCTest 宿主不得被普通 `⌘Q` 误退出。
- 目前 `BaileyTests` 仍借 Bailey App 宿主，即使最终只运行纯逻辑也必须先判明测试宿主菜单隔离是否仍被需要；若属于必要安全契约，由独立 Runner 的受控 App 行为或纯构建/配置检查保留等价验证，不能直接删掉第二项。

**Step 2 — 实现/清理：**
- 用独立 `XCUIApplication` 的文件树、Git Changes、Dock 真实按钮与菜单、鼠标/键盘（真实双击/上下/Space/Return/右键）逐步验证。短长 label、滚轮水平位置和焦点反馈用 AX 加相同条件截图证据。
- 稳定标识仅补真实控件需要的 AX；窗口路由以 PR #50 的 `WorkspaceWindowModel` 为准，不依赖原 `TerminalManager` 别名或 `NSWindow.sendEvent`。
- 核销 12 项后删除三个旧源类及专用 host helpers；对应 `docs/features/files.md`、`docs/features/dock.md`、`docs/features/command-palette.md`、`docs/ui.md` 测试入口及时更新。

**Step 3 — 验证：**
- 独立 GUI runner 的 Files/Git 行命中与两个方向键路径；按当前 Makefile 运行共享树行纯模型回归；菜单 `⌘Q` 隔离只在专用测试 App 上验证，确保用户现有正式 App 未受到任何操作。
- Coverage：文件夹/文件/空行、短/长名称、中英、Unicode、窄宽、浅深、多级菜单、单/双/右键、Space/Return/Escape、同组/异组、空工具区、拖动释放点、命令面板搜索/取消/切换、异常和极端点击位置。
- Uncovered：无法由 XCUITest 精确再现的触控板滑动及原生 Hover 轨迹如有缺口，按 `idea.md` 报具体原因与独立补验，不能用 `NSWindow.sendEvent` 冒充。
- **Commit boundary:** 12 项原方法逐项替代、删三旧套件和无用 mocks，同步当前功能文档。

<a id="p4-t2"></a>

## P4-T2 多窗口的实际键盘响应与焦点恢复

**Own old tests:** `BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift` 的**前 19 项**（清单 P4-T2）；仅删除已被本 task 证明替代的这些方法，保留其余部分给 P4-T3/T4。

**Files/anchors:** `Bailey/App/{WorkspaceApplication,BaileyApp}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project,DockWorkspaceModel}.swift`、`Bailey/UI/{ContentView,CommandPaletteView,WorkspaceDockView}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`；新增/扩展 `BaileyUITests/Workspace/WorkspaceFocusUITests.swift`。

**Step 1 — 原测试定位：**
- Files/Git 列表异步出现后的第一个选中行及真正焦点、切回 File Manager 时选中实际打开文件、不同 Dock 组焦点交接、Palette 早于 search field 焦点就绪时 Files/Git 不抢键盘；取消恢复原有效区域，执行命令转交目标区域。
- 文件树内改名/新建退出、Tab 前后台/编辑器焦点与 Find 搜索框、Space/Return 操作、未聚焦面板不夺取真实键盘；窗口失活/遮挡/恢复后由当前 key window 决定接收，不靠错误的 SwiftUI 选择态推测键盘目标。

**Step 2 — 实现/清理：**
- 使用 `XCUIApplication` 操作真实 windows、Dock、Files/Git 和 Palette，在每次交接后发送真实按键并核对**实际文件/选中行/正文输入**，而不是只检查 `firstResponder` 的类型；同时验证背景窗口没有变化。
- 对真正不需要绘制的作用域、项目身份、过期焦点请求/异步回调结果，保留非 UI 模型测试；如有 AX 不能代表的原生输入行为，用 P1-T4 的实证替代手段。
- 逐方法替代后删除旧 19 项和仅相关 fixture，暂不删除 `WorkspaceWindowIsolationTests.swift` 本体；同步 `docs/features/files.md`、`git.md`、`command-palette.md`、`dock.md` 中必要的验证说明。

**Step 3 — 验证：**
- 专用 GUI 会话操作两窗/三个 Dock 组、关闭/取消 Palette、同时存在 File/Terminal/Find/再切 Git 时的上下、Space/Return、文本插入结果；非 UI 层保留数据加载/身份测试。
- Coverage：空、1/1000+ 文件、深层 Git、异步延迟/取消/错误、窗口初建/激活/前后台、不同窗口焦点先后交错、File Manager 与 Git Manager、键盘快捷键连续和非法焦点动作、窄宽浅深、多语言/IME、输入期间视图重挂载；组合尽量覆盖所有可达时序。
- Uncovered：非前台专用 GUI 无法保证 AppKit key-window 时，不能将用例改为 `XCTSkip` 后报告通过；必须取得独占前台或记录 Gate 阻塞。
- **Commit boundary:** 第一组 19 项覆盖/移除与文档。

<a id="p4-t3"></a>

## P4-T3 Finder／Dock 外部文件打开和批量拖放的真实归属

**Own old tests:** `WorkspaceWindowIsolationTests.swift` **中间 17 项**（清单 P4-T3，原 `testFinderWindowDropLoadsURLProvidersIntoItsOriginalWindow` 到 `testPendingFinderDocumentsSurviveMoreThan64EventsBeforeOwnerWindowAttaches`）。

**Files/anchors:** `Bailey/App/{FinderService,WorkspaceApplication,BaileyApp}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project}.swift`、`Bailey/UI/{ContentView,WorkspaceDockView}.swift`、`Bailey/UI/Panels/ProjectsPanelView.swift`；新增 `BaileyUITests/Workspace/WorkspaceFinderUITests.swift`。

**Step 1 — 用户入口与触发前提：**
- 从 Finder / 文件打开事件 / Dock 拖到空窗口/Projects/编辑器/已有标签/异组标签栏，单文件/多文件/文件夹、真实剪贴 URL provider，项目恢复尚未附着时的外部事件；无项目不能因打开单文件隐式建项目。
- 已开文件的去重与所属窗口优先、目标组跨窗、拖动发生后立刻关闭窗口/项目、延迟 provider 返回/撤销、先后到达的 50+/64+ 事件、不同机器同名路径、SSH 项目中的本机文件归属；行为证明须从系统事件到真正 Tab/disk，而不是调用 `routeExternalFiles` 内部方法。
- 真正的 Finder 应用或 Launch Services 文件事件不是 `XCUIElement.typeText` 可以冒充的；在专用 GUI Runner 研究实际可用系统外部入口，要求检测有权的前台桌面与协议，否则安排具体人工 E2E，不能记作全部自动化。

**Step 2 — 实现/清理：**
- 用唯一临时目录、合法普通文件/符号链接/不存在路径/多文件与目录，向测试版 App 发起真实外部请求；守住唯一 Bundle ID 和前台 App 权限，不能把事件发送给用户正式 Bailey。
- 跨进程 E2E 覆盖正常投递、拖放目标和最终文件/窗口；provider 返回乱序、窗口消失、错误回调、超过 64 事件等不易模拟的逻辑隔离继续在非 UI Integration 测试中精确保留。
- 逐项验证 17 条保障并移除对应旧方法和仅服务本组的模拟 provider；不抢先删其余 `WorkspaceWindowIsolationTests`。同步 `docs/features/projects.md`、`files.md`、`dock.md` 和 `docs/testing.md` 的测试边界。

**Step 3 — 验证：**
- 专用 GUI Runner 中真实 Finder/Launch Services 与 Dock/drop 证据（自动化可执行的全部场景）；目标窗口项目、Tabs identity、最终文件/内容和错误提示；非 UI 先后事件队列、身份和时序回归分别执行。
- Coverage：0/1/多窗、项目存在/不存在、文件夹/单/多文件、符号链接与坏链接、UTF-8/非 UTF、超长路径、重复批次/64+ 排队、迟到/cancel、关闭前后与恢复中、异组、同名本机/SSH、双窗口同时外部投递、Finder 右键打开方式及 Dock 拖放可行组合。
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
- 同步 `docs/features/session-restore.md`、`dock.md`、`editor.md`、`docs/architecture.md` 和 `docs/testing.md` 的**验证归属变化**；不改变存储键/格式或原行为。

**Step 3 — 验证：**
- 专用 Runner 中通过 App 窗口菜单/关闭/重启、Sheet 和真实文件 bytes、终端历史配置验证；非 UI `SessionStoreTests`／`WorkspaceIdentityTests`／`DockWorkspaceTests` 继续检查保存状态单一性、缺失 snapshot、跨窗口错误结果。
- Coverage：0/1/多窗、干净/脏文件/保存失败/保存中新编辑、后台窗/关窗/退出并发、Shell/WebView/File/Diff 混合标签、分屏/窗口缩放/重挂载、窗口恢复队列 1/2/3+、关闭已失效 owner、缺失/损坏历史、初次/第二次启动、远端/本地同路径、重复关闭、外观主题/语言与错误/重试组合。
- Uncovered：跨进程恢复必须证明环境 suite 在重启前后完全相同；无法安全隔离普通配置或后台正式 App 时该场景阻塞，不能让 UI Runner 触及用户设置。
- **Commit boundary:** 15+2 项完整去向、旧 3 个 UI suite 和 Integration UI 方法删除、底层 SessionStore 保留、文档与验收证据。

<a id="p4-t5"></a>

## P4-T5 Terminal、Browser、编辑器原生资源、设置页

**Own old tests:** `BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`（20）。同时对 P1-T3 标记的 `AppSettingsTests.swift` 做结果核对，只有真正需要通过可见设置页验证的操作放 `BaileyUITests`，纯配置和 Observation 保留在 `BaileyTests/Integration/Settings`。

**Files/anchors:** `Bailey/Terminal/TerminalSession.swift`、`Bailey/UI/WorkspaceDockView.swift`、`Bailey/App/SettingsView.swift`、`Bailey/Editor/{FileViewerView,SourceTextEditor}.swift`、`Bailey/Workspace/{PaneTab,WorkspaceWindowModel}.swift`，Browser `WKWebView` 宿主的当前实现（沿 `docs/features/browser.md` 指向的真实代码检查）；目标 `BaileyUITests/Workspace/WorkspaceRetentionUITests.swift`、`BaileyUITests/Settings/SettingsUITests.swift` 等最少的职责分组。

**Step 1 — 旧的真实资源保障：**
- 20 项涵盖终端 surface 复用/parking/Find、Shell PID 与历史、文件标签五编辑器同时存在、10 万行加载保存释放、查看器缓存不可让旧 document 保活、编辑器重挂载/Undo/滚动、打开其他 Pane／切 Dock、Browser 地址/历史/Favicon/form 与 WebKit 对话框、Native file/SSH 选择面板、选中/取消、关闭窗口后原生资源释放。
- 另有 Settings 页面真实快捷键、外观/字号/终端配置 UI 到磁盘 TOML 和现有观察者应用，属于 App UI；`AppSettingsTests` 的纯配置读写与校验继续在非 UI Target，若测试重设 `NSApp.appearance` 则必须确认测试隔离和全局副作用。
- 原始对象引用/ARC 释放、Task/callback 到期逻辑不等于纯 UI 可观察结果；需要非 UI 注入测试守护异步资源不变量，真实 UI 再用实际 Shell/文件/浏览器操作与 Instruments/进程测量补证。

**Step 2 — 新 UI 与非 UI：**
- 在专用 CI Runner 构造终端实际输出 marker、Shell 进程、含本地可控网页的 Browser、5 个文件编辑器与 10 万行文本，按真实 Dock 操作/停车/关闭观察状态与资源释放；不得用假 Session 或页面模型直调冒充用户路径。
- 对关闭后旧 callback 的处理、窗口附着后的时序、Document 占用保护、默认配置变更污染等无视觉算法归非 UI 单元/集成；用 `XCUIApplication` 与独立 Profile 的 Settings 和原生 Sheet 验证可见结果。
- 核销全部 20 项并移除 `PaneRetentionTests.swift` 与其 AppKit-only helpers；`AppSettingsTests` 仍保留无 UI 的方法。根据实际变化更新 `docs/features/terminal.md`、`browser.md`、`dock.md`、`settings.md`、`editor.md` 和 `docs/testing.md` 的测试入口。

**Step 3 — 验证：**
- 专用 GUI Runner 完整文件/终端/Browser/Settings 用户路径；必要时 `xcrun xctrace` 或系统原生 Instruments 报告建立可比内存前后记录，非 UI 生命周期模型与 Settings 配置文件验证另跑。
- Coverage：终端/浏览器/编辑器同窗与跨窗、空/1/5/更多 Tab，窄/宽 Find、停车/重挂载、重复开关、多窗/外观/主题/中英、字符/大文件、100k 行、多编辑器语法任务、长时间持续操作和内存回落、WebKit 原生 alert/confirm、页面导航/历史、终端焦点/按键/后台输出、设置写入失败/撤销/重启恢复、窗口断开及 SSH 机器归属。
- Uncovered：设备输入／本地 WebKit 权限／SSH 实机／Instruments 观测权限若不满足，记录受阻条件、尝试、非 UI 替代证据、内存/行为影响及补验 Gate，不以轻量 smoke 测试覆盖资源释放。
- **Commit boundary:** 20 条逐项核销、真正 E2E + 无窗口的逻辑测试、旧 suite 删除、所属功能文档同步与资源证据。

---

## Phase Audit

实际执行完 P4 后生成 `audit-p4.md`。必须确认 83 条旧 UI 方法以及 `SessionStoreTests` 2 项混入的原生装配都已核销；本阶段旧 `NativeUI/WorkspaceUI` 类均被真实替代、没有留下只因 XCTest 只能访问内部对象而被静默删掉的断言。关键外部 Finder 拖放、保存否决、窗口/终端/浏览器原生身份和内存释放证据不足，标为明确阻塞而非通过。
