# Plan P2 — macOS 系统文件注册与 Finder/Dock 打开

**Goal：** 正式签名的唯一 Bailey.app 被 Launch Services 识别为文件／文件夹的备用打开应用；Finder、Dock、`open -a` 的真实文件事件进入 P1 的共同路由。

**Non-goals：** 不建立 `NSDocument`、`DocumentGroup`、Finder Extension、第二 Bundle ID、安装脚本、注册守护进程；不更改任一文件类型的系统默认应用，也不替换原 Finder 文件夹服务。

**Approach（已按真实系统证据修正）：** 现有 Xcode 工程 Debug/Release 都使用 `GENERATE_INFOPLIST_FILE = NO` 和 `Bailey/Resources/Info.plist`，仅在这一资源声明 `CFBundleDocumentTypes`。首次实现使用 `application(_:openFiles:)`，但在当前 SwiftUI `WindowGroup` 系统实测中该委托**没有被调用**：SwiftUI 优先接收 `kAEOpenDocuments`，`.onOpenURL` 只收到批次第一个文件，并先生成多余窗口。最终在 `applicationWillFinishLaunching` 以 `NSAppleEventManager` 注册**唯一**的 `kAEOpenDocuments` 原生处理器，提取完整 Apple Event URL 列表，交给 P1 的 `TerminalManager.openExternalFiles`；不留平行 `.onOpenURL` 和 `openFiles` 兼容链，不更改 `SessionStore` 的恢复策略。静态委托单测被原生真实 E2E 纠正。

**Acceptance：** 实际包内 plist 正确、Finder 将 Bailey 列为相应类型的备选 App、真实文件在正确窗口打开；多选、启动／后台／末窗关闭均可用；目录服务、身份、快照、默认文件关联无变化。

**Rules：** 只有一个 `Bailey.app / chiimagnus.bailey`。正式使用的 App 与隔离 XCTest 宿主共享 bundle ID；不能为了 E2E 随意调用 `open -a Bailey` 操作用户正在用的进程。最低 macOS 15.6，App Sandbox 未启用，不因本功能添加书签系统、文件访问常驻守卫或额外 entitlements。

---

## P2-T1

**独立结果：真正接通 Launch Services 的 Finder／Dock 文件打开。**

**Source anchors：**
- `Bailey/Resources/Info.plist` 在 P2 实施前只有 `NSServices / openInBailey`；P2 已在同一文件增加 `CFBundleDocumentTypes`，保留原 Service。
- `Bailey/App/BaileyApp.swift` 的 `@NSApplicationDelegateAdaptor(BaileyApplicationDelegate.self)` 装配到一个 `WindowGroup(id: "main")`；实际入口在 `Bailey/App/FinderService.swift`。
- `Bailey/Workspace/TerminalManager.swift` 的 P1 公共外部打开路由，必须保留 `openInBailey` 目录 Service 的独立菜单和同一窗口恢复机制。
- `Bailey.xcodeproj/project.pbxproj` 明确 Info.plist 非生成资源；无需创建或生成另一份 Info.plist／工程清单。

**Files：**
- Modify：`Bailey/Resources/Info.plist`、`Bailey/App/FinderService.swift`；只有被真实事件实验证明需要时修改 `Bailey/App/BaileyApp.swift` 的场景接收配置。
- Tests：优先扩充 `BaileyTests/Unit/App/AppIdentityTests.swift`、`BaileyTests/Integration/Workspace/SessionStoreTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`；若既有类无法表达 AppKit 委托的有效测试，可新增 `BaileyTests/Integration/App/FinderOpenTests.swift`（目录自动归同一 BaileyTests target，需核对 XCTest 实际发现）。
- Localizations：只有新增可见文档名称或提示时更新 `Bailey/Resources/Localization/InfoPlist.xcstrings` 或所属业务 string catalog，保留 `ServicesMenu.xcstrings` 与现有 NSServices 条目。
- 文档：`README.md` 的 Finder 使用入口，`docs/features/projects.md` 的系统打开与手动添加区别；仅当注册／验证／安装契约改变时更新 `docs/development.md`、`docs/testing.md`；`docs/features/dock.md` 只在窗口行为有实际修改时同步。

### Step 1：平台 API 和当前代码核对，先写 Red

- Apple [CFBundleDocumentTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes)、[LSHandlerRank](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes/lshandlerrank)、[application(_:openFiles:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29) 和 [application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopen%3A%29) 是平台契约。**后者的 URL 列表明示排除已声明文档类型的文件，且会抑制 `openFile(s)`**；前者要对文件批次调用 `reply(toOpenOrPrint:)`。SwiftUI `WindowGroup` 的实际文件投递仍要独立进程验证，不能把 delegate 单测当作 Finder E2E。
- 对照 [Zed DocumentTypes.plist](https://github.com/zed-industries/zed/blob/main/crates/zed/resources/info/DocumentTypes.plist)：其通用 `public.text`、`public.folder` 用 `Alternate`，还有**第二组旧式扩展名声明（`CFBundleTypeOSTypes = ****`、`LSHandlerRank = Default`）**，并不意味着 Bailey 应复制这些过时通配规则或提升默认优先级。Apple [InfoPlist 文档类型说明](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html) 指出使用 `LSItemContentTypes` 时旧式扩展名／OSType 不再生效。VS Code [macOS 打开文件回调](https://github.com/microsoft/vscode/blob/main/src/vs/code/electron-main/app.ts) 对多事件短暂聚合、NFC 规范化并显式 `preferNewWindow: true`；此窗口选择是 VS Code 产品策略，不应盲从。
- 首先证明构建包无文档类型注册，写出本机项目和窗口接收的 Red 测试；真实系统首次验证暴露的**AppDelegate 回调未执行、SwiftUI 多建空窗口和丢失批次第二文件**要以真实 Apple Event 记录为 Red 证据，随后验证最终文件内容与窗口数，而非仅验证一次方法调用。

### Step 2：最小实现和明确的关联试验

1. 在唯一 Info.plist 声明**TextKit 支持的文本／源码、现有图片预览、目录**适用的 Uniform Type Identifiers 和 `CFBundleTypeRole`；一律使用 `LSHandlerRank = Alternate`，不抢默认程序。核对 macOS 实际 UTI 归属，不把 `public.text` 当成所有未知后缀或无扩展名的万能匹配；优先少量宽泛公共类型，而不是逐项复制 Zed 旧式扩展名列表。
2. **未知／无扩展名文件是明确验收场景，不是无限扩注册的许可。** 用真实 Finder 的「推荐应用／全部应用」、系统 `open -a` 和实际 UTI 识别观察覆盖范围；只有存在明确且必须解决的缺口时，才以最小副作用比较 `public.data` 或自有 UTI 的必要性。不能为了出现在 Finder 候选中把 Bailey 宣称为所有二进制数据的默认编辑器，也不修改系统默认关联。
3. **系统实测后确认为 `NSAppleEventManager` 唯一 `kAEOpenDocuments` 接收者**：不使用会被 SwiftUI 抢先消费的 `application(_:openFiles:)`，也不靠 `.onOpenURL` 处理多文件（该 SwiftUI 回调会先为这一次打开新建工作区）。`applicationWillFinishLaunching` 中安装 Apple Event 回调，在原生事件保留全部文件书签的时点解析完整 URL 列表，传给 P1 单一文件路由；不靠任意延时、全局 eventID 黑名单或第二套文件会话。用真正 Finder／Dock／`open -a` 分别核对冷启、已运行、双窗口、文件夹、图像、重复和多文件等可行用户路径；无法物理操作时明确分别记未测和替代证据。
4. 原 `openInBailey`、Services 所需 plist 键、`applicationShouldTerminate` 和主题初始化都必须保留；只改确实归本任务的业务代码。文档类型图标键不可引用不存在的 `Document.icns`；不引入单独 document filetype 图标资产。注意 VS Code 的 `open-file` 对文件名使用 NFC，Bailey 应验证文件系统两种 Unicode 规范的路径身份，而不是简单统一字符串后打开了另一个文件。
5. 不把 `lsregister -f`、重置 Launch Services 数据库、修改用户默认文件打开程序当作正常安装步骤。真实包签名和候选查验失败时追实际构建、系统缓存／版本及 Bundle ID，再定位根因。**静态 `plutil` 和一个 AppKit delegate 单测不构成 Finder 候选与打开成功的证据。**

### Step 3：覆盖全部适用的系统路径、失败与兼容边界

**自动验证：** `plutil -lint Bailey/Resources/Info.plist`；`make test ONLY_TESTING=BaileyTests/AppIdentityTests`，新增测试类时执行实际类选择；`make test ONLY_TESTING=BaileyTests/SessionStoreTests`；`make build`、`make test`、`git diff --check`，检查完整退出状态／测试实际被发现、证书签名和**构建的 `Bailey.app/Contents/Info.plist`**。工程／签名配置如发生真实变动才加 `make build:release`；CI 的 ad hoc 结果不能冒充正式 Apple Development 包。

**必须另验的原生系统用户路径：**
- Finder「打开方式」、Finder「显示简介」候选、文件拖 Dock 图标、`open -a Bailey /path/to/file`、多个文件连续请求与单批请求。比较当前和先前默认打开 App，Bailey 不能主动抢系统默认。
- `swift`、`md`、`txt`、`json`、`py`、常见源代码后缀，PNG/JPEG/HEIC，未知后缀、无扩展名、隐藏文本、目录、PDF／二进制：逐项记录 macOS 识别的 UTI、Finder「推荐／全部」候选、实际投递和内容结果，**不把系统候选可见性等同于可编辑**。核查多选列表中有不同 UTI 时是否丢项、包目录是否按 Folder 还是文档、文件夹 Finder 菜单因系统版本差异的实际行为。
- App 未启动、在前台已开文件、后台已有不同窗、当前是 SSH 项目、最后一个窗口关闭、跨进程恢复第二个窗口后目标文件才出现、窗未 attach 时多文件并发到达；新系统入口不能制造重复 editor、错误 project 或多余 Shell。
- 拒绝访问、失效软链、路径别名、Unicode／控制字符、文件被删除、读入时移除、多文件部分失败、文本超限、不可预览图片；应显示已有错误／不可用 UI 且不改源文件。
- 当前支持 macOS 与最低 15.6、深／浅色、中／英文、安装后签名与运行，能够安全执行的逐项记录。**首先检查 `--isolated-ui-test` 是否真的隔离目标窗口、工作区快照和文件关联；它不提供独立 Bundle ID，Launch Services 的按 Bundle ID 投递仍可能到用户在用的正式实例。**真实 Finder/Dock E2E 应在独立图形登录用户／测试主机或同等真正隔离的系统环境下执行；不能盲用 `open -a Bailey` 影响用户现有进程。无法安全隔离则记明确 blocked，不伪报完成。

**Uncovered / Gate：** macOS 15.6 主机、进程外 Finder/Dock UI、真实签名、不同系统语言如缺条件，逐项列出环境、替代证据、用户风险和所需补验，未完成的强制 Finder 路径不得宣称已验收。资料可留在任务 note／后续阶段 audit，不事先创建 audit 文件。

### Step 4：本任务原子提交

文档类型、唯一文件事件入口、App 相关回归及本任务失效旧逻辑**同一次任务**完成；同步用户说明，不保留投递不到的备用 callback、额外偏好或过时包装。中文提交正文说明实际包／系统验证及缺口；不推送或发布。

---

## Phase Audit

P2 真正完成后才审查实际签名包中的文档关联、唯一事件处理和 Finder Service 回归；只有运行进程外系统操作并观察真实文件内容，才报告 Finder 路径通过。审计不受旧 `audit**.md` 干扰。

---

## P2-T1 初次实施的历史阻塞记录（2026-10-18）

**第一次代码提交：** `833f5718c4a7bca87c4bff60936bfb588e6ba245`。这次提交包含文档注册和初版 `application(_:openFiles:)`。**以下阻塞与低层通过只代表初次实施的历史状态，已被随后实际系统运行与修复所更新。** 实时状态始终以 `todo.toml` 为准。

**安全执行结果：**

| 检查维度 | 真实结果 | 层级 |
| --- | --- | --- |
| plist 格式及实际签名 App 内容 | `plutil -lint` 通过；`Bailey.app/Contents/Info.plist` 具有 `public.text`、`public.image`、`public.folder`；全部 `LSHandlerRank=Alternate`；不含 `public.data` | Bundle |
| 正式应用身份及签名 | `chiimagnus.bailey`、Apple Development 签名；`codesign --verify --deep --strict` 成功；原 Finder `NSServices/openInBailey` 仍在 | Bundle |
| Objective-C 系统回调存在 | 编译产物能定位 `application:openFiles:` selector；未声明与之冲突的 `application:openURLs:` 或重复 `.onOpenURL` | AppKit 静态/集成 |
| 实际 App delegate 路由 | `NSWindow + NSHostingView(ContentView)` 经 `application(_:openFiles:)` 打开 2 个 UTF-8 文件、复用同一个 FileTab、打开目录及有效 PNG 预览；核对实际文本及磁盘字节 | WorkspaceUI XCTest，非系统进程外 |
| 各 UTI 在本机的识别 | `.txt/.md/.swift/.py/.json/.js` 符合 `public.text`；`.png/.jpg/.heic` 符合 `public.image`；`.pdf` 和未知后缀不错误归入文本/图片 | UniformTypeIdentifiers |
| 代码后缀实际限制 | `.go/.rs/.jsx` 为动态类型、不符合 `public.text`；`.ts` 被系统识别为视频传输流，推荐应用覆盖需 Finder 实测；暂未用宽泛 `public.data` 抢关联 | UniformTypeIdentifiers |
| LS 候选与默认程序 | 只读 `LSCopyAllRoleHandlersForContentType`：文本、图片、目录均包含 `chiimagnus.bailey`；这三类的当前默认处理程序**都不是 Bailey**；`LSCopyApplicationURLsForBundleIdentifier` 中有本 worktree 签名包路径 | Launch Services 只读查询 |
| 完整项目验证 | `make build DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder` -> exit 0 + 严格签名校验；`make test` -> **439 tests、0 failures、6 skipped**；目标类 11/11 | Xcode/XCTest |
| 真实 Finder / Dock / `open -a` | **未执行**。检查到 `/Applications/Bailey.app` 正式用户进程仍运行（当时 PID 59797），多个已注册包共享 `chiimagnus.bailey`；Finder 事件可能被投递到用户进程 | **强制 E2E，阻塞 P2** |
| macOS 15.6 最低部署版本 | 本机是 macOS 27.2、Xcode 27.2；目前无 15.6 原生 runner | 兼容性缺口 |
| 真 SSH 后端 | 6 个现有 XCTest 需要专用授权 SSH 主机，未设置 `BAILEY_P4_TEST_SSH_HOST`；当前 P2 不改变 SSH 后端，P1 已通过本机与受控 SSH 隔离回归 | 实机环境缺口 |

**Gate 约束：** `--isolated-ui-test` 只隔离快照，不改变 Bundle ID 或 Launch Services 投递目标，不能用它当真正独立图形环境；不能重启、停用或向用户正在运行的 Bailey 发测试文件。只有在独立图形登录用户／专用测试 Mac（或等效隔离的系统 App 身份和 UI 会话）运行 Finder「打开方式」、Dock 文件拖入、`open -a`、多窗口恢复及部分无效批次并核对实际文件内容后，才可将 P2-T1 标记 `completed`，触发 `audit-p2.md` 审计并按 `Go` 进入 P3。未满足之前保持 P3 `pending`，不把软件包正确/测试绿色冒充全功能已经完成。

---

## P2-T1 根因修复与进程外验证（2026-10-18，更新上述历史记录）

- **真实 Red 1（缺少文件）：** 初版 `application(_:openFiles:)` 在 SwiftUI `WindowGroup` 中没有被调用。系统的 `kAEOpenDocuments` 先被 SwiftUI 消费，试验性的 `.onOpenURL` 只交付批次第一个文件。一个 `open -a Bailey first.txt second.txt` 事件的实际 `NSAppleEventManager.currentAppleEvent` 有两个书签，第二个原来未进入 Bailey。
- **真实 Red 2（额外窗口）：** `.onOpenURL` 接收文件前，SwiftUI 为该事件又创建一个 `WindowRootView`，`TerminalManager.registry` 数量增长且出现空窗口。尝试 `.handlesExternalEvents`、`.restorationBehavior(.disabled)` 和旧 AppKit 回调没有从根本上解决；实验性修改已撤回。
- **Green／根因：** 在现有 `BaileyApplicationDelegate.applicationWillFinishLaunching` 使用 `NSAppleEventManager.setEventHandler` 将 `kAEOpenDocuments` 交给唯一 AppKit 接收器。它从 `keyDirectObject` 的文件列表读取全部 `NSAppleEventDescriptor.fileURLValue`，一次性调用 P1 的 `TerminalManager.openExternalFiles`；不再有平行 `.onOpenURL`、`application(_:openFiles:)`、延时合并或文件索引。此方式早于 SwiftUI 为每个文档新开窗口。
- **测试环境隔离：** 正式 `/Applications/Bailey.app` 由用户退出并以 `ps` 核对无进程后，使用独立 worktree Apple Development 已签名包及唯一 UUID 环境变量 `BAILEY_UI_TEST_RUN_ID`；测试实例通过环境变量启用隔离快照与禁止已保存隧道。临时文件全部在 `/tmp/bailey-finder-e2e.1aEhOQ`，不访问用户项目；测试实例的 PID/完整可执行文件路径已逐一核对。
- **真实 E2E 已通过（系统 `kAEOpenDocuments`）：** 冷启动直接打开 `sample.swift` -> 单窗口/单项目，真实编辑正文 `let baileyE2E = 42` 截图证据；已运行时单文件 -> 仍单窗口；同一命令多选 `first.txt` + `second.txt` -> 同一个本机目录项目、两个真实 FileTab；目录 `source-folder` -> 正确的目录项目/不生成文件标签；重复打开 `sample.swift` -> 不重复建项目；显式打开 `unknown.notype` 和无扩展名 `no-extension` -> 进入文件标签，不篡改系统默认关联。测试后工作区快照显示 **1 window、3 projects**；所有测试源文件的 SHA-256 前后相同。
- **自动回归：** `AppIdentityTests` 中 `NSAppleEventDescriptor.list()` 的 Unicode/目录/顺序、nil 与空列表；`WorkspaceWindowIsolationTests` 里真实编辑内容、PNG 预览、文件夹、重复打开。Targeted `make test` 18 tests、0 failures。完整 `make build` 和 `make test` 最终输出在当前 worktree `/tmp/bailey-finder-native-final-*.log`；通过后才记录为阶段完成。
- **仍无真机 UI 证据的项目：** Finder 右键「打开方式」及 Dock **物理拖入**未通过权限受限的 GUI 自动化独立观察；Peekaboo Screen Recording 允许截图，但 Accessibility/Event Synthesizing 未授权。Finder AppleScript `open using` 返回退出码 0，**但没有向测试 PID 投递事件**，因此不能冒充 Finder UI 通过。替代证据是已签名包的 LS Alternate 候选只读查询、默认程序未改变，以及同样的 macOS `kAEOpenDocuments` 系统投递 `open -a` 的最终原生正文/项目验证。最低 macOS 15.6 runner 当前未提供，实际执行在 macOS 27.2；6 个专用 SSH 测试由环境跳过，不冒充通过。
- **后续验收判断：** 系统文件回调的正确性、签名和多文件最终副作用已由真实系统 E2E 验证。上述 Finder/Dock 的物理 UI 触发和 macOS 15.6 为**剩余独立环境覆盖**，必须在 Feature 最终 Gate 中继续明确列出，不能写成已测试。P2 的核心入口不需要为此保留失效回调。

---

## P2-T1 二次完整验证与当前阻塞（2026-10-18，11:45 之后）

**修复代码提交：** `de65f880299cf58bf7846050eb8958c83f221e8a`，基于先前注册提交 `833f5718c4a7bca87c4bff60936bfb588e6ba245`。新增唯一 AppKit Apple Event 入口、URL 批次解析与测试、有效 UUID 环境隔离，删除失效 `application(_:openFiles:)`；同步 `docs/features/projects.md`、`docs/features/session-restore.md`、`docs/testing.md`。此提交**不是 P2 完成标记**。

**执行与退出结果：**

- `make build DERIVED_DATA=build/DerivedData-finder SOURCE_PACKAGES=build/SourcePackages-finder`：exit 0，`BUILD SUCCEEDED`，`codesign --verify --deep --strict` 通过；`plutil -lint`、`git diff --check` 和 `todo validate` 通过。
- P2 相关 `AppIdentityTests + PaneRetentionTests + SessionStoreTests + WorkspaceWindowIsolationTests`：**30/30 通过**，日志 `/tmp/bailey-finder-p2-contextual-test.log`。原始 `testSystemFileBatchRoutesToActualMountedFileBuffers` 夹具在完整宿主多个窗口共存时错误依赖全局焦点，导致首次完整套件 `XCTUnwrap(Project)` 失败；已修正为显式 `preferred: manager`，保留独立系统进程外真实收件窗口的验证。目标真实最终副作用仍核对 FileTab、内容和 PNG 预览。
- 第一次完整 `make test`：**440 tests、6 SSH skipped、2 failures**，`/tmp/bailey-finder-native-final-fulltest.log`；失败在上述测试夹具以及原有 `PaneRetentionTests.testEditorRetainsScrollAndReleasesRetiredNativeResources`。
- 第二次完整 `make test`：**440 tests、6 SSH skipped、2 failures，退出非零**，`/tmp/bailey-finder-p2-recheck-fulltest.log`。两项失败分别为 `PaneRetentionTests.testBrowserAndEditorStateSurviveViewRemount`（`scrollY` 实际从 900 变为 942）与 `PaneRetentionTests.testEditorRetainsScrollAndReleasesRetiredNativeResources`（旧原生编辑器弱引用在 10 秒等待内仍不释放）；P2 新改的 `WorkspaceWindowIsolationTests` 全部通过。
- `PaneRetentionTests` 单独全类重测：**12/12 通过**，`/tmp/bailey-finder-native-retention-isolated.log`。浏览器/编辑器生产实现 `Bailey/Browser/BrowserView.swift`、`Bailey/Editor/SourceTextEditor.swift` 及上述旧测试文件在 P1/P2 commits 和当前 worktree 都**没有修改**，目前缺乏将失败归于 Finder 的证据；但连续完整宿主运行下的资源和布局差异是**真实红灯**，不能跳过、扩大容差或伪称全绿。要继续调查 NativeUI 连续宿主与 AppKit/WebKit 原生释放/重挂载关系，区分错误的测试前提和产品真实问题。
- macOS 27.2 Launch Services 只读查询：`.swift/.md/.txt/.json/.py/.js` 与 `.png/.jpg/.heic` 推荐 Bailey；`.rs/.go/.jsx` 不在系统推荐列表，`.ts` 被识别为 `public.mpeg-2-transport-stream`；`.pdf` 和未知扩展名不在推荐列表。显式 `open -a` 仍可投递其他文件。**不擅自用 `public.data` 拦截所有二进制内容，也不改变用户默认关联**。
- 用户已经重新启动正式 `/Applications/Bailey.app`（核对到 PID 56036）；该进程正在使用，因此**不可再向系统文件关联投递测试请求，亦不得安装/重启它**。原先本任务启动的隔离测试实例已经单独结束，不影响正式用户会话。
- Peekaboo：Screen Recording 已授权；Accessibility 和 Event Synthesizing 均未授权。Finder 右键「打开方式」以及 Dock 图标的真实鼠标文件投递**未执行**；Finder AppleScript `open using` 虽成功返回，但没有观察到向测试 PID 交付真实文档事件，不能冒充这两个 GUI E2E。最低 macOS 15.6 真实主机及专用 SSH 主机也未提供。

**当前 Gate：No-Go／P2-T1 blocked。** 不能仅凭已提交代码、30 项针对性测试、签名成功和部分 `open -a` E2E 标记整个 P2 完成。解除条件：在允许安全操作的 GUI 会话下，独立验证 Finder「打开方式」与 Dock 物理投递及实际结果；同时定位/修复连续完整 XCTest 里两项 NativeUI 失败并复测完整 `make test`。没有 P2 Go 之前不得开始依赖它的 P3 实施。以上历史证据不按后续结论改写。

---

## P2-T1 实际 Finder／Dock 鼠标 E2E（2026-10-18，授权解除阻塞后）

- **授权与测试保护：** 用户明确允许正常退出正式 Bailey 并申请权限；`NSRunningApplication.terminate()` 对 `/Applications/Bailey.app` 正式 PID 56036 返回成功，确认其进程退出。Peekaboo CLI `permissions request accessibility`、`event-synthesizing` 发起系统授权后，`permissions status --all-sources` 验证本地与 Bridge 的 Screen Recording、Accessibility、Event Synthesizing **全部 true**。
- **隔离对象：** 真正签名的本 worktree 测试 App（PID 78135），环境 `BAILEY_UI_TEST_RUN_ID=8F60ABF2-B9EB-423F-A1DE-F5F6AE0EA69D`；临时文件夹 `/tmp/bailey-finder-ui-p2.6J4N3A`，没有使用用户项目。Finder 实际图形窗口 ID 135709；正式 Bailey 已退出。
- **Finder 真实右键（通过）：** 用 Peekaboo 在 Finder 图标 `right-click.swift` 发起真实右键，悬停「打开方式」，展开子菜单确实包含 `Xcode-beta.app（默认）` 和 `Bailey.app`，实际点击 Bailey。核查收到文件的是测试 PID、独立 `SessionStore` 只有 1 个窗口、项目的 `pinnedFile` 对应正确路径、文件标签及原生 AX `Text Editor` 正文确实为 `let e2e = "right-click"`，不是只观察系统事件。
- **Dock 物理拖单文件（通过）：** 从 Finder 的 `dock-drop.swift` 图标以 Peekaboo 真实鼠标轨迹拖向 Dock 测试 Bailey 图标。Dock 上存在**两个同名 Bailey**：通过 `AXURL` 核对首个指向 `/Applications/Bailey.app`，另一个确实指向 worktree 测试构建；只向后者拖。用户 Dock 原本 `autohide=1`，第一轮拖动时 Dock 未显示、**没有生效**，并未冒称通过。随后用 System Events **临时**关闭自动隐藏，在 shell trap 中恢复原 `true` 值；第二轮拖动到读出的实际测试图标坐标后，独立快照显示仍为 1 window，原 `right-click.swift` 标签保留并新增 `dock-drop.swift` 标签，源文件字节未变。Dock 自动隐藏已恢复为 `1`。
- **Dock 物理拖目录（通过）：** Finder 拖 `folder-project` 到同一测试 Dock 图标，独立快照显示仍为 **1 window**，两个文件标签保留，另新增 `pinnedFile=nil, customDirectory=<临时目录>/folder-project` 的目录项目，目录本身没有被当作文件标签，临时文件 SHA-256 一致。Finder 文件夹右键菜单只提供「在新标签页/新窗口中打开」，没有「打开方式」，属于**系统菜单本身的差异**，用真实 Dock 目录投递验收而不是伪造菜单测试。
- **恢复与环境：** 系统权限仍有效；用户 Dock 偏好已还原；测试 App PID 78135 已按正常终止流程退出；仅对临时文件与窗口做操作。系统最低 macOS 15.6 仍需另机补测。
- **后续自动验证：** 在全部 Bailey GUI 实例退出的条件下启动 `make build`、完整 `make test` 第三轮（`/tmp/bailey-p2-post-ui-build.log` 和 `/tmp/bailey-p2-post-ui-fulltest.log`）；以最终进程退出码及原生编辑器/浏览器测试结果更新 Gate，不能仅因为 GUI E2E 已通过就标记整个阶段完成。
