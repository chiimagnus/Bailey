# P4 · 其余 67 项 UI：真正收敛完整用户流程

**Goal:** 将除 Git Dialog/Graph 外的 **67** 个 UI 方法压缩为可由真实系统行为证明、无重复 fixture/后台数据矩阵的少量 E2E。三组归属：其它 Git **26**、Files/Editor **22**、Workspace **19**。在 P1–P3 证据基础上，完整 App UI 总数目标约 **30–50**，不是先定数再删断言。

**Non-goals:** 不把 Finder 系统事件、真实输入法候选、TextKit 图像、Ghostty Shell 或 WebKit 上传伪装成纯 Unit；不为降低方法数只把 5 项合到 1 个巨大 E2E；不改用户 UI/UX、不改完整 CI 规则。

**共同 Gate:** P1/P2 的纯算法/真 IO/最小 AppKit 合同先跑通；每条被删的 E2E 必须由现有低层＋剩余的原生跨层用户路径联合覆盖。合并流程时失败要能直接定位，保留真实窗口/项目/机器和文件字节检查。只运行受影响的 E2E，最后做一次正式完整验收并报告是否真的执行。

---

<a id="p4-t1"></a>

## P4-T1 Git Changes/History/Ignore/Uncommitted：26 条重叠路径去重

**Files:** BaileyUITests/Git/GitChangesUITests.swift（12）、GitHistoryUITests.swift（5）、GitIgnoreEditorUITests.swift（1）、GitUncommittedUITests.swift（3）、WorkspaceGitUITests.swift（3）、BaileyUITests/Files/SharedTreeUITests.swift 的两条 Git 方法；Integration/Git 的 GitStatusModelTests、NativeGitHistoryFileTests、GitUncommittedActionTests、GitIgnoreIntegrationTests、NativeDiffTabTests 等对应 owner。

**Steps:**
1. 将每条测试的“菜单/按钮/焦点/原生错误提示”与“真实 Git index/HEAD/工作树数据”拆开。后者的全量矩阵已由 GitStatusModelTests、GitWorkspaceActionTests、GitUncommittedActionTests、GitIgnoreIntegrationTests、NativeGitHistoryFileTests、NativeDiffTabTests 覆盖时，不应每次都重新创建仓库、Commit 和复杂 Unicode 样本。完整 App 保留一条从真实用户入口到真实副作用的连通证据。
2. **三种 Stage/Unstage 用户入口不可合并删除**：文件夹右侧 inline、文件夹右键以及单文件右键/inline；真实 Tree/Graph 键盘焦点也不能被 Git 状态测试替代。SharedTree 的两项 Git 行横滚/Stage 按钮命中与后台 Git staging 不是同一个合同，核对后再决定是否被真正等价的树行 E2E 承接。
3. 对历史 revision、rename/copy、二进制/超大文件错误、外部编辑后拒 Reset、Merge Conflict、忽略规则与已打开编辑器 Undo、Stash/Reset/Clean 危险确认，优先由最小 NativeDiff/真实文件集成负责数据异常矩阵，完整 App 只保留独有菜单、焦点、取消→确认及文件真实字节。**不得删掉“有一条被拒绝的错误提醒”这种只能完整用户层证明的反馈**。
4. 每个删减方法即时核销原断言和剩余系统入口；删除该方法的独占 fixture/helper，必要时同步 docs/testing.md 当前选择器，不动 docs/features/git.md 的产品安全契约。

**Verify:** 根据实际改动运行 make test:GitStatusModelTests,GitWorkspaceActionTests,GitUncommittedActionTests,GitIgnoreIntegrationTests,NativeGitHistoryFileTests,NativeDiffTabTests,FileTreeTests；独占 GUI 定点运行改变过的三种 Stage 入口、真实 Git 历史/错误提示、键盘、窗口/项目隔离。覆盖 HEAD/index、两个 worktree、rename/copy、冲突/取消/拒写/恢复、Unicode/二进制、文件不串仓。报告 26→实际数量。

**Commit:** 其它 Git UI 一次独立原子提交。

<a id="p4-t2"></a>

## P4-T2 Files/Editor：22 项中的数据/容量矩阵下沉

**Files:** BaileyUITests/Files/WorkspaceFilesUITests.swift（11）、SharedTreeUITests.swift 的六条非 Git 方法、BaileyUITests/Editor/EditorNavigationUITests.swift（3）、EditorHighlightingUITests.swift（2）；Integration/Files、Integration/Editor、Unit/Editor、Unit/Files 中真实职责类。

**Steps:**
1. 纯路径去重/同名身份、树压缩/Unicode/滚动索引、文本坐标、语法解析和大规模输入矩阵交 P1 Unit；真实 FileTab 读写、TextKit2 视口、标记中文输入、原生像素、Undo/Redo、错误/重载和对象释放交 P2 Integration。完整 App 只需 FilePicker/Finder、Dock/文件树真实命中、原生快捷键聚焦、真正保存到磁盘等跨层路径。
2. 本机 10k 行 Unicode/emoji 与 100k ASCII 测试**输入不同**，只有 P2 证明原生边界、实际文件字节和用户完整键盘语义都被其它层覆盖才考虑删其重复操作或其中一条 E2E；不能用 10k 代表 100k。Swift/Markdown/TSX/HTML/CSS vs plain text 的真实像素由 AppKit 与必要的真实文件开窗共同证明，不能只检查 token 列表。
3. 将中文长路径 Picker、系统 ⌘O、取消恢复剪贴板、重名不同路径保存、FileTree 焦点/键盘恢复、明暗 Tree 选中背景按**独有系统路径**分组；一个真实路径内顺序验证相邻结果，去掉同一焦点在中英文、多个菜单来源重复启动 App 的乘积。仍需保留真实语言/主题边界，以低层范围矩阵和最少原生 E2E 共同证明。
4. 同 task 删除替代成功的完整 App 方法及失效 helper，保持文件保存保护与不同仓库文件目标不变。

**Verify:** 实际受影响时选择 make test:FileTreeTests,FileTabPersistenceTests,NativeFileTabTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,TextCoordinateIndexTests；GUI 只运行被修改的 Files/Editor/SharedTree 方法。检查空/重复/特殊路径、中文/英文、10k/100k、IME/Undo/Save、深浅、系统 Picker、焦点、拒写和磁盘原字节；没有 macOS 15.6/实体中文 IME/触控板的组合需明确具体缺口。报告 22→实际 E2E 数。

**Commit:** Files/Editor UI 独立提交。

<a id="p4-t3"></a>

## P4-T3 Workspace：19 项聚焦系统交接，完成金字塔收尾

**Files:** BaileyUITests/Workspace/WorkspaceDockUITests.swift（3）、WorkspaceRetentionUITests.swift（7）、WorkspaceSmokeUITests.swift（1）、WorkspaceWindowsUITests.swift（8）；Integration/Workspace 的 DockFocusIntegrationTests、FinderDeliveryIntegrationTests、NativePaneRetentionIntegrationTests、WindowCloseIntegrationTests、WindowOwnershipIntegrationTests、SessionStoreTests、WorkspaceIdentityTests。

**Steps:**
1. 模型 Dock、SessionStore 快照身份和循环布局由 Unit；原生 NSWindow/PanelContentView 重挂载、弱引用销毁、终端真实 PTY、WKWebView 页面状态、保存冲突和内存释放归 P2 Integration。完整 App 仅检查独有的真实登录窗口/前台焦点、Finder/LaunchServices 路由、窗口关闭/恢复、Settings 快捷键、WebKit/Ghostty 系统拖放与用户可见结果。
2. WorkspaceRetention 的五轮×五次文件 Tab 开关验证的是 UI/磁盘一致性，**不能冒充内存泄漏验收**；真正内存释放需弱引用和 Release 堆证据。重复开关参数由组件/Integration 承接，只留必要的一次完整窗口生命周期路径。不同 Finder→WebKit 文件上传与 Finder→Ghostty 粘贴不回车属于独有系统入口，都保留。
3. 检查 WorkspaceSmoke、WorkspaceFiles 和 WorkspaceDock 里是否反复证明同一次冷启动→命令面板→焦点恢复；只留一条真正完整启动链，其它焦点状态由 P1/Native Component 支撑。双窗口“实际上激活的 key window”必须从真实用户动作验证，绝不靠窗口索引或仅创建第二窗口推断。
4. P1–P4 完成后用 Xcode 实际枚举全部新 Unit/Integration/UI 方法，与原始 86/463/133 逐项对账，不以搬目录/同类巨型 E2E/skip 假装提速。仅在整个计划验证和清理通过后更新 docs/testing.md 中**现行**测试选择与职责；任务过程写 audit，不把阶段数据复制进永久文档。

**Verify:** 受影响类定点 make test:DockWorkspaceTests,PanelContextTests,SessionStoreTests,NativePaneRetentionIntegrationTests,FinderDeliveryIntegrationTests,WindowOwnershipIntegrationTests,WindowCloseIntegrationTests；真实 GUI 运行改变的 Dock/Settings/Files/Finder/Ghostty/WebKit/窗口关闭和重启路径。完成时根据 docs/testing.md 执行 make build、make build:ui、签名与必要全量 make test；完整 UI 套件只有具备独占图形会话和测试授权时运行并记录执行项数/退出码，CI 全量由原 workflow 独立验收。没有环境的 SSH、macOS15.6、实体触控板/显示缩放/中文 IME 必须按功能逐项说明 Gate 影响，不冒充全绿。

**Commit:** Workspace/UI 改动单独提交，审计记录全部旧 UI 133 项的保留/替代/归属和真实成本；不为统计创建新的 runner/CI 智能测试机制。

## Phase Audit

在 audit-p4.md 核销 26+22+19=67 项，并汇总原 **Unit 86 / Integration 463 / UI 133** 的每个方法去向、最终 Xcode 实际发现数、**Unit / Integration / UI 占比**、测试执行结果、真实 Git/Window/进程及完整 App 启动次数与可比耗时。**最终必须呈现大量 Unit、明显较少 Integration、极少 E2E 的形状**；约 70/20/10 仅为计划检视方向，不是为达标增加空 Unit 或删独有系统合同的许可。若只是 UI 减至 30–50 而 Integration 仍约 400+，明确 **No-Go**，不能把某个 GUI 通过冒充整体金字塔完成。
