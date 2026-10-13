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

## 发现 F-03

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1490`
- 摘要：`Git status 成功但 Git log 单独失败会发布空历史并抹掉 Git Graph`
- 风险：`SSH 批处理局部失败时解析结果仍被当作仓库成功快照，提交图谱和历史列表丢失且没有警告`
- 预期修复：`有 HEAD 时 Git log 失败应当作为整个刷新失败，保留上次成功的仓库快照；初始无 HEAD 则仍允许空历史`
- 验证：`make test ONLY_TESTING=KeroTests/GitStatusModelTests/testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers; make test`
- 解决证据：`2af09b2：有 HEAD 的 Git log 局部失败不能当作成功空历史；受控 batch 单子命令失败红绿对照通过；全套 XCTest 89/89。`


## 发现 F-02

- 任务：`P3-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1261`
- 摘要：`一次 Git/SSH 状态刷新失败会清空同一仓库已成功读取的提交与文件变化`
- 风险：`一时超时导致 Git Graph、文件装饰和工具栏消失，已加载的历史被误认作仓库丢失；之前的 SSH Git Unavailable 与此一致`
- 预期修复：`仅在确定切换仓库或确认不是 Git 仓库时清空快照；暂时失败保留上次成功的数据并展示可重试的错误，不新增第二份缓存`
- 验证：`make test ONLY_TESTING=KeroTests/GitStatusModelTests/testTransientGitFailurePreservesLastRepositorySnapshotAndRecovers; make test`
- 解决证据：`0e46a97：SSH Git 超时后保留已加载快照并在 GitPanel 展示可重试错误；红绿对照，新版 GitStatusModelTests 6/6；全套 XCTest 89/89。`


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


## 2026-10-14 独立重审：P3（不继承旧审计结论）

| todo 任务 | 原提交核对 | 当前执行路径／独立证据 | 判定 |
| --- | --- | --- | --- |
| P3-T1 | `f92ab70` | `FileTreeModel` 与原生 `ContentView` 的错误呈现仍为 FileTreePanel 的实际路径；FileTreeTests 真实创建、删除、重命名受控文件。 | 现行路径存在、被测试覆盖 |
| P3-T2 | `d78bd85` | `GitStatusModel→ContentView.@State→ToolPanelView/GitPanel/RecentCommits` 真实消费；刷新失败清空历史由 `0e46a97` 修复，`git log` 单点失败伪装空历史由 `2af09b2` 修复。原生 Git/SSH 使用独立回归验证。 | **原提交有真实缺陷，后审已定位并修复**（F-02、F-03） |
| P3-T3 | `ffa054c`，相关窗口回调后续 `d492475` | `GitPanel` 丢弃确认只负责 UI，`GitStatusModel` 执行路径与目标/内容复验；GitStatusModelTests 真实 Git/index/受控 SSH 错误有覆盖。 | 真实功能使用，未发现可删除的旧并行丢弃服务 |

**阶段门槛**：针对性 XCTest、Debug 验签已通过；真实 SSH 长时间断连／Git UI 原生重试路径待额外手工验收。错误必须显示但不抹去可靠的上次快照。
