# Audit P5 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P5-T1 归因原生 Diff 完整流水线
- [x] P5-T2 修复共享 LF／CRLF 分行契约
- [x] P5-T3 收敛读取身份、错误与加载收尾
- [x] P5-T4 接入实测选中的原生性能措施

## 任务到文件的映射

- **P5-T1（本地实验，不提交）**：`Project.openDiff/openHistoricalDiff` → `DiffTab.reload/recomputeDisplay` → `DiffEngine/DiffSyntaxHighlighter` → `DiffNativeSurface/DiffTextView`；临时 `DiffPipelinePerformanceTests.swift` 只在测试期间挂载，最终源码与日志归忽略的 `build/performance/diff/`，永久项目中已删除。
- **P5-T2（`cae2cf6`，复查 `92ad0b4`、`8b3f742`、`c845cac`）**：共享 `DiffLineSplitter` 的 LF 标量扫描、`DiffComputation.DocumentBuilder` 的派生展示行；`DiffCodePaneView` 的真实段落首尾 ghost 占位、空文件虚拟行和 TextKit 行号映射；`DiffEngineTests`、`DiffTabTests` 的字节／坐标／撤销／删除与原生显示；`docs/features/diff.md`。
- **P5-T3（`b87f360`，复查 `00fed8c`、`a4dc9a0`；边界测试 `c19cb2d`）**：`DiffTab.reload`、Git index/tree/OID reader、历史标签复用；核实暂存删除、错误保留、损坏 HEAD、错误历史 D、实际 SHA-1/SHA-256 64 字符对象和 5MiB 原始字节上限；`DiffTabTests`、`GitHistoryFileTests`、`GitExecutionTests`、`WorkspaceIdentityTests`；`docs/features/diff.md`。
- **P5-T4（`0644d34`，复查 `c845cac`）**：原有 `recomputeDisplay` 的两侧 `async let`、原生布局热路径；删除 `DiffRowGeometry.visibleRows` 每次重绘扫描全文的代价，改由 `DiffTextView` 内容变化时更新唯一标记；`DiffTabTests`、`SyntaxHighlightingTests`、`EditorTextInputTests` 与原生 30 次 A/B 证据；`docs/features/diff.md`。

## 发现项

## 发现 F-26

- 任务：`P5-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:360-400`
- 摘要：`Unicode U+2028 行分隔在同一 TextKit 段落生成多行，而原生 Diff 几何丢弃非首行的绘制范围`
- 风险：`macOS NSTextLayoutManager 实测 A+U2028+B+LF 只有一个 NSTextParagraph，却含 3 个 textLineFragments（2 条正文+1 extra）；当前 DiffRowGeometry 只接收 first 或 extra，忽略中间正文视觉行，导致该行的 diff tint、强调、gutter 可见区域不覆盖后半文本`
- 预期修复：`保持 Git LF 每行唯一元数据，把同一 TextKit 段落所有非 extra 视觉行布局框合并成一个逻辑行的绘制范围，extra 仍独立；复用现有统一行几何，不增加第二套行号计算`
- 验证：`真实 DiffCodePaneView + NSTextLayoutManager U2028/0085/CR/CRLF 的 viewport 行框 Red→Green，统一/分栏/编辑和 ghost 原生回归`
- 解决证据：`5b48bed：真实 NSWindow/TextKit 的 U+2028/U+0085 两行装饰最初均只有 1/2 片段（Red p5-third-audit-unicode-geometry-red.log），Green p5-third-audit-visual-terminal-green.log；额外覆盖 U+2029、裸 CR 的续行且没有重复 gutter/ghost。150 个裸 CR 长 Git 行小视口下 EOF 仅在真实最后片段（p5-third-audit-long-cr-viewport.log）。最终 DiffTabTests 32/32（p5-third-audit-final-geometry-suite.log），未新增缓存或另一绘制器。`


## 发现 F-25

- 任务：`P5-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:192-232,1070-1118`
- 摘要：`编辑 Diff 删除全部正文后，空缓冲虚拟行错置删除 ghost 且没有可滚动高度`
- 风险：`DiffDecorations.edit 把空文件统一作为 1 行但 ghost anchor 仍为 0，当作显示在第 0 行之前；没有实际字符时 applyGhostSpacing 没有 paragraphRange，2 行删除 ghost 被画在视口上方或被裁切。真实 NSWindow 测试 ghost anchor 错与高度 0 均 Red`
- 预期修复：`由 DiffDecorations.edit 统一把空内容 ghost 归为虚拟行之后的 EOF 锚点，现有 DiffCodePaneView 内容高度计算在这个虚拟行上容纳 ghost，不能写入虚拟字符到用户文本`
- 验证：`空→纯删除、完整删除→撤销→恢复、短窗滚动、原生真实 TextKit Red→Green 和 DiffTabTests`
- 解决证据：`c845cac：真实 NSWindow/TextKit 删除到空文件，Red p5-third-audit-empty-red.log（EOF anchor nil、override height0），Green p5-third-audit-empty-green.log（虚拟行后 EOF ghost，可滚动）；空→输入→清空→去 ghost 测试及 DiffTabTests 30/30；始终不写虚拟字符。`


## 发现 F-24

- 任务：`P5-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:316-330`
- 摘要：`Diff 滚动每次绘制都完整扫描文本判断非 LF 换行，4MiB 普通文件产生帧级性能回退`
- 风险：`DiffRowGeometry.visibleRows 在每次 gutter 和 underlay 绘制执行 hasNativeNonLFSeparators(textView.text) 的 O(文件字节数) 扫描；4MiB ASCII 文本 Swift Debug 实测 x30 中位9.74ms/次，双次绘制约20ms，还未计 TextKit，影响长文件滚动/输入响应`
- 预期修复：`把特殊分隔符标记归实际 DiffTextView 文本内容所有者，在首次装载和真实文本变更时更新；viewport 只读 O(1) 标记，不引入缓存系统，保留裸 CR/Unicode/undo 边界`
- 验证：`真实 STTextView 编辑输入/撤销、LF/CRLF/裸CR/Unicode viewport 行号、改动前后 30 次同设备扫描/原生绘制；DiffTabTests及构建`
- 解决证据：`c845cac：Debug Swift 4MiB 普通文本旧 hasNativeNonLFSeparators 全量扫描30次，中位9.738ms/p95 10.085ms；此前每 viewport gutter + underlay 调用。现在 DiffTextView 对内容实际变化失效缓存、DiffNativeSurface delegate 单次捕获文本并更新标记，viewport O(1) 读取；输入/撤销/CRLF/裸CR 回归 DiffTabTests 30/30，未宣称未经测量的 GPU FPS。`


## 发现 F-23

- 任务：`P5-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:1069-1116`
- 摘要：`编辑态一条 LF Git 行包含裸 CR 段落时，删除 ghost 占位重复插入多次`
- 风险：`applyGhostSpacing 对整条 LF 行的 utf16 range 设置同一个 paragraphSpacingBefore；TextKit 将其拆成多个实际段落，真实原生 XCTest 中第二个段落也获得 15pt 占位，导致重复空隙、删除内容与 gutter 行号错位`
- 预期修复：`按首／末实际 TextKit 段落分别施加 before／after 样式，正确清除旧占位，不改变 Git 行或保存字节`
- 验证：`NSWindow/TextKit 实际 attributed paragraph style Red→Green，首/尾 ghost、CRLF、empty、undo、DiffTabTests`
- 解决证据：`c845cac：真实 AppKit/TextKit 裸 CR 的删除行 ghostBefore 第二段重复 15pt；Red build/performance/diff/p5-third-audit-ghost-red.log，Green p5-third-audit-ghost-green.log。首段/末段独立段落样式、清除旧样式且正文不变，DiffTabTests 30/30 passed。`


## 发现 F-22

- 任务：`P5-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:303-355`
- 摘要：`Diff 原生编辑态按 TextKit 段落计数而非 LF 行号，裸 CR 后行号及装饰错位`
- 风险：`TextKit 将 A\\rB\\nC\\n 拆成三个 NSTextParagraph，Git LF 分行只有两行；当前 visibleRows 使用 textElements.count 并逐 fragment 自增，第二段误标为第 2 行，第三段找不到装饰`
- 预期修复：`利用现有 NSTextParagraph 的实际末尾 LF 判断 Git 行前进，仅在真正 LF 结束的段落递增；保留 TextKit 原生片段几何和文件字节，不建缓存及并行映射`
- 验证：`真实 NSTextContentStorage 及 NSWindow 编辑 pane 行号映射 Red/Green；DiffTabTests、DiffEngineTests、GitHistoryFileTests`
- 解决证据：`8b3f742：真实 NSWindow/TextKit 测试 Red p5-second-audit-geometry-red.log（3 个段落 index [0,1,2]），Green p5-second-audit-geometry-green.log 与 p5-second-audit-geometry-optimized.log（Git LF 行 [0,0,1]，DiffTabTests 28/28）。仅特殊分隔符按实际末尾 LF 计数，普通文本沿用快速路径；单独 20k 段落 50 次测试显示正常路径原生 count 更廉价，避免所有绘制采用昂贵的 reduce。`


## 发现 F-21

- 任务：`P5-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:1232-1257`
- 摘要：`包含裸 CR 的真实原生 Diff 仍强制按 LF 行数设内容高度`
- 风险：`Git LF-only 行数与 TextKit 实际段落数不同；一个 Git 行可能映射数十个原生段落，固定高度按原行数限制滚动内容并破坏行几何，真实 NSWindow 测试已 Red`
- 预期修复：`仅在存在非 LF 原生换行标记时停止强制固定总高度，按 TextKit 实际布局求高度；普通 LF/CRLF 继续保持已验证的固定行高和双栏范围，不改用户字节`
- 验证：`真实 DiffCodePaneView/STTextView Red/Green + CRLF 基线 + DiffTabTests 整组 + Debug/Release 构建`
- 解决证据：`92ad0b4：原生 NSWindow/STTextView bare CR 固定高度 Red p5-second-audit-cr-red.log，CRLF 派生末行缺布局 LF Red p5-second-audit-reviewcrlf-red.log；Green p5-second-audit-engine-green.log（5/5）和 p5-second-audit-native-green2.log（27/27），另 p5-second-audit-history-postrender.log（18/18）、input-postrender.log（5/5）。保留源字节及正常固定行高。`


## 发现 F-20

- 任务：`P5-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffViewerView.swift:314-322`
- 摘要：`历史删除 Diff 未验证被选中的提交仍有效`
- 风险：`source.commit(status:D) 完全跳过 hash 对应 tree，若该 hash 被清除或无效而 parent 仍可读，就会呈现一份并不存在的成功删除 Diff`
- 预期修复：`删除状态也通过现有 tree metadata 核实选中 hash，唯有实际缺失的路径允许空新侧；损坏提交必须返回错误，不增加独立 reader`
- 验证：`真实 Git 有效删除/无效删除 hash 对照；GitHistoryFileTests Red→Green`
- 解决证据：`a4dc9a0：真实 Git 有效删除/无效历史删除 hash，Red p5-second-audit-red.log→Green p5-second-audit-green.log；GitHistoryFileTests 18/18 全通过。`


## 发现 F-19

- 任务：`P5-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/DiffViewerView.swift:804-823`
- 摘要：`悬空分支引用被误判为 unborn HEAD，伪造暂存 Diff 空旧侧`
- 风险：`rev-parse HEAD^{commit} 返回 1 且 symbolic-ref HEAD 返回 0 既符合真正 unborn，也符合已存在但悬空的 refs/heads/main；后者不能被当作初次提交展示`
- 预期修复：`继续验证 HEAD 指向的分支 ref 是否确实不存在；只有明确缺失才允许空 HEAD 侧，其余失败保持错误`
- 验证：`真实临时 Git unborn 与悬空 refs/heads/main 对照；GitHistoryFileTests Red→Green，相关 XCTest`
- 解决证据：`a4dc9a0：真实 Git dangling HEAD vs unborn 的 Red p5-second-audit-red.log，Green p5-second-audit-green.log；GitHistoryFileTests 18/18 全通过。`


## 发现 F-18

- 任务：`P5-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/DiffViewerView.swift:468-470`
- 摘要：`已加载 Diff 读取失败后字体或外观刷新清空保留的旧展示`
- 风险：`Git 故障后原生 diff 本应维持上一有效内容；主题或字体切换触发 refreshNativeAppearance/recomputeDisplay 却因 error 非空把 display 置 nil`
- 预期修复：`让已经成功加载的内容在错误横幅期间仍可重新构建原生展示，同时禁止把首次读取失败的空缓冲渲染为有效 Diff`
- 验证：`DiffTabTests 成功读取→损坏 Git→刷新外观→旧原生内容保持 Red/Green + make test`
- 解决证据：`00fed8c：Red p5-independent-red.log（成功→失去 .git→字体/外观重新渲染超时）；Green p5-native-final.log，旧 Diff/原生 STTextView 仍挂载、错误横幅保留，26/26 通过。`


## 发现 F-17

- 任务：`P5-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/DiffViewerView.swift:338-339`
- 摘要：`暂存区删除文件的合法空 index 被当作 Git revision 缺失错误`
- 风险：`Git 暂存 D 文件行进入真实 DiffTab 后展示错误，无法审阅 HEAD→空文件的删除差异`
- 预期修复：`仅 staged 的合法缺失 index 作为空新侧，保留无效命令、损坏 index 和未合并冲突的错误；不削弱历史 revision 的 required 约束`
- 验证：`真实 git rm 临时仓库 + DiffTabTests staged deletion Red/Green + make test`
- 解决证据：`00fed8c：Red p5-independent-red.log（staged D 文件误报 missing、无法绘制）；Green p5-native-final.log，真实 git rm HEAD→空 index、冲突 index 拒绝、NSWindow/TextKit 26/26 通过。`


三轮独立源码复查对照 P5-T1～T4 的实际用户入口、提交、原生消费者及磁盘副作用，累计发现 F-17～F-26 **10 项可复现缺陷**。经 `00fed8c`、`a4dc9a0`、`92ad0b4`、`8b3f742`、`c845cac`、`5b48bed` 六个生产修复提交逐项 Red→Green，另有 `c19cb2d` 边界测试提交。既有修复不重复列为新 finding。

明确验收边界：本机真实 Git／NSWindow／TextKit 已验证**文字进入原生表面、编辑保存回磁盘**，但不能冒充独立 App 的菜单点击或合成像素 E2E；真实 SSH 需使用授权专属连接。性能 A/B 为同机同文本的 Debug 热路径，冷启动／峰值 RSS／渲染像素／完整交互只能在 P6 综合复测中继续取证，不由组件时间外推。

## 修复日志

- T2 从共享根因删除逐 `Character` LF 匹配，使用 Unicode scalar；CR 及原字节、UTF-16 坐标不转换，单一分行器继续供 review 和 edit 使用。
- T3 以原始 NUL index/tree metadata 选固定 OID 后读 size/blob，删除动态 Git spec、stderr 词汇猜错缺失和重复的 `isUnmerged` 查询；unborn HEAD、冲突 stage 及特殊路径有实际回归。读取错误保留之前已显示内容，失效 fold 不覆盖新输入；不可变历史已加载的重复点击不再读 Git，live 仍重读。未删除保存／只读／容量的必要保护。
- T4 只改双侧 captures 的并行方式，保留同一个 query 缓存、core/runs 和 `displayGeneration`；对同机原生文本安装中位约 5.8% 的两轮可比收益，不增加任务调度、缓存或新依赖。临时性能 XCTest 已退出正式目标，原始实验源码在忽略目录。
- 首轮复查 F-17／F-18（`00fed8c`）：暂存删除的空 index 合法，错误后的已有正文仍可随主题重新计算；删除过时 `git show` 注释。
- 第二轮 F-19／F-20（`a4dc9a0`）：确认 HEAD 所指 branch ref 真不存在才能用 unborn 空侧；历史 D 文件必须在真实可读的选中提交中缺失，不再跳过 selected hash。
- 第二轮 F-21（`92ad0b4`）：`DiffComputation.DocumentBuilder` 为派生只读文档补最后一行的布局 LF，原始字节、缺失换行标记不变；TextKit 对裸 CR／Unicode 分隔符采用实际高度，普通 LF／CRLF 保持固定行高。原有测试中隐含“人工渲染文档必须漏终止 LF”的旧断言同步改成正确显示契约。
- 第二轮 F-22（`8b3f742`）：真实 TextKit 原生编辑段落在裸 CR 后产生错误行索引 `[0,1,2]`，修为 Git LF 索引 `[0,0,1]`；不存第二套行号索引。普通文件继续使用原生段落 `.count`，只有实际非 LF 分隔符才根据段落结尾 LF 计数。
- 第三轮 F-23／F-25（`c845cac`）：TextKit 裸 CR 多段落中只向首／末真实段落加删除行占位；全部删除为空后使用虚拟行后的 EOF ghost 且内容高度足以滚动，不改用户文本；后续输入、恢复、移除 ghost 时重算正确。
- 第三轮 F-24（`c845cac`）：4MiB 普通文本的特殊换行扫描在本机 Debug 30 次中位 9.738ms、p95 10.085ms。原实现每次 gutter 与底纹绘制都进行全量扫描，改为仅在文档安装／原生输入与撤销变化时失效，视口 O(1) 读取；这是明确减少扫描工作，不把该单项测量说成画面帧率提升。
- 第三轮 F-26（`5b48bed`）：根因是一个 Git LF 行可能分解成多个 TextKit 视觉片段。使用共享 `DiffRowGeometry` 为 `U+2028`／`U+0085` 的同一段落视觉换行以及 `U+2029`／裸 CR 的跨段落换行保留完整 tint／强调范围，只在首段绘制行号及起始 ghost，末尾标记与 EOF ghost 只在真实行尾而非视口边界绘制；150 个裸 CR 的单 Git 行短窗口原生回归通过，无新增独立渲染器。
- 第三轮新增必要而非防御式的回归（`c19cb2d`）：500 组固定种子 Unicode／混合 CRLF／裸 CR／换行／组合字形，以及 820 行超阈值锚点差异，核对 UTF-8 原文、UTF-16 行内／来源范围和 Diff 操作不变量；真实 SHA-256 Git 仓库三类 Source 与 5MiB 精确容量边界，皆通过已有 XCTest。

## 验证日志

- 原实施基线 HEAD `0644d34` 的历史全量记录（`build/performance/diff/p5-final-full.log`）：315 项、0 失败、3 个需授权 SSH 的用例跳过；当时 Debug／Release 构建及签名通过。此行只表示原实施时的验证，不替代独立复查后的测试。
- 原实施分层回归：DiffEngineTests 4/4、DiffTabTests 23/23、GitHistoryFileTests 16/16、GitExecutionTests 4/4、WorkspaceIdentityTests 4/4、SyntaxHighlightingTests 15/15、EditorTextInputTests 3/3；独立复查新增三个 `DiffTabTests`，Red 日志 `p5-independent-red.log`、最终 Green `p5-native-final.log`（26/26），覆盖真实 Git 暂存删除与冲突、NSHostingView/STTextView、失败后外观刷新仍挂载旧正文。
- 独立复查提交 `00fed8c`：`make test DERIVED_DATA=build/DerivedData-P5`（`build/performance/diff/p5-independent-full-isolated.log`）实际执行 **344 tests、5 skipped、3 个 testcase 失败（13 个断言失败，1 unexpected）**。失败仅出现在并行审查中的 `GitStatusModelTests` 两项（`testCoreIsDeliveredBeforeRefMetadataAndSurvivesRefFailure`、`testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers`）和 `RemoteCommandsTests` 一项（`testSSHFileRenamePreservesDanglingSymlinksAndRejectsOccupiedDestinations`）；P5 的 DiffEngine（4）、DiffTab（26）、GitHistoryFile（16）、GitExecution（4）、SyntaxHighlighting（16）、EditorTextInput（3）、WorkspaceIdentity（5）共 **74/74** Green。其他阶段的失败不在 P5 范围内擅自修复，也不谎称全量成功。
- 首轮复查的 `make build DERIVED_DATA=build/DerivedData-P5` 和 `make build:release DERIVED_DATA=build/DerivedData-P5` 均 **BUILD SUCCEEDED**，分别严格 `codesign --verify --deep --strict` 通过；日志为 `build/performance/diff/p5-independent-{debug,release}-build.log`。并行 AI 仍在修改 P1～P4 生产代码，因此没有以包含其他阶段未验收改动的构建覆盖 `/Applications/Kero.app`，也没有重启用户 App。
- 第二轮审查 `a4dc9a0`：`GitHistoryFileTests` 18/18，Red→Green 的损坏 HEAD 与无效删除记录保留在 `p5-second-audit-{red,green}.log`。`92ad0b4`：`DiffEngineTests` 5/5、`DiffTabTests` 27/27、`GitHistoryFileTests` 18/18、`EditorTextInputTests` 5/5；Red/Green 和完整原生 TextKit 观测见 `p5-second-audit-*` 日志。`8b3f742`：`DiffTabTests` 28/28，包括编辑态 Git LF 索引 `[0,0,1]` 的独立 Red→Green；`p5-second-audit-geometry-{red,optimized}.log`。
- 第二轮全量 `make test DERIVED_DATA=build/DerivedData-P5`（`p5-second-audit-full-suite.log`）实际 **359 项、6 skipped、1 testcase 失败**：`FileTabTests.testRepeatedWindowFocusCoalescesInFlightCleanRefresh`，属于 P2 正在修改的窗口重复读取路径；**该次执行先于 `8b3f742` 的最新纯 P5 行号改动**，其后已另跑 `DiffTabTests` 28/28，不能把本轮全量称为最终全部通过。
- 在 `8b3f742` 提交之后，使用独立 `build/DerivedData-P5` 的 `make build` 和 `make build:release` 均 **BUILD SUCCEEDED**，Debug／Release 均通过严格 `codesign --verify --deep --strict`。证据 `build/performance/diff/p5-second-audit-final-{debug,release}.log`。此版本还未安装到 `/Applications/Kero.app` 或重启正式 App；其他阶段源码仍在并行修改，整库 XCTest 的 P2 失败尚未收口。
- 最终 P5 相关 XCTest 分组复核：`DiffTabTests` 28/28、`DiffEngineTests` 5/5、`GitHistoryFileTests` 18/18、`SyntaxHighlightingTests` 18/18、`GitExecutionTests` 4/4、`WorkspaceIdentityTests` 5/5，合计 **78/78**，日志 `build/performance/diff/p5-second-audit-{geometry-optimized,postcommit-*}.log`。此后同时执行的 `EditorTextInputTests` 因 P3 正在修改的 `Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift:214` 强制解包崩溃，XCTest 恢复宿主后另有 3 项 passed 但**整体命令 `TEST FAILED`**（`p5-second-audit-postcommit-EditorTextInputTests.log`），不可冒充该测试组全绿；先前 `p5-second-audit-input-postrender.log` 的 5/5 属于更早的源码快照。
- 同机 Apple M1 Pro、macOS 27.2、Debug 的 1200 行 Swift 样本：双侧 captures 30 次串行中位 74.670ms→并行 53.733ms，name/range 等价；Git→Diff→原生文本安装反向各 30 次中位 236.562ms→222.759ms，p95 242.726ms→237.101ms。内容安装不是屏幕合成或冷启动测量。
- 已读源码调用链与测试确认旧动态 Git spec、stderr 缺失猜测、重复 isUnmerged、逐 Character 分行、历史不可变重复读取均已替代，临时性能类从正式 XCTest 目标删除，实验源码留在忽略目录。
- 文档相关 8 个入口（docs/README、diff、git、editor、testing、development、idea、plan-p5）的相对 Markdown 文件路径均可达；git diff --check 通过。
- 第三轮专项：`p5-third-audit-difftab-30.log`、`p5-third-audit-final-geometry-suite.log` 的 DiffTab 从 30/30 扩至 **32/32**；DiffEngineTests 6/6（含 500 组固定种子），GitHistoryFileTests 20/20（含 SHA-256 和 5MiB 边界），SyntaxHighlightingTests 20/20、GitExecutionTests 4/4、WorkspaceIdentityTests 5/5、WorkspaceContentIdentityTests 3/3、EditorTextInputTests 9/9，总计 **99/99** 对应分组通过。`p5-third-audit-unicode-geometry-red.log` 的原生 U+2028／U+0085 均漏了第二视觉片段，`p5-third-audit-final-geometry-suite.log` Red→Green；`p5-third-audit-long-cr-viewport.log` 单独通过 150 裸 CR 视口边界。
- 在 `c19cb2d` 之后、`5b48bed` 之前，带授权 Windows SSH 的 `p5-third-audit-full-windows.log` 真实 **376/376 passed、0 failures、0 skipped**，包含远端文件树、Git panel 自动刷新、交互式 Rebase、二进制历史恢复、Stash/Clean/Ignore；这是该时点代码的完整集成证据，不能替代最后的视觉几何提交。`5b48bed` 之后启动的最终验证已完成：`p5-third-audit-final-{debug,release}.log` 记录 Debug／Release 均 `BUILD SUCCEEDED` 且 `codesign --verify --deep --strict` 通过；`p5-third-audit-full-windows-after-visual.log` 记录授权 Windows SSH 整库 **388 tests、0 failures、0 skipped、TEST SUCCEEDED**，包含真实 SSH Git、文件树、Git 自动刷新、断线恢复及历史文件等。测试启动时 HEAD 为 `5b48bed95ba0`，运行期间另一个开发任务在相同分支追加了 Git Graph 提交，不能把该次结果冒充后续 Git Graph 提交的重新验收。
- P6 历史证据已包含专用 Windows SSH 读取五种 Diff 来源（1/1）及全量授权 SSH（315/315）、隔离 App 图片／编辑／滚动与短时内存测量；它们早于本次七个复查生产／测试提交，不能冒充当前提交在真实 SSH／完整 App 的重新验收。完整独立 UI、用户输入的全部极端换行及 Instruments 运行时限制仍按实测边界区分。

## Gate（是否允许进入下一阶段）

- 结论：**P5 阶段 Go，已完成要求的构建、签名、专项测试及授权 Windows SSH 整库集成测试**；独立 App 菜单点击／屏幕合成 E2E 仍未运行，不属于已验证项。
- 理由：P5-T1～T4 已完成，F-17～F-26 十项均有真实 Git／TextKit Red→Green 证据；专项 99/99（含 SHA-256、5MiB 和 Unicode 极端输入）。最终 `5b48bed` 的 Debug／Release 构建及严格签名通过，之后启动的授权 Windows SSH 整库 XCTest **388/388 passed、0 failures、0 skipped**。未连接外接测试屏幕，因此未抢占主屏执行独立 App 前台 UI 自动化；该边界不冒充完整 E2E，也不否定实际通过的 P5 集成 Gate。

## 最终状态与剩余风险

- 当前状态：P5-T1～T4 及 F-17～F-26 十项 finding 均为 **Resolved**，六个生产修复提交及一个边界回归提交已入库；最终 Build、Code Sign、P5 专项和授权 Windows SSH 全量 XCTest 均已通过。Git Graph Feature 仍由另一个任务推进，不属于 P5 验收。
- 剩余边界：本轮已重新运行真实 Windows SSH 端到端后端／宿主 XCTest 路径，但没有独立 App 菜单操作的像素与键盘 E2E；外接测试屏幕当前未连接。没有重新完成 Instruments 长时间 RSS、FPS 及内存泄漏专项测量；已有 Xcode-beta Instruments/DTServiceHub 限制不能直接归因为 Kero 缺陷。正式 App 没有安装或重启。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
