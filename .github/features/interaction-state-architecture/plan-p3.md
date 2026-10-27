# P3：Git Changes、内置 History Graph 与 Git Graph 扩展对齐

**目标：** 不再把 Git Changes 的“当前显示 Diff”、资源选择和键盘 Focus 混合，
让 Stage/Unstage/Discard 的实际集合与菜单完全准确；
同时独立复现 Git Graph 的提交、引用标签、详情、比较、工作树与原生菜单的交互，
确保色轨/节点、异步身份和危险动作正确。

**上游必须同时阅读：**
- VS Code `scmViewPane.ts:SCMTreeDataSource/createTree/open/RepositoryPaneActionRunner/`
  `getSelectedResources/onListContextMenu/onDidActiveEditorChange`；
- `scmHistoryViewPane.ts:SCMHistoryTreeIdentityProvider/_createTree/`
  `_onDidOpen/_onContextMenu`，History Graph 自己设置
  `multipleSelectionSupport:false`，与 Changes 多选不同；
- `scmHistory.ts:renderSCMHistoryItemGraph` 的图谱 swimlane 与 refs；
- Git Graph 扩展 `web/main.ts:observeTableEvents/observeKeyboardEvents/loadCommitDetails`、
  `web/graph.ts:Graph.loadCommits/render`、`web/contextMenu.ts:show/close/refresh`、
  `web/styles/main.css` 的行状态；
  `src/gitGraphView.ts` 的事件→Git 操作/差异消息路由。
  **扩展许可证禁止分发衍生源代码：只吸收需求/行为，独立实现 native Swift。**

**Bailey 真源：** `GitStatusModel` 负责仓库/Worktree/SSH Git 数据、
`GitPanel` 维护 Changes 游标/明确选择/菜单，`RecentCommitsView` 维护
Graph 游标/详情展开/菜单；`CommitGraphLayout` 与
`GitGraphPalette` 维护图谱的真实拓扑和颜色，DiffTab/Project 负责已展示内容。
本阶段不创建统一 Files+Git SelectionStore，也不重新实现 Git backend。

**状态不变量：** 同一仓库相对路径在 `staged/unstaged/merge` 属不同 Git 对象；
`repoRoot/selectionScope` 及真实机器/连接必须参与身份。
提交 SHA + 工作树 Stash 不能当普通文件 Path，
提交展开不是显式资源选择，显示历史 Diff 不是 Git Graph 拥有第一响应者。
破坏性操作始终使用现有确认与复核。

---

## P3-T1 Git Changes 游标、明确选择、Diff 浏览和输入框隔离

**源码证据：**
- `scmViewPane.ts:createTree` 以 SCMInput/SCMActionButton/Repo/ResourceGroup/
  ResourceFolder/Resource 类型区分键盘和打开动作，
  `open` 只对可打开资源执行真实 Diff；
  输入框会取得原生焦点并清除树游标。
- `onDidActiveEditorChange` 的 autoReveal 是有条件的显式同步，
  不是任意 `displayed` 值变化就抢焦点。

**Bailey 锚点：**
`GitPanel.swift` 的 `ChangeSelection`、
`selectedChange`、`explicitlySelectedChange`、`contextChange`、
`focusGitChanges`、`focusContextChange`、
`browseGitChange`、`handleGitChangeKey`、
`navigableChanges`、`changedFileRows`、`directoryRow`、
`isDisplayedChange`；`GitEntryRow`、`GitStatusModel.Entry`；
`Project.openDiff` 与 DockGroup。

**步骤：**
1. 将 ChangeSelection 的 scoped identity（仓库/状态区/路径）与
   当前显示 Diff、临时菜单上下文的等价判断逐行对照源码；
   确认 staged/unstaged 同名条目不会因共享 `path` 错选。
2. Red（缺陷）：在一个真实临时 Git 仓库建立 modified/untracked/
   staged+unstaged/merge-conflict 和目录节点，
   分别操作列表/树视图；左键、↑↓、←→、Space/Return、Esc、
   文件按钮、右键、输入框、Palette 取消。
   Focus 移动不得浏览 Diff 或修改 index；
   目录展开不得假装选择同路径的文件。
3. 在 GitPanel 唯一所有者合并重复的“选择游标时顺便打开 Diff”判定，
   让 Browse/Expand/Context 与 keyboard focus 分开；
   `TreeKeyboardHost` 只承担原生输入，不能逆向决定仓库。
   删除实际重复的 `@State` 镜像或二次焦点路径，但不要删除 P3-T3 所需 Selection。
4. 验证 SSH 项目切换、仓库刷新、结果晚到、Git TextField/原生输入焦点、
   隐藏 Git 组重挂载和在另一可见组展示 Diff；失败时保留有效旧显示而不启用错误写操作。

**验证：** `make test:GitStatusModelTests,NativeDiffTabTests,DockWorkspaceTests`，
隔离 `GitChangesUITests`、`WorkspaceGitUITests`，
检查真实 Diff 路径/内容、index 不变、可见焦点/AX；
明暗/中文英文/树与列表模式、空仓库与 1/1000+ 变更，
`make build:dev`。同提交更新 `docs/features/git.md`、
确实改变公共视觉才更新 `docs/ui.md`；一个提交。

---

## P3-T2 Graph 提交/历史文件/展开与菜单上下文目标

**源码证据：**
- 内置 `scmHistoryViewPane.ts` 的 `SCMHistoryTreeIdentityProvider`
  区分提交/历史文件/目录/LoadMore 节点；
  其中 Graph Tree **禁用多选**，不能把 Changes 的选择集合复制到此处。
- 扩展 `web/main.ts:observeTableEvents` 按
  commit/ref/stash/uncommitted 分派点击、右键；
  `web/contextMenu.ts` 菜单临时目标拥有自己的生命周期。

**Bailey 锚点：**
`RecentCommitsView.swift` 的 `selectedRowID`、
`contextRowID`、`expandedCommitIDs`、`collapsedFolders`、
`toggle`、`toggleFolder`、`selectRow`、
`selectContextRow`、`dismissContextRow`、
`contextTarget(for:)`、`keyboardRows`、
`handleGraphKey`、`activate`、`isFocusedRow`；
`commitRow`、历史文件/Worktree/Stash 行与 GitPanel 的 `graphKeyboardOwner`。

**步骤：**
1. 先完整枚举 Graph 中所有可点目标：
   commit row 的 badge/title/node/metadata，refs、标签、Stash、Uncommitted、
   历史目录各段/文件、工作树状态、加载更多、空白、右侧按钮。
   一个目标一个语义：选择游标、展开详情、打开 Diff、菜单、Checkout/Reset 等不能串联。
2. Red：在含两条以上分支/merge/stash/未提交、至少一个历史文件、
   独立 worktree 的受控 Git 仓库中逐个点击/右键/键盘操作，
   检查菜单有效期间目标描边和 AX、
   Esc 关闭菜单不展开详情，不更换当前 Diff；
   选中的历史文件从另外组显示但 Git 仍为输入目标。
3. 保持 `RecentCommitsView` 的局部状态 owner，将重复的
   commit/ref/stash/worktree context forwarding 合并到现有最小方法，
   但**不**用一个 `selectedRowID` 冒充真正的 `expandedCommitIDs`。
   菜单目标以完整 commit/file/ref/worktree ID 绑定，过期即撤销。
4. 检查 GitPanel 在 Changes/Graph 间的 focus handoff，
   Graph 不可见时输入不会被旧 `TreeKeyboardOwner` 抢占；
   Graph 恢复时定位有效当前行/可见祖先而非自动展开所有节点。

**验证：** `make test:CommitGraphLayoutTests,GitStatusModelTests,NativeGitHistoryFileTests`、
`GitGraphUITests`、`GitHistoryUITests`、`GitChangesUITests`；
空/单/多提交、分支/remote/ref/stash、工作树、多窗/SSH、菜单连续打开与取消、
长中英文 commit subject/深目录、主题与无障碍，
真实 Diff 字节和 index/HEAD 不变；`make build:dev`。
`docs/features/git.md`、必要 `docs/ui.md` 同一提交。

---

## P3-T3 Git Changes 资源多选、范围锚点和批量动作

**这是上游源码明确揭示的独立缺口：**
`scmViewPane.ts:RepositoryPaneActionRunner/getSelectedResources` 使用
**多资源 Selection**；Bailey 的 `explicitlySelectedChange` 当前只能保存一个
`ChangeSelection`。把蓝底改漂亮并不能获得真正多选。
此项不能和 Files 选择共用同一可写 Set，因为 Git Section/Repo 和
ResourceGroup 是业务身份的一部分。

**Bailey 锚点：** `GitPanel.ChangeSelection`、
`navigableChanges`、`explicitlySelectedChange`、
`contextChange`、`directoryMenu`、`stageEntries`、
`unstageEntries`、`requestDiscard`、
`GitStatusModel.stageEntries/unstageEntries`、`GitStatusModel.Entry`、
`TreeRowSurface.isSelected`、`GitEntryRow`；
UI 的 stage/unstage/discard 按钮与独立冲突处理。

**步骤：**
1. 对照上游 Tree List 的多选/Anchor、SCM group-specific action runner，
   确定 Bailey 的最小 ChangeSelection 集合（按 repo+stageSection+path 唯一标识）；
   Git TextField、目录和历史 Graph 节点不进入可文件批量操作的同一集合。
   允许 list/tree 当前可见行上的 ⌘ 切换与 Shift 范围选择，保持一个键盘游标。
2. Red：在真实 Git 仓库建立 5+ staged/unstaged/conflict/untracked 条目，
   选 A/C→Shift E→缩到 D、跨分组/同名路径/目录；
   方向键只移动 Focus、右键选区内保留组选/选区外单选、
   菜单动作作用合法目标集合。AX 的 selected 条件不得把所有 displayed Diff 都标记已选。
3. 让唯一 GitPanel owner 管理本地集合/Anchor 与有效仓库 identity，
   将菜单/快捷键/行 hover 按该集合计算；
   **批量 Stage/Unstage** 只提交当前允许的部分并验证结果，
   **Discard** 的确认和取消不能丢失前一集合或错误操作其它 Section。
   若跨组批量动作没有业务定义，明确菜单禁用/分组，而非勉强对所有类型执行同一命令。
4. 删除旧单项 Selection 状态或迁移全部调用方，不留下单双选双轨；
   不复制 FileTreeModel 进 Git，也不引入 `SelectionManager`。
5. 检查已打开 Diff、仓库切换/SSH 断线、刷新/排序过滤/折叠时的选择锚和
   动作安全；失败后 index/HEAD/文件字节与剩余选择保持可解释。

**验证：** 新增针对独立真实 Git index 的宿主 `GitStatusModelTests`、
`GitUncommittedActionTests`、`GitExecutionTests` 和 GitPanel 最小挂载 AX；
隔离 `GitChangesUITests`，真实多选右键/快捷键/确认后核对
`git status --porcelain`、index staged bytes 和工作树内容；
冲突 index、tracked/untracked、改名、中文/空格/非法路径、空/大量文件、
同名跨仓库、远端 Windows SSH 断线、双窗与撤销，
`make build:dev`。Docs `docs/features/git.md`、`docs/ui.md`；
本 task 一个原子提交。

---

## P3-T4 Git Graph 提交详情、比较、标签与键盘导航

**三套不同语义必须先区分：**
- 内置 SCM History Tree：多选关闭，提交作为历史节点；
- Git Graph 扩展 `web/main.ts`：单击提交切换详情，按 ⌘ 比较两个提交，
  ↑↓ 表格移动、⌘↑↓ 顺父/子、⌘⇧↑↓ 替代父/子；
  ref 标签单击与双击、右键是不同事件；
- Bailey 当前 `expandedCommitIDs` 是**多展开集合**，
  既有用户明确要求单击任意 ref/commit 标签统一展开详情，
  并否决“单击复制/直接打开 Worktree”等危险或不统一交互。

**锚点：** `RecentCommitsView.toggle`、
`handleGraphKey`、`keyboardRows`、`referenceStrip`、
`stashBadge`、`commitRow`、`BranchAction/RemoteAction/TagAction`、
`expandedCommitIDs`、`CommitGraphLayout`；
`GitStatusModel.RecentCommit`、`GitPanel` 的 Detail/Compare/Diff 操作入口、
`Project.openDiff` 和 Git 原生确认 Sheet。

**步骤：**
1. 在**同一张对照表**实际验证扩展/内置/当前 Bailey：
   首次单击/第二次单击提交、点击 ref badge/node/title/metadata、
   ⌘ 点第二个提交、方向键/⌘+方向键、连续展开多个详情、
   右键引用、Stash 和 Worktree；
   标出 VS Code 本身存在的两种 Graph 行为，不假设它们完全相同。
2. 对“单详情 vs 多展开”、“Git Graph compare two commits”、
   “badge double-click checkout vs 用户明确禁用”分别记录采用哪套语义与理由；
   **危险 Checkout/Reset/Rebase 不得未经明确菜单+确认绑定成双击副作用**。
   提交比较属于用户明确要求的 VS Code 交互吸收，应有清晰可见的两端身份，
   不能用 Files/Git Changes multi-select 模型硬凑。
3. Red：两个提交比较与普通详情展开互不覆盖；
   跨仓库同 SHA、merge 多父、已不存在 ref、分页时第二目标变动，
   快速按键时不打开错误历史；
   菜单/详情中输入框应保留自身焦点。
4. 独立 Swift 状态只保留实际需要的 Compare pair/expanded state，
   在 `RecentCommitsView` 或原有 Git 模型 owner 形成明确事件动作，
   避免“点击提交时先写选中，再由 onChange 推断打开比较”；
   删除被新显式动作替代的旧分支。
5. 若上游部分功能（如比较 UI、分支导航）需要新增布局，
   先依赖现有 Detail/Diff 容器及真实 Git 数据，
   不复制扩展 Webview，保证任意 NSWindow/SSH 安全。

**验证：** `GitStatusModelTests`、`NativeGitHistoryFileTests`、
`CommitGraphLayoutTests`、`GitGraphUITests`、`GitHistoryUITests`；
两提交与多父/单父/初始提交/快速连续点击/分页/新删除 ref、
本机和 SSH 项目、两窗口；
真 Diff 内容和比较范围/HEAD/index 不变，带未保存编辑时操作受保护；
`make build:dev`。Docs `docs/features/git.md` 和确有更改的 `docs/ui.md`；
一个提交。

---

## P3-T5 Git Graph DAG 轨道、ref 徽章与行状态视觉

**源码：**
- VS Code 内置 `scmHistory.ts:renderSCMHistoryItemGraph`
  明确 swimlanes 与 commit references 不等于 Selection；
- Git Graph 扩展 `web/graph.ts:Graph.loadCommits/Branch.draw/render`
  处理多父边、颜色轨道、不同 commit 详情高度；
  `web/styles/main.css` 将 commit:hover/contextMenuActive 与
  `.commitDetailsOpen` 的持续灰底区分。
  **不可复制扩展算法/CSS，只有对照样本与目标视觉语义**。

**Bailey 锚点：** `Bailey/Git/CommitGraphLayout.swift` 的
`rows/rails/line lanes`，`RecentCommitsView.swift` 的
`commitRow/referenceStrip/stashBadge/commitFiles`、
`GitGraphPalette`，`TreeRowSurface` 的
`displayed/focusRing/contextRing`；
`GitStatusModel.RecentCommit` 的 refs/parents/worktree；
Git Graph 现有分页加载和水平滚动。

**实现门禁与步骤：**
1. 在 VSCodium/VS Code 内置 Graph、Git Graph 扩展和 Bailey Dev
   取得同一个受控提交 DAG 与明暗主题对照：
   普通 commit、merge 双父、octopus、交叉 merge、rebase/cherry-pick、
   detached HEAD、标签/远端/多 refs、stash、Uncommitted Changes、
   linked worktree、隐藏/缺失父提交与分页连接。
2. 比较每行 `expanded`、`hover`、`context`、`focused`、
   `displayed file` 的独立视觉；
   **上游 Git Graph 扩展在详情展开时有灰底，
   Bailey 当前 docs 声称“展开不产生持久灰底”**。
   先按前述用户决定与可视基线明确是否调整，
   不用把“全部都只有蓝色描边”误作 VS Code 同义。
3. Red：真实 Git 拓扑测试逐个确认 parents 和 rails，
   refs 同色跟随真实分支，合并后保持分支颜色；
   横向滚动不挪动固定按钮、长标题/中文/emoji 不溢出，
   1000+ commit 分页不丢颜色/详情/右键对象。
4. Green：仅在 `CommitGraphLayout/GitGraphPalette` 与
   Graph 行自身的视觉 modifier 内解决几何/颜色/背景不变量，
   不动 Files/Git Changes 的共享状态语义；
   不增加重绘期间的额外 Git polling；
   清理旧条件色/重复图谱辅助实现。
5. 实测密集 12+ 轨/宽度不足/字体最大最小/高对比及主题切换，
   确保真实节点、引用标签、Stash、Worktree/Uncommitted 不丢，
   图谱鼠标命中与实际 commit hash 一致。

**验证：** `make test:CommitGraphLayoutTests,GitGraphPaletteTests,GitStatusModelTests`；
`GitGraphUITests`、`GitGraphGeometryUITests` 实际 DAG 视觉与 AX，
暗/亮/自定义 Ghostty、窄/宽、多屏像素比例、
所有父子拓扑及横滚，`make build:dev`；
完整 commit 图不会因 View 重绘重建编辑器/终端。
Docs `docs/features/git.md`、`docs/ui.md`；一个提交。

---

## P3-T6 Git Graph 引用/Stash/Worktree/危险操作与目标失效

**上游：** Git Graph 扩展 `web/main.ts` 以 Ref/Commit/Stash/
Uncommitted 类别选择菜单动作，`web/contextMenu.ts:refresh/close`
在刷新后以完整 hash+ref 寻找真实目标，否则关闭菜单；
内置 `scmHistoryViewPane.ts:_onContextMenu` 按 provider/refs 区分可用动作。

**Bailey 锚点：**
`RecentCommitsView.BranchAction/RemoteAction/TagAction/HistoricalFileAction/WorktreeAction`、
`branchAction/remoteAction/tagAction/stashAction/worktreeAction`、
`contextRowID/contextTarget(for:)`；
`GitStatusModel` 的 `canActOnCommit`、当前 ref/stash/worktree 有效性、
本机/SSH 仓库执行和 `GitBranchDialog`、`GitTagDialog`、
`GitStashDialog`、`GitUncommittedDialog` 等原生确认。

**步骤：**
1. 按 Branch、Remote、Tag、Stash、Commit、Uncommitted Changes、
   Worktree、历史文件分别列出菜单项、只读条件、需要确认/选父提交的条件、
   提交后 index/HEAD/ref/工作树实际副作用；
   Git Graph 扩展的所有可观察命令与 Bailey 当前菜单逐项对应，
   不通过增加无价值菜单或复制扩展内容凑“完整性”。
2. Red：双窗 A 仓库菜单打开，B 窗切前台、
   A 仓库 checkout/reset、SSH 断线、ref 被外部删除/重命名、
   菜单跟踪中 Git 自动刷新/分页；
   旧菜单不得在不同仓库执行，也不得向本机同名 path 回退。
3. Green：仅在原有 `GitStatusModel` 的
   当前有效仓库/HEAD/ref/连接校验入口处完善，
   菜单/contextRow 不足时用当前模型 identity 解析一次，
   不增加第二套危险操作后端和全局 MenuManager。
   用户确认前后复核目标并保留未保存编辑和待操作输入。
4. 恢复 Git Graph 原生 NSMenu 关闭/取消的临时视觉；
   实际操作成功后更新真实状态，不因一次失败清空仍可信的 Git 图谱；
   删除替代路径或过期兼容的冗余菜单转发。

**验证：** `GitExecutionTests`、`GitStatusModelTests`、
`GitStashActionTests`、`GitRemoteBranchActionTests`、
`GitUncommittedActionTests`、`GitNativeDialogTests`、
`GitDialogUITests`、`GitGraphUITests`；
真实 Git index/HEAD/refs/工作树/双窗/切仓库、
Detached、linked worktree、stash、取消/确认、权限失败、SSH 断连；
`make build:dev`。Docs `docs/features/git.md`、
具体 SSH 身份契约变化时 `docs/features/ssh.md`；一个提交。

---

## P3-T7 Graph/Changes 列表身份、刷新分页及跨组显示恢复

**源码：** VS Code List/Tree `TraitSpliceable`、
`scmHistoryViewPane.ts:SCMHistoryTreeIdentityProvider`、
Git Graph 扩展 `ContextMenu.refresh` 在重绘时按完整 hash/ref 寻找目标，
History Graph 分页/LoadMore 不能改变已展示的 Diff 身份。

**Bailey 锚点：**
`GitStatusModel.repositoryIdentity/currentScope`、`graphCommits`、
`RecentCommitsView.commits/selectionScope`、`requestedLastCommit`、
`selectedRowID/contextRowID`、`expandedCommitIDs`、
`GitPanel.onChange`、`Project.openDiff`、
`DockWorkspaceModel` 的 active group/selected。

**任务：**
1. 核对独立实例 A/B 仓库在相同 SHA、同名路径和交错 SSH 连接中的列表身份；
   记录刷新/分页/重命名 ref 后哪些状态必须保留，哪些临时目标必须失效。
2. Red：多页提交中已展开较旧 commit、鼠标右键正在跟踪时新增提交/切换分支；
   Graph 数据晚到不能把旧 commit/ref 绑定到新 index；
   同名 Changes/History 行菜单不得串线，编辑器已显示旧历史 Diff 可以继续只读。
3. 在当前所有者按 ID 重绑有效选中和可见展开，
   失效的临时菜单/拖放必须立刻清理；禁止把 array index 当稳定 commit identity；
   不借刷新事件修改实际 NSWindow.firstResponder。
4. 去掉重复因相同 Git 数据反复提交 selected/context 引起的无效重绘；
   不改 Git 的轮询/FSEvents 所属任务设计。

**验证：** `GitStatusModelTests`、`CommitGraphLayoutTests`、
`NativeGitHistoryFileTests`、
`GitChangesUITests`、`GitGraphUITests`、
`GitHistoryUITests`；1k+ 提交分页、跨 SHA/Repo/SSH、
快速切项目/刷新失效/双窗/大量 refs、取消真实菜单、
正确 Diff 内容、没有跨机器写入；`make build:dev`。
Docs `docs/features/git.md`，只改本任务直接影响路径；一个提交。

---

## P3 阶段验收与审计

1. Git Changes 资源 **多选与批量 Stage/Unstage/Discard**、
   Git Graph 提交展开／比较／引用菜单／历史 Diff、DAG 轨道颜色、
   Stash/Worktree/Uncommitted、仓库身份各自拥有独立宿主与真实 UI 证据。
2. 运行受影响的 Git 宿主全集和
   `GitChangesUITests`、`GitGraphUITests`、`GitGraphGeometryUITests`、
   `GitHistoryUITests`、`GitDialogUITests` 的隔离 Dev E2E，
   不能仅通过 UI 显示替代 Git index/HEAD/ref/文件字节的实际断言。
   阶段 `make build:dev` 与签名验证。
3. 用 `vscode-source-audit.md` 的 SCM/History/Git Graph 行为矩阵逐项勾销；
   保留“两个上游 Graph 不同”和“扩展代码禁止直接复用”的证据，
   不把 Graph 的禁用多选误改为 Changes 的多选。
4. 每 task 实现与测试/文档同 commit、旧实现同 task 删除、
   `todo.toml` 写 SHA；`phase-complete --phase p3` 后立即运行
   `plan-task-auditor` 的独立 `audit-p3.md` Gate；
   未核销的真实 Windows SSH、极端多父、Mac 15.6 或外部权限需逐项列原因和影响。
