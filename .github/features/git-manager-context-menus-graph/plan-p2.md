# P2：Recent Commits 的对象菜单与指定 Commit 创建引用

**Goal：** 使 Commit 行、本地 Branch Badge、Tag Badge 和历史文件右键互不混淆；只新增在指定 Commit 创建本地分支/Tag 的操作，最大化复用现有 Kero 代码。

**Non-goals：** 不做独立 Remote Branch 菜单、Tag Push/Delete、Stash 列表、Changes 文件菜单翻新、Git Graph 全操作包或新菜单框架。

**Approach：** 在 `RecentCommitsView` 上使用原生 `.contextMenu`；只扩充少量当前模型没有、但这次对象菜单确实需要的 Ref 操作。现有 `GitEntryRow.menu` / `GitPanel.branchMenu` / `GitPanel.moreMenu` 不复制。

**Acceptance：** 右击 Commit/当前本地分支/其他本地分支/Tag/历史文件分别出现设计稿规定的动作；远端跟踪引用只显示；Commit 选定 SHA 上创建的引用确实指向该 SHA；Changes、冲突、未跟踪和暂存文件的现有菜单不变。

**Rules：** 新增本地 Ref 创建仍复用当前唯一 Git ViewModel（现名 `GitStatusModel`）→现有命令执行入口→`GitCommandExecution`→当前 `WorkspaceBackend`；直接接入已有的 `@MainActor @Observable` owner，不另建 Service/状态副本。保留操作互斥、仓库身份、所选 SHA 校验与失败提示；View 不发 Shell 命令。正式产品用 SwiftUI `.contextMenu`，不引入 HTML 菜单或另造 `NSMenu`。

<a id="p2-t1"></a>
## P2-T1 Commit、本地 Branch、Tag 与历史文件菜单路由

**Files / 锚点：** `kero/Git/RecentCommitsView.swift` `commitRow` / Ref Badge；`kero/Git/GitPanel.swift` `branchMenu` / `performOperation` / `openCommitDiff`；`kero/Git/GitStatusModel.swift` 当前 branch 和 refs；必要的原生 UI 检查。

**现有能力直接使用：** Commit 复制 SHA / Subject、标题点击展开、历史文件 Diff/复制路径；本地 `switchBranch(to:)`；顶部 `branchMenu`、Push/Fetch/More Menu 与 Git Entry 右键全部保留，不复制出另一套。

**实施：**
1. Commit 行右键提供「展开/收起历史文件」「在此创建本地分支」「在此创建 Tag」「复制 Commit SHA」「复制提交标题」；左键标题仍展开，单击短 SHA 复制完整值；历史文件继续有独立的 Diff / 复制相对路径。**不引入** Cherry-pick、Revert、Drop、Reset、Merge 或 Rebase。
2. 当前本地分支 Badge 的菜单**只复制分支名**；其他本地分支 Badge 只提供「切换到此分支」「复制分支名」（调用已有 `switchBranch(to:)`）。`origin/main` 等远端跟踪引用只显示胶囊，不弹出管理菜单，也不把它当成本地可切换分支。
3. Tag Badge 只提供「定位该 Tag 的 Commit」「复制 Tag 名称」，不加 Push/Delete；Badge 右键不落入 Commit 菜单。若过窄导致部分 Ref 折叠，使用 P1-T2 的 `+N` 可访问入口仍能进入各自菜单。所有命中维持 Kero 原有点击/焦点习惯。

**验证：** 同一 Commit 上同时存在当前本地分支、其他分支、Tag、远端跟踪 Ref；右击各自显示对应菜单，`origin/main` 无管理菜单；提交标题左键展开，短 SHA 点击复制，文件行右键 Diff/复制路径，Esc/键盘/VoiceOver 可达；检查 Changes 原菜单没有被意外改动。

**提交边界：** 仅 View 命中／菜单绑定、必要测试及受影响的 UI／Git 文档，一次提交，不夹带历史 Git 命令。

<a id="p2-t2"></a>
## P2-T2 在指定 Commit 创建本地分支与 Tag

**Files / 锚点：** `kero/Git/GitStatusModel.swift` `createBranch` / `perform` / `validate`，`kero/Git/GitPanel.swift` 现有建分支对话框及错误处理，`RecentCommitsView.swift` 菜单回调；`KeroTests/Integration/Git/GitStatusModelTests.swift`、`KeroTests/Integration/Git/GitExecutionTests.swift`；所属的 `kero/Resources/Localization/Git.xcstrings`／`Interface.xcstrings`。

**根因 / 范围：** 现有 `createBranch(named:)` 使用 `git switch -c <name>`，**只能基于 HEAD**。不能从历史 Commit 菜单直接调用并声称分支指向该 SHA。设计稿只要求以选中的历史提交创建**本地分支**或**本地 Tag**，不要求 Tag 推送/删除。

**实施：**
1. 从被右击 Commit 捕获仓库身份与完整 SHA。通过已有 Git 操作执行入口，用 `git branch <name> <sha>` 创建本地分支（**不自动 Checkout**），或用 `git tag <name> <sha>` 创建轻量 Tag；输入名称时明确显示目标短 SHA。执行前确认仓库上下文未切换，失败使用既有命令结果提示，不绕过 CommandBatch 日志。
2. Tag 创建成功后更新 Recent Commits 的 Ref Badge；已有 Tag 仍仅支持定位 Commit / 复制名称。**不得把 Tag 推送、删除或 GitHub Release 纳入本任务**；当前原型中的“创建”只是模拟，本机实际创建必须通过 Kero 现有 Git 操作后端执行。
3. 新能力复用 `GitStatusModel` 的忙碌状态、错误内容与完成后的 `refresh()`；没有第二套 Git 状态机，已有 branch/stage/stash 操作与文案不动。

**验证：** 临时 Git fixture 同时有 HEAD 与较旧 Commit：通过对应菜单新建的本地分支/Tag 必须解析到目标 SHA，且创建本地分支不切换 HEAD；重复名称不覆盖现有 Ref，取消输入不写入，切换仓库后不会写错目标；更新后可在该 Commit 显示 Badge。不会向任何真实远端 Push，也不在 Kero 仓库创建/删除 Tag；Mac 原生菜单检查目标身份，SSH 仅在获准隔离环境验证。

**提交边界：** 指定 SHA 的本地分支/Tag 创建、菜单接线、测试、必要文案及 [Git 功能契约](../../../docs/features/git.md)一次提交；删除被替代的冗余路径，不保留仅演示而不执行的正式产品菜单。
