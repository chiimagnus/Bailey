# Kero 源码模块化与必要协议边界

## 背景与目标

Kero 已有项目、终端、两层递归分屏、自由停靠、Files/Git/Info、SSH、编辑器与浏览器功能。随着迭代，部分视图同时承担刷新和远程连接协调，部分模型跨越窗口/项目职责；`Workspace/FileTreeModel.swift`、`Terminal/SessionInfoModel.swift` 和 `UI/Panels/ToolPanelView.swift` 的物理归属也不再体现实际功能边界。

目标不是换一套架构，而是在不改变产品行为的前提下：**明确状态与生命周期的唯一持有者，收敛真实跨功能调用，把混合文件按职责拆开，整理源码目录；只在确有多个实现或能力边界时使用 Swift Protocol。**

本 Feature 以已提交的根 `AGENTS.md` 为实施规则，以 `docs/PRODUCT.md`、`docs/CONTRIBUTING.md` 和相关功能文档为现有行为依据。

## 必须满足

1. **状态不漂移**：窗口级项目选择和恢复由窗口协调者管理；`Project` 继续拥有其标签、外层 `DockWorkspaceModel`、文件树；`PaneTab` 持有内部 `PaneNode` 和终端/编辑器等内容。明确 Files/Git/Info 刷新与端口转发的持有者和取消时机，避免把长期状态绑定在易重建的 SwiftUI View 上。
2. **功能划分可辨**：Files、Git、Info 的业务/界面职责从当前混合面板源码中分离；窗口、项目、编辑器、浏览器、终端与远程实现归属清晰。共享树模型与行交互只有一个实现，供 Files、Git 未提交/暂存、提交历史共用。
3. **依赖边界最小**：复用 `WorkspaceBackend`、`TerminalBackendSurface`、`RemoteCommandRunner`；仅当实际耦合/替换需求成立时调整或增加契约。保留本地和 SSH 不同的超时、批处理与路径信任边界；不强制所有类型都定义协议。
4. **配置独立于内部设计**：`config.toml` 仅是用户设置输入；新项目所需配置由构建项目的入口传入，业务模型不为读取全局设置而耦合 App 层。保留既有设置的用户行为。
5. **用户可见行为不变**：原生 Kero 标签样式、拖拽停靠/重排、两层上下左右分屏、项目与会话恢复、未保存文件、SSH 文件/Git/Info、端口转发、Git 操作、文件树惰性展开与无障碍行为不退化；移动标签不重启 Shell。
6. **渐进式原子提交**：每一项改动独立可编译、可验证，变更同时更新调用者和必要文档，不能先留下悬空实现再依赖后续任务修复。执行严格按 `todo.toml` 顺序，阶段结束按项目流程审计。

## 默认决策与数据安全

- 保持现有单个 Xcode App Target、SwiftUI + AppKit/Ghostty 集成及文件系统同步工程分组；先通过代码职责与目录组织模块，不拆 Swift Packages。
- 用户只有一份 Kero，不为已淘汰的代码路径预留新兼容层；但**已有项目布局、终端历史和未保存内容必须保护**。涉及快照结构时先检验当前保存数据、做好可恢复备份，并仅在现有数据可安全读取的前提下移除无用分支。
- 当前窗口级 `GitStatusModel`、项目级 `FileTreeModel` 等所有权以源码为证据；重构前先做生命周期验证，不把拟议的新边界描述为既成事实。

## 明确非目标

- 不新增产品功能、交互样式、菜单/快捷键、协议驱动 API、CLI/MCP、插件体系或网络服务。
- 不扩大 `config.toml` 配置项，不以配置驱动框架取代模块边界，也不引入依赖注入框架、事件总线、通用 Service/Repository/Protocol 模板。
- 不借本次重构实施 `editor-git-performance` Feature 的性能优化；只保护现有懒加载、事件合并和远程批处理，不凭拆目录宣称性能提升。
- 不手改生成的 `MaterialFileIcon.swift` / 图标，或为移动目录改写第三方 `Vendor/`。

## 完成验收

- 文件与职责的实际依赖关系可说明：每个长期状态只有明确持有者，必要协议有具体消费者；目录变动不造成第二套树组件、模型或会话快照。
- 每项任务记录源文件、真实调用链、行为不变量及针对性检查；无关清理不混入，Git 原子提交可单独审查。
- 现有 `scripts/check-dock-workspace.swift`、`check-file-tree-navigation.swift`、`check-tree-row-hit-testing.swift` 等受影响检查通过；重构后的测试命令/路径同步更新。
- 按 `docs/CONTRIBUTING.md` 安全验证签名 Debug，真实检查本地与 SSH、Files/Git/Info、标签/窗格拖拽、项目切换、关闭/重启恢复和长树交互。正式 Kero 中有不能中断的任务时先使用隔离模式；不能以模拟点击成功代替真实效果。
- 最终文档与引用路径一致；不引入过期目录、孤立文件、遗留兼容逻辑或额外的架构层。