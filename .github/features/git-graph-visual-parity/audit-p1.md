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

## 发现 F-15

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/RecentCommitsView.swift:837`
- 摘要：`固定图谱轨道色与 60 种内置 Ghostty 主题的背景重叠，黄色在 TokyoNight Day 对比仅1.17:1`
- 风险：`当前所有线条背景描边颜色与 Theme.sidebar 一致，12 色中多种与浅色主题背景几乎同色，720 个主题/轨道色组合中124个对比度低于2:1；节点与 Merge 路径不可辨认，不满足图谱在所支持主题下的可读性约束`
- 预期修复：`沿唯一 CommitGraphRails Canvas 绘图路径，在轨道色和当前主题 sidebar 实际背景对比不足3:1时才用高对比黑/白 1pt 细底衬；轨道及节点保留原始12色与真实父边，不添加主题配置或独立第二色盘；每个 Canvas 绘制只计算12色一次`
- 验证：`测试先基于现有60个内置主题×12调色板720个组合确认低对比场景；在 NativeUI 添加全部720组合的路径/衬线对比度判定与浅/深绘制测试；运行 Git Graph UI、图谱、完整401+授权 SSH、Debug+Release签名。`
- 解决证据：`Red: read-only analyze all built-in Kero Ghostty themes (60) ×12 palette (720), 124 graph path vs actual theme sidebar backgrounds <2:1, lowest TokyoNight Day yellow 1.169:1. Root fix 603ced3: existing CommitGraphRails.Canvas renders a high-contrast 1pt underlying halo only if path contrast <3:1, for all link/HEAD/Stash nodes/expanded bottom rails, retaining 12 exact path colors; helper reused existing sRGB luminance. Green: RecentCommitsViewTests 24/24, new 720-combination contrast assertions with actual Theme.commonDarkThemes + commonLightThemes and other native click/scroll/menu tests. Logs /tmp/kero-graph-audit-60theme-720colors-20261017.log /tmp/kero-graph-audit-theme-postpatch-final-20261017.log; no user theme settings modified.`
- 后续产品决策（2026-10-17）：用户明确要求取消黑／白对比度轮廓；已撤销 `603ced3` 新增的全部描边、颜色判定、专用断言及说明文案。本条仅保留当时的历史审计证据，**当前不再提供或要求自动高对比度描边**。


## 发现 F-14

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/CommitGraphLayout.swift:104`
- 摘要：`深度分页的 Merge 轨道每条边重复逐行逐 Link 判断是否可用，Debug 5000 行/150 车道布局中位 4.72 秒`
- 风险：`RecentCommitsView.body 每次状态/UI 更新都会重新构造布局；现有 clear(lane) 对所有中间行及已添加的链接重复逐层扫描，3000 行/100 车道中位 1.46s，5000/150 达 4.72s，造成真实 UI 主线程卡顿风险`
- 预期修复：`仅在 CommitGraphLayout.init 内建立临时车道占用 IndexSet，节点先占位，生成每条父边时把两端及中间区间一次性登记；clear 由区间相交代替逐行逐 Link 检索，移除旧重复扫描逻辑，不加跨刷新状态/缓存或新图谱模型`
- 验证：`先留存当前同生产 Swift 源码构建的 1001/31、3000/100、5000/150 Debug+Release 中位耗时日志；修复后相同 fixture 30 次热操作中位/p95/最差对比，22+ graph/test、随机 DAG 真实父边/避障/分页/Stash、401+ 本机及授权 Windows SSH 全量测试、Release 构建签名`
- 解决证据：`d615831 时原生产源码为基线：同fixture Onone Debug 1001/31=75.4ms、3000/100=1.459s、5000/150=4.716s，中间多段图谱链接扫描为根因。98f2c2a 用仅构造期间的 IndexSet 占用区间替换 clear(lane) 嵌套扫描，不新增永久缓存；绿测23/23(新增5000/150父边/避障/重复稳定性)；优化后同样测量 Debug中位38.7ms、437.7ms、996.1ms，Release-like6.2ms、58.9ms、125.9ms。旧/新生产源码经812组随机包括Stash/缺页/DAG的节点、每行links、bottomRails和knownHeadHistory逐值完全相等。日志 /tmp/kero-graph-large-layout-*-20261017.log /tmp/kero-graph-layout-equivalence-*。`


## 发现 F-13

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/RecentCommitsView.swift:783`
- 摘要：`100+ 图谱车道时最小 1pt 间距让轨道区超过侧栏，237 车道下提交标题只剩 8pt 且 1.6 倍字体下完全被挤走`
- 风险：`计划承诺窄侧栏不整体横向滚动并尽量保持提交标题可读；现有 spacing 的 max(1,...) 使 gutter 不能按 34% 侧栏上限收缩，极端分支下无法显示或访问提交内容，真实用户路径受阻`
- 预期修复：`只在 CommitGraphRails.spacing 的唯一布局处计算非负自适应间距并严格约束总 gutter；保留全部真实 DAG 与点击/菜单路径，不添加持久色盘、第二绘制路径或裁断父关系；过密轨道仍应诚实记录视觉重叠的物理上限`
- 验证：`对 260/400/800pt、0.8/1/1.6/2 倍字体、0/1/12/30/100/237/1000 lanes 逐组合对照原生产公式先 Red，Green 断言 gutter 上限与可用提交标题空间，随后 NativeUI、图谱、全量 401 Git/Windows SSH 和 Release 构建验签`
- 解决证据：`旧 spacing 1pt 下 260pt宽、237车道 gutter=252pt（1.6x字体403.2pt），XCTest 新160组合回归先 Red；根因更改 in d615831，仅允许非负间距而不另建渲染器，Red→Green：RecentCommitsViewTests 23/23；6个真实NSHostingView组合（237车道、浅/深、260/400pt、1/1.6/2x）标题可视滚动区域仍在侧栏内；docs/ui.md 同提交。日志 /tmp/kero-graph-density-red-20261017.log /tmp/kero-graph-density-native-green-20261017.log。`


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

## 2026-10-17 追加极端条件审查（独立于本文件既有结论）

- **F-13 / `d615831`**：单个 `CommitGraphRails.spacing` 在车道多于约 100 时仍强制每条至少 1pt。原代码实际算出 260pt 侧栏、237 车道时图谱宽 252pt，字体 1.6x 时 403.2pt，标题消失；Red 的原生 XCTest 包含 160 个窗口宽度/字号/车道数组合。仅将最小 `spacing` 由 1pt 改为 0pt，既没有删掉真实父边，也没有引入截断图谱的兼容渲染器。Green：同 160 组合通过；NativeUI 237 车道，浅/深两主题与 260pt/400pt + 1x/1.6x/2x 字号六组真实 NSHostingView 均保留可见标题滚动区域。`RecentCommitsViewTests` 23/23，日志 `/tmp/kero-graph-density-red-20261017.log`、`/tmp/kero-graph-density-native-green-20261017.log`。
- **F-14 / `98f2c2a`**：原布局在排每条 Merge 父边时逐行扫描所有现存 Link 判空，重复成本随历史页数和车道数放大。直接用原生产源码 Debug 测量 1001/31 为75.4ms、3000/100 为1.459s、5000/150 为4.716s（中位）。替换成同一个 `CommitGraphLayout.init` 内临时 `IndexSet` 车道占用区间，无跨刷新状态/第二图谱缓存，删除逐行逐 Link 扫描。新实现分别 38.7ms、437.7ms、996.1ms；同输入 Release 优化版 6.2ms、58.9ms、125.9ms（基线原版 6.5ms、72.3ms、178.1ms）。23/23 DAG 单测，额外用**原源码与新源码各自独立编译**跑 812 组确定性 DAG/缺页/Stash/多父历史，规范化比对完整 rows/laneCount/links/bottomRails/knownHeadHistory，812/812 **逐值一致**。5k Debug 约1s 与237条并行轨道不可完全肉眼分辨是已声明的规模上限，不以性能修复冒充可阅读无限车道。测试源只在 `/tmp`，日志 `/tmp/kero-graph-large-layout-{debug,release}{,-green}-20261017.log`，未新增永久 profiler。
- **F-15 / `603ced3`**：从项目真正提供的60个 Ghostty 浅/深主题及12路径色遍历720种背景/轨道组合，发现124种小于2:1，最差TokyoNight Day上的黄线1.169:1；之前使用和背景相同颜色绘制底衬，线条几乎不可见。保留12色路径身份不变；仅当路径对比<3:1时，在**同一个** `CommitGraphRails.Canvas` 用背景对比明显的黑/白细衬绘制 path、HEAD/Stash 节点及展开文件行 `bottomRails`，每次 Canvas 绘制只计算12种底衬一次，沿用原有 sRGB 亮度公式且不更改用户主题配置。Green：`RecentCommitsViewTests` 24/24（720组合逐项验证路径或底衬能达3:1，图谱/Ref/Stash点击及横滚均通过），日志 `/tmp/kero-graph-audit-theme-postpatch-final-20261017.log`。这是原生宿主 + 主题模型证据，不冒充60个主题均有人眼截图审阅。
- **P2/P3 跨阶段补充 / `8b60625`**：新的临时真实 Git SHA256 仓库通过真实 `GitStatusModel.sync` 检查 64位 SHA、双父 Merge、中文逗号名称分支/Tag、`origin/HEAD`/`origin/ALIAS` 符号别名与真实非符号 `upstream/HEAD`，连真实 `CommitGraphLayout.knownHeadHistory` 一起校验。`GitStatusModelTests` 27/27；不靠虚拟 Git log 假数据证实。日志 `/tmp/kero-graph-sha256-integrated-20261017.log`。临时 Git repo 在 test defer 内删除。

**新增测试分层边界：** 图谱计算/随机拓扑、真实 Git IO、原生 NSHostingView/主题模型各自检查了最终数据或控件几何。macOS 15.6 真实运行时及正在使用中的 Kero 正式进程没有被擅自更改；不同 Retina 屏幕缩放、所有自定义 Ghostty 主题的人眼截图和完整独立 App 鼠标操作仍需专用无干扰图形测试会话，不能把本轮单元/原生宿主当作全场景人工 E2E。

### 2026-10-17 极端条件最终自动化复验

在最终隔离测试宿主修复 `e5c82e5` 后，授权 Windows SSH 完整 `make test` 重新返回 **407/407 passed，0 failed，0 skipped，退出码 0**，`xcresult` 状态 Passed。新增 5k 行/150 车道确定性拓扑压力、160 个视口/字体/车道组合、720 个主题/路径色组合、真实 Git SHA-256 Merge 均实测执行并通过；独立程序另完成 812 个随机 DAG 与旧算法逐值一致性比较。相应测试环境：macOS 27.2 arm64 + 授权 Windows SSH，最低 macOS 15.6 和专用 GUI 人工 E2E 仍属 P3 的显式 Deferred 边界。
