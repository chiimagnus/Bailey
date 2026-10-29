# P3：Git Changes、内置 History Graph 与 Git Graph 扩展对齐

**阅读时点：** 下文“当前”与旧字段指 P3 实施前的源码基线，不代表完成后的实现。
实际提交见 `todo.toml`，现行交互契约见 `docs/features/git.md`。

**目标：** 保留 Git Changes 已分开的“当前显示 Diff”、单项明确选择和键盘游标，
核对它们的事件规则与视觉组合，补齐资源多选，让 Stage/Unstage/Discard 的实际集合与菜单完全准确；
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
  `src/gitGraphView.ts` 的事件→Git 操作/差异消息路由，
  `src/dataSource.ts:getCommitComparison/execDiff` 的两端数据；
  VS Code `extensions/git/src/commands.ts:stage/unstage/clean` 的合法资源过滤。
  **扩展许可证禁止分发衍生源代码：只吸收需求/行为，独立实现 native Swift。**

**Bailey 真源：** `GitStatusModel` 负责仓库/Worktree/SSH Git 数据、Git 目录折叠
及可跨 Git 面板重挂载保留的 Changes 游标/选择；`GitPanel` 仅解释 Changes 的输入与临时菜单，
Graph 展开集合由同一窗口的 `GitStatusModel` 保留，
`RecentCommitsView` 通过 Binding 改变提交展开，只持有 Graph 游标/临时右键等局部状态；
`CommitGraphLayout` 与 `GitGraphPalette` 负责图谱拓扑和颜色，
`Project`/`DockWorkspaceModel` 与 `DiffTab` 负责标签展示、活动组及真实 Diff。
本阶段不创建统一 Files+Git SelectionStore，也不重新实现 Git backend。
“不重写 backend”不等于禁止为新增比较补充真实 Git 查询。
独立复核与任务删除清单见 [source-review.md](source-review.md)。

**状态不变量：** 同一仓库相对路径在 `staged/unstaged/merge` 属不同 Git 对象；
`repoRoot/selectionScope` 及真实机器/连接必须参与身份。
提交 SHA + 工作树 Stash 不能当普通文件 Path，
提交展开不是显式资源选择，显示历史 Diff 不是 Git Graph 拥有第一响应者。
`Project.selectedTabID` 表示最近选择的工作标签，不能替代各 Dock 组正在展示的内容，
更不能替代 `focusedContent` 所代表的活动组内容；Git 在后台组预览 Diff 时仍可持有键盘焦点。
破坏性操作始终使用现有确认与复核。

---

<a id="p3-t1"></a>

## P3-T1 Git Changes 游标、明确选择、Diff 浏览和输入框隔离

**源码证据：**
- `scmViewPane.ts:createTree` 以 SCMInput/SCMActionButton/Repo/ResourceGroup/
  ResourceFolder/Resource 类型区分键盘和打开动作，
  `open` 只对可打开资源执行真实 Diff；
  输入框有自己的输入焦点；这不等于必须销毁保留的树游标，失焦描边应消失。
- `scm.contribution.ts` 的 `scm.autoReveal` 默认 true；
  `scmViewPane.ts:onDidActiveEditorChange` 订阅活动编辑器变化，
  查找可见仓库中匹配路径的 SCM resource，找到后 `expandTo/reveal/setSelection/setFocus`；
  没有匹配资源时不硬造 Selection，也不夺走原生 firstResponder。
  不能把 Auto Reveal 当成可保留的 Bailey 差异，或误解为任意 `displayed` 重绘抢键盘。

**Bailey 锚点：**
`GitPanel.swift` 的 `ChangeSelection`、
`selectedChange`、`explicitlySelectedChange`、`contextChange`、
`focusGitChanges`、`focusContextChange`、
`browseGitChange`、`handleGitChangeKey`、
`navigableChanges`、`changedFileRows`、`directoryRow`、
`isDisplayedChange`；`GitEntryRow`、`GitStatusModel.Entry`；
`Project.openDiff`、`Project.selectTab` 与 DockGroup。
当前旧 `explicitlySelectedChange=A` 与新 `displayedDiff=B` 会分别给 Changes 两条灰底，
必须在此任务修正，而非等 P5 只调颜色。

**既有能力边界：** `selectedChange` 当前是游标，`explicitlySelectedChange` 才是单项明确选择；
`displayedDiff` 当前读 `Project.selectedTab`，但这只表示最近工作标签，
不必然是当前活动编辑器或另一组实际展示的 Diff。
`Project.selectTab(activating:false)` 可在 Git 仍活动时更新别组预览；
`WorkspaceWindowModel.bind` 的 `dock.onActiveItemChange` 目前只驱动 Files 的 Auto Reveal。
不能仅订阅 `selectedTabID` 并把所有变化冒充活动编辑器事件，
也不为术语整齐增加别名／镜像或纯改名任务。
真正集合升级及旧单项字段删除在 P3-T3 同时完成。

**步骤：**
1. 将 ChangeSelection 的 scoped identity（仓库/状态区/路径）与
   当前显示 Diff、临时菜单上下文的等价判断逐行对照源码；
   确认 staged/unstaged 同名条目不会因共享 `path` 错选。
2. 对新增行为／已证实缺陷建立 Red，其余保留回归：在一个真实临时 Git 仓库建立 modified/untracked/
   staged+unstaged/merge-conflict 和目录节点，
   分别操作列表/树视图；左键、↑↓、←→、Space/Return、Esc、
   文件按钮、右键、输入框、Palette 取消。
   Focus 移动不得浏览 Diff 或修改 index；
   目录展开不得假装选择同路径的文件。
   另测从 Dock 切换 Diff A→B 或回到普通修改文件 B、
   同路径 staged/unstaged、没有 Git 更改的文件、其它仓库/SSH 同名文件、
   SCM 隐藏/再次显示、快速切换与旧 Git 刷新晚到：
   匹配资源时替换旧 A 选区并定位 B，未匹配时保留合法旧选择而不伪造 B。
3. 从 `DockWorkspaceModel` 的真实可见组选择及活动内容变更接通 Auto Reveal；
   显式 Git 预览仍由 `browseGitChange` 自身更新选择，
   不把最近工作标签的 `selectedTabID` 变化误当成焦点转移。
   只在当前项目/机器/仓库、当前连接核验有效、且资源在当前 Git Changes
   可见范围内匹配时更新 `selectedChange` 和明确 Selection；
   同名 staged/unstaged 以 Diff 来源与 Section 分辨，
   过滤、折叠或未匹配导致行不可见时保留合法旧选区，
   不静默改过滤条件、不展开无关区域，也不抢原生第一响应者。
   删除 Changes 的独立 `displayed` 常驻灰底入口，
   仍保留 Focus/Selection/Context 及其他 Git History 的独立语义。
   Browse/Expand/Context 与原生 keyboard focus 继续分开，
   `TreeKeyboardHost` 只承担输入，不能逆向决定仓库。
   删除实际重复的 `@State` 镜像或二次焦点路径，但不要删除 P3-T3 所需 Selection。
   复用 `WorkspaceWindowModel` 已有的 Dock 事件交接和 `GitPanel` 局部状态，
   不新增全局 FocusManager/SelectionStore、SwiftUI 重绘驱动的重复监听或双轨显示状态；
   如改变 Dock 事件契约，本 task 同步更新 `docs/features/dock.md`。
   当 P3-T3 升级多选后，Auto Reveal 的 Selection 替换行为也须经其回归确认。
4. 验证 SSH 项目切换、仓库刷新、结果晚到、Git TextField/原生输入焦点、
   隐藏 Git 组重挂载和在另一可见组展示 Diff；失败时保留有效旧显示而不启用错误写操作。

**验证：** `make test:GitStatusModelTests,NativeDiffTabTests,DockWorkspaceTests`，
隔离 `GitChangesUITests`、`WorkspaceGitUITests`，
检查真实 Diff 路径/内容、index 不变、可见焦点/AX；
断言 A→B 后 B 唯一选中灰底，旧 A 不被 Displayed 叠画，
普通文件与 Staged/Unstaged Diff 切换的正确资源、无匹配/跨仓库时不误选，
异步更新不覆盖最后一次选择且不劫持输入；
明暗/中文英文/树与列表模式、空仓库与 1/1000+ 变更，
`make build:dev`。同提交更新 `docs/features/git.md`、
确实改变公共视觉才更新 `docs/ui.md`；一个提交。

---

<a id="p3-t2"></a>

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
`contextRowID`、`expandedCommitIDs`/`collapsedFolders` Binding（两者所有者均为
窗口级 `GitStatusModel`，不是短生命周期的 `RecentCommitsView`）、
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
3. 保留 `RecentCommitsView` 对 Graph 游标与临时菜单的所有权，
   `GitStatusModel` 唯一持有展开集合及目录折叠，确保 Git Panel 隐藏/重挂载时
   保留同一项目的有效展开；项目、仓库或机器切换时在模型同步入口清理。
   不在 `GitPanel` 重新保留一份 `@State` 镜像。
   逐一核对 `commitRow` 的整体 `onTapGesture`、title/ref/node 的嵌套 `Button`
   是否只触发一次对应动作；有实际重复触发才收敛事件入口，
   不为“统一”增加通用 ContextRouter。
   `selectedRowID` 是游标，不是提交展开集合；右键可移动游标但不应自动展开或浏览。
   菜单目标须区分 commit/ref/stash/worktree/历史文件的完整身份，失效即撤销。
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

<a id="p3-t3"></a>

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
   Git TextField、标题按钮和历史 Graph 节点不进入资源集合；
   **目录节点可参与选择**，执行时展开为当前过滤/分组下的后代资源并去重，
   不是把目录 path 直接传给 Git 递归处理。与上游 `ResourceTree.collect` 一致，
   也守住 Bailey 只操作当前匹配文件的契约。
   允许 list/tree 当前可见行上的 ⌘ 切换与 Shift 范围选择，保持一个键盘游标。
   **点击入口先核实：** 共享 `TreeFileRow`/`TreeFolderRow` 当前通过普通
   `.onTapGesture` 打开/展开，不能直接读取到可靠的修饰键点击意图；
   Files 使用 `FileTreeNativeDragSurface` 接收真实 `NSEvent`，但 Git 不应为多选
   复制整套拖动/剪贴板实现。先以原生 Dev 实验验证修饰键事件顺序，
   再接入最小 Git 行点击入口，保留共享外观、紧凑目录段及行尾按钮命中。
   明确普通点击浏览、⌘/Shift 只改 Selection 不打开 Diff、不展开目录。
2. Red：在真实 Git 仓库建立 5+ staged/unstaged/conflict/untracked 条目，
   选 A/C→Shift E→缩到 D、跨分组/同名路径/目录；
   方向键只移动 Focus；鼠标 Shift 与键盘 Shift 按 P1-T1 的两个算法分别验证。
   **SCM 右键不同于 Explorer：** 上游 `onListContextMenu` 不改 Selection，
   ActionRunner 在命中 Selection 内时操作集合，在外时仅操作 context；取消后旧集合仍在。
   不再要求右键集合外强行单选。
   菜单动作作用合法目标集合。AX 的 selected 条件不得把所有 displayed Diff 都标记已选。
   选区锚点只按当前可见的 Changes 行顺序计算，折叠/过滤/刷新后剔除失效成员与锚点；
   ⌘A 选择可见行，Escape 清空选择但保留游标；Shift 鼠标按连续区间、键盘按逐步增减。
   任何修饰键都不得意外触发原行的浏览或目录展开。
3. 让 `GitStatusModel` 唯一持有可跨 Git 面板隐藏/重挂载的 Changes 集合、Anchor 与游标；
   `GitPanel` 仅管理菜单临时目标及键盘输入，不另存镜像。
   这是 T1 在真实 Dev 中复现的状态丢失根因，
   不能将多选新集合重新放回会被卸载的 `@State`。
   将菜单/快捷键/行 hover 按该集合计算；
   **批量 Stage/Unstage** 先按动作解析合法资源：Stage 接受 CHANGES，
   Unstage 只接受 STAGED，Discard 只接受现有允许的非冲突 CHANGES；
   MERGE 只通过原有明确的 Mark Resolved 入口标记已解决，
   选区混入冲突项不能暗中将其 Stage。
   点击组内已选资源的按钮/菜单时使用同一合法集合，未选资源只操作自己。
   现有 Section 标题的 Stage All/Unstage All/Discard All 仍代表整组，
   行多选不得暗中改变这些按钮的范围。
   没有合法项时禁用该动作，不自动扩大到整仓库。
   对本次动作合法的 Section，将父目录展开为可见后代并去重实际 pathspec，
   Rename 的旧路径沿 `stageEntries/unstageEntries` 现有逻辑处理；
   同名的 staged/unstaged 仍是不同资源身份。
   每次触发菜单或按钮时，从当前模型重新解析 `GitStatusModel.Entry` 并核对
   所属 Section 是否仍含该条目：当前 `validate(entry)` 只核对仓库/代次/HEAD，
   不核对旧 Entry 是否仍在最新变更快照中。
   保留 `perform` 的真实仓库/HEAD/连接复核，
   若操作可能影响选中后外部更新的内容，仅在现有 runner 补必要的状态复核，
   不建立新的 Git 后端或 per-file generation。
   **Discard** 的确认和取消不能丢失前一集合或错误操作其它 Section。
   跨组按上述规则过滤合法子集，而非对所有类型执行同一命令。
4. 复用现有 `stageEntries/unstageEntries` 一次批量 Git 调用，
   不循环调用 `stage/unstage`（第一项后 isBusy 会阻止其余项）。
   以本次操作 ID 对应的 `GitStatusModel.operation` 完成结果及随后
   刷新的 Section 解析 Selection：
   已迁入另一 Section 或消失的目标按身份剔除，仍有效的目标保留；
   不以同步 `Void` 返回或开始 loading 代表全部成功，也不增加 operation 镜像。
   Discard 直接复用 `GitPanel.requestDiscard([Entry], trigger:)`、
   `GitStatusModel.prepareLocalDiscard/prepareRemoteDiscard` 与
   `confirmLocalDiscard/confirmRemoteDiscard` 已支持的任意条目数组，
   不创建另一套多选 Discard 对话框或文件删除路径。
   现有本机 `prepareLocalDiscard` 会**过滤**失效条目，远端版本会整体拒绝；
   执行前先确保合法请求集与确认展示的审核结果一致，
   不把部分过滤当成用户已批准整组，确认时仍逐项复核指纹。
   文件失败/部分成功不能伪装事务回滚；确认取消不修改任何文件。
   保留 `Project.saveBeforeGitAction` 的编辑保护、本机 Trash 与远端永久删除差异；
   不因多选删掉 `PendingDiscard` 数据保护。
   删除旧单项 `explicitlySelectedChange` 并迁移全部调用方，不留下单双选双轨；
   不复制 FileTreeModel 进 Git，也不引入 `SelectionManager`。
5. 检查已打开 Diff、仓库切换/SSH 断线、刷新/排序过滤/折叠时的选择锚和
   动作安全；失败后 index/HEAD/文件字节与剩余选择保持可解释。

**验证：** 新增针对独立真实 Git index 的宿主 `GitStatusModelTests`、
`GitUncommittedActionTests`、`GitExecutionTests` 和 GitPanel 最小挂载 AX；
隔离 `GitChangesUITests`，真实多选右键/快捷键/确认后核对
`git status --porcelain`、index staged bytes 和工作树内容；
冲突 index、tracked/untracked、改名、中文/空格/非法路径、空/大量文件、
同名跨仓库、远端 Windows SSH 断线、双窗与撤销，
`make build:dev`。真实单击与修饰键点击须由 Dev E2E 验证，
宿主测试覆盖批量合法性、路径、索引副作用和过期条目；
Docs `docs/features/git.md`，共享选择视觉确有改变时再改 `docs/ui.md`；
本 task 一个原子提交。

---

<a id="p3-t4"></a>

## P3-T4 Git Graph 提交详情、比较、标签与键盘导航

**三套不同语义必须先区分：**
- 内置 SCM History Tree：多选关闭，提交作为历史节点；
- Git Graph 扩展 `web/main.ts`：单击提交切换详情，按 ⌘ 比较两个提交，
  ↑↓ 表格移动、⌘↑↓ 顺父/子、⌘⇧↑↓ 替代父/子；
  ref 标签单击与双击、右键是不同事件；
- Bailey 当前 `expandedCommitIDs` 是**多展开集合**，
  既有用户明确要求单击任意 ref/commit 标签统一展开详情，
  并否决“单击复制/直接打开 Worktree”等危险或不统一交互。

**本轮确定的取舍：** 保留 Bailey 多展开、普通↑↓只移动游标、ref 单击展开，
不引入扩展的单详情覆盖/普通方向键自动重开详情或 ref 双击 Checkout。
新增 ⌘点击普通提交作双端比较、⌘↑↓父子导航和 ⌘⇧↑↓替代路径；
比较不是多选集合，Worktree/Stash 也不假装普通 immutable commit。
同一 SHA 不同 Stash selector、多个 Worktree 的身份继续沿现有模型。

**锚点：** `RecentCommitsView.toggle`、
`handleGraphKey`、`keyboardRows`、`referenceStrip`、
`stashBadge`、`commitRow`、`BranchAction/RemoteAction/TagAction`、
`expandedCommitIDs`、`CommitGraphLayout`；
`GitStatusModel.RecentCommit`、`GitPanel` 的既有 Diff/菜单入口、
`Project.openHistoricalDiff`、`DiffTab.Source.commit`/`reload`、
`GitCommandExecution.runData`、`GitHistoricalFileLocator` 和原生确认 Sheet。
当前 `RecentCommitsView` 无比较入口，`GitStatusModel.expandedCommitIDs` 才是展开真源。

**步骤：**
1. 在**同一张对照表**实际验证扩展/内置/当前 Bailey：
   首次单击/第二次单击提交、点击 ref badge/node/title/metadata、
   ⌘ 点第二个提交、方向键/⌘+方向键、连续展开多个详情、
   右键引用、Stash 和 Worktree；
   标出 VS Code 本身存在的两种 Graph 行为，不假设它们完全相同。
2. 按上述已确定取舍实施，不把这些决定留给执行者任选；
   **危险 Checkout/Reset/Rebase 不得未经明确菜单+确认绑定成双击副作用**。
   提交比较属于用户明确要求的 VS Code 交互吸收，应有清晰可见的两端身份，
   不能用 Files/Git Changes multi-select 模型硬凑。
3. Red：两个提交比较与普通详情展开互不覆盖；
   跨仓库同 SHA、merge 多父、已不存在 ref、分页时第二目标变动，
   快速按键时不打开错误历史；
   菜单/详情中输入框应保留自身焦点。
4. 仅 `RecentCommitsView` 持临时 Compare pair、请求结果与取消生命周期，
   展开仍经 Binding 回写既有 `GitStatusModel.expandedCommitIDs`，
   `GitStatusModel` 只提供可测试的按目标读取双端变更的只读 async 函数，
   不另存一份可写 compare pair 或平行结果缓存；
   对过期请求按本次 pair/目标身份拒绝回写。
   点击提交直接执行明确动作，不由 `selectedRowID` 的 `onChange` 间接打开比较；
   删除实际被替代的旧点击分支，不为迁移制造 alias。
5. 若上游部分功能（如比较 UI、分支导航）需要新增布局，
   先依赖现有 Detail/Diff 容器及真实 Git 数据，
   不复制扩展 Webview，保证任意 NSWindow/SSH 安全。

**比较必须闭合到字节（本 task，不留给 P3-T7）：**
- 从最近一次**左键明确激活**的普通 commit 作为第一目标，
  ⌘点另一普通 commit 开/关比较；
  不把普通键盘游标、右键菜单游标或已展开集合当作比较锚点；
  pseudo `RecentCommit`（stash/worktree）不能参与比较；
  UI 明示两端完整提交身份、缩写 SHA 与比较方向；
  初始没有第一目标时按普通展开处理，同一提交不创建无意义比较。
  与扩展 `getCommitOrder` 一样以当前图谱顺序确定旧端→新端，捕获完整 SHA 后不随刷新反转。
  普通展开集合保留，比较显示在第一目标现有详情容器内，取消只撤销比较。
- `GitStatusModel` 增加按当前目标执行的只读双端查询，复用 `GitCommandExecution.runData`：
  `diff --name-status -z --find-renames --no-ext-diff <from> <to> --`，
  `<from>/<to>` 须为当前仓库真实可访问的完整 40/64 位 commit OID，
  只读命令的字节输出限制用 `limit+1` 检出截断（现有远端
  `GitCommandExecution.runData` 仅会截取 `stdoutLimit`，不会自行报告截断）；
  不拼两个 commit 各自的 files，也不误用 `<from>...<to>` 的 merge-base 比较。
  复用 `parseStashFileChanges` 已有 NUL/rename 解析能力，通用化命名时同任务迁移 Stash 调用，
  不保留旧名 alias。空结果与失败/截断/解码失败分别表达；输出沿现有容量与超时契约。
- 当前 `DiffTab.Source.commit(hash:parent:status:)` 已能读取任意两端 immutable blob，
  优先通过 `Project.openHistoricalDiff` 复用，不再造 Diff 引擎或可写历史编辑器。
  两端 SHA、rename old/new path、status 参与既有来源/标签复用语义；
  核对 `.commit(hash:parent:status:)` 对 `A` 跳过旧 blob、
  对 `D` 读取新 blob 的现有特判，确保“比较两端”并不错误沿用首父缺省或
  以无效对象冒充空文件。`Project.findDiffTab` 依 `repoRoot/path/source/workspace`
  复用，`origPath` 是可变元数据；同源重用必须证明 rename 目标仍一致。
  更新“首父”说明，使普通提交仍默认首父，比较显式传另一端。
  非文本/大文件、A/D/R/C/T、根提交、SHA-256、非祖先两端与仓库失效均验证最终两侧内容。
- 新比较请求只需本 owner 一个取消/取代标识，复用现有仓库/连接 identity，
  不在 View、Project、DiffTab 各追加一套 comparison generation。
  DiffTab 独立存在的加载代次仍是其原生内容保护，不是比较可替代的状态。
- 父导航使用 `parentHashes`；子导航用当前已加载 DAG 的反向关系，优先同 lane，
  但 `CommitGraphLayout` 的轨道包含 stash/worktree 伪节点，
  导航图只能由真实普通 commit 建立；
  替代路径选择第二父/不同 lane 子项，边界无节点不动、不凭空创建父提交。
  ⌘导航明确激活/展开目标；普通方向键仍仅移动游标，菜单/输入框不被截获。
  `RecentCommitsView.handleGraphKey` 当前拒绝所有 ⌘/Shift 按键，
  新导航必须在现有 `TreeKeyboardHost` 第一响应者中验证真实系统快捷键竞争，
  不能靠额外全局 NSEvent monitor 或让后台图谱截取编辑器快捷键。

**验证：** `GitStatusModelTests`、`NativeGitHistoryFileTests`、
`CommitGraphLayoutTests`、`GitGraphUITests`、`GitHistoryUITests`；
两提交与多父/单父/初始提交/快速连续点击/分页/新删除 ref、
本机和 SSH 项目、两窗口；
真 Diff 内容和比较范围/HEAD/index 不变，带未保存编辑时操作受保护；
`make build:dev`。Docs `docs/features/git.md`、`docs/features/diff.md`、
只有持久化来源格式或恢复行为实际改变才更新 `docs/features/session-restore.md`，
确有变化才更新 `docs/ui.md`；
一个提交。

---

<a id="p3-t5"></a>

## P3-T5 Git Graph DAG 轨道、ref 徽章与行状态视觉

**源码：**
- VS Code 内置 `scmHistory.ts:renderSCMHistoryItemGraph`
  明确 swimlanes 与 commit references 不等于 Selection；
- Git Graph 扩展 `web/graph.ts:Graph.loadCommits/Branch.draw/render`
  处理多父边、颜色轨道、不同 commit 详情高度；
  `web/styles/main.css` 将 commit:hover/contextMenuActive 与
  `.commitDetailsOpen` 的持续灰底区分。
  **不可复制扩展算法/CSS，只有对照样本与目标视觉语义**。

**现有覆盖门槛：** `CommitGraphLayoutTests` 已包含 5000 提交／150 轨、
交叉 merge、分页与轨道几何；`GitGraphUITests`、`GitGraphGeometryUITests`
已有密集 12+ 轨、深路径、中文长标题及明暗主题场景。
先运行这些现有断言并检查真实视觉证据，不因计划写有「1000+」
就重复制造另一套 DAG 算法、缓存或等价测试。

**Bailey 锚点：** `Bailey/Git/CommitGraphLayout.swift` 的
`rows/rails/line lanes`，`RecentCommitsView.swift` 的
`commitRow/referenceStrip/stashBadge/commitFiles`、
`GitGraphPalette`，`TreeRowSurface` 的
`displayed/focusRing/contextRing`；
`GitStatusModel.RecentCommit` 的 refs/parents/worktree；
Git Graph 现有分页加载与长文本独立横滚。

**实现门禁与步骤：**
1. 以固定版本 VS Code SCM/Git Graph 源码作为行为参照，在 Bailey Dev
   使用受控提交 DAG 做明暗主题的原生实际对照；已有可用上游 GUI 时再交叉观察，
   不为执行本任务额外安装 Electron 应用或移植扩展源码：
   普通 commit、merge 双父、octopus、交叉 merge、rebase/cherry-pick、
   detached HEAD、标签/远端/多 refs、stash、Uncommitted Changes、
   linked worktree、隐藏/缺失父提交与分页连接。
2. 比较每行 `expanded`、`hover`、`context`、`focused`、
   `displayed file` 的独立视觉；
   **上游 Git Graph 扩展在详情展开时有灰底，
   Bailey 当前 docs 声称“展开不产生持久灰底”**。
   按 `docs/ui.md` 保留 Bailey 的“展开无持续灰底”，
   不用把“全部都只有蓝色描边”误作 VS Code 同义。
3. 仅对现有测试未覆盖的具体失效建立 Red，复核真实 Git parents 和 rails，
   refs 同色跟随真实分支，合并后保持分支颜色；
   图谱本身不水平滚动，只有长标题/路径独立横滚且不挪动固定按钮；
   长标题/中文/emoji 不溢出，
   1000+ commit 分页不丢颜色/详情/右键对象。
4. Green：仅在 `CommitGraphLayout/GitGraphPalette` 与
   Graph 行自身的视觉 modifier 内解决几何/颜色/背景不变量，
   不动 Files/Git Changes 的共享状态语义；
   不增加重绘期间的额外 Git polling；
   只有发现真实重复/已替代实现才清理旧条件色或图谱辅助方法；
   不重写已由 `CommitGraphLayout` 正确承载的多父图，不增加额外缓存/颜色协调器。
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

<a id="p3-t6"></a>

## P3-T6 Git Graph 引用/Stash/Worktree/危险操作与目标失效

**上游：** Git Graph 扩展 `web/main.ts` 以 Ref/Commit/Stash/
Uncommitted 类别选择菜单动作，`web/contextMenu.ts:refresh/close`
在原 index 的完整 hash+ref 仍匹配时重绑，否则关闭菜单，不做全表恢复搜索；
内置 `scmHistoryViewPane.ts:_onContextMenu` 按 provider/refs 区分可用动作。

**Bailey 锚点：**
`RecentCommitsView.BranchAction/RemoteAction/TagAction/HistoricalFileAction/WorktreeAction`、
`GitPanel` 的 `handleHistoricalFile`/现有原生 Sheet 与 `performOperation`、
`GitStatusModel.ActionTarget/isCurrent/perform`、
`branchAction/remoteAction/tagAction/stashAction/worktreeAction`、
`contextRowID/contextTarget(for:)`；
`GitStatusModel` 的 `canActOnCommit`、当前 ref/stash/worktree 有效性、
本机/SSH 仓库执行和 `GitBranchDialog`、`GitTagDialog`、
`GitStashDialog`、`GitUncommittedDialog` 等原生确认。

**来源边界：** 固定版本 Git Graph 扩展的 `web/`、`src/` 没有 Worktree 交互实现；
Worktree 是 Bailey 自有能力，依据当前源码/测试及 Git 契约保留，不冒称扩展复刻。

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
3. Green：先追踪完整路径：Graph 菜单捕获的普通 commit/ref/stash/worktree
   → GitPanel 的当前窗口/项目/PanelContext 校验
   → `GitStatusModel.ActionTarget` 或专属 stash/worktree 目标
   → `perform` 的真实仓库/HEAD/ref 与 SSH backend 复验
   → 原生 Sheet 取消/确认及最终副作用。
   仅在已证明存在缺口的原有校验入口处完善，
   菜单/contextRow 不足时用当前模型 identity 解析一次，
   不增加第二套危险操作后端和全局 MenuManager。
   用户确认前后复核目标并保留未保存编辑和待操作输入。
   Stash 需同时辨认 selector 和 OID，ref 需辨认全名与目标 OID，
   Worktree 需辨认机器、路径、HEAD/分支和锁定状态；
   一次 refresh 中数组序号变化不能把旧右键目标换成新对象。
   不把 `canActOnCommit` 等按钮展示条件当作替代执行时复核的安全机制。
4. 沿用共享 `ContextMenuClickTarget` 的 NSMenu tracking/关闭通知：
   原生菜单关闭后撤销临时描边；若打开期间刷新导致目标过期，
   后续菜单动作必须按原始目标拒绝执行，不能只依赖 SwiftUI 行已消失。
   **不为已经正确的菜单新增第二层 Event Monitor 或全局 MenuManager。**
   Git Graph 原生 NSMenu 取消后临时视觉必须清除；
   实际操作成功后更新真实状态，不因一次失败清空仍可信的 Git 图谱；
   仅删除本任务经真实调用方检索确认已经不再可达或被替代的转发；
   没有重复路径时不强行拆/合方法，不因省代码删除数据保护。

**验证：** `GitExecutionTests`、`GitStatusModelTests`、
`GitStashActionTests`、`GitRemoteBranchActionTests`、
`GitUncommittedActionTests`、`GitNativeDialogTests`、
`GitDialogUITests`、`GitGraphUITests`；
真实 Git index/HEAD/refs/工作树/双窗/切仓库、
Detached、linked worktree、stash、取消/确认、权限失败、SSH 断连；
`make build:dev`。Docs `docs/features/git.md`、
具体 SSH 身份契约变化时 `docs/features/ssh.md`；一个提交。

---

<a id="p3-t7"></a>

## P3-T7 Graph/Changes 列表身份、刷新分页及跨组显示恢复

**源码：** VS Code List/Tree `TraitSpliceable`、
`scmHistoryViewPane.ts:SCMHistoryTreeIdentityProvider`、
Git Graph 扩展 `ContextMenu.refresh` 在重绘时验证原 index 的完整 hash/ref，失配即关闭，
History Graph 分页/LoadMore 不能改变已展示的 Diff 身份。

**Bailey 锚点：**
`GitStatusModel.repositoryIdentity/currentScope`、`graphCommits`、
`PanelContext.Identity`（project/workspace/directory）、后端连接代次及
`GitStatusModel.contextGeneration`/`statusRequestID`（已有内部机制）、
`RecentCommitsView.commits/selectionScope`、`requestedLastCommit`、
`selectedRowID/contextRowID`、`expandedCommitIDs`、
`GitPanel.onChange`、`Project.openDiff`、
`DockWorkspaceModel` 的 active group/selected。

**任务：**
1. 核对独立实例 A/B 仓库在相同 SHA、同名路径和交错 SSH 连接中的列表身份；
   记录刷新/分页/重命名 ref 后哪些状态必须保留，哪些临时目标必须失效。
2. Red：多页提交中已展开较旧 commit、鼠标右键正在跟踪时新增提交/切换分支；
   当前 `RecentCommitsView` 仅在 repoRoot/selectionScope 改变时清理 Graph 游标，
   当前 `GitPanel` 也主要监听 rootPath/repositoryIdentity/currentScope。
   同 SSH host+目录但**不同 Project ID** 的切换会更新 `PanelContext.Identity`，
   不一定改变前述字符串；先验证是否会把前一个项目的临时菜单、
   选区或未完成比较带入新项目。连接代次变化仍须确认写操作是否被拦截。
   Graph 数据晚到不能把旧 commit/ref 绑定到新 index；
   同名 Changes/History 行菜单不得串线，编辑器已显示旧历史 Diff 可以继续只读。
3. 在当前所有者按 ID 重绑有效选中和可见展开，
   同一项目/仓库的普通状态刷新保留有效展开/游标，
   真正切项目、切后端或 SSH 连接代次变化时撤销临时菜单及旧比较请求，
   不把与仓库内容无关的 view 重建当成新身份；
   失效的临时菜单/拖放必须立刻清理；禁止把 array index 当稳定 commit identity；
   不借刷新事件修改实际 NSWindow.firstResponder。
4. 根据真实调用链证明重复或已被替代的 selected/context 赋值后直接清理；
   遇到性能疑点才测量，无需为显然的冗余强制运行 Instruments。
   不引入全局选区缓存、
   手动 reconcile 管理器或“防重绘”额外 generation；
   不改 Git 的轮询/FSEvents 所属任务设计。

**验证：** 先复用已有 `GitStatusModelTests` 的历史分页/SSH 重连、
`CommitGraphLayoutTests` 的 5000 提交图谱、`NativeGitHistoryFileTests` 的内容读取、
`GitChangesUITests`、`GitGraphUITests` 的原生分页、`GitHistoryUITests`；
仅对实际发现的身份泄漏/菜单过期缺口新增回归。覆盖 1k+ 提交分页、跨 SHA/Repo/SSH、
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
3. 依据本轮重新核实的固定上游源码和当前 Bailey 实现，
   用 `source-review.md` 的 SCM/History/Git Graph 行为矩阵逐项核销；
   该文档中的旧基线结论不得直接冒充当前实现或执行后的验收证据；
   保留“两个上游 Graph 不同”和“扩展代码禁止直接复用”的证据，
   不把 Graph 的禁用多选误改为 Changes 的多选。
4. 每 task 实现与测试/文档同 commit，取代旧状态/兼容壳时在**同一 task**
   迁移所有真实调用方并删除旧路径；`PendingDiscard`、`perform`、
   `PanelContext` 和原生输入保护须在等效验证成立后才可删改，
   不以安全代码较多为由无证据删除；
   `todo.toml` 写 SHA；`phase-complete --phase p3` 后立即运行
   `plan-task-auditor` 的独立 `audit-p3.md` Gate；
   未核销的真实 Windows SSH、极端多父、Mac 15.6 或外部权限需逐项列原因和影响。
