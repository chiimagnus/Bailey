# P1｜用 swift-markdown 建立原生预览

交付一条可在 Bailey 真正打开的 Markdown 阅读路径：同一 `FileTab` 的源码／预览切换，原生 CommonMark/GFM、YAML 元数据和受控图片。
**解析使用 [swift-markdown 0.9.0](https://github.com/swiftlang/swift-markdown/tree/0.9.0)，渲染由 Bailey 的 SwiftUI 组件实现；不使用 Textual、MarkdownView 或 WebKit。**

## 方案

`Project.openFile` → `FileTab.nativeTextStorage` → `FileViewerView` 是唯一文件与编辑链路。
阅读器只消费源文档快照，不拥有第二份可编辑文本、Undo 或保存状态。
`swift-markdown` 用 cmark-gfm 生成 AST，必须直接读取节点类型与子节点；绝不把 Markdown 转成 HTML 再渲染，也不使用 Foundation `AttributedString(markdown:)` 作为第二套普通 Markdown 解析器。

Markdown AST 的 `Document` 未公开声明 `Sendable`；跨 actor 时在解析任务中投影成最少必要的不可变、`Sendable` 显示节点（保留行号、标题、代码围栏语言、表格单元和链接目标），不要把不安全的 AST 引用放入 UI 状态。
普通内联内容用 SwiftUI `Text` 组合相邻片段；块级使用 SwiftUI 原生布局。长文档先异步解析、按块懒加载；实际跨块选区效果必须在 GUI 中证明，不能把 `.textSelection(.enabled)` 当作证明。
不再复制 Textual 的富文本、附件、布局引擎。

Front Matter 仅限文件开头（可带 BOM）由 Yams 解析；元数据和正文分离，源码字节不变。
相对资源只允许由现有 `PreviewResource`（已由原 MarkdownResource 收敛为公共文件预览资源）经
`WorkspaceBackend` 与 `LocalPathScope` 访问当前项目／机器；
原生 SVG、图片和 HTML 沿当前 `swift-markdown` 分支的实现演进，不恢复旧 Textual 渲染路径。

静态 HTML 完整性、额外 GitHub 语义与源码导航的后续扩展以 [P3](plan-p3.md) 为准。

真实位置：`Bailey/Editor/FileViewerView.swift`、`Bailey/Workspace/Project.swift`、
`Bailey/Editor/SourceTextEditor.swift`、`Bailey/App/BaileyApp.swift`、
`Bailey/UI/WorkspaceDockView.swift`、`Bailey/Workspace/WorkspaceWindowModel.swift`、
`Bailey/Workspace/LocalWorkspaceBackend.swift`；这些入口的职责以当前源码为准。

## 任务

<a id="p1-t1"></a>
### P1-T1 原生 CommonMark/GFM、元数据与安全图片

- 新增 `Bailey/Editor/MarkdownDocument.swift` 作为 swift-markdown AST → 展示快照的唯一转换入口；建立 `MarkdownPreview.swift` 的 SwiftUI 标题、锚点、段落、强调、链接、列表、任务项、引用、表格、代码围栏与分割线。
- 接入 `swift-markdown` 和必要的 Yams，静态图片通过 ImageIO／CoreGraphics 解码；相对文件以及 SVG 的受控加载复用旧分支有证据的 `MarkdownResource`／`MarkdownSVG`，删去 Textual AttachmentLoader 路径。
- `SKILL.md` 文首 YAML、BOM、空值、未闭合、非文首横线能正确区分；`.mdx` 中 import/JSX/表达式只显示文字，不执行也不丢失。
- 在 `BaileyTests/Files` 添加基于真实文件和 AST 的行为测试；覆盖 GFM 原始语义、围栏原文及语言、内联／块 HTML 的不执行语义、Unicode、表格边界与解析失败无损回退。
- 完成判据：可显示真实文档、没有 WKWebView、文件不存在／越界／外链／SSH 同名本地路径都不能绕过 backend，未保存源码及字节保持不变。

<a id="p1-t2"></a>
### P1-T2 同一标签切换源码／预览与 File 菜单

- `FileTab` 只增加独立于源码缓冲的阅读显示状态；`FileViewerView` 挂载只读预览，保留现有 TextKit 源码编辑器和编辑状态。
- `BaileyApp.swift` File 菜单统一注册 `⌘⇧V`；`WorkspaceWindowModel` 按前台有效 Dock 焦点路由，`WorkspaceDockView.projectTabMenu` 的右键目标独立。
- 正确处理 `.md/.markdown/.mdx`、只读、后台标签、多窗口、无效预览及其他非预览类型；菜单动态置灰，不注册第二套按键监听。旧的 Dock、保存／Undo 和编辑器路径不替换。
- 完成判据：实际隔离 Bailey Dev 中往返切换无新标签、无自动保存，原生编辑器恢复原始选区与焦点；现有相关宿主及 UI 测试通过。

<a id="p1-t3"></a>
### P1-T3 GitHub Markdown 视觉与指针交互

- 对照 [Primer Markdown 样式](https://github.com/primer/css/tree/main/src/markdown) 调整 `MarkdownPreview`／`MarkdownHTMLContent` 的字号、行高、标题／引用、列表、表格、代码片段及响应式内边距；复用当前 `MarkdownGitHubColors`，不复制 CSS 引擎。此任务只负责基础视觉，复杂嵌套与 GFM Alerts 见 P2-T8。
- 链接保留 AST 嵌套强调语义；原生系统链接处理真正的文字范围，图片、HTML 交互和标题锚点仅在可点击区域使用 `.pointerStyle(.link)`。正文不要整段显示手形指针。
- 代码围栏使用 GitHub 风格悬停复制控件；键盘和 VoiceOver 仍可发现操作。错误资源、超长代码、内联图片混排和深浅主题真实复验。
- 宿主核验嵌套链接与完整源码；隔离 Bailey Dev 以真实 README／`SKILL.md` 和复杂混排文档验证点击跳转、指针形状、Hover／焦点、截图、窄 Dock、选择复制及样式回归。
  简短专项用例只定位缺陷；跨结构连续选择归 P2-T6，跨环境极端覆盖按 P2 共同验收执行。

## P1 验收

- **语义**：CommonMark／GFM 规范样例、Front Matter／MDX、嵌套引用／列表／表格、代码围栏、链接、题注与超长行；未支持语义不得无声丢失。
- **安全**：真实受控项目目录、符号链接逃逸、`../`、百分号编码、`file:`／`http:`／`https:`、SSH 断线和同路径不同机器；观测实际资源读取与网络请求。
- **体验**：双窗口、多 Dock、窄布局、原生键盘、深浅主题、VoiceOver、跨段落拖选/复制与标题跳转。选区跨块是否成立需真实 GUI 记录，不以组件构造代替。
- **性能**：500／5,000／20,000 行和已有 32 MiB 文件边界，分别量化解析、首屏、滚动、内存、输入时主 actor 停顿；不把纯 AST 基准冒充渲染性能。
- **命令**：按 `AGENTS.md` 由根 `Makefile` 执行隔离 `build:dev`、所需 `BaileyTests`、`build:ui` 和必要的 `BaileyUITests`。真实 GUI 验收使用独立 Bailey Dev，绝不替换正式 App。
