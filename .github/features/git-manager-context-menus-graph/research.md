# Git Manager P4：Git Graph / VSCodium 右键菜单的源码依据

本文只记录 **P4 执行前的可验证事实**：外部行为来源、Kero 当前入口与已证实的边界。具体需求在 [idea.md](idea.md)，逐项弹窗、任务及验收在 [plan-p4.md](plan-p4.md)。P1～P3 的旧范围、图谱算法与刷新决策已留在 [P1](plan-p1.md)、[P2](plan-p2.md)、[P3](plan-p3.md)，**旧 P2 曾排除 Cherry-pick/Remote/Tag 并不限制 P4**；[design.html](design.html) 只是 Recent Commits 历史视觉原型，不能作为原生交互通过的证明。关联 [Issue #2](https://github.com/chiimagnus/kero/issues/2)，包括[原 Commit 菜单截图](https://github.com/user-attachments/assets/4321d2dd-7bb6-4499-aa9d-2bcf11663c25)。

## 一手行为来源

| 固定来源 | 哪部分是行为依据 |
| --- | --- |
| [Git Graph develop `d7f43f4`](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812) | `web/main.ts` 的 Commit、Branch、Remote Branch、Tag、Stash、Uncommitted、Commit File 菜单与弹窗分流；`web/dialog.ts` 的按钮和字段交互；`src/config.ts` 的默认值；`src/dataSource.ts` 的实际 Git argv 与二段操作；`src/utils.ts` 的 Archive、历史文件/重命名与交互终端；`web/graph.ts` 的 Drop 拓扑条件 |
| [Git Graph 菜单说明](https://github.com/mhutchie/vscode-git-graph/wiki/Context-Menus) | 核对对象分类与显示条件；**源码优先**，不把截图或菜单名称等同于实际行为 |
| [VS Code 内置 Git 固定版本](https://github.com/microsoft/vscode/blob/76e9dff43b237f3fcbb8a289ed2f8bdf28105baf/extensions/git/package.json) | VSCodium 使用 VS Code 内置 Git 扩展的 SCM 菜单声明。重点是文件、目录与分组的 Stage/Unstage/Clean/Open File/Open HEAD File/Ignore；不混成 Git Graph 扩展自身的 Commit 菜单 |
| [VS Code `repository.ignore`](https://github.com/microsoft/vscode/blob/76e9dff43b237f3fcbb8a289ed2f8bdf28105baf/extensions/git/src/repository.ts#L2728) | 打开/建立 Git 根目录 `.gitignore` 文档，按行追加选择的相对路径后保存；没有专属 Ignore 编辑器 |
| [Apple SwiftUI `contextMenu`](https://developer.apple.com/documentation/swiftui/view/contextmenu(menuitems:)) | Kero 的对象菜单使用原生 SwiftUI/AppKit，而不是嵌入 Git Graph WebView |

上游证实的**二次行为**包括 Branch/Tag 重名时「替换 / 换名称」、远端 Branch Checkout 重名时「换名称 / 切已有并 Pull」、未合并 Branch 删除失败后询问强删、Tag 推送到可能不包含目标 Commit 的远端时警告。Merge 的 No-FF 默认开启；Commit Reset 默认 Mixed；Cherry Pick 仅合并提交需要选择父节点；Rebase 交互式模式会打开终端；Stash Apply/Pop 的 Reinstate Index 默认关闭。所有输入、默认值、按钮及 Git argv 由 [P4 弹窗合同](plan-p4.md#原生弹窗行为合同) 单独维护，不在此重复列一份操作表。

**适用边界：** Git Graph 的 Branch/Remote Branch/Tag 有 Create Archive，适合 Kero 原生保存；其 PR Provider、Issue Linking、Code Review、Branches Dropdown、列配置、外部 Difftool 没有现有 Kero 对应对象，暂不移植。VS Code 历史图里的 Compare with Ref/Merge Base 不是 Git Graph 普通 Commit 右键命令，不为混合两个产品而新造泛用比较器。VSCodium 的 Ignore 属于文件/目录菜单，应补齐，但必须复用 Kero 现有文本编辑器与保存流程。

## Kero 已有入口与缺口

| 实际 owner / 入口 | 阅读当前代码后确认 | 应在何处落地 |
| --- | --- | --- |
| `RecentCommitsView.commitRow/referenceActions/referenceGroup/changedFile` | 双行图谱、左击展开、短 SHA、Ref/`+N` 基础命中已有；Remote Ref 仍是只读，Commit/Tag 菜单仅少数功能 | 扩展**同一对象入口**的按钮和回调，`+N` 调相同菜单，不改 Canvas 和共享树 |
| `GitPanel.branchMenu/moreMenu/changeList/GitEntryRow.menu` | 顶部 Fetch/FF-only Pull/Push/Sync，MERGE/STAGED/CHANGES 分组，Stage/Unstage/Discard 及原生确认已有；`stashCount` 不等于可选某一条 | 保留现有菜单语义，在原分组和既有面板补所需 Stash/Ignore/Uncommitted 右键，避免平行工具栏 |
| `GitPanel.presentGitNameDialog` | 通过 `NSApp.keyWindow ?? NSApp.mainWindow` 挑弹窗窗口；多窗口下不保证属于右击来源 | 由 `ToolPanelView.manager.window` 明确注入发起窗口，取消后不能作用到别的项目 |
| `GitStatusModel.createReference/perform/runGitStatus` | `perform` 已排他执行，校验仓库、HEAD/branch 和可选 upstream，刷新/机器代次已有；**未校验所选 Branch、Tag、Remote Ref 和 Stash OID**。P2 `createReference` 只创建本地普通 Branch/轻量 Tag | 沿这唯一 Model/Backend 入口补真实命令、必要的所选对象 OID 校验与状态；成功/部分成功/失败都取自 Git |
| `GitStatusModel.repositoryOperation` | 已识别 Merge/Cherry-pick/Revert/Rebase/Bisect 标记，并在 Banner 提示终端恢复 | **无需新状态机**；Git Graph 菜单自身没有 Continue/Abort/Skip GUI，使用既有原生终端实测恢复 |
| `GitCommandExecution.runData`、`WorkspaceBackend.run/read` | argv 支持本机与 SSH；`stdoutLimit` **会截断但保留 exit 0**，SSH 的 `ProcessRemoteCommandRunner` 先无界收集 stdout；`SSHWorkspaceBackend.read(path:maxBytes:)` 能通过多读一字节严格判断超限 | Archive 必须先在选定机器生成本次临时文件，再通过有界 `read` 传完整字节、本地校验/保存，失败只清理本次临时文件，不新造流式服务 |
| `Project.newSession(directory:)` 与 `TerminalSession.sendCommand` | SSH 路径的 `directory` 参数被 `makeSession` 忽略；`sendCommand` 仅将字节交给 PTY，不能证明初始 Shell 已就绪 | Interactive Rebase 只在**发起项目的新终端**执行，先验证 prompt/远端 cwd，绝不使用旧终端或无依据 sleep |
| `Project.openCommitDiff/findDiffTab` → `DiffTab.reload` | 历史 Diff 仅读 Commit 第一父与 Commit 本身；Tab Key 不包含 revision-only/revision-to-worktree 模式 | 扩展已有 DiffTab 的来源和身份，不建立第二套文本展示；历史 Open File/Revision↔Worktree 还需按上游 `getNewPathOfRenamedFile` 追踪重命名 |
| `Project.openFile` → `FileTab` → `SourceTextEditor.Coordinator` | 同一路径复用 FileTab；文本 `file.text` 被 `@ObservationIgnored`，原生 STTextView 持有另一个显示缓冲；SSH FileTab 初始 `.loading`，`save()` 是唯一串行保存路径 | Ignore 应等文本真正读入后通过**同一个原生编辑缓冲**追加并保存；不可直接改 `file.text` 或 Backend 偷写，否则 UI/undo/未保存修改会分裂 |

## 已复现的关键 Git 边界

- **Stash OID 与 selector 不等价：** 在隔离临时 Git 库中，`git stash apply <OID>` 成功，而 `git stash drop <OID>` 被拒、`git stash drop 'stash@{0}'` 成功；Pop/Drop 必须持有菜单打开时的 `stash@{n}` **和**对应 OID，并在执行前核实 selector 没有移位。
- **远端 Ref 删除必须尊重服务器状态：** 2026-10-14 的临时 bare remote 验证：`git push --force-with-lease=refs/heads/main:<oldOID> origin :refs/heads/main` 在远端 tip 改变后原子拒绝；tip 匹配时，服务器默认仍可能因 `receive.denyDeleteCurrent` 拒绝删除其 HEAD 分支。仅在**测试 bare remote**显式更改该设置后才成功；Kero 不得修改用户远端的保护配置。测试目录 `/tmp/kero-p4-gitcheck.feDqH6` 仅为本次隔离实验证据，非代码依赖。
- **风险来自用户目标，不来自按钮名称：** Soft/Mixed/Hard Reset 对 HEAD、index、worktree 的效果不同；Drop 会重放后续提交而非做 Revert；Tag 是 Annotated Object 时不能混用 Tag Object OID 和 peeled Commit；SSH 同名路径不得回退写 Mac；历史 File Reset 会同时改 index 与 worktree，不能覆盖未保存编辑。
- **测试证据分层：** `GitStatusModelTests` / `GitExecutionTests` 的临时仓库需核对真实 refs/index/worktree；`RecentCommitsViewTests` / `DiffTabTests` 验证原生菜单、显示与 Tab；独立 App E2E 和经批准的 Windows SSH 专用测试仍是单独关口。Issue #2 的 SSH 外部刷新仍未实测，不因 P4 菜单完成而关闭。
