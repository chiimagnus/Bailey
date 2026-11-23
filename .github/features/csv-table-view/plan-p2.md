# P2｜通过现有 TextKit 单缓冲编辑 CSV 并原样保存

交付网格单元格编辑、撤销、增删行、复制粘贴和条件保存。
排序／筛选只改变展示映射，不能在保存时重排或重写其它字段。

## 已确认的写入语义

`FileTab.nativeTextStorage` 是唯一可写正文；`FileTab.save` 经
`TextFileEncoding.prepareSave` **把完整文本编码为字节**，随后调用
`WorkspaceBackend.write(ifUnchanged:)` 保护原文件版本。
因此“只修改某个字段”应指**当前文本文档只替换该字段源区间**，
最终编码后字节 diff 也必须证明未编辑区间保持原样，
而不是另做一套 CSV 磁盘补丁或序列化整张表。
任何编码在保存前必须严格往返：若重新编码整个未编辑原文与原始
`WorkspaceFileVersion` 不匹配，网格只读，提示用户回源码，不得静默转换。

当前 `SourceTextEditor` 的 `Coordinator` 与原生 `NSTextView` 持有编辑器和 Undo 关联，
而网格默认显示时编辑器可能尚未挂载。
**首个 P2 任务必须先验证脱挂载时 Undo 属于谁**：
把文本源和网格编辑绑定同一个文件标签寿命的原生 Undo 上下文，
让源码输入、网格输入与 `⌘Z`／`⌘⇧Z` 同栈交替生效；
不靠一个不可见的第二编辑器，也不新建单元格草稿正文／独立 Undo 历史。
当网格输入生效，更新现有 `nativeStorageDidChange`／`refreshDirtyState` 的同一条链，
撤销须复原完整原文区间且在回到保存基线时清除脏状态。

## 任务

<a id="p2-t1"></a>
### P2-T1 对原文源区间执行原生编辑、复用唯一 Undo

- **位置**：P1 CSV 解析索引、`FileTab.nativeTextStorage`、
  `SourceTextEditor` 的现有编辑／Undo 归属、`CSVTableView`。
- **实施**：双击／Return 编辑、Tab／Shift-Tab 导航、矩形粘贴、插入／删除记录；
  先由当前展示行映射回物理记录，再定位单元格 UTF-16 源范围。
  单元格修改时只对该字段加入最低限度 quote/escape，未变的引用方式不动；
  多格操作作为一组 Undo，修改后按编辑代次重建索引并保留有效选区。
  确保源码／网格输入到同一 NSTextStorage、Undo、dirty、保存队列；
  同任务删除被替代的旧事件、选区或重复转换，不补建中间可写表格模型。
- **验证**：实测 `NSTextStorage`／`NSTextView` 同栈 Undo、网格默认打开无源码视图、
  源码↔网格交替编辑、中文 IME、行高不一、筛选／排序后改单格、
  带引号／多行字段、空列、复制粘贴不同行列形状、容量边界、
  32 MiB 限制、Ctrl／Cmd 组合键、撤销到基线恢复 clean；
  对照原文 UTF-16 与保存后每一处真实字节 diff。

<a id="p2-t2"></a>
### P2-T2 严格往返编码、条件保存和外部冲突

- **位置**：`FileTab.save`／`TextFileEncoding.prepareSave`、
  `WorkspaceBackend.write(ifUnchanged:)`、CSV 测试与 `docs/features/editor.md`。
- **实施**：继续由现有 FileTab 执行全文编码和有版本的条件写入，
  保存前断言未修改的源文字区间按原编码逐字节一致；
  保留 BOM、CR/LF/CRLF、原引用样式与不变的空白。
  外部内容已被更改时不覆盖并保持全部未存的网格编辑。
  `write(ifUnchanged:)` 当前是提交前验证，不是跨所有文件系统的原子比较替换；
  并发外部写入窗口如实测可导致覆盖，应在共享 Backend 所有者处一次修复，
  不能把方法名或只检查 `mtime` 当作完美无冲突的证据。
  不新增 CSV 读写引擎、独立保存队列或排序后导出覆盖原文件。
- **验证**：打开→网格编辑→⌘S→重开→Git Diff 的实际磁盘变化；
  外部同长同 mtime 改写、两个窗口并发脏稿、编码失败／只读、
  保存中继续编辑、权限错误、SSH 断线重连、重命名、
  不合法 CSV 修复前禁网格编辑、UTF-8 BOM／UTF-16／GBK、混合行尾和容量临界点。
  对比整份源字节 diff、Undo 重做、关闭保护及未改字段逐字节保留。

## 阶段验收

运行现有 `FileTabPersistenceTests`、`NativeEditorCompositionTests`、
CSV 解析／事务／Undo 与条件保存宿主用例、`make build` 和阶段 `make test`；
隔离 Bailey Dev 验证表格和源码实际编辑保存、文件冲突和快捷键，
遵守 `docs/testing.md` 的本机／获授权 SSH、规模、状态和极端组合。
