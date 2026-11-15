# P2：重实现文件标签、原生编辑及安全读写

**交付：** `FileTab` 从读取到编辑、保存、刷新、退役只有一份权威可写正文；
32 MiB 文件在验证通过后完整可用；64 MiB 仅条件放行。
P1-T2 的原生所有权决策是前提。每项任务**接入实际调用者、删除被替代路径、同步对应现行功能文档、完成自己的测试**。

## 最小目标结构

```text
文件标签 FileTab (身份/代次/路径/后端/保存基线/草稿生命周期)
   |-- 唯一可写文本存储 NSTextStorage / NSTextContentStorage
   |     `-- 一个 NativeCodeTextView + 原生 Undo / Find / IME
   |           `-- 只消费版本及范围变化的行号/高亮/预览
   `-- 保存请求 (冻结同一版本) -> 严格后台编码 -> WorkspaceBackend
         `-- 本机/SSH 校验原始文件版本 -> 独占暂存 -> 完整接收 -> 原子发布
```

`FileTab` 拥有生命周期，**原生存储拥有可写字节**。
Swift `String` 可作为一次性加载、比较或保存快照，不能长期与原生文本互为可写镜像。
保存基线允许一份不可变文字／原始字节信息；它不是第二个可写编辑器。

不添加 `LargeFileManager`、复杂滚动投影、版本树、独立 IPC 服务或一组并行兼容接口。
不把已有 Git `DiffNativeSurface` 变成另一个编辑器；它继续使用同一 `NativeCodeTextView` 类型，
但 Worktree 的文本生命周期属于 `DiffTab`，其保存版本须在 P3 接上本阶段的后端契约。

<a id="p2-t1"></a>
## P2-T1：封住本机、SSH 与图片读取的实际错误入口

**改动：** `Bailey/Workspace/LocalWorkspaceBackend.swift`、
`Bailey/Remote/SSHWorkspaceBackend.swift`、`RemoteCommands.swift`、
`Bailey/Editor/FileViewerView.swift`；
`BaileyTests/Files/FileTabPersistenceTests.swift`、`BaileyTests/Remote/RemoteCommandsTests.swift`。

**已知可复现的根因：**

- 本机 `LocalWorkspaceBackend.readSync` 用可能阻塞的 `FileHandle(forReadingFrom:)` 打开路径，
  仅检查长度，没有先以普通文件类型和 NUL 路径守住 FIFO／设备的输入边界；
  旧分支 `2f96dab6`、`9e43979d` 给出了更严格的 FD 实证。
- SSH `read` 目前在类型检查前直接执行 `head -c`／`cat`，
  且普通读取进入 `RemoteCommandRunner.run` 的完整输出路径；
  旧分支 `54030cf8` 曾实际触发命名管道超时与特殊文件假成功。
- `FileTab.readContent` 遇到图片扩展名请求 `.max`，
  错误命名的巨型文件可先被全部加载到内存后才被判为不可用；
  旧分支 `2eac38cf` 已证明这条路径不能靠文本限制保护。
- `SSHWorkspaceBackend.execute` 只转义了环境变量**值**，
  原样插入名称会进入 Shell 控制流；旧分支 `4e4d8f66` 有 macOS 与 Windows MSYS2 的副作用复现。

**实施：**

1. 本机从单个普通文件 FD 读取，设置不可阻塞打开并用 `fstat`、限制及实际读满检查处理目录、设备、FIFO、符号链接与读中替换；超限和截断均不得返回可保存的半份正文。
   仅就本次打开支持的容量读取完整数据；不用 APFS clone 作为默认小文件路径。
2. SSH 先验证文件类型／大小，实际运行时对 stdout／stderr 加限，
   检查远端工具退出值和真正返回字节；不把非普通文件交给 `cat` 后等它超时。
   `RemoteCommands.statCommand` 与参数转义需核对 GNU／MSYS2 和 macOS BSD 两套真实语义，
   不能在新预检中让 Mac SSH 因不支持 GNU `stat --printf` 而全部拒绝读取。
   共享 stat 修复还需回归 Files/Git 的调用方。
   远端 `-f` 预检与实际打开之间存在非原子窗口：需在真实换目标／超时／取消下证明安全失败，
   不把 Shell 预检写成能彻底阻止并发路径替换的原子保证。
   本机 Shell fixture 与获授权的真实远端行为分开报告；不引入 GB 租约协议。
3. 图片单独定义有限的文件字节上限及解码尺寸／内存预算，在读取前检查元数据，
   参考备份中 256 MiB 原始图片字节限制的实际案例但不直接作为默认承诺；
   若能在 ImageIO 生成有界缩略图就复用原生 API，不把压缩字节小却解码极大的图片完整展开。
   需要时有界识别实际格式；假图片按**文本原本规则**处理，不因为 `.png` 扩展名无限读取。
   缺失、路径增长和后缀伪装失败均不影响旧文件草稿。
4. 在共享远端命令入口将完整 `name=value` 当作一个经过转义的参数，
   拒绝空名称／`=`／NUL 等无效键，保护以 `-` 开头的名称不变成 `env` 选项。
   正常的特殊字符路径及变量值仍可正确传递，不造第二个转义函数。

**Red→Green：** 使用临时 FIFO／目录／设备、NUL、超限假 `.png`、读中增长／截断、
以及含引号、换行、`$`、分号、前导 `-` 的变量名。
在旧版确实重现阻塞、内存风险或额外 Shell 副作用，再测真实文件、已保存正文、
意外副作用不存在以及请求超限而非静默截断。

**清理／验收：** 删除不再可达的无界读回退；
复用现有 `WorkspaceBackend` 与进程泵，必要安全校验位于最终执行点，
不为每个调用者增加一层验证器。
保留 8 MiB 文本限制直到 P2-T5。

<a id="p2-t2"></a>
## P2-T2：让 `FileTab` 与原生文本只有一个可写所有者

**改动：** `FileViewerView.swift`、`SourceTextEditor.swift`、
只在有必要时修改 `NativeCodeTextView.swift`、`NativeTextLineIndex.swift`；
`TabSwitcherView.swift`、`Project.ignoreGitPaths` 的实际消费者。

**核心动作：**

1. 按 P1-T2 已验证的最小原生所有权方案，
   让首次读入、第一次挂载、卸载重挂、编辑和关闭都使用**同一个权威 `NSTextStorage`**。
   `FileTab` 不再通过 `editorCoordinator.currentText()` 取得另一份实时正文。
   未挂载但已请求 `.gitignore` 追加的标签必须能编辑、保存、后续挂载看见准确正文；
   已挂载时的 Undo 语义不变，不为程序化离屏追加另建用户未要求的 Undo 机制。
   如果需要在加载时就创建一个原生编辑器，应由标签持有它而非由 SwiftUI 一次性 View 持有。
2. 把 `NSTextStorage.didProcessEditing` 的真实 UTF-16 范围、替换内容和
   输入法结束事务交给一个状态入口；不要依赖 `textDidChange` 漏报的 Undo、AX 和程序化编辑。
   保留 `NativeCodeTextView.finishComposition/replayComposition` 与独立多选区的正确 Undo 分组。
3. `FileTab` 保存点单独记录**不可变**正文基线、当前编辑版本和原始磁盘字节版本。
   脏状态针对字节精确性：单次输入不得为检查是否干净复制 32 MiB 正文；
   撤销、手工改回相同字节以及规范等价但原字节不同都须按结果处理。
   P1 已实测有效的最小增量判定机制可保留；如果仍需精确全量比较，
   只能在无法由局部变化判断时发生，且延迟、内存要经量测证明可接受。
4. 预览只提取不超过数千 UTF-16 单元的局部片段，不先读全篇；
   `.gitignore` 追加只读取当前行尾格式所需信息，
   不通过 `file.text.contains` 触发无关的全文构造。
5. 对照现有标签身份、`reloadRevision`、`targetGeneration`、滚动／焦点状态
   保留旧读取不可覆盖新编辑、同字节刷新不重建编辑器、外部接受新版本才退役旧原生对象的行为。
   真实关闭要解除 `NSScrollView.documentView`、旧 Undo 和 Neon 回调；Dock 只暂时卸载。

**必须随本项删除：** 已被新事件与存储契约取代的
`bufferedText`、`nativeTextIsCurrent`、`reversibleEdit`、`restoredSavedBytes`、
反向取全文和相应未使用的全文镜像；
`nativeCodeUnitDelta` 仅在选定的更简单机制能替代其**已证明用途**时移除，
不能先删再引入每键全文比较。
不要留下 `if newModel { ... } else { oldModel }` 的长期双轨。

**Red→Green／完成：** 真实 `FileTab → NSTextView → FileTab`，
小文件与接近当前 8 MiB 的文本，在跨行多选、IME 已标记／未标记、
Undo/Redo、手动改回、原生 AX 编辑、离屏 `.gitignore` 追加、重挂载、失败刷新、
连续五标签关闭与释放中都保留最终正文和实际原生文档身份。
被移除调用者的搜索结果不得仍可到达旧路径。提交同时更新 `docs/features/editor.md`。

<a id="p2-t3"></a>
## P2-T3：以原字节版本和一次保存事务替代排队写入

**改动：** `FileTab.save`／`writeCurrentText`、`TextFileEncoding.swift`、
`WorkspaceBackend.swift`、`LocalWorkspaceBackend.swift`、
`SSHWorkspaceBackend.swift`、`RemoteCommands.atomicWriteCommand`；
包括受影响的本机／SSH 测试夹具。

**一条完整写入路径：**

```text
读取真实源字节 -> 记录其长度/摘要/路径和机器身份 -> 原生文档被编辑
手动/失焦/关闭请求 -> 冻结这一正文版本 -> 后台严格编码并核验可往返
-> 后端校验当前目标与读取时接受的原字节版本
-> 同目录独占暂存完整写入 -> 核对接收长度和 SHA-256 -> 再核对目标版本
-> 原子发布 -> 仅在确认写入与当前请求身份匹配后更新保存基线
失效/冲突/拒写 -> 旧目标和编辑草稿保留，不启动无条件重试
```

- 现有 `WorkspaceBackend.write(path:data:)` 服务其它**有意无条件写**的调用者；
  为文本保存明确增加要求版本相等的专用写入契约，
  **不得以协议默认实现退回无条件 `write`**。
  可以复用备份 `WorkspaceFileVersion` 的简短原字节长度+SHA256 思路，
  但无需搬回整套 GB stable-source 类。
- `FileTab` 在磁盘读取后保存**原字节**摘要，不把 Unicode `String` 重新编码的摘要当原始版本；
  同字节或同解码文本的成功刷新仍应正确更新原字节基线而不清空 Undo。
  内容哈希不是 inode、文件入口身份或跨 SSH 的原子版本号；路径、工作区与机器身份仍独立核对，
  对“外部替换为相同字节的新文件”明确现行策略并验证，不能用摘要代表不存在的身份保证。
  新编辑发生于写入期间时，旧写入完成也不能将其标记 clean。
- 编码确认、`coding:` 声明、BOM、Windows 远端 `mbcs` 和无损转换
  在主 actor 外计算；明确新编码保存是不可合并的独立用户意图。
  一个所有者串行确认实际完成的请求，连续重复的普通保存只保留最新待处理版本，
  不为每次失焦累积完整正文快照或无主 `Task` 链。
- 本机使用同卷暂存并保留现行普通文件权限；SSH 继续使用已有每次事务独占的
  `mktemp -d` 和原子 `mv`，接收端必须检查真实写入的**长度与 SHA-256**。
  短写、标准输入提前关闭、尾随字节、发送方中断、命令异常退出均不能发布部分文件。
  链接入口替换、目录拒写、缺失与被其他进程修改的版本分别处理。
- 最后一次比对与 `rename` 之间仍可能有**非合作外部写者的竞态**。
  POSIX 并未提供当前无服务协议的通用 compare-and-rename；
  必须明确承认并实测，不能把两次哈希说成原子 CAS，
  也不要为不可保证的承诺加入无限锁／常驻 Windows 服务。
  若发布成功回执不确定，查询实际目标后再决定保存状态，不能盲重试覆盖新内容。

**真实 Red→Green：** 以 `c771a930` 的已失败场景作为验证原型：
外部文件以**同大小、同 mtime、不同字节**替换后由真实 FileTab 保存；
修复前必须证明覆盖发生，修复后保留外部版本与草稿。
扩大到同路径不同 FileTab/Diff、另一个窗口、路径删除／重命名、链接、权限、
失焦重复保存、保存时追加、SSH 接收字节截断／篡改／提前 EOF、断连再连及取消。
每次检查真正的磁盘内容、编辑器版本、错误反馈、私有暂存清理和恢复后再次保存。

**清理／验收：** 旧 FileTab 保存任务链及无条件 fallback 退出，
文件操作和窗口关闭仍必须等待真实保存结果；
后端 API 的错误语义与版本内容可由不同调用者消费。
**P3-T1 必须让工作区可编辑 Diff 使用同一版本条件写入**，
在此之前不得把本轮改动称为“所有编辑入口已防覆盖”。

<a id="p2-t4"></a>
## P2-T4：只优化测到的主线程热点，不再扩建文本模型

**入口：** `NativeMeasuredLineWidths`、`NativeTextLineIndex`、
`NativeCodeTextView.configureWrapping/setLongLineTruncation/processStorageEdit`、
`SyntaxHighlightCoordinator`／Neon、`TextFileEncoding`、Find/缩略图。

- 根据 P1 的 CPU／Allocations 结果优先消除最重的重复全文分配、
  不折行时初始化逐行测宽、行数变化重建、
  每键从 `NSTextStorage` 复制大段字符串及主线程编码；
  **若没有测到瓶颈则不改对应模块**。
- 固定字宽 ASCII 行优先使用已有快速测量与行索引，
  不引入新的 Tree/Worker。非 ASCII 宽行仍需真正测到正确的横向范围，
  不能因只量可见行就截断远处合法文本、漏画 SVG 或使滚动范围失准。
  长行普通宽度与“完整显示”的既有可见性规则不改。
- 保留原生 TextKit 2 的窗口布局、系统 Find/AX、Tree-sitter 的增量更新和 Neon 现有查询缓存。
  `Task` 的主 actor 继承不能算后台优化；若测到耗时计算仍在主 actor，
  只将**纯数据工作**移出隔离并对版本、取消、结果交付做最小核对。
- 字体／主题切换、窗口缩放、字符替换、前方插入和关闭时，
  原生行号、实际像素、语法颜色、折叠/横滚及真实资源释放不得退化。

**验收：** 同机器／同输入／同设置的 Debug 与 Release 前后对照；
普通输入 p95 ≤ 16 ms、10 万行 p95 ≤ 32 ms、主线程连续占用目标 16.7 ms。
覆盖 382／1,000／10,000／100,000 行、16／32 MiB、巨行、Unicode、CRLF，
每个适用热操作至少 30 次，并核对正确字节、实际画面、隐藏标签的任务取消与资源回落。
所有新增缓存必须有明确所有者和失效／释放边界。

<a id="p2-t5"></a>
## P2-T5：真实 FileTab 32 MiB 放行，64 MiB 独立决策

- 用在 **P2-T1～T4** 已验证的最终代码，生成并实际打开合法 0、1、8 MiB-1、
  8 MiB、8 MiB+1、16 MiB、32 MiB、64 MiB 与超限本机文件。
  不把直接 `NSTextView.text = ...` 的组件测试冒充 FileTab 可用。
- 对 32 MiB 覆盖：首次可交互、文首中尾及 17 次远距编辑、跨行多光标、IME、
  Find／Replace、Undo/Redo、改变折行与主题、失焦/手动保存、关窗/重开和
  **真实磁盘逐字节结果**，对照 P1 相同设备、文件与设置的耗时及 RSS。
- 原有 8 MiB 边界、被拒绝的部分 UTF-8 字节、非正规文件、图片、
  UTF-16 BOM／GBK／GB18030／Windows `mbcs`、Unicode 规范等价与大小写路径
  继续准确拒绝或无损保存；不能将超限内容截断后标成完整可写文件。
- **只有 32 MiB 全链与性能均过关才调整正式产品限制。**
  64 MiB 运行相同的行为、延迟、内存、释放和原生绘制检查；
  若不符合则保留 32 MiB 并记录反例，而不是开新的实现阶段。
- SSH 在受控 Shell 后端完成相应容量／完整字节验证；
  只有有授权的隔离真实 SSH E2E 通过时才宣称该远端容量已正式验收，
  否则列出真实远端未知的限制，不因本机通过而对 SSH 作无条件承诺。
- 不更换正式运行的 Bailey，相关实际 UI 路径只用有独立图形会话的 Bailey Dev，
  不能临时夺取用户桌面。没有条件就明确记录未验收状态。

**验收产出：** 本机 32 MiB 的 Go/No-Go 与 64 MiB 的独立结论，
明确最终文件上限、内存及耗时、已测试后端、文本异常与停止原因；
对应的 `FileViewerView` 文案和 `docs/features/editor.md` 都与实现一致。

## P2 阶段验收

先通过现有 Makefile 运行文件与生命周期宿主测试：

```bash
make test:FileTabPersistenceTests,NativeEditorCompositionTests,NativeEditorLayoutTests,NativeFileTabTests,NativePaneRetentionIntegrationTests,WindowCloseIntegrationTests,RemoteCommandsTests,RemoteLifetimeTests,WorkspaceIdentityTests
```

再根据 `NativeCodeTextView` 共享影响运行
`NativeDiffTabTests`、`NativeSyntaxHighlightingTests`、`TextCoordinateIndexTests`、`GitIgnoreIntegrationTests` 等受影响类。
任务中先按真实缺陷取得 Red→Green；阶段末 `make build`、`make test`、`make build:ui`。
大文件、输入法、保存与资源释放的真实环境和组合见 [P3 总验收](plan-p3.md#full-acceptance)；
不能因测试类“全绿”或只编译 UI Target 就宣称完整 GUI 成功。

每个改动只提交它真正连接到产品的调用链；对应的旧路径、夹具和文档同步退休。
离开 P2 时 Files 不再有两份互相推送的可写正文，
但最终完整对外验收要等 P3 的可编辑 Diff 与跨窗口文件冲突一起完成。
