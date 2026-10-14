# P4：按 Git Graph 真实行为补齐 Git Manager 右键菜单

**关联：** [需求](idea.md) · [当前源码和上游证据](research.md) · [Issue #2](https://github.com/chiimagnus/kero/issues/2)。
**上游基线：** [Git Graph `d7f43f4`](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812)（develop，2023-07；最新 GitHub Release 是 v1.30.0）。菜单、弹窗、默认值依次查 `web/main.ts`、`web/dialog.ts`、`src/config.ts`，最终 Git argv 查 `src/dataSource.ts`；不能只凭 Wiki 或截图猜操作语义。

**Goal：** 尽可能复制 Git Graph **对象右键 → 原生弹窗 → 用户选择 → Git 结果 → 二次询问/错误**的行为，而不是只给 Kero 加同名命令。菜单、提示、字段和按钮采用 Kero 现有 SwiftUI/AppKit 风格及中英本地化，不嵌入 Git Graph Web UI。

**Non-goals：** 不复制插件特有的 Branches Dropdown、Issue Linking、PR/Code Review Provider、Mark Reviewed、列配置、外部 Difftool 或 Source Control 跳转。通用「Compare Commit with HEAD/Ref/Merge Base」**不是**上游普通 Commit 的右键动作：从本 P4 的必需项删除，不为它另建 Diff 比较模式。VSCodium 的 Ignore 在源码中是向现有 `.gitignore` 文档追加路径并保存，Kero 必须复用普通 FileTab 完成（不建 Ignore 专用编辑器或 Git 状态/对话框框架）。上游「Create Archive」属于 Branch/Remote/Tag 菜单，须尽可能沿用原生保存；不能谎称远端二进制流已经可安全保存。

**Approach：** 保持 `RecentCommitsView.commitRow/referenceActions/changedFile` 和 `GitPanel.branchMenu/moreMenu/GitEntryRow.menu` 的原生命中；弹窗由 `GitPanel` 在**传入的发起窗口**展示，简单确认继续用 NSAlert、多个字段采用 SwiftUI 原生 sheet/Form，不建通用 DialogCoordinator；不能继续依赖 `NSApp.keyWindow ?? NSApp.mainWindow` 猜目标窗口（当前 `presentGitNameDialog` 正存在这处缺口）。Git 的执行、互斥、错误和刷新归 `GitStatusModel.perform` → `GitCommandExecution` → 当前 `WorkspaceBackend`，Tab/编辑内容由 `Project/PaneTab/DiffTab` 拥有。需要动态 Ref/Stash 保护时扩充**现有**执行前校验，不再开第二条写入/刷新通道。

**Rules：** [AGENTS.md](../../../AGENTS.md) · [Git Invariants](../../../docs/features/git.md#invariants) · [Diff Invariants](../../../docs/features/diff.md#invariants) · [Files](../../../docs/features/files.md#invariants) · [SSH](../../../docs/features/ssh.md#invariants) · [UI](../../../docs/ui.md) · [测试](../../../docs/testing.md)。
- 弹窗打开时绑定**右击目标**的窗口、项目、机器、仓库、HEAD、ref 名/OID 和必要的文件状态；确认后在原 Model 执行入口验证。服务器端 Ref 删除/Force 的预检查不能消除远端并发更新：优先使用 Git 原生 **exact-OID lease** 等服务器原子拒绝能力；服务器 Protected Branch/Tag 拒绝须原样展示，绝不更改用户远端策略。一次菜单成功不等于 Git 成功。
- Git 本身可以安全拒绝的操作不叠加猜测式禁用规则。只有对象不存在、当前正在冲突恢复、操作会破坏未保存编辑等**当前可证实**的前提才禁用或明确提示；不为所有 Git 分支/网络状态预建多层校验、retry 或 coordinator。
- 普通操作默认非 Force。Force、替换已存在 Ref、Reset Hard、Clean 和历史文件覆写**仅在原生弹窗明确选中/确认后**执行；多远端动作逐一反馈部分成功和失败。后台 Git 不得等待交互式编辑器（Merge 需要提交时明确使用非交互默认消息）；选「Interactive Rebase」就打开真正的新终端，绝不在无 TTY 的 worker 假装已完成。
- P1～P3 图谱、左右滚动、共用树行、历史 Diff、快速刷新以及正运行的 Kero 均不动。每个 task 自己完成 Red→Green、源码接入、旧路径清理、`Git.xcstrings`/`Sidebar.xcstrings` 和功能文档同步、原子提交；P4-T9 不是用来推迟实现或清理的总收尾。

## 菜单矩阵与边界

| 右键对象 | 应出现的 Git Graph 核心操作 | Kero 入口 / 不出现的条件 |
| --- | --- | --- |
| Commit 行（普通、根、Merge） | Add Tag、Create Branch；Checkout、Cherry Pick、Revert、合适时 Drop；Merge into current、Rebase current onto、Reset Soft/Mixed/Hard；复制 SHA/Subject | `RecentCommitsView.commitRow`；`Drop` 必须有可证实的拓扑可行性。**保留整行左击展开**，不加右键「展开/收起」 |
| 当前／其他本地 Branch Ref | Checkout（非当前）、Rename、Delete（非当前）、Merge/Rebase（非当前）、Push、Copy Name | `referenceActions` 及折叠 `+N`；当前分支仍能 Rename/Push |
| Remote Branch Ref | Checkout（新本地跟踪分支/同名分流）、Delete Remote、Fetch into Local（本地同名且非当前）、Merge、Pull、Copy | `remoteBranch` 也必须有原生菜单；`refs/remotes/<remote>/HEAD` 不是可删除实体 |
| Tag Ref | View Details（Annotated）、Delete（可选远端）、Push、Copy Name | Annotated/Lightweight 按 Git 对象类型判断，不凭 Badge；`+N` 行为一致 |
| Stash 条目 | Apply、Create Branch、Pop、Drop、Copy Name/Hash | Kero 目前只有 `stashCount`：在既有 GitPanel 增加紧凑可右击 STASHES 条目，不新建独立 Dock |
| Uncommitted Changes（CHANGES 标题） | Stash（Message/Include Untracked）、Reset（Mixed/Hard）、Clean Untracked（含目录选项） | Kero 没有 Git Graph 的伪 Commit，落到 `GitPanel` 现有 CHANGES 区块标题右键；保留已有 Stage/Discard |
| Staged/Unstaged/Conflict 文件、目录与标题 | 原有 Open/Diff、Stage/Unstage/Discard、分组批量动作；工作区与 Untracked 行/目录提供 VSCodium Ignore；按真实版本存在性提供读取 | Ignore 只在适用 Git 文件树对象出现，编辑目标是普通 `.gitignore` FileTab，不引入独立编辑器或未经协调的磁盘写入 |
| 历史文件 | View Diff、View File at Revision、View Diff with Working File、Open File、Reset File to Revision、Copy Absolute/Relative Path | 仅内容确实存在且文本可读时启用对应查看；`Reset File` 独立警告其对 index/worktree 的覆盖 |
| Branch/Remote Branch/Tag | Create Archive（TAR/ZIP） | 本机 NSSavePanel 选择目的地；SSH 不能把远端地址当作 Mac 本地路径，需按真实可用的二进制链路处理 |

## 原生弹窗行为合同

下表的字段、默认值、主按钮/后续分支来自上游 `web/main.ts` 与 `src/config.ts`，**是 P4 必须核对的产品行为**，不是可按实现便利删掉的附加选项。默认值采用 Git Graph 默认配置，而非继承用户浏览器/VS Code 插件的设置；只有用户在 Kero 明确保存的偏好才可更改。

| 触发项 | 原生字段与默认值 | 主按钮、取消及分流 |
| --- | --- | --- |
| Commit → Create Branch | Name 必填；**Check out=false** | **Create Branch / Cancel**；重名时 **Replace Existing Branch** 或 **Choose Another Name**（输入不丢） |
| Commit → Add Tag | Name；Type **Annotated** 默认或 Lightweight；Message（仅 Annotated 生效，可空）；Push to Remote **false/Don't push**，多 remote 单选 | **Add Tag / Cancel**；重名 **Replace Existing Tag** 或 **Choose Another Name**；确认推送后仍保留单独的本地创建结果 |
| Commit → Checkout | 警告进入 Detached HEAD；**Always Accept=false** | **Yes, Checkout / Cancel**；勾选后下次略过此确认，保留真正的 Git checkout 失败提示 |
| Commit → Cherry Pick | Merge Commit 才显示 Parent（默认第一父，可选 1…N）；**Record Origin=false**、**No Commit=false** | **Yes, Cherry Pick / Cancel**；映射 `-m`、`-x`、`--no-commit`，不能忽略勾选 |
| Commit → Revert | 普通提交无额外字段；Merge Commit 选择主线 Parent（默认第一父） | **Yes, Revert / Cancel**，实际 `revert --no-edit [-m N]` |
| Commit → Drop | 显示 Commit 与历史改写范围，无额外字段 | **Yes, Drop / Cancel**；非可 Drop 的拓扑**不显示/禁用**；不以 Revert/Reset 冒充 |
| Commit / Branch / Remote Branch → Merge | **Create Commit Even If FF Possible=true**、**Squash Commits=false**、**No Commit=false** | **Yes, Merge / Cancel**；Squash 且未选 No Commit 时按上游自动生成合并效果的 commit，而非只留 staged changes |
| Commit / Branch → Rebase | **Launch Interactive Rebase in New Terminal=false**、**Ignore Date=true**（只影响非交互式） | **Yes, Rebase / Cancel**；Interactive 必须在选定机器的新终端交互，后台模式实际执行 `rebase` |
| Commit → Reset | 单选 **Mixed** 默认，另有 Soft、Hard，各说明影响 | **Yes, Reset / Cancel**；Hard 必须是明确选择，Git 的 Untracked 保留规则如实说明 |
| Local Branch → Rename / Delete | Rename 新名默认旧名；Delete **Force Delete=false**、存在 remote tracking 时 **Delete on Remote(s)=false** | **Rename Branch / Cancel**；**Yes, Delete / Cancel**；未合并 safe Delete 失败时提供上游 **Yes, Force Delete Branch** 二次选择 |
| Local Branch → Push | 单 remote 直接显示；多 remote 多选；**Set Upstream=true**；Push Mode **Normal** 默认 / Force With Lease / Force | **Yes, Push / Cancel**；每个 remote 实际执行并记录部分成功 |
| Remote Branch → Checkout | New Local Name 默认为 remote 分支短名 | **Checkout Branch / Cancel**；同名已存在时 **Choose Another Name** 或 **Checkout Existing Branch & Pull Changes**（不是隐式覆盖） |
| Remote Branch → Delete / Fetch | Delete 无附加字段；Fetch into同名本地 Branch 时 **Force Fetch=false** | **Yes, Delete / Cancel**；**Yes, Fetch / Cancel** |
| Remote Branch → Pull | **Create Commit Even If FF Possible=false**、**Squash Commits=false** | **Yes, Pull / Cancel**；不是 Kero 顶部的 `pull --ff-only`，两种入口语义不得偷换 |
| Tag → Delete / Push | Delete：单远端 **Also Delete on Remote=false**，多远端选 **Don't Delete on Any Remote** 默认；Push：单远端确认，多远端多选 | **Yes, Delete / Cancel**、**Yes, Push / Cancel**；目标提交不在远端已知分支上时二次警告 **Proceed to Push / Cancel**，可选 **Always Proceed=false** |
| Uncommitted → Stash / Reset / Clean | Stash：Message 可空、**Include Untracked=true**；Reset：Mixed 默认 / Hard；Clean：**Clean Untracked Directories=true** | **Yes, Stash/Reset/Clean / Cancel**；Clean 是 Git Graph 的永久清理，不误称本机废纸篓 |
| Stash → Apply / Pop / Branch / Drop | Apply/Pop **Reinstate Index=false**；Branch 输入新名称；Drop 无附加字段 | **Yes, Apply Stash / Yes, Pop Stash / Create Branch / Yes, Drop**，均有 **Cancel**；选择的特定 stash 不会误用栈顶 |
| 历史文件 → Reset File to Revision | 显示 Commit、文件及工作区/索引将被覆盖的警告 | **Yes, Reset File / Cancel**；不与 View File at Revision（只读）混淆 |
| Ref → Create Archive | 原生保存面板，格式 TAR/ZIP，用户决定文件名及位置 | **Create Archive / Cancel**；文件必须真正包含所选 Ref 内容，绝不导出当前 HEAD 冒充 |

**二次弹窗是行为而不是实现细节。** 上游在 Branch/Tag 重名时给「替换 / 改名再试」，远端 Checkout 同名时给「换名称 / 切已有并 Pull」，删除未合并分支时给「强制删除」，Tag 远端不包含目标提交时给「仍要推送 / 取消」。Kero 采用同等可操作的原生按钮、提示和保留输入；不能简化成一个错误 Banner 加重试。

**真实代码的限定：** `GitStatusModel.perform` 目前只校验 repoRoot、HEAD/branch（可选 upstream），不验证任意 Ref OID 或 index/worktree；按对象增加最少必要的目标预检，不能全局新增永远不需要的检查。Git Graph `stash apply <OID>` 可用，但实测 `stash pop/drop <OID>` 被 Git 拒绝：Pop/Drop 必须用 selector 并在执行前核对它仍指向选择的 OID。现有 `DiffTab` 只会读 index/worktree 或 Commit 对第一父的 blob；要先扩展**具体**修订来源与 Tab 身份，不能直接复用旧 Diff 假装满足新菜单。

<a id="p4-t1"></a>
## P4-T1 Commit Checkout、Cherry-pick、Revert、Merge 与恢复

**结果：** Commit 的四类动作遵守上游弹窗字段、默认值和真实 Git 效果，产生冲突后能保留文件，并通过现有终端处理。

**入口 / Files：** `RecentCommitsView.commitRow` → `GitPanel.presentCreateReferenceDialog/performOperation/repositoryOperationBanner` → `GitStatusModel.perform/detectRepositoryOperation/remoteRepositoryOperation` → `GitCommandExecution`；窗口由 `ToolPanelView` 对应的 `TerminalManager` 提供。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`WorkspaceWindowIsolationTests`、`AppSettingsTests`（Always Accept 的真实偏好持久化）。

**实施：**
1. 只扩展现有 Commit `.contextMenu` 的操作回调，不覆盖整行左击与 Ref 点击。弹窗按上方矩阵保留 Checkout「Always Accept」、Cherry Pick Parent/Record Origin/No Commit、Revert Merge Parent、Merge No-FF/Squash/No Commit。沿 `ToolPanelView.manager.window` 向 `GitPanel` **显式传入发起窗口**，取代 `presentGitNameDialog` 通过全局 key/mainWindow 猜窗口的旧路径；取消或切窗口后旧 sheet 不能写到别的项目。勾选「Always Accept」由现有 `AppSettings` 持久化其真实含义（之后不再显示 Checkout 确认），不另设 UserDefaults 状态。不要在 View 层拼 Shell。
2. `GitStatusModel` 使用所选完整 SHA 与当前工作空间，后台 argv 分别为 `switch --detach`（与上游 checkout 的 detached 结果一致）、`cherry-pick [-m N] [-x] [--no-commit]`、`revert --no-edit [-m N]`、`merge [--no-ff|--squash] [--no-commit]`；产生普通 Merge Commit 时使用 Git 的非交互默认消息选项，**不能弹出或阻塞不可见编辑器**。**上游 Squash + 自动 Commit**先用临时库实测并按实际结果完成后续提交，不能以 staged 中间态冒充完成。保留多命令部分成功状态、原仓库 commit hook/签名配置与实际失败提示，不暗中绕过。
3. 现有 `repositoryOperation` 已从真实 Git 标记识别 Merge/Cherry-pick/Revert/Rebase/Bisect，`GitPanel.repositoryOperationBanner` 已提示用户可从终端恢复：这条路径足够，本阶段仅校验和修正提示文案。上游 Git Graph 自身没有额外 Continue/Abort/Skip 右键或弹窗；Kero 发生冲突后保留 index/worktree，允许用户从已有原生终端运行 Git 的 continue/abort/skip，完成后刷新。**不为菜单再造状态枚举、GUI 恢复面板或第二套状态机。**
4. 对可能改变已打开文件的操作，从当前 `Project/PaneTab` 检查未保存编辑，拒绝覆盖或让用户先保存；异步执行前沿既有 `perform` 校验当前机器/仓库/HEAD 和选中 SHA 的存在。不要把所有 dirty Git 状态一律禁用：Git 自己能拒绝的不合法合并由真实错误说明。

**Red→Green / 验收：** 正常/根/Merge Commit、父节点选择、No Commit 与 Record Origin、多种 Merge 组合、Squash 自动 commit、detached 与 Always Accept；临时 Git fixture 核对 HEAD/refs/index/worktree/commit message。制造 Cherry-pick/Revert/Merge 冲突后从现有终端执行 Continue/Abort（及 Git 允许的 Skip），验证文件、序列状态与仓库标记；NativeUI 核对字段默认值、按钮和整行/Ref 独立命中。切换项目、取消及未保存内容均不得被偷偷覆盖；不把事件触发当成验收。

**提交边界：** 四项菜单、原生选项/确认路径、现有冲突提示的必要文案调整、代码回归、Git/UI/Settings 文档及中英文字符串同一提交；清理被替代的旧菜单/回调，不新增恢复状态。

<a id="p4-t2"></a>
## P4-T2 Commit Rebase、Reset 和合法 Drop

**结果：** Reset 三模式、非交互/交互式 Rebase、Drop 具备上游的选项与效果，历史写入不能误改别的分支。

**入口 / Files：** `RecentCommitsView.commitRow`、`GitPanel` 原生弹窗、`GitStatusModel.RecentCommit.parentHashes/headOID/branch/perform`，交互式入口复用 `Project.newSession`、当前机器的 `TerminalSession.sendCommand`；冲突提示继续使用 P4-T1 核对过的现有 Banner 与终端路径。验证：`CommitGraphLayoutTests`、`GitStatusModelTests`、`RecentCommitsViewTests`、现有 Workspace/Terminal 集成。

**实施：**
1. Rebase 原生字段 **Interactive=false、Ignore Date=true**。非交互式后台运行 `git rebase [--ignore-date] <selectedSHA|ref>`；勾 Interactive 后从**发起窗口的当前 Project** 创建独立终端并执行真正的 `git rebase --interactive`，不能借用用户已有终端、假显示成功或在后台阻塞编辑器。**源码已核对：** `Project.newSession(directory:)` 在 SSH 情形通过 `makeSession` 忽略所传 `directory`，默认使用 `customDirectory ?? "/"`；`TerminalSession.sendCommand` 仅调用 `surface.sendText`，不能证明新建的 SSH Shell 已就绪。先用本机和受控 SSH 的最小实验确认 `TerminalCommandLifecycle.prompt` / 远端 readiness 信号是否可靠；若 SSH 没有 OSC 133，就沿现有 `Project.makeSession` 的 launchCommand 入口在**该新会话**绑定目标 cwd/启动命令，不靠任意 sleep 盲发。必须证明命令在所选远端 repo 的真实 PTY 中运行且编辑器可交互；冲突仍使用终端和现有 Banner。
2. Reset 弹窗 Soft/Mixed(默认)/Hard 单选与文案按矩阵，分别执行 `git reset --soft/--mixed/--hard <selectedSHA>`。Hard 明示覆盖已跟踪文件，未跟踪文件 Git 本来会保留的边界不能称为已清除；核对用户未保存 Tab 与 index/worktree，确认后在同一 Model 执行。
3. Drop 与上游 `graph.dropCommitPossible` 同样要求被选节点有父、向当前 HEAD 的路径无合并/多子分叉；再用 Git 真实祖先/ref 验证图谱分页**未覆盖的拓扑**也不会被破坏。命令语义为 `git rebase --onto <selectedSHA>^ <selectedSHA>`；只更新当前本地分支，对存在其它 Ref 依赖的历史谨慎禁用，不自动 Force Push。Root/Merge/共享拓扑不使用假的 Reset/Revert；误选、取消后没有重写副作用。
4. 与上游相同，Reset 只在用户按 **Yes, Reset** 且选定模式后执行；Rebase/Drop 失败保留 Git 错误及现有操作标记，在终端可恢复；不新增定时器、重试或 Rebase 控制器。

**Red→Green / 验收：** A→B→C→D、独立分叉、Merge、历史 Tag/远端 Ref、HEAD 与非 HEAD 的合法/非法 Drop：验证仅目标线性链被改写和其它 Ref 不变；Soft/Mixed/Hard 验证 HEAD/index/worktree 的不同结果，Hard 不删除普通 untracked；交互式 Rebase 的新终端（包括 SSH Shell 无 OSC prompt 情形）确实在目标仓库、Shell 就绪后执行，结束/冲突/取消行为可观察；NativeUI 验证两项复选框、三选一与二次确认，旧历史图仍可展开。

**提交边界：** 本组菜单、Rebase 终端接线、合法 Drop 判断及对应测试与 Git/Terminal/SSH 文档、本地化同一提交；不在最后 E2E task 才删除旧路径。

<a id="p4-t3"></a>
## P4-T3 创建 Branch 与本地 Branch 菜单、Ref Archive

**结果：** 选定 Commit 创建 Branch 的二级分流、现有 Branch 的重命名/删除/定向推送和 Archive 都按照 Git Graph 的弹窗与最终作用对象工作。

**入口 / Files：** `RecentCommitsView.createReference/referenceActions/referenceStrip`、`GitPanel.presentCreateReferenceDialog/presentGitNameDialog/branchMenu/performOperation`；`GitStatusModel.createReference/createBranch/switchBranch/push/publish/perform`；存档使用 `GitCommandExecution.runData`、`WorkspaceBackend.run` 以及已有原生文件对话框风格 `WorkspaceNativeDialogs`（只复用交互模式，不加入全局 Dialog service）。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`GitExecutionTests`。

**实施：**
1. 将 P2 的「输入名称后只能创建且不 Checkout」直接**迁移**到 Commit → Create Branch 的 Name 与 **Check out=false** 表单；已有名称时给 **Replace Existing Branch / Choose Another Name** 两条真正可用的后续路径，后者保留输入。替换只在用户明确确认后使用 `git branch -f <name> <SHA>`（随后按 Check out 选择切换），普通新建用 `git branch <name> <SHA>` 或 `git switch -c <name> <SHA>`；Git 拒绝重写当前检出/其它 worktree 的分支必须显示错误。
2. 直接展示与 `+N` 的本地 Ref 共享 `referenceActions`。当前 Branch 有 Rename、Push、Copy；其它 Branch 还包含 Checkout（不用确认，Git 自己检查工作区）、Delete、Merge into current、Rebase current onto、Copy。Rename 提供预填旧名称和 `Rename Branch / Cancel`，底层 `git branch -m old new`，重名不自动 `-M`；Merge/Rebase 复用 P4-T1/T2 的同一字段/方法。
3. Delete 弹窗有 **Force Delete=false**；已知远端存在该分支时才显示 **Delete on Remote(s)=false**。先用 `git branch -d`，如上游「not fully merged」失败，**保留选择、提示 Yes, Force Delete Branch** 才允许 `-D`；选远端删除时仅针对已勾选且列出的 remotes，先取得各远端的准确 ref/OID，以 Git 的 expected-OID lease 在服务器端拒绝确认后移动过的 ref（此真实 helper 供 T4 Remote Branch Delete 复用），逐项报告哪条已经成功。不能将本地删除成功 + 部分远端删除失败整体称为失败且未改动。
4. Push 弹窗包含 `Set Upstream=true`、`Push Mode=Normal(default)/Force With Lease/Force`；多 remote 是**多选**，支持定向非 HEAD 分支，`push <remote> <selectedBranch> [-u] [--force-with-lease|--force]`，不把顶部 `model.push()`（会 Push 当前 HEAD）当成目标 Branch Push。二次确认/错误保留已选择的 Ref；用户显式选 Force 才使用，拒绝过期 Ref。
5. 上游 Branch/Remote Branch/Tag 有 **Create Archive**：在本 task 创建一个共享、真正按传入 ref 执行 `git archive --format=tar|zip <ref>` 的原生 NSSavePanel 流程（T4/T5 只接入对应 Badge）。保存路径由用户选定；本机可直接生成临时文件后原子保存；SSH 要把远端二进制归档通过**当前** `WorkspaceBackend` 有界传回 Mac，绝不能把 Mac 保存路径交给远端 Git。**实际源码没有这个保护**：`SSHWorkspaceBackend.run` / `ProcessRemoteCommandRunner` 先积累整个 stdout；`GitCommandExecution.runData(stdoutLimit:)` 只是切掉多余字节并仍返回成功，不能检测 Archive 截断。计划采用现有 `backend.run` 在选定机器的临时文件生成 Archive（需要核对 ExitCode），再通过**已有** `backend.read(path:maxBytes:)` 有界读取，核对字节长度与容器完整性后保存至用户选定的 Mac 路径；每次正常、失败、取消都清理**本次自身**生成的远端临时文件，绝不使用 SSH Backend 的任意无上限 stdout 直接导出。初期允许明确说明并严格执行单包上限（上限数值依据实际 runner 测试选定，禁止静默截断），不另建流式传输系统或永久缓存。没有能力安全导出某大小的 Archive 时明确报超限，不提供虚假的成功按钮；服务器仍按原有 SSH 认证及超时执行。

**Red→Green / 验收：** 真实临时 Git 仓库创建/重名替换/取消/保留 Name/Checkout；当前及非当前分支 Rename/安全 Delete/提示后 Force Delete，两个 bare remotes 的 Delete on Remote(s) 及部分成功；Push Normal/Force With Lease/Force、Set Upstream、多远端选择核对 **服务器实际 refs** 与 upstream 配置。Tag 不在本 task 新增菜单，但共享 Archive 用 Branch Ref 验证 TAR/ZIP 实际条目内容、取消无文件、远端完整二进制与严格上限、失败/超限时本地无损坏文件且只清理本次远端临时文件。原生菜单 `+N`、异常分支名与窗口焦点测试，受影响文档同一任务同步。

**提交边界：** Branch 创建旧单字段弹窗和旧执行路径直接替换；Branch Ref 与通用 Archive 所需的 Git/原生保存接线、测试及 Git/SSH/UI 文档、本地化一起提交。拒绝为 Archive 增加长期新 Service 或单独网络传输协议。

<a id="p4-t4"></a>
## P4-T4 Remote Branch 的 Checkout 分流、Fetch、Merge/Pull、删除

**结果：** 远端 Badge 不再只是只读文本；Remote Branch 每项使用 Git Graph 相同的选择与后续动作，操作的是真正 remote/ref，而非当前 HEAD 或同名 Mac 仓库。

**入口 / Files：** `GitStatusModel.RecentCommit.Reference(.remoteBranch)` / `parseCommitReferences`、`remotes/branches/fetch/pull/perform`；`RecentCommitsView.referenceBadge/referenceActions/+N`、`GitPanel`；`GitCommandExecution` → `SSHWorkspaceBackend`（远端 argv 引用）及 P4-T3 `Create Archive`；`GitStatusModelTests`、`GitExecutionTests`、`RemoteCommandsTests`、`RecentCommitsViewTests`。

**实施：**
1. 对照已配置 `remotes`，以**完整** `refs/remotes/<remote>/<branch>` 解析身份，处理含斜杠的 remote/branch，不能按字符串中第一个 `/` 盲切；`refs/remotes/<remote>/HEAD` 是 symbolic ref、不可当作普通 Branch。原有 `remoteBranch` 胶囊改为按钮与独立右键，`+N` 调相同菜单，保留标签左击不展开 Commit。
2. Checkout Branch 弹窗预填 remote 后的分支名，新名时创建本地跟踪分支并 Checkout；同名本地 Branch 已存在时必须提供**Choose Another Name**（带原输入重开）或 **Checkout Existing Branch & Pull Changes**（先切换再针对所选 remote/branch Pull，使用 P4-T4 同样的默认 Pull 参数）。不能把同名情况直接抛成「名字已存在」错误，不能隐式覆盖。
3. Fetch into Local Branch 只在同名本地分支存在且不是当前分支时出现；复选 **Force Fetch=false**，普通尝试快进，选中时执行上游 `git fetch -f <remote> <branch>:<local>`，仍遵守 Git 对其它 worktree 正检出分支的禁止条件。Merge into current 直接复用 P4-T1 的 No-FF/Squash/No Commit 表单。
4. Pull into current 提供 **Create New Commit Even If Fast-Forward=false**、**Squash=false**，以明确 remote/branch 执行 `git pull <remote> <branch> [--no-ff|--squash]` 及上游成功后的 Squash Commit 结果；**不走**顶栏的 `model.pull()`（它特意是 `--ff-only`）。同一项目两个菜单行为各自正确，失败由真实 Git 决定。
5. Delete Remote Branch 只确认选中的 remote + branch；复用 P4-T3 已实现的定向服务器删除语义，不另造执行器。确认时固定该 remote/ref 在服务器上的实际旧 OID，使用 `git push --force-with-lease=refs/heads/<branch>:<oldOID> <remote> :refs/heads/<branch>` **原子拒绝**确认后移动过的 Ref（lease 是保护条件，不代表用户允许覆盖新的远端 Ref）；服务器的 `receive.denyDeleteCurrent` 等保护拒绝须原样提示，不修改远端设置。目标 ref 已不存在时，上游允许删除对应本地 remote-tracking ref：也必须检查同一仓库和跟踪 OID，不能删除其它分支。成功或部分成功均刷新；Create Archive 复用 T3 的选中远端 Ref。

**Red→Green / 验收：** 两个 bare remotes 含同名不同 SHA、旧 OID 的服务器端删除拒绝、远端默认分支删除保护、`origin/HEAD` 与嵌套分支，逐项确认 Checkout 新分支及重名两按钮、Fetch 普通/Force、本地当前分支拒绝、Merge/Pull 的 No-FF 与 Squash、远端 Delete 与失效追踪 ref 清理；用 `ls-remote`、`for-each-ref`、index/worktree 检查真实结果。原生菜单在直显/`+N` 一致，SSH 受控后端证明机器和 argv 无串仓库，真实 SSH 留 P4-T9。

**提交边界：** 远端 Ref 从「只读标签」迁移为真菜单，复用既有 Fetch/Pull/Archive 而不创建第二个操作模型；实现、验证和文档/本地化同一提交。

<a id="p4-t5"></a>
## P4-T5 Tag 的 Annotated/Lightweight、重名替换、Push 与删除

**结果：** Tag 创建、View Details、Delete、Push 的每个字段、二次提醒和部分成功行为均符合 Git Graph，而不是「只能建轻量 Tag，操作另加一个确认」。

**入口 / Files：** `RecentCommitsView.createReference/referenceActions/+N`，`GitPanel.presentCreateReferenceDialog`；`GitStatusModel.createReference/perform/remotes`、`RecentCommit.Reference(.tag)`；按需 `git cat-file/for-each-ref/ls-remote`；共享 Archive 由 P4-T3 提供。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`AppSettingsTests`（Always Proceed 的保存与恢复）。

**实施：**
1. 直接替换 P2 的轻量 Tag 专用名称框。Commit → Add Tag 原生表单：**Name**、**Type=Annotated(default)/Lightweight**、**Message=Optional（仅 Annotated 用）**、**Push to Remote=false**（单 remote checkbox、多 remote 单选默认 Don't Push）；添加到选定完整 SHA，不自动改变 HEAD。已同名时**Replace Existing Tag** 或 **Choose Another Name**，后者保留所有字段；Replace 必须用户确认，`git tag -f` 覆写**本地目标 ref**，无自动强推。
2. Tag 胶囊需要区分 Git **annotated tag object** 与 lightweight ref；`RecentCommit.Reference` 当前只有 Kind/Name，不能凭 `commit.hash` 判断 Tag 类型。沿现有 `runGitStatus/prefetchedSnapshotCommands` 的**同一状态快照**加入一次轻量 `for-each-ref refs/tags` 的对象类型/Ref OID 数据（远端纳入已有 batch，而不是每个 Badge 各发 SSH 查询）；不预取 Tag 注释全文。只有 annotated 的菜单显示 View Details，点击后按需查询 Tagger/Message/Tag object SHA/peeled Commit；`+N` 复用相同类型与菜单。
3. Delete Tag：无 remote 直接确认只删本地；单 remote 显示 **Also Delete on Remote=false**；多 remote 显示 **Don't Delete on Any Remote（默认）/指定一个 remote**。用户选远端时按上游先执行该远端指定 Tag 的 Delete，再删除本地 Tag；任一失败保留实际错误及局部修改结果，不捎带其它同 SHA 的 Tags。指定远端 Tag 删除与 Branch 一样需用服务器原生 expected-OID lease 拒绝误删确认后已移动的 Tag；用户远端自己的 Protected Tag/Hook 拒绝不绕过。
4. Push Tag：单 remote 确认，多 remote 多选并对每一个执行所选 `refs/tags/<name>` 的定向 Push，不 `--tags`；若目标 Commit 不在该 remote 已知分支上，按上游给出独立二次弹窗 **Proceed to Push / Cancel** 和 **Always Proceed=false**，用户选后才推；勾「Always Proceed」的持久化复用 `AppSettings` 的同一设置/保存 owner（字段独立于 T1 的 Always Accept），不额外添加 Tag 专用状态容器。不能把 annotated Tag 对象 ID 与 peeled commit ID 混淆，也不能把「Tag 本地创建成功、远端推送失败」当成全部失败/自动回滚。
5. Tag 的 Create Archive 接 P4-T3 共享实现；新建 Tag 对话框仍归原 `GitPanel`，不另建 Tag ViewModel/Release 页面。增补真正需要的 Ref OID 核对与重名处理，取消/切仓库/旧 remote 不写错；清理旧轻量 `createReference(.tag)` 分支与重复 UI。

**Red→Green / 验收：** 临时仓库含 lightweight/annotated 两种同 Commit Tag、包含标点的合法名称；验证默认 Annotated、附注、替换/重新输入分流、创建时不改变 HEAD、单/多 remote 推送与不推送、Delete Local/Also Remote、Tag 目标变化、Push 目标提交不可达远端的 Proceed 警告、只有用户明确选择时覆盖。核对 `cat-file -t`、`show-ref`、`ls-remote --tags`、提示按钮和 Git index/worktree；Archive Tag 内容正确，NativeUI 真菜单和 `+N` 一致。

**提交边界：** 原轻量 Tag 新建路径直接迁移为完整表单，Tag 读/写和后续提示、测试与 Git/UI/Settings 文档、中英字符串同一提交；不保留两套创建方式。

<a id="p4-t6"></a>
## P4-T6 历史文件 View / Diff / Reset 的完整菜单与真实 Tab

**结果：** 历史文件右键复制 Git Graph 的读版本、比较工作区及**带警告的覆写**，使用真实版本内容，不能把「查看」做成修改当前文件。

**入口 / Files：** `RecentCommitsView.commitFiles/changedFile/displayRow` → `ToolPanelView.openCommitDiff/openFile` → `TerminalManager.openCommitDiff/openFile` → `Project.openCommitDiff/openFile/findDiffTab` → `DiffTab.reload/gitContent/readWorktreeFile`、`WorkspaceBackend`；`GitStatusModel.RecentCommit.FileChange.originalPath/parentHashes`。验证：`DiffTabTests`、`RecentCommitsViewTests`、`WorkspaceContentIdentityTests`、`GitStatusModelTests`。

**实施：**
1. 上游 Commit Details File 右键是 **View Diff、View File at this Revision、View Diff with Working File、Open File、Reset File to this Revision…、Copy Absolute/Relative File Path**；普通文件 Diff 已存在，直接保留。只在版本 blob 确实可读时显示「查看修订」和「与工作区比较」，Deleted 文件不能冒充选中 SHA 中仍存在。重命名和 Copy 的前后路径分别按 `originalPath/path` 解释，root/merge 的历史 Diff 与当前已有第一父规则一致。
2. `DiffTab.reload` 目前只支持「历史 commit^ → commit」或「HEAD/index/worktree」；在**现有 DiffTab** 增加确需的三种来源：「仅显示选定 Revision 的只读原文」「Revision blob ↔ 当前工作区」「历史两侧 Diff」。**View File at Revision 应是只读原文视图，不是把整个文件画成全新增的假 Diff**，可直接复用现有原生 TextKit 内容。根据 `Project.findDiffTab` 的真实 Key 同步包含比较来源/目标，避免同一 `commitHash + path` 错误复用不同模式的 Tab；不建另一套文件预览缓存/全局 Diff 引擎。继续使用 5 MiB/UTF-8/二进制限制和 Tab 的机器/断线/dirty 身份。
3. 「Open File」使用当前 Project 的普通 FileTab，只访问**当前工作区路径**，但上游 `src/utils.ts.openFile` 和 `viewDiffWithWorkingFile` 都会在历史文件旧路径已不存在时，通过 `dataSource.getNewPathOfRenamedFile` 尝试从选定 Commit 到当前工作区追踪 Rename：Kero 的 Open File 应打开找到的真实现行路径，Revision ↔ Worktree 比较也必须使用同样的新路径；最终找不到文件时按上游区分「Open File 报不存在」与「Diff 的 working 一侧为已删除」，不能默默打开另一同名文件。Kero 应按这条**按需**解析的成功/失败分支操作，不能把所有历史路径直接当当前文件，也不为跟踪重命名预建全历史索引。远端只由其 Backend 打开，不能调用 Mac Finder。「Copy Absolute」是选定 repoRoot + Git 相对路径（SSH 为远端绝对路径），「Copy Relative」只复制相对路径；目录只提供对应的复制动作。
4. 「Reset File to this Revision…」显示明确 **Yes, Reset File / Cancel** 和 SHA/路径/索引及工作区覆盖范围。底层选定 `git checkout <fullSHA> -- <literalFilePath>`（如适用配合 `--literal-pathspecs`），这是**同时影响 index 和 worktree**的真实复位，不是只恢复编辑器文本。确认和发命令前重新核对该文件真实工作区状态；若相同路径在当前 Project 的 FileTab/DiffTab 存在未保存编辑，阻止静默覆盖并通过已有保存保护引导用户处理；操作结束后正确更新/重载干净 Tab，不用新标签掩盖旧脏缓冲。

**Red→Green / 验收：** Git 临时库包含 Added/Deleted/Renamed/Copied、根提交、Merge 文件、多版本同名路径、文件超过 5 MiB、NUL/坏 UTF-8、SSH 模拟路径；比较实际 blob bytes 而不把缺失 blob 解释为无变化。NativeUI 从历史文件菜单进入：View Revision 是真实只读原文、Revision ↔ Worktree 的左右内容正确且能处理改名/工作区已删除，普通 Open 打开当前工作区文件且历史路径被改名时按需追踪新路径、复制两种路径准确；Reset File 取消零副作用、确认后 Git index/worktree 同时变更、未保存编辑不丢；重复打开不同模式必须生成/复用**正确** DiffTab 且保留原生视图身份。共享树整体仍不横向移动。

**提交边界：** 与历史文件菜单同一 task 补齐真实 `DiffTab` 来源及 Tab Key、Git 文件复位、测试和 [Git](../../../docs/features/git.md)/[Diff](../../../docs/features/diff.md)/[Files](../../../docs/features/files.md)/[Editor](../../../docs/features/editor.md) 文档；删除被替换的特殊分支，不造独立 RevisionViewer。

<a id="p4-t7"></a>
## P4-T7 Uncommitted Changes 弹窗与工作区 Git 文件/分组菜单

**结果：** Git Graph 的未提交改动三项操作能从 Kero 的现有分组右键使用，VSCodium 的 Stage/Unstage/Discard 文件菜单仍准确保持原有分组语义。

**入口 / Files：** `GitPanel.changeList` 的 MERGE/STAGED/CHANGES 区块标题 `PanelSectionHeader`、`changedFileRows/row/GitEntryRow.menu`，共享 `TreeFolderRow/TreeFileRow`；`GitStatusModel.stash/stage/unstage/stageAll/unstageAll/discard/discardChanges/prepareLocalDiscard/prepareRemoteDiscard`；`GitStatusModel.perform`。验证：`GitStatusModelTests`、`TreeRowHitTestingTests`、`RecentCommitsViewTests` 或现有同层 Git 原生窗。

**实施：**
1. Git Graph 把 Uncommitted Changes 当伪 Commit：其右键提供 **Stash uncommitted changes…**（Message 可空、Include Untracked=true）、**Reset uncommitted changes…**（Mixed 默认/Hard）、**Clean untracked files…**（Clean Untracked Directories=true）。Kero 不另加伪提交或独立区块：把这组菜单挂在**当前存在的** CHANGES/STAGED/MERGE 区块标题右键，并从既有 More Menu 提供一致入口（只有 staged 变化时仍能打开）；不复制不同的 `stash(includeUntracked: true)` 和「盲 Reset」按钮。Stash 仅扩展原方法接受可选 message。
2. Reset Mixed 使用 `git reset --mixed HEAD`：取消暂存而保留 working；Hard `git reset --hard HEAD`：丢弃已跟踪的 index/worktree 修改，普通未跟踪文件不被它自动删除；在无 HEAD（unborn repo）时没有该菜单。原生确认呈现两种效果，不默认 Hard；复用 P4-T2 的真实 Reset Model 方法及工作区未保存保护。
3. Clean 使用上游 `git clean -f[d]` 的**永久删除语义**，不能把它谎称为本机 Move to Trash，也不能把 Kero 原本逐文件的 Discard/Trash 悄悄改成永久删除。原生确认明确是否包含目录及永久删除的影响，保持上游 **Yes, Clean / Cancel** 单次确认，不为 Clean 新增另一个预览状态机；执行前核对当前机器与仓库，清理范围按 Git 原生语义。取消不执行，远端通过当前 Backend 执行，没有 Mac 同名路径兜底。
4. MERGE 仍只对真正冲突文件提供 Open Conflicted File/Mark Resolved，STAGED 继续 Open Diff/Unstage 且补上 VSCodium 原有的 **Open File / Open HEAD File**（有 HEAD blob 时）；CHANGES 仍可 Stage/Discard/打开文件，并按存在的 HEAD/index blob 复用 P4-T6 的只读版本查看入口。分组/目录右键复用现有单文件/批量 Model 动作，不重新实现文件树与 hover，过滤时不能把“当前可见部分”误当全部而批量丢弃。Tree 目录批量操作基于显式所选路径集，不能简单使用全仓 `stageAll`。本机 per-file 删除仍按原 `PendingDiscard` 与 Trash；SSH 删除仍必须走原审核且是远端永久删除。
5. **补齐 VSCodium 真实 Ignore，不建第二个编辑器**：微软 Git 扩展的 `repository.ignore` 在源码中打开仓库根 `.gitignore`，将所选工作区/Untracked 文件或目录的 Git 相对路径逐行追加至文档，随后保存。Kero 用**当前 Project 的普通 FileTab**承载该编辑；已核对 `FileTab.text` 是 `@ObservationIgnored`、`SourceTextEditor.Coordinator` 持有正在显示的 STTextView，单纯 `file.text += ...` **不会刷新已挂载的原生编辑器**。在 `FileTab`/其现有 `SourceTextEditor.Coordinator` 之间增加最小的「在现有原生缓冲尾部插入文本」动作，走原 `refreshDirtyState()` 与 `save()`；避免替换整个编辑器、丢失 undo/光标或双份内容。远端 FileTab 初始 `.loading` 必须等实际 `content == .text` 和初始读取完成才能追加，`.unavailable`/断线/保存失败要明确保留或拒绝；若 `.gitignore` 已有未保存修改，必须直接在**同一个**缓冲追加并保留原文，不能另起 Backend 写入压过用户文本；若文件不存在，复用已有创建文件→打开流程。路径按 Git ignore 规则处理反斜杠和 `[` 等字符，保持旧规则、换行和换行结束；不能碰其它机器同名路径。不存在一个名叫 Ignore 的另行维护状态机，也不做只在编辑器选区有效的 Stage Selected Ranges。共享树布局、点击、短文本不回弹、长文本可滚动、右侧按钮固定仍复用现有组件。

**Red→Green / 验收：** 临时 Git 仓库覆盖只有 staged、只有 unstaged、同路径 staged+unstaged、untracked 文件及目录、Merge 冲突、改名、无 HEAD、变更过滤后批量动作、特殊路径。Stash Message/IncludeUntracked 直接核对 `stash list` 和工作区；Reset Mixed/Hard 核对 index/HEAD/工作区；Clean 取消/确认的实际作用路径、目录开关/远端命令；现有 Discard 仍按本机 Trash/SSH 删除审核执行；Ignore 在 `.gitignore` 无文件、已有规则、已挂载原生 STTextView、SSH 仍处于 `.loading` 及已有未保存文本时按真源追加并保存，不能空读覆盖或绕过原生编辑缓冲；失败后原文、undo 与脏状态不丢。NativeUI 在真实分组、目录和文件**右键**操作，额外验证 Staged 的 Open HEAD File 正确只读、无 HEAD 时不误开，其他各区 hover 与菜单动作一致，键盘/VoiceOver 和共享树滚动回归。

**提交边界：** 原有 More Menu 的盲 Stash 行为直接替换成相同表单（仅语义明确的 Pop Latest 快捷键留给 T8）；新增 Uncommitted/分组文件菜单、VSCodium Ignore、回归以及 Git/Files/Editor/UI 文档同一提交。不在最后统一清理多余菜单分支。

<a id="p4-t8"></a>
## P4-T8 逐条 Stash 的 Apply、Pop、Branch、Drop 与右键

**结果：** Git Manager 可看到并右击**具体** Stash，所有原生弹窗选项和操作对象与 Git Graph 相同。

**入口 / Files：** `GitStatusModel.stashCount/runGitStatus/perform/stashPop`，`GitPanel.moreMenu/changeList`、`PanelSectionHeader`、现有树行风格；`WorkspaceBackend`。测试：`GitStatusModelTests`、原生 Git Panel 测试。

**实施：**
1. 在 GitPanel 中增加最小 STASHES 折叠行区域（不独立 Dock，不修改 Recent Commits 的真实 DAG）：读取各条 `stash@{n}`、原始 OID、说明，使用现有 Model 在需要显示时按需加载；每条有原生 `.contextMenu`：Apply、Create Branch from Stash、Pop、Drop、Copy Stash Name/Hash。刷新/成功操作使旧列表失效，不为同一条 Stash 另建全局缓存、ViewModel 或定时轮询。
2. Apply 与 Pop 分别有 **Reinstate Index=false** 复选，真正带/不带 `--index`；Apply 不移除 Stash，Pop 仅成功应用后移除，冲突时仍保留 reflog。Create Branch 先输入名称，真实 `git stash branch <name> <selector>` 会**Checkout 新 Branch 并恢复变更**、成功后可能移除原 Stash；Drop 的 **Yes, Drop/Cancel** 只移除选定的条目。
3. **必须保留 selector + OID 两种含义。** 临时真实 Git 证明 `stash apply <OID>` 可执行，但 `stash pop/drop <OID>` 返回 `not a stash reference`；因此本项目的 Pop/Drop 传 `stash@{n}`，在**同一个** `GitStatusModel.perform` 开始 Git 命令前核对 reflog selector 当前 OID 等于菜单打开时的 OID。序号因新 Stash 移动时拒绝操作并提示重新选择；不依赖仅有的 `stashCount` 作身份。
4. 既有 More Menu 的 `stashPop()` 若保留，明确叫 **Pop Latest Stash**，使用相同执行语义/可选 Reinstate Index，不造成两个不同的同名「Pop Stash」。操作前保护用户未保存编辑，不在选择 Stash 失败时用 Hard Reset 清理 Git index。兼顾远端连接和机器身份。

**Red→Green / 验收：** 至少两个不同内容的真实 Stash，分别 Apply/Pop（有/无 `--index`）、Branch、Drop：核对 `stash list/reflog`、HEAD、新 Branch、index/worktree 和冲突；对话框打开后插入或删除另一 Stash，旧 selector 不得误删另一条；取消、新名重复、远端连接变化零错误副作用。NativeUI 每行右键显示正确名称及按钮，More Menu Pop Latest 语义清楚，窗口/项目切换与 VoiceOver 不串目标。

**提交边界：** 原 `stashCount` 只作数字展示的缺口按需补成可读条目、菜单、模型复用、测试与 Git/UI/本地化文档；移除旧的含混 Pop 路由，不保留两套 Stash 执行器。

<a id="p4-t9"></a>
## P4-T9 全对象弹窗、真实副作用与本机/SSH 用户路径验收

**结果：** 以实际菜单 → 弹窗 → 每个按钮 → Git 持久结果验收 P4-T1～T8；上游适用项不遗漏，未覆盖的环境明确写明而不假称通过。

**入口 / Files：** `ToolPanelView → GitPanel → RecentCommitsView / GitEntryRow / PanelSectionHeader`、当前 `ContentView/TerminalManager/Project` 的窗口和机器绑定；`GitStatusModel → GitCommandExecution → WorkspaceBackend`；`DiffTab/PaneTab` 生命周期；现有 `KeroTests/NativeUI/Git/`、`KeroTests/Integration/Git/`、`KeroTests/WorkspaceUI/`。实测证据落在本 feature 的 `evidence-p4.md`（实施时才建立；这里不预建），最终审计由相应 Skill 创建，不用旧 `audit*.md` 下结论。

**步骤：**
1. 对照 [菜单矩阵](#菜单矩阵与边界) 与 [弹窗行为合同](#原生弹窗行为合同) **逐格**核验：Commit Root/Merge/Head，当前与非当前 Branch，Remote HEAD 和多 remote，Tag 两类型与折叠 `+N`，Stash 各序号，Uncommitted 标题、Staged/Unstaged/Conflict 文件、历史文件、Archive。检查默认字段、禁用理由、键盘焦点、主/次按钮、二次询问、取消和保留输入；不是只测 `perform` 被调用。
2. 使用临时 Git 仓库与两个 bare remotes，从真实菜单触发各种模式，核对 HEAD/refs/index/worktree、Stash reflog、Tag 注释、提交消息、Archive TAR/ZIP 内容以及服务端 Ref。显式覆盖：Branch/Tag 重名两按钮、Force With Lease/Force、Merge No-FF/Squash/No Commit、Cherry Pick -x/No Commit、Rebase Interactive、Reset 三模式、Drop、Tag Proceed to Push、Reset File、Clean Untracked、Stash selector 移位。所有部分成功与取消都要真实核对。
3. 按 [测试隔离](../../../docs/testing.md#隔离环境) 使用独立 Debug App 检查真右键和原生弹窗，不启动/结束用户正式 Kero。获授权的**专用** Windows SSH 测试连接和远端临时库另外实测；不能复用用户正在工作的 SSH master、修改正式仓库或在断线后落回 Mac。远端的 Push/Delete/Archive/Reset File 必须验证目标机器上的实际结果。缺 SSH 条件时只报告本机 Gate，P4 不冒称「SSH 全部验收」。
4. 按各 task 已有回归先 Red→Green，最终运行实际发现的相关 XCTest、`make test`、`make build` 与严格签名；对 P1～P3 图谱、历史分页、横向回弹、文件树、焦点、多窗口、Local/SSH 刷新保持回归。**P4-T9 只能修实测遗漏并回到原 task 的源码/测试/文档归属，不把被替代代码的删除或必要新增测试留到本 task。** Issue #2 的 SSH 外部刷新缺口仍需单独证据，不因菜单完成自动 Close。

**提交边界：** 以用户路径证据和完成判断为交付；只有本地证据而无源码变化时在 `todo.toml` 记 `no_commit_reason`。实际缺陷归还所属 task 同步修改并提交，保留严格 Task/Commit 对应；所有 P4 功能完成且真正审计通过后才可收 Gate。
