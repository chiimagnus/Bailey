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
- **必须取得 P1-T1／T2 的技术 Gate 通过证据**，而不只是 `todo.toml` 中任务标记为 completed；
  P1-T4 固定受支持的原生分段编辑路线后才能实施。
  现有 P1 原型证明：普通 `NSTextStorage` 接口被频繁请求全文，
  未知 UTF-16 末尾被当作真实文末；直接自定义 `NSTextContentManager` 被 `NSTextView` 拒绝，
  初版自定义 `NSTextContentStorage` 范围又引发 AppKit 异常。
  因此这些都不是可直接套用的生产分页方案，后续须先拿出实际通过的原生适配。
  下面是有源码锚点、顺序与验收的条件任务，不是已证明可行的技术路线。
- 只要求**正文版本／原生适配／稳定 IO** 三项真实职责，不预定必须各新建一个 Manager／Protocol／文件。
  `TextDocument`、`NativeDocumentStorage`、`WorkspaceFileSession` 仅为下文的候选锚点；
  P1 以最少实际类型确定接口、删除的旧所有者和编译接入，不能为了匹配文件名制造三层壳。
- `FileTab` 继续拥有文档生命周期；原生 storage 只适配同一文档。
- 已有 `TextFileEncoding` 的 UTF-8／BOM、UTF-16 BOM、GBK／GB18030、Shift-JIS、Windows-1252、Latin-1、`mbcs` 和手动重开／另存是**必须维持的功能**；GB 改造不是重新引入 UTF-8-only。
- 每个新类型都要替代并删除对应旧职责，不能只添加转发壳或新协议。
- 复用 WorkspaceBackend的真实双实现边界，不新建通用文件系统、工厂或注册表。
- 每 task先验证最终字节与原生结果，不把基础正确性留给阶段末尾。
  覆盖总集与逐任务核销见 `plan-p1.md#覆盖执行契约`、`plan-p1.md#验证条件总集`；
  每个 task 按分派表完成本块断言，不等阶段末尾补证。

<a id="p2-t1"></a>
## P2-T1 统一正文真源并接通原生适配

**依赖／范围：** P1 Gate；保留旧打开容量，先证明小文件迁移没有行为回退。

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
2. 删除 `bufferedText`／`savedText` 及被替代的镜像同步链；
   原生 `NSTextStorage` 和 `FileTab` 不能各保留一份可写正文，
   不留生产环境可调用的全文 `text` 兼容属性。迁移全部调用点，特别是标签预览、
   `.gitignore` 追加、文件刷新及预览获取；只从文档取所需范围／行末信息。
   旧 8 MiB 以内的单入口保存暂沿用现有 `Data` 后端，T2 **在同一入口原位删除**该过渡，
   不另设新旧两条保存链或二次内容所有者。
3. 原生变更只发一次既有 NSTextStorage事务。
   重挂载不重建文档／Undo，业务对象不反向读取窗口或控件树。
4. 脏状态按**选定编码的原字节**与保存基线判断（包含 BOM／CRLF／仅编码差异），
   不能仅用规范等价 String、哈希或版本递增。
   无法局部证明相等时比较稳定版本，较早结果不得清除较新草稿。
5. `.gitignore` 追加、换行选择、干净刷新、非视图等待及 Dock 标签切换器预览接文档范围动作；
   预览只取所需 7,000 单元窗口，不能先组装全文；信息需要遍历时顺序扫描，
   挂载／未挂载均保留原生 Undo。
6. 删除被新适配替代的 P1原型路径；原型回归转为正式回归，不留第二套内容管理器。

**验证：**
先新用例，再 `make test:TextDocumentTests,FileTabPersistenceTests,NativeFileTabTests,NativeEditorCompositionTests,NativePaneRetentionIntegrationTests`。
覆盖 D1／D4／D6、N1／N2、S4～S6、L3；旧容量回归仍须成立，
证明本次纯职责迁移没有悄悄改变策略或 UI。

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
2. 文本装载不再经完整 `Data → String`。
   本机 `LocalWorkspaceBackend.readSync` 目前打开任意路径就尝试读完整内容，
   应在同一文件会话入口依实际 `stat`／FD 类型区分普通文件、符号链接、
   目录、FIFO／socket／设备：验证无法把非普通对象挂起为无响应读，也不得保存覆盖。
   `TextFileEncoding` 先从有界前缀识别 BOM／首两行声明，必要时查询远端代码页；
   分段解码、局部修改及流式重新编码均以该选择为真源，
   覆盖 UTF-16 合法 NUL、跨页多字节字符、严格往返及无法编码拒写；
   不使图片扩展名的大文本先经 `.max` 全量下载再回退。
   保留真实图片预览及既有错误分类，不扩大到新增图片能力。
3. 部分可见、验证／索引进度、完整性和失败只增加必要事实；
   现有 content、reloadError、readOnlyReason能表达时不重复状态机。
   未访问区域失败保留草稿，取消不发布半份结果。
4. 保存迭代冻结快照，按**原文编码与 BOM 语义**校验、转换，编码和 IO 明确离开主 actor，
   完整成功和目标核对后原子发布；在途新编辑仍脏。
   原位删除 T1的有界 Data保存适配，不拼完整 Data、不改成局部覆盖写。
   临时目标由本次写事务独占，不沿用远端固定 `.bailey-tmp` 名称：
   P1 已用真实 `SSHWorkspaceBackend.write`＋受控本机 Shell 复现
   **预置 `target.bailey-tmp` 符号链接会覆盖无关文件**，并非纯理论风险。
   同一职责中删除危险旧命令，不加单纯 `-e` 前检查；
   两次同目标写入、临时名碰撞／预置链接及清理失败在本块验证。
   保持既有可写资格及实证的权限／链接语义，不擅自扩大元数据保证。
5. 区分缓存淘汰、源版本变更和 View重挂载；
   同字节刷新保留对象／Undo，重复激活不重传或重解码全部。
6. 本机与 SSH 均接入稳定源、范围读取和流式原子保存。
   远端块有背压与并发预算，不每行／每页启动 SSH、不攒完整 stdout／stdin；
   复用现有单进程 stdin／stdout／stderr 泵、取消和退出确认，不建立兼容版全读模式；
   超时区分连接、无进展和持续推进，不修改无关 Git／目录命令的时限。
7. 区分发布前失败与发布后确认丢失；后者核验实际目标和源版本，
   不虚报原文件未变、不自动重试覆盖较新目标，不因不确定而清除草稿。
   取消只终止本次生产者，不动共享 master；故障后不回退本机。
8. 删除两个后端**文本链**旧全读／全写旁路和 T1 的 `Data` 保存适配。
   不得误删图片、小型元数据和既有 Git 命令所需的独立 `read/write/runLimited` 路径，
   也不得为新文本协议保留默认全文 fallback。
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
短读写、进展／无进展、断线、旧结果及共享 master 取消在本 task 已须成立；
注入与安全可得的真实系统错误分别报告，T4 只扩大组合，不代补正确性。

**文档／提交：**
同 task更新 `docs/features/editor.md` 的装载、校验、保存与刷新；
同 task 更新 `docs/features/ssh.md` 的稳定源、传输、超时、取消及发布确认；
后端职责确变时同步 `docs/architecture.md`，未改变的图片能力不重写。
验证后原子提交。

<a id="p2-t3"></a>
## P2-T3 清除全文原生热点，从共享入口开放 GB 编辑

**依赖：** T1／T2和 P1原生、长行、查找、预算 Gate。

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
1. 行／段落索引和宽度改用 P1实证的分页摘要／有界视口工作，
   删除首屏／局部编辑的整篇扫描和 per-line常驻对象。
   原生视图与容器仍同一有限宽度，长行命中和偏好语义不变。
2. 组合输入和大范围 Undo 使用范围事务、共享或可落盘片段；
   删除 CompositionSnapshot全文及复原时的全文比较，
   不通过缩减 Undo、禁用多选区或 IME达标。
3. Find／Replace保留实际可达选项和原生栏，范围访问、扫描、结果与全部替换有界；
   需要的 finder适配须由 P1证明，不能临时增加缩水查找 UI。
4. 大文件不默认创建完整 Tree-sitter树或解码整块巨大 injection；
   上下文无法正确解析时按预算回到纯文本并说明，
   编辑、Undo和保存继续可用；普通文件增量高亮不回退。
5. 取消落到索引、解析、预取、搜索的生产任务；
   不取消其它标签的共享 query编译，不只是丢回调。
6. 本机与 SSH 完整原生能力及数据验证成立后，
   从共享 `FileTab` 删除旧容量拒绝，所有普通文本入口遵循同一策略。
   `TabSwitcherView.filePreview`、`.gitignore` 和图片扩展名文本回退也必须是分段路径，
   不得留隐藏全文“快路径”。
   资源错误准确反馈，不换更大的常量，不新建按机器分流的放行规则。

**验证：**
`make test:TextDocumentTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,TextCoordinateIndexTests,FileTabPersistenceTests,NativeFileTabTests`。
总集 D、N、I1／I4、L及关联 E3；字节与实际像素共同验证，
高亮降级／不降级均测。
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
