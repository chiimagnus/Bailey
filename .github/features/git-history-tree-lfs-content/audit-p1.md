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

## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/DiffViewerView.swift:1400`
- 摘要：`历史文件改为目录后删除 Diff 错误地将目录后代解析为目标文件`
- 风险：`Git Graph 已显示删除记录，但打开该记录时只显示 Git 内容读取错误，违反文件目录双向转换验收`
- 预期修复：`历史 OID 查询改为只定位路径自身；将当前树对象视为文件缺失，保留 gitlink 非文本限制`
- 验证：`使用真实文件转目录提交复现 Red/Green，检查删除 Diff、Revision 缺失与 gitlink 错误，并运行 Git 宿主回归及构建`
- 解决证据：`707837c8：Git Tree 非递归、Index 排除目录后代；实际 SHA-1/256 真实 Git 仓库 Red 20 条断言→Green，新增 1200 文件和中文特殊路径回归；56项目标测试0失败（1项条件跳过），436项受影响跨模块0失败（3项条件跳过）；make build、make build:ui 均成功。`


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

## 独立后审（2026-11-18，代码提交 707837c8）

依据 `todo.toml` 从代码、提交、真实 Git 输出重新核对，不采用此前阶段审计的 Go 结论作为前提。

| 任务与提交 | 源码接线及提交复核 | 后审结论 |
| --- | --- | --- |
| P1-T1 `62d48eef` | `TreeDisplayModel.Row.id/pathRows` 的文件／目录节点按类型区分；`RecentCommitsView.commitFiles` 与 `appendHistoricalNavigation`、Changes Tree 和键盘导航使用生产共享树；真实历史的文件→目录／目录→文件与 SHA-1/256 用例保留。 | 生产链路实际使用；无独立过时树需要清理。 |
| P1-T2 `d28bf591` | 真实 Git 变更共 36 条，Tree/List 与解析模型使用同一集合，Stash 重复路径仍保留必要的 List 回退。原 GUI 测试未点击被删除的旧文件，因而漏掉历史 Diff 与同名目录的内容读取错误。 | 发现 F-01；由 `707837c8` 修复，追加宿主及 GUI 回归。 |

- 独立复现：真实 Git `ls-tree -r` 将旧文件路径下的子文件返回；Index 目录前缀匹配还会产生超限输出。新增 Red 为 1 个方法、20 条失败断言，覆盖 SHA-1/256。
- 根因修复：Git Tree 不递归查询、明确把目录节点当作非文件；Index 使用字面包含路径与排除子目录的 Git pathspec，保留对返回目标路径的严格字节校验。1,200 个索引后代使旧查询输出 84,093 字节，新查询输出 0 字节。
- `707837c8` 的最终测试：`make test:NativeGitHistoryFileTests,GitExecutionTests` 执行 56 项、1 条 Windows SSH 条件跳过、0 失败；此前受影响跨模块定点集执行 436 项、3 条远端条件跳过、0 失败；`make build`、`make build:ui` 成功。
- 原生 GUI 原有历史树测试曾实际通过；本次新增“点击旧文件删除 Diff”断言已编译签名，**未取得独立图形会话实测**，不把编译视为 GUI 通过。
- 保留必要边界：Stash 重复路径 List 回退、Git 非文本对象拒读、元数据完整性校验；未增加双轨历史解析或兼容实现。当前无其他已证实的 P1 未修复生产缺陷。跨阶段技术门禁及远端遗留问题见 P2。
