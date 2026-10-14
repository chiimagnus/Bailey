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
