# P2：原生首屏、可写缓冲与折叠交互收敛

**Goal：** 先在同一 TextKit 2 所有者中证明可放行的准确快速几何，
再消除首次全文同步布局和每键全文搬运，保持唯一可编辑缓冲、
手动折叠展开与完整原生交互。P1-T2 尚未找到可放行的布局快路径。

**Non-goals：** 不重建 Monaco／STTextView，不删除底层 Git 快照校验，
不改动通用 Files／Dock 风格，不在此 phase 把 GB 文件引入内存。

**Approach：** 先解决测量证实的源头：TextKit 几何 ownership 与编辑事件边界；
再使折叠／行号／删除 ghost 在同一版本下更新，最后处理共享绘制、滚动和 AX。
每条路径只接一个可信所有者，替代旧调用链时同时删除旧路径。

**Acceptance：**
- 24k/100k 行首次可见与滚动范围符合 P1 冻结的预算，末行与 ghost 立即可达；
  不再靠 `ensureLayout(for: documentRange)` 同步遍历全篇掩盖估算误差。
- 单次可见编辑不再无条件抓取／比较整份原文，普通输入、IME、Undo／Redo、
  自动／显式保存真实落盘，无损保存原始 UTF-8 字节。
- 折叠仅手动展开，修改前方行数、快速点击、保存后重载不改变其它折叠区间；
  可见文字和隐藏文字的编辑作用域可解释、可自动核验。
- Changes、Graph、历史原文、Stash 及其它 Worktree 的适用来源，在统一／分栏中的真实像素、
  AX、两轴滚动一致；重挂载后仍是同一原生对象。

**Rules：**
- P1-T2 已对现有原生视口估算／单段布局／重定位路线判定 No-Go；
  P2-T1 不得直接删全文布局保护。P1-T3 的原生增量通知已有 Go 证据，
  但 P2-T2／T3 仍须独立 Red→Green。
- 纯性能改造不得改颜色、字体、文本／选区语义；需要可见行为决定时依据 `idea.md`。
- 正式 Bailey 不在开发测试期间启动、停止或替换；只用 Bailey Dev 与隔离 Git 文件。
- 每个 task 以当前适用的源码/测试 Red→Green→Refactor，
  实现、旧路径删除、当前契约文档与原子提交同一任务完成。
- 验证取值沿用 `idea.md#验证条件全集（所有任务分摊核销）`，
  下文写明确切对应切片，不能只运行所列最小回归而省略适用极值。

<a id="p2-t1"></a>
## P2-T1 让原生 Diff 首帧布局和完整滚动范围同时成立

**结果：** 完整滚动高度不再以整篇同步布局为代价，
且首次渲染、深处滚动与末尾定位没有精度退化。

**Files／实际路径：**
`Bailey/Git/DiffTextView.swift` 的
`DiffCodePaneView.invalidateDocumentLayout/layout/applyContentHeightOverride/applyGhostSpacing`、
`DiffTextView.setEditingFolds/hasNativeNonLFSeparators/storageCharactersDidChange`、
`DiffRowGeometry.visibleRows`；对照已有 `NativeTextLineIndex`（AppKit 自然段落）、
`TextCoordinateIndex`（仅 LF）与只读 `DiffDecorations.lineStartOffsets`
（已存的 Git 行 UTF-16 起点）。编辑态已移除过期快照偏移字段，
仅复用唯一实时 Git-LF 索引；**原生段落与 Git 行不能语义互换**，不另造行索引 owner；
必要时调整现有 `Bailey/Editor/NativeCodeTextView.swift` 的共用 TextKit 几何，
但必须先证明 Files 同根因和影响范围。
测试主要在 `BaileyTests/Git/NativeDiffTabTests.swift`、
`BaileyTests/Editor/NativeEditorLayoutTests.swift`。

**步骤：**
1. P1-T2 已否决直接依赖 TextKit 估算坐标的简单快路径：24k 行固定 15 pt，
   未完成全篇布局时估算内容高度约 481,215 pt，真实高度 360,000 pt；
   `scrollRangeToVisible` 与单段 `ensureLayout` 仅 4/17 次全局坐标准确，
   `layoutQueue` 不能恢复准确性。不得再把这些路线直接接入生产。
   同一 storage 在重定位时临时跳过前缀的反证也仅 16/17 次坐标及可见性正确，
   恢复枚举前后调整 viewport 或局部布局均未修复首个远跳；见
   `evidence-p1-textkit-transient.md`，不得当作已通过的新路线。
   先在同一个 TextKit 布局所有者内，证明可同时给出准确的滚动高度、
   视口片段、17 次远跳和尾行真实命中，最小原型用纯 LF 无 ghost 的 24k 行。
   未取得可验证原型时，保留现有全文布局保护，暂停该实现 task，
   其它不依赖几何改造的任务继续；不能制造第二个可写缓冲或以定时补全冒充正确。
   原型通过后再扩展 CR／Unicode／折行／ghost 等可变几何，
   不预先搭建两套布局引擎。
   已有跳过折叠隐藏 NSTextElement 的受控实验只有
   24k／120 折叠时 253→50 ms 的布局收益；该方案仅能作为原型入口，
   不得当成未折叠路径或 Undo／IME／Find 已验证。
   将 100k 重定位最差约 310 ms 与热视口 32 ms 目标直接对照，
   不接受把 O(文档规模) 等待从首帧转移到首次远跳。
   先写宿主 Red：首次可见前时间、未滚动时已完整的原生滚动范围、
   滚动条多次直达末尾后不缩短、末项正文与删除 ghost 的真实命中。
2. 把可测的高度／折叠／行片段尺寸归属保持在 `DiffCodePaneView` 与原生 TextKit，
   而不是增加 SwiftUI 高度镜像。固定行高快路径不能套用到裸 CR、Unicode、折行、
   ghost 等可变几何；用 P1 已验证的准确路径处理。仅在对应布局失效时重算。
   **另一个同源热路径必须同时处理：**`DiffRowGeometry.visibleRows` 在无行起点且非折叠时
   从文首枚举到 viewport；优先用当前 Diff 内容版本的 LF UTF-16 行起点反查 Git 行号，
   `NativeTextLineIndex` 仅用于确定 AppKit 自然段落，不得把裸 CR／Unicode 段落算作 Git 行；
   不得每帧扫描文首前缀。
   P1 主线程采样还发现 `NSTextContentStorage.updateRangesForTextElement` 的大量占用，
   与整篇布局后缓存的段落维护有关；须核对消除全文布局后普通编辑的实际变化，
   不能只移走 `ensureLayout` 调用而保留同等规模的缓存维护。
   `hasNativeNonLFSeparators` 的编辑后全文扫描也应在相同任务依原生变化范围收敛，
   不增加第二套全文缓存。
3. **仅在正确的新几何路径通过 Red→Green 后**，删除被替代的
   `ensureLayout(documentRange)` 强制全篇路径、过时 height override 分支和冗余前缀枚举，
   并删除随替代失效的旧测量状态；仍需用于可变行高的分支不可误删。
   内容坐标恢复、滚动锚点和 Split 同步必须继续到达真实可见结果。
4. 用 Instruments 核对源文档是否仍偷偷在主 actor 全文创建布局；
   发现同等成本被挪入其它 callback 时不算通过。

**验证：**
`make test:NativeDiffTabTests,NativeEditorLayoutTests,TextCoordinateIndexTests`，
测试包括 0／1／1k／24k／100k／安全内存内更多极短行、不同位置变更、
非折叠无变更／折叠众多区域、完整删除、长删除 ghost、
LF／CRLF／裸 CR／Unicode 分隔符、无末尾 LF、长行完整显示／截断，
窗口初装／缩放／改字体／折行、Split 纵横两轴、深处滚动／17 次远跳、
两种系统滚动条样式，纯只读与可编辑两类 TextKit。
对顶／中／末相同视口反复滚动记录前缀扫描长度、布局次数及 P95；
单字符变更后核对换行类型缓存与实际 Git LF 行号，
特别是同一 Git 行里多个裸 CR／U+2028 段落；逐项断言原生片段、UTF-16 命中和写盘字节。
必须检查滚动条比例、真实最后片段、选区、行号、滚动锚点和最后的磁盘字节；
30 次热／冷与独立实际首屏数据对照 P1。

**Uncovered：**
只有原生 `NSWindow` 的位图测试不能证明整个 App 的 WindowServer 像素；
P2-T4 和 P4-T2 仍须真实 Bailey Dev。
低版本 macOS 15.6 没有实机时按 `idea.md` 单独记录。

**文档：** 同任务更新 `docs/features/diff.md` 中首次高度和折叠滚动契约，
若共用 TextKit 原生行为改变同步 `docs/features/editor.md` 和 `docs/development.md`。
**提交：** 一次经过验证的几何 ownership 改动、回归及旧逻辑删除，中文原子提交。
**Gate：** P1-T2 无可用正确方案时暂停此实现，不以“滚动到底再完整布局”替代。

<a id="p2-t2"></a>
## P2-T2 消除每次编辑整篇正文回读与重复内容判定

**结果：** 一次普通按键的同步工作与本次变化相关，不因 100k 行正文而重复全量提取；
保存仍基于同一原生可写缓冲，不能留下第二份可写真源。

**Files／实际路径：**
`Bailey/Git/DiffNativeSurface.swift` 的
`makeEditPane/editTextDidChange`；
`Bailey/Git/DiffViewerView.swift` 的
`DiffTab.updateEditedContent/refreshEditDecorations/writeCurrentText`；
优先复用 `Bailey/Editor/NativeCodeTextView.swift` 的
`processStorageEdit`、`NativeTextLineIndex`、`storageCharactersDidChange` 和 `onCharacterEdit`；
对照 `Bailey/Editor/SourceTextEditor.swift` 的
`Coordinator.textView(_:shouldChangeTextIn:replacementString:)/handleNativeCharacterEdit`：
它在变更**之前**取得被移除文字和替换文字，Undo 等无前置通知时进入明确回退，
不能拿变更后 `editedRange` 反推被删文字。参照 `FileTab.refreshDirtyState` 的准确字节语义，
但不得无依据复制整套多层 delta/reversibleEdit 缓存。
主要测试 `NativeDiffTabTests`、`NativeEditorCompositionTests`、
`TextCoordinateIndexTests`、`NativeContentIdentityIntegrationTests`。

**步骤：**
1. 按 P1-T3 已证实的 `NSTextStorage` 编辑范围接入；
   测试旧路径的零参 `onCharacterEdit` 如何迫使 `DiffNativeSurface.editTextDidChange`
   读取 `textView.string` 和 `DiffTab.updateEditedContent` 进行全 UTF-8 比较；
   不预断 getter 一定复制内存，要分别测桥接、扫描、分配与触发次数。
   P1 已测 getter 约微秒级，100k 行文末完整 UTF-8 比较约 136 ms（Debug）；
   此任务应消除已证实的整串判定，而不是宣称已证明 getter 大块复制。
   断言必须从真实原生存储变化进入，不能只直接调用 ViewModel 方法。
2. 在有前置通知时复用文件编辑器已验证的
   `shouldChangeTextIn(range,replacement)` 采样与变更后回调；
   在 Undo、程序改写、IME 未提交等**没有可靠 prechange** 的场景明确用现有原生事件和
   必要的真实字节比较回退，不为百分百增量创造第二份文字真源。
   仅更新必要的变化和版本；Undo 恢复至保存基线时必须准确回干净，
   Unicode 规范等价但字节不同仍须脏。
   脏标记、缓冲来源与保存快照继续只有 `DiffTab` 认可；
   不能为了加速把整个 `String` 永久同步复制到第二个编辑模型。
   后台 Diff 真正开始时取得**与版本一致**的完整快照，编辑继续时使旧任务失效，
   保存时才读取需要写入的原文。
3. 复用文件编辑器已经可靠的 Undo／IME 通知及变更范围处理，
   区分普通编辑、组合输入中间态／提交态、批量粘贴、多范围编辑、
   Undo 回干净与异步保存期间新增编辑。
   不以“反复强制刷新”解决失效通知。
4. 在同 task 清理旧的逐键 `textView.string → updateEditedContent(String)` 整篇传输路径；
   逐项审核 `savedNewContent/editedNewContent/newContent/comparisonNew` 的读写者：
   需要留作 Git canonical 对照、保存基线或一致后台快照的保留，
   已被唯一 TextKit 缓冲取代的镜像才删除。
   同时清除失去作用的回调及触发，不能先留两套文本流“向后兼容”。

**验证：**
`make test:NativeDiffTabTests,NativeEditorCompositionTests,NativeFileTabTests,TextCoordinateIndexTests`；
再在 `Bailey Dev` 验证可见输入、`⌘Z/⌘⇧Z/⌘S`、
自动保存和最终 Git 状态。文首／中／末各 30 次编辑，内容为
1k／24k／100k 短行以及大规模单行，普通字符、换行、删除、粘贴、IME、
多选区、快速 Undo、保存失败和并发再次编辑。
记录 input P95／最长主线程占用／每键字符串总量／重算次数；
核对文件原始字节、工作区与 Index 完全符合用户操作，不改变旧段落。

**Uncovered：**
原生宿主 IME 组合事件不等于真实系统输入法候选界面；
完整 App 系统中文候选在 P4-T2 专门核销。
正式实际 SSH 写入不在本 task 未授权执行，P4-T3 核销。

**文档：** 同任务同步 `docs/features/diff.md` 的单缓冲与输入更新语义、
`docs/features/editor.md` 的真实编辑事件共享契约；
只有性能测试标准确实变化才修改 `docs/testing.md`。
**提交：** 输入数据流单一职责原子提交，立即删除旧逐键整篇传输路径。
**Gate：** P1-T3 不能证明增量通知与原生 Undo 一致时不臆造另一套文字缓存。

<a id="p2-t3"></a>
## P2-T3 统一实时折叠、选区、编辑坐标和手动展开语义

**结果：** 折叠和输入具有同一内容版本，普通光标编辑不跳开未修改区域，
也不因旧坐标误删或误着色隐藏段落。

**Files／实际路径：**
`DiffTab.expandRun/refreshEditDecorations/nativeTextDidChange`、
`DiffEditFold.sourceFolds`、
`DiffTextView.setEditingFolds`、
`DiffCodePaneView.setEditingFolds/applyGhostSpacing`。
测试 `NativeDiffTabTests` 中
`testEditingBeforeExpandedContextRetainsItsSourceLinesWithoutOpeningOtherFolds`、
`testRapidRepeatedFoldClicksRevealDistinctUnchangedLines`、
`testFoldedEditorUpdatesSourceOffsetsWithoutRevealingHiddenParagraphs`、
`testNativeDiffEditUndoScrollSaveAndReparent`。

**步骤：**
1. 构建真实原生旧失败前提：在折叠区域**之前**连续插入／删除换行，
   处于后台 120 ms 防抖期间交错快速输入、Undo、点击折叠、保存，
   记录当前源码 UTF-16 坐标、可见行号、折叠区间及点击位置是否不一致。
   已正确行为保留原样，不凭可能性补分支。
2. 让轻量文本变更坐标和当前可见折叠归一个版本；
   `DiffTab` 继续拥有不可变基线展开锚点，
   `DiffTextView` 只接收针对本次原文的行坐标；
   不能在异步装饰到达前把上一版本折叠范围套在新文本上。
   失效时要保持正确的可见行为，不允许首帧先展开全文。
3. 固定 P1-T3 的真实交互决定：
   点击折叠标记逐步展开，普通代码点击／选择／编辑不自动展开；
   跨隐藏边界选区、粘贴、Delete、Find/Replace、`⌘A`、
   IME 和多选区遵守明确的原生文档语义，
   不能无声修改用户没有明确覆盖的隐藏行。
   不因实现简便把选区和 Undo 禁掉。
   P1-T3 已修复窗口菜单对 `.diff` 的查找／替换启用与派发，
   并沿用原生 `NSTextFinder`；真实 Dev App `⌘F`／`⌘⌥F` 可打开对应栏，
   Staged／历史只读不允许替换。不要在本任务再造相同派发接口或查找引擎。
   本任务专注尚未通过的行为：Find 栏取得焦点后重复 `⌘G`，
   跨折叠隐藏区间的 Find／Replace、跨行选区和保存，
   Split 切换与未显示列的旧查找状态，确认原始磁盘字节与焦点归属。
4. 逐一验证默认折叠、两次快速点击、只展开原区间、前方编辑、
   baseline 变动与保存后保留；先用 CodeGraph 证明实际仍存在的
   重复坐标表、强制重绘或事件围栏，然后在本任务同一提交删除。
   **源码没有证据的所谓旧 `runIndex` 迁移不得列为必删项目**。

**验证：**
`make test:DiffEngineTests,NativeDiffTabTests,TextCoordinateIndexTests,NativeEditorCompositionTests`；
隔离 Bailey Dev 的折叠点击、可见文字编辑、焦点保持和实际窗口标记由
`WorkspaceGitUITests` 的完整操作补足。
输入矩阵包括空、1 行、长重复行、Unicode 组合、混合换行、
数十／上百折叠区域与删除 ghost，编辑／Undo／保存／刷新，
Split 左右行对齐、远距导航、AX 点击和极短窗口。
核对最终原文件字节、选区范围和显示层，不只核对折叠状态列表。

**Uncovered：**
真实系统剪贴板延迟类型／中文候选只有独立 GUI 会话才能完整验证，
P4-T2 补验，禁止擅自改动用户剪贴板。

**文档：** 同任务更新 `docs/features/diff.md` 和真正受影响的 `docs/ui.md`
折叠与编辑作用域；一般编辑契约变化才同步 `docs/features/editor.md`。
**提交：** 单一内容版本／折叠坐标改动和相应回归原子提交，不留旧序号映射。

<a id="p2-t4"></a>
## P2-T4 收敛 Unified／Split 的滚动、视觉层级和真实坐标

**结果：** 工作区、暂存、历史共享同一真实 Diff 行语义与渲染层，
没有错位、高亮丢失、遮挡滚动条或切主题后延迟更新；
真正关闭 Diff 标签后不残留可编辑原生正文，Dock 重挂载则保留同一对象。

**Files／实际路径：**
`Bailey/Git/DiffNativeSurface.swift` 的
`render/layout/restoreAnchor/apply`；
`Bailey/Git/DiffTextView.swift` 的
`DiffCodePaneView.layout/setScrollOffset/setReviewDocument`、
`DiffRowGeometry.visibleRows`、`DiffDecorationUnderlayView`、
`DiffFoldOverlayView`、`DiffGutterView`；
`DiffSyntaxHighlighter.attributedDocument`；
真实关闭链 `Project.remove/terminateAll`、`PaneTab`、`DiffTab.nativeSurface` 与
`DiffNativeRoot.dismantleNSView`，对照 `FileTab.retireNativeEditor`，
以及 `NativePaneRetentionIntegrationTests` 的旧 AppKit scroll view 保留用例。

**步骤：**
1. 以同一原文／变更样本对照四个可达原生 pane（Unified、Split 两侧、Worktree），
   复现影响滚动及像素的实际缺陷；数据来源不同不应导致折叠线条、字号、
   配色、删除 ghost、词级强调和标记锚点不同。
2. 共用已有行与视口几何，保留 `NSClipView` 内正文前景遮盖、滚动条上层；
   滚动和窗口缩放只重绘当前视口，不能逐帧重新布局全文；
   纯主题／语法颜色变化不重建内容与滚动位置。
3. Split 上下和横向滚动只传播**合法位置**；
   左右一侧较短时不能把长侧拉回；恢复首次变化定位和文首／中／末阅读锚点。
   保留 `showAll` 模式长行折行与 Split 不独立折行的既有契约。
4. 变更内容、字号／主题、Find bar、布局模式和多窗口后反复定位，
   彻查重复渲染、隐藏 pane 后仍计算及视图身份变化；
   若当前已经达到性能与像素不变量，只保留证明而不改生产代码。
5. **对照 FileTab 的真实关闭资源归属，补 Diff 退役的 Red→Green：**
   `Project.remove` 对文件调用 `retireNativeEditor`，对 Diff 只清快照回调；
   `Project.terminateAll` 也只退役文件；`DiffNativeRoot.dismantleNSView` 当前只撤销焦点。
   在真关闭 Diff 标签／项目／窗口后故意保留原 `NSScrollView` 强引用，
   检查旧 `NSTextView` 是否仍可写、持有 Undo／解析器与全文缓冲。
   若复现保留问题，只在**真正所有权结束**的最小 owner 退役旧原生内容，
   解除 ScrollView documentView 强引用、禁用过期回调与 Undo／语法任务；
   在替代链生效的同一 task 清理旧残留，不新增全局 native-resource manager。
   P1 的 5 标签反证还发现：旧编辑器已释放 60 秒后，原始 TextKit 布局 manager
   仍全部存活；受控实验在真正关闭后从原 content storage 移除 manager，
   可以释放它们及相应在用内存。不能只断言旧 NSTextView 已释放就算完成。
   须沿 `NativeCodeTextView` 共享创建链验证生命周期和 Files 编辑器影响，
   用原生对象弱引用与内存证据确认释放，不直接把实验性拆解顺序当成生产实现。
   SwiftUI 临时 `dismantleNSView`／Dock 重挂载**不得**触发退役，
   切回时同一 TextKit/Undo/滚动原对象必须仍可操作。

**验证：**
`make test:NativeDiffTabTests,NativeSyntaxHighlightingTests,NativeContentIdentityIntegrationTests,NativePaneRetentionIntegrationTests,WindowCloseIntegrationTests`；
真实 Bailey Dev 截图像素与 AX（P2-T5 共用）核对。
所有 Staged／Unstaged／历史、Unified／Split、亮暗及高对比、
滚动条传统／浮动、窄／宽窗口、水平／竖直、主题／字体切换、
长行、裸 CR、CRLF、Unicode、删除多块、可见中间和文件末尾。
最终核对每一行色块／字形／原生滚动条相对层级和物理可视内容，
原文及 Git 比较保持不变。
另在 1／5／10／20 Diff 标签与长行／5 MiB 合法文本下真实关闭、整项目关闭、
窗口关闭、保留旧 AppKit 宿主、重复开关、带未保存草稿取消关闭等条件，
核对真正关闭后正文不再被旧 NativeView 保留、脏草稿确认前绝不提前清理，
并测重新打开／撤销历史与当前标签身份。

**Uncovered：**
宿主位图不能单独证明 WindowServer 合成，P4-T2 复验真实 App 像素。
**文档：** 修改共有视图规则时同步 `docs/features/diff.md`、`docs/ui.md`，
共享 TextKit 容器变化才更新 `docs/architecture.md`。
**提交：** 单一原生渲染归属变更原子提交；若没有产品缺陷，补验收证据而不是制造重构。

<a id="p2-t5"></a>
## P2-T5 验证 Git 行浏览、折叠 AX 与焦点动作

**结果：** 可视折叠标记和 AX Press 指向同一个可触达行为，
后台展示／鼠标点击／键盘／系统焦点之间不发生自动展开或错误输入。

**Files／实际路径：**
`DiffGutterView.accessibilityChildren`、
`DiffCodePaneView.activateFold/expandCollapsedRow`、
`DiffFoldOverlayView.draw`、
`DiffNativeSurface.makePane/makeEditPane/requestFocus`、
`GitPanel.browseGitChange/selectGitChangeForPointer`、
`GitStatusModel.selectChange`、`WorkspaceWindowModel.openDiff`、
`DiffTab.setEditorActive`；
测试 `NativeDiffTabTests` 的
`testEditableFoldAccessibilityFrameMatchesActualClickAfterScrolling`、
`testFoldIndicatorIsClippedInsideScrollContentAndNeverCoversScroller`、
`testWorktreeFoldedEditorKeepsFoldsOnClickAndExpandsOnlyOnSeparator`，
以及 `WorkspaceGitUITests/GitChangesUITests`。

**步骤：**
1. 深处滚动后比较原生翻转坐标、AX frame、实际鼠标点击与键盘动作；
   先证实可复现的问题，再在共享 `DiffCodePaneView` 的坐标变换源修复，
   不写二套虚拟按钮。
2. 核对点击折叠、纯移动光标、切 pane、切 Dock、右键菜单和快速重复选择，
   仅明确用户动作触发展开；保留当前窗口级第一响应者，不因浏览 Diff 抢其它组焦点。
   **同时测 Changes 的真实点击链：**`selectGitChangeForPointer` 每次计算
   `navigableChanges.map(selection)`，在 1／100／10k 行仓库与 Shift／⌘ 组合选择时，
   分离这段投影与 `Project.openDiff` 的延迟。若 P1 证明它影响浏览响应，
   在 Git 选择 owner 复用现有稳定行身份，删除被替代的重复数组构建，
   不创建第二套 Changes 选区状态或通用事件管理器。
3. 压缩布局、主题／字号变化和两类滚动条下，
   AX 名称、数量、坐标、可执行 Press 与目视标记一致，
   编辑／只读模式分别具有正确 `AXEditable` 状态。
4. 避免为解决 UI 测试注入超时增加 Sleep、焦点劫持或全局快捷键；
   自动化环境干扰独立分离，保留失败日志。

**验证：**
`make test:NativeDiffTabTests,NativeContentIdentityIntegrationTests,PanelContextTests,GitStatusModelTests`，
加 `make test:ui ONLY_TESTING='BaileyUITests/WorkspaceGitUITests BaileyUITests/GitChangesUITests'`
中的真实 App 用户入口（执行时根据专用桌面与选例成本选择，最终 P4 扩展）。
涉及前台键盘与真实辅助功能动作必须用隔离 Bailey Dev 验证。
覆盖顶／中／深处、大小窗口、折叠标记被裁剪时、背景窗口／多组、
1／100／10k 级 Git 变化列表、单选／Shift 范围／⌘ 多选／右键仅定向，
Staged／Unstaged／历史、正常编辑及未保存状态；
除 AX 与焦点还需比较实际用户点击到 Diff 首像素的延迟。

**Uncovered：**
真实 Windows SSH 不可由本地 AX 覆盖；它的远端 Diff 行身份到 P4-T3 核对。
**文档：** 同任务更新 `docs/features/diff.md`、`docs/ui.md`（仅改变真实行为时）。
**提交：** AX 与焦点共用行为若需修复，连同行为测试和旧动作清理原子提交。

## Phase Gate

P2 的正确性、首屏、输入和 GUI 行为逐项通过后才进入交叉全局验收。
每个 task 可独立提交，但阶段完成必须核对 P1 冻结的预算及全矩阵；
实际开始审计时才创建 `audit-p2.md`。
