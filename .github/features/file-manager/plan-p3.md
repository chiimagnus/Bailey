# P3：隐藏规则、SSH 快速打开与当前文件定位

**Goal：** 在现有 Files 中增加可配置隐藏规则、临时显示被排除文件和当前文件定位；保留已有 `⌘P` 并补齐 SSH 项目文件快速打开。

**Non-goals：** **不实现 Files 面板内搜索框、按名称或路径过滤、未展开目录递归搜索及其索引**；不实现文件排序、跨文件搜索及它的 `search.exclude`、监听器的 `files.watcherExclude`、VS Code `when`、项目级 `.vscode/settings.json`、全文搜索或新设置页面。本计划只登记后续 Exclude 的语义边界，不预建未接入的注册表或设置控件。

**Approach：** 将 `FileTreeModel.children` 中 `.git` 硬编码改为 `files.exclude` 的有限 Glob 子集（仅 `*`、`?`、`**`），只在后端原始目录缓存生成显示行时过滤，不改 `TreeDisplayModel.Traversal`、原始目录缓存及 Git UI；**不宣称完全兼容 VS Code Glob**。配置归 `AppSettings` 现有全局 TOML，UI 放 **[#44 的 Settings → File Manager 页面](../settings-by-feature/plan-p1.md)**（按功能分类）；Files 面板只需临时显示开关。`search.exclude` 未来归跨文件搜索，`files.watcherExclude` 未来归 #40 的实际事件监听；各自拥有独立设置键和消费者，可复用经过实际验证的分段 Glob 匹配，但当前不引入通用规则注册框架。SSH `⌘P` 沿原 `ProjectFileIndex` 扩展；Reveal 沿已有文件树逐级展开，不另建索引。

**Acceptance：** 默认只隐藏 `.git`，用户按 Glob 设置可显示／隐藏，原始目录顺序与 Git 忽略状态不变；配置立刻传播到本机／SSH Files，临时查看不改持久值；`⌘P` 能准确打开远端文件；Reveal 不误定位同名异机器文件。

**Rules：** #44 先把 File Manager 页面挂入现有原生 Settings，P3-T1 再把 Exclude 控件接入它，不能回退到混合 Workspace 设置页或新建另一套 Settings；不在 Files 标题栏新增搜索输入，不因隐藏规则对整仓扫描；失效配置不覆盖上次有效规则；涉及真实文件 IO 的结果继续按已有项目和后端边界校验。

---

<a id="p3-t1"></a>
## P3-T1 Files 隐藏规则及原生设置 UI

**源码锚点：** `Bailey/Files/FileTreeModel.swift.children/rebuild`（当前唯一 `.git` 硬编码过滤）、`Bailey/Shared/Tree/TreeDisplayModel.swift.Traversal`、`Bailey/App/AppSettings.swift`（`TOML.parse/save/resetToDefaults`，当前仅识别**单行数组**）、`Bailey/App/SettingsView.swift`（#44 改造后的独立 `File Manager` 页面，当前旧代码把 Panels／Git／Text Editing 混在 `workspaceSettings`）、`Bailey/Files/FileTreePanel.swift`（现有 Files 标题栏）。

1. **Red：** `FileTreeTests` 验证 `.git` 在根／嵌套目录默认隐藏、其它点文件和 `node_modules` 默认仍显示；Glob `*`（当前目录段）、`?`（一个字符）、`**`（零层／多层目录）按**当前 Files 根**的相对路径匹配。验证 `**/.git`、`**/node_modules`、`**/*.log`、仅文件名与相对目录模式：**无斜杠模式匹配各层级的文件名，含 `/` 模式从 Files 根匹配，整段 `**` 匹配零或多级路径**；根层 `.git` 与深层 `.git` 均命中。测试前/后空格、NFD/NFC、UTF-8、前导点、根路径恰好命中、特殊符号及空模式；不支持的字符类、花括号、`when`、绝对路径/上级穿越直接报验证错误而非悄悄改变语义。命中目录后整个子树不再出现在树上。特别测试已缓存层级改变规则后**只重新投影、不为已知层级额外 list**（包括「先展开目录→设置隐藏→恢复显示」的往返）（首次显示新显现的已展开目录子层级，允许按现有懒加载补读），以及更改时旧刷新不得覆盖新规则。旧代码与新需求形成真实 Red；`AppSettingsTests` 覆盖配置初装、无效模式／类型、持久化、重置、其他设置触发保存，以及 `[]` 明确关闭所有排除规则。
2. **Green：** `AppSettings` 新增仅供 Files 显示使用的 `files.exclude` 字符串数组，**默认 `["**/.git"]`**；当前 TOML 解析器只支持单行数组，文件应由现有 `TOML.list` 写为 `files.exclude = ["**/.git", "**/node_modules"]`，显式空数组 `[]` 和缺省键必须保持不同语义，不引入多行 TOML 解析层。实现最小且可独立测试的分段 Glob 子集匹配（`*`/`?`/`**`，`**` 可匹配零级子目录），文件夹匹配后整棵子树不可见；**只让 Files 在本任务消费它**。以后搜索或 watcher 需要规则时再复用被测试过的纯匹配函数、增加各自的配置键/默认值与测试，不能将本次 `files.exclude` 扩大为跨系统隐藏总开关；在 `FileTreeModel.children` 原过滤位置**直接替换**旧 `.git` 分支，不在磁盘／SSH 后端分别过滤。通过最小设置变化观察复用**未过滤的**已读目录缓存重新投影，不额外整树扫描或重列已缓存层级；**当前 `FileTreeModel.rebuild` 末尾执行 `cachedDirectories.filter { visited.contains($0.key) }`，被 Exclude 隐藏的已读子树会从缓存中丢失；本任务需按「根/后端变化时清除，当前树只是暂时过滤时保留」修正既有缓存淘汰规则，并在重新显现时实测 list 次数**，不能靠添加第二份缓存冒充复用；只有此前未读且需要实际展示的子目录才走原来按需读取；如旧遍历仍在进行，返回时使用当前规则，不能把过时投影写回 UI。无效规则只影响设置草稿，保留上次有效配置并明确报错；不维护第二份过滤后目录缓存。
3. **设置界面：** 先核实 [#44](https://github.com/chiimagnus/Bailey/issues/44) 已建立功能分类的独立 **Settings → File Manager** 页面；本任务直接在其原生 `Form` 增加 `Excluded Items` 区块，**不回填 Workspace 页面，也不重新实现 Settings 导航**：一个 SwiftUI `TextEditor`，**每行一条 Glob**，配简短示例、明确说明**目前只支持 `*`/`?`/`**`，不是 VS Code 全部 Glob 语法**，以及**应用**和**恢复默认**按钮。输入仅为临时草稿，点击应用且全部校验通过才一次写入 `AppSettings`，避免每次按键重写配置；**当前 `AppSettings.save()` 遇到磁盘写入失败只调用 `NSLog` 并吞下错误，不能凭设置赋值成功就向用户报告持久化成功。** 在本任务给这一次 Exclude 应用提供最小的写入成败回传；失败必须显示具体错误并保留旧有效设置，不新造全局配置存储器。全局规则对本机和所有 SSH 项目一致生效，暂不增加逐项目配置或开关。现有 `Reset to Defaults`／`hasCustomizedPreferences` 也须包含该选项。
4. **Files 临时查看：** 在现有 Files 标题栏右侧加入一个简洁的省略号菜单，其中勾选项「显示被排除的文件」只作用于当前 Files 树/目标，不写 `config.toml`，切回关闭后恢复隐藏；`Reveal` 可临时显示被隐藏的目标及必要祖先。禁止为它另造搜索框或持久化显示状态。
5. **验证与闭环：** 实测根／嵌套/压缩目录、空规则和删除默认 `.git`、符号链接与循环、Unicode／大小写差异、规则更改期间 Files 打开、多个项目/窗口、本机/SSH、离线及重连、隐藏的当前打开文件／Git status／`⌘P` 结果不变；尤其断言 File Manager 的规则**不会**改变 `⌘P`、Git 或 #40 watcher 的数据集合。设置 UI 验证 #44 的 File Manager 页面确实为唯一入口、其它类别设置不丢失；中英/浅暗/窄 Settings 和键盘辅助功能。跑 `FileTreeTests`、`AppSettingsTests`、`TreeRowHitTestingTests`、原生 Settings／Files GUI；核对磁盘配置字节、只读/无权限写入失败时 UI 错误且旧规则仍生效，以及已缓存目录没有不必要的 SSH 遍历。更新 `docs/features/files.md`、`settings.md`、`docs/ui.md`；同任务删除已替代的 `.git` 硬编码和多余配置路径，独立中文提交。

---

<a id="p3-t2"></a>
## P3-T2 扩展已有 ⌘P 快速打开到 SSH

**源码锚点：** `Bailey/Workspace/ProjectFileIndex.swift`（`load/gitProjectFilePaths/enumeratedProjectFiles`，现有结果**只有文件**，Git 中包含 tracked 与 nonignored untracked）、`Bailey/UI/CommandPaletteView.swift`（`fileIndexContext` 过滤远端、`.task(id:)`、`matchingFiles`、`indexedTarget`、50 条展示）、`Bailey/Workspace/PanelContext.swift.resolvedRoot`、`Bailey/Workspace/Project.swift.panelRoot`（CodeGraph 当前**仅有 `CommandPaletteView` 一个调用方；迁走后可删除这个同步旧入口**）、`Bailey/Remote/{SSHWorkspaceBackend,RemoteCommands}.swift`（SSH 命令与批量读取）及 `Bailey/Git/GitCommandExecution.swift.runData(...,backend:)`（**已经存在**的本机/远端 Git 调用，非新接口；远端 `stdoutLimit` 目前仅在收齐输出后截取）。

1. **Red：** 本机既有 `ProjectFileIndexTests` 断言的 Git ignored 不在 `⌘P` 搜索结果，而 Files 树仍可显示 ignored；此差异**必须保留**，不要把 `files.exclude` 混入 `⌘P` 文件索引。验证远端同名本机路径不产生 Mac 查询；记录 `fileIndexContext` 当前直接拒绝 SSH 以及同步本机 `project.panelRoot` 不能用于远端根。**`ProjectFileIndex.load` 当前在 `gitProjectFilePaths` 返回 nil 时直接递归列举，无法区分「确实不是 Git 仓库」与 Git 错误；远端权限/断线/命令超时不得变成一次完整目录扫描或貌似成功的空列表。**补慢查询、文件删除／移动、断开及切换目标、索引在途取消，证明旧结果不会打开错文件。
2. **Green：** 扩展原有 `ProjectFileIndex` 的后端感知文件枚举入口和 `CommandPaletteView` 的异步装配：远端根从 `PanelContext.resolvedRoot()` 得到，查询经当前 `context.backend` 到远端，而不是 Mac `FileManager/GitCommandExecution`。**优先调用已存在的 `GitCommandExecution.runData(...,backend:)`** 获得本机和远端 Git 路径，不新建执行器；**只在已验证不是 Git 仓库时**走原来的非 Git 文件枚举语义：远端按现有 `WorkspaceBackend.list(directories:)` 批量读取并检查缺失目录键（它表示读取失败，不是空目录）；Git 报错/SSH 失联应显示可重试错误，不能假称目录可遍历。远端非 Git 遍历仅索引文件、避免沿目录软链无限环和越根遍历，以现有条目的 `isSymlink`/路径以及明确的文件数、深度和输出预算控制真实成本；超过上限报告结果不完整，不制造新递归索引框架。以小型受控 SSH 检验 `ls-files -z` 和 Windows/MSYS2 的真实行为与成本；注意当前 `GitCommandExecution` 对远端 `stdoutLimit` **只在 `backend.run` 已累计完整输出之后截取**，因此不能把这个参数误称为远端内存限流。只有实测证明确实需要时才在现有执行路径增加来源端输出限制或明确超限错误，不引入全局框架；结果不完整必须显式提示。`⌘P` 仍只返回文件、保留本机既有 Git 规则和匹配排名/前 50 个显示结果，Home 防误全盘扫描在本机保持；远端的用户主目录不得未经界定直接全量枚举。**索引输入必须是真正完整的 NUL 分隔路径记录；截断不能拼出伪路径或将未完全扫描显示为完整结果**。**固定 SSH 项目的 `PanelContext.Identity.pinned` 不含连接 ID，且 `SSHHostWorkspaces.backend(for:)` 会复用后端实例**：本次不能仅以 `.task(id: identity)` 判断索引是否仍有效；复用现有 `SSHHostWorkspaces.connectionChanged`/活动目标变化触发失效与重读，断线期间不保留可点击的旧结果，重连恢复再核对真实磁盘。必须把当前索引所属目标/连接有效性一起检查到实际 `PaletteCommand.action` 打开时，避免任务 A 的闭包在 A→B→A 或断线后以旧结果操作目标。任务取消先阻止 UI 发布与动作；只有在实测进程仍耗资源时才修改具体 runner 的取消机制，不承诺任意外部命令可被 `Task.cancel()` 同步杀死。
3. **覆盖：** 本机 Git/非 Git/submodule、tracked/ignored/nonignored untracked、未提交的 Git 仓库、Git 不可用/失败、普通目录、空根、中文及换行/Tab/首尾空格路径（NUL 安全解析）、macOS 的 NFC/NFD（受控临时夹具已验证 Git 可返回规范化的名称，但文件系统仍可定位原路径）、SSH Linux/Windows MSYS2 的 Git 与非 Git、远端目录软链/环/越根、0/1/100/10,000+ 文件、路径长度、上限前后和不完整 NUL 记录、权限/输出过长/超时/断线、固定 SSH **同一 identity+backend** 下先断后连、自动 SSH 连接替换、A→B→A、索引结束后目标文件被删除/移动、索引取消后继续输入、两个窗口及实际焦点。核对**打开的 FileTab.workspaceIdentity/path 与真实机器磁盘**，同时核对远端请求数、进程退出和内存，不以返回假列表冒充 SSH。运行 `ProjectFileIndexTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`、`PanelContextTests` 和真正 `⌘P` GUI。
4. **闭环：** 在相同任务更新 `docs/features/command-palette.md` 的「仅本机」旧不变量，以及 `docs/features/ssh.md`；从 `CommandPaletteView` 迁走后，重新核对 CodeGraph 调用者，**同一任务直接删除 `Project.panelRoot(...)` 这个同步本机专用旧入口**，同时清理 `LocalWorkspaceBackend.statSync/gitRootSync` 周边「仍由 panelRoot 使用」的过时注释；保留仍被 `LocalWorkspaceBackend.gitRoot` 使用的 `gitRootSync`，不为了清理破坏已有调用。其它确已无用途桥接也本任务删除；本机 `⌘P` 成熟排序不动。中文原子提交。

---

<a id="p3-t3"></a>
## P3-T3 在 Files 定位当前文件并修正机器高亮

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift.openFilePath`（当前依赖 `Project.focusedContent`；#13 修正真实焦点后，在 Files 获得焦点时其值将变成 nil）、`Bailey/UI/WorkspaceDockView.swift.projectTabMenu`（**所有 FileTab 不论本机/SSH 都有 `Reveal in Finder`，当前直接将远端路径传给 Mac**）、`Bailey/Files/FileTreePanel.swift.FileTreeRow.isCurrent`（当前只按路径字符串）、`Bailey/Workspace/Project.swift.openLocalFile`（SSH 项目中可能存在本机文件标签）、`Bailey/Editor/FileViewerView.swift.FileTab.workspaceIdentity`、`FileTreeModel.sync/toggle` 与 `FileTreeScrollView.ScrollViewReader`。

1. **Red：** 实测 SSH 项目中打开与远端树同名的本机文件，确认仅按路径高亮的风险；再测试编辑器→Files 焦点切换：**#13 让 `focusedContent` 正确指向实际工作焦点时，旧 `ToolPanelView.openFilePath` 会在 Files 自己聚焦后丢失当前文件高亮**。新增「在文件管理器中显示当前文件」：目录未展开／被压缩、目录被 `files.exclude` 排除、根外文件、文件已消失、SSH 切换、滚动在途切项目与连接的结果测试；**还要证明 SSH FileTab 的现有右键 `Reveal in Finder` 会错误地走本机 `NSWorkspace`，并测试同一路径恰好在本机存在的情况**；**不新增 Files 内搜索或过滤态测试**。
2. **Green：** 「当前工作文件高亮」改从**最近被选中的工作标签**（如 `Project.selectedTab?.content` 为 file 时）取得，而非菜单操作所用 `focusedContent`；Files 自身获焦点不会清空该信息，最近工作标签不是文件时不高亮。联合比对 `FileTab.workspaceIdentity`、当前 Files 的机器/连接及路径。Reveal 使用现有文件树后端沿祖先逐级展开、滚动到真实末级行；目标或祖先被隐藏时复用 P3-T1 的临时显示能力，不更改持久设置。根外/异机器不可定位，原生编辑器缓冲和 Undo 不变；不新建目录索引、独立定位缓存或复杂状态机。**在现有 FileTab 右键菜单 `projectTabMenu` 加入「在文件管理器中显示」，复用此处 FileTab 的 `workspaceIdentity` 判定后端，`Reveal in Finder` 只对本机 FileTab 出现**（哪怕它位于 SSH 项目，也仍是本机文件），远端 FileTab 绝不向 NSWorkspace 交 Mac URL；失败应在原窗口提示，不额外创建工具栏按钮/定位缓存。
3. **覆盖：** 本机/SSH 同路径与在 SSH 项目打开本机文件、**本机确有与 SSH FileTab 完全同名的磁盘文件、不同机器同名文件的 Finder 菜单可用性及点击副作用**、目录压缩、隐藏祖先、含软链/Unicode/大小写的路径、当前 `Traversal` 32 层呈现限制、根外或已删除文件、脏文本、移动与重命名、多个 Dock 组/窗口、断开/重连、在途读取切目标。对真实不可展开的超深路径明确提示或保留直接打开，不无限递归；`FileTabTests`、`WorkspaceIdentityTests`、`PanelContextTests`、`FileTreeTests` 与原生 GUI 同时检查真实滚动、路径及身份。
4. **闭环：** 更新 `docs/features/files.md`、`editor.md`、`projects.md`、必要 `docs/ui.md`；本任务直接替换和删除旧的「仅按路径高亮」逻辑，保留 Git 树和 Files 打开行为；独立中文提交。

---

## Phase Audit

实施并完成 P3 的对应测试后才生成 `audit-p3.md`，核对 Glob 作用范围、Settings 保存和临时查看、SSH `⌘P`、Reveal 身份及编辑状态；不把 Files 面板搜索算入需求。
