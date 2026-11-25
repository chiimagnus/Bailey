# P3｜Markdown 式原生网格

让 CSV／TSV 的默认表格拥有 Markdown 表格的视觉质量、按内容适配的列宽和明确的行列选择。
保留 P1／P2 的编辑、显示路由与字节保真；P4 在这张网格上增加数据操作。

## 方案与依据

当前入口是 `FileViewerView → CSVTableView → NativeDelimitedGrid → DelimitedGrid`。
`DelimitedGrid` 用 `NSTableView` 虚拟化数据行，`installColumns` 为新列固定 140 pt，
`tableView(_:viewFor:row:)` 使用单行、尾部截断的 NSTextField，`DelimitedNativeTable.style`
只处理系统选中背景；并没有 Markdown 式边框、字体和间距。
`DelimitedTablePresentation` 用不可变的物理记录映射提供展示排序和筛选，
`Selection.Block` 以两个闭区间表达矩形，不需要逐格存储选区。

Markdown 原生 GFM 表格见 `MarkdownNativeBlockView.cell`（`MarkdownPreview.swift`）
及 `MarkdownHTMLContent`（`MarkdownHTMLView.swift`）：
零 Grid 间隔、半粗表头、等宽数字、12–13 pt 横向和 6–7 pt 纵向内边距、
细横竖分隔线、交替的 background／muted 背景，使用 `MarkdownReaderColors`。
CSV 应共用现有 Theme 的颜色来源和表格视觉尺度，而不是将全量 SwiftUI Grid 当成编辑器。
仅提取实际共同使用的表格视觉值，不复制主题常量或再建一套主题系统。

AppKit SDK 已提供 `NSTableView.style`、`gridStyleMask`、`gridColor`、`rowHeight`、
`intercellSpacing`、`NSTableHeaderView` 和列拖拽调整接口，优先用这些原生能力。
先在真实宿主比较绘制效果、选择和 field editor 几何；若系统表头无法实现所需颜色及间距，
只在现有 DelimitedHeader／header cell 边界调整绘制及命中，不替换表格或原生滚动。
SDK 没有可直接使用的冻结首列 API：行号采用同一表格的辅助首列，随表横向滚动，
任何单元格的右键菜单始终可选择对应行，不为冻结行号另建同步滚动的第二张表。

## 任务

<a id="p3-t1"></a>
### P3-T1 Markdown 式主题与自适应列宽

- **位置**：`CSVTableView.swift` 的 `NativeDelimitedGrid.updateNSView`、
  `DelimitedGrid.init/installColumns/tableView(_:viewFor:row:)`、`DelimitedHeader`、
  `DelimitedNativeTable.style`；核对 `MarkdownReaderColors`、原生 GFM／HTML 表格与 `Theme`。
- **实施**：明确原生表格样式与行高，使用 Markdown 同源文字、背景、交替行色、表头字重、
  单元格留白及细分隔线；按 backing scale 对齐线条，不在每格叠放多层独立视图。
  主题变化更新现有原生表面和复用单元格，保留原选区、输入与滚动，不重建 FileTab。
  选区用现有强调色，非活动窗口、Hover、当前单元格和编辑态分别表达。
  表头始终可见，水平滚动时与内容同步；空表、表头独行、过滤零行不画虚假的数据网格。
- **列宽**：删除 140 pt 作为所有新列的唯一宽度策略。按真实表头及有界字段样本测量；
  从物理记录取样而非仅当前筛选结果，首／中／末和可见记录均纳入；极宽字段限制初始宽度，
  但完整值仍可查看、复制和编辑。小表自然宽度，宽表横向滚动，不无条件等分或拉伸最后一列。
  建议初始约 64–480 pt（含内边距和表头排序入口），先在 220／480／920 pt 实际窗口验证后确定；
  用户可拖动原生列边界、双击列边界或右键重新适配。自动宽度估计先采用每列至多 32 条物理记录、每字段至多 256 个 UTF-16 码元的预算；
  小表可一次测量，极宽表按首屏及后续可见列分批，每批至多 1024 个字段样本。
  后台处理不可变字段样本，MainActor 只测量有界文本并设置实际列宽；
  未测的列先按表头确定有界初值，后续首次适配时保留当前可见列锚点，防止横向滚动跳跃。
  数值为待测的初始预算，不是已取得的性能结果。
  不逐次编辑扫描全文、不为所有格创建 NSTextField、不因筛选或每次重挂载覆盖人工宽度。
  `DelimitedTableControls` 保存当前标签的手动列宽；分隔符改变或列身份已不可证明时丢弃失效设置，
  与 P4 结构操作的列索引映射衔接，不持久化全表布局。
- **验证**：建立同主题、同窗口内容的 CSV 与 GFM 表格像素基线，
  检查实际表头、横竖线、交替色、内边距、字体及明暗主题切换（含自定义主题）。
  宿主复用 `testRepeatedNativeTableMountsClearRowsAndSelectionInBothAppearances`、
  `testNativeGridVirtualizesTallAndWideTablesAndCanReachTheirLastCells`，增加真实表头和编辑框几何、
  宽度估计／人工覆盖、复用及重挂载断言。CSV 显示及源文件不变，Markdown 渲染不退化。
  单一标签多 Dock／双窗分别保持各自显示身份；视觉修改记录同尺寸、内容和动作的前后并排录屏。
- **文档**：更新 `docs/features/editor.md` 的实际网格外观、适配列宽和限制；
  如提取共享视觉值，仅在现有 `docs/ui.md` 对应 owner 维护说明。

<a id="p3-t2"></a>
### P3-T2 行号、整行／整列选区与表头操作

- **位置**：`DelimitedGrid.installColumns/physicalCell/recordMenu/columnMenu`、
  `DelimitedHeader`、`DelimitedNativeTable.mouseDown/keyDown/select/selectAll`、
  `DelimitedTablePresentation.Selection/rows/copy/find` 及 `DelimitedTableControls`。
- **实施**：行号按 `presentation.rows[row] + 1` 显示原始逻辑记录号；
  首行作为表头时记录 1 属于表头，数据从 2 开始，quoted 内换行不新增记录号。
  行号不是数据列，不进入 CSV 字段索引、排序、复制、粘贴、查找或原文写入；
  在现有网格边界统一实际 NSTableColumn 与数据列索引转换（含命中、滚动、field editor、
  sort descriptor 和 AX），不能在每个调用处临时加减 1。
  行号点击选整行，列头标题点击选当前可见数据的整列；Shift 连续选择、⌘ 多块追加，
  左上角及 ⌘A 选全部当前可见数据，保留原生方向键、Tab 和单格／矩形选择。
  行列选区复用既有区间块、anchor／caret 和 NSTableView 原生行选中映射，
  不枚举所有选中格创建对象；重叠块去重。复制沿用原 TSV 矩形规则，
  非连续选区的未选交叉格仍为空占位；批量编辑不得把这些占位当作被选字段。
  排序／筛选后选区只依据当前展示映射；无法证明旧选择身份时清除，不把旧视觉行号套到新记录。
- **表头动作**：列标题选列，独立排序按钮（含方向／优先级）及右键菜单升序、降序、清除排序；
  保留 P1 的展示排序功能，替换旧标题点击即排序的唯一动作路径及对应测试，
  列边界拖动／双击适配、标题选择、排序与 P4 的重命名相互独立。
  右键命中明确是该列或行的有效目标，不改变其它窗口的选区；
  选区和筛选状态清楚可辨，表头和辅助列可键盘／AX 访问，
  表头保留真实字段名称及 sort 语义；无数据时不伪造单元格。
  恢复显示、离开网格、关闭、重新索引和原生编辑中的输入焦点遵循现有路径。
- **验证**：同名／空表头、无表头、仅表头、过滤零行、倒序、不连续记录、多块重叠、
  非相邻列、带 quoted 换行、宽表最后一列、十万行整列选择、复制／粘贴及查找，
  检查行号、实际 AX 行列语义、原始字段坐标和剪贴板（不含辅助行号）。
  真实 App 验证鼠标、菜单、键盘、两窗和并排源码；选列不排序、排序不写盘，
  直接编辑仍只修改正确的物理字段；空表／只读网格依然可安全查看。
- **文档**：在 `docs/features/editor.md` 同任务替换旧列头排序入口说明，
  删除已被替代的索引／菜单分支，不留第二套选择真源。

## 阶段验收

沿用 [P1 的 C01–C07](plan-p1.md)、
[P2](plan-p2.md) 中既有编辑回归及
[共享 R01–R11 和环境／归属规则](../file-viewer-routing/plan-p1.md#shared-verification)。
历史 P1／P2 审计保留原结论；进入执行时核对前置 Gate，用户已暂缓的真实旁白及全量测试
不得伪造通过，也不因新规划改写为 Go。

| 编号 | 验收条件 | 最终结果 |
| --- | --- | --- |
| C15 视觉 | 亮／暗／自动与自定义主题、宽／窄 Dock（920／480／220／150 pt）、实际 2× 与可执行倍率、空表／仅表头／筛选零行、短／长内容、中英文和数字混排。 | 与 Markdown 同源色彩与边界，表头／网格／编辑器不重叠，分隔线不漂移；窗口缩放不重建表或改变数据。 |
| C16 尺寸与虚拟化 | 0／1／10万行、2501／4096／超限列、百万字段及 32 MiB 临界值、极宽文本、快速滚动、拖动／适配列宽、主题切换和 100 次挂载。 | 不扫描或布局整表来绘制首屏；可到最后格、宽度适配有界，保持既有行虚拟化断言（480×330 宿主实际实现行少于 100），关闭后资源释放。 |
| C17 选择与入口 | 头部／行号／单元格、Shift／⌘／矩形／非连续、⌘A、键盘及 AX；排序、筛选、换分隔符、重复列名、手动列宽、并排源码、双窗及撤销后重索引。 | 选区和物理字段映射一致；排序入口独立，清除／恢复正确，复制和编辑绝不把行号或表头算入普通数据；正确目标、第一响应者与文件字节。 |

交叉 C15×C16、C15×C17、C16×C17、C02×C17、C06×C17、C09×C17，
及共享窗口归属、原生输入、关闭恢复的全部适用条件。
复用既有宿主 `DelimitedTablePresentationTests`、`DelimitedTableIndexTests`、
`SwiftMarkdownLayoutTests`、`FileTabPersistenceTests`、`NativePaneRetentionIntegrationTests`、
`WindowOwnershipIntegrationTests` 和完整 App `CSVPreviewUITests`／`FilePreviewWorkspaceUITests`。
阶段宿主命令：

```sh
make test:DelimitedTablePresentationTests,DelimitedTableIndexTests,SwiftMarkdownLayoutTests
make test:FileTabPersistenceTests,NativePaneRetentionIntegrationTests,WindowOwnershipIntegrationTests
make build
make build:dev
make test:ui ONLY_TESTING=BaileyUITests/CSVPreviewUITests
make test:ui ONLY_TESTING=BaileyUITests/FilePreviewWorkspaceUITests
```

开发时先运行对应定点方法，完整 App 仅在允许且独占图形会话时运行。
正式阶段整合运行 `make test`；此前暂停测试的决定仍有效，待用户恢复验收后执行。
记录首屏、滚动、宽度计算、选择和关闭 RSS／footprint、实际实现行数及同机修改前后对照；
不把已有单次测量写成固定性能保证。缺配设备与其它不可安全执行条件按共享规则逐项记录。
