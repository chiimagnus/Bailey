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
- **设备/环境缺口**：缺少获授权的临时 Windows SSH 测试主机（只能用受控本机 Shell 夹具证明命令语义，不能证明 Windows/MSYS2 真传输）；缺少 macOS 15.6 真机（最低部署版本 GUI/文件系统差异仍未实测）；物理触控板、特殊卷/跨卷与真实掉线组合未获实机证据。各项在相应环境安全可用后补测，并在 P4 最终 Gate 重新核销。
- **文档核对**：`docs/features/files.md` 描述当前 Files 操作、剪贴板和数据保护；`docs/features/ssh.md` 区分远端永久删除与 Finder，本机界面规则位于 `docs/ui.md`。阶段验收缺口保留于本地计划及本审计，未把未测行为写作已验收。

## Gate（是否允许进入下一阶段）

- **结论：Go（仅允许继续后续实现；不是完整 E2E 验收通过）。**
- **理由**：P1-T4 的代码、90 项宿主回归及签名构建已通过；用户在 2026-10-25 明确要求因无法进行生物识别授权，延期 UI E2E 并继续 P2～P4。F-01 标记 Deferred，实际 GUI 剪贴板／多选等尚未通过，不得在 P4 最终验收时抹除。

## 最终状态与剩余风险

- **当前状态：Deferred；只豁免推进顺序，不豁免最终用户验收。**
- **剩余风险**：真实文件剪贴板快捷键、多选操作及远端确认的完整 App 行为需自动化验收；本机跨路径窗口与软链接竞态已完成宿主回归，Windows SSH/macOS 15.6/物理输入设备环境仍缺。XCTest 宿主会话已恢复，但系统 Automation Mode 仍要求用户认证。根据用户指令继续 P2～P4 的可执行工作；未授权的 GUI E2E 留待用户可解锁时补验。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

