# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：**Go（文件剪贴板 P1）**。F-01、F-02、F-03 均已修复且核销。最终 HEAD 的第二次完整 Host、真实 Finder GUI、独立 APFS 跨卷均通过；首次完整 Host 的 Git Graph AX 不稳定性保留为非本 Feature 的验收记录。
- **依据**：最终 HEAD 完整 Host 复跑 **1,144 项，0 失败、21 跳过**（命令退出 0，`TEST SUCCEEDED`）；文件/跨窗口 Host 152 项、真实 Finder GUI 5 项、独立 APFS 跨卷 6 次均 0 失败；Debug 构建与验签通过。首次全量 Host 同一 Git Graph AX 用例产生 9 个失败断言，隔离 1/1、整类 3/3、后续完整全量均通过。

## 独立逐提交复审（2026-11-21）

本轮以 `idea.md`、`plan-p1.md`、`todo.toml`、各提交原始 diff、
CodeGraph 调用链和真实磁盘／GUI 结果为依据；不采信原有审计结论。

完整 Host 和 GUI 的受测代码位于 `fca8bdea`；复测期间并行提交 `1393940a` 仅更新本 Feature 的 `audit-p1.md` 与 `todo.toml`，未修改任何生产代码、测试或 UI。因此当前 HEAD `1393940a` 与受测版本在可执行代码上相同，不将文档提交误记为另一次编译验收。

| 提交 | 归属 | 实际消费链与审查结论 |
| --- | --- | --- |
| `aa3ae57e` | P1-T1 | `FileTreeClipboard` 写入逐项原生文件 URL，`WorkspaceWindowModel` 复制/剪切入口实际调用；`WorkspaceApplication` 持有当前进程剪切身份，伪造记录不能独立授权删除；SSH 不产生本机文件 URL。 |
| `159aa612` | P1-T2 | `FileTreeModel.performFileOperation` 和 `importFromFinder` 均通向 `LocalWorkspaceBackend.transferLocalFile(s)`；真实文件、目录、符号链接、并发不覆盖与隔离 APFS 跨卷结果已核对。 |
| `ad4acb2c` | 计划 | `plan-p1.md`、`todo.toml` 为流程记录，不是未接入的生产功能；需求真源 `idea.md` 保留。 |
| `9e8611d6` | P1-T3 | `BaileyApp` 的 Edit 菜单、`TreeKeyboardView` 的原生菜单动作和 `FileTreePanel` 右键均路由至 `WorkspaceWindowModel.pasteLocalFiles`，经 `withProtectedFiles` 到统一磁盘后端；跨窗口标签同步由 `fileRenamed` 负责。 |
| `08320d35` | GUI 夹具 | Finder 窗口/文件项准确定位，避免误复制文件名文本；真实 Finder 双向复制与显式移动测试均使用该夹具，非孤立测试代码。 |
| `911814db` | F-02 根因修复 | 操作发起时锁定源实体；异步保存仅为同一合法实体刷新身份；被替换来源不保存、不删除；部分成功仍逐项继续，失效剩余项不重新获得剪切授权。已完成文件/目录替换的 Red→Green。 |
| `4696f454` | T2 清理 | 扩展属性名改为标准 UTF-8 解码，移除弃用 `String(cString:)`，并修正旧 Finder 专用描述；文件元数据回归与构建已通过。 |
| `95885c13` | F-03 根因修复 | `WorkspaceApplication.withProtectedFiles` 按源 inode 类型识别本机符号链接，不跟随链接强制保存目标编辑器；剪贴板和内部移动复用同一保护入口，四种链接/打开路径组合 Red→Green。 |
| `fca8bdea` | 跨卷验收修正 | 用真实文件身份替代 `/private/tmp` 与 `/tmp` 别名下的纯字符串路径比较；独立 APFS 镜像两种挂载路径各 3/3 通过，不改变生产传输。 |

**旧路径核对**：原本独立的 Finder 本机复制入口、`LocalFileImportResult` 和无用的
`copiedEntries` 已删除；没有残留的双轨本机传输。
`FileTreeModel.copyWithUniqueName` 仍由 SSH／可注入后端真实调用，不应作为死代码删除。
内部拖放 nonce、跨卷校验、源实体身份及原子排他发布均承担真实数据保护职责，
不是可以随意删除的兼容层或冗余围栏。

## 发现项

## 发现 F-03

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/App/WorkspaceApplication.swift:338`
- 摘要：`移动原生符号链接时跨窗口保护按解析路径误匹配链接目标并强制保存无关脏稿`
- 风险：`仅移动链接 inode 的用户操作会提前写盘链接目标编辑器的未保存内容，违反不跟随链接实体与保存保护的来源归属。FileTree 剪贴板和内部移动均可触发。`
- 预期修复：`在现有 WorkspaceApplication.withProtectedFiles 公共文件保护入口按源文件系统实体判别；本机符号链接本身的移动不触发链接目标正文保存；保留常规文件、真实目录与远端原有保护。`
- 验证：`新增真实链接+未保存目标编辑器的剪贴板移动与内部移动 Red→Green；WindowOwnershipIntegrationTests 和 FileTreeTests、Finder UI、最终完整 Host。`
- 解决证据：`Red /tmp/bailey-clipboard-audit-symlink-red-20261121.log: link move forcibly saved unrelated dirty target (4 assertions). Commit 95885c13 fixes withProtectedFiles shared path to protect entities not link targets. Green /tmp/bailey-clipboard-audit-symlink-four-matrix-20261121.log four native-clipboard/internal-move x real-target/link-open combinations; FileTree+WindowOwnership 152/0/3 skipped; true Finder GUI 5/5; real independent APFS aliases 6/6.`


## 发现 F-02

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/WorkspaceWindowModel.swift:1105`
- 摘要：`文件剪贴板移动在异步文件保护之后重新读取来源身份；粘贴发起时与执行时不同的源实体可能被错误移动`
- 风险：`源文件在排队移动前或受保护保存期间被替换，异步重采身份可能误移动后来创建的实体；部分失败后若重新信任替换后的来源，还可能将其错误授权为下一次剪切移动。注意：已经明确发起的 ⌥⌘V 可以继续执行，但不得覆盖其他应用后来设置的剪贴板。`
- 预期修复：`把移动意图、剪贴板版本及来源身份绑定到开始执行时；只允许受保护编辑器的已验证保存变更；异步之后必须核销授权，不重采来源作为原授权。`
- 验证：`WindowOwnershipIntegrationTests 排队源替换、部分失败重试、脏稿保存与原有显式移动剪贴板保持回归；make test:WindowOwnershipIntegrationTests；FileTreeTests、完整 Host、真实 Finder UI 回归。`
- 解决证据：`Red: /tmp/bailey-clipboard-audit-red-20261121.log and /tmp/bailey-clipboard-audit-directory-negative-red-20261121.log prove replaced file/directory was wrongly moved. Root-cause commit 911814db pins source identity and forbids unauthorized retry. Green: /tmp/bailey-clipboard-audit-symlink-files-final-20261121.log FileTree+WindowOwnership 152 tests/0 failures/3 dedicated APFS skips; actual Finder GUI /tmp/bailey-clipboard-audit-f03-gui-final-20261121.log 5/5/0; independent APFS logs 6/6. Final full Host has one unrelated Git Graph AX failure pending separate verification.`


## 发现 F-01

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Files/SharedTreeUITests.swift:81`
- 摘要：`审计时双向复制已通过，显式移动尚缺完整 GUI 验收；2026-11-21 已完成`。
- 风险：`原验收缺口已由隔离 Bailey Dev 的原生菜单和真实磁盘副作用测试关闭`。
- 预期修复：`在独立 macOS 图形登录会话或受控 GitHub Actions macOS Runner 运行新增两项 XCT UI 用例，逐项核对 Finder 和 Bailey 两端的真实磁盘字节、来源存留及剪贴板恢复`
- 验证：`make test:ui ONLY_TESTING='BaileyUITests/SharedTreeUITests/testFinderAndBaileyCopyFilesBothWaysThroughNativeClipboard BaileyUITests/SharedTreeUITests/testFinderFileUsesNativeMoveHereShortcutWithoutAClipboardCutToken'`
- 解决证据：`2026-11-21 /tmp/bailey-clipboard-finder-final-p1-20261121.log: make test:ui 双向复制+Finder显式移动，Selected XCTest methods:2，2 passed/0 failures，TEST SUCCEEDED，退出0；/tmp/bailey-clipboard-gui-context-regression-20261121.log: 3 passed/0 failures，TEST SUCCEEDED，退出0；目标字节、源删除、剪贴板源URL失效及恢复均由真实 GUI 断言；08320d35 修正测试夹具。`


## 验证与未覆盖（独立复审）

- **F-02，Red→Green**：排队移动期间替换单文件／目录会错误移动新实体；批量部分失败不得恢复新实体的剪切授权。修复后相应源码副作用、脏稿合法保存和旧剪贴板保留测试均通过；证据：/tmp/bailey-clipboard-audit-red-20261121.log、/tmp/bailey-clipboard-audit-directory-negative-red-20261121.log、/tmp/bailey-clipboard-audit-symlink-files-final-20261121.log。
- **F-03，Red→Green**：仅移动符号链接却意外保存目标脏稿；修复后剪贴板／内部移动 × 编辑器打开真实目标／链接路径四种组合均保持目标原字节、链接实体和未保存稿。证据：/tmp/bailey-clipboard-audit-symlink-red-20261121.log、/tmp/bailey-clipboard-audit-symlink-four-matrix-20261121.log。
- **文件与窗口 Host**：FileTreeTests 112 项、WindowOwnershipIntegrationTests 40 项，合计 **152 项，0 失败、3 跳过**；覆盖多选/Unicode、目录/链接、权限、元数据、冲突/并发防覆盖、跨窗口脏稿、源替换、部分成功与 SSH 隔离。证据：/tmp/bailey-clipboard-audit-symlink-files-final-20261121.log。
- **真实跨卷 APFS**：两次新建 256 MB 镜像，/private/tmp 与 /tmp 入口各运行 **3/3 通过**，核对目标与来源 dev 不同、普通文件字节、含失效符号链接的目录以及只读来源导致的已验证复制但源未删除；两次均正常卸载并清理。证据：/tmp/bailey-clipboard-audit-apfs-private-20261121.log、/tmp/bailey-clipboard-audit-apfs-public-20261121.log。
- **真实 Finder GUI**：隔离 Bailey Dev 的双向复制、外部显式移动、右键目标/焦点、内部剪切粘贴与删除，**5/5 通过、0 失败**；验证实际磁盘字节、原文件存留或移除、剪贴板失效 URL 清理和终端焦点。证据：/tmp/bailey-clipboard-audit-f03-gui-final-20261121.log 与对应 Xcode xcresult。
- **完整 Host 首次**：最终 HEAD 的 `make test` 共 **1,144 项，21 跳过，9 个失败断言集中于 `GitPanelVisibilityTests.testGraphRemainsVisibleAfterResizeChangesAndHistoryRewrite`**；命令返回非零，不能记为通过。证据：`/tmp/bailey-clipboard-audit-final-complete-20261121.log`。该测试独立重测 **1/1 通过**：`/tmp/bailey-clipboard-audit-gitgraph-isolated-20261121.log`；整个 GitPanelVisibilityTests 类 **3/3 通过**：`/tmp/bailey-clipboard-audit-gitgraph-suite-20261121.log`。该测试与 Git Graph 生产代码均不在本 Feature 修改范围内；未据此修补 GitGraph，也未把单次成功写成完整全绿。最终 HEAD 全量重跑日志：`/tmp/bailey-clipboard-audit-final-full-recheck-20261121.log`，**1,144 项，21 跳过，0 失败，退出 0，`TEST SUCCEEDED`**。此前 1,141 项、0 失败的全量证据属于 F-03 修复前版本，未作为最终 HEAD 的完成证据。
- **构建与清理**：make build 成功；codesign --verify --deep --strict 验签通过；原生 GUI 目标可编译运行；已删除过时的本机 Finder 专用传输入口、冗余导入类型与弃用 UTF-8 解码调用。原有 SSH 复制与拖放 nonce 仍真实使用，不能当死代码删除。
- **未执行的环境专属项**：18 项真实 Windows SSH Live 测试需要专门授权的远端环境，本次不触碰用户服务器；Host 的 SSH 来源/目标隔离断言已经通过。完整 Host 中原会跳过的 3 项跨卷用例已在上述独立 APFS 镜像单独补齐。
