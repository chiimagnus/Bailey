# P3：正确的编辑高亮与按证据减少重复工作

**目标：** 编辑后的范围和 token 版本正确；只优化实测的全文比较、坐标、调度、编译和嵌入片段热点。
**不做：** Rope／CRDT、第二套根树／队列、通用解析服务、LanguageLayer fork 或全语言预热。
**前置：** P1 基线及 P2；完成状态只读 todo.toml，不能以计划审查代替实施。
**验收：** 最终视口对应当前文本，固定资源失败不形成重编译循环；保留的优化有数据，无热点就不制造代码。

Neon 已有根解析版本、串行 queue、pending edits／范围变换。TreeSitterClient 留 MainActor，readHandler 必须持续读取稳定快照到 completion；Parser／MutableTree／QueryCursor 不因 Query／Tree 可传递就跨线程共用。测试、文档和替代路径删除都在所属 task 完成；新测试仍进一个 XCTest 目标。

<a id="p3-t1"></a>
## P3-T1 修复编辑范围与整次 token 同版交付

**类型：** 正确性实现。
**文件：** `kero/Editor/SyntaxHighlightPlugin.swift` 的 setUp、will/did、两种 provider／invalidation；只读 Neon Highlighter／TokenApplication／TreeSitterClient。扩展 `KeroTests/NativeUI/Editor/SyntaxHighlightingTests.swift`；文档归 `docs/features/editor.md`。

**已核实缺口：** 未调用 Highlighter.didChangeContent，valid/pending 不随 edit 移动；plain 的过期成功／失败、base 与 injection 两次异步查询可跨编辑版本。实际 TextKit 旧 NSTextRange 使用同文档偏移，尾删／全删和连续编辑对照 Parser 已通过，不新增无必要的旧范围缓存。

1. Red：用生产插件和可控异步交付复现在已着色文本前插入／删除、尾删、全删、base/injection 间编辑；检查最终样式位置及当前视口重请求，不只检查 invalidate 被调用。
2. will 推进编辑 revision 并通知 tsClient；did 沿用实际 TextKit 提供的旧范围偏移与 replacement UTF-16 长度，先通知 highlighter，再通知 tsClient。新快照取实际 TextKit 内容，不能依赖随后 delegate 才写回的 FileTab.text。
3. 复用一个 coordinator 编辑 revision 保护整次交付：plain/base/injection/最终 completion 都只能提交当前 edit 的结果。它解决跨回调间隙，不复制 Neon 内部解析版本；后续子区域路径复用它。
4. stale 交付不回 .noChange：Highlighter 会把范围标 valid；TokenProvider 允许零次回调，旧请求可丢弃。编辑／invalidation 必须让新版本最后重请求，旧 failure 也不能异步清掉新 pending。普通实际错误保留既有降级，不加无限 retry。
5. 删除无版本合并和伪成功交付路径；保留已验证正确的范围转换，不引入第二套 pending 管理。
6. `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`：旧成功／旧失败晚到、连续 edit、undo/redo／空文本、当前视口最终颜色。完整测试／构建后隔离 App 检查 Swift／TSX／Markdown、替换、长粘贴、中文组合输入与保存原字节。

**提交：** edit 桥接、回归及文档独立正确性提交；修复后才用输入高亮结果比较优化收益。

<a id="p3-t2"></a>
## P3-T2 恢复字节精确文本契约并删除重复比较

**类型／依赖：** 正确性修复及同根因精简；依赖 T1。
**文件：** SourceTextEditor.Coordinator.textViewDidChangeText；FileTab.refreshDirtyState/matches；DiffTab 的 hasChanges、内容更新／模式切换、dirty／保存基线比较；DiffEngine.linesEqual 与 DiffIntraline 的文本／token 比较。扩展 FileTabTests／DiffTabTests，在现有 XCTest 目标新增 `KeroTests/Unit/Git/DiffEngineTests.swift`，供 P5-T2 继续扩展；文档 owner 为 editor.md／diff.md。

1. Red：保存的 `é`（U+00E9）替换为 `e` + U+0301。两者 String == 为 true、hash 相同，但 UTF-8 与 UTF-16 长度不同；当前回写可被跳过，dirty／干净重载／Diff 有变化判定及行／token 对比都可能漏掉字节变化。分别验证真实编辑、保存字节、外部 clean reload 和 Git 原文 Diff，不只断言 Swift 的语言行为。
2. 使用标准库 UTF-8 elementsEqual 这类字节精确比较，在文本基线／内容变更及行／token 相等的真实拥有者修复。hash 只能筛选，必须保留精确确认；不能 normalize、增加第二 hash 或把字节不同当“不变”。同 task 接通编辑器与原生 Diff，不只修脏标记留下另一条内容链。
3. 同时删除 newText != file.text 的冗余前置比较，同步取一次完整 String 回写；savedText 仍准确决定 dirty。保留保存期间新增编辑、全部撤销回原字节的行为，不用“收到 edit 就 dirty”或延迟第二缓冲替代。
4. 相同字节、组合字符／中文／emoji、归一化表示变化、保存期间继续输入、撤销／重做和 clean reload；DiffCore ops 重建必须保留两侧字节和各自 UTF-16 范围。只治理用户文本，不把路径、Git Ref、文案等所有 String == 全仓替换。
5. 运行 `make test ONLY_TESTING=KeroTests/FileTabTests`、DiffTabTests／DiffEngineTests、保留／保存相邻回归和完整完成流程；隔离 App 输入／替换／IME／撤销／保存，对照原始磁盘和 Git blob。
6. 对修正后的精确比较重新取得可比基线，再测长文件尾部输入的比较／分配与响应。若 getter／dirty 比较仍主导，记录并另回改数据所有权方案，不偷偷加入 buffer。正确性收益不算后续性能收益。

**提交：** 字节精确不变量、重复比较删除、全部真实消费者、回归及文档一个原子结果，不混坐标／解析缓存。

<a id="p3-t3"></a>
## P3-T3 测量修正后坐标转换，必要时加最小索引

**类型／依赖：** 实验后条件实现；依赖 T1、T2。
**文件：** 当前 SyntaxHighlightPlugin transformer／edit；条件成立才新增 `kero/Editor/TextCoordinateIndex.swift` 和 `KeroTests/Unit/Editor/TextCoordinateIndexTests.swift`，与生产接入同 task；文档归 editor.md。

1. P1-T3 已删除错误的 TextKit.position 路径。本 task 重新测正确 LF／字节转换的首中尾、等字节不同换行数和长行，分离 parse 与转换；不沿用旧热点名称。
2. 先找 TextKit／依赖可复用能力。一轮定位加一个最小原型；没命中就记录保留理由，不新建文件。
3. 确需索引才在现有 coordinator 维护当前文档 UTF-16 的 LF 行起点，二分查询并在 edit 更新受影响段／后续偏移；承认数组平移成本，不造 Rope。
4. will 用旧文档、did 用新文档；输出字节列，不用段落坐标。替换原扫描时同 task 删除旧实现，不留兼容开关或第二份索引真源。
5. 性能替代先保留原生产转换的绿色等价基线，再用固定 seed 插删替换，对照直接扫描和真实 Parser 的点，涵盖 CRLF／LF／bare CR／Unicode 分隔符／emoji／文末；不为制造 Red 改坏正确旧实现。前者测增量等价，后者约束实际解析契约。
6. 条件实现运行 `make test ONLY_TESTING=KeroTests/TextCoordinateIndexTests` 及 SyntaxHighlightingTests／完整完成流程；隔离 App 输入／高亮复测，记录首建、更新、分配和净收益。无净收益不接入。

**提交：** 只提交被采用实现、测试和必要文档，实验证据归本地 evidence-p3.md。

<a id="p3-t4"></a>
## P3-T4 测量根解析调度，必要时调整现有参数

**类型／依赖：** 条件实验；依赖 T1，默认在 T3 后检查残余热点。
**锚点：** SyntaxHighlightCoordinator 的 TreeSitterClient 初始化；T10 本地核心的 processEdit／synchronousLengthThreshold。

默认 edit 不超过 1024、文档不超过 1,000,000 且无在途队列时可同步 parse。公开 init 已能设 threshold，本 task 不改运行时调度实现。

1. 仅默认同步 parse 确认阻塞时对比默认和 threshold=0；非空 edit 可走后台，零 edit 不保证，不用负数 undocumented 参数。
2. 同组动作测按键／光标、高亮追上和持续输入后收敛，稳定 String readHandler 保持到 parse 完成；不只测主线程 parse 消失。
3. 默认满足响应且异步更迟就保留。采用现有参数即可，不加 debounce／queue／root Parser／generation。
4. SyntaxHighlightingTests 补最后版本、undo、大粘贴、切文档／关闭后的真实颜色与释放；完整完成流程和隔离 App 复测。

**清理／提交：** 不保留临时参数切换配置。选中参数、测试及必要说明独立提交；无改动只留本地证据，不做阈值调参研究。

<a id="p3-t5"></a>
## P3-T5 修复查询失败闭环，按需共享在途编译

**类型／依赖：** 失败闭环必修，共享有热点才做；依赖 T1。
**文件／完整消费者：**
- SyntaxHighlightPlugin 中 HighlightQueryCache、installTokenProvider、finishInstall、injectedHighlightsQuery／pendingInjectionCompiles。
- `kero/Git/DiffSyntaxHighlighter.swift` 的 context 也读写同一 cache、也自行 compile，不得遗漏。
- SyntaxHighlighting 的真实 query 资源输入；SyntaxHighlightingTests，若共享则扩展 DiffTabTests 的实际着色检查；文档归 editor.md，Diff 行为变动才同步 diff.md。

1. Red：固定坏 embedded Query 完成后当前实现仍 invalidate，下一请求再编译；证明反复 viewport／请求不会忙循环。
2. 在现有 query owner 记录进程内固定资源编译失败；失败结束 pending，不以 invalidate 启动无益重试，保留 plain/root 降级。资源无热更新入口，不增 TTL／重试恢复状态机。
3. 只有冷开多文档／Diff 的 trace 证明重复 compile 值得治理，才在现有 cache 按 language／kind 合并在途工作。不为测试强制迁出新文件；root、embedded 与 Diff highlights 共用，injections 分 kind，TS 与 TSX 不混 grammar。
4. 共享时 compile／资源读取在明确后台边界，cache／invalidate 回所属 actor；一个 waiter 关闭不能取消其他 waiter。只有真实存活消费者需要弱引用／释放处理，不预建 protocol 或编译服务。
5. 同 task 接入所有消费者并删除各自重复 compile/pending／双轨备用闭包；只做失败闭环时不声称已经共享，也不预建共享文件。
   冷开实测4个编辑器+2个Diff确有6次同键编译，进入共享实现。缓存只用pending Task／完成结果（含nil）两态；embedded保留每coordinator一份等待标记以避免重复挂载重画waiter，它不再拥有编译任务，不新增中央订阅框架。
6. `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`、共享时 DiffTabTests、完整完成流程。检验坏资源重复请求不重编译、root/embedded/Diff 同 key、不同 kind／grammar、关首个 waiter 后另一 editor/Diff 仍实际着色；不是只看 Query 返回或计数。
7. 隔离 App 多同语言标签／Diff／围栏，比较冷 compile 工作量、可见颜色与内存。数字来自本机，不沿用源码注释的历史毫秒数。

**提交：** 失败闭环与实际采用的共享接入／旧路径删除、回归和文档一个结果；未准入不建缓存框架。

<a id="p3-t11"></a>
## P3-T11 清理插件依赖与无用包装

用户追加要求。先核对真实包图和引用，不能把一个本地覆盖解释成两份 Neon 运行时，也不能把上游包清单仍含 Neon 说成已删除。

- 当前远程 STTextView-Plugin-Neon 同时承载20种语法／查询、主题资源和未使用的插件适配；没有独立资源产品。40个被引用语法／查询模块共139文件、124164111字节，直接搬入仓库不是小清理。完整去包的源码体积取舍已向用户确认；不因等待停止其他已授权任务。
- 不受该决定影响的清理：移除 SourceTextEditor／DiffSyntaxHighlighter 无用 import，直接使用现有颜色字典替代第三方 Theme／Fonts／TokenName 包装，保持所有颜色及 fallback／alias 一致，不改UI。
- 按最小已授权清理范围收尾：应用侧旧引用和主题包装删除，必需的语法资源来源保留，明确上游声明仍在、实际只解析一份本地Neon，不假称完全去包。不靠修改下载checkout或构建时补丁维持结果。用户未明确选择大体积资源接管，不能据此复制118MiB源码，也不把未授权额外接管当作整份计划的阻塞条件；日后明确要求完整去包时单独处理资源所有权。
- 既有颜色／字体／撤销回归和实际Diff颜色，Debug／Release构建验签及当前依赖图检查。新增等价性验证先在正确旧实现通过，不人为制造Red；必要旧路径同提交删除。

**顺序：** T4完成后执行；与T5不互相捆绑，仍在P3门禁前闭环。

<a id="p3-t12"></a>
## P3-T12 修复实测的长文档反向定位

T6原生滚动实验两次在反向第16次定位失败；实际颜色正确，但目标UTF-16偏移80757，viewport仍在171001附近。去掉整个高亮插件后同样复现，不能归因于injection缓存或通过延长等待绕过。

- 入口为FileTab.performFindAction → NSTextFinder → STTextFinderClient.scrollRangeToVisible → STTextView.scrollToVisible／relocateViewport／layoutViewport。CodeGraph不覆盖Vendor内部，已用源码补证；继续读完整布局／内容尺寸反馈和平台API契约后才修复。
- 在既有NativeUI测试目标留下最小无高亮Red，覆盖前进／后退到指定正文范围和实际viewport，另检验普通短文档与文末。不要用颜色存在冒充目标可见，也不因测试API失败就猜用户鼠标滚动失败。
- 修复失效的最小共享位置，删除被替代定位逻辑，不能另建滚动缓存、追加重试循环或全篇预布局补丁。正确性确认后重跑T6的原生滚动对照。
- 同任务更新Vendor补丁说明与编辑器契约，相关回归、完整XCTest及Debug／Release验签；不操作用户App。

**顺序：** 属于已复现的编辑器路径缺陷，在P3门禁前闭环；不把T6 provider性能实验误当这个路径已通过。

<a id="p3-t6"></a>
## P3-T6 验证嵌入语言的最小复用

**类型／依赖：** 本地探索；依赖 T1、T5 的实际结论，先于 T7。
**当前路径：** root highlights → injections → 每个 NamedRange 新 Parser／全 fragment parse／query／偏移 → Neon 样式；fragment 和 predicate 目前在主线程，可见范围请求可能反复解析同一长块。

1. 先测重复 parse／token 工作；无热点则记录保留，不自动重构。
2. 有热点只做一个最小原型：优先同文档同 edit revision 的片段／结果复用与稳定快照后台计算。只有跨 edit 全量重算仍主导，才再验证 Parser／Tree 的增量复用；不一开始强制后台增量子树引擎。
3. 长 fence、同语言不同区域、HTML script/style、围栏删改／换语言、区域前插入、未知语言与 Unicode，对照同版本全量解析。跨 root/injection 间隙复用 T1 的 revision，不另建版本真源。
4. 当前 SwiftTreeSitterLayer 未链接；公开接口不能直接采用 Neon 根树，resolveSublayers 也无消失区域的完整删除契约。因此不做 Layer 双根解析原型／fork，不以“依赖有这个类型”当接入证据。
5. 一个原型、一组正确性／性能对照；无收益、范围或删除语义不成立就不接入。缓存只留当前文档可达区域，不留无限版本。

**交付：** 本地 evidence-p3.md 的方法、结果、选中的最小措施及 T7 精确接入决定；不提交原型、不改依赖 checkout。

<a id="p3-t7"></a>
## P3-T7 接入已验证的子区域复用措施

**类型／依赖：** 条件实现；T6 有热点且原型通过才进入。
**文件：** SyntaxHighlightPlugin 的 injection／edit／生命周期；确需单一职责时才新增 InjectedSyntaxState.swift，不预定文件。测试扩展 SyntaxHighlightingTests；数据算法变复杂才补 `KeroTests/Unit/Editor/InjectedSyntaxTests.swift`，仍进现有 XCTest。文档归 editor.md。

T6已选定：只在现有coordinator保存当前revision的NamedRange→Task结果，使用SDK已有Sendable元数据，后台局部Parser／QueryCursor。读fragment后再校验revision，编辑取消并清缓存。root与child token都裁剪到请求区间：否则root整块capture会被Neon提前标成valid，不能只裁child。无新文件／依赖／根树／子树增量引擎；T12独立处理已确认的原生反向定位。

T7永久回归进一步证明：等长将`swift`换成未知围栏语言时，根树局部集合只覆盖信息字符串，旧child样式仍valid。与选定的整次revision子结果契约一致，嵌入文档的新根解析结果清掉旧有效标记，Neon仍只按视口请求1024区间，不做全篇重画或第二套区域依赖图；单语言继续精确局部集合。这个失效职责在既有tsClient.invalidationHandler闭环，不在每个调用处堆特判。

1. 按 T6 选择接入，删除被替代的每请求 Parser／全片段路径。可能只是同版本复用，不把“必须跨 edit 增量解析”写成无证据验收。
2. 稳定 String／数据后台计算，可变 Parser／Tree 一个串行拥有者；复用 T1 的 edit revision 保证 root+child 合并一致。不重造 root parser、queue、版本或 workspace 状态。
3. 范围／语言／内容变化按实际选中策略失效；不能仅以同语言／同起点匹配其他片段。删除围栏必须清旧颜色／缓存。
4. 只返回当前请求需要的合法 token 范围，保持 child 覆盖 root 的顺序和跨边界语法；旧结果不标 valid、不忙循环，当前视口最终着色。
5. 关闭 editor 释放独占片段／任务／快照，不为了复用永久挂载所有编辑器。已有 root／query 缓存职责不复制。
6. Red／Green 覆盖重复请求、片段内 edit、围栏移除／换语言、相同语言不同内容、Unicode／空范围和延迟旧结果；检查真实最终 tokens／颜色与工作量。
7. `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`、实际新增 Unit 类及完整完成流程；隔离 App 长 fence／HTML 输入、滚动、切换、撤销／保存，比较主线程、可见高亮、内存和关闭后释放。

**提交：** 采用实现、真实接入、旧路径删除、回归和文档同 task。未采用只交理由，不创建占位实现或“未来升级”配置。

<a id="p3-t8"></a>
## P3-T8 修复原生组合输入结束时丢字

T2 的原生中文输入回归实际发现：STTextView.unmarkText 删除已标记正文，违反 Apple 接受已插入文本的契约。T2 先验证正常 setMarkedText→insertText 的提交路径；本任务紧接 T2 独立修复，不推迟到阶段收尾。

1. 使用真实 STTextView 对照 NSTextView，Red 验证直接 unmark 不删字；同时覆盖 marked→insertText 的默认／显式替换范围，不能修一条路径后让另一条重复插入。
2. 在现有 NSTextInputClient 桥接区分“接受组合文本”和“用最终输入替换组合范围”；删除旧的 unmark 删正文语义，不引入第二套输入缓冲。保持临时标记清理、选择、普通输入和既有撤销。
3. 复用现有 NativeUI XCTest；通过 EditorTextInputTests、FileTabTests、DiffTabTests、SyntaxHighlightingTests 和完整 build/test；更新 development.md 的本地补丁归属及 editor.md。独立原子提交。

<a id="p3-t9"></a>
## P3-T9 核实解析输入分块边界

T3 后沿残余解析成本继续读到 SwiftTreeSitter 的实际 readFunction：按 UTF-16 字节块换算 String 范围，再重新编码。边界怀疑已用实际读取字节、生产插件和 fresh Parser 核实，没有复现截断。保留原读取器，撤回拟议的字节快照替代，不以理论风险新增产品代码。

1. 永久回归覆盖 1022／1023／2047 UTF-16 单元前缀，emoji、组合字符、CRLF／ZWJ 及编辑后平移；Swift String 与实际 TextKit 快照的分块读取拼接必须等于完整 UTF-16 字节。
2. 初次与编辑后都对照生产插件和 Parser.parse(String) 的完整 AST／范围／Point，检查末尾当前关键字色，不能只凭 AST 中的 comment 节点推断字符没有变化。
3. 无产品实现变更，只提交回归及必要文档。运行分块单例与高亮／坐标／组合输入组；现有产品的 267 项全量及 Debug 验签归 T3，不冒称已覆盖新测试。阶段综合验证继续全量发现该回归，不为单一测试重复搭一套构建／跑法。
4. T4 的读取与坐标基线仍成立；先 profile 剩余实际工作，不把未复现的截断或未实施的 reader 改造计为收益。

<a id="p3-t10"></a>
## P3-T10 修复解析队列交付旧坐标的失效范围

T4 的大文档连续编辑实际 Red：声明改成调用，随后在前方注释中插入内容；当前树和当前 provider 已是调用，当前视口仍保留声明色。锁定 Neon `ce8d252` 的 transformRangeSet 算出了 transformedSet，却返回原 set；异步回到主 actor 时还有后续 edit，失效坐标因此错误。

1. 保留当前原生回归，初始通过实际请求使旧样式 valid，编辑前恢复生产默认请求长度。最终核对真实 Tree、provider 及视口，不把“新树正确”当作已重画。
2. 同版本运行时核心作为本地 Neon 包接入，修复返回值；保持唯一 parser／串行 queue／范围变换拥有者，不在 coordinator 复制 edit 列表，不用全量重绘或第二队列绕过。锁定插件依赖这个固定 fork，当前公开分支此文件仍是同一提交，不作跨版本迁移。
3. 只带实际消费者需要的 runtime 源码。未被 Kero 或锁定插件使用的 NSTextView／UIKit 适配、buffer／旧 Region 别名不引入；旧系统 MainActor／主队列兼容桥改为当前平台原生能力。弃用游标、无调用者的查询模式／便捷接口、恒为 true 的失效开关及 noChange 样式叠加路径同任务删除。使用已经锁定的 SwiftTreeSitter 0.25 匹配序列，后台取匹配、主线程谓词前后校验版本；保留必要队列断言、原作者版权与许可证，不改其余根解析算法。包最低 macOS 14 与插件一致，App 仍 15.6。
4. Xcode 本地 package override 确保同一 Neon 身份只有一份实现，依赖版本不变；许可证进入仓库与 App 资源，更新 NOTICE、development 和 editor 文档。不得修改 SwiftPM checkout 或搭补丁脚本。
5. Red→Green 后运行高亮／输入／坐标／Diff 相邻回归、完整 XCTest、Debug 和 Release 构建／验签，检查实际构建路径与许可证入包；独立原子提交，再恢复 T4 调度实验。

## 阶段核销

evidence-p3.md 分清修复、实测保留、未测与仍慢；正确性依靠最终内容／可见范围，性能依靠同机对照。实施并验证后进入阶段审计，不以计划审查宣布 Go。
