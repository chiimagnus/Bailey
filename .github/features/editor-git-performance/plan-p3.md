# P3：正确的增量编辑、查询与嵌入语言

**Goal:** 编辑后范围正确，输入不承担无必要的全文扫描；嵌入语言不为同一内容和区域反复从头解析。

**Non-goals:** 不造 Rope/CRDT，不替换 Neon，不引入通用 parser service，不扩大语言能力或改语法资源。

**Approach:** 先补齐现有高亮编辑通知契约，再分别关闭重复比较、坐标扫描、同步解析、重复查询编译的证据链。最复杂的嵌入语言先做最小实验，比较已安装 Layer API 与现有 Parser/Tree 的可复用能力，选职责边界最小的办法。

**Acceptance:**
- 插入/删除/替换后，高亮有效范围随编辑移动；延迟旧回调不能把新区域误标为已高亮。
- 输入成本按全文访问、比较、坐标转换、根解析分开复测，不把一项收益归给另一项。
- 同语言冷开不会无必要地重复编译；已关闭编辑器不被编译 waiter 留住。
- 同内容重复访问嵌入区域复用计算；内容/围栏/语言变化后结果正确，解析不堵主线程。
- 所有选用的新逻辑在对应 task 就有最小可运行回归检查和真机验收，不等 P6 补测试。

**Rules:**
- TreeSitterClient 为 MainActor API；它的内部串行解析、版本检查、pending edits 与 range transformation 已存在，不能把整个 client 放后台或复制一套 root 状态机。
- readHandler 须在 parse completion 前稳定且线程安全，后台不能访问正在变动的 NSTextContentStorage。
- SwiftTreeSitter 使用 UTF-16 输入；Neon 的 InputEdit 从 NSRange 乘 2 得字节。Point 列与换行契约需单独核对，不能把 Swift Character 数、UTF-16 和字节混用。
- 已有 Query/Tree 是 Sendable；Parser、MutableTree 和 QueryCursor 不因此可跨线程共用。可变解析状态由一个明确串行拥有者持有。
- 不关闭可见高亮换速度；未知语言仍 plain text，继承查询/TSX/metadata 过滤/零范围保护保留。
- 标为“证据门”的 task：未命中热点时交付复测与保留理由，不制造代码；确有热点则在本 task 完成最小修复和验证。不同根因分开提交。

<a id="p3-t1"></a>
## P3-T1 补齐编辑后的高亮范围更新

**类型 / 依赖:** 正确性实现；依赖 P2 和 P1 基线。

**Files / 锚点:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift：setUp、willChangeContent、didChangeContent、tsClient.invalidationHandler。
- Read-only: Neon Highlighter.didChangeContent / handleTokens / TokenApplication；锁定源码见 build/SourcePackages/checkouts/Neon/Sources/Neon/。
- New: scripts/check-highlighting-ranges.swift，调用真实 Neon Highlighter 与现有 TextSystemInterface 协议。
- Modify: docs/PERFORMANCE.md 的增量路径事实。

**证据:** Highlighter 明确要求每次文本改变调用 didChangeContent(in:delta:)；该方法移动 validSet 并重新处理 pendingSet。Kero 当前只通知 TreeSitterClient，未通知 highlighter。变更后的失效范围重算不能代替所有未变区间的坐标平移。这是已读源码契约缺口，不声称用户已报告错色或已有复现。

**实施与验证:**
1. 先用可控 TokenProvider 的延迟回调复现“在已着色文本前插入/删除”；检查请求覆盖当前视口，而不是仅看 invalidate 被调用。
2. Kero 的同一 edit 通知中，用旧 NSRange 和 delta 调 highlighter.didChangeContent，再由既有 parse invalidation 触发颜色更新。核对 will/did 的旧/新坐标顺序，STTextViewDelegateProxy 先通知 delegate 再通知 plugin 的真实顺序不改。
3. stale 回调不返回 .success(.noChange) 冒充当前结果：它仍会在 handleTokens 标记请求范围有效。TokenProvider 允许零次回调；编辑已经清理旧 pending 并安排新请求时，可直接丢弃旧交付。Neon 的 failure 分支只异步清 pending，不主动启动下一请求，不能假定失败自动重试。沿实际 edit/invalidation 顺序证明新版本最终重请求、不忙循环也不永久失色。
4. 脚本链接真实 Neon/Rearrange/TreeSitterClient/SwiftTreeSitter/TreeSitter 和 Debug swiftmodule，文本接口仅提供可控测试数据；测试初次请求、插入、删除、pending 期间新 edit 和再次 viewport 请求。它验证依赖契约；Kero 桥接接入仍须真实应用验收。
5. 当前已存在以下产物，可在 P1 构建后使用：
   xcrun swiftc -swift-version 5 -I build/DerivedData/Build/Products/Debug -Xcc -fmodule-map-file=build/DerivedData/Build/Intermediates.noindex/TreeSitter.build/Debug/TreeSitter-t.build/TreeSitter.modulemap -Xcc -Ibuild/SourcePackages/checkouts/tree-sitter/lib/include scripts/check-highlighting-ranges.swift build/DerivedData/Build/Products/Debug/Neon.o build/DerivedData/Build/Products/Debug/Rearrange.o build/DerivedData/Build/Products/Debug/TreeSitterClient.o build/DerivedData/Build/Products/Debug/SwiftTreeSitter.o build/DerivedData/Build/Products/Debug/TreeSitter.o -framework AppKit -o build/check-highlighting-ranges && build/check-highlighting-ranges。
   规划时只核对 import 的 typecheck flags 通过，未运行此未来脚本或声称链接验收通过。task 内须跑完整命令并写进运行说明。
6. 真机对 Swift/TSX/Markdown 首/中/尾插删、粘贴、find replace、撤销/重做、连续输入和中文组合输入；滚到原已高亮区域核对位置与保存内容。

**提交边界:** 编辑范围契约修复、脚本与必要说明一次提交，不夹带调度优化。

<a id="p3-t2"></a>
## P3-T2 删除编辑回写中的重复全文比较

**类型 / 依赖:** 小实现；依赖 P3-T1。

**Files / 锚点:**
- Modify: kero/Editor/SourceTextEditor.swift：Coordinator.textViewDidChangeText。
- Verify: kero/Editor/FileViewerView.swift：text、savedText、refreshDirtyState、save。
- Modify: docs/PERFORMANCE.md。

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
- Only if admitted: new kero/Editor/TextCoordinateIndex.swift、scripts/check-text-coordinate-index.swift；现有同步根目录自动接入应用。
- Local evidence: evidence-p3.md；实现后更新 docs/PERFORMANCE.md。

**问题与方法:** position 每次枚举整份文档段落并搜索。测首/中/尾、等字节不同换行数量、超长单行；将转换耗时与 parser 耗时分开。成本最多一轮定位加一轮纯数据原型，若未命中就保留现实现。

**准入后实施:**
1. 优先检查现有 TextKit/依赖是否有不全篇扫描且满足坐标契约的入口；当前公开 position 实现没有索引，不能用改名 helper 假装优化。
2. 如确需索引，只维护当前文档的 UTF-16 行起点，在编辑通知更新受影响片段和后续偏移；二分查所在行。不新建 Rope、不声称数组尾部平移是 O(log N)。
3. will 阶段给旧范围终点，did 阶段给新起点/终点，数据由 coordinator 持有；重建/换文档重置。解析后台只读对应不可变快照，不读 AppKit。
4. 明确 CRLF、LF、bare CR、尾换行和空文本的行定义；对照 TextKit 实际行为与 Tree-sitter 完整解析 oracle。若两者契约不同，不直接复制一个错误列值。
5. 脚本编译真实 TextCoordinateIndex；用固定 seed 多次插删替换与慢扫描 oracle 对比全部关键偏移，含 emoji 代理对、中文、CRLF 边界和尾端。命令：xcrun swiftc -swift-version 5 -o build/check-text-coordinate-index kero/Editor/TextCoordinateIndex.swift scripts/check-text-coordinate-index.swift && build/check-text-coordinate-index。

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

**成本 / 验收 / 提交:** 两个配置各跑同组样本，不展开阈值调参研究；记录选择与延迟。被选中的参数及必要说明独立提交，并安装签名 Debug 验收；只实验无变化不提交。

<a id="p3-t5"></a>
## P3-T5 查询编译的单次在途共享

**类型 / 依赖:** 条件实现；依赖 P1，按默认顺序在根解析复测后。

**Files / 锚点:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift 的 installTokenProvider、finishInstall、injectedHighlightsQuery、pendingInjectionCompiles；SyntaxHighlighting.highlightsData/injectionsData 的资源输入。
- Only if admitted: new kero/Editor/HighlightQueryCache.swift，将现有 HighlightQueryCache 原职责迁出插件，新增的在途合并仍由它拥有。不是新增通用缓存或替换 SyntaxLanguage。
- New with implementation: scripts/check-highlight-query-cache.swift，编译实际 cache 与 SwiftTreeSitter Query；脚本只提供应用语言标识的 Hashable 类型壳，不复制缓存/回调算法。
- Local evidence: evidence-p3.md；实现后更新 docs/PERFORMANCE.md。

**证据门:** 当前只有完成缓存，每 coordinator 有自己的 pendingInjectionCompiles；同语言多文件同时冷开可重复 compile，root injections query 还在 finishInstall 内同步 compile。P1/定向 trace 记录实际编译次数和耗时；没有可观成本则不造缓存框架。

**准入后实施与验证:**
1. 在现有 HighlightQueryCache 加固定 language + query kind 的 in-flight 共享，root/embedded highlights 用同一查询，injections 单独种类。固定进程内资源无需文档 hash、TTL 或预编译全部语言。
2. compile 和必要资源读取离开主线程；cache 管理与 UI invalidate 回主 actor。多个 waiter 得到同一 Query，关闭一个视图不取消其他 waiter 需要的编译。
3. 编译完成/失败后结束 pending，waiter 弱引用 coordinator；失败维持当前 plain/无 injection 降级，不因 invalidate 自旋重编。按固定资源的实际失败原因定义最小重试边界，不建立通用恢复流。
4. 真机一次打开多个同语言文件和同语言围栏：每 key 在途 compile 一次；打开 TS 与 TSX 不共用 grammar；关首个 editor，第二个仍实际着色。未知语言保持 plain。
5. 同 task 接入独立检查：调用生产 cache 的实际请求/完成入口，控制两次请求和一次编译交付，使用真实 Query 值验证同 key 在途一次、不同 kind/语言不串、热命中、失败清理和关闭 waiter 不留住接收者。只有测试调度可控，不把生产编译与缓存替换成另一套算法。
6. 下列命令按已存在的 runtime/JSON grammar 产物安排，脚本可用真实 JSON Query 作为无私有数据的编译 fixture；它证明缓存状态，不证明 TS/TSX 选择，后者仍由真实应用检查。task 内须实际链接/运行；规划未运行未来脚本。

```sh
xcrun swiftc -swift-version 5 -I build/DerivedData/Build/Products/Debug \
  -Xcc -fmodule-map-file=build/DerivedData/Build/Intermediates.noindex/TreeSitter.build/Debug/TreeSitter-t.build/TreeSitter.modulemap \
  -Xcc -fmodule-map-file=build/DerivedData/Build/Intermediates.noindex/STTextView-Plugin-Neon.build/Debug/TreeSitterJSON-t.build/TreeSitterJSON.modulemap \
  -Xcc -Ibuild/SourcePackages/checkouts/tree-sitter/lib/include \
  kero/Editor/HighlightQueryCache.swift scripts/check-highlight-query-cache.swift \
  build/DerivedData/Build/Products/Debug/SwiftTreeSitter.o \
  build/DerivedData/Build/Products/Debug/TreeSitter.o \
  build/DerivedData/Build/Products/Debug/TreeSitterJSON.o \
  -o build/check-highlight-query-cache && build/check-highlight-query-cache
```

7. 用 P1 Debug 计数和 trace 验证并发首次、热 cache、根 injections 与失败路径；真机证明最后视口真的着色，不只以函数返回 Query 或 compile 次数下降验收。

**提交边界:** 单次共享、必要检查与事实说明一次提交，删除原每 coordinator 重复 pending 路径。

<a id="p3-t6"></a>
## P3-T6 嵌入语言复用方案的最小实验

**类型 / 依赖:** 探索；依赖 P3-T1 和查询缓存准入结论，必须先于 P3-T7。

**当前最终路径:** root highlights callback → root injections callback → injectedTokens；每 NamedRange 新 Parser、parse 全 fragment、query 全 token、偏移后由 Neon 写样式。callback 与 predicate prepare 均回主线程。视口 1024 请求可能反复包含同一个长片段，不能只缓存 Query。

**已核对的可复用能力:**
- 现有 SwiftTreeSitter Parser.parse(tree:string:)、Tree.copy/edit、Query.execute 支持子树复用。
- 锁定包另有 SwiftTreeSitterLayer 产品：LanguageLayer.didChangeContent、resolveSublayers、snapshot、ContentSnapshot；当前 Kero 未链接该产品。Layer 会维护子语言与 included ranges，不能把它当作已接入能力。
- Layer 的 resolveSublayers 会按语言收集/合并 ranges；围栏删除/语言切换的清理语义须实验，不能只看到 API 名就信任。
- Neon TokenApplication.noChange 会把请求范围加入 validSet，不能用于掩盖过期结果。

**实验交付:** 在 build/performance/prototypes/ 做一次可丢弃、同样本对照，不改用户应用资源；evidence-p3.md 明确决策和实际输出。
1. 用锁定 Layer、现有 Parser/Tree 两种最小组合比较接入成本与工作量。不更换 root 技术栈，不重复维护 root 树；Layer 若只能靠复制 root parse 才接入，比较总 CPU/内存并优先更小的子区域方案。
2. 长 Markdown fence、两个相同语言不同内容区域、HTML script/style、未知语言、围栏编辑/删除/改语言、区域前插入文本；输出 named ranges 与同版本全量解析 oracle 一致。
3. 同版本反复 viewport 查询计数；代码块内 edit 后检查可复用旧 tree，而非仅“有 cache”；调后台后按内容版本门控 root+child 合并，防止两个独立 root query 中途 edit 混版。
4. 串行拥有可变 parser/tree，query/read 使用 immutable snapshot；记录 token 顺序、坐标/Point 和关闭后释放。
5. 停止条件：各一个小原型、一组正确性与性能对照。任何方案有围栏清理/坐标错误都不能直接接入；两者均不成立就回改 P3-T7 的实际决定与验证，不边实现边赌。

**提交边界:** 只交本地证据与回写后的 P3-T7，不为实验制造 Git 提交。临时依赖源码修改不能成为正式成果。

<a id="p3-t7"></a>
## P3-T7 接入已验证的后台子区域增量路径

**类型 / 依赖:** 实现；依赖 P3-T6 的明确选择，不能先实现“预定 Layer 重构”。

**Files / 接入:**
- Modify: kero/Editor/SyntaxHighlightPlugin.swift 的 injection provider / edit / lifecycle。
- Only if selected: kero/Editor/InjectedSyntaxState.swift，拥有当前 editor 的子区域解析数据；单个真实职责，不写 protocol/factory。
- Only if Layer selected: kero.xcodeproj/project.pbxproj 接入同一锁定 SwiftTreeSitter 包的 SwiftTreeSitterLayer 产品；Package.resolved 必须仍固定当前 revision，不升级其他依赖。
- New: scripts/check-injected-highlighting.swift 与同 task 配套运行命令；编译实际被选子区域实现和现有依赖，不复制其算法。
- Modify: docs/PERFORMANCE.md；需要额外产品/补丁时更新 docs/DEPENDENCIES.md。

**实施:**
1. 按 P3-T6 决策接入，删除原每次 new Parser / full-fragment parse 的旧路径，不能两个实现同时运行。只维护当前文档当前子区域，查询仍由 P3-T5 的实际缓存策略提供。
2. 复用已有 edit range/delta；未受影响区域可移动/复用，片段内 edit 复用树，结构/语言改变作最小重建。无法可靠匹配的区域重建，不按相同 language 或相同起点误用别处内容。
3. 子解析和 query 使用稳定文本在明确后台串行边界执行；一次 document edit 的版本在 coordinator 拥有，用于跨 root+injection+child 的同版合并。这一 guard 服务现有多回调与新后台路径，不另建 workspace generation。
4. 回主线程前丢弃过期或已关闭 coordinator 的结果；通过 Neon 的实际 pending/失效机制保证当前视口最终得到最后版本，不能失败即永久不请求。字体仍不入文本存储。
5. token 只交付当前请求需要的范围，保持子语言覆盖 root 的既有顺序；不要为一个 1024 请求反复发整块数万 token，合法跨边界 token 的剪裁依现有语法/渲染契约验证。
6. 缓存随 editor 释放，只留当前可达区域/树与必要快照；不保存无限文档版本。若视图重建仍是实测热点，先记录与回改专门 task，不能偷偷让全部编辑器永久挂载。

**验收与提交:**
- task 内运行真实实现的脚本：P3-T6 全量 oracle、重复查询/片段内 edit、围栏移除/变语言、未知语言、零范围、Unicode 和故意延迟旧结果；检查输出与 parse 次数。
- 安装签名 Debug，在长围栏与 HTML 中输入/滚动/切页，最终可见颜色、范围、文本、撤销/保存均正确；实际子 parse 不在主线程，同版复访不从头解析。
- 同 P1 样本比较主线程、可见高亮、后台追上、内存和关闭释放；不能只证明分支选择或 cache 命中。
- 实现、接入/旧路径删除、脚本及必要文档一个原子提交；依赖生成不混入。

## 阶段自审与交接

- 逐项核对全量 oracle、最终可见高亮与磁盘文字；快照、root 版本检查不替代跨回调同版合并。
- evidence-p3.md 区分已修复、实测保留、缺权限未验收与仍慢，不把条件措施全部算“已经优化”。
- 实际完成后进入 plan-task-auditor 并创建 audit-p3.md；规划时不创建。
