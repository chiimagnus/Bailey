# P1：验证基线与快照事件解耦

**Goal：** 建立真实行为和 Swift 6 迁移诊断基线；先切断“任何 UI 变化都触发窗口持久化”的耦合，为随后逐模块换用 Observation 创造安全条件。

**Non-goals：** 本阶段不批量改写所有 ObservableObject、不变更存储键/快照格式、不启动或重启正式 App；诊断性 Swift 6 编译不等于正式切换语言模式。

**Approach：** 从当前 `SessionStore.SessionSnapshot`、`TerminalManager.makeWindowSnapshot` 和 `TerminalHistoryStore` 的**真实持久化字段**反推触发点。保留 `TerminalManager.saveAll/windowClosed` 唯一写入入口与 500ms 防抖，直接连接确实影响快照的业务更改；UI 刷新、Shell 每个 OSC 133 事件、编辑器逐键输入不等于快照内容改变，不能重复写盘。先以现有 XCTest 确定写盘/关闭状态，再做 Swift 6 诊断，不预造通用 Observer/事件总线。

**Acceptance：** 重构前的**原生 UI 截图与交互基线**、测试与诊断均可复核；项目/标签/布局/网址/工作目录的**已存字段**能正确写盘，关闭最后窗口/退出保留终端历史且无多窗口覆盖；普通 Git UI、OSC133 状态或逐键编辑不会无意义触发全窗口自动保存；本阶段已删除 `autosaveObservation = objectWillChange` 旧路径。

**Rules：** 单一 `TerminalManager` 窗口 owner；`SessionStore` 的 `workspaceSnapshot` 格式与 `TerminalHistoryStore` 保持不变，历史内容与当前实时进程不能混淆；用户磁盘数据不参与测试。每个变更任务同提交移除对应旧路径。

---

<a id="p1-t1"></a>
## P1-T1 核对迁移基线并取得 Swift 6 诊断

**类型：** 探索／证据任务，不修改生产源码，不为报告制造提交。

**源码锚点：** `kero/App/keroApp.swift::WindowRootView/KeroCommands`、`TerminalManager.init/saveAll/windowClosed/restore`、`Project.register`、`PaneTab.init`、`SessionStore.save/load`、`kero.xcodeproj/project.pbxproj`、`KeroTests/`。

**步骤：** 记录执行时 HEAD 和共享工作树修改（禁止覆盖并行未提交改动），运行 `make doctor`、`make test` 及必要的 `make build`，阅读失败和已有测试实际覆盖面。**在任何生产源码迁移前**，先对**当前正在运行的 `/Applications/Kero.app` 做只读窗口截图**，把它作为长期保留的正式 App UI/UX 视觉参照；不得为了采集而点击其标签、切焦点、执行菜单、关闭窗口或中断终端。照片落在 `evidence/p1-baseline/`，保留原图、不随新构建覆盖，记录 App 版本、窗口尺寸与 macOS 环境；该版本号相同也**不代表安装包与 HEAD 字节级一致**。再使用当前源码构建的**隔离 Debug App** 建立可操作、可复现的 UI/UX 基线：固定系统版本、显示缩放、窗口大小、亮/暗主题、语言、受控项目和内容；记录主窗口/Dock、Files/Git、终端/查找、编辑器/Diff、浏览器、命令面板、设置、现有菜单/弹窗的代表性**原生截图**，及拖拽、快捷键、焦点、悬停/滚动、加载/失败/取消、关闭/重开的**当前实际行为**。只采与重构影响相关的代表性状态，不建额外自动化框架，不改用户配置或正在运行的正式 App。诊断 Swift 6 时**不能把 `SWIFT_VERSION=6` 作为全局命令行参数直接施加给第三方 SwiftPM 依赖**：已实测该参数令 `STTextKitPlus` 的两个非并发安全全局属性编译失败，无法诊断 Kero 本身。应在 `build/` 下创建**仅用于诊断的工程副本**（源文件仍引用当前仓库），只在副本的 App/Test target 把 `SWIFT_VERSION` 改为 6；使用与 `Makefile` 相同的 scheme、destination、锁定依赖及签名配置，并将诊断产物放在独立 DerivedData 目录。**绝不改原 `kero.xcodeproj/project.pbxproj` 或第三方源文件**。按实际编译结果分类 MainActor、后台 IO、Objective-C/Ghostty/WebKit 和测试诊断；目前实际首次 App 根因在 `KeroTerminalView` 的 `nonisolated deinit` 访问 `Timer?`，并伴随 WebKit delegate 签名及 TextKit 插件闭包的编译警告，后续 P7 需逐根因验证，而非假称 Swift 6 已通过。若因依赖或签名阻塞，记录具体原因和最小复验方法，不猜数量。

**验证与交付：** `make doctor`、`make test`；`todo.toml` 的 P1-T1 note 记录**正式 App 只读截图和隔离 Debug 截图/交互记录各自的实际路径**、固定的对照条件、无法采集的场景；正式 App 参考用于长期视觉回看，行为对照以同一源码版本的隔离实例为准。截图包含用户项目/终端内容时只保存在本机 evidence，不提交公开 Git。任务 note 还须记录工具链、完整诊断命令、退出码、首个根因及对 P2～P7 的影响。截图应在后续阶段可直接读取对照；动态内容要控制或注明，不能拿不同系统渲染误判为代码变化。临时诊断构建失败属于证据，不冒充通过；不操作 `/Applications/Kero.app`。

**提交：** 只读任务无源码提交，完成时通过 Skill 状态工具记录 `no-commit-reason`。

---

<a id="p1-t2"></a>
## P1-T2 将窗口自动保存改为语义变更触发

**Files／入口：** `kero/Workspace/TerminalManager.swift::init/saveAll/makeWindowSnapshot/windowClosed`；`kero/Workspace/Project.swift::tabs/selectedTabID/register`；`kero/Workspace/DockWorkspaceModel.swift::move/place/removeTool/resize`；`kero/Workspace/PaneTab.swift::customName`；`kero/Terminal/TerminalSession.swift::workingDirectory`；`kero/Browser/BrowserView.swift::BrowserTab.urlString`；`KeroTests/SessionStoreTests.swift` 和必要的窗口／身份测试。

**根因：** 当前 `TerminalManager.autosaveObservation` 订阅 `objectWillChange.debounce(500ms)`，而此事件由 Project、Dock、Terminal、Browser、Tab 的 Combine 链转发；任意一层先改为 Observation 都可能漏存，同时旧事件在对象值改变前送出。

**实现：** 逐字段追踪 `makeWindowSnapshot`：项目名单/名称/目录/SSH host/选择、tabs 名称及 `contextSession`、Dock root、会话本机 cwd、FileTab 路径与编辑器光标/滚动、BrowserTab URL、DiffTab 的必要身份。实现一条由**实际影响已保存字段的修改入口**触发的窗口级 `requestSave`（500ms 合并，退出与最后窗口立即冲刷），让随后 P2～P5 的宏迁移继续复用它；不引入额外 global notification、通用 Observer 总线或第二份快照真源。**先列出真实写入入口并逐个接线**：项目添加／关闭／重排与 `customName/customDirectory/sshHost/pinnedFile`（含 `ProjectsPanelView` 的直接赋值）、标签添加／移除／重命名与 context session、Dock 组／选中／比例变化、OSC7 工作目录、`FileTab.updatePath`、浏览器导航 URL。必要时将 View 的直接写属性改成已有 owner 的语义方法或最小变更回调，禁止遗漏因为值从某个 View 直接赋入而没有执行 `requestSave` 的路径；初始化和恢复期间不保存半成品快照。**明确排除**未被快照保存的 Git status、Shell 每次 OSC133 `commandLifecycle`、逐键的 `FileTab.text/isDirty`，而 `editorState` 改动本来不靠 `@Published` 逐帧保存，切换/关闭/最终冲刷仍须准确采集。静态 `saveAll` 是多窗口写入/退出最终保证。现行 `saveAll(false)` 从 `TerminalSession.lastHistorySnapshot` 获取缓存内容，并与本次 `makeWindowSnapshot` 重新生成的 `historyKey` 配对写入 `TerminalHistoryStore`；没有当前快照可引用的历史时清空 sidecar 是**清理陈旧项**，不应为此制造新持久化层。保留同一批 snapshot/sidecar 的键值一致性及终态 `captureLive: true` 的 scrollback 更新；本 Task 只调整 `requestSave` 事件来源，**不拆散现有存储配对**。**同 Task 移除 `autosaveObservation = objectWillChange` 旧订阅、无用转发，不删仍供旧 SwiftUI UI 展示的订阅直到 P4/P5 具体替换。**

**验证：** `make test ONLY_TESTING=KeroTests/SessionStoreTests` 并在此类增加最小真实窗口变更/500ms 合并/最后窗口及退出保存测试，校验 UserDefaults 的**最终序列化数据**；隔离验证**恢复的会话带有缓存历史 → 仅 Dock/Browser 改变 → 新快照 `historyKey` 能在同步写入的 sidecar 找到对应内容 → 关闭窗口抓取最新历史**，以及无会话引用时孤儿历史正确清理；不得只断言 `requestSave` 被调用。编辑器仅验证生命周期结束/布局改变会持久化正确光标状态，不要求逐键写盘；含 BrowserTab URL 和现行 Dock 结构；**旧 Info 仍可能存于用户快照**；这里不改存储格式，P5-T1 保留最小数据过滤并测试整份 `AppSnapshot` 能读取含 Info 的历史 Dock，不能删 enum case 导致全窗口恢复失败。必要时运行 WorkspaceIdentityTests。若测试构造终端会启动 PTY，使用 XCTest 原有隔离模式，不操作用户正在运行的 Session。`make build`。

**提交：** 持久化语义事件接入、回归检查与旧自动保存订阅删除一起原子提交。

---

## 阶段完成门槛

**没有可复核的重构前 UI/UX 基线，不启动 P2～P7 的界面迁移。** 后续每个 Task 都对受影响的相同场景做原生截图/交互对照，不能只验数据状态和编译；发现 UI/UX 差异必须在该 Task 内修回。

不得带着“UI 改动触发保存”的旧广播放行后续 Observation 迁移；若实际证明某些内容需要特定回调，直接在本任务的真实 owner 补齐，并更新对应验证，不添加兜底轮询。
