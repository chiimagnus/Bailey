# Bailey Finder 打开与原生拖放

关联：[Issue #10](https://github.com/chiimagnus/Bailey/issues/10)。Issue 只是起点；最终行为参考 Zed、VS Code，遵守 Bailey 现有项目和自由停靠模型。

## 目标

让 Bailey 成为 macOS 文件的可选打开应用，让 Finder 文件／目录可直接拖进 Bailey：普通工作区打开文件、终端接收本机路径、Files 的明确文件夹目标保留给独立的文件管理器功能 #5。必须通过真实命中目标决定动作，不能因为存在通用拖放接收器就误执行命令、误操作 SSH 机器或未经授权复制文件。参考 Zed／VS Code 的源码和交互语义，但只复用契合 Bailey 原生架构的方案。

## 必须满足的行为

1. **系统入口**：Finder「打开方式」、文件拖到 Dock 图标、从 Finder 选定 Bailey、`open -a Bailey /path/to/file` 都能打开本地文件；批量文件、目录、冷启动及已运行时的请求均能处理。Bailey 只注册备用处理程序，不修改系统默认应用。
2. **打开与复用**：同一 Mac 文件已在某个窗口的本机文件标签打开时，定位并激活**原有**窗口、项目及标签，不能另开可写缓冲。否则优先使用实际接收窗口中适用的**本机目录项目**（不把手动 `pinnedFile` 单文件项目误当可容纳所有同级文件的普通目录项目）；确实没有才按文件父目录创建项目。同一批的多文件按需要合并到目录项目，保持原有顺序；一个单独的新文件仍可沿既有手动单文件项目能力创建。Finder 没有明确接收窗口时复用适当主窗口，普通拖放优先实际落点窗口，绝不误入 SSH 后端。路径别名是否视为同一文件由实测和现有磁盘语义决定，不为此建立全局文件索引。
3. **保留手动添加语义**：`Add Files or Folders…` / 项目面板「＋」及 Finder 的 `Add Folder to Bailey` 服务仍走 `TerminalManager.addLocalItems`：每个显式添加的文件可以拥有自己的 `pinnedFile` 项目；目录只添加项目、不启动 Shell。**不得以本需求为由整体改变手动添加和 SSH 添加规则**，不清除、迁移用户已有 `pinnedFile`、手动名称或工作区快照。
4. **窗口普通区域拖放**：文件拖进空项目区、编辑器区域、普通标签栏或没有更具体语义的面板区域，是「打开文件」；拖入目录是「添加项目」。**网页内容若本身接收文件上传，由 WebKit 保留该专用行为**，普通 Bailey 标题／面板留白才执行打开，不能用根层覆盖网页文件上传。不移动、不复制 Finder 原始内容；拖入另一窗口中已打开文件，优先定位原有标签，不制造冲突写入者。
5. **本机终端拖放**：与 Zed 及 Bailey 现有 Ghostty 一致，向终端表面拖文件／目录只插入正确 shell 转义的路径文本，**不得自动发送 Return 或执行命令**。除了 Shell 引号，还必须在真实 PTY 中验证换行、回车、ESC 等文件名控制字符不会被模拟成按键；无法安全编码时明确拒绝这些路径，不向 PTY 写危险控制字节。SSH 终端不把 Mac 的绝对路径伪装为远端路径，也不隐式上传。
6. **Files 专用放置边界（#5）**：Zed、VS Code 均将「编辑区打开」与「Explorer 文件夹导入」明确分开。**本 Feature 不实现 Files 目标目录复制、移动、覆盖确认或上传**；这些行为完整归 [文件管理器 Issue #5](https://github.com/chiimagnus/Bailey/issues/5)。Finder 文件明确放在 Files 的目录行、压缩目录末级、文件行或树根的专用目标时，**不得静默降级成普通窗口打开，更不得假装已复制成功**；在 #5 实现前，精确专用目标应表现为未支持／不可放置。Files 面板外壳、标题或其它非专用普通区域可以按通用窗口打开。未来 #5 接入时由其真正处理复制／移动，不在本计划预置空壳服务。
7. **其它拖动无回归**：Bailey 自身 Dock 标签移动、项目排序、Files 外拖、普通文本在编辑器中拖放、网页的文件上传与链接拖动、Git 行为和非文件数据均继续按原语义执行。当前远端 Files 行会把 SSH 路径伪装成 Mac `fileURL`，接入通用打开前必须在**源头**纠正，不给每个接收者写例外。原生编辑器当前仅注册文本／RTF 拖动类型：必须先测 Finder 实际 pasteboard 内容，不能未经验证认定它必然抢夺文件 URL。
8. **编辑能力和自动保存保持现状**：文本限 UTF-8、无 NUL、8 MiB；支持原有图片预览。二进制、PDF、超限、缺失、无法访问和破损文件应给出正确的已有不可用说明或入口错误；不开发新格式预览，不覆盖脏缓冲。**Bailey 原有项目／标签切换会触发失焦自动保存**；外部打开不能新增未经授权的写入，也不能禁止或误判既有的合法自动保存。文件系统软链／Finder alias／包目录不得被不加辨别地当作普通目录打开或复制。
9. **窗口与恢复**：未挂载窗口、无窗口、重启恢复多窗口与已有终端时，系统请求只被正确窗口消费一次；不能额外重复开窗、结束 Shell 或破坏之前保存的工作区。失败反馈属于真实接收窗口，不能因另一个窗口成为 key 就送错。
10. **无额外架构**：保持单一 `Bailey.app` / `chiimagnus.bailey`、SwiftUI + AppKit + Ghostty + STTextView；复用 `TerminalManager`、`Project`、`FileTab`、`FileTreeModel`，不引入第二套会话、DnD 框架、持续轮询、Finder Extension、辅助常驻进程或无用设置开关。

## 有证据的设计依据

- [Apple CFBundleDocumentTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes) 与 [LSHandlerRank](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes/lshandlerrank)：文档类型由实际 bundle 声明，使用 `Alternate` 不抢默认关联。
- Apple [application(_:openFiles:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29) 面向文档文件名批量投递，并要求以 `reply(toOpenOrPrint:)` 回告；[application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopen%3A%29) 明确说明 URL 列表不包含已注册文档类型的文件，且实现它会抑制前述 `openFile(s)` 回调。**先按文件类型选择正确单一回调，再通过真实 Finder + SwiftUI `WindowGroup` 验证**，不先把 openURLs 视为万能文件入口。
- [Zed 文档类型](https://github.com/zed-industries/zed/blob/main/crates/zed/resources/info/DocumentTypes.plist)：通用文本和文件夹使用 `Alternate`，另有旧式扩展名列表并使用 `Default`（**不照抄旧式通配类型或 Default**）；[统一打开入口](https://github.com/zed-industries/zed/blob/main/crates/zed/src/main.rs) 接入专属 OpenListener；[终端处理](https://github.com/zed-industries/zed/blob/main/crates/terminal_view/src/terminal_view.rs) 对本机 ExternalPaths 用 Shell 引用并走 `terminal.paste`、远端拒绝；[Project Panel 复制入口](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs) 与编辑区打开分离，属于 Bailey #5。
- [VS Code macOS 文件批量事件](https://github.com/microsoft/vscode/blob/main/src/vs/code/electron-main/app.ts)：以短批次合并系统文件请求，默认 `preferNewWindow: true` 是 VS Code 自身策略，不适合无依据复制给 Bailey；[编辑区目标分流](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/editorDropTarget.ts) 与 [Explorer 外部文件导入](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/views/explorerViewer.ts) 不共享放置动作，后者属 Bailey #5。
- 本仓库实际路径：`FinderService.openInBailey → TerminalManager.openDirectories → addLocalItems`；`TerminalManager.addLocalItems → Project.openFile → FileTab`；`ContentView → WorkspaceDockView → PanelContentView → Ghostty/STTextView/WKWebView`；`ToolPanelView → FileTreePanel → FileTreeModel`。现有文件项目的 `pinnedFile` 被 `SessionStore` 持久化并影响项目图标，不能草率合并。

## 不做

- 不在 #10 做 Files 目录目标的文件复制、移动、覆盖对话框、远端上传、内部文件树搬移或任何新文件管理系统；这些归 Issue #5。
- 不做 PDF/二进制预览增强、Quick Look、Finder Extension、文件关联设置页或终端执行文件。
- 不移植 Zed GPUI 或 VS Code Electron，也不重写整个 workspace／session restore。
- 不为了未知扩展名预先将 `public.data` 宣告为万能可编辑类型；先用 `public.text`、明确的代码／图片类型和 `public.folder`，在真实 Finder 上核对需要的类型覆盖。

## 验收真源

- **完整系统入口**：Bundle 包内的文档声明、LS 候选、Finder「打开方式」、Dock 拖入、`open -a` 各自独立验证；真实文件字节或原生预览可见。
- **窗口与项目**：单／多窗口、零项目、单文件项目、目录项目、已运行 SSH 终端、混合批次、重启恢复、重复打开、输入次序；用户项目命名、`pinnedFile`、缓冲、焦点、Shell 均保持正确。
- **拖放目标**：普通区打开、本机终端仅输入引用路径、固定 SSH 项目连接前／中／后及动态 SSH 终端都拒绝 Mac 路径、Files 精确目录目标在 #5 前不承诺复制／不降级普通打开、远端 Files 不输出伪 Mac URL；取消／跨目标／内外拖动不双触发。测试 STTextView 和 WebKit 既有原生拖动语义。
- **输入与失败**：同目录／跨目录、文件／文件夹、相同／别名路径、符号链接／失效链接、未知／无扩展名、Unicode／空格／引号／控制字符、权限／删除、空与超限、二进制／损坏图片、无窗口／重启、部分合法批次／重复请求；所有普通打开与不支持的专用放置**不得修改源文件或隐式复制**，原有编辑内容必须保留；切换导致的**既有**失焦自动保存单独核对，不误报为拖放写入。
- **环境**：最低 macOS 15.6 和当前支持版本、唯一签名身份、中文／英文、浅／深色、鼠标／触控板、不同窗口和面板布局；可安全执行者必须逐项覆盖，不能实测者记录具体原因、替代证据与阻塞结论。XCTest/CI 不代替真实 Finder E2E。
- 执行细目在 `plan-p1.md` / `plan-p2.md` / `plan-p3.md`，唯一当前进度在 `todo.toml`。**当前仅审查并更新计划，不实施功能代码。**
