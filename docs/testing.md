# 测试与验收

本页是 Bailey 完成标准的唯一归属，负责测试层次、执行入口、隔离、性能测量和人工回归。测试结构、覆盖范围或验收要求改变时同步更新；贡献指南与 PR 只引用本页，不维护第二份清单。

## 完成标准

需求／文档驱动决定做什么和如何验收，测试驱动验证实现；二者属于同一流程。

| 检查 | 完成条件与证据 |
| --- | --- |
| 行为回归 | 新增或调整受影响测试；可测试的新行为和缺陷先确认 Red，再修复为 Green，最后 Refactor |
| 自动测试 | 本地只运行受影响的 XCTest，正式完整验收时运行 `make test`；测试必须实际被发现和执行 |
| 构建与签名 | 功能代码通过 `make build`；Swift 6 全面迁移、依赖或发布路径变更还检查 `make build:release`，无未解释的新诊断 |
| 架构与数据保护 | 按 [模块边界](architecture.md#模块化与依赖) 核对旧／新所有者、减少的反向依赖与镜像状态、明确动作意图及取消／目标失效后的真实副作用；每个独立迁移任务立即删除自己替代的旧路径 |
| 用户路径 | 按下文运行受影响的原生／工作区和人工回归；未执行的 E2E、真实网络与恢复明确列出 |
| 文档与差异 | 受影响文档在同一提交更新，现行链接可达；通读 diff，`git diff --check` 通过 |

**纯文档改动**检查事实、路径、命令和导航，不机械编译或安装 App。文档体系调整逐页核对职责、更新时机、功能页首节、索引覆盖、路径大小写与标题锚点；现行计划单独查失效引用，历史审计不全局替换。检查脚本未覆盖的格式或目录明确列出，不将“无断链”冒充全部文档通过。纯翻译检查字符串表、中英文、占位符与链接，涉及提取时按需构建；快捷键、路由和布局不是纯文案改动。

编译成功、全部低层测试转绿或事件已发出，都不能证明完整用户路径正确。不能禁用失败用例或增加任意等待来制造绿色；既有正确行为也不能为了错误断言而被修改。

## 根因与回归覆盖

**必须尽可能覆盖受影响功能的全部测试环境、测试条件、异常状态、边界与极端情况及其组合；不得以正常路径或几个代表性测试通过作为完成依据。** 修复缺陷须还原真实触发条件，沿入口、状态所有者、共享依赖及失败／恢复路径定位失效不变量，在归属处修复；逐一核对同一根因涉及的其它入口，不能吞错、加等待或只调整断言。可复现缺陷保留 Red→Green 证据；测试夹具必须证明前置条件成立，例如真实 Git 冲突索引，而不仅是命令非零。

开始验收时，先枚举**全部已识别且适用于受影响功能**的条件，并尽最大可行程度逐项执行，而非事先挑选少数高风险示例：

- **环境／配置**：最低及当前支持的系统、工具链版本、默认与非默认配置、语言区域、权限／签名、本机及获授权的 SSH 后端、在线／离线／网络不稳定。
- **输入／容量**：空／缺失／非法输入、特殊字符／Unicode、二进制、特殊路径、最小／通常／大规模数据、长度与容量边界、超限及资源耗尽。
- **状态／失败／恢复**：初次及已有数据、冲突、部分成功、读写失败、断线／超时／重连、取消、重新打开、关闭与恢复、旧状态迁移。
- **时序／交互／生命周期**：并发与重复操作、乱序回写、窗口或目标切换、资源释放、长时间运行，以及受影响的尺寸、主题、焦点、多窗口和键盘操作。

**所有已识别且可在安全隔离环境中执行的适用条件都应覆盖。** 对有限且可承受的条件组合尽可能逐一验证；组合规模过大时，应覆盖每个适用维度的取值与极值，并系统地扩展两两、多因素和已知失效条件的组合，不得用“风险驱动”或“抽样”跳过单独可执行的条件及极端情况。无法实测的项目逐项写明环境／前提、原因、替代验证、影响及是否阻塞验收；关键条件未验证不得宣称功能已完整验收。测试须核对最终可观察结果。**XCTest 全绿不等于整个 `make test` 成功**：还须核对构建、签名等后置检查与完整命令退出状态；本地、CI、真实用户路径分别报告。

## 测试目录与入口

`BaileyTests/` 使用 `Unit/`、`Integration/`，并暂时保留尚未迁走的 `NativeUI/`、`WorkspaceUI/` 宿主用例（`Bailey` Scheme）。编辑器中需要直接测量 `NSTextView` 的行号像素、TextKit 2 视口和 IME 组合状态，放在 `Integration/Editor/NativeEditorLayoutTests`、`NativeEditorCompositionTests`；这属于 AppKit 组件集成而不是完整 App E2E，也不能简化为纯算法测试。`BaileyUITests/` 使用独立 UI Test Target（`Bailey-UI` Scheme），通过 `XCUIApplication` 操作完整 App，不导入产品模块。只有跨进程、从用户入口执行的操作放入这个目标。

每个文件按主要职责归档，不因混合用例机械拆类，不创建空目录或空测试。移动文件时核对工程发现路径，不能让它退出真实测试集合。

```sh
make test:FileTabPersistenceTests,NativeFileTabTests
make test:FileTabPersistenceTests,NativeFileTabTests,GitStatusModelTests,RecentCommitsViewTests
make test            # 完整宿主 XCTest
make build:ui        # 只编译独立 UI Test，不启动 App
make test:ui         # 独立图形会话中运行完整 App UI Test
```

本地迭代人工指定 `make test:类名1,类名2,...`（逗号分隔，不加空格）选择任意数量的宿主 XCTest 类；涉及共享组件时补测相关类。`make test:ui` 单独执行整个 UI Test Target，不混入本机日常宿主测试。`make test`、`make test:ui` 和 `make build:ui` 自动使用独立的 `chiimagnus.bailey.dev` 与 `build/DerivedData-Dev`，即使正式 Bailey 在运行也不会终止或覆盖它。`WorkspaceUITestSupport` 通过显式 Dev Bundle ID 启动 App，拒绝终止已有开发版实例；本机 GUI Runner 必须使用 Apple Development 签名而非强制 ad-hoc，否则可能被系统拒绝操作辅助功能树。公共启动入口在启动 Bailey Dev **之前**暂选 ABC 输入字母和路径，测试清理时恢复之前的输入法，并撤销 XCTest 临时启用的 Unicode Hex Input（若该输入法原本未启用）；此举不替代真实中文 IME 组词／候选测试。AppKit/XCUITest 仍争用同一桌面键盘焦点，要获得完全无干扰的真实 GUI 自动化须使用独立图形会话。CI 为每次非 Draft PR 都运行完整宿主 XCTest 和独立 App UI Test，不再根据文件变更猜测测试类名，避免迁移类名后执行零项。`ci/full` 可触发一次新的完整检查，测试结果必须对应本次 Head SHA。运行器由 [Makefile](../Makefile) 与 [共享 scheme](../Bailey.xcodeproj/xcshareddata/xcschemes/Bailey.xcscheme) 决定；不另建不参与 XCTest 的检查脚本，也不在产品启动时执行断言式自检。

## 测试层次

| 层次 | 证明什么 | 不证明什么 |
| --- | --- | --- |
| Unit | 模型、解析、状态不变量及边界 | 原生焦点、真实网络或完整 App 入口 |
| Integration | 临时文件、Git 仓库、持久化或受控后端之间的结果 | 模拟后端之外的真实 SSH 传输 |
| NativeUI | `NSWindow`／`NSHostingView` 中真实 TextKit、WebKit、滚动、焦点与撤销 | 从完整 App 菜单／点击入口走完路径 |
| WorkspaceUI | 真实 `ContentView`、项目、Dock、标签与多窗口的集成 | 独立进程的完整端到端 UI 自动化 |
| E2E | 启动完整 App，从用户入口操作并核对最终结果 | 不能由上面的测试数量或绿色状态推断 |

`BaileyUITests` 通过一次性本机临时文件／Git 仓库作为输入，并经真实 App 的系统文件选择器、Dock 和键盘操作核对结果。夹具创建时即登记 XCTest 清理，失败启动也不能留下文件；Git 子进程使用当前 Xcode 或 Command Line Tools 的真实 Git 二进制，绕开 `/usr/bin/git` 在 XCTest 沙盒中的 `xcrun` 包装器；标准输出定向至空设备、错误输出写临时文件，避免管道反压。原生文件选择器用窗口内的 `OKButton` 标识确认、`Escape` 取消，不能硬编码英文 `Add`/`Open`/`Cancel` 文案。Files/Git 行用原绝对／仓库相对路径的 AX 标签后缀区分同名项，文件 Tab 以独立的 AX 路径值区分重名标题，标识符不携带长路径；多窗口查询还须限定实际窗口。中文界面与超长 Unicode 文件树路径均有独立 App 回归；系统「前往文件夹」直接输入超长中文路径仍须单独验证，不由普通路径测试推断。构建 UI Target 不等于执行 GUI 测试：

| 完整用户路径 | 独立 UI 测试 | 仍保留的底层回归 |
| --- | --- | --- |
| 冷启动、命令面板搜索／Escape、从编辑器切换 Files 后真实方向键／空格焦点 | `WorkspaceSmokeUITests`、`WorkspaceFilesUITests` | `DockFocusP2RegressionTests`、`WorkspaceWindowIsolationTests` |
| 系统 Add Folder、Files 预览／打开、焦点恢复、文件去重、编辑保存到磁盘 | `WorkspaceFilesUITests` | `FileTreeTests`、`TreeRowHitTestingTests`、`FileTabPersistenceTests`、`NativeFileTabTests` |
| 大文件远距导航、文本替换、键盘撤销／重做、真实保存 | `EditorNavigationUITests` | `NativeEditorLayoutTests`、`NativeEditorCompositionTests`、`FileTabPersistenceTests` |
| Swift 与纯文本实际着色像素差异、原文未污染 | `EditorHighlightingUITests`（本机 Bailey Dev 已实测） | `NativeSyntaxHighlightingTests`、`HighlightQueryCacheTests` |
| Git Changes 状态、Git Graph 提交展开及工作区 Diff 分栏／统一、编辑／Undo／真实保存 | `WorkspaceGitUITests`（Git Changes／Git Graph／Split→Unified→Edit→磁盘字节路径已实测） | `GitStatusModelTests`、`NativeDiffTabTests`、`RecentCommitsViewTests` |
| 多窗口、设置、系统选择器取消 | `WorkspaceWindowsUITests` | `WorkspaceWindowCloseTests`、`WorkspaceWindowIsolationTests` |

这些 UI 用例不取代原有 `NSWindow`／`NSHostingView` 回归。未覆盖的完整外部路径（Finder/Dock 拖放、真实 SSH、脏文件保存冲突和不同窗口混合停靠）仍必须独立验收，不能因为 UI Test Target 存在而宣称已全部迁移；宿主 XCTest 也不等于 E2E。

按行为风险选择层次，不给每个功能机械配五套测试。纯计算优先单元测试；影响标签身份、焦点、保存、连接、停靠和窗口生命周期时，加入真实原生或工作区回归，并补足相应人工路径。

## 改什么，测什么

下表是选择依据，不是另一套执行器；完整测试集合仍由 Xcode 目标发现。

| 改动 | 相关测试 |
| --- | --- |
| 应用身份、Finder 类型注册与原生 Apple Event 系统入口 | `AppIdentityTests`、`WorkspaceWindowIsolationTests`；真实 Finder/Dock 进程外投递需获授权的受控图形会话 |
| Dock 模型、项目与上下文身份 | `DockWorkspaceTests`、`WorkspaceIdentityTests`、`PanelContextTests`；改变焦点许可或活动组时补 `DockFocusP2RegressionTests`、`WorkspaceWindowIsolationTests` 的原生输入与双窗路径 |
| 偏好、隧道配置和异常输入 | `AppSettingsTests`、`TunnelStoreTests` |
| 文件树、创建和项目文件索引 | `FileTreeTests`、`ProjectFileIndexTests` |
| Git 环境、刷新、写操作与失败状态 | `GitExternalRefreshTests`、`GitExecutionTests`、`GitStatusModelTests`、`GitBranchActionTests`、`GitRemoteBranchActionTests`、`GitTagActionTests`、`GitWorkspaceActionTests`、`GitStashActionTests`、`GitBranchDialogTests`、`GitTagDialogTests`、`GitWorkspaceMenuTests`、`GitStashDialogTests` |
| Git 图谱拓扑、引用标签、颜色、Worktree 菜单与窄侧栏 | `CommitGraphLayoutTests`、`RecentCommitsViewTests` |
| SSH 命令、断线、重连和过期结果 | `RemoteCommandsTests`、`RemoteLifetimeTests` |
| 文件、Diff 和原生内容保留 | `FileTabPersistenceTests`、`NativeFileTabTests`、`NativeDiffTabTests`、`DiffEngineTests`、`PaneRetentionTests` |
| 高亮坐标、渲染色与字体／撤销 | `TextCoordinateIndexTests`、`NativeSyntaxHighlightingTests` |
| 查询编译共享、固定资源失败与取消等待者 | `HighlightQueryCacheTests`、`NativeSyntaxHighlightingTests` |
| 原生组合输入、结束标记与最终替换 | `NativeEditorCompositionTests` |
| 原生远距离定位、文末与固定行高 | `NativeEditorLayoutTests` |
| Files 与所有 Git 树的命中与交互 | `TreeRowHitTestingTests` |
| 快照、历史与测试隔离 | `SessionStoreTests` |
| 标签及窗口整合路径 | `WorkspaceContentIdentityTests`、`WorkspaceWindowCloseTests`、`WorkspaceWindowIsolationTests` |

Git Graph 的引用和 Worktree 标签用数据模型及实际展示文案断言，原生绘制、点击、菜单、主题与尺寸仍用窗口和像素检查；不依赖 Vision OCR 在 CI 中反向识别截图文字。

测试断言应到达磁盘字节、Git index/HEAD、原生内容、窗口归属或实际焦点。需要前台原生输入的用例由运行环境保证焦点，不以窗口是否为 Key Window 决定跳过或放宽断言。只验证 mock 被调用、字段改变或事件送出，不足以守住最终结果。临时 Git 仓库若依赖固定分支名，应在 `git init -b` 时明确指定，不能依赖本机或 CI 的 `init.defaultBranch`。

`SessionStoreTests` 还在真实 `NSHostingView` 中挂载生产 `WindowRootView`，反复构造同一位置的 View，核对登记数量、恢复内容和原生编辑器身份不变。此测试覆盖根视图装配，不代替 `WindowGroup` 的系统恢复与独立 App 验收。

## 隔离环境

宿主 `Bailey` Scheme 的 TestAction 向 Debug 宿主传入 `--isolated-ui-test`。Makefile 的测试构建使用独立 Bundle ID `chiimagnus.bailey.dev`；独立 UI Test 显式通过 `XCUIApplication(bundleIdentifier:)` 启动 Bailey Dev，并传入 `--isolated-ui-test` 与一次性 `BAILEY_UI_TEST_RUN_ID`，不允许定位或终止正式 Bailey。

需要单独检查原生界面时使用相同签名的 Debug 包：

```sh
open -n -a "$PWD/build/DerivedData-Dev/Build/Products/Debug/Bailey.app" --args --isolated-ui-test
```

该模式为每个进程使用独立 UUID 快照和临时终端历史，不加载其他测试实例的项目，不启动已保存隧道。**开发版与正式版拥有不同 Bundle ID、配置路径和 DerivedData**，XCUITest 仅定位 Bailey Dev；正式版运行时也可执行宿主测试，无须强制退出用户 App。`make build:ui` 只编译。完整 UI 测试仍依赖当前 macOS 图形会话的前台键盘焦点；如果用户同时在 Helium 或正式 Bailey 输入，XCUI 键盘事件可能失败或打断用户，不能将不同 Bundle ID 冒称独立桌面。隔离 XCTest 宿主会移除自身菜单中的 `⌘Q` 退出快捷键：Mac 的键盘和前台应用状态仍由各进程共享，普通 Bailey 的退出快捷键不能误结束长时间运行的测试宿主；正式 Bailey 的菜单及保存退出保护不变。该隔离不是独立的图形登录会话，执行原生 UI 回归时仍应避免与用户正在进行的前台快捷键／鼠标操作互相干扰。刻意测试重启恢复时，两次启动显式传入同一有效 UUID 环境变量 `BAILEY_UI_TEST_RUN_ID`。

**正式设置不会被开发版共用。** Dev 使用 `~/.config/bailey-dev`，正式版仍使用 `~/.config/bailey`；两版的终端历史、窗口快照、语言及 Bark 凭据也分域。不同 Dev 测试之间仍可能共用开发配置，修改设置的用例须使用独立临时配置与 UserDefaults suite；尤其 Diff 原生重载测试不得继承用户持久化的编辑模式，否则正常的编辑保护会让测试误判为刷新超时。临时文件、Git 仓库和受控后端不得指向正式项目。

并行构建或测试同一项目时，为各任务指定独立的 `DERIVED_DATA`（如 `make test DERIVED_DATA=build/DerivedData-review`），避免共用产物被另一任务覆盖或重新签名；不得清理其他任务的构建目录。

Finder 拖进运行中 Bailey 时，**先核对 Finder 与 Bailey 两个窗口的屏幕边界，目标点不能落在 Finder 自身窗口或侧栏内**，否则会被 Finder 执行移动／废纸篓等本机操作，不能归因于 Bailey。核对系统当前选中项与拖动的真实 provider 数量；双窗口、文件树精确行和网页上传必须检查最终编辑标签／Shell／网页内容，而不是只看鼠标事件已派发。

Finder「打开方式」、Dock 文件投递和 `open -a Bailey` 仍指向正式 `chiimagnus.bailey`。对测试版发送文件时，必须显式使用 `open -n -a "$PWD/build/DerivedData-Dev/Build/Products/Debug/Bailey.app" --env "BAILEY_UI_TEST_RUN_ID=$UUID" "$TEMP_FILE"`；不能只传 `--isolated-ui-test` 或混用 `--args`（可能丢失系统文件事件）。随后核对接收 PID 的 Bundle ID 为 `chiimagnus.bailey.dev`，并检查窗口数、目标文件内容和原始 SHA-256。Dev 的 `LSHandlerRank=None` 不竞逐 Finder 默认文件处理程序；Bundle ID 分离不隔离 GUI 焦点，不能因此把物理 Dock 拖放视为已验收。

真实 SSH 只使用专用且获准的测试 master；不借用用户连接或结束其后台任务。真实 Windows SSH 回归必须**明确指定获授权的测试主机**。`BAILEY_P4_TEST_SSH_HOST` 是已有的共用参数名，P4 与后续 Git 外部刷新测试都使用它；未提供时专用用例按条件跳过，不能视为真实 SSH 验收。

`GitInteractiveRebaseTests` 检查固定与自动跟随项目的真实 PTY；`GitWorkspaceSSHTests` 检查专属远端临时仓库的 Push/Delete、ZIP 二进制内容、历史文件 index/工作区复位、Stash、Clean 和普通 FileTab Ignore；`GitExternalRefreshTests` 检查真实 SSH 外部写入后的可见面板自动更新和面板隐藏／App 后台暂停查询，并以可暂停的远端详情查询验证外部暂存不会因周期请求被跳过而遗失、视图隐藏时不会启动延迟补查；原生窗口测试须等 SwiftUI `onAppear` 完成后再模拟应用激活，不能用固定延迟代替订阅已挂载；`SSHGitRecoveryLiveTests` 验证专属 Windows 临时仓库在测试后端失联期间保留 Git 快照、拒绝写操作并于恢复后重新允许写操作。这些是实际 SSH 后端与原生面板集成验证，不是完整独立 App 的菜单 E2E。当前已获授权的 `windows` 主机完整执行命令是：

```sh
BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test
```

必须核对原生 XCTest 的实际执行总数、0 failures、0 skipped 和 Windows SSH 用例的 passed 记录；不能以不带环境参数的绿色 `make test` 冒充实机验收。没有获准测试主机的 CI 不应擅自连接用户设备。XCUITest 只允许启动 Bailey Dev；它不会因 Bundle ID 与正式版冲突而结束正式应用，但键盘与鼠标仍属于共享图形会话，用户持续输入时必须在独立 GUI 登录会话验收。

只清理本次创建且可确认归属的窗口、进程和数据，不按 App 名或宽泛目录清理。安装不包含重启，见 [development.md](development.md#本地安装)。

## 架构与异步检查

纯 Model 不引入 UI 或环境效果；其时钟、文件事实和外部输入按实际边界注入。按真实职责和调用关系检查分层，不以文件名、目录名或一次文本扫描代替验证。

职责重构须逐任务记录**原所有者 → 新的唯一所有者 → 被删除的重复状态／反向依赖 → 用户最终结果**。新增 Manager／Coordinator／Protocol 本身不算模块化；未使用的协议、镜像状态或只转发的壳必须删除。应用／窗口拆分覆盖外部路由、双窗隔离、关闭保存与恢复；各项完成前没有第二套全局登记或保存路径。

焦点和列表交互必须分别验证六种事实：**展开、选中、悬停、展示、激活、真实键盘焦点**。在同一动作可合法联动时，也要核对动作是否明确要求联动；目录展开不误打开文件，Files／Git 浏览可展示 Diff 但不抢另一组焦点，图谱提交展开不制造持续灰底，行边框只随实际键盘接收者变化。核对 `NSWindow.firstResponder`／原生 field editor、实际按键文本或 Shell marker、选区、当前展示内容与对应文件／Git 结果；`selected` 字段、视觉高亮、请求已排队或事件已发出都不能单独证明焦点成功。具体状态所有权见 [焦点协调边界](architecture.md#焦点协调边界)。

跨组件焦点迁移按 Dock／Files、Git、原生 Terminal／Editor／Diff、Browser、Palette 等**已触及的真实调用链逐段交付**；每段在原始实现基线和上一验收点上验证静态画面、中间帧、交互步骤、输入及对象身份**零 UI/UX 变化**，不把旧实现清理和重要 E2E 留到全部迁移结束。新旧策略不能同时争夺焦点；尚未迁移的功能继续独立维持原行为。按全部可行条件／组合验证，并逐条记录无法执行的系统级路径、原因、影响及 Gate 限制。

平台范围以 [architecture.md](architecture.md#平台范围) 为准：当前验收仍须尽可能覆盖受影响的 macOS 最低／当前系统、配置和原生路径，不为暂缓的 iOS、iPadOS 或 visionOS 建立测试目标或承诺兼容性。新规则的静态文档检查不等于架构迁移或产品验收通过。

使用明确事件和有界等待控制异步测试，覆盖取消、目标切换和乱序回写。保存检查发起时身份、真实写入和编辑期间的新内容；原生集成检查观察、绑定、嵌套变化、窗口菜单和重挂载，不只检查类型注解。

全项目 Swift 6 迁移收口必须在真实语言模式下构建、运行测试并严格验签。静态扫描、只改编译选项或屏蔽并发诊断不算通过。

## 性能与内存测量

先测共享热点，再减少主线程工作、重复 IO、计算和无关进程。骨架屏出现或数据读完不等于真实显示与输入可用。

| 用户路径 | 分开记录 |
| --- | --- |
| 打开编辑器 | 文本可见、可输入、高亮稳定 |
| 按键输入 | 文本／光标响应、高亮追上、主线程最长占用 |
| Git | 状态可用、详情完成、进程数、读取量、SSH 往返 |
| Diff | 数据读取、差异计算、TextKit 首屏、滚动与编辑 |
| 多标签和空闲 | 冷开、重复切换、峰值内存、关闭后稳定内存、CPU 与唤醒 |

在同一机器、配置和公开／合成样本上前后比较，记录提交、系统、硬件、屏幕、字体、布局与缓存。Debug 与优化构建分开，冷开和热操作分开；按实际改动选择小／中／接近上限文件、长行、密集高亮、大变更、多标签和本机／SSH，包含受影响的空内容、Unicode、二进制和超限边界。单独在 Release 优化配置运行 `@testable` XCTest 时，仅对隔离测试构建传 `ENABLE_TESTABILITY=YES`；正式 Release 保持原配置，优化 XCTest 也不能替代独立 App 的 GUI 内存验收。

热操作至少重复 30 次，记录样本数、中位数、p95 与最差值；少量冷启动只报中位数和最差值。代码编辑性能要分别测裸原生视图与真实加载 Tree-sitter／Neon 高亮的文件，不得拿前者的输入延迟代替后者；同步核对正文原字节及解析后的语法树。用 Instruments Time Profiler 查 CPU，卡顿但 CPU 不高时查等待；用 Allocations 检查视图与缓冲生命周期。确需阶段对齐时才增加轻量 signpost，不先搭埋点框架。

编辑器回归必须覆盖下列实际结果，不能只检查状态字段：

- **性能与坐标**：`NativeEditorLayoutTests`、`TextCoordinateIndexTests` 验证 382／1,000／10,000／100,000 行，折行两态、文首／中／末各 30 次编辑，以及至少 17 次交错远跳；检查滚动条、长行横滚、Unicode 命中及撤销后的真实字节。
- **真实绘制**：`NativeEditorLayoutTests`、`NativeDiffTabTests`、`NativeFileTabTests` 验证亮暗主题、行号与跨行选区、空行、查找栏展开、窗口缩放、Diff 及行号与首字形不互相遮挡；颜色和位置以窗口像素为准。
- **颜色取样**：像素回归先声明目标位图色彩空间，再读取该空间的通道并与同空间主题值比较。不要把 `colorAt` 返回的旧式 calibrated RGB 数值再次当成显示器 profile 进行转换；当前行号背景测试在 sRGB 目标中按实际位深读取通道，保留原容差，不通过放宽阈值掩盖差异。
- **十万行真实工作区闭环**：`PaneRetentionTests.testHundredThousandLineWorkspaceEditsSavesAndReleasesFile` 在真实 `WorkspaceDockView` 挂载超过旧 5 MiB 上限的十万行 Swift 文件，核对首／中／末位置、编辑、Undo／Redo、磁盘保存和关闭后所有权；它仍属于原生工作区测试，不得充当独立 Release 的键盘 E2E。`EditorNavigationUITests.testHundredThousandLineNavigationPreservesAllInterveningBytes` 则从完整 App 验证十万行首尾键盘导航、修改与实际写盘；两者均不替代 Release 资源测量。大文件压力测试另以隔离正式 App 按阶段记录首次可见时间、峰值与稳定物理内存、CPU 时间、真实滚动后的缓存波动及关闭后 heap 引用；`leaks` 只发现不可达内存，不等于关闭后所有可达 FileTab 已释放。
- **窗口生命周期**：`PaneRetentionTests.testClosingNativeWindowReleasesItsProjectBeforeSwiftUIDisappears` 直接关闭已关联 manager 的真实 `NSWindow`，验证关闭通知会同步注销管理器、清除所属项目和文件，而不是等待 SwiftUI `.onDisappear`；重复清理不得覆盖最后窗口快照。运行相关 `SessionStoreTests`、`WorkspaceWindowIsolationTests` 和窗口关闭测试，避免只修内存而破坏窗口恢复。
- **生命周期**：`PaneRetentionTests` 验证 Dock 重挂载不换编辑器、五轮各五个编辑器的输入与释放，以及真实 `WorkspaceDockView` 执行 `Close Files`／关闭整个项目（含焦点停在待关闭编辑器、旧 `NSScrollView` 仍被持有）。关闭时立即核对标签所有权已解除、滚动容器不再挂载原文档、原视图语法解析已停用；AppKit／SwiftUI 可能延迟释放旧 `NSView`，故另在宿主窗口销毁后核对两轮原生视图和文件弱引用全部归零，不以单次 10 秒窗口内析构代替清理语义。外部重载、旧窗口缓存、转为二进制也不得保留过期文档。独立 Release 须补充打开／关闭／重开后的 heap、Allocations 与实际 GUI 对照；XCTest 对象释放不等同于长期内存回落。
- **保存**：`FileTabPersistenceTests` 和 `NativeFileTabTests` 验证原生 AX 编辑后的脏状态和写盘，并用受控远端挂起写入构造「关闭项目／关闭文件／关闭窗口／退出应用时，另一个原本干净的文件突然变脏」的并发时序，逐项核对未保存正文、实际磁盘、关闭否决和重试成功；多窗口使用 `WorkspaceWindowIsolationTests` 核对各自目标。完整 App 的 ⌘S 另须核对前台焦点、真实磁盘字节与重启结果；后台事件派发不能直接算成功。

`WorkspaceWindowIsolationTests.testTwoMountedWorkspaceManagersSaveTheirOwnNativeAXBuffers` 在两个真实 `ContentView`／`NSWindow` 中使用同名不同路径文件，通过原生 AX 修改两个缓冲区、经各自 `WorkspaceWindowModel.saveSelectedFile()` 保存并核对独立磁盘字节、脏状态和原编辑器身份。隔离 XCTest 无法保证目标窗口实际成为系统 Key Window，因此这只证明工作区保存路由和最终写盘，不代替独立 App 的 ⌘S 菜单、窗口焦点 E2E。

保留已有增量高亮、懒加载、刷新合并、视图复用及 SSH 批量操作。优化不能牺牲编辑内容、超时反馈、机器身份、Unicode 坐标、撤销和无障碍。测量日志可能包含用户数据，分享前脱敏，不默认入库。

没有测量就不宣称提速。历史数据是带环境的观测，不是永久预算；当前没有统一内存硬阈值。实验和失败证据留在对应 Feature 资料，长期文档只提炼会影响后续行动的约束。

## 人工回归

受影响功能的全部可行人工操作、环境差异和极端条件应尽可能逐项执行；不把未触及的其它项目硬加进回归，也不把没有执行的项目写成通过。

| 路径 | 检查结果 |
| --- | --- |
| 项目与 SSH | 本机／远端同名路径隔离，切换、断线、重连和失败不串目标 |
| 停靠与窗口 | 上下／左右组合、跨区移动、关闭、双窗口菜单和焦点，后台 Shell 不重启 |
| 文件与编辑 | 创建／重命名、中文输入、查找、撤销、滚动、保存失败和关闭保护 |
| Files 外部刷新 | 外部程序在根目录及已展开目录新建、覆盖、重命名、移动、删除文件；核对真实磁盘与文件树一致。检查面板隐藏／重新打开、App 前后台、切项目／SSH 连接、失败保留旧列表，以及空闲目录查询次数；未来改为事件驱动时还须证明无周期读取 |
| Git 与 Diff | 工作区／索引／历史、首次提交、特殊路径、失败草稿、两侧滚动及真实写入 |
| Git 外部刷新 | 独立 CLI 修改本机后由文件事件更新，空闲时不周期查询；SSH 前台 5 秒兜底；Git 面板隐藏但 App 在前台时底栏仍更新，App 后台暂停，恢复前台重新读取，失败后可手动重试 |
| Git Graph 多级菜单 | 多 Ref、多 Worktree 下用真实鼠标和键盘依次展开 `+N → Branch → Worktree → 目录 → 操作`。菜单保持打开时分别触发无数据变化的手动刷新、外部文件修改及分支／Worktree 变更，调整侧栏宽度并核对菜单宿主没有被替换，录屏确认同一菜单不因纯查询进度或布局切换而关闭，真实目标变化后操作仍经过校验；检查超过 10 秒的悬停、首次加载、明暗与窄宽面板；短 Branch（含 Worktree 数量标记）不可被拉宽，`+N` 与提交标题必须仍可见。`GitStatusModelTests` 还须验证观察依赖不因无变化刷新失效；静态 XCTest 菜单结构不能冒充真实悬停 |
| 共享树 | Files、工作区、暂存和历史一致；窄面板、放大字体、长名称和动作命中 |
| 浏览器 | 表单、滚动、前进后退和重挂载；默认浏览器交接与开发服务 |
| Finder 与原生文件拖放 | Finder 右键／Dock／空态（无项目时新文件拒绝）、编辑区、顶部标签栏新增与复用 FileTab，分屏非选中组／空组／普通编辑与 Git 面板落点及已打开文件不搬组；系统「文件 → 打开文件…」⌘O、每组「＋」原生文件多选与窗口焦点、添加本机目录 ⇧⌘A 仅选目录；Projects 文件打开标签、文件夹添加目录项目，重复项目不增加，旧 `pinnedFile` 仅作历史恢复；Files 目录行/文件行/根标题/留白复制到指定本机目录，核对原文件 SHA-256、新副本、可见树刷新、部分成功、同名冲突 Sheet 和失败复制无部分目录；Ghostty 纯路径无 Return、SSH 拒绝 Mac 路径、WebKit 网页上传但不另开标签。单／双窗口原始目标、取消／晚到（包括发起后切项目、指定 Dock 组消失而拒绝错误落点）、本机／SSH 相同路径与 50+ 混合重复文件，以及内部标签／Projects 重排互不干扰 |
| 设置与恢复 | 隔离配置的即时传播、快照和真实重启，区分显示恢复与任务恢复 |
| 通知与命令面板 | 定位原会话、键盘选择和文件实际打开，而非仅收到事件 |
| 视觉、键盘与基础无障碍 | 两种外观、长文案、键盘焦点与动作目标、原生按钮辅助功能名称、不同字体；纯架构改动前后无变化 |

视觉改动使用同窗口尺寸、内容和动作的前后并排录屏；截图和自动检查作为补充，不能把静态图当成焦点、拖动或滚动验收。纯架构重构对受影响区域逐任务对照原生截图和交互，不夹带重设计。VoiceOver 的逐项语音导航与专项焦点适配不作为普遍验收门槛；仅在明确需求涉及屏幕阅读器时单独验收，现有基础无障碍语义仍须保留。

## 提交证据

说明新增／调整了什么测试、实际运行了什么命令及完整结果、覆盖了哪些环境与高风险边界、验证了哪些原生与用户路径，以及失败、跳过、阻塞和未测部分。与内存、生命周期或性能有关的改动附前后测量；普通文档任务不制造性能数字。

CI 的执行与签名限制见 [release.md](release.md#pr-检查)。报告区分本地验证、Actions、安装、重启和发布；任何一个成功都不能替代其他步骤。
