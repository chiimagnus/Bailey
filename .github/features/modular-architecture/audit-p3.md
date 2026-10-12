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

## 发现 F-101

- 任务：`P3-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/SSHWorkspaceBackend.swift:279`
- 摘要：`独立复审：固定SSH后端的进程helper在client退出后无限等待master持有的输出管道`
- 风险：`watchdog在client退出时取消，而group.wait仍可能等待存活的mux master；网络失联时固定SSH项目的文件/Git请求不受原25秒期限约束`
- 预期修复：`现有静态SSH进程helper承接RemoteConnection已有的有界poll执行，实现一份共同进程/管道deadline；删除重复reader/watchdog/lock状态，保留两类连接与错误映射`
- 验证：`现有sshPath参数的真实子进程检查：client退出而子进程持管道应按期限抛timedOut；正常双流/错误/输入及真实mux与连接寿命通过`
- 解决证据：`本轮SSH统一修复提交见HEAD。/tmp/kero-independent-ssh-helper-before.log证明client退出后取消pipe deadline；after日志独立输入/双流/status/按时超时及真实mux并发检查PASS。实际App SSHHostCommandRunner与RemoteConnection在专用Windows master的File/Diff/Git和重连保存均PASS，日志/tmp/kero-independent-real-ssh.log；签名Debug及12项重新编译回归通过。`


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

## 2026-10-12 执行完成后的独立复审

以当前 plan/todo、各 commit diff 和重新编译的实际模块检查独立判断，不使用旧 audit 结论。

- P3-T1 / `6bacc62`：唯一 TerminalManager.makeProject 向 Project 传值，Project 不读 AppSettings；真实配置 URL 的默认/自定义/手工 workspace 保留与失败写入检查 PASS，旧字体键和 legacyDefaults 删除，现用语言/Diff 偏好仍保留。
- P3-T2 / `e9a9767`：删除 ColumnSnapshot、weight、三路 decoder 和单窗口 fallback；保存/加载仍为当前 windows/两层布局，可选字段业务含义保留。重编译往返/损坏必需字段拒绝/旧格式拒绝/无效 Dock 引用检查 PASS；实际 restore 源码的焦点、上下文、选中索引保护仍存在。
- P3-T3 / `527b61f`：Pane 模型迁移只有注释变化，外层 Dock 与内层 Pane 仍是两个原有布局；Diff 不允许内层分屏，与 Dock 直接挂载一致。
- P3-T4 / `295df31`：窗口协调者迁移保留唯一 registry、makeProject/saveAll/restore、App 菜单和 SSH 通知消费者；删除无人调用的外观/argv 查询及旧 Diff 挂载 UUID 表。当前 Shell 状态仍属于 TerminalSession，不另建 owner。
- P3-T5 / `1e8f9c6`：接口/本地实现分离，身份扩展回定义类型；File/Diff 全部生产构造者显式传 backend 和可选身份，nil 本机不回退为 session 的 SSH 身份。静态进程 helper 仍被 SSHHostCommandRunner 消费，删除仅无人实例化的协议 conformance 和便利重载。`4eb0043` 明确真实 App 的默认 actor 隔离，磁盘/进程解析 @concurrent 方法仍为生产入口；没有新增协议。实际模块身份与失败保存回归 PASS，不能以独立源码编译替代这一证据。
- P3-T6 / `9d54a42`：BottomToolbarView 的生产消费者为 Dock/Projects，迁移 helper 与 AppKit popover，删除不可达 emptyState 分支及独占的两条文案；保留真正空项目入口。
- P3-T7 / `7e6fe8a`：标签/chrome 在 Components 中唯一，Dock/Projects 继续消费；仅移除临时滚动日志，实际几何重算和 EditorState 恢复逻辑保留。
- `a0c1de8` 删除无人消费的旧 diffPlacements；`191cdd9` 的两份脚本实际链接 App dylib，不产生生产替身。重跑实际 Pane/Dock dirty File 与 Browser 身份、原生 SwiftUI Browser 页面/表单/非零滚动/历史重挂载检查 PASS。
- 本轮 4 项检查日志 `/tmp/kero-independent-p3.log`，签名 Debug 构建/严格校验 PASS。本轮 Gate：Go，无新 finding；焦点/光标逐项前台视觉与远端 UI 不用模型检查冒充。

### 最终消费者交叉核对后的补验

- 顺着 P3-T5 的 `SSHHostCommandRunner → ProcessRemoteCommandRunner.launch` 继续追到进程与管道，发现 F-101：客户端提前退出取消 watchdog，但 mux master 仍可持有输出 FD，group.wait 无期限等待。真实本机子进程反例修复前失败，日志 `/tmp/kero-independent-ssh-helper-before.log`。
- `ae80653` 把 RemoteConnection 已有的有界 poll 收敛到现有静态 helper，两种 SSH 调用共享它；固定 SSH 后端仍映射 timedOut/启动错误，交互连接保留状态码和部分输出。不改变独立主机连接与交互连接的认证/所有权差异。
- 删除旧重复读取线程、watchdog、Collected 和 Flag 两套锁状态；没有新增接口、状态机、重试或监控器。原 sshPath 参数保留，只在轻量检查中用于真实本机子进程，未为测试新加生产注入接口。
- 正常 stdin/双流/非零状态、client 退出但输出持有时按期超时，以及真实 OpenSSH mux/连接释放/并发转发检查 PASS。签名 Debug、全部 10 项独立检查与 2 项实际 App 检查重新编译通过。
- 专用 Windows master 上实际 App 的 SSHHostCommandRunner 和 RemoteConnection 均通过；File/Diff/Git 批次及替换连接保存检查最终远端字节、本机哨兵未改，测试目录与 master 已清理，日志 `/tmp/kero-independent-real-ssh.log`。
- 更新本轮 Gate：Go，F-101 已解决；这是返回责任 Task 的补验，不以 P5 添加新围栏掩盖根因。

