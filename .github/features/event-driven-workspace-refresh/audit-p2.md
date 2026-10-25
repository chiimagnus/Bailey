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
- P2-T2：原始接入 `2f5fac7`；先前修复 `cf3ec1d`、`84833c3`；**本轮独立复核与修复 `93064ef`**。真实消费链为 `ToolPanelView → SSHWorkspaceFileEvents → SSHWindowsFileEvents → Project.syncFiles → FileTreeModel`，保留不健康时原有 2 秒轮询；新增真实 Windows 专属子进程释放测试和隔离 Bailey Dev GUI 测试。
- P2-T3：`GitStatusModel.runRemoteRefreshLoop()` 和 `TerminalSession.watchRemoteConnection` 均保留；Git 自触发的 No-Go 证据见 `evidence-p2.md`。

## 发现项

## 发现 F-05

- 任务：`P2-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Remote/SSHWindowsFileEvents.swift:32`
- 摘要：`仅测试调用的 events 包装入口与正式 subscribe 重复且隐藏取消能力`
- 风险：`生产代码只调用 subscribe 返回的带 cancel 订阅；events 额外包装只被两条测试使用，却丢掉 cancel 句柄，令测试必须依赖 AsyncStream 自动终止来清理实际远端进程。`
- 预期修复：`移除无生产消费者的 events 包装，现有测试直接使用 subscribe 并明确在完成和失败后取消，保留唯一事件入口。`
- 验证：`CodeGraph 与 rg 确认只剩单一 subscribe 入口；真实 Windows ROOT LOST、外部事件宿主测试和远端子进程回收测试全部通过。`
- 解决证据：`93064ef; removed test-only SSHWindowsFileEvents.events wrapper; CodeGraph confirms single subscribe entry for production and tests, 6/6 real Windows host tests PASS /tmp/bailey-p2-audit-windows-green-20261026.log; explicit cancel in 2 former wrapper consumers.`


## 发现 F-04

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Remote/SSHWindowsFileEventsTests.swift:142`
- 摘要：`已标记完成但缺真实 SSH Files GUI 和取消后 PowerShell 释放的直接验收`
- 风险：`原 P2-T2 只有宿主事件流和 UI 编译；没有完整 Bailey Dev 中的外部远端新建／改名／删除与隐藏恢复，也未在生产订阅取消后以测试目录身份确认远端 PowerShell 已退出，不能用 Swift 取消标志替代远端清理验收。`
- 预期修复：`沿用现有真实 Windows SSH 和 BaileyUITests，补充受控临时目录中的真正 GUI 用户路径与仅按测试目录归属的 PowerShell 进程计数；不新增后端或安装远端工具。`
- 验证：`BAILEY_P4_TEST_SSH_HOST=windows 对应宿主进程回收测试和单条 Bailey Dev UI E2E；核对远端最终字节、监听不存在与无残留测试目录。`
- 解决证据：`93064ef; Windows Powershell watcher test exactly 1 live owned process then 0 on cancellation (2/2, /tmp/bailey-p2-reap-corrected-20261026.log), isolated Bailey Dev real SSH file create/rename/delete and hidden recovery 1/1 /tmp/bailey-p2-windows-gui-20261026.log; tests clean only their own remote fixtures.`


## 发现 F-03

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Remote/SSHWindowsFileEvents.swift:190`
- 摘要：`SSH 事件流 stdout 单独 EOF 时仍等待 stderr，健康态可能停止轮询至租期超时`
- 风险：`持续流的 stdout 关闭时仅把 outFD 从 openDescriptors 移除；若 stderr 仍被远端子进程持有，while 会继续等待 stderr 直到 leaseSeconds+20（默认约 80 秒）。上层 SSHWorkspaceFileEvents 的 healthy 在事件流结束前保持 true，ToolPanelView 不执行 2 秒回退查询，外部 Files 变化在这段时间不可见。`
- 预期修复：`把 stdout EOF 或不可恢复 read 错误作为事件通道立即失效，保留既有错误／END 区分，退出观察、取消独立 SSH 并由上层恢复轮询；不新增抽象。`
- 验证：`针对 stdout/stderr 独立 pipe EOF 的可达逻辑核验；真实 Windows 的正常事件、根消失与 EOF 回退，完成后定向 host/SSH 测试及严格签名构建。`
- 解决证据：`93064ef; stdout EOF now terminates poll loop despite stderr remaining open; static source verification; real Windows EOF via root move LOST test 6/6 /tmp/bailey-p2-audit-windows-green-20261026.log; explicit split-EOF fault injection not run, keep this limit in audit; Bailey Dev GUI PASS.`


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

- `93064ef`（F-03/F-04/F-05）：事件 `stdout` 是唯一可信帧通道；其 EOF 不再因 `stderr` 仍打开而保持健康态直至租期超时，及时结束观察并让 Files 恢复原轮询。删除仅测试使用的 `events()` 包装，生产与宿主统一带显式取消的 `subscribe()`；补真实 Windows 进程归属计数（取消后 1→0）、中文／空格路径与 550 次突发、完整 Bailey Dev 远端 GUI。没有新增服务、轮询器或额外远端持久进程。
- **极端负载必须区分**：550 次创建／删除的一轮纯事件断言出现 `healthy=false`，此状态本应触发 UI 原 2 秒轮询，不能误报为文件已经被删除；随后用符合实际 Gate 的事件或必要回退两路径断言实测 250 个剩余文件并通过。另一次真实生产事件通道在 550 次操作中直接收敛（`eventConverged=true`）；不声称高频时监听永不退化。
- `cf3ec1d`（F-01）：项目所有者释放后不再重新建立 SSH 监听进程。
- `84833c3`（F-02）：实际目录批量读取失败时保留可信缓存并向上报告失败，恢复原有轮询；不新增远端查询。

## 验证日志

- **本轮全量宿主（提交 `93064ef`）**：`make test` **648 项执行，633 通过、15 项环境条件跳过、0 失败、退出码 0**；日志 `/tmp/bailey-p2-audit-full-host-20261026.log`，xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-36-26-+0800.xcresult`。15 项未在默认环境提供远端授权，明确记为跳过而非通过；下列获授权真实 Windows 专项独立补验。
- **本轮授权 Windows 远端联动**：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHFileTreeLiveTests,RemoteLifetimeTests,GitRemoteRefreshIntegrationTests,SSHGitRecoveryLiveTests,GitWorkspaceSSHTests` **15/15 PASS、0 跳过、退出码 0**，日志 `/tmp/bailey-p2-audit-windows-integration-20261026.log`，xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-45-35-+0800.xcresult`。覆盖远端批量目录、失败隔离、复制／移动／删除／重命名、字节保真、Git 外部改动轮询、历史/Ref/工作树、独立连接生命周期及断线恢复的获准场景。这些是 P2 未替换的真实功能回归，不代表 SSH Git 已事件化。
- **最终构建签名**：提交 `93064ef` 之后 `make build:dev` 与 `make build:ui` 均退出码 0，对生成的 `build/DerivedData-Dev/Build/Products/Debug/Bailey.app` 分别执行 `codesign --verify --deep --strict` 均退出 0。日志 `/tmp/bailey-p2-audit-final-{dev,ui}-build-20261026.log`。构建／测试均为隔离 Dev，未替换正式 App。对 Windows `/tmp` 按本轮独有的 `bailey-p2-owner-*`、`bailey-p2-reap-*`、`bailey-p2-ui-*` 前缀读回，未见测试目录残留；没有按进程名杀用户程序。
- **本轮独立 Windows 与 GUI**：以 `ssh windows`（MSYS2 + `powershell.exe` + `cygpath`）直连确认可达，未共享用户 master。`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHWindowsFileEventsTests` **6/6 PASS，0 skip**（`/tmp/bailey-p2-audit-windows-green-20261026.log`，xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_02-30-47-+0800.xcresult`；测试升级 550 次突发前）。专属 PowerShell 清理、根移动回退定向 **2/2 PASS**（`/tmp/bailey-p2-reap-corrected-20261026.log`）。`WorkspaceFilesUITests.testAuthorizedWindowsSSHExternalFilesRefreshInRealApp` 经完整 Bailey Dev `File→Add SSH Files or Folders`、Files、Git 隐藏／恢复，真正由另一 SSH 命令创建、改名、删除中文路径并核对远端文件字节，**1/1 PASS**（`/tmp/bailey-p2-windows-gui-20261026.log`，xcresult `build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.26_02-28-00-+0800.xcresult`）。只创建并清理获准的 `/tmp/bailey-p2-*` 测试目录／专属 SSH socket，不改正式 App。
- **实际高频事件**：在 `testAuthorizedWindowsPinnedProjectUsesEventsAndSharesOneSubscription` 中执行 400 次文件创建与 150 次删除，要求最终精确 250 条并禁止错误旧条目。第一轮仅事件条件失败，监听变为不健康，真实磁盘仍有 250 文件（`/tmp/bailey-p2-audit-burst-green-20261026.log`）；测试保留事件健康时的直接收敛断言，以及失效时执行与面板一致的 2 秒后读盘分支；重测 **1/1 PASS**，但本次实际走的是事件分支（输出 `BAILEY_P2_STORM operations=550 remaining=250 eventConverged=true`，日志 `/tmp/bailey-p2-storm-fallback-green-20261026.log`），**不能冒称已在该次高频场景执行回退分支**。回退的生产条件和单独根失效／目录失败回归仍须保留。
- **EOF 代码缺陷**：源代码静态路径明确原逻辑仅用 `openDescriptors.isEmpty` 退出，`stdout` EOF、`stderr` 被继承仍打开会延长健康状态；`93064ef` 使用 `openDescriptors.contains(outFD)` 直接判断事件通道存活，实际 ROOT LOST／正常 EOF Windows 回归通过；**未独立注入故意遗留 stderr 的 split-EOF 场景**，不把一般 EOF 测试冒充完整故障矩阵。
- **死代码与职责边界**：CodeGraph 复扫确认唯一 `SSHWindowsFileEvents.subscribe` 生产入口；GitStatusModel 的 `runRemoteRefreshLoop()` 5 秒、TerminalSession 存活／cwd 检测、Panel 不健康 2 秒回退均有真实消费者，不删除这些独立机制。
- Red→Green：新增 `FileTreeModel.sync` 失败传播断言时按预期编译失败；修复后 `make test:FileTreeTests,PanelContextTests` 76/76 通过，失败保留旧行、恢复后读取新行。证据 `/tmp/bailey-p2-audit-f02-{red,green}-20261025.log`。
- 真实 `ssh windows`：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHWindowsFileEventsTests,FileTreeTests,PanelContextTests,RemoteLifetimeTests,ProjectFileIndexTests`，95/95 通过、0 跳过；实测外部变更、共享订阅、根切换、符号链接与根丢失后回退。日志 `/tmp/bailey-p2-audit-f02-windows-20261025.log`。
- **历史（10/25）全量基线**：`make test` 627 项、615 通过、12 项 SSH 条件跳过、0 失败（`/tmp/bailey-p2-audit-f02-full-20261025.log`），不能替代 `93064ef` 之后的本轮全量验证。
- **历史（10/25）签名基线**：`make build:dev`、`make build:ui`、`make build` 全部退出 0，正式 Debug 严格 codesign 通过（`/tmp/bailey-p2-audit-f02-build-{dev,ui,formal}-20261025.log`）。本轮实际运行了 GUI，不再把历史 UI build-only 写为本轮结论。
- 实测环境为 macOS 27.2 和 Windows 10/MSYS2 的 `ssh windows`；事件合并、PTY 清理/租期的 P2-T1 远端实验继续有效。SSH Git 只读查询自触发已复现，维持其 5 秒轮询及独立终端存活/cwd 探测。
- **本轮未测边界**：① 已通过单窗口真实 SSH Files GUI，但多窗口同时拥有不同 `Project`、后台唤醒、完整键鼠焦点及 Windows SSH 断线重连联合 GUI 仍无同一 App 完整 E2E；② macOS 15.6 真机缺席；③ 半开 TCP、丢包、网络中断、不可移动卷、拒绝权限、真实 FileSystemWatcher 内部缓冲溢出的专项注入未独立完成；④ 每个不同 `Project` 可能需要约 67 MiB 的 PowerShell watcher，多窗口长时间 CPU／内存没有实测预算；⑤ stdout/stderr 独立 EOF 注入没有单独通过。不得据此宣称所有系统与异常都已 Go。
- 长期行为由 `docs/features/files.md`、`docs/features/ssh.md`、`docs/testing.md` 维护；实验及未测证据归当前 Feature。

## Gate（是否允许进入下一阶段）

- **正常 Windows 10／MSYS2、当前 Mac 27.2、独立 SSH Files（单窗口）：`Go`**，且监听意外结束必须恢复原 2 秒轮询；原实现 `2f5fac7` 与修复 `cf3ec1d`、`84833c3`、`93064ef` 全部在生产消费链中。条件型 P2-T3 的 **SSH Git：`No-Go`**，不能以自触发 `index.lock` 噪声替代安全去噪或删除 5 秒刷新。
- **全平台发布与所有网络故障场景：`No-Go`**，受上述多窗资源、macOS 15.6、网络与 overflow 注入约束；已通过的真实 Windows 目录和 GUI 只证明当前条件。

## 最终状态与剩余风险

- 当前状态：`F-01～F-05 Resolved`，本轮独立修复提交 `93064ef`。P2-T1 是技术验证（无实现 commit），P2-T2 正式接入并经真实主机与 Dev GUI 核销，P2-T3 因 Git No-Go 保持旧机制（无变更 commit），三项各自符合条件式任务定义。`todo.toml` 原提交指针不改，审计证据存本文件。
- 剩余风险：多窗口与长时间 67 MiB/Project 订阅资源、macOS 15.6、其它卷、半开/丢包及真实溢出故障仍需环境，不能宣称完整平台 E2E 已完结；SSH Git 无法安全去噪前继续 5 秒轮询。正式 Bailey App 未安装、替换、启动或发布，本轮只动 P2 代码、宿主/UI 测试和长期测试文档。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

