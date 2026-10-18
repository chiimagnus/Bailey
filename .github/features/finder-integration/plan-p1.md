# Plan P1 — 文件打开复用与窗口生命周期

> **历史阶段，已完成；文件建项目策略已被 P4 替换。** P1 当时允许外部打开新文件时根据路径复用或创建本机项目，也允许手动添加单文件 `pinnedFile` 项目。2026-10-18 用户改为「已有项目内打开本机文件、只有显式添加目录才建立本机项目」。当前规则和验收以 [idea.md](idea.md)、[Plan P4](plan-p4.md) 为准；本文件的任务、Red→Green 和提交记录只作为**当时验收的历史证据**，不能据此恢复旧行为。P1 的跨窗口原标签复用、冷启动恢复以及 Finder Service 目录入口仍需按现行需求审查。

**Goal：** 为 Finder／Dock／普通窗口拖放建立一条可复用的「打开本机资源」路径；保留现有「添加项目」语义，正确找到文件、项目、窗口并完成打开。

**Non-goals：** 本阶段不注册 macOS 文件类型、不处理 Finder 拖放、不改变手动添加或 SSH 添加的产品行为，不改文件编辑／预览能力。

**Approach：** `TerminalManager.addLocalItems` 是用户明确「添加文件／目录为项目」的入口；单文件 `pinnedFile` 参与名称、图标和恢复。外部打开另用薄入口决定选哪个**现有本机项目和标签**，具体项目创建仍复用 `addLocalItems`，文件标签仍由 `Project.openFile` 管理。跨窗选择在第二任务利用现有 `registry` 与窗口生命周期接入；**不预先规定必须合并两个语义不同的冷启动队列**。

**Acceptance：** 已打开文件只定位一份编辑缓冲；新文件选择正确本机目录项目，不绑定远端；批量不同路径不制造重复项目；手动文件／文件夹添加与原 `pinnedFile` 快照完全不变；冷启、末窗关闭、恢复多窗口和原 Finder 文件夹服务均正常。

**Rules：** `TerminalManager` 管窗口和项目列表，`Project` 管标签，`FileTab` 管编辑缓冲；不建平行应用容器、文件模型、持久化层或跨窗口共享编辑器。**只有确实被新实现取代的旧队列和调用分支才在该任务删除**；已有 Finder Service 继续使用仍有实际调用者的最小逻辑。

---

## P1-T1

**独立结果：单窗口内 Finder 式打开与既有添加语义共存。**

**真实入口与根因：**
- `Bailey/Workspace/TerminalManager.swift::addLocalItems` 每个文件创建带 `pinnedFile` 的项目，判重条件是 `customDirectory + pinnedFile + sshHost`。这是手动添加的既有语义，不能直接改成目录内所有文件合并。
- `Bailey/Workspace/Project.swift::openFile / findFileTab` 只在本项目寻找相同 `path + workspaceIdentity` 的文件标签；`Project.workspaceBackend / panelContext` 决定本机或 SSH 后端。当前没有「外部文件打开」的本机项目选择策略。
- `Bailey/Workspace/TerminalManager.swift::restore` 会根据 `pinnedFile` 补开对应标签；`ProjectsPanelView` 根据 `pinnedFile` 显示文件图标。改动这一字段会破坏旧工作区。

**Files：**
- Modify：`Bailey/Workspace/TerminalManager.swift`，在现有 `addLocalItems / Project.openFile` 上组合「打开资源」路径；必要时只补 `Project` 已有标签的只读查找，不新建跨窗缓存。
- Modify only if proven necessary：`Bailey/Workspace/Project.swift`；不得改变 `SessionSnapshot` 编码、`FileTab` 数据模型。
- Tests：扩充 `BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift` 与 `PanelContextTests.swift`；如触及 `pinnedFile` 路径，扩充 `SessionStoreTests.swift`；如影响原生内容，扩充 `PaneRetentionTests.swift`。
- 文档：`docs/features/projects.md` 说明「手动添加项目」与「外部打开文件」不同意图；`docs/features/session-restore.md` 只有真实恢复契约变化才更新。

### Step 1：Red，证明现有行为及新增期望

建立独立临时目录、源文件与真实 `TerminalManager`。新增测试需先因缺少外部文件打开入口而失败，同时守住既有手动添加：

1. 手动连续 `addLocalItems([a.txt,b.txt])`：两个独立 file-pinned 项目、各自图标／`customName`／`pinnedFile` 不变；重复添加同一 URL 仍选旧项目；选择文件夹只新增／定位目录项目且**不启动终端**。
2. 外部打开位于现有**目录型本机项目**（`pinnedFile == nil`）根及深层子目录的文件：先找已有同一机器的真实 FileTab，再用实际已确认的**路径分量**选最深适用目录项目；`/tmp/app` 不能错误匹配 `/tmp/apple`。自动跟随 Shell 的项目只有在当前有效本机根确实覆盖文件且身份未改变时才可候选，不能把暂时处于 SSH 的自动项目当成本机根。
3. 本机有 file-pinned 项目且打开**同一文件**：保留原 `Project`、`PaneTab`、`FileTab`、dirty 和撤销；打开其**同级另一文件**时**不得把 file-pinned 项目当通用目录项目来复用**，应寻找真正目录项目或按需新建目录／独立文件项目，不能修改原有 `pinnedFile`、名称和归属。
4. 本机有同名 SSH 项目、正在 SSH 的自动项目、断线状态；只使用 `sshHost == nil` 且 `workspaceIdentity == nil` 的项目／标签，绝不触发远端后端。不同机器的同名路径不能判成已打开。
5. 没有可用本机项目时，单个文件复用现有「添加该文件为项目」能力；同批同目录多文件通过**一次创建／复用目录项目＋多次 `Project.openFile`** 建立同一范围，不为 N 个文件创建 N 个临时项目；不同目录按根分组。若批次同时含目录和其内部文件，先复用该明确目录而不是另造父目录项目；多个文件和目录混排保留用户文件选择的可理解顺序及最终焦点，不启动 Shell。
6. URL 非 `file://`、无路径、缺失、拒绝访问、符号链接与失效符号链接、Finder alias、`/var`／`/private/var` 等同一路径别名、大小写敏感盘的不同文件、中文／emoji／空格／引号／换行、空文件、重复顺序与混合目录文件；单批失败不阻断其他有效项，失败不能悄悄丢弃。系统传来 alias 目标还是 alias 文件须实测，不自行假设所有 Finder alias 都是普通目录。文件内容是 PDF／二进制／图片／大于 5 MiB 时保持现有 `FileTab` 结果，不增加格式解析器。
7. 既有目录项目已打开脏编辑或运行 Shell 时再调用外部打开，**原生编辑对象、用户编辑内容与 Shell 不被丢弃**；`TerminalManager.selectedProjectID`／`Project.selectedTabID` 的既有失焦自动保存可以合法写入旧文件，必须按此验证，不把原本自动保存误算为「外部打开修改磁盘」，也不让新逻辑额外写错目标；同时核对 `SessionStore` 中手动 `pinnedFile` 项目仍能按当前格式恢复。

### Step 2：Green／Refactor

- 实现 **`openExternalLocalItems(_ urls: [URL])`（实例级，名称允许依现有编码惯例调整）**，专门决定 Finder 式打开；用 `URL.isFileURL`、`standardizedFileURL` 和文件系统事实识别输入，聚合合法路径与必要错误。不要把 `addLocalItems` 当成全部外部打开的通用语义；它继续服务手动添加和新建项目。
- 已在本窗口某项目的本机 file tab → 选中该项目并 `Project.openFile` 定位；否则**只选择目录型本机项目**且确认文件在其真实范围内，再 `Project.openFile`。既有 `pinnedFile` 项目只复用自己的文件，不作为其同级全部文件的容器。找不到时依已有 `addLocalItems` 创建最小本机项目。自动项目的跟随范围可能随前台 Shell 变化，只有当前可靠本机根满足条件才参与，不能通过路径字符串把 SSH 误当 Mac。路径匹配核对分量、标准化与软链语义，不新增全局索引。
- 对批次中同目录的新文件**仅在确有多个需要同工作范围的文件时**一次选择／添加目录项目，逐个使用现有 `Project.openFile`；单文件继续沿原有文件项目能力。文件夹与其内文件混入同一批时复用该文件夹的真实 root；保留原顺序和最后可用文件的焦点，避免在项目之间反复跳动触发不必要失焦保存。目录本身沿既有添加目录行为。
- 如 P2 的实际 AppKit 文档打开入口需要回告，则让本批次产生**最小接受／拒绝结果**供系统回调使用；这只代表路由完成，不伪装异步正文已成功读取。不得为还没选择接收 API 就先建立大量 Result 枚举、跨任务 completion registry。失败用已有窗口对话框汇总呈现；无 attached window 时不直接 `runModal()`（交给 P1-T2 在附着后呈现）。`FileTab` 的容量、二进制和图片判断继续由原文件模型负责。不要对每个未证实的异常新建 error enum、队列或 fallback。
- 替代分支如有实际失效就在本任务清除；保留仍被原「添加」和 SSH 调用的 `addLocalItems`。本任务同时同步文档。

### Step 3：验证及原子提交

- Red → Green：`make test ONLY_TESTING=BaileyTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=BaileyTests/PanelContextTests`；若改动恢复或原生标签，分别执行 `SessionStoreTests`、`PaneRetentionTests`；再执行 `make build`、`make test`，核对**完整退出码**和真实执行的 XCTest 数量，`git diff --check`。
- 检查最终项目数、选择、`FileTab.id`、原生正文、dirty／已自动保存结果、磁盘字节和远端 fixture 访问次数，**不以方法返回成功替代内容打开**。区分原有失焦自动保存与不该出现的新写入；同时对照手动文件添加、目录添加、SSH 添加、关闭／重启语义。
- 未覆盖：系统 Finder／Dock 进程外事件、原生外部拖放属于 P2/P3，不在 P1 宣称完成；最低 macOS 15.6 无 runner 则明确记录与补验。覆盖和实际缺失遵循 `docs/testing.md`。
- 本 task 单独中文原子提交，正文写清根因和验证；文件修改只限本 task，Feature 文档按本地不入库政策保留，状态通过脚本更新。

---

## P1-T2

**独立结果：外部请求选中正确的已存在窗口；无窗口和恢复中的请求不会丢失或重复消费。**

**真实入口与根因：**
- `Bailey/App/FinderService.swift::openInBailey` → `TerminalManager.openDirectories`；系统服务将目录写入静态 `pendingDirectories`。
- `Bailey/Workspace/TerminalManager.swift::init` **在 attached window 前已会消费 pendingDirectories**；`attach(to:)` 也有消费；`requestWindowForPendingDirectories` 的短暂 runloop 延后已有启动理由，`WindowRootView.onAppear` 的 `openRestoredWindows` 又在下一轮打开剩余快照窗口。
- `windowClosed` 保留最后窗口快照并终止该窗 Shell；`WindowChromeAccessor` 的原生关闭保护和 `WindowRootView.onDisappear` 共同维护生命周期。不能把这些函数整段删除重写。

**Files：**
- Modify：`Bailey/Workspace/TerminalManager.swift`，将 Finder Service 和外部文件打开路由到正确已挂载管理者，扩展原有启动待处理能力；删除本任务中确实被替代的目录专用入口／变量，**仍被服务需要的转换逻辑保留最小一处**。
- Modify only if needed：`Bailey/App/FinderService.swift::openInBailey`（保持 NSServices selector 不变），`Bailey/App/BaileyApp.swift::WindowRootView`（保留一个 `WindowGroup`），`Bailey/UI/Components/WindowChrome.swift`（非必要不动）。
- Tests：`BaileyTests/Integration/Workspace/SessionStoreTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`、`WorkspaceWindowCloseTests.swift`、`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`、`AppMenuIsolationTests.swift`（只增加有关场景）。
- 文档：`docs/features/dock.md`、`docs/features/session-restore.md`、`docs/features/projects.md` 分别更新真正变化的窗口选择／恢复／新增入口契约；不复制测试总则。

### Step 1：Red，列明时序交点

1. 两个已 attached 的主窗口 A/B：A 为 key、B 为 main／仅后台；文件已在 B 打开时激活 B 与**原有**标签（避免两个不共享的脏缓冲）；文件只在 A 的本机目录中未打开时打开到 A；只有 SSH 项目时新建本机项目。
2. 普通放置请求携带**实际 NSWindow/manager**（P3 将调用）时，不误用 NSApp 当前 key window；但若同一本机文件已经在 B 编辑，优先定位 B，确保不同窗口不产生两个不共享的可写缓冲。用户应得到明确、可见的焦点反馈。
3. 仅设置窗口有焦点、没有 attached 主窗口、刚关闭最后一窗、WindowRootView 初始化但未 `attach`、`registerWindowOpener` 早于／晚于请求、多个连续 Finder / Service 批次：主窗口确实出现、每项只消费一次。
4. 保存的 1/2 个窗口快照与冷启动文件请求同到：后恢复窗口原有标签中的文件必须被识别；**先处理队列不应抢在第二个窗口恢复前制造重复 FileTab**。`openRestoredWindows` 的异步恢复确实到达后再验证消费窗口选择；不为此加任意 100ms/500ms 重试循环。
5. 关闭保存失败、窗口被关闭、`attach` 重复触发、设置窗口抢焦点、恢复带终端 Shell：错误反馈只到还活着的接收窗，后台 Shell／WebView／编辑器不被拆卸。
6. 老服务在文件夹粘贴板（NSFilenamesPboardType、fileURL）及无效选中项的行为保持：只接收目录，不把文件塞进旧服务；新入口允许目录＋文件的系统资源批次。

### Step 2：Green／Refactor

- 复用 `TerminalManager.registry`、已有窗口开启器和 attached-window 选择，新增**随窗口附着、恢复后排空的外部打开 URL 批次**待处理路径（仅冷启／无窗口等实际需要时）。按实际接收请求的生命周期管理，不设置任意 64 次硬拒绝；2026-10-19 的 F-11 复测已证实此限额会丢弃有效的晚到文件打开事件。原服务的 `pendingDirectories` 若仍在工作且两个意图时序不同，**继续保留**，不要为了「统一」强行混成一大队列；复用共用的窗口唤醒部分即可。若源代码和测试确证可以统一且减少状态，则本任务一并删除被替代分支，不保留两个窗口开启定时器。系统回告若需 completion，只保留单次请求的实际结果回调，不能长久悬挂。
- 保留旧 Finder Service 在 `TerminalManager.init` 取待处理目录的既有行为，除非被新实现**有实测证据地**等价替换。新系统打开请求若可能命中尚未恢复的第二窗口中的文件，需要在实际恢复窗口可判定后再去重路由；不能提前造第二个 FileTab，也不能依靠任意 100ms/500ms 睡眠。验收冷启动快照数量不同、最后窗口被关闭再打开和 `WindowRootView.onAppear` 竞态。
- 逐一查实际调用者：旧 `pendingDirectories`、`takePendingDirectories`、`requestWindowForPendingDirectories`、`openDirectories` **仍被 Finder Service 使用就保留**；只有真的被新共用路径完全替换时，在 P1-T2 **同一提交删除全部无引用死分支**。不要重写 `windowClosed` 和快照恢复；已有短暂窗口调度仅在原本必要时沿用一处，不增加重试轮询或仅为安抚竞态的 guard 链。
- `NSApp.keyWindow/mainWindow` 仅用于寻找 attached 的 Bailey 主窗口，不把 Settings 或无 owner 的原生测试窗口误当接收者；窗口与项目选中处理由所属 manager，不能在视图内缓存另一份 project selection。
- 窗口未附着时不弹 `runModal()`，一次失败批次汇总到实际接收窗口；取消／失效不能打开无主窗口。继续用当前关闭与恢复快照保护。

### Step 3：验证及原子提交

- Red → Green：`make test ONLY_TESTING=BaileyTests/SessionStoreTests`、`make test ONLY_TESTING=BaileyTests/WorkspaceWindowIsolationTests`、`make test ONLY_TESTING=BaileyTests/WorkspaceWindowCloseTests`，以及受影响的 `PaneRetentionTests`、`AppMenuIsolationTests`；完整 `make build`／`make test`／`git diff --check`。
- 原生 `NSWindow + NSHostingView(ContentView(manager:))` 检查最终编辑内容、窗口焦点、打开的标签对象、恢复快照、Shell 进程身份、Service 原有结果。测试须明确隔离与用户前台交互；不使用真实用户进程制造冷启。
- 无法从 XCTest 宿主直接证明 Finder、Dock 进程外回调，P2 真机 E2E 另有强制 Gate。不能因为本 Task 模型测试绿就声称 Launch Services 已接通。
- 本 task 独立中文提交，同步以上文档并只清理**当前替换**的旧队列和失效入口。

---

## Phase Audit

只在 P1 两个任务实际完成后由执行流程创建 `audit-p1.md`；审查当前源码与提交，而不是提前产出意见文件。核对本阶段没有改动手动 `pinnedFile` 项目语义、没有复制 SessionStore 状态、没有平行队列或定时器、没有两个可写的同文件缓冲；全部适用用户路径与边界按 `docs/testing.md` 留证。
