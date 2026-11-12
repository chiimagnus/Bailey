# P1：原生 GB 文档、稳定 IO 与 Diff 的技术准入

**Goal：** 先取得会改变架构的原生、存储、SSH 和 Diff 证据，固定预算，再准入生产改造。

**Non-goals：** 不提前选择 Rope／Piece Tree 库，不先删除容量检查，
不换编辑器，不安装正式 App，不以原型通过代替功能验收。

**Approach：** 分开验证原生输入能否保持分页、后端能否提供稳定源与完整流式保存、
Diff 能否以有界内存处理 GB 两侧。只使用现有 XCTest、Makefile 和隔离 Bailey Dev。
P2／P3 是受实验约束的结果拆分；P1-T4 必须先将其具体化，才能进入生产实施。

**Acceptance：** 原型有真实输入和最终字节证据；失败边界可复现；
预算有量纲、测量方法与适用环境；没有把待验证假设写成已具备能力。

**Rules：**
- 2026-11-12 已授权 P1 原型与验证；本阶段不实施 P2／P3，也不直接解除容量检查。
- 遵守根 AGENTS 及 `docs/{architecture,standards,testing,development,ui}.md`。
- 保留原生输入、Undo、焦点及后端身份，不借实验引入第二套编辑器或远端常驻服务。
- 先核对磁盘、内存、专属桌面与远端授权；不以 OOM 或破坏用户环境取证。
- 计划、证据和审计默认不入 Git。审计文件仅在实际阶段审计开始时创建。

## 已读依据和责任链

2026-11-12 执行前复审基于 `main` HEAD
`37badb70321bee40c0e2df1cf9e8105cd9bb6353`（macOS 27.3／Xcode 27.2）。
本次同时核对 `c9111491` 的文件编码变更、`37badb70` 的旧折叠索引越界修复及现行功能文档；
旧计划 11-04 的源码快照与测试结果不可直接当当前状态。
P1 实际实验基线另为 `4f97741c97c0de8626e0ff225d409d881770b53e`；
真实执行结果在 `evidence-p1.md`，本页仍只定义计划和实验准入条件。
实施前仍须重新查 Git status／HEAD。

**已落地的原生行为不得重复规划：** 工作区 Diff 自首次展示即使用同一可写
`DiffCodePaneView`／TextKit 文档，未修改段落在该文档内折叠；
不再存在 `showsFoldedWorktree`／`activateEditor`／`beginEditing` 浏览到编辑器的切换链。
历史／暂存的 Unified／Split 才是派生只读投影；更换 Git 快照时必须在装入新原文前退役旧折叠、ghost 和旧坐标，
并保留有效的 Split 左侧基线。P3 以这些**当前事实**为起点，不重建已删除的模式。

| 责任链 | 已读源码锚点 | 最终结果及现有验证 |
| --- | --- | --- |
| 打开／恢复 | `WorkspaceWindowModel.openFile`、`Project.openFile/openLocalFile/makeContent` | 同机去重、本机身份、懒恢复；`FinderDeliveryIntegrationTests` |
| 文件读取／更新 | `FileTab.loadIfNeeded/waitForText/reloadFromDiskIfClean/readContent/loadedContent` | 代次、目标与脏编辑保护；`FileTabPersistenceTests` |
| 原生内容 | `SourceTextEditor.makeScrollView/Coordinator.retireObsoleteDocument` | 重挂载不重建，关闭解除正文；`NativePaneRetentionIntegrationTests` |
| 输入／布局 | `NativeCodeTextView.processStorageEdit/configureWrapping/finishComposition`、`NativeMeasuredLineWidths` | IME、Undo、命中、像素；`NativeEditorCompositionTests`、`NativeEditorLayoutTests` |
| 索引／高亮 | `NativeTextLineIndex`、`TextCoordinateIndex`、`SyntaxHighlightCoordinator`、`Vendor/Neon` | LF／原生段落坐标、稳定解析快照与真实颜色；`TextCoordinateIndexTests`、`NativeSyntaxHighlightingTests` |
| 保存保护 | `FileTab.save/writeCurrentText/beginFileMutation`、`PaneContent.save`、`WorkspaceApplication.saveBeforeGitAction` | 字节、在途编辑、关闭否决；文件与工作区宿主测试 |
| 本机／SSH | `WorkspaceBackend`、`LocalWorkspaceBackend.readSync/write/runSync`、`SSHWorkspaceBackend.read/write`、`SSHHostWorkspaces.execute`、`ProcessRemoteCommandRunner.run` | 当前完整 Data 契约及共享进程读／写／取消所有者；`RemoteCommandsTests`、`SSHFileTreeLiveTests` |
| Diff 读取 | `DiffTab.reload/gitContent/readWorktreeFile/gitComparisonBaseline` | 锁定 OID、Git clean 与原始文件；`NativeGitHistoryFileTests`、`NativeDiffTabTests` |
| Diff 派生 | `DiffCore.computeIfActive`、`DiffComputation.build`、`DiffTab.recomputeDisplay/publishDisplay/refreshEditDecorations`、`DiffNativeSurface.render` | 当前两侧全文行数组及统一／左右只读派生文档；工作区已用唯一原生可写正文；`DiffEngineTests`、原生 Diff 测试 |

| 编码识别及转换 | `TextFileEncoding.decode/encoded/declared/contradictsDeclaration`、`FileTab.reopen`、`DiffTab.reopen` | UTF-8／BOM、UTF-16、GBK、GB18030、Shift-JIS、Windows 单字节编码、远端 `mbcs`，严格往返和用户选择；不能把合法 UTF-16 零字节判作二进制 |
| 非编辑器消费者 | `TabSwitcherView.filePreview/diffPreview/textExcerpt`、`Project.ignoreGitPaths` | 先访问全文再截取预览／判断换行；小视图不能成为 GB 文档全文物化的旁路 |

### VS Code 固定版本对照

取证版本为
[`077bec303574782e7b6f09b94c761ca96c7068eb`](https://github.com/microsoft/vscode/commit/077bec303574782e7b6f09b94c761ca96c7068eb)，
提交时间 2026-11-04T01:30:55Z。这是源码对照，不是两款产品的同机 GB 性能实测。
后续引用此固定版本，不自动追 main；未构建 VS Code，不宣称其实际性能或全部输入能力。

| 主题 | 已读上游源码 | 适用启示与边界 |
| --- | --- | --- |
| 流式装载 | [textFileService.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/workbench/services/textfile/browser/textFileService.ts)、[textModel.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/textModel.ts) | `readStream → createTextBufferFactoryFromStream` 在流结束后交付 factory，不是只装入可见页即完成模型 |
| 文本缓冲 | [pieceTreeTextBufferBuilder.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeTextBufferBuilder.ts)、[pieceTreeBase.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts) | 分块、子树汇总及局部修改可借鉴；块仍是内存字符串，不是磁盘分页；不能复制 EOL 规范化 |
| 视口 | [viewLayer.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/browser/view/viewLayer.ts) | 视口行的替换／复用；不移植 DOM 或替换已有 TextKit 2 |
| 大模型策略 | [textModel.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/textModel.ts) | tokenization、sync、全文 heap 操作分别受限；比较的是 UTF-16 文本长度或行数，不能都当磁盘 MiB |
| 打开确认 | [resourceEditorInput.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/workbench/common/editor/resourceEditorInput.ts)、[editor.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/workbench/common/editor.ts) | 按资源决定确认门槛，允许 Open Anyway；不证明任何大小都能在给定内存下成功编辑 |
| 快照／保存 | [pieceTreeBase.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/pieceTreeTextBuffer/pieceTreeBase.ts)、[textFileEditorModel.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/workbench/services/textfile/common/textFileEditorModel.ts)、[fileService.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/platform/files/common/fileService.ts) | 顺序快照、编码流和写入前校验；上游单线程快照假设不能当 Swift 跨 actor 安全证明 |
| Undo／搜索 | [editStack.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/editStack.ts)、[textModelSearch.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/model/textModelSearch.ts) | 范围事务和结果驻留控制可参考；保留系统输入语义，不把结果限额当作完整搜索 |
| Worker／Diff | [editorWorkerService.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/browser/services/editorWorkerService.ts)、[defaultLinesDiffComputer.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/common/diff/defaultLinesDiffComputer/defaultLinesDiffComputer.ts)、[diffEditorViewModel.ts](https://github.com/microsoft/vscode/blob/077bec303574782e7b6f09b94c761ca96c7068eb/src/vs/editor/browser/widget/diffEditor/diffEditorViewModel.ts) | 预算、取消、提前结束显式化；Diff 会强制同步大模型，算法接收全文行数组，不是可直接搬用的分页算法 |

[官方 Piece Tree 文章](https://code.visualstudio.com/blogs/2018/03/23/text-buffer-reimplementation)
解释避免单字符串拼接、逐行对象膨胀的动机；历史指标不作为本 feature 的预算。

只参考已核对的职责和算法，不把 TypeScript 移植当作现成 Swift 实现。
若后续实际复用上游代码，保留其许可及归属，并按仓库规则更新 NOTICE；
不得未经需要新增依赖、覆盖第三方头部或将源码副本混入产品资源。

Apple 的
[NSTextStorage 子类契约](https://developer.apple.com/documentation/appkit/nstextstorage#Subclassing-Notes)
和 [TextKit 2 说明](https://developer.apple.com/videos/play/wwdc2021/10061/)
允许自定义存储／内容模型，但没有承诺 NSTextView 的所有功能都不会物化全文。
本机 xcdocs 能定位符号但未返回正文，已补读 Apple 文档数据及 WWDC。
这只能证明原型入口有依据，不能通过以下 Gate。

### 现有运行证据的边界

前轮调查运行了四项定点回归，回报 4/4、零失败、完整命令退出 0：

```sh
make test ONLY_TESTING='BaileyTests/FileTabPersistenceTests/testLocalTextReadCapacityAndFailureKinds BaileyTests/FileTabPersistenceTests/testInvalidUTF8AndImageFallbackRespectTextCapacity BaileyTests/RemoteCommandsTests/testSSHBackendEnforcesByteLimitAndPreservesBinaryWrites BaileyTests/NativeGitHistoryFileTests/testGitBlobAtExactFiveMiBIsReadableWhileNextByteIsRejected'
```

环境为 Apple Silicon、macOS 27.2、Swift 6.4.2。
它们只证明旧边界、UTF-8／图片回退、受控 SSH 字节行为及 Git blob 上限。
原报告日志为 `/tmp/bailey-large-file-review-20261104.log`，
结果包名为 `Test-Bailey-2026.11.04_09-45-11-+0800.xcresult`；
本轮未取得可复验的完整结果包，不把历史回报作为当前完整工作树验收。
需要复用时先核对原日志和相关代码；缺失即用上述命令重跑。

<a id="p1-t1"></a>
## P1-T1 原生分页编辑与全文访问点的反证实验

**结果：** 证明原生控件能承载有界访问，或交付最小失败条件。
不先提交未经证明的生产内容管理器。

**Files／锚点：**
读取 `Bailey/Editor/{NativeCodeTextView,SourceTextEditor,EditorFind}.swift`，
特别是 `text/string/attributedText`、`finishComposition`、`processStorageEdit`、
`configureWrapping`、`performFindAction`、`SourceTextEditor.Coordinator.currentText`；
同时核对 `TabSwitcherView.textExcerpt` 与 `Project.ignoreGitPaths` 的全文消费。
在现有 `BaileyTests/Editor/` 新增 `LargeDocumentPrototypeTests.swift`；
对照 `NativeEditorLayoutTests`、`NativeEditorCompositionTests`。
工程使用文件系统同步组，仍核对 XCTest 枚举，不建立新工程或 shell 测试系统。

**步骤：**
1. 先以有读取计数的合法分段源探测 NSString／String、字符、属性和范围访问的真实成本。
   优先实验官方 NSTextStorage 自定义 backing；
   只有其失败证据明确时再检验自定义内容管理器与 NSTextView 的接入。
2. 用真实原生视图对照小文件、256 MiB、1 GiB，以及多短行和单个超长逻辑行。
   单行从 1／16／128 MiB 扩展到资源允许的 GB，不能用多行结果代替。
3. 挂载、首屏、17 次首尾跳转、滚动、输入、IME、Undo／Redo、全选、查找／替换、
   AX 范围请求、字体和折行变化逐项测量。记录正文、段落和缓存的持有者。
4. 冷页 miss 若导致主 actor 阻塞，记录最坏值；不靠预热、隐藏段落合并、
   截短正文、自绘编辑器或页外选区丢失制造通过。
5. 同时核对小文件像素、命中、多选区和每次 IME 一条 Undo。
   原型成功只证明接入，不替代全产品消费路径。

**防止实验先替产品做完全文工作的约束：**
- 使用尚无全局 UTF-16长度／行数索引的真实变宽 UTF-8源。
  夹具可为独立 oracle知道答案，但不得把预生成 String、字符总数或全局行起点传给原生适配。
  分别记录文件字节数、已知正文范围、已知 UTF-16／行范围和它们的实际获得过程。
- 首次页／预取额度后用受控读取屏障暂停生产，再请求真实首屏和已知范围内输入。
  屏障不释放前就应取得可见文字及有效编辑；不能把“读完整后内存降下来了”算按需。
  索引未知时的 Cmd-End、恢复选区、滚动条和 Find请求也须明确等待／完成语义，
  不允许把估算字符数、局部末尾或占位符伪装成全局文档位置。
- 全局长度若是 NSTextView接入的不可绕过前提，直接记录该原生路线的失败；
  不能用已知长度的合成 provider掩盖这一关键约束。
- 将复制／剪切、跨窗口粘贴、原生服务和 AX普通查询／显式完整值读取纳入探测。
  区分例行查询的隐式全文副本与显式导出整篇的协议成本；
  不测、返回不完整数据或关掉能力都不算修复。
- 探测布局中的单个巨段落、超长组合字符簇、冷页 miss和热缓存，
  不只实验已经排好版／预先建好索引的多行 ASCII。

**验证与覆盖：**
`make test:LargeDocumentPrototypeTests,NativeEditorCompositionTests,NativeEditorLayoutTests`。
Debug 验证正确性，隔离优化构建测性能；总集 E、D、N、L，
必须组合长行 × 折行 × 字体 × 远距导航。
当前支持的系统可先给证据；最低系统缺实机时独立列缺口，不冒称全平台准入。

**文档、停止及提交：**
仅在本 feature 的 `evidence-p1.md` 保存 API／SDK、访问计数、字节、内存、
延迟与失败栈，不更新长期文档为“已支持”。
原生输入、完整范围或有界内存无法兼容时，停止依赖路线，不默认换编辑器。
可复用的测试才原子提交；一次性实验在结束前移除，不制造空提交。

<a id="p1-t2"></a>
## P1-T2 稳定源版本、分段 IO 与完整保存的协议实验

**依赖：** 可与 P1-T1 的取证并行，生产路线须同时通过两者。

**Files／锚点：**
`WorkspaceBackend.read/write/stat`、`LocalWorkspaceBackend.readSync/write`、
`SSHWorkspaceBackend.read/write`、`SSHHostWorkspaces.execute`、
`ProcessRemoteCommandRunner.run`、`LocalWorkspaceBackend.runSync`（当前单一进程 stdin／stdout／stderr 泵）、
`RemoteCommands.atomicWriteCommand`、`TextFileEncoding.decode/encoded/declared`。
当前没有 `ProcessStdinWriter` 类型，不得为了匹配旧计划重新创建。
在 `BaileyTests/Remote/RemoteCommandsTests.swift` 内新增
`SegmentedWorkspacePrototypeTests` 类，复用同文件的 private `LocalShellRunnerFixture`，
不为原型复制 runner 或扩大 helper 可见性；真实传输复用现有专属 master 入口。

**步骤：**
1. 明确源版本的产生、保持、失效：原地写、增长／截断、原子替换、
   符号链接、路径重建、重连及换目标；包括**同大小、同 mtime、字节已变化**的反例。
   size／mtime 不单独证明内容不可变。
2. 比较平台稳定只读源／快照和本次拥有的临时副本，测创建成本、空间、权限、
   复制时源变化检测和清理；不假定 mmap 或一次 cp 就保证一致性。
3. 实验有偏移的有界读取、预取和顺序编码保存。
   页跨 UTF-8／UTF-16／GBK／GB18030／Shift-JIS 编码单元、CRLF、BOM、EOF 均无损；
   扫描编码声明的前两行及 Windows `coding: mbcs` 的远端代码页一次性确定编码，不每页启动探测命令；
   无法完整校验或无损编码时保留原目标及草稿。取消须终止本次生产者，不动共享连接。
4. 先在本机 shell 验证协议和背压，再在授权远端临时目录验真。
   复用现行 `LocalWorkspaceBackend.runSync` 的单进程 IO／取消所有者扩展分段协议，
   不再造第二个独立 SSH pipe engine；runner 当前返回完整 Data，必须证明新文本边界不先攒完整文件，
   也不每页／每行启动 SSH。保留其它业务原有有界 `Data` API。
5. 将稳定版本与局部修改组成可迭代快照，同卷私有临时写入；
   全部读取、校验、写入和目标核对成功才发布。
   核对短写、对端提前关闭、空间／配额不足、取消、断线和保存期间新编辑。
   当前远端 `atomicWriteCommand` 使用固定的 `$1.bailey-tmp`：
   对同路径两次保存、遗留临时名及预置符号链接核对隔离和安全清理。
   新流式契约必须独占本次临时资源，不复制固定名称造成并发截断。
   沿用实际可写资格，核对原文件权限／可执行位及链接语义，不顺带承诺完整元数据备份。
6. 区分连接／闲置截止与有进展传输，不把全 App 超时改无限。
   所有失败核对原文件、草稿和临时资源；进程退出 0 不等于完整传输。
7. 单独复验图片扩展名的合法 GB 文本和伪造／损坏图片头：
   现有 `readContent` 先以 `.max` 读取图片数据、再用 `NSImage` 尝试解码。
   新文本回退不得在进入分页之前已经下载／分配全文；
   格式判定的有界路径须同时保留真实图片预览及错误分类。
   此外，用真实临时 FIFO／socket、目录和可安全访问的设备节点检验普通文件资格：
   不可读对象不得阻塞文件打开、变成空文本或被保存覆盖；
   这是现有任意路径打开入口的适用输入，不为此新增通用文件类型框架。
8. 测稳定源创建、建索引和预校验自身的首屏前读写量；
   snapshot／clone／临时副本的创建成本和竞态不能从测量中排除。
   记录磁盘配额、权限及发布前后故障，不把临时空间无界增长换成“低 RSS”。

**验证与覆盖：**
`make test:SegmentedWorkspacePrototypeTests,RemoteCommandsTests,FileTabPersistenceTests`。
授权后才运行 `make test:SSHFileTreeLiveTests`；总集 E、D、I、S、R、L。
并发修改 × 缓存 miss × 保存，断线 × 写入 × 重连必须组合。
真实 SSH 参数沿用 testing 文档的 `BAILEY_P4_TEST_SSH_HOST` 与
`TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST`，两者指向同一个本 feature 获准主机；
每个 Windows MSYS2／POSIX 环境分别运行并记录实际系统／Shell／Git／命令能力，
不能因文档有历史主机授权便自动取得本次 GB 空间与断线实验授权。
未提供参数导致的 skip 不算实机证据，也不从用户 `/.ssh 的现存 master 借连接。

**文档、停止及提交：**
`evidence-p1.md` 给两种后端的稳定源策略、能力前提、磁盘／驻留预算、
拟修改的 WorkspaceBackend 方法签名及全部 conformer。
无空间／远端授权不做实机，记录具体缺口；稳定源和按需首屏冲突时交付实际代价。
原型测试提交规则同 P1-T1，不建立通用传输框架或远端常驻服务。

<a id="p1-t3"></a>
## P1-T3 GB 两侧 Diff 的有界数据与精度实验

**Files／锚点：**
`GitCommandExecution.runData`、`DiffTab.gitContent/gitComparisonBaseline/recomputeDisplay`、
`refreshEditDecorations`、`DiffCore.compute`、`DiffEngine.lineOps`、
`DiffComputation.build`、`DiffSyntaxHighlighter.captures`、
`DiffNativeSurface.editTextDidChange`。
在 `BaileyTests/Git/` 新增 `LargeDiffPrototypeTests.swift`，
使用真实临时仓库，复用 `DiffEngineTests` 和 `NativeGitHistoryFileTests`。

**步骤：**
1. 验证锁定 OID 的 blob 可以进入稳定分段源，不经 stdout 全量 Data／String。
   原文、clean 后内容和 patch 各自核对，不能混用坐标。
2. 对照现有前后缀／Patience／受限 Myers 的分页适配与 Git 原生流式 hunk。
   优先复用已安装 Git，但实测其自身 GB 内存及输出放大，不能只把压力移到子进程。
3. 同一 GB 基底制造首／中／末单点变化、重复行、整篇替换、超长行、重命名和改行数过滤器。
   **已发现 Git 2.54 xdiff 对 1 GiB 文本直接退出 128**：
   仅借助 `git diff --unified=0` 不具备 GB 级完整精确 hunk 准入。
   必须改为已验证的独立有界比较方法，不能提高超时或增加输出上限掩盖硬失败。
   同时覆盖 SHA-1／SHA-256、`.gitattributes working-tree-encoding`、
   不同文件编码与 Git patch 输出编码不一致、只改文件模式和大二进制源。
   当前 `gitComparisonBaseline` 将 patch 的输出直接交给 `newEncoding.decoded`，
   **须用真实 Git 原始输出与独立字节 oracle 验证**，不能默认 Git patch 总与文件原编码相同。
   核对定位、完整覆盖和重建字节，不能以整篇替换糊过小修改。
4. 分别测行哈希、hunk 索引、词级强调、ghost、Unified／Split 的成本；
   验证只构造需要的视口／hunk，不先做三篇全文富文本。
5. 预算、取消、连续编辑和旧结果发布逐项验证。
   未完成不得映射成空 diff，不能仅以后台执行证明有界。

**验证与覆盖：**
`make test:LargeDiffPrototypeTests,DiffEngineTests,NativeGitHistoryFileTests`。
总集 D、G、S、L；重复内容 × 小编辑、过滤器 × GB 原文、
取消 × 旧结果为必测组合。报告输入、patch、进程及子进程峰值内存和精度。

**文档、停止及提交：**
在 `evidence-p1.md` 记录算法选择、正常／最坏成本和完成度定义；
Git `hash-object --path --stdin` 当前一次传入完整原始 `Data`，`git diff` 当前有 `maxBytes * 4` 输出上限，
新路线必须分别解决原始哈希输入、patch 流及 clean 后比较坐标，不仅改 `cat-file`。
不在实验中移除 5 MiB、替换生产渲染或宣称正式支持。
只保留可重复的精度／预算回归，不保留永久第二套试验 engine；
失败不能用仅显示原文代替 Diff 交付。

<a id="p1-t4"></a>
## P1-T4 固定决策、预算并具体化后续任务

**依赖：** P1-T1～T3 证据齐全。核心 Gate 失败不准入依赖路径。

**步骤与产物：**
1. 将实验映射 R1～R6；逐个新类型／状态／接口写出消费者、唯一所有者、
   替代旧路径及证据。复用已有 generation、保存队列、错误通道和连接身份。
2. 锁定**原始字节坐标／所选编码增量解码／UTF-16 编辑坐标／Git LF 行坐标**四者的映射，
   覆盖 BOM、声明编码、远端 `mbcs`、手动重开与无损另存；保留 Undo、稳定快照和保存版本契约。
   Tree-sitter 的 UInt32 字节范围不能被误当成全 GB 默认解析能力。
3. 选定原生、稳定源、远端和 Diff 路线，在 `evidence-p1.md` 写
   Decision／Alternatives／Why／Risk；删除已被否决的实施分支。
4. 更新 `idea.md` 实证默认值及 P2／P3：明确新文件名、接口签名、
   调用和迁移顺序、每次接入与旧路径删除，以及准确测试选择器。
   不以“执行时再找入口”替代已可核对的事实。
5. 数值固定：首屏、最坏同步停顿、页／索引／Undo 驻留、临时磁盘、
   并发工作及取消收敛、跳转、搜索结果、保存吞吐、Diff 完成和细化。
   写清量纲、冷／热、硬件、输入分布和失败判定；热路径至少 30 次，
   给中位／p95／最坏值，不套用旧裸控件的 16／32ms 证明 GB 全功能。
6. 审查总集每个条件的测试入口和授权缺口。不能因无最低系统或远端条件删掉该条件。
   没有证据的可行性结论继续标未知，不能强行放行。

7. 修正共享链的先后依赖：本机和 SSH 都接通同一文档 IO 契约后，
   才能由共享 FileTab解除容量检查。不得靠检测 backend类型／机器身份，
   新增本机专用放行分支、远端全文默认实现或生产环境 unsupported占位方法。
8. 验证预算在优化方案比较前登记，依据现有基线、设备资源和用户结果制定；
   不能在测量失败后不断抬预算直到通过。调整预算需记录原因、前后结果和对验收的影响；
   若改变用户要求的可观察结果，应重新确认而非自批 Go。
9. 完成下文逐条件执行清单、task分派和根因反例检查。
   P2／P3所有依赖实验的签名、具体算法、状态及测试参数均须被实证结论替换，
   不能只将“具体化”这个 task标为完成却保留条件空缺。

**验证与 Gate：**
使用共享 `feature_tool.py todo validate`，核对真实 plan 锚点、源码路径和测试发现。
P1 Go 只允许按具体化路线实施，不等于功能验收。
No-Go 时交付最小冲突和解阻条件；不私自降成只读、全量加载或更换编辑器。
阶段实际审计时才由工具创建 `audit-p1.md`，不预建审计文件。

**提交：** 默认只有本地计划和证据，不作 Git 提交。

### 统一测量命令与证据格式

正确性使用各 task 的 `make test`／定点入口。
隔离优化 App 使用 `make build:dev CONFIGURATION=Release`；已通过 Make dry-run
核对它仍构建独立 `chiimagnus.bailey.dev`，不覆盖正式 App。
需要优化宿主测量时仍从根 Makefile 进入，只在该隔离测试构建覆盖 XCODEBUILD：

```sh
make test CONFIGURATION=Release ONLY_TESTING='BaileyTests/LargeDocumentPrototypeTests' \
  XCODEBUILD='xcodebuild -project Bailey.xcodeproj -scheme Bailey -configuration Release -destination platform=macOS,arch=arm64 -derivedDataPath build/DerivedData-Dev -clonedSourcePackagesDirPath build/SourcePackages -skipPackageUpdates -disableAutomaticPackageResolution ENABLE_TESTABILITY=YES'
```

其它原型类沿同一入口替换 ONLY_TESTING，不把 ENABLE_TESTABILITY 写入正式工程或发布配置。
优化 XCTest 仍不代替独立 App 的首帧、内存和 GUI 结果。
每条运行证据记录 Git／本任务 diff、系统、硬件、配置、输入字节、实际样本数、
最终字节／可见结果、完整退出码及对应条件 ID。当前计划未执行此命令。

## 覆盖执行契约

本节把“尽可能全面”落实到执行，不增加生产防御框架或另建测试体系。
当前所有新增用例、参数化运行和原型均是计划，尚无通过结果。

### 每个条件必须怎样落地

执行者在相应 `evidence-pX.md` 展开下文条件，复用现有 XCTest 和结果包：

- 一条记录对应一个可识别的条件／参数组合；包含条件 ID、负责 task、
  实际 `BaileyTests/类/方法` 或必要的 Dev 原生操作、
  输入容量／布局／种子、环境与配置、故障点／受控时间顺序、
  前提断言、最终断言、命令／退出码、日志／结果包和资源测量。
- P1 原型与 P2／P3 正式用户链分别记证据。
  同一模型用例不能代替 `FileTab`、`DiffTab`、两个后端或完整 App 的实际接入；
  其它 task 只有源码／配置／触发条件未变时才可复用有效证据。
  **先复用已存在的回归**，仅对它未证明的新条件增测：旧 5／8 MiB 断言必须改成新成功语义，
  不能保留旧拒绝测试再叠加新放行测试。
- 计划中的页大小 P、缓存预算 B、并发／输出／时间预算，由 P1 实验固定后代入实际数值。
  每个适用值与边界须展开到可执行输入；不能到实施时仍只留下“各种大小”。
- 先确认故障真的发生：例如主机确实断开本次通道、原子替换确实已发生、
  页确实被淘汰、OS 确实拒绝本次写入、Git index 确实处于指定冲突状态；
  FIFO 已真实创建并在非阻塞测试环境访问，Git 属性／过滤器确实生效，
  实际 Git OID 与内容和所测 SHA 格式相符。
  夹具失败单列，不能算产品拒绝正确或跳过后通过。
- 区分通过、失败、skip、前提无效、未执行；按实际参数组合统计
  预期／执行／各结果数量，不只统计 XCTest 方法数。
  循环中的参数值、随机种子和失败步骤须可复现；零匹配选择器不是验证。
- 不适用必须有当前入口／平台契约依据；缺系统、设备、授权或时间不是“不适用”。
  每个缺口列原因、已尝试／替代证据、潜在影响、补验动作及是否阻塞。
  必需原生分页、完整保存、真实 GB、本机／SSH、Diff 缺证据均阻塞无保留验收。

先完整运行所有安全可行单项、极值及有限可承受乘积。
若组合量超过可用资源，记录维度取值、组合总量／成本、
确切已执行与剩余组合及约束，再扩展多因素组合至安全可行最大范围；
不得预先以“两两覆盖”代替仍可运行的完整乘积。
L5 列出的交互是最低必测集，不是允许跳过其它组合的上限。
环境敏感的 TextKit、文件发布、SSH 和像素断言必须在相应实际环境重验；
普通纯算法无需在每个 GUI 外观下重复整套 E2E。

### 逐任务分派与完成断言

表中是各 task 必须核销的本链切片，命令见各 task。
条件全集定义在下一节；共享 ID 在不同链分别证明，不因另一链通过而自动核销。
新增方法名是实施目标，不声称当前已经存在；P1-T4 固定具体方案时再补齐其它参数化方法。

| 负责 task | 强制条件切片 | 测试入口与不可替代的最终断言 |
| --- | --- | --- |
| P1-T1 | E1／E3、D2～D4／D7／D8、I1／I4、N、L1／L2 | 拟新增 `LargeDocumentPrototypeTests.testFirstScreenAndEditBeforeSourceEOFWithoutGlobalIndex`：禁止夹具泄露全局长度，屏障未释放即有真实文字和有效编辑；原生布局／IME／Find／AX 每项给访问量、像素与原生事务证据 |
| P1-T2 | E2／E4、D1／D2／D4～D7、I、R、S4、L1 | 拟新增 `SegmentedWorkspacePrototypeTests.testStableStreamSaveAtEveryPublishBoundary`：两后端冻结一个版本，逐提交点故障后核对完整目标、草稿与生产者／临时资源；图片扩展名大文本不先全读 |
| P1-T3 | D1～D4／D7、G、I4／I5、L1／L2 | 拟新增 `LargeDiffPrototypeTests.testGiBRepeatedSmallEditsReconstructBothSourcesWithinBudget`：真实 Git 两侧及稠密变化均完整覆盖、重建正确，小改动不被糊成全替换；计入子进程和输出 |
| P1-T4 | 全集的适用性、分派、预算与缺口 | 原型结果→固定接口／算法／状态／数值→更新 P2／P3→实际测试发现与条件展开逐项对应；结构校验不能代替 Go 证据 |
| P2-T1 | D1／D4／D6～D8、N1／N2、I6、S4～S6、L7 | `TextDocumentTests` 对照模型逐步核对字节／坐标／Undo；`FileTabPersistenceTests`、`NativeFileTabTests` 证明挂载、非视图追加、标签切换器预览及 `.gitignore` 追加不借全文镜像，真实保存正确 |
| P2-T2 | E2／E4、D1／D2／D4～D7、I、R、S1／S2／S4、L1／L3 | `WorkspaceFileSessionTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`：本机与 SSH 共享契约，首屏前读量、全流哈希／重开、每个发布故障点、存活 master、FD／进程／临时文件共同核对 |
| P2-T3 | E1～E3、D1～D4／D7／D8、I1／I4／I5／I9、N、L1／L2／L5／L7 | `NativeFileTabTests` 和 Editor 各原生测试：实际入口越过 8 MiB、两后端 GB 编辑保存重开；冷页、未知索引、长行、IME、Find、剪贴板／AX 均不隐式退回全文路径 |
| P2-T4 | E4、I2／I3／I5～I9、R、S3～S5／S7、L3／L5 | 同一远端宿主／实机用例扩大并发与时序：两窗共享连接、一方取消另一方持续可用；断线／重连与新编辑交错后只写正确机器版本，不盲重试已发布保存 |
| P2-T5 | E1／E3、S、N1／N6／N7、I5／I6、L3～L7 | 现有文件／窗口宿主测试及 `EditorNavigationUITests`：真实入口、菜单焦点、关闭否决／确认、释放与重新打开最终字节；GUI 只补宿主不能证明的动作 |
| P3-T1 | G1／G3／G5、D1／D4～D7、I2／I3／I5／I7～I9、R | `NativeGitHistoryFileTests`、`GitExecutionTests`、`GitWorkspaceSSHTests`：锁定 OID 的真实字节、空侧资格、filter 原文／比较文分离，失败不变空 diff |
| P3-T2 | G2／G4／G5／G7、D2～D4／D7／D8、I1／I4／I5／I9、N4／N5／N8、L1／L2／L7 | `DiffEngineTests` 与 `NativeDiffTabTests`：精确小 hunk＋两侧完整重建、稠密输出预算、真实取消、模式／折叠像素；保持现有工作区原生折叠和最新快照坐标，隐藏只读表面不留 GB 副本 |
| P3-T3 | G、D1／D4～D8、I3／I5～I7／I9、N1／N2／N6／N7、S4／S5、R | `NativeDiffTabTests`、`NativeGitHistoryFileTests` 及保存保护：全部来源越过 5 MiB；点击／ghost／过滤器坐标下编辑、Undo、原始字节保存；历史与暂存拒绝写入 |
| P3-T4 | 全集及适用的跨链组合，重点 E、L4／L6 | 全宿主、隔离 Release、必要 GUI、签名／交付各自留证；按参数组合对账，无孤立条件、无夹具假通过，全部缺口逐项判定后才能下验收结论 |

新增发现追加到条件总集和负责 task，不把测试留给“以后统一审查”。
P2／P3 每块提交前还须沿实际入口追到最终读写／渲染，核对已删除旧全文路径；
静态搜索仅辅助，不能取代运行中的读取计数、原生结果及最终字节。

## 验证条件总集

本总集约束 P1～P3，每个 task 的切片不豁免其它适用条件。
执行在相应 `evidence-pX.md` 按条件 ID 记录输入、真实命令、最终结果和逐项缺口。

### E 环境与配置

- E1：**当前本机** macOS 27.3、Apple Silicon／32 GiB RAM、Xcode 27.2、Swift 6，
  Debug／优化构建及真实 SDK／部署目标分别核对。
  另有 `.github/workflows/ci-ui-test.yml` 的 `xcode-27` Host／UI Runner（指定 Xcode 27.2）；
  CI 只在明确触发后记录其**实际 macOS 版本**、Git、签名、XCTest 总数与退出码，
  不把本机绿色或 CI 编译绿色当对方真实环境通过。最低部署目标仍为 macOS 15.6；
  有可用旧系统时补跑受影响的原生、IO 与性能路径，缺设备时明确列为旧系统验证缺口，
  **不为本 feature 专门搭旧系统 VM 或把未实测兼容性写成已通过**。
  SDK 可编译不等于老系统运行；当前本机证据不自动外推其它设备和内存。
  核对 Swift 6 语言模式、MainActor 隔离及 Debug／Release 实际优化条件。
- E2：本机不同**可控缓存预算**、可用磁盘空间及本机 APFS 与授权 SSH 实际文件系统；
  必测读写权限、只读目标、同卷原子替换。其它内存机器和不同卷仅在可安全取得时补测，
  不为测量专门换机／换卷或提高最低配置。
- E3：默认／非默认字号与字体、可变宽／等宽、折行两态、四档超长行宽、
  窄／宽窗口、亮／暗、中／英文；验证像素、命中、滚动和设置即时传播。
- E4：本机、受控 shell、真实 Windows MSYS2 SSH、真实 POSIX SSH；
  开发签名、隔离 Dev 配置。模拟 shell、宿主和完整 App 的证据分别报告。

### D 输入、容量与坐标

- D1：空、1 字节、旧 5／8 MiB 的 -1／恰好／+1，页／预取边界相邻字节，
  编辑使文档跨过旧容量或策略边界；核对完整重开字节，不只是读取成功。
- D2：256 MiB、真实合法 UTF-8 的 1 GiB，2^31／2^32 附近长度／偏移；
  可安全生成时运行 2／4 GiB 实体文件。整数模型测试不冒充真实容量、UI 或传输。
- D3：海量短行（10 万／百万行）、平均代码行、混合长短行、重复行、密集嵌入语言、
  **单个超长逻辑行**（与百万短行分开）、空行及末行有／无换行；
  在相同字节规模下对比行数极多／单行极长的索引、内存、首屏、编辑及 Diff 精度。
- D4：ASCII、中文、emoji／代理对、组合字符、双向文本、tab；**全部现有文本编码**：
  UTF-8（含 BOM）、UTF-16 LE／BE BOM、GBK、GB18030、Shift-JIS、Windows-1252、Latin-1，
  Windows SSH 的 `coding: mbcs`，文件头声明与手动重开／另存；
  LF／CRLF／裸 CR／LS／PS 及混合换行；页边界拆多字节编码单元／CRLF，
  核对声明匹配、严格往返、UTF-16 坐标和原字节。
- D5：所选编码下的无效／截断字节、错误 BOM／声明、无法编码字符、真实二进制；
  UTF-16 合法零字节与未知编码的 NUL 分别判定，不能把 `NUL` 一概认定二进制；
  合法图片、损坏图片回退和图片扩展名合法大文本。
  未访问区发现错误仍保留草稿，不发布不完整保存。
- D6：缺失、删除后重建、Unicode／引号／换行／长路径，同名不同目录、
  本机／远端同路径、符号链接（含断链和指向变化）、Windows 大小写别名；
  **普通文件、目录、FIFO、socket、设备节点**逐类验证：仅真实可编辑文件能进入
  该文件会话，非普通对象不会挂起打开或被按文本保存；沿用现有可写资格，不换目标。
  符号链接、可执行位及权限与当前保存行为逐项对照；若选择的发布机制会改变
  硬链接、ACL 或扩展属性，再做针对性回归并明确原有保证边界；
  不把内容原子替换宣传成完整元数据或所有别名同步保证。
- D7：字节／UTF-16／行号分别测 0、1、页 P−1／P／P＋1、
  多页、EOF 前后；有界模型测试 2^31／2^32／Int.max 附近的范围、加法溢出、
  offset＋length、非法负数／越界协议值及转换，绝不截断后用作合法地址。
  只有真实可达入口才加对应校验，不据测试维度发明生产协议；
  模型测试与 1／2／4 GiB 实体证据分开。
- D8：同一组合字符簇／ZWJ emoji／连续组合标记跨越多个页，
  密集空行、一个巨段落、连续 tab、双向段落及非 BMP 字符密集正文。
  字节、UTF-16、grapheme 和原生段落边界不可混用；预算不能靠切断合法文本满足。

夹具先证明字节数、编码、行分布、OID和编辑范围，再触发产品动作。
大夹具顺序生成／校验，不先分配 GB String／Data，不能拿 NUL 稀疏文件当合法文本。
最终核验使用独立流式逐字节比较，或源／期望流／实际目标的流式 SHA-256 加关键范围；
不能仅检查尾部 marker。页／索引统计还须证明首屏前没有全量下载或解码。

### I IO、快照与资源故障

- I1：冷／热、顺序／随机、预取、反向跳转、淘汰后重读、重复请求、多消费者；
  核对缓存与索引驻留、合并请求及正确正文。
- I2：源原地改写、**同长度同 mtime** 字节改写、增长／截断、原子替换、
  符号链接目标更换和重命名，发生在读取／建索引／保存源快照期间；
  证明稳定源或明确拒绝过期结果，不只比较 size／mtime、不混拼版本。
- I3：短读／短写、EOF、源删除、权限、临时目录不可用、空间／配额不足和校验失败；
  原目标无部分覆盖、草稿和 Undo 保留、错误可重试，注入须经过实际消费路径。
- I4：页／索引／Undo／临时正文预算边界及超预算，大量新增、全删、反复 Undo；
  验证 spill／回收或明确失败，不丢编辑，不把压力转移成无界子进程。
- I5：取消发生在打开、读页、索引、搜索、编码、写入、发布前／后各实际提交点；
  本次生产终止，发布前不改目标；已发生副作用必须按实核对，不能声称自动撤销。
- I6：迭代保存快照时继续编辑、Undo、再次保存、外部修改与重命名；
  写出一个完整版本，后续编辑仍脏，旧结果不清除新草稿。
- I7：逐实际事务点测试：源／临时目标创建前、冻结源中、写一部分、
  全部写完但校验未完、校验后／rename 前、rename 后／回执前、清理中。
  发布前旧目标完整；发布后目标只能是实际完整版本，
  回执丢失不得误标已撤回、清除草稿或盲目覆盖重试。
  安全时只终止本次隔离写入子进程，检查目标、孤立资源与后续重开。
  不承诺此前没有的崩溃草稿恢复或断电持久性；不杀用户进程、不做主机断电实验。
  同目标并发保存、临时名碰撞／预置链接、遗留资源与清理失败分别测；
  本次临时写入不能截断另一写入或跟随未知链接，清理不能误删其它事务。
  外部写者在目标校验与发布间的保证边界须实证说明，
  普通 stat 后 rename 不算对任意第三方写入的原子 compare-and-swap。
- I8：底层允许的短读写、0 字节／EOF、1 字节分片、多字节字符／BOM／协议头跨块、
  stdout／stderr 同时拥塞、stdin 提前关闭、消费者慢于生产者、重复冷页请求。
  核对背压、请求合并、需求页不被预取饿死、任务数／打开句柄数及取消后收敛；
  分片和错误注入须经过生产消费边界，不仅在 fake 自身返回错误。
- I9：实际支持预算 B 的下界及 B−1／B／B＋1工作集、一个页大小、
  全部活跃文档合计超预算；并行索引／Find／Diff／保存，
  冻结快照持有时淘汰、page-in 在途失效、关闭后迟到结果。
  正文、索引、Undo、hunk、队列、子进程、FD 与临时磁盘分别计量和核对释放。
  不要求无效的零预算成功；不以清空页表但仍保留其它全文所有者达标。

不通过填满用户磁盘或耗尽系统内存制造 I3／I4。
受控错误注入、小配额夹具和安全隔离的真实系统错误分别报告；
Windows 原子替换等平台行为仍须对应实机证据。

### N 原生编辑与可见结果

- N1：首／中／末、冷页边界输入／删除／粘贴、跨页选区、多选区、全选／整篇替换；
  正确位置、Undo和磁盘字节，局部操作不强制复制全文。
- N2：IME 组合、候选替换、显式范围、跨页组合、确认／取消、Undo／Redo；
  与系统 NSTextView 契约一致，一次组合一条事务，无全文组合快照。
- N3：现有原生 Find／Replace 的全部可达选项、正反向／环绕、跨行／跨页、
  相邻／重叠／无命中及替换全部；完整搜索、真实可见定位、可撤销和保存。
  结果显示数量上限不能冒充搜索结束；不新增原本没有的正则语法。
- N4：至少 17 次交错远跳、窗口／Dock 改尺寸、字体／折行切换、
  超长行完整显示和往返横滚；实际文字像素、行号、命中和滚动位置正确。
- N5：语法有／无、单语言／嵌入、多页上下文、连续编辑、重命名换语法；
  颜色属于当前版本，预算降级不丢正文或编辑。不能按可见页独立解析而误报上下文颜色。
- N6：可写／只读 AX、选区／范围读取、键盘和 Find 菜单前台路由；
  不让只读文档经 AX 被改写，也不为 GB 校验主动索取 AX 全文。
- N7：复制／剪切小范围及整篇、多选区、页外选区、跨窗口粘贴、原生 Services、
  AX 普通查询及显式全文值请求；对照平台真实协议、权限及 readonly 行为。
  区分正常交互隐式全文分配与用户明确请求整篇导出的必要成本，
  系统 API 无法有界时记录冲突，不能默默截断或直接禁用。
  自动化只操作本次隔离 Dev 及可恢复的测试剪贴板，不覆盖用户内容。
- N8：全局长度／行索引尚未知时首屏输入、Cmd-End、全选、Find、
  恢复落在未读区的选区／滚动、窗口 resize 与策略切换；
  冷页返回失败或晚发现非法字节时已编辑前缀仍可保留。
  对未知进度明确等待／可取消，不以局部 EOF、估算位置或占位正文冒充完整文档。

如原生某项 Find、AX或长行行为无法有界实现，P1 交付具体冲突和影响，
不能在 P2 偷偷关闭选项、切只读或用缩水查找替代完整需求。

### S 时序、更新与保存保护

- S1：首次／已加载／失败重试／会话恢复，未消费／已消费标签；
  保持懒恢复、不全项目预读，失败不被旧 unavailable 永久锁住。
- S2：重复展示、窗口激活、在途初读／刷新、乱序完成、干净／脏文档；
  合并工作、不反复搬运全文，旧结果不覆盖新编辑。
- S3：同窗／跨窗、A→B→A、切项目、Dock 移动、关闭标签／项目／窗口／App及取消关闭；
  对象、Undo、焦点、保存保护与释放符合现行契约。
- S4：手动／失焦保存、保存中再次编辑／保存／关闭，另一原本干净标签变脏；
  核对串行写入字节、错误与关闭否决，不只看任务完成。
- S5：移动／重命名／删除、Git 操作前等待保存、同路径两份不同草稿；
  保留目标、拒绝冲突，旧路径不被迟到写入重新创建。
- S6：`.gitignore` 挂载／未挂载／读取中／离线／刷新失败时追加，
  Dock 标签切换器在大文件首／中／末选区展示短预览；
  都从同一文档取实际所需范围，保留外部变更、草稿和原生 Undo，不回到全文字符串旁路。
- S7：前后台、长时间闲置、系统睡眠／唤醒后首次冷读与保存、
  失焦自动保存和远端重连交错；复用已有生命周期，不预建新恢复层。
  安全宿主模拟通知与真实获准设备操作分别报告，
  不为测试令正在使用的主机睡眠、修改时钟或中断用户网络。

### R SSH、授权和真实传输

- R1：首次连接、在线、慢但有进展、无进展超时、认证／主机信任／命令失败；
  有进展的 GB 传输不被旧整文件截止误杀，失败仍有边界。
- R2：断线在冷页、预取、保存前／中／发布后、关闭期间发生，原机器换通道重连；
  保留草稿／Undo，旧结果失效，不能续写另一目标。
- R3：两文件／两窗共享 master，一方取消／关闭，专属测试 socket 清理；
  只终止本次拥有的生产任务，另一文档与用户 SSH 不受影响。
- R4：Windows MSYS2／POSIX 的偏移读取、原子替换、路径转义、权限、清理失败；
  分别验证高压缩率重复文本／不可压缩文本的 SSH 传输吞吐和本地解压后内存，
  而非只看网络传输字节；平台分别给实际字节和能力证据，
  无法清理的本次临时路径可追踪。

### G Git 与 Diff

- G1：worktree、staged、commit、revision、revisionWorktree，
  首提交、冲突各 stage、增删、重命名、特殊路径、模式-only；
  **SHA-1／SHA-256 OID**、符号链接 blob 与 submodule 非普通文本对象须区分。
  核对真实 index／tree、OID、空侧和只读性，不误用状态元数据上限限制正文。
- G2：旧边界相邻字节、两侧 GB、一大一小；相同、首中末单点、小范围增删、
  重复行、多 hunk 和整篇替换；Git loose blob 与可安全生成的 packed／delta blob
  分别核对读取完整性及 Git 子进程成本；小改动不能糊成整篇替换。
- G3：LF／CRLF、`core.autocrlf`、`.gitattributes` 的 `text`／`-text`／`eol`／
  `working-tree-encoding`、clean filter 改字节／行数、Unicode 非同字节文本；
  patch 原始输出编码与工作区所选编码可能不一致，需以 Git OID、实际字节及独立
  patch oracle 证明比较和原始保存正确，不能靠 `newEncoding.decoded(patch)` 自证。
- G4：Unified／Split、折叠／展开、两侧长短不同、长行、主题／字体和首改动定位；
  新 Git 快照由长→短→空时旧 fold、ghost、UTF-16 索引失效与 Split 左侧基线保留正确；
  像素、行号、滚动及同一工作区原生文档身份正确，不构造三份 GB 富文本。
- G5：读取失败／短 blob／无效 OID／权限／断线，预算到期／取消／重试／连续编辑；
  保留有效显示，未完成不变空 diff，旧结果不发布。
- G6：工作区输入、IME、Undo／Redo、保存和在途新编辑，历史／暂存 AX 写入；
  正确原始字节，只读始终拒绝写入，ghost／装饰不成为正文。
- G7：两侧空／一侧空、相同巨文件、稀疏小改动、几乎每行变化、
  高重复内容、单 hunk 巨大输出与海量小 hunk；
  构造可复现的行指纹相同但原字节不同情况及 Unicode 规范等价字节差异。
  原文重建与精确定位用独立 oracle，不让 hash、Git 成功或算法自身同时充当答案。
  重复行可有多个正确分解，断言完整重建及登记的精度界限，不机械要求唯一 patch；
  单点变化等定位确定的夹具仍须严格核对位置与范围。
  正文／patch／行摘要／词级强调／ghost 的最坏放大分别核算，
  预算不足明确未完成，不把整篇替换或空 diff 当作自动成功。

### L 测量、生命周期和组合

- L1：冷首屏、热输入、随机页、搜索、保存、Diff 分开计时，
  同时记录读取字节、页／索引／Undo、临时磁盘、CPU、物理足迹与子进程。
  `open` 返回、事件派发、AX 存在或单次 RSS都不是首帧／有界证明。
- L2：热操作至少 30 次，首中末、折行两态和各实际策略分别给中位／p95／最坏值；
  不混算首次构建、冷文件系统与热缓存。压力结束检查队列收敛和空间。
- L3：打开→遍历→大编辑→Undo→保存→关闭→重开连续循环；
  隐藏保留必要状态，真正关闭释放独占资源，旧 SwiftUI／NSScrollView 被持有也不留正文。
- L4：有限且可承受组合完整遍历。规模过大先执行每个适用取值与极值，
  再扩展两两／多因素组合至安全可行的最大范围，不能用抽样豁免可测单项。
- L5：必须另测：UTF-8／UTF-16／GBK／GB18030 多字节编码单元、BOM／CRLF 跨页×插删／Undo；
  手动重开／声明 `mbcs`×SSH 分页×无损另存；未验证页发现无效编码／二进制×保存；
  缓存淘汰×IME／Find；快照保存×外部替换／新编辑；重连×旧页／旧保存结果；
  稠密短行×多标签×索引预算；巨长单行×完整显示×冷页；
  GB 两侧×重复行小改动×精度预算；clean filter×统一／分栏×编辑保存；
  窗口关闭×其它窗新草稿。
  再加入：未知 UTF-16长度×首屏／远跳／恢复；巨字符簇×冷页×IME／选区；
  图片扩展名大文本×远端首屏；B 边界×并发索引／Find／Undo；
  rename 已完成×断线／取消×再保存；工作区**单一原生** `editPane`×折叠／分栏×GB；
  短 IO／stderr 背压×取消×共享连接；稠密 hunk×输出预算×重试；
  Git 长→短→空新快照×旧折叠坐标／Split 左栏；Dock 缩略预览×GB 文档×正文缓存淘汰；
  特殊文件×本机／SSH 打开取消；同大小同 mtime 外部替换×冷页／保存；
  `working-tree-encoding`×clean filter×GB Patch；SHA-256×重命名×历史只读。
- L6：先定点 Red→Green，再测共享实现的相邻入口。阶段收尾执行适用的完整宿主、
  构建／签名及不可替代 UI；不在每个纯模型 task 重复整套 GUI。
- L7：复用 XCTest 写确定性模型对照，不引入 property-test 框架：
  小输入 oracle 可完整持有 String／原字节，产品入口不能借用这些索引／答案。
  穷举可承受的小输入／有效边界，再按预登记种子跑插删替换、分片、
  Undo／Redo、淘汰、冻结快照与保存序列；每步核对字节、坐标、脏状态和所有保留版本。
  失败保留种子／最短可复现操作序列；不能只做最后一次字符串比较。

### 外部前提与未覆盖条件

| 条件 | 本轮限制 | 替代证据、影响和补验要求 |
| --- | --- | --- |
| P2／P3 正式实施 | 本轮明确执行 P1 | P1 Gate 证据通过之前不得开始；P1 实验不能算产品已交付 |
| 最低及其它 macOS | 未取得对应系统 | SDK／源码只能支持可用性判断；取得机器后补原生、IO、GB，限制平台验收声明 |
| 低内存／其它卷 | 未确认授权设备、空间和卷 | 小预算验证保护，不冒充硬件性能；取得隔离资源后补测 |
| Windows／POSIX SSH | 未取得本 feature 的主机、目录和 GB 空间授权 | shell 只证明协议；明确授权专属 socket和临时目录后补实机，缺必需后端证据不宣称全面交付 |
| 完整 GUI／真实 IME | 未取得独占焦点／专用图形会话 | 宿主只证明组件；隔离 Dev 补前台键盘、候选、菜单、跨窗和重启 |
| 2／4 GiB 实体极值 | 生成和原子保存需额外空间 | 先核对独立测试卷剩余空间及同时存在的输入、稳定快照、输出与 Git 对象峰值；安全可行时顺序补实体，模型测试不能证明实体极值 |
| 系统 ENOSPC／真实压力 | 不得破坏用户环境 | 注入和实际错误分别报告，在安全隔离卷／设备补系统路径，不填满主机 |

新增缺口也逐项记录条件、原因、替代证据、潜在影响、补验方式与是否阻塞。
原生分页、完整保存、真实 GB 路径或用户要求的 Diff／SSH 若缺必要证据，
不能给无保留的完成结论，更不能以“计划已写”绕过。

## 阶段审计

P1 tasks 实际结束后由 executing-plans 进入 plan-task-auditor；
工具届时生成 `audit-p1.md`，核对证据和 Go／No-Go再交回执行流。
本轮按 `executing-plans` 执行 P1；原型、状态与实验结果由 `evidence-p1.md` 记录，
不预先放行 P2／P3。
