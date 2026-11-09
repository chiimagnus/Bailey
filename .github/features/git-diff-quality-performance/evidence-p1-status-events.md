# P1 文件事件热态基线

本页补充 `evidence-p1.md`，不是阶段完成声明。
2026-11-06 在 `d5391b61`、macOS 27.3 / 26C5035r、Xcode 27.2、
Apple M1 Pro 上运行隔离 Bailey Dev 宿主测试。

测试使用真实临时 Git 仓库和 `GitStatusModel.sync(root:)` 的本机 FSEvents 路径。
分别建立 1、100、10,000 个未跟踪文件，在同一已跟踪文件上交替写入修改与原文，
每档各 30 次，其中修改和恢复各 15 次；等待模型中的实际文件状态变化，
随后等待 `isRefreshing` 结束，核对变更数量与磁盘原始字节。
没有手动调用刷新。等待条件按 20 ms 轮询，结果包含轮询误差。
每组升序第 16、29、30 个样本分别记为上中位、P95 和最差。

| 未跟踪文件数 | 事件至状态行上中位 / P95 / 最差 | 事件至刷新结束上中位 / P95 / 最差 |
| --- | --- | --- |
| 1 | 771.9 / 867.4 / 941.9 ms | 959.9 / 1038.2 / 1112.3 ms |
| 100 | 753.6 / 835.4 / 838.5 ms | 925.8 / 1016.0 / 1093.1 ms |
| 10,000 | 750.4 / 878.5 / 883.1 ms | 1035.4 / 1160.1 / 1162.9 ms |

命令 `make test ONLY_TESTING=BaileyTests/GitStatusModelTests/testAuditGitStatusFileEventLatencyMatrix`
实际发现并执行 1 项、0 失败，完整 Make 退出 0；原始日志为
`build/git-diff-p1-status-event-30-isolated.log`。
一次性测试源码保存在 `build/git-diff-p1-status-event-30-experiment.patch`，
已从常规测试目标移除，避免每次完整回归都增加这组 90 次性能实验。

这里的“状态行”是模型 `changedEntries`，不是 Changes 面板的窗口像素；
`isRefreshing` 结束也不单独证明所有详情字段已成功更新。
该结果不能代替完整 App 首屏、可输入、Git 进程取消或 SSH 验收。

首次尝试与另一项 Dev 窗口采样重叠，主动中断，Make 退出 2；
`build/git-diff-p1-status-event-30-matrix.log` 保留该结果，不作为上表数据。
本页测试在前一窗口实验结束后开始，并在下一窗口实验开始前结束。

按窗口采集 `action.json` 与宿主日志文件创建时间核对，
中断的 Make 命令约在 11:47:34 已启动，而非直到 11:47:59 测试方法开始。
因此 `build/git-diff-p1-30gui-cold-1793936862/` 的 `sample-01` 至 `sample-03`
与构建或测试实际重叠；它们仍可用于观察来源与截图，
但不能作为独占资源下的性能样本。排除后，现有四轮冷窗口采样
Staged 和 Unstaged 分别至多剩 29 次。
前一轮 `sample-08` 的采集尾段也与命令启动有秒级重叠，
但其记录的首次完整正文采样发生在命令启动之前。
仍需补足独立样本，不能将包含重叠采样的汇总当成无干扰的 P95 基线。

## 高频窗口采样尝试

尝试使用独立 24k 行 Git 夹具和 Peekaboo 的本地 ScreenCaptureKit 路径，
但没有取得有效采样。第一次夹具目录不符合 `Bailey-UITest-` 启动保护前缀，
截图确认项目没有加载；修正目录后，应用 PID 存在，但窗口清单报告
`is_on_screen=false`、`pixels_only`，精确窗口 AX 不可用。
应用级激活回执虽为成功，后续窗口聚焦因找不到 AX 元素被拒绝，未派发窗口动作。
这不能证明产品启动缺陷，也不能作为首帧或采样帧率结果。

原始回执留在 `build/git-diff-p1-frameaudit-*.json`；已终止本次独立 Dev 进程
并删除确认属于本次实验的临时仓库。后续需先确认目标窗口确实位于当前图形会话、
前台并具备可访问的精确窗口，再测更高帧率与输入就绪；不能盲目复用旧 AX 快照。

## 独占桌面补测

用户再次同意独占桌面后，在唯一一次性 Git 仓库中使用隔离 Bailey Dev 和
准确窗口 ID 测试。首次尝试以后台子进程启动，命令结束时进程随之退出；
改为保留启动进程的会话后，窗口实际在屏幕上、前台且为 key window。
没有操作或重启正式 Bailey。首次启动日志及后续窗口清单分别为
`build/git-diff-p1-gui-precision-app.log`、
`build/git-diff-p1-gui-precision-windows-live.json`。

在真实 Changes 中选择未暂存行，720 像素上限的窗口捕获只达到 6.72 fps
并报告 `lowFps`；相对捕获动作开始，1,105 ms 的采样帧仍是骨架，
1,251 ms 的采样帧显示修改行和折叠，原始帧为
`build/git-diff-p1-gui-precision-unstaged/keep-0010.png` 和
`build/git-diff-p1-gui-precision-unstaged/keep-0011.png`。
这只是单次采样区间，动作启动时间不等于物理点击时间，不能当作精确首像素或 P95。
随后选择暂存行，360 像素上限的 ScreenCaptureKit 采样仍只有 5.10 fps；
AX 正文包含 Index 的修改而不包含工作区修改和输入标记，确认了来源，
但帧率依旧不足以核销高频测量。原始结果在
`build/git-diff-p1-gui-precision-unstaged/` 和
`build/git-diff-p1-gui-precision-staged/`。

未暂存编辑器挂载后进行一次真实键盘输入：`peekaboo type` 回执为失败且
声明事件可能已经派发，因此没有盲目重试；随后 AX 正文实际增加了唯一的 `Q`。
`⌘S` 后独立核对磁盘内容与原文相比仅增加该字节。相关回执和 AX 保存在
`build/git-diff-p1-gui-precision-type.json`、
`build/git-diff-p1-gui-precision-after-type.json` 和
`build/git-diff-p1-gui-precision-final-worktree.diff`。
这证明该次已挂载后的输入与保存，不证明最早可输入时点。

切至暂存再回到工作区后，尝试通过 Peekaboo 发送 `⌘Z`：命令回执报告成功，
但随后取得的 AX 只有 `application_partial`、无 snapshot ID；其中正文相对于
发送前尾部从 `Q` 变为 `Q z`，没有观察到预期的撤销。
前台窗口清单仍显示 Dev 为 key window，磁盘未保存这次变化。
该结果可能来自按键注入、焦点、输入法或应用处理，现有证据不足以归因，
不能将其判为产品缺陷或通过。回执及前后正文分别为
`build/git-diff-p1-gui-precision-undo.json`、
`build/git-diff-p1-gui-precision-before-undo.txt`、
`build/git-diff-p1-gui-precision-after-undo.txt`；P4-T2 应使用独立 XCTest
合成命令键并核对窗口第一响应者、正文、Undo／Redo 与磁盘，必要时追查注入层。
测试结束后只终止本次 Dev 进程并删除本次临时仓库。

本机 Peekaboo 为 4.6.0。其[上游问题 #797](https://github.com/openclaw/Peekaboo/issues/797)
记录旧版前台组合键可能残留修饰键，并说明 4.6.0 源码包含对应修正；
测试结束后读取 `NSEvent.modifierFlags` 为 0。
这不能反推出错瞬间的事件标志，也不能据此归因本次 `Q z` 现象。
