# Audit P3 - ui-test-target-migration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/ui-test-target-migration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 历史版本文件、Git revision 和安全重置
- [x] P3-T2 Git Changes 交互、外部刷新、菜单与工作树操作
- [x] P3-T3 Git 原生对话框、危险操作、交互 rebase
- [x] P3-T4 Git Graph 全图谱、颜色/标签、键盘与多级菜单

## 任务到文件的映射

- P3-T1：`BaileyUITests/Git/GitHistoryUITests.swift`、`BaileyTests/Integration/Git/{NativeGitHistoryFileTests,NativeDiffTabTests}.swift`；真实 Git revision、重置前后磁盘/index/HEAD 和只读 Diff。
- P3-T2：`BaileyUITests/Git/{GitChangesUITests,GitUncommittedUITests,GitIgnoreEditorUITests}.swift`、`Bailey/Git/GitStatusModel.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`BaileyTests/Integration/Git/{GitRemoteRefreshIntegrationTests,GitStatusModelTests,DiscardRemoteWorkspaceFixture}.swift`；真实 Git Changes 输入与安全操作、外部事件和远端轮询取消。
- P3-T3：`BaileyUITests/Git/GitDialogUITests.swift`、`BaileyTests/Integration/Git/{GitBranchActionTests,GitCommitActionTests,GitTagActionTests}.swift`、`BaileyTests/Integration/Remote/GitInteractiveRebaseIntegrationTests.swift`；表单、真实 Git Ref、PTY 和独立 SSH 握手。
- P3-T4：`Bailey/Git/RecentCommitsView.swift`、`BaileyUITests/Git/{GitGraphUITests,GitGraphGeometryUITests}.swift`、`BaileyTests/Unit/Git/{CommitGraphLayoutTests,GitGraphPaletteTests,GitGraphReferenceGroupTests,GitGraphWorktreePresentationTests}.swift`；图谱、颜色、窄栏、键鼠、多级菜单与历史 Diff。

## 发现项

## 发现 F-02

- 任务：`P3-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Remote/GitInteractiveRebaseIntegrationTests.swift:106-116,242-252`
- 摘要：`交互 Rebase 集成测试仍装配 NSWindow+NSHostingView(PanelContentView) 来启动真实终端，违反 P3 原生 UI 已迁出宿主的约束`
- 风险：`BaileyTests 隐含图形会话依赖、UI 生命周期未从真实 App 入口证明且 PTY 行为若直接删除会退化`
- 预期修复：`追踪 TerminalSession 原生启动与 PTY 输入路径，保留真实 Git/SSH 后端不变量，仅允许 Ghostty 必需的最小 NSWindow 附着，并用独立 GitDialogUITests 验证真实用户操作；迁出窗口挂载前确保等价运行证据`
- 验证：`make test:GitInteractiveRebaseIntegrationTests；BaileyUITests/GitDialogUITests/testInteractiveRebaseFromGitGraphOpensRealPTYAndAcceptsEditorInput；Git HEAD/工作区真实结果`
- 解决证据：`移除两处 NSHostingView(PanelContentView)，直接将 TerminalBackendSurface 挂入只提供进程附着条件的 AppKit NSWindow（Ghostty 仅 window-attached 启动 PTY，见 BaileyTerminalView.swift:44）；不再模拟完整窗口 UI。原生集成本地+获准 Windows SSH 3/3、0 skip、exit 0（/tmp/bailey-p3-audit-pty-raw-surface-tests.log）；完整 Bailey Dev Git Graph→Sheet→终端输入 E2E 1/1、exit 0（/tmp/bailey-p3-audit-rebase-full-app-gui.log）。不可去除的底层挂载例外已在 idea.md 和 plan-p3.md 明确限定。`


## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Git/GitRemoteRefreshIntegrationTests.swift:50-110,208-282`
- 摘要：`Git 状态刷新集成测试仍以 NSWindow/NSHostingView 挂载 ToolPanelView 并通过窗口可见性模拟用户，违反 BaileyTests 不得装配 GUI 的唯一分层目标`
- 风险：`NativeUI 旧测试虽已删除，但伪装为 Integration 的 SwiftUI GUI 仍保留第二条 UI 测试通路`
- 预期修复：`区分纯后端慢响应与真实可见面板计时；将可直接证明的刷新正确性保留无窗口集成测试，将组件挂载与显示/隐藏验证转向独立 XCUIApplication，不能因迁移删除自动轮询保障`
- 验证：`make test:GitRemoteRefreshIntegrationTests；受影响 BaileyUITests/GitChangesUITests 与 SSH 真实 App GUI 入口，确认两目标语义和文件/Ref 结果`
- 解决证据：`UI 测试专属旧 NSHostingView/NSWindow 完全删除；ToolPanelView 调用 GitStatusModel.runRemoteRefreshLoop，由 view.task 的可见/活跃生命周期取消。Windows SSH 模型定点 2/2、0 skip、exit 0（/tmp/bailey-p3-audit-remote-loop-real-ssh.log）；真实 Bailey Dev 外部初始化/提交与 Graph 刷新 3/3、exit 0（/tmp/bailey-p3-audit-loop-real-gui.log），验证 Git Ref、文件与菜单最终结果。`


## 修复日志

- F-01：删除 `GitRemoteRefreshIntegrationTests` 的全部 `NSHostingView/NSWindow` 夹具。`ToolPanelView` 仍以 `.task` 持有和取消轮询，五秒 SSH 查询由唯一 `GitStatusModel.runRemoteRefreshLoop()` 负责；不改变本地事件驱动刷新，也不引入第二套定时器。
- F-02：源码确认 Ghostty `BaileyTerminalView` 需要窗口附着才启动子进程。两条真实 PTY 集成测试不再挂载 `PanelContentView`，而是直接挂载现有 `TerminalBackendSurface`；仅保留最小 `NSWindow` 作为底层进程启动条件，绝不模拟菜单/键盘/页面。完整 UI 用户路径继续由独立 `GitDialogUITests` 验证。唯一例外边界记录于 `idea.md` 和 `plan-p3.md`，并非静默降低目标。
- 两项修复与当前文档一并提交为 `f9eb22a`（6 文件，52 行新增、94 行删除）；本 Feature 的审计、计划、状态按约定仅留本地。

## 验证日志

- P3 原 102 个测试方法在 `migration-inventory.md` 中逐条映射：T1 21、T2 15、T3 18、T4 48；没有未列出的旧方法。旧 `BaileyTests/NativeUI/Git` 类及其 UI 宿主已删除，用户界面交互迁入真实 Bailey Dev。
- T1：`GitHistoryUITests` 真正历史 Git UI 5/5，宿主 NativeHistory/Diff/Status/Execution 89/89，实际 Git blob/index/HEAD 与磁盘字节；提交 `f0f8699`。
- T2：原 `GitChangesUITests` 11/11、附加冲突 1/1、`GitUncommittedUITests` 3/3、`GitIgnoreEditorUITests` 1/1；获准 Windows SSH 与底层宿主先前 58/58；提交 `76c417e`。
- T3：`GitDialogUITests` 完整 21/21、受影响 Branch/Tag 21/21、原 PTY/SSH 3/3；提交 `5f7d512`。
- T4：两类 UI 首次 45 项 42 通过、3 项 150pt/24-lane 宽度真实失败；修复之后定点 10/10，额外 33 Remote 最窄栏菜单 1/1；移除旧宿主后 Unit/Status 五类 88/88、构建 Dev 与正式 Debug 成功，严格签名通过；提交 `6853d34`。**没有声称修复后全 45 项重新执行**。
- F-01：`TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:GitRemoteRefreshIntegrationTests` → 2/2、0 skip、0 failure、exit 0（`/tmp/bailey-p3-audit-remote-loop-real-ssh.log`）；真实 Bailey Dev `GitChangesUITests` 外部 init/worktree/commit 与 `GitGraphGeometryUITests` 远端标签刷新组合 3/3、exit 0（`/tmp/bailey-p3-audit-loop-real-gui.log`）。校验实际文件、Git Ref、菜单所指 checkout，而非只看事件或 mock。
- F-02：`TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:GitInteractiveRebaseIntegrationTests` → 3/3、0 skip、0 failure、exit 0（`/tmp/bailey-p3-audit-pty-raw-surface-tests.log`）；Dev `GitDialogUITests.testInteractiveRebaseFromGitGraphOpensRealPTYAndAcceptsEditorInput` → 1/1、exit 0（`/tmp/bailey-p3-audit-rebase-full-app-gui.log`）。确认标记文件写入工作目录及 PTY 状态、编辑器待输入前 HEAD 未变、Return 后 HEAD/两份文件内容符合预期；真正 SSH 包含固定与自动跟随项目。
- 受影响扩大回归：`make test:GitStatusModelTests,PanelContextTests` → **61/61、0 失败、0 跳过、exit 0**（`/tmp/bailey-p3-audit-model-panel-regression.log`）；`make build` → `BUILD SUCCEEDED`、exit 0，`codesign --verify --deep --strict` → exit 0（`/tmp/bailey-p3-audit-final-normal-build.log`）。本轮不重跑无关的完整宿主／完整 UI Target；全量验证仍归 P5。
- 条件矩阵：本机 macOS 当前版本、可用 Dev/Debug、明暗×9/18pt、150–420pt 侧栏、24 lane、33 remote、中文长标题/路径、嵌套三级菜单、分页、Tree/List、实际 Worktree/Stash/Detached、二进制与 Git 恢复边界已有对应 UI/Unit/Integration 证据；真实 Windows SSH 本轮执行且未跳过。
- 尚未覆盖：macOS 15.6 真机、实体触控板、第二种显示设备（无相应硬件）；互联网上真实 provider 不作为可写测试仓库（改用 bare remote，外网认证/断链须获准专用环境）；SSH 面板在**完整 App**中显示→隐藏→恢复的组合尚无独立 App 级 E2E（模型取消及真实 SSH 已验证，但不可互相冒充）。这些环境组合需在 P5/专用设备补验，完整 Feature 的跨环境最终 Gate 不能据此标全域通过。
- 文档：产品规则归 `docs/features/{git,terminal}.md`，测试执行与分层归 `docs/testing.md`，审计特有例外和历史证据归本 Feature；正式 App 未启动、替换或重启。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（**仅 P3 → P4 的阶段门禁**，不是整个 Feature 的最终 Go）
- 理由：102 条旧方法全部有去向，4 个原生 Git suite 的关键用户行为、真实文件/Git 结果与错误恢复得到 UI/非 UI 双链证据；本轮两项高优先级审计发现已解决，受影响测试、真实 Windows SSH、构建和验签通过。P5 全量与环境覆盖仍单独验收。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 SSH 的完整 App 隐藏／恢复 GUI、macOS 15.6／实体触控板／其他显示设备、外部互联网 provider 错误注入和最终全量 CI 没有在本阶段完整闭环；P5 不得将这些事项当成已通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
