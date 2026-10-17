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

## 发现 F-12

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/CommitGraphLayout.swift:60`
- 摘要：`无基础节点的多条 Stash 错误长期预约不可见车道`
- 风险：`Stash 基础提交缺页时无边可绘，但将每条 stash 车道预约至 commits.count；多条 Stash 可把窄侧栏图谱挤到几乎没有标题空间`
- 预期修复：`只有普通提交的未知父节点才跨缺页保留路径预约；Stash base 不可见时不生成跨页预约，base 出现时按现有已加载关系重新布局`
- 验证：`新增 40 条 stash 在 base 缺页与加载后的布局/身份测试，先 Red 后 Green；保留原有 Stash 集成测试`
- 解决证据：`Red: testUnloadedStashBasesDoNotReserveInvisibleRails observed 41 invisible lanes vs expected 2; Green: graph 22/22, actual Git stash integration 12/12 and native history UI 20/20. Fixed reservation root cause in commit 4b24cfa.`


## 发现 F-11

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/CommitGraphLayout.swift:108`
- 摘要：`两条互不重叠的 Merge 绕行线也会占用不同的永久新车道`
- 风险：`使用最大车道号加一，不能复用已经空闲的临时线道；不同历史 Merge 累积让车道数和侧栏图谱宽度不断膨胀，即使同时活跃的分支很少`
- 预期修复：`沿用现有 clear() 在 from/to lane 都不可用时寻找实际空闲车道，只有所有已有 lane 不可用才新开 lane；不新增另一套 lane manager`
- 验证：`新增两个不相交的 Git 多父边回归，先 Red 再 Green；保持真实父边、颜色、避障与原生布局测试`
- 解决证据：`Red: testNonoverlappingMergeDetoursReuseTheSameFreeLane observed 3 lanes vs expected 2; Green: CommitGraphLayoutTests 22/22; GitStashActionTests 12/12; RecentCommitsViewTests 20/20; source and regression commit 4b24cfa.`


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

## 本轮独立逐提交复审（2026-10-17；不采用既有 audit 结论）

- P1-T1：`todo.toml` 旧 SHA `312af32` 的内容在当前分支对应 `48be515`，两者稳定 patch-id 相同。复核 `CommitGraphLayout.init`：GitPanel→GitStatusModel.graphCommits→RecentCommitsView 确实使用此唯一布局。普通提交父边、Stash base 展示边、分页缺页、路径色、Node/Rail/Link 均与计划映射。发现非重叠 Merge 仍新开车道、缺页 Stash 长期预约两种可复现缺陷（F-11/F-12）；经新增 Red 测试后在 `4b24cfa` 同时修复，未新建兼容实现。
- P1-T2：原 SHA `8158774` 在当前分支对应 `b848abf`，patch-id 相同。`CommitGraphRails` 原生 Canvas 唯一消费 `Row.links` / `bottomRails`，当前 HEAD、Stash 和其它节点依真实 Ref/Stash 属性绘制不同形状；12 色位在 `GitGraphPalette` 唯一维护。原按 lane 固定蓝色、旧系统色与全填充节点实现已清理，不再双轨渲染。`TreeRowSurface` 和文件轨道仍保留。
- 本轮 Red：`make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests` → 22 项中新增 2 项失败，分别 3 条车道（期望 2）和 41 条车道（期望 2），证据 `/tmp/kero-graph-audit-p1-red.log`。Green：图谱 22/22、真实 Stash 12/12、原生提交行 20/20；30 次 1001 行、31 车道布局中位 0.073s，p95 0.075s，最大 0.075s，日志 `/tmp/kero-graph-audit-p1-green.log`。
- 本轮结论：P1 的两条实质缺陷均已按公共根因修复并独立提交 `4b24cfa`；无需持久化色彩缓存或通用车道管理器。全量验证另见本轮最终检查。

### 本轮额外随机极端压力检查（不替代 XCTest）

直接把**当前生产 `kero/Git/CommitGraphLayout.swift`** 以 Swift 6 编译到 `/tmp` 中的隔离一次性压力程序（只用同形状轻量输入数据，不移植/修改图谱算法），对 22 个 300 行和 5 个 1000 行确定性随机多父 DAG 进行遍历，总计 **27 组、16,022 条父边**。每一条已加载边均逐段验证相同路径颜色的真实 child→parent 起点、整段中间轨道和终点；所有 `through` 都不得穿过不相干提交节点，重复同一输入布局必须稳定。检查均通过，布局总耗时约 0.351 秒（隔离 Swift 优化编译，不与 App 主线程帧耗时等同），最大可构造 237 条图谱车道。测试 fixture 仅在 `/tmp`，未增加未接入 XCTest 的永久检查脚本、缓存或第二套图谱实现。

237 条车道超出本 feature 明定原生窄侧栏 30/31 车道验收规模，不能将此压力测试冒称 237 车道时全部线条/标题都能完整肉眼辨识；超高车道密度是否需要专用折叠交互属于独立产品设计问题，本次没有用裁剪车道破坏真实父边，也不增加虚假的过度围栏。

### 本轮 P1 最终 Gate（2026-10-17）

**Go（P1 所列可自动验证的范围）。** 逐提交 `48be515`/`b848abf` 已实际接入唯一 Git Graph 渲染路径；旧固定蓝色及按 lane 着色、无复用临时车道和缺页 Stash 无谓预约已从同一路径删除。F-11、F-12 Red→Green 并提交 `4b24cfa`；22/22 图谱用例及真实 Stash/NativeUI 回归全绿；额外 27 组 300/1000 节点 DAG 逐边验收 16,022 条父关系全通过。授权 Windows 全量 `make test DERIVED_DATA=build/DerivedData-graph-audit` 401/401、0 failed、0 skipped，完整命令退出 0；同目录 `make build`、严格 `codesign` 均退出 0。上述只保证 P1 确定的拓扑与 UI 组件调用；237 并行车道的有限宽度可读性没有被冒称完美。
