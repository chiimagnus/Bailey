# P1｜复用 Markdown 的 SVG 安全解析，提供真正矢量预览

SVG 文件默认以图形查看，可一键切源码；缩放必须保持矢量清晰度。
**不要为独立 SVG 再创建一套 XML 净化、SwiftDraw 解析或缩放手势。**

## 当前实现与技术决定

- `MarkdownResource.picture` 及 `MarkdownHTMLImage.svgPicture` 已调用
  `MarkdownSVG.render`；它通过 `MarkdownSVG.sanitizedXML → SwiftDraw.SVG`
  净化与解析 SVG，再在 Core Graphics 位图中渲染。
  白名单、禁外链／脚本／DOCTYPE、深度 48、节点 4096、输入 1 MiB 是**目前真实安全边界**。
  不能跳过净化直接将文件交给另一个 SVG parser，也不能为独立文件另写不一致的过滤规则。
- 现有 `MarkdownSVG.render` 的输出最长约 2048px，是 Markdown 内嵌所需的受限栅格，
  **不是高倍矢量文件查看器**。在这一现有类型中复用安全净化后的 SwiftDraw 解析结果；
  文件查看在视口和当前倍率下由同一 SVG 内容矢量重绘，Markdown 继续使用其有界栅格。
  先用实际 `SwiftDraw.SVGView`／Core Graphics 组件测试选择最短可用原生绘制路径，
  不能凭名称假定 SVGView 在高倍时仍保留矢量质量，也不额外引入 WebKit。
- 文件 `.svg` 仍由 `FileTab` 读取为 `.text`，文本、BOM、编码、Undo 和外部版本归 TextKit。
  共享 [图片 P1 的唯一原生缩放视口](../image-annotations/plan-p1.md#p1-t1)，
  不复制 `MarkdownImageInspector` 的旧 SwiftUI 手势或增加另一套缩放控件。
  复用 [文件预览共用 Dock／菜单](../file-viewer-routing/plan-p1.md#p1-t2)，默认图形。
- 文件大小不等于 XML 可安全解析大小。独立源码可打开到 32 MiB，
  现有净化器只允许 1 MiB 的内嵌 SVG；需要放宽独立文件限制时，
  应在**相同净化入口**实测 CPU／内存、深度、节点和恶意输入预算，
  再决定明确的限值，不能复制代码或无条件放开；不支持的内容保留源码与可读提示。

## 任务

<a id="p1-t1"></a>
### P1-T1 复用 SVG 净化与 SwiftDraw，确认复杂 SVG 能力

- **位置**：`MarkdownSVG.sanitizedXML / render`、`FileViewerView` 的 `.text`，
  新增 SVG 文件内容接入与 SVG 安全、视觉宿主测试。
- **实施**：用同一净化后的文档生成原生矢量展示，不另造 parser／安全白名单。
  在 SVG 语法无效或目前不支持的高级功能下保持源码、清楚提示，
  不以 WebKit、外网或不安全的 SVG 内联资源作暗中 fallback。
  当前净化白名单会移除 `pattern`、`use`、`symbol`、内嵌 `image` 等节点，
  因此必须明确这些输入的可见结果；若决定支持，沿**现有**净化器谨慎补全并同步 Markdown 安全回归，
  不另设一套宽松的独立 SVG 规则。
  确认 `clipPath`、mask、filter、pattern、渐变、文字／字体和大路径在 SwiftDraw 中的真实表现；
  格式支持差异只能按证据提示，不能以“有渲染结果”推断视觉正确。
  新能力就绪时删除被替代的旧 SVG 视图／重复净化分支，Markdown 的合法内嵌输出必须仍可用。
- **验证**：`demo-plot.svg`、真实科研 SVG、标准与恶意 XML，
  viewBox／旋转／透明、剪裁与负坐标、复杂文本、深层嵌套、实体／外链／style URL、
  符号链接／本机和 SSH 同名资源、1MiB 与 32MiB 附近／超限、取消和快速改写。
  和可确认的参考图按实际像素与可见范围逐项比对，不因渲染失败清空有效源码。

<a id="p1-t2"></a>
### P1-T2 接入共用图形视口和源码／预览／并排命令

- **依赖**：图片 P1-T1 的共用 NSScrollView 视口能力，与文件路由 P1-T2 的通用模式接入同步。
- **位置**：共用图片缩放视口、`FileViewerView`、`Project`／`DockWorkspaceModel`、
  `WorkspaceWindowModel`／`BaileyApp.swift`、文件标签右键及 `docs/features/editor.md`。
- **实施**：默认 fit 矢量图，可切源码／预览／并排，滚轮、捏合和拖拽沿共用视口；
  重绘基于当前视口实际 backing scale 而非放大 Markdown 的 2048px 位图。
  File 菜单 `⌘⇧V` 仅一个，右键只作用命中标签；无永久缩放／编码栏。
  接线当场删除任何被替代的 SVG 专用模式、Dock companion 或旧图片缩放实现。
- **验证**：本机触控板、鼠标、光标锚点、双击 fit／100%／400%、
  不同屏幕倍率与窄 Dock、源文件焦点／IME、后台右键目标、多窗口与标签恢复。
  确认 SVG 放大仍清晰，Markdown 内嵌 SVG 不退化。

## 阶段验收

新增 `SVG` 净化／SwiftDraw 像素和原生视口宿主测试，回归
`SwiftMarkdownNativeTests`、`MarkdownResourceScopeTests`、`FileTabPersistenceTests`，
`make build`、阶段 `make test` 和隔离 Bailey Dev 图形、鼠标、菜单实际行为。
要检查无脚本／远程访问、源字节不变、错误回源码、取消与重挂载释放；
对未支持的滤镜、字体或恶意输入列明能力差异，不能声称 SVG 与浏览器实现等价。
