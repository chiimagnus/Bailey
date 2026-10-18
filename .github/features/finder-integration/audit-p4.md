# Audit P4 - finder-integration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/finder-integration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P4-T1 统一当前项目的本机文件标签路由
- [x] P4-T2 Open File 菜单、目录添加与旧路径清理
- [x] P4-T3 真实 Finder、极端条件与独立验收

## 任务到文件的映射

- **P4-T1 · `1121e74`**：`TerminalManager.openExternalLocalItems/openExternalFiles`、`Project.openLocalFile`、`SessionStore.TabSnapshot.localFile` 与恢复分支；`WorkspaceIdentityTests`、`SessionStoreTests`、`WorkspaceWindowIsolationTests`；`docs/features/{projects,dock,editor,session-restore}.md`。取代按父目录统计／最长目录匹配创建项目的旧路径；本机标签不依赖 SSH 项目后端，跨窗复用以 `FileTab.workspaceIdentity == nil` 为准。
- **P4-T2 · `6269ac9`**：`BaileyApp.BaileyCommands` 的 `⌘O`，`WorkspaceDockView` 每组「＋」的 Open File，`ContentView.WorkspaceNativeDialogs` 原生文件／目录面板，`ProjectsPanelView`、`CommandPaletteView` 等新增意图入口；`TerminalManager.chooseFiles/chooseFolders/addLocalItems`；`AppMenuIsolationTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`、`WorkspaceIdentityTests`；`Interface/Sidebar/Terminal.xcstrings`、`README.md`、当前功能与 UI/测试文档。新建 Mac 单文件项目的入口已删，历史单文件快照保留。
- **P4-T3 · `b426b30` + `b4e29bc`**：前者修正失效 `(projectID, groupID)` 异步投放禁止回退，补 A→B→A、空组、52+、无项目等测试；后者修复 Finder 新文件权限、目录权限、FIFO 特殊文件，新添 4 项回归并同步 `docs/features/projects.md`。`plan-p4.md` 与 `todo.toml` 为本地执行记录，不属于任何代码提交。

## 发现项

- **已解决的真实缺陷 1（P4-T3 / High）**：对新 Finder 文件只做 `fileExists` 验证，`chmod 000` 文件会创建无法读取的编辑标签；混合批次同时影响合法邻居的用户结果记录。`WorkspaceIdentityTests.testFinderUnreadableFileRejectsNewTabButOpensValidNeighbor` 原版失败，现由唯一文件接收入口拒绝新建并允许合法项继续，且不破坏已有打开标签。
- **已解决的真实缺陷 2（P4-T3 / Medium）**：不可读取／遍历的目录被 `addLocalItems` 添加为无法浏览的 Project；`testFinderUnreadableFolderCannotBecomeProjectOrMaskValidFolder` 原版失败；现目录添加与 Finder 文件夹两处入口共用可读／可遍历约束。
- **已解决的真实缺陷 3（P4-T3 / High）**：命名管道等非普通文件仅因路径存在就进入 `FileTab`，后续读取可能阻塞；`testFinderNamedPipeDoesNotCreateEditorThatCouldBlockOnRead` 原版失败；现新文件校验实际目标的普通文件类型。
- **当前没有尚未解决、达到可复现或代码不变量违背门槛的 finding。** 未获执行条件的原生 E2E 不能被写成已修复 Bug，也不视为已完成的真机组合，具体见下方缺口。

## 修复日志

- T1 在原 `Project → PaneTab → FileTab → Dock` 链路上统一新 Mac 文件与已开文件；旧父目录／自动 pinned 路由在同一任务清理。T2 复用一个 `NSOpenPanel` 选择逻辑和一条文件事件路由，保留固定 SSH 手动文件项目与老快照。T3 `b426b30` 的目标校验发生在批次开始前，失效时不向其它项目偷偷投放。
- 本次 T3 权限/FIFO 先运行 Red：`/tmp/bailey-p4-nonregular-red.log` 为 **23 项、7 个失败断言**；随后在现有 `TerminalManager` 入口修复；`/tmp/bailey-p4-regress-final.log` 为 **24 项、0 失败**。正向测试覆盖只读但可读文件、权限变化后已开缓冲仍复用，不把所有只读文件误拒绝。`b4e29bc8ace21c39d9fee1da87369e2758afc9c3` 为唯一新增代码修复提交，含生产文档。
- 四个 P4 实现提交 `1121e74`、`6269ac9`、`b426b30`、`b4e29bc` 逐个 `git show --check` 退出 **0**；当前 `git diff --check` 退出 **0**。检索无 `filesByParent`、`chooseLocalItems`、混合 `localPanel`、`documentProject` 或新建 Mac pinned 的可达路径；仍存在的 `pinnedFile` 分支由**显式 SSH 添加和旧快照恢复**消费，不属于旧代码垃圾。

## 验证日志

- **最终完整构建和测试**：macOS 27.2、Xcode 27.2、arm64，最低 deployment 15.6。`make build` -> 完整退出 **0**、`** BUILD SUCCEEDED **`、`codesign --verify --deep --strict` 成功，日志 `/tmp/bailey-p4-final-build.log`；`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test` -> 完整退出 **0**、`** TEST SUCCEEDED **`、**470 tests / 0 failures / 0 skipped**、828.482 秒，日志 `/tmp/bailey-p4-final-ssh-test.log`。六个 SSH 专用用例（Git 外部刷新、交互式变基、Git 归档/状态、文件树两个、断线恢复）均实际 passed，使用获授权 `windows` 主机和各自测试专用套接字／远端临时仓库，没有动用户 SSH master。
- **真实原生菜单和系统文件事件**：签名 Debug App 以唯一 `BAILEY_UI_TEST_RUN_ID`、独立 Home 及临时文件夹启动；实际 File 菜单和 ⌘O／Dock 每组「＋」弹出 Native `NSOpenPanel`，取消不添加标签。原生 Text Editor 真实显示外部文件正文与多选各路径内容，160×100 PNG 由图像视图加载；跨目录／特殊字符／未知扩展名打开不生成项目。A 的根内文件及 A 的根外文件，在切换到 B 后再用系统事件打开，均回到 A 原 FileTab，不额外生成可写缓冲。右侧组「＋」选择文件后 `dock` 快照证明进入真实接收组；磁盘文件修改后原生 File → Save，源字节从 `let edited = 0` 写为 `let edited = 1234`。
- **真正 Finder 物理落点**：独立签名 App／Finder 两个实际窗口核对边界后，Finder→Projects 文件落点在现有项目打开而不建项目；Finder→Files 根留白产生逐字节相同副本而不打开标签；Finder→顶部 Dock 标签栏产生实际组内标签。三次源文件完整保留并核对 SHA-256。P3 的 Files 目录行／文件行／根标题、Ghostty 和 WebKit 真实 Finder 记录在 `audit-p3.md`；P4 对相应不可前台重测的位置使用 `FileTreeTests`、`WorkspaceWindowIsolationTests` 和 `PaneRetentionTests` 分层替代，不冒充本轮真鼠标 E2E。
- **容量、身份、恢复**：独立真实 App 一次收取 **68 个唯一文件及重复／软链合计 72 个输入**，最终仅 1 个正常目录项目、68 个唯一 FileTab；68 个源文件 SHA 全不变。另一个隔离 App 在两个项目打开 11 个标签，执行真实退出及同 UUID 重启；原生 UI、文件路径、选中标签、Dock 树和本机身份恢复，先前保存的源内容在磁盘可读。无项目空态、坏链、非法 URL、跨窗优先原有 buffer、原生关窗保存／失败、旧 `pinnedFile` 快照、SSH 项目内本机/远端同路径隔离，均有已实际执行的模型／NSWindow／FileTab / SessionStore 测试；不可据此推断所有独立进程 GUI 组合。
- **路径与异常矩阵**：0/1/多/68 个、根内/根外/不同父目录、重复/软链/断链、Unicode/空格/引号、未知后缀/PNG/普通文本、只读可读、不可读新文件、不可浏览目录、FIFO、受控 SSH 断开/重连、5 MiB 边界/NUL/无效 UTF-8 的底层处理，以及 Files 的局部成功/失败、重名原子无覆盖，均有不同层次测试；把“已运行 XCTest”和“实际 GUI 看见用户结果”逐条区分。本机实际补出的权限/FIFO 缺陷均有 Red→Green，原始测试素材只在 `/tmp/bailey-p4-e2e-2p9m03uq/`。
- **安装与用户保护**：最终签名 Debug `Bailey.app` 先同卷 `/Applications/.bailey-p4-install.qyPKHM` 完整暂存、验证签名与哈希，再整包替换；现有正式包及新包严格验签成功，安装后二进制 SHA-256 与构建一致 `fd05597363ffc87eefe704df6781cab448722be7f9384f7a3328e1c3f1ea542e`。仅临时空目录由 `rmdir` 清理；正式运行中的 Bailey PID **59877 保持不变**，未退出／启动／重启。安装成功不等于旧进程已加载新逻辑，须用户自行正常重启生效。未推送／未合并，Feature 文件未加入 Git。
- **功能文档**：`docs/features/{projects,dock,editor,session-restore,files,ssh,command-palette}.md` 与 `docs/{ui,testing}.md` 按真实职责记录项目范围、原生菜单、窗口与 Git/Files 根、Local vs SSH、保存和隔离；`README.md` 中入口对齐。`docs/features/projects.md` 在本次修复提交同步说明普通文件／目录权限、不抛弃已开缓冲。对应文件、索引和文档引用均实际存在，历史 P1～P3 审计不被改写为 P4 的新 UI 成功记录。

### 无法在当前环境完成的实际 E2E（不冒充通过）

1. **macOS 15.6 最低系统真机**：仅有 macOS 27.2 和对 15.6 的部署编译，无 15.6 主机。风险是 15.6 原生 Finder Drop、NSOpenPanel/Apple Event 与窗口外观兼容尚无真机结论；应在 15.6 设备以签名包复测启动、菜单、物理落点、保存／关闭和 SSH 项目文件身份。**不作为当前 27.2 验收的失败，但不能宣布最低系统全验。**
2. **Finder 系统上下文与 Dock**：P4 最新构建尚未逐个通过实际 Finder「打开方式」、设置 Bailey 为默认程序后的双击、Dock 图标物理文件/目录投放；P2 对系统右键／Dock 已有旧版 E2E，P4 使用相同 `kAEOpenDocuments` 且本轮 `open -a` 及真 Finder 部分落点已证，但**不能替代最新版本逐入口真机重测**。需要独占图形会话、明确观察接收 PID/窗口/原生 FileTab 和源 SHA。
3. **真实 Finder 其它落点／多窗／主题组合**：真实编辑／Diff／Git／浏览器工具栏、空组和非选中组、Files 目录行／文件行／根标题、混合目录/文件一批、两个独立 App 窗口焦点、窗口关闭时迟到 provider、暗/亮／中英文／窄宽／触控板的全部物理组合未在最终 P4 进程逐一点击拖放。正式 Bailey PID 59877 已在使用，共享鼠标／系统菜单／同 Bundle ID 的 Launch Services 可能误操作用户数据；不能擅自关闭正式 App。底层及原生 `NSWindow` 测试验证组所有权与拒绝错目标，P3 某些落点实际真鼠标测过；这仍非完整独立 App E2E。**需安全隔离 GUI 登录会话，或用户明确空出前台后补测。**
4. **真实 GUI 错误提示和复杂输入**：无项目文件投递、不可读文件／目录、部分失败批次、二进制/5 MiB 超限对话框、包目录、系统文件别名及权限在请求和读取之间变化时的用户可见错误 Sheet，未在安全的独立 GUI 中逐项观察。`WorkspaceIdentityTests`、`FileTabTests`、NativeUI 组件测试覆盖现有错误判定／内容限额，**不等于原生提示已经 E2E 验证**；应在独占会话逐个触发并检查错误 Sheet、取消及后续继续操作。
5. **远端混合的完整图形交互**：授权 Windows SSH 的六项真后端测试已过，但“固定/动态 SSH 项目中由 Finder 打开 Mac 文件并在 GUI 保存、重启、断线再连接”的全部原生交互没有在专用前台完成；项目文件身份和保存有真实本地字节/受控后端测试，仍需独占 GUI + 授权专用远端主机补测，严禁使用用户长期 SSH master。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：本机**所有已安全执行的实现路径及新增缺陷**有代码、真实原生/系统落点、Red→Green 和授权远端最终副作用证据；**470/0/0、构建验签、整包安装及 T1~T3 提交审查均通过**，没有未解决的确定性实现 finding。本结论**仅涵盖当前环境可完成的阶段交付，不表示最低 15.6、所有 Finder/Dock 物理 E2E 和全部外观／多窗组合已验收**；上述独占 GUI/新系统条件应另补。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：上述 5 类有条件的真实 GUI/最低系统补验尚缺；已有模型、原生、真 Finder 部分落点与真 Windows SSH 证据降低回归不确定性，但不能消除未测运行环境风险。正式 Bailey 已整包安装最新签名构建，当前运行进程仍加载原有代码，待用户自行退出再启动后新功能生效。没有远端 Git push/PR，也未留下本轮安装备份。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
