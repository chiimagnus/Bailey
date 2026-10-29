# Audit P3 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 统一 Git Changes 状态与 Diff 打开路径
- [x] P3-T2 统一 Git Graph 展开浏览和菜单目标
- [x] P3-T3 实现 Git Changes 资源多选与批量动作
- [x] P3-T4 对齐 Git Graph 提交详情与键盘导航
- [x] P3-T5 对齐 Git Graph 轨道颜色与视觉状态
- [x] P3-T6 复核 Git Graph 引用菜单与危险操作
- [x] P3-T7 统一 Git Graph/Changes 分页刷新与身份恢复

## 任务到文件的映射

- P3-T1 · `7385e1cc`
  - `Bailey/Git/GitPanel.swift`、`GitStatusModel.swift`：游标、选择与活动 Dock Diff 交接；
    `BaileyUITests/Git/GitChangesUITests.swift`：选中与预览的真实 GUI；
    `docs/features/git.md`、`docs/ui.md`。
- P3-T2 · `a6f3c6ec`
  - `GitPanel.swift`、`GitStatusModel.swift`：模型持有展开集合和项目身份；
    `GitStatusModelTests.swift`、`GitGraphUITests.swift`：展开重挂载与不同项目；
    `docs/features/git.md`。
- P3-T3 · `fbf59fea`
  - `GitPanel.swift`、`GitStatusModel.swift`：多资源身份、Shift/Command 选择、
    目录与合法 Section 过滤、批量 Git 写入；
    `GitStatusModelTests.swift`、`GitChangesUITests.swift`：index/文件字节；
    `docs/features/git.md`、`docs/ui.md`。
- P3-T4 · `d6f66e9a`
  - `RecentCommitsView.swift`、`GitStatusModel.swift`、`GitPanel.swift`：
    父子导航、历史只读 Diff 与焦点隔离；
    `GitStatusModelTests.swift`、`GitGraphUITests.swift`、`GitHistoryUITests.swift`；
    `Resources/Localization/Git.xcstrings`、`docs/features/git.md`、`docs/features/diff.md`。
- P3-T5 · `ccd790ae`
  - `RecentCommitsView.swift`：窄幅 Stash AX；
    `GitGraphGeometryUITests.swift`：真实 DAG/徽章/背景像素验收；
    `docs/features/git.md`、`docs/ui.md`。
- P3-T6 · `081167df`
  - `GitPanel.swift`、`GitStatusModel.swift`、`RecentCommitsView.swift`、
    `BottomToolbarView.swift`：原始 Tag/Stash/Branch OID、窗口／仓库绑定、执行时复验；
    `GitBranchActionTests.swift`、`GitStashActionTests.swift`、
    `GitStatusModelTests.swift`、`GitTagActionTests.swift`、
    `GitDialogUITests.swift`；`docs/features/git.md`。
- P3-T7 · `5ca1a2c6`
  - `Bailey/UI/Panels/ToolPanelView.swift`：GitPanel 仅随项目 ID／SSH 连接身份换代；
    `GitGraphUITests.swift`：同 Git 仓库跨两个 Project 的展开隔离；
    `docs/features/git.md`。

## 逐提交核对

| 任务 / 提交 | 实际消费链 | 审计判断 |
| --- | --- | --- |
| P3-T1 `7385e1cc` | Dock 活动内容 → `GitPanel.revealActiveChange` → `GitStatusModel.changeCursor/selectedChanges` → Changes 行选择；移除旧 Displayed 灰底 | 已接入；未发现残余单项选择写入 |
| P3-T2 `a6f3c6ec` | `GitPanel` 的展开 Binding → `GitStatusModel.expandedCommitIDs` → `RecentCommitsView`；项目/仓库失效时清理 | 已接入；展开与键盘游标所有者不同 |
| P3-T3 `fbf59fea` | Shift/Command/右键 → 仓库、Section、路径约束的选择集合 → `selectedEntries` → 单次 `stageEntries/unstageEntries` 或确认 Discard | 已接入；无需恢复 `explicitlySelectedChange` |
| P3-T4 `d6f66e9a` | Graph 点击与 ⌘方向键 → 有效 DAG 目标 → 提交详情与历史文件 Diff | 已接入；真实 Git SHA 与原生焦点分离 |
| P3-T5 `ccd790ae` | Stash 徽章 AX 标签 → 原生 Graph 行；像素/轨道断言在 `GitGraphGeometryUITests` | 已接入；没有引入重复视觉模型 |
| P3-T6 `081167df` | 原生菜单、Tag、Stash、Branch OID → `GitStatusModel.perform` 执行前复核 → 真实 Git | 原始 OID 防护已接入；但工具栏保存旁路和跨窗编辑保护有证实缺口（F-02/F-03） |
| P3-T7 `5ca1a2c6` | `WorkspaceDockView` → `ToolPanelView` 的 Project Identity/SSH 代次 → GitPanel/Graph 局部游标生命周期 | 已接入；普通刷新与真实切换不混同 |

未发现 P3 新增的平行 Git 后端、独立 Git SelectionStore 或重复 Graph 展开真源。
目前仅删除经调用方逐一核对已被跨窗口保存入口取代的旧 `Project` Git 保存／重载链。
真正执行危险操作所需的 Ref OID、目标身份和工作区编辑保护不能当作冗余围栏删除。

## 发现项

## 发现 F-06

- 任务：`P3-T5`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`BaileyUITests/Git/GitGraphUITests.swift:940-990`
- 摘要：`Graph 双轨颜色测试使用全像素最小差值，抗锯齿边缘导致两条正确配色被误判为相同`
- 风险：`完整 93 项 GUI 回归中只此断言失败，0.250 的最小 RGB 和值不代表两个节点的主体颜色；生产调色板的唯一颜色约束与该 0.30 门槛不一致`
- 预期修复：`读取真实节点截图中占比最高的彩色像素作为代表色，以生产调色板的最大通道差异语义验证颜色区分，不修改产品配色`
- 验证：`先前 93 项 GUI 实跑 92/93，颜色测试 RGB=0.2500536 失败；make test:ui ONLY_TESTING=BaileyUITests/GitGraphUITests/testTwoRealBranchLanesPaintMatchingReferenceBadgesAndGraphNodes 复测 1/1，通过，RGB 每个 badge-node 差值 0；git diff HEAD --check`
- 解决证据：`2026-10-29 下午完整 Bailey-UI 93 项中该项独败，失败源于所有彩色像素跨节点求最小 RGB 差（抗锯齿伪接近）。按截图内占比最高的真实节点彩色像素比较 RGB 最大通道差；未调整产品调色板；18:20 make test:ui 定向复验 1/1 passed (17.948s)，两个 badge-node RGB delta 均为 0。`


## 发现 F-05

- 任务：`P3-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitPanel.swift:173-235, Bailey/Git/GitStatusModel.swift:1314-1359`
- 摘要：`Git Changes 单项与批量 Discard 确认直接执行 Git 还原或删除，未保护其它已打开且未保存的编辑`
- 风险：`用户在另一窗口/Project 持有脏编辑，确认 Discard 后磁盘或 Git index 已改变，但旧缓冲仍可自动保存覆盖已丢弃的结果；remote 永久删除也未保护编辑写入`
- 预期修复：`沿复用的 WorkspaceApplication 文件操作协调在 Discard 确认时保护受影响的真实文件，保存/复验原快照、执行后重载或失效；不替换 GitStatusModel 已有指纹校验/本机 Trash 与远程删除语义`
- 验证：`通过独立 Git/FileTab 多窗口未保存内容 Red-Green；本机单项/批量、多路径/冲突和 SSH 断连；GitChangesUITests、GitStatusModelTests、make build:dev`
- 解决证据：`Discard 在 WorkspaceApplication.withProtectedFiles 下执行至异步 Git 完成；跨窗脏编辑、指纹陈旧、无关草稿及 index/文件实际字节宿主专项通过；Staged Diff 路径刷新回归 Red→Green；Git 多选 Discard 取消/确认/未选文件真实 Bailey Dev E2E 1/1 通过（25.599s）；Windows SSH 断线恢复专项 1/1 通过；构建通过。远端原生 Discard GUI 不在已完成样本中，仍须阶段覆盖核对。`


## 发现 F-04

- 任务：`P3-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitStatusModel.swift:1384-1386,1407-1409`
- 摘要：`旧版 stage/unstage 单文件转发不再被 Bailey 生产代码调用，仅剩测试依赖`
- 风险：`无生产调用的双轨入口遮蔽实际生产 Stage/Unstage 批量操作的测试覆盖，并增加冗余 API`
- 预期修复：`删除两个单项包装方法；将原宿主与 SSH 测试调用替换为同一批量方法，保留所有原断言`
- 验证：`rg -n "\.stage\(|\.unstage\(" Bailey BaileyTests; make test:GitStatusModelTests,GitWorkspaceActionTests; git diff --check`
- 解决证据：`删除单项 stage/unstage 包装并迁移所有测试；rg 搜索 Bailey 和 BaileyTests 中旧入口调用为 0；GitStatusModelTests/GitWorkspaceActionTests 等八类宿主 175/175 通过；git diff --check 通过。`


## 发现 F-03

- 任务：`P3-T6`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:155-205, Bailey/App/WorkspaceApplication.swift:182-240, Bailey/Git/GitPanel.swift:620-1435`
- 摘要：`Git 工作树变更操作仅保护当前 Project，遗漏其它窗口或其它 Project 中打开的同仓库编辑`
- 风险：`两个 Bailey 窗口可同时打开同一仓库；窗口 A 执行 Checkout/Reset/Branch 切换时窗口 B 的未保存文本未被纳入保存或冲突检查，切换后 B 的旧缓冲可能覆盖新分支文件`
- 预期修复：`复用 WorkspaceApplication 已有跨窗口文件操作保护，统一 Git 变更前的同仓库编辑保存/冲突识别、操作后全部受影响窗口重载；删除只保护单个 Project 的重复入口`
- 验证：`两个窗口同仓库不同及同名脏编辑的真实临时 Git/FileTab 宿主测试；分支切换、文件重载、拒绝覆盖、跨仓库不串扰、Git 危险菜单与构建回归`
- 解决证据：`跨窗口/跨 Project 已改由 WorkspaceApplication 统一保护；GitBranchActionTests、WindowOwnershipIntegrationTests 等八类宿主 175/175 通过，跨窗口 Git 原生 Sheet GUI 1/1 通过（38.915s）；make build:dev 通过。`


## 发现 F-02

- 任务：`P3-T6`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/Components/BottomToolbarView.swift:284-291, Bailey/Git/GitPanel.swift:594-616`
- 摘要：`底部工具栏切换分支绕过 GitPanel 的保存编辑和操作后重载保护`
- 风险：`有未保存文件或 Diff 时，底部工具栏直接调用 model.switchBranch 且 prepare 默认为 nil；Git 可切换工作区，编辑缓冲仍指向旧版本，后续自动保存可能覆盖新分支内容，且未校验原窗口/项目`
- 预期修复：`将分支切换的窗口/项目/保存/重载事务收敛到已存在的窗口所有者单一入口；GitPanel 与底部工具栏统一复用，保留 OID 实时复核`
- 验证：`新增真实隔离 Git 与脏 File/ Diff 的宿主 Red-Green（取消保存不切换、可保存先保存再切换、后续重载）；受影响 Branch/Editor 宿主及 Bailey Dev 工具栏原生 GUI；make build:dev`
- 解决证据：`统一 WorkspaceWindowModel.switchGitBranch；GitBranchActionTests 等受影响宿主八类 175/175 通过；Bailey Dev 底部工具栏真实分支切换 GUI 1/1 通过（16.122s）；make build:dev 通过。`


## 发现 F-01

- 任务：`P3-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`plan-p3.md:59-70,184-190`
- 摘要：`执行完成后的现行 P3 计划仍把已删除的单项 Git Selection 与 Displayed 字段写成当前源码状态`
- 风险：`下一次维护按已不存在的字段复核、误建兼容分支，和 todo 已完成状态产生时间语义混淆`
- 预期修复：`仅在 P3 计划入口澄清“当前/旧”的执行前基线语义，保留历史问题与任务细节，不重写已验证计划`
- 验证：`rg -n "explicitlySelectedChange|isDisplayedChange" Bailey/Git; python3 feature_tool.py todo validate .github/features/interaction-state-architecture; git diff --check`
- 解决证据：`plan-p3.md 入口已写明当前/旧字段为 P3 实施前基线；rg -l explicitlySelectedChange/isDisplayedChange Bailey/Git 无命中；todo validate 与 git diff --check 通过。用户本轮明确要求提交全部 Git Changes，阶段资料独立提交。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- **F-01：** `plan-p3.md` 入口注明旧字段属于 P3 执行前源码；
  当前 Git 源码已移除 `explicitlySelectedChange` 和 `isDisplayedChange`，记录为 Resolved。
- **F-02：** 删除底部工具栏直接调用 `GitStatusModel.switchBranch` 的旁路。
  `GitPanel` 和 `BottomToolbarView` 均通过 `WorkspaceWindowModel.switchGitBranch`
  进入同一个保存、实时 Ref 复核、切换和重载流程。
- **F-03：** 删除 `Project` 内仅扫描当前 Project 的重复 Git 编辑保护。
  将相关编辑的枚举、保存、冲突拒绝与重载移入既有 `WorkspaceApplication` 注册窗口集合；
  复用 Files 的同路径脏草稿冲突判断，不另建项目或 Git 后端状态。
  GitPanel 的 Checkout、重置、Stash、历史文件、Remote Checkout 等现有写入口均改用它。
  修复提交为 `1d136d40`，已按独立 Git index 重核 11 个代码/测试/文档文件。
  Discard 的后续独立审计修复不属于此提交。
- **F-04：** 删除 GitStatusModel 单文件 Stage/Unstage 转发，测试统一使用真实批量 API，
  全仓调用检查无旧入口残留。
- **F-05：** Discard 确认后在 WorkspaceApplication 的跨窗口文件修改事务中
  先保存、重新核对确认指纹，直到 Git 完成才释放写入；
  按真实路径重载干净的文件、Worktree Diff 和 Staged Diff。
  暂存区 Diff 路径过滤曾有可复现遗漏，已完成针对性 Red→Green。
  修复与旧 Stage/Unstage 转发清理提交为 `10500d41`。
- **F-06：** Graph 原生颜色断言不再把节点抗锯齿边缘的最小像素差当作
  两条轨道的主体色差；改用实际截图中出现频率最高的节点彩色像素，
  按调色板的最大通道距离校验。
  与工具栏、历史 Diff 原生验收前提修正一起提交为 `7c501d31`。

## 验证日志

- **Git 命令前提：** 在临时仓库制作 main/feature 同路径不同版本，确认
  未提交的冲突工作区内容令 `git switch` 拒绝，恢复基线后可切换；
  最终分支名和文件字节均符合预期，临时仓库已清理。
- **受影响主机测试：** 新增真实 `GitBranchActionTests`，
  检查已打开文件的先保存、失败不切换、成功后重载；
  另测第二窗口草稿与同一文件两份互相冲突草稿。
  旧 `FileTabPersistenceTests` 和 `NativeGitHistoryFileTests`
  已迁移到应用级唯一保存入口，保留异步保存失败及真实历史重置断言。
- **构建：** `make build:dev` 退出码 0，`BUILD SUCCEEDED`，
  Development 签名和 `codesign --verify` 成功；
  `make build:ui` 退出码 0，`TEST BUILD SUCCEEDED`，新 GUI 用例已编译。
  现有 `@Entry` 闭包可比性诊断属于原有 warning，不属于本阶段提交。
  共享工作区并行修改后仍需对最后代码状态做最终回归。
- **宿主运行器：** `make test:GitBranchActionTests,FileTabPersistenceTests,NativeGitHistoryFileTests,WindowOwnershipIntegrationTests`
  完成编译，但 XCTest App 在 `_prepareTestConfigurationAndIDESession` 等待 IDE 会话建立，
  没有进入测试方法；采样两轮一致。本轮独立结束其进程后又尝试
  `make test:GitBranchActionTests`，期间与另一 AI 未完成的
  `GitStatusModel.swift` 参数签名修改交错导致编译失败。
  两者均不能视作产品断言失败，也不能冒充通过。
  临时签名重测 `make test:GitBranchActionTests SIGNING=adhoc` 同样停在
  `_prepareTestConfigurationAndIDESession`，确认后结束本轮测试及隔离 Dev 进程。
- **GUI 阶段回归：** P3 的五个原生测试类共执行 92 项，70 通过、22 未通过：
  1 项在 Graph 点击时 XCTest 与 App 连接丢失；后续 21 项启动时
  直接报 `Not authorized for performing UI testing actions`。
  没有将权限/会话问题冒充 Git 功能失败，也不能将本批次记为通过。
- **环境：** 真实 macOS / Xcode-beta / Bailey Dev；
  独立本机 Git 覆盖普通、脏文件、重名分区、多个窗口、中文路径、
  暂存、冲突、Stash、Tag、Graph 多父、分页与历史二进制；
  T6 前轮有 2 项需 `BAILEY_P4_TEST_SSH_HOST` 的 Windows SSH 专用测试被跳过，
  不能由模拟 SSH 替代实机断线/重连验收。
- **文档和老代码：** `docs/features/git.md` 同步底部工具栏与跨窗口保护；
  当前源码无被 T3 取代的旧单项 Selection、重复 Displayed 高亮或 P3 的第二套 Git 操作后端。
  测试和 `git diff HEAD --check` 需在所有并行修改稳定后再次核销。

### 2026-10-29 审计复验

- `make build:dev` 通过，Development 签名成功；
  八类受影响宿主测试 `make test:GitStatusModelTests,GitWorkspaceActionTests,GitBranchActionTests,FileTabPersistenceTests,NativeGitHistoryFileTests,WindowOwnershipIntegrationTests,GitStashActionTests,GitTagActionTests`
  共 **175/175 通过**；该批次之前的 1 项新测试夹具误删 `git status --porcelain` 前导状态空格，已修复并复测。
- Staged Diff 定向重载新测试在缺陷代码下失败，修正后通过；
  Discard 其它窗口脏文件、确认后保存、旧确认失效、无关文件保留及实际 Git/文件字节断言通过。
- Bailey Dev 专项 GUI：批量 Discard 确认／取消与实际未选文件通过；
  Graph 提交双端只读 Diff、Git 多选与 Stage、同仓库 Project 切换失效、
  跨窗口 Git Sheet、轨道视觉、底部工具栏分支切换等均通过。
  Graph 旧测试误把 Unified 默认显示当成双 TextView，已显式切至 Split；
  底栏旧测试未启用默认隐藏的工具栏，已在隔离配置中打开。
- 授权测试主机 `windows`：
  `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHGitRecoveryLiveTests`
  **1/1 通过**，验证 SSH 传输失效时拒绝写入和恢复后重试。
- 先前 92 项 GUI 批次中的授权错误属于历史证据。
  五类 Git 原生 GUI **93 项完整复验**已于 16:03 结束：
  92 项通过，1 项 Graph 轨道颜色断言失败；失败仅发生在
  `GitGraphUITests.testTwoRealBranchLanesPaintMatchingReferenceBadgesAndGraphNodes`，
  其旧断言把两个节点的抗锯齿像素最小 RGB 和差当成主体色差（实际为 0.250，
  小于人为的 0.300 门槛）。
- 18:20 在**未修改生产代码**的情况下修正测试取样，执行
  `make test:ui ONLY_TESTING='BaileyUITests/GitGraphUITests/testTwoRealBranchLanesPaintMatchingReferenceBadgesAndGraphNodes'`，
  退出码 0，**1/1 通过（17.948s）**。两个分支的徽章与对应节点色差均为 0。
  因此 93 个适用 GUI 用例均有最终通过证据；
  **不是声称单次完整批次 93/93 全绿**。
- Git 代码在下午完整 GUI 批次前已稳定，随后只修正原生测试断言。
  当前 Dev App 重新验签通过，Bundle ID 为 `chiimagnus.bailey.dev`；
  `git diff HEAD --check` 与 `todo validate` 通过。
  F-02/F-03 修复提交 `1d136d40`，F-04/F-05 提交 `10500d41`，
  F-06 及 GUI 夹具修正提交 `7c501d31`。
- Windows SSH 实机测试验证断连、状态恢复及 Stage/Unstage；
  **未执行 Windows SSH 远端 Discard 的完整原生 GUI 永久删除流程**。
  该入口的远端预确认/文件指纹/失效拒绝已由
  `GitStatusModelTests` 的受控 SSH backend 验证，
  不将它说成实机 GUI 证据。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（P3 审计通过）
- 理由：7/7 项原计划已实施，F-01～F-06 均核销；
  宿主 175/175 与授权 SSH 1/1 通过；
  完整 GUI 其余 92 项通过、唯一颜色断言修复后定向 1/1 通过；
  构建、签名和代码修复提交均完成。
  远端永久删除原生 GUI 未执行的范围明确保留，不冒充全平台零风险。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：远端 Discard 的真实 Windows SSH 完整 GUI 删除尚无直接端到端证据，
  但受控 SSH 后端及实机连接失效测试已覆盖相关边界。
  本次未推送、未发布，也未触碰正式 Bailey 运行实例。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
