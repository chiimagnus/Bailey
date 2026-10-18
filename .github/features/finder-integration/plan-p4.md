# Plan P4 — 在现有项目中直接打开任意本机文件

> **待执行方案，基于 2026-10-18 的 P3 基线 `a85d10c`。** 此文档不是实现或测试结果。用户已明确取消「没有项目也能打开文件」；不得恢复此前已删除的 P4 隐藏文件工作区实现。P1～P3 的历史任务及审计不改写。

## Goal / Non-goals / Decision

**Goal：** 在 Bailey **当前已选中的 Project** 里，直接以现有 `PaneTab.file(FileTab)` 打开项目目录内外的 Mac 文件。入口是**macOS 系统「文件 → Open File…」（⌘O）**、标签栏「＋ → Open File…」、Finder／Dock、窗口普通拖放；单文件和多文件均不创建项目。目录只有用户显式添加时才形成 Project。

**Non-goals：** 无项目时打开**新的**文件、隐藏 `documentProject`／`Open Files`、第二套 Dock／Editor／SessionStore、临时文件夹浏览、远端上传、PDF／Quick Look 增强、每个 Projects 行的新 Drop 处理器、**除 Open File 标准 ⌘O 外的其它新增快捷键**、新窗口选择架构。P3 的 Files 复制、Ghostty 路径插入、WebKit 上传不重做。

**架构决定：** **不解耦／搬走 `Project.tabs` 与 `Project.dock`**。现有 `Project.openFile` 已能打开根目录外路径，真正要分开的是「本机文件打开意图」和「添加项目意图」，以及**单个 FileTab 的本机／远端身份**。继续由 `TerminalManager` 选中窗口与项目、`Project` 持有标签和 Dock、`FileTab` 持有读写与撤销；不增加并行所有者。

### 源码与文档事实（执行前取证）

按仓库 `AGENTS.md` 与 `docs/architecture.md`、`standards.md`、`ui.md`、`testing.md`、`features/projects.md`、`dock.md`、`session-restore.md`、`editor.md`、`files.md`、`command-palette.md` 阅读对应不变量，并使用 `rg` 枚举 `Bailey`、`BaileyTests` 中以下符号的直接调用者。此 worktree 的 CodeGraph 未初始化，`rtk codegraph sync` 明确报错，因此沿现有源码、测试和调用链核验，不自行初始化索引。本轮尚未运行新的 P4 运行时实验。

| 现有事实／根因 | 源码证据 | P4 处理 |
| --- | --- | --- |
| **文件被当成项目**：单文件触发 `addLocalItems(file)`，多个文件按父目录找／创建项目，项目数量、选中项受路径影响 | `TerminalManager.addLocalItems`、`openExternalLocalItems`：`filesByParent`、`explicitDirectories`、`containing`、`contains(path:in:)` | 文件统一进**当前项目**的本机 FileTab；删掉自动项目算法和本机单文件新建 pinned 项目的生产路径 |
| **Projects 外部文件拖入另建项目**，本机“添加文件或文件夹”选择器也把文件按 Project 解释 | `WorkspaceDockView.DockTabGroupView.content(.projects)`、`ProjectsPanelView`、`WorkspaceNativeDialogs.localPanel`、`TerminalManager.chooseLocalItems`；菜单与命令面板直接调用 | Projects 文件投放调用普通本机文件 opener，目录保留 `addLocalItems`；将文件选择和添加目录明确拆成不同原生 picker |
| **Dock 不是问题**：`Project` 已持有 `PaneTab`、`FileTab`、`DockWorkspaceModel`，能在任意组开外部路径并保留编辑缓冲 | `Project.openFile(_:editorState:inGroup:)`、`findFileTab`、`Project.tabs`、`WorkspaceDockView` | 复用原标签及组定位，不引入隐藏 `Project`、第二套布局或零项目容器 |
| **本机文件会继承远端后端**：`Project.openFile` 当前从 `workspaceBackend` 和 `workspaceIdentity` 生成 FileTab；SSH 项目可能把 Mac 路径当 SSH 路径 | `Project.openFile`、`workspaceBackend`／`workspaceIdentity`、`FileTab.reevaluateWorkspace` | 仅为**明确本机文件 URL**提供共享插入逻辑的 `openLocalFile` 入口，使用 `LocalWorkspaceBackend.shared` 和 `nil` 机器身份；原 `openFile` 保留项目后端语义 |
| **混合后端快照会丢标签**：`isSnapshotable` 按 `project.sshHost` 过滤文件；`Project.restoreTab` 用项目后端反建 FileTab | `TerminalManager.isSnapshotable`／`contentSnapshot`、`SessionStore.ProjectSnapshot.TabSnapshot`、`Project.makeContent` | 在**已有单个 TabSnapshot** 上加最小可选本机标识，确认为 Mac 的 FileTab（包括固定／动态 SSH 项目里的本机标签）写入 `localFile=true`；恢复时按文件标识选本机后端。旧字段缺失时沿原行为，不新增文件区快照 |
| **全窗口查找错误地依赖项目是本机**：现有跨窗判重排除 `project.sshHost != nil` 的 Project，无法识别未来 SSH Project 中的本机 FileTab | `TerminalManager.deliverPendingExternalFiles`、`openExternalLocalItems` | 判重按 `FileTab.workspaceIdentity == nil` 和标准化真实本机路径，**不以 Project 的 sshHost 排除**；原窗口／原缓冲优先 |
| **系统与拖放接入已存在**：Apple Event、恢复队列、Finder provider、准确 Dock 目标组、Files Copy、WebKit、Ghostty 各已有接收者 | `BaileyApplicationDelegate.handleOpenDocuments` → `TerminalManager.openExternalFiles` → `deliverPendingExternalFiles`；`FinderWindowDrop.receive`、`FileTreeImportDrop`、`PanelContentView` | 保留接收与窗口归属；只替换最终文件分派规则。不要复制队列、另设全局缓存或父层 Drop |
| **零项目不能显示 Dock**：`ContentView` 只有在 `selectedProject != nil` 时渲染 `WorkspaceDockView` | `ContentView.body`、`TerminalManager.selectedProject` | 本期**不改**。没有项目时新文件明确不打开；显式目录添加仍正常启动现有工作区 |
| **历史单文件项目是真实用户资料**：项目名、图标、路径、快照仍依赖 `pinnedFile`；远端添加文件另走 `addSSHItems` | `ProjectsPanelView`、`Project.updateFilePaths`、`SessionStore.ProjectSnapshot`、`TerminalManager.restore` | 删**新的 Mac 文件 → pinned 项目**创建逻辑；保留旧快照的读取、重命名、图标和 SSH 显式文件项目语义，不对用户数据做自动删除／迁移 |

**已经正确且不应重构的公共路径：** `TerminalManager.fileRenamed` 会遍历所有 Project；`Project.updateFilePaths` 逐个按 `FileTab.workspaceIdentity` 判断文件路径是否需要更新，随后才按 Project 身份调整项目根或 `pinnedFile`。因此 Mac 文件位于 SSH Project 时，文件重命名通知已有机器隔离，无需新增重命名系统。`TerminalManager.saveBeforeWindowClose`／`saveBeforeTermination` 也遍历项目内每个脏标签，新增本机 FileTab 可以使用现有保存保护；验证真实字节即可，不改另一套关闭流程。

### 单一文件路由：必须维持的规则

1. **入口分离**：标签栏「＋ → Open File…」和 macOS 系统「文件 → Open File…」（⌘O）**共用**「只选文件、允许多选」`NSOpenPanel`，前者携带发起的 Dock 组，后者使用聚焦窗口的当前项目／活动组；没有选中项目时菜单命令禁用。`Add Folder…`（Projects、`⇧⌘A`、命令面板、零项目空态）使用「只选目录」`NSOpenPanel`；Finder／普通编辑器落点使用已有文件事件及 `FinderWindowDrop`；Projects 整体 Drop **文件 → Open File，目录 → Add Folder**。新建文件 `New File…` 仍在当前项目的 Files 根创建，不能误变成 Open File。
2. **先判重，再落当前项目**：`deliverPendingExternalFiles` 继续等待原窗口/恢复、在所有窗口查找**本机** FileTab，找到就选择其原窗口、原项目、原标签，不复制原生缓冲，不迁移原 Dock 组；没有才使用**实际接收窗口当前选中 Project**。明确固定回归：**文件 X 已在 A 标签打开 → 切换到 B → Finder 再打开 X → 激活 A 原标签**。即使 X **不在 A 项目根目录内**也如此；X 在 A 根内是另一测试用例。只有**首次打开**的 X 才进入当前 B，不按文件路径自动选择 A 或其它项目。该规则亦适用于标签栏「＋」、系统「文件」菜单及跨窗口打开。本机路径是否位于项目根目录、Git 仓库完全不影响路由。`openLocalFile` 允许新建在实际指定 `DockGroup`（包括空／非选中组）。
3. **机器身份以文件为准**：新 Mac FileTab 永远用本机后端，`workspaceIdentity == nil`；项目自己可以是本机、固定 SSH、动态 SSH、连接／断线中。不能把 Project 的 SSH 后端传给 Mac FileTab，也不能把同名远端 FileTab 当本机复用。`FileTab.reevaluateWorkspace` 对本机 nil 身份本就无远端重绑，原远端文件、Diff、Git、Files 后端不变。
4. **没有选中 Project**：新本机文件拒绝，`openExternalLocalItems` 返回该 URL 为 rejected，外层原有按窗口 `showError` 反馈，不造项目／窗口外编辑状态。此前已在其它有项目窗口打开的 Mac 文件可以激活原标签。仅包含目录的显式投递可用 `addLocalItems` 创建正常项目；文件／目录混批中**确实包含显式目录**时，可先加目录，再把该批新文件打开到新增的真实项目，不能偷偷根据文件父目录建项目。
5. **批量／位置稳定**：有初始选中项目时，无论同一批里有多少目录，**新文件的目标固定为该初始项目**；目录显式添加按既有规则改变选中项目，最后应使最后成功文件及接收窗口取得焦点。没有初始项目但明确添加了目录时，文件使用本批新建／复用的正常目录项目。重复文件只建立一个 Tab，部分无效文件可拒绝且合法文件继续。准确 Dock group 必须同时匹配发起的 `projectID` 与 `groupID`，若异步返回时该目标已失效，则拒绝，不默默投到其他项目或组；无指定组的系统文件请求按实际投递时的当前项目处理。
6. **会话恢复**：不另建快照；给现有 `ProjectSnapshot.TabSnapshot` 增加可选 `localFile: Bool?`，本机 `FileTab.workspaceIdentity == nil` 写 true（含普通本机、固定和动态 SSH Project 中的 Mac 文件），远端文件不写，旧快照缺键继续继承原项目后端。原 `isSnapshotable` 允许本机文件被保留，即使 Project 是 SSH；`Project.restoreTab`／`makeContent` 只有带 true 标记时强制本机 backend。原 `dock`、选中位置和 EditorState 保持不变；不保存未写盘正文、不启动新 Shell、不改变旧 SSH Tab 加载。
7. **数据保护**：项目选择或标签选择的**既有**失焦自动保存保持不变；`saveBeforeWindowClose`／`saveBeforeTermination` 对本机标签真实写本机磁盘，失败仍保留编辑和窗口。重命名／删除、重复打开／跨窗重开要核对源路径、原生视图与最终写入。`Project.pinnedFile` 既有实例仍可继续开标签，但不能因此增加第二个 file-pinned 项目。

---

## P4-T1 — 统一当前项目的本机文件标签路由

**Goal：** Finder 系统文件事件和已有普通 Dock 文件投放，不再按路径找项目／造项目，而是打开至接收窗口的当前项目；SSH 项目也正确保留本机文件与恢复。无项目新文件不创建 Project。

**修改边界：** `Bailey/Workspace/TerminalManager.swift` 的 `openExternalLocalItems`、`deliverPendingExternalFiles`、`isSnapshotable`、`contentSnapshot`、`makeWindowSnapshot` 及必要参数；`Bailey/Workspace/Project.swift` 的共享文件标签插入与 `restoreTab`；`Bailey/Workspace/SessionStore.swift` 的**可选 TabSnapshot 标记**。保持 `TerminalManager.openFile`／`Project.openFile` 的项目文件打开语义，不能为了 Finder 把 Git、Files、命令面板及远端文件打开改成全局本机。需要验签版本不变的原生编辑器和 Dock，不改 `FileViewerView.swift` 的 IO 引擎。

**Red → Green → Refactor（同一 task）：**

1. **Red 模型与工作区测试**：选中本机 Project A，分别打开 A 根内、B 根内、根外文件，单个／同目录多个／跨目录多个；断言 `manager.projects` 数量、Project ID/根、`selectedProjectID` 不变，新文件均进 A 的 `FileTab`，真实内容可读。旧算法会建项目或切 B，应真正失败；仅 `NSItemProvider` 投递成功不算 Red。补全项目切换判重：A 已打开文件 X 后选 B，再从 Finder 重新投递 X；分别以 **X 在 A 根目录内**、**X 仅作为 A 的外部文件** 建立测试，均断言回 A 的同一 Tab／原生缓冲且 B 不新增标签。X 在 A 中尚未打开时，当前 B 接收并新建 B 标签。无项目文件先返回 rejected、列表保持空白；混批显式目录能添加正常项目。
2. **Green 公共路由**：现有 `openExternalFiles → deliverPendingExternalFiles → openExternalLocalItems` 仍是唯一系统／通用 Drop 入口；新本机文件只通过 `selectedProject.openLocalFile` 进入原 Project 的标签／Dock。拆出 `Project.openFile` 中最小共享插入函数，避免复制完整打开／去重流程；本机以 `LocalWorkspaceBackend.shared`／nil 身份传入，原 `Project.openFile` 继续沿项目 backend。移除 `filesByParent`、`explicitDirectories`、`containing`、“最长本机根”、从文件退回 `addLocalItems` 以及仅供该算法使用的 `contains(path:in:)`；`resolvedLocalPath` 仍供全窗口／软链判重。
3. **SSH 不混机**：固定 SSH 未握手／已连／断线、动态 SSH 进入／退出（可控 backend 夹具）下，在**当前项目**添加 Mac FileTab，检查其真实 Mac 内容、可写状态、源文件最终字节与同名远端文件隔离；禁止 SSH 请求、本机路径伪装远端。`deliverPendingExternalFiles` 中现有 `project.sshHost == nil` 的本机 Tab 判重条件应改为**检查 FileTab 自己的本机身份**；SSH 远端文件仍绝不能冒充本机已开。
4. **快照最小变化**：对 `FileTab.workspaceIdentity == nil` 的标签写入现有 `TabSnapshot` 的可选 `localFile=true`，`isSnapshotable` 允许本机标签出现在 SSH Project 的快照，恢复按标记选择本机 backend；旧 `TabSnapshot` JSON 缺键兼容、旧本机及固定 SSH 文件标签、旧 `pinnedFile` Project 的名称／目录／图标／Dock／光标／选择全不改变。固定和动态 SSH 场景均模拟保存、终止、重启，从磁盘重读同一 Mac 文件；断线重连后不变成远端。
5. **目标与失败**：已有标签先用标准化／解析软链路径全窗口查找，复用原 `PaneTab`／`FileTab` 和原 `NSView`；固定 group 新文件插入准确组，旧组不迁移。请求接收窗关闭、非选中组、项目切换或 group 消失时，不能投向错误项目。无项目冷启动和缺失／非法项返回失败，原有 UI 失败通道清楚告知。
6. **本 task 清理／验证**：移除 T1 替换掉的路由分支和旧注释，改写而**不删掉**现有 `WorkspaceIdentityTests`、`WorkspaceWindowIsolationTests` 的“按父目录建项目”旧断言；增补 `SessionStoreTests`、`WorkspaceContentIdentityTests`、`FileTabTests`、`DockWorkspaceTests`、`PanelContextTests` 的本机／远端复用与真实文件保存检查。同期更新 `docs/features/projects.md`、`dock.md`、`session-restore.md`、`editor.md` 中已实现的新规则，检查 `docs/architecture.md` 不应产生新所有者。执行定向测试、`make build`／`make test`、签名与完整退出码、`git diff --check`；验证后仅原子提交本 task 变更。

**Acceptance：** Project A、SSH Project S 中打开 Mac 文件均留在原 Project；`FileTab.workspaceIdentity == nil`，读写及重启仍是本机；跨窗单缓冲，不自动建项目；零项目保持零项目。

---

## P4-T2 — 「Open File…」菜单、目录添加与 Projects 入口归一

**Goal：** 同时提供标签栏「＋ → Open File…」与 macOS 系统「文件 → Open File…」（⌘O），彻底移除“把新 Mac 单文件作为用户 Project 添加”的旧入口。目录添加仍清楚、可用。

**修改边界：** `Bailey/UI/WorkspaceDockView.swift::DockTabGroupView.panelAddButton`（真正的每组「＋」）、`Bailey/UI/ContentView.swift::WorkspaceNativeDialogs`、`Bailey/Workspace/TerminalManager.swift::chooseLocalItems/addLocalItems`、`Bailey/UI/Panels/ProjectsPanelView.swift`、`Bailey/App/BaileyApp.swift::BaileyCommands`、`Bailey/UI/CommandPaletteView.swift`、`ContentView.emptyState`、`Bailey/Resources/Localization/{Interface,Sidebar,Terminal}.xcstrings`；必要时触及 `FinderWindowDrop.receive` 的现有调用而不复制 provider 加载。

**Red → Green → Refactor（同一 task）：**

1. **Red 原生 chooser**：新「Open File…」选择器必须 `canChooseFiles=true`、`canChooseDirectories=false`、`allowsMultipleSelection=true`；本机「Add Folder…」反之（只能目录、允许多选）。两者都以`发起主窗口`显示 Sheet；选择／取消、按 Return、另一窗口成为 key 时不串窗口。旧混合 `localPanel`、`chooseLocalItems` 的行为应在改前由新测试明确指出冲突；不是复用“添加文件夹”选择器打开文件。
2. **Green UI**：每个工作 Dock 组「＋」直接增加 `Open File…`，在其原 `NSOpenPanel` 选择后调用 T1 统一 `TerminalManager.openExternalFiles`，附带原 `projectID/groupID`；**`BaileyCommands` 的 File 菜单中同样新增 `Open File…`，标准快捷键 ⌘O**（现有快捷键表未占用），通过 `@FocusedValue(\.baileyManager)` 归属当前聚焦主窗口、以其活动组为默认落点，复用相同选择器和路由，不能直接操作后台窗口或打开另一套 FileTab。无项目时禁用该命令，设置窗口成为 key 时不得偷用前一个 Bailey 主窗口。Projects「＋」、`⇧⌘A`、命令面板、无项目空态分别改成 `Add Folder…`，只添加/复用目录 Project；`New File…` 与 `New Folder…` 仍是 Files 的创建功能。零项目无 Dock「＋」，其他无项目入口只允许添加目录。
3. **Finder 落点统一**：Projects 现有 **整体** `.onDrop` 仍复用 `FinderWindowDrop.receive` 的单份 NSURL 加载；文件使用 T1 已有文件路由，目录使用 `addLocalItems`，混合请求保留合法项与明确错误。其他编辑器／Diff／Git／浏览器**工具栏**及 Dock 标题的精准 group 投递按 P3 保留；Files 行与根的复制、终端路径插入及 WebKit 正文上传不改变。项目行内部排序及工具栏本地 Dock 标签拖动不能被新增入口误接收。
4. **删除错误创建入口**：`TerminalManager.addLocalItems` 只处理现存目录；彻底删除其中“Mac 文件 → `pinnedFile` 新项目”的分支及相关新项目命名逻辑。改掉全部直接调用旧 `chooseLocalItems`／`localPanel` 和误导性“Add Files or Folders”文案及测试；不能同时留一条 UI／Service 仍可调用旧 Mac 文件建项目的路径。`TerminalManager.addSSHItems` 的远端文件显式项目、`Project.pinnedFile` 历史读取、`SessionStore` 旧快照与项目图标／重命名支持保留并回归测试。
5. **测试与文档闭环**：`PaneRetentionTests` 验证两个 NSOpenPanel 的参数、Sheet 所属窗口；`AppMenuIsolationTests`／`WorkspaceWindowIsolationTests` 检查每组「＋」**和系统 File → Open File／⌘O** 的真实命令启用、当前窗口／当前项目／活动 Dock group 的编辑标签，并覆盖双窗口切换、设置窗口前台、无项目禁用、键盘与鼠标菜单触发；`WorkspaceIdentityTests` 验证新增文件不创建 Project、目录仍创建、重复目录复用、混批与 0 项目；`FileTreeTests`／`TreeRowHitTestingTests`、`DockWorkspaceTests` 保护 P3 分发。同期更新 `README.md`、`docs/features/projects.md`、`dock.md`、`files.md`、`command-palette.md`、`docs/ui.md`、`docs/testing.md` 及受影响的中英翻译，旧 P1～P3 审计不改写。定向测试 + 全量 `make build`／`make test`、严格签名、`git diff --check`，核对新按钮实际可操作和原生文本可见，验证后原子提交。

**Acceptance：** 用户在当前项目的任意 Dock 组经「＋ → Open File…」，或经 **macOS File → Open File…／⌘O** 打开任意本机文件；两者共用文件选择器及路由，均归当前窗口与准确的活动组；Projects 仍只含原有项目；「Add Folder…」不能选择单文件；所有生产可达的**本机单文件建新 Project**入口已删除。

---

## P4-T3 — 真实 Finder／菜单 E2E、极端条件与独立审计 Gate

**Goal：** 用实际签名 App 和受控原生窗口验证 P4 全部用户路径；对发现的实际同源缺陷补 Red→Green→清理后再交独立阶段审计。不能用“已派发事件”、静态源码或 XCTest 全绿替代真实 UI 结果。

1. **自动测试执行**：`WorkspaceIdentityTests`、`SessionStoreTests`、`WorkspaceWindowIsolationTests`、`WorkspaceWindowCloseTests`、`WorkspaceContentIdentityTests`、`PaneRetentionTests`、`FileTabTests`、`DockWorkspaceTests`、`PanelContextTests`、`AppMenuIsolationTests`、`AppIdentityTests`、`FileTreeTests`、`TreeRowHitTestingTests`，在现有 `BaileyTests` target 被发现并真实执行。执行仓库根 `make build`、`make test`；确认整体退出码、成功／失败／跳过数、签名和无新增诊断。定向类别只用于定位缺陷，不能替代全量。
2. **原生菜单**：真 `NSWindow`／`NSHostingView` 及有签名的隔离测试 App：实际点击**macOS File → Open File…／按 ⌘O** 和各组的「＋ → Open File…」，单／多文件、目录不可选、取消、跨窗口 Sheet 不串、聚焦组与非选中／空组定位、键盘导航、无项目菜单禁用及设置窗口不误触发；新文件实际看到全文／图片并可编辑，重开后复用同一原生编辑器。项目数、项目路径、Git/Files 根、终端 cwd、Dock 结构无错误副作用；`⇧⌘A` 与 Projects「＋」只选择目录。
3. **Finder 真实事件**：核对 `CFBundleDocumentTypes` 仍是备用候选、Finder「打开方式」、Dock 图标文件拖入、`open -a Bailey` 单／多文件和目录（仅做明确项目添加）、已启动／未启动／末窗关闭、已有文件在另一窗口、窗口恢复先后 attach；**Finder 双击只有在 Bailey 为该文件默认程序时才向 Bailey 送文件事件**，不得把“打开方式”或 `open -a` 代替默认双击证据。必须分别验证 **A 打开 X（X 在 A 目录内）→ B → Finder 重开 X → 原 A 标签** 与 **A 打开目录外 X → B → Finder 重开 X → 原 A 标签**；再测试 **X 从未打开、当前 B → B 新标签**。要检查**真正的目标 PID／窗口、原生 FileTab 内容、项目列表、磁盘字节和最后焦点**。真实 Finder 鼠标拖放分别测 Projects 整体文件/目录/混合、编辑器、Diff、Git、各组标签栏、空组、浏览器工具栏及 Files 行/根；检查一次动作只有对应子系统消费。不要复用旧截图代替新 P4 验证。
4. **机器与存储**：本机固定目录／自动目录、旧 `pinnedFile` 项目、多项目切换 A→B→A、固定 SSH（握手前／已连／断线／重连）、动态 SSH（连接／退出）、本机／远端同名文件、多窗口内外复用。逐项核对真实本机保存或 SSH 数据保持不变；重启恢复旧 JSON 和新可选本机 Tab 标记、选中标签／Dock 组、光标滚动、脏文件切换与关闭失败／取消、用户明确丢弃与已保存字节。不能借用用户私人 SSH master。
5. **编辑与失败**：空／单／2／50+ 文件、同目录／跨目录／文件目录混批、重复与乱序、软链／断链／Finder alias、`/var` 与 `/private/var`、大小写敏感路径、Unicode/中文/emoji/空格/引号/控制字符、包目录、缺失／权限拒绝／异步消失、空文件／5 MiB 边界／超限、UTF-8／NUL／图片／损坏图片／二进制／未知扩展名。验证部分失败反馈与合法项继续，重复打开不产生第二个可写缓冲或错误写入。旧保存/撤销/IME/滚动/重命名、窗口关闭、失焦自动保存都要检查最终文件字节而非只看状态。
6. **P3 回归边界**：Files 导入的行／根命中、实际副本字节、源项保留、同名冲突、非覆盖发布和局部失败；本机 Ghostty 只插入安全转义路径且不执行；SSH 终端拒绝 Mac URL；WebKit 正文上传不新增 FileTab；Dock 内部移动、Projects 内部排序、Git／Files 共享树点击／悬停／焦点及 Shell 活性。暗／亮、en／zh-Hans、窄／宽窗口、鼠标／触控板、长标题、键盘与基础无障碍均对受影响区域核实。
7. **清理与审计**：`rg` 定位所有新入口是否最终使用共享文件路由；无 `filesByParent`／`contains` 路径推断、无“Mac 文件 → 新 Project”分支、无未接入的旧 `chooseLocalItems` 混合选择器、无隐藏 documentProject／第二套选择或快照、无误导性当前产品文案。仍有真实用途的 `pinnedFile` 历史结构、`addSSHItems` 与独立 Files Copy 不作为垃圾删除。实际发现 Bug 同 task 先 Red、根因修复、再次完整验证与同步文档，不能只调整断言。独立 P4 审计按 `todo.toml` 的 task / commits 逐一核对；证据未完成不标记全通过。

### 必须最大程度覆盖的组合与未验边界

以下是执行时的核销全集，不能按“正常路径足够”“代表用例”减少。每一取值及已知极端条件都要实际验证；组合太多时尽可能穷举有限集，再扩大两两／多因素及已知失败组合。已测、失败、Blocked、替代证据、影响和补验动作写在本计划的执行证据及 `audit-p4.md` 中，不另建永久重复矩阵。

| 维度 | 实际条件和最终判断 |
| --- | --- |
| 入口与意图 | 每个组「＋ Open File…」、Add Folder、Projects 面板、Finder Open With／Dock／`open -a`、编辑／Diff／Git／浏览器工具栏／空组；文件开标签、目录才建项目、无双重接收 |
| 项目与机器 | 无项目（新文件拒绝）、本机单／多／自动项目、旧单文件 pinned、固定 SSH 握手前／已连／断线、动态 SSH 进出、同一路径多机器；Mac 文件后端绝对是本机 |
| 路径／容量 | 0、1、2、50+，根内外、交错、重复、软链接／失效链接／别名、不同大小写与系统路径别名、特殊字符、未知类型、权限和容量边界；合法项真的可读，错误有反馈 |
| 布局与生命周期 | 窗口 1／2+，上／下／左／右组，选中／非选中／空组、已打开复用、迟到／取消／关窗、冷启动／末窗重开／旧新快照、脏缓冲保存／失败／退出；单份 native buffer 与最终磁盘字节 |
| 保留子系统与 UI | Files Copy、Ghostty 路径、WebKit 上传、Git/Diff/SSH、项目与标签重排；英文／中文、亮／暗、窄／宽、鼠标／触控板、键盘／无障碍，无现行行为回退 |

**已有环境边界**：当前 Mac 为 macOS 27.2，最低部署 macOS 15.6 的真实 Finder/UI 仍需 15.6 设备补验，不能由 SDK 编译推断。专用 Windows SSH 运行条件可能需获授权主机；无权限只使用受控后端测试，并逐项标注真实 SSH 未测。真正 Finder、Dock、`open -a` 采用 Launch Services 同 Bundle ID 路由，`BAILEY_UI_TEST_RUN_ID` 仅隔离用户数据、**不隔离 Bundle ID 和前台图形会话**；不可为了做 E2E 擅自退出／重启用户正式 Bailey、覆盖偏好或结束后台 SSH。不能确认真实接收 App 时必须标阻塞，不谎称成功。执行阶段需要符合 `docs/testing.md` 的隔离、证据与完整命令检查。

### P4-T3 执行证据（2026-10-18，当前环境已完成，其他系统／GUI 条件待补）

- **签名与隔离**：macOS 27.2 / Xcode 27.2 / arm64；签名 Debug Bailey 的 `BAILEY_UI_TEST_RUN_ID` 与独立 Home 均生效，进程、UID 快照和 `/tmp/bailey-p4-e2e-2p9m03uq/` 中测试文件逐项核对。正式 Bailey 有独立运行进程，未被退出或重启。
- **真实菜单 / Apple Event**：文件菜单「打开文件…」与 ⌘O、右侧 Dock 组「＋ → 打开文件…」实际弹出原生多选文件面板；取消不改变项目/标签。文件打开后原生 Text Editor 显示真实 UTF-8 内容，图像显示实际 160×100 PNG；右侧分组落点经 `dock` 快照核对未迁组。`open -n` 冷启动目录 Project A；`open -a` 多选不同父目录和 Unicode/空格/单引号/未知后缀，实际只增加本机标签；A 根内及根外文件在选中 B 时重新打开均复用 A 原标签；新图片首次进入 B，不增加隐藏项目。
- **真正 Finder 鼠标**：在核对 Finder 和测试 Bailey 窗口屏幕边界后，拖到 Projects 整体 → 当前项目新标签、不新建项目，源 SHA 不变；拖到 Files 根留白 → 项目根出现字节相同的副本，不打开标签、源文件保留；拖到顶部标签栏 → 当前组新标签。P3 的 Files 精确行/根标题、Ghostty 与 WebKit 真机记录另在 `audit-p3.md`，不可将其冒称本次 P4 全部位置的物理拖放。
- **编辑、容量、恢复**：在原生 File 菜单 Save 后，直接读取项目外文件确认正文由 `let edited = 0` 变成 `let edited = 1234`；68 个不同文件 + 重复/软链接共 72 个批次项由新隔离进程实际接收，唯一 Project、68 个不同标签、68 个源 SHA 全不变。退出并以同一 UUID 重启隔离 App：原生界面和快照中的 2 个项目、11 个标签、Dock 分组及已保存正文均恢复。
- **新增真实缺陷与 TDD**：POSIX `chmod 000` 文件和目录分别仍被误开成空文件标签/不可浏览 Project，FIFO 被错误打开成编辑器；三个 Red 场景先证明 7 个失败断言。`TerminalManager` 的现有路由在新建前核对普通文件类型、文件可读、目录可读且可遍历；已有标签优先复用。`WorkspaceIdentityTests` 四项新增条件含原标签权限变化、只读文件可读、失败批次合法项继续；最新 **24/24，0 失败**；同步 `docs/features/projects.md`。日志 `/tmp/bailey-p4-{nonregular-red,access-green,regress-final}.log`。
- **完整命令**：此前授权 Windows 主机实机套件 `make test` **466 项、0 失败、0 跳过**，退出 0；本轮修复后 `make build` **退出 0**、`** BUILD SUCCEEDED **`、完整 App 严格验签成功（`/tmp/bailey-p4-final-build.log`）。随后使用 `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test`，**470 项、0 失败、0 跳过**，完整退出 **0**、`** TEST SUCCEEDED **`，耗时 **828.482 秒**（`/tmp/bailey-p4-final-ssh-test.log`）；6 个需要真实 SSH 主机的用例全部实际 passed，无权限跳过。
- **提交与整包安装**：阶段剩余缺陷已原子提交 `b4e29bc8ace21c39d9fee1da87369e2758afc9c3`，仅 `TerminalManager.swift`、`WorkspaceIdentityTests.swift` 和 `docs/features/projects.md` 入库，Feature 状态/审计保持本地。完整已验签新 App 在 `/Applications` 同卷暂存并整包替换，安装后二进制 SHA-256 `fd05597363ffc87eefe704df6781cab448722be7f9384f7a3328e1c3f1ea542e` 与测试构建完全一致；暂存与旧包备份已清理。正式 Bailey PID 59877 未退出／重启，新磁盘包须用户下次正常重启才加载。独立阶段审计见 `audit-p4.md`，Gate `Go` 仅针对现有可安全执行的范围。
- **待核销而不冒称已测**：macOS 15.6 真机、Finder「打开方式」/默认双击/物理 Dock 图标、另一个窗口、Git/Diff/浏览器工具栏及空组的真实鼠标组合、外观明暗/中英文与触控板交互，以及 GUI 权限拒绝提示。当前正式 Bailey 正在使用；`Peekaboo` 的实体鼠标会共享桌面，不能未经同意抢正式会话。已有 `WorkspaceWindowIsolationTests`、`PaneRetentionTests` 与原生/集成测试是替代验证，**不等于上述物理 E2E 已通过**。获安全独立图形会话和最低系统设备后应逐项补验，独立 Gate 按实际未验影响判断。

### Gate

- T1/T2 各自可运行的 Red→Green→Refactor、删除替代旧代码、同步真实功能文档与中英本地化、按仓库规范形成单一原子提交；若验证揭示共享核心假设不成立，**先修正计划，不能临时叠加补丁式架构**。
- T3 对全部可执行条件完成原生可观察验证，分别报告 XCTest、签名构建、真实 Finder、最低系统与真实 SSH 的结果；独立 `plan-task-auditor` 检查提交、旧代码删除和残余缺口后才可关闭 P4。
- 实施前设计评审曾仅限计划文件；用户随后已授权执行 P4，因此以实际代码、测试、当前文档和 `todo.toml` 为准。Feature 计划与审计仍仅保留本地，不擅自推送。
