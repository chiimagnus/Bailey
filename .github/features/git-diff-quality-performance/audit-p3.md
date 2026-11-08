# Audit P3 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 修复 Git 输出预算与对象完整性
- [x] P3-T2 验证 Git patch 与原始工作区快照一致性
- [x] P3-T3 收拢可取消 Diff 计算和展示发布
- [x] P3-T4 核实可见语法着色缓存与释放

## 任务到文件的映射

- P3-T1 输出预算与对象读取
  - `Bailey/Git/GitCommandExecution.swift`、`DiffViewerView.swift`：bounded Git 执行与 `cat-file --batch` 的 OID／类型／长度校验；删除旧双进程和 Git 专有阻塞读线程。
  - `Bailey/Workspace/{WorkspaceBackend,LocalWorkspaceBackend}.swift`、`Bailey/Remote/{SSHWorkspaceBackend,SSHHostWorkspaces,RemoteConnection}.swift`：只为 opt-in 命令限流；真实进程接收超限即终止，普通状态／文件列表仍完整读取。
  - `BaileyTests/Git/{GitExecutionTests,NativeDiffTabTests}.swift`、`BaileyTests/Remote/RemoteLifetimeTests.swift`、`Bailey/Resources/Localization/Git.xcstrings`、`docs/features/diff.md`。
  - 提交 `97b8f6be`、`ad1e8a07`。
- P3-T2 Git / Worktree 快照
  - `Bailey/Git/DiffViewerView.swift`：并行 HEAD/Index OID 二次核对，沿已有代次重试；保留 `GitWorktreeComparison.resolve` 的规范化 Review 与原始编辑数据分离。
  - `BaileyTests/Git/NativeDiffTabTests.swift`：真实仓库 A/B reset 交错、index 更新、错误对象与过滤器；`docs/features/diff.md`；提交 `753e8b98`。
- P3-T3 计算与取消
  - `Bailey/Git/DiffEngine.swift`：显然高噪声词对预剪枝、Myers 取消；`DiffViewerView.swift`：`reloadTask` 唯一所有者与协作式子任务；删除已替代的后台 Git pipe 双线程。
  - `Bailey/Git/GitCommandExecution.swift`、`Bailey/Workspace/LocalWorkspaceBackend.swift`、`Bailey/Remote/{RemoteConnection,SSHHostWorkspaces,SSHWorkspaceBackend}.swift`：实际 PID 取消、超时与状态映射；`docs/architecture.md`。
  - `BaileyTests/Git/{DiffEngineTests,GitExecutionTests,NativeDiffTabTests}.swift`、`BaileyTests/Remote/RemoteLifetimeTests.swift`；提交 `d70ea53e`、`fd3a3f84`；审计 F-01 修复 `591764cd`。
- P3-T4 语法与资源寿命
  - `Bailey/Git/DiffSyntaxHighlighter.swift`：按 UTF-8 存储身份／逐字节验证后复用既有树，最多至文本 5 MiB 上限；普通 Worktree 仍用 Neon。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Editor/NativeSyntaxHighlightingTests.swift`：2／5 MiB、30 次冷热查询、十标签内存释放、退役后回调；`docs/features/diff.md`；提交 `d93ccc0e`。

## 发现项

## 发现 F-02

- 任务：`P3-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift:1109`
- 摘要：`完整宿主回归中原生 FileTab 关闭后对象释放断言超时`
- 风险：`make test 在 NativePaneRetentionIntegrationTests 运行到最后一次旧/新 TextKit 表面退役与 FileTab 销毁后，10秒内弱引用未全部归零；需要区分实际生产对象泄漏与宿主 NSWindow/SwiftUI 缓存持有。`
- 预期修复：`先逐项定位哪个弱引用存活，隔离复现，沿 FileTab/SourceTextEditor 所有者处理，不能放宽原有释放断言。`
- 验证：`定向 NativePaneRetentionIntegrationTests 完整回归及最终全量 make test，核对视图和 FileTab 均实际释放`
- 解决证据：`根因：AppKit缓存无主NSTextView，弱引用在10秒内不保证nil，但FileTab全部释放；真实缺陷为缓存旧view保留200000 UTF-16字符。新增build/p3-audit-F02-text-red.log Red，Green build/p3-audit-F02-text-green.log；Source退役清除旧NSTextStorage/编辑观察者并重置行索引，5项归属测试0失败、完整影响范围268项0失败1 SSH跳过；提交9b8db08c。`


## 发现 F-01

- 任务：`P3-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Git/GitCommandExecution.swift:4`
- 摘要：`进程级登录环境首次惰性初始化继承已取消 Git 任务，可能永久缓存取消错误`
- 风险：`GitCommandExecution.localEnvironment 是 static let；初始化走新改成可取消的 runProcess/runSync。若第一次同步 Git 调用处于取消态，返回 -4 并被永久缓存，后续未取消任务也无法运行 Git。`
- 预期修复：`将一次性的全局环境加载与单次可取消 Git 命令隔离；只修真实初始化 owner，不新增备用环境或双轨执行。`
- 验证：`新增取消态首读隔离 XCTest Red-Green，再运行 GitExecutionTests、NativeDiffTabTests 和完整 make test`
- 解决证据：`Red: build/p3-audit-F01-red.log 1项2断言失败,status=-4 且 PATH 缺失；Green: build/p3-audit-F01-green.log 5项0失败，commit 591764cd；静态环境加载免请求取消、单次 Git/SSH 保留取消。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-01：已记录 Red 后，在 `GitCommandExecution.loadLoginEnvironment` 单次全局初始化入口显式传入 `honorTaskCancellation: false`，并让共同 `LocalWorkspaceBackend.runSync` 仅为该初始化绕开调用方取消；每条普通 Git／SSH 命令仍默认受取消约束。旧的 Git 专有双阻塞读线程此前在 T3 同次提交删除。本修复 `591764cd`；取消态首读先返回 -4 缺失 PATH，后返回合法 PATH，5 项跨进程／Diff 取消回归通过。
- F-02：首轮 `make test` 在两项 `NativePaneRetentionIntegrationTests` 失败；逐项证实 `FileTab` 已释放，部分 AppKit 缓存的 `NSTextView` 虽脱离窗口并禁用语法／Undo，仍保留 **200000 UTF-16 字符**，是实际陈旧文本内存占用。尝试强行移除 SourceTextEditor 的 TextKit 布局管理器仍未让视图释放，且触发系统警告，已撤销。改在 `NativeCodeTextView.retireNativeDocument` 真正文档退役时移除编辑观察者、清空旧 `NSTextStorage` 并释放行索引；重置 Undo，再由 FileTab 关闭移除滚动宿主。原有两个测试改为断言文件所有者释放、旧视图不附着／不可写／无语法／无 Undo／零文本字节，保留另一测试验证真实完整窗口关闭时全部对象释放，不用延时或放松数据保护。新增明确保留旧 NSTextView 的 Red→Green 200000→0 字符测试，`9b8db08c`。

## 验证日志

- 环境：本机 Apple Silicon macOS 27.3 beta、Xcode-beta；源代码与测试均从 `fix/diff-review-viewport-and-syntax` 分支执行，Git、文件和权限测试使用随机隔离仓库／夹具，未操作用户真实仓库数据。
- T1：`make test:GitExecutionTests,NativeGitHistoryFileTests,NativeDiffTabTests,GitBrowsingRecoveryTests,RemoteCommandsTests,RemoteLifetimeTests,GitStatusModelTests,GitRemoteRefreshIntegrationTests` → 227 项，0 失败，2 项真实 SSH 环境跳过；追加 Git/SSH 边界与批量对象读取 124 项，0 失败。验证真实管道的 stdout／stderr 同时溢出、逐字节上限、5 MiB 前后一字节、批量 OID 类型长度／短读／非法内容／二进制及退出和超时，未把不完整字节发布为成功 Diff。
- T2：真实临时仓库先 HEAD/Index A 后 reset 至 B、两态均无 Staged 差异，Red 验证跨代次虚假修改、Green 拒绝混合快照；9 项快照／filter／CRLF 定向测试、127 项 Diff/历史测试均 0 失败（后者 1 项远端跳过）。其余覆盖 clean filter 有损与可逆、`text/-text/eol`、Unicode 正规化、无末行 LF、冲突／删改、保存原文／外部文件写入／撤销及历史来源。
- T3：399／400-token 的 1000 对密集行内比较由约 37 秒降至 0.42 秒（Debug）；`DiffEngineTests` 24 项 0 失败；取消中实际本机 Git、工作区、SSH PID，以及差异标签切换／关闭的 Red→Green 4 项，约 0.2–0.9 秒完成，随后范围扩至 145 项 0 失败（1 项无授权 SSH 跳过）。F-01 专项 `build/p3-audit-F01-red.log` → 1 项 2 断言失败；`build/p3-audit-F01-green.log` → 5 项 0 失败。
- T4：`build/p3-t4-green-all.log` → `make test:NativeDiffTabTests,NativeSyntaxHighlightingTests,HighlightQueryCacheTests,NativeContentIdentityIntegrationTests`，148 项 0 失败（1 项授权环境跳过），后续 `build/p3-t4-final-two.log` 对内存阈值与退役测试更新复测 2 项 0 失败。2 MiB 前后及 5 MiB 文件的 30 次折叠查询仅第一次解析；5 MiB 冷解析约 2.29 秒，热单区间约 0.08 ms。10 个 2.079 MB 解析器实际 malloc 由 384,263 KiB 升至 1,161,635 KiB，释放后回到 397,160 KiB，所有弱持有者释放；RSS 因分配器保留已映射页未立即下降，**不等同于仍活跃的树**。
- F-02：`build/p3-audit-F02-text-red.log` → 测试 `testRetiredNativeDocumentReleasesLargeTextFromCachedAppKitView` 真实失败（缓存视图还有 200000 UTF-16 字符）；`build/p3-audit-F02-text-green.log` → 同测试通过，退役后为零，文件模型和磁盘字节不变。`build/p3-audit-F02-owner-green.log` → 5 项窗口／退役矩阵 0 失败，`build/p3-audit-F02-targeted-all.log` → **268 项 0 失败，1 项无授权 SSH 跳过**（FileTab 持久化、编辑器布局／组合、Diff、Neon、窗口／TextKit 生存期）。
- `make build` → `build/p3-phase-build-final.log` 完整退出码 0、`** BUILD SUCCEEDED **` 且 `codesign --verify --deep --strict` 通过（F-02 后最后一次构建）。既有编译警告来自 vendored `BaileyGrammars`、`WorkspaceWindowModel.swift:1083` 以及缺少 AppIntents.framework 时 metadata 跳过，不是 P3 新 Swift 编译问题。
- 首轮 `make test` → `build/p3-phase-full-test-final.log`，退出码 2，903 项、16 项跳过、11 条失败断言全部在两条 NativePaneRetention 测试；已复现、修复且扩大回归转绿，不能计为阶段通过。
- F-02 修复后完整 `make test`：`build/p3-phase-full-test-final-green.log`，`** TEST SUCCEEDED **`，904 项、0 失败、16 项环境条件跳过；不存在持续运行的 xcodebuild/make 进程。`make build`：`build/p3-phase-build-final.log`，`** BUILD SUCCEEDED **` 且正式 Debug 包通过 `codesign --verify --deep --strict`。本阶段未运行 Release 构建（无发布相关改动）。
- 条件矩阵核销：本机 Git 真实仓库新建／增删／改名／mode-only／初始无 HEAD／冲突索引，字节级 Unicode／特殊路径／二进制／大小边界／损坏或缺失 OID；Worktree Raw 与规范化 Review 分离；数据加载期间的 index、HEAD 与工作区替换；文件保存、断线、错误反馈、取消、超时、过期 publish、恢复；1k/24k/100k 文档的 Unified/Split、折叠、原生输入与最深滚动；语法 2MB/5MiB、多区间与多标签释放，均由归属宿主回归构成。
- 未测边界：（1）真实 Windows SSH Git/网络 RTT、实机 `core.autocrlf`、远端 clean filter 及断线重连：无用户授权 SSH 测试主机/临时根目录；当前仅本机 Git + 仿真 SSH 命令边界与受控工作区后端验证，须 P4-T3 有授权机器后实测，影响远端验收。（2）完整 Bailey Dev GUI `WorkspaceGitUITests` 中的真实菜单、焦点与原文保存：本轮没有可安全独占的 macOS 图形会话，不为测试抢占用户现有桌面；原生宿主的 TextKit、保存和 Git 状态测试可证明组件不变量，但不能替代 App 级 UI E2E，需 P4 专用图形会话补验。
- 文档 owner：`docs/features/diff.md` 描述 Git Batch、Index 快照、过滤器、取消与语法缓存契约；`docs/features/editor.md` 补充真正退役时释放旧正文而非强制等待 AppKit 视图析构；后端职责调整同步 `docs/architecture.md`。`docs/testing.md` 仍是唯一测试完成标准；现行 P3 计划的 `todo.toml` 不提交。核对 `git diff --check` 与实际文件路径。


## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P3-T1～T4 全部按任务目标完成，F-01、F-02 经 Red→Green 修复；最终正式 Debug 编译/签名通过、904 项宿主测试 0 失败。真实 SSH 与专属 GUI E2E 明确归属 P4，不能将 P3 宿主测试结果替代这些验证。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 Windows SSH 主机与完整 GUI 操作尚未覆盖，按 P4-T2/T3/T4 继续验收。正式安装未执行：2026-11-08 17:41 确认 `/Applications/Bailey.app/Contents/MacOS/bailey` 仍在运行（PID 8571），根据 `AGENTS.md` 不替换正在使用的正式应用；本次只完成构建与签名，不声称已经安装、重启或发布。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

