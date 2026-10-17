# Plan P2 — macOS 系统文件注册与 Finder/Dock 打开

**Goal：** 正式签名的唯一 Bailey.app 被 Launch Services 识别为文件／文件夹的备用打开应用；Finder、Dock、`open -a` 的真实文件事件进入 P1 的共同路由。

**Non-goals：** 不建立 `NSDocument`、`DocumentGroup`、Finder Extension、第二 Bundle ID、安装脚本、注册守护进程；不更改任一文件类型的系统默认应用，也不替换原 Finder 文件夹服务。

**Approach：** 现有 Xcode 工程 Debug/Release 都使用 `GENERATE_INFOPLIST_FILE = NO` 和 `Bailey/Resources/Info.plist`；只在这一资源声明 `CFBundleDocumentTypes`。Apple 文档明确指出 `application(_:open:)` 的 URL 列表**不包含已声明文档类型的文件**，且会抑制 `openFile(s)`；所以普通 Finder 文档优先采用 `application(_:openFiles:)`，处理后按契约 `reply(toOpenOrPrint:)`。SwiftUI `WindowGroup` 对文件的真实投递仍须通过**可隔离的正式签名包**验证，选择真正生效的一个处理入口，不写 `.onOpenURL + openFiles + application(_:open:)` 的兼容链。

**Acceptance：** 实际包内 plist 正确、Finder 将 Bailey 列为相应类型的备选 App、真实文件在正确窗口打开；多选、启动／后台／末窗关闭均可用；目录服务、身份、快照、默认文件关联无变化。

**Rules：** 只有一个 `Bailey.app / chiimagnus.bailey`。正式使用的 App 与隔离 XCTest 宿主共享 bundle ID；不能为了 E2E 随意调用 `open -a Bailey` 操作用户正在用的进程。最低 macOS 15.6，App Sandbox 未启用，不因本功能添加书签系统、文件访问常驻守卫或额外 entitlements。

---

## P2-T1

**独立结果：真正接通 Launch Services 的 Finder／Dock 文件打开。**

**Source anchors：**
- `Bailey/Resources/Info.plist` 只有 Finder 的 `NSServices / openInBailey`，没有 `CFBundleDocumentTypes`。
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
- 对照 [Zed DocumentTypes.plist](https://github.com/zed-industries/zed/blob/main/crates/zed/resources/info/DocumentTypes.plist) 的 `public.text`、`public.folder`、`Alternate`，与 [VS Code app.ts](https://github.com/microsoft/vscode/blob/main/src/vs/code/electron-main/app.ts) 的多 URL 批量接入；借鉴用户结果，不移植框架或 VS Code 偏好新窗的默认策略。
- 首先证明构建包无文档类型注册，然后用进程内可触发的**实际 App delegate → P1 窗口管理者**路径做 Red 测试：一个文件、多文件与目录；已有标签、不同窗口、待恢复请求；测试最终窗口与内容，而非仅断言方法调用计数。

### Step 2：最小实现和明确的关联试验

1. 在唯一 Info.plist 声明 **文本／源代码、图片、目录**的合适公共 Uniform Type Identifier；角色只承诺现有 TextKit 文本编辑与图片预览；各项均 `LSHandlerRank = Alternate`。未知扩展名与无后缀文本先验证公共类型的实际 Finder 覆盖，**不要预先用 `public.data` 宣称能处理所有文件**，或搬运数十个过时后缀。系统选择 UI 不支持的类型仍可通过显式打开操作验证，但要说清候选限制。
2. 对已声明 `CFBundleDocumentTypes` 的普通 Finder 文件，优先在 App delegate 实现 `application(_:openFiles:)`，将文件名形成的本机 URL 批次转给 P1 路由，依真实请求结果调用 `reply(toOpenOrPrint:)`（接受、失败、取消分别明确）；冷启排队时不能抢先把未实际接收的失败报告成成功。使用真正 Finder／Dock／`open -a` 验证接收层；若 SwiftUI 场景接管了文档事件，采用测试证明有效的**唯一入口**并删除无用回调。不可将 `application(_:open:)` 与 `openFile(s)` 叠加做万能兜底，不能靠全局事件 ID 黑名单为多次接收打补丁。
3. 原 `openInBailey`、Services 所需 plist 键、`applicationShouldTerminate` 和主题初始化都必须保留；只改确实归本任务的业务代码。文档类型图标键不可引用不存在的 `Document.icns`；不引入单独 document filetype 图标资产。
4. 不把 `lsregister -f`、重置 Launch Services 数据库、修改用户默认文件打开程序当作正常应用安装步骤。真实包签名和候选查验失败时追实际构建、系统缓存／版本及 Bundle ID，再定位根因。

### Step 3：覆盖全部适用的系统路径、失败与兼容边界

**自动验证：** `plutil -lint Bailey/Resources/Info.plist`；`make test ONLY_TESTING=BaileyTests/AppIdentityTests`，新增测试类时执行实际类选择；`make test ONLY_TESTING=BaileyTests/SessionStoreTests`；`make build`、`make test`、`git diff --check`，检查完整退出状态／测试实际被发现、证书签名和**构建的 `Bailey.app/Contents/Info.plist`**。工程／签名配置如发生真实变动才加 `make build:release`；CI 的 ad hoc 结果不能冒充正式 Apple Development 包。

**必须另验的原生系统用户路径：**
- Finder「打开方式」、Finder「显示简介」候选、文件拖 Dock 图标、`open -a Bailey /path/to/file`、多个文件连续请求与单批请求。比较当前和先前默认打开 App，Bailey 不能主动抢系统默认。
- `swift`、`md`、`txt`、`json`、`py`、常见源代码后缀，PNG/JPEG/HEIC，未知后缀、无扩展名、隐藏文本、目录、PDF／二进制；分别记录是否能选择 Bailey、是否被系统投递、实际编辑／不可用结果，**不把「所有应用」与「推荐应用」混为一谈**。Finder 对文件夹的菜单形式由 macOS 决定，使用 Dock／系统命令另验目录处理。
- App 未启动、在前台已开文件、后台已有不同窗、当前是 SSH 项目、最后一个窗口关闭、跨进程恢复第二个窗口后目标文件才出现、窗未 attach 时多文件并发到达；新系统入口不能制造重复 editor、错误 project 或多余 Shell。
- 拒绝访问、失效软链、路径别名、Unicode／控制字符、文件被删除、读入时移除、多文件部分失败、文本超限、不可预览图片；应显示已有错误／不可用 UI 且不改源文件。
- 当前支持 macOS 与最低 15.6、深／浅色、中／英文、安装后签名与运行，能够安全执行的逐项记录。**独立测试登录环境或同等真正隔离的签名实例**才可用于 Finder 的进程外实测：已有用户 Bailey 正在运行时，不能通过同 Bundle ID 的 `open` 意外操作用户会话；无法隔离则本项明确 blocked，低层回调测试不是完成证明。

**Uncovered / Gate：** macOS 15.6 主机、进程外 Finder/Dock UI、真实签名、不同系统语言如缺条件，逐项列出环境、替代证据、用户风险和所需补验，未完成的强制 Finder 路径不得宣称已验收。资料可留在任务 note／后续阶段 audit，不事先创建 audit 文件。

### Step 4：本任务原子提交

文档类型、唯一文件事件入口、App 相关回归及本任务失效旧逻辑**同一次任务**完成；同步用户说明，不保留投递不到的备用 callback、额外偏好或过时包装。中文提交正文说明实际包／系统验证及缺口；不推送或发布。

---

## Phase Audit

P2 真正完成后才审查实际签名包中的文档关联、唯一事件处理和 Finder Service 回归；只有运行进程外系统操作并观察真实文件内容，才报告 Finder 路径通过。审计不受旧 `audit**.md` 干扰。
