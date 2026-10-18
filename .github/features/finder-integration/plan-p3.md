# Plan P3 — Finder 按实际放置区域执行对应动作

> **历史阶段，已完成。** 当时的 Projects 文件投放会建立独立 `pinnedFile` 项目，后经用户明确修正为「普通文件只打开标签，目录才添加项目」。新需求和其测试见 [Plan P4](plan-p4.md)，P3 的 Files 复制、终端/WebKit 所有权及真实 Finder 验收继续有效；以下任务和审计保留原有完成证据，不改写历史。

**Goal：** Finder 文件／文件夹按 Bailey 实际命中区域执行不同且互斥的动作：编辑区和分屏标签栏打开或复用文件（新标签进入实际落点组）、Projects 新增本机项目、Files 将文件及目录复制到准确的本机目录、本机 Ghostty 只插入转义路径、WebKit 网页内容保留原生上传；SSH 不误接本机路径，Dock／Projects 内部拖动不受影响。2026-10-18 用户将原本留给 Issue #5 的 Finder→本机 Files 复制子集提前纳入本阶段。

**Non-goals：** 除 Finder→本机 Files 复制导入外，不做文件树多选、内部移动、剪贴板、覆盖确认、远端上传与跨机器传输；这些继续属于 [Issue #5](https://github.com/chiimagnus/Bailey/issues/5)。不做第二套拖放引擎、全窗口透明层、全局 NSEvent monitor、Shell 自动执行、PDF 预览或独立设置项。

**真实前提：**
- `Bailey/UI/ContentView.swift` 的工作区分为空状态和 `WorkspaceDockView`；其多个 Overlay、`WindowChromeAccessor` 都参与命中／生命周期。
- `WorkspaceDockView` 用自己的 SwiftUI `DragGesture` / `DockTabDragCoordinator` 移动内部标签，项目面板也有独立排序；不可将内部 DragGesture 当成 Finder 的 `fileURL` drop。
- `BaileyTerminalView` 已是 `NSDraggingDestination`，注册 `.fileURL`，现有 `performDragOperation` 转义路径后 `sendText`，**不显式发送 Return**。
- `TerminalSession.workspaceIdentity` 从动态连接／`initialWorkspace` 推断机器，但 **`Project.makeSession` 以 `sshHost` 直接生成远端 SSH 启动命令时 `initialWorkspace` 可以为 nil**；连接尚未接管前 `workspaceIdentity` 也可能为 nil，绝不只用该字段来判断远端路径是否允许输入。
- `Vendor/STTextView/.../STTextView+NSServicesMenuRequestor.swift` 注册的拖动类型只有字符串／RTF；`.../STTextView+NSDraggingDestination.swift` 可接受外部文本并插入正文。**不能直接推断 Finder 的文件 URL 一定被它抢走**，先看实际 pasteboard 类型和命中结果。
- **T1 调查时的旧状态**：`FileTreeRow` 曾错误地将 SSH 路径外拖为 Mac `fileURL`，P3-T2 已从源头修复。后续用户明确要求本次实现 Finder→本机 Files 复制，P3-T3 已沿 `FileTreeModel`／`LocalWorkspaceBackend` 接入实际复制与错误反馈。

**Acceptance：** Finder 单／多文件和文件夹在普通区域打开；每个分屏的顶部标签栏打开到实际落点组（空组亦支持），已有文件复用原组原缓冲；Projects 添加本机文件／文件夹项目；Files 真实复制到指定目录、不覆盖、部分失败保留源且不留半成品；本机终端只插安全路径不执行，固定／动态 SSH 拒绝 Mac 路径；WebKit 上传、STTextView、Dock 与项目内部拖动保持原语义。分别用 XCTest 与真实 Finder E2E 核对最终效果，不以 Drop 回调返回成功代替验收。

---

**阶段演进说明：** 下面 P3-T1／T2 保留当时的 Red→Green、真实 Finder 实验及代码快照，部分文案是用户扩展 Files／Projects 交互**之前**的历史语境（例如「Files 留白打开」或「Files 导入留给 #5」）。**当前目标与验收以以上说明、P3-T3/T4 及 `idea.md` 为准**，不能按 T2 历史语义回退已经实现的复制与项目添加。

---

## P3-T1

**独立结果：以最小原生实验查明每个落点的真实拖动接收者，确定 P3-T2/T3 要改哪些层；无永久行为变化不做空提交。**

**Files to inspect：**
- `Bailey/UI/ContentView.swift`、`Bailey/UI/WorkspaceDockView.swift`、`Bailey/UI/Panes/PanelContentView.swift`、`Bailey/UI/Components/WindowChrome.swift`。
- `Bailey/Terminal/BaileyTerminalView.swift`、`Bailey/Terminal/TerminalHostView.swift`、`Bailey/Terminal/TerminalSession.swift`、`Bailey/Terminal/TerminalSurface.swift`。
- `Bailey/Editor/SourceTextEditor.swift::FocusReportingTextView`、`Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSServicesMenuRequestor.swift`、`STTextView+NSDraggingDestination.swift`、`Bailey/Browser/BrowserView.swift`。
- `Bailey/Files/FileTreePanel.swift`、`Bailey/UI/Panels/ProjectsPanelView.swift`、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/Shared/Tree/TreeRowStyle.swift`。

### Step 1：先建立可验证的决策矩阵

1. 只用临时本机文件，观察 Finder `fileURL` 实际的 `NSDraggingInfo`／`NSItemProvider` 可读类型、来源、源操作掩码，区分本机 Finder、多文件 Finder、Files 自身拖出、普通选区文本以及网页拖动；不能根据 `draggingEntered` 单一返回值推断最终执行者。
2. **独立验证命中层**：无项目空白区、普通 Dock 内容／标题、编辑区原生 STTextView、浏览器页面／标题、Ghostty 终端、Files 行／外壳、Git 树、项目行、工具栏、分屏空区；确定上层 SwiftUI `.onDrop` 与 AppKit 子视图是否竞争、是否会双回调、是否会阻断子层正常业务。
3. STTextView 仅注册文本/RTF，但 Finder 的 pasteboard 可能携带 URL 与兼容的文字；**若文件会落入正文才在 Bailey 自有 `FocusReportingTextView` 修**，不得改 Vendor 或预置补丁。WebKit 的真实文件上传目标必须保留优先权；不为通用 opener 占据网页整个表面。
4. Finder 真文件拖过 Files 的**文件、目录、压缩目录、空白面板**时，哪些区域有实际可稳定辨识的精确目标？具体文件树目标属于 #5，在它实现前不可落到 P3 通用打开；面板普通留白允许正常打开。实验确认是否仅需在局部抑制或不注册外层 URL 处理，别造全屏 drop blocker。
5. 多窗口、切项目、拖动取消／移出／重进、点击设置窗口、工具面板重挂载后，确认拥有事件的窗口和命中目标。测试只观察正确数据，不能临时打开／关闭用户现有 Bailey。

### Step 2：最小实验与 Red 证据

- 使用仓库现有 `BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`、`BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift` 夹具，在必须的范围添加一次性真实原生拖动实验；永久可复用时可留一项 Red 测试，不重复建立第二套 UI 测试宿主。
- 对无法在 XCTest 中模拟的 macOS Finder→应用跨进程 drag，使用授权的独立图形登录用户／等效真正隔离环境；**`--isolated-ui-test` 只隔离快照，不改变 Bundle ID 与前台 GUI 归属**，不能以其存在证明 Finder 系统路径安全隔离。受限就逐项标注 Blocked 而不是伪造测试成功。
- 输出每个落点的「具体消费视图、是否文件 URL、实际行为、是否需修改、证据类别」，记录在本 Task 的进度 note／实际测试证据位置；不得将猜测写入将要编辑的代码路径。无功能或永久测试变更不制造 commit。

### Step 3：确认执行 Gate

- 必须确认「普通窗口打开」与「Ghostty 输入」互斥、网页上传仍生效、STTextView 普通文本仍插入、Dock／Files 内部拖动不触发通用 opener、Files 文件树具体目标保留给 #5。
- 实测缺口决定 P3-T2/T3 的**最小归属位置**；不先加透明 overlay、全局 event 过滤、持续轮询或一套新 coordinator。若是平台确有无法消除的事件竞争，按真实根因修改计划，不叠加补丁链。

---

## P3-T1 执行证据（2026-10-18，原生 Finder 拖动）

- **系统真实输入类型：** 经过 Finder 原生文件图标拖动后，系统 `NSPasteboard(name: .drag)` 的 item 类型实测为 `public.file-url` + `com.apple.finder.node`，没有 `public.plain-text` 或 RTF；Vendor/STTextView 仅以 `plainText/rtf` 实际写入，因此当前 Finder 文件不会因“文件名像文字”而覆盖编辑缓冲。不要因为 `draggingEntered` 返回 `.copy` 就推测文本真的插入。
- **进程与实际接收者：** 唯一运行测试 Bailey PID 98469，测试快照 `BAILEY_UI_TEST_RUN_ID=8B79EF69-D894-420C-9E2A-E3D198F1279A`，Finder PID 1318、测试窗口 136140，临时目录 `/tmp/bailey-drop-p3.wuIWxq`。正式 Bailey 已在 P2 授权下正常退出，没有动正式数据。
- **Red/实际落点矩阵：** Finder `alpha.txt/beta.txt` 分别拖至 (1) 无项目空白工作区 (2) 原生 `FocusReportingTextView` 正文 (3) Files 文件行明确目标 (4) Files 留白 (5) Projects 项目行 (6) Dock 工作标签标题 (7) Git 面板普通空白；全都未新建 FileTab 或项目（P1 文件路由没有被调用），原始编辑器正文 `let p3 = 3` 未改变，SHA-256 完全一致。普通区需要一个真正的 URL 接收者；不靠猜测添加全窗口透明罩。
- **既有终端 Green：** 同 Finder `alpha.txt` 真鼠标拖到本机 Ghostty 终端 body，系统只在当前 shell prompt 中插入 `/private/tmp/bailey-drop-p3.wuIWxq/alpha.txt `（真实截图 `/tmp/bailey-p3-terminal-after-drag.png`），没有 Enter、没有新 FileTab/项目/文件修改，证明 `BaileyTerminalView` 的 `NSDraggingDestination` 已有合法路径；须保留，并在 T2 仅加固定/动态远端拒绝和控制字节安全检查。
- **现有源码所有权：** `ContentView`、`WorkspaceDockView` 及普通 `PanelContentView` 没有 `fileURL` 目标，WorkspaceDockView 的 `DockTabDragCoordinator` 只接应用内部标签移动；`FileTreeRow.onDrag` 当前把本机与 SSH 都误作为本机 NSURL，需在 T2 改源头；Git/Projects 的 DragGesture 是内部交互，不得被覆盖。WKWebView 自身页面文件上传的实际回归留在 T2/T3 接入通用 opener 后，不能以本轮无浏览器实例假称实测。
- **归属决策：** 原生终端最内层继续独立接收和输入；编辑器正文之外的普通 Window/Dock 占位接入 P1；Files 文件/目录专用目标明确定义为不接受普通 opener、复制留给 Issue #5；浏览器页面区域保留 WebKit 接收，文件放浏览器 chrome 可按普通打开。这些假设在 T2/T3 真 GUI 复验，真正竞争时修所有者而非加蒙层。
- **提交例外：** T1 仅完成可审查的调查/原生行为确认，未修改永久代码或测试，不制造空 Git commit；证据存当前 `plan-p3.md`、临时图与日志，下一步 T2 写 Red 自动测试并逐根因修复。

---

## P3-T2

**独立结果：普通工作区外部文件打开 + 终端的本机／远端严格分流；在接通通用 URL drop 前修复 Files 外拖源头。**

**Files：**
- 必改：`Bailey/Files/FileTreePanel.swift` 中远端行伪 Mac `fileURL` 输出；`Bailey/Terminal/BaileyTerminalView.swift` 中外部路径的正确终端输入和远端拒绝。
- 根据 P3-T1 命中结果再改：`Bailey/UI/ContentView.swift`／`WorkspaceDockView.swift`／`PanelContentView.swift`。只有证实 STTextView 文件放置被错误消费时，才改 `Bailey/Editor/SourceTextEditor.swift::FocusReportingTextView`，并维护 make/update/dismantle 回调生命周期；WebKit 本身不应因通用文件打开被劫持。
- 如固定 SSH 项目启动前身份缺失，最小改动 `Bailey/Terminal/TerminalSession.swift` 或当前创建路径，让终端能根据**明确的项目 SSH 启动意图**与当前动态连接辨认自己是否远端；不能解析 `launchCommand` 字符串，也不扩张整套终端协议。
- Tests：`BaileyTests/Integration/Workspace/WorkspaceIdentityTests.swift`、`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`、`WorkspaceContentIdentityTests.swift`，以及有必要时新增 `BaileyTests/NativeUI/Workspace/ExternalFileDropTests.swift`；针对 Terminal input／来源身份的纯判断可增最小 Unit 测试，不建独立 target。
- Docs：`docs/features/terminal.md`、`docs/features/dock.md`、`docs/features/files.md`、`docs/features/projects.md`，影响网页时再改 `docs/features/browser.md`；涉及新测试发现规则才更新 `docs/testing.md`；中英文 UI 文字归 `Interface.xcstrings`／`Terminal.xcstrings`／`Sidebar.xcstrings`。

### Step 1：Red — 各路径最终副作用

1. Finder 单个／多个本机文件、文件夹、混合批次拖到**无项目空态、编辑内容或非专用框架、标签栏、Git/Projects 面板的普通留白、分屏空组**，P1 公共入口只打开资源，不在磁盘复制／移动。命中窗口属于实际拖动窗口，而非操作结束后的 `NSApp.keyWindow`；跨窗已有相同 FileTab 应回到原有缓冲。
2. 原生 Ghostty 终端表面拖文件：继续**插入路径文本而不是「打开文件」**；无回车、无自动执行。单文件、多文件、文件夹、空格、单引号、反斜线、美元、分号、Unicode 真实 Shell 引用无歧义；**CR／LF／ESC、控制字符**不能因为未经验证的原始 `sendText` 而被解释为按键。对照 Zed `terminal.paste`，先核对 Ghostty 现有 Paste 接口；没有可靠安全语义则明确拒绝危险文件名，不自行添加新终端输入协议。
3. SSH 的**四类状态**：固定 `Project.sshHost` 创建终端但远端握手尚未完成；固定项目已连接／断线；本机 Shell 通过 Bailey handoff 切到 SSH；动态 SSH 退出后恢复本机。前几种对 Finder Mac URL **不得输入远端或偷偷上传**，在**终端这个精确落点**明确拒绝后也不得由父层通用 opener 意外把它当普通窗口拖放处理；退出恢复本机后依本地身份正常输入。特别不要用 `TerminalSession.workspaceIdentity != nil` 作为唯一判断：固定 SSH 项目连接前确实可能 nil。
4. 先覆盖现有 `FileTreeRow` 不论 local/remote 均外拖 Mac `fileURL` 的根因：本机 Files 行拖出仍是本机 URL；远端 Files 行不能构造 Mac URL（可只维持已有「Copy Path」菜单，未确认需求时不实现新文本拖出）；投 Finder／Bailey 通用区／Ghostty 不得打开或输入错误本机同名路径。**此处旧错误路径必须早于新增外部 drop 接收器被移除。**
5. STTextView 正文已编辑／存在撤销、输入法组词中、可从文件读取时，外部 Finder 文件应作为文件打开（若 P3-T1 证实该落点受支持）；原生纯文本、内部选区拖动及 RTF 仍按原 STTextView 语义。切换标签可能触发项目的**既有**失焦自动保存，不能错误要求磁盘始终不变；必须验证真实输入文本、撤销和保存目标。
6. WKWebView 页面文件上传、网页拖动链接和未提交表单仍由 WebKit 自己处理，不能让外层 opener 吃掉或重建 WebView；Browser 工具栏等真正普通区域才可走通用打开（以 P3-T1 实测为准）。
7. 鼠标拖动进入/退出/取消/重复、多文件相邻/跨目录、输入批次部分无效、目标窗口已关闭、设置窗抢焦点、Mac 文件放到当前 SSH 项目普通区：不丢合法项、不写远端、不制造不属于该窗口的 Shell、焦点恢复和主题反馈准确。
8. 非 `fileURL`（文本/网页/图片对象）、App 内 Dock tab/Projects 排序、Files 行拖动、Git 菜单不被通用入口劫持；Unix 特殊文件、Finder alias、符号链接、不可访问项目遵守 P1 既定处理，不建旁路。

### Step 2：Green — 保留唯一接收者，避免补丁链

- 按 P3-T1 的**实际拖动消费视图**接入 Finder `fileURL`，普通区域只转发给 P1 `TerminalManager`，并绑定触发时所属 manager／NSWindow，而不是异步完成时重新找 key window。`NSItemProvider` 异步取 URL 时遵守系统拖放作用域、取消与目标窗口销毁；如果 AppKit 同步 pasteboard 已足够，不要叠加另一套状态／队列。
- 保留 `BaileyTerminalView` 当前最小本机路径插入，远端拒绝要检查**启动目标＋动态真实连接**而不是字符串中是否包含 `ssh`；远端终端明确落点拒绝时不能把文件交给普通父级 opener。Shell 引号只是语法，不一定能防控制字符以键盘事件进入 PTY，优先验证现有 Paste API。不得增加 Return、进程启动、SSH 上传或本机路径回退。
- **先删除 FileTreeRow 远端 `.onDrag` 把 SSH 路径包装为 Mac NSURL 的旧分支**；本机拖出保留；未实现 #5 的目录导入时，不为图方便把远端路径当成本机 URL 的兼容数据留下。
- 优先不改 Vendor/STTextView、不抢 WebKit 的网页文件投放、不为 STTextView 未发生的冲突加 override；如实验证明原生编辑器错误消费，则在 Bailey 自有视图局部处理 fileURL，非文件调用 super，不变更 `FileTab` 的 native editor identity。
- Drop hover 指示只有真实接受动作的区域显示「打开／插入路径」含义；Files 专用目录区域在 #5 前不得误显示「复制成功」或「打开」。不新增布局样式系统、不可达错误恢复兜底或 eventID 黑名单。
- 本任务删掉取代的旧逻辑与无用状态，同步 docs 和本地化，不把上述远端伪 URL 问题留给 P3-T3 才清理。

### Step 3：回归／原子提交

- Red→Green：确实新增测试类时执行 `make test ONLY_TESTING=BaileyTests/ExternalFileDropTests`，以及 `WorkspaceIdentityTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`、`WorkspaceContentIdentityTests`、`TreeRowHitTestingTests` 和相关 `FileTabTests`／`EditorTextInputTests`；完整 `make build`／`make test`、`git diff --check`。核对真正执行的 XCTest、签名、完整返回码。
- 原生窗口合成拖动只证明本进程目标。Finder→真正的终端／编辑区／浏览器／空态必须在**不影响用户当前 Bailey 的独立图形测试环境**做跨进程 E2E，观察实际编辑内容、URL、Shell 输入和终端命令是否执行、WebKit 表单结果；没有环境明确标为 Blocked。
- 每项验证单/双窗口、单/多文件、长／含控制字符路径、SSH 握手前及切换前后、已打开脏文件、重挂载、原始 Finder 文件未被非预期修改、上层 drop 不影响原生子视图；真实用户不可达场景不虚称绿。
- 本 Task 单独中文提交，包含远端伪文件 URL 的**根因清理**、必要原生接收、测试、文档，不推送。

---

## P3-T2 实施与真实验收证据（2026-10-18）

- **真实根因与修正：** 原本在 `ContentView` 根挂 `fileURL` `.onDrop`，Finder 投放网页 `input[type=file]` 后 WebKit 虽显示选中文件，父级仍另开 FileTab；即使改 `NSEvent.mouseLocation` + `NSWindow.hitTest` 屏幕换算也有实际复现，说明**不是坐标偏差补丁能保证事件独占**。现已完全移除根接收和猜测命中逻辑，仅在已确认的普通 SwiftUI 区域局部注册：无项目空态、各 Dock 分组的标题／空组、编辑器与 Diff、Projects/Git/Files 普通面板；浏览器**仅 toolbar** 使用普通打开，其网页正文不注册；Ghostty 终端正文也不注册。通过唯一 `FinderWindowDrop.receive` 加载 `NSItemProvider` 并复用 P1 路由，无第二套队列、全屏透明层或 native view override。
- **空态补救 Red→Green：** 首次 scoped `.onDrop` 挂在未撑满的空态提示本身，真实 Finder 拖到提示外的大空白时无效果；检查 SwiftUI 树后移到 `.frame(maxWidth:.infinity,maxHeight:.infinity).contentShape(Rectangle())` 的整体容器上。相同临时样本从 Finder 拖到 `x334<Finder.minX377` 的有效空白区域后，新隔离快照明确为 **1 window + 1 pinnedFile project + 1 FileTab**，原生 AX 编辑器正文与临时文件内容一致，SHA-256 前后不变。
- **WebKit 结构性独占：** 再用**以前未打开过**的 `upload-only-new.txt` 从 Finder 真鼠标拖入本地 HTML 上传区；页面 AX 明确 `Selected: upload-only-new.txt`，项目仍为 3、已有标签数量 `[1,3,2]`、所选浏览器不变、新文件**没有**进入任何 FileTab，源文件哈希不变。随后将另一独立文件拖到浏览器工具栏，真正新增文件标签，原生 Text Editor 显示对应正文且源文件不变。两种动作不能仅看网页“已选中”就算通过；之前父级双接收日志为真实 Red，已移除诊断 `BAILEY_P3_PROBE`。
- **其它真实目标：** Finder→已有原生编辑区正常新增文件 FileTab，未覆盖当前文件和原始字节；Finder→Files 明确文件行不打开文件、不切换项目，→Files 普通留白新增正确标签、可读正文、源文件 SHA 相同；Finder→本机 Ghostty 原生提示符只插入 `'/private/tmp/.../upload-only-new.txt '` 文本，不发送 Return、无新 FileTab/项目或源文件更改。T1 里真实原始终端路径截图、P2 的 Finder 右键/Dock 文件与目录入口仍为独立原生证据。
- **远端与输入边界：** `Project.makeSession` 显式将固定 `sshHost` 启动意图注入 `TerminalSession`；`acceptsLocalFileDrop` 覆盖固定握手前/中/断线、动态已连接/断线/进程真正退出返回 Mac。本机路径先整批检查 CR/LF/ESC/TAB 等控制字符再做 Shell 转义；无 Return。`FileTreeRow` **源头**不再把 SSH POSIX 路径包装成本机 fileURL；本机行仍保持原生外拖。`WorkspaceIdentityTests` 13/13 通过，`WorkspaceWindowIsolationTests` 增加真实 `NSItemProvider` 双文件打开、异步结果晚到但窗口关闭／改挂其它窗口后不误送，合并 22/22 通过。额外发现并核销**手动前台 ssh 未接管**：通过真实原生 Ghostty 运行 `/usr/bin/ssh -F /dev/null -o 'ProxyCommand=/bin/sleep 12' fixture.invalid`，无任何真实主机／用户 SSH master 网络连接；旧 `acceptsLocalFileDrop` 判断实际 Red 失败、新复用 `unmanagedSSH` 进程事实后 Green 通过，关联 14/14 测试成功。随后检查到 `exec ssh` 会替换原 Shell 而**不变更根 PID**，原 `unmanagedSSH` 只看不同于根 PID 的前台进程导致真实 Red；修订原生测试分别覆盖子进程与 `exec` 两种真实进程形态，直接读 `proc_pidpath`，对 Bailey 固定 SSH 启动保留 `isRemoteLaunch` 排除；Green `PaneRetentionTests + WorkspaceIdentityTests` **27 项、0 失败**，无真实 SSH 连接、无残留受控进程。
- **测试事故/恢复边界：** 一轮拖放目标点错误落进前台 Finder 自己的侧栏，**不是** Bailey 编辑区 E2E，Finder 将仅本轮新建的临时 `editor-drop-new.txt` 移到废纸篓；经逐字节 `cmp` 与 SHA 核对后已从废纸篓还原至独立测试目录，没有触碰用户项目，并将“先确认窗口屏幕边界”写入 `docs/testing.md`。该无效尝试不计为产品成败。
- **仍待 P3-T3 与总体 Gate：** 两窗口真实指向／Files 压缩目录、树根／取消与切出／主题和窄面板、SSH 真机及最低 macOS 15.6 环境覆盖，按 P3-T3 与阶段审计处理。T2 完整 `make build` / `make test` 及原子提交后才可将其标完成；不能拿以上局部 Green 代替全套验收。

---

## P3-T3

**交付：Finder 文件/目录拖入 Files 时，按行、目录或树根真正复制到指定本机文件夹；不会额外打开 FileTab。** 2026-10-18 用户明确扩展了现行目标，提前完成 Issue #5 F2 的 Finder→本机项目导入子集；完整多选、内部拖动移动、剪贴板和远端传输仍由 #5 后续处理。

**证据与边界：**
- [Issue #10](https://github.com/chiimagnus/Bailey/issues/10) 的普通区域打开与 [Issue #5](https://github.com/chiimagnus/Bailey/issues/5) 的 Finder→Files 本机导入被用户明确要求在同一拖放体验中完成；保留其它 F1/F2/F3/F6 的独立后续范围。
- Zed `project_panel.rs::drop_external_files` 与 VS Code `explorerViewer.ts` 的 external import 均是**文件管理器专属**动作；不可照搬到 #10 通用 opener。
- Bailey 当前 `FileTreePanel` 依靠 `FileTreeModel` 展示行、目录压缩、懒加载、右键及 `.onDrag`；`ToolPanelView` 有 `filesTarget`，`isCurrentTarget` 已维护实际工作区后端身份；共享树 `TreeRowStyle` 也服务 Git，不能为未来 #5 先改 shared tree 的语义。

**Files：**
- FileTreePanel 与 ToolPanelView 决定目标文件夹；FileTreeModel 负责刷新与错误显示；LocalWorkspaceBackend 使用 FileManager.copyItem 真正复制并拒绝覆盖，耗时 IO 不阻塞主线程。移除 P3-T2 的临时 `UnavailableFileTreeDrop` 和 Files 外层通用打开，不另写 provider loader 或第二份复制路径。
- Tests：`BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`；如已有 `ExternalFileDropTests` 则扩充同一测试类。文档 `docs/features/files.md`、`docs/features/dock.md` 只更新本次**已实现**的 drop 边界，不宣称 #5 已完成。

### Step 1：Red — 真实 Finder 导入与副作用

1. Finder 文件/目录放在 Files **目录行（含压缩目录末级）**复制到该目录；放在**文件行**复制到其父目录；放在**文件树留白或根目录标题**复制到真实当前根目录。不得另开编辑标签或移动原始文件，成功后原生树及时显示副本。
2. 空、单/多、重复/同名、来源已失效、两个来源同名、文件夹递归进自己或子级、损坏软链接与路径大小写、Unicode、无权限目录、在途切换项目/窗口关闭：不能覆盖既有目标或误写 SSH。有效来源继续复制，失败逐项报告；没有复制前不显示“已导入”。
3. 只有目标实际为本机且当前项目/根目录/原窗口仍有效时接受；固定 SSH、动态远端 Files 显示禁放，不回退到父级普通打开、更不自动上传。本机 Files 外拖仍提供原 fileURL，远端路径不伪装 Mac URL。
4. 窄/宽面板、压缩目录、混合文件夹/文件、行之间移动或取消、深/浅、中英文、双窗口与不同 project 不能出现双消费或错误提示；原有 Git 树、文件名编辑、目录展开、菜单和 Shell 身份维持。
5. Finder→Files **默认复制**，不移动源项、不自动覆盖；明确的冲突报错代替危险 Replace。多选/剪切/粘贴、树内移动、跨机器导入仍交给 #5。

### Step 2：Green／Refactor

- 普通 `FinderWindowDrop` 唯一异步 provider 加载器保留原窗口身份，目标区域只选择末端动作（打开、添加项目、复制）。Files 外壳不再拥有普通打开入口，子目录和文件行由自己的本机 DropDelegate 指向准确的绝对目录。
- `LocalWorkspaceBackend` 后台用 FileManager.copyItem 批量处理，拒绝同名目标（包括 dangling link）、递归复制、无权限/失效路径，返回成功/逐项失败；不自行删除源项。`FileTreeModel` 校验原 root/scope，刷新当前可见目录和缓存，并经现有 `onError` 呈现失败，不设第二套复制 API/queue。
- 不接入新的 hover 状态机、跨机器上传、隐式替换或过度文件管理器模块；本 task 同时删除 `UnavailableFileTreeDrop` 的旧语义并更新文档。

### Step 3：真实 E2E／提交条件

- 测试实际磁盘文件与目录树的复制、重名、符号链接、双来源冲突、自/子目录、批次部分成功、切换根目录、SSH 拒绝及源文件字节，接入原 `FileTreeTests`、`TreeRowHitTestingTests` 和 `WorkspaceWindowIsolationTests`；`make build`、`make test`、严格验签、`git diff --check` 全部核对退出码。
- 原生隔离 App 中从 Finder 拖到 Files 根标题、空白、文件行、目录行与压缩目录：核对物理目标新文件、源 SHA、行出现时间、项目标签数和错误弹窗；原有普通编辑区/终端/WebKit/Projects 行为留到 P3-T4 做总体验收。
- 每项不可安全执行的环境记录阻塞与补验条件。同步 Files、Dock、README、testing 文档，代码与测试一个中文 commit，不推送。

---

## P3-T4

**交付：每个区域各行其职。** Projects 面板用 `TerminalManager.addLocalItems` 新增/复用**显式本机项目**（文件保留 pinnedFile，目录不建 Shell），而非 `openExternalFiles` 的普通文件标签意图；项目行内部排序手势不被外部文件 URL 冒充。顶部工作标签栏与普通编辑区用既有 `TerminalManager.openExternalFiles`，将普通打开区域（顶部标签栏、空组、编辑／Diff、Git 面板及浏览器工具栏）的项目和 `DockGroup` ID 传至原文件路由，同一文件复用原窗口原 FileTab（不迁组），新文件落入实际命中分屏（含空组），目录按普通打开建项目，不覆盖当前内容。Git 普通面板、空态仍执行普通打开；WebKit 正文上传、Ghostty 本机路径输入和 SSH 拒绝不变。

Red→Green：在同一受控图形会话用真实 Finder 验证 Projects 文件/文件夹批次/重复/不同窗口，顶部标签栏新/旧文件、非选中分屏与空标签组、跨项目新旧文件、真实空态/编辑区、网页上传、终端本机/SSH、Files 目标与内部 Dock/Projects 排序互斥，核对项目数、pinnedFile、标签身份/顺序、磁盘字节、原生 WebKit 文件表单和终端无 Return；Build/全量 XCTest/验签/长期文档，原子提交不推送。

---

## Feature 完成 Gate

按实际源码和每项 commits 核对：
- P1 已打开文件的唯一标签、固定 file-pinned 与目录项目分离、SSH 目标和恢复时序；没有新全局文件索引或重复队列。
- P2 真实 `CFBundleDocumentTypes`、`LSHandlerRank=Alternate`、正确系统文件回调和签名包验证；Finder Services、用户默认关联不变。
- P3 每个区域的语义分别兑现：普通工作标签打开、Projects 显式添加项目、Files 真正复制文件／目录进指定**本机**文件夹且无静默覆盖，终端纯路径输入并拒绝所有 SSH 误投，WebKit 原生上传；Files 复制与其他区域无双重消费。#5 剩余内部文件管理功能仍可独立演进。
- 所有替换分支在各自 Task 即时清理，旧 SSH→Mac 伪 fileURL 不保留；无透明全窗口阻断、无第二套 drag engine、无重复复制引擎、无过度防护。覆盖适用的全部环境、失败与极端组合，实测缺口标记，不能用全绿的模型单测替代真正 Finder E2E。**执行前审查不创建 `audit**.md`，实施完成后才按真实 commits 审查。**
