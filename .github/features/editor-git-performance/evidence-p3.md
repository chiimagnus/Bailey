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
