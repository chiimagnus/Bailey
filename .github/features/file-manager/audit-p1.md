# Audit P1 - file-manager

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/file-manager/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 Files 多选、焦点与键盘导航
- [x] P1-T2 本机／SSH 安全文件复制移动与批处理
- [x] P1-T3 统一操作模型与编辑标签路径保护
- [x] P1-T4 右键、快捷键与批量确认入口（GUI E2E 已获用户明确延期）

## 任务到文件的映射

- **P1-T1（`96ad979`）**：`Bailey/Files/{FileTreeModel,FileTreePanel}.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`、`BaileyTests/Files/FileTreeTests.swift`、`BaileyUITests/Files/WorkspaceFilesUITests.swift`。
- **P1-T2（`235d2d5`）**：`Bailey/Workspace/{WorkspaceBackend,LocalWorkspaceBackend}.swift`、`Bailey/Remote/SSHWorkspaceBackend.swift`、`BaileyTests/{Files/FileTreeTests,Remote/RemoteCommandsTests}.swift`。
- **P1-T3（`ad9cc81`）**：`Bailey/App/WorkspaceApplication.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project}.swift`、`Bailey/Editor/FileViewerView.swift`、`Bailey/Git/DiffViewerView.swift` 与文件、窗口、编辑测试。
- **P1-T4（`c50c048`，实现已提交，GUI E2E 明确延期）**：`Bailey/Files/{FileTreePanel,FileTreeModel}.swift`、`Bailey/Workspace/{WorkspaceWindowModel,Project}.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/Remote/{SSHHostWorkspaces,SSHWorkspaceBackend}.swift`、`Bailey/Resources/Localization/Sidebar.xcstrings` 与对应宿主／GUI 测试。
- **功能文档**：`docs/features/{files,ssh,editor}.md`、`docs/ui.md`；跨窗口项目身份及操作入口与 `docs/features/projects.md` 对照。

## 发现项

## 发现 F-04

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:1268`
- 摘要：`Command 点击取消最后一个选中项后，目录刷新会偷偷重新选中该项`
- 风险：`多选集合与真实用户取消意图不一致，后续快捷键可能操作已取消的文件`
- 预期修复：`只有刷新前确实存在选中集合、且集合因路径不可见而清空时，才继承可见祖先；保留显式取消全选`
- 验证：`make test:FileTreeTests; make test:DockFocusIntegrationTests; make build:dev`
- 解决证据：`c7df6ab：目录刷新不会恢复主动取消的最后一项；真实目录刷新新用例通过；最终 10 类宿主 234/234、make build:dev 与 make build:ui 均通过。`


## 发现 F-03

- 任务：`P1-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/WorkspaceWindowModel.swift:729`
- 摘要：`旧的单项删除方法与只转发改名方法不再被生产入口调用`
- 风险：`与 P1-T3 唯一操作路径并存，增加误用及维护成本`
- 预期修复：`删除未使用的单项删除入口，改写测试调用到实际应用所有者并删除转发方法`
- 验证：`make test:SessionStoreTests,WindowOwnershipIntegrationTests,FileTreeTests; make build:dev`
- 解决证据：`3140f9e：删除旧 deleteFile 和 fileRenamed 转发，SessionStoreTests 改为应用所有者调用；234/234 宿主通过，Dev 签名与 UI 编译成功。`


## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:654`
- 摘要：`Finder 导入仅预先验证真实目标，异步复制仍使用可重指向的符号链接路径`
- 风险：`校验后若目录链接指向项目外，复制可能发布到未授权位置`
- 预期修复：`将已经解析并确认属于项目的物理目录交给复制后端，避免重复解引用原逻辑链接`
- 验证：`make test:FileTreeTests,RemoteCommandsTests; make build:dev`
- 解决证据：`1d9a584：Finder 复制使用校验后的物理目录，别名回归检查字节/源/目标；真实 windows SSH 4/4 通过含二进制复制移动删除，受影响 234/234 通过，Dev/UI 构建成功。`


## 发现 F-01

- 任务：`P1-T4`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`BaileyUITests/Files/WorkspaceFilesUITests.swift:testFileManagerClipboardCopyCutPasteAndTrashAgainstRealDisk`
- 摘要：`批量菜单完整 GUI 与新增边界用例尚未通过实际执行验收`
- 风险：`跨窗口别名及软链接 IO 竞态已经在宿主测试中通过，但真实 GUI 的文件剪贴板快捷键、多选批量磁盘结果和远端确认仍缺完整 E2E，不能以编译或菜单点击替代验收`
- 预期修复：`XCTest 宿主已恢复；用户在专用开发环境通过 macOS 官方 automationmodetool 配置一次性授权，再执行隔离 Bailey Dev 的剪贴板及多选完整 GUI 测试，核对实际文件副作用；不绕过系统授权`
- 验证：`make test:FileTreeTests,PanelContextTests,WindowOwnershipIntegrationTests,RemoteCommandsTests; make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests/testFileManagerClipboardCopyCutPasteAndTrashAgainstRealDisk`
- 解决证据：`2026-10-25 user explicitly postponed password/fingerprint-gated UI E2E while away; c50c048 implementation, 90 host tests, signed Dev/UI build and isolated manual single-item GUI verified; full keyboard/multi-select GUI and remote Sheet still unverified and must be revisited before final P4 gate.`


## 修复日志

- `96ad979`：Files 原有游标扩展为真实 Cmd/Shift 多选，保留 Git 行独立焦点；折叠、切换根、改名时维护选择集合。
- `235d2d5`：本机 Finder／同机复制共用同卷暂存与原子防覆盖；SSH 复用安全重命名发布，并在独立 shell 夹具中验证。
- `ad9cc81`：将编辑器待完成的保存与移动／重命名／删除串行化，更新已登记窗口标签；移除旧单项删除路径。
- `c50c048`：整合 P1-T4 的文件树菜单、快捷键、批量操作及剪贴板身份；重命名、移动、删除后的本地路径解析改为沿仍存在的父路径解析符号链接，避免跨别名窗口的旧路径误判；补充多窗口别名目录移动及删后脏稿保留测试，修正 XCTest 枚举缺少 children 时的错误。代码已提交，**不表示本 finding 已关闭**。

## 验证日志

- **实际通过**：P1-T1 的 `make test:FileTreeTests`（29 项）、`make test:DockFocusIntegrationTests`（3 项）和独立 GUI（1 项）；P1-T2 的 `make test:FileTreeTests,RemoteCommandsTests`（50 项）；P1-T3 的文件树／面板／窗口／持久化组合 92 项，Diff 与远端命令组合 56 项，Files 键盘焦点 GUI 1 项。以上均为对应提交当时通过的测试结果。
- **P1-T4 部分通过**：新增剪贴板部分成功及 SSH 缺失路径／符号链接删除的 Red→Green，`make test:WindowOwnershipIntegrationTests,RemoteCommandsTests` 34 项成功，**在后续新增物理父目录和跨路径标签修正之前**。
- **补充真实原生 GUI**（2026-10-25，独立签名 Bailey Dev `chiimagnus.bailey.dev`，仅操作受控临时项目）：经文件行右键实际打开菜单；制作副本后 `alpha copy.txt` 与 `alpha.txt` 字节一致且树中显示新条目；「Move To…」将 `beta.txt` 移至 `target/beta.txt`，原位置消失、内容字节一致且树更新；「Move to Trash」删除临时副本的原位置，源 `alpha.txt` 与已移动文件均未受影响。使用 Peekaboo AX 触发原生菜单、读取新界面，再以真实磁盘字节和路径验收。**未验证**系统剪贴板快捷键的最终 App 行为、批量多选组合、远端 Sheet；这些证据不等同于 `WorkspaceFilesUITests` 通过。
- **最终签名与编译**：`make build:dev` 退出码 0、`BUILD SUCCEEDED` 且通过严格签名验证；`make build:ui` 退出码 0、`TEST BUILD SUCCEEDED`。均不冒充 UI 测试执行。
- **XCTest 恢复和完整宿主验证**：对 `testmanagerd` 的真实进程采样显示其卡在 Automation Mode 的 `LocalAuthentication` 同步等待；在没有其他 XCTest 进程时重启当前用户的 `com.apple.testmanagerd` 服务后，`make test:FileTreeTests` 的 37 项全部通过。恢复后的 88 项相关回归曾实际发现一个跨符号链接路径的标签更新缺陷；修复后，`make test:FileTreeTests,PanelContextTests,WindowOwnershipIntegrationTests,RemoteCommandsTests,DockFocusIntegrationTests` 完整退出码 0，**90 项全部通过**，包括新增别名移动、删后保留脏稿及换目标竞态测试。
- **当前 UI 授权门槛**：macOS 27.2 上 `/usr/bin/automationmodetool` 实测显示「This device requires user authentication to enable Automation Mode」；当前执行环境无免密 sudo 权限，用户希望 UI Test 不弹授权窗口，尚未启用系统级免交互授权。此前 UI XCTest 的启动失败不等同于代码测试通过；单项原生 GUI 的手工受控验证详见上文。
- **覆盖过的触发条件**：本机多选、父子重叠、源/目标文件字节、部分成功、覆盖冲突、目录与失效软链接、保存等待、两个窗口同路径脏稿冲突、改名后的路径与旧路径缺失；远端 Shell 夹具验证删除/复制命令。
- **尚需完整 GUI 的条件**：真实 Cmd+C/X/V/D 键盘事件在 Files 与输入框、Git、编辑器之间的分发，以及多选批量操作的完整 App 最终磁盘结果；真实远端确认 Sheet。宿主已执行软链接等待期间换目标、跨别名重命名与移动、原生等效键焦点范围测试；单项右键副本、移动、废纸篓已按上文实际 GUI 验证。
- **设备/环境缺口（首次审计时）**：当时缺少获授权的临时 Windows SSH 测试主机，只能用本机 Shell 夹具验证；本轮已补做 `windows` 实机测试，见下文。macOS 15.6 真机、物理触控板、特殊卷／跨卷与真实掉线组合仍无完整实机证据。
- **文档核对**：`docs/features/files.md` 描述当前 Files 操作、剪贴板和数据保护；`docs/features/ssh.md` 区分远端永久删除与 Finder，本机界面规则位于 `docs/ui.md`。阶段验收缺口保留于本地计划及本审计，未把未测行为写作已验收。

## 本轮独立复核（2026-10-25 晚间）

先独立读取 `todo.toml`、四个任务提交、当前调用链和测试，再对照历史记录；任务状态与实际验收分开判断。

- **P1-T1 / `96ad979`**：`FileTreePanel` → `FileTreeModel.select/moveSelection` → 真实选择集合及键盘焦点。复核了 Cmd/Shift、可见顺序、折叠、跨根和输入控件；新增 F-04，修复显式取消最后一项后被刷新重新选中的问题。
- **P1-T2 / `235d2d5`**：`FileTreeModel` → `WorkspaceBackend.copy` → 本机 `RENAME_EXCL` 或 SSH 暂存发布。复核二进制、空文件/目录、软链接、同名冲突、并发占用、父子自复制和实际字节；新增 F-02，Finder 校验后改用物理目录，消除重新解引用可换向链接的路径。Windows 实机验证复制、防覆盖、移动和删除。
- **P1-T3 / `ad9cc81`**：`WorkspaceWindowModel.performFileOperation` → `WorkspaceApplication.withProtectedFiles` → FileTab/Diff 保存排空、磁盘操作、跨窗口标签更新。复核两份脏稿冲突、原路径失效、SSH 身份和删后缓冲。新增 F-03，删除无生产调用的单项删除／改名转发，测试改走真正的应用所有者。
- **P1-T4 / `c50c048`**：真实 Files 行／快捷键进入同一 `performFileTreeCommand`，剪贴板携带项目/机器/连接身份，远端删除采用发起窗口的 Sheet；原生 `firstResponder` 控制快捷键分发。宿主验证剪切仅在粘贴成功后移动、部分失败保留来源、跨窗口隔离，F-01 的原生完整 GUI 仍为 Deferred。

**本轮验证**：修复前基线 157 项、0 失败；首次修复后的受影响组合 131 项、0 失败；最终 10 个受影响宿主类 234 项、0 失败（日志 `/tmp/bailey-file-p1-audit-final-tests-20261025.log`）。真实 Windows SSH：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHFileTreeLiveTests`，4 项、0 失败、0 跳过（日志 `/tmp/bailey-file-p1-audit-live-ssh-verified-20261025.log`），含真实临时目录中的二进制复制／移动／删除和 8 MiB 读写；各测试使用自己创建的目录及 SSH socket 并执行清理。Windows 该账户不能创建部分符号链接，日志为 `P4_LIVE_SYMLINK_UNAVAILABLE status=1`，对应远端链接权限场景仍未实测，本机链接与受控 Shell 夹具另有测试。

**未核销**：真实 GUI 的多选键鼠、⌘C/X/V/D 焦点分发、远端批删 Sheet；macOS 15.6、物理触控板、特殊卷／跨卷和真实掉线的端到端组合。已有宿主测试不能代替这些平台测试；完整 P1 用户验收仍受 F-01 阻塞。

## Gate（是否允许进入下一阶段）

- **结论：继续后续阶段为 Go；P1 完整验收为 No-Go（F-01 Deferred）。**
- **理由**：P1-T4 的代码、90 项宿主回归及签名构建已通过；用户在 2026-10-25 明确要求因无法进行生物识别授权，延期 UI E2E 并继续 P2～P4。F-01 标记 Deferred，实际 GUI 剪贴板／多选等尚未通过，不得在 P4 最终验收时抹除。

## 最终状态与剩余风险

- **当前状态：Deferred；只豁免推进顺序，不豁免最终用户验收。**
- **剩余风险**：真实文件剪贴板快捷键、多选操作及远端确认的完整 App 行为尚需原生 GUI 验收；本机跨路径窗口和软链接已有宿主回归，Windows SSH 已完成实机文件操作验证，但其软链接权限场景受限；macOS 15.6、触控板和跨卷环境仍缺。Automation Mode 仍需用户认证，不绕过授权，不将宿主测试计作完整 GUI。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

