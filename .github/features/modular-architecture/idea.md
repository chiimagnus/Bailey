# Kero 内部模块化重构

## 目标

在**不改变现有产品行为**的前提下，按真实职责整理源码：外层停靠与内部窗格仍分别由 `DockNode`、`PaneNode` 管理；项目、终端、Files、Git、Info、Remote 与 UI 各有明确的状态/操作归属。优先复用现有协议与组件，只在确有两个实现或实际调用边界时新增协议。

本 Feature 以根 `AGENTS.md` 和 `docs/PRODUCT.md` 为约束，`docs/CONTRIBUTING.md` 为验证入口。采用一个 Xcode App Target，不拆包、不引入服务容器和通用配置/插件框架。

## 不变量

1. **状态所有权**：每窗口由 `TerminalManager` 协调；`Project` 负责项目的标签、外层 Dock 和文件树；`PaneTab` 负责内部分屏；`ContentView` 当前持有窗口级 `GitStatusModel`。变更必须保留相应生命周期和数据归属。
2. **唯一共享实现**：Files、Git 工作区/暂存与提交历史继续复用 `TreeDisplayModel` 及树行控件。目录压缩、颜色、点击、焦点、无障碍与惰性加载不能被复制或替代。
3. **本地与 SSH 语义**：`WorkspaceBackend`、`TerminalBackendSurface`、`RemoteCommandRunner` 保留现有边界；Git 本地命令的超时/管道输出和远程批处理不得被机械统一。文件、进程、Git 命令和端口转发操作保持正确机器与仓库范围。
4. **上下文安全**：切换项目、同一项目中连续更改工作目录、关闭/重开 Info 或断开 SSH 后，旧异步结果不得更新新作用域；终端停靠/分屏移动不重新启动 Shell。只修真实可达的不变量缺口，不层叠 generation、重试、全局缓存或安全围栏。
5. **用户与数据不退化**：项目/窗口、已保存的当前格式布局、标签位置、文件和 Diff 状态、Git 操作、未保存编辑及当前终端/SSH 运行命令受保护。必要时先备份真实快照；不为个人项目继续支持已废弃的历史布局或设置迁移格式。
6. **增量收敛**：新实现或新归属接入的**同一个 Task**就删除被替换的旧定义、旧调用/编译路径及确证无用的过时兼容代码；不能在 P5 才清理。每一步独立验证、原子提交；仅需要审查证据时不制造提交。

## 已识别的范围

- `ToolPanelView.swift` 混合了 Files/Git/Info 的 UI、范围选择、异步刷新及按连接维护的端口转发视图状态。
- `ContentView.swift` 包含被 Dock 复用的底部工具栏和标签外观；`WorkspaceBackend.swift` 末尾实现了对 TerminalSession/RemoteConnection 的跨域扩展。
- `SessionStore.swift` 仍解析老版单内容、列式分屏和单窗口快照；`AppSettings.swift` 仍读取旧 UserDefaults/旧字体配置键。需在当前格式验证后就地清理。
- `GitStatusModel.runGit/remoteGitData` 还被 `DiffViewerView`、`CommandPaletteView` 使用；`DiffViewerView` 本地字节读取有独立大小上限，不可直接替换为通用字符串命令执行。
- `Editor/MaterialFileIcon.swift` 是生成资源，`BrowserView.swift` 等大文件不因行数而拆分；除已确认跨职责、跨调用边界的内容外不扩大范围。

## 非目标

不新增用户功能、菜单或设置项；不扩展 CLI/MCP/API、Swift Packages、依赖注入框架、事件总线、兼容层或测试框架；不修改 `Vendor/`、生成资源、不实施独立的性能 Feature。运行时安全校验（SSH 主机信任、删除确认、Git 防串仓、保存失败保留编辑、当前快照读写）**不是**历史兼容围栏，不能删掉。

## 验收

- 目录归属与真实所有者相符，没有重复实现、空壳转发或孤立文件；同任务清理完成，命令/文档的旧路径随之修正。
- 已有停靠、文件树和树行命中检查通过；Git、Files、Info、终端及编辑/差异的受影响真实调用路径均有对应验证。
- 签名 Debug 安全验收本地与可安全连接的 SSH、项目/窗口切换、双层分屏与重启恢复；未验证的远端条件如实记录，不能用模拟点击充数。
- `todo.toml` 为唯一执行状态，所有 Task 在实际执行前保持 pending；本次执行前审查仅更新 Feature Plan，不提前修改或删除产品源码。
