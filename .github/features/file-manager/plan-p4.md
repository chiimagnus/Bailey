# P4：与外部变化刷新整合并验证全部用户路径

**Goal：** 新增 Files 操作、选择、隐藏、定位及 `⌘P` 快速打开在**已存在的外部变更链路**中准确反映真实目录，跨功能和异常组合不退化。

**Non-goals：** 不在 #5 另建 FSEvents watcher、SSH 后台服务、轮询替代或独立事件总线；这些由 [Issue #40](https://github.com/chiimagnus/Bailey/issues/40) 及 `../event-driven-workspace-refresh/` 拥有。不因为本阶段 E2E 才补 P1–P3 本该同任务完成的测试、文档或旧代码清理。

**Approach：** 当前本机 Files 使用 FSEvents，Windows 固定 SSH Files 优先使用临时文件通知、失效时回退 2 秒轮询；SSH Git 继续 5 秒检查。具体触发与回退由 [Files 文档](../../../docs/features/files.md#自动刷新) 维护。P4 只验证通知、重连与现有 `Project.syncFiles → FileTreeModel`／`⌘P` 的联动，不维护第二套刷新或文件状态；已有 #40 代码不等于 F6 的完整 GUI 验收。

**Acceptance：** 选择／隐藏／定位及 `⌘P` 结果与本机或 SSH 实际数据一致，失败保留有效编辑和已确认显示，旧请求不可影响新目标；Settings 与跨窗口输入不串目标。F1–F4 已独立实施，**F6 仍需 P4-T2 完整 GUI 联动验收**；不为 P4 再造轮询或 watcher。

**Rules：** 真实刷新所见的目录条目才是内容真源；失败不伪装删除，SSH 不回退 Mac；P4 只补**跨功能连接点**及确实验证的缺口。

---

<a id="p4-t1"></a>
## P4-T1 已有刷新后的选择与 ⌘P 文件结果一致性

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift`（`syncModels/performSync/PanelSyncQueue/commandCompletionSequences`）、`Bailey/Workspace/Project.swift.syncFiles`、`Bailey/Files/FileTreeModel.swift`（`sync/rebuild/cachedDirectories/items`）、`Bailey/UI/CommandPaletteView.swift`（`indexedTarget/task(id:)`）、`Bailey/Workspace/ProjectFileIndex.swift`、#40 对当前 Files 刷新实际提供的事件（只有确认其代码已落地才接入）。

1. **Red：** 用独立 CLI／Finder／Git 进程创建、删除、移动或原子替换文件，验证树在实际读取成功前后的选择、隐藏项目临时查看、Reveal 与已打开的 `⌘P` 索引。立项时 `CommandPaletteView.task(id:)` 仅依目标变化重新索引，同一根内真实文件变化不一定触发重索引；这才是要检查的失效不变量。**对固定 SSH，`PanelContext.Identity` 不包含连接代次，`SSHHostWorkspaces.backend(for:)` 仍是同一对象；立项时 `ToolPanelView` 收到 `SSHHostWorkspaces.connectionChanged` 只更新头部状态、不调用 `syncModels()`，而 `remoteConnectionToken` 在固定 SSH 下也不会携带连接代次**。先证实连接通知→Files/Palette 失效→重连真实查询的链路，不因轮询暂时兜底就写成事件化已完成。制造扫描被阻塞、项目 A→B→A 和 SSH 读失败，确认当前树不清空、不串旧结果。
2. **Green：** 只在现有 `Project.syncFiles`/`FileTreeModel.sync` 与已打开的 Command Palette 上接入**已经真实提供的刷新/连接信号**。批量 `list` 的缺失键是失败，不是空目录：失败保留可信行与已加载编辑，禁止因未知状态执行破坏性文件操作；确证删除后才清理选择和临时 Reveal。已打开 ⌘P 的索引在文件结果变动后失效并按当前根重读，关闭后再打开总读当前目标；不能建持久全仓索引。固定 SSH `connectionChanged` 仍使用现成订阅：使可见 Files 重读、Palette 旧结果不可点击，重连后恢复检索；A→B→A/后端复用仍核对项目和机器。**#40** 只负责发出真实刷新信号与管理生命周期，本任务不写任何 watcher/轮询。一次成功的本机/远端查询不应重复发布完全相同的项目文件结果。
3. **覆盖：** 在已展开/折叠/临时显示 Excluded 的 Files 和已打开/关闭的 ⌘P 中，实际让 CLI、Finder、Git 创建/删除/原子替换文件；核对外部改名、高频变更、Git worktree 切换、项目 A→B→A、断线/重连与旧扫描结果。重点覆盖**固定 SSH 同 Identity、同 backend、连接变化、索引未完成**及 `list` 空/部分/全部失败，确保最终磁盘、列表、索引和可操作机器一致。定点跑 `FileTreeTests`、`PanelContextTests`、`ProjectFileIndexTests`、`GitRemoteRefreshIntegrationTests`、必要授权 `SSHFileTreeLiveTests` 和真正影响的 UI 文件搜索/焦点测试；不重复重测所有 P1/P2 的文件复制。
4. **闭环：** 只同步 `docs/features/files.md`、`command-palette.md` 与 `docs/testing.md` 中被集成行为真实改变的内容；不重写属于 #40 的监听文档。本任务引入的新旧状态处理替换后当次清理，独立中文提交。

---

<a id="p4-t2"></a>
## P4-T2 全用户入口与极端组合联动验收

**源码锚点：** `Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/{CommandPaletteView,Panels/ToolPanelView}.swift`、`Bailey/Workspace/{Project,WorkspaceWindowModel,ProjectFileIndex,WorkspaceBackend}.swift`、`Bailey/App/{WorkspaceApplication,BaileyApp,AppSettings}.swift`、`Bailey/Editor/FileViewerView.swift`、`Bailey/Remote/SSHWorkspaceBackend.swift` 及对应宿主/UI 测试。

1. **复核任务证据而非补拖欠功能：** 对 P1–P3 每个任务（P2 只有包含 Finder 回归的一个任务）的实现、原子提交、Red→Green、旧代码清理、功能文档和原生测试进行交叉审查；当发现某前置任务没有完成其自身所需验收时，**回到对应任务修复**，不能把剩余代码和文档堆到 P4。不要参考已有 `audit*.md` 的结论，直接从当前源码、Git diff、测试与真实界面核实。
2. **完整受控 App 用户流：** 复核 P1–P3 已证明的每段功能与每个 Git task commit。真实签名 Bailey Dev 中仅补跨领域不能由宿主测试证明的链路：Files 多选→剪贴板/批删→脏编辑保存→内部/Finder 拖放→Settings Exclude→Reveal→SSH ⌘P→外部变更；核对源/目标字节、标签后端、Undo、实际首响应者及错误反馈。原生 GUI 不必对每个纯输入组合重新走一遍相同点击；细粒度矩阵在宿主完成。
3. **交叉竞争与环境：** 对前台/后台多窗口、分屏切换、工具面板/终端/编辑器/浏览器/Diff 首响应者切换、Cmd+A/C/X/V 等快捷键不串目标、所选文件与当前编辑文件不同、重名抢占、父子混选、移动中自动保存、Finder 投放窗口坐标、源目标同路径但不同机器、断网重连、改分支时索引返回、不同 Dock 组/窗口/项目、弱网络与高频事件、特殊 Unicode／大小写／软链/深层结构，在安全隔离临时根最大程度实测。覆盖 macOS 当前版本、中英/明暗/窄宽/字体缩放、所有可用本机权限/文件系统条件；缺失 macOS 15.6 真机、未授权 SSH／物理输入设备明确登记**条件、尝试、替代证据、影响、补验与是否阻塞**，不假称通过。
4. **与已有 Focus／#44／#40 分工核对：** 已存在的 Files 单行游标、单击/双击、原生键盘焦点与 Git 共享树只回归，不引用已不存在的 #13 本地计划文件。#44 负责 Settings 的分类，#5 只交付 File Manager 内的 Exclude；#40 负责 FSEvents 与 SSH 刷新机制，#5 不新增监听配置或替代轮询。**分别报告 F1–F4 和 F6 的实际完成状态**：事件通知代码已接入，也不能替代 F6 完整 App 联动验收。
5. **验证与收尾：** 已在对应任务跑过定向 `make test ONLY_TESTING=...` 和 E2E，本阶段执行完整 `make test`、`make build`、`codesign --verify --deep --strict` 与原生签名 App 组合复验，检查完整命令退出状态。仅清理本阶段实际引入的临时数据及经证实的冗余，独立中文提交真正发生的修复及相应文档；纯审查/无代码变动不制造无用提交。同步完成报告到现有计划任务证据，不另建永久矩阵。

---

## P4-T2 联动核销与记录

按 [idea.md 的验收全集](idea.md#验收全集) 与 [docs/testing.md 的根因与回归覆盖](../../../docs/testing.md#根因与回归覆盖) 逐项记录受影响条件、实际测试和环境缺口，避免在此重复维护另一张 10 行测试矩阵。重点确认：多选/脏编辑在途保存/不同窗口同路径；本机/SSH 别名与跨后端身份；公开/私有双类型拖放；设置失败回滚；远端索引与外部事件的迟到结果。各任务的单项与故障夹具优先在宿主跑，完整 App 只负责菜单、真实键鼠、跨窗口与 Finder 拖动。

缺少 macOS 15.6 真机、特定卷、未授权 SSH 或物理输入设备时，逐项列明未测条件、替代证据、影响及是否阻塞 Go。性能只针对新增扫描/IO 的真实热路径测冷/热请求、耗时、CPU 与内存，不机械对每个操作要求 30 次 p95。完成前必须核对完整 `make test`、`make build`、签名检查和真实 GUI 各自退出结果；不得把纯宿主绿灯记成整机 E2E 通过。

---

## Phase Audit

仅全部实际完成后用计划工具新建 `audit-p4.md`；它记录独立复核及未覆盖条件，不替代阶段内实际测试。#40 的 F6 未过验收时，不能宣称 #5 全部联动已经完成。
