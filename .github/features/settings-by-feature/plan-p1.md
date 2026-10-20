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

1. **Red：** 先以当前 UI 和测试记录旧所有设置的唯一页面、值、默认值和最终生效点：General 主题／语言／Toolbar／Reset，Terminal 明暗主题/字体/光标/Option/历史，Workspace 面板字号/Git 布局/编辑折行，Connections 端口转发/通知。单独核查 Git 对话框所持久化的 `git.always-accept-checkout`／`git.always-proceed-push-tag` 与 `AppSettings.save`，重排不能丢；`AppSettingsTests` 对所有键值往返/重置/未知配置边界保留现有断言。
2. **Green：** `SettingsPage` 增加 Common、Text Editor、Terminal、Browser、File Manager、Git Manager、Projects，并保留 Port Forwarding、Notifications；每个功能一条侧栏入口，右侧仍沿原生 `Form`，不以用户实际创建的 Dock Group 动态复制设置。Common 放外观模式、**App 共用的 `themeDark/themeLight` 暗／亮配色选择器**、**Projects/Files/Git 共用的 `panelFontSize`**、语言/Reset，Editor 放 `wrapLines`，Terminal 放字体/光标/Option/历史（原 Terminal 颜色选择器迁入 Common，不能两页同时存在），Git 放 `gitViewMode`，Projects 放 `toolbarVisibility`；已有 Bark/Tunnel 控件、启动及状态保持原样。Browser/File Manager 暂无真实属性时只显示轻量空状态，**不新建占位设置模型**。#5 P3-T1 直接给此处 File Manager 页面接入 `files.exclude` 规则编辑器。移除已无调用的旧 `workspaceSettings` 混合结构，不保留两套导航。
3. **Projects 后续接口边界：** 未来面板默认布局调整应读写 `AppSettings.workspaceConfiguration`，只影响**新项目**；浏览或恢复正在使用的项目/窗口布局应读 `SessionStore` 的项目快照且需要独立安全确认。本 task 只整理页面归属及文案，不改变这两套数据、不写假 UI/配置或承诺马上提供记录按钮。
4. **覆盖与闭环：** 执行 `AppSettingsTests`、`DockWorkspaceTests` 和受影响的原生 Settings GUI；逐页实测中文/英文/明暗/不同主题/窄宽/字体缩放、键盘与辅助功能、多窗口/打开 `⌘,`/切页面/关闭重开、语言重启提示、空设置类别、复原默认与自定义值、`config.toml` 正常/无效/权限失败、独立 Home，确认相同终端/浏览器实例没有因为迁移重建、已运行端口转发不被结束、Bark 不发误通知。若不能实测 macOS 15.6 等条件，按测试文档列出准确限制和补验。按现有本地化规范维护 `Settings.xcstrings` 中英项、同步 `docs/features/settings.md` 和 `docs/ui.md`；本任务删掉废弃分类分支、旧死代码后独立中文提交。

---

## Phase Audit

只有上述设置项全部迁移、真实 Settings 各页验收和最大可行组合测试完成时才创建 `audit-p1.md`。#5 的 `files.exclude` 未实现前，不能把它报告成已经存在的偏好。
