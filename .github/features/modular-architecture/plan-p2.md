# P2：Files / Git / Info 面板职责与真实生命周期

**Goal：** 把三套面板 UI 移出混合文件，并处理源码已确认可达的连接状态与异步范围错配；不建立新容器或重写业务模型。

**Non-goals：** 不改变 Kero 的标签外观、菜单和面板功能；不增加全局刷新服务、事件总线、统一后端协议或多层防护状态。

**Approach：** 依次抽离 Files、Git、Info 的已有 View/私有 helper，每次完成编译接入并删除旧定义；最后在各自真实所有者上收敛两条已识别的状态链：`PortForwardController` 的连接生命周期，以及 Git/Info 异步结果的工作区范围。

**Acceptance：** `ToolPanelView` 只负责工具标签的渲染选择和当前必要的生命周期触发，Files/Git/Info 的 UI 源码各有唯一归属；Git 提交草稿不归临时 View，从工具标签离开再回来不会丢失草稿或既有 SSH 转发记录；Git/Info 不显示来自旧项目/旧工作目录的返回值。

**Rules：** `GitStatusModel` 仍由 `ContentView` 作为窗口级状态持有，`Project.fileTree` 持有 Files 模型；`PanelSyncQueue` 已合并远端目录刷新，不因拆分而新增并行轮询。`RemoteConnection` 执行 SSH 转发，销毁视图不是停止 SSH 的理由。

---

<a id="p2-t1"></a>
## P2-T1 抽离 Files 面板与唯一共享标题

**Files：**
- 从 `kero/UI/Panels/ToolPanelView.swift` 移出 `PanelHeader` → `kero/UI/Panels/PanelHeader.swift`。
- `GitSectionHeader` 实际同时被 Git 与 Info 的八处入口使用；同任务改名为 `PanelSectionHeader` 并整体移到 `kero/UI/Panels/PanelSectionHeader.swift`，包括 `Action`、折叠、帮助 Popover 和无障碍，不留旧名 alias。不能把它当成 Git 私有类型。
- 移出 `FileTreePanel`、`FileTreeScrollView`、`FileTreeRow` 及 Files 独有 helper → `kero/Files/FileTreePanel.swift`；删掉原文件中相应定义。
- `ToolPanelView` 仍按 `Project.fileTree`、`git` 与文件打开/重命名闭包调用它，公共行来自 P1 的 `Shared/Tree`。

**依据：** 原文件 `// MARK: - File tree` 下的类型由 `ToolPanelView.body` 唯一实例化；`PanelHeader`、`GitSectionHeader` 都有跨面板消费者，不应该复刻。文件末尾的文件级 `shellQuote` 由 Files 的 “cd Here” 使用，必须随 Files 一起迁移；不能漏掉，也不能保留在混合文件中迫使新文件扩大可见性。

**实施：** 原样移动相关视图与 helper，同一提交移除旧定义、无用 import 和错误源码路径；`docs/PERFORMANCE.md` 引用 FileTreePanel/旧 ToolPanel 路径的地方当场更新。清理所触及文件中“固定右侧栏”一类已失效的注释，不改变文件操作目标选择，也不在此时新增 `FilesController` 或根目录解析方案。

**验证：** Debug 编译/签名，原生 Files 面板的创建/重命名/打开、项目范围、目录压缩、状态颜色与按钮命中；运行 P1 对应文件树与树行检查；确认没有第二份 `PanelHeader`、`FileTreeRow` 或 `TreeRowSurface`。

**提交边界：** Files 显示与共享标题归位、旧定义当场删除，一个原子提交。

---

<a id="p2-t2"></a>
## P2-T2 抽离 Git 面板和破坏性操作确认 UI

**Files：**
- 从 `ToolPanelView.swift` 的 `// MARK: - Git panel` 移出 `GitPanel`、`GitEntryRow`、`NonemptyTextFieldValidator` 以及仅供 Git 使用的私有类型 → `kero/Git/GitPanel.swift`；分区标题使用 P2-T1 的共享 `PanelSectionHeader`。
- 保留 `GitStatusModel`、`RecentCommitsView`、`DiffViewerView` 原位置和窗口级状态；同任务删除原 GitPanel 旧定义。

**依据：** GitPanel 内 `PendingDiscard`、指纹对照、`EntryOperation`、`OperationTrigger` 保护实际丢弃/暂存操作，属于 Git 操作 UI，不是通用表单逻辑。

**实施：** 一次性迁移 GitPanel 的私有 helper、确认弹窗、操作闭包与原有按钮样式；保留 `openDiff/openCommitDiff` 路径和对唯一共享树组件的引用。不因为文件超过 1,000 行拆出无用途的额外 ViewModel/Protocol。

**不能仅原样移动的状态：** `GitPanel.commitMessage` 现在是 View 的 @State，Dock 挂载不同工具/分组时可丢失用户输入；它还只随 repositoryIdentity（路径）重置，没有区分同名远端。把提交草稿交给现有窗口级 GitStatusModel，以机器 scope + 已确认 repoRoot 保存/绑定各仓库的草稿，沿用已有按范围保存状态的简单字典方式，不新增 DraftStore/ViewModel/磁盘持久化。GitPanel 删除自己的 commitMessage 和 `resetRepositoryDrafts` 对它的清空；确认弹窗、hover、过滤等短期交互仍留在 View。提交完成后的清空由模型比较本次仓库/提交文本再执行，失败或用户已改写文本时保留草稿，不能清掉另一个目标的输入。

**同任务立即清理无用的模型状态：** `GitStatusModel.Entry.mergeRowID/stagedRowID/changedRowID` 和 `Operation.isSuccess` 没有消费者；`loadedDetails` 在每个实际发布的 repository snapshot 中必为 true。删除这些属性、字段、赋值和恒真条件包装，保留原状态更新及实际树行 ID。该任务已经修改窗口级 Git 状态，不把这些清理拖到 P4 的 runner 提取或 P5。

**验证：** 签名 Debug 的 Git 工作/暂存与历史树、分支/菜单、Diff 打开、焦点与弹窗；输入提交消息后切工具、关闭重开 Git、移组、切项目再回来，草稿保留且同名不同机器不串用。模型回归至少覆盖失败保留、提交期间文本已改变不清空、成功仅清空匹配目标/文本；**仅在独立测试仓库**实测暂存/取消暂存/丢弃/提交，检查最终 Git 文件/索引/提交消息，不拿 UI 回调成功代替提交完成。共享树原生命中回归、编译/签名与旧类型删除检查均通过。

**提交边界：** Git 面板迁移、提交草稿归属和旧 UI/无用模型状态即时清理，一个原子提交。

---

<a id="p2-t3"></a>
## P2-T3 抽离 Info 面板及其数据模型

**Files：**
- `git mv kero/Terminal/SessionInfoModel.swift kero/Info/SessionInfoModel.swift`。
- 从 `ToolPanelView.swift` 的 `// MARK: - Info panel` 移出 `InfoPanel`、`InfoProcessRow`、`InfoPortRow` 及专属 helper → `kero/Info/InfoPanel.swift`；旧实现同步删除。
- 保留 `ToolPanelView` 对 `SessionInfoModel` 的创建与现有 `InfoPanel(model:session:sshHost:forwards:)` 调用，P2-T4/T5 才处理被确认不稳定的生命周期。

**依据：** `SessionInfoModel` 的目录/进程/端口扫描只服务 Info，原来位于 Terminal 是物理归属错误。远端 pid/端口仍通过 `WorkspaceBackend`，不可换为 Mac 本地 pid。

**实施：** 模型与其消费 View 在**同一个任务**归入 Info；按真实引用最小调整可见性、文档和旧路径，同时清理所触及代码及 `RemotePaneHeaderView.swift` 中“固定右侧栏”的旧注释（只更正文案，不重写已有 AppKit 头部），不新增 `InfoService` 或单独刷新架构。

**验证：** Debug 签名构建；本地 Info 显示工作目录、进程/端口和作用于正确 PID 的操作；有可用 SSH 时确认远端目录与端口，断线/重连后展示正确主机。旧 `Terminal/SessionInfoModel.swift`、旧 Info 视图定义必须不存在。

**提交边界：** Info 模型与视图唯一归属同一个原子提交。

---

<a id="p2-t4"></a>
## P2-T4 让 SSH 转发记录跟随连接，而非工具 View

**Files / 已确认链路：** `WorkspaceDockView.DockTabGroupView.content` 切换 `ToolPanelView`；`ToolPanelView.@State PortForwardRegistry` 为 `RemoteConnection` 分配 `PortForwardController`；`PortForwardController.localPortsByRemote` 记录已经建立的 SSH 转发；`TerminalSession` 持有远程连接。

**源码可证明的缺口（尚非 SSH 实测结论）：** `PortForwardRegistry` 只由可卸载的工具 View 持有。`DockTabGroupView.content` 切换选中工具会移除原 View；重建 Info 时创建空 controller，但 SSH 转发仍存在。`TerminalSession.beginRemoteConnection` 会在同一 session 内替换连接，`lastRemoteConnection` 还会保留前一连接；按 session 保存一张不区分连接的表也不正确。

**实施：**
1. 明确由 `RemoteConnection` 持有一个惰性创建的现有 `PortForwardController`；工具 View 只取该引用。controller 对连接使用弱引用，并在发起异步请求时取得本次连接的强引用，避免 `connection → controller → connection` 循环。连接已释放时走现有 `notConnected` 错误，不造新的 Registry、协议或重连状态机。
   当前 `RemoteConnection` 还惰性持有 `workspaceBackend/livenessBackend`，而 `SSHWorkspaceBackend.runner` 强持有该连接，已经构成另一个可由源码直接证明的循环。两者改为按需返回现有轻量 backend，仍由使用它的模型/请求持有；创建 backend 不执行 I/O，无需为此新增 weak-runner 协议、缓存或所有权容器。短 liveness timeout 保持 3 秒，普通 backend timeout 不变。请求身份使用连接 id，不使用新建 backend 的对象地址。一起验证释放最后一个实际使用者后连接可释放。
2. 同任务删掉 View 中旧 `PortForwardRegistry` 与不再使用的分配路径。断线仍由现有 `connection.$state` 清理记录。源码中没有用户取消会话转发的入口；`PortForwardController.cancel/cancelAll` 及其唯一调用的 `RemoteConnection.cancelForward` 是无消费者辅助链，同任务删除，不为验证它们新增取消按钮或菜单。独立长期隧道的禁用/停止路径不受影响。
   `RemoteCommands.freeLocalPort/forwardSpec/forwardArguments/cancelForwardArguments` 只被从未调用的 `RemoteCommands.runSelfCheck` 引用，实际请求由 `RemoteConnection.forward` 完成；删除这条旧辅助链。把该 DEBUG self-check 中仍服务现行端口占用/SSH 参数/转义的断言迁到可运行的 `scripts/check-remote-commands.swift`，删掉针对淘汰 API 的断言与 App 内无调用的测试体。不删除 `isLocalPortFree`：会话转发与长期隧道都真实使用它，IPv4/IPv6 和 wildcard 占用检查防止打开错误服务。`TunnelStore.runSelfCheck` 由 TunnelManager 真正调用，不按同名测试一并删除。
3. Info 的端口显示必须观察 controller 的发布变化。当前只读取可选引用，`localPortsByRemote` 更新不保证触发 View 重绘；复用现有端口行/面板的观察方式修正，不把转发状态复制到 Info 模型或另一张表。
4. 对照实际 UI：打开/复制远端端口后立即显示实际本机端口；切标签、关闭重开 Info、移动停靠后复用同一连接的同一转发；退出交互 SSH 后该监听结束、记录消失。网络临时失联的 `.disconnected` 只证明记录清空，不等于 master 已退出或监听已关闭，不能这样写验收结论。

**验证：** 同任务做不发起 SSH 的连接/controller/backend 引用寿命轻量检查；不为模拟转发成功给生产代码增加协议或注入层。重复打开/复制的请求合并、实际本机端口与监听寿命在签名 Debug + 安全可用的真实 SSH 上验证，并检查页面/剪贴板最终结果，不仅看方法返回成功。不能连接时标明这些端到端行为未测，不宣称 UI 可取消。确认旧 Registry、无调用取消链已删除，独立 `TunnelManager` 仍能停止规则；`git diff --check`。

**提交边界：** 转发记录生命周期修复与旧视图缓存同步删除一个提交。

---

<a id="p2-t5"></a>
## P2-T5 收敛同一项目内异步范围校验

**Files / 实际调用：**
- `kero/UI/ContentView.swift::syncGit`：异步 `project.panelRoot(...)` 后只校验 `selectedProjectID`；同一个项目内连续 cd / SSH 切换时旧 root 可能晚返回并触发 `git.sync`。
- `kero/UI/Panels/ToolPanelView.swift::performSync`、`Project.panelContext/panelRoot`、`FileTreeModel.sync/rebuild`。
- `kero/UI/CommandPaletteView.swift::fileIndexRoot/.task`：文件索引实际只用本机 Git/FileManager，却只把 root 字符串当作任务身份；远端目录与本机同名时可把本机结果交给当前远端项目打开。
- `kero/Info/SessionInfoModel.swift::sync/refresh`：当前刷新返回只比较 `shellPid`，不同 SSH 主机的相同 PID 不能代表同一工作区。

**依据：** `FileTreeModel.rebuild` 已对 root 与 scope 进行回写检查，`GitStatusModel` 已有 `contextGeneration/statusRequestID`，不应再叠加一个大范围 Coordinator。缺口在**计算根目录之后、写入当前状态之前**的特定调用点。

**实施：** 将当前 `Project.panelContext` 的数据及必要的请求身份收敛在 Project 的同一处：两条调用链均校验实际决定本次目标的输入，再应用异步 root，不在两个 View 复制身份拼接。自动跟随终端时需覆盖项目、cwd、foreground、会话及交互 SSH 连接身份/状态；固定目录只绑定其项目/机器/目录，不因无关终端的 cd 或 SSH 状态改变而丢弃有效 root。`scope` 是机器身份，不等于连接实例，自动远端不能只比 `scope`。Info 另外捕获实际用于本次进程表的 pid 与目标身份，完成后核对同一目标，不能在返回时用新目标的 `isRemote/localShellName` 解释旧进程表。切换目标时旧进程/端口行不得继续作为新 backend 的操作对象：当前 `sync` 先换 backend 却保留旧行，`kill(pid:)` 可将旧 PID 发给另一台机器；在目标切换处使旧行失效，而不是另加一层全局安全框架。复用现有串行/合并状态；若重定向发生在刷新期间，保证最后一个有效目标仍得到刷新，而不只丢弃旧结果。`PanelSyncQueue`、Files root/scope 与 Git 状态代次的不同职责保留，不叠加全局 generation/缓存/轮询。固定 SSH 项目的 Info 当前只有目录信息，不借此增加进程/会话转发能力。

**进程操作边界：** 清空旧行不等于延迟菜单动作已经失效。行的 kill 动作须捕获原进程目标，模型在实际执行 kill 的共同入口核对；即使新目标进程表也出现相同 PID，旧动作不能转而操作它。进程目标只由实际机器/连接、会话 PID 决定，不因无关 cwd/root 改变而失效。复用该目标值，不在每个按钮加独立判断或新增安全管理层。

**命令面板的同一机器边界：** 保留现有本机文件索引，不新增 SSH 搜索功能；只为本机目标索引，任务与结果绑定发起时的项目/目标/root。远端目标不能用本机 FileManager 检查同名 root，也不能把残留本机文件行作为远端打开动作。复用 Project 的目标判定，保留子模块索引失败后的真实 fallback 和普通目录枚举；这是当前可达的机器错配，不是预设防护。

**Files 最终副作用也属于这条链：** FileTreeModel 的 rename/create/delete 已捕获 backend/root/scope，保留这些有效校验；不是再给每次 await 叠 generation。补齐 UI 两个真实边界：远端删除的 modal 确认返回后，原行目标必须仍匹配才允许调用模型；新文件异步创建返回后，`openFile` 不能无条件跳到 manager 此时选中的另一个项目/机器。使用发起时的 Project/目标及现有模型范围判断，在进入操作和应用后续打开动作的边界检查；重命名的 workspace 已随回调捕获，不复制另一套文件操作管理者。

**验证：** 同任务留下最小可运行回归检查，沿用 `scripts/check-*.swift` 的轻量方式，用现有 `WorkspaceBackend` 的延迟实现控制返回顺序：自动目标的 cwd/foreground 改变、同路径不同机器、同机器不同连接、相同 pid 换目标；断言旧结果不发布、旧行不向新 backend 发 kill、最后一次有效刷新会完成。还需覆盖旧菜单动作在新目标已有同 PID 行后执行，仍不向新 backend 发 kill。固定目录在无关终端 cd/SSH 切换后仍有效，同一进程目标不随无关目录变化失效，防止过度失效。Files 延迟创建期间切项目，不在新项目打开旧文件；删除确认期间切目标，不向新目标发送删除。不启动 SSH 或真的 kill/delete 用户资源，不为测试新增生产协议。签名 Debug 验证命令面板本机搜索/子模块 fallback 和本机→同名远端切换不残留本机文件结果，再做面板快速切换与可安全连接的 SSH 验收；缺 SSH 不影响确定性模型检查，但远端端到端明确记为未测。

**提交边界：** 精确修复异步根目录/进程范围错配并删除被取代的旧判断，一个提交，不新建框架。

---

## P2 完成条件

原混合 `ToolPanelView.swift` 不再容纳三套面板 UI、Files/Info 数据模型也已归位。任何新接入均已同时移除旧定义；不把残留留给 P5。没有 SSH 实机证据的条件不冒称通过。
