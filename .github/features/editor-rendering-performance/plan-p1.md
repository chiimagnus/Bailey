# P1：查明并重构源文件编辑器的滚动热路径

**目标：** 让用户实际打开的 Swift 文件在**触摸板连续／惯性滚动**及首次进入新区时明显更流畅；先通过实际渲染与主线程证据找出重复工作，再在单一 Swift／AppKit／TextKit 所有者处重构。滚动条拖拽作为单独对照，不预先重写编辑器。

**不做：** Git Diff 读取／算法、Git 状态刷新、Files 树重写、Rust／GPUI／Rope、替换 Neon，以及新 FPS 产品埋点／第二套文字绘制引擎。[原 P5](../editor-git-performance/plan-p5.md)继续独立进行；共享 STTextView 修改只在确认没有并行改动冲突后进行，并同时验证 Diff 消费者。

**方式：** T1 对触摸板、滚动条、首开分别取证并确定真正的主线程/绘制瓶颈；T2 只重构证实的连续滚动热路径，T3 仅在首开仍有独立瓶颈时处理；T4 按实际触摸板体验验收。新路径在**所属任务当次替换并删除旧实现**，不追加长存的缓存、重试或兼容层。临时实验保存在忽略的 `build/performance/editor-rendering/`，经验证的结论记 `evidence-p1.md`。

**现有基础已完成而非待重做：** [旧 P3 证据](../editor-git-performance/evidence-p3.md)涵盖初次解析、后台根树、增量坐标、查询缓存、嵌入片段、远距离定位。约 400 KiB Swift 输入返回中位数从 48.074 ms 降到约 0.37 ms；高亮追上约 52 ms；长文首次指定位置定位及着色约 393.6 ms、已访问反向约 52 ms。它们**不是物理触摸板的帧间隔**。不要为这次滚动再造重复解析器或将 P3 的定位修复退回。

**执行前逐项核对的代码事实（并非已经证明它们是 CPU 热点）：**
- **文件打开与标签**：`Project.openFile → PanelContentView → FileViewerView`；`FileTab.reloadFromDiskIfClean` 通过 `@concurrent` 后端读取／解码、对干净文件按字节比较；仅内容真实变化才清除原编辑器并递增 `reloadRevision`。`SourceTextEditor.makeScrollView` 在主线程依次设置字体、全文、语法插件与首帧选区／滚动恢复。`FileViewerView.onAppear`／窗口重新变为焦点会请求干净文件重新读取；需分开测**初读、重复激活与 TextKit 首次装配**，不能假定每次切换都重建。`EditorState` 被 `@ObservationIgnored` 排除，写回 clip bounds 不等于每帧 SwiftUI 更新。
- **滚动准备与收敛**：`STTextView.prepareContent(in:)` 仅向上预备约半个视口；区域改变时同步 `layoutViewport()`，`layout()` 也会发起 viewport 布局。`layoutViewport()` 允许至多 5 次收敛，以应对 `setFrameSize → prepareContent` 回入；不是可随便删的无效安全围栏。`isCompatibleWithResponsiveScrolling = false`，且 Kero／Vendor **没有自定义 `scrollWheel` 拦截**；触摸板与滚动条表现不同不等于存在错误的滚轮算法，需沿 NSScrollView/NSClipView 追踪真实布局。响应式滚动仅在 AppKit 全链契约成立后评估。
- **视口与正文**：`STTextView+NSTextViewportLayoutControllerDelegate` 已通过 `fragmentViewMap` **复用可见正文的 `STTextLayoutFragmentView`**、移除脱离的视图；并非每帧重新创建全部正文。`DidLayout` 之后依次可达 viewport `ensureLayout`、`updateContentSizeIfNeeded`、选中范围／当前行、gutter 和 plugin 回调。`updateContentSizeIfNeeded()` 又查询文末 fragment 与 `textSegmentFrame`，并可能通过 `setFrameSize` 触发新的布局；`setupTextLayoutManager` 还对 `usageBoundsForTextContainer` 做 KVO 并设置 `needsUpdateConstraints`。这些是**需要采样区分的布局反馈候选**，不预先声明必然导致卡顿。`updateSelectedRangeHighlight` 和 `updateSelectedLineHighlight` 也可能重建 NSView，不能只盯 gutter。
- **行号及交互**：`STTextView+Gutter.layoutGutterLineNumbers` 每次移除并重建可见 `STGutterLineNumberCell`，通过 `textContentManager.textElements(for:文首…viewport)` 生成段落数组后 `.count`。`STGutterView` 的 marker 定位、鼠标命中／拖拽还依赖这些 line-number cell；Kero 默认未启用 marker，**不能因此就直接删上游共享行为或预设改成单一 Canvas**。前缀枚举／NSView 分配是否占用连续滚动帧，留 T1 定量判断。
- **着色与观察**：`SyntaxHighlightCoordinator.updateViewportRange` 在 viewport 文字范围改变时才让 Neon 处理**无效且可见**区域，不会像 P7 失败的新插件一样每滚动全文 reset。新文件仍涉及正文装载、一次初始解析及共享 query 获取。`TextCoordinateIndex` 只维护 Tree-sitter 的 LF 行坐标，与 TextKit 段落／软换行不等价，不能直接转用为 gutter 索引。STTextView 还注册 `NSScrollView.didLiveScrollNotification` 取消自动补全，`resetCursorRects` 会遍历可见区链接/光标属性；仅当实际帧堆栈包含它们时才考虑优化，不因为名字在滚动链上就添加处理。现有 `kero/Support/FPSCounter.swift` 只数 `CADisplayLink` 回调，**不测文字真实合成／提交帧**，不得把界面 FPS 徽章当作完成证据。

**必须保留的真实契约：** `docs/features/editor.md` 规定的标签唯一原生对象、干净文件刷新、字节级保存保护、IME／Undo、Find 双向定位、实际高亮、只读与关闭后资源释放。`SourceTextEditor.sizeThatFits` 防止文档撑大窗口并无限布局；滚动恢复与 `setFrameSize` 收敛保护已有回归，不能因外观看似复杂就删。Vendor 的空范围高亮防崩溃、文末/水平滚动与 Diff 固定行高等修复仍有消费者（`kero/Git/DiffTextView.swift` 和 `DiffNativeSurface.swift`）。只对被本任务**真正取代、验证后无消费者**的旧实现进行即时删除；不触碰用户现有 Kero，测试限隔离实例，完成标准由根 `Makefile`／`docs/testing.md` 唯一维护。

<a id="p1-t1"></a>
## P1-T1 真实滚动与首次打开性能归因

**性质：** 执行前最小实验；没有可信热路径证据前**不重写产品渲染器**。不在产品加入诊断框架或新长期设置。

1. 固定实现前的 HEAD／相关未提交差异、Swift／Xcode 配置、实际屏幕刷新率、窗口、用户字号、默认**不折行**及语言。**先选用户能复现卡顿的一份真实 Swift 文件**，再以约 400 KiB Swift 和按需接近 5 MiB 的合成样本判断文件规模影响；避免只测巨型文件漏掉普通 Swift 文件。记录 Debug／Release 差别、首开与重新切回、首次进入新区和已布局区域反向滚动。
2. 用同一个文件分别复现 **物理触摸板连续／惯性滚动**与**拖动右侧滚动条**；固定方向、区域和观察窗口，实际手势重复若干次并保存代表性最差卡顿。真实画面/帧 hitches 与主线程长阻塞要分别记录；只在需要比较具体热函数时跑 30 次微基准（中位/p95/最差）。不能用 `scrollRangeToVisible`、合成 wheel 事件或 P3 的首次着色等待代替物理手势；没有可控物理输入时记录人工操作步骤及未测边界。
3. 优先用 Instruments 的 Time Profiler 和 Animation Hitches；若仍无法录制（此前 Xcode Beta 的 DTServiceHub/AMFI 曾阻塞），保留失败事实，用系统 `sample` 和仅限隔离测试的计时判断主线程卡在哪。按样本逐项核对 `prepareContent/layoutViewport`、文末 `updateContentSizeIfNeeded`、`usageBounds` KVO→约束更新、gutter 段落前缀与 view 重建、选区/当前行高亮、新 fragment 绘制和 Neon 请求；只有观察到堆栈命中才扩至实时滚动通知或光标区域重建。用 Allocations 仅在分配明显时补查。**`FPSBadge` 的 display-link tick 不是 App 实际内容呈现帧**；没有画面／帧证据时只能报告 CPU 和运行时热点，不能宣称达到流畅帧率。
4. 在隔离 NativeUI 或只用于实验的配置中，优先单变量对照**行号开/关、高亮开/关**。文件首次挂载进一步区分后端读/字节比较、主线程 `textView.text` 安装、第一次 viewport layout、初始 Query/Neon 和颜色完成；如果这些阶段的开销不影响实际手势，不扩大到其它子系统。Zed 的可见行策略作源码参照；**检查时 `/Applications/Zed.app` 不存在**，如未配备可对比的 Zed 版本，就不把“同机 Zed A/B”当作本阶段必跑项。
5. 在 `evidence-p1.md` 记录两种滚动方式的可比条件、主线程调用栈、对应画面/帧证据（如可得）、被排除的猜测、首次打开各阶段和**具体该修改的唯一 owner**。`build/performance/editor-rendering/` 仅存隔离样本与临时诊断，保留必要可复核依据，不创建新的 Xcode test target、永久脚本或产品级 signpost 状态。

**门槛：** 至少在具体原生调用路径或 A/B 中观察到可复核的额外工作，并与用户感到的卡顿关联，才进入相应的 T2/T3；未验证的假设不进入生产代码。若真实帧录制被系统阻塞，可据可重复的主线程热点做有限的优化实验，但**不能报物理触摸板帧率或整项体验已解决**。

<a id="p1-t2"></a>
## P1-T2 重构已证实的连续滚动主线程热路径

**性质：** 仅修 T1 证实的连续滚动热点；无需在 T1 之前决定重写行号、视口还是正文。相互独立的瓶颈分开做原子改动，同一共享根因只保留一份实现。

1. **入口与责任**：以 T1 的证据选择实际最窄共有代码：`STTextView+Gutter.layoutGutterLineNumbers`、`STTextView.prepareContent/layoutViewport/updateContentSizeIfNeeded`、viewport delegate、`STTextView.updateSelectedRangeHighlight/updateSelectedLineHighlight`、usageBounds KVO/尺寸约束反馈，或确实命中的 `SourceTextEditor.Coordinator.attach`。分别核对首次进入/返回已访问区域、连续小步滚动/大步拖动。已有 `fragmentViewMap` 复用可见正文，先检查误失效／重入；**不要再实现第二个正文 fragment 缓存**。
2. **行号命中时**：先消除每次视口更新产生的文首至 viewport 段落数组和无效 `STGutterLineNumberCell` 销毁/重建。需要绝对行号时优先已有 TextKit 内容位置能力和真实 paragraph 语义；不能不经验证复用只按 LF 计数的 `TextCoordinateIndex`，也不能先添加第二套全文索引。只在分配热点证明必要时复用可见行号单元；保持 `STGutterCalculations` 的文本行框、换行语义和 `STGutterView` marker 命中/位置契约（虽然 Kero 未启用 marker）。不预设新绘制画布、CoreText 行号引擎或额外永久缓存。
3. **视口/选择热点命中时**：减少一次连续手势引出的重复 `layoutViewport`、文末 `ensureLayout`／`enumerateTextSegments`、无变化的 frame/尺寸回写、旧/新可见 fragment 反复失效以及选区／当前行 NSView 重建。保持无换行水平范围、文末、空文件及 Diff 固定高度正确；区分真实必要的 TextKit 估算与多余的同帧强制排版。`prepareContent` 当前只向上扩大半屏，若实际下滑最卡，再按采样做有界双向预布局实验，不靠全文同步排版。仅当 AppKit 官方响应式滚动的完整准备/线程契约可证明成立才评估开启，不能直接翻 `false` 或对主线程 UI 做未经支持的后台读写。
4. **同 task 清理与验收**：先补能复现 T1 热点或正确性边界的最小原生测试，保留换行（特别 CRLF／软换行）、字体、可见行号、当前行与长行水平滚动等受影响结果。新算法接入后**立即删除被替代的前缀枚举、视图重建、重复尺寸计算或无消费者 helper**，不留旧/新并跑、兼容 fallback 和诊断开关；但 `sizeThatFits` 防窗口死循环、`layoutViewport` 收敛／递归保护、IME／高亮防崩溃、保存身份与 Diff 行高等存在真实消费者的机制不能当成“多余安全围栏”删除。同步 `docs/development.md`、`docs/features/editor.md`，真正改变 Diff 契约时同步 `docs/features/diff.md` 与旧 P5 接口说明；保留 Vendor 版权与补丁来源。
5. **验证按改动影响选择**现有 `EditorNavigationTests`、`FileTabTests`、`EditorTextInputTests`、`SyntaxHighlightingTests`、`PaneRetentionTests`；改 STTextView 共享路径时必须覆盖 `DiffTabTests` 的双栏、水平/垂直滚动及 fixed-row。筛选示例为 `make test ONLY_TESTING=KeroTests/EditorNavigationTests`（测试类名，不是文件夹），其余参照 `docs/testing.md`。相同样本 A/B 对照主要热点、内存分配和真实触摸板卡顿，**无稳定净收益就撤回未采用的实现**。每个实现任务 Red/Green 后做完整相关回归、`make build` 和原子提交，不等 T4 才清理旧代码。

**决策边界：** 如果消除已证实的重复工作后仍无法满足体验目标，先在证据中写清**哪个 TextKit/AppKit 约束不可优化、为何现有 fragment 复用不足**。只有确有不可跨越的瓶颈才评估独立的 Swift 原生绘制方案；不能仅因 Zed 使用另一渲染架构就在本任务新造 CoreText/Metal 或第二套输入、Find、Undo 系统。

<a id="p1-t3"></a>
## P1-T3 收敛新文件首屏与首次跨区域高亮工作

**性质：** T1 证明首次打开与连续滚动**存在不同根因**时才实施。如果已由 T2 的共享滚动布局修复解决，则只做验证并在证据注明无需新代码。

1. 沿真实 `Project.openFile → FileViewerView.onAppear/refreshWhenSelected → FileTab.reloadFromDiskIfClean → SourceTextEditor.makeScrollView/makeNSView → textView.text → addPlugin → SyntaxHighlightCoordinator.init/installTokenProvider → didLayoutViewport` 分开观察：后台读/解码、干净文本在主线程的字节比较、首次编辑器装配、正文第一次实际可见、第一帧可操作、首次正确颜色。**`onAppear`、App/window 重新激活会发起重读，但同字节内容通过 `matches` 不重建；不能先假定“每次切标签必全文安装”**。
2. 只在阶段计时证明确有瓶颈时处理该 owner：如果耗时在重读/比较，修 `FileTab` 的必要读写边界；如果在 `textView.text` 全文安装、首次布局或视口着色，修 `SourceTextEditor`／STTextView／现有 SyntaxHighlightCoordinator 的真实重复工作。字体在全文赋值前安装、原有共享 Query 编译及后台 parser 已完成，不得重做。重载／编辑的 `reloadRevision`、`contentRevision` 和文件目标校验保障数据安全，不能因简化而跳过；已经取消或过期的结果不能覆盖新内容。
3. 不以“正文先显示空白、暂时禁用高亮、永远只显示旧色”换首屏数字；要比较真实 Swift／TSX／Markdown 首可见内容及最终颜色。仅在观察到旧安装/重复着色路径被取代后**当次删除旧路径和无消费者分支**，不额外加另一个激活监听器、预热任务或 parser 状态；保护原字节、IME、Undo、Find、重挂载后选区／滚动和窗口 Dock，更新 `docs/features/editor.md`（依赖或补丁变化才更 `docs/development.md`）。

**验证：** 依命中路径运行 `FileTabTests`、`SyntaxHighlightingTests`、`HighlightQueryCacheTests`、`EditorTextInputTests`／`PaneRetentionTests` 中受影响者；若修改共享 TextKit，再加 `DiffTabTests`。按同条件独立首开/重复切回对照**字节/颜色/可编辑/真实画面**，有限冷开样本记录中位与最差，不将后台任务返回当作首屏完成。采用代码仍需当 task 构建、测试并同步文档。

<a id="p1-t4"></a>
## P1-T4 真实用户路径验收与必要的下一层设计决策

**性质：** 对已采用的改动做最终体验验收；前面每个任务已经完成各自的功能测试、代码清理和文档同步，**这里不集中偿还遗漏事项**。

1. 用 T1 同一真实 Swift 文件、同窗口与设置，复现**触摸板连续/惯性下滑和反向、滚动条拖动、新开及切回**；记录可获得的实际呈现/帧间隔、hitches、主线程长阻塞、正文与颜色、稳定内存及剩余卡顿。`FPSBadge` 的 CADisplayLink 次数不作为帧证据；不能把 Debug 与 Release 或合成 wheel 输入的结果混合。若本机有 Zed 才做同条件对照，**没有 Zed 也必须验收 Kero 自己的前后差异**。
2. 仅当 T1 样本出现 Git／Files 同线程竞争，再用开／关面板的单变量场景确认；已有 P4 文件树异步扫描和 Git 状态预聚合不重做。如果争用根因属于独立旧 Feature，将其记录并交回原所有者处理，不在本 Feature 顺带修改 Git/Files。没有此现象就跳过额外对照矩阵。
3. 对本轮实际受影响的编辑器、IME、查找、行号、字节保存、窗口/标签重挂载及共享 Diff 运行原生回归，完成后 `make test`、`make build`、严格验签；必要的 Vendor/平台覆盖变更再 `make build:release`。已有测试通过不等于实际触摸板不卡，人工原生画面／焦点／保存和关闭资源需按 `docs/testing.md` 的适用项核验，隔离 App 不改用户设置、进程或项目。
4. 已证实体验改善则记录量化结果、误差与残余限制；如果仍卡顿，记录是 **尚未归因、未能取帧，还是明确的 TextKit 限制**。只有获得可靠证据后再决定是否需要新的 Swift 原生架构计划，**本阶段不预创替代渲染器任务或保留双轨引擎**。功能代码在 T2/T3 实施当次即完成旧路径删除、文档及原子提交；本任务仅综合验收，不把任务勾选当作成功。

**交付：** `evidence-p1.md` 中的前后证据、采用/否决原因、未测范围；进入执行审计时才创建 `audit-p1.md`，不在编写计划时预设审计结论。当前任务仅执行前审查，**未开始实现或性能录制**；不启动/退出用户正在使用的 Kero，不推送或发布。
