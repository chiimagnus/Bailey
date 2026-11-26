# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：P2-T2 独立完成：已存／保存后 Browser 运行、脚本执行和最小目录权限、外部版本／远端拒绝及脏稿保护通过。P2-T1 并排真实中文 IME、Undo／Redo、最终 WebKit 中文与源字节已通过；既有真实 IME 与原生连续编辑期间滚动专项均通过（见[共享验收](../file-viewer-routing/audit-p1.md)）；最终整合与 P1 门禁留阶段。
- **现行 AX 验收**：依[共享验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)，下文 VoiceOver 记录仅为历史证据，专项语音不再阻塞。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。
  保存冲突后续统一按[VS Code 保存冲突方案](../file-viewer-routing/plan-p1.md#shared-save-conflicts)，不将严格 CAS 冒称已解决。

## 任务与改动

- **P2-T1 实时渲染、同标签并排和阅读位置保持**：HTMLFilePreview、FileTab.showHTMLPreview、PreviewResource：当前源文和授权资产版本、同标签原生 WebView 与阅读位置；7c9ffcf7 连续 100 次实际编辑。
- **P2-T2 明确浏览器运行的已保存版本与文件权限**：FileTab.savedHTMLForBrowser/openSavedHTMLWithoutAutoSave 与 BrowserTab：622b7db0 明确选择磁盘版本、实际 loadFileURL、相对资源和本机路径/远端身份边界。

## 发现项

### F-01｜刷新把读者拉回编辑前的位置（已修复）

旧页面在编辑合并期间仍可阅读，但原实现过早记下滚动位置。
`839186db` 改为在同一文件实际导航前取样；过期请求不能回写，进行中的恢复保留自己的位置。

在屏外 AppKit 窗口中，以实际 Bailey Dev 组件连续修改正文 100 次，
在合并期间向该窗口投递原生 End 键。旧版三次从 7658 回退至 1520；修复后三次保留 7658，
草稿仍未保存。实际 SwiftUI 文件视图自动刷新并切回源码再重挂后，仍是同一 WebView 和 7658 的位置。
Dev 构建／严格验签、回归测试文件编译通过。正式宿主 XCTest 尚未开始运行即中止，不计为用例通过；
这不是物理输入或完整 App 长会话。

## 验证与未覆盖

- 最新本机隔离 App 三项通过，覆盖双窗命令归属、编辑预览与显式打开保存版本；`839186db` 的编辑期间滚动保持已用实际 TextKit 和 WebKit 验证。真实中文 IME、辅助功能及长会话仍待核销。

- 真实 HTMLFilePreviewTests 18 项曾全部通过：100 次编辑最新 DOM，1520px 阅读位置、WebContent 退出恢复、真实 WKWebView 本机已存版本执行及未存原字节保护；授权资源边界见 P1 审计和 todo.toml。
- 远端 6102bf3e 完整 App HTML 3/3 通过，含原显式执行流程。27c2b254 增补动态草稿和相对脚本的真实端到端用例已在 45534516603（4575cddb）实际通过；HTML 3/3，零失败、零跳过。
- H12×H13：云端用例实际验证了在 Browser 中运行选定的磁盘版本及其相对脚本。
  测试通过粘贴输入草稿，不能证明 H09×H11 的中文 IME 候选与焦点交接；
  双窗口菜单用例也不能证明 H10×H14 的完整 App 多窗长会话。
  这些项目尚待补验，保存后执行仍依赖共享保存版本边界。
- 最新共享构建、冻结宿主与完整 App 结果以 [文件路由审计](../file-viewer-routing/audit-p1.md) 为准；现行行为归 [文件编辑器](../../../docs/features/editor.md)。

- 2026-11-25：`bd6e74a2` 共享本机保存恢复定点通过；已存版本显式打开的既有完整 App 证据不变。严格非协作 CAS 与真实输入／多窗长会话仍未核销，见 [CSV P2](../csv-table-view/audit-p2.md)。

- 5d216abe：HTML 源码共用 FileTab 保存错误及可换行提示；共享保存与资源回归 16/16 通过。严格 CAS 和设备/完整 App 门禁不变。 共享验证证据见 [CSV P2 F-09](../csv-table-view/audit-p2.md#发现-f-09)。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 本机隔离 Dev 真实拼音组合 `zhong wen`，确认 `中文` 前磁盘未改；显式保存后切预览，实际 DOM 可访问文字与屏幕显示中文，源字节为 `<h1>\n中文\n</h1>\n`。证据 `/tmp/bailey-ime-native.VZLk2z/{15,16,17}.json`、`17.png` 与 `Bailey-UITest-IME/project/Composition.html`。单窗真实输入与渲染通过，不代替并排连续 IME／滚动交叉验收。

- 隔离完整 Dev 自动化真实系统拼音（非粘贴）：并排组合、候选中文、连续 Undo／Redo，DOM 实际可见中文，精确保存。证据 /tmp/bailey-native-ime-auto.dL04QZ/run5.log、remaining-*.json／截图。退出恢复原输入源；不冒称完成所有滚动／设备交叉。
