# Audit P1 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [ ] P1-T1 建立 Git Diff 全链路体验与性能基线
- [ ] P1-T2 验证 TextKit 完整滚动范围与快速首屏的可行路线
- [ ] P1-T3 实证编辑事件与隐藏区间编辑语义
- [ ] P1-T4 分析 Git 快照子进程与语法派生真实成本
- [ ] P1-T5 固定预算技术决定与生产阶段准入
- [ ] P1-T6 移除生产语法高亮中的测试专用全量入口

## 任务到文件的映射

- P1-T1
  - `BaileyTests/Git/NativeDiffTabTests.swift` 的模型／原生／组件绘制和输入基线；`evidence-p1.md`
- P1-T2
  - `Bailey/Git/DiffTextView.swift`、实际 SDK 的 TextKit 头文件、`build/` 下的局部原型补丁与日志
- P1-T3
  - `BaileyTests/Editor/NativeEditorCompositionTests.swift` 的 21 阶段事件／字节断言；`NativeDiffTabTests` 输入和保存
- P1-T4
  - `BaileyTests/Git/GitExecutionTests.swift`、`DiffEngineTests.swift` 和真实后台取消测量；尚未改生产算法
- P1-T5
  - 本 feature 的 `idea.md`、`plan-p2.md`、`plan-p3.md` 与 `evidence-p1.md`；预算和生产准入未冻结
- P1-T6
  - `Bailey/Git/DiffSyntaxHighlighter.swift`、`BaileyTests/Git/DiffSyntaxOracle.swift` 和两处测试迁移

## 发现项

## 发现 F-05

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Git/NativeDiffTabTests.swift:testNativeDiffEditorFocusLossSavesThroughBackend`
- 摘要：`焦点保存夹具只等待原生表面创建，未等待编辑器实际挂载窗口`
- 风险：`全量中AppKit明确报告editor.window为nil并撤销第一响应者，实际未获得或失去焦点，却等待保存而超时；定点通过不能消除此前错误前提`
- 预期修复：`在宿主视图树中等待可编辑NSTextView附着目标窗口，并断言实际第一响应者，然后验证焦点交接和后端最终字节`
- 验证：`先运行模型首帧基线与焦点保存组合，再完整make test核对挂载和真实保存结果`
- 解决证据：`9eb27356：等待真实host层级的editor.window匹配并断言实际firstResponder；组合回归2项0失败；当前HEAD完整make test为848项、16项SSH跳过、0失败，退出0。此前846项失败及AppKit detached-window告警保留在git-diff-p1-full-host.log。`


## 发现 F-04

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`docs/features/diff.md`
- 摘要：`功能文档把宿主Diff撤销重做结果写成完整App快捷键覆盖`
- 风险：`WorkspaceGitUITests实际只输入和保存，误导后续验收跳过Diff特有的系统Undo路由`
- 预期修复：`纠正文档中的宿主和E2E边界，P4-T2仍须补齐实际Diff撤销重做快捷键`
- 验证：`逐方法核对WorkspaceGitUITests与NativeDiffTabTests的真实操作和磁盘断言`
- 解决证据：`提交中的docs/features/diff.md已明确WorkspaceGitUITests只覆盖编辑与保存，Undo/Redo为宿主断言；逐方法核对Git UI唯一Command-Z用例是gitignore文件编辑而非Diff。新增原生事件矩阵21个动作阶段全部核对字节。`


## 发现 F-03

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Makefile:27`
- 摘要：`GUI枚举持续返回零项，完整App首帧和键盘基线没有获得`
- 风险：`组件像素不能代替WindowServer首帧或真实Command-S，无法冻结完整用户路径预算`
- 预期修复：`保存实际枚举JSON、Runner采样与testmanager日志，解决测试发现或外部授权环境后再核销GUI`
- 验证：`make build:ui；make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests`
- 解决证据：`2026-11-06 GUI原0项初始化问题已恢复：独立Bailey Dev WorkspaceGitUITests含Windows SSH执行7项0失败0跳过，日志build/git-diff-p1-windows-ui-full-class-exclusive.log。真实输入/写盘/菜单Find路径有E2E证据；但Peekaboo只能约5–7FPS，准确WindowServer首像素、首次可输入P95尚未取得，移交P4-T2/T4。`


## 发现 F-02

- 任务：`P1-T4`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Git/DiffEngine.swift:819`
- 摘要：`密集行内投影已实证为热点，但取消及完整分配归因尚未核销`
- 风险：`399/400 token、1000 对替换投影约37秒，稀疏样本不能支持生产阶段忽略此路径`
- 预期修复：`补齐共享token、取消时延和分配测量，将经验证的最小词级算法修复纳入P3-T3`
- 验证：`make test ONLY_TESTING=BaileyTests/DiffEngineTests/testDenseIntralineProjectionTokenBoundaryCosts；追加真实取消测量`
- 解决证据：`2026-11-06 399/400/401 token × 1/100/1000对与共享token、真实DiffCore取消已测；400token千对约37秒，100×400取消尚需约277ms，旧后台取消100×400曾约3709ms；内存归因/产品修复属于P3-T3。见evidence-p1.md及build/git-diff-p1-*日志；不把实测缺陷写成已修复。`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Git/DiffTextView.swift:1535`
- 摘要：`尚无满足全条件的原生布局技术准入证据`
- 风险：`直接移除全文布局可能导致错误几何，现有替代原型也未证明折叠首屏和热滚动达标`
- 预期修复：`继续单一 TextKit 布局所有者实验，校正视口内真实行与尾行断言，取得准入前保留生产保护路径`
- 验证：`复验 evidence-p1.md 中的原型补丁及原生滚动矩阵`
- 解决证据：`2026-11-06 P1原生估算快路径4/17准确，重定位17/17但100k中位181ms/最慢310ms；隐藏元素跳过24k布局253→50ms未验证未折叠和IME。技术No-Go已写入idea.md与plan-p2.md，P2-T1不得动生产全文布局直到同一TextKit owner完成准确/性能Red→Green；见evidence-p1.md和evidence-p1-textkit-transient.md。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- `8ce6d0da`：删除仅有测试消费者的旧全文入口及预算，独立 oracle 留在宿主；未删除任何数据保护。
- `fe777a29`：固定真实原生编辑元数据和 Undo／Redo 字节契约；修正 F-04 的文档验收层次。
- `b0320924`、`644d2aa9`、`2dc1a37a`：分别原子提交对象读取、密集投影／取消、首帧／输入基线。
- `9eb27356`：修正 F-05 的实际挂载前提，检查真实窗口及第一响应者，保留最终保存字节断言。
- `65152f3d`：八种折叠命令逐项核对完整原文、Undo／Redo、保存及 Index；未把直接选区设置算作 Find／拖选 GUI。
- 原型仅保留在本地 `build/` 证据，不进入产品或常规测试源；失败不被写成性能修复。
- 保留期间已另行暂存的 feature 文件，未纳入上述代码提交；仅移除本任务临时原型的暂存。

## 验证日志

- 提交 `9eb27356` 完整 `make test`：848 项、16 SSH 跳过、0 失败，退出 0；
  日志 `build/git-diff-p1-final-full-host.log`。之前 846 项的焦点保存失败保留，F-05 有 Red→Green 及全量证据。
- `make build`：Debug 构建及其后严格签名检查退出 0；`make build:ui` 退出 0，仅证明编译。
- Release 四项性能／字节测试退出 0；另行正式 `make build:release` 及严格验签退出 0，未安装或重启正式 App。
- 新的折叠命令矩阵及相邻原生组合共 15 项通过，退出 0；朴素 NSTextView 多选区对照的夹具契约错误保留失败证据。
- 最新 HEAD `65152f3d` 再跑完整宿主：849 项、16 SSH 跳过、0 失败、约 953 秒，完整 Make 命令退出 0；
  日志 `build/git-diff-p1-final-full-host-with-fold-commands.log`，新增矩阵及真实挂载焦点保存均实际通过。
- 同一 HEAD 再跑 Debug／正式 Release 构建及各自严格验签，均退出 0；
  新增折叠命令的 Release XCTest 1 项、0 失败、完整命令退出 0，未安装或重启正式 App。
- 真实普通输入／粘贴／Delete／全选／组合／多选区／程序追加及各自 Undo／Redo，
  已逐次重建 UTF-8 字节；1k／24k／100k、txt／Swift、文首／中／末每组 30 次输入，最终中文保存和 Index 未改动有证据。
- 1k／24k 的 Staged／Unstaged 各 30 次模型／原生／组件绘制分时，
  Git metadata／size／blob／batch 各 30 次，逐次检查对象头、字节和终结 LF；组件缓存绘制不是 WindowServer 首帧。
- 399／400／401 token × 1／100／1000 对替换均已执行；
  真实取消仍有约 3.7 秒 Debug 阻塞，结果不发布不代表底层已及时停止。
- GUI 原生发现 JSON 的 errors 明确为 `Timed out while enabling automation mode`，
  系统要求用户认证；未绕过安全策略，不将 0 项测试、编译或宿主结果写成 GUI 通过。
- SSH 已获任务授权，但现有两个独立目标连接超时；16 个跳过方法的具体条件、影响和补验逐项列在 `evidence-p1.md`。
- 显式注入授权目标的 Windows Diff 测试也实际执行，约 8.49 秒后 SSH 退出 255；1 项、2 处失败，Make 退出 2，不作通过或跳过处理。
- 其它未核销条件包括 macOS 15.6、其它缩放硬件、完整 App 帧／系统候选、
  全部布局／隐藏编辑组合、输出预算与 Staged 交叉快照、长期内存和底层 IO 取消；
  具体缺口及替代证据见 `evidence-p1.md#尚未核销的验收`，均未被全量宿主绿色豁免。
- 当前长期文档只纠正 `docs/features/diff.md` 的宿主／E2E 实际边界；
  实验数值、失败与当前任务状态只保留在本 feature，不复制到产品能力保证。

## 2026-11-06 复审：研究阶段交付与生产门禁

此前的 No-Go 是 2026-11-05 原始审计结论，并未随 GUI／SSH 与新实验自动变绿。
本次重新读取当前 CodeGraph、`idea.md`、P1／P2／P3／P4 和原始日志：
`todo.toml` 现已把 P1-T1 至 T6 逐项记录为完成，
这是**研究／可复现证据完成**，不是 Git Diff 性能修复完成。

- P1-T1：1k／24k／100k Staged、Unstaged Debug／Release
  模型／原生／组件像素各 30 次热态，真实状态事件
  1／100／10k 项各 30 次；GUI 已实测 29／29 与新版本
  16／15 次有效 Split 冷窗口，帧率 5–7 FPS，只能报采样上下界。
  5 MiB±1、20 标签宿主内存及关闭后的进程／布局所有权有原始日志。
- P1-T2：全篇原生布局替代方案明确 **No-Go**：
  4/17 直接滚动正确，17/17 原生重定位路线在 100k 最慢约 310 ms；
  跳过折叠隐藏元素仅是局部有益原型，不等于完整正确方案。
  F-01 转 P2-T1 的入口验证，禁止跳过几何 Gate 进入产品。
- P1-T3：生产 Find 菜单转发及原生编辑事件已按旧任务独立提交，
  覆盖隐藏原文字节、Undo／Redo／保存。仍有完整 App 中文候选、
  跨隐藏 Find 选区等 P2-T3／P4-T2 验收。
- P1-T4：串行 size＋blob 与 batch 约 47／19 ms，
  Git 输出后截断、交错 HEAD／Index 虚假 Diff、取消后 Git 子进程残留、
  400-token 行内投影与逐次语法全文对比均有可复现反例；
  F-02 属 P3-T1／T2／T3／T4 的生产修复责任，不凭实验绿灯销账。
- P1-T5：上述决策与现行输入/视口预算已经在 `idea.md` 冻结，
  P2 的不正确几何快路径明确禁止，P3 的 Git 正确性优先于小幅优化。
- P1-T6：仅有测试消费方的生产语法高亮旧入口已删除，
  独立测试 oracle 仍保留，提交 `8ce6d0da`。
  `afterGitAction`／`hasCollapsedContext`／旧 Review/Edit 已不存在，
  `showsCanonicalComparison`／OID／保存／symlink 保护仍有真实消费者。

最新独立 `make build` + 严格验签退出 0；`make test`
实际 **856 项，16 项远端条件跳过、0 失败，退出 0**，
日志 `build/git-diff-p1-current-head-{make-build,full-host}.log`。
`WorkspaceGitUITests` 已在授权 Windows SSH 的隔离 Bailey Dev
实测 7 项、0 跳过、0 失败；
`GitRemoteRefreshIntegrationTests` 真实 Windows 3 项均通过。
这两组单独证据不补齐本机未注入 SSH 的 16 项跳过，
也不证明精确 WindowServer 首像素和真实物理断线。

## Gate（是否允许进入下一阶段）

- 历史（2026-11-05）：`No-Go`，当时 GUI 初始化失败、准入证据不足。
- 当前（2026-11-06）：`Go`，**只表示 P1 技术调查与后续依赖已
  如实收敛，可执行下一阶段中独立于几何方案的任务**。
  生产首屏几何方案仍单独为 **No-Go**：P2-T1 必须先用单一原生
  TextKit 布局所有者验证 17 次真实远跳、100k 视口性能、
  首次完整滑块、尾行与 Ghost；通过前不得删除 `ensureLayout(documentRange)`，
  不能宣称 P2/P3/P4 完成。
- F-01／F-02／F-03 均属于**明确后移但不可豁免**的生产及 E2E Gate，
  实验结果不足以改成 Resolved；其风险和补验已写在各 finding 证据。
  P2-T2／T3 可依独立原生事件 Go 证据实施；
  其它任务也必须遵守各自前置条件、Red→Green 与最终副作用。

## 最终状态与剩余风险

- P1 探索：完成。F-04／F-05 已解决，F-01／F-02／F-03 已归属后续
  真实实现与完整 App 验收；P2 的布局首屏不是已完成结果。
- 主要未验收：快速且准确的 TextKit 全条件几何；
  大仓密集差异的及时取消与完整内存归因；
  真实 GUI 首像素／可输入高帧率测量、完整中文候选及物理 SSH 断线。
  macOS 15.6 未实机测试，只维护最低部署目标。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
