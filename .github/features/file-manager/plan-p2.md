# P2：Files 树内拖放与现有 Finder 导入回归

**Goal：** 在同一 Files 树里将单项／多选项移动到真实目录，按 Option 复制；保持现有 Finder → Files 的独立复制行为及其它面板拖放语义。

**Non-goals：** 不新增跨窗口、跨项目、Mac ↔ SSH 或不同 SSH 主机传输；不重写原有 Finder 拖放/Window Drop 分发，不建立全局 Drag Manager、第二套剪贴板或新的批处理层。

**Approach：** 复用当前 Dock 活动组和 P1 的选择/操作结果；在 `FileTreePanel` 用一个最小的**进程内私有拖动身份**区分 Files→Files 与 Finder 公开 `fileURL`。Finder→Files 仍为复制，本机 Files→Finder 继续提供文件 URL，SSH 只能使用私有内部路径。明确落点与操作后直接调用 P1，不新增 Drag Manager、独立文件 IO 或跨窗口传输。Option 的实际修饰键传递须先验证 SwiftUI 拖放事件能力，不凭 `DropInfo` 想象不存在的接口。

**Acceptance：** 内部默认移动、Option 复制；操作之后磁盘的源/目标字节、打开编辑器路径及焦点正确；Finder 导入始终只复制，文件源不被移走、子目录/软链/原子防覆盖原有测试仍通过，Projects/工作标签/终端/浏览器投放行为不变。

**Rules：** Drag preview/hover 不算正式 Focus；真实结果由 P1 的单一操作入口给出，DropDelegate 不能另写文件系统操作。**本阶段就完成完整 Finder 回归及被取代路径删除，不再设置第二个仅做重复回归的任务。**

---

<a id="p2-t1"></a>
## P2-T1 内部移动/复制、真实落点与 Finder 回归

**源码锚点：** `Bailey/Files/FileTreePanel.swift.FileTreeRow.body/FileTreeImportDrop/FileTreeScrollView`、`Bailey/Files/FileTreeModel.swift` 的 P1 选择及统一操作、`Bailey/Shared/Tree/TreeDisplayModel.swift` 的真实压缩路径、`Bailey/UI/Panels/ToolPanelView.swift.filesTarget/importFromFinder`、`Bailey/Workspace/LocalWorkspaceBackend.swift.copyFromFinder`、`Bailey/UI/ContentView.swift.FinderWindowDrop.receive` 以及真实 Finder → Projects/编辑/终端/浏览器拖放入口。

1. **Red：** 用真实 GUI 验证当前本机 FileTreeRow 只有公开 `fileURL`，并被 Files 自己的 `FileTreeImportDrop` 视为 Finder→Files **复制**，因此直接用旧类型实现内部移动会误操作；远端无本机 URL。先构造未选中行拖动、1/N 项、根/空白、目录、文件行父目录、压缩目录链的真实落点以及 Option 切换、取消。记录拖动后实际源/目标磁盘内容、活动 Dock 组和原生 first responder。
2. **Green：** 同一 Files 树内部拖动提供最小私有来源类型或等效本地标记，承载源集合及 P1 已知的树/机器/项目身份；**内部标识优先分派给 P1 移动/复制，公开 `fileURL` 继续仅供 Finder 等外部应用访问**。现有 Finder→Files 始终 `DropProposal.copy`，内部默认移动、Option 复制；不得让外来 Finder URL 伪造内部身份，也不能把 SSH POSIX 路径包装成 Mac 文件 URL。Drop 落点只用树实际末级目录，文件行用父目录；**内部来源落到其它项目、窗口或 SSH 主机 Files 时，纵然 provider 同时携带 Mac `fileURL` 也应拒绝，而不是自动降级为 Finder 复制**；私有类型必须关联本进程仍有效的源树选择和身份，外部构造同名类型不能获得写入授权；先归一化父子混选，拒绝自移动/自己后代/源目标已变更，P1 处理原子失败与部分成功；Hover 和 preview 不改变 #13 Focus，成功后才定位有效行/组。仅在实际验证两类后端复制重复时提取已存在且确有调用的下层部分，**不强行重写 FinderWindowDrop**。
3. **现有入口回归：** Finder→Files 的根/目录行/文件父目录准确复制且源不动，不额外开标签；Files→Finder 的本机公开 URL 和 SSH 禁用外传保持原样。验证来源同时带私有标记及 `fileURL` 时，本树执行移动/Option 复制，**其它 Files 项目/窗口拒绝**而不是降级 Finder 导入，编辑区仍按现有文件打开规则处理；Finder→Projects、Dock、Ghostty、WebKit 只做受影响路径回归。优先用 `FileTreeTests` 已有防覆盖/软链/失败夹具，不复制整套测试。`git.refresh()` 仍走已有项目目标；只有复现错目标副作用才修所属入口，不预建额外刷新调度器。
4. **异常与覆盖：** 覆盖空/单/多选、父子重叠、压缩链与文件父目录、根/空白区、修饰键中途变化、取消、异步 provider 晚到、来源/目标切换、LazyVStack 行回收；联动 P1-T2/T3 复测链接与目录循环、覆盖竞争、跨卷、保存中移动和 SSH 断线，最终核对源目标字节、原生焦点与错误 Sheet。宿主 `FileTreeTests`、`PanelContextTests`、`WindowOwnershipIntegrationTests`；真实拖放 `SharedTreeUITests`、`WorkspaceFilesUITests`、必要 `WorkspaceDockUITests` 和授权的 `SSHFileTreeLiveTests`。依照 `docs/testing.md` 只对新增的真实 GUI 边界运行 E2E，不在每次迭代重复所有 Finder 场景。
5. **闭环：** 本任务更新 `docs/features/files.md` 和实际受影响的 `docs/features/projects.md`／`docs/features/dock.md`／`docs/ui.md`；**直接删除被新内部拖放路由取代的旧路径或重复业务判断**，但保留真正有用的 Mac 外拖 URL、Finder 复制与原子防覆盖。Red→Green→Refactor、中文原子提交与可执行 GUI 验收同任务完成。

---

## Phase Audit

只有内部实际移动/复制及上述 Finder 全套回归完成后创建 `audit-p2.md`，不另设仅为重复测试的 P2-T2；不以事件/提示色代替真实磁盘与原生 App 验收。
