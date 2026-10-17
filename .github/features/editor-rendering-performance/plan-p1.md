# P1：稳定编辑器滚动与降低编辑成本

## 范围与执行顺序

目标与验收由 [idea.md](idea.md) 定义。保留五个任务：T1 复现并测基线 → T2 修已证实的滚动根因 → T3 验证并调整文件容量 → T4 消除已测编辑热点 → T5 综合验收。实时状态只在 [todo.toml](todo.toml)；用户于 2026-10-17 授权执行全部任务，另授权 windows 专用临时 SSH 测试和隔离实例前台验收。

T2／T4 是有证据后选最小修复，不是预先批准几何引擎、正文所有权迁移或分段树。T3 若容量候选因现有编辑成本不满足 T1 确立的资源条件，不得先宣布完成：记录具体依赖，先推进不依赖新容量的 T4 组件工作，再回到真实 FileTab 验证。不要为顺序整齐放行不安全的大文件。

每项代码改动自己完成接入、旧路径删除、Red→Green、文档同步与原子提交；T5 不负责补前面欠下的测试／清理。功能代码按仓库要求验证、验签及整包安装，不退出或重启现有 Bailey。Feature 文件按 Skill 默认保留本地，不擅自提交、推送或创建分支。

<a id="审查依据"></a>
## 审查依据

2026-10-17 独立核对当前源码；没有读取或沿用已有 `audit*.md`。审查基线为 `02c6478`，开始时工作树干净。CodeGraph 对自有代码建立入口关系；其索引未覆盖 STTextView 内部符号，Vendor 与依赖通过逐字源码补证。以下是受本计划影响的执行闭包，不宣称已审完无关终端／浏览器／Git 全部实现，也不宣称产品缺陷已运行复现。

### 样本与平台

- 本地 Git 已找到与原记录行数／字节数一致、可固定复现的历史样本：`618c77bc19e9876a8a4d4e76d0d0777ffe2f45c8:kero/Files/FileTreeModel.swift`，382 LF 行、16,050 UTF-8 字节，blob `42fe797b6a6307d65532581238b3d884e25107cf`。原计划没有样本哈希，不额外宣称已证明它与当时用户打开的字节完全一致。T1 从此对象提取，不从当前文件截取 382 行，不依赖外网历史链接。
- 当前文件为 [Bailey/Files/FileTreeModel.swift](../../../Bailey/Files/FileTreeModel.swift)，431 LF 行、18,440 字节，SHA-256 `972cf6ce8ca43428873fdcc439f101b67887e254d0bb15aef40626eb583dfcb3`。它是额外的小文件对照，不冒充历史样本；执行时重新记录提交／哈希和计数口径。
- 工程 App／XCTest 是 Swift 6、arm64、最低 macOS 15.6；当前审查机为 macOS 27.2／Xcode 27.2，CI 配置为 macOS 26／Xcode 26.6。这些是配置／命令读取结果，不是三个环境均已测试。
- `NativeUI` 是 [BaileyTests](../../../BaileyTests) 内的目录，不是独立 target。全部新增回归接入现有 `BaileyTests` XCTest／`Bailey` scheme，仍通过根 [Makefile](../../../Makefile) 执行。

### 实际执行链与责任

| 路径 | 已核对的源码／契约与最终结果 |
| --- | --- |
| 初读与干净重载 | [FileViewerView.swift](../../../Bailey/Editor/FileViewerView.swift)：`loadIfNeeded/waitForText/refreshWhenSelected → reloadFromDiskIfClean → readContent/loadedContent`；[LocalWorkspaceBackend.swift](../../../Bailey/Workspace/LocalWorkspaceBackend.swift) 有界 FileHandle 读取、原子写入；[SSHWorkspaceBackend.swift](../../../Bailey/Remote/SSHWorkspaceBackend.swift) 有界 head／命令失败映射，写入经 [RemoteCommands.swift](../../../Bailey/Remote/RemoteCommands.swift) 临时文件再 rename。核对的是最后字节，不是只发出保存动作。 |
| 原生生命周期 | [SourceTextEditor.swift](../../../Bailey/Editor/SourceTextEditor.swift)：`makeCoordinator → makeScrollView/makeNSView → update/dismantle`、字体／颜色等值守卫、`sizeThatFits`、`RestorableScrollView`。FileTab 强持有 coordinator，coordinator 持有 scroll view；`editorView` 仅是挂载期间的弱引用，卸载不释放真实文档。 |
| 几何、导航与输入 | [STTextView.swift](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView.swift) 的 `prepareContent/layoutText/layoutViewport/updateContentSizeIfNeeded/setFrameSize/relocateViewport/sizeToFit`；[视口代理](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextViewportLayoutControllerDelegate.swift)、[Scrolling](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Scrolling.swift)、[Gutter](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Gutter.swift)、[布局片段](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextLayoutFragment.swift)、[Finder](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextFinderClient.swift)、[输入法](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift)。 |
| 编辑与解析 | 原生 `replaceCharacters` 在事务前后经 [DelegateProxy](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextViewDelegateProxy.swift) 交付 range；然后 `didChangeText` 通知 FileTab 回写／判脏。插件经 [SyntaxHighlightPlugin.swift](../../../Bailey/Editor/SyntaxHighlightPlugin.swift) 更新 [TextCoordinateIndex](../../../Bailey/Editor/TextCoordinateIndex.swift)、Neon Highlighter 与 [TreeSitterClient](../../../Vendor/Neon/Sources/TreeSitterClient/TreeSitterClient.swift)。旧坐标／新坐标的转换顺序和后台不可变读快照不能被合并回调破坏。 |
| 其它正文消费者 | [Project.ignoreGitPaths](../../../Bailey/Workspace/Project.swift) 先等待新鲜正文，再判换行／追加／保存；[TabSwitcherView](../../../Bailey/UI/Panes/TabSwitcherView.swift) 取有界摘要；[PaneTab](../../../Bailey/Workspace/PaneTab.swift)、Project 与 [TerminalManager](../../../Bailey/Workspace/TerminalManager.swift) 路由自动保存、Git 前置保存、关闭与退出，不能只改编辑器回调。 |
| 共享 Diff | [DiffTextView.swift](../../../Bailey/Git/DiffTextView.swift) 的固定段落行高、`applyContentHeightOverride`、`setReviewDocument/setEditBufferText`、ghost 间距、两轴同步和 review 禁止追随选区；LF 行数不适用于裸 CR／Unicode 分隔符，已有相应原生回归。 |

依赖边界另核对已解析 checkout 中 STTextKitPlus 的 `NSTextContentManager.attributedString(in:)` 和 SwiftTreeSitter 的 `Parser.readFunction(for:)`，不能把 `build/SourcePackages` 内上游 Neon／STTextView checkout 误当成工程实际链接的 `Vendor/Neon`／`Vendor/STTextView`。相关规则已按 [architecture](../../../docs/architecture.md)、[standards](../../../docs/standards.md)、[ui](../../../docs/ui.md)、[testing](../../../docs/testing.md)、[development](../../../docs/development.md) 及 [editor](../../../docs/features/editor.md)、[diff](../../../docs/features/diff.md)、[ssh](../../../docs/features/ssh.md) 核对。功能文档只写已实现事实，不把本计划能力提前写入。

### 执行前发现与计划修正

| 发现 | 证据与影响 | 本计划的处理 |
| --- | --- | --- |
| 旧路径／样本不可复现 | 当前没有 `kero/`，当前 FileTreeModel 也不是 382 行。原计划还沿用 P6、旧名称和历史测量链接作为当前前提。 | 用上面的固定 Git 对象及当前对照；移除无依据的并行阶段假设，不从历史审计继承结论。 |
| 过早指定“唯一几何模型” | frame 不仅由 `updateContentSizeIfNeeded` 更新，`relocateViewport` 与 `sizeToFit` 也能写；后者还调用全文 ensureLayout，但 SourceTextEditor 未调用它。 | T1 确认实际到达的入口，T2 只收敛真实冲突写入，不无条件重做全部几何路径。 |
| 只稳高度不能证明布局正确 | TextKit fragment 的 Y 仍可能是估算；`rowCount × rowHeight` 与 frame 稳定不保证行落在正确位置。现有 Source 没有 Diff 的固定段落行高配置。 | T2 必须核对布局片段／可见字符、命中、选区及导航，固定行高只是待实验候选，不强改字体或套用 LF 索引。 |
| 后台补布局被误当成现成能力 | 原计划写“需要异步补足显示行几何”，但没有已验证的安全调度、准确度或代价。 | 删除该预设；对当前 AppKit 文档的布局／状态变更留在主线程。不新增 worker、预热器或 WrapMap；若最小原型不能满足需求，记录限制并修订方案，不悄悄缩水验收。 |
| 把全文 getter 当成整文物化 | 固定依赖 STTextKitPlus 的 `attributedString(in:nil)` 对 NSTextContentStorage 直接返回 `textStorage`，不是它的慢路径拼接。Swift String／NSString 桥接、UTF 编码、比较及后续写入是否复制仍需测。 | T1 分开计数、耗时与分配；T4 删除强制迁移正文所有者、强制解析／保存共用快照的要求，先使用现有 range 回调和最小改动。 |
| 把挂载状态当正文所有权 | `dismantleNSView` 清掉弱 `editorView`，但保留 coordinator／原生文档。`appendText` 当前通过弱引用找 view，未挂载走 String 分支；若只优化“可见编辑器”会保留双轨和过期原生内容。 | T4 加“曾挂载→卸载→追加→保存→重挂载→Undo”回归，使用同一个长期标签所有者；不在卸载时新建缓冲／丢撤销。 |
| 容量与语义边界混在一起 | FileTab 和 Diff 都有 5 MiB，但分别拥有契约；图片候选读取还走无文本上限分支、无效图回落文本检查。 | T3 只调整 FileTab 可编辑容量，Diff 仍独立验证原上限；保留图片回落及后台解码，不全局替换“5 MiB”。 |
| 验证停在模拟中间层 | `EditorWorkspaceFixture` 实现 WorkspaceBackend，不执行 SSHWorkspaceBackend 的 head／错误处理／写入命令。现有导航测试主要用裸 STTextView，不覆盖 SourceTextEditor 的恢复／resize 链。 | T2 加真实 Source 桥接；T3 复用 RemoteCommandRunner 边界测试实际 SSHBackend，实机 SSH 单列。覆盖表区分三层，不冒充 E2E。 |
| 清理缺少具体删除对象 | 只写“清理兼容层”无法执行，保留保护清单又容易冻结过时补丁。 | T2／T4 下列出有据的旧包装、常量围栏与条件替代分支；新路径成立就同任务移除，不无条件保留旧补丁，也不先删真实边界。 |

平台依据：本机 SDK 的 `NSTextViewportLayoutController.h` 明确 `relocateViewport` 返回建议锚点，`adjustViewport` 用于不改变内容的视口偏移；[Apple relocateViewport](https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontroller/relocateviewport(to:))／[adjustViewport](https://developer.apple.com/documentation/appkit/nstextviewportlayoutcontroller/adjustviewport(byverticaloffset:)) 并未承诺首帧精确全文高度。[usageBounds 文档](https://developer.apple.com/documentation/appkit/nstextlayoutmanager/usageboundsfortextcontainer) 确认 KVO 与约束更新用途，不能仅因它是“围栏”删除观察。Zed 的 [ScrollAnchor 源码](https://github.com/zed-industries/zed/blob/main/crates/editor/src/scroll.rs) 支持“文本位置＋显示偏移”的参考；不再引用未在本轮核验的其它模块作为实施要求。

<a id="覆盖与证据"></a>
## 覆盖与证据

T1 建立同一份 `evidence-p1.md`，以后各任务补事实与缺口，不另建永久矩阵／诊断服务。临时公开／合成样本和采样产物放 `build/performance/editor-rendering/`。下面各项是待执行条件，不是通过记录。

| 维度 | 必须覆盖的适用取值／极端情况 | owner／结果 |
| --- | --- | --- |
| 系统与工具链 | macOS 15.6 最低运行时、CI macOS 26／Xcode 26.6、当前 macOS 27.2／Xcode 27.2；Swift 6／arm64；Debug 与优化构建、开发签名与 CI ad-hoc 分别核对。 | T1 记录可用环境，T2–T4 按影响验证，T5 核销；不可用系统不能用当前 SDK 编译冒充运行。 |
| 样本形态 | 历史 382 行、当前小文件、1k／10k／100k；至少一个 100k 样本 > 旧 5 MiB。空、单行、只换行、连续空行、末尾有／无换行、长行（含极长单段）、行长悬殊、密集语法与大块注释。记录 UTF-8／UTF-16、LF／原生段落计数及最长行，不能只按 Swift Character 计行。 | T1 固定样本与哈希；T2 几何，T3 字节边界，T4 编辑与解析。极长段落不可拆掉以绕过 TextKit 成本，实际限制如实记录。 |
| 字符与坐标 | ASCII、中文、emoji／代理对／ZWJ、组合附加符、规范等价但字节不同、Tab、LF／CRLF／裸 CR／U+2028／U+2029／混合；非法 UTF-8 与合法文本分别处理；解析 chunk 前后、EOF 和空文档。 | T2 用 TextKit 的段落／视觉行语义；T4 的 Tree-sitter Point 只按 LF、UTF-16 字节列。索引不可互相替代。 |
| 布局配置 | 换行开／关；TerminalFont 默认 JetBrains Mono（缺失时系统等宽）、其它可选字体与实际回退字形；AppSettings 字号范围 8／32 端点及默认 13；窄／宽／近零尺寸／隐藏→显示；live resize／结束；两种外观与 en／zh-Hans；行号开关、9→10／99→100／999→1000 位数变化；overlay／legacy scroller、1x／2x／当前刷新率能取得的环境。 | T2 核对 clip／文档／content／gutter 坐标、像素误差、宽度回流；不写用户设置或系统偏好取得组合。 |
| 滚动与定位 | 首次未知区／已布局区；小步、快速、反向、拖滑块、0／25／50／75／100%、弹性越界；Page Up／Down、文首／末命令、Find 下一处／上一处、选区 reveal、横向长行。 | T2 断言真实目标可见、映射方向正确、无额外跳位／空白／截断；物理手势和拖拽另做人工路径。 |
| 编辑语义 | 文首／中／末插删、同长替换、跨行替换、删光／从空输入、大粘贴、连续输入、Undo／Redo、手动恢复原字节、Find 替换／Replace All、中文 marked text 更新／确认／取消、选区与 AX 可写／只读。 | T4 同时断言原生正文、FileTab、脏状态、解析树／渲染颜色及最终字节。普通文本、Swift、TSX、Markdown／HTML 嵌入及未知后缀，含扩展名切换。 |
| 加载与容量 | 0、旧阈值两侧、新阈值 N−1／N／N+1；多字节恰跨阈值；缺失、权限拒绝、读取失败、读取中增长／替换路径；有效图、无效图回落、非法 UTF-8。 | T3 本机真实临时文件、受控 FileTab 后端及真实 SSHBackend 命令边界；验证未截断、结果／错误正确，未保存内容不丢。文本上限不误用到图片预览。 |
| 保存／失败／时序 | 无变更、单次、连续保存、失焦触发；写入挂起后新编辑／Undo／手动恢复／再保存；写失败／重试；重命名、同机换连接、断线／超时／重连、旧读晚到／合并焦点刷新。 | T3／T4 复用 generation 与串行保存，不增加第二套 token；校验写入目标和实际数据，旧成功／失败不污染新绑定。 |
| 生命周期／入口 | 从未挂载、已挂载、卸载但标签存活、重挂载；A→B→A、Dock 移动／resize、项目切换、多窗口菜单、聚焦／后台；Git Ignore 追加；文件／项目／窗口关闭及退出保存失败／取消／不保存；解析未完成时关闭。 | T2／T4 复用长期原生对象与撤销，验证有界最终释放；用测试窗口与确认接口，不退出用户 App。 |
| 共享 Diff | review／edit、统一／分栏、普通工作区／暂存／历史只读、空／短／长、固定高度／原生非 LF 段落、折叠展开、EOF ghost、长短侧两轴同步、只读替换不追随光标、字体／主题／重挂载。 | T2 影响 STTextView 时全部检查；T4 影响共享高亮／输入时复验对应部分；Diff 的 5 MiB 不随 FileTab 提升。 |
| 资源与组合 | 冷／热开；1／5 标签；30 次以上热输入和滚动；静置 30 秒及多轮打开关闭，等真实在途解析完成后看稳定值。四档 × 换行 × 三个输入位置完整遍历；容量边界 × 本机／SSHBackend × 初读／刷新；保存挂起 × 编辑／Undo／重命名／换连接；resize × 深滚动 × 换行／行号位数；Diff × 两轴边界。 | T1 前基线、每项实现自己的后测、T5 重跑一致样本。可承受有限组合跑尽；其余先遍历全部单维取值与极值，再系统扩大两两／多因素及已知故障交互，不因完整套件绿而省略可测条件。 |

### 现有测试复用与必须新增的缺口

- [EditorNavigationTests](../../../BaileyTests/NativeUI/Editor/EditorNavigationTests.swift) 已检查双向远距离 reveal 与固定高度，但未检查连续滚动时高度／knob 稳定，也未覆盖真实 Source 的 restore／resize；T2 补原生窗口断言，不止裸 STTextView。
- [FileTabTests](../../../BaileyTests/NativeUI/Editor/FileTabTests.swift) 已覆盖字节判脏、容量、图片回落、读写挂起、连接替换、刷新失败、自动保存与关闭。保留这些语义测试，修改容量期望而非删除超限测试；补新边界和卸载后追加的真实原生结果。
- [SyntaxHighlightingTests](../../../BaileyTests/NativeUI/Editor/SyntaxHighlightingTests.swift)、[TextCoordinateIndexTests](../../../BaileyTests/Unit/Editor/TextCoordinateIndexTests.swift)、[EditorTextInputTests](../../../BaileyTests/NativeUI/Editor/EditorTextInputTests.swift) 已覆盖 chunk／Unicode、随机编辑、旧结果、嵌入语言、IME 与撤销。新增结构时复用直接扫描／fresh parser oracle，扩展到大规模和跨段边界，不复制第二套夹具体系。
- [PaneRetentionTests](../../../BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift) 已验证同一 scroll view、重挂载、旧 editor 回调失效与释放；扩展卸载后操作，并复验 WorkspaceContentIdentity／WorkspaceWindowClose／WorkspaceWindowIsolation 的受影响真实入口。
- [RemoteCommandsTests](../../../BaileyTests/Integration/Remote/RemoteCommandsTests.swift) 已有 `RemoteCommandRunner` 与本机 shell 夹具。T3 在同类中补实际 `SSHWorkspaceBackend.read/write` 的上限、stdin／错误和目标断言；GNU 命令实跑只在具有相同工具语义的隔离环境。带 `ssh:` 标签的 EditorWorkspaceFixture 不算 SSHBackend 或真实传输。
- [DiffTabTests](../../../BaileyTests/NativeUI/Git/DiffTabTests.swift) 已覆盖裸 CR／Unicode 段落、ghost、固定布局、两轴同步；[GitHistoryFileTests](../../../BaileyTests/NativeUI/Git/GitHistoryFileTests.swift) 已覆盖历史只读和原 5 MiB 临界值；T2／共享高亮改动不能只跑 Source 测试。

### 无法执行的条件如何处理

- 当前审查仅做源码／文档核验，没有运行上述产品测试或性能实验。不能据此给实现验收 Go；进入 T1 后逐项核实可用环境。
- 最低系统、CI 指定系统、其它屏幕／刷新率若本机缺少，分别记录具体环境缺口、受影响 API／行为、现有替代证据和待在哪个机器补测；旧系统 TextKit 差异若决定方案，阻塞对应实现验收。
- 真实 SSH POSIX／Windows MSYS2 仅用明确获准的专用主机、临时目录与专用 master。无权限时受控 Runner 只提供命令／字节协议证据，不提供网络／远端权限证据；容量／读写需求的实机验证仍待补，不能列为全部完成。
- 不主动制造系统 OOM、切断用户网络、改系统滚动条偏好或用户字体设置；用有界样本、受控失败和原生视图局部配置代替，并列清替代未证明的资源极限／真实中断行为。
- 独立完整 App E2E／物理触控板与拖滑块录制须有不干扰用户的测试会话；宿主 XCTest 的窗口不算完整 App。没有安全会话时分别记录入口交互与物理呈现的缺口，不能用 clip bounds 移动声称真实手势已验收。
- Instruments 不可用时保留错误，使用可用采样／分配证据，只报告能证明的指标；未测到真实呈现帧率就不报告帧率。必要效果／性能指标缺失时阻塞相应结论，不靠猜测或任意等待放行。

<a id="p1-t1"></a>
## P1-T1 定位文档高度与滚动条跳变的布局反馈

**交付：** 在 `evidence-p1.md` 建立可复现几何与编辑成本基线，决定 T2／T4 的真实修改点。不开永久诊断系统，不把方案假设当复现结果。

1. 从上面的 Git 对象提取原始小文件，另保留当前文件，生成并固定 1k／10k／100k 的真实代码形态样本；记录哈希、字节、行计数口径、字体、窗口／屏幕、换行、语言、配置与冷热状态。超旧容量样本的 FileTab 拒绝单列；直接装入 STTextView 只用于有界组件实验，不能算可打开文件。
2. 在真实 `SourceTextEditor` 桥接与裸 STTextView 对照中，记录 document frame、clip origin／bounds、scroller 存在性／knobProportion／doubleValue、viewportRange、首个实际可见字符的片段 Y 与屏幕偏移。prepared／viewportRange 包含预备绘制区，不当作视口顶部字符；用实际 visibleRect 与 fragment／segment 交集取锚点。按覆盖表连续正反向滚动及定位，区分正常滚动位移与无操作时的附加跳位。
3. 对真正到达的调用点作本地采样：文末 fragment／segment 估算 → frame 写入 → prepare/layout 重入，usageBounds KVO → constraints，didLayout 的到底判断 → relocate，Source 恢复／resize 及 gutter 宽度增长。同步记录事件顺序和收敛轮数。还追文首／末命令与 Find／selection reveal，不能只看 didLayout。若 frame 稳定而仍卡顿，分别测 gutter 前缀 `textElements` 枚举／cell 重建、选区绘制、可视高亮，按各自 owner 归因。
4. 分开测 `STTextView.text`、NSTextContentStorage 快路径／String 桥接、`refreshDirtyState` 实际比较、`SyntaxHighlightCoordinator.didChangeContent`、Parser readHandler、`TextCoordinateIndex.replace` 与原生 layout。比较会在首个不同字节停止，文首／末改动成本不同；同长替换 delta=0 与插删也须区分。采样调用次数不等于分配字节；检查 retained snapshots／排队解析是否主导峰值。
5. 四档 × 换行 × 文首／中／末做插入、删除、同长替换、Undo／Redo 和连续输入，热操作至少 30 次，测主线程中位／p95／最差、分配与进程峰值；测滚动、空闲与 1／5 标签反复打开关闭。关闭后等待本任务可观察的在途工作完成，不能任意 sleep 掩盖泄漏。
6. 修改前固定可比较的资源条件：记录机器可用内存、样本尺寸／峰值、首屏／可输入／高亮时间及用户可观察的停顿；为候选验收明确几何容差（依据像素对齐／实测噪声）、资源上限与退回条件。当前没有统一 MB 或 FPS 标准，不能事后挑指标；不以“任何规模完全常数时间”代替真实性能结果。

**结束条件：** 证据能区分几何反馈、独立滚动热点、编辑／读取成本；T2 只修被证实的机制，T4 每项独立决定是否改。无法复现则记录对照／差异，继续最小定位，不以源码猜测跳入大重构。工具／环境阻塞逐项登记。

<a id="p1-t2"></a>
## P1-T2 稳定文档几何与可见内容滚动锚点

**入口与修改范围：** STTextView 的尺寸写入／视口代理／Scrolling；有证据才改 Gutter 与 Source 的恢复／resize。目标不是强制建立新几何模型。

1. 先在现有原生 XCTest 中建立能失败的回归：真实 Source 与裸 view、固定不变文件的多轮正反向滚动，记录 frame／knob 和实际文字位置；原生目标 reveal、文首／末、Find 前后均检查结果。历史小样本是首要用例，1k／10k 必测，100k 在现有目标用筛选命令独立运行，不建额外 target 或把大文件永久 skip。
2. 先验证最小平台修复／错误反馈消除。若候选用“原生段落数 × 实际行高”确定高度，必须在默认 Source 字体／样式下证明固定行高，并同时验证 TextKit 段落 Y／远处布局／反向命中。不能从 Diff 复制固定样式改变 Source 外观，不用 Tree-sitter LF 数直接当 TextKit 段落数；行高不等时该候选不成立。一次初始化扫描与真实编辑增量更新可以测量，滚动时不再扫全文。
   - T1／T2 实验已经证明删除到底重定位不足、仅固定 frame 也不足。当前候选在 Source 内使用 NSString 原生行边界与实测行高，并将同一内容／选区／行号视图的 bounds 坐标统一转换；TextKit 内部的估算 Y 不冒充文档 Y。`adjustViewport` 没有把现有 fragment 的 Y 直接改成期望值，故已撤掉该失败候选；所有验收使用真实屏幕矩形／反向命中与坐标转换，而不是比较两个不在同一坐标系的数。新辅助只保留在一个几何文件，不引入第二个排版器。
3. 软换行／回退字体／可变高度先用现有 relocate／adjust 能力做最小文本位置＋可视偏移实验；测试静止阅读与用户主动滚动的区别，尺寸修正不能取消用户输入、反向滚动或夺回查找目标。准确全文高度不凭估算承诺；不把活跃 AppKit content manager 交给后台。若只能靠另一套排版器才能满足目标，先交实验限制并修订后续方案，不能自动扩建 WrapMap。
4. frame 的垂直范围与原生内容位置必须一致。修复所有被证实冲突的实际写入点，包括 `relocateViewport(to:)` 对 frame 的更新以及文首／末调用，而不仅是 didLayout；维持水平范围、viewport 最小高度、短文末尾点击、末尾 extra fragment 与稳定 Diff override。现在已有近似相等才 setFrameSize 的判断，不额外包一层同义守卫／新 generation。
5. 若 gutter 是已测热点，在原 owner 更新绝对段落号／复用可见 cell，替换前缀数组和反复销毁路径；覆盖空文档、折行只显示首段号、marker、字体切换后的旧 fragment、行号位数引发宽度变化与软换行回流。不引入常驻整篇正文／第二套 LF 索引。

**同任务删除：**

- 新几何路径证明可接管后，删除其替代的文末反复估高／错误到底重定位分支；若 Source 的 resize 二次布局、clamp／tile 或 live-resize suppression 被根因修复替代，同次删除相应失效状态／回调，不留“兼容旧路径”开关。没有替代证据则保留实际负责收敛、scroller 布局或恢复的部分。
- 清除本任务尺寸路径里的无消费者旧别名：AppKit `widthTracksTextView/heightTracksTextView` 及 [STTextViewProtocol](../../../Vendor/STTextView/Sources/STTextViewCommon/STTextViewProtocol.swift) 仅为这些别名服务的要求，直接保留现用 `isHorizontallyResizable/isVerticallyResizable`。Common 协议不能留下无实现要求；不因此顺手重写未使用的 UIKit／SwiftUI 上游目录。
- 删除 AppKit 未使用的 deprecated `typingLineHeight`（实际 gutter 已用 fragment／CTLine metrics），同步去掉受影响位置误导性的旧说明。执行时复核调用／selector 与本地包编译，若新出现真实消费者，迁移到现用 API，不恢复包装。

**验证与文档：** 几何条件按覆盖表全量核销，特别是首帧／反向、resize／恢复、0／末尾、极长行、非 LF、emoji 与命中。跑 EditorNavigation／EditorTextInput／FileTab／PaneRetention、DiffTab／GitHistoryFile 及受影响工作区测试。文档 owner 为 editor；依赖补丁变化同步 development；Diff 契约真的变更才改 diff，不复制说明。代码通过相关与完整 `make test`、`make build`，Vendor 变更加 Release 与验签；记录几何和资源前后结果。未证明坐标一致或以全文 layout 换稳定的候选不接入。

<a id="p1-t3"></a>
## P1-T3 支持小文件首开与十万行代码完整编辑

**入口：** FileTab 的 `maxTextBytes/readContent/loadedContent`、本机／SSHBackend 边界及真实 Source 首开。只处理测得的首开瓶颈，不另建只读／大文件编辑器。

1. 先 Red：至少一个有真实 Swift 结构、长短行、注释／Unicode 的 100k 样本超过旧 5 MiB，真实 FileTab 应按现状拒绝；记录字节与错误。为拟定有限新阈值的 N−1／N／N+1、UTF-8 跨边界、非文本及图片回落补测试。保留 Diff／GitHistory 原 5 MiB 临界回归。
2. 通过有界原生组件实验先测候选样本的文本、语法树、layout 与排队编辑峰值；确定有依据的容量后再接入 FileTab，从真实读入到编辑、Undo、保存实测。不能以组件绕过容量的成功当用户路径成功，也不能只调常量宣布性能达标；不满足资源条件则按前述依赖推进 T4 后重验。
3. 在现有后端测试边界分别验证：Local 的实际有界读取／原子写；FileTab 受控后端的失败与代次；真实 SSHWorkspaceBackend 组装的 head 上限+1、EOF 恰上限／越界、stdout／stderr／非零／超时、stdin 原字节与正确路径的写入。复用 RemoteCommandRunner 夹具，不造新的 backend 协议。受控 Runner 不算真实 SSH，专用获准主机再验证实际传输、原子替换与权限失败／恢复。
4. 分阶段记录后台读取／UTF-8 解码、主线程安装、首屏、可输入、可视高亮稳定；“颜色完整”指当前可视内容，不强制解析查询全文件着色。首开慢才改对应 owner，保留已有后台解析和查询编译缓存，未知语法纯文本正常显示；不增加预热器或全文 ensureLayout。

**当次清理／验证：** 新阈值直接替换原 FileTab 常量及旧测试期望，不留旧／新双阈值模式；其上限和无效图回落保护仍存在。逐项执行覆盖表的加载／容量／故障／保存交互，实际 100k 文件首屏、中部、文末、返回、输入／撤销、Find 与本机／SSH 最终字节；首开优化影响高亮／生命周期时跑对应现有测试。同步 editor 的真实上限（包括现有两处容量描述），必要的补丁／后端契约再改 development／ssh。相关与完整 test、build／签名通过才完成，不能依赖 T5 补基本可编辑性。

<a id="p1-t4"></a>
## P1-T4 降低编辑热路径的整文成本和内存占用

**根因边界：** 由 T1 证明的热点分别修改。一个 getter 的调用存在，不足以批准正文所有权迁移；同样，现有 helper 不能因为“已经有”就免验最终保存与原生效果。

1. **先走现成增量事件。** `STTextView.replaceCharacters` 已经在事务前后发出带 range／replacement 的 delegate 与 plugin 回调；优先用它减少 Coordinator 的无条件全文回写／判脏。变更前保留旧 range 的 UTF-16 整数值，事务后更新当前状态；TSClient 的 `willChangeContent → coordinates.replace → didChangeContent` 顺序不可倒置。正文全量赋值／干净 reload、原生输入、IME、Undo、Find Replace All、Git Ignore 都要走一致正确的内容更新，不为各调用者复制守卫。
2. **最小正文与快照方案。** 若需要改变 `FileTab.text` 的维护方式，完整列出调用者并同次迁移：初次安装、save／matches／reload、Project 换行判定／append、TabSwitcher 有界摘要、后台解析。长期 FileTab 仍是唯一内容拥有者，已保留的原生文档在卸载时也是真文档，不能以弱 `editorView == nil` 决定另建正文或忽略其修改。先证明现有 String／原生存储方案不能满足目标，再选择最小增量方案；不预写双缓冲状态机、协议、快照缓存或新版本 token。
3. **字节判脏不靠版本／哈希偷换。** 利用已知编辑范围、字节长度与实际差异减少无意义比较；保存基线仍可确定性精确判等，Unicode 规范等价不算相同。测试同长替换、长公共前缀、重复文本、编辑后手动恢复、跨行／空文档、Undo／Redo 与保存中变化，不能只证明某个版本号回到旧值。真正相等的确认和保存允许必要成本；逐次扫描是否已从普通输入热路径消除须实测。
4. **后台解析快照。** TreeSitterClient 要求 readHandler 在 completion 前线程安全且稳定；`Parser.readFunction(for:)` 捕获不可变 String。优先保留这个契约，只去掉测得的重复提取／分配。解析和保存不必强制共用同一快照，更不能捕获活跃 mutable content manager／同步回主线程读文本。若换 read provider，覆盖 UTF-16 字节偏移（不是 code unit）、chunk 跨代理对／CRLF、EOF／空文件、连续排队修改与完成后释放；保留当前内容版本校验及可视颜色失效。
5. **坐标索引只在有收益时替换。** 当前 `TextCoordinateIndex.replace` 的 delta≠0 会平移后续起点；delta=0 仍可能付数组替换成本。先对 1k／10k／100k、文首／中／末、插删／同长／删光测量；确实阻塞目标才在同一个 owner 采用最小分段偏移结构，删原尾循环，不建平行 index。扩展现有 direct-scan／fresh parser oracle 到每个新段边界、分裂／合并、跨段多行替换、随机编辑与无效查询；不在主线程再做全索引重建抵消收益。不必要则记录保留现有简单实现的测量依据。
6. **真实调用者闭环。** 必须先 Red 再 Green：曾挂载文件卸载但标签存活，执行 Git Ignore／append、保存、重挂载并 Undo，核对同一原生对象、未保存状态和磁盘新字节。再测未挂载初读、干净刷新、过期旧 editor 回调、扩展名切换、TabSwitcher 摘要、失焦／窗口／项目／App 保存保护。save 请求当前是在等待前一个任务后进入 `writeCurrentText` 时取得 `written/path/backend/targetGeneration`；不把快照偷移到 UI 发出 save 的时刻以改变排队语义。在途 written 必须不可变，旧结果不得清新编辑或新目标状态。

**同任务清理：**

- 每个实际接入的增量改动同次删除被替代的全文回写／重复判脏、旧 read provider／索引循环和无人消费的状态；不保留 A/B 开关／旧慢路径兜底。没有性能收益的候选撤回，不留长期试验结构。
- 去掉受影响 AppKit 编辑桥接中无消费者的 deprecated `textDidChange(_:)` 转发、`delegate` 和 `textContentStorage` 别名；使用已在用的 `didChangeText/textDelegate/textContentManager`。检查真实调用、selector 和协议边界，不混删原生 NSTextInputClient／NSTextFinder 的必要入口或本地变量名。
- [STTextView+Insert.swift](../../../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Insert.swift) 将五个固定有效换行／Tab／Backtab 常量转换为 Unicode.Scalar 再 guard/assertionFailure 的分支直接改成等价字符串。它们不是外部输入校验；保留原插入、coalescing 和 replacementRange 语义，不搭 helper。相关键盘命令断言实际插入字符和 Undo。
- 不是“旧”就删：coordinator 身份／reloadRevision、targetGeneration、保存串行化、断线只读、失效窗口检查、空 rendering range 崩溃保护与布局重入控制，都有当前消费者／回归；如更简单路径接管其职责，在相应任务证明等价后删除旧实现，不能只删除 if。插件的空 token 早返回也在避免无效转换，不能把共同底层仍需保护误判为全部冗余。

**验证与文档：** 每一逻辑块先读懂→Red→最小改动→Green／测量→清旧路径→复验→原子提交，再进入下一块，不把正文、parser、索引一起盲改。复用 FileTab／SyntaxHighlighting／TextCoordinateIndex／HighlightQueryCache／EditorTextInput／PaneRetention 和受影响 Workspace／Diff 回归；覆盖表的编辑、时序、生命周期与内存维度尽可能跑尽。相关／完整 test、build；Vendor 更改加 Release 与严格验签。同步 editor 的实际数据流和坐标更新契约，依赖修改同步 development／必要 NOTICE；不把未做的快照架构写成已实现。无净收益不接入，但需求未达标也不能因撤回试验就宣布任务完成。

**新实测与推进门禁（2026-10-18，仍为 in_progress）：** `e97494b` 已实现增量事件与卸载状态一致性；Release 100k 文首单次插入约 330／233 ms（无折行／折行），未达 16 ms median／32 ms p95。随后隔离 XCTest 证明：只挂首屏 Debug 文首插入约 10 ms；浏览全文后 358／292 ms；只做远距 `location` 与局部 `ensureLayout` 仍约 10 ms，但 `relocateViewport`／真滚动后 >130 ms。`NSTextContentStorageDelegate.textParagraphWithRange` 在跳到文档 25／50／75／100% 后累计被请求 24,992／49,982／74,974／99,963 次。`invalidateLayout` 无效，且采样定位 `NSTextContentStorage.processEditingForTextStorage → EnumerateCachedElements → updateRangesForTextElement`。`evidence-p1.md` 记录全部日志、不可比系统原生对照与 1 GiB 终止线。

**下一实现边界：**

1. 先在隔离测试中按 Apple 官方 `NSTextElementProvider` 契约验证按需段落提供器（基于 `NSTextContentManager`、稳定 `NSTextLocation` 与 UTF-16 偏移），验证真正跳至 100k 文末、反向、编辑后定位是否仍正确。**首个独立门槛是结尾 LF／CRLF、空尾行 fragment、光标命中和选区**：公共 `NSTextParagraph.paragraphSeparatorRange` 只读，公开 [自定义 manager 实例](https://stackoverflow.com/questions/77569002/new-lines-not-generating-a-textlinefragment-when-using-a-custom-nstextcontentman) 曾出现不能生成末尾空行的严重缺口。必须仅用公开 API 得到等价结果；若需要 KVC 写只读属性或私有 `NSCountableTextRange` 就直接判该原型 No-Go。不得通过限制返回元素个数、禁用正文编辑或固定高度制造假的可见内容。
2. 用对应测试证明仅创建/保留实际需要的段落（测真实对象与请求数，不混淆）、30 次热输入 median／p95、峰值内存，避免在已访问段落上的逐次全量迁移；以先红后绿验证文首中部末尾、相同长度及长度变化、Unicode／CRLF、全文保存字节。
3. 对照 `STTextView.swift`／`STTextView+NSTextInputClient.swift`／`STTextView+LineGeometry.swift` 的 `NSTextContentStorage` 具体强转及附带读取／写入假设，连同 `SourceTextEditor`、`SyntaxHighlightPlugin`、TextFinder、Undo／IME／selection／AX、Diff 共享依赖逐项验证后才能决定是否进入正式运行路径。复用已有原生编辑器和标签所有权；未完成等价性不得保留试验兼容开关或替换正式编辑器。
4. 自定义 manager 原型不能成立就记录明确失败和约束，再以成熟实现为参照评估可替换的代码编辑内核：<https://github.com/CodeEditApp/CodeEditTextView> 已有 macOS 行驱动布局、光标选择、Undo 等功能，但其官方 README 明确没有系统 NSTextView 完整特性（例如部分复杂文字布局），不能把“大文件快”当作与 Bailey 现有 IME／查找／AX 功能等价；<https://github.com/simonbs/Runestone> 更适合作为增量行索引设计参照，主体目标为 iOS，不能直接假定 AppKit 可用。先列现有功能的可复用／缺失边界并对照可运行测试，绝不同时维护两套正式编辑器。不以 8 MiB 限制、禁用高亮或只读偷换 T4/T5。Apple 接口：<https://developer.apple.com/documentation/appkit/nstextelementprovider>；STTextView 上游存储边界：<https://github.com/krzyzanowskim/STTextView/discussions/79>。

<a id="p1-t5"></a>
## P1-T5 验收四档文件的稳定滚动和低资源编辑

1. 使用 T1 固定样本、同机／同配置重跑覆盖清单，包括历史小文件和超过旧上限的真实 FileTab 十万行文件。固定行高场景检查 frame／knob 不反复变、原生文字位置与操作一致；软换行／可变行高检查无附加阅读跳位、无反向映射、末尾可达，不错误要求其首帧精确全文高度。
2. 对比首开各阶段、四档 × 换行 × 三位置的输入中位／p95／最差、getter／比较／坐标更新的真实成本、分配、滚动与空闲 CPU、1／5 标签及多轮关闭后内存。不能只数 getter、只看 RSS 回落或把 display-link tick 报为实际帧率；同时查看对象释放和在途任务收尾。
3. 语义／故障／生命周期／共享 Diff 按表逐项核销。代码已在 T2–T4 各自接入、清理、同步文档；本任务只发现遗漏后回到所属块修正，不作为集中清旧代码的任务。
4. 通过根 Makefile 运行现有 scheme，示例入口：
   - `make test ONLY_TESTING=BaileyTests/EditorNavigationTests DERIVED_DATA=build/DerivedData-editor-rendering`；其它类按同一格式逐类筛选，不把 NativeUI 目录拼入选择器。
   - `make test DERIVED_DATA=build/DerivedData-editor-rendering`；核对完整退出码、发现／执行／失败／跳过数，任何条件跳过逐项解释。
   - `make build DERIVED_DATA=build/DerivedData-editor-rendering`；STTextView／Neon 等依赖变更再跑 `make build:release DERIVED_DATA=build/DerivedData-editor-rendering`。构建入口已含严格验签；ad-hoc 测试还核对 Makefile 的宿主／测试包后置验签，不只截取 XCTest 绿色摘要。
   - 真实 SSH 仅在专用主机获准后按 [testing.md](../../../docs/testing.md#隔离环境) 的参数执行；没有主机不擅自连接。测试设置不改用户配置，DerivedData 不与其它任务共用，不另搭 shell 测试系统。
5. `evidence-p1.md` 保存每项已测／失败／未测、具体阻塞、替代证据、影响与补验方式；完整 App E2E 与人工录屏分别记录。按 development 的整包安装流程记录已构建、验签、安装，未重启如实写明；不启动／重启用户现有 App。

**交付判断：** 用户可观察的滚动、十万行完整编辑、输入与资源目标及全部已识别可安全执行条件均有证据后才完成；关键未知未核销不得无保留 Go。实际阶段实现完成、进入实现审计时才创建 `audit-p1.md`，不以本轮计划修订当作产品验收。
