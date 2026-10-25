# P1：多选、文件操作与编辑数据保护

**Goal：** 在现有 Files 树中实现本机／SSH 多选及复制、剪切、粘贴、移动和批量删除，所有入口共享执行结果，并保护打开的编辑。同目录复制粘贴自动生成不重名副本，不另设「制作副本」或「移动到…」菜单。

**Non-goals：** 本阶段不加拖放（P2）、隐藏及 ⌘P SSH 支持（P3）、事件监听（#40）、排序选项；不重做文件树、编辑器或 Finder 已有导入。

**Approach：** 当前 `FileTreeModel.selectedPath`、`FileTreeScrollView.handleKey`、`TreeKeyboardHost`、`TreeRowSurface(focusRing:)` 和单击浏览/双击激活**已经实现**；直接增量扩展多选，不依赖已删除的 Focus 计划，不复制焦点控制。Files 继续使用 `Project.fileTree` 与 `WorkspaceBackend`；路径变化统一由真实窗口/应用所有者协调，文件操作前复用 `FileTab.save` 队列保护内容。只为本机／SSH 均缺失的复制新增必要后端方法；保留 Finder 导入的 `RENAME_EXCL`。

**Acceptance：** 真实本机和获授权 SSH 后端的源／目标字节、目录、废纸篓行为与用户意图一致；中途失败不丢编辑或误改另一台机器；菜单与焦点正确。

**Rules：** 逐任务 Red→Green→Refactor；完成该任务替代路径的当次删除旧实现、补测试与文档，不留到 P4；不能为了简化删除已实际负责防覆盖、SSH 身份和旧写入保护的机制。

---

<a id="p1-t1"></a>
## P1-T1 Files 多选、焦点与键盘导航

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`items/expanded/sync`）、`Bailey/Files/FileTreePanel.swift`（`FileTreeScrollView/FileTreeRow.semanticRow`）、`Bailey/Shared/Tree/{TreeDisplayModel,TreeRowStyle}.swift`、`Bailey/UI/Panels/ToolPanelView.swift`（`openFilePath`）。

1. **基线与 Red：** 先用 `FileTreeTests`、`DockFocusIntegrationTests` 和 `WorkspaceFilesUITests` 证明现有单行游标、Space 浏览且保留 Files 焦点、Return/双击显式打开、共享 Git 树外观与焦点归属。新行为先 Red：普通点击沿用现有浏览/展开；⌘点击只切换选中、⇧点击选择可见区间，不额外打开/折叠；右键已选中项作用集合、右键未选中行只作用该行。原生箭头、⇧+箭头、⌘A 与 Escape 的行为明确，以真实 `firstResponder` 而不是旧工作标签推断命令目标。
2. **Green：** `FileTreeModel` 继续拥有**唯一游标** `selectedPath`，在当前根／后端身份内增添多选路径集合和范围锚点；现有 `TreeKeyboardHost` 处理修饰键，Files 私有行输入区分单击与修饰键、双击（避免 `onTapGesture` + `simultaneousGesture` 重复触发）。共享 `TreeRowSurface(selected:focusRing:)` 分别画集合背景与真实键盘焦点，Git 仅回归不另改模型。压缩目录选中使用真实 `Row.path`。折叠/刷新时剔除不可见集合并重定位游标，根／通道切换清理选择；文本重命名输入框和 Command Palette 不被拦截。
3. **覆盖：** 空、单项、混合文件夹/文件、连续 Shift、Cmd 增减、选择全部、键盘折叠和压缩链、选择项被删除或外部移动、重名路径和跨根切换；必须验收真实浏览/激活后的焦点与菜单目标、终端/TextKit/WebKit/Git 输入不被 Files 快捷键劫持，兼顾中英、明暗、窄栏、多窗口和 SSH 换通道。基于受影响的宿主测试补齐逻辑，只保留不可替代的真实键鼠 E2E。
4. **闭环：** `docs/features/files.md`、必要的 `docs/features/dock.md` 和 `docs/ui.md` 在本任务同步 **Cmd/Shift 多选** 契约，不重复叙述/重新实现 #13 P3 的单行游标与预览焦点；保证 Git 树复用焦点外观，仍保留原 22pt 命中。按 `docs/testing.md` 运行相关真实 XCTest／原生验收，删除本任务确已替换的局部选择处理（若有），独立中文提交源码与对应文档。

---

<a id="p1-t2"></a>
## P1-T2 本机／SSH 原子复制与同机移动原语

**源码锚点：** `Bailey/Workspace/WorkspaceBackend.swift`（`rename/delete/list`）、`Bailey/Workspace/LocalWorkspaceBackend.swift`（`copyFromFinder`、`rename`、`trashItem`）、`Bailey/Remote/SSHWorkspaceBackend.swift`（`rename` 的竞态、`delete` 及 `RemoteCommandRunner`）、`Bailey/Remote/RemoteCommands.swift`（命令与路径转义）。

1. **Red：** 后端已支持重命名和永久／废纸篓删除，却**没有通用同机复制**。先写真实临时目录测试，证明普通文件、目录、符号链接、重复副本的复制结果，目标被抢占时不覆盖；对 SSH 使用确切受授权的独立测试机器／临时目录。实际核对 `FileManager.copyItem` 与 SSH 系统命令的跨卷、大小写碰撞和取消行为，不能假定 `mv -n` 的退出码等于成功；远端 `cp -n` 也可能静默跳过已存在目标而返回成功，必须核对真正生成的对象。
2. **Green：** 当前 `WorkspaceBackend` 没有 copy，P1 真正要求本机和 SSH 都复制，故只增加**一个与已实现功能对应的复制原语**，不造批处理/移动抽象；本机提取 `copyFromFinder` 中已有的 **同卷暂存 + `RENAME_EXCL`** 核心供内部复制使用，Finder 仍调用原功能；SSH 用现有受管远程 Shell 在**同一远端**完成复制、校验无覆盖和失败结果，不用全文 `read/write` 模拟目录拷贝。移动直接复用经确认的 `backend.rename`，不提前新增 `move` 接口或通用批处理协议。防自复制／向自身子树复制必须覆盖真实链接目标；尤其 Files 能展示指向根外的目录软链，**写入目标还须符合当前项目根的解析后边界**，不能因同一机器便允许误写根外目录，复用已有 `LocalPathScope.contains` 与经证实的远端真实路径规则。系统操作不能可靠保证无覆盖或无法跨卷时明确失败，绝不自动删除源。
3. **覆盖：** 文件 0 字节／二进制／大体积、空和递归目录、父子路径、跨卷、目录链接／断链／循环链接、硬链接、中文／Unicode 规范化、空格／引号／换行、大小写仅更名、并发同名创建、权限／空间不足、取消、源消失、远端失联与重连；**目录软链在路径校验完成到真正复制/移动之间被另一进程替换/改指向的场景**（现有 Finder 导入根检查发生在 `await copyFromFinder` 前，不能把先前路径解析当作写入瞬间的事实）；包含**0/1/100+ 项、0B/1B/大文件、深层目录/大量兄弟项、大小写敏感与不敏感卷、源/目标各种文件/目录/链接冲突**。空间不足/权限故障优先用安全的受控后端注入实际错误，不能为验收填满用户磁盘；验证夹具真实条件及源/目标最终字节。检查所有 `WorkspaceBackend` 测试遵循者，避免为新方法向无关测试后端复制虚假行为。
4. **闭环：** `FileTreeTests`、`RemoteCommandsTests`、`SSHFileTreeLiveTests`、必要 SSH 后端测试类在原有 XCTest 目标内回归；`docs/features/files.md`、`ssh.md` 当次同步。任何提取后不再使用的私有复制实现**此任务直接删除**，保留被使用的远端 `rename` 回滚及 Finder 原子防覆盖。仅后端能力可独立验收，不在这一任务提前公开未经 P1-T3 保存保护的移动 UI。

---

<a id="p1-t3"></a>
## P1-T3 文件操作闭环与已打开编辑的保存顺序

**源码锚点：** `Bailey/Files/FileTreeModel.swift`（`rename/commitDraft/moveToTrash/delete/rebuild`）、`Bailey/Workspace/Project.swift`（`updateFilePaths`）、`Bailey/Workspace/WorkspaceWindowModel.swift`（`fileRenamed`）、`Bailey/App/WorkspaceApplication.swift`（现有窗口登记）、`Bailey/Editor/FileViewerView.swift`（`FileTab.save/writeCurrentText/updatePath`）、`Bailey/Workspace/PanelContext.swift`（目标身份）。

1. **Red：** 当前 `FileTab.writeCurrentText` 会**在 await 后只校验结果代次**，不能阻止已经写出的旧路径；同时 `fileRenamed` 只同步发起窗口内的 `projects`。`FileTreeModel.moveToTrash/delete` 具有重复目录缓存/错误编排，`LocalWorkspaceBackend.delete` 按顺序移动到废纸篓而失败可能已有部分完成，远端 `SSHWorkspaceBackend.delete` 使用 `rm -rf` 对不存在的文件仍可能返回成功。**更隐蔽的是 `FileTreeModel.rename` 在 `await backend.rename` 成功后仍会因树目标变化返回 nil，导致 `FileTreeRow.commitRename` 跳过 `onRename`，实际已改名文件的原 FileTab 继续指向旧路径。**针对同机多个窗口、同路径异远端、本机文件标签位于 SSH 项目、脏编辑／在途保存、打开子目录文件与刚完成移动后再次保存做可控并发测试，核对旧路径不被重新写出、缓冲与 Undo 未损坏。测试现有复制／单项删除是否在目标切换时产生错报或遗留。
2. **Green：** 先在**真正拥有 FileTab 的项目／窗口**排空 `FileTab.save()` 队列、处理脏编辑/保存失败，再执行磁盘操作；操作期间不得启动新的旧路径写入，成功后才 `FileTab.updatePath`。现有 `WorkspaceWindowModel.fileRenamed` 只遍历单窗口，利用 `WorkspaceApplication` 已登记窗口完成同机多窗口路径传播，不创建全局文件事件管理器；保留 `workspaceIdentity` 校验和目录子项映射。**必须修复** `FileTreeModel.rename`：后端已成功但树切换时仍须报告真实完成结果给原拥有者，仅取消过期树 UI 更新。文件删除逐项返回真实成功/失败，避免本机 Trash 部分成功和 SSH `rm -rf` 误报；删除打开文件先保护缓冲，不留下可自动写回已删除路径的编辑器。未保存 Diff 的受影响范围先按现有模型能力核验，不篡改只读历史 Diff。`rename/commitDraft` 先 `stat` 的竞态预查若被后端安全防覆盖涵盖就删除；但后端必须准确识别**悬空链接已占用**。不修剪合法文件名前后空格，只拒绝空名、`.`、`..`、`/`、NUL 等真正非法输入。**SSH alias 临时重指向风险**先用受控 SSH 配置测试证明是否存在，仅在有实证时修现有目标身份校验，不预建全局身份层。
3. **覆盖：** 文件／目录移动、重命名、批量删除、制作副本、剪切（只在目标真正成功后才移除源）、父子重叠选择、部分成功、已打开子文件、未加载的 FileTab、自动保存已开始与尚未开始、编辑期间再次输入、不同 Dock 组／窗口、本机文件在 SSH 项目、旧连接迟到／断线恢复、目标被占用、文件系统操作成功后项目切换、同机旧/新标签路径唯一性、Git Diff 目标和 Trash 结果。断言**磁盘内容、标签 path、Undo、isDirty、错误提示和当前机器**，不是单测回调。
4. **闭环：** `FileTabPersistenceTests`（其中含 `NativeFileTabTests`）、`FileTreeTests`、`WorkspaceIdentityTests`、`WindowOwnershipIntegrationTests`、`PanelContextTests`；再按受影响入口执行 `WorkspaceFilesUITests` / `WorkspaceWindowsUITests`。同步 `docs/features/files.md`、`editor.md`、`projects.md`。确认所有入口已接到唯一编排后，在**本任务**删除 `FileTreeModel` 内重复的单项副作用/错误转发，不等最终 P4；保留本机 Trash 与 SSH 删除差异。

---

<a id="p1-t4"></a>
## P1-T4 菜单、剪贴板与快捷键接入实际聚焦 Files

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`rowMenu/confirmRemoteDelete`，当前使用阻塞的 `NSAlert.runModal()`）、`Bailey/UI/Panels/ToolPanelView.swift`、`Bailey/App/BaileyApp.swift`（命令入口）、`Bailey/Workspace/WorkspaceWindowModel.swift`、`Bailey/Resources/Localization`。

1. **Red：** 原生 GUI 验证已选中／未选中行右键、复制与「复制路径」不同语义、⌘C／⌘X／⌘V、制作副本、删除确认、输入框、终端和编辑器焦点。剪切只记录来源，粘贴成功才执行移动；跨机器粘贴明确拒绝。
2. **Green：** Files 有实际键盘焦点时才路由文件快捷键到 **P1-T3 同一操作**；不覆盖 macOS 标准文本输入及 Ghostty 粘贴。使用系统 `NSPasteboard` 和必要的私有文件来源标识，不增加并行的应用级剪贴板状态缓存／后台 coordinator；目标路径从当前树根／所选目录或文件父目录取得，操作前复核所属机、根、连接与选中。右键仅组织命令，保留独立「复制路径」与 Finder 打开。远端批删保留明确永久删除确认，但将现有 `confirmRemoteDelete().runModal()` 改为**发起窗口绑定的原生 Sheet**，确认回调中再次核对原目标而不是阻塞整个应用；本机按真实废纸篓行为。统一重复的菜单操作回调和报错，不造第二套弹窗框架。
3. **覆盖：** Cmd 键组合与输入法、活动／非活动 Files、改名文本框和 Command Palette、空集合、单项/多项、右键选中集合、复制后换项目与源消失、目标文件／目录／根、源目标同名、部分成功、远端离线/重连及多窗口交错、浅暗／中英/小尺寸、系统剪贴板与文字复制。验证终端和编辑器命令仍作用在正确控件，Git 树菜单不受影响；实际删除后检查 Trash/SSH 目录。
4. **闭环：** `FileTreeTests`、`DockFocusIntegrationTests`、`WindowOwnershipIntegrationTests`，共享树真实命中由 `SharedTreeUITests`、菜单/键盘由 `WorkspaceFilesUITests` 定点覆盖。同步 `docs/features/files.md`、`docs/ui.md` 和真实新增的字符串表；**当次**删除旧 `runModal` 删除入口及重复菜单处理，不搬动 Git 菜单。

---

## Phase Audit

P1 实际实现并测完后才由计划工具创建 `audit-p1.md`。预审不得假设旧代码已经无用途；每项必须追到操作后的真实磁盘／原生缓冲并完成当次旧路径清理。
