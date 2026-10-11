# P4：Git 命令执行的唯一真实边界

**Goal：** 将被 Git 状态、Diff 和命令面板共同使用的无状态 Git 命令执行从状态模型中独立出来，同时保留必要的本地/SSH 执行差异。

**Non-goals：** 不重写 Git 状态解析/缓存，不新增 `GitBackend` Protocol、操作队列或调度框架，不开启独立 `editor-git-performance` 性能计划，不提取仅有一个调用方的普通 helper 以凑文件。

**Approach：** 一个可独立验收的原子改动，收敛已经被多个模块调用的 Git 执行 API，并合并状态/Diff 重复的本地双管道进程实现；调用者同步切换、旧实现立刻移除，远程快照批处理保留在当前快照逻辑中。不要把这一步扩成通用 Process 框架。

**Acceptance：** `GitStatusModel` 唯一维护窗口仓库状态、刷新合并、代次与操作结果；Git 命令调用入口唯一。本地进程优先级/超时/部分输出、SSH stdout/stderr/错误码均不变；Diff 在同一字节执行实现上保持 `maxBytes + 1` 捕获上限、二进制/UTF-8 判定，不留下第二份本地 runner。

**Rules：** 现有 `runGitStatus`、`contextGeneration`、`statusRequestID`、`refreshPending` 是真实状态路径，不重写。Git 的丢弃、checkout 等路径需保持已存在的拒绝错仓、指纹/HEAD 核对，绝不因为“删多余护栏”取消。

---

<a id="p4-t1"></a>
## P4-T1 提取 Git 进程执行，并一次性修正全部消费者

**Files / 已核对的调用链：**
- From `kero/Git/GitStatusModel.swift`：本地 `static runGit`、含 `WorkspaceBackend` 的 `async runGit`、`remoteGitData`，及其独占的 `PipeData` → `kero/Git/GitCommandExecution.swift` 的普通内部执行类型/命名空间；`DiffViewerView.swift::runGitData/DiffPipeData` 的重复进程实现同时归并。
- Callers: `GitStatusModel.perform`、`runGitStatus`、仓库/操作辅助；`kero/Git/DiffViewerView.swift` 的大小检查/远端读取/冲突查询；`kero/UI/CommandPaletteView.swift` 的已跟踪/未跟踪文件搜索。
- Keep unchanged: `GitStatusModel.prefetchedSnapshotCommands` 的仓库快照批次、`WorkspaceBackend.run`、`RemoteCommands`，以及 Diff 的 blob 选择、文本/二进制/过大判定。

**已确认的设计约束：** GitStatusModel 与 Diff 的本地执行重复了 `Process`、Git 环境、双管道读线程、超时终止/必要 SIGKILL 及结果收集。差异是返回文本还是原始 bytes，以及 stdout 是否限量；无需因此保留两份 runner。以原始 Data 结果作为内部执行结果，文本入口只作解码；有 stdout 捕获上限时达到上限后仍继续排空管道，不能让子进程卡住。Diff 读取只留 `maxBytes + 1`，不能直接改用无限文本结果。远端仍用现有 backend.run；该传输当前先收完整输出，不冒称此次加了 SSH 流式内存上限。

**实施：**
1. 沿上述所有实际调用方核对入参/返回值、主 actor / `nonisolated` 和局部错误消息，收敛为一个 Git 专用的本地字节执行实现；允许可选 stdout 捕获上限，文本/异步远端入口复用它或现有 backend。不创造新 `GitBackend`、通用 CommandRunner 或策略对象；原模型保留仓库/状态/操作编排。
2. 同一个 Task 更新 `GitStatusModel`、`DiffViewerView`、`CommandPaletteView` 的全部调用，删除原 `runGit/remoteGitData/PipeData` 与 `runGitData/DiffPipeData` 的重复实现。保留原 QoS、Git 环境变量、launch failure/timeout 错误码和部分输出；远端预取留在模型，不再安排第二次执行策略抽离。
3. 即时删除已证实的 Git 历史辅助层：`Entry.mergeRowID/stagedRowID/changedRowID` 与 `Operation.isSuccess` 均无消费者；`loadedDetails` 在每个实际发布的 repository snapshot 中必为 true，删除该字段/赋值/条件包装，保持原字段更新；`remoteTextLineCount` 只在一个已经由远端批量分支提前返回的路径后被调用，删除不可达的逐文件远端 fallback 与因此多余的参数。保留远端批量计数的真实体积预算/限制及 parser 的真实路径去重，不因名称像防护就删除。
4. 更正 `SSHWorkspaceBackend.swift` “Git 只在本地运行”的旧注释，删除迁移失去消费者的 import/转发接口；**保留**当前输出限量、超时、SSH 主机信任、Git 丢弃 UI 的指纹确认和执行前仓库/HEAD 核对。UI 确认与执行前检查处于不同时间点，不能合并掉真实数据保护。

**验证：** 同任务增加 `scripts/check-git-execution.swift`，沿用现有轻量脚本，不搭测试框架。临时 Git 仓库检查文本与原始 Data、含空格/引号的 literal 路径、NUL/无效 UTF-8、恰好上限/超限输出且进程可结束、stdout/stderr、非仓库/启动失败/超时及部分输出；启动失败用不存在的 cwd 触发，不为测试增加可执行文件注入。用现有 WorkspaceBackend 的测试实现核对远端环境/返回值映射，不发起真实认证。具体独立编译命令随新源码一并写入脚本/CONTRIBUTING 并实际运行，不留到 P5。签名 Debug 验证 unborn、未跟踪、暂存/历史、Diff 和命令面板文件搜索；破坏性 Git 验证只用独立仓库并检查最终文件/暂存区结果。SSH 可安全使用时确认批次与超时不退化，否则明确远端端到端未测；原静态 API/重复 runner/上述 dead code 无残留，`git diff --check`。

**提交边界：** 共享 Git 执行唯一归属、三处调用方切换与原实现清理一个原子 Git 提交。

---

## P4 完成条件

不为让 Git 模型变短继续拆解析 helper、额外 Repository、第二个 GitStateStore 或重复本地字节读取。旧执行实现不保留兼容 wrapper；后续的性能问题归独立 Feature。
