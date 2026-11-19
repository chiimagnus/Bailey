# P1｜Markdown 安全预览与视图命令

交付与原生源码编辑器共用文件身份的 Markdown 预览，在当前文件标签切换，不创建独立 Dock。

## 方案

`Project.openFile` → `FileTab` → `FileViewerView` 继续做加载与保存；`SourceTextEditor` 保持唯一可编辑正文。
在 `FileViewerView` 增加受控的 Markdown 渲染区，资源路径由文件所属本机工作区决定。
使用现有 `WKWebView` 平台机制进行安全排版；解析器优先核实现有 SPM 能力，需引入时只用一个经过维护的 Markdown 解析依赖。不将任意源 HTML 直接交给可执行 WebKit。
快捷键归 `Bailey/App/BaileyApp.swift` 的原生命令，当前选中 Markdown 标签才启用。

## 任务

<a id="p1-t1"></a>
### P1-T1 渲染 CommonMark／GFM 与相对图片

- **位置**：`FileViewerView`、新增 Markdown 渲染代码、`WorkspaceBackend` 既有只读接口与宿主测试。
- **实施**：映射 Markdown 段落与表格；拦截代码、原始 HTML、外链和资源 URL；不执行脚本，不向网络自动发送内容。将相对路径解析限制在当前文件所在位置与用户确实打开的资源。
- **验证**：中英、emoji、段落、引用、代码、表格、任务清单、本地图片、链接、损坏语法、XSS／JS／外链及未授权绝对文件 URL。

<a id="p1-t2"></a>
### P1-T2 单标签预览、源码切换

- **位置**：`FileViewerView`、`BaileyApp.swift` 的 Editor / View 命令、`docs/features/editor.md`。
- **实施**：默认源码；局部选项「源码／预览／并排」；⌘⇧V 切换源码与预览。原生工具栏不新增全局按钮；切换保持同一 `FileTab` 和编辑者身份。
- **验证**：窗口及 Dock 多组、标签切换、⌘W、重启恢复、失焦时菜单启用条件、字号和明暗外观；未编辑不会脏。

## 阶段验收

`make build:ui`、独立宿主解析／安全测试、必要 Bailey Dev GUI。
明示布局预览只是文件的另一种视图；原文的 TextKit Undo、Finder 路径和编码不可因预览重建。
