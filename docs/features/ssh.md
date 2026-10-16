# SSH 工作区

SSH 后端让文件和 Git 面板直接操作远端项目，不要求挂载文件系统。连接、远端命令或目标绑定改变时更新本页；长期转发另见 [tunnels.md](tunnels.md)。

## Invariants

- **远程失败不能回退写入本机。** 同名路径不是同一文件，读取、保存、删除和 Git 操作都不能换目标重试。
- **标签保留创建时的机器。** 主机、端口、连接与路径一起参与身份；当前终端变化不能偷偷改写标签目标。
- **断线保留编辑。** 文件及可编辑 Diff 转为只读，已输入内容、撤销与错误仍在。
- **换连接立即失效旧请求。** 同一机器重连或切到另一条可用通道也要重新绑定，不要求先经过只读状态。
- **主机信任失败不能绕过。** 不关闭校验，也不借用用户正在工作的连接进行测试。

## 连接与后端

复用既有 OpenSSH 配置、密钥和工作区 master。交互会话与文件／Git 操作不是同一条生命期路径：终端仍能输入，不足以证明后端连接正常。

固定 SSH 项目的新终端与 Files/Git 采用相同 OpenSSH 多路复用选项，`%C` 按实际主机、用户、端口及跳板配置区分 socket；ControlMaster 持久化独立于终端标签，关闭一个标签不关闭其余操作。手动在本地 Shell 输入的 `ssh` 仍走自己的已认证会话管理，不强行共享此连接。失联时不自动改写目标或回退本机；保持主机密钥校验和批量命令。Files 目录首次加载和刷新按同层目录批量读取，展开已有目录优先用缓存，网络工作由后端异步执行。真实 SSH 测试继续使用专属 socket，禁止借用和关闭用户 master。

外部 Git 工具不会发出 Kero 终端的命令完成事件。当前 SSH 项目 Git 面板的前台可见刷新、暂停条件和失败提示由 [Git 刷新](git.md#刷新与显示) 统一维护；不增加独立的远端后台监控。

交互式变基是明确创建的新终端，拥有独立的 SSH 连接。固定主机与自动跟随的项目都捕获原机器、端口和 Git 根；握手前暂存启动目标，握手后由真实 RemoteConnection 接管。以普通登录终端接收原生启动输入，不把复杂远端 command 的 Windows 参数重组当作 POSIX 语义。连接或会话结束后保留断线目标与结果，不回退操作 Mac。

Git Ref 归档在所选 SSH 工作区的临时目录生成，经 Git 原生进程写入后，通过已有后端一次有界读取保存至 Mac：传输限制为 **64 MiB**，超限不替换目标文件。只清理本次临时目录；断线导致清理失败时保留具体远端路径和失败反馈，不把 Mac 路径交给远端或反向写入。

远端命令要求 POSIX shell 与相应 GNU 工具。Windows 支持依赖 MSYS2 路径和 shell，不承诺原生 PowerShell 命令兼容；路径转义与参数边界必须由后端处理。

## 断线与恢复

发布异步结果、开始副作用以及保存完成回写时，都核对当前绑定。旧通道的保存结果不能清除新通道／新目标的未保存标记。重连只恢复原机器上的操作能力，不通过创建另一份编辑缓冲来“修复”状态。

远端删除不进入本机废纸篓。操作前确认范围和可恢复性，不能承诺像本机文件一样从废纸篓找回。安全边界统一见 [SECURITY.md](../../SECURITY.md)。

## 验证

`RemoteCommandsTests`、`RemoteLifetimeTests`、`WorkspaceIdentityTests` 和工作区身份回归检查 SSH 批量目录读取、复用参数、绑定、取消、失败与过期结果。受控后端只能证明这些逻辑，不能证明真实传输；`SSHFileTreeLiveTests` 使用专用、获准的 Windows SSH master 检查特殊目录名、批量读取、单目录失败隔离和文件树冷加载／缓存展开／批量刷新各自的 SSH 请求次数；显式 `KERO_SSH_BENCHMARK=1` 时再测冷加载与 30 次热路径的中位数/p95。`SSHGitRecoveryLiveTests` 使用另一个专用 master 和 Windows 临时仓库，模拟仅该测试传输失联，验证 Git Graph 保留、写操作拒绝、恢复后重新允许暂存；显式开启 `KERO_SSH_BENCHMARK=1` 时测首次 Git 核心/详情耗时和 30 次热刷新。不会切断用户或系统网络连接。测量不代替完整 App 视觉响应或原生网络异常的 UI 验收。

归档的验证分层：模拟 SSH 后端覆盖传输上限与远端清理失败；`GitWorkspaceSSHTests` 在真实 Windows SSH 中核对选定 Ref 的 ZIP 原始字节，远端分支经原生保存面板归档另有 [P4 现场证据](../../.github/features/git-manager-context-menus-graph/evidence-p4.md)。这些成功路径不代表断线时完整 App 的清理与恢复已完成验收。

实现边界：[WorkspaceBackend.swift](../../kero/Workspace/WorkspaceBackend.swift)、[RemoteCommands.swift](../../kero/Remote/RemoteCommands.swift)。统一运行方式见 [testing.md](../testing.md)。
