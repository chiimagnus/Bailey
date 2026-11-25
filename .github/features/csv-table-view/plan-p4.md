# P4｜专业 CSV 数据编辑

在 [P3 原生网格](plan-p3.md) 上交付真实列结构编辑、完整长／多行字段编辑、批量修改与只读数值检查。
所有编辑直接进入 P2 的同一原文事务和保存保护，不新增表格正文、Undo 历史或 CSV 保存器。

## 方案与依据

当前 `DelimitedTableMutation.Change` 只有 cells、paste、insertRows、deleteRows；
`prepare` 从 `DelimitedTableIndex.Field.source`（UTF-16 原文区间）产生 Replacement，
执行原编码及 32 MiB 预检。调用链已经存在：

- `DelimitedGrid` 的选区／原生 field editor → `physicalCell`／`apply` →
  `FileTab.submitDelimitedEdit` 或 `commitDelimitedEditing` →
  `enqueueDelimitedEdit` → `applyAcceptedDelimitedEdit` →
  `DelimitedTableMutation.prepare` → `applyDocumentReplacements`。
  最终替换在同一 NSTextStorage 内完成，先验证旧区间，再以倒序执行，注册同一原生 Undo，
  更新编辑代次、脏状态和重新索引；原有 FileTab.save → TextFileEncoding → WorkspaceBackend
  仍负责磁盘发布、冲突比较及显式覆盖。
- `DelimitedTableIndex.Record` 已有 source、fieldCount、lineEndingLength 和 physicalLine；
  原始字段区间包含既有引号拼写，字段值只在需要编辑／读取时解码。
  `DelimitedTablePresentation.evaluate/find/copy` 由展示记录索引映射物理记录，
  不可用视觉行号或表头标题直接决定写入目标。
- `DelimitedGrid.beginEditing` 取得完整值，但普通 NSTextField 为单行，
  显示路径限 4096 码元；当前 `DelimitedTableControls.perform(.replace)` 无操作，
  `WorkspaceWindowModel.canReplace` 排除了表格与 HTML 预览，
  查找只返回含匹配的可见数据单元格。必须在这些真实入口扩展能力，不引入并行全局命令。

P3 的选择、尺寸及原生控件身份是此阶段的前提。
结构修改和批量编辑沿既有事务捕获文件版本、分隔符、物理目标和展示代次；
在异步准备完成后再次检查正文身份和旧源区间，任何失败都不执行部分替换。
只读统计不进入事务。前两阶段的 Gate、延期与严格非协作 CAS 边界保持原结论，
本阶段不得宣称已有更强的跨文件系统原子性。

## 任务

<a id="p4-t1"></a>
### P4-T1 插入、删除、移动列与直接重命名表头

- **位置**：`DelimitedGrid.columnMenu/installColumns`、`DelimitedHeader`、
  `DelimitedTableControls.accept`、`DelimitedTableMutation.Change/prepare`、
  `DelimitedTableIndex.fields(in:)`、`FileTab.enqueueDelimitedEdit/applyAcceptedDelimitedEdit`。
- **交互**：列头右键插入左侧／右侧一列、删除该列或明确选中的整列集合、向左／右移动或移动到指定列。
  列移动是明确的原文变更，不启用 NSTableView 仅改变外观的列拖动排序。
  在首行作为表头时，双击列标题或右键「重命名列」进入原生文本编辑，
  修改物理记录 0 的指定字段；允许空／重复名称，列身份始终是索引而非名称。
  重命名后保持原列选择，不将不可见的表头记录当作待恢复的数据格。
  无表头时显示的列号不可重命名；空文件先用既有插入行入口建立记录，
  不造独立列 schema。禁止删除到零列；超出显示上限的截断表禁止结构操作，
  不将不可见列当作已删除。
- **写入**：结构操作作用于所有物理记录，包括首行、筛选隐藏记录和未滚到的行。
  对每条记录从已索引字段的原始 token 取得受影响的最小连续区间，
  插入必要分隔符／空字段，删除正确相邻分隔符，移动原始 token 而非先解码再重编码所有字段；
  保留行终止符、原引用样式、空白、未受影响字段及记录顺序。
  删除到单列且为空字段时沿已有空记录／CR-LF 合并边界的处理保留逻辑记录；
  明确不可表示的结果拒绝，不自动猜修。
  用本次已确认的分隔符重新解析候选原文，检查字段数、记录数及上限
  （4096 可显示列、一百万字段、32 MiB 原编码），核对准备结果的不重叠源区间。
  结构编辑不能让当前标签因再次自动探测而改变分隔符解释；
  删除至单列或重开后无法自动确定分隔符时，沿既有显式选择入口恢复相同解释，
  不往文件写入额外元数据，不创建新的 CSV 读写引擎。
  一次操作一次原文事务和 Undo；失败保留原文、原设置和选区。
- **展示状态**：在结构事务成功后、相应新展示映射发布前，用该操作的旧→新索引映射
  同步 sort、filters、手动列宽及待恢复选区，
  删除被移除列的设置；同名列和空表头不作为映射依据。
  普通单格／表头重命名保持列身份，移动后排序／筛选仍跟原字段。
  Undo／Redo、源文任意改写、分隔符切换或外部刷新无法证明旧列身份时，
  清除失效的列设置／选择而非套用旧列号；展示状态不单建 Undo。
  任何结构操作的确认绑定当前快照与明确的列范围；延迟确认时若目标已改变，重新选择。
- **验证**：Red→Green 覆盖头／中／尾插列、删单／多列、任意移动、
  空／重名／无表头、只有表头、一列空记录、末尾无换行、引用内 CRLF、
  重复字段文本、分号／TSV、混合编码、筛选隐藏行、全表最大容量及操作失败。
  断言实际每条记录的 raw token、行尾和保存后磁盘字节；
  重新打开、源码切换、Undo／Redo、同路径外部替换、两窗及真实 Windows SSH 下结果一致。
  明确结构操作范围和原生菜单／编辑焦点，旧排序／重命名入口不得竞争。

<a id="p4-t2"></a>
### P4-T2 完整长字段和原生多行编辑

- **位置**：`DelimitedGrid.CellEdit/beginEditing/finishEditing/cancelEditing/
  controlTextDidEndEditing`、`DelimitedNativeTable.keyDown`、
  `FileTab.beginDelimitedEditing/commitDelimitedEditing/endDelimitedEditing`、
  `DelimitedTableIndex.Field.value`；复用原生 field editor 和既有 Finder／Dock 保存保护。
- **交互**：普通短字段继续双击／Return 在格内编辑；含换行或显示截断的字段直接进入
  完整文本编辑，也可由单元格右键「编辑完整字段」主动打开。
  表格显示有界摘要并明确截断／多行提示；完整查看和复制读取真实字段，不能复制摘要中的省略号。
  编辑器用原生多行 NSTextView（当前单元格锚定的可关闭原生 popover），
  原文换行可见、可选择，Return 输入换行，⌘Return／确认按钮提交，Esc 取消；
  输入法组合期间按键先交给 IME，不吞候选确认或全局快捷键。
  短字段与多行编辑互斥，仅一处活动 CellEdit、同一文件级编辑事务，
  popover 中只暂存当前字段输入，不创建第二份文档／文件 Undo。
  可用只读完整查看，但禁用修改；超长字段不截断输入后提交。
- **生命周期**：复用原有 `finishEditing` 的普通失焦／保存／卸载提交路径，
  统一字段确认、取消及在途编辑等待；若活动组合输入无法可靠结束，保留草稿并否决关闭／保存，
  不冒充成功。普通失焦不抢走其它 Dock 或窗口的第一响应者。
  原生字段编辑器和 popover 验证焦点转移后接入，同任务清理旧的重复终结路径。
  提交使用完整逻辑字符串及现有字段 escape；不经任意换行正规化或 SwiftUI 单行 TextField。
  先用真实 NSTextView 验证加载、选择、局部编辑和返回值对 CR/LF/CRLF 的保留；
  若原生输入路径会正规化，必须保住未修改换行的原拼写后才启用该路径，不能用重写整字段掩盖。
  原值不变时不生成 Undo 或脏状态，真实修改按原编码和容量预检。
- **验证**：长字段 4095／4096／4097 UTF-16、超长及容量边界、emoji／代理对、组合字符、
  CR／LF／CRLF、引号和分隔符；实际选择／复制原值、多行插入和删除、中文／英文 IME、
  Return／⌘Return／Esc、Tab／Shift-Tab、Undo／Redo、失焦／关闭／并排／切换主题与窄 Dock。
  使用既有 `testActiveNativeGridFieldIsIncludedInSaveAndProjectClose`、
  `testAcceptedGridEditsSurviveImmediateUnmountAndSave` 与
  `testMountedCSVGridRetainsKeyboardFocusAcrossEditUndoRedo` 的真实宿主链；
  额外证明取消不写盘、未变换行仍逐字节相等，输入期间的原始单元格没有被旧索引误改。

<a id="p4-t3"></a>
### P4-T3 批量填充、清空与原生查找替换

- **位置**：`DelimitedGrid.recordMenu/apply/paste`、`DelimitedNativeTable`、
  `DelimitedTablePresentation.Selection/find`、`DelimitedTableMutation.prepare`、
  `CSVTableView.overlay`、`DelimitedTableControls.perform`、
  `WorkspaceWindowModel.focusedPreviewFile/canReplace/performFindAction` 与
  `BaileyApp.swift` 既有 Find 主菜单。
- **交互与范围**：选区右键提供「填充…」「清空内容」，
  支持非连续、矩形、整行和整列；只作用选择的可见数据格，重叠范围只处理一次，
  不删除记录／列，不填充选区包围盒中的未选格，也不隐式作用隐藏记录或表头。
  Delete／Backspace 在实际网格第一响应者且没有活动文本输入时清空选区；
  在 field editor、查找框、终端等位置仍归原生控件。
  使用现有查找浮层扩展替换，不添加常驻工具栏。
  系统 ⌥⌘F 打开 Find and Replace；可查看当前命中、替换当前匹配或全部，
  明确「当前选区／可见数据／全部数据记录」范围（不含作为表头的记录 0）。
  默认可见数据，全部包含被过滤隐藏的数据，仅显式选择才允许。
  当前替换只在可导航的真实匹配格上执行，不悄悄清除过滤或改隐藏格；
  全部替换显示命中单元格及实际出现次数、受影响范围并确认。
- **匹配语义**：沿用 `find` 的字面字符串、caseInsensitive／diacriticInsensitive 语义，
  由同一匹配实现定位解码后字段中的实际范围；匹配可含字段内换行，
  不能跨字段边界匹配分隔符或表头，空查询禁止替换。
  明确「替换当前」为当前格中明确定位的一次命中；进入格时取首个，
  替换后按新代次从已替换范围之后继续，必要时进入下一可见匹配格。
  「替换全部」遍历作用范围内全部不重叠命中，不递归匹配刚写入的结果；替换为空字符串合法。
  普通查找仍按格导航；替换模式显示当前格的具体命中及总出现次数，
  隐藏范围只用于明确选择的全量替换预检。
  不把原现有匹配单元格数量误当出现次数，不另加正则引擎。
- **写入与状态**：捕获选区和展示→物理映射及查询／替换意图，
  以已有不可变快照在后台遍历区间、准备去重后的 Replacement；
  复用 `prepare` 的 escape、原值校验、编码／容量预检及单一 FileTab 提交。
  大选区不能在 MainActor 构造百万字典；按需要合并同一记录连续修改的源区间，
  保留未修改 raw token 与终止符。测量真实 `applyDocumentReplacements` 和 Undo 注册成本；
  若大量小区间导致主线程长停顿，在该所有者处减少重复文本存储操作，
  不拆成多个可见部分事务，也不在后台直接修改 NSTextStorage。
  一次用户批量动作一次原文提交与 Undo；无变化不置脏。
  替换确认与异步查找、筛选、选区和原文代次绑定；过期结果不得直接覆盖新内容。
  表格的 `canReplace` 与各写入动作以实际 `FileTab.canEditDelimited(snapshot)`、
  pending edit 与当前有效预览目标为依据；菜单仅读取当前 FileTab 的派生编辑能力，
  执行动作再次核对实际快照，不复制可写状态或遍历视图判定业务许可。
  预览本身只读时仍可 Find，不启用写入。
  保留源码／Diff 替换及 HTML 仅查找路由，不新增全局快捷键分发器。
- **验证**：单格、百万字段边界内的整表／整列、非连续重叠选区、隐藏行、重复匹配、
  无命中、空替换、跨字段不匹配、大小写／变音符号／Unicode 与 quoted 换行，
  多格粘贴前后、非法编码、容量预检失败、旧查询／旧映射、取消及保存中再次编辑。
  对照每次操作的实际磁盘差异、撤销回原字节及重做；没有任何选区外字段被修改。
  真实 App 验证 ⌘F／⌥⌘F、焦点及当前窗口菜单启用状态、查找结果与修改范围；
  修改后统计与查找重新绑定最新版本，不用旧命中坐标。

<a id="p4-t4"></a>
### P4-T4 按需列统计与空值检查

- **位置**：`DelimitedTablePresentation` 的现有不可变 source/index/rows 读取链、
  `DelimitedGrid.columnMenu/recordMenu`、`CSVTableView` 现有按需浮层和
  `DelimitedTableControls`。复用区间选区和物理映射，不增加可写数值模型或持久缓存。
- **交互**：列头／选区右键「统计…」打开轻量原生浮层，
  默认当前选中格或该列可见数据，明确可切到该列全部数据记录（排除表头）。
  多列选区按列列出结果，不把不同量纲的列无条件相加。
  显示范围、总字段数、空字段数、有效数值数、非数值／越界数以及最小、最大、合计、平均。
  提供「查找空值」定位当前范围中可见的空字段，沿既有匹配导航，
  通过显式空字段谓词复用导航，不能把空查询传给现有 find（空查询无结果）。
  过滤外命中只在明确清除过滤后导航；仅空值检查不写文件。
- **数字语义**：原始字段仍是字符串。空值为解码后长度为零（含 quoted 空串），
  空白字符串与缺失／损坏字段不当作数值零；非均匀／无效表只统计已明确索引的有效字段，
  显示「部分数据」及实际范围，不声称整表完整。
  对仅用于统计的副本，允许去掉外围空白并按与 Locale 无关的十进制字面规则
  解析有限数值（符号、小数、科学计数法），前导零保留在原文；
  NaN、无穷、溢出／不可表示的非零下溢、千位分组、日期、公式字符串等作为非数值／越界。
  不自行把逗号当小数点或执行公式；采用有明确精度的 Double 近似统计，
  用稳定求和／均值算法并明确溢出不可表示，不显示伪造零、NaN 或无限数值；
  无有效数值时 min/max/sum/mean 显示无值。
- **性能与生命周期**：按需从不可变快照读取完整逻辑字段，在后台一次遍历计算有界聚合，
  不布局全表、不为统计保留全部字符串或缓存全列数值。
  选区、范围、文本编辑代次、分隔符、筛选和窗口身份变化时废弃旧结果；
  关闭浮层／卸载取消任务，不把过期数值覆盖新选区。
  只读及无法安全往返编码的可读表仍可统计，前后原文件、Undo、dirty 和保存基线相同。
- **验证**：空、全空、空白、0／负零、负数、前导零、科学计数、极大／极小及异常数、
  精度敏感累加、非数值混合、不同 locale、同值不同拼写、无表头、
  过滤／排序／非连续选区、部分坏表、十万行与百万字段边界，
  以独立预期统计（精度敏感数据用高精度参考值、声明误差判据）及实际导航字段验证。取消／编辑／重挂载后无过期结果，
  全过程源码和磁盘哈希不变，关闭后释放资源。

每项任务在同一变更中更新 `docs/features/editor.md` 的相应用户操作与约束；
新增本地化写入现有 Editor／Interface 字符串表，命令与启用状态沿已有主菜单。
若影响测试职责或文档索引，在现有 `docs/testing.md` 对应入口同步，不新增专门手册。

## 阶段验收

[P2 的 C08–C14](plan-p2.md)、[P3 的 C15–C17](plan-p3.md) 及
[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification) 按受影响的真实入口回归；
环境、延期及所有权沿 [公共验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)
和 [验收归属](../file-viewer-routing/plan-p1.md#acceptance-ownership)，不复制既有矩阵。

| 编号 | 专项条件 | 最终结果 |
| --- | --- | --- |
| C18 结构编辑 | 插入、删除、移动和重命名；首／中／末、1→2／2→1／拒绝 1→0、空／重复／无表头、筛选隐藏行、引号内换行及终止符混合、4096 列／百万字段／32 MiB 两侧。 | 全部物理记录字段结构正确；raw token 保真、表头定位正确、设置重映射或安全清除、一次 Undo，失败无部分结果。 |
| C19 真实字段输入 | 短／超长／多行／Unicode、剪贴板、中文 IME marked text、编辑／取消／提交／关闭、只读、极窄 Dock、并排、两窗、主题切换和重新索引。 | 完整值而非摘要进入原文，焦点和组合输入正确、在途保存／关闭不丢稿，原始 CR/LF/CRLF 和编码按实际字节验证。 |
| C20 批量事务 | 可见／选区／全部范围，非连续与重叠、排序筛选、重复出现、空查询／替换、公式状字面量、编码失败／超限、异步结果乱序、编辑与保存交叉。 | 显示范围和实际修改严格一致；未选格与隐藏行不被误改，全部修改原子生效、唯一 Undo／Redo、磁盘准确。 |
| C21 数值与空值 | 各类空／非数值、科学计数、极端浮点、locale、数值边界、部分坏表、多列不同量纲、筛选和最新代次、长会话取消。 | 统计的样本范围、分类、数值和定位准确，数值异常明确标记，原字节／Undo／dirty 不变，关闭释放。 |
| C22 数据安全与恢复 | 本机／获授权 Windows Tailscale，读取／写入权限错误、同长同 mtime 外部替换、两窗同文件、旧确认、保存时继续编辑、移动／改名、断线／重连、关闭否决及 Git Diff。 | 沿 P2 共用保护，不错文件／列／行或旧版本，不部分提交、不丢草稿、不回退本机；验证磁盘原字节、Git 与重开。 |
| C23 规模和事务性能 | 100000 行、2501／4096 列、百万字段及 32 MiB 内外，100 次单格／结构／批量操作与 Undo、取消旧解析／统计及切换源文。 | 实际首屏、输入、主线程提交、内存、峰值和关闭恢复可复核；原生虚拟化、取消、原文一致，避免全表可写副本和逐格 View。 |

覆盖 C18×C01/C03/C17/C22/C23、C19×C04/C12/C15/C22、C20×C06/C10/C17/C22/C23、
C21×C06/C16/C17/C20/C23，及新发现的真实失败组合；
每个适用条件均验证，组合规模过大时先跑完单项与极端，再扩大两两及高后果组合。
记录实际环境、前置条件、操作、完整退出、失败／跳过、最终磁盘／原生像素和资源证据；
不可安全完成项逐项写明原因、影响、替代证据、补验方式和 Gate 限制。

宿主 XCTest 优先复用 `DelimitedTableIndexTests`、`DelimitedTablePresentationTests`、
`FileTabPersistenceTests`、`WindowOwnershipIntegrationTests`、`NativePaneRetentionIntegrationTests`、
`MarkdownResourceScopeTests`／现有获授权 SSH 用例；整合原生保存比较与真实 Git 差异。
完整 App 复用 `CSVPreviewUITests`，仅新增宿主不能证明的表头／行号、系统菜单、
多行编辑、批量操作、统计与两窗的实际用户路径。
阶段宿主命令：

```sh
make test:DelimitedTableIndexTests,DelimitedTablePresentationTests,FileTabPersistenceTests
make test:WindowOwnershipIntegrationTests,NativePaneRetentionIntegrationTests,MarkdownResourceScopeTests
make build
make build:dev
make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests
```

开发先运行对应定点方法，真实远端专项使用公共验收环境中的 SSH 参数；
正式阶段整合 `make test`。复用同一源码及环境的已有证据，不每任务重复全量。
用户此前已暂缓 GUI／全量测试；只在恢复授权和图形会话独占后运行，
未测不计为通过，不伪造 P1–P4 Gate。
