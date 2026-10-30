# P5 验收证据

## PR #69 合并后的主线与增量复测

- GitHub 主分支 `bc7ffab6`（PR #69）经 Windows SSH 独立拉取并生成小型 Git bundle，
  本机验证 bundle 先决提交 `afd03f1c` 和完整新 SHA 后，快进 `main`、`origin/main`。
  `crh1` 的五个 P5 提交已 Rebase 到此基线，四个未提交文件先备份后完整恢复；
  冲突处同时保留 PR #69 原有的两条提交离屏导航回归与本地新测试。
  远端仓库未被推送，未新建 PR，正式 Bailey 进程及安装包未改变。
- 新增 `GitGraphUITests.testGraphKeyboardNavigationKeepsFortyHistoricalFilesVisible`：
  同一个真实 Git 提交下逐行导航 40 个历史文件；每行验证当前视口实际可点击，
  Git HEAD、status、磁盘字节不变。**最新主线 GUI 1/1 通过、70.783 秒，退出码 0**；
  实现提交 `be3da639`。与 PR #69 的跨提交方向键回归互补。
- `GitGraphGeometryUITests.testOverflowBranchWorktreeActionRebindsAfterExternalRefresh`：
  旧 GUI 在外部 Tag 刷新后重用已经失效的四层 NSMenu AX 对象，真实点击稳定失败；
  新用例先验证旧操作没有副作用，若原生菜单因刷新关闭则按当前 UI 重新展开同一 Worktree，
  核对真实文件、HEAD、Tag 与 Worktree 列表。
  **最新主线 GUI 1/1 通过、45.870 秒，退出码 0**；
  日志确实记录了 Escape 后重新展开至 `a904/Bailey`。
  实现提交 `e42e6fe0`；原生菜单刷新时可自行收起，未声称持续保持展开。
- 基于 PR #69 的带真实 Windows SSH 完整宿主：
  `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test`
  **723/723 通过，0 失败、0 跳过，退出码 0**。
  实测含 Windows SSH 的 Rebase、外部刷新、Ref/ZIP/Stash/Reset/Worktree、
  远端 8 MiB 保存、断线恢复与 FileSystemWatcher，未借用用户 SSH master。
  `NativeSyntaxHighlightingTests.testClosingEmbeddedEditorReleasesPendingHighlightRequests`
  此次通过（0.596 秒）。原始偶发超时尚无稳定复现根因，不宣称已经彻底修复。
  测试报告：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.30_15-51-56-+0800.xcresult`。
- 最新主线联合 UI（同一隔离 Dev runner，四条连续）：
  `testFilesGitGraphDockAndPaletteKeepOneRealTargetThroughSwitches`（39.443 秒）、
  PR #69 的 `testGraphArrowNavigationKeepsRealCommitVisible`（22.974 秒）与
  `testGraphArrowNavigationWithGitChangesKeepsRealCommitVisible`（22.968 秒）、
  `testThirtyRealDockSwitchesKeepExplorerSelectionAndMeasureEndToEndResponse`（112.093 秒）。
  **4/4 通过，0 失败，退出码 0**，Dock n=30：中位 3.373 秒、p95 3.558 秒、最大 3.685 秒，
  测得的是含 XCUITest 空闲/AX 开销的自动化往返，不是独立 App 输入延迟。
  报告：`build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.30_16-09-14-+0800.xcresult`。
  整套约 190 项 GUI 用例尚未在此新基线上一次性重新执行，不记为整套通过。
- `make build:dev` **退出码 0（BUILD SUCCEEDED）**；
  `codesign --verify --deep --strict` 验证完整 `Bailey Dev.app` 签名与 Designated Requirement，
  bundle ID 确认为 `chiimagnus.bailey.dev`，与正式 `chiimagnus.bailey` 隔离。
  未安装、退出或重启正式 Bailey，也未创建 PR。
- P5 尚未整体核销：尤其最低 macOS 15.6、VoiceOver／高对比／真实 IME、
  10k/100k Files 真实可见列表、长期 Instruments 资源基线，以及最新 SHA 的整套 GUI 全量复测；
  双窗 Windows SSH 的 Dev 专属 master 断开与恢复已经独立实测通过，
  不得冒充整机网络失联。

基线：2026-10-30；macOS 27.2 / Xcode 27.2（27B5038j）；
M1 Pro / 32 GiB / 内建 Retina 3024×1964（逻辑视口 1800×1169）。
只启动隔离 `chiimagnus.bailey.dev`，未重启或替换正式 Bailey。
测试使用临时本地仓库、获授权 `windows` 的专属远端临时目录及 SSH control socket。

## P5-T1：真实跨组件因果与数据

- 2026-10-30 21:20 `009af523` 修复后 Git/Windows UI 全类联合复测：
  `GitChangesUITests` **24/24**、`GitDialogUITests` **22/22**、
  `GitHistoryUITests` **5/5**、`WorkspaceWindowsUITests` **8/8**，
  共 **59/59 通过，0 失败，退出码 0**。
  报告详见 `/tmp/bailey-p5-focus-ui-groupA-20261030.log`；
  无残留 Xcode UI 测试进程，正式 Bailey 保持运行。
  全仓库 UI 定义约 191 项，本轮未宣称 191/191，
  最新修复后的剩余类仍需增量核销；不重复启动已通过的整类作为进度。

- 2026-10-30 19:41 最新基线 Git 三类 GUI 全量联跑：
  `GitChangesUITests` 23/24，`GitGraphGeometryUITests` 14/14，
  `GitGraphUITests` 31/31，合计 **68/69 通过、1 失败，命令退出 65**。
  唯一失败位于跨组件测试的 Git Graph 历史文件 → Command Palette → Escape，
  `GitChangesUITests.swift:273` 断言面板未关闭。
  同一个 E2E 独立复跑 1/1 通过（39.276 秒），故为间歇性而非稳定失败。
  源码核对发现 `GitPanel.focusGitChanges()` 未像 Files/Projects/Dock 一样
  在命令面板可见时避免原生焦点争抢；现在保留 Git 树注册和游标更新，
  但在 Command Palette 或原生 Sheet 显示时禁止它抢第一响应者。
  修复后跨组件 Escape、Git Changes 恢复、双窗口键盘焦点 **3/3 GUI 通过**
  （131.362 秒，退出码 0），报告：
  `build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.30_20-28-16-+0800.xcresult`。
  同一实现的完整宿主（带真实 Windows SSH）**723/723 通过，0 失败、0 跳过，退出码 0**，
  报告：`build/DerivedData-Dev/Logs/Test/Test-Bailey-2026.10.30_20-30-46-+0800.xcresult`。
  Git 三类在修复后的完整联跑仍须补验，不能把旧版 68/69 当作全绿。

- 2026-10-30 19:38 新主线真实双窗口 Windows SSH 专项：
  `WorkspaceFilesUITests.testAuthorizedWindowsSSHTwoWindowsKeepTargetsAfterIsolatedMasterExit`
  配置 `BAILEY_P4_TEST_SSH_HOST=windows` 与 `BAILEY_P2_EXTERNAL_DISCONNECT=1`；
  控制器验证当前 `chiimagnus.bailey.dev` 的 PID 和仅属于它的
  `/tmp/bailey-<uid>-<Dev PID>-%C.sock`，再执行 `ssh -S ... -O exit windows`。
  远端 A/B 多选及复制相对路径、另一个本机窗口复制精确绝对路径、
  实际 SSH master 退出和自动恢复、Windows 文件新增/刷新、原选区、
  本机同名文件字节和远端真实 Git 工作区均验证。
  **1/1 GUI 通过，134.012 秒，退出码 0**。
  记录：`build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.10.30_19-38-29-+0800.xcresult`。
  仅核销 Dev 专属 SSH master 退出/恢复，不冒充切断 Windows 主机所有网络。

- `BaileyUITests/Git/GitChangesUITests.swift`：
  `testFilesGitGraphDockAndPaletteKeepOneRealTargetThroughSwitches`。
  Files 多岛 Selection → 集合外右键取消 → Editor → Git Diff →
  Graph 历史文件真实提交字节 → Palette 取消 → Dock/Files/Git Auto Reveal →
  Stage/Unstage 实际 index → HEAD、工作区字节、不相关文件无变化。
  首版 1/1 UI 通过，增强版 2026-10-30 12:51 完整 E2E **通过**（39.684 秒，退出码 0）。
- `BaileyTests/Workspace/ProjectFileIndexTests.swift` 与
  `BaileyUITests/Files/WorkspaceFilesUITests.swift`：
  移除旧 `BAILEY_P3_TEST_SSH_HOST`，统一现行 `BAILEY_P4_TEST_SSH_HOST`。
  真实 Windows SSH 的索引/重连/UTF-8/字节宿主 **通过**（32.438 秒），
  命令面板搜索远端普通文件并打开原生编辑器的 GUI **通过**（84.532 秒）。
- PR #69 合并前的历史全量宿主记录（带真实 Windows SSH）：
  退出码 0；**723 项中 722 通过、1 跳过、0 失败**，
  跳过的旧 P3 环境参数已修正并在上一条独立实测 **1/1 通过**。
  包含 SSH Rebase、外部 Git 刷新、Stash/Worktree、断线恢复、
  Files FSEvents/FileSystemWatcher、550 次文件事件风暴、8 MiB 保存和逐项数据保护。
- 此前全集唯一失败 `NativeSyntaxHighlightingTests.testClosingEmbeddedEditorReleasesPendingHighlightRequests`
  在本轮完整宿主实测 **通过**（0.582 秒），独立复测 **通过**（0.721 秒）。
  未稳定复现原始 5 秒资源释放超时，不臆测生产缺陷或改动无关代码。

## P5-T2：外观/容量/性能

- 2026-10-30 本轮 Git Graph/SharedTree/Dock 78 项 UI 联跑发现一条真实红灯：
  `GitGraphUITests.testLongChineseGraphTitleScrollsButShortTitleAndGraphRailsStayFixed`
  在水平滚动后截图字节相同（`GitGraphUITests.swift:1047`）。
  旧夹具将同一中文片段重复 48 次；12.5 pt 实测该片段宽约 156.09 pt，
  滚动 460 pt 约为 2.95 个重复周期，因而截图相等无法可靠证明未滚动。
  已将夹具调整为每段带唯一序号，并先稳定滚轮所在行的悬停状态；
  **修正后真实 Bailey Dev GUI 1/1 通过，退出码 0**，保留前后位图不等、
  短标题不回弹、图谱轨道不动以及 Git HEAD/status 不变全部原始断言。
  Git 图谱/共享树/Dock 78 项整组原版 77/78 通过，唯一红灯由此独立复验变绿；
  修正提交 `edc31129`，日志：`/tmp/bailey-p5-unique-graph-title-20261030.log`。
- 新增原生 Files 宿主两项 **2/2 通过，0 失败，退出码 0**（`feed7e5d`）：
  真实 1k/10k/100k APFS 文件、FileTreeModel、NSHostingView、NSScrollView
  及底部滚动，核对行数、文档长度、选区、无意外标签与真实视口，
  并采用 macOS 高对比 Aqua / DarkAqua 原生 Appearance 截图比较选中填充和 Focus 边框。
  100k 测得创建 13.426s、模型同步 6.581s、原生挂载 0.154s、焦点到底部 0.921s；
  当前宿主进程峰值 RSS 338.9 MiB；每一级实际 NSView 后代 197 个。
  1k/10k 原生底部滚动分别 0.029s/0.107s；指标是该设备本轮单次基线，
  `ru_maxrss` 为整个测试进程累计峰值，并非独立分摊到树的内存。
  测试退出码 0，日志：`/tmp/bailey-p5-native-scale-contrast-20261030.log`。
  这些原生宿主结果不冒充真实 VoiceOver 朗读。

P5 行为对齐判定只对可观察契约负责，不宣称复制上游 CSS 或全平台像素：

| 范围 | 判定 | 验收依据 |
| --- | --- | --- |
| Files／Changes 的 Selection、Focus、Context Target 分离 | 同义 | 原生行位图、AX 与真实菜单取消、选区和文件字节 |
| Git Graph 历史行、图谱轨道与 Ref/Tag/Worktree | 等价（行为） | 图谱与原生菜单完整 UI 类、真实 Git HEAD/ref |
| Dock 多选、批量移动、关闭与活动窗口焦点 | 等价（行为） | Dock 实际拖动、关闭、多窗 E2E、宿主数据边界 |
| Git Graph 的外部刷新原生菜单生命周期 | 明确不复刻 | SwiftUI／NSMenu 失效后重建当前菜单，不复制扩展 DOM/CSS |
| 整体外观、字体、Ghostty 主题与原生编辑区 | 明确不复刻 | Bailey 原生设计与 `docs/ui.md` 约束，不做 VS Code 逐像素镜像 |
| macOS 15.6、实体 VoiceOver 朗读及第二显示器 | 未验收 | 当前仅 macOS 27.2 单内屏；原生 AX/高对比宿主为替代证据 |
| 中文／日文真实 IME 候选与长时间 Instruments | 未验收 | 标记文本与短时性能已验，真实候选和长期资源仍需专门环境 |

- `WorkspaceDockUITests.testThirtyRealDockSwitchesKeepExplorerSelectionAndMeasureEndToEndResponse`：
  真实 Bailey Dev 30 次 A/B 标签切换、每次断言 Files 唯一 Selection、最终原始磁盘字节；
  **通过**（112.516 秒）。
  本机 XCUITest 点击＋空闲等待＋AX 查询的总往返
  **n=30，中位 3.378s、p95 3.574s、max 3.588s**；
  不是直接测得的 App 内部输入到像素延迟，不可用来宣称 UI 卡顿或提速。
- 完整宿主通过的代表性容量场景：
  原生 TextKit 100,000 行编辑/保存/释放、
  Git 图谱千级提交与高轨道布局、
  Dock 32 项批量 Move、Files 1,024+ Unicode 行、复杂 SSH 刷新和异常中断。
  宿主绿色不替代 100k 行原生 Files GUI 性能。
- 首次完整 `make test:ui` 已运行到 Editor 三项全绿、Git Changes 24 项中的 23 项通过、1 项失败。
  故障仅出现在既有 `testCoreTimeoutKeepsFileDiffAndKeyboardBrowsingWhileGitWritesStayDisabled`：
  工作区 Diff 异步加载前 `mode.exists` 为假，测试跳过显式 Review 切换，
  而在持久化 Edit 偏好下只读到一列 `WORKTREE`。Git HEAD/index 未证实被修改。
  `d3de8128` 将检查改为等待真实 Edit/Review 控件就绪并显式选择 Review。
  对按相同先后顺序执行的 Palette/核心超时两项 E2E 实测 **2/2 通过、退出码 0**；
  不是延长任意固定时间，也没有生产修复。
- 首次全集为避免重复执行已知失败的长串 GUI 测试，在 Git Changes 类结束后主动中断；
  其结果明确为 Interrupted，不记为全集通过。
  修复后其余 UI 类按完整类名单独分组，均以真实退出码和发现测试数核销。

## 2026-10-31 凌晨完整 UI 分组验收

- **A 组（Git Changes/Dialog/History/Windows）**：59/59，通过，0 失败，退出码 0；
  `/tmp/bailey-p5-focus-ui-groupA-20261030.log`。
- **B 组（Git Graph/Geometry/SharedTree/Dock）**：78 项原始 77/78，通过，
  唯一失败为同一中文片段周期重复造成的滚动位图无法判别；
  修正数据后原方法 1/1 通过、退出码 0（`edc31129`）。
  其余 77 项均在同次原始类联跑中通过；
  `/tmp/bailey-p5-complete-ui-B-20261030.log`。
- **C 组（Editor/Files/Retention/Smoke/SSH）**：53 项，49 通过、
  4 个测试方法失败、8 条 XCTest 断言失败，完整命令退出码 2；
  `/tmp/bailey-p5-complete-ui-C-20261030.log`。
  失败分别为 Windows SSH 命令面板的输入框在第二次打开时缺失、
  Windows SSH→本机 Finder 拖放的目标项目未匹配、Finder→WebKit 原生上传
  被 Finder 窗口位置遮挡及主题重启用例仍按旧 `.segmented` 的 RadioButton
  查询 macOS 27 原生 `.tabs`。**这四项尚未核销，不可宣称完整 GUI 通过。**
  同组 Windows SSH 双窗口测试（含专用 master 断开恢复）实际通过。
- 新增容量与高对比宿主 2/2 通过；按当前 53+78+59 个 UI 方法的覆盖，
  已有 186 项通过或经过针对性 Red→Green，剩余明确为 C 组四个失败方法。
  “已通过”统计不等于同一套 190 项修复后一次性全绿。

## 未核销的设备与组合

- macOS 15.6 真机（本机 27.2）；最低平台上的原生窗口/AX/菜单效果未知，
  需在 15.6 的 Dev 或 CI 环境补测。
- VoiceOver 实际朗读、专用硬件触控板/中键与中文/日文 IME 组词、
  高对比及第二显示器指定手工操作：不能用合成 AppKit 事件或默认 UI 测试冒充。
- Windows SSH 与**两真实窗口**的选区、菜单、文件字节及 Dev 专属 SSH master 断开/恢复
  已在同一次真实 App GUI 测试中通过。更进一步的**多个 Dock 组及整机网络中断**
  尚未合并进同一 E2E；现由 Dock 多组宿主/GUI 与该真实 SSH GUI 分别验证，
  不将关闭专用 SSH master 说成 Windows 主机完全断网。
- 10k/100k Files 已新增真实原生视口/模型/滚动和进程峰值 RSS 验收；
  **长期内存回落及 Instruments 主线程帧间隔**尚缺设备级连续运行测量，
  不能由短时单次基线外推为长期性能保证。
