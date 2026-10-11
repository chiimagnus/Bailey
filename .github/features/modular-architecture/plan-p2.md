# P2：按功能拆分 Files / Git / Info 面板

**Goal：** 结束 `ToolPanelView.swift` 同时拥有三套大型 UI 实现的结构，让 Files、Git、Info 各自维护界面；保留一个足够轻的标签组面板宿主，明确现有异步刷新/连接对象的生命周期。

**Non-goals：** 不改变侧栏/标签外观、菜单或弹窗；不重写 Git 操作/Info 扫描算法；不为了视图拆分新建通用 Controller、Store 或 Protocol。

**Approach：** 先实测跨项目、跨标签和远程断线时 View/模型的实际重建和任务取消；再一次一个面板迁移**现有**类型、关联 helper 和布局。分离单个共享标题头后，原宿主保留通用环境/刷新入口；再沿实际调用链收敛场景选择，避免把本地/SSH 安全决策写在视图里。

**Acceptance：**
- `ToolPanelView.swift` 不再内含 Files/Git/Info 三个庞大的视图及其私有行类型；三个面板可以独立定位源码，不复制树语义或操作实现。
- 终端工作目录变化、项目切换、窗口重建、SSH 重连不会使旧刷新覆盖新工作区；Git 不被新增无条件轮询。
- Git 丢弃/暂存/提交/历史 diff、Files 新建/重命名/打开、Info 端口转发均与 P1 基线一致；面板位置与项目数据范围无关。

**Rules：** 当前 `ToolPanelView` 的 `PanelSyncQueue` 合并异步请求，`Project.panelRoot` 计算面板工作区根，`FileTreeModel.sync` / `SessionInfoModel.sync` / `GitStatusModel.sync` 分别消费结果；不得在拆文件时凭直觉改写这些路径。`PortForwardRegistry` 与 `RemoteConnection` 的生命周期须有 P2-T1 证据才能改变。

---

<a id="p2-t1"></a>
## P2-T1 核对面板生命周期与异步回写时序

**类型 / 依赖：** 最小只读实验；依赖 P1 全部任务，先产证据，不实施架构改写。

**源头与真实路径：** `kero/UI/WorkspaceDockView.swift::DockTabGroupView.content` 建立 `ToolPanelView`；宿主内 `@StateObject SessionInfoModel`、`@State PanelSyncQueue`、`@State PortForwardRegistry`、`applyRemoteHeading()`、`performSync()`；后者通过 `Project.panelContext/panelRoot` 和 `WorkspaceBackend` 进入 Files/Info；`ContentView` 持有窗口级 `GitStatusModel`。

**操作与决策：**
1. 用 CodeGraph 追踪宿主显示条件与 `@StateObject`/异步任务的实际生命周期，确认切项目、工具标签在外层分屏间移动、关闭再加入、切换本地/SSH 时对象是否重建；对照窗口创建/重建和端口转发的现有持有者。
2. 在签名 Debug 隔离场景做最少量可观察实验：Files/Info 正在刷新时切项目；终端快速 `cd` 改变目录；SSH 连接变更/断线期间离开、重返面板。核对最终目录、Git 范围、Info 端口显示和连接状态，而非只看请求完成日志。
3. 如发现实际失效/资源泄漏，记录触发顺序、唯一应持有状态的对象和一项最小修复路径；如没有证据，仅记录现有 `PanelSyncQueue` 与各 Model 已满足的条件，不提前增加服务。结果写入本地 `evidence-p2.md`，用于决定 P2-T5 是否需要移动状态持有者。

**验证：** 对每个路径分别记录操作、最终可见结果、对象生命周期证据、未覆盖的 SSH 场景；不得将“AX 点击成功”算为面板刷新成功。只读实验无 Git 提交。

---

<a id="p2-t2"></a>
## P2-T2 独立 Files 面板并保留共享标题

**类型 / 依赖：** 原子源码迁移；依赖 P2-T1。

**Files / 锚点：**
- Extract from `kero/UI/Panels/ToolPanelView.swift`: `FileTreePanel`、`FileTreeScrollView`、`FileTreeRow` 及仅 Files 使用的辅助类型/方法（目前位于 `// MARK: - File tree`）。
- New: `kero/Files/FileTreePanel.swift`。
- Move shared `PanelHeader` into `kero/UI/Panels/PanelHeader.swift`（它当前被多个面板使用，不能复制三份）。
- Update: 原宿主中 `FileTreePanel(...)` 的构造引用；使用 P1 的 `Shared/Tree`。

**当前依据：** `ToolPanelView` 通过 `Project.fileTree`、窗口级 `git`、`manager.openFile/openFileToSide`、`manager.fileRenamed` 与 `git.refresh` 给 FileTreePanel 传入操作闭包；业务范围取自当前项目和 `fileActionSession`。

**实施：** 将现有 Files 视图及关联私有 helper 整体移出，跨文件需要访问的类型仅做最小访问控制调整，移完即删除旧定义；共用标题保留一份。宿主中的回调、Files 根目录状态、压缩目录/展开、文件动作和刷新触发保持原样。

**验证：** 更新路径后的 Files/共享树检查及 Debug 构建/签名；真机检查本地/SSH 文件、项目切换、固定目录、打开/新建/重命名、Git 文件颜色/压缩目录/点击命中、长名称和键盘导航；对照 P1 基线。运行 `git diff --check`、`rg` 确认无重复 PanelHeader/TreeRow。

**提交边界：** Files 面板及共享标题抽离一个中文原子提交，包含必要最小引用更新。

---

<a id="p2-t3"></a>
## P2-T3 将 Git 面板与操作确认 UI 归入 Git

**类型 / 依赖：** 原子源码迁移；依赖 P2-T2。

**Files / 锚点：**
- Extract from `kero/UI/Panels/ToolPanelView.swift`: `GitPanel`、`NonemptyTextFieldValidator`、`GitSectionHeader`、`GitEntryRow` 及仅被其使用的私有 helper（从 `// MARK: - Git panel` 至 `// MARK: - Info panel`）。
- New: `kero/Git/GitPanel.swift`。保留现有 `GitStatusModel.swift`、`RecentCommitsView.swift`、Diff 视图位置不变。
- Consumer: `ToolPanelView` 的 `.git` 分支、`PanelHeader` 与 `Shared/Tree`。

**当前依据：** GitPanel 内有暂存/取消暂存/丢弃、提交/分支等操作、文件指纹与确认状态；这些是操作安全的一部分，不能因为“纯 UI 拆分”遗漏状态或确认前检查。

**实施：** 原样迁移 GitPanel 和其私有辅助类型，避免把 Git 的破坏性确认或仓库路径判断抽象成通用面板功能。移除原文件旧定义，保持 `openDiff` / `openCommitDiff`、刷新和提示走现有调用链。

**验证：** 签名 Debug 真机逐项验收 Git 未提交、暂存、冲突、提交历史和 diff；在专门的**测试仓库**进行暂存/撤销/丢弃和提交（不要触碰用户真实项目）；本地/SSH 状态及远程失败提示保持原样。共享树命中检查通过；确认没有新增 Git 轮询、重复操作/数据副本，`git diff --check` 通过。

**提交边界：** Git 面板 UI 与其现有私有辅助类型一个提交，行为不变。

---

<a id="p2-t4"></a>
## P2-T4 Info 面板 UI 与子行独立归属

**类型 / 依赖：** 原子源码迁移；依赖 P2-T3。

**Files / 锚点：**
- Extract from `kero/UI/Panels/ToolPanelView.swift`: `InfoPanel`、`InfoProcessRow`、`InfoPortRow` 及其私有视图 helper。
- New: `kero/Info/InfoPanel.swift`。
- Check: `Info/SessionInfoModel.swift`（P1 移入）、`Remote/PortForwardController.swift` 与 `ToolPanelView` 原有 `forwards` 参数。

**当前依据：** InfoPanel 负责目录、子进程、监听端口及转发操作的显示；宿主 `applyRemoteHeading` 通过 Session/RemoteConnection 选择本地或 SSH 内容。

**实施：** 原样移动 Info 面板及局部显示/交互状态，仍从宿主接收 `SessionInfoModel` 和 `PortForwardController`；不自行创建第二套远程连接或计时刷新机制。移动后去掉旧定义。

**验证：** Debug 签名构建；Info 本地 PID、端口、目录展示与操作正确；SSH 端口转发入口、权限/失败反馈与断线状态不变，跨项目切换未把旧主机映射到新项目；`git diff --check`。

**提交边界：** Info 视图及子行一个提交。

---

<a id="p2-t5"></a>
## P2-T5 收敛宿主中的工作区选择和刷新责任

**类型 / 依赖：** 单一业务边界改造；依赖 P2-T1 证据与 P2-T2～T4 的独立迁移。

**Files / 锚点：**
- `kero/UI/Panels/ToolPanelView.swift::fileActionSession`、`workspaceEpoch(of:)`、`performSync()`、`PanelSyncQueue`、`applyRemoteHeading()`。
- `kero/Workspace/Project.swift::workspaceBackend`、`panelContext`、`panelRoot(...)`。
- `kero/Files/FileTreeModel.swift::sync`、`kero/Info/SessionInfoModel.swift::sync`、`kero/Git/GitStatusModel.swift::sync/refresh`。

**当前依据：** 固定本地项目下的文件动作必须不跟随交互 SSH 会话；旧连接/项目的异步结果不得写进新项目。宿主目前在 View 内同时决定范围、序列化刷新和调用具体模型。

**实施：**
1. 将**工作区范围和文件操作目标的业务判断**归到现有 `Project` 的上下文选择位置，宿主只读取可用结果、触发相应模型刷新，不重复计算安全/范围规则。沿项目身份、scope 与现有 generation/请求标识核对结果，不叠加新一层通用计时器。
2. `PanelSyncQueue` 的请求合并行为、Git 的事件触发和 2 秒可见面板刷新路径保持不变；P2-T1 若证明某个对象因 View 重建丢失，再把**该对象**移到已经存在的适当窗口/项目/连接持有者，不为理论问题增加全局单例或协议。不得让移入业务层的刷新变成无条件后台轮询。
3. 同任务删除宿主里已被替代的重复范围判断和无效 helper，保留必要的 `RemotePaneHeaderHost` 和轻量渲染切换。

**验证：** 有针对性的源码回归与签名 Debug：快速切项目/切标签、前景工作目录与固定目录、SSH 连接状态变化、Files/Git/Info 同步、关闭后资源释放，确认最后一个刷新事件没有丢失且旧结果不能覆写新范围。比较主线程/远程调用次数，至少确认无新轮询或明显重复请求；`git diff --check`。

**提交边界：** 面板工作区上下文的唯一归属及同任务移除冗余判断，一个独立提交；若 P2-T1 已证实无需移动某个状态，不为形式增加额外层。

---

## 阶段审查准入

- 原 `ToolPanelView.swift` 中不再含各面板的整套 UI 定义，Files/Git/Info 的真实行为仍由原模型驱动；重复类型或空壳转发文件为审计失败。
- 没有证据时不把视图内 `@State` 或刷新任务自动视为缺陷；确有生命周期失效的按 P2-T1 证据最小修复。
- 阶段审计时创建 `audit-p2.md`，此时不预建。
