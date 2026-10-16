# P6 同机综合复测（2026-10-16）

## 范围与可比性

- 当前实施 HEAD：0644d347e747e258b345849d2f5cf8562dfceaeb，macOS 27.2、Apple M1 Pro、Xcode-beta、唯一 Bundle ID chiimagnus.kero。P1–P5 已采用的优化不增设第二个产品渲染器；官方 Tree-sitter 插件 P7 的 Gate 为 No-Go，继续使用原 Neon。
- 综合复测复用 P1、P3、P4 现存实验与 P5 原生 30 次 A/B，不将不同阶段/样本的毫秒数直接相加或宣称整体 FPS。P5 最终无 SSH 环境全量 315 tests／0 failures／3 skipped；Debug 与 Release BUILD SUCCEEDED，两包严格 codesign 验证。测试文件 p5-final-* 位于忽略目录 build/performance/diff。
- P5 本机 1,200 行 Swift 热数据读取至 Diff display→原生 TextKit 文本安装（同一 30 次样本）：串行完整中位 236.562ms，p95 242.726ms；并行完整中位 222.759ms，p95 237.101ms。额外 30 次捕获等价对照：约 75ms→约 54ms，两侧每条名称/范围相同。不将文本已安装等同合成像素或真实 GUI 可输入性。
- P4 Git 核心优先发布、有限 SSH 批次、树状态装饰 30 次 A/B、跨 backend 文件树副作用均见 evidence-p4.md；P3 输入、查询共享与解析后台优化见 evidence-p3.md。个别场景的显著优化不等于所有用户路径同时加速。

## 专用 Windows SSH

- 依据当前 docs/testing.md 明确授权的主机别名 windows，先以 SSH 命令验证可连接（BatchMode、ControlMaster=no、ControlPath=none）；未借用用户正在运行的 master。
- 单独临时 XCTest DiffSSHVerificationTests：使用 KERO_P4_TEST_SSH_HOST=windows TEST_RUNNER_KERO_P4_TEST_SSH_HOST=windows make test ONLY_TESTING=KeroTests/DiffSSHVerificationTests，结果 p6-real-ssh-diff.log：**1/1 passed（32.923s）**。用独立 socket /tmp/kp6-diff-随机.sock 和远端临时仓库 /tmp/kero-p6-diff-XXXXXX，真实运行 Git 初始化、commit、index 更新与工作区更新，分别核对 worktree、staged、revision、revisionWorktree、commit 的原始字节与颜色派生；实际路径含冒号、空格及 CRLF，坏 revision 正确返回错误而非缺失。验证后 fixture 与独立 socket 清理，未更改其它仓库或远端分支。
- 此针对性 XCTest 原始源码保留于被忽略的 build/performance/final/DiffSSHVerificationTests.swift，已从正式测试目标删除；它证明真实 SSH 的五种 Diff 后端读取，不是完整菜单/窗口 E2E。
- 已完成授权 Windows 全量 XCTest：`build/performance/final/p6-windows-full.log`，**315/315 passed、0 failures、0 skipped**（605.221s）。三个原本跳过的真实 SSH 用例分别通过：外部 Git 面板刷新 75.031s、固定／自动跟随项目的交互 Rebase 45.602s、Push/Delete／ZIP／历史恢复／Stash／Clean／Ignore 155.399s；每项只操作测试创建的仓库与独立 socket。另有上述独立五来源 Diff 用例 1/1 passed。

## 隔离 App、资源与安装

- 真实签名 Debug App 通过 `open -g -n ... --env KERO_UI_TEST_RUN_ID=<专用 UUID> --args --isolated-ui-test` 启动，唯一副实例恢复本轮本地临时 Git 仓库的 `P6Preview.swift`（1,200 行、四处改动）。独立测试快照仅写入 `chiimagnus.kero.isolated-ui-test.<UUID>`，不接触正式项目或用户保存会话；正式 `/Applications/Kero.app` 进程 PID 42850 始终运行，不曾重启。
- 已核对完整 App 的真实 CGWindow 截图 `p6-fixture-visible.png`、`p6-cold-screen-{1,5}.png`：原生 Diff 的折叠上下文、旧／新行号、语法颜色确实可见，非仅 `display` 字段不空。独立文件编辑器快照 `p6-editor-pixels.png` 可见第 1～46 行正文及行号；App 进程的 AX `Text Editor` value 含 24,181 字符并有正确起始内容。文件视图像素颜色本次未证明高亮稳定，专用 SyntaxHighlightingTests（15/15）及 FileTab 原生测试仍是该行为的独立自动回归证据。
- `p6-five-starts.py` 测 5 次独立隔离进程，在同一个合成仓库/快照中到达**真实 Diff 原生 Text Editor AX 内容**，`p6-five-isolated-starts.json`：中位 **1770.693ms**、最短 1761.415ms、最长 1795.291ms（n=5）。此时 RSS 约 239.4～240.6MiB。数值包括 `open` 与 Peekaboo 辅助功能观测/命令往返，系统文件缓存已热，不称独立冷磁盘启动或与 P1 不同路径的直接 A/B。
- 单次隔离 Diff 后台静置 30×1s 采样 `p6-background-30x1s.txt`：RSS 中位 270.16MiB、最大 270.25MiB、变化 +0.05MiB，CPU 中位 0.0%、最大 0.1%；仅代表该后台窗口样本，不能代替前台 Git 可见刷新或断言长时运行内存上限。`vmmap -summary` 证据 `p6-vmmap-diff.txt`，`leaks -quiet` 报 **0 leaks／0 bytes**（单次快照）；未把无泄漏快照当重复标签关闭的证明。
- 单独临时原生 XCTest `P6MemoryLifecycleTests` 真实构建 12 次 Git Diff／File 选项卡并通过 NSWindow/NSHostingView 挂载 TextKit 后关闭，使用弱引用核对 `FileTab / DiffTab / DiffNativeSurface` 余留 **0/0/0**，`p6-native-lifetime-green.log` **1/1 passed**。第一次实验在 nativeSurface 实际挂载窗口之前就断言其 `window` 非空，发生 4 次先后顺序误判；修正为等待窗口实际挂载后 Green，未修改产品代码。试验源码留在 `build/performance/final/P6MemoryLifecycleTests.swift`，已从正式 XCTest 目标移出。
- `xcrun xctrace record --template Allocations --attach <隔离 PID>` 返回 `Cannot find process for provided pid`，同时 `ps` 可见该进程；没有 Allocations trace，不能称 Instruments 的分配归因已通过。使用原生弱引用销毁、`vmmap` 与 `leaks` 作为已实际取得的有限证据。
- 保护现有桌面：Peekaboo 非前台 App/窗口 AX 读到准确按钮与文本，但其精确窗口快照因 `incomplete accessibility read` 不授予安全的后台点击身份，尝试 Split 按钮返回 `INTERACTION_FAILED` 且复查仍为 Unified。没有提升为共享前台鼠标/焦点输入；因此独立完整 App 菜单点击、真实 IME/撤销/保存、前台滚动与 GPU 合成/唤醒测量**未完成**，对应已通过的 NativeUI／WorkspaceUI／Git tests 不冒充独立 UI E2E。
- 安装核对：初次对照时两包一致；临时验收类退出正式 XCTest 目标后，`make test ONLY_TESTING=KeroTests/WorkspaceContentIdentityTests` **3/3 passed**，`make build` **BUILD SUCCEEDED**，Debug 重构建与既有安装出现整包差异（旧安装含多余的 `Contents/PlugIns`）。依 `docs/development.md` 已在 `/Applications` 同盘暂存完整新包、先验签再整包替换、再次严格验签与逐文件 `diff -qr` 核对，**最终安装与 Debug 产物完全一致**。安装事务带失败回滚，成功后清理旧包与所有临时备份，证据 `p6-install-receipt.txt`／`p6-install-debug.log`。唯一 Bundle ID `chiimagnus.kero`、签名团队 `RDQHYSDFFG` 未变，原 PID 42850 未退出或重启。用户实际手动重启后的正式恢复**未测**。
- 所有本轮创建的隔离 App 子进程均由完整命令行精确校验后停止，两个专用 UserDefaults suite 和唯一临时 Git 仓库已清理，实验日志／截图／临时源码留在被忽略的 `build/performance/final/`。

## P6-T2 文档、当前入口与收尾

- 对 `docs/README.md`、全部 `docs/features/*.md`、`development.md`、`testing.md`、`architecture.md`、`standards.md`、`ui.md`、`signing.md` 及本 Feature 的现行 `idea.md`、`plan-p5.md`、`plan-p6.md` 共 23 份相关文档检查 Markdown 链接：**170 个本地目标无失效文件**，受版本控制的 `docs/` 指向未纳入当前 HEAD 的 Feature 本地证据链接 **0**；当前文档已有 Git、Diff、Files、SSH 和 Editor 各自的功能职责，未新增重复规定。
- CodeGraph 再次核对共享文本读取/UTF-16 高亮、Git core/detail、工作区对象身份、`DiffLineSplitter`、固定 Git OID、原生 `DiffNativeSurface` 及 `TreeDisplayModel` 的真实消费者与所有者；无须在 P6 补做被其它阶段遗留的旧路径清理。用户可见接口、依赖和命令入口无本轮新变更，不新增 README、AGENTS 或无意义文档提交。
- `git diff HEAD --name-only -- kero docs Makefile Vendor` 无生产代码/现行文档工作区差异；独立临时 XCTest 文件均已从正式 `KeroTests` 目录删除，最终 WorkspaceContentIdentityTests 3/3，`make build` 成功，安装的完整 Debug 包逐字节目录核对并验签。临时实例、UserDefaults 与测试仓库清理，用户正式 PID 未动。
- 阶段实验源码、日志、截图只留在被忽略的 `build/performance/final/`，Feature 实验结论只归本地 `evidence-p6.md`；没有推送、发布，也没有修改其它 Feature 里同时出现的用户工作树改动。P6 只评估已实现的安全原生用户路径；前台 E2E、Instruments 授权和正式应用重启仍如实列作未测。
