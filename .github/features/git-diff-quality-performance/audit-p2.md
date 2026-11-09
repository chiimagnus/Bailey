# Audit P2 - git-diff-quality-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/git-diff-quality-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [ ] P2-T1 修复原生首帧布局和滚动几何的共同根因（重开审查，宿主修复已验证，阶段 Gate 未通过）
- [x] P2-T2 消除逐键正文全量回读及重复判定
- [x] P2-T3 统一实时折叠编辑坐标和手动展开行为
- [x] P2-T4 收敛 Unified Split 滚动与原生绘制
- [x] P2-T5 验证 Git 行浏览、折叠 AX 与焦点动作

## 任务到文件的映射

- P2-T1（`c8d92f1a`）
  - `Bailey/Git/DiffTextView.swift`：单一内容存储、折叠元素枚举、固定 LF 可见几何、100k 冷跳及删除行占位。
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Editor/NativeCodeTextView.swift`、`Bailey/Editor/NativeTextLineIndex.swift`：首屏装配与实时内容/行索引。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Git/DiffFoldLiveMutationTests.swift`、`BaileyTests/Editor/TextCoordinateIndexTests.swift`、`docs/features/diff.md`。
- P2-T2（`ee85f511`）
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Git/DiffViewerView.swift`、`Bailey/Editor/NativeCodeTextView.swift`、`Bailey/Editor/SourceTextEditor.swift`：原生变化范围、写入原文字节与已保存基线。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/features/diff.md`、`docs/features/editor.md`。
- P2-T3（`4127eead`）
  - `Bailey/Git/DiffTextView.swift`、`Bailey/Editor/NativeTextLineIndex.swift`、`Bailey/Git/DiffViewerView.swift`：折叠唯一实时坐标、Find/Replace/选区与版本。
  - `BaileyTests/Git/DiffFoldLiveMutationTests.swift`、`BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/features/diff.md`、`docs/ui.md`。
- P2-T4（`036873d5`）
  - `Bailey/Git/DiffNativeSurface.swift`、`Bailey/Git/DiffTextView.swift`、`Bailey/Git/DiffViewerView.swift`、`Bailey/Workspace/Project.swift`、`Bailey/Editor/NativeCodeTextView.swift`：Split/Unified、虚拟删除行和原生生命周期归属。
  - `BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyTests/Workspace/NativePaneRetentionIntegrationTests.swift`、`BaileyUITests/Git/WorkspaceGitUITests.swift`、`docs/architecture.md`、`docs/features/diff.md`、`docs/features/editor.md`。
- P2-T5（`a9e41fc1`）
  - `Bailey/Files/FileTreeModel.swift`、`Bailey/Files/FileTreePanel.swift`、`Bailey/Git/GitPanel.swift`、`Bailey/Git/DiffTextView.swift`：Git 选择与折叠 AX，以及 Files 跨 await 对象代次保护。
  - `BaileyTests/Files/FileTreeTests.swift`、`BaileyTests/Git/GitStatusModelTests.swift`、`BaileyTests/Git/NativeDiffTabTests.swift`、`BaileyUITests/Git/GitChangesUITests.swift`、`docs/features/files.md`。

## 发现项

## 发现 F-04

- 任务：`P2-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Git/GitChangesUITests.swift:481`
- 摘要：`真实 Bailey 历史跨来源 GUI 用例假定每个 Git Patch 均有新增行；当前 HEAD 对前一版本只有删除行，导致测试尚未启动 App 即失败`
- 风险：`真实源代码持续迭代时 P2/P3 的跨来源回归依赖特定提交增删方向，合法 Git 状态被误判为产品失败，且完整 GUI 门禁长期不稳定`
- 预期修复：`从真实 Git patch 按实际变化方向选取可定位且出现在原生 Diff 的文本，允许纯删除而不伪造夹具；保持真实 HEAD/index/worktree 字节和原有 UI 断言`
- 验证：`验证当前 HEAD 对 previous Diff 0 新增 11 删除；make test:ui ONLY_TESTING=BaileyUITests/GitChangesUITests/testRealBaileySourceHistoryDiffLoadsAcrossIndexWorktreeAndOtherSource，核对真实 App 原文、Git index/HEAD 与两种来源`
- 解决证据：`513c94e5：真实 Bailey 源码 HEAD→上一版 staged 只有11条删除、无新增，原用例在 App 启动前 XCTUnwrap Red；修正为从真实 patch 选择实际新增或删除行，未改变真实Git HEAD/index/worktree及 UI 字节/原生折叠断言。make test:ui ONLY_TESTING=BaileyUITests/GitChangesUITests/testRealBaileySourceHistoryDiffLoadsAcrossIndexWorktreeAndOtherSource：Selected XCTest methods 1、1通过、0失败、TEST SUCCEEDED（29.562s）。make test 917项0失败16条件跳过、退出0。`


## 发现 F-03

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/DiffTextView.swift`（`DiffCodePaneView.layout`／`applyContentHeightOverride`）及 `Bailey/Editor/NativeTextLineIndex.swift`
- 摘要：`原审计在实际 LF／CR／Unicode／Ghost／稀疏折行根因修复与宿主回归完成后，仍强制额外 WindowServer 首像素和 30 次冷热 GUI P95，属于超出用户验收范围的计划过度指定，而非已证实产品缺陷。`
- 风险：`额外门禁会使已通过实际 Swift 正确性回归的 P2-T1 无期限阻塞，并诱导在用户桌面运行抢焦点测试或创建不需要的虚拟机。`
- 预期修复：`收敛 idea.md 与 P2/P4 验收，以 BaileyTests 覆盖原生组件、极端组合和实际字节，以必要 BaileyUITests 验证用户操作；对实际失败的 XCTest 继续修根因。`
- 验证：`eaa6d05a 相关 make test 本机 932 项 0 失败（16 项条件跳过），Debug／Release 验签通过；隔离 Bailey Dev 55 项真实 Git UI 通过；该提交后 GitHub Actions 42637140114 与 42636683924 选择性 UI 各 9 项通过。更晚 CI 完整宿主测试有失败，由 P4-T5 复查，非本 finding 所指 GUI 帧门禁。`
- 解决证据：`2026-11-09 用户明确以相关 Swift XCTest 为验收：额外 WindowServer 首像素、独立30次冷热GUI P95和虚拟机为plan过度指定而非产品缺陷。eaa6d05a 已完成原生滚动/UTF-16/折叠/Ghost等根因修复；make test 本机932项0失败16环境跳过，Debug/Release严格验签，UI测试目标编译通过；既有隔离Bailey Dev完整Git UI 55项0失败，eaa6d05a之后的GitHub Actions 42637140114/Xcode27.2与42636683924各实际9个必要BaileyUITests全通过。较新CI全量BaileyTests有失败，属于P4最终HEAD全量回归待处置，不冒充CI全绿。修订idea.md/plan-p2.md/plan-p4.md后撤销原额外GUI帧统计阻塞。`


## 发现 F-02

- 任务：`P2-T4`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Support/WorkspaceUITestSupport.swift:112`
- 摘要：`GUI冷启动偶发不挂载测试专属Git工作区`
- 风险：`本机同一GitHistoryUITests首个冷进程已出现窗口但30秒内未出现bailey.dock.files，导致历史二进制与超限文件无法进行真实UI校验`
- 预期修复：`跟踪BAILEY_UI_TEST_PROJECT从首次隔离启动到项目/Files Dock实际出现的状态与失败终态，区分加载缺失和AX可见性，不增加盲等或重新建窗`
- 验证：`隔离首次GUI启动与该测试的窗口、项目和Files Dock可见证据；make test:ui ONLY_TESTING=BaileyUITests/GitHistoryUITests/testBinaryAndOversizeHistoricalRevisionsShowNativeReadRestrictions`
- 解决证据：`f6573679: 隔离GUI冷启动以唯一绝对路径bailey.project.row验证项目已挂载，不再以bailey.dock.files存在判断；5次不同测试独立冷启动均通过，Binary/Oversize作为首例通过；Peekaboo AX实测同一隔离会话项目行与Files Dock均存在。build/git-history-audit-20261107.log:944-1049,1684-1698。`


## 发现 F-01

- 任务：`P2-T5`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Git/RecentCommitsView.swift:1656`
- 摘要：`历史提交文件右键上下文菜单在真实 Bailey Dev GUI 中不可访问`
- 风险：`5条GitHistoryUITests中4条实际历史文件行已存在且可命中，但右键后Reset/View/Compare菜单项不出现，相关重置和历史比较最终字节未被GUI证明；整套UI命令退出65`
- 预期修复：`沿TreeFileRow与ContextMenuClickTarget到原生右键事件/NSMenu追踪排查，区分产品菜单被吞与XCUITest显示坐标合成失效；在真实所有者根修，不以重试或Sleep掩盖`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/GitHistoryUITests；真实右键菜单AX/动作与Git磁盘字节核对`
- 解决证据：`f6573679: GitHistoryUITests完整5/5通过、0失败，右键NSMenu键盘操作到达View/Compare/Open/Reset且真实Git Index/HEAD/文件字节符合预期；原生菜单项XCUITest直接枚举假失败。build/git-history-audit-20261107.log:1684-1698。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- `eaa6d05a`：Git-LF 首次行索引改为扫描原 Swift String UTF-16 单元，后续编辑仍使用同一可增量更新的索引；共享原生编辑器的文字宽度缓存用既有自然段落行起点和有界 UTF-16 缓冲批量识别等宽 ASCII，Unicode 与 Tab 仍按字体测量。扩大真实 Git Staged／Unstaged 首次组件位图性能矩阵到 100k 行各 30 次，并对实际首帧文字像素、未预热冷滚动文字像素增加断言。仅提交 5 个代码／测试文件和 2 个功能文档；Feature 计划与审计仍留本地。
- `a45a8996`：折叠内部原生段落计数复用现有 NativeTextLineIndex 的实时行坐标，修正非单调行映射；滚动仅在剪裁区反映后布局 TextKit 视口，移除新增的每次滚动整棵视图同步布局。新增2400行字号／宽度组合及100k Git行30次深跳、未预热原生滚动条首帧与字符命中回归。只提交 `DiffTextView.swift`、`NativeDiffTabTests.swift` 和 `docs/features/diff.md`；Feature 计划和审计仍为本地文件。
- `a16c71fa`：修复只读重载锚点、稀疏长行折行、Ghost 虚拟几何、CRLF／Unicode 原生分隔符类型增量同步以及无 Diff 装饰的历史原文快速布局；删除被替代的全文换行类型扫描与旧段落间距路径。仅提交 6 个代码／测试文件和 2 个功能文档；Feature 计划与审计记录保持本地。

## 验证日志

以下为测试发生时的原始证据；其中“F-03 Open / P2 Gate No-Go”是
**2026-11-09 验收收敛之前的历史结论**，当前状态只看本文件末尾 Gate。

- 2026-11-09 `eaa6d05a` 全量修复验证：`build/p2t1-utf16-first-paint-final-full-20261109.log`：`make test` 932 项、0 失败、16 项条件跳过，`TEST SUCCEEDED`；`build/p2t1-utf16-first-paint-final-debug-20261109.log`、`build/p2t1-utf16-first-paint-final-release-20261109.log`：Debug／Release 均 `BUILD SUCCEEDED` 且严格代码签名校验通过；`build/p2t1-utf16-first-paint-final-ui-compile-20261109.log`：`TEST BUILD SUCCEEDED`（仅 UI 测试目标编译）。100k Git-LF 初次行索引约 263→43ms，原生行宽准备约 290→152ms，同一台 Mac 的分段样本；`build/p2t1-100k-mixed-real-glyph-pixels-20261109.log`：30 次混合深跳 P95 5.91ms、真实冷滚动目标字形像素与字符命中通过。`build/p2t1-git-component-100k-pixels-20261109.log` 和全量宿主日志：真实 Git Staged／Unstaged 各 30 次 1k／24k／100k 首次组件位图、100k 首次可见行文字像素断言通过。组件缓存绘制并非 WindowServer 真实首像素；真实 Bailey Dev 独立 GUI 混合首像素与冷热 30 次 P95 仍缺隔离图形会话，F-03 High Open、P2 Gate No-Go。
- 2026-11-09 `a45a8996` 最终宿主与构建核销：`build/p2t1-fold-scroll-final-full-host-20261109.log`：`make test` 931项执行、0失败、16项真实SSH条件跳过，`TEST SUCCEEDED`；`build/p2t1-scroll-fold-root-regression-20261109.log`：相关187项0失败1跳过。`build/p2t1-cold-manual-native-scroll-final-20261109.log`：30次原生深跳 P95 6.69ms、最慢7.13ms，未预热直接 clip 滚动至61,234行的首次可见字形及实际字符命中通过。`build/p2t1-fold-scroll-final-debug-20261109.log`、`build/p2t1-fold-scroll-final-release-20261109.log`：Debug／Release BUILD SUCCEEDED 且严格 codesign 核验通过；`build/p2t1-fold-scroll-final-ui-compile-20261109.log`：TEST BUILD SUCCEEDED，仅编译 UI 测试。所有样本为本机宿主视图或组件，未进行完整 Bailey Dev 的 WindowServer 首像素测量；F-03保持 High Open，Gate No-Go。
- 2026-11-09 P2-T1 极端组合新反例：100,000 Git 行约 300,000 原生段落，同时包含裸 CR／U+2028、稀疏折行、三处折叠与四处删除 Ghost。初次回归在折叠后的第 51 行漏绘；进一步加入真实 clip 滚动和 17 次远跳时，部分跳转达到 4.2～8.4 秒。根因是隐藏原生段落计数只包含已完成的折叠，折叠内部 Y 映射不再单调；同步修正原生 clip 状态到 TextKit 视口的时机。Red：`build/p2t1-100k-mixed-native-viewport-diagnostic-20261109.log`、`build/p2t1-manual-scroller-and-100k-timing-20261109.log`。Green：`build/p2t1-100k-mixed-30-p95-final-20261109.log`（30 次混合远跳 P95 5.97ms、0 失败），`build/p2t1-scroll-fold-root-regression-20261109.log`（187 项 0 失败、1 SSH 条件跳过；30 次混合远跳 P95 6.57ms）；另有 3 次独立 17 跳全部通过。原生首帧布局约 565ms 是宿主 `NSWindow` 样本，不等于完整 App WindowServer 首像素；正式 GUI 仍未复测，F-03 继续 Open。
- 2026-11-09 `a16c71fa` 最终验收：`build/p2t1-final-verified-host-20261109.log`：`make test` 实际执行 929 项、0 失败、16 项条件跳过，退出成功；`build/p2t1-final-verified-build-20261109.log`：`make build` 成功且 Debug 严格验签通过；`build/p2t1-final-verified-release-20261109.log`：`make build:release` 成功且 Release 严格验签通过；`build/p2t1-20261109-final-ui-build.log`：`make build:ui` 测试目标编译成功（`TEST BUILD SUCCEEDED`），未运行完整 App XCUITest。
- 2026-11-09 反例实测：100k 行历史纯原文首次布局约 3173→216 ms，并核验深跳、字形及原文字节；CRLF→裸 CR／U+0085／U+2028／U+2029 以及 Undo 与行索引随机编辑全部通过；`build/p2t1-revised-targeted-host-20261109.log`：185 项、0 失败、1 项条件跳过。
- P2-T1 原生 TextKit 反例 Red／Green：`build/p123-variable-native-red.log` → `build/p123-variable-native-green.log`；`25200b0d` 使用现有原生自然段落索引而非 Git-LF 行号，100k 裸 CR 等高、无折行首帧约 3081→154 ms；尾段落坐标、滚动高度、原始字节和编辑／Undo 已实测通过。
- 宿主 `make test`：`build/p123-audit-20261109-final-full-v2.log` 920 项、0 失败、16 项真实 SSH 等环境条件跳过、退出码 0；该结果包括 P2 修复但不含后来加入的 P3 过期读取用例。隔离 `Bailey Dev` 三组真实 Git UI：`build/p123-audit-20261109-git-ui-final.log` 55 项、0 失败、0 跳过、退出码 0。
- GUI 旧夹具 F-04：真实 Bailey 源码 HEAD 对前一提交的 staged patch 有 11 行删除而无新增，原用例在启动前失败；`513c94e5` 改选真实已有的新增或删除行，原有内容、Git Index 与窗口断言不降级；定向复测及 55 项完整 UI 回归均通过。
- 已核销：本机真实 Git、原生 TextKit 1k／24k／100k、CRLF／裸 CR／U+2028／U+2029、普通等高行、字体／深滚动、折叠与 Undo、真实 Changes 和历史窗口、状态超时／旧目标切换。相关性能数字限于各自测量对象，不等于 WindowServer 精确首像素时间。
- **2026-11-09 验收变更**：原要求的独立 WindowServer 首像素、30 次冷热 GUI P95 与专用 macOS 虚拟机不再构成阻塞；相关 Swift 原生几何、文字像素、滚动和字节回归已通过。P4 仍负责完整 App 的必要交互／中文 IME／授权远端 SSH 与最终代码提交的全量 XCTest；近期 GitHub Actions 的完整宿主 Job 有真实失败，不能冒称最终 CI 全绿。正式 Bailey 未替换或重启。
- 文档：`docs/features/diff.md`、`docs/features/editor.md` 已同步原生索引与几何实现；当前验收要求同步至 `idea.md`、`plan-p2.md`、`plan-p4.md`，`todo.toml` 的 P2-T1 为 `completed`，本轮 P2 Gate 按新范围为 Go。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P2-T1～T5 的 Swift 实现、相关宿主回归和必要完整 App UI 回归有可核查的通过证据；F-01～F-04 均已 Resolved。F-03 的剩余门禁被确认是额外 GUI 帧测量要求，而非未修复的产品行为错误。P4 的最终 HEAD 全量 CI 失败调查仍属独立待办，不将 P2 Gate 的 Go 冒称最终交付通过。

## 最终状态与剩余风险

- 当前状态：`Resolved`（P2 阶段验收已通过；非整个 Feature 交付完成）
- 剩余风险：更晚 CI 的完整 `BaileyTests` 存在真实失败，需要 P4-T5 按提交与运行环境排查；P4-T2 的必要真实用户操作与 P4-T3 的远端特殊条件仍应按 Swift XCTest 验证。额外 WindowServer 帧采样不再视为验收缺口。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

