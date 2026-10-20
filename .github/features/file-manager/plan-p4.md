# P4：与外部变化刷新整合并验证全部用户路径

**Goal：** 新增 Files 操作、选择、隐藏、定位及 `⌘P` 快速打开在**已存在的外部变更链路**中准确反映真实目录，跨功能和异常组合不退化。

**Non-goals：** 不在 #5 另建 FSEvents watcher、SSH 后台服务、轮询替代或独立事件总线；这些由 [Issue #40](https://github.com/chiimagnus/Bailey/issues/40) 及 `../event-driven-workspace-refresh/` 拥有。不因为本阶段 E2E 才补 P1–P3 本该同任务完成的测试、文档或旧代码清理。

**Approach：** 当前 `ToolPanelView.syncModels → Project.syncFiles → FileTreeModel.sync/rebuild` 在 Files 前台每 2 秒刷新，也响应终端命令完成、项目变化及 App 激活；本机 Git 已用独立 FSEvents。P4 仅消费这些既有或 #40 后续提供的刷新触发，在 Files／项目当前所有者内核对选中项、隐藏显示和 `⌘P` 文件结果的更新，不维护第二套文件状态。#40 不在当前分支已完成时，不把「靠旧轮询正确」说成「事件通知已验收」。

**Acceptance：** 在已成功确认文件真实变化后，Files 行、选择、临时定位及 `⌘P` 文件结果与磁盘一致；#13 窗口/分屏/原生控件的真实 Focus 与 Files 多选视觉及快捷键归属一致，#44 的 File Manager 设置入口可见且持久化正确；旧 SSH 失败留住有效数据，当前编辑不丢失，额外监听/扫描为零；每项涉及 UI 的任务已有原生或完整 App 测试记录。

**Rules：** 真实刷新所见的目录条目才是内容真源；失败不伪装删除，SSH 不回退 Mac；P4 只补**跨功能连接点**及确实验证的缺口。

---

<a id="p4-t1"></a>
## P4-T1 已有刷新后的选择与 ⌘P 文件结果一致性

**源码锚点：** `Bailey/UI/Panels/ToolPanelView.swift`（`syncModels/performSync/PanelSyncQueue/commandCompletionSequences`）、`Bailey/Workspace/Project.swift.syncFiles`、`Bailey/Files/FileTreeModel.swift`（`sync/rebuild/cachedDirectories/items`）、`Bailey/UI/CommandPaletteView.swift`（`indexedTarget/task(id:)`）、`Bailey/Workspace/ProjectFileIndex.swift`、#40 对当前 Files 刷新实际提供的事件（只有确认其代码已落地才接入）。

1. **Red：** 用独立 CLI／Finder／Git 进程创建、删除、移动或原子替换文件，验证树在实际读取成功前后的选择、隐藏项目临时查看、Reveal 与已打开的 `⌘P` 索引。`CommandPaletteView.task(id:)` 当前仅依目标变化重新索引，同一根内真实文件变化不一定触发重索引；这才是要检查的失效不变量。**对固定 SSH，`PanelContext.Identity.pinned` 不随同一主机的断线/重连改变，`SSHHostWorkspaces.backend(for:)` 仍是同一对象；`ToolPanelView` 收到 `SSHHostWorkspaces.connectionChanged` 目前只更新头部状态、不调用 `syncModels()`，而 `remoteConnectionToken` 在固定 SSH 下也不会携带连接代次**。先证实连接通知→Files/Palette 失效→重连真实查询的链路，不因轮询暂时兜底就写成事件化已完成。制造扫描被阻塞、项目 A→B→A 和 SSH 读失败，确认当前树不清空、不串旧结果。
2. **Green：** 真实读取导致 Files 数据变化时，仅在当前 Files 树清理过期选中并保留实际显示状态；**区分批量 `backend.list` 返回成功的空目录与缺失键代表的读取失败**：断线或权限错误只能保留旧的已验证行并标为不可确认，不得触发批删选中、导出错误完成状态、或者允许按失效行执行写操作；连接成功后才重验。如 `⌘P` 当前打开，使用已存在的观察／任务身份使其过期并重索引，不添加永久共享索引缓存。外部变化不一定经过 Files 面板时，`⌘P` 每次新打开都应从真实目标加载，不依赖隐藏面板的旧缓存。失败时保留已确认的树并显示无法确认的 `⌘P` 文件结果状态，而不是清空所有条目。固定 SSH 连接变化复用已有 `SSHHostWorkspaces.connectionChanged`：Files 可见时向已有 `syncModels` 请求一次按正确后端的重读，Palette 已打开时使旧索引不可操作并在重连后重建；远程操作仍按最终发起源身份授权，不能把旧返回发布到新连接。**#40 拥有刷新调度与本机事件监听**；本任务仅消费其已完成的触发信号或当前现成的 SSH 连接通知，不复制 watcher/轮询/服务。缓存和已被确认删除的选择应在**产生变化的本任务**清理，不能推迟到 P4-T2。
3. **覆盖：** 0/1/100+ 项、已展开／未展开／压缩目录、选中正被移动项、临时 Show Excluded、`⌘P` 查询中继续输入、Git Branch/Worktree 切换、后台／前台、CLI 高频改名／删除／原子替换、旧扫描回写、SSH 超时/断线/恢复、多个不同机器同名路径、两窗口、没有 Files 面板但直接打开 `⌘P`；特别组合**SSH 固定根 + 缓存的 `backend` + 相同 Identity + 断开/重连 + 旧索引仍在途**，并测试远端 `list` 返回缺失键、全部失败、部分成功，用户在树/Palette 中请求文件操作时的禁用/错误反馈。比较真实磁盘、`items`、聚焦选择、被排除项显示状态、Quick Open 文件路径与源机器、目录读取请求数、CPU/RSS；扩展 `FileTreeTests`、`PanelContextTests`、`ProjectFileIndexTests`、`GitExternalRefreshTests` 和真实 GUI／获授权 SSH。
4. **闭环：** 只同步 `docs/features/files.md`、`command-palette.md` 与 `docs/testing.md` 中被集成行为真实改变的内容；不重写属于 #40 的监听文档。本任务引入的新旧状态处理替换后当次清理，独立中文提交。

---

<a id="p4-t2"></a>
## P4-T2 全用户入口与极端组合联动验收

**源码锚点：** `Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/{CommandPaletteView,Panels/ToolPanelView}.swift`、`Bailey/Workspace/{Project,TerminalManager,ProjectFileIndex,WorkspaceBackend}.swift`、`Bailey/Editor/FileViewerView.swift`、`Bailey/App/{BaileyApp,AppSettings}.swift`、`Bailey/Remote/SSHWorkspaceBackend.swift` 以及相应 `BaileyTests/Integration`、`NativeUI`、`WorkspaceUI`。

1. **复核任务证据而非补拖欠功能：** 对 P1–P3 每个任务（P2 只有包含 Finder 回归的一个任务）的实现、原子提交、Red→Green、旧代码清理、功能文档和原生测试进行交叉审查；当发现某前置任务没有完成其自身所需验收时，**回到对应任务修复**，不能把剩余代码和文档堆到 P4。不要参考已有 `audit*.md` 的结论，直接从当前源码、Git diff、测试与真实界面核实。
2. **完整受控 App 用户流：** 本机和获授权 Windows SSH 临时仓库执行：先按 #13 验收窗口 key/Dock 活动组/原生 first responder、Files 行多选/聚焦键盘语义，再做文件／目录多选、复制剪切粘贴／副本、删除及保存中移动、内部拖放和 Finder 外拖、#44 的 Settings → File Manager 中 Exclude 规则编辑与临时 Show Excluded、Reveal、SSH `⌘P`、外部 Git／CLI 改动。逐项覆盖 `idea.md` 的全部适用环境与正常/异常/极端输入，实际确认源／目标字节、原生缓冲/Undo、真实菜单焦点、Git Graph、Files 行和错误 Sheet；不让模拟测试替代完整 GUI。
3. **交叉竞争与环境：** 对前台/后台多窗口、分屏切换、工具面板/终端/编辑器/浏览器/Diff 首响应者切换、Cmd+A/C/X/V 等快捷键不串目标、所选文件与当前编辑文件不同、重名抢占、父子混选、移动中自动保存、Finder 投放窗口坐标、源目标同路径但不同机器、断网重连、改分支时索引返回、不同 Dock 组/窗口/项目、弱网络与高频事件、特殊 Unicode／大小写／软链/深层结构，在安全隔离临时根最大程度实测。覆盖 macOS 当前版本、中英/明暗/窄宽/字体缩放、所有可用本机权限/文件系统条件；缺失 macOS 15.6 真机、未授权 SSH／物理输入设备明确登记**条件、尝试、替代证据、影响、补验与是否阻塞**，不假称通过。
4. **与 #13／#44／#40 分工核对：** #13 负责窗口/停靠组/原生内容 Focus 真源，#5 只拥有 Files 行选择和文件操作；#44 负责 Settings 功能页面，#5 只添加 Files Exclude 控件；#40 拥有文件监听与是否引入将来的 watcherExclude，#5 不添加监听配置。分别报告各自真实已通过的代码与验收，尤其区分 #5 F1–F4 和 #40 F6 是否完成：实际代码若仍是本机 Files 2 秒轮询，F6 事件化**未完成**；SSH 若尚未完成事件化则保留已有 2/5 秒可靠轮询。不能为让 #5 “结案”越权删除 #40 轮询或增加远端 watcher。
5. **验证与收尾：** 已在对应任务跑过定向 `make test ONLY_TESTING=...` 和 E2E，本阶段执行完整 `make test`、`make build`、`codesign --verify --deep --strict` 与原生签名 App 组合复验，检查完整命令退出状态。仅清理本阶段实际引入的临时数据及经证实的冗余，独立中文提交真正发生的修复及相应文档；纯审查/无代码变动不制造无用提交。同步完成报告到现有计划任务证据，不另建永久矩阵。

---

## P4-T2 适用环境与极端组合核销

下表用于**逐项跑实并记录证据**，不是另建测试系统或要求对不可用硬件宣称通过。每个条件均须覆盖可安全执行的取值、边界和组合；未实测的项在原任务证据中记明前提、阻塞、替代测试、实际影响、补验方法及是否阻塞 Go。完整仓库级要求仍见 [docs/testing.md](../../../docs/testing.md#根因与回归覆盖)。

| 维度与可行取值 | 至少需要实际组合的极端故障与最终验收 |
| --- | --- |
| macOS 15.6 最低目标／本机实测 macOS 27.2（arm64）及 Xcode 27.2 beta，APFS 大小写敏感／不敏感（仅在可获安全卷时），独立 Home、默认／自定义配置 | 重启与窗口快照、Mac 本地标签混在 SSH 项目、带 NFD/NFC 和首尾空格/换行/Tab 的文件名；磁盘字节、UI 名称和配置键在重开后仍一致，不因缺失 15.6 机器伪报实测 |
| 本机普通目录／Git（含未提交仓库、submodule、忽略文件）／worktree，Linux SSH 与 Windows MSYS2（仅可授权主机） | `⌘P` 包含 tracked 与非 ignored untracked，真实 Git 失败、远端失联或非 Git 目录不触发误扫描；空/1/100/10,000+ 文件的结果完整性、取消、限流、CPU/RSS 和超限提示 |
| Files 根、文件行父目录、压缩链真实末端、根空白与边缘、内部/外部/双 provider 拖动 | 默认移动/Option 复制、Finder→Files 复制、Files→Finder 公开 URL、跨窗口/项目/主机内部拖动拒绝；最终文件哈希、源是否还在与落点目录一致，绝不借 Finder URL 降级偷写 |
| 文件普通/空/大/二进制、目录/空目录/深层目录/大量兄弟项、硬链接/目录软链接/悬空链接/循环链接 | 重名（大小写仅差/NFD-NFC）、目录自身/子孙、同名异机器、越根软链、并发目标抢占和跨卷；逐项核对新旧路径、原文件字节、Trash 与中断时无残留临时目录 |
| 0/1/N、多选父子重叠、折叠/展开/过滤、仅键盘/鼠标/触控板模拟、原生辅助功能 | `⌘A/C/X/V`、方向/Shift/Option、Escape/Enter、Tab/右键、复制路径与真正复制不能串，GIT 树不受 Files 行选中样式干扰；逐项核对活动 first responder、选中/高亮与磁盘副作用 |
| 文件保存空闲/脏/进行中，失焦自动保存刚排队/已进入 `backend.write`、两个窗口共享路径、目录包含打开文件 | 先完成写入再移动/重命名/删除、成功 IO 回传前切项目/SSH 通道、用户再次编辑、取消及部分成功；保持 `FileTab`/Diff 内容、Undo、唯一正确写入路径，不能复写旧路径或重建已删文件 |
| 前台/后台、1/2/6+ 组合 Dock 组、双窗口、Palette/查找栏/Sheet/rename 输入、按键中途切焦点 | `⌘W/S/F/K/L/R` 的命令可用性与最终内容目标一致，两个脏编辑器在失去窗口 key 时都保存；关闭 Palette 不能抢回已停车终端/已关闭的文件，Shell/WebView/TextKit 身份保持 |
| 本机/SSH 稳定、延迟/超时/断线/重连、同身份旧后端/连接替换、A→B→A | 固定 SSH 后端复用但连接变化、受控 SSH 配置将同一 alias 指到不同有效 HostName/User/Port 的假设复现，旧目录批量列表/Palette 索引晚到，新查询成功/部分失败/全失败；不得串目标、误清空旧已验证行、误把失败报成空结果或打开同名本机文件 |
| TOML 缺省/`[]`/有效/非法/重复/只读配置，中文/英文/浅暗主题/窄宽/字号边界 | Exclude 只影响 Files 可见层，不改变 Git/Palette/watcher；已读缓存只重投影，首次显现子目录按需读；应用失败不修改旧生效值和用户 config 字节，Settings Reset 按钮对任意单项变化可用 |
| CLI/Finder/Git 外部新建、删除、原子替换、大批量/高频修改；Files 显示/隐藏及窗口前后台 | #40 事件或已有触发执行**真实**数据查询；选中项丢失/保留、当前文件高亮、Reveal、已打开 Palette 索引与磁盘一致，检查无重复 watcher/扫描、请求次数、资源和失败恢复 |

**核销方式：** 每个相关任务先覆盖其全部适用单项，再执行此表的复合场景；可承受的有限组合穷举，数量大时逐值覆盖并系统叠加两两及同根因多因素组合，不以“典型用例”省掉可测边界。Unit/Integration/NativeUI/WorkspaceUI 对应真实断言，**完整签名 App 的真实鼠标键盘用户流程另行验收**；使用独立构建/配置/文件与授权 SSH 临时测试 master，不操作用户正在运行的 Bailey。对 IO/渲染性能按 `docs/testing.md` 相同条件冷/热分开采样，热测至少 30 次给出中位数/p95/最差值。最后分别核对 `make test` 的 XCTest 和后置检查退出状态、`make build`、签名及真实 GUI；缺失 macOS 15.6、特定卷格式、受授权 Linux/Windows SSH 或物理外设时逐项列缺口，不能标“全通过”。

---

## Phase Audit

仅全部实际完成后用计划工具新建 `audit-p4.md`；它记录独立复核及未覆盖条件，不替代阶段内实际测试。#40 的 F6 未过验收时，不能宣称 #5 全部联动已经完成。
