# P2：应用设置、主题与长期隧道的独立状态迁移

**Goal：** 先完成不依赖窗口项目树的应用级状态，消除最上游的设置 Combine 发布链，使后续窗口／终端改造不再依赖设置的 `$property` Publisher。

**Non-goals：** 不改用户配置文件位置或格式、不更换内核配色机制、不强制把经过验证的 AppKit 表格改写为另一套 UI。

**Approach：** 直接在目前的唯一 App owner 上迁移，不新增配置容器。保存和系统主题刷新由设置变更直接触发；原本仅为静态调色板刷新而存在的空 `ObservableObject` 由真正可观察的变化来源替代。长期隧道管理独立于任何终端标签，迁移其展示状态但保持真实进程归属。

**Acceptance：** 设置在 Observation 下更改即持久化，主题与终端外观及时更新；隧道状态、睡眠唤醒与独立服务进程生命周期不受 UI 重建影响。旧 `AppSettings.$...` 订阅、`Theme.changes.objectWillChange.send()` 和 `TunnelSettingsView` 的无必要 Combine 管道在各自 Task 内移除。

**Rules：** `~/.config/kero/config.toml` 和 `tunnels.toml` 分离；遵守 `docs/SETTINGS.md`、`docs/LOCALIZATION.md`、`docs/SECURITY.md`，不得在隔离 UI 实例更改全局设置或启动真实的保存隧道进行测试。

---

<a id="p2-t1"></a>
## P2-T1 配置状态转 Observation，保持写入与终端设置传播

**Files／入口：** `kero/App/AppSettings.swift::AppSettings`（各设置属性的 `didSet/save/applyAppearance`）、`kero/App/SettingsView.swift::SettingsView`、`kero/Workspace/TerminalManager.swift::init/settingsObservation/refreshAppearance`、其余真正读取 `AppSettings.shared` 的 View、`KeroTests/AppSettingsTests.swift`。

**根因：** `AppSettings` 是唯一可写配置 owner，但 `@Published` 既承担 UI 通知又被 `TerminalManager` 的 `Publishers.CombineLatest4` 当作配置更新事件；直接改宏会切断终端重配。

**实现：** 让现有配置 owner 使用 `@Observable`；View 以实际数据流直接读取或在需要双向绑定处用 `@Bindable`。保留每个设置已有的验证／`didSet` 写盘、TOML 未知字段保留、错误处理、语言重启确认；通过**设置 owner 的明确变更入口或现有终端配置调用路径**触发 `refreshAppearance`，不增加镜像配置状态。验证接通后，同 Task 删除配置的 `@Published`、`SettingsView.@ObservedObject`、`settingsObservation` 和已无消费者的 Combine import；保留 `AppSettings.shared` 作为现有唯一进程级设置身份，不另造容器。

**验证：** `make test ONLY_TESTING=KeroTests/AppSettingsTests`，补真实字段变化／存盘往返与设置传播的最小检查；`make build` 并验签。隔离 UI 只检查显示、绑定和主题切换，不在共用配置上做真实写入；终端字号、Option-as-Alt、光标与主题均应随设置生效。

**提交：** 配置 Observation 接入、终端订阅迁移、旧 Publisher 删除及测试一起提交。

---

<a id="p2-t2"></a>
## P2-T2 用 Observation 替换全局主题重绘信号

**Files／入口：** `kero/App/Theme.swift::ThemeChanges/reloadSelection`；`kero/UI/Components/WorkspaceChrome.swift`、`kero/UI/Panes/TabSwitcherView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/Git/DiffViewerView.swift`、`kero/Browser/BrowserView.swift`、`kero/Terminal/TerminalFindBar.swift` 等以 `Theme.changes` 重新绘制的实际消费者，以及 `KeroTests/AppSettingsTests.swift`。

**根因：** 主题颜色通过静态 `Theme` 解析，`Theme.changes` 却是空 `ObservableObject`，必须手工调用 `objectWillChange.send()` 才能通知读静态颜色的视图。

**实现：** 在 `Theme` 已拥有的选中主题／解析结果变化处提供单一可观察信号，或让消费者直接读取 P2-T1 已建立的唯一设置值；根据代码实际依赖选择，不并存双重通知。视图读取相应 Observation 属性，使系统外观、主题切换正确刷新；静态配色解析和 Ghostty 主题映射仍由 `Theme` 负责。**同 Task 删除 `ThemeChanges: ObservableObject`、旧 `objectWillChange.send()` 和各消费者已不需要的 `@ObservedObject`**，并确保 WebKit/编辑器中无法靠 SwiftUI 自动重绘的原生表面有明确主题更新动作。

**验证：** `make test ONLY_TESTING=KeroTests/AppSettingsTests`，`make build` 和隔离原生外观验收：窗口、Git、Files、差异、浏览器、终端查找条、编辑器和终端表面在亮／暗色和自选主题间切换后全部更新，不只是 SwiftUI 外框刷新。

**提交：** 主题真源接入与所有旧重绘订阅删除同一原子提交。

---

<a id="p2-t3"></a>
## P2-T3 长期隧道状态与 AppKit 表格事件迁移

**Files／入口：** `kero/Remote/Tunnels/TunnelManager.swift::TunnelManager.start/commit/reconcile/state`、`kero/Remote/Tunnels/TunnelSettingsView.swift::init/reload`，必要时 `TunnelDefinition.swift`，针对性 `KeroTests/` 测试。

**根因：** `TunnelManager.$tunnels/$states` 被 `TunnelSettingsView` 的 NSTableView 以 Combine 订阅；它不是 SwiftUI 界面状态，不能简单删除订阅或假定 View 重绘会调用 `reload()`。

**实现：** 隧道 manager 作为唯一进程级服务／可观察状态持有者改为 `@Observable`，保留 `start/reconcile/TunnelRunner` 及唤醒、终止通知。对仍为 AppKit 的 NSTableView，在实测确实需要时使用一条**明确的 manager → view 更新回调／Observation 追踪桥**触发 `reload`，而非复制一份 `tunnels` 或 `states`；同 Task 删除 `$tunnels.combineLatest($states)` 等废弃订阅。只有经实际 UI 验证原生 SwiftUI 有等价收益时才考虑替换 NSTableView。

**验证：** 现有隧道定义的校验与文件往返、启用／禁用及状态刷新使用临时数据或受控 runner 测试；补最小 UI reload 检查，`make test ONLY_TESTING=KeroTests/RemoteLifetimeTests` 及 `make build`。不连接用户 SSH、不打开真实监听端口；真实唤醒和长期运行若未测需记录边界。

**提交：** 隧道可观察状态、UI 适配、旧 Publisher 清除及测试一起提交。

---

## 阶段完成门槛

设置／主题／长期隧道的**当前消费者**全部改用新状态或必要的原生桥接；未处理的 app-wide Publisher 不得留在此阶段之外作为无说明的“过渡兼容”。
