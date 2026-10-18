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
- **P4-T3 · `b426b30` + `b4e29bc`**：前者修正失效 `(projectID, groupID)` 异步投放禁止回退，补 A→B→A、空组、52+、无项目等测试；后者修复 Finder 新文件权限、目录权限、FIFO 特殊文件，新添 4 项回归并同步 `docs/features/projects.md`。`plan-p4.md`、`todo.toml` 及 `audit-p4.md` 已按用户后续明确要求在 `5d5a41e` 单独提交，不属于 P4 功能实现提交。

## 发现项

## 发现 F-05

- 任务：`P4-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift:220,289`
- 摘要：`两项 Finder XCTest 名称仍描述 P1 的 pinned-file 与最深目录选择策略，但断言已切换为 P4 当前项目语义`
- 风险：`测试名称与真实断言互相矛盾，后续审查或重构容易据旧名称错误恢复按目录建项目行为`
- 预期修复：`仅按现行行为准确重命名两项 XCTest，不改变断言、历史提交或应用逻辑`
- 验证：`make test ONLY_TESTING=BaileyTests/WorkspaceIdentityTests; git diff --check`
- 解决证据：`Commit effaf46，准确重命名两项与 P4 当前语义矛盾的测试名称；针对性 make test 24/0 退出0，完整 make test 472/0/0 退出0，make build + codesign 严格验签退出0；测试断言和应用逻辑未变。`


## 发现 F-04

- 任务：`P4-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/Components/WindowChrome.swift:33`
- 摘要：`新建空项目窗口在离屏渲染后挂载时丢失 NSWindow 绑定，添加文件夹按钮及菜单无响应`
- 风险：`空工作区无法添加第一个项目；File 菜单依赖 focused window 也可能误路由，Finder 跨窗口验收无法继续`
- 预期修复：`保留原窗口拥有者与 NSWindowDelegate 转发，改由 NSView.viewDidMoveToWindow 在真实装入窗口时同步调用 Coordinator.attach，删除一次性 runloop 挂载检查`
- 验证：`旧实现 WorkspaceWindowCloseTests 延后装配用例失败，修复后3/3通过；独立签名 Bailey 第二窗口真实点击 Add Folder 原生 Sheet 并成功加入 Project C；make build 和 Windows SSH 全量 make test`
- 解决证据：`Commit 0398a24; native Red failed prior attachment path; Green WorkspaceWindowCloseTests 3/3; make build and strict codesign PASS; SSH full make test 472/0/0 PASS; real two-window Finder NSOpenPanel, cross-window buffer reuse, and no-project Finder drop error E2E PASS on macOS 27.2.`


- **已解决的真实缺陷 1（P4-T3 / High）**：对新 Finder 文件只做 `fileExists` 验证，`chmod 000` 文件会创建无法读取的编辑标签；混合批次同时影响合法邻居的用户结果记录。`WorkspaceIdentityTests.testFinderUnreadableFileRejectsNewTabButOpensValidNeighbor` 原版失败，现由唯一文件接收入口拒绝新建并允许合法项继续，且不破坏已有打开标签。
- **已解决的真实缺陷 2（P4-T3 / Medium）**：不可读取／遍历的目录被 `addLocalItems` 添加为无法浏览的 Project；`testFinderUnreadableFolderCannotBecomeProjectOrMaskValidFolder` 原版失败；现目录添加与 Finder 文件夹两处入口共用可读／可遍历约束。
- **已解决的真实缺陷 3（P4-T3 / High）**：命名管道等非普通文件仅因路径存在就进入 `FileTab`，后续读取可能阻塞；`testFinderNamedPipeDoesNotCreateEditorThatCouldBlockOnRead` 原版失败；现新文件校验实际目标的普通文件类型。
- **四个已发现的可复现缺陷均已解决；F-04 已有 Red→Green、代码提交、本轮 472 项全量回归与双窗 GUI 验收。** 未执行的其它原生 E2E 不得冒充通过；也不能把受工具前台、锁屏和 Finder 多选影响的操作当成产品 Bug。

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
- **安装与用户保护**：最终签名 Debug `Bailey.app` 先同卷 `/Applications/.bailey-p4-install.qyPKHM` 完整暂存、验证签名与哈希，再整包替换；现有正式包及新包严格验签成功，安装后二进制 SHA-256 与构建一致 `fd05597363ffc87eefe704df6781cab448722be7f9384f7a3328e1c3f1ea542e`。仅临时空目录由 `rmdir` 清理；正式运行中的 Bailey PID **59877 保持不变**，未退出／启动／重启。安装成功不等于旧进程已加载新逻辑，须用户自行正常重启生效。未推送／未合并；Feature 文件随后按用户要求在 `5d5a41e` 独立入库。
- **功能文档**：`docs/features/{projects,dock,editor,session-restore,files,ssh,command-palette}.md` 与 `docs/{ui,testing}.md` 按真实职责记录项目范围、原生菜单、窗口与 Git/Files 根、Local vs SSH、保存和隔离；`README.md` 中入口对齐。`docs/features/projects.md` 在本次修复提交同步说明普通文件／目录权限、不抛弃已开缓冲。对应文件、索引和文档引用均实际存在，历史 P1～P3 审计不被改写为 P4 的新 UI 成功记录。

### 无法在当前环境完成的实际 E2E（不冒充通过）

1. **Finder 系统上下文与 Dock**：P4 最新构建尚未逐个通过实际 Finder「打开方式」、设置 Bailey 为默认程序后的双击、Dock 图标物理文件/目录投放；P2 对系统右键／Dock 已有旧版 E2E，P4 使用相同 `kAEOpenDocuments` 且本轮 `open -a` 及真 Finder 部分落点已证，但**不能替代最新版本逐入口真机重测**。需要独占图形会话、明确观察接收 PID/窗口/原生 FileTab 和源 SHA。
2. **真实 Finder 其它落点／多窗／主题组合**：真实编辑／Diff／Git／浏览器工具栏、空组和非选中组、Files 目录行／文件行／根标题、混合目录/文件一批、两个独立 App 窗口焦点、窗口关闭时迟到 provider、暗/亮／中英文／窄宽／触控板的全部物理组合未在最终 P4 进程逐一点击拖放。正式 Bailey PID 59877 已在使用，共享鼠标／系统菜单／同 Bundle ID 的 Launch Services 可能误操作用户数据；不能擅自关闭正式 App。底层及原生 `NSWindow` 测试验证组所有权与拒绝错目标，P3 某些落点实际真鼠标测过；这仍非完整独立 App E2E。**需安全隔离 GUI 登录会话，或用户明确空出前台后补测。**
3. **真实 GUI 错误提示和复杂输入**：无项目文件投递、不可读文件／目录、部分失败批次、二进制/5 MiB 超限对话框、包目录、系统文件别名及权限在请求和读取之间变化时的用户可见错误 Sheet，未在安全的独立 GUI 中逐项观察。`WorkspaceIdentityTests`、`FileTabTests`、NativeUI 组件测试覆盖现有错误判定／内容限额，**不等于原生提示已经 E2E 验证**；应在独占会话逐个触发并检查错误 Sheet、取消及后续继续操作。
4. **远端混合的完整图形交互**：授权 Windows SSH 的六项真后端测试已过，但“固定/动态 SSH 项目中由 Finder 打开 Mac 文件并在 GUI 保存、重启、断线再连接”的全部原生交互没有在专用前台完成；项目文件身份和保存有真实本地字节/受控后端测试，仍需独占 GUI + 授权专用远端主机补测，严禁使用用户长期 SSH master。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：本机**所有已安全执行的实现路径及新增缺陷**有代码、真实原生/系统落点、Red→Green 和授权远端最终副作用证据；**470/0/0、构建验签、整包安装及 T1~T3 提交审查均通过**，没有未解决的确定性实现 finding。本结论**仅涵盖当前环境可完成的阶段交付，不表示所有 Finder/Dock 物理 E2E 和全部外观／多窗组合已验收**；上述独占 GUI/新系统条件应另补。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：上述 4 类有条件的真实 GUI 补验尚缺；已有模型、原生、真 Finder 部分落点与真 Windows SSH 证据降低回归不确定性，但不能消除未测运行环境风险。正式 Bailey 已整包安装最新签名构建，当前运行进程仍加载原有代码，待用户自行退出再启动后新功能生效。没有远端 Git push/PR，也未留下本轮安装备份；按用户要求已独立提交 P4 Feature 记录。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-18 左半屏后续 E2E 与用户系统范围更新

用户现已明确：只要求**当前 macOS 27.2 机器**，不要将缺少 macOS 15.6 真机当作 P4 未完成条件。15.6 仍是工程 deployment target，仅没有该系统的真机证据；不是本轮 Gate 的补验项。

用户要求把本地 Feature 记录也提交 Git，已生成 `5d5a41e`（仅 `plan-p4.md`、`todo.toml`、`audit-p4.md`），未推送。追加测试独立 Bailey PID `97058` 和专用 Finder 窗口均保持在显示器左半屏（右边界 x=1680），正式 Bailey PID `96141` 未终止。新增当前系统上**实际验证**：Finder→空编辑区显示真实正文；菜单添加 Project B；Open File 跨项目复用 A 原缓冲；Finder→Git 面板文件直接变编辑标签；Finder→Files 复制最终字节且无立即额外标签；重复复制出现原生非覆盖错误 Sheet，副本哈希不变；Finder→顶部标签栏打开新文件且显示正文。完整触发前提、文件及窗口证据见 `plan-p4.md` 末尾“本机左半屏补充 E2E”。

**待确认而不是 finding**：后续观察到 Project B 消失并伴随标签重新归属，但未核对可靠的鼠标源窗口和修改瞬间，不能认定 Bailey 自动删除项目；该过程不得标记成功或归因。随后 GUI 会话锁定，`peekaboo` 报 `CAPTURE_FAILED`，物理 Finder 拖放、双窗口／Dock 和原生错误组合无法安全继续。**这不推翻已完成的 470 项自动测试与上述可靠 GUI 操作，也不代表新要求的全部 E2E 已完成**。屏幕解锁后应在新的受控会话补验该异常及四类尚缺 GUI 组合，不触碰正式 App 或屏幕右半边。

## 2026-10-18 第二窗口挂载根因修复与现场验收

- **Red**：在当前 Mac 左半屏创建一个正常项目窗口和一个新建的无项目窗口。新窗口的「Add Folder…」按钮和 File 菜单可见，但实际点击后没有原生 Sheet。沿 `ContentView → TerminalManager.chooseFolders → WindowChromeAccessor` 发现窗口管理者缺少 `NSWindow`。新增 `WorkspaceWindowCloseTests.testEmptyWorkspaceAttachesToWindowWhenHostingViewWasRenderedOffscreen`：先离屏渲染 `ContentView`、让一次性 dispatch 执行，再把宿主视图挂入真实 `NSWindow`；旧实现持续 6 秒无法满足附着条件，Red 证据 `/tmp/bailey-p4-red-newwindow.log`。这不是加延迟重试能解决的事件时序问题。
- **Green／清理**：`WindowChromeAccessor` 改用 `WindowChromeAttachmentView.viewDidMoveToWindow` 接收 AppKit 真正的安装事件，直接交给原有 `Coordinator.attach`；删除旧的一次性 async 检查，保留同窗口防重复和 NSWindowDelegate 原转发。补第二个原生测试：已有项目窗口、延迟安装的空项目窗口同时存在，各自文件夹 Sheet 只出现在所属窗口，互不影响。精简为 `weak coordinator` 后 `WorkspaceWindowCloseTests` **3/3，0 失败**，日志 `/tmp/bailey-p4-final-native-window-target.log`。同步 `docs/features/dock.md`。
- **真实已签名 App E2E**：完整退出本轮自行启动的隔离旧 PID 97058，使用相同隔离 UUID 在已重新构建的签名 App 内重新启动（PID 6079），重新归位两个 Bailey 窗口至屏幕左半边。实际点击新无项目窗口的「Add Folder…」→ `NSOpenPanel` 真 Sheet 被 AppKit/辅助功能看到（为守左半屏将宿主移动至 x=675，原生 Sheet 跟随至 x=610..1570）→ 原生选中 `Project C` 并点击 Add → 最新会话快照和实际 AX 项目行均证实新窗口只拥有 Project C、原窗口仍拥有 A/Finder Sources/B。随后在 C 窗口原生「File → Open File…」选择 B 窗口已打开的 `drag-projects.swift`，Bailey 真正把**原 B 窗口**恢复为 key/main、原 B 标签不重复，C 不增加标签；之后在 C 中选择其首次打开的 `inside-C.swift`，仅 C 新增一个标签且原生编辑器显示 `let cUnique = 42`。两个 Bailey 主窗口坐标均满足 x+width≤1680。
- **仍待复核**：此前未消除的窗口遮挡、Finder 多选干扰已在单一选中源文件的物理 E2E 中排除；无项目窗口的错误 Sheet 现已验证通过。Finder「打开方式」与 Dock 图标属于同 Bundle ID 的 Launch Services，若它指向正式 Bailey 会影响用户资源，不能为验收改系统默认打开应用。暗/亮、触控板、部分浏览器/Git 组合和 SSH 项目的所有图形联动尚无独立真实 E2E；真实 Windows SSH 自动回归不替代 UI。只有当前 macOS 27.2 是用户要求的真机环境，不再要求 15.6 设备。
- **最终回归结果**：`make build` 已完成并严格验签，日志 `/tmp/bailey-p4-window-attach-final-build.log`；含授权 Windows SSH 的最终 `make test` 完整退出 0，**472 项 / 0 失败 / 0 跳过**、`** TEST SUCCEEDED **`，用时约 838 秒，日志 `/tmp/bailey-p4-window-attach-final-test.log`。生产修复、两项新增窗口测试与 `docs/features/dock.md` 已由 `0398a24` 单独提交；F-04 已标记 Resolved。未将本轮 Debug 签名包覆盖安装到正式 `/Applications/Bailey.app`，也未推送。

## 2026-10-18 本轮最终补验与 Git 结论

- **验收环境**：用户要求仅使用当前 macOS 27.2 真机；没有 macOS 15.6 真机，因此既不把它作为本阶段阻塞，也不声称该旧版系统 GUI 已通过。工程最低 deployment target 不变。
- **真实完整回归**：修复后 `make build` 退出 0，`** BUILD SUCCEEDED **`，严格 `codesign --verify --deep --strict` 成功；`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test` 退出 0，`** TEST SUCCEEDED **`，**472 项／0 失败／0 跳过**，耗时约 838 秒。日志 `/tmp/bailey-p4-window-attach-final-{build,test}.log`。`WorkspaceWindowCloseTests` **3/3**、`WorkspaceWindowIsolationTests` **13/13**，含真实 SSH 的 GitExternalRefresh 也通过。
- **真实双窗验证**：签名隔离 Bailey 的新空窗口因旧挂载时序无法打开原生文件夹选择器，F-04 修复后实际点击 `Add Folder…` 弹出 NSOpenPanel，选择 Project C 后只在新窗口增加 Project C，不改原窗口 A/Finder Sources/B；随后在 C 窗口打开 B 已有文件，App 自动切回原 B 窗口／原标签，C 不新增缓冲；在 C 中首次打开 `inside-C.swift`，只在 C 新增标签并显示真实文件正文。关闭仅用于隔离测试的 C 后，新窗口恢复到无项目状态。
- **无项目物理 Finder 错误 E2E**：Finder `windowID=154106` 中经真实辅助功能确认**唯一选中** `new-import.txt`，从 Finder 真实拖入无项目的 Bailey 窗口，原生 NSAlert 实际显示 `Add a project folder before opening files.`，详情只有 `new-import.txt`；确认后快照显示该窗口继续 **0 项目／0 标签**，其他窗口已有 A/Finder Sources/B 和标签全部保留，源文件哈希未变。已排除此前 Finder 9 项多选与双窗重叠造成的不确定性。
- **屏幕边界**：本轮两个测试 Bailey 主窗口、Finder 和真正弹出的 Sheet 均满足 x+width ≤ 1680（显示器宽 3360）；测试资源均为 `/tmp/bailey-p4-left-e2e-hazgvu6v` 内的人工数据，未移动/退出正式 Bailey。修复代码已提交 `0398a24`，审计状态 F-04 `Resolved`。
- **Gate**：可复现的四项实现缺陷均已修复，当前 macOS 上的上述真 GUI 场景和含 SSH 全量测试通过。但 Finder「打开方式」/默认双击、实体 Dock 图标文件拖放、全部明暗语言与多分屏排列和 SSH 端到端 GUI 组合仍没有本轮逐项实测证据，必须诚实标记为**尚未全验**；本阶段的 `Go` 只涵盖已经安全执行且有实测证据的范围。本轮计划／审计文件独立提交 Git，不擅自 push。

## 2026-10-19 PR #34 追加原生验收（当前 Mac）

本轮只使用 macOS 27.2、工作树已验签 Debug Bailey、隔离 `BAILEY_UI_TEST_RUN_ID=3389fc44-b4e7-4a93-85ea-ada06e4c59d2` 与 `/tmp/bailey-p4-left-e2e-hazgvu6v/` 内测试素材。显示器本轮报告为 1800×1169 pt，相关测试 Bailey 主窗口均为 `x=12,width=860` 或 `x=15,width=810`，保持在当前显示器左半屏（`x+width≤900`）。这与前一轮 3360 pt 显示状态不同，不能沿用旧坐标。**没有更改系统默认文件关联，未退出／修改正式 Bailey。**

- **Finder / 系统文件入口**：Finder「打开方式 → 其他…」原生菜单曾明确选择隔离 Debug Bailey、未勾选「始终以此方式打开」；当事件落到**无项目窗口**时，实际原生提示先添加项目，项目和标签数量不变。通过 `open -a <隔离 Bailey.app> <文件>` 将项目根外 `real-open-with.swift`、`dock-p4-only.md` 打开到 Project B，实际增加文件标签、源 SHA 不变、文件关联仍指向原来的默认应用；重复打开的跨窗口去重证据见前述双窗口小节。另用 Finder AppleScript `open ... using <明确的 Bailey.app>` 时命令返回成功，但未取得新标签的最终态，因此**不算 Finder 右键有项目场景已通过**。其间外部桌面操作改变 Finder selection，原生应用选择面板消失，不能归因于 Bailey。
- **异常文件和恢复的实际编辑器 UI**：`oversize-5MiB-plus1.txt`（5 MiB + 1 byte）真正打开到 Project B，原生文件标签出现，但正文区域显示 `File is too large to open`；`invalid-utf8.bin`（含无效 UTF-8 和 NUL）显示 `Binary file`。随后打开可读的未知扩展名 `odd.unknown`，原生 Text Editor 恢复并显示 `unknown extension but UTF8`。没有创建新项目；直接比对源 SHA-256，异常文件和恢复文件的磁盘内容未改变。**这是编辑区占位提示，不是 NSAlert 错误 Sheet**，不得混淆。
- **主题 × 语言**：同一隔离 App 真实先后以浅色、深色和 `-AppleLanguages (zh-Hans)`／`(en)` 启动，实际检查原生窗口菜单、Projects/Files 和文件编辑器，四种组合的截图仅保存在测试目录 `theme-light-main.png`、`theme-dark-main.png`、`language-zh-main.png`、`theme-light-zh-main.png`（未提交仓库）。中英文菜单分别展示「文件／设置…」和 `File/Settings…`，工作区显示「项目／文件管理器／没有已打开的项目」与 `Projects/File Manager/No open projects`；已有 Project B 标签／文本随会话恢复。正式 Bailey 的 TOML 设置哈希未改变、系统语言选择未被覆盖；原系统偏好 plist 的整体哈希因窗口状态变化，**不宣称字节完全不变**。此结果覆盖实际启动／恢复，不等于所有深浅／语言／多分屏／触控板拖放笛卡尔积均已实测。
- **SSH 真实 GUI 本机／远端隔离**：隔离 Bailey 的 SSH `windows` 项目 `/tmp/bailey-p4-gui-fRmd2B` 有两个名字和 POSIX 路径相同的 `remote-p4.txt` 标签，但一个使用 SSH 后端、一个使用 Mac 本地后端；实际点击远端标签的原生 Text Editor 显示 `remote-saved-chang`，点击本机同路径标签显示 `mac-local-saved-change`。独立使用 `ssh -T -o BatchMode=yes -o ControlMaster=no -o ControlPath=none windows` 读取 Windows 侧文件，同时直接读取 Mac 侧文件；远端 SHA-256 为 `38afb178367be2539702db6e286a8f765d37ea1ece5261dd4172bb880135e647`，本机为 `f13ddde8865055afbbf7ecf3f3779576e824800002ac8a0b4845d9a8d3c51c44`，内容与 GUI 各自一致。会话快照还确认同 SSH 项目中 `mac-in-ssh-project-p4.swift` 为本机标签。**此处实测读取及身份隔离，不冒称本轮重新执行了远端保存／GUI 断网重连**；授权 Windows 后端六项真主机测试已在上述 472 项全量回归中通过。
- **Dock 与 Finder 物理剩余条件**：Dock 在尝试独占测试时又出现另一个工作树启动的同 `chiimagnus.bailey` 进程，后来正式 `/Applications/Bailey.app` 也再次运行；无法可靠指定物理 Dock 落点的接收 PID。为避免把文件投递到别人的 App，**没有执行这次 Dock 图标拖放**。Finder「打开方式」的**有项目正向点击**也因 Finder 全局选择／Space 前台被其它应用改变而未完成；`open -a` 及 Finder AppleScript 不能冒充它的完整鼠标路径。某次 Peekaboo 只能取得空窗口的 `Application-scoped partial semantics`，是 Space／AX 目标不可辨认时的测试工具限制，不能直接定性为 Bailey Bug。
- **范围与待办**：当前 Mac 上 Finder 右键正向打开、Dock 图标物理拖入、部分组合式分屏／触控板、SSH GUI 真断线恢复与 Mac 保存到远端的全过程，仍需要**可独占的安全图形会话**并核对实际接收 PID、真实标签及磁盘最终字节。系统默认应用的修改／恢复不是本阶段必要操作；没有 macOS 15.6 真机，按用户决定不列为当前验收阻塞。现有 `make build` 严格签名与授权 Windows SSH 全量 `make test` **472/0/0** 的历史日志仍然有效；本轮只添加原生 E2E 证据，**未修改生产代码，不冒称重新运行全部 XCTest**。

## 2026-10-19 本轮独立审计结论（覆盖先前执行者的 Gate 判断）

- **P4-T1 · `1121e74`**：当前 `openExternalLocalItems` 先按解析后的本机真实路径查找已有 `FileTab.workspaceIdentity == nil`，未命中才开在接收窗口原选中 Project；`Project.openLocalFile` 使用 `LocalWorkspaceBackend.shared`，不会把 Mac 文件送给 SSH。既有 `SessionStore.TabSnapshot.localFile` 保持新旧快照兼容；`WorkspaceIdentityTests`、`SessionStoreTests` 和多窗口集成均实际执行。
- **P4-T2 · `6269ac9`／`b426b30`**：系统文件菜单 `⌘O` 与 Dock 各组「＋」共用文件型 `NSOpenPanel`，项目添加共用目录型 `NSOpenPanel`；异步组目标失效时拒绝越界投放。核对生产源码无 `chooseLocalItems`、`filesByParent`、`explicitDirectories`、`documentProject` 或新建 Mac 单文件 Project 分支；仍有消费者的 `pinnedFile` 是历史快照／显式 SSH 项目，不删除。
- **P4-T3 · `b4e29bc`／`0398a24`**：新 Finder 文件的普通文件／可读性门槛，以及空窗口 `NSView.viewDidMoveToWindow` 附着回调，均连入生产路径；权限、FIFO、延迟挂载、真正 `NSWindow` 文件选择器及关闭路径有测试。新独立发现 **F-05 / Low**：两项 XCTest 名称仍宣称 P1 的旧项目策略，而断言验证 P4；按准入规则先登记后仅更名，提交 `effaf46`，不更改实现或断言，**已 Resolved**。
- **本轮重测事实**：macOS 27.2、Xcode 27.2。带 `BAILEY_P4_TEST_SSH_HOST=windows` 的完整 `make test` 在重命名前实际运行 **472 项、0 失败、0 跳过、整体退出 0**（`build/audit-logs/finder-audit-test.log`）；更名后 `WorkspaceIdentityTests` **24／24 通过、退出 0**（`build/audit-logs/finder-f05-focused-test.log`）；随后 `make build` **退出 0、严格 `codesign` 验签通过**（`build/audit-logs/finder-audit-build.log`）。19 个原分支提交 `git show --check` 全部通过，`todo validate`、`git diff --check` 通过。**不得声称更名后重新运行了整套 472 项**，尽管测试体没有变化。
- **边界与内部跳过**：`SSHFileTreeLiveTests` 日志有 `P4_LIVE_SYMLINK_UNAVAILABLE status=1`，表示该次真实 Windows 环境未成功建立该特定符号链接测试前提，**不把整体 XCTest 的 0 skipped 当作这项内部前提也测到了**；本机符号链接拒绝与重复标签有独立测试。当前轮次**未实际完成** Finder「打开方式」有项目正向点击、Dock 图标物理文件投放、全部分屏／触控板位置组合和 SSH GUI 真断线恢复。之前证据不能冒充本次复测；同 Bundle ID 多进程、前台窗口归属不确定时不得发送可能落入正式 Bailey 的鼠标／文件事件。macOS 15.6 真机不属于用户要求的本轮环境，不列为缺陷。
- **独立 Gate**：**自动测试、构建验签和可核查的源码不变量为 Go；完整 P4 真实 GUI 验收为 No-Go（尚未全部实测，不代表发现新生产 Bug）**。在可安全独占且只使用屏幕左半边的图形会话中，核对真实接收 PID、窗口、文件标签、目标副本／源 SHA 后补齐上述具体操作；授权 Windows SSH 图形断线／恢复另行核对最终本机与远端文件字节。不得为测到绿色而退出、替换或误操作用户现有 App。本轮仅提交了测试更名，计划与审计文件仍是本地待提交记录，未 push。
