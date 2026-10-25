# P2-T1：Windows SSH 事件通道实测

测试日期：2026-10-25。**只使用 `ssh windows`**，经现有配置连接 Windows 10／MSYS2；`wincrh` 是工位局域网地址，本计划不再使用或修改。所有写入均限于测试临时目录，连接以 `BatchMode=yes`、严格主机密钥验证、测试独立 SSH 通道执行，未占用用户终端或 master。

## 已证实

| 目标 | 真实结果 |
| --- | --- |
| 通知源 | 系统 `powershell.exe` 的 `System.IO.FileSystemWatcher` 可由 MSYS2 SSH 调用，订阅后收到 Created、Changed、Deleted、Renamed。D 盘 `/d/GitHub/...` 经 `cygpath -w` 映射至 `D:\GitHub\...`，中文及空格文件名可触发。 |
| 高频与最终状态 | 400 次创建 + 150 次删除，2 秒节流输出 **5 个脏信号／166 字节**，真实磁盘剩余 250 文件；此前连续记录 120 次突发中的 122 条原始通知。仅发送“需复查”，不信任事件自带路径修改树。 |
| 持续流与进程清理 | **独立且禁用 ControlMaster 的 SSH `-tt` PTY** 订阅收到多次事件并正常结束；取消已运行中的 watcher 后，远端 PowerShell PID 不再存在。**不能使用 `-T` 非 PTY**：该模式断开 SSH 后遗留远端 PowerShell。**也不能使用 `ControlMaster=auto` 的通知子通道**：独立测试 socket 实测即使 `-tt`，终止子通道后远端 PowerShell 仍存活；已按唯一实验标识清理并关闭测试专用 master。生产通知只能评估 `ControlMaster=no`、`-S none` 的独立 PTY 事件通道。 |
| 空闲资源／时限 | Windows PowerShell 单个监听器工作集约 **66.6–66.7 MiB**，实测 5 秒空闲累计 CPU 时间未增长。测试订阅设置 **15 秒自退出租期**后正常结束且无残留。长期多订阅成本尚未验收，不据此宣称性能达标。 |
| Git 元数据 | 独立临时 Git 仓库及 Worktree：真实关联 Worktree 提交、Stash、Tag 后，主仓库收到 175 条、关联树收到 2 条事件，Git Ref/提交核验正确；另一轮操作 211 条事件中 123 条是 `.git` 下非 `index.lock`／根目录的元数据变化。 |
| Git 自触发 | **明确缺陷：**仅连续执行 8 次 `git status`／`git log` 就产生约 29 条 `.git/index.lock` 创建／删除及 `.git` 目录 Changed 通知。不能把这些通知无条件转成新一次 Git 查询，否则可能形成自刷新循环。 |

原有 `ProcessRemoteCommandRunner.run` **等待命令结束且累积 stdout/stderr**，不能直接作为持续事件流。实测 `-tt` 终端输出会混入控制码，因此实际接入必须解析有界的专属帧标记、独立排空 stderr，避免误读终端提示和无界内存占用。

## Go / No-Go

- **Windows SSH Files：仅独立 PTY 通道具备技术可行性 Go，允许进入 P2-T2 实现与带回退验收**。共享 ControlMaster 的通知通道实测 No-Go。此 Go 不代表已删除 2 秒轮询或 GUI 通过。必须先证明监听 READY + 初读完成、信号合并后真实 Files 行与索引收敛；EOF／非支持平台／异常／到期应恢复原轮询；独立 PTY、有限租期及取消后远端进程退出是强制门槛，并须复测多窗口资源与异常网络。只有全部完成才能切健康态轮询。
- **Windows SSH Git：暂未 Go。** 必须证明安全消除 `.git/index.lock`／目录自身的只读噪声，同时不遗漏 `index`、`HEAD`、refs、stash、rebase、merge 和外置 gitdir/commondir 的真正变化。P2-T3 不得仅凭“收到过 Git 事件”开始替换 5 秒轮询。
- **其他 SSH 系统：未验证，不具备 Go 依据。** 保持现有 2／5 秒机制及终端连接存活和 cwd 探测。

## 仍需核销

1. `FileSystemWatcher.Error`／内部 buffer overflow、已建立订阅时根目录移走或权限变化、订阅前及重连窗口内变更：要证明实际磁盘最终状态会被重新读取，而非仅收到事件。
2. 半开连接／延迟／丢包、端口不可达、远端 PowerShell 异常退出和 Mac App 关闭：须用测试自有进程与 socket 验证有界结束与回退，不能切断用户网络或清理用户 master。租期过期是孤儿寿命上限的候选机制。
3. 多项目、多窗口、多根目录及长时间 CPU／内存：单监听器约 67 MiB，若采用每面板一份进程可能不可接受；应限制拥有者与共享通道数量，并对照旧 2 秒轮询测请求次数。
4. 完整 Bailey GUI 与 macOS 15.6 真机尚无授权／设备，不以宿主或命令行实验冒充验收。

测试脚本只存放于 Mac `/tmp/` 并在运行后删除。Windows 的 `/tmp/bailey-p2-*` 及 D 盘 `.bailey-p2-*` 已核对无残留；测试专属 ControlMaster socket 已主动关闭。**真实 SSH 集成测试**：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHFileTreeLiveTests,GitWorkspaceSSHTests,SSHGitRecoveryLiveTests,GitRemoteRefreshIntegrationTests,RemoteLifetimeTests`，**14 项通过、0 失败、0 跳过**，包括真实远端文件树、Git Worktree、Stash、二进制归档、远端断线恢复和生命周期；日志 `/tmp/bailey-event-p2-windows-live-20261025.log`。这些测试验证现有远端后端与回退基础，不等同于尚未接入的通知驱动 GUI。
