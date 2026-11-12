# VS Code / Monaco 大文件架构：源码研究与 Bailey 设计依据

## 阅读结论

**Monaco 是全量驻留的分块文本模型，具备局部编辑与虚拟渲染；它不是按需读取磁盘的 GB 文档引擎。**
VS Code 的流式传输、增量解码、Piece Tree、worker 和可见区绘制分别解决不同成本，
没有组合出“全文尚未读取／解码、驻留受固定预算约束、所有编辑功能仍完整可用”的保证。

本报告以研究开始时 GitHub HEAD
[`530b702bc1ecca912e842e906fa67ecfc60c091e`](https://github.com/microsoft/vscode/commit/530b702bc1ecca912e842e906fa67ecfc60c091e)
为唯一上游基线，提交时间 **2026-11-12 09:36:27 UTC**。
“最新”指本次取证时固定的 HEAD，不是会随分支移动的链接。
Monaco 核心直接审计 VS Code 的 `src/vs/editor`；不是从说明文档或 npm 包描述推导。
本次下载该 SHA 的源码、逐字追踪调用链，未运行 VS Code GB 基准。
Piece Tree、TextModel、基础 View 与 Diff 核心位于 `src/vs/editor`；
TextMate 集成、文件服务、Remote 和 Git 扩展属于 VS Code 的外层服务。
这些外层能力不能自动归给独立 `monaco-editor` 包。

续查最新 HEAD 为 [`15f8b54d0d15b89ca885e2aa87800848a53050f6`](https://github.com/microsoft/vscode/commit/15f8b54d0d15b89ca885e2aa87800848a53050f6)
（2026-11-12 10:00:41 UTC），相对首轮仅改变 package.json 的 distro，本文相关源码未变。
新增的 [33 项机制吸收设计](vscode-adoption.md)逐项说明成熟机制如何接入 Bailey、
替代哪条全文链及怎样验证，并已写回 P1／P2／P3。
续查也纠正了本文原先对 Diff 编辑后重基的描述：实际 helper 直接返回 undefined，
不能由调用点推断已经实现；准确控制流见下文“取消与输入并发”。

| 用户关心的问题 | 源码已实现的能力 | 实际边界 |
| --- | --- | --- |
| 模型与打开 | 流式解码、多块字符串、Piece Tree 局部编辑 | 等 EOF 后创建模型；所有原始块和块内行索引常驻 [M01] [M02] [M03] |
| 渲染与长行 | 可见行 DOM／实验 GPU 渲染、超长行绘制截断 | 绘制截断之前仍可取得整条巨行；非 large 模式还有全行投影 [M15] [M18] [M22] |
| 编辑、IME、Undo | 范围编辑、增量事件、替换片段 Undo | 大选区输入上下文、单行 composition、批量合并和大范围 Undo 仍可物化巨量文本 [M08] [M09] [M10] [M32] [M33] |
| 查找替换 | 单行搜索、结果限额、普通编辑事务 | 多行搜索构造整个 scope；大量全篇替换走全文 String.replace [M35] [M36] [M37] |
| 本机与 Remote IO | provider 分块读写、流式编解码、真实读取取消 | 不是稳定文件快照；公开 Remote 传输链不能证明全程硬背压 [IO04] [IO05] [IO11] [IO12] [IO74] [IO75] [IO80] |
| 保存与冲突 | 分块 snapshot、保存串行化、版本核对 | 默认直接写目标；etag 不是强一致 CAS；atomic write 特定分支反而合并完整 buffer [IO36] [IO39] [IO53] |
| Git Diff | 两侧完整模型、worker 行级／字符级算法、超时反馈 | Git provider／worker／算法各有全文持有；没有外存分页 Diff [G02] [G03] [G07] [G16] |

### 如何读证据

- **源码事实**：本 SHA 的实际分支、数据结构、数值及调用者；每节附精确路径、关键符号和永久链接。
- **设计限制**：从必经接口、全量数组或明确 guard 可直接推出的能力边界；
  不将配置声明自动视为已执行的限制。
- **推断／待验证**：运行时峰值、延迟、平台文件系统行为及某种 GB 文件实际能否打开；
  本报告没有用静态源码冒充这些实测结果。
- Bailey 对照固定本轮开始的本地提交 `6a8ffc4e27d69791cb5deddc4ad42149bae31765`。
  这批产品修复已经在当前树，不能因为历史实验文件缺失而撤销或重复实现。
  Bailey 链接指向仓库内实际源码，行号按此基线记录。

导航：[文本模型与编辑渲染](#model-editor) · [文件 IO](#file-io) ·
[Git Diff](#git-diff) · [Bailey 当前架构](#bailey-current) ·
[计划决策与验证边界](#bailey-decisions)。

<a id="model-editor"></a>
## 一、文本模型、编辑与渲染

### 1. 模型：Piece Tree 不是文件分页器

#### 调用链

`createTextBufferFactoryFromStream(stream)`
→ `PieceTreeTextBufferBuilder.acceptChunk(string)`
→ `_acceptChunk2`
→ `chunks.push(new StringBuffer(...))`
→ **收到 onEnd** 后 `builder.finish()`
→ `PieceTreeTextBufferFactory.create(defaultEOL)`
→ `new PieceTreeTextBuffer(chunks,...)`
→ `PieceTreeBase.create(chunks,...)`
→ `TextModel._buffer`。

- [M01] 的 Promise 在 onEnd 才 resolve；没有“首块完成便发布部分 TextModel”的路径。
- [M02] 持有所有 `StringBuffer`；每块都是 JS string 加行起点数组。
- [M03] 把所有原始块加入 `_buffers`；第 0 项是新增文本 buffer，其余是原始 buffers。
  未见文件 fd、按需读取、缓存淘汰或“未知长度”的模型状态。
- [M04] 红黑树节点保存 `Piece`、左子树字符数 `size_left` 和换行数 `lf_left`；
  Piece 引用 buffer 的起止坐标，编辑主要切分/连接 pieces，并维护树元数据。
  这改善随机定位及局部编辑成本，但不改变正文全量常驻的前提。

`AverageBufferSize=65535` 是新增大文本切块以及换行规范化重建时的目标粒度；
不能把它写成“所有读取页固定 64 KiB”，更不能当作磁盘分页或全程缓存上限。[M38]

行起点保存为 `Uint16Array` 或 `Uint32Array`：
最后一个 offset 小于 65536 时选前者，否则选后者。
避免“一行一个独立字符串对象”是收益，但换行索引总量仍随全文行数增长。[M03]

#### 编码与坐标

Piece Tree 操作的是 JS string，`length`、`charCodeAt`、`substring` 与 offsets 均是 UTF-16 code units。
这不是原文件 UTF-8 byte offsets，也不是 Unicode scalar count 或用户眼中的字素数。

`acceptChunk` 暂存块尾 CR 或高代理项，交给下一块，防止 CRLF/代理对在 builder 的块边界拆坏；
第一块可剥离 BOM 并另存。[M02]
文件编码解码发生在 IO 层；Piece Tree 本身不保存原编码的 byte→UTF16 映射。
JS string 的实际物理表示由引擎决定，不能机械写成“文件大小乘 2 就是全部内存”。

默认 `finish(normalizeEOL=true)`。
factory 根据全文 CR/LF/CRLF 数选择单一 EOL，在需要时遍历块并 `replace(/\r\n|\r|\n/g,eol)`，
插入文本也会规范化到模型 EOL；`setEOL` 会重建正文块。[M02] [M06]
因此 Monaco 的模型文本不能作为“混合换行原始字节原样保存”的参照实现。

### 2. 普通编辑如何避免每键全文复制

#### 调用链

`ViewController.type/compositionType`
→ `CodeEditorWidget._createView` 提供的 commandDelegate（普通编辑器走 Handler 命令，simple widget直接调用）
→ `CodeEditorWidget._type/_compositionType`
→ `ViewModel.type/compositionType`
→ `CursorsController.type/compositionType`
→ `TypeOperations...`
→ `CursorsController._executeEditOperation`
→ `CommandExecutor.executeCommands`
→ `TextModel.pushEditOperations`
→ `EditStack.pushEditOperation`
→ `TextModel.applyEdits(...,true)`
→ `PieceTreeTextBuffer.applyEdits`
→ `_doApplyEdits`
→ `PieceTreeBase.delete/insert`。[M52] [M46] [M53] [M07] [M55] [M54] [M08] [M56] [M09]

TextModel 发出带 range、rangeOffset、rangeLength、replacement text 的增量事件；
装饰、视图和镜像可消费局部变化。
PieceTree 插入拆分当前 Piece，并可合并追加在 change buffer 末端的小插入。
没有调用 `getValue()` 将整篇重新绑定给 UI。[M05] [M08]

这不代表每次输入都严格 O(log N)：
输入自身、涉及的行、撤销文本、语法和视图派生工作仍有成本；
单个极长逻辑行可迫使 `getLineContent` 构造巨串。

#### Undo / Redo

- `PieceTreeTextBuffer.applyEdits` 为每个操作读取被替换范围，生成 `TextChange(oldPosition,oldText,newPosition,newText)`。[M09]
- `EditStack` 合并相邻更改、保存编辑前后 selection、EOL、alternative version；
  stack element close 时序列化为 ArrayBuffer，Undo/Redo 反序列化后应用反向/正向 edit。[M10]
- `TextChange` 序列化 positions 和 string lengths 使用 UInt32，文本逐 UTF-16LE 单元写入。
  这是格式约束，不能据此承诺任意超过 2^32 文本单位的可撤销编辑。[M11]
- 大范围删除/替换仍需要大范围 `oldText`；序列化还要分配对应大小 ArrayBuffer。
  所以“局部编辑增量 Undo”成立，“无限 Undo 且恒定内存”不成立。
- 当操作可合并且数量达到 1000，`_reduceOperations` 会把首尾操作之间的整个区间拼为一次大替换；
  `_isTracked` 操作会阻止此归并。不能把格式化/replace-all 当成普通单键成本。[M12]

`MAX_MEMORY_FOR_CLOSED_FILES_UNDO_STACK=20*1024*1024` 只约束关闭文件后保留的 Undo，
不是打开文档的全局 Undo 内存预算。
关闭时若 Undo 太大，或 SHA1 不允许计算，会丢弃该文件的可恢复 Undo；
默认 SHA1 上限为模型长度 `<=10*1024*1024` 个 UTF-16 单元。[M13] [M39]

#### 保存快照只避免单个全文串

`TextModel.createSnapshot`
→ `TextModelSnapshot`
→ `PieceTreeSnapshot`。
后者先遍历全树收集所有 Piece 引用，read 再依次读取 Piece 内容。
外层通常聚合到至少 `64*1024` 个 UTF-16 单元后返回；单个 Piece 可能更大，
所以这不是严格 64 KiB 上限。
快照元数据随 Piece 数增长，正文仍全量在内存。[M14]

该快照不是可直接照搬的多线程持久树。
源码注释明确要求 normalization 不与 snapshot reading 并行；
快照引用当前 tree/buffers，不应仅凭名字推断跨 actor 原子性。[M03]

### 3. 渲染：可见行虚拟化与长行限制

#### 默认 DOM 路径

`View` 计算 `ViewportData`
→ `ViewLines.renderText(viewportData)`
→ `VisibleLinesCollection.renderLines`
→ `ViewLayerRenderer.render(startLineNumber,endLineNumber,...)`
→ 复用交集中的行、移除视口外行、插入新可见行
→ `ViewLine.renderLine`
→ `getViewLineRenderingData`
→ `renderViewLine`。[M15] [M16]

DOM 中的正文行数量随视口变化，不为整篇创建一整套 DOM。
垂直几何还把大坐标按 500,000 px 分段平移，
文本 DOM 高度被限制为 `min(scrollHeight,1,000,000)`；
逻辑滚动与实际 DOM 坐标分开。[M15] [M17]

这只证明渲染虚拟化。
普通 `ViewModelLinesFromProjectedModel._constructLines` 会调用 `model.getLinesContent()`，
为全文行建立 projections 和 prefix sums；改折行设置会重新构建。
被判大文件时改走 `ViewModelLinesFromModelAsIs`，
其 `setWrappingSettings`、`setHiddenAreas` 均返回 false。
因此大文件默认策略确实牺牲折行和折叠来省内存，并非保持全部功能的分页视图。[M18] [M40] [M41]

#### 超长行

`editor.stopRenderingLineAfter` 默认 10000，`-1` 表示不截断。[M19]
`resolveRenderLineInput` 在 lineContent.length 超过该数时只渲染前段，
渲染末尾有 “Show more”；
`LongLinesHelper` 点击边界后将该选项改为 -1。[M20] [M21]

此限制发生在**已经取得行字符串之后**。
`PieceTreeBase.getLineContent` / `getLineRawContent`
会跨 pieces 拼接整个逻辑行并缓存最近一行。[M22]
DOM 路径也不是以水平小窗口按需向文件读取；
整个 view line 的内容作为 RenderLineInput，绘制截断与底层字符串成本是两回事。
因此不能以 10,000 字符绘制限额证明 GB 单行可用。

#### 实验 GPU 路径

`editor.experimentalGpuAcceleration` 默认 off；
开启后 `ViewLinesGpu` 有 full-file/viewport 两种 render strategy。
当前 full-file storage 的界限为 3000 行、200 列；
视口越界时切换 viewport strategy。
`ViewGpuContext.canRender` 对 RTL、超过 2000 的 maxColumn 或不支持的样式返回 false，
由 DOM 路径继续处理。
这些是绘制缓存/能力边界，正文仍是同一全量 TextModel。[M23] [M24] [M42]

### 4. 语法高亮：默认 TextMate、实验 Tree-sitter、semantic tokens 必须区分

#### 默认 tokenizer / TextMate

`TextModel` 构造时判定大文件
→ `TokenizationTextModelPart`
→ `TokenizerSyntaxTokenBackend.initializeTokenization`
→ 大文件返回 `[null,null]`，不创建正常 tokenizer。[M25] [M43]

普通文档沿可见行优先的 `refreshRanges → tokenizeHeuristically` 快速着色，
再请求 background tokenizer 校正。
TextMate worker 初次注册模型使用 `getLinesContent()` 发送全文行数组，
后续发增量；这会增加镜像，并非按需只发送屏幕文本。[M26]

`editor.maxTokenizationLineLength` 默认 20,000；
`TokenizationSupportWithLineLimit.tokenizeEncoded` 条件是 `line.length >= limit`，
达到阈值就返回默认样式 token，并原样保留传入的非空 state，不解析该行。[M27] [M57]
这是 tokenization 降级，正文不因此截断。

#### 实验 Tree-sitter

最新源码并非只有 TextMate。
`TokenizationTextModelPart._useTreeSitter`
→ `TreeSitterLibraryService.supportsLanguage`
→ `editor.experimental.preferTreeSitter.<language>`。
当前 css/typescript/ini/regex schema 默认均 false。[M28] [M44]

开启后：

`TreeSitterSyntaxTokenBackend`
→ `TreeSitterTree`
→ 首次 `handleContentChange(undefined)`
→ `_parseAndYield`
→ `parser.parse(callback,oldTree,{includedRanges})`
→ `_parseCallback`
→ `textModel.getTextBuffer().getNearestChunk(index)`。[M29]

此处按现存 Piece Tree 的 chunk 喂给 parser，避免要求一次 getValue；
首次默认范围仍是整篇，已有树可增量编辑。
progressCallback 在经过 >50ms 时请求让出，外层 setTimeout0 后继续；
它限制单次事件循环占用，不是总解析时间、内存或文件读取限额。
完成后保留当前 tree 及两次 tree.copy() 的结果；
依赖可能共享底层节点，不能声称 AST 物理占用必定三倍。[M29] [M45]

所读 TreeSitterSyntaxTokenBackend / TreeSitterTree 没有默认 tokenizer 的
`isTooLargeForTokenization()` guard；
所以应写“默认 tokenizer 路径降级”，不能把这一阈值泛化到实验路径。

#### Semantic tokens / 扩展

`DocumentSemanticTokensFeature` 按配置/主题创建 watcher，
附着编辑器且有 provider 时请求文档 semantic tokens；
这条功能没有同一 20Mi 单元的统一 hard guard。[M30]
实际能力依赖 provider、是否允许模型同步、扩展自身限制。
不能把 TextMate 20Mi 阈值说成“全部语言服务都按这个数关闭”。

### 5. IME：输入宿主不是全文编辑 DOM，但仍有大范围物化

#### 当前默认 NativeEditContext

`editor.editContext` 默认 true，只有环境支持才生效；
`View._instantiateEditContext` 在 NativeEditContext 与 textarea 实现间选择。[M31]
这里的 “Native” 是浏览器 EditContext API，不是 AppKit/TextKit。

`compositionstart/end`
→ `ViewController.compositionStart/end`
→ `CursorsController.startComposition/endComposition`；
`textupdate`
→ `NativeEditContext._emitTypeEvent`
→ 按更新范围推导 replacePrevCharCnt/replaceNextCharCnt
→ `ViewController.compositionType/type`
→ 同一 TextModel edit 链。[M32] [M07]

关键限制：`_getNewEditContextState` 读取主选区从起始行第1列到终止行行尾的完整 range，
经 `getValueInRange` 放进 EditContext。
单行光标也会请求整行；大范围选择/全选可能物化全文。
不是固定大小的光标周边窗。[M32]

`CompositionState._capture` 对各个单行 selection 保存 `getLineContent(lineNumber)`，
组合结束再次读行、比较公共前后缀；跨行 selection 返回 null。
这避免普通多行文件的全文快照，却没有消除 GB 单行的整行快照。[M33]

#### textarea 与辅助功能

textarea fallback 在无屏幕阅读器的 macOS 场景只放光标前的字/词，
或长度 <500 的选区；其余可为空/平台 placeholder。
屏幕阅读器走 `SimplePagedScreenReaderStrategy`，
按页面取选区前后文；Unknown 模式会裁到500单元附近，
但真实 screen reader 模式不套同一 trim 开关。[M34]

注意其部分分支先 `getValueInRange(selection)` 再 substring；
所以最终输入框字符串很短也不等价于取值过程没有大临时串。
这是输入上下文分页，不是正文分页；不能替代 TextKit 2 自身协议的实测。[M47]

显式复制同样要单独核验：`getDataToCopy` → `ViewModel.getPlainTextToCopy`
→ 每个选区调用 `model.getValueInRange`，多个选区再 join。
全选复制因此会形成整篇纯文本；通常 65536 门槛只跳过富文本附加生成，
不是纯文本传输/临时字符串的内存上限。[M48] [M49]

### 6. 查找替换：有明确的整篇分配路径

#### 查找

`TextModel.findMatches`：
普通不含换行的文本 → PieceTree `findMatchesLineByLine`；
其它请求 → `TextModelSearch.findMatches` 再判断是否 multiline。
单行 regex 仍可逐行搜索，不能写成所有 regex 都全文拼接。[M35]

跨行分支 `_doFindMatchesMultiline` 先
`model.getValueInRange(searchRange, EndOfLinePreference.LF)`；
默认 searchRange 是全篇，因此会形成完整搜索字符串。
CRLF 用 LineFeedCounter 补偿 offsets。
Find next 跨行也拼从起点到文件末尾；previous 可拼文件开头到当前位置。[M36]

这些 model search 循环同步执行；所读代码没有时间片/取消参数。
不能把匹配结果数限制当成 CPU 时间、regex 回溯或全文分配上限。
逐行 literal 搜索也不等于“巨型单行无需拼接”：跨 piece 的当前行仍可能由 getLineContent 物化。[M22] [M35]

#### 替换

Find UI 的 `MATCHES_LIMIT=19999` 与 TextModel 默认 `LIMIT_FIND_COUNT=999` 是不同层。[M37] [M01]

`FindModelBoundToEditorModel.replaceAll`：
未限定 scope 且 matchesCount>=19999
→ `_largeReplaceAll`
→ `model.getValue(LF)`
→ `String.replace`
→ `ReplaceCommandThatPreservesSelection(fullModelRange,resultText)`。
这明确是整篇字符串替换；再结合 Undo 可同时保留旧/新大文本。[M37]

普通 replace-all 也会取出所有 matches（上限参数用 MAX_SAFE_SMALL_INTEGER）
及 replacement string 数组，再执行 ReplaceAllCommand，
不是有界流式边扫边替换。
高匹配数输入需单独验收，不能从一次小查找成功外推。

### 7. 阈值表：原样记录条件与适用范围

| 项目 | 实际阈值/比较 | 单位/作用 |
| --- | --- | --- |
| 默认大型模型判定 | length >20×1024²，或 lines >300000 | length是UTF-16单元；largeFileOptimizations=true才生效；默认tokenizer、折行、折叠等降级 |
| 常规模型同步 | length >50×1024² | UTF-16单元；一般worker/extension镜像不建立；Diff可forceLargeModels绕过该门槛 |
| 防止巨串操作 | length >256×1024² | UTF-16单元；largeFileOptimizations=true才生效；getValue/getLinesContent抛异常；getValueInRange无同样guard |
| DOM长行绘制 | 默认10000；-1禁限额 | view-line UTF-16单元；仅绘制；可点击Show more |
| 默认TextMate长行 | line.length >=20000 | UTF-16单元；不给该行做语法tokenization |
| Find UI显示匹配 | 19999 | 匹配数；全篇replaceAll达到此数改用整串策略 |
| TextModel默认find limit | 999 | API默认返回匹配数；调用方可覆盖 |
| Undo归并 | operations.length >=1000且canReduce | 归并为跨首尾操作的一个大replacement |
| 关闭文件Undo缓存 | 20×1024² | 序列化堆用量bytes；不是所有打开文档的Undo上限 |
| 关闭后Undo的默认SHA1条件 | valueLength <=10×1024² | UTF-16单元；过大不保留恢复栈 |
| PieceTree新增大块 | >65535切块 | UTF-16单元；不是原始IO固定页/缓存上限 |
| 文本snapshot聚合 | accumulatedLength >=64×1024即return | UTF-16单元；不是严格最大值 |

前三种标志都是构造 TextModel 时计算并固定，
不是每次编辑后动态重算；后续内容变大/变小不会自动改换这些标志。[M25]

### 8. 哪些环节仍会完整加载或完整扫描

| 路径 | 实际处理范围 |
| --- | --- |
| 初次stream→TextModel | 全文解码后留存所有chunks及行起点；等EOF |
| 非large projected view初始化/重折行 | getLinesContent + 每行projection |
| 默认worker/extension初始同步 | getLinesContent全文行数组；后续才增量 |
| TextMate worker初始化 | 全文行数组，后台语法状态随文本增长 |
| 实验Tree-sitter首次解析 | 逐chunk读取已驻留全文，形成整篇树 |
| getLineContent / 原生EditContext / CompositionState | 可能完整巨型单行；EditContext的大选区还可包含全篇 |
| 多行查找 | 完整搜索scope串，默认全篇 |
| 全篇大量replace-all | 完整旧文本+新文本；Undo附加成本 |
| 大范围Undo/批量edit合并 | 整个被替换区间 |
| 全选复制/多选区剪切 | 选区完整纯文本，多个范围可再join；富文本门槛不限制纯文本 |
| EOL改变 | 遍历并重建各正文块 |
| 保存snapshot | 扫遍所有piece和正文；无需必然单个全文串，但原模型已在内存 |

没有从这些源码得到“所有 GB 文件、所有基本编辑功能、有界驻留”保证。
适当编码、行分布和足够内存下某个 GB 文件可能被打开，是必须实测的容量结果；
它不等同于 Bailey 要求的 GB 按需完整编辑。
精确的 V8 string/heap 上限还取决于运行时版本/架构，不从旧博客或旧配置推导当前固定上限。

### 可见源码路径与关键符号索引

以下路径均相对于固定的 `microsoft/vscode` 仓库根目录；点击路径进入对应 SHA 的行区间。
同一文件的其它关键区间由各节的 M 编号链接补齐，调用顺序见前文对应调用链。

| 责任／调用链环节 | 完整源码路径 | 关键符号与定位 |
| --- | --- | --- |
| 流结束后建立模型、大小标志与全文访问 | [src/vs/editor/common/model/textModel.ts][M01] | `createTextBufferFactoryFromStream`；`TextModelSnapshot`；[构造时阈值][M25]；[getValue / getValueInRange / getLinesContent][M51] |
| 字符串块与换行规范化 | [src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBufferBuilder.ts][M02] | `PieceTreeTextBufferBuilder.acceptChunk / finish`；`PieceTreeTextBufferFactory.create` |
| 完整 backing、分片、整行与快照 | [src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts][M03] | `StringBuffer`、`PieceTreeSnapshot`、`PieceTreeBase.create`；[insert][M05]；[normalizeEOL][M06]；[getLineContent][M58]／[getLineRawContent][M22]；[createNewPieces][M38] |
| 红黑树汇总 | [src/vs/editor/common/model/pieceTreeTextBuffer/rbTreeBase.ts][M04] | `TreeNode.piece / size_left / lf_left` |
| 范围修改与大批操作归并 | [src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.ts][M09] | `applyEdits / _doApplyEdits`；[_reduceOperations][M12] |
| 输入命令委托 | [src/vs/editor/browser/view/viewController.ts][M52]；[src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts][M46] | `ViewController.type / compositionType` → `CodeEditorWidget._createView` 的 commandDelegate → `_type / _compositionType` |
| 视图模型路由与复制 | [src/vs/editor/common/viewModel/viewModelImpl.ts][M53] | `ViewModel.type / compositionType / _executeCursorEdit`；[大模型视图选择][M40]；[getPlainTextToCopy][M48] |
| 光标命令执行与 IME 行快照 | [src/vs/editor/common/cursor/cursor.ts][M07]；[src/vs/editor/common/cursor/cursorTypeOperations.ts][M55] | `CursorsController._executeEditOperation`、`TypeOperations`；[CommandExecutor.executeCommands / _innerExecuteCommands][M54]；[CompositionState._capture][M33] |
| Undo 构造与序列化 | [src/vs/editor/common/model/editStack.ts][M56]；[src/vs/editor/common/core/textChange.ts][M11] | `EditStack.pushEditOperation` → `TextModel.applyEdits`；[SingleModelEditStackElement.close / undo / redo][M10]；`TextChange.write / read` |
| 关闭文档后的 Undo 预算 | [src/vs/editor/common/services/modelService.ts][M13] | `ModelService._onWillDispose`；[MAX_MEMORY_FOR_CLOSED_FILES_UNDO_STACK][M39]；默认 SHA1 长度限制 |
| 可见行 DOM 增删与单行绘制 | [src/vs/editor/browser/viewParts/viewLines/viewLines.ts][M15]；[src/vs/editor/browser/view/viewLayer.ts][M16]；[src/vs/editor/browser/viewParts/viewLines/viewLine.ts][M61] | `ViewLines.renderText` → `VisibleLinesCollection.renderLines`／`ViewLayerRenderer.render` → `ViewLine.renderLine` |
| 几何平移、绘制截断与 Show more | [src/vs/editor/common/viewLayout/linesLayout.ts][M17]；[src/vs/editor/common/viewLayout/viewLineRenderer.ts][M20]；[src/vs/editor/contrib/longLinesHelper/browser/longLinesHelper.ts][M21] | 大滚动坐标平移；`resolveRenderLineInput / renderViewLine`；`LongLinesHelper` |
| 全文投影与大文件关闭折行／折叠 | [src/vs/editor/common/viewModel/viewModelLines.ts][M18] | `ViewModelLinesFromProjectedModel._constructLines`；[ViewModelLinesFromModelAsIs.setWrappingSettings / setHiddenAreas][M41] |
| 实验 GPU 渲染 | [src/vs/editor/browser/viewParts/viewLinesGpu/viewLinesGpu.ts][M23]；[src/vs/editor/browser/gpu/renderStrategy/fullFileRenderStrategy.ts][M42]；[src/vs/editor/browser/gpu/viewGpuContext.ts][M24] | `ViewLinesGpu` strategy 切换；`FullFileRenderStrategy`；`ViewGpuContext.canRender` |
| 选项及默认值 | [src/vs/editor/common/config/editorOptions.ts][M19]；[src/vs/editor/common/config/editorConfigurationSchema.ts][M44] | `stopRenderingLineAfter`；`editContext`；`experimentalGpuAcceleration`；`maxTokenizationLineLength`；Tree-sitter 语言开关 |
| 默认 tokenizer 与 TextMate 镜像 | [src/vs/editor/common/model/tokens/tokenizerSyntaxTokenBackend.ts][M43]；[src/vs/workbench/services/textMate/browser/backgroundTokenization/textMateWorkerTokenizerController.ts][M26] | `TokenizerSyntaxTokenBackend.initializeTokenization`；`TextMateWorkerTokenizerController` 初次 `getLinesContent` |
| TextMate 长行跳过 | [src/vs/workbench/services/textMate/browser/tokenizationSupport/tokenizationSupportWithLineLimit.ts][M27]；[src/vs/editor/common/languages/nullTokenize.ts][M57] | `tokenizeEncoded` → `nullTokenizeEncoded`，默认样式 token、保留传入 state |
| 实验 Tree-sitter 路由 | [src/vs/editor/common/model/tokens/tokenizationTextModelPart.ts][M28]；[src/vs/workbench/services/treeSitter/browser/treeSitterLibraryService.ts][M63]；[src/vs/editor/common/model/tokens/treeSitter/treeSitterSyntaxTokenBackend.ts][M62] | `_useTreeSitter` → `supportsLanguage` → `TreeSitterSyntaxTokenBackend` 建立 `TreeSitterTree` |
| Tree-sitter 完整首次解析与让出 | [src/vs/editor/common/model/tokens/treeSitter/treeSitterTree.ts][M29] | `handleContentChange / _parseAndYield / _parseCallback`；[progressCallback 的 50 ms 判断][M45] |
| 文档 semantic tokens | [src/vs/editor/contrib/semanticTokens/browser/documentSemanticTokens.ts][M30] | `DocumentSemanticTokensFeature`；文档 watcher 的 provider 请求条件 |
| 浏览器输入宿主选择 | [src/vs/editor/browser/view.ts][M31]；[src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts][M32] | `View._instantiateEditContext`；`NativeEditContext._emitTypeEvent / _getNewEditContextState` |
| textarea 与 screen reader 输入上下文 | [src/vs/editor/browser/controller/editContext/textArea/textAreaEditContext.ts][M34]；[src/vs/editor/browser/controller/editContext/screenReaderUtils.ts][M47] | `TextAreaEditContext` 的写入状态；`SimplePagedScreenReaderStrategy` 的选区／上下文读取 |
| 剪贴板纯文本 | [src/vs/editor/browser/controller/editContext/clipboardUtils.ts][M49] | `getDataToCopy` → `ViewModel.getPlainTextToCopy`；富文本附加数据的独立门槛 |
| 搜索与大量替换 | [src/vs/editor/common/model/textModelSearch.ts][M36]；[src/vs/editor/contrib/find/browser/findModel.ts][M37] | [TextModel.findMatches][M35] → `TextModelSearch._doFindMatchesMultiline`；`FindModelBoundToEditorModel.replaceAll / _largeReplaceAll` |
| Worker 与扩展初始镜像 | [src/vs/editor/common/services/textModelSync/textModelSync.impl.ts][M50]；[src/vs/editor/common/model.ts][M59]；[src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts][M60] | worker 的 `forceLargeModels`／同步检查；扩展 `shouldSynchronizeModel`；`_toModelAddData` 发送全文行数组 |

### 源码永久链接

[M01]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L57-L170
[M02]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBufferBuilder.ts#L13-L188
[M03]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L16-L318
[M04]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/rbTreeBase.ts#L8-L27
[M05]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L849-L901
[M06]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L268-L367
[M07]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/cursor/cursor.ts#L354-L395
[M08]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L1340-L1601
[M09]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.ts#L243-L381
[M10]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/editStack.ts#L193-L239
[M11]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/core/textChange.ts#L17-L95
[M12]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBuffer.ts#L420-L515
[M13]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/modelService.ts#L500-L589
[M14]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L130-L170
[M15]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/viewParts/viewLines/viewLines.ts#L613-L676
[M16]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/view/viewLayer.ts#L357-L460
[M17]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewLayout/linesLayout.ts#L620-L651
[M18]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewModel/viewModelLines.ts#L126-L169
[M19]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/config/editorOptions.ts#L6880-L6883
[M20]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewLayout/viewLineRenderer.ts#L474-L505
[M21]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/contrib/longLinesHelper/browser/longLinesHelper.ts#L19-L35
[M22]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L1253-L1322
[M23]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/viewParts/viewLinesGpu/viewLinesGpu.ts#L332-L353
[M24]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/gpu/viewGpuContext.ts#L157-L202
[M25]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L188-L368
[M26]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textMate/browser/backgroundTokenization/textMateWorkerTokenizerController.ts#L83-L100
[M27]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textMate/browser/tokenizationSupport/tokenizationSupportWithLineLimit.ts#L34-L51
[M28]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/tokens/tokenizationTextModelPart.ts#L64-L81
[M29]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/tokens/treeSitter/treeSitterTree.ts#L303-L358
[M30]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/contrib/semanticTokens/browser/documentSemanticTokens.ts#L231-L275
[M31]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/view.ts#L308-L314
[M32]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/controller/editContext/native/nativeEditContext.ts#L427-L508
[M33]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/cursor/cursor.ts#L1053-L1125
[M34]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/controller/editContext/textArea/textAreaEditContext.ts#L206-L265
[M35]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L1174-L1224
[M36]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModelSearch.ts#L161-L224
[M37]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/contrib/find/browser/findModel.ts#L515-L583

[M38]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L1164-L1202
[M39]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/modelService.ts#L84-L86
[M40]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewModel/viewModelImpl.ts#L94-L121
[M41]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewModel/viewModelLines.ts#L1152-L1166
[M42]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/gpu/renderStrategy/fullFileRenderStrategy.ts#L54-L65
[M43]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/tokens/tokenizerSyntaxTokenBackend.ts#L93-L115
[M44]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/config/editorConfigurationSchema.ts#L125-L159
[M45]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/tokens/treeSitter/treeSitterTree.ts#L437-L446
[M46]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/codeEditor/codeEditorWidget.ts#L1928-L1974
[M47]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/controller/editContext/screenReaderUtils.ts#L51-L106
[M48]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewModel/viewModelImpl.ts#L1005-L1055
[M49]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/controller/editContext/clipboardUtils.ts#L48-L75
[M50]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/textModelSync/textModelSync.impl.ts#L91-L118


[M51]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L799-L875
[M52]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/view/viewController.ts#L51-L92
[M53]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/viewModel/viewModelImpl.ts#L1202-L1224
[M54]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/cursor/cursor.ts#L767-L820
[M55]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/cursor/cursorTypeOperations.ts#L16-L97
[M56]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/editStack.ts#L428-L440
[M57]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/languages/nullTokenize.ts#L22-L34
[M58]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L613-L628
[M59]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model.ts#L1624-L1628
[M60]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts#L376-L387
[M61]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/viewParts/viewLines/viewLine.ts#L103-L207
[M62]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/tokens/treeSitter/treeSitterSyntaxTokenBackend.ts#L22-L79
[M63]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/treeSitter/browser/treeSitterLibraryService.ts#L22-L131

补充定位（上表同一 SHA）：

- 所有原始 buffers 的持有：`pieceTreeBase.ts:268–318`。
- 新插入 >65535 的分块：`pieceTreeBase.ts:1164–1202`。
- `TextModel.createSnapshot/getValue/getLinesContent`：`textModel.ts:799–875`。
- EditStack 真正调用 applyEdits：`editStack.ts:428–440`。
- 当前大文件不投影选择：`viewModelImpl.ts:49,94–121`。
- 大文件关闭折行/折叠：`viewModelLines.ts:1152–1166`。
- GPU 默认 off、EditContext 默认 true：`editorOptions.ts:6426–6450`。
- TextMate默认20,000：`editorConfigurationSchema.ts:94–97`。
- 默认tokenizer大文件guard：`tokenizerSyntaxTokenBackend.ts:93–115`。
- 默认tokenizer可见行优先：`tokenizerSyntaxTokenBackend.ts:223–255`。
- Tree-sitter各语言默认false：`editorConfigurationSchema.ts:125–159`。
- Tree-sitter 50ms yield：`treeSitterTree.ts:437–446`。
- Paged screen reader trim发生前的取值：`screenReaderUtils.ts:51–106`。
- 常规模型镜像/forceLargeModels：`textModelSync.impl.ts:91–118`。
- Extension host门禁：`model.ts:1624–1628`；全文初发：`mainThreadDocumentsAndEditors.ts:381`。

<a id="file-io"></a>
## 二、本机与 Remote SSH 的文件 IO

### 2. 文件打开：真实调用链及全量边界

#### 2.1 入口至模型

`FileEditorInput.resolve → doResolveAsText → textFileService.files.resolve
→ TextFileEditorModel.resolve → doResolve → resolveFromFile
→ AbstractTextFileService.readStream → doRead → FileService.readFileStream
→ provider.readFileStream / open-read-close / readFile
→ toDecodeStream → createTextBufferFactoryFromStream → builder.finish
→ resolveFromContent → doCreateTextModel / doUpdateTextModel`。

| 源码 owner | 关键符号与事实 |
| --- | --- |
| [src/vs/workbench/contrib/files/browser/editors/fileEditorInput.ts][IO01] | `doResolveAsText` 传入 `ensureLimits(options)`；模型已存在时可以先展示旧模型并异步 reload，首次模型仍须 resolve。 |
| [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO02] | `resolve` 不覆盖 dirty/正在保存模型；依次尝试显式内容、备份、文件。 |
| [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO03] | `resolveFromFile` 传完整资源、编码、etag、limits，没有 position/length 分页；读取前记录模型版本，完成时版本变化则不覆盖新编辑。 |
| [src/vs/workbench/services/textfile/browser/textFileService.ts][IO04] | `read` 直接 join 全文；`readStream` 的返回值是“等流全收完生成的 text buffer factory”，不是仍供编辑器消费的懒流。 |
| [src/vs/editor/common/model/textModel.ts][IO05] | `createTextBufferFactoryFromStream` 每个 chunk 调 `acceptChunk`，只在 `onEnd` resolve `finish()`。 |
| [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO06] | `resolveFromContent` 得到完整 factory 后才建立/更新 TextModel。 |

底层 `IFileReadStreamOptions` **确有** position/length 能力，但普通文本打开不传它们：
[src/vs/platform/files/common/files.ts][IO07]。
因此“底层支持 range read”不能推导“编辑器按页打开”。

#### 2.2 本地 provider

Desktop renderer：

`FileService → workbench/.../electron-browser/DiskFileSystemProvider
→ DiskFileSystemProviderClient(localFilesystem channel)
→ main-process DiskFileSystemProviderChannel
→ AbstractDiskFileSystemProviderChannel
→ platform/files/node/DiskFileSystemProvider
→ readFileIntoStream → open/read/close`。

- [src/vs/workbench/services/files/electron-browser/diskFileSystemProvider.ts][IO08]：
  renderer 的 disk provider 几乎全代理给主进程，递归 watcher 另属 utility process。
- [src/vs/code/electron-main/app.ts][IO09]：
  注册主进程本地文件通道。
- [src/vs/platform/files/node/diskFileSystemProvider.ts][IO10]：
  每个读取 buffer 为 `256 * 1024` bytes（256 KiB）。
- [src/vs/platform/files/common/io.ts][IO11]：
  同一个 fd 顺序读取，支持 offset/length，循环检查 cancel 与配置 size，
  最终总会 close。块大小不是全文内存上限。
- [src/vs/platform/files/common/fileService.ts][IO12]：
  stat 与读取默认并发；有 etag 才先等验证，失败取消并等流收尾。
  普通流读没有“读后 fstat/内容hash保证整次文件版本”的检查；
  本地文件被其他进程原地改写时，不应宣称 point-in-time snapshot。

#### 2.3 provider 能力退化

[src/vs/platform/files/common/fileService.ts][IO13]：
优先 provider 的 stream，其次 primitive buffered read；
provider 不支持分块、显式 preferUnbuffered 或 atomic read 时走 unbuffered。

[src/vs/platform/files/common/fileService.ts][IO14]：
unbuffered 必须先 `await provider.readFile(resource)` 得到全部 bytes，
然后才应用 position/length。因此这条路径中的 range 参数也不能减少 provider 峰值内存。

[src/vs/platform/files/common/fileService.ts][IO15]：
`FileService.readFile` 对外返回全文 `VSBuffer`；
[src/vs/workbench/services/textfile/browser/textFileService.ts][IO16]：
`TextFileService.read` 对外返回 join 后的全文 JS string。

### 3. 解码、BOM、编码保存与保真边界

调用链：

`doGetDecodedStream → toDecodeStream → detectEncodingFromBuffer
→ EncodingOracle.getPreferredReadEncoding → DecoderStream.create/write/end`。

- UTF-8 使用 `new TextDecoder()`，每块 `decode(...,{stream:true})`，
  EOF 再 `decode()` 收尾；非 UTF-8 懒加载 `@vscode/iconv-lite-umd` decoder。
  所以能处理跨读取块的多字节字符，而不是逐块独立 decode。
  [src/vs/workbench/services/textfile/common/encoding.ts][IO17]
- 编码探测下限（不是固定实际读取块大小）默认 512 bytes，auto guess 4096 bytes；
  传给字符集猜测器最多 65536 bytes。真实 disk read chunk 是 256 KiB，
  第一块可能已超过这些下限。
  [src/vs/workbench/services/textfile/common/encoding.ts][IO18]、
  [src/vs/workbench/services/textfile/common/encoding.ts][IO19]、
  [src/vs/workbench/services/textfile/common/encoding.ts][IO20]
- 先 BOM；无 UTF-16 BOM 时只检查前 512 bytes 的零字节模式推断 UTF-16 或 binary。
  源码明确承认 false positive/negative。不是对整文件的严格有效编码证明。
  [src/vs/workbench/services/textfile/common/encoding.ts][IO21]
- 明确选择的 encoding 通常优先于检测，再到配置；特定资源 encoding override 优先级更高；
  保留 UTF-8 BOM 信息。保存 UTF-16 LE/BE 与 UTF-8 BOM 按 encoding 决定是否写 BOM。
  [src/vs/workbench/services/textfile/browser/textFileService.ts][IO22]
- **不能直接借用为 Bailey 的无损编码契约**：UTF-8 decoder 未设 `fatal:true`；
  写入时 `iconv.getEncoder(...).write(chunk)` 路线没有逐字无损 round-trip 校验。
  “记住编码再保存”不等于“原始非法字节、混合换行和不可编码字符都原样保存”。
  自动候选猜测中的 lossless 匹配仅是候选识别的局部条件，不是对整个文档保存的完整验证。
  [src/vs/workbench/services/textfile/common/encoding.ts][IO23]、
  [src/vs/workbench/services/textfile/common/encoding.ts][IO24]、
  [src/vs/workbench/services/textfile/common/encoding.ts][IO25]

### 4. 保存：snapshot、串行、分块与异常语义

#### 4.1 主调用链

`TextFileEditorModel.save / doSave
→ TaskSequentializer → doSaveSequential
→ save participants
→ createSnapshot
→ AbstractTextFileService.write / getEncodedReadable
→ toBufferOrReadable(UTF-8) 或 toEncodeReadable(iconv)
→ FileService.writeFile → validateWriteFile
→ peekBufferForWriting → doWriteBuffered / doWriteUnbuffered
→ provider.open/write/close 或 writeFile`。

- 同一 version 的保存合并；另一版保存排队，不能两个写同时执行。
  后发保存只取消正在运行的 save participants，**不取消已开始的底层写盘**。
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO26]
- 保存前运行 format/code-action 等 participant；随后重新捕获版本。
  取消检查在真正写盘之前，进入 fileService 后没有取消 token。
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO27]
- 保存成功只有当前 version 仍等于所写 version 才清 dirty；
  在途新输入保留为 dirty。保存失败保留模型并置 dirty/error/conflict。
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO28]
- 原生桌面退出会等待 pending save；web 不能等待任意长关窗工作而直接 veto。
  [src/vs/workbench/services/textfile/electron-browser/nativeTextFileService.ts][IO29]、
  [src/vs/workbench/services/textfile/browser/browserTextFileService.ts][IO30]

#### 4.2 避免额外全文字符串的方式和代价

[src/vs/workbench/common/editor/textEditorModel.ts][IO31]：
BaseTextEditorModel snapshot 保留 BOM；
[src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts][IO32]：
PieceTreeSnapshot 遍历树收集 Piece 引用，读取时从原 buffer 提取片段。
它不复制全部正文，但 metadata 为 O(piece count)，同时保留相关原 buffer。
源码明确提醒多线程环境需要 Piece 不变性，并禁止 snapshot 读取期间做 node/buffer normalization；
不要称其为可直接跨 Swift actor 使用的持久化不可变树。

[src/vs/editor/common/model/textModel.ts][IO33]：
TextModelSnapshot 合并短片段到至少 64 Ki 个 UTF-16 code units；
这不是每块严格最大值，原 Piece 可能更大。

[src/vs/workbench/services/textfile/browser/textFileService.ts][IO34]、
[src/vs/workbench/services/textfile/common/textfiles.ts][IO35]：
正常 UTF-8 通过每次 `snapshot.read()` 编码一块；
其他 encoding 由有状态 encoder 分块写，最后 flush 与处理空文件 BOM。

#### 4.3 buffered 与 unbuffered 写盘

[src/vs/platform/files/common/fileService.ts][IO36]：

- 对有整文件写能力的 provider 先窥看约 3 个 chunks，能结束就收成小 buffer。
- 不支持 open/read/write/close、输入已经是完整 buffer、或显式 atomic write，
  则走 `doWriteUnbuffered`。
- 其他情况走 `doWriteBuffered`。

[src/vs/platform/files/common/fileService.ts][IO37]：

- ResourceQueue 以目标串行写，打开 fd 后消费完整 snapshot/readable，
  每个 chunk `await provider.write`，按 bytesWritten 循环处理短写。
- stream 路径 pause → 写 → resume；EOF 还必须等待最后一个 pendingWrite。
  测试直接覆盖 pending write/错误/短写/队列释放，
  [src/vs/platform/files/test/browser/fileService.test.ts][IO38]。
- unbuffered 路线明确 `streamToBuffer / bufferedStreamToBuffer / readableToBuffer`，
  所以 **atomic 选项在这层会重新物化全文 bytes**。
- 严格零进展/未知远端结果的通用恢复协议不能从这些循环推导出来；
  这里审查的是实现，不把正常单次成功升级为全故障完整性保证。

#### 4.4 原子性与 durability

普通文本模型写入选项见 [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO39]，
没有 atomic；disk provider 与 client 没有 enforceAtomicWriteFile 实现。
因此默认 target 直接写，不能把注释中的“atomic operation without cancellation”
误读为 OS 原子文件替换。

- [src/vs/platform/files/node/diskFileSystemProvider.ts][IO40]：
  target 按 `w` 截断；Windows 尝试 `r+` + ftruncate 保留隐藏文件/alternate streams。
- [src/vs/platform/files/node/diskFileSystemProvider.ts][IO41]：
  显式 atomic opts 用同目录临时名 → write → rename；遇到 symlink 不支持该方式而回到普通写。
  这不是 Bailey“失败前目标完全不变”需求的可直接复制实现。
- [src/vs/platform/files/node/diskFileSystemProvider.ts][IO42]：
  close 前默认尝试 fdatasync；失败记录错误并全局关闭后续 flush，然后仍 close。
  没有在这条链中看见目录 fsync，也不能宣称断电持久化完美保证。
- [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO43]：
  错误分支明确承认写失败时磁盘文件可能已截断/损坏，因此保留内存 dirty。

**更适合 Bailey 参考的现有上游模式是备份写入链：**
[src/vs/workbench/services/workingCopy/common/workingCopyBackupService.ts][IO44]。
支持 atomic rename 时先流式写临时资源，再 `fileService.move(...,{atomic:true})` 发布。
这与 `writeFile(...,{atomic:...})` 强制全量 buffer 的路线不同。
是否让 Bailey 使用这类模式仍须满足其私有临时目录、元数据、路径身份、远端和并发冲突要求。

#### 4.5 symlink、hardlink、rename fallback 与发布后失败

- `canWriteFileAtomic` 只检查 symlink；实际 ordinary `open('w')` 走文件系统正常打开语义，
  不能说它拒绝符号链接或统一替换链接入口。
  显式 atomic write 遇到 symlink 会退回普通写，而不是报“无法保证原子性”。
- 本次已追 `canWriteFileAtomic → doWriteFileAtomic → rename → doRename → validateMoveCopy`，
  没有看到 `nlink` / hardlink 专门检查。**平台语义推断**：直接原地写与“新临时 inode 替换一个路径”
  对其它 hardlink 的可见结果不同；VS Code 这里没有为所有模式统一这项语义。
  Bailey 必须在自己的契约里明确，不能简单声称“像 VS Code 一样保留链接”。
- 值得区分两条 rename：旧 `doWriteFileAtomic` 调的是一般 `this.rename`，
  它调用 `Promises.rename`，在 EXDEV 或部分以点结尾路径失败时可 copy/delete fallback；
  新备份路线 `FileService.move(...,{atomic:true}) → renameFileAtomic → Promises.renameAtomic`
  明确没有 copy/delete fallback。不能仅凭 `atomic` 名字把两者视为相同保证。
  [disk provider rename][IO45]、
  [target validation][IO46]、
  [pfs rename 与 renameAtomic][IO47]。
- `FileService.writeFile` 完成 provider write 后还要 `resolve(...metadata)` 才返回成功。
  因而 **stat 失败可以发生在实际内容已经写入之后**；
  远端响应丢失也不能由这个接口推导为“磁盘未改动”。
  [write 之后的 resolve][IO48]。
  模型处理错误保留 dirty，但没有因此恢复目标旧字节或证明回滚。
- **待验证的短写缺口**：buffered 路线有完整 `bytesWritten` 循环；
  node provider 的 unbuffered `doWriteFile` 只 `await this.write(...content.byteLength)` 一次，
  没有比较返回数量。`Promises.write` 是单次 `fs.write` 包装，而非 write-all。
  这是源码可见的异常边界，未运行短写注入，不能宣称真实出现过数据丢失。
  [doWriteFile][IO49]、
  [doWrite][IO50]、
  [Promises.write][IO51]。

### 5. 外部改写、冲突与额外全文副本

#### 5.1 通用保存冲突检查较弱

[src/vs/platform/files/common/files.ts][IO52]：
etag 是 `mtime.toString(29) + size.toString(31)`，不是内容 hash。

[src/vs/platform/files/common/fileService.ts][IO53]：
触发冲突要求所有条件同时成立：

1. 调用者有 mtime、非空 etag；
2. 当前 mtime 比调用者 mtime 新；
3. 旧 etag 不等于 **旧 mtime + 当前 size** 生成的 etag。

因此同大小但不同字节的外部改写可以漏过第一道检查。
若触发了冲突检查，窥看的输入已是完整同长度 buffer，才额外完整读取磁盘比字节；
这一步不是每次保存都会发生。

不要被测试名误导：
[src/vs/platform/files/test/node/diskFileService.integrationTest.ts][IO54]
“same length but different”测试传 `etag:'anything',mtime:0`，所以一定进入内容比较；
它没有推翻旧 etag+同长度外部写可能漏检这个源码事实。

模型默认 `files.saveConflictResolution='askUser'`；
显式 ignoreModifiedSince 或 overwriteFileOnDisk 会把 etag 禁掉。
[src/vs/workbench/contrib/files/browser/files.contribution.ts][IO55]、
[src/vs/workbench/services/filesConfiguration/common/filesConfigurationService.ts][IO56]。

此外 validate 在写入队列/OS write 之前进行，不是文件系统 compare-and-swap；
同 provider 的锁与 ResourceQueue 不能锁住外部进程。

#### 5.2 reload 与 agent 合并不是相同路径

- 文件事件只 reload 干净模型；dirty 模型跳过；
  `resolve` 同时防止保存中被重读覆盖，
  完成读取再验证 version。
  [src/vs/workbench/services/textfile/common/textFileEditorModelManager.ts][IO57]、
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO58]、
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO59]
- 当前源码新增的 `retainResolvedContent/reconcileExternalChanges` 是特殊调用者按需启用：
  AgentHost edit review/session 申请 baseline；
  `getValue()` 保留全文 baseline，再完整读 disk、完整生成 current string、做两组 1000 ms diff/rebase。
  超过 model sync limit 直接 Unavailable；这不是 GB 流式三方合并。
  [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO60]、
  [src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostEditReview.ts][IO61]、
  [src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts][IO62]。

#### 5.3 Extension host 是额外全文镜像

`MainThreadDocumentsAndEditors._toModelAddData
→ proxy.$acceptDocumentsAndEditorsDelta
→ ExtHostDocumentsAndEditors.acceptDocumentsAndEditorsDelta
→ new ExtHostDocumentData → MirrorTextModel`。

- 初次发送全部 `model.getLinesContent()`，只有 `shouldSynchronizeModel` 允许才同步。
  [src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts][IO63]、
  [src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts][IO64]。
- Extension host 保存全部行字符串数组；`document.getText()` 还能 join 成额外全文缓存。
  [src/vs/workbench/api/common/extHostDocumentsAndEditors.ts][IO65]、
  [src/vs/workbench/api/common/extHostDocumentData.ts][IO66]、
  [src/vs/editor/common/model/mirrorTextModel.ts][IO67]。
- 后续只发送 edit changes/eol/version，而不是每次重发全文；
  接收端更新行数组并失效全文缓存。
  [src/vs/workbench/api/browser/mainThreadDocuments.ts][IO68]、
  [src/vs/workbench/api/common/extHostDocuments.ts][IO69]。
- 同步上限约 50 Mi **UTF-16 code units**，不是磁盘 50 MiB；模型研究负责其构造时条件。
  “大模型不发给扩展”是关闭能力以控制成本，不是分页扩展协议。

### 6. Remote SSH：可审计的数据面与不可推断的边界

#### 6.1 与本地共享 provider 契约

`RemoteFileSystemProviderClient.register
→ fileService.registerProvider(vscodeRemote)
→ connection.getChannel('remoteFilesystem')
→ DiskFileSystemProviderClient
→ AbstractDiskFileSystemProviderChannel
→ RemoteAgentFileSystemProviderChannel
→ 远端 DiskFileSystemProvider`。

- 注册使用 remote authority 和环境；Linux 判断路径大小写：
  [src/vs/workbench/services/remote/common/remoteFileSystemProviderClient.ts][IO70]。
- 远端 server 注册通道：
  [src/vs/server/node/serverServices.ts][IO71]。
- 服务端 URI transformer 将 remote authority/path 映射到正确 server 文件系统，
  同一套 DiskFileSystemProvider 运行于远端：
  [src/vs/server/node/remoteFileSystemProviderServer.ts][IO72]。
- `RemoteAgentConnection._createConnection` 调用 resolver 得到 `connectTo/connectionToken`，
  然后连接 ManagementPersistentConnection：
  [src/vs/workbench/services/remote/common/abstractRemoteAgentService.ts][IO73]。
  **本次已读 Code-OSS 源码只能证明这个公开边界。**
  Remote-SSH 扩展具体怎样安装/启动 server、认证、复用 SSH 与建立转发，
  不在此已审文件内；不凭这些接口编造其闭源实现或额外超时策略。

#### 6.2 流式读取和真实取消

- `DiskFileSystemProviderClient.readFileStream` 订阅 `channel.listen('readFileStream')`，
  收到 VSBuffer 直接 stream.write；end/error 清理监听。
  token cancel 会报 canceled/end 并释放监听。
  [src/vs/platform/files/common/diskFileSystemProviderClient.ts][IO74]
- server `onReadFileStream` 在最后一个监听释放时 cancel 它自己的 CancellationTokenSource，
  token 交给远端 disk read 循环。
  [src/vs/platform/files/node/diskFileSystemProviderServer.ts][IO75]
- 每次 open/read/write/close 都有 IPC 对应；write 的返回 Promise 会等待远端结果，
  buffered save 循环等待本块 bytesWritten 后再读下一 snapshot 块。
  [src/vs/platform/files/common/diskFileSystemProviderClient.ts][IO76]、
  [src/vs/platform/files/node/diskFileSystemProviderServer.ts][IO77]。

#### 6.3 背压不能过度承诺

**已实现：** 读 helper 可以 `await target.write`；stream 支持可选 highWaterMark。
**当前链限制：** disk/provider-client/transform/decoder 创建流都没配置 highWaterMark；
server onData 是 `emitter.fire`，client `stream.write` 没有返回给远端的消费 ACK/credit，
client.pause 也不会自动转化为远端 pause。

证据：
[src/vs/platform/files/node/diskFileSystemProvider.ts][IO78]、
[src/vs/platform/files/common/diskFileSystemProviderClient.ts][IO79]、
[src/vs/platform/files/node/diskFileSystemProviderServer.ts][IO80]、
[src/vs/base/common/stream.ts][IO81]、
[src/vs/base/common/stream.ts][IO82]、
[src/vs/base/parts/ipc/common/ipc.ts][IO83]。

**推断范围：** 慢消费者/IPC暂缓下，不能从这个文件 provider 实现得出固定的端到端内存上限。
未审全部底层 socket queue 策略，也未实测驻留峰值，因此不写“必然无界增长”或精确峰值。
Bailey 若要求缓存及所有中间队列有界，需单独以生产链实证，而不能照搬这里的命名。

#### 6.4 Git 等 extension provider 是另一条整文件路径

`FileService.readFileUnbuffered → mainThreadFileSystem.RemoteFileSystemProvider.readFile
→ ExtHostFileSystem.$readFile → extension provider.readFile`。

默认注册只有 FileReadWrite；只有完整 fsChunks proposed API 才有 open/read/write/close；
Git provider 研究另给其 `git show --textconv` 全量收集实现。

[src/vs/workbench/api/common/extHostFileSystem.ts][IO84]、
[src/vs/workbench/api/common/extHostFileSystem.ts][IO85]、
[src/vs/workbench/api/browser/mainThreadFileSystem.ts][IO86]。

不要混淆 `RemoteFileSystemProvider`（这里表示扩展进程代理）和
`RemoteFileSystemProviderClient`（vscodeRemote 远端磁盘通道）；
它们都跨进程，但能力与 GB 全量风险不同。

### 7. 实际大小阈值与旧信息纠正

| 条件 | 当前实现 | 单位与含义 |
| --- | --- | --- |
| file scheme | 1024 × 1024² | 1 GiB 磁盘 bytes；超过才要求确认，不是编辑容量保证。 |
| vscodeRemote/remote authority | 10 × 1024² | 10 MiB；避免高成本传输。 |
| web、非file/非remote | 50 × 1024² | 50 MiB；传输成本未知。 |
| desktop其他scheme | 1024 × 1024² | 1 GiB 默认确认门槛。 |
| 用户显式配置 | `workbench.editorLargeFileConfirmation * 1024²` | 配置标题称 MB，源码实际 MiB；minimum=1。 |
| Open Anyway | `limits.size=Number.MAX_VALUE` | 跳过确认门槛，实际仍受模型/运行时/内存限制。 |
| 磁盘读取块 | 256 KiB | IO chunk，不是页缓存/文档容量。 |
| 编码探测 | 512 bytes/4096 bytes，guess最多65536 bytes | 初步采样探测范围，不是全文件严格校验。 |

证据：
[src/vs/platform/files/common/files.ts][IO87]、
[src/vs/workbench/common/editor/resourceEditorInput.ts][IO88]、
[src/vs/workbench/browser/parts/editor/editorConfiguration.ts][IO89]、
[src/vs/workbench/common/editor.ts][IO90]、
[src/vs/platform/files/common/fileService.ts][IO91]。

关于旧 `files.maxMemoryForLargeFilesMB`/32bit-64bit heap threshold：
当前 `IFileReadLimits` 只有可选 size（[src/vs/platform/files/common/files.ts][IO92]），
NativeTextFileService.ensureLimits 只保证 limits 对象存在、不填写任何阈值
（[src/vs/workbench/services/textfile/electron-browser/nativeTextFileService.ts][IO93]）。
实际调用者由上表的 ResourceEditorInput 提供大小门槛；
配置 schema / CLI argv / Native service 均无旧配置和旧 memory 分支。
package.json 的 `--max-old-space-size=8192` 是 gulp/tsec 等开发命令，
不能作为已发布 editor 的大文件内存设置：
[package.json][IO94]。
这一结论仅限本次固定修订，不推断所有旧版都如此，也不声称运行时没有 heap/string 上限。

### 源码路径与关键符号索引

以下集中列出核心实现 owner；每个路径可直接打开固定 SHA 的对应行段。
注册点、调用者和测试证据另在各节给出完整可见路径与链接；文末 IO 引用定义不代替此索引。

| 责任 | 完整源码路径 | 关键符号／入口 |
| --- | --- | --- |
| 编辑器打开入口 | [src/vs/workbench/contrib/files/browser/editors/fileEditorInput.ts][IO01] | `FileEditorInput.resolve`、`doResolveAsText` |
| 文本文件生命周期 | [src/vs/workbench/services/textfile/common/textFileEditorModel.ts][IO03] | `TextFileEditorModel.resolveFromFile`、`resolveFromContent`、`doSave`、`retainResolvedContent`、`reconcileExternalChanges` |
| 解码与快照编码 | [src/vs/workbench/services/textfile/browser/textFileService.ts][IO04] | `AbstractTextFileService.read`、`readStream`、`write`、`EncodingOracle` |
| 完整模型构建与快照块 | [src/vs/editor/common/model/textModel.ts][IO05] | `createTextBufferFactoryFromStream`、`TextModelSnapshot.read` |
| Piece 快照寿命 | [src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts][IO32] | `PieceTreeSnapshot` |
| 工作副本快照入口 | [src/vs/workbench/common/editor/textEditorModel.ts][IO31] | `createSnapshot` |
| UTF-8 snapshot 适配 | [src/vs/workbench/services/textfile/common/textfiles.ts][IO35] | `toBufferOrReadable` |
| 字符解码与编码 | [src/vs/workbench/services/textfile/common/encoding.ts][IO17] | `DecoderStream`、`toDecodeStream`、`toEncodeReadable`、`detectEncodingFromBuffer`、`guessEncodingByCandidates` |
| 文件服务读写选择与排队 | [src/vs/platform/files/common/fileService.ts][IO36] | `FileService.readFile`、`readFileStream`、`writeFile`、`validateWriteFile`、`doWriteBuffered`、`doWriteBuffer` |
| 读取契约、etag 与门槛 | [src/vs/platform/files/common/files.ts][IO87] | `IFileReadLimits`、`IFileReadStreamOptions`、`etag`、`ByteSize`、`getLargeFileConfirmationLimit` |
| Desktop renderer 代理 | [src/vs/workbench/services/files/electron-browser/diskFileSystemProvider.ts][IO08] | `DiskFileSystemProvider` |
| Disk IPC 客户端 | [src/vs/platform/files/common/diskFileSystemProviderClient.ts][IO74] | `DiskFileSystemProviderClient.readFileStream`、`writeFile`、`write` |
| Disk IPC 服务端 | [src/vs/platform/files/node/diskFileSystemProviderServer.ts][IO75] | `AbstractDiskFileSystemProviderChannel`；流事件订阅、取消与 fd 请求转发 |
| 本机／远端磁盘实现 | [src/vs/platform/files/node/diskFileSystemProvider.ts][IO40] | `DiskFileSystemProvider.readFileStream`、`open`、`close`、`doWriteFile`、`doWriteFileAtomic`、`canWriteFileAtomic`、`rename` |
| 顺序 fd 读取循环 | [src/vs/platform/files/common/io.ts][IO11] | `readFileIntoStream` |
| rename 与 fs.write 包装 | [src/vs/base/node/pfs.ts][IO47] | `Promises.rename`、`Promises.renameAtomic`、`write` |
| 工作副本备份发布 | [src/vs/workbench/services/workingCopy/common/workingCopyBackupService.ts][IO44] | `backup`；独立临时文件与 atomic move 路线 |
| 原生退出／默认读取限制 | [src/vs/workbench/services/textfile/electron-browser/nativeTextFileService.ts][IO93] | `NativeTextFileService`、`ensureLimits` |
| 浏览器关闭保护 | [src/vs/workbench/services/textfile/browser/browserTextFileService.ts][IO30] | `BrowserTextFileService`；pending save veto |
| 外部变化与 dirty reload | [src/vs/workbench/services/textfile/common/textFileEditorModelManager.ts][IO57] | `TextFileEditorModelManager`；文件变动后的 dirty 判定 |
| 保存冲突策略配置 | [src/vs/workbench/services/filesConfiguration/common/filesConfigurationService.ts][IO56] | `preventSaveConflicts` |
| remote scheme 注册 | [src/vs/workbench/services/remote/common/remoteFileSystemProviderClient.ts][IO70] | `RemoteFileSystemProviderClient`；`remoteFilesystem` channel |
| 远端磁盘通道 | [src/vs/server/node/remoteFileSystemProviderServer.ts][IO72] | `RemoteAgentFileSystemProviderChannel`；Node disk provider 与 URI transformer |
| 远端管理连接 | [src/vs/workbench/services/remote/common/abstractRemoteAgentService.ts][IO73] | `RemoteAgentConnection`；`connectRemoteAgentManagement` 调用链 |
| stream 排队／可选背压 | [src/vs/base/common/stream.ts][IO81] | `WriteableStreamImpl`、`newWriteableStream`、`transform`、`highWaterMark` |
| IPC 推送路径 | [src/vs/base/parts/ipc/common/ipc.ts][IO83] | `ChannelServer`；事件响应发送 |
| 首次 extension host 镜像 | [src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts][IO64] | `_updateStateOnModelAdd`、`_toModelAddData`、`model.getLinesContent` |
| 镜像文档创建 | [src/vs/workbench/api/common/extHostDocumentsAndEditors.ts][IO65] | `$acceptDocumentsAndEditorsDelta` |
| extension API 文档 | [src/vs/workbench/api/common/extHostDocumentData.ts][IO66] | `ExtHostDocumentData` |
| 全行镜像与全文拼接 | [src/vs/editor/common/model/mirrorTextModel.ts][IO67] | `MirrorTextModel.getText`、`onEvents` |
| extension 文件 provider | [src/vs/workbench/api/common/extHostFileSystem.ts][IO84] | `registerFileSystemProvider`、`$readFile`；`fsChunks` capability |
| extension 文件服务桥接 | [src/vs/workbench/api/browser/mainThreadFileSystem.ts][IO86] | `RemoteFileSystemProvider.readFile` |
| 确认门槛注入 | [src/vs/workbench/common/editor/resourceEditorInput.ts][IO88] | `ensureLimits` |
| Open Anyway | [src/vs/workbench/common/editor.ts][IO90] | `createTooLargeFileError`；`Number.MAX_VALUE` size override |

### 源码永久链接

[IO01]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/files/browser/editors/fileEditorInput.ts#L338-L397
[IO02]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L295-L338
[IO03]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L527-L565
[IO04]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/browser/textFileService.ts#L181-L250
[IO05]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L72-L108
[IO06]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L596-L665
[IO07]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/files.ts#L349-L376
[IO08]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/files/electron-browser/diskFileSystemProvider.ts#L22-L109
[IO09]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/code/electron-main/app.ts#L1416-L1421
[IO10]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L255-L263
[IO11]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/io.ts#L57-L124
[IO12]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L588-L663
[IO13]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L623-L640
[IO14]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L702-L730
[IO15]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L565-L579
[IO16]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/browser/textFileService.ts#L181-L196
[IO17]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L70-L116
[IO18]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L25-L30
[IO19]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L119-L213
[IO20]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L320-L331
[IO21]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L477-L542
[IO22]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/browser/textFileService.ts#L819-L885
[IO23]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L82-L101
[IO24]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L217-L263
[IO25]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/encoding.ts#L360-L390
[IO26]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L864-L935
[IO27]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L940-L1039
[IO28]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L1049-L1097
[IO29]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/electron-browser/nativeTextFileService.ts#L61-L76
[IO30]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/browser/browserTextFileService.ts#L54-L65
[IO31]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/common/editor/textEditorModel.ts#L234-L241
[IO32]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts#L153-L198
[IO33]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L129-L168
[IO34]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/browser/textFileService.ts#L266-L297
[IO35]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textfiles.ts#L622-L644
[IO36]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L383-L454
[IO37]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L1302-L1435
[IO38]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/test/browser/fileService.test.ts#L692-L938
[IO39]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L1028-L1039
[IO40]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L397-L467
[IO41]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L266-L326
[IO42]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L518-L546
[IO43]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L1079-L1083
[IO44]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/workingCopy/common/workingCopyBackupService.ts#L271-L329
[IO45]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L714-L761
[IO46]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L792-L856
[IO47]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/base/node/pfs.ts#L492-L568
[IO48]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L413-L434
[IO49]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L329-L358
[IO50]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L635-L655
[IO51]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/base/node/pfs.ts#L820-L836
[IO52]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/files.ts#L1587-L1600
[IO53]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L486-L536
[IO54]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/test/node/diskFileService.integrationTest.ts#L2429-L2492
[IO55]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/files/browser/files.contribution.ts#L361-L373
[IO56]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/filesConfiguration/common/filesConfigurationService.ts#L548-L550
[IO57]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModelManager.ts#L134-L145
[IO58]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L306-L313
[IO59]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L541-L565
[IO60]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/common/textFileEditorModel.ts#L341-L423
[IO61]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostEditReview.ts#L280-L290
[IO62]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/chat/browser/agentSessions/agentHost/agentHostSessionHandler.ts#L1558-L1566
[IO63]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts#L165-L169
[IO64]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadDocumentsAndEditors.ts#L377-L386
[IO65]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostDocumentsAndEditors.ts#L79-L103
[IO66]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostDocumentData.ts#L35-L79
[IO67]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/mirrorTextModel.ts#L58-L105
[IO68]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadDocuments.ts#L86-L118
[IO69]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostDocuments.ts#L180-L187
[IO70]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/remote/common/remoteFileSystemProviderClient.ts#L16-L55
[IO71]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/server/node/serverServices.ts#L388-L389
[IO72]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/server/node/remoteFileSystemProviderServer.ts#L20-L52
[IO73]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/remote/common/abstractRemoteAgentService.ts#L216-L264
[IO74]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/diskFileSystemProviderClient.ts#L103-L159
[IO75]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProviderServer.ts#L108-L136
[IO76]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/diskFileSystemProviderClient.ts#L162-L187
[IO77]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProviderServer.ts#L139-L164
[IO78]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProvider.ts#L255-L261
[IO79]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/diskFileSystemProviderClient.ts#L103-L113
[IO80]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/node/diskFileSystemProviderServer.ts#L112-L134
[IO81]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/base/common/stream.ts#L193-L274
[IO82]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/base/common/stream.ts#L712-L721
[IO83]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/base/parts/ipc/common/ipc.ts#L354-L387
[IO84]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostFileSystem.ts#L132-L180
[IO85]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostFileSystem.ts#L264-L269
[IO86]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadFileSystem.ts#L184-L239
[IO87]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/files.ts#L1621-L1680
[IO88]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/common/editor/resourceEditorInput.ts#L190-L210
[IO89]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/browser/parts/editor/editorConfiguration.ts#L203-L215
[IO90]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/common/editor.ts#L1073-L1095
[IO91]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L740-L762
[IO92]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/files.ts#L349-L356
[IO93]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/services/textfile/electron-browser/nativeTextFileService.ts#L79-L114
[IO94]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/package.json#L65-L83

<a id="git-diff"></a>
## 三、Git Diff 的读取、计算与精度

### 1. Git 内容来源与比较入口

真实主链：

`Resource.openChange()`
→ `CommandResolver.resolveChangeCommand()`
→ `vscode.diff(leftUri, rightUri, title)`
→ Workbench `DiffEditorInput.resolve()/createModel()`
→ 并行 `original.resolve()`、`modified.resolve()`
→ `TextDiffEditorModel`
→ `TextDiffEditor.setInput()`
→ `DiffEditorWidget.createViewModel()`
→ `DiffEditorViewModel`
→ worker 文本 Diff。[G05] [G06] [G29]

Git 扩展把 HEAD／Index／历史内容表示为只读的 `git:` URI；
工作区修改侧通常仍是实际文件资源。
`~` 在 provider 内根据 index 状态选择空 ref（index）或 HEAD，
`~1/~2/~3` 映射冲突阶段。
暂存变更通常是 HEAD 对 index；普通修改是 index／HEAD 对工作区。
Submodule 是例外：provider 返回 `diffIndexWithHEAD`／`diffWithHEAD` 生成的文字，
不能用该例外概括普通文件的渲染主链。[G05] [G07] [G43]

普通 Git 虚拟文本读取链：

`GitFileSystemProvider.readFile()`
→ `Repository.buffer()`
→ 底层 `Repository.buffer(ref, path)`
→ `stream(['show', '--textconv', ref + ':' + relativePath])`
→ `exec(child)`
→ 收集所有 stdout `Buffer[]`
→ `Buffer.concat(buffers)`
→ 返回完整 `Uint8Array`。[G07] [G08] [G28]

这不是 Git blob 的分页接口。`stream` 是进程管道名称；
消费者仍一次保留全部输出并拼接完整 buffer。
这里没有 `maxBuffer` 参数或分段驱逐预算，内存风险转移到 extension host。
`getObjectDetails()` 通过 `ls-files/ls-tree/cat-file -s` 获取原始对象元数据，
正文却由单独的 `git show --textconv` 读取；不能声称 metadata 与转换后正文天然是同一字节快照。[G08]

extension host 桥接也保持全量语义：
`ExtHostFileSystem.$readFile()` 等待 provider 完整 `readFile`，包装 `VSBuffer`；
`RemoteFileSystemProvider.readFile()` 等待 RPC 返回完整 buffer。
Git provider 未实现 open/read/close 分块能力。
FileService 的无流 provider 分支是 `readFileUnbuffered()`，先收全量再包装成 stream，
并不把 Git 虚拟文件改造成按需文件。[G09] [G37] [G38] [G39] [G42]

**边界：**
Git 状态、暂存、补丁应用仍可能使用命令行 `git diff` 等；
普通两侧文本编辑器的行／字符显示则由 Monaco 算法计算。
不能把前者当成后者，也不能把 Monaco 的“文本相等”当成 Git raw blob／clean filter 相等。
`--textconv` 本身就说明展示文本可能不是原始 blob 字节。[G05] [G07] [G08] [G28]

### 2. 两侧模型、worker 副本与容量门槛

`DiffEditorInput.createModel()` 等待两侧完成 resolve。
`TextDiffEditor.setInput()` 还先等待新 view model 的 `waitForDiff()`，
然后才 `control.setModel(vm)`。
因此标准比较入口不是“先显示第一页，再逐页建立 Diff”。[G06] [G29]

计算链：

`DiffEditorViewModel`
→ `WorkerBasedDocumentDiffProvider.computeDiff()`
→ `EditorWorkerService.computeDiff()`
→ `_workerWithResources([original, modified], true)`
→ `WorkerTextModelSyncClient.ensureSyncedResources()`
→ `_beginModelSync()`
→ `$acceptNewModel({ lines: model.getLinesContent(), EOL, versionId })`
→ worker 的 `MirrorModel`
→ `EditorWorker.$computeDiff()`。[G02] [G03] [G10] [G11]

副本结构与更新：

- 主编辑器是 Piece Tree；worker mirror 是完整 `string[]` 行数组。
- 首次同步必须读取全部行；正常 Web Worker 传输跨线程序列化，不是共享 Piece Tree。
- 后续输入以 range、rangeLength、text、versionId 等增量事件更新 mirror，
  不能把“增量同步”误写为“初始按需加载”。
- mirror 自己维护行数组，必要时建立 `Uint32Array` 行长度前缀和；
  `getText()` 还会 `join(EOL)` 并缓存全文。
- worker model 超过 60 秒未使用会停止同步；worker 本身 5 分钟闲置释放。
  这是生命周期回收，不是固定容量的页缓存。[G03] [G12] [G13] [G40] [G41]

实际阈值：

| 项目 | 代码条件 | Diff 行为 |
| --- | --- | --- |
| 普通 worker 同步 | 构造时 `bufferTextLength > 50 * 1024 * 1024` | Diff 显式 `forceLargeModels=true`，绕过此项 |
| heap operation | 构造时、且 `largeFileOptimizations=true`，`bufferTextLength > 256 * 1024 * 1024` | `getLinesContent` 抛 `BugIndicatingError`，forceLargeModels 不绕过 |
| Diff 文件大小设置 | 默认值 `maxFileSize: 50`，schema 文案“MB” | 当前标准 Diff 生产链未发现执行该值的 gate |
| 计算时间 | 默认 `5000` ms；`0` 表示无超时 | 作用于计算中的协作式时间检查，非加载/复制/分配硬截止 |
| 运行结果验证 | 每侧行数 `<= 50_000` 且随机抽样命中 | 抽样率默认 0；不能声称每次 Diff 均做重建校验 |

这些字符数阈值计 UTF-16 code units，不是磁盘 bytes。
阈值判定锁定在模型构造时；把文档随后编辑变大不是动态重新设定所有优化标志。
关闭 `largeFileOptimizations` 可取消 heap-operation guard，
但不会产生分页能力，也不会消除 worker／算法副本。[G01] [G04] [G10] [G14] [G26] [G27]

**负证据范围：**
对本 SHA 的 `src` 和 `extensions/git` 生产源码检索 `maxFileSize`，
Diff 相关命中只有默认值、schema、公开类型及 `validateOptions` 的归一化；
继续沿上述 provider→worker→算法链，没有读这个值的实际条件判断。
这是此 SHA 的标准实现结论，不泛化到第三方自定义 Diff provider 或别的 VS Code 版本。[G04] [G14] [G34]

**GB 推断的限定：**
对于新建、非空的普通双侧模型，若解码后长度超过 256 Mi UTF-16 units 且默认优化开启，
首次 worker 同步会在 `getLinesContent()` 抛异常。
原侧为空的快速路径不经过相同计算链，因此不能写“任何 GB Diff 一定走同一异常”。
没有运行该版本，不断言界面一定弹窗、卡住或崩溃；
源码只证明此链无法正常计算。
`DiffEditorViewModel` 的非取消异常继续 reject，
而 Workbench 等的是 `waitForDiff()` 状态，不能把此异常直接等同于 `FILE_TOO_LARGE` 提示路径。[G01] [G03] [G06] [G10] [G11] [G26] [G27] [G33]

### 3. 默认 advanced 算法实际做什么

默认 `diffAlgorithm='advanced'` 解析为 `DefaultLinesDiffComputer`，
不是 git histogram／patience，也不是默认 WASM。[G04] [G15]

`DefaultLinesDiffComputer._computeDiff()` 的步骤：

1. 处理全空等快速路径。
2. 为两侧所有 `line.trim()` 建立共用 `Map<string, number>`，
   得到完整行 ID 数组。
   这里“perfect hashes”是字符串驻留表的精确 ID，不是可能碰撞的短哈希摘要。
3. 两侧行数之和 `< 1700` 用带评分的动态规划；否则用 Myers。
4. 优化对齐、合并较短匹配；必要时补充首尾空白差异。
5. 对变化行块建立 `LinesSliceCharSequence`，逐 UTF-16 code unit 放进 `number[]`。
6. 两侧字符序列长度之和 `< 500` 用动态规划，否则 Myers；
   再按单词／子词边界调整，移除视觉上碎小的匹配。
7. 输出 `DetailedLineRangeMapping` 及 `innerChanges`；
   可选计算移动块，默认 `showMoves=false`。[G16] [G17] [G30]

复杂度和内存：

- 动态规划创建三张 `Array2D`，源码标明 O(MN)。
- Myers 源码标明 O(ND)，最坏空间二次增长；
  它维护 `Int32Array` 前沿和 `SnakePath` 链，不是磁盘外存算法。
- 全量行数组、trimmed 文本表和数字 ID 随全文／行数增长。
- 极长单行虽然只有很少“行”，字符细化仍可构造巨大的 `number[]`。
- 全文或超大块发生改变时，所谓“只细化变更块”仍可能等价于处理大部分全文。
- 上述内存结构没有一个由默认 5000 ms 自动提供严格字节上限。[G16] [G17] [G18] [G31]

因此可借鉴“先行后字符、按规模选算法、把可读性与严格重建分开”，
不能直接把这个实现作为 Bailey 的 GB 有界内存 Diff 后端。

### 4. 精度、超时、取消与降级

#### 超时

`DateTimeout` 用 `Date.now()` 检查 elapsed，超时后保持 false。
Myers 主要在每轮 d 开始检查，动态规划在循环中检查。
行哈希建立、字符序列物化、一些后处理并没有逐步检查同一截止时间；
配置的 5000 ms 不包含之前的文件读取、模型创建和 worker 同步开销。[G16] [G18] [G19] [G32]

算法超时可以返回 `trivialTimedOut(seq1, seq2)`：
用整个当前序列的替换块覆盖，再标记 `hitTimeout=true`。
worker 把它变成 `quitEarly`。
Workbench `DiffEditorHelperContribution` 显示提前终止警告，并提供
“Remove Limit”把 `diffEditor.maxComputationTime` 设为 0。
这是一种诚实的粗粒度结果，绝非“仍然精确定位了每一处少量改动”。[G18] [G19] [G20]

#### 取消与输入并发

`WorkerBasedDocumentDiffProvider.computeDiff()` 接收取消 token，
但 worker 的 `$computeDiff` 调用没有把 token 传到同步算法；
provider 在 await 结束后才检查取消。
所以不能宣称切走或取消必定立即停止旧 CPU 计算。[G10] [G11]

`DiffEditorViewModel` 以 200 ms debounce 合并重算请求。
内容监听器和在途计算虽然收集编辑并调用 `applyOriginalEdits/applyModifiedEdits`，
两个函数在当前源码中都直接 `return undefined`，后面的实现处于 TODO 注释内。
因此不能把调用点当成已实现的增量映射修复：编辑只将当前结果标为过期并安排重算，
在途结果使用 `apply…(...) ?? result`，无法由这些空函数重基到新版本。
本段存在取消／模型释放检查，但没有为每次计算核对原始／修改侧版本的最终发布检查；
不能据此承诺旧结果总会被丢弃或已被正确重映射。
实现位置见 [diffEditorViewModel.ts:651–719](https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts#L651-L719)。
worker 在等待可选后端加载之后才获取两边行内容，
使该次 worker 内的 diff 和 identity 检查读取同一模型状态；这不等于主线程后续没有新编辑。
以上均是完整模型的异步结果管理，不是 GB 索引分页。[G11] [G21] [G33]

#### identical 的准确含义

默认 `ignoreTrimWhitespace=true`。
当 changes 非空，`identical=false`；
当 changes 为空，worker 还逐行做严格字符串比较，避免把仅空白差异直接报告为 identical。
Workbench 可以提示“Show Whitespace Differences”。[G04] [G11] [G20]

但这个检查只比行内容，没有比较原始编码、BOM 或原始换行字节；
模型已解码，算法输入由行分离出来。
因此 `identical` 不能作为 Bailey 保存字节一致性、Git clean 结果或二进制原文一致性的证据。

#### 正确性验证与可选外部算法

本 SHA 除 legacy/advanced 外，还支持 `advanced-external` 和 `advanced-wasm`，
依赖锁定为 `@vscode/diff 0.0.2-128`，默认仍 advanced。
适配器首先对两侧 `lines.join('\n')`，构造完整字符串，再调用包。
WASM 名称没有消除完整文本物化。[G14] [G15] [G22] [G35] [G36]

`resolveLinesDiffComputerWithFallback()` 对外部包加载／计算异常回退内置 advanced；
抽样验证发现外部结果 invalid 时也回退。
内置算法不经过相同自动换后端处理。[G23]

验证 `verifyLinesDiff()` 用 inner changes 重建 modified，
严格模式比较结果字符串；忽略空白时逐行 trim 比较。
缺少 inner changes 返回 `unverified`。
由于线性重建也会物化全文，
`WorkerBasedDocumentDiffProvider._shouldVerify()` 仅允许两侧各不超过 50,000 行且概率抽样命中；
schema 默认抽样率为 0，可被实验配置更改。
因此“VS Code 每次都会严格回放验证 Diff”是错误描述。[G10] [G14] [G24]

本文只证明此仓库内的外部包适配与回退，
未审阅 `@vscode/diff` 对应包版本的内部 JS／WASM 实现，
不把内置 Myers 的复杂度强加到这些可选后端。

#### 其它边界

- 原文件过大而 resolve 失败时，Workbench 的 `FILE_TOO_LARGE` 分支给出大文件提示；二进制走 binary diff fallback。[G06]
- 普通 gutter Quick Diff 使用独立选项：默认 advanced、1000 ms。
  不应拿这一数值冒充完整 Diff Editor 的 5000 ms。[G25]
- Web Worker 创建或 ping 失败会回退到 `SynchronousWorkerClient(new EditorWorker)`，
  所以“Diff 永远不在主线程计算”也不成立。[G13]
- 隐藏未修改区基于已计算的行映射；它减少显示内容，不减少两侧正文或计算输入。[G44]

### 永久源码索引

| ID | 源码路径与永久链接 | 关键符号／作用 |
| --- | --- | --- |
| G01 | [src/vs/editor/common/model/textModel.ts][G01] | TextModel 常量：50 Mi 同步／256 Mi heap 阈值 |
| G02 | [src/vs/editor/browser/services/editorWorkerService.ts][G02] | EditorWorkerService.computeDiff；forceLargeModels |
| G03 | [src/vs/editor/common/services/textModelSync/textModelSync.impl.ts][G03] | WorkerTextModelSyncClient._beginModelSync；全行首次同步 |
| G04 | [src/vs/editor/common/config/diffEditor.ts][G04] | diffEditorDefaultOptions；5000 ms／50 声明／默认 advanced |
| G05 | [extensions/git/src/repository.ts][G05] | CommandResolver；vscode.diff 与两侧资源选择 |
| G06 | [src/vs/workbench/browser/parts/editor/textDiffEditor.ts][G06] | setInput；waitForDiff；binary／FILE_TOO_LARGE |
| G07 | [extensions/git/src/fileSystemProvider.ts][G07] | GitFileSystemProvider.readFile；只读 Git 来源 |
| G08 | [extensions/git/src/git.ts][G08] | Repository.buffer／getObjectDetails；git show --textconv |
| G09 | [src/vs/workbench/api/common/extHostFileSystem.ts][G09] | ExtHostFileSystem.$readFile；完整 VSBuffer RPC |
| G10 | [src/vs/editor/browser/widget/diffEditor/diffProviderFactoryService.ts][G10] | WorkerBasedDocumentDiffProvider；取消、缓存、抽样验证 |
| G11 | [src/vs/editor/common/services/editorWebWorker.ts][G11] | EditorWorker.$computeDiff；identical；quitEarly |
| G12 | [src/vs/editor/common/model/mirrorTextModel.ts][G12] | MirrorTextModel；全行数组／全文缓存／前缀索引 |
| G13 | [src/vs/editor/browser/services/editorWorkerService.ts][G13] | WorkerManager 生命周期；SynchronousWorkerClient 回退 |
| G14 | [src/vs/editor/common/config/editorConfigurationSchema.ts][G14] | Diff 配置声明、外部算法与验证抽样默认值 |
| G15 | [src/vs/editor/common/diff/linesDiffComputers.ts][G15] | 算法名称到内置／外部实现的路由 |
| G16 | [src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts][G16] | 行驻留 ID、1700 行阈值、行／字符映射 |
| G17 | [src/vs/editor/common/diff/defaultLinesDiffComputer/linesSliceCharSequence.ts][G17] | LinesSliceCharSequence；逐 UTF-16 unit 数字数组 |
| G18 | [src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/myersDiffAlgorithm.ts][G18] | MyersDiffAlgorithm；O(ND)／最坏二次空间／超时 |
| G19 | [src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts][G19] | trivialTimedOut；粗粒度整段替换 |
| G20 | [src/vs/workbench/contrib/codeEditor/browser/diffEditorHelper.ts][G20] | 空白提示、提前终止警告与 Remove Limit |
| G21 | [src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts][G21] | DiffEditorViewModel；200 ms debounce |
| G22 | [src/vs/editor/common/diff/externalLinesDiffComputer.ts][G22] | 外部 JS／WASM 适配器；先 join 两侧全文 |
| G23 | [src/vs/editor/common/diff/linesDiffWithFallback.ts][G23] | 外部失败／无效结果回退内置算法 |
| G24 | [src/vs/editor/common/diff/verifyLinesDiff.ts][G24] | verifyLinesDiff；回放重建与 trim 语义 |
| G25 | [src/vs/workbench/contrib/scm/browser/quickDiffModel.ts][G25] | gutter Quick Diff 默认 1000 ms |
| G26 | [src/vs/editor/common/model/textModel.ts][G26] | 构造时锁定 heap／sync 标志 |
| G27 | [src/vs/editor/common/model/textModel.ts][G27] | getLinesContent；超 heap 阈值抛异常 |
| G28 | [extensions/git/src/git.ts][G28] | exec(child)；完整 stdout Buffer[]／Buffer.concat |
| G29 | [src/vs/workbench/common/editor/diffEditorInput.ts][G29] | DiffEditorInput.createModel；并行 resolve 两侧 |
| G30 | [src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts][G30] | refineDiff；500 code units 阈值与词边界优化 |
| G31 | [src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/dynamicProgrammingDiffing.ts][G31] | DynamicProgrammingDiffing；三张 O(MN) 矩阵 |
| G32 | [src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts][G32] | DateTimeout；协作式时间检查 |
| G33 | [src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts][G33] | 计算期间记录编辑、未实现重基的调用与结果发布 |
| G34 | [src/vs/editor/browser/widget/diffEditor/diffEditorOptions.ts][G34] | validateOptions；maxFileSize 归一化 |
| G35 | [package.json][G35] | @vscode/diff 依赖版本 |
| G36 | [pnpm-lock.yaml][G36] | @vscode/diff 锁定版本 |
| G37 | [src/vs/workbench/api/browser/mainThreadFileSystem.ts][G37] | RemoteFileSystemProvider.readFile；完整 RPC buffer |
| G38 | [src/vs/platform/files/common/fileService.ts][G38] | doReadFileStream；无分块能力时选 unbuffered |
| G39 | [src/vs/platform/files/common/fileService.ts][G39] | readFileUnbuffered；完整读取后再 slice／包装流 |
| G40 | [src/vs/editor/common/services/textModelSync/textModelSync.impl.ts][G40] | 60 秒闲置阈值与定时停止同步 |
| G41 | [src/vs/editor/browser/services/editorWorkerService.ts][G41] | worker 的 5 分钟闲置阈值 |
| G42 | [src/vs/workbench/api/common/extHostFileSystem.ts][G42] | fsChunks 必须具备完整 open／close／read／write |
| G43 | [extensions/git/src/fileSystemProvider.ts][G43] | sanitizeRef；HEAD／index／冲突阶段选择 |
| G44 | [src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts][G44] | UnchangedRegion.fromDiffs；折叠消费已有映射 |

[G01]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L186-L191
[G02]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/services/editorWorkerService.ts#L110-L144
[G03]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/textModelSync/textModelSync.impl.ts#L91-L125
[G04]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/config/diffEditor.ts#L8-L39
[G05]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/extensions/git/src/repository.ts#L532-L640
[G06]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/browser/parts/editor/textDiffEditor.ts#L100-L191
[G07]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/extensions/git/src/fileSystemProvider.ts#L197-L244
[G08]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/extensions/git/src/git.ts#L1622-L1675
[G09]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostFileSystem.ts#L264-L266
[G10]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffProviderFactoryService.ts#L45-L189
[G11]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/editorWebWorker.ts#L126-L191
[G12]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/mirrorTextModel.ts#L58-L121
[G13]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/services/editorWorkerService.ts#L347-L521
[G14]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/config/editorConfigurationSchema.ts#L196-L287
[G15]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/linesDiffComputers.ts#L6-L16
[G16]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts#L38-L200
[G17]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/linesSliceCharSequence.ts#L14-L48
[G18]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/myersDiffAlgorithm.ts#L10-L103
[G19]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts#L17-L33
[G20]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/codeEditor/browser/diffEditorHelper.ts#L34-L75
[G21]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts#L86-L97
[G22]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/externalLinesDiffComputer.ts#L47-L101
[G23]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/linesDiffWithFallback.ts#L21-L71
[G24]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/verifyLinesDiff.ts#L11-L35
[G25]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/contrib/scm/browser/quickDiffModel.ts#L36-L44

[G26]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L328-L368
[G27]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/model/textModel.ts#L869-L875
[G28]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/extensions/git/src/git.ts#L218-L280
[G29]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/common/editor/diffEditorInput.ts#L202-L218
[G30]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts#L231-L281
[G31]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/dynamicProgrammingDiffing.ts#L10-L68
[G32]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/diff/defaultLinesDiffComputer/algorithms/diffAlgorithm.ts#L184-L208
[G33]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts#L211-L326
[G34]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffEditorOptions.ts#L208-L216
[G35]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/package.json#L129
[G36]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/pnpm-lock.yaml#L79-L81

[G37]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/browser/mainThreadFileSystem.ts#L237-L240
[G38]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L622-L629
[G39]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/platform/files/common/fileService.ts#L702-L730
[G40]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/common/services/textModelSync/textModelSync.impl.ts#L20-L89
[G41]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/services/editorWorkerService.ts#L42-L45
[G42]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/workbench/api/common/extHostFileSystem.ts#L132-L166
[G43]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/extensions/git/src/fileSystemProvider.ts#L21-L35
[G44]: https://github.com/microsoft/vscode/blob/530b702bc1ecca912e842e906fa67ecfc60c091e/src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts#L156-L163

补充精确锚点：

- heap guard：[构造时判定][G26]；[getLinesContent 抛异常][G27]。
- [Git stdout 全量收集][G28]；[两侧 resolve][G29]。
- [Diff 失效重算／结果发布][G33]；[字符算法阈值][G30]。
- [O(MN) 三张矩阵][G31]；[DateTimeout 非硬截止][G32]。
- 外部包固定版本：[package.json][G35]；[pnpm-lock.yaml][G36]。
- [maxFileSize 仅归一化][G34]。


<a id="bailey-current"></a>
## 四、Bailey 当前架构：保留什么、真正还卡在哪里

Bailey 继续使用 SwiftUI 组织界面、原生 `NSTextView`／TextKit 2 承载正文。
当前目标是迁移正文和 IO 的数据流，不是换成 Monaco、WebKit 或第二个可写编辑器。
下表是当前源码事实，不是本轮已经完成的改造。
行号以本轮开始的 Bailey 提交为准。

| 源码路径与行号 | 关键符号／调用链 | 当前成本与必须保留的行为 |
| --- | --- | --- |
| [Bailey/Editor/FileViewerView.swift](../../../Bailey/Editor/FileViewerView.swift)，L573–615 | `FileTab.readContent → backend.read → TextFileEncoding.decode → loadedContent` | 普通文本仍受 8 MiB 门槛；先完整 Data 再 String。图片候选以较宽读取路径尝试，回退文本也须治理 |
| [Bailey/Workspace/LocalWorkspaceBackend.swift](../../../Bailey/Workspace/LocalWorkspaceBackend.swift)，L86–112 | `readSync` | 64 KiB 循环最终追加到完整 Data；使用同一 FD 不提供不可变版本 |
| [Bailey/Remote/SSHWorkspaceBackend.swift](../../../Bailey/Remote/SSHWorkspaceBackend.swift)，L148–159 | `read / write` | head／cat 结果和保存 stdin 均为完整 Data；后续应扩展现有进程泵，不增加第二套 SSH 引擎 |
| [Bailey/Editor/SourceTextEditor.swift](../../../Bailey/Editor/SourceTextEditor.swift)，L77–165、L325–361 | `makeScrollView / currentText / handleNativeCharacterEdit` | 初次安装完整 `file.text`；后续已有范围事务。原生控件已经是挂载时的可写真源，不能误称两份独立可写文档 |
| [Bailey/Editor/NativeTextLineIndex.swift](../../../Bailey/Editor/NativeTextLineIndex.swift)，L19–100 | `init / replace` | 全篇建行长度／前缀结构；局部替换已经增量，但行数结构变更会重建 Fenwick |
| [Bailey/Editor/NativeCodeTextView.swift](../../../Bailey/Editor/NativeCodeTextView.swift)，L670–710、L845–900 | `configureWrapping / NativeMeasuredLineWidths` | 全文 NSString／行宽路径仍在；Unicode 巨型单行可整行构造，TextKit 可见布局并不消除此成本 |
| [Bailey/Editor/SyntaxHighlightConfiguration.swift](../../../Bailey/Editor/SyntaxHighlightConfiguration.swift)，L382–393 | `didChangeContent → parser.readFunction(for:)` | parser 仍接完整 String；可见着色不是分页解析 |
| [Bailey/Editor/NativeCodeTextView.swift](../../../Bailey/Editor/NativeCodeTextView.swift)，L295–359 | `finishComposition / replayComposition` | 已恢复局部 composition edits 与 Undo；需要证明跨页、冷页和大范围保留成本，不能再安排删除已不存在的全文快照 |
| [Bailey/Editor/EditorFind.swift](../../../Bailey/Editor/EditorFind.swift)，L17–38 | `FileTab.performFindAction → FindAction.perform → NSTextView.performFindPanelAction` | 当前保留原生 Find；未来分页必须证明实际系统访问边界，不能直接用 Monaco 行为代替 |
| [Bailey/Editor/FileViewerView.swift](../../../Bailey/Editor/FileViewerView.swift)，L379–445；[Bailey/Editor/TextFileEncoding.swift](../../../Bailey/Editor/TextFileEncoding.swift)，L50–101 | `save → writeCurrentText → encoded → backend.write` | 完整 String 编码成 Data，并严格往返；`contradictsDeclaration` 先 `Data(text.utf8)` 再取前缀。应保留严格性，改变全量访问方式 |
| [Bailey/Remote/RemoteCommands.swift](../../../Bailey/Remote/RemoteCommands.swift)，L264–290 | `atomicWriteCommand` | 已用私有 `mktemp -d` 暂存、普通非 symlink 目标的 mode 位继承和目标替换；仍以 `cat` 正常 EOF 作为输入结束，迁移流式编码时必须补完整成功的发布条件 |
| [Bailey/UI/Panes/TabSwitcherView.swift](../../../Bailey/UI/Panes/TabSwitcherView.swift)，L676–749；[Bailey/Workspace/Project.swift](../../../Bailey/Workspace/Project.swift)，L364–395 | `filePreview / diffPreview / textExcerpt / ignoreGitPaths` | 预览先读全文再截 7,000 UTF-16 单元；ignore 追加会查询全文换行。这些非编辑器消费者也在正文链内 |
| [Bailey/Git/DiffViewerView.swift](../../../Bailey/Git/DiffViewerView.swift)，L1327–1449 | `gitComparisonBaseline / readWorktreeFile` | 工作区 5 MiB 边界、完整 Data hash stdin、`maxBytes*4` patch 输出、末次完整原字节核验；blob 之外仍有独立全文成本 |
| [Bailey/Git/DiffEngine.swift](../../../Bailey/Git/DiffEngine.swift)，L75–218、L263–287、L1233–1317 | `GitWorktreeComparison.resolve → DiffCore.computeIfActive → computeLineOps → DiffComputation.build` | 完整行数组／指纹、clean 投影，以及 Unified／Split 左右全文派生内容；只替换核心算法不够 |
| [Bailey/Git/DiffNativeSurface.swift](../../../Bailey/Git/DiffNativeSurface.swift)，L178–294；[Bailey/Git/DiffViewerView.swift](../../../Bailey/Git/DiffViewerView.swift)，L682–708 | `render / nativeTextDidChange` | 工作区已有单一可写 editPane；不可逆 clean filter 保留 canonical 只读比较与 raw 编辑。旧折叠坐标须随快照换代，不能恢复 Review/Edit 交接 |

### 已恢复的修复不是待办

`24014251e16c61e9d43edc363d49bc7e4afd66b7` 已恢复局部 IME Undo；
`5f1024e048c2a00f794f88cf7a2464388bc291a0` 已恢复 SSH 私有暂存写入；
`3d62c14b93bf73745116f48079aec8b0d7d96e50` 已恢复重复行 Diff 精度。
此外保留 `37badb70` 折叠换代、`a66052ae` 文件事件生命周期及
`1d2632a9` 工作树 Git 元数据事件修复。
本轮未修改这些生产源码，也未重跑其历史测试；提交正文中的过去结果不冒充当前新增验证。

已有 `Context.linesEqual` 对指纹命中的文本做实际字节复核；
`Task.isCancelled → DiffCore.computeIfActive(cancellation:) → DiffEngine.lineOpsIfActive`
`→ Context.checkCancellation` 已提供真实取消检查。
未来应把这些不变量延伸到分页与预处理，而不是宣称现有引擎只丢弃结果。

### 两个不能藏在“分块”名下的条件

**稳定读取源。** 逐块访问同一 FD 或同一路径，不阻止外部原地修改。
本地 clone／快照、远端私有源、版本核验的能力与成本须分别证明。
先完整复制／下载再显示会与“首屏先于全文读取”冲突；
这必须在 P1 决定，不能在 P2 实现时悄悄降低目标。

**完整写入的结束信号。** 当前 SSH 写入接收预先形成的 Data；
把它改成可能在尾部发现非法编码的生产流后，普通 EOF 可能来自成功，也可能来自失败或取消。
私有暂存目录只解决隔离，不自动区分两者。
新协议必须在全源严格校验、完整输出结束与长度／校验确认后才发布；未改字节直拷也不能跳过源校验。
并验证“上游失败、下游正常 EOF”的真实时序。
这是新流式路径的设计要求，未在本轮宣称已复现当前产品数据损坏。

<a id="bailey-decisions"></a>
## 五、落实到 adaptive-large-files 的决策

| 决策 | 采用的源码经验 | Bailey 的实际落点 |
| --- | --- | --- |
| 单一正文版本、范围替换、增量事件 | Piece Tree／TextModel 的局部更新 | P2-T1 在现有 FileTab 与原生 storage 之间消除全文属性及基线物化；最少类型替换实际旧职责 |
| 原始字节 backing 与按需索引 | 借鉴片段引用，不照搬常驻字符串数组 | P1-T1/T2 证明未知长度、冷页、巨段落、稳定源；P2 落实页、坐标和回收 |
| 严格原编码、BOM／混合换行保留 | 上游宽松解码和 EOL 规范化是反例 | 保留 TextFileEncoding 的无损语义；对页边界及未访问尾部做完整校验 |
| 冻结快照、有背压的完整保存 | snapshot/readable 与 backup temp→atomic rename | 复用现有保存队列及5f私有暂存；补生产完成协议，不改成默认 truncate-write |
| 预算覆盖所有派生数据 | worker镜像、整行IME、Find和Undo暴露旁路 | 正文、索引、Undo、snapshot、队列、语法树、查找和预览一起计量；主 actor 不等待冷页 IO |
| 精度与完成度分别表达 | advanced Diff 的行／字符分层及 quitEarly | P1-T3/P3 治理全阶段成本；完整行级可展示，未完成整体不能冒称精确或无变化 |
| 原文与 Git canonical 分开 | Git provider、textconv、filter 与字节身份并不相同 | 保留 Bailey 现行不可逆 filter 分支；工作区始终编辑真实原文 |
| 不把研究当作实现验收 | 各层都有静态限制，运行容量仍未知 | P1-T5 结束研究；P1 三个机制单独准入，P2/P3 完成生产与用户链 |

P1 不要求先交付整个 P2/P3 再准入。
它只解决会改变路线的最小未知：原生文档协议、稳定 IO／发布、GB Diff 的有界机制。
缓存预算 B、页大小、队列上限、索引／Undo／快照成本和算法时间由实际最小验证冻结，
不编造本轮未测的推荐数值。
驻留内存受固定预算约束；临时磁盘允许预检过的 O(N) 增长并限制峰值，
不能把磁盘辅助存储误解为必须常量空间。

完整的原生交互、查找替换、编码、真实 SSH、保存保护、Diff 各来源／Unified／Split、
生命周期和 GB 资源组合继续保留在 [P1 覆盖总集](plan-p1.md#验证条件总集)及
[P2](plan-p2.md)、[P3](plan-p3.md)。
以当前 Mac 验收并保留 macOS 15.6 部署兼容，不要求专门取得旧系统或创建 VM。

## 六、本轮证据边界与后续验证

- 上游证据来自固定提交的真实实现；CodeGraph 优先，VS Code 全仓索引超时后按准确路径直接追踪源码。
  索引缺失不作为“代码不存在”的依据。
- `diffEditor.maxFileSize` 未执行、旧 `files.maxMemoryForLargeFilesMB` 不存在等负结论，
  范围限定为本 SHA 的已注明生产链与源码检索；不外推全部历史版本。
- 没有运行 VS Code GB 文件／Diff，因此不报告打开时间、RSS、最大可用 GB 数或具体界面异常。
  没有审计 V8／Electron 的完整运行时硬上限，也不引用旧博客常量替代。
- Remote 部分只论公开仓库的 provider／IPC／server 文件系统数据面；
  不推断闭源 Remote SSH 扩展的认证、安装和隧道实现。
- 本轮没有实施 Bailey 的 GB 文档、运行 App／构建／GB 压测或真实 SSH，也没有安装或替换正式 App。
  `todo.toml` 区分源码研究完成、历史调查记录、待验证机制和待交付产品。
- 本轮验证对象是报告与计划：源码文件／行区间、引用与本地链接、任务锚点、
  feature 状态结构和实际 Git diff；运行容量与数据完整性由对应实施任务取得证据。
