# P2：设置与主题的 Observation 迁移

**Goal：** 迁移真正被 SwiftUI 消费的全局 `AppSettings` 与主题刷新状态，保留终端真实配置响应；**不强迫只由 AppKit NSTableView 消费的隧道服务迁移到另一套桥接**。

**Non-goals：** 不改用户配置文件位置或格式、不更换内核配色机制、不强制把经过验证的 AppKit 表格改写为另一套 UI。

**Approach：** 保留单个 `AppSettings.shared` 及现有 TOML/Theme 缓存；Settings、Chrome 等 SwiftUI View 消费 Observation，终端表面实际更新由窗口视图读取必要设置变化并调用现有 `TerminalManager.refreshAppearance()`。单独的 `Theme.changes` 空广播用一份有效可观察的 revision 或直接依赖 AppSettings 字段代替，不增加同名镜像调色板。`TunnelManager.$tunnels/$states → TunnelSettingsView.NSTableView.reload` 是真实原生事件订阅：依 AGENTS.md **可继续使用 Combine**，不增加 `withObservationTracking`/notification 桥接来替换它。

**Acceptance：** 设置改动实时影响 UI、终端和原有磁盘配置；主题切换后 SwiftUI 与长期原生表面全部刷新；移除 `AppSettings.@Published`、`TerminalManager.settingsObservation` 与 `ThemeChanges.objectWillChange` 旧链。不改变不属于 SwiftUI 状态的 TunnelManager/AppKit 表格原生事件协议，避免强制引入第二套事件桥。

**Rules：** `~/.config/kero/config.toml` 和 `tunnels.toml` 分离；遵守 `docs/SETTINGS.md`、`docs/LOCALIZATION.md`、`docs/SECURITY.md`，不得在隔离 UI 实例更改全局设置或启动真实的保存隧道进行测试。对照 P1 基线，设置页控件、排列、亮/暗配色、字号、主题切换反馈、终端光标与字体**均不可有任何 UI/UX 差异**；不能借迁移重画设置页面。

---

<a id="p2-t1"></a>
## P2-T1 配置状态转 Observation，保持写入与终端设置传播

**Files／入口：** `kero/App/AppSettings.swift::AppSettings`（各设置属性的 `didSet/save/applyAppearance`）、`kero/App/SettingsView.swift::SettingsView`、`kero/Workspace/TerminalManager.swift::init/settingsObservation/refreshAppearance`、其余真正读取 `AppSettings.shared` 的 View、`KeroTests/AppSettingsTests.swift`。

**根因：** `AppSettings` 是唯一可写配置 owner，但 `@Published` 既承担 UI 通知又被 `TerminalManager` 的 `Publishers.CombineLatest4` 当作配置更新事件；直接改宏会切断终端重配。

**实现：** 将 `AppSettings.shared` 原实例改为 `@Observable`；Settings/其它现有消费者直接读取，需要修改时使用 `@Bindable`。保持已实现的 `didSet → save`、语言重启前保存、TOML 现有校验和**仅保留用户手工配置的 workspace 字段**的真实行为（源码未实现“保留任意未知键”，不提出虚假要求）。窗口端在读取 fontFamily/size/thicken、theme/dark/light、Option-as-Alt、cursor 等相关设置的 `onChange` 里调用已有 `manager.refreshAppearance()`；当前旧 `Publishers.CombineLatest4` 承担的语义一次覆盖，不新建设置事件总线或从设置层反向依赖窗口层。**本 Task 一次删除 `AppSettings.@Published`、`settingsObservation`、Setting View 的旧 `@ObservedObject`、无消费者 Combine import**；必须实际核对每个设置影响终端的字段，没有原生结果不称迁移完成。

**验证：** `make test ONLY_TESTING=KeroTests/AppSettingsTests`，通过 `AppSettings(configURL: 临时路径)` 验证配置变更与磁盘往返，补新 Observation 的字段跟踪／终端刷新触发检查；`make build` 并验签。`--isolated-ui-test` 本身**不会隔离用户的 config.toml**。本机 macOS 27.2 已额外实测通过 LaunchServices `open -g -n --env CFFIXED_USER_HOME=<临时Home> --env HOME=<临时Home> -a <Debug Kero.app> --args --isolated-ui-test`：测试实例真实读取／写入的 `~/.config/kero/config.toml` 被限制到 `build/UIBaselineFixture/home/`，而正式用户配置前后 SHA-256 不变。使用该**已验证的进程级配置隔离**在原生设置 UI 调整字段并检查 Shell PID、字体实际渲染、光标/Option 配置与主题实际配色；后续 SDK/系统若不支持这种隔离，则只允许只读观察，不得改用户真实配置。不得只断言 Settings View 文本。

**提交：** 配置 Observation 接入、终端订阅迁移、旧 Publisher 删除及测试一起提交。

---

<a id="p2-t2"></a>
## P2-T2 用 Observation 替换全局主题重绘信号

**Files／入口：** `kero/App/Theme.swift::ThemeChanges/reloadSelection`；**全部已检索到的主题实际消费者**：`kero/UI/Components/WorkspaceChrome.swift`、`kero/UI/Components/BottomToolbarView.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/CommandPaletteView.swift`、`kero/Git/DiffViewerView.swift`、`kero/Browser/BrowserView.swift`、`kero/Terminal/TerminalFindBar.swift`；涉及颜色源的 `kero/Git/GitPanel.swift`、`kero/Files/FileTreePanel.swift` 亦应核对，测试沿用 `KeroTests/AppSettingsTests.swift`。

**根因：** 主题颜色通过静态 `Theme` 解析，`Theme.changes` 却是空 `ObservableObject`，必须手工调用 `objectWillChange.send()` 才能通知读静态颜色的视图。

**实现：** 保留 `Theme.selection` 原有 `OSAllocatedUnfairLock`：它是非隔离 `NSColor` 动态颜色 provider 的必要线程安全缓存，不是多余的可写 UI 镜像。旧 `ThemeChanges: ObservableObject {}` 是纯空重绘信号，可改为单一 `@Observable` 修订值（由 `Theme.reloadSelection` 修改）或让各 View 直接读取已观察的 AppSettings/theme 字段，以实际消费者最少改动决定；不能并行保留空 Publisher。原生 Ghostty、WebKit diff、TextKit 按现有具体 appearance 更新入口响应，不造主题订阅中心。**同 Task 删除 `Theme.changes.objectWillChange.send()`、旧 `@ObservedObject themeChanges`/空类与无用 Combine import**，保留真实颜色缓存。

**验证：** `make test ONLY_TESTING=KeroTests/AppSettingsTests`、`make build`；主题修订值变更应能触发全部真实消费者，而非仅窗口外框。**不能在普通隔离 Debug 实例中修改共享的用户配置文件**；复用 P2-T1 已实测的 `CFFIXED_USER_HOME` 临时 Home 进程隔离进行主题变更和原生对照，另用 `AppSettings(configURL:)` 检查状态/解析。不得误把进程级隔离失效的运行继续当安全测试；正式用户配置的 SHA-256 必须保持不变。静态颜色缓存应仍线程安全；对照 P1 同条件的亮/暗主题原生截图，核对窗口/树行/标签/Diff/终端的实际颜色及切换时机，不接受因替换刷新源产生闪烁、重置滚动或焦点。

**提交：** 主题真源接入与所有旧重绘订阅删除同一原子提交。

---

## 阶段完成门槛

设置／主题的 SwiftUI 消费者全部改用 Observation；已替代的旧 `AppSettings.$...` 与 `Theme.changes.objectWillChange` 一项不留。明确保留的 Combine **仅**服务 `TunnelManager.$tunnels/$states → TunnelSettingsView.NSTableView` 的原生 reload，WebKit KVO 则由 P4 单独审查。当前 `TunnelStore.parse` 对历史文件缺少 `direction` 时默认 local 是现有用户数据兼容，不能不经数据迁移就删；`TunnelPIDFile` 的 PID 启动时间校验也非冗余围栏。
