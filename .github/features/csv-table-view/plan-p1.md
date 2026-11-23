# P1｜以单一原文缓冲无损阅读 CSV／TSV

交付默认表格、排序、筛选与源码切换；P1 不修改数据。
CSV 不复用 Markdown 的 GFM 表格解析器，因为二者的字段、引号和原文结构不同。

## 当前文件链与实现边界

- `FileTab.readContent → TextFileEncoding.decode → nativeTextStorage` 已提供
  UTF-8／BOM／UTF-16 与用户指定编码、32 MiB 文本限额、原字节版本检查。
  `TextFileEncoding.prepareSave` 会**重编码整个文本**，但在严格往返编码与
  原始字节相等得到验证后，未编辑的段落／行尾仍可保留原字节；
  不要声称 `FileTab` 已提供通用“只替换磁盘上的某一字段” API。
- 只用一份精简的 RFC 4180 类词法扫描记录字段／物理记录在
  `NSTextStorage` 中的 UTF-16 `NSRange`、转义形式、分隔符和原行终止符。
  CSV／TSV／分号变体作为明确输入选项；引用内 CRLF、空行、尾空列必须正确索引。
  不引入 `CodableCSV`、Markdown AST、第二套 CSV parser／encoder 或可写单元格模型。
  Parser 结果只是当前文本版本的不可变只读索引，源位置和显示排序次序分离。
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

宿主证明解析范围、原编码与字节保真、并发／取消／容量；
隔离 Bailey Dev 证明打开（Files／Finder／会话恢复）、只读网格／排序／筛选、
源码切换和 GUI 焦点。执行相关 `make test:FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
及新增 CSV 专项、`make build` 与阶段 `make test`；
照 `docs/testing.md` 核销所有适用错误、状态、系统／远端与交互组合。
P1 未实现网格写入，禁止宣称可以安全编辑。
