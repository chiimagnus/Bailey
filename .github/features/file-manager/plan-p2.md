# P2：文件树内拖放与 Finder 行为回归

**Goal：** 在现有 Files 树内实现单项／多选移动与 Option 复制，保留 Finder → 本机 Files 现有稳定的原子复制导入。

**Non-goals：** 不增加跨项目／跨窗口传输协议，不支持本机与 SSH、不同 SSH 机器间传输；不修改 Projects／Dock／终端／浏览器的拖放意图。

**Approach：** 前置复用 [#13 Focus](../focus-navigation/idea.md) 的 Dock 活动组和真实键盘接收者，以及 P1-T1 已实现的行选择；拖放预览不抢活动焦点。`FileTreePanel` 的现有本机 `onDrag` 仅提供 Mac 文件 URL；`FileTreeImportDrop` 接收 Finder URL 并固定执行复制。本期只扩展 **同一活动 Files 树内部**的源／目标识别，内部动作调用 P1 已验证的文件操作，不借 Mac `fileURL` 表示 SSH。只有确实需要区分同机内部拖动与 Finder 提供者时才增加最小的本 App 拖动类型，不预建跨 App 粘贴／拖动协议。

**Acceptance：** 拖放落到真实目录，默认移动、Option 复制；移动后已打开文件正确保存和改路径；Finder 导入不改变来源；其它面板拖放无回归。

**Rules：** 保留真实落点、原生 provider 及项目／机器约束；P1 已解决的源文件保护与并发不在 DropDelegate 重新实现。源未获确认前不做磁盘动作。

---

<a id="p2-t1"></a>
## P2-T1 Files 内部单／多项拖放及目标判定

**源码锚点：** `Bailey/Files/FileTreePanel.swift`（`FileTreeRow.body/onDrag`、`FileTreeImportDrop`、`FileTreeScrollView` 根／行落点）、`Bailey/Files/FileTreeModel.swift`（选中集合、`rootPath`、统一操作）、`Bailey/Shared/Tree/TreeDisplayModel.swift`（`row.path/compactPrefix`）、`Bailey/UI/Panels/ToolPanelView.swift`（`filesTarget/isCurrentTarget`）。

1. **Red：** 先证明 #13 及 P1-T1 的分屏／Files 真焦点、选择集合与源路径已经成立；用原生真实 Drag 证明现有 Files 仅提供本机 `fileURL`、不能执行树内移动，远端没有 `onDrag`；新增单项、多选、拖非选中行、根/空白、文件行父目录、目录行、目录压缩链最终路径、Option 修饰键及放弃拖动用例。核查拖放完成后源与目标**实际文件内容**。
2. **Green：** 拖动源为当时已选中成员集合（拖未选中的单项时仅该项），绑定当前 Files 根／机器／连接；拖动期间的 hover、目标边框与 #13 的正式 Focus 分开，成功落地后再恢复有效活动组／键盘焦点；仅同一活动 Files 树接受内部操作，变化、源或目标失效则拒绝。落点使用 `TreeDisplayModel.Row.path` 的真实末级目录；普通文件目标使用父目录，压缩链不可写到错误祖先。默认移动，按下 Option 时复制；委托只负责识别动作，统一调用 P1 操作，不自行写 Shell 命令。仅本机继续对 Finder 提供现有 Mac URL，远端拖动不泄露为 Mac `fileURL`；先验证是否需要新增一个内部 provider 类型，避免为技术上的可能性建立全局拖放服务。
3. **覆盖：** 0/1/N 项，父子同时选中，非空目录、压缩目录、当前选中与编辑文件，Drop 的边缘／行内留白／标题／根、纵横滚动、Option 按下与放开，悬停期间目录关闭／切根、已开始保存、目标外部抢占、循环软链、目录自身或后代、同名异机器、远端断线／再连、双窗口前后台、Dock 活动组、工具与编辑器真实 first responder、拖动悬停/取消/完成前后焦点归属、中文／明暗／字号变化。分别使用 `FileTreeTests`、`TreeRowHitTestingTests`、`WorkspaceWindowIsolationTests` 和真实原生 GUI；不把 SwiftUI Drop 提示颜色当操作成功。
4. **闭环：** `docs/features/files.md` 和 `docs/ui.md` 当次更新；内部拖放若取代旧的仅内部 URL 分支，**在本任务删掉对应旧路由**，但不得删除对 Finder 有真实用途的外拖 URL；测试、真实文件结果、中文原子提交同次完成。

---

<a id="p2-t2"></a>
## P2-T2 Finder 导入与其它投放区域完整回归

**源码锚点：** `Bailey/Files/FileTreeModel.swift.importFromFinder`、`Bailey/Workspace/LocalWorkspaceBackend.swift.copyFromFinder`（`lstat`、临时目录、`RENAME_EXCL`）、`Bailey/Files/FileTreePanel.swift.FileTreeImportDrop`、`Bailey/UI/ContentView.swift.FinderWindowDrop.receive`、`Bailey/UI/Panels/ToolPanelView.swift`。

1. **基线：** `FileTreeTests` 已有 Finder 多文件、多文件夹、普通／悬空软链、禁止外部软链目标、目标竞态、特殊文件、不完整复制等测试。复跑**所有相关用例**并对照真实 Finder 投递，明确源/目标文件字节、Files 行和错误 Sheet；在 Windows SSH 项目不能因同名路径写 Mac。保留 Finder→Projects 的目录添加／文件打开、Finder→Dock／编辑区的文件打开意图。
2. **整合与清理：** 比较 Finder 现有核心复制与 P1 内部复制是否真的产生重复；只提取双方实际共享的原子复制原语和目录校验，**不得为了外表上“一套调用”重写已验证的 `FinderWindowDrop.receive`、防覆盖或错误反馈**。需要合并时，在本任务直接清理被替代代码；没有重复则保持 Finder 独立入口，复用下层效果即可，不强求所有 UI 走一个方法。
3. **覆盖：** 根／空白／普通文件父目录／压缩文件夹、真实 Finder 多选与目标屏幕命中、Unicode／中文／换行、越根链接／死链／环、重名与并发抢占、目录自复制、不可写目录／磁盘失败、多个窗口焦点、前后台、分屏／窄面板；特别检查 `ToolPanelView` 中 `await importFromFinder` **返回后直接 `git.refresh()`**：如果期间切换项目，旧复制完成后不能刷新错误的当前 Git 范围，也不能把旧错误投向新窗口。每次核对投递源没有移动、目标没有半成品且不会新开 FileTab。额外验证外拖 Files→Finder 的本地文件 URL 仍可用，SSH Files 拒绝外拖 Mac URL。运行 `FileTreeTests`、`PanelContextTests`、`WorkspaceWindowIsolationTests` 和真实 Finder E2E，记录无法安全执行的外设条件。
4. **闭环：** 仅在行为确有变化时同步 `docs/features/files.md`、`projects.md` 和 `docs/ui.md`；重复代码在**本任务**直接清理，不把 Finder 重构作为目标本身。独立中文提交受影响源码/测试/文档。

---

## Phase Audit

实施后才生成 `audit-p2.md`；检查 Finder 与内部 drag 的实际来源、落点、修饰键和文件结果，不能拿单元回调代替正式用户路径。
