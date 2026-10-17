# P1：稳定滚动几何与低资源占用的源代码编辑器

**目标：** 根治源代码浏览新区域时**滚动条长度／阅读位置异常跳变**，同时让 382、1,000、10,000、100,000 行 Swift 文件的打开、查看、连续编辑与关闭具备低 CPU／内存成本。真实复现文件：`kero/Files/FileTreeModel.swift`（382 行／16,050 字节）。坚持 Swift 6／AppKit／TextKit 2 按需布局；不修并不存在的自定义触控板事件层，也不靠强制全文排版换取稳定。

**不做：** 触控板 `scrollWheel` 事件补丁、独立 Git／Files／Diff 算法、Rust／GPUI／Rope、Neon 插件迁移或第二套编辑器。共享 STTextView 修复须验证 [原生 Diff](../../../docs/features/diff.md) 使用者；不覆盖正在进行的 P6 工作区或暂存文件。

**方案与顺序：** T1 建立滚动几何、编辑主线程成本及内存基线；T2 在 STTextView 的**唯一几何所有者**处稳定滚动范围与文本锚点；T3 解决真实十万行文件的容量、初开与资源成本；T4 消除已确认的**每次按键整文快照／比较、全量坐标平移**等热路径；T5 用相同样本综合验收。不预置第二套编辑器或 Rope，只有 T1/T4 测量表明原生数据结构无法满足目标才做最小 Swift 分段索引替换。每个实现任务**同次接入新路径、删除旧路径、测试并更新拥有者文档**；实验放 `build/performance/editor-rendering/`，结论归 `evidence-p1.md`。

**与既有优化的关系：** [此前 P3 实验证据](https://github.com/chiimagnus/kero/blob/08adf2c45b4f3354b1d2af2a54d97fafb6b52271/.github/features/editor-git-performance/evidence-p3.md) 表明，已有实现改善了 Tree-sitter 后台解析、初次 Query 编译和长文档定位，但先前测得的输入延迟不代表对十万行文件持续按键的低开销。文件加载时完整进入 `FileTab.text` 和 STTextView；动态发生的是 TextKit **视口排版**，不是滚动时读取文件块。沿用现有 Neon、查询缓存和 STTextView 可见正文 fragment 复用；保留高亮正确性，不重做解析器。

**按实际调用链核对的事实（具体异常仍需 T1 记录）：**
- **完整读取与容量**：`FileTab.reloadFromDiskIfClean` 后台完整读取／UTF-8 解码、比对旧字节后才更新 `reloadRevision`；`SourceTextEditor.makeScrollView` 一次将全文赋给 STTextView，并非按滚动位置分块读取。`FileTab.maxTextBytes = 5 << 20`（5 MiB），`LocalWorkspaceBackend.read`／`SSHWorkspaceBackend.read` 遵守传入上限，`FileTabTests` 专门断言超限拒绝。**十万行真实 Swift 文件可能超限**，T3 必须连带修订读入额度与测试／文档，不能只做一个十万行极短文本的假测试。
- **真正的滚动触发链**：`NSScrollView/NSClipView → STTextView.prepareContent(in:) → layoutViewport() → NSTextViewportLayoutControllerDelegate.didLayout → updateContentSizeIfNeeded()`。`prepareContent` 向上预备半个视口，正文 fragment 已由 `fragmentViewMap` 复用，`layoutViewport()` 最多进行 5 轮有因由的布局收敛；Kero／Vendor 没有自定义 `scrollWheel`。不要简单禁用按需布局、移除收敛保护或翻 `isCompatibleWithResponsiveScrolling` 开关。
- **滚动条高度变化的直接机制**：`STTextView.updateContentSizeIfNeeded`（`STTextView.swift`）每次都从**文末布局 fragment／textSegmentFrame**计算 `estimatedSize.height`，再以 `setFrameSize()` 更新 `documentView.frame`。TextKit 按需排版导致文末坐标估计会变化，STTextView 自己的 `sizeToFit()` 注释也明确承认**估算高度随滚动逐渐变化**（注意：Kero 现有 `SourceTextEditor.sizeThatFits` 并未调用 `sizeToFit()`，不能把它误判为直接热函数）。Apple 的 `usageBoundsForTextContainer` 还能通过 KVO 触发 `needsUpdateConstraints`；`didLayout` 在看似到底部、实际未到文末时另有 `relocateViewport(to: documentEnd)`，可能进一步调整 frame 和锚点。这一**估算高度 → frame／滚动范围变化 → 重新布局／重定位**是新症状首要验证的完整反馈链。<https://developer.apple.com/documentation/appkit/nstextlayoutmanager/usageboundsfortextcontainer>
- **滚动时重复工作**：`STTextView+Gutter.layoutGutterLineNumbers` 每次布局移除、重建可见行号 cell，并用 `textElements(for:文首…viewport).count` 计算绝对行号；选择／当前行高亮、Neon 可视区着色也可能产生额外分配。先与文档高度跳变区分归因；**若行号确实是 CPU／内存热点**，就由原有 gutter owner 增量计算／复用可见行号单元，替换文首前缀数组与每帧销毁路径，保持 marker、Unicode、折行等行为；不新增第二套正文缓存。
- **滚动位置与状态**：`SourceTextEditor.RestorableScrollView` 初次挂载恢复 clip bounds，窗口尺寸变化时更新几何；`EditorState` 被 `@ObservationIgnored` 排除，不是每次滚动触发 SwiftUI 重新生成正文的证据。需要调查文末 `relocateViewport` 与错误高度是否共同导致跳行。`FPSCounter` 的 `CADisplayLink` 回调数不代表实际呈现帧。
- **编辑时已存在的整文路径**：`SourceTextEditor.Coordinator.textViewDidChangeText` 每次调用 `textView.text`；STTextView getter 返回 `textContentManager.attributedString(in:nil)?.string`，然后 `FileTab.refreshDirtyState()` 使用 `text.utf8.elementsEqual(savedText.utf8)` 整文比较。`SyntaxHighlightCoordinator.didChangeContent` 又对 `NSTextContentManager` 取得全文字符串，并将其提供给后台 Tree-sitter read handler；`TextCoordinateIndex.replace` 平移修改行之后所有行起点，文件头编辑与行数有关。**这些是确定存在的可达工作，不等于已经量得每次都复制多少 MB**。独立关注主线程耗时、快照分配以及 Undo／IME／保存契约。

**从 Zed 直接借鉴的方案（不移植 Rust）**：Zed 的 [ScrollAnchor](https://github.com/zed-industries/zed/blob/main/crates/editor/src/scroll.rs) 保存**文本锚点与屏幕偏移**，而不是仅记一个易受高度修正影响的 Y 像素；[DisplayMap](https://github.com/zed-industries/zed/blob/main/crates/editor/src/display_map.rs) 经 [WrapMap](https://github.com/zed-industries/zed/blob/main/crates/editor/src/display_map/wrap_map.rs) 管理实际显示行，软换行位置和改动通过分段树及后台任务维护；[EditorElement](https://github.com/zed-industries/zed/blob/main/crates/editor/src/element.rs) 只对 `start_row..end_row` 布局可见文字；[Buffer](https://github.com/zed-industries/zed/blob/main/crates/language/src/buffer.rs) 将实时文本与便宜的快照分离。Kero 可复用 TextKit 原生输入／绘制，优先实现相同**职责边界、可见区工作量和按修改范围更新**，不再造 GPUI。

**现成能力与必须保留的行为**：`DiffTextView.applyContentHeightOverride` 已用 `overrideContentHeight` 为**固定行高的 Diff**提供稳定高度，这是可对照的本仓方案，但源码编辑器存在 CRLF／Unicode／软换行、字体变化，不能直接套用其 `rowCount × rowHeight`。`EditorNavigationTests` 测的是双向跳转可见，不检查连续滚动时的 `frame.height`／滑块比例；新的几何回归应在现有 NativeUI 目标内补足。保留 `sizeThatFits` 防止窗口无限布局、文末点击／长行横滚／选区与 IME、保存和重挂载保护，以及共享 Diff 的固定行高。现有 [文件编辑器契约](../../../docs/features/editor.md) 还要求保存基线**字节完全相同才清除脏标记**，撤销和手动重打相同内容都必须立即正确；不能以单一 `revision != savedRevision` 替代字节判定，破坏 Undo 恢复。修改保存快照的所有者应追到 `Project.appendText`、`TabSwitcherView` 摘要、标签重挂载、`FileTab.save/reload` 与本地／SSH 实际字节写入。正式实现时**每个相关 task 同步删除旧路径、更新 `docs/features/editor.md`／必要的 `docs/development.md`**；不建立第二套编辑器。

<a id="p1-t1"></a>
## P1-T1 捕获文档高度与滚动条跳变的真实反馈链

**性质：** 最小诊断任务。先确认 382 行文件的**文档几何跳变**是否成立，同时建立编辑整文工作量和 CPU／内存前基线，避免 T4 改完才发现没有可比样本。不改正式渲染算法，不加入永久埋点。

1. **真实小文件先行**：用 `kero/Files/FileTreeModel.swift`（382 行／16,050 字节）在隔离的原生编辑器中复现；固定文件版本、字体、默认不换行、窗口大小、Debug/Release 模式，再做约 **1,000、10,000、100,000 行**的真实 Swift 结构样本。记录每个样本的 UTF-8 字节数和是否超过现有 5 MiB 容量限制；容量拒绝单列为 T3 的问题，不用极短行掩盖。
2. **直接测滚动范围**：从文件开头、小步连续下/上滚、拖动滑块到约 25%／50%／75%／文末，再反向返回；各点同步记录 `scrollView.documentView.frame.height`、`NSClipView.bounds.origin.y`、`NSScroller.knobProportion`／`doubleValue`、`textViewportLayoutController.viewportRange` 和首个可见行的屏幕位置。对固定文本／字号／宽度，**文档总高度与滑块比例**应稳定，`doubleValue` 和可见行则应随滚动正常变化；先确认**哪个值发生了非预期变化**，以及可见行是否因此瞬移。使用原生手势／滚动条观察现象，测试中直接移动 clip bounds 可以验证几何不变量，不能由此声称物理手势 FPS。
3. **逐调用点确认因果**：在仅用于本地测试的边界记录 `updateContentSizeIfNeeded → estimatedSize.height → setFrameSize`、`usageBounds` KVO→约束、文末判定→`relocateViewport`／`adjustViewport`、`RestorableScrollView` 的恢复／resize 时机以及 `layoutViewport` 收敛次数。看**滑块比例变化是否与 frame 高度重新估算一致**，还是正文重绘/行号导致独立卡顿。只有对应主线程耗时明显时使用 Instruments Time Profiler／`sample`，Xcode Beta 诊断服务失效时记录阻塞，不凭 FPS 徽章代替几何证据。
4. 对照 **不换行／软换行**、首次滚到未布局位置／回到已布局位置；改变字体、窗口宽度或插删行时，判定哪些高度变化确属合法。尤其验证**估算高度过短时误判“已经到底部”**是否触发 `relocateViewport`。排除动态文档几何后，才单变量开/关行号或高亮测试独立耗时；不下载 Zed 作为必须前提。
5. **建立资源基线**：同文件分别在文首／中／末执行单字符插入、删除、Undo／Redo 与 30 次连续输入，确认实际调用到 `STTextView.text` 全文 getter、`refreshDirtyState` 比较、`SyntaxHighlightCoordinator.didChangeContent` 快照和 `TextCoordinateIndex.replace` 的次数／耗时；记录主线程中位／p95／最大、每次编辑分配、进程峰值／稳定驻留内存。再观察静置 30 秒的 CPU／唤醒、滚动 30 次以及 5 个标签打开／关闭后内存。样本与窗口、字体、语言、换行、Debug／Release 分开标注；尚被 5 MiB 拒绝的十万行样本注明不可测，不能冒充已验收。
6. `evidence-p1.md` 汇总几何跳变、调用栈、主线程与内存数据、未测条件和不发生异常的对照，按**几何、编辑、文件加载**标明 T2～T4 应改的唯一 owner。临时采样放 `build/performance/editor-rendering/`，不新增永久 XCTest target、产品定时器或性能日志服务。

**门槛：** 固定文档高度／滑块比例异常与调用链相关，才进入 T2 相应几何改造；高度稳定则改查 fragment／行号／高亮 CPU。文件超过 5 MiB 的拒绝已从源码确定，可纳入 T3。T4 的两个整文 getter 和一个后续行偏移更新是确定存在的候选，按 T1 的真实开销**分别决定**是否需要更换所有者或索引，不因 Zed 用 Rope 就贸然移植。

<a id="p1-t2"></a>
## P1-T2 重构单一文档几何模型，稳定滚动条和阅读锚点

**性质：** 先解决 T1 已证明的**文档高度不稳定／视口被错误重定位**，这是当前用户体验的核心；行号、Neon 等独立耗时只在根因排除后处理。正文继续按需绘制，滚动条所依赖的**完整文档几何**必须另有稳定且正确的来源。

1. **责任位置**：先审 `STTextView.updateContentSizeIfNeeded` 与 `STTextView+NSTextViewportLayoutControllerDelegate.didLayout`／`relocateViewport`，并追踪 `setFrameSize → prepareContent → layoutViewport`、`usageBounds` KVO 的反馈；这是多个滚动方式汇聚的共同 owner。实测确立唯一几何更新入口，区分**全文稳定范围**与**当前可见区布局**，不要在 `SourceTextEditor` 或 `NSScrollView` 外层追加“拖动时冻结滑块”的补丁。
2. **无软换行时**：利用文档段落/行数和经过验证的实际行高确定可重复的总高度／滚动范围（可参考现有 `DiffTextView.applyContentHeightOverride`，但它只适用 Diff 的固定行高）。先核对末尾换行与额外行、CRLF／bare CR／Unicode、emoji/字体回退、段落样式与行高是否真的恒定；只有证明等价才能复用简单行数×行高，不能把 `TextCoordinateIndex` 的 LF 假设直接用作 TextKit 高度真源。**382 行也必须稳定**，不要靠达到行数阈值才启用修复。
3. **软换行／高度可变时**：精确总高度依赖实际的行折返／字体布局，不能一面拒绝必要布局、一面无条件保证首帧已知精确高度。先验证 TextKit 的布局范围／位置 API；需要异步补足显示行几何时，以**文本位置＋视口内像素偏移**为滚动锚点，保持阅读行屏幕位置、滚动位置单调、末尾可达；背景得到更精确高度时只合并必要修正，禁止每滚一屏反复跳动。借鉴 Zed 的 WrapMap 原理但优先原生可用能力；不锁死错误尺寸、不每帧 `ensureLayout(documentRange)`、不另建一份完整文本或定时预热器。
4. **单一更新链与当次清理**：检查文末 `relocateViewport` 是否被不准确的 documentView 高度误触发；新模型替代旧的“每次 didLayout 用文末 fragment 反复估高／反复 setFrameSize”分支时，**同 task 删除被替代的反馈循环和无消费者代码**。只在真正几何变化时更新 frame/scroller，必要时保留可见文字锚点。保留 `SourceTextEditor.sizeThatFits` 的窗口约束、布局收敛保护、水平长行滚动、短文末尾点击、IME 与 Diff 的 `overrideContentHeight`，不误删实际修复。更新 `docs/features/editor.md`／`docs/development.md`，共享 Diff 受影响再同步 `docs/features/diff.md`；保留 Vendor 版权。
5. **先 Red 后 Green 的原生几何回归**：在现有 `EditorNavigationTests`／对应 NativeUI 测试中，固定文本+窗口时记录初始 `documentView.frame.height`、`verticalScroller.knobProportion` 和视口顶部字符/坐标，再多次滚动及反向（包含 0／25／50／75／100%），断言滑块比例不随视口改变、阅读锚点不跳、文末真的可达。单测覆盖 382／1,000／10,000 行，100,000 行纳入受控的性能/集成测试避免拖垮日常单测；字体、折行、内容修改必须触发**正确而稳定**的尺寸更新。共享实现还必须通过 `DiffTabTests` 的固定高度和双栏同步、`PaneRetentionTests` 的重挂载，以及相关输入和查找测试。改动无净收益或产生不正确滚动范围则撤回候选，改动当次完成测试、旧路径清理和原子提交。

**决策边界：** 正文 fragment 按需复用不等于滚动范围必须不稳定。如果稳定几何无法在现有 TextKit API 下准确获得，先以实验说明限制和可观察误差，才评估最小的 Swift 原生几何计算方案；不因 Zed 使用 GPUI 就写 CoreText/Metal 或第二套输入系统。行号前缀枚举等独立 CPU 热点只有 T1 测得后才在所属 owner 另行优化，不能遮盖高度问题。

<a id="p1-t3"></a>
## P1-T3 保证小文件首开与十万行代码的加载、编辑成本

**性质：** **十万行文件可读、可编辑且资源成本可控**是明确需求；现有 5 MiB 限制可能阻挡，必须先测量而不是无条件提高容量。首开／解析额外优化只针对实测独立瓶颈，不建第二套只读编辑器。

1. **四档真实规模**：先用 `FileTreeModel.swift` 和约 1,000／10,000／100,000 行包含 Swift 语法、长行、注释及 Unicode 的代码样本，逐档记录**UTF-8 字节数**。至少一个十万行样本应真实超过 5 MiB，明确表现为现行 `FileTab.maxTextBytes` 拒绝，而不是把超限失败误记为渲染慢；另一个十万行样本在现行上限内时，可先用于 T2 的布局实验。
2. **容量与读取唯一 owner**：`FileTab.maxTextBytes`、`readContent/loadedContent` 决定本地 `LocalWorkspaceBackend.read`／远端 `SSHWorkspaceBackend.read` 上限。先对典型十万行文件记录真实 UTF-8 字节数、文本/语法树/布局峰值内存、编辑后稳定内存和冷开耗时，结合实测峰值和必要的现有复制成本，确定**有依据且仍有限制**的可编辑容量；此任务确保文件读入、可编辑及保存正确，T4 随后针对连续输入的额外整文工作继续降低 CPU／内存，不把 T3 的基本正确性交给后续任务。不能仅调大常量便宣布性能达标，也不能无限制读取、静默截断、降级只读或修改远端目标边界；新阈值要在 `FileTabTests` 与编辑器文档一并更新，保留超过新阈值／非法 UTF-8／断线／编辑中保存的真实保护。
3. **按阶段评估首开**：沿 `FileTab.reloadFromDiskIfClean → SourceTextEditor.makeScrollView/textView.text → 第一次 viewport layout → SyntaxHighlightCoordinator` 区分读／解码、主线程文字安装、正文可见、可编辑和颜色完整的时间。只有 T1/T3 数据证明某阶段额外卡顿才修改对应 owner；仍沿用现有后台 parser 与 Query 缓存，不预热全文、不在首次绘制时 `ensureLayout(documentRange)`。新尺寸模型也不能让首次打开空白、错误滑块或切回后跳位。

**验证和清理：** `FileTabTests` 覆盖新容量边界（阈值内／阈值外、本地与 SSH 模拟、UTF-8、替换后保存及未保存编辑保护），受影响时跑 `SyntaxHighlightingTests`、`EditorTextInputTests`、`PaneRetentionTests`。十万行样本真实加载后检查首屏、可编辑、滚到中部／文末／回到文首、Undo、Find 和保存字节，以及加载／滚动耗时与峰值内存。采取新容量/首开逻辑的**同 task 清理旧阈值常量、旧特殊分支与过期测试**，及时更新 `docs/features/editor.md` 的真实限制和维护文档；不能仅上调常量后不实测。

<a id="p1-t4"></a>
## P1-T4 消除每次按键的整文工作并控制内存

**性质：** 由 T1 已测的 CPU／分配瓶颈驱动的编辑数据流重构，目标是小范围编辑主要付小范围的计算成本。不预设必须写 Rope 或全新编辑器；**保存基线、Undo 与后台解析的正确性不可缩水**。

1. **首先定位所有消费者**：`SourceTextEditor.Coordinator.textViewDidChangeText → STTextView.text → FileTab.text → refreshDirtyState`、`SyntaxHighlightCoordinator.didChangeContent → NSTextContentManager.attributedString(in:nil)?.string → TreeSitterClient.readHandler`、`TextCoordinateIndex.replace` 后续行整体平移；另追 `FileTab.appendText/save/reload`、`Project.appendText`、`TabSwitcherView.textExcerpt`、断线重连与 PaneRetention。先用 T1 数据确认是否为每次编辑的主要同步耗时／分配，区分 `String` 本身可能共享存储与 `NSAttributedString.string` 的实际物化成本；不把“调用全文 getter”直接等同于已测得等量物理拷贝。
2. **统一实时正文所有者与快照边界**：优先由已存在的 TextKit 原生文档承载挂载中的实时编辑，未挂载内容仍由长期 `FileTab` 可读；将完整文本快照移到真正需要的保存、导出、关闭／外部消费者，并在切换／拆卸前保持内容可取得。若最小方案需要让 `FileTab` 暴露按需快照，避免在 `TabSwitcherView` 预览或焦点变化时反过来对整个大文档重复提取。**同一内容代次的语法解析与保存不要各自重复物化完整正文**；但 Tree-sitter 后台 read handler 必须捕获可长期有效的**不可变内容**，绝不能从后台直接访问会继续编辑的 AppKit mutable content manager。只有真实内存／耗时收益确立后才采用共享增量快照方案，不建第二套长期竞争的正文状态。
3. **保持字节级脏状态**：现有 `FileTab.refreshDirtyState` 使用 `text.utf8.elementsEqual(savedText.utf8)` 逐字节对照，保证撤销和**手动重打原字节**时立即清除未保存状态。可利用实际编辑范围和已有基线减少无意义的整文判断，但必须保留完全相等时的确定性字节确认；单纯计数版本号、`UndoManager` 状态或哈希相等都不能替代精确相等。保留 Unicode 规范等价但字节不同、CRLF、空文档，以及编辑发生在保存过程中的 `savedText`／`targetGeneration` 语义；旧保存结果不能清掉新改动。
4. **坐标与高亮仅更新实际变化区域**：目前 `TextCoordinateIndex.replace` 对所改行后面的所有行起点加 delta，是 O(剩余行数)。先用 1k／10k／100k 行在文首单字符插删与连续 Undo 测量；确认它是长尾来源时，将该同一索引所有者改为**分段偏移／前缀累计结构**，让定位与范围替换主要依赖被改区段规模，移除旧的全文尾部循环，复用现有 Tree-sitter UTF-16／LF 坐标与 Unicode 测试。不新建平行 index、不移植 Zed 的 Rust SumTree；Neon 的视口失效和异步解析继续按内容版本避免旧结果覆盖新文本。
5. **TDD、当次清理与原生验证**：先在现有 `TextCoordinateIndexTests`、`SyntaxHighlightingTests`、`FileTabTests`、`EditorTextInputTests` 增加能复现 CPU／坐标／字节语义的失败用例；代码改动当次删除已替代的整文读取／尾部平移旧路径及无消费者兼容层，检查无重复状态所有者。验收文首／中／末输入、Undo／Redo、中文 IME、规范等价、自动保存与写入中编辑、Git Ignore 追加、TabSwitcher 摘要、切标签／关闭释放；性能测量保留 30 次中位／p95／最大、峰值分配和多标签稳定内存。按 `docs/features/editor.md` 更新数据流契约，必要时更新依赖补丁说明。实施任务本身必须经过相关测试和 `make build`，不推迟到 T5。

**收益门槛：** 逐项对照 T1 的原生主线程和内存数据；若某条路径并未成为可重复瓶颈则保留现有简单实现，避免额外索引／缓存导致内存更高。关闭标签后未被共享查询缓存正常拥有的内容、语法任务和视图必须释放；无收益的试验结构撤销，不长期保留 A/B 分支。

<a id="p1-t5"></a>
## P1-T5 四档代码文件的滚动条、编辑响应与资源验收

**性质：** 验收 T2 的几何、T3 的真实大文件读写、T4 的连续输入／内存改善。所有实现任务已经各自删除旧代码、补全测试和文档；本任务不集中偿还技术债，也不拿一次成功加载冒充编辑器高性能。

1. 对 **382 行真实 `FileTreeModel.swift`、1,000、10,000、100,000 行**分别新开、慢速上下滚、快滚、拖动滑块、25／50／75／100% 跳转和返回。固定行高／不软换行的配置下，`documentView.frame.height` 与 `knobProportion` 不应因滚动新区域而改变；`doubleValue` 和第一可见行随操作正确变化，反向返回无突然跳行。软换行／可变字体如需逐步精确化高度，必须保留**文本锚点的屏幕位置、滚动映射单调与末尾可达**，不得因刷新估算引发肉眼可见的大幅跳动；窗口宽度、字体或编辑改变时再更新合法范围。
2. **按键与内存**：四档文件在文首／中／末各做单字符插入、删除、连续输入、Undo／Redo；分别记录输入主线程中位／p95／最大、整文 getter/比对/索引平移次数、每次编辑分配、连续滚动 CPU，以及打开 1／5 个标签、关闭后稳定 RSS 与空闲 30 秒 CPU／唤醒。验证**普通输入不再无条件多次扫描整文，关闭后内存不持续增长，空闲无持续重绘**；Debug/Release 和软换行单列，不伪造绝对 MB 或 FPS 的跨机器承诺。
3. **语义回归**：Swift/TSX/Markdown 高亮、长行横滚、LF/CRLF、Unicode 规范等价但字节不同、折行、行号、中文 IME、Undo、Find、选区、自动保存与编辑中的并发保存、重挂载和关闭释放。十万行文件必须真正打开、编辑、撤销、保存原字节、到达文末；不能绕过容量／禁用着色假通过。共享 Diff 的固定行高、双栏同步和只读测试必须通过；没有测到争用不顺手改 Git／Files。
4. **可比较的证据**：以 T1 固定样本和同机配置比对前后滚动条／锚点、首次可见、文末可达、主线程长阻塞、稳定与峰值内存、实际呈现卡顿（能测到才报告）。必要用 Instruments Time Profiler／Allocations；工具链阻塞则记录且不声称已得到真实帧率。`FPSCounter` 的 display-link tick 不是实际正文帧率。记录文件字节数、平均／最长行、语言、刷新率、样本量和性能瓶颈是否随全文大小线性增长；既不把用户的小文件问题埋在巨型测试，也不以 100,000 行短文本取巧。
5. 运行受影响 NativeUI、`FileTabTests`、`TextCoordinateIndexTests`、`SyntaxHighlightingTests`、`EditorTextInputTests`、`PaneRetentionTests`、共享 `DiffTabTests`，以及完整 `make test`、`make build` 和严格验签（平台补丁必要时补 Release）。T2～T4 的旧路径和文档已在各自任务处理。若高度／锚点仍跳，或十万行编辑的同步全文处理仍明显拖慢主线程，**不能只因构建和单测通过而宣布完成**；说明残余瓶颈、证据与是否需要另立 Swift 原生结构方案，不预建第二引擎。

**交付：** `evidence-p1.md` 的四档样本／字节数、滚动条与可见文字前后对照、输入 p95 与全文操作次数、峰值／关闭后内存、CPU/唤醒，以及未达标与未测项；实际进入审计时才建 `audit-p1.md`。本轮仅修订 Feature Plan，未开始产品实现、性能录制、App 重启或推送。
