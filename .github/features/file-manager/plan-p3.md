# P3：隐藏规则、SSH 快速打开与当前文件定位

**Goal：** 在现有 Files 中增加可配置隐藏规则、临时显示被排除文件和当前文件定位；保留已有 `⌘P` 并补齐 SSH 项目文件快速打开。

**Non-goals：** **不实现 Files 面板内搜索框、按名称或路径过滤、未展开目录递归搜索及其索引**；不实现文件排序、跨文件搜索及它的 `search.exclude`、监听器的 `files.watcherExclude`、VS Code `when`、项目级 `.vscode/settings.json`、全文搜索或新设置页面。本计划只登记后续 Exclude 的语义边界，不预建未接入的注册表或设置控件。

**Approach：** 在 `FileTreeModel.children` 用仅供 Files 展示的最小 Glob 匹配替换 `.git` 硬编码，使用现有 `AppSettings` TOML 与真实原生 Settings。[#44 Settings](../settings-by-feature/plan-p1.md) 的 File Manager 页面尚未落地，需先完成该任务；本计划不替它建立第二套分类。`⌘P` 只扩展已有 `ProjectFileIndex` 与 `PanelContext` 的远端查询；Reveal 沿已存在树展开。`search.exclude`、`files.watcherExclude` 与独立全仓索引均不在本计划创建。

**Acceptance：** 默认只隐藏 `.git`，用户按 Glob 设置可显示／隐藏，原始目录顺序与 Git 忽略状态不变；配置立刻传播到本机／SSH Files，临时查看不改持久值；`⌘P` 能准确打开远端文件；Reveal 不误定位同名异机器文件。

**Rules：** #44 先把 File Manager 页面挂入现有原生 Settings，P3-T1 再把 Exclude 控件接入它，不能回退到混合 Workspace 设置页或新建另一套 Settings；不在 Files 标题栏新增搜索输入，不因隐藏规则对整仓扫描；失效配置不覆盖上次有效规则；涉及真实文件 IO 的结果继续按已有项目和后端边界校验。

---

<a id="p3-t1"></a>
## P3-T1 Files 隐藏规则及原生设置 UI

**源码锚点：** `Bailey/Files/FileTreeModel.swift.children/rebuild`（当前唯一 `.git` 硬编码过滤）、`Bailey/Shared/Tree/TreeDisplayModel.swift.Traversal`、`Bailey/App/AppSettings.swift`（`TOML.parse/save/resetToDefaults`，当前仅识别**单行数组**）、`Bailey/App/SettingsView.swift`（#44 改造后的独立 `File Manager` 页面，当前旧代码把 Panels／Git／Text Editing 混在 `workspaceSettings`）、`Bailey/Files/FileTreePanel.swift`（现有 Files 标题栏）。

1. **Red：** `FileTreeTests` 验证 `.git` 在根／嵌套目录默认隐藏、其它点文件和 `node_modules` 默认仍显示；Glob `*`（当前目录段）、`?`（一个字符）、`**`（零层／多层目录）按**当前 Files 根**的相对路径匹配。验证 `**/.git`、`**/node_modules`、`**/*.log`、仅文件名与相对目录模式：**无斜杠模式匹配各层级的文件名，含 `/` 模式从 Files 根匹配，整段 `**` 匹配零或多级路径**；根层 `.git` 与深层 `.git` 均命中。测试前/后空格、NFD/NFC、UTF-8、前导点、根路径恰好命中、特殊符号及空模式；不支持的字符类、花括号、`when`、绝对路径/上级穿越直接报验证错误而非悄悄改变语义。命中目录后整个子树不再出现在树上。特别测试已缓存层级改变规则后**只重新投影、不为已知层级额外 list**（包括「先展开目录→设置隐藏→恢复显示」的往返）（首次显示新显现的已展开目录子层级，允许按现有懒加载补读），以及更改时旧刷新不得覆盖新规则。旧代码与新需求形成真实 Red；`AppSettingsTests` 覆盖配置初装、无效模式／类型、持久化、重置、其他设置触发保存，以及 `[]` 明确关闭所有排除规则。
2. **Green：** `AppSettings` 新增仅供 Files 显示使用的 `files.exclude` 字符串数组，**默认 `["**/.git"]`**；当前 TOML 解析器只支持单行数组，文件应由现有 `TOML.list` 写为 `files.exclude = ["**/.git", "**/node_modules"]`，显式空数组 `[]` 和缺省键必须保持不同语义，不引入多行 TOML 解析层。实现最小且可独立测试的分段 Glob 子集匹配（`*`/`?`/`**`，`**` 可匹配零级子目录），文件夹匹配后整棵子树不可见；**只让 Files 在本任务消费它**。以后搜索或 watcher 需要规则时再复用被测试过的纯匹配函数、增加各自的配置键/默认值与测试，不能将本次 `files.exclude` 扩大为跨系统隐藏总开关；在 `FileTreeModel.children` 原过滤位置**直接替换**旧 `.git` 分支，不在磁盘／SSH 后端分别过滤。通过最小设置变化观察复用**未过滤的**已读目录缓存重新投影，不额外整树扫描或重列已缓存层级；**当前 `FileTreeModel.rebuild` 末尾执行 `cachedDirectories.filter { visited.contains($0.key) }`，被 Exclude 隐藏的已读子树会从缓存中丢失；本任务需按「根/后端变化时清除，当前树只是暂时过滤时保留」修正既有缓存淘汰规则，并在重新显现时实测 list 次数**，不能靠添加第二份缓存冒充复用；只有此前未读且需要实际展示的子目录才走原来按需读取；如旧遍历仍在进行，返回时使用当前规则，不能把过时投影写回 UI。无效规则只影响设置草稿，保留上次有效配置并明确报错；不维护第二份过滤后目录缓存。
3. **设置界面：** 确认 #44 的 `SettingsPage.fileManager` 真正存在后，在该原生 `Form` 内放一处每行一个 Glob 的 `TextEditor`、应用及恢复默认；不增加新页面或通用规则管理器。当前 `AppSettings.save()` 失败只 `NSLog`，故须给 **Exclude 一次应用**增加可报告写入结果的最小原子入口：先验证全部规则与 TOML 内容，写盘成功后才更新有效设置；失败向所属 Settings 显示错误并保留旧规则。避免每输入一字就改偏好/写磁盘；`[]`（明确显示 `.git`）区别缺省（默认隐藏 `.git`）。在 `resetToDefaults` 与 Settings 的恢复默认可用性判断中加入该键，不破坏其它原有设置或手工工作区初始布局。
4. **Files 临时查看：** 在现有 Files 标题栏右侧加入一个简洁的省略号菜单，其中勾选项「显示被排除的文件」只作用于当前 Files 树/目标，不写 `config.toml`，切回关闭后恢复隐藏；`Reveal` 可临时显示被隐藏的目标及必要祖先。禁止为它另造搜索框或持久化显示状态。
5. **验证与闭环：** `FileTreeTests` 覆盖 Glob 匹配、已读缓存隐藏→恢复仅重新投影、未读目录仍按需读取；`AppSettingsTests` 验证缺省/`[]`/无效输入、保存失败不改变旧有效规则、重置和其它设置往返。宿主或隔离原生 Settings 检查应用、错误与 File Manager 页面，`WorkspaceFilesUITests` 验证实际 Files 显示/临时开关；本机/SSH、中英明暗、隐藏文件与 `⌘P`/Git 仍相互独立。同步 `files.md`、`settings.md` 和必要 `ui.md`；**在本任务删除** `FileTreeModel.children` 的硬编码 `.git`、多余独立缓存和过时设置判断，勿保留双重过滤。

---

<a id="p3-t2"></a>
## P3-T2 扩展已有 ⌘P 快速打开到 SSH

**源码锚点：** `Bailey/Workspace/ProjectFileIndex.swift`（`load/gitProjectFilePaths/enumeratedProjectFiles`，现有结果**只有文件**，Git 中包含 tracked 与 nonignored untracked）、`Bailey/UI/CommandPaletteView.swift`（`fileIndexContext` 过滤远端、`.task(id:)`、`matchingFiles`、`indexedTarget`、50 条展示）、`Bailey/Workspace/PanelContext.swift.resolvedRoot`、`Bailey/Workspace/Project.swift.panelRoot`（CodeGraph 当前**仅有 `CommandPaletteView` 一个调用方；迁走后可删除这个同步旧入口**）、`Bailey/Remote/{SSHWorkspaceBackend,RemoteCommands}.swift`（SSH 命令与批量读取）及 `Bailey/Git/GitCommandExecution.swift.runData(...,backend:)`（**已经存在**的本机/远端 Git 调用，非新接口；远端 `stdoutLimit` 目前仅在收齐输出后截取）。

1. **Red：** 本机既有 `ProjectFileIndexTests` 断言的 Git ignored 不在 `⌘P` 搜索结果，而 Files 树仍可显示 ignored；此差异**必须保留**，不要把 `files.exclude` 混入 `⌘P` 文件索引。验证远端同名本机路径不产生 Mac 查询；记录 `fileIndexContext` 当前直接拒绝 SSH 以及同步本机 `project.panelRoot` 不能用于远端根。**`ProjectFileIndex.load` 当前在 `gitProjectFilePaths` 返回 nil 时直接递归列举，无法区分「确实不是 Git 仓库」与 Git 错误；远端权限/断线/命令超时不得变成一次完整目录扫描或貌似成功的空列表。**补慢查询、文件删除／移动、断开及切换目标、索引在途取消，证明旧结果不会打开错文件。
2. **Green：** 保留 `ProjectFileIndex` 的文件结果与评分，增加一个复用 `PanelContext.backend` 的异步路径：远端根由 `PanelContext.resolvedRoot()` 获取，Git 文件继续用已存在的 `GitCommandExecution.runData(..., backend:)`（tracked + 非 ignored untracked），**只有 Git 明确报告非仓库**才退回无 Git 目录枚举；权限/连接错误不得全树回退。远端普通目录按 `WorkspaceBackend.list(directories:)` 的成功/缺失键语义批量懒遍历，不跟随目录软链越根/成环；限定内存、项数与目录扫描量，达到限制应提示结果不完整而不是静默截断。保留前 50 条展示、匹配排名、本机 Home 拒绝整扫；远端用户 Home 未经限制不整扫。当前 `GitCommandExecution.runData(...,backend:)` 的 `stdoutLimit` 在远端**收齐后**才裁剪，不能视作远端资源保护；优先在现有远端执行入口处理可证实的输出压力，拒绝半条 NUL 记录。连接变更时使旧结果不可点击，并在真正执行 `PaletteCommand.action` 时复核**项目、根、机器及当前通道**，不能只靠 `PanelContext.Identity.pinned`（没有连接 ID）或 `.task(id: identity)`；复用已有 `SSHHostWorkspaces.connectionChanged`，不造额外索引 Store、轮询或后台服务。仅在证实取消后远端进程继续消耗资源时再改 runner 取消机制。
3. **覆盖：** `ProjectFileIndexTests` 验证 Git 已跟踪/非忽略未跟踪与非仓库、失败不自动回退、NUL 安全路径（空格、换行、Unicode）、目录链接循环与扫描预算；`RemoteCommandsTests` 和授权 `SSHFileTreeLiveTests` 验证 Windows/MSYS2 Git、非仓库以及请求耗时；`PanelContextTests` 与实际 `WorkspaceFilesUITests`/`WorkspaceSmokeUITests` 检查索引在途切 A→B→A、固定 SSH 断线重连、错误/超限提示及最后打开的 FileTab 机器/path。真实无权限、慢查询、断线等条件按测试规范隔离模拟与实际验收区分，减少重复完整 App 测试。
4. **闭环：** 在相同任务更新 `docs/features/command-palette.md` 的「仅本机」旧不变量，以及 `docs/features/ssh.md`；从 `CommandPaletteView` 迁走后，重新核对 CodeGraph 调用者，**同一任务直接删除 `Project.panelRoot(...)` 这个同步本机专用旧入口**，同时清理 `LocalWorkspaceBackend.statSync/gitRootSync` 周边「仍由 panelRoot 使用」的过时注释；保留仍被 `LocalWorkspaceBackend.gitRoot` 使用的 `gitRootSync`，不为了清理破坏已有调用。其它确已无用途桥接也本任务删除；本机 `⌘P` 成熟排序不动。中文原子提交。

---

<a id="p3-t3"></a>
## P3-T3 当前文件定位与远端 Finder 入口

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift.openFilePath`（**当前已按 `selectedTab` + `workspaceIdentity` 校验**，无需重写）、`Bailey/UI/WorkspaceDockView.swift.projectTabMenu`（远端 FileTab 也暴露 `Reveal in Finder`）、`Bailey/Files/FileTreeModel.swift.sync/toggle` 和 `FileTreeScrollView.ScrollViewReader`、`Bailey/Workspace/Project.swift.openLocalFile`、`Bailey/Editor/FileViewerView.swift.FileTab.workspaceIdentity`。

1. **Red：** 先回归已有 `ToolPanelView.openFilePath` 的当前文件高亮：SSH 树与本机同名文件不混淆，切回 Files 后仍可显示 `Project.selectedTab` 对应的同机标签。**这是已实现基线，不把它误报为缺陷。** 新增 Red：工作标签菜单能在远端 FileTab 上调用 Mac `Reveal in Finder`；当前文件在树未展开、目录压缩、被 Exclude 隐藏时没有路径定位操作。测试在 Mac 碰巧存在远端同名文件时，绝不能误唤起 Mac Finder。
2. **Green：** **保留** `ToolPanelView.openFilePath` 已正确实现的 `selectedTab` 与 `workspaceIdentity` 校验，不再创建所谓高亮替代状态。只在 `WorkspaceDockView.projectTabMenu` 给 FileTab 增加「在文件管理器中显示」，并将 `Reveal in Finder` **仅限本机 FileTab**（即使本机标签置于 SSH 项目）。定位时从该标签已绑定的机器/路径进入已有 Files 树，沿真实祖先逐级展开、滚动并选中；对 `files.exclude` 隐藏项使用 P3-T1 临时显现，不写配置。目标在当前 Files 项目根外、已消失、处于另一机器或后端已断线时给出明确反馈，不自动切机器或创建第二份索引；实际延迟展示前再次核对目标/窗口是否仍有效。
3. **覆盖：** 本机/SSH 同名路径与 SSH 项目中本机 FileTab、嵌套/压缩及被排除祖先、根外或已删除项、脏缓冲、移动/更名、跨窗口/组、SSH 换通道及异步展开后切目标；当前 `Traversal` 最多 32 层压缩应明确失败，不用无限递归。`FileTabPersistenceTests`、`WorkspaceIdentityTests`、`PanelContextTests`、`FileTreeTests` 和受影响的 `WorkspaceFilesUITests`/`WorkspaceDockUITests` 核对最终行位置、菜单可用性和 Finder 副作用。
4. **闭环：** 同步 `docs/features/files.md`、`editor.md` 与必要 `projects.md`、`ui.md`。**删除的是**原来不区分机器的标签 Finder 操作以及本任务新增导航替代的重复入口；**不删除或重写**现有正确的 Files 当前文件高亮，也不触碰 Git 共享树逻辑。单独中文提交。

---

## Phase Audit

实施并完成 P3 的对应测试后才生成 `audit-p3.md`，核对 Glob 作用范围、Settings 保存和临时查看、SSH `⌘P`、Reveal 身份及编辑状态；不把 Files 面板搜索算入需求。
