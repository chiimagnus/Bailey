# P2｜网格编辑与无损保存

交付表格改单元格、增删行、撤销重做，且 Git Diff 与磁盘内容只反映明确的用户编辑。

## 技术决定

沿用 P1 的**自有单份 RFC 4180 词法索引**、AppKit `NSTableView` 与现有 TextKit 2／`UndoManager`，**不引入 `CodableCSV` 或第二套 CSV 序列化器**。
网格写入按 UTF-16 源区间修补原生 `NSTextStorage`，仅对用户明确改变的字段执行必要的 quote/escape；未经编辑的其它字段／行永不因排序、筛选或保存而重新编码。
文件真实字节保存与外部版本比对继续由 `FileTab.save` / `WorkspaceBackend.write(ifUnchanged:)` 负责，不引入新的文件写入层或后台自动转换。

## 方案

在现有 `FileTab` 的 `NSTextStorage` 上执行字段级替换，不把排序后可见行当物理行，也不先重排整份 CSV。
解析索引由文本版本失效重建；Undo、编码、保存队列和 `WorkspaceBackend.write(ifUnchanged:)` 仍走原有 FileTab。
若源文件已损坏而无法提供无歧义字节区间，不允许网格写入；源码仍可修复。
插入新行按原文件的分隔符和主导换行构造新字段，绝不将逗号拆成普通字符串。

## 任务

<a id="p2-t1"></a>
### P2-T1 单元格操作共享 TextKit Undo

- **位置**：`FileTab` 编辑入口、CSV 解析器、`CSVTableView`、原生 UndoManager。
- **实施**：双击／Return 编辑、Tab／Shift-Tab 导航、范围粘贴和增删行；视图排序／过滤后的显示行必须映射回**物理记录**，使用稳定的 UTF-16 源范围替换并在变更后作索引失效处理。
  只对修改的字段做最低限度引号／转义，保留其他字段的全部原样写法；多格粘贴作为同一 Undo 事务并处理行列容量限制。新文本修改原生 TextKit 正文，源码和表格共用原生 Undo。
- **验证**：按逐字节 diff 检查仅目标字段变化；复杂引号／多行单格、CRLF、BOM、中文／emoji 的 NSRange、空值与尾列、大小范围粘贴、筛选或排序后改单格、源码／表格交替编辑及 Undo／Redo；同一 `FileTab` 的未保存修改绝不丢失。

<a id="p2-t2"></a>
### P2-T2 保存与真实外部冲突验收

- **位置**：既有 `FileTab.save`／`WorkspaceBackend.write(ifUnchanged:)`、CSV 文件测试、`docs/features/editor.md`。
- **实施**：保留字段外字节、源编码、BOM、未编辑的引用方式和混合行尾。外部内容变化时拒绝覆盖并保留未保存表格编辑，统一关闭提示。
- **验证**：磁盘前后 byte diff；关闭、App 恢复、Finder 修改、多窗口两个脏副本、不可写文件和 32 MiB 边界。实际应用中完成打开→编辑→⌘S→重开、Git Diff，确保没有隐式重写。

## 阶段验收

按 `docs/testing.md` 完成本机宿主字节级边界与真实 Bailey Dev GUI。
筛选与排序仍为只读视图行为，只有显式字段与行操作参与保存；不以“能显示表格”冒充“可安全编辑”。
