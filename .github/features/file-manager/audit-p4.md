# Audit P4 - file-manager

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md#p4-t1`，本轮仅 P4-T1；P4-T2 未审查。
- feature 目录：`.github/features/file-manager/`
- 粒度：`phase`（同一个 `audit-p4.md`；本轮先记录 P4-T1 的部分审计，不预判 P4-T2）
- 审计基准：2026-10-26，原任务提交 `dff9512`、相关修复 `5735cbf`；本轮修复提交 `bdbcafe`。#40 事件化提交仅作为现行依赖，不冒充 P4 原提交。

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。以下 `[x]` 只代表任务原执行标记，不代表审计放行。

- [x] P4-T1 外部变更后选择与快速打开一致性
- [ ] P4-T2 全入口 E2E 与 Issue #40 集成验收

## 任务到文件的映射

- **P4-T1**（`dff9512`；同一行为后续受 `5735cbf`、#40 事件刷新提交影响）
  - `Bailey/UI/Panels/ToolPanelView.swift`：`PanelSyncQueue`、`syncModels`、`performSync`、SSH 连接通知，以及本机/远端监听的可见性。
  - `Bailey/Workspace/Project.swift`、`PanelContext.swift`：`syncFiles`、目标身份与连接代次。
  - `Bailey/Files/FileTreeModel.swift`：`sync`、`rebuild`、`contentRevision`、外部事件、可信行/选择保留。
  - `Bailey/UI/CommandPaletteView.swift`、`Bailey/Workspace/ProjectFileIndex.swift`：`fileIndexKey`、索引任务取消/回写、真实 Git/远端文件索引及结果打开。
  - `Bailey/Workspace/WorkspaceWindowModel.swift`：文件标签的 Reveal 与异步机器身份校验。
  - 外部依赖（#40，不算 P4-T1 的新增实现）：`Bailey/Git/GitFileEventWatcher.swift`、`Bailey/Remote/SSHWorkspaceFileEvents.swift`、`SSHHostWorkspaces.swift`。
  - 证据/测试：`BaileyTests/Files/FileTreeTests.swift`、`BaileyTests/Workspace/PanelContextTests.swift`、`BaileyTests/Workspace/ProjectFileIndexTests.swift`、`BaileyTests/Git/GitStatusModelTests.swift`、`GitRemoteRefreshIntegrationTests.swift`；真实 App `BaileyUITests/Files/WorkspaceFileIndexRefreshUITests.swift`。#40 的 `SSHWindowsFileEventsTests` 只作现有事件消费路径参考。
  - 文档：`docs/features/files.md`、`docs/features/command-palette.md`、`docs/features/ssh.md`、`docs/testing.md`。
- **P4-T2**：未审查；不填写实现映射，也不核销其 E2E。

## 发现项

## 发现 F-03

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/ProjectFileIndex.swift:254`
- 摘要：`Git ignore/index 变化未进入 Cmd+P 文件范围失效链`
- 风险：`Cmd+P 的 Git 文件列表来自 ls-files --cached/--others --exclude-standard；只修改现有 .gitignore 内容或 Git index，目录条目未变化时 FileTreeModel.contentRevision 不增加，旧搜索结果仍可见，不满足外部 Git 状态变化的验收。`
- 预期修复：`复用现有 Git 变化来源，按实际文件索引语义失效 Cmd+P 结果，不对 Files 树增加全仓扫描或强制重列所有目录。`
- 验证：`make test:FileTreeTests,ProjectFileIndexTests,GitStatusModelTests；隔离临时 Git 仓库改变 .gitignore 与 Git index 并验证已打开 Cmd+P 文件集合`
- 解决证据：`bdbcafe; FileTreeTests real gitignore/index/worktree native FSEvents PASS; signed Bailey Dev GUI Git ignore/index results and actual opened file PASS`


## 发现 F-02

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:506`
- 摘要：`根目录 MustScanSubDirs 事件不能可靠失效未加载深层文件索引`
- 风险：`FSEvents 允许在根路径合并事件并只给 MustScanSubDirs；根路径分支重读已缓存目录后直接 continue，深层目录未缓存且根条目未变时 contentRevision 不递增，已打开 Cmd+P 保留过期路径。`
- 预期修复：`在已有本机 FSEvents 汇总中把需要递归核验但不能逐目录枚举的信号正确传给 Cmd+P 索引失效，Files 树继续保持懒加载。`
- 验证：`make test:FileTreeTests,ProjectFileIndexTests；注入根路径 MustScanSubDirs 并在未展开子树创建文件，验证索引重查和真实磁盘文件`
- 解决证据：`bdbcafe; FileTreeTests testRootMustScanSubDirsInvalidatesUnloadedProjectFileIndex PASS; deep unread directory stayed unread while Git file index saw real disk file`


## 发现 F-01

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/Panels/ToolPanelView.swift:363`
- 摘要：`Files 不显示时，已打开的 Cmd+P 无本机文件变化失效信号`
- 风险：`命令面板可从终端或 Git 打开；没有可见 Files 时 FSEvents 订阅被释放，当前项目文件在外部新增、删除或重命名后搜索结果仍使用旧索引，不满足 P4-T1 外部变化同步验收。`
- 预期修复：`沿现有项目文件变化通知与命令面板生命周期补上最小失效路径，不使整个 Files 树在后台常驻扫描或增加第二套 watcher。`
- 验证：`make test:FileTreeTests,ProjectFileIndexTests；隔离 Bailey Dev 从非 Files 面板打开 Cmd+P，外部增删文件后检查真实搜索结果`
- 解决证据：`bdbcafe; FileTreeTests shared-listener real FSEvents PASS; signed Bailey Dev WorkspaceFileIndexRefreshUITests PASS (external create/delete with Files hidden)`


以上 F-01～F-03 均经 `feature_tool.py finding add` 登记并在修复验证后使用 `finding resolve` 核销，当前为 `Resolved`。这三条是不同失效前提：无 Files 监听、FSEvents 合并失同步信号、Git 文件范围变化。

**纠正上一轮的错误判断：**此前口头报告的“SSH 子目录部分读取失败必然清空可信行”不能成立为 High Finding。`FileTreeModel.rebuild` 对成功返回的目录执行 `cachedDirectories.merge`，已有但本次缺失的子目录缓存仍保留，`TreeDisplayModel.Traversal.receive` 可继续投影原有行。尚缺对“根成功、已展开子目录失败”的独立回归，列为待补验证，不以未经复现的情况认定产品缺陷。

## 修复日志

- **2026-10-26，已提交 `bdbcafe`：**F-01：用成员订阅让 ⌘P 与 Files 共享当前 `FileTreeModel` 的同一条 FSEvents 监听，非 Files 搜索在真实本机根上启动监听，切换项目、查询清空、失去前台及面板关闭时移除自己的订阅。F-02：根路径 `MustScanSubDirs` 总是使文件名索引失效而不递归扫描未打开的子目录。F-03：监听期间复用 `GitFileEventWatcher.paths` 同时覆盖 `.gitignore`、普通/linked worktree Git index、排除配置及 refs；根据实际文件索引来源标记需要重查，排除默认隐藏 Git 锁文件的无效刷新。
- 已新增 `FileTreeTests` 宿主验证和 `WorkspaceFileIndexRefreshUITests` 实际 App 集成回归，并更新 `docs/features/files.md`、`command-palette.md`、`docs/testing.md`。相关代码与文档已作为独立原子提交 `bdbcafe`；审计文件按 Skill 规则留在本地。

## 验证日志

- **最终本地宿主验证：**`make test:FileTreeTests,PanelContextTests,ProjectFileIndexTests` → PASS / exit 0，**99 项执行、98 passed、1 skipped、0 failed**；macOS 27.2 arm64，`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_01-36-03-+0800.xcresult`。实测双成员共享订阅及释放、深层文件 MustScan、真实 Git ignore/index、**linked worktree 外部 Git 元数据原生 FSEvents**、本机/远端同路径不混淆、原 Files/SSH 连接代次回归。唯一跳过为其它 AI 在 `ProjectFileIndexTests` 加入的需授权 Windows SSH 夹具。
- **完整 App GUI：**`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFileIndexRefreshUITests/testCommandPaletteTracksExternalFilesAndGitScopeWithoutOpeningFilesPanel` → PASS / exit 0，**1/1 通过**；`build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.26_01-37-00-+0800.xcresult`。签名隔离 Bailey Dev 从 Git 面板打开 ⌘P，实时创建/删除文件、改 `.gitignore`、强制暂存被忽略文件；断言搜索结果增删、绝对文件路径及点击后真实标签与磁盘字节，测试后清理临时项目。
- **远端回归：**`make test:GitRemoteRefreshIntegrationTests` → PASS / exit 0，**2 项执行，1 passed、1 skipped**；`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_01-38-48-+0800.xcresult`。跳过者为需要已授权实际 SSH 主机的测试，非静默成功。
- **扩展 Git watcher 兼容性检查（未完成）：**额外执行 `make test:GitStatusModelTests`；49 个声明用例中已通过前 21 项、0 断言失败，运行到 `testIndexMutationAndPaginationAvoidUnrelatedGitQueries` 时 MCP 等待命令超时触发 SIGTERM，最终 make **exit 143 / 未完成**。这不属于失败断言，也不能称为 49/49 通过；需要空闲的独占测试锁时继续补验。项目已有其他 AI 的 Bailey Dev GUI 测试占锁，未抢锁重试。
- **构建和验签：**`make build:dev` → BUILD SUCCEEDED / exit 0，Apple Development 签名；`codesign --verify --deep --strict build/DerivedData-Dev/Build/Products/Debug/Bailey.app` → exit 0。正式 Bailey App 未启动、替换或重启。
- **本轮首次修复验证（2026-10-26）：**`make test:FileTreeTests,PanelContextTests,ProjectFileIndexTests` → **PASS / exit 0**；97 项执行，96 passed、1 skipped、0 failed，macOS 27.2 arm64；实际 xcresult：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_01-29-50-+0800.xcresult`。新测共享 watcher 成员、根级 MustScanSubDirs、`.gitignore` 与 Git index 均通过；跳过的是其它任务新增、需要 `BAILEY_P3_TEST_SSH_HOST` 授权的 Windows SSH 实测。此条是当时的首轮快照；随后增补的 linked worktree 与 GUI 已在上方独立验收。
- **本轮环境并发：**第一次定点构建发现闭包参数编译错误，已改正；第二次尝试因其他 AI 的 Bailey Dev 测试锁而未启动，未绕过互斥；取得锁后实际完成上述 PASS。锁释放后已完成第二轮宿主、GUI、构建和验签；没有终止其他 AI 的测试。
- **原审计时定点宿主测试：**`make test:FileTreeTests,PanelContextTests` → **PASS，命令退出码 0**；macOS 27.2、arm64，82 passed / 0 failed / 0 skipped；实际 Xcode 结果：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.26_01-13-16-+0800.xcresult`。该结果仅证明所运行用例通过，不证明新发现的三个失败场景。
- **提交证据：**`git show dff9512`（11 个文件，Files→Palette 内容代次与固定 SSH 重连身份链）；`git show 5735cbf`（同一固定 SSH 重连后，首次读取失败保留已确认行并阻止旧行移动/删除/重命名）。后续 `204e74a`（本机 FSEvents）、`2f5fac7`（Windows SSH 事件通知及回退）、`84833c3`（失败回退）是 #40 依赖，不以当时 2 秒轮询文档代表当前实际实现。
- **真实消费路径：**可见 Files 的 FSEvents / SSH 文件通知 → `FileTreeModel.rebuild` / `Project.syncFiles` → `contentRevision` → `CommandPaletteView.fileIndexKey` → `.task(id:)` → `ProjectFileIndex.load/loadRemote` → 结果列表与打开动作；`SSHHostWorkspaces.connectionChanged` → `ToolPanelView.syncModels`，连接代次和窗口/项目根身份阻止旧通道结果回写。确认实际接线，不是只新增了未使用类型。
- **实测触发前提：**在独立临时 Git 仓库中，仅将已有 `.gitignore` 写入 `*.tmp`，磁盘文件名不变，`git ls-files --others --exclude-standard` 却不再包含 `target.tmp`；与当前 `contentRevision` 只观察目录条目的条件形成反例。F-01 由 Palette 独立展示及 Files 订阅生命周期的可达源码路径支持；F-02 由当前 Xcode SDK `FSEvents.h` 对 `MustScanSubDirs` 根级层次合并事件的明确契约和源码 `continue` 分支支持。
- **已覆盖的受影响条件：**相同目录无变化、目录创建/删除、读取全失败保留旧行、固定 SSH 同 Identity 但连接代次变化、新旧查询乱序、选择不随未证实删除消失；以上既有路径结合 99 项最新定向测试及 1 项真实 GUI E2E 共同支撑；不以此前 82 项基线冒充当前验证。
- **修复核销：**① Files 隐藏时 ⌘P 外部增删实时结果、实际打开（F-01，GUI PASS）；② 根级 `MustScanSubDirs` 与未展开深层目录（F-02，真实磁盘夹具 + 模拟聚合信号 PASS）；③ Git ignore/index 与 linked worktree 元数据（F-03，本机真实 Git + FSEvents + GUI PASS）。**剩余独立验收：**实际 Windows SSH 的同主机重连、根读取成功而已展开子目录部分失败、断线期间旧请求拒绝回写及恢复链路尚无本轮真实主机证据；相关宿主夹具不能替代实测。
- **环境缺口与补验：**本轮实际签名 Dev GUI 已验证 Git 面板 ⌘P 与外部磁盘/Git 操作；Finder 拖放、真实 GUI 多窗口与 SSH 断线/重连的跨领域矩阵属于 P4-T2，未擅自扩测。P4-T1 仍缺获授权的实际 Windows SSH 主机，无法核销固定 SSH 部分读失败与重连（本轮 SSH 宿主测试因未提供授权目标各跳过 1 项；使用获授权隔离 SSH master + 测试目录后补验）。macOS 15.6 真机、物理触控板、特殊卷条件不可用，记录于 P4-T2 完整环境 Gate，不以 macOS 27.2 代表所有版本。
- **构建/签名边界：**本轮 `make build:dev` 和 `codesign --verify --deep --strict` 已实际通过；未执行全仓 `make test` 或 Release 发布，这些属于 P4-T2 阶段 Gate，不冒充已完成。
- **文档：**当前 `docs/features/files.md` 与 `docs/features/command-palette.md` 反映后续本机 FSEvents 和 SSH 回退；`docs/features/ssh.md` 与 `docs/testing.md` 说明连接和 E2E 边界。`plan-p4.md` 中“2 秒轮询、#40 未实现”的文字是写计划时的基线，当前已被 #40 的实际提交推进；历史 plan 不因此被直接改写。

## Gate（是否允许进入下一阶段）

- **P4-T1 已发现的 F-01～F-03：`Resolved`，本机根因修复与真实 GUI 已验收通过。**
- **P4-T1 完整 Gate：`No-Go`（仍缺授权 Windows SSH 实机验收；扩展 GitStatusModelTests 全套运行中断）。**本机/真实 Dev 场景已核销，SSH 固定连接部分读失败、断线恢复与旧查询隔离只具备宿主替代证据；GitStatusModelTests 仅 21 项在中断前通过，不能冒充全套完成。未完成这些必要补验前，不把全部计划称为通过。**P4-T2 本轮未审查，不作其 Go/No-Go 判定。**

## 最终状态与剩余风险

- 当前状态：**3 项 High Finding 全部 `Resolved`；对应代码/测试/文档已提交 `bdbcafe`；完整 P4-T1 Gate 仍等待 Windows SSH 实机证据。**P4-T2 未审。
- 剩余风险：实际 Windows SSH 不可用时无法复验固定连接恢复、部分目录失败与跨机器真实打开；本机已发现的 3 项失效路径均有宿主及 GUI 证据，不再列为 Open 风险。
- 操作边界：仅提交本轮拥有的 10 个文件，未纳入其它 AI 的 `FileTreePanel.swift`、`ProjectFileIndexTests.swift`、`WorkspaceFilesUITests.swift` 未提交改动，未更新 `todo.toml` 或审查 P4-T2。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

