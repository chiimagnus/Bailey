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
- 状态：`Open`
- 位置：`Makefile:27`
- 摘要：`GUI枚举持续返回零项，完整App首帧和键盘基线没有获得`
- 风险：`组件像素不能代替WindowServer首帧或真实Command-S，无法冻结完整用户路径预算`
- 预期修复：`保存实际枚举JSON、Runner采样与testmanager日志，解决测试发现或外部授权环境后再核销GUI`
- 验证：`make build:ui；make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-02

- 任务：`P1-T4`
- 严重级别：`High`
- 状态：`Open`
- 位置：`Bailey/Git/DiffEngine.swift:819`
- 摘要：`密集行内投影已实证为热点，但取消及完整分配归因尚未核销`
- 风险：`399/400 token、1000 对替换投影约37秒，稀疏样本不能支持生产阶段忽略此路径`
- 预期修复：`补齐共享token、取消时延和分配测量，将经验证的最小词级算法修复纳入P3-T3`
- 验证：`make test ONLY_TESTING=BaileyTests/DiffEngineTests/testDenseIntralineProjectionTokenBoundaryCosts；追加真实取消测量`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`Bailey/Git/DiffTextView.swift:1535`
- 摘要：`尚无满足全条件的原生布局技术准入证据`
- 风险：`直接移除全文布局可能导致错误几何，现有替代原型也未证明折叠首屏和热滚动达标`
- 预期修复：`继续单一 TextKit 布局所有者实验，校正视口内真实行与尾行断言，取得准入前保留生产保护路径`
- 验证：`复验 evidence-p1.md 中的原型补丁及原生滚动矩阵`
- 解决证据：`<commit diff note or test/build output>`


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

## Gate（是否允许进入下一阶段）

- 结论：`No-Go`
- 理由：P1 的真实 GUI 基线与全条件原生几何路线尚未建立，隐藏编辑、分配和快照反例等也未全部核销，不能冻结预算或进入 P2／P3。

## 最终状态与剩余风险

- 当前状态：`Open`
- 剩余风险：F-01／F-02／F-03 仍阻塞准入；F-04／F-05 已按实际文档与完整宿主证据解决。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
