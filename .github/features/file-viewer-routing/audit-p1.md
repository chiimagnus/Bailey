# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go
- **依据**：真实渲染和系统文件投递已经验收；保持原文件读取与切换器路径，未增加分发框架。

## 任务与改动

- **P1-T1**：无需生产改动。`Project.openFile`、`openLocalFile`、`restoreTab` 最终沿现有
  `FileTab` 有界读取返回 `.text`；图片的大小、有效格式头及像素预算不变。
- **P1-T2**：共享接线 `597df61`，系统投递回归 `993519f`。
  `FileViewerView` 只在加载后的 `.text` 按 Markdown 自己的显示模式挂载预览；
  `TabSwitcherView` 继续截取原正文摘要，没有新的 `Content` 分支、全文渲染或额外 I/O。

## 发现项

## 验证与未覆盖

- `make test:FileTabPersistenceTests,NativeContentIdentityIntegrationTests,NativePaneRetentionIntegrationTests,WorkspaceIdentityTests,SessionStoreTests,FinderDeliveryIntegrationTests,NativeSyntaxHighlightingTests SIGNING=adhoc`：
  174 项通过，涵盖图像／伪装文件／容量、初次读取与恢复、远端身份和本机路径、
  窗口及原生表面、冲突和撤销。
- macOS 27.3、Xcode 27.2 上，隔离 Bailey Dev 定点 GUI 4 项通过。
  Launch Services 混合文件实际投递和重用、Markdown 真实视图往返、标签数及原字节全部核验。
  另一个工作树存在同 ID 的 Dev 宿主时，旧夹具可能将事件交给错误 App；
  已要求与 Runner 同一产物目录，并禁用 Launch Services 的运行实例代换。
- 最低系统 15.6 无可用环境；部署目标未改，SDK 可用性只由构建核验。真实 Windows SSH 不在
  此次可授权验证环境中；已有远端连接／同名本机路径的受控测试，本次不经过远端媒体回退。
  完整 Finder 拖放与真机 VoiceOver 未逐项重测；保留现有装配，宿主测试验证身份和 AX 路径。
- `docs/features/editor.md#markdown-预览` 同步实际功能。现有 Markdown 之外的独立格式
  不新增类型或占位渲染。
- `make build`、`make build:release` 均退出 0 并通过严格验签。
  最终全量宿主首次 1,114 通过、18 项缺少授权 SSH 跳过，唯一失败是 Save 的旧菜单断言。
  断言修订后相关 35 项宿主退出 0，生产代码未变，其余全量结果仍适用；未再次运行完整宿主命令。

## 独立复核（2026-11-21）

原 Go 结论遗漏了 Finder 打开项目目录外 Markdown 的相对资源路径：
资源错误地受当前项目根限制，项目外本机文件点击相对链接也可能被拒绝。
`18150d59` 修正授权边界：项目内沿用项目根，项目外 Finder 文件仅允许自身父目录；
链接沿原文件后端打开，不把 SSH 文件误映射到本机。保留 `../` 和符号链接逃逸拦截。
`MarkdownResourceScopeTests,FileTabPersistenceTests` 共 63 项 Host 测试通过。
真实 Windows SSH、此组合在多窗口的完整 GUI 仍未独立验收。

