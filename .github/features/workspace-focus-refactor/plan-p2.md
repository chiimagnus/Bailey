# Plan P2 — 工作区焦点交接重构

**目标：** 状态各归其主，跨组件焦点许可和恢复按窗口协调；原生组件只负责接收真实输入。**纯重构，UI/UX 零变化。**

**非目标：** 不做 Zed 式 GPUI／FocusHandle 引擎、不复制固定 Dock 模式、不新建全局 FocusManager／输入控件注册表／角色枚举／焦点栈，也不修改单击、双击、Space、Return、展开、拖放、菜单、IME 等既有行为。

**前提：** P1 全部任务完成并通过阶段 Gate。执行时重新核对当时源码、CodeGraph 和 [执行前审查](review-preflight.md)；已变动的实现以现行事实为准，历史审查不是新的运行证据。

## 设计与交接原则

- **六种状态，分别有真源：** 展开／折叠、行选中、悬停、展示内容、活动／激活意图、真实键盘焦点。当前 `Project.dock` 保存组的 `selected` 和 `activeGroupID`，`Project.selectedTabID` 保存最近工作标签；Files／Git 保存自己的游标；前台 key window 的 `NSWindow.firstResponder` 和实际按键结果共同说明当前输入交给谁。一次明确操作可以同时改变多个状态，但不能靠一种状态偷偷推导另一种。
- **窗口只协调跨组件决策：** 自动聚焦许可、明确交接和被临时输入打断后的恢复。优先在 P1 后窗口对象和现有挂载回调中表达；只有源码和真实测试证明存在独立生命周期需要时，才提取最小窗口协作者，不能再造通用 Manager。
- **功能负责本地输入：** Files／Git 的选择和键盘游标、Terminal Find、NSTextFinder、浏览器地址／正文、改名／草稿、Popover／Sheet 的原生事件、焦点执行与反馈不搬到窗口层；窗口不能按 TreeKeyboardView、WKWebView 私有类或坐标猜目标。
- **意图驱动而非状态级联：** 浏览／预览只在既有规则要求下改变展示，不自动激活其它组或抢编辑器焦点；显式打开才走原有激活链路。请求时、原生视图就绪时以及最终真正聚焦时均核对发起窗口和当前目标。无效／关闭／隐藏／停车／切组／新请求使旧请求失效，不能让回调晚到后抢回。
- **旧路径按场景移交：** P2-T1 接管 Dock／Files 的窗口级许可，P2-T2 迁移 Git，P2-T3 迁移 Terminal／TextKit／Diff，P2-T4 迁移 Browser，P2-T5 迁移 Palette 与打断恢复。每个任务同轮删除自己已经替换的规则；尚未迁移的组件仍沿原路径工作，但绝不同时运行两套策略；不能以最终任务统一清理作借口。
- **纯重构证据：** 每个任务在同一环境中比较原始产品基线及上个已验收任务；按 [idea 的 UI/UX 硬门槛](idea.md#uiux-零变化硬门槛)、[全部适用条件](idea.md#环境异常与极端条件) 和 [每任务放行条件](idea.md#每任务放行条件) 核销。任何改变既有用户交互的需求都另案处理。

<a id="p2-t1"></a>
## P2-T1 Dock／Files 焦点许可与交接闭环

**范围：** Dock + Files 首个独立验收闭环；只在这里建立一次窗口级许可，其他组件按后续任务依次复用。

### 真实入口与步骤

1. **观察与 Red 基线。** 沿 `WorkspaceDockView.canFocusGroup/focusGroup`、`DockGroupFocusReader/View`、`ToolPanelView` 到 `FileTreePanel.focusSelectedRow`、`TreeKeyboardOwner.focus`，确认每条可达输入路径、当前 NSWindow、活动组、真实 responder 与异常回退。验证行游标的创建与取焦是两件事；缺陷先建立能证明触发条件和实际键盘目标的 Red，用例正确时保持原有回归。
2. **最小公共许可。** 在 P1 的 `WorkspaceWindowModel` 现有动作上下文表达“此窗口／项目／Dock 组现在能否自动取焦”；事实来自现有项目、可见性、临时输入、key window 与 Sheet。调用方继续通过现有 callback 传递当前目标，不增加第二套活动组或原生控件登记。对直接点击保留 mouseDown→原生控件事件→必要时释放旧响应者的既有顺序。
3. **完成 Dock 与 Files。** `WorkspaceDockView`、`ToolPanelView`、`FileTreePanel` 的窗口许可改为同一策略；旧的 `canFocusGroup`／`canFocusKeyboard` 内部规则同时删除或变成单纯委托。Files 的已选行、默认第一行、当前文件定位、异步晚到行、改名和草稿仍归 FileTreeModel／局部视图，列表按键只在真正成为第一响应者时消费。其它组展示文件时保留 Files 键盘焦点；同组打开导致 Files 不再可见则按原行为交给新内容。
4. **处理挂载与取消。** 工具区空白、跨组拖动取消／成功、悬停、切窗口和重挂载不产生新的选中／焦点联动。已失效的挂载回调不能重新聚焦或清掉新宿主；临时 Palette 的“已经展示但 field editor 未就绪”许可仍应由窗口识别，Palette 的具体旧恢复实现直到 T5 才迁移，不能并行新建第二套恢复。
5. **即时清理。** 本范围内旧重复窗口 guard 和只能透传的壳删除；保留原生响应者、field editor、安全／可见性检查。未迁移的 Git／内容适配不预先改写，不改变树行尺寸、颜色或 Dock 结构。

### 验证与提交

```sh
make test:DockWorkspaceTests,DockFocusP2RegressionTests,WorkspaceWindowIsolationTests,TreeRowHitTestingTests,FileTreeTests,PaneRetentionTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

至少完整验证 Files 空／单／千级、未读到首行、已选行和目录压缩、当前文件与行游标分离、折叠父级、单击／双击／Space／Return、文件树鼠标按压／拖放、同组与异组浏览、真实按键、中文 IME、改名／创建输入、Palette 未就绪、前后台、双窗口、隐藏／停车／重挂载，以及 idea 的其它适用取值和组合。比较树行背景／边框／Hover、活动组标签、可见内容和第一响应者，不只比较状态字段。

同任务更新 docs/architecture.md、docs/features/{dock,files}.md 和必要的 docs/{ui,testing}.md；只在有效原生结果、旧路径清理及零变化证据齐全后中文原子提交。

<a id="p2-t2"></a>
## P2-T2 Git Changes／Git Graph 保留局部状态并统一交接

**依赖：** P2-T1 的窗口级许可已真实接入 Dock。**单一结果：** Files 与 Git 共享窗口交接规则，但不共享键盘游标和业务操作。

### 真实入口与步骤

1. 沿 `GitPanel.focusGitChanges`、`RecentCommitsView`、`TreeKeyboardOwner`、`ToolPanelView`、`GitStatusModel` 查询调用者；分清 Changes 文件行、Graph 提交行、展开的历史文件／Stash／Uncommitted Changes、搜索／提交输入框和 Shift/Git 右键动作的真实响应者。
2. Git Changes／Graph 仍各自保留选中行、上次键盘区域、浏览 Diff 的身份与滚动，工具激活与真实输入由当前窗口许可处理。不能把“Graph 展开提交”自动当成“选中另一行／激活另一组／聚焦 Diff”；Git 的按键映射保持既有单击／Space／Return 语义，不能照搬 Zed 的双击或焦点规则。
3. 迁移自动聚焦、工具组恢复与原生挂载回调；删除重复窗口许可，仅保留与仓库、机器、请求代次、输入框及原生事件有关的局部校验。异步 Git 结果必须仍按 `PanelContext.Identity` 失效；失去焦点只取消视觉描边，不得清空实际打开的 Diff。
4. 验证图谱菜单与弹窗：分支／Worktree 的多级原生菜单、底部搜索／提交说明输入、不同窗口发起的 Git Sheet 继续拥有自己的焦点和业务目标。窗口级策略不进入菜单内部管理，也不为 Git 复刻第二份焦点状态机。

### 验证与提交

```sh
make test:RecentCommitsViewTests,GitWorkspaceMenuTests,GitHistoryFileTests,GitStatusModelTests,GitExternalRefreshTests,TreeRowHitTestingTests,WorkspaceWindowIsolationTests,DockFocusP2RegressionTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

覆盖 Changes／Graph／历史／工作树、空仓库、数据晚到、重复刷新、Diff 复用、单击／Space／Return／方向键、Graph 行展开、右键和多级菜单、输入框切换、跨组／双窗口、SSH 同路径、明暗和不同字号、窄宽面板、原生 Sheet 与持久焦点视觉；按 idea 扩充全部适用组合。断言实际可见 Diff、Git index／HEAD 未被浏览修改、第一响应者及键盘目标，保留已确认的错误恢复行为。

同任务更新 docs/features/git.md 与实际受影响的 dock/ui/testing 契约，删除该范围旧规则并中文原子提交。

<a id="p2-t3"></a>
## P2-T3 Terminal／Editor／Diff 原生焦点与内容身份

**依赖：** P2-T2 完成工具层交接。**单一结果：** 工作标签显示、激活与真正输入不再靠 Dock 或各内容适配互相猜测。

### 真实入口与步骤

1. 沿 `TerminalHostView`／`BaileyTerminalView`／`TerminalFindBar`、`SourceTextEditor`／`FileViewerView`、`DiffNativeSurface`／`DiffViewerView`／`DiffTextView` 追到真正原生 first responder。核对原生挂载、焦点变化回调和工作区活动内容身份；不把“`PaneTab` 正在展示”当作输入已获得。
2. 在现有原生 adapter 上报告“已附着到哪个窗口／组、是否实际获得焦点”，窗口仅判定跨内容许可；保持 TextKit 的 IME／NSTextFinder／Undo、Ghostty 输入、Diff review/edit 和两侧 pane 的局部焦点。已请求聚焦不是成功；延迟执行前再验证当前宿主，旧视图不从新宿主夺回输入。
3. Terminal Find 的查找栏局部输入、关闭后的终端恢复和停车判定分别验收；只将跨内容恢复许可交给窗口，不把全部 `@FocusState` 与 Ghostty 状态搬上层。移动、关闭、重挂载须保留相同 `TerminalSession.surface`、`FileTab` 文档／Undo、`DiffTab` 表面；旧宿主解除动作不等待可能晚到的卸载回调。
4. 本任务删掉被接管的重复前台／Palette／Sheet 决策路径；保留真实原生协议、Window／field editor 归属、文件保存与机器身份保护。未迁移的 Browser／Palette 恢复仍由原所有者执行，不增加绕路重试或第二套焦点策略。

### 验证与提交

```sh
make test:PaneRetentionTests,WorkspaceContentIdentityTests,FileTabTests,DiffTabTests,EditorTextInputTests,EditorNavigationTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,DockFocusP2RegressionTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

覆盖 Shell PID／后台进程与输入、终端 Find、同组替换与横纵跨组移动、File 与 Diff 的大文件/Unicode/IME/Undo、Diff 双栏局部输入、原生查找与选区、挂载晚到、失败保存／关闭否决、极窄查找栏及重复关闭；逐项核对真实 Shell marker、磁盘字节、原生身份和第一响应者。按 idea 完成其它适用环境／极端组合；不把对象未销毁误认作对象仍正确接受输入。

同任务更新 docs/features/{terminal,editor,diff,dock}.md 与必要的 ui/testing 入口，删除本任务替换的旧逻辑并中文原子提交。

<a id="p2-t4"></a>
## P2-T4 Browser 地址／网页焦点交接

**依赖：** P2-T3 完成工作内容交接。**单一结果：** WebKit 地址栏与网页正文由浏览器自身选择输入目标，跨组许可来自窗口。

### 真实入口与步骤

1. 沿 `BrowserView`、`BrowserAddressField.Coordinator.focus`、`BrowserWebViewRepresentable` 和菜单 `focusBrowserAddressBar` 追踪 `⌘L`、地址输入、提交／取消、网页表单与重挂载。核对当前 6 次／50ms 的地址栏重试是在等待哪一个真实 AppKit 挂载事件；不把次数当永久契约。
2. 用可观察的原生附着／就绪反馈消费一次有效聚焦请求，最终交接前仍检查项目、组、窗口和新请求；独立保留地址编辑、搜索、网页表单、网页脚本弹窗与 WKWebView 私有输入实现。不得从窗口层枚举 WebKit 私有响应者或用几何推断业务归属。
3. **以实验决定删除时机：** 优先删除被证实可由可靠挂载事件替代的旧定时重试；若系统首次挂载仍需原生 runloop 次序，必须在此任务的可重复测试中给出真实原因和最小有界方案，不换类名保留无意义轮询，也不为猜测提前删掉有效输入路径。无法验证等价时阻塞本任务，而非提交半迁移。
4. 不碰 URL 解析、导航、数据存储、开发服务和 Finder 网页文件上传；旧宿主释放／窗口切换不得重建 WebView 或重新提交网页表单。

### 验证与提交

```sh
make test:PaneRetentionTests,WorkspaceContentIdentityTests,AppMenuIsolationTests,WorkspaceWindowIsolationTests,DockFocusP2RegressionTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

缺少覆盖时补入现有 XCTest 目标：首次／重复 `⌘L`、地址栏编辑与提交／取消、网页输入、表单/滚动/历史保留、标签停车／恢复、跨组／双窗、Sheet／JS 弹窗、拖放文件不误开新标签、快速切换和旧异步请求取消。最终核对真实当前输入、网址与 WebView 内容，不能只断言 callback 调用。按 idea 扩展适用环境、异常与边界。

同任务更新 docs/features/browser.md 和受影响的 dock/ui/testing 契约，删除被替代的重试／抢焦路径并中文原子提交。

<a id="p2-t5"></a>
## P2-T5 Palette 恢复、临时输入与全链路核销

**依赖：** P2-T1～T4 均已逐条接通。**单一结果：** 临时输入关闭后的有效焦点恢复不再由窗口扫描所有具体控件。

### 真实入口与步骤

1. 沿窗口对象的 `toggleCommandPalette`／`restoreFocusAfterCommandPalette`／`activeTreeResponder`／`ownsActiveResponder`，`CommandPaletteView`、`TabSwitcherView` 和各工具、内容 adapter 的挂载反馈，分别追踪 Palette 取消／执行／切项目／切组／输入框尚未就绪四类结束路径。
2. 由窗口决定被打断目标是否仍有效；当前内容或工具提供自己的可聚焦端点与实际结果。优先复用已有组／标签 ID 和能力回调；原生控件仍由所属适配检查。**不持有裸 NSView 强引用、不遍历 NSWindow.contentView 子树猜 TreeKeyboardView、不保存 field editor 作为长期恢复目标、不建全窗 responder registry。**
3. 取消时只恢复当前 key window 可见且有效的内容或树，命令切换目标后不恢复旧控件；如果新命令已使另一个原生输入取得焦点，旧恢复不得覆盖新焦点。隐藏、停车、窗口关闭和 App 失活使旧请求失效；迟到的卸载与恢复不得污染新宿主。
4. Projects 改名、文件草稿、Git 搜索／提交输入、Terminal Find、Editor NSTextFinder、Settings／Sheet／NSPopover 的控件内部焦点继续独立工作。特别核对 BottomToolbarView 的 `BranchSearchField`／`InstantPopoverPresenter`：旧 `presentationGeneration` 属于真正的呈现时序保护，不因焦点重构删除；只有原生挂载证据证明替代方案完整时才移除局部等待。保持原生弹窗生命周期与相同键盘步骤。
5. 删掉已被完整替换的 Palette 中央原生类型枚举／递归搜索及重复窗口级 guard。审视 P2 全链路，凡仍只有代理转发或并行可写状态都删除；不是删除真正的安全、生命周期、保存和连接保护。不得再新增一个最后“统一清理”任务。

### 验证与提交

```sh
make test:DockFocusP2RegressionTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,WorkspaceContentIdentityTests,PaneRetentionTests,AppMenuIsolationTests,AppSettingsTests,RecentCommitsViewTests,EditorTextInputTests,DiffTabTests,FileTreeTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

对 Files、Git Changes／Graph、Terminal、Editor、Diff、Browser 逐个交叉验证 Palette 打开前／搜索未就绪／输入中、取消／执行、连续快捷键、新控件抢先获得焦点、跨窗口／项目／组、popover 关闭重开、Sheet／输入法、重挂载／关闭／异步迟到。记录 **真实第一响应者、实际按键和最终内容**；视觉对照中间帧、边框、Hover、焦点淡化、菜单保持与 AX 语义。扩展到 idea 其它全部适用配置和极端组合，不能把局部测试成功记作端到端完成。

同任务更新 docs/features/{command-palette,dock,projects}.md 与真正受影响的 ui/testing/architecture 文档；中文原子提交并清理所有已迁移旧路径。

## 最终验证与阶段审计

- **任务之间不互相借门槛。** 各任务必须建立当前路径的真实旧版基线、实际结果与零 UI/UX 变化证据；没有受影响主路径的原生验收不得靠 T5 或阶段末再补。少环境时分别记录已测／缺失及对 Gate 的影响，可继续不依赖缺位环境的其它安全工作。
- **Feature 完成检查：** 对全量 `make test DERIVED_DATA=build/DerivedData-workspace-refactor` 的真实执行数量、失败／跳过及完整退出码、Debug 签名；按受影响的优化／原生生命周期范围运行 `make build:release DERIVED_DATA=build/DerivedData-workspace-refactor` 及必要的隔离 Release 原生验收。不得把 XCTest、Release 编译、安装和 GUI E2E 混为一个“通过”。
- **最大可行覆盖：** P2 的所有任务都受 [idea 的环境、异常和极端条件](idea.md#环境异常与极端条件) 约束，须逐项展开可安全执行的取值和组合；跨窗口 × 临时输入 × 异步请求 × 切组／关闭、IME × 原生文本 × 重挂载、保存失败 × 新编辑 × 退出等已知交错必须复现最终副作用。最低系统、物理输入、真实 Finder/Dock、SSH/Windows 和授权受限路径逐项报告阻塞原因、影响、替代证据、补验方式及 Gate 状态，不以“无设备”宣称通过。
- **原始基线收口：** 比较原始产品基线与最终实现，逐帧检查受影响 UI/UX，确认菜单、快捷键、点击语义、输入、资源身份、恢复和文件／Git 字节无未解释差异；保存与机器隔离守卫不得被误删。
- **审计：** 实施结束后由 executing-plans 进入 plan-task-auditor，再创建 `audit-p2.md`，独立核对任务到提交、源码调用路径、旧实现删除和完整验收证据；关键原生路径缺证、任一未解释行为变化或可安全执行条件漏测均不给无保留 Gate。本次文档更新不创建完成审计、不声称已实现。
