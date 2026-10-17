# P1 执行证据

## 环境与边界

2026-10-17，M1 Pro（10 核、32 GiB），macOS 27.2 (26B5101f)，Xcode 27.2 (27B5038j)，arm64／Swift 6。内置 3024×1964 Retina，原生窗口 backing scale 2。仅创建隔离 XCTest 窗口，没有触碰运行中的正式 Bailey。

使用独立 `build/DerivedData-editor-rendering`；坐标索引基线另用 `build/DerivedData-editor-index`，不覆盖其它任务产物。日志和 Instruments 产物均在 `build/performance/editor-rendering/`。RTK 对较大构建日志存在 1 MiB 截断，因此后续关键测量改用原生 `make` 重定向，仍使用同一个根 Makefile。

第一次编译因同时存在的无关测试引用 `remoteLaunchDirectory` 失败，随后工作区原有改动消失，未由本任务修改；重跑编译成功。另一次探针未等待真实 viewport（高度为 0），其几何数字作废；修正夹具后确认 viewport 为 900×600。第一次长探针遭 SIGTERM，不能当通过；有效 Source 探针完整退出 0。

## T1：修改前的发现

- 裸 STTextView、系统等宽 13、相同行长 ASCII：382／1k／10k／100k 连续正反向未知区域高度均稳定，100k 为 1,600,016 pt。证明不能把所有 TextKit 延迟布局当同一个失败。
- JetBrains Mono 13、1k 行变长 ASCII（含空行、不换行）：高度序列 `20415, 14070.5, 21942, 16983, 17000, 17000, 17000, 17000, 17000`。新回归原实现确实 Red：1 pt 容差失败。字号和实际内容没有变化，不是用户编辑导致的尺寸变化。
- 固定 Git 对象导出的历史 382 行样本也复现：`6308.5, 5957.5, 5877, 6368, 6511, 6511.5, …`；当前 FileTreeModel 为 `7453.5, 8815.5, 7259, 7909.5, 7344, …`。临时原生探针在滚动记录之后才做全文排版 oracle，分别获得 382／431 个 fragment，高度 17 pt（末尾带 extra line 的 fragment 为 34 pt）；生产路径没有全文排版。探针依赖本机导出文件，记录原始 `t1-historical-oracle.log` 后从提交中删除，避免 CI 依赖未入库样本。
- 真实 Source 桥接、JetBrains Mono 13、900×600、变长代码／中文／emoji：382 行无软换行高度 `6953 → 6190.5 → 6349.5 → 6218 → 6494`；10k 为 `186085.5 → 162649 → 197043 → 190106.5 → 170000 → …`。折行同样存在明显估算修正，不能用固定外框冒充文字坐标正确。
- Source 100k 样本 3,577,717 UTF-8 字节，尚未超过旧容量，不能证明新容量。无高亮 `.txt` 对照每位置 30 次插入／删除对：文首 median/p95/max `656.43/669.32/669.46 ms`，中部 `568.27/576.63/582.74 ms`，文末 `477.46/487.42/491.09 ms`；折行为 `645.76/718.18/725.25`、`593.37/617.03/625.35`、`501.37/506.97/507.23 ms`。这是 Debug、成对回到干净基线、原生变更调用耗时，不是键盘呈现延迟或 Release 指标。主线程 sample 的几乎全部普通输入样本在 `FileTab.refreshDirtyState → UTF8View.elementsEqual`，不支持先迁移正文所有权或 parser 快照架构。
- 同一探针不 yield 的长循环累积大量 autorelease 文本对象，结束时 sample 落在 `NSTextRange/NSTextParagraph` 销毁，RSS 曾达约 5 GiB；补充逐次 yield 后量级下降。因此该数字不是已证明的长期泄漏。已经保留 5 秒 Allocations trace，不能把调用次数当分配字节。
- 坐标索引 382／1k／10k／100k × 三位置 × 30 次插删对、原有 parser/direct-scan 两个 oracle 测试通过，整个成本测试约 1.03 s。尚无证据要求先引入分段树；T4 再用完整输入前后结果决定。

命令与原始结果：`t1-geometry-rerun.log`／RTK 对应完整 tee（1 test, 0 failures）；`t1-variable.log`（1 test, 1 failure，精确几何 Red）；`t1-variable-baseline.log`（几何记录／字节对照，1 test, 0 failures）；`t1-source-mounted.log`（1 test, 0 failures，151.69 s）；`t1-baseline-default.log`（四档 Source＋已有导航基线，4 tests, 0 failures／0 skipped，138.52 s，完整 make 退出 0）；`t1-index.log` 对应 xcresult（3 tests, 0 failures／0 skipped）；`t1-input.sample.txt`、`t1-mounted.sample.txt`、`t1-allocations.trace`。

## 修改前固定的判断条件

- 几何容差 1 pt（2× 屏幕两个物理像素）；固定行高的变长行不能靠滚动逐渐收敛才满足；真实目标、字符命中和最终内容必须同时正确。
- 不接入每屏全文 ensureLayout、第二个 AppKit 后台排版器或没有测量收益的正文架构。先处理布局反馈／锚点与已测判脏热点；不能以丢高亮、撤销或容量只读换速度。
- 普通单字符输入目标以 16 ms median／32 ms p95 为本机优化构建比较预算；相等确认、初读、保存快照、解析完成与呈现单列，不能把 Debug 成对操作直接当成已达到此预算。
- 100k 单标签资源试验不人为制造 OOM；先以 1 GiB footprint／五标签 3 GiB 为有界实验停止线，越线保留结果并查对象归属，不直接扩大 FileTab 容量。它是本机实验停止线，不是跨机器性能承诺。

## T2：几何与恢复

- 失败候选分别撤回：只删除文末重定位仍会变高；只固定 frame 不修文字坐标会令远处命中错误；`adjustViewport` 不会立即把既有 fragment 移到逻辑 Y。最终用原生行起点、可见片段实测行高，以及内容／选区／gutter 的统一 NSView 坐标转换；不强制字体、段落样式或全文布局。行高确实可变、软换行、Diff 不走固定高度。
- 变长 ASCII／空行的真实屏幕矩形、反向字符命中、行号和 marker 已通过；四档无折行 Source 高度分别稳定为 6494／17000／170000／1700000 pt。所有可选字体（13 pt）及当前 JetBrains Mono 18 pt 均保留自然行高并通过正反向滚动；Monaco／Spot Mono 的非整数自然行高未被取整替换。详见 `t2-fonts-and-scroll.log`。
- 864 组字号、字体、折行、scroller、窗口宽度、空文本／非 LF／Unicode／长行、明暗外观配置通过，近零宽度回到正常宽度仍能到达文首末。真 Source 的初次保存位置恢复、三种宽高 live resize、32→8→13 字号变化验证同一对象与真实文字位置。
- 新回归分别揭示并修复：初次安装文字后的异步 caret-follow 把保存位置 5000 归零；混合字号 Undo 后仍使用“可变高度”旧派生状态；卸载改字体后像素恢复使文字偏移变成 7642／−2060 pt。原生变更维护行边界／锚点，内容替换清空派生状态，字体变化与真实 detach 捕获文字位置，重新挂载前不消费锚点。删掉 Source 的 `detachedScrollOrigin`、重复恢复闭包与 focus 后像素重放；正常输入跟随插入点仍保留。`t2-remount-red.log` 两条失败，`t2-remount-green.log` 同一路径与 PaneRetention 13 tests 通过，完整 make 退出 0。
- 删除尺寸 API 的无消费者 deprecated 别名、Common 对应要求、`typingLineHeight`、旧 frame 截断 relocate helper 和 didLayout 到底重定位。Source 的 tile／clamp／live resize 仍在负责真实 scroller 收敛，未无证据删除。
- 首轮完整含 Windows 验证为 414 tests、0 failures、0 skipped，make 退出 0，见 `t2-full-test.log`。此后新增字体／Undo／remount 回归又发现上面的缺陷，故该绿色结果不是最终提交验证。第二轮完整验证与 Debug／Release 构建继续执行。
- 100k 文末小步滚动 Debug 测得 median/p95/max 49.37／300.60／918.37 ms（382 行 20.08／21.85／23.11 ms）；2 秒 sample 中主线程 504/540 采样在测试操作，gutter 的全文前缀 `textElementsForRange` 占主要增量，footprint 232.6 MiB、峰值 272.1 MiB。不是实际手势帧率。已将段落序号作为同一个原生行索引的元数据，替换 Source 每屏前缀数组；LS 不计新段落、CRLF 不重复。索引／真实 TextKit 段落 oracle 和滚动复测尚待完成，不预先声明优化收益。不另造 cell 池或第二份正文。
- 共享 `build/SourcePackages/workspace-state.json` 指向旧 kero 路径，未修改用户共享缓存；后续命令统一显式 `SOURCE_PACKAGES=build/SourcePackages-editor-rendering`，独立解析后正常编译。

## T3：容量、完整编辑与 SSH 传输（已完成）

- 真实 100,000 行 Swift 样本超过旧 5 MiB，当前在 8 MiB 内，已验证加载、原生可视定位、追加、Undo/Redo、磁盘字节，见 `t3-native-100k-edit.log`。
- FileTab 候选容量 8 MiB；本机 N−1／N／N+1、UTF-8 边界、多字节、嵌入 NUL、图片回落、缺失和恢复通过。`p1-filetab-current.log`：40/40。Diff 原 5 MiB 限制不变。
- 远端命令边界测试涵盖 0／N−1／N／N+1、引号与中文路径、stdin 二进制字节、原子写、缺失、非零退出。`p1-stdin-short-write-green.log`：16/16。
- Windows 专用 SSH 首次测试遭 SIGPIPE；随后无压缩的大文件读取超时。启用标准 SSH 压缩后，`p1-windows-compressed-live.log` 验证 8 MiB 双向读取、保存重读、越界和二进制；1/1 通过，45.328 秒。再次以产品默认 25 秒逐命令时限执行 `p1-windows-product-timeout-live.log`，1/1 通过，50.461 秒；未动用户 master。
- 子进程提前关闭 stdin 时，原实现会发出 SIGPIPE，或即使未消费完整字节也返回成功。新增零退出与非零退出 Red，修复为核对实际写入是否完成，见 `p1-stdin-short-write-red.log`（2 failures）与 `p1-stdin-short-write-green.log`（16/16）。

## T4：增量编辑、精确判脏与原生热路径（进行中）

- 原生输入后不再无条件提取整篇正文；改用带范围的编辑事件更新判脏依据，保存、外部读取和无法证实相等时仍执行精确字节比较。
- `p1-detached-append-red.log` 证明暂时卸载后追加只更新临时正文，导致原生 Undo 与重新显示不同步。改为向长期 coordinator 保留的同一个原生文档追加，`p1-detached-append-green.log` 通过。
- 规范等价 Unicode、同频次重排、Undo 和在途保存后修改已补回归；`FileTabTests` 40/40，`SyntaxHighlightingTests` 20/20。
- `t4-incremental-100k.sample.txt` 主线程采样确认 TextKit 2 的缓存段落位置更新仍是瓶颈。`t4-inverse-edit-benchmark.log` 100k Debug 文首插入／删除对 median 718.82 ms（不折行）／490.76 ms（折行），中部 354.64／248.51 ms，文末 0.42／0.20 ms。未达优化构建单次输入预算 16/32 ms；不能把成对 Debug 耗时当作 Release 单次输入。
- 旧 deprecated 包装与五个固定有效字符转换围栏已删除；完整回归、Release 构建和验签现已通过。资源峰值／多标签回收、真实图形操作及 T4 性能门槛尚待核销。

## 当前完整回归与构建记录

- `p1-full-current-test.log`：2026-10-18 全部 **425/425 XCTest，0 failures，0 unexpected，完整 `make test` exit 0**，耗时 892.494 秒。包含授权真实 Windows Git/文件树/8 MiB FileTab/恢复、EditorNavigation、EditorTextInput、SyntaxHighlighting、Git Ignore、Diff、PaneRetention、关闭保护及 WorkspaceIdentity；没有用单项成功冒充全量。
- `p1-debug-current-build.log`、`p1-release-current-build.log`：首轮 Debug／标准 Release 构建和严格验签已通过。最终含 T3 管道期限修复与 T4 代码的 `p1-final-debug-build.log`、`p1-final-release-build.log` 也均 `BUILD SUCCEEDED`、`codesign --verify --deep --strict` 成功。已构建及验签，尚未安装到 `/Applications`、没有重启用户运行中的 Bailey。

## 补充边界与优化构建实测

- T3 后续独立提交 `237f91e`：本机与 SSH stdin 写线程改为带期限的非阻塞 `poll`，修复父进程退出、后代继续持有读取管道引发无限等待。`p1-writer-deadline-green.log` 17/17；`p1-nonblocking-writer-windows-live.log` 专用 Windows 8 MiB 全链路 1/1，37.654 秒。主提交 `171cd1b` 保持 T3，后续提交没有混入 T4 或本地计划。
- Debug 与标准 Release `make build`、`make build:release`、严格 `codesign` 均通过：`p1-debug-current-build.log`、`p1-release-current-build.log`。完整本机/Windows `make test` 是 `p1-full-current-test.log` 425/425，无意外失败。
- Release 常规测试构建因 `Bailey` 和 `STTextViewAppKit` 关闭 `-enable-testing` 被 `@testable import` 拒绝；这是预期配置限制而非产品编译失败。使用仅用于测量的 `ENABLE_TESTABILITY=YES` 命令行覆盖成功运行单个 Release XCTest；正式签名 Release 维持原编译设置。
- `p1-release-testable-input.log`：100k 行，在优化编译下，单次插入 median／p95（毫秒）：不折行文首 329.78/375.36、中部 173.73/182.42、文末 0.295/0.383；折行文首 233.21/242.38、中部 117.26/121.03、文末 0.097/0.169。原生缓存段落位置批量更新阻断 16/32 ms 目标。T4 不得标为 completed；需要单独评估可控缓存的 TextKit2 content manager 替换成本与完整兼容性，不在现有热路径叠加不必要的防护。

## T4：视口导航引发的段落缓存扩张（2026-10-18，尚未解决）

- **最终已提交代码的全量门槛已通过**：`p1-final-full-test.log` 426/426 XCTest、0 失败、整个 `make test` 退出 0，包含 Windows SSH 的 Git、文件树、断线恢复；`p1-final-debug-build.log`／`p1-final-release-build.log` 均成功并完成严格 codesign 验签。但这些功能测试不代表 T4 的输入性能或完整 App E2E 达标。
- **同文档冷／热导航对照**：`t4-cache-cold-vs-navigated.log`（1 XCTest，0 失败；100k 行、30 次小插入）。Debug、未浏览其他区域时文首单次插入 median/p95：不折行 10.16/10.71 ms，折行 10.54/10.89 ms；跳转多个远处区域后变成 358.18/370.39 ms 与 292.38/316.47 ms。同一个文本、字体、编辑位置，仅改变已访问范围。
- **逐步跨越区域**：`t4-cache-depth-and-zero-delta.log`（1 XCTest，0 失败）：到 0／25／50／75／100% 后文首单插入 Debug median 10.43／92.16／170.78／289.07／340.36 ms；全文浏览后等长替换仍需 52.07 ms，显式 `textLayoutManager.invalidateLayout(for: documentRange)` 后仍需 349.96 ms。单纯清布局不是解决办法。
- **区分定位与布局入口**：`t4-cache-entrypoint-probe.log`（1 XCTest，0 失败）：只取半程 `NSTextLocation` 或对单一远处 `NSTextRange` 请求 `ensureLayout` 后，文首插入约 10.5 ms；执行 `relocateViewport`／滚动到中部后分别约 130.82／172–180 ms。不能笼统把 Unicode／行号索引或远程文件读取归咎于此。
- **原生段落生成请求证据**：`t4-paragraph-delegate-count.log`（1 XCTest，0 失败）：仅观察 `NSTextContentStorageDelegate.textParagraphWithRange` 调用并返回 nil（保持系统默认实现），跳到 25／50／75／100% 后请求数分别 24,992／49,982／74,974／99,963。它计数的是**创建请求**，不能直接等同当下活跃缓存对象数，但结合 `t4-incremental-100k.sample.txt` 内 `NSTextContentStorage.processEditingForTextStorage → EnumerateCachedElements → updateRangesForTextElement`，确认已跨越范围的段落枚举与编辑成本随深度增长。
- **系统原生 NSTexView 对照无法完成**：`t4-system-nstextview-textkit2-oracle.log` 在尚未导航的 TextKit 2 系统控件中测得约 409 ms，但隔离测试宿主 RSS 增至 1,176,320 KiB，超过本计划 1 GiB 实验停止线；主动仅终止该隔离 XCTest，结果为 **中止／不可比较**，不得写成 AppKit 原生性能结论、不得并入正常回归。
- **上游与 API 边界**：Apple 官方 `NSTextContentStorage` 负责段落对象映射，`NSTextContentManager` 允许通过自己的位置和存储实现自定义 provider（<https://developer.apple.com/documentation/appkit/nstextcontentstorage>）。STTextView 上游维护者在 <https://github.com/krzyzanowskim/STTextView/discussions/79> 明确指出当前 `STTextContentStorage` 依赖 `NSTextStorage`，自定义 manager 并非现成开关。当前 Vendor 的 `STTextView.swift` 编辑／字体／属性与 `STTextView+NSTextInputClient.swift` 使用 `NSTextContentStorage` 强转；`SourceTextEditor.swift`、`STTextView+LineGeometry.swift`、Find／Accessibility／Diff 也依赖同一契约。不应在热路径临时重置 storage 或取消 Undo、语法、远距导航。
- **现成方案的真实适配边界**：已核对 CodeEditTextView 上游 `TextView.swift`、`TextView+NSTextInput.swift`、`CEUndoManager.swift`（<https://github.com/CodeEditApp/CodeEditTextView>）。它具备 macOS 自研行布局、`NSTextInputClient`、marked text、原生选择及 Undo 实现，但官方明确**不保证 NSTextView 功能完全等价**；Bailey 的中文候选、复合输入撤销、双向字形、Find、AX、编辑历史还需要逐项实机验收。Runestone 的增量行存储以 iOS 为主，仅作数据结构参考（<https://github.com/simonbs/Runestone>）。
- **自定义 provider 的首要阻断风险**：本机 SDK 的 `NSTextParagraph.paragraphSeparatorRange` 为只读；公开的自定义 `NSTextContentManager` 示例在末尾换行的额外视觉行上曾遇到必须依赖私有 `NSCountableTextRange`／KVC 的问题（<https://stackoverflow.com/questions/77569002/new-lines-not-generating-a-textlinefragment-when-using-a-custom-nstextcontentman>）。正式路线只允许公开 API，先通过末尾 LF/CRLF、空尾行与 caret oracle，再讨论性能。
- **接下来的受限验证**：仅在测试环境评估公开 API 的按需段落 provider 能否保持 100k 行文首→文末定位及末尾空行原生行为；若不成立则按验收矩阵比较成熟 macOS 行布局内核，不自行移植未经验证的缓存协议。后续必须核对创建／持有段落数量、真实按键／Undo、IME、Find、选区、滚动锚点、UTF-16、长行／换行、资源与 16 ms median／32 ms p95，之后才考虑移植。**未修改正式编辑器代码；T4 in_progress、T5 pending**。

## 当前外部条件

| 条件 | 事实、替代证据与补验 |
| --- | --- |
| macOS 15.6 | 本机没有该运行时；当前 SDK 构建不证明最低系统的 TextKit 行为。必须分别报告，不伪造运行通过。 |
| CI macOS 26／Xcode 26.6 | 未触发远端 CI；只在当前机器运行。不能冒充 CI 验收。 |
| 1×／其它刷新率屏幕 | 当前只有内置 2× 屏幕；不能用坐标缩放冒充硬件。 |
| 真实 SSH | 用户已授权 windows 专用临时目录／socket；后续只使用新建的测试资源，不借用用户 master。未获其它 POSIX 专用主机授权，不擅自连接。 |
| 完整 App UI／录屏 | 已获用户授权隔离前台会话；最新 `peekaboo permissions status --no-remote` 的 Screen Recording 已允许，Accessibility／Event Synthesizing 仍未允许。原生窗口测试不能代替真实手势和完整 App 录屏；权限缺口不阻止其它已授权验证。 |
| OOM／断网／用户系统偏好 | 不主动破坏真实环境；容量与受控超时／失败用现有测试 seam 验证，物理资源耗尽和真实用户网络中断单独保留缺口。 |

以上尚不是阶段验收结论；T2–T5 继续逐项记录实现、删除项、实际结果和未覆盖项。
