# Audit P4 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。
2026-11-11 用户调整验收后，P4 五项任务均已在 `todo.toml` 标记 completed，
以下勾选框保留创建审计时的历史状态，不代表现行待办。

- [x] P4-T1 核销所有 Git Diff 来源和实际字节结果
- [ ] P4-T2 完成完整 App GUI 交互与可访问性验收
- [ ] P4-T3 验收获授权 Windows SSH Diff 与失败恢复
- [ ] P4-T4 以 Swift XCTest 核验首屏、编辑、滚动与资源释放
- [ ] P4-T5 执行最终全量回归并完成交付审计

## 任务到文件的映射

- P4-T1：`Bailey/Git/{DiffViewerView,GitHistoricalFileLocator,GitStatusModel,GitPanel,GitCommandExecution,DiffEngine}.swift`、`Bailey/Workspace/Project.swift`；`BaileyTests/Git/{NativeDiffTabTests,NativeGitHistoryFileTests,GitStatusModelTests,GitExecutionTests,GitBrowsingRecoveryTests}.swift`。
- P4-T2：`BaileyUITests/Git/{WorkspaceGitUITests,GitChangesUITests,GitGraphUITests,GitHistoryUITests}.swift`、`BaileyUITests/Support/WorkspaceUITestSupport.swift`、`.github/workflows/ci-ui-test.yml`；`docs/{testing,ui}.md`。
- P4-T3：`Bailey/Remote/{SSHWorkspaceBackend,RemoteCommands}.swift`、`Bailey/Workspace/Project.swift`、`BaileyTests/Git/{NativeDiffTabTests,SSHGitRecoveryLiveTests,GitWorkspaceSSHTests,GitRemoteRefreshIntegrationTests}.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`；`docs/features/ssh.md`。
- P4-T4：`Bailey/Git/{DiffTextView,DiffNativeSurface,DiffSyntaxHighlighter,DiffViewerView}.swift`、`Bailey/Editor/{NativeCodeTextView,NativeTextLineIndex}.swift`、`Bailey/Workspace/LocalWorkspaceBackend.swift`；`BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Editor/{NativeEditorLayoutTests,TextCoordinateIndexTests}.swift`；`docs/features/{diff,editor}.md`、`docs/testing.md`。
- P4-T5：`Makefile`、`Bailey.xcodeproj`、`docs/{architecture,standards,ui,testing,development}.md`、本 Feature 的 `idea.md`／`plan-p{1,2,3,4}.md`／`todo.toml`／`evidence-p4.md`，以及当前 HEAD 的真实 Git 与 XCTest、签名产物。

## 发现项

## 发现 F-06

- 任务：`P4-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyUITests/Git/GitUncommittedUITests.swift:188`
- 摘要：`GitHub 完整 BaileyUITests 在旧 SHA 出现26个失败方法，原生菜单、Dock/Finder 操作与焦点等未通过`
- 风险：`run 42842249408, c9111491, UI 225 tests/8 skipped/26 failed methods/40 failed assertions；真实完整App交互路径未获得可信绿色结论`
- 预期修复：`先按失败方法核对前台App、AX元素、XCTest执行器和真实副作用，区分测试环境与产品；追至共享根因并在最终SHA定点复验，不降低断言或吞掉菜单操作`
- 验证：`build/p4-ci-ui-old-c9111491.log；最终 SHA GitHub 隔离 runner 重新运行 P4 必需 UI 测试，并检查真实磁盘/窗口结果`
- 解决证据：`旧云端run 42842249408 UI 225项、8跳过、26失败方法40失败断言，菜单/Dock/Finder/焦点等尚未在最终SHA复测，真实缺口保留；用户2026-11-11明确不将GitHub独立GUI作为本轮P4 Gate。`


## 发现 F-05

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/DiffTextView.swift:285`
- 摘要：`Unicode U+2028 单个 TextKit 自然段落内多条视觉行被固定片段错误压成一行，末尾字形未实际绘制`
- 风险：`滚动条高度看似正确，但36条视觉行的 fragment 仅15pt而非539pt，最终真实字形在屏幕中不可见`
- 预期修复：`同一 DiffFixedRowFragment 按原生视觉行数分配高度；排除末尾空字形片段，保留普通 Git LF/CR/PS、删除占位的行高`
- 验证：`Red: build/p4-unicode-ls-glyph-red.log 2条失败断言；Green: build/p4-unicode-ls-glyph-green.log 3项通过；再运行 NativeDiffTabTests/EditorLayout/TextCoordinateIndex/DiffFoldLiveMutation`
- 解决证据：`ea30f7be: 36行U+2028的TextKit单段落旧frame=15pt、预期>=539pt且末端像素缺失，build/p4-unicode-ls-glyph-red.log 两条断言失败；修复 DiffFixedRowFragment 按原生字形行数设置实际高度并保留Ghost行，build/p4-unicode-ls-glyph-green.log 3项通过、0跳过；build/p4-tree-owner-direct-lifetime.log 末行真像素回归通过。更大整类在新SHA复测中。`


## 发现 F-04

- 任务：`P4-T3`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyUITests/Git/WorkspaceGitUITests.swift:89`
- 摘要：`获授权Windows SSH完整App断线/重连/切窗生命周期仍无独立GUI证据`
- 风险：`真实SSH宿主三项通过不代表完整App保存失败后重连、跨窗或过期请求无错写`
- 预期修复：`保持SSH唯一目标/专属临时仓库，在获授权独立GUI会话逐入口核对实际远端磁盘与本机同名文件`
- 验证：`WorkspaceGitUITests/testAuthorizedWindowsSSHGitReviewThroughRealUI及其他真实断线恢复用户动作，独立Runner和授权远端`
- 解决证据：`Windows SSH真实专属临时仓库3项实机通过0跳过，b76d4fa4全量Host 955项0跳过；完整App物理断线、隐藏/跨窗/重连未验收。2026-11-11用户确认仅本机XCTest为本轮Gate，保留此GUI缺口不冒充通过。`


## 发现 F-03

- 任务：`P4-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`.github/workflows/ci-ui-test.yml:126`
- 摘要：`GitHub UI Job 浅克隆丢失测试所需 Bailey 真实源码历史`
- 风险：`GitChangesUITests/testRealBaileySourceHistoryDiffLoadsAcrossIndexWorktreeAndOtherSource 在真实App启动前失败，无法覆盖工作区/暂存区切换`
- 预期修复：`UI Job完整Git历史检出，保留真实源码双版本夹具及内容/Index/HEAD断言`
- 验证：`浅/完整克隆Red→Green、改动后最终SHA独立BaileyUITests真GUI回归`
- 解决证据：`5e4a7660: .github/workflows/ci-ui-test.yml 的 UI Job 改为 fetch-depth: 0；本机浅克隆不能取得历史版本、完整克隆可取得历史版本的 Red-Green 前提已验证。最终SHA云端UI未跑，不能据此声称整类GUI通过。`


## 发现 F-02

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyTests/Git/NativeDiffTabTests.swift:1263`
- 摘要：`前一个 CI SHA 的折叠高度、深滚动、AX与内存测试未在修复SHA完成云端复验`
- 风险：`尽管本机54项通过、独立解析器测量证明可释放，老系统下首屏/最末行与AX仍需真实CI复核`
- 预期修复：`复核唯一原生布局所有者，保持逐字节、可见段落及原生AX断言；不将旧CI失败视为通过`
- 验证：`在最终SHA运行 NativeDiffTabTests 全类和受影响 Editor/TextCoordinateIndex 集合、完整Host以及必要App UI`
- 解决证据：`旧云端 TextKit/AX/布局失败按真实断言保留；本机 b76d4fa4 全量Host 955项0失败0跳过，最终 ae049476 受影响 NativeDiffTabTests 136项0失败2条件跳过，原生像素、折叠、树释放均通过；用户不要求新SHA云端复测。`


## 发现 F-01

- 任务：`P4-T4`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Git/DiffTextView.swift:1925`
- 摘要：`macOS 27.0.1 CI 原生 Unicode LS/CR 首次布局持续超出200ms门槛`
- 风险：`CI独立复测 UnicodeLS-24k 371ms、CR-100k 288ms；冷首屏可能同步计算过多布局`
- 预期修复：`定位固定行高原生布局初始化和失效顺序，减少真正不必要的 TextKit 计算；不修改阈值`
- 验证：`原有 NativeDiffTabTests/testLargeNativeCRAndUnicodeParagraphsKeepExactScrollEnd 的 Red→Green、本机性能与当前SHA云端相同环境`
- 解决证据：`2026-11-11 用户改为本机验收：macOS 27.0.1 云端首次布局性能旧失败仍保留，尚未在 ae049476 旧系统重测；本机 NativeDiffTabTests 136项0失败，不能据此声明云端恢复。非本轮 P4 Gate。`


## 修复日志

- `1dc54e0e`：固定高度在原生 TextKit 挂载与重排持续对齐；折叠 AX 用实际可见按钮核对，不假设首个标签一定改变。
- `b76d4fa4`：直接子进程已正常结束但后代仍持有 stdout/stderr 时，不再因残留管道误判命令超时。
- `5e4a7660`：UI Job 改为完整检出 Git 历史，修复真实 Bailey 历史夹具缺少前一次源码提交。
- `ea30f7be`（F-05 Resolved）：U+2028 同一原生段落的多条字形行必须拥有完整片段高度；以独立屏幕实际像素断言 Red→Green。
- `ae049476`：不再将共享进程全局 malloc 的无关分配归罪于标签；追到 SwiftTreeSitter `MutableTree → Tree.deinit → ts_tree_delete`，以弱引用直接核对 10 个真实解析树及所有者释放，保留 RSS/heap 诊断。

## 验证日志

- `make test`，`b76d4fa4` + Windows 专属授权 SSH 环境变量，日志 `build/p4t5-final-full-host-b76d4fa4.log`：**955 tests / 0 failed / 0 skipped / exit 0**。此结果发生于新 U+2028 与内存测试提交前，不能代替最终提交验证。
- `make test ONLY_TESTING='BaileyTests/NativeDiffTabTests/testUnicodeLineSeparatorKeepsLastNativeGlyphVisibleAfterDeepScroll ...'`：`build/p4-unicode-ls-glyph-red.log` 真像素＋片段高度均失败；`build/p4-unicode-ls-glyph-green.log` 同用例与 CR／Unicode 极端滚动及折叠滚动三项通过、exit 0。
- `make test ONLY_TESTING='BaileyTests/NativeDiffTabTests/testThirtyColdParsesAndTenSyntaxOwnersReleaseTheirTrees BaileyTests/NativeDiffTabTests/testUnicodeLineSeparatorKeepsLastNativeGlyphVisibleAfterDeepScroll'`：`build/p4-tree-owner-direct-lifetime.log` 两项通过、exit 0；`MutableTree` 弱引用 10 个全部归零，RSS／堆前后数据保留。
- `make test ONLY_TESTING='BaileyTests/NativeDiffTabTests BaileyTests/NativeEditorLayoutTests BaileyTests/TextCoordinateIndexTests BaileyTests/DiffFoldLiveMutationTests'`：`build/p4-unicode-ls-regression.log` 中除进程全局堆断言外各类通过；该失败已按真实树析构根因改写。最终 SHA `ae049476` 的整类 `NativeDiffTabTests` 复测 `build/p4-native-diff-ae049476.log`：**136 tests，0 failures，2 条 SSH 条件跳过，exit 0**；同一进程经历真实大样本解析、编辑、布局等多项负载后，依然直接证明 10 个 Tree-sitter 对象与所有者均释放。两个 SSH 条件项目已在旧 SHA 的授权 Windows SSH 全量 Host 955 tests/0 skipped 中成功执行，不能计入本次通过。
- `make build:ui`，`ae049476`：`build/p4-final-ae049476-build-ui.log`，`TEST BUILD SUCCEEDED`、exit 0；仅编译 UI Target，不代表启动 App。`make build`：`build/p4-final-ae049476-build.log`，`BUILD SUCCEEDED`、退出 0，后置 `codesign --verify --deep --strict` 成功。`make build:release`：`build/p4-final-ae049476-release.log`，`BUILD SUCCEEDED`、退出 0，后置正式 Release 验签成功。未安装或重启正式 Bailey。
- Windows SSH 独立三项真实传输测试 `build/p4t3-ssh-authorized-forwarded-c9111491.log`：3 项通过，含 CP936、Git EOL／clean filter 原始字节、模拟连接失效时拒写及恢复；完整 App 的远端断线 GUI 并未执行。
- 独立 GitHub Actions macOS 27.0.1／Xcode 27.2 `42848854796`（旧 SHA）复测 Unicode LS 24k 布局 371.4 ms、CR 100k 288.0 ms，超过原 200 ms 门槛；目前不能视为达标。旧 SHA 完整 Host run `42842249408` 12 条断言失败，GUI 225 项、8 skipped、26 失败测试方法／40 条失败断言。GUI 失败含真实菜单、Git Graph、拖拽及焦点路径；须区分测试夹具／Runner 与产品责任后复测，不因相关 Host 绿而放行。
- 已覆盖本机 Debug TextKit 真像素、Git Index／工作区/历史、字节／编码／clean filter、折叠、原生 AX、Unicode／CR／LF／CRLF、长行、100k 行、撤销／保存／资源退出，以及真实 Windows SSH 专属临时仓库；Debug/Release/Dev UI 构建和验签。**未验证但非本轮门禁**：新 SHA 的 macOS 27.0.1 CI 宿主及完整 GUI；完整 App SSH 物理故障/跨窗重连。用户 2026-11-11 明确仅本机通过即可完成 P4，不因缩小验收范围抹除历史失败。未创建 VM、未抢用户前台或擅自推送 main。
- 行为规则已随代码变更更新 `docs/features/{diff,editor,ssh}.md`、`docs/testing.md`；流程修复在 `.github/workflows/ci-ui-test.yml`。审计原始数据见本目录唯一 `evidence-p4.md`。用户此次明确要求将 Feature 计划、`todo.toml`、证据和本审计一起提交 Git。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 适用范围：`仅本机验收`
- 理由：用户 2026-11-11 改为本机 Host＋受影响 Swift XCTest＋获授权 Windows SSH＋Debug／Release 构建与验签即可收口。`b76d4fa4` 完整 Host 955 项 0 失败 0 跳过；最终产品代码 `ae049476` 受影响 `NativeDiffTabTests` 136 项 0 失败、2 条 SSH 条件跳过（此前授权实机通过）；`make build`／`make build:ui`／`make build:release` 均通过，严格签名通过。
- 范围声明：没有在 `ae049476` 重新跑完整 955 项，也没有最新完整 App E2E 或旧 macOS CI 绿色证据；F-01／F-02／F-04／F-06 保留 Deferred，F-03／F-05 已 Resolved。`Go` 不等于所有环境全面通过。

## 最终状态与剩余风险

- 当前状态：`本机范围已完成，剩余跨环境与 E2E 证据延后`
- 剩余风险：旧系统上原生布局性能、完整 App 菜单／焦点／拖放，以及实际远端断线／跨窗行为仍可能与本机宿主测试不同；历史失败证据仍有效。用户本次明确不以这些条件阻塞 P4。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
