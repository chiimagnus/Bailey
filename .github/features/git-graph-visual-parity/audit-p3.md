# Audit P3 - git-graph-visual-parity

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/git-graph-visual-parity/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 对齐提交行布局密度与Merge状态
- [x] P3-T2 节点悬停与跨场景视觉回归验收

## 任务到文件的映射

- P3-T1 — `48506e9c937fb8ba7b4bcfc3247e09a069c3e1a8`
  - `kero/Git/RecentCommitsView.swift`：唯一提交行 `commitRow` 调整为「Ref/Stash → 标题」，Merge 只弱化标题，SHA/作者/相对时间不改变原生交互。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：按实际布局更新标签、标题、Tag、右键命中；未修改共享树组件。
  - `docs/features/git.md`、`docs/ui.md`：同步图谱显示与行内动作说明。
- P3-T2 — `d12e93718264ac5975bc2c1b2de12d5e6610b21e`
  - `kero/Git/CommitGraphLayout.swift`：基于加载的父边一次计算 `knownHeadHistory`，只证明可达，不推断未加载历史。
  - `kero/Git/RecentCommitsView.swift`：原生节点 `help`、局部圆形命中及完整 SHA／直接 Ref／Stash 提示；与既有 `toggle` 和提交菜单同一消费者。
  - `KeroTests/Unit/Git/CommitGraphLayoutTests.swift`：Detached HEAD、Merge 多父、交叉拓扑、缺页、1001 行 31 车道及 30 次计时。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：本地化悬停内容、原生节点点击只切换一次、右键不串目标。
  - `kero/Resources/Localization/Git.xcstrings`、`docs/features/git.md`、`docs/ui.md`：中文提示与行为合同。

## 发现项

## 发现 F-32

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/Integration/Git/SSHGitRecoveryLiveTests.swift:21`
- 摘要：`授权 Windows 全量 Git 回归中远端断线恢复测试的 XCTest 宿主进程提前以 code0 退出，405 项出现一次不完整运行`
- 风险：`xcresult 明确记录 404 passed、1 failed、0 skipped；失败原因为 the test runner exited with code 0 before finishing running tests，测试宿主随后重启并将该案例标失败，不是 XCTAssert 失败；不能将这轮全量试验误报绿色，需排除并行构建、进程退出与 SSH 恢复流中的实际缺陷`
- 预期修复：`先提取 xcresult/runner诊断，使用独立 DerivedData 单独多次运行专用 Windows SSH 真实失败恢复用例，再在无并行冲突环境运行最新 406 项全量；有产品可复现根因再修改责任代码，不为未知宿主退出添加重试安全围栏`
- 验证：`xcrun xcresulttool get test-results summary --path ...; KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-graph-audit-theme ONLY_TESTING=KeroTests/SSHGitRecoveryLiveTests；最终最新 HEAD 全量406/406 0失败0跳过。`
- 解决证据：`Root proven twice via native macOS xcresult logarchive: during 405/406 Windows full suites actual AppKit performKeyEquivalent→sendAction→NSApplication.terminate, normal code0 exit; xcodebuild reports 404/405 and 405/406 completed. Independent real Windows GitWorkspaceSSH (142.266s) and SSHGitRecovery (38.789s) passed. Commit e5c82e5 suppresses default App Quit Command-Q solely in --isolated-ui-test CommandGroup; no retry, no production quit behavior change. True test-host NSApp.mainMenu regression first Red failing, then Green passing; KeroTests/RecentCommitsViewTests 24/24, AppIdentityTests 3/3; make build:release + strict codesign exit0. Fresh whole authorized Windows SSH command KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-graph-audit-theme exit0 with xcresult 407/407 passed, failed0, skipped0, includes GitWorkspaceSSH 139.315s, SSHFileTreeLive 29.610s, SSHGitRecovery 35.891s, no runner exit. Full log /tmp/kero-graph-audit-post-isolation-windows-407-20261017.log, xcresult build/DerivedData-graph-audit-theme/Logs/Test/Test-kero-2026.10.17_15-06-16-+0800.xcresult; minimum macOS 15.6 GUI E2E still Deferred F-01.`


## 发现 F-31

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`KeroTests/NativeUI/Git/GitExternalRefreshTests.swift:389`
- 摘要：`Windows SSH 面板隐藏测试没有排除隐藏前已经开始的分阶段历史查询`
- 风险：`只等 changedEntries 这一早到核心信号，不等 isRefreshing false 就移除 View 并写入新 HEAD，可能把之前启动的历史查询结果错误判定为隐藏后新轮询；本轮授权实机运行对此断言 1 项失败，须隔离竞争条件才能判断产品实际缺陷`
- 预期修复：`在模拟隐藏前先等当前 SSH Git 全量刷新完成，再更改实际 HEAD 并验证没有隐藏后的周期请求；如果在严格闲置后仍失败，再沿 ToolPanelView .task(id:) 与生命周期修根因，不能添加定时重试或无关防护`
- 验证：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test ONLY_TESTING=KeroTests/GitExternalRefreshTests；实机确认背景、恢复、隐藏期间无新查询，以及当前模型真正刷新后恢复`
- 解决证据：`Red (authorized Windows): 401 executed/1 failed/0 skipped, GitExternalRefreshTests.testVisibleSSHPanelRefreshesExternalGitChanges failed hidden polling assertion; before removal view a prior remote staged/core update was observed but pending full detail read not yet settled. Add precondition !model.isRefreshing and old newHead history confirmed before hiding; commit 2f9e170. Green: KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-graph-audit ONLY_TESTING=KeroTests/GitExternalRefreshTests: 3 passed, 0 failures, 0 skipped, command exit 0; Windows SSH case passed 69.053 s. Real product ToolPanelView .task cancellation unchanged. Log /tmp/kero-graph-audit-ssh-refresh-green.log.`


## 发现 F-01

- 任务：`P3-T2`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`.github/features/git-graph-visual-parity/plan-p3.md:67`
- 摘要：`独立 App 菜单、分页及系统悬停气泡没有在同一前台 E2E 流程中完整复测`
- 风险：`已在隔离真实 App 中证实图谱显示与节点展开，但这三项在独立进程中仍属于未验证，不能把 NativeUI 测试冒充完整独立进程 E2E`
- 预期修复：`在不会干扰用户工作会话的专用图形桌面中，使用隔离仓库补做 +N 右键、30→60 翻页与实际帮助气泡的同一路径验收`
- 验证：`在独立 macOS GUI 会话启动 --isolated-ui-test，截图记录菜单各项、翻页前后行数与节点 hover；保留对应 App 及 Git fixture 证据`
- 解决证据：`替代性覆盖：RecentCommitsViewTests 20/20（真实 NSHostingView 菜单、Tag/Ref/Stash 命中与分页触发）、GitStatusModelTests 26/26（真实 Git 30→60 分页）、真实隔离 Kero App 的图谱与 Merge 节点展开 side.txt 已验证；但用户使用的桌面焦点持续改变，未能可靠地在同一独立 App 完成菜单+分页+系统气泡的全过程。无已复现产品功能错误，待专用 GUI 环境补测。`


本阶段发现项由工具记录并追踪。源码、操作权限、节点与数据归属未检出可复现的阻塞级缺陷；F-01 是独立进程的完整 E2E 证据缺口，不等同于已确认的产品 bug。

## 修复日志

- P3-T1 把 Ref 排到消息前后，原有坐标测试准确复现了错误命中；在该任务内根据新的真实元素位置重测，保留 Tag 第二次点击不收起、各个 Ref 右键不串目标、标题展开等原有合同。
- P3-T2 的 Hover 不额外发 Git/SSH 请求或建悬浮窗口、缓存、定时器；复用 `TreeRowSurface`、局部透明节点 Button 和现有 `CommitGraphLayout`。实际 MAC AX 控件定位与右键 XCTest 匹配代码；旧版固定蓝色路径、系统配色与 Capsule 已在所属任务清理。
- F-01 未作虚假修复：因用户正常工作会话使隔离窗口焦点/几何频繁变化，原生 GUI 自动化无法可靠完成一条从右键菜单到翻页的**同进程**录制路径。保留 `Deferred`，给出针对性补测入口；没有为了通过流程往产品加专用自动化接口。

## 验证日志

- `make build` + `codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` → **PASS**，Debug macOS App 成功签名，无 Swift 编译错误；Xcode CoreSimulator 版本警告不影响 macOS 构建。
- `make test` → **PASS**，全部 397 项、0 失败、6 skipped（全部为需要授权 Windows SSH 主机的 live fixture）。日志：`/tmp/kero-graph-final-all-tests-20261017.log`。
- `make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests` → **PASS**，20/20（P3-T2 新增交叉 DAG 及 30 次性能采样后）；1001 行、31 车道、30 次 Debug 布局：median 0.077s、p95 0.079s、max 0.080s。
- `RecentCommitsViewTests` → **PASS**，完整全量 XCTest 中 20/20，标签独立点击/右键、Stash、中文与标题、节点命中、分页触发、无整体横滚；`GitStatusModelTests` 26/26，`GitRemoteBranchActionTests` 15/15，`GitStashActionTests` 12/12，`TreeRowHitTestingTests` 5/5 均在全量测试中通过。
- **真实独立 macOS App**：以 `--isolated-ui-test` 新启已签名 Debug 实例，打开受控 `/tmp/kero-git-graph-ui-*` 仓库（36+ Git 提交、Merge、Tag、Stash、`origin/HEAD`）。辅助功能树显示 GIT GRAPH 37 项、`main`、`origin/main`、折叠中的 `v1.0, origin/HEAD`、Stash；真实截图为 `/tmp/kero-graph-e2e-git-real.png`。再对实际 Merge 节点执行 `AXPress`（返回 code 0），截图 `/tmp/kero-graph-e2e-ax-node-after.png` 证明正确展开 `side.txt` 历史文件。
- 独立 Debug App 进程、仅供本轮测试的 Git 仓库和快捷链接均清理；正式 `/Applications/Kero.app` 进程 PID 10096 **未被退出或重启**。再次 `make build` → **PASS** 后，用同卷临时目录整包暂存安装、安装前后执行 `codesign --verify --deep --strict`，新包成功更新至 `/Applications/Kero.app`，无残留暂存/备份。当前运行进程仍保持旧代码，用户自行重启后新包生效。上述截图没有写入项目提交。
- `git diff --check`、`todo validate`、六个提交的变更文件列表、最新 `GitPanel → GitStatusModel → RecentCommitsView → CommitGraphLayout` 调用链与参照截图核对 → **PASS**；本轮没有读取既有审计结论来取代源代码检查。
- 当前文档职责：Git 拓扑、Ref 绑定与 Stash 动作 `docs/features/git.md`；仅图谱外观、悬停、行密度 `docs/ui.md`；验证策略引用 `docs/testing.md`。未增加重复实现或全局 Theme 特例。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（保留 F-01 `Deferred` 的已声明验收边界）
- 理由：P3-T1/T2 两项已独立提交并真正接入现有 Git 面板；构建验签、全量 XCTest、强化的图谱/原生交互测试和隔离独立 App 实际历史文件展开均已通过；尚未复测的**单一独立 App 完整菜单→分页→帮助气泡链路**已在发现项中明示，不冒充通过，也未发现现行功能错误。

## 最终状态与剩余风险

- 当前状态：`Resolved`（实现与自动化验证；单独图形桌面最终 E2E 作为 `Deferred` 跟进）
- 剩余风险：F-01 独立进程完整菜单/翻页/气泡联动仍未逐项走通（但每项已有 NativeUI/模型证明）；6 个授权 Windows SSH 条件测试在未配置专用测试主机的这轮全量运行中被正确跳过。未声称 Git Graph 可保证任何输入下无 bug，也未将当前隔离 UI 截图当成与 VS Code 不同 DPI 的逐像素相等证明。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 本轮独立逐提交复审（2026-10-17；不采用既有 audit 结论）

- P3-T1：`todo.toml` 中原 SHA `48506e9` 的提交在当前分支对应 `91d0a34`，两者 `git patch-id --stable` 完全相同。检查 `GitPanel.changeList → RecentCommitsView.commitRow`：Ref/Stash 位于标题前，Merge 仅弱化标题、悬停后恢复，第二行 SHA/系统字体作者/右侧日期不改变；实际按钮、全文标题单独滚动、文件树折叠均复用原生共享行。旧的作者斜体衬线/标题优先样式已替换，不存在另一个 Merge 专用图谱渲染器。
- P3-T2：原 SHA `d12e937` 对应本分支 `68ee700`，patch-id 一致。`CommitGraphLayout.knownHeadHistory` 仅沿已加载父边自当前 HEAD/Detached HEAD 追踪；`nodeHelp` 只写完整 SHA、真实 Ref/Stash 和已证明的 HEAD 祖先；圆形 Button 位于绘制节点上，原生 `.help`、鼠标主键展开、右键提交菜单皆复用现有路径而不创建自定义悬停任务或新增 Git 查询。测试对直接按钮、`+N` 分段菜单、宽窄侧栏、Stash、Merge、多父/未知祖先和展开文件均有覆盖。
- 两份参考截图与主机已有隔离 App 截图本轮重新读取核对：图谱路径、Ref 分段、节点形状与提交信息的顺序一致；截图来自不同仓库/主题/窗口宽度，不能伪称逐像素相等。用户正在使用中的正式 Kero 不用于 UI 自动化，也不重启。
- `todo.toml` 原记录的是改分支前的提交；本轮在全部六个稳定 patch-id 对应后，用 `feature_tool.py todo set-status` 逐条修正为当前分支真实 SHA。原始提交证据未删除，当前六个新 SHA 均已被 Git HEAD 包含，`todo validate` 已通过。
- F-31：授权 Windows SSH 实机测试揭示隐藏期间的历史更新断言失败；只等分阶段的 `changedEntries` 而未等 `isRefreshing=false`，不能据此直接证明隐藏后仍启动周期请求。先把前次查询与被测新轮询分离，再决定是否修产品的可见性生命周期。详见本轮 finding 与随后实机复测日志。

### 本轮适用条件与极端边界核销（独立于既有审计结论）

| 已识别的环境或条件 | 本轮实际覆盖与原始证据 | 范围与未测情况 |
| --- | --- | --- |
| 真实 macOS / 工具链 | macOS 27.2、Xcode 27.2、Apple Git 2.54.0、Apple Silicon；`make build` 命令退出 0，`make test` 401 项、0 失败、6 项因未设置专用 SSH 主机跳过 | 真实最低支持的 macOS 15.6 没有可使用的测试主机，未验证最低 OS 运行时；编译与现有 SDK 部署检查不能冒充 15.6 运行 |
| Git DAG 正常、异常、极端规模 | `CommitGraphLayoutTests` 22/22：空图、unborn、线性/root/非连通、并行 tip、交叉/多父/Octopus/Merge、两条非重叠绕行、缺页与翻页、随机 120 节点多父序列、1000 线性、1001 行和 31 车道重复布局 30 次 | 1001 行布局本轮日志中中位约 0.073 秒、p95 约 0.075 秒，未把 CPU 估计等同独立前台滚动帧率 |
| Stash 与可见性边界 | `GitStashActionTests` 12/12：同 OID 不同 selector、base 有/无、真实 Apply/Pop/历史及文件；新增 40 个 base 缺页 Stash 的 Red（41 车道）→Green（2 车道） | 未在用户真实工作仓库制造/清空 Stash，所有变更限独立临时 fixture |
| 引用／解析／组合／目标安全 | `GitRemoteBranchActionTests` 15/15、`GitStatusModelTests` 26/26、`RecentCommitsViewTests` 21/21：真实符号/非符号 `origin/HEAD`、多个已配置/未配置 remote、最长前缀、Tag、同一提交的 34 个 Ref、跨提交不合并、Unicode／逗号、分段左键复制/右键；原目标身份、OID 和授权校验仍完整生效 | 还以真实 Git SHA-256 临时仓库预检 64 位哈希、Unicode+逗号分支/Tag 与符号远端，Git 命令成功；这项独立 Git 预检**不等于**已经从完整 Kero App 走完该 fixture 的点击 E2E |
| 颜色、主题、缩放、命中 | 原生 NSHostingView 测试：12 色准确性、12 色图标对比至少 4.5:1、aqua/darkAqua 下 HEAD 和 Stash 可点击、260pt+1.6 字号和 420pt+正常字号、30 并行车道无整表横滚、左右键、Tag 重复点击、Git 文件 tree/list、短标题防回弹、菜单复制及 hover 帮助 | 自定义 Ghostty 主题、独立 2x 外接显示器、触控板长距离拖拽、运行时连续调整侧栏宽度和系统 VoiceOver 人工路径暂未单独做全功能手动 E2E。不能因原生宿主绿色宣称这些已测 |
| 本机生命周期、恢复与两窗口 | `GitExternalRefreshTests` 本机实时变更/隐藏/激活均验证；`WorkspaceWindowIsolationTests` 等完整工作区宿主测试运行。更高层对外部工具启动的 Git 变化没有增设新查询路径 | 不在真实用户正在使用的 Kero 安装包里测试、重启或更改设置；只能在隔离实例中测试 |
| 获授权 Windows SSH | 首轮完整 401 项、1 个旧测试前置竞态失败、0 跳过；`GitExternalRefreshTests` 修正前提后专用主机重测 3/3、0 跳过（SSH case 69.053 s）；真实远端 Rebase、文件树、Git Push/Delete/Zip/历史恢复/Stash/Clean、连接故障恢复测试已经分别运行通过 | 最终已修正代码的 `windows` 主机全量命令再次独立执行中，待最终完整退出状态核销；不对用户现有 SSH master 注入真实断网或杀进程，故仅验证专用 socket 与独立失败注入 |

禁忌边界：不修改或导出用户机密、不访问用户在用仓库执行破坏性 Git 命令、不清理共享构建目录、不使用正在打开的 Kero 窗口进行无授权的自动化。具体用户路径在独立 App 做过的部分只按实际证据报告；XCTest 原生宿主/静态截图不冒充独立完整前台 E2E。

**64 位对象及特殊 Ref 的命令级夹具细化：** 在 `/tmp` 创建 SHA-256 Git 仓库，使用生产 `recentCommitLogArguments` 完全相同的 `--decorate=full`、`--date-order`、`--diff-merges=first-parent` 与 `%(decorate:separator=%x1d)` 格式直接查询，得到 64 字符完整提交 OID、两条 64 字符父 OID，以及用 `\x1d` 独立分隔的 4 个引用：`HEAD -> refs/heads/main`、`tag: refs/tags/版本,β`、`refs/remotes/origin/main`、`refs/remotes/origin/HEAD`。说明 Git 真实命令输出没有丢失 UTF-8/逗号或符号 Ref，且与生产解析器的 7 个 Unit Separator 字段输入格式一致；这仍是 CLI 输入事实，不夸大成完整 App 的 SHA-256 E2E。原始二进制响应记录仅在 `/tmp/kero-graph-audit-sha256-native-log.bin`，未提交含用户信息的夹具或新增非 XCTest 永久实现。

### 本轮授权 Windows 全量重验与严格签名（最终结果）

- 首轮的 SSH 401 项、1 失败、0 跳过，根因是原 `GitExternalRefreshTests` 在 SSH `changedEntries` 早到后立即隐藏视图，未等待历史／Ref 部分完成；修复为**校验已启动刷新真正结束**，不改产品轮询。代码以单独原子提交 `2f9e170` 落地。F-31 已用审计脚本回填 Resolved。
- 有同一正式 Kero XCTest 目标的实际 Green：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-graph-audit`，**401 项，0 failures，0 skipped，退出码 0**，合计 682.719s，日志 `/tmp/kero-graph-audit-windows-full-final.log`。明确逐项包括 `GitExternalRefreshTests` SSH 隐藏面板、`GitWorkspaceSSHTests` 真远端 Git 文件与操作、`SSHFileTreeLiveTests`、`SSHGitRecoveryLiveTests`、SSH Rebase、普通原生图谱和 WorkspaceWindowIsolation，所有通过。
- `make build DERIVED_DATA=build/DerivedData-graph-audit` 完整退出 0，日志 `/tmp/kero-graph-audit-build-final.log`。紧随其后的 `codesign --verify --deep --strict --verbose=2 build/DerivedData-graph-audit/Build/Products/Debug/Kero.app` 返回 0，输出 `valid on disk`、`satisfies its Designated Requirement`，日志 `/tmp/kero-graph-audit-codesign-final.log`；构建／签名是独立检查，不由 XCTest 绿色推断。
- 隔离 App 当前代码实测：执行 `open -g -n -a build/DerivedData-graph-audit/Build/Products/Debug/Kero.app --args --isolated-ui-test`，获得**独立测试 PID 83554**，正式安装包 `/Applications/Kero.app` 的 PID 94982 始终保持运行，桌面前台仍为用户自己的 Helium。隔离 Kero 的背景窗口可列出，但 Peekaboo 精确窗口 AX 仅返回不完整的 application menu bar，`snapshot_reusable=false`／`mutation_targeting_available=false`，像素+AX 捕获失败；不允许用未核验的坐标冒充点击，也不升级为前台抢用户焦点。只向 PID 83554 发出 SIGTERM 清理该测试实例，正式 Kero 未退出、未修改、未重启。此前保留的隔离 App 图谱截图可证明实际应用曾能展示 Git Graph，但本轮**没有完成独立 App 前台的图谱→菜单→历史文件→分页全程点击**。

### 本轮 P3 最终 Gate（严格按完整验收，不作虚假全绿）

**No-Go（仅对“完整独立 App 前台 E2E 已彻底验收”的无条件声明）；功能代码与所有可安全自动执行的 Unit／Integration／NativeUI／授权 SSH 验证已通过。** P3 两个原始 commit `91d0a34`、`68ee700` 确认真实接入；用户路径的 NativeUI/真实 git 工作区和上一轮隔离运行截图均有证据，F-31 已解决，最新 401/401 + build + codesign 都为 0 错误。未覆盖的条件明确为：① macOS 15.6 最低版本真实运行时（当前只有 macOS 27.2；需独立兼容机），②自定义 Ghostty 主题与独立 Retina/DPI、系统辅助功能人工测试（不能擅自更改用户共享设置／显示器），③完整独立 App 前台鼠标、右键与动态面板缩放／分页流程（背景 AX 不可用、抢占用户工作会话不合适；需获准可占用焦点的隔离 UI 环境）。风险：不同系统视觉细节、极限车道可读性和全 App 路由仍缺独立人工认证。补验方式：在用户明确可交出前台、没有正在使用 Kero 的隔离桌面／测试会话，使用同一临时 Git fixture 从真实 Kero 项目选择到图谱标签、菜单、历史文件、30→60 分页、缩放及悬停逐项完成，不改正式用户环境；另在 macOS 15.6 主机和独立主题/DPI fixture 复核。未完成前不能把 401/401 当作上述环境的 E2E 通行证。

### 按现行 AGENTS.md 完成本地安装（2026-10-17 14:00 左右）

代码 `4b24cfa`、`1d232e6` 和测试 `2f9e170` 经授权 Windows 401/401、`make build` 与 `codesign --verify --deep --strict` 完整通过后，依据 `docs/development.md#本地安装` 将签名 Debug 包从 `build/DerivedData-graph-audit/Build/Products/Debug/Kero.app` 先以 `ditto --rsrc --extattr` 暂存到 `/Applications` 同盘临时目录，独立验签并核对新旧 `CFBundleIdentifier=chiimagnus.kero`；随后**整包**原子移动替换 `/Applications/Kero.app`，验签成功且 `valid on disk` / `satisfies its Designated Requirement`。安装脚本预设失败回滚至原包，实际未触发；已删除临时 stage 和旧包 backup，未留下过时的并行安装包。正式 Kero 原进程 PID 94982 在更新后仍运行，未结束、未启动或重启；用户下次自行重启后才会运行新文件。严格区分**已安装**与**当前旧进程尚未重启**，不把包验签代替当前进程 UI E2E。未对用户在用仓库、主题、SSH master 和保存会话执行破坏性操作。

### 2026-10-17 F-32 进一步定位：隔离 XCTest 宿主接收了前台退出菜单快捷键

此前 405 项授权 Windows SSH 全量测试得到 **404 passed / 1 failed / 0 skipped**，失败测试 `SSHGitRecoveryLiveTests.testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`；随后 406 项全量得到 **405 passed / 1 failed / 0 skipped**，失败测试变成 `GitWorkspaceSSHTests.testAuthorizedSSHRefArchiveBinaryResetStashCleanAndIgnorePersistOnWindows`。两次 XCTest 的直接信息均为 `The test runner exited with code 0 before finishing running tests`，而不是 Git 命令结果或测试断言失败，完整命令均退出 65。

这两次的 `.xcresult` 导出原生 macOS `logarchive` 后发现**共同且实际发生的进程退出路径**：14:39:30.609、14:53:16.680，测试宿主 `kero` 分别记录 `AppKit performKeyEquivalent:` → `sendAction:` → `[com.apple.AppKit:Application] terminate:` → `applicationShouldTerminate: NSTerminateNow` → `Termination complete. Exiting without sudden termination.`。其根因是长时间运行的原生 XCTest 宿主仍响应共享桌面的 `⌘Q` Quit 快捷键（系统日志未标明按键来源，不将其归咎于用户/其它代理）。`xcresulttool get test-results summary` 精确显示上述两轮失败总数，两者都没有孤立的 Git Assert 失败证据。

隔离真实 SSH 用例各自重跑通过：`SSHGitRecoveryLiveTests` 38.789 秒 / 1 passed，`GitWorkspaceSSHTests` 142.266 秒 / 1 passed，真正执行了 Windows 远端失败/恢复、分支推送/删除/归档、二进制复位、Stash、Clean 与 Ignore 的最终结果。

**Red→Green：** 新增 `KeroTests/NativeUI/App/AppMenuIsolationTests.swift`，先用真实 `NSApp.mainMenu` 确认 `⌘Q` 菜单快捷键存在导致 `XCTAssertTrue` 失败；修复 `kero/App/keroApp.swift`，只对 `--isolated-ui-test` 宿主执行 `CommandGroup(replacing: .appTermination) {}`，不阻断标准的程序性退出、不更改正式 Kero 的快捷键、保存与退出处理。随后同一用例 **1/1 通过**，`RecentCommitsViewTests` **24/24 通过**，`AppIdentityTests` **3/3 通过**，`make build:release DERIVED_DATA=build/DerivedData-graph-audit-release` 和严格 `codesign --verify --deep --strict` 均成功。同步 `docs/testing.md` 的实际测试隔离边界。独立原子提交 `e5c82e5`，不混入同期图标资源变动。

**剩余边界：** 这项单一源修复消除了已观测到的 `⌘Q`-菜单 Quit 触发链路，但测试宿主与正在使用的用户桌面仍共享键盘焦点；它不代表完整的 macOS GUI 会话隔离。必须等待最新 HEAD 的 Windows 全量 XCTest `407/407`、退出 0 且 0 skipped，方可将该故障从 `Open` 调整为 `Resolved`；专用独立桌面 E2E、最低 macOS 15.6 和跨 DPI 的人工验收仍遵循 F-01 已声明的 `Deferred` 边界。

### 2026-10-17 15:18 自动化重验最终 Gate

**自动化测试与代码修复：Go。** 最新 Git Graph 与隔离 XCTest 宿主修复 `e5c82e5` 已真实编入 Debug/Test；授权 Windows SSH 完整命令 `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-graph-audit-theme` 完整返回 0，`xcodebuild` 明确 `** TEST SUCCEEDED **`。`xcresulttool get test-results summary`：**407 total / 407 passed / 0 failed / 0 skipped / Passed**，macOS 27.2、Apple Silicon MacBook Pro；包含 F-32 原来失败的 `GitWorkspaceSSHTests`（139.315s）、`SSHGitRecoveryLiveTests`（35.891s）、`SSHFileTreeLiveTests`（29.610s）。新增菜单快捷键原生 XCTest Red→Green，图谱压力/主题/模型全部在同一轮再次通过。源日志 `/tmp/kero-graph-audit-post-isolation-windows-407-20261017.log`，`.xcresult` `build/DerivedData-graph-audit-theme/Logs/Test/Test-kero-2026.10.17_15-06-16-+0800.xcresult`。本轮修复的 Release 构建与严格签名验收通过。

**完整独立 GUI E2E：维持 No-Go / F-01 Deferred。** 单个实际窗口从打开项目到操作弹窗、图谱滚动、真实鼠标、悬停辅助提示的完整流程，仍需要不打扰正式 Kero 的专用 GUI 桌面；最低 macOS 15.6 运行时、其它 DPI 下的实际视觉差异不能由目前 macOS 27.2 的 XCTest 替代。已有的 NativeUI、真实仓库、Windows SSH 验收不能被夸大为上述条件已全部通过。源码审查没有发现新的可复现产品缺陷，F-32 因本轮全量回归闭环确认为 Resolved。

**安装归属边界：** 当时正式 `/Applications/Kero.app` 仍在运行，且同期另一个任务正在修改 Bailey App 图标并提交；本审计没有替换或重启其正式 App，以免用本次较旧的已签名构建覆盖另一任务正在变更的资源。代码提交已在当前分支；安装状态应由图标任务完成后以最新整体构建单独确认，不能宣称本轮已安装或已重启。

### 2026-10-17 15:21 正式包安装核验（补充此前暂缓记录）

图标任务在同一分支完成并提交后，本次以最新 `7aef9da`（包含 `e5c82e5` 及 Bailey 图标提交）重新运行 `make build:release DERIVED_DATA=build/DerivedData-graph-audit-release`，**BUILD SUCCEEDED** 且构建目标的严格签名检查通过。在 `/Applications` 的同盘临时路径完整 `ditto` 新包，复核 `CFBundleIdentifier=chiimagnus.kero`、arm64 与严格签名，再整包换入 `/Applications/Kero.app`，对最终包再次严格验签并核对实际二进制 SHA-256：`ea1ff234a99924b1faeed2e7c206634f3f727691c75ba1da114033a470eba42b`（替换前：`48383e78d6a3ff65942c5dcfa363d38222122561aec59e56e9b9f9760c0becad`）。`INSTALL_COMPLETE=YES`、备份临时目录随安全清理删除。没有结束或重新启动用户现有 Kero；原 PID `85027` 安装后仍存活，因此**已安装但新代码须由用户以后自行重启才能生效**。新版安装包未执行独立前台菜单 E2E，不据此改变 F-01 的 Deferred 状态。
