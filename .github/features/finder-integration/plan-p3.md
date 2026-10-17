# Plan P3 — Finder 原生窗口拖放与专用目标隔离

**Goal：** Finder 文件／文件夹放到 Bailey 的普通窗口内容区域时打开本地资源；放到本机 Ghostty 终端时按既有 IDE 语义插入文件路径；明确的 Files 文件树目标留给 Issue #5。三类区域互不抢事件，也不影响现有原生编辑、网页拖动、SSH 和 Dock 操作。

**Non-goals：** 本阶段不提供 Files 文件／目录的复制、移动、粘贴、覆盖确认、Finder→目录导入、远端上传或任何文件系统新写操作；这些是 [Issue #5 的 F1/F2](https://github.com/chiimagnus/Bailey/issues/5)。不做新的 Drag-and-Drop 引擎、覆盖全窗口的透明层、通用 NSEvent monitor、Shell 自动执行、PDF 预览或独立设置项。

**真实前提：**
- `Bailey/UI/ContentView.swift` 的工作区分为空状态和 `WorkspaceDockView`；其多个 Overlay、`WindowChromeAccessor` 都参与命中／生命周期。
- `WorkspaceDockView` 用自己的 SwiftUI `DragGesture` / `DockTabDragCoordinator` 移动内部标签，项目面板也有独立排序；不可将内部 DragGesture 当成 Finder 的 `fileURL` drop。
- `BaileyTerminalView` 已是 `NSDraggingDestination`，注册 `.fileURL`，现有 `performDragOperation` 转义路径后 `sendText`，**不显式发送 Return**。
- `TerminalSession.workspaceIdentity` 从动态连接／`initialWorkspace` 推断机器，但 **`Project.makeSession` 以 `sshHost` 直接生成远端 SSH 启动命令时 `initialWorkspace` 可以为 nil**；连接尚未接管前 `workspaceIdentity` 也可能为 nil，绝不只用该字段来判断远端路径是否允许输入。
- `Vendor/STTextView/.../STTextView+NSServicesMenuRequestor.swift` 注册的拖动类型只有字符串／RTF；`.../STTextView+NSDraggingDestination.swift` 可接受外部文本并插入正文。**不能直接推断 Finder 的文件 URL 一定被它抢走**，先看实际 pasteboard 类型和命中结果。
- `FileTreeRow` 目前不论本机还是 SSH 都把路径作为 Mac `NSURL(fileURLWithPath:)` 外拖，属于**真实错误的源头**；必须在启用新通用文件 URL 接收器之前改掉。Files 专用落点由 Issue #5 处理，不在本次建设 FileManager.copy。

**Acceptance：** Finder 多文件／文件夹在窗口非专用区域正确打开；本机终端只安全插路径，不提交命令；固定 SSH 项目连接前／中／后、自动项目中动态 SSH 均不把 Mac 路径发给远端；Files 具体文件树落点不被外层 opener 吞掉、也不假复制；文本编辑器、WebKit 网页文件上传、Dock 与项目内部移动照旧。真实外部拖入须独立 Finder E2E 验证，不能只测 ViewModel。

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

## P3-T3

**独立结果：Files 的文件树精确落点与通用窗口接收互斥，预留 #5 的完整文件管理职责；完成 #10 的端到端原生拖动验收。**

**证据与边界：**
- GitHub [Issue #10](https://github.com/chiimagnus/Bailey/issues/10) 明确写出「窗口通用打开 ≠ Files 树复制／移动，#5 负责目标目录操作」。[Issue #5](https://github.com/chiimagnus/Bailey/issues/5) 的 F2 涵盖 Finder 文件放进本地 Files、复制／移动、名称冲突；本阶段不提前实现 F2 的磁盘动作。
- Zed `project_panel.rs::drop_external_files` 与 VS Code `explorerViewer.ts` 的 external import 均是**文件管理器专属**动作；不可照搬到 #10 通用 opener。
- Bailey 当前 `FileTreePanel` 依靠 `FileTreeModel` 展示行、目录压缩、懒加载、右键及 `.onDrag`；`ToolPanelView` 有 `filesTarget`，`isCurrentTarget` 已维护实际工作区后端身份；共享树 `TreeRowStyle` 也服务 Git，不能为未来 #5 先改 shared tree 的语义。

**Files：**
- 如 P3-T1 的真实命中测试表明有 FileTree row 与外层 opener 冲突，仅修改 `Bailey/Files/FileTreePanel.swift` / `Bailey/UI/Panels/ToolPanelView.swift` / `Bailey/UI/ContentView.swift` 中**必需的局部文件树落点边界**；不得改 `FileTreeModel`、`WorkspaceBackend`、`LocalWorkspaceBackend`、文件操作 UI 或添加复制函数。
- Tests：`BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`；如已有 `ExternalFileDropTests` 则扩充同一测试类。文档 `docs/features/files.md`、`docs/features/dock.md` 只更新本次**已实现**的 drop 边界，不宣称 #5 已完成。

### Step 1：Red — 只验证真正属于 #10 的结果

1. Finder 文件放在**FileTree 明确文件夹行、文件行、目录压缩末级或文件树 root 的可确定专用目标**：若 #5 尚未处理，此动作不能被通用窗口 opener 截获，也不能在项目根执行不被用户知道的复制／移动；鼠标反馈不得说「已接受复制」。不把这类专用区域的「当前暂不支持」错误地算成 #10 漏开文件。
2. Finder 文件放在**Files 面板真正的普通非专用留白、标题区**或该面板外的普通工作区：执行 #10 的「打开文件」，不能误触发已有 Files 行右键／新建／重命名。真实目标界限依据 P3-T1 实测，不猜测 SwiftUI 父子顺序。
3. Files **本机行向 Finder／终端外拖**仍保留合法 fileURL，**SSH 行不再伪装 Mac URL**；项目快速切换、断线、不同远端同名、拖放取消与 Files/Git 共享行交互不损坏。
4. 多文件、拖过多个文件树行后移出、窄面板、水平滚动、压缩目录、深色/浅色、中英文、两窗口不同 project：不能遗留错误 hovered/drop 状态，也不出现双开、本机/SSH 串目标、已有 Shell 被重建。
5. 复制/移动、批量粘贴、文件树内拖动和覆盖对话框**完全不实现**；对应正向 E2E 留给 #5，不能为本期制造重复 helper 和未使用状态。

### Step 2：Green／Refactor

- 只修 **实际能复现**的外层 opener 与 FileTree 精确目标优先级冲突；首选最小局部行为，使**不支持的目标返回不接受，而不是接受后无操作**。不为未来 #5 加空 `copy` 方法、悬浮文件管理器状态机、覆盖确认或有歧义的视觉假阳性。
- 如 P3-T1 已证明当前根层能够正确区分 Files 行，P3-T3 可只落永久回归测试和准确文档；**没有生产代码需要修就不为了凑 commit 添加代码**。
- P3-T2 已移除的远端伪 URL 旧分支只回归检查，不留第二层兼容绕过。内容保存和焦点仍遵守 `Project` 与 `TerminalManager` 现有失焦自动保存契约。

### Step 3：真实 E2E／提交条件

- 自动相关用例：`TreeRowHitTestingTests`、`WorkspaceWindowIsolationTests`、新增 `ExternalFileDropTests`（若存在），并按实际影响复测 `FileTreeTests` 和 `PaneRetentionTests`；运行 `make build`／`make test`／`git diff --check`，检查退出码、测试发现和签名。
- 在隔离图形环境完整覆盖 Finder `Open With`／Dock／`open -a`／普通区/终端/Files 精确目标/网页上传/文本拖动/内部移动。检查真实文件标签、原有文本缓冲、Shell 的输入、Files 行表现和源文件磁盘字节；**#5 的实际复制／移动不纳入 #10 验收**。
- 无法安全实测的系统或目标逐项记录阻塞、影响和补验条件；不能以模型测试充数。本 Task 仅在产生真正测试／功能／文档变更时原子提交，不推送。

---

## Feature 完成 Gate

按实际源码和每项 commits 核对：
- P1 已打开文件的唯一标签、固定 file-pinned 与目录项目分离、SSH 目标和恢复时序；没有新全局文件索引或重复队列。
- P2 真实 `CFBundleDocumentTypes`、`LSHandlerRank=Alternate`、正确系统文件回调和签名包验证；Finder Services、用户默认关联不变。
- P3 普通窗口打开、终端纯路径输入且拒绝固定/动态 SSH 错误路径、STTextView/网页和内部拖动行为；Files 精确专用目标**不能被通用打开吞掉**，与 #5 边界可后续无冲突地接入。
- 所有替换分支在各自 Task 即时清理，旧 SSH→Mac 伪 fileURL 不保留；无透明全窗口阻断、无第二套 drag engine、无文件树复制补丁、无过度防护。覆盖适用的全部环境、失败与极端组合，实测缺口标记，不能用全绿的模型单测替代真正 Finder E2E。**执行前审查不创建 `audit**.md`，实施完成后才按真实 commits 审查。**
