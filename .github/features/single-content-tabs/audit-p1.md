# Audit P1 - single-content-tabs

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/single-content-tabs/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 删除标签内部布局并保留独立面板生命周期

## 任务到文件的映射

- P1-T1
  - `kero/Workspace/PaneTab.swift`：一个标签只持有一份内容，发布名称与脏状态。
  - `kero/Workspace/{Project,TerminalManager,SessionStore}.swift`：独立内容创建、身份查找、关闭、快照与恢复。
  - `kero/UI/Panes/PanelContentView.swift`、`WorkspaceDockView`、`WorkspaceChrome`、`TabSwitcherView`：真实挂载、选择、标题与预览。
  - `kero/App/keroApp.swift`、`CommandPaletteView`、终端/编辑器/浏览器/Files/Git 调用方：删除所有内部创建和布局动作；保留新独立标签。
  - `scripts/check-{pane-retention,session-snapshot,workspace-identity}.swift`：当前模型和真实原生组件回归。
  - `AGENTS.md`、`docs/{TERMINAL,SETTINGS,BROWSER,PRODUCT}.md`、五份双语字符串目录：当前约束同步。README 完全保留用户内容。

## 发现项

独立复核未发现未解决的范围内缺陷。未读取其他 feature 的既有 audit。

## 修复日志

- 实施中原生回归确认 NSAlert 根据“不保存”标题隐式设置 Command-D，生产代码显式清空；保留保存失败与取消保护。
- 验收脚本不再依赖应用成为 key window：定时响应本进程实际模态窗口或 sheet，通过按钮完成关闭，核对最终标签及编辑状态。未增加生产重试或兼容路径。

## 验证日志

- 当前统一入口 `kero` 的 Debug 原生测试与构建已覆盖该功能；双应用身份的旧构建入口已移除。
- Debug 产物统一为 `build/DerivedData/Build/Products/Debug/Kero.app`。
- `bash scripts/check.sh pane-retention workspace-identity session-snapshot dock-workspace file-tree-navigation tree-row-hit-testing` → 六项 PASS；最终签名构建后再次运行，日志 `build/single-content-tabs-checks.log`。
- 原生检查实际操作 AppKit/STTextView 编辑、WKWebView 表单/滚动/历史、Ghostty Shell PID 和停止；Cancel、保存失败、明确放弃及正常保存均到达最终状态；文件/空白浏览器快照恢复通过。
- 98 份当前源码、字符串目录及维护文档的旧内部类型/动作残留检查 → PASS；显式 Command-D 入口不存在，字符串 JSON 有效。
- `rtk git diff --check` 与两个 feature 的 `todo validate` → PASS。
- 生产原子提交：`a4cb7ffed4d5517286bc1f930d3aa2d419f8c9b6`。未包含 README 或 feature 计划；任务回写与阶段完成校验通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：单内容状态不变量成立，旧内部布局与入口整体删除，原生生命周期及关键失败路径回归通过；独立停靠实现未被替换。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 证据边界：未代操作鼠标拖拽或正式包重启，未测真实 SSH 网络传输；受控后端不能替代这些验收。正式应用未替换、未重启。旧窗口快照按用户决定不恢复，无迁移或旧格式解码；原始数据未主动删除。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
