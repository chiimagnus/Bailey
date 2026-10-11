# P1：确立状态基线与共享代码的真实归属

**Goal：** 在不改产品行为的前提下确定状态/生命周期证据，把已共享的树实现和两个明显归属错误的模型放回正确功能域，为之后拆面板提供稳定引用。

**Non-goals：** 不重写状态模型、不引入协议或依赖注入、不拆面板/窗口协调器、不进行性能优化。

**Approach：** 先用现有代码与签名 Debug 观察窗口/项目/面板的持有者及关闭/切换行为；然后一次一个逻辑模块迁移既有源码。使用 Xcode 文件系统同步目录，不另建 Target。只移动原实现、更新必须的检查命令与文档链接；不另造共享树。

**Acceptance：**
- 基线记录区分源码事实、实机已验证行为和未测 SSH 场景；后续阶段知道哪个对象持有窗口、项目、标签、外层 Dock、内层 Pane、Files/Git/Info 与端口转发。
- Shared/Tree 是文件与 Git 各树视图共同使用的唯一模型/语义行实现；Files 与 Info 的模型位置清楚，公开类型/状态生命周期不变。
- 迁移后涉及的三项独立检查、签名 Debug 构建及相应真实界面路径通过，自动化点击不能冒充结果。

**Rules：** 保留 `Project.fileTree` 的项目所有权、`ContentView` 内 `GitStatusModel` 的窗口作用域和 `ToolPanelView` 当前面板状态；P2 才处理面板生命周期。更改路径时同时更新真实调用/测试/文档；不改 `Vendor/` 或自动生成文件。

---

<a id="p1-t1"></a>
## P1-T1 固定现有行为与状态归属基线

**类型 / 依赖：** 只读审查与可重复验收；无前置任务，不实施重构、不产生代码提交。

**锚点：** `kero/App/keroApp.swift::WindowRootView` 的 `@StateObject TerminalManager`、`kero/UI/ContentView.swift` 的 `@StateObject GitStatusModel`；`kero/Workspace/Project.swift` 的 `fileTree`、`dock`、`tabs`；`kero/UI/Panels/ToolPanelView.swift` 的 `PanelSyncQueue` / `PortForwardRegistry` / `SessionInfoModel`；`kero/UI/Panes/Panes.swift` 与 `kero/Workspace/DockWorkspaceModel.swift` 的两层树；`TerminalManager.restore(from:)` / `SessionStore` 保存链。

**操作：**
1. 使用 CodeGraph 追踪上述对象的创建、刷新、关闭和恢复；制作简短所有权表，注明哪些是现状、哪些只是后续目标。确认项目切换时 Git scope 和共享树刷新、面板销毁后的端口转发控制器归属，不能仅凭 `@State` 猜生命周期。
2. 对照 `docs/CONTRIBUTING.md`，先以当前仓库状态运行 `scripts/check-dock-workspace.swift`、`check-file-tree-navigation.swift`、`check-tree-row-hit-testing.swift` 所列命令，记录成功/失败、真实文件路径与版本；不新建测试框架。
3. 依照正式 App 任务保护要求，在签名 Debug 隔离模式验证：项目切换、外层标签跨组拖动/恢复、内层 Pane 分屏、Files/Git 未提交/暂存/历史树、Info 进程和端口、关闭与重新打开面板。核实终端进程/未保存文件不受影响；不以 AX 事件成功等同于界面成功。
4. SSH 已配置且可以安全使用时追加远程文件/Git/Info、断线与重新连接的代表性路径；若不可达只记录明确缺口，P2/P4 的远程验收不得据此标记通过。产出本地 `evidence-p1.md`（状态归属 + 可重放动作 + 结果/缺口），不提交私人路径或会话输出。

**验证：** 确认所有者表与以上实际源码一致；证据注明 Git HEAD、Debug 包身份、隔离与正式窗口区别及未覆盖点。仅做基线时无 Git commit。

---

<a id="p1-t2"></a>
## P1-T2 共享树模型与交互移入同一归属

**类型 / 依赖：** 原子源码迁移；依赖 P1-T1。

**Files / 已核对锚点：**
- Move: `kero/Workspace/TreeDisplayModel.swift` → `kero/Shared/Tree/TreeDisplayModel.swift`。
- Move: `kero/UI/Panels/TreeRowStyle.swift` → `kero/Shared/Tree/TreeRowStyle.swift`。
- Update: `docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift` / `scripts/check-tree-row-hit-testing.swift` 中出现的旧路径，以及确实引用旧路径的性能/开发文档。
- Consumers: `FileTreeModel`、`ToolPanelView`、`GitStatusModel`、`Git/RecentCommitsView.swift`。

**当前依据：** Files 和 Git 未提交/暂存/提交历史已通过 `TreeDisplayModel`、`TreeRowSurface`、`TreeFolderRow` 与 `TreeFileRow` 共享树语义/布局。移动不是重写；目前不同文件夹易导致重复创建组件。

**实施：**
1. 用 `git mv` 将**现有**两个文件一起移至 `Shared/Tree`，不改变核心 API 和绘制算法；检查 Xcode 文件系统同步分组是否自动接入。
2. 定向更新编译脚本路径、注释与文档引用；原路径不保留转发副本，其他 Files/Git 模块仍直接复用共享实现。
3. 核对所有树使用者的编译引用，尤其提交历史；发现某个私有内部 helper 不能跨文件访问时在同一任务解决，不新增平行 row/style。

**验证：** 按更新后的 `docs/CONTRIBUTING.md` 运行树导航和原生鼠标命中两项独立检查；Debug 编译/签名，Files、Git 三种区域的压缩目录、颜色、点击/悬停、长名称和键盘/无障碍真机对照 P1-T1。运行 `git diff --check`、确认旧路径不存在且无重复实现。

**提交边界：** 共享树模型 + 行组件的唯一归属及必要引用更新，一个原子中文 Git 提交。

---

<a id="p1-t3"></a>
## P1-T3 文件树模型归入 Files，保持项目级所有权

**类型 / 依赖：** 原子文件归属迁移；依赖 P1-T2。

**Files / 锚点：**
- Move: `kero/Workspace/FileTreeModel.swift` → `kero/Files/FileTreeModel.swift`。
- Update: `docs/CONTRIBUTING.md` 中树导航 Swift 编译路径与其他实际引用。
- Check: `kero/Workspace/Project.swift::fileTree`、`kero/UI/Panels/ToolPanelView.swift::FileTreePanel` 及 `FileTreeModel.sync`。

**当前依据：** `Project` 持有 `FileTreeModel`，其展开状态按工作区/根目录分别保存，树刷新与动作经 `WorkspaceBackend` 访问本地或 SSH。模型源码在 Workspace 只是目录归属，不是要求迁移所有权。

**实施：** 只移动模型，不创造 `FilesManager` 或新协议；保持 `Project.fileTree` 初始化和订阅关系。更新检测命令与源码路径引用，确保树遍历仍引用 P1-T2 的共享模型。

**验证：** 更新后的 `check-file-tree-navigation.swift` 在真实临时文件系统中通过；签名 Debug 的本地与可用 SSH 文件根目录、展开/压缩目录、新建/重命名、项目切换与恢复不变；在长树上检查惰性展开和响应。提交前 `git diff --check`。

**提交边界：** Files 模型的文件迁移和必要引用一个提交，不包含 UI 拆分。

---

<a id="p1-t4"></a>
## P1-T4 Info 数据模型归入 Info，暂不改变刷新生命周期

**类型 / 依赖：** 原子文件归属迁移；依赖 P1-T1，可排在 P1-T3 之后实施以减少并行风险。

**Files / 锚点：**
- Move: `kero/Terminal/SessionInfoModel.swift` → `kero/Info/SessionInfoModel.swift`。
- Check: `ToolPanelView` 的 `@StateObject private var info`、`performSync()` 和 `InfoPanel`、`PortForwardController`。

**当前依据：** 进程/监听端口数据被 Info 面板消费，但 `SessionInfoModel` 位于 Terminal 目录；它的当前创建/刷新路径确实在 `ToolPanelView`。P2 才讨论是否需要稳定于视图的所有者。

**实施：** 只迁移实现及必要源码/文档引用；不提前新增 Coordinator、全局注册表或面板协议，不把窗口级远程连接生命周期改成项目级。

**验证：** Debug 构建签名；本地 Info 的目录、子进程、监听端口刷新与操作不变；SSH 可用时验证远端与本地路径不混淆、断线提示和转发入口。恢复结果与 P1-T1 基线一致；`git diff --check` 通过。

**提交边界：** Info 模型归属一个提交，不改变产品行为。

---

## 阶段审查准入

- `evidence-p1.md` 记录未解决的真实风险；本阶段不能把“目录已经分开”当成“生命周期已经安全”。
- P2 只在上述基线清晰且迁移验收通过后启动；阶段完成时由实施流程生成 `audit-p1.md`，规划阶段不预建。
