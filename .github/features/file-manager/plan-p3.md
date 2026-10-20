# P3：隐藏规则、SSH 快速打开与当前文件定位

**Goal：** 在现有 Files 中增加可配置隐藏规则、临时显示被排除文件和当前文件定位；保留已有 `⌘P` 并补齐 SSH 项目文件快速打开。

**Non-goals：** **不实现 Files 面板内搜索框、按名称或路径过滤、未展开目录递归搜索及其索引**；不实现文件排序、`search.exclude`、VS Code `when`、项目级 `.vscode/settings.json`、全文搜索或新设置页面。

**Approach：** 替换 `FileTreeModel.children` 现有的 `.git` 硬编码过滤为 `files.exclude` Glob 匹配；仅在树行投影前过滤，不改变 `TreeDisplayModel.Traversal`、现有惰性目录缓存及 Git UI。配置归 `AppSettings` 现有全局 TOML，UI 放 `SettingsView.workspaceSettings` 的「文件」分区；Files 面板只需临时显示开关。SSH `⌘P` 沿原 `ProjectFileIndex` 扩展；Reveal 沿已有文件树逐级展开，不另建索引。

**Acceptance：** 默认只隐藏 `.git`，用户按 Glob 设置可显示／隐藏，原始目录顺序与 Git 忽略状态不变；配置立刻传播到本机／SSH Files，临时查看不改持久值；`⌘P` 能准确打开远端文件；Reveal 不误定位同名异机器文件。

**Rules：** 不在 Files 标题栏新增搜索输入，不因隐藏规则对整仓扫描；失效配置不覆盖上次有效规则；涉及真实文件 IO 的结果继续按已有项目和后端边界校验。

---

<a id="p3-t1"></a>
## P3-T1 Files 隐藏规则及原生设置 UI

**源码锚点：** `Bailey/Files/FileTreeModel.swift.children/rebuild`（当前唯一 `.git` 硬编码过滤）、`Bailey/Shared/Tree/TreeDisplayModel.swift.Traversal`、`Bailey/App/AppSettings.swift`（`TOML.parse/save/resetToDefaults`，当前仅识别**单行数组**）、`Bailey/App/SettingsView.swift.workspaceSettings`（已有 Panels／Git／Text Editing Sections）、`Bailey/Files/FileTreePanel.swift`（现有 Files 标题栏）。

1. **Red：** `FileTreeTests` 验证 `.git` 在根／嵌套目录默认隐藏、其它点文件和 `node_modules` 默认仍显示；Glob `*`（当前目录段）、`?`（一个字符）、`**`（零层／多层目录）按**当前 Files 根**的相对路径匹配。验证 `**/.git`、`**/node_modules`、`**/*.log`、仅文件名与相对目录模式；命中目录后整个子树不再出现在树上。旧代码与新需求形成真实 Red；`AppSettingsTests` 覆盖配置初装、无效模式／类型、持久化、重置、其他设置触发保存，以及 `[]` 明确关闭所有排除规则。
2. **Green：** `AppSettings` 新增唯一 `files.exclude` 字符串数组，**默认 `["**/.git"]`**；当前 TOML 解析器只支持单行数组，文件应由现有 `TOML.list` 写为 `files.exclude = ["**/.git", "**/node_modules"]`，不要引入多行 TOML 解析层。实现最小分段 Glob 匹配，`**` 可匹配零级子目录，文件夹匹配后整棵子树不可见；在 `FileTreeModel.children` 原过滤位置**直接替换**旧 `.git` 分支，不在磁盘／SSH 后端分别过滤。改变规则时复用已读目录缓存重建显示，不增加扫描；规则无效时保留上次有效配置和明确报错。
3. **设置界面：** **不新建左侧设置页面**。在 `Settings → Workspace` 已有原生 `Form` 中增加 `Files / Excluded Items` 分区：一个 SwiftUI `TextEditor`，**每行一条 Glob**，配简短示例、**应用**和**恢复默认**按钮。输入仅为临时草稿，点击应用且全部校验通过才一次写入 `AppSettings`，避免每次按键重写配置；错误直接在编辑区下面说明、不影响此前有效规则。全局规则对本机和所有 SSH 项目一致生效，暂不增加逐项目配置或开关。现有 `Reset to Defaults`／`hasCustomizedPreferences` 也须包含该选项。
4. **Files 临时查看：** 在现有 Files 标题栏右侧加入一个简洁的省略号菜单，其中勾选项「显示被排除的文件」只作用于当前 Files 树/目标，不写 `config.toml`，切回关闭后恢复隐藏；`Reveal` 可临时显示被隐藏的目标及必要祖先。禁止为它另造搜索框或持久化显示状态。
5. **验证与闭环：** 实测根／嵌套/压缩目录、空规则和删除默认 `.git`、符号链接与循环、Unicode／大小写差异、规则更改期间 Files 打开、多个项目/窗口、本机/SSH、离线及重连、隐藏的当前打开文件／Git status／`⌘P` 结果不变；中英/浅暗/窄 Settings 和键盘辅助功能。跑 `FileTreeTests`、`AppSettingsTests`、`TreeRowHitTestingTests`、原生 Settings／Files GUI；核对磁盘内容及无新增 SSH 遍历。更新 `docs/features/files.md`、`settings.md`、`docs/ui.md`；同任务删除已替代的 `.git` 硬编码和多余配置路径，独立中文提交。

---

<a id="p3-t2"></a>
## P3-T2 扩展已有 ⌘P 快速打开到 SSH

**源码锚点：** `Bailey/Workspace/ProjectFileIndex.swift`（`load/gitProjectFilePaths/enumeratedProjectFiles`，现有结果**只有文件**，Git 中包含 tracked 与 nonignored untracked）、`Bailey/UI/CommandPaletteView.swift`（`fileIndexContext` 过滤远端、`.task(id:)`、`matchingFiles`、`indexedTarget`、50 条展示）、`Bailey/Workspace/PanelContext.swift.resolvedRoot`、`Bailey/Workspace/Project.swift.panelRoot`（CodeGraph 当前**仅有 `CommandPaletteView` 一个调用方；迁走后可删除这个同步旧入口**）、`Bailey/Remote/{SSHWorkspaceBackend,RemoteCommands}.swift`（SSH 命令与批量读取）及 `Bailey/Git/GitCommandExecution.swift.runData(...,backend:)`（**已经存在**的本机/远端 Git 调用，非新接口；远端 `stdoutLimit` 目前仅在收齐输出后截取）。

1. **Red：** 本机既有 `ProjectFileIndexTests` 断言的 Git ignored 不在 `⌘P` 搜索结果，而 Files 树仍可显示 ignored；此差异**必须保留**，不要把 `files.exclude` 混入 `⌘P` 文件索引。验证远端同名本机路径不产生 Mac 查询；记录 `fileIndexContext` 当前直接拒绝 SSH 以及同步本机 `project.panelRoot` 不能用于远端根。补慢查询、文件删除／移动、断开及切换目标、索引在途取消，证明旧结果不会打开错文件。
2. **Green：** 扩展原有 `ProjectFileIndex` 的后端感知文件枚举入口和 `CommandPaletteView` 的异步装配：远端根从 `PanelContext.resolvedRoot()` 得到，查询经当前 `context.backend` 到远端，而不是 Mac `FileManager/GitCommandExecution`。**优先调用已存在的 `GitCommandExecution.runData(...,backend:)`** 获得本机和远端 Git 路径，不新建执行器；非 Git 项目按当前 `WorkspaceBackend.list(directories:)` 批量按需枚举。以小型受控 SSH 检验 `ls-files -z` 和 Windows/MSYS2 的真实行为与成本；注意当前 `GitCommandExecution` 对远端 `stdoutLimit` **只在 `backend.run` 已累计完整输出之后截取**，因此不能把这个参数误称为远端内存限流。只有实测证明确实需要时才在现有执行路径增加来源端输出限制或明确超限错误，不引入全局框架；结果不完整必须显式提示。`⌘P` 仍只返回文件、保留本机既有 Git 规则和匹配排名/前 50 个显示结果，Home 防误全盘扫描在本机保持，远端仅对过大的用户主目录明确拒绝扫描。任务取消先阻止 UI 发布与动作；只有在实测进程仍耗资源时才修改具体 runner 的取消机制，不承诺任意外部命令可被 `Task.cancel()` 同步杀死。
3. **覆盖：** 本机 Git/非 Git/submodule、tracked/ignored/nonignored untracked、中文和文件名含换行（NUL 安全解析）、远端 Git/非 Git、Windows MSYS2/路径空格/引号、大小写与 Unicode、0/1/大量文件、输出上限、权限/超时/断线、连接替换、A→B→A、打开已删除文件、取消后重复查询、多窗口及焦点。核对**打开的 FileTab.workspaceIdentity/path 与真实机器磁盘**，同时核对远端请求数、进程退出和内存，不以返回假列表冒充 SSH。运行 `ProjectFileIndexTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`、`PanelContextTests` 和真正 `⌘P` GUI。
4. **闭环：** 在相同任务更新 `docs/features/command-palette.md` 的「仅本机」旧不变量，以及 `docs/features/ssh.md`；从 `CommandPaletteView` 迁走后，重新核对 CodeGraph 调用者，**同一任务直接删除 `Project.panelRoot(...)` 这个同步本机专用旧入口**，同时清理 `LocalWorkspaceBackend.statSync/gitRootSync` 周边「仍由 panelRoot 使用」的过时注释；保留仍被 `LocalWorkspaceBackend.gitRoot` 使用的 `gitRootSync`，不为了清理破坏已有调用。其它确已无用途桥接也本任务删除；本机 `⌘P` 成熟排序不动。中文原子提交。

---

<a id="p3-t3"></a>
## P3-T3 在 Files 定位当前文件并修正机器高亮

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift.openFilePath`（当前只传 `file.path`）、`Bailey/Files/FileTreePanel.swift.FileTreeRow.isCurrent`（当前只按路径字符串）、`Bailey/Workspace/Project.swift.openLocalFile`（SSH 项目中可能存在本机文件标签）、`Bailey/Editor/FileViewerView.swift.FileTab.workspaceIdentity`、`FileTreeModel.sync/toggle` 与 `FileTreeScrollView.ScrollViewReader`。

1. **Red：** 实测 SSH 项目中打开与远端树同名的本机文件，确认仅按路径高亮的风险。新增「在文件管理器中显示当前文件」：目录未展开／被压缩、目录被 `files.exclude` 排除、根外文件、文件已消失、SSH 切换、滚动在途切项目与连接的结果测试；**不新增 Files 内搜索或过滤态测试**。
2. **Green：** 当前文件高亮先联合比对 `FileTab.workspaceIdentity`、当前 Files 机器及路径。Reveal 使用现有文件树后端沿祖先逐级展开、滚动到真实末级行；目标或祖先被隐藏时复用 P3-T1 的临时显示能力，不更改持久设置。根外/异机器不可定位，原生编辑器缓冲和 Undo 不变；不新建目录索引、独立定位缓存或复杂状态机。现有文件菜单中提供入口，不堆叠额外工具栏按钮。
3. **覆盖：** 本机/SSH 同路径与在 SSH 项目打开本机文件、目录压缩、隐藏祖先、含软链/Unicode/大小写的路径、当前 `Traversal` 32 层呈现限制、根外或已删除文件、脏文本、移动与重命名、多个 Dock 组/窗口、断开/重连、在途读取切目标。对真实不可展开的超深路径明确提示或保留直接打开，不无限递归；`FileTabTests`、`WorkspaceIdentityTests`、`PanelContextTests`、`FileTreeTests` 与原生 GUI 同时检查真实滚动、路径及身份。
4. **闭环：** 更新 `docs/features/files.md`、`editor.md`、`projects.md`、必要 `docs/ui.md`；本任务直接替换和删除旧的「仅按路径高亮」逻辑，保留 Git 树和 Files 打开行为；独立中文提交。

---

## Phase Audit

实施并完成 P3 的对应测试后才生成 `audit-p3.md`，核对 Glob 作用范围、Settings 保存和临时查看、SSH `⌘P`、Reveal 身份及编辑状态；不把 Files 面板搜索算入需求。
