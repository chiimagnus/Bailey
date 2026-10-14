# P4：补齐 Git Manager 的对象右键菜单

**关联：** [Issue #2](https://github.com/chiimagnus/kero/issues/2) · [需求](idea.md) · [现行代码对照与参考](research.md) · 原 P2 [已完成记录](plan-p2.md)。

**Goal：** 参照 Issue 原始 Commit 菜单截图、Git Graph 与 VSCodium 的 SCM/Git 菜单，把 **Kero 现有 Git Manager 中适用于对应对象**的操作补全，并在本机与 SSH 上遵守同一语义。旧 P2 仅完成基础菜单及新建 Ref；不改写旧 task 状态或审计来掩盖缺口。

**Non-goals：** 不复制 Git Graph 的独立全屏图谱、列配置、Branches Dropdown、Archive、PR Provider 或 Code Review；不新增 HTML 菜单、第三方 Git 引擎、冗余菜单框架。Kero 本身就是 Source Control View，不需「Open Source Control View」。未提供 PR Provider 前不得放假 PR 按钮。**不是**不做 Cherry-pick / Revert / Drop / Reset / Merge / Rebase / 远端管理。SSH **刷新问题**仍归 Issue #2 其它阶段，不因本阶段完成而自动认定整个 Issue 关闭。

**Approach：** 以 `RecentCommitsView.commitRow / referenceActions / changedFile`、`GitPanel.branchMenu / moreMenu / GitEntryRow.menu` 为唯一产品菜单入口；需要操作时经 `GitPanel.performOperation` 和现有确认表单交给 `GitStatusModel.perform` → `GitCommandExecution.run` → 当前 `WorkspaceBackend`。Model 拥有仓库身份、命令及回写，View 只展示对象和选择；已有 `DiscardContext`、请求 ID、`isBusy`、`repositoryOperation` 优先复用。新增特定状态必须来自当前真实 Git 操作，不为未来预建 coordinator 或缓存。

**Rules：** 遵守 [AGENTS.md](../../../AGENTS.md)、[Git 不变量](../../../docs/features/git.md#invariants)、[UI](../../../docs/ui.md)、[测试层次](../../../docs/testing.md)与 [安全边界](../../../SECURITY.md)。Git 参数通过 argv / 当前机器后端传递，特殊文件路径和 ref 不拼 Shell；点击时捕获对象，确认前后校验机器、仓库、后端连接、HEAD、相关 ref 及需要保持的 index/worktree 状态。任何写操作不得退回本机同名路径。用户未授权操作真实仓库/远端：所有实施实验使用临时 Git fixture 与专用 bare remote。

## 菜单矩阵与边界

下表是本阶段的**必须覆盖项**，不是原 P2 的旧版缩减清单；同一动作从多个入口出现时复用相同的 Model 方法，不复制执行逻辑。

| 右键目标 | 已有／需保留 | P4 必须补齐 | 出现条件及禁用说明 |
| --- | --- | --- | --- |
| **Commit 行** | 创建本地 Branch/轻量 Tag、复制 SHA/标题、整行左击展开文件 | Checkout 此 SHA（明确 detached HEAD）、Cherry-pick、Revert、**Drop**、Merge into current、Rebase current onto、Reset current to SHA（Soft/Mixed/Hard）、Compare Commit with HEAD/Ref/Merge Base | 无 HEAD、脏工作区、处理中、detached、不在当前分支祖先链、合并提交父节点等分别按**操作语义**判断；Drop 只在拓扑允许的当前本地线性历史启用；Merge Commit 的 Cherry-pick/Revert 必须选择主线父节点，不暗取第一个 |
| **当前本地 Branch Badge** | 复制名称 | Rename、Push 到明确的 remote | 不提供 Checkout 自己、删除当前分支、与自己 Merge/Rebase |
| **其他本地 Branch Badge** | Checkout/复制 | Rename、Delete（普通／明确强制）、Merge into current、Rebase current onto Branch、Push 此分支 | 不删除其它 worktree 正检出的分支；Rebase/Merge 不能在未处理冲突时启动；按目标 ref 而非 HEAD Push |
| **远端 Branch Badge** | 目前只读显示 | Checkout 为本地跟踪分支、Fetch 到本地分支、Pull into current（明示 FF-only）、Delete Remote Branch、复制名称 | 完整 `refs/remotes/<remote>/<branch>` 身份；`origin/HEAD` 不当成真实分支，目标不存在、无 remote 或远端不可达时不能误执行；不自动 Force Push |
| **Tag Badge / 在 Commit 新建 Tag** | 定位提交、复制、创建轻量 Tag | 可选注释 Tag 创建、查看注释信息、删除本地 Tag、Push **所选** Tag、删除所选 remote 的 Tag | 注释信息只对 annotated Tag 显示；本地删除不等于远端删除，推送不等于 Release；一个提交多 Tag 及 `+N` 中保持独立菜单 |
| **具体 Stash 条目** | 仅有 Stash All、默认 Pop 和 stash 数量 | 选择单个 Stash：Apply、Pop、Drop、Create Branch from Stash、复制标识 | 在现有 GitPanel 中以紧凑 Stashes 列表展示条目并支持逐行原生右键，而非新 Dock 面板；More Menu 可保留明确的快捷动作；执行前确认 reflog 条目仍是所选 OID，禁止因 stash 序号变化误操作 |
| **MERGE / STAGED / CHANGES / Untracked 分组与文件行** | Open Changes/File、Stage、Unstage、Discard、Finder/复制路径、分组批量按钮 | 对照 VSCodium 补 Open HEAD/Index 修订（存在时）、工作区比较、适用的 Ignore；分组右键提供已有 Stage All、Unstage All、Discard All、Clean Untracked、Stash 的正确归属 | 已暂存文件不得误当未暂存丢弃；冲突行保留独立处理；未跟踪删除走已有确认/Trash 保护；共享 `TreeFileRow` 不复制 |
| **历史文件/目录** | 历史 Diff、复制相对路径、目录折叠 | 查看指定 Commit 中的文件版本、与当前工作区比较、适用时打开当前文件、复制绝对路径 | 按实际历史 SHA、父 SHA 与重命名路径解析；删除/缺失文件不假装历史版本存在，SSH 文件不调用 Mac Finder |
| **进行中 Git 操作** | 现有 `repositoryOperation` 文字提示 | 根据实际 Cherry-pick/Revert/Merge/Rebase 类型在既有提示中提供 Continue/Abort、合法时 Skip | 冲突不被隐式 `reset --hard`；保留真实 index/worktree、失败输出和手动重试 |

**禁用不等于功能删减：** 每项不适用必须有明确上下文条件和可识别的禁用/隐藏理由；只有对象在 Git 语义上不存在或无对应产品入口时才不展示。Git Graph 中 Create Archive、PR 创建、列可见性与第三方链接属于 Kero 当前没有的对象或服务，不因“完整”而加入空菜单。Git Graph 的 Drop 原文也注明“仅在拓扑允许时”。

**共通 Gate：** 每个实施 task 都先以现有 XCTest 写 Red → 修复 Green → 按当次风险检查临时 Git 的 HEAD、refs、index、worktree 与 remote → 同 task 更新 `docs/features/git.md` 和需要的 `docs/ui.md`、`docs/features/files.md`、字符串表 → 删除替代的冗余路径 → 原子中文 commit。涉及复杂 Git 命令先在临时仓库证明参数和失败路径，再放入产品 Model；不能写成「执行时再找命令」。NativeUI 证明菜单/对话框，Integration 证明真实 Git 副作用；最终真实 App/SSH E2E 另行验收。

<a id="p4-t1"></a>
## P4-T1 Commit 的 Checkout、Cherry-pick、Revert 与 Merge

**结果：** Commit 右键四项是真实执行的 Git 操作，失败与冲突可恢复，不丢本地工作。

**入口 / Files：** `RecentCommitsView.commitRow`（保留已有复制/创建及整行左击）；`GitPanel` 当前 `createReference` 回调、`presentGitNameDialog`、`performOperation`、`repositoryOperationBanner`；`GitStatusModel` 的 `RecentCommit.parentHashes`、`perform`、`detectRepositoryOperation` / `remoteRepositoryOperation`；`GitCommandExecution` 与 `WorkspaceBackend`；`KeroTests/Integration/Git/GitStatusModelTests.swift`、`KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`。

**实施：**
1. 把 Commit 操作接到唯一 `GitStatusModel`；`git switch --detach <SHA>` 需提示 detached HEAD；`cherry-pick`、`revert`、`merge` 以所选 SHA 作为 argv 执行，不用 Git 顶部当前 HEAD 菜单偷换目标。为 merge commit 的 Cherry-pick/Revert 显示父节点选项并传明确的 `-m` 参数；不默默选第一父。
2. 对工作区变更、进行中操作、用户取消和上下文切换按命令实际前提处理。确认/菜单阶段和最终执行阶段都检查当前机器、repoRoot、HEAD 与所选 Commit；复用既有操作互斥、错误显示与刷新。
3. 现有 `repositoryOperation` 已探测 `MERGE_HEAD`、`CHERRY_PICK_HEAD`、`REVERT_HEAD`、rebase 标记，但只输出字符串/「去终端恢复」。在**同一个所有者**上为这些真实状态提供类型与对应 Continue/Abort/合法 Skip，重用现有冲突文件 Stage/操作提示；不增加第二个状态机，绝不在 Git 命令失败后自动丢弃工作区。

**Red→Green / 验收：** 临时 Git 图含普通、合并和有冲突的提交；真实 `rev-parse HEAD` / `log` 验证 Checkout、Cherry-pick、Revert、Merge 结果；merge-commit 主线父选择确实影响结果；有未暂存/已暂存改动、已存在 rebase/merge、取消、异步切仓库时原状态保留；冲突后 Continue/Abort 的 Git index/HEAD/工作区真实一致。NativeUI 断言点击行与各 Ref 菜单不串、标题/SHA 与原左击保留；不能只验证 `perform` 被调用。

**提交边界：** 四类 Commit 操作和它们实际需要的冲突恢复、接线、测试、本地化与 Git 文档一份原子提交；不提前夹带 Reset/Drop 代码。

<a id="p4-t2"></a>
## P4-T2 Commit 的 Rebase、Reset 与条件 Drop

**结果：** 将历史改写作为显式操作呈现，包含不同 Reset 模式和拓扑有效的 Drop，而不是用 Revert 或 Reset 冒充 Drop。

**入口 / Files：** `RecentCommitsView.commitRow`；`GitPanel` 原生确认入口、`repositoryOperationBanner`；`GitStatusModel.RecentCommit.parentHashes` / `headOID` / `branch` / `perform`、已有 `refreshPending`；`GitCommandExecution`；`GitStatusModelTests`、`RecentCommitsViewTests`。

**实施：**
1. Rebase current onto 选定 Commit 使用实际 `git rebase` 语义，只有正常本地分支、无进行中的其它操作且仓库前提满足时启用；冲突复用 P4-T1 同一状态提示和 Continue/Skip/Abort，不单独造恢复面板。
2. Reset current to Commit 明确列出 Soft/Mixed/Hard 影响 HEAD/index/worktree；原生确认中由用户**显式选择**模式，尤其 Hard 显示会丢弃哪些本地改动，并在真实执行前再次校验当前仓库、HEAD 和工作区/索引。不自动 stash，不默认执行 Hard。
3. Drop：先在临时分叉图上验证正确 Git 语义（删除目标提交并重放其后的当前分支提交），实现限于当前本地分支的第一父**线性**祖先链，确认被改写区段没有需要保留的其它可达本地/远端/Tag Ref，所选 Commit 非 merge/root 且与当前仓库一致；符合条件时基于 `git rebase --onto <parent> <selected> <current>` 等已在 fixture 证明的命令执行。分叉/合并、共享 ref、已发布或无法确定受影响范围时禁用并说明原因；`git reset` 和 `git revert` 不是 Drop 的替代品。
4. 更新原生确认中的 before/after SHA、ref、脏状态；Git 中止后保持原始状态与失败信息。仅当 Git 实际成功才刷新图谱与 Ref；保留 reflog 中可恢复的提交，不暗中强推远端。

**Red→Green / 验收：** 构造 A→B→C→D 与分叉/merge 临时仓库：Drop B 后只在合法路线得到 A→C'→D'，B 不再属于当前分支且其他 refs 不变；分叉、Tag/远端标记、根/merge Commit 禁止错误 Drop。分别验证 Reset soft/mixed/hard 的 `HEAD`、index、worktree；Dirty/取消/切仓库/确认间变更不写入。Rebase 有成功、真实冲突和 Abort/Continue，确保冲突不是静默视为成功。

**提交边界：** 历史重写动作、前提/确认、对应回归和 Git 文档同一提交；不修改旧 P2 新建分支的既有正确行为。


<a id="p4-t3"></a>
## P4-T3 当前/其他本地分支的管理菜单

**结果：** 原来只能 Checkout/复制的 Branch Badge，按当前与非当前分支语义拥有 Rename、Delete、Merge/Rebase、针对该分支 Push。

**入口 / Files：** `RecentCommitsView.referenceBadge / referenceActions` 与 `referenceStrip` 的 `+N`；`GitPanel.branchMenu` / `presentGitNameDialog` / `performOperation`；`GitStatusModel.branches / branch / remotes / switchBranch / createBranch / push / perform`；`GitStatusModelTests`、`RecentCommitsViewTests`、`docs/features/git.md`、`Git.xcstrings`。

**实施：**
1. 当前本地分支：保留复制，新增 Rename（`git branch -m` 且不自动改工作目录）和定向 Push；不出现切换到自身、删除自身、Merge/Rebase 自身。其他本地分支：保留 Checkout/复制，新增 Rename、Delete（默认 `git branch -d`；只在用户明确确认且确实允许时单独 Force Delete）、Merge into current、Rebase current onto 分支、Push this branch。Merge/Rebase 与 P4-T1/T2 复用同一方法和恢复逻辑。
2. 对话框绑定**被右击**分支的完整 `refs/heads/...`，不是当前 HEAD；再次验证它仍指向打开时的 OID。检测该分支是否在另一个 worktree 中检出；Git 拒绝时清楚显示。重名、新名非法、多个 remote 与已发布/未合并分支分别明确处理，不自动使用 `-M`、`-D` 或 `--force`。
3. Push 由用户选择具体 remote 与目标分支 ref，非当前分支也准确 Push 自身；沿用现有凭据/失败/后台执行路径。直接显示的 Badge 与 `+N` 子菜单有同一功能，顶部 `branchMenu` 继续复用而不是第二套实现。

**Red→Green / 验收：** 临时本地及 bare remote：当前与其他 Branch 的 Rename、safe Delete、明确强制删除、Push 目标实际生效；默认拒绝未合并删除、不能删除当前或其它 worktree 正检出的分支；Merge/Rebase 后当前分支 HEAD 正确且非当前 refs 不被无关移动。重名、脏树、分支在确认期间变化、远端选择取消均不写错；原生菜单和 `+N` 中的动作一致。

**提交边界：** 本地分支对象动作和接入、回归、Git 文档/文案同一提交；如已有分支功能完全等价，直接调用，不重写。

<a id="p4-t4"></a>
## P4-T4 远端跟踪分支的独立菜单与真实远端操作

**结果：** `origin/feature` 不再只是只读胶囊；Checkout tracking、定向 Fetch/Pull、Delete Remote 与复制按目标身份正确执行。

**入口 / Files：** `RecentCommitsView.referenceBadge / referenceActions` 的 `.remoteBranch` 及 `+N`；`GitStatusModel` 当前 `remotes`、`recentCommits`、`fetch / pull / perform`、typed Ref 解析（`parseRecentCommits`）；`GitPanel` 确认/远端选择；`GitCommandExecution` → `WorkspaceBackend`；`GitStatusModelTests`、`GitExecutionTests`、`RecentCommitsViewTests`。

**实施：**
1. Ref 身份以 Git 完整 ref 路径与当前配置的 remote 解析，不能简单把 `origin/name` 文案作为未校验的 shell 参数；`refs/remotes/<remote>/HEAD` 是符号引用，禁止当成可删真实分支。右键提供「Checkout 为本地跟踪分支」「Fetch into local branch」「Pull into current (FF-only)」「Delete Remote Branch…」「Copy Branch Name」，并在 `+N` 同步提供。
2. Checkout 用明确的远端分支与新本地名称（若名称已存在，提示选择另一名称或明确切换已有本地分支，不隐式覆盖）；Fetch into local 只允许更新**未在任何 worktree 中检出**且符合 Git 正常非强制快进规则的本地分支；Pull into current 保持 Kero 已有 `--ff-only` 原则，不悄悄变成 Merge/Rebase。确需合并时使用 P4-T3 的显式 Merge 操作。
3. Delete Remote 需用户显式确认 remote 和 `refs/heads/<branch>`，真正目标为该 remote 的服务器端分支而非仅本机 `refs/remotes/...`；不默认 Force，不删错默认分支或其它 remote 的同名分支。操作前与执行时重新核对本地快照及远端目标引用；远端拒绝、断线和慢响应保留错误，不回退本机；成功后 Fetch/刷新引用。
4. 不创建一个新的 Remote Branch 页面，原有分支标题、Fetch/Pull/Push 与本地菜单继续使用；与 VSCodium/Git Graph 的历史 Ref 菜单语义对照，但不复制 PR/Archive。

**Red→Green / 验收：** 两个独立本地 bare remote（同名不同 commit）、多个本地分支和 `origin/HEAD`，证明 Checkout tracking、Fetch 的快进与拒绝、Pull FF-only 成功/分叉拒绝、Delete Remote 只删除被选中服务器 ref；`ls-remote` 与本地 `for-each-ref` 双重验证。模拟 SSH 后端检查实际 argv/机器身份，真实 Windows SSH 的 Git E2E 在 P4-T8 完成；确认窗口期间切 remote、断线或 ref 更新不误操作。

**提交边界：** 远端 Ref 身份、菜单、服务端 Git 写入、定向失败处理、测试及 Git 文档一份原子提交。

<a id="p4-t5"></a>
## P4-T5 Tag 的创建类型、详情与本地/远端管理

**结果：** Tag 不再只有复制/定位，能明确创建轻量或带注释 Tag，查看注释、删除本地 Tag、推送指定 Tag、删除指定远端 Tag。

**入口 / Files：** `RecentCommitsView.referenceActions` / `+N` 与 Commit 上「Create Tag…」；`GitPanel.presentCreateReferenceDialog / presentGitNameDialog / performOperation`；`GitStatusModel.createReference / perform`、`RecentCommit.Reference(.tag)`、`remotes`；`GitStatusModelTests`、`RecentCommitsViewTests`，`kero/Resources/Localization/Git.xcstrings`、`docs/features/git.md`。

**实施：**
1. 在旧 P2 以指定 SHA 创建**轻量 Tag**的真实路径上增加明确的「轻量 / 带注释（需填写注释）」选择，保留从选定 Commit 创建、不改变 HEAD、不自动 Push 的语义；采用 Git argv 传注释内容，不能触发交互式编辑器或 Shell 插值。
2. Tag Badge 的独立菜单提供「定位 Commit」「查看 Tag 详情」（仅 annotated，按当前 Tag 的实际对象类型读取 Tagger/注释）、「Delete Local Tag…」「Push This Tag to Remote…」「Delete This Tag on Remote…」「Copy Tag Name」；推送/删除必须是**指定** `refs/tags/<name>` 与由用户选定的 remote，不传 `--tags`，本地删除不能偷偷删远端。不存在的远端 Tag 不展示为已推送。
3. 现有 `RecentCommit.Reference` 只含 `kind/name` 而非注释类型或服务器端 Tag 状态：按需从真实 Git ref 对象/远端读取，不能凭胶囊颜色或猜测全部为轻量 Tag。捕获选中 Tag 的 ref OID，确认后核对是否仍相同，再执行删除/推送；保留当前 SHA 与其它同提交 Tag。确认框应显示本地/远端、Tag 名及目标。
4. `+N` 隐藏 Tag 与直接展示 Tag 有相同子菜单；不增加 GitHub Release 创建、Tag 列表专用 Dock 或独立 Git 操作状态机。

**Red→Green / 验收：** 临时仓库含同一提交的轻量及 annotated Tag（含特殊合法名称）、两个 bare remotes：`git cat-file -t` / `show-ref` / `ls-remote --tags` 验证类型、目标、注释、定向 Push/删除、本地与远端边界；取消、Tag 目标变化、重名、无 remote、远端拒绝与 SSH 断线不写错。Tag 删除后提交仍在，既不新增 Release 也不自动 Push 其它 Tag。

**提交边界：** Tag 对象行为与需要的按需读取、菜单/对话框、测试/文案/文档同一提交；旧轻量 Tag 路径直接整合而非保留两套创建入口。

<a id="p4-t6"></a>
## P4-T6 历史文件/目录的修订操作菜单

**结果：** Commit 的 Compare with HEAD/Ref/Merge Base 与历史文件的阅读、版本比较都基于真实 Git 修订，不读取错误版本也不修改当前文件。

**入口 / Files：** `RecentCommitsView.commitRow / commitFiles / changedFile / displayRow`（Commit 比较与历史文件菜单）和共用 `TreeFileRow / TreeFolderRow`；`GitPanel.openCommitDiff` → `ToolPanelView` → `TerminalManager.openCommitDiff` → `Project.openCommitDiff` 与已有 `DiffTab`；`GitStatusModel.RecentCommit.FileChange.originalPath / parentHashes`；`WorkspaceBackend` 的真实路径读取；`KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`、`KeroTests/NativeUI/Git/DiffTabTests.swift`。

**实施：**
1. Commit 菜单对照 VSCodium `scm/historyItem/context` 补「Compare This Commit with HEAD」「Compare with Branch/Tag」「Compare with Merge Base」（仅有实际两个不同 ref 与唯一可确定的合并基点时）。使用 Git 对两端真实 OID 的文件差异计算，结果以现有 Diff/文件列表交互呈现；不能把某提交自带的单次变更列表冒充两引用之间的完整差异，也不额外改写 HEAD。
2. 历史文件菜单保留「Open Historical Diff」「Copy Relative Path」，补「View File at Selected Revision」（只读）、「Compare This Revision with Working File」、「Open Working File」（仅实际存在时）、「Copy Absolute Path」；历史目录只提供当前适用的复制/定位动作，不在目录右键放文件级命令。
3. 根据所选 Commit 完整 SHA、合并第一父及 `originalPath` 处理 Added/Modified/Deleted/Renamed/Copied。文件在选中提交后已删除时不得 `git show <commit>:<path>` 冒充成功；需要显示删除前内容时明确标注「View Before Deletion」并读取有效父提交。历史修订视图只读，与工作区比较不改写真实工作文件；沿用现有内容大小/二进制数据边界，不能把 blob 任意解成 UTF-8 后宣称内容完整。
4. 新菜单重用现有 Diff/Editor/PaneTab 内容所有者和文件树组件；本机可用的打开文件及复制路径使用现有入口，SSH 通过当前 Backend 加载真实远端文件，绝不拿远端路径交给 Mac Finder。仍保留整行提交左击、图谱连续性、文件列表懒加载与文本独立横向滚动。

**Red→Green / 验收：** 不同 HEAD/本地 Branch/Tag、可求/不可求唯一 merge-base 的临时提交图，核对双端差异文件集合和实际 Diff bytes、不会改动任何 ref；多次历史提交含重命名、删除、带空格/换行路径与不同当前工作区内容：核对展示的实际提交 blob bytes、与 working 文件的 Diff、文件只读和打开当前文件的准确目标；没有所需 blob 或远端断线有明确失败而不回退本机；NativeUI 验证文件行独立菜单、路径复制、整行展开和无障碍。历史文件菜单不能把“查看版本”误做“签出覆盖工作区”。

**提交边界：** 历史菜单、必要的现有内容接线、验证和 Git/Diff/文件文档同一提交；不创建脱离真实 PaneTab 生命周期的预览缓存。

<a id="p4-t7"></a>
## P4-T7 工作区文件与分组菜单对齐 VSCodium 的 SCM 行为

**结果：** MERGE、STAGED、CHANGES（含 Untracked）的**单个文件、目录及分组标题**右键完整、正确，不再出现“标题有按钮却无右键动作”或把已暂存当作未暂存删除。

**入口 / Files：** `GitPanel.changedFileRows / row / GitEntryRow.menu / entryStatus`、MERGE/STAGED/CHANGES 对应的 `PanelSectionHeader`、已有 `GitStatusModel.stage / unstage / discard / stageAll / unstageAll / discardChanges / prepareLocalDiscard / prepareRemoteDiscard`；`TreeDisplayModel / TreeFileRow / TreeFolderRow`；`GitStatusModelTests` 与 `KeroTests/NativeUI/Shared/TreeRowHitTestingTests.swift`。

**实施：**
1. 逐组对照 VSCodium `scm/resourceState/context` / `scm/resourceGroup/context` / `scm/resourceFolder/context`：MERGE 保留打开冲突及 Mark Resolved；STAGED 保留打开 Diff/文件、Unstage，补条件允许的查看 HEAD/Index 版本；CHANGES 保留 Stage/Discard/打开文件，补适用时比较 HEAD/工作区；Untracked 只出现真实适用的 Open、Stage、Delete/Ignore。文件在 HEAD/Index 没有 blob 时不得显示虚假读取。
2. 分组标题/目录右键提供同种类的 Stage All、Unstage All、Discard All、Clean Untracked；CHANGES 可使用已有 Stash 操作，明确是否包括未跟踪内容。批量写入复用既有 Model 及 `PendingDiscard` 确认，**单个已暂存文件不得因为菜单选错分组而清空工作区**。已有悬停按钮与右键菜单只共享同一动作，不重复状态和文件树。
3. 按 VSCodium 补 Untracked 的「Ignore」：只修改本仓库合适的 `.gitignore` 内容并处理路径字面量/通配符转义，保留原文件、换行、编码和用户已编辑的内容；执行前核对目标仓库与当前文件状态，取消或写入冲突必须保留原文件。已跟踪文件和不可忽略对象不得误显示。远端通过当前 Backend 操作，不能写到 Mac 同路径。
4. 不新增只有代码编辑器选区才成立的 `Stage Selected Ranges` 或独立 Source Control 页面入口；不删现有 `GitEntryRow` 的 Finder（仅本机）、复制路径、终端插入和共用树行命中/滚动。

**Red→Green / 验收：** 真实临时仓库覆盖 staged-only、unstaged-only、同一路径 staged+unstaged、冲突、未跟踪、改名、目录、特殊路径：按右键执行后分别核对 Git index 与 working bytes，测试过期丢弃确认、批量 Cancel、本机 Trash/SSH 删除边界、忽略规则确实生效但不抹除现有 `.gitignore` 内容；本机/SSH 后端目标一致。已打开但未保存的 `.gitignore` 编辑不得被外部直接覆写。原生行/目录/分组右键与 hover 动作一致，短名称不回弹、长名称可滚动、操作按钮不跟随滑动。

**提交边界：** 文件/分组菜单与真正缺少的文件操作、现有共享树测试、对应 Git/Files/UI 文档和文案在同一提交完成。

<a id="p4-t8"></a>
## P4-T8 具体 Stash 的选择、右键和生命周期

**结果：** 现有「Stash All Changes」「Pop Stash」不再只能盲操作栈顶；用户能在 Git Manager 的实际 Stash 行上右击所选条目，再 Apply、Pop、Drop 或从该 Stash 创建分支。

**入口 / Files：** `GitPanel.moreMenu` 中已有 `stashCount`、`model.stash / stashPop`，GitPanel 现有 `PanelSectionHeader` 与共享树行（增加紧凑 Stashes 区域，不增加新 Dock/独立屏幕）；`GitStatusModel.runGitStatus` 的 `stashCount`、`perform` / `refresh`、`WorkspaceBackend`；`GitStatusModelTests`、`RecentCommitsViewTests` 或同层原生 Git Menu 测试。

**实施：**
1. 在现有 Git Manager 区域最小增加可折叠的 **STASHES 条目列表**，沿用现有区块标题与树行外观，每条显示 Stash 标识、说明、可辨识的 OID（按需读取 `git stash list` / reflog，而非在 Recent Commits 里硬塞新对象），在该行原生 `.contextMenu` 提供「Apply」「Pop」「Drop…」「Create Branch from Stash…」「Copy Stash Name/Hash」。More Menu 中已有 Stash All 与 Pop latest 如保留快捷入口，必须复用相同的栈顶执行方法，避免重复、行为不同的菜单。
2. Apply 保留 Stash，Pop 只在应用成功时从 stash reflog 删除，Drop 仅删所选 stash，Create Branch from Stash 确认新分支与当前 checkout 的变化（Git 成功后会移除对应 reflog 条目的条件要如实提示），不悄悄改变其他 Stash；有冲突时保留 Git index、用户修改及未应用的 stash，不能默默 `reset --hard`。
3. **Stash 的 `stash@{n}` 序号可能改变。** 菜单读取时记录具体 OID/selector，用户确认后再次验证 reflog 条目指向原 OID 再执行；多仓库/多远端机器不共享列表或选中项。使用 Model 现有 busy/error/refresh，按需读取而非前台无界轮询，不新增 Stash 专用 ViewModel/持久化数据库。

**Red→Green / 验收：** 两个及以上不同 Stash（含 staged、untracked、修改冲突）在真实临时仓库中分别 Apply/Pop/Drop/Branch：核对 `git stash list`、refs/heads、HEAD、index 和工作区内容；模拟在确认期间另有 Stash 新增/移除，旧选择不得误删或误应用；取消、新分支重名、无 Stash、远端不可用显示明确结果。原生 Stash 行右键能访问每个条目，More Menu 快捷入口不会误操作选中行，键盘/VoiceOver 有对应名称。

**提交边界：** Stash 单对象菜单、按需列举与受控执行、测试和 Git 文档/本地化同一提交；没有另一套 Stash 状态所有者。

<a id="p4-t9"></a>
## P4-T9 全对象菜单与本机/SSH 完整用户路径验收

**结果：** 用独立的真实产品路径核查 P4-T1～T8 的菜单与 Git 副作用，不把 UI 事件派发、`make test` 或假的远端命令当成全部实现。

**入口 / Files：** `ToolPanelView → GitPanel → RecentCommitsView / GitEntryRow`，`ContentView` 的当前项目/机器接线；`GitStatusModel` 和 `WorkspaceBackend`；已有 `KeroTests/NativeUI/Git/`、`KeroTests/Integration/Git/`、`KeroTests/WorkspaceUI/`；完成时记录实际证据到本 feature 的 `evidence-p4.md`（**现在不预建**），审计时由工具创建 `audit-p4.md`。

**步骤：**
1. 对照上面的菜单矩阵逐行勾验：Commit 正常/merge/root、当前/其他本地分支、远端分支/远端 HEAD、轻量/annotated Tag、`+N` 折叠 Ref、Stash 各序号、历史文件与 staged/unstaged/untracked/merge 文件及分组；每个菜单核对文字、可访问性、禁用原因、确认选中的 ref/SHA 和取消不落盘。
2. 使用真正临时仓库与 bare remotes，从 Kero 原生菜单 → 确认 → `GitStatusModel.perform` → 真实 Git 命令 → refs/HEAD/index/worktree/remote 持久结果 → UI 刷新全链取证；场景必须包括脏工作区、冲突 Continue/Abort、Reset Hard、Drop、远端删除、Stash 错序选择、切换项目/机器和回滚后重试。回归已完成 P1～P3 的滚动、图谱与历史分页。
3. 使用 [测试规范](../../../docs/testing.md#隔离环境) 允许的独立 Debug App 隔离窗口执行真正的用户右键路径，保留用户运行中的 Kero。对 **真实 Windows SSH** 只使用专用且获准的测试连接/临时仓库，不借用用户 SSH master、不操作正式项目；证明写的是 Windows 上的 Git 仓库，断线/超时不误回写 Mac。同名 Mac 和 SSH 路径构造防串仓库测试。
4. 按真实结果运行相关 XCTest、`make test`、`make build` 及严格签名校验；受影响文档按各 task 已同步，P4-T9 只修实测中遗漏的接线/验收问题，不把必要代码测试拖到最后。缺独立进程操作能力或专用 SSH 环境时**不得标记最终 Gate Go**：写明可复现阻塞和未测范围，保留任务 pending/blocked，不能说“自动化通过所以远端已验收”。

**提交边界：** 以产品侧 E2E/回归证据为结果；若仅产生本地证据而无代码变更，按 `feature_tool.py` 记录 `no_commit_reason`。实际修复按归属回到原 task 的源码、测试与文档，在对应原子提交完成；不为“最终集成”另建长期测试执行器。只有 P4 全项验收并独立审计通过，才可把 P4 标记完成；Issue #2 仍需其独立 SSH **刷新**缺口核对后才能关闭。

