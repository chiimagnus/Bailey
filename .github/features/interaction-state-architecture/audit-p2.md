# Audit P2 - interaction-state-architecture

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/interaction-state-architecture/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 收敛 Files 浏览与打开事件链
- [x] P2-T2 收敛 Files 系统 Edit 与右键操作目标
- [x] P2-T3 核验原生菜单生命周期并清理旧路径
- [x] P2-T4 统一文件选择与 Finder 内外拖放目标
- [x] P2-T5 统一文件浏览与原生焦点恢复

## 任务到文件的映射

- P2-T1：`FileTreeModel.revealFile`、`WorkspaceWindowModel` 的活动文件同步、
  `Project.selectTab`、`FileTreePanel` 的浏览与展示；`docs/features/files.md`、
  `docs/features/dock.md`。提交 `4dd9ad83`（含 `f4feb729` 对应历史）。
- P2-T2：`FileTreeModel.selectedOperationPaths/selectForContextMenu`、
  `FileTreePanel` 菜单与系统 Edit、`TreeKeyboardView`、
  `WorkspaceWindowModel.performFileTreeCommand`；`SharedTreeUITests`、
  `WorkspaceFilesUITests`。提交 `8fe95df`、`dd79095f`、`88ccd4d`。
- P2-T3：`ContextMenuClickView` 的 NSMenu 跟踪、`WorkspaceDockView` 的
  右键目标及菜单快捷键、`WorkspaceWindowModel.closeActivePanelOrWindow`；
  `WorkspaceDockUITests`、`docs/ui.md`、`docs/features/dock.md`。
  提交 `3b9c60d`、`d832f485`、`0823fdf`。
- P2-T4：`FileTreeModel.beginDrag/consumeDrag`、
  `FileTreeNativeDragView`、`FileTreePanel`、`ToolPanelView`、
  `WorkspaceWindowModel.receiveFileTreeDrop/performFileTreeCommand`；
  `WindowOwnershipIntegrationTests`、`WorkspaceFilesUITests`、
  `docs/features/files.md`。提交 `f73f3f0`、`8cef05f`。
- P2-T5：`WorkspaceWindowModel.registerTreeResponder/registeredToolResponder`、
  Files/Git `TreeKeyboardHost`、`DockFocusIntegrationTests`；
  `docs/architecture.md`、`docs/features/dock.md`。提交 `b9d1b2f`.

## 逐任务源码与提交核验

- **T1**：`4dd9ad83` 与当前分支 `f4feb729` 的稳定 Patch-ID 相同。
  `DockWorkspaceModel.onActiveItemChange → WorkspaceWindowModel.autoRevealActiveFile → FileTreeModel.revealFile`
  已接入实际活动文件切换；切换身份、关闭、重连与树节点缺失按真实目标校验；不触发编辑器焦点交接。
  `currentFilePath` 仍用于树首次聚焦，不能作为死代码删除。
- **T2**：`8fe95df5` 与当前分支 `dd79095f` 补丁相同，后续 `88ccd4d1` 修复 GUI 测试入口。
  `FileTreeModel` 的 Focus/Selection/Context 传至原生菜单与系统 Edit，最终通过
  `WorkspaceWindowModel.performFileTreeCommand → FileTreeModel.performFileOperation`
  落到本机或 SSH 文件后端；右键选择范围不依赖编辑器展示文件。
- **T3**：`3b9c60dd` 与当前分支 `d832f485` 补丁相同，`0823fdf2` 修正菜单 Cmd-W 路由。
  `WorkspaceDockView → ContextMenuClickTarget → WorkspaceWindowModel.closePanel → Project.close`
  真实贯通。发现直接 Close 对未消失标签遗留旧目标（F-01）；已收敛消费入口。
  另删除 66 行与 Escape 契约相悖的重复 GUI 用例（F-02）。
- **T4**：`f73f3f0e` 实现、`8cef05ff` 修复 Control-click、`0a1bcc18` 增加紧凑祖先段回归。
  `FileTreeNativeDragView → FileTreeModel.beginDrag/consumeDrag → WorkspaceWindowModel.receiveFileTreeDrop`
  到既有文件操作后端；本机多选逐项发布 Finder URL，SSH 仅发布进程私有数据。
  旧单 Provider `.onDrag` 路线已删除；未发现另一条可达的重复实现。
- **T5**：`b9d1b2fe` 接入 Files/Git 实际挂载的 `TreeKeyboardHost` 与窗口登记，
  由当前 Dock、窗口与第一响应者判定恢复目标；不再整窗遍历视图查找焦点。
  命令面板、原生输入框和编辑器的焦点优先级保留。

以上是本轮独立检查源码与补丁所得；已有历史审计结论不作为证据。

## 发现项

## 发现 F-04

- 任务：`P2-T5`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Files/SharedTreeUITests.swift:114-150; BaileyUITests/Files/WorkspaceFilesUITests.swift:656-686`
- 摘要：`部分完整 GUI 终端输入回归出现 Shell 命令拼接，尚未确认是 XCUITest 还是真实 PTY 缓冲问题`
- 风险：`SharedTreeUITests.testContextMenuCommandCCopiesFileWithoutStealingTerminalFocus 在独立执行时多次未生成命令预期标记；原生日志证明 Cmd-C 菜单前后 firstResponder 仍为 BaileyTerminalView，之后文字和 Return 的 keyDown 也发送到终端；测试截图显示不同测试会话的命令片段拼在同一 Shell 行并生成不存在文件名。另有同类 GUI 测试连续执行时出现瞬态 AX 焦点、临时 Dev 进程归属失败。不能冒充所有输入路径已通过。`
- 预期修复：`独立检查 Ghostty PTY Ready/缓冲以及 XCTest 合成事件、输入法与 Runner 沙盒临时路径可达性，先证明命令在干净 Shell 中的最终字节与副作用，再在最小拥有者修复；禁止增加猜测性重试、延时或全局监听。`
- 验证：`多次 XCUITest 原样复现：/tmp/bailey-p2-shortcuts-ordered.log、/tmp/bailey-p2-terminal-focus-green.log、/tmp/bailey-p2-focus-event-diagnostic2.log、/tmp/bailey-p2-focus-screenshot.log；本轮未发现生产 firstResponder 丢失，未修改 Ghostty 生产逻辑，临时 P2FOCUS NSLog 已全数清除。`
- 解决证据：`实际根因是 UI 测试 App 的 HOME 已隔离但 Zsh 仍可加载宿主交互插件／共享命令历史，产生 Shell 输入拼接；仅为测试启动环境补齐 ZDOTDIR=home.path，删除 SharedTree 用例重复 App/IME 启动链，保持生产终端行为未变。Red: /tmp/bailey-p2-shortcuts-ordered.log、/tmp/bailey-p2-focus-screenshot.log（真实 Ghostty 有命令拼接）；Green: /tmp/bailey-p2-f04-isolated-zdotdir.log 单例 1/1 PASS、/tmp/bailey-p2-f04-sequence-green.log 连续 4/4 PASS（真实 shell 标记落盘）、/tmp/bailey-p2-f04-extended-ui.log 3/3 PASS（Edit、Delete、Finder→Ghostty）。`


## 发现 F-03

- 任务：`P2-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/WorkspaceDockView.swift:559-617; Bailey/Shared/Tree/TreeRowStyle.swift:163-235`
- 摘要：`右键后台 Files 工具菜单期间 Cmd-W 实际关闭活动 Git`
- 风险：`真实 XCUITest 测试在原生 Close Panel 菜单已经展开后执行 Cmd-W，Files 仍在而 Git 消失；系统快捷键绕过右键目标，违反菜单目标与活动目标分离。`
- 预期修复：`检查右键命中、原生 NSMenu tracking、键盘事件消费以及 ClosePanel 单一命令入口，修复最小共享失效不变量，避免添加兜底全局监听。`
- 验证：`Red: make test:ui ONLY_TESTING=BaileyUITests/WorkspaceDockUITests/testOpenToolContextMenuCommandWClosesOnlyRightClickedPanel（/tmp/bailey-p2-ui-edit-menu.log，两断言失败）；Green 后同例及 tab 菜单、Edit、焦点、Host 回归。`
- 解决证据：`根因：窄 Dock 标签组使用固定内容尺寸突破组视口，右键 Files 实际落入相邻组；删除 .fixedSize(horizontal:...)，ScrollView 采用 .frame(width:maxWidth).clipped()；GUI red /tmp/bailey-p2-ui-edit-menu.log，green /tmp/bailey-p2-f03-viewport-test.log；WorkspaceDockUITests 10/10 PASS /tmp/bailey-p2-f03-all-dock-ui.log；Dock/Focus/Ownership/Finder 等宿主 113/113 PASS /tmp/bailey-p2-f03-host-regression.log；Dev+UI 构建 /tmp/bailey-p2-final-*-build.log PASS。`


## 发现 F-02

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Workspace/WorkspaceDockUITests.swift:179-243`
- 摘要：`旧 Dock GUI 测试将 Escape 后的关闭目标当成仍有效`
- 风险：`该用例按 Escape 取消 B 的右键菜单后仍断言 Cmd-W 关闭 B，而既有 P2 专项测试与系统菜单契约明确要求关闭活动 C；两条测试相互矛盾，可能造成误报和错误修复方向。`
- 预期修复：`删除已被更精确的菜单取消、菜单键盘命令、原生 Close 及活动目标测试覆盖的旧混合测试，避免维护重复且冲突的场景。`
- 验证：`源码检查对照 WorkspaceDockUITests.testCancelledFileTabMenuDoesNotCloseItsFormerTarget 和 testOpenFileTabContextMenuCommandWClosesOnlyRightClickedTab；UI 测试编译与上述两项真实执行。`
- 解决证据：`对照旧用例 Escape 后断言 B 关闭与 testCancelledFileTabMenuDoesNotCloseItsFormerTarget 的契约相反；已删除 66 行冲突/重复 GUI 测试，保留三个独立的取消、菜单键盘、菜单点击 Close 用例；make build:ui 编译成功，实际 UI Runner 因本机 Automation Mode 关闭尚未执行。`


## 发现 F-01

- 任务：`P2-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/WorkspaceWindowModel.swift:594-602`
- 摘要：`Dock 原生菜单的显式 Close 可能留下旧右键关闭目标`
- 风险：`右键未激活文件 A 时，如 A 已在关闭/保存流程中，Close 不会移除标签且不会消费 contextTarget；随后系统 Cmd-W 可能再次指向旧 A，而不是活动 B。`
- 预期修复：`把 contextTarget 的消费集中到 WorkspaceWindowModel.closePanel 的合法命令入口，closeActivePanelOrWindow 复用它，不增加延迟或重复快捷键。`
- 验证：`Red: make test ONLY_TESTING=BaileyTests/DockWorkspaceTests/testDirectTabCloseClearsMenuTargetWhenAnEarlierCloseIsStillPending，XCTAssertNil 失败；修复后同例及完整相关 Dock/GUI 回归。`
- 解决证据：`testDirectTabCloseClearsMenuTargetWhenAnEarlierCloseIsStillPending 原实现 XCTAssertNil 失败（/tmp/bailey-p2-audit-red.log）；将关闭目标消费收敛至 closePanel 后单例 PASS（/tmp/bailey-p2-audit-green.log），随后 260 项宿主 PASS（/tmp/bailey-p2-audit-host.log）；make build:dev 签名验证 PASS。`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- 修复代码提交：`3f03d9901477d58cc42724d2caae36262f0e99dd`（仅 4 个代码／测试／长期文档文件；
  本地 `todo.toml` 与审计文件没有纳入提交）。
- T1 的 `todo.toml` 提交字段改为当前分支可达的 `f4feb729`；其补丁与重写前 `4dd9ad83` 一致。
- F-01：将 `clearContextTarget()` 从系统 Cmd-W 专用分支移入公用合法
  `closePanel` 入口；既修复菜单 Close，也避免两处重复清理。新增关闭已在途标签后，
  下一次 Cmd-W 应处理当前活动标签的宿主回归，并同步 `docs/features/dock.md`。
- F-02：删除与菜单取消契约相矛盾的 66 行旧混合 GUI 测试；
  已有取消、菜单内 Cmd-W、点击 Close 与活动标签切换的独立测试继续保留。
  没有引入兼容分支或延时。

## 首轮验证日志（Automation Mode 授权前的历史记录）

- `make test ONLY_TESTING='BaileyTests/DockWorkspaceTests/testDirectTabCloseClearsMenuTargetWhenAnEarlierCloseIsStillPending'`
  → **Red**，原代码 `XCTAssertNil(contextTarget)` 失败；修改关闭入口后同例 → **PASS**（退出码 0）。
- `make test:DockWorkspaceTests,FileTreeTests,WindowOwnershipIntegrationTests,AppIdentityTests,PanelContextTests,DockFocusIntegrationTests,FinderDeliveryIntegrationTests,FileTabPersistenceTests,NativeFileTabTests,NativePaneRetentionIntegrationTests,NativeContentIdentityIntegrationTests,WindowCloseIntegrationTests`
  → **PASS**，260 项测试、0 失败（退出码 0），涵盖本机文件字节、Selection/Focus、源目标归属、
  独立窗口与宿主保留等；不是 GUI 真实操作的替代。
- `make build:dev` → **PASS**，退出码 0，含 Bailey Dev App 签名验证；
  `make build:ui` → **PASS**，退出码 0，包含改动后的 UI 测试目标编译。
- 本轮 `make test:ui ONLY_TESTING=...` → **未执行测试**：枚举返回 0 项；
  绕过枚举直接 `xcodebuild ... -only-testing:... test` → **初始化失败**，
  `Timed out while enabling automation mode`，0 项测试实际运行（退出码 65）。
  `xcrun automationmodetool` 显示 Automation Mode 已禁用且必须由用户认证启用；
  未擅自修改系统安全设置。
- 附加的宿主全类及单例重跑在 Xcode 构建或测试枚举之后停滞、无测试执行记录，
  分别精确终止受控进程；未计为通过，也不冒充应用断言失败。
  前面已完成的 260 项与最初的针对性 Red→Green 仍有效。
- 静态覆盖核对：Files 同组/跨组、展开/折叠、选择/右键/菜单取消、
  本机/SSH 根身份、拖动中目标更换、多窗、原生 Edit 与面板焦点切换均有具体调用路径。
  本轮实际覆盖的是上述宿主可执行组合；真实 GUI 触发、Finder 拖出和 SSH 联合场景不能由源码或历史记录冒充。
- **当时未核销 1**：P2-T1～T5 的当前版本真实 GUI 单击、右键、Cmd-W、拖动、菜单／焦点恢复及亮暗主题；
  原因是系统 Automation Mode 授权，影响最终行为证明；补验须在用户完成认证后单项执行现有
  `WorkspaceDockUITests`、`WorkspaceFilesUITests`、`SharedTreeUITests` 的 P2 用例，逐条核对元素及磁盘字节。
- **当时未核销 2**：从 Finder 真实拖入和向 Finder 真实多项拖出，及 Windows SSH 断线后拖动/操作的 GUI 联合边界。
  本轮没有隔离的授权真实窗口操作；现有后端宿主、NSDraggingItem 与历史 GUI 证据不足以取代现场实测。
  补验应使用独立 Bailey Dev、临时工作目录与授权 SSH 测试根，不碰用户真实文件。
- 文档已核对 `docs/features/files.md`、`docs/features/dock.md`、`docs/architecture.md`、
  `docs/ui.md`；F-01 的关闭语义已同步 Dock 文档。无证据证明旧状态分支仍可达，
  未为追求表面删减破坏有效的焦点恢复、文件后端或数据边界。

## 续审：真实 macOS GUI、Finder 与 Windows SSH（2026-10-28）

本节按当前运行事实补充／核销上一轮“未核销 1／2”；原始验证日志保留作历史快照。
测试对象是独立 `chiimagnus.bailey.dev`（隔离临时项目），正式 Bailey 未操作。
`peekaboo permissions status --json` 确认录屏、辅助功能、事件合成均授权；每项均以事件后
AX / 文件存在性 / SHA-256 验证最终结果，而不把 `dispatched_unverified` 算作成功。
系统 `xcrun automationmodetool` 仍显示 disabled、要求身份认证，故本轮没有将 XCUITest 记作通过。

- **T1**：Files 单击独立文件创建目标 FileTab；后台标签右键不打开文件。
  活动文件从 `charlie.txt` 切换时 Files Selection 自动同步；切换到 Git 后实测 Files 行数为 0，
  在面板隐藏时激活 `audit-a.txt`，重新显示 Files 后只选中对应行，标签数不增加。
- **T2**：从普通文件 A 右键 B，菜单属于 B 且没有新增 B 编辑标签；
  Files 原生 Shift+↓ 两次依次产生精确三文件 Selection，未选中的文件不属于集合。
  Edit 的复制／剪切与命令点击单独留待拥有输入焦点的 XCUITest；Peekaboo 的修饰点击在派发前被拒绝。
- **T3 / F-01**：活动 B 时右键 A，再按 Cmd-W，A 被关闭、B 保留，源文件内容一致。
  在只读子目录创建 `unsaved.txt`，实测编辑内容与磁盘不同，右键关闭后台标签时弹出原生
  “保存／不保存／取消” Sheet；点击取消保留其标签与原始磁盘字节，随后 Cmd-W 关闭真正活动的
  `charlie.txt` 而非再次处理已取消的 `unsaved.txt`。随后重新打开脏稿标签，确认内存中修改还在、磁盘仍为基线；
  通过 Close 的“不保存”正式丢弃该测试脏稿，文件字节与原件一致。保存失败与取消路径的真实 UI 已核销。
- **T4**：普通 `alpha.txt` 内部拖动默认移动；`alpha / leaf` 压缩祖先段移动整个目录树，
  非仅末级目录；三项 Shift 多选拖动同时移动三份文件，未选中 `charlie.txt` 保留。
  Finder→Files 将 `from-finder.txt` 复制到目标目录，Finder 原件不动、SHA-256 相同，
  且不创建编辑标签；Files→Finder 留白拖出 `charlie.txt` 为副本，原件不动、SHA-256 相同；
  另外三项多选从 Files 拖出后，Finder 得到**三个**文件，逐一验证原件与副本 SHA-256 一致。
- **T5**：打开 Command Palette 产生原生搜索框，Escape 后搜索框消失；Files 输入焦点恢复，
  方向键加 Space 浏览下一文件并新增正确标签，同时原 Selection 仍指向先前文件，证明
  Focus 和 Selection 未合并。编辑器获得键盘焦点后，点击 Files 留白再输入 `z`，旧编辑器正文
  和已保存磁盘字节均未变化，未把输入错误发送给隐藏焦点。
- **工具限制**：Peekaboo 的 `drag --modifiers option` 在 Bailey 和 Finder 都产生 Move，
  不能证明 Option 修饰键实际持续到 Drop，故不据此认定 Bailey 的 Option Copy 有 bug。
  现有专属 `WorkspaceFilesUITests.testNativeDragOptionCopiesSelectionAndUnselectedRowMovesOnlyItself`
  需在 Xcode Automation Mode 可用后执行。Finder 的文件夹行接收拖出第一轮未成功，
  拖向目录留白复测成功；具体 Finder 行落点不据单次失败推断产品缺陷。
- **隔离**：实际 App、临时文件与 Finder 测试窗口均为本轮专属；使用 `open -n -F`
  避免系统恢复上一次未隔离的 Dev 多窗口状态。App 正式版本的 PID、Git 分支和源代码未变动。
- **SSH**：`BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:SSHFileTreeLiveTests`
  → **PASS**，退出码 0，4 项真实 Windows SSH 测试、0 failures、0 skipped，用时 203.844 秒。
  已逐项核对批量目录与失败隔离、复制／移动／删除字节、远端 FileTab 容量与保存、重命名目录项；
  四个专属 SSH master 已自动清理（无残余 `ssh: /tmp/bailey-(files|p1|cap|rename)` 进程）。
  另外在同一隔离 Bailey Dev 内通过 Cmd-Shift-N 实际创建第二个空窗口，并在第二窗口添加
  `SSH · windows` 项目：Files 展示专属 `/tmp/bailey-p2gui-*` 下的真实 `one.txt`、`two.txt`、`folder`，
  第一窗口仅保留本机项目。远端行右键正确显示“删除…”且不提供“在访达中显示”，
  选择远端删除后显示“远端删除无法撤销”与实际 SSH 路径的原生警告 Sheet，点击取消后两行仍保留。
  第二窗口内真实拖动远端 `one.txt` 至 `folder` 后，Windows MCP 核对源路径消失、
  目标文件存在且 SHA-256 与拖动前一致，`two.txt` 保持原位，远端 Files 同步更新；
  关闭第二窗口后第一窗口本机项目仍然存在。
  期间 Mac 的**独立新** SSH 握手连续超时、一个复用 Dev socket 的外部会话被拒，
  但 Bailey Dev 自身仍通过已有连接完成上述拖动，因此不能把外部握手失败误称为 App 已断线。
  本轮仍未执行“主动终止该 Dev master → 重连 → 原选区与新内容”的完整双窗口 GUI 场景，
  也未验证 SSH 项目拒绝 Finder 外部拖入的独立真实 GUI 路径；已有代码边界及宿主证据不能冒充此 E2E。
  无证据认定 Bailey 源码缺陷。
- **清理已验证**：两个隔离 Dev 窗口均实际关闭，只有测试 PID `57745` 正常退出；
  其专属 SSH master `61551` 按进程命令精确核对后终止，正式 Bailey PID `1807` 仍运行。
  Windows MCP 已在确认解析路径与独占测试前缀后清理 `/tmp/bailey-p2gui-L8VDOZc1`，
  并验证目录不存在；本机 `Bailey-UITest-P2Audit.*` 文件夹也只在验证内容后清理。
  当轮源码无新增修改；其后 P2 继续补验期间发现并修复了 F-03。`todo.toml` 与 `audit-p2.md` 不纳入代码提交。

这轮真实 GUI 覆盖了源头行、目标行、菜单、后台标签、窗口焦点、
跨 App 拖入与多项拖出、紧凑目录、脏稿失败及取消；其时未用手动 GUI 结果替代 XCUITest。

## Xcode Automation Mode 授权后验收（2026-10-28）

- `make test:ui` 已能启动真实签名 Bailey Dev 和 XCUITest；
  `testCancelledFileTabMenuDoesNotCloseItsFormerTarget`、Option 拖动复制与保留原件
  `testNativeDragOptionCopiesSelectionAndUnselectedRowMovesOnlyItself` 均独立 **PASS**。
  运行后 `automationmodetool` 返回 `disabled` 是当前模式状态，不代表 XCTest 失败。
  **没有启用**系统级免认证长期设置。
- 系统 Edit Copy/Paste、Files 焦点复制、Control-click 原生菜单三项 **PASS**；
  后续完整 `WorkspaceDockUITests` **10/10 PASS**，已实际覆盖文件标签与工具标签右键 ⌘W、
  Escape 取消、跨组拖动、Auto Reveal、焦点、Project 与命令面板。
- **F-03 Red→Green**：测试先证实右键后台 Files 时错误关闭活动 Git；
  原因是窄 Dock 组标签栏的 `.fixedSize(horizontal:)` 撑出分配视口，
  原生鼠标命中落到相邻组。删除越界尺寸规则，使用实际组宽与裁剪；
  测试明确滚动到视口内再右键并断言可见范围。
  `make test:ui ONLY_TESTING=BaileyUITests/WorkspaceDockUITests/testOpenToolContextMenuCommandWClosesOnlyRightClickedPanel`
  **PASS**（`/tmp/bailey-p2-f03-viewport-test.log`）；完整 Dock XCUITest **10/10 PASS**
  （`/tmp/bailey-p2-f03-all-dock-ui.log`）；受影响 Dock/焦点/窗口/Finder 等宿主 **113/113 PASS**
  （`/tmp/bailey-p2-f03-host-regression.log`）。第一版 Geometry 回调实验未解决真实失败，已完全撤销；
  不存在新的全局菜单监听、兼容状态或临时调试日志。
- **真实 Windows SSH 双窗口断线 E2E**：
  `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows BAILEY_P2_EXTERNAL_DISCONNECT=1 TEST_RUNNER_BAILEY_P2_EXTERNAL_DISCONNECT=1 make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests/testAuthorizedWindowsSSHTwoWindowsKeepTargetsAfterIsolatedMasterExit`
  → **PASS**，1/1 项、0 failures、136.840 秒（`/tmp/bailey-p2-ssh-two-window-e2e.log`）。
  由外部控制器核验 ready 标记、测试 Dev PID 和唯一测试 SSH master 后，实际终止 master；
  用例验证本机/Windows 窗口独立、重连后的远端目录新条目、选区不被重定向、远端内容与 Git 状态。
  测试退出后精确清理测试 master 与控制标记；Windows `/tmp/bailey-p2-ui-*` 没有残留目录。
  此用例额外恢复原剪贴板内容，避免联合验收污染用户数据。
- `make build:dev` → **BUILD SUCCEEDED**；`make build:ui` → **TEST BUILD SUCCEEDED**，
  退出码均为 0、签名检查完成（`/tmp/bailey-p2-final-dev-build.log` 与 `/tmp/bailey-p2-final-ui-build.log`）。
- **额外扩大 GUI 回归发现 F-04**：`SharedTreeUITests` 的终端保留焦点／Shell 写文件用例
  多次失败；原生日志表明菜单前后 `firstResponder` 始终是 `BaileyTerminalView`，
  测试文字和 Return 也到达 `keyDown`，但截图显示 Shell 命令片段在不同测试会话间拼接，
  最终未生成测试文件。单独运行的右键 ⌥⌘N 新建文件夹曾 PASS，连续运行时出现临时
  AX 元素消失／Dev 归属异常。无法证明这些异常是 P2 的生产焦点代码引起；
  也不能把已失败的测试记作 PASS。未保留输入字符串打补丁、重复启动器或日志插桩。
- **当时仍未核销** SSH Files 拒绝外部 Finder drop 的真实组合场景与 F-04；
  后续实机与测试隔离验证结果见下节，不能以当时的宿主证据替代。

## F-04 与 Finder/SSH 收尾（2026-10-28）

- **F-04 根因与修复**：原测试只隔离 `HOME`，仍会从用户的 Zsh 配置加载交互插件和历史记录；
  在统一 `WorkspaceUITestSupport.launch` 中同时设置独立 `ZDOTDIR`，并删掉右键新建用例重复的启动、
  输入法与进程清理代码。不修改正式 Ghostty 或用户的 Shell 配置。提交 `f5d0414f`。
  Red：`/tmp/bailey-p2-shortcuts-ordered.log`、`/tmp/bailey-p2-focus-screenshot.log`；
  Green：`/tmp/bailey-p2-f04-sequence-green.log`（连续 **4/4 PASS**，终端命令确实写出文件）；
  `/tmp/bailey-p2-f04-extended-ui.log`（Edit、Delete、Finder→Ghostty **3/3 PASS**）。
- **SSH Finder 实机负向／本机正向对照**：
  `BAILEY_P4_TEST_SSH_HOST=windows TEST_RUNNER_BAILEY_P4_TEST_SSH_HOST=windows make test:ui ONLY_TESTING=BaileyUITests/WorkspaceFilesUITests/testAuthorizedWindowsSSHRejectsRealFinderDropWithoutAffectingLocalCopy`
  → **PASS**（93.643 秒）；从系统 Finder 拖入 Windows SSH Files 时远端不出现本机文件，
  原有远端文件字节不变；同一个 Finder 文件拖入本机 Files 后复制成功，源／目标字节一致，
  证明负向拒绝不是因拖动从未发生。收敛共享 Finder 拖动夹具，提交 `dcf2707a`。
- 回归：`/tmp/bailey-p2-final-finder-regression.log` → **3/3 PASS**（SSH Files 拒绝，Ghostty 粘贴，
  WebKit 上传；连续运行 0 failures，退出码 0）。第一次新 SSH 测试因独立 Tailscale 连接超时未进入 GUI；
  核查 Windows `sshd` 正常且连接恢复后复测通过，未改动用户网络或 SSH 服务配置。
- `make build:dev` 和 `make build:ui` → **PASS**，均退出码 0；两套 App 均经
  `codesign --verify --deep --strict` 验证（`/tmp/bailey-p2-open-final-build-*.log`）。
  本轮只提交测试与长期测试说明，未修改用户的正式 Bailey。测试临时 Windows SSH 目录全部清理；
  正式 Bailey PID `1807` 保持运行。phase 的 `audit-p2.md`、`todo.toml` 继续仅在本地保存。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（仅 P2）
- 理由：`P2-T1`～`P2-T5` 均为 `completed`；F-01～F-04 全部 `Resolved`，无遗留 `Open` finding。
  原有 260 项宿主、新增相关 113 项宿主、10 项 Dock GUI、Option Copy、系统 Edit、
  真实 Windows 双窗口主动断线恢复、F-04 连续终端回归和 SSH Finder 拒绝／本机正向对照均已验证；
  最新构建、UI 编译和签名通过。其它阶段（P3～P5）仍按自己的计划与 Gate 独立实施。

## 最终状态与剩余风险

- 当前状态：`Closed`（P2 审计已完成，无未解决 finding）。
- 已知环境限制：Tailscale 的 SSH 新建连接曾间歇性超时，但在服务正常且连接恢复后
  完整 Windows 联合 E2E 已通过；这不是 Bailey 生产逻辑缺陷，亦未被作为跳过验收的理由。
  本轮没有启用 Automation Mode 免认证的系统级设置。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
