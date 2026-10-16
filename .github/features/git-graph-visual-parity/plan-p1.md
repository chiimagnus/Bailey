# P1：图谱路径、颜色与节点几何

**Goal：** 以真实提交父边维持各路径颜色和正确 Merge 走线，同时保留 Stash 到基础提交的既有**展示性**连接；以同一图谱输出驱动原生节点及曲线绘制。

**Non-goals：** 不修改 Git log 命令、SSH 刷新、Ref 菜单或业务提交模型；本阶段不实现复合 Ref 标签，也不移植上游算法源码。

**Approach：** 保留 `CommitGraphLayout` 的纯数据图谱和 `RecentCommitsView` 的原生 `Canvas`。先用确定性 DAG 证明当前以 HEAD 固定蓝色、按“起点 lane”给父子边染色造成的差异，再最小修改路径分配与画法：颜色是图谱路径的属性，车道是几何的属性，两者分开。渲染端集中维护一次 12 色参考调色板，下一阶段的 Ref 标签直接复用。

**Rules：**
- 普通提交只根据已加载的真实父边画线；Stash 经 `GitStatusModel.graphCommits` 人工接到基础提交，是明确的**展示关系**，不是其完整 Git 父图。未知父／未加载 Stash 基础节点不画虚构连接；不改 `--date-order`。
- 当前 HEAD 不是“蓝色／lane0”的别名；图谱路径的颜色不依赖分支名称或 Ref 类别。
- 保留展开历史文件后的 `bottomRails`，以及侧栏收窄时不整体横向滚动的现有契约。
- 不取消现有测试对节点避障、分页前缀和连接真实父节点的强断言；失效的具体 lane 编号可改为更恰当的结构断言，但不能删除正确性保护。
- 本阶段如改变图谱算法，须连同相应图谱展示合同及时更新 `docs/features/git.md`。

<a id="p1-t1"></a>
## P1-T1 以完整 Git DAG 分配路径颜色并消除 Merge 串色

**类型／依赖：** 实现；无前置，实现通过才进入 T2。

**当前根因与调用路径：** `GitPanel.changeList → GitStatusModel.graphCommits → RecentCommitsView.body → CommitGraphLayout.init`。`CommitGraphLayout` 先让当前 HEAD 第一父路径固定 `lane=0,color=0`，剩余路径按首次未占节点排序着色，再以 `from.lane == 0 && to.lane != 0 ? to.color : from.color` 对每条父边临时选色：颜色受节点所在几何车道污染，并非连接所归属的路径。`Row.links/bottomRails` 已是唯一画图输入；不引入第二套图谱模型。`GitStatusModel.graphCommits` 还插入独立 Stash 展示行，其 base 连接与真实提交父边要区别处理。

**文件与锚点：**
- `kero/Git/CommitGraphLayout.swift`：`init(commits:)`、`Node/Rail/Link`、父子边填充、车道避障与 `bottomRails`。
- `KeroTests/Unit/Git/CommitGraphLayoutTests.swift`：现有九类线性、Merge、交叉、分页、无 HEAD 测试。
- `KeroTests/Integration/Git/GitStatusModelTests.swift`：`testGitGraphUsesCommitDateOrderWithoutBreakingMergeParents`、实际合成仓库中的 refs/父序。仅在读取链数据被改动时扩展相应集成断言；不修改解析器以配合画图。
- 文档 owner：`docs/features/git.md` 的“刷新与显示”Git 图谱段，删除“蓝色主干”作为固定不变量的表述。

**步骤：**
1. **Red／对照：** 先用已存在的九项 `CommitGraphLayoutTests` 与真实 `git log --date-order` 记录建立绿色基线，再补明确会失败的颜色与拓扑样例：HEAD 不在第一行、多个独立 tip、非 HEAD 分支合入主线、第一／第二父互换、先后及连续 Merge、Octopus、交叉图、独立 root、部分父未加载、翻页扩展。用具体父 Hash 对应的连接端点、转弯路径色、避开其它提交点及重复刷新稳定性作断言；**同一已加载输入**必须稳定，因新 HEAD／新提交改变 DAG 时允许合理的颜色重新分配，不能要求颜色永久不变。增加确定性小规模 DAG 组合检查，不为这些 fixture 搭新随机测试框架。
2. **根本修改：** 在现有 `CommitGraphLayout.init` 内让**逻辑路径的颜色身份**与避障所用的**几何 lane**分离；按真实父序持续分配父边路径，进入已有分支的连接沿所连接分支色，而非沿 Merge 提交自己的色。中途额外避障车道仅修改几何，不得重新着色；节点允许按其最终所属主路径着色。保留 `Rail/Link/Row` 现有契约，删除以 `lane=0` 决定色彩的旧分支。不能为了造出目标图强行修改 Git 的父序或连接真实端点。
3. **颜色复用与分页：** 与上游一致，逻辑路径终止后颜色索引可复用；并存路径优先选择未被占用的调色板槽。调色板只有 12 色，超过 12 条并行路径不许承诺全局唯一色；循环复用须确定性且尽量避免紧邻同色。分页仅给已加载父边添线，已显示节点的色／lane 优先保持；如新提交／父边使拓扑本身改变，允许布局调整并在可比 fixture 说明原因。不引入颜色持久化、Ref→色缓存或后台查询。
4. **Stash 与旧路清理：** Stash 行按 selector 而非 OID 唯一；相同 OID 的多个 selector 仍是独立节点，只有基础提交在本页时才接出展示线，不穿过其它节点，右键仍只提供 Stash 操作。修改分配规则的**同一 task**删除 `loadedHead → lane0/color0` 特例、旧边着色分支及不再使用的局部变量，不建立兼容 fallback。旧测试中实际依赖 lane0=HEAD 的断言改为结构性不变量，同时保留避障与分页保护，不得删掉正确用例。
5. **完成与性能边界：** 当前 `RecentCommitsView.body` 会重建布局，每个父边的 `clear(lane)` 又可能扫描多行／多 link。用 30 条真实分页、几百条内存合成行和 30 条并行 lane 核对正确性与布局耗时；确认性能热点时在**同一个布局构造过程**消除重复线性扫描，避免触摸板滚动或持续刷新卡顿，不能靠加一套持久缓存掩盖算法成本。跑 `make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests`、`KeroTests/GitStashActionTests`，Git 读取链有变化时加 `GitStatusModelTests`；同步 `docs/features/git.md` 并原子提交，仅包含本 task 差异。

**本 task Acceptance：** 真实提交的连线只指向自身实际父节点，支线跨 Merge 前始终沿用逻辑路径色、车道绕行不变色；Stash 仅沿现有 base 展示关系连接，且相同 OID 的不同 stash 不合并；分页／缺页不造假边，同一输入稳定且无明显算法性退化。不再通过 HEAD/main 或 lane=0 硬编码蓝色。

<a id="p1-t2"></a>
## P1-T2 用统一调色板绘制圆滑曲线与 HEAD／Stash 节点

**类型／依赖：** 实现；依赖 P1-T1。

**当前根因与路径：** `RecentCommitsView.commitRow → CommitGraphRails.body` 将节点全部画成实心圆；线宽 1.6、无下层分离线，默认仅蓝＋五种 AppKit 系统色；节点颜色与 `referenceBadge` 无法共享。展开文件时 `fileRails` 复用相同绘制路径，但必须保留。

**文件与锚点：**
- `kero/Git/RecentCommitsView.swift`：`CommitGraphRails` 的 `color`、`body`、`spacing/gutter`、`fileRails`；根据 `RecentCommit.references` / `stash` 确认当前 HEAD，不能靠 lane0 推断。
- `kero/Git/CommitGraphLayout.swift`：只有 T1 结果表明行模型确需携带节点状态时才补最小标记；优先使用已有 `RecentCommit` / `Reference.Kind`。
- `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：实际 `NSHostingView` 行和点击／展开测试；必要时扩展 `CommitGraphLayoutTests` 断言节点类型。
- 文档 owner：`docs/features/git.md` 中图谱形状及 `docs/ui.md` Git 图谱特有的主题例外；不得扩散至共享树行颜色。

**步骤：**
1. **Red：** 在已存在的原生宿主中增加带已知 HEAD、Detached HEAD、Merge、Stash、普通 root 的行；确认 HEAD 显示空心、Stash 双环、普通提交实心的预期，并让自动化证明拓扑 row/background 保持完整命中、展开后 `bottomRails` 连续。用于逐像素人工比对的 fixture 应生成固定 DAG 和对照视口，不读取用户实际 Git 仓库。
2. **统一颜色：** 在当前 Git 图谱展示文件内维护唯一的小型 palette（12 个独立的 sRGB 色，编号由 `CommitGraphLayout` 给出），供 `CommitGraphRails` 和下阶段 `referenceBadge` 同时调用；不放进全 App `Theme`，不在 Model 引入 `SwiftUI.Color`，也不建“可配置配色系统”。
3. **Canvas：** 参考上游默认圆角 path：纵向直线、跨车道三次贝塞尔、圆形端点；使用高对比背景下可见的细底衬与 2pt 主路径（受 `fontScale` 缩放），点约 r=4pt。对齐相邻行的上下边界、拐点、线段叠放顺序和绝不覆盖不相干节点。当前已检出 HEAD 是空心同色描边；Stash 依当前 `stash` 字段使用双环视觉；不以“所有分支尖端”代表 HEAD。
4. **响应式：** 复用既有 `CommitGraphRails.gutter/spacing` 和 `viewportWidth`，用 260pt、宽侧栏、字体缩放和 30 车道测试不会整体横滚；车道过密时对比参考的渐隐做取舍，但**没有真实视觉问题不得先增渐变遮罩**。展开历史文件后同色轨道贯通、不遮挡文件命中；像素描边需与实际 macOS 缩放保持视觉一致。
5. **验证与清理：** 更新或补充 NativeUI 图谱测试，运行 `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` 与 `CommitGraphLayoutTests`；在隔离宿主截图核对 12 色、圆角和节点形态、浅／深背景。删除旧 `[.systemGreen, .systemPurple, …]` 与写死蓝色的重复路径，同步上述文档并原子提交。无需现在跑产品构建；实现阶段按 `docs/testing.md` 跑必要构建／全量测试。

**本 task Acceptance：** 第一个路径使用目标蓝色，后续并行路径依序采用目标色系；HEAD 颜色来自所属路径且为空心，Stash 与普通节点可区分；曲线和展开路径连贯、背景对比合理、窄面板不横滚。此时 Ref 徽章仍是旧样式，明确由 P2 接续。

## Phase 完成与审计

P1 两个 task 各自完成测试、旧路删除、owner 文档和独立 Git 提交后，按 `executing-plans` 进入本 phase 审计；`audit-p1.md` 由审计工具在审计开始时创建，计划阶段不预建。