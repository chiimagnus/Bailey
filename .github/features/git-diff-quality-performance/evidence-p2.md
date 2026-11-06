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

