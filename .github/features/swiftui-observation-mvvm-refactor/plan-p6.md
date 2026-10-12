# P6：跨面板业务编排、命令面板搜索与辅助状态收敛

**Goal：** 在 P3～P5 已有稳定 ViewModel 的基础上，清除仍留在 SwiftUI View 中的后台 IO、目标校验和长期任务编排，并收敛命令面板与少量剩余的局部可观察状态。

**Non-goals：** 不新增另一套项目／Git／Files 状态真源；不重做原生终端或编辑器的输入机制；不扩大命令面板的搜索范围到远程 SSH 项目。

**Approach：** 依据已经存在的实际调用链，在窗口级 ViewModel、项目级 ViewModel 与各专用 Service 之间明确所有权；View 的 `.onChange`／`.task` 可以负责触发可取消的展示生命周期动作，但不再内嵌目录遍历、Git 命令、过期请求合并等业务实现。删除旧 View 逻辑时直接接入新 owner，不添加中间空壳代理。

**Acceptance：** Git／Files 的同步不受窗口位置或 View 重挂载影响；本机项目文件搜索通过真实服务并尊重取消及作用域；辅助 UI 状态由 Observation／局部 `@State` 表达，原先旧式订阅与包装器按任务消失。

**Rules：** `docs/TERMINAL.md`、`docs/GIT.md`、`docs/EDITOR.md`、`docs/PERFORMANCE.md`，尤其保留本地与 SSH 身份隔离、Git 事件驱动刷新、文件树活动期间定时刷新与长寿命原生视图。重构不是新增轮询或重复读盘的理由。

---

<a id="p6-t1"></a>
## P6-T1 将跨面板根目录解析与刷新编排移出 SwiftUI View

**Files／源码锚点：** `kero/UI/ContentView.swift::syncGit/commandCompletionSequences`、`kero/UI/Panels/ToolPanelView.swift::PanelSyncQueue/syncModels/remoteConnectionToken`、`kero/Workspace/PanelContext.swift::PanelContext.resolvedRoot`、P3 的 Git ViewModel、P5 的 `TerminalManager`／`Project` ViewModel、`KeroTests/PanelContextTests.swift`、`KeroTests/GitStatusModelTests.swift`。

**当前可达链：** `ContentView` 在 `.onAppear`、App 激活、终端命令完成和项目身份改变时运行 `syncGit`，其 `Task` 调用 `PanelContext.resolvedRoot()` 后写入 Git 模型。 `ToolPanelView` 中另有 `PanelSyncQueue` 防止远端单目录多次并发刷新，并用活动状态与 2 秒定时源刷新 Files、更新远端 header。仅把 `@ObservedObject` 换成 `@Observable` 不会移走这些副作用。

**实现：** 让 P5 窗口级 ViewModel／项目级 ViewModel 在同一 `PanelContext.Identity` 上协调同步；根解析仍复用 `PanelContext.resolvedRoot` 和已有 WorkspaceBackend，Git ViewModel 执行其 `sync/refresh`，Files ViewModel 执行其 `sync`。按身份重入时复用原 `PanelSyncQueue` 单飞／合并语义（可移动到有实际调用者的 owner），不增加第二个任务协调器；保留 Git 事件驱动、Files 活动可见时轮询及远端标题断线更新；保留与原生头部 `RemotePaneHeaderHost` 的唯一桥接。**同 Task 从 ContentView／ToolPanelView 移除 `syncGit/syncModels` 的业务实现、View 内旧 `PanelSyncQueue` 和失效目标缓存或重复定时源**；SwiftUI 只转发出现／消失、应用激活与交互事件。

**验证：** `make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests`、`make test ONLY_TESTING=KeroTests/GitStatusModelTests`（依当前重命名更新类引用）；补重复事件合并与旧请求不可覆盖新选中项目的回归，确保真正读到正确仓库；`make build` 并验签。隔离原生项目切换、终端执行 Git 后变化、文件树刷新与断线 header；无真实 SSH 许可时只报告受控边界。

**提交：** 共享真实刷新 owner、旧 View 业务链与并行缓存删除、更新测试一起原子提交。

---

<a id="p6-t2"></a>
## P6-T2 命令面板文件索引与动作查询改成 ViewModel／Service

**Files／源码锚点：** `kero/UI/CommandPaletteView.swift::CommandPaletteView/loadProjectFiles/gitProjectFilePaths/enumeratedProjectFiles/runSelected`、`kero/Git/GitCommandExecution.swift`、`kero/Workspace/PanelContext.swift`、P5 `TerminalManager` ViewModel；如需新专用测试则为 `KeroTests/CommandPaletteTests.swift`，并复用 `KeroTests/PanelContextTests.swift`、`KeroTests/WorkspaceIdentityTests.swift`。

**当前可达链：** 命令面板 `.task(id: fileIndexContext?.identity)` 启动 `Task.detached`；View 内静态 `loadProjectFiles` 先直接调用 `GitCommandExecution.run(ls-files)`，失败时 `FileManager.enumerator` 枚举本机文件，并在异步返回后核对 manager／project 目标。远端项目默认禁止该本机文件索引，避免同名路径串机。

**实现：** 索引／git ls-files、目录遍历与过滤放进单一具体 `ProjectFileIndexService`（仅确有实际多个实现或测试替换需要才引入协议），保留 NUL 分隔、ignore、子模块失败回退、目录边界与取消；查询、选择、加载／错误展示、作用域目标和防过期属于 `@Observable` 命令面板 ViewModel，由窗口 manager 唯一输入当前项目，View 只绑定搜索与键盘动作。现有模糊评分算法保留纯函数，不重复维护两个检索器。**同 Task 删除 View 中 `loadProjectFiles/gitProjectFilePaths/enumeratedProjectFiles` 等底层 IO 实现、旧 `@State projectFiles/indexedTarget` 与失效 `Task.detached` 接线**，不能留下双套索引或脱离界面的新 Service。

**验证：** 增补或调整针对性 XCTest，覆盖本机普通目录、已跟踪／未跟踪／忽略文件、git ls-files 失败回退、查询排序与超过结果限制、快速换项目／取消后旧结果不能出现，特别检查 SSH 项目不会访问本机同名目录；`make test ONLY_TESTING=KeroTests/PanelContextTests`、`make test ONLY_TESTING=KeroTests/WorkspaceIdentityTests` 及新命令面板测试；`make build`、隔离原生 ⌘P、上下键／Return／Esc 与实际打开文件。

**提交：** 索引服务＋查询 ViewModel＋旧 View IO 删除及真实结果验证同一提交。

---

<a id="p6-t3"></a>
## P6-T3 辅助状态、FPS 与剩余旧式 View 包装器即时收敛

**Files／源码锚点：** `kero/Support/FPSCounter.swift::FPSCounter.start/stop/tick`、`kero/UI/Components/WorkspaceChrome.swift`（FPS badge）、`kero/UI/CommandPaletteView.swift::PalettePointerSelectionController`、`kero/UI/Components/BottomToolbarView.swift`、`kero/UI/Panes/PanelContentView.swift` 与本次迁移中仍使用旧 UI 包装器的实际 View。必要的原生测试沿用 `KeroTests/PaneRetentionTests.swift`。

**当前可达链：** FPS 是一份 `ObservableObject`，由 View 的 `@StateObject` 持有；它通过 `CADisplayLink` 和弱代理取得真实渲染节奏。命令面板的 `PalettePointerSelectionController` 亦标成 `ObservableObject`，但只承载短暂指针动作，不是业务持久状态。

**实现：** FPSCounter 保持当前 Native display-link 所有权与 `start/stop` 生命周期，只有 FPS 展示状态改用 `@Observable`、`@State`；保留弱代理和通知观察者正确释放。指针状态优先简化为 `@State` 或小型已有局部控制对象，避免为没有观察消费者的对象创建 ViewModel。检查本阶段直接相关的残留 `@ObservedObject/@StateObject`，按真实类型同步更换，不重新引入前阶段删去的 `ObservableObject`；**同 Task 移除 FPS `@Published`、旧 View wrapper 和已无用的 Controller 协议继承／Combine import**。不为了“全面更新”把稳定的原生工具栏重造一个版本。

**验证：** `make build`、`make test ONLY_TESTING=KeroTests/PaneRetentionTests`；隔离原生验证 FPS badge 每秒实际数值、切前后台暂停／恢复、显示关闭后无持续 display-link；命令面板键盘优先与指针实际移动再选中，其他窗口及工具栏没有因观察迁移丢失更新。

**提交：** 辅助状态变更、旧代码删除及针对性测试一份原子提交。

---

## 阶段完成门槛

所有**仍可达的业务 IO／异步索引／跨项目请求**均有明确的 ViewModel／Service owner，View 的生命周期回调不再自己实现后台文件／Git 命令。各条旧 View 状态／订阅在对应任务已清理；后续最终阶段只核验，不接收堆积的清理工作。
