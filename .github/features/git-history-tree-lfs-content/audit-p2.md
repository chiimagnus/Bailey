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

## 发现 F-03

- 任务：`P2-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitHistoricalFileLocator.swift:25`
- 摘要：`历史文件定位对已由 stat 可选结果表达的缺失路径重复兜底`
- 风险：`本机和 SSH 后端的 stat 都将路径不存在表达为 nil；额外的 notFound 异常分支在真实后端不可达，增加与协议语义不一致的兼容路径。`
- 预期修复：`保留可选 stat 与真实连接错误反馈，移除 WorkspaceError.notFound 专门捕获分支。`
- 验证：`make test:NativeGitHistoryFileTests,GitExecutionTests`
- 解决证据：`0a881e99：依据 LocalWorkspaceBackend.statSync 与 SSHWorkspaceBackend.stat 的 nil 缺失约定移除两行永远无需的 notFound 捕获，保留真实异常反馈；修正误导性旧注释。make test:NativeGitHistoryFileTests,GitExecutionTests 完整运行 57 项、0 失败、1 项授权 Windows SSH 跳过，退出码 0；含无效提交、SHA-1/256、多段重命名、真实 LFS 和目录替换。git diff --check 通过。`


## 发现 F-02

- 任务：`P2-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitHistoricalFileLocator.swift:34`
- 摘要：`历史到 HEAD 及 HEAD 到 Index 各自重命名时整体路径定位失败`
- 风险：`历史版本到暂存区累计修改降至 Git 重命名相似度阈值以下，但分段均为真实 R065；旧实现返回 missing，导致历史对工作区 Diff 读不到新路径。`
- 预期修复：`只追踪真实 Git tree/Index 中可验证的两段重命名，验证磁盘文件实际存在；不使用会触发 LFS clean 的工作区 Git diff。`
- 验证：`SHA-1/SHA-256、中文空格制表符换行路径 Red→Green，核对真实 Diff、HEAD、Index 和磁盘字节，运行相关宿主测试与 App 构建。`
- 解决证据：`主工作区 commit b216b7cc（原隔离提交 78c11df1），SHA-1/SHA-256 的 Git rev→Index 无重命名、rev→HEAD 与 HEAD→Index 均为 R065，修复前 6 断言失败、修复后 NativeGitHistoryFileTests 36 项 0 失败（1 个无授权 Windows SSH 用例跳过）；HEAD、Index、当前文件原始字节均不变。`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/DiffViewerView.swift:1663`
- 摘要：`工作区旧文件被目录替代时读取错误阻止显示 Git 已确认的删除 Diff`
- 风险：`真实 Git status 显示删除、git diff 能生成删除 Patch，但 DiffTab 把目录读取 ENOTSUP 当文件错误，无法查看原有内容与空新侧`
- 预期修复：`在原有工作区读取失败边界确认当前路径为目录时视为文件缺失；其它特殊文件和权限错误仍维持报错；结合 exact Git OID 查询修复`
- 验证：`用真实 SHA-1/256 工作区文件转目录复现 Red/Green；核对工作区/暂存/历史真实 Diff 与磁盘、HEAD、Index 无改动`
- 解决证据：`707837c8：仅真实目录替代旧文件时将 Worktree 新侧视为缺失，其它 I/O 错误不吞；SHA-1/256 Worktree/Staged/History 实仓 Red→Green，新目录→文件反向回归通过；真实 GUI 新断言已编译未运行。`


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

## 独立后审（2026-11-18，代码提交 707837c8）

以 `todo.toml` 五个任务及其实际依赖提交为主线，独立阅读生产调用链与测试源码；上述历史日志仅用于复核尚未关闭的风险，不作为正确性推定。

| 任务／提交 | 逐提交检查、真实集成与旧路径处理 |
| --- | --- |
| P2-T1 `168b904d` | `DiffTab.gitContent` 以 Git OID 锁定历史／Index blob，Git LFS 从本机或 SSH 后端的 `LocalMediaDir` 读取，经真实字节数、SHA-256 和 5 MiB 限制验证；已由 `.commit/.revision/.staged` 生产调用。缓存缺失不把 pointer 当正文、不暗中下载。 |
| P2-T2 `472b7906` | `gitComparisonBaseline` 为 LFS 与属性切换采用原文比对；非 LFS 保留 Git clean/EOL 的必要规范化，Worktree 条件保存保留真实字节版本；发现目录代替旧文件时 Worktree 误报非文件读取错误，见 F-01。 |
| P2-T3 `5fcf9348` | `GitHistoricalFileLocator.resolve` 由历史／Index／HEAD 重命名查询推导路径，已移除会调用 LFS clean 的 live Worktree diff 探测；历史与暂存的真实仓库重命名和媒体缓存稳定测试均被发现且通过。 |
| P2-T3 `9ad5eb5b` | `SSHFolderPickerModel.selectHost` 的首次握手尊重已输入绝对路径，旧的无条件盘符重置路径已删除；延迟握手 XCTest 与既有远端 GUI 证据对应实际 Add SSH 入口。 |
| P2-T3 `da23b093` | `GitGraphUITests` 与 `GitHistoryUITests` 使用真实 App 入口，`NativeGitHistoryFileTests` 经 `SSHWorkspaceBackend` 使用 Windows Git LFS 真实文件；新增 GUI 删除 Diff 断言已编译，当前提交未实跑。 |
| P2-T3 `d1286f9f` | `ProcessRemoteCommandRunner` 仅对有界下载或带 stdin 的上传按字节进展更新时间，普通命令保留总截止时限；`SSHFileTreeLiveTests` 计数包装器转发 `runLimited`，不是无界退化路径。 |
| P2-T3 `b2a39e0c` | Windows watcher 的 READY、目录移动和 LOST 按实际阶段分别等待；测试后端 25 秒期限与生产保持一致，未修改产品 SSH 设置。 |
| P2-T3 `b522e259` | 远端 Files 目录切换压力测试调用真实 `Project.syncFiles` 再重绑监听，不再以单独修改路径变量伪造真实入口；该测试由现有宿主 Target 发现。 |
| 计划整理 `393d595c` | `todo.toml` 的五个任务均有真实原子提交，Git Graph/Files/LFS/SSH 入口关联已核对；该提交自身只涉及规划和历史审计，不含新生产逻辑。 |
| 后审修复 `707837c8` | Tree 与 Index 精确查询、Worktree 目录替换按文件缺失处理；删除失效的递归／前缀查询，不新增二轨读取；更新 Git 执行基准、历史 GUI 和实际仓库回归。 |
| 后审修复 `b216b7cc` | 历史→HEAD、HEAD→Index 两次可识别的重命名现可串联，解决累计内容变化导致的历史→Index 重命名丢失。`GitHistoricalFileLocator` 同时供 Git Graph 的「打开工作文件」和原生历史→工作区 Diff 使用，保留 Git LFS 无 clean 副作用的只读比较。新增 SHA-1／256、中文／空格／Tab／换行路径与 Git/Index/磁盘未改动的实仓回归；原隔离提交为 `78c11df1`，已整合进同一主工作区。 |

**独立缺陷与修复**：P1-F-01 与本阶段 F-01 均由 `707837c8` 解决。真实提交下文件→目录造成 Historical/Staged/Worktree 删除 Diff 错误；反方向目录→文件的子文件删除也复测。Red：SHA-1/256 产生 20 条失败断言；Green：新增两条回归通过，1,200 后代、中文方括号文件名和只读对象查询均通过。F-02 经 `b216b7cc` 解决：历史→Index 无法整体识别时两段 R065 的真实重命名仍能定位最终文件；Red 6 条失败断言→Green，修复后 36 项、0 失败、1 个未授权 Windows SSH 跳过。其它 I/O、gitlink、LFS 缺失、损坏和格式限制继续正常报错，不视为多余围栏删除。

**当前构建／测试证据**：
- `make test:FileTreeTests,GitStatusModelTests,NativeGitHistoryFileTests,NativeDiffTabTests,DiffEngineTests,GitExecutionTests,SSHFolderPickerTests,RemoteLifetimeTests`：复核前 435 项（3 条远端条件跳过）、0 失败；首次修复后 436 项（3 条跳过）、0 失败，完整命令成功。
- 追加大目录、Index 精确 Git pathspec 和逆向目录替换后的最终代码 `make test:NativeGitHistoryFileTests,GitExecutionTests`：56 项（1 条获授权 Windows SSH 条件跳过）、0 失败，退出码 0。专项 LFS、真正 SHA-256 仓库和 literal path 回归均通过。
- `make build` 与 `make build:ui`：均返回成功；签名验证通过。GUI 新断言仅构建，未在独立图形会话运行。未替换正式 Bailey、未 push `main`。
- 本次复审额外执行原隔离 `78c11df1` 的 `make test`：**1090 项、18 项未授权 Windows SSH 条件跳过、0 失败，完整退出码 0**。此全量结果对应 P2 重命名修复自身的基线，不能冒充同时含 P1 `707837c8` 的全量验证。
- 将两笔修复合并至本地主工作区后，`main@b216b7cc` 执行 `make test:NativeGitHistoryFileTests,GitExecutionTests`：**57 项、1 个 Windows SSH 条件跳过、0 失败，完整退出码 0**。新增连续重命名与正反文件／目录互换回归共同通过；`git diff --check` 通过。合并时只保留两组测试，未覆盖已有改动；独立工作树属于本轮临时产物。
- 真实 Git LFS 仓库另确认：文件重命名同时改写媒体时，Git 指针 SHA 变化可使差异只呈现删除／新增。没有足以证明文件对应关系的 Git 记录时不靠名称猜测，不能宣称所有 LFS 改名均可自动定位。

**技术 Gate：仍为 No-Go（保留既有用户批准的测试豁免）**。不能因新增定点测试通过就声称最终完整宿主／Windows SSH／原生 GUI 全绿。旧版 Cloudflare 全量 `b522e259` 的 Git Clean 清理实际未生效，以及其它 SSH 命令 25 秒超时仍有失败记录，本轮未重新跑对应真实远端测试；缺少独占 GUI 会话，最新 GUI 断言未执行；未实测最低 macOS 15.6。未发现需要通过删除非 LFS clean/EOL、Stash List 回退、SSH 取消／时限、LFS SHA 校验等真实边界来换取表面绿色的证据。

### 最终本地 main 整合复核（2026-11-18）

- 已验证 `main@b216b7cc` 同时包含 P1 修复 `707837c8` 和 P2 修复 `b216b7cc`，新增历史连续重命名的生产源码与原隔离提交一致，没有留下重复合并提交。此前临时工作树、临时分支均已清理。
- **整合后的完整宿主 `make test`：1092 项、18 项条件跳过、0 失败，退出码 0，`TEST SUCCEEDED`**。原生 Git 历史、文件／目录互换、LFS 真正媒体读取、Diff 编辑／保存和 SSH 本地模拟测试均在此次完整运行中通过。原始结果：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.18_01-30-48-+0800.xcresult`；执行日志：`/tmp/bailey-audit-lfs-main-b216-full.log`。
- `make build:ui`：`TEST BUILD SUCCEEDED`、退出码 0；`make build`：`BUILD SUCCEEDED`、退出码 0，正式构建产物经过 `codesign --verify --deep --strict`，没有安装或替换正式 Bailey，也没有 push `main`。
- **门禁范围不变**：18 项条件跳过并不等于已重新连通并验证全部真实 Windows SSH；新增完整 App GUI 断言仍缺可独占的图形会话。因此宿主／构建验证为 **Go**，跨平台真实端到端技术门禁继续 **No-Go（既有人工豁免另记）**。
