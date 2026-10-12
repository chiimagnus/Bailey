# P1：删除标签内部布局

**目标：** 从状态所有者删除多内容标签，而非关闭快捷键后留下可达或潜伏实现。

**非目标：** 不更换终端/编辑器/网页后端，不改变独立标签自由停靠，不迁移旧数据，不安装正式应用。

**方法：** 单个原子改动同时替换状态、调用方、快照、入口与现有验证，避免不能构建的中间提交。先核实全部路径，再分块落盘；每块删除被替代代码。

## P1-T1 实现单内容标签并删除所有内部拆分入口

### 源码锚点

- Workspace/PaneTab.swift::PaneTab、Project::closeContent/restoreTab、TerminalManager::makeWindowSnapshot/restore、SessionStore。
- KeroCommands、CommandPaletteView.commands、WorkspaceDockView.content、PanelContentView、WorkspaceChrome、TabSwitcherView。
- TerminalHostView、TerminalSession、TerminalSurface、TerminalOpenMenuTarget、SourceTextEditor、FileViewerView、BrowserView、FileTreePanel、GitPanel、ToolPanelView。
- `KeroTests/check-session-snapshot.swift`、`KeroTests/check-pane-retention.swift`、`KeroTests/check-workspace-identity.swift`；AGENTS、TERMINAL/SETTINGS/BROWSER/PRODUCT 文档及被删除动作的字符串。README 保留用户删减后的内容，不恢复、不改写。

### 实施

1. PaneTab 只保存一个 content、名称、上下文及单个脏状态观察。Project 直接操作标签内容，删除数组包装与内部索引、几何、焦点、缩放、侧边创建。
2. 以单内容 PanelContentView 替换内部布局渲染；保留全窗口焦点回报及长生命周期视图桥接。终端打开链接/文件的新标签菜单保留，旧分屏 target 收敛为只负责打开的 target。
3. 删除所有内部拆分菜单、命令面板、按钮、回调和缩略图分屏。关闭对话框取消“不保存”快捷键，但失败/取消保护不变；保留 Ghostty 默认绑定清空。
4. 新 TabSnapshot 直接保存内容、历史、名称及上下文；外层 Dock 不改。新存储键不读取或覆盖旧快照；没有迁移/兼容路径。
5. 同步现有测试为独立标签，覆盖外层移动/重挂载与关闭、保存失败和机器隔离；同步文档、字符串和性能计划挂载锚点，不重写旧审计来伪造历史。

### 验证与提交

- bash scripts/check.sh session-snapshot dock-workspace。
- 按 AGENTS 构建 kero Debug 并严格校验签名。
- bash scripts/check.sh pane-retention workspace-identity；原生检查证明实际生命周期，不仅模型分支。
- 核对菜单注册、全量源码和双语目录没有内部布局入口；签名 Debug 动态库的原生组件回归验证独立内容打开、编辑、停靠、重挂载及关闭。鼠标拖拽和正式包重启不作为已测结论；不操作正式实例。
- 精确搜索旧类型、入口、回调、字符串与命令；rtk git diff --check；仅提交本任务生产/文档/测试变更。

## 阶段审计

完成后新建 audit-p1.md，独立核实入口残留和生命周期；不参考其他 feature 的既有审计。
