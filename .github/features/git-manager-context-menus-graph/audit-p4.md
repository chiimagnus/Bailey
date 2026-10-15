# Audit P4 - git-manager-context-menus-graph

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/git-manager-context-menus-graph/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 Commit Checkout、Cherry-pick、Revert、Merge 与冲突恢复
- [x] P4-T2 Commit Rebase、Reset 三模式及条件 Drop
- [x] P4-T3 当前与其他本地分支管理菜单
- [x] P4-T4 远端分支 Checkout、Fetch、Pull 与删除
- [x] P4-T5 Tag 注释与本地及远端管理
- [x] P4-T6 历史文件修订、比较与打开菜单
- [x] P4-T7 工作区文件、目录与分组右键菜单
- [x] P4-T8 具体 Stash 的选择与 Apply、Pop、Drop、Branch
- [x] P4-T9 全对象菜单与本机及真实 SSH 用户路径验收

## 任务到文件的映射

- P4-T1
  - `GitPanel.presentCommitDialog` → `GitCommitDialog` → `GitStatusModel.actOnCommit/perform` → `GitCommandExecution`；`Project.saveBeforeGitAction/reloadAfterGitAction`；`GitCommitActionTests/GitCommitDialogTests`；Git/UI/Settings 文档。
- P4-T2
  - 同一 Commit 执行链与 `Project.newInteractiveGitSession` → 原生 PTY；Drop 拓扑、Reset 模式；`GitInteractiveRebaseTests`（本机与真实 Windows）；Git/Terminal/SSH 文档。
- P4-T3
  - `RecentCommitsView.referenceActions`（直显和 +N）→ `GitPanel.presentBranchAction` → `GitBranchDialog` → Model Branch/Archive 方法；`GitBranchActionTests/GitBranchDialogTests`；Git/UI 文档。
- P4-T4
  - `presentRemoteBranchAction/presentRemoteCheckoutDialog` → Model Remote 方法，`remoteBranch` 最长 remote 前缀及 symref 分类；`GitRemoteBranchActionTests`；Git/SSH 文档。
- P4-T5
  - `GitTagDialog`、`presentTagCreate/presentTagAction/presentTagPushWarning` → Model Tag/Archive；`GitTagActionTests/GitTagDialogTests`；Git/Settings/UI 文档。
- P4-T6
  - `RecentCommitsView.changedFile` → `handleHistoricalFile` → `Project` 普通 FileTab 或同一 DiffTab；`GitHistoricalFileLocator`、`DiffNativeSurface`、Source/SessionStore 往返；`GitHistoryFileTests/DiffTabTests/SessionStoreTests`；Git/Diff/Files/Editor/Session Restore 文档。
- P4-T7
  - `PanelSectionHeader.menuActions`、目录原分组批量操作、`GitEntryRow.menu` → `GitUncommittedDialog`/Model；`Project.ignoreGitPaths` → FileTab 已有读取与串行保存/TextKit 插入；`GitUncommittedActionTests/GitWorkspaceActionTests/GitWorkspaceMenuTests/FileTabTests`；Git/Files/Editor/UI 文档。
- P4-T8
  - 同一 StatusResult 的 `stash list -z`、派生数量、STASHES 原生行 → `GitStashDialog/actOnStash` → 同一 perform；`GitStashActionTests/GitStashDialogTests`；Git/UI 文档。
- P4-T9
  - `GitWorkspaceSSHTests` 专用 Windows master/远端临时库、`TreeRowHitTestingTests`、`RecentCommitsViewTests` 原生菜单解析；隔离 App PID75571→23842→28904→551→3581→10883→15033 的真实菜单、确认与本机/SSH 持久结果见 `evidence-p4.md`。只有这些已核对身份的测试进程被操作；用户 PID40825 与后来无隔离参数的3361未退出或重启。
  - 审计补充：`GitRefReplacementTests`、`GitRemoteBranchDialogTests`、`GitHistoryFileTests`、`FileTabTests`，分别核对原生确认期间的Ref/目标变化、只读AX边界和被挂载替换的实际读任务；归属仍回各原task，不增加第二套状态或执行器。

## 发现项

## 发现 F-24

- 任务：`P4-T8`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Git/RecentCommitsView.swift:292`
- 摘要：`实际隔离 App 窄 Git 侧栏中 Stash 徽标把 stash@{0} 截断成 stash...，仅 AX 和帮助信息能读到完整 selector`
- 风险：`存在多条储藏时无法在图谱中直接区分 stash@{0}、stash@{1} 等身份标签，不符合显示具体 Stash 的产品目标`
- 预期修复：`让 Stash 标签的文本采用内在完整宽度，优先压缩前方可横向滚动的提交标题，不新增宽度状态或独立布局`
- 验证：`原生 RecentCommitsViewTests、隔离 Kero 真实窄侧栏截图、make test、make build 和严格验签`
- 解决证据：`42bbb53：RecentCommitsView.stashBadge 将 selector 文本改成固定内在水平尺寸，允许前方提交标题独立缩短/滚动，去掉 stash... 错误省略。隔离独立 Kero 窄侧栏之前截图 /tmp/kero-graph-isolated-git.png 对照之后 /tmp/kero-stash-graph-badge-after.png 看到完整 stash@{0}；原生图谱 RecentCommitsViewTests 11/11，最新真实 Windows SSH 全量 234/234，make build/codesign 全过。`


## 发现 F-23

- 任务：`P4-T8`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1593; kero/Git/RecentCommitsView.swift:99`
- 摘要：`已完成的 Issue #2 要求参考 VS Code Git Graph；上游 d7f43f4 真实将 Stash 插入 Git DAG 并连接其基础提交，但 Kero 的 P4 计划主观排除 Stash 并单独创建 STASHES 区域，未满足更新后的用户需求`
- 风险：`Stash 与原始提交缺乏拓扑关系，无法像 Git Graph 在图谱里观察每条储藏及其变化历史；同 SHA 多条记录仍需准确分别可操作`
- 预期修复：`采用 Git Graph 的单父可视化策略，整合 GitStatusModel Stash 身份与 RecentCommitsView/CommitGraphLayout，删除独立 STASHES 分组及失效计划描述；保留原有 Stash 互斥与弹窗语义，必要时惰性读取变更`
- 验证：`GitStashActionTests、RecentCommitsViewTests、CommitGraphLayoutTests、GitStatusModelTests、真实 Git 临时仓库与实际本机/Windows SSH make test、make build；启动隔离 App 检查图谱 Stash 节点及右键`
- 解决证据：`42bbb53；Git Graph 上游 d7f43f4 的 src/dataSource.ts 真实读取 Stash 并以基础提交作单父可视化，Kero 复用现有 graphCommits/CommitGraphLayout、移除独立 STASHES；同 OID 不同 selector 多节点、无基础提交时不画虚线、第三父未跟踪差异、原右键身份保护专项全部通过。隔离 Kero 完整 App 的图谱关系线/展开 src/conflict.txt/原生 Diff/Apply Pop Drop Branch 右键经截图与 Git blob 对照。最终真实 Windows SSH 全量 /tmp/kero-stash-graph-badge-final-full-windows.log 234/234、0失败、0跳过；make build 严格验签，最终安装哈希对照通过。`


## 发现 F-22

- 任务：`P4-T8`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1824`
- 摘要：`STASHES 只是上下文菜单行却启用 SwiftUI 默认焦点描边，鼠标交互留下主题色选中外框，与共享树行的 Hover/Focussed 浅底样式不一致`
- 风险：`点击/键盘聚焦时出现多余强调色外框，容易误解为持续选中某条 Stash`
- 预期修复：`保留原生可聚焦及 AX 上下文操作，禁止额外系统焦点描边，复用 TreeRowSurface 原有聚焦背景`
- 验证：`原生侧栏焦点与菜单访问回归；make test；make build；正式 App 重启后实测样式`
- 解决证据：`42bbb53：独立 STASHES/stashRow/@FocusState 删除，Stash 改为正式 Git 图谱节点，无原来专属的额外默认焦点描边；隔离完整 Kero App 右键图谱 Stash、视觉验收通过，RecentCommitsViewTests 11/11、最终真实 Windows SSH 234/234、严格 build/codesign 通过。正式运行 PID52207 没重启，未谎称现有用户进程已切换。`


## 发现 F-21

- 任务：`P4-T8`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:2099`
- 摘要：`Stash Pop/Drop/Branch 只用 selector 当前 OID 验证旧菜单；同 OID 不同 reflog 记录在外部插入后可使旧 selector 错指另一条记录且 OID 比对依然通过`
- 风险：`用户确认删除或弹出 stash@{1} 的旧记录，实际删除另一条同 SHA 的 stash reflog，违反精确选择和已知身份保护`
- 预期修复：`复用现有 stash list 快照及 parser，确认打开时捕获列表，在首个 Git 写入前重新读取整个 reflog 列表并验证不变，取代不足以辨认条目的单 OID 检查；Apply 固定 OID 保持不变`
- 验证：`真实 Git stash store 同 SHA 经中间项 drop 得到相邻重复记录，外部插入后原 selector OID 不变却指向另一条；GitStashActionTests Red-Green、NativeUI 相邻测试、完整 Windows SSH make test 和 build`
- 解决证据：`7c7ddc6；真实同 SHA 不同 stash reflog 条目挤占 selector、旧 Git drop 错删 Red (/tmp/kero-p4-f21-red.log)；整列表快照执行前复验后 GitStashActionTests 10/10、GitStatusModelTests 10/10、GitStashDialogTests 2/2 Green。`


## 发现 F-20

- 任务：`P4-T7`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:512`
- 摘要：`Git 文件行的 isCurrent 只按仓库路径检查，外部 CLI 切分支并刷新后，旧 CHANGES 行仍能 Stage 新分支的同名文件`
- 风险：`过期右键与延迟回调将另一分支文件加入 index，可能影响随后的提交或 Revert/Discard 决策，违背菜单目标身份绑定`
- 预期修复：`让 Git status Entry 在快照发布时携带本次分支和 HEAD 身份，在现有 isCurrent/validate 最小公共位置校验，拒绝跨分支/HEAD 的旧行，不加新的状态机`
- 验证：`真实仓库 main→other 的旧行 Stage Red-Green、相邻 GitWorkspaceActionTests 和 GitStatusModelTests、Windows SSH 完整测试与构建`
- 解决证据：`f4f8cc0；旧文件行 main→other Stage 实际误写 index 测试 Red；修复共享 isCurrent(entry) 后 GitWorkspaceActionTests 5/5 与 GitStatusModelTests 10/10 Green；旧测试更新为显式拒绝过期行并允许重新选择当前行。`


## 发现 F-19

- 任务：`P4-T7`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:2907`
- 摘要：`Porcelain v2 同路径既有 staged 删除 D. 又有 untracked ?? 时，parseStatus 仅按 path 去重，吞掉未跟踪文件 CHANGES 行和对应 Ignore 菜单`
- 风险：`git rm --cached 后磁盘仍在的文件在未跟踪分组中消失，不能从 P4 文件右键忽略，Stage/Discard 操作分组丢失`
- 预期修复：`按 Git 状态所在分组保留同路径的 staged 与 untracked 两条记录；各组 path 身份仍唯一，不新增第二套 Git 状态来源`
- 验证：`真实 git rm --cached 仓库 status porcelain 对照；GitStatusModelTests 或 GitWorkspaceActionTests Red-Green；原生 Git CHANGES 菜单、make test、make build`
- 解决证据：`f4f8cc0；真实 git rm --cached 得到 D. 与 ? 同名两条 NUL 状态；/tmp/kero-p4-deeper-red-GitWorkspaceActionTests.log Red、/tmp/kero-p4-deeper-green2-GitWorkspaceActionTests.log 5/5 Green。`


## 发现 F-18

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:2150`
- 摘要：`Squash Merge 成功后使用全索引 diff --cached 断言并执行普通 git commit，导致预先暂存的无关文件被误提交，甚至 already up to date 时也能产生非预期提交；Remote Pull Squash 同受影响`
- 风险：`改变与所选 Merge/Pull 无关的用户暂存记录和 Git HEAD，提交不属于合并的内容并清空其暂存态`
- 预期修复：`在 Squash 自动提交执行前核实初始 index 无预先暂存变更，若不干净则在首次 Git 修改前明确拒绝自动 Squash；保持正常 Squash、No Commit 和失败路径不变，复用同一 perform 入口`
- 验证：`临时真实 Git 仓库复现已有 staged 和 already-up-to-date 两情况，GitCommitActionTests 与 GitRemoteBranchActionTests Red-Green，Windows SSH 全量 make test 和 make build`
- 解决证据：`f4f8cc0；git merge --squash with unrelated staged and already-up-to-date cases Red then Green；/tmp/kero-p4-deeper-green2-GitCommitActionTests.log 13/13；/tmp/kero-p4-deeper-green2-GitRemoteBranchActionTests.log 15/15。`


## 发现 F-17

- 任务：`P4-T7`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1775`
- 摘要：`已跟踪的修改文件仍显示添加到 .gitignore，但 Git 不会忽略已跟踪文件，形成成功保存却无实际忽略效果的无效操作`
- 风险：`普通 CHANGES 中已跟踪文件点击 Ignore 后会新增一条无效规则，仍保持 M 状态，使用户误以为文件已被忽略，污染 .gitignore`
- 预期修复：`在现有 Git 文件菜单入口只对真正未跟踪（?）行展示 Ignore；目录只有包含未跟踪文件才展示，intent-to-add 已占用索引同样不应提供无效操作；不引入第二套 Ignore 实现`
- 验证：`真实临时 Git 仓库验证 tracked M / untracked ?? 的 check-ignore 差异；NativeUI 原生文件右键菜单 Red→Green；make test；make build`
- 解决证据：`cd4187b: 原生真实 Git 菜单测试先 Red（tracked 无效 Ignore），再 Green 5/5；Windows SSH 全量 KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test：224/224，0 failure，0 skipped；make build + codesign --verify --deep --strict 通过；/Applications/Kero.app 整包替换并严格验签通过，不重启用户进程；git diff --check 通过。`


## 发现 F-16

- 任务：`P4-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:2671`
- 摘要：`Ref、Remote、Git 目录与进行中操作标记失败时发布不完整的成功快照`
- 风险：`间歇性 SSH/Git 故障会把已有分支、Tag、远端和正在进行的 Merge/Rebase 状态清空，历史引用徽章与菜单短暂消失、部分本应禁用的提交操作被启用，且未报告查询失败；T4、T5 与 T9 同样受影响。`
- 预期修复：`在 runGitStatus 统一校验 Ref、Remote、Git 目录三个查询，并让本机/远端正在进行的 Git 操作标记检测传播真实读取失败；仅明确缺失的标记表示没有操作。失败走既有 .failed → statusError 与成功快照保留路径，不在各个菜单叠加守卫。`
- 验证：`局部关键快照 5 条断言 Red（/tmp/kero-p4-post-audit-f16-metadata-red.log）；初步 Green（/tmp/kero-p4-post-audit-f16-metadata-green.log），Windows 223/223 PASS（/tmp/kero-p4-post-audit-f16-full-windows.log）；沿标记检测继续发现 2 条 Red（/tmp/kero-p4-post-audit-f16-marker-red.log）再专项 Green（/tmp/kero-p4-post-audit-f16-marker-green.log）；以含真实 Windows SSH 的最终全量、build、严格验签作最后 Gate。`
- 解决证据：`两轮专项 Red：Ref、Remote、Git 目录 5 条断言失败（/tmp/kero-p4-post-audit-f16-metadata-red.log），在途 Merge 标记 SSH 读取失败 2 条断言失败（/tmp/kero-p4-post-audit-f16-marker-red.log）；同一模型测试对应 Green（/tmp/kero-p4-post-audit-f16-metadata-green.log、/tmp/kero-p4-post-audit-f16-marker-green.log）。唯一状态读取入口修复后完整 Windows SSH make test 223/223 PASS、0 failed、0 skipped（/tmp/kero-p4-pr14-post-audit-f16-final-full-windows.log）；make doctor Xcode27.0、make build PASS、严格 codesign PASS（/tmp/kero-p4-pr14-audit-f16-final-build.log）；完整 Debug Kero.app 整包替换，已安装和构建 SHA256 同为 4a2ec5a40b115fd374f55a5847f9df20e56b338a92685c3c288a199043098ec0，用户 PID69132 未重启或退出，配置 SHA256 不变。`


## 发现 F-15

- 任务：`P4-T9`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/NativeUI/Git/GitInteractiveRebaseTests.swift:76`
- 摘要：`序列编辑器测试把标记文件存在误判为已完成写入`
- 风险：`完整测试可能在PTY行写入前读取文件而随机失败，无法稳定证明真实交互式变基`
- 预期修复：`等待完整的工作目录与PTY两行就绪信号，继续核对实际HEAD与终端结果`
- 验证：`Windows SSH专项GitInteractiveRebaseTests及无人干预的完整make test; make build`
- 解决证据：`首次完整测试222项仅本机PTY就绪断言失败，源码证明文件存在先于第二次追加；bcd3ced只改完整标记等待。含真实Windows SSH专项2/2、无人干预完整222/222（0失败0跳过）、make doctor、make build/严格验签均通过；新版整包安装且正式PID40825未重启。`


## 发现 F-14

- 任务：`P4-T7`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Editor/FileViewerView.swift:120`
- 摘要：`Ignore只等待最初读取任务，原生挂载替换读取后误判或使用旧缓存`
- 风险：`真实Windows App创建空.gitignore后未追加规则；已有文本时取消的旧任务结束而新读取未完，可能从旧缓存追加并覆写新磁盘规则`
- 预期修复：`FileTab.waitForText沿同一目标实际拥有的读取代次继续等待，目标变更仍拒绝，不轮询sleep、不引入第二缓冲或读任务`
- 验证：`受控双读取覆盖loading和已有缓存，先Red再Green；FileTab/GitWorkspaceMenu/真实Windows挂载Ignore及完整test/build`
- 解决证据：`9d5c722：受控loading/缓存双读取Red六条失败后FileTab14/14、GitWorkspaceMenu4/4、build/签名PASS；PID15033真正Windows新建.gitignore→普通TextKit挂载→追加并保存/literal\[1\].txt，git check-ignore命中，Mac同名文件未创建`


## 发现 F-13

- 任务：`P4-T6`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/DiffTextView.swift:266`
- 摘要：`历史原文与只读Diff的辅助功能值写入绕过isEditable`
- 风险：`真实App的历史base文本通过辅助功能变成99base；未改Git对象或磁盘，但只读显示失真且向辅助技术宣告可写`
- 预期修复：`在现有DiffTextView边界约束AX值setter和settable声明，所有只读面板共用；不改第三方源码、不造RevisionViewer`
- 验证：`扩充真实原生历史与共享文本视图回归先Red再Green；确认编辑态仍接受AX写入，完整make test/build及App复验`
- 解决证据：`原生Red五条失败；共用DiffTextView拒绝AX只读值写入及settable声明后GitHistoryFile11/11、DiffTab16/16、build/严格签名PASS；正常编辑态AX仍可写`


## 发现 F-12

- 任务：`P4-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1383`
- 摘要：`远端检出已有分支路径跳过名称校验，可把外部名为减号的Ref当作前次检出简写`
- 风险：`与F-07共享Git语义，确认检出已有减号分支时实际切换并Pull到另一个分支`
- 预期修复：`新建与已有分支两条远端Checkout路径均执行同一现有check-ref-format预检，不添加视图特判或新状态`
- 验证：`真实Git构造减号Ref与前次分支，先Red再Green；Remote集成与完整make test/build`
- 解决证据：`真实Git Red3条失败（previous/错误HEAD/无错误）；修复后Remote14/14，make build/严格验签PASS，删除已有分流跳过校验的豁免`


## 发现 F-11

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1402`
- 摘要：`Force Fetch 核对只读 remote-tracking Ref，未固定会被覆写的本地目标`
- 风险：`真实 App 中确认前把 side 从旧目标移动到 44af4cf，勾选 Force 后仍被覆盖为 dd445d6，丢失未经本次确认授权的新分支位置`
- 预期修复：`打开 Fetch 表单时捕获本地目标 OID，沿唯一 perform.expectedRef 核对该实际写入目标；Fetch 仍按原生语义获取服务器最新分支，不加服务器 lease 或第二个执行器`
- 验证：`完整 App Red 已复现；新增真实原生 Fetch 表单/缓存刷新/过期拒绝、新确认强制和正常快进回归；完整 make test/build`
- 解决证据：`完整App旧行为覆写44af4cf→dd445d6；/tmp/kero-p4-t9-fetch-red.log Red 后 fetch-green1/1，fetch-adjacent13/13，实际本地Ref与HEAD均核对`


## 发现 F-10

- 任务：`P4-T5`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1028`
- 摘要：`真实中文 Tag 详情显示 Close/Commit，相关 P4 字段与错误缺少字符串表项`
- 风险：`中文界面和 VoiceOver 帮助回退英文，不满足本阶段本地化合同`
- 预期修复：`补齐 Git/Sidebar 的七个现行缺失键，不改变菜单或 Git 行为`
- 验证：`字符串 JSON 与缺键扫描、NativeUI、make build、隔离 App 详情与 Stash 字段复验`
- 解决证据：`fcd80bd，七键JSON和Git字符串缺键扫描通过，原生Tag4/4、build/严格签名通过；PID28904真实中文Tag详情显示提交/关闭；PID3581 Stash Branch字段有明确Branch Name辅助标签，未改用户语言配置`


## 发现 F-09

- 任务：`P4-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/NativeUI/Git/GitTagDialogTests.swift:115`
- 摘要：`Tag 类型测试用 performClick 打开原生菜单并无限等待外部事件`
- 风险：`全量测试阻塞；先前专项绿色依赖外部鼠标关闭菜单，且没有验证类型切换后编辑状态`
- 预期修复：`选择项后发送控件已有 action，直接验证真实类型更新与消息只读；真实展开菜单留给 E2E，不用任意等待或跳过`
- 验证：`PID99729 采样 /tmp/kero-p4-t9-test-sample.txt 定位菜单事件跟踪；专项与无外部干预全量复验`
- 解决证据：`原生采样明确卡在 performClick 菜单；sendAction 后 /tmp/kero-p4-t9-tag-popup-green.log 4/4 无外部输入通过`


## 发现 F-08

- 任务：`P4-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:594`
- 摘要：`Branch 和 Tag 替换确认未固定打开时的目标 OID`
- 风险：`确认期间外部进程移动 Ref 并触发状态刷新后，Model 在确认回调重新读取新 OID，仍会强制覆写用户未确认的新目标；Tag 默认可能无 reflog`
- 预期修复：`打开替换确认前按需读取实际 Ref OID；创建 API 用明确 replacing OID 替代 Bool 并透传既有 perform.expectedRef，迁移所有调用并删除旧布尔路径`
- 验证：`真实 NSAlert 的 Branch/Tag 重名改名保留输入、外部移动并刷新后拒绝替换、新确认成功；Integration 与完整 make test/build`
- 解决证据：`原生 Branch/Tag 真实 Red 后 /tmp/kero-p4-t9-ref-green.log 1/1；共享读取复用后 GitTagActionTests7/7；所有 replace Bool调用已迁移删除`


## 发现 F-07

- 任务：`P4-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1182`
- 摘要：`共享分支切换把外部 Ref 名当作 Git 选项或前次检出简写`
- 风险：`真实 update-ref 可产生 -d 和 - 分支；switch -d 成功进入 detached HEAD，switch - 可切到另一个分支，而非用户右击目标`
- 预期修复：`共享 switchBranch 用选项结束符和现有 Git check-ref-format --branch 预检，拒绝非标准分支名，不用 View 特判或兼容路由`
- 验证：`GitBranchActionTests 新真实 Ref 边界先Red再Green，普通分支切换回归，make test/make build`
- 解决证据：`真实 Model Red 后 /tmp/kero-p4-t9-switch-green.log 13/13，通过标准校验/选项边界与普通切换相邻路径`


## 发现 F-06

- 任务：`P4-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1063`
- 摘要：`Tag 远端包含检查失败返回 nil 时直接继续 Push`
- 风险：`查询失败被误当作不需要警告，可能绕过 Proceed to Push 的用户选择`
- 预期修复：`nil 明确拒绝并报告检查失败；只在检查成功后决定警告或推送`
- 验证：`原生面板失败查询后真实 bare remote 没有 Tag；正常路径仍推送`
- 解决证据：`2e5bb4c，真实查询失败不启动Push、服务器无Tag，GitTagDialogTests4/4`


## 发现 F-05

- 任务：`P4-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitPanel.swift:1027`
- 摘要：`Tag Push 表单硬编码 origin，忽略 remote.pushDefault`
- 风险：`多 remote 时默认选错推送目标，尽管共享 preferredPushRemote 已正确支持无 Branch 查询`
- 预期修复：`Tag Push 复用 preferredPushRemote(for: nil)，异步后核对原窗口与目标；原生面板回归核对实际默认选择与服务器 Ref`
- 验证：`GitTagDialogTests; make test; make build`
- 解决证据：`2e5bb4c，真实原生表单与bare remote，Red后GitTagDialogTests4/4`


## 发现 F-04

- 任务：`P4-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Resources/Localization/Sidebar.xcstrings:221`
- 摘要：`新分支原生名称字段缺中文，Tag 迁移留下无引用的 Show Tagged Commit 字符串`
- 风险：`中文表单混用英文且遗留已删除菜单文案，违背本阶段本地化和清理边界`
- 预期修复：`补齐 Branch name 与该入口新增中文文案；删除已无代码引用的 Show Tagged Commit`
- 验证：`字符串 JSON 校验、引用核对、NativeUI 与 make build`
- 解决证据：`04e8d9c，JSON校验、无引用旧入口扫描、更新资源后原生测试5/5通过`


## 发现 F-03

- 任务：`P4-T5`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`docs/features/git.md:55`
- 摘要：`归档说明仍称 Tag 属于后续任务，现行历史重命名计划只写一次查询与已验证实现不符`
- 风险：`当前文档和计划误导后续维护，可能删掉已验证的改名再编辑路径`
- 预期修复：`删除 Tag 未实施说法；按真实 T6 测试说明工作区差异无改名结果时查 Revision 到 HEAD 并确认目标存在`
- 验证：`核对当前调用、GitHistoryFileTests 和功能文档引用`
- 解决证据：`811835a，GitHistoricalFileLocator与Rename再编辑原生回归核对，现行plan已同步`


## 发现 F-02

- 任务：`P4-T6`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:2033`
- 摘要：`Reset File 将自身保存产生的工作文件变化判成确认过期`
- 风险：`目标 FileTab 有未保存文本或在途保存时，prepare 保存后与旧指纹比较必然拒绝，无法完成已确认覆写`
- 预期修复：`在准备保存前验证确认指纹，准备后核对 index 未变并捕获新工作文件状态，首次 Git 写入前再验证；不移除外部变更保护`
- 验证：`GitHistoryFileTests 的真实 FileTab 保存/复位和 stale 回归；make test; make build`
- 解决证据：`dd4535e，GitHistoryFileTests及完整214/214，远端Reset真实App结果已核对`


## 发现 F-01

- 任务：`P4-T4`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Git/GitBranchDialog.swift:60`
- 摘要：`远端 Fetch/Pull 表单确认按钮沿用了菜单名而非明确的 Yes, Fetch/Pull`
- 风险：`与原生弹窗行为合同不一致，测试固化了错误标签`
- 预期修复：`保留菜单名，确认按钮改为 Yes, Fetch 和 Yes, Pull；更新原生断言与翻译`
- 验证：`make test ONLY_TESTING=KeroTests/GitBranchDialogTests; make test; make build`
- 解决证据：`385cf50，GitBranchDialogTests 4/4，完整214/214`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-15 `bcd3ced`：完整测试的本机 PTY 等待错误是测试先看见标记文件、后看见追加的 `PTY`，将就绪条件收敛为完整内容。含真实 Windows SSH 的专项 2/2 与后续无干预全量 222/222 通过，生产执行链不变。
- F-01～F-06：按真实表单补明确按钮、修Reset File保存指纹时序、纠正文档/本地化、Tag默认remote与失败检查。提交与针对性日志见各发现及`evidence-p4.md`。
- F-07/F-08/F-11/F-12：真实Git与原生确认复现后修标准分支名、固定替换Ref及Fetch本地目标；原Bool替换API及已有分支跳过校验的豁免已删除，不以菜单特判掩盖模型问题。
- F-09：原生采样证明测试卡在弹出菜单的performClick；改为原控件action并核对编辑状态。无人干预全量已通过219项，后续修改再跑最终全量，不把人工解阻的215项记为Gate。
- F-10：七个现行字符串键补中文，真实中文Tag详情复验；无引用旧Tag菜单键已删。
- F-13 `8cafd13`：在现有DiffTextView处理上游AX写入缺口；History11/11、Diff16/16及真实App拒绝只读写入，仍允许编辑态与选择复制。
- F-14 `9d5c722`：FileTab等待同一目标当前拥有的读任务；loading和缓存的双读取Red六条→FileTab14/14、GitWorkspaceMenu4/4，真实Windows新建+挂载Ignore最终保存正确字面规则。
- 清理核对：旧全局猜窗口、createReference/CommitReferenceKind、旧Diff来源optional/兼容初始化、无参盲stashPop、stash独立计数命令均已替换删除。派生stashCount与真实unmerged index阶段读取仍有现行职责，不能误删为“兼容代码”。没有新增通用DialogCoordinator、第二编辑器、缓存、轮询或Git executor。

## 验证日志

- 最终 `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` → **PASS 222/222，0 failures，0 skipped**；`GitInteractiveRebaseTests` 2/2、`GitWorkspaceSSHTests` 1/1，日志 `/tmp/kero-p4-t9-final-full-green.log`，无人工菜单干预；此前 222/222 中 1 失败的真实 Red 保留在 `/tmp/kero-p4-t9-final-222-windows.log`。
- `make doctor` → Xcode 27.0；`make build` + 独立严格签名 → PASS，`/tmp/kero-p4-t9-final-build.log`；安装 `/Applications/Kero.app` 并验签、可执行文件哈希一致，正式 PID40825 未重启，配置哈希不变。
- `rtk ... feature_tool.py todo validate` → OK；`phase-complete --phase p4` → PHASE COMPLETE。功能现行文档仍与本次纯测试同步修复一致，不另造第二份同步约定；局部现行计划的 Rename 检测步骤已按真实 Git 证据修正。
- `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` → PASS 10/10；原生menu(for:)只证明菜单解析，实际App的直显/折叠菜单另外核对。
- `make test ONLY_TESTING=KeroTests/GitRemoteBranchActionTests` → Red（已有分支减号别名）后PASS 14/14；Fetch表单专项1/1。
- `make test ONLY_TESTING=KeroTests/GitHistoryFileTests` → AX Red五条后PASS 11/11；`DiffTabTests`16/16。
- `make test ONLY_TESTING=KeroTests/FileTabTests` → 读任务替换Red六条后PASS 14/14；`GitWorkspaceMenuTests`4/4；每块完成时build/严格签名均PASS。
- 完整App：本机全部对象菜单与原生表单、重名两按钮、三种Push/Reset、Merge/NoCommit/冲突恢复、真实PTY交互式Rebase、具体Stash及移位、Tag创建后取消Push、历史查看/工作区刷新/Reset、两格式选定Ref归档、普通FileTab Ignore。Windows专用库实测Push/Delete/Archive/Reset、Fetch过期拒绝及新Force、Checkout冲突分流/Pull、Tag创建/服务器删除与新建挂载Ignore。具体SHA/字段/文件结果见同目录证据，不把低层测试统称E2E。
- 当前文档归属：Git/Diff/Editor/Files/UI/Settings/SSH/Terminal/Session Restore及测试说明随原task同步；Tag Archive未来时态、警告默认选项和无引用文案已纠正。当前plan只修正有真实Git证据的Rename再编辑查询漂移，未缩水验收。
- 无新增关键环境假设：外部CLI可并发，检查不承诺跨进程锁；SSH使用真实获准Windows和独立master。VoiceOver基础验证实际AX名称、动作与不可写属性，未启动系统朗读，不冒称人工语音走查；Issue #2 的SSH外部刷新未据菜单验收关闭。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P4-T1～T9 均完成，15 条发现均有修复及验证证据；真实本机/Windows 菜单与 Git 副作用已覆盖，无干预全量测试、Debug 构建、严格签名与整包安装全部通过。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：没有已知的 P4 未解决 Finding；未启用 VoiceOver 系统朗读做人工走查，仅有真实 AX 名称、菜单、焦点和只读属性的原生验证。Issue #2 的 SSH 外部变更自动刷新仍需独立验收，不属于本阶段完成证明。运行中的正式 App 未重启，磁盘新版下次启动生效。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-15 独立复审：P4 × PR #14（按提交顺序）

范围锁定：PR #14 合并时的 head `9f653fd`（merge `0686673`），实际 `38` 次提交、`72` 个差异文件；P4-T1～T9 以 `todo.toml` 与 `plan-p4.md` 原始验收要求为准。逐次核对 `git show` 的真实文件差异、最终源码调用方、现行测试和集成结果；计划与纯证据提交不冒充生产功能。**以下是针对最终集成态的审查，不意味着重新 checkout 并单独运行了 38 个历史版本。** 本次判断不以旧审计的结论为依据。

| 顺序 | PR 提交 | 对应任务 | 独立核查的正式入口／结果 |
| ---: | --- | --- | --- |
| 01 | `eeaca06` | P4 需求 | 仅需求与任务分解，不是产品实现；与现行九任务对照 |
| 02 | `b3014dd` | P4 计划 | 菜单与弹窗合同收敛；现行代码逐对象另行核对 |
| 03 | `a5f1c91` | T1 | `RecentCommitsView` Commit 菜单 → `GitPanel.presentCommitDialog` → `actOnCommit`，真实 Cherry-pick／Revert／Merge／Checkout 用例 |
| 04 | `ffd3194` | T2 | 同入口的 Rebase、Soft/Mixed/Hard Reset、按提交拓扑限制的 Drop；交互式会话经 `Project.newInteractiveGitSession` |
| 05 | `c4ec20c` | T1–T2 | 只同步任务与验证资料；不计作新功能 |
| 06 | `c15d72c` | T3 | `presentBranchCreate/Action` → `createBranch/renameBranch/deleteBranch/pushBranch`；归档走 `createArchive` 并核选定 Ref/OID |
| 07 | `a6f28be` | T3/T9 相邻测试 | 修正 XCTest 原生窗口生命周期与刷新测试的前提；无新增产品调用链 |
| 08 | `9e25f51` | T4 | 远端 Ref 的 Checkout/Fetch/Merge/Pull/Delete/Archive 接入直显 Badge 和折叠菜单、同一 Git executor |
| 09 | `11d9e33` | T5 | Tag 轻量/附注创建、详情校验、指定远端 Push/Delete/Archive；引用来自实际 Git Snapshot |
| 10 | `43e9ec7` | T3–T5 | 仅计划进度与证据；没有新产品代码 |
| 11 | `e5a64fd` | T6 | 历史文件菜单 → `Project.openHistoricalDiff` 与 `resetHistoricalFile`；DiffTab 来源显式类型及 SessionStore 真正使用 |
| 12 | `57cac9e` | T6 | 仅进度与实施证据 |
| 13 | `af16b18` | T7 | Git 行／目录标题右键 → `stageEntries/unstageEntries/stash/resetUncommitted/cleanUntracked`；Ignore 经真实 `Project.ignoreGitPaths` |
| 14 | `111f3cd` | T8 | `GitPanel.stashRow` → `actOnStash`，Stash selector/OID 同快照，Pop/Drop/Branch 显式锁定选择 |
| 15 | `320b4cc` | T7 | `GitUncommittedActionTests` 纳入同一 XCTest 目标，验证真实 Git index、工作区和 Clean 范围 |
| 16 | `c0edf54` | T7–T8 | 提交任务状态与历史证据；不计入功能实现 |
| 17 | `385cf50` | T4 | Remote Fetch/Pull 原生确认按钮与资源回归；保留既有 Git 功能入口 |
| 18 | `dd4535e` | T6 | 复位先保存再复核文件/index 的副作用次序，专属 `GitHistoryFileTests` |
| 19 | `2e5bb4c` | T5 | Tag Push 默认 Remote 和失败检查后不推送的真实 bare remote 及对话框回归 |
| 20 | `811835a` | T5 | 归档功能文档去掉错误未来时态，仅文档 |
| 21 | `04e8d9c` | T3/T5 | 补本地化并删除无引用旧菜单资源；仅资源清理 |
| 22 | `80f7129` | T7/T9 | Windows SSH GitWorktree 实测 + LazyVStack 真行右键命中；测试纳入已有目标 |
| 23 | `2da19d8` | T5 | 澄清 Push 警告复选框默认值，非行为变更 |
| 24 | `c555404` | T9 | 测试原生 NSPopUpButton 事件跟踪改用控件 action，避免全量测试阻塞 |
| 25 | `7b62892` | T3/T9 | `switchBranch` 统一 Git 名称预检，`-`／`-d` 不能劫持 switch 命令 |
| 26 | `1c05cd7` | T3/T5/T9 | Branch/Tag 替换确认读取真实初始 OID，`perform(expectedRef:)` 拒绝旧授权覆写新目标 |
| 27 | `fcd80bd` | T5/T8 | Tag/Stash 原生 UI 中文资源补齐，保持业务逻辑不变 |
| 28 | `53fb771` | T4/T9 | Force Fetch 捕获目标本地 Ref OID，执行前比较同一引用，防外部移动误覆盖 |
| 29 | `aaf69f` | T9 | NativeUI 的 Badge 右键菜单归属验证，非仅合成事件已发送 |
| 30 | `ed862e5` | T4/T9 | Remote Checkout Existing & Pull 复用名称预检，拒绝 Git `-` 上次分支别名 |
| 31 | `8cafd13` | T6/T9 | 共用 `DiffTextView` 只读原生 Accessibility setter 真正拒写 |
| 32 | `9d5c722` | T7/T9 | `FileTab.waitForText` 追当前读取任务，真实远端 Ignore 不用取消任务的过时内容 |
| 33 | `bcd3ced` | T2/T9 | PTY Rebase 测试等完整内容就绪，不依赖固定 sleep 或人工输入 |
| 34 | `b5f79a4` | T9 | 阶段任务状态／原有审计资料，无生产实现 |
| 35 | `ad3f1ba` | T9／Issue #2 | 记录真实 SSH 外部刷新 Red 和 VoiceOver 实际边界；该提交未修生产代码 |
| 36 | `ca183bf` | Issue #2／T9 相邻 | `ToolPanelView` 已有可见面板任务放开 SSH Git 周期刷新；真实 Windows SSH 后端、原生面板自动检测；随后另完成完整独立 App E2E（后续证据提交不属于 PR #14） |
| 37 | `3716644` | T9 文档收口 | 用户／Git／SSH／UI／测试说明更新，取消额外 VoiceOver 专项强制要求 |
| 38 | `9f653fd` | PR 收尾 | 历史审计末尾空行修正，无产品逻辑 |

### 复审判据和遗留代码

- **产品真正使用**：`ToolPanelView` 实例化正式 `GitPanel`；`GitPanel.changeList` 实例化正式 `RecentCommitsView` 并将 Commit、Branch、Remote、Tag、历史文件、Stash 和目录菜单回调分别连到 Model 与 Project；Model 统一走 `GitCommandExecution` 和当前 Local/SSH `WorkspaceBackend`，提交副作用由真实 Git、文件和远端引用测试断言。
- **对照删旧路径**：现行生产源码没有 `presentGitNameDialog`、`CommitReferenceKind`、旧混合 `createReference`、参数为空的 `stashPop()` 或已废弃的 `Show Tagged Commit`。现有 `stashCount` 是 `stashes.count` 的只读派生，确实被正式 Git 标题使用；不是独立计数缓存。现有 `expectedRef`、项目/连接身份、未保存缓冲、归档上限、旧操作拒绝等保护防止覆盖用户数据，不能作为“多余安全围栏”删除。
- **此次新发现**：F-16（见本文件发现项）证明 Ref、Remote、Git 目录和 Git 操作标记共四类关键读取故障原本会发布缺失数据的成功快照。完整旧版 `223/223` 没覆盖该风险；新增 7 条 Red 断言后沿唯一 Git 状态快照入口修复，关键标记的本机/SSH 读取保留真实错误，不在菜单分支补救；专项及最终含真实 Windows SSH 全量均通过。

### 独立复审 Gate（最终）

- **结论：Go。** P4-T1～T9 对应产品入口、38 个 PR #14 提交和 72 个差异文件按最终源码独立核对；历史提交本身不被冒充为逐 SHA 重编的通过证明。此次唯一新确认的根因 F-16 已通过真实 Red/Green 并在同一 GitStatusModel 快照所有者修复。
- **最终回归**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` → **223/223，0 失败、0 跳过**（`/tmp/kero-p4-pr14-post-audit-f16-final-full-windows.log`，586.008 秒），涵盖真实 Windows SSH、Git 面板自动刷新、历史提交和图谱、Remote/Tag/Stash、交互式 Rebase、文件／目录和原生菜单。关键扩展测试 `GitStatusModelTests.testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers` 也在最终全量中通过。
- **构建和安装**：`make doctor` Xcode 27.0；`make build`、`codesign --verify --deep --strict`、同盘完整 App 替换与安装后的签名及可执行文件哈希对照通过。安装哈希 `4a2ec5a40b115fd374f55a5847f9df20e56b338a92685c3c288a199043098ec0`，正式 PID69132 未退出/重启，普通配置未改；新版等待用户下次自行重启后生效。
- **范围边界**：没有为了所谓“安全围栏精简”删除必要的用户数据保护；计划点名的旧 Git 菜单/Ref/Stash 双轨入口在当前源码不存在，`stashCount` 只是派生展示值，不是旧缓存。PR #14 已在本次审查前合并，这次审后修复是本地后续改动，尚未另外推送或发布 PR。审查和当前通过的回归不能逻辑上保证未来所有环境均无缺陷；无其它已复现的 P4 阻断项。

## 2026-10-15 独立逐提交复审（本轮）

审查只以 `idea.md`、`todo.toml`、`plan-p4.md`、当前 `AGENTS.md`／owner 文档、真实 `git show`、CodeGraph 逐字符源码与调用关系、临时 Git 仓库及本轮实际 XCTest 为依据；旧 audit 的 findings、Gate 和叙述不作为结论证据。范围限定 P4；随后 `ca183bf` 和 `a266595` 等 Git 修改按当前调用链核对，避免只审历史 SHA 而忽略最终版本。

| todo 任务及其提交 | 当前生产接线及可观察结果 | 当前测试和审阅结论 |
| --- | --- | --- |
| P4-T1 `a5f1c91` | `RecentCommitsView` 的 Commit 菜单 → `GitPanel.presentCommitDialog` → `GitStatusModel.actOnCommit/perform` → backend Git；Checkout、Cherry Pick、Revert、Merge 和冲突保留由同一入口完成 | `GitCommitActionTests`、`GitCommitDialogTests` 的临时仓库 HEAD/index/worktree、原生确认与冲突断言；接线有效 |
| P4-T2 `ffd3194` | Rebase/Soft-Mixed-Hard Reset/合法 Drop 仍经所选 Commit；交互式由 `Project.newInteractiveGitSession` 启动选定机器的新原生终端 | `GitCommitActionTests`、`GitInteractiveRebaseTests`；本轮 Windows SSH 独立 PTY 已通过，不能以仅发出启动事件代替完成 |
| P4-T3 `c15d72c` | 本地 Branch 的 Create/Rename/Delete/Push 与 ZIP/TAR Archive 通过 `GitPanel.presentBranchCreate/presentBranchAction` 和 `GitStatusModel`，保留所选 Ref 对象身份 | `GitBranchActionTests`、`GitBranchDialogTests`、`GitWorkspaceSSHTests`；无遗留 `createReference` 兼容分支 |
| P4-T4 `9e25f51` | 远端 Badge 与折叠 Ref 的 Checkout/Fetch/Merge/Pull/Delete/Archive 经 `presentRemoteBranchAction` 和 model 现有执行器；同名本地 Ref、远端范围和 Force 在现行源码中独立核对 | `GitRemoteBranchActionTests`、`GitRemoteBranchDialogTests`、真实 SSH；后续已修复的远端 Fetch 过期 Ref 检查属于最终源码 |
| P4-T5 `11d9e33` | Tag Annotated/Lightweight、Details、Delete、Push 与 Archive 经 `presentTagCreate/presentTagAction/presentTagPushWarning`、`createTag/tagDetails/deleteTag/pushTag` | `GitTagActionTests`、`GitTagDialogTests`、Settings tests；旧 Tag 创建回调已删除；查询失败时停止并报错是后续修复后的真实语义，计划已同步 |
| P4-T6 `e5a64fd` | `RecentCommitsView.changedFile` → `GitPanel.handleHistoricalFile` → `Project` 的原生 FileTab / `DiffTab` / `GitHistoricalFileLocator`；Reset File 经真实 Git index 和工作区覆写 | `GitHistoryFileTests`、`DiffTabTests`、`SessionStoreTests`；只读文本、二进制和保存/过期检查非无效围栏 |
| P4-T7 `af16b18` | `GitPanel.changeList` → `GitEntryRow.menu`/`directoryMenu`、Uncommitted 表单 → `GitStatusModel`，Ignore 由 `Project.ignoreGitPaths` 写入现有原生 `.gitignore` FileTab | 发现 F-17：对已跟踪／intent-to-add 行展示无效 Ignore。独立 Git 复现和 NativeUI Red 后按 Git `?` 精确资格修复；定向回归 5/5 Green |
| P4-T8 `111f3cd` | `GitPanel.stashRow/presentStashDialog` → `GitStatusModel.actOnStash`，同一 status 快照派生 Stash count，Pop/Drop/Branch 检查 selector+OID | `GitStashActionTests`、`GitStashDialogTests`；无无参盲 Pop 或双份独立 stashCount 查询 |
| P4-T9 `bcd3ced` | 本提交修复交互式 Rebase 测试的完整就绪条件，不谎称它单独交付前八项全部功能；当前菜单→原生面板及各类持久结果由上述功能和真实 SSH/NativeUI 测试承接 | `GitWorkspaceSSHTests`、`GitInteractiveRebaseTests`、`RecentCommitsViewTests` 等；本轮不重新宣称未亲自重做的独立完整 App 物理点击 E2E |

**本轮已完成的独立验证：** 初始真实 Windows SSH 全量 `223/223, 0 failures`（`/tmp/kero-p4-independent-audit-test.log`）；F-17 Git CLI 临时库确认 tracked/intent-to-add 即使写入 `.gitignore` 仍不被忽略；补原生右键验收 `/tmp/kero-p4-f17-red-confirmed.log` 如期 Red；最小源码修复后 `/tmp/kero-p4-f17-green.log` 的 GitWorkspaceMenuTests `5/5` Green。最终完整 Windows 回归、build、严格签名与安装结果于完成后补记。

**清理判断：** 旧 `presentGitNameDialog`、`presentCreateReferenceDialog`、`CommitReferenceKind/createReference` 和无参 Stash Pop 已无现行引用。当前机器/仓库/窗口身份、保存中失效、Git index/Ref 和 Stash OID 验证都阻止真实串目标或丢数据，不因“减少围栏”而删除。旧计划的入口符号、Tag 包含关系查询失败语义和专项 VoiceOver 强制验收已依最新源码与需求校准；这是计划漂移而非另外的实现缺陷。

### 独立复审最终验证与 Gate（2026-10-15）

- 独立基线：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，`/tmp/kero-p4-independent-audit-test.log`：**223/223，0 failures**。
- F-17 根因：`git check-ignore -- tracked.txt` 和已 add -N 的 intent-to-add 都不会返回忽略匹配，即使对应规则已加入 `.gitignore`；真正未跟踪文件才受规则影响。真实原生 `NSWindow/NSHostingView/GitPanel` 右键测试 `/tmp/kero-p4-f17-red-confirmed.log` **Red**，受影响菜单资格修复后 `/tmp/kero-p4-f17-green.log` **5/5 Green**。
- 修复后完整 Windows SSH 回归：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，`/tmp/kero-p4-f17-final-full-windows.log`：**224/224、0 failures、0 skipped，TEST SUCCEEDED**。Windows 本机/自动 SSH Interactive Rebase、真实 SSH Archive/二进制文件 Reset/Stash/Clean/Ignore 均 passed；新原生菜单测试 passed。
- `make build`：`/tmp/kero-p4-f17-final-build.log`，**BUILD SUCCEEDED**，自带 `codesign --verify --deep --strict` PASS；`git diff --check` PASS。
- **安装**：将当前签名 Debug `Kero.app` 在 `/Applications` 临时目录预签验证后整包替换 `/Applications/Kero.app`；目标重验签 PASS，安装包的 `Contents/MacOS/kero` 与构建源码二进制 SHA-256 都为 `d9d000e7c04275f86baf88ec7b133afdcb9b7ed0918960be68681b0cdedff8d5`。替换前旧完整包的临时备份已清理。没有停止／重启用户当前 Kero 进程，磁盘新包需用户自行重启后生效。
- 生产最小修复已原子提交：**`cd4187b`**（仅 `GitPanel.swift`、原生右键测试和 `docs/features/git.md`）。Phase 计划与审计继续按 Skill 保留在本地，不混入代码提交；`idea.md` 的当前验证计数同步为 224。
- **Gate：Go（P4 代码、测试和安装范围）**。本轮发现 F-17 已通过专用脚本标记 `Resolved`，无新确定的正确性阻塞项。以前 `evidence-p4.md` 记录过独立完整 App 的多对象菜单和 Windows UI E2E；本轮没有重做完整 App 逐按钮物理点击和 VoiceOver 系统朗读/导航，不把 NativeUI/SSH XCTest 冒充这些 E2E。VoiceOver 专项原已排除出需求；当前安装后正式进程也并未重启。历史旧测试失败和有限平台诊断仅留在历史执行证据中，不拿其推测新的产品缺陷。

## 2026-10-15 P4 二次独立深入审查（针对上一轮只有 F-17 的复核）

以现行生产代码为依据，使用 CodeGraph 逐字源码及入口→模型→Git argv→工作区/索引/Ref/reflog 路径追踪，所有新 finding 均在本轮先记录再修复，旧 `audit*.md` 不作为缺陷存在性证据。旧 F-17 的修复提交 `cd4187b` 未被撤销。

| Finding / task | 真实失败依据（Red） | 最小根因修复 / 定向 Green |
|---|---|---|
| F-18 High / P4-T1，并涉及 T4 Pull Squash | `git merge --squash` 保留原索引的 staged 条目；旧 `perform` 仅检查合并后整个 `git diff --cached`，即使 `Already up to date (nothing to squash)` 仍可能 `git commit` 预存文件。`/tmp/kero-p4-deeper-red-GitCommitActionTests.log` 两项真实仓库 Red；`/tmp/kero-p4-deeper-red-GitRemoteBranchActionTests.log` 远端 Pull Red | 原有 `perform` 在自动提交 Squash 首次 Git 副作用前检查索引干净，否则明确失败，`No Commit` 不变。`f4f8cc0`；定向 Commit 13/13、Remote Branch 15/15 Green |
| F-19 Medium / P4-T7 | `git rm --cached retained.txt` 后真实 `status --porcelain=v2 -z` 为 `1 D.` 与 `?` 两记录，旧 parser 按路径去重隐藏 `?` 行。`/tmp/kero-p4-deeper-red-GitWorkspaceActionTests.log` Red | 现有 parser 仅在相同分组内去重；STAGED 与 CHANGES 分别保留同路径文件。`f4f8cc0`，Workspace Actions 5/5 Green |
| F-20 High / P4-T7 | 外部切换 `main→other` 后旧 CHANGES 行仍能对同路径调用 Stage，污染另一分支 index；同一真实 Git 集成 Red | Entry 在现有 status 发布时记录仓库代次/分支/HEAD，`isCurrent(entry)` 唯一公共位置拒绝过期行，成功路径仍使用现有 Stage。`f4f8cc0`，Workspace Actions 5/5 Green；`GitStatusModelTests` 内旧测试曾错误地期望作用于跨 scope 旧行，已改成旧行拒绝、当前重新选中行可用，定向 10/10 Green |
| F-21 High / P4-T8 | 真实 Git stash store 同一 OID 的不同 reflog 记录，在外部插入新 stash 后旧 `stash@{1}` 被另一同 OID 条目占据；单 OID 校验通过且实际误删另一个 reflog。`/tmp/kero-p4-f21-red.log` 原生执行器 Red | 弹窗开启时捕获现有 stash 列表，唯一 `perform` 在副作用前通过既有 stash list/parse 比对 selector/OID/消息的完整快照；不新建状态机，Apply 固定 OID 行为不变。`7c7ddc6`；Stash Action 10/10、GitStatusModel 10/10、Stash Dialog 2/2 Green |

初次合并测试包执行真实 Windows SSH 完整回归 `/tmp/kero-p4-deeper-final-full-windows.log`：229 项里有 5 个断言失败、涉及三个用例。其一 `GitStatusModelTests.testDiscardReviewGuardsContentSymlinkAndRepositoryScope` 是上述 F-20 新目标身份与旧测试假定冲突，修改测试后单类 10/10 通过。另两处为真实 SSH `mktemp` 连接返回 255 和测试私有临时文件清理时文件已不存在，无法单凭日志确定是产品缺陷；未为它们修改生产代码或任意加长等待。使用同一授权的 `windows` 主机独立重跑实际 `GitExternalRefreshTests` 3/3、`GitInteractiveRebaseTests` 2/2 均通过，日志 `/tmp/kero-p4-deeper-windows-recheck.log`，明确记录此前首次失败而不当成永久通过。

生产修复只触及原本使用的 `GitStatusModel.perform/parseStatus/isCurrent/actOnStash`、`GitPanel.presentStashDialog` 及对应测试/owner 文档；未添加兼容入口、专用存储或新的 Git 状态机。计划、idea 和审计文档保持本地；两笔代码提交 `f4f8cc0`、`7c7ddc6`。最终回归、签名、安装和 Gate 待本轮真实完成后记录。

### 二次复审最终验收与 Gate（本轮结论）

- 严格真实 Windows SSH 完整入口：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`。最终 `/tmp/kero-p4-deeper-final-230-windows.log`、`Test-kero-2026.10.15_16-43-26-+0800.xcresult`：**230/230 tests，0 failures，0 skipped，TEST SUCCEEDED**。新增 F-18～F-21 六个真实 Git 用例已发现执行并通过；Windows `GitExternalRefreshTests`、`GitInteractiveRebaseTests` 与 `GitWorkspaceSSHTests` 真实路径均 passed（后者约197.862s）。
- `make build`：`/tmp/kero-p4-deeper-final-build.log`，`BUILD SUCCEEDED`，自动 `codesign --verify --deep --strict` 通过。对源码和工作区的 `git diff --check` 及已提交文件校验无空白错误。
- 签名 Debug 完整包以独立临时 stage 校验后整包替换 `/Applications/Kero.app`，新包重验签 PASS，构建和安装可执行文件 SHA-256 均为 `7d23afa18c858d4f79b193a3a5a00f7fe20142b1b47cbfd17c18dec6798f50eb`。只清理本次确定归属的临时备份；**用户当前 Kero 进程未停止、未重启**，须自行重启后才切换磁盘新包。
- 代码修复原子提交 `f4f8cc0`（T1/T4/T7 共享根因）和 `7c7ddc6`（T8 Stash 身份）；F-18～F-21 的 Open→Resolved 由 `feature_tool.py finding resolve` 分别写入定向 Red/Green 证据，未人工改写旧审计判断。历史阶段 commit 映射及 `todo.toml` 原始 P4-T1～T9 状态保留，不虚构第十个任务。
- **Gate：Go（P4 生产逻辑/仓库操作、自动化测试、构建和磁盘安装）**；本轮四项新缺陷已全部解决，无保留的实证正确性阻塞。没有再次进行完整独立 App 所有菜单的人工端到端点击/VoiceOver 实际导航，不把 XCTest 当成该层级的重新通过；旧 `evidence-p4.md` 已有历史 E2E 记录但不是本轮依据。完整日志曾有 SSH 255 和测试临时文件已不存在两处环境失败，独立同类真机专项 5/5 和最终全量 230/230 均已通过，故不增加网络补丁、静默 fallback 或测试 sleep。阶段计划与审计保留本地，**未 push**。


## 2026-10-15 Stash 入 Git Graph 的后续补验（F-22～F-24）

**根因与实现：** 已核对 VS Code Git Graph 固定提交 `d7f43f4` 的 `src/dataSource.ts`：Stash 在图谱中作为节点显示，只沿基础提交画关系线，并具有 Stash 专属菜单。原 P4 将储藏放在独立 STASHES 区域的设计不符合该交互及当前需求（F-23）。现行 `GitStatusModel.graphCommits` 将每条记录插入现有图谱，`CommitGraphLayout` 只用真实 Commit 建立父提交 SHA 索引，从而支持同 OID 不同 reflog selector、未加载基础提交时不伪造连线。`GitPanel` 删除旧的 STASHES 分组和焦点描边入口（F-22），保留原 `presentStashDialog/actOnStash` 的完整 reflog 身份验证。展开时惰性读取已跟踪和第三父未跟踪文件，复用只读 Diff；SSH 更换通道时旧明细失效，读取失败后可重试。窄栏完整显示 `stash@{n}`（F-24）。没有引入另一套 Git 模型、图谱或操作执行器。

**执行证据：**
- 真实临时 Git：`GitStashActionTests` 核对重复 OID 不同 selector 分别成行、首父连线、缺页不造边、12 条同时间戳记录保持 reflog 数字顺序、第三父未跟踪文件的真实 Git blob，以及 Apply/Pop/Drop/Branch 精确作用对象；`GitStatusModelTests` 核对 SSH 通道切换、旧加载丢弃和失败重试；`RecentCommitsViewTests` 核对原生 Stash 右键不混入普通 Commit 操作。
- **独立完整 Kero App 的本机用户路径**：签名 Debug `--isolated-ui-test` 中观察到 GIT GRAPH 内的 Stash 节点及通向基础提交的真实彩色线；展开 `src/conflict.txt` 后打开原生历史 Diff，`QA_RESOLVED_MAIN_SIDE` → `native focus snapshot` 的真实显示与 `git diff 'stash@{0}^1' 'stash@{0}'` 一致。真实右键显示 Apply/Create Branch/Pop/Drop/Copy Name/Hash，不含普通 Commit 的 Reset/Checkout。截图 `/tmp/kero-graph-isolated-git.png`、`/tmp/kero-graph-isolated-stash-expanded.png`、`/tmp/kero-graph-isolated-stash-menu.png`；F-24 修复后 `/tmp/kero-stash-graph-badge-after.png` 确认窄侧栏中完整 `stash@{0}`。独立 App 没有执行破坏性 Pop/Drop；真实副作用由 Git 测试覆盖。隔离 App 进程已正常退出，不影响用户正式进程。
- **最终完整 Windows SSH 自动化**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，`/tmp/kero-stash-graph-badge-final-full-windows.log`，**234/234、0 failures、0 skipped，TEST SUCCEEDED**；Windows `GitExternalRefreshTests`、`GitInteractiveRebaseTests`、`GitWorkspaceSSHTests`（远端 ZIP、二进制版本、Stash、Clean、Ignore）和 `RecentCommitsViewTests` 全部 passed。F-24 之后的原生专项 `/tmp/kero-stash-graph-badge-native-final.log` 11/11 passed。
- 首轮 `/tmp/kero-stash-graph-full-windows.log` 曾有一次 SSH 前台暂存后面板未刷新的超时；独立复测 `/tmp/kero-stash-graph-ssh-refresh-isolated.log` 及后续两轮完整 234/234 均通过。没有延长超时、跳过测试或为未经定位的问题打补丁；当下没有稳定复现的 Stash 回归。
- `/tmp/kero-stash-graph-final-verified-build.log`：**BUILD SUCCEEDED**，`codesign --verify --deep --strict` PASS，`git diff --check` 和本地化 JSON 校验通过。`/Applications/Kero.app` 经过同磁盘预验签整包替换、安装后严格验签，构建/安装 `kero.debug.dylib` SHA-256 均为 **df9e6354dfc71fad404ba69b5430dcc6e09427e9115674622c8b7b14b43759fd**。临时安装目录和旧包备份清理；用户正式 PID **52207** 未退出或重启，需用户自行重启才加载新版本。
- **正式本地提交 42bbb53**（14 个生产源码、测试、owner 文档与本地化文件）；F-22、F-23、F-24 已使用 `feature_tool.py finding resolve` 全部标为 `Resolved`。PR #14 已合并、Issue #2 已关闭，此次在 `crh` 上的补修不属于先前合并的 PR；分支领先 `origin/crh` 一个提交、**未 push**。`idea.md`、`plan-p4.md`、`audit-p4.md` 仍只保存在本地。

**Gate：Go（本次 Stash 图谱、真实 Git、NativeUI、独立本机 App、真实 Windows SSH 自动化、签名和磁盘安装）。** F-22～F-24 均已关闭，无新的可复现阻断项。未另行执行真实 Windows SSH **独立 App** 逐按钮 E2E，也未做 VoiceOver 专项朗读；不能把自动化或本机 GUI 验收冒充这些未执行的测试。
