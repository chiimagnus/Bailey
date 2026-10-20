# P4：与外部变化刷新整合并验证全部用户路径

**Goal：** 新增 Files 操作、选择、隐藏、定位及 `⌘P` 快速打开在**已存在的外部变更链路**中准确反映真实目录，跨功能和异常组合不退化。

**Non-goals：** 不在 #5 另建 FSEvents watcher、SSH 后台服务、轮询替代或独立事件总线；这些由 [Issue #40](https://github.com/chiimagnus/Bailey/issues/40) 及 `../event-driven-workspace-refresh/` 拥有。不因为本阶段 E2E 才补 P1–P3 本该同任务完成的测试、文档或旧代码清理。

**Approach：** 当前 `ToolPanelView.syncModels → Project.syncFiles → FileTreeModel.sync/rebuild` 在 Files 前台每 2 秒刷新，也响应终端命令完成、项目变化及 App 激活；本机 Git 已用独立 FSEvents。P4 仅消费这些既有或 #40 后续提供的刷新触发，在 Files／项目当前所有者内核对选中项、隐藏显示和 `⌘P` 文件结果的更新，不维护第二套文件状态。#40 不在当前分支已完成时，不把「靠旧轮询正确」说成「事件通知已验收」。

**Acceptance：** 在已成功确认文件真实变化后，Files 行、选择、临时定位及 `⌘P` 文件结果与磁盘一致；旧 SSH 失败留住有效数据，当前编辑不丢失，额外监听/扫描为零；每项涉及 UI 的任务已有原生或完整 App 测试记录。

**Rules：** 真实刷新所见的目录条目才是内容真源；失败不伪装删除，SSH 不回退 Mac；P4 只补**跨功能连接点**及确实验证的缺口。

---

<a id="p4-t1"></a>
## P4-T1 已有刷新后的选择与 ⌘P 文件结果一致性

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift`（`syncModels/performSync/PanelSyncQueue/commandCompletionSequences`）、`Bailey/Workspace/Project.swift.syncFiles`、`Bailey/Files/FileTreeModel.swift`（`sync/rebuild/cachedDirectories/items`）、`Bailey/UI/CommandPaletteView.swift`（`indexedTarget/task(id:)`）、`Bailey/Workspace/ProjectFileIndex.swift`、#40 对当前 Files 刷新实际提供的事件（只有确认其代码已落地才接入）。

1. **Red：** 用独立 CLI／Finder／Git 进程创建、删除、移动或原子替换文件，验证树在实际读取成功前后的选择、隐藏项目临时查看、Reveal 与已打开的 `⌘P` 索引。`CommandPaletteView.task(id:)` 当前仅依目标变化重新索引，同一根内真实文件变化不一定触发重索引；这才是要检查的失效不变量。制造扫描被阻塞、项目 A→B→A 和 SSH 读失败，确认当前树不清空、不串旧结果。
2. **Green：** 真实读取导致 Files 数据变化时，仅在当前 Files 树清理过期选中并保留实际显示状态；如 `⌘P` 当前打开，使用已存在的观察／任务身份使其过期并重索引，不添加永久共享索引缓存。外部变化不一定经过 Files 面板时，`⌘P` 每次新打开都应从真实目标加载，不依赖隐藏面板的旧缓存。失败时保留已确认的树并显示无法确认的 `⌘P` 文件结果状态，而不是清空所有条目。#40 后续替换调度时仅接入其最终一致性读取，不复制 watcher。缓存和已被确认删除的选择应在**产生变化的本任务**清理，不能推迟到 P4-T2。
3. **覆盖：** 0/多项、已展开／未展开／压缩目录、选中正被移动项、临时 Show Excluded、`⌘P` 查询中继续输入、Git Branch/Worktree 切换、后台／前台、CLI 高频改名／删除／原子替换、旧扫描回写、SSH 超时/断线/恢复、多个不同机器同名路径、两窗口、没有 Files 面板但直接打开 `⌘P`。比较真实磁盘、`items`、聚焦选择、被排除项显示状态、Quick Open 文件路径与源机器、目录读取请求数、CPU/RSS；扩展 `FileTreeTests`、`PanelContextTests`、`ProjectFileIndexTests`、`GitExternalRefreshTests` 和真实 GUI／获授权 SSH。
4. **闭环：** 只同步 `docs/features/files.md`、`command-palette.md` 与 `docs/testing.md` 中被集成行为真实改变的内容；不重写属于 #40 的监听文档。本任务引入的新旧状态处理替换后当次清理，独立中文提交。

---

<a id="p4-t2"></a>
## P4-T2 全用户入口与极端组合联动验收

**源码锚点：** `Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/{CommandPaletteView,Panels/ToolPanelView}.swift`、`Bailey/Workspace/{Project,TerminalManager,ProjectFileIndex,WorkspaceBackend}.swift`、`Bailey/Editor/FileViewerView.swift`、`Bailey/App/{BaileyApp,AppSettings}.swift`、`Bailey/Remote/SSHWorkspaceBackend.swift` 以及相应 `BaileyTests/Integration`、`NativeUI`、`WorkspaceUI`。

1. **复核任务证据而非补拖欠功能：** 对 P1–P3 每个任务的实现、原子提交、Red→Green、旧代码清理、功能文档和原生测试进行交叉审查；当发现某前置任务没有完成其自身所需验收时，**回到对应任务修复**，不能把剩余代码和文档堆到 P4。不要参考已有 `audit*.md` 的结论，直接从当前源码、Git diff、测试与真实界面核实。
2. **完整受控 App 用户流：** 本机和获授权 Windows SSH 临时仓库执行：文件／目录多选、复制剪切粘贴／副本、删除及保存中移动、内部拖放和 Finder 外拖、Show Excluded 与设置、Reveal、SSH `⌘P`、外部 Git／CLI 改动。逐项覆盖 `idea.md` 的全部适用环境与正常/异常/极端输入，实际确认源／目标字节、原生缓冲/Undo、真实菜单焦点、Git Graph、Files 行和错误 Sheet；不让模拟测试替代完整 GUI。
3. **交叉竞争与环境：** 对重名抢占、父子混选、移动中自动保存、Finder 投放窗口坐标、源目标同路径但不同机器、断网重连、改分支时索引返回、不同 Dock 组/窗口/项目、弱网络与高频事件、特殊 Unicode／大小写／软链/深层结构，在安全隔离临时根最大程度实测。覆盖 macOS 当前版本、中英/明暗/窄宽/字体缩放、所有可用本机权限/文件系统条件；缺失 macOS 15.6 真机、未授权 SSH／物理输入设备明确登记**条件、尝试、替代证据、影响、补验与是否阻塞**，不假称通过。
4. **与 #40 分工核对：** 分开报告 #5 F1–F4 是否完成和 #40 的 F6 是否完成：实际代码若仍是本机 Files 2 秒轮询，F6 事件化**未完成**；SSH 若未真实 Go 保留旧 2/5 秒可靠轮询。不能为让 #5 “结案”越权删除 #40 轮询或增加远端 watcher。
5. **验证与收尾：** 已在对应任务跑过定向 `make test ONLY_TESTING=...` 和 E2E，本阶段执行完整 `make test`、`make build`、`codesign --verify --deep --strict` 与原生签名 App 组合复验，检查完整命令退出状态。仅清理本阶段实际引入的临时数据及经证实的冗余，独立中文提交真正发生的修复及相应文档；纯审查/无代码变动不制造无用提交。同步完成报告到现有计划任务证据，不另建永久矩阵。

---

## Phase Audit

仅全部实际完成后用计划工具新建 `audit-p4.md`；它记录独立复核及未覆盖条件，不替代阶段内实际测试。#40 的 F6 未过验收时，不能宣称 #5 全部联动已经完成。
