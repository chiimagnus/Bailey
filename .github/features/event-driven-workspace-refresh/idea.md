# 工作区刷新：消除不必要的轮询

需求归属：[Issue #40](https://github.com/chiimagnus/Bailey/issues/40)。本机 Git 起点见 [PR #41](https://github.com/chiimagnus/Bailey/pull/41)。本文记录立项方案；完成情况以 [todo.toml](todo.toml) 为准，现行刷新规则见 [Files](../../../docs/features/files.md#自动刷新) 和 [Git](../../../docs/features/git.md#刷新与显示)。

## 立项背景（历史基线）

Git Graph 与底部状态栏曾因每 2 秒重复查询而闪烁。本机 Git 已改为 FSEvents 事件触发，但立项时仍有以下持续查询：

- `ToolPanelView` 的 `.task(id:)` 在前台显示 **Files** 时，本机与 SSH 均每 **2 秒**调用 `syncModels → Project.syncFiles → FileTreeModel.sync → rebuild(refresh: true) → backend.list(directories:)`；即使没有文件变化，也会读取根目录和可见的已缓存目录。
- SSH **Git** 面板在前台可见时每 **5 秒**调用 `GitStatusModel.refresh()`。本机 Git 已在相同入口提前返回，不再定时查询。
- `TerminalSession.watchRemoteConnection` 每秒检查本地 SSH 进程／control socket，健康时约每 2 秒发送一次**真正抵达远端**的状态探测。它负责发现静默断线，不能把“SSH 进程尚存在”视为远端在线。
- `GitFileEventWatcher` 已使用系统原生 FSEvents 监听本机仓库、Git 元数据和 Worktree，可复用原生机制；`SSHWorkspaceBackend` 的 `RemoteCommandRunner.run` 目前只能一次请求、一次完整返回，没有可靠的持续事件流。

本计划解决仍会产生无用磁盘/网络 IO 的周期刷新，而非为了形式上“全事件驱动”删除有意义的超时和连接探测。

## 不可突破的架构边界

**Bailey 绝不引入远程 Server。** 不部署 Bailey/Zed Headless Server、守护进程、常驻代理，不安装额外远端程序，不开放监听端口、RPC 服务或安装／升级流程；不修改远端 Git hooks、系统服务或用户 SSH 配置。此项不是 P2 实验可放宽的 Go 条件。

SSH 只允许使用**当前受管理 SSH 连接生命周期内的临时、只读系统命令**观察变化：无安装、无独立监听端口，连接或项目关闭时进程及其子进程全部退出。若原生能力不足、取消不可证实或必须引入服务端，则 **No-Go，继续使用现有 SSH Files 2 秒／Git 5 秒轮询**。Zed 远端源码只用于理解原则，不复制它的同步协议或架构。

## Zed 源码研究（固定 2026-10-19，`042e0406`）

- **事件入口与资源所有权**：[FsWatcher](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L36-L104) 将原生通知合并成路径事件，注册、缺失路径等待和释放归同一 watcher 管理（[注册与 Drop](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L144-L260)）。macOS/Windows 的递归监听可避免 Linux 那种逐目录注册；Bailey 复用既有 CoreServices FSEvents，不复制 Rust watcher 框架。
- **异常不是普通变更**：[丢事件／子树 Rescan](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L702-L795) 与正常路径事件分开合并；[队列溢出回归测试](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L1827-L1902)确保不能丢掉其它受影响子树。Apple [官方 FSEvents 契约](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)要求 `MustScanSubDirs` 递归核对相应范围、`KernelDropped/UserDropped` 重新核对全部监控范围，`RootChanged` 重新校验根。**Bailey 现有 `GitFileEventWatcher` 回调只返回 `()`、丢弃路径和标志；P1 必须先补齐必要信息。**
- **监听先于读取**：[扫描目录前订阅](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L5410-L5453)、[初次扫描后消费积压事件](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L4567-L4588)，保证新建目录及并发修改不会悄悄漏掉（[30 次重复测试](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/tests/integration/worktree_tests.rs#L3096-L3163)）。P1 须证明最终文件树，而非只收到回调。
- **按变化范围读取，按快照差异通知**：[受影响路径 → 后台重读](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L5123-L5219)，[仅发布不同的 Entries/Git 仓库](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L1444-L1490)，[GitStore 消费 Worktree 事件](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/project/src/git_store.rs#L2468-L2509)。Bailey 已有 `cachedDirectories`、`items != traversal.rows`、`PanelSyncQueue`，应优先改进现有缓存失效，不新建第二套 Worktree。
- **路径与目录边界**：[符号链接目标映射](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L4739-L4799)、[大小写／macOS NFC/NFD 监听键](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L532-L575)；但 Zed [工作树路径前缀比较仍留有大小写问题 TODO](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L5080-L5105)，**不能盲目复制**。涉及外部链接、目录压缩、只改大小写、特殊路径时，Bailey 应按真实卷语义复核磁盘与 UI。
- **Git 噪声与真正状态变化**：[忽略锁文件等无效事件，同时保留真正 Git 更新](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L4879-L5057)，[共享 Worktree Git 目录监听](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L3603-L3657)；[真实回归测试](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/tests/integration/worktree_tests.rs#L5256-L5266)覆盖自激重查。Bailey 不照搬 Zed 的忽略表：Git Graph 还需要 Stash、Merge/Rebase 等状态，必须验证不能误屏蔽。
- **必要的时间机制**：Zed [每 5 秒只核对根路径是否被祖先移动](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L4591-L4665)，而非遍历文件树；[相应回归测试](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/tests/integration/worktree_tests.rs#L6392-L6453)证明这是事件盲区。Bailey 已开启 FSEvents `WatchRoot`，**先实测 `RootChanged`，不可机械增加 5 秒探测**。Zed 的[Linux 网络／虚拟盘自动降级](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/fs/src/fs_watcher.rs#L283-L406)也不代表 macOS 现成可用。
- **远程仅借鉴可靠性原则**：Zed 用 Headless Server 在远端生成[带工作树及扫描编号的增量](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/worktree/src/worktree.rs#L2992-L3031)，由[WorktreeStore](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/project/src/worktree_store.rs#L1173-L1225)传输；这条架构明确排除。可吸收的是“事件只提示需要核对、旧结果不覆盖新数据”和[连接活动／心跳／重连相互独立](https://github.com/zed-industries/zed/blob/042e0406d33cfb312ea7e5796870671e0afa7383/crates/remote/src/remote_client.rs#L799-L895)，由 Bailey 现有后端完成。

**实现方向（示意，不是移植 Zed 源码）：**

```text
本机 FSEvents(路径、标志) → 标记受影响目录／失同步范围
  → 复用 FileTreeModel 缓存和 backend.list → 仅真实变更更新 Files UI
SSH 临时通知命令(变化／失效) → 复用 Files／Git 现有查询
  → 订阅失效、取消或不可信 → 保留／恢复现行轮询
```

## 需求与默认行为

1. **本机 Files 由事件驱动。** 文件、目录的新增、覆盖保存、删除、重命名及已展开子目录变化，在前台 Files 视图中自动可见。无变化时不每 2 秒枚举目录；打开／切回 Files、切换项目与 App 激活时立即验证一次，避免遗漏后台变化。沿用现有目录批量读取、树模型和共享行组件，内容相同时不重复发布 UI。
2. **SSH Files / Git 优先探索真实事件流。** 在受支持且经真实验证的远端环境，尝试把外部修改通知通过受管理的 SSH 会话送回当前工作区，复用一个可靠的通知入口触发既有 Files/Git 刷新。**若无法保证目标隔离、断线恢复、事件丢失补验和资源释放，保留现行 Files 2 秒与 Git 5 秒轮询**，不以偶尔工作的后台脚本替代。
3. **SSH 存活与工作目录探测独立。** 现有终端远端探测同时跟踪远程 Shell 的工作目录，不是纯粹的在线心跳；通知通道不能替代它。只有能够同时证明静默断线发现与原有远程工作目录语义完整保留，才能评估减少重复探测，否则维持现状。
4. **保留其它真正与时间有关的任务。** 保存防抖、终端进度报告超时、网络重试退避、隧道倒计时／准备状态和 UI 动画不是本 feature 的轮询替换目标。
5. 不增加第二套 Files 树、永久配置开关、后台服务、付费依赖或每仓库一套多层协调器；优先复用 FSEvents、`FileTreeModel` 的刷新合并、`PanelSyncQueue` 与现有 SSH 命令通道。

## 不变量与边界

- 使用 Swift 6 / 原生 macOS 15.6+；不改文件树的视觉、上下文菜单、目录压缩、滚动、焦点与无障碍。
- 事件不是内容真源；收到通知后通过当前后端读取**实际目录或 Git 快照**。合并连续事件，只为真实变化发布 UI；发生事件溢出、初始化竞态或监听失效时必须有重新校验途径，不能承诺所有通知绝不丢失。
- 旧根目录、旧机器、旧连接及已取消的异步事件绝不可覆盖当前目标；断线时保留已确认的文件树而不是清空或回退写本机。重新连接后校验真实数据。
- FileTree 的本地监听仅绑定需要的当前项目／可见 Files 场景，退出前台／切换根目录或关闭视图时释放资源；正常隐藏后重新打开必须补验。
- 同一功能的定时入口一旦由经验证的事件入口取代，应当次删除旧入口、同步 `docs/features/files.md`、`docs/features/git.md`、`docs/testing.md`，不保留两套无依据的刷新模式。
- 本计划不重复实施已有本机 Git 修复，也不授权直接执行后续 Files／SSH 生产改造。

## 可检查的验收

- 本机 Files：真实外部编辑器、Finder 或独立 CLI 对根目录、已展开子目录执行文件创建／覆盖／原子替换／移动／删除，UI 自动反映磁盘结果；无任何变化时前台静置 10 秒以上无周期目录读取。文件树菜单、路径、状态与手动刷新行为不变。
- 环境与输入：已打开／隐藏／重新出现的 Files；前台／后台；初次空目录、普通目录、Git 仓库、关联 Worktree、包含中文／空格／换行的路径、大小写更名、符号链接、不可读取目录、很深或很大的目录，以及大量短时间连续变更。逐项验证实际适用条件并尽可能组合。
- 同时发生目录变更、Git 刷新、项目切换、窗口关闭与后台切换：旧事件不跨项目发布，列表无丢失／误清空、无长期后台 watcher／无空闲重复 I/O。使用原生 UI 和磁盘最终内容核对，不只断言收到通知。
- SSH 可行性实验：只允许会话内临时原生命令；至少核查真实 Windows SSH 目标的事件来源、连续有界输出、失同步重扫、取消、重连与子进程清理；其它远端按已有命令可用性明确支持或 No-Go。分别记录 Files、Git 与 SSH 连接／工作目录探测的保留／替换决定，不能将 SSH 轮询停止误报为“事件驱动完成”。
- 验证 `FileTreeTests`、`SSHFileTreeLiveTests`、`PanelContextTests`、`GitRemoteRefreshIntegrationTests`、`GitStatusModelTests`、共享树原生交互、完整 `make test`、`make build` 与严格签名。受条件限制未测的远端设备、权限、系统版本、断线场景须逐项记录原因、替代证据、潜在影响和补验条件，不宣称全部通过。
