# P2：Files / Git / Info 面板职责与真实生命周期

**Goal：** 把三套面板 UI 移出混合文件，并处理源码已确认可达的连接状态与异步范围错配；不建立新容器或重写业务模型。

**Non-goals：** 不改变 Kero 的标签外观、菜单和面板功能；不增加全局刷新服务、事件总线、统一后端协议或多层防护状态。

**Approach：** 依次抽离 Files、Git、Info 的已有 View/私有 helper，每次完成编译接入并删除旧定义；最后在各自真实所有者上收敛两条已识别的状态链：`PortForwardController` 的连接生命周期，以及 Git/Info 异步结果的工作区范围。

**Acceptance：** `ToolPanelView` 只负责工具标签的渲染选择和当前必要的生命周期触发，Files/Git/Info 的 UI 源码各有唯一归属；从工具标签离开再回来，不会丢失既有 SSH 转发记录；Git/Info 不显示来自旧项目/旧工作目录的返回值。

**Rules：** `GitStatusModel` 仍由 `ContentView` 作为窗口级状态持有，`Project.fileTree` 持有 Files 模型；`PanelSyncQueue` 已合并远端目录刷新，不因拆分而新增并行轮询。`RemoteConnection` 执行 SSH 转发，销毁视图不是停止 SSH 的理由。

---

<a id="p2-t1"></a>
## P2-T1 抽离 Files 面板与唯一共享标题

**Files：**
- 从 `kero/UI/Panels/ToolPanelView.swift` 移出 `PanelHeader` → `kero/UI/Panels/PanelHeader.swift`。
- 移出 `FileTreePanel`、`FileTreeScrollView`、`FileTreeRow` 及 Files 独有 helper → `kero/Files/FileTreePanel.swift`；删掉原文件中相应定义。
- `ToolPanelView` 仍按 `Project.fileTree`、`git` 与文件打开/重命名闭包调用它，公共行来自 P1 的 `Shared/Tree`。

**依据：** 原文件 `// MARK: - File tree` 下的类型由 `ToolPanelView.body` 唯一实例化；公共 `PanelHeader` 被多个工具面板使用，不应该复刻。调整 `private` 访问仅限真实跨文件调用。

**实施：** 原样移动相关视图与 helper，同一提交移除旧定义、无用 import 和错误源码路径；`docs/PERFORMANCE.md` 引用 FileTreePanel/旧 ToolPanel 路径的地方当场更新。清理所触及文件中“固定右侧栏”一类已失效的注释，不改变文件操作目标选择，也不在此时新增 `FilesController` 或根目录解析方案。

**验证：** Debug 编译/签名，原生 Files 面板的创建/重命名/打开、项目范围、目录压缩、状态颜色与按钮命中；运行 P1 对应文件树与树行检查；确认没有第二份 `PanelHeader`、`FileTreeRow` 或 `TreeRowSurface`。

**提交边界：** Files 显示与共享标题归位、旧定义当场删除，一个原子提交。

---

<a id="p2-t2"></a>
## P2-T2 抽离 Git 面板和破坏性操作确认 UI

**Files：**
- 从 `ToolPanelView.swift` 的 `// MARK: - Git panel` 移出 `GitPanel`、`GitSectionHeader`、`GitEntryRow`、`NonemptyTextFieldValidator` 以及仅供 Git 使用的私有类型 → `kero/Git/GitPanel.swift`。
- 保留 `GitStatusModel`、`RecentCommitsView`、`DiffViewerView` 原位置和窗口级状态；同任务删除原 GitPanel 旧定义。

**依据：** GitPanel 内 `PendingDiscard`、指纹对照、`EntryOperation`、`OperationTrigger` 保护实际丢弃/暂存操作，属于 Git 操作 UI，不是通用表单逻辑。

**实施：** 一次性迁移 GitPanel 的私有 helper、确认弹窗、操作闭包与原有按钮样式；保留 `openDiff/openCommitDiff` 路径和对唯一共享树组件的引用。不因为文件超过 1,000 行拆出无用途的额外 ViewModel/Protocol。

**验证：** 签名 Debug 的 Git 工作/暂存与历史树、分支/菜单、Diff 打开、焦点与弹窗；**仅在独立测试仓库**实测暂存/取消/丢弃/提交，确保最终 Git 文件和 UI 结果正确。共享树原生命中回归、编译/签名与旧类型删除检查均通过。

**提交边界：** Git 面板整体迁移 + 旧实现当场清理，一个原子提交。

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

**已观察的源码缺口：** `PortForwardRegistry` 只由可卸载的工具 View 持有。离开或关闭 Info 后重建 View，会创建空的 `PortForwardController`，但现有转发仍由 SSH 连接管理；UI 将不再认出此前的端口。它与工具停靠后的视图生命周期直接相关，不是理论上的未来扩展。

**实施：**
1. 选择当前连接的真实长寿命持有者（优先 `TerminalSession`，核对连接是否会在同一 session 内替换），让一个连接对应现有的 `PortForwardController`；视图只取引用。不得把 controller 强持有回其 `RemoteConnection` 造成循环引用，也不创建应用级转发注册中心。
2. 同任务删掉 View 中旧 `PortForwardRegistry` 与不再使用的分配路径。断线仍由现有 `PortForwardController` 的 `connection.$state` 清理端口记录；显式取消仍走 `RemoteConnection.cancelForward`。
3. 对照实际 UI：先打开一个远端端口 → 切别的标签 → 回 Info → 应仍显示同一个已转发端口并可取消；连接断开后记录消失。若现场缺 SSH，仅可报告未做端到端，不追加无证据的重连状态机。

**验证：** 签名 Debug + 安全可用的真实 SSH 连接上验证上述端口操作；不新增监听、不会复制远程请求；确认旧 Registry 不再使用、`PortForwardController` 的唯一生命周期可解释，`git diff --check`。

**提交边界：** 转发记录生命周期修复与旧视图缓存同步删除一个提交。

---

<a id="p2-t5"></a>
## P2-T5 收敛同一项目内异步范围校验

**Files / 实际调用：**
- `kero/UI/ContentView.swift::syncGit`：异步 `project.panelRoot(...)` 后只校验 `selectedProjectID`；同一个项目内连续 cd / SSH 切换时旧 root 可能晚返回并触发 `git.sync`。
- `kero/UI/Panels/ToolPanelView.swift::performSync`、`Project.panelContext/panelRoot`、`FileTreeModel.sync/rebuild`。
- `kero/Info/SessionInfoModel.swift::sync/refresh`：当前刷新返回只比较 `shellPid`，不同 SSH 主机的相同 PID 不能代表同一工作区。

**依据：** `FileTreeModel.rebuild` 已对 root 与 scope 进行回写检查，`GitStatusModel` 已有 `contextGeneration/statusRequestID`，不应再叠加一个大范围 Coordinator。缺口在**计算根目录之后、写入当前状态之前**的特定调用点。

**实施：** 重用当前 `Project.panelContext` 的项目/范围与目录数据进行校验：`ContentView.syncGit` 只应用仍匹配当前项目、目录和机器的异步结果；`SessionInfoModel` 只采用本次原目标 pid 和机器/作用域的进程/端口结果。不重复计算根目录、不搬移 `Project` 已有的范围选择逻辑，不新增全局 generation/缓存/轮询，保留现有 `PanelSyncQueue` 的合并行为。

**验证：** 签名 Debug 内连续改 cwd/快速切项目、SSH 断开/重连、跨主机相同 pid 情况可控时测最终 Git 仓库和 Info 内容；旧异步返回不能覆盖新的，最后一次有效刷新仍生效。保留 Git 事件驱动刷新、Files 惰性展开及现有面板展示；按源码核对唯一范围判断，`git diff --check`。

**提交边界：** 精确修复异步根目录/进程范围错配并删除被取代的旧判断，一个提交，不新建框架。

---

## P2 完成条件

原混合 `ToolPanelView.swift` 不再容纳三套面板 UI、Files/Info 数据模型也已归位。任何新接入均已同时移除旧定义；不把残留留给 P5。没有 SSH 实机证据的条件不冒称通过。
