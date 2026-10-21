# Audit P4 - focus-navigation

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/focus-navigation/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 Git Changes 文件行和 Diff 焦点
- [x] P4-T2 Git Graph 行焦点与内部输入焦点

## 任务到文件的映射

- P4-T1（`474a46a`）：`Bailey/Git/GitPanel.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/Workspace/{TerminalManager,Project}.swift`；`GitWorkspaceMenuTests`、`DockWorkspaceTests`、`TreeRowHitTestingTests`；`docs/features/{git,dock}.md` 与 `docs/ui.md`。
- P4-T2（`3de8241`）：`Bailey/Git/{RecentCommitsView,GitPanel}.swift`、`Bailey/Workspace/{TerminalManager,Project}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`；`RecentCommitsViewTests`、`GitHistoryFileTests`、`GitWorkspaceMenuTests`、`WorkspaceWindowIsolationTests`；`docs/features/{git,dock}.md` 与 `docs/ui.md`。

## 发现项

## 发现 F-08

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitPanel.swift:2466`
- 摘要：`切换项目后旧 Git Changes 行内 Stage 按钮仍可写入非活动仓库索引`
- 风险：`已实际修改用户不再操作的仓库 index，原生双项目回归证明 first.txt 被错误暂存`
- 预期修复：`统一从 GitPanel 当前项目与面板目标判断写操作资格，拒绝已切换的旧 UI 回调；保留 GitStatusModel 自身快照复核`
- 验证：`Red: /tmp/bailey-focus-p4-red4.log；同一原生测试旧 Stage 按钮造成 Git diff --cached --name-only 输出 first.txt`
- 解决证据：`Red /tmp/bailey-focus-p4-red4.log: 切换项目后旧 Stage 按钮使 git diff --cached --name-only 包含 first.txt；Green /tmp/bailey-focus-p4-green1.log: index 不变；最终 /tmp/bailey-focus-p4-final-targeted.log: 104/0。`


## 发现 F-07

- 任务：`P4-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitPanel.swift:1805`
- 摘要：`旧 Git Graph 历史文件行在项目切换后仍打开到当前新项目`
- 风险：`跨项目产生错误历史 DiffTab；双项目原生测试证明旧 Graph 点击使新项目标签数量 1→2`
- 预期修复：`在 Git Graph 浏览回调统一检查当前项目与面板目标归属，不建立另一套焦点/仓库缓存`
- 验证：`make test ONLY_TESTING=BaileyTests/GitWorkspaceMenuTests/testStaleGitChangeClickCannotOpenDiffInAnotherProject；Red: /tmp/bailey-focus-p4-red3.log（Graph 1→2）`
- 解决证据：`Red /tmp/bailey-focus-p4-red3.log: Graph 历史文件使新项目 DiffTab 1→2；Green /tmp/bailey-focus-p4-green1.log: 1/0；最终原生 Graph 43/0、P4 相关测试总计 104/0。`


## 发现 F-06

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitPanel.swift:1990`
- 摘要：`旧 Git Changes 文件行在切换项目后仍通过 TerminalManager 当前项目打开旧仓库 Diff`
- 风险：`跨项目混淆内容与仓库/机器后端，当前项目新增错误 DiffTab；原生双项目测试实际出现 0→1 标签`
- 预期修复：`在 Git Changes 行浏览入口验证面板所属 Project 仍是 TerminalManager.selectedProject，失效立即拒绝并保留当前项目`
- 验证：`make test ONLY_TESTING=BaileyTests/GitWorkspaceMenuTests/testStaleGitChangeClickCannotOpenDiffInAnotherProject；Red: /tmp/bailey-focus-p4-red3.log（变化行触发 0→1）`
- 解决证据：`Red /tmp/bailey-focus-p4-red3.log: Changes 0→1 错误 DiffTab；Green /tmp/bailey-focus-p4-green1.log: 1/0；最终 /tmp/bailey-focus-p4-final-targeted.log: 104/0。GitPanel.hasCurrentPanelTarget 验证当前 Project 与 PanelContext。`


## 发现 F-05

- 任务：`P4-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreePanel.swift:185`
- 摘要：`Palette 覆盖时切换 Files 会请求原生键盘焦点，可能抢走命令面板搜索框`
- 风险：`ToolPanelView 的 Files 活动组焦点判定未区分命令面板，FileTreeScrollView.focusSelectedRow 在窗口为 key 且 App 活动时调用 makeFirstResponder，覆盖模态搜索框的输入；退出面板后此前 Git 行已不是可恢复目标`
- 预期修复：`在 Files/Git 自动焦点入口尊重正在显示的命令面板，并在其关闭后由实际可见工具树恢复焦点；不改变显式文件点击与原生 TextField 所有权`
- 验证：`make test ONLY_TESTING=BaileyTests/WorkspaceWindowIsolationTests + 真正 key-window 的 Palette/Files/Git 交接验收`
- 解决证据：`2026-10-21 19:34 make test: 604 tests, 0 failures, 8 authorized SSH skipped; key-window Palette -> Files -> dismiss -> arrow navigation test PASSED; native Files<->Git active tree ownership test PASSED; targeted 24/0; 21 PaneRetention/0. Code: FileTreePanel native field editor priority, TerminalManager restores valid active TreeKeyboardView only.`


- P4 本身尚无经复现证实的未修复焦点功能缺陷。Graph 的提交、目录和文件选择不再借用展开状态；Git Changes 和 Graph 共享原生行机制，但拥有各自的选中状态与第一响应者。
- **全量回归的外部阻断（非已证实 P4 回归）：** `PaneRetentionTests.swift:1010` 的旧 `NSTextView` 弱引用有时未能在 10 秒内释放。连续两次全量运行分别出现 2 项及 1 项生命周期失败；仅运行对应两项、或者运行此前 5 项最小前置组合时通过，而完整 `PaneRetentionTests` 类（21 项）出现 1 项失败。已排除简单的必现点击/键码错误；尚未证明真实持有者及是否是系统运行时延迟，不因与本阶段源码不同而冒称问题已解决。**不延长超时、不修改无关编辑器逻辑来伪造 Green。**

## 修复日志

- `474a46a`：Git Changes 的单击、Space、Return 浏览 Diff 不激活另一组；当前行仅在列表真正聚焦时描边；Stage/Unstage/Discard 等独立按钮不触发 Diff。
- `3de8241`：Git Graph 用稳定提交／仓库／机器范围／文件分组／路径身份，分别追踪图谱行与展开集合；原生方向键及 Space/Return 复用已有点击动作，历史／工作树 Diff 预览不夺键盘焦点；输入框与右键仍由原生输入控件拥有焦点。未移植 GPUI 或增加全局 Focus Manager。
- 对原生资源释放失败，已开展全量、整类、两项隔离及 5 项前置组合复验；目前未取得可靠的共同持有路径，作为独立故障保留。

## 验证日志

- **受影响回归：** `make test` 限定 `GitWorkspaceMenuTests`、`RecentCommitsViewTests`、`GitHistoryFileTests` 和窗口焦点相关测试，100 项／0 失败，见 `/tmp/bailey-p4-focus-final-affected.log`；新增 Graph 单击／Space、同一路径分期 Diff、清洁仓库焦点、原生 TextField/输入框和 Dock 工具切换测试均通过。Git Changes Space 曾 Red（没有打开 Diff），现 Green；历史与 worktree Diff 的实际旧／新文本、Stage／Unstage、HEAD/index 和本地文件内容有独立断言。
- **完整 XCTest：** `/tmp/bailey-p4-focus-clean-final-complete.log`：`make test` 597 项，8 跳过，**1 失败，退出码 2**，失败为 `PaneRetentionTests.testEditorRetainsScrollAndReleasesRetiredNativeResources` 弱引用释放超时。更早的 `/tmp/bailey-p4-focus-final-complete.log` 同为 597 项、8 跳过，有两个资源生命周期用例失败。`make test ONLY_TESTING='BaileyTests/PaneRetentionTests/testEditorRetainsScrollAndReleasesRetiredNativeResources BaileyTests/PaneRetentionTests/testFiveConcurrentNativeEditorsReleaseDocumentAndParsingTasks'` → 2/0，见 `/tmp/bailey-p4-retention-isolated-recheck.log`；完整 `PaneRetentionTests` 21/1；前置 5 项组合 5/0。**不得宣称全套通过。**
- **构建／验签／安装：** `make build` 成功；`codesign --verify --deep --strict` 对 Debug 产物、同卷暂存 App 和安装后的 `/Applications/Bailey.app` 均通过；安装后 `bailey.debug.dylib` SHA-256 与编译包相同（`96771ab765138de4fd8d22b8b60ae02872134c5fd133546af819f79327045020`）。正在运行的正式进程 PID `96412` 未重启，新代码须下次自行重新打开 App 后加载；无推送。
- **本机实际交互：** 隔离 Bailey 原生 GUI 验收：Git Changes 单击、↓／Space，Graph 点击提交展开与行描边，方向键与 Space 浏览历史文件及 Diff 内容，过滤框文字输入由原生输入控件接收。截图 `/tmp/bailey-focus-verify.kniA3O/p4-order-gui-after-{down,space}.png`、`p4-e2e-graph-click-after.png`、`p4-filter-gui-typed-after.png`。未将截图观察代替 Git index/HEAD 的原生集成断言。
- **条件跳过（共 8 项）：** Git 外部刷新、交互 Rebase、Windows Git 写入/归档和 Worktree 4 类远程联机用例；Windows 文件批量列表、容量保存、目录重命名和 Git 断线恢复 4 类联机用例。专用测试主机未被显式授权，不能借用用户 SSH master；因此真实 Windows SSH 交互、断线和写入操作未被这些测试确认。具体八个 XCTest 名称、替代 scope／模拟远端证据与授权测试主机补验方法见 [`audit-p3.md`](audit-p3.md)；不能将跳过计为通过。
- **其它环境缺口：** 无 macOS 15.6 真机、实体触控板与完整 VoiceOver／所有物理显示组合。影响是最低系统和真实辅助输入效果仍有边界；已用当前 macOS 的原生 `NSWindow` 事件、同尺寸明暗和缩放 GUI、共享行命中与无障碍用例作替代，但不是这些缺位环境的实测结果。
- **文档与状态：** `docs/features/git.md`、`docs/features/dock.md`、`docs/ui.md` 已写入 Space／Return／展开与选择分离、单层焦点边框和 Diff 预览语义。`todo.toml` 的 P4 两项对应提交已回填；`todo validate`、`git diff --check` 通过。Feature 计划及审计保留本地，不混入两个功能提交。

## 后续视觉缺陷修复（2026-10-21）

- **根因：** 共享 `TreeRowSurface` 曾由 `focused` 同时绘制浅灰底与主题色边框，Git 的键盘游标因此带动灰底；之前 `focused && !focusRing` 只遮住有描边的情形。浅／深模式下，无描边 Focus 的 Red 像素差分别为 `0.103`／`0.153`。
- **修复 `fe2fa76`：** 删除共享行的 `focused` 输入和底色分支：`selected` 只绘制当前文件／Diff 或展开提交的灰底，`focusRing` 只绘制键盘边框，Hover 仍只由 `.onHover` 绘制；保留 Files 新建草稿的原浅灰底及既有 AX 导航语义。Git Changes 与 Graph 使用实际展示的 Diff 来源计算 `selected`，而非键盘行身份。
- **验证：** 浅／深像素、Git Changes 同路径暂存／未暂存 Diff、Git Graph 历史 Diff 及原生键盘回归 Red→Green；受影响 155 项／0 失败，`make test` **600 项、8 条条件跳过、0 失败、退出码 0**（`/tmp/bailey-focus-separation-full-final.log`），本轮 `PaneRetentionTests` 21 项亦全部通过；Debug 签名、整包安装 `/Applications/Bailey.app` 与新包 dylib SHA-256 一致。原正式进程 PID `97289` 未重启，当前 `crh` 未推送。
- **边界：** 离屏 XCTest 的合成鼠标进入事件无法驱动 SwiftUI `.onHover`，不将其冒充真实 Hover 验收；共享桌面的前台为 Helium，未抢占其指针与键盘。实际 Hover 指针行为、macOS 15.6 与 8 条 SSH 条件跳过仍待对应环境补验。旧编辑器释放超时的历史复现原因未被本次视觉修复证明消失，因此原 No-Go 门禁暂不改判。

## Gate（是否允许进入下一阶段）

- 结论：**`No-Go`（仅指完整阶段回归最终验收；两项 P4 功能已实现、独立提交及安装）**。
- 理由：Git 焦点行为的原生 GUI 与针对性回归已通过，但全量 XCTest 仍有未定因的旧编辑器释放用例失败，无法据此称全部环境和极端情况已通过。

## 最终状态与剩余风险

- 当前状态：`Open`（功能代码已完成，阶段 Gate 未放行）。
- 剩余风险：旧 NSTextView 的测试顺序／生命周期释放不确定性；八项授权 SSH 联机用例、macOS 15.6、实体触控板和完整 VoiceOver 缺位。后续优先定位导致 `PaneRetentionTests.swift:1010` 的实际强引用来源，取得 Red→Green 后重跑完整 XCTest，再更新 Gate。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-21 独立按提交复核（不采用上方历史 Gate 作依据）

| Task | 独立核对的提交 | 当前真实调用链与不变量 |
| --- | --- | --- |
| P4-T1 | `474a46a` | Git Changes 的唯一当前行键由 scope/repository/section/path 确定；`TreeKeyboardHost` 接 ↑↓←→、Space/Return 及 Escape，打开 Diff 经 `ToolPanelView → TerminalManager → Project.openDiff(activating:false)`，不强抢 Git 原生响应者；Stage/Unstage/Discard 是独立按钮。 |
| P4-T2 | `3de8241`、`fe2fa76` | `RecentCommitsView` 的图谱行游标、commit 展开集合、已显示 Diff 灰底和 Focus 主题描边分别拥有不同状态；Graph Space/Return 按当前提交/目录/历史文件动作分发，历史 Diff 经 `openCommitDiff(activating:false)`，输入框保留原生 first responder。 |

逐个阅读 GitChanges → GitIndex/工作区、Graph → HistoricalDiff → `DiffTab` 原生加载以及 Workspace 的调用链。已有真实临时仓库的 `GitWorkspaceMenuTests` 验证同路径 Staged/Unstaged 内容正确、Stage/Unstage 只在显式操作时修改 index、Head/工作区保持正确；`RecentCommitsViewTests` 验证单击与 Space 展开、历史浏览、灰底与描边独立。图谱在 repo/scope 不匹配时 `GitPanel` 只显示仓库查找占位而非旧图谱，不能据旧调用方缺少重复判断臆断跨仓库错误。此前 `PaneRetentionTests` 旧编辑器释放超时属于需单独复核的间歇性资源回收问题，尚不能仅因一次新的全套测试通过就声称原因消失；本轮 Gate 在最终压力与全量验证后另记。

## 2026-10-21 21:03 完整回归与退休文档补验

- **功能核对：** P4-T1 `GitPanel.handleGitChangeKey` 的 Space（49）／Return（36、76）、单击 Diff 浏览和分组文件身份仍在真实入口；P4-T2 `RecentCommitsView.handleGraphKey` 的提交、目录、历史／工作树文件 Space、Return 和方向键仍独立于展开状态。`ToolPanelView → TerminalManager → Project` 的浏览 Diff 入口不主动激活仍可见的编辑器组。P4 两项代码提交不变。
- **最近失败原始记录：** `/tmp/bailey-focus-audit-p4-full-final-next.log` 在 20:11 运行 `make test`：605 项、8 跳过、11 条断言失败（只涉及 `PaneRetentionTests` 的两项测试；五编辑器用例中多轮重复报告同类失败），退出码非零。旧 NSTextView／FileTab 是否在某种 XCTest 顺序下被持续强持有，仍未取得稳定可重复的引用链。
- **本轮完整回归：** `/tmp/bailey-focus-p4-current-complete-validation.log`：`make test` **605 项、0 失败、12 跳过、退出码 0**。其中 8 项是缺少明确授权的 Windows SSH 测试专用主机；另 4 项是需要 XCTest 窗口实际成为前台 key window 的 Files／Git／Palette 焦点测试，为保护正在使用的 Bailey 而按用例前提跳过。此前已有 108 项原生窗口针对性回归、4 个需要前台窗口的条件跳过、0 失败，不能将跳过视为真实前台验证通过。
- **实际根因之一与 Red→Green：** 退休旧文本版本时，`SourceTextEditor.Coordinator.retireObsoleteDocument()` 虽解除旧文档和回调，仍允许退役 `NSTextView` 编辑，且其独有 `UndoManager` 继续持有指向旧 `NSTextStorage` 的 Redo。加入“旧编辑 → Undo（留 Redo）→ 外部磁盘重载”测试后，移除修复会在禁用编辑与清理 Redo 两项断言上失败（`/tmp/bailey-p4-retired-undo-red.log`）；恢复仅在真正退役时 `isEditable=false` 和 `undoManager.removeAllActions()` 后，退休文档、五编辑器释放和 Dock 重挂载 Undo 3 项／0 失败（`/tmp/bailey-p4-retired-undo-restored-green.log`）。生产代码、回归和 editor 文档以 `d10c4a6` 原子提交，普通 Dock 标签重挂载不会清空 Undo。
- **压力与并发：** `PaneRetentionTests` 21 项／0 失败，连续三轮 `/tmp/bailey-p4-retention-stress-after-build-{1,2,3}.log` 每轮 21／0；此前首次压力启动失败是并行 Release 构建持有共享 `build.db`，未执行 XCTest，不算资源释放失败或通过。五编辑器直接关闭窗口不走上述 `retireObsoleteDocument()` 清理路径，因此不能据退休 Undo 的 Green 断言证明该间歇性释放失败已根治。
- **环境边界与 Gate：** 当前机器实际 GUI、已授权本地临时仓库及原生响应者的既有测试提供功能证据；上述 SSH 8 项、前台 key-window 4 项、macOS 15.6 真机、真实触控板与完整 VoiceOver 仍无对应环境实测。旧释放失败未获得稳定持有链，故原审计 **No-Go 暂不改判**（不否认两项已交付的 Git 焦点功能）。未强行中止、重启用户正式 Bailey 或借用 SSH master；不推送或发布本轮提交。

## 2026-10-21 P4 独立 Red→Green 审查（F-06～F-08）

- **逐提交核实：** `474a46a` 的 Changes 文件行、Space/Return、Stage/Unstage 仍由 `GitPanel → GitStatusModel / DiffTab` 实际调用；`3de8241` 的 Graph 文件行、方向键、Space/Return 由 `RecentCommitsView → GitPanel → Project.openCommitDiff` 执行。`fe2fa76` 的焦点视觉与真正原生 first responder 分离，以上路径都不是脱离界面的孤立代码。
- **之前审计判断已被反证：** 即使 `GitStatusModel` 对旧项目 A 的仓库快照仍然有效，`TerminalManager.selectedProject` 已切到 B 时，旧文件行照样可以执行回调。新增双项目原生窗口测试先后复现：Changes 在 B 新增错误 DiffTab（0→1）、Graph 历史文件继续新增错误 DiffTab（1→2）、旧 Stage 按钮实际暂存 A 的 `first.txt`。失败原始证据：`/tmp/bailey-focus-p4-red3.log`、`/tmp/bailey-focus-p4-red4.log`，不能仅凭旧面板一般会隐藏而否认回调竞争。
- **根因修复：** `GitPanel.hasCurrentPanelTarget` 统一加入当前 Project 身份核对，Changes／Graph 浏览、行内写操作、弃置请求及确认均使用该实时入口检查；GitStatusModel 原有仓库、索引、HEAD 与快照检查仍保留。没有新增 generation、轮询、后台协调器或兼容分支；无法证明冗余的共用 TreeKeyboardView/Owner、按键焦点与 Diff 展示态不删除。
- **验证：** Red 三处断言失败；Green `/tmp/bailey-focus-p4-green1.log`：1 项／0 失败；含真实本地 Git 内容和原生 AppKit 键盘、鼠标事件的最终 `/tmp/bailey-focus-p4-final-targeted.log`：**104 项／0 失败**，包括 `PaneRetentionTests` 21 项。`/tmp/bailey-focus-p4-tree.log` 另核对 Changes Tree、Graph Tree 的目录展开、收起、Space/Return、真实 Diff、索引零写入，2 项／0 失败（已包含在最终 104 项）。
- **全量与并行边界：** 本轮隔离目录执行 `make test`（`/tmp/bailey-focus-p4-full.log`）在多项 P4、GitStatusModel、PaneRetention、深色／浅色 Graph 等套件通过后，于 `WorkspaceWindowCloseTests.testBackgroundProjectDirtyCloseSheetStaysInItsOwningWindow:221` 出现窗口测试断言失败，并卡在系统 Sheet 处理；仅终止本轮测试命令。该测试文件由其他审查任务并行修改，不能把这次全套称为成功，也尚不能把该断言归因于 P4。
- **环境与 Gate：** macOS 27.2、真实 NSWindow/NSHostingView 键盘和鼠标、深浅外观、宽窄 Graph、多工作树/多历史状态、本地索引均有实际测试；未覆盖独立 macOS 15.6 真机、真实触控板/VoiceOver、需明确授权的 SSH 实机焦点以及对用户正式安装包的 E2E。**F-06～F-08 均已解决；项目全量 Gate 仍为 No-Go**，待无关卡住的窗口测试消除并补齐必要环境；不越界修改 P1～P3 或重启正式 Bailey。
- **构建与签名：** `make build:release DERIVED_DATA=build/DerivedData-focus-p4-review SOURCE_PACKAGES=build/SourcePackages` 退出码 0，`BUILD SUCCEEDED`，并通过 `codesign --verify --deep --strict`，见 `/tmp/bailey-focus-p4-release.log`。仅使用独立 DerivedData，没有替换用户正式 App。
- **原子提交：** P4 的 `GitPanel.swift`、两份 Git 原生测试、`docs/features/git.md` 和本审计文档合并为同一提交；其他 P 的未提交改动保持不变。
