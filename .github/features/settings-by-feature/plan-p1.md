# P1：按功能重组 Settings 左侧导航与原有控件

**Goal：** 现有所有设置能够按 Common、Text Editor、Terminal、Browser、File Manager、Git Manager、Projects、连接、通知定位，保留 native Settings 结构、持久化和真实业务效果。

**Non-goals：** 不改全局 TOML 格式、不增加未实现的业务偏好、不实现布局编辑器或 Exclude 搜索/监听、不定制 VS Code 的网页式 Settings UI。

**Approach：** 直接修改 `SettingsView.SettingsPage` 和同一原生 `Form` 的分支，把旧混杂的 `workspaceSettings` 拆进模块页面；值仍唯一绑定现有 `AppSettings.shared`，不用任何设置注册系统、自动反射菜单或泛型设置项框架。无实际配置项的 Browser/File Manager 在首次功能接入前展示简洁空状态；#5 在 `File Manager` 页面加首个可用控件。

**Acceptance：** 旧设置功能无丢失无重复，新分类直观，File Manager `files.exclude` 的未来接入点明确，Projects 未来停靠布局设置有正确归属，完成时不创建虚构配置键。

**Rules：** 遵守 `AGENTS.md`：SwiftUI 原生、相同 Scene、中文本地化、相同持久化路径、同任务测试与文档、及时删除被淘汰的旧 `workspaceSettings`；所有验证在隔离环境进行，不访问正式钥匙串。

---

<a id="p1-t1"></a>
## P1-T1 Settings 按功能分区与现有状态迁移

**源码锚点：** `Bailey/App/SettingsView.swift.SettingsPage`（当前 5 个 case／`List(selection:)`／`Form switch`、`generalSettings/terminalSettings/workspaceSettings/notificationSettings/portForwardingSettings`）、`Bailey/App/AppSettings.swift`（`@Observable` 属性、`save/resetToDefaults` 与 `workspaceConfiguration`）、`Bailey/App/BaileyApp.swift`（Settings Scene、变化即时传播）、`Bailey/Resources/Localization/Settings.xcstrings`、`Bailey/Remote/Tunnels/TunnelSettingsView.swift`、`Bailey/Workspace/{DockWorkspaceModel,SessionStore}.swift`。

1. **Red：** 从现有真实控件和 `AppSettings.save()` 记录各项唯一归属与生效点：General 外观／语言／Toolbar／Reset；Terminal 共用明暗主题、字体、光标、Option、历史；Workspace 面板字号/Git 文件布局/编辑折行；Connections 端口转发和通知。**实际缺陷：** `SettingsView.hasCustomizedPreferences` 漏掉 `gitAlwaysAcceptCheckout`、`gitAlwaysProceedPushTag`，但 `AppSettings.resetToDefaults` 会清零；新增仅修改这两项后「恢复默认」仍应可点的回归，覆盖原配置读写/重置及与别的偏好组合；**现有 `AppSettingsTests` 只测配置模型，不会触达 `SettingsView.hasCustomizedPreferences` 的按钮禁用条件**，须增加真正挂载 SwiftUI Settings 的 NativeUI/隔离实例测试，先证明按钮在原实现不可用。Bark、隧道和语言的存储不属于 AppSettings 的普通 TOML；不应被页面移动或 Reset 误改。
2. **Green：** `SettingsPage` 增加 Common、Text Editor、Terminal、Browser、File Manager、Git Manager、Projects，并保留 Port Forwarding、Notifications；右侧仍沿原生 `Form`，不随 Dock Group 数量复制。Common 放外观模式、**全 App 共用的 `themeDark/themeLight`**、**Projects/Files/Git 共用的 `panelFontSize`**、语言/Reset；Editor 放 `wrapLines`；Terminal 放字体/光标/Option/历史；**Git Manager 放 `gitViewMode` 和当前工作标签 Git 状态底栏的 `toolbarVisibility`**；Projects 留给后续实际布局功能，现阶段显示简洁说明，不制造配置或按钮；Browser/File Manager 同样不造假设置。#5 P3-T1 直接在此 File Manager 页面接入 `files.exclude`。补齐 Reset 可用性对 Git 两项确认偏好的判断，**保留当前配置键、写入路径及 AppSettings 单一状态**。在本任务删除旧 `workspaceSettings` 和重复/无用的导航/控件代码，不保留两套分类。
3. **Projects 后续接口边界：** `AppSettings.workspaceConfiguration` 目前是**只读 `let`**，`save()` 重读 `config.toml` 中手工配置的初始布局。未来确实需要图形编辑默认布局时，应另外增加受验证的写入入口并保证仅影响**新项目**；现有项目/窗口由 `SessionStore` 快照保管，不可把它重置当作默认布局更新。本任务只安排入口和文案，不编造可用的布局 setter、录制器或恢复按钮。
4. **覆盖与闭环：** 运行 `AppSettingsTests`、相关 `DockWorkspaceTests` 及原生 Settings GUI；验证全部原配置往返与重置，尤其**仅更改任一 Git 确认偏好时 Reset 可用，点击后原键确实回到 false**；新 View 测试不得直接修改真实 `AppSettings.shared` 配置或钥匙串，在独立 Home/隔离进程挂载实际 Settings 后核对 `.disabled` 状态和磁盘键值，不能用对私有计算属性的静态搜索冒充 GUI 通过。逐页实测中英、明暗主题、窄宽窗口、大字号、键盘/辅助功能、多窗口 `⌘,` 与关闭重开、语言重启、空页面、独立 Home 以及无效/只读配置；原来主题即时生效、终端字体/光标、编辑器折行、Git 底栏/布局、全局面板字号都必须真正在原对象传播。保持 `workspace.groups/weights/...` 手工布局设置与所有已存窗口快照字节不意外变化，Bark Keychain/隧道不可因导航重建或触发真实发送。缺失系统版本按测试文档逐项记录。更新 `Settings.xcstrings`（中英）与 `docs/features/settings.md`、必要 `docs/ui.md`；同任务删除已替代的分类、重复控件/死代码，中文原子提交。

---

## Phase Audit

只有上述设置项全部迁移、真实 Settings 各页验收和最大可行组合测试完成时才创建 `audit-p1.md`。#5 的 `files.exclude` 未实现前，不能把它报告成已经存在的偏好。
