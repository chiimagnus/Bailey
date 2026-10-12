# P1：建立同机基线与可重复证据

**Goal:** 在改性能代码前回答“哪一段慢、慢在 CPU 还是等待、用户什么时候真正能操作”。

**Non-goals:** 不优化业务路径，不建立通用 benchmark 平台，不改应用配置或会话恢复格式。仅修复已证实的首次解析/坐标契约，使参考实现的输入正确，不夹带性能实现，也不假定旧 App 已复现启动崩溃。

**Approach:** 准备最小合成样本和操作记录，在签名 Debug 上取得两批基线。优先现成 Instruments 与可见行为记录；阶段难分时才增加 Debug 轻量标记，并复测扰动。源码推断与实际 trace 分栏记录。

**Acceptance:**
- 样本可重建，有尺寸/行数/内容校验和、固定操作序列，不用私有仓库。
- 冷/热、文本首屏/可输入/高亮、Git 状态/详情、diff 桥接/首屏口径一致。
- 同机两批未优化数据、热点与等待归因齐全，实施前固定目标样本。
- 构建身份、隔离方式与证据有记录；无法观测的指标写明缺口，不用替代指标冒充。

**Rules:**
- 沿用 `AGENTS.md`：同一签名 Debug 包通过 `open -n ... --args --isolated-ui-test` 验收，不操作正式实例；共用全局偏好不得在隔离实例修改。正式包替换不是取得基线的前提。
- 工程只有 Debug 配置，目标默认 MainActor、启用 approachable concurrency。单看 `async` 或旧注释不能证明 executor。
- `FPSCounter.tick` 统计显示回调；`DiffWebRoot.onReady` 不是可见首屏，只能辅助定位。
- trace 和原始样本留在被忽略的 `build/`，feature 文件保持本地。
- 字体/换行等变体优先由现有原生检查显式传 view 参数；隔离 app 只使用当前全局偏好。需要真实切全局设置时另取得授权，不能因为用了 isolated 参数就自行更改。

<a id="p1-t1"></a>
## P1-T1 合成样本与验收操作序列

**类型 / 依赖:** 样本与文档实现；无前置 task。

**Files:**
- New: `scripts/prepare-performance-fixtures.swift`，独立 Foundation 脚本，不增加测试框架。
- Modify: `docs/PERFORMANCE.md` 的生成入口，验收流程链接 `AGENTS.md`。
- Local evidence: `build/performance/fixtures/`、`build/performance/fixtures-manifest.json`、feature 下 `evidence-p1.md`。

**当前依据:** `scripts/check-file-tree-navigation.swift` 已用独立 Swift 检查和临时目录；没有 app 测试 target。文本及 diff 上限 5 MiB，未跟踪计数有 2048 文件/8 MiB 每文件/32 MiB 总预算。

**实施:**
1. 只创建指定的全新输出目录；已存在则拒绝覆盖。确定性生成 32 KiB / 512 KiB / 4 MiB Swift、TSX、Markdown 长代码块和 HTML script，记录真实字节数、UTF-16 长度与行数。
2. 边界样本包括空文件、中文/emoji、CRLF、超长单行、5 MiB 恰好及多一字节、二进制、有效小图片和无效图片扩展名。图片用固定合法样本，不建生成链路。
3. 仅在输出目录建 Git fixture：小仓库、上千 tracked/untracked 改动、rename、unborn、merge conflict 和足够分页的 history。设仓库内作者信息，不改 global config，不建立网络 remote。
4. 固定动作：首次打开、重复切换、首/中/尾编辑、滚动、撤销回原文、Git 刷新/分页、同一 diff 复选及跨项目切换。正确性边界另列，不掺进计时动作。
5. 分屏、字体/换行、SSH 按相应根因加入，不穷举所有组合。fixture 关闭/重建不改变用户项目。

**验证:**
- Run: `xcrun swift scripts/prepare-performance-fixtures.swift build/performance/fixtures`；manifest 与文件一致，Git porcelain/index/log 与设计一致。
- 同目录再运行应拒绝，原校验和不变；另一新目录的内容/状态语义相同。Git 哈希允许时间不同，除非显式固定日期。
- 验证空文件、5 MiB 边界、Unicode、冲突和失败不触碰目录外资源。
- 按开发文档的签名 Debug 真机流程，实际打开生成的文本与 Git fixture，确认样本在真实编辑器/面板中可用；仅查看，不改计时样本。该检查不宣称性能通过，耗时与构建可比性仍归 P1-T2。

**提交边界:** 脚本与入口文档一个原子提交；生成产物与本地证据不入库。

<a id="p1-t3"></a>
## P1-T3 恢复首次解析与字节坐标契约

**类型 / 依赖:** 前置正确性修复；依赖 P1-T1，先于 P1-T2 完整基线。阶段内顺序为 T1 → T3 → T2；保留原 task ID，不把 T3 标成性能优化。

**Files / 锚点:**
- Modify: `kero/Editor/SyntaxHighlightPlugin.swift`：coordinator 初始化的首次 will/did 与 TreeSitterClient transformer。
- Read-only: `Neon/Sources/TreeSitterClient/TreeSitter+Extensions.swift`、`SwiftTreeSitter/Parser.swift`、`STTextKitPlus/NSTextContentManager.swift`、tree-sitter `lib/src/lexer.c`。
- New: `scripts/check-editor-highlighting.swift` 与 `.sh`，复用现有 `@testable import kero` / Debug dylib 方式，调用生产插件；Modify: `scripts/check.sh` 注册 `editor-highlighting`，`docs/EDITOR.md` 仅同步必要维护约束。

**当前证据:** 初始文档长度 N 时，代码以旧范围 `[0,N)` 加 delta=N，Neon 因而请求新终点 2N；Kero 的 NSTextContentManager 无该位置，不能用 `.zero` 伪造坐标。锁定 parser 用 UTF-16，InputEdit 字节乘 2，但当前 transformer 将 TextKit 的 UTF-16 column 原值传入 Point；TextKit 段落也不等于 Tree-sitter 只按 LF 分行的定义。本轮链接真实依赖的最小检查确认 N=7 时请求 offset=14，完整解析的 EOF column 为 14 字节，不是 7。

**实施 / 验证:**
1. 保存原错误范围与可运行检查输出。初次解析按“空旧文档插入 N 个 UTF-16 单元”通知，不能把非空文档范围当旧树范围；首次 oldEndPoint 为零，new point 从当前稳定全文计算。
2. 使用 Tree-sitter 的 LF 行与 UTF-16 字节列契约，在插件当前拥有者修正 transformer；先用直接扫描/标准库表达，不为正确性预建行索引。不要将未知位置静默映射成合法 `.zero`。文本快照来自实际 TextKit 内容，不依赖尚未更新的 FileTab.text。
3. 同 task 删除错误初次通知与原单位错误的转换路径，不保留“旧算法兼容”开关。P3-T3 只负责已正确转换的扫描性能，不重复修复坐标。
4. 新 App 检查覆盖空/非空初次打开、末尾 offset=N、中文/emoji、LF/CRLF/bare CR、Unicode 段落分隔符、尾换行；将实际坐标与真实 Parser 全量解析所得 Point 对照，并挂载真实插件检查 Debug 无断言、合法首屏着色。编译模块参数复用现有检查的 `GeneratedModuleMaps`，不写旧包 target 路径。
5. Run（同 task 接入）：`bash scripts/check.sh editor-highlighting`，先构建并验签 Debug；隔离实例实际打开 Swift/TSX/Markdown，文本、光标和颜色可用。脚本正确性通过不等于性能验收。

**提交边界:** 首次解析/坐标、生产路径接入、回归检查及必要说明一个原子提交。不加入高亮范围调度、字体精简、缓存或阈值调整。随后 P1-T2 对这个明确标识的正确性基线测量，不把契约修复计为后续性能优化的收益；本轮依赖检查并未证明 Kero 初次打开会崩溃。

<a id="p1-t2"></a>
## P1-T2 真实基线、阶段标记与热点准入

**类型 / 依赖:** 最小实验；依赖 P1-T1、P1-T3。

**Files / 已核对锚点:**
- `kero/Workspace/Project.swift`：`openFile`、`openFileToSide`、`makeContent`。
- `kero/Editor/FileViewerView.swift`：`FileTab.init`、`reloadFromDiskIfClean`、`loadedContent`。
- `kero/Editor/SourceTextEditor.swift`：`makeNSView`、`Coordinator.textViewDidChangeText`。
- `kero/Editor/SyntaxHighlightPlugin.swift`：`didChangeContent`、`injectedTokens`、`SyntaxHighlightTextInterface.applyStyle`。
- `kero/Git/GitStatusModel.swift`：`refresh`、`runGitStatus`、`applyRepository`。
- `kero/Git/GitCommandExecution.swift`：`loadLoginEnvironment`、`runData`、`runProcess`；`kero/Workspace/LocalWorkspaceBackend.swift`：`readSync` / `read`。
- `kero/Git/DiffViewerView.swift`：`DiffTab.reload`、`gitContent`、`readWorktreeFile`、`DiffWebRoot`。
- 当前布局 caller：`WorkspaceDockView.DockTabGroupView.content` 直接挂载独立 diff，文件经 `PaneLayoutView.PaneView.content`；Git 同步归 `ContentView.syncGit`，Files 同步归 `ToolPanelView.performSync`。工具唯一但 Files/Git 可同时可见，不能套旧 sidebar/visited stack 假设。
- Only if needed: new `kero/Support/PerformanceTrace.swift`，通过现有同步根目录接入；上述共享入口的 Debug 标记。
- Local evidence: `evidence-p1.md` 与 `build/performance/baseline/`。

**实验:**
1. 固定实际 HEAD、相关工作树差异/文件校验和及依赖，源码在测量之间变化就重建基线，不替用户提交/回滚/stash。按开发文档构建并验签，启动本轮拥有的隔离实例，核对 PID、可执行路径和包身份。冷测量只正常关闭自己的无未保存工作的测试实例；不退出、替换或重启正式 Kero。
2. 核对实际编译设置/命令与 executor，在 trace 中识别本地 `readSync`、解码、文本创建、解析和样式线程。参考 [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)；非隔离 async 可以继承 caller actor，旧注释不是后台证据。
3. 用 Time Profiler；CPU 低仍卡顿再用 System Trace/线程等待；分配/累计用 Allocations。diff 同时定位 WebKit 内容进程，不仅看 Kero。
4. 难区分阶段才用 `OSSignposter` 区间/事件，集中一个 Debug 入口，无文本、路径、命令参数或主机值，只含无敏感数据的关联 ID、长度/数量。不增加轮询或 `@Published` 指标。
5. 标记读取、解码、编辑回写、parse completion、颜色应用、Git 状态/详情和 diff 输入；绘制仍与截图/录像或网页 timeline 对齐。NSView 安装、parse 完成、ready 各自记录，不命名为“用户已看到”。
6. 每场景两批数据、各冷 5 次/热 30 次建立波动，记录中位数/p95/最差、主线程最长段、读取量、Git 进程/SSH 往返、关闭后内存和三种空闲状态。检查 tracing 开/关扰动，显著时改轻并重建基线。
7. 把热点映射 P2–P5，区分可避免工作、待实验、未命中候选。未命中的复杂措施不提前实施；已证实缺口要有对应任务。
8. 本机第一次 Git 调用包含一次交互式登录 shell 环境加载（最多 5 秒），随后缓存；单独记录这段等待，后端已声明 `@concurrent` 的读取/list 不再列为待实现。P1-T3 修复前的不一致参数记录与“契约已修复、性能未优化”的基线分开；不能将错误坐标回退当成已复现崩溃，不能关闭断言/高亮获得数字，也不能把正确性修复的收益混入后续优化。

**命令核对:** 当前 Xcode 有 `Time Profiler`、`System Trace`、`Allocations`；`xcrun xctrace help record` 支持 attach/all-processes。实施时先建输出目录，对正确 PID 录制，例如：

```sh
xcrun xctrace record --template 'Time Profiler' --attach <Kero-PID> \
  --time-limit 60s --output build/performance/baseline/editor.trace
```

这是后续示例，本轮未录制。跨进程录制限定合成操作，不顺手采集其他敏感应用；按系统提示处理权限，不用 `--no-prompt` 绕过。

**成本 / 停止:** 每候选一轮基础 trace 加一轮定向验证；仍无法归因就记录缺少的可观察量、修正测量，不试写多种优化。缺输入/权限只暂停相关实验。不为交付基线制造无用户可见终点的数字。

**交付与验证:** `evidence-p1.md` 写环境/样本/动作/统计/噪声/热点和后续准入，原始记录在 `build/`。证明实际文本、光标、状态或 diff 可用，并核对磁盘/Git 副作用。

**提交边界:** 只有确需的 Debug 标记与测量说明入一个原子提交，无代码实验不提交。加标记须构建、验签并在隔离 Debug 实例验证默认关闭、开启不改变行为及生命周期。

## 阶段自审与交接

- 用 P1 真实结果支持排序，不凭“async/worker/缓存已存在”跳过测量。
- 回写后续 plan 的选择依据，`idea.md` 不维护实时 task 状态。
- 实际完成后进入 `plan-task-auditor` 并创建 `audit-p1.md`；规划时不预建、不宣称 Gate 通过。
