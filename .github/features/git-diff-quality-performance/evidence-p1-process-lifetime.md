# P1 关闭 Diff 后的真实 Git 进程

本页补充 `evidence-p1.md`，记录缺陷基线，不表示取消问题已经修复。
2026-11-06 在 `d5391b61`、macOS 27.3 / 26C5035r、Xcode 27.2、
Apple M1 Pro 上运行隔离 Bailey Dev 宿主测试。

临时 Git 仓库包含两个已跟踪文件。慢文件使用仓库私有的 clean filter：
进入 filter 时记录自身及父进程 PID，并等待临时仓库内的释放标记；
释放后原样转发输入，不修改工作区或 Index。
测试打开慢文件的 Worktree Diff，确认真实父进程是
`git hash-object --path=slow.txt --stdin`，再打开并加载快速文件的 Diff。
通过 `Project.close` 关闭慢标签，确认其 `DiffTab` 已释放后检查进程。

- 关闭后约 506 ms，最初的 Git 进程和 filter 都仍存活。
- 手动释放 filter 后，旧读取继续触发第二次 filter；约 668 ms 时两次调用均已退出。
- 快速 Diff 始终保持选中且内容正确；两个工作区文件字节和 Git Index 均未改变。

命令 `make test ONLY_TESTING=BaileyTests/NativeDiffTabTests/testAuditClosingSlowDiffLeavesGitFilterRunning`
实际执行 1 项、0 失败，完整 Make 退出 0。测试通过只说明上述**缺陷被复现**，
不代表取消符合要求；日志为 `build/git-diff-p1-close-filter-process-experiment.log`。
一次性测试补丁为 `build/git-diff-p1-close-filter-experiment.patch`，
没有留在常规测试目标。

进一步在相同真实仓库中连续打开并关闭慢 Diff 五次，每次确认标签对象已释放：
五个 `git hash-object` 进程及各自的五个 filter 同时仍在运行。
释放后确认五个独立 `git diff` 父进程确实继续执行；本次总计观察到 20 次
filter 调用，所记录的相关进程均已退出，快速 Diff 和磁盘／Index 字节仍正确。
修正后的实验实际执行 1 项、0 失败、Make 退出 0；日志与一次性补丁分别为
`build/git-diff-p1-close-filter-reopen5-corrected.log`、
`build/git-diff-p1-close-filter-reopen5-corrected.patch`。

该实验的第一版错误地假定每个后续 Git 操作恰好调用一次 filter；
实测出现更多调用，断言失败，Make 退出 2。
原始失败和补丁保留在 `build/git-diff-p1-close-filter-reopen5-experiment.log`、
`build/git-diff-p1-close-filter-reopen5-failed.patch`。
修正版按真实 `git diff` 父进程身份确认五条后续路径，而非放宽次数断言后直接重跑。

以上实验只覆盖本机 Worktree 慢 clean filter → 快速 Worktree → 关闭／重开慢标签；
不证明 Staged／历史、编辑时失效、项目关闭或 SSH 断线的实际进程行为，
也没有测量自然超时、峰值 RSS 或传输字节。P3-T3 仍须在现有任务所有者和后端
修复取消传播，并以停止真实进程、保留当前内容及文件字节的回归验证。

同日约 12:06，分别禁用 SSH master、指定 4 秒连接超时复核已授权的
`windows` 和 `wincrh`：两者连接均超时、退出 255；Tailscale 仍为停止状态。
没有借用既有连接，也没有启动网络服务或修改远端文件。
约 12:09 用户明确要求开启 Tailscale；执行不带参数的 `Tailscale up`，
状态变为 `Running`，未改变现有设置。之后禁用 SSH master 独立连接
`windows` 成功、退出 0；`wincrh` 仍超时。连接成功不等于真实 Diff、
取消、断线及保存验收通过。

随后在 `windows` 上运行
`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test ONLY_TESTING=BaileyTests/NativeDiffTabTests/testAuthorizedWindowsSSHGitReviewAndRawSaveMatchGitCleanRules`：
实际执行 1 项、0 失败、0 跳过，完整命令退出 0，耗时 72.663 秒；
日志为 `build/git-diff-p1-windows-live-connected.log`。
该测试使用独立 SSH socket 和经正则校验的一次性远端目录，覆盖 Windows
`core.autocrlf=true`、`text`／`-text`、clean filter、原生 Diff 及保存后真实字节和 Git 结果，
并清理自己的目录与 master。它不证明真实 SSH 断线、取消、其他来源或完整 App GUI。

随后执行真实 `WorkspaceGitUITests/testAuthorizedWindowsSSHGitReviewThroughRealUI`。
第一轮实际执行但失败：测试按 `Git Manager` 文案匹配到了已有 Dock 标签，
而非预期的添加面板动作；失败时 AX 层级显示 Files 仍被选中，
因此等待 Git Changes 行超时。原始日志为 `build/git-diff-p1-windows-ui-connected.log`，
失败 AX 层级保存在 `build/git-diff-p1-windows-ui-failure-attachments/`。
该次 XCUI 点击失败后原有 `defer` 未能清理远端夹具；
核对独立仓库身份及内容后，只删除该次确认属于测试的目录，
并关闭该次 Dev PID 专属 SSH master。

测试改为先核对目标 SSH 项目选中，再走现有 Git 快捷键并核对 Git 标签选中；
远端夹具清理改由 XCTest teardown block 注册，失败不能静默吞掉。
临时注入不存在的控件点击，确实触发 XCUI 失败，
随后通过独立 SSH 确认远端目录已删除；故意失败的日志与临时补丁为
`build/git-diff-p1-windows-ui-teardown-injected.log`、
`build/git-diff-p1-windows-ui-teardown-injected.patch`。
移除故意失败后，真实 Windows GUI 测试执行 1 项、0 失败、0 跳过，
完整 Make 退出 0；日志为 `build/git-diff-p1-windows-ui-corrected.log`。
该用例通过系统输入编辑并保存，核对远端原文字节及 clean filter 后的显示；
独立确认本次远端目录已删除，并关闭本次 Dev PID 专属 SSH master。
测试夹具及选择修复提交 `33348f07`；这不是其它 GUI 来源、真实网络断线或高帧率首屏的验收。

带真实 SSH 的整组 GUI 第一次运行 7 项中有 1 项失败：远端原文已保存，
但读取刷新后的原生视图时 XCTest 找不到窗口。
失败附件仅有应用菜单、没有窗口；系统焦点日志进一步显示 12:55:44
正式 Bailey 成为前台，12:55:47 系统切到浏览器所在 Space，
而 Dev 进程直到失败后的 teardown 才退出。证据分别在
`build/git-diff-p1-windows-ui-full-class.log`、
`build/git-diff-p1-windows-ui-class-failure-attachments/` 和
`build/git-diff-p1-windows-ui-failed-focus.log`。因此这次失败发生在
独占桌面焦点的前提被打断时，不据此断言产品保存失败，也不抹去该次失败。

用户确认暂时不操作桌面后，带真实 `windows` SSH 重跑完整
`WorkspaceGitUITests`，实际执行 7 项、0 失败、0 跳过，Make 退出 0；
日志为 `build/git-diff-p1-windows-ui-full-class-exclusive.log`。
独立确认远端夹具已删除，并仅关闭该次 Dev PID 创建的 SSH master。
这解释了本次窗口丢失，不证明历史上每次 ⌘S 超时都有相同原因。

准备运行 SSH 恢复基线时发现，该测试的 `mktemp` 结果原先只检查父目录及前缀，
未限制随机后缀字符；非零退出后也可能继续使用输出。
已在对应测试中增加严格路径和退出状态校验，并在创建失败时回收测试专用 socket。
恶意字符、错误长度等输入的原始 Red 日志是
`build/git-diff-p1-ssh-fixture-validation-red.log`；修复后定点测试通过，
日志为 `build/git-diff-p1-ssh-fixture-validation-green.log`。
进一步与相邻 `RemoteCommandsTests` 共同执行 21 项、0 失败，完整命令退出 0；
日志为 `build/git-diff-p1-ssh-fixture-validation-adjacent.log`，代码提交 `3c98b438`。
相邻测试出现一次 `ProcessStdinWriter.finish` 的 QoS 优先级反转警告；
该测试直接在较高 QoS 调用 runner，而正常 SSH 入口使用 utility 任务。
旧全量日志中同一 writer 也出现过类似警告；尚未证明实际用户路径受影响，
后续检查进程与输出预算时应保留此证据，不据此擅改生产调度。

使用已授权 `windows`、私有 SSH master 和通过校验的临时 Git 仓库运行
`SSHGitRecoveryLiveTests/testAuthorizedWindowsGitSnapshotSurvivesTransportFailureAndCanWriteOnlyAfterRecovery`，
同时启用该测试已有的 `BAILEY_SSH_BENCHMARK=1`：实际执行 1 项、0 失败、0 跳过，
完整 Make 退出 0，日志 `build/git-diff-p1-windows-recovery-benchmark.log`。
模型首次 `sync` 至核心状态 3.029 秒，至刷新结束 7.223 秒；之后 30 次热刷新
中位 8.181 秒、P95 9.016 秒、最差 11.925 秒。
首次 `sync` 前已经为测试建仓并建立 SSH master，故不是冷连接握手时间；
这些是 Git 状态模型时间，不是单文件 Diff、网络 RTT 或窗口首帧。
测试中的断连由专用 runner 注入失败，验证保留快照、拒绝旧目标及恢复后的真实暂存／取消暂存；
它不证明物理网络断开或在途 SSH 进程取消。测试结束时清理自己的远端目录与 master。
随后用不复用 master 的独立连接确认该次远端目录不存在，
并确认本地测试专用 socket 已消失。首次核查命令因 zsh 的只读变量名报错，
更正变量名后的完整核查退出 0；没有再次删除远端内容。

随后在 `GitRemoteRefreshIntegrationTests` 用 15 处失败断言复现相同的前缀校验缺口，
改为拒绝失败状态、无效 UTF-8 和不匹配完整随机目录的输出；外部连接 socket 也改用
完整 UUID 并拒绝复用。Red 与 Green 分别在
`build/git-diff-p1-remote-refresh-fixture-red.log` 和
`build/git-diff-p1-remote-refresh-fixture-green.log`。
带授权 `windows` 主机运行整个类：3 项、0 失败、0 跳过，完整 Make 退出 0；
真实外部工作区变动和外部提交被轮询观察，取消后验证未继续轮询并能手动恢复。
日志为 `build/git-diff-p1-remote-refresh-windows-class.log`，代码提交 `82d17ea8`。
测试前已存在另一个同前缀目录，本次未触碰；独立连接确认本次目录已删除、
测试外部 socket 已由测试回收，并仅关闭本次宿主 PID 所有的主 socket。
该类验证不代表真实网络断线或完整 App 隐藏／恢复界面通过。

其它实际 SSH 用例中仍可见相同的宽松路径检查，包括
`BaileyTests/Git/GitWorkspaceSSHTests.swift`、
`BaileyTests/Remote/GitInteractiveRebaseIntegrationTests.swift`、
`BaileyTests/Files/SSHFileTreeLiveTests.swift` 与
`BaileyTests/Remote/SSHWindowsFileEventsTests.swift`。
本次没有运行这些需要清理远端目录的用例；在未来带主机参数的完整回归前，
须按各自真实入口核对并补足安全的完整路径校验，不能把当前修复推广为全部已安全。

## 关闭 Diff 后旧原生视图的资源

一次性宿主实验使用真实临时 Git 仓库和 2,000 行 Swift 工作区文件，
通过 `Project.openDiff` 建立可编辑 Diff 并渲染原生表面；确认实际正文、
可编辑状态和语法解析器后，只强持有该 pane 的 `NSScrollView`。
`project.closeDiffs()` 之后确认标签已删除、弱引用的 `DiffTab` 已释放，
但保留的 scroll view 仍持有可编辑 `DiffTextView`、语法 coordinator 和
35,780 字节正文。相应的三个退役断言均失败；磁盘原文没有变化。
日志 `build/git-diff-p1-closed-diff-retention-red.log`、可重放的一次性补丁
`build/git-diff-p1-closed-diff-retention-red.patch`；Make 退出非零，
不能写作通过。实验代码已从常规测试目标移除。

此实验是人为保留旧 scroll view，证明所有权结束时没有解除原生正文，
不证明 AppKit 在每次实际关闭时必然缓存该视图，也未测 Undo、窗口／项目关闭、
重复打开或内存曲线。P2-T4 须在真正所有权结束处完成 Red→Green，
并区分 Dock 临时重挂载与关闭，确保未保存草稿和 Undo 不被提前清理。

## 多标签内存及 TextKit 所有权

在独立宿主中逐个打开并渲染 20 个不同的未跟踪 Swift 文件，每个文件
24,000 行、481,780 字节；每次检查可编辑原文与语法 coordinator。
这是原生组件和真实临时 Git 仓库，不是完整 App 窗口。
通过 `task_info` 读取宿主 RSS，并用 `malloc_zone_statistics(nil, ...)`
汇总进程所有 malloc zone 的在用字节。一次结果如下；释放后期间另取过 heap 快照：

| 状态 | 在用 malloc | RSS |
| --- | ---: | ---: |
| 打开前 | 17.9 MiB | 156.8 MiB |
| 1 个标签 | 140.7 MiB | 300.4 MiB |
| 5 个标签 | 615.8 MiB | 767.0 MiB |
| 10 个标签 | 1,211.8 MiB | 1,348.5 MiB |
| 20 个标签 | 2,401.3 MiB | 2,496.4 MiB |
| 全部关闭、保留 20 个旧 scroll view | 2,027.0 MiB | 2,496.5 MiB |
| 放开旧 scroll view 30 秒后 | 539.3 MiB | 2,364.9 MiB |

关闭时 20 个 `DiffTab` 均已释放；人为保留的 20 个 scroll view 仍各自
持有可编辑正文和语法 coordinator。放开它们后 20 个 `DiffTextView` 的弱引用
均清零，最终逐文件核对磁盘字节未变。测试 1 项、0 失败、0 跳过，Make 退出 0；
日志和一次性补丁为 `build/git-diff-p1-many-diff-tab-resources-recovery.log`、
`build/git-diff-p1-many-diff-tab-resources-recovery.patch`。
这是整个测试宿主的瞬时总量，不是每个标签的独占分配；RSS 包含分配器保留和
共享页面，不能据此判断对象仍然存活。初轮在 2 GiB 保护线处主动跳过，
日志 `build/git-diff-p1-many-diff-tab-resources.log`，未冒称测到 20 个标签；
监控系统内存后以 3 GiB 保护线完成上表。

独立 heap 快照显示，加载过程中的 `NSTextLayoutFragment`、`NSTextLineFragment`、
CoreText 字形和 Diff 行数组均占可观内存；放开旧 scroll view 后的快照仍有
144,000 个原生布局片段。日志为
`build/git-diff-p1-many-diff-tab-heap-snapshot.log`、
`build/git-diff-p1-many-diff-tab-heap-after-release.log`。
它们是两个时刻的整个宿主快照，不能仅凭类别数量认定持有者。

为确认对象身份，另一轮 5 标签实验用独立弱引用跟踪原始
`NSTextLayoutManager`：关闭标签、放开全部旧 scroll view 并确认 5 个
`DiffTextView` 已释放后，这 5 个原始 manager 在 60 秒时仍全部存活；
此时 malloc 在用 386.4 MiB。对一个已记录地址执行 `leaks --trace`，
报告包含通知中心、`NSTextContentStorage`／`NSTextContainer` 和布局 manager 的引用路径；
其中部分根是保守扫描候选，不能单凭路径断定唯一系统根因。
证据为 `build/git-diff-p1-five-diff-manager-lifetime-corrected.log`、
`build/git-diff-p1-five-diff-manager-lifetime-corrected.patch` 和
`build/git-diff-p1-five-diff-manager-retained-trace.log`。

再以相同的 5 标签实验，仅在确认真关闭和原生视图释放后，保留测试专用的
storage／manager 引用并调用 `storage.removeTextLayoutManager(manager)`：
放开这些测试引用后 5 个 manager 的弱引用全部清零，malloc 在用从约
386.5 MiB 降至 65.3 MiB；后续对已释放 manager 的 container 清理没有对象可处理。
磁盘字节不变，实验 1 项、0 失败、0 跳过，Make 退出 0；日志及补丁为
`build/git-diff-p1-five-diff-detach-ablation.log`、
`build/git-diff-p1-five-diff-detach-ablation.patch`。
另一轮仅清空旧文本后仍有大量 malloc 在用，不能当作充分修复，见
`build/git-diff-p1-five-diff-retired-text-experiment.log`。
这些是关闭后的受控对象实验：尚未证明可在真实窗口关闭顺序、未保存草稿、
Dock 重挂载和共享 Files 编辑器上安全地执行同一操作；P2-T4 必须补齐。

弱引用实验的初版用 `NSHashTable.count == 0` 等待释放而超时；独立最小对照
显示对象释放后 `count=1`、`allObjects.count=0`，故更正为检查实际活对象。
失败日志、补丁和对照分别为 `build/git-diff-p1-five-diff-manager-lifetime.log`、
`build/git-diff-p1-five-diff-manager-lifetime-failed.patch`、
`build/git-diff-p1-weak-hashtable-count.log`，不把夹具错误当产品失败。

## 5 MiB 本机输入边界

独立宿主用真实临时 Git 仓库和未跟踪工作区文本，分别读取 5 MiB 减 1 字节、
恰好 5 MiB、5 MiB 加 1 字节；输入每 256 字节包含一个 LF，恰好 5 MiB 样本
共有 20,480 个换行。前两者成功、可编辑并核对完整 UTF-8 和磁盘字节；
超限样本报告错误且不可编辑，原始文件未改。

单次 Debug 观测中，恰好 5 MiB 的读取约 38.8 ms、模型可挂载约 146.4 ms，
包括创建和布局原生表面约 1,761.7 ms。测试 1 项、0 失败、0 跳过，
Make 退出 0；日志和一次性源码为
`build/git-diff-p1-5mib-boundary-experiment.log`、
`build/git-diff-p1-5mib-boundary-experiment.patch`。
这是组件单次结果，不是窗口像素、冷进程、Release 或 30 次 P95；
也没有核销极短行、其它 Git 来源、混合换行和 5 MiB 边界的所有组合。

另以恰好 5 MiB、每 52 字节一个 LF 的未跟踪文本测量 100,825 行：
模型可挂载约 386.5 ms、该时刻宿主 RSS 约 323.7 MiB，创建并布局原生表面累计约
3,828.7 ms。实际编辑器内容和磁盘字节均与输入一致；测试 1 项、0 失败、
0 跳过，Make 退出 0，临时仓库已确认删除。日志和一次性源码为
`build/git-diff-p1-5mib-100k-experiment.log`、
`build/git-diff-p1-5mib-100k-experiment.patch`。
这仍是单次 Debug 组件结果，不是 Native 首像素／可输入、Release、30 次统计，
也不代表在同样容量下更多极短行的内存和延迟。

## 已有构建与回归

在当时一次性测试代码移出常规目标后，提交 `d5391b61` 执行：

- `make build`：Debug 构建及 `codesign --verify --deep --strict` 通过，完整命令退出 0；
  日志为 `build/git-diff-p1-continuation-build.log`。
- `make test`：实际执行 854 项，16 项 SSH 跳过、0 失败，完整命令退出 0；
  日志为 `build/git-diff-p1-continuation-full-host.log`。
  命令启动时没有传入 SSH 测试主机，即使中途 Tailscale 连接成功，
  已跳过的项目也不等于通过；需另行运行真实 SSH 测试。
- 之后提交 `82d17ea8` 执行 `make build:dev`，Debug 构建及独立 Dev 签名检查
  退出 0；日志为 `build/git-diff-p1-current-dev-build.log`。

这只验证对应提交，不代表之后修改或 P2／P3 实现已通过全量测试，也没有安装或重启正式 App。
