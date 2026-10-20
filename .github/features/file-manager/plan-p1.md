# P1：多选与统一文件操作

**Goal：** 使本机／SSH 的文件、目录与多选集合能够安全地执行复制、剪切、粘贴、制作副本、移动和批量删除，并保持编辑器与原生 UI 一致。

**Non-goals：** 不做拖放 UI（P2）、过滤／搜索／隐藏规则（P3）、监听机制改造（归 #40）、文件排序。

**Approach：** 在现有 `FileTreeModel` 中持有当前 Files 的选中集合；沿 `WorkspaceBackend` 为本机和 SSH 补齐必需的复制／移动原语，复用现有 Finder 拷贝及 SSH 重命名的防覆盖行为。业务操作的上下文保留发起时 `PanelContext.Identity`，模型负责选择／结果／目录缓存，真正的文件 IO 在后端；所有入口最后复用同一命令，不复制操作实现。

**Acceptance：** 右键、聚焦快捷键与模型 API 的行为一致；任何已完成操作都能在真实磁盘或受控 SSH 中核实，失败不损坏源／目标，已打开标签的路径与未保存正文仍正确。

**Rules：** 文件树选择和编辑器当前文件高亮是不同状态；不可改变 Git 树点击／布局；远端不能回落到本机；所有破坏性确认绑定原窗口和实际目标，未经完成的异步保存不能在旧路径留下错误内容。

---

<a id="p1-t1"></a>
## P1-T1 Files 多选、焦点与键盘导航

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`items`、`expanded`、`sync`、`toggle`）、`Bailey/Files/FileTreePanel.swift`（`FileTreeScrollView`、`FileTreeRow.semanticRow`／`isCurrent`）、`Bailey/Shared/Tree/TreeRowStyle.swift`（`TreeRowSurface`、`TreeFolderRow`、`TreeFileRow`）、`Bailey/UI/Panels/ToolPanelView.swift`（`openFilePath` 与目标校验）。

1. **Red：** 先在 `FileTreeTests` 和可运行的 `TreeRowHitTestingTests`／原生窗口用例覆盖：普通点击保留现有文件打开／目录展开；⌘ 切换离散选择，⇧ 在**可见行顺序**范围选择，方向键切换聚焦，空格／Return 的动作明确，Esc 取消选择。右键未选择行改以该行为操作对象；右键已选择行保留选中集合。验证选中并不切换编辑器标签，也不让 ⌘C 等夺走终端／编辑器的键盘焦点。旧版本不具备多选，应出现真实 Red。
2. **Green：** 选择集合及锚点由当前 `FileTreeModel` 持有，使用已存在的行身份／root／workspace 代次来切换、清理和重映射；高亮区分当前 FileTab 和 Files 选中项，选择状态在重建、目录压缩和无变化刷新时不闪烁。仅在 Files 行及其聚焦容器扩展事件路由；保留共享树行自己的 22pt 命中、Git 装饰和原生键盘语义，不建立独立树。
3. **验证：** 空树、一行、首尾与连续／间隔选择、文件与目录混合、折叠导致所选行不可见、过滤尚未存在时的常规列表、同名异路径、快速展开重建、外部删除导致消失、根／项目／机器 A→B→A、焦点进入改名输入框、菜单打开、明暗／中英／窄侧栏／辅助功能和多窗口。逐项验证选中**精确路径**、视觉、键盘操作对真实动作对象的影响；关联 `FileTreeTests`、`PanelContextTests`、`TreeRowHitTestingTests`，真实原生 GUI 检查焦点。
4. **文档与完成：** 本 task 同步 `docs/features/files.md` 的选择语义与 `docs/ui.md` 的共享行焦点／交互；不得提前声称复制粘贴可用。复核旧单击入口无倒退，`git diff --check`，独立中文提交实现与对应文档。计划文件本身遵守本地不提交策略。

---

<a id="p1-t2"></a>
## P1-T2 本机／SSH 安全复制、移动、制作副本与批处理原语

**源码锚点：** `Bailey/Workspace/WorkspaceBackend.swift`（`rename`、`delete` 和批量 `list`）、`Bailey/Workspace/LocalWorkspaceBackend.swift`（`copyFromFinder` 的分卷暂存、`RENAME_EXCL`、`delete(paths:)`）、`Bailey/Remote/SSHWorkspaceBackend.swift`（`rename`、`delete`、`shell`）、`Bailey/Remote/RemoteCommands.swift`（路径转义与批量命令）。`WorkspaceBackend` 有多个测试后端遵循者，新增要求同次核对编译接入。

1. **Red：** 在受控临时目录和 SSH 后端先证明原协议尚不能复制，新增目标断言：文件／目录原样复制、同一机器目录间移动、按原名生成不冲突的副本、批量一次性处理父子路径（避免重复作用），文件／目录与符号链接不互相误解。冲突及目标在验证后被另一进程抢占时**不覆盖**；权限失败、磁盘满、跨卷失败、源消失或取消时来源仍可定位，目标无可误认成成功的半成品。
2. **Green：** 在现有后端扩展最小必要的 `copy` 能力与批处理结果，移动优先复用 `rename` 及其经验证的同机语义；本机可重用 `copyFromFinder` 的 staging/no-replace 过程而非复制一份；SSH 使用现有受管命令和 POSIX/MSYS2 实际可用工具，禁止以 `read(maxBytes:) → write` 伪造无限制整目录复制。移动先判目标并禁止向自己／子孙移动，源只在目标结果可核验后才视为已移动；无法安全实现的跨卷场景明确报错而不自动删除源。目录、断链符号链接按实体语义处理，逐项报告成功／失败；大批操作有界，不在主 actor 执行阻塞 IO。
3. **验证：** 本机临时路径、真实授权 Windows SSH 临时根及后端测试替身；空／非空／深层目录、零字节／大文件／二进制、特殊字符／NFC-NFD／大小写碰撞、硬链接、普通／断链／目录软链、自身／后代及父子混选、不可写／不可读、磁盘满与取消、目标抢占、跨卷、多个项目相同文字路径、断网重连、批量部分成功、并发副本。先保证测试确实建立占位、卷/权限、连接等前提；核对操作前后**实际字节、目录条目和源保留**。SSH 不受授权时显式列为未测且不得冒充通过；执行 `make test ONLY_TESTING='BaileyTests/FileTreeTests BaileyTests/SSHFileTreeLiveTests'`（对应隔离参数按 `docs/testing.md`）及相关 `RemoteCommandsTests`；协议遵循者全部编译、无无谓 SSH 往返。
4. **文档与完成：** 同步 `docs/features/files.md` 的复制／移动失败契约及 `docs/features/ssh.md` 的远端限制；`SECURITY.md` 只在信任边界真的改变时更新。移除被新通用复制流程替代的冗余私有实现，绝不降低已存在的 Finder 复制安全性；独立中文提交。

---

<a id="p1-t3"></a>
## P1-T3 统一操作模型与已打开编辑的路径保护

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`rename`、`moveToTrash`、`delete`、`cachedDirectories`）、`Bailey/Workspace/Project.swift`（`updateFilePaths`、`openFile`）、`Bailey/Workspace/TerminalManager.swift`（`fileRenamed`；当前只遍历该窗口项目）、`Bailey/Editor/FileViewerView.swift`（`FileTab.updatePath`、`save`／`writeCurrentText`、`reloadFromDiskIfClean`）、`Bailey/Workspace/PanelContext.swift`（`Identity`）。路径更名已更新标签，但现有未结束的写入可能仍指向更名前的路径，不能仅靠写完后的 generation 判断消除此副作用。

1. **Red：** 模型级测试从**同一个操作入口**运行复制、剪切后粘贴、制作副本、批量移动和删除；将目录更名／移动与已打开子文件、当前未保存编辑／Undo、已经开始的自动保存、挂起的远端保存并发。特别验证更名后不会由旧写入重建旧路径，失败不更改标签路径或清空缓冲。核对同机跨项目、跨窗口及同名异 SSH 机器标签范围：确认当前 `fileRenamed` 只遍历一个 `TerminalManager` 是否构成可重现实测缺口，再选择最小可信的现有窗口分发入口，不先造进程级全局事件总线。
2. **Green：** 将 F1 的授权执行、源目标身份、集合归一化、部分结果、成功后的重映射及缓存失效归口现有 `FileTreeModel`／`Project`，由当前窗口提供后端和确认 UI。重用 `updateFilePaths`／`FileTab.updatePath` 与已有保存队列，正确处理在途 IO 与操作顺序；只有**已确认成功**的操作重定向标签，批量删除要通过已存在的关闭／未保存编辑保护，不能悄然放弃缓冲。切换根、项目、SSH 连接或关闭发起窗口后，旧确认和旧结果不能在新机器执行。
3. **验证：** 移动文件及含多个已打开子文件的文件夹、同名多项目、同机两窗口／不同机相同路径、不同 Dock 组、文件已修改或脏状态、在途自动保存（可控阻塞）、读失败或远端超时／恢复、在提交与执行之间外部重命名／抢占、移动后撤销与再次保存、文件外部删除、前台切窗口／后端切换与关闭保存取消。核对磁盘上源／目标字节、当前标签路径、原生缓冲／Undo、Git 状态及失效缓存；必要时扩展 `FileTabTests`、`WorkspaceWindowIsolationTests`、`WorkspaceIdentityTests`、`PanelContextTests`、`FileTreeTests`，运行真实原生工作区测试，不用模拟回调冒充跨窗口一致。
4. **文档与完成：** 同步 `docs/features/files.md`、`docs/features/editor.md`、`docs/features/projects.md` 中文件身份与保存不变量；仅新增本 task 需要的最小状态／取消关系，清理旧单项路径映射若已被替换；独立中文提交。

---

<a id="p1-t4"></a>
## P1-T4 右键、快捷键与批量确认共用 F1 操作

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`rowMenu`、`semanticRow`、`confirmRemoteDelete`）、`Bailey/UI/Panels/ToolPanelView.swift`（`isCurrentTarget`、`fileActionSession`）、`Bailey/App/BaileyApp.swift`（`BaileyCommands` 和 `@FocusedValue`）、`Bailey/Workspace/TerminalManager.swift`（当前窗口命令路由）、`Bailey/App/SettingsView.swift`（原生 Sheet 风格仅参考）、`Bailey/Resources/Localization/`。

1. **Red：** 原生 Files 焦点下测试右键单项／已选择多项、⌘C／⌘X／⌘V、制作副本、Delete／Backspace／确认、可选中的文件／文件夹，验证全部调用 P1-T3 **同一操作入口**；非 Files 聚焦时终端粘贴、编辑器 Cmd-C／Cmd-V、改名输入及其他 App 菜单绝不可被 Files 夺走。剪切失败后仍可粘贴重试且源仍在；SSH 删除有清晰永久删除警告；本机批删经废纸篓恢复。
2. **Green：** Files 有焦点时向当前窗口的命令／菜单传递选中集与目标，右键菜单不另外写文件 IO；剪贴板记录来源机器和规范目标，剪切标记不立即改磁盘、成功后清除对应成员；跨机器粘贴明确拒绝，不传 SSH file URL。重名、部分失败和取消通过现有原生所属窗口 Sheet 呈现每项结果；确认期间切目标须让操作失效。除用户需求引起的菜单项及视觉反馈外，保留原 Files／Git 行和 Finder 入口。
3. **验证：** 文件树焦点／非焦点、Cmd 与 Shift 状态、同时有打开的原生文本输入、上下文菜单唤出顺序／点击未选中项、复制含重名目录、粘贴到根／目录／当前文件父目录、批次 0/1/N、源项目关闭后粘贴、不同 Mac 和 SSH 主机同名路径、连接断开／重连与用户取消。覆盖中英文、系统浅暗、窄面板、原生菜单快捷键实际作用、VoiceOver 基本名称与焦点语义；先验证临时目录真实结果、再做原生 Debug App 用户路径。
4. **文档与完成：** 同 task 更新 `docs/features/files.md`、`docs/ui.md` 和受影响快捷键表（存在才更新）；新增 `Sidebar`／`Interface` 本地化字符串，并验证占位符。运行 `FileTreeTests`、`TreeRowHitTestingTests`、`FileTabTests`、`PanelContextTests`、相关窗口测试，代码更改通过 `make build`、受影响 `make test`；真实 GUI 限制依 `docs/testing.md` 逐项记录。独立中文提交。

---

## Phase Audit

P1 全部任务已执行时，才用计划工具建立 `audit-p1.md` 并按任务／提交、源码路径、磁盘最终结果和遗漏的机器／边界独立审查；规划阶段不预建审计文件。
