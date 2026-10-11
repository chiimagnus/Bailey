# Audit P2 - dockable-workspace

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/dockable-workspace/`
- 粒度：`phase`

## 任务看板

- [ ] P2-T1 统一原生窗口布局和标签交互
- [ ] P2-T2 设计对照回归与文档

## 任务到文件的映射

- P2-T1（代码提交 `59b1580`）
  - `kero/UI/WorkspaceDockView.swift`：统一布局、拖拽与预览
  - `kero/Workspace/DockWorkspaceModel.swift`、`kero/Workspace/Project.swift`：跨组操作与选中顺序
  - `kero/UI/ContentView.swift`、`kero/UI/Panes/{PaneLayoutView,Panes}.swift`：原生窗口切换、焦点、清理旧路由
  - `kero/UI/Sidebar/{SidebarView,RightSidebarView}.swift`：原始项目、文件、Git 与信息复用
  - `kero/Terminal/TerminalManager.swift`、`kero/Resources/Localization/Interface.xcstrings`：面板快捷键与中英双语
  - `scripts/check-dock-workspace.swift`：可运行的状态与命中检查
- P2-T2（文档提交 `93af1c1`）
  - `docs/{README,PRODUCT,TERMINAL,PROJECTS,GIT,SETTINGS}.md`：用户行为与布局恢复

## 发现项

## 发现 F-05

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`kero/Git/DiffViewerView.swift`
- 摘要：`Diff 长期 WebHost 在新停靠结构下的切换性能未实测`
- 风险：`项目或标签切换可能重复挂载重型 diff 主视图造成掉帧`
- 预期修复：`在真实 Debug 中复现多仓库 diff 的切换；如实际回归则在停靠区复用已缓存的 DiffWebHost`
- 验证：`仅现有 DiffTab.webHostView 长寿命持有已核对；切换耗时仍待实测`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-04

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Open`
- 位置：`/Applications/Kero.app`
- 摘要：`签名 Debug 安装与真实 GUI 交互尚未验收`
- 风险：`当前 Kero 有正在执行的 codex agents，会话中断会造成用户工作损失；不能在此状态替换 App`
- 预期修复：`等待任务结束或经用户明确同意中断后，安全退出并安装唯一签名 Debug Kero.app；执行真机拖拽及设计稿逐项比对`
- 验证：`xcodebuild Debug PASS 且 codesign --verify PASS；真机结果当前未验证`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-03

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Workspace/DockWorkspaceModel.swift`
- 摘要：`升级后默认停靠比例与历史侧栏宽度不同`
- 风险：`长期配置的栏宽会突然变化，偏离 v3 截图与原始 Kero UI`
- 预期修复：`首次无新布局快照时换算现有左右 AppStorage 宽度，之后只采用停靠布局保存比例`
- 验证：`check-dock-workspace 迁移分数断言 PASS`
- 解决证据：`check-dock-workspace PASS: 1800pt window with 184pt/300pt sidebars converts fractions; saved snapshots bypass migration`


## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Workspace/Project.swift`
- 摘要：`全项目批量关闭与新标签组的范围不一致`
- 风险：`关闭其他标签或右侧标签可能误删另一分屏的会话与未保存编辑`
- 预期修复：`closeOthers 与 closeToRight 仅操作所在停靠标签组；保留原有保存确认`
- 验证：`源码调用链核对与 Debug 编译通过；真机关闭弹框路径待验收`
- 解决证据：`closeOthers and closeToRight scoped by DockGroup item identity with original closeBatch dirty editor confirmation path; Debug BUILD SUCCEEDED; end-to-end pending F-04`


## 发现 F-01

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/UI/Panes/PaneLayoutView.swift`
- 摘要：`多分屏同屏时旧窗口焦点判断不足`
- 风险：`多个终端同时认为自己是焦点，命令可能作用在非当前分屏`
- 预期修复：`注入全局选中 Tab 条件，并在 NSView 获得焦点时更新 project.selectedTabID`
- 验证：`源码调用链核对与 Debug 编译通过；真机多窗格鼠标焦点仍待验收`
- 解决证据：`PaneView.isFocused now requires active workspace tab; onFocused routes native focus; Debug BUILD SUCCEEDED; true macOS interaction pending F-04`


## 与 v3 设计稿逐项对照

| 设计验收项 | 源码证据 | 状态 |
| --- | --- | --- |
| 采用 Kero 现有圆角轻底色标签 | 直接复用 `PaneTabItem`、`TabItemChrome`，无独立标签样式 | 静态确认，待截图 |
| 默认左项目、中终端、右 Info/Files/Git | `DockWorkspaceModel.defaults` 及 `WorkspaceDockView` | 状态回归通过，待截图 |
| 标签可跨区移动、合并及排序 | `DockWorkspaceModel.move` 与 `DockTabDragCoordinator` | 状态回归通过，待真机拖动 |
| 上下左右靠边停靠、只显示单片预览 | `DockDropHitTest.edge` 与 `dropPreview` | 四向几何回归通过，待真机预览 |
| 分隔线调节和双击均分 | `DockTreeView.divider` | 编译确认，待真机操作 |
| ⌘B／⇧⌘B 收起并恢复，空区添加面板 | `DockNode.visible`、`TerminalManager.togglePanel`、`emptyGroup` | 状态回归通过，待快捷键实测 |
| 不破坏终端、SSH、文件及 Git 语义 | 复用 `PaneLayoutView`、`SidebarView`、`FileTreePanel`、`GitPanel` | 编译和树回归通过，待端到端 |
| 布局与侧栏宽度迁移、重启恢复 | `ProjectSnapshot.dock`、旧宽度比例迁移 | Codable 与几何回归通过，待重启复现 |

**验收边界：**静态对照只是代码契约和参考截图比对；上述“待真机”项一律不算已实际通过。

## 修复日志

- `59b1580`：修复多停靠组同时显示时的终端焦点与批量关闭范围；删除旧主标签栏和固定右侧标签栏；统一拖拽落点、状态持久化、完整面板复用。
- `59b1580`：初次无 Dock 快照时继承 `leftSidebarWidth`／`rightSidebarWidth`；修复在鼠标松开时使用最后落点，并保留原主标题栏最小拖拽区域。
- `93af1c1`：更新六份中文使用文档，确保操作、恢复与验收限制表述准确。

## 验证日志

- `xcrun swiftc ... DockWorkspaceModel.swift scripts/check-dock-workspace.swift && /tmp/check-kero-dock` → PASS（移动、排序、分屏、恢复、宽度、四向命中、关闭面板）
- `xcrun swiftc ... scripts/check-file-tree-navigation.swift` → PASS（含 10k 文件响应）
- `xcrun swiftc ... scripts/check-tree-row-hit-testing.swift` → PASS（原生点击命中）
- `xcodebuild ... -configuration Debug build` → BUILD SUCCEEDED
- `codesign --verify --deep --strict .../Kero.app` → PASS
- `python3` 校验 Interface.xcstrings 新增六条简中译文 → PASS
- 六份文档内相对 Markdown 链接存在性校验 → PASS
- `git diff --check` → PASS
- `/Applications/Kero.app` 安装、拖拽、重启截图及 Diff 切换 → **未执行，受运行中的 Codex 进程阻塞**

## Gate（是否允许进入下一阶段）

- 结论：`No-Go`（仅阻止标记为全部验收通过；已保存源码提交）
- 理由：已有真实用户任务在 Kero 终端运行，不能替换 App 来做规定的签名 Debug 真机操作；实际 GUI 验收是不可省略的关口。

## 最终状态与剩余风险

- 当前状态：`Open`；P2-T1 与 P2-T2 均 blocked，F-01/02/03 修正但真实交互待确认，F-04/05 保持 Open。
- 剩余风险：安装会中断 `codex agents` 活动会话；拖拽是否符合实际点击／键盘／坐标行为、Diff 恢复性能尚不能作完成声明。用户结束或允许终止任务后，安装单一 `/Applications/Kero.app`、逐项截图并与 v3 对照，修正发现问题后重新审计 Gate。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
