# Plan P3 — 原生窗口拖放与 Files 目录导入

**Goal：** Finder 文件／目录投放到 Bailey 时，最具体的真实接收目标执行一次正确动作：普通工作区打开、本机终端插入安全路径、Files 本机目录复制；非文件拖动与原有 Dock／编辑器／浏览器行为不变。

**Non-goals：** 不实现完整内部文件搬移、SSH 上传、远端 Files 导入、文件预览升级、新拖放框架或自定义拖放事件总线。Finder 普通区打开不默默把文件复制到项目目录。

**Approach：** Bailey 同时包含 SwiftUI Dock、AppKit Ghostty、STTextView 和 WKWebView。外部文件 URL 的 `NSDraggingDestination` 命中不能靠经验假设：P3-T1 进行最小原生实验并产出确定接收层的证据；P3-T2 接入通用打开与现有本机终端路径输入；P3-T2 先清理远端 Files 外拖源伪 URL，P3-T3 再负责 Files 精确目录的副本导入。三个任务均使用 P1 已建立的窗口／文件打开路径，不复制 project resolver。

**Acceptance：** 放在普通区 → 正确文件标签；放在本机终端 → 输入引用路径、绝不执行；放在 SSH 终端 → 拒绝 Mac 路径；放在 Files 本机文件夹／根 → 复制真实磁盘内容，冲突明确且不破坏旧数据；放在 SSH Files → 不执行错误本机动作。跨窗口已有同文件则定位原窗口／标签，不创建第二份可写缓冲。

**Rules：** 保护当前 Shell、WebView、TextKit 原生对象、`DockTabDragCoordinator` 和项目排序手势；不抢夺内容区的文本／链接或非文件拖放；UI 反馈说明真实动作；外部拖拽不静默写入磁盘，只有**明确 Files 本地复制**才属于允许的文件系统写入。

---

## P3-T1

**独立结果：找到唯一真实可达的 Finder DnD 接收层，避免直接写一套错误的遮罩。**

**Files / call paths（已核对）：**
- `Bailey/UI/ContentView.swift` 主窗口 Group、空状态及 command/tab switcher overlays。
- `Bailey/UI/WorkspaceDockView.swift` 的 `DockTabDragCoordinator / DockTabGroupView`，header、内容与 split。
- `Bailey/UI/Panes/PanelContentView.swift` → `Bailey/Terminal/TerminalHostView.swift` 和 `Bailey/Terminal/BaileyTerminalView.swift`（终端注册 `.fileURL`），以及 `Bailey/Editor/SourceTextEditor.swift::FocusReportingTextView`／`Bailey/Browser/BrowserView.swift` 的原生表面。**已核对本地 `Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSDraggingDestination.swift`：外部 draggingEntered 返回 .copy、performDragOperation 可把 pasteboard 的纯文本插入正文，因此根层 SwiftUI `.onDrop` 不能被假定优先接收到 Finder 文件。**
- `Bailey/Files/FileTreePanel.swift` 已有每行 `.onDrag`；`Bailey/UI/Panels/ProjectsPanelView.swift` 已有自己的高优先级项目排序 DragGesture。
- 现有原生集成夹具 `BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`、`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`、`BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`。按需扩充其中可复用的测试，不建额外 XCTest target。

### Step 1：把平台未知收敛为可验证问题

1. Finder 的本机 `fileURL` 以一个／多个文件、目录、文件夹与文件混合放入空工作区、普通内容区、tab strip、面板、Files 根／文件夹行、Ghostty、STTextView、WKWebView，分别哪个 `NSDraggingDestination` 真正消费？SwiftUI 根 `.onDrop(of: [.fileURL])` 与原生子视图是否会双发？浏览器页面的原生文件上传目标必须继续由 WebKit 接收，不可由通用「打开文件」抢走。
2. 文件 URL 在 SwiftUI `NSItemProvider` 异步读取时，最初**接收的 manager/window**是否还存在、是否会在数据返回前因焦点变化而误送到另一窗口？原生 AppKit `NSDraggingInfo.draggingPasteboard` 对本地 `NSURL` 是否可以更简单地**同步获取**，避免无用异步状态机？
3. Ghostty 已有 `registerForDraggedTypes`／`performDragOperation` 是否被上层捕获；**STTextView 本地副本已确定会报告 .copy 并尝试从外部载荷读取纯文本**，必须实测 Finder 文件 URL 是否会被误插入 `FocusReportingTextView` 正文。编辑器普通文本拖动、浏览器网址、内部 Dock tab、项目列表排序仍要由原有目标处理；跨区域滑过、取消、移出窗口、面板关闭后，hover 不得残留。
4. 文件夹放到本机 Files 精确文件夹行与放到 Files 空白／普通背景的可区分区域如何判定？如果没有准确的叶子目标，本期不能偷偷复制文件到错误目录。

### Step 2：小范围原生实验／决策

- 使用现有 NSWindow + NSHostingView 测试夹具与临时文件；需要系统真实拖动才可证明的部分，在**不影响用户运行中的 Bailey** 的隔离进程／图形登录环境下验证（或标注阻塞）。
- 首先检查**不新增生产代码**的原生接收行为，形成每个目标的「接收层 → 行为 → 实际测试证据」映射。仅必要时在隔离测试中加临时诊断；清理临时实现，不保留调试开关和日志框架。
- **首选**：最小 SwiftUI 局部 `.onDrop` 负责普通区，原生 Ghostty 负责自己，Files 行自己的 `.onDrop` 优先负责目录。**对已确认抢夺拖动的原生 STTextView**，优先在 Bailey 自有 `FocusReportingTextView` 的局部拖放覆盖中精准识别外部 file URL、转给 P1 opener，对非文件文本调用原 `super`；不能直接修改 Vendor 的 STTextView 原生拖放实现。若 WKWebView 或其它容器另有确证缺口，再仅修改受影响的原生容器。禁止透明全窗 overlay、全局 NSEvent monitor、自定义 DnD framework。
- 探索停止条件：每个支持目标可唯一收到文件 URL，普通文本／网页／标签拖动未被窃取，放下、移开或取消不遗留伪目标。结果交给 P3-T2/T3 的具体改动位置，不能只凭静态推断假定成功。

### Step 3：证据与收尾

- 为可自动化的真实窗口拖放事件增加必要且可持续的 NativeUI 测试，核实目标实际收到一个接收动作和原有动作未被破坏；只调用 `TerminalManager.addLocalItems` 的测试**不构成拖放证据**。
- 覆盖两窗口、空／有项目、终端、编辑器、浏览器、Files、Git、tab strip、非文件载荷、多文件及取消等已识别目标；无法安全向 Finder 发起真实 drag 时，将它列为 P3 最终 Gate 的阻塞而不虚报。
- 若仅有调查材料，无生产或永久测试文件变化，不制造空 commit；有保留测试时独立提交，其他 Task 再引用。证据更新到当前任务 note／执行记录，不预建 `audit-p3.md`。

---

## P3-T2

**独立结果：Finder 文件／目录普通窗口打开；本机终端保留安全路径输入、SSH 终端拒绝错机器路径。**

**Files（最终接收层由 P3-T1 的证据限定）：**
- Modify：`Bailey/UI/ContentView.swift`，按实测必要时 `Bailey/UI/WorkspaceDockView.swift`／`Bailey/UI/Panes/PanelContentView.swift`；`Bailey/Editor/SourceTextEditor.swift::FocusReportingTextView` 为已发现的第三方原生拖动命中冲突的**首选自有修复位置**（具体是否调用取决于 P3-T1 实测），必须同时保留文字拖动的 `super` 行为及已有 `makeNSView/updateNSView/dismantleNSView` 的回调生命周期；`Bailey/Browser/BrowserView.swift` 仅当原生实验证明必要才改。
- Modify：`Bailey/Terminal/BaileyTerminalView.swift` 的文件 drop 入口；根据源头实际可达状态需要时在 `Bailey/Terminal/TerminalHostView.swift` 与 `TerminalSession.swift` 极小地传递远端身份，**不要为单一判断扩大整个 TerminalBackendSurface 协议**。**同一任务修改 `Bailey/Files/FileTreePanel.swift` 的远端 `.onDrag`：新增通用 URL 接收前必须先终止 SSH 文件伪装 Mac URL 的旧路径。**
- Use：P1 `Bailey/Workspace/TerminalManager.swift` 统一外部打开路径；不在 UI 新建项目管理逻辑。
- Tests：按实测需要扩充 `WorkspaceWindowIsolationTests.swift`、`PaneRetentionTests.swift`，可新增 `BaileyTests/NativeUI/Workspace/ExternalFileDropTests.swift` 集中原生 drop；`WorkspaceContentIdentityTests.swift` 与 `AppMenuIsolationTests.swift` 的相关焦点回归，另验证远端 Files 行不再输出本机 fileURL。
- 文档：`docs/features/dock.md` 说明目标路由，`docs/features/terminal.md` 说明本机插路径／远端拒绝，**`docs/features/files.md` 同步远端 Files 不再伪造本机 URL 的外拖行为**，`docs/features/ssh.md` 若远端外拖边界变化则同步；`docs/features/browser.md` 只在网页内容区行为确有变化时更新；`docs/ui.md` 有实际提示才更新，`docs/testing.md` 在引入新的长期测试类时同步测试入口；`README.md` 加入 Finder 拖入普通窗口。对应字符串使用现有 `Bailey/Resources/Localization/Interface.xcstrings`／`Terminal.xcstrings`。

### Step 1：Red，实际触发前提与最终结果

1. Finder 本机文件／目录拖入**空窗口、普通编辑区域、浏览器标签外壳／标题、Git 空白面板、tab header、分屏空组**；编辑区新建／选中原文件内容标签，目录新增／选中项目，不复制磁盘内容。**网页有真实文件上传 drop target 时 WebKit 优先**，不由外层统一 opener 抢走。**文件位于别窗已打开时定位该窗原 FileTab**，不能创建两个可能写入同一源文件的缓冲。
2. 多选同一目录、跨目录与目录＋文件混合、重复拖入、不同放置窗口、放下后 keyWindow 被设置窗口／别窗抢走；仍按真实接收上下文消费一次；不因一次加载失败丢弃其它有效文件。
3. 本机 Ghostty 本身是精确接收目标：一个或多个文件／目录，常规路径含空格、单引号、分号、美元符、反斜杠、Unicode，**只插入被正确 shell quote 的路径＋分隔空格，无回车、无执行**。特别把换行、CR、ESC 和其它控制字节文件名放进真实 PTY 测试；`shellToken` 的引号转义本身不能阻止终端把控制字节当按键解释。若没有经过证明的安全编码／Paste API，必须拒绝含终端控制字节的名字并反馈，而不是把原字节发送给 Shell。
4. 通过真实 `TerminalSession.location` 或 `initialWorkspace` 处于 SSH 的终端，在连接正常、断线、SSH 启动中与重挂载状态下都不得接受本机 URL 为远端 Shell 路径；普通区在 SSH 项目中接收 Finder 本机文件，则用 P1 本机项目。**不能把全部 Finder 拖放都禁止**，这样会使用户从 SSH 项目无法打开 Mac 文件。
5. `STTextView` 正在输入法组词、脏编辑、选区、undo 和在途刷新时，Finder **fileURL** 放下只开新标签，不因同一 pasteboard 也有 `public.plain-text` 而把路径插进正文；纯文本／富文本与内部选区拖动仍调用 STTextView 原方法。选择另一标签可能触发**当前既有**失焦自动保存，测试不能要求旧脏文件的磁盘字节一律不变；应验证缓冲、撤销和保存目标正确。若采用 `FocusReportingTextView` 的局部文件 drop 回调，重挂载后的 callback 必须更新，拆卸后清空，不能引用已关闭窗口或泄漏 `FileTab`。
6. `WKWebView` 已有未提交表单、网页滚动、链接拖动、文件上传表单时不可重建 WebView；**网页原生接受的文件放置优先让网页处理上传，不触发外层打开**。Dock 标签内拖、Projects 排序、Files 内部 drag、Git 项目交互不受影响。
7. **源头先修复**：SSH Files 行当前发布伪造本机 `fileURL` 的外拖载荷；若根层通用打开已经生效，会立即变成错机器文件打开。先令远端行只输出真实受支持的纯文本路径（或不允许不支持的外拖），然后再接通通用 opener；验证拖至 Bailey 窗口／Ghostty／Finder 不被误认成 Mac 文件。此项不得等 P3-T3 才做。
8. 空数据、非法／非 file URL、无权限、失效文件、文件放下后被删除、未知后缀、图片、文本超限、二进制、混合有效／无效批次；真实结果是文件内容或已有不可用反馈，不修改原始字节。
9. 浅／深色，中／英文，多窗口、全屏／窄布局、各分屏方向、drag enter→exit→reenter、取消、重复 drop、窗口关闭／切项目：目标提示不残留，原 Native surface、焦点及项目选择保持可用。

### Step 2：Green／Refactor

- 仅按 P3-T1 已证实的命中层在 `ContentView` 或必要子区域接收 `fileURL`，使用 `TerminalManager` 的**实际接收窗口引用**；避免异步读取后重新查 NSApp.keyWindow。Apple [`.onDrop(of:isTargeted:perform:)`](https://developer.apple.com/documentation/swiftui/view/ondrop%28of%3Aistargeted%3Aperform%3A%29-f15m) 要求 `NSItemProvider` 的内容加载**在 perform 闭包返回前启动**，否则安全边界会失效；完成可以异步，但必须保留最初的接收窗口和有效期。AppKit pasteboard 同步可读时不额外造异步 loader / coordinator。
- 最具体的**本机终端目标**继续使用现有 `BaileyTerminalView.shellToken / sendText`；远端判断优先复用 `TerminalSession.workspaceIdentity`（已经由 `TerminalBackendEvents` 连到表面）与已知 SSH 状态，以证据选择最小必要的只读传递。不能为这一项重写 `TerminalHostView` 的生命周期或新建终端协议。远端时返回“不接受”，不能将 Mac URL 发送到远端，更不能执行／上传；本机输入前阻止危险控制字符未经安全证明直接进入 PTY，保留原有本机合法路径 drag 语义。
- 普通窗口 drop 只调用 P1 外部打开路由，不调用手动项目添加全套逻辑，也不对文件目录复制。悬停反馈准确表示「打开文件／添加文件夹」，可复用 `Theme`，`.allowsHitTesting(false)` 的纯提示不得抢 NSDraggingDestination。
- **先在 `FileTreePanel.swift` 删除 SSH 行伪造 Mac URL 的旧 `.onDrag` 分支**，保留本机文件 URL 外拖，远端只保留确实支持的文字路径能力；这个源头修复必须先于通用接收器生效，不能留到 P3-T3。新事件链替代的其它旧分支同任务清理；P3-T3 才负责文件树目录目标复制，不为防双发加第二套全局 eventID 黑名单。
- 本任务同步用户入口／所属文档及中英文字符串，避免代码先合并后补说明。

### Step 3：验证及原子提交

- Red → Green：按新增类执行 `make test ONLY_TESTING=BaileyTests/ExternalFileDropTests`；以及 `WorkspaceWindowIsolationTests`、`PaneRetentionTests`、`WorkspaceContentIdentityTests`；完整 `make build`、`make test`、`git diff --check`，检查实际 XCTest 发现、App 签名与返回码。
- **NativeUI 与 Finder 真机区别报告**：原生 `NSWindow` 的真实接收层测试 + **Finder→真实终端／编辑器／浏览器／空态**的进程外拖动，两种都检查唯一消费、原生文件内容、真正的 Shell 输入与远端拒绝。必须使用隔离实例，不准操作用户前台 Shell。
- 文件数据与程序状态：Finder 源文件未被非预期修改、旧 editor 的正文与 undo、合法失焦自动保存状态、WebView 表单、Shell 身份、选中标签与实际窗口、SSH 后端执行计数是观察结果；模型字段变化不是完成。
- 无最低 15.6 真机、输入设备／语言、受限文件提供方的测试环境时逐项注明可用环境、未测风险和补验门槛，不能省略真正相关的边界。
- 本任务独立中文提交，同时处理受影响文档和旧路径清理；不推送。

---

## P3-T3

**独立结果：Finder 外部文件真正复制到 Files 本地目录；复验 P3-T2 已修正的远端拖动源在新目录接收路径上仍然安全。**

**证据与边界：**
- 审查时确认 `Bailey/Files/FileTreePanel.swift::FileTreeRow.body` 当前无论本机／SSH 均通过 `NSItemProvider(object: URL(fileURLWithPath: item.path))` 发布伪装本机的 `fileURL`；其 `isRemote` 已用于限制「在 Finder 中显示」，却没有限制拖动载荷。这是**当前可达的源头问题，必须由先行的 P3-T2 清理**；本任务补验新导入路径不再接收远端伪 URL。
- `FileTreePanel` 已知道 `sshHost`、`session`、`FileTreeModel.rootPath`；`ToolPanelView` 具有 `filesTarget` 和 `isCurrentTarget`，可复用现成作用域检查。
- `FileTreeModel` 已有 `onError`、`sync/rebuild`、当前 root/backend/epoch，但**没有外部文件复制操作**；`WorkspaceBackend` 没有抽象 `copy`，本期仅有本地 Files 外部导入，绝不为了 SSH 将复制扩展成新远端协议。
- 上游：Zed [project_panel.rs::drop_external_files](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs) 将外部内容复制到选定目录并处理冲突；VS Code [fileImportExport.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/fileImportExport.ts) 与 [explorerViewer.ts](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts) 为资源管理器专用外部导入，与编辑区打开区分。

**Files：**
- Modify：`Bailey/Files/FileTreePanel.swift`（本地目录行和 Files 根精确目标）、`Bailey/Files/FileTreeModel.swift`（复用当前刷新／失效／错误机制）、`Bailey/UI/Panels/ToolPanelView.swift`（仅必要时传目标身份、接收窗口的原生确认）。远端外拖源在 P3-T2 已修正，本 task 负责回归验证。
- Optional local IO owner：`Bailey/Workspace/LocalWorkspaceBackend.swift`；选择最小可测的本地 FileManager copy 实现，不扩展 `WorkspaceBackend` 为远端并不存在的能力。
- Native confirmation：优先用现有 `WorkspaceNativeDialogs` 的 owner-window sheet 模式；真正需要时才扩展 `Bailey/UI/ContentView.swift`，确认作用域在发起窗口而非别的 key 窗口。
- Tests：`BaileyTests/Integration/Files/FileTreeTests.swift`、`BaileyTests/NativeUI/Shared/TreeRowHitTestingTests.swift`、`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`；补 P3-T2 的 `ExternalFileDropTests`（如新增）。
- 文档：`docs/features/files.md` 的外部复制／源头机器隔离、`docs/features/ssh.md`（实际涉及远端 Files 外拖语义时）、`docs/features/dock.md` 的专用目标优先级、`docs/testing.md`（引入独立长期测试类时）、`README.md` 的 Files 文件导入；中英文业务文字使用 `Sidebar.xcstrings` 或 `Workspace.xcstrings`。

### Step 1：Red：目录复制的真实磁盘行为

1. Finder 拖一个文件、多个文件和整个文件夹到**本地 Files 的目录行、压缩目录的真实末级行、文件行（其父目录）、Files 根空白区域**：目标是对应真实本地目录，不是任意当前项目根或其他机器；复制后原始文件依然存在，目标字节一致，文件树刷新可见。
2. 外部文件只放在文件树旁的编辑区／tab／Git 面板时仍是 P3-T2 的**打开**，绝不能复制；拖到 Ghostty 只插路径。文件树内原先的 row 拖动／文本复制行为不得被“所有拖动都复制”改变。
3. 同名文件、同名文件夹、不同大小写但实际同路径、已有目录、文件软链／失效软链、源和目标同一路径、文件夹复制进自己的子目录：不无声覆盖旧文件，不触发递归复制；冲突用真实目标窗口的明确选择「替换／取消或跳过」，取消保留两个原始位置的字节。
4. 替换得到明确同意后仍必须确保失败不遗留被清空的目标；使用 macOS 文件系统提供的可靠替换能力，而不是先删目标再 `copyItem`。不把用户取消或读取失败伪装成成功；文件夹冲突的可用处理按 FileManager 契约验证后选最小安全方案，不把未经验证的递归合并算法写进项目。
5. 无权限、源在途消失、目标目录在途重命名／删除、剩余磁盘空间不足、文件提供方 iCloud 未就绪、混合批次部分成功、源是 symlink／包目录，复制中切项目／关窗口：已完成文件可辨识，未完成保留错误、其它数据不受破坏；在执行前核对真实本机目标和当前 `PanelContext.Identity`，不用项目名称猜地址。
6. `FileTreeRow.isRemote` 为 true：任何远端文件／目录都不得生成 Mac `fileURL`，更不允许被投给 Mac Finder、终端或通用 opener 而打开本机同名路径。保留有意义的「Copy Path」文字行为（如提供纯字符串外拖，必须标明远端身份；否则不支持外拖），不实现 SSH 上传／远端 FileManager copy。
7. 原 Files/Git 树的缩进、22pt 交互行、滚动、右键、创建/重命名、SSH 后端刷新、窗口身份、项目切换、撤销和焦点均不破坏；浅／深主题、中／英文、长路径／Unicode、压缩目录、窄面板、从 Files 内部拖文件与 Finder 外部拖文件分别核验。

### Step 2：Green／Refactor

- 只在**本地 Files 目录行／根**装配外部文件 URL 专用 drop；落点精确解析目标目录，文件行归父目录；远端行不接受该本地复制行为。不要增加通用全屏放置区域、模拟文件移动或更改 shared Git 树的 row 模型。
- 在正确业务所有者内部用本机 FileManager 的复制能力，将 Finder 本机资源**从磁盘复制**到本机目标目录（不是从内存中尚未保存的 FileTab 缓冲复制）；实际文件 IO 不能阻塞主 actor。完成后复用现有 `FileTreeModel` 刷新及 `FileTreePanel.refreshGitStatus` 回调，不新建 Git 文件监听器。复制前验证同名冲突及不安全源/目标关系，冲突由**发起窗口的原生 sheet**选择；未明确确认不覆盖。显示当前已有 `FileTreeModel.onError` 通道，操作成功后使用原树模型的刷新／缓存失效入口（没有必要不要重新实现缓存）。
- **复核 P3-T2 已删除的远端 Files 行伪 Mac `fileURL` 分支未在新增外部复制目标中复活**；本机行仍能拖出 Finder／投本机终端，远端不被错认成 Mac 本机路径。不写第二层补丁屏蔽错误输入。
- 不能因为支持目录复制就补一个大而全 `WorkspaceBackend.copy` 协议、通用跨文件系统事务引擎或 SSH 上传；若 Native FileManager 失败说明是文件系统问题，保持源与已有目标并明确报错。
- 同一任务清理被新本机 Files 目录 drop 替代的旧处理分支，更新文件操作文档、用户文案与中英文业务字符串。

### Step 3：验证、最终 E2E 与提交

- Red → Green：`make test ONLY_TESTING=BaileyTests/FileTreeTests`、`make test ONLY_TESTING=BaileyTests/TreeRowHitTestingTests`、相关 `WorkspaceWindowIsolationTests` 与 `ExternalFileDropTests`；完整 `make build`、`make test`、`git diff --check`，核对签名、XCTest 实际发现与完整退出状态。
- 测试检查**真实源／目标字节、mtime／目录项、目标树行、覆盖前后结果、原有 dirty FileTab、真正落点窗口与是否意外访问 SSH**；拷贝失败／取消后不凭模拟回调判断成功。可安全执行的权限、大小、路径字符、混合批次、文件夹边界、错误和组合尽可能逐项覆盖。
- 真正 Finder 外拖和 Files 外部导入 E2E，按不同投放落点与跨项目／窗口状态分别执行；用户当前正在使用的 Bailey 不得被强制拿来作为测试目标。无进程隔离、macOS 15.6 或文件提供方环境，逐项列实际未测和影响，功能完成 Gate 仍受到制约。
- 本 task 独立中文提交，包含本地导入、错误与冲突测试、P3-T2 远端源头修复的回归证据和对应文档；远端伪 `fileURL` 的实际删除应已在 P3-T2 提交，绝不能拖到本 task 或最后审计；不推送。

---

## Phase Audit / Feature 完成 Gate

完成 P3 的真实代码任务后才创建审计文件；按实际 commits 对照 P1 **手动添加与系统打开的意图边界**、P2 **真实 Finder 系统注册**、P3 **普通打开／终端输入／本地 Files 副本导入**。检查每条路径的单一接收者、真正磁盘结果、原生标签与 Shell 不重建、SSH 不串机器。

同一 Task 必须同步移除替代旧路径，不保留 `pendingDirectories` 与新 URL 队列双消费、重复文件打开器、透明全窗 drop 拦截层、远端伪文件 URL 或不必要兼容防护。最后核对全部受影响环境、测试条件、错误／极端组合、实际 macOS 原生 E2E、构建签名及未覆盖障碍；**仅模型单测通过不等于完整功能交付**。
