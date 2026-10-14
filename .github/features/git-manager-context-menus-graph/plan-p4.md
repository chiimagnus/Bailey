# P4：按 Git Graph 真实行为补齐 Git Manager 右键菜单

**关联：** [需求](idea.md) · [当前源码和上游证据](research.md) · [Issue #2](https://github.com/chiimagnus/kero/issues/2)。
**上游基线：** [Git Graph 固定提交 `d7f43f4`](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812)。菜单、弹窗、默认值依次查 `web/main.ts`、`web/dialog.ts`、`src/config.ts`；Git argv 查 `src/dataSource.ts`，多步操作顺序还必须查 `src/gitGraphView.ts`。不依赖“最新版本”的浮动描述，不凭 Wiki 或截图猜操作语义。

**Goal：** 尽可能复制 Git Graph **对象右键 → 原生弹窗 → 用户选择 → Git 结果 → 二次询问/错误**的行为，而不是只给 Kero 加同名命令。菜单、提示、字段和按钮采用 Kero 现有 SwiftUI/AppKit 风格及中英本地化，不嵌入 Git Graph Web UI。

**Non-goals：** 不复制插件特有的 Branches Dropdown、Issue Linking、PR/Code Review Provider、Mark Reviewed、列配置、外部 Difftool 或 Source Control 跳转。通用「Compare Commit with HEAD/Ref/Merge Base」**不是**上游普通 Commit 的右键动作：从本 P4 的必需项删除，不为它另建 Diff 比较模式。VSCodium 的 Ignore 在源码中是向现有 `.gitignore` 文档追加路径并保存，Kero 必须复用普通 FileTab 完成（不建 Ignore 专用编辑器或 Git 状态/对话框框架）。上游「Create Archive」属于 Branch/Remote/Tag 菜单，须尽可能沿用原生保存；不能谎称远端二进制流已经可安全保存。

**Approach：** 保持 `RecentCommitsView.commitRow/referenceActions/changedFile` 和 `GitPanel.branchMenu/moreMenu/GitEntryRow.menu` 的原生命中；弹窗由 `GitPanel` 在 `ToolPanelView.manager.attachedWindow` 提供的**发起窗口**展示，简单确认用 NSAlert，多个字段用原生 sheet/Form 或 NSAlert accessory，不建通用 DialogCoordinator；删除 `presentGitNameDialog` 的全局 key/mainWindow 猜窗口路径。Git 的执行、互斥、错误和刷新归 `GitStatusModel.perform` → `GitCommandExecution` → 当前 `WorkspaceBackend`，Tab/编辑内容由 `Project/PaneTab/DiffTab` 拥有。展示层传递用户选择，Model 编排 Git 的条件分支，不让 View 拼命令或处理 Git 业务错误。

**Rules：** [AGENTS.md](../../../AGENTS.md) · [Git Invariants](../../../docs/features/git.md#invariants) · [Diff Invariants](../../../docs/features/diff.md#invariants) · [Files](../../../docs/features/files.md#invariants) · [SSH](../../../docs/features/ssh.md#invariants) · [UI](../../../docs/ui.md) · [测试](../../../docs/testing.md)。
- 弹窗打开时绑定**右击目标**的窗口、Project 与现有 `PanelContext` 身份、机器和仓库；不能到确认时才从已变更的 Model 抓取“原目标”。会修改当前 HEAD 的动作捕获并核对 HEAD/branch，替换/删除本地 Ref 核对被确认的 Ref，Stash 核对 selector/OID，文件覆写核对该文件。不可变 Commit SHA 不另设 OID 状态。沿现有 generation/backend 失效机制检查确认及预检后的首次副作用，不新增并行的身份或锁管理器。
- 远端删除按用户确认的 **remote + 完整 Ref 名**执行 Git 原生删除；删除动作不额外强制 `ls-remote`、expected-OID lease 或网络二次确认。Push 的三模式严格映射普通 Push、原生 `--force-with-lease`、`--force`，不把刚查到的服务器 OID 当 lease 基线而绕过其拒绝含义。服务器保护/Hook 拒绝原样展示，绝不修改远端策略。
- Git 本身可以安全拒绝的操作不叠加猜测式禁用规则。只有对象不存在、当前正在冲突恢复、操作会破坏未保存编辑等**当前可证实**的前提才禁用或明确提示；不为所有 Git 分支/网络状态预建多层校验、retry 或 coordinator。
- 普通操作默认非 Force。Force、替换已存在 Ref、Reset Hard、Clean 和历史文件覆写**仅在原生弹窗明确选中/确认后**执行；多远端动作逐一反馈部分成功和失败。后台 Git 不得等待交互式编辑器（Merge 需要提交时明确使用非交互默认消息）；选「Interactive Rebase」就打开真正的新终端，绝不在无 TTY 的 worker 假装已完成。
- P1～P3 图谱、左右滚动、共用树行、历史 Diff、快速刷新以及正运行的 Kero 均不动。每个 task 自己完成 Red→Green、源码接入、旧路径清理、`Git.xcstrings`/`Sidebar.xcstrings` 和功能文档同步、原子提交；P4-T9 不是用来推迟实现或清理的总收尾。
- 只读查询、Archive、无需 Checkout 的 Branch/Tag 创建不因无关 HEAD 变化失败，按需使用已有 `requiresStableHead: false`；不能为“统一安全”让每种动作都重复检查整个 index/worktree。保留机器/仓库隔离、真实未保存编辑、破坏性确认、argv/literal pathspec 与 Archive 有界读取，不能把这些数据边界当作多余围栏删除。

## 执行前审查结论（2026-10-14）

本节记录执行前从源码重新建立的问题证据，不读取或引用旧 `audit*.md`，不代表当前实现状态。实时任务状态见 `todo.toml`，实际执行与验证见 `evidence-p4.md`；以下仍保留为同任务修复和清理的依据。

| 已确认的问题 | 源码依据与修订归属 |
| --- | --- |
| `manager.window` 是 private，真实可用入口为 `attachedWindow`；Model 不知道 Project ID | `TerminalManager.attachedWindow`、`Project.panelContext/matchesPanelTarget`、`GitStatusModel.perform`；T1 接入发起 Project/窗口，预检后再核对，后续任务复用 |
| 原 `perform` 只有静态 argv 数组及成功 Bool，不能直接表达条件 Squash Commit、上游错误分流和多远端各自的停止规则 | `GitStatusModel.perform/CommandBatchResult`；T1 在此最小扩展条件步骤/实际结果，T3～T5 复用，不另建 executor 或反复退出互斥后接命令 |
| Drop 额外禁止 Tag/远端 Ref 依赖不符合上游 | `web/graph.ts.dropCommitPossible` 只检查父、Merge、子分叉和 HEAD 路径；T2 删除“有其它 Ref 就禁用”，保留真实拓扑检查 |
| SSH 新终端不仅丢 directory；自动跟随 SSH 的 Project 若 `sshHost == nil`，`newSession` 还会开本机 Shell | `Project.newSession/makeSession`、`TerminalSession.init/makeLaunchScript`、`RemoteConnection`；T2 按捕获的机器/cwd 启动命令，不在本机等待远端 prompt |
| 本地 Branch 删除不是任意勾选 remotes；与 Push 的遇错策略也不同 | `web/main.ts.getBranchContextMenuActions`、`src/gitGraphView.ts` 的 `deleteBranch`、`dataSource.pushBranchToMultipleRemotes`；T3 单复选覆盖所有列出的同名 tracking remotes，本地删除成功后逐个尝试；Push 首错停止 |
| 多 remote Push 缺默认选择及 Set Upstream 的最后成功目标 | `web/main.ts.getPushRemote`；T3/T5 按 Git config 与 origin/首个 remote 决定默认，不能默认全选或空选 |
| Squash 后不能无条件 Commit；No Commit 未选 No-FF 时仍可能快进 | `dataSource.merge/pullBranch/commitSquashIfStagedChangesExist`；T1/T4 检查 staged 差异才提交，并采用上游默认消息，不强加 No-FF |
| Archive 经本机 `backend.run(["git", …])` 会绕过已有登录环境且相对 executable 不符合本机后端契约 | `GitCommandExecution.runData`、`LocalWorkspaceBackend.runSync`；T3 的 Git 生成步骤必须走 GitCommandExecution，backend 仅承担临时文件/有界读取 |
| 新 Diff 来源只改 `reload` 不够：只读原文会被 No Changes 隐藏，Revision↔Worktree 不会选中刷新，恢复会退回旧历史 Diff | `DiffViewerView.body`、`DiffNativeSurface.render`、`DiffTab.refreshWhenSelected`、`TerminalManager.contentSnapshot`、`Project.makeContent`；T6 同任务接通呈现、刷新、身份与当前快照 |
| `gitContent` 将所有 Git 失败当 missing，读取失败可以被解释成空白/全删 | `DiffTab.gitContent/firstGitContent`；T6 区分预期缺侧与真实读取失败，不给新入口继承假成功 |
| `PanelSectionHeader` 自己已有 contextMenu；把新 actions 加进去还会多出 hover 按钮 | `PanelSectionHeader.body`；T7 扩展同一菜单的仅菜单项，不嵌套另一 contextMenu，不改变标题左击和 hover 工具 |
| 关闭保存 helper 会删 Tab，不能拿来作 Git 前置保存 | `Project.saveBeforeClosing/confirmCloseUnsaved`；T1 用 `PaneContent.save()` 等待在途保存并复查，失败留 Tab，不借用关闭副作用 |
| Stash Branch 也会删除 selector 对应的 stash | `dataSource.branchFromStash`；T8 与 Pop/Drop 一起校验 selector/OID，不只保护两个按钮 |

**本轮隔离 Git 实验：** Drop B 后指向 B 的 Tag 保持不变；`merge --no-commit` 在可快进时确实前移 HEAD；Squash 第二次无 staged 差异，不应创建空 Commit；Reset Hard 保留普通 untracked，却会删除阻挡目标 tracked 路径的 untracked 目录；Annotated Tag 可用 `-m ""` 非交互创建；所选 SHA 的 ZIP 只含该版本文件。命令在本轮 `/tmp` 临时库执行，不触及用户仓库、App 或 SSH。这些只证明 Git 语义，不是 Model/NativeUI/E2E 通过。

## 菜单矩阵与边界

| 右键对象 | 应出现的 Git Graph 核心操作 | Kero 入口 / 不出现的条件 |
| --- | --- | --- |
| Commit 行（普通、根、Merge） | Add Tag、Create Branch；Checkout、Cherry Pick、Revert、合适时 Drop；Merge into current、Rebase current onto、Reset Soft/Mixed/Hard；复制 SHA/Subject | `RecentCommitsView.commitRow`；`Drop` 必须有可证实的拓扑可行性。**保留整行左击展开**，不加右键「展开/收起」 |
| 当前／其他本地 Branch Ref | Checkout（非当前）、Rename、Delete（非当前）、Merge/Rebase（非当前）、Push、Copy Name | `referenceActions` 及折叠 `+N`；当前分支仍能 Rename/Push |
| Remote Branch Ref | Checkout（新本地跟踪分支/同名分流）、Delete Remote、Fetch into Local（本地同名且非当前）、Merge、Pull、Copy | `remoteBranch` 也有原生菜单；symbolic HEAD 不当实体 Branch，不能仅凭 `/HEAD` 名称后缀分类 |
| Tag Ref | View Details（Annotated）、Delete（可选远端）、Push、Copy Name | Annotated/Lightweight 按 Git 对象类型判断，不凭 Badge；`+N` 行为一致 |
| Stash 条目 | Apply、Create Branch、Pop、Drop、Copy Name/Hash | Kero 目前只有 `stashCount`：在既有 GitPanel 增加紧凑可右击 STASHES 条目，不新建独立 Dock |
| Uncommitted Changes（现有分组标题） | Stash（Message/Include Untracked）、Reset（Mixed/Hard）、Clean Untracked（含目录选项） | 落到 CHANGES/STAGED/MERGE 标题的同一原生菜单及 More Menu；只有 staged 或被过滤隐藏时仍有入口；保留 Stage/Discard |
| Staged/Unstaged/Conflict 文件、目录与标题 | 原有 Open/Diff、Stage/Unstage/Discard、分组批量动作；工作区与 Untracked 行/目录提供 VSCodium Ignore；按真实版本存在性提供读取 | Ignore 只在适用 Git 文件树对象出现，编辑目标是普通 `.gitignore` FileTab，不引入独立编辑器或未经协调的磁盘写入 |
| 历史文件 | View Diff、View File at Revision、View Diff with Working File、Open File、Reset File to Revision、Copy Absolute/Relative Path | Deleted 不提供查看该 Revision、Open File 或 Reset File；已知二进制不提供文本查看，但仍可 Reset；大小/读取失败在实际读取时说明，不逐行预读 blob |
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
| Commit → Drop | 显示 Commit 与当前 HEAD 的改写范围，无额外字段 | **Yes, Drop / Cancel**；非可 Drop 的拓扑**不显示/禁用**，不因一个 Tag/同节点 Ref 禁用；尊重已有 Rebase 配置，不以 Revert/Reset 冒充 |
| Commit / Branch / Remote Branch → Merge | **Create Commit Even If FF Possible=true**、**Squash Commits=false**、**No Commit=false** | **Yes, Merge / Cancel**；Squash 且未选 No Commit 时按上游自动生成合并效果的 commit，而非只留 staged changes |
| Commit / Branch → Rebase | **Launch Interactive Rebase in New Terminal=false**、**Ignore Date=true**（只影响非交互式） | **Yes, Rebase / Cancel**；Interactive 必须在选定机器的新终端交互，后台模式实际执行 `rebase` |
| Commit → Reset | 单选 **Mixed** 默认，另有 Soft、Hard，各说明影响 | **Yes, Reset / Cancel**；Hard 必须是明确选择，Git 的 Untracked 保留规则如实说明 |
| Local Branch → Rename / Delete | Rename 新名默认旧名；Delete **Force Delete=false**；存在同名 remote tracking 时，**Delete on Remote(s)=false** 是一个复选框，覆盖提示中列出的全部 remotes | **Rename Branch / Cancel**；**Yes, Delete / Cancel**；未合并 safe Delete 失败时给 **Yes, Force Delete Branch**；本地删成功才逐个尝试全部所列远端删除 |
| Local Branch → Push | 单 remote 直接显示；多 remote 多选，默认选 `getPushRemote(selectedBranch)`；**Set Upstream=true**；Push Mode **Normal** 默认 / Force With Lease / Force | **Yes, Push / Cancel**；按选择顺序执行，首个失败后停止；报告已成功、失败与未执行项 |
| Remote Branch → Checkout | New Local Name 默认为 remote 分支短名 | **Checkout Branch / Cancel**；同名已存在时 **Choose Another Name** 或 **Checkout Existing Branch & Pull Changes**（不是隐式覆盖） |
| Remote Branch → Delete / Fetch | Delete 无附加字段；Fetch into同名本地 Branch 时 **Force Fetch=false** | **Yes, Delete / Cancel**；**Yes, Fetch / Cancel** |
| Remote Branch → Pull | **Create Commit Even If FF Possible=false**、**Squash Commits=false** | **Yes, Pull / Cancel**；不是 Kero 顶部的 `pull --ff-only`，两种入口语义不得偷换 |
| Tag → Delete / Push | Delete：单远端 **Also Delete on Remote=false**，多远端选 **Don't Delete on Any Remote** 默认；Push：单远端确认，多远端多选，默认选不带 Branch 参数的 `getPushRemote()` | **Yes, Delete / Cancel**、**Yes, Push / Cancel**；全部所选 remote 的已知 tracking 分支包含检查在推送前完成；缺目标 Commit 时 **Proceed to Push / Cancel**、**Always Proceed=false**；实际 Push 首错停止 |
| Uncommitted → Stash / Reset / Clean | Stash：Message 可空、**Include Untracked=true**；Reset：Mixed 默认 / Hard；Clean：**Clean Untracked Directories=true** | **Yes, Stash/Reset/Clean / Cancel**；Clean 是 Git Graph 的永久清理，不误称本机废纸篓 |
| Stash → Apply / Pop / Branch / Drop | Apply/Pop **Reinstate Index=false**；Branch 输入新名称；Drop 无附加字段 | **Yes, Apply Stash / Yes, Pop Stash / Create Branch / Yes, Drop**，均有 **Cancel**；选择的特定 stash 不会误用栈顶 |
| 历史文件 → Reset File to Revision | 显示 Commit、文件及工作区/索引将被覆盖的警告 | **Yes, Reset File / Cancel**；不与 View File at Revision（只读）混淆 |
| Ref → Create Archive | 原生保存面板，格式 TAR/ZIP，用户决定文件名及位置 | **Create Archive / Cancel**；文件必须真正包含所选 Ref 内容，绝不导出当前 HEAD 冒充 |

**二次弹窗是行为而不是实现细节。** 上游在 Branch/Tag 重名时给「替换 / 改名再试」，远端 Checkout 同名时给「换名称 / 切已有并 Pull」，删除未合并分支时给「强制删除」，Tag 远端不包含目标提交时给「仍要推送 / 取消」。Kero 采用同等可操作的原生按钮、提示和保留输入；不能简化成一个错误 Banner 加重试。

**真实代码的限定：** `perform` 的互斥覆盖同一 Model，不锁住用户外部 CLI；执行前检查不能承诺跨进程原子性，不为此发明全仓锁。按对象补最少预检和结果分流；多步成功应保留，失败不自动回滚。Stash Apply 可按固定 OID 执行；Pop/Drop/Branch 必须用 selector 并核对 OID，不能用 OID 替换 selector 而改变移除行为。Diff 的读取、原文呈现、选中刷新、Tab Key 和快照须一起更新。

**推送默认目标：** Branch 依次尝试其 `branch.<name>.pushRemote`、`branch.<name>.remote`、`remote.pushDefault`、`origin`、remotes 首项，只选仍在配置列表中的目标；Tag 不使用 Branch 配置，依次 `remote.pushDefault`、`origin`、首项。当前 Model 只有 HEAD upstream，不能拿它冒充所选非 HEAD Branch 的配置；在打开 Push 弹窗时按需读取，SSH 合并往返，不在每次周期刷新中为每个 Branch 查询。

<a id="p4-t1"></a>
## P4-T1 Commit Checkout、Cherry-pick、Revert、Merge 与恢复

**结果：** Commit 的四类动作遵守上游弹窗字段、默认值和真实 Git 效果，产生冲突后能保留文件，并通过现有终端处理。

**入口 / Files：** `RecentCommitsView.commitRow` → `GitPanel.presentCreateReferenceDialog/performOperation/repositoryOperationBanner` → `GitStatusModel.perform/detectRepositoryOperation/remoteRepositoryOperation` → `GitCommandExecution`；窗口由 `ToolPanelView` 对应的 `TerminalManager` 提供。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`WorkspaceWindowIsolationTests`、`AppSettingsTests`（Always Accept 的真实偏好持久化）。

**实施：**
1. 只扩展现有 Commit `.contextMenu` 回调，不覆盖整行左击与 Ref 点击。字段保留 Checkout Always Accept、Cherry Pick Parent/Record Origin/No Commit、Revert Parent、Merge No-FF/Squash/No Commit。由 `ToolPanelView.manager.attachedWindow` 及发起 Project/PanelContext 显式接线；同步迁移现有名称框的窗口路由，不留全局窗口 fallback。关闭窗口、切 Project 或换连接使原确认失效；另一窗口成为 key 不把 sheet 转给它。Copy Commit Message 实际只复制 Subject，同 task 改为准确的 Copy Commit Subject 标签。Always Accept 在现有 `AppSettings` 的读取/保存/`resetToDefaults` 中默认 false，UI 测试传入临时配置的同类设置，不改 `AppSettings.shared` 或用户 Home。
2. `GitStatusModel` 用完整 SHA 和捕获的工作空间；argv 为 `switch --detach`、`cherry-pick [-m N] [-x] [--no-commit]`、`revert --no-edit [-m N]`、`merge --no-edit [--squash|--no-ff] [--no-commit]`。Squash 优先于 No-FF，非 Squash 且 No-FF=false 不私自补 `--no-ff`：此时 No Commit 不能阻止快进，提示和测试如实表达。Squash 成功且 No Commit=false 后，按上游检查是否真的有 staged 差异；有才 `commit -m`，默认消息是 `Merge commit '<fullSHA>'`／`Merge branch '<name>'`／`Merge remote-tracking branch '<remote/name>'`，不误用 `--no-edit` 的 SQUASH_MSG，不制造空提交。原仓库 Hook/签名失败保持真实错误和已产生的 staged 状态。
   在现有 `perform` 内最小扩展条件步骤和可检查的结果，让上述检查→Commit 保持同一个操作、同一个 backend；后续远端 Checkout→Pull、Tag 创建→Push、错误二次分流也复用它。仅原有 Bool completion 不足以让 UI 区分“未合并”“重名”“部分成功”；提供所需结果，不让 View 解析完整日志，不创建通用工作流 DSL 或另一套 runner。
3. 现有 `repositoryOperation` 已从真实 Git 标记识别 Merge/Cherry-pick/Revert/Rebase/Bisect，`GitPanel.repositoryOperationBanner` 已提示用户可从终端恢复：这条路径足够，本阶段仅校验和修正提示文案。上游 Git Graph 自身没有额外 Continue/Abort/Skip 右键或弹窗；Kero 发生冲突后保留 index/worktree，允许用户从已有原生终端运行 Git 的 continue/abort/skip，完成后刷新。**不为菜单再造状态枚举、GUI 恢复面板或第二套状态机。**
4. 在发起 Project 中按机器/仓库筛选受影响的 FileTab 和可编辑 DiffTab，复用 `PaneContent.save()` 等待已排队保存并复查；失败或保存期间又编辑就停止，保留内容。**不能调用 `Project.saveBeforeClosing/confirmCloseUnsaved`，它们会删 Tab。** 确认前后与异步预检后检查原目标，在首次 Git 副作用前沿现有 contextGeneration/backend 失效机制再确认；不能只有完成后的 guard。正常完成后重载干净的工作区 Tab，不等用户切换才显示变化；不重载 dirty 原生缓冲，不统一禁止所有 dirty Git 状态。此最小入口归 Project/现有 Git 编排，T2/T4/T6/T7/T8 复用，不各建保存协调器。

**Red→Green / 验收：** 正常/根/Merge、主线 Parent、No Commit/-x、No-FF/Squash/No Commit 组合；Squash 有 staged 才提交、无差异不创建空 Commit；No-FF=false 的快进与上游相同，默认消息准确。临时仓库核对 HEAD/refs/index/worktree。制造冲突后在终端 Continue/Abort（及允许的 Skip），验证 Git 标记；NativeUI 测默认字段/按钮/独立命中和 Always Accept 的保存与重置。保存中再次编辑、预检等待期间切 Project/连接、两个 Project 指向同一仓库、窗口失效均测试真实副作用；取消不修改 Git，保存失败不关 Tab，操作成功已挂载干净编辑器更新。

**提交边界：** 菜单/选项、窗口与最小保存接线、`perform` 的必要条件结果、回归、Git/UI/Settings 文档及中英字符串同一提交。删除全局猜窗口路径及被替换的 Commit 回调；替换“Copy Commit Message”旧标签（确认无其它使用后删除旧字符串）。保留仍负责安全语义的 `repositoryOperation`、PendingDiscard 和后台环境，不把它们当 legacy。

<a id="p4-t2"></a>
## P4-T2 Commit Rebase、Reset 和合法 Drop

**结果：** Reset 三模式、非交互/交互式 Rebase、Drop 具备上游的选项与效果，历史写入不能误改别的分支。

**入口 / Files：** `RecentCommitsView.commitRow`、`GitPanel` 原生弹窗、`GitStatusModel.RecentCommit.parentHashes/headOID/branch/perform`，交互式入口沿 `Project.newSession/makeSession` → `TerminalSession.init/makeLaunchScript` → 真实 PTY；机器依据来自 `PanelContext`、`SSHHostWorkspaces` 或 `RemoteConnection`。验证：`CommitGraphLayoutTests`、`GitStatusModelTests`、`RecentCommitsViewTests`、现有 Workspace/Terminal 集成。

**实施：**
1. 字段 **Interactive=false、Ignore Date=true**。非交互式后台 `git rebase [--ignore-date] <selectedSHA|ref>`；Interactive 忽略 Ignore Date，在发起 Project 的**新**终端执行 `git rebase --interactive`。当前 `makeSession` 对 pinned SSH 忽略传入 directory，而自动跟随 SSH 的 Project（sshHost=nil）还会启动本机 Shell；两个入口都必须接到捕获的机器与 repoRoot，不把 `customDirectory` 或选中终端的 cwd 当 Git top-level。
   接线扩展既有 newSession/makeSession，通过 `TerminalSession.launchCommand` 启动捕获机器的新 PTY。实际 Windows 测试证明复杂 remote command 会经过本机现有 Windows wrapper 的参数重组并产生 parse error，显式启动环境项路线已停止并删除，不把它保留成 fallback。改走普通 SSH 登录及已有认证 helper，再使用已安装 Ghostty 的原生 `input`（1.2 起支持，当前引擎 1.3.2）发送一次命令；不建 prompt/OSC 等待器、stdin 管道系统或另一个握手协议。握手前只暂存该会话的启动工作区，随后交给真实 RemoteConnection；新 Tab 不落回 Mac，保留 host/user/port、Shell 环境、配置与编辑器。SSH 结束后保留结果至 Enter 关闭，远端专用标签仍绑定断线机器。启动不等于变基成功；用本机及获准 `windows` 的真实 PTY、编辑器等待/输入和 HEAD 改写验证，主题变化不得重发输入，不借用工作 master。
2. Reset Soft/Mixed(默认)/Hard 分别 `git reset --soft/--mixed/--hard <selectedSHA>`。Hard 覆写 tracked 的 index/worktree；普通 untracked 通常保留，但挡住目标 tracked 路径的 untracked 文件/目录可能删除，不能保证“Hard 从不删除 untracked”。复用 T1 不关闭 Tab 的保存/在途写入保护与干净内容重载。
3. Drop 按上游要求所选节点有父，沿子路径找到当前 HEAD，所检查路径无 Merge/多子分叉；必要时在打开 Drop 时按需读完整可达拓扑，不能把分页缺节点当成安全证明，也不预建全历史索引。命令 `git rebase --onto <selectedSHA>^ <selectedSHA>`，不额外添加 `--update-refs` 或 Force Push。**删除“有其它 Ref 就禁用”的限制**：单个 Tag 或指向同一节点的其它 Branch/remote Ref 不是多个子提交，默认 Rebase 配置下保持这些 Ref 不动；真正的多子分叉仍不可 Drop。用户已有 `rebase.updateRefs=true` 会按 [Git 原生配置](https://git-scm.com/docs/git-rebase#Documentation/git-rebase.txt-rebaseupdateRefs)更新相关本地 Branch，不能保证所有配置下其它 Branch 恒定，也不能偷偷加 `--no-update-refs` 改变上游命令含义。保留上游在 detached HEAD 下成立的拓扑行为，准确呈现目标为当前 HEAD。Root/Merge 不以 Reset/Revert 冒充。
4. 与上游相同，Reset 只在用户按 **Yes, Reset** 且选定模式后执行；Rebase/Drop 失败保留 Git 错误及现有操作标记，在终端可恢复；不新增定时器、重试或 Rebase 控制器。

**Red→Green / 验收：** A→B→C→D、独立分叉、Merge、分页边界、有历史 Tag/同节点 remote Ref、HEAD/detached 的 Drop；默认配置下其它 Ref 保持，另测用户显式开启 updateRefs 的 Git 原生结果，不能因一个 Tag 错禁用。Soft/Mixed/Hard 检查 HEAD/index/worktree，包含普通 untracked 保留与阻挡路径被 Hard 删除。Interactive 的新 PTY 在目标仓库真正进入编辑器并产生可观察结果；本机、pinned SSH 与自动 SSH 路由分别验证，不要求 OSC prompt。取消零 Git 副作用；NativeUI 核对两复选/三模式和历史展开。

**提交边界：** 本组菜单、Rebase 终端接线、合法 Drop 判断及对应测试与 Git/Terminal/SSH 文档、本地化同一提交；不在最后 E2E task 才删除旧路径。

<a id="p4-t3"></a>
## P4-T3 创建 Branch 与本地 Branch 菜单、Ref Archive

**结果：** 选定 Commit 创建 Branch 的二级分流、现有 Branch 的重命名/删除/定向推送和 Archive 都按照 Git Graph 的弹窗与最终作用对象工作。

**入口 / Files：** `RecentCommitsView.createReference/referenceActions/referenceStrip`、`GitPanel.presentCreateReferenceDialog/presentGitNameDialog/branchMenu/performOperation`；`GitStatusModel.createReference/createBranch/switchBranch/push/publish/perform/runGitStatus/prefetchedSnapshotCommands`；Archive 的 Git 生成走 `GitCommandExecution`，文件传回用 `WorkspaceBackend.read`，保存交互参考 `WorkspaceNativeDialogs`。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`GitExecutionTests`。

**实施：**
1. 将 P2 的仅名称 Branch 创建迁移到 Name 与 **Check out=false** 表单；重名给 **Replace Existing Branch / Choose Another Name**，保留 Name 和 Check out。确认替换才 `git branch -f <name> <SHA>`，成功后按选择切换；普通新建 `git branch <name> <SHA>`／`git switch -c <name> <SHA>`。顶部 Create New Branch 原本会切换，保留其**从当前 HEAD 创建并 Checkout**的语义，与历史入口共用执行方法但不偷换默认值。Git 对当前检出/其它 worktree 的拒绝原样显示；Ref 名必须按 Git 校验，不能只检查文本非空或让前导 `-` 变成 option。
2. 直接展示与 `+N` 的本地 Ref 共享 `referenceActions`。当前 Branch 有 Rename、Push、Copy；其它 Branch 还包含 Checkout（不用确认，Git 自己检查工作区）、Delete、Merge into current、Rebase current onto、Copy。Rename 提供预填旧名称和 `Rename Branch / Cancel`，底层 `git branch -m old new`，重名不自动 `-M`；Merge/Rebase 复用 P4-T1/T2 的同一字段/方法。
3. Delete 默认 **Force Delete=false**。现有状态只读取 heads；把该条 `for-each-ref refs/heads` 查询扩为同一次 heads/remotes 的完整 ref 名、OID、symref 元数据，远端替换同一 batch 项，T4 继续使用、T5 再补 tags 对象类型，不新造 RefStore。按**已知同名 remote-tracking 分支**列出 remotes，显示一个 **Delete on Remote(s)=false** 复选框：勾选就删所有所列对象，不改成任意多选。先本地 `branch -d`（已选 Force 则 `-D`），未合并错误才给 **Yes, Force Delete Branch**；本地成功后，按上游 handler **逐个尝试全部**所列远端删除，即使中间一个失败仍尝试后面的。使用完整 heads refspec，服务器不存在时只清理对应 tracking ref；拒绝不绕过，不新增远端 expected-OID lease。记录本地及各远端的部分结果，T4 复用同一个单远端删除方法。
4. Push 包含 `Set Upstream=true`、`Normal/Force With Lease/Force`；多 remote **多选且默认目标按上方合同**。支持非 HEAD Branch，用完整 `refs/heads/<selected>:refs/heads/<selected>` 避免同名 Tag 歧义，不调用当前 HEAD 的 `model.push()`。按选择顺序执行，**首错停止**；Set Upstream 最终指向最后一次**成功**的设定，不承诺同时 tracking 多个 remote。不预先 Fetch 来更新 lease，不把 Force With Lease 改成普通 Force；空选择禁用提交。T1 的结果分流及同一互斥区承担操作，失败/未执行清楚可见。
5. Branch/Remote/Tag 共用 **Create Archive** 原生 NSSavePanel（T4/T5 只接入 Badge）。格式与扩展名一致，限 TAR/ZIP；目标是对象的完整 Ref／解析出的选定 OID，不用 HEAD 或歧义短名。本机用 `GitCommandExecution` 的已解析登录环境执行 `git archive --format=tar|zip -o <本次临时文件> <target>`，成功后原子保存到选择的位置，不用本机 `backend.run(["git", …])` 绕过环境。SSH 在**选定 backend**申请本次临时文件，Git 仍经 GitCommandExecution 生成并检查退出码，再通过已有 `backend.read(path:maxBytes:)` 有界传回 Mac；stdoutLimit 不能证明传输完整。
   本机磁盘归档无需人为设内存上限；SSH 整包读取须公布一个有界上限，在本 task 验证边界，超限明确失败且不损坏现有目的文件。Git 生成成功及有界 read 是运行时检查，TAR/ZIP 条目与字节完整性放在测试验证，**不另写容器解析器、checksum 协议或传输系统**。对成功/失败/取消尝试清理本次临时文件；断线导致远端清理失败要记录准确路径和未完成结果，不承诺断线后已清干净，不加跨机器 fallback/定时 janitor。已确认目的文件替换才原子保存；取消不生成归档。

**Red→Green / 验收：** 历史 Branch 创建/替换/改名再试保留字段，顶部默认 Checkout 保持；重名 Tag/Branch、前导 option/特殊合法 ref、当前及其它 worktree 检出 Branch。至少三个 bare remotes 验证 Delete 的单复选范围、中间失败仍尝试后项、本地失败不删远端；Push 首错停止与后项未执行、三模式、默认目标 config 优先级、非 HEAD 源、最后成功 upstream。Archive 选中 Ref 的 TAR/ZIP 条目和 bytes、GUI PATH 登录环境、取消/已存在目的文件、SSH 受控 runner 的边界读取与断线清理失败；不把 runner fixture 当真实 SSH。原生直显/`+N`、焦点与文档同步。

**提交边界：** 同 task 替换历史与顶部 Branch 名称框及 Branch 执行分支。P2 `createReference(.branch)` 不保留兼容转发；`presentGitNameDialog`/`NonemptyTextFieldValidator` 若仍承载未迁移 Tag，留至 T5 最后调用迁移时立即删除，没有调用则 T3 就删。头部 Push/Publish 是现行快捷入口而非旧菜单，不删除或偷换语义。新菜单、Archive、回归与 Git/SSH/UI 文档和本地化同一提交。

<a id="p4-t4"></a>
## P4-T4 Remote Branch 的 Checkout 分流、Fetch、Merge/Pull、删除

**结果：** 远端 Badge 不再只是只读文本；Remote Branch 每项使用 Git Graph 相同的选择与后续动作，操作的是真正 remote/ref，而非当前 HEAD 或同名 Mac 仓库。

**入口 / Files：** `GitStatusModel.RecentCommit.Reference(.remoteBranch)` / `parseCommitReferences`、`remotes/branches/fetch/pull/perform`；`RecentCommitsView.referenceBadge/referenceActions/+N`、`GitPanel`；`GitCommandExecution` → `SSHWorkspaceBackend`（远端 argv 引用）及 P4-T3 `Create Archive`；`GitStatusModelTests`、`GitExecutionTests`、`RemoteCommandsTests`、`RecentCommitsViewTests`。

**实施：**
1. 使用 T3 的完整 remotes ref 元数据及已配置 remote 前缀解析身份，处理嵌套 branch 和含斜杠 remote，不能盲切第一个 `/`；前缀有重叠时取实际匹配的最长 remote 前缀。**symref 元数据**判断 symbolic HEAD，不能继续 `parseCommitReferences` 的 `name.hasSuffix("/HEAD")` 过滤：普通实体分支也可叫 HEAD。只隐藏 symbolic HEAD 的管理操作，实体 refs 保留。remote Badge 变为独立原生菜单，`+N` 删除只读 Text 特判、调用同一 referenceActions，左击不展开 Commit。
2. Checkout Branch 弹窗预填 remote 后的分支名，新名时创建本地跟踪分支并 Checkout；同名本地 Branch 已存在时必须提供**Choose Another Name**（带原输入重开）或 **Checkout Existing Branch & Pull Changes**（先切换再针对所选 remote/branch Pull，使用 P4-T4 同样的默认 Pull 参数）。不能把同名情况直接抛成「名字已存在」错误，不能隐式覆盖。
3. Fetch into Local Branch 只在同名本地分支存在且不是当前分支时出现；复选 **Force Fetch=false**，普通尝试快进，选中时执行上游 `git fetch -f <remote> <branch>:<local>`，仍遵守 Git 对其它 worktree 正检出分支的禁止条件。Merge into current 直接复用 P4-T1 的 No-FF/Squash/No Commit 表单。
4. Pull 字段 **No-FF=false、Squash=false**，按 remote/完整 heads ref 执行 `pull --no-edit <remote> <branch> [--squash|--no-ff]`，Squash 优先；保持用户 Git 配置，不偷偷改 `pull.rebase`/`pull.ff`。Squash 成功后用 T1 的条件 staged 检查，存在差异才提交；上游默认消息为 `Merge branch '<remote>/<branch>'`。**不走**顶栏的 `model.pull()`（FF-only）。Checkout Existing & Pull 必须在同一执行链中 switch 成功才 Pull；Pull 失败保留已成功的 Checkout，不能对自己已更改的 HEAD 重用旧前置校验。
5. Delete 只确认所选 remote + branch，复用 T3 的原生定向删除 `git push <remote> --delete refs/heads/<branch>`，不引入网络探测/lease 前提。服务器保护失败原样展示。仅真实错误表明 `remote ref does not exist` 时，按上游删除**对应**本地 tracking ref（同仓库目标校验）；认证/断线/Hook 拒绝不能走这个 fallback。测试到实际 tracking ref 删除，不只断言 fallback 被选择。Archive 使用选中的完整 `refs/remotes/…`，不是 Fetch 服务端实时归档。

**Red→Green / 验收：** 多 remote 同名不同 SHA、前缀重叠 remote、嵌套 Branch、symbolic `origin/HEAD` 与实体 HEAD 分支；Checkout 新 tracking/重名两按钮，switch 成功但 Pull 失败的部分结果；Fetch 普通/Force/其它 worktree 拒绝；Merge/Pull No-FF/Squash 条件 Commit。远端服务器保护、Ref 不存在时最终 tracking ref 消失、其它网络/Hook 错误不清理本地；`ls-remote/for-each-ref`、index/worktree 证明作用对象。NativeUI 直显/`+N` 一致；SSH fixture 仅证明路由和 argv，真实 SSH 单独验收。

**提交边界：** 远端 Ref 从「只读标签」迁移为真菜单，复用既有 Fetch/Pull/Archive 而不创建第二个操作模型；实现、验证和文档/本地化同一提交。

<a id="p4-t5"></a>
## P4-T5 Tag 的 Annotated/Lightweight、重名替换、Push 与删除

**结果：** Tag 创建、View Details、Delete、Push 的每个字段、二次提醒和部分成功行为均符合 Git Graph，而不是「只能建轻量 Tag，操作另加一个确认」。

**入口 / Files：** `RecentCommitsView.createReference/referenceActions/+N`，`GitPanel.presentCreateReferenceDialog`；`GitStatusModel.createReference/perform/remotes`、`RecentCommit.Reference(.tag)`；按需 `git cat-file/for-each-ref/ls-remote`；共享 Archive 由 P4-T3 提供。验证：`GitStatusModelTests`、`RecentCommitsViewTests`、`AppSettingsTests`（Always Proceed 的保存与恢复）。

**实施：**
1. 直接替换 P2 的轻量 Tag 专用名称框。Commit → Add Tag 原生表单：**Name**、**Type=Annotated(default)/Lightweight**、**Message=Optional（仅 Annotated 生效，切类型不清空输入）**、**Push to Remote=false**（单 remote checkbox、多 remote 单选默认 Don't Push）；添加到选定完整 SHA，不自动改变 HEAD。重名给 **Replace Existing Tag / Choose Another Name**，后者保留所有字段；Replace 确认才 `git tag -f` 覆写本地 Ref，无自动强推。
2. 在 T3 已有的 refs 快照查询中加入 tags 的 objecttype/OID，不再新增第二份 heads/remotes/tags 查询或每 Badge 各发 SSH。annotated 才有 View Details，按需读 **Tag 名、Tag object SHA、peeled Commit、Tagger 姓名/邮箱、日期、消息、签名验证状态（有签名时）**，原生可选文本和 Close 按钮，不造签名管理页。按 tag object 与 commit 区分身份，不能把 object OID 当 commit 推送警告依据；不预取全文或为验证失败假报签名有效。创建 Annotated 必须用 `-a -m <message>`，空 message 也显式 `-m ""`，后台不等编辑器；保留仓库 `tag.gpgSign` 与实际签名失败。
3. Delete 无 remote 仅本地；单 remote **Also Delete on Remote=false**；多 remote **Don't Delete on Any Remote（默认）/指定一个**。按上游先 `push <remote> --delete refs/tags/<name>`，成功才本地 `tag -d`；远端失败时本地仍在，本地删除失败时已成功的远端结果保留。无 expected-OID lease 或 `ls-remote` 强制前检；本地被确认 Ref 的必要检查与服务器保护仍保留，不删同 SHA 的其它 Tags。
4. Push 单 remote 确认、多 remote 多选且默认按上方合同；明确 `refs/tags/<name>:refs/tags/<name>`，不 `--tags`。按上游 `getRemotesContainingCommit` 用**已有 remote-tracking 分支**判断 peeled Commit 的包含关系：不先 Fetch、不联网查询服务端全部历史，不把本地快照称为“服务器一定存在”。对所有所选 remote 完成此检查后，缺少 Commit 时整体先给 **Proceed to Push / Cancel**、**Always Proceed=false**，未确认不先推其中某个。这个提示本来是启发式；包含关系查询失败不伪造“不在远端”，按上游继续尝试 Push，保留查询诊断与真实 Push 结果，不新加网络重试/阻塞协议。实际推送按选中顺序**首错停止**。
   Always Proceed 由 `AppSettings` 读取/保存/重置，默认 false、独立于 Always Accept；测试用临时配置。该警告也应用于 **Add Tag 选择 Push to Remote** 的后续 Push；本地已创建后用户取消警告，仅取消 Push、不撤销 Tag。使用同一个 T1 执行/分流入口，不把创建→推送封成无法继续询问的静态 argv 列表。
5. Archive 接 T3；Tag 表单归原 GitPanel，不另建 ViewModel/Release 页面。保留左击 Tag 定位 Commit，但删除旧右键 **Show Tagged Commit** 冗余项，让原生右键按上游仅管理 Tag。迁移最后的 `createReference(.tag)` 后，立即删除 `CommitReferenceKind/createReference`、旧 `presentCreateReferenceDialog/presentGitNameDialog/NonemptyTextFieldValidator` 及已无调用的回调/字符串；T3 的 Branch 不恢复兼容壳。

**Red→Green / 验收：** lightweight/annotated 同 Commit Tag、空附注、合法标点、同名 Branch、签名详情（至少有签名但无法验证时不假报有效）。默认 Annotated、替换/改名保留所有字段、创建不改 HEAD、单/多 remote 默认选择、Push 首错停止、Delete 远端先于本地且失败不乱回滚。独立 Push 与 Add Tag→Push 都测 Proceed 警告、取消保留本地 Tag、Always Proceed 往返/重置；已有 tracking 与服务端实际 tip 不同的情况明确警告证据边界。`cat-file/show-ref/ls-remote` 核对实际对象；Archive Tag 内容、NativeUI 详情字段/Close/直显与 `+N` 一致。

**提交边界：** 原轻量 Tag 新建路径直接迁移为完整表单，Tag 读/写和后续提示、测试与 Git/UI/Settings 文档、中英字符串同一提交；不保留两套创建方式。

<a id="p4-t6"></a>
## P4-T6 历史文件 View / Diff / Reset 的完整菜单与真实 Tab

**结果：** 历史文件右键复制 Git Graph 的读版本、比较工作区及**带警告的覆写**，使用真实版本内容，不能把「查看」做成修改当前文件。

**入口 / Files：** `RecentCommitsView.commitFiles/changedFile/displayRow` → `ToolPanelView` 回调 → `TerminalManager/Project.openCommitDiff/openFile/findDiffTab` → `DiffTab.reload/gitContent/readWorktreeFile/refreshWhenSelected` → `DiffViewerView.body/DiffNativeSurface`；`TerminalManager.contentSnapshot` → `SessionStore.ContentSnapshot` → `Project.makeContent` 是恢复链。验证：`DiffTabTests`、`RecentCommitsViewTests`、`WorkspaceContentIdentityTests`、`GitStatusModelTests`、`SessionStoreTests`；文档增加 [Session Restore](../../../docs/features/session-restore.md)。

**实施：**
1. 保留已有历史 View Diff；补 View File at Revision、Diff with Working、Open File、Reset File、Copy Absolute/Relative。Deleted 无选中 SHA blob，因此不提供该 Revision 查看、Open 或 Reset；已知二进制不提供文本查看，但**仍提供 Reset**，不能把文本能力当 Git 文件覆写资格。Kero 当前 FileChange 只有 name-status，不知道 binary；所需 diff 能力元数据在展开所选 Commit 时用一次 NUL 分隔 numstat 读取（Root/第一父规则），不遍历所有已加载历史、不逐文件 cat-file 预探。5 MiB/解码/真实读取失败在打开时反馈，不在菜单前预读整包内容。Rename/Copy 的 before/after 分别 originalPath/path，Root/Merge 维持第一父规则。
2. 在现有 DiffTab 明确「Revision 原文」「Revision↔Worktree」「历史 Diff」「既有 index/worktree」的来源与身份，只增加这些实际模式，不造泛用 Ref/Merge Base 比较器。源模式同任务进入 `Project.findDiffTab`、标题、打开回调和**当前**快照编码/恢复；不让新模式恢复成 commitDiff。保留现有 diff/commitDiff 快照对应的现行业务，不新增旧版本解码、版本迁移层或双份来源字段/兼容 initializer；被替换的参数/分支在所有调用点和测试迁移后直接删除。
   **原文**走同一 Tab 保留的原生 TextKit 表面，无增删装饰/折叠 Diff/编辑保存；修改 DiffViewerView 的 No Changes gate 与 DiffNativeSurface 呈现，空文件也显示原文而非“无变化”。Revision↔Worktree 的右侧是实际工作区，选中/重新打开时重读该侧，不能继续 `refreshWhenSelected` 的 `commitHash != nil` 一律不刷；不因共享 prefersEditing 意外写入历史 Revision。保留唯一表面、5 MiB、UTF-8/NUL 与机器/断线保护。
   修 `gitContent` 把 cat-file 所有失败当 missing 的汇聚点：仅 Root/Added 的 before、Deleted 的 after、经确认不存在的版本/工作区侧可为空；所选 Revision 应存在却读取失败、SSH 超时或权限错误必须是错误，不走 firstGitContent 的“最后返回空成功”。保留未合并 index 的真实 stage fallback，不把删除所有 fallback 当简化。
3. Open File 用**发起** Project 的普通 FileTab；其路径当前不存在时，按上游 `getNewPathOfRenamedFile` 只做一次 `git diff --name-status -z --find-renames --diff-filter=R <selectedSHA> --` 的 Revision→Worktree 对比，并确认匹配新路径实际存在。Revision↔Worktree 使用同一按需解析结果；不是逐 Commit `log --follow` 或预建历史索引。原路径仍存在时上游直接打开它，不加没有来源证据的“同名内容必须仍是原文件”规则；查询失败不能冒称已找到 Rename。最终找不到时 Open 报不存在、Diff working 侧为删除，远端仅当前 backend，不调 Mac Finder。Copy Absolute 为所选 repoRoot+Git 相对路径（SSH 为远端绝对路径），Relative 为原相对路径，目录同时提供两种复制。
4. Reset File 显示 **Yes, Reset File / Cancel**、SHA/路径和 index/worktree 覆写说明；执行 `git --literal-pathspecs checkout <fullSHA> -- <original revision path>`，两处一起修改，不能只恢复编辑器文本，也不把 Open 的 Rename 解析结果偷换成 Reset 的目的路径。复用 T1 对受影响 Tab 的保存/在途写入保护、失败不关 Tab与干净重载；只核对该覆写目标的实际状态，不扫描或指纹整个仓库。二进制文件同样可恢复真实 bytes；取消零 Git 副作用。

**Red→Green / 验收：** Added/Deleted/Renamed/Copied、Root/Merge、多版本/当前同名路径、空 blob、超过 5 MiB、NUL/坏 UTF-8、读取失败与 SSH fixture；Revision 应存在却失败不能变成空 Diff。NativeUI 真菜单的只读原文无增删装饰，Revision↔Worktree 改名/删除/重新选中刷新正确，普通 Open 按上游仅在不存在时解析 Rename；两种目录/文件复制准确。Reset 取消不改 Git，确认后 index/worktree 同变、二进制 bytes 可恢复、失败/保存期间编辑不丢。不同来源的 Tab 正确复用/区分、共享编辑偏好不使 Revision 可写；SessionStore 当前模式往返及 Project 实际重建内容/只读性质一致，不只测 JSON 编码。保留原生身份与共享树滚动。

**提交边界：** 同 task 补齐 Diff 来源、原文呈现、刷新/Tab Key/当前快照、Git 文件复位、测试及 Git/Diff/Files/Editor/Session Restore 文档；删除被替换的布尔/optional 来源分支和兼容回调，不造 RevisionViewer、第二个 FileTab 或旧格式迁移器。

<a id="p4-t7"></a>
## P4-T7 Uncommitted Changes 弹窗与工作区 Git 文件/分组菜单

**结果：** Git Graph 的未提交改动三项操作能从 Kero 的现有分组右键使用，VSCodium 的 Stage/Unstage/Discard 文件菜单仍准确保持原有分组语义。

**入口 / Files：** `GitPanel.changeList` 的 MERGE/STAGED/CHANGES 区块标题 `PanelSectionHeader`、`changedFileRows/row/GitEntryRow.menu`，共享 `TreeFolderRow/TreeFileRow`；`GitStatusModel.stash/stage/unstage/stageAll/unstageAll/discard/discardChanges/prepareLocalDiscard/prepareRemoteDiscard`；`GitStatusModel.perform`。验证：`GitStatusModelTests`、`TreeRowHitTestingTests`、`RecentCommitsViewTests` 或现有同层 Git 原生窗。

**实施：**
1. Git Graph 的三项是 **Stash…**（Message 可空、Include Untracked=true）、**Reset…**（Mixed 默认/Hard）、**Clean…**（Directories=true）。Kero 不加伪 Commit 或新区块：扩展 PanelSectionHeader **内部现有 contextMenu** 的仅菜单项，合并原 Stage/Unstage/Discard；不能外套第二份 contextMenu，也不能把这三项放进会同时生成 hover 按钮的 `actions`。Files 等其它 header 默认保持原样。CHANGES/STAGED/MERGE 使用同一表单入口，More Menu 兜住只有 staged 或过滤隐藏标题的情况；此处是可达入口而非错误 fallback。不留直接 `stash(includeUntracked: true)` 的盲执行；原 stash 方法仅增加可选 message。
2. Mixed `git reset --mixed HEAD` 保留 working、重置 index；Hard `git reset --hard HEAD` 覆写 tracked 且可能删除阻挡恢复路径的 untracked，准确沿用 T2 提示，不默认 Hard；无 HEAD 不提供 Reset。复用 T2 的方法和 T1 不关闭 Tab 的保存/重载保护；Mixed 不因为无关未保存工作区文本一律被禁用。
3. Clean 使用上游 `git clean -f[d]` 的**永久删除语义**，不能把它谎称为本机 Move to Trash，也不能把 Kero 原本逐文件的 Discard/Trash 悄悄改成永久删除。原生确认明确是否包含目录及永久删除的影响，保持上游 **Yes, Clean / Cancel** 单次确认，不为 Clean 新增另一个预览状态机；执行前核对当前机器与仓库，清理范围按 Git 原生语义。取消不执行，远端通过当前 Backend 执行，没有 Mac 同名路径兜底。
4. MERGE 保留真正冲突的 Open/Mark Resolved；STAGED 已有 Open File，不重复添加，补 **Open HEAD File**（有 blob 时）；CHANGES 保留 Stage/Discard/Open，HEAD/index 查看复用 T6 原文入口。目录动作从对应**原始分组**取得所选真实目录的路径集，包含 Rename 新旧路径，单次 argv/perform 完成批量 Stage/Unstage：不能循环单文件调用（首个会占 isBusy），不能用全仓 stageAll 冒充目录作用域。无 HEAD 的 Unstage 继续用原 rm --cached 语义。Discard 复用 prepare/confirm ReviewedDiscard；过滤状态下沿用现有禁用“全仓”危险动作的规则，不默默改变范围。保留本机 Trash/SSH 删除审核和共享树 hover，不另建目录操作 executor。
5. Ignore 按 VSCodium `repository.ignore` 在发起 Project 的普通 `.gitignore` FileTab **追加并保存**。使用同一原生编辑缓冲的末尾插入动作、`refreshDirtyState()` 和串行 `save()`；`file.text += …` 不会更新已挂载 STTextView，`reloadRevision` 重建或直接 backend.write 也不能替代原生插入。已有脏文本一起保留并按该动作保存，undo 能撤销插入；未挂载时仍由同一 FileTab 文本真源承载，不另建缓冲。
   `.loading` 时等待 FileTab 已拥有的读取任务后核对文本/身份，不轮询或 sleep；`.unavailable`、断线和保存失败明确保留/拒绝。缺 `.gitignore` 时通过现有 backend 的排他 createFile→Project.openFile 建立，若已被另一进程创建则读取它，不能覆盖成空文件；FileTreeModel.beginNewFile 是会弹名称输入的 UI，不能把它当已存在的“静默创建指定文件”方法。Git 相对路径转换为可表达的 ignore pattern，保留旧内容/换行；POSIX 文件名的反斜杠不是 Windows 分隔符，`* ? [ # !` 等不能无意变成规则语法，用 `git check-ignore` 验证特殊文件/目录。含换行且不能准确表达的路径明确拒绝自动追加，不把一条文件名写成多条规则。不扩成通用 Ignore 编辑器、规则优化器或配置状态机；Ignore 的 Git 刷新由成功保存触发，不在失败时显示已忽略。

**Red→Green / 验收：** 临时 Git 仓库覆盖只有 staged、只有 unstaged、同路径 staged+unstaged、untracked 文件及目录、Merge 冲突、改名、无 HEAD、变更过滤后批量动作、特殊路径。Stash Message/IncludeUntracked 直接核对 `stash list` 和工作区；Reset Mixed/Hard 核对 index/HEAD/工作区；Clean 取消/确认的实际作用路径、目录开关/远端命令；现有 Discard 仍按本机 Trash/SSH 删除审核执行；Ignore 在 `.gitignore` 无文件、已有规则、已挂载原生 STTextView、SSH 仍处于 `.loading` 及已有未保存文本时按真源追加并保存，不能空读覆盖或绕过原生编辑缓冲；失败后原文、undo 与脏状态不丢。NativeUI 在真实分组、目录和文件**右键**操作，额外验证 Staged 的 Open HEAD File 正确只读、无 HEAD 时不误开，其他各区 hover 与菜单动作一致，键盘/VoiceOver 和共享树滚动回归。

**提交边界：** 原有 More Menu 的盲 Stash 行为直接替换成相同表单（仅语义明确的 Pop Latest 快捷键留给 T8）；新增 Uncommitted/分组文件菜单、VSCodium Ignore、回归以及 Git/Files/Editor/UI 文档同一提交。不在最后统一清理多余菜单分支。

<a id="p4-t8"></a>
## P4-T8 逐条 Stash 的 Apply、Pop、Branch、Drop 与右键

**结果：** Git Manager 可看到并右击**具体** Stash，所有原生弹窗选项和操作对象与 Git Graph 相同。

**入口 / Files：** `GitStatusModel.stashCount/runGitStatus/prefetchedSnapshotCommands/StatusResult/applyRepository/clearRepositoryState/perform/stashPop`，`GitPanel.moreMenu/changeList`、`PanelSectionHeader`、现有树行风格；`WorkspaceBackend`。列表沿同一 StatusResult 与缓存快照发布/失效，切仓库时清除，测试：`GitStatusModelTests`、原生 Git Panel 测试。

**实施：**
1. GitPanel 增加紧凑 STASHES 折叠行，不独立 Dock、不混入真实 Commit DAG。在既有 status/batch 中把只计数的 `rev-list --walk-reflogs --count refs/stash` **替换**成一次 selector/OID/说明的 `stash list` 或 `reflog` 查询，count 从条目派生；不并行保留 count+list 两查询、独立缓存或按需加载状态机。使用可靠字段分隔保留说明，空列表与查询失败区分。各行 `.contextMenu` Apply/Branch/Pop/Drop/Copy Name/Hash；复用已有刷新请求失效规则，不另加轮询。
2. Apply 与 Pop 分别有 **Reinstate Index=false** 复选，真正带/不带 `--index`；Apply 不移除 Stash，Pop 仅成功应用后移除，冲突时仍保留 reflog。Create Branch 先输入名称，真实 `git stash branch <name> <selector>` 会**Checkout 新 Branch 并恢复变更**、成功后可能移除原 Stash；Drop 的 **Yes, Drop/Cancel** 只移除选定的条目。
3. selector+OID 都需保留。Apply 可用固定 OID；**Pop/Drop/Branch** 用 selector，Branch 的成功移除行为不能通过传 OID 丢掉。在同一 perform 首次副作用前核对 selector 仍指向选择的 OID；弹窗期间移位就重新选择，不只依赖 stashCount。检查不是外部 CLI 的原子锁，不声称消除所有跨进程并发，也不新建全局锁。Apply 使用 selector 时做同样核对。
4. More Menu 若保留 Pop 快捷入口，明确 **Pop Latest Stash…**：绑定打开时的首条 selector/OID，走相同 Reinstate Index 表单、校验和执行方法，不保留原无参数盲 `stashPop()`。会修改工作区的 Apply/Pop/Branch 复用 T1 保存/重载；只删 reflog 的 Drop 不因无关 dirty Tab 被禁用。失败不 Hard Reset 清 index，连接/机器变化不串目标。

**Red→Green / 验收：** 至少两个不同内容的 Stash，Apply/Pop 有/无 --index、Branch 成功移除、Drop 精确移除；冲突保留 stash/真实 index。弹窗期间新增/删除另一条时 Pop/Drop/**Branch** 不误用移位 selector；Apply 固定 OID 的内容正确。count 从真实列表派生，查询失败不假清零；Pop Latest 同表单/校验。取消、重名、换机器和保存失败留原内容；NativeUI 行右键/名称/字段/按钮、窗口与 VoiceOver 不串目标。

**提交边界：** 列表/菜单/模型/回归及 Git/UI/本地化文档同一提交；删原 stashCount 独立计数命令/存储和无参数 stashPop 盲执行，count 仅保留派生展示；无兼容 Pop 路由、双份缓存或执行器。

<a id="p4-t9"></a>
## P4-T9 全对象弹窗、真实副作用与本机/SSH 用户路径验收

**结果：** 以实际菜单 → 弹窗 → 每个按钮 → Git 持久结果验收 P4-T1～T8；上游适用项不遗漏，未覆盖的环境明确写明而不假称通过。

**入口 / Files：** `ToolPanelView → GitPanel → RecentCommitsView / GitEntryRow / PanelSectionHeader`、当前 `ContentView/TerminalManager/Project` 的窗口和机器绑定；`GitStatusModel → GitCommandExecution → WorkspaceBackend`；`DiffTab/PaneTab` 生命周期；现有 `KeroTests/NativeUI/Git/`、`KeroTests/Integration/Git/`、`KeroTests/WorkspaceUI/`。实测证据落在本 feature 的 `evidence-p4.md`（实施时才建立；这里不预建），最终审计由相应 Skill 创建，不用旧 `audit*.md` 下结论。

**步骤：**
1. 对照 [菜单矩阵](#菜单矩阵与边界) 与 [弹窗行为合同](#原生弹窗行为合同) **逐格**核验：Commit Root/Merge/Head，当前与非当前 Branch，Remote HEAD 和多 remote，Tag 两类型与折叠 `+N`，Stash 各序号，Uncommitted 标题、Staged/Unstaged/Conflict 文件、历史文件、Archive。检查默认字段、禁用理由、键盘焦点、主/次按钮、二次询问、取消和保留输入；不是只测 `perform` 被调用。
2. 复用 T1～T8 的临时 Git 库与 bare remotes，从真实原生菜单/弹窗触发，核对 HEAD/refs/index/worktree、Stash reflog、Tag、消息、TAR/ZIP 和服务器 Ref。覆盖重名两按钮、Force 三模式、Merge 选项、Cherry Pick -x/No Commit、Interactive、Reset/Drop、Tag Proceed（含 Add Tag 后取消 Push）、Reset File/Clean/Stash selector 移位，以及 Delete 继续/Push 首错停止的差别。共享 Merge/Pull 模型的 Git 组合测试不为每种 Ref 重复一套；各对象仍验证实际菜单路由、默认字段与按钮，不用纯 callback spy 替代最终结果。所有部分成功、取消和“未执行”项都准确反馈。
3. 按 [测试隔离](../../../docs/testing.md#隔离环境) 使用独立 Debug App 检查真右键和原生弹窗，不启动/结束用户正式 Kero。获授权的**专用** Windows SSH 测试连接和远端临时库另外实测；不能复用用户正在工作的 SSH master、修改正式仓库或在断线后落回 Mac。远端的 Push/Delete/Archive/Reset File 必须验证目标机器上的实际结果。缺 SSH 条件时只报告本机 Gate，P4 不冒称「SSH 全部验收」。
4. 各 task 在本 task Red→Green 后运行相关 XCTest、`make test`、`make build`/严格签名并按 development 整包安装，不重启用户 App；无需额外 Release 构建（除非实际触及其要求范围）。T9 汇总受影响回归及完整 App/专用 SSH 路径，按测试文档区分 Integration/NativeUI/WorkspaceUI/E2E；普通设置不因 isolated-ui-test 而隔离，Always 选项验收使用已核实的测试配置，不能改用户偏好。**旧代码清理、必要回归和 owner 文档不延后到 T9。** 实测遗漏归还原 task；Issue #2 的 SSH 外部刷新另需证据，不自动 Close。

**提交边界：** 用户路径证据和完成判断是交付；只有本地证据无源码变化时记 no_commit_reason。缺陷回原 task 同步修改/验证/提交；无真实 SSH 条件可单独报告本机结果，但 T9 不因此标 completed、P4 不宣称全验收。规划/证据文件默认本地维护，生产代码按中文标题、正文写清改动/原因/实际验证原子提交，不推送。

## 同任务清理与依赖顺序

按 T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 执行；不新增前置框架 task。

| Task | 替代接通后本 task 立即删除 | 保留的现行职责 |
| --- | --- | --- |
| T1 | 全局猜窗口、被替换 Commit 回调、错误的 Message 复制标签 | 唯一 perform、仓库/连接失效、冲突 Banner、Git 登录环境 |
| T3 | Branch-only 名称框/旧 branch createReference 路由；名称 helper 无调用时删 | 顶部 Create 默认 Checkout、Push/Publish 快捷语义；Tag 未迁移的调用留 T5 |
| T4 | remote Badge/+N 的只读特判、按 /HEAD 后缀过滤 | 单远端删除 fallback 的真实结果、symbolic HEAD 分类 |
| T5 | 最后的 CommitReferenceKind/createReference、右键 Show Tagged Commit | 左击 Tag 定位、同一 refs 查询、独立 Always 偏好 |
| T6 | 被替换的旧 Diff 来源参数/分支/初始化壳，不能保留两份来源真源 | 现行工作区/历史 Diff、当前快照业务、真实 stage fallback、唯一 TextKit 表面 |
| T7 | More Menu 盲 Stash、被替换的重复菜单分支 | PendingDiscard、Trash/SSH 删除审核、共享树、普通 FileTab/保存 |
| T8 | 独立 stashCount 查询/存储、无参盲 stashPop、含混 Pop 标签 | 派生 count、selector+OID 身份、同一刷新/执行 owner |

清理只在替代实现接通并通过对应回归后进行；提前删仍被未实施 task 使用的调用不是原子迁移。确认无引用才删除字符串。T9 只验收和回送真实遗漏，不承担集中清理。
