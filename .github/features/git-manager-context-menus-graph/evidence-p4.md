# P4 执行证据

实时状态只由 `todo.toml` 维护。此页区分模型、原生界面与真实机器结果，不把构建或回调等同于 E2E；不沿用旧审计结论。

## P4-T1

- Red：`make test ONLY_TESTING=KeroTests/GitStatusModelTests/testContextChangeDuringMutationPreflightDoesNotSwitchOldRepository`；异步 Git 预检期间切换机器，旧库分支实际变成 `other` 而不是保持 `main`。完整原始日志：`~/Library/Application Support/rtk/tee/1791970983_make_tes_4258da.log`。
- 修复：唯一 `perform` 在准备保存后、异步预检后及每一步副作用前核对既有 generation 与发起目标；Squash 的 staged 检查及条件 Commit 不退出互斥。实际失败 argv、stderr 留在 Operation，不要求 View 解析 transcript。
- `GitCommitActionTests` 6/6：真实临时库证明 Checkout/Root Revert、Cherry-pick -x/NoCommit、Merge 主线、NoFF/FF/Squash/NoCommit、无差异不提交及冲突后 Git abort/continue。不是 PTY 或完整 App E2E。
- `GitCommitDialogTests` 2/2：真实 NSAlert 的字段默认值、父提交选项；Cancel 无副作用、另一窗口 key 不接管 sheet、两个 Project 指向同库时切 Project 拒绝、主按钮实际检出所选 SHA。测试通过 GitPanel 原生呈现入口，不冒称已从右键自动化走完。
- 保存保护直接等待既有 FileTab/DiffTab 写队列，不调用会删 Tab 的关闭 helper；失败、保存期间新编辑与 preflight 期间新编辑回归核对缓冲/HEAD。干净编辑模式 Diff 的原生表面直接重载，不重建、不覆盖 dirty。
- 首轮完整测试 129/129。收尾发现 reset 设置测试会调用共享语言偏好写入；改为可注入的语言 UserDefaults/domain，并只在独立 domain 验证 reset，不把测试隔离错误保留成产品开关。最终完整测试与构建/安装记录待实际完成后追加。
- 清理：全局 key/mainWindow 猜窗口路径、旧 Copy Commit Message 标签已删除；仍被 T3/T5 使用的名称 helper 与轻量 Tag 路径不提前破坏。
- 最终完整 `make test` 130/130；关闭发起窗口及 Always Accept 勾选后实际略过 sheet 的补充 NativeUI 2/2。`make build` 与严格签名 PASS，整包更新 `/Applications/Kero.app`，不启动或重启现有进程；临时原包备份已清理。实现提交 `a5f1c91`，规划文件不入提交，原有暂存 plan 保持原样。

## SSH 条件

- 用户授权已有 `windows` 主机。以 `ControlMaster=no`、`ControlPath=none`、BatchMode 与严格 host-key 验证只读探测；未借用已有 master。
- 实机回答：`MSYS_NT-10.0-19045`，`/c/Users/Administrator`，`/usr/bin/git`，Git 2.56.0。此探测不是 P4 SSH 操作验收；后续只创建测试临时库和独立连接。

## P4-T2（本轮验收）

- 拓扑 Red→Green：Root、Merge、子分叉、当前 HEAD/未知 HEAD、HEAD 后的单子/合并路径；规则不读取 Ref 数量，不额外禁止 Tag 或同节点 Ref。首次 Drop 副作用前另读真实可达拓扑，不能用分页缺节点证明安全。
- 隔离 Git 测试已覆盖 Reset 三层及 Hard 删除 untracked 阻挡、后台 Rebase、Drop 与 detached HEAD。更新引用测试最初错误地期望被排除的 upstream（被删除节点）上的 Branch 也会移到父节点；真实 Git 不这样做。修正为检查实际被重放的中间 Commit 的 Branch，并保留 Tag/remote Ref 验证，未为错误断言改变实现。
- 源码续追确认普通 SSH 带 command 不握手。首个显式环境项路线虽然握手，但复杂 remote command 在 Windows 上真实 parse error，编辑器从未就绪；错误退出还会自动关掉标签，不能查看结果。已停止并删除该路线，不保留兼容或兜底；未修改 Windows wrapper、sshd 或用户配置。
- 当前路线：原 helper 普通登录，新连接拥有独立 socket，Ghostty `input` 一次发送已转义的目标 cwd/命令；现有 SDK `withCustom` 和 1.3.2 引擎实际支持该原生能力。本机 PTY 测试真实等待序列编辑器输入并改写 HEAD，终端保留。Windows NativeUI/真实 SSH 测试在固定主机与自动项目两路均通过（57.244 秒），核对实际 cwd、TTY、HEAD/两分支文件、不同控制 socket 和无本机 backend。自动项目的起始连接元数据是测试拥有的连接，不冒称完整 App 手动 SSH E2E。
- Windows 验证入口：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test ONLY_TESTING=KeroTests/GitInteractiveRebaseTests/testAuthorizedSSHInteractiveRebaseUsesIndependentHandshakeForPinnedAndAutomaticProjects`。原始日志 `~/Library/Application Support/rtk/tee/1791977590_make_tes_2986c0.log`。远端测试仓库和本测试 source master 在用例成功/失败路径都清理，用户 master 未使用。
- 第二个 Red：把 Project 的 Git 根重新查询作为预检，误拒绝了本机原生检出（日志 `1791975634_make_tes_751a89.log`）。删除这条额外查询；在唯一 GitStatusModel 记录已解析的 PanelContext 身份，新目标解析立即失效旧 generation，未解析快照不允许动作。原生回归恢复 Green；补充切不同仓库及切走再切回不会恢复旧确认，属于 T1 目标绑定的补充修复。
- Windows 额外只读探测：Shell 为 `/usr/local/bin/openssh-zsh-v3.exe`，可调用 `/usr/bin/zsh -ic`。单次空 Git 探测库 `/tmp/kero-p4-Qulkrt`（远端）的单/双引号 Git root 查询均回答相同实际根，不把过去版本的 quoting 假设写成当前缺陷；该临时库已按确切路径清理。只读查看了现有 wrapper 源码，未改服务器。
- 接手后复验（2026-10-14）：完整 `make test` **140 项、0 失败、1 跳过**（未指定专用 SSH 测试主机），日志 `/tmp/kero-handoff-p4t2-test.log`；`make build`、Debug 严格验签通过，日志 `/tmp/kero-handoff-p4t2-build.log`。
- 真实 Windows SSH 专用测试第一次复跑在 pinned=true 完成后、**pinned=false 的 Git fixture 准备阶段**超时，随后使用同一测试 backend 清理也超时。失败日志 `/tmp/kero-handoff-p4t2-ssh.log`；故不能声称自动项目实际 Rebase 失败。使用不借用用户 SSH master 的新连接确认主机正常，再用隔离短期 ControlPath 连续 4 次验证连接复用正常；仅删除该次测试遗留的远端临时目录 `/tmp/kero-p4-ssh-scntw3`（事先确认目录归属、无进程及没有符号链接），未改用户 SSH 配置。
- 第二次真实 Windows SSH 测试 **通过（44.278 秒）**，涵盖 pinned 与 automatic 两种项目、新独立控制 socket、真实目标目录、交互式编辑器等待及最终 HEAD/文件核对。日志 `/tmp/kero-handoff-p4t2-ssh-repeat.log`。首次一次性超时原因暂未证实为产品缺陷，保留该事实；不以盲目重试遮盖。

## P4-T3（本地分支与 Archive）

- 源码执行链：`RecentCommitsView` 本地 Branch/`+N` 菜单 → 发起窗口的 `GitPanel.presentBranchAction`/`GitBranchDialog` → 唯一 `GitStatusModel.perform`（原有互斥、仓库/机器/选中 Ref OID 校验、Git argv）→ 本机登录环境/所选 SSH backend。旧 P2 `createReference(.branch)` 已删除，现存 `createLightweightTag` 明确归 P4-T5 替换；文件编辑保护继续复用 `Project.saveBeforeGitAction` 与 `reloadAfterGitAction`。
- 隔离真实 Git：历史与顶部 Branch 创建/替换，Rename 不覆盖，安全/Force Delete，非 HEAD 定向 Push；至少 3 个 bare remotes 的中途服务器拒绝与部分删除成功，Normal、Force With Lease、Force、多个远端默认上游和末次成功 upstream；ZIP/TAR 实际条目和原始字节。模拟 SSH backend 证明有界读取、超 64 MiB 拒绝不破坏已有目标、远端临时清理失败准确报告路径；**不冒称已从真实 Windows SSH GUI 导出 Archive**。
- 后续补足 T3 核对：服务器上目标 Branch 已消失时，不需要另外创建本地 ref 清理执行器；临时 bare remote 的真实 `push --delete` 已清除**相应**的 remote-tracking ref，而另一 remote 同名 ref 仍在。首个 Push 被拒时后续 remote 仍未写入；前导 `-` 分支名被 Git 校验拒绝；另一个 worktree 检出的 Branch 不被 `branch -f` 强制覆写。这三项回归最终进入同一个 `GitBranchActionTests`。没有为了初始静态猜测保留无用 fallback。
- 原生 `GitBranchDialogTests` 验证 Name/Check out、Rename、Force Delete 默认关闭、Set Upstream 默认开启、Push Mode 默认 Normal、Remote 多选、全部取消选择时主按钮禁用；无 remote 时面板显示明确原因且不能提交，不再空点击。整套 Kero 内嵌右键、系统 NSSavePanel 手动操作及真正 SSH Archive 下载的 E2E 仍归 P4-T9；低层成功不等于这些用户路径已验收。
- 原始验证：`/tmp/kero-p4t3-deep3.log`（初期 8 项）、`/tmp/kero-p4t3-remote-fixture.log`（9 项）、`/tmp/kero-p4t3-missingref-red-20261014.log`（追加 12 项，实际均 Green）、`/tmp/kero-p4t3-complete-20261014.log`（151 项、0 失败、1 个真实 SSH 环境跳过），`/tmp/kero-p4t3-complete-build-20261014.log`（Debug 构建、严格验签 PASS）。追加边界验证后 `/tmp/kero-p4t3-final-154-20261014.log` 完整 154 项、0 失败、1 环境跳过；最终修复无 remote 空点击后，`/tmp/kero-p4t3-final-155-20261014.log` **155 项、0 失败、1 环境跳过**，`GitBranchActionTests` 12/12、`GitBranchDialogTests` 3/3。最终独立 Debug `make build` 以 `/tmp/kero-p4t3-final-build-20261014.log` 为准。

## P4-T4（远端分支操作与真实 SSH 回归）

- 新增 `GitRemoteBranchActionTests` 13 项真实临时 Git + 多 bare remote 回归：最长已配置 remote 名称前缀、符号 `origin/HEAD` 对比真实名为 `HEAD` 的 Branch、Checkout tracking / 本地同名分流、Fetch/Force Fetch/其它 worktree 拒绝、Merge 和 Pull No-FF/Squash、选中 Ref 变更拒绝、部分 Checkout 后 Pull 失败、远端不存在时只清理同 remote tracking，以及服务器保护策略拒绝仍保留引用。每项核对 Git 的 refs/HEAD/index/worktree，不是只测 argv。
- 直显和 `+N` Remote Branch Badge 都接入同一原生菜单。原生 `GitBranchDialogTests` 核对 Checkout 名称、Force Fetch 默认 off、Pull No-FF/Squash 默认 off。原生集成的真实右键→窗口操作和完整 SSH Remote Branch E2E 仍需 P4-T9 单独验收，不用 fixture 冒充。
- **拒绝跳过真实 SSH**：普通 `make test` 不设置 `KERO_P4_TEST_SSH_HOST` 会按测试源码产生 1 skipped；本轮使用 `KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test` 完整执行，专用 Windows 主机经独立严格 host-key 的 SSH 连接确认。真实 `GitInteractiveRebaseTests` pinned/automatic 均在 Windows 临时 repo 验证 TTY、编辑器与 Git HEAD；该项在最终完整回归中 **passed（68.810 秒）**，不借用已有用户 SSH master。单项实机先前也在 `/tmp/kero-p4-ssh-required-20261014.log` 通过（46.883 秒）。
- 首次带真实 SSH 的完整回归 `/tmp/kero-p4-full-ssh-no-skip-20261014.log`：169 项、0 skipped，但 `GitExternalRefreshTests` 的提交刷新等候超时，导致 2 条失败。独立该类 2/2 通过。第二次全量 `/tmp/kero-p4-full-diagnostic-ssh-20261014.log`：169 项、0 skipped，Git 外部刷新与 Windows SSH 均通过，但 `WorkspaceWindowCloseTests` 旧宿主 release 断言超时。独立重现诊断 `/tmp/kero-windowclose-diagnostic-20261014.log` 明确：旧 SwiftUI NSHostingView 仍被保留，而新宿主、当前 NSWindowDelegate 和 TerminalManager 窗口身份**都正确**。
- 因此没有修改生产 Git 轮询或靠提高 6 秒门限掩盖失败。独立修复测试生命周期错误的提交 `a6f28be`：Git 刷新窗口改用真正可成为 Key Window 的原生类型；窗口关闭测试验证新宿主/Delegate 接管和最终保存/关闭，不对 SwiftUI deinit 时序强作保证。修正后单项 `WorkspaceWindowCloseTests` 1/1 与 `GitExternalRefreshTests` 2/2 均通过。
- **最终正式全量结果**：`/tmp/kero-p4-t4-verified-full-windows-20261014.log`，**169/169、0 失败、0 跳过**，含真实 Windows SSH 和 P4-T4 的 13 项集成测试；`/tmp/kero-p4-t4-verified-build-20261014.log` 对应 `make build`、严格 `codesign --verify --deep --strict` PASS。此前失败日志保留作为历史依据，不谎称它们通过。已明确区分真实 SSH 交互式 Rebase 的 E2E 与待 P4-T9 核对的 Remote Branch 完整 UI/SSH E2E。

## P4-T5（Tag 创建、详情、删除、Push、归档）

- 原代码仅在 Commit 上用单个名称输入框创建轻量 Tag，Tag Badge 只提供 Show Commit/Copy。现统一到 `GitTagDialog` 的原生 Add Tag（默认 Annotated，说明可空，切换类型不清空说明、单/多远端可选）、Delete（默认本地，仅明确选择一个远端才删服务器）、Push（单/多远端选择、默认正常）、Tag Details（含签名校验、只读可复制全文）与共享 Archive；直显 Badge 和 `+N` 调相同菜单。旧 `presentGitNameDialog`、`presentCreateReferenceDialog` 与 `CommitReferenceKind` 兼容路径在本 task 删除，不新建另一个 Git 执行器。
- 测试根因：原 `testTagDeleteRemoteFirstAndPreservesLocalWhenRemoteRejects` 认为 `receive.denyDeletes=true` 拒绝 Tag 删除。隔离真实 bare remote 实测该配置**仍允许 Tag 删除**；手写到 `hooks/pre-receive` 的测试 Hook 又被用户全局 `core.hooksPath` 覆盖。此测试修复为在**测试 bare repo 自身**显式 `core.hooksPath`，由临时 Hook 确实拒绝 refs/tags 删除，确认失败时 Tag 的本地、远端对象均存在；解除测试 Hook 再删除，双方 refs 均不存在。并未为错误测试假设改变产品逻辑。原失败 `/tmp/kero-p4t5-tag-model-test-20261014.log`，修后通过 `/tmp/kero-p4t5-tag-delete-green-20261015.log`。
- 真实临时 Git `GitTagActionTests` **7/7**：Annotated/Lightweight 与创建附注、Replace 但保护其它 Tags、两端远端删除顺序与拒绝、Push 首错停止、不调用 Fetch 的远端可达启发式、创建后立刻用实际新 Tag object OID 推送、从较老 Annotated Tag 导出的 ZIP 不混入当前 HEAD 新文件，以及临时生成的 SSH 签名 Tag 缺可信 allowedSignersFile 时标明 `unverified` 而非 `valid`。`GitTagDialogTests` **3/3**：原生默认值、类型切换保留文本、重名后输入保留、单多远端选择和无远端禁用。独立的 `AppSettingsTests` 还覆盖 `git.always-proceed-push-tag` 默认/保存/重置，与 Checkout consent 独立。
- **含真实 Windows SSH 的完整 XCTest 本轮通过**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，日志 `/tmp/kero-p4t5-full-windows-20261015.log`，**179/179、0 失败、0 跳过**；SSH pinned/automatic 专用案例通过（34.334 秒）。`make build` 通过且严格签名，日志 `/tmp/kero-p4t5-build-20261015.log`。`/Applications/Kero.app` 已整包安全替换并重新验签/校验二进制 SHA256 `6aa389b1f7fd93aa9a6d1eec1b3d88bbd00ae28a3716435be4194a2eb0a4d52d`，现有 Kero PID 69689 未退出也未重启。
- 边界：SSH 这次验证的是**真实 Windows Interactive Rebase**，Tag 部分证明了真实临时 bare remote Git 副作用与原生弹窗组件，Tag 完整用户右键→确认→真正 Windows remote 的 App E2E 仍须在 P4-T9 单独验收；不能用上述 179/179 冒充已完全部 E2E。

## P4-T6（历史文件右键、只读版本、比较和 Reset）

- 接手现场只有部分 `DiffTab.Source`、历史 Rename 定位器和新测试，尚未迁移 `DiffTab.reload`、`Project.openCommitDiff`、`SessionStore`、`RecentCommitsView` 的菜单与真正 Git 写入口；初始 `make test ONLY_TESTING=KeroTests/GitHistoryFileTests` 证实缺 `commitHash/staged` 编译错误，不把前人的计划记录当作已实现。
- 同 task 源码真源清理：删除 `DiffTab.staged/commitHash/commitParentHash/commitStatus` 等散落 optional/Bool 状态，使用一份 `Source` 区分 `.worktree/.staged/.commit/.revision/.revisionWorktree`。`Project.findDiffTab` 根据来源区分标签，`SessionStore.ContentSnapshot.diff` 直接保存 Codable Source 并恢复；只读历史原文使用同一 TextKit 表面而不是把全部行染成新增。
- 根因复现：`git diff --find-renames` 用提交与**已被工作区修改**的文件比较时，可能因相似度下降无法确认 Rename。现在优先查询提交→worktree，查不到时按需查询提交→HEAD 的已提交 Rename，最后核对远端／本地 backend 中新路径真实存在，不预建全历史索引。相关真实 Git/native test 已通过。
- 历史文件右键沿 `RecentCommitsView` 单行菜单绑定来源窗口/仓库，打开工作区文件只使用当前 Project/backend；Reset 通过原生 NSAlert 明确 SHA、路径和 index/worktree 覆写，再经唯一 `GitStatusModel.perform` 执行 `git --literal-pathspecs checkout <SHA> -- <path>`；额外校验确认前捕获的该文件 index+worktree blob OID，外部 CLI 修改后拒绝过期确认。二进制 Git 恢复真实字节，不错误要求可显示 UTF-8。
- 仅在用户展开历史 Commit 时一次读取该提交的 Git `--numstat -z`：按 NUL 解码重命名、二进制状态；已知二进制的历史行禁用文本查看/比较，不禁用 Reset。状态属于既有 GitStatusModel，仓库切换即失效，SSH 不按文件逐个请求。
- 专项 `GitHistoryFileTests` 已由初期编译 Red 走到 8/8 Green（`/tmp/kero-t6-binarymetadata-test.log`）：原生只读／空文件／5MiB／二进制、Root/Deleted、历史重命名与动态工作区刷新、SessionStore 三模式还原、Reset 二进制 index/worktree 与 HEAD 不变、过期内容拒绝、展开后二进制 Rename 元数据。一手失败日志 `/tmp/kero-t6-takeover-red.log`、`/tmp/kero-t6-rename-fix.log` 均保留，不谎称最初通过。
- 第一次全量（`/tmp/kero-p4t6-full-realssh.log`）实际执行 187 项（含 Windows SSH），唯一失败是 `DiffTabTests` 旧的未跟踪符号链接读取：Git 对索引和 HEAD 都返回“在磁盘上存在，但不在相应 Git 对象中”，新实现当成真实读取失败而清空 symlink 显示。独立临时 Git 仓库复现四种 Stage/HEAD 不存在语义，修复 `DiffTab.gitContent` 的严格 missing 分类，未吞掉网络/权限读取错误；专项回归 `/tmp/kero-p4t6-symlink-regression.log` 转绿。保留失败日志，不把第一次测试冒称通过。
- **最终全部验收**：`KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test`，日志 `/tmp/kero-p4t6-verified-full-ssh.log`，**187/187，0 失败，0 跳过**；Windows pinned/automatic 实际交互式 Rebase 用例通过（28.477 秒），GitHistoryFileTests 8/8、DiffTabTests 16/16、SessionStoreTests 6/6 均通过。`make doctor` 通过，日志 `/tmp/kero-p4t6-doctor.log`；构建日志 `/tmp/kero-p4t6-verified-build.log` 记录独立 Build 和严格签名。T6 的完整鼠标右键、保存对话框和真正远端文件恢复仍归 T9 实机 E2E，不能用上述 lower-layer/NativeUI 部件测试冒充。
