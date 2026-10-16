# P1：查明并重构源文件编辑器的滚动热路径

**目标：** 使新开 Swift 文件和触摸板连续／惯性滚动在真实 App 中明显更流畅，定位并消除每帧不必要的主线程工作；Swift/AppKit/TextKit 继续为主架构，必要时升级共享渲染责任，但不预先重写整个编辑器。

**不做：** Git Diff 读取／算法、Git 状态刷新、Files 树功能重写、Rust／GPUI／Rope、替换 Neon。旧 [P5](../editor-git-performance/plan-p5.md) 独立进行；若共用 STTextView 补丁改变，验证其 Diff 消费者并同步相应维护文档。

**方式：** T1 先拿到触摸板真实滚动与滚动条拖动的差异、采样栈和新文件首开阶段耗时；后续改造仅落在 T1 命中的代码所有者。若行号和视口成本同时成立，在同一原生布局责任链收敛，而不是每个回调贴一个缓存／节流。T4 对真实帧、可见内容和编辑正确性统一验收；不能仅靠单项微基准。所有实验归被忽略的 `build/performance/editor-rendering/`，结论记 `evidence-p1.md`。

**现有基础已完成而非待重做：** [旧 P3 证据](../editor-git-performance/evidence-p3.md)涵盖初次解析、后台根树、增量坐标、查询缓存、嵌入片段、远距离定位。约 400 KiB Swift 输入返回中位数从 48.074 ms 降到约 0.37 ms；高亮追上约 52 ms；长文首次指定位置定位及着色约 393.6 ms、已访问反向约 52 ms。它们**不是物理触摸板的帧间隔**。不要为这次滚动再造重复解析器或将 P3 的定位修复退回。

**已证实的候选热路径，仍须测占比：**
- `kero/Editor/FileViewerView.swift`：`FileTab.reloadFromDiskIfClean` 后台读／解码，以 `reloadRevision` 区分新的正文；`SourceTextEditor.swift` 的 `makeScrollView` 设置全文、语法插件及状态恢复。滚动写回的 `FileTab.editorState` 被 `@ObservationIgnored` 修饰，**不能假设它导致 SwiftUI 每帧刷新**。
- `Vendor/STTextView/Sources/STTextViewAppKit/STTextView.swift`：`prepareContent(in:) → layoutViewport()` 在可见准备区域变化时同步布局；`isCompatibleWithResponsiveScrolling = false`。响应式滚动不是改成 `true` 就能安全启动的开关，须验证 AppKit 整条视图链及内容准备契约。
- `Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextViewportLayoutControllerDelegate.swift`：`DidLayout` 内可达 viewport `ensureLayout`、`updateContentSizeIfNeeded`、选区／行号及高亮插件；`updateContentSizeIfNeeded` 请求文档尾端尺寸。是否对连续手势重复执行昂贵布局须用现场样本说明。
- `Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Gutter.swift`：`layoutGutterLineNumbers` 从文首枚举到 viewport 再 `.count`，并移除／重新建立行号 `NSView`；这是存在的重复工作，**还没有证明它就是触摸板卡顿的唯一根因**。
- `kero/Editor/SyntaxHighlightPlugin.swift`：`didLayoutViewport → updateViewportRange → Neon.Highlighter.visibleContentDidChange` 仅在 viewport 范围改变时通知现有高亮；与官方新插件“每滚动全文 reset”不相同。`TextCoordinateIndex` 的 LF 行起点是 Tree-sitter 坐标，未经 TextKit 段落／折行等价检验不得作为行号真源。

**禁止回归：** `docs/features/editor.md` 的单标签唯一原生对象、真实字节保存、IME／Undo、Find 双向定位、ReadOnly、实际着色和关闭后释放；STTextView 补丁也服务 `kero/Git/DiffTextView.swift` 和 `DiffNativeSurface.swift`。不碰用户在用的 Kero；测试只用隔离实例，所有开发入口归仓库根 `Makefile` 和 `docs/testing.md`。

<a id="p1-t1"></a>
## P1-T1 真实滚动与首次打开性能归因

**类型：** 必要的本地实验，没有性能证据之前**不修改正式渲染器**。

1. 固定当前 HEAD／未提交差异、Mac 及屏幕刷新率、Xcode、真实 Swift 文件与 400 KiB／接近 5 MiB 合成 Swift、13pt 字体、窗口、折行及语法。比较首次打开、重复切回、首次与已访问区域、文首／文中／文末。
2. **分开测试物理触摸板连续／惯性上下滚动和拖动右侧滚动条**，记录帧间隔／hitch、屏幕实际更新、主线程时间；相同区域、同机前后可比较。每个实际手势场景重复至少 5 组，热单一函数对照每侧 30 次并报中位／p95／最差。合成 `scrollWheel`／`scrollRangeToVisible` 只能测机制，不可冒充物理手势 E2E。
3. 先用 Instruments Time Profiler／Animation Hitches／Allocations 查主线程布局、行号重建及分配、`updateContentSizeIfNeeded` 文末布局、fragment view 绘制与 Neon 通知；Xcode Beta 若再遇 DTServiceHub／AMFI 阻塞则保留错误，使用 `sample`、最小临时计时和可用帧数据，**缺少帧证据则记录未测，不能声称滚动已达到目标**。
4. 在隔离 NativeUI 对照单独关闭行号、关闭高亮、无软折行、关闭其他面板，不把测试开关留在产品；比较首次屏幕真实文本可见／可滚动／最终颜色，排除 FileTab 后台 IO 与首次 TextKit 布局的混淆。参照同机 Zed 的同文件、同条件体验，说明 Debug/Release 配置差异，不引用 120 FPS 宣传值当本机数据。
5. 在 `evidence-p1.md` 列出各候选的调用栈、帧与主线程占比、最差卡顿、未测边界及**下一步该改哪个 owner**；独立进程／fixture 属于忽略的实验目录，使用后按归属清理，不建立正式基准服务。

**Gate：** 没有现场数据证明某项热路径影响触摸板滚动，则该项不得进入下列生产重构。只有明确 root-cause 候选并能同条件复现，才能实施 T2／T3；无法实测时只记录阻塞，不直接重写渲染器。

<a id="p1-t2"></a>
## P1-T2 重构已证实的连续滚动主线程热路径

**类型：** 依赖 T1 的**条件生产重构**；可一次性重组 STTextView 布局／行号唯一责任，不等于预定一定要改行号。

1. 根据 T1 归因选唯一或实际耦合的主要 owner：`STTextView+Gutter.swift` 的行号文首扫描及视图分配、`STTextView.swift` 的 `prepareContent/layoutViewport/updateContentSizeIfNeeded`、或 `STTextView+NSTextViewportLayoutControllerDelegate.swift` 的视口反馈。若 T1 判定主因是另一个已读 owner，改其真实共享路径，不在调用点各贴 debounce 或长期双缓存。
2. 对确实命中的行号热点：以真实 `NSTextLayoutFragment` 的可见段落和行框构建有界结果，避免每次从文首生成整个段落数组；实际需要绝对行号时，先证明平台 API 或一次增量索引能保持 CRLF／bare CR／Unicode／软折行与编辑同步。只有测出视图重建显著，才复用可见 `STGutterLineNumberCell` 或改成**单个可见行号绘制表面**，不能两套并存。
3. 对确实命中的 viewport 热点：由同一所有者完成必要的可见布局、有限上下预准备、文档尺寸与 fragment view 更新；避免一帧重复同步请求文末 `ensureLayout`／回写尺寸／全量重绘。对 AppKit 响应式滚动必须先通过视图链、线程和 `prepareContent` 的内容完整性约束；不盲改 `false`、不把 AppKit 渲染转到未经支持的后台线程。
4. 先以真实 native view 补失败／等价回归（深度滚动前后、换字体、空文档、长行、不换行与软折行、Unicode 与 CRLF、行号、悬停与无障碍、当前行与选区），修复在拥有共同不变量的层，**同 task 删除旧重算／旧 NSView 分配路径及无消费者 helper**，不留兼容 fallback。相关补丁归属同步 `docs/development.md`、`docs/features/editor.md`，触及 Diff 则同步 `docs/features/diff.md`。
5. `make test ONLY_TESTING=KeroTests/EditorNavigationTests`、`FileTabTests`、`EditorTextInputTests`、`SyntaxHighlightingTests`、`DiffTabTests` 及新增实际需要的 NativeUI 回归；同文件真实触摸板和滚动条前后 A/B 的帧、主线程及内存须有净收益。若测量无收益或视觉退化，撤销候选而非以测试壳冒充交付。

**边界：** 如果 TextKit 现有布局／绘制模型经证据证明不适合需求，可先在同一实验目录验证一个使用 Swift＋AppKit／CoreText／TextKit 的**可见区域表面重组**，证明与当前文本输入、Find、IME、Undo、Accessibility 和 Diff 的完整契约兼容后，再决定是否替换现有单一渲染 owner；不预建第二套长期编辑器、不迁移 Rust／GPUI、不引入 Metal UI 系统。若不能等价就保留原生 TextKit，诚实报告瓶颈。

<a id="p1-t3"></a>
## P1-T3 收敛新文件首屏与首次跨区域高亮工作

**类型：** T1 证实首开还有独立热点时实施；如果 T2 已从共同布局根因消除卡顿，只复测和记录，不重复修改。

1. 沿 `FileTab.reloadFromDiskIfClean → SourceTextEditor.makeScrollView/makeNSView → textView.text → addPlugin → SyntaxHighlightCoordinator.init/installTokenProvider → didLayoutViewport` 分段比较“正文可见”“可操作”“实际首次颜色正确”和“触摸板可流畅滚动”。已有后台读取／共享 Query 编译／增量 parser 是前提，不重新建服务或预热整个文件。
2. 仅当首次安装重复全文样式／同步解析／范围失效实测拖慢首帧时，在相同 owner 收敛一次性工作与可见区域需求；后台结果沿用 `reloadRevision`／`contentRevision`，不能覆盖编辑后内容或丢失 Markdown／HTML 注入色。首次显示纯文本不等于高亮完成，要分别记录实际颜色到达时间。
3. 保持保存字节、Unicode、中文输入、Undo、Find、重挂载后选区／滚动、窗口与 Dock 的一致；同 task 删除被替代的旧代码，文档归 `docs/features/editor.md`，依赖／本地补丁有变才更新 `docs/development.md`。

**验证：** 现有 `FileTabTests`、`SyntaxHighlightingTests`、`HighlightQueryCacheTests`、`EditorTextInputTests`、`PaneRetentionTests`，外加新开/切回真实原生文档与颜色的 A/B；首开至少 5 个独立进程样本，报中位／最差。不允许“只延后渲染而屏幕空白”换假收益。

<a id="p1-t4"></a>
## P1-T4 真实用户路径验收与必要的下一层设计决策

**类型：** 完成 T1 的可比基线后对已采用改动做综合复测；不预留一个必做的“全面换引擎”任务。

1. 在同机相同源文件、窗口和字体上，对比修改前后的触摸板连续／惯性下滑与反向、拖动滚动条、新开和重复切换；记录帧间隔、hitches、主线程最差阻塞、最终可见内容、首次颜色完成与稳定内存。需要和 Zed 比时严格注明构建模式／样本／测量口径，不能以 Debug vs Release 宣称相同帧率。
2. 分开关闭／显示 Git、Files 面板和前台 Git 刷新，检查它们是否在**同一主线程**上造成可重复的 editor hitch。P4 状态预聚合与目录扫描已经做过；没有证据就不复制 File Manager 或 Git 状态机，确有共享争用则按共同 owner 最小责任归因并与原 Feature 对接。
3. 对所有触及的原生边界跑相关 XCTest 及 `make test`、`make build`／strict codesign，Vendor／渲染公共路径大改时再跑 `make build:release`。隔离 App 的真实触摸板体验、可见行号、输入、Find、选区、Undo、保存、Diff 联动和多标签关闭后的内存不能由组件 green 替代。
4. 性能达成则记录有量纲的改善和剩余限制；若仍明显卡顿，指明帧栈／不能由 TextKit 满足的真实平台约束，确定是否需要另开更大 Swift 原生渲染 phase。**不得以任务勾选替代滚动流畅度验收**。P1 的所有代码变更各自原子提交，现有旧路径和文档在相应 task 已清理，不推迟集中清理。

**交付：** `evidence-p1.md` 的结果、采用／未采用原因、必要文档与阶段审计 `audit-p1.md`（实际进入审计时再创建）。用户当前要求只做计划，本阶段**尚未执行**；不启动／关闭用户在用的 Kero，不推送、不发布。
