# P4｜专业 CSV 数据编辑

在 [P3](plan-p3.md) 的原生表格上完成列结构、长字段和批量编辑。
所有修改直接进入 P2 的同一原文事务，不新增可写表格模型、保存器或 Undo 历史。

## 源码依据与事务边界

`DelimitedGrid` 的操作经 `FileTab.submitDelimitedEdit/commitDelimitedEditing`、
`enqueueDelimitedEdit → applyAcceptedDelimitedEdit → DelimitedTableMutation.prepare → applyDocumentReplacements`。
Mutation 在后台按 UTF-16 原文区间准备替换、检查原编码和容量；
FileTab 在 MainActor 验证原值、倒序替换同一 NSTextStorage、注册逆变换 Undo。
磁盘仍由 FileTab.save、TextFileEncoding 和 WorkspaceBackend 的条件发布负责，不增加 CSV 专用保存路径。

`canEditDelimited` 是新动作入口，`matchesDelimitedDocument` 验证已经接受的草稿与正文身份。
后者有意不依赖连接代次：断线、离开网格或已接受后的编码发布不能凭空丢掉草稿。
保留无效表、歧义分隔符、原字节往返、旧源区间、真实连接／目标身份与条件保存保护；
不把显示配置、菜单许可和保存许可叠成重复围栏，不把非协作写入宣称为严格 CAS。

P3-T2 完成有效解析／投影身份及固定行号与数据格的动作映射后才进入本阶段。
延续 [CSV HTML 原型](../prototype.html?format=csv) 的紧凑网格、原位编辑和右上角按需浮层，
复用 [P3 的 App 主题接入及 C15a–C15f 验收](plan-p3.md)，不新增独立调色板。
不复制原型的解析、全量 DOM 重绘、JavaScript 历史或模拟保存。
各任务按 [最小实现审查](../../../docs/testing.md#完成标准) 清理自己替换的旧代码与测试，
不以最后一次 task 兜底。不新增抽象接口、持久列 schema、事务队列或数据类型推断。

## 任务

<a id="p4-t1"></a>
### P4-T1 插入、删除、移动列与直接重命名表头

- **位置**：`DelimitedGrid.columnMenu/installColumns`、`DelimitedHeader`、`DelimitedTableControls.accept`、
  `DelimitedTableMutation.Change/prepare`、`DelimitedTableIndex.fields(in:)`、FileTab 的既有编辑事务。
- **操作**：列头菜单插入左／右列，删除该列或明确选择的整列集合，向左／右移动或移到指定位置。
  结构修改作用于全部物理记录（含表头及隐藏行），不是 NSTableView 的展示重排；操作名称明确其范围。
  禁止删除至零列，超出 4096 显示列的表不接受列结构编辑；不误删不可见的列。
  双击编辑记录 0 的完整字段，空名称、重复名称合法；
  合成列号不写入文件。空表先沿既有插入行入口建立记录。
- **原文修改**：以 Field.source 原始 token 重组各受影响记录的最小连续正文区间，保留未改 token、引号、
  空白及原行终止符；不重新序列化整表、不针对同一零长度边界生成有歧义的重复 Replacement。
  删除至单列为空时复用 Mutation 已有 escape／joinsLineEndings 处理，避免末记录消失或 CR／LF 合并。
  后台只对结构变换后的候选文本使用已确认分隔符解析一次，
  核对预期记录数、字段数、合法性及既有解析容量；统一经过 prepare 的编码／字节上限检查。
  区分 32 MiB 编码文件上限与索引自身 UTF-16 码元上限，不另造一套容量限制。
  最终仍由 applyDocumentReplacements 检查并提交一次，失败不留下部分修改或独立 Undo。
- **分隔符与列身份**：复用 P3-T2 已确定的网格分隔符保留规则，特别验证列删除至单列。
  重新打开后自动识别，无法消歧时保留原文写入保护，不提供手工选择或额外提示。
  已知列结构变化用一次旧→新索引映射同步 sort、filters、人工列宽及实际选区，
  删除失效设置；普通单格／行编辑及重命名不清空有效设置。
  源码任意修改、Undo／Redo 或外部刷新不能证明列身份时清除失效的按列位置设置，
  不按名称猜测、不引入列 ID 或第二套展示历史。
- **表头编辑前置**：表头与所有数据格复用唯一原位多行编辑会话；
  复用 FileTab.begin／commit／endDelimitedEditing 与现有保存等待入口。
  不把长表头截断后编辑，不先造独立重命名窗口再于 T2 重写。
  T1 首次交付该会话时就完成 T2 所列的完整内容、IME、确认／取消、失败输入保留与保存关闭保护；
  T2 只扩展数据格入口，不把表头草稿保护延期。
  头字段不进入普通数据选格，成功后保留被重命名列的有效选择。
- **本任务清理**：删除仅测试调用的 `FileTab.editDelimited` 旁路（绕过 hasPendingDelimitedEdit），
  将相关宿主迁到真实 submitDelimitedEdit／在途任务完成结果；
  纯 Mutation 错误用 prepare 的实际测试入口验证。
  删除仅转发到 submitDelimitedEdit 的 `DelimitedGrid.apply`，改为真实提交入口；
  修改记录、列及表头共用已有原文替换，不保留旧路径或并行事务。
  beginEditing、paste 等与 FileTab.beginDelimitedEditing／submitDelimitedEdit 重复的
  canEditDelimited、hasPendingDelimitedEdit 准入判断收敛到 FileTab；
  视图仅保留真实可见许可、目标映射及原生控件前提，先准入再开始实际输入，避免失败后转移焦点。
  prepare 独立输入验证、接受后正文身份和最终原值校验对应不同真实边界，不合并成错误的连接门禁。
- **验收**：首／中／尾插删移动、1→2／2→1／拒绝 1→0、空表／仅表头、重复／空／多行表头、
  隐藏行、空末记录、原引号及混合 CR／LF／CRLF、添加其他分隔符、Undo 后新操作、过期菜单目标、
  4096 列／百万字段／32 MiB 边界。核对完整原文字节、保存、重开和唯一 Undo。
  复用 DelimitedTableIndexTests、DelimitedTablePresentationTests、FileTabPersistenceTests，
  包括原字节验证、断线后已接受输入、重叠及不兼容编码发布；并排、双窗、移动文件、
  获授权远端沿 C22 执行真实写入与冲突验证。

<a id="p4-t2"></a>
### P4-T2 完整长字段和原生多行编辑

- **位置**：`DelimitedGrid.CellEdit/beginField/layoutEditor/finishEditing/cancelEditing/textDidEndEditing`、
  `DelimitedNativeTable.keyDown`、`DelimitedTableIndex.Field.value`。
- **操作**：双击／Return 在实际单元格启动同一个原生 NSScrollView＋NSTextView，表头也复用它。
  参考 Handsontable 的 TextEditor.refreshDimensions：从实际单元格位置扩展输入框，最多占用表格视口；
  超出时内部滚动，不逐键调整整列、重排其他记录或重建表格。不存在长字段弹窗或第二套编辑器。
  只读时仍可原位选择、复制完整值。主题、字号、滚动及列宽变化更新当前输入框，不重设原文、焦点或 IME。
  Return 提交、Tab／Shift-Tab 提交并导航、Option-Return 插入换行、Esc 取消，marked text 优先交给系统。
  单一活动编辑会话持有局部原生 Undo，文档事务仍只进入原文 Undo。
- **内容与生命周期**：读取解码后的真实字段，而非 `Field.value(limit:)` 生成的摘要。
  先验证 NSTextView 加载、局部编辑、确认能保留 CR／LF／CRLF 及 Unicode；
  若有真实换行正规化再在当前字段输入边界修正，不预建通用换行差异引擎。
  未修改不注册 Undo 或置脏。确认、普通失焦、保存、卸载、关闭、移动等统一沿 finishEditing
  和 FileTab.finishPendingDelimitedEdit，不能仅移除输入框即认为提交成功。
  若 IME 无法完成，则保留输入、阻止该次关闭或保存；不主动抢其它 Dock／窗口焦点。
- **失败恢复**：编辑会话结束后异步 prepare，
  编码／容量或原文身份校验失败时用户输入可能只剩通用错误，原始提议值不再可恢复。
  在已接受的文件级字段意图中保留这一个未完成值，直到成功或用户明确取消；
  离开网格也可重新查看、复制或重试，旧物理坐标失效时不盲写。
  失败后 hasPendingDelimitedEdit／保存关闭保护仍须反映未处理草稿；
  明确重试／取消同一个提议，而不是因 pending 恒真使它无法再次提交或让保存无限等待。
  不为此添加新文档副本、历史草稿库、持久队列或自动重试；无效粘贴仍利用已有剪贴板反馈。
- **本任务清理**：删除旧的短字段／长字段分流和 Popover、共享 field editor 外观恢复路径；
  所有字段共用唯一原位编辑会话的完成、取消和失败归属，
  不增加重复编码或容量预检。保留真实输入、Undo、连接变化和条件保存保护。
- **验收**：4095／4096／4097 UTF-16、极长字段、仅列宽裁切、emoji／组合字符、
  CR／LF／CRLF、引用与分隔符、真实中文／英文 IME、Return／Option-Return／Esc、Tab／Shift-Tab，
  查看／复制／局部编辑、只读、窄 Dock、换主题、切源码、保存／关闭／移动、重挂载。
  失败保留原文和用户提议；取消不写入、未修改换行保持原字节。
  复用 `testActiveNativeGridFieldIsIncludedInSaveAndProjectClose`、
  `testAcceptedGridEditsSurviveImmediateUnmountAndSave`、`testMountedCSVGridRetainsKeyboardFocusAcrossEditUndoRedo`
  及 NativeEditorCompositionTests；检查原生第一响应者和一次文件 Undo。

<a id="p4-t3"></a>
### P4-T3 批量填充、清空与原生查找替换

- **位置**：`DelimitedGrid.recordMenu/paste`、`DelimitedNativeTable`、`DelimitedTablePresentation.Selection/find`、
  `DelimitedTableMutation.prepare`、`CSVTableView.overlay`、`DelimitedTableControls.perform`、
  `WorkspaceWindowModel.focusedPreviewFile/canReplace/performFindAction`、BaileyApp 既有 Find 菜单。
- **操作与范围**：仅多格选区提供右键批量填充同一个值；实际选中的可见格重叠只处理一次、空洞不写入、不删行列。
  ⌘A 选择全部可见数据格；Delete／Forward Delete 只在网格第一响应者时清空，
  不另设右键清空入口；field editor、查找框和其它控件遵循原生输入。
  扩展现有 ⌘F 浮层及系统 ⌥⌘F Find and Replace，默认可见数据，可选当前选区或全部数据记录。
  全部包含隐藏行但不含表头；超出显示上限时明确标示仅当前显示列，不暗中替换隐藏列。
  选择「当前选区」时固定此次范围；showMatch 随查找移动 caret 不得把替换范围缩为当前命中格。
  用户主动重选范围、正文／投影失效时更新或废弃旧范围；查找内部导航不改范围。展示匹配数及范围，用户明确点击替换／全部替换即为操作确认，
  不再叠加同义确认框。单次替换只导航真实可见命中，不自动清除筛选。
- **匹配**：沿用 find 的字面字符串、caseInsensitive／diacriticInsensitive，
  对解码字段内的实际不重叠匹配使用同一个实现；不跨字段或表头，空查询禁用替换，空替换合法。
  现有 find 返回匹配格而非出现次数；普通查找继续按格导航，替换时计数实际命中，
  单次替换定位当前格的一个命中并从替换区间之后继续；
  全部替换不递归处理刚插入的字符串，不常驻全表出现位置数组。
- **事务**：复用 P3 的区间选区及当前快照，在后台遍历真实记录和字段，生成一组 Replacement。
  批量填充／清空／粘贴和替换共用已有字段转义与准备链；
  copy 的 TSV 引用规则与 Mutation.escape 中确实重复的转义逻辑合并在现有所有者，
  保留 TSV 最后空记录及原文件分隔符的语义差异。
  不在 MainActor 构造百万格字典；大批量按实际受影响记录合并连续替换，保留未选 token。
  测量真实 applyDocumentReplacements 和逆变换 Undo 成本，再针对实测主线程瓶颈精简。
  不在后台修改 NSTextStorage、不拆成多个可见部分事务、不建批处理引擎。
  无变化不置脏，每次用户动作一次原文提交与 Undo。
- **权限与状态**：P3 当前有效解析快照和投影提供真实输入，FileTab.canEditDelimited 与 pending edit
  派生菜单启用；执行时核对现有快照、范围、查询及操作意图，不复制可写标志或遍历视图决定业务许可。
  复用现有 SearchRequest 与实际任务取消，过期结果不能进入事务。
  只读仍可 Find，源码、Diff 和 HTML 既有路由保持原行为。
- **本任务清理**：删除 `DelimitedTableControls.perform(.replace)` 的空分支及 canReplace 排除 CSV 的旧路径。
  不保留旧版查找／替换浮层；在现有匹配和 Mutation 准备链内收敛实际重复扫描、转义和批量逐格字典构造，
  用验证证明替换的旧路径不再被调用。
- **验收**：单格／整表／整列、非连续重叠、未选空洞、隐藏行、同格多处匹配、无匹配、
  大小写／变音符号／组合字符／quoted 换行、空替换、超过显示列／容量、选择中导航、
  旧查询与旧投影、输入框 Delete、取消及在途保存。核对原字节差异、一次 Undo／Redo、
  保存重开；复用 CSVPreviewUITests、宿主 FileTabPersistenceTests 和
  `HTMLFilePreviewTests.testFindMenuTargetsReadOnlyHTMLPreviewRatherThanItsSource`，
  验证系统 Find 菜单目标、只读和跨窗口无回归。

每任务同时更新 docs/features/editor.md；新增本地化沿 Editor／Interface 字符串表，
跨功能规则仅在原 owner 更新。提交前按 AGENTS.md 列明实际删除的旧代码及必须保留的边界，
没有证据表明冗余的保护不删除。

## 阶段验收

[P1 C01–C07](plan-p1.md)、[P2 C08–C14](plan-p2.md)、[P3 C15–C17](plan-p3.md)、
[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification) 按受影响路径回归；
[环境](../file-viewer-routing/plan-p1.md#acceptance-environment) 与
[归属](../file-viewer-routing/plan-p1.md#acceptance-ownership) 沿现有规则，不复制公共矩阵。

| 编号 | 专项条件 | 通过标准 |
| --- | --- | --- |
| C18 结构 | 首／中／末列、删除至一列、空／重复／多行表头、隐藏行、分隔符改判、源码／Undo 后身份、列及字段／字节上限 | 全部物理记录结构正确，raw token、行尾及原文保真；设置正确重映射或清除；一次 Undo |
| C19 输入 | 空／短／4095／4096／4097 UTF-16 及文本上限附近的长字段、多行／Unicode、真实 IME、只读、最窄／最矮 Dock、原生选择／粘贴、明暗及同外观换主题、取消／确认／关闭／卸载／重挂载、编码或准备失败 | 原始值而非摘要进入原文；失败不丢稿，原生焦点、marked text、换行及实际字节正确 |
| C20 批量 | 三种范围、空／单格／整表、重叠／空洞、隐藏行、同格多匹配、空查询／替换、Unicode／quoted 换行、快速连续替换及重选、旧结果、编码／容量失败、保存交叉；替换浮层打开／查询在途换主题 | 范围、数量和实际改动一致；无部分提交、一次 Undo／Redo、原文件准确 |
| C22 保存与恢复 | 本机／授权 Windows Tailscale、权限失败、同长同 mtime 改写、双窗、旧确认、保存中编辑、编码发布、移动／改名、断线／重连、关闭否决、Git Diff | 继续 P2 的实际版本保护，已接受输入和失败提议保留；不回退本机、不误写目标；核对磁盘、Git 和重开 |
| C23 性能 | 100000 行、2501／4095／4096／4097 列、999999／1000000／1000001 字段、32 MiB 前／等于／后（字节／码元分别验证），100 次单格／结构／批量及 Undo、换主题和取消／重挂载 | 首屏、滚动、准备／主线程提交、峰值及关闭后资源可复核；无逐格 View／可写全表副本／重复事务 |

交叉 C18×C01/C02/C03/C15/C17/C22/C23、C19×C04/C11/C12/C15/C22、
C20×C06/C10/C15/C17/C22/C23；
并覆盖新发现的真实故障组合。
C15 的主题覆盖不得只测试 P3 原位单行：P4 的表头重命名、长字段原位编辑、失败草稿、
替换浮层均在已挂载状态按 C15a–C15f 核对配色、焦点、数据和对象身份。
尤其验证中文组合期换色、未提交字段换色后失焦、后台批量准备期间换色后立即切文件、
外部冲突比较与双窗并排、主题改变后 Undo／Redo 和保存。
纯换色不得提交任何编辑、改变选区／替换范围或 dirty、Undo／磁盘版本。
所有 C18–C20、C22–C23 适用取值及极值分别核销，再执行可承受的完整组合及两两、多因素组合；
对组合规模限制不豁免单项覆盖，不新增第二套状态或防护来满足虚构场景。
复用 DelimitedTableIndexTests、DelimitedTablePresentationTests、FileTabPersistenceTests、
NativeEditorCompositionTests、WindowOwnershipIntegrationTests、NativePaneRetentionIntegrationTests、
HTMLFilePreviewTests、NativeDiffTabTests、SSHFileTreeLiveTests 及 FilePreviewWorkspaceUITests／CSVPreviewUITests；
只增加现有测试无法表达的行为，不重复构建测试框架。
真实远端用例复用已授权 SSH 参数及隔离目录，例如
`testAuthorizedWindowsCSVRebindConfirmsActualPublishedBytes`、
`testAuthorizedWindowsReviewedCSVConflictRejectsExternalRevisionAndOldChannel`，并增加结构与批量真实字节检查。
按仓库 Makefile 执行受影响宿主／GUI 定点测试、make build 与 make build:dev；
正式整合 make test。本轮按用户要求不运行完整 App GUI 测试；
可验证的交互、菜单路由及实际写入在挂载宿主和真实后端核对，完整 App 专有路径单列未测。
记录实际环境、命令、失败／跳过、最终字节、Undo、像素、性能与资源证据；
逐项记录不能实测的前置条件、具体原因、尝试及替代证据、潜在影响、补验方式和 Gate 限制，
不将不可用的物理 1×／外接显示器、旧系统、系统真实睡眠或共享桌面冲突冒称通过。
按 C15 的真实像素／身份及 R06 的字节和冲突判据验证结果，不用旧审计结论替代本阶段独立验收。
