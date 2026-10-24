# P3 · Git UI：完整 App 只证明接线、命中和原生行为

**Goal:** 在 P1/P2 已验证的 Unit + 真 Git/AppKit Integration 上，把 Git Dialog **21**、Graph/Geometry **45** 共 **66** 个完整 App UI 方法精简为约 **15–25** 条真正独有的用户流程。目标不是安全删减的豁免条款。

**Non-goals:** 不合并成超长脚本、不跳过测试、不改弱危险确认；系统焦点、真实 Sheet/菜单、实际 Git 结果无法被 Unit 冒充。

**共同 Gate:** **P1/P2 必须已使 Unit 成为主要测试层，并实质缩减 Integration**；若仍是 86/463 式倒金字塔，不能通过先删 UI 来宣布整体重建成功。每条准备删的 UI 都须有已验证的最低层规则/实际副作用 **加** 保留的真实 App 用户入口，逐项核对原有 XCTAssert、取消/确认、窗口归属和结果。P2 的缺口先回 P2 修复。同 task 删除废弃方法、辅助代码与误导性的 selector，不能以只减少几次 click 宣称完成。

---

<a id="p3-t1"></a>

## P3-T1 Git Dialog：压缩重复后台 Git/表单组合

**Files:** BaileyUITests/Git/GitDialogUITests.swift；P1 的原生 AppKit 表单合同、P2 的 GitBranch/Tag/Stash/Commit/RemoteBranchActionTests。只读核对 GitPanel 的 presentBranchCreate、presentTagCreate、presentBranchAction、presentTagAction、presentRemoteCheckoutDialog 和真实 GitStatusModel 操作。

**Steps:**
1. 把 21 项原 XCTAssert 拆为：①原生 NSAlert 输入、按钮、初始选择（P1 AppKit Integration）；②真实 Ref/OID/index、冲突、Force、取消/重试（P2 真实 Git）；③必须由完整 Bailey Dev 验证的菜单→Sheet→前台窗口→用户动作→最终结果。原生控件层与真 Git 操作层已经证明的矩阵不再经 App 重演。
2. 优先逐项核销 testCurrentBranchNativeSheetDefaultsToCheckoutAndPreservesGitBytes、testStashNativeApplyDropAndBranchUseSelectedOlderEntry、testRemoteFetchRejectsMovedLocalDestinationThenAllowsFreshForceAndFastForward、testHistoricalCommitNativeSheetsUseSafeDefaultsAndCheckoutRealHistory、testTagPushWithoutRemoteCannotSubmitOrWriteRepository、testBranchDeleteDefaultsPreserveRemoteAndCancelIsNoOp。**Branch 与 Tag 二次旧 OID 竞态不是同一事件**，替代不全则保留唯一原生用户决策；不可只以低层重试成功就删除 Sheet 的异常回填。
3. 优先留存跨层独有家族：历史 Branch/Tag 创建/注释、晚到 Ref 冲突选择、真实 Branch 菜单、远端 Checkout/Fetch/Pull/Push 目标、旧 Stash Pop、危险 Drop、Graph→Terminal PTY 交互 Rebase、双窗焦点隔离。不同 Branch/Tag 的无 remote 原生禁用必须在 P1 各自得到验证。
4. 双窗旧测试仅创建了第二个窗口，**未真正让它成为 key window**；留存用例必须在 Sheet 打开后真实激活另一窗口再确认原仓库的 Sheet/HEAD/文件、检查未串窗。不能引入新的全局焦点管理器。
5. 确证等价后删除旧 UI 和已失消费者 helper；只在实际稳定测试职责改变时同步 docs/testing.md，不碰产品安全机制。

**Verify:** 定点 make test:GitDialogComponentTests,GitBranchActionTests,GitRemoteBranchActionTests,GitTagActionTests,GitStashActionTests,GitCommitActionTests；再在独立 Dev/独占图形会话运行受影响的保留 GUI 选择器，核验 Xcode 真发现数、Sheet、前台焦点、不同 bare remote、旧 Stash OID、PTY 和真实 HEAD/index/文件。空/非法/中文名称、SHA-1/256、旧 Ref、0/1/N remote、拒写与恢复的矩阵在低层全部执行，不再每种配置重启 App。不能用 XCTest skip 或重复调时掩盖环境故障。

**Commit:** 一个代码提交；报告原 21→实际数及完整 App 启动的实际减少量。

<a id="p3-t2"></a>

## P3-T2 Git Graph Geometry：六点点击只验证一次

**Files:** BaileyUITests/Git/GitGraphGeometryUITests.swift；Unit/Git/CommitGraphLayoutTests.swift、GitGraphPaletteTests.swift、GitGraphReferenceGroupTests.swift、GitGraphWorktreePresentationTests.swift。

**Steps:**
1. 原 verifyDivider 被 **11 项** UI 重复调用，每项执行五档宽度、每档右键且点击 Commit 六处，合计约 **330 次同类展开点击**。保留唯一 150pt 窄栏“六处点击→展开/折叠”基准 E2E；一次做宽/窄/回拉拖动和一次真正的 Branch 原生菜单检查，核对文件行、HEAD/index 未变。其它字号/主题/Worktree 测试不再重复点击。
2. CommitGraphRails.spacing/gutter 的 0/1/2/12/24/30/150 lane × 9/14/18pt/面板宽度计算由已有 Unit 覆盖；GUI 只补明暗实际像素、Tree/List 持续选择填充、长中文标签、1/12 共享 HEAD worktree 的**独有原生差异**，不再做 theme×font×worktree 的乘积拖动。不能用 Unit 颜色常数冒充像素。
3. Overflow 的 33 个远端引用、三层 Worktree 菜单、刷新前后真实菜单目标不可被算法 Unit 替代。逐项核销后删除重复 Geometry UI 和无用 fixture/screenshot/helper，不保留兼容空方法。

**Verify:** make test:CommitGraphLayoutTests,GitGraphPaletteTests,GitGraphReferenceGroupTests,GitGraphWorktreePresentationTests；只对改变过的真实六点、明暗像素、Tree/List、worktree 极端/菜单进行定点 make test:ui。记录 20→实际 UI 数、330→实际点击数，实体触控板和不同显示缩放缺位时单独标明影响。无需每次截图上传 PR。

**Commit:** 一个可独立回归的代码提交。

<a id="p3-t3"></a>

## P3-T3 Git Graph History：重复 24-lane 和引用枚举退回低层

**Files:** BaileyUITests/Git/GitGraphUITests.swift；Unit/Git/CommitGraphLayoutTests.swift；Integration/Git/GitStatusModelTests.swift、NativeGitHistoryFileTests.swift。

**Steps:**
1. verifyDenseGraph 由 **5 项** UI 调用，分别重建 24 条 lane、四档宽度和横滚四次。只保留一次真实密集图谱宽度往返和一次标题横滚，必要的最小/最大字号只检查其独有可见性；30/150 lane、5,000 commit 和引用颜色用已有 Unit/真 Git 证明。
2. testGraphBadgeTitleNodeAndMetadataToggleTheSameRealCommit 与 P3-T2 六点触发展开属于同类系统行为，应只保留**一条**全量节点/标题/空白点击闭环。中文菜单测试只测本地化菜单标题和剪贴板结果，不能再重复英文节点点击矩阵。
3. 保留不同真实用户路径：分页、两父 Merge 的文件 Diff、真实 Stash/Detached、Worktree 三层菜单、符号远端禁用项、键盘焦点、中文长路径横滚、staged/working Diff。对应数据的纯拓扑/Ref/OID/状态矩阵不重复由 App 枚举；每删一项核对原有断言与留存路径，同 task 删旧 helper。

**Verify:** 受影响的 Unit/Integration 定点 make test:CommitGraphLayoutTests,GitStatusModelTests,NativeGitHistoryFileTests；GUI 仅测实际修改的密集图谱、中文菜单、分页/Worktree 原生入口。比较 Graph 原 25 个方法的实际剩余数、lane 初始化和横滚次数；逐项列出空仓库、中文/超长路径、明暗/字号、30/150 lane、Worktree、多 Ref 的责任层。make test:ui 已自带构建，不再机械重复 make build:ui。

**Commit:** 单独一个代码提交。

## Phase Audit

audit-p3.md 逐项核销 21+20+25 个旧方法：保留/删除、Unit/Integration 证据、剩余完整 App 入口与本次运行结果；数字未有实际删减或原生危险合同退化则 No-Go。P3 的局部 Go 不代表 CI 和 P4 完成。
