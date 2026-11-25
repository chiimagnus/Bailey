# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：真实矢量、非法源码恢复、有界 PNG 和独占输出已有证据；完整 App 新增实时编辑及实际导出已通过；物理显示／输入设备、共享文本保存竞态和 P1 门禁未核销。

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
