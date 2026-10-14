# Git Manager 调研：P1～P3 历史决策与 P4 菜单补齐依据

> 本文前半记录最初收缩的 P2 需求和当时的源码状态，保留供追溯；**2026-10-14 的 P4 新需求以文末的最新实证为准**，旧版「不做」不再限制本轮菜单。

对应 [Issue #2](https://github.com/chiimagnus/kero/issues/2) · [Recent Commits 设计稿](design.html)。研究依据为 **当前 Kero 源码**、Issue 中的 Git Graph 截图（两行提交、主干/多色分叉、Ref/短 SHA/作者/时间）与 Git Graph 官方材料，不把 Git Graph 的全量菜单当作 Kero 需求。

## 一手参考

- [Git Graph 仓库 README](https://github.com/mhutchie/vscode-git-graph)：区分 Commit、Branch、Tag、Stash、未提交变更与历史文件的菜单归属，以及图谱、Refs、详情界面。
- [Git Graph Context Menus](https://github.com/mhutchie/vscode-git-graph/wiki/Context-Menus)：参考原生语义和动作分类，**不直接迁移全部菜单项**。Issue 中也附有其 Commit 菜单截图。
- [Apple SwiftUI contextMenu](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:))：正式 UI 使用 SwiftUI `.contextMenu`；右击对象本身决定 Menu 归属，不在 App 中引入自绘 HTML 菜单。
- Kero 本地 [Git 维护约束](../../../docs/features/git.md)、[安全](../../../SECURITY.md)、[文件与共享树](../../../docs/features/files.md)和仓库 [AGENTS.md](../../../AGENTS.md)，以及用户提供的当前界面截图。

## 已经有的功能：无需再做

| 现有代码入口 | 已有行为 | 本次处理 |
| --- | --- | --- |
| `kero/Git/GitPanel.swift` `branchMenu` | 显示当前分支、切换本地分支、从 HEAD 新建分支 | 直接复用；只给需要的 Ref Badge 提供正确菜单命中 |
| `GitPanel.moreMenu` | Fetch、Pull (FF-only)、Push/Publish、Sync、Stash All/Pop、复制仓库路径 | 保留顶部菜单，不再创造独立的 Remote/Stash 管理 UI |
| `GitPanel.commitBox` / `commitMenu` | 提交已暂存、全部暂存并提交、Amend | 不重做提交框，不重做提交功能 |
| `GitEntryRow.menu` | merge/staged/unstaged 不同菜单，Stage/Unstage/Discard，本机 Finder、复制路径、终端插入 | 全部保留；远端和未跟踪删除走原有保护 |
| `GitPanel.changeList`、`TreeDisplayModel`/`TreeFileRow` | MERGE/STAGED/CHANGES、目录压缩、共享行、分组动作与懒加载 | 仅展示/复用；不生成重复树组件 |
| `RecentCommitsView` `changedFile` / `commitFiles` | 点击展开历史文件；打开历史 Diff，复制文件路径；保留 Tree / List 视图 | 不新造历史 Diff、文件管理器 |
| `GitStatusModel` `refresh`/`loadMoreCommits` | 异步刷新、请求 ID、待处理合并、超时、30 条分页、失败/断线反馈 | 在这里和实际事件入口定位刷新延迟，不能直接推翻其既有防护 |

## 确实缺少的增量（有源码证据）

- 2026-10-14 源码复核：`GitStatusModel` 已是 `@MainActor @Observable`，继续复用 `GitCommandExecution` 与 `WorkspaceBackend`。新能力沿此唯一 Git ViewModel 接入，不重复进行 Observation 迁移或引入平行服务。所有权见[当前架构](../../../docs/architecture.md#唯一所有者)，测试使用[分层 XCTest](../../../docs/testing.md)，不是旧独立检查脚本。

1. **Commit 与 Ref 菜单归属**：`RecentCommitsView.commitRow` 整行放在一个 `Button` 中，右键仅复制 Hash/Subject；`primaryReference` 把一个引用挑成单一字符串胶囊。真实 Tag Badge 尚未独立呈现或拥有自己的 `.contextMenu`。需分离 Commit 行与 Ref Badge 的命中，不能用一个统一的菜单判断“点击位置”的字符串。
2. **选定提交创建 Ref**：`GitStatusModel.createBranch(named:)` 当前用 `git switch -c <name>` 从 HEAD 建立；不能用于“在历史 Commit 建分支”。需要在已有 `perform` 命令/身份校验链下增加以指定 SHA 创建本地分支/Tag 的路径；**不增加 Tag Push/Delete、远端操作或发布流程**。
3. **真实合并/分叉**：`GitStatusModel.runGitStatus` 已使用 `git log ... %P ... %D` 一次拿到**完整父哈希与引用字符串**；但 `parseRecentCommits` 截断为首个 `parentHash`，`CommitTreeRails` 仅在 X=14 画单直线。应复用已有数据扩展 Model，并在 RecentCommitsView 中布局车道，而不是加一套网络查询。
4. **外部变更没有稳定的刷新触发证据**：`ContentView.syncGit` 监听 app 激活、terminal command completion 与项目切换；`ToolPanelView.pollsSelectedPanel` 明确排除 `.git`，并在 `performSync` 的 `.git` 分支不调用 `git.refresh()`。因此持续前台、外部程序修改仓库的情形**可能缺少刷新触发**。这只是静态可达路径证据，需复现实测后确认是否就是 Issue 的根因；现有 `GitStatusModel.refreshPending` 并发合并本身不是已证实的 bug。

## 精简后的 Context Menu 归属

| 对象 | 复用（已存在） | 真正建议增加 | 不做 |
| --- | --- | --- | --- |
| Commit 行 / 节点 | 复制 SHA、复制标题；单击展开历史文件 | 在指定提交创建本地分支、创建 Tag；明确目标 Commit | 不做 Cherry-pick、Revert、Drop、Merge、Rebase、Reset 的全量 Git Graph 复刻 |
| 当前本地分支 Badge | Top Branch/Menu 已有当前状态、Push、Fetch、创建分支 | 独立 Badge 命中、复制分支名 | 不允许 Checkout 自己 / 删除当前分支 |
| 其他本地分支 Badge | 已有 `switchBranch(to:)` | 独立 Badge 命中、复制分支名 | 不新造分支管理页、远程分支删除 |
| `origin/main` 等已有跟踪引用 | 顶部 upstream 状态、Fetch/Pull/Sync | 在 Recent Commits 中作为胶囊显示、标注跟踪引用身份 | **只显示，不独立右击管理，也不新增 Remote Branch 菜单** |
| Tag Badge | 历史 `%D` 可能携带 Tag 字符串 | Tag 类型/独立右键；定位所指 Commit、复制名称 | 不做 Push/Delete Tag 或 Tag 列表页；Tag 不当作 Branch |
| 未跟踪/未暂存/已暂存/冲突文件、历史文件 | 现有 `GitEntryRow` / `RecentCommitsView` 上下文菜单 | 只验证正确命中，不重做操作 | 不重复实现文件读取/暂存/删除/恢复 |
| 仓库标题、CHANGES、More、Stash | 现有 Menu / Button / `PanelSectionHeader` | 原布局维持；没有明显缺失则不改 | 不加第二套仓库/分组菜单 |

> `design.html` **仅演示 Recent Commits**，其中 Commit/分支/Tag/历史文件与多色分叉是合成数据；不包含 Changes、Staged/Conflict 等其他 Git Manager 区域。自绘菜单仅用于浏览器评审，正式 App 使用 SwiftUI `.contextMenu`。

## 新版设计稿：两行提交与分叉图谱

- 一条 Commit 分两行：**标题 + 紧随其后的 Ref Badge**；其下为**短 SHA、作者、右对齐相对时间**，上下提交之间用细分隔线。HTML 示例显示 8 位 SHA，而生产代码的 `%h` 长度受 Git 缩写规则影响；优先复用 `RecentCommit.shortHash`，完整 SHA 仍可复制，不为视觉长度新增 Git 查询。标题、作者与 Ref 可截断，但不能挤掉时间；作者和时间沿用现有 `author` / `relativeDate`。原型固定 `90` 只是示例计数，正式 App 使用现有实际计数。
- 蓝色主干为当前本地分支的第一父提交链；真实存在的侧分支在其生命周期内使用其他颜色、从主干分叉并平滑合并。**只保留分叉/合并视觉样例，不再制作独立的“线性历史”模式或切换按钮**；正式 App 仍需支持真实线性仓库的一车道显示。线条必须依据全部 parent OID；分页未加载的父提交不虚构连接，展开文件后图谱仍需连续。
- HTML `topo()` 仅对样例中的侧分支重复利用第二车道，**不能直接作为生产多车道算法**：若真实仓库同时存在多个分支，应由拓扑关系分配不冲突的车道，颜色不应因展开/分页改变。
- Ref 必须解析 `HEAD -> main` / `origin/main` / `tag: v...` 等类型；一个 Commit 可显示多个 Badge。跟踪引用只显示，不响应专属管理菜单。当前 HTML 在窄窗口用 `+N` 表示额外的 Ref，但该字符**尚不可操作**；正式 App 必须能访问其中的每个 Ref（可用原生子菜单或等价可访问入口），不能因截断丢失 Tag 操作。
- 单击标题展开 Commit 文件，单击短 SHA 复制完整值；右击 Commit 行显示 Commit 菜单，右击本地分支或 Tag 显示该对象菜单，不穿透到父行。历史文件继续使用共享树的键盘/hover/目录折叠语义，Ref 省略显示不能带来横向滚动或错误命中。
- 刷新调查需要区分：(a) 事件根本未触发，(b) 已触发但合并/丢弃，(c) Git/SSH 查询耗时，(d) 新状态未渲染。以外部 CLI 修改 `.github/features` 下文件和提交后的状态为可重复样本；在临时仓库运行，避免污染真实项目。
- 本次唯一新增的 Git 写操作是以被选中 Commit SHA 在本地创建分支或 Tag；使用现有操作链处理输入、忙碌状态、错误和仓库身份，不在 View 自行执行 Shell。**不包括 Tag Push/Delete，也不触发 Tag Release**。

## 本轮交付边界

- 当前 `design.html` 是用户已更新并提交的 **V4 Recent Commits 参考原型**。过去 HTML 的浏览器测试不等于这次同步计划或正式 SwiftUI 的实机验收；使用它时需独立核验所修改的版本。
- 上述初版调研记录实施前的缺口。P1～P3 现已实施且完成独立逐提交审计，现行契约见 [Git 维护文档](../../../docs/features/git.md)，验收证据按阶段保留在 `audit-p1.md`～`audit-p3.md`。正式 App 已按后续明确授权替换；未使用用户真实仓库执行测试写操作。

## 2026-10-14：P4 完整对象菜单的新增一手依据

**范围变化：** 上面的「不做 Cherry-pick/Revert/Drop/Reset/Merge/Rebase、远端分支和 Tag 管理」是**原 P2 的历史收缩决定**，不是现在的需求。用户明确要求补回这些动作；当前实施方案以 [idea.md](idea.md) 和 [plan-p4.md](plan-p4.md) 为准，不能拿旧研究或旧审计把新增项划出范围。

### 上游菜单与原 Issue 证据

| 一手材料 | 实际核对结果 | 在 Kero 的使用方式 |
| --- | --- | --- |
| [Kero Issue #2](https://github.com/chiimagnus/kero/issues/2) 的 [Commit 菜单原图](https://github.com/user-attachments/assets/4321d2dd-7bb6-4499-aa9d-2bcf11663c25) | 原图逐项包含 Add Tag、Create Branch、Checkout、Cherry Pick、Revert、**Drop**、Merge into current、Rebase current onto、Reset current to this Commit、复制 SHA/Subject | 这些是本次 Commit 菜单最低覆盖，不得因旧 P2 省略而当作可选优化 |
| [Git Graph 官方 Context Menus](https://github.com/mhutchie/vscode-git-graph/wiki/Context-Menus) | 分别列出 Commit、已/未 checkout 的本地分支、Remote Branch、Tag、Stash、Uncommitted Changes、Commit Details File 等菜单；Drop 有“if topologically possible”条件 | 依对象拆分；对不可用 Git 状态明确禁用，不用一个大菜单或假执行动作 |
| [Git Graph 官方设置](https://github.com/mhutchie/vscode-git-graph/wiki/Extension-Settings) | Tag 有 annotated/lightweight；Reset 有 Soft/Mixed/Hard；Stash 可按具体条目操作 | 参考 Git **语义和影响范围**，不照抄插件的全部设置项 |
| [VSCodium 构建说明](https://github.com/VSCodium/vscodium/blob/master/README.md) | VSCodium 用 Microsoft `vscode` 源码构建，Git SCM 菜单参考其内置 Git 扩展而不是另找 VSCodium 私有实现 | 明确 upstream 的来源，勿将 Git Graph 第三方插件误认为 VSCodium 自带 Git |
| [VS Code Git 扩展 `package.json` 固定源码](https://github.com/microsoft/vscode/blob/76e9dff43b237f3fcbb8a289ed2f8bdf28105baf/extensions/git/package.json)（Git 扩展 10.0.0；2026-10-14 核对） | `scm/historyItem/context` 的 `git.graph.checkoutDetached` / `git.graph.cherryPick` / `git.graph.compareWithRemote` / `git.graph.compareWithMergeBase` / `git.graph.compareRef`；`scm/historyItemRef/context` 的 checkout/delete Branch/Tag；`scm/resourceState/context` 的 Stage/Unstage/Clean/Ignore/Open File，`scm/resourceGroup/context` 的批量 Stage/Discard；目录 `scm/resourceFolder/context` 也有单独命令 | Kero 同样按历史 Commit/Ref、工作区文件与分组/目录区分。菜单命令及条件取自实际声明，不按文字猜测 |

**不照搬的明确理由：** Archive/PR 需要 Kero 当前不存在的导出目标或 PR Provider；列可见性、Branches Dropdown 和链接菜单没有对应 UI 对象；只在编辑器行选区中成立的 Stage Selected Ranges 不属于当前 Git 文件树行。用户强调的 Cherry-pick、Revert、Drop、Reset、Merge/Rebase、Remote Branch、Tag 和 Stash 不是此类非目标。

### Kero 当前生产链与缺口（已逐层核对）

| 当前 owner / 锚点 | 当前能力或缺口 | P4 应改位置 |
| --- | --- | --- |
| `RecentCommitsView.commitRow` | 仅历史 Branch/Tag 创建、复制；左击整行展开，SHA 和 Ref 独立 | Commit 命令由此绑定，但交付给 `GitPanel` / Model 执行；不要让 View 发 Git |
| `RecentCommitsView.referenceActions` 与 `+N` | 当前本地 Branch 仅复制，其他本地 Branch 切换/复制，Tag 定位/复制，Remote Ref 为只读胶囊 | 通过同一个对象动作入口补本地/远端/Tag；验证 `+N` 与直接显示行为一致 |
| `GitPanel.branchMenu / moreMenu / GitEntryRow.menu` | 顶部 Fetch/Pull FF-only/Push/Sync、Stash All/默认 Pop；行级 Stage/Unstage/Discard，Merge/Index/Working 不同；分组按钮存在 | 继续复用现有入口，缺 Stash 单条、历史 ref 管理、工作区分组/文件缺口在所属菜单实现 |
| `GitStatusModel` | `perform` 校验 repoRoot、机器 scope、HEAD/upstream，并排他运行；`createReference` 可在选中 Commit 新建本地轻量 Tag/Branch；只有 `stashCount`，无逐条 Stash 身份/可右击条目 | 扩展现有 ViewModel 的真实 Git 语义，不建重复状态管理器；Ref、Stash 及确认前后目标需额外校验；确需单条右键时在现有 GitPanel 增加最小 STASHES 行，不把 More Menu 的左键子菜单当作右键验收 |
| `GitStatusModel.repositoryOperation` / `detectRepositoryOperation` | 已检测 MERGE、CHERRY_PICK、REVERT、rebase 标记，但展示为字符串，`GitPanel.repositoryOperationBanner` 只建议转终端 | 对实际可恢复 Git 状态增加按钮和相应 Model 命令；不会无条件产生 Recovery 状态 |
| `GitCommandExecution.run(_:in:backend:)` → `WorkspaceBackend.run` | argv 交给本机 `Process` 或 SSH backend；不直接复用用户终端 Shell | 保持当前后台执行、错误/超时、远端 argv 引用与机器身份；不得靠 View 使用 `Process` 或拼接未经校验的 shell |
| `TerminalManager.openCommitDiff` → `Project.openCommitDiff` | 已有历史 Diff 标签的真实生命周期和 Read-only 语义 | 在现有内容体系上扩展「查看修订」「与工作区比较」，不在 Git Panel 新建平行 Editor/缓存 |

### 真实风险、检查点与任务边界

- **历史改写不是 Revert：** Git Graph 的 Drop 指从当前分支历史删除提交并重放后续提交；仅在拓扑可证明安全时启用。Reset 的 Soft/Mixed/Hard 影响不同，Hard 会影响未保存到提交的改动；不能无确认、默认 Hard 或擅自 Force Push。
- **冲突必须有结果路径：** Cherry-pick、Revert、Merge 和 Rebase 可留下 `MERGE_HEAD`/`CHERRY_PICK_HEAD`/`REVERT_HEAD`/rebase 状态。现有只读 banner 不足以支撑完整菜单；需提供 Continue/Abort 与适用 Skip，失败保留真实 index/worktree。
- **Remote/Tag/Stash 不能只信显示名称：** `origin/main` 必须解析为指定 remote + branch，`stash@{n}` 会随着 stash 变更移动，Tag 可能是 annotated 对象；确认之后仍需验证实际 OID/ref。使用独立 bare remotes 和真实临时 Git fixture 核对被修改的对象，不在真实 Kero 或用户 Git remote 上实验。
- **双重验收：** `RecentCommitsViewTests` 等 NativeUI 宿主验证菜单命中与确认，`GitStatusModelTests` 等 Integration 验证 Git side effects；本机完整 App 与专用 Windows SSH 必须逐项实测。没有 SSH 实机测试，就只能报告本机已验，不能宣布 Issue #2 的 SSH 目标完成。
