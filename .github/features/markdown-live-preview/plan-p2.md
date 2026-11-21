# P2｜实时并排与富媒体内容

交付阅读 `SKILL.md`／科研文档时的可用富内容预览，同时保证一个文件标签、一份源码和清晰的安全边界。

## 技术决定

- Markdown 全部使用 **Textual／SwiftUI 原生 View**；不在 Markdown 页面引入 `WKWebView`，也不复制现有 Browser 进程。
  静态 HTML 从 Markdown 结构中提取并交给 **SwiftSoup 2.14.4** 自定义 allowlist，能映射为 SwiftUI 的 `details`、`img`、`audio`、`video` 等受限组件；未支持节点原样可读，不执行 JavaScript／外链。
- 相对 PNG/JPEG/HEIC/WebP/GIF 由现有 **ImageIO＋Core Graphics** 按需解码；SVG 使用独立 SVG Plan 选定的 **SwiftDraw 0.30.0** 原生图像表示。
  嵌入音视频复用 **AVFoundation／AVKit**，不安装音视频播放器 SPM。
- Mermaid 选 **[MermaidKit 2.10.2](https://github.com/2389-research/MermaidKit)** 的 `MermaidRender` 原生渲染（`MermaidRenderer.image`／`altText`），不打包 Mermaid.js，也不运行 JS。
  隔离工程已实际生成流程、时序、类与状态图，但其语法覆盖与 mermaid.js 不完全一致；unsupported diagram 原样回显，必须以真实 Markdown 样本验收。
- 公式优先使用 Textual 已依赖的 `SwiftUIMath`（`.math` syntax extension），不再引入 KaTeX、MathJax 或第二套公式引擎；脚注锚点若 Foundation parser 丢失，交给 P1 的 AST 验证门槛。
  主 Markdown 结构仍在后台准备；Textual 的公开扩展需在主 actor 调用，只处理当前显示块内的有界公式片段。
- SwiftDraw、MermaidKit 已与 Textual、Yams、SwiftSoup 在隔离 Swift 6.4.2 工程组合编译通过，且真实 SVG 与四种 Mermaid 输出通过；**不是 Bailey App 已验收**。

## 方案

从 `FileTab.nativeTextStorage` 的原生编辑通知按版本采集快照，**后台 Foundation Markdown 解析 + 主 actor 提交已经准备好的 `AttributedString`**（自定义 Textual `MarkupParser`），不在 SwiftUI 每次重绘时重新同步解析全文；合并连续输入并取消过时请求。
显示用不可变版本快照，不持有第二份可写内容。
视图模式归同一 `FileTab`，不创建第二份源码或 Dock 标签。
由于仓库 `AGENTS.md` 要求 `DockNode` 是唯一外层分屏真源，实施并排时先核对现有 Dock 交互，**不得新增一套标签内部的通用 Splitter**；必须让源码／预览两个展示者共用一个 FileTab，并由外层 Dock 布局负责其几何与激活。若现有 Dock 只能显示不同标签，P2-T1 必须在其唯一布局模型中解决同内容双展示，而不是创建两个可写副本。
静态资源的归属及相对引用、SSH 目录身份检查由现有文件 IO 真源负责。
MermaidKit 从代码围栏输入直接产出受控原生图像；禁止嵌入 HTML 点击回调、脚本及外部资源。没有 JS 运行环境或网络加载路径。

## 任务

<a id="p2-t1"></a>
### P2-T1 实时渲染与位置／焦点恢复

- **位置**：`FileTab` 原生编辑通知、Markdown 渲染更新、`FileViewerView` 并排布局。
- **实施**：先验收 `DockNode` 下同一 FileTab 两种展示者的并排能力，不能引入内部独立分屏状态；再完成后台 Foundation 解析、输入合并、请求身份和版本检查，主 actor 只接收当前版本的预解析结果，缓存仅限于已验证的只读渲染快照；
  保护 IME、原生 Undo、选区、行号和滚动位置；渲染区就地标识错误而不污染源码。
- **验证**：500／5,000／20,000 行基准回归（纯解析与实际渲染单独测量）、快速输入、撤销、中文拼写组合、渲染过时结果、32 MiB 文件边界、跨 Dock／窗口、恢复、关闭以及资源文件变化；
  未授权文件和旧异步结果不进入新标签。

<a id="p2-t2"></a>
### P2-T2 原生保存、恢复和链接操作

- **位置**：`FileTab.save`、会话恢复、文件菜单／标签右键、`docs/features/editor.md`。
- **实施**：保存仍只写原生源码、保留编码／BOM／CRLF／外部版本检查；恢复按既有快照打开源码，
  持久化 Dock 布局时折叠临时预览位置，不修改会话格式。
  模式切换不保存；内部资源点击定位有权限的同项目文件，外链须显式交给 Browser。
- **验证**：源码→预览→源码后逐字节一致；并排编辑→`⌘S`→重开，含未保存关闭、多窗口同文件、只读、冲突、SSH、路径重命名及 VoiceOver。

<a id="p2-t3"></a>
### P2-T3 PNG／SVG、受限 HTML 与音视频嵌入

- **位置**：Markdown AST→显示快照、与 SVG／图片／音视频文件 viewer 共用的资源及安全读取路径。
- **实施**：`![...](image.png|plot.svg)` 与白名单 `img`、静态内联 `svg`；保留图像尺寸、alt 和 Retina；
  `details` 等静态 HTML、受限 `audio`／`video controls` 在文内播放，禁止 autoplay／远端拉流／脚本／事件处理。
  触发“在独立标签打开媒体”时调用现有文件打开动作；停用不可见媒体，避免文档后台有声播放。
- **验证**：所有已支持位图类型、SVG 内部渐变／滤镜与外链过滤，媒体流中断／范围读取／seek、未授权路径、相对资源变化、多个媒体并存及长文档内存上限。

<a id="p2-t4"></a>
### P2-T4 Mermaid 与常见文档扩展

- **位置**：Markdown fenced code 节点、离线 Mermaid 原生位图、数学与脚注排版。
- **实施**：以 P1 确认的 AST／围栏源范围提取 Mermaid，调用 `MermaidRenderer.renderImage(source:theme:)` 在后台生成原生图像并校验取消／版本；
  图表不启用 HTML 标签、交互链接或回调，禁止远端图像与字体；
  不支持／无效图显示原始围栏代码与可用的解析诊断；公式 `$…$`／`$$…$$` 复用 Textual/SwiftUIMath，脚注保留正确跳转，无 CDN。
- **验证**：真实多类型 Mermaid 样例、畸形 diagram、XSS／点击、资源引用、循环更新及大图性能；
  数学表达式、跨语言字符、脚注跳转、离线部署、渲染失败的无损源码回退。

## 阶段验收

宿主验证解析与原文数据安全；隔离 Bailey Dev 验证实际多内容文档、焦点、滚动／平移、动态菜单、原生字幕／音量、深浅主题及资源释放。
原型包含少量可操作示例，不冒充完整的标准解析器或 Mermaid 编译器。
