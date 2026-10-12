# Audit P3 - modular-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p3.md`
- feature 目录：`.github/features/modular-architecture/`
- 粒度：`phase`

## 任务看板

- [x] P3-T1 项目显式接收布局初始值，同步清理设置旧格式
- [x] P3-T2 删除已淘汰的快照解码分支，只保留当前格式
- [x] P3-T3 内层 Pane 数据模型与渲染分离
- [x] P3-T4 窗口协调者归入 Workspace，不拆现用 owner
- [x] P3-T5 收敛 WorkspaceBackend 接口与具体实现的源码边界
- [x] P3-T6 把被 Dock 使用的底部工具栏抽成独立组件
- [x] P3-T7 把标签胶囊、重命名和内容标签统一归入 Components

## 任务到文件的映射

- P3-T1
  - `kero/App/AppSettings.swift`、`kero/Workspace/Project.swift`、`kero/Workspace/TerminalManager.swift`、`scripts/check-settings.swift`
- P3-T2
  - `kero/Workspace/SessionStore.swift`、`kero/Workspace/TerminalManager.swift`、`scripts/check-session-snapshot.swift`
- P3-T3
  - `kero/Workspace/Panes.swift`、`kero/UI/Panes/PaneLayoutView.swift`、`scripts/check-pane-retention.swift`
- P3-T4
  - `kero/Workspace/TerminalManager.swift`、`kero/Workspace/Project.swift`、`kero/Terminal/ProcessWorkingDirectory.swift`、App/SSH 通知调用方
- P3-T5
  - `kero/Workspace/WorkspaceBackend.swift`、`kero/Workspace/LocalWorkspaceBackend.swift`、`kero/Workspace/Project.swift`、`kero/Remote/RemoteConnection.swift`、`kero/Terminal/TerminalSession.swift`、`kero/Editor/FileViewerView.swift`、`kero/Git/DiffViewerView.swift`、`scripts/check-workspace-identity.swift`
- P3-T6
  - `kero/UI/Components/BottomToolbarView.swift`、`kero/UI/ContentView.swift`、`kero/Resources/Interface.xcstrings`
- P3-T7
  - `kero/UI/Components/WorkspaceChrome.swift`、`kero/UI/ContentView.swift`、`kero/UI/Panels/ProjectsPanelView.swift`、`kero/Editor/SourceTextEditor.swift`、`kero/Terminal/FPSCounter.swift`

## 发现项

## 发现 F-03

- 任务：`P3-T4`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Workspace/Project.swift:144`
- 摘要：`旧Diff stack的diffPlacements已无消费者`
- 风险：`迁移后仍遗留旧挂载枚举入口，违反同步清理要求`
- 预期修复：`删除已无调用的属性及旧挂载注释`
- 验证：`全仓调用检查、实际App身份回归、Debug build`
- 解决证据：`a0c1de8；无消费者的diffPlacements已删除，Debug/严格签名/App身份检查PASS。`


## 发现 F-02

- 任务：`P3-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Workspace/WorkspaceBackend.swift:76`
- 摘要：`App默认MainActor隔离泄漏到WorkspaceBackend与本地异步I/O`
- 风险：`真实App契约与独立编译不同，文件读取/列目录可在主actor阻塞UI；actor测试后端无法符合实际App协议`
- 预期修复：`在真实后台I/O边界明确nonisolated协议及本地实现，保持UI模型的MainActor归属`
- 验证：`真实App模块actor后端编译、身份回归、独立导航/异步检查及签名Debug构建`
- 解决证据：`4eb0043；签名Debug、九项独立回归、真实App身份回归PASS；专用Windows SSH master真实File/Diff读取、断线拒写、替换连接写回、远端字节及本机sentinel核对PASS，远端fixture删除。`


## 发现 F-01

- 任务：`P3-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Workspace/Project.swift:314`
- 摘要：`本机+SSH标签身份已实测，远端同路径与断线重连尚缺可重复回归`
- 风险：`身份边界验收不完整，不能据本机保存推断远端无误写`
- 预期修复：`补充真实App类型的身份/断线回归与实际受控远端写回证据，不新增生产注入或框架`
- 验证：`真实App类型回归、现行签名Test与独立远端fixture`
- 解决证据：`4eb0043；签名Debug、九项独立回归、真实App身份回归PASS；专用Windows SSH master真实File/Diff读取、断线拒写、替换连接写回、远端字节及本机sentinel核对PASS，远端fixture删除。`



## 修复日志

- `4eb0043` 修复实际 App 默认 actor 泄漏并补齐身份回归；`a0c1de8` 删除 Diff stack 遗留入口；`191cdd9` 补充实际 App Pane/Dock 与原生浏览器重挂载回归。
- 异步边界依据 [Swift 官方契约](https://docs.swift.org/latest/documentation/diagnostics/nonisolated-nonsending-by-default/)：Approachable Concurrency 下 nonisolated 本身不保证离开调用者 actor，本地磁盘方法使用 @concurrent。

## 验证日志

- CONTRIBUTING 的九项独立 swiftc 检查全部重新编译运行 -> PASS；树含 10k 文件，Git 含真实 stage/unstage/discard/commit，面板含延迟目标与同 PID 旧菜单。
- 签名 Debug xcodebuild、严格签名、git diff --check -> PASS；日志 `/tmp/kero-p3-audit-final-build.log`。
- `bash scripts/check-workspace-identity.sh` -> PASS；实际 App 类型检查本机固定目录+SSH、同路径不同机器/端口、断线拒绝与保存失败保持编辑。
- 专用 Windows master 的真实 SSH File/Diff 读取、受控断线、替换连接后写回并核对远端字节与本机 sentinel -> PASS；自建远端目录已删除。
- `bash scripts/check-pane-retention.sh` -> PASS；实际 SwiftUI representable 重挂载后页面、表单、非零滚动与前进后退历史保留；Dock/Pane 与 dirty File 身份不变。
- Kero Test：四向嵌套五窗格跨组移动 Shell PID 不变，两窗口恢复，快照越界修正后重存，dirty File 跨组/窄组/重命名/保存，分支搜索和外部点击关闭，查找替换实际保存、Ctrl-Tab/Escape -> PASS。正式实例未操作。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：职责与机器身份边界落实，发现项均修复；状态和视图保持有源码、针对性测试及实机证据。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 补充实机证据：后续签名 Kero Test 新鲜窗口坐标截图确认标签 hover 显示 x；点击 x 后 Local-check 标签实际消失，磁盘保存内容仍在。悬停关闭验收已完成。
- 剩余风险：未改共享 toolbar 配置；Windows 缺少 Linux Info 工具，远端 Info 行不冒称通过。中文输入法组合文本需提交，不能把 AX 字段已变而筛选未刷新误判为产品失败。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

