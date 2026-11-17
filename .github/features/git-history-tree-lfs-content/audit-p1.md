# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（允许推进 P2；不等同于最终 GUI 验收通过）
- **依据**：真实 Git、生产共享树、历史解析和宿主测试证实同路径文件/目录独立存在，代码无旧分叉；完整 GUI 测试尚缺可独占图形会话，明确移交最终 P2-T3 验收，不得在发布或替换正式 App 前宣称完整 E2E 通过。

## 任务与改动

- **P1-T1 让共享树正确表达同路径文件与目录**：`62d48eef`；`TreeDisplayModel.Row.id/pathRows` 改用「路径＋节点类型」身份，不再让历史旧文件占用新增目录槽位；`FileTreeTests` 先 Red 后 Green；同步 `docs/features/files.md`。未新增双轨树、绕行兼容代码。
- **P1-T2 让真实历史、Tree/List 和交互共享同一完整集合**：`d28bf591`；`GitStatusModelTests` 用 SHA-1/256 实仓比较 Git 原始 NUL name-status、历史解析、叶子集合、折叠和状态；`GitGraphUITests` 增加实际 App 文件与目录同路径回归；同步 `docs/features/git.md`。`RecentCommitsView.commitFiles/appendHistoricalNavigation` 原本共享同一个 `pathRows`，无需重写解析器、导航或 Stash 重复路径 List 回退。

## 发现项

- **计划计数漂移，已修正**：实际只读 `3eb51c6` 变更为 31 A、2 D、3 M，共 36 条；原计划误把 A+D 的 33 条作为全部。已在 `idea.md` 和 `plan-p1.md` 修正；不是生产代码缺陷，无需新增代码分支。
- **未发现仍可达的重复树实现或多余安全围栏**：Files 仍用共享 `Traversal`，Git Graph 的 Tree 和键盘使用同一批 `pathRows`，Stash 重复路径按原有 List 语义呈现。

## 验证与未覆盖

- `make test ONLY_TESTING=BaileyTests/FileTreeTests/testSharedTreePreservesFileAndDirectoryWithTheSamePath`：旧实现真实失败（7 个断言），确认根因；修复后连同普通路径身份用例 2/2 Green。
- `make test:FileTreeTests,GitStatusModelTests,NativeGitHistoryFileTests`：**完整命令成功，194/194 宿主测试通过**；额外 `make test ONLY_TESTING=BaileyTests/GitStatusModelTests/testRealHistoryRetainsBothKindsOfNodesWhenPathsAreReused`：新实仓用例 1/1 成功。
- `make build:ui`：Xcode 返回 `** TEST BUILD SUCCEEDED **`；证明完整 App UI 测试 Target 编译成功，但不等于 GUI E2E 已执行。
- 手工只读以当前 `TreeDisplayModel.swift` 编译 Swift 驱动，喂入实际 `~/.codex` 提交 `3eb51c6` 的 Git `-z` 状态：**36 个输入文件，36 个可见叶子，36 个唯一路径，旧 `wiki` 文件与新目录同名并存**；输入仓库未修改。
- 维度：SHA-1/256；文件→目录、目录→文件、gitlink→目录；中文、空格、换行文件名；输入正反顺序；空树；普通路径目录压缩/身份；状态优先级；目录折叠；旧文件仍可见；真实 `GitStatusModel` 日志解析。当前实现无新的额外重试、守卫或兼容性双轨。
- **未测：完整 Bailey Dev GUI**：仅有用户正在使用的 `console` 会话，按 `docs/testing.md` 不能抢占前台；专用 GUI 用例已编译、尚未执行。影响：不能宣称鼠标、焦点、上下文菜单与折叠的真实 App 路径验收通过。补验：P2-T3 在可独占图形会话运行 `make test:ui ONLY_TESTING=BaileyUITests/GitGraphUITests/testHistoricalTreeKeepsDeletedFileBesideDirectoryReusingItsPath`；发布前必须通过。
- **未测：真实 SSH 和最低 macOS 环境**：没有为本阶段使用授权测试仓库和独立远端 GUI；`GitStatusModel` 本机实仓和既有受控后端测试覆盖数据层，不能冒充实机。P2-T3 有远端授权条件时补验。SSH 状态与历史解析共用 `GitCommandExecution` 和 `TreeDisplayModel`，本阶段未修改传输。
- 文档已随各代码提交同步 `docs/features/files.md`、`docs/features/git.md`；`git diff --check` 和预提交检查通过。正式版 App 未操作，未 push `main`。

## 后续验收补充（2026-11-17）

P2-T3 后续取得 GUI 会话和 Windows Tailscale 授权：
实际运行的 `GitGraphUITests.testHistoricalTreeKeepsDeletedFileBesideDirectoryReusingItsPath`
已通过（21.203 秒），历史文件键盘导航亦通过（23.964 秒）。
本机历史树的真实 GUI 验收不再受阻；最初阶段未测记录保留为当时的审计事实。
后续完整宿主测试尚有远端超时，最终跨阶段门禁以 [P2 审计](audit-p2.md) 为准。
