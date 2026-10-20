# P2：评估并按证据引入 SSH 远端通知

**Goal：** 在**绝不引入远程 Server** 的前提下，判断能否通过当前 SSH 会话内的临时系统命令接收 Files/Git 变化；只有实测可靠才替换对应 2／5 秒轮询，否则维持原实现。SSH 在线及远程工作目录探测单独保持正确。

**Non-goals / 强制禁止：** 不引入任何 Bailey／Zed 远端 Server、Headless、代理服务、守护进程、远端二进制或脚本安装、监听端口、RPC/Socket 服务、长期后台任务、额外依赖或版本管理；不占用用户 SSH master／终端，不写 Git hooks、改 SSH 配置或建立另一份远端文件树。**即使试验证明 Server 性能更好，也不改变该边界。**

**Approach：** Zed 的远端增量快照实现仅作为[源码参考](idea.md)，不移植。Bailey 的 `RemoteCommandRunner.run` 是一次性返回，`ProcessRemoteCommandRunner.run` 会累积 stdout/stderr 直到退出或超时，**直接运行永久监听命令会阻塞并积累内存**。P2-T1 只验证现有 SSH 连接生命周期内的临时只读通知命令能否被**有界、持续、可取消**地读取；每次变化只发一个“需刷新”信号，Mac 再复用已有批量 `backend.list(directories:)`／Git 查询。Windows 先检查当前 MSYS2/POSIX Shell 能否安全调用系统 PowerShell `FileSystemWatcher`；其它系统无现成可靠系统命令即 No-Go，绝不安装 watcher 程序。

**Acceptance：** 无论决策结果为何，SSH Git/Files 外部修改仍可靠可见，断线能识别、重连能恢复，旧主机结果不串回新主机。若通知通道未通过 Gate，现行轮询必须继续有效且明确保留，不得宣称功能已事件驱动。

**Rules：** 每个 task 独立验收、提交；只允许在已获授权的临时目录和独立 SSH 测试通道上实验。临时通知进程随当前远端工作区订阅启动，断线／切项目／关闭时必须连同远端子进程一并终止；不能借用用户会话或遗留服务。若 Windows／其它环境无法满足条件，按平台或连接明确退回既有轮询，不增加永久配置。P2 不改 P1 本机 Files/Git。

---

<a id="p2-t1"></a>
## P2-T1 验证远端事件通道是否真正可用

**源码锚点（先读且只实验）：** `Bailey/Remote/SSHWorkspaceBackend.swift` 的 `RemoteCommandRunner.run`、`ProcessRemoteCommandRunner.run`（`Process`／pipe／`poll`／timeout；输出累积为 `Data`）、`SSHWorkspaceBackend.list(directories:)`；`Bailey/Remote/{SSHHostWorkspaces,RemoteConnection}.swift`（固定主机／接管 SSH 的连接所有权和 control socket）；`Bailey/Terminal/TerminalSession.swift`（`watchRemoteConnection` 每秒检查及远程工作目录探测）；`Bailey/UI/Panels/ToolPanelView.swift`（2／5 秒刷新）。用现有 `SSHFileTreeLiveTests`、`RemoteCommandsTests`、`RemoteLifetimeTests`、`GitWorkspaceSSHTests`、`SSHGitRecoveryLiveTests` 验证。

1. **确认原有命令边界：** 证明现有 runner 必须等子进程退出才能交付 stdout，且长运行过程持续累积字节；不得向它传永不退出的 watcher。仅在隔离实验中探索由当前 SSH 连接所有者持有、**逐帧读取且有限队列**的临时 `ssh` 子进程；输出只表示“变化／订阅失效”，不传任意命令、路径内容或工作树数据，不新增远端服务协议。测试无输出与大量输出时的阻塞、内存、取消、EOF、stderr、子进程退出及父进程回收。
2. **Windows 临时系统命令实验：** 先核实 Bailey 实际支持的 MSYS2/POSIX SSH Shell 如何调用系统自带 `powershell.exe`、将 `/d/...` 映射到 Windows 路径（含空格、中文、换行）并接收持续输出；不假定 PowerShell 就是现有交互 Shell。用 `System.IO.FileSystemWatcher` 的 `IncludeSubdirectories` 监听**隔离的只读测试范围**，观察 Changed/Created/Deleted/Renamed 和 `.Error`／`InternalBufferOverflowException`（[Microsoft 官方说明](https://learn.microsoft.com/en-us/dotnet/api/system.io.internalbufferoverflowexception)），正确清理事件句柄与进程。其它获授权 Linux/macOS 主机仅测试无需安装的**现成原生通知命令**；不存在则该平台维持轮询。不得下载编译运行其它程序来满足测试。
3. **正确性及破坏场景：** 真实远端新建、覆盖、原子替换、删除、改名、移动目录、已有／未展开子目录、多个 Git Worktree；观察 0、1、数百乃至数千次突发事件、重复／乱序通知和 `FileSystemWatcher.Error` 溢出。覆盖**订阅建立前、开始监听与初次读取之间、重连再订阅**三个缺口，以及静默断网、SSH master 异常、远端 watcher 进程退出、权限拒绝、项目／主机／窗口快速切换及 App 关闭。事件丢失须触发受影响范围重读；不能证明恢复最终 Files/Git 真实状态则 No-Go。记录输出帧损坏、命令注入边界、网络／CPU／内存／延迟及远端进程是否完整退出；不破坏用户既有连接。
4. **按能力逐项 Go / No-Go：** 分别记录 Windows Files、Windows Git、其它可用系统、连接存活检查的实际证据：可重复命令、收到通知到最终 UI 的时延、空闲/高频磁盘与网络 IO、CPU/内存、断线恢复、取消后**远端无子进程遗留**。**Go** 需证明临时只读命令可靠监控所需路径、按当前机器和仓库身份隔离、能报告或补验丢事件，资源开销可接受且不超过旧轮询带来的实际工作；**任何方案若需要 Server／守护进程／安装额外程序，一律 No-Go**。不能证明 Git 元数据监听不代表 Files 也失败，可对 Files 单独 Go；没获验证的平台保留 2／5 秒轮询。保留远端工作目录探测，不提交永久实验程序。

**文档 owner：** 实际触发用户行为变更时更新 `docs/features/files.md` 和 `docs/features/git.md`；仅 No-Go 时在此计划证据及 Issue 记录，不修改现行机制的对外承诺。实验完成才写证据（如 `evidence-p2.md`），不预造 audit 文件。

**验证限制：** 未获授权的 Windows SSH／Linux／macOS 主机、远端真实 Shell、网络故障注入、某个文件系统或系统事件源不能实测时，逐项登记可用设备、尝试方式、具体阻塞、替代证据、潜在影响、补验要求及是否阻塞对应平台 Go。**没有真实可复现的远端受控流与退出证据就不能 Go**；不得为了测试下载 watcher 或切断用户网络。

---

<a id="p2-t2"></a>
## P2-T2 在 Gate 允许时实现 SSH Files 通知与完整回退

**前置：** P2-T1 的 SSH Files 部分为 Go，且无需任何 Server／安装。No-Go 时由计划工具更新 `todo.toml` 并写明证据，不实施生产代码，保留现行 2 秒刷新。

**涉及文件：** `Bailey/Remote/{RemoteConnection,SSHHostWorkspaces,SSHWorkspaceBackend}.swift` 中已验证的命令/连接生命周期所有者；`Bailey/Workspace/Project.swift`、`Bailey/Files/FileTreeModel.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`BaileyTests/Integration/Files/SSHFileTreeLiveTests.swift`、`BaileyTests/Integration/Workspace/PanelContextTests.swift`。只能有**会话内临时进程**，不能引入 Server、远端程序安装或第二份目录树。

1. **Red→Green：** 由独立远端 CLI 修改临时目录，没有 Bailey 终端命令完成事件；先证明旧版仅 2 秒查询发现，再证明受控临时订阅的通知经现有 `Project.syncFiles → backend.list(directories:) → FileTreeModel` **确实更新 UI 与磁盘一致**。通知只表示“需要重读”，禁止将远端发送的未经验证路径/字节直接修改本机缓存。
2. **所有权和退路：** 当前项目／机器／连接身份拥有其临时通知命令，同一目标 Files/Git **共享一个受管理的通知通道**，多项目/多主机不可串流。只有命令确认已订阅并完成初始真实读取，才暂停该目标前台 2 秒查询；EOF、事件源不支持、溢出、失联及重新连接时立即回到原轮询并校验全部已缓存目录。普通通知合并后先沿原有 `backend.list(directories:)` 批量重读；如果仅传“脏”信号导致高频整树 IO 超过旧轮询成本，必须有真实测量支持更小范围的可信通知与目录失效，否则判该方案 No-Go，不用第二个远程 Worktree 模型补洞。
3. **全面验收：** Windows 授权主机的 MSYS2/POSIX Shell、不同 Windows 路径与卷、远端独立编辑器/CLI 写入、原子替换、跨目录移动、大小写/Unicode/空格特殊路径、深层/大规模目录、Git Worktree、软链接、不可读/消失目录、空闲/事件风暴；同时测试 App 前后台／Files 与 Git 面板隐藏、SSH 断线/重连、多窗口/多主机、旧任务延迟完成、Watcher 出错或强制退出。对照**远端实际磁盘、最终 Files UI、事件与轮询分别实际何时触发、CPU/IO/内存/网络、远端无孤儿进程**。其它远端系统按 P2-T1 已验证的平台范围同标准验收。
4. **清理与完成：** 被确认可靠替代的 SSH Files 健康态 2 秒查询分支在本任务删除，**回退所需旧轮询逻辑必须保留**；监听关闭后完全退出，不能长驻。同步 `docs/features/files.md`、`docs/features/ssh.md`、`docs/testing.md`；运行 `FileTreeTests`、`PanelContextTests`、`SSHFileTreeLiveTests`、`RemoteLifetimeTests`、全量 `make test`、`make build`、签名及实际 SSH GUI。每一项未覆盖的条件登记原因/影响，验收后单独中文 Git commit。

---

<a id="p2-t3"></a>
## P2-T3 在 Gate 允许时接入 SSH Git，核实连接探测与全局验收

**前置：** P2-T1 的 **SSH Git 路径监控**为 Go，且 P2-T2 的同一临时通知通道已完成 Files 验收；否则仅记录 No-Go，继续使用 5 秒 Git 刷新。**不得借用 Git 实现另建远端 Server、子系统或单独的常驻订阅。**

**涉及文件：** `Bailey/Git/GitStatusModel.swift`（分支／HEAD／Stash／历史／Worktree 和写操作资格）、`Bailey/UI/Panels/ToolPanelView.swift`（SSH Git 5 秒刷新）、P2-T2 已经拥有的 SSH 临时通知命令、`Bailey/Terminal/TerminalSession.swift`（独立的工作目录与连接存活探测）、`GitStatusModelTests`、`GitWorkspaceSSHTests`、`SSHGitRecoveryLiveTests`、`GitExternalRefreshTests`。

1. **Git 通知覆盖范围：** 用 P2-T2 同一临时通道覆盖当前仓库文件与真正 Git 元数据：`.git` 若是 gitfile，须解析所属 `gitdir` 和共享 `commondir`，其中可能位于 Files 根外；包含 `HEAD`、index、Refs/packed-refs、Stash、reftable 和关联 Worktree 的共享目录。保持 **Git Graph、Worktree、底栏和当前仓库的数据链只走 `GitStatusModel.refresh()`**，不把文件树事件本身当 Git 状态。只在真实外部 Git 变更和仓库身份更新可捕获时停止前台 5 秒轮询；失联／未订阅／溢出时恢复原轮询并重新验证核心状态，直到成功前缓存只读。
2. **Red→Green Git 数据与去噪：** 用真实远端 CLI 改 index、HEAD、Branch、Tag、Stash、rebase/merge、主／关联 Worktree、Detached HEAD、冲突、push/fetch/pull、外部提交，核查 Graph、状态栏、未提交节点和实际 Git 数据一致。对照 Zed 的 `.git/index.lock` 等噪声事件，测量 Bailey 读取 Git 自身是否引发二次通知／无限重查；若过滤，**必须同时证明不会错过 Stash／Refs／Merge/Rebase 或只有目录事件的真实变更**，不能照搬 Zed 忽略清单。高频通知不应清空已确认的行数、重建相同历史；换仓库／SSH 通道和超时的旧结果不能重新授权写操作。
3. **不得混淆 SSH 心跳和终端工作目录：** `TerminalSession.watchRemoteConnection` 的 1 秒本机进程检查／健康时约 2 秒真正远端请求还会读取**远程 Shell 或前台作业所在目录**，负责项目自动跟随。按 Zed 独立心跳的原则，只有实测能同时保留静默断网／鉴权失败／master socket 失效／远端退出检测及远程 cwd 更新，才评估去掉重复请求；否则完整保留。文件无通知不等于连接存活，更不等于当前远程工作目录没变。
4. **环境／异常／收尾：** 实测可用 SSH 远端的长空闲、0／海量文件、低／高延迟、丢包／超时／半开连接与恢复、多个共享 Git 目录的 Worktree、乱序及溢出、后台/隐藏、多窗口和快速切换。逐项核对远端真实 Git 状态、Graph 菜单与底栏、数据权限、CPU/网络/内存以及临时远端进程完全退出。同步 `docs/features/git.md`、`docs/features/ssh.md`、`docs/testing.md`；复用 `GitStatusModelTests`、`GitExternalRefreshTests`、`SSHGitRecoveryLiveTests`、`GitWorkspaceSSHTests`，完整 `make test`、`make build`、codesign 和真实 GUI 验收；任务内删除已替代的健康态查询，保留明确的轮询退路，中文原子提交。

---

## Phase Audit

- 仅在各任务真实开始审计时创建 `audit-p2.md`。审核平台 Go／No-Go 证据、旧计时路径与失败回退、远端子进程及句柄完整释放、目标身份隔离、不可访问环境与补验。**审查整个 PR 不得新增任何远端 Server／安装/守护进程／监听端口。**
- No-Go 也是完整的技术决策，不是“事件驱动已完成”；必须记录 SSH Files/Git 仍按 2/5 秒检查的限制，继续保留完整用户行为。不得为了减少轮询而牺牲 SSH 断线判断或终端目录自动跟随。
