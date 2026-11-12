# P3：GB Diff、原生投影与整体验收

**Goal：** 取消 Diff 的 5 MiB硬拒绝，GB两侧可比较、浏览和编辑工作区原文，
保持真实 Git语义、原生输入及完整保存，并完成本 feature的最终验收。

**Non-goals：** 不新增 Git操作、移动代码识别或新 diff偏好；
不替换原生编辑器，不将未完成计算冒充完整差异。

**Approach：** 复用 P2文档与稳定 IO，把输入、差异索引、视口投影和可写原文分清。
沿原有 DiffTab／DiffCore／DiffNativeSurface链原位迁移，
不叠一个“大文件 Diff Manager”或永久第二套 engine。
先迁移来源和计算，再替换全文展示／编辑镜像，最后开放 GB并验收。

**Acceptance：** R6及与之共享的 R1～R5均有证据；两侧 GB小修改精确可见，
完整覆盖、字节重建和原生保存成立。预算到期／失败／取消明确可见并可恢复，
所有来源／统一分栏／过滤器及已识别组合按总集核销。

**Rules／准入：**
- P1-T3通过且 P1-T4已固定算法、接口和数值；P2的共享文档／IO具备所需能力。
  下面同样是条件任务，不提前宣称 out-of-core算法或 AppKit投影可行。
- DiffTab继续拥有该标签的来源、任务和原生表面；可写正文只有一份。
  不能通过全局路径缓存把 FileTab／DiffTab的独立草稿强行合并。
- immutable旧侧、Git规范化比较内容和原始可写工作区必须分别保留身份与坐标。
- 保留现有 DiffGhostGeometry的视口二分定位及原生 ghost机制，
  不把已解决的每帧前缀扫描当成尚未完成的新工作。
- **当前工作区 Diff 已经没有浏览→编辑器交接。** `DiffNativeSurface.render` 自首次展示复用一个
  `editPane` 可写 TextKit 文档，并用 `DiffTextView.setEditingFolds` 在真实正文中折叠；
  `unifiedPane` 和左右只读投影是其它来源／模式的派生展示，不是第二份可写正文。
  本 feature 保留该路径、ghost、Split 同步、Undo 和当前折叠／快照失效不变量，
  不恢复已删除的 `showsFoldedWorktree`／`activateEditor`／`beginEditing` 或 Review/Edit 双模式。
- 每 task同改实际契约的文档并删除被替代路径；不将基本字节正确性留到最终测试。
  覆盖总集与逐任务核销见 `plan-p1.md#覆盖执行契约`、`plan-p1.md#验证条件总集`；
  每个 task 按分派表完成本块断言，不等最终 task 补基本正确性。

<a id="p3-t1"></a>
## P3-T1 用稳定分段来源替代 Diff 的全文读取依赖

**依赖／范围：** P2共享文档／IO；本 task保留旧 Diff打开容量，
先在现有数据规模内证明来源迁移没有改变 Git结果。

**Files／锚点：**
`Bailey/Git/DiffViewerView.swift` 的
`DiffTab.reload/gitContent/gitObject/firstGitContent/requiredGitContent`、
`readWorktreeFile/gitComparisonBaseline`；
`GitCommandExecution.runData`、`GitWorktreeComparison.resolve`；
P2 的 `WorkspaceFileSession` 及必要远端流式命令边界。
当前 `gitComparisonBaseline` 的 `hash-object --path --stdin` 会一次传入完整 worktree `Data`，
`git diff` 会把 `maxBytes * 4` 输出装入 `Data`；两条**独立于 blob** 的路径必须一起迁移。
测试扩展 `NativeGitHistoryFileTests`、`NativeDiffTabTests`、
`GitExecutionTests` 和 `GitWorkspaceSSHTests`。
不改 Git目录／图谱等无关命令的全局输出策略。

**Red：**
真实临时 index／tree、明确 OID 和路径下覆盖普通 blob、短读、
无效 revision、删除空侧、初次提交、冲突 stage、模式-only、符号链接、
SHA-1／SHA-256、重命名与含 Unicode／换行的特殊路径；
对旧／新读取间改动 ref／index，验证仍读锁定版本。
显式制造 `working-tree-encoding`／clean filter／CRLF 与工作区所选编码不同的 Git patch，
独立保留 Git 原始输出、标准 Git 结果与原始工作区字节，
不能仅以当前 `newEncoding.decoded(patch.stdout)` 解析结果充当 oracle。

**实现、接入与删除：**
1. metadata解析和 OID选择沿用现有入口，blob大小／流式内容核对同一 OID，
   用 P2稳定源保存原字节，不转完整 stdout Data或 UTF-8 String。
2. 工作区读取进入同一分段源，读取错误不变空侧；
   只有 Git明确的缺失／删除状态可表示空文档。
3. clean／hash／patch 链按 P1 确定的流边界执行。
   区分 Git patch 的实际输出编码、工作区磁盘编码和展示用 UTF-16，
   不得无依据地用工作区所选编码解析整段 patch；
   `hash-object` 输入、原始工作区源、clean 输出、patch 输出及比较内容各自有背压、OID 和版本；
   同一输入快照可供 `hash-object` 与 patch 比对，不把动态 worktree 的两次读取混成一份内容。
   不能只移除 `maxBytes * 4` 检查却仍全攒 patch，
   也不能继续使用 `worktreeBytes: Data?` 作为 GB 比较的必要前置。
4. Git 判断相同、原始文件不同（如 EOL／filter）时仍保存原文；
   过滤器改行数时保留规范比较与原始编辑的明确映射，
   Git LF 逻辑行、UTF-16 源偏移和物理编码字节偏移不得混用。
   编码按现有 `TextFileEncoding` 选择，不假设所有 Git blob 与工作区均为 UTF-8。
5. 删除 Diff输入链完整 Data／String读取依赖。
   在旧 5 MiB边界内仅为尚未迁移的渲染提供有界只读派生投影，
   它不是第二份可写正文，T2／T3原位移除；不提前开放 GB暴露旧渲染。
6. 失败保留已加载的有效来源和原生内容；旧读取按既有 generation失效。

**验证：**
`make test:NativeGitHistoryFileTests,NativeDiffTabTests,GitExecutionTests`；
远端再按授权执行 `make test:GitWorkspaceSSHTests`。
覆盖 D4～D6、I2／I3／I5、G1／G3／G5、R。
实际 Git OID、patch、工作区字节和旧显示共同断言，不只检查命令参数。
复用 `NativeDiffTabTests` 现有 clean filter／快照变更／Windows CP936 用例、
`NativeGitHistoryFileTests.testSHA256RepositoryResolvesImmutableBlobsForHistoryIndexAndWorktree`
及初次提交／特殊路径测试、`GitExecutionTests` 的背压／取消；
仅对**这些既有断言未证明的** GB 流式、不同编码 patch、`working-tree-encoding` 与 OID 组合增测，
不另建第二套 Git parser。

**文档／提交：**
同 task更新 `docs/features/diff.md` 的来源／快照／失败及 Git规范化关系；
远端传输能力变更由 `docs/features/ssh.md` 负责，Git入口只导航，不复制机制。
有界旧容量尚在就如实保留其说明。验证后原子提交。

<a id="p3-t2"></a>
## P3-T2 让差异计算和视口投影有界，删除三篇全文派生文档

**依赖：** T1及 P1算法／原生投影 Gate；仍不提前让尚未迁移的工作区编辑开放 GB。

**Files／锚点：**
`DiffEngine.swift` 的 `GitWorktreeComparison.resolve`、
`DiffSourceLine/DiffCore/DiffComputation/DiffSideDocument`、
`DiffTab.recomputeDisplay/publishDisplay/refreshEditDecorations/expandRun`、
`DiffSyntaxHighlighter`，
`DiffTextView.swift` 的 `DiffDecorations/DiffRowGeometry/DiffGhostGeometry/DiffCodePaneView`，
`DiffNativeSurface.render/apply/restoreAnchor`。
必要分段 hunk／行索引留在现有领域 owner内，不为每个结构新建模块。
测试扩展 `DiffEngineTests`、`NativeDiffTabTests`及 P1可复用的精度／预算回归。

**Red：**
两侧 GB 基底的单点改动、重复行小变更、多 hunk／整篇替换，
验证定位与字节重建；相同字节量的百万短行与极长单行分别测极端索引／渲染成本；
首中末／折叠／展开／模式切换不生成三份全文字符串。
额外复现新 Git 快照从长文缩为短文／空文（含 Split），
折叠行号／ghost／UTF-16 索引必须同步改代次，不得重现 `37badb70` 的行索引越界或造成左栏闪烁。
计算取消及超预算必须真实停止或报告未完成，不能先完成后仅丢结果。

**实现、接入与删除：**
1. 按 P1 实证的单一路线适配分页行／hunk 数据：
   `GitWorktreeComparison.resolve` 当前同时创建 `oldLines/rawLines`、`projected`、`canonical` 和
   `canonicalNew` 等**全文副本**，必须与 `DiffCore` 的全文 `Substring` 行数组一起迁移；
   不得只替换 Diff 引擎，留下 Git clean 投影的全文重建。
   若选择 Git 计算入口，原位替代对应大计算职责，不新增重复 engine 和永久双轨。
2. 行／hunk索引、哈希、删除行、词级细化分别受固定预算控制；
   相同前后缀和重复小改动保持精度，不能仅因字节多就整篇替换。
   哈希碰撞通过原字节复验，不把哈希相等当字节相同。
3. 计算状态明确区分完成、未完成、失败和取消；
   从实际生产循环／进程传递取消和检查目标版本。
   可继续／重试时保留稳定输入，过期结果不能发布。
4. 将**历史／暂存／比较基线**的 Unified／Split 变为同一差异索引上的不可变视口投影；
   删除 `DiffComputation` 目前预建的 `unified/splitLeft/splitRight` 全文派生内容及
   `DiffSideDocument.text` 全文拼接，保留按需原生投影与两侧滚动联动。
   工作区可写 `editPane` 不转成只读视口副本；投影与真实正文坐标分别映射，
   不能用屏幕局部 offset 保存原文。
5. 只生成所需 hunk／行的样式和 ghost，复用既有折叠／滚动／二分 ghost 定位。
   主题、字体、展开、重挂载只改派生显示，不重算全文或重建可写文档。
   `DiffEditFold.sourceFolds`、`DiffCodePaneView.setEditBufferText` 和
   `DiffTextView.setEditingFolds/rebuildFoldedUTF16Ranges` 必须消费**同一代**正文／行索引／装饰；
   先退役旧坐标再安装新快照，Git 基线未变时不能无故销毁 Split 左栏。
   投影行到原文位置的映射须使用当前文档版本，不把缩短投影 offset 当作真实文件 offset。
6. 离线高亮继续共用语法资源及预算；现行 `DiffSyntaxHighlighter.captures`
   在判断 5 MiB 缓存门槛**之前**已 `parser.parse(text)` 全文，必须使真正的解析输入有界，
   不能把巨型 hunk 当成可无界解析的小块。
   旧全文投影适配在本 task 删除，必要错误／进度使用现有界面边界和本地化。

**验证：**
`make test:DiffEngineTests,NativeDiffTabTests,NativeGitHistoryFileTests,NativeEditorLayoutTests`。
复用已有十万行、折叠失效、ghost、clean filter 和特殊 Unicode 的回归，
另补真正 GB 两侧与固定资源预算、未完成状态的独立证据，不重复旧小文件 GUI 矩阵。
总集 D、I1／I4／I5、N4／N5、G2～G5、L。
完整重建、准确 hunk、实际像素和驻留共同证明；
单独算法耗时或纯富文本构造耗时不能当完整首屏指标。

**文档／提交：**
同 task更新 `docs/features/diff.md` 的算法预算、完成度、投影和高亮；
验证入口／完成度要求变化同步 `docs/testing.md`，
错误／进度字符串在 `Bailey/Resources/Localization/Git.xcstrings`。
UI若出现真实新语义才更新 ui文档，不改整体样式。验证后原子提交。

<a id="p3-t3"></a>
## P3-T3 工作区 Diff 编辑复用同一 GB 文档，解除全部来源 5 MiB门槛

**依赖：** T1／T2及 P2原生完整编辑，所有需要的正确性测试在本 task内成立。

**Files／锚点：**
`DiffTab.editedNewContent/savedNewContent/editableSnapshot/nativeTextDidChange/writeCurrentText`、
`refreshEditDecorations/reload/refreshWhenSelected`，
`DiffNativeSurface.editTextDidChange/render`，
`DiffCodePaneView.setEditBufferText/setReviewDocument`、
`Bailey/UI/Panes/TabSwitcherView.swift` 的 `diffPreview/textExcerpt`；
P2 的原生文档适配／稳定保存。
当前 `DiffNativeSurface.editedText` 返回 `textView.string` 全文，
`DiffTab.nativeTextDidChange/resynchronizeNativeDelta/refreshEditDecorations` 又获取它；
Dock 缩略预览也先消费全文，必须一起切换到有界范围接口。
测试扩展 `NativeDiffTabTests`、`NativeGitHistoryFileTests`、
`WindowOwnershipIntegrationTests`和必要的现有保存保护用例。

**Red：**
工作区 GB直接编辑、IME、Undo／Redo、删除 ghost、统一／分栏切换、
保存期间新编辑、断线、过滤器改行数；
历史／暂存通过键盘和 AX均不能写。
实际打开入口中 5 MiB+1先出现拒绝 Red，而非直接绕过入口调新引擎。

**实现、接入与删除：**
1. 工作区侧接 P2 同一文档契约和原生事务；
   直接删除 `editedNewContent`／`savedNewContent`／`editableSnapshot` 等全文镜像消费，
   同步迁移 `DiffNativeSurface.editedText`、脏状态核对、Dock 缩略预览和 `writeCurrentText`；
   **不**保留从 `textView.string` 完整复制再截取摘要／逐项编码的兼容入口。
   基线和当前版本是文档快照，不再各持一个完整 String。
2. 装饰读取当前文档版本并增量失效／后台更新，
   取消旧 editTask的生产，避免连续输入堆积全文比较。
   精细化滞后不能改写原文或误标保存状态。
3. 保存沿 P2完整快照迭代和既有队列／目标代次，
   clean后重读只更新干净基线，未保存草稿和在途输入不被覆盖。
4. 历史原文、历史 Diff 和暂存继续只读；
   现有单一原生 `editPane` 在 Unified／Split、焦点、重挂载、失焦保存间保持同一文档及 Undo；
   clean 规范化比较与原始可写正文仍分别正确。
   直接复用现在的 `setEditingFolds`、删除行 ghost、正文邻接定位和快照撤销机制，
   不增加已经不存在的 Review/Edit 交接，也不沿用 `snapshotOffsets` 全文数组让 GB 文档常驻。
5. 全链字节、原生与资源验证成立后，删除所有文本来源旧 maxBytes拒绝和
   依赖它的 patch／blob固定倍数上限，改为已实证的独立资源预算。
   并非删除所有安全限额：metadata、非法输出、其它业务读取限制按其原职责保留。
6. 更新旧“超限应拒绝”的测试为合法文本成功、真实资源错误准确失败，
   覆盖 UTF-8／UTF-16 BOM／GBK／GB18030、手动重开与无损另存、
   `.gitattributes working-tree-encoding` 与 filter 规范化；
   二进制、非法编码、权限、短读、OID错误继续有原有保护，不放宽为任意文本。
   删除 T1的剩余旧渲染适配，核查所有可达历史／工作区入口，不只改一种来源。

**验证：**
`make test:NativeDiffTabTests,NativeGitHistoryFileTests,DiffEngineTests,FileTabPersistenceTests,WindowOwnershipIntegrationTests`。
总集 G全项及 D、I、N、S、R的关联条件。
本机和授权 SSH分别核对 Git结果、原始字节、完整重开、Undo和失败草稿。
真实远端 cleanup复用当前严格 mktemp全路径验证，
不能只按目录前缀信任命令返回值或清理未知路径。

**文档／提交：**
同 task移除 `docs/features/diff.md` 的旧 5 MiB契约并替换为实证策略；
`docs/features/editor.md` 的 Diff独立旧边界同步改为导航，
共享保存／断线规则不复制；验证后原子提交。

<a id="p3-t4"></a>
## P3-T4 完整验收、证据核销与本地交付

**依赖：** P2／P3全部实际实现已各自验证，不用这个 task为前面未读透的部分兜底。

**Files／锚点：**
扩展 `BaileyUITests/Git/{WorkspaceGitUITests,GitHistoryUITests}.swift`、
`BaileyUITests/Editor/EditorNavigationUITests.swift`和现有测试支持。
参考当前真实用例
`testWorktreeDiffEditsAndPersistsRealGitFile`、
`testGitCleanFilteredReviewAndRawEditRemainDistinct`、
`testBinaryAndOversizeHistoricalRevisionsShowNativeReadRestrictions`；
最后一项要改为二进制拒绝、合法大历史可打开，
同时补长→短／空快照切换时折叠、ghost 和 Split 左栏不旧坐标越界的真实原生回归；
不保留与新需求矛盾的断言。

**验收步骤：**
1. 按 P1总集逐项核销 E／D／I／N／S／R／G／L，
   所有安全可测单项和有限组合执行；新发现失效条件追加回归。
   按覆盖执行契约展开实际参数值和最终断言，对账预期／执行／失败／
   skip／前提无效／未执行数量；每个缺口单独判断，不能以方法总数或套件绿代替。
2. 宿主覆盖真实文件／Git／SSH、范围、异常、IME、像素、原生生命周期。
   完整 GUI只补真正的用户入口：
   打开 GB文件并保存重开；
   Git Changes的 GB工作区编辑／Undo／⌘S；
   Git Graph大历史只读；
   clean filter的规范化差异与原文编辑；
   两窗前台命令及必要远端用户路径。
   不重复整套 GUI矩阵，不索取 GB AX全文校验。
3. 专属 Dev、独占焦点和明确远端授权逐项确认；
   GB空间预检，流式生成／校验，cleanup仅本次可信临时资源。
   当前正式 Bailey及用户 SSH不被测试启动／关闭／替换。
4. Release分别测冷首屏、热输入／跳转、遍历／搜索、保存、Diff和关闭重开循环；
   记录内部预算和外部进程／子进程物理足迹、CPU、磁盘。
   普通文件与 GB、多短行与超长行、多标签与失败恢复都不能遗漏。
5. 运行下列实际适用入口并检查完整退出、测试发现与签名后置检查。
   出错诊断／修复本功能根因再重验，不放宽阈值、删用例或吞错误。
6. 更新用户 README中真实已实现的能力和必要限制；
   全部实证契约在原 owner内同步，docs索引仅在导航变化时调整。
   最终证据留本 feature，不把实验日志搬进长期文档。
7. 若关键前提缺失，逐项报告具体限制、潜在影响、替代证据和补验，
   不以“完整套件绿”代替全部适用条件，不给无保留 Go。
8. 正式代码通过要求的验收后，才按 development的本地安装流程：
   同盘暂存整包、验签、原子替换、复验，失败恢复原包；
   不退出／启动／重启正在使用的正式 App，不 push或创建分支。
   这是将来获得实施授权后的收尾，本轮只制定计划，绝不安装。

**命令：**
- 定点：`make test:DiffEngineTests,NativeDiffTabTests,NativeGitHistoryFileTests,FileTabPersistenceTests,NativeFileTabTests,NativeEditorLayoutTests,NativeEditorCompositionTests,NativeSyntaxHighlightingTests,NativePaneRetentionIntegrationTests`。
- 全宿主：`make test`。
- 隔离优化 App：`make build:dev CONFIGURATION=Release`；不能拿 Debug包测 Release指标。
- GitHub Actions：在有本 feature 代码提交且明确授权触发时，
  用现有 `Bailey XCTest (host and UI)` 的 `xcode-27` Host／UI 作另一运行环境，
  记录 Runner 实际 OS、Xcode 27.2、签名与 `.xcresult` 结果；
  不改工作流、不自行 push／创建 `ci-ui-*` 标签来代替本机验证。
- GUI 分开：`make test:ui ONLY_TESTING=BaileyUITests/EditorNavigationUITests`，
  `make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests`，
  `make test:ui ONLY_TESTING=BaileyUITests/GitHistoryUITests`。
- 正式构建／签名：`make build`、`make build:release`，
  同时检查实际产物 arm64、Bundle ID和签名；不把 Dev测试构建当正式包已验签。
- 计划机械校验：共享 `feature_tool.py todo validate`；
  文档链接／锚点、`git diff --check`及原子提交前的实际 diff核对。

**文档／提交：**
`README.md`、`README.en.md`仅说明已实现且已验证范围及必要反馈；
`docs/features/{editor,diff,ssh}.md`各归其责，
`docs/testing.md`记录可重复入口而非一次性数字，
`docs/development.md`仅在构建／依赖／原生适配维护契约改变时更新。
修复和测试按独立逻辑原子提交；纯证据不产生空提交。
中文提交正文写清改了什么、为什么、真实验证；本 feature计划／状态／证据默认不入 Git。

## 最终阶段审计

实际开始时再创建 `audit-p3.md`。
对照 idea验收、P1决策、当前源码、真实字节／像素／资源和每项缺口独立 review。
组件通过不冒充 E2E；安装、重启、发布分别报告。
最终交付不得是只改上限、只读预览、全文驻留的分批读取，
或只在热缓存／单一典型输入下成立的 GB承诺。
