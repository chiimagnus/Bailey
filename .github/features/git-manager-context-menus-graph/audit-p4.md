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
