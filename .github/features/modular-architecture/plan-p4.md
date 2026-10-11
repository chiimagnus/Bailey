# P4：Git 命令执行与本地 / SSH 边界

**Goal：** 让 `GitStatusModel` 更聚焦于仓库状态、缓存和操作流程，将真实的 Git 命令执行差异限制在 Git 内部的少量执行代码里；复用现有 `WorkspaceBackend`，不为协议数量制造架构。

**Non-goals：** 不更换 Git 实现库、不增加远程服务、不把 Git 状态迁入另一套 Store、不实施 `editor-git-performance` 的状态与详情分阶段优化、不全量拆分 `WorkspaceBackend`。

**Approach：** 先对照源码和实机量化本地进程与 SSH 批处理的差异，再按已经存在的 `runGit`、`remoteGitData`、`prefetchedSnapshotCommands` 边界提取**无状态命令执行**。`GitStatusModel` 继续唯一持有 `@Published` 状态、仓库 identity、operation 队列和请求代次。

**Acceptance：**
- Git 业务状态更新、快照应用、状态目录着色仍归 `GitStatusModel`；文件访问依然经过现有 `WorkspaceBackend`。本地/SSH 的命令调用封装有唯一 owner，没有新的“万能 GitBackend 协议”。
- 现有本地短超时/原生进程与 SSH 批次/长超时在已知场景下等价；命令返回码、stdout/stderr、失败/超时提示不变。
- 仓库快速切换、操作期间刷新、暂存/丢弃/提交/分支/冲突和远端失败都不会应用旧快照、误操作别的仓库或丢掉最后一轮刷新。

**Rules：** 不把 `backend is LocalWorkspaceBackend` 全部视为缺陷；部分分支来自真实的远程往返和进程管道差异。当前 `runGitStatus`、`contextGeneration`、`statusRequestID`、`refreshPending` 属于状态安全链，不能随意替换。未经授权不在用户真实仓库试验丢弃、提交或远程推送。

---

<a id="p4-t1"></a>
## P4-T1 建立 Git 本地/SSH 命令契约与测试样本

**类型 / 依赖：** 定向源码审查与最小实验；依赖 P3 完成。

**锚点：**
- `kero/Git/GitStatusModel.swift::sync/refresh/runGit/runGitStatus/remoteGitData/prefetchedSnapshotCommands`。
- `GitStatusModel.perform`、`contextGeneration`、`statusRequestID`、`refreshPending` 和 `detectRepositoryOperation`。
- `kero/Workspace/WorkspaceBackend.swift::run/gitRoot`、`kero/Remote/SSHWorkspaceBackend.swift`、`kero/Remote/RemoteCommands.swift`。

**操作：**
1. 用 CodeGraph 将每处本地类型判断分类为：命令执行/等待策略、仓库路径/状态判断、远程批量减少往返；标出哪些具有当前真实的调用方与性能收益，哪些是与业务无关的可移出分支。
2. 在**专门的本地测试仓库**验证成功、无仓库、未提交、未跟踪、暂存/取消、冲突、提交历史与分页，记录同一查询的可见 Git 输出和命令失败表现；不要写入用户真实 Git 工作区。SSH 可用时在明确可用的测试目录读远程状态、断线与超时；远程破坏性操作仅在获授权的独立测试仓库里执行。
3. 形成 `evidence-p4.md`：当前错误码与超时、批次内容、后台任务/刷新代次、决定应移动进命令执行层的函数清单；未实际证明的优化不要写成既有成果。若某个提取会降低 SSH 性能或需要更改信任边界，调整 P4-T2/T3 的范围后才能动手。

**验证：** 每个判定能指向可到达的现有调用路径、样本或工具输出；记录缺失的 SSH 条件和重试限制。此审查没有源码改动则不提交代码。

---

<a id="p4-t2"></a>
## P4-T2 分离现有 Git 命令执行，保留两种执行路径

**类型 / 依赖：** 原子业务/IO 责任拆分；依赖 P4-T1。

**Files / 锚点：**
- Extract from `kero/Git/GitStatusModel.swift`: 两个重载的 `runGit`（本地、异步 backend）、`remoteGitData` 及它们独占的进程/数据处理 helper。
- New: `kero/Git/GitCommandExecution.swift`（普通内部具体类型或函数命名空间，不新增协议）。
- Consumers: `GitStatusModel.perform`、`runGitStatus`、分支/暂存/提交及失败回报路径。

**当前依据：** 本地 `runGit` 有专用子进程/管道读取路径；远程通过 `WorkspaceBackend.run` 取得 Data，并把超时、失败映射为 UI 已使用的返回码。合并成一套简单的 `backend.run` 可能改变性能与输出语义。

**实施：**
1. 仅提取无 `@Published` 状态的命令执行，保持原有成功/失败结果契约（status、stdout、stderr、`-1/-2` 与错误文本），不重写安全确认/操作并发机制。
2. 调用方用唯一的执行入口替换原有静态调用；保留本地原生管道读取、远程 async 和对应 timeout；移动后立刻删除模型中的旧实现。
3. 调整内部访问范围时以必要调用为限，不为了跨文件可见性把整个 Git 模型暴露为公共 API。

**验证：** 签名 Debug 对比本地/SSH 相同 Git 命令的状态输出、失败和超时；`GitStatusModel.refresh` 在不同仓库下结果不混淆；受影响测试仓库暂存/撤销/分支/提交后仍可恢复，远端不可达时错误一致。检查线程/进程和远程往返未因提取增多，`git diff --check`。

**提交边界：** 无状态命令执行归属和同步切换所有调用者，一个中文原子提交。

---

<a id="p4-t3"></a>
## P4-T3 收敛 Git 快照的执行策略，保留状态安全链

**类型 / 依赖：** 单一 Git 执行策略收敛；依赖 P4-T2。

**Files / 锚点：**
- `kero/Git/GitStatusModel.swift::runGitStatus`、`prefetchedSnapshotCommands`、`containsGitMetadata`、`untrackedLineAdditions`、`textLineCount`、`detectRepositoryOperation`。
- `kero/Git/GitCommandExecution.swift`（P4-T2 新建）。
- `kero/Remote/RemoteCommands.swift` 的批处理命令与 `WorkspaceBackend.run`。

**当前依据：** `runGitStatus` 调用远程预取批次并按 deadline 获取快照，失败时根据错误类型判定仓库是否存在；状态与刷新仍依赖模型中的 `contextGeneration`、`statusRequestID` 防止异步结果乱序。

**实施：**
1. 将 P4-T1 已确认属于“本地/SSH 执行成本”而不属于 Git 业务状态的分支和远程批量提交入口收敛到 P4-T2 的执行层；解析/状态缓存、刷新的 generation/operation 安全判断留在 `GitStatusModel`。
2. 不无条件搬迁所有本地判断。需要访问 model 的 repository 状态或解析产物的分支继续留在模型，避免把整个 GitStatusModel 透传给执行层。
3. 删除被替代的旧静态/helper 及误导注释；如 `SSHWorkspaceBackend` 的注释与当前真实路径不一致，仅修正文案，不因注释推测而改变协议实现。

**验证：** 本地/SSH 重跑 P4-T1 最小矩阵；尤其是初次 Git 根解析、unborn、未跟踪/忽略、冲突、batch 不可用时的原有失败策略；切换项目期间旧快照不能盖过新仓库，刷新期间的最后一个变更事件仍会被处理。使用现有 Git/性能文档的口径比较命令数量和可见状态，未测量时只报告行为等价，`git diff --check`。

**提交边界：** Git 快照执行策略收敛及同任务旧实现清理一个提交；不引入 `GitBackend`、多余服务层或新的 retry 状态机。

---

## 阶段审查准入

- 真正的复用边界是现有 `WorkspaceBackend` + Git 内部具体执行层；不得因项目未来可能有 API 就新增协议。
- GitStatusModel 仍是窗口观察状态的唯一归属，Git 操作的失败反馈、并发/取消和 repo 作用域不变。
- P4 未证实的性能问题不转为本 Feature 需求，相关优化由独立 `editor-git-performance` Feature 处理。
- 本阶段完成后再生成 `audit-p4.md`，规划阶段不预建。
