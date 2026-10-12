# Audit P5 - modular-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/modular-architecture/`
- 粒度：`phase`

## 任务看板

- [x] P5-T1 全仓调用链、旧路径和文档交叉核销
- [x] P5-T2 安全替换签名 Debug 并验证核心工作流

## 任务到文件的映射

- P5-T1
  - `kero/App/`、`Workspace/`、`Terminal/`、`Files/`、`Git/`、`Info/`、`Remote/`、`Editor/`、`Browser/`、`UI/`、`Shared/Tree/`：状态所有者、实际消费者、旧路径与唯一组件核销。
  - `AGENTS.md`、`docs/CONTRIBUTING.md`、`docs/PERFORMANCE.md`：28042a1，更新已实现的配置输入、Diff 内容宿主与独立测试包规范。
- P5-T2
  - `kero/App/keroApp.swift`、Finder 服务与终端通知入口；`Workspace/TerminalManager.swift`、`Project.swift`、`SessionStore.swift`、`PaneModels.swift`、Dock 模型与 UI；`Files/`、`Git/`、`Info/`、`Remote/`、编辑器与浏览器的真实执行路径。
  - `kero/Remote/RemoteConnection.swift`、`scripts/check-remote-lifetime.swift`、`docs/CONTRIBUTING.md`：018d67a，最终发现的修复归属 P2-T4，不另建 P5 服务或兼容层。

## 发现项

## 发现 F-01

- 任务：`P5-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Remote/RemoteConnection.swift:309`
- 摘要：`检查master和打开子通道之间退出时仍允许OpenSSH回退到新连接`
- 风险：`违反只复用用户会话的传输/认证边界，断线时可能在后台使用密钥新建连接`
- 预期修复：`归属P2-T4：在共享controlArguments禁止新传输/master，不增加调用点守卫或新runner；补真实mux检查后socket消失的本地传输回归`
- 验证：`受控本地mux与TCP监听检查、真实既有master读写、签名Debug及受影响回归`
- 解决证据：`018d67a：共享controlArguments添加ControlMaster=no与ProxyCommand=/usr/bin/false。真实OpenSSH mux存活检查后删除socket：修复前新建TCP使断言失败，修复后无新传输PASS；10独立回归、2真实App模块检查、真实SSH File/Diff/Git与并发HTTP404转发PASS，签名Debug build/严格校验PASS；退出专用master后本机1177监听消失，远端测试目录删除。`


## 修复日志

- P1–P4 已各自完成实现、原子提交和阶段审计；P5 核对最终消费者，不重新制造并行布局、树、面板或 Git runner。
- F-01（同时回写 P2 F-03）：实际 OpenSSH 在 mux socket 不存在时会回退新传输，检查 master 存活不能消除检查与执行间隙。共享 `controlArguments` 禁止创建 master，并以失败的 ProxyCommand 禁止新传输；有效 mux 继续正常复用。未在 File/Git/转发调用方叠加守卫，未改变主机信任规则。契约对照：[OpenSSH ssh.c](https://raw.githubusercontent.com/openssh/openssh-portable/master/ssh.c)、[mux 协议](https://raw.githubusercontent.com/openssh/openssh-portable/master/PROTOCOL.mux)。
- 本机专用 mux 回归完成真实 HELLO/存活检查，在成功回复前删除 socket，用实际 OpenSSH 命令和回环监听检查最终传输。修复前 `/tmp/kero-mux-before.log` 断言失败并证明新 TCP；修复后 `/tmp/kero-mux-after.log` PASS。018d67a 保留这一最小回归。
- 只清理本轮自建资源：3 个自建隔离项目及对应历史、临时仓库、测试包、专用 master 和远端服务目录。没有清空用户快照、历史、设置或 build。原有 2 个隔离项目数据重启前后相同，解锁后实际 UI 均可见；配置原文不变，正式 Kero PID95629 保持运行。私有恢复备份保留在仓库外。

## 验证日志

- 全仓 CodeGraph 与实际源码调用交叉核对 -> PASS。旧模型/组件路径及淘汰的快照解码、legacy defaults、旧 Git runner 均无生产引用；共享树和面板标题只有唯一实现。`PBXFileSystemSynchronizedRootGroup` 自动接入最终源码，无需手写移动文件清单；未改 Vendor、依赖或 target。
- 文档本地链接 15 项、`git diff --check` -> PASS。架构与验证规则仍分别归属根 `AGENTS.md`、`docs/CONTRIBUTING.md`，未创建重复架构文档。
- `xcodebuild -project kero.xcodeproj -scheme kero -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData -clonedSourcePackagesDirPath build/SourcePackages -skipPackageUpdates build` -> PASS；最新原生日志见 `/tmp/kero-p5-ssh-build.log` 的 tee 路径。`codesign --verify --deep --strict build/DerivedData/Build/Products/Debug/Kero.app` -> PASS。
- 按 `docs/CONTRIBUTING.md` 重新编译运行 10 项独立检查 -> PASS，日志 `/tmp/kero-p5-regression.log`。涵盖 Dock、当前快照/拒绝旧格式、共享树（10k 文件约 0.107 秒）、真实配置原子保存、Git 字节/捕获上限/超时、真实 stage/unstage/discard/commit 与草稿、远端命令、连接寿命及新 mux 回归、延迟面板目标和同 PID 旧动作、两档字体原生树行命中。Git 忽略 TERM 的 helper 也在约 1.18 秒内退出并保留部分输出，不只证明计时器已触发。
- `bash scripts/check-workspace-identity.sh` -> PASS，编译链接实际 App 模块。真实本机 Git/Diff、未提交仓库、NUL/非法 UTF-8、恰好 5 MiB/超限、同路径不同机器/端口、断线拒写及失败保存保留 dirty 均有最终文件断言。加专用 SSH master 参数的实际远端回归 -> PASS，日志 `/tmp/kero-p5-real-ssh.log`：Git 批次/历史/未跟踪计数、File/Diff 读取及替换连接保存；远端字节正确、同名本机文件未改、测试目录已删除。
- `bash scripts/check-pane-retention.sh` -> PASS，日志 `/tmp/kero-p5-pane.log`。实际 Pane/Dock 移动保留 dirty File 和 Browser 身份，原生 SwiftUI 浏览器重挂载保留页面、表单、非零滚动与前进后退历史；这不是浏览器前台拖动验收。
- 最新专用真实 SSH master 的两次并发转发 -> PASS，复用本机 1177，HTTP404 证明远端临时服务实际可达，日志 `/tmp/kero-p5-real-forward.log`。标记断开只清记录；最后正常退出专用 master 后本机监听消失，远端测试目录成功删除。没有借用或终止用户 master。
- 签名 `Kero Test` 实机 -> PASS：四向嵌套 5 终端窗格、跨外层 Dock 移动后 Shell PID 不变；dirty 编辑器移动、窄组/窗口调整、重命名/保存实际字节；2 窗口聚合和恢复、空窗口关闭；当前快照越界 focus/context/selection/Dock 引用恢复修正；本机固定根与真实 SSH 终端上下文共存，文件保存不误写另一台机器。
- 签名 `Kero Test` 交互 -> PASS：Files 创建/打开/rename、Git 工作区/历史与实际 Diff 内容、草稿保持、本机 Info 端口复制 URL/终止临时服务、分支搜索与 Escape/外部关闭、Cmd-F 查找替换并保存实际字节、Ctrl-Tab、命令面板匹配并打开本机文件、悬停关闭按钮与实际标签关闭。悬停截图 `/tmp/kero-p4-final-hover.png`。中文输入法组合文本提交后再判断筛选；粘贴验收保存并恢复完整剪贴板，不修改输入设置。
- Finder 服务与 OS 通知 -> 仅源码核对：现有目录路由继续选择 key/main window 或新建窗口；通知按 sessionID 查找所属窗口/项目/标签/窗格。未冒称服务调用和系统通知点击已实机通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P1–P5 的实现、旧路径删除和阶段审计已完成，最后的确定性 SSH 缺陷已根因修复；最终签名构建、12 项回归及可安全执行的真实工作流通过，未实测条件按计划如实记录。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余验证边界：Finder 服务调用/OS 通知点击、编辑器光标和滚动位置的逐项视觉恢复、浏览器前台 Dock 拖动未完整实机验证；可访问的 Windows/MSYS 远端缺少现行 Info 所需 Linux 工具，远端 Info 行/复制 URL/移组后记录可见性未端到端验证。暂时网络失联后的会话转发恢复未实测，不能用 master 退出后监听消失替代。
- 已知限制：SSH 仍先捕获完整输出再应用内容上限，不宣称流式内存上限；原有 TerminalHistory、Dock 默认参数 actor 与 SwiftPM identity 构建 warning 未在本次扩大修复，当前 Swift 5 构建与回归通过。
- 所有已记录 finding 均已解决。不能据此证明不存在任何潜在 bug；上述实测、回归和源码核对是本次结论的证据边界。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-12 执行完成后的独立逐提交复审

本轮不读取已有 audit 的发现、验证记录或 Gate；以当前需求、idea/plan/todo、各产品提交 diff、生产调用链和本轮重新执行结果独立判断。旧 audit 保留，不覆盖历史证据。

### 27 个提交逐项核对

| 提交 | 任务/性质 | 本轮核对结果 |
| --- | --- | --- |
| bfe8602 | P1-T1 / 计划 | 无产品变更；基线所有者由源码重新确认 |
| 26a3f4e | P1-T2 | 共享树两文件 100% rename，真实消费者与旧路径删除确认 |
| 53d747c | 计划校正 | 仅计划说明，不算功能实现 |
| 01c3c1c | P1-T3 | FileTreeModel 100% rename，Project 仍唯一持有者 |
| 72ee408 | 计划状态 | 无产品变更，不采用旧审计结论 |
| 18e3fb2 | P2-T1 | Files/共享标题归位并在 ToolPanelView 挂载，旧定义删除 |
| e327401 | P2-T1 | 仅删 EOF 空行，无行为改动 |
| 9e3b94d | 计划说明 | 无产品变更，不算实现 |
| c110092 | P2-T2 | GitPanel 挂载与窗口级按机器/仓库草稿，真实 Git 操作回归通过 |
| 97fd6eb | P2-T3 | Info 原模型归位，backend/PID 操作实际接入 |
| 34dc7b4 | P2-T4 | 连接/controller/backend 所有权接入；本轮发现并修复并发等待旁路 |
| 2e06a23 | P2-T5 | PanelContext 被三类真实入口消费，延迟目标回归通过 |
| 3799427 | P2-T5 | Files 旧菜单/异步副作用边界复用目标检查，未另建管理层 |
| 6bacc62 | P3-T1 | 布局值经唯一工厂传入，旧设置迁移删除，真实配置回归通过 |
| e9a9767 | P3-T2 | 旧快照解码删除，当前格式与可选语义保留，往返/拒绝回归通过 |
| 527b61f | P3-T3 | 原 Pane 模型迁移，仅修正不实 Diff 注释 |
| 295df31 | P3-T4 | 原 window registry/快照/命令与通知路由保留，死入口删除 |
| 1e8f9c6 | P3-T5 | 后端与显式机器身份接入；继续追到实际 SSH helper 并修复其期限 |
| 9d54a42 | P3-T6 | Dock/Projects 消费唯一工具栏，旧定义与不可达分支删除 |
| 7e6fe8a | P3-T7 | 标签/chrome 实际被 Dock/Projects 消费，临时滚动日志删除 |
| 4eb0043 | P3-T5 | 明确 App actor 隔离契约，实际 App 而非桩的检查通过 |
| a0c1de8 | P3-T4 | 无消费者 diffPlacements 删除，Dock 当前直接挂载 Diff |
| 191cdd9 | P3-T3/T7 验证 | 真实 App Pane/Dock 与原生 Browser 重挂载，不进入生产替身路径 |
| 3e32370 | P4-T1 | 唯一 Git 字节执行器接入三类消费者；本轮补修正常退出后管道期限 |
| 28042a1 | P5-T1 | AGENTS/开发验收/性能说明与最终所有者一致，不增加重复架构文档 |
| 018d67a | P2-T4 / P5-T2 | 共同控制参数禁止新传输，实际 mux/TCP 反例再次通过 |
| 15ada6a | 计划完成状态 | 只含计划/审计状态，无产品变更，不采用其审计结论 |

每个产品提交的真实路径与针对性验证见本轮各 phase 的独立复审附录。5 个纯计划提交没有被算作已接入的功能。

### 新发现与根因修复

- P2 F-101 / `6cfaa9b`：合并转发的第二等待者绕过断线检查。删除直接返回旁路，所有等待者共用完成校验；按现有 Task 身份收尾，无新状态机。
- P4 F-101 / `4ccb18f`：Git 已正常退出但后台 helper 持有管道时，显式 timeout 不约束 readers.wait。进程和管道共用原始期限，复用原有所有者进程组收尾。
- P3 F-101 / `ae80653`：固定 SSH 项目的 helper 在 client 退出后取消 watchdog，仍无限等待 mux master 的输出。两类 SSH 请求共用已有有界 poll，删除重复管道/锁/watchdog 状态。
- 三项均有修复前失败与修复后通过的实际进程/协议回归，不是只因“可能发生”添加防御。发现先落盘、修复回责任任务、分别验证和原子提交。

### 本轮独立验证

- 重编译 10 项独立检查全部 PASS，日志 `/tmp/kero-independent-all.log`：Dock、现行快照、共享树（10k 约 0.110 秒）、真实设置、Git 执行、真实 Git 操作与草稿、远端命令、SSH 生命周期及新反例、延迟面板目标、原生行命中。
- 签名 Debug 构建与严格 codesign PASS，日志 `/tmp/kero-independent-ssh-build.log`。重新编译并链接当前 App dylib 的身份/Git/Diff检查和原生 Browser 重挂载检查 PASS，日志 `/tmp/kero-independent-ssh-identity.log`、`/tmp/kero-independent-ssh-retention.log`。
- 实际专用 Windows SSH master：生产 SSHHostCommandRunner 与 RemoteConnection、Git 批次/历史/未跟踪计数、File/Diff 读写/拒绝断线保存/替换连接保存 PASS，检查最终远端字节与同名本机哨兵不变。日志 `/tmp/kero-independent-real-ssh.log`；自建远端目录和 master 已清理。
- 文档 15 文件中的 107 个本地 Markdown 链接均存在；产品 `git diff --check` PASS。Xcode 同步根的唯一源码排除仍为 Info.plist，未改 target/Vendor/依赖。旧路径/旧 runner/旧快照/旧设置兼容均无生产残留；测试中拒绝旧格式的字符串不是兼容实现。
- Finder 服务和通知的注册、manager 窗口选择、sessionID 到所属项目/标签/窗格的最终路由由当前源码重新核对；不是仅看名字存在。没有新增面向未来的协议、缓存或管理者。

### 本轮 Gate 与边界

- Gate：Go；P1–P5 当前实现与真实消费者一致，本轮三个新 finding 已解决。
- 本轮未重新制造完整前台拖拽/焦点/光标/OS通知点击与 Finder 服务调用；Windows 远端 Info 的 Linux 工具条件及临时断网转发恢复未实测，不冒称这些端到端场景通过。
- 保留现用数据完整性、机器身份、确认后/执行前校验与并发结果代次。没有证据表明这些是多余围栏；删除的是已确认的死兼容/旁路/重复执行与监视状态，而非为了行数撤掉真实保护。
- 不能证明所有潜在 bug 均不存在；上述逐提交核对、实际副作用与反例回归定义本轮结论边界。

### 正式包收尾

- 原 PR #1 已补入 `6cfaa9b`、`4ccb18f`、`ae80653`，远端 head 与本地一致，共 30 个提交；本轮新增的本地计划/审计修改未混入产品提交。
- 按用户此前的正式更新授权正常退出（不强退）并安装最新签名 Debug，严格 codesign 与构建 dylib 字节比较通过。退出时最终快照包含 5 个项目，全部项目、标签内容、Dock 拓扑/比例/节点身份重启后保留，配置原文不变，原生 UI 新观察成功。
- 自动保存快照和退出快照之间出现新项目/标签；重启后的连续桌面观察中，标签和项目选中值也变化。没有独占桌面条件，不能把选择比较称为完全通过，也不能只据此推断产品焦点 bug 或给它加恢复补丁；选中/焦点需独占桌面时复验。只核对不受选择操作影响的完整结构与内容，不覆盖用户的当前选择。
- 只删除本轮能够确认归属的崩溃回归临时仓库、专用 master 和旧安装包备份；保留仓库外私有配置/快照恢复备份，没有清空用户隔离数据、配置、build 或其他临时目录。

