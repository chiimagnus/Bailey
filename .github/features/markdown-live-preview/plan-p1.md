# P1｜安全 Markdown 预览、Front Matter 与 File 菜单

交付在同一文件标签安全排版 Markdown／GFM，正确识别 `SKILL.md` 元数据，并由系统 File 菜单双向切换。

## 方案与真实入口

现有 `Project.openFile` → `FileTab`（`Bailey/Editor/FileViewerView.swift`）→ `FileViewerView` 管理文件读取、唯一原生 `NSTextStorage`、保存及重载。
解析 HTML 不得引入第二份可写源文件；Markdown 生成的是只读显示快照。
优先核对项目已有解析依赖；无可用解析器时采用一个维护中的 CommonMark/GFM 解析器，**不**自行堆正则模拟全部 Markdown。
Front Matter 用无执行能力的 YAML 数据解析器，作为文档头部元数据，而不是普通段落或可执行配置。
权限检查必须延伸到图片和媒体资源的实际解码请求，不能只验证文本 URL。

应用快捷键唯一注册点为 `Bailey/App/BaileyApp.swift` 的 **`CommandMenu("File")`**，不是额外的 View/Editor 菜单。
沿用现有 Save 的 `WorkspaceWindowModel.selectedProject?.focusedContent` 和前台主窗口校验；
`WorkspaceDockView.projectTabMenu` 的显式右键视图选择只作用被右键的文件标签，不推断它是当前输入焦点。
单一动作的可用性、标题和目标由当前有效文件显示模式决定；`⌘⇧V` 不绑定在右键菜单或编辑器事件中。

## 任务

<a id="p1-t1"></a>
### P1-T1 Markdown／GFM、Front Matter 与安全静态资源

- **位置**：`FileTab` 原生正文读取、`FileViewerView` 新增只读渲染、既有 `WorkspaceBackend` 资源读取和 `BaileyTests/Files`。
- **实施**：CommonMark/GFM、标题锚点、表格、任务清单、围栏代码和安全内联 HTML；
  仅在 BOM 后文首检测配对 `---` 的 YAML Front Matter，保留全部原文字节，允许文件标签右键查看解析出的元数据。
  相对 PNG／SVG 等按当前文件实际项目、机器和获准目录定位；外部链接不自动打开，资源失败以局部替代文本展示。
- **验证**：`SKILL.md` 多行 YAML 值、注释、空值、自定义 YAML 标签、未闭合／非头部横线；
  GFM、Unicode、代码块与嵌套 HTML；SVG/PNG 丢失、转义路径、权限、文件更名、SSH 与同名本地文件；CSP、恶意标签及离线验证。

<a id="p1-t2"></a>
### P1-T2 统一 File 菜单快捷键和动态置灰

- **位置**：`BaileyApp.swift` 的 File `CommandMenu`、`WorkspaceWindowModel` 当前活动文件路由、`WorkspaceDockView.projectTabMenu`、`FileTab` 的单份显示状态和 `docs/features/editor.md`。
- **实施**：在 Open File 与 Save 间常驻一个命令：
  `Button(当前是源码 ? "显示预览" : "显示源码")`、
  `.keyboardShortcut("v", modifiers: [.command, .shift])`、
  `.disabled(!canToggleSourcePreview)`。
  源码→预览；预览→源码；并排→源码；CSV 则对应表格／源码。
  文件标签右键「源码／预览／并排」不显示快捷键，也不额外注册按键。
  格式支持、内容可用性及是否为当前真实活动 Dock 文件共同决定启用状态；
  工具栏／终端／Browser／普通代码及失去窗口焦点时系统菜单项置灰。
  只读允许切换；预览出错仍允许返回源码。
- **验证**：实际 File 菜单在支持／不支持格式、两窗、多个 Dock、后台右键标签、查找／设置焦点、关闭／重载及错误渲染时动态正确；
  单次按键只执行一次、无响铃、菜单项不消失、不触发别的窗口；屏幕阅读器可识别禁用状态。

## 阶段验收

`make build:ui`、宿主格式识别／权限／菜单路由测试和隔离 Bailey Dev 完整菜单／编辑 GUI 测试。
编辑和打开预览前后，文件原始字节与所有 TextKit Undo 仍一致。
