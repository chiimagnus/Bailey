# Git Manager P4：Git Graph / VSCodium 右键菜单的源码依据

本文只记录 **P4 执行前的可验证事实**：外部行为来源、Kero 当前入口与已证实的边界。具体需求在 [idea.md](idea.md)，逐项弹窗、任务及验收在 [plan-p4.md](plan-p4.md)。P1～P3 的旧范围、图谱算法与刷新决策已留在 [P1](plan-p1.md)、[P2](plan-p2.md)、[P3](plan-p3.md)，**旧 P2 曾排除 Cherry-pick/Remote/Tag 并不限制 P4**；[design.html](design.html) 只是 Recent Commits 历史视觉原型，不能作为原生交互通过的证明。关联 [Issue #2](https://github.com/chiimagnus/kero/issues/2)，包括[原 Commit 菜单截图](https://github.com/user-attachments/assets/4321d2dd-7bb6-4499-aa9d-2bcf11663c25)。

## 一手行为来源

| 固定来源 | 哪部分是行为依据 |
| --- | --- |
| [Git Graph 固定提交 `d7f43f4`](https://github.com/mhutchie/vscode-git-graph/tree/d7f43f429a9e024e896bac9fc65fdc530935c812) | `web/main.ts` 的对象菜单、弹窗与推送默认 remote；`web/dialog.ts` 的按钮/字段；`src/config.ts` 默认值；`src/dataSource.ts` argv、条件 Squash Commit；**`src/gitGraphView.ts` 多步执行顺序**；`src/utils.ts` Archive、历史 Rename/打开；`web/graph.ts` Drop 拓扑；`src/types.ts` 消息对象种类 |
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
| `GitPanel.presentGitNameDialog` | 通过全局 key/mainWindow 挑窗口；`TerminalManager.window` 是 private，公开当前入口为 `attachedWindow`；Model 没有 Project ID | `ToolPanelView` 注入发起窗口/Project 与已有 PanelContext 身份，不只在确认时读取当前 Model |
| `GitStatusModel.createReference/perform/runGitStatus` | 排他执行、仓库/HEAD/branch/可选 upstream 与代次已有，但只有静态 argv 和 Bool completion；没有所选本地 Ref、Stash 或条件多步结果 | 在唯一 perform 最小补齐条件结果与对象预检；不可变 SHA 创建/读取不套全局 HEAD 或 worktree 守卫，不另建 workflow DSL |
| `GitStatusModel.repositoryOperation` | 已识别 Merge/Cherry-pick/Revert/Rebase/Bisect 标记，并在 Banner 提示终端恢复 | **无需新状态机**；Git Graph 菜单自身没有 Continue/Abort/Skip GUI，使用既有原生终端实测恢复 |
| `GitCommandExecution.runData`、`WorkspaceBackend.run/read` | stdoutLimit 会截断但保留 exit 0；SSH runner 先无界收集 stdout，read 的多读一字节才严格拒绝超限；LocalWorkspaceBackend.run 要绝对 executable 且不加载 Git 登录环境 | GitCommandExecution 生成临时归档，SSH 才有界读取到 Mac，本机磁盘保存无需内存上限；不写容器解析器或新传输协议；断线清理失败不能假报已清理 |
| `Project.newSession/makeSession` → `TerminalSession.init/makeLaunchScript` | pinned SSH 丢 directory；自动跟随 SSH 的 Project（sshHost=nil）开本机 Shell；sendCommand 不证明远端 ready，launchCommand 是已有执行入口 | T2 在新 PTY 的启动链绑定捕获机器/仓库及真正交互命令，不新造 OSC 等待器或 fallback；目标选择变化不落回 Mac |
| `Project.openCommitDiff/findDiffTab` → `DiffTab` → `DiffViewerView/DiffNativeSurface` | Key 缺来源；No Changes 会隐藏原文；commitHash 非 nil 不会选中刷新；gitContent 所有错误均当 missing | T6 一次接通来源、只读原文、worktree 刷新和真实失败；Rename 按上游一次 Revision→Worktree diff，不建历史索引 |
| `TerminalManager.contentSnapshot` → `SessionStore.ContentSnapshot` → `Project.makeContent` | 当前持久化明确区分 diff/commitDiff，新来源若不接入会恢复成错误历史 Diff | T6 同任务维护当前模式及实际内容恢复；无旧版本兼容 decoder/迁移层，不破坏当前仍支持的工作区和历史快照业务 |
| `Project.saveBeforeClosing/confirmCloseUnsaved` | 等待/提示保存后会 removeTab，不是通用 Git 覆写前置保护 | T1 直接复用 PaneContent.save 等待/复查，不关闭 Tab；失败保留缓冲，后续写工作区动作复用同一入口 |
| `PanelSectionHeader.body`、`GitPanel.changedFileRows` | header 内已有 contextMenu，actions 也生成 hover 按钮；目录没有批量菜单，循环单文件执行会被 isBusy 拒绝 | T7 增加同一菜单的仅菜单项，目录单批路径集，不套第二 contextMenu 或增加平行 toolbar |
| `Project.openFile` → `FileTab` → `SourceTextEditor.Coordinator` | 同一路径复用 FileTab；文本 `file.text` 被 `@ObservationIgnored`，原生 STTextView 持有另一个显示缓冲；SSH FileTab 初始 `.loading`，`save()` 是唯一串行保存路径 | Ignore 应等文本真正读入后通过**同一个原生编辑缓冲**追加并保存；不可直接改 `file.text` 或 Backend 偷写，否则 UI/undo/未保存修改会分裂 |

## 已复现的关键 Git 边界

- **Stash OID 与 selector 不等价：** Apply OID 可用，Pop/Drop OID 会被拒；Branch 使用 selector 成功时也可能删除该条 stash，改传 OID 会丢失移除语义。Pop/Drop/Branch 都持有 selector+OID 并执行前核对，不宣称预检是外部 CLI 原子锁。
- **远端 Ref 删除与 lease 不是同一产品行为：** 上游 deleteRemoteBranch/deleteTag 是按名字原生 Push Delete，并尊重服务器拒绝。之前临时 bare remote 证明 exact-OID lease 可拒绝已移动 tip，只是 Git 能力实验，**不构成 P4 必须增加此围栏的依据**；本轮删除该计划前提。Force With Lease 的 Push 模式依旧按用户选择保留，不预先 Fetch 冲掉其基线；Kero 不修改任何用户服务器保护配置。
- **多远端并非同一种停止规则：** `gitGraphView.ts.deleteBranch` 先本地删除，成功后逐个尝试全部列出的 remote；`dataSource.pushBranchToMultipleRemotes/pushTag` 首错停止。默认 remote 由 `web/main.ts.getPushRemote` 决定，Delete on Remotes 是一个复选而非任意多选，详见计划合同。
- **本轮隔离实证（2026-10-14）：** 临时 A→B→C 库 Drop B，Tag keep-B OID 未变；FF 的 merge --no-commit 前移 HEAD；Squash 有 staged 才 Commit，默认消息采用上游 actionOn，二次无差异不空提交；Reset Hard 保留 ordinary-untracked，却删掉阻挡 tracked 文件的 untracked 目录；空 Annotated message 显式 `-m ""` 可创建；selected SHA 的 ZIP 内容准确。原始输出来自本轮临时库，不是 App/SSH 验收。Drop 的用户 `rebase.updateRefs` 配置边界已用 [Git 官方契约](https://git-scm.com/docs/git-rebase)核对。
- **风险来自用户目标，不来自按钮名称：** Soft/Mixed/Hard Reset 对 HEAD、index、worktree 的效果不同；Drop 会重放后续提交而非做 Revert；Tag 是 Annotated Object 时不能混用 Tag Object OID 和 peeled Commit；SSH 同名路径不得回退写 Mac；历史 File Reset 会同时改 index 与 worktree，不能覆盖未保存编辑。
- **测试证据分层：** `GitStatusModelTests` / `GitExecutionTests` 的临时仓库需核对真实 refs/index/worktree；`RecentCommitsViewTests` / `DiffTabTests` 验证原生菜单、显示与 Tab；独立 App E2E 和经批准的 Windows SSH 专用测试仍是单独关口。Issue #2 的 SSH 外部刷新仍未实测，不因 P4 菜单完成而关闭。
