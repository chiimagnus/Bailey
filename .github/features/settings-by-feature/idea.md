# Settings：按功能与 Panel 分类的原生设置导航

需求归属：[Issue #44](https://github.com/chiimagnus/Bailey/issues/44)。已有两栏窗口来自已完成的 [Issue #11](https://github.com/chiimagnus/Bailey/issues/11)；本计划仅重排设置功能归属，不重建窗口。

## 当前实现与根因

`SettingsView.SettingsPage` 目前是 General、Terminal、Workspace、Notifications、Port Forwarding。右侧已经是原生 `NavigationSplitView` + `Form`；但 `workspaceSettings` 同时包含面板字号、Git 文件布局、编辑器折行，`generalSettings` 混入 Git 状态底栏的显示设置。应只调整导航与控件归属，不重建设置架构。`AppSettings` 已是唯一 TOML 偏好源；`WindowRootView` 已监听主题、字体、终端相关设置的变化；`TunnelManager`、Bark Keychain 分属现有服务，不能因导航迁移重建。

`DockWorkspaceConfiguration` 从 `config.toml` 读取的是**新项目默认布局**（`workspace.groups/selected/weights/add-actions/edge-threshold`）；`AppSettings.workspaceConfiguration` 当前为初始化后不可赋值的 `let`，`save()` 会重新读取 TOML 中手工填写的布局字段。`TerminalManager + SessionStore` 保存的是**具体项目与窗口的当前布局快照**。未来若增加布局编辑，须单独设计可写入、可验证的初始布局设置；不能把「默认布局编辑」与「恢复窗口布局」合并成一个重置按钮。Browser 目前没有 `AppSettings` 偏好；Files 的 `files.exclude` 尚未实现。

## 产品规则

- 原生 macOS `⌘,`、SwiftUI `NavigationSplitView`、右侧 `Form/Section` 不变，左侧改成**按功能命名的页面**，不是按 `Workspace` 等混合容器。单个 Dock 分屏实例不生成一份自己的设置副本。
- **常用**：全 App 外观模式、`themeDark/themeLight` 的暗／亮配色主题、全工具面板共享的 `panelFontSize`、语言、恢复默认。主题颜色由编辑器、终端和窗口共用，面板字号由 Projects／Files／Git 共用，**各自只提供一份控件**。
- **文本编辑器**：现有软折行；为以后编辑器真实选项留同一页面，但不生成无用状态。
- **终端**：现有字体、字号、字形加粗、光标、Option→Alt、终端历史与预览（保留原有底层服务）。不再重复编辑 App 共用的暗／亮配色主题。
- **浏览器**：独立页面，目前无持久化偏好，显示清楚的简洁空状态，不造假开关。
- **File Manager**：独立页面；`files.exclude` 控件由 [#5 P3-T1](../file-manager/plan-p3.md#p3-t1) 接入，不再在混合 Workspace 页面挂载。此页未接入前显示明确空状态，不重复配置源。
- **Git Manager**：现有文件展示布局（`gitViewMode`）和工作标签底部 Git 状态工具栏显示（`toolbarVisibility`）；它们使用原有配置键。Git 操作弹窗直接存的确认偏好保持原路径与行为，本次不额外复制一套控制。
- **Projects**：先提供独立功能入口，明确将来在这里管理**新项目默认 Dock 布局**与**现有项目／窗口快照**；目前没有已实现的布局编辑控件，允许简短空状态。**本期不开发布局编辑器，也不迁移已有快照格式**。
- **连接**：原有端口转发。**通知**：Bark 设置保留，隔离实例不读取钥匙串。
- **已确认的现存缺陷，随本次重组修复：** `SettingsView.hasCustomizedPreferences` 漏掉 `gitAlwaysAcceptCheckout`、`gitAlwaysProceedPushTag`；但 `AppSettings.resetToDefaults()` 会重置它们。当用户仅修改这两项时「恢复默认」可能错误禁用。在同任务补齐条件和测试，不增设第二套偏好判断状态。
- 未来扩展的 Exclude 不该造成「一个开关影响全部」：`files.exclude` 属 File Manager，`search.exclude` 属未来跨文件搜索，watcher 排除属 [#40](https://github.com/chiimagnus/Bailey/issues/40) 的实际监听路径。可复用 Glob 匹配语义，但配置键与作用边界分别持有；当前 `⌘P` 不自动继承 `files.exclude`。

## 非目标

本次不开发浏览器新偏好、任何文件或跨文件搜索、Git 新功能、可配置布局录制／恢复 UI、设置全文搜索与关键词索引、不增加新的 `AppSettings` 文件／中间缓存／配置迁移或第 2 套 NavigationSplitView。不动 `README.md`。

## 尽可能完整的验收

1. 每个原有选项位置唯一、实际值准确、输入及失焦、Tab/方向键/VoiceOver 可用；从旧 Workspace 挪走后不能留下第二份；Settings 重开、重新启动、reset 不改变语义。
2. 主题/亮暗切换、语言重启提示、字体/终端实际渲染、编辑器折行、Git 布局、项目工具栏及面板字号、Bark 与端口转发真实结果不变。Settings 页面导航不结束隧道、不发意外通知、不主动打开用户钥匙串。
3. File Manager 页与 #5 排除控件的最终入口唯一，错误反馈明确；不污染未来 `search.exclude` 和 watcher 规则。Projects 页清楚区分新项目初始布局与各窗口快照。
4. 完整组合测试：Mac 15.6+／当前、中文／英文、浅暗/主题、常规/窄窗口、大字号、键盘/鼠标、独立 Settings 窗口与多主窗口、前台/后台、模拟无配置/旧配置/无效值/无写权限、隔离 Home、关闭重开/重启。逐项记录未具备条件的补验、影响和是否阻塞。

真实实现和验收时同步更新 `docs/features/settings.md`、`docs/ui.md` 与相关功能页；新的 File Manager 偏好由 #5 的相应任务同步这些文档，不提前把计划写成已实现。
