# Audit P1 - editor-rendering-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/editor-rendering-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 定位文档高度与滚动条跳变的布局反馈
- [x] P1-T2 稳定文档几何与可见内容滚动锚点
- [x] P1-T3 支持小文件首开与十万行代码完整编辑
- [x] P1-T4 降低编辑热路径的整文成本和内存占用
- [ ] P1-T5 验收四档文件的稳定滚动和低资源编辑

## 任务到文件的映射

- **P1-T1 · `f0a0cc0`**：`EditorNavigationTests.swift`、`TextCoordinateIndexTests.swift`、`docs/testing.md`；修改前 STTextView 的真实几何 Red 和输入成本已记录在 `evidence-p1.md` 的 T1 段。旧控件后来由 T4 完整淘汰；不能用新控件的绿灯改写旧基线。
- **P1-T2 · `9f11b53`**：旧 `SourceTextEditor.swift`、`Vendor/STTextView` 的视口、行号及滚动，`EditorNavigationTests.swift`、`TextCoordinateIndexTests.swift` 与编辑器文档；该实现已由 T4 的 `647dc44` 删除，继承的行为契约由当前原生 TextKit 2 的导航／重挂载／行号／像素回归验证。必须在当前控件判断是否回归，不复活旧补丁。
- **P1-T3 · `171cd1b`、`237f91e`**：`FileViewerView.swift` 的 8 MiB 文本上限、`LocalWorkspaceBackend.swift` 与 `SSHWorkspaceBackend.swift` 的有界读写、`SSHHostWorkspaces.swift` 压缩，`FileTabTests.swift`、`RemoteCommandsTests.swift`、`SSHFileTreeLiveTests.swift`；真实调用链：文件标签 → 后端 read/write；远程后端 → SSH 进程 → `ProcessStdinWriter`。本轮 F-01 已真实 Red→Green 修复管道超时，单独补测后仍保留完整 T3 测试链路。
- **P1-T4 · `e97494b`、`d237f20`、`4945666`、`647dc44`**：`FileTab` 精确判脏与串行保存；`TextCoordinateIndex.swift`；`SourceTextEditor.swift` → `NativeCodeTextView.swift`／`NativeTextLineIndex.swift`，`SyntaxHighlightConfiguration.swift` 与 `Vendor/Neon`；Diff 走 `DiffNativeSurface.swift` → `DiffTextView.swift` → 同一原生 NSTextView/TextKit 2；Xcode 工程中的 `Vendor/STTextView` 和插件运行依赖已删除，保留由该源码改编部分所需授权文件及独立语法资源。回归入口：`EditorTextInputTests`、`SyntaxHighlightingTests`、`FileTabTests`、`DiffTabTests`、`TextCoordinateIndexTests`。
- **P1-T5 · `f687758`、`561a0f3`、`2358cdb`、`d433d47`、`6e9342b`、`12a15b6`、`230b29c`、`08cf95b`、`817b0dd`、`380d762`**：四档滚动/输入 24 组合 ×30 对；行号、Diff 背景、查找栏、最长行、窗口重挂载的像素／语义回归；5 轮 ×5 原生编辑器弱引用释放；双窗口原生 AX 保存；外部重载后过期 NSScrollView 文档退役。历史 `458/458` 的授权 Windows SSH XCTest、Debug/Release 验签与已安装 Release、五分屏真实渲染/静置采样、前台独立 Release ⌘S 真写盘均见 `evidence-p1.md`，不代表本次审计重新跑过，也不代表 Release 实际关闭五分屏后的 Allocations 已通过。**`todo.toml` 仍为 in_progress。**

## 审核原则与历史边界

只将 `todo.toml`、各任务 Git diff、现行源码的真实调用者和最新可复核的运行结果作为判断依据；历史 `audit*.md` 未作为结论来源。原 plan 中对 STTextView 的几何修复被后续用户决定的原生迁移替代，属于需求演进，不是未安装的双轨代码。公开 C parser 生成源码按固定包来源/编译/版权确认，不逐行人为评审上百万行生成代码。避免影响并行 Bailey 工作和用户正式进程，所有本次测试仅使用隔离 DerivedData／测试目标；用户真实工作区、签名身份及 SSH master 不清理。

## 发现项

## 发现 F-03

- 任务：`P1-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/WorkspaceDockView.swift:453-474,543-596`（旧 Tab 强引用）；`Bailey/Workspace/Project.swift:725-736,915-936` 为触发入口
- 摘要：`独立 Release 关闭全部五个文件标签后，原生编辑器和 FileTab 对象持续存活`
- 风险：`实际 Close Files 两轮后 AXTextArea=0、文件标签全部消失，但静置多次 heap 检查仍有 6 个 FileTab、FocusReportingTextView、SyntaxHighlightCoordinator 和 NSTextViewportLayoutController；可能随反复开关累积缓存和原始文档`
- 预期修复：`沿真实 Project.closeFiles→closeBatch→removeTabWithContent→Dock/SourceTextEditor 卸载所有权链确定具体强引用，修复单一 owner 的生命周期，不用每帧清空视口或定时 GC 补丁`
- 验证：`隔离 Release 五标签打开→Close Files→重开→再次关闭，使用真实 AX 数、heap 类实例与 vmmap/Allocations 对照；追加 WorkspaceDockView/Project 真实关闭生命周期 XCTest Red→Green、所有受影响回归与 Debug/Release 验签`
- 解决证据：`cd039a1: 实测真实 Release 五个 10k 行文档右键 Close Files，AXTextArea 5→0；4秒后 heap FileTab/FocusReportingTextView/SyntaxHighlightCoordinator 5→0，vmmap physical footprint 273.2MiB→99.7MiB；独立 PaneRetentionTests 先 Red（真实旧标签/项目强引用/旧 documentView），再 Green 15/15，含 Project.closeFiles 与 TerminalManager.close(Project)；最终提交后的 Windows SSH 全量 make test 462/462、0 failures、exit0，813.962s，日志 build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log；最终 Release make build:release 和 codesign --verify --deep --strict exit0，已通过相同签名整包安装 /Applications/Bailey.app，旧正式 PID86913 未退出。五轮连续 GUI 因用户 Space 切换导致精确窗口失效未测完，仍属于独立 T5 Gate 未满足条件，不宣称连续内存曲线全部通过。`


## 发现 F-02

- 任务：`P1-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/NativeUI/Editor/EditorNavigationTests.swift:18-44,650-692; Bailey/Editor/SyntaxHighlightConfiguration.swift:358-369`
- 摘要：`四档输入延迟回归使用未安装真实语法高亮的裸 NSTextView；100k 实际文件输入热路径缺基准`
- 风险：`真实 Swift 文件每次编辑还会进入 SyntaxHighlightCoordinator.didChangeContent 与 TreeSitterClient；裸视图 16/32 ms 预算通过不足以证明用户实际加载语法资源后的输入体验`
- 预期修复：`补充在真实原生 TextKit 2 + Neon/TreeSitter 安装并完成初次解析时的 100k 行文首／中／末输入延迟和源字节／语法树一致性回归，不复制第二套编辑器`
- 验证：`附带真实插件的量化输入日志、median/p95/worst 与完整修复后 XCTest；性能预算不满足即保持 Gate No-Go`
- 解决证据：`补测原 T1 混合长度真 FileTab + SourceTextEditor + Neon/Tree-sitter: make test ONLY_TESTING=BaileyTests/SyntaxHighlightingTests/testFourSizeRealFileTabHighlightedInputAndParserBudget (退出码0,1/1)。382/1000/10000/100000 行 × 折行两态 × 文首中末 ×30 次共720次；10万行最慢 median 1.044ms / p95 1.452ms,均低于16/32ms；每组原生正文与 FileTab 字节相同，解析树全文长度正确，撤回编辑后 isDirty=false。日志 build/performance/editor-rendering/audit-p1-real-file-highlight.log。完整版 make test 460/460 退出码0，早于补测增加，独立补测另计。`


## 发现 F-01

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/LocalWorkspaceBackend.swift:288-312`
- 摘要：`本机进程输出管道超时依赖后代关闭描述符，可能无法按 deadline 返回`
- 风险：`后代持有 stdout/stderr 而非 stdin 时，reader DispatchGroup 等待 EOF；超时后无界 readers.wait 并可能对已退出父进程 terminate，导致工作区命令卡死或原生异常`
- 预期修复：`在真实 runSync 所有者以非阻塞 poll 同时排空两条输出管道，使用单调时钟统一约束读取与父进程退出；超时仅终止本次启动的父进程，不等待后代 EOF`
- 验证：`RemoteCommandsTests 真实 Python fork/setsid 后代分别继承 stdout 与 stderr 的 Red→Green，并跑受影响回归、全部 make test、Debug/Release 验签`
- 解决证据：`真实独立 Python fork/setsid 子进程分别继承 stdout/stderr、父进程正常等待或立即退出，deadline=0.2s。原实现 Red 两失败: 1.612/1.640s（audit-p1-pipe-red-confirmed.log, make test exit2）；改 runSync 单调截止时间+双路 nonblocking poll，超时仅按精确 PID 结束所启动进程且关闭父侧 FD。Green 四种输入/父子时序的单次返回限0.85s，双路各256KiB 完整读取/无丢字节，RemoteCommandsTests 19/19（audit-p1-process-final.log exit0）；完整含 Windows SSH XCTest 460/460（audit-p1-full-windows.log exit0）、make build 和 make build:release + codesign --verify --deep --strict 全部退出码0（audit-p1-debug-sign.log/audit-p1-release-sign.log）。`


## 修复日志

- **F-03，T5，闭环验证中：** 本机旧 Release 真实显示五个 10k 行编辑器，精确右键标签执行 `Close Files`，0 个 `AXTextArea`；在相同 PID 重新打开五个文件、再次关闭后，`heap` 连续三次间隔采样仍有 **6 个 `FileTab`、`FocusReportingTextView`、`SyntaxHighlightCoordinator`、`NSTextViewportLayoutController`**。旧进程关闭后物理足迹虽从 287 MiB 降至 168 MiB，但存活对象数量没有随关闭减少。`leaks --traceTree=0x796f5bf600 43351` 证实保留链为 `PaneTab → SwiftUI 闭包 → HoverResponder → ContextMenuResponder / SwiftUI 视图缓存`，不是 TreeSitter parser 本身。`PaneRetentionTests.testClosingMountedFiveFileTabsReleasesTheirNativeDocuments` 在真正 `WorkspaceDockView/Project.closeFiles()` 中复现 Red（exit2，10.494s 后五份弱引用不释放）；UI 层的 tab close/context menu 回调改为按当前 UUID 解析 `project.tabs`，浏览器/文件菜单也只捕获 path/address 值，不继续强捕获已关闭的 Tab。原测试 Green（exit0，0.758s），日志 `build/performance/editor-rendering/audit-p1-release-memory/f03-red.log` 和 `f03-green-attempt1.log`；本轮全量 Windows 回归和改动后的独立 Release heap／Allocations 仍待终局核销，不据此提前标 Resolved。

- **F-03 第二层实证，闭环验证中：** 第一次修复后的独立 Release PID87374 在真实 `Close Files` 后 **`FileTab=0`**，但四秒后 `FocusReportingTextView=1`、`SyntaxHighlightCoordinator=1`、布局控制器仍 5 个（随后收敛到 1）；`leaks --traceTree` 指向窗口旧 First Responder／AppKit 焦点和暂存布局视图，而非标签闭包。增强原测试强持有 5 个旧 `NSScrollView` 并将编辑器设为窗口 First Responder，明确断言真正关闭后 `documentView=nil`，再次 Red（exit2，旧滚动视图仍持有原生正文且弱编辑器不能释放；`f03-retired-red.log`）。根因修复在 `FileTab.retireNativeEditor()` 统一处理已存在的 `Coordinator.retireObsoleteDocument()`；`Project.remove(tabID:)` 仅在语义关闭时调用，磁盘内容真正替换也复用同一方法，**普通 Dock 视图重挂载不退役**。`PaneRetentionTests` 完整 15/15、exit0（`f03-retired-green.log`）；本轮最终完整 Windows suite 和再次更新后的 Release 内存验证仍需核销，未提前关闭 F-03。

- **F-03 第三层，提交 `cd039a1`，最终 Release／项目关闭补验：** `Project.terminateAll()` 除停用终端外在真实项目或窗口关闭时统一退役所有文件原生文档；新增真实五 Dock 分屏关闭整个 Project 的 XCTest 先 Red（`f03-project-close-red.log`），后 `PaneRetentionTests` 15/15 Green（`f03-project-close-green.log`），不影响普通 Dock 重新挂载与未保存保护。最终源码独立 Release `make build:release`／严格验签 exit0（`audit-p1-bounded-release/release-final-build.log`）。用同一个 Release 窗口五个 10k 行 Swift 文件，精确后台右键 `Close Files`，Accessibility `AXTextArea` 从 5 降为 0，4 秒后 `heap` 显示 `FileTab`、`FocusReportingTextView`、`SyntaxHighlightCoordinator` 均 **0**，物理足迹 **273.2 MiB→99.7 MiB**（`audit-p1-bounded-release/heap-*.txt`、`vmmap-*.txt`），仅 AppKit 视口布局缓存尚存。重复打开第 1 个文件成功，但后续桌面 Space 变动使精确测试窗口不再可操作，五轮脚本在首次循环中止，**没有五轮通过结论**（`e2e-interruption.json`）；不强抢用户前台。另一轮含 Windows SSH 的完整 XCTest **462/462** 通过（`f03-final-full-windows.log`），但它在 `Project.terminateAll()` 修改前启动；后续独立 15/15 + 最终 Release 验证覆盖新增路径；修复代码已按 6 个指定文件原子提交 `cd039a1`（未推送）。随后使用已提交的同一源码重新执行完整授权 Windows SSH XCTest，462/462、0 failures、exit0、813.962s；证据 `build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log`。
- **F-01，T3，提交 `490beb9`：** 用真实 fork/setsid 子进程继承 stdout/stderr，构造父进程存活/先退出两种时序。旧实现 `readDataToEndOfFile` 与 `DispatchGroup.wait()` 无界等待后代 EOF；最小 Red 单轮 0.2s deadline 实际 1.61～1.64s。`LocalWorkspaceBackend.runSync` 改为同线程非阻塞 `poll` 并发排空两条管道，单调时钟约束退出与数据读取、SIGTERM/SIGKILL 只作用于本次启动的直接 PID；移除不再使用的 `RunPipeData` 和独立阻塞 reader 线程。Green 对齐 4 种继承管道/父退出时序，追加两路各 256 KiB 完整内容断言；既有远端写入/二进制/EOF/断线/父先退出回归仍通过。长期契约写入 `docs/features/ssh.md`。
- **F-02，T5，提交 `0ccf8ba`：** 恢复 T1 的混合长度／空行／Unicode／长行基准样本，使用真实磁盘 Swift 文件 → `FileTab` → `SourceTextEditor` → `NativeCodeTextView + TextKit 2`，实际安装 Neon／Tree-sitter 而非裸 NSTextView；补充四档、折行两态、三位置各 30 次的可持续回归。每组核对原文/原生 FileTab 完全一致、恢复干净及解析树长度，`docs/testing.md` 将真实高亮性能与裸控件明确分开。没有添加替代编辑器、快照状态机、生产性能开关或额外兜底。
- **清理结果：** T4 的 STTextView runtime、原插件及旧桥接调用在生产项目已移除，`git ls-files Vendor/STTextView Vendor/STTextView-Plugin-Neon` 无文件；Neon 本身仍是已实际调用的增量高亮实现，BaileyGrammars 保留合法语法来源；不能为表面清理删除正在使用的授权/原生边界保护。审计没有更改现有文件编辑器或 Diff 的 UI 布局／颜色逻辑。

## 验证日志

- **当前环境：** macOS 27.2／arm64、Xcode 27.2 (27B5038j)；原分支 `backup/local-main-20261019` 基线 `380d762`，独立构建目录 `build/DerivedData-native-parity`、既有 `build/SourcePackages`，不接管其他 Bailey 进程、项目或 SSH master。
- **T1/T2：** 旧 ST 路径经原生 T4 替代，不复活废弃的旧几何补丁；现有 `EditorNavigationTests`、行号像素/首字形、滚动条高度与 knob、查找栏、Diff 颜色、窗口重挂载/恢复均进入本次完整 XCTest，100k 17 次远距双向访问高度与 knob 波动均为零，真实控件保持文本和选择语义。
- **T3：** 先 Red：`audit-p1-pipe-red-confirmed.log` 命令退出 2，2 项预期失败（0.2s 超时实际 1.612/1.640s）；修复后 `make test ONLY_TESTING=BaileyTests/RemoteCommandsTests` 完整 exit0、19/19，`audit-p1-process-final.log`。stdout/stderr 各 256KiB 完整、父直接退出/先等待/后代保留管道的四种组合、stdin 关闭/继承、SSH 后端二进制及超限等已核对。
- **T4/T5：** `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-native-parity SOURCE_PACKAGES=build/SourcePackages` → 完整 exit0，**460/460、0 failures**，约 771.86 秒；`audit-p1-full-windows.log`。其中真实 Windows 文件树与 8MiB 双向传输已过，用户文件未参与。新增真实高亮性能 `make test ONLY_TESTING=BaileyTests/SyntaxHighlightingTests/testFourSizeRealFileTabHighlightedInputAndParserBudget` → exit0，1/1，24 组 ×30 = 720 次，`audit-p1-real-file-highlight.log`；100k 最慢 median **1.044ms**／p95 **1.452ms**／worst **1.617ms**，低于原 16／32ms Gate。输入测量不冒称为系统端到端帧率，单一测试成功不冒称旧 460 项曾包含此新增用例。

- **最终提交版实测：** 在提交 `cd039a1` 后重新运行 `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test DERIVED_DATA=build/DerivedData-native-parity SOURCE_PACKAGES=build/SourcePackages`，**462/462、0 failures、exit0**，耗时 813.962s（`build/performance/editor-rendering/audit-p1-bounded-release/f03-committed-full-windows.log`）。覆盖 Windows SSH 文件树/8MiB 双向传输/断线恢复、真实 Dock 五编辑器关闭与整个 Project 关闭、原生 UI 颜色/几何和文本保存；远端主机不支持创建 symlink 的条件仍独立记录，未冒称通过。
- **优化 Release 生命周期 XCTest 补验：** 原生 Release `make test CONFIGURATION=Release` 首次未通过编译，因为优化模块没有 `-enable-testing`，`@testable import Bailey` 无法解析；这不是产品 Release 构建错误。随后仅在独立 XCTest 构建命令中传入 `ENABLE_TESTABILITY=YES`，完整 `PaneRetentionTests` **15/15、0 failures、`TEST SUCCEEDED`**，包括五轮各五个原生编辑器输入与释放、真实 Dock 关闭文件及关闭整个 Project 的回归；日志 `build/performance/editor-rendering/audit-p1-bounded-release/f03-release-xctest-testability.log`。正式 Release 配置未改变，该测试不等同于独立 App 五轮 GUI 内存趋势验收。
- **独立 Release 五轮真实文件标签开关：** 在同一个隔离签名 Release 进程 PID16723、同一窗口中，首轮同时挂载 5 个 10k 行原生文本视图；执行真实标签右键 `Close Files`，确认 0 个文件标签／`AXTextArea`。随后连续四轮通过 Files 面板重开 5 个文件标签再关闭：Dock 自动收拢，后四轮各只有 1 个同时挂载的编辑器，不能冒称 5 分屏循环。五轮结束时 `FileTab`／`SyntaxHighlightCoordinator` 始终为 0；第 2～5 轮 `NSTextViewportLayoutController=5`、`NSTextParagraph=745` 均不增长，物理足迹 85.7／90.0／90.1／83.0 MiB。前台保留 1 个 AppKit 文本视图，在应用失焦后与全部布局缓存一起回落到 0，失焦后物理足迹 86.5 MiB。每份测试文件 SHA-256 保持不变，测试进程及独立 UUID 设置域已清理。详细原始 `heap`、窗口快照与循环报告见 `evidence-p1.md` 最新小节和 `build/performance/editor-rendering/audit-p1-bounded-release/gui-five-cycles-d3a6e550-bf0e-4055-b575-7592c4a9d13d/`。未额外改动生产源码。
- **正式 App 整包安装：** 最终 Release 构建 `BUILD SUCCEEDED`，源包、同磁盘暂存包和 `/Applications/Bailey.app` 均通过 `codesign --verify --deep --strict`，安装后 executable SHA-256 与源包完全相同：`1da5c6d785e139dfa0a9339a886c1c0fb40116a95c90d6f03d642e5c136aa840`。整包替换、无残留安装暂存或旧包备份；原正式 PID `86913` 未退出、启动或重启，新版需用户自行重启后生效。

- **构建验签：** `make build` 与 `make build:release`（同独立 DerivedData）各退出 0，均 `BUILD SUCCEEDED`，后置 `codesign --verify --deep --strict` 成功；日志 `audit-p1-debug-sign.log`、`audit-p1-release-sign.log`。Release 仍有 Tree-sitter C/C++ 生成/第三方源码固有编译警告，未篡改 vendor 或误称无警告；该早期验证时尚未安装，最终安装证据见上条。
- **历史真实 App 证据的使用边界：** 原 `evidence-p1.md` 已有独立 Release 五个 10k 行分屏实际截图、120s/90s 静置 RSS/CPU 采样，以及前台真实 ⌘S 写盘/重启仍匹配字节的后续 E2E；此为之前运行的证据，**本次后续补做了上述独立 Release 关闭与内存验收，已完成同 PID 的五轮真实文件标签开关；但后四轮仅一个编辑器同时挂载，全程 FPS 仍未测**。本轮对 UI 生产绘制源码无修改，并复跑已有真实 AppKit/WorkspaceUI 文本、颜色、行号、Diff、找回、撤销及双窗口保存回归；不能据此宣称覆盖所有实体屏幕组合。
- **未测及 Gate 影响（逐项）：** (1) 独立 Release 首轮五分屏实际关闭、后续四轮五文件标签重开／关闭及每轮 `heap`／物理内存对照已通过，但关闭后 Dock 自动收拢，尚缺五个分屏同时挂载、编辑、反复关闭的完整 GUI Allocations 曲线；`leaks` 基线和本次五标签结果不能替代该组合，仍阻塞 T5 长周期资源 Gate。(2) 无可用于测试的 **macOS 15.6／CI26** 设备/系统；本轮只有 macOS 27.2，历史项目最低系统组合未经实测，补验需对应设备/CI，保留兼容性风险。(3) 当前无隔离可验证的**真实手指触控板、不同物理刷新率/显示缩放与 VoiceOver 完整交互**；AppKit 窗口像素、AX 与测试鼠标事件不能冒充实体条件；补验需对应硬件和辅助功能交互。(4) Windows SSH 主机返回 `P4_LIVE_SYMLINK_UNAVAILABLE status=1`，说明其权限环境不能创建 symlink；已验非符号链接的重命名/二进制/读写，不把专属符号链接能力写成通过；补验需具备 symlink 权限的授权 Windows 环境。(5) 未重跑独立 Release 的完整人工高帧率滚动 FPS，Debug 插入/布局回归与既有 Release 截图不等于物理显示帧时间；补验需独立显示采样。前三项及 FPS 限制尚使阶段无法无保留放行。
- **文档核对：** `docs/README.md` 索引、`docs/features/editor.md`/`diff.md`/`ssh.md`、`docs/testing.md` 与当前实际入口一致；保留前期历史 No-Go STTextView 原型作为取证时间线，不重新加入双轨兼容，`audit*.md` 不作为审查结论。审计文档后由并行流程独立提交 `0c9b1a2`；本轮最终证据追加到同一文档，未擅自推送。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（整个 P1 的无保留完成）**；**F-01、F-02、F-03 均 Resolved**（旧强引用链已实证修复且最终提交版完整 XCTest 通过；T5 五分屏同时挂载编辑器的五轮 GUI／帧时长验收尚未完成）。
- 理由：本机及授权 Windows 回归、构建验签、真实高亮性能和同 PID 五轮文件标签关闭均通过，未见对象累积；但五分屏同时挂载／编辑的连续 GUI Allocations、真实帧时长及部分实体环境尚无证据，`todo.toml` 继续保持 `in_progress`。

## 最终状态与剩余风险

- 当前状态：发现项 **3/3 Resolved**；正式 App **已整包安装、未由审计重启**（安装时旧 PID 86913 仍运行，目前该进程已不在进程表中）；阶段 **P1-T1～T4 完成，P1-T5 in_progress**。
- 剩余风险：F-03 的旧强引用已按 Red→Green 修复；真实 Release 五轮文件标签开关没有对象累计，前台暂存的 1 个原生视图在应用失焦后归零。仍缺五分屏持续同时挂载／编辑的 GUI 分配趋势、Release 实际帧时长，以及 macOS 15.6／CI 26、物理触控板、不同刷新率、VoiceOver 与 Windows symlink 权限环境。保留 T5 Gate，不冒称全部验证。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

