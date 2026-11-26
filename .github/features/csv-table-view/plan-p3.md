# P3｜原型式原生网格

交付接近 [CSV HTML 原型](../prototype.html?format=csv) 的紧凑表格、自适应列宽、固定行号和整行／整列选择。
沿用原生 NSTableView、FileTab 及现有原文索引，不嵌入 HTML 或另建编辑模型。

## 源码依据与执行约束

当前 `FileViewerView → CSVTableView → NativeDelimitedGrid → DelimitedGrid`。
`installColumns` 固定新列宽 140 pt，`DelimitedNativeTable.style` 使用系统配色；
`prototype.html` 的 .csv-area、.csv-table、.row-id、.numeric、.selected、.csv-input、.find-pop
定义实际视觉基准；应用配色由现有 Theme 统一提供，见 [主题与共享值](../../../docs/ui.md#主题与共享值)。
`AppSettings.theme → applyAppearance → NSApp.appearance` 决定当前窗口外观，
`themeLight/themeDark → reloadThemeSelection → Theme.reloadSelection → Theme.changes.revision` 决定主题配色。
两条路径必须同时覆盖：改变系统／明暗外观不一定增加 Theme revision；同一外观换主题不一定改变 colorScheme。
FileViewerView 已读取主题 revision，但 CSVTableView 自身未观察它，NativeDelimitedGrid 未接收配色；
`install` 在相同 presentation.id 时提前返回，`style` 仅在单元格创建／选择更新时调用，且使用系统固定配色。
因此不能靠重新安装数据或强制重建 SwiftUI View 实现主题刷新。
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
  单格 Hover 背景、选区强调色填充和细描边、失焦状态及原位输入框分别可辨；
  quoted 换行仅在显示摘要中以 ↵ 提示，完整读取、复制与编辑仍使用原值。
  优先 NSTableView 原生表头、网格线、行高、滚动和 field editor；仅对原型要求而原生未覆盖的状态补绘制，
  不为每格叠多层 View。表头纵向固定、横向与数据同步；固定行号栏归 T2。
  **主题接入**：CSVTableView 在实际绘制子树读取 Theme.changes.revision 与当前 colorScheme，
  从 Theme.terminal(dark:) 解析当前配色，经 NativeDelimitedGrid.updateNSView 传递给同一 DelimitedGrid。
  借鉴 SourceTextEditor.apply 的原生更新方式：配色改变时独立于 install 的 presentation.id 刷新
  scroll/clip/table 背景、表头、分隔线、已实现的可见单元格及当前输入编辑器；
  复用现有 style／可见行刷新边界，新实现的复用单元格也使用当前配色。
  T2 固定行号栏和 P4 的多行编辑、筛选／替换浮层沿同一主题来源。
  未生效的另一套明暗主题设置变化不导致当前数据重新安装；不缓存过期 NSColor／CGColor，
  不按主题 revision 改 View.id、ParseRequest、DisplayRequest 或 SearchRequest，不 reloadData 全表来换色。
  `style` 区分普通 NSTextField 和正在输入的原生 field editor，仅更新必要的文字、背景、插入点、
  选择及焦点外观，不重设 stringValue、firstResponder、marked text 或 Undo；不修改窗口共享 field editor 的无关控件样式。
  未输入的背景、表头、行号、正文、网格线、数字高亮、Hover、选区、编辑框及按需浮层统一从现有主题派生。
  数字绿色缺失时用当前正文色，低对比时沿用现有主题派生可读色的方式，
  原生系统菜单／材质仍遵循 App 有效外观与无障碍设置；不要求用自绘菜单重现 HTML。
  不设 CSV 独立主题、主题缓存／监听总线或固定色备选路径，不硬编码原型暗色值；空表不画假数据。
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
  不叠加两套绘制。移除被新配色替换的 `style` 中 .selectedContentBackgroundColor、
  .alternateSelectedControlTextColor、.labelColor 固定选择路径；同一主题色只在实际所有者解析，
  原生编辑器与复用单元格不保留旧默认配色分支。将同一 FileTab 的 controls 通过一个实际入口取得，
  去掉 representable／grid 重复传递和持有；
  仍保留原生控件访问 file、Undo 与卸载所需的真实引用。
- **验收**：用原型 CSV 分支的 INITIAL（sample_id、material、confining_MPa、strain_rate_s-1、peak_MPa、notes）
  作同尺寸样例，执行时与原型实际渲染截图对照；检查紧凑行高、字体、网格线、表头、数字高亮、
  Hover、选区描边、换行提示和原位编辑框。明暗、自定义主题、失焦、编辑、Undo、窄 Dock、重挂载。
  检查实际行高、表头／编辑器几何、最后一列及十万行滚动；测量首屏、列宽计算、实际实现行与单元格 View 数量及内存，
  不以 NSTableView 名称推定列虚拟化。复用
  `SwiftMarkdownLayoutTests.testGitHubStylePreviewRendersAcrossLightDarkAndNarrowWidths`、
  `AppSettingsTests.testThemeRevisionInvalidatesObserversAndUpdatesNativePalette`、
  `AppSettingsTests.testMountedSettingsSidebarActuallyRepaintsGhosttyAccent` 的已挂载像素验证方式、
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
| C15 视觉与主题 | 下列 C15a–C15f 全部条件；920／480／360／260／220／150 pt、低高度／实际支持的最小尺寸、实际 2× 及可执行倍率 | 与 CSV 原型视觉层次及几何一致、适配主题；控件与编辑器不重叠，不重建表或改变原文 |
| C16 尺寸与虚拟化 | 0／1／10万行；1／2501／4095／4096／4097 列；999999／1000000／1000001 字段；32 MiB 前／等于／后（原编码字节与索引码元分别核对），超长单格／表头、原生拖动／适配、100 次挂载 | 实际末格可达，有界采样、首屏／滚动耗时、实际实现行及单元格数量可核验；保留现有 480×330 宿主实际实现行少于 100 的断言；人工宽度保留、关闭释放 |
| C17 选择与目标 | 行号／表头／矩形／非连续、Shift／⌘、鼠标／键盘／AX，排序／筛选／分隔符／表头变动、并排、双窗、Undo 后重新索引 | 固定行号和表头与真实网格对齐，当前有效投影是唯一动作目标；正确的物理字段、剪贴板、第一响应者及磁盘字节 |

### C15 主题与真实渲染专项

| 条件 | 必验场景与最终判据 |
| --- | --- |
| C15a 全部主题 | 遍历 Theme.commonLightThemes + Theme.commonDarkThemes 当前实际全部 60 个可选定义，包含两套 Default；逐套核对原型样例的背景、表头、行号（T2）、网格线、数字／普通文字、选择、Hover、输入及浮层的真实颜色或像素。对比度不足、缺少 ANSI 绿／选择色的可构造主题输入，用现有 Theme 解析及可读色规则验证，不新增可配置主题功能。未知主题名回退由 Theme 现有入口负责。颜色不是数值、选择或只读状态的唯一提示。 |
| C15b 双路径即时刷新 | 默认→非默认→默认；同为浅色／深色的主题切换；System／Light／Dark 全部转换及 System 随真实系统外观变化；修改未生效的另一主题槽、设置重置、重开 App。独立 AppSettings 配置不得污染当前窗口。核对已挂载 CSV 实际像素与同一窗口的源文／Markdown／Dock 主题，不靠切标签才生效。 |
| C15c 状态与焦点 | 首次挂载、普通／Hover／选择／非连续选区、活动／非活动窗口、右键目标、滚动到首中末列、拖动列宽、空／仅表头／坏表／只读／筛选零行、查找／筛选和活动 field editor。换主题后全部已实现控件与之后复用的控件无旧色，保持窗口第一响应者、真实选区、滚动原点及人工宽度；不能为上色改写选择。 |
| C15d 输入与数据 | 原位输入中（含实际中文 IME marked text、英文输入、Unicode 组合、长字段）切换主题，保存／取消／撤销／重做；P4 增加多行／表头输入和替换浮层。检查当前输入、插入点／选择、原文代次、解析／展示 ID、在途操作与磁盘最终字节。单纯换色不得提交编辑、改变 dirty／Undo、重新解析或触发保存。 |
| C15e 几何与可访问性 | 所有 C15 窗格尺寸及连续改变宽高，系统滚动条自动／始终显示、实际可用显示倍率、鼠标／触控板、键盘、基础 AX 语义与动作；中文／英文及适用的区域数字样本。实测固定表头和行号、半可见行、滚动条、边界像素、浮层锚点和编辑器不互相覆盖；真实 AX 名称、行列位置与状态不依赖配色。 |
| C15f 规模与并发 | 十万行、最大列／字段／文本边界及长单元格，在快速滚动、拖选、排序／筛选／分隔符切换、输入／Undo、后台解析／查找、远端重载／断线及关闭同时重复切换主题；复用同一表格，不触发新的数据任务或全表 View 构造，测主线程耗时、可见对象数、RSS／footprint 和关闭释放；迟到的结果不能恢复旧配色。 |

宿主以实际 FileViewerView → CSVTableView → NativeDelimitedGrid 链挂载，而不是手动调用 grid.style 后宣称响应式生效。
复用原生像素捕获（NSHostingView、NSWindow、NSBitmapImageRep）、主题恢复与实际文件临时目录。
先用相同 presentation.id 的已挂载网格完成 Red（改主题后旧像素或原生样式仍在）→ Green → Refactor，
再检查表头／复用格／编辑器、所有主题及状态；原生对象身份、请求 ID、原文及文件哈希同时核对。
以实际应用 Settings 和系统外观操作的隔离 Dev E2E 验证用户入口、双窗及正在输入的组合，
不把单独设置 window.appearance 当作系统自动外观实测；不通过调大等待或重挂载测试掩盖旧色。

交叉 C15×C16、C15×C17、C16×C17、C02×C17、C06×C17、C09×C17、C13×C17；
C15a×C15c、C15b×C15c/d/e/f、C15d×C15f、C15e×C16、C15b×R06/R07/R08/R10。
先执行全部可行单项、全部极值和可承受的有限组合，再扩大两两、多因素及已知失败组合；
主题集合从实际 Theme.common* 枚举而非写死几个代表项。
宿主复用 DelimitedTablePresentationTests、DelimitedTableIndexTests、SwiftMarkdownLayoutTests、
AppSettingsTests、NativeEditorLayoutTests、NativeEditorCompositionTests、FileTabPersistenceTests、
NativePaneRetentionIntegrationTests、WindowOwnershipIntegrationTests。
完整 App 复用 CSVPreviewUITests、FilePreviewWorkspaceUITests 验证真实鼠标、菜单、焦点及基础 AX。
用现有 Makefile 的 `make test:类名`、`make test ONLY_TESTING=...`、
`make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests`、`make build`、`make build:dev`，
按实际受影响路径定点执行；正式阶段整合 `make test`。
本机环境沿共享 R01（当前 macOS／SDK／Apple Silicon，保留最低 macOS 15.6 部署目标，不冒称旧系统实机）；
缺配的物理显示设备及真实睡眠按共享延期约定处理，获授权 Windows Tailscale 走真实后端。
本轮按用户要求不运行完整 App GUI 测试，不占用桌面键鼠。可验证的原生操作、基础 AX、
像素与状态尽量下沉到挂载宿主；完整 App 专有路径保留为未测，不把宿主结果当成 E2E。
每个无法安全执行的条件记录具体前提、原因、尝试／替代证据、潜在影响、补验方式及是否阻塞对应 Gate。

每任务同时更新 docs/features/editor.md，若共享视觉规则变化才更新 docs/ui.md。
按同机条件记录真实 UI、性能、RSS／footprint、资源释放和剩余环境缺口，不将初始预算当实测结果。
