# P1｜完整呈现 Git Graph 同路径文件／目录变更

修好共享树对同路径不同类型节点的表示，让历史文件及其新增后代同时可见，
并确保导航和文件操作使用真实 Git 变更。与 #82 的 LFS 内容读取独立。

## 方案与证据

- 已用**当前生产源码** `TreeDisplayModel.swift` 在临时目录编译复现 Red：
  输入 `D skills/wiki`、`A skills/wiki/README.md`、
  `A skills/wiki/index.md`，`pathRows` 仅输出 1 个文件叶节点；
  两个新增文件被隐藏。
- 真实只读仓库 `~/.codex` 的提交 `3eb51c6`，
  `git show --name-status` 与 `git log --name-status`
  均包含 **31 A、2 D、3 M**，合计 36 条变更。不修改此仓库。
- 来源：`GitStatusModel.recentCommitLogArguments` →
  `parseRecentCommits` → `RecentCommit.FileChange`；
  渲染：`RecentCommitsView.commitFiles` →
  `TreeDisplayModel.pathRows` → `Traversal` → 共享 Tree 行；
  键盘：`appendHistoricalNavigation` 同样读取 `pathRows`。
- **根因**：`TreeDisplayModel.pathRows` 的
  `seen: Set<String>` 和 `directories[parent][path]`
  只按路径去重或覆盖；`Row.id = namespace + path`
  也无法区分同名**叶文件**与**目录容器**。
  `Traversal` 只继续读取 `isDirectory`，
  因此被覆盖为文件的容器会截断其所有后代。
- `RecentCommitsView` 已分别使用 `historicalFileRowID`
  与 `folderRowID` 标识动作；`GitStatusModel.rows`
  和其它树共用 `pathRows`，但常规 Git Changes 没有必要出现两份同路径叶变更。
  Stash 的真正重复路径已有 List 回退，**不删除该有效分支**。

**最小方案**：在现有 `pathRows` 中明确区分
“真实变更文件”和“从路径推导的目录”，
让两者共用路径却拥有不同字典槽位和 SwiftUI 行身份。
不新建 Graph 专用树、不复制折叠状态、不重写 Git parser 或 Traversal；
只在真实回归证明其错误时才修改这些现有正确路径。
保留目录优先排序、状态传播、压缩逻辑和原始 `FileChange` 动作标识。
同路径旧 gitlink 的显示是树问题；其对象不是文本 Blob，
不能擅自将其读作空文本。

## 任务

<a id="p1-t1"></a>
### P1-T1 让共享树正确表达同路径文件与目录

**位置**：`Bailey/Shared/Tree/TreeDisplayModel.swift`：
`Row.id`、`pathRows`；`BaileyTests/Files/FileTreeTests.swift`。

- 固化上述 Red，再覆盖**反向目录→文件**、输入逆序、
  普通嵌套路径、状态聚合、压缩目录和折叠。
- 用节点类型而不是单纯路径区分目录／叶子；
  一次替换错误的 `seen`／路径键决策并清理不再需要的分支，
  保留原 `Traversal` 而非新建特殊渲染流程。
- Green 后核对 Files／Changes／Worktree 的行排序、ID、
  折叠与原生命中没有变化。若涉及功能契约，
  同任务更新 `docs/features/files.md`。

<a id="p1-t2"></a>
### P1-T2 让真实历史、Tree/List 和交互共享同一完整集合

**位置**：`Bailey/Git/RecentCommitsView.swift`：
`commitFiles`、`appendHistoricalNavigation`、`changedFile`；
`Bailey/Git/GitStatusModel.swift` 的历史解析（先校验、必要才改）；
`BaileyTests/Git/GitStatusModelTests.swift`、
`BaileyUITests/Git/GitGraphUITests.swift`、
`GitHistoryUITests.swift`。

- 用隔离真实 Git 仓库生成文件／gitlink→目录、目录→文件；
  核对 Git `-z` 原始结果、解析的 `FileChange` 和完全展开的
  Tree/List **多重集合**（含 status、path），而不是只数视图行。
- 让两条消费者使用同一类型化树结果；
  测试目录折叠、Space／Return、方向键与父链、
  点击文件 Diff、复制路径及旧 gitlink 的准确错误；
  清理被修复替代的路径-only 判断，**不要删除** Stash 真实重复路径的 List 回退。
- 用真实 `3eb51c6` 只读验收全部 36 条（31 A、2 D、3 M），验证交互且不改变仓库；
  保留 PR #87/#88 的图谱刷新、点击与拓扑缓存。
  同任务更新 `docs/features/git.md`；
  视觉／交互契约真的改变时才更新 `docs/ui.md`。

## 阶段验收

**数据**：空、单文件、多层路径、文件／目录双向替换、
gitlink、同名文件、重命名、根提交、Merge 首父、
分页、Stash 重复路径；含空格／中文／控制字符的真实 Git 路径，
SHA-1／SHA-256 仓库。本机和获授权 SSH 后端使用各自临时仓库。
完整展开时叶变更不得丢失／重复；折叠时只隐藏正确的后代。

**交互与共享**：Tree/List、目录压缩、键盘/鼠标、选中与焦点、
Files／Changes／Worktree／Stash、窄面板／字号与主题、
刷新后滚动/展开状态。按既有 Git Graph 大量变更用例观察
是否新增不必要的派生计算和渲染开销；不重复建立性能基准体系。

**执行**：Red→Green 后
`make test:FileTreeTests,GitStatusModelTests,NativeGitHistoryFileTests`；
隔离 Bailey Dev 选取现有 `GitGraphUITests`／`GitHistoryUITests`
真实路径，并补充**一个**完整 App 同路径转换 GUI 回归。
阶段收尾运行仓库要求的完整宿主测试、适用构建与差异检查，
不把宿主成功当完整 GUI 成功。

**未能执行时**：分别说明受阻的最低 macOS 实机、
Windows SSH 临时仓库或独立 GUI 会话、替代证据、
后续复测及是否阻塞当前阶段验收；不得写成已经通过。
