# Plan P1 — 固定迁移证据与安全测试边界

**Goal:** 把 329 条旧 UI 保障、306 条现存非 UI 保障和原有 10 条 XCUITest 纳入可核销基线；先验证真实 App 测试能安全、可重复地执行，再允许任何旧测试删除。

**Non-goals:** 本阶段不为了“目录变干净”提前删 NativeUI／WorkspaceUI；不迁移具体编辑器、Git 或工作区功能，不改变正式 Bailey 用户行为。

**Approach:** 以源码、`Bailey.xcodeproj`、两个 Scheme、`Makefile`、CI 和 `docs/testing.md` 为依据，逐方法核对测试当前证明了什么。只用现有 `XCUIApplication` 和隔离参数；对于不能跨进程观测的内部信息，先做小规模可行性试验并记录可验证边界，再把迁移责任交给 P2–P4。

**Acceptance:**
- `migration-inventory.md` 逐方法覆盖 329 条（23 个旧 suite）、对另 306 条作目录内审查、列出既有 10 条 E2E；同名冲突与动态发现差异均核实。
- 每条旧保障都被判为「UI」、「非 UI」或「两者拆分」，关联负责 task、最终可观察结果和拟保留的模型不变量；分类有旧断言事实，不以文件名猜测。
- 独立 App 测试的启动、文件选择器、Git fixture、AX、teardown、安全检查可以由专属 GUI Runner 真实验证；失败留证，不用跳过或任意等待掩盖。
- AppKit 专属输入、渲染、焦点、对象身份和跨进程恢复有已实证可行的验收方式或明确未解阻塞，不能宣称 XCUITest 天然一比一替代所有原生断言。

**Rules:** 不终止／重启现用正式 App；CI 上运行 App 同 Bundle ID 只能在专用 Runner；每条迁移链的旧用例在对应新覆盖验证完成前必须保留。仅修改需要证明的测试基础设施，不引入新产品级测试后门。

---

<a id="p1-t1"></a>

## P1-T1 核销源测试集合与全部断言归属

**Files:** `BaileyTests/{Unit,Integration,NativeUI,WorkspaceUI}/**/*Tests.swift`、`BaileyUITests/**/*Tests.swift`；更新 `migration-inventory.md`（计划内证据）。以 `Bailey.xcodeproj/project.pbxproj` 的实际目标成员与 `Bailey.xcscheme`／`Bailey-UI.xcscheme` 的测试发现为准。

**Step 1 — 枚举与源事实：**
- 重新枚举所有目录、测试类、`func test*`，并检查测试 target 实际运行发现列表、重复命名、Swift Testing `@Test`、跳过／禁用标志，记录二者差异。当前静态参照为 NativeUI 275、WorkspaceUI 54、Unit 75、Integration 231、UITests 10；不可把静态数直接称作已执行数。
- **逐方法**阅读 329 条原用例的真实 arrange／act／assert 和共用 fixture，登记「真实触发条件 → 旧断言 → 目标不变量 → 最终观察 → 目标 task」。核查相同语义由不同方法重复覆盖还是有不同异常维度；允许多个旧方法映射一个更强的 E2E，但要逐行注明被保留的边界。
- 审查原有 10 条 UI 方法的断言强度与前置条件，不因它们位于 UI Target 就默认满足同名旧保障。
- 在 `migration-inventory.md` 每个旧方法的执行证据位置注明最终分类与后续替代用例；方法删除前必须补齐方法级链接／验收证据，不能仅填目标目录。

**Step 2 — 路径与阶段核对：**
- 按已知调用路径追查 `SourceTextEditor`／`NativeCodeTextView`、`FileViewerView`／`PaneTab`、`DiffViewerView`、`GitPanel`／`RecentCommitsView`、`TreeRowStyle`、`WorkspaceWindowModel`／`WorkspaceApplication` 与 Finder／Settings／SessionStore。确认 UI 局部内部状态属于被测产品，非 UI 字节、算法与后端可以直接由 `BaileyTests` 验证。
- 查整个 `BaileyTests` 的隐藏 UI 装配（参见 P1-T3），新需求影响前述数量时同步更新清单与任务负责范围。

**Step 3 — 验证与门槛：**
- 在本机仅执行只读源码清点／Xcode 测试枚举，不启动 XCUITest；必要时用脚本比较「旧完整类.方法集合」与本清单行集合，必须 0 缺失、0 重复、0 无 task；核查原有 10 条与 Xcode target 发现值。
- Coverage：各业务模块中的正常／错误／取消／重复／晚到、长输入／空输入以及专用 fixture 是否确实触发；至少记录每一方法受测状态与可触达的后果。
- Uncovered：静态审查不能证明真实界面，P1-T2 后获取 GUI 证据；最低 15.6 与硬件输入证据按 `idea.md` 的补验条件单独登记。
- 本 task 是基线证据，不删产品／测试源码；对照结果与方法映射作为交付，不伪造 Red／Green 或产品构建。

<a id="p1-t2"></a>

## P1-T2 稳定独立 UI Runner 和现有十条真实路径

**Files:** `BaileyUITests/Support/WorkspaceUITestSupport.swift`、现有 `BaileyUITests/{Files,Git,Workspace}/*UITests.swift`、`Bailey/Workspace/SessionStore.swift`、`Bailey/App/BaileyApp.swift`；需要时仅调整 `Bailey.xcodeproj`、`Bailey-UI.xcscheme` 和 `Makefile` 的真实执行入口。测试规范触发时同步 `docs/testing.md`、CI 约束触发时同步 `docs/release.md`。

**Step 1 — 先复现实证问题：**
- 在有专用 GUI 的隔离 CI Runner 上执行现有 10 条（逐条和全组），明确 `XCUIApplication.launch`、teardown、macOS 原生 Open/Add Panel、Go to Folder、Finder／AX 查询、Git fixture branch／history、焦点恢复、窗口数量、Cmd-S 磁盘字节、Cmd-O 同文件去重的实测结果。过往 “OpenPanel 按钮命中 Touch Bar”“AX 绝对路径超过 128”“Graph 未找到提交”是排查线索，不预判最新 `main` 已修好。
- 阅读 `WorkspaceUITestSupport.choose/addFolder/fileRow/fileTab` 与生产 `WindowRootView`、`WorkspaceDockView`、`TreeRowStyle` 的真实可达链。定位失败是运行器前提、文件选择器、AX 可访问性、夹具仓库未激活还是产品问题；任何新失败须先复现并归责，不先加 `sleep`。

**Step 2 — 最小改动与保持：**
- 保留 `make test:ui` 的 `pgrep -x bailey` 防护，启动仅使用真实 App 与当前隔离标志；测试里的 `defer`／`addTeardownBlock` 负责关闭**本次测试持有**的 App 和临时文件，不允许误杀正式 Bailey。构建用 `make build:ui`，本机存在 Bailey 时不启动 UI 自动化。
- 用已有 `XCUIElement`/稳定 AX ID、真实菜单／键盘／文件选择器；必要时修复产品控件的**真实无障碍语义**，不添加隐形测试按钮、模型直通通道或额外测试 Bundle ID。
- 先验证 `--isolated-ui-test` 和 `BAILEY_UI_TEST_RUN_ID` 对快照、历史、隧道的隔离范围；测试会改变普通设置时在专用 HOME／账户、真实配置路径下先证明隔离生效，否则拒绝执行该测试，不得污染用户全局配置。
- Git／文件／重启 fixture 均设唯一临时目录和可证明的状态，取消、异常、重新启动和 TestCase 失败必须清理属于自己的产物。错误抓取 App 层级、截图、最终磁盘/Git 状态而非把错误跳过。

**Step 3 — 验证：**
- Build（不会启动）：`make build:ui SIGNING=adhoc DERIVED_DATA=build/DerivedData-<独占任务名>`；GUI（专用 Runner）：`make test:ui SIGNING=adhoc`，单例隔离以及逐类 `-only-testing:BaileyUITests/<类名>` 的实际运行、失败与 0 skipped 均记录。两目标测试选择语义参照 Xcode 实际参数；避免重用其他任务 DerivedData。
- Coverage：0／1／多窗、picker 选择／取消／错误路径／同名文件、空与真实历史 Git 仓库、长／特殊 Unicode 路径、重开文件、失败中途 cleanup、已运行同 Bundle ID 时明确拒绝；不会因追加重试将长路径失败隐藏。
- Uncovered：共享桌面不可安全执行时该 GUI gate 阻塞本任务，提交只读诊断证据并明确要求独立 Runner，不将编译成功记作本任务的 GUI 通过。
- 原有 10 个测试分别核销，缺陷先 Red→Green，修复测试基础设施时同步相关规范；验证后按仓库规则提交本任务生产/测试 diff（规划文档仍默认本地）。

<a id="p1-t3"></a>

## P1-T3 清理 Unit／Integration 的 UI 污染边界，保留逻辑价值

**Files:** `BaileyTests/Unit` 8 个源文件、`BaileyTests/Integration` 20 个源文件，重点 `BaileyTests/Integration/Workspace/SessionStoreTests.swift` 与 `BaileyTests/Integration/Settings/AppSettingsTests.swift`；对应 `Bailey/Workspace/SessionStore.swift`、`Bailey/App/AppSettings.swift`；测试发现由 `Bailey.xcodeproj/project.pbxproj` 支持。

**Step 1 — 真实职责审查：**
- 对 306 个测试方法及共享助手按断言分层，而非按目录名：真实 `NSWindow/NSHostingView`、AppKit `firstResponder`、鼠标键盘、视图像素、UI Sheet 归 UI；JSON snapshot、Git 命令、file tree 数据、文本坐标、状态/Observation 属非 UI。仅 `import AppKit` 或读取颜色常量不自动意味着必须迁 UI。
- `SessionStoreTests.testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction` 与 `testClosedWindowCannotBeUsedForLateFileOperationErrors` 含真实原生装配，已交由 P4-T4 完整 E2E 验证；本 task 先证明它们混合了哪些纯恢复/归属不变量，P4-T4 负责实际搬离、删除旧 UI 路径。其余 SessionStore 十个方法和 `AppSettingsTests` 五个逐项核对是否仍直接依赖宿主窗口。
- 若非 UI 断言被混在 UI 方法内，标注保留 `BaileyTests/Unit` 还是 `Integration` 的新类及实际源码路径；不为减少源码数量删掉断线、延迟、保存冲突等后端安全回归。

**Step 2 — 验证：**
- 静态审查 28 个非 UI 类所有方法与导入/具体创建的对象，并核对运行时选择；验证目标定义为最终非 UI Target 没有 UI 事件／窗口渲染，不要求排斥 Foundation 之外的所有库。
- GUI 依赖的拆除排在其负责的 P2–P4 task，**本 task 不能在证明替代前删原测试**；更新 `migration-inventory.md` 的 Integration 异常项和全部依赖。
- Coverage：现有 Unit/Integration 成功／失败／混合异步/SSH 夹具、测试恢复导致的副作用、原生 AppSettings 测试的系统外观恢复；先确保独立模型逻辑覆盖仍可按类运行。Uncovered：P4-T4 前不能宣称整个 BaileyTests 已纯化，明确登记未完成项；不拿 P1 审查替代 P4 的真实删除。

<a id="p1-t4"></a>

## P1-T4 验证原生内部断言的跨进程等价证据可行性

**Files:** 查 `BaileyTests/NativeUI/Editor/{EditorNavigationTests,EditorTextInputTests,SyntaxHighlightingTests}.swift`、`BaileyTests/NativeUI/Git/{DiffTabTests,RecentCommitsViewTests}.swift`、`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`，产品锚点 `Bailey/Editor/{NativeCodeTextView,SourceTextEditor,SyntaxHighlighting}.swift`、`Bailey/Git/{RecentCommitsView,DiffNativeSurface}.swift`。

**Step 1 — 明确要回答的问题：**
- `XCUIApplication` 能否通过可见文本／可访问性、键盘、原生截图／录屏与外部磁盘／Git 结果直接证明 TextKit 2 的滚动/换行/焦点，IME 组合文本/Undo，Git Graph 颜色/图谱，Diff 删除行/分屏同步，以及关闭五编辑器后的资源释放？
- 现存 XCTest 直接读 `NSTextView` 内部布局、颜色、对象指针、Parser captures、`WKWebView` 引用等，哪些可拆成**非 UI 算法和业务不变量**并由 Unit/Integration 保留，哪些必须由用户可见 E2E/人工输入取代？不得直接把 App 内私有指针泄露给 UI Test。
- 对 AX／截图／图形像素的观测做最小演示：相同夹具同环境的前后对照、已知焦点错误或已知文字颜色差异能否被测试发现；测量是否稳定、是否会误把系统动画与光标闪烁作为回归。原生中文 IME、真实 Finder 拖放、macOS 15.6、物理触控板等未满足条件分别登记，不能用 `typeText` 伪装成系统输入法完整组合行为。

**Step 2 — 实验验收与决策：**
- 先保留原生守卫测试；用已存在的 10 条 E2E 和最小新增 UI 路径对照原子输出，证明方法可行后才给 P2–P4 拆迁。无需先开发新的生产 Framework／测试专用 Coordinator。
- 为每项无法完整通过跨进程接口观测的旧保障，列出「现行原断言 → 可由纯逻辑守住的部分 → 可由真实 UI 守住的部分 → 不可验证的剩余差异、原因、补验方式与 Gate」。能力不明时不提前承诺已全自动化。
- Coverage：浅/深主题、中文/英文、原生窗口尺寸极值、长行／Unicode／CRLF／组合输入／多窗／失败恢复、非运行状态资源回收与重启；具体受影响维度见 `idea.md`，有条件项逐一验证。没有硬件或授权的情况按项记录，而非静默跳过。
- 本 task 的产物是经最小实验支撑的设计选择和证据，不能以 `make build:ui` 代替真实可行性结论；尚不启动 P2–P4 的迁移或删除。

---

## Phase Audit

P1 各 task 完成后由 `executing-plans` 触发 `plan-task-auditor`，当时才生成 `audit-p1.md`。审核要求：329 方法对应 task 0 漏项、28 个非 UI 类审过，独立 Runner 与真实不可观测边界有可核验结果；任何前置安全缺陷仍未解决则 P2 不以 UI 全绿为基础。
