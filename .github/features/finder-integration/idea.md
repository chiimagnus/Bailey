# Bailey Finder 打开与原生拖放

关联：[Issue #10](https://github.com/chiimagnus/Bailey/issues/10)。Issue 只是起点；最终行为参考 Zed、VS Code，遵守 Bailey 现有项目和自由停靠模型。

## 目标

让 Bailey 成为 macOS 文件的可选打开应用，并能将 Finder 文件／目录投放到正确的 IDE 区域：编辑区打开文件、终端插入路径、Files 目录导入副本。这三种动作必须由实际目标决定，不能互相抢事件，更不能误操作 SSH 机器。

## 必须满足的行为

1. **系统入口**：Finder「打开方式」、文件拖到 Dock 图标、从 Finder 选定 Bailey、`open -a Bailey /path/to/file` 都能打开本地文件；批量文件、目录、冷启动及已运行时的请求均能处理。Bailey 只注册备用处理程序，不修改系统默认应用。
2. **打开与复用**：同一 URL 已在任一窗口以本机文件标签打开时，定位并激活**原有**窗口、项目及标签；避免出现两个互不共享、可能写入同一文件的编辑缓冲。否则，先复用目标窗口中**包含该文件的本机项目**，再按文件父目录新增项目；不把其他目录的文件随意塞进当前 SSH／本地工作范围。Finder 没有明确窗口目标时选真正的 Bailey 主窗口；普通拖放优先按实际落点窗口打开**尚未打开的**文件。多文件同目录可放入一个目录项目，不能每个文件重复建项目。
3. **保留手动添加语义**：`Add Files or Folders…` / 项目面板「＋」及 Finder 的 `Add Folder to Bailey` 服务仍走 `TerminalManager.addLocalItems`：每个显式添加的文件可以拥有自己的 `pinnedFile` 项目；目录只添加项目、不启动 Shell。**不得以本需求为由整体改变手动添加和 SSH 添加规则**，不清除、迁移用户已有 `pinnedFile`、手动名称或工作区快照。
4. **窗口普通区域拖放**：文件拖进空项目区、编辑器区域、普通标签栏或没有更具体语义的面板区域，是「打开文件」；拖入目录是「添加项目」。**网页内容若本身接收文件上传，由 WebKit 保留该专用行为**，普通 Bailey 标题／面板留白才执行打开，不能用根层覆盖网页文件上传。不移动、不复制 Finder 原始内容；拖入另一窗口中已打开文件，优先定位原有标签，不制造冲突写入者。
5. **本机终端拖放**：与 Zed 及 Bailey 现有 Ghostty 一致，向终端表面拖文件／目录只插入正确 shell 转义的路径文本，**不得自动发送 Return 或执行命令**。除了 Shell 引号，还必须在真实 PTY 中验证换行、回车、ESC 等文件名控制字符不会被模拟成按键；无法安全编码时明确拒绝这些路径，不向 PTY 写危险控制字节。SSH 终端不把 Mac 的绝对路径伪装为远端路径，也不隐式上传。
6. **Files 树的具体目标**：Finder 文件／目录放在 Files 的**本地目录行或树根**时，行为是复制到该目录，与 Zed／VS Code 资源管理器一致；同名冲突先让用户明确选择，失败不损坏已有目标；不会移动或删除源文件。文件树外的区域仍是「打开」。不支持的远端目录放置不得降级成错机器的本机打开，也不能假装已经导入。本项只涵盖本地 Files 外部导入，不趁机实现通用文件树内搬移或 SSH 上传。
7. **其它拖动无回归**：Bailey 自身 Dock 标签移动、项目排序、Files 外拖、普通文本在编辑器中拖放、网页拖放、Git 行为和非文件数据均继续按原语义执行。当前远端 Files 行会把 SSH 路径伪装成 Mac `fileURL`，必须在**源头**纠正，不给每个接收者写例外。
8. **编辑能力和自动保存保持现状**：文本限 UTF-8、无 NUL、8 MiB；支持原有图片预览。二进制、PDF、超限、缺失、无法访问和破损文件应给出正确的已有不可用说明或入口错误；不开发新格式预览，不覆盖脏缓冲。**Bailey 原有项目／标签切换会触发失焦自动保存**；外部打开不能新增未经授权的写入，也不能禁止或误判既有的合法自动保存。文件系统软链／Finder alias／包目录不得被不加辨别地当作普通目录打开或复制。
9. **窗口与恢复**：未挂载窗口、无窗口、重启恢复多窗口与已有终端时，系统请求只被正确窗口消费一次；不能额外重复开窗、结束 Shell 或破坏之前保存的工作区。失败反馈属于真实接收窗口，不能因另一个窗口成为 key 就送错。
10. **无额外架构**：保持单一 `Bailey.app` / `chiimagnus.bailey`、SwiftUI + AppKit + Ghostty + STTextView；复用 `TerminalManager`、`Project`、`FileTab`、`FileTreeModel`，不引入第二套会话、DnD 框架、持续轮询、Finder Extension、辅助常驻进程或无用设置开关。

## 有证据的设计依据

- [Apple CFBundleDocumentTypes](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes) 与 [LSHandlerRank](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundledocumenttypes/lshandlerrank)：文档类型由实际 bundle 声明，使用 `Alternate` 不抢默认关联。
- Apple [application(_:openFiles:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopenfiles%3A%29) 面向文档文件名批量投递，并要求以 `reply(toOpenOrPrint:)` 回告；[application(_:open:)](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/application%28_%3Aopen%3A%29) 明确说明 URL 列表不包含已注册文档类型的文件，且实现它会抑制前述 `openFile(s)` 回调。**先按文件类型选择正确单一回调，再通过真实 Finder + SwiftUI `WindowGroup` 验证**，不先把 openURLs 视为万能文件入口。
- [Zed 文档类型](https://github.com/zed-industries/zed/blob/main/crates/zed/resources/info/DocumentTypes.plist)、[统一打开入口](https://github.com/zed-industries/zed/blob/main/crates/zed/src/main.rs)、[本地终端路径拖放及测试](https://github.com/zed-industries/zed/blob/main/crates/terminal_view/src/terminal_view.rs)、[Files 外部副本导入](https://github.com/zed-industries/zed/blob/main/crates/project_panel/src/project_panel.rs)。
- [VS Code macOS 文件批量事件](https://github.com/microsoft/vscode/blob/main/src/vs/code/electron-main/app.ts)、[编辑区目标分流](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/browser/parts/editor/editorDropTarget.ts)、[Explorer 外部文件导入](https://github.com/microsoft/vscode/blob/main/src/vs/workbench/contrib/files/browser/fileImportExport.ts)。
- 本仓库实际路径：`FinderService.openInBailey → TerminalManager.openDirectories → addLocalItems`；`TerminalManager.addLocalItems → Project.openFile → FileTab`；`ContentView → WorkspaceDockView → PanelContentView → Ghostty/STTextView/WKWebView`；`ToolPanelView → FileTreePanel → FileTreeModel`。现有文件项目的 `pinnedFile` 被 `SessionStore` 持久化并影响项目图标，不能草率合并。

## 不做

- 不做远端文件上传、完整的内部文件树拖动搬移或新一套文件管理系统。
- 不做 PDF/二进制预览增强、Quick Look、Finder Extension、文件关联设置页或终端执行文件。
- 不移植 Zed GPUI 或 VS Code Electron，也不重写整个 workspace／session restore。
- 不为了未知扩展名预先将 `public.data` 宣告为万能可编辑类型；先用 `public.text`、明确的代码／图片类型和 `public.folder`，在真实 Finder 上核对需要的类型覆盖。

## 验收真源

- **完整系统入口**：Bundle 包内的文档声明、LS 候选、Finder「打开方式」、Dock 拖入、`open -a` 各自独立验证；真实文件字节或原生预览可见。
- **窗口与项目**：单／多窗口、零项目、单文件项目、目录项目、已运行 SSH 终端、混合批次、重启恢复、重复打开、输入次序；用户项目命名、`pinnedFile`、缓冲、焦点、Shell 均保持正确。
- **拖放目标**：普通区打开、本机终端只插路径、SSH 终端拒绝、Files 本机目录复制／重名确认、远端 Files 不误写；取消／跨目标／内外拖动不会双触发。
- **输入与失败**：同目录/跨目录、文件与文件夹、同名／符号链接／软链失效、Unicode／空格／引号／换行、权限／文件删除、空与超限、二进制／破损图片、读写失败／部分成功／重复并发、拷贝到自身或子目录；源文件不得因错误导入被覆盖，原有编辑内容必须保留；切换导致的**既有**失焦自动保存按当前契约单独验证，不能误报为拖放写入。
- **环境**：最低 macOS 15.6 和当前支持版本、唯一签名身份、中文／英文、浅／深色、鼠标／触控板、不同窗口和面板布局；可安全执行者必须逐项覆盖，不能实测者记录具体原因、替代证据与阻塞结论。XCTest/CI 不代替真实 Finder E2E。
- 执行细目在 `plan-p1.md` / `plan-p2.md` / `plan-p3.md`，唯一当前进度在 `todo.toml`。**当前仅审查并更新计划，不实施功能代码。**
