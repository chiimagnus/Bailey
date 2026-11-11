# P4 本机验收及未测边界

本文件只记录本次执行的实际观测；`todo.toml` 是唯一实时任务状态。后续任何生产提交均须重新核销受影响范围，不继承旧提交的绿色结论。

## P4-T1：Git 来源、字节与读取生命周期（2026-11-10）

- 源码版本：`c9111491a2bf10e09529af4fac2b720bfe50b013`（`main`，执行前工作区干净）。环境：macOS 27.3，Xcode 27.2（27B5038j），Apple Silicon。
- 调用链：`GitStatusModel`／`GitPanel`／`Project.openDiff` → `DiffTab.reload` → Git OID／Index、原始 Worktree 读取 → `gitComparisonBaseline` → `DiffCore` → 原生表面；历史重命名经 `GitHistoricalFileLocator`，可写缓冲由 `DiffTab.writeCurrentText` 保存。
- 实际命令：`make test ONLY_TESTING='BaileyTests/NativeDiffTabTests BaileyTests/NativeGitHistoryFileTests BaileyTests/GitBrowsingRecoveryTests BaileyTests/GitStatusModelTests BaileyTests/GitExecutionTests'`。退出码 0，`TEST SUCCEEDED`，245 项、0 失败、2 跳过。日志：`build/p4t1-baseline-host-20261110.log`；xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.10_23-13-31-+0800.xcresult`。
- 分类：NativeDiffTabTests 135 项（133 通过、2 SSH 跳过）；NativeGitHistoryFileTests 20 项全通过；GitStatusModelTests 69 项全通过；GitExecutionTests 17 项全通过；GitBrowsingRecoveryTests 4 项全通过。
- 真实 Git 边界：Staged 与 Worktree 双基线、并行 HEAD／Index OID 重查、冲突 stage、无 HEAD／dangling HEAD、历史 Blob 与更名、工作区文件／Index／HEAD 对比；SHA-256、字面特殊路径、5 MiB 精确阈值及超限；Git stdout 实际接收预算／取消与截断拒绝（见各测试真实方法和回归日志）。
- 文字与副作用：BOM UTF-8／UTF-16、无声明 CP936 的手动重开、`coding: mbcs` 的 Windows 代码页模拟、实际原编码回写与不可编码拒写；`core.quotePath=false` 中文路径、Git 规范化 EOL、clean filter、Git patch 文字与字节不对应、规范等价 Unicode、原文保存及 Index 不变。上述证据来自真实临时 Git 仓库和逐字节断言，不以页面成功加载代替落盘验证。
- 异步与错误：外部重写与 clean filter 时的原始文件复查、Git metadata 交错、旧读取取消、Git 失败保留先前内容、脏缓冲保护和连接目标隔离，均有本轮运行的对应宿主回归。
- 没有发现需要本任务引入生产替代路径的新失败；OID 校验、`showsCanonicalComparison`、严格编码、symlink 拒写、结构化取消与保存队列都有真实消费者，不可作为旧兼容实现删除。本任务只有证据核销，无生产代码变更，故无提交。
- 2 项实机条件跳过：`testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`、`testAuthorizedWindowsSSHLegacyMBCSFileAndStagedDiffKeepCP936Bytes`；归 P4-T3 在用户既有授权的测试机器补跑，不归为通过。
- 完整 App 的 Changes／Graph 选择、真实 AX／键盘、焦点及保存动作由 P4-T2 单列旧版 GUI 证据和未测条件；本机宿主通过不能冒充最终 GUI 通过。不额外制造等价底层矩阵的重复 GUI 夹具。
- 旧 SHA `c9111491` 的完整 Host＋UI CI 已完成（run `42842249408`），两个 Job 都失败；详细断言、独立复现及修复状态见下方 P4-T2／T4，不可冒充新 SHA 的结果。

## P4-T2：历史完整 GUI 证据与非门禁缺口

- GitHub Actions run `42842249408`（`c9111491`）完整 Host+UI 两个独立 runner 均已结束失败；Host 955 项、17 skipped、12 failures（2 unexpected），见 `build/p4-ci-c9111491-host.log`；GUI 结果单列如下。均不算当前 SHA 验收通过。
- 独立 UI runner run `42849842298` 在旧 SHA 定向执行 5 项，4 通过、1 失败；失败由浅克隆缺少真实源码旧提交触发，已经在 `5e4a7660` 将 UI Job 改为 `fetch-depth: 0`，并用浅／完整临时 Git 克隆证明原因，最终 SHA 云端 GUI 未复验，本轮用户不再要求。
- 旧 SHA 的全量 GUI run `42842249408`：225 项、8 skipped、26 个失败测试方法、40 条失败断言。原生菜单、Git Graph 位置、Dock／Finder 拖放及恢复等错误不全属于 P4 代码变更，也不能直接归因于 runner；原始日志 `build/p4-ci-ui-old-c9111491.log`，已登记 audit F-06；最终 SHA 的云端重跑不在本轮范围内，不能认定这些失败已修复。
- **最终提交 SHA 的完整 App GUI 未运行，本次明确为非门禁。** 本机没有不抢占桌面的独立图形会话，用户选择只看本机 Swift 测试结果；不得以宿主 `NSWindow`、旧 SHA GUI 或 UI Target 编译冒充 E2E。授权 SSH GUI 亦未执行。

## P4-T3：获授权 Windows SSH 实机

- 首次运行仅设置 `BAILEY_P4_TEST_SSH_HOST=windows`，XCTest Runner 未继承环境，3 项条件跳过，**不计成功**；已按 `docs/testing.md` 增加 `TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows` 重跑。
- `c9111491`、本机 macOS 27.3/Xcode 27.2，3 项实际执行、**3 passed、0 failed、0 skipped**，完整退出码 0。日志：`build/p4t3-ssh-authorized-forwarded-c9111491.log`，`.xcresult`：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.11.10_23-35-45-+0800.xcresult`。
- 测试入口：`NativeDiffTabTests.testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`（100.349 s）、`testAuthorizedWindowsSSHLegacyMBCSFileAndStagedDiffKeepCP936Bytes`（65.855 s）、`SSHGitRecoveryLiveTests.testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`（61.202 s）。远端 Windows 专属临时仓库、独立 SSH socket，核对实际 Index、HEAD、原字节、Unicode 与 CP936、clean/EOL、编辑落盘，以及测试层模拟断线时的拒写与恢复。
- 这是**真实 Windows SSH 传输 + 受控失联注入**，不是物理网络断开时的完整 App 交互；完整 GUI 隐藏、跨窗、关闭、重连及改名测试仍未执行，当前不阻塞 P4 本机 Gate。`b76d4fa4` 已完成授权完整 Host：955 项通过、0 失败、0 跳过（包括远端 Git/文件事件测试），退出码 0，日志 `build/p4t5-final-full-host-b76d4fa4.log`；之后原生字形修复已在最终 `ae049476` 受影响的 136 项回归中复验。

## P4-T4：CI 缺陷、根因及当前修复证据

- 对照 `162d1369` 和 `c9111491` 两次 CI，后者 955 项、17 skipped、12 failures；定位到 `NativeDiffTabTests` 5 个方法 11 断言，以及 `RemoteCommandsTests` 1 个命令超时。CI 原始日志已另存 `build/p4-ci-c9111491-host.log`，前次 `build/p4-ci-162d-failures.log`。
- 提交 `1dc54e0e`：唯一 `NativeCodeTextView` 固定高度所有者在视图首次挂载和 AppKit 后续 `layout` 时同步帧高；新增折叠高度对照断言。原生 AX 断言改为当前实际可见折叠及其标签，校验实际隐藏段落减少、编辑器对象身份、原始磁盘字节；不再误认无关的首个 AX 子元素必须改变。
- 语法内存：旧 CI 报 134421 KiB 超额；`c9111491` 的独立 CI run `42846865837` 验证 30 次冷解析、10 个 owner 全部释放，`malloc` 基线 15026 KiB → 释放后 15092 KiB，**隔离测试通过**。原测试把前 20 次临时冷解析分配计入 10 个标签的归因；调整为先运行 20 次冷解析再取 owner 基线，仍要求 10 owner 峰值明显增加且释放后差值小于 32 MiB。本机新测试 31272 KiB → 31266 KiB，30 个冷样本、10 owner 释放成功。
- 提交 `b76d4fa4`：`LocalWorkspaceBackend.runSync` 的截止时间只对仍运行的直接子进程判超时，已退出者只排空可用输出，不把后代继承管道误报超时；保留运行中超时、取消、限额。
- 本地定向实测：`build/p4-fix-geometry-process-targeted.log`（50 项 0 失败），`build/p4t4-isolated-memory-ax-target.log`（4 项 0 失败），`build/p4t4-final-geometry-timeout.log`（4 项 0 失败），实际退出码均为 0。用户原始磁盘未被覆盖。
- **仍未证明 CI macOS 27.0.1 性能达标**：旧 SHA `c9111491` 的隔离 CI run `42848854796`，`NativeDiffTabTests.testLargeNativeCRAndUnicodeParagraphsKeepExactScrollEnd` 中 24k Unicode LS 首布局 371.4 ms、100k CR 288.0 ms，超过现有 200 ms 门槛；该独立失败是实证，不能当作全量进程噪声或直接放宽阈值。本机已在实际 TextKit 布局所有者修复并 Red→Green，旧系统同 SHA 未重测，不属于本轮 Gate。日志：`build/p4-ci-perf-isolated-c9111491.log`。
- 新增真实缺陷（audit F-05）：TextKit 将 U+2028 的 36 条视觉行放在同一个 `NSTextParagraph`，旧固定布局片段仅 15pt，预期至少 539pt，末行像素未绘制。`build/p4-unicode-ls-glyph-red.log` 的两项断言红；生产 `DiffFixedRowFragment` 改为使用该片段真实视觉字形行数，剔除末端空片段后，`build/p4-unicode-ls-glyph-green.log` 3 项绿。原字节不变，CR/Unicode 极端滚动依旧通过。
- 大回归 `build/p4-unicode-ls-regression.log` 的原内存测试因共享进程的全局堆波动失败，10 个对象全部析构后总堆仍高 52,646 KiB；重复持有／释放 20 个对象的测试在单独运行时仅增加 28 KiB，但在整类 XCTest 中仍高 38,797 KiB（`build/p4-native-diff-final-regression.log`）。因此不能用进程级堆量判断某个标签树是否仍存活。追至 `SwiftTreeSitter.Tree.deinit → ts_tree_delete`，改用测试内对 `DiffSyntaxSource.cachedTree` 实际 `MutableTree` 的弱引用核销 **10 个语法所有者与 10 个真实树对象全部释放**，保留 RSS／全局堆的诊断数，不改变生产接口。修复 `ae049476`；`build/p4-tree-owner-direct-lifetime.log` 两项测试通过、退出 0，`malloc` 19,635→19,629 KiB。最终 SHA 的整类回归 `build/p4-native-diff-ae049476.log` 已结束：`NativeDiffTabTests` 136 项、0 失败、2 项授权 SSH 条件跳过，`TEST SUCCEEDED`，退出码 0；重负载之后仍直接确认 10 个真实 Tree-sitter 树和 10 个 owner 均已释放。跳过的两项已有 `b76d4fa4` 完整 Windows SSH 实机 Host 955 项/0 跳过的独立验证。
- 最新本地提交 `ae049476`，新增 `ea30f7be`（U+2028 实际字形补绘，Red→Green）与 `ae049476`（真实 Tree-sitter 资源释放验证），各自包含同步文档和回归。本轮仅提交计划与证据，不推送 `main`，也不要求 GitHub runner 复验。

## P4-T5：本机回归与审计（已收口）

- P1～P3 既有退役名称 `afterGitAction`、`hasCollapsedContext`、`updateEditedContent` 等已在当前生产源码中确认不存在；`showsCanonicalComparison`、Git OID 校验、symlink、原始字节、结构化取消和保存队列仍有真实消费者，不应错误删除。
- `b76d4fa4` 已完成改动前本机授权完整 Host：955 项通过／0 失败／0 skipped，实际退出 0；`ae049476` 上受影响的 `NativeDiffTabTests` 全类 136 项、0 失败、2 项 SSH 条件跳过、退出 0，新增 U+2028 真像素及树生命周期同时覆盖。
- 最终提交 `ae049476` 的 `make build:ui` 已完成 `TEST BUILD SUCCEEDED`，退出 0，日志 `build/p4-final-ae049476-build-ui.log`；这是 UI Target 编译，而非真实 GUI 自动化。正式 Debug `make build` 同样退出 0，`BUILD SUCCEEDED`，随后 `codesign --verify --deep --strict` 退出 0；日志 `build/p4-final-ae049476-build.log`。没有安装或重启用户正式 Bailey。
- 最终提交 `ae049476` 的 `make build:release` 亦退出 0，`BUILD SUCCEEDED` 且 Makefile 后置 `codesign --verify --deep --strict` 通过；日志 `build/p4-final-ae049476-release.log`。正式 Debug、Release 与 Dev UI 编译均已验签／构建，未安装或重启用户正式 Bailey。
- **2026-11-11 用户确认本机即本轮验收口径**：采用 `b76d4fa4` 完整 Host 955 项全绿与最终 `ae049476` 受影响的原生 Diff 136 项全绿（2 条实机条件跳过有旧 SHA 通过证据），以及最终 Debug／Release／UI Target 构建验签全部通过。**没有在 `ae049476` 重新运行完整 955 项**；完整 App GUI／macOS 27.0.1 CI／远端物理断线与跨窗恢复仍未验证，已明确转为非门禁保留风险。`todo.toml` P4 五项 completed，`audit-p4.md` 本机范围 Gate `Go`；不代表 GUI 或跨环境全面通过。

阶段审计使用唯一 `audit-p4.md`；本证据文件不替代 `todo.toml` 的实时状态。用户本轮明确要求将 Feature 计划与审计一起提交 Git。
