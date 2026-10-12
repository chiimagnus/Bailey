# Git Manager 调研：只补 Kero 真正缺少的部分

对应 [Issue #2](https://github.com/chiimagnus/kero/issues/2) · [Recent Commits 设计稿](design.html)。研究依据为 **当前 Kero 源码**、Issue 中的 Git Graph 截图（两行提交、主干/多色分叉、Ref/短 SHA/作者/时间）与 Git Graph 官方材料，不把 Git Graph 的全量菜单当作 Kero 需求。

## 一手参考

- [Git Graph 仓库 README](https://github.com/mhutchie/vscode-git-graph)：区分 Commit、Branch、Tag、Stash、未提交变更与历史文件的菜单归属，以及图谱、Refs、详情界面。
- [Git Graph Context Menus](https://github.com/mhutchie/vscode-git-graph/wiki/Context-Menus)：参考原生语义和动作分类，**不直接迁移全部菜单项**。Issue 中也附有其 Commit 菜单截图。
- [Apple SwiftUI contextMenu](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:))：正式 UI 使用 SwiftUI `.contextMenu`；右击对象本身决定 Menu 归属，不在 App 中引入自绘 HTML 菜单。
- Kero 本地 [Git 维护约束](../../../docs/GIT.md)、[安全](../../../docs/SECURITY.md)、[文件与共享树](../../../docs/EDITOR.md)和仓库 [AGENTS.md](../../../AGENTS.md)，以及用户提供的当前界面截图。

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

- 仓库正在进行独立的 [MVVM / Observation 重构](../swiftui-observation-mvvm-refactor/plan-p3.md)：该计划明确让 **`GitStatusModel` 保留名称，但承担窗口级 `@Observable` Git ViewModel 职责**，继续复用 `GitCommandExecution` 与 `WorkspaceBackend`，不引入新 Git Service。实施本 Feature 时应先核对该重构实际完成状态，沿唯一的当前 Git 状态 owner 接入，不把新操作写回已淘汰的 `ObservableObject` 路径，也不重复迁移。

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
- **尚未**实现新版 SwiftUI Recent Commits、Ref 创建或刷新修复。后续按 `plan-p1.md`—`plan-p3.md` 实施，在本机隔离 Debug / 受控本机或 SSH fixture 验收；不能复用正在运行的正式 App 进行写操作。
