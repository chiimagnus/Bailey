# P1：样本、解析契约与同机基线

**目标：** 查明实际耗时、等待和用户可操作终点，再决定优化。
**不做：** 永久 benchmark 平台、产品配置／会话格式变更，不假定已复现 App 崩溃。
**顺序：** P1-T1 → P1-T3 → P1-T2。输入高亮／字节精确比较／CRLF Diff 的已知错误分别归 P3-T1／P3-T2／P5-T2；未修前不把错误输出的低耗时当有效对照，修正后再补相应可比基线。
**验收：** 可重建样本、两批可比数据、线程归因与热点选择；未观测项不冒充通过。

共同规则见[需求](idea.md#验收与授权边界)与 [testing.md](../../../docs/testing.md#性能与内存测量)。使用当前 Swift 6、MainActor／approachable concurrency、Makefile 和一个 XCTest 目标；证据留本地 `evidence-p1.md`／`build/performance/`。

<a id="p1-t1"></a>
## P1-T1 准备最小可重复样本与动作

**类型：** 本地实验准备，无前置。

**依据：** 文本／Diff 上限 5 MiB；未跟踪统计预算为 2048 文件、单文件 8 MiB、总计 32 MiB。复用当前 XCTest 的临时文件／Git fixture 方式，不复建独立测试 runner。

1. 在全新本地目录准备 Swift、TSX、长 Markdown fence／HTML script，从 32 KiB／512 KiB／4 MiB 中选出能区分成本的少数组合；记录字节、UTF-16 长度、换行、行数和校验和，不强制全部组合计时。
2. 边界单列：空、Unicode／emoji、LF／CRLF、长行、5 MiB 恰好／多一字节、二进制、有效／无效图片。只在相应实现任务验证，不每份都录冷／热 trace。
3. 合成 Git 小仓库／上千变更、rename、unborn、冲突及分页历史；仅仓库局部设置作者、hook 和签名，不改 global config，不连真实远端。
4. 固定打开、首中尾输入／撤销、滚动、切换、Git 刷新／分页和 Diff 复选。布局／SSH 仅在相应根因需要时加入。
5. 生成步骤与 manifest 默认留本地；需要重复生成才保存一个本地脚本，不强制增加永久生成器。拒绝覆盖已有目录，样本不能沿 symlink 写到输出目录外。

**验证／交付：** 独立生成两份得到相同文本和 Git 状态语义；manifest 与文件／Git 输出一致。T2 开始时在隔离 App 实际打开选中样本。无生产代码或长期入口变化就不制造提交。

<a id="p1-t3"></a>
## P1-T3 修正首次解析与字节坐标

**类型／依赖：** 正确性实现；依赖 T1，先于 T2。

**文件：**
- `kero/Editor/SyntaxHighlightPlugin.swift` 的首次 will/did 与 locationTransformer。
- 只读契约：Neon 的 TreeSitterClient／InputEdit 扩展，SwiftTreeSitter 的 Parser／Point，STTextKitPlus 的 position。
- 新 `KeroTests/NativeUI/Editor/SyntaxHighlightingTests.swift`，进入现有 XCTest 目标，调用生产插件与真实 Parser。
- 文档 owner：`docs/features/editor.md`，不复制依赖 API 清单。

**根因与步骤：**
1. Red：当前首次旧范围 [0,N) 加 delta=N 请求 2N；TextKit 段落／UTF-16 列不等于 Tree-sitter LF 行／字节列。检查真实插件初始化和 Parser 全量树对应点，不只对比自写函数。
2. 首次通知表示空旧文档插入 N 单元，旧终点为零；当前 TextKit 稳定快照按 UTF-16 code unit／scalar 的 LF 计行、字节计列。不要逐 Character 比 LF（CRLF 在 Swift 是一个 Character），未知位置不能伪造 .zero。
3. 同 task 删除错误初始化、旧段落转换与静默兜底；先正确扫描，不预建索引。P3-T3 测这个新实现，不再测被删除的 position。
4. 覆盖空／非空／文末、中文／emoji、LF／CRLF／bare CR、Unicode 段分隔符、尾换行；真实挂载 Debug 插件，检查合法 token／实际可见颜色。

**验证：** `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`，随后 `make test`、`make build` 与隔离 App 的 Swift／TSX／Markdown 打开。签名／安装遵循开发规范，不重启用户实例。

**提交：** 初始化／坐标、接入、回归和文档一个正确性提交，不混字体、缓存、调度；修复前证据与修复后性能基线分开。

<a id="p1-t2"></a>
## P1-T2 冻结代表路径基线与热点选择

**类型／依赖：** 实验；依赖 T1、T3。

**真实源码阶段：**
- 文件：Project.openFile/makeContent → FileTab.init/reloadFromDiskIfClean/loadedContent → backend → SourceTextEditor.makeScrollView／编辑回写。
- 高亮：SyntaxHighlightCoordinator 的 parse、query compile、base/injection query、fragment parse 和颜色应用。
- Git：ContentView.syncGit／ToolPanelView → GitStatusModel.refresh/runGitStatus/applyRepository → GitCommandExecution／SSH batch。
- Diff：DiffTab.reload/recomputeDisplay → DiffCore/Computation、DiffSyntaxHighlighter → DiffNativeSurface／DiffCodePaneView；不再测网页。
- 挂载：WorkspaceDockView.DockTabGroupView.content → PanelContentView，各可见组显示 active 内容，原生资源由标签保留。

1. 固定源码／差异／依赖／构建／样本／环境，以同一签名 Debug 的本轮隔离实例测量；不为基线替换正式包。
2. 优先 Time Profiler；CPU 低却卡时查 System Trace／等待，资源归属用 Allocations。当前 beta 的 DTServiceHub 被 AMFI 拒绝（见 evidence-p1.md），按用户决定保留 beta，CPU 归因改用系统 sample，只附本轮隔离 PID；不绕过系统校验。以现有 XCTest 目标内的本地原生实验与隔离 App 的实际观察补可比数据，明确组件／AX／绘制边界及未测范围。backend read/list 已有 @concurrent，不当成待补能力；同步 init、主 actor 解码另外计时。
3. 真有阶段分不清才加最少 Debug signpost，留在领域入口，不预建 PerformanceTrace 服务、偏好或轮询；不记录文本／路径／主机。不把 parse／display 创建命名为绘制完成。
4. 两批选中正常路径估计波动；热至少 30 次、冷开 5 次独立进程。分别记主线程长段、IO／计算／进程／往返和用户可见终点。登录 shell 首次环境加载（最多 5 秒）与热成本分开，不绕过共享执行器。
5. 每候选一轮定位和一个最小原型；未归因先修观测，不排列多套架构。回写 P2–P5 的命中／未命中及理由。trace 开关有显著扰动就精简并重测。

**交付：** 本地 evidence-p1.md 写环境、动作、统计、波动、热点及错误输出的排除范围。只有确需生产 Debug 标记才补测试／文档并原子提交；无代码实验不提交。
