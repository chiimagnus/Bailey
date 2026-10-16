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
- **P5-T2（`cae2cf6`）**：`kero/Git/DiffEngine.swift` 的唯一 `DiffLineSplitter` LF 标量扫描；`KeroTests/Unit/Git/DiffEngineTests.swift` 原始字节、Unicode 与 UTF-16 回归；`KeroTests/NativeUI/Git/DiffTabTests.swift` 原生 CRLF review/edit/undo/save；`docs/features/diff.md`。
- **P5-T3（`b87f360`，独立复查 `00fed8c`）**：`DiffViewerView.swift` 的 `DiffTab.reload`、`GitLocation/gitObject/gitContent`、加载失败保留与旧 fold 身份，`Project.swift` 的历史标签重用；复查修复暂存删除空 index 误报与出错后外观刷新清空旧 Diff；`DiffTabTests`、`GitHistoryFileTests`、`GitExecutionTests`、`WorkspaceIdentityTests`；`docs/features/diff.md`。
- **P5-T4（`0644d34`）**：`DiffTab.recomputeDisplay` 原有后台闭包中使用两侧 `async let`，无新 executor、缓存、渲染表面；`DiffTabTests`、`SyntaxHighlightingTests`、`EditorTextInputTests` 加交错 30 次 capture 等价及实际原生 30 次 A/B 的临时证据；`docs/features/diff.md`。

## 发现项

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


独立复查按 P5-T1～T4 的真实入口、代码与提交核对，额外发现 F-17／F-18 两项生产缺陷，均已按 Red→Green 修复于 `00fed8c`。T2 原先 CRLF 漏行，以及 T3 原先的 revision 错判、旧正文清空和重复历史读取，属于原计划的既有修复，不重复列为新 finding。

明确验收边界：本机真实 Git／NSWindow／TextKit 已验证**文字进入原生表面、编辑保存回磁盘**，但不能冒充独立 App 的菜单点击或合成像素 E2E；真实 SSH 需使用授权专属连接。性能 A/B 为同机同文本的 Debug 热路径，冷启动／峰值 RSS／渲染像素／完整交互只能在 P6 综合复测中继续取证，不由组件时间外推。

## 修复日志

- T2 从共享根因删除逐 `Character` LF 匹配，使用 Unicode scalar；CR 及原字节、UTF-16 坐标不转换，单一分行器继续供 review 和 edit 使用。
- T3 以原始 NUL index/tree metadata 选固定 OID 后读 size/blob，删除动态 Git spec、stderr 词汇猜错缺失和重复的 `isUnmerged` 查询；unborn HEAD、冲突 stage 及特殊路径有实际回归。读取错误保留之前已显示内容，失效 fold 不覆盖新输入；不可变历史已加载的重复点击不再读 Git，live 仍重读。未删除保存／只读／容量的必要保护。
- T4 只改双侧 captures 的并行方式，保留同一个 query 缓存、core/runs 和 `displayGeneration`；对同机原生文本安装中位约 5.8% 的两轮可比收益，不增加任务调度、缓存或新依赖。临时性能 XCTest 已退出正式目标，原始实验源码在忽略目录。
- 独立复查额外修复 F-17／F-18（`00fed8c`）：暂存删除合法空 index 的新侧改用已有 `firstGitContent`，保留 stage 冲突错误；`recomputeDisplay` 以已成功加载的快照而非最近一次 IO 错误作为重建资格。清理了过时的 `git show` 注释，不保留旧读取实现，也不删必要校验。

## 验证日志

- 原实施基线 HEAD `0644d34` 的历史全量记录（`build/performance/diff/p5-final-full.log`）：315 项、0 失败、3 个需授权 SSH 的用例跳过；当时 Debug／Release 构建及签名通过。此行只表示原实施时的验证，不替代独立复查后的测试。
- 原实施分层回归：DiffEngineTests 4/4、DiffTabTests 23/23、GitHistoryFileTests 16/16、GitExecutionTests 4/4、WorkspaceIdentityTests 4/4、SyntaxHighlightingTests 15/15、EditorTextInputTests 3/3；独立复查新增三个 `DiffTabTests`，Red 日志 `p5-independent-red.log`、最终 Green `p5-native-final.log`（26/26），覆盖真实 Git 暂存删除与冲突、NSHostingView/STTextView、失败后外观刷新仍挂载旧正文。
- 独立复查提交 `00fed8c`：`make test DERIVED_DATA=build/DerivedData-P5`（`build/performance/diff/p5-independent-full-isolated.log`）实际执行 **344 tests、5 skipped、3 个 testcase 失败（13 个断言失败，1 unexpected）**。失败仅出现在并行审查中的 `GitStatusModelTests` 两项（`testCoreIsDeliveredBeforeRefMetadataAndSurvivesRefFailure`、`testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers`）和 `RemoteCommandsTests` 一项（`testSSHFileRenamePreservesDanglingSymlinksAndRejectsOccupiedDestinations`）；P5 的 DiffEngine（4）、DiffTab（26）、GitHistoryFile（16）、GitExecution（4）、SyntaxHighlighting（16）、EditorTextInput（3）、WorkspaceIdentity（5）共 **74/74** Green。其他阶段的失败不在 P5 范围内擅自修复，也不谎称全量成功。
- 独立复查的 `make build DERIVED_DATA=build/DerivedData-P5` 和 `make build:release DERIVED_DATA=build/DerivedData-P5` 均 **BUILD SUCCEEDED**，分别严格 `codesign --verify --deep --strict` 通过；日志为 `build/performance/diff/p5-independent-{debug,release}-build.log`。并行 AI 仍在修改 P1～P4 生产代码，因此没有以包含其他阶段未验收改动的构建覆盖 `/Applications/Kero.app`，也没有重启用户 App。
- 同机 Apple M1 Pro、macOS 27.2、Debug 的 1200 行 Swift 样本：双侧 captures 30 次串行中位 74.670ms→并行 53.733ms，name/range 等价；Git→Diff→原生文本安装反向各 30 次中位 236.562ms→222.759ms，p95 242.726ms→237.101ms。内容安装不是屏幕合成或冷启动测量。
- 已读源码调用链与测试确认旧动态 Git spec、stderr 缺失猜测、重复 isUnmerged、逐 Character 分行、历史不可变重复读取均已替代，临时性能类从正式 XCTest 目标删除，实验源码留在忽略目录。
- 文档相关 8 个入口（docs/README、diff、git、editor、testing、development、idea、plan-p5）的相对 Markdown 文件路径均可达；git diff --check 通过。
- 独立 App 完整菜单／GUI E2E、授权真实 SSH 与长期资源占用仍由 P6 验收，不把自动测试的绿色扩展到它们。

## Gate（是否允许进入下一阶段）

- 结论：**P5 阶段自身 Go；当前整库集成测试 No-Go**。
- 理由：P5 四项真实调用链、三次原始生产提交与 `00fed8c` 根因修复均已核对，P5 相关永久 XCTest 全部 Green，性能收益有同机 A/B；但独立全量 XCTest 现有其他阶段并行修改导致的 GitStatusModel／RemoteCommands 失败，尚不能宣称整个仓库通过。需要相应 P2／P4 审查修复并在稳定源码上重跑整库验收。独立 App、真实 SSH、长期内存和像素效果也不在 P5 组件证据内。

## 最终状态与剩余风险

- 当前状态：P5-T1～T4 及本次发现 F-17／F-18 均为 **Resolved**；P5 范围内未留有已证实未修复缺陷。整库全量测试另有跨阶段失败，已逐项记录。
- 剩余风险：独立 App 前台真实 E2E、授权 SSH、长期 RSS/CPU 仍待 P6。P7 的官方插件迁移 No-Go 不影响现行 Neon 下的 P5 完成。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
