# P3：定位 Git 刷新迟滞、修复并验收

**Goal：** 解决 Issue #2 的“Git Manager 更新不及时”，保持 Kero 已有事件驱动、互斥/去重、SSH 性能与失败保护。

**Non-goals：** 不进行整体性能重构，不引入通用文件监控框架、永久后台轮询或新的 Git 缓存；不重新实现 Files 刷新。

**Approach：** 先用受控仓库复现事件缺口与实际耗时，再修改拥有问题的最小现有入口。最后仅针对 `design.html` 的 Recent Commits 双行信息、图谱与对象菜单做原生界面验收；其余 Git Manager 区域检查是否回归，不重新设计。

**Acceptance：** 外部修改仓库时，正在显示的 Git Manager 会在可观测的合理时间内反映变更；手动刷新仍有效；Git 操作中不被旧快照覆盖；本机/SSH 失败与恢复不退化；Commit / Tag 菜单和图谱整体可用。

**Rules：** 全部测试在临时仓库；不清理或操作用户真实 Kero 数据、不重启正式 App、不修改 Windows SSH 配置。沿已有 Observation Git ViewModel 和当前事件入口取证，不重复迁移，也不修复已删除的旧订阅。使用 `AGENTS.md` 指定的唯一 Debug App `--isolated-ui-test` 路径与现有 XCTest；不把 CI 编译、HTML 演示当真机验收。

<a id="p3-t1"></a>
## P3-T1 追踪前台外部 Git 变更与刷新丢失位置

**Files / 锚点：** `kero/UI/ContentView.swift` `syncGit` / `.onChange(commandCompletionSequences)`；`kero/UI/Panels/ToolPanelView.swift` `pollsSelectedPanel` / `performSync`；`kero/Git/GitStatusModel.swift` `sync` / `refresh` / `refreshPending` / `apply` / `statusRequestID`；`kero/Git/GitCommandExecution.swift`；测试 fixture 与本地 feature 证据 `evidence-p3.md`（实施时新建）。

**已知线索：** ToolPanel 对 `.git` 明确关闭可见面板轮询；ContentView 主要监听焦点、项目变化、终端命令完成与 App 激活。**可能**漏掉 App 前台期间由外部程序直接改动的文件或 Index，但 Issue 现象仍未实测归因。

**实验：**
1. 用完全新建的临时 Git 仓库与 Kero 隔离实例，在 Git 面板持续可见时从**外部进程**新增未跟踪文件、Stage、Commit，分别记录真正 Git 结果、事件是否触发、`refresh` 调用、请求代次、应用快照、可见 UI 更新时间；与通过 Kero 内置终端完成的命令、手动 Refresh、失焦/重获焦点对比。
2. SSH 使用现有批量命令耗时和失败模型定向检查，不直接挂新轮询；若没复现远端外部变更，标记“待验”而非假定已解决。
3. 将根因归为“无事件 / 请求合并错 / Git 查询慢 / 应用后不渲染”之一；仅收集必要的时间线与可观察证据，避免全项目新增日志和框架。

**验证：** 保存最短复现步骤、两次一致复现和关键实际时间；至少能区分「外部修改未触发」与「刷新触发但旧结果写回」。这个 task 为诊断，不提交代码或制造无效修复。

<a id="p3-t2"></a>
## P3-T2 最小刷新修复与设计方案整体验收

**Files / 锚点：** 以 P3-T1 的已证实失效入口为准，预计在 `ContentView.swift` / `ToolPanelView.swift` 当前订阅与 `GitStatusModel.refresh` 之间，若证据指向快照层再修改 `GitStatusModel.swift`；`KeroTests/Integration/Git/GitStatusModelTests.swift`、`docs/features/git.md`、所属的 `kero/Resources/Localization/Git.xcstrings`／`Interface.xcstrings`。

**实施：**
1. 优先复用已有本机文件变化/命令完成事件；若缺事件且只有当前显示的 Git 面板需要补全，再引入受**前台、面板可见、仓库身份和 SSH 成本**约束的最小刷新触发。不无条件启动独立 Git polling、不对远程目录逐文件请求。
2. 旧请求不得覆盖新仓库或完成后的状态；失败/超时仍可重试。复用 `refreshPending` 等既有逻辑，证据显示失效时修它，不新造 generation、cache、queue。
3. 同 task 更新 `docs/features/git.md` 中实际新增的刷新契约，删掉被替代的旧订阅/分支，不留“以后最后再清理”任务。对照最新版 `design.html` 验收 Recent Commits 的**双行布局、标题后 Ref、短 SHA/作者/时间、蓝色主干与彩色分支**，避免影响已有 Changes、Stash 与顶部仓库菜单。

**验证：** 在 P3-T1 相同的隔离 fixture 上重放前台外部编辑/Stage/Commit、Kero 内部操作、项目切换、首次与重复打开、刷新中继续修改、SSH 断开；核对 Git 状态/图谱/菜单与真实 refs/index 一致。检查 Recent Commits 中多分支提交的 SHA、作者、相对时间与 Ref 显示；有性能证据时比较刷新次数和用户可见更新时间，不通过禁用刷新获得通过。执行受影响 XCTest、`make test` 和本机隔离 Debug 窗口点按 / 右击验收；正式包不替换。

**提交边界：** 根因最小修改、回归测试、长期维护文档一次提交。按已核实的实际运行记录区分本机与 SSH 的验证范围。

**执行后授权更新（2026-10-14）：** 用户随后明确要求替换正式 App；本次独立审计修复并通过全量测试后，已将最新签名 Debug Kero.app 安装至 `/Applications/Kero.app`，安装未主动重启运行进程。原阶段计划中的“不替换正式包”仅适用于原实施阶段。
