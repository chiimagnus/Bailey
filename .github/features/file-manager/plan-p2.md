# P2：Files 树内拖放与现有 Finder 导入回归

**Goal：** 在同一 Files 树里将单项／多选项移动到真实目录，按 Option 复制；保持现有 Finder → Files 的独立复制行为及其它面板拖放语义。

**Non-goals：** 不新增跨窗口、跨项目、Mac ↔ SSH 或不同 SSH 主机传输；不重写原有 Finder 拖放/Window Drop 分发，不建立全局 Drag Manager、第二套剪贴板或新的批处理层。

**Approach：** 直接消费 #13 的 Dock 活动组、P1 的 Files 选择与已实现文件操作；将**来自本 App 当前 Files 树的内部拖动**与 Finder 的公开 `UTType.fileURL` 作最小区分。现有 Finder 导入使用 `FileTreeImportDrop`，在根、目录行、文件行父目录执行**复制**；本机 Files 外拖到 Finder 的公开 URL 保留，SSH 仅允许受限的私有内部数据。除非执行 P1 已有的后端复制，无新建原子复制路径的理由。

**Acceptance：** 内部默认移动、Option 复制；操作之后磁盘的源/目标字节、打开编辑器路径及焦点正确；Finder 导入始终只复制，文件源不被移走、子目录/软链/原子防覆盖原有测试仍通过，Projects/工作标签/终端/浏览器投放行为不变。

**Rules：** Drag preview/hover 不算正式 Focus；真实结果由 P1 的单一操作入口给出，DropDelegate 不能另写文件系统操作。**本阶段就完成完整 Finder 回归及被取代路径删除，不再设置第二个仅做重复回归的任务。**

---

<a id="p2-t1"></a>
## P2-T1 内部移动/复制、真实落点与 Finder 回归

**源码锚点：** `Bailey/Files/FileTreePanel.swift.FileTreeRow.body/FileTreeImportDrop/FileTreeScrollView`、`Bailey/Files/FileTreeModel.swift` 的 P1 选择及统一操作、`Bailey/Shared/Tree/TreeDisplayModel.swift` 的真实压缩路径、`Bailey/UI/Panels/ToolPanelView.swift.filesTarget/importFromFinder`、`Bailey/Workspace/LocalWorkspaceBackend.swift.copyFromFinder`、`Bailey/UI/ContentView.swift.FinderWindowDrop.receive` 以及真实 Finder → Projects/编辑/终端/浏览器拖放入口。

1. **Red：** 用真实 GUI 验证当前本机 FileTreeRow 只有公开 `fileURL`，并被 Files 自己的 `FileTreeImportDrop` 视为 Finder→Files **复制**，因此直接用旧类型实现内部移动会误操作；远端无本机 URL。先构造未选中行拖动、1/N 项、根/空白、目录、文件行父目录、压缩目录链的真实落点以及 Option 切换、取消。记录拖动后实际源/目标磁盘内容、活动 Dock 组和原生 first responder。
2. **Green：** 同一 Files 树内部拖动提供最小私有来源类型或等效本地标记，承载源集合及 P1 已知的树/机器/项目身份；**内部标识优先分派给 P1 移动/复制，公开 `fileURL` 继续仅供 Finder 等外部应用访问**。现有 Finder→Files 始终 `DropProposal.copy`，内部默认移动、Option 复制；不得让外来 Finder URL 伪造内部身份，也不能把 SSH POSIX 路径包装成 Mac 文件 URL。Drop 落点只用树实际末级目录，文件行用父目录；**内部来源落到其它项目、窗口或 SSH 主机 Files 时，纵然 provider 同时携带 Mac `fileURL` 也应拒绝，而不是自动降级为 Finder 复制**；私有类型必须关联本进程仍有效的源树选择和身份，外部构造同名类型不能获得写入授权；先归一化父子混选，拒绝自移动/自己后代/源目标已变更，P1 处理原子失败与部分成功；Hover 和 preview 不改变 #13 Focus，成功后才定位有效行/组。仅在实际验证两类后端复制重复时提取已存在且确有调用的下层部分，**不强行重写 FinderWindowDrop**。
3. **Finder 与其它区域回归（同任务）：** 从 `FileTreeTests` 现有真实 Finder 批量/同名/目录/普通与断链软链/越根目标/特殊文件/并发唯一发布/不完整目录失败基线出发，检查 FileTreeImportDrop 根、行、标题、空白区和高 DPI/窄栏命中；真实 Finder 投放后源仍在原路径，目标字节正确、不额外开 FileTab。**尤其验证同时携带私有类型和公开 `fileURL` 的本机 Files 拖动，在本树、其它 Files 树、Finder、编辑区四种真实落点分别触发正确动作；内外 DropDelegate 优先级不能改变后端写入语义**。Finder→Projects 文件打开/目录添加、普通编辑和 Dock 标签栏文件打开、本机 Ghostty 插入路径而非执行、WebKit 正文上传维持原有意图；Files→Finder 本机公开 URL 外拖仍有效，SSH 不对外发布本机 URL。核查 `ToolPanelView` 导入完成后 `git.refresh()` 是否确实在切项目后操作错 Git 范围：**先记录请求所读的真实 git 目标，若没有副作用就不额外增加修复/guard**；若已确认错误，在此 task 按发起目标修正，不补全局 watcher。
4. **异常与覆盖：** 空/单/N、父子混选、深层压缩链、目录软链/死链/循环、Unicode/中文/换行/空格、大小写、重名、其它进程创建目标抢占、权限/只读/磁盘不足/跨卷、未保存 FileTab 和在途写入、本机/SSH 断线/重连、两个主窗口、Dock 重排、前后台及焦点切换、长名称/水平滚动/Option/取消；来源/目标身份切换或异步 provider 晚到不能写另一台机器；核对 Option 在拖动中按下/放开时的最终动作与预览一致、拖动期间源/目标被外部改名/删除、先后两次拖动更换选中集合以及源行被 LazyVStack 滚出屏幕。运行 `FileTreeTests`、`TreeRowHitTestingTests`、`WorkspaceWindowIsolationTests`、`PanelContextTests`、必要 `SSHFileTreeLiveTests` 和签名 App 的真实 Finder 内外拖放；实际验证源目标数据及错误 Sheet，静态 `DropProposal` 断言不等于 E2E。
5. **闭环：** 本任务更新 `docs/features/files.md` 和实际受影响的 `docs/features/projects.md`／`docs/features/dock.md`／`docs/ui.md`；**直接删除被新内部拖放路由取代的旧路径或重复业务判断**，但保留真正有用的 Mac 外拖 URL、Finder 复制与原子防覆盖。Red→Green→Refactor、中文原子提交与可执行 GUI 验收同任务完成。

---

## Phase Audit

只有内部实际移动/复制及上述 Finder 全套回归完成后创建 `audit-p2.md`，不另设仅为重复测试的 P2-T2；不以事件/提示色代替真实磁盘与原生 App 验收。
