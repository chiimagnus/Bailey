# P1：共享树和文件树模型的实际归属

**Goal：** 固定本次重构的最小行为基线，将已复用的树语义/行组件放到唯一共享位置，并让文件树模型归 Files；不改变任何运行行为。

**Non-goals：** 不重写数据流或刷新机制，不为一次目录迁移新增协议/Coordinator/测试平台，不因文件长度做其它拆分。

**Approach：** 以 CodeGraph 和现有三项轻量检查核对入口；`git mv` 迁移原实现，不复制组件，同一 Task 更新编译路径/文档并删除旧路径。签名 Debug 按 `docs/CONTRIBUTING.md` 安全做针对性 UI 验收。

**Acceptance：** `TreeDisplayModel`、`TreeRowSurface`、`TreeFolderRow`、`TreeFileRow` 仍被 Files、Git 工作/暂存与提交历史**共同**使用；`Project.fileTree` 继续持有原 `FileTreeModel`，惰性加载与路径/状态行为不变。

**Rules：** 不改变共享树 API、SwiftUI 命中区域、语义颜色、状态折叠和 SSH 路径；文件树与 Git 不各自新增树组件。阶段完成才开始 P2。

---

<a id="p1-t1"></a>
## P1-T1 核对代码所有权与基础回归

**类型：** 只读基础核对，无代码提交。

**源码锚点：** `kero/App/keroApp.swift::WindowRootView`、`ContentView.git`、`Project.tabs/dock/fileTree`、`TerminalManager.saveAll/restore`、`DockNode` / `PaneNode`、`ToolPanelView`、`SessionInfoModel`、`PortForwardController`。

**步骤：** 执行入口核对 HEAD 与未提交改动；复用本次独立审查的所有权/基线证据，不再重复全仓调研。2026-10-12 在 `335a940` 上重新编译运行三项检查均通过，`051c1fe..335a940` 的 `kero/docs/scripts/kero.xcodeproj` 无差异。若执行前相关源码/工具链已变化，再重跑受影响检查并更新证据，不把旧结果套用到新代码。窗口级 Git、项目级文件树与标签级 Pane 的 owner 已核对，不再创建全面实机实验或基线框架。

**验证：** `docs/CONTRIBUTING.md` 当前提供树导航和原生命中两条命令，不含 Dock 命令；Dock 的实际命令是 `xcrun swiftc -swift-version 5 -o build/check-dock-workspace kero/Workspace/DockWorkspaceModel.swift scripts/check-dock-workspace.swift && build/check-dock-workspace`。记录源码/命令与可安全触碰的窗口边界；P1-T2 同步补上文档遗漏的 Dock 命令。证据写入 Task note，无需额外 `evidence-p1.md` 或第二个状态看板。

---

<a id="p1-t2"></a>
## P1-T2 共享树唯一归属与旧路径同步移除

**Files：**
- `git mv kero/Workspace/TreeDisplayModel.swift kero/Shared/Tree/TreeDisplayModel.swift`
- `git mv kero/UI/Panels/TreeRowStyle.swift kero/Shared/Tree/TreeRowStyle.swift`
- 同 Task 更新 `docs/CONTRIBUTING.md` 的树导航/命中编译路径并补全已有 Dock 检查命令，更新 `scripts/check-file-tree-navigation.swift` 内的注释命令及受影响的其他源码路径/文档引用；旧文件无副本。根 `AGENTS.md` 对 `TreeDisplayModel` 的共享约定仍为唯一契约，不再新增架构规范。

**依据与步骤：** `TreeDisplayModel` 负责 Files 实际目录遍历、Git 路径树和共同的目录压缩语义，`TreeRowStyle` 同时实现 `TreeRowSurface` 与两个语义行及 Status 颜色；它们已经共享，并非这次才创建统一实现。整体搬迁、保持声明和调用语义，核对 Files、Git 工作区/暂存区、`RecentCommitsView`；共享目录只放这两份真实公用实现，不扩成通用 Toolkit。

**验证：** 三项轻量检查中受影响的树导航/原生命中检查，Debug 编译/签名、真实 Files/Git 树行的悬停、选中、长名称、压缩目录/无障碍；检查旧路径和重复 Row 声明已消失。按项目开发规范安全验收，不中断运行的命令。

**提交边界：** 共享树归位 + 即时删除旧路径与更新引用，一份原子中文提交。

---

<a id="p1-t3"></a>
## P1-T3 文件树模型归入 Files，项目持有者不变

**Files：** `git mv kero/Workspace/FileTreeModel.swift kero/Files/FileTreeModel.swift`；同任务更新 `docs/CONTRIBUTING.md`、`scripts/check-file-tree-navigation.swift` 的旧路径和确实受影响的引用，不留下转发文件。

**根因与步骤：** `FileTreeModel` 是 Files 的目录浏览/编辑/惰性刷新模型，但**现在由 `Project.fileTree` 实例化并持有**，只需要改物理归属。不得借迁移创建 `FilesManager`、新协议或改变对象生命周期；保留 `FileTreeModel.rebuild` 的单次刷新合并、root/scope 检查与展开状态。

**验证：** 独立文件树导航测试、Debug 编译/签名；本地或可用 SSH 下对照真实文件根目录、创建/重命名、跨项目展开状态、10k 文件树响应；确认 `Project.fileTree` 唯一持有者，旧文件和旧命令路径立即删除。

**提交边界：** 文件树模型迁移及必要引用同一原子提交。

---

## P1 完成条件

上述两个迁移各自已经移除旧定义与路径；从本阶段起后续任务使用新文件位置。审计在实际执行完成后按工作流创建，不预留 P5 清理任务。
