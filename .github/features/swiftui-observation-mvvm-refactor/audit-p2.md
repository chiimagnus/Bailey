# Audit P2 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P2-T1 配置状态转 Observation，保持写入与终端设置传播
- [x] P2-T2 用 Observation 替换全局主题重绘信号

## 任务到文件的映射

- P2-T1（`0b05d11`）：`kero/App/AppSettings.swift`（唯一设置 owner，`@Observable`/TOML）、`kero/App/SettingsView.swift`（`@Bindable`）、`kero/App/keroApp.swift::WindowRootView`（9 项设置 `onChange`）、`kero/Workspace/TerminalManager.swift::refreshAppearance`、`kero/Terminal/{TerminalSession,KeroTerminalView+Ghostty}.swift`（原生生效链）、Git/Editor/Dock/Projects/ToolPanel SwiftUI 消费者、`KeroTests/AppSettingsTests.swift`、`docs/SETTINGS.md`。
- P2-T2（`889172a`）：`kero/App/Theme.swift::ThemeChanges/reloadSelection/selection`；11 处旧主题订阅所属的 Browser、Diff、TerminalFind、CommandPalette、TabSwitcher、WorkspaceChrome、Projects/ToolPanel、BottomToolbar，以及审查确认实际读静态主题的 `kero/Editor/FileViewerView.swift`、`kero/Git/{GitPanel,RecentCommitsView}.swift`、`kero/Files/FileTreePanel.swift`、`kero/Shared/Tree/TreeRowStyle.swift`、`kero/UI/{WorkspaceDockView,ContentView}.swift`、`kero/UI/Panes/PanelContentView.swift`。原生尾端为 Ghostty、SourceTextEditor.updateNSView、WebKit Diff 的 NSHostingView/NSView、`KeroTests/AppSettingsTests.swift`。
- 证据（本机、未随 Git 提交）：`evidence/p1-baseline/README.md` 及 P2 原生截图、`/tmp/kero-observation-p2-t1-{settings-test,full-test,build}.log`、`/tmp/kero-observation-p2-t2-{settings-test-continued,full-test-continued,final-build}.log`。

## 发现项

未发现符合门槛的未解决 P2 回归或数据破坏问题。旧 `AppSettings.@Published`、`TerminalManager.settingsObservation`、`ThemeChanges.objectWillChange.send` 与 `@ObservedObject themeChanges` 均已删除；没有保留两套同步状态。保留 `Theme.selection` 的 `OSAllocatedUnfairLock`（服务任意线程的原生 NSColor 动态 provider），`TunnelManager.$tunnels/$states → TunnelSettingsView.NSTableView` 仍是实际需要的 Combine/AppKit 更新桥接，不在本阶段删除。

审计途中确认 P2-T2 **必须超出原 11 个旧订阅接入更多真正的静态 Theme 消费者**：P2-T1 移走设置全局 Publisher 后，TextKit 编辑器、Git 树/提交图谱和 Dock 等同 dark slot 下换色不会因系统 `colorScheme` 更新而重绘。已在 `889172a` 同一任务修正并以原生屏幕双向换色验证，属任务内必要补齐，不是新独立功能。

## 修复日志

- `0b05d11`：配置状态切换到唯一 `AppSettings @Observable`；9 个真实终端设置源在窗口 `onChange` 后调用已有 `TerminalManager.refreshAppearance → TerminalSession.applyTheme → Ghostty`，不改 Shell 身份/配置文件格式。删除 `Publishers.CombineLatest4` 和所有 `AppSettings.@Published`。
- `889172a`：主题改用一个有效的 Observation revision；所有相应 SwiftUI View.body 读取真实 revision 并让已有原生 `updateNSView` 应用颜色，不使用 `.id` 重新挂载。移除空对象广播、保留唯一静态选中主题颜色缓存。没有额外审计修复提交。

## 验证日志

- P2-T1 `make test ONLY_TESTING=KeroTests/AppSettingsTests` -> **PASS 3/3**；`make test` -> **PASS 36/36**；`make build` 与 `codesign --verify --deep --strict` -> **PASS**。
- P2-T1 使用 `CFFIXED_USER_HOME` 临时 Home 的原生 Debug Kero：设置窗口 600×632、94 AX 控件与重构前一致，正文像素完全一致（22 个底部抗锯齿边缘像素不影响布局）；字体 13→14pt 真正使终端字形重绘、Option-as-Alt 和 Block→Bar 改动写入独立 TOML、System→Light→Dark 终端外观变化，Shell PID 不变 -> **PASS**。
- P2-T2 `make test ONLY_TESTING=KeroTests/AppSettingsTests` -> **PASS 4/4**，新增 `withObservationTracking` 及 `Theme.terminal(dark:)` 最终颜色缓存断言；`make test` -> **PASS 37/37**，`build/DerivedData/Logs/Test/Test-kero-2026.10.13_11-44-59-+0800.xcresult`；`make build` + 严格 codesign 验签 -> **PASS**。
- P2-T2 原生 Debug 临时 Home 在同 dark slot 中 Default Dark→Ayu→Default Dark：已有 STTextView 编辑器、Git 状态树及真实 Recent Commits 图、Dock/项目侧栏、Ghostty Shell、WebKit Diff（左右正文+控制保持）、Kero 空白 Browser 页面都实际随之改变像素；Shell 直接子进程 PID 42746 未变化，受控文件未写入 -> **PASS**。`~/.config/kero/config.toml` 原文件 SHA-256 全程维持 `e57aa9b3550971296c547220b1fa2c66bc640e1a3b08616ac3f35724f9076c2a`；正式 `/Applications/Kero.app` PID 60367 始终存活未操作。
- `rtk python3 ... todo validate`、`phase-complete --phase p2`、`git diff --check` -> **PASS**；源码全文搜索旧设置/主题订阅表达式无命中；`TunnelSettingsView.swift` 原生 NSTableView Combine 链仍在运行路径。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P2-T1/T2 的真实设置状态、原生终端、配色缓存、SwiftUI 主题订阅及重要 AppKit/WebKit 绘制尾端均已核对，并通过全量测试、构建验签和临时 Home 的双向主题切换；无 P2 正确性阻塞项。

## 最终状态与剩余风险

- 当前状态：`Resolved`（P2 阶段审计结束）
- 剩余风险：完整编辑器长文滚动和焦点压力、SSH 会话隧道 UI、P3 文件/Git 状态迁移、P4 原生桥接迁移、P5 多窗口生命周期与恢复、P7 Swift 6 语言模式编译均属于后续对应阶段，P2 不将这些未测结果标记为完成。独立原生验收 App 已停止，正式 App 未更新安装。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
