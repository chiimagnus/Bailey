# Audit P4 - modular-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p4.md`
- feature 目录：`.github/features/modular-architecture/`
- 粒度：`phase`

## 任务看板

- [x] P4-T1 提取 Git 进程执行，并一次性修正全部消费者

## 任务到文件的映射

- P4-T1
  - `kero/Git/GitCommandExecution.swift`：唯一专用本地字节进程、文本解码、远端映射。
  - `kero/Git/GitStatusModel.swift`：操作/刷新/仓库解析使用新入口，批次与状态仍属模型。
  - `kero/Git/DiffViewerView.swift`：blob 捕获上限、二进制和 UTF-8 判定使用新入口。
  - `kero/UI/CommandPaletteView.swift`：tracked/untracked 与坏 submodule fallback 同步切换。
  - `kero/Remote/SSHWorkspaceBackend.swift`：接口和能力注释；执行/认证未重写。
  - `scripts/check-git-execution.swift`、`scripts/check-git-panel-state.swift`、`scripts/check-workspace-identity.swift`、`docs/CONTRIBUTING.md`：真实执行和消费者回归。

## 发现项

## 发现 F-101

- 任务：`P4-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitCommandExecution.swift:78`
- 摘要：`独立复审：Git先退出但后台子进程持有管道时超时失效`
- 风险：`显式timeout仅等待Git进程，提前成功后readers.wait无期限等待；后台hook或helper可让用户请求持续卡住`
- 预期修复：`将进程退出与管道排空纳入同一原始deadline，超时后复用现有所有者进程组收尾，不新增runner或重试`
- 验证：`真实Git alias父进程正常退出而忽略TERM后台子进程持有管道，0.1秒期限仍须约1.2秒收尾并保留部分输出；原超时与字节检查继续通过`
- 解决证据：`本轮修复提交见HEAD。新增真实Git正常退出但后台helper持有管道的回归修改前失败；修改后日志/tmp/kero-independent-git-after.log为1.105秒并返回-2/保留orphan。Git既有回归及实际App身份、Diff大小/二进制/历史、原生重挂载和签名Debug PASS。`


- 本轮审计没有仍未修复的发现项。实施期的忽略 SIGTERM helper 超时问题已有稳定复现与同提交修复，不另造 Open 项。

## 修复日志

- `3e32370`：移除全部旧 runner、双管道重复实现和不可达 remoteTextLineCount；一个 Git 字节 runner 仍排空限量捕获的 stdout，保留读线程 QoS、环境、错误码和部分输出。
- 超时升级同时观察进程退出与管道 EOF；只对 getpgid 实际证明本次 Git 所有的进程组发 SIGKILL，普通终止路径不改变。原用例从约 5 秒降至约 1.18 秒，部分输出保留。
- 仓库/HEAD/指纹保护、代次、刷新合并、远端快照与行数批次均保留；未引入新协议、通用 runner 或第二套状态。

## 验证日志

- CONTRIBUTING 十项独立 swiftc 检查重新编译运行 -> PASS；`/tmp/kero-p4-regression.log`。
- 签名 Debug xcodebuild、严格 codesign -> PASS；`/tmp/kero-p4-final-build.log`，包更新仅限 `sh.kero.test`。
- `bash scripts/check-workspace-identity.sh` -> PASS；实际 App Git unborn、未跟踪、暂存、历史及 Diff NUL/无效 UTF-8/恰好 5 MiB/超限。
- 专用 Windows master 参数检查 -> PASS；真实 SSH 快照批次、历史、未跟踪计数和 File/Diff 断线拒写、换连接后远端字节/本机 sentinel 核对；`/tmp/kero-p4-identity-final.log`，自建远端目录已删除。
- `bash scripts/check-pane-retention.sh` -> PASS；`/tmp/kero-p4-pane-final.log`。
- 签名 Kero Test -> PASS：新入口驱动的实际 Git 工作区、Diff +3 渲染，提交中文组合文本后搜索命中文件并打开；新鲜窗口坐标 hover 显示 x，点击后标签实际关闭。
- 全仓旧 API/runner/remoteTextLineCount 搜索无产品残留，唯一 Process 位于 GitCommandExecution；git diff --check -> PASS。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：唯一执行职责与全部消费者接入成立，限量/失败/超时边界和实际 SSH 最终副作用验证通过。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：SSH 传输依然先收完整输出再限量，不宣称流式内存上限；未改 Windows 不具备的 Linux Info 查询。现有 TerminalHistory 与 Dock 默认参数 actor 编译 warning 和 SwiftPM identity warning 不冒称消除，不影响当前 Swift 5 build/test 通过。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-12 执行完成后的独立复审

不使用旧 audit 结论，按 P4-T1、`3e32370` 的 diff 和当前生产路径重新核对。

- GitStatusModel 的状态/操作、DiffTab 的 cat-file 大小与字节读取、Palette 的 ls-files 主路径及子模块 fallback 均实际改用 GitCommandExecution；没有孤立的新文件。Xcode 同步根接入该文件，实际 App 模块的 Git 和 Diff 检查通过。
- 旧 runGit/remoteGitData/DiffPipeData 与重复本地 runner 已移除。保留单一 raw Data 捕获，文本只是解码；Diff 仍传 maxBytes+1 并独立拒绝 NUL/非法 UTF-8/超限。本轮实际 App 的恰好 5 MiB/超限和历史 Diff 验证 PASS。
- SSH 快照 prefetchedSnapshotCommands 与 RemoteCommands 批次仍由当前 GitStatusModel 消费，未机械转换成多次远端往返；远端参数/环境/错误映射独立检查 PASS。现有状态代次、刷新合并、HEAD/仓库/指纹校验具有真实消费者，不能作为多余围栏删除。
- 新 F-101：进程先正常退出不代表输出管道关闭。唯一执行器原先只等待进程 deadline，随后无期限 readers.wait；真实 Git alias 的后台 helper 保留管道时新增回归失败。修复用同一原始 deadline 等待进程与管道，继续使用已验证归本次 Git 所有的进程组收尾，不新增 runner、全局状态或重试。
- `/tmp/kero-independent-git-after.log`：正常超时约 0.11 秒、忽略 TERM helper 约 1.18 秒、Git 已退出而 helper 持管道约 1.11 秒，均保留部分输出；真实字节/文本/literal 路径/上限排空/环境/启动错误/远端映射 PASS。
- 重新构建与严格签名 PASS；实际 App 身份/Git/Diff与原生 Browser 重挂载重新编译运行 PASS，日志 `/tmp/kero-independent-final-build.log`、`/tmp/kero-independent-final-identity.log`、`/tmp/kero-independent-final-retention.log`。
- 本轮 Gate：Go，F-101 已根因修复；SSH 仍先捕获完整输出再限量，不宣称流式内存上限。

