# Audit P2 - event-driven-workspace-refresh

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/event-driven-workspace-refresh/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 真实验证 SSH 持续事件通道并确定 Go／No-Go
- [x] P2-T2 可行时接入 SSH Files 通知与轮询回退
- [x] P2-T3 可行时接入 SSH Git 并验收连接探测

## 任务到文件的映射

- P2-T1：`plan-p2.md`、`evidence-p2.md`；依据真实 Windows SSH 实验判 Files Go、Git No-Go。
- P2-T2：`2f5fac7` 的 SSHWindowsFileEvents、SSHWorkspaceFileEvents、ToolPanelView、Project、FileTreeModel、测试与长期文档；审计修复 `cf3ec1d`、`84833c3`。
- P2-T3：`GitStatusModel.runRemoteRefreshLoop()` 和 `TerminalSession.watchRemoteConnection` 均保留；Git 自触发的 No-Go 证据见 `evidence-p2.md`。

## 发现项

## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Remote/SSHWorkspaceFileEvents.swift:98-107`
- 摘要：`远端批量读取失败后仍报告同步成功，阻止轮询回退`
- 风险：`WorkspaceBackend.list(directories:) 在 SSH 命令失败时返回缺失结果，FileTreeModel 保留旧缓存但 Project.syncFiles 仍返回成功，watcher 的 healthy 保持 true；因此事件虽到达，实际目录未读成功且 2 秒回退查询被抑制。`
- 预期修复：`让 FileTreeModel 同步返回实际目录读取是否完整，Project.syncFiles 向 watcher 传递真实失败，再恢复原轮询；不要增加重复 SSH 读取。`
- 验证：`CountingFileBackend 注入批量读取失败先 Red 再 Green；运行 FileTreeTests、PanelContextTests 和授权 ssh windows 定向测试及签名构建。`
- 解决证据：`84833c3：FileTreeModel.sync/rebuild 返回实际目录读取是否完整，Project.syncFiles 失败时返回 nil，SSH watcher 因此将 healthy 置 false 并恢复 2 秒轮询；/tmp/bailey-p2-audit-f02-red-20261025.log Red 编译失败；/tmp/bailey-p2-audit-f02-green-20261025.log 76/76；/tmp/bailey-p2-audit-f02-windows-20261025.log 95/95 ssh windows 0 跳过；/tmp/bailey-p2-audit-f02-full-20261025.log 全量 627 项、12 SSH 跳过、0 失败；/tmp/bailey-p2-audit-f02-build-{dev,ui,formal}-20261025.log 全部成功并通过严格 codesign。`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Remote/SSHWorkspaceFileEvents.swift:55-78`
- 摘要：`Project 已释放而订阅成员未清除时 watcher 可无主重复启动`
- 风险：`Project 所有者为 weak；如果视图异常未触发 unsubscribe，成员还在时 worker 可能在 60 秒租期结束后无限重订阅，导致独立 SSH/PowerShell 进程反复创建`
- 预期修复：`持续任务只在实际 Project 所有者存活且存在订阅成员时运行，异步前置检查后再核对所有者，失效后退出不重建通道`
- 验证：`源码生命周期逐分支复核，运行 SSHWindowsFileEventsTests 实机定向，检查无测试进程残留及 Dev 签名构建`
- 解决证据：`cf3ec1d：while 与两次 await 结果后均核验 weak owner 与订阅成员；代码分支复核已限制项目释放后重新创建远端进程。/tmp/bailey-p2-audit-f01-windows-20261025.log：19 项 Windows+PanelContext 全部通过；/tmp/bailey-p2-audit-f01-dev-20261025.log 和 ui：Dev 签名构建/测试目标编译均通过。`


## 修复日志

- `cf3ec1d`（F-01）：项目所有者释放后不再重新建立 SSH 监听进程。
- `84833c3`（F-02）：实际目录批量读取失败时保留可信缓存并向上报告失败，恢复原有轮询；不新增远端查询。

## 验证日志

- Red→Green：新增 `FileTreeModel.sync` 失败传播断言时按预期编译失败；修复后 `make test:FileTreeTests,PanelContextTests` 76/76 通过，失败保留旧行、恢复后读取新行。证据 `/tmp/bailey-p2-audit-f02-{red,green}-20261025.log`。
- 真实 `ssh windows`：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHWindowsFileEventsTests,FileTreeTests,PanelContextTests,RemoteLifetimeTests,ProjectFileIndexTests`，95/95 通过、0 跳过；实测外部变更、共享订阅、根切换、符号链接与根丢失后回退。日志 `/tmp/bailey-p2-audit-f02-windows-20261025.log`。
- 最终 `make test`：627 项，615 通过、12 项 SSH 条件跳过、0 失败，退出码 0；本轮在两个审计修复后执行。日志 `/tmp/bailey-p2-audit-f02-full-20261025.log`。
- `make build:dev`、`make build:ui`、`make build` 全部退出 0；普通 Debug 严格 codesign 通过，日志 `/tmp/bailey-p2-audit-f02-build-{dev,ui,formal}-20261025.log`。UI 仅编译，未运行完整 GUI。
- 实测环境为 macOS 27.2 和 Windows 10/MSYS2 的 `ssh windows`；事件合并、PTY 清理/租期的 P2-T1 远端实验继续有效。SSH Git 只读查询自触发已复现，维持其 5 秒轮询及独立终端存活/cwd 探测。
- 未测边界：① 完整 App GUI、焦点/多窗需用户在 Mac 前授权，按既定要求延期；② macOS 15.6 无真机；③ 网络/可移动卷、权限拒绝、事件溢出及半开/丢包无获授权的可控故障注入，仍靠轮询回退；④ 不同窗口的 Project 可能分别占用约 67 MiB PowerShell，多窗长时资源无实测上限。不得据此宣称跨平台或完整 GUI 通过。
- 长期行为由 `docs/features/files.md`、`docs/features/ssh.md`、`docs/testing.md` 维护；实验及未测证据归当前 Feature。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（仅 P2 已按条件交付的范围，不等于完整 GUI／多平台发布验收）。
- 理由：Windows SSH Files 的事件与回退、真实远端测试、宿主全量回归和签名通过，F-01/F-02 已修复。SSH Git 因无法证明安全去噪按计划 `No-Go`，保留 5 秒刷新。

## 最终状态与剩余风险

- 当前状态：`Resolved`（P2 条件实现及两项审计发现）。
- 剩余风险：完整 GUI、macOS 15.6、其它卷与异常网络、多窗口长期资源尚需具备环境时补验；SSH Git 未改为事件驱动，重新评估需要无漏报、无刷新循环的实测依据。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

