# Plan P2 — 窗口内焦点协调

**目标：** 每窗只有一处工作区自动聚焦／交接／恢复策略；原生输入和局部交互留在所属组件。

**非目标：** 不改变 UI/UX、快捷键或浏览／激活语义，不重写 TextKit／Ghostty／WebKit，不接管所有文本框，不增加通用角色枚举、弹窗栈、事件总线或跨平台框架。

**路径：** 从现有窗口策略和原生适配中收拢重复决策，一次接通受影响内容和工具。复用现有 ID、请求序号、取消和局部状态；不预设必须新增 FocusManager 类型。需要独立承载已存在的焦点状态时最多提取一个具体窗口协作者，不为单一实现加协议／工厂／多层 registry。

**验收：** 窗口策略不识别 TreeKeyboardView、TextKit、WebKit 私有控件；恢复和真实输入保持基线；组件不再重复窗口级规则，必要原生检查不丢失。必须满足 [UI/UX 零变化硬门槛](idea.md#uiux-零变化硬门槛) 与 [每任务放行条件](idea.md#每任务放行条件)，不是“新协调者收到请求”即可通过。

**前提：** P1 Gate 通过，并明确获准实施。遵守 [焦点边界](../../../docs/architecture.md#焦点协调边界) 和 [验证全集](idea.md#验收条件与验证全集)。

<a id="p2-t1"></a>
## P2-T1 接通唯一窗口焦点策略并清理分散决策

### 真实入口与职责

| 入口 | 迁移内容 | 不上收的内容 |
| --- | --- | --- |
| WorkspaceDockView：canFocusGroup／focusGroup、DockGroupFocusReader／View | 所属窗口、活动目标、Palette／Sheet 许可与恢复决策 | 鼠标按下／释放序列、拖放命中、原生事件顺序 |
| P1 后窗口对象：toggleCommandPalette／restoreFocusAfterCommandPalette／ownsActiveResponder／activeTreeResponder | 命令面板打断与恢复、目标有效性；移除窗口对具体原生控件的搜索 | Dock 和 Project 已有选择真源 |
| PanelContentView 与内容适配 | 工作内容的显式聚焦、挂载／实际结果交接 | 文档／Shell／WebView、Undo、滚动、局部输入 |
| ToolPanelView、FileTreePanel、GitPanel、RecentCommitsView、TreeRowStyle | Files／Git 自动取焦的共享许可、当前工具恢复和原生接入 | Files 游标／草稿／改名，Git Changes／Graph 最近区域及各自行游标、按键业务 |
| TerminalHostView／TerminalFind／TerminalFindBar／BaileyTerminalView | 可见终端交接和 Find 关闭后的恢复许可 | 搜索状态、计数、重复 ⌘F、本地 @FocusState 和安全剪贴板确认 |
| SourceTextEditor／FileViewerView、DiffNativeSurface／DiffViewerView／DiffTextView | 内容挂载、焦点回调与现有原生文档映射 | NSTextFinder、marked text、保存／关闭、Diff 模式和内部有效 pane 选择 |
| BrowserView：BrowserAddressField、BrowserWebViewRepresentable | 地址／正文请求有效性、原生后代归属、替代挂载轮询 | URL／导航、地址编辑、WebKit 输入和网页脚本对话框 |
| CommandPaletteView、ProjectsPanelView、WorkspaceChrome、TabSwitcherView | 打断／结束时是否允许旧工作内容恢复 | 文本编辑提交／取消、Escape 清查询、Ctrl-Tab 临时选择和修饰键消费 |
| BottomToolbarView：BranchSearchField／InstantPopoverPresenter | 验证工作区与 popover 输入互不抢占；确需时只传最小暂停事实 | NSPopover 呈现代次、搜索框 field editor、初始响应者和原生开关生命周期 |

### 步骤 1：先把真实行为变成断言

1. 复跑当前基线，补齐同组内容替换／异组浏览、列表未附着／首行晚到、Palette 未得到 field editor、Git Changes／Graph 恢复、Find／改名结束、命令不切目标的真实响应者及输入结果。新缺陷先证明前提再 Red→Green，不为纯结构变化制造假 Red。
2. 单独验证底栏分支 popover：原生呈现窗口与工作区不同，不能简单用“不是工作区 keyWindow”拒绝其搜索，也不能在关闭异步回调中夺回新输入。反复开关、先关闭再重开、输入／清除、取消／选择分支、双窗口切换均检查最终行为。这里不增加新的代次；现有 presentationGeneration 不是冗余围栏。
3. 确认组件的实际输入映射与挂载事件足以替代窗口类型搜索。共享 field editor 按其真正输入控件归属，WebKit 私有响应者由 Browser 适配解释；工具和空组无需虚构工作标签 ID。几何可用于点击／拖放、控件可见性和原生局部命中，不作为全局业务身份。
4. 若在受控原生宿主仍无法证明映射或附着时序，先完成最小实验和结论再替换该链路；不先引入通用目标 registry、全窗 NSView 搜索 fallback 或多层 generation 来掩盖未知。
5. 使用原始产品基线与 P1 已验收点双重对照。提前写出每个受影响入口的响应者、输入文本、选区／滚动、视觉状态及错误／恢复结果；覆盖 idea 中所有适用配置、输入极值与时序组合。缺少可靠原生基线的链路先补证，不能通过改写预期、更新截图或放宽容差让新实现成为自己的验收标准。

### 步骤 2：在一个闭环任务内接通并删除

1. **唯一窗口策略。** 持有所属窗口及已有工作区事实的读取入口，统一自动许可、显式交接和恢复。现有项目／组／内容 ID 按需使用；功能内部的地址／正文或 Changes／Graph 由所属适配选择，不扩展全局输入角色表。
2. **局部原生接入。** 组件提供完成当前交接需要的能力、挂载和实际结果。引用／闭包不形成保活环；登记若确实需要，只登记实际可恢复的内容／工具端点，旧宿主卸载仅解除自己的接入，不能清除新宿主回调。
3. **区分三种事实。** 展示哪个标签、哪个组活动、真正响应者是谁分别处理。直接点击沿原生事件流，只报告实际获得焦点，不在 mouseDown 前抢占；空工具组仍在事件交付后释放旧编辑器输入。行游标初始化与真正取焦分开：现有 Files／Git 可以在未取焦前准备行选择，Palette 未就绪时又必须阻止底层游标接管；不能把统一前台许可提前到所有局部状态更新前，改变这些顺序。视觉只读现有活动／临时输入事实，不把“允许自动聚焦”当成唯一视觉标志，也不另建镜像状态；查找框输入与组标签高亮保持基线。
4. **临时输入不变成全局管理。** Palette 自出现便阻止底层抢焦点，取消／切目标／不切目标沿原行为结束；Terminal Find 的跨内容恢复许可接统一入口。本地 @FocusState、NSTextFinder、行内改名／草稿、Git 弹窗初始响应者仍由组件或 AppKit 管理。Settings／Sheet／NSPopover 不进工作区目标栈，原生 modal 生命周期保持不变。
5. **检查发生在最终副作用前。** 异步请求到真正 makeFirstResponder 时再查询当前窗口策略；切项目／组／窗口、隐藏／停车／关闭、后续交接使旧请求失效。保留原生宿主归属、可见性、协议与输入合法性检查，不能把“统一许可”缓存后在延迟闭包无条件使用。复用已有计数／取消，不新增通用重试／超时／恢复服务。
6. **同任务删掉重复决策。** 用统一入口替换 Dock canFocusGroup、ToolPanel canFocusKeyboard、各内容重复的窗口／Palette／Sheet 判断及 Palette 的窗口级原生类型枚举／递归搜索。canFocus 这种适配回调可以保留，但它只查询同一策略，不能复制规则或成为旧策略 fallback。保留 Git／Files 的当前数据目标检查、局部游标、按键分发及改名防双提交。
7. **计时与挂载分开。** Browser 两处 6 次／50ms 轮询在同任务用真实附着及请求消费取代，并覆盖首次、重挂载和重复 ⌘L；不得把轮询换个类名保留。BranchSearchField 的轮询属于独立 NSPopover 就绪链，只有实际挂载／didShow 测试证明可替代时才在本任务删除；否则明确记录其原生原因，不能把焦点重构扩成弹窗重写。必要单次 runloop 交接不等于无条件重复重试。
8. **内容与清理不分期。** 保留同一 TerminalSession.surface、FileTab 原生文档／Undo、Diff pane 和 BrowserTab.webView。停车解除旧动作，晚到卸载不清除当前宿主。删除被替代实现及全部旧调用方后再提交；不留 compatibility alias、双策略、临时适配壳或“以后清理”的任务。

### 同任务清理边界

| 删除／替换 | 必须仍然成立的条件 |
| --- | --- |
| 多处窗口级许可／恢复规则、中央按控件类型搜索 | 所有自动路径查询唯一策略；合法点击、辅助功能输入、Sheet／popover 仍按原生工作 |
| 旧 Palette 弱响应者＋中央类型枚举恢复链 | 不保留 field editor 作稳定目标；恢复当前有效内容／工具，不打开文件或执行 Git 操作 |
| Browser 挂载轮询 | 事件到真正地址输入／网页输入，不吞掉首次或连续 ⌘L |
| 旧宿主焦点回调接入 | 新宿主仍能接收焦点，Shell／网页／文档不重建、无闭包保活 |
| 不删除：保存／机器／连接身份、终止幂等、安全剪贴板检查 | 这些不是重复焦点策略；触及其路径仍逐项回归 |

没有发现“旧 FocusManager alias”或“通用旧焦点框架”可供预先删除；不能在执行证据中虚构清理成果。

### 验证与组合

```sh
make test:DockWorkspaceTests,DockFocusP2RegressionTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,WorkspaceContentIdentityTests,TreeRowHitTestingTests,RecentCommitsViewTests,GitWorkspaceMenuTests,GitHistoryFileTests,PaneRetentionTests,EditorTextInputTests,EditorNavigationTests,SyntaxHighlightingTests,FileTabTests,DiffTabTests,SessionStoreTests,FileTreeTests,PanelContextTests,AppMenuIsolationTests,AppSettingsTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

新增测试类加入同一选择集合。旧辅助方法消失时改为断言真实挂载、响应者、输入及最终副作用，不能删除测试或只改成“新 API 返回成功”。

逐项覆盖 idea 的全部适用维度，尤其检查下列交互，不能以这些组合替代其它可执行条件：

- Files／Git 浏览 × 同组替换／异组展示 × 新建／复用内容 × 空／异步列表。
- Palette 未就绪／已聚焦 × Files／Changes／Graph／编辑器／浏览器 × 取消／切目标／不切目标。
- Terminal Find × 150／210pt × 横纵移动／停车 × Palette／切项目；NSTextFinder 与编辑器 Undo／IME 并行保留。
- 底栏分支 popover × 打开／快速重开／取消／选择 × 旧恢复晚到／双窗口；Settings／原生 Sheet 另验，不套用同窗规则。
- field editor／WebKit 内部输入 × Dock 点击／右键／跨组拖放释放 × 前后台；真实按键不得进入旧内容。
- 多脏缓冲 × 保存失败／保存中新编辑 × 切换／关闭／退出；磁盘、保留正文与 Undo 正确。
- 重复重挂载／关闭 × 当前容量边界、Unicode、字体／外观／窄宽；复用原生对象且监听／回调释放正确。
- 新增维度按 idea 的 [环境、异常与极端条件](idea.md#环境异常与极端条件) 全部展开：包括默认／最小／最大字号、四种既有查找栏宿主宽度、显示缩放／窗口状态、快捷键重复与修饰键中断、IME、容量临界值和受控失败；不能只从上列组合挑几条。受控继续点用于构造可达乱序与关闭／取消，不以随机延时、反复重跑直到通过代替断言。

保留原生基线对照；实际安全条件具备时分别验证真正 ⌘S／⌘F／⌘P／⌘W、Shell marker／PID、Files／Git 键盘、网页表单、拖放和弹窗最终输入。窗口 sendEvent 不是独立 App E2E。

**P2-T1 零变化放行：** 在相同环境逐项对照原始基线和 P1 验收点，检查静态几何／可确定像素、交接录屏、实际按键与文本、组标签／树行／悬停视觉、原生菜单／弹窗、错误与恢复、基础 AX 和响应／资源。动效和中间状态也不能变化，不允许以最终响应者正确掩盖一次闪动、丢键、错投或滚动跳跃。按 idea 保留每条件及组合的实际证据；任一未解释差异、漏测的安全可执行条件、关键 E2E 缺证或旧策略未删除均不得通过本任务验收，不等最终审计再清理。

Feature 正式验收运行完整 `make test DERIVED_DATA=build/DerivedData-workspace-refactor`，核对实际发现的测试、失败／跳过、后置签名及完整退出码。生命周期／原生回调的优化配置用 `make build:release DERIVED_DATA=build/DerivedData-workspace-refactor` 和受影响原生用户路径复核；若更改跨 actor 回调或优化相关代码，按 testing.md 对相应类补 Release XCTest，隔离构建才传 `ENABLE_TESTABILITY=YES`，不把全套 Debug 再原样复制成全套 Release 门槛。正式 Release 恢复原配置。

整包安装遵守现有开发文档，不包含启动／重启。真实 SSH、通知、Finder、权限及最低系统缺位逐项说明原因、影响、替代证据与是否阻塞；关键焦点／数据链未验证不作完整验收结论。

### 文档与提交

同任务同步 docs/architecture.md 的实际边界、docs/features/{dock,files,git,terminal,editor,diff,browser,command-palette}.md 的受影响事实及必要 ui／testing 说明；不重写无关文案、历史审计或整个算法文档。

中文原子提交完整接入、替代路径删除、测试、现行文档，以及用户要求入库的计划／脱敏证据。通读 diff、现行引用和 `git diff --check`；仅由 feature_tool 回写 todo 的真实状态与提交。

## 阶段审计

实施结束后由 executing-plans 进入 plan-task-auditor，再创建 audit-p2.md。独立核对原生内容／工具／popover、P1 应用回归和每项删除证据，并从原始产品基线做最终 UI/UX 对照，防止阶段累计漂移。按 idea 逐项核销环境、极值、异常、时序及其可执行组合；未解释差异、可执行场景漏测、关键原生／系统入口缺证均不给无保留 Gate，不能以全量 XCTest 绿色或截图更新代替。本轮不预建实施审计。
