# P2：文件树内拖放与现有 Finder 导入整合

**Goal：** 在不破坏已经完成的 Finder → 本机复制导入的前提下，补齐 Files 内单项与多项移动／Option 复制，并复用 P1 的文件操作、冲突与目标保护。

**Non-goals：** 不处理跨机器上传下载、不把远端路径注册成 Mac `fileURL`、不重建整个 Dock 的拖放系统，也不修改终端／浏览器对拖放的原有语义。

**Approach：** `FileTreePanel` 的内部拖动目前只把本机项暴露为 URL；外部导入使用 `FileTreeImportDrop` 与 `FinderWindowDrop.receive`，由 `ToolPanelView` 路由 `FileTreeModel.importFromFinder`。先引入本 App 内部携带多项及机器身份的拖动数据，并明确区分内部操作和外部 Finder 复制，最终由 P1 统一业务命令执行，不另建文件 IO。

**Acceptance：** 同一当前机器的 Files 根、目录、压缩链及文件父目录准确接收落点；默认移动／Option 复制；Finder 仍默认仅复制且不会转移来源；SSH 无任何本地 URL 误路由。

**Rules：** 不改变 Projects、Dock 标签、编辑器、Ghostty 与 WebKit 的原生拖放；不允许视图在操作前后切项目导致目标跨机器，结果以实际目录内容为准。

---

<a id="p2-t1"></a>
## P2-T1 Files 内部单／多项拖放与合法落点

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`FileTreeRow.semanticRow` 的现有 `onDrag`、`FileTreeImportDrop`、`FileTreeScrollView` 的根／空白／行 Drop）、`Bailey/Files/FileTreeModel.swift`（当前选中集、`rootPath`、压缩树与统一文件操作）、`Bailey/UI/Panels/ToolPanelView.swift`（`filesTarget`、`PanelContext.Identity`）、`Bailey/Shared/Tree/TreeDisplayModel.swift`（`compactPrefix` 和真实 `row.path`）。

1. **Red：** 对当前 Files 的源路径进行真实 App 内部 drag，记录现状只能提供本地 URL、不能完成移动；新增测试确保拖单项、拖已选中多项、拖非选中行、目录与普通文件、压缩目录中间／末端行及目标空白的**真实落点**，自动判断根／文件父目录／目录本身。验证内部拖动默认移动、Option 拖动复制，源与目标最终磁盘状态符合修饰键。
2. **Green：** 使用仅供 Bailey 内部的、带发起文件树目标身份和确切路径集合的拖动数据；内部操作读取 P1 操作命令而不是自行 `FileManager.moveItem`／SSH shell。只有确认来自当前机器、连接和有效树范围时接受；跨项目或跨 SSH 连接拖动仅在可验证为同机器且合法时允许，否则有明确拒绝而不是误转到本机。悬停和放手落点按 `TreeDisplayModel.Row.path` 判定，不能把压缩路径的首级目录当作最终目录；禁止拖到自己／后代、源项重叠、目标失效。保留已有外拖 Mac URL 供 Finder 使用，但远端永不导出这种 URL。
3. **验证：** 文件／文件夹、空根／无项目、已折叠与展开、目录压缩、树横向／纵向滚动、面板标题／空白、⌘/⇧ 多选、跨文件系统卷的明确结果、重名和并发抢占、取消拖动、目标删除、脏文件保存过程中拖动、不同项目同名路径、多个 SSH 主机／重连、浅暗主题与最窄面板、交错多窗口。检查 Drag 类型、当前修饰键以及真实源／目标字节，单元／原生窗口／真实 Debug App 分层验证；补充 `FileTreeTests`、`TreeRowHitTestingTests` 和实际工作区原生组合。无实体设备的拖拽限制依 `docs/testing.md` 披露。
4. **文档与完成：** 同步 `docs/features/files.md` 和 `docs/ui.md` 的 Files 内部拖放与交互范围；移除被取代的仅适合内部流的 URL 路由，不删除 Mac 外拖兼容；相关原生 UI 与测试通过、独立中文提交。

---

<a id="p2-t2"></a>
## P2-T2 保留 Finder 复制导入并统一冲突／错误业务入口

**源码锚点：** `Bailey/Files/FileTreeModel.swift.importFromFinder`（`isCurrentTarget`、`LocalPathScope.contains`、`rebuild(refresh:)`）、`Bailey/Workspace/LocalWorkspaceBackend.swift.copyFromFinder`（`lstat`、临时替换目录、`RENAME_EXCL`）、`Bailey/Files/FileTreePanel.swift.FileTreeImportDrop`、`Bailey/UI/ContentView.swift.FinderWindowDrop.receive`、`Bailey/UI/Panels/ToolPanelView.swift` 的源目标回调。

1. **已存在行为的基线：** 不为已完成的 Finder 导入写“新功能”。先核对 `FileTreeTests` 中多项复制、目的目录判定、部分冲突、同时复制同名、符号链接、失效源、非法设备及带外路径测试，以及真实 Finder → Files、Finder → Projects、Finder → Dock／编辑区分别产生的不同结果。现有 Finder 复制默认不移动来源，绝不接受 SSH 导入，作为不可回退的基线。
2. **整合：** 在 P1 统一文件操作实现可满足已验证原子性时，复用它的目标计算、路径验证、冲突反馈与后端执行；不能因为“统一”退回为先检查 `exists` 再覆写、把目录复制半成品暴露在项目中，或吞掉 `renamex_np` 竞争失败。内部 drag 和 Finder drag 的来源类型与默认动作仍然不同，所有确认归实际发起窗口；Finder 旧入口只保留必要的 provider 解码，不再独立生成第二套后端写入路径。
3. **验证：** 至少逐条重新执行 `FileTreeTests` 的既有 Finder 用例并实测正式 GUI 格式的 Debug App：根／文件父目录／压缩链／空白、多个文件夹和符号链接混合、中文/空格/换行、批量部分成功、不可读/设备文件、目录自己及外部 symlink、自身被并发更改、目标同时由外部工具抢占、跨设备目标、同机与远端重名路径。重点核对每个来源文件无变动、目标无静默替换、失败目录不留半品、错误在当前窗口可见；同时核实拖入 Projects 仍添加文件夹／打开文件、Dock 仍打开文件而非复制。运行 `FileTreeTests`、`WorkspaceWindowIsolationTests`、`PanelContextTests`、`TreeRowHitTestingTests` 与真实 Finder E2E；不把 SwiftUI 单元 drop 委托触发冒称 Finder 实机。
4. **文档与完成：** 同步 `docs/features/files.md`、`docs/ui.md`、`docs/features/projects.md` 中实际受影响的拖放契约；若公共路径合并导致无行为差异，文档只需链接现行正确说明，避免重复。独立中文提交，旧入口冗余消除与验证同次进行。

---

## Phase Audit

仅在 P2 实施完成后生成 `audit-p2.md`，复核每个实际投放来源、落点、修饰键、最终文件系统和 SSH 身份；不得因模拟 DropDelegate 通过而跳过 Finder 原生 E2E。
