# P6：跨面板业务编排与命令面板索引

**Goal：** 迁出 View 真正承担的 Git 根目录解析与本机文件搜索 IO，保留 SwiftUI 合理的生命周期定时触发、焦点、过滤和键盘展示状态；不为常规 UI 状态制造新 ViewModel。

**Non-goals：** 不新增另一套项目／Git／Files 状态真源；不重做原生终端或编辑器的输入机制；不扩大命令面板的搜索范围到远程 SSH 项目。

**Approach：** `PanelContext.resolvedRoot()` 已解决本机/SSH 项目识别；GitStatusModel、FileTreeModel 自己已有 refresh 合并/代次保护，`ToolPanelView.PanelSyncQueue` 另解决可见面板重复触发。不再发明一套窗口级 SyncCoordinator，只把实际解析与后端操作移到最接近的现有 ViewModel，View 的 `onChange/.task` 留做生命周期触发。命令面板目录枚举/`GitCommandExecution.run` 移入一份简单的索引函数/具体后台 helper；现有 `.task` 与 `@State` 已能保存索引、取消和选中作用域，不再预留额外 ViewModel。

**Acceptance：** Git／Files 的同步不受窗口位置或 View 重挂载影响；本机项目文件搜索通过真实服务并尊重取消及作用域；辅助 UI 状态由 Observation／局部 `@State` 表达，原先旧式订阅与包装器按任务消失。

**Rules：** `docs/TERMINAL.md`、`docs/GIT.md`、`docs/EDITOR.md`、`docs/PERFORMANCE.md`，尤其保留本地与 SSH 身份隔离、Git 事件驱动刷新、文件树活动期间定时刷新与长寿命原生视图。重构不是新增轮询或重复读盘的理由。Git/Files 更新时机、加载与错误反馈、⌘P 搜索排序、键盘/鼠标选择、焦点/关闭时机、动画和可见界面必须与 P1 原生基线一致。

---

<a id="p6-t1"></a>
## P6-T1 将跨面板根目录解析与刷新编排移出 SwiftUI View

**Files／源码锚点：** `kero/UI/ContentView.swift::syncGit/commandCompletionSequences`、`kero/UI/Panels/ToolPanelView.swift::PanelSyncQueue/syncModels/remoteConnectionToken`、`kero/Workspace/PanelContext.swift::PanelContext.resolvedRoot`、P3 的 Git ViewModel、P5 的 `TerminalManager`／`Project` ViewModel、`KeroTests/PanelContextTests.swift`、`KeroTests/GitStatusModelTests.swift`。

**当前可达链：** `ContentView` 在 `.onAppear`、App 激活、终端命令完成和项目身份改变时运行 `syncGit`，其 `Task` 调用 `PanelContext.resolvedRoot()` 后写入 Git 模型。 `ToolPanelView` 中另有 `PanelSyncQueue` 防止远端单目录多次并发刷新，并用活动状态与 2 秒定时源刷新 Files、更新远端 header。仅把 `@ObservedObject` 换成 `@Observable` 不会移走这些副作用。

**实现：** 将 `ContentView.syncGit` 内等待 `PanelContext.resolvedRoot`、验证 project/scope/identity 后调用 Git `sync` 的**业务部分**移到当前 Git/Project ViewModel 的唯一明确方法；UI 的 `.onAppear/.onChange/onReceive` 只通知此 owner “目标/应用事件发生”，不再自己发起 backend Task。`ToolPanelView.syncModels` 同理将真正目录 IO 与目标比对复用 `PanelContext` 和 `FileTreeModel/GitStatusModel`，并将已有 `PanelSyncQueue` 合并入口放在实际消费者位置（如果 View 仅负责定时触发，保留该局部调度器即可），不创建全局 SyncCoordinator。**保留** Files 只在可见、应用活动时每 2 秒刷新；保留 SSH header 无论 App active 都会更新的真实原因，Git 仍事件驱动无轮询；保留 AppKit 远端头部稳定视图。**同 Task 删除已被接管的 View 业务 `Task`、冗余重复验证和失效缓存；不删除当前仍为请求合并提供作用的 `PanelSyncQueue`。**

**验证：** `make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/GitStatusModelTests`（依当前重命名更新类引用）；补重复事件合并与旧请求不可覆盖新选中项目的回归，确保真正读到正确仓库；`make build` 并验签。隔离原生项目切换、终端执行 Git 后变化、文件树刷新与断线 header；无真实 SSH 许可时只报告受控边界。

**提交：** 共享真实刷新 owner、旧 View 业务链与并行缓存删除、更新测试一起原子提交。

---

<a id="p6-t2"></a>
## P6-T2 将命令面板文件索引迁出 View 并保留即时交互状态

**Files／源码锚点：** `kero/UI/CommandPaletteView.swift::CommandPaletteView/PalettePointerSelectionController/loadProjectFiles/gitProjectFilePaths/enumeratedProjectFiles/runSelected`、`kero/Git/GitCommandExecution.swift`、`kero/Workspace/PanelContext.swift`、`kero/Workspace/TerminalManager.swift`；有必要时新增 `KeroTests/CommandPaletteTests.swift`，复用 `KeroTests/PanelContextTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前可达链：** 命令面板 `.task(id: fileIndexContext?.identity)` 启动 `Task.detached`；View 内静态 `loadProjectFiles` 先直接调用 `GitCommandExecution.run(ls-files)`，失败时 `FileManager.enumerator` 枚举本机文件，并在异步返回后核对 manager／project 目标。远端项目默认禁止该本机文件索引，避免同名路径串机。

**实现：** 把 `loadProjectFiles/gitProjectFilePaths/enumeratedProjectFiles` **从 SwiftUI View 类型**移动到一个无状态具体后台索引 helper（如 `ProjectFileIndex`，无需 `Service` 后缀/协议/DI），内部仍复用唯一 `GitCommandExecution`，普通目录只用 `FileManager` 枚举，NUL/pathspec/.git 排除/子模块失败回退行为保持不变。**现有 `.task(id: fileIndexContext?.identity)` + `@State projectFiles/indexedTarget` 已具备本地索引的取消和目标核对**，默认原样保留，移动的是纯文件 IO；没有证据就**不新增 `CommandPaletteViewModel`、加载状态或额外 generation token**。`query/selection/hover/焦点` 等即时 View 局部状态继续 `@State`，不制造镜像。当前 `PalettePointerSelectionController: ObservableObject` **没有任何 `@Published` 字段**，改成普通持久参考对象由 `@State` 保存，保留识别真实鼠标移动的逻辑（其值仅在 pointer callback 被读取，不必为了重新渲染加宏）。**本 Task 删除 View 内目录枚举/同步 Git 命令和旧指针假可观察声明**；现有 `Task.detached` 仅是把阻塞磁盘索引移离主线程的**必要一次调用**，helper 接走后保留一条异步调用及其取消，不要因偏好新并发 API 而改成主线程扫描；不新增后台常驻索引或远端扫描。

**验证：** 增补或调整针对性 XCTest，覆盖本机普通目录、已跟踪／未跟踪／忽略文件、git ls-files 失败回退、查询排序与超过结果限制、快速换项目／取消后旧结果不能出现，特别检查 SSH 项目不会访问本机同名目录；`make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests` 及新命令面板测试；`make build`、隔离原生 ⌘P、上下键／Return／Esc 与实际打开文件。

**提交：** 无状态后台索引＋必要的异步结果状态＋旧 View IO 删除及真实结果验证同一提交。

---

## 阶段完成门槛

所有**仍可达的业务 IO／异步索引／跨项目请求**均由现有 ViewModel 或具体后台 helper 持有，View 的生命周期回调不再自己实现后台文件／Git 命令。各条旧 View 状态／订阅在对应任务已清理；后续最终阶段只核验，不接收堆积的清理工作。
