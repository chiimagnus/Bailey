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
