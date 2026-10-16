# P3 执行证据

原始日志与临时样本：`build/performance/editor-git-20261016/`。继续使用本机 Xcode beta；不要求 stable，不绕过 AMFI 限制。生产提交逐任务写入 `todo.toml`。

## T1：编辑范围与同版交付

- 先读实际 STTextView will/replace/did、STTextKitPlus 的范围／正文读取、Neon Highlighter／TokenProvider、TreeSitterClient 的串行解析和异步 query、SwiftTreeSitter predicate／injection 读取及返回链。
- 当前 NSTextContentStorage 的旧 NSTextRange 可以按同文档 offset 转换。实际尾删、全删、连续排队编辑对照全新 Parser 的 AST、范围与 Point 全部相同；没有复现计划所称的尾删越界。因此删去旧范围缓存的计划，不增加 pendingEditRange。
- 初次自定义测试 storage 使用 NSTextContentStorage 不符合 STTextView 的实际 replaceContents 契约，导致无初始颜色；改为继承产品本来使用的 STTextContentStorage。Swift predicate 样本也调整为查询实际包含的 `Capitalized.method()`。这些测试装配错误不算产品 Red。
- `p3-version-red3.log`：真实生产 provider 过期 failure 仍回调；在真实 predicate 读取期间编辑，旧 success 仍交付一次。5 测试中两项准确失败、无 unexpected failure。不是假造 token-provider mock。
- `p3-version-green.log`：相同 5 项 Green。`p3-injection-green.log`：6 项 Green，增加真实 Markdown injection 读取间编辑、当前嵌入注释色、undo／redo 的实际位置；普通路径也断言编辑后当前注释色，而非只断言 revision。
- 实现只增加一个编辑 revision，通知现有 highlighter 移动 valid/pending；plain/base/injection/最终合并丢弃过期交付。删除 coordinator 失效时 `.noChange` 的伪成功和“同树必同版”的错误说明，不复制依赖队列／版本／pending。
- 独立进程实际截图 `p3-markdown.png` 已查看：标题、围栏语言、嵌入 Swift 注释／关键字／数字、中文与 emoji 显示正常。两个自建 PID 1461／3002 均按进程启动身份正常退出；不操作用户 App。
- 后台输入没有成功：大文档 AX frame 超出窗口；小文档无精确 AX-window receipt。两次均 refusal/no dispatch，重新读取原文未变；未升级到共享前台输入。因此独立 App 替换／IME／保存不宣称 E2E 通过，实际编辑与撤销由原生 XCTest 验证。

全量 `make test`（`p3-t1-test.log`）253 项、0 failures、3 个无专用主机的 SSH skipped；`make build`（`p3-t1-build.log`）和整包 strict 验签通过。仅已有 AppIntents／平台日志，无新增编译诊断。`git diff --check` 通过。

## T2：原始字节与保存／Diff

- 从 SourceTextEditor 的实际 delegate 追到 FileTab 的 dirty、保存快照、clean reload；从原生 Diff delegate 追到模式切换、断线发布、重读、写入完成和 DiffCore／行／token 对比。检查 NativeSurface 的 display UUID／editBufferRevision 消费和底层 STTextView.setString，后两者没有需要替换的 String 相等守卫，不能按文件名遗漏实际消费者。
- `p3-bytes-red.log` 实际复现：规范等价编辑不回写模型／不 dirty／不落盘；外部规范等价 clean reload 不替换；保存期间再次编辑被旧成功清 dirty；真实 Git 原文被判无变化；Diff 原生编辑／切换漏掉变化；行 ops 把字节不同当 equal，重建不等于新原文；intraline 无强调。相同字节对照仍保留。
- 使用标准库 `utf8.elementsEqual` 恢复各拥有者的字节契约；删掉 SourceTextEditor 重复全文前置比较。行 hash 继续只作筛选，随后按字节确认，不新增 hash／normalize／缓冲或路径字符串的全仓替换。
- 初始 Diff 展示测试错误地期待末尾 LF。源码 DocumentBuilder 按行间 LF 拼接，并由 missingNewline 独立表达末尾换行；测试已按实际呈现契约改正，不改产品来迎合错误断言。随后逐次 reload 等待实际新 display，不能用旧的相同外观冒充刷新通过。
- 新的原生 IME 检查还发现 unmark 删正文与显式 final replacement 的独立缺陷；正常 setMarkedText→insertText(.notFound) 路径在 T2 覆盖，独立问题立即加入 P3-T8，紧接 T2 修复，不拖到 P6。Apple 官方 `NSTextInputClient.unmarkText()` 文档及当前源代码确认它应接受而非删除组合文本。
- 原生输入性能实验使用同一 XCTest 目标临时类，不进入产品／提交。内容为 400 KiB／4 MiB ASCII 单长行、900×600、13pt 等宽、不折行，各两批 30 次末尾替换。只记 insertText 返回与模型 dirty／最后字节，不将它叫作光标绘制／高亮稳定；刻意不自动滚动，以分开后续 TextKit 布局。另一个工作树存在并行 XCTest，数字只作带噪观测，不作前后提速结论。
- 精确自有 PID 20446 的 `p3-byte-input.sample` 显示主线程主要落在 TextKit viewport／CoreText caret offsets；这个残余超长行问题没有因本任务正确性修复而消失。不凭静态“少比较一次”宣称整体变快，不新增第二缓冲绕过原生所有权。
- `p3-bytes-perf.log` 临时实验 XCTest 通过。每批 n=30，ms 中位／p95／最差：400 KiB 为 83.001／106.068／148.049 和 98.076／108.258／114.906；4 MiB 为 548.870／576.106／577.193 和 534.458／564.182／568.791。明显仍慢，尤其原生布局；不把这个单长行／无自动滚动的 API 返回当作一般文件输入体验。临时测试已移回 build/performance，不进入长期测试集合。
- `p3-bytes-green3.log`：File 24、Diff 19、DiffEngine 2，45 项全部通过，包括正常组合输入提交到真实文件、两类保存期间规范等价编辑和逐次原生 Diff display 更新。`p3-t2-test.log` 全量 261 项、0 failures、3 SSH skipped；`p3-t2-build.log` Debug 构建及 strict 验签通过，diff-check 通过。独立 App 编辑 E2E 仍受 T1 所述后台 AX 定位限制，不冒称通过。

## T8：即时补上组合输入结束的真实缺口

- 已核对 Apple [unmarkText 契约](https://developer.apple.com/documentation/appkit/nstextinputclient/unmarktext())，并以本机系统 NSTextView 做相同输入的可运行对照，而非只按文案推测。源码追到 STTextView 的标记更新、最终 insert、replaceCharacters 的通知／撤销注册及原生实际副作用。
- `p3-ime-red.log`：3 项中两项共 7 个断言失败。直接 unmark 丢掉中文／emoji；最终默认范围插入文首，显式范围继续删除其后文字，扩大范围也错误；普通无组合输入对照通过。
- unmark 只接受正文／清除临时标记样式；最终 insert 单独移除临时组合串，先把明确的替换端点映射到移除后的同一文档坐标，再执行原本有撤销的最终写入。不增加输入缓冲、会话／generation 或原文副本；旧 unmark 的删正文语义已删除，普通输入没有绕道新状态机。
- `p3-ime-green1.log` 原始 3 项 Green；`p3-ime-green2.log` 组合 53 项 Green，包括：系统 TextView 对照、默认／显式／扩大范围的 undo/redo、临时字体／颜色／下划线恢复、普通输入、FileTab 真实组合提交后磁盘字节、Diff 相邻保存；新增真实高亮插件在组合中规范等价变化、最终中文替换后，对照 fresh Parser AST／Point 并检查当前注释与关键字色。
- 这是原生 NSTextInputClient／TextKit 集成验证，不宣称手动切换某一中文输入法或独立 App E2E 已通过。
- `p3-t8-test.log`：全量 265 项、0 failures、3 SSH skipped；`p3-t8-build.log`／`p3-t8-release.log` Debug 和 Release 构建与整包 strict 验签通过。Release 仅已有 AppIntents 提取跳过提示，无新增诊断。移除测试的无用 App import 后，再运行 `p3-ime-final.log` 验证实际最终源文件；diff-check 通过。

## T3：已准入的坐标索引

### 旧实现的实际成本

先查现有实现和依赖：Neon 在 will 取旧 end、did 构造 start／new end；没有可复用的 LF／UTF-16 行索引。TextKit 段落和 Diff 的显示行不是相同契约。继续沿真实生产 transformer 取证，而不是只测新造的 helper。

临时 `CoordinatePerformanceTests` 进入现有 XCTest 目标；首次错误使用了仅在 STPlugin 内可见的 CoordinatorContext，编译失败后改用真实 coordinator 构造器。这不是产品 Red。`p3-coordinate-before2.log` 原生产转换 540 次比较全部 Green，之后才做性能替代；没有故意改坏旧实现制造 Red。

400 KiB／4,000 KiB 多行 Swift 含中文、emoji、LF，及约 400 KiB ASCII 长行；每组首／中／尾、两批各 n=30，ms 中位／p95／最差：

| 位置 | 旧批 1 | 旧批 2 |
| --- | --- | --- |
| 400 KiB 多行，中 | 5.587／5.654／5.660 | 5.519／5.566／5.579 |
| 400 KiB 多行，尾 | 11.020／11.118／11.123 | 11.018／11.089／11.092 |
| 4,000 KiB 多行，中 | 55.145／56.395／56.414 | 55.375／56.579／56.795 |
| 4,000 KiB 多行，尾 | 111.256／114.734／115.081 | 110.164／112.619／113.265 |
| 400 KiB 长行，尾 | 11.633／11.747／11.771 | 11.643／11.684／11.689 |

文首原来已很快（各组中位约 0.001 ms）；不能把它也说成原来卡顿。

### 最小替代与边界

- `TextCoordinateIndex` 只保留 UTF-16 长度及 LF 后的行起点；二分查字节列。编辑更新受影响起点和后续偏移；不复制正文，不复制 parser／queue／revision，也不保留旧扫描或运行时兼容开关。
- will 使用旧索引；did 从实际 TextKit 快照取正文，先应用原生 replacement，再让现有解析器读取新点。首次解析使用与索引相同的稳定快照。空文档、负／超界、尾端、CRLF／bare CR／U+2028／U+2029、代理对与规范等价输入均不归一化。
- 2 个新 Unit 测试包括 400 个固定 seed Unicode scalar 边界插删替换，逐个 UTF-16 偏移对照直接扫描，再对照真实 fresh Parser 节点 Point；联合原生高亮／组合输入 12 项 Green。`p3-coordinate-after.log` 同样 540 次生产转换全部 Green，查找最大值低于 0.02 ms；多数已接近计时分辨率，不宣称微秒级倍率。
- 首个 work 实验把原生 Swift String 当成 TextKit 快照，UTF-16 迭代表示和生产不同，不能用它推断挂载成本。最终 `p3-coordinate-work3.log` 从真实 NSTextStorage 快照计时，使用同一单遍构建和作用域内标准 Array 可变缓冲移动后缀，不使指针逃逸。
- work3 每批 n=30；4,000 KiB 初建中位 48.705／48.240 ms，文首插入更新 16.284／16.293 ms，中间 8.147／8.187 ms，尾部约 0.001 ms。400 KiB 初建约 4.82 ms、文首更新约 1.65 ms。数组仍有后续行移动成本，尤其大文件文首；这是明确取舍，不造 Rope 掩盖成本。行起点的 Int 载荷约 128 KiB／1.25 MiB，不冒充实际 RSS／峰值。

### 同条件原生输入 A/B

两次只切换生产坐标桥接：旧桥接为 `f87b416` 的正确扫描，新桥接接上该索引。其他 T1／T2／T8 修复、字体、窗口、语法、源文件、默认解析参数完全相同。临时补丁已恢复并清除，不进入产品。真实 STPlugin events → will/replace/did → 当前 Tree，30 次后仍为当前正文；旧精确自有 PID 75240 的 sample 直接捕获多次 transformer 扫描。

每批 n=30、ms 中位／p95／最差：

| 原生尾部 insertText 返回 | 旧批 1／批 2 | 新批 1／批 2 |
| --- | --- | --- |
| 400 KiB | 83.222／84.672／85.482；83.591／85.771／86.517 | 49.597／50.959／51.280；48.910／50.415／50.703 |
| 4,000 KiB | 336.771／350.476／883.277；335.633／340.843／342.910 | 0.368／0.413／0.452；0.368／0.387／0.397 |

日志 `p3-native-input-old.log`／`p3-native-input-new.log` 均 XCTest 通过。每次返回之后另 await actual currentTree，保证没有用旧成功冒充解析完成；但 tree 等待、后续绘制和高亮稳定没有算入表中。明确不自动滚动，因此不把该数字叫作可见光标端到端延迟。400 KiB 仍约 49 ms，而大文档默认后台 parse，下一任务据此定位残余同步工作，不预先认定所有余量都是 parse。

单次挂载观察为 400 KiB 41.0→33.0 ms、4,000 KiB 129.5→66.5 ms；每侧只有一次，不称冷启动统计或纯粹首屏绘制。`p3-t3-test.log` 完整 267 项、0 failures、3 SSH skipped；`p3-t3-build.log` Debug 构建及 strict 验签通过。临时所有测量类已移回 build/performance，diff-check 通过。该轮全量在 T9 新分块边界测试加入前编译；T9 单独验证，不冒称被这 267 项覆盖。

## T9：分块读取怀疑被实验否定

- 沿 `Parser.readFunction` → String.data → FFI Input.read 的真实 EOF／UTF-16 字节链核实。不能因源码用了 String 范围，就直接假定其会截断 Unicode。
- `p3-reader-boundary-red.log` 名字虽预留 Red，实际是 Green；`p3-reader-boundary-bytes.log` 进一步核对完整字节仍 Green，不把它们记为已修缺陷。
- 永久用例使用 1022／1023／2047 UTF-16 前缀、emoji／组合字符／CRLF／ZWJ，初次和前插空格后共 24 个状态。Swift String 与实际 TextKit 快照的分块字节流逐一等于完整 UTF-16；生产插件的 AST、范围、Point 与 fresh Parser 相同，末尾关键字仍实际着色。
- `p3-reader-boundary-final.log` 高亮 8、坐标 2、组合输入 3，共 13 项通过。未改产品代码，最近产品全量 267／0失败／3 SSH skipped 与 Debug 验签仍归 T3；阶段综合测试会发现新增回归，不冒称此前已执行新测试。
- 结论：保留现有 reader，撤回字节快照替代方案；不新增第二正文缓冲、不改第三方 checkout、不把未实施改造算提速。只提交边界回归及测试文档。

## T10：真正复现的排队范围问题

- T4 的进一步原生检查不是只看 currentTree。先把大文档已显示的声明色实际标为 valid，再删除 `func `、在更前方注释中插入 8192 单元，期间不让主 actor 处理完成回调。编辑前恢复默认请求长度。当前 AST 与 fresh Parser 相同，当前 provider 已返回 function.call 色，实际尾部视口却保持 method 色。
- `p3-queued-semantic-red.log` 及恢复生产默认请求长度的 `p3-queued-semantic-default-red.log` 都准确失败 1 项、无 unexpected failure；后者明确打印实际 method 与期望 function.call。不是初始装配、错误主题或异步未完成导致的误判。
- 源头是 Neon `transformRangeSet` 已用 outstandingEdits 算出 transformedSet，却 `return set`；主 actor 消费旧解析结果时，后续 edit 已改变其位置。修复返回真正变换结果，不在 coordinator 另存 edit 列表或用全量重画打补丁。

### 固定依赖的最小本地核心

- 实际 checkout 与先前读取的 DerivedData 路径源码 SHA 相同；固定 `ce8d252c8fd53ea0b6960e02c423315eef11f141`，插件清单精确依赖该修订，公开分支该文件最新提交仍是它。保留同版本核心，不以跨版本迁移掩盖修复。
- `Vendor/Neon` 只保留实际引用的 9 个核心源文件，Xcode 解析结果明确为该本地目录。未引入旧 NSTextView／UIKit 适配、未用 buffer／Region、上游测试语法或另一个测试系统。必要主队列约束保留，旧系统 unsafe actor 桥／可用性包装移除。
- 第一轮最小复制使真实旧坐标回归与许可证用例 4 项 Green，但完整重编译暴露上游弃用游标和 noChange 非 Sendable 全局值诊断。按实际消费者继续清理：只保留一直在用的异步预取查询，删除无调用者的同步查询模式、便捷接口、可关闭失效开关和样式叠加/noChange 路径。
- 现有 SwiftTreeSitter 0.25 的 QueryCursor 在后台生成匹配数组，Node／QueryCapture 保有 Tree／Query；主线程用其公开 resolve 序列读取谓词，读取前后校验同一请求版本。没有把 C 查询搬回主线程，没有新增解析器、队列或 edit revision。根解析同步阈值暂不调整，留给 T4 实测。
- 中间清理遗漏一条已删除 action 的赋值导致编译失败，已删除；`p3-neon-core-green2.log` 36 项全部通过（高亮 9、坐标 2、组合输入 3、Diff 19、身份／许可证 3），本地核心的弃用／并发诊断已消失。
- BSD 原文在上游、Vendor、App 资源源码及实际 Debug 包中的 SHA-1 都是 `4a53954e2562120139a56dd914227e1fa04c0a2c`。AppIdentityTests 确认许可证真实入包。第三方 checkout 的 Git 状态仍为空，没有修改下载缓存或增加构建补丁脚本。

### 诊断边界与验证

当前 beta SwiftPM 对项目已有 STTextView 本地覆盖发出同身份提示，新增 Neon 覆盖也有同类前瞻提示；实际解析／编译均只有本地核心，不是两份运行时并存。沿用项目现有覆盖机制，不为消除未来工具链提示复制整套语法／资源包；升级 SwiftPM 时仍需复核该机制。没有通过 suppress-warnings 隐藏它。

首次完整重编译还显示既有 GitWorkspaceMenuTests 未使用返回值与 PaneRetentionTests weak 可变性提示。前者与初始基线相同；后者在 P2 只新增两处 waitForText，weak 声明原本就有，T10 未改这些声明，不顺手修无关测试。产品编译常规 AppIntents 提取跳过提示保留解释。全量 XCTest、Debug／Release 构建和验签结果完成后追加。

`p3-t10-test.log` 完整 270 项、0 failures、3 SSH skipped；`p3-t10-build.log` 和 `p3-t10-release.log` 两种配置构建及 strict 整包验签通过。Release 明确清掉旧 UIKit 对象产物，实际只编译本地核心；没有残留弃用游标／noChange 并发诊断。Release 许可证 SHA 也与源文件相同。Package.resolved 版本未变，本地覆盖提示及已有平台日志按上述边界解释，diff-check 通过。

## T4：根解析调度

使用同一生产 STPlugin、900×600 原生窗口、13pt 等宽字体、409600 字节重复 Swift 源码和末尾 `let marker`。初始滚动需反复 `scrollRangeToVisible` 直到真实 viewport 包含目标；第一次实验只滚一次，TextKit 估算仍距目标约一万 UTF-16 单元，初始化等待失败，没有把它当产品缺陷或性能数据。修正测量装配后，交替插入／删除 `// `，每组30次、两组；同时等待实际前景色在 keyword/comment 间切换，并对照当前树长度及最终原字节。

`p3-root-default.sample` 对精确 XCTest 宿主 PID 采样，主线程直接出现 processEditSync → applyEdit → Parser.parse 与 computeInvalidatedSet。第一组默认参数被2秒 sample 干扰，中位输入49.485 ms，p95/最大326.757/787.405 ms，不将这些长尾作为无干扰基线。第二组没有 sample：输入中位/p95/最大48.074/49.800/50.779 ms；目标行前景色57.824/60.314/62.355 ms。

仅设现有 synchronousLengthThreshold=0，不增加队列、定时器、解析器或版本状态。`p3-root-async.log` 两组均通过：输入中位/p95/最大0.374/0.448/0.525 ms、0.370/0.390/0.390 ms；目标行前景色52.320/53.663/53.909 ms、52.360/53.150/54.009 ms。保留该参数：真实非空编辑移到原有后台解析，颜色没有因调度显著延后。零长度无变化操作不保证异步；不使用负数魔法值。

这里测的是原生 insertText 返回与目标可见行的实际 rendering attribute，不是物理屏幕完成绘制，也不是完整 App 键盘 E2E 或整份文档所有 token 稳定。每次单次操作收敛后再下一次，连续编辑收敛、undo/redo、IME、Unicode和最后版本正确性另由真实插件回归验证。新增关闭时排队解析的释放检查，临时性能类已移回 build/performance，不留产品调参开关。

`p3-t4-focused.log` 10项原生高亮测试通过；`p3-t4-test.log` 271项完整测试0失败、3项专用SSH跳过；`p3-t4-build.log` Debug构建及strict验签通过。未操作或重启用户App。

## T11：插件链路清理的真实边界

用户要求核对 `STTextView-Plugin-Neon → Neon`。上游固定 `5a30db4ce7908a5414e7b499e2379bdc49991cd1` 的清单仍声明 Neon ce8d252；实际解析是唯一的 Vendor/Neon，不能称两套Neon，也不能声称已删除上游清单链路。上游只导出整个插件产品，没有独立资源产品。TreeSitterResource直接引用20种语言，40个语法／查询模块共139文件、124164111字节（逐文件File.size之和，不是Git压缩大小）；彻底去包需要接管这些资源或另选来源，不能以删引用造成语言缩水。

已提交前的无争议精简：App四处不再import STPluginNeon，颜色沿用同一资源、改为[String:NSColor]，删除Theme／空Fonts／TokenName中转和对应过时说明。没有新增颜色适配器、字体表或兼容分支。插件原适配代码不再被App调用，但上游包产品仍会构建它，**不把应用层引用清理冒充整个依赖去除**。源码体积取舍已发异步问题，用户随后只要求继续，没有明确选择大体积资源接管；先推进其余任务，不擅自搬入。

`p3-palette-before.log` 新等价用例在原实现1项Green；同一20色资源在aqua/darkAqua逐项核对，并覆盖tag/attribute别名、逐层capture降级和plain fallback。`p3-palette-after.log` 33项通过（高亮11、Diff19、输入3），包含实际原生颜色／字体／撤销和Diff侧真实着色。构建与提交完成后补实际结果。

`p3-palette-build.log`／`p3-palette-release.log` Debug／Release构建及strict验签通过，已提交0953fa3。没有新增Swift诊断，既有SwiftPM覆盖前瞻提示不隐瞒。T11仍保留进行中：等待完整资源接管的范围决定；接着推进独立T5。

后续范围收敛：用户只要求继续，没有明确授权大体积语法接管。按AGENTS的最小实现与不缩水语言支持原则，T11以已完成的应用引用／包装删除收尾，必需资源来源保留；公开说明上游包清单链路未删除、只是没有第二份运行时。完整去包属于尚未授权的额外资源所有权变更，不将它暗中实施，也不把它新增为整个性能计划的阻塞条件。不是声称用户选择了某选项。

后续Xcode自行重生成Package.resolved：旧远程Neon pin被删除，originHash同步改变，其余pins的版本／修订／地址逐项diff不变。没有手改生成锁文件；`p3-t12-release.log`实际图仍是唯一Vendor/Neon @ local，Release构建验签通过，76项联合也通过。独立提交这个生成结果，仍不声称上游资源包清单的Neon声明已消失。

## T5：共享查询编译与失败闭环

`p3-query-cold-before.log` 在独立XCTest进程中冷开4个同语言原生编辑器、并发2份Diff context；各编辑器实际comment色与Diff实际capture均确认后结束。临时compile计时显示同一Swift grammar=15编译6次，每次wall time1.521–1.556秒，最终ready1.752秒。并发时间不能直接相加当CPU时间；这里只报告工作次数及观察到的wall time。

在现有文件内把Query owner改为每language/kind一份pending Task或完成结果。`p3-query-failure-red.log` 保留原来“不记失败”的策略，2项单元测试中失败缓存断言实际Red10处：失败后未完成，再请求会重新编译。Green改为保存complete(nil)，不做TTL／资源热更新／自动重试。highlights与injections、TS与TSX各自分键；一个消费者取消不取消共享编译。root、embedded与Diff不再各自detached compile，root injections也不再主线程同步编译。embedded仅保留每视图一次完成通知的等待标记，避免一连串请求挂载重复重画回调；不是第二份编译所有权。

`p3-query-green-and-cold.log` 37项联合通过：其中1项临时冷开实验、2项Query缓存、12项原生高亮、19项Diff、3项组合输入。冷开实验同键只编译1次，0.308秒，全部消费者ready0.496秒；只做一次冷开观察，不写中位数或p95，不把它叫物理绘制E2E。固定资源失败、取消与grammar/kind分离由独立真实Query编译单测证明；另用原生Go编辑器关闭首个消费者后第二编辑器与Diff颜色检查，以及既有Diff原生文档测试覆盖实际接入。

临时计时print与性能类已移回／删除，产品没有诊断开关。未测独立App多标签内存峰值，不用少了Query对象推算RSS。完整测试与Debug验证完成后追加实际结果。

完整重编译暴露GitStatusModelTests:826/827未使用局部量；git blame确认声明来自8734baea（10月14日），本Feature在该文件只新增一次waitForText，不改这两条声明。与既有PaneRetentionTests／GitWorkspaceMenuTests诊断一样单独解释，不为本任务改无关测试。

`p3-t5-test.log` 完整275项、0失败、3项专用SSH跳过；`p3-t5-build.log` Debug构建及strict验签通过。正式全量未包含已移回artifact的临时性能类；永久新测试实际进入目标并执行，diff-check通过。

## T6：长围栏的一个最小原型

204800字节Swift内容包在Markdown围栏，4096次相同两行、含中文与emoji；900×600、13pt真实STTextView与生产插件。先预编译固定Swift Query，避免把资源编译混进片段工作。实际原生初始请求把同一`{17,180224}`片段完整解析／查询／排序两次；无sample的`p3-injection-scroll-diagnose.log`每次541.8／538.4 ms。`p3-injection-before.sample`直接出现主线程injectedTokens→highlights→QueryCapture稳定排序，不把全部耗时误称parser.parse。

完整滚动实验在反向第16次失败；目标80757，实际viewport{171001,1276}，颜色已经正确。去掉整个高亮插件仍在相同位置失败，见`p3-injection-prototype.log`的NAVFAIL。另立T12处理共享原生定位，不能把这个实验记成滚动通过，也不增加等待绕过。

为单独比较高亮流水线，另对真实生产provider请求不同片段内行，双向各30次，核对最终comment色与原始字节；这不是滚动／输入／物理显示时延。`p3-injection-provider-before.log`全部Green：中位/p95/最大529.464/576.511/2328.956 ms、519.453/528.306/528.465 ms。同一片段包括初始请求共62次完整工作；首组最大值包含初始仍在途的自动着色，不用它推算独立纯解析长尾。

唯一原型：在现有coordinator按NamedRange保存当前revision的一份Task结果，复用SDK已有Sendable元数据；fragment稳定String的Parser／QueryCursor只在本Task后台拥有。编辑清理并取消旧缓存，整次交付沿用T1 revision；不引入Layer、第二根树、跨edit增量树、通用服务或新文件。只在读取新fragment后再校验revision，避免可重入TextKit读取把旧请求种进新缓存。Query编译仍复用T5。

原型第一轮仅过滤child、没有裁剪root token，12项既有回归中1项超时；根token覆盖整块会被Neon当作整块valid，不能只给部分child颜色。修正为root与child都裁剪到请求区间，保持child在后覆盖root，不能靠全篇重画掩盖。`p3-injection-prototype-fixed.log` 1项临时双向30次provider与12项既有高亮回归均通过；同片段只工作1次，两个30次请求组中位/p95/最大21.124/21.878/43.606 ms、21.074/21.255/21.256 ms。

结论：T7只接入上述同版结果复用与后台计算，已有净收益；不升级为跨edit子树引擎。约21 ms仍含主线程metadata遍历与根查询，不承诺输入／滚动达到固定帧预算；RSS及关闭后稳态尚未测量。诊断print已删除，原型和性能类归build/performance；产品源码已恢复312fa77，T7先补永久行为回归再接入，不能把原型当作已完成实现。

## T7：当前版本片段缓存接入

永久3项回归先在312fa77运行，`p3-t7-red.log` 29处预期范围断言Red、0 unexpected：旧实现把请求以外的root／child token一起交付。Swift／TSX围栏、HTML script／style逐一与fresh Parser+Query对照实际comment色和交付范围；另覆盖同语言不同片段、等长内容替换、未知语言移除／undo、清空正文，以及关闭时真实editor／coordinator释放。

接入T6方案后，`p3-t7-green.log` 41项联合中1项超时。进一步的`p3-t7-language-probe.log`准确显示第一围栏已是`xxxxx`、其comment色却仍旧，第二正常围栏不受影响；不是等待不足或颜色推断错误。根因是根Markdown AST不把信息字符串的等长内容变化报告为整个child区域失效；裁剪交付后不能再依赖旧的整块root token顺带覆盖child颜色。

修复位于原有根树invalidationHandler：嵌入文档的child结果和样式有效性同属整次contentRevision，新根结果清旧valid标记，Neon只请求当前视口及lookaround，单次仍受原1024长度约束。没有全篇TextKit重画、第二份区域依赖图、第二版本号或重复调用方守卫；普通单语言仍使用精确局部失效集合。这与选定的“编辑清空当前版片段缓存”职责一致，而不是隐藏根树范围变换问题；T10的单语言排队范围回归继续真实执行。

`p3-t7-green2.log` 41项联合全部通过：高亮15、Query缓存2、坐标2、输入3、Diff19。诊断print与临时性能类均不在产品／测试目标；完整XCTest、Debug／Release结果完成后追加。T12的原生定位仍单独待修，不把本次绿色组件验证当完整滚动或独立App E2E。

`p3-t7-test.log` 第一轮完整278项出现1次关闭释放超时，3项SSH跳过，后续构建因&&未运行，不能称完整通过。测试创建窗口的async helper没有像既有关闭回归那样限定AppKit对象的自动释放池；改为在autoreleasepool内创建并返回明确持有的原生内容，原有异步请求、弱引用终态检查和5秒上限不变，不修改产品释放路径、不增加等待。`p3-t7-lifetime-and-boundaries.log` 与12项PaneRetention顺序联合后共27项通过；同轮补了CRLF片段及保留正文而移除围栏／undo的真实颜色边界。第二轮完整测试仍需独立确认，不用定向绿色替代。

`p3-t7-test2.log` 第二轮278项0失败、3SSH跳过，Debug构建及strict验签通过。Release也构建验签通过，但WMO新增ImplicitStrongCapture诊断：base/injections回调仍隐式强持有self，内部Task却声明weak。统一为这些实际异步消费者的显式weak捕获与原位置解包检查，让关闭后回调不再无谓保留coordinator；不加unsafe标注或压制诊断。为避免后段Release诊断导致再次回滚整轮证据，接下来顺序为定向→Release→完整测试→Debug；修正后的结果另记，不冒称此前278已覆盖这次捕获调整。

`p3-t7-ownership-focused.log` 最终41项通过；`p3-t7-release2.log` Release构建及strict验签通过，ImplicitStrongCapture已消失；`p3-t7-test3.log` 最终完整278项0失败、3项SSH跳过；`p3-t7-build2.log` Debug构建与strict验签通过。生产／测试代码不含诊断print，diff-check通过，已原子提交。

## T12：通用定位与文档边界锚定分责

沿真实Find入口、STTextFinderClient、scrollToVisible、relocateViewport、prepareContent、viewport delegate、内容尺寸更新与STTextKitPlus.textSegmentFrame追到最终排版／滚动。SDK头文件说明relocateViewport返回建议锚点，adjustViewport只人工移动viewport；ensureLayout和textSegmentFrame已有目标排版／几何能力。xcdocs符号页正文为空，补读Apple文档及当前beta SDK原文，资料在viewport-relocate-doc.json。

`p3-t12-red.log` 2项永久回归中长文档1项预期Red，0 unexpected。单次调用后只等待排版，不反复重发定位。最初尝试删除显式anchor段不足以解决，`p3-t12-native-green.log`名字预留Green、实际仍Red，未保留这版代码。随后测试装配对齐SourceTextEditor（行号、no-wrap、滚动条和零自动内边距）；`p3-t12-source-config-red.log`仍Red：目标{136681,2}，viewport{135282,1267}，实际目标排版框y98461.286超过visible底98355.5。不是只有颜色／范围断言错误，目标确实在屏幕下方。

通用定位原来调用文档边界helper，该helper会按中间位置重设整个文档高度并人工调整viewport。修复在唯一通用入口：先保留完整内容尺寸，用原生建议锚点移动真实NSView可见矩形，布局当前viewport后再滚动到最终目标框。删除通用路径对边界helper的调用及未经证明的O(1)注释；文首／文末已有独立语义和调用者，不误删仍用的helper。不加重试、延时、状态flag或滚动缓存。

`p3-t12-anchor-green.log` 两项通过。随后增强非空目标的实际排版框可见性检查（不仅检查过绘制viewport范围），fixed-row情形使用Diff真实的无内置行号配置；`p3-t12-combined-green.log`76项联合通过（含1项临时Native长围栏滚动，随后移回artifact）。永久长文档前后各30次均一次请求成功，短文档／文末／固定行高正常；T6原先失败的原生围栏滚动现在也完成双向各30次并核对实际颜色和原字节。

本次Native滚动观察的中位/p95/最大为393.622/678.759/679.586 ms（首次遍历）、52.027/82.891/109.169 ms（逆向已访问区域）；包含TextKit排版、provider和颜色观察。旧版本未完成60次，不把不完整旧实验当可比提速基线，也不拿T6的21ms provider数字冒充滚动时间。这里证明定位正确，不承诺所有滚动达到固定帧预算；未运行全App Find菜单或写入全局查找剪贴板。

`p3-t12-release.log` Release构建及strict验签通过，无新增Swift源码诊断；`p3-t12-test.log`正式完整280项、0失败、3项专用SSH跳过；`p3-t12-build.log` Debug构建及strict验签通过。临时性能类不在正式280项中，diff-check通过，受影响文档同任务同步。
