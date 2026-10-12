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

