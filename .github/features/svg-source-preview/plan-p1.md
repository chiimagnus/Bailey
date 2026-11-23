# P1｜复用 Markdown 的 SVG 安全解析，提供真正矢量预览

SVG 文件默认以图形查看，可一键切源码；缩放必须保持矢量清晰度。
**不要为独立 SVG 再创建一套 XML 净化、SwiftDraw 解析或缩放手势。**

## 当前实现与技术决定

- `MarkdownResource.picture` 及 `MarkdownHTMLImage.svgPicture` 已调用
  `SVGArtwork.render`；它通过 `SVGArtwork.sanitizedXML → SwiftDraw.SVG`
  净化与解析 SVG，再在 Core Graphics 位图中渲染。
  白名单、禁外链／脚本／DOCTYPE、深度 48、节点 4096、输入 1 MiB 是**目前真实安全边界**。
  不能跳过净化直接将文件交给另一个 SVG parser，也不能为独立文件另写不一致的过滤规则。
- 现有 `SVGArtwork.render` 的输出最长约 2048px，是 Markdown 内嵌所需的受限栅格，
  **不是高倍矢量文件查看器**。在这一现有类型中复用安全净化后的 SwiftDraw 解析结果；
  文件查看在视口和当前倍率下由同一 SVG 内容矢量重绘，Markdown 继续使用其有界栅格。
  已核对当前 SwiftDraw 包中的公开 `SVGView(svg:)`：它使用 SwiftUI `Canvas` 绘制原生 SVG，
  还能复用 Core Graphics `CGContext.draw(svg, in:)`。
  首选将现成 SVGView 安放在共用的原生滚动／缩放视口；
  先做 100%／400%、不同屏幕倍率的实际像素实验，
  若 SwiftUI 承载导致额外位图缩放，只改这一绘制适配层，不另建 SVG parser／备份 renderer。
- 文件 `.svg` 仍由 `FileTab` 读取为 `.text`，文本、BOM、编码、Undo 和外部版本归 TextKit。
  共享 [图片 P1 的唯一原生缩放视口](../image-annotations/plan-p1.md#p1-t1)，
  直接接入 `PreviewScrollView`，不增加另一套缩放控件。
  复用 [文件预览共用 Dock／菜单](../file-viewer-routing/plan-p1.md#p1-t2)，默认图形。
- 文件大小不等于 XML 可安全解析大小。独立源码可打开到 32 MiB，
  现有净化器只允许 1 MiB 的内嵌 SVG；需要放宽独立文件限制时，
  应在**相同净化入口**实测 CPU／内存、深度、节点和恶意输入预算，
  再决定明确的限值，不能复制代码或无条件放开；不支持的内容保留源码与可读提示。

## 任务

<a id="p1-t1"></a>
### P1-T1 复用 SVG 净化与 SwiftDraw，确认复杂 SVG 能力

- **位置**：`SVGArtwork.sanitizedXML / render`、`FileViewerView` 的 `.text`，
  新增 SVG 文件内容接入与 SVG 安全、视觉宿主测试。
- **实施**：用同一净化后的文档生成原生矢量展示，不另造 parser／安全白名单。
  独立 SVG 以 `FileTab` 已解码的当前文字快照作为输入，
  转成内存 XML 给同一净化器，不能绕开 TextFileEncoding 读取源字节第二次，
  也不能将 XML 解析后的归一化文本写回原文件。
  在 SVG 语法无效或目前不支持的高级功能下保持源码、清楚提示，
  不以 WebKit、外网或不安全的 SVG 内联资源作暗中 fallback。
  当前净化白名单会**静默移除** `pattern`、`use`、`symbol`、内嵌 `image` 等节点，
  仅展示 SVG 不足以知道原图缺了什么；应由现有净化遍历同步报告实际剔除的特性，
  让独立文件预览能明确提示，不再对 SVG 做第二遍诊断解析。
  若决定支持，沿**现有**净化器谨慎补全并同步 Markdown 安全回归，
  不另设一套宽松的独立 SVG 规则。
  确认 `clipPath`、mask、filter、pattern、渐变、文字／字体和大路径在 SwiftDraw 中的真实表现；
  SwiftDraw `SVGView` 对滤镜采用异步填充的 Canvas 缓存，
  首帧可能尚未应用滤镜：验证应比较最终滤镜收敛后的可见像素，
  并在当前文档版本改变时核对不会绘制上一个 SVG 的缓存。
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

### SVG 专项验收矩阵（P1）

同时执行[共用 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)的适用路径；
用仓库 `demo-plot.svg`、真实科研绘图及可控生成夹具，
**正常图对照实际像素，危险图核对最终无外部 IO 和可读错误**。

| 编号 | 实际输入 | 判据 |
| --- | --- | --- |
| S01 基本几何 | `viewBox` 原点为 0／负值／非零、`preserveAspectRatio`、横竖比变化、旋转／嵌套 transform、透明、曲线与超大坐标。 | 100% 和放大后内容、裁剪区域、alpha 与参考一致；不能只凭 SwiftDraw.SVG 创建成功判断完整。 |
| S02 真实科研元素 | `clipPath`、mask、linear/radial gradient、filter 与 blur／drop-shadow、text／中文字体、嵌套 defs、pattern／use／symbol／image、复杂 path。 | 使用已有净化器后的结果与可信 SVG 参考比较；当前白名单移除的元素必须明确告知，不允许展示**漏内容却不报错**的“成功”图。 |
| S03 XML 与格式 | UTF-8、UTF-8 BOM、UTF-16、用户选择的其它已有编码、XML 声明匹配／不匹配、坏字节、截断／未闭合标签、空 SVG、非 SVG XML、SVGZ 候选。 | 只按 TextFileEncoding 的**同一文本快照**安全解析；无损切回原文，坏 XML 无可执行内容，SVGZ 若不支持须明确而非伪解析。 |
| S04 实际限制 | XML `1 MiB-1/1 MiB/1 MiB+1`，深度 48／49、节点 4096／4097、数十万个 path 命令／长字符串、0／NaN／无限或极端宽高、恶意滤镜尺寸。 | 默认内嵌限额与净化规则始终有效；放宽独立 SVG 上限必须先测吞吐和内存，不能把 32 MiB 可编辑源码误当 32 MiB SVG 都可安全渲染。 |
| S05 主动内容 | DTD／外部实体、XInclude、script、onload/onclick、`foreignObject`、`xlink:href`、`url(file/http/data/../...)`、CSS `@import` 与混合大小写／命名空间。 | 同一 `SVGArtwork.sanitizedXML` 禁止不允许的节点／引用；本机隔离资源监听与越界文件不发生读写；Markdown 内嵌同样被保护。 |
| S06 输出质量 | `SVGView(svg:)` 在 1×／2×、100%／400%、fit、深浅背景／窗口移动、不同屏幕刷新率及滤镜异步缓存首次填充时对照。 | 变倍率触发真实矢量重绘、最终滤镜像素收敛，不用 2048px 栅格放大；旧缓存不能覆盖别的 SVG，慢滤镜不长时间卡住主线程。 |
| S07 模式与权限 | 默认 SVG 文件图形、源码／预览／并排、伪 `.svg`、Finder 本机与 SSH 同名源、断线／重连、大小写后缀、改名为 `.txt` 和返回。 | 只存在一份原文／Undo，菜单操作正确文件；不合法预览 companion 随格式变化被收回；绝不因净化失败修改原文。 |
| S08 复用及生命周期 | 同一个 SVG 作为独立文件、Markdown 资源、HTML 静态资源（由 WebKit CSP 负责）；大图反复缩放、100 次打开／关闭、改主题与窗口切换。 | 独立文件与 Markdown 共用解析净化安全规则，HTML 不假装共用 SwiftDraw 的页面渲染；对象、滤镜缓存和内存按实际文件生命周期释放。 |

必须交叉 S02×S06、S03×S04、S04×S05、S05×S07、S06×S08、R03×S05。
先完成有可信样本的精确视觉差异对照，再判定哪些 SVG 特性确需扩展**同一**净化／绘制实现；
不为了“绕过不支持”引入 WebKit、外链或第二套 SVG parser。
