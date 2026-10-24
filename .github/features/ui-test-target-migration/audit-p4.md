# Audit P4 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 共享树行、Dock 点击、命令面板、App 菜单
- [x] P4-T2 多窗口的实际键盘响应与焦点恢复
- [x] P4-T3 Finder／Dock 外部文件打开和批量拖放的真实归属
- [x] P4-T4 窗口关闭、保存否决、状态恢复与原生对象身份
- [x] P4-T5 Terminal、Browser、编辑器原生资源、设置页

## 任务到文件的映射

- P4-T1：`87292c1`；`BaileyUITests/Files/SharedTreeUITests.swift`、`BaileyUITests/Workspace/WorkspaceDockUITests.swift`；共享树行、原生菜单及 Dock 真实点击；旧 `TreeRowHitTestingTests` 与 `DockFocusP2RegressionTests` 删除，菜单隔离守卫留待 T5。
- P4-T2：`be40be8`；`BaileyTests/Integration/Workspace/DockFocusIntegrationTests.swift`、`BaileyTests/Integration/Files/FileTreeTests.swift`、`BaileyUITests/Workspace/{WorkspaceWindowsUITests,WorkspaceDockUITests}.swift`；19 项跨窗、聚焦与键盘归属拆分，部分原生终端资源断言后续进入 T5。
- P4-T3：`c88f218`；`BaileyTests/Integration/Workspace/FinderDeliveryIntegrationTests.swift`、`BaileyUITests/Workspace/WorkspaceWindowsUITests.swift`；17 项 Finder／Launch Services、批次、过期回调与窗口归属，旧源项删除。
- P4-T4：`f4f6f81`；`BaileyTests/Integration/Workspace/{WindowCloseIntegrationTests,WindowOwnershipIntegrationTests,NativeContentIdentityIntegrationTests,SessionStoreTests}.swift`、`BaileyUITests/Workspace/WorkspaceWindowsUITests.swift`；15 项窗口／原生对象及额外 SessionStore 2 项拆分，3 旧类和完整 SwiftUI 宿主删除。
- P4-T5：`658eebe`；`BaileyTests/Integration/Workspace/NativePaneRetentionIntegrationTests.swift`、`BaileyUITests/Workspace/WorkspaceRetentionUITests.swift`、`Bailey/App/BaileyApp.swift`；20 项原生资源断言保留、最后 1 项旧测试专属 ⌘Q 拦截删除，真实退出、配置、Shell、WebKit 与多轮资源验收；同步对应领域文档。

## 发现项

## 发现 F-06

- 任务：`P4-T5`
- 严重级别：`High`
- 状态：`Open`
- 位置：`BaileyTests/Integration/Workspace/NativePaneRetentionIntegrationTests.swift:877-885`
- 摘要：`全量宿主549项中五编辑器资源释放用例连续五轮弱引用残留（每轮3/5）`
- 风险：`仅局部20/20不能证明复杂真实负载后旧原生文本视图和文档零持有；P4阶段Gate原先Go存在漏验`
- 预期修复：`核对旧视图的实际保留者和文档／SyntaxCoordinator释放路径，在真实所有权点消除泄漏或证明纯系统暂存后修正不成立的测试前提，不通过延迟或弱化断言掩盖`
- 验证：`make test:NativePaneRetentionIntegrationTests; make test SIGNING=adhoc; representative combination; release allocations`
- 后续复核：`/tmp/bailey-p5-host-adhoc-retain-diag.log` 与 `/tmp/bailey-p5-host-adhoc-repeat3.log` 均为完整宿主 549 项、8 跳过、0 失败、退出码 0；后者五轮均释放 5/5。一次失败仍未解释，不能仅凭重复通过关闭此项。
- 解决证据：尚未查明失效根因，待最终确认后回填。

## 发现 F-05

- 任务：`P4-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Workspace/WorkspaceRetentionUITests.swift:128`
- 摘要：`P4-T5 实际 Finder 拖放到 Ghostty 和 WebKit 文件上传入口缺少跨进程 UI 验收`
- 风险：`模型层测试只证明路径转换和 SSH 拒绝；真实 Finder 的文件 URL 是否由原生 Ghostty／WKWebView 接收，以及会否被上层错误重复打开标签尚无真实证据`
- 预期修复：`优先使用隔离 Bailey Dev 和临时 Finder 文件执行安全的真实拖放并验证终端输入但未发送 Return、网页 input[type=file] 选择和无重复 FileTab；若系统权限阻断，保留实际尝试、替代证据和 No-Go，不用合成 NSDraggingInfo 冒充`
- 验证：`BaileyUITests Finder-to-Terminal and Finder-to-WebKit paths; compare original disk bytes and workspace file-tab count`
- 解决证据：`fe8acb3: real Finder selected temporary file dragged via XCUICoordinate into isolated Bailey Dev Ghostty and WKWebView; terminal verified no auto-Return, explicit Return yields escaped file path in temporary marker, no FileTab and source bytes unchanged; WebKit input[type=file] change handler visibly shows exact filename with no FileTab and unchanged source bytes. Two individual targeted E2E PASS, then full WorkspaceRetentionUITests 7/7, zero failures/skips, exit 0 in /tmp/bailey-p4-audit-all-retention-fixed.log. Initial full-class Red after unconditional Finder view switch resolved by conditional-only switch.`


## 发现 F-04

- 任务：`P4-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Workspace/NativeContentIdentityIntegrationTests.swift:83`
- 摘要：`P4-T4 标签栏滚动用例仍在 Integration 挂载整棵 WorkspaceDockView`
- 风险：`整个 SwiftUI 工作区及 Git/Files 状态参与宿主测试，违反分层原则，且可能掩盖真实标签栏回弹的触发条件`
- 预期修复：`对生产中现有标签栏真实组件建立最小宿主，保留宽窄宽/溢出/回弹全部断言，删除完整 Dock 宿主`
- 验证：`make test:NativeContentIdentityIntegrationTests; git grep for full WorkspaceDockView host in BaileyTests; make build:ui`
- 解决证据：`Commit fc61ce2: native elasticity test now mounts real production DockTabGroupView in minimal NSHostingView/NSWindow; only internal visibility change (private to internal), no runtime behavior change or hand-built tab strip. Responsive wide/180pt narrow/wide scroll and horizontalScrollElasticity assertions retained. NativeContentIdentityIntegrationTests3/3, combined NativeContentIdentity/NativePaneRetention/WindowClose/DockWorkspace45/45, make build, make build:ui, codesign strict all pass. git grep confirms BaileyTests has no NSHostingView(rootView: WorkspaceDockView).`


## 发现 F-03

- 任务：`P4-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`.github/features/ui-test-target-migration/migration-inventory.md:499`
- 摘要：`优化 Release 只有一次关页堆快照与 RSS 曲线，尚缺同负载完整 Allocations 和可比较堆`
- 风险：`弱引用单测虽绿，无法将本机实时 App 的关闭后长期缓存与内存趋势同早期状态逐段比较`
- 预期修复：`在独立 Release Bailey Dev 的 GUI 五轮压力期间采集 Allocations 与多个开/关节点 heap/RSS，记录能证明和不能证明的结果`
- 验证：`xcrun xctrace record --template Allocations --attach <isolated Release PID>; heap -q -H; five-round Release GUI and disk bytes`
- 解决证据：`Release Bailey Dev five-round GUI 5/5 25 file opens/closes passed twice (latest /tmp/bailey-p4-audit-release-cycles.log). 105.833 s Allocations trace /tmp/Bailey-P4-Audit-Release-Allocations.trace verified via xctrace export --toc (Statistics, Allocations List, Regions Map). RSS 124 samples /tmp/bailey-p4-audit-release-rss.tsv; heap after round0,2,3 full closure 50.3/50.9/50.1 MiB; one RestorableScrollView and one SyntaxHighlightCoordinator at each cached snapshot, no per-round growth in these snapshots. 20/20 NativePaneRetention integration object weak-reference assertions retained; RSS and heap evidence is bounded, not proof of zero residual reachable caches.`


## 发现 F-02

- 任务：`P4-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`.github/features/ui-test-target-migration/migration-inventory.md:404-407`
- 摘要：`T2 三处引用 P4-T5 已重命名的原生组件测试类`
- 风险：`最终核销脚本无法找到旧 PaneRetentionTests 方法`
- 预期修复：`更新映射指向已存在 NativePaneRetentionIntegrationTests 真实测试，保留旧源方法名称和历史`
- 验证：`Swift test method declarations and P4 inventory row map`
- 解决证据：`P4-T2 three outdated references updated to NativePaneRetentionIntegrationTests; 19/19 rows and all P4 class.method refs exist in the current test tree`


## 发现 F-01

- 任务：`P4-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`.github/features/ui-test-target-migration/migration-inventory.md:381`
- 摘要：`T1 历史映射引用已经不存在的 WorkspaceDockUITests 方法名`
- 风险：`按旧名称检索会误判真实空白面板焦点 E2E 已被删除，阻碍最终 329 条追踪`
- 预期修复：`以实际存在的 testDockFocusHandoffNeverSendsKeysToHiddenEditor 替换名称并核对其真实键盘与磁盘断言`
- 验证：`method inventory cross-check + current WorkspaceDockUITests source`
- 解决证据：`P4-T1 inventory now points to WorkspaceDockUITests.testDockFocusHandoffNeverSendsKeysToHiddenEditor (currently defined, asserts old editor unchanged and exact disk bytes); 11/11 historical rows crosschecked`


## 修复日志

- `F-01/F-02`：将迁移清单中过期方法名改为当前真实测试声明，P4 全 85 条旧来源（83 + `SessionStoreTests` 2）均能追溯到有效的目标测试类与方法；源任务提交及历史事实未改写。
- `F-03`：Release Bailey Dev 五轮文件压力重跑并取得 Allocations 105.8 秒、RSS 124 个样本及关闭文件后的三次 heap（50.3、50.9、50.1 MiB）；原 20 项弱引用／持有契约由原生 Integration 继续守护，未把 RSS 当作零残留证明。
- `F-04`：提交 `fc61ce2` 将标签栏回弹测试的完整 `WorkspaceDockView` 宿主改为生产 `DockTabGroupView` 最小原生宿主；保留宽→窄→宽与横向弹性断言，无新的测试版组件。
- `F-05`：提交 `fe8acb3` 补真实 Finder 文件拖入 Ghostty 与 WebKit 两条 E2E，修正辅助函数强制切换 Finder 视图导致的回归；临时文件最终字节、终端路径、WebKit 文件名和不重复打开标签均实测。

## 验证日志

- 当前环境：Apple Silicon，macOS 27.2、Xcode 27.2。构建／验签：`make build`、`make build:ui`、`codesign --verify --deep --strict` 通过；只运行隔离 `chiimagnus.bailey.dev`，未替换正式 App。
- 分层与旧方法：逐项核对 P4-T1 11、T2 19、T3 17、T4 15 + 额外 2、T5 21，共 **85 条**。当前 `BaileyTests/NativeUI` 和 `WorkspaceUI` 无跟踪文件；不再有 `BaileyTests` 挂载完整 `WorkspaceDockView`。本次修复后 `NativeContentIdentityIntegrationTests` 3/3；与原生资源、窗口关闭和 Dock 模型合跑 45/45（`/tmp/bailey-p4-audit-targeted-final.log`），旧资源本体 20/20。
- GUI 全链：`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceRetentionUITests` **7/7、0 失败、0 跳过、退出码 0**（`/tmp/bailey-p4-audit-all-retention-fixed.log`）。真实 Finder→Ghostty 验证仅粘贴、不自动执行与磁盘原字节；Finder→WebKit 验证文件输入及无误开标签；5 轮各 5 个 10k 行文件关闭归零；另覆盖正常退出保存失败否决与重启、Settings、Shell PID、WebKit 未提交表单。T1–T4 各任务原有定点 GUI 与 Integration 证据见 `todo.toml` 和 `migration-inventory.md`。
- 资源验证：优化 Release 5/5 轮且文件字节不变；`xctrace export --toc` 证实 Allocations Trace 含 Statistics／Allocations List／Regions Map；堆快照节点及缓存无逐轮累加证据，**不代表证明任意时刻无泄漏**。
- 限制与补验：macOS 15.6 真机、实体触控板、非当前显示设备没有可用环境，不能用 XCUITest 的鼠标代替；终端／WebKit 的跨窗混合长期压力及 Windows SSH 实机全路径尚无本轮专用证据，已有双窗身份、同窗资源、SSH 模型和本机真实拖放作为部分替代。影响为外部环境与组合的回归风险，需在具备对应设备／授权时针对性 E2E 复核，最终全环境验收不得称作已通过。PR #54 当前仍为 Draft，远端 CI 为 skipped；这不计为已执行 CI，归 P5 最终门禁。
- 当前长期文档归属：`docs/testing.md` 与 `docs/features/{browser,terminal,dock,editor,settings}.md` 已按实际测试入口更新；neat-freak 文档链接审查无断链，Git 差异检查通过；审计和迁移证据仅本地保存。

## Gate（是否允许进入下一阶段）

- 结论：`No-Go`（P5 全量回归发现新阻塞，撤销此前局部 Go）
- 理由：85 条旧保障与 7/7 GUI 已通过，但完整宿主回归曾在五编辑器释放用例发生 10 条断言失败；后续两轮 549 项均通过，仍未证明失败源于 AppKit 临时持有、测试对象生存期还是产品泄漏，F-06 保持 Open。

## 最终状态与剩余风险

- 当前状态：`Open`（F-06 调查中）
- 剩余风险：宿主资源释放偶发失败根因未明；此外最低系统真机、物理输入、远程 SSH、跨窗混合长时压力和 PR Head CI 尚未全证实；不得给出 P4／P5 Go。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

