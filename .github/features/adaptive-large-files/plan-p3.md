# P3：接通 Git Diff 的安全编辑，完成全链验收

**交付：** Files 与可编辑 Git Worktree Diff 的两条写盘入口服从相同的字节／版本规则；
完成真实窗口、Git、SSH、保存失败、性能和释放的产品核验。
**不交付 GB Diff，也不将 P2 的 32 MiB 文本编辑容量自动套给 Diff。**

## 为什么要独立收尾 Diff

当前 `DiffTab` 在 `Bailey/Git/DiffViewerView.swift` 另有
`editableSnapshot/savedNewContent/nativeCodeUnitDelta/reversibleEdit`，
`editedNewContent` 又从 `DiffNativeSurface` 的 `NativeCodeTextView.string` 取全文。
它拥有自己的 `lastSaveTask` 和 `WorkspaceBackend.write(path:data:)`。

因此，即使 Files 保存已经拒绝外部修改，用户从 Changes 进入同一文件仍可能通过 Diff 的旧写入路径覆盖它。
这是**另一条实际存在的入口**，而不是以后才需要的兼容性功能。

Git 读取又分工作树原始字节、暂存 Index、历史 Blob 与经 `.gitattributes`／clean filter 规范化的比较内容。
只改变 Diff 的容量常量会产生错误坐标、误判大量变更或使旧折叠范围访问新文件。
已有 `DiffEngine`、`GitWorktreeComparison`、`DiffNativeSurface` 和 TextKit 折叠机制保留；
仅重新实现错误的数据身份与写入桥接。

<a id="p3-t1"></a>
## P3-T1：让可编辑 Worktree Diff 遵守同一保存与正文原则

**修改：** `Bailey/Git/DiffViewerView.swift`、`DiffNativeSurface.swift`、
必要时 `DiffTextView.swift` 与 P2 共用的 `WorkspaceBackend` 保存契约；
`NativeDiffTabTests`、`GitIgnoreIntegrationTests`、`WindowCloseIntegrationTests`。

- Worktree 真实文本由其 retained `NativeCodeTextView` 唯一编辑；
  `DiffTab` 保存基线为不可变原文版本，Git 比较和 Unified/Split 只是派生展示。
  脏状态按实际原字节和 Undo 结果判定，不在每次事件里比较整篇
  `editedNewContent`／`savedNewContent` 或维护另一份可写镜像。
  若 FileTab 与 Diff 的增量脏状态过滤完全同构，可复用 P2 的**小型纯值逻辑**；
  不复制第二套全文状态机，也不借此新增全局 Document/Save Manager。
- 把 `DiffTab.save`／`writeCurrentText` 接到 P2-T3 的同一**要求原始版本的写入**，
  将编辑快照编码与工作区文件原始身份一起交给后端；
  不得从 `WorkspaceBackend.write(data:)` 悄悄回退。
  Diff 与 FileTab 在不同窗各自编辑同一路径时，第一个保存成功后
  第二个必须报告冲突并保留草稿；明确手动处理后才可保存。
- 保存期间新输入继续保持 dirty；切换 Git 来源、仓库、机器、连接、路径，
  或执行 Git reset/restore、移动／删除文件时，旧结果不能更新新标签或重建已删除文件。
  保留窗口关闭/取消关闭和受控保存失败的真实副作用验证。
- 接受新的 Git 快照时先失效旧折叠、行装饰及旧文档坐标，
  而**未换 Git 基线**时保留左侧 Split、右侧原生 Undo 与用户手动展开状态。
  旧分支 `c45d8e65` 的“排版中的刷新不丢失”与 `37badb70` 的越界问题
  对应独立回归，不能用无条件重建视图修闪烁或崩溃。
- 在替换完成的同一任务删除 `DiffTab` 被替代的保存任务链、
  字符频数／反向全量比较和旧无条件写入；
  不重新引入 `Review/Edit` 两套编辑器，也不合并两个标签的窗口身份。

**Red→Green：** 本机真实 Git 仓库，两个不同窗口的 FileTab/Worktree Diff
同时对一份物理文件编辑；外部同大小同 mtime 改写、同名不同路径、
保存中 Git 重新载入、断线后原编辑可见、保存失败关闭否决。
确认原目标真实字节、两份草稿状态、Git index/HEAD 未被意外修改、
旧折叠不越界、原生焦点与选区正确。此处不是仅测 `DiffTab.save` 返回成功。

<a id="p3-t2"></a>
## P3-T2：以真实 Git 语义验证 Diff 精度和容量

**修改：** `DiffTab.gitContent/readWorktreeFile/gitComparisonBaseline`、
`GitWorktreeComparison.resolve`、`DiffEngine.computeIfActive`、
`DiffNativeSurface.render` 的**已证实有问题的路径**；无问题的算法保留。

**2026-11-14 实测基线：** 当前 `NativeDiffTabTests.testLocalGitStagedAndUnstagedDiffReadyLatencyMatrix`
在 24,000 行、30 次新建 Surface 的真实 Git fixture 中，
首帧像素就绪 p95 **Staged ≈ 421 ms、Worktree ≈ 716 ms**；
100,000 行分别约 **1.80 s、2.21 s**。
Worktree 的一次新建渲染／布局约为 24k 行 **43／42 ms**，
100k 行 **175／165 ms**，Staged 相同阶段约 **1.5／3 ms**。
这些是**新建视图从数据到像素**的成本，包含 Git 模型阶段，
不应拿它冒充热滚动 p95；优先定位 Worktree 专属的原生折叠和布局链。
另一个输入测试中 100k 行尾部输入 p95 约 16 ms，
而最高约 164 ms 的全文字节比较属于**测试断言本身**，不是应用每键耗时；
必须在真实回调中独立量测，不能把测试夹具成本误归因给生产代码。
证据：`.build/plan-review/crh-full-baseline-20261114.log`。

1. 对 staged、unstaged、首次创建／删除／重命名、历史提交、两个指定 revision、
   revision↔worktree 和原始历史文件分别构建真实 Git fixture。
   本机与可用的隔离 SSH 后端使用相同 Git 输出作为对照，不混用 HEAD、Index 与工作树代次。
2. 以 `.gitattributes` 的 `text`／`-text`／`eol`、`core.autocrlf=true`、
   LF／CRLF、BOM、clean/smudge filter（含非一一对应的内容）和编码变化核对
   **Git 等价性与原始工作树字节分离**。
   Git 报无修改不得显示整篇增删；过滤器改变行数时不能用规范化行号定位原始可写文本。
3. 复测 `3d62c14b` 的大段重复行少量编辑、结构化增删、末尾无换行、
   Unicode／CRLF、二进制／非法编码、取消及极密集差异。
   核对变化行、实际 hunk、编辑后保存的工作树字节与 Git OID，
   不用只比较色块数量或“算法返回完成”。
4. 逐档测 **5 MiB 当前限制**、8／16／32 MiB 每侧、1k／24k／100k 行，
   对比实际读取、差异计算、原生首帧、折叠后滚动、两栏同步及 RSS。
   大于当前上限先在隔离算法／Git fixture 中量测，
   未取得完整产品结果之前仍保留现行 5 MiB 用户门限。
5. 仅当对应 **Diff 数据源、准确性、真实视觉/交互和资源**均符合
   `docs/testing.md` 及当前阶段预算时提升该路径容量；
   失败保持现行上限并解释原因，不能因 32 MiB 文件编辑已支持就把 Diff 一起放开。
   不新增 GB 外存 spool、全量 Git worker mirror、第二个对比引擎。

**验收：** `DiffEngineTests`、`NativeDiffTabTests`、`NativeGitHistoryFileTests`、
`GitUncommittedActionTests`、`GitExecutionTests`、`GitWorkspaceSSHTests`、
`DiffFoldLiveMutationTests` 的适用部分通过；
编辑态像素、折叠占位、最后一行、远跳、横向滚动、两侧对齐与真正保存结果一致。
**单个 Diff 测试绿不等于 32 MiB Diff 产品容量已经放行。**

<a id="p3-t3"></a>
## P3-T3：跨窗口与实际 App 验收、删除残留并交付

**覆盖入口：** `PaneTab.save`、`Project` 的移动／删除与
`FileTab.beginFileMutation`／`DiffTab.beginFileMutation`、
`WorkspaceWindowModel` 的全窗保存与退出、`SourceTextEditor`／`DiffNativeSurface` 的
挂载／关闭、Files 与 Git 的菜单命令，以及实际 `Bailey Dev`。

1. **先核对完整调用链。** 从 Finder 打开文件、Files 树、快捷键保存、
   `.gitignore` 追加、Git Worktree 编辑、跨窗口文件移动／删除到实际磁盘写入，
   查找可达的旧双轨、无条件写入 fallback、反向全文读取、重复缓存和过期测试。
   每条旧链在其新替代已经验证时删除；仍属于 Git／文件系统其它真实消费者的能力保留。
   重点重放 `WindowCloseIntegrationTests` 的竞争：关闭同时批量保存期间，
   原先干净的其它标签又发生新编辑；不得只因较早的保存任务完成就退出窗口或抹掉该草稿。
   远端重绑、Git checkout／restore、文件改名与两份独立草稿也须按真实目标重新核对。
2. 用最小原生宿主测试证明后台 actor、真实 AppKit 文本、完整 IO、
   编码、原生 Find／IME、Diff 像素、行号、长行、滚动和闭窗安全。
   用 `make build:ui` 编译 UI Target；
   在**真正独立的图形会话**中才运行 `EditorNavigationUITests`、
   `EditorHighlightingUITests`、`WorkspaceFilesUITests`、
   `WorkspaceGitUITests`、`WorkspaceWindowsUITests` 等**不能由宿主代替的**用户操作。
   本机没有独立 GUI 会话时，优先复用**现有 GitHub Actions 的隔离 UI Runner**；
   推送测试分支和触发 CI 需要另行授权，且 Runner 版本差异须单独记录。
   不争夺当前桌面，不新建 macOS 虚拟机，也不能用 GUI 全跳过冒充验收。
3. 本地对同一批真实 0／8／16／32 MiB 文件进行从创建到保存、
   退出／重启 Bailey Dev、重新打开、对照独立字节摘要的闭环；
   64 MiB／Diff 较大容量逐档按 P2/P3 的各自 Go／No-Go 决定。
4. 完成 `make build`、完整 `make test`、`make build:ui`、
   `make build:release SIGNING=adhoc` 和严格签名核验；
   按当前 Git 与 Swift 代码检查保留真正的设备／连接／失败环境覆盖，
   不修改正式运行的 Bailey，不推送 main 或擅自发布。
5. 更新**真实已实现**的 [`editor.md`](../../../docs/features/editor.md)、
   [`diff.md`](../../../docs/features/diff.md)、[`ssh.md`](../../../docs/features/ssh.md)，
   涉及文件操作时同步 [`files.md`](../../../docs/features/files.md)。
   更新容量、失败文案及外部冲突操作；历史 GB 研究仍标为停用，不混入产品使用说明。

**工程验收：** 同行为下复核新增／删除行数与复杂度，
没有长期同时存活的旧正文、保留的多重保存调度器或过度抽象；
新机制减少了可写状态和到磁盘的路径，而不只是从一个文件迁到另一文件。

<a id="full-acceptance"></a>
## 最终验收全集：可执行条件一个也不能漏

下面按受影响**最终结果**组织测试，而不是将所有组合再做一套样板框架。
凡当前环境能安全执行的适用边界、极值与关键交互都要覆盖；
完整矩阵的具体参数可写入本次测试数据与结果，不在每个任务重复抄写。

| 结果 | 必须实际覆盖的条件 | 真实判据 |
| --- | --- | --- |
| 打开和拒绝 | 0／1 字节，5／8 MiB 两侧，16／32／64 MiB，超限，缺失／权限，目录／FIFO／设备，NUL，路径中引号和 Unicode | 正确文本或具体错误；不等待设备 EOF、不截断、不保留错误可写状态 |
| 图片与内容类型 | 真图片、伪 `.png` 的文本／二进制、声明格式伪造、文件增长与超大图片 | 图片预览有独立上限；不以 `.max` 读任意文件；按实际内容准确回退 |
| 编码与字节 | UTF-8／BOM／UTF-16 BOM、GBK／GB18030、Shift-JIS、CP1252、Latin1、Python `coding:`、Windows `mbcs`、非法尾部、规范等价 Unicode、CRLF | 保存与重开逐字节一致；不支持字符拒写并保留草稿，编码变化有明确用户意图 |
| 原生输入 | 普通／完整显示长行、混合 Unicode、中文 IME 标记与取消、多选区远距、Undo/Redo、查找替换、AX 读写权限；超长单一组合字符须在隔离进程测 | 选择、字形、行号、鼠标命中与真实字节一致；普通输入 ≤16ms p95、十万行 ≤32ms p95；极端平台布局无法承受时安全拒绝且不丢稿 |
| 滚动与绘制 | 明暗、窄宽、主题/字号、折行、十万行远跳、SVG 超长行，Git 删除行、Split 两栏与首帧折叠 | 真实 TextKit 像素、行号和完整滚动范围，首尾皆可见，没有空行叠字／折叠越界 |
| 草稿与保存 | 自动／手动／显式新编码、空文件、写中输入、重叠保存、短 IO、磁盘满、权限、取消、同大小同 mtime 外部写入 | 真正文件字节完整；失败不覆盖、草稿仍可恢复；不能无条件 fallback |
| 文件操作与窗口 | A→B→A、五标签、两个同名不同路径、同一文件 FileTab 与 Diff 两份草稿、重命名／删除／窗口关闭／退出同时保存 | 正确机器/路径，过期写入拒绝、未保存保护、原生 Undo 不丢；关闭后缓存与进程实际释放 |
| Git 语义 | Staged／Worktree／History／Revision、重命名、重复行稀疏变化、clean/filter、`core.autocrlf`、`eol`、末尾无换行、二进制 | 对照 Git 真实索引/OID/patch，raw 原文不变，不把小改动误画成整篇增删 |
| SSH 与命令信任 | 隔离 Mac shell、Windows MSYS2 受控命令、已授权真实 SSH 的断连／重连、恶意 env 名称、符号链接／权限、接收端截断 | 意外命令没有副作用；上传完整后发布；错误时远端旧版、权限、暂存与本机草稿均正确 |
| 性能和资源 | 冷/热、Debug/Release、语法颜色有无、32/64 MiB、10 万行、多窗口／五标签、关闭重开 | ≥30 热样本的 median/p95/max，主线程连续占用、RSS/heap 峰值与回落，版本身份无泄漏 |

- **宿主：** 根据 `docs/testing.md` 的受影响类别运行，
  尤其 `FileTabPersistenceTests`、`NativeFileTabTests`、`NativeEditorLayoutTests`、
  `NativeEditorCompositionTests`、`NativeSyntaxHighlightingTests`、
  `NativePaneRetentionIntegrationTests`、`WindowCloseIntegrationTests`、
  `RemoteCommandsTests`、`RemoteLifetimeTests`、`NativeDiffTabTests`、`DiffEngineTests`。
  先 Red→Green，最后全量并核对完整 `make test` 的退出状态和 skipped 项。
- **GUI：** 只执行宿主无法证明的真实系统菜单、⌘S、Finder、前台键盘、
  选中窗口与跨窗口路由；必须在独立的 Dev 图形会话执行。
- **环境缺口：** macOS 旧版／不可用的 Runner、真实 SSH 授权、GUI 独立 console、
  断网或强杀等条件逐项写出不能执行的原因、替代证据、潜在影响、后续验证方式及是否阻塞当前容量放行。
  不能通过 `XCTSkip` 或只编译 UI 测试消除未知。

## 对外完成的判断

若 Files 32 MiB 的真实完整编辑、保存、资源及既有 UI 语义未通过，
**该容量就不能放行**；64 MiB 和 Diff 独立不放行不妨碍已通过的普通 Files 功能。

源码研究、原生组件实验、构建签名、宿主 XCTest、真实 SSH 与 GUI E2E
是不同层次。必须分别注明已完成、失败、跳过和未执行，
不能用备份的 1 GiB 原型、历史 CI 绿灯或一次 Git 操作成功替代正式产品验收。
