# P2 实施与回归证据

## P2-T2：原生编辑范围与单一正文快照（2026-11-06）

**范围：** `NativeCodeTextView.processStorageEdit`、
`SourceTextEditor.Coordinator`、`DiffNativeSurface`、
`DiffTab.nativeTextDidChange/refreshEditDecorations/writeCurrentText`；
共享 Files 原生后置事件、可编辑 Worktree Git Diff、字节保存与 Undo。

**修改前缺陷：** 原生 `NSTextStorage.didProcessEditing` 已提供真实
UTF-16 前一范围与替换文字，Git Diff 却只接收零参回调；
每键 `DiffNativeSurface.editTextDidChange` 读取完整 `textView.string`，
`DiffTab.updateEditedContent(String)` 再用全文
`utf8.elementsEqual(savedNewContent.utf8)` 判脏并当场生成完整
`editedNewContent` 快照。SwiftUI 重绘还会无条件求值源文字参数。
大文件前部编辑增加重复主线程工作；Undo/Redo 也走该路径。

**同任务删除和替换：**

- 共享 `onCharacterEdit` 改为传真实 `previousRange`／`replacement`；
  FileTab 只在原生前后事件的 UTF-16 范围及**字节**一致时
  使用受控旧文字，否则保留原有全字节回退，不复用失效的前置事件。
- Worktree 以现有 TextKit 2 `NSTextStorage` 为唯一可写正文，
  `editedNewContent` 仅在必要时从已完成载入的原生 pane 读取。
  `editableSnapshot` 只保存最近已验收的 Git 原始快照，
  不再每键维护另一份动态可写文字。
- 用本次变化的 UTF-16 单元增减表判定肯定不同的正文；
  只有增减抵消或缺少可信前置修改范围时核对完整 UTF-8，
  以免 NFC/NFD、相同字符重排或真实 Undo 被误判。
  撤销来自干净状态的一次修改可精确恢复，无需全文比较；
  直接在原位调整差异表，脏状态未改变时不重复向 SwiftUI 发送变更。
- 数据源接受新 Git 快照时重置追踪器，并在**模型装入唯一入口**
  暂停外部用户编辑回调；不屏蔽 TextKit 自己的索引、Undo 或语法维护。
  防抖 120 ms 后、真实需要 Diff 投影时才取得完整当前正文快照，
  保存时才冻结真正写盘的完整原始 UTF-8。
  并发保存完成后按新的保存基线重新核对／同步追踪器。
- 彻底移除逐键 `updateEditedContent(String)` 和零参
  `onCharacterEdit`；旧测试改为驱动真实 `DiffTextView.insertText`
  并核对原文，未保留测试专用生产兼容入口。

**Red→Green：** 初版增量追踪器在
`testReadInFlightCannotReplaceEditingOrDisconnectedContent`
中失败，无法撤销到干净正文；原始日志
`build/git-diff-p2-t2-native-regressions.log`。
追踪日志 `build/git-diff-p2-t2-revert-diagnostic.log` 复现：
初次 Git 模型装入原生 TextKit 产生字符通知
`loc=0 prior=0 replacement=12`，
实际原始字节已经相等，但错误增量表有 11 个非零键。
不是 Unicode 比较或读任务身份失效。
在唯一程序化载入入口暂停外部回调后，
`build/git-diff-p2-t2-revert-green.log` 的四项 Undo／读失效／保存
定点用例 0 失败；加上
`testNativeDiffDirtyTrackerDistinguishesInitialLoadManualRevertAndUnicode`
及原生折叠、输入法后，
`build/git-diff-p2-t2-dirty-tracker-matrix.log` 三项 0 失败。

**输入真实矩阵（第一次实现的 Debug 版）**：
`build/git-diff-p2-t2-native-regressions.log`
包含 100k txt／Swift 文件文首／中／末各 30 次输入+Undo，
每次完整检查磁盘字节；该矩阵用例通过。
Swift 文首 P95 约 495 ms、文中约 252 ms、文末约 1.12 ms。
不能宣称该次 Git Diff 层改动已让**整体**文首输入达到
`docs/testing.md` 的 100k P95 ≤32 ms；
P1 TextKit 主线程 `updateRangesForTextElement` 与当前全篇布局路径仍有
独立证据，须由 P2-T1 的准确几何方案处理。
性能对照构建和其它进程负载尚未严格一致，不归因未经核验的提升／退步。

**四类受影响完整 XCTest（最后一次代码微调之前编译）：**
`build/git-diff-p2-t2-targeted-full.log`：
NativeDiffTabTests 90 项（1 SSH 条件跳过）、
NativeEditorCompositionTests 11 项、
NativeFileTabTests 18 项、
TextCoordinateIndexTests 9 项，共 **128 项、1 跳过、0 失败**，
Make 退出 0。其后进一步将差异表改为非可选原位更新、
避免每键重复脏状态观察通知；最终代码还须另行编译并全量验证。

**持续约束：** 普通 Dock 重挂载不能重建编辑器／Undo；
原始 Unicode、CRLF 和 clean filter 与真实 Git 保存结果保持逐字节一致；
真实独立 App 高帧率可输入时点、系统 IME 候选和
TextKit 100k 首屏几何仍按 P4-T2／T4 与 P2-T1 核销，
不能凭宿主绿色冒充完整 UX 达标。

**最终源码的完整命令验证：**

- `make test`：`build/git-diff-p2-t2-final-full-host.log`，真实执行
  **857 项、16 项按未指定的 SSH 主机条件跳过、0 失败**；
  Xcode `TEST SUCCEEDED` 且 Make 退出 0（950.13 s）。
  包含新 `testNativeDiffDirtyTrackerDistinguishesInitialLoadManualRevertAndUnicode`。
  这些跳过不是远端成功证据。
- `make build`：`build/git-diff-p2-t2-final-make-build.log`，
  正式构建产物 `BUILD SUCCEEDED`，严格 `codesign --verify --deep --strict`
  退出 0；未安装或启动正式 Bailey。
- 最终全套中的 100k Swift Debug 输入 30 次：
  文首 P95 **560.67 ms**、中部 **276.16 ms**、末尾 **1.59 ms**；
  24k Unstaged Debug 组件像素中位约 **1527.75 ms**、P95
  **1633.86 ms**。对应 P1 Debug 的 100k Swift 文首 P95 约
  469.24 ms、末尾约 140.57 ms，24k Unstaged 组件 P95 约
  1545.12 ms。当前代码的末尾事件明显更轻量，但文首和 Diff
  打开时间未达标；两轮并非系统负载、版本及后台任务完全一致的
  严格 A/B，不得把此差异独立归因于实现的回归或性能收益。
  重复 TextKit 全篇布局及原生段落编辑维护仍按 P2-T1 的 No-Go
  门禁处理，不能用当前 T2 的局部实现掩盖整个产品性能目标。

**真实独立 Bailey Dev GUI 测试（2026-11-06）：**
`make test:ui ONLY_TESTING=BaileyUITests/WorkspaceGitUITests/testWorktreeDiffEditsAndPersistsRealGitFile`
已实际枚举并执行 1 项、0 失败／0 跳过，Make 退出 0，
约 32.05 秒，日志 `build/git-diff-p2-t2-real-gui-undo-redo.log`。
测试在真实隔离 Git 仓库中先选择 Worktree，切换 Split／Unified，
核对只读基线与可编辑原文；通过原生 Find、键盘全选与中文替换，
真实按下 ⌘Z 观察正文撤销变化，按 ⌘⇧Z 确认恢复最新字节，
再按 ⌘S 并独立读取磁盘确认原文字节与编辑器一致。
整个 UI 测试仅操作 `chiimagnus.bailey.dev`，由夹具创建／清理临时项目；
未安装／切换正式 Bailey。单次 GUI 通过不等于系统 IME 中文候选、
真实远程断线、完整窗口首像素性能和 30 次长期自动保存均已通过。

## P2-T3：实时 Git 行号与折叠版本（2026-11-06，仍在验证）

P2-T3 开始时工作区已有尚未提交的同任务改动：
`NativeTextLineIndex` 的 Git-LF 模式、`DiffTextView` 实时行号索引、
`DiffCodePaneView` 的折叠／删除占位同步，以及两项测试。
这组代码先完整复核而未清理，原始文件修改时间为当天 16:04–16:13。

- 原有新增的索引随机替换和“在后台防抖前插入两次换行／Undo”
  测试通过：`build/git-diff-p2-t3-existing-changes-review.log`，
  2 项、0 失败。
- 发现实际缺陷：在隐藏 Git 行 5–22 内修改第 14 行，
  `adjustLiveFoldSource` 直接删除整个折叠，致使未修改的第 8、20 行立即展开。
  新增独立原生回归 Red 日志
  `build/git-diff-p2-t3-hidden-edit-red2.log`：
  1 项、2 个断言失败。
- 修正处只在已有折叠所有者：不增删 LF 的修改保留折叠；
  修改完全位于单个隐藏区间且增删 LF 时，按行数变化调整当前隐藏区间，
  避免把无关行全部展开。新变更最终显示仍交给后台 Diff，
  不建可写副本、不启动定时刷新或旧视图重建。
- Green：`build/git-diff-p2-t3-hidden-edit-green.log`，
  混合换行索引、换行／Undo、隐藏段落普通替换与插入 LF
  共 3 项、0 失败。
- 进一步发现无折叠文件的增量行号没有建立来源索引：
  输入 LF 后 `decorations.rows` 和 UTF-16 行起点停留在旧的 3 行，
  新源码实际有 4 行。Red 证据
  `build/git-diff-p2-t3-unfolded-rows-red.log`（1 项、2 个断言失败）。
  修正为即使无折叠也维护单一 Git-LF 原文行索引；
  初始快照无行偏移时直接从当前原生存储构建，不等待后台 Diff。
  Green 证据 `build/git-diff-p2-t3-folded-unfolded-green.log`：
  折叠／无折叠和随机 Unicode 坐标共 4 项、0 失败。
- 对删除 ghost 的关联核验：在第 10 行前插入 LF 后，
  原本锚定第 40 行的删除占位即移到第 41 行，
  原生 UTF-16 行起点与实际 changed 行一致；
  `build/git-diff-p2-t3-ghost-anchor.log` 1 项、0 失败。
- 第一轮受影响全域测试 `build/git-diff-p2-t3-affected-suites.log`
  **136 项、1 远端条件跳过、0 失败**，Make 退出 0，
  但编译版本在“无折叠编辑”修复之前；仍需最终版完整复测。
  真实 Dev App 的 Find／跨隐藏替换／Split／滚动与 AX、
  跨边界删除、连续 Undo 和大文件性能也待核销。
  本项尚未提交或标记完成。

- 同任务发现行首插入 LF、从完整行边界删除多行时，
  增量投影把旧的新增行颜色绑定到错误的新行；
  `build/git-diff-p2-t3-row-tint-boundary-red.log`
  独立测试 1 项、3 个预期失败。
  根因是仅按首个涉及行映射，没有区分“修改结束恰好在原行首”。
  现从原生单一 Git 行索引保存编辑前结束边界，
  只为确证未修改的前后原始行迁移行着色及删除占位，
  中间不确定区域保持中性直到后台 Diff 发布。
  `build/git-diff-p2-t3-row-tint-boundary-green.log`：
  边界 + 隐藏行／Undo 合计 6 项、0 失败。
- 独立 Bailey Dev 查找栏及 AX：
  首轮测试失败是测试错误地使用输入框 `label`，
  并假设原生按钮名称为 “Replace All”。
  导出失败时的真实 AX 树（`build/git-diff-p2-t3-ui-evidence/`）
  显示替换输入框实际属性是 `placeholderValue=Replace`，
  原生按钮为 “All”；并非生产替换功能缺失。
  正确查询后，`build/git-diff-p2-t3-real-find-next-gui-v2.log`
  验证真实 Find、两次 ⌘G、原生 Replace、保存字节，1 项通过。
- 首次组合 GUI 三测试，Git Manager 元素存在却瞬间尚不可点击。
  失败后导出的 AX 树
  （`build/git-diff-p2-t3-ui-matrix-failure-attachments/`）
  证明实际 App 已显示并选中 Git Manager。
  改为等待 AX 的可点击状态而不是立即判断；
  最终 `build/git-diff-p2-t3-final-gui-matrix.log`
  三条真实 App 路径（900 行折叠按钮与原文、
  隐藏查找／替换／保存、⌘Z／⌘⇧Z／⌘S）共 **3 项、0 失败**，
  Make 退出 0。使用隔离 `chiimagnus.bailey.dev`，
  结束后恢复 Find 剪贴板的全部数据类型及系统输入法。
- `make build`：
  `build/git-diff-p2-t3-final-make-build.log`，
  Xcode `BUILD SUCCEEDED`，`codesign --verify --deep --strict` 退出 0。
  未替换或重启正在使用的正式 Bailey。
- **最终源码完整宿主验收（2026-11-06）：** `make test`
  日志 `build/git-diff-p2-t3-final-current-full-host.log`：
  **864 项、16 项按 SSH 主机条件跳过、0 失败，Make 退出 0**。
  包括 DiffEngine 23、DiffFoldLiveMutationTests 4、NativeDiffTabTests 92
  （其中 1 项远端条件跳过）、NativeEditorCompositionTests 11、
  NativeEditorLayoutTests 45、NativeFileTabTests 18、
  TextCoordinateIndexTests 10，及其它窗口／Git 回归。
  远端条件跳过不等于 Windows SSH 实机通过。
- **最终来源性能：** 100k Swift Debug 编辑文首 P95 **457.51 ms**、
  文中 **250.43 ms**、文末 **1.37 ms**；
  100k 纯文本依次 **436.27 / 235.81 / 1.25 ms**。
  24k Unstaged 首次组件可见为 **1948.75 ms**。
  同机不同负载／运行时间的数字不能直接认定实现导致回归或收益；
  但明确不满足 100k 输入 P95 ≤32 ms 性能预算。
  P2-T1 的 TextKit 准确几何方案仍 No-Go，本任务的正确性验收
  不代替后续性能验收。

## P2-T4：原生 Diff 真关闭后的释放和分栏几何（2026-11-06，进行中）

**已证实的根因：** P1 原始真实 Git 仓库的红色实验曾在
`project.closeDiffs()` 后仍通过被人为强持有的旧 `NSScrollView`
保留完整可写 `DiffTextView`、语法解析器及 35,780 个正文 UTF-8 字节。
本轮将同等测试纳入 `NativeDiffTabTests`，
`build/git-diff-p2-t4-native-close-red.log` 再次得到
**1 项失败／3 个断言失败**，排除先前改动偶然修复。

CodeGraph 源码核对：`Project.remove(tabID:)` 旧版本只给 Diff
清 `onSnapshotChange`；`Project.terminateAll()` 仅退役 Files；
`DiffNativeRoot.dismantleNSView` 只能撤销临时焦点，不能代替真关闭。
FileTab 已有 `retireObsoleteDocument`，却不覆盖 Diff 的所有权。

**同一真实拥有者的修复：**
在 `Project.remove/terminateAll` 真关闭时通知 DiffTab 退役
唯一 `DiffNativeSurface`，逐个解除 Worktree、Unified、Split
两侧的本地回调、Undo、语法解析器与缓存滚动视图的
`documentView`；Diff pane 已与滚动视图解绑后，再从
`NSTextContentStorage` 移除原有 `NSTextLayoutManager`。
共享 `NativeCodeTextView.retireNativeDocument` 只关闭编辑／Undo／
语法与共用事件，不在通用入口移除布局管理器。
`DiffNativeRoot.dismantleNSView` 继续只撤销挂载相关的焦点；
Dock 切换与临时卸载后保留同一 TextKit 文档和 Undo。

**失败分离与修复顺序：** 第一版把布局管理器提前从共享
`NativeCodeTextView` 卸下，在 FileTab 旧宿主 AppKit 仍进行布局时
使 `nativeLayoutManager` 成为 nil 并导致宿主崩溃。
原始日志 `build/git-diff-p2-t4-close-green2.log` 为 **TEST FAILED**；
它不能冒充绿色证据。调整为只有 Diff 真关闭／
scrollView 已解除 documentView 绑定后移除布局管理器，
保留 FileTab 旧宿主的安全生命周期。

**已获得 Green：**
- `build/git-diff-p2-t4-close-green3.log`：
  Diff 旧 scroll view 保留／Files 旧视图缓存重载／Files Undo 退役，
  **3 项、0 失败**。
- `build/git-diff-p2-t4-close-mount-weak.log`：
  真关闭后弱引用 TextKit 编辑器和原始布局管理器都释放、
  项目整体关闭与 `DiffNativeRoot.dismantleNSView` 后重挂载保留
  同一原生正文／Undo、Files 旧宿主仍可安全关闭，
  **3 项、0 失败**。
- `build/git-diff-p2-t4-mounted-split-close.log`：
  真实 `NSWindow` 仍强持有原 Diff surface、原工作区编辑视图是
  firstResponder 时，Split 工作区左右两侧的旧
  `NSScrollView.documentView` 全部断开，不再可编辑、无旧 Undo；
  同时核对磁盘和 Git Index 原始字节，**3 项、0 失败**。
- `build/git-diff-p2-t4-multi-resource-horizontal2.log`：20 个独立
  1,000 行 Swift Worktree Diff（每个从真实 Git 临时仓库读取），关闭后
  强保留全部 20 个旧滚动视图，逐一证明 `documentView == nil`、
  原始编辑器与 `NSTextLayoutManager` 弱引用均释放，20 份磁盘 UTF-8
  原始字节不变；长短左右列横滚不会互相回弹；已关闭编辑器的晚到输入
  不会再次变脏。合计 **3 项、0 失败**，Make 退出 0。
- `build/git-diff-p2-t4-affected-suites.log`：原生 Diff、共享语法、
  FileTab／Dock 原生身份、窗口关闭及保留旧 AppKit 视图的
  **162 项、1 项按条件跳过、0 失败**，Make 退出 0。
- `build/git-diff-p2-t4-real-close-reopen-gui.log`：独立 Bailey Dev 的
  Git Changes 真正 `⌘W` 关闭再点击相同工作区文件重新打开，
  新正文无旧 Undo 历史、原始磁盘字节不变，**1 项通过、0 失败**，
  没有替换正式 Bailey。
- `build/git-diff-p2-t4-final-make-build.log`：正式 `make build`
  **BUILD SUCCEEDED**，`codesign --verify --deep --strict` 退出 0。

**全量发现并解决的独立竞态：**
首次完整 `make test` 日志 `build/git-diff-p2-t4-final-full-host.log`
在 20 标签用例遇到宿主崩溃（不是绿色：852 项通过、16 SSH 跳过、
另 1 项崩溃，完整退出 65）。对应
`~/Library/Logs/DiagnosticReports/bailey-2026-11-06-183259.ips`
的主线程堆栈逐层指向 `Neon.Highlighter.makeNextTokenRequest →
SyntaxHighlightTextInterface.visibleRange →
NativeCodeTextView.nativeLayoutManager` 强制解包 nil。
Neon 的 `DispatchQueue.main.async` 回调可在 `highlighter = nil` 后继续执行；
因此只清 `syntaxCoordinator` 不等于清掉排队中的旧接口。
用强持有 20 个已退役 `DiffTextView` 与对应 Neon Highlighter，
主动读取旧 `visibleRange` 的回归再次 Red：
`build/git-diff-p2-t4-neon-retired-callback-red.log` 崩溃。
修复归属是 `SyntaxHighlightCoordinator.deactivate`：先使唯一
`SyntaxHighlightTextInterface` 断开对旧 `NativeCodeTextView` 的弱访问，
然后释放 Highlighter。旧请求仅见到空范围与长度，不再访问已移除的布局。
`build/git-diff-p2-t4-neon-retired-callback-green2.log`：
20 标签／保存原字节／排队着色接口模拟、单 Diff 真关闭、
FileTab 旧视图缓存重载共 **3 项、0 失败**，Make 退出 0。
这是修复异步消费者的根因，不修改第三方 Neon 代码。

**后续仍需核销：** 以上 20 标签测试是 1,000 行 UTF-8 而非 20 份
24k 行或 5 MiB；不将弱引用释放等同于长期整机 RSS 必然下降。
对应稳定 malloc／RSS、20×24k／最大合法文本、反复关闭重开与
系统窗口活跃时间的完整 Allocations 验收仍由 P4-T4 核销。
**最终源码完整宿主验收：**
`build/git-diff-p2-t4-post-neon-final-full-host.log` 对应当前含 Neon
退役修复及旧 AppKit pane 再布局回归的源码：`make test` 共 **869 项、
16 项 SSH/环境条件跳过、0 失败、Make 退出 0**。`NativeDiffTabTests`
共 **97 项，1 项条件跳过、0 失败**；此前仅在完整顺序发生的 20
标签关闭崩溃已在这一完整顺序下通过。
`build/git-diff-p2-t4-retired-pane-late-layout-matrix.log` 使用仍被强引用的
Split 双 pane 在真关闭后强制再次布局，并核对 20 份关闭释放，
**2 项、0 失败**；无需针对无证据的潜在布局问题另外改造生产生命周期。
`build/git-diff-p2-t4-post-neon-final-make-build.log`：相同产品源码
`make build` 的 Debug 构建与 `codesign --verify --deep --strict` 均退出 0。
16 项跳过不计作真实 SSH 实机通过；P2-T1 的首帧完整布局及
100k 行编辑延迟 No-Go 结论不变，不能将资源回收修复写作性能预算已达标。
完整 App GUI 自独立 Bailey Dev 执行，不触及在用正式 Bailey。

**用户截图暴露的原生像素缺陷（19:17–19:36 继续核验）：**
`/Users/chii_magnus/Downloads/截屏2026-11-06 19.17.07.png`
显示旧行红色字体与真实工作区第一行文字重叠；
`build/git-diff-p2-t4-post-neon-final-gui.log` 的原始 4 项 GUI
有 1 项失败，`⌘A` 后正文多出一行，Undo、Redo、保存结果亦错误，
不将前次 869 项宿主绿灯等同 GUI 放行。
CodeGraph 核查发现 TextKit 2 不计算首段 `paragraphSpacingBefore`，
此前第一行删除 ghost 从 y=0 绘制，实际第一个原生段落也从 y=0 开始。
最小 `DiffFoldLiveMutationTests.testLeadingDeletionGhostNeverOverlapsEditableGlyphsAfterNewlineEdit`
先在完整字体／窗口设置下 Red：
`build/git-diff-leading-ghost-typography-red.log` 首行与追加换行时均 y=0。
修复为同一个原生文本容器在首行删除 ghost 存在时保留顶部间距；
只用现有 TextKit 的容器属性，统一调整共享行几何、只读 ghost 着色层和实际正文。
独立根因是 `NativeTextLineIndex.row` 将终止 LF 后的 EOF 位置钳回最后一行，
`DiffTextView.adjustLiveFoldSource` 误将独立追加判为修改最后一行并丢掉首行 ghost；
`build/git-diff-leading-ghost-live-edit-diagnosis.log` 确认首行 ghost 消失和顶部间距归零，
仅对 EOF 末尾 LF 后的零宽插入按新 Git 行处理，不修改全局行索引语义。
`build/git-diff-leading-ghost-eof-live-green.log` 两个根因合计 3 项、0 失败。
字号变化也曾保留旧高度（`build/git-diff-leading-ghost-font-red.log`）；
已在字号变化时重新应用同一个原生 ghost 段落布局，
`build/git-diff-leading-ghost-font-green.log` 2 项、0 失败。
真实 Bailey Dev 在修复后原样重跑同一失败 GUI 用例：
`build/git-diff-post-ghost-original-gui-red.log` **1 项通过**；
再运行全部 4 项 GUI 测试：
`build/git-diff-leading-ghost-full-gui-matrix.log` **4 项通过、0 失败**，
包含 `⌘A`、Undo/Redo 和 `⌘S` 的原文件字节核对、主题像素和查找替换。
原先一次 GUI 失败的键盘焦点因素是否另有环境偶发性，
不能仅凭两次通过断言永不复现；首行覆盖和 EOF 行身份有独立 Red→Green 证据。
最终同版本完整宿主套件：
`build/git-diff-leading-ghost-final-all-host.log` — `make test`
**870 项、16 项 SSH／环境条件跳过、0 失败，退出 0**；
`NativeDiffTabTests` **97 项、1 条件跳过、0 失败**。
额外使用真实 `NSWindow` 与 AppKit 第一个字符的
`firstRect(forCharacterRange:)` 验证底层字形确实位于删除行之后：
`build/git-diff-first-glyph-native-frame-check.log` — **1 项通过、0 失败**。
更新后真实 Bailey Dev GUI 捕获窗口原生截图：
`build/git-diff-p2t4-glyph-screenshot-gui.log` — **1 项通过、0 失败**；
原始结果：
`build/DerivedData-Dev/Logs/Test/Test-Bailey-UI-2026.11.06_20-15-06-+0800.xcresult`；
截图：`build/git-diff-p2t4-last-gui-attachments/2A6CBC2E-66BA-4D4E-8D31-C212409A90AC.png`。
红色旧行 `let value = 1` 与绿色工作区行 `let value = 2` 在真实
WindowServer 截图中各占一行，未重叠；保留 GUI 附件便于复审。
正式 `make build` 日志：`build/git-diff-p2t4-final-build-signed.log`，
`BUILD SUCCEEDED`，`codesign --verify --deep --strict` 退出 0。

**未覆盖和阶段限制：**
未配置 16 项真实远端 SSH／环境前提，仍需 P4-T3 实机验收；
WindowServer 截图只覆盖本次原生首行删除场景，主题和折叠像素依赖
前述已通过的宿主／GUI 矩阵，完整全组合仍由 P4-T2 核销；
20×24k／5MiB 长期进程 RSS 仍需 P4-T4；
P2-T1 的 24k 首帧与 100k 编辑预算为 No-Go，不因本次任务解锁。

**P2-T4 交付：**代码与当前功能文档已原子提交
`036873d5b216e7b946dc2385990fb1cc6f23e309`（未推送）。
使用经 `make build` 严格签名的完整 `/Applications/Bailey.app`
同磁盘暂存→整包替换→二次严格验签与可执行文件 SHA-256 比对，
安装退出 0，旧暂存包仅在验证完成后清理；未退出／启动／重启
已经运行的正式 Bailey（原进程 PID 67609，安装后仍运行旧进程）。
**正式 App 安装完成不等于在用进程已经加载新版：须由用户自主重启后生效。**

## P2-T5 — 真实 Git 浏览、Files 选区竞态与折叠 AX

**真实入口 Red：**
`build/git-diff-p2-t5-real-ui-selection-matrix.log` 的独立 Bailey Dev
覆盖 Git 预览、Files/Git/Graph/Palette 交接、右键、Shift/⌘ 多选、
Staged/Unstaged 与键盘操作。8 项中 7 项通过，1 项在 Files 已点击
A 后 ⌘点击 C 时未保持双选；随后取消 B 的右键仍失败，记录原样保留。
隔离单测的 `build/git-diff-p2-t5-files-selection-debug.log` 则可通过，
不能凭重试将首次问题认定为误报。

**真正失效的不变量：**
`WorkspaceWindowModel.autoRevealActiveFile` 会异步调用
`FileTreeModel.revealFile(automatically: true)`；它在读取目录真实路径、
文件 `stat` 和目录重建多个 `await` 后无条件 `select(item)`。
用户在后台读取期间作出的新多选会被旧 Auto Reveal 结果清空。
使用现有 `CountingFileBackend` 的可控 `stat` 延迟锁住旧请求，
用户在旧请求未完成时 ⌘加入 C，之后放行旧请求；
`build/git-diff-p2-t5-auto-reveal-selection-red2.log` 精确复现
selectedPaths 被重置且 Focus 指向旧 A，两项断言 Red。
修复位于唯一 Files 选区 owner：自动定位请求取出发前的游标及集合快照，
在真实路径读取完成前、执行目录可见性扩展前，以及最终选择前，
对照快照；新输入到来即拒绝旧自动定位，保留用户新选区。
显式 Reveal 的历史契约不受此检查影响；不增加第二套可写选区状态。
`build/git-diff-p2-t5-ax-stale-selection-final-targeted.log`：
旧请求取消、用户显式 Reveal、正在进行中的目录重建回归，
以及真实前置删除 ghost 下的 AX 帧定位／Press，**5 项通过、0 失败**。
`build/git-diff-p2-t5-real-ui-selection-green.log`：
修复后同样 **8 项真实 GUI，0 失败**；此前失败的跨 Files/Git/Graph/Palette
连续操作完整通过，并核对 Git Index/HEAD 和工作区字节。
`build/git-diff-p2-t5-real-fold-and-source-matrix.log`：
工作区实际折叠行鼠标点击、普通编辑区点击不触发展开、隐藏原文查找替换、
复杂真实 Git 源文件浏览与 clean filter，**3 项真实 GUI，0 失败**。
原生 `NativeDiffTabTests.testEditableFoldAccessibilityFrameMatchesActualClickAfterScrolling`
增加真实首行删除 ghost 和三组滚动偏移：检查可见 AX 元素数量、
按钮中心与原生折叠行一致，`accessibilityPerformPress()` 命中同一折叠范围，
实际工作区字符串不变。

**Changes 规模核验：**
P1 先前在真实 Git 仓库逐项核验 1／100／10,000 文件状态读取与 FSEvents，
但不将它冒充点击成本。P2 在 `GitStatusModelTests` 追加 30 次各规模的
合成可见行投影与模型选择计时，
`build/git-diff-p2-t5-model-selection-projection-scales.log`：
1 行投影／选区 P95 ≈0.001／0.005ms，100 行 ≈0.016／0.047ms，
10,000 行 ≈1.56／4.31ms；真实 App 选区/右键行行为由上述 GUI 验收。
该时间不包括 SwiftUI 的可见行构建、Git IO、Diff 创建和真实首次像素；
此前 P1 的真实完整 Diff 首帧仍为阶段独立 No-Go。
当前没有证据支持为 10k 普通选择重构状态 owner 或加入缓存链，
依计划不增加无必要实现。

**进一步追到与选区共用的用户交互：**
`FileTreeModel.select` 除更新 Focus/Selection，还会撤销
`contextMenuTargetPath` 与 `activeDrag`。仅比对当前游标／选区的第一版
会在后台 Auto Reveal 完成时清除其间由用户建立的右键目标和拖动，
但两者不必改变选区。
`build/git-diff-p2-t5-stale-menu-drag-red.log` 用同一真实 `stat` 延迟夹具
稳定复现：正在右键 B 和拖动 B 时，旧定位 A 覆盖 Context Target
并使该拖动 `consumeDrag` 失效（5 个断言 Red）。
首次相邻风险修复使用 Focus／压缩目录段／Selection／锚点／菜单目标／拖动 nonce 的
不可写局部快照，但发现 A→B→A 时选区快照会再次相等，仍可能执行已过期的旧定位。
最终收敛到 `FileTreeModel` 自身已有交互所有权：`interactionRevision` 在
选择、焦点、范围、菜单目标、拖动以及显式定位等用户动作中递增；后台自动定位在
每次异步返回后、目录展开前及最终选择前核对发起时版本。即使状态恢复到原样，
旧请求仍然失效。没有第二份选区／菜单／拖动可写状态，也不事后强制恢复。
`build/git-diff-p2-t5-async-interaction-owner-green.log`：
新旧自动定位、菜单取消、拖动有效性、显式 Reveal 组合 **4 项通过、0 失败**。
第一次扩大宿主回归（在该相邻风险修复前）：
`build/git-diff-p2-t5-affected-host-suites.log` **278 项、1 条件跳过、0 失败**。
最终交互版本的再验证：`build/git-diff-p2-t5-recheck-affected-host.log` 的
`make test:FileTreeTests,NativeDiffTabTests,NativeContentIdentityIntegrationTests,PanelContextTests,GitStatusModelTests`
**285 项、1 项授权 SSH 条件跳过、0 失败**；新增 10 万行原生布局实验也在同一次宿主回归中通过，
但布局性能仍归 P2-T1，不能借用本任务核销。
`build/git-diff-p2-t5-final-real-gui-recheck.log` 的最终 Bailey Dev 8 项真实 GUI
**全部通过**，覆盖原始 Files/Git/Graph/Palette 选区、焦点、Cmd-C 右键目标、
Escape 恢复和隐藏折叠内容替换与保存。
**最终全量宿主／构建：** `build/git-diff-p2-current-full-host-recheck.log`：
`make test` **879 项、16 项真实 SSH 授权条件跳过、0 失败，退出 0**；
`build/git-diff-p2-current-build-verify.log`：`make build` 成功，
`codesign --verify --deep --strict` 退出 0。
单一任务的 8 个关联文件由提交 `a9e41fc178ec9f48625526e477249913b602d01e`
原子收敛；`todo.toml` 和本证据文件保留为本地计划，不混入代码提交。
注意当前工作区仍有**独立 P2-T1 几何实验**，本轮测试／构建覆盖二者的组合，
不代表未提交 P2-T1 已完成全部首帧／折叠验收；因此没有替换正在使用的正式 Bailey。

## P2-T1 — 继续核查 10 万行布局原型与折叠首帧（进行中）

同一份最新工作区 `build/git-diff-p2-t5-recheck-affected-host.log` 中，
10 万行 LF 编辑视图 17 次远跳 P95 **2.65 ms**，10 万行只读视图
17 次远跳 P95 **2.60 ms**；首末行、真实 UTF-16 片段与光标命中已核对。
完整 `make test` 中 `NativeDiffTabTests.testNativeDiffInputCostsAndUndoByteIntegrityMatrix`
测得 10 万行 Swift 文件文首／文中／文末真实原生输入 P95
**1.17／1.54／1.33 ms**；文末单次最坏 **100.58 ms**，不能隐去。
相同回归的 Git 真源 24k 行 30 次热测：Staged 组件像素就绪
中位／P95 **236.5／314.0 ms**，Unstaged 中位／P95
**2075.7／2119.1 ms**（此值包含模型准备、原生装入和组件位图）。
因此当前仍有默认折叠 Unstaged 首帧 2 秒级阻塞，P2-T1 继续 No-Go；
源码 `DiffCodePaneView.layout` 在非固定 LF（包含折叠）仍执行
`ensureLayout(for: documentRange)`。暂不能将折叠首帧耗时全部归因于
这一调用，需补充同源分段测量与实际像素验证再修改，而非盲删全文布局。
特殊 Unicode 段落、长行折行、所有 fold+ghost 组合和 Release 实测也尚未全部核销。

**P2-T1 继续执行（2026-11-07，待最终验收）：**

- 已从源码和 `sample` 主线程堆栈确认：编辑态折叠使用
  `NSTextContentStorageDelegate.shouldEnumerate` 过滤隐藏段落，
  在深处滚动时 TextKit 仍枚举大量前缀；装饰层先前每次绘制又重复调用
  `layoutViewport()`，24k 首次像素在画面绘制部分约花 1.16 秒。
  同样文件改名为纯文本 `.txt` 的 30 次对照仍约 1.16 秒，
  排除了 Swift 语法高亮是本次主要原因。
- 正常 Git LF／CRLF 且未折行时，从现有 UTF-16 源行索引、隐藏行前缀和
  删除 ghost 坐标为原生 TextKit 片段设置固定行框，滚动条高度一次确认，
  视口只在剪裁边界实际变化时重新布局；直接定位目标源码行时核验局部
  原生段落，不再为每次导航全文布局。非 LF 原生段落／真实折行仍以
  TextKit 变高布局为真源，无旧路径备用镜像。
- 第一次修改折叠集合只通知布局缓存失效，导致某些展开后
  `viewportRange == nil`、末行不可达；反例日志
  `build/git-diff-p2-t1-original-fold-baseline-retest.log`。
  现用原始 `NSTextStorage.edited(.editedAttributes)` 从变化的首个折叠区间
  到 EOF 通知段落缓存、再重新排布；收窄到仅改变范围的局部通知
  会留下旧末尾段落，反例 `build/git-diff-p2-t1-changed-fold-invalidation-tests.log`。
- `shouldEnumerate` 不再为每个原生段落重复调用 Git 行号索引与
  折叠列表两次查询；折叠变化及活编辑时直接从同一个
  `NativeTextLineIndex` 生成 UTF-16 源范围，与实际原文和折叠状态同步。
  不保留基于前后相邻枚举的额外 cursor：它在 17 次交错跳转对照中
  没有证实进一步收益。
- 新测试直接比较实际视口文本／全局 Y／末行、17 次源码行跳转及
  17 次滚动条直接跳转；冷跳中位约 19.7 ms、P95 约 35.7 ms。
  `docs/testing.md` 的 32 ms 是 30 次**热视口**目标，
  冷跳只报告中位、P95、最差，不改验收门槛。
  对可编辑和只读 100k 文件的各 17 次真原生远跳及字符命中已验证。
- `NativeDiffTabTests.testRemovingBareCRWhileOtherNativeSeparatorsRemainUpdatesScrollExtent`
  先 Red：文件仍有其他裸 CR 时删除一个 CR，
  高度错误地保持 1215 pt，见 `build/git-diff-p2-t1-bare-cr-red.log`。
  根因是仅当布尔 `hasNativeNonLFSeparators` 改变才失效原生高度。
  对仍含原生分隔符且替换／删除可能更改段落数量的情况也通知
  同一布局 owner，`build/git-diff-p2-t1-bare-cr-green.log`
  的裸 CR 删除／Undo、CRLF 变为裸 CR 再 Undo、初始裸 CR 高度
  **3 项全部通过**；不为普通 LF 的每键编辑重新全篇扫描。
- `build/git-diff-p2-t1-related-regression-20261107.log`：原生 Diff、
  编辑器布局、Git/原生行索引及折叠实时修改共 **162 项，
  1 项因 SSH 前提跳过、0 失败**，Make 退出 0；
  24k 折叠 101 区间热视口 P95 **0.50 ms**，
  100k 编辑／只读远跳 P95 **2.72／2.92 ms**。
  100k Swift 真编辑文首／中／末 P95 约 **1.53／1.28／1.16 ms**。
  24k Unstaged Debug 30 次组件像素 P95 **928 ms**、
  Staged **308 ms**（多项测试混合负载），此前同一任务首次对照
  `build/git-diff-p2-t1-new-folded-first-frame-matrix.log` 为
  Unstaged P95 **2113 ms**；两轮负载不完全相同，不能称为严格 A/B。
- 全量宿主、签名构建、Release 同机对照和真实独立 Bailey Dev
  GUI 仍在本项终验范围内；正式 Bailey 未因本次实验被替换／重启。

### 2026-11-07：折叠冷视口反证与最新门禁

对照实验 `build/git-diff-p2-t1-fold-eager-prelayout-probe.log`：
先同步 `ensureLayout(documentRange)` 需额外 **200 ms**，但使 17 次冷跨区跳转
P95 **18.42 ms**；这是明确禁止的首屏全文预热，**不采用**。
将隐藏源码改成零高度 Fragment 的实验
`build/git-diff-p2-t1-zero-fragments-probe.log` 令源码行与末行定位失败，
已撤销实验实现，不计入成功路径。
独立 `build/git-diff-p2-t1-cold-direct-scroll-red.log` 在**任何源码行预热前**
将原生 `NSClipView` 直接滚到第 12,120 行，真实 `DiffRowGeometry.visibleRows`
无法命中目标，**稳定 Red**；该用例说明先运行 17 次显式 `scrollToRow`
再做直接滚动，可能以 TextKit 缓存掩盖真实冷视口问题。
`build/git-diff-p2-t1-related-regression-20261107.log` 的
`NativeDiffTabTests`、`DiffFoldLiveMutationTests`、`NativeEditorLayoutTests`、
`TextCoordinateIndexTests` 四组均通过，**不包含此后新增的冷视口断言**。
当前源码 `build/git-diff-p2-t1-current-build-check.log` 的 `make build`
退出 0，严格 `codesign` 校验通过；**构建成功不解除冷视口 No-Go**。
只有修复真实冷首次跳转并重跑适用矩阵、Release 与 GUI 像素，才能归档 P2-T1。
不得删除冷视口失败断言、预先扫描全文或靠偷偷预热使它转绿。

### 2026-11-07：冷视口目标段落归属的 Red→Green

`DiffCodePaneView.handleScrolled` 统一接收原生滚动条、源码定位和分栏同步滚动。
折叠固定 LF 片段虽已用真实 Git 行索引及删除 ghost 前缀固定 Y，
但未布局的 TextKit viewport 仍会按估计文本位置选错段落，
使首个未预热的远距离滚动条跳转显示其它源码。
现仅对大于一个视口的位移，用同一文档的准确可见 Y 二分定位源码行，
依据现有 UTF-16 行起点 `ensureLayout` 目标段落，然后布局本次 viewport；
普通小幅滚动不做全文排版，不建第二份编辑缓冲、不改变原始文本。
此前 `scrollToRow` 私自预热段落的重复分支已移除，恢复共同滚动所有者。

- `build/git-diff-p2-t1-cold-direct-scroll-red.log`：初次直接跳第 12,120 行失败；
  `build/git-diff-p2-t1-first-direct-deep-scroll-green.log`：同一断言通过，
  17 次折叠源码行定位中位 **18.31 ms**、P95 **35.16 ms**。
- `build/git-diff-p2-t1-common-viewport-owner-targeted.log`：4 个定点回归均通过；
  24k／101 折叠热视口几何 30 次 P95 **0.483 ms**，
  100k 未折叠编辑态 17 次远跳 P95 **2.763 ms**。
- `build/git-diff-p2-t1-scroll-style-targeted.log`：另一滚动条样式下冷跳断言通过，
  17 次源码导航 P95 **34.98 ms**。这些是 Debug 宿主结果，不是 GUI 真实首像素。
- 新增 `testHundredThousandLineFoldedColdScrollbarJumpsKeepSourceAndExtentAligned`：
  100k 原文、近 500 个折叠、未经显式源码定位预热的 17 次滚动条跨区跳转；
  同时检查原生源码片段、滚动高度及滑块比例。此处暂不记录未经运行确认的结果。

上一轮 `make test` 的 880 项、16 条条件跳过、1 项失败来自冷视口旧实现；
新的全量宿主测试及后续独立 Build、Release／GUI 首帧实测仍须按结果核销。
P2-T1 在这些门禁满足前保持 `in_progress`，不提前提交、安装或宣称完工。

### 2026-11-07：10 万行冷滚动、实时编辑源索引与首帧实测

- `build/git-diff-p2-t1-full-suite-final-20261107.log`：宿主 **881 项、16 项条件跳过、
  1 项失败**。所有 NativeDiffTab、文本布局、折叠及新增 10 万行冷远跳
  用例通过。唯一失败为 Files 的
  `testNativeLocalWatcherObservesAtomicRetargetOfSymlinkedProjectRoot`：
  符号链接重定向后，目标目录计数由 4 意外增加至 5；前次全量该项通过，
  随后的独立 `build/git-diff-p2-t1-files-watcher-isolation.log` 也通过
  （1 项，4.312 秒）。目前**只能说明非稳定复现，不能声称根因已消除**；
  不为让全量变绿而删除断言或改动无关 Files 代码。
- 同次全量 100k 原文、约 500 个折叠、17 次不相邻且未经预热的
  原生滚动条跳转，原生源码行与滚动高度、滑块比例始终正确：
  中位 **3.940 ms**、P95 **6.278 ms**、最差 **6.468 ms**。
- 进一步追踪 `DiffTextView.adjustLiveFoldSource`：普通行内编辑会更新
  当前 `foldedGitLines`，而 `DiffDecorations.editSnapshotOffsets` 在后台
  Diff 结果到达之前仍是旧快照。将首次深滚动目标段落的 UTF-16 偏移、
  变高段落导航和 `scrollToRow` 的编辑态偏移均归还给现有实时原文索引
  `liveGitOffset(forLine:)`；没有引入第二索引或对整篇预热。
  新增真正独立 TextKit 实例：先在第 0 行插入 8k UTF-16 字符，
  再直接跳转第 48,220 行，检查原生文本片段的**实际文字**及 Git 行坐标；
  `build/git-diff-p2-t1-live-source-owner-green.log` 通过，
  同组 17 次原始冷跳 P95 **5.995 ms**。
- 上次全量同机 24k 行／30 次热测：Staged Git 模型／原生就绪／组件像素
  P95 分别 **285.5／291.4／295.7 ms**，Unstaged 分别
  **400.9／818.8／884.2 ms**。
  Unstaged 数据就绪后至原生就绪仍额外约 **418 ms**，
  必须进一步分段分析源码安装、折叠失效和 TextKit 实际布局，
  不把此耗时归咎于 Git 模型；离屏组件像素不冒充 WindowServer 首像素。

上一版适用矩阵 `build/git-diff-p2-t1-post-live-index-full-suite-long-timeout.log`
已于 2026-11-07 02:14 通过：**881 项、16 项授权 SSH 条件跳过、0 失败**；
`make build` 与严格签名、`build/git-diff-p2-t1-release-check-20261107.log`
的 Release 构建及签名通过。随后按下述新发现继续根因修复，以上全量不冒充最新源码的最终门禁。

### 2026-11-07：删除占位共用坐标与旧展示快照覆盖实时索引

`DiffCodePaneView.fixedFragmentRow` 已用 `positionedGhosts` 的有序前缀二分；
但 `documentY` 每次冷滚动仍线性遍历 `ghostsByAnchor`，既有重复坐标算法也随删除块数量增加同步耗时。
将两者统一到 `displayRow(forSourceRow:)`，同一可见行／删除行规则供原生固定 Fragment、滚动条逆映射复用。
新添 100k 行、约 500 折叠及 **500 删除行占位块**、17 次未经预热远跳测试；
`build/git-diff-p2-t1-100k-ghosts-before-projection.log` 基线 P95 **6.410 ms**，
`build/git-diff-p2-t1-shared-ghost-projection-targeted.log` 修改后 P95 **5.656 ms**；
后者 6 项宿主全部通过，含开头／长块 ghost 和原始 cold fold。
仅把这组视为同机两次测量，不宣称完整 GUI 首帧已由此加速。

进一步将测试场景设置为：100k 文件开头插入 8,000 UTF-16 字符，
**再次收到仍带旧 `editSnapshotOffsets` 的展示版本**。
`build/git-diff-p2-t1-stale-fold-snapshot-red.log` 稳定 Red：
实时行偏移从正确的 **998,400** 被回退成 **990,400**，同时冷滚动源码行和真实文本命中失败。
根因：`DiffTextView.setEditingFolds` 在每次展示刷新时又基于旧行起点重建
`foldedGitLines`，违背实时编辑原文唯一真源。已移除此重建及全链调用参数，
只在 `setEditBufferText` 原文重载和原生编辑事件更新同一个 Git-LF 行索引；
删除仅由测试使用的 `NativeTextLineIndex(gitLineStarts:)` 生产入口，
测试转为直接检查正式 Git-LF 构造路径。

首次调整时 `build/git-diff-p2-t1-single-live-index-red-to-green.log`
又发现两个有证据的边界：TextKit 末尾 LF 多一个空段落，Git 行差异不计该空行；
展示版本更新但折叠未改变时，不得关闭固定行高 delegate 后漏掉重新激活。
修复后 `build/git-diff-p2-t1-single-live-index-and-terminal-green.log`
含实时编辑后冷跳、24k 末尾 LF、500 ghost、折叠修改共 **4 项 0 失败**。
最新 `build/git-diff-p2-t1-live-index-final-release.log` 通过 Release 构建和严格签名。

独立 Bailey Dev UI：`build/git-diff-p2-t1-real-gui-selected-20261107.log`
的 3 项真实 GUI 里折叠 Find/Replace 和 900 行显隐测试通过；编辑／Undo／保存
因**测试未输入前多出 `asd`，之后末尾 LF 丢失**两条断言失败。
随后 `build/git-diff-p2-t1-gui-edit-isolated-recheck.log` 同一 GUI 项独立运行 0 失败，
不能把一次转绿冒充已确认外部输入或产品根因；保留初次失败日志和焦点诊断缺口。

含新源码的完整 `make test` 正按
`build/git-diff-p2-t1-final-single-owner-full-suite-20261107.log` 执行；
后续受影响 GUI、Release 性能对比及主线程 Instruments 证据继续按实际结果核销。
P2-T1 在这些门禁满足前保持 `in_progress`，不提前提交、安装或宣称完工。

### 2026-11-07：修复 Git 源行与 TextKit 末尾空段落的计数边界

第一次在单一实时索引版本上执行的完整宿主测试
`build/git-diff-p2-t1-final-single-owner-full-suite-20261107.log`
显示 `DiffFoldLiveMutationTests.testRemovedRowGhostStaysOnItsSourceLineDuringLiveNewlineEdit`
失败：一个原本 **80** 行且带尾随 LF 的文件在中间插入 LF 后，
Diff 行数得到 **82**，而 Git 语义应该是 **81**。
原因是 `NativeTextLineIndex(.gitLF)` 仍为 TextKit 的末尾 LF 空段落保留一行；
之前为性能而去掉基于快照构造函数后，`applyLiveNativeEdit`
误把这个空段落计入真实 Diff 行，同时会在尾随 LF 增删时算错 `lineDelta`。

现在只维护一个原生可编辑 Git-LF 索引及**派生的 Git 源行数**：
初装从同一个索引减去末尾空段落；编辑前保留旧计数，
编辑后按新尾随 LF 重新计算，`lineDelta` 和行装饰只比较真正 Git 源行；
空文件仍保留一个原生可视占位行。修复不复制第二份文字、不重扫全文。
新增 `testLiveGitRowsExcludeTerminalEmptyParagraphAcrossEOFEdits`：
空文件、末尾 LF 添加／删除、EOF 续写、新行插入和全文删除共 8 组实际
`NSTextStorage` 变化，对照 `DiffLineSplitter` Git 源行与正文原文。
同时把 `testUnfoldedEditableDiffRowsTrackInsertedLFBeforeBackgroundProjection`
从原生含空段落的计数改为 Git 实际源行。
`build/git-diff-p2-t1-real-git-lf-source-count-targeted.log`：
DiffFoldLiveMutationTests **6/6**、原生折叠远跳 **3/3**，合计 **9 项 0 失败**。
上一全量是有已定位缺陷的旧二进制，已精确停止自己启动的测试进程树，
未干扰正式 Bailey 或用户任务。
最终版全量宿主测试正在
`build/git-diff-p2-t1-final-source-git-lf-full-suite-20261107.log` 执行；
完整退出、Release 对照、GUI 和 Instruments 仍以实际结果为准。

### 2026-11-07：10 万行输入与结构性编辑的重复全文派生

`build/git-diff-p2-t1-final-source-git-lf-full-suite-20261107.log`
已在 02:59 最终完成：`make test` **883 项执行／16 条授权 SSH 条件跳过／0 失败，退出 0**。
此前 100k TXT／Swift 末尾普通输入各 30 次 P95 **88.65／88.43 ms**，
根因是末尾新建 Git 行会让 `applyLiveNativeEdit` 为整份文档重建行装饰与
100k UTF-16 起点。删除此实时回调中的全文索引物化，行位置统一由
`liveGitOffset(forLine:)` 查询，
`build/git-diff-p2-t1-incremental-decoration-input-green.log` 相同输入矩阵
P95 降至 **13.00／12.94 ms**，正文、Undo／保存字节回归通过。
其后经 CodeGraph 与全仓调用检索确认生产端已不再读取 `editSnapshotOffsets`，
故删除该过期偏移数组及持续复制；需要断言源码行偏移的测试改查实时
`liveGitOffset(forLine:)`，不保留仅为旧测试服务的生产状态。

另建 100k／约 500 折叠／500 删除行占位真实 `insertText` 结构性编辑夹具，
每个位置 30 次 LF 插入与精确删除；
`build/git-diff-p2-t1-100k-structural-multi-ghost-regression.log` 显示
文首／中部／尾端总输入 P95 **83.89／55.44／27.61 ms**，
`build/git-diff-p2-t1-structural-callback-breakdown-before.log` 进一步量得
其中 Diff 回调 P95 **71.21／43.27／15.25 ms**。
先移除固定 LF 已采用虚拟删除行时仍逐段设置原生段落 style 的重复写入，
保留裸 CR／Unicode／折行测量路径；
再将行装饰更新改成按原始/新正文实际变更区间 `replaceSubrange`，
不再逐行重建未受影响的整篇后缀。工作区高亮区间改为行内相对 UTF-16，
绘制时由实时索引补全绝对偏移；行号同样使用真实可见行，避免旧 `.newLine`。
`build/git-diff-p2-t1-structural-splice-row-emphasis-first-pass.log`：
全部 11 项通过，同一 100k／500 fold／500 ghost 结构编辑 P95
**27.74／27.75／25.97 ms**；原文、折叠、删除 anchor、着色像素校验通过。

新增 LF→裸 CR→LF 间距切换与编辑前方新增行后强调仍匹配真实源码字符的两项回归。
前者 `build/git-diff-p2-t1-cr-transition-and-relative-emphasis-red.log` 稳定 Red：
原生段落布局已改变但实时行数没有变，旧编辑回调因 `lineDelta==0`
跳过了删除行段落间距刷新。改由 `onNativeParagraphGeometryChanged`
记录本次需求，并在原生编辑更新唯一 Git-LF 索引**之后**刷新间距；
`build/git-diff-p2-t1-cr-transition-and-relative-emphasis-green.log`
这两项及原生 CR 和 100k 编辑回归 **4 项均通过**，
100k 结构编辑 P95 **31.08／29.03／25.84 ms**，未增设第二布局所有者。

最新代码正在执行完整 `make test`：
`build/git-diff-p2-t1-post-incremental-full-suite-20261107.log`。
此后的独立 Release/Debug 签名、实际 Bailey Dev GUI 和 Instruments CPU／首帧仍未核销；
不能用已通过的旧版 883 项或离屏位图冒充最新完整验收。

### 2026-11-07：完整回归揭示新旧来源的布局归属问题

`build/git-diff-p2-t1-post-incremental-full-suite-20261107.log`
在 `NativeDiffTabTests` 发现两项失败后，已精确终止该轮旧二进制全量测试，
避免继续消耗测试窗口。`testDeletingEveryEditLineKeepsEOFRemovalGhostScrollAccessible`
暴露全文 `setEditBufferText` 替换后**旧文件 EOF 删除占位仍被用于新原文高度**：
此前存在的快照起点计数偶然掩盖了过期状态；移除该冗余字段后问题显现。
根因修复：新来源安装前清除旧文档装饰、折叠与展示版本，
恢复原生段落间距并重建唯一实时索引；同版本号的下一文件仍能正确首展。
新增 `testNewSourceRetiresOldFoldsGhostsAndPresentationRevision` 逐项验证。

`testDiffLongLineWidthModesPreserveEditGhostsAndReviewText` 的旧断言
误将固定 LF 应有的虚拟删除行要求成 NSTextStorage 段落前距；
改为同时验证固定 LF 间距为零、可见删除块锚点不移动、
完整折行时原生间距正确增加及恢复，保留原字节／宽度／原生 Fragment 断言。
`build/git-diff-p2-t1-source-ownership-ghost-behavior-green.log`
共 14 项绿色，100k 500折叠/500ghost结构输入 P95
**29.88／29.11／26.75 ms**；
`build/git-diff-p2-t1-full-source-ownership-targeted.log` 追加新的来源/版本
回归及两项旧失败，共 **3 项 0 失败**。
最新独立首帧阶段计时在 `build/git-diff-p2-t1-firstframe-native-phase-20261107.log` 执行，
仍待用最新产品源码重新完成全量 make test 与 Release/GUI 核验。

### 2026-11-07：TextKit 隐藏元素枚举的根因与优化

独立 24k LF／仅两处变更的真实 Git 夹具 30 次热测证明，首次展示
`DiffNativeSurface.layout` 中 `pane.layoutSubtreeIfNeeded()` 约 **200 ms**，
首次 `scrollToRow(11998)` 另约 **52 ms**；虽然滚动偏移仅 6 pt，
实际可视源行集合包含 11998–12005，新增断言逐次确认第一处变更
第 12001 行首帧即有真实 TextKit Fragment，没有所谓空屏或先展开后折叠。
`build/git-diff-p2-t1-first-change-true-visibility.log` 30 次全部通过。

对 Bailey Dev 同一测试进程采集 Time Profiler：
`build/git-diff-p2-t1-unstaged-firstframe-cpu.trace`，导出表
`build/git-diff-p2-t1-time-profile.xml`，主线程 10940 个样本中
44.4% 的调用栈包含 `NSTextContentStorage.enumerateTextElementsFromLocation`，
37.3% 包含 `NSTextViewportLayoutController.layoutViewport`（包含关系，不能相加）。
直接根因是旧 `NSTextContentStorageDelegate.shouldEnumerate` 逐段返回 false：
即便 24k 文件只剩 9 个可见行，TextKit 仍要访问上万隐藏段落。

当前 SDK `NSTextElementProvider.enumerateTextElements(from:options:using:)`
明确允许“skip a range / hide some elements from the layout”。
独立原生小程序 `build/git-diff-p2-t1-fast-enumerator-probe.swift` 已验证
同一 `NSTextContentStorage` 子类可在保留原文坐标的同时，正向／反向
只返回未隐藏的真实原生元素。产品以单一 `FoldedDiffContentStorage`
替代逐段 delegate 过滤，折叠边界由 Git 行索引派生，保留裸 CR／Unicode
同一 Git 行只显示首个原生段落的语义。没有第二份可写字符串／缓存文档，
仍由一个原生 LayoutManager 展示。

`build/git-diff-p2-t1-fast-fold-native-enumeration-second-pass.log`：
5 项原生 cold jump／100k 大折叠／ghost／裸 CR 均通过；
`build/git-diff-p2-t1-fold-enumeration-coverage-render-phase.log`：
新的前后双向和隐藏内部起始枚举测试通过。30 次同构 Git 夹具
`build/git-diff-p2-t1-fast-fold-enumeration-firstframe-30-samples.log`：
24k Unstaged 原生就绪 P95 **833.51→560.34 ms**，
组件位图 P95 **899.12→564.86 ms**；
独立首次布局准备 **约 200→73 ms**、首变更定位 **约 52→0.3 ms**，
布局整体 **约 300→74 ms**、组件栅格绘制 **约 65→4.5 ms**。
同机不同轮的 Git 模型本身仍有抖动，必须分辨模型 P95 与原生阶段收益。
额外子段计时证明 `loadSourceText` 首装约 **109 ms**，折叠应用仅约
**0.5 ms**；这部分包含安装真实正文和原生语法处理，没有移到异步刷新。

对照否决尝试：关闭 `NSTextView.isVerticallyResizable` 的
`build/git-diff-p2-t1-native-fixed-height-autoresize-probe.log`
未降低约 300 ms，已撤销，不保留补丁。
当前受影响宿主全集仍在 `build/git-diff-p2-t1-fast-fold-all-affected-host-tests.log`
验证；已确认一处旧测试仍期待固定 LF 使用非零 `paragraphSpacingBefore`，
已改为检查虚拟 ghost 锚点、总高度和截断样式，需最新编译重测。
P2-T1 在全量构建、GUI 与 Release 实证前仍为 `in_progress`。

### 2026-11-07：完整 make test 报告揭露 Direct DiffTextView 构造崩溃

`build/git-diff-p2-t1-fast-fold-final-full-host-suite-20261107.log`
虽然最后一轮宿主进程的 797 项显示零断言失败，但 **`make test` 退出 65**；
原始 `Test-Bailey-2026.11.07_11-04-16-+0800.xcresult` 汇总为
**871 passed / 16 skipped / 1 failed（Crash）**，不能报作全绿。
通过 `xcresulttool get test-results test-details/activities` 和
`xcresulttool export attachments` 获得原生
`build/git-diff-p2-t1-crash-attachments/*.ips`：
SIGABRT 栈为 `swift_dynamicCastClassUnconditionalImpl →
DiffTextView.rebuildFoldedUTF16Ranges → setEditingFolds`，
发生在 `DiffFoldLiveMutationTests.testReplacingHiddenSourceKeepsUnrelatedContextCollapsedDuringDebounce`。
根因是宿主及无障碍测试直接构造 `DiffTextView()` 仍使用父类缺省
`NSTextContentStorage`，而真实 `DiffCodePaneView` 才注入新的
`FoldedDiffContentStorage`；强转因此崩溃。
现已在**文本视图的默认构造入口**提供正确存储，删除外围显式注入；
`build/git-diff-p2-t1-default-diff-storage-crash-root-green.log` 验证
原崩溃回归、正反向隐藏枚举、100k 冷滚动、无障碍写保护 4 项通过，
完整 `make test` 尚需在此代码上重跑并核对完整退出状态。
另经 CodeGraph 确认只为旧逐段 Delegate 实现服务的
`testTextKitContentDelegateCanCollapseLayoutWithoutChangingEditableStorage`
已由当前 `testFoldedTextKitEnumeratesOnlyVisibleSourceInBothDirections` 的正式
生产路径覆盖，故移除过期 Delegate 夹具；`docs/features/diff.md`
遗留的 Delegate 说明已更新为真正的区间枚举。
正式 Bailey 未退出、重启或替换。

### 2026-11-07：P2-T1 最终构建／原生性能与 GUI 边界

新默认内容存储入口后，完整 `make test` 日志
`build/git-diff-p2-t1-fast-fold-final-no-crash-full-suite-20261107.log`
实际退出 **0**；XCTest **887 项，16 项条件跳过，0 失败**；
`xcresulttool` 直接核对
`build/git-diff-p2-t1-fast-fold-xcresult-final-summary.json` 为
`result: Passed / passedTests:871 / failedTests:0 / skippedTests:16`。
`make build` 日志 `build/git-diff-p2-t1-fast-fold-final-debug-build.log`
以及 `make build:release` 日志 `build/git-diff-p2-t1-release-final.log`
均为 **BUILD SUCCEEDED**，内含 Apple Development 签名和
`codesign --verify --deep --strict` 成功；Release 编译来自同一源状态。
Release 本轮仍只编译／验签，不代表完成 Release 真实 GUI 帧测。

这轮全量的 24k Unstaged 30 次热测组件像素 P95 **602.90 ms**、
原生就绪 P95 **598.54 ms**（模型阶段 P95 **409.96 ms**），
对照原实现组件 P95 约 **899.12 ms**，总量改善约三分之一；
100k／500 折叠的 17 次未预热深跳 P95 **3.64 ms**，
加 500 ghost 后 P95 **3.79 ms**，
100k 结构性文首／中／尾修改 P95 **29.61／28.72／27.03 ms**。
所有这些数值均为宿主原生组件／编辑基准，不冒充真实窗口首个像素。

`make test:ui ONLY_TESTING='BaileyUITests/WorkspaceGitUITests BaileyUITests/GitHistoryUITests'`
在 `build/git-diff-p2-t1-real-dev-gui-full-git-20261107.log`
执行 **14 项，WorkspaceGitUITests 8 通过／1 条 SSH 环境跳过／0 失败**：
工作区真实文件修改保存、撤销恢复、CRLF、Git clean、折叠中 Find Replace、
900 行可视文本和手动展开、主题切换重绘、关闭重开都通过。
但 **整条 GUI 命令退出 65（失败）**：历史 Git 的 5 项全失败，
其中首次冷启动没有出现 `bailey.dock.files`；其余 4 项历史行已真实出现在
AX 树中，但右键后预期菜单项不可见，XCUITest 伴随
`DisplayManager: Could not find any displays containing rect (inf, inf, 0.0, 0.0)`。
确认 `RecentCommitsView.changedFile` 仍声明这些上下文菜单动作；
本轮 P2-T1 改动未触及其行、菜单或运行环境，**暂未证实是产品动作失败还是 GUI 事件合成失败**。
不能把 8 条工作区 GUI 转绿冒充整套 UI 通过，也不能用重复运行忽略失败。
本轮不为了这一未归因的历史右键问题修改无关菜单或增加超时重试；
保存失败证据供 GUI 交互归属任务审查，必要时在独立窗口复测右键真实触发与外部 Git 字节。
正式 Bailey 在这轮构建／测试中保持运行，没有被测试 App 替换或重启。

