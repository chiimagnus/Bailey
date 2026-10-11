# P4：Git 命令执行的唯一真实边界

**Goal：** 将被 Git 状态、Diff 和命令面板共同使用的无状态 Git 命令执行从状态模型中独立出来，同时保留必要的本地/SSH 执行差异。

**Non-goals：** 不重写 Git 状态解析/缓存，不新增 `GitBackend` Protocol、操作队列或调度框架，不开启独立 `editor-git-performance` 性能计划，不提取仅有一个调用方的普通 helper 以凑文件。

**Approach：** 一个可独立验收的原子改动，移动已经被多个模块调用的进程执行 API 和它独占的 PipeData；调用者同步切换、旧实现立刻移除，远程快照批处理保留在当前快照逻辑中。执行前只核对真实调用方和适用的失败契约，不另建一轮实验计划。

**Acceptance：** `GitStatusModel` 唯一维护窗口仓库状态、刷新合并、代次与操作结果；Git 命令调用入口唯一。本地进程优先级/超时/部分输出、SSH stdout/stderr/错误码均不变；Diff 的带字节上限本地读取仍独立。

**Rules：** 现有 `runGitStatus`、`contextGeneration`、`statusRequestID`、`refreshPending` 是真实状态路径，不重写。Git 的丢弃、checkout 等路径需保持已存在的拒绝错仓、指纹/HEAD 核对，绝不因为“删多余护栏”取消。

---

<a id="p4-t1"></a>
## P4-T1 提取 Git 进程执行，并一次性修正全部消费者

**Files / 已核对的调用链：**
- From `kero/Git/GitStatusModel.swift`：本地 `static runGit`、含 `WorkspaceBackend` 的 `async runGit`、`remoteGitData`，及其独占的 `PipeData` → `kero/Git/GitCommandExecution.swift` 的普通内部执行类型/命名空间。
- Callers: `GitStatusModel.perform`、`runGitStatus`、仓库/操作辅助；`kero/Git/DiffViewerView.swift` 的大小检查/远端读取/冲突查询；`kero/UI/CommandPaletteView.swift` 的已跟踪/未跟踪文件搜索。
- Keep unchanged: `DiffViewerView.runGitData` **本地限量字节读取**、`GitStatusModel.prefetchedSnapshotCommands` 的仓库快照批次、`WorkspaceBackend.run`、`RemoteCommands`。

**已确认的设计约束：** GitStatusModel 的本地执行用 `Process`、双管道独立线程、超时后终止/必要 SIGKILL，并可保留部分输出；远端直接用 backend.run。Diff 的本地 blob 读取只留 `maxBytes + 1`，不能简单复用无限读取的文本 `runGit`，否则会破坏大小上限和二进制数据判断。

**实施：**
1. 沿上述所有实际调用方核对入参/返回值、主 actor / `nonisolated` 和局部错误消息，迁移现有 runner，不创造一套新 `GitBackend`；原模型中仅保留仓库/状态/操作编排。
2. 同一个 Task 直接更新 `GitStatusModel`、`DiffViewerView`、`CommandPaletteView` 的调用，删除原 `runGit`、`remoteGitData` 和 `PipeData` 定义及无用 import/注释。远端预取和元数据判定与状态刷新紧密相关，留在原模型，不再安排第二次所谓执行策略抽离。
3. 修正 `SSHWorkspaceBackend.swift` “Git 只在本地运行”之类已经不符合源码路径的注释；同任务删除因迁移确证无用的旧转发接口，**保留**当前输出限量、超时、SSH 主机信任及数据正确性校验。

**验证：** 使用独立 Git 测试仓库核对成功/非仓库、unborn、未跟踪、暂存与提交历史、错误码与输出；签名 Debug 下 Git 工作/暂存/历史、Diff 文本和大小限制、命令面板文件搜索。SSH 可安全使用时验证现有批次与超时不退化，不能时标记未测；核对命令数量无新重复，原静态 API 无残留调用，`git diff --check`。

**提交边界：** 共享 Git 执行唯一归属、三处调用方切换与原实现清理一个原子 Git 提交。

---

## P4 完成条件

不为让 Git 模型变短继续拆解析 helper、额外 Repository、第二个 GitStateStore 或重复本地字节读取。旧执行实现不保留兼容 wrapper；后续的性能问题归独立 Feature。
