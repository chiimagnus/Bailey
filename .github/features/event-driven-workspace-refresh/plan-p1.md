# P1：本机 Files 由文件事件驱动

**Goal：** 真实文件变化驱动 Files 树更新，删除本机 Files 2 秒目录查询；无 UI/UX 变化，无新的全局服务。

**Non-goals：** 本阶段不改 SSH Files／Git、SSH 存活探测、保存防抖或隧道定时器；不让 Git 事件快照成为普通文件树内容真源。

**Approach：** 当前 `ToolPanelView.periodicRefreshID → Project.syncFiles → FileTreeModel.sync → rebuild(refresh: true) → backend.list(directories:)` 每次重读根及全部缓存目录；`GitFileEventWatcher` 虽有 `WatchRoot`，却把 FSEvents 路径与标志丢弃，仅回调 `()`。先在原有 CoreServices 监听实现上保留必要的事件范围／失同步／根变化信息，再沿现有 `PanelSyncQueue` 与 `FileTreeModel.cachedDirectories` 按事件标记脏目录、批量读取及比较；不建第二份文件树。先记录全量缓存重读的 IO 基线，普通事件尽量仅使相关缓存失效；失同步必须重读受影响的整个已加载树，不能用路径级优化遗漏最终目录状态。

**Acceptance：** 本机 Files 无定期查询、外部文件变更可自动反映、可见/后台/切根生命周期正确；原生树 UI 和实际文件操作没有回归。

**Rules：** 继续使用 `PanelSyncQueue`、唯一 `FileTreeModel` 缓存、`WorkspaceBackend` 和 Swift Observation；监听状态由当前工作区／Files 生命周期持有，Git 继续保留它自己的状态读取和菜单权限边界。失败保留有效旧树，不跨机器混用后端。禁止新增第二个 watcher 框架、轮询兜底配置项或新的状态缓存；当次删除旧本机 2 秒查询并同步文档。

---

<a id="p1-t1"></a>
## P1-T1 替换本机 Files 周期查询并验收目录事件

**涉及代码：** `Bailey/Git/GitFileEventWatcher.swift`（FSEvents callback 现丢弃路径及标志，`WatchRoot` 已开）、`Bailey/Git/GitStatusModel.swift`（原消费者继续正常刷新）、`Bailey/UI/Panels/ToolPanelView.swift`（2 秒调度、当前 Files 目标与 `PanelSyncQueue`）、`Bailey/Workspace/Project.swift`（`syncFiles(in:)`）、`Bailey/Files/FileTreeModel.swift`（`cachedDirectories`、`invalidateDirectory`、`rebuild(refresh:)`）、`Bailey/Workspace/LocalWorkspaceBackend.swift`（实际 `list` 和符号链接）、`Bailey/Shared/Tree/TreeDisplayModel.swift`（目录压缩需要的父/子目录），`Bailey/UI/ContentView.swift`（已有前后台事件）。SSH 相关代码本阶段仅验证，不改。

**文档 owner：** `docs/features/files.md` 的 Files 自动更新契约、`docs/features/git.md` 的 Git 独立事件行为、`docs/testing.md` 的 Files/Git/SSH 刷新 E2E。实现任务同次更新，不另建临时状态文档。

1. **Red / 真实问题与基线：** 用独立进程在 Files 正显示时创建／原子替换／删除本机测试文件，确认现行版本仅依靠 2 秒扫描发现、路径变更与最终 UI 对应。记录 10 秒以上空闲目录读取、事件风暴下批量 `list` 次数／CPU／延迟和实际 Finder 操作。将原生 FSEvents 的普通事件、`MustScanSubDirs`、`UserDropped/KernelDropped`、`RootChanged` 及初始化失败作为可控回归输入，断言**读取后的真实树内容**而非 callback 次数；现有 `FileTreeTests`、`PanelContextTests` 与原生 UI 测试复用。
2. **Green / 事件与缓存边界：** 沿现有 `GitFileEventWatcher` 的 CoreServices 封装提供最少必要的**路径／标志或失同步范围**，不能只给 Files 复用无参数 `onChange`。保留 Git 原消费方行为，复核已有 0.3 秒 stream latency 与 Git 0.4 秒防抖，避免每次通知堆叠更多计时器。**先注册再初次扫描、扫描后消费期间积压事件**；普通目录事件合并后使所属父目录、被压缩路径及必要的已展开子目录缓存失效，重命名要处理两侧父目录；目录层级事件不含精确文件名时须扩大对应目录范围，而非误判为“只改一个文件”。如果树允许展开指向根外的符号链接，根 watcher 不会收到外部目标的独立变化；只有在该链接实际显示且其目标获允许时才考虑观察规范化后的目标，并将事件映射回树内别名，关闭／折叠时释放额外订阅，不能因此允许越界写操作。保留批量 `backend.list`，只在 `items` 真的改变时发布。
3. **异常通知与生命周期：** `MustScanSubDirs` 要重新核验通知指定子树**内已加载／可见目录及必需祖先**，`KernelDropped/UserDropped` 要核验当前监听根下**所有已缓存目录**；已折叠未加载部分在再次展开时读取实际磁盘，不凭旧事件造条目。`RootChanged` 重新验证根目录是否存在、被祖先移走或重命名；Bailey 已设置 `WatchRoot`，先用真实目录移动和原生回调证明能覆盖，再决定是否真的需要低频轻量根健康检查，**不照搬 Zed 5 秒轮询**。异常不能清空有效旧行、转向另一项目或擅自跟随被移动路径。监听失败、根消失、权限拒绝、卷卸载及资源用尽必须可通过 App 激活、重新打开面板或手动刷新重新校验；只有实测原生事件在某挂载类型不可用时，才单独评估该范围的必要降级，不能恢复普通本机目录周期重扫。
4. **输入／竞态／身份矩阵：** 本机普通目录、空目录、Git 根、关联 Worktree、目录压缩的单子目录链、已展开／折叠目录、深树／大树；创建／覆盖／原子替换／跨目录移动／删除、大小写仅更名、NFC/NFD 中文／空格／换行路径、硬链接、普通／失效／环形／根外符号链接、路径前缀相似项目、目录短时移除又重建和连续数百次修改。还需同时验证监听开始／扫描／切根／更换窗口／隐藏再显示／App 后台恢复／外部 Git 操作的竞争，监视旧根的回调及旧 SSH 请求不得更新当前 Files。对 macOS 当前系统、最低支持系统及不同卷类型尽量实测；缺少实体设备逐项记明影响和补验条件。
5. **回归与清理：** 参考 Zed `worktree_tests.rs` 的初次扫描重复竞态、分裂的 Rename、失同步 Rescan、Git 共用目录事件与随机高频更新测试，在 Bailey **现有 XCTest 目标**构造可控事件顺序、验证磁盘最终条目和观察值；再用真实磁盘及签名 App E2E 核对 Files 行、右键、目录压缩、Git Graph/底栏与无静态闪烁。至少运行 `FileTreeTests`、`PanelContextTests`、`TreeRowHitTestingTests`、`GitExternalRefreshTests`、`GitStatusModelTests`，SSH 相关测试验证未回归（真实远端需授权），全量 `make test`、`make build`、严格 codesign；验收 CPU、IO、内存、Watcher 释放和零无效 UI 更新。**当次删除本机 Files 2 秒分支**，保留 SSH 2 秒／5 秒及终端存活检查，同步 `docs/features/files.md`、`docs/features/git.md`、`docs/testing.md`，任务状态和中文提交同次记录。

**Exit Gate：** 本机 Files 前台静置至少 10 秒，无周期目录读取；普通事件能及时反映真实内容，丢事件／根移动时能通过规定路径恢复一致；初次扫描与刷新中并发写入不漏掉最终状态；旧目标不能串写；Watcher 生命周期和 Git UI 无倒退。未满足任一门槛，不标记“事件驱动已完成”。

---

## Phase Audit

- 对 P1-T1 的源码、旧路径删除、现行文档和真实 E2E 独立复核；进入执行审计时才创建 `audit-p1.md`。
- 特别核对 Files 与 Git 是否能够在同一仓库复用现有底层 FSEvents stream（而不引入新的全局服务）；若各自生命周期需要不同监听，必须证明没有重复周期 IO、资源竞争及释放遗漏。确认外部符号链接的规范路径、监听与缓存路径指向同一实际对象，切根后不会串事件。
