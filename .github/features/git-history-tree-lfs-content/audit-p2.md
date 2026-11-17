# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：**用户批准豁免放行（Accepted with waiver）；技术 Gate 仍为 No-Go**。
  用户明确要求将本轮未通过的测试视为已接受，停止后续排查与补测，
  允许本 Feature 按现有实现继续推进；这是一项由用户承担剩余风险的验收例外，
  **不代表测试实际通过、也不覆盖日志中的失败断言**。
  #56 历史树与 #82 LFS 已实现并提交，5 项真实 Bailey Dev GUI 和关键远端 Git/LFS 验收有通过证据。
- **依据**：此前 `d1286f9f` 的 Tailscale 全量测试 1089 项，1079 通过、10 项失败、0 跳过；
  失败主要发生在不稳定的 Tailscale SSH 命令，另有 Git Graph 可见性测试失败。
  `b2a39e0c` 将文件事件测试分阶段验证，并统一测试夹具与生产一致的 SSH 期限。
  Tailscale 下仍因握手超时失败；切换获用户授权的 Cloudflare SSH 后，
  `SSHWindowsFileEventsTests` 6/6 实际通过、0 失败、0 跳过，退出码 0。
  另一次无 Windows 环境变量的完整宿主测试 1089 项、18 远端跳过、
  1 项 Diff 性能矩阵测试出现 2 处断言失败；该矩阵独立复跑 30 轮通过。
  `b2a39e0c` 的 Cloudflare 全量测试 1089 项中有 1 个 Windows 文件事件压力用例失败；
  `b522e259` 修正测试未在切换根目录后执行 Files 模型同步的夹具偏差，
  改动后该用例及事件类 6/6 均实机通过。
  `b522e259` 最终 Cloudflare 完整宿主测试运行约 33 分钟后，用户要求先跳过；
  停止前 978 项通过、4 项失败、0 跳过，其余未执行完毕。
  4 项失败包括 3 项 Windows SSH 命令 25 秒超时，以及 1 项 Git clean 未实际删除文件／目录的两条断言。
  已对本次自有 `xcodebuild` 发送 TERM，`make test` 返回 143／`BUILD INTERRUPTED`；
  测试锁已释放，未结束任何用户后台任务。
  日志：`/tmp/bailey-p2-final-cloudflare-b522e259-full.log`。
  **验收决策更新**：用户在 2026-11-18 明确批准跳过剩余失败项并按可继续推进处理。
  因此本 Feature 不再因这轮测试阻塞后续工作；技术 Gate 仍记录实际 No-Go，
  未确认的 Git clean 文件／目录清理与偶发 SSH 初始化超时列为用户已接受的遗留风险，
  需要重新验证时仍以原始 XCTest 日志为准，不得引用为全量测试通过。
  未修改正式 Bailey、未 push main、未修改用户 SSH 配置。

## 任务与改动

- **P2-T1 离线解析锁定的 LFS 指针并读取经校验的真实字节**：
  `168b904d`。
  `DiffTab.gitContent` 先锁定 Git Blob OID，再识别标准 v1 LFS pointer，
  读取目标机器 `git lfs env` 的 `LocalMediaDir`，经现有 `WorkspaceBackend.read`
  校验真实字节数、SHA-256 及 5 MiB 上限后按严格文本编码解码。
  缓存缺失、损坏、畸形、超限、Git LFS 缺失均不回退成 pointer 文本；不触发下载。
  `NativeGitHistoryFileTests` 真实测试和 `docs/features/diff.md`、`Git.xcstrings` 同步。
- **P2-T2 用真实 LFS 正文计算差异并守住 Git 规范化与保存边界**：
  `472b7906`。
  旧 Git Blob 为 LFS pointer，或旧 Blob 普通但新属性启用 LFS 时，不执行
  不相容的 Git pointer Patch／`hash-object` clean 比较，
  改用真实正文、Index/历史 OID 及工作区字节版本重新核验；
  非 LFS 保留原来的 Git EOL、BOM 和自定义 clean filter 语义。
  pointer-only checkout 禁止冒充可编辑正文；条件保存、原生编码和冲突保护不变。
  `NativeDiffTabTests`、`NativeGitHistoryFileTests` 均以真实临时仓库测试。
- **P2-T3 以隔离真实仓库和 Bailey Dev 完成跨来源验收**：
  `5fcf9348`、`9ad5eb5b` 和 `da23b093`，真实 GUI 与 Windows SSH 验收已完成。
  复核历史入口后发现 `GitHistoricalFileLocator.resolve` 原本对 live Worktree
  使用 Git diff，会运行 LFS clean 并产生缓存副作用；
  现已删除该探测方式，只比较历史提交与 Index／HEAD。
  增加已提交重命名、暂存重命名、相似度下降需回退 HEAD、Stash 等真实 LFS 测试；
  `GitGraphUITests` 和 `GitHistoryUITests` 已真实执行同路径树与 LFS
  历史／Staged／Worktree 的完整 UI 测试，均通过。
  使用现有 `windows-tailscale` OpenSSH 别名完成 Windows 真实 GUI 测试；
  同时新增 Windows Git LFS 实机完整源测试并验证缓存／HEAD／Index／原文件未变。
  首次 SSH 握手期间输入远端路径被后续盘符导航覆盖的实际问题经 GUI 截图定位，
  模型 Red→Green 修复并再次经完整远端 GUI 验证。
  同步 `docs/features/git.md`、`docs/features/diff.md`、`docs/features/ssh.md`。

## 发现项

- **已修复：历史重命名查询有非预期媒体缓存写入**。
  使用受控 LFS 仓库实测：`git diff <历史提交>` 触及 live Worktree 后，
  对改写过的重命名文件运行 LFS clean，多产生一个本地对象。
  责任位置：`Bailey/Git/GitHistoricalFileLocator.swift`。
  `5fcf9348` 删除 live Worktree 探测路径，替换为 Index、HEAD；
  用真实 LFS 已提交、暂存、暂存改写及 Stash 的 OID／缓存／文件字节核对复验。
- **已修复：SSH 首次握手覆盖用户输入的远端路径**。
  首次握手尚未完成时用户可在原生 TextField 输入绝对路径，
  `SSHFolderPickerModel.selectHost` 随后强制导航默认盘符 `/`，使原路径丢失、Add 始终禁用。
  由实际 XCTest 截图、`addPath` 与调用链证实，隔离的受控延迟模型测试在修复前稳定失败；
  `9ad5eb5b` 优先导航用户已输入的有效绝对路径，不叠加定时器／新状态；
  `SSHFolderPickerTests` 13/13 通过，Windows Tailscale GUI E2E 84.572 秒通过。
- **无证据的额外抽象未引入**：
  Git Blob OID 与 LFS 媒体 SHA-256 分开，复用 `WorkspaceBackend`、
  `WorkspaceFileVersion` 和 `TextFileEncoding`；
  保留对普通 Git 文件仍有作用的规范化分支，未另建 LFS 服务或并行持久状态。
  在旧 Blob 非 LFS、新属性启用 LFS 的情况下，
  一次 `git check-attr` 元数据查询是避免错误调用 clean filter 的必要代价。

## 验证与未覆盖

- `make test:NativeGitHistoryFileTests,GitExecutionTests`：
  P2-T1 阶段 46/46 通过。
  `make test:NativeDiffTabTests,NativeGitHistoryFileTests,DiffEngineTests,GitExecutionTests`：
  P2-T2 阶段 227 项，225 通过、2 个 SSH 条件跳过、0 失败。
- `make test` 第一轮：
  **退出码 0，1081 项，17 跳过，0 失败**，
  报告：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.17_12-43-57-+0800.xcresult`；
  该轮构建早于 `5fcf9348`，不代表新重命名代码已纳入完整回归。
- **最终提交 `5fcf9348` 的完整 `make test` 第二轮：
  退出码 0，1084 项、17 跳过、0 失败，`** TEST SUCCEEDED **`，
  用时 1096.54 秒。**新增的 3 项 LFS 重命名／Stash 回归均在完整测试内执行并通过。
  报告：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.17_13-05-31-+0800.xcresult`。
  17 项跳过全部属于需要真实已授权 Windows SSH 远端的 Git、Diff、文件、事件和恢复测试；
  它们不代表失败，也不能算作远端通过。
- **最新提交 `da23b093` 的全量宿主重跑（未通过，不重复执行）**：
  2026-11-17 17:37 使用 `BAILEY_P4_TEST_SSH_HOST=windows-tailscale` 和
  `TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows-tailscale` 启动 `make test`；
  `GitWorkspaceSSHTests` 两项失败（Git 未及时响应／`timedOut`，含清理失败），
  `NativeDiffTabTests` 两项远端用例亦各自 `timedOut`（30 秒）。
  证据：`/tmp/bailey-p2-t3-full-host-tailscale-final.log`。
  用户已澄清 Bailey 测试应继续，后续定点复测消除上述 4 项超时，并进行了新的完整测试。
- **2026-11-17 18:21 的完整宿主测试**：1086 项，1 项失败（其余 1085 通过），0 跳过，
  唯一失败为 Windows SSH 的 32 MiB 文件传输，受固定 25 秒总截止时间影响。
  Red→Green 修复 `d1286f9f`：在传输 stdin／有界 stdout 时以实际字节进展刷新无进展超时，
  普通命令仍用总截止时间；实机测试包装器明确转发 `runLimited`。
  修复后 18 项相关测试（含真实 Windows LFS、32 MiB 上传／下载／保存／边界、取消／停滞）
  0 失败、0 跳过；日志 `/tmp/bailey-ssh-final-targeted-tailscale.log`。
- **最新完整宿主测试，提交 `d1286f9f`**：
  `BAILEY_P4_TEST_SSH_HOST=windows-tailscale`
  `TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows-tailscale make test`，
  实际 1089 项、1079 通过、10 个失败用例、20 条失败断言／错误、0 跳过，
  `** TEST FAILED **`，耗时约 2913 秒。
  xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.17_19-40-23-+0800.xcresult`；
  终端日志：`/tmp/bailey-p2-final-host-d1286f9f-tailscale.log`。
  其中 9 个 SSH 用例多在命令启动或收尾时达到 25 秒 `timedOut`，
  Git Graph 可见性用例有多条鼠标／AXPress 断言失败。
- **失败项复验**：
  Git Graph 可见性用例独立重跑 41.679 秒通过，不能因此声称全量复现已解决。
  4 个真实 Windows SSH 测试类共 15 项，**14 通过，1 失败**，
  包括远端刷新、32 MiB 文件、重命名、断线恢复与前 4 项事件监听均已在同一组合运行中通过。
  最后失败的 `SSHWindowsFileEventsTests.testAuthorizedWindowsWatcherReportsLostWhenRootMoves`
  抛出 `CancellationError`；源码发现它只给启动（允许 30 秒）、远端重命名和 LOST 共 16 秒。
  `b2a39e0c` 将 READY（最多 32 秒）、远端重命名与 LOST（16 秒）分阶段验证，
  并核对最终 Windows 磁盘位置；5 处测试后端与生产统一使用 25 秒命令期限。
  修订后经 Tailscale 单项与两项组合分别通过，但完整事件测试类依旧受远端 SSH 失稳影响，
  先后出现 4/6 和 1/6 通过的失败执行。
  Tailscale 当时只能走 DERP（dfw/sfo/nue 等），Ping 约 0.4–1.4 秒且无法建立直连；
  独立 `ssh windows-tailscale` 能在 TCP 22 已连通后停于 `SSH2_MSG_KEX_ECDH_REPLY` 密钥交换，
  与 Bailey 业务命令、PowerShell 监听器无关，不能将这些网络错误归为已证实的产品缺陷。
  原组合日志：`/tmp/bailey-p2-recheck-four-ssh-classes-d1286f9f.log`；
  Tailscale 事件类最终失败日志：`/tmp/bailey-p2-windows-events-b2a39e0c.log`。
- **Cloudflare SSH 真实复核**（用户批准改用现有 `windows` 别名并手动登录）：
  `ssh -G windows` 已确认使用 `cloudflared access ssh` ProxyCommand，而不是 Tailscale；
  Windows Git 与 Git LFS 真实返回版本信息，6 项 `SSHWindowsFileEventsTests` 全部通过，
  0 失败、0 跳过、退出码 0，含 READY→根目录移动→LOST 和文件事件实际刷新。
  记录：`/tmp/bailey-p2-cf-windows-events-b2a39e0c.log`，
  `build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.17_22-59-12-+0800.xcresult`。
- **Cloudflare 完整宿主测试（`b2a39e0c`，未通过）**：
  2026-11-17 23:05 起运行全部 1089 项，1088 项通过、1 项失败、0 跳过，
  合计 2 条失败断言。唯一失败在
  `SSHWindowsFileEventsTests.testAuthorizedWindowsPinnedProjectUsesEventsAndSharesOneSubscription`：
  550 次远端文件操作正确收敛为 250 项，但换根目录后新的事件订阅未恢复 healthy。
  源码对照 `ToolPanelView` 的真实行为发现，测试只设置 `Project.customDirectory`，
  没有执行真实 Files 面板的 `Project.syncFiles` 目标切换与两秒失败重试，
  就安装新目录监听器；需要先把文件树根目录切到新目标，才能验证真实的订阅重绑定。
  `b522e259` 复用原有 `project.syncFiles`，初始与切换目录均走同一测试内同步入口，
  仍完整验证 550 次变更、新订阅和新文件真实上屏；不修改生产代码或普通 SSH 超时。
  改动后单项实机 77.457 秒通过，全 `SSHWindowsFileEventsTests` 6/6 通过、0 跳过、退出码 0。
  失败证据：`/tmp/bailey-p2-final-host-cloudflare-b2a39e0c.log`；
  修复证据：`/tmp/bailey-p2-cf-root-rebind-green.log`、
  `/tmp/bailey-p2-cf-events-post-root-sync.log`。
- **当前本机全量与独立性能回归**：
  不启用 Windows SSH 环境变量的完整 `make test` 执行 1089 项，
  18 个真实远端条件跳过；另有 Diff 100,000 行性能矩阵中的一个测试发生 2 条超时断言。
  该方法单独复跑 125.699 秒通过，覆盖 1,000/24,000/100,000 行与各 30 次 Staged/Worktree 交替，
  不以单次成功冒充完整稳定；独立证据为
  `/tmp/bailey-p2-local-diff-perf-isolated-b2a39e0c.log`。
  当前 `b522e259` 上 Cloudflare SSH 全量宿主测试执行中，
  日志 `/tmp/bailey-p2-final-cloudflare-b522e259-full.log`，最终 Gate 等待完整退出码。
- `make test ONLY_TESTING=...`：新重命名／暂存／Stash／旧普通重命名
  4/4 通过；旧 live Worktree diff 在真实临时仓库被证明会无意新增 LFS 媒体，
  新实现的真实测试确认媒体目录、HEAD、Index 和工作区字节稳定。
- `make build`：**退出码 0，`** BUILD SUCCEEDED **`，
  `codesign --verify --deep --strict` 通过**，没有安装或启动正式 Bailey；
  `WorkspaceWindowModel.swift:1083` 有既存的 `default will never be executed` 警告，
  不属本功能代码。
  `make build:ui`：**退出码 0，`** TEST BUILD SUCCEEDED **`**；
  Xcode `-enumerate-tests` 证实两条新增 UI XCTest 均可发现。
  额外 `codesign --verify --deep --strict` 分别验证
  `Bailey.app`、`Bailey Dev.app`、`BaileyUITests-Runner.app`，全部成功。
- 本机真实数据：标准 LFS v1 pointer、历史提交、暂存区、Stash、
  SHA-1/256 Git 仓库、Git 属性启用/移除、自定义 `lfs.storage`、
  Unicode/空格/换行路径、UTF-8 BOM/GBK、真实二进制、
  5 MiB 恰好/超限、缓存丢失/损坏、OID/大小不一致、
  pointer-only checkout、原生 Worktree 编辑保存、
  外部覆盖、取消及普通 Git EOL/clean 路径均已验证。
- Windows MCP 真实 MSYS2/Git LFS 受控仓库：自定义对象目录返回
  `C:\\...` 盘符格式，目标机器 `cygpath -u` 转换后，
  SHA-256／size／文件实际 CSV 字节均一致，仓库状态干净。
  该独立验证**不等于** Bailey 经 SSH 真实远端后端访问。
- **完整 Bailey Dev GUI E2E 已通过**，用户明确授权使用当前受控图形会话：
  `GitGraphUITests.testHistoricalTreeKeepsDeletedFileBesideDirectoryReusingItsPath`：21.203 秒通过；
  `GitHistoryUITests.testRealLFSHistoryStagedAndWorktreeShowCSVAcrossNativeDiffTabs`：
  第一次因 XCTest Runner 的 PATH 缺少 Homebrew `git-lfs` 被跳过，
  调整测试范围内 PATH 并恢复环境后 33.577 秒通过（未跳过）；
  `GitGraphUITests` 键盘历史文件导航 23.964 秒通过；
  `GitHistoryUITests` 真实历史重命名打开工作文件 31.980 秒通过；
  `WorkspaceGitUITests.testAuthorizedWindowsSSHGitReviewThroughRealUI`：
  使用明确的 `windows-tailscale` SSH 别名、修复启动路径竞争后 84.572 秒通过。
  GUI 使用独立临时仓库和 Bailey Dev，未替换正式 Bailey。
- **真实 Windows SSH/Tailscale 已通过**：
  Mac `100.123.73.103` 到 Windows `100.101.55.94` 的 SSH 主机密钥与 Windows 本机记录一致，
  通过 OpenSSH 身份认证；`ssh -G windows-tailscale` 未配置 ProxyCommand／ProxyJump。
  `NativeDiffTabTests` Windows clean/EOL/真实保存 136.797 秒及 GBK/CP936 65.957 秒均通过；
  新增 `NativeGitHistoryFileTests.testAuthorizedWindowsSSHLFSReadsVerifiedMediaAcrossGitSources`
  经 Windows MSYS2/Git LFS 的独立临时仓库与真实 `SSHWorkspaceBackend`
  验证历史、暂存、工作区、历史对工作区、非预期缓存创建、磁盘原文／Index／HEAD；
  首次 91.311 秒、扩大复核 52.207 秒，均 0 失败。
  跨模块 7 项获授权 Windows SSH 集成回归 564.107 秒、7/7 通过：
  Git 远端刷新／取消、Git Ref／Reset／Stash／Ignore、Worktree、LFS、
  项目索引、批量文件树、断线恢复写入资格。
  实测首次 GUI 用例因裸 IP 非显式 Host 别名无法被选择（现有设计），
  改用现成 `windows-tailscale` 别名后发现并根因修复前述路径竞争。
- **未测的部署环境**：仅在当前 macOS 27/Xcode 27 运行本地构建与测试，
  未在最低支持的 macOS 15.6 与其他工具链实机验收，不声称等价覆盖。
  用户明确要求继续 Bailey 测试；最低系统未测不冒充等价覆盖，
  当前阻塞门禁的是最新版远端事件监听测试和尚未取得的完整零失败回归。
- 文档随每个代码提交更新对应 `docs/features/git.md`／`diff.md`、
  `files.md`；两个阶段计划计数已纠正至 36 条真实历史变更。
  未 push `main`，未替换正式 Bailey。
