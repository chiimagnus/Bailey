# P1：验证基线与快照事件解耦

**Goal：** 建立真实行为和 Swift 6 迁移诊断基线；先切断“任何 UI 变化都触发窗口持久化”的耦合，为随后逐模块换用 Observation 创造安全条件。

**Non-goals：** 本阶段不批量改写所有 ObservableObject、不变更存储键/快照格式、不启动或重启正式 App；诊断性 Swift 6 编译不等于正式切换语言模式。

**Approach：** 从当前 `SessionStore.SessionSnapshot`、`TerminalManager.makeWindowSnapshot` 和 `TerminalHistoryStore` 的**真实持久化字段**反推触发点。保留 `TerminalManager.saveAll/windowClosed` 唯一写入入口与 500ms 防抖，直接连接确实影响快照的业务更改；UI 刷新、Shell 每个 OSC 133 事件、编辑器逐键输入不等于快照内容改变，不能重复写盘。先以现有 XCTest 确定写盘/关闭状态，再做 Swift 6 诊断，不预造通用 Observer/事件总线。

**Acceptance：** baseline + 诊断具实际命令/退出码；项目/标签/布局/网址/工作目录的**已存字段**能正确写盘，关闭最后窗口/退出保留终端历史且无多窗口覆盖；普通 Git UI、OSC133 状态或逐键编辑不会无意义触发全窗口自动保存；本阶段已删除 `autosaveObservation = objectWillChange` 旧路径。

**Rules：** 单一 `TerminalManager` 窗口 owner；`SessionStore` 的 `workspaceSnapshot` 格式与 `TerminalHistoryStore` 保持不变，历史内容与当前实时进程不能混淆；用户磁盘数据不参与测试。每个变更任务同提交移除对应旧路径。

---

<a id="p1-t1"></a>
## P1-T1 核对迁移基线并取得 Swift 6 诊断

**类型：** 探索／证据任务，不修改生产源码，不为报告制造提交。

**源码锚点：** `kero/App/keroApp.swift::WindowRootView/KeroCommands`、`TerminalManager.init/saveAll/windowClosed/restore`、`Project.register`、`PaneTab.init`、`SessionStore.save/load`、`kero.xcodeproj/project.pbxproj`、`KeroTests/`。

**步骤：** 记录执行时 HEAD 和共享工作树修改（禁止覆盖并行未提交改动），运行 `make doctor`、`make test` 及必要的 `make build`，阅读失败和已有测试实际覆盖面。诊断性临时 Swift 6 编译通过 `xcodebuild` 命令行覆盖 `SWIFT_VERSION=6`（其余 scheme、destination、derived data 和包锁定选项沿 `Makefile`），**不写 pbxproj**；按主 actor、后台 IO、Objective-C/Ghostty/WebKit 桥接分类真正出现的警告／错误。若因依赖或签名阻塞，记录具体原因和最小复验方法，不猜数量。

**验证与交付：** `make doctor`、`make test`；诊断记录包括工具链、完整命令、退出码、首个根因及对 P2～P7 的影响，写入 P1-T1 的 `todo.toml` note。临时诊断构建失败属于证据，不冒充通过；不操作 `/Applications/Kero.app`。

**提交：** 只读任务无源码提交，完成时通过 Skill 状态工具记录 `no-commit-reason`。

---

<a id="p1-t2"></a>
## P1-T2 将窗口自动保存改为语义变更触发

**Files／入口：** `kero/Workspace/TerminalManager.swift::init/saveAll/makeWindowSnapshot/windowClosed`；`kero/Workspace/Project.swift::tabs/selectedTabID/register`；`kero/Workspace/DockWorkspaceModel.swift::move/place/removeTool/resize`；`kero/Workspace/PaneTab.swift::customName`；`kero/Terminal/TerminalSession.swift::workingDirectory`；`kero/Browser/BrowserView.swift::BrowserTab.urlString`；`KeroTests/SessionStoreTests.swift` 和必要的窗口／身份测试。

**根因：** 当前 `TerminalManager.autosaveObservation` 订阅 `objectWillChange.debounce(500ms)`，而此事件由 Project、Dock、Terminal、Browser、Tab 的 Combine 链转发；任意一层先改为 Observation 都可能漏存，同时旧事件在对象值改变前送出。

**实现：** 逐字段追踪 `makeWindowSnapshot`：项目名单/名称/目录/SSH host/选择、tabs 名称及 `contextSession`、Dock root、会话本机 cwd、FileTab 路径与编辑器光标/滚动、BrowserTab URL、DiffTab 的必要身份。实现一条由**实际影响已保存字段的修改入口**触发的窗口级 `requestSave`（500ms 合并，退出与最后窗口立即冲刷），让随后 P2～P5 的宏迁移继续复用它；不引入每属性永久回调、额外 global notification 或第二份快照真源。**明确排除**未被快照保存的 Git status、Shell 每次 OSC133 `commandLifecycle`、逐键的 `FileTab.text/isDirty`，而 `editorState` 改动本来不靠 `@Published` 逐帧保存，切换/关闭/最终冲刷仍须准确采集。静态 `saveAll` 是多窗口写入/退出最终保证，不能在普通 debounce 时误删 TerminalHistory sidecar。**同 Task 移除 `autosaveObservation = objectWillChange` 旧订阅、无用转发，不删仍供旧 SwiftUI UI 展示的订阅直到 P4/P5 具体替换。**

**验证：** `make test ONLY_TESTING=KeroTests/SessionStoreTests` 并在此类增加最小真实窗口变更/500ms 合并/最后窗口及退出保存测试，校验 UserDefaults 的**最终序列化数据**；编辑器仅验证生命周期结束/布局改变会持久化正确光标状态，不要求逐键写盘；含 BrowserTab URL 和现行 Dock 结构；**旧 Info 工具的解码兼容将在 P5-T1 连同旧测试清除**，这里不新增或扩大旧 Info 恢复保证。必要时运行 WorkspaceIdentityTests。若测试构造终端会启动 PTY，使用 XCTest 原有隔离模式，不操作用户正在运行的 Session。`make build`。

**提交：** 持久化语义事件接入、回归检查与旧自动保存订阅删除一起原子提交。

---

## 阶段完成门槛

不得带着“UI 改动触发保存”的旧广播放行后续 Observation 迁移；若实际证明某些内容需要特定回调，直接在本任务的真实 owner 补齐，并更新对应验证，不添加兜底轮询。
