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
`NSTextStorage.replaceCharacters` 不应被假定自动注册与 `NSTextView` 完全相同的 Undo；
**首个 P2 任务必须先用真实 AppKit 宿主实验验证脱挂载时 Undo 属于谁**：
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

### CSV 写入与事务专项验收矩阵（P2）

P1 的 C01–C07 和[共用 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)
均须按受影响路径回归；以下测试要在真实 `NSTextStorage`、原生 Undo 和临时磁盘上执行。

| 编号 | 操作和竞态 | 通过条件 |
| --- | --- | --- |
| C08 网格默认打开 | 从未挂过源码编辑器的 FileTab 直接编辑网格，⌘Z／⌘⇧Z；随后切到源码编辑再回网格撤销。 | 一份文档和一份原生 Undo 历史，网格与 TextKit 的交错事务按实际先后撤销；不能靠“后台藏一个 NSTextView”模拟。 |
| C09 单格源范围 | 在排序／过滤后编辑重复值、最后一列空格、嵌套引号／多行字段、中文及 surrogate 边界、含逗号／引号的值。 | 精确替换被选物理字段及最少必要 quote，不修改其它字段、换行／行序；修改后解析索引与 UI 显示同一 revision。 |
| C10 批量事务 | 2×2／不规则矩形粘贴、Tab／Shift-Tab、插入／删除行、多格部分非法／超 32 MiB、用户 Undo 中再次粘贴、源区间失效。 | 作为一次 Undo 原子变化，失败不会留下部分新行；重做／撤销回原始文件后 dirty=false，原先显示映射失效后不误写旧行。 |
| C11 字节往返 | UTF-8 BOM／UTF-16／GBK／Shift-JIS／Latin-1、混合 CR/LF/CRLF、不同引号写法、前导 `=/+/-/@` 字段、Unicode 规范等价字符。 | 先证明未改的旧全文能按原编码**逐字节 round-trip**；成功修改只产生目标字段字节 diff，其余原样。非往返／不安全编码拒绝网格写入并保留源码编辑能力。 |
| C12 保存冲突 | 源码失焦自动保存／⌘S／后台自动刷新、两个窗口同时改单元格、外部同大小同 mtime 替换、存盘期间再次输入、写入失败／断线／重连。 | `FileTab.save` 一条队列和已接受版本负责结果；冲突拒绝旧稿覆盖，任何失败保留可继续编辑的未存正文和可见错误，不新建 CSV 保存器。 |
| C13 恢复目标 | 表格编辑后改名／移动／删除、选中不存在记录、切不同 SSH 主机、另窗打开同名本机文件、关闭否决、App 会话重启及 Git Diff。 | 没有错机／错行／错路径写入；完成保存后磁盘、Git 和源码视图一致，未存草稿不会被旧解析任务或生命周期回调丢弃。 |
| C14 性能 | 100000 行和宽字段下单格编辑、Unicode/CRLF 源范围重建、多次 Undo、100 次切源码／网格、同版本快速 100 次输入。 | 不因一次字段编辑全文重新序列化 CSV 或同步重扫／重排整个 UI；测量主线程延迟、文本额外复制量、内存和稳定索引更新。 |

必须交叉 C08×C10、C09×C11、C10×C14、C12×C13、C11×C12 和 C13×R10；
**保存检查与最终写入间的外部替换**需借受控后端屏障实际测试。
现有 `write(ifUnchanged:)` 非原子 CAS 的平台限制不能靠循环重试或文件级假锁掩盖。
