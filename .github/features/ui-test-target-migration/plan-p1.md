# Plan P1 — 分类核销与可靠的 UI Test 基础

**Goal:** 在不动产品功能和用户 Bailey 的前提下，确认当前 329 条旧 UI、306 条 Unit/Integration 和 10 条 XCUITest 的断言职责；修复现有 UI Runner 的实际失败点，为 P2–P4 的逐项迁移建立可信起点。

**Non-goals:** 不在本阶段删除尚未被替代的原生测试；不新增 UI 自动化框架、另一套 App 身份、生产测试后门或独立配置状态机。

**Approach:** 逐方法读现有 XCTest 的输入、动作、断言与 fixture；按断言而非目录和 `import AppKit` 判定 UI／非 UI 归属。测试运行沿用现有 `BaileyUITests`、两个 Scheme、Makefile 和 CI。TextKit、Diff、Git Graph 等内部可观测性由负责迁移的 P2–P4 任务当场验证，不另设跨领域预研。

**Acceptance:** 329 条方法 0 遗漏且已有任务归属；306 条非 UI 方法的 UI 混入边界明确；10 条现有 UI 用例有独立 Runner 的实际结果；所有新旧测试未因本阶段丢失断言。完成前须说明未实测场景，不拿编译冒充 E2E。

**Rules:** 运行中的正式 Bailey 不退出、不重启、不覆盖。保留必要的 `BaileyInstanceMode`、`SessionStore.localFile`、保存失败保护及 SSH 目标校验。新增生产 AX 语义只为现有真实控件负责，不用虚假测试控件。

---

<a id="p1-t1"></a>

## P1-T1 按方法核对旧测试与行为归属

**Files:** `BaileyTests/{NativeUI,WorkspaceUI}/**/*Tests.swift`，`BaileyUITests/**/*Tests.swift`；实施证据补入 `migration-inventory.md`，并核对 `Bailey.xcodeproj/project.pbxproj` 和两个 Scheme。

**Why:** 当前 329 条方法按名称和所在文件已在 [清单](migration-inventory.md) 中登记，但初次盘点并不等于已读取每条原断言；直接搬目录会丢掉原生组件、Git 后端及异步失败边界。

**Steps:**
1. 逐个读取 23 个源文件中的 329 个方法及它们实际调用的 helper；确认每个旧输入/触发、用户结果、内部不变量、错误/取消、生命周期与临时夹具。核对实际测试发现（不只统计 `func test*`）、动态跳过、同名方法及可能的新版本文件；并核对当前 10 个 `BaileyUITests` 的真实断言，而非仅名称。
2. 逐项决定：A. 用户操作 → 跨进程真实 UI；B. 字节、数据、Git/解析/坐标/状态 → `Unit/Integration`；C. 两种都需要 → 拆分。允许几个旧方法映射一个更强的测试，但要逐条记录每个边界如何保留；不能因“未来会有 UI Test”提前删除原断言。
3. 根据当前真正的入口确认负责人：Editor/NativeCodeTextView → P2、GitPanel/RecentCommitsView → P3、FileTreePanel/WorkspaceApplication/WorkspaceWindowModel → P4。其它隐藏 GUI 混入由 P1-T3 负责，避免 P1 同一测试重复登记。

**Verification:** 当前源码静态枚举与 Xcode 实际测试发现的名称/数量交叉核对；清单中 329 个旧 `Class.method` 都有唯一的 P2/P3/P4 task，源与清单双向差集均为空。当前 CI/本机执行条件、不能实测的环境逐项说明。此任务只出分类证据，不强行制造 Red/Green、删除源代码或进行 UI 自动化。

**Cleanup/doc owner:** 发现真正重复的计划条目立即合并，不另建实时任务表；产品/测试旧代码由相应 P2–P4 任务在替代测试通过的同一次提交删除。此次只更新 Feature 清单。

---

<a id="p1-t2"></a>

## P1-T2 修复独立 Runner 和现有十条真实 UI 路径

**Files:** `BaileyUITests/Support/WorkspaceUITestSupport.swift`、现有 `BaileyUITests/{Files,Git,Workspace}/*UITests.swift`；必要时 `Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/UI/Components/WorkspaceChrome.swift`、`Bailey/UI/ContentView.swift`、`Bailey.xcodeproj`、`Makefile`。验证方式改变即同步 `docs/testing.md`／`docs/release.md`。

**Why / verified risk:**
- 现有 `fileRow(_:,in:)` 搜索全 App 中标识相同的 `bailey.tree.file`，只以 `lastPathComponent` 模糊匹配；Files/Git 并列、两个目录同名文件时可能拿到错误区域和对象。`fileTab` 同样只用 basename；不能以 `firstMatch` 存在证明来源正确。
- 既有 Sheet 操作写死 `Add/Open/Cancel` 文案，系统语言或 Touch Bar 重名可能破坏测试选择。旧的 AX 全路径标识已遇到 128 字符限制；应按真正控件/窗口做可靠查询，不增加隐藏测试 UI。
- `WorkspaceUITestSupport.launch` 已注册 App teardown，多数具体用例又在 `defer` 中 `app.terminate()`。更重要的是，Files/Git 测试**先创建 fixture / 写文件 / 初始化 Git，再调用会抛错的 `launch()`，直到成功返回后才注册 `defer { fixture.remove() }`**；启动失败就漏清理临时目录。应用关闭应仅有统一 teardown，fixture 创建成功后应立即登记清理，测试内后续任意抛错都能清理。
- `WorkspaceUITestFixture.git(_:)` 将 stdout 和 stderr 都设为 `Pipe`，却在 `process.waitUntilExit()` 前不读取它们；复杂 Git fixture 的输出塞满管道时会互相等待。使用无需输出的安全重定向或可靠排空，并核实退出码和错误信息；不要因此开发第三套命令执行器。`WorkspaceUITestFixture.file(_:)` 仅向 `root.appendingPathComponent(name)` 写文件，不创建中间目录；同名不同路径测试须先建立各自父目录，或仅扩展该现有 helper，不能以根目录里的同名标签假装覆盖。
- `--isolated-ui-test` 自身仅隔离快照／终端历史并禁启保存的隧道；仅给 `HOME` 赋临时值确实不改变 Foundation 配置路径。2026-10-23 续执行已用 Apple CoreFoundation 的 `CFFIXED_USER_HOME`、当前 SDK 探针和真实 Dev App 证明临时 Foundation 主目录可行：启动器同时设置两种主目录并核对临时 TOML，外观和字号可使用真实临时配置，不新增产品配置注入。此证据不隔离 UserDefaults／钥匙串，语言持久化仍需独立登录账户或明确恢复方案。Git 夹具须显式持久化自身身份与不签名策略，不依赖真实 HOME。
- `BaileyTests` 虽被称为 Unit Target，Xcode 构建配置却明确 `TEST_HOST = $(BUILT_PRODUCTS_DIR)/Bailey.app/Contents/MacOS/bailey`，`make test` 没有 `make test:ui` 的在用 App 预检；先通过工程配置和安全环境的真实运行证实宿主不会占用/污染用户会话，决定是否只限独立 Runner 或在现有 Makefile 上做最小前置保护。**在未证明安全前，本机正式 Bailey 运行时也不要启动 `make test`**，不能因测试名为 Unit 就擅自启动第二个 App。

**Steps:**
1. 保留现有 `make test:ui` 的 `pgrep -x bailey` 安全拒绝；专用 CI GUI Runner 从真实 `XCUIApplication.launch()` 开始依次执行原 10 项，核验原生文件选择器、项目载入、文件 Tab/真实保存、Palette 焦点、Git history/Changes、多窗和 Settings 只读入口。先用 fixture 建好仓库并检查分支、commit 和实际文件，失败要有精准诊断，不能通过加 `sleep` 或 `XCTSkip` 隐藏。
2. 用实际面板/列表/窗口限定 AX 查询，验证不同目录同名、Files 与 Git 同时展示、两个 Tab 同名、超长/Unicode 路径及目标选择准确；需要时补充不含绝对路径的真实 AX 语义。系统文件选择器须在所附 Sheet 和当前语言中操作，不能命中其他窗口的同名按钮。
3. 统一本次 UI 测试拥有的 App、fixture 和 Git 子进程的 teardown：**创建临时目录成功后立即注册同一 XCTest 用例的清理**，不等到 `launch()` 成功；App 的关闭只由 `WorkspaceUITestSupport.launch` 登记一次；Git 子进程的 stdout/stderr 必须在退出前避免管道反压阻塞，验证真实失败能退出并报告错误。`BAILEY_UI_TEST_RUN_ID` 供有意重启恢复，同一次测试直接复用现有 `XCUIApplication`（其 `launchEnvironment` 已保持 UUID）即可；不同用例各自独立 UUID，无需另建重启管理器。
4. 本任务修掉的旧 helper、重复 teardown、无效测试查询或过时 fixture 在同一提交直接移除；不能留到 P5。保留产品当前有效的数据保护守卫。

**Verification:** 本机正式 App 活跃时只允许安全的 `make build:ui SIGNING=adhoc`，不运行 UI Test；`make test` 因真实 `TEST_HOST` 未证明本机会话安全也先不执行。专用 Runner 跑 `make test:ui SIGNING=adhoc` 和相应 `ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests`／Git/Windows/Smoke 定点选择，核对完整命令退出状态、用例实际发现、0 意外 skipped。遍历本任务实际可达的空/非空项目、长/重名路径、文件选择器确认/取消、同名跨组、不同语言窗口、脏数据写盘、重复打开、失败清理与现有 Bailey 进程安全拒绝。无法安全自动操作的真 GUI/系统权限逐项说明原因、替代证据及 Gate，不把 `build-for-testing` 称为 E2E。

---

<a id="p1-t3"></a>

## P1-T3 核对 Unit/Integration 中混入的原生 UI 用例

**Files:** `BaileyTests/Unit`（8 文件、75 方法）、`BaileyTests/Integration`（20 文件、231 方法）；重点 `BaileyTests/Integration/Workspace/SessionStoreTests.swift` 与 `BaileyTests/Integration/Settings/AppSettingsTests.swift`，必要的源锚点 `Bailey/Workspace/SessionStore.swift`、`Bailey/App/AppSettings.swift`。

**Why:** 迁移目标是两个纯职责 Target，而非只删除 `NativeUI`/`WorkspaceUI` 目录。`SessionStoreTests` 中有实际 `NSWindow`/`NSHostingView`。**源码已证实 `AppSettingsTests` 全部 5 个方法都有隐藏的原生副作用**：它们反复构造 `AppSettings(configURL:)`，而 `AppSettings.init` 在结束前无条件调用 `applyAppearance()` → `NSApp?.appearance = theme.nsAppearance` 和 `reloadThemeSelection()` → 全局 `Theme.reloadSelection`；其中两方法另直接恢复 `NSApp`，一方法修改 `.theme`。不能用“只有两项显式引用 NSApp”的扫描结论证明其余三项纯净。

**Steps:**
1. 核对全部 28 个 Unit/Integration 文件的 306 个方法及共享测试 helper，辨别窗口装配、原生输入、图形断言与纯 model/文件、Git/远端、配置/Observation。测试只引用 `NSColor` 或 Foundation 兼容类型，但不渲染/发事件时可保留在低层。
2. 两条 `SessionStoreTests.testRealWindowRootRetainsItsRegistrationAndEditorAcrossViewConstruction`、`testClosedWindowCannotBeUsedForLateFileOperationErrors` 含原生窗口依赖：P4-T4 负责真实 App 替代与**同任务删除旧原生部分**，快照身份/退出队列逻辑留在非 UI Target。其他 8 项逐项查。对 `AppSettingsTests` **全部 5 项**，在本任务就逐个复核构造引发的 `NSApp` 与全局 Theme 写入，先消除不需要真实 GUI 的初始化/测试副作用和多余恢复路径；若需小幅调整 `AppSettings.init` 的外观应用时机，必须跟踪 `BaileyApp` → `BaileyApplicationDelegate.applicationWillFinishLaunching` 既有 `AppSettings.shared.applyAppearance()` 路径，证明正常首次启动、切主题和恢复不变，不为 XCTest 加业务分支。配置、Theme 值和 Observation 的原断言保留非 UI；真正用户可见 Settings 改动于 P4-T5 验证，不能提前删掉唯一的有效保障。
3. 在 `migration-inventory.md` 的额外混入部分登记实际归属和消费任务，不额外维护第二张长表，也不要求把所有带 `@MainActor` 的非 UI 测试迁移。

**Verification:** 全部 28 个文件及运行发现集合核对；从旧类中识别的真 UI 操作都有关联 P2–P4 任务和删除条件，不能在 P1 清单调查后宣称最终纯净。非 UI 性能/错误/SSH/快照输入保留；有条件的真实 SSH tests 可以按环境明确跳过，**跳过不算对应真实远端通过**，不为让全量数字归零而删测试。

**Cleanup/doc owner:** P1-T3 当场删除**已证实不再需要**的配置测试原生副作用/重复复位，不把简单根因清理推到 P4-T5；同时修正触及的 `Bailey/App/AppSettings.swift` 注释和 `docs/features/{settings,tunnels}.md` 将实际 `.config/bailey` 误写为 `.config/Bailey` 的旧路径，不引入双目录兼容。P4-T4 负责 `SessionStoreTests` 两项图形用例的替代删除，P4-T5 只负责剩余真正可见的 Settings 操作和最终核验。任何修改仍须保证共享 Theme 状态不污染其它测试，不得直接删除必要的恢复逻辑。同步 `docs/testing.md` 对应分类。

---

## Phase Audit

三项任务完成时才由执行工具生成阶段审查证据。核验 329 条源方法、306 条现有低层方法与 10 条现有 UI 用例的归属和实际 Runner 前置条件；明确哪个领域内部断言必须由 P2–P4 当场做等价性实验。阶段完成不等于 UI 迁移已完成。
