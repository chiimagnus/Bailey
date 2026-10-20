# P3：隐藏规则、Files 搜索与准确定位

**Goal：** 在 Files 上增加简洁的 Glob 隐藏规则、名称／相对路径搜索和 Reveal，另将已有 `⌘P` 快速打开扩展到 SSH；保持原目录树及排序。

**Non-goals：** 文件排序、`search.exclude` 单独配置、VS Code `when` 表达式、`.vscode/settings.json` 自动兼容、内容全文搜索、长期全仓索引服务和第二套文件树。

**Approach：** `FileTreeModel.children` 负责 Files 可见性投影（目前仅硬编码隐藏 `.git`），不动 Git 的 `TreeDisplayModel.Traversal` 排序。Files 树的名字／路径过滤需包含非展开目录，采用**用户查询时的按需遍历**，结果仍绑定当前 Files 模型，不与 `⌘P` 强行共享全量索引。`⌘P` 的 `ProjectFileIndex` 有独立 Git tracked/nonignored 文件语义，单独扩展 SSH；两者只复用必要的路径匹配或后端查询原语，不能把结果集合混用。

**Acceptance：** 默认只隐藏 `.git`，用户规则不改变真实文件与 Git；Files 能搜索非展开的目录／文件；`⌘P` 支持同机 SSH 文件快速打开；Reveal 不会误高亮另一个机器的同名文件。

**Rules：** 隐藏只影响 Files；既有本机 `⌘P` Git ignore 规则不改变；所有异步结果绑定发起目标和连接且失败不表现为空；避免新增常驻缓存和每次按键全量 SSH 扫描。

---

<a id="p3-t1"></a>
## P3-T1 Files 隐藏规则与设置持久化

**源码锚点：** `Bailey/Files/FileTreeModel.swift.children` 的 `.filter { $0.name != ".git" }`、`cachedDirectories/rebuild`，`Bailey/Shared/Tree/TreeDisplayModel.swift.Traversal`（压缩与既定自然排序），`Bailey/App/AppSettings.swift`（`TOML.parse/save/resetToDefaults`），`Bailey/App/SettingsView.swift.workspaceSettings`。

1. **Red：** 在 `FileTreeTests` 为根和嵌套 `.git`、`node_modules`、`src/**/generated?`、`**/*.log`、点文件、同名目录及软链构造数据，验证当前默认仅隐藏 `.git`；检查 Glob 规则命中目录后整个子树不可见，非法规则有错误反馈，不影响 `.gitignore`、Git Graph、`⌘P`。`AppSettingsTests` 覆盖配置初装/重启/重置，以及 `save()` 重写配置文件时不能丢新数组键值。
2. **Green：** 使用最小、可测试的项目相对路径分段 Glob（`*`、`?`、`**`），对树展示前的实际目录条目筛选；**直接替换**现有单独 `.git` 过滤为等价默认规则，不保留双轨。目录被隐藏时不查询其不可见子孙；切到「临时显示被排除项」后重新投影/按需加载。`AppSettings` 提供一个 `files.exclude` 字符串数组及 `SettingsView` Workspace 中简单编辑入口，遵循现有保存/观察规则，不新增存储文件或第二套设置模型。模式非法保持旧有效配置并提示；默认不隐藏其它点文件或 `node_modules`。规则变更优先重建当前已读缓存，不因一个展示设置而对 SSH 全盘遍历。
3. **覆盖：** 根／嵌套匹配、`**` 零层/多层、空和全匹配、路径中特殊字符及 Unicode、大小写敏感卷和不敏感卷、软链目录、压缩目录隐藏前后的真实末级路径、展开和选中状态、已打开隐藏文件、临时显示/恢复/不同项目、旧配置与重置、AppSettings 其它配置修改后再保存、Settings 中英文／明暗／字号、Git 颜色与菜单保持原状。核对磁盘字节与 `⌘P` 结果不变、目录排序不变。运行 `FileTreeTests`、`AppSettingsTests`、`TreeRowHitTestingTests` 和原生 Settings 验收。
4. **闭环：** `docs/features/files.md`、`settings.md`、`docs/ui.md` 当次同步；本任务实现成功时**立即删除旧硬编码过滤和其它确实重复的匹配路径**，不改 `TreeDisplayModel` 的排序。中文原子提交。

---

<a id="p3-t2"></a>
## P3-T2 扩展已有 ⌘P 快速打开到 SSH

**源码锚点：** `Bailey/Workspace/ProjectFileIndex.swift`（`load/gitProjectFilePaths/enumeratedProjectFiles`，现有结果**只有文件**，Git 中包含 tracked 与 nonignored untracked）、`Bailey/UI/CommandPaletteView.swift`（`fileIndexContext` 过滤远端、`.task(id:)`、`matchingFiles`、`indexedTarget`、50 条展示）、`Bailey/Workspace/PanelContext.swift.resolvedRoot`、`Bailey/Workspace/Project.swift.panelRoot`（CodeGraph 当前**仅有 `CommandPaletteView` 一个调用方；迁走后可删除这个同步旧入口**）、`Bailey/Remote/{SSHWorkspaceBackend,RemoteCommands}.swift`（SSH 命令与批量读取）及 `Bailey/Git/GitCommandExecution.swift.runData(...,backend:)`（**已经存在**的本机/远端 Git 调用，非新接口；远端 `stdoutLimit` 目前仅在收齐输出后截取）。

1. **Red：** 本机既有 `ProjectFileIndexTests` 断言的 Git ignored 不在 `⌘P` 搜索结果，而 Files 树本身仍能显示 ignored；这一差异**必须保留**，不能让 Files 的展示索引成为 `⌘P` 真源。验证远端同名本机路径不产生 Mac 查询；记录 `fileIndexContext` 当前直接拒绝 SSH 以及同步本机 `project.panelRoot` 不能用于远端根。补慢查询、文件删除／移动、断开及切换目标、索引在途取消，证明旧结果不会打开错文件。
2. **Green：** 扩展原有 `ProjectFileIndex` 的后端感知文件枚举入口和 `CommandPaletteView` 的异步装配：远端根从 `PanelContext.resolvedRoot()` 得到，查询经当前 `context.backend` 到远端，而不是 Mac `FileManager/GitCommandExecution`。**优先调用已存在的 `GitCommandExecution.runData(...,backend:)`** 获得本机和远端 Git 路径，不新建执行器；非 Git 项目按当前 `WorkspaceBackend.list(directories:)` 批量按需枚举。以小型受控 SSH 检验 `ls-files -z` 和 Windows/MSYS2 的真实行为与成本；注意当前 `GitCommandExecution` 对远端 `stdoutLimit` **只在 `backend.run` 已累计完整输出之后截取**，因此不能把这个参数误称为远端内存限流。只有实测证明确实需要时才在现有执行路径增加来源端输出限制或明确超限错误，不引入全局框架；结果不完整必须显式提示。`⌘P` 仍只返回文件、保留本机既有 Git 规则和匹配排名/前 50 个显示结果，Home 防误全盘扫描在本机保持，远端仅对过大的用户主目录明确拒绝扫描。任务取消先阻止 UI 发布与动作；只有在实测进程仍耗资源时才修改具体 runner 的取消机制，不承诺任意外部命令可被 `Task.cancel()` 同步杀死。
3. **覆盖：** 本机 Git/非 Git/submodule、tracked/ignored/nonignored untracked、中文和文件名含换行（NUL 安全解析）、远端 Git/非 Git、Windows MSYS2/路径空格/引号、大小写与 Unicode、0/1/大量文件、输出上限、权限/超时/断线、连接替换、A→B→A、打开已删除文件、取消后重复查询、多窗口及焦点。核对**打开的 FileTab.workspaceIdentity/path 与真实机器磁盘**，同时核对远端请求数、进程退出和内存，不以返回假列表冒充 SSH。运行 `ProjectFileIndexTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`、`PanelContextTests` 和真正 `⌘P` GUI。
4. **闭环：** 在相同任务更新 `docs/features/command-palette.md` 的「仅本机」旧不变量，以及 `docs/features/ssh.md`；从 `CommandPaletteView` 迁走后，重新核对 CodeGraph 调用者，**同一任务直接删除 `Project.panelRoot(...)` 这个同步本机专用旧入口**，同时清理 `LocalWorkspaceBackend.statSync/gitRootSync` 周边「仍由 panelRoot 使用」的过时注释；保留仍被 `LocalWorkspaceBackend.gitRoot` 使用的 `gitRootSync`，不为了清理破坏已有调用。其它确已无用途桥接也本任务删除；本机 `⌘P` 成熟排序不动。中文原子提交。

---

<a id="p3-t3"></a>
## P3-T3 Files 内名称／相对路径过滤（按需搜索）

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`items/cachedDirectories/rebuild`）、`Bailey/Files/FileTreePanel.swift.FileTreeScrollView`（`ScrollViewReader/ForEach`）、`Bailey/Shared/Tree/TreeDisplayModel.swift`（`Traversal`）、`Bailey/Workspace/WorkspaceBackend.swift`（`list(directories:)`）。

1. **Red：** 当前 `items` 只包含已读取、展开或用于压缩预读的目录，单纯对 `items.filter` 无法找到深层未展开文件；`FileTreeModel.rebuild` 调用 `Traversal(directoryDepthLimit: 32)` 也是现有树呈现的实质深度边界，不能承诺结果一定可经树展开到达。添加**被 Git 忽略但未被 Files exclude** 的文件、超过树深度限制的真实深层项、重名文件、目录名匹配、父文件夹隐藏、目录压缩链、循环软链与空目录的测试；旧主机或取消查询结果不得出现。
2. **Green：** 在现有 Files 标题附近提供简洁、可收起的过滤输入。查询非空时沿**当前后端/根**按需批量遍历，产生本次匹配路径和必要父级投影；使用同一 `FileTreeModel` 展示，不维护第二份长期全量目录缓存或与 `⌘P` 共享忽略 Git 文件的 `ProjectFileIndex`。输入节流只在真实测到每键 IO 过量时采用；当前查询取消后旧结果不可发布；SSH 扫描有成本／请求／内容上限，超限时提示结果不完整，不报告空结果。搜索结果若超过原树 32 层或遇软链循环，**可直接从真实匹配路径打开文件／定位目录，但不能假装已在树中展开**；必要时对原树的极限单独改进，并证明防循环仍成立。用户 Home 等过大根需要同样受控，不可放开全量递归。过滤清除立刻恢复原本的展开/选中与目录压缩语义，点击项仍使用实际路径；单纯搜索不应读取每个文件正文。
3. **覆盖：** 根、深层未展开、被 Git ignored／untracked／tracked、Files 排除规则及临时显示、空目录和相似前缀、同名、多项、Unicode／空格／换行、压缩链、0/多结果和超限、输入高速变化、当前目录外软链、SSH 高延迟／断开／权限拒绝、切根/切主机/两窗口、焦点／方向键／Return／Escape、浅暗中英／窄侧栏。测查询 IO、CPU、RSS 与可见行对应的**真实机器路径**，`FileTreeTests`、`PanelContextTests`、原生界面与可用 SSH 测试均需验证；无法获得的极端设备按文档逐项记录。
4. **闭环：** `docs/features/files.md`、`docs/ui.md` 同步，避免在 P4 才补过滤状态清理。若旧行过滤路径不再使用则本任务直接删掉。独立中文提交。

---

<a id="p3-t4"></a>
## P3-T4 在 Files 定位当前文件并修正机器高亮

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift.openFilePath`（当前只传 `file.path`）、`Bailey/Files/FileTreePanel.swift.FileTreeRow.isCurrent`（当前按路径字符串）、`Bailey/Workspace/Project.swift.openLocalFile`（SSH 项目可拥有本机 FileTab）、`Bailey/Editor/FileViewerView.swift.FileTab.workspaceIdentity`，`FileTreeModel.sync/toggle` 与 `FileTreeScrollView.ScrollViewReader`。

1. **Red：** 在 SSH 项目打开**路径恰与远端目录同名的本机 Finder 文件**，检测 Files 目前可能把远端行误高亮——代码路径已确认，实际 GUI 触发仍须测试；深层未展开、压缩路径、Files 隐藏/过滤、根外文件、不存在路径、在途展开时切机器需要额外回归。
2. **Green：** 先修正当前文件高亮**同时比较 `FileTab.workspaceIdentity` 与当前 Files 后端身份**，不单凭路径字符串；通过现有 `FileTreeModel` 逐级展开实际父目录并通知现有 `ScrollViewReader` 滚动到文件末级路径。被排除时可使用 P3-T1 的临时显示机制或仅临时揭示目标及祖先，选择实现更简单且可验证的一种，不为此增加独立的「定位缓存」／复杂状态机。任何路径在当前机器/根之外明确拒绝定位，不擅自切换项目或后端；保留已打开原生编辑及 Undo。菜单入口进入目前已有的当前文件/Files 操作菜单即可，不叠加按钮组。
3. **覆盖：** 本机与 SSH 同名路径、本机标签处于 SSH 项目、根内多层／压缩目录、隐藏父目录、过滤激活、普通与失效软链、超过当前 `Traversal` 32 层呈现上限的路径、项目根外、脏文本、改名后路径、并发读取和切机器、多窗口与不同 Dock 组。对确实不能在树中显示的超深文件提供可解释的不可展开结果或直接打开入口，**不能无限递归或偷偷解除防环上限**。对 `FileTabTests`、`WorkspaceIdentityTests`、`PanelContextTests`、`FileTreeTests` 及真实 GUI 核对实际滚动、高亮、目标身份与文件可访问性；不仅检查 `expanded` 集合。
4. **闭环：** `docs/features/files.md`、`editor.md`、`projects.md` 和必要的 `docs/ui.md` 与实现同次更新；**本任务替换并删除旧的仅按路径高亮分支**，确保 Git 树和 Files 单击不变。独立中文提交。

---

## Phase Audit

只有 P3 的实现、文档和真实 GUI／SSH 验收完成才生成 `audit-p3.md`。重点检查 Files 展示范围与 `⌘P` Git ignore 语义分离、SSH 查询可靠成本、Reveal 机器身份与原生编辑稳定性。
