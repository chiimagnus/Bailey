# Audit P1 - finder-integration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/finder-integration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 本机项目与文件标签复用
- [x] P1-T2 跨窗口复用与冷启动请求接入

## 任务到文件的映射

- P1-T1 · `0d994fe4084429943ccae954d1db49bfeeb6638b`
  - `Bailey/Workspace/TerminalManager.swift`: `openExternalLocalItems`，仅本机文件与目录项目，保留手动 `addLocalItems` 和 `pinnedFile`
  - `BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift`: 6 组 Finder 文件路由、软链、批量、SSH 隔离回归
  - `docs/features/projects.md`: 手动添加与外部打开的契约
- P1-T2 · `aa999e902b74bf84830493fc0dc8c454e8e8e3be`
  - `Bailey/Workspace/TerminalManager.swift`: `registry`、`openExternalFiles`、`attach`、窗口请求与结束；含旧 Finder Service 的非空 key/main 窗口修正
  - `BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`: 原生 NSWindow 双窗口、未附着与取消、批次顺序和跨套件状态
  - `Bailey/Resources/Localization/Interface.xcstrings`: 打开失败提示中英文本
  - `docs/features/dock.md`、`docs/features/projects.md`、`docs/features/session-restore.md`: 目标窗口、标签去重、恢复边界

## 发现项

逐任务审查提交与当前源码、直接调用者、复用的 `Project.openFile`、`FileTab`、`SessionStore`、`WindowGroup`、旧 Finder Service 及相关测试，未发现尚需单独提交的确定性 P1 代码缺陷。审查时识别的「未附着无关管理者阻塞」和「两个 nil 窗口误判为 key/main」均已在 P1-T2 提交前以 Red→Green→完整套件修复。

## 修复日志

- 无未解决 P1 finding。`0d994fe` 和 `aa999e9` 均为独立、中文、含验证说明的代码提交；未修改原 `Project`、`FileTab` 和 `SessionStore` 模型格式，也没有清理旧 Finder Service 仍需的目录队列。
- Feature `idea.md` 结尾的「当前仅审查并更新计划」是实施前文案，执行中已无效；改成以 `todo.toml` 为状态真源（不改历史提交证据）。

## 验证日志

- `make build DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder` -> **exit 0**，`** BUILD SUCCEEDED **`，末尾严格 `codesign --verify --deep --strict` 返回 0。
- `make test DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder` -> **exit 0**，**437 tests，0 failures，6 skipped**，日志 `/tmp/bailey-finder-p1t2-final-fulltest.log`、xcresult `build/DerivedData-finder/Logs/Test/Test-Bailey-2026.10.18_03-05-09-+0800.xcresult`。
- Red→Green：缺失新入口使 6 组测试编译失败；跨窗口路由的完整套件 Red 首次出现 9 项失败，后缩小到可选 `NSWindow?` 的 nil identity 错误；跨类测试顺序 `WorkspaceIdentityTests + WorkspaceWindowIsolationTests` 17/17，末次全套 437/437 含原生窗口隔离 6/6 通过。
- **已覆盖的入口和环境**：本机目录/单文件/已打开 FileTab、多窗口有/无焦点、窗口关闭与未附着、交错批次与同目录、软链/失效软链、无效 URL、文件被删除、中文/emoji 路径、SSH 同路径隔离、项目固定文件语义、合法失焦保存及文件内容读取；`SessionStoreTests`、`PaneRetentionTests`、`AppMenuIsolationTests`、工作区 Git/Files 测试经完整套件执行。断言实际 `FileTab` 对象、项目/标签身份、目录和原盘字节。
- **未完成且属于后续阶段的必须验收**：Finder / Dock / `open -a` 的进程外投递和 macOS Launch Services 注册：P1 尚未声明 `CFBundleDocumentTypes`，本阶段不能模拟为真机成功，P2-T1 必须检查签名 App 的回调、真实文件正文/焦点和多窗口冷启。STTextView/Ghostty/WKWebView 与 Files 精确放置目标属于 P3 原生测试。
- **环境跳过**：6 项套件测试依赖专用、明确授权的 Windows SSH 实机或特定环境，当前未配置 `BAILEY_P4_TEST_SSH_HOST` 等条件；P1 的本机文件入口已使用模拟 SSH 隔离和本机实盘测试，实机 SSH 行为在 P3 的独立安全边界验证；macOS 15.6 实机当前不可用（工具链为 Xcode 27.2，本机当前系统），无法以当前 SDK 构建替代运行实测，作为最终环境验收缺口记录。
- 已核对功能文档事实与链接归属：项目添加归 `projects.md`，窗口定位归 `dock.md`，冷启窗口快照归 `session-restore.md`。P1 只完成可复用底层路径，未将 Finder 系统注册或用户级拖放写成已具备功能。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P1 两个任务已实现、原子提交、全套构建与 XCTest 通过，当前窗口/项目/本机文件标签不变量均成立；真正 Finder 系统事件与原生放置是明确的 P2/P3 Gate，不能由本阶段测试冒称已完成。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实 Finder/Dock/Launch Services/macOS 15.6/外部放置及专用 Windows SSH 测试尚无 P1 层证据；按上文 P2/P3 验收条件逐项补全，否则不得宣布 Feature 全部完成。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-19 独立复核（按原始提交与当前调用链）

- **P1-T1 · `0d994fe`**：原提交确曾实现「已有本机标签 → 包含该文件的目录 Project → 必要时创建本机 Project」的当时要求；它不是 P4 当前行为。独立核对 HEAD 的 `TerminalManager.openExternalLocalItems` 和 `addLocalItems`：`filesByParent`、`explicitDirectories`、`contains(path:in:)` 与普通文件创建 Project 的分支均不再存在；`addLocalItems` 仅接受目录。旧 `pinnedFile` 数据的恢复、重命名及明确 SSH 文件项目的写入仍可达，不能为了清理旧策略误删。
- **P1-T2 · `aa999e9`**：`openExternalFiles → deliverPendingExternalFiles → openExternalLocalItems → Project.openLocalFile` 在当前源码仍连通；通过真实 `registry`／已附着窗口查找现存本机标签，`pendingRestores` 未清空时延后消费，关闭指定接收窗口时取消其批次。原目录 Service 与系统文件事件的待处理数据仍有不同调用方，不能按「重复队列」名称机械删除。
- **重新运行的证据**：在本 worktree 执行含获授权 Windows SSH 的全量 `make test`，完整退出 0，**472 项／0 失败／0 跳过**；`WorkspaceIdentityTests`、`WorkspaceWindowIsolationTests` 真实执行。19 个原始分支提交各自的 `git show --check` 通过；原生 Finder 完整图形组合不能由这些 XCTest 推导。
- **独立 Gate**：P1 的**历史任务**可保留完成，**不能**将原 P1 按目录建项目规则作为当前验收或恢复依据；现行归属、安全和 GUI Gate 交给 P4。无新增 P1 阻塞 finding。
