# P3：正确的增量编辑、查询与嵌入语言

> 本页保留旧实施方案，先读 [实施基线更新](idea.md#实施基线更新)。下面写作前提的“P1 已修复”是旧计划的依赖条件，不是任务完成证据。按当前 Swift 6、XCTest 与实际高亮实现重新复现和测量，不恢复旧 Swift 5 编译／独立脚本路径。

**Goal:** 编辑后范围正确，输入不承担无必要的全文扫描；嵌入语言不为同一内容和区域反复从头解析。

**Non-goals:** 不造 Rope/CRDT，不替换 Neon，不引入通用 parser service，不扩大语言能力或改语法资源。

**Approach:** 首次解析/坐标契约已在 P1-T3 修复；这里补齐编辑通知与整次 token 交付的同版契约，再分别核对比较、扫描、解析调度和编译成本。嵌入语言先验证现有 Parser/Tree 的最小复用，不预定第二套根解析。

**Acceptance:**
- 插入/删除/替换后，高亮有效范围随编辑移动；延迟旧回调不能把新区域误标为已高亮。
- 输入成本按全文访问、比较、坐标转换、根解析分开复测，不把一项收益归给另一项。
- 固定资源编译失败不会持续 invalidate/recompile；热点成立时，同语言冷开共享在途编译，已关闭编辑器不被 waiter 长期留住。
- 同内容重复访问嵌入区域复用计算；内容/围栏/语言变化后结果正确，解析不堵主线程。
- 所有选用的新逻辑在对应 task 就有最小可运行回归检查和真机验收，不等 P6 补测试。

**Rules:**
- TreeSitterClient 为 MainActor API；它的内部串行解析、版本检查、pending edits 与 range transformation 已存在，不能把整个 client 放后台或复制一套 root 状态机。
- readHandler 须在 parse completion 前稳定且线程安全，后台不能访问正在变动的 NSTextContentStorage。
- SwiftTreeSitter 使用 UTF-16 输入；Neon 的 InputEdit 从 NSRange 乘 2 得字节。P1-T3 已采用 Tree-sitter LF 行/字节列；这里不得退回 TextKit 段落序号/UTF-16 column 原值。
- 已有 Query/Tree 是 Sendable；Parser、MutableTree 和 QueryCursor 不因此可跨线程共用。可变解析状态由一个明确串行拥有者持有。
- 不关闭可见高亮换速度；未知语言仍 plain text，继承查询/TSX/metadata 过滤/零范围保护保留。
- 标为“证据门”的 task：未命中热点时交付复测与保留理由，不制造代码；确有热点则在本 task 完成最小修复和验证。不同根因分开提交。

<a id="p3-t1"></a>
## P3-T1 补齐编辑后的高亮范围更新

**类型 / 依赖:** 正确性实现；依赖 P2 和 P1 基线。

**Files / 锚点:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift：setUp、willChangeContent、didChangeContent、两种 token provider、tsClient.invalidationHandler。
- Read-only: Neon Highlighter.didChangeContent / handleTokens / TokenApplication；锁定源码见 build/SourcePackages/checkouts/Neon/Sources/Neon/。
- Modify: `KeroTests/check-editor-highlighting.swift`，扩展 P1-T3 已有真实 App/生产桥接检查；可在同一脚本用现有 TextSystemInterface 加可控延迟验证真实 Neon 契约，不另写桥接算法。
- Modify: docs/features/editor.md 的增量路径事实。

**证据:** Highlighter.didChangeContent 移动 validSet、清 pending 并安排重请求，Kero 当前未调用。另有真实的多回调间隙：base query 成功后再发 injection query，两者各自通过 Neon 的 version 检查，并不证明合并结果同版；后一查询 staleContent 时当前代码仍提交旧 base tokens。STTextView 在修改前/后传同一个 NSTextRange，Kero 却在修改后重新转换旧范围，删除末尾时可能越界；应在 will 阶段保留旧 NSRange。这些是当前执行链缺口，不等待后台子解析或性能准入才处理。

**实施与验证:**
1. 先用可控 TokenProvider 的延迟回调复现“在已着色文本前插入/删除”；检查请求覆盖当前视口，而不是仅看 invalidate 被调用。
2. will 阶段捕获旧 NSRange，并传现有 tsClient.willChangeContent；did 阶段使用保存的旧范围与 replacement UTF-16 长度通知 highlighter，再通知 tsClient。不在已缩短文档里重新换算旧 endLocation。注意 plugin 的 didChangeTextIn 早于 delegate 的 textViewDidChangeText 全文回写；新解析快照取实际 TextKit 内容。
3. stale 回调不返回 .success(.noChange) 冒充当前结果：它仍会在 handleTokens 标记请求范围有效。TokenProvider 允许零次回调；编辑已经清理旧 pending 并安排新请求时，可直接丢弃旧交付。Neon 的 failure 分支只异步清 pending，不主动启动下一请求，不能假定失败自动重试。沿实际 edit/invalidation 顺序证明新版本最终重请求、不忙循环也不永久失色。
4. 在 coordinator 增加仅服务整次 token 交付的一个编辑 revision，edit 时更新；plain 与 injection provider 入口捕获，base/injection/最终 completion 均只交付同版结果。后续 P3-T7 复用此 revision，不另加根/子语言各一套 generation。旧错误也不能清除新请求的 pending；正常真实错误保持现有反馈/降级，不能靠无期限 retry 追上。
5. Run: `bash scripts/check.sh editor-highlighting`，先构建 Debug。扩展真实生产桥接测试：在已着色区域前插入、尾部删除、全删到空、pending 期间新 edit、base 与 injection 中间编辑、旧成功/旧失败晚到；检查最终 token 范围和当前视口重新着色，而非仅测试 Neon 自身。
6. 真机对 Swift/TSX/Markdown 首/中/尾插删、粘贴、find replace、撤销/重做、连续输入和中文组合输入；滚到原已高亮区域核对位置与保存内容。

**提交边界:** 编辑范围契约修复、脚本与必要说明一次提交，不夹带调度优化。

<a id="p3-t2"></a>
## P3-T2 删除编辑回写中的重复全文比较

**类型 / 依赖:** 小实现；依赖 P3-T1。

**Files / 锚点:**
- Modify: kero/Editor/SourceTextEditor.swift：Coordinator.textViewDidChangeText。
- Verify: kero/Editor/FileViewerView.swift：text、savedText、refreshDirtyState、save。
- 当前编辑与保存契约归 `docs/features/editor.md`；测量方法改变才更新 `docs/testing.md#性能与内存测量`。

**依据与不变量:** didChangeText 已是文本变化完成通知；FileTab.text 不发布。当前先 newText != file.text，再 refreshDirtyState 比较 savedText，长文尾部编辑可能进行两次长前缀比较。真正决定 dirty 的是保存基线，不是之前一刻文本。

**实施与验证:**
1. 去掉回写前非必要的新旧相等比较，仍同步获取一次当前完整 String 写 FileTab，仍用准确的保存基线比较决定 dirty。不要用“收到 edit 就永远 dirty”替代。
2. 这不承诺消除全文 getter/桥接，也不顺手延迟 file.text 同步。保存、关闭、切标签都可随时消费完整正确文本。
3. 同机大文尾部输入复测比较次数/分配与按键响应；同内容替换通知不产生额外 dirty 发布。
4. 真机插入/删除/同长度替换、全部撤销回保存内容、保存中继续输入、找替换和中文输入；核对关闭提示与最终文件。
5. 如果 P1 显示剩余 getter/脏比较占主导，先在 evidence-p3.md 记录具体热点。更深文本持有方案必须回改计划、明确数据所有者和兼容测试，不能偷偷加入第二套 buffer 或概率 hash 判等。

**提交边界:** 回写精简一个独立提交；不包含坐标/解析/子语言缓存。

<a id="p3-t3"></a>
## P3-T3 坐标扫描的证据门与最小索引

**类型 / 依赖:** 定向实验后条件实现；依赖 P3-T1、P3-T2。

**Files / 锚点:**
- kero/Editor/SyntaxHighlightPlugin.swift：TreeSitterClient transformer、willChangeContent/didChangeContent。
- Read-only: STTextKitPlus NSTextContentManager.position；Neon InputEdit 扩展与 SwiftTreeSitter.Point。
- Only if admitted: new kero/Editor/TextCoordinateIndex.swift、KeroTests/check-text-coordinate-index.swift；现有同步根目录自动接入应用。
- Local evidence: evidence-p3.md；实现后更新 docs/features/editor.md 中相关契约，不把实现细节复制进测量规范。

**问题与方法:** position 每次枚举整份文档段落并搜索。测首/中/尾、等字节不同换行数量、超长单行；将转换耗时与 parser 耗时分开。成本最多一轮定位加一轮纯数据原型，若未命中就保留现实现。

**准入后实施:**
1. 优先检查现有 TextKit/依赖是否有不全篇扫描且满足坐标契约的入口；当前公开 position 实现没有索引，不能用改名 helper 假装优化。
2. 如确需索引，只维护当前文档的 UTF-16 行起点，在编辑通知更新受影响片段和后续偏移；二分查所在行。不新建 Rope、不声称数组尾部平移是 O(log N)。
3. 复用 P1-T3/P3-T1 已正确的 Point 与旧 edit 范围：索引按 LF 行定义，输出 UTF-16 字节列，will 用旧文本、did 用新文本。数据由 coordinator 持有，重建/换文档重置；后台只读对应快照，不读 AppKit。
4. 对照完整 Parser oracle 检查 CRLF、LF、bare CR、Unicode 段落分隔符、尾换行和空文本；不把 TextKit 的 paragraph row 当作 Tree-sitter row。此处是性能替代的等价性验证，不将已知单位修复延期到索引准入。
5. 脚本编译真实 TextCoordinateIndex；用固定 seed 多次插删替换与慢扫描 oracle 对比全部关键偏移，含 emoji 代理对、中文、CRLF 边界和尾端。命令：xcrun swiftc -swift-version 5 -o build/check-text-coordinate-index kero/Editor/TextCoordinateIndex.swift KeroTests/check-text-coordinate-index.swift && build/check-text-coordinate-index。

**验收:** 真机输入/撤销/高亮范围无回退，原扫描热点消失或明显收敛；记索引分配、首开成本与尾部偏移更新成本。未改善或破坏坐标则撤销原型，不把新增索引本身算完成。

**提交边界:** 仅被证据选中的坐标实现、回归检查与说明；未准入的实验不提交。

<a id="p3-t4"></a>
## P3-T4 根解析调度的证据门

**类型 / 依赖:** 定向实验后条件实现；依赖 P3-T1，默认在 P3-T3 后比较残余热点。

**Files / 锚点:** kero/Editor/SyntaxHighlightPlugin.swift 的 tsClient 初始化与 didChangeContent；锁定 TreeSitterClient.init(synchronousLengthThreshold:) / processEdit；evidence-p3.md。

**已知:** 默认小 edit <=1024、文档 <=1,000,000 且无 queued work 时同步 parse。公开 init 已有 synchronousLengthThreshold 参数，不需要 fork Neon 增加“总是后台”开关。

**实验与选择:**
1. 比较默认 threshold 与公开参数设为 0 的定向原型：后者让非空 edit 排队后台；零变化 edit 不保证走后台，不靠负数 undocumented 值强推。
2. 测按键到文本/光标、高亮追上、pending 深度与持续输入结束后追上时间，而非只测主线程 parse 消失。每次 parse 仍读稳定 String 快照，Neon 自己保持 edit 顺序。
3. 默认已在交互预算内且异步只增加着色迟滞则保持默认。同步 parse 确认阻塞时选较简单且实测有效的公开 threshold；不增加第二套 debounce、generation、queue 或 root Parser。
4. 新 edit、撤销、大粘贴、关编辑器、切文档期间验证最后一版真实可见高亮正确，后台任务不留住视图。P3-T1 的编辑范围通知不可省略。

**成本 / 验收 / 提交:** 两个配置各跑同组样本，不展开阈值调参研究；记录选择与延迟。被选中的参数及必要说明独立提交，构建、验签后在隔离实例验收；只实验无变化不提交。

<a id="p3-t5"></a>
## P3-T5 查询编译的单次在途共享

**类型 / 依赖:** 必修编译失败闭环 + 条件在途共享；依赖 P3-T1，默认在根解析复测后。

**Files / 锚点:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift 的 installTokenProvider、finishInstall、injectedHighlightsQuery、pendingInjectionCompiles；SyntaxHighlighting.highlightsData/injectionsData 的资源输入。
- Only if admitted: new kero/Editor/HighlightQueryCache.swift，将现有 HighlightQueryCache 原职责迁出插件，新增的在途合并仍由它拥有。不是新增通用缓存或替换 SyntaxLanguage。
- Modify: `KeroTests/check-editor-highlighting.swift`；实际 cache 仍在插件内时用现有 App 模块检查，不为了测试迁出文件或伪造 SyntaxLanguage。确因共享职责需要独立文件才用真实模块链接。
- Local evidence: evidence-p3.md；实现后更新 docs/features/editor.md 中相关契约，不把实现细节复制进测量规范。

**已证实必修:** injectedHighlightsQuery 无论成功/失败都移除 pending 并 invalidate；固定查询失败后，下一请求会再编译、再 invalidate，形成实际闭环。本 task 先用坏查询可控复现并消除循环，不以性能不显著为由保留。

**在途共享的证据门:** 当前只有完成缓存，每 coordinator 自有 pendingInjectionCompiles；同语言多文件冷开可重复 compile，root injections query 在 finishInstall 内同步 compile。trace 记录成本，没有热点则仅做失败闭环，不造缓存框架。

**准入后实施与验证:**
1. 首先为进程内固定的 language/query kind 记录编译失败，不因视口 invalidate 再次编译；失败保留 plain/root 降级，没有资源更新入口就不造自动重试、TTL 或恢复状态机。只有在途共享准入后才在同一 cache 合并 root/embedded highlights，injections 为另一种类。
2. compile 和必要资源读取离开主线程；cache 管理与 UI invalidate 回主 actor。多个 waiter 得到同一 Query，关闭一个视图不取消其他 waiter 需要的编译。
3. 编译完成/失败都结束 pending，waiter 弱引用 coordinator；成功失效一次以重绘，失败不驱动无益 invalidate。只在当前进程资源不变的边界记录失败，关闭一份文档不影响另一份编译。删除被共享请求取代的每 coordinator pending 与双份 root/child 编译闭包，不留下备用编译路径。
4. 真机一次打开多个同语言文件和同语言围栏：每 key 在途 compile 一次；打开 TS 与 TSX 不共用 grammar；关首个 editor，第二个仍实际着色。未知语言保持 plain。
5. 同 task 扩展 `bash scripts/check.sh editor-highlighting`：真实固定资源/坏 Query、失败后重复 viewport、root/embedded 相同语言、TS 与 TSX、不同 kind、关闭首个 waiter 后其他文档仍着色。若共享准入，断言同 key 编译一次、热命中和完成清理；只做失败闭环时不声称已共享。不要复制生产缓存算法或为了测试新增生产 protocol。
6. 模块链接沿用 P1-T3 检查与当前 `GeneratedModuleMaps`；旧 plan 中包 target 内的 modulemap 路径不能复用。真实 JSON Query 可作小 fixture，但语言选择仍由实际 SyntaxLanguage/插件检查证明。

7. 用 P1 Debug 计数和 trace 验证并发首次、热 cache、根 injections 与失败路径；真机证明最后视口真的着色，不只以函数返回 Query 或 compile 次数下降验收。

**提交边界:** 查询编译闭环、实际准入的共享接入/旧 pending 删除及检查一个原子提交；未命中共享时只包含必修失败闭环，不为条件分支预建新文件。

<a id="p3-t6"></a>
## P3-T6 嵌入语言复用方案的最小实验

**类型 / 依赖:** 探索；依赖 P3-T1 和查询缓存准入结论，必须先于 P3-T7。

**当前最终路径:** root highlights callback → root injections callback → injectedTokens；每 NamedRange 新 Parser、parse 全 fragment、query 全 token、偏移后由 Neon 写样式。callback 与 predicate prepare 均回主线程。视口 1024 请求可能反复包含同一个长片段，不能只缓存 Query。

**已核对的可复用能力与排除项:**
- 现有 SwiftTreeSitter Parser.parse(tree:string:)、Tree.copy/edit、Query.execute 支持子树复用。
- 锁定包另有 SwiftTreeSitterLayer 产品：LanguageLayer.didChangeContent、resolveSublayers、snapshot、ContentSnapshot；当前 Kero 未链接该产品。Layer 会维护子语言与 included ranges，不能把它当作已接入能力。
- Layer.state 为非公开，公开入口没有采用 Neon 已解析根树的能力；resolveSublayers 只遍历本次有结果的语言并并入 ranges，不移除消失的 sublayer/旧范围。它不能直接满足当前根树复用与围栏删除要求。本 feature 不为比较而强制实现另一套根解析或维护 Layer fork。
- Neon TokenApplication.noChange 会把请求范围加入 validSet，不能用于掩盖过期结果。

**实验交付:** 在 build/performance/prototypes/ 做一次可丢弃、同样本对照，不改用户应用资源；evidence-p3.md 明确决策和实际输出。
1. 先测现有 fragment 工作量；未形成实际热点则保留并记录，不自动进入重构。命中后只做现有 Parser/Tree 的一个最小子区域原型；Layer 因上述源码边界排除，不强制做第二原型。后续若出现可用根树接入与清理契约，先回改本决定再试。
2. 长 Markdown fence、两个相同语言不同内容区域、HTML script/style、未知语言、围栏编辑/删除/改语言、区域前插入文本；输出 named ranges 与同版本全量解析 oracle 一致。
3. 同版本反复 viewport 查询计数；代码块内 edit 后检查可复用旧 tree，而非仅“有 cache”；调后台后按内容版本门控 root+child 合并，防止两个独立 root query 中途 edit 混版。
4. 串行拥有可变 parser/tree，query/read 使用 immutable snapshot；记录 token 顺序、坐标/Point 和关闭后释放。
5. 停止条件：一个小原型、一组正确性与性能对照。有围栏清理/坐标错误或无净收益就不接入；记录是否需要后续单独设计，不边实现边赌。

**提交边界:** 只交本地证据与回写后的 P3-T7，不为实验制造 Git 提交。临时依赖源码修改不能成为正式成果。

<a id="p3-t7"></a>
## P3-T7 接入已验证的后台子区域增量路径

**类型 / 依赖:** 条件实现；依赖 P3-T6 的热点与原型通过，未准入就交付保留理由，不实现“预定 Layer 重构”。

**Files / 接入:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift 的 injection provider / edit / lifecycle。
- Only if selected: kero/Editor/InjectedSyntaxState.swift，拥有当前 editor 的子区域解析数据；单个真实职责，不写 protocol/factory。
- New: KeroTests/check-injected-highlighting.swift 与同 task 配套运行命令；编译实际被选子区域实现和现有依赖，不复制其算法。
- Modify: `scripts/check.sh` 注册 `injected-highlighting`；编译/模块参数沿 P1-T3 的现有 App/依赖入口，采用真实 SyntaxLanguage，不为脚本新增类型壳。
- 实际接入后的高亮契约归 docs/features/editor.md；依赖补丁归 docs/development.md#依赖与本地补丁；测量规范只在方法变化时更新。

**实施:**
1. 按 P3-T6 决策接入，删除原每次 new Parser / full-fragment parse 的旧路径，不能两个实现同时运行。只维护当前文档当前子区域，查询仍由 P3-T5 的实际缓存策略提供。
2. 复用已有 edit range/delta；未受影响区域可移动/复用，片段内 edit 复用树，结构/语言改变作最小重建。无法可靠匹配的区域重建，不按相同 language 或相同起点误用别处内容。
3. 子解析和 query 使用稳定文本在明确后台串行边界执行；复用 P3-T1 已有 coordinator 编辑 revision 做 root+injection+child 同版合并，不再增加一套版本或 workspace generation。可变 parser/tree 只有一个拥有者。
4. 回主线程前丢弃过期或已关闭 coordinator 的结果；通过 Neon 的实际 pending/失效机制保证当前视口最终得到最后版本，不能失败即永久不请求。字体仍不入文本存储。
5. token 只交付当前请求需要的范围，保持子语言覆盖 root 的既有顺序；不要为一个 1024 请求反复发整块数万 token，合法跨边界 token 的剪裁依现有语法/渲染契约验证。
6. 缓存随 editor 释放，只留当前可达区域/树与必要快照；不保存无限文档版本。若视图重建仍是实测热点，先记录与回改专门 task，不能偷偷让全部编辑器永久挂载。

**验收与提交:**
- task 内运行真实实现的脚本：P3-T6 全量 oracle、重复查询/片段内 edit、围栏移除/变语言、未知语言、零范围、Unicode 和故意延迟旧结果；检查输出与 parse 次数。
- 构建、验签后在隔离 Debug 实例的长围栏与 HTML 中输入/滚动/切页，最终可见颜色、范围、文本、撤销/保存均正确；实际子 parse 不在主线程，同版复访不从头解析。
- 同 P1 样本比较主线程、可见高亮、后台追上、内存和关闭释放；不能只证明分支选择或 cache 命中。
- 实现、接入/旧路径删除、脚本及必要文档一个原子提交；依赖生成不混入。

## 阶段自审与交接

- 逐项核对全量 oracle、最终可见高亮与磁盘文字；快照、root 版本检查不替代跨回调同版合并。
- evidence-p3.md 区分已修复、实测保留、缺权限未验收与仍慢，不把条件措施全部算“已经优化”。
- 实际完成后进入 plan-task-auditor 并创建 audit-p3.md；规划时不创建。
