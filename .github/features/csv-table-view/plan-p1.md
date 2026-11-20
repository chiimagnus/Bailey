# P1｜以原始 CSV 字节为准的表格阅读

交付可用的 CSV／TSV 表格视图、源码切换、非破坏性排序和筛选。编辑保存留在 P2。

## 技术决定

**不新增 CSV SPM。** CSV／TSV 的核心需求不是普通读写，而是保留每个字段的引号、空白、BOM、原始换行及源区间，编辑某个单元格后仅替换该字段。
[CodableCSV](https://github.com/dehesa/CodableCSV) 虽能解码／编码和流式读取，却不直接返回源区间，且最近的正式版长期未更新；引入后仍要写一套无损定位器，形成两套解析逻辑。
选择单一、小型、受 RFC 4180 约束的**有限状态词法分析**（带 CSV／TSV／分号变体），直接记录记录／字段在 `NSTextStorage` 中的 **UTF-16 `NSRange`**，与 TextKit 编辑 API 对齐；原始字节版本仍归 `FileTab`。
解析器不独立持有第二份可编辑字符串，显示模型只是按当前文本版本建立的索引。
表格使用系统 **AppKit `NSTableView`＋`NSScrollView`**（行列虚拟化、原生辅助功能），不使用 Spreadsheet/Excel UI 框架；多单元格范围选择和编辑必须明确实现，不误以为 `NSTableView` 默认就提供 Excel 网格语义。

## 方案

入口为 `Project.openFile` → `FileTab` → `FileViewerView`（`Bailey/Workspace/Project.swift`、`Bailey/Editor/FileViewerView.swift`）。
新增的解析结果是 **FileTab 原生文本正文的只读投影**，而非第二份可写模型；按内容版本计算、关闭即释放。
`NSTableView` 原生虚拟化行、列头和选择；Tab 控件不生成第二层 Dock。
已有 `SourceTextEditor` 继续负责源码与编解码。依文本文件的既有 32 MiB 边界，不提前扩容。

## 任务

<a id="p1-t1"></a>
### P1-T1 解析和文件类型路由

- **位置**：`FileViewerView` 现有 `.text` 分支、`FileTab.nativeTextStorage`；新增 CSV 解析器及纯解析测试。
  遵循 [文件渲染接入边界](../file-viewer-routing/plan-p1.md)，**不新增 CSV 专用 `Content` case，也不为文本表格重写 `loadedContent`**。
- **实施**：识别 CSV／TSV；有限样本分隔符探测和手动覆盖；有限状态分析 quoted/escaped 字段、CRLF/LF/CR、空行及尾空列，记录**UTF-16 字段与行范围**、对应物理行号和原文引用状态。
  Unicode 代理对和多字节字符不能拿 UTF-8 offset 当作 `NSRange`；格式错误给出准确行列且保留源码，不在网格中默默修复。文件有效时展示只读结构，失败走源码。
- **验证**：与 RFC 4180 参考输入及隔离参考解析器交叉核验（参考库只用于测试，不加入正式 SPM）；
  UTF-8 BOM、UTF-16／非 UTF-8 文本、CRLF／LF／CR 混合、逗号／分号／Tab、嵌套引号、跨行引号、尾空列、空行、CJK/emoji 代理对、字段不齐及损坏引号。
  对比原始字节和 `NSString` NSRange，确认没有第二份可写正文。

<a id="p1-t2"></a>
### P1-T2 原生表格与视图切换

- **位置**：`FileViewerView`、新增 `CSVTableView`、`Bailey/App/BaileyApp.swift` 及文件标签上下文菜单。
- **实施**：默认表格直接显示内容；**复用 Markdown P1-T2 在 File 主菜单注册的唯一 `⌘⇧V` 动作**，此处只提供当前 CSV 的显示模式／能力，不重复注册快捷键。列头右键放筛选与表头选项，`⌘F` 显示短暂查找框，无路径栏、模式条或常驻工具栏。保留原生复制、范围选择与非破坏性排序。
- **验证**：数万／十万行虚拟滚动、横纵滚、长列、窄 Dock、深浅主题、键盘／鼠标／VoiceOver、双窗口焦点、切回源码时原文一字未动。

## 阶段验收

`make build:ui`、受影响 `BaileyTests` 及隔离 `BaileyUITests`；验证空／单行／巨量／不合法输入、大小及编码边界、文件更名／重新读取、快捷键作用域。
P1 不声称已可通过网格修改文件；此处以可访问的只读渲染完整性为 Gate。
