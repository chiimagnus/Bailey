# P2：单一分段文档接入本机、原生编辑与 SSH

**Goal：** 在原生编辑器和现有保存保护内交付 GB 按需、完整编辑和完整保存，
取消普通文件的 8 MiB 拒绝门槛。

**Non-goals：** 不换控件、不增加全局 Manager，不重做恢复或扩大现有编码清单；
尚未迁移的 Diff 契约由 P3 处理，本阶段不安装／重启正式 App。

**Approach：** 沿真实链先统一文档和原生适配，再接有界 IO，
先使本机与 SSH 同时满足共享 IO 契约，清除全文消费者后才从共同入口开放 GB，
再扩大真实远端生命周期和跨窗口验证。
每次迁移同时删除该链旧真源，不提供两个可写文档或两套保存语义。

**Acceptance：** R1～R5 有本机及获准 SSH 的真实 GB 证据，
原生输入、查找、Undo、保存保护、懒恢复和释放不回退，满足 P1 固定预算。

**Rules／准入：**
- **P1-T1／T2 只证明原生同步访问与稳定 IO 的最小机制，P1-T4 固定接口和预算。**
  这些实际证据足以决定 P2 的对应实现是否启动；不要求 P2 的完整 GUI、真实远端组合和整体验收先在 P1 完成。
  历史记录曾报告原生全文请求、未知末尾与自定义 storage 异常，但对应探针／证据不在当前树；
  这些是复核线索，既不是当前实现的结论，也不是永久禁止分段原生适配的证明。
  仍须以当前 `FileTab → SourceTextEditor → NativeCodeTextView` 最小路径解决未知 UTF-16 总长、
  冷页同步访问、超长段落及首屏可编辑问题；不能仅凭 Monaco Piece Tree 或 TextKit 2 视口布局宣称可行。
- 只要求**正文版本／原生适配／稳定 IO** 三项真实职责，不预定必须各新建一个 Manager／Protocol／文件。
  `TextDocument`、`NativeDocumentStorage`、`WorkspaceFileSession` 仅为下文的候选锚点；
  P1 以最少实际类型确定接口、删除的旧所有者和编译接入，不能为了匹配文件名制造三层壳。
- `FileTab` 继续拥有文档生命周期；原生 storage 只适配同一文档。
  当前原生控件已经是挂载期间的可写正文真源；`bufferedText/savedText` 是未挂载／保存基线等全文持有。
  本阶段移除全文物化及基线成本，不把已有结构误写成两个独立可写编辑器。
- 已有 `TextFileEncoding` 的 UTF-8／BOM、UTF-16 BOM、GBK／GB18030、Shift-JIS、Windows-1252、Latin-1、`mbcs` 和手动重开／另存是**必须维持的功能**；GB 改造不是重新引入 UTF-8-only。
- 每个新类型都要替代并删除对应旧职责，不能只添加转发壳或新协议。
- 复用 WorkspaceBackend的真实双实现边界，不新建通用文件系统、工厂或注册表。
- 每 task先验证最终字节与原生结果，不把基础正确性留给阶段末尾。
  覆盖总集与逐任务核销见 `plan-p1.md#覆盖执行契约`、`plan-p1.md#验证条件总集`；
  每个 task 按分派表完成本块断言，不等阶段末尾补证。

## VS Code 对照后的实现约束

源码与永久链接见 [源码研究](vscode-source-study.md)，
具体机制、真实上游测试和迁移取舍见 [吸收设计](vscode-adoption.md)。
借鉴 Piece Tree 的“不可变片段引用＋局部替换＋范围事件”和 snapshot 的分块保存；
Bailey 的片段 backing 必须能按页读取和回收，不能照搬 Monaco 的全量字符串数组。
原始编码字节、展示 UTF-16、逻辑行和字素边界分别建模；未改片段不能被整篇 EOL 规范化。
文档、增量索引、缓存、Undo、保存快照及派生任务共同纳入 P1 预算，
不以“编辑器 DOM／TextKit 只布局可见区域”代替全进程驻留证据。
快照共享必须满足 Swift actor／线程所有权，不能直接类比 JS 单线程 snapshot 的引用寿命。

VS Code 的 20／50／256 Mi UTF-16 单元阈值、长行截断及 worker 关闭只说明它的降级边界，
不是 Bailey 的新拒绝常量。Find、IME、复制和 Undo 均要追到最后一次范围访问，
避免“先取全文／整条巨行，再截断窗口”。

## 每条链要吸收的机制与删除的成本

| 责任任务 | 具体接入 | 同时删除／缩小的旧成本 | 完成判据 |
| --- | --- | --- | --- |
| T1 模型与原生事务 | [片段汇总、原始 edit 集合、内容身份、锚点、Undo 快照](vscode-adoption.md#model) | 全文保存基线、聚合包围区间重读、两套全文坐标数据 | 局部编辑只消费必要范围；一次事务、原生 Undo、手工改回字节均正确 |
| T2 IO 与保存 | [状态编解码、短 IO、同语义请求合并、完整暂存后发布](vscode-adoption.md#io) | 文本完整 Data 收发、无界等待 Task 链、EOF 即发布 | 末块与收尾完成、旧目标中途可读、最新保存版本与所有等待者结果准确 |
| T3 呈现与派生工作 | [区间失效、可见优先、视口复用、内容锚点、受控后台调度](vscode-adoption.md#render) | 无关范围重新解析／测量、完整 injection、全篇最长行首扫 | 独立动作只触发其依赖；冷页和巨行真实原生结果正确、队列与驻留有界 |
| T4／T5 生命周期 | [源会话代次、共享任务引用、最后使用者释放](vscode-adoption.md#io) | 迟到页保活、旧全文镜像、取消只丢回调 | 重挂载保留、真关闭释放、其它窗口／文档不被取消 |

这是同一文档上的机制组合，不新增面向普通／大文件的两套产品链。
当前已经成立的局部 IME、query 共享、刷新合并和真实取消直接复用。

<a id="p2-t1"></a>
## P2-T1 统一正文真源并接通原生适配

**依赖／范围：** 对应 P1 最小机制与 T4 决策；保留旧打开容量，先证明小文件迁移没有行为回退。

**Files／锚点：**
新增候选 TextDocument、NativeDocumentStorage；
修改 `Bailey/Editor/FileViewerView.swift` 的
`FileTab.text/bufferedText/savedText/refreshDirtyState/writeCurrentText`，
`SourceTextEditor.makeScrollView/Coordinator`，
`NativeCodeTextView.text/attributedText/processStorageEdit`、
`TextFileEncoding` 与 `FileTab.reopen`、
`Bailey/Workspace/Project.swift` 的 `ignoreGitPaths`，
以及 `Bailey/UI/Panes/TabSwitcherView.swift` 的 `filePreview/textExcerpt`。
当前标签切换器会先读取整个 `file.text` 才截断到 7,000 UTF-16 单元；
不能只改编辑器，保留这个隐式全文消费。
新增 `BaileyTests/Editor/TextDocumentTests.swift`，调整实际受影响的文件／原生测试。
新文件同 task接入编译和 XCTest枚举，不留孤立库。

**Red：** 跨片段替换、删空、首中末插入、Unicode非同字节、Undo回原字节、
手工改回、在途保存后新编辑和重挂载。夹具必须经过 FileTab→原生→实际保存，
不能仅直接调用新文档类型。

**实现、接入与删除：**
1. 文档提供范围读取、局部替换、坐标和稳定快照迭代；
   FileTab保留目标、请求代次和保存队列，不再与原生缓冲互相同步完整 String。
   先复用现有范围变更事务，再选择最少的片段／树结构；新增文本、原字节 backing 和索引有明确寿命。
   片段摘要区分原字节长度、UTF-16 长度、原生分隔规则及 Git／parser LF 行；
   共用树上汇总，不把这些语义合成一个 lineCount。
   当前 parser 列按 UTF-16 单元差乘 2，不按 UTF-8 字节数推算。
   局部更新只改相关片段和祖先摘要，结构变化不得重建全部 Fenwick／行起点。
   新增草稿可暂时不能按目标编码输出；仍允许编辑，保存严格拒绝有损转换，
   其未知字节长度／相等性明确表达，不为让索引“完整”而提前拒绝输入。
   不常驻每行对象或完整行起点数组；行数／UTF-16 长度未确定时如实表达，
   冷页、索引补齐、EOF 与取消不得伪装成空文档或已知文末。
   快照／Undo 引用使旧页或旧 backing 继续存活时也计入预算，必要落盘与空间不足有明确结果。
2. 删除 `bufferedText`／`savedText` 及被替代的镜像同步链；
   原生 `NSTextStorage` 和 `FileTab` 不能各保留一份可写正文，
   不留生产环境可调用的全文 `text` 兼容属性。迁移全部调用点，特别是标签预览、
   `.gitignore` 追加、文件刷新及预览获取；只从文档取所需范围／行末信息。
   旧 8 MiB 以内的单入口保存暂沿用现有 `Data` 后端，T2 **在同一入口原位删除**该过渡，
   不另设新旧两条保存链或二次内容所有者。
3. 同一 baseRevision 的原子 batch 使原生变更、文档提交和范围通知保持一次边界。
   IME 实际修改正文的候选更新才提交并推进正文 revision，仅选择／标记范围变化不制造空编辑；
   整个会话按原生行为共用 Undo 分组，无实际可撤销变化不制造历史项；
   回放须按各中间版本顺序预检或先正确组合，不直接排序混合版本的 ranges。
   `insertAcrossSelections` 已排序、拒重叠和逆序应用，保留该逻辑；
   自控批量操作把旧 revision 上的原始 edit 集合传到消费者，
   不再从聚合 `storage.editedRange` 重取两端之间的巨大未改正文。
   事务提交后才通知；失败不能留下正文、索引、锚点各停在不同版本。
   选区、IME 标记、搜索结果和阅读锚点分别指定边界亲和性，
   同一事务更新相关范围，不新建全局装饰树或第二个 UndoManager。
   重挂载不重建文档／Undo，业务对象不反向读取窗口或控件树。
4. 脏状态按**选定编码的原字节**与保存基线判断（包含 BOM／CRLF／仅编码差异），
   不能仅用规范等价 String、哈希或版本递增。
   分开单调 revision、可恢复内容历史身份、保存版本与来源／目标身份：
   Undo／Redo 恢复相同内容身份且编码／BOM一致时可直接识别保存点；
   手工改回、编码变化或身份不同仍按稳定字节契约比较。
   无法局部证明相等时后台比较稳定版本，较早结果不得清除较新草稿。
   快照／Undo 优先引用不可变片段，巨型删除不先拼原文 String；
   pin 住的旧页、编辑片段、落盘空间与快照取得成本全部计量。
5. `.gitignore` 追加、换行选择、干净刷新、非视图等待及 Dock 标签切换器预览接文档范围动作；
   预览只取所需 7,000 单元窗口，不能先组装全文；信息需要遍历时顺序扫描，
   挂载／未挂载均保留原生 Undo。
6. 删除被新适配替代的 P1原型路径；原型回归转为正式回归，不留第二套内容管理器。

**验证：**
先新用例，再 `make test:TextDocumentTests,FileTabPersistenceTests,NativeFileTabTests,NativeEditorCompositionTests,NativePaneRetentionIntegrationTests`。
覆盖 D1／D4／D6、N1／N2、S4～S6、L3；旧容量回归仍须成立，
证明本次纯职责迁移没有悄悄改变策略或 UI。
另在现有类中断言：相邻／同位置多插入、重叠拒绝、两端多选区中间读量、
跨片段 CRLF／代理对、Undo 到保存点、手工改回、改编码但不改文字、
不可编码草稿保留，以及快照取得后继续编辑仍读到原版本。
这些是新事务与资源契约的增量，不重复建立原生输入测试框架。

**文档／提交：**
同 task更新 `docs/features/editor.md` 的内容真源、脏状态、追加与保存；
所有权实际改变时同步 `docs/architecture.md`，不宣称 GB已交付。
针对性验证、通读 diff及 `git diff --check` 后原子提交。

<a id="p2-t2"></a>
## P2-T2 接通本机与 SSH 的稳定源、分页装载和完整保存

**依赖／范围：** T1；同一共享契约在两个生产后端同时落地。
原生全文热点未核销前保留共同的旧打开门槛；内部 IO 使用真实大文件验证。
这不是完整 GB 产品验收，也不把基础远端正确性延后到 T4。

**Files／锚点：**
新增候选 WorkspaceFileSession，修改 `WorkspaceBackend`、
`LocalWorkspaceBackend.readSync/write/runSync`、`SSHWorkspaceBackend.read/write`、
`SSHHostWorkspaces.execute`、`ProcessRemoteCommandRunner.run`、
`RemoteCommands.atomicWriteCommand`；
修改 `FileTab.readContent/loadedContent/reloadFromDiskIfClean/writeCurrentText`、
`TextFileEncoding.decode/encoded` 的**增量**等价协议。
当前没有 `ProcessStdinWriter`；扩展现有**唯一** poll/pipe 所有者，不新建写线程或第二套子进程引擎。
新增 `BaileyTests/Workspace/WorkspaceFileSessionTests.swift`，
更新文件 IO测试、`RemoteCommandsTests` 和所有受影响的受控后端 conformer；
真实远端复用 `BaileyTests/Files/SSHFileTreeLiveTests.swift` 的授权入口。
现有方法以 Windows 命名，不据此宣称 POSIX 已被覆盖；
同文件补 `testAuthorizedSSHSegmentedDocumentAndSaveContract`，
按 P1 的参数传递分别在获准 Windows MSYS2 与 POSIX 主机运行，
先断言真实平台／命令能力，再执行相同文档契约，不新建测试系统。
图片、Git归档等不需要分页的消费者保留现有有界 Data API，不扩大迁移。

当前直接 conformer 为两个生产后端，以及以下测试文件中的具体 fixture：
`Files/{FileTabPersistenceTests,FileTreeTests}.swift`、
`Git/{NativeDiffTabTests,GitExecutionTests,GitBranchActionTests,GitStatusModelTests,DiscardRemoteWorkspaceFixture}.swift`、
`Workspace/{WindowCloseIntegrationTests,SSHFolderPickerTests,WorkspaceIdentityTests,PanelContextTests}.swift`，
均位于 `BaileyTests/`；`NativeDiffTabTests.swift` 内另有 `StagedTransitionBackend` 与
`WindowsCodePageGitBackend`，均按真实调用链检查。当前 2 个生产实现、13 个测试实现；
**先由 CodeGraph 核对变更时的全部 conformer**，而不是靠这张静态清单猜。
接口一旦变化，同 task 更新相应实现；
不能提供默认“读完整 Data 再切片”来绕过 conformer 改造。

**Red：** 源变更（含同大小同 mtime）、UTF-8／UTF-16／GBK／GB18030 跨页编码单元、CRLF／BOM、
声明 `coding: mbcs` 与手动重开／另存、晚发现编码无效或真实二进制、
非普通文件／断链符号链接、保存中新编辑／重命名、
短读短写、空间不足、取消、旧版本发布；先证明故障确实发生在目标 IO 路径。

**实现、接入与删除：**
1. 按 P1确定的协议打开稳定源，文档只保留需要的页、解码和索引；
   资源句柄／临时源／源身份有一个明确 owner。
   同一 FD、mmap、mtime＋size 或分块传输都不自动提供不可变版本。
   本机 clone／快照和远端能力须分别证明；不默认远端文件系统支持 CoW，
   也不能先复制／下载完整 GB 文件再宣称满足“首屏先于全文读取”。
   源在读途中变化必须拒绝混合版本；无法证明稳定性的后端限制如实保留。
2. 文本装载不再经完整 `Data → String`。
   本机 `LocalWorkspaceBackend.readSync` 目前打开任意路径就尝试读完整内容，
   应在同一文件会话入口依实际 `stat`／FD 类型区分普通文件、符号链接、
   目录、FIFO／socket／设备：验证无法把非普通对象挂起为无响应读，也不得保存覆盖。
   `TextFileEncoding` 先从有界前缀识别 BOM／首两行声明，必要时查询远端代码页；
   分段解码、局部修改及流式重新编码均以该选择为真源，
   覆盖 UTF-16 编码中的合法零字节（保留对正文 U+0000 的既有拒绝）、跨页多字节字符、严格往返及无法编码拒写；
   当前 `TextFileEncoding.contradictsDeclaration` 先构造 `Data(text.utf8)` 再截前缀，
   也要改为真正有界的首两行／512 字节读取。
   UTF-16 代理对、CRLF、BOM 和编码器状态跨页保留；验证和保存严格拒绝有损转换。
   前缀可判断候选编码，不等于尾部全部合法；晚发现无效字节必须保留草稿并阻止不完整发布。
   发布前必须完成所选稳定源全部字节的严格校验，未改片段直接复制原字节也不能跳过；
   源校验完成与输出快照完整写出是两项独立条件，不能只验证被访问或重新编码的范围。
   不使图片扩展名的大文本先经 `.max` 全量下载再回退。
   保留真实图片预览及既有错误分类，不扩大到新增图片能力。
3. 部分可见、验证／索引进度、完整性和失败只增加必要事实；
   现有 content、reloadError、readOnlyReason能表达时不重复状态机。
   未访问区域失败保留草稿，取消不发布半份结果。
4. 保存先检查可写资格与原目标，完成既有输入／声明准备后再冻结实际版本；
   明确不可写时不得先顺序扫描 GB 正文。
   `FileTab.lastSaveTask` 已提供串行基础，在同一 owner 合并普通同语义保存：
   一次运行、至多一个最新 pending，目标／编码／动作语义相同才可合并，
   普通可合并请求跟随取得执行权并完成准备后捕获的最新快照，
   不承诺逐一发布入队时的中间 revision；被合并等待者接收该轮真实结果及实际发布版本，
   失败／发布确认未知也如实返回。显式固定版本、编码变更、文件操作和关闭保护仍是串行屏障，
   不得被“最后一个请求”静默吞掉。
   取得执行权后才创建快照，替代逐请求捕获 preceding 的无界等待链。
   保存迭代冻结快照，按**原文编码与 BOM 语义**校验、转换，编码和 IO 明确离开主 actor，
   完整成功和目标核对后原子发布；在途新编辑仍脏。
   原位删除 T1的有界 Data保存适配，不拼完整 Data、不改成局部覆盖写。
   复用已恢复的 `5f1024e0`：`RemoteCommands.atomicWriteCommand` 已使用
   私有 `mktemp -d` 暂存目录、trap 清理、普通非符号链接目标的 mode 位继承及明确的目标替换语义。
   固定 `.bailey-tmp` 覆盖漏洞已经修复；本 task 改的是完整 `stdin: Data` 到有背压的快照流，
   不重做修复、不重新引入共享临时名。
   现有命令在 `cat` 正常 EOF 后直接发布，EOF 本身不证明增量编码／生产已完整成功；
   新流协议必须在完整结束、预期长度与校验确认后才能发布。
   以真实屏障验证“晚发现编码错误／上游取消→stdin 早 EOF”不会把半文件换成正式目标。
   两次同目标写入、临时名碰撞／预置链接及清理失败仍保留回归。
   保持既有可写资格及实证的权限／链接语义，区分 symlink、hard link、元数据和目录项替换；
   不将 rename、fdatasync 或命令退出成功写成未验证的崩溃持久化保证。
5. 区分缓存淘汰、源版本变更和 View重挂载；
   同字节刷新保留对象／Undo，重复激活不重传或重解码全部。
6. 本机与 SSH 均接入稳定源、范围读取和流式原子保存。
   远端块有背压与并发预算，不每行／每页启动 SSH、不攒完整 stdout／stdin；
   复用现有单进程 stdin／stdout／stderr 泵、取消和退出确认，不建立兼容版全读模式；
   超时区分连接、无进展和持续推进，不修改无关 Git／目录命令的时限。
   短读／短写按实际字节推进 source offset 和 destination position；
   预期长度内提前 EOF、零进展写入和 producer 失败有明确终态。
   末块写完、在途 IO settle、句柄关闭／本次命令退出属于同一次操作的完成条件。
   区分源读取、编码、送入 pipe、远端确认写入／发布各层进度，
   没有远端确认时不能把本机 pipe 字节计数称为远端保存完成。
7. 保存前检查冻结源与目标身份，覆盖同大小／同 mtime 改写和检查后外部写入；
   区分应用内保存串行化、外部冲突检测和真正的条件发布。
   普通“检查→rename”没有原子 compare-and-swap，若平台／协议无法关闭该竞态，
   必须给出具体语义和残余窗口，不声称已消除任意外部并发覆盖。
   区分发布前失败与发布后确认丢失；后者核验实际目标和源版本，
   不虚报原文件未变、不自动重试覆盖较新目标，不因不确定而清除草稿。
   取消只终止本次生产者，不动共享 master；故障后不回退本机。
8. 删除两个后端**文本链**旧全读／全写旁路和 T1 的 `Data` 保存适配。
   不得误删图片、小型元数据和既有 Git 命令所需的独立 `read/write/runLimited` 路径，
   也不得为新文本协议保留默认全文 fallback。
   明确承诺原子发布的操作失败时不降级为先删目标、copy/delete 或普通弱 rename；
   跨卷／后端能力不足在 mutation 前反馈，保留源和旧目标。
   不照搬上游 capability 注册表；在两个现有实现内表达实际可证明的强操作即可。
   WorkspaceError.tooLarge和其它业务的有界读取契约继续保留。
   不增加 backend 类型检查、远端 unsupported 占位或先全读再切页的默认实现。

**验证：**
`make test:WorkspaceFileSessionTests,TextDocumentTests,FileTabPersistenceTests,NativeFileTabTests,RemoteCommandsTests`；
获授权后 `make test:SSHFileTreeLiveTests`，缺必需后端证据不能进入 T3 解除共享门槛。
覆盖 E1／E2／E4、D、I、S、R；两个后端使用同一文档／IO 契约断言，
小预算下遍历超过预算的真实正文，同时检查缓存、快照和完整目标。
复用已有 `FileTabPersistenceTests` 的 BOM／编码／重连／保存保护与
`RemoteCommandsTests` 的 pipe 取消、限额、stdin／stdout／stderr 交错测试；
新增的仅是分段源、特殊文件不会阻塞和 GB 真实保存的未覆盖断言。
短读写断言具体 offset／position、最大在途写数量和 write-finished→close 顺序；
保存屏障在暂存已有真实字节时读取旧目标，验证它仍完整；
同版本重复保存可用一旦被消费就失败的 reader 证明没有重复准备。
另测大量相同保存请求与在途新版本、显式编码、文件移动屏障的组合，
所有等待者有终局且末次应保存版本实际写出。
短读写、进展／无进展、断线、旧结果及共享 master 取消在本 task 已须成立；
注入与安全可得的真实系统错误分别报告，T4 只扩大组合，不代补正确性。

**文档／提交：**
同 task更新 `docs/features/editor.md` 的装载、校验、保存与刷新；
同 task 更新 `docs/features/ssh.md` 的稳定源、传输、超时、取消及发布确认；
后端职责确变时同步 `docs/architecture.md`，未改变的图片能力不重写。
验证后原子提交。

<a id="p2-t3"></a>
## P2-T3 清除全文原生热点，从共享入口开放 GB 编辑

**依赖：** T1／T2及 P1 已证明的原生同步范围访问／超长行机制与冻结预算。
完整查找、IME 和交互组合由本 task 交付，不要求 P1 先完成同一套产品实现。

**Files／锚点：**
`NativeCodeTextView.configureWrapping/processStorageEdit/setMarkedText/finishComposition`、
`NativeMeasuredLineWidths`、`NativeTextLineIndex`、`TextCoordinateIndex`、
`SyntaxHighlightCoordinator.init/didChangeContent/injectedCaptures`、
`SourceTextEditor`、`EditorFind`、`FileTab.maxTextBytes/loadedContent`；
还须复核 `NativeCodeTextView.setLongLineTruncation` 的全段样式遍历、
`NativeMeasuredLineWidths` 的全行测量和 `SyntaxHighlightCoordinator.didChangeContent` 的全文 `String`／parser read handler。
以上是正文加载的最后一条共同瓶颈链，不限于 `FileTab.readContent`。
扩展现有 Editor各测试及 NativeFileTabTests，不为覆盖率机械增加目录。

**Red：**
真实 1 GiB按需首屏、跨页输入、整篇替换、IME、Find、Undo、保存与重开，
访问计数证明局部操作没有全文解码、语法树、组合快照或行宽测量；
另保留 8 MiB+1的用户入口拒绝 Red，不能只测页接口。

**实现、接入与删除：**
1. 原生行／段落消费者接 T1 的片段摘要，剩余宽度和几何改用 P1实证的有界视口工作，
   删除首屏／局部编辑的整篇扫描和 per-line常驻对象。
   原生视图与容器仍同一有限宽度，长行命中和偏好语义不变。
   将正文、语法、几何和仅绘制失效分开，保留现有几何请求合并；
   滚动／选区／主题不触发正文索引重建，字体／折行才使相关几何失效。
   视口重叠区复用片段和颜色；cache key 覆盖真实片段身份、范围、字体／宽度和语法依赖。
   扩展既有 RestorableScrollView 为“当前内容锚点＋fragment 内像素偏移＋几何代次”，
   防止冷页高度修正、前方编辑及重挂载让旧恢复任务覆盖新用户滚动。
2. 保留 `24014251` 已恢复的局部 IME Undo：`finishComposition` 已基于 composition edits 回放，
   不再把删除旧全文 CompositionSnapshot 写成待办。
   本 task 将该输入与 Undo 会话扩展到跨页／冷页、标记范围、候选取消和快照寿命；
   大范围 Undo 使用共享或可落盘片段，不能把巨大选区直接复制为一个 String。
   测 AppKit 实际访问的输入上下文，不因普通键入局部化便推断所有 IME／AX 请求有界。
   不通过缩减 Undo、禁用多选区或 IME达标。
3. Find／Replace保留实际可达选项和原生栏，范围访问、扫描、结果与全部替换有界；
   依 P1 的真实访问记录接通 finder，不增加本来没有的搜索选项来扩大范围，
   也不以缩水 UI 绕过原有能力。
   单次 Replace All 冻结版本，扫描和替换结果不能全文驻留；
   大量匹配、跨页匹配、取消和 Undo 一起验证，不能照搬 Monaco 的全文 String.replace fallback。
   复制／粘贴只取确需范围；巨大选区的显式导出成本与日常编辑成本分别记录。
4. 保留 Tree-sitter 增量编辑、共享 query、highlightRevision 和临时 rendering attributes；
   按 changed ranges 合并失效，只有上下文仍可能改变时继续传播。
   缩小 injection 的 `.all` 失效及全任务清空到真正受影响的 fragment／依赖；
   外层语言或边界改变时正确扩大，不能把 IO 页当语言边界。
   大文件不默认创建完整 Tree-sitter树或解码整块巨大 injection；
   上下文无法正确解析时按预算回到纯文本并说明，
   编辑、Undo和保存继续可用；普通文件增量高亮不回退。
   可见范围先算，邻域预取其次，其余扫描按有界输入／输出批次推进；
   对不可中断 parser 调用单测最坏量，不能以“后台”代替预算。
   只有固定合并仍造成明显重复排队时，在现有调度点引入上下界明确的耗时反馈；
   输入、IME、显式保存不等待自适应 debounce，停止输入后的结果也不得饥饿。
5. 取消落到索引、解析、预取、搜索的生产任务；
   不取消其它标签的共享 query编译，不只是丢回调。
   同身份页请求复用在途 producer；最后使用者退出才释放共享工作，
   单个标签取消不能清掉其它标签仍用的 query／backing。
   无视图时停止可丢弃视觉预取，保存与来源验证按真实事务继续。
6. 本机与 SSH 完整原生能力及数据验证成立后，
   从共享 `FileTab` 删除旧容量拒绝，所有普通文本入口遵循同一策略。
   `TabSwitcherView.filePreview`、`.gitignore` 和图片扩展名文本回退也必须是分段路径，
   不得留隐藏全文“快路径”。
   资源错误准确反馈，不换更大的常量，不新建按机器分流的放行规则。

**验证：**
`make test:TextDocumentTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,TextCoordinateIndexTests,FileTabPersistenceTests,NativeFileTabTests`。
总集 D、N、I1／I4、L及关联 E3；字节与实际像素共同验证，
高亮降级／不降级均测。
在已有颜色／几何测试增加读取量与失效计数：
主题不重新解析、滚动只新增边缘需求、未变 injection 保留、
上下文变化不会过早停止、旧内容／几何代次不回写。
同时检查热输入 p95、单批最坏耗时、取消后继续处理量与停止输入后的完成延迟。
静态搜索全文 String只能找遗漏，不能替代计数、原生运行和 Allocations。

**文档／提交：**
同 task更新 `docs/features/editor.md` 的容量、索引、IME、Find和高亮；
`docs/ui.md` 仅记录实际新增的进度／错误语义，
本地化在 `Bailey/Resources/Localization/{Editor,Workspace}.xcstrings`。
验证入口改变同步 `docs/testing.md`。
小文件、本机和授权 SSH 的 GB 闭环通过后原子提交，不等 T4／T5 才证明正确。

<a id="p2-t4"></a>
## P2-T4 核销 SSH 恢复、共享连接与资源隔离的交互组合

**依赖：** T2／T3；真实远端验证需明确主机、专属 socket、临时目录和空间授权。
两后端 IO 已由 T2 实现、共享入口已由 T3 验证；本块不再承诺首次接通它们。

**Files／锚点：**
`WorkspaceFileSession` 的远端接入、`SSHWorkspaceBackend`、
`SSHHostWorkspaces.execute`、`ProcessRemoteCommandRunner.run`、
`LocalWorkspaceBackend.runSync`、`RemoteCommands`，
`FileTab.rebindWorkspace/setReadOnly/updatePath`。
测试使用 `RemoteCommandsTests`、`FileTabPersistenceTests`、
`SSHFileTreeLiveTests` 和 T2的受控 session测试。

**Red：** **只验证 T2 单文档协议测试无法证明的交互**：两文件／两窗口共用连接时，
取消其中一项下载、保存或项目关闭；同时另一项继续、重连并发生新编辑；
核对在途任务的精确所有权和旧目标不可写。单文档短读写、格式和原子发布不在此重新实现。
已读 `SSHGitRecoveryLiveTests` 的 private `InterruptibleSSHRunner`：
它只令后续 `run` 失败，不能证明已经运行的传输中断或 producer 被取消。
本块另以受控屏障确认在途阶段，再关闭本次拥有的通道／子进程；
旧 fixture 仅复用为拒绝后续请求的证据，不复制或扩大其 private helper。

**实现、接入与删除：**
1. 将 T2 已实现的契约扩展为 Windows MSYS2／可用 POSIX 主机上的**双文件／双窗／共享 master**交错场景，
   核对本次任务取消后其它文档和 query 照常运行；不重复 T2 的单文件格式／边界矩阵。
2. 冻结原机器、连接和源版本；重连不重建用户文档，
   新通道不能悄悄覆盖用户已编辑的旧源片段。
3. 核销**跨文件**读／写／预取／索引／关闭各阶段的慢进展、停顿、断线和重连组合，
   连接错误与正文错误不混淆；不以模拟 shell 代替两类真实系统证据。
4. 在**另一文件仍在写入**时验证发布前失败保留原目标；发布后断线／确认丢失核对真实远端完整版本，
   保留草稿／Undo和明确错误，禁止盲重试或声称副作用已撤回。
   清理失败记录本次确切路径，不清理未知目录，不回退本机。
5. 取消终止本次 producer，共享 master、query和其它文档继续存活；
   核对已经删除的完整 Data 收发／旧门槛未从恢复路径重新进入；
   其它业务有界 Data API 保留。

**验证：**
受控先 `make test:WorkspaceFileSessionTests,RemoteCommandsTests,FileTabPersistenceTests`；
授权后 `make test:SSHFileTreeLiveTests,NativeFileTabTests,NativePaneRetentionIntegrationTests`。
总集 E4、D、I、R、S；读取／写入×断线／重连×新编辑组合必须核销。
检查远端流式哈希、重开、master存活和清理，不仅检查接口成功。

**文档／提交：**
同 task 更新 `docs/features/ssh.md` 中实测改变的重连、共享连接与清理契约，
editor文档仅导航远端契约。无实机授权时保留成果但验收未完成，
不把 skip当全面支持。经验证的实现与文档原子提交。

<a id="p2-t5"></a>
## P2-T5 闭合工作区生命周期与完整 App 用户路径

**依赖／边界：** T1～T4；扩大集成和不可替代 GUI覆盖，不替前几 task补基础正确性。

**Files／锚点：**
`Project.openFile/openLocalFile/makeContent/ignoreGitPaths`、
`WorkspaceApplication.saveBeforeGitAction/reloadAfterGitAction`、
`WorkspaceWindowModel` 的保存／关闭入口和 `PaneContent.save`。
扩展 `BaileyTests/Workspace/{NativePaneRetentionIntegrationTests,FinderDeliveryIntegrationTests,WindowOwnershipIntegrationTests}.swift`、
`BaileyTests/Files/FileTabPersistenceTests.swift`、
`BaileyUITests/Editor/EditorNavigationUITests.swift`、
`BaileyUITests/Support/WorkspaceUITestSupport.swift`。
只改新文档实际影响的动作，不趁机重构全部窗口。

**步骤：**
1. Files／Finder／恢复真实入口打开 GB 文件；切标签、Dock、窗口激活
   不重复全读／重建文档，原机身份和 Undo 保留。
   选择目录／FIFO／socket 等非普通文件时，验证入口迅速给出可理解失败，
   不让 UI、读任务或关闭保护永久等待；宿主能证明的情况不另建整套 GUI 测试。
2. **仅核销应用级组合**：自动保存、Git 前保存、文件操作互斥、同路径不同草稿、
   关闭中其它窗新草稿均核对最终字节和关闭否决；底层单文件保存已经由 T1～T3 证明，不重复一套协议测试。
3. 持有旧宿主／scroll view，真关闭后检查正文、解析、页缓存、临时源释放；
   重挂载相反，必须保留原文档。
   视图释放、文档退役、最后 backing 引用释放分别验证：
   保存／Undo／在途读取仍持有的版本不提前关闭；最后使用者结束后才关 FD／删本次临时源。
   迟到的源创建也必须关闭新到句柄，不能仅丢 UI 回调。
   复用现有刷新合并和 reload／target 代次，页与索引只进入创建它的会话。
4. GUI 只补真实入口→GB 首尾键盘编辑→Find 定位修改→Undo／Redo→⌘S→关闭／重启重开，
   以及 Dock 切换器的局部缩略预览不触发全文解码。
   文件流式核验，不读 XCUI textView.value或整篇 String；
   夹具生成／校验扩展现有测试支持，不搭另一套 GUI脚本系统。
5. 远端 GUI、两窗前台保存、真实中文候选按授权及可行条件逐项执行；
   每项未执行说明原因和影响，宿主不冒充 E2E。
6. 阶段内运行适用完整宿主和隔离优化测量；P3尚未完成，
   不把全产品写成已交付，不在此阶段提前更新正式安装。

**验证：**
`make test:FileTabPersistenceTests,NativeFileTabTests,NativePaneRetentionIntegrationTests,FinderDeliveryIntegrationTests,WindowOwnershipIntegrationTests`；
GUI为 `make test:ui ONLY_TESTING=BaileyUITests/EditorNavigationUITests`，
只在独占桌面和隔离 Dev执行，新方法须被实际枚举。
总集 E～L中全部普通编辑条件和组合逐项核销，再执行 `make test`。

**文档／提交：**
同 task更新 editor的编辑／保存／释放；恢复格式真的改变才更新
`docs/features/session-restore.md`，默认保持旧格式。
测试入口改变同步 testing；证据写 `evidence-p2.md`。
只提交实际修复的本功能问题，纯证据不制造代码或空提交。

## 阶段审计

实际审计时才生成 `audit-p2.md`。
核对 R1～R5、P1预算、总集缺口、唯一所有者及每条被删除路径。
只读、全文驻留假分页、取消不收敛或完整保存缺证据，均不能无保留放行。
若新证据推翻 P1，先回写计划与取舍，不用临时旁路绕过。
