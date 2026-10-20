# P1：多选、文件操作与编辑数据保护

**Goal：** 在现有 Files 树中实现本机／SSH 多选及复制、剪切、粘贴、制作副本、移动和批量删除，所有入口共享执行结果，并保护打开的编辑。

**Non-goals：** 本阶段不加拖放（P2）、隐藏及 ⌘P SSH 支持（P3）、事件监听（#40）、排序选项；不重做文件树、编辑器或 Finder 已有导入。

**Approach：** **先以 [#13 Focus 计划](../focus-navigation/plan-p1.md)的真实窗口／Dock 活动组及 first responder 契约作为 P1-T1 前置门槛**，不在 Files 实现第二套全局焦点。`FileTreeModel` 管理 Files 行选择和锚点、展开与刷新；文件操作在其现有目标后端执行，`Project`／`TerminalManager` 负责已打开内容的保存及路径更新；`FileTreePanel` 只转发交互。复用 `WorkspaceBackend.rename/delete` 和已经安全的 `LocalWorkspaceBackend.copyFromFinder` 底层复制能力，**仅在现有协议不能表达真实复制时**添加最小接口，不为批处理、移动和剪贴板分别造框架。分清 Files 的选择与 FileTab 当前文件高亮。

**Acceptance：** 真实本机和获授权 SSH 后端的源／目标字节、目录、废纸篓行为与用户意图一致；中途失败不丢编辑或误改另一台机器；菜单与焦点正确。

**Rules：** 逐任务 Red→Green→Refactor；完成该任务替代路径的当次删除旧实现、补测试与文档，不留到 P4；不能为了简化删除已实际负责防覆盖、SSH 身份和旧写入保护的机制。

---

<a id="p1-t1"></a>
## P1-T1 Files 多选、焦点与键盘导航

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`items/expanded/sync`）、`Bailey/Files/FileTreePanel.swift`（`FileTreeScrollView/FileTreeRow.semanticRow`）、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`（`openFilePath`）。

1. **前置焦点检查 + Red：** 核对 #13 的活动 Dock 组和原生 first responder 已完成相应验收；没有完成则先在 #13 修复，不给文件树加一个局部假焦点。以 `DockWorkspaceTests`、`WorkspaceWindowIsolationTests` 的真实结果证明窗口及工具面板 Focus；再在 `FileTreeTests`、`TreeRowHitTestingTests` 和原生宿主验证：普通点击选中并保持现有**文件打开／目录展开**；⌘ 点击只增减离散选择、⇧ 点击只按当前可见行顺序扩展选择，二者**不打开或折叠**行；右键已选中项对整个集合，右键未选中行仅对该项且不打开。键盘 ↑↓ 移动焦点、⇧+↑↓ 扩展范围、→/← 展开／收起目录、Return 打开聚焦文件、Esc 清除选择；Files 真正聚焦时 ⌘A 选中当前可见项。明确选中集合和「当前编辑文件」是两种状态，原始双击、按钮及无障碍行为不能倒退。
2. **Green：** 当前 `FileTreeModel` 持有路径集合和选择锚点；行键盘焦点归 Files 真正的 first responder／焦点视图，Dock 活动组归 #13，同一行的选中状态、键盘焦点环及「当前编辑文件」强调分别呈现。复用共享 `TreeRowSurface` 已有 selected/focused 样式入口，仅给 Files 行增加多选语义，不改 Git 共享行的默认选择。当前编辑文件强调与多选视觉各自表达，选中项被移除时清理；换根、机器、连接时沿 `sync` 现有重置行为更新，不能用字符串相同跨通道继承。
3. **覆盖：** 空、单项、混合目录／文件、Cmd+A、范围反选、连续 Shift、键盘展开/收起、压缩链、折叠/展开、重建、重名异路径、失去焦点、改名输入焦点、菜单开启；**前台/后台、不同 Dock 组工具面板之间与终端、TextKit 编辑器、WebKit 浏览器、Diff 来回切焦点后，⌘A/C/X/V、Return、方向键真正送到谁；不能由 `Project.selectedTabID` 的旧值误判**；A→B→A、SSH 失联／换通道、多窗口、浅暗／中英／窄面板／缩放及键盘与辅助功能。验证命中后的真实选择集合、焦点与屏幕状态，而非只检查事件回调。
4. **闭环：** `docs/features/files.md`、必要的 `docs/features/dock.md` 和 `docs/ui.md` 在本任务同步 Files 新增行选中契约；#13 的通用 Dock Focus 文档由 #13 自己维护，不复制内容；保留 Git 树现有行和 22pt 命中。按 `docs/testing.md` 运行相关真实 XCTest／原生验收，删除本任务确已替换的局部选择处理（若有），独立中文提交源码与对应文档。

---

<a id="p1-t2"></a>
## P1-T2 本机／SSH 原子复制与同机移动原语

**源码锚点：** `Bailey/Workspace/WorkspaceBackend.swift`（`rename/delete/list`）、`Bailey/Workspace/LocalWorkspaceBackend.swift`（`copyFromFinder`、`rename`、`trashItem`）、`Bailey/Remote/SSHWorkspaceBackend.swift`（`rename` 的竞态、`delete` 及 `RemoteCommandRunner`）、`Bailey/Remote/RemoteCommands.swift`（命令与路径转义）。

1. **Red：** 后端已支持重命名和永久／废纸篓删除，却**没有通用同机复制**。先写真实临时目录测试，证明普通文件、目录、符号链接、重复副本的复制结果，目标被抢占时不覆盖；对 SSH 使用确切受授权的独立测试机器／临时目录。实际核对 `FileManager.copyItem` 与 SSH 系统命令的跨卷、大小写碰撞和取消行为，不能假定 `mv -n` 的退出码等于成功。
2. **Green：** 只为复制新增一个必要后端原语（若执行环境证明确需）；本机提取 `copyFromFinder` 中已有的 **同卷暂存 + `RENAME_EXCL`** 核心供内部复制使用，Finder 仍调用原功能；SSH 用现有受管远程 Shell 在**同一远端**完成复制、校验无覆盖和失败结果，不用全文 `read/write` 模拟目录拷贝。移动直接复用经确认的 `backend.rename`，不提前新增 `move` 接口或通用批处理协议。防自复制／向自身子树复制必须覆盖真实链接目标；尤其 Files 能展示指向根外的目录软链，**写入目标还须符合当前项目根的解析后边界**，不能因同一机器便允许误写根外目录，复用已有 `LocalPathScope.contains` 与经证实的远端真实路径规则。系统操作不能可靠保证无覆盖或无法跨卷时明确失败，绝不自动删除源。
3. **覆盖：** 文件 0 字节／二进制／大体积、空和递归目录、父子路径、跨卷、目录链接／断链／循环链接、硬链接、中文／Unicode 规范化、空格／引号／换行、大小写仅更名、并发同名创建、权限／空间不足、取消、源消失、远端失联与重连；验证测试夹具实际触发目标条件及源目标最终字节。检查所有 `WorkspaceBackend` 测试遵循者，避免为新方法向无关测试后端复制虚假行为。
4. **闭环：** `FileTreeTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`、必要 SSH 后端测试类在原有 XCTest 目标内回归；`docs/features/files.md`、`ssh.md` 当次同步。任何提取后不再使用的私有复制实现**此任务直接删除**，保留被使用的远端 `rename` 回滚及 Finder 原子防覆盖。仅后端能力可独立验收，不在这一任务提前公开未经 P1-T3 保存保护的移动 UI。

---

<a id="p1-t3"></a>
## P1-T3 文件操作闭环与已打开编辑的保存顺序

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`rename/moveToTrash/delete/invalidateDirectory/rebuild`）、`Bailey/Workspace/Project.swift`（`updateFilePaths`、`openLocalFile`）、`Bailey/Workspace/TerminalManager.swift`（`fileRenamed` 和已有窗口 `registry`）、`Bailey/Editor/FileViewerView.swift`（`FileTab.save/writeCurrentText/updatePath`）及 `PanelContext.Identity`。

1. **Red：** 当前 `FileTab.writeCurrentText` 会**在 await 后只校验结果代次**，不能阻止已经写出的旧路径；同时 `fileRenamed` 只同步发起窗口内的 `projects`。`FileTreeModel.moveToTrash/delete` 具有重复目录缓存/错误编排，`LocalWorkspaceBackend.delete` 按顺序移动到废纸篓而失败可能已有部分完成，远端 `SSHWorkspaceBackend.delete` 使用 `rm -rf` 对不存在的文件仍可能返回成功。针对同机多个窗口、同路径异远端、本机文件标签位于 SSH 项目、脏编辑／在途保存、打开子目录文件与刚完成移动后再次保存做可控并发测试，核对旧路径不被重新写出、缓冲与 Undo 未损坏。测试现有复制／单项删除是否在目标切换时产生错报或遗留。
2. **Green：** 所有移动／重命名／删除**先处理受影响的正在编辑文件**，复用已有保存等待和取消／失败提示；具体采用已有 `FileTab.save` 队列实现操作顺序：待写完成、重新检查脏状态、确认操作对象，再执行磁盘动作，然后更新路径，不能靠再加一个 `generation` 挡住事后写入。必要时在当前拥有者提供最小串行入口，禁止移动期间启动新的旧路径保存。删除打开文件若用户不愿丢弃缓冲则取消，不能直接调用关闭并无条件删除。单次文件操作只依据真实成功项更新路径、展开和缓存，批量按独立结果逐项处理：本机中途失败不能误报全部未删除，远端 `rm -rf` 的成功退出不能证明每项原本存在，必要时按源逐项进行有确切前提的删除；**已成功完成磁盘更名但在 await 后切项目的情况，也必须向原文件/窗口拥有者同步实际路径效果，不能因当前面板过期而丢弃成功结果；只禁止把旧界面数据写入新树。** 失败保持旧标签；本机 Mac 文件必须按 `file.workspaceIdentity=nil` 区分。跨窗口共用现有 `TerminalManager.registry` 的拥有者能力**先证明必要且可安全调用**，不得建全局文件事件服务。现有 `Project.updateFilePaths` 对目录孩子和固定项目路径的映射可复用；额外确认实际受影响的打开 Diff 与其他路径消费者，不擅自修改历史只读内容。**审查可达的冗余往返：** `FileTreeModel.rename/commitDraft` 现先 `backend.stat` 后 `rename/create`，既增加 SSH 往返又不能替代后端原子拒绝重名；在测试证实后端错误信息可正确映射到原生提示时，**此任务删掉重复的存在性预查**，仅保留合法名称、目标身份及已证实有必要的大小写仅更名处理。避免为了减一次读取而让本机/SSH 覆盖已有文件。
3. **覆盖：** 文件／目录移动、重命名、批量删除、制作副本、剪切（只在目标真正成功后才移除源）、父子重叠选择、部分成功、已打开子文件、未加载的 FileTab、自动保存已开始与尚未开始、编辑期间再次输入、不同 Dock 组／窗口、本机文件在 SSH 项目、旧连接迟到／断线恢复、目标被占用、文件系统操作成功后项目切换、同机旧/新标签路径唯一性、Git Diff 目标和 Trash 结果。断言**磁盘内容、标签 path、Undo、isDirty、错误提示和当前机器**，不是单测回调。
4. **闭环：** `FileTabTests`、`FileTreeTests`、`WorkspaceIdentityTests`、`WorkspaceWindowIsolationTests`、`PanelContextTests` 及原生保存 E2E；`docs/features/files.md`、`editor.md`、`projects.md` 当次同步。若已被统一执行路径替代，**本任务直接删除 `FileTreeModel` 的重复单项操作编排**；保留真实远端／本机不同删除语义。独立中文提交。

---

<a id="p1-t4"></a>
## P1-T4 菜单、剪贴板与快捷键接入实际聚焦 Files

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`rowMenu/confirmRemoteDelete` 目前调用**全局阻塞的 `NSAlert.runModal()`**）、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/App/BaileyApp.swift`（`BaileyCommands`、`FocusedValues`）、`Bailey/Workspace/TerminalManager.swift`、`Bailey/Resources/Localization`。

1. **Red：** 原生 GUI 验证已选中／未选中行右键、复制与「复制路径」不同语义、⌘C／⌘X／⌘V、制作副本、删除确认、输入框、终端和编辑器焦点。剪切只记录来源，粘贴成功才执行移动；跨机器粘贴明确拒绝。
2. **Green：** Files 有实际键盘焦点时才路由文件快捷键到 **P1-T3 同一操作**；不覆盖 macOS 标准文本输入及 Ghostty 粘贴。使用系统 `NSPasteboard` 和必要的私有文件来源标识，不增加并行的应用级剪贴板状态缓存／后台 coordinator；目标路径从当前树根／所选目录或文件父目录取得，操作前复核所属机、根、连接与选中。右键仅组织命令，保留独立「复制路径」与 Finder 打开。远端批删保留明确永久删除确认，但将现有 `confirmRemoteDelete().runModal()` 改为**发起窗口绑定的原生 Sheet**，确认回调中再次核对原目标而不是阻塞整个应用；本机按真实废纸篓行为。统一重复的菜单操作回调和报错，不造第二套弹窗框架。
3. **覆盖：** Cmd 键组合与输入法、活动／非活动 Files、改名文本框和 Command Palette、空集合、单项/多项、右键选中集合、复制后换项目与源消失、目标文件／目录／根、源目标同名、部分成功、远端离线/重连及多窗口交错、浅暗／中英/小尺寸、系统剪贴板与文字复制。验证终端和编辑器命令仍作用在正确控件，Git 树菜单不受影响；实际删除后检查 Trash/SSH 目录。
4. **闭环：** `FileTreeTests`、`TreeRowHitTestingTests`、`WorkspaceWindowIsolationTests` 和完整 GUI 菜单 E2E；`docs/features/files.md` 与 `docs/ui.md` 更新操作和焦点语义，`Sidebar/Interface` 字符串表实际增加并验证。此任务清理被统一路由取代的旧菜单事件路径，不搬动其它区域菜单，原子提交。

---

## Phase Audit

P1 实际实现并测完后才由计划工具创建 `audit-p1.md`。预审不得假设旧代码已经无用途；每项必须追到操作后的真实磁盘／原生缓冲并完成当次旧路径清理。
