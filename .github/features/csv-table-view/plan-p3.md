# P3｜原型式原生网格

交付接近 [CSV HTML 原型](../prototype.html?format=csv) 的紧凑表格、自适应列宽、固定行号和整行／整列选择。
沿用原生 NSTableView、FileTab 及现有原文索引，不嵌入 HTML 或另建编辑模型。

## 源码依据与执行约束

当前 `FileViewerView → CSVTableView → NativeDelimitedGrid → DelimitedGrid`。
`installColumns` 固定新列宽 140 pt，`DelimitedNativeTable.style` 使用系统配色；
`prototype.html` 的 .csv-area、.csv-table、.row-id、.numeric、.selected、.csv-input、.find-pop
定义实际视觉基准；应用配色由现有 Theme 统一提供，见 [主题与共享值](../../../docs/ui.md#主题与共享值)。
`NativeLineNumberGutter` 与源码固定 gutter 的实际布局及测试可供固定行号栏复用思路，
不把 TextKit 的物理文本行号直接用于 CSV 逻辑记录。
`DelimitedTablePresentation` 的 rows 是展示到物理记录的映射，Selection.Block 是既有区间选区。
`CSVTableView.displayed` 目前仅绑定 ParseRequest，未绑定 DisplayRequest 中的展示配置；
排序、筛选、表头改变期间可能将旧映射作为当前投影使用。

每项任务先复现、收敛真实入口、删除被替换的实现，再验证并提交。
遵守 [最小实现审查](../../../docs/testing.md#完成标准)，不把清理留到最后阶段。
原文、编码、Undo 和条件保存仍归 FileTab；不重复增加数据保护层。

## 任务

<a id="p3-t1"></a>
### P3-T1 原型式主题与自适应列宽

- **位置**：`NativeDelimitedGrid.updateNSView`、`DelimitedGrid.init/installColumns/tableView(_:viewFor:row:)`、
  `DelimitedNativeTable.style`、`DelimitedHeader`；几何与状态以原型为准，颜色由 Theme 派生。
- **视觉**：直接对照原型：表格顶端贴合标签栏、约 30 pt 行高、11 pt 等宽正文、
  11 pt 系统表头及中等字重、约 11 pt 横向留白、10 pt 等宽行号、细横竖分隔线；
  普通数据行背景统一，不强加 Markdown 式交替行色。表头和行号略有层次，行号右对齐；
  纯十进制／科学计数值用主题绿色（现有 paletteNSColor(2)）作弱高亮，保留原文字面量，
  不按 JavaScript Number 隐式转换。仅分类真实完整的可见值，截断摘要不作数值判定；
  P4-T4 复用该有限数值判定，不再实现第二套规则。
  单格 Hover 背景、选区强调色填充和细描边、失焦状态及原位输入框分别可辨；
  quoted 换行仅在显示摘要中以 ↵ 提示，完整读取、复制与编辑仍使用原值。
  优先 NSTableView 原生表头、网格线、行高、滚动和 field editor；仅对原型要求而原生未覆盖的状态补绘制，
  不为每格叠多层 View。表头纵向固定、横向与数据同步；固定行号栏归 T2。
  背景、表头、行号、正文、网格线、数字高亮、Hover、选区、编辑框及按需浮层均使用 App 当前生效的主题，
  从 Theme.terminal(dark:) 取得相应配色；主题变化通过现有 Theme.changes 即时重绘原生表格和活动编辑器，
  保留输入、焦点、滚动、选区与正文。数字高亮使用主题绿色，缺失时使用正文色。
  不设 CSV 独立主题，不硬编码原型暗色值；空表不画假数据。
- **列宽**：新列首次建立时，测量表头和少量均匀分布的物理数据记录（不依赖当前筛选）。
  以最多 4096 个数据采样格、每格最多 128 UTF-16 码元为初始预算；
  采样只读有界字段片段，使用实际字体；以原型约 110–290 pt 的紧凑列宽为初始视觉范围，
  内容和用户拖动需要时可扩大，长字段保留省略号及完整查看入口。
  先测实际首屏与宽表成本，必要时将样本提取移出 MainActor；
  不预建逐列异步任务、渐进布局调度器、滚动锚点恢复或缓存表。
  小表紧凑并贴合窗格，必要时自然填充剩余宽度而非无限拉宽单列；宽表横向滚动。
  保留原生列边界拖动，列菜单提供重新适配（系统原生双击若可用则直接复用）。
  现有 controls 只保存标签内人工调整的宽度；不持久化新布局，不因普通编辑、筛选或换主题覆盖人工值。
  分隔符／列结构变化按 T2、P4-T1 的身份规则清理或重映射。
- **本任务清理**：删除固定 140 pt 作为默认策略及被替换的系统交替行色、选区配色，
  不叠加两套绘制。将同一 FileTab 的 controls 通过一个实际入口取得，去掉 representable／grid 重复传递和持有；
  仍保留原生控件访问 file、Undo 与卸载所需的真实引用。
- **验收**：用原型 CSV 分支的 INITIAL（sample_id、material、confining_MPa、strain_rate_s-1、peak_MPa、notes）
  作同尺寸样例，执行时与原型实际渲染截图对照；检查紧凑行高、字体、网格线、表头、数字高亮、
  Hover、选区描边、换行提示和原位编辑框。明暗、自定义主题、失焦、编辑、Undo、窄 Dock、重挂载。
  检查实际行高、表头／编辑器几何、最后一列及十万行滚动；测量首屏、列宽计算、实际实现行与单元格 View 数量及内存，
  不以 NSTableView 名称推定列虚拟化。复用
  `SwiftMarkdownLayoutTests.testGitHubStylePreviewRendersAcrossLightDarkAndNarrowWidths`、
  `AppSettingsTests.testThemeRevisionInvalidatesObserversAndUpdatesNativePalette`、
  `DelimitedTablePresentationTests.testNativeGridVirtualizesTallAndWideTablesAndCanReachTheirLastCells`、
  `testRepeatedNativeTableMountsClearRowsAndSelectionInBothAppearances`。

<a id="p3-t2"></a>
### P3-T2 行号、整行／整列选区与表头操作

- **位置**：`CSVTableView` 的 parse/display/search 发布、`DelimitedTableControls.accept/perform`、
  `DelimitedGrid.installColumns/physicalCell/columnMenu/recordMenu`、`DelimitedHeader`、
  `DelimitedNativeTable` 的鼠标、键盘、选择与滚动，以及 `DelimitedTablePresentation.Selection`。
- **投影身份**：已发布 displayed 改用完整 DisplayRequest（ParseRequest + configuration）；
  分隔符、表头、筛选、排序改变时，旧投影即不再接受新数据动作。
  原生事件及浮层确认使用同一当前身份，不只依赖 SwiftUI 下一帧隐藏旧 grid；
  同时收敛解析／展示失败状态的请求归属，取消或迟到错误不得遮盖新结果。
  利用现有请求和取消机制，不增加并行 generation、缓存、延迟重试或通用状态机。
  现有 parsed 状态迁移到 file-owned controls（不是复制），仅保留一个当前有效解析快照，
  供 P4 的菜单派生权限使用；请求和控件退休后不得发布旧结果。
  筛选浮层绑定真实列及当前请求，失效即关闭；分隔符／表头改变前，活动输入按原编辑事务完成或明确取消。
  已接受的 FileTab 草稿不因投影失效、离开表格或连接变化被撤销。
  网格写入成功后通过已有 controls.separator 保留本次确定的分隔符，防止自动检测因
  单格引入其它分隔符或记录变化而改判；不覆盖之后明确选择的分隔符，不持久化新设置。
- **固定行号**：匹配原型 sticky 左栏和 # 左上角，显示 `presentation.rows[row] + 1`；
  有首行表头时第一条数据编号 2，quoted 换行不增加逻辑记录号。原型约 46 pt，按最大记录号位数扩宽。
  原生 NSTableView 没有直接冻结首列 API；优先借鉴现有源码固定 gutter 的原生布局，
  由同一 DelimitedGrid 的滚动宿主提供固定左栏，按原生 table 的实际可见行矩形绘制／布局和命中，
  水平滚动不移动左栏，纵向严格跟随原生行；# 与原生表头等高。
  不创建第二张 NSTableView、第二个独立滚动位置或全表行号 View。
  行号不占数据列索引，原有 field／table 数据列一致；点击和右键通过同一现有选区及记录动作，
  AX 行身份、选择和 # 全选可达。任何数据格菜单也可选择所在行。
  若实际 AppKit 几何／AX 存在问题，在本任务解决并实测，不用伪造的原型截图替代原生结果。
- **选择**：沿用 Selection.Block、anchor／caret；行号选整行，列标题选当前可见数据的整列，
  Shift 扩展、⌘ 追加、左上角和 ⌘A 全选，行列选择的 caret 落在真实数据格。
  非连续区间先合并重叠范围；复制沿用现有 TSV 规则：已选行、列的并集形成交叉矩形，
  未选交叉格为空占位，完全未选的中间行／列不输出；批量写入只访问实际选格。排序／筛选后按真实映射恢复，无法证明旧身份则清除。
  原生 AX 行列选择与逻辑选区一致，不再建立第二套可写选区。
  宿主直接构造 grid 的测试以真实 FileTab 控件状态挂载；不保留仅测试可注入另一套 controls 的入口。空表／仅表头不伪造数据选格；空表插入行沿用现有按钮。
- **表头**：列标题点击只选择，右键提供升序、降序、清除排序以及既有筛选等动作，
  原生表头显示当前排序状态；保留现有多列排序顺序及稳定次序。
  原生列头、列边界调整和上下文菜单优先，不另做独立排序按钮或自定义命中层。
  原型单击标题排序与现行整列选择需求冲突，采用标题选列、菜单排序并在表头标示方向；
  行号右键沿原型提供明确的在此行后插入／删除，复用既有物理记录事务。
  筛选与 Find 保留原型右上角按需浮层的布局，不复制原型将查找与筛选混用的逻辑。
  表头名称与其真实字段区分于无表头时的合成列号，重复／空名称不充当列身份。
  查找「使用选区」在动作时读取实际选中字段，而非提前缓存截断的显示文本。
- **本任务清理**：删除 `sortDescriptorPrototype`、`tableView(sortDescriptorsDidChange:)`、
  `table.sortDescriptors` 与 configuration.sort 的双向状态，排序配置为唯一真源；
  保留原生数据列与字段列的一致索引，删除新增行号时不再需要的重复映射和区间展开去重路径、
  `selectedValue` 的 4096 码元截断缓存。迁移旧测试（点击标题即排序、截断缓存断言），不保留兼容入口。
- **验收**：无／空／重复表头、仅表头、筛选零行、一列和末列、十万行整列、
  重叠及非连续区间、quoted 换行、排序／筛选／分隔符／表头连续变化后立刻操作。
  真实 AX、鼠标、键盘、复制、粘贴、删除、编辑、Undo 和磁盘字节符合物理行列身份。
  复用 NativeEditorLayoutTests.testSourceGutterRemainsOutsideHorizontallyScrollableText 的验证思路，
  实测横滚时 #／行号位置不变、垂直滚动与行边界一致、排序后点击行号仍写入真实记录。
  额外覆盖引入逗号／分号／Tab 后的原地再索引及显式换分隔符。
  更新 `CSVPreviewUITests` 的列头排序和排序后保存用例，验证并排、双窗、源码切换、
  关闭恢复及旧投影不可写；保留现有剪贴板变化计数、窗口和有效请求的异步保护。

## 阶段验收

沿用 [P1 的 C01–C07](plan-p1.md)、[P2 的 C08–C14](plan-p2.md) 和
[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification) 中受影响的真实入口，
不因旧审计结论或已有测试通过而跳过本次源码变化。

| 编号 | 专项条件 | 通过标准 |
| --- | --- | --- |
| C15 视觉 | 亮／暗／自动／自定义主题，920／480／220／150 pt，实际 2× 及可执行倍率，空表／仅表头／筛选零行，中英文和数字混排，输入中切主题 | 与 CSV 原型视觉层次及几何一致、适配主题；控件和编辑器不重叠，不重建表或改变原文 |
| C16 尺寸与虚拟化 | 0／1／10万行、2501／4096／超限列、百万字段、32 MiB 临界值、超长字段、原生拖动／适配、100 次挂载 | 实际末格可达，有界采样、首屏／滚动耗时、实际实现行及单元格数量可核验；保留现有 480×330 宿主实际实现行少于 100 的断言；人工宽度保留、关闭释放 |
| C17 选择与目标 | 行号／表头／矩形／非连续、Shift／⌘、鼠标／键盘／AX，排序／筛选／分隔符／表头变动、并排、双窗、Undo 后重新索引 | 固定行号和表头与真实网格对齐，当前有效投影是唯一动作目标；正确的物理字段、剪贴板、第一响应者及磁盘字节 |

交叉 C15×C16、C15×C17、C16×C17、C02×C17、C06×C17、C09×C17、C13×C17。
宿主复用 DelimitedTablePresentationTests、DelimitedTableIndexTests、SwiftMarkdownLayoutTests、
AppSettingsTests、FileTabPersistenceTests、NativePaneRetentionIntegrationTests、WindowOwnershipIntegrationTests。
完整 App 复用 CSVPreviewUITests、FilePreviewWorkspaceUITests 验证真实鼠标、菜单、焦点和旁白。
用现有 Makefile 的 `make test:类名`、`make test ONLY_TESTING=...`、
`make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests`、`make build`、`make build:dev`，
按实际受影响路径定点执行；正式阶段整合 `make test`。
用户此前暂停 GUI／全量测试的决定仍有效，需恢复授权并独占图形会话；未测不计通过。

每任务同时更新 docs/features/editor.md，若共享视觉规则变化才更新 docs/ui.md。
按同机条件记录真实 UI、性能、RSS／footprint、资源释放和剩余环境缺口，不将初始预算当实测结果。
