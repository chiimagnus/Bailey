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

