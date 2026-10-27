# Audit P2 - context-menu-and-tree-selection

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/context-menu-and-tree-selection/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 分离 Files 显式选择、游标和右键目标
- [x] P2-T2 共享 TreeRowSurface 分层绘制与无障碍
- [x] P2-T3 核销 Git、Dock 和窗口交叉行为并清理旧路径

## 任务到文件的映射

- P2-T1（`a59cbe3`，审计 `26a2648`）：
  - `Bailey/Files/FileTreeModel.swift`：Focus、Selection、Anchor、右键改选与命令目标。
  - `Bailey/Files/FileTreePanel.swift`：↑↓／左右导航、Esc、首次聚焦。
  - `BaileyTests/Files/FileTreeTests.swift`、`BaileyUITests/Files/{SharedTreeUITests,WorkspaceFilesUITests}.swift`：状态和真实右键、多选、焦点恢复。
  - `docs/features/files.md`：Files 选择、压缩目录右键与 Esc 撤销内部拖动。
  - `BaileyTests/Files/FileTreeTests.swift`：审计压缩目录真实段右键和旧 Drop nonce 的 Red→Green。
- P2-T2（`405f5f7`，审计 `bcbe14e`）：
  - `Bailey/Shared/Tree/TreeRowStyle.swift`：活动／失焦 Selection 底色、独立 Focus 轮廓、Hover 和 AX。
  - `Bailey/Files/FileTreePanel.swift`、`Bailey/Git/{GitPanel,RecentCommitsView}.swift`：统一 `displayed`、`isSelected`、`listActive` 参数。
  - `BaileyTests/Files/FileTreeTests.swift`：真实 `NSHostingView` 重叠状态像素；`docs/ui.md`：唯一视觉规范。
  - `Bailey/Files/FileTreePanel.swift`、`Bailey/Git/GitPanel.swift`：审计清理 `isMultiSelected`／`selected` 的误导参数。
- P2-T3（`1dcdd23`，审计 `f43c0b5`、`ae672d1`）：
  - `Bailey/Files/FileTreeModel.swift`：按 VS Code `explorerView.ts#getContext(true)` 修正多选优先级。
  - `BaileyTests/Files/FileTreeTests.swift`：多选 A/C、Focus B 的 Red→Green；`docs/features/files.md` 同步说明。
  - `BaileyTests/Workspace/WindowOwnershipIntegrationTests.swift`：多选 Focus 外操作通过真实窗口、独立剪贴板及文件 bytes 的完整路径。
  - `Bailey/Git/{GitPanel,RecentCommitsView}.swift`、`Bailey/UI/{WorkspaceDockView,Panels/ProjectsPanelView}.swift`：只读回归，没有新增平行状态或业务实现。
  - `docs/features/files.md` 与 FileTree SSH 回归：准确说明同机器同根重连保留可信选择但禁止未经确认的远端写入。

## 发现项

## 发现 F-08

- 任务：`P2-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`docs/features/files.md:50; Bailey/Files/FileTreeModel.swift:714-736`
- 摘要：`Files 当前文档误称所有 SSH 连接变化都清空 Selection，和既有同主机同根重连时保留可靠行与游标的真实逻辑冲突`
- 风险：`P2 审计必须把用户可观察规则与代码对齐；现有 testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot 已证明同根连接代次变化会保留行与游标，同时禁止未经确认的远端写操作。盲删这一行为会造成离线恢复回归。`
- 预期修复：`仅修正 docs/features/files.md 状态规则：切项目根/机器身份清空；同机器同根同后端的 SSH 连接更新在首次成功读取前保留可信显示和游标，禁用未经确认的远端写入；确认新列示后剔除不存在的 Selection。不移除真实保数/写保护分支。`
- 验证：`现有 FileTreeTests.testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot 与相同身份连接更新回归；docs diff/check；make test:FileTreeTests`
- 解决证据：`ae672d1：按 FileTreeModel.sync 的 sameRemoteRootReconnected 条件修正 docs/features/files.md，不删除可信行缓存和写操作保护；原 testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot 新增保留 Selection 断言，全 FileTree 82/82 PASS，git diff --check PASS`


## 发现 F-07

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Workspace/WindowOwnershipIntegrationTests.swift; Bailey/Files/FileTreeModel.swift:258; Bailey/Workspace/WorkspaceWindowModel.swift:821`
- 摘要：`P2 多选与 Focus 分离缺少贯穿真实文件剪贴板和最终磁盘副作用的联合测试`
- 风险：`现有 FileTree 模型测试验证选中路径、WorkspaceWindowModel 测试使用手写复制路径；未对多选 A/C、焦点 B 的当前模型命令路径与真实剪贴板记录和目标磁盘字节完成联合验收，不能证明改动已通过真实用户命令链。`
- 预期修复：`沿用 WindowOwnershipIntegrationTests 的独立 NSPasteboard/临时目录真实多窗模型，直接把 selectedOperationPaths 传入现有 performFileTreeCommand，核对 copy/cut+paste 的最终磁盘字节及剪贴板记录，不改生产路由。`
- 验证：`make test:WindowOwnershipIntegrationTests；FileTree 与 Git/Dock 交叉回归；make build+签名`
- 解决证据：`f43c0b5：新增 named NSPasteboard+临时真文件的 WindowOwnership 集成测试，真实 FileTreeModel 多选 A/C、Focus B 经 WorkspaceWindowModel.performFileTreeCommand Copy/Cut/Paste 后，A/C bytes 完整，B 不改变，私有 token 在 Cut 完成后正确清理；单项 1/1、受影响宿主 148/148、make build+codesign PASS`


## 发现 F-06

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/FileTreeTests.swift:2670`
- 摘要：`共享行组件验收缺少 Focus+Selection、Displayed+Selection、Context+Selection 等明确定义的重叠视觉组合`
- 风险：`现有 bitmap 只比较纯 Selection 或纯 Focus；计划要求同时成立的背景与轮廓不能被现有测试证明，未来修改优先级可能抹掉一层状态。`
- 预期修复：`直接扩展现有 NSHostingView bitmap 测试，验证选中与正在展示共存优先级、选中与 Focus 的边框、菜单上下文边框、无 Selection 的展示背景，不另搭截图工具。`
- 验证：`make test ONLY_TESTING=BaileyTests/FileTreeTests/testTreeRowActiveInactiveSelectionAndKeyboardFocusRenderIndependently; make test:FileTreeTests,GitGraphPaletteTests; make build`
- 解决证据：`bcbe14e：原 NSHostingView 位图测试扩充 Focus+Selection、Displayed+Selection、Context+Selection、Displayed 单态背景和独立描边；单项 1/1，87/87 宿主、3/3 GUI，构建签名 PASS`


## 发现 F-05

- 任务：`P2-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreePanel.swift:397; Bailey/Git/GitPanel.swift:2695`
- 摘要：`P2-T2 改名不彻底，单选仍名为 isMultiSelected，Git Changes 已显示 Diff 仍名为 selected`
- 风险：`两条仍在运行的视图调用链把 Selection 与 Displayed 再次混在命名中；明确违反 P2-T2 删除误导状态别名的实施要求，后续复用共享行很容易再接错。`
- 预期修复：`按实际状态将 Files Row 的成员资格属性命名 isSelected，Git Changes 显示 Diff 参数命名 displayed，同步所有唯一调用处，不保留兼容参数。`
- 验证：`git diff --check; make test:FileTreeTests,GitGraphPaletteTests; make build; 相关 GUI 回归`
- 解决证据：`bcbe14e：FileTreeRow.isSelected 与 GitEntryRow.displayed 替换残留歧义名，零兼容参数；FileTree/GitGraphPalette 87/87，GitChanges 与深浅 Files GUI 3/3，make build+codesign PASS`


## 发现 F-04

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:352-356`
- 摘要：`Esc 清空 Selection 但未取消旧 activeDrag 快照，可在后续异步 Drop 中误使用已经取消的旧文件集合`
- 风险：`beginDrag 记录 nonce/paths；moveSelection 和 select 清掉 activeDrag，但 clearExplicitSelection 没有；接收到晚到的文件 Drop 时 consumeDrag 只校验 nonce 与行存在，仍可放行旧目标。`
- 预期修复：`在 Esc 清空显式 Selection 的同一状态所有者中撤销 activeDrag；保留 Focus，不增加新的取消处理机制。`
- 验证：`FileTreeTests 在独立临时文件树 beginDrag→clearExplicitSelection→consumeDrag 必须 false；保留正常拖放的现有测试`
- 解决证据：`26a2648: clearExplicitSelection 与选中状态同时丢弃 activeDrag，旧 nonce 的 consumeDrag 明确拒绝；Red build/p2-audit-t1-red.log，FileTreeTests 82/82，make build+codesign PASS`


## 发现 F-03

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreeModel.swift:306-318`
- 摘要：`紧凑目录内的真实父目录被右键时，仅按压缩行末级路径判定是否已选中，导致旧多选集合保留而菜单操作另一个目录`
- 风险：`当 compact row 叶级和其它文件被多选，右键同一压缩行的父级组件，会沿 selectedPaths.contains(item.path) 保留旧集合；真实菜单却操作父级目录。AX/背景与命令目标不一致。`
- 预期修复：`右键改选依据实际 componentPath 或行路径判断集合成员；父组件非当前选中对象时清空旧多选并把本次目录设为有效命令目标，复用 selectedCompactPath 不引入新 Store。`
- 验证：`FileTreeTests 真实 a/b/c 压缩路径加多选，Red/Green 检查右键父级后的 Selection、selectedOperationPaths、contextSelection 及磁盘路径；定向现有 compact GUI 回归`
- 解决证据：`26a2648: 压缩目录父级点击后改选为唯一实际目标；Red build/p2-audit-t1-red.log，FileTreeTests 82/82，压缩目录菜单及连续右键 GUI 2/2，make build+strict codesign PASS`


## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`BaileyUITests/Files/WorkspaceFilesUITests.swift:670`
- 摘要：`多选命令的真实剪贴板与系统废纸篓副作用未完全 GUI 验收`
- 风险：`模型和普通右键 GUI 已验证 VS Code 选中语义；富类型系统剪贴板不可无损备份，批量 Trash 会写真实废纸篓，未在当前用户环境执行破坏性组合。`
- 预期修复：`在剪贴板可安全恢复且可隔离 Trash 的专用环境，检查选中集合、文件字节、剪贴板 token、目标删除和撤销；保留既有数据保护。`
- 验证：`隔离剪贴板及 Trash 的多选 Copy/Cut/Paste/Trash GUI，真实文件内容与副作用核对`
- 解决证据：`已补 f43c0b5 独立命名 NSPasteboard 的多选 Focus A/C 操作真实 Copy/Cut/Paste 最终文件 bytes/token 集成测试 1/1，受影响宿主 148/148；但当前用户富类型系统剪贴板无法无损备份，LocalWorkspaceBackend.delete 会写入用户系统废纸篓，不可在当前桌面安全运行全套 GUI。余项仅为系统全局剪贴板+真实 Trash 的不可安全验收条件，不是已重现代码缺陷。需独立图形用户/专用卷与无用户数据剪贴板补验。`


## 发现 F-01

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`Bailey/Files/FileTreeModel.swift:295`
- 摘要：`真实双窗口与独立 Windows SSH 断连恢复后的 Focus、Selection 和右键目标组合缺少完整 GUI 核销`
- 风险：`宿主覆盖根及连接代次失效，Git/Dock GUI 已绿，但不能据此证明实际远端断线或双窗口菜单交接完全正确；这是验收缺口，不是已重现代码缺陷。`
- 预期修复：`仅在获授权的独立 SSH 测试项目和隔离 Bailey Dev 中补组合 E2E，核对目标文件、AX 选择及未写错机器；不借用户既有 SSH master。`
- 验证：`隔离 Bailey Dev Windows SSH GUI 断线重连与双窗口 Focus/Selection/右键交叉；核对真实远端文件和 Git 状态`
- 解决证据：`无获授权独立 Windows SSH GUI 测试主机，按 plan 禁止借用用户既有 SSH master。替代证据：FileTreeTests.testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot、testSamePinnedSSHIdentityNewConnectionRefreshDoesNotWaitForOldBackend 覆盖连接代次+失败恢复和写拒绝；WindowOwnershipIntegrationTests 独立窗口/剪贴板/真实文件测试和 Git/Dock GUI 已通过。仍缺实际 Windows SSH GUI 断线+双窗口组合，需在独立临时项目与受控 SSH 主机补测，非已确认生产 Bug。`


## 修复日志

- `a59cbe3`：Focus 与 Selection 分离，箭头仅移动 Focus，右键集合外改选、Esc 清除 Selection 不丢 Focus。
- `405f5f7`：复用共享 TreeRowSurface 的选中／失焦／Hover／轮廓分层，删除误导性的 `multiSelected`／`selected` 参数，Git 保持原有单游标语义。
- `1dcdd23`：对照 VS Code `getContext(true)` 修正多选 A/C、Focus B 时误以 B 为命令目标的旧逻辑，先 Red 再使多选集合优先。
- **`26a2648`（T1）**：两处真实 Red：压缩目录父组件右键保留错误旧多选，以及 Esc 后旧 Drag nonce 仍可被接受。直接修正现有 FileTreeModel，未增加状态镜像或安全包装层。
- **`bcbe14e`（T2）**：删除 Files/Git 残留的误导状态命名；同一 NSHostingView 位图测试补齐 Focus+Selection、Displayed+Selection、右键轮廓+Selection，未增加绘制组件。
- **`f43c0b5`（T3）**：把 FileTreeModel.selectedOperationPaths 直接交给既有 WorkspaceWindowModel.performFileTreeCommand，在独立命名 NSPasteboard 中验证多选 Copy/Cut/Paste 的真实文件 bytes 和私有 token 清理；未另造命令路由。
- **`ae672d1`（T3）**：纠正同根 SSH 连接更新的旧文档，新增保留 Selection 的测试；保留真实承载缓存和未认证写入阻止的原有保护，不把必要数据围栏当作冗余删除。
- Git、Dock、Projects 的现有回调经真实 GUI 复核无需修改；没有另增 Coordinator、双轨命令或兼容路径。

## 验证日志

- 运行环境：macOS 27.2、Xcode 27.2（27B5038j）、Apple Silicon；正式 `/Applications/Bailey.app` 保持运行，测试全部为独立 `chiimagnus.bailey.dev`。
- 源码审查：分别 `git show` 对照 `a59cbe3`、`405f5f7`、`1dcdd23` 与当前 `FileTreeModel`／`FileTreePanel`／`TreeRowSurface`／`GitPanel`／`RecentCommitsView`／`WorkspaceWindowModel`，不以已有审计作为结论。CodeGraph 首先尝试同步但仓库未初始化，随后通过 `rg` 与直接调用链审阅，未宣称索引已建立。
- 上游依据：`microsoft/vscode@c5f99e8` 的 `src/vs/base/browser/ui/list/listWidget.ts`、`src/vs/workbench/contrib/files/browser/views/explorerView.ts#getContext(true)`、`src/vs/platform/theme/common/colors/listColors.ts`。
- P2-T1：5 项错误状态 Red 后，`make test:FileTreeTests,PanelContextTests` -> **98/98 PASS**；菜单连续右键、Cmd/Shift 多选 GUI -> **2/2 PASS**；命令面板恢复 Files 焦点 GUI -> **1/1 PASS**；`make build`、严格验签 PASS。
- P2-T2：共享 NSHostingView 位图比较活动／非活动 Selection、Focus 轮廓与不伪造 Selection；`make test:FileTreeTests,GitGraphPaletteTests` -> **86/86 PASS**；明／暗色与命令面板 GUI -> **2/2 PASS**；`make build`、严格验签 PASS。
- P2-T3：Git Changes 右键／Return、Git Graph 右键／Space、Projects 右键菜单／轮廓 GUI **3/3 PASS**；Dock 文件标签右键、取消与 Cmd-W 单独补测 **1/1 PASS**；`make test:FileTreeTests,DockWorkspaceTests,DockFocusIntegrationTests,AppIdentityTests,GitGraphPaletteTests,GitGraphWorktreePresentationTests,GitGraphReferenceGroupTests` -> **128/128 PASS**。
- T3 的多选焦点外越界：`build/p2-t3-context-red.log` 复现 A/C 多选却错误操作 B；修复后 `make test:FileTreeTests` -> **81/81 PASS**，最终 `make build`、`codesign --verify --deep --strict` PASS。
- Dock 原执行联合批次在第 4 项超过命令时限而中断；仅结束遗留的隔离 Bailey Dev 子进程，该单项随后独立 PASS，没有结束或替换正式 App。
- **审计 T1**：`build/p2-audit-t1-red.log` 的压缩目录错误多选与 Esc 旧 Drag nonce 两处 Red；修复后 `make test:FileTreeTests` **82/82 PASS**，逐级压缩目录菜单和连续右键真实 GUI **2/2 PASS**，`make build`、严格验签 PASS。
- **审计 T2**：现有组件位图扩展 Focus+Selection、Displayed+Selection、Context+Selection；`make test:FileTreeTests,GitGraphPaletteTests` **87/87 PASS**；Files 浅色、深色与 Git Changes 右键真实 GUI **3/3 PASS**；`make build`、严格验签 PASS。
- **审计 T3**：`testFilesMultiSelectionCommandTargetsReachClipboardAndDiskWhenFocusMovesOutside` **1/1 PASS**，使用临时真文件、独立命名剪贴板，最终写入 bytes、未选中 B、Copy/Cut/Paste token 均核对。FileTree／WindowOwnership／Dock／Focus／AppIdentity／Git Graph 宿主 **148/148 PASS**；`make build`、严格验签 PASS。
- **本轮 GUI 失焦重试**：Git Graph、Projects、Dock 联合首次 **2/3 PASS**；Git Graph 首次因隔离 Bailey Dev `XCUIApplicationState=3`（非前台）而没有达到测试前提，未进行有效右键验收；随后 Git Graph 独立复测 **1/1 PASS**。不得将首次失败当成生产回归，也不能把首次 2/3 冒充 3/3。
- **SSH 重连现有模型再验**：`ae672d1` 为 `testPinnedSSHReconnectKeepsTrustedRowsIfNewChannelCannotListRoot` 补保留 Selection 断言；FileTree 全类 **82/82 PASS**，覆盖失连保留可信树行、拒绝未经确认写入、新列表成功后清除不存在的选择。
- **实际产品接入路径**：Files 按键／右键 → `FileTreePanel` → `ToolPanelView.onCommand` → `WorkspaceWindowModel.performFileTreeCommand` → `FileTreeClipboard`／`FileTreeModel.performFileOperation` → 本机真实文件。审计测试核对独立剪贴板记录、原始内容、目标内容、移动结果和非目标文件不变。
- 已核销：无选中／单选／Cmd 多选／Shift 范围、集合内外右键、Esc 与 Focus、首次聚焦、目录导航、实际打开文件／Diff 不被误切换；Git 树右键、Dock 关闭对象、Projects 菜单，主题浅／深及展示期间失焦；本机大量文件和 Unicode 名称有现有宿主回归。
- **Deferred F-01（Windows SSH + 双窗口 GUI）**：本机同范围多窗和远端身份/连接代次的宿主实测已覆盖，缺少获授权的独立 Windows SSH GUI 测试主机；未借用户现有 SSH master。仍需在受控远端临时根目录与可独立中断的连接上联合核对 AX、Files 所有者及实际远端文件，不能将本机宿主证据充作远端 E2E。
- **Deferred F-02（系统全局富类型剪贴板 + Trash）**：本轮已安全验证独立剪贴板的真实 Copy/Cut/Paste 文件 bytes/token；用户现有富类型系统剪贴板无法无损备份，删除会写入用户真实废纸篓。需独立图形用户/专用卷与无用户资料的剪贴板再核对真实 Trash、Undo 和相关 AX；不牺牲用户数据换测试结果。
- macOS 15.6 实机、其他显示尺寸／实体触控板与真实 Windows 远端尚未验收；本轮构建采用 15.6 最低部署目标，但不能替代低版本实机、真实设备交互。P2 不对这些环境宣称已过完整 E2E。
- 文档归属：`docs/ui.md` 为共享状态颜色唯一说明；`docs/features/files.md` 为 Files 操作；`docs/features/dock.md`、`docs/features/git.md` 保持业务规则；`plan-p2.md` 记上游源码与任务验收，不在仓库长期规范复制流水账。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（全环境 E2E Gate）**；P2-T1／T2／T3 生产实现及本轮所有有证据的代码缺陷已修复，当前可安全执行的宿主与 GUI 回归已完成。
- 理由：本轮 F-03～F-08 全部 Resolved；F-01/F-02 是无安全验收环境而 Deferred 的覆盖缺口，并非未修复的确认生产 Bug。Windows SSH 实机、最低 macOS 15.6 和系统富类型剪贴板/Trash 不可伪称全条件通过。

## 最终状态与剩余风险

- 当前状态：**6 项实证问题已修复、验证和原子提交；2 项外部环境限制 Deferred，无已确认生产 Bug 留在 Open。** 阶段审计留存全环境 E2E 的受限范围。
- 剩余风险：Windows SSH 实机断线与跨窗口 GUI 同时发生时的目标交接、系统富类型剪贴板和真实 Trash 用户路径；macOS 15.6、其他显示尺寸及实体触控板尚缺本轮实机验证。
- P1 菜单蜂鸣与瞬时高亮按用户指令暂停；它们不属于本次 P2 改动和完成声明。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

