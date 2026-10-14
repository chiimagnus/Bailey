# Audit P2 - git-manager-context-menus-graph

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/git-manager-context-menus-graph/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 按 Commit、本地分支、Tag 归属原生 Context Menu
- [x] P2-T2 在指定 Commit 创建本地分支与 Tag

## 任务到文件的映射

- P2-T1（`dddc9b0`）：`kero/Git/RecentCommitsView.swift` 菜单归属、`kero/Git/GitPanel.swift` 原分支切换回调、`KeroTests/NativeUI/Git/RecentCommitsViewTests.swift` 真实窗口 Tag 点击、`kero/Resources/Localization/Git.xcstrings` 与 `docs/features/git.md`。
- P2-T2（`8734bae`）：`GitPanel.swift` 共享 NSAlert 输入及当前仓库目标、`GitStatusModel.swift` 复用 `perform` 创建指定 SHA 的本地引用、`RecentCommitsView.swift` 两个创建菜单、`KeroTests/Integration/Git/GitStatusModelTests.swift` 临时真实仓库校验、Git 本地化与功能文档。

## 发现项

逐一核对代码所有权、Git 命令与失败路径后，未发现达到 finding 准入门槛的未解实现缺陷。P2-T1 的创建菜单被明确移到 P2-T2，在真实操作具备前不展示无效菜单；无第二套菜单框架、Git 状态机或 Tag 发布路径。

## 修复日志

- T1 NativeUI：点 Tag 定位由 Red（选中 Tag 未展开）变 Green；保留 Commit 标题展开、SHA 复制、历史文件 Diff 及远端跟踪只读语义。
- T2 Integration：旧 `git switch -c` 行为在选择历史 SHA 时 Red（创建于 HEAD 且自动切换），新的 `git branch -- name sha`／`git tag -- name sha` Green。复用原有确认框和 `perform`，不创建新执行器。

## 验证日志

- `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` → PASS（2/2，原生窗口及引用点击）。
- `make test ONLY_TESTING=KeroTests/GitStatusModelTests` → PASS（8/8，真实本地仓库新建 Branch/Tag，重复名、切仓库、保持 HEAD 和 Ref 更新）。
- `make test` → PASS（103/103，零失败）。
- `make build` → PASS（Debug + `codesign --verify --deep --strict`）。
- `python3 -m json.tool kero/Resources/Localization/Git.xcstrings`、`git diff --check` → PASS。
- CodeGraph 确认 `GitPanel → RecentCommitsView → GitPanel.presentCreateReferenceDialog → GitStatusModel.createReference → perform → GitCommandExecution → WorkspaceBackend` 为产品真实执行链，输出通过真实 `git rev-parse` 核实。
- `docs/features/git.md` 负责 Git 当前操作契约，P2 菜单和按 SHA 创建行为随各次代码提交同步更新；feature 计划与审计只本地维护。
- 实际本机隔离 Debug UI 进程 61823 成功运行；Peekaboo 观察到原生空项目界面及 NSOpenPanel，但系统对该文件对话框的后台 AX/焦点输入拒绝，**无法将临时仓库载入完整 App 操作**。因此独立进程的 Commit 右键及原生 NSAlert 输入未完成端到端验收；已完成的是 SwiftUI 宿主 NativeUI 和 Git 集成测试，不将其冒充 E2E。真实 SSH 仍未测。

## Gate（是否允许进入下一阶段）

- 结论：**Go（P2）**
- 理由：本阶段新增菜单和本地 Git 写入已连通正确生产路径，真实 Git 结果、NativeUI 宿主及完整测试通过；独立进程 E2E 的受限部分列为未测，不据此扩大权限或误报通过。

## 最终状态与剩余风险

- 当前状态：**Resolved（P2 代码及回归验证）**
- 剩余风险：右键弹出完整 App 菜单、NSAlert 确认的整链独立进程 E2E，及真实 Windows SSH 行为仍待获可操作测试界面／专用测试连接后验收；不影响继续排查 P3 的刷新触发事件。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-14 独立逐提交复审

本轮独立对照 `plan-p2.md`、原始提交完整 diff 和 CodeGraph 调用路径，不依赖先前审计的通过记录。

- **P2-T1／`dddc9b0`**：Commit 整行提供展开／复制；本地分支与 Tag 单独拥有 `.contextMenu`，远端跟踪引用仍为只读标签；过宽时 `+N → 各自子菜单` 保留可操作路径；历史文件依旧复用 `TreeFileRow` 与 `openCommitDiff`，Changes/Stash/仓库菜单未被另造。原生宿主窗口验证标题点击、Tag 展开和历史文件 Diff。
- **P2-T2／`8734bae`**：`GitPanel.presentCreateReferenceDialog → GitStatusModel.createReference → perform → GitCommandExecution → WorkspaceBackend` 全链已核对。测试在真实临时仓库验证分支及轻量 Tag 指向所选旧 SHA、HEAD 不切换、重复名称不覆盖以及切换仓库后拒绝。取消 NSAlert 直接返回，不触发写命令。**`94cabe5`** 移除固定 SHA 40/64 位和 ASCII 逐字节重复校验：模型仅接受仍列于当前历史快照的目标，`perform` 检查仓库与 HEAD，Git 自身拒绝非法 OID（实测 128），未移除任何保护真实写入目标的校验；专项 GitStatusModelTests 8/8。
- **验收边界**：菜单及调用链在正式 `GitPanel` 可达，但独立进程对实际菜单右击及确认对话框的完整 E2E 因 macOS 原生文件选择框自动化限制仍未通过；不将宿主窗口和模型集成测试误称独立完整 App E2E。最终 `make test` **106/106**、`make build` 和严格验签通过；独立源码审计 Gate：**Go（本机可自动化验证范围）**。没有新增第三方菜单框架、Tag 发布/删除功能，也没有保留旧的演示假操作。
