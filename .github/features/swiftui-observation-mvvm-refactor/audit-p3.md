# Audit P3 - swiftui-observation-mvvm-refactor

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/swiftui-observation-mvvm-refactor/`
- 粒度：`phase`

## 任务看板

- [x] P3-T1 文件树状态转 Observation，文件操作归入 ViewModel／Backend
- [x] P3-T2 Git 状态／读取刷新统一成可观察 ViewModel
- [x] P3-T3 把 GitPanel 的丢弃预检移出 View 并保留交互确认

## 任务到文件的映射

- P3-T1：`kero/Files/FileTreeModel.swift`、`kero/Files/FileTreePanel.swift`、`kero/UI/ContentView.swift`、`kero/Workspace/TerminalManager.swift`、`KeroTests/FileTreeTests.swift`（`f92ab70`）；本次审计修复涉及 `KeroTests/SessionStoreTests.swift`
- P3-T2：`kero/Git/GitStatusModel.swift`、`kero/Git/GitPanel.swift`、`kero/Files/FileTreePanel.swift`、`kero/UI/ContentView.swift`、`kero/UI/WorkspaceDockView.swift`、`kero/UI/Panels/ToolPanelView.swift`、`kero/UI/Components/BottomToolbarView.swift`、`KeroTests/GitStatusModelTests.swift`（`d78bd85`）
- P3-T3：`kero/Git/GitStatusModel.swift`、`kero/Git/GitPanel.swift`、`KeroTests/GitStatusModelTests.swift`、`docs/GIT.md`（`ffa054c`）

## 发现项

## 发现 F-01

- 任务：`P3-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/UI/ContentView.swift:109`
- 摘要：`异步文件操作错误回调可将已经关闭的旧窗口重新打开`
- 风险：`当窗口关闭后，来自 TerminalManager.newItem 或 FileTreePanel 的未完成异步操作仍持有旧 manager/project，presentError 经 onError 获取残留 weak NSWindow 并执行 makeKeyAndOrderFront，会重新激活本应关闭的窗口；错误不应在非活动窗口中重新路由。`
- 预期修复：`在 TerminalManager.windowClosed 当场清除 attachedWindow 引用，窗口 UI 异步错误回调只在原窗口仍可见时显示；不新增弹框管理器或切换成另一套 UIAlert。`
- 验证：`make test ONLY_TESTING=KeroTests/SessionStoreTests; make test; make build; codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app`
- 解决证据：`d492475：windowClosed 立即清空 AppKit 窗口引用，onError 仅在原窗口可见时显示；SessionStoreTests 5/5 PASS (/tmp/kero-observation-p3-audit-f01-session-retest.log)，全量 XCTest 42/42 PASS (/tmp/kero-observation-p3-audit-f01-full-test.log)，make build 与 codesign 严格验签 PASS (/tmp/kero-observation-p3-audit-f01-build.log)。测试窗口使用 isReleasedWhenClosed=false，避免 XCTest autorelease 崩溃。`


本阶段仅发现并修复以上一处真实窗口生命周期问题，未添加无证据的防护。

## 修复日志

- `f92ab70`：Files 通过 Observation 驱动；隔离原生新建、改名、取消、非法名称警告已验收（`evidence/p3-t1/`）。
- `d78bd85`：Git 的 Observation 与 Files 颜色、Git 工具栏同步；临时 Git 仓库和原生 UI 已验收（`evidence/p3-t2/`）。
- `ffa054c`：丢弃预检归 GitStatusModel；远端断线/内容变化/切机器均不执行删除，原生确认框只点 Cancel（`evidence/p3-t3/`）。
- `d492475`：修复审计 F-01 的窗口关闭后弹错问题，补齐 AppKit 生命周期回归测试。

## 验证日志

- `make test ONLY_TESTING=KeroTests/SessionStoreTests` → **PASS 5/5**；`/tmp/kero-observation-p3-audit-f01-session-retest.log`
- `make test` → **PASS 42/42**；`/tmp/kero-observation-p3-audit-f01-full-test.log`
- `make build` 和严格 codesign 验签 → **PASS**；`/tmp/kero-observation-p3-audit-f01-build.log`
- 隔离原生 Files、Git、丢弃确认框 → **PASS**；真正的 Peekaboo 截图，正式 Kero 未操作
- `git diff --check`、`todo validate`、`phase-complete --phase p3` → **PASS**

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：三个已提交任务均完成正常和错误/取消行为验收；唯一审计 finding F-01 已修复并验证，没有仍阻塞 P4 的 P3 缺口。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：原生验收采用隔离本机临时仓库，未执行真实 SSH 远端删除（避免触及用户数据）；SSH 状态链与原生终端留在 P4 验收。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

