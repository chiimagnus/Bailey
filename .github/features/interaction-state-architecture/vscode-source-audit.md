# VS Code 源码对照与 Bailey 交互差距

本页只保存**源码证据、行为差异、移植边界和验收矩阵**；需求见 `idea.md`，
每个具体改动和提交边界见 `plan-p1.md`～`plan-p5.md`。
这是执行前的源码基线，不是已通过的 Bailey 验收结论。

## 版本、来源和许可

| 来源 | 固定版本 | 使用边界 |
| --- | --- | --- |
| [microsoft/vscode](https://github.com/microsoft/vscode/tree/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e) | `4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e`，2026-10-27 | MIT。可以按许可采用适用算法和结构，若复制源代码需保留许可和版权说明；不移植 Electron/DOM。 |
| [mhutchie/vscode-git-graph](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812) | `d7f43f429a9e024e896bac9fc65fdc530935c812`，develop | **非 MIT**：`LICENSE` 明确禁止发布、分发、再授权或出售衍生作品。仅作行为研究与独立 Swift 实现，禁止复制源代码、图谱实现、CSS、资源进入 Bailey，除非另获许可。 |

VS Code 内置的 Source Control Graph（SCM History）与 Git Graph 扩展是两个不同产品；
本计划同时检查前者的原生树/时间线语义和后者的完整 Git Graph 交互。
“全面吸收”不是直接粘贴 Electron/Webview 代码，而是**逐项实现同等可观察行为、事件边界、
状态所有权、可访问性、视觉与异常行为**。遇到用户已明确否决的行为和
Bailey 架构硬约束，先记录差异和验收决定，不偷偷改回。

## 统一状态词典与架构映射

| 事实 | VS Code 源码中的独立真源／事件 | Bailey 当前真源 | 严禁混淆 |
| --- | --- | --- | --- |
| Keyboard Focus（行游标） | `listWidget.ts` Focus Trait；Tree Trait | Files `FileTreeModel.selectedPath`；Git Changes `selectedChange`；Graph `selectedRowID`；Projects `cursorProjectID` | 不等于系统第一响应者、打开、Selection |
| Selection（显式集合） | Selection Trait，支持复选与范围选择；编辑器另有 `selectedEditors` | Files `selectedPaths`；Git Changes 单个 `explicitlySelectedChange`；Dock 每组单一 `selected` | Git Changes 和 Dock 当前缺完整多选能力，不能共享 Files 路径集合 |
| Anchor（范围锚） | List Anchor Trait；Tabs `lastSingleSelectSelectedEditor` | Files `selectionAnchorPath`；其它领域缺或有不同语义 | 不等于当前鼠标位置或下一次选择的默认点 |
| Displayed / Active Document | Explorer `editorService`、SCM Diff、EditorGroup 的 `activeEditor` | `FileTab`/`DiffTab`、DockGroup.selected | 展示的文档不代表 Files/Git 行被选或对应输入焦点 |
| Expanded / Collapsed | `abstractTree.ts` 模型；Git Graph `expandedCommit` | Files `expanded`、Git `collapsedFolders`、Graph `expandedCommitIDs` | Graph 的展开与 Focus、右键、选中应是不同事实 |
| Context Target | Explorer `onContextMenu`；SCM action runner；Tab `onTabContextMenu`；Git Graph `ContextMenuTarget` | `FileTreeModel.contextMenuTargetPath`、`contextChange`、`contextRowID`、Dock `contextTarget` | 菜单结束撤销；不能隐式切项目、打开文件、改活动标签 |
| Hover / Drag Over | List CSS、Graph `.graphVertexActive`、Tabs hover 与 DnD | `RowHighlightStyle.hovering`、各拖放目标 | 不能持久改变 Selection、实际焦点或底层 Git 操作 |
| Active Pane / Window Focus | `EditorPart.activeGroup` 与 DOM focused input 分开；ListService.lastFocusedList | `DockWorkspaceModel.activeGroupID` 与 NSWindow.firstResponder | 不把“活动组”假装成编辑器/终端实际获得输入 |
| Preview / Open / Pin | `ResourceNavigator` 的单击/双击 `onDidOpen` 和 `preserveFocus,pinned` | Files `openFile(path, activating)`、Project `openFile` | Bailey 当前没有 VS Code 的临时预览标签机制；要单列产品决定 |
| Persist / Restore | Tree `identityProvider` 和 `getViewState`；EditorGroup 模型 | FileTree 根/机器缓存、DockNode、Project 和会话恢复 | 不以刷新/挂载重置输入、选中、展开、未保存内容 |

**边界：** 共享的是可证明相同的列表事件规则、RowHighlighter 和原生键盘适配；
每个业务领域自己拥有选择键、命令对象和打开动作，不建立 App-wide FocusManager、
万能 SelectionStore、跨窗口菜单状态或 Electron 式全局 ContextKey 系统。

## 逐文件源码审计（固定提交）

### 基础 List / Tree / Explorer

| VS Code 文件与重要符号 | 已读结论 | Bailey 映射与待处理 |
| --- | --- | --- |
| [`listWidget.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/base/browser/ui/list/listWidget.ts) `Trait`、`SelectionTrait`、`TraitSpliceable` | 焦点/选择是不同 Trait，索引更新依稳定 identity 重映射；AX 选择只跟实际 Selection | `FileTreeModel` 的 root/scope 重建、Git Changes 列表和 Graph 提交分页，检查更新后真实行是否仍对齐 |
| 同上 `KeyboardController`、`MouseController` | 方向键移动 Focus/Anchor，Enter 设置选择，Escape 清除选择；Mac ⌘ 切换单项、Shift 扩范围；右键首先定位 Focus | `FileTreeScrollView.handleKey`、`FileTreeModel.select/focus/moveSelection`、各 Git/Projects 键盘入口，不机械统一 Open |
| 同上 `changeSelection`、`getContiguousRangeContaining`、`disjunction`、`relativeComplement` | Shift 扩/缩只调整锚点连通区间并保留不相邻的选择岛 | `FileTreeModel.selectRange` **已确认与上游不同**：当前覆盖整个 `selectedPaths`；P1 先 Red 再修，不提前改业务代码 |
| 同上 `DefaultStyleController` | Focus/Selection/Focus+Selection/Hover/失焦/Context 各有样式，覆盖优先级独立；菜单可用 `last-focused` | `RowHighlightStyle` 当前菜单目标会强制透明底，这与上游焦点/选择重叠不完全一致；先做双 App 实机对照并明示视觉取舍 |
| [`abstractTree.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/base/browser/ui/tree/abstractTree.ts) `Trait`、`AbstractTree`、`TreeNodeListMouseController` | 折叠节点的选择真源在 Tree 层，按 identity 保留；twistie/按钮命中不冒充整行选择 | `TreeDisplayModel`、`FileTreeModel.rebuild`、`TreeRowSurface` 的目录/紧凑行/无障碍和刷新 |
| [`listService.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/platform/list/browser/listService.ts) `MultipleSelectionController`、`ResourceNavigator`、`ListService` | 统一修饰键，选择≠打开；`onDidOpen` 携带 `preserveFocus,pinned,sideBySide`，列表焦点归属作用域内 | Bailey 使用最小 SwiftUI/AppKit 适配，不复制全局服务；Files 和 Git 打开事件应能明确表达保留焦点或切换焦点 |
| [`explorerView.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/files/browser/views/explorerView.ts) `getContext`、`onDidOpen`、`onContextMenu` | 多选时命令作用 Selection；否则使用 Focus/压缩目录真实段。右键选区外改为该项，不转发成文件打开 | `FileTreeModel.selectedOperationPaths/contextSelection`、`FileTreePanel.rowMenu`、`WorkspaceWindowModel.performFileTreeCommand` |
| [`explorerViewer.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts) `ExplorerCompressionDelegate`、`getCompressedNavigationController` | 紧凑目录有独立段目标，图标/文本/留白不同命中；身份由真实文件 URL 决定 | `FileTreePanel` compact components、路径动作、Finder DnD 和 AX |
| [`fileActions.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/files/browser/fileActions.ts) | 文件命令从 Explorer getContext 取得准确目标，保存确认/路径动作在后端 | `FileTreePanel.performEdit`、`WorkspaceWindowModel.performFileTreeCommand`、本机/SSH 实际副作用 |

### Source Control Changes、内置 History Graph 与 Git Graph 扩展

| 上游文件 | 已读结论 | Bailey 映射与待处理 |
| --- | --- | --- |
| [`scmViewPane.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/scm/browser/scmViewPane.ts) `createTree/open` | SCM 树有 repo/group/input/resource/folder 不同节点；一个 `onDidOpen` 按节点类型执行，输入框取得焦点时清除树游标 | `GitPanel`、`GitEntryRow`，区分 stage/unstage/discard 与浏览 Diff 的命中/焦点 |
| 同上 `RepositoryPaneActionRunner/getSelectedResources/onListContextMenu` | SCM 可操作资源来自显式选中集合；右键菜单按资源类型选动作，上层按有效仓库分发 | 当前 `explicitlySelectedChange` 仅单项；需补可选多选、范围和批量 Git 操作的安全语义；不能用 Files 的路径集合 |
| 同上 `onDidActiveEditorChange` | 显示变动的自动定位为明确受配置控制的动作，可同时更新 Focus/Selection，不是“展示即焦点” | `isDisplayedChange/browseGitChange`，按用户批准的自动定位语义验收；不能另造失焦抢占 |
| [`scmHistoryViewPane.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/scm/browser/scmHistoryViewPane.ts) `SCMHistoryTreeIdentityProvider/_createTree/_onDidOpen/_onContextMenu` | 历史树独立 identity；`multipleSelectionSupport:false`；提交、文件、加载更多各有不同打开/右键动作 | `RecentCommitsView` 的提交/历史文件/分页/Stash/Worktree 局部状态，**不允许强行套 SCM Changes 多选** |
| [`scmHistory.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/contrib/scm/browser/scmHistory.ts) `renderSCMHistoryItemGraph` | 入/出 swimlanes、commit/ref badges、图谱占位在几何层；与交互选中分离 | `CommitGraphLayout`、`RecentCommitsView` rails/节点/徽章，拓扑不应被渲染状态改变 |
| [扩展 `web/main.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/web/main.ts) `observeTableEvents/observeKeyboardEvents/loadCommitDetails` | 单击提交打开/折叠详情，⌘点其它提交比较；方向键浏览，⌘方向键沿父/子分支；ref 双击与普通单击有不同语义 | `RecentCommitsView.toggle/activate/handleGraphKey`；明确 Bailey 现有“点标签统一展开”与上游 ref 双击 checkout 的产品冲突，未经决定不引入危险动作 |
| 扩展 [`web/contextMenu.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/web/contextMenu.ts) | commit/ref/stash/repo/详情菜单目标分别标识；菜单关闭撤临时状态；列表重渲染按 hash/ref 重绑，否则关闭 | `contextRowID/contextTarget(for:)`、`ContextMenuClickView`，重点检验分页/刷新/换仓库和延迟菜单关闭 |
| 扩展 [`web/styles/main.css`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/web/styles/main.css) | Hover/菜单临时目标弱灰，展开详情深灰、叠加较深灰；ref 活动边框与其父提交背景独立 | Bailey 当前 Graph “展开无持续灰底”，构成视觉差异；需单项视觉对比决定目标，不复制原 CSS |
| 扩展 [`web/graph.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/web/graph.ts) | DAG 中的 branch/vertex/parents、展开详情影响路径几何、节点 hover 独立 | `CommitGraphLayout`、`GitGraphPalette`；按独立样本比较 merge/octopus/reflog/stash/worktree，不直接移植算法代码 |
| 扩展 [`src/gitGraphView.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/src/gitGraphView.ts)、[`src/dataSource.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/src/dataSource.ts) | UI 事件与 Git backend 操作分开，异步 commit details/comparison 与仓库结果有目标约束 | `GitStatusModel`、`GitPanel` 现有模型/后端，保留本机和 SSH 可靠身份校验、危险操作确认 |
| 扩展 [`src/repoFileWatcher.ts`](https://github.com/mhutchie/vscode-git-graph/blob/d7f43f429a9e024e896bac9fc65fdc530935c812/src/repoFileWatcher.ts) | Git metadata 事件过滤与 UI 重绘独立 | 当前 Bailey 的本机事件驱动和 SSH 轮询/通知路径沿用既有所有者，本次仅检验刷新是否错改选择/图谱，不另建刷新架构 |

### 编辑器标签、活动组与 Dock

| 上游文件 | 已读结论 | Bailey 映射与待处理 |
| --- | --- | --- |
| [`editorGroupView.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/editorGroupView.ts) `setSelection/openEditor/doShowEditor` | ActiveEditor、SelectedEditors（多选）、PreviewEditor、Pinned/Sticky、GroupActive 各独立；打开与激活并非同一效果；失败保留有效编辑器 | `Project.selectedTabID`、`DockWorkspaceModel.activeGroupID`、DockGroup.selected、`FileTab` 保存保护；本次不隐式加预览生命周期 |
| [`multiEditorTabsControl.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/multiEditorTabsControl.ts) `registerTabListeners/selectEditor/selectEditorsBetween/unselectEditor` | **标签本身支持⌘/Shift多选和范围锚；** 触发时活动标签和已选集合分别更新；右键不必激活标签；键盘导航、Shift+F10、鼠标中键明确动作 | Bailey Dock 当前只持有每组单项 `selected`，缺少标签多选集合/Anchor/批量拖动；是独立 P4 子任务，不借用 Files 选择 |
| 同上 `onDragStart/onDrop` | 用 selectedEditors 批量拖/复制/移动；组间移动与单个标签输入保留，失败不激活幽灵目标 | `DockTabDragCoordinator`、`DockWorkspaceModel.move`、`WorkspaceDockView.tabStrip`；需真实批量结果与安全关闭验证 |
| [`editorTabsControl.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/editorTabsControl.ts) `onTabContextMenu` | 右键命令明确 `groupId/editorIndex`，动态检查 pinned/dirty/cannotClose，菜单关闭回到真实活动组 | `DockWorkspaceModel.contextTarget/closeTarget`、`WorkspaceDockView.handleMenuKeyDown`，处理后台标签与跨组准确路由 |
| [`editorPart.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/editorPart.ts) `doSetGroupActive/addGroup/removeGroup` | 活动组切换归 Group owner；重排后仅在旧输入确属当前容器时才恢复焦点 | `DockWorkspaceModel`、`DockGroupFocusReader`，只对成功的 click/drop 交接目标 |
| [`editorDropTarget.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/editorDropTarget.ts) `handleDrop` | 拖动 Editor/Group/Tree/外部 URI 四类来源分别解析；落点可拆组、移动/复制；实际成功后聚焦目标 | Bailey 的独立外部 Finder 投放、单标签 Dock Drag、Files 内部移动；不可混同后端，需按来源/边界核验 |
| [`editorParts.ts`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/editorParts.ts) | 多窗活动 Part 由真实焦点与 MRU 决定，后台不能偷取另一窗焦点 | Bailey 每窗 `WorkspaceWindowModel`、应用 `WorkspaceApplication`，多窗口/WindowGroup 保持单一命令属主 |
| [`multieditortabscontrol.css`](https://github.com/microsoft/vscode/blob/4bda7217fc83e8e838b1edd9ebaf21bb9b498c7e/src/vs/workbench/browser/parts/editor/media/multieditortabscontrol.css) | 标签 active、inactive、selected-but-not-active、组激活、组失焦有不同背景/文字与 hover 规则 | Bailey `TabItemChrome` 当前共用树行 `RowHighlightStyle`，需按 Tab 专属角色审查是否过度复用；Settings 更不能被拉入 |

## 分区域交互差距与决策门禁

状态列：**已有**表示 Bailey 有对应实现但还须复验；**差异**表示上游源码与当前 Bailey 不一致；
**需观察**表示不能仅凭源码证明原生 UI 是否复现；**决定**表示牵涉此前明确产品取舍。

### Files / File Manager

| 场景 | VS Code 规则 | Bailey 现状与后续 |
| --- | --- | --- |
| 单击、双击文件 | ResourceNavigator 分别构造 preview/open 意图，preserveFocus/pinned 独立 | **已有** 单击浏览、双击进入编辑器；**决定** 不自动创建 VS Code preview tab，先对照再确认需求 |
| 普通方向键与 Shift 方向键 | Focus 与 Anchor 不等于 Selection；Shift 在有关手势中扩选 | **已有** cursor/selection 分离；**差异** Shift 扩选覆盖不相邻选择，P1-T1 |
| ⌘ 点击 / Shift 点击 | 非连续 toggle，锚点区间合并，Shift 回缩只撤旧区间 | **已有一部分**；逐条检查 5+ 行、反向、锚点被取消、覆盖多岛与可见顺序 |
| 目录行/扭转箭头/空白 | 折叠与 Selection、打开分别路由 | **需观察** 高亮区、左/右动作、目录压缩不同段与横向滚动 |
| 右键已选/未选 | 集合内保持多选，集合外换成单一对象；不打开文件 | **已有** `selectForContextMenu`，须检验菜单停止/失效/作用集合与真实 file bytes |
| 可见/已折叠列表重建 | Tree Trait 按身份保留或失效，避免无意义焦点跳变 | **差异风险** `rebuild` 路径过滤/目录改名/SSH 重连必须与 identity 同步 |
| Edit/菜单操作 | >1 选择用集合、否则焦点及真实紧凑段 | **已有** 两入口分别解析，须消除重复决策并验证跨窗口和 SSH |
| 拖动与 Finder | 明确源和目的、Copy/Move 与磁盘真实副作用 | **已有** 内部拖动/外部 Finder，须同选择/菜单目标核验 |
| 视觉/AX | 正常/失焦/选中+焦点/右键重叠有明确层级 | **差异** 现有 Context Ring 强制清除 Selection 底色；先用 VS Code/VSCodium 和 Bailey 真实界面核对 |
| 大文件目录 | 稳定 identity、虚拟化与增量渲染 | **需观察** 10k/100k 行、折叠/过滤后 cursor/Selection 性能与正确性 |

### Git Changes / Git Manager

| 场景 | VS Code SCM | Bailey 现状与后续 |
| --- | --- | --- |
| 行节点类型 | Repo/Group/SCMInput/ActionButton/Folder/Resource 各走不同点击、焦点行为 | **差异** Bailey Changes 主要是 Staged/Unstaged/Merge 行，需逐类型映射而非强制同一打开动作 |
| 多选与批量命令 | `getSelectedResources` 返回多个选项，RepoActionRunner 使用集合 | **缺口** `explicitlySelectedChange` 只有单项；设计 Git 专属选择集合/Anchor、可用性与批量副作用 |
| 目录/文件操作 | 展开只动树，文件 Open 命令才打开 Diff；Stage/Unstage 行独立 | **已有** `browseGitChange`、`directoryRow`；检查单击、Space/Return、按钮冒泡 |
| Edit 输入框 | 输入接管会清树焦点，返回时才恢复当前可见树 | **已有一部分** `focusGitChanges`，需真实原生输入验收 |
| 展示 Diff 与自动 reveal | 仅显式动作或已启用 autoReveal 改 selection；不把 displayed 当 selected | **差异待查** `isDisplayedChange` 与 `selectedChange` 的反馈和副作用 |
| 右键目标 | 不同资源类型菜单与可执行状态，独立操作上下文 | **已有** `contextChange`；多选后菜单动作必须按集合作为单位且标清合法组合 |
| 仓库/SSH | 当前 provider/repo 的 identity 决定合法操作 | **已有** `GitStatusModel`；多窗口/断连/刷新前后验收 |
| 列表样式 | 每个 Selection/Focus/Displayed/Context 分离，无额外两层系统焦点 | **已有共享样式**，须图谱、Files 共同视觉 + AX 复核 |

### Git Graph（内置 SCM History + Git Graph 扩展）

| 场景 | 上游规则 | Bailey 现状与后续 |
| --- | --- | --- |
| 提交单击 | 扩展单击提交切换详情，内置历史提交由树节点独立表现 | **已有** `expandedCommitIDs` 可多项展开；是否改扩展单展开须先定产品目标 |
| 提交多选/比较 | 扩展 ⌘ 点两个提交打开比较，内置 History Tree 明确关闭多选 | **缺口/决定** 必须单列“比较两个提交”，不能误当普通选中、右键菜单或 Git Changes 多选 |
| ref 标签 | 扩展 ref 单击/双击/右键语义不同；可能双击执行 checkout | **与既有用户决定冲突**：Bailey ref 单击统一展开详情，不应无提示复活双击 checkout；需独立选择取舍 |
| 提交上下左右键 | 扩展正常 ↑↓ 行导航，⌘↑↓ 同分支，⌘⇧↑↓ 备选分支 | **需观察** Bailey `handleGraphKey` 的实际覆盖，补对应语义但不能改变系统菜单快捷键 |
| 历史文件单击 | 真实 Git revision Diff/对比读取，展示与提交详情独立 | **已有** 文件行和 DiffTab；检验仍在 Git 的焦点，SSH/历史只读与失败 |
| Stash/Worktree/Uncommitted | 单独节点/上下文菜单，身份和危险动作不同 | **已有**；检验真实 refs/HEAD/index/工作树，而非仅颜色 |
| 右键图谱提交/ref | 不应触发详情展开；生命周期按 commit hash/ref 重绑或失效 | **已有部分** `contextRowID`；菜单关闭后仅清临时状态，Git Graph 更新目标禁止错作用 |
| 详情展开灰底 | 扩展展开 row 约 .25 灰底，菜单 hover 另叠；内置 History 可不同 | **差异/决定** Bailey 当前 Graph 展开不产生持续灰底；先实机可视对比，并确认是否启用 |
| 颜色拓扑 | swimlanes/parents/branch labels/merge/refs 独立渲染 | **已有** `CommitGraphLayout`；测试 octopus/rebase/cherry-pick/分页/颜色/长标题 |
| 扩展视觉授权 | 扩展 CSS/graph 受禁止衍生分发许可证约束 | **硬约束** 只独立复刻可观察 UX，不从扩展粘贴任何代码或资源 |

### Dock、标签栏、Projects、临时列表

| 场景 | VS Code 规则 | Bailey 现状与后续 |
| --- | --- | --- |
| 展示 vs 激活 | EditorGroup activeEditor 与 activeGroup 独立；Native input 另有焦点 | **已有** DockGroup.selected + activeGroupID，但 Project.selectedTabID 需检查“最近工作”是否误代表全组当前展示 |
| 标签多选/锚 | ⌘ 切换单项、Shift 连续区间、单击时恢复单选；每组独立 | **缺口** 目前每组只一选；必须设计最小 per-group selected items + anchor，不能用全局 Files Set |
| 多标签批量拖动 | 拖动已选标签集合，Ctrl/Option 复制语义和组落点归宿 | **缺口** DockTabDragCoordinator 仅单个 item；多标签在不同组/项目/窗口的安全边界待定义 |
| 批量关闭与菜单 | 右键未活动标签不自动激活；菜单拥有准确 clicked group/index/selection | **已有** 单项 `contextTarget`；新增多选后必须明确菜单范围与脏文件关闭保护 |
| 原生键盘标签导航 | Tab ↑↓←→/Home/End、Enter/Space 激活、Shift+F10 菜单 | **差异** Bailey 要核对 SwiftUI 标签焦点接管，不能让方向键跑到编辑器 |
| 中键关闭/双击 | VS Code 有中键关闭、双击固定预览或调整组；Bailey 固定标签且不支持 preview | **决定** 可对齐中键关闭，双击行为需要产品与现有布局契约比较 |
| 标签颜色与焦点 | active tab、selected non-active、inactive group、hover 四层不同 | **差异** 现在 `TabItemChrome` 复用列表 RowHighlightStyle，须决定改为 tab 专有视觉，不再套同一 TreeRowSurface |
| 跨窗口拖放/焦点 | group/drop result 才交接第一响应者；多窗口不能把命令送另一窗口 | **已有部分**，验证真实 NSWindow+Editor/Terminal 保留原始内容 |
| Projects 列表 | 其对象是 project，不是 editor tab；键盘游标与当前项目独立 | **已有** `cursorProjectID`、`selectedProjectID`，需要删除重排/焦点/右键联合测试 |
| Palette 与 Ctrl+Tab | 输入框、当前结果游标和临时预览不可写回持久 Tab selection | **已有** `CommandPaletteView`、`TabSwitcherController`，验证 Esc/焦点恢复/跨窗 |
| Settings | macOS 原生 `List(selection:)`，用户明确要求回撤共享样式 | **非目标**：保持 `9c84d355`，不纳入本次高亮/Focus 模型 |

## 行为取舍必须显式记录

实施前把下列冲突逐个使用**VS Code 源码 + 真实 VSCodium/VS Code UI + Bailey Dev**核对，
由计划中的前置比较 task 保存证据；无法确认的不能直接默认为已有行为。

1. **右键背景是否保留：** VS Code 对选中与焦点可叠加；Bailey 当前右键目标强制隐藏底色。
   用户此前反对误叠加的蓝色底＋蓝框。应先判定“用户反对错误双重焦点”还是“任何右键都必须无底”；
   为这项明确差异设置决策 Gate，不擅自更改主题样式。
2. **Git Graph 展开背景：** 扩展持久灰底，Bailey 当前没有；展开本身不是键盘 Focus。
   颜色/深浅在主题和高对比度下检查后记录保留/调整的决定。
3. **Git Graph 标签单击/双击：** 扩展可能双击 Checkout；Bailey 曾明确撤回标签直接执行动作。
   只吸收菜单目标隔离和图谱交互，不把危险操作绑回双击。
4. **标签多选：** VS Code 每组 tabs 可多选。用户要求全面吸收，作为新功能明确纳入，
   但必须先核对 Bailey 的工具 tab 与编辑器 tab 混组后如何选择、批量关闭和拖动。
5. **临时预览标签：** VS Code ResourceNavigator 可以创建 preview editor；Bailey 当前只有固定文档标签。
   这将引入新的生命周期/替换未保存对象风险，单独列为待产品决定，不能偷加。
6. **原生菜单：** 不能直接复制 VS Code DOM ContextKey/事件监听或 Git Graph Webview 菜单。
   只移植“上下文目标/可用性/动作结果”的契约，继续使用 NSMenu 和现有 SwiftUI 命令。

## 交互与渲染验收组合

| 轴 | 适用取值 | 真正的后置结果 |
| --- | --- | --- |
| 指针与键盘 | 左单击、双击、⌘、Shift、⌘+Shift、右键、Control-click、触控板、拖动、中键（可用设备）、↑↓←→、Home/End、Space/Return/Esc、菜单等价键 | 对照焦点、Selection、Anchor、展示/展开、真实打开/关闭/副作用 |
| 状态 | 无/单/离散/连续/非连续多岛、焦点在集合内/外、菜单前后、被展开/折叠、hover+selection、已显示但未选择、失焦 | 每种状态的行背景/描边/AX 与实际命令目标均一致 |
| 节点 | 本机/SSH 文件与目录、紧凑目录各段、Git 状态分组和文件、历史提交/refs/Tag/Stash/Uncommitted/Worktree、工具/文件/Diff/Terminal/Browser 标签 | 右键命中和所有操作作用真实节点，不因同名/相似路径错位 |
| 变动 | 刷新/分页、过滤/排序、文件 rename/move/delete、Git checkout/rebase/new ref、项目切换、SSH 断线与恢复、Dock 移动/关闭和布局恢复 | 稳定身份保留有效状态，失效及时清除且禁止错作用 |
| 外观 | 默认/自定义 Ghostty 主题、macOS Light/Dark、字号上下限、宽/窄窗口、长行、中文/英文、Unicode/emoji、VoiceOver/AX | 视觉与点击区域一致、不重叠伪焦点、键盘可达 |
| 性能 | 空/单行、1k/10k/100k 视图项目（适用时）、多分支 DAG、长路径/多组标签、连续导航与重绘 | 滚动/键盘不因为选择而退化为整树重建，性能指标由实际基线记录 |
| 窗口/权限 | 单/双窗口、多分屏、input field/IME、终端、编辑器、Sheet/Palette、可测试的最小 15.6 与当前 macOS、授权/未授权自动化 | 前台 NSWindow firstResponder 不被后台抢走；未保存字节和输入保留 |
| 数据 | 真实本机文件字节/剪贴板，真实受控 Git index/HEAD/refs，授权 SSH Windows 项目和断连重连 | 实际结果与目标完全一致，拒绝远端回退写 Mac |

**覆盖层次：** 纯状态模型和大规模/故障用宿主 XCTest；共享颜色/AX 用最小
`NSHostingView`/NSWindow 像素；只有真正的右键菜单跟踪、跨窗键盘焦点、
系统 Finder 与 Dock 拖放才跑隔离 Bailey Dev `BaileyUITests`。
测试隔离不能修改用户真实剪贴板、正式 Bailey、SSH master 或正在运行的任务。
无法实测的 macOS 15.6、实体触控板、中键、真实 Windows SSH、富类型剪贴板等，
必须在对应 task/阶段审计逐项记录**缺失条件、原因、影响、可替代证据和补验条件**，
不得用“其它测试通过”核销。

## 现有测试基线和可执行入口

- Files 状态/紧凑目录/刷新/SSH：`BaileyTests/Files/FileTreeTests.swift`、
  `SSHFileTreeLiveTests.swift`，真实入口 `BaileyUITests/Files/SharedTreeUITests.swift`、
  `WorkspaceFilesUITests.swift`。
- Files 打开/未保存及跨窗：`FileTabPersistenceTests`、`NativeFileTabTests`、
  `DockWorkspaceTests`、`WorkspaceDockUITests`、`WorkspaceWindowsUITests`。
- Changes/Graph：`GitStatusModelTests`、`CommitGraphLayoutTests`、
  `GitGraphPaletteTests`、`NativeGitHistoryFileTests`，
  `GitChangesUITests`、`GitGraphUITests`、`GitGraphGeometryUITests`、
  `GitHistoryUITests`、`GitDialogUITests`。
- Dock/Project/Input 保留：`DockWorkspaceTests`、`WindowCloseIntegrationTests`、
  `NativePaneRetentionIntegrationTests`、`WorkspaceRetentionUITests`。
- Makefile 入口按 `docs/testing.md`：`make test:<TestClass,TestClass>`、
  `make build:dev`、`make test:ui ONLY_TESTING=BaileyUITests/<Class>`；
  对共享功能做阶段扩展回归，最后全量验收。所有验证必须记录运行结果，**本轮尚未执行**。

计划以现有 `AGENTS.md` 和源码为约束；若 VS Code 上游行为与 Bailey 现有明确产品决策冲突，
在所属 task 的“决策/验收”中写清保留或变更原因，不把主观 UI 偏好当作已验证事实。
