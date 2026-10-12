# P1：建立同机基线与可重复证据

**Goal:** 在改性能代码前回答“哪一段慢、慢在 CPU 还是等待、用户什么时候真正能操作”。

**Non-goals:** 不优化业务路径，不建立通用 benchmark 平台，不改应用配置或会话恢复格式。

**Approach:** 准备最小合成样本和操作记录，在签名 Debug 上取得两批基线。优先现成 Instruments 与可见行为记录；阶段难分时才增加 Debug 轻量标记，并复测扰动。源码推断与实际 trace 分栏记录。

**Acceptance:**
- 样本可重建，有尺寸/行数/内容校验和、固定操作序列，不用私有仓库。
- 冷/热、文本首屏/可输入/高亮、Git 状态/详情、diff 桥接/首屏口径一致。
- 同机两批未优化数据、热点与等待归因齐全，实施前固定目标样本。
- 安全安装/恢复有记录；无法观测的指标写明缺口，不用替代指标冒充。

**Rules:**
- 沿用 `AGENTS.md` 的签名 Debug 与 `/Applications/Kero.app`，不注册另一份同标识应用。
- 工程只有 Debug 配置，目标默认 MainActor、启用 approachable concurrency。单看 `async` 或旧注释不能证明 executor。
- `FPSCounter.tick` 统计显示回调；`DiffWebRoot.onReady` 不是可见首屏，只能辅助定位。
- trace 和原始样本留在被忽略的 `build/`，feature 文件保持本地。

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

<a id="p1-t2"></a>
## P1-T2 真实基线、阶段标记与热点准入

**类型 / 依赖:** 最小实验；依赖 P1-T1。

**Files / 已核对锚点:**
- `kero/Workspace/Project.swift`：`openFile`、`openFileToSide`、`makeContent`。
- `kero/Editor/FileViewerView.swift`：`FileTab.init`、`reloadFromDiskIfClean`、`loadedContent`。
- `kero/Editor/SourceTextEditor.swift`：`makeNSView`、`Coordinator.textViewDidChangeText`。
- `kero/Editor/SyntaxHighlightPlugin.swift`：`didChangeContent`、`injectedTokens`、`SyntaxHighlightTextInterface.applyStyle`。
- `kero/Git/GitStatusModel.swift`：`refresh`、`runGitStatus`、`applyRepository`、`runGit`。
- `kero/Git/DiffViewerView.swift`：`DiffTab.reload`、`gitContent`、`readWorktreeFile`、`DiffWebRoot`。
- 当前布局 caller：`kero/UI/WorkspaceDockView.swift` 的 `DockTabGroupView.content`，以及 `PaneLayoutView`。不沿用旧 `ContentView` 的 visited-project diff stack 假设。
- Only if needed: new `kero/Support/PerformanceTrace.swift`，通过现有同步根目录接入；上述共享入口的 Debug 标记。
- Local evidence: `evidence-p1.md` 与 `build/performance/baseline/`。

**实验:**
1. 先固定实际 HEAD、相关工作树文件校验和/未提交差异及依赖，核对并行停靠工作是否稳定，不替用户提交/回滚/stash；布局在测量之间变化就重建基线。按开发文档构建、验证签名；检查运行命令和未保存内容后正常退出、替换、启动，不强退获得“冷启动”。记录真实恢复与实际构建身份。
2. 核对实际编译设置/命令与 executor，在 trace 中识别本地 `readSync`、解码、文本创建、解析和样式线程。参考 [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)；非隔离 async 可以继承 caller actor，旧注释不是后台证据。
3. 用 Time Profiler；CPU 低仍卡顿再用 System Trace/线程等待；分配/累计用 Allocations。diff 同时定位 WebKit 内容进程，不仅看 Kero。
4. 难区分阶段才用 `OSSignposter` 区间/事件，集中一个 Debug 入口，无文本、路径、命令参数或主机值，只含无敏感数据的关联 ID、长度/数量。不增加轮询或 `@Published` 指标。
5. 标记读取、解码、编辑回写、parse completion、颜色应用、Git 状态/详情和 diff 输入；绘制仍与截图/录像或网页 timeline 对齐。NSView 安装、parse 完成、ready 各自记录，不命名为“用户已看到”。
6. 每场景两批数据、各冷 5 次/热 30 次建立波动，记录中位数/p95/最差、主线程最长段、读取量、Git 进程/SSH 往返、关闭后内存和三种空闲状态。检查 tracing 开/关扰动，显著时改轻并重建基线。
7. 把热点映射 P2–P5，区分可避免工作、待实验、未命中候选。未命中的复杂措施不提前实施；已证实缺口要有对应任务。

**命令核对:** 当前 Xcode 有 `Time Profiler`、`System Trace`、`Allocations`；`xcrun xctrace help record` 支持 attach/all-processes。实施时先建输出目录，对正确 PID 录制，例如：

```sh
xcrun xctrace record --template 'Time Profiler' --attach <Kero-PID> \
  --time-limit 60s --output build/performance/baseline/editor.trace
```

这是后续示例，本轮未录制。跨进程录制限定合成操作，不顺手采集其他敏感应用；按系统提示处理权限，不用 `--no-prompt` 绕过。

**成本 / 停止:** 每候选一轮基础 trace 加一轮定向验证；仍无法归因就记录缺少的可观察量、修正测量，不试写多种优化。缺输入/权限只暂停相关实验。不为交付基线制造无用户可见终点的数字。

**交付与验证:** `evidence-p1.md` 写环境/样本/动作/统计/噪声/热点和后续准入，原始记录在 `build/`。证明实际文本、光标、状态或 diff 可用，并核对磁盘/Git 副作用。

**提交边界:** 只有确需的 Debug 标记与测量说明入一个原子提交，无代码实验不提交。加标记须安装签名 Debug，验证默认关闭、开启不改变行为及生命周期。

## 阶段自审与交接

- 用 P1 真实结果支持排序，不凭“async/worker/缓存已存在”跳过测量。
- 回写后续 plan 的选择依据，`idea.md` 不维护实时 task 状态。
- 实际完成后进入 `plan-task-auditor` 并创建 `audit-p1.md`；规划时不预建、不宣称 Gate 通过。
