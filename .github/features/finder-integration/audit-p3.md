# Audit P3 - finder-integration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/finder-integration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P3-T1 验证原生拖放事件所有权
- [x] P3-T2 窗口拖放与终端目标接入
- [x] P3-T3 Files 专用落点隔离与原生验收
- [x] P3-T4 Projects 与标签栏按区域路由及完整验收

## 任务到文件的映射

- P3-T1 · 调查，无代码 commit：`plan-p3.md#p3-t1` 原生 Finder pasteboard 与目标实验；逐项调查 `ContentView`、`WorkspaceDockView`、`PanelContentView`、`BaileyTerminalView`、`BrowserView`、`FileTreePanel`、`ProjectsPanelView`、共享树及 Vendor/STTextView。此任务在 `todo.toml` 记录明确的无 commit 原因；真实矩阵指导 T2、T3，不把历史禁放行为继续当当前目标。
- P3-T2 · `69cc3b5`：`ContentView.FinderWindowDrop`、`WorkspaceDockView` 和 `PanelContentView` 按原生目标挂通用 opener；`TerminalSession.acceptsLocalFileDrop` 与 `BaileyTerminalView` 保护 PTY 控制字符及固定/动态/前台/exec SSH；`FileTreePanel` 修复远端虚假 Mac fileURL 源头；`BrowserView` 不抢 WKWebView 正文上传；`WorkspaceIdentityTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`、`README.md` 与相关 browser/dock/files/ssh/terminal/testing 文档。
- P3-T3 · `c7f64ee`：`FileTreePanel.FileTreeImportDrop` 目标目录行/文件行/根标题和树留白；`ToolPanelView` 项目与根身份绑定、唯一 `FinderWindowDrop.receive` 取 URL；`FileTreeModel.importFromFinder` 校验本机根和刷新；`LocalWorkspaceBackend.copyFromFinder` 原子无覆盖发布（先在同卷系统替换目录拷贝，再 `renamex_np(RENAME_EXCL)`）；`Workspace.xcstrings` 中英错误提示；`FileTreeTests` 覆盖目录残片、并发竞态和符号链接；`docs/features/files.md` 同步。
- P3-T4 · `a85d10c`：`WorkspaceDockView` 的 Projects 落点调用 `TerminalManager.addLocalItems`；普通标题、空组、编辑/Diff、Git 面板和浏览器工具栏向唯一 Finder 路由传 `(projectID,groupID)`；`TerminalManager.openExternalFiles`、`openExternalLocalItems` 保留跨窗原 FileTab、只把新标签放入对应接收组；`Project.openFile(inGroup:)` 先预置分组再添加 Tab，解决空组消失；`WorkspaceWindowIsolationTests` 增加 Projects 重复添加、非选中分屏、空组及跨项目原标签测试；同步 `README.md`、`docs/features/{dock,projects}.md`、`docs/{ui,testing}.md`。

## 发现项

逐一核查 P3 四项及其直接调用方、异步 provider、原文件打开后端、Dock 分组、FileTree 真实磁盘复制与错误回调、原生 Ghostty/WebKit 消费者，并与实际 Finder E2E、原生 XCTest 和当前功能文档对照。未发现达到可复现缺陷、可达不变量违背或平台契约直接冲突准入门槛的**未解决 finding**。历史 T2 曾写「Files 行禁放、留白打开、Projects 普通打开」，是 T3/T4 用户扩展需求以前的真实 Red/Green 记录：已修正 `plan-p3.md` 首页为当前目标并标记旧段落历史语境；未擅自删除历史验证或当作生产缺陷。

下列环境缺口单独在验证日志登记，不凭猜测增添产品缺陷或安全补丁；本阶段完成不等于这些系统组合已经真机执行。

## 修复日志

- T2 `69cc3b5` 解决通用接收器抢 WebKit 上传、SSH 本机 URL 误发与 Files 远端伪 URL；T3 `c7f64ee` 解决 Files 导入时源数据保护、批次部分失败留下残片及冲突 Sheet 不可见；均沿原所有者修复且分别提交。新 P3-T4 Red 证明原打开路径没有精确 Dock 组信息，新增目的地后由 T4 `a85d10c` 完成跨组／空组正确放置；44/44 针对性与全量 455 项成功。
- 审计过程中仅将已过时的 P3 首页 Goal、Non-goals、Acceptance 统一为最终用户要求，保留 P3-T1/T2 历史实验事实；本地 feature 文档不进入 Git 提交。当前源码未发现无消费者的新抽象、第二套 Finder loader／队列、透明全窗 hover 补丁或备用 SSH→Mac 写入分支。

## 验证日志

- **最终全量**：`make build DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder` -> exit **0**，`** BUILD SUCCEEDED **`，Makefile 严格 `codesign --verify --deep --strict` 成功；`make test` 同参数 -> exit **0**，**455 tests、0 failures、6 skipped**，`** TEST SUCCEEDED **`，`/tmp/bailey-p3t4-final-v2-{build,test}.log`，xcresult `build/DerivedData-finder/Logs/Test/Test-Bailey-2026.10.18_14-44-34-+0800.xcresult`。`git diff --check`、`git show --check` 三个提交、`todo validate` 和 `phase-complete --phase p3` 全部通过。
- **针对性与根因证据**：T2 完整 446 项、0 失败/6 SSH skip；T3 原子目录导入、安全并发、软链及目标冲突的 `FileTreeTests + TreeRowHitTestingTests` **22/22** 通过，包含先失败再修复的权限复制残片 Red；T4 新增分屏目标组/空组/跨项目和 Projects provider 本机测试与 `PaneRetentionTests`、`DockWorkspaceTests`、`WorkspaceIdentityTests` 组合 **44/44** 通过；之后在**所有代码修改结束后**重新运行上述 455 全量，不使用中断的旧测试作为最终证据。
- **真正 Finder E2E**：已在独立签名测试 Bailey 中拖到 Files 目录行、文件行、根标题及留白，分别核对实际目标的文件/文件夹、副本 SHA/`cmp`、Files AX 树节点、源项保留以及项目和 FileTab 数量；同名冲突原生 Sheet 通过 AX 看见真实标题、具体文件名与 OK，旧目标哈希保持；原子发布后再次将 Finder 文件拖进根并查无公开临时目录。实际 Finder→Projects 空白与项目行分别生成 `pinnedFile` 项目而不改旧项目，Finder→Projects 文件夹产生 0 Shell 的目录项目；Finder→顶部标签栏新文件可读取原生编辑正文、重复文件复用原标签，源字节未变。P3-T2 独立原生 Finder 测试核对 WebKit 上传只选中网页文件、无多余 FileTab；本机 Ghostty 只插转义路径、无 Return；固定/动态及独立前台 SSH 由真实受控进程夹具和原生/单元测试证明拒绝。测试临时样本 `/tmp/bailey-file-import.bCBHAq` 仍在，不触及用户仓库。
- **全部可行适用条件**：文件/目录/混合批次、重复、相同/不同父目录、目标目录/文件行、根/子目录、Unicode/空格、同名冲突、源项缺失、无权限文件、文件夹递归自身/子级、软链/失效链接、并发同名复制 12 竞争者恰有一成功、复制失败不得留半成品、只读远端和路径超出本机 root、刷新可见目录与原始源字节；跨项目本机目录/单文件 pinned 项目、同路径不同 SSH 主机、选中组/非选中组/空组、双窗口/窗口关闭晚到 provider、跨窗已有 FileTab 不迁组且不多开可写缓冲；终端控制字符、Ghostty 真 PTY、前台/exec SSH、浏览器网页上传与工具栏、Files 外拖、本机编辑器等。对应底层、原生 XCTest、真实 Finder 三层证据不能互相偷换。
- **有界环境缺口 1**：本机是 macOS **27.2**、Xcode **27.2**、最低 deployment **15.6**；没有 macOS 15.6 实机，不能独立证实该版本 Finder/SwiftUI Drop UI，影响最低系统真机兼容的确定性。已有针对 15.6 的 Swift 6 编译和当前系统真 Finder E2E；获得 15.6 主机后应重做 Finder→各实际落点、冲突 Sheet、WebKit/Ghostty 和签名/打开方式。当前系统交付不因此阻塞，不能写「15.6 已验证」。
- **有界环境缺口 2**：6 项需**明确授权专用 Windows SSH 测试主机**：`GitExternalRefreshTests` 1、`GitInteractiveRebaseTests` 1、`GitWorkspaceSSHTests` 1、`SSHFileTreeLiveTests` 2、`SSHGitRecoveryLiveTests` 1。未设置 `BAILEY_P4_TEST_SSH_HOST`，按套件跳过；不借用用户生产 Windows 主机/现有 SSH master 触发破坏性操作。替代证据为本机真实 PTY、受控进程事实和模拟断线/SSH 身份测试；获得授权专用主机后运行各真实联动测试。不是本次 Files 本机拷贝或普通 Finder 实际落点的已知失败。
- **有界环境缺口 3**：本次新增**跨分屏**精确 drop 的 DOM/hit 原生行为经实 `NSWindow`、`NSItemProvider<NSURL>` 及 44 项 XCTest 检查正确 DockGroup 和 FileTab；真实 Finder 鼠标在已有签名测试 App 上检查过单分屏顶部标签，但**没有在当前已启动的用户正式 Bailey 旁再次前台拖鼠标跨多分屏和切换暗/亮/字号**，以免抢用户窗口或改变偏好。需要可控独立图形会话后补测不同分屏标题/空组/编辑/Git/浏览器工具栏、暗亮及多窗口真实 Drag；现有真正 Finder 接收者和原生 Dock 所有者链已由其它 E2E 与 XCTest 分层覆盖，未发现可复现问题，不伪称全部真实 GUI 组合完测。
- **整包本地安装与生效边界**：完成 P3-T4 提交和 P3 Go 审计后，用同卷 `/Applications/.bailey-install.XXXXXX` 暂存完整 `Bailey.app`、严格验签后重命名替换 `/Applications/Bailey.app`，失败路径带旧包回滚；新包二进制 SHA-256 与最新 Debug 构建完全一致 `8a39f42da6cca3155ac1356c1cf256ad6ff62b1ec994961d6d45d73e6331a1dc`，Bundle ID 均为 `chiimagnus.bailey`，重签验收 0 失败，安装成功后删除本次旧包备份与暂存目录。正式运行的用户 PID `92710` 安装前后均存活，**从未退出、启动或重启用户 App**。注意其进程仍运行原加载版本，须用户自行重启后新磁盘包才在现有用户 GUI 生效；不能以磁盘安装冒称已经在正式进程测试了新功能。
- **文档/边界**：`README` 用户入口，`docs/features/{projects,dock,files,terminal,ssh,browser}.md` 各归自己的真状态，`docs/{ui,testing}.md` 维护交互与验收；共同的 `AGENTS.md`、架构及开发文档保持单一 Bundle ID 和签名，不引入安装或版本新策略。`idea.md` 和 `plan-p3.md` 改为当前目标，T1/T2 旧行为标历史；`todo.toml` 是唯一状态。Feature 资料按 Skills 默认为本地记录不入 Git。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：四项 P3 均有真实代码/调查交付、原子提交及阶段连续验收，当前 macOS 的真实 Finder 用户行为与分屏原生所属者链已覆盖、Build 严格签名及完整 455 项测试通过，无未解决的确定性阶段 finding；最低 macOS 15.6、授权 SSH 真机与不同分屏实鼠标组合缺口均如上明确限定，不将其冒称全部通过。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：最低 macOS 15.6 真机 Finder/Launch Services、6 项授权 SSH 主机联动和多分屏真 Finder 鼠标暗/亮模式组合未在安全可用环境中逐项执行；补验条件、实际替代证据与影响如验证日志。`/Applications/Bailey.app` 最新已签名完整构建已完成整包替换并验签 SHA 一致；**旧正式 Bailey 进程仍在运行，未重启，直到用户自行重启才生效**。无推送或 PR，Feature 计划／审计仅在当前本地工作树留存。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 正式 App 重启后的补充 Finder 验收（2026-10-18）

- **正式重启确认**：本机 `/Applications/Bailey.app` 的 `codesign --verify --deep --strict` 通过；二进制 SHA-256 与本 worktree 的最终 Debug 构建均为 `8a39f42da6cca3155ac1356c1cf256ad6ff62b1ec994961d6d45d73e6331a1dc`。通过 `NSRunningApplication.terminate()` 正常退出旧 PID `92710`、启动已安装程序，确认真正加载新二进制及窗口 AX；未用强制终止或修改用户工作区。验收结束后当前正式进程 PID `35737` 在运行，正常 UserDefaults 的原快照前后均为 **1 window / 3 projects / 29 tabs**，原生 AX 可见 `Projects` 与 `File Manager`；正式 App 已生效，不再是“待用户手动重启”。
- **严格隔离 E2E**：为消除恢复中的多窗口／不同 macOS Space 导致的目标坐标漂移，关闭本轮临时窗口，再在仅一个 Bailey 实例运行的条件下，使用**已安装同一正式包**启动 `BAILEY_UI_TEST_RUN_ID=B3B92DE0-D529-4DE9-A97C-FDC8679652EF` 独立快照（PID `32090`）。全部来源／目标只使用 `/tmp/bailey-restart-acceptance.XP3zuI` 下临时文件。Peekaboo Screen Recording、Accessibility、Event Synthesizing 均有授权；每轮真实 Finder 拖放前读取当前 Finder 图标和 Bailey 目标的 AX screen bounds，并检查两个原生窗口均在屏幕上，禁止以旧 screenshot 坐标进行试验。测试进程正常退出，未借用现有用户终端／SSH 会话。
- **File Manager 的实际落盘验收**：`file-row.dat` 从 Finder 落到压缩目录行 `target / deep` 后，真实目标 `workspace/target/deep/file-row.dat` 已出现且与源文件 SHA-256 均为 `4ef2ae3e117dc388474408ca010fe3d77fe4d122c616a4e44659819244017204`；`root-copy.py` 落在 `existing.txt` 文件行后复制到其父目录 `workspace/`；`second.md` 落在树留白后复制到根目录；整个 `FolderA` 落在目录行后 `target/deep/FolderA/nested.md` 完整存在且 `cmp` 与源一致。独立的 `one-selected.txt` 在明确单选和实时坐标下复制到 `target/deep/`，前后该项目 FileTab 数量相同、没有生成该文件标签。来源均保留。
- **真实错误提示**：Finder `copy-me.txt` 投到已含该名称的 Files 根目录，原生非阻塞 Sheet 的 AX 明确显示 `Couldn’t import some files or folders.` 和 `Already exists: copy-me.txt`，原目标／源文件 SHA-256 前后一致。弹窗只在独立测试 App 中关闭。
- **Projects 的实际副作用**：Finder 单文件 `first.swift` 投到 Projects 空白后新增独立 `pinnedFile=.../source/first.swift` 项目且仅一个该项目编辑标签；再次投同文件复用，不增加重复项目；`FolderA` 投到 Projects 后新增独立目录项目且该项目 `tabs=0`，未隐式复制到旧项目或启动 Shell。最后独立快照有原测试根、Pinned File 与目录共 3 项；正常用户快照仍为原 3 项。
- **工作标签栏**：Finder 从新建的目录项目 `FolderA` 拖 `nested.md` 到空中央分屏顶部标签栏，实际生成文件标签且持久化 Dock Group `0AD6D0CA-AF66-4CF0-9C40-906C3AF099FE` 中可观察到该标签；右侧 `File Manager/Git Manager` 分组原工具项保留。右侧另一个分屏的**物理 Finder 鼠标投放及暗／亮外观组合尚未得到可靠 E2E**：过程中 Finder 临时 Info 窗口和桌面 Space 可见性切换使 AX 观察失败，自动化在拖动前停止；不能以事件发送成功或 XCTest 代称通过。原生 `NSWindow` / `NSItemProvider` 的非选中/空组/跨项目测试 44 项通过仍是替代证据，而非真实 Finder 鼠标全部覆盖。
- **反例归属修正**：重启后最初两次拖放失败时，UI 窗口从 `(29,68)` 移至 `(0,39)` 而脚本仍使用旧全局坐标，目标实际落在不同 Files 行／不可见窗口；后改用单实例＋每次实时 AX bounds，压缩目录复制成功。**旧两次不计为代码缺陷或验收证据**。连续拖放期间 Finder 选择与原生自动化窗口竞争还曾污染独立快照；明确单文件验证后确认无额外标签，不能仅凭此前未控制选择的累积标签数量推断产品重复打开。
- **验收限制**：本轮没有改动源码，沿用已经验证的最终 `make build` 和 `make test` **455 项、0 failures、6 skipped**；未重新跑全套。macOS 15.6 真机、6 个获授权专用 SSH 实机用例和暗／亮多分屏真实 Finder 组合仍需相应测试环境。没有推送 PR；本次补充记录只保存在本地 Feature 审计文件。

## 2026-10-19 独立复核（P3 区域所有权及 P4 覆盖边界）

- **P3-T1 · 无代码提交**：该任务确为 Finder 粘贴板／原生接收者调查，`todo.toml` 的无提交原因与计划匹配。没有把实验误计作生产功能；本轮未重新执行全部物理 Finder 坐标实验，不冒充复现。
- **P3-T2 · `69cc3b5`**：当前 `FinderWindowDrop` 只在普通 SwiftUI 区域及浏览器工具栏接收文件，网页正文和 Ghostty 终端保留自己的拖放；`BaileyTerminalView.fileDropText` 整批拒绝控制字符，`performDragOperation` 只 `sendText`、不发 Return；`TerminalSession.acceptsLocalFileDrop` 区分固定 SSH、动态连接和手动 SSH 前台进程。远端 Files 行不再生成伪本机 `fileURL`。
- **P3-T3 · `c7f64ee`**：`FileTreeImportDrop → FileTreeModel.importFromFinder → LocalWorkspaceBackend.copyFromFinder` 仍是 Files 唯一复制路径。核对目录／文件行与根落点、目标属于本机、符号链接越界拒绝、后台复制到暂存目录及 `renamex_np(RENAME_EXCL)` 的原子不覆盖发布；`FileTreeTests` 实测源字节保留、目标副本、冲突、失败清理与 12 并发竞争。
- **P3-T4 · `a85d10c`**：`DockTabGroupView` 将实际 `(projectID, groupID)` 传给共享文件入口，当前 `Project.openLocalFile` 将新标签放入对应组，旧标签不迁组；跨窗、空组、晚到 provider 由 `WorkspaceWindowIsolationTests` 覆盖。P3 当时的 Projects 单文件新建 `pinnedFile` 行为已由 P4 替换，现为文件开标签、目录添加项目。
- **本轮自动回归**：`make test` **472 项／0 失败／0 跳过**、完整退出 0；`make build` 严格验签退出 0。P3 的历史真实 Finder 行／根／终端/WebKit 观察留作当时证据，**不是**本次最新版所有 GUI 放置组合均已重跑的证明。
- **独立 Gate**：P3 已实施的代码和安全副作用在当前静态／集成层未发现新的确定性缺陷，历史交付可保留；当前版本的 Finder 精确物理落点、双窗口和主题组合仍应纳入 P4 未闭合的 GUI Gate。不把旧 Projects 文件建项目路径恢复为回归目标。
