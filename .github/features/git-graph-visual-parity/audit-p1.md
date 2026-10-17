# Audit P1 - git-graph-visual-parity

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/git-graph-visual-parity/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 以真实DAG分配路径颜色并消除Merge串色
- [x] P1-T2 统一图谱调色板及HEAD和Stash节点几何

## 任务到文件的映射

- P1-T1 — `312af32e1c565d2e07a9943a4642b770f8b1e6b4`
  - `kero/Git/CommitGraphLayout.swift`：把拓扑逻辑路径颜色与几何车道分离；多父 Merge 的连接沿实际父路径色；Stash 独立分配展示路径。
  - `KeroTests/Unit/Git/CommitGraphLayoutTests.swift`：真实父路径颜色、交叉避障、Octopus Merge、30 条并行路径、1000 条历史、缺页／同 OID Stash。
  - `docs/features/git.md`：更新颜色与真实连线的用户可见契约。
- P1-T2 — `8158774b2484b18f56a768bcb1b01edadeb7d4ee`
  - `kero/Git/RecentCommitsView.swift`：唯一 12 色调色板；Canvas 曲线底衬、HEAD 空心、Stash 双环、提交实心节点；展开文件沿用同一配色。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：色值与深／浅主题命中回归。
  - `docs/ui.md`：更新原生图谱渲染外观。

## 发现项

无阻塞发现项。审查了两个实现提交的改动范围、图谱唯一路径、调用者及实际原生渲染，未发现有证据支持的剩余 P1 正确性缺陷。

## 修复日志

- 本阶段无需审计补丁。两个任务都已在各自原子提交中删除被替代的固定 HEAD 蓝色、按 lane 着色与系统色循环逻辑，没有保留双轨实现。

## 验证日志

- `make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests` -> PASS，16/16（最终 P1-T1 代码）。
- `make test ONLY_TESTING=KeroTests/GitStashActionTests` -> PASS，12/12，含相同 OID 不同 selector 及真实 Stash 操作。
- `make test ONLY_TESTING=KeroTests/GitStatusModelTests` -> PASS，26/26，含真实 `--date-order`、分页和状态恢复。
- `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` -> PASS，13/13，含 12 色原生色值、两种 macOS 外观及全行／图谱点击。
- 临时 `NSHostingView` 视觉取证 -> PASS，浅／深色截图 `/tmp/kero-graph-p1-light.png` 与 `/tmp/kero-graph-p1-dark.png`，已检查蓝／粉路径、Merge 接入、HEAD 空心、Stash 双环与曲线底衬；一次性截图测试代码随后从源码移除，未加入 Git commit。
- `git diff --check` -> PASS；提交 `312af32` 仅 3 个任务文件、`8158774` 仅 3 个任务文件；既有其他 AI 的 staged／unstaged 改动未纳入两个提交。
- 当前文档归属：真实 Git 路径与颜色语义在 `docs/features/git.md`，图谱外观在 `docs/ui.md`；未更改 `AGENTS.md`、共享树、全局 Theme、Git 动作实现或项目导航。完整 `make build`／`make test`、复合标签与行布局验收属于后续阶段的整体 Gate，不冒充已通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P1 的两项功能均已实际接入、旧路清理、通过直接单元／真实 Git 集成／原生交互验证，且浅／深色视觉输出确认基本图形。剩余标签样式和提交行布局明确由 P2、P3 实施，不构成 P1 阻塞。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：本阶段截图是离屏原生窗口而非独立用户进程；当前 Ref 仍为旧彩色 Capsule、消息仍先于 Ref，必须由 P2／P3 修复并完成最终 E2E 与全量 build/test。复杂 SSH 主机不属于 P1 图谱计算的新副作用链；本阶段未单独测试真实 SSH 主机。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
