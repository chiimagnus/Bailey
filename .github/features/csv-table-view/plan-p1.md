# P1｜以原始 CSV 字节为准的表格阅读

交付可用的 CSV／TSV 表格视图、源码切换、非破坏性排序和筛选。编辑保存留在 P2。

## 方案

入口为 `Project.openFile` → `FileTab` → `FileViewerView`（`Bailey/Workspace/Project.swift`、`Bailey/Editor/FileViewerView.swift`）。
新增的解析结果是 **FileTab 原生文本正文的只读投影**，而非第二份可写模型；按内容版本计算、关闭即释放。
`NSTableView` 原生虚拟化行、列头和选择；Tab 控件不生成第二层 Dock。
已有 `SourceTextEditor` 继续负责源码与编解码。依文本文件的既有 32 MiB 边界，不提前扩容。

## 任务

<a id="p1-t1"></a>
### P1-T1 解析和文件类型路由

- **位置**：`FileTab.Content`／`FileTab.loadedContent`、`FileViewerView`；新增独立 CSV 解析器及纯解析测试。
- **实施**：识别 CSV／TSV；有限样本分隔符探测和手动覆盖；引用字段、转义引号、行尾、空行与字节范围记录；将警告定位到行列。仅在文件有效时提供结构视图，失败走源码。
- **验证**：真实字节往返，含 UTF-8 BOM、CRLF／LF、逗号／分号／Tab、跨行引号、尾空列、非 ASCII、字段不齐和损坏引号。文本缓冲未额外复制为第二个可写源。

<a id="p1-t2"></a>
### P1-T2 原生表格与视图切换

- **位置**：`FileViewerView`、新增 `CSVTableView`、`Bailey/App/BaileyApp.swift` 及文件标签上下文菜单。
- **实施**：默认表格；⌘⇧V 切换源码；表头显示选项、范围选择、复制、查找、仅展示排序／筛选。视图选项仅归对应文件标签；不让普通文本抢此快捷键。
- **验证**：数万／十万行虚拟滚动、横纵滚、长列、窄 Dock、深浅主题、键盘／鼠标／VoiceOver、双窗口焦点、切回源码时原文一字未动。

## 阶段验收

`make build:ui`、受影响 `BaileyTests` 及隔离 `BaileyUITests`；验证空／单行／巨量／不合法输入、大小及编码边界、文件更名／重新读取、快捷键作用域。
P1 不声称已可通过网格修改文件；此处以可访问的只读渲染完整性为 Gate。
