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

## Gate（是否允许进入下一阶段）

- 结论：**`No-Go`（仅指完整阶段回归最终验收；两项 P4 功能已实现、独立提交及安装）**。
- 理由：Git 焦点行为的原生 GUI 与针对性回归已通过，但全量 XCTest 仍有未定因的旧编辑器释放用例失败，无法据此称全部环境和极端情况已通过。

## 最终状态与剩余风险

- 当前状态：`Open`（功能代码已完成，阶段 Gate 未放行）。
- 剩余风险：旧 NSTextView 的测试顺序／生命周期释放不确定性；八项授权 SSH 联机用例、macOS 15.6、实体触控板和完整 VoiceOver 缺位。后续优先定位导致 `PaneRetentionTests.swift:1010` 的实际强引用来源，取得 Red→Green 后重跑完整 XCTest，再更新 Gate。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

