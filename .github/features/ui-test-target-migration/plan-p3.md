# Plan P3 — Git Changes、历史文件、操作表单与 Git Graph

**Goal:** 完整核销 Git 原生界面的 **102 个旧测试方法**：`GitHistoryFileTests` 21、`GitWorkspaceMenuTests` 11、`GitExternalRefreshTests` 4、七个 Git 表单／操作类合计 18、`RecentCommitsViewTests` 48；业务命令与失败语义留在 Unit/Integration，真实用户操作归 `BaileyUITests`。

**Non-goals:** 不改 Git 图谱视觉、拓扑、标签、菜单选项或仓库操作语义；不以迁移测试为由实现新的 Git 功能、重新引入 Vision OCR，或访问真实用户仓库/SSH 凭据。

**Approach:** 复用现有 `WorkspaceUITestFixture.git(_:)`、独立 CI GUI Runner 和 `WorkspaceGitUITests`。每条旧测试在本任务中拆为用户操作或 Git/状态逻辑，验证真实临时仓库的前置状态与操作后的磁盘、index、HEAD、refs；完成后立即删除相关旧宿主测试、专用 helper、失效文档/CI 引用。不新建统一 Git fixture 框架。

**Acceptance:**
- 102 个旧方法逐项有可追溯替代断言及执行证据；四项任务分别移除负责的旧类，避免原生 View 测试和 App UI Test 长期重复。
- Git Changes/Graph 的同一共享树模型在键盘、鼠标、菜单、分组展开、不同布局宽度、浅/深主题中一致；Git 历史文件不被误写，所有改变仓库的操作只作用于真实选择的 fixture 仓库。
- 对取消、仓库/HEAD/索引变化、超时、SSH 断线等原来保护的失败条件，有 UI 可见结果和非 UI 后端不变量双重证据；不能只确认原生按钮可点击。
- 有完备的安全 fixture 校验，禁止 stage/clean/reset/rebase 对非测试文件执行。

**Rules:** 用户真实存储、真实 Git 工作树及 SSH Host 不作为测试夹具；影响的文档 owner 是 `docs/features/git.md`、`docs/features/diff.md`、`docs/ui.md`、`docs/testing.md`。不将菜单截图/OCR 结果作为 Git 图谱语义的唯一依据。

---

<a id="p3-t1"></a>

## P3-T1 历史版本文件、Git revision 和安全重置

**Own old tests:** `BaileyTests/NativeUI/Git/GitHistoryFileTests.swift`（21）。

**Files/anchors:** `Bailey/Git/{GitHistoricalFileLocator,GitStatusModel,GitPanel,DiffViewerView}.swift`、`Bailey/Workspace/PaneTab.swift`，`BaileyTests/Integration/Git/{GitExecutionTests,GitStatusModelTests}.swift`；UI 目标 `BaileyUITests/Git/GitHistoryUITests.swift`。

**Step 1 — 原有保障按可观察性拆分：**
- UI: 点击不同历史提交、只读 revision、重命名关联、预览不切离 Git、显式激活编辑器、Diff 模式切换与恢复、历史二进制/超大文件提示、选中 revision 失效后的错误、重置文件的确认／取消/关闭、变更成功后的现有标签与脏文本如何处理。
- 纯 Git/后端：revision → blob 的定位、stage 2 冲突与 stage 0 缺失、unborn/dangling HEAD、SHA-1/SHA-256、5 MiB 读取边界、特殊路径／原始内容、index mutation 期间的不可变对象、外部 repo/ref 变化、save-before-reset 与 stale-revision 拒绝。
- 危险操作只针对 `WorkspaceUITestFixture` 在独立临时目录内创建的 Git 仓库，并用 `rev-parse`、`ls-files`、`status`/实际冲突阶段验证前置条件；无效 fixture 必须失败而不是跳过。已有用户 Git 工作树和 SSH 连接不参与测试。

**Step 2 — 新真实 UI 与非 UI 保障：**
- 在 `BaileyUITests/Git` 从 Git Graph 展开真实提交打开历史文件/Diff，确认只读区域不能修改历史 blob；从 GUI 执行有确认的文件恢复，核对磁盘 bytes、暂存 index 和 HEAD 不会修改未选择内容。
- 以集成测试维持 Git 操作的精确错误、重新定位、sha256 和二进制长度极限；不让 E2E 依赖 App 隐私内部指针。
- 全部 21 项对应的有效性证据建立后删旧 `GitHistoryFileTests.swift` 与原有测试-only 本地 Window helper，并更新 `docs/features/git.md`／`diff.md` 相关验证入口。

**Step 3 — 验证：**
- 独立 GUI Runner 的历史文件 UI 路径；`make test:GitStatusModelTests,GitExecutionTests` 等非 UI 回归，在原始/修改后的 Git index、HEAD、worktree bytes 上断言一致性。
- Coverage：空/未提交 HEAD、merge/conflict index、重命名/删除/二进制、大于和等于 5 MiB、SHA-256（事先核对可用 Git 版本）、Unicode／空格／通配符路径、Git 操作前后再次编辑、确认途中 index/ref/worktree 改变、失败/取消/重试、本机和获准 SSH、跨窗口/项目；所有安全可执行的已知状态逐项验收。
- Uncovered：SSH 实机未获授权或 SHA-256 Git 版本不支持时保留对应非 UI 工具/模型证据并标注 UI Gate 影响，不能悄悄 skip。
- **Commit boundary:** 历史文件 UI、纯 Git 模型补验、旧 21 项逐方法核销、旧类删除与文档。

<a id="p3-t2"></a>

## P3-T2 Git Changes 交互、外部刷新、菜单与工作树操作

**Own old tests:** `BaileyTests/NativeUI/Git/GitWorkspaceMenuTests.swift`（11）和 `GitExternalRefreshTests.swift`（4），合计 15。

**Files/anchors:** `Bailey/Git/{GitPanel,GitStatusModel,GitFileEventWatcher,GitUncommittedDialog}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`；扩展 `BaileyUITests/Git/WorkspaceGitUITests.swift`，非 UI 逻辑继续 `BaileyTests/Integration/Git/{GitUncommittedActionTests,GitStatusModelTests,GitWorkspaceActionTests}.swift`。

**Step 1 — 真实数据与 UI 场景：**
- 未初始化 → 初始化、外部两次变更 → 可见 Git 列表更新；已有／无变化、远端状态慢返回、当前窗口失活/切项目时刷新和身份许可。
- Changes 树与文件夹、Space/Return、上下行、点击、预览、展开、Diff index side；stage/unstage 单文件/文件夹、ignore .gitignore 多种字符与 CRLF、undo/脏缓冲保存、不允许旧 repo 的滞后点击改新仓库。
- Uncommitted Reset／Clean／Stash 菜单的默认项、警告、取消、确认、包含未跟踪目录的不可恢复删除**只对唯一临时目录生效**；先检查 git status 与 fixture path，不操作用户工作树。

**Step 2 — 实现与清理：**
- 在真实应用中从加项目进入 Git 面板，经点击/键盘/菜单执行，观察变更数、选中行、Diff 和实际 index/磁盘；外部变更通过在 fixture 路径运行 Git 命令触发 watcher，不用直接调用 `model.refresh()` 冒充事件链。
- 对纯 Git 行状态、失败、过期身份、缓存、目录过滤及网络慢返回归入非 UI 集成测试。维护 Git Graph 的本地和 SSH 差异，未经授权不借真实 SSH master。
- 15 条逐方法覆核后删除两个旧测试文件与无用 NSWindow fixture，更新 `docs/features/git.md`、`docs/features/files.md` 里受影响的验证入口。

**Step 3 — 验证：**
- 真实 UI Git Changes 点击/键盘/菜单路径，外部 Git 变更前后 `git status --porcelain=v1`／`git ls-files -s`／.gitignore 字节，非 UI watcher/event/status 测试与 `make test:GitStatusModelTests,GitUncommittedActionTests`。
- Coverage：未 init、空 repo、无/多文件／目录嵌套、stage/unstage/merge conflict、staged 和 unstaged 同时、Unicode/special path、工作树新建/删除/忽略、二次外部变更、延迟/失败 Git 后端、远端响应乱序、窗口/项目切换、取消/确认、不可撤销 clean 风险和真实提交结果。
- Uncovered：获准 SSH 服务不可用时先用既有测试验证后端并记录真实远端 Git Graph/Changes 缺口；失败需保留旧方法直到补证。
- **Commit boundary:** 文件树和菜单 UI + 后端事件测试 + 旧 15 项核销/源删除 + 文档。

<a id="p3-t3"></a>

## P3-T3 Git 原生对话框、危险操作、交互 rebase

**Own old tests:** `GitBranchDialogTests`（4）、`GitCommitDialogTests`（3）、`GitInteractiveRebaseTests`（3）、`GitRefReplacementTests`（1）、`GitRemoteBranchDialogTests`（1）、`GitStashDialogTests`（2）、`GitTagDialogTests`（4），合计 18 方法。

**Files/anchors:** `Bailey/Git/{GitBranchDialog,GitCommitDialog,GitStashDialog,GitTagDialog,GitPanel,GitStatusModel}.swift`，SSH interactive rebase 的 `Bailey/Remote/BaileySSHBridge.swift` 与既有 backend；UI 目标 `BaileyUITests/Git/GitActionsUITests.swift`／`GitDialogUITests.swift`，纯 Git 命令继续 `BaileyTests/Integration/Git/{GitBranchActionTests,GitCommitActionTests,GitRemoteBranchActionTests,GitStashActionTests,GitTagActionTests}.swift`。

**Step 1 — 原始 UI/后端结果：**
- 表单字段、默认项、禁用态、用户改后切选项保留、关闭/取消后的无副作用；branch create/rename/delete/checkout/push、远端 Fetch/Pull、tag create/rename/delete/push、stash pop/apply/branch、Commit message/mainline/amend/未暂存的选项和同步。
- 操作确认途中 HEAD/ref/index、选中 repository/project、窗口/Sheet 所属权变动后的过期目标拒绝，网络慢响应和错误提示；`git rebase -i` 原生终端／PTY 的实际编辑器输入与生命周期。危险默认项必须是用户可见且可取消，不只断言 model flag。
- **已确认混合边界**：`GitInteractiveRebaseTests.testSSHHelperHandoffUsesTheRebaseFixturesApplication` 实际操作 `BaileySSHSocketServer.exchange`、`BAILEY_SSH_SOCKET`/token 与 `TerminalNotificationService` 服务所有权，并没有真正的 App UI 操作；它必须完整移入 `BaileyTests/Integration/Remote` 或对应非 UI 集成类，不可以因为旧路径叫 `NativeUI` 就删除。该类另外两条测试也要先拆分真实 PTY/SSH/命令结果与界面入口各自的验证，不强造只有 UI 可测的结论。
- 外网 remote push/fetch/pull 用**受控本地 bare remote 或获准临时测试 remote**，绝不向用户 GitHub 仓库直接执行写入；SSH 重连/认证不借真实用户 master/凭据。

**Step 2 — 实现与清理：**
- 以完整 App 的 Git Graph、Changes 右键/菜单和原生 Sheet 作为入口，通过 `XCUIApplication` 查询实际字段和操作，确认工作树与 bare remote 的 refs/index/HEAD 最终状态；交互 rebase 在独立 Runner 可测范围内执行并核对提交序列，而不是直接调 dialog callback。
- 将 ref 等值/规范路径/安全策略、错过期拒绝、复用数据模型与 Git command 移入或保留非 UI 单元／集成测试；只在所用的真实控件确有 AX 欠缺时补稳定语义，不生成假 dialog。
- 逐项核销 18 条后在本任务移除对应七个旧测试文件和 window/menu 夹具，同步 `docs/features/git.md`、`docs/ui.md` 的验证入口，保留产品默认行为。

**Step 3 — 验证：**
- 专用 GUI Runner 的表单输入、取消、确认、Sheet 跨窗归属、错误恢复与实际 Git 可读结果；并用 `make test:GitBranchActionTests,GitCommitActionTests,GitRemoteBranchActionTests,GitStashActionTests,GitTagActionTests` 定点跑底层测试。
- Coverage：空／非法／Unicode／长名称、失效 ref、无 remote／配置多个 remote、fast-forward/force、空 index/merge parent/unborn、stash 多项选择与索引移动、双项目／双窗口混合触发、断线/失败/取消/重试、PTY 输入/EOF、Git 签名或 user config 缺失；交叉含 Git 操作前后仓库外部变化。
- Uncovered：不可安全跑的真正外部 SSH/provider 场景必须逐项记录和阻塞程度；本地 bare remote 不冒充互联网实际故障。
- **Commit boundary:** 18 项逐断言迁移、真实 Git UI/E2E 与纯后端、删除七个旧 suite + 更新文档。

<a id="p3-t4"></a>

## P3-T4 Git Graph 全图谱、颜色/标签、键盘与多级菜单

**Own old tests:** `BaileyTests/NativeUI/Git/RecentCommitsViewTests.swift`（48）。

**Files/anchors:** `Bailey/Git/{RecentCommitsView,CommitGraphLayout,GitPanel,GitStatusModel}.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`，`BaileyTests/Unit/Git/CommitGraphLayoutTests.swift`；UI 目标 `BaileyUITests/Git/GitGraphUITests.swift`，可扩展现有 `WorkspaceGitUITests`。

**Step 1 — 对象与原始验证链：**
- 原有 48 项分别包含提交行整体点击/展开、空白/元信息/图谱节点命中、焦点、Space/Return、树子目录和历史文件、提交/文件横滚、历史分页、stash/worktree/uncommitted 结合；不可只添加“提交出现”这一条。
- 合并的 branch/remote/tag/stash 标签、当前 HEAD 和 detached HEAD、默认 remote alias、窄宽展示、更多隐藏引用、worktree 同名目录、pending uncommitted 节点、引用类型菜单/危险操作；颜色要核对相同 branch 在拓扑合并前后的语义，不只看截图文字。
- 12+ lane 的拥挤图、字体缩放、窄侧栏/宽侧栏、浅/深、中文长文案、横滚按钮、菜单多级 hover/popup 与切窗行为，结合 `CommitGraphLayoutTests` 的完整父关系与数据。

**Step 2 — 新 UI 和纯算法双链：**
- 按 48 个旧测试实际需要的拓扑构造**必要的几组最小 Git fixture**：合并、多分支远端、stash、worktree、detached、长目录、密集 lanes 与多页历史；对每组都执行 Git 前置核验，不机械在每条 UI 测试里创建 100+ 提交。算法的 lane/颜色编号由现有 `CommitGraphLayoutTests` 做精确组合检验，UI 只要求真实用户路径呈现/命中正确。
- 通过真实图谱展开/选择、菜单分级、历史文件、滚动与键盘操作验证。当前 `WorkspaceGitUITests` 以 `app.buttons` 的提交信息做整词匹配，不先核对 AX 真实角色与标签，曾出现「找不到提交」；先诊断真实输出再修查询，不能靠延长等待或 UI fixture 切回直接 mock View。颜色/几何由确定的算法 + 可对比实际绘制共同证明，截图不能自动替代精确原生断言。
- 48 项逐方法核销后，**在 P3-T4 当场**移除 `RecentCommitsViewTests.swift` 和该类独占的 `NSHostingView`/鼠标注入/颜色取样 helper；维护其它单元/集成仍消费的 `CommitGraphLayout`、共享树行和安全约束。同步 `docs/features/git.md`、`docs/ui.md`、`docs/testing.md` 中现行回归入口和 CI 实际引用。

**Step 3 — 验证：**
- 专用 Runner XCUITest 的图谱键鼠、菜单和视觉验证 + `make test:CommitGraphLayoutTests,GitStatusModelTests`；输出 Git 仓库状态、实际可见提交和目标文件 Diff/菜单动作，比较明确受控的颜色/尺寸基线。
- Coverage：0/1/多历史、深历史分页、2/12/极端多 lane、branch merge/rename/stash/worktree/ref 冲突、短长哈希、复杂 remote names、图谱展开/折叠/悬停/单击/双击/Space/Return、Tree/List、字体上下限/长中文路径、浅/深、宽窄/横纵滚、菜单上级→子级/取消/重新打开、窗口切换、外部 refs 更新。
- Uncovered：GUI Runner 不支持的真 hover 连续轨迹、不同显示设备/物理触控板逐项列明设备与人工补验；Vision OCR 不作为必要依赖或放行替代物。
- **Commit boundary:** 48 条方法的真实图谱证据与纯拓扑验证、旧类删除、文档同步及完整 GUI 结果。

---

## Phase Audit

实际执行完成 P3 全部 tasks 后由 `executing-plans` 触发 `audit-p3.md`。审核：旧 102 条逐项有去向；危险 Git 操作真实修改的始终是隔离夹具；Git Graph 颜色、拓扑、菜单和可触达性有 App 层结果；历史文件只读与保存保护未退化。缺少真实 SSH / 图像对照 / 复杂菜单证据时不能标全域通过。
