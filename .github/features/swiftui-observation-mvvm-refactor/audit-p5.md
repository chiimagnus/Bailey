# Audit P5 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P5-T1 Dock 布局唯一状态与拖动手势改用 Observation
- [x] P5-T2 PaneTab 和 Project 的身份、选择及关闭流程收敛
- [x] P5-T3 窗口 TerminalManager 收敛成唯一窗口 ViewModel
- [x] P5-T4 App／WindowRoot 的 Observation 装配及多窗口菜单焦点
- [x] P5-T5 Ctrl-Tab 快速切换及标签／项目侧栏的局部状态收敛
- [x] P5-T6 移除 WebKit Diff 与 Pierre 依赖

## 任务到文件的映射

- P5-T1：`ddc4333`；`kero/Workspace/DockWorkspaceModel.swift`、`kero/Workspace/Project.swift`、`kero/UI/WorkspaceDockView.swift`；`DockWorkspaceTests`、`PaneRetentionTests`、`SessionStoreTests`。
- P5-T2：`134ac76`；`kero/Workspace/Project.swift`、`PaneTab.swift`、`TerminalManager.swift`、`kero/UI/{ContentView,WorkspaceDockView,Panels,Components,Panes}`；关闭与焦点回归。
- P5-T3：`3918150`；`kero/Workspace/TerminalManager.swift`、`kero/App/keroApp.swift`、`kero/UI/ContentView.swift`、项目、Git、命令面板和原生弹窗接线；`SessionStoreTests`、`PaneRetentionTests`。
- P5-T4：`3918150` 已原子实现 WindowRoot `@State`、FocusedValues、KeroCommands，本任务无新代码提交；隔离 Debug 双窗口菜单、命令、关窗、恢复实测。
- P5-T5：`998b249`；`kero/UI/Panes/TabSwitcherView.swift`、`ContentView.swift`、`Components/WorkspaceChrome.swift`、`Support/FPSCounter.swift`、`KeroTests/PaneRetentionTests.swift`。
- P5-T6：`6b3081b`、`3d72aff`；`kero/Git/Diff{ViewerView,Engine,NativeSurface,SyntaxHighlighter,TextView}.swift`、`KeroTests/DiffTabTests.swift`、本地 Pierre 包和 Xcode 工程依赖移除；`docs/{GIT,DEPENDENCIES,PERFORMANCE}.md`。

## 发现项

- 审计中未发现达到 finding 门槛的本阶段回归：WindowGroup 每窗口独立 Manager，Dock/项目/标签与切换器的状态 owner 不重复；原生 Diff 已接入真实 Git 标签而非孤立测试组件，原 Pierre 路径及旧上行发布器搜索无残留。
- 问题核对：原生 Diff Edit 工具栏切换后不刷新的回归已在 `3d72aff` 修复并加可见 TextKit 测试；全量之前由 WebKit 离屏虚拟化引发的超时已通过删除无关依赖与原生测试解决。
- 没有将 Peekaboo/AppleScript 合成 Control 键的释放效果冒充真实物理键盘验收；控制器事件与 Esc 已由 XCTest 和隔离 Debug 交叉验证。

## 修复日志

- `6b3081b`：复用历史原生 Diff，彻底删除 Pierre 与 WKWebView 差异链。
- `3d72aff`：修正原生 Diff 可见编辑器模式切换和测试偏好污染。
- `998b249`：迁移 Ctrl-Tab/FPS，并覆盖预选、确认、取消与停止生命周期；审查发现无需追加兼容包装。

## 验证日志

- `make test`（`/tmp/kero-native-full-mode-fixed.log`）→ **PASS：68/68**。
- `make test ONLY_TESTING=KeroTests/DiffTabTests` → **PASS：9/9**，包括原生滚动／撤销／重挂载、可见模式切换、SSH 断线与在途读写。
- `make test ONLY_TESTING=KeroTests/PaneRetentionTests`（`/tmp/kero-p5-t5-final-pane.log`）→ **PASS：11/11**。
- `make build`（`/tmp/kero-p5-t5-final-build.log`）→ **PASS**；`codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` → **PASS**。
- `rg` 检索被删除的旧观察中继、`@FocusedObject`、旧 P5 `@StateObject`、Pierre API → **0 匹配**；Xcode 项目不再引用 Pierre。
- 隔离 Debug：Unified/Split 原生渲染中文/emoji/增删色；两窗口不同项目的菜单可用项随 key 焦点切换；新浏览器仅加到目标窗口；关闭空窗口保留另一窗口；关闭最后窗口后隔离快照为 1 窗口、1 项目、19 标签，随后 File > New Window 真实恢复原项目与 `zsh/README.md`；**PASS**。
- 全程正式 `/Applications/Kero.app`（PID 37163）未替换或退出。

## Gate（是否允许进入下一阶段）

- 结论：**Go**
- 理由：六项任务均有提交或明确已提交实现的验收证据；本阶段独有的状态、焦点、原生资源、真实 Diff 副作用及关闭/恢复均经测试与隔离运行验证。

## 最终状态与剩余风险

- 当前状态：**Resolved（本阶段无 Open finding）**。
- 剩余风险：关闭未保存 File/Diff 时可能丢失编辑、批量关闭中途取消不能回滚已关闭标签，均为 P5 计划明确保留的既有 UX 缺陷，本次纯 Observation 重构不修改；需要另案处理。实际物理 Ctrl-Tab 释放测试未做，工具合成的 flagsChanged 存在不确定性，未冒称物理按键已验证。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

