# P3：Git Changes 与 Git Graph 的局部状态语义

**Goal：** 使用现有共享树行和键盘输入视图，但不复制 Files 多选状态；
Git 的浏览/展开/菜单/输入拥有独立合法的局部真源。
**Non-goals：** 不改变 Git 提交图布局、Git 命令参数和仓库刷新机制。
**Approach：** 对照 VS Code `scmViewPane.ts` 的资源列表事件和
`listWidget.ts` 的 Focus/Selection/Context；沿 Bailey Git 的
显示与真实 Diff 副作用，收敛不同入口的重复转换。
**Acceptance：** Changes/Graph 中每个键盘游标与选择都有唯一真源，
切仓库清除不合法目标；右键不打开 Diff、切换提交不等于展开，
切入输入框后真实焦点正确；共享颜色/AX 无两层互相覆盖。

## P3-T1 Git Changes 状态与 Diff 打开路径

**锚点：** `Bailey/Git/GitPanel.swift` 的 `selectedChange`、
`explicitlySelectedChange`、`contextChange`、
`focusGitChanges`、`handleGitChangeKey`、`browseGitChange`、
`changedFileRows`、`row`、`directoryRow`；
`BaileyTests/Git/*`、`BaileyUITests/Git/GitChangesUITests.swift`。
**任务：** 对照 upstream SCM 行动/焦点模型，证明当前集合和游标是否各自必要，
删除重复镜像而不破坏当前 Edit/Stage/Unstage/Discard 意图；
分别验证树/列表、Folder/文件、Staged/Unstaged/Merge、
单击/Space/Return/Esc/右键、Diff 已展示但面板继续活动，
跨仓库与 SSH 的失效结果。
**验证：** 受影响 Git 宿主类 + `make build:dev`；
隔离 `GitChangesUITests`；
更新 `docs/features/git.md`、`docs/ui.md`。

## P3-T2 Git Graph 提交、历史文件和菜单目标

**锚点：** `Bailey/Git/RecentCommitsView.swift` 的 `contextRowID`、
`contextTarget(for:)`、`selectRow`、`isFocusedRow`、
`TreeKeyboardHost`、提交/历史文件/工作树/Stash 行；
`GitGraphUITests`。
**任务：** 对照 VS Code list 与树的 Context/Selection 模型，
检查一次右键只命中真实行、菜单结束清目标、点击详情不制造持久选中、
文件浏览不抢 Git 的原生输入；
把重复的行上下文转发收敛到已有本地方法，不增加新的全局 state。
**验证：** 受影响 Git 宿主类 + `make build:dev`；
隔离 `GitGraphUITests` 的多提交/历史文件/Stash/Worktree/SSH，
不同显示/焦点/菜单状态和实际 Diff 结果；更新 `docs/features/git.md`。
