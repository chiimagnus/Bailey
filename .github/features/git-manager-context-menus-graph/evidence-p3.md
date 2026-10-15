# P3：Git 前台刷新迟滞复现证据

## 环境与范围

- 使用 `KeroTests/NativeUI/Git/GitExternalRefreshTests.swift` 中的临时 Git 仓库；`TerminalManager.addLocalItems` 绑定本地项目，真实 `NSWindow + NSHostingView(ToolPanelView(panel: .git))` 常驻显示。
- 外部进程通过 `GitCommandExecution.run` 和文件写入创建两次真实变化；**未触及用户的正式仓库、Windows SSH 或正式运行中的 Kero**。
- 原生窗口测试使用现有 `make test ONLY_TESTING=KeroTests/GitExternalRefreshTests`，日志：`/tmp/kero-p3-external-red.log`。

## 两次复现（修复前）

| 外部操作 | Git 真源 | 等待 | Kero GitStatusModel / 可见模型 | 手动 Refresh 对照 |
| --- | --- | --- | --- | --- |
| 修改受追踪的 `tracked.txt` | `git status --porcelain` 非空 | 4.6 秒 | `changedEntries` 无该文件，XCTest 第 71 行 Red | 调用 `model.refresh()` 后 `changedEntries` 正确出现 |
| 外部 `git add` + `git commit` | `git rev-parse HEAD` 已变 | 4.6 秒 | `recentCommits.first.hash` 仍是旧 SHA，XCTest 第 81 行 Red | 调用 `model.refresh()` 后头提交正确 |

本次原生测试总耗时 11.237 秒，两个 XCTAssert 同时失败，说明先后两次不同真实外部变更均未被自动读取；手动刷新路径成功。此实验的可见层为 **NSHostingView 承载的真实 GitPanel**，不把它表述为完整独立进程 E2E。

## 实际执行链与根因

1. `ContentView.swift` 的 `syncGit()` 只在应用激活、选中项目/上下文变化和本应用终端命令完成时触发；独立 CLI 不产生上述事件。
2. `ToolPanelView.swift` 有已有的 2 秒可见面板周期任务，但 `pollsSelectedPanel` 明确排除 `.git`；`performSync` 只针对 `.files`，所以 Git 视图即使常驻前台也没有触发路径。
3. `GitStatusModel.refresh()` 被手动触发后，成功查询并发表最新变更及提交，说明本次故障不是 Git 命令慢、请求代次合并或 SwiftUI Observation 拒绝渲染。

**根因类别：缺少外部变更事件触发**。本机、可见、前台 Git 面板应复用已有 2 秒周期任务，避免后台与 SSH 持续轮询；原有操作中的请求互斥及代次处理保留。远端外部变更与断线真机本轮尚未实测。

## 修复与回归验收

- 仅修改 `ToolPanelView.swift` 已有可见面板的 2 秒任务：Git 仅在前台、本机、面板可见时借用原任务；仓库状态加载中或 Git 写操作进行时跳过，不启动额外后台 watcher，不循环查询远程主机。
- 同一 `GitExternalRefreshTests` Red→Green：外部工作区文件修改约 2.0 秒、外部 Index 暂存约 2.0 秒、外部新提交约 1.7–1.8 秒后自动读到实际 Git 结果；已覆盖 App 失焦停止、重获激活恢复、Git 面板卸载停止、切换本地项目不读旧仓库、手动刷新有效。
- 原生窗口加载有双父合并、侧分支及多重 Ref 的**真实临时仓库**，截图位于 `/tmp/kero-p3-visual-qa.png`（仅测试现场，不入仓）。首次视觉审查发现多个引用挤压标题（`merge feature` 被截为 `mer…`）；调整标题布局优先级后重新验收，完整标题和 `main`、`v0.1`、`+2` 显示可读，蓝色主干与绿色合并线连接正确。
- 独立进程隔离 Debug Kero 已启动并可见，但原生文件选择框拒绝 Peekaboo 后台输入；因此未将临时仓库导入完整独立进程进行右键操作。当前验收为**真实 NSHostingView 中的产品 GitPanel、CLI 真值、模型集成和 NativeUI 点击**，不将它冒充完整进程 E2E。真实 Windows SSH 外部修改仍待验。
- 最终完整 XCTest、Debug 构建、签名和阶段审计的实际结果记录在 `audit-p3.md`。

## 2026-10-15 补验：真实 Windows SSH 外部提交

- 使用获授权的 Windows 主机 `windows` 和独立远端临时 Git 仓库。临时 `GitExternalRefreshTests.testIssue2SSHExternalRefresh` 通过真实 `NSWindow + NSHostingView(ToolPanelView(panel: .git))` 显示绑定 `ssh:windows` 的 Git 面板；外部提交使用不同 SSH 后端/连接，不发送 Kero 终端命令完成事件。
- 外部 Git `HEAD` 由 `6e0a54865ab4627422eaa7b5491f58f5fc2c8981` 变为 `a6a5b4804163811ae4bb604c276fecc1f6d77834`。面板可见且应用激活，等待 **6 秒**后 `recentCommits.first.hash` 仍为旧 SHA；主动 `model.refresh()` 后读到了真实新 SHA。这是**自动刷新失败、手动刷新通过**，不是网络写入失败。原始 Red 日志：`/tmp/kero-issue2-ssh-test-red.log`，XCTest 1 项中 1 项按预期失败。
- 根因归属：`ToolPanelView.pollsSelectedPanel` 在 `panel == .git` 时只允许本地项目；周期任务也只在 `git.currentScope == "local"` 时发起刷新。外部 SSH Git/CLI 不触发既有终端完成事件，导致可见远端面板仍停在旧快照。这与 [Issue #2](https://github.com/chiimagnus/kero/issues/2) 的 SSH 范围缺口一致，**不能关闭 Issue**。
- 本次按要求仅验证，未修改 Git 刷新生产逻辑、未增加远端轮询。临时失败测试已撤销，防止在未修复行为之前把 Red 用例混入常规测试；原始日志和本结论保留，未来修复时可将同一真实行为回归正式纳入 XCTest。此测试是带真实 Windows SSH 的 NativeUI/模型集成，不冒称完整独立 App E2E；前面的 P3 本机结果不受影响。

## 2026-10-15：修复 Issue #2 的 SSH 自动刷新

- **根因修复**：`ToolPanelView` 既有的可见面板任务不再排除 SSH Git。仅 App 前台且面板挂载时轮询，本机沿用 2 秒，SSH 5 秒；`GitStatusModel` 正在查询或写入时跳过。重用既有 SSH 批量查询、状态模型、过期结果屏蔽与独立 master，不新增常驻服务或第二条刷新通道。
- **Red**：正式纳入 `GitExternalRefreshTests.testVisibleSSHPanelRefreshesExternalGitChanges`，真实 Windows 临时仓库由独立 SSH 连接修改；旧代码下可见 Git 面板 18 秒后仍无法发现外部变更。日志 `/tmp/kero-issue2-fix-red-2.log`。此失败不是初始仓库识别错误。
- **Green（首轮实机）**：日志 `/tmp/kero-issue2-fix-green-ssh2.log`，1/1 PASS（97.329 秒）。文件修改自动刷新 15.20 秒、新提交自动刷新 8.61 秒；外部暂存可自动出现，Kero 后台及 Git 面板隐藏后停止周期刷新，恢复激活能重新读取，显式手动刷新依旧有效。远端耗时会放大端到端延迟，5 秒是触发间隔而非固定刷新完成时限。
- 该回归使用真实 `NSHostingView` 中的产品 Git 面板、真实 Windows SSH 后端和独立 Git 工作区；**不是完整独立 App 的可视化 E2E**。仅清理本次专属临时仓库与连接，不操作用户正式 Kero、工作仓库或 SSH master。
- **最终全量**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` → **223/223、0 failures、0 skipped**（`/tmp/kero-issue2-fix-full-windows.log`），其中新增 SSH 刷新 1/1、原本本机刷新 2/2、真实 Windows Rebase 与 GitWorkspaceSSH 均通过；完整运行 602.542 秒。
- `make doctor`：Xcode 27.0；`make build` 与 `codesign --verify --deep --strict` 均 PASS（日志 `/tmp/kero-issue2-fix-build.log`）。将签名通过的新 Debug App 整包更新至 `/Applications/Kero.app`，安装后独立验签、构建／安装可执行文件 SHA256 同为 `dc7356166fafb343fccbec63d44d4a2d8668739885c4cf94b811aa1fd129f170`；原正式 PID41537 未退出或重启，普通配置 SHA256 `a23668bd5e043f0da30cbb02b307c0c5f0a99da7cb8d20c5d4a437adb5e1cf3c` 未改变。安装日志 `/tmp/kero-issue2-fix-install.log`；新版仅在用户下次自行重启时生效。
