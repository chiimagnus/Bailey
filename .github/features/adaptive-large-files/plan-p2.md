# P2：替换文件编辑内核，不保留旧双轨

**交付：** 从真实 `FileTab` 打开到原生输入、保存、重载、关闭的单一简洁链路。
优先让普通文件和 **32 MiB** 文本可稳定编辑；**64 MiB** 只有 P1 的资源与语义结论允许时才开放。
P1 的正文方案和性能预算是前置输入；不把 GB 实验代码合入本阶段。

## 新旧职责

| 位置 | 重实现后的职责 | 需要退出的旧链 |
| --- | --- | --- |
| `FileTab`（`FileViewerView.swift`） | 唯一编辑会话、正文与保存基线所有者；路径、机器、版本、脏状态 | `bufferedText`／`nativeTextIsCurrent` 与原生全文往返的双真源；多套脏状态猜测 |
| `SourceTextEditor`／`NativeCodeTextView` | 同一原生输入控件；范围变化、选区、IME、Undo 和视口状态 | 每次重挂载重新安装完整镜像、每次编辑拉取整个字符串 |
| `WorkspaceBackend`、`TextFileEncoding` | 32 MiB 目标范围内的有界读取、严格解码与完整安全保存 | 无界图片读取、过期内容静默覆盖、保存并发中的旧目标回写 |
| `NativeTextLineIndex`、高亮、Find、预览 | 依赖已确定的正文版本，只计算当前操作必要的派生结果 | 小预览先生成全部字符串；一次输入重算与当前操作无关的全部信息 |

只在确实替换到对应用户入口后删除旧实现与测试。
不要引入单独的 `LargeFileEditor`、兼容 Feature Flag、镜像工作器或第二套窗口模型。
Git Diff 共用的 `NativeCodeTextView` 部分必须保持原语义，受影响回归一起验收。

## <a id="p2-t1"></a>P2-T1：以单一正文重写文件挂载、编辑和保存状态

**修改：** `Bailey/Editor/FileViewerView.swift`、`SourceTextEditor.swift`、
需要时修改 `NativeCodeTextView.swift`；
`FileTabPersistenceTests`、`NativeEditorLayoutTests`、`NativeEditorCompositionTests`。

- 按 P1 选定方案让 `FileTab` 持续拥有一个权威正文及其保存基线，
  原生编辑事务只提交变更范围与必要状态；不在输入回调里拉取全文来推断脏状态。
- 从打开到首屏、保存前冻结、成功确认与失败保稿形成一条闭环。
  精确处理 UTF-16、CRLF 和 Unicode 规范等价但原字节不同；Undo 回保存版本必须清除脏状态。
- 复用原生选区、IME/Undo、查找、行号、滚动和无障碍行为。
  Dock 重挂载保持文档身份；文件真正变更或关闭才退役旧文档及高亮任务。
- **在本任务完成前删除**被取代的原 `bufferedText`、原生反向正文镜像、
  字符频数／单次反向推断逻辑及其它无消费状态；不保留新旧两条保存可写路径。
  重写的目标是更少的状态分支，而非单纯减少代码行数。

**验收：** 真实 `FileTab → NSTextView → FileTab → 保存目标` 回环通过；
覆盖跨行替换、多选区、中文 IME、Undo/Redo、失败保存及重挂载后继续编辑。
保存后的磁盘字节、光标、原生文档身份与最终脏标记均要断言。
当前 8 MiB 行为不得回退；目标 32 MiB 在完整文件入口测量，不用组件演示代替。

## <a id="p2-t2"></a>P2-T2：用现有本机和 SSH 后端完成无损且有界的读写

**修改：** `FileTab.readContent`／`writeCurrentText`、
`TextFileEncoding`、`LocalWorkspaceBackend`、`SSHWorkspaceBackend`、
`RemoteCommands.atomicWriteCommand`；
`FileTabPersistenceTests`、`RemoteCommandsTests`、`RemoteLifetimeTests`。

- **先守住读取边界：** 普通文件、图片和二进制使用各自明确限额；
  对目录、FIFO／设备、不完整读取、非法 NUL 路径及大于支持范围的文件明确失败。
  不再把图片扩展名直接传给无限 `read(maxBytes: .max)`。
- 在支持的几十 MiB 范围内优先复用 `Data`／`String` 与当前编码能力。
  重量级解码、校验、SHA 和编码离开主 actor；
  只有实际测量证明全文副本是瓶颈时才做局部 API 优化，**不引入 GB 流式协议**。
- 保留 BOM／声明与手动编码、严格无损往返、CRLF、Unicode 和 Windows `mbcs`；
  对无损编码失败必须阻止写入，不能发生隐式转换。
- 复用同目录私有暂存与原子发布。本机与 SSH 保存时需核对打开时接受的
  **原始字节版本**（含同大小、同 mtime 被改写），保留目标权限及符号链接入口替换语义；
  删除、重命名、其他程序修改或 SSH 断连均保留草稿。
  完整性校验检查实际接收字节数／摘要、短写、取消与失败清理。
  远端命令的路径、环境变量名和值必须保持原样作为参数，
  不允许把环境变量名插入 Shell 控制流；复用备份 `4e4d8f66` 的回归思路。
  最终比较到 rename 的窗口不是 POSIX 原子 CAS，用户提示不得声称绝对防覆盖。
- 对焦点丢失、手动保存及关闭请求维护一个明确的写入所有者；
  避免重复排队同一正文版本，保存途中新编辑仍保持 dirty，显式换编码请求不能被合并。
  跨机器、旧路径与旧连接的结果不能确认新目标。

**验收：** 本机与受控 SSH Shell fixture 保存同一组 UTF-8／UTF-16／CP936、
空文件、长行和错误输入；真实临时文件在短写、重连、外部改写、取消时
旧目标完整、草稿保留、权限／符号链接语义正确、失败后无孤儿暂存。
真实 Windows SSH 只在获授权的隔离目录做单独 E2E；没有该条件不得冒称已通过。

## <a id="p2-t3"></a>P2-T3：收敛全文派生热点并完成 32 MiB 产品门禁

**修改：** `NativeTextLineIndex`、`NativeCodeTextView` 的测宽与折行、
`SyntaxHighlightConfiguration`／`EditorFind`、`TabSwitcherView` 与 `Project.ignoreGitPaths`
实际调用点；`NativePaneRetentionIntegrationTests`、文件／窗口关闭回归。

- 只修 P1 及真实 P2 运行中测到的瓶颈：主线程初始测宽、
  Tree-sitter 全文解析、远距滚动或预览全文读取；复用现有原生 TextKit、
  增量行索引和取消任务，而不是预写一套窗口化渲染引擎。
- 隐藏标签、主题切换、取消搜索和关闭时释放属于该文档的内存、原生视图和后台任务。
  保留多窗口、Finder 打开的本机文件与同路径 SSH 文件之间的身份隔离。
- 跑 **32 MiB 真实文件**的首／中／末编辑、查找／替换、Undo、自动保存、
  重新打开、长行与 10 万行、A→B→A、关闭释放的完整链路；
  核对 P1 预算与小文件性能。只有这组实际验收通过才提升生产限制。
- 再以完全相同的条件验证 64 MiB；不满足即保留已证的 32 MiB 容量，
  给出真实错误文案和可用的终端替代，不因“已经写了优化”放行。

**验收：** 用户可在 Bailey 完整编辑并保存 32 MiB 合法文件，
不仅测试例程可以解码；无大块主线程冻结、内容截断、遗失 Undo 或缓存泄漏。
每项性能结论必须记录机器、构建、真实字节与测量方式，32／64 MiB 分别判定。

## 阶段验收与必须覆盖的边界

- **容量与类型：** 0、1、5/8 MiB 临界、16、32、64 MiB、刚超出已支持范围，
  UTF-8／BOM／UTF-16／CP936、损坏编码、NUL 二进制、无效图片与受控大图片。
- **编辑语义：** 中文拼写中组合输入、代理对与组合字簇、LF／CRLF、无换行巨行、
  多光标、查找／替换、AutoSave、Undo 到保存点、失焦保存、重挂载及多窗口关闭。
- **失败与并发：** 本机／SSH、同大小同 mtime 外部改写、路径替换、短写、
  磁盘满／权限、断线重连、取消、两次并发保存、保存中继续编辑、关闭与文件改名竞争。
  每个失败必须检查**真实磁盘字节、原生草稿和后续恢复**。
- **运行：** `make test:FileTabPersistenceTests,NativeEditorLayoutTests,NativeEditorCompositionTests,RemoteCommandsTests,RemoteLifetimeTests,NativePaneRetentionIntegrationTests`；
  受影响的 Diff／Git 宿主测试也一起跑，阶段末执行 `make build`、`make test`。
  GUI 只用隔离 Bailey Dev 验收，不能抢占正在使用的正式桌面。

适用但无法执行的真实 SSH／GUI／旧系统条件，逐项记录阻塞原因、替代证据、
影响及是否妨碍放行；不能把 Shell fixture 当作远端实机或把 `build:ui` 当成 UI E2E。
同步更新 [编辑器](../../../docs/features/editor.md)与 [SSH](../../../docs/features/ssh.md)现行契约。
