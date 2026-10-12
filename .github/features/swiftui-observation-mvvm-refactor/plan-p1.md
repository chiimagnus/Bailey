# P1：验证基线与快照事件解耦

**Goal：** 建立真实行为和 Swift 6 迁移诊断基线；先切断“任何 UI 变化都触发窗口持久化”的耦合，为随后逐模块换用 Observation 创造安全条件。

**Non-goals：** 本阶段不批量改写所有 ObservableObject、不变更存储键/快照格式、不启动或重启正式 App；诊断性 Swift 6 编译不等于正式切换语言模式。

**Approach：** 先复用 XCTest 和构建真源核对行为；沿 `TerminalManager → Project → PaneTab → 内容对象` 与 `DockWorkspaceModel` 找全当前快照实际记录的字段及触发事件。用现有窗口 owner 安排一次防抖写盘，持久化改变由**实际内容或布局变更**触发，而不是依赖任意 `objectWillChange` 重绘事件。

**Acceptance：** 基线和实际 Swift 6 诊断有记录；窗口/项目/标签/布局/网址/终端目录等已持久化字段改变会触发正确快照，结束运行和关闭最后窗口仍保存完整数据；`autosaveObservation = objectWillChange` 路径在本阶段已删除。

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

**实现：** 从 `makeWindowSnapshot` 中的实际持久化字段反推最小变更源：项目名单／选中、项目元数据、标签及名称／上下文、Dock、终端目录、浏览器地址。保持窗口 manager 统一防抖写入及退出时强制冲刷；在拥有字段的变更入口向窗口 owner 发出明确的“需保存”信号，包含仍依赖框架事件的目录／网址变化，避免另建全局事件总线、镜像快照或重复可写状态。先接入所有实际来源、验证写盘，再**同 Task 删除旧 `autosaveObservation = objectWillChange`、重复写盘触发与无消费者分发代码**；尚供 UI 使用的 Combine 转发仅保留到其具体界面迁移任务，须有可核对的消费者。

**验证：** `make test ONLY_TESTING=KeroTests/SessionStoreTests`，补充变更触发／防抖／窗口关闭／最终历史冲刷的最小 XCTest（使用隔离或临时存储，绝不写真实快照）；按 `KeroTests/WorkspaceIdentityTests` 验证本机／远端同名目标没有串写。观察结果必须是读取**正确的实际序列化快照**，而非只检查触发计数；`make build` 并验签。

**提交：** 持久化语义事件接入、回归检查与旧自动保存订阅删除一起原子提交。

---

## 阶段完成门槛

不得带着“UI 改动触发保存”的旧广播放行后续 Observation 迁移；若实际证明某些内容需要特定回调，直接在本任务的真实 owner 补齐，并更新对应验证，不添加兜底轮询。
