# P1：实测现有编辑器，确定一份正文如何工作

**交付：** 现有产品的性能／正确性基线、文件至磁盘的责任图、唯一正文的原生可行性证明。
P1 **不修改正式文件容量**，也不为 32／64 MiB 引入新的文本存储树。
目标和禁止事项见 [需求](idea.md)。

## 现有调用链与问题

已在 `crh` 的 `874f24de` 上使用 CodeGraph 与逐字源码核对；下面列的是执行路径，而不是将来的架构假设。

| 入口与所有者 | 当前实际工作 | 需要判定／消除的成本 |
| --- | --- | --- |
| `FileTab.readContent` → `WorkspaceBackend.read` → `TextFileEncoding.decode` | 本机／SSH 完整 `Data` → 解码后的 `String`；图片后缀使用 `.max` | 容量、IO 阻塞、峰值；异常路径不能转为无界读取 |
| `FileTab.text` → `SourceTextEditor.makeScrollView` | `bufferedText` 与已挂载 `NSTextStorage` 互相取全文；首次设 `textView.text` | 不知道哪个是可写正文真源；每次投影和重载的生命周期 |
| `NativeCodeTextView.processStorageEdit` → `SourceTextEditor.Coordinator` → `FileTab.refreshDirtyState` | 原生替换通知、字符频数表、反向取全文、可逆编辑猜测 | 每键耗时、远距多选区事务、精确 Undo／手工回保存点 |
| `NativeTextLineIndex`／`NativeMeasuredLineWidths`／`configureWrapping` | 初始化全行索引；无折行时逐行测自然宽度；行数变化可重建 Fenwick | 首帧与输入回调在主线程处理大量行，长 Unicode 行可能整行物化 |
| `SyntaxHighlightCoordinator.didChangeContent` → Tree-sitter／Neon | 读取当前全文接口，解析与绘制有独立异步工作 | 必须实际量测主线程与解析任务，不能凭 `Task` 断言已经后台化 |
| `FileTab.save` → `writeCurrentText` → `WorkspaceBackend.write` | 手动／失焦各排队一个 `Task`；全文严格编码；原子写替换，无原字节版本条件 | 大文件同步编码、保存时新编辑、外部相同大小／mtime 改写被覆盖 |
| `Project.ignoreGitPaths`／`TabSwitcherView.filePreview` | 为判断行尾与 7000 单元缩略图取 `file.text` 全文 | 改动窗口外依赖时不能重新增加隐式正文镜像 |
| `PaneTab.save`／`Project`／`WorkspaceWindowModel` | 文件／Diff 分别保存；移动／关闭等待保存并保留各自目标身份 | 同路径多窗口、另存编码、待写任务与远端重连必须一起验收 |
| `DiffTab` → `DiffNativeSurface`／`DiffEngine` | 工作区编辑另有原生文档、字符频数表与自己的无条件写入 | 不要只修 Files 而遗留同一真实文件的第二条覆盖入口 |

**根因并非 8 MiB 常量太小。** 当前许多操作默认“拿到整份 String 是便宜的”，
同时以 AppKit 的原生存储和另一个 Swift 字符串表示同一份正在变化的正文。
从状态拥有者、文字来源和保存确认三处重建最短可用链，
而不是为增加容量再造 TextKit 分页器。

## 备份分支已证明哪些事情

原始提交、源码和实验留在 `back2026-11-14`；没有复制其代码或宣称新分支已通过这些实验。

| 历史证据 | 可沿用的结论 | 不沿用的东西 |
| --- | --- | --- |
| `24014251` 与当前 `NativeEditorCompositionTests` | IME 标记输入、局部 UTF-16 替换与 Undo 必须不复制整篇文本 | 用另一套输入状态机替换 AppKit |
| `3d62c14b`、`37badb70` | 重复行不能被误识别成整篇增删；旧 Diff 折叠坐标不能作用在新版本上 | 为此重写 GB 差异引擎 |
| `6c8ce391`、`17e1af48` | FileTab 可通过明确正文版本移除多处脏状态镜像；多选区必须各自发布真实范围 | `VersionedTextDocument` 的持久平衡树、GB 快照优化、第二个并行文本 owner |
| `2f96dab6`、`54030cf8`、`2eac38cf` | 本机 FIFO／设备及图片后缀是实际无界或阻塞输入；路径有 NUL 时不应被截断；BSD/GNU `stat` 参数不同 | 32 MiB 默认使用 APFS CoW、Windows 稳定租约或无限重试 |
| `a3b6c751`、`c771a930` | SSH `cat` 提前结束可能成功发布残缺文件；同大小同 mtime 外部改写会覆盖。须真实 Red→Green | GB 的分块结束协议和后台流式服务；以“SHA+rename”冒称原子 CAS |
| `4e4d8f66` | 未转义的 SSH 环境变量**名称**可以执行额外 shell 命令 | 为一处 quoting 错误新建 shell 命令框架 |
| 隔离实验 `evidence-p1.md`（本机忽略文件） | TextKit 2 冷页同步重入曾达到 768,300 次请求及约 10 GiB 内存；窗口原型从未进入产品 | 返回 `nil`／跳段落、合成假字符、GB 可视窗口与自定义全局 AX 映射 |

其余备份提交也已逐条核对：`3e911b7c`／`647922e1`／`c9b1dda7`
建立的严格 GB 分块编解码，`8dacfcff`／`b9d0d0c3` 的超大数据进程泵，
`3dee18a5`／`f1163de8` 的跨平台租约与 GB 回放，
以及 P1 原型的 GB 差异索引，都是**为已撤销目标增加的工程成本**。
32／64 MiB 先采用 Foundation 完整文件路径；仅实测无法达标时再局部改良 IO，
不因某个提交已经存在就迁移整条基础设施。

研究附件 [`vscode-source-study.md`](vscode-source-study.md) 与
[`vscode-adoption.md`](vscode-adoption.md) 保留原时代的技术来源，
**不是这条路线的实施清单**；不把其 33 项机制逐项变成新的 Todo。

<a id="p1-t1"></a>
## P1-T1：用真实产品链测出开销和失效位置

**范围：** `FileViewerView.swift`、`SourceTextEditor.swift`、`NativeCodeTextView.swift`、
`NativeTextLineIndex.swift`、`SyntaxHighlightConfiguration.swift`、
`TextFileEncoding.swift`、`WorkspaceBackend.swift`、`DiffViewerView.swift`。

1. 重放 8 MiB 以内已有宿主回归、当前文本编辑/关闭与 Git 工作区测试。
   记录实际发现／执行／跳过项目数，**不把 10 万行组件测试当成完整 `FileTab`**。
2. 在**隔离临时本机真实文件**上量测 0、8 MiB 附近、16、32、64 MiB；
   至少覆盖：10 万及更多短行、普通 Swift／Markdown、有非 ASCII 的混合行、
   超长无换行行、LF／CRLF、无／有高亮、折行两态、短长不同宽度。
   对历史发生过高内存重入的单个超长 Unicode 组合字符（30 万、85 万、120 万 UTF-16 单元），
   在**隔离测试进程**设超时与内存退出条件，不用正式 App 或无界布局赌一次成功。
   暂时超过 8 MiB 的输入在已编译原生组件中实验，**必须区分**“原生可行”和“用户打开成功”。
3. 同次运行记录：打开到首次可见／可交互、文首中尾各 30 次输入及撤销、
   17 次前后远跳、搜索／替换、编码、保存与关闭、空闲内存与并行打开五标签的峰值；
   对照 Files 与可编辑 Diff 两条真实用户路径。
4. 使用 Time Profiler／Allocations 与线程记录定位耗时，分辨读盘、复制、严格编码往返、
   Tree-sitter 首次 parse、全部行测宽、Fenwick 结构修改和保存队列的实际成本。
   记录 Debug/Release、硬件、macOS、Xcode、字体、宽度、文件内容和样本大小。
5. 与 [`docs/testing.md`](../../../docs/testing.md#性能与内存测量) 对齐：
   普通编辑 p95 ≤ 16 ms、10 万行 p95 ≤ 32 ms、连续主线程占用／滚动目标 16.7 ms；
   首开、关闭后 RSS 回落和 32／64 MiB 的额外预算用**测量结果**制定，
   不直接以放宽到 50 ms 掩盖性能下降。

**产出／验收：** 一份短的“操作 → 耗时/内存 → 责任函数 → 原始证据”表，
明确哪些瓶颈在当前主线程、哪些已经由系统或已有依赖覆盖。
对没有性能问题的路径明确**不改动**。测量命令和日志保留在现有忽略构建目录。

本次规划审查已实测
`make test:FileTabPersistenceTests,NativeEditorCompositionTests,NativeEditorLayoutTests`：
**99 项、0 失败、完整命令退出 0**，日志 `.build/plan-review/crh-editor-baseline-20261114.log`。
其中裸原生控件的 10 万行 × 折行两态 × 首中尾六组，每组 30 次输入，
实测 p95 为 **0.40～1.36 ms**；另一项十万行原生布局编辑测试 p95 约 **2.03 ms**。
同一未修改产品代码的完整 `make test` 也退出 0：**972 项、17 项跳过、0 失败**，
宿主 XCTest 约 897 秒，日志 `.build/plan-review/crh-full-baseline-20261114.log`。
跳过项不等于真实 SSH 或完整 GUI 验收。
这表明当前原生控件已有可观的日常编辑余量，**没有证明**
32／64 MiB 在正式 FileTab 加载、高亮、保存与关闭时可用，也不支持重写整个 TextKit。

<a id="p1-t2"></a>
## P1-T2：在真实 FileTab 上验证最简单的正文所有权

**优先候选：** 一个长生命周期标签拥有 `NSTextContentStorage`／`NSTextStorage`，
一个 `NSTextView` 编辑它；不可变的原始读入字节／版本只用作保存基线。
`NativeCodeTextView.init(contentStorage:)` 已是现成入口；不另建 Rope/Fragment Tree。
这是一项**待证明的候选**，不是先写入接口再迫使产品适应的决定。

- 用真实 `FileTab → SourceTextEditor → NativeCodeTextView` 检查可否在挂载前由标签持有文本存储，
  再附着唯一原生编辑器，并在 A→B→A、窗口／Dock 重挂载、外部接受新版本、关闭释放时
  维持选区与 Undo 的正确生命周期。
- 以 `.gitignore` 自动追加的**尚未挂载标签**作为反例：
  必须在无需造第二份可写 `String` 的前提下追加、写盘，并于稍后挂载时显示一致。
  已挂载时的原生 Undo 必须保持；不为当前原本没有的离屏 Undo 另造状态机。
  当前存储接口若做不到，比较“标签提前持有原生编辑器”与“一次性转移所有权”的成本，
  选在真实 App 中状态最少、无需反复重建的路径。
- 原生 `NSTextStorage.didProcessEditing` 的变更通知须成为唯一编辑事务入口；
  Unicode 坐标使用 UTF-16；远距多选区独立通知每个真实变更范围，
  不合并中间未改的大块文本。
- 脏状态必须精确区分“位置变了／仅 Unicode 规范等价／手工改回同样字节／Undo 回保存点”。
  **不能直接用 `revision != savedRevision` 代替内容比较**，也不能每键复制 32 MiB 全文。
  候选是“当前 UTF-16 长度＋由被删／被插入字符更新的简单校验和”作为**只证明不同**的快速过滤，
  过滤相等时才与保存基线做精确逐字节比较；校验和**绝不能独自证明内容相同**。
  与现有字符频数表在实际替换、重新排列和相同字符重输上比较 p95、内存及正确性，
  只有新方案实测更简单且不退化时才删除旧频数状态。
- 首次失败、保存失败、刷新失败保留上一个可靠正文；
  不保留一套 Swift 文本模型作为“隐藏备份”。真正需要恢复的数据只有明确定义的保存基线和草稿。

**决策门槛：** 产出一张“唯一可写正文／不可变保存基线／派生视图／写入后端”的责任图，
一组可复现的文件、IME、多光标与卸载测试，
以及**明确要删除的可达旧符号**：
`FileTab.bufferedText/nativeTextIsCurrent/reversibleEdit/restoredSavedBytes`、
`SourceTextEditor.Coordinator.currentText` 等只在接入等价行为后退出；
`DiffTab` 当前类似状态另归 P3 处理。

若原生 TextKit 的完整 32 MiB 编辑确实受可复现的系统瓶颈限制，
先给出完整原生失败证据和最小可行上限，回到需求决定；
不得偷偷改为只读、增加 GB 窗口模拟或第二套编辑器。

## P1 结束前的判断

- **Go：** 真实原生文本存储的生命周期、Undo、Find/AX 与 32 MiB 组件输入可行，
  性能热点与预算可定位，方案不要求另建分块文件引擎；进入 P2。
- **No-Go：** 未能证明同步原生布局、输入或资源边界可接受；保留原 8 MiB 门限，
  给出最小失败示例与修正方向，而不是把风险推给 P2。
- 任何实验只影响本仓库生成的临时文件与隔离宿主测试；旧系统与真实 Windows SSH
  缺少可用测试环境时记录原因与影响，不通过修改用户系统、正式 App 或新建 VM 补证。
