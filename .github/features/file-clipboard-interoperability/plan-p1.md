# P1｜本机文件剪贴板与跨应用互操作

Bailey Files 的复制／剪切使用 macOS 标准文件剪贴板；访达和本机其他项目可双向复制，
移动只能由仍有效的本进程剪切意图或用户明确执行的「移动到此处」发起。
SSH 只保留原有同项目、同连接的内部文件操作。
需求真源：[idea.md](idea.md)。

## 方案

**已确认的根因**：`FileTreeClipboard.write` 仅发布私有 JSON 和换行路径；
`WorkspaceWindowModel.canPasteFileTree` 将来源与目的项目身份绑定；
`FileTreeModel.performFileOperation` 要求每个来源属于目标根；
Finder 导入虽走 `LocalWorkspaceBackend.copyExclusive`，却与内部复制分开判断冲突。
`WorkspaceApplication.withProtectedFiles` 已能协调跨窗口脏稿，不应复制此机制。
入口分别是 `TreeKeyboardView` 原生 Edit、Files 右键菜单和 `FileTreeNativeDragView`。

- **公开身份**：本机每个选中实体发布单独的 `public.file-url`，附带可选路径文本；
  SSH 只发布原有私有记录与文本，复制路径菜单仍只发布文本。
  读取使用 `NSURL` 与 `urlReadingFileURLsOnly`，不从文本构造来源。
- **授权身份**：私有记录是非可信输入；`WorkspaceApplication` 只保存当前进程、
  当前剪贴板版本的内部剪切来源意图与真实文件身份，不使用剪贴板 UUID 作为删除许可。
  被外部改写或重启后只能从有效本机文件 URL 复制；SSH 保留同连接核验。
  批量部分成功只保留未处理来源，不覆盖已经被其它应用改写的剪贴板。
- **磁盘真源**：复用 `LocalWorkspaceBackend` 的目标卷暂存、`RENAME_EXCL` 防覆盖，
  将 Finder 拖放、剪贴板复制与内部复制接到同一套目标冲突判据；
  本机移动同卷用排他重命名，跨卷先复制并验证完整数据与来源身份再删除。
  跨卷删除失败单独报告，不宣称移动成功。
  本机来源可在另一个授权项目，或来自用户明确复制的 Finder URL；
  目标仍必须在当前本机项目的物理目录内。
- **操作归属**：`WorkspaceWindowModel` 固定发起窗口／目标，并调用现有
  `WorkspaceApplication.withProtectedFiles` 保护真实源路径；
  `FileTreeModel` 负责树刷新和内部状态更新；
  `WorkspaceApplication.fileRenamed` 负责跨窗口编辑标签路径。
  右键沿本次目录段，键盘沿当前有效选择；不增加剪贴板服务、全局快捷键处理器或 SSH 传输。
- **取消与权限**：粘贴时才读取剪贴板内容并验证真实本地 URL、文件类型、
  来源身份、项目／连接与文件权限；菜单只查看类型，不扫描剪贴板数据。
  拒绝越界目录链接、虚拟条目、特殊文件和缺失来源。

## 任务

<a id="p1-t1"></a>
### P1-T1 发布原生文件项并绑定进程内剪切意图

- **位置**：`Bailey/Files/FileTreePanel.swift` 的 `FileTreeClipboard`；
  `Bailey/App/WorkspaceApplication.swift` 的传输意图；
  `Bailey/Workspace/WorkspaceWindowModel.swift` 的复制入口；
  `BaileyTests/Workspace/WindowOwnershipIntegrationTests.swift`。
- **实施**：本机多项文件 URL 与文本／私有记录共存；SSH 无 URL。
  发起剪切时持有可核验的进程内身份、来源范围和剪贴板版本；
  删除旧的“UUID 即授权”和“同项目即授权”假设，保留内部拖放独立 nonce。
  同步文件操作文档。
- **验证**：命名剪贴板检查每项 `NSURL`、真实文件／符号链接、Unicode 和多选；
  另一进程伪造、篡改、改写／过期记录无法授权移动；复制不读取文件正文；
  纯路径无文件 URL，SSH 不泄露本机路径。

<a id="p1-t2"></a>
### P1-T2 统一安全复制与显式移动的磁盘结果

- **位置**：`Bailey/Workspace/LocalWorkspaceBackend.swift`、
  `Bailey/Files/FileTreeModel.swift`；`BaileyTests/Files/FileTreeTests.swift`。
- **实施**：统一 Finder 拖放与本机复制的源类型、唯一副本命名、目录边界、
  并发防覆盖及分项结果；跨项目来源使用独立的授权来源核验，不能绕过目标范围。
  同卷原子移动不覆盖目标；跨卷先拷贝、验证、再根据源身份决定删除，
  返回“已移动／仅复制／失败”的真实区别；逐项处理父子重叠和冲突。
  不修改远端复制、重连或删除语义，删除被替代的本机重复代码。
- **验证**：临时文件中的常规、目录、链接、特殊文件、空目录、文件名极值、
  同源副本编号、同名冲突、递归、外部来源、并发、权限、目标链接改指向、
  大文件与多项部分成功；复制后源不动，移动后身份／字节正确。
  跨卷测试须使用明确的隔离测试卷，不能以同卷结果冒充跨卷。

<a id="p1-t3"></a>
### P1-T3 接通跨项目粘贴、菜单与跨窗口保存保护

- **位置**：`Bailey/Workspace/WorkspaceWindowModel.swift`、
  `Bailey/UI/Panels/ToolPanelView.swift`、
  `Bailey/Files/FileTreePanel.swift`、
  `Bailey/Shared/Tree/TreeRowStyle.swift`、
  `BaileyTests/Workspace/WindowOwnershipIntegrationTests.swift`、
  `BaileyUITests/Files/*` 和 `docs/features/files.md`、`docs/ui.md`。
- **实施**：`⌘V` 对可信剪切才移动，否则仅复制文件 URL；`⌥⌘V`
  从公开 URL 明确移动，支持系统菜单及目录右键；
  失效私有记录无公开 URL 时拒绝。跨项目、跨窗口操作协调全部受影响文件编辑，
  不改项目选择；源与目标各自刷新、移动后更新标签；SSH 严格隔离。
  剪贴板被外部修改后不覆盖，成功项不再作为待移动项；
  路径复制、编辑器／终端／Git 焦点不改变。
- **验证**：Host Tests 核对真实字节与脏稿、跨窗口两份冲突、剪贴板伪造、
  重试／部分成功、断线／切换／重新打开；隔离 Bailey Dev 与 Finder 双向
  真实键盘／菜单互操作，核对焦点和目标，安全保全并恢复可完整快照的剪贴板。

## 阶段验收

1. **文件表示**：单项、多项、目录、链接／失效链接、空目录；
   UTF-8、中文、空格、换行、只有文本、网页 URL、远程 file URL、损坏私有记录和混合数据。
2. **来源与作用域**：本项目、同机另一项目与窗口、Finder 项目外来源、
   另一个进程、剪贴板改写、App 重启、项目移除、切换工作范围；
   SSH 同根重连／换机均不得按旧意图写盘。
3. **目标与权限**：根、目录段、文件父目录、空选择、右键目标、
   指向内／外的目录链接、源目录的自身／后代、父子重叠、只大小写不同的冲突；
   并发相同目标不可覆盖。
4. **移动与一致性**：未保存稿、不同窗口脏稿、保存中的编辑、外部修改／替换、
   同卷及隔离跨卷、复制成功但删除失败、源缺失、只读和特殊文件、取消及批量部分成功。
5. **现有交互**：内部拖放默认移动／Option 复制、外部拖放复制；
   SSH 不隐式传输，本机文件标签／Git 路径复制只为文本；
   菜单刷新不反复读取剪贴板正文。

逐任务执行 `make test:FileTreeTests,WindowOwnershipIntegrationTests` 等受影响宿主用例，
再运行 `make build`、`make test` 与有独立桌面许可的定点 Bailey Dev UI 验收。
每项测试核对实际文件内容、元数据及来源存在性，而不只验证通知／返回值。
无法安全执行的跨卷、权限或 GUI 条件逐项记载原因、替代证据、潜在影响和补验方法，
关键验收缺失时阶段审计必须给出 `No-Go`，不冒充全通过。
