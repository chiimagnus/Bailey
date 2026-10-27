# P1：树/列表状态语义与 Files 交互基础

**目标：** 对照 VS Code List/Tree/Explorer 的真实行为，
明确 Focus、Selection、Anchor、Expand、Hover、Displayed、Context、稳定 identity 与 AX 的含义；
在 Files 领域 owner 上修复已证实缺陷，避免先画颜色、再用 View 猜状态。
这些是按组件适用的分析概念，不是一套要求所有行实现的统一状态结构。

**上游主线：** VS Code 固定提交中
`listWidget.ts` 的 `Trait/SelectionTrait/KeyboardController/MouseController/changeSelection/DefaultStyleController`，
`abstractTree.ts` 的 Tree Trait/稳定 ID，`explorerViewer.ts` 的 compressed navigation，
`explorerView.ts` 的 `getContext/onContextMenu`。
逐文件/符号/许可证及 Bailey 映射见 [本轮独立源码复核](source-review.md)。

**本地链：** `Bailey/Files/FileTreeModel.swift` 的 `selectedPath`（Focus）、
`selectedPaths`（Selection）、`selectionAnchorPath`、`selectedCompactPath`、
`contextMenuTargetPath` 和 `expanded`；
`Bailey/Files/FileTreePanel.swift` 的树行、`handleKey`、`selectForClick`；
`Bailey/Shared/Tree/TreeRowStyle.swift` 的 `TreeRowSurface/RowHighlightStyle/TreeKeyboardHost`。
不要增加平行状态模型。Settings 的 SwiftUI 原生 List 不参与本阶段。

**当前证据：** `selectRange(to:)` 当前直接将 `selectedPaths` 覆盖为 Anchor→目标区间；
鼠标 Shift 与键盘 Shift 共用它。上游鼠标走 `MouseController.changeSelection`，
工作台 Shift+方向键却走 `listCommands.ts:expandMultiSelection`，不能合并成同一个算法。
以上为执行前源码证据；后续 Red／Green、真实 GUI 和构建结果见 `evidence-p1.md`，
不沿用旧审计中的测试数字。

**验收门禁：** 所有可选行及实际命令目标必须与 Focus/Selection/Anchor 一致；
折叠/刷新/重排时稳定 identity；右键不制造打开动作；
Hover/Selected/Focused/Context 的背景与描边不出现两个错误的来源；
AX 选择只代表真实 Selection。完成 P1 后才允许 P2 以这些事实派发文件操作。

---

<a id="p1-t1"></a>

## P1-T1 修正不连续选择的锚点范围扩选

**源码与根因：**
- VS Code `listWidget.ts:MouseController.changeSelection` + `getContiguousRangeContaining`
  在原选区中找到 Anchor 对应的连续块，移除旧块，再并入 Anchor→目标的新区间；
  不消掉其它相隔的已选行。
- Bailey `FileTreeModel.select(_:extending:toggling:componentPath:)`、
  `moveSelection(by:extending:)` 最终都调用 `selectRange(to:)`，
  后者直接覆盖整个 `selectedPaths`；在 FileTreeModel 内分开两种动作，
  而非让 View 补记选择集合，也不是让所有入口套同一个鼠标算法。
  `FileTreeRow.selectForClick` 只翻译修饰键、传递意图。
- 单选、不连续选择、反向区间、普通方向键和 Escape 的当前测试
  在 `BaileyTests/Files/FileTreeTests.swift`。

**实现顺序：**
1. 同时读 `changeSelection`、`listCommands.ts:expandMultiSelection` 及其注册调用，
   以同版本 VS Code/VSCodium 复核；没有对应二进制时，源码推演与真实 UI 验收分开记录。
2. Red：建立 6+ 个真实文件，按顺序选 A、⌘选 C、Shift 选 E
   期望 A/C/D/E；Shift 回缩到 D 期望 A/C/D，移到 B 期望 A/B/C；
   Anchor 被 ⌘ 取消后仍存在其它选择岛的情况；不制造虚构 Anchor。
   正/反方向、从列表空白聚焦、选中集合外 Focus、
   普通↑/↓、⌘A、Esc、目录和压缩行分别断言。
   **键盘另表：** Selection={A,C}、Focus=C 时 Shift+↓得到 {A,C,D}，
   再 Shift+↑得到 {A,C}；Focus 已在首尾、Selection 为空、Focus 不在集合时分别验证。
   上游按“新 Focus 是否已选”移除旧 Focus 或加入新 Focus，不从 Anchor 重建范围。
   当前测试中 `moveSelection(by:2,extending:true)` 不是一次真实按键；
   当前生产键盘调用只有 ±1，测试用两次真实步进，不保留为了旧测试的兼容算法。
3. Green：鼠标在 `selectRange(to:)` 只移除旧锚点连通区间并并入新范围；
   键盘在 `moveSelection` 按 previous/new Focus 调整集合。
   Anchor 在普通导航/⌘点击时更新，Esc 与全选后按明确规则清理；
   上游 ⌘A 清 Anchor，不继续沿用 Bailey 当前全选后写 Focus 的隐式锚点。
   保留可见行顺序与路径身份；不增加新 fallback。
   不额外保存“上次选择范围”或添加业务 Coordinator。
4. Refactor：检查 View/模型是否另有重复 Range 判定，移除本 task 真正被取代的重复逻辑；
   保留源行为所需的命令集合 `contextSelection/selectedOperationPaths`，不可顺手改写文件操作。

**实测结果必须包含：**
- 宿主：`make test:FileTreeTests`；新用例先 Red 后 Green，
  文件/目录/紧凑目录/纯导航/不连续多岛/边界 0、1、N 和反向。
- 隔离 GUI：`SharedTreeUITests`、`WorkspaceFilesUITests` 中复用真实修饰键与 AX 断言；
  证明右键不丢多选，Shift 和鼠标点击不打开文件；覆盖中英、明暗与窄列表。
- 验证最终多选操作对象，而不只比较 UI 高亮；在失效/刷新/SSH 目标中确认拒绝过期路径。
- `make build:dev`、`git diff --check`；没有现成环境的 15.6/触控板/真实 Windows SSH
  分别记录原因与影响，不按“代码通过”关闭缺口。

**所属文档：** 同一提交更新 `docs/features/files.md` 的 Anchor/Shift 语义，
需要调整颜色契约时才动 `docs/ui.md`；提交只含此 task 生产代码、测试和文档。

---

<a id="p1-t2"></a>

## P1-T2 将刷新、折叠和移动后的 Focus/Selection/Anchor 约束于稳定身份

**源码与根因：**
- VS Code `listWidget.ts:TraitSpliceable` 和 `abstractTree.ts:Trait.onDidModelSplice`
  以 identityProvider 为基准在增删、虚拟化、折叠时复用/撤销原 Trait；
  Anchor、Selection、Focus 各自处理。
- Bailey `FileTreeModel.sync/rebuild/revealFile`、`move/rename` 后路径映射、
  `expandedByRoot`、`selectedPath` 与 `selectedPaths` 及
  SSH `panelIdentity/connectionRevision` 必须分别核对。
  无须把 `FileTreeModel` 重写成 VS Code 的 JS Tree。

**明确保留的差异：** 上游 `TreeNodeList.splice` 与 Explorer 的
`replaces a selection hidden in a collapsed folder` 测试证明：折叠后模型仍保留隐藏 Selection。
Bailey 当前 `rebuild` 对可见路径求交，`testFileTreeMultiSelectionTracksCollapseRenameAndWorkspaceSwitch`
明确要求折叠清掉子项 Selection。本 Feature 保留这条已文档化产品契约，
不能把它写成“完全复刻了 VS Code identity”；折叠、过滤、删除分别测试，
不为模拟隐藏节点另建第二棵树或无用持久状态。

**实现顺序：**
1. 阅读 `FileTreeModel` 的 root/scope 同步、刷新、目录折叠、filter/exclude、
   创建/重命名/删除和旧连接恢复路径；沿 `ToolPanelView` 到当前机器绑定核实每个入口。
2. Red：选中目录子项并折叠父级；同根刷新不变化、删除子项、同一路径重建、
   重命名父目录/子文件、移动根、变更 exclude、链接替换；
   同 SSH 机器同根断线重连与换远端身份；
   保持与撤销的条件分别写断言。检查 Anchor 指向消失项时不会随机扩选。
3. 在唯一 FileTreeModel owner 收敛身份过滤和路径重映射：
   同一有效路径保留；不可见/删除/换 root/机器按上述 Bailey 规则清理；
   文件 identity 是作用域内路径，不添加 inode/全局 UUID 来区分同路径重建。
   SSH 连代改变但尚未验证新列表时保留可信显示、阻止写操作，
   成功读取后再剔除失效行，不能提前清空视觉。
   不以 `hasCurrentTarget` 临时 View 判断推断选择逻辑。
4. 删掉被同一约束替代的旧状态清理分支/重复指针修正，保留数据保护边界。

**验收：** `make test:FileTreeTests,PanelContextTests` + 受影响 `SSHFileTreeLiveTests`；
文件真实字节与路径检查；最小 NSHostingView 树挂载/折叠测试；
隔离 `WorkspaceFilesUITests` 做真实 GUI 入口，SSH Windows 条件按现场可获得性实测。
测试空目录/1/1000+ 文件、深层链接/Unicode/大小写碰撞、批量事件和重复出现，
核实滚动/AX 没有“幽灵选中”。

**文档/提交：** `docs/features/files.md`、
必要时 `docs/features/ssh.md`；一个原子提交。

---

<a id="p1-t3"></a>

## P1-T3 对齐紧凑目录各段、按钮、留白和拖动的命中语义

**源码与边界：**
- VS Code `explorerViewer.ts:ExplorerCompressionDelegate`、
  `getCompressedNavigationController` 区分紧凑目录内实际目录段，
  `abstractTree.ts:TreeNodeListMouseController` 不让 twistie/action 按钮冒充整行单击。
- Bailey `FileTreePanel.FileTreeRow`、compact components、
  `selectForClick(componentPath:)`、`selectForContextMenu`、
  `rowMenu(for:)`、`TreeRowSurface`、`TreeRowLayout`、
  `TreeFileRow/TreeFolderRow` 的分段高亮与 hit area 同属此任务。

**实现顺序：**
1. 绘制真实点击区域表：整行空白、icon、twistie、姓名/压缩 a/b/c 的每一段、
   独立右侧按钮、左侧缩进、水平滚动区域、拖动起点，按事件分派实际 target。
2. Red：分别对 a、b、c 右键及 Copy/New/Rename；
   在中间目录点开/折叠；⌘/Shift 点击与双击；
   hover 段亮和 AX path/label 必须对应实际目录，不出现“末级代替父级”。
3. 仅在已存在的 TreeRow/压缩段 target 解析位置合并重复命中，
   不在业务命令里按显示字符串拆路径；删掉错误的 fallback 或对同事件重复触发。
4. 检查 Finder/内部 DnD 是否也走同一个有效目录身份；
   不改变其安全 Copy/Move 语义，本任务只处理命中，实际传输由 P2-T4。

**不能遗漏的压缩语义：** 上游 `getContext` 在多选压缩行时会展开 controller.items，
并非简单返回末级路径。Bailey 保留“明确段优先，整行末级”的既有规则，
父子重复目标由现有 `performFileOperation` 归并；测试压缩段与其它行多选的组合。
Git Changes/历史树目前只传普通 `TreeFolderRow`，并未接入 Files 的 `compactSegment`；
同任务补齐可观察的分段命中与身份，不把“共用 TreeRow”当作已经支持。

**验证：** `FileTreeTests` 的紧凑目录模型/AX/像素以及
`SharedTreeUITests` 的每段原生右键、首尾长行、水平滚动、缩放与多语言；
`make build:dev`；保持 Git Changes/History 同一共享树行不破坏原命中。
**文档/提交：** `docs/features/files.md` 和真正变更时的 `docs/ui.md`；单一提交。

---

<a id="p1-t4"></a>

## P1-T4 统一树行视觉状态优先级和 AX，保留独立领域显示意图

**源码与差异：**
- VS Code `listWidget.ts:DefaultStyleController` 独立声明
  `focused`、`selected`、`focused.selected`、`hovered`、
  列表 `:focus`／失焦与 `.context-menu-visible .last-focused`；
  这不是“一个 isSelected 对应一种颜色”。
- Bailey `RowHighlightStyle` 当前 `contextRing` 优先时**直接清背景**，
  而 VS Code 某些组合会保留 Selection 底色；
  这与用户此前要求“不出现无意义的蓝底+蓝框”有真实冲突。
  不能没做可视对照就把所有区域统一到一种 fill。

**实施门禁/步骤：**
1. **只读观察先行**：用 VSCodium/VS Code 和隔离 Bailey Dev
   在 Light/Dark、活动/失焦、鼠标右键已选/未选、多选内外、
   Focus+Selection、Displayed+Selection、Hover+Context、菜单取消之后
   获取可观察状态（可用 AX、最小像素采样/用户允许时截图）。
   将“用户先前反对的错焦点外框”与“正常 Focus+Selected”分开；
   本轮目标保持 `docs/ui.md` 已规定的菜单期仅描边：这是 Bailey 与上游的明确差异，
   不是待执行者自行选择的悬案。没有新的用户决定，不改成上游保留底色的视觉。
2. 将经过确认的底色/描边规则只在
   `TreeRowStyle.RowHighlightStyle/TreeRowSurface` 和当前 Theme owner 编码；
   Files/Changes/Graph 只传语义，不复制 `.background` 与 `.overlay` 决策。
   Dock 标签/Settings 不盲目复用相同高亮。
   现有共享组件若已表达目标规则，保留实现，只修确认错误的调用参数或重复绘制；
   不为了“统一八种状态”增加状态对象、重命名包装或重写优先级。
3. 为各组件实际适用的状态组合及互斥先后绘制最小 `NSHostingView` 真实像素断言；
   文件／资源树的 AX `isSelected` 只跟显式 Selection，键盘焦点另走原生语义，
   `displayed` 不添加虚假 AX Selected。
   Projects 的当前项目、Palette 的高亮结果和 Ctrl+Tab 的预览候选按各自契约验证，
   不把共享视觉参数误认成共享的业务选择模型。
4. 删除真实重复的本地视觉实现，除非它表达 Tabs 和 Graph 特有的视觉意义；
   避免因换主题触发终端、编辑器重建。

**验证：** 扩展 `FileTreeTests` 已有 bitmap 断言，分别覆盖 Changes/Graph 适用组合；
检查 Projects、Palette、Ctrl+Tab 与标签外壳等共享 `RowHighlightStyle` 使用方未被连带改变，
不为不适用的状态补字段或制造组合；`GitGraphPaletteTests`；真实 `SharedTreeUITests/GitGraphGeometryUITests`
做主题、活动组与失焦/菜单，字号/窄宽/长 Unicode 和辅助功能树；
`make build:dev` 和 `git diff --check`。
**文档/提交：** `docs/ui.md` 作为唯一共享外观规则 owner，
只把 Files 局部行为写入 `docs/features/files.md`；一个提交。

---

<a id="p1-t5"></a>

## P1-T5 原生树键盘所有权、可见滚动与特殊输入回归

**源码：** VS Code `KeyboardController`、`TreeNodeListMouseController`、
`ListService` 的 scoped focus/Context，允许 Input 夺焦。
Bailey `TreeKeyboardView/TreeKeyboardHost`、
`FileTreeScrollView.handleKey`、`focusSelectedRow`、
`WindowRootView` 与 `DockGroupFocusReader` 是真实交接路径。

**实现：** 区分树行 cursor 与 NSWindow.firstResponder；
Files 实际前台时 ↑↓/←→ 仍按既有契约；补齐上游已有的 Home/End 和 PageUp/PageDown，
Home/End 聚焦首尾可见非 draft 行，分页按实际视口可见行数移动并钳制边界，
均只改 Focus/Anchor、不打开文件或改 Selection；
Space 浏览、Return 激活、Escape 清 Selection；
rename/new file TextField/IME 接管时不得吞键；
切工具/分屏后不以旧键盘宿主作为仍有效焦点；
回到 Files 恢复有效 cursor 而非打开文件。
只在树实际 firstResponder 的原生输入入口处理，不给系统主菜单重复注册按键；
视口信息在现有滚动宿主取得，不逐行读取屏幕几何。P2-T5 再迁移本链窗口许可，
本 task 不预建第二套协调器；
重挂载焦点交接不要追加 `DispatchQueue.main.async` 补丁链。

**验收：** `FileTreeTests` + `DockWorkspaceTests`、
`SharedTreeUITests`、`WorkspaceDockUITests`；
空/大量列表、上下边界/深层目录、水平滚动、中文/日语 IME 组合、
编辑器/终端输入接管、切项目与双窗、Sheet/Palette 取消；
聚焦后实际键作用于正确目标，原 Terminal/Editor 输入没有丢。
本机未配备的 15.6/实体触控板及未授权 GUI 场景逐项标注证据缺口。

**文档/提交：** `docs/features/files.md`、`docs/features/dock.md`（仅发生交接契约变化时）；
一个提交。

---

## P1 阶段验收与审计

1. `make test:FileTreeTests,DockWorkspaceTests,PanelContextTests`，
   再运行具体影响的 Git 共享树行宿主类和对应隔离 GUI；
   `make build:dev`、完整签名后置步骤、`git diff --check`。
2. 对照 `source-review.md` 的 Files 状态/视觉/AX/身份/容量/异常表逐项核销；
   不是只验某个 Shift 单元测试通过。
3. 检查各 task 的提交或已验收无变更证据与 `todo.toml` 对应，文档 owner 已更新且无遗留双轨。
4. 运行 `feature_tool.py phase-complete ... --phase p1`，使用
   `plan-task-auditor` 独立审查 `audit-p1.md`；Go 才进入 P2。
5. 未能实测的 macOS 15.6/触控板/GUI 争用/Windows SSH/大容量组合
   在审计逐项列出原因、影响、补测方式与是否阻塞，不将 Deferred 算成功。

**测试启动边界（审计后核对）：** `WorkspaceUITestSupport.launch(in:project:)` 仅在
传入 `project` 时通过 `BAILEY_UI_TEST_PROJECT` 预置临时目录；
`WorkspaceApplication.init` 只是将其放入待加载队列，直到首个
`WindowRootView` 出现并注册窗口，才真正添加项目。预置路径不负责创建窗口。
未传 `project` 的用例仍需覆盖真实 Add Folder 入口，不能全部改成直接预载。
F-03 的窗口专项修复已撤回并从 P1 门禁排除；不得将“预载目录”解释为
“初始窗口一定存在”，也不为 F-03 重新增加独立修复任务。
