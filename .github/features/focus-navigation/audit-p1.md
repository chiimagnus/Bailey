# Audit P1 - focus-navigation

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/focus-navigation/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 Dock 活动组与选中标签分离
- [x] P1-T2 原生内容与工具面板焦点联动

## 任务到文件的映射

- P1-T1
  - `Bailey/Workspace/{DockWorkspaceModel,Project,TerminalManager}.swift`；`DockWorkspaceTests`、`SessionStoreTests`、`WorkspaceWindowIsolationTests`；`docs/features/{dock,editor,session-restore}.md`。
- P1-T2
  - `WorkspaceDockView`、`PanelContentView`、`SourceTextEditor`、`TerminalHostView`、`BrowserView`、`DiffNativeSurface` / `DiffTextView`、`BaileyCommands`；原生保留/工作区/共享树测试；`docs/features/{dock,browser,files}.md`。

## 发现项

## 发现 F-93

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/TerminalManager.swift:669`
- 摘要：`标签关闭流程仍进行时，项目关闭仅检查脏内容导致已变干净的在途标签被提前销毁`
- 风险：`已写入但未结束原生关闭生命周期的标签、窗口状态或其内容可提前退役，打断后续关闭和保存确认`
- 预期修复：`项目关闭必须针对所有关闭中内容判定，而不只是当前仍为 dirty 的内容；批量重复关闭也不得先删干净的标签`
- 验证：`WorkspaceWindowCloseTests 的 testProjectCloseCannotBypassAnActiveTabClose 与 testRepeatedCloseAllKeepsCleanTabsUntilDirtyConfirmationResolves，20261021 EXTRA_RED 2tests/4failures；修复后重测，核对取消和最终资源保留`
- 解决证据：`/tmp/bailey-focus-p1-extra-red.log: 清洁但关闭中的文件被 TerminalManager.close 销毁（XCTAssertTrue failed）；修复 guard 检查全部正在关闭的内容；/tmp/bailey-focus-p1-extra-green.log: 2 tests/0 failures；/tmp/bailey-focus-p1-window-final.log: 6 tests/0 failures。`


## 发现 F-92

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:701`
- 摘要：`重复触发脏标签关闭可并发启动多个保存/确认流程`
- 风险：`快捷键与标签按钮连续触发时，关闭自动保存悬挂与确认对话框可重复排队，用户只取消一个请求仍有后续关闭请求在执行`
- 预期修复：`以单一关闭流程的真实生命周期为所有者，重复请求不得再次开始同内容的保存和确认，不增加永不清理的缓存`
- 验证：`受控写入挂起并重复触发关闭，检查只有一个写入/确认；失败取消后再关闭允许正常重试且内容不丢失`
- 解决证据：`/tmp/bailey-focus-p1-extra-red.log: 2 tests/4 assertions failed, 第二次 Close All 越过第一轮确认删除 clean tab；/tmp/bailey-focus-p1-extra-green.log: 2 tests/0 failures；/tmp/bailey-focus-p1-window-final.log 6/0; 单标签重复关闭 1 写入、Cancel 后重试 2 写入、批量取消保留草稿、成功重试核对最终字节。`


## 发现 F-91

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:714`
- 摘要：`关闭后台窗口的脏文件时使用全局 keyWindow 而非文件所属窗口`
- 风险：`另一窗口或设置页占据键盘焦点时，保存失败确认 Sheet 会出现在错误窗口，造成跨窗口误确认或无提示等待，破坏 P1 菜单/焦点目标隔离`
- 预期修复：`沿 Project 所属 TerminalManager 的 attachedWindow 取得窗口，关闭单标签和批量关闭共用所属窗口，不再依赖全局 keyWindow`
- 验证：`双真实 NSWindow + 两独立项目，第二窗口为 key，第一窗口脏文件写入失败触发关闭；原实现 Red 为 Sheet 在 B，修复后 Green 为 Sheet 仅在 A，Cancel 保留原始内容`
- 解决证据：`Project.closeSheetWindow 绑定真实 TerminalManager.attachedWindow；/tmp/bailey-focus-p1-window-final.log: WorkspaceWindowCloseTests 6 tests/0 failures, 双真实 NSWindow、失败 Sheet 仅在文件所属窗口、Cancel 不改原字节、允许 Unicode 重试成功。原实现全局 NSApp.keyWindow 违反归属，独立前台 Red 无法在共用桌面稳定构造，不虚报为有效 Red。`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/Project.swift:958`
- 摘要：`关闭最近工作标签的记账赋值仍会激活无关组`
- 风险：`工具或另一个可见组活动时，关闭后台 MRU 会改变焦点、命令目标及其它组选择`
- 预期修复：`显式选择走 selectTab；selectedTabID 只记录 MRU，关闭记账不再隐式选组`
- 验证：`DockWorkspaceTests 的关闭后台标签回归与完整工作区测试`
- 解决证据：`3dd7dd2; Red 3 assertions -> 41 tests/0 failures, make test exit 0, rtk tee 1792515628_make_tes_128e0f.log`



## 修复日志

- F-01 已按脚本解决，提交 `3dd7dd2`。显式入口与关闭记账分开，旧隐式属性激活路径已删除，所有调用方已迁移。

## 验证日志

- 后续 P2 审计补强 P1 共享读点：`9c95cc2` 修复 SwiftUI 控件 visibleRect 超出 bounds 导致键盘归属错投，记录和有效 Red→Green 归 P2 F-01；不改写本审计当时证据。最终冻结版本的完整测试为 579 passed、0 failed、0 skipped（含授权 Windows SSH），真实窄 Find 关闭后 Shell marker 也已写出，见 `evidence.md`。

- `evidence.md` 记录 Red→Green、原始日志、全部条件维度与独立 App 的实际字节/工具关闭/Settings 关闭结果。101 项扩展原生回归及 `make build`/严格验签完整退出 0；审计修复后 41 项模型/快照/窗口/工作区回归完整退出 0。
- 逐块重查了菜单目标、项目上下文、保存队列、原生焦点请求、Diff 可见性、工具留白、重挂载及关闭记账；追到了磁盘正文、原生对象与真实前台键入。8 标签/6+ 嵌套、全部边缘、无效 ID、关闭工具与后台工作标签均有回归。
- 当前系统全部可运行的相关 XCTest 已执行；macOS 15.6 无设备，SDK 可用性检查替代但不冒充该系统实测；最低运行时与长时间真实 SSH GUI 补验仍需对应环境。其不阻止当前模型/原生实现的阶段推进，不代表跨系统/网络全验收。用户追加完整授权后，最终完整测试将启用文档中的独占 `windows` 测试 master 与临时仓库；不碰现有连接。
- 普通浏览器焦点请求许可由窗口所属组提供，组件测试的 AppKit 本地 first responder 不等于系统前台。独立 App 前台边界已补原始键入；命令面板取消/执行、停车终端恢复、活动边框仍按计划归 P2。
- 当前文档对应源码，无新增页面或失效导航；Files 当前文件高亮刻意保留最近工作标签，不混同工具活动状态。计划中曾误将最近工作标签记账视为焦点的实现锚点，以本审计及 `selectTab` 为准。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P1 的活动真源、原生输入衔接与审计发现均已验证；后续恢复与视觉问题保持在 P2 的原验收归属。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：仅上述明确环境缺口与尚未进入的 P2 验收，不冒称完整 Feature 完成。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-21 独立按提交复核（不采用上方历史 Gate 作依据）

| Task | 独立核对的提交 | 当前真实调用链与不变量 |
| --- | --- | --- |
| P1-T1 | `1594966`、`3dd7dd2` | `DockWorkspaceModel.activeGroupID` 单独持有当前组，`root.group.selected` 只决定该组显示标签，`Project.selectedTabID` 仍保存最近工作内容；`Project.focusedContent` 和 `TerminalManager` 菜单目标从当前活动组求值。工具关闭与后台标签关闭不写错组。 |
| P1-T2 | `737871b` | `WorkspaceDockView/PanelContentView` 向 TextKit、Ghostty、WebKit 与 Diff 下发焦点许可；原生 `NSWindow.firstResponder` 变化反向通知 Dock 活动组；原生内容本体由各 Pane 持有，未因本次 UI 切换重新创建。 |

本轮重新读了两个任务所改生产源码及 `DockWorkspaceTests`、`WorkspaceWindowIsolationTests`、`WorkspaceContentIdentityTests` 的实际消费测试。后续发现 F-91/F-92/F-93 并完成源码修复和回归，实际结论以本节末尾的复核记录为准；不使用上方历史 Go 代替本轮判断。

### 本轮修复与结果

- `59182ed`：P1-T1 关闭链路从 `NSApp.keyWindow/mainWindow` 改为实际拥有项目的窗口；`PaneContent.isClosing` 直接复用既有关闭期自动保存挂起标记；单个标签、批量标签与整个项目的关闭入口均不得绕过未完成的保存确认，不新增焦点协调器、超时重试器或持久状态。
- `F-91`（High）：两个真实 `NSWindow` 分别绑定独立 `TerminalManager`，失败的文件写入仅在原窗口显示 Sheet；取消后磁盘保持原字节，之后再次关闭仍可重试。测试未强行夺取系统 key window，因此不是后台前台切换的完整 GUI E2E。
- `F-92`（Medium）：先证实重复「关闭全部」会把干净的浏览器标签提前删除：`/tmp/bailey-focus-p1-repeat-batch-red.log` 2 断言失败。修复后同根因的单标签连击、同组多脏文件、批量重入、项目关闭与取消重试均通过；两条新增的独立竞争回归已通过 `44848f8` 单独提交。
- `F-93`（High）：即使先前的待关闭文件已经变干净，也不能在其关闭流程结束前由项目关闭将其销毁。另两项测试的原始 Red (`/tmp/bailey-focus-p1-extra-red.log`: 2 项、4 次断言失败) 和 Green (`/tmp/bailey-focus-p1-extra-green.log`: 2 项、0 失败) 已直接检查；最终 6 项原生关闭测试全部通过。保护作用于所有 `isClosing` 内容，不只当前脏内容。

### 验证边界（2026-10-21，macOS 27.2 / Xcode 27.2，arm64）

| 范围 | 执行事实与最终副作用 |
| --- | --- |
| Dock / MRU / 快照 | `DockWorkspaceTests` 16 项、`SessionStoreTests` 8 项通过；瞬时活动组不写快照，组移动、空组、删除回退、后台标签关闭均核对实际状态。 |
| 保存和关闭 | `WorkspaceWindowCloseTests` 6 项通过；失败、取消、重试、双窗口 Sheet 归属、重复关闭、原生窗口拒绝关闭及写入后关闭均核对。 |
| 原生输入及内容生命期 | `PaneRetentionTests` 21、`FileTabTests` 49、`DiffTabTests` 35、`TreeRowHitTestingTests` 7、`WorkspaceContentIdentityTests` 3、`WorkspaceWindowIsolationTests` 38 项全部所在测试组通过；核对文件字节、编辑器对象/Undo/输入、工具活动时的路由与多窗口内容隔离。 |
| 此前定向回归 | `make test ONLY_TESTING=...` 覆盖上述 9 个测试类：183 项、0 失败、5 项未获前台而跳过；完整命令退出 0，日志 `/tmp/bailey-focus-p1-postcommit-selected.log`。前台五项已另行全部核销，见下节。 |
| 构建验签 | 最终 Debug `make build` 与 Release `make build:release` 均完整退出 0，随后各自的 `codesign --verify --deep --strict` 通过；隔离输出 `build/DerivedData-focus-p1-review`，最终日志 `/tmp/bailey-p1-final-debug-build.log`、`/tmp/bailey-p1-final-release-build.log`。部署目标 15.6 不等于 15.6 真机已测。 |
| 全量套件 | 最终 `make test DERIVED_DATA=build/DerivedData-focus-p1-review SOURCE_PACKAGES=build/SourcePackages-focus-p1-review` **618 项、0 失败、14 跳过、退出 0，TEST SUCCEEDED**；日志 `/tmp/bailey-p1-full-final-20261021.log`。之前两次中断日志另存，不替代本次完整结果。14 项中 8 项需专用 SSH 主机、5 项需独占前台（已另测全部通过）、1 项属 P2 前台覆盖（本次未核销）。 |

最初跳过的 5 项包括 Files/Git 树取消命令面板后恢复键盘导航、编辑器经命令面板切回 Files、重命名/草稿退出后的键盘恢复及命令面板覆盖时输入归属；现均在真实前台 XCTest 中执行通过，并验证第一响应者与实际方向键结果。独立 App 的菜单快捷键 `⌘W/S/F/K/L/R` 仍以已有历史证据为准，本轮未逐组合重做。未测环境：macOS 15.6 真机（无设备，目标 SDK 构建替代，运行时风险仍在）、获授权 Windows SSH 长时间 GUI（8 项全仓用例缺专用 host 参数，远端焦点/断线恢复不能称实测）；本轮也没有替代实体触控板/多显示器人工操作。它们不阻断**当前 macOS 27.2 上的 P1 代码和原生焦点阶段验收**，但阻断跨版本、跨设备和 SSH 的全环境完成声明。

清理结论：P1 已去除 `selectedTabID` 隐式激活及旧的最近标签即焦点路由；`DiffViewerView.isSelected` 仍服务可见性/内容刷新而非输入焦点，`DockSavedItem.info` 仍承担旧快照解码迁移（`SessionStoreTests` 有实际消费），没有依据将其当无用安全围栏删除。控制原生焦点的窗口/Sheet/输入框归属检查有实际防止错误写入目标或键盘抢占的作用，不能无证据删掉。

### 2026-10-21 前台补验

- `75b1c9f`：五个原生焦点用例只在确认真实 `NSApp.isActive` 和 `NSWindow.isKeyWindow` 后继续，并为 AppKit 的异步窗口激活保留最多约 2 秒等待；缺失前台时仍跳过，不绕过输入断言。没有新增生产焦点状态或重试框架。
- 精确 PID 前台激活的隔离 XCTest：`/tmp/bailey-p1-five-await-continuous.log`，五项在同一测试宿主中 **5 passed、0 failed、0 skipped**；核对 Files、Git Tree 的方向键、命令面板焦点、重命名/草稿退出及原生第一响应者。之前首次合并运行曾出现 Git 树挂载超时及焦点跳过（`/tmp/bailey-p1-all-five-foreground-verified.log`），在持续取得真实前台的条件下全部通过，原失败日志保留，不将它归因为已确认的生产缺陷。
- 单独复核 Files/Git 取消命令面板：`/tmp/bailey-p1-two-foreground-await-green.log`，2 项通过、0 跳过。所有 GUI 测试使用隔离 `--isolated-ui-test`，没有替换或重启正式 Bailey。

### 本轮 Gate

- **Go（P1 当前 macOS 可用环境）**：三个新发现 F-91/F-92/F-93 均已解决；前台五项真实原生焦点全部执行通过（0 跳过），全仓 XCTest 618 项完整完成、0 失败，Debug/Release 构建与严格验签通过。原先阻止 Gate 的两个条件已经核销；仅上述无法获得的旧版 macOS、远端 SSH 与物理设备组合仍为有边界的环境限制，不称跨环境全验收。
- P1 生产修复 `59182ed`、关闭竞态回归 `44848f8`、原生测试就绪 `75b1c9f` 已独立入库。用户已明确要求提交全部 P1 文档，本 `audit-p1.md` 随本次终审独立提交，不混入 P2～P4 的审计或源码；未为本次验收重启或替换正式 Bailey。

