# P3：Files 隐藏规则、搜索与定位

**Goal：** 用最少的原生 UI 实现 Files 的可配置隐藏规则、树内名称／路径过滤、定位当前文件，以及共享索引支持 SSH 的 `⌘P` 搜索。

**Non-goals：** 不增加排序设置、不改变 Git ignore 语义、不引入第二个命令面板、不复制本机索引到 SSH 后端、不支持完整 VS Code 配置语法（例如 `when` 条件映射与 `search.exclude`），不默认扫描整个用户 Home。

**Approach：** Files 可见性规则归现有模型／配置所有者，不修改通用 `TreeDisplayModel.Traversal` 的默认排序及 Git 树语义；现有 `ProjectFileIndex` 扩展为后端感知、可取消、有界的共享索引路径，`CommandPaletteView` 继续做唯一模糊搜索 UI。Files 内联过滤复用同一索引并由现有树展示路径，单文件 Reveal 使用 `FileTreeModel` 自身的目录逐级展开和 `ScrollViewReader` 滚动。

**Acceptance：** 默认 Files 外观与当前实现一致；隐藏规则仅改变显示；过滤能找到未展开的文件和目录；SSH `⌘P` 不查询 Mac 同名路径；Reveal 定位到正确机器的当前文件（必要时短暂越过过滤和隐藏），不丢失用户选择或未保存编辑。

**Rules：** 模式匹配与路径身份分别处理；隐藏只是 UI 投影、永不删除真实目录项；搜索路径和文件操作无本机/远端串接；程序查询全部在可取消的有界任务中进行；配置不改变其他偏好项或已保存工作区。

---

<a id="p3-t1"></a>
## P3-T1 Files 全局隐藏规则、临时显示与持久化设置

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`children` 过滤 `.git`、`cachedDirectories`、`rebuild`）、`Bailey/Shared/Tree/TreeDisplayModel.swift`（`Traversal.receive` 压缩与 `enqueue` 固有顺序）、`Bailey/App/AppSettings.swift`（`TOML.parse`、`save`、`resetToDefaults`）、`Bailey/App/SettingsView.swift.workspaceSettings`；`Bailey/Git/GitStatusModel.swift` 只需回归验证不受影响。

1. **Red：** 在 `FileTreeTests` 创建受控结构：根和嵌套 `.git`、`.DS_Store`、`node_modules`、被排除目录中的文件、未命中相似前缀目录、空目录／压缩单子目录链、普通点文件及大小写／Unicode 变体。断言默认只隐藏 `.git`（与目前一致），配置规则如 `**/node_modules`、`**/*.log`、`src/**/generated?` 只影响相应 Files 行和子树；显示被排除项后应能看见底层条目而不改变磁盘；配置非法不静默导致所有文件消失。`AppSettingsTests` 覆盖初装／旧配置迁移、配置往返与保存其他设置时不抹去规则。
2. **Green：** 对现有 `FileTreeModel` 的**展示入口**增加可复用的项目相对 Glob 匹配（`*` 同目录，`**` 多级，`?` 单字符），与现有隐藏 `.git` 的默认等效规则统一；只过滤列表呈现，不修改 `WorkspaceBackend.list` 返回值及 Git 状态。文件夹隐藏同时隐藏子树，单子目录压缩基于过滤后的孩子；保留共享 `Traversal` 原有固定顺序，不添加排序配置。通过 `AppSettings` 的 TOML 字符串数组和 `SettingsView` 的 Workspace/Files 原生简洁编辑配置，附输入错误反馈／重置；仅 Files 临时开关显示已排除项目并在目标切换后明确复位；规则变更时重新投影已有缓存而非全量 SSH 扫描。
3. **验证：** 空、仅一个匹配、全部匹配、深／广目录、无效 Glob、双星号在根和多层、大小写敏感／不敏感卷、Unicode、隐藏父目录中打开文件、隐藏路径的 Git 状态和快捷菜单、刷新后展开状态、应用关闭重开与 Reset、改系统字号／语言／主题触发 AppSettings.save、不同项目／SSH 多窗口配置传播。断言真实文件均存在、Git Graph 与 `⌘P` 原本索引范围保持、原生 Files 展示顺序不变，`git status` 未因规则而变化。执行 `AppSettingsTests`、`FileTreeTests`、`TreeRowHitTestingTests` 和 Settings 原生 UI，压缩目录、Git 树一同回归。
4. **文档与完成：** 同步 `docs/features/files.md`（隐藏与临时显示）、`docs/features/settings.md`（`files.exclude` 配置／默认值／作用范围）、`docs/ui.md`（开关和交互）；不修改 `docs/features/git.md` 的忽略规则。删除原来单独过滤 `.git` 的重复分支，独立中文提交。

---

<a id="p3-t2"></a>
## P3-T2 本机与 SSH 共用可取消、有界文件／目录索引

**源码锚点：** `Bailey/Workspace/ProjectFileIndex.swift`（`load`、`gitProjectFilePaths`、`enumeratedProjectFiles`）、`Bailey/UI/CommandPaletteView.swift`（`fileIndexContext` 的 `!context.isRemote`、`task(id:)`、`indexedTarget`、`matchingFiles`、`FuzzyMatcher`、`maxFileResults`）、`Bailey/Workspace/PanelContext.swift`（`resolvedRoot`）、`Bailey/Workspace/WorkspaceBackend.swift`（`list(directories:)`、`run`）、`Bailey/Remote/SSHWorkspaceBackend.swift`（批量列表、现有 Shell runner）。

1. **Red：** 用同名本机路径和 Windows SSH 临时项目实测：旧版 `⌘P` 只有本机文件，没有远端结果；本机 Git 索引会读 tracked 与 nonignored untracked，普通目录跳过 `.git`。新增取消／容量／失效用例：大 Git／非 Git 目录、空目录与空子目录、索引开始后切主机／工作树／连接、查询清空再输入、关闭面板、在途查询结束于新项目、CLI 移动／增加文件、SSH 断线和慢命令。确保“取消”真实中止可控生产 IO，不能只挡住 UI 发布。
2. **Green：** 扩展**现有** `ProjectFileIndex` 使用当前 `PanelContext.backend` + `resolvedRoot`，共享本机／远端规范相对路径以及文件、目录信息（Files 过滤要包含未展开／空目录，`⌘P` 仍只返回文件），以有界批量遍历或经测量确认的单次远端 Git 查询避免 SSH 每目录串行往返。先确认远端 `runner.run` 的等待和输出累积行为，再选无需远端常驻服务的做法；严格限制最大枚举项数、输出内存和执行时长，达到上限时**明确反馈结果不完整**而不是假称零匹配。取消由当前面板／项目持有，切根与连接后旧数据不再显示、不可打开；不能把 SSH POSIX 路径交给本机 FileManager。保留 `⌘P` 现有混排、排序/匹配逻辑、50 条文件展示上限及 Home 防误全盘索引；不要因引入目录而让快捷打开返回目录标签。
3. **验证：** Git／非 Git、submodule、tracked／untracked／ignored、普通目录内空文件夹、重名文件与相对路径、超过阈值／内存／超时、缓慢和并发 SSH、实际授权 Windows MSYS2 POSIX 路径、空格／换行／中文／NFC-NFD、权限失败、断线／重连、多个不同主机同一路径、项目与标签 A→B→A、启动/取消竞争、索引和 Git 切分支同时发生、首页 Home 保护。验证**实际搜索结果及所打开的 FileTab.workspaceIdentity/path**、取消后进程／资源消失、请求数与 RSS 上界；测试添加 `ProjectFileIndexTests`、`PanelContextTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests` 及原生 `⌘P` E2E。远端无授权则不能标记 SSH 完全通过。
4. **文档与完成：** 更新 `docs/features/command-palette.md` 中“只支持本机”的旧 Invariant、`docs/features/ssh.md` 的实际索引边界与 `docs/features/files.md` 对应索引复用；新增本 task 引入的测试与调用方同次接入，移除本机专用重复路径；独立中文提交。

---

<a id="p3-t3"></a>
## P3-T3 Files 内名称／路径过滤及定位结果

**源码锚点：** `Bailey/Files/FileTreePanel.swift.FileTreeScrollView`（`ForEach(model.items)`、`ScrollViewReader`）、`Bailey/Files/FileTreeModel.swift`（`items`、`expanded`、`rebuild`／`cachedDirectories`）、`Bailey/Workspace/ProjectFileIndex.swift`（P3-T2 共用索引）和 `Bailey/UI/CommandPaletteView.swift` 的 `FuzzyMatcher`。

1. **Red：** 先证明现有展开外路径不会出现在 `model.items`，所以仅在现有行字符串上做 `filter` 无法满足深层文件搜索。对「输入一段文件名或相对路径」添加返回嵌套文件、目录名、路径片段、同名多目录、空目录、无结果和超出索引上限的预期；查询变化不能让原来多选对象误指其它行，清除查询须还原原树与展开状态。
2. **Green：** 在 Files 标题下添加紧凑的可收起过滤输入，复用 P3-T2 的同一后端感知索引／匹配方法；匹配目录与文件时只为渲染必要祖先生成可定位的展示行，不用第二份磁盘树或逐键重新 SSH 枚举。现有 `TreeDisplayModel.Row` 的真实 `path` 仍决定目标，搜索态不改其持久展开／现有排序；隐藏规则仅作用于 Files 显示，临时显示被排除的切换有明确行为。输入中可取消、失效、重建时不会闪现旧主机结果；结果点击打开或展开并能直接定位，错误或不完整索引状态必须可见。
3. **验证：** 空查询、快速输入与清除、多项相同名称、目录-only、深层未展开路径、压缩链、隐藏路径／临时显示、Git Worktree 更根、相似前缀目录、文件系统允许的极深目录与大量文件、图标和 Git 颜色、索引失效／权限错误／SSH 断线、多个并行窗口、Cmd+P 同时开启，窄/宽侧栏、中英和明暗、键盘箭头／Return／Escape。逐个核对屏幕实际行的路径、所属机器及原有选中／展开状态，测输入响应、目录 IO 次数、内存；扩展 `FileTreeTests`、`ProjectFileIndexTests`、`TreeRowHitTestingTests` 与原生 UI 测试。
4. **文档与完成：** 同步 `docs/features/files.md` 和 `docs/ui.md`；过滤与普通多选共用行、不新建完整独立搜索面板，原始树回归完全通过后独立中文提交。

---

<a id="p3-t4"></a>
## P3-T4 在 Files 中显示当前文件并保护机器身份

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift.openFilePath`（目前只取 `focusedContent.file.path`，未检查 workspace）、`Bailey/Files/FileTreePanel.swift`（当前行 `isCurrent` 只按路径、`ScrollViewReader` 仅对 Draft 滚动）、`Bailey/Files/FileTreeModel.swift`（`toggle`、`expanded`、`rebuild`）、`Bailey/Workspace/Project.swift`（`focusedContent`、`panelContext`、`matchesPanelTarget`）、`Bailey/Editor/FileViewerView.swift`（`FileTab.workspaceIdentity`）。

1. **Red：** 设置本机和 SSH 机器上存在**完全相同的字符串路径**，并在远端项目中打开一个本机 Finder 文件标签；先确认当前 `isCurrent` 可能错误地把远端树的同名行高亮。新增显式「在文件管理器中显示当前文件」回归：路径位于树的深层未展开目录；父目录被压缩、被 Files 隐藏或当前过滤遮蔽；活动文件根外、权限拒绝或文件已删除；切项目时在途展开和滚动不得落到另一机器。
2. **Green：** 当前文件高亮和 Reveal 必须联合确认 `FileTab.workspaceIdentity` 与当前 `PanelContext.Identity`、根及目标路径，不单凭 `String(path)`。通过当前 `FileTreeModel` 的 `backend.list` 与展开缓存沿祖先逐级加载、更新 `ScrollViewReader` 到实际行并在 Files 高亮；必要时**临时揭示这一个路径及祖先**，不修改隐藏设置或过滤查询的持久内容。非当前机器或 Files 根之外明确不可定位，不能重新定向项目或偷偷切机器。入口放在符合现有 UI 的编辑文件上下文或 Files 操作中，不引入重复“定位”按钮组。
3. **验证：** 文件所在根／嵌套目录／压缩多级、隐藏／过滤／搜索激活、路径大写小写与 Unicode、链接指向根内外、文件不存在／无权限、打开的是 Mac 外部文件却选 SSH 项目、同机多标签／多 Dock 组／多窗口、快速切换 A→B→A、点击与自动滚动异步延迟、重新命名／移动后 Reveal 和未保存编辑。测试 `PanelContextTests`、`WorkspaceIdentityTests`、`FileTreeTests`、`FileTabTests`，实际验证屏幕滚动到**准确文件**并有可见高亮，同时其它机器同名行不被点亮；不能只测试模型 expanded set。
4. **文档与完成：** 同步 `docs/features/files.md`、`docs/features/editor.md`、`docs/features/projects.md` 的文件身份／定位契约，以及必要的 `docs/ui.md` 菜单语义；替代按纯字符串高亮的旧路径并在同一任务保留单击打开、焦点与目录压缩。独立中文提交。

---

## Phase Audit

P3 实施完成后才创建 `audit-p3.md`；重点审查隐藏与 Git ignore/`⌘P` 的作用范围分离、索引是否真正取消并有界、Reveal 能否跨机器误高亮以及原文件树压缩/排序是否保持。
