# P5 原生 Diff 验证与实测

## T1：调用链与前置样本（2026-10-16）

- 入口：`Project.openDiff/openHistoricalDiff → DiffTab.reload`；后台使用 `GitCommandExecution`、`GitHistoricalFileLocator`、`WorkspaceBackend` 读取原始 Git/工作区数据，数据有效后 `recomputeDisplay → HighlightQueryCache.context → detached DiffCore.compute + 双侧 Tree-sitter captures + DiffComputation.build → @MainActor makeDisplay(3 份 NSAttributedString) → DiffNativeSurface.render → DiffCodePaneView.setReviewDocument → STTextView/TextKit`。`refreshWhenSelected` 仅 live 重读，用户再次点击现有 Git 行 `Project.openDiff` 会重读；历史不可变的再次点击是否有重复 IO 留给 T3。
- 系统：Apple M1 Pro、macOS 27.2、Xcode beta、Debug XCTest；与已记录的 P1 样本区分，未执行同配置 Release 真实 App 首屏。样本为 1,200 行 Swift、旧 31,380／新 31,381 UTF-8 字节，每隔 47 行改变一处；测试通过现有 `make test ONLY_TESTING` 运行。实验 XCTest 只临时放在正式 test target 中供 Xcode 发现，结束后删除，完整实验源码留在忽略目录 `build/performance/diff/DiffPipelinePerformanceTests.swift`，未新增正式测试框架。
- 30 次热路径（`p5-t1-stages.log`）：DiffCore 6.606ms（p95 7.132）、双侧 captures 74.795ms（p95 77.013）、文档构造 2.238ms（p95 2.560）、三份富文本 3.411ms（p95 3.645）。首次 query/context 304.739ms；包含首次系统初始化，不是独立冷开，也不等同完整 App 高亮落屏。
- 5 个真实本地临时 Git 仓库改动通过 `DiffTab` 得到 display，再在 NSWindow/NSHostingView 中观察真实原生 TextKit 文本安装（`p5-t1-native-mount2.log`）：Git+worktree+解码+派生 display 中位 183.234ms、最差 479.188ms；display 到文字进窗口中位 53.223ms、最差 70.687ms。只证明真正文本进入原生 view；非像素合成、滚动性能、Release、真实 SSH、磁盘峰值 RSS 的整体 E2E。
- 单一最小候选：**两侧 captures 并行**。临时原型 30 次交错 AB/BA（`p5-t1-capture-prototype.log`）：串行 75.588ms（p95 97.475）、并行 52.728ms（p95 69.248），两侧每条 capture 的 name/range 顺序逐条一致，全部 XCTest 通过。单轮相对降低约 30%，但未在正式 App 流程验证，亦不承诺综合首屏减少 23ms；若 T2／T3 完成后同机复测有真实净收益，T4 仅把当前 detached 片段的 old/new captures 改为并行，不额外引入缓存、actor/队列/全局线程池。
- 不采用：重复新算法、永久 blob 缓存、三份属性文档的额外缓存、直接改 Diff 阈值；目前它们都不是这批测量的最高成本。折叠已有 `displayInputs` 可复用 core/runs，继续保留。`P5-T2` 的 CRLF 行语义修复先于后续性能 A/B，错误分行不算优化。

## T2：LF／CRLF 原始行契约

- `KeroTests/Unit/Git/DiffEngineTests.swift` 新增纯单元回归：CRLF／LF／裸 CR／空内容／尾换行／emoji 和 Unicode 规范差异，用原始 bytes 核对 ops 重建、UTF-16 行起点和内容、准确 old/new 行号。`p5-t2-red.log` 真实 Red：原分行器把 `\r\n` 看作一个 Swift Character，漏掉中间的 LF、行号由 3 降到 1；`p5-t2-green2.log` Green。
- 根因只在 `DiffLineSplitter.lines`，使用 `String.unicodeScalars` 的 LF 边界迭代替代 `Character`，不归一化 CR 或文件字节，也不新增另一套 splitter。测试本身须以最后 Unicode scalar 判断 CRLF 尾换行；Swift `String.hasSuffix("\\n")` 会把 CRLF 看作一个 Character，不能做 LF 字节判定。
- `DiffTabTests.testCRLFNativeReviewRowsAndEditUndoSavePreserveBytes` 真实本地 Git `HEAD→worktree` 经 DiffTab、原生 STTextView、统一/双栏行装饰、edit→undo/redo→实际保存、Data 原字节复核 Green（`p5-t2-native.log`）。`make test ONLY_TESTING` 三组：DiffEngineTests 4/4、DiffTabTests 20/20、GitHistoryFileTests 11/11，0 failed，日志 `p5-t2-{DiffEngineTests,DiffTabTests,GitHistoryFileTests}.log`。已同步 `docs/features/diff.md`。
- 未宣称独立 App 前台真实菜单、真实 SSH 或视觉光栅化已验收。裸 CR／Unicode 分隔符的 Git LF 行契约不会主动改写为 TextKit 的段落规则；当前主要 CRLF 多行同步已由真实 TextKit 表面与字节回写测试覆盖。

## T3：读取身份、缺失语义与旧派生失效

- 真实 Git `p5-t3-metadata-red.log`：无效对象哈希被原 stderr 子串猜缺失误报为“选中 revision 不含文件”，以及历史正文加载成功后临时失去 `.git` 再读把用户看到的内容清空，均 Red；改为 `ls-files --stage -z`／`ls-tree -rz --full-tree` 按原始路径字节解析 blob OID，固定 OID 后运行 `cat-file -s` 与 `cat-file blob`。有效空 metadata 才是 missing，非零状态、坏记录、无效哈希、短读分别报错；字节大小、NUL、UTF-8 与 5 MiB 限额复用原有检查。不再对 Git stderr 文案猜缺失。修复后 `p5-t3-metadata-green2.log` Green。
- Worktree 的 index stage 选择与未合并判定来自**同一次** `ls-files -z`，使用 0→2→1 顺序，找不到 index 后才尝试 HEAD；验证 unborn HEAD 是否确实符号引用且无提交后才允许空侧，失败不假装 unborn。删除原独立 `isUnmerged` Git 命令与可变 `:path`/`HEAD:path` 分别查 size/blob 的旧双轨。
- 永久原生/真实 Git 用例：隔离后端在 size 与 blob 间更改 index，assert 实际选定的 OID 内容仍为 `indexA` 而非已变化的 `indexB`；故意截短 blob，assert error 且未发布；真实 `git merge` 冲突使用 stage 2 和 Unmerged 标记；含 tab、换行、冒号的路径 + unborn 首次暂存 + HEAD 原文 + 后续暂存；选中无效 revision 与合法缺失文件区分。
- Async UI：新内容接收后即清理旧 `displayInputs`，旧 fold 事件不得通过它取消并覆盖新文档；复用 `displayGeneration`，没有附加第二套 render identity 或另建缓存。`DiffTab.reload` 成功读取标记与失败保留上次正文；读取错误只在未有可用旧内容时取代正文，已有正文显示错误横幅。P2 的 `invalidateReload` loading 收尾保留且继续跑回归，不再重复实现。
- 真实 `p5-t3-reuse-red.log`：已有不可变 history tab 再次点击仍重新调用 Git；修复 `Project.openHistoricalDiff`，不可变历史且已加载则复用，切 origPath/失败允许重读；live 仍可刷新，正在读取的同源点击不制造重复读。`p5-t3-reuse-green.log` 16/16。
- 最终定向 `p5-t3-{DiffTabTests,GitHistoryFileTests,GitExecutionTests,WorkspaceIdentityTests}-verified.log`：23/23 + 16/16 + 4/4 + 4/4 = **47/47，0 失败**；旧 `GitHistoricalFileLocator` 的真实 rename/missing 及文件字节契约仍经历史用例覆盖。真正授权 SSH 与完整独立 App GUI 另需验收，当前受控后端仅证明逻辑，远端传输返回后截断并不等于真正内存限额。

## T4：两侧 captures 并行，真实原生路径复测

- T2/T3 正确性修复后，生产代码原样串行 baseline（`p5-t4-before.log`）：双侧 captures 30 次中位 74.870ms，core 5.529ms，文档 2.320ms，三份 attributed 3.516ms；同一 1,200 行 Swift、同一 Xcode Debug 和 M1 Pro。当前路径两侧独立 Parser，可共享只读的 query，`async let` 在原有后台 detached 工作内并行，不向 MainActor 搬 Tree-sitter，也不增加 cache/task manager。
- 临时 30 次交错串并行捕获对照（`p5-t4-after.log`）逐条核对 name/range 一致：串行中位 74.670ms，并行 53.733ms，均 Green；只有语法捕获这一阶段可直接归因降低约 28%。`testThirtyNativeDiffPipelineStages` 仍测纯串行参考，不能把它的 75ms 指标误报为正式并行版本耗时。
- 首轮实际本地 Git→DiffTab display→原生 NSHostingView/STTextView 安装（n=30，不是像素合成）：`p5-t4-fullpath-serial-30.log`，读取至 display 中位 175.749ms、p95 209.554ms、最多 475.697ms；TextKit 安装中位 32.779ms、p95 39.172ms、最多 58.539ms。并行对应 `p5-t4-fullpath-parallel-30.log`：156.644/256.543/451.372ms 和 45.767/53.832/59.866ms。两阶段互有波动，不能按首轮断言整体验收改善。
- 反向复测（相同 30 次、原生安装成功条件；新增从开始到原生文字可取的总路径终点）：`p5-t4-serial-confirm-30.log`，Git→display 中位 172.417ms、p95 186.848ms；display→TextKit 中位 56.801ms、p95 67.994ms；**完整原生文本安装中位 236.562ms、p95 242.726ms、最大 560.786ms**。并行 `p5-t4-parallel-confirm-30.log`：相应 158.991/169.280ms、56.367/65.953ms；**完整安装中位 222.759ms、p95 237.101ms、最大 528.571ms**。对应总中位改善约 5.8%（13.803ms），p95 约 2.3%，不是 GUI 绘制或冷启动的证明；不将高亮容量阈值以上的 plain 文本当高亮。
- 最小生产变更只在 `DiffTab.recomputeDisplay` 中将串行的两次 `DiffSyntaxHighlighter.captures` 改为 `async let`；仍复用原有 `displayGeneration` 发布保护、`DiffCore`、`DiffComputation`、主线程属性构造及唯一 `nativeSurface`。没有缓存、两套 reader、阈值调低、任务服务或新依赖。
- 临时 `DiffPipelinePerformanceTests.swift` 作为完整复测源码保存在被忽略的 `build/performance/diff/`，正式测试目标入口于测量结束后移除。仍需跑正式受影响 XCTest／完整 `make test`、Debug／Release 构建与验签。独立 App 菜单、真 SSH、峰值 RSS 与显存均未由本组证明。
