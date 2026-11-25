# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：真实 WebKit 静态/执行态隔离与源码联动已有证据；新增完整 App 动态未存版本／相对脚本用例尚未执行，中文 IME、独占 GUI 和 P1 门禁仍未核销。

## 任务与改动

- **P2-T1 实时渲染、同标签并排和阅读位置保持**：HTMLFilePreview、FileTab.showHTMLPreview、PreviewResource：当前源文和授权资产版本、同标签原生 WebView 与阅读位置；7c9ffcf7 连续 100 次实际编辑。
- **P2-T2 明确浏览器运行的已保存版本与文件权限**：FileTab.savedHTMLForBrowser/openSavedHTMLWithoutAutoSave 与 BrowserTab：622b7db0 明确选择磁盘版本、实际 loadFileURL、相对资源和本机路径/远端身份边界。

## 发现项

## 验证与未覆盖

- 真实 HTMLFilePreviewTests 18 项曾全部通过：100 次编辑最新 DOM，1520px 阅读位置、WebContent 退出恢复、真实 WKWebView 本机已存版本执行及未存原字节保护；授权资源边界见 P1 审计和 todo.toml。
- 远端 6102bf3e 完整 App HTML 3/3 通过，含原显式执行流程。27c2b254 增补动态草稿和相对脚本的真实端到端用例，已构建及严格签名，未执行新用例。
- H09×H11 的真实中文 IME／焦点组合、H10×H14 完整 App 多窗长会话、H12×H13 新版实际执行和真实 GUI 仍需独占图形会话。宿主实际 WebKit 不代替这些验收；保存后执行仍依赖共享保存版本边界。
- 最新共享构建、冻结宿主与完整 App 结果以 [文件路由审计](../file-viewer-routing/audit-p1.md) 为准；现行行为归 [文件编辑器](../../../docs/features/editor.md)。
