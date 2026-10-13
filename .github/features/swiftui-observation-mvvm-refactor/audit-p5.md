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

## 发现 F-02

- 任务：`P5-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/App/keroApp.swift:WindowRootView.onDisappear + kero/Workspace/TerminalManager.swift:windowClosed`
- 摘要：`单独关闭窗口缺少保存失败时的预关闭拦截`
- 风险：`关闭一个窗口不是全 App 退出；当前 TerminalManager.saveBeforeTermination 只处理终止进程，单窗关闭时未保存内容或写入失败可能丢失，docs/EDITOR.md 已承认缺口`
- 预期修复：`后续单独设计窗口关闭前的异步保存及失败阻止关闭，复用既有 saveBeforeTermination/ProjectCloseConfirmation 合理职责，避免增加第二套窗口 owner`
- 验证：`新增针对两窗口、未保存文件、保存失败、取消、窗口保持可见与 SSH 断开的真实 UI/进程验收；现有 89 XCTest 不含该完整路径`
- 解决证据：`085849b: 原生 NSWindow+ContentView 的失败保存测试修复前红：保存拒绝仍关闭窗口；修复后等待同一窗口所有脏文件真实 save，失败不关闭，二次关闭+保存成功后才退出；覆盖重复关闭只发起一次写入、SwiftUI 宿主重挂载和原 windowWillClose delegate 链，独立 1/1、全量 94/94，Debug/Release 构建并严格验签。后续再测最终 95/95。`


## 发现 F-01

- 任务：`P5-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/UI/WorkspaceDockView.swift:497`
- 摘要：`共享 Dock 标签位置切换 Files A-B-A 时复用旧文件的 STTextView`
- 风险：`显示 A 文本却标记 B 文件，后续编辑存在写入错误文件的风险`
- 预期修复：`在所有 PaneTab 共用挂载入口按稳定 tab.id 指定视图身份，保留标签持有的原生编辑器`
- 验证：`make test ONLY_TESTING=KeroTests/FileTabTests/testFilesPanelABATabSwitchKeepsEachNativeEditorAndCorrectSaveTarget`
- 解决证据：`5edfccd：WorkspaceDockView 在共用 PaneTab 视图挂载处使用 .id(tab.id)；新增完整 ContentView 文件 A-B-A、分别编辑保存真实磁盘隔离检查；2026-10-14 全量 XCTest 84/84 与签名 Debug 构建通过。`


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


## 2026-10-14 独立重审：P5（不继承旧审计结论）

| todo 任务 | 原提交核对 | 当前执行路径／独立证据 | 判定 |
| --- | --- | --- | --- |
| P5-T1 | `ddc4333`，后审修复 `5edfccd` | `DockNode` 单树，`WorkspaceDockView` 内共享 PaneTab 挂载按稳定 ID 区分；Full ContentView Files A→B→A 复现红绿与真实磁盘内容验收（F-01）。 | 原提交遗漏关键交互身份约束，已修复 |
| P5-T2 | `134ac76` | Project/PaneTab `@Observable`，原 `projectObservations` 已消失；关闭 Sheet 由 WorkspaceNativeDialogs/ProjectCloseConfirmation 驱动；PaneRetentionTests 核查原生按钮行为。 | 当前使用；旧观察中继已删除 |
| P5-T3 | `3918150`，单窗关闭后审修复 `085849b` | `TerminalManager` 持有每窗口状态，WindowRoot `@State`；项目/原生选择器实际接入。后审以真实 NSWindow 实证关闭保存失败会丢窗口，现已通过共用窗口保存方法和原生 windowShouldClose 拦截，失败保留缓冲、成功再关闭。 | F-02 已解决；唯一 owner，未新增平行 WindowManager |
| P5-T4 | 与 P5-T3 同提交 `3918150`，无第二份独立实现提交 | `WindowRootView.focusedSceneValue(keroManager)` 与 `KeroCommands.@FocusedValue` 可达；新增独立双 `NSWindow+ContentView` 的 manager/编辑器与关闭快照隔离测试。 | 源码可达；真正菜单点击与多窗口焦点自动化未覆盖 |
| P5-T5 | `998b249` | `TabSwitcherController` 和 FPSCounter Observation 由 ContentView/WorkspaceChrome 消费；现有 PaneRetentionTests 覆盖切换器关键状态。 | 仍可达，未保留旧 ObservableObject |
| P5-T6 | `6b3081b`，`3d72aff` | 删除 Pierre 源码、包依赖、WebKit Diff，使用当前 STTextView/原生 Diff，DiffTabTests 覆盖渲染/分栏/撤销/保存；后续 `9202ffa` 补水平同步。 | 新路径确实在用，旧渲染退出 |

**阶段门槛**：视图身份 A→B→A 和单独窗口原生关闭失败保护均已修复，后者测试修复前红、修复后绿且经完整工作区验证；`make test` 95/95。批量关闭中途取消无法回滚已关闭标签的旧产品行为仍存在，完整原生菜单／真正 E2E 仍未验收。
