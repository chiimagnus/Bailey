# P2：为真正需要的对象补充原生 Context Menu

**Goal：** Commit 行、本地 Branch Ref、Tag Ref 右击结果准确，并最大化复用现有 Kero 菜单/操作后端。

**Non-goals：** 不做单独 Remote Branch 菜单、Stash 列表/逐条管理、文件菜单翻新、Git Graph 全操作包或新菜单框架。

**Approach：** 在 `RecentCommitsView` 上使用原生 `.contextMenu`；只扩充少量当前模型没有、但这次对象菜单确实需要的 Ref 操作。现有 `GitEntryRow.menu` / `GitPanel.branchMenu` / `GitPanel.moreMenu` 不复制。

**Acceptance：** 右击 Commit/当前本地 Branch/其他本地 Branch/Tag 分别出现正确动作；正常文件、冲突、未跟踪、暂存文件的既有菜单与安全确认没有变化；不因 Badge 内嵌而误触发 Commit 展开、滚动或错误目标。

**Rules：** Git 写操作仍走 `GitStatusModel`→`perform`→`GitCommandExecution`→当前 `WorkspaceBackend`，保留操作互斥、仓库身份、HEAD 和 remote 校验、明确确认与错误详情；View 不发 shell 命令。不要使用 `NSMenu` 重造 SwiftUI 能表达的菜单。

<a id="p2-t1"></a>
## P2-T1 Commit、Branch 与 Ref 的专属菜单路由

**Files / 锚点：** `kero/Git/RecentCommitsView.swift` `commitRow` / Ref Badge；`kero/Git/GitPanel.swift` `branchMenu` / `performOperation` / `openCommitDiff`；`kero/Git/GitStatusModel.swift` 当前 branch 和 refs；必要的原生 UI 检查。

**现有能力直接使用：** Commit 复制 SHA / Subject、点击展开；本地 `switchBranch(to:)` / `push` / `fetch`；文件 Diff、Git Entry 右键。避免从顶部菜单复制一套分支选择器或把 `origin/main` 当作新的远端管理 UI。

**实施：**
1. Commit 行菜单：查看本次文件变化（沿用展开/现有 Diff），复制 SHA/标题；留好 P2-T2 的「在此创建本地分支」「在此创建 Tag」动作回调。**本期不加入** Cherry-pick/Revert/Drop/Reset/Merge/Rebase。
2. 已有当前和其他**本地**分支 Badge 用不同菜单：当前仅复制/Push/Fetch 的现有动作；其他分支可 Switch/复制，不可在当前分支上错误显示切换/删除。`origin/main` 若显示仅提供复制/查看引用，不加独立操作体系。
3. Tag Badge 右击不能冒泡给 Commit；Tag 先提供复制、查看所指提交，P2-T2 再接 Tag 变更动作。点击或右击 Badge 不改变 Commit 原有左键展开逻辑。

**验证：** 同一 Commit 上多个 Badge、Badge 与空白行边界、右键/左键、Esc、Tab/VoiceOver；已有上下文菜单动作路由到当前仓库；真实 `origin/main` 不出现本地 `Checkout`/远程删除等误操作。

**提交边界：** 仅 View 命中/菜单绑定及必要的测试，一次提交，不夹带历史 Git 命令。

<a id="p2-t2"></a>
## P2-T2 指向所选 Commit 的创建 Ref 与 Tag 操作

**Files / 锚点：** `kero/Git/GitStatusModel.swift` `createBranch` / `perform` / `validate`，`kero/Git/GitPanel.swift` 现有建分支对话框及错误处理，`RecentCommitsView.swift` 菜单回调；`KeroTests/GitStatusModelTests.swift`、`KeroTests/GitExecutionTests.swift`；必要的 `Localizable.xcstrings`。

**根因 / 范围：** 现有 `createBranch(named:)` 使用 `git switch -c <name>`，**只能基于 HEAD**。不能从历史 Commit 菜单调用它并声称分支指向选中 SHA；Tag 创建/推送/删除目前没有对应 Git Model 命令。

**实施：**
1. 从被右击 Commit 捕获稳定的仓库、范围与 SHA。通过现有命令执行入口，以指定 SHA 创建本地分支（默认不切换；如需切换由用户另选）或 Tag；弹出输入/确认前后校验当前仓库与 SHA。避免绕过 CommandBatch 日志和失败反馈。
2. Tag 菜单只保留针对已有 Tag 的「查看提交」「复制名称」「Push Tag…」「Delete Tag…」。发布与删除为明显的单独操作，明确目标 Tag 和 Remote；删除需确认，断线/无 remote/无该 Tag 时禁用或报可见错误。Tag 推送不自动创建 Release（GitHub 可能另有 Tag workflow，必须由用户主动确认推送）。
3. 新能力复用 `GitStatusModel` 的忙碌状态、错误内容和后续 `refresh()`，不建立第二套 Git 状态机；内置 branch/stage/stash 已存在行为不动。

**验证：** 临时 Git fixture 中同时存在 HEAD 与历史 SHA：创建的新分支/Tag 的 object ID 必须等于被右击 Commit，而非 HEAD；重复名称应失败且保留原 Ref；Push Tag 到临时本机 bare remote 的引用一致；取消删除不修改 Tag，确认删除只删指定 Ref。测试时不在真实 Kero 仓库创建/推送标签。Mac 原生菜单核对目标身份，SSH 仅在专用测试环境获准时实测。

**提交边界：** 被指定 SHA 的 Ref 操作、菜单接线、测试及必要文案一次提交；同时清掉替代的无用分支，不把操作列留为只显示不执行。
