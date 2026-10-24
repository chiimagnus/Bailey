# P2 · 减少重复的完整 App UI 测试

**Goal:** 用 `BaileyTests` 承担全部可独立验证的逻辑、数据、异常及原生组件合同；仅留真正需要完整 `BaileyUITests` App 的用户入口。原 133 项 UI 分别为 Git Dialog 21、Graph/Geometry 45、其它 67。

**共同门槛:** 每个准备删除的 UI 方法先逐断言核对宿主与保留的 UI 双重证据；缺口先补宿主测试，再删旧 UI 及无消费者的 helper。不能用 `XCTSkip`、巨型合并脚本、减少实际断言或固定数量指标冒充精简。保留所有必要的危险操作确认、窗口焦点及真实系统结果。

<a id="p2-t1"></a>

## P2-T1 Git Dialog：表单与真实 Git 的重复验证移至宿主

**Files:** `BaileyUITests/Git/GitDialogUITests.swift`、`BaileyTests/Git/`、`BaileyTests/Remote/GitInteractiveRebaseIntegrationTests.swift`。

逐项检查 21 项 UI 的表单默认／启停、Ref/OID 竞态、取消重试与实际 Git 结果。原生 AppKit 控件和真实临时 Git/bare remote 由宿主 XCTest 覆盖；完整 UI 只验证不可替代的菜单→Sheet→前台窗口→用户确认及结果。保留不同 Branch/Tag 危险操作、旧 Stash Pop、Commit Drop、真实 PTY、跨窗实际切焦点与 Remote 目标。删除真正重复的 UI 和其 helper，不只删几次点击。

**验收:** 受影响宿主测试、真正保留的完整 App GUI 定点通过；记录 21 项方法的去向、减少的 App 启动、真实 Git/文件后置状态与未测边界。一个代码提交。

<a id="p2-t2"></a>

## P2-T2 Git Graph：消除重复的六点点击和密集初始化

**Files:** `BaileyUITests/Git/GitGraphGeometryUITests.swift`、`GitGraphUITests.swift`；`BaileyTests/Git/` 相应几何／引用／颜色测试。

原 `verifyDivider` 在不同宽度、字号、主题和 Worktree 下反复做六点 Commit 点击；仅一条 GUI 基准检查完整点击/展开，宽度／lane 等数据由宿主覆盖。原 `verifyDenseGraph` 反复创建 24-lane 仓库和滚动，保留必要的一条真实图谱密集路径。明暗真实像素、Tree/List 命中、中文长标签、多级菜单、历史 Merge/Diff/分页和键盘焦点等原生差异不能仅由宿主算法替代。

**验收:** 受影响宿主测试与必要 GUI 定点通过；原 45 项的逐项保留／删除与减少的点击、初始化、App 启动有实际证据。一个代码提交。

<a id="p2-t3"></a>

## P2-T3 其余 67 项 UI：只保留独有用户入口

**Files:** `BaileyUITests` 其余 Git Changes/History、Files/Editor、Workspace 用例与 `BaileyTests/{Git,Files,Editor,Workspace,Remote}/` 对应宿主类。

已可由宿主验证的 Git index/ref、文件字节、解析/Undo、模型状态和原生视图边界不再反复启动 App。保留不同 Stage/Unstage 入口、系统 Finder/Picker、实际 TextKit/IME/保存、原生颜色、跨窗口、WebKit/Ghostty 文件交接和关闭／恢复。逐项核对独有断言，确认替代后删除重复 UI 及失效 helper。

**验收:** 原 133 项 UI 均有去向，按受影响类定点测试、必要全量构建/签名和独立 CI 验收分别报告；不因 P1 目录整理通过就宣称 P2 成功。一个代码提交。

## Phase Audit

完整 App 的实际启动与交互次数应有可核查的减少，且所有唯一系统行为和安全验证均保留；不设 Unit/Integration 方法数量或比例门槛。
