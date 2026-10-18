# Audit P2 - finder-integration

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/finder-integration/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 Finder 注册与系统打开事件

## 任务到文件的映射

- P2-T1 · `833f5718c4a7bca87c4bff60936bfb588e6ba245` + `de65f880299cf58bf7846050eb8958c83f221e8a`
  - `Bailey/Resources/Info.plist`: 唯一 `CFBundleDocumentTypes`；`public.text` / `public.image` / `public.folder`，均为 `LSHandlerRank = Alternate`；保留 `NSServices/openInBailey`。
  - `Bailey/App/FinderService.swift`: `applicationWillFinishLaunching` 注册唯一 `kAEOpenDocuments` Apple Event 接收者；还原整个文件 URL 列表，委托现有 `TerminalManager.openExternalFiles`；删除在 SwiftUI `WindowGroup` 下不接收事件的 `application(_:openFiles:)`。
  - `Bailey/Workspace/SessionStore.swift`: 有效 `BAILEY_UI_TEST_RUN_ID` 隔离测试窗口与历史，不读取正式用户状态。`Bailey/Workspace/TerminalManager.swift`: P1 已有的文件路由/窗口选择/恢复等待与事件错误提示，本阶段仅修正文档性注释，没有复制新的文件队列。
  - `BaileyTests/Unit/App/AppIdentityTests.swift`: Alternate UTI、单一 BundleID、原有 Service、Unicode 文件批次 Apple Event 解析；`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`: 真实 NSWindow/ContentView、本机文件正文/图片/目录/缓冲去重，明确接受窗口以杜绝宿主全局焦点夹具污染。
  - `README.md`、`docs/features/projects.md`、`docs/features/session-restore.md`、`docs/features/dock.md`、`docs/testing.md`: 区分手动添加、系统打开、唯一窗口身份、测试实例安全限制和原生验证。

## 发现项

- 已逐一审查本阶段两个实现提交、实际调用路径、签名包、Launch Services、原生 Finder/Dock 最终打开结果及对应测试。无尚未解决的、具有具体复现/源码契约证据的 P2 产品缺陷。
- 初版回调实际不工作且 SwiftUI 接收丢失批次/额外开窗：已在 `de65f88` 从根因纠正，测试包含真实进程外 Red→Green；没有保留替代回调或第二套窗口模型。
- 两次完整 XCTest 中曾出现 `PaneRetentionTests` 的滚动偏差/弱视图释放失败；相关生产文件未在本 Feature 中变更，12/12 单类通过；用户授权清理其他 Bailey GUI 实例后，本次 **同样完整 440 项**第三轮运行该类全通过。尚不能断言过去偶发失败的唯一根因，后续重现时应独立跟踪而非在 Finder 实现中增设任意等待/释放补丁。

## 修复日志

- 已修复的系统失败：`application(_:openFiles:)` 被 SwiftUI WindowGroup 抢收；尝试 `.onOpenURL` 又先多建空窗、只交付批次首项。最终以唯一早期 `NSAppleEventManager.setEventHandler(kAEOpenDocuments)` 收整个批次并路由 P1；失败尝试未保留为兼容链。
- 系统文件类型只用现代 UTI 的 Alternate，不复制 Zed 历史 CFBundleTypeOSTypes / Default 或全匹配 `public.data`。测试包隔离只影响本机快照，未更改正式 Bundle ID/普通默认应用。原有 Finder Service 和数据退出保护完整保留。

## 验证日志

- 完整命令：`make build DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder` -> **exit 0** (`** BUILD SUCCEEDED **` + 末尾严格 codesign 验证)。`make test` 同参数 -> **exit 0**，**440 tests、0 failures、6 skipped**，`** TEST SUCCEEDED **`，日志 `/tmp/bailey-p2-post-ui-{build,fulltest}.log`。`git diff --check`、`plutil -lint`、`codesign --verify --deep --strict` 和 Feature `todo validate` 均为 0。
- 分层覆盖：Apple Event 实际 Unicode/空批次/多文件的 parse XCTest；真实本机目录和文件项目、批次多文件、重复、已打开原缓冲、跨窗口焦点、SSH 同名路径隔离、冷启动/恢复等待、已关闭窗口拒绝晚到任务、图片 Preview、损坏/不可读取/过大文件沿 `FileTab` 现有测试集合；单/双窗 NSHostingView，SessionStore 恢复和原生 TextKit/WebKit via 440 项完整 XCTest；前次 `PaneRetentionTests` 单类 12/12 成功，第三轮完整套件亦通过。
- **独立进程 Finder E2E**：独立签名测试 Bailey，隔离快照 ID `8F60ABF2-B9EB-423F-A1DE-F5F6AE0EA69D` 和 `/tmp/bailey-finder-ui-p2.6J4N3A` 临时样本；Peekaboo 真右键 `right-click.swift` → Finder「打开方式」→ `Bailey.app`，原生 AX 编辑器正文确认为 `let e2e = "right-click"`，仍只有 1 window；真 Dock 物理拖 `dock-drop.swift` → 测试 App 的 Dock 图标，编辑标签加入同一窗口；真 Dock 物理拖 `folder-project`，新增目录项目而非假文件标签；3 次真实鼠标入口源文件 SHA-256 前后完全相同、无额外窗口或 Shell。Dock 上双 Bailey 图标先经 AXURL 精确区分正式/测试；原 autohide 真值通过 trap 恢复为 1。第一次 Dock 隐藏状态下发送拖动未生效，已如实记录，不冒称通过。
- Launch Services 实际在本机识别 `swift/md/txt/json/py/js` 与 `png/jpg/heic` 为 Bailey 候选，Swift 仍默认 Xcode-beta、txt 默认 TextEdit、目录默认 Finder；不擅改默认。`.go/.rs/.jsx` 动态 UTI 和 `.ts` 错认 MPEG-TS 导致**不在推荐应用列表**，但经显式 `open -a` 可读；当前 P2 需求是广义 `public.text`、图片、目录备用程序，不为动态/跨媒体扩展提升 `Default`。此限制在 `plan-p2.md`、`idea.md` 保留；专用代码扩展名可另行评估最小注册策略，不应被描述为全部格式 Finder 推荐。
- **未实测/Deferred，原因与影响**：最低 macOS **15.6** 实机目前无主机，无法证明此系统 Finder UI 行为，只能由 Xcode 目标版本/API 编译和 macOS 27.2 真 GUI 代替；有机器时重新执行上述系统入口。6 项需授权 SSH 主机的专用测试被环境跳过，本 P2 不改变 SSH 协议且已用本机/受控后端验证不会向远端错路由；在专用 SSH 主机验证实际连接相关场景。Finder **文件夹右键**在本机菜单根本没有「打开方式」，已以真实 Finder→Dock 目录拖放补验。没有新的独立 GUI 登录用户，测试过程经用户明确授权关闭正式 App、最小范围临时文件与独立快照；未宣称两个 UI 会话隔离。权限均由系统授权，Peekaboo Bridge/Local status 确认 true。
- 文档核对：`projects.md` 保持唯一系统打开/手动添加区别，`dock.md` 为窗口所有权，`session-restore.md` 为隔离快照，`testing.md` 为 E2E/局限性；`plan-p2.md` 保存初次阻塞/修正与原生 GUI 真实数据，`todo.toml` 为唯一状态；没有凭旧计划把已删除 Delegate 列为现行代码。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P2 的应用类型注册和单一原生系统回调已真实通过 Finder 右键/真实 Dock 文件与目录 E2E，严格构建签名及完整 XCTest 440 项 0 失败；无法获得最低系统/SSH 专用主机作为明确环境补验，不构成 macOS 27.2 当前系统功能路径阻塞，允许进入 P3。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：最低 macOS 15.6 与专用授权 SSH 实机未覆盖；Finder 推荐应用对未知/部分动态代码扩展名覆盖有限。先前 NativeUI 全套环境相关两次红灯，在目前唯一测试宿主下已全绿，不把推测的资源问题伪装成确定缺陷。P3 仍须独立验证窗口内容区域的文件拖放、终端远端拒绝、Files 精确落点和其他原生拖放语义。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-19 独立复核（现行系统接收机制）

- **P2-T1 · `833f571`**：核对唯一 `Bailey/Resources/Info.plist` 及本轮 `make build` 的实际包：文本、图片、目录均声明 `LSHandlerRank=Alternate`，保留原 `NSServices/openInBailey`；没有修改默认文件关联、增加第二 Bundle ID 或创建 Finder Extension。
- **P2-T1 修复 · `de65f88`**：核对现行 `BaileyApplicationDelegate.applicationWillFinishLaunching` 安装 `NSAppleEventManager` 的唯一 `kAEOpenDocuments` 接收者，`handleOpenDocuments` 解析整批 URL 后调用 `TerminalManager.openExternalFiles`。旧无效 `application(_:openFiles:)` 和 SwiftUI `.onOpenURL` 并行接收分支已从生产源码消失；Finder 的文件夹 Service 仍通过 `openDirectories` 执行目录项目添加。
- **独立运行证据**：`AppIdentityTests`、`WorkspaceWindowIsolationTests` 在本轮全量 `make test` 中通过（**472 项／0 失败／0 跳过，完整退出 0**）；`make build` 执行成功并严格验签；编译后 Info.plist 内容与源码声明一致。
- **独立 Gate**：系统注册与事件分发的当前源码、构建和集成层可通过复核；**本轮未重新点击 Finder「打开方式」的有项目正向路径，也未物理拖文件至 Dock 图标**。旧 P2 的实际 Finder E2E 属于历史证据，不能替代 P4 当前版本的完整跨进程 GUI 验收。最低 macOS 15.6 真机不是用户要求的本轮补验条件，不声称旧系统实测通过。无新增 P2 源码缺陷 finding。
