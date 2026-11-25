# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：P2-T2 独立完成，48bbbd5d 后的三项 PNG／独占发布宿主与真实 App 复制／新目标导出均通过，普通源码保存接线通过。P2-T1 并排连续输入、现有设备／VoiceOver、共享磁盘错误与保存冲突回归、P1 阶段门禁仍待；未执行实际磁盘满。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。
  保存冲突后续统一按[VS Code 保存冲突方案](../file-viewer-routing/plan-p1.md#shared-save-conflicts)，不将严格 CAS 冒称已解决。

## 任务与改动

- **P2-T1 同步源文字节与矢量图形、保持滚动状态**：SVGFilePreview、FileTab.showSVGPreview、NativeSVGViewport 共用源文本代次和视口；a3502b7a 的无效 XML、100 次真实编辑、上一有效图像／错误恢复和缩放中心证据。
- **P2-T2 SVG 有界复制／导出与源码保存回归**：SVGArtwork、FileTab 的当前草稿、命名剪贴板和独占文件发布；1da0f3dd／b54ee4cf 有界 PNG、ICC、alpha、滤镜及取消／旧版本拒绝。

## 发现项

## 验证与未覆盖

- 既有 PreviewScrollViewTests／SVGArtworkTests 真实截图、复杂科研 SVG 百次开闭、1×1／32768×1／800 万像素、并发输出、已有目标和悬空链接等；任务专项 18 项及整合 95+3 项通过（详见 todo.toml、P1 审计）。
- 远端 6102bf3e 完整 App SVG 5/5 通过；27c2b254 新增非法源码→恢复、Undo/Redo、实际复制和新目标导出的用例已在 45534516603（4575cddb）实际通过；SVG 6/6，零失败、零跳过。此为云端虚拟图形设备结果，不替代物理设备或双窗综合长会话。
- 仍缺真实中文 IME、VoiceOver 播报、物理 1× 与触控板，以及双窗长会话组合；保存原文仍共享未核销的第三方条件写入边界（参见 CSV P2 审计 F-02）。S09–S13 的这些交叉项阻塞 Go。
- 最新共享构建、冻结宿主与完整 App 结果以 [文件路由审计](../file-viewer-routing/audit-p1.md) 为准；现行行为归 [文件编辑器](../../../docs/features/editor.md)。

- 2026-11-25：`bd6e74a2` 改进共享本机条件保存冲突恢复，未改变 SVG 渲染和缩放；严格非协作 CAS 与真实输入／物理显示器／长会话仍未核销，见 [CSV P2](../csv-table-view/audit-p2.md)。原 `48bbbd5d` 接缝回归证据保留。

- 5d216abe：SVG 源码共用 FileTab 保存错误及可换行提示；共享保存与资源回归 16/16 通过。严格 CAS 和设备/完整 App 门禁不变。 共享验证证据见 [CSV P2 F-09](../csv-table-view/audit-p2.md#发现-f-09)。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 本机隔离 Dev 原生中文拼音输入（非剪贴板）：`zhong wen` 候选期间磁盘保持旧源码，空格确认 `中文` 后显式保存，切回原生 SVG 验证中文字形及精确 UTF-8。证据 `/tmp/bailey-ime-native.VZLk2z/{20,21,22}.json`、`22.png` 与 `Bailey-UITest-IME/project/Composition.svg`。仅核销单窗真实输入、保存与渲染；并排快速组合输入及物理设备交叉项仍待补。
