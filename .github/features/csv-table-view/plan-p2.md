# P2｜网格编辑与无损保存

交付表格改单元格、增删行、撤销重做，且 Git Diff 与磁盘内容只反映明确的用户编辑。

## 方案

在现有 `FileTab` 的 `NSTextStorage` 上执行字段级替换，不把排序后可见行当物理行，也不先重排整份 CSV。
解析索引由文本版本失效重建；Undo、编码、保存队列和 `WorkspaceBackend.write(ifUnchanged:)` 仍走原有 FileTab。
若源文件已损坏而无法提供无歧义字节区间，不允许网格写入；源码仍可修复。
插入新行按原文件的分隔符和主导换行构造新字段，绝不将逗号拆成普通字符串。

## 任务

<a id="p2-t1"></a>
### P2-T1 单元格操作共享 TextKit Undo

- **位置**：`FileTab` 编辑入口、CSV 解析器、`CSVTableView`、原生 UndoManager。
- **实施**：双击／Return 编辑、Tab／Shift-Tab 导航、范围粘贴和增删行；编辑定位原始记录，按需引用转义。新文本更新当前原生正文；视图切换沿用同一 Undo。
- **验证**：原文引号／多行单格、中文、空值、尾列、大小范围粘贴、筛选后改单格、Undo／Redo、同时有未保存源码时不丢修改。

<a id="p2-t2"></a>
### P2-T2 保存与真实外部冲突验收

- **位置**：既有 `FileTab.save`／`WorkspaceBackend.write(ifUnchanged:)`、CSV 文件测试、`docs/features/editor.md`。
- **实施**：保留字段外字节、源编码、BOM、未编辑的引用方式和混合行尾。外部内容变化时拒绝覆盖并保留未保存表格编辑，统一关闭提示。
- **验证**：磁盘前后 byte diff；关闭、App 恢复、Finder 修改、多窗口两个脏副本、不可写文件和 32 MiB 边界。实际应用中完成打开→编辑→⌘S→重开、Git Diff，确保没有隐式重写。

## 阶段验收

按 `docs/testing.md` 完成本机宿主字节级边界与真实 Bailey Dev GUI。
筛选与排序仍为只读视图行为，只有显式字段与行操作参与保存；不以“能显示表格”冒充“可安全编辑”。
