# P1｜以单一原文缓冲无损阅读 CSV／TSV

交付默认表格、排序、筛选与源码切换；P1 不修改数据。
CSV 不复用 Markdown 的 GFM 表格解析器，因为二者的字段、引号和原文结构不同。

本页保留 P1 的基础交付与验收；后续表格视觉、列头选择与排序的入口调整以
[P3](plan-p3.md) 为准，原有解析及只读不变量继续有效。

## 当前文件链与实现边界

- `FileTab.readContent → TextFileEncoding.decode → nativeTextStorage` 已提供
  UTF-8／BOM／UTF-16 与用户指定编码、32 MiB 文本限额、原字节版本检查。
  `TextFileEncoding.prepareSave` 会**重编码整个文本**，但在严格往返编码与
  原始字节相等得到验证后，未编辑的段落／行尾仍可保留原字节。
  合法 UTF-8 表格的 `# coding:` 首字段是数据，不参与自动选择或显式转换。
  Git LFS 已有非 UTF-8 CSV 用 `# coding: gbk` 自描述；保留此回退，
  仅在没有 BOM、显式选择且严格 UTF-8 失败时生效。
  规则仍由共用 TextFileEncoding 负责，不创建 CSV 专用解码器；
  不要声称 `FileTab` 已提供通用“只替换磁盘上的某一字段” API。
- 只用一份精简的 RFC 4180 类词法扫描记录字段／物理记录在
  `NSTextStorage` 中的 UTF-16 `NSRange`、转义形式、分隔符和原行终止符。
  CSV／TSV／分号变体作为明确输入选项；引用内 CRLF、空行、尾空列必须正确索引。
  不引入 `CodableCSV`、Markdown AST、第二套 CSV parser／encoder 或可写单元格模型。
  Parser 结果只是当前文本版本的不可变只读索引，源位置和显示排序次序分离；
  手工切分隔符／列头选项均不改原文，且所有解析结果和 UI 请求须绑定 FileTab 编辑代次。
  `DelimitedTableIndex` 使用最多 16,384 个 UTF-16 码元识别分隔符，整表索引最多一百万字段；
  超限保留可辨认记录和源位置，不放宽 FileTab 的 32 MiB 原始字节读取上限。
  `FileTab.delimitedSnapshot` 使用 Markdown 已有的文本请求代次，并核对原字节能否往返。
- 系统 AppKit `NSTableView`＋`NSScrollView` 呈现网格，复用原生行虚拟化、键盘及 AX；
  **多格选择／剪贴板和原生范围编辑要实际实现并测试**，不能当作 NSTableView 免费提供。
  十万行与极宽字段的解析／排序／筛选从主 actor 移开，有界缓存可见内容，
  不把全表转成第二份每格 `String` 或为隐藏缩略图布局百万个 Cell。
- `.csv/.tsv` 仍是 `FileTab.Content.text`，完整源码与保存只归
  `SourceTextEditor`／`FileTab`。视图模式、Dock companion 和唯一
  `⌘⇧V` 使用 [已有 Markdown 入口的通用化方案](../file-viewer-routing/plan-p1.md#p1-t2)；
  CSV 默认表格，切换不会再创建文件标签、编辑器或 File 菜单命令。
  若 CSV 是第一个新格式，则**在同任务**移除原 Markdown 专名分发代码。

## 任务

<a id="p1-t1"></a>
### P1-T1 原文 UTF-16 字段索引与有界类型路由

- **位置**：`FileTab.nativeTextStorage`、`TextFileEncoding`、现有 `.text` 分发，
  新增唯一 CSV／TSV 源字段词法扫描及相关宿主测试。
- **实施**：UTF-16 源坐标必须对应当前 TextKit 字符（BOM 已由解码层处理），
  不用 UTF-8 字节偏移直接写 `NSRange`；准确识别双引号转义、
  quoted 换行、物理行／逻辑记录、尾空列与空值，有限样本猜测默认分隔符并允许用户更改。
  解析出错或列数不齐时提供具体源行列与只读／源码回退，
  不能悄悄修复并回写磁盘。验证原编码严格重编码与已接受
  `WorkspaceFileVersion` 原字节匹配；无法安全回合的文件不得启用未来网格写入。
- **验证**：RFC 4180／TSV／分号、BOM 与各种 Unicode、emoji 组合字符、
  UTF-16／GBK 等受支持编码、CR／LF／CRLF 混合、quoted 换行、
  引号、空值／尾空列／末尾换行、非法引号、二进制／编码失败、
  32 MiB 边界、巨大字段／行数、路径大小写／改名；
  对照真实源字节与 `NSString` 中的每个偏移，不创建第二套正文。

<a id="p1-t2"></a>
### P1-T2 共用文件展示模式，交付可访问的只读原生表格

- **位置**：`FileViewerView`、文件标签／Dock、`BaileyApp.swift` 现有 `⌘⇧V`，
  新增最小 `CSVTableView` 及 `TabSwitcherView` 有界缩略图行为。
- **实施**：默认表格、可切源码，行列虚拟化、只改展示次序的排序／筛选、
  按需 `⌘F`、原生多格选区／复制。文件标签右键菜单作用原目标，
  主菜单只作用当前前台有效文件；按现有 Markdown 路由通用化要求替换旧分支，
  不添加常驻格式栏、额外分屏或专用全局表格 Manager。
- **验证**：10 万行级虚拟滚动、超宽列／水平滚动、排序后源字节不变、
  组合筛选与查找、窄 Dock／双窗口／暗亮主题、键盘／鼠标／VoiceOver、
  菜单焦点与原文切回选区，真实 `⌘F` 与复制结果，以及 Markdown 原菜单回归。

## 阶段验收

本轮远端连接、现有设备及缺配设备延期规则统一遵循[共用验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；
任务独立核销与阶段共同验证按[验收归属](../file-viewer-routing/plan-p1.md#acceptance-ownership)，不复制公共测试。

宿主证明解析范围、原编码与字节保真、并发／取消／容量；
隔离 Bailey Dev 证明打开（Files／Finder／会话恢复）、只读网格／排序／筛选、
源码切换和 GUI 焦点。执行相关 `make test:FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
及新增 CSV 专项、`make build` 与阶段 `make test`；
照 `docs/testing.md` 核销所有适用错误、状态、系统／远端与交互组合。
P1 未实现网格写入，禁止宣称可以安全编辑。

### CSV／TSV 专项验收矩阵（P1）

共同的文件、资源、菜单、并发及设备条件执行
[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)；
每个解析夹具保存原始字节与期待的**物理记录、逻辑行、字段 UTF-16 区间**，
不能只比较画面上显示的格子数量。

| 编号 | 解析与界面测试样本 | 最终结果 |
| --- | --- | --- |
| C01 词法 | 空表、只有分隔符、单字段／末尾空列、quoted 逗号、`""`、单格内 CRLF／CR／LF、空白行、末尾无换行、NUL／未闭引号、行宽不一致。 | 区分空记录、空字符串、引用内换行和坏 CSV；所有有效字段的 `NSRange` 恰好映射原 `NSTextStorage`，坏输入指明行列并允许无损回源码。 |
| C02 分隔符 | `.csv` 逗号／分号、`.tsv` Tab、带引号的分隔符、自动探测不确定／混合分隔符、手工选择、表头重复／缺失／空值。 | 自动识别不能破坏正确引用；不确定时让用户明确选择，切换分隔符与表头只是展示设置，磁盘和原文本不变。 |
| C03 编码 | UTF-8／BOM／UTF-16 LE-BE、GBK／GB18030／Shift-JIS／Latin-1、Emoji／组合字符、源首格为 `# coding: GBK`、无效字节和非往返编码。 | 不把数据列当 Python 头部声明；使用 FileTab 既有统一解码与显式重新打开，错误时只读／回源码，不另作 CSV 字节解码。 |
| C04 范围 | UTF-16 代理对边缘、CRLF 两字符边缘、Emoji 在多行 quoted 字段中、U+2028／U+2029、混合换行、超长单格。 | 按 UTF-16 原始位置精确命中，选择和未来写入都不切开 surrogate、引号或换行序列；视觉行不等于记录号。 |
| C05 容量 | `0/1/32 MiB-1/32 MiB/32 MiB+1`、100000 物理行、极宽字段、数千列、深度引用样式、连续滚动和文本后续插入。 | 32 MiB 文件读取上限保持；解析、排序、筛选离开 MainActor，表格可见行虚拟化，不建全文第二份每格字符串，内存／延迟记录可复核。 |
| C06 纯查看 | 升／降序、按多列／文本筛选、原顺序返回、复制非连续区间、查找无匹配／多匹配、滚到百万字符之后的某列。 | 操作只修改当前展示映射，选区和复制结果正确；保存前后原文件 SHA 与字节完全相同，搜索不会布局全表。 |
| C07 真实交互 | 默认网格、切源码→网格→并排（若该格式支持）、Finder、双 Dock、大小写后缀、窗口更换、光标／右键、VoiceOver／中文路径。 | 文件身份、菜单作用目标、标题／行列 AX 和焦点一致；TabSwitcher 只取轻量摘要，不再次解析/加载整份大表。 |

必须交叉 C01×C04、C02×C03、C03×C05、C05×C06、C06×C07 和 R03×C03；
按实际源区间和磁盘内容断言，而非以筛选后 `NSTableView.numberOfRows` 正确冒充数据保真。
