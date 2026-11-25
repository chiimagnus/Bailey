# P3｜GitHub 文件语义完整性与源码链接导航

让 Markdown 预览正确呈现 GitHub 仓库文件的静态内容，原生源码可 ⌘点击链接和路径，
预览可查找。保留同一个 FileTab、TextKit 文本缓冲、Undo、保存及 Dock。

## 根因与方案

| 实际缺口 | 负责修复的位置 |
| --- | --- |
| 行内 HTML 在绘制／复制时重新匹配标签；块 HTML 另经 SwiftSoup，单行音视频用 paragraph.format() 再解析 | MarkdownDocument 的 AST 投影与 MarkdownHTML 的静态语义；渲染、复制只消费同一结果 |
| HTML 解析要求顶层元素命中白名单，注释单独成块会回退原文；超过深度返回空数组，可能静默丢失子树 | MarkdownHTML.parse/render，区分有意隐藏、有效静态内容与无法解析／超限 |
| Markdown 与 HTML 图片各有加载任务，富内容拆分丢失外层链接；Mermaid 仅按 colorScheme 启动任务 | MarkdownResourceImage、MarkdownNativeImage、MarkdownMixedParagraph、MarkdownMermaidView 的真实资源及布局所有者 |
| GFM 扩展自动链接未启用；脚注仅取首段；标题锚点只覆盖顶层 heading，HTML 锚点无入口 | 锁定 swift-markdown 0.9.0／swift-cmark 0.9.0 的实际 API、MarkdownDocument、MarkdownFootnotes 与目标定位 |
| SourceTextEditor 无导航；预览和大纲分别解析；链接打开只检查 key window／项目，异步后使用当前 activeGroupID | FileTab 的语义快照，原生源码命中及 Project.openMarkdownLink 的显式来源、目标与动作 |
| Markdown 预览无 Find；单预览和并排 companion 的查找当前均被禁用 | WorkspaceWindowModel 的当前 Dock 表面分发和原生阅读器 |

保留 `9d8fa6f9` 的 swift-markdown＋原生 SwiftUI 路线、
`d5d145d5` 的统一阅读选区、`ed83419d` 的 SwiftSoup 原文映射、
`877429d3` 的媒体坐标、`0743dd15`／`dce36f98` 的真实阅读锚点及 `3028bd65` 的代码行尾显示修复。
不恢复 Textual、MarkdownView 或 Markdown WebKit；不增加第二个可写正文、全局 LinkManager、HTML/CSS/JS 引擎或通用 DOM。

以 [GFM 规范](https://github.github.com/gfm/)、
[GitHub 基础语法](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax)、
[折叠结构](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/organizing-information-with-collapsed-sections)、
[GitHub Markup](https://github.com/github/markup) 为基准。
GFM、GitHub 静态过滤和站内服务是不同层次；官方 Markup 也不包含完整站点净化器。
先用已公开或合成的 .md 文件确认候选标签及属性实际效果；不上传私有资料，不照抄旧净化器列表。
外网图片不自动加载，MDX 不执行，Issue／PR 服务、跨仓库／分支的网络资源、GeoJSON／TopoJSON 地图及 STL 交互不在本阶段；
这些与 GitHub 网站的差异明确降级，不宣称完全复刻 GitHub.com。
不为尚无需求的地图、3D、脚本或样式引擎新增依赖。

各任务从实际入口独立交付，替换即删除旧代码与旧测试预期，按
[最小实现审查](../../../docs/testing.md#完成标准) 复验。未证明冗余的安全、数据完整性及资源限制不删除。

## 任务

<a id="p3-t1"></a>
### P3-T1 统一原生 HTML 语义、格式与原文映射

**位置：** MarkdownDocument.parse/project/projectInline、MarkdownHTML.parse/render/groupedForPresentation、
MarkdownNativeText.make/linkedText/attributed、MarkdownHTMLContent.inlineText/styledText、MarkdownSelectionText.visible，
以及 Vendor/SwiftSoup 的 TextNode.originalTextSegments 与既有 MarkdownHTMLByteMapping。

- Swift-markdown 仍负责原始 AST。HTMLBlock 从原 rawHTML 与源区间进入 SwiftSoup；
  InlineHTML 在投影时按实际标签和原 Markdown 子节点归组，纯 HTML 岛复用 SwiftSoup，
  混合强调／链接／代码时保留原 AST 和原始坐标。先用跨 AST 子节点、跨行、嵌套列表及表格的实际输入
  验证归组方法和 SwiftSoup 源区间，不重新格式化 Markdown 或将整个文档转 HTML。
  仅需要标签局部范围时沿 AST token／SwiftSoup 已有源区间取得，不为属性另写全量 tokenizer。MarkdownDocument.project 目前未知节点以 node.format() 回退；
  有原始范围时直接保留原始片段，避免格式化后字形无法回源，禁止退化路径悄悄规范化原文。
- 统一已核实的静态语义：sub/sup、ins、br、注释、pre/code、现有 strong/em/s/del/kbd/a/span 等；
  检查 GitHub 实际允许的 u/strike/tt/samp/var/abbr/mark/small/ruby/rt/rp/cite/q/dfn/time/wbr
  等候选格式及属性，逐项确认后映射到原生可见语义。
  文本折叠普通 HTML 空白，但保留 pre 原有空格／换行；对 CRLF、实体、转义、注释、未知／MDX 标签、
  无效闭合、重复属性、script/style/iframe/事件属性分别处理，不能执行或混入普通可见复制。
  不支持的静态格式可保留可见子内容并提示；MDX 和源码示例不被当作未知网页吞掉。
- 修复 MarkdownHTML.parse 的顶层白名单 guard：解析成功但有意不可见（例如注释）返回空节点，
  不是 .rawHTML；只在无法安全表达／解析失败／超限时保留明确可读的源码退化。
  保留实际必要的字节及深度预算；到达限制不静默丢弃子树。
  源码链接和媒体的范围至少有准确原始 token，实体、上下标、emoji 等显示变换沿已有区间映射，
  不用原文字符串搜索或伪造等长坐标；区分真正的可见字形与用于复制的合成分隔符。
- 渲染、标题可见文字、语义复制和实际链接标记共享格式与源区间；保留 SwiftUI 原生 Text、
  MarkdownSourceGlyph、链接拖选、真实 UTF-16 回源，所有段落／标题／引用／列表／表格入口一起接入。
  文本样式采用同一现有主题来源，不另造 HTML 样式表。初始设计不引入新 DOM 或全量扁平缓存。
- **同任务清理**：迁移后删除 MarkdownInlineHTML.scan、ActiveHTML、validLink 的伪造标签再解析、
  MarkdownSelectionText 的第二次标签识别，替换 paragraph.format() 音视频特判。
  删除 MarkdownHTML.supported 与 render 分支重复的顶层白名单预筛；
  合并两套 inline 格式和链接候选解释中确实重复的部分，最终打开权限仍归实际动作入口；
  MarkdownNativeText.attributed 仍被生产代码使用，不误删。
  未出现真实失败时不增加标签修复重试、兼容解析器或第二套选择。
- **验收 M01**：SwiftMarkdownNativeTests、SwiftMarkdownSelectionTests、SwiftMarkdownLayoutTests、
  MarkdownInlineHTMLUITests。复现注释回退／深度丢失及同一标签跨容器的不一致；
  验证实际文字、格式、可见复制、命中、AX、真实源码范围及无请求／执行。

<a id="p3-t2"></a>
### P3-T2 完整静态结构、图片链接与富内容混排

**位置：** MarkdownHTML.render/groupedForPresentation、MarkdownHTMLContent、
MarkdownMixedParagraph、MarkdownResourceImage、MarkdownHTMLImage、MarkdownNativeImage、
MarkdownMediaView、PreviewResource.relativePath/read/resolvedFile 与 Project.openMarkdownLink。

- 补齐 GitHub 实际支持的 details/summary、picture/source/img、链接包裹图片、
  HTML 标题、列表、表格、caption、thead/tbody/tfoot、align、rowspan/colspan、dl/dt/dd、figure/figcaption 等。
  对照真实语义后实现必要的原生结构，不猜测百分比／CSS 或支持任意属性；
  table span 先复用 SwiftUI Grid 的实际能力，不能表达时才在现有表格内补最小布局，
  不预建通用 HTML 排版器。图片尺寸、列表编号、表头、空格、嵌套和 alt 均保留。
  details 使用真正的 summary 内容及源范围而非 summary.text()；
  按 GitHub 空行规则保留其中 Markdown AST，不再把整个容器当 HTML 纯文本。
  展开状态归现有阅读器；修复 MarkdownPreview.onChange(revision) 无条件清空展开状态，
  对未受编辑影响且能证明身份的 disclosure 保留状态，不能证明则按原生初始状态恢复，
  不建立持久详情历史或 ID 数据库。
- **资源路径在本任务接通**：现有 PreviewResource.read(URL) 与 resolvedFile(URL) 都使用 relativePath，
  当前拒绝以 / 开头及带 query 的地址。GitHub 文件链接和图片的 / 路径以实际仓库根为准；
  只在当前文档确有根引用时经其 backend 的 GitCommandExecution.run([rev-parse, --show-toplevel], in: ...)
  确认根并在本次文件有效目标内共享结果，不能用 customDirectory 或 Git 面板状态猜测。
  根解析与后续资源访问不扩大 FileTab.previewResource 授权的目录；
  Finder 文件仍按真实本机身份，不借用 SSH 根；分支／跨仓库网络引用不解释为本机路径。
  不在普通相对引用／每次 Hover 时执行 Git。Markdown URL 路径解码一次，fragment、query 独立，
  M05 检查 lexical 归一化与 symlink/..、授权与实际读取间替换路径的语义；
  可复现的授权失效在 PreviewResource 或实际 backend IO 归属修复，不在每个图片／链接入口添加重复 guard。
  本机保留 fd 实际路径／regularFileStat 校验；远端不能用仅检查 realpath 成功代替实际读取身份。
  raw=true 等已核实的本地静态引用不成为文件名。
  独立 HTML 的 read(path:) 与 CSS 相对语义保持不变；T4 源码导航复用同一解析及权限边界。
- **单一图片链**：MarkdownHTMLImage 当前 file 分支与 MarkdownResourceImage 重复维护 picture/loaded、
  .task 和 resource.picture；HTML img 与 picture 直接复用 MarkdownResourceImage，
  内联 SVG 仍走 SVGArtwork 的既有处理，不为此新增通用资产加载器。
  picture 只按当前有效明暗条件选 source 或 img fallback，尊重当前 App 主题，
  不预取所有候选；原始 sourceRange 从 T1 贯通实际图像边界和 AX。
  外网资源不自动请求，普通和 HTML 图片都显示 alt／失败状态与明确的主动查看入口；
  已有外层链接的图片即使加载失败，主点击仍走外层目标。独立可读取图片保持现有打开与缩放操作，
  不用 Button 包含另一个图片 Button；通过既有原生上下文动作查看图像自身。
- MarkdownMixedParagraph.segments 将 image/math 单独提取时保留外层 link 及相关格式；
  ViewThatFits 目前在宽度不足时把整段转为 VStack。先用一个长段落包含短图、
  行内公式和链接的真实窄窗夹具确认原生换行、baseline、点击与源码坐标。
  优先利用现有 Text 布局及最小的富内容行布局，只有复现确实需要时才替换整段双布局，
  不为了混排另做文字排版／选择／滚动引擎。
- 核对资源任务按真正变化的 source、当前目标身份与 refresh 更新；资源替换、重复 URL、
  主题及后端变化不能发布旧图。MarkdownMediaView 的播放、暂存与退役沿现有授权链，
  对同 URL 更换内容／断线／重挂载的实际失败再修复，不引入全页媒体缓存或自动重试。
  MarkdownHTML 当前按后缀选择 media kind，但 NativeMedia.open 已提供真实 kind；
  不以声明／后缀把音频误呈现为视频，失败回退或选择经验证可播放的实际候选，复用 NativeMedia 的能力。
- **同任务清理**：删除 MarkdownHTMLImage.file 的重复加载任务与状态、丢失 link 的拆分逻辑、
  被替代的 HStack/VStack 双布局（仅在新布局实际覆盖全部入口时）；
  保留 SVG 净化、图片／GIF 像素预算、媒体主动加载及真实后端限制。
  现有 Markdown/HTML 表格只共享确实同义的视图代码，不重写 GFM AST 或强行统一结构。
- **验收 M02/M05/M06**：SwiftMarkdownNativeTests、SwiftMarkdownLayoutTests、SwiftMarkdownSelectionTests、
  MarkdownResourceScopeTests、HTMLFilePreviewTests、SVGArtworkTests、NativeMediaFileTests、MarkdownPreviewUITests、
  MarkdownSelectionBoundaryUITests；核对实际图像、点击、回源、表格、展开、原文和无额外网络请求。
  本任务完成根路径的预览图片／媒体／链接入口，不留到 T4 才通过。

<a id="p3-t3"></a>
### P3-T3 GitHub 文档锚点、脚注及其余语义兼容

**位置：** MarkdownDocument.parse/headingOutline/MarkdownBlockIndex、MarkdownFootnotes、
MarkdownMath、MarkdownMermaid、MarkdownPreview 的 fragment 与实际坐标导航。
依赖版本以 Package.resolved 及已安装 checkout 为准。

- **解析器边界**：锁定 swift-markdown 0.9.0 的 CommonMarkConverter.parseString
  仅 attach table/strikethrough/tasklist，没有 autolink；ParseOptions 没有该开关。
  先用 GFM 自动链接全部规范例核对裸 www/http(s)/邮件、尾部标点、转义、代码、
  已有链接和源范围，不把缺失归咎于渲染器。优先已安装解析器／公开能力；
  如确需改依赖，仅在隔离副本试验最小 autolink 扩展接入，验证 Link AST 和原 UTF-16 区间、
  原有 GFM 及构建，再比较与在现有 prose 投影中补齐缺失语义的成本；
  选一个最小正确实现。禁止改 .build 缓存当作正式修复、双 parser 或仅用 URL 正则冒充 GFM。
  底层 swift-cmark 已定义 CMARK_OPT_FOOTNOTES，但 Swift converter 未支持脚注节点，
  直接开启可能触发 Unknown cmark node fatalError；本阶段默认收敛现有 MarkdownFootnotes，
  不为开启一个 flag 预建整套 Swift AST fork。
- **锚点**：heading slug 从实际可见文字生成，核对 GitHub 空白、Unicode、emoji、标点、
  内联格式、重复及冲突后缀规则；保留现有线性分配策略（f09694c0）。
  支持已核实的 HTML <a name="..."></a> 自定义锚点，与标题编号分开；
  不能因为 id 属性能被 HTML parser 读到就假定 GitHub 允许它。
  目标是当前快照里的原文区间／真实结构位置；同页、跨文件、嵌套标题及折叠 details
  都能揭示实际祖先并定位；自定义锚点不进入大纲。MarkdownBlockIndex.block(atUTF16Offset:)
  是就近阅读定位，不能用它的近邻回退当作精确命中或不存在锚点的成功。
  所有导航、复制标题链接、脚注与大纲使用同一目标解释，不添加第二套可写锚点状态。
  MarkdownPreview 的同页 openURL 当前绕过 MarkdownFilePreview.openLink 的版本检查；
  本任务即让旧快照只能显示，不能执行同页跳转或展开，复用现有 request 判定。
- **脚注**：现有 MarkdownFootnotes 的 ignoredLines、ASCII 名称 regex、连续缩进行以及
  parse 中仅取首个 Paragraph 会漏掉多段定义及部分原文；按 GitHub 实际规则处理完整定义
  和引用，复用 MarkdownOriginalCoordinates/MarkdownSourceRewrite 与原 AST 投影。
  保留定义内部的段落、列表、代码、公式和链接及每个引用的真实位置；
  脚注往返定位不能再依赖伪造 URL 字符串（#bailey-note: / #bailey-return: 可与真实锚点碰撞）。
  优先现有内部语义目标而非新增自定义 URL scheme／全局注册表；不支持或未定义保留实际文字。
  既有 MarkdownMath 的 TeX 保护规则继续使用，脚注中同样采用真实源映射，不以临时拼接文本猜位置。
  脚注按引用顺序附在正文后，源区间不一定按阅读顺序单调；MarkdownReaderCoordinates 的单一 NSRange
  与 MarkdownSelectionText.copy 的源区间相交目前可能选入不在实际拖动范围中的正文。
  用真实逆序脚注拖选确认后，在阅读选区的唯一所有者区分阅读顺序与原文区间，
  复用已有字形及语义节点；只在确需跨非单调片段时扩展现有选区表达，不为它另建选区引擎。
  MarkdownMath.protect 目前遇到字面内部 token 前缀会跳过全篇保护；复现合法字面前缀与公式共存，
  修复 token 冲突根因，不再因此禁用整个文档。核对 GitHub math 围栏、混排及现有 TeX 边界，
  正确支持的语法复用当前 SwiftUIMath，不追加第二种公式渲染器。
- **其他 GFM**：核对全部适用规范例和 GitHub 文件语义，包括 table span 语义差异、
  软硬换行、列表、checkbox、Alerts、链接与转义；已由 swift-markdown 正确处理的部分不再实现。
  锁定版本启用了 CMARK_OPT_TABLE_SPANS，Table.Cell 已公开 colspan/rowspan，现有投影丢弃这两个字段；
  先核对标准 GFM 与该扩展的实际结果，保留确需支持的跨度语义，不另写表格语法。
  对 emoji shortcode 优先现有本地数据；无可复用数据时采用许可明确、可生成的小型 Unicode 映射，
  不引入运行时依赖、联网或逐字符扫描全量词典。未知、转义及代码中的 shortcode 保持字面。
  GitHub 文档确认 GeoJSON、TopoJSON、ASCII STL 也可渲染
  （[图表说明](https://docs.github.com/en/get-started/writing-on-github/working-with-advanced-formatting/creating-diagrams)），
  本阶段不加入地图／3D 引擎，保留代码显示并明确限制。
- **Mermaid 实际根因与简化**：已安装 MermaidKit 的 MermaidDiagram 有 30 种图型；
  MermaidRenderer.renderImage 经原生 parser、布局、CoreGraphics/ImageIO 输出图像，
  不是 WebKit 或 Mermaid.js；Flowchart parser 忽略 click，Gantt parser 也将 click 当非任务指令。
  当前 MarkdownMermaidView.task(id: colorScheme) 缺少 source，
  同位置围栏被修改时会保留旧图；以实际图源＋当前有效主题为请求身份，
  取消旧结果并保留真实阅读锚点，错误时使用已有源码回退，避免新旧图同时显示。
  Mermaid 的报错行号当前来自去掉 Front Matter 的 AST；用投影后真实 Block.line／sourceRange，
  复验 BOM、CRLF、脚注重写和嵌套图表，不在视图层另加行号偏移猜测。
  图表主题由 MarkdownReaderColors/Theme 派生，删除固定 GitHub 明暗 RGB 及自定义备用调色板；
  图型按锁定依赖真实支持全集验证，未支持的语法明确回退，不因旧限制误拒已支持图型。
  依赖已有 maxTextSize=50000（字符）、flowchart maxEdges=500 与 NSCache 的 64 MiB costLimit（不是硬内存上限）。
  逐项审查 Bailey 16 KiB/160 行/1024 字节行长及 click/link/links 首词拒绝：
  先用静态合法图、长行、恶意指令和真实复杂度验证依赖实际可达行为。
  如原生渲染确无回调／URL 副作用，删除宽泛首词拦截，允许静态语义而不执行指令；
  旧 nil 断言迁移为无执行／无外链和正确图像。保留依赖未覆盖的真实资源约束；
  仅经实测峰值／取消／输出尺寸证明等价后移除多余字节、行数限制，不预建第三套预算或缓存。
- **同任务清理**：删除被替代的顶层 heading-only fragment 查找、脚注首段／首引用硬编码及 attributed 中依据伪造 URL 的编号样式、
  重复解析或手写坐标、已证实冗余的 Mermaid 拦截及旧主题路径。
  不删除仍服务于编辑位置的 MarkdownBlockIndex、实际 AST 保护或安全上限。
- **验收 M03/M06/M08**：SwiftMarkdownNativeTests、SwiftMarkdownMathPerformanceTests、
  SwiftMarkdownSelectionTests、SwiftMarkdownLayoutTests、MarkdownPreviewUITests、MarkdownMathUITests；
  对照实际 GitHub 文件语义与规范，先复现自动链接、脚注、重复锚点及图表源变化。
  Mermaid 使用依赖全部实际图型夹具，包含合法 link 指令／普通词、旧容量前后、依赖边界、
  无效源、取消及当前所有可选 App 主题；核对实际图形、源区间、剪贴板和无执行／外部请求。

<a id="p3-t4"></a>
### P3-T4 源码 ⌘点击、文件路径识别与统一导航

**位置：** FileTab.nativeStorageDidChange/installNativeDocument/retireContent/targetGeneration、
MarkdownDocument.parse、MarkdownFilePreview、MarkdownOutlineView、SourceTextEditor.Coordinator、
FocusReportingTextView、NativeCodeTextView、Project.openMarkdownLink/openFile、DockTabGroupView、
PreviewResource 与 T2/T3 的路径和锚点结果。

- **一次语义请求，多处使用**：把 MarkdownFilePreview 的 parsed/failed/task 与 MarkdownOutlineView
  独立 parse 迁入 FileTab，按现有 textPreviewRequestID 持有一份不可变语义结果及在途任务，
  preview/source/outline 消费该结果；派生 MarkdownBlockIndex 和 headingOutline 不再分别维护版本。
  一个请求内部保留 math／footnote 确有必要的条件解析遍次，不误写成「每版本只执行一次 cmark」。
  已打开预览按现有 150 ms 合并输入；只看源码且从不导航时不因每次键入强制建立富内容快照。
  预览、大纲和实际源码导航按需请求同一结果，优先在 ⌘ 导航意图出现时准备，
  冷 ⌘点击可等待当前请求完成，期间保留此次真实命中及身份；失效则取消，不能打开上版链接。
  不在每次鼠标移动、滚动或着色中重新解析，不因主题或资源 refresh 重做 AST。
  普通编辑可继续显示同一 fileContentRevision 的最后有效预览，但旧图不能提交导航、查找或源码定位。
  FileTab 目标变更、替换正文、扩展名变化和 retireContent 取消任务、释放快照及过期定位；
  重挂载复用有效结果，不持久化 AST，不新建通用缓存或 Manager。
- **识别真实来源**：Link/Image 的 AST destination 与准确原始 range（含完整／折叠／快捷引用）是主真源；
  T1 HTML 的 href/src 及 T3 自动链接沿同一投影。swift-markdown 不公开引用定义节点，
  已有 TreeSitterMarkdown grammar 的 link_reference_definition/link_destination 可提供定义范围，
  先确认原生语法服务的真实命中或在当前源位置按需查询现有语法，
  不从 syntax color 反推目标、不为定义再建长期 parser/cache，不把定义中的转义当字面路径。
  Markdown 语法之外仅按鼠标所在行／token 识别明确的 http(s)、相对路径、带引号／反引号的路径、
  bare POSIX 绝对路径、file: URL 和文件名；普通单词、公式、围栏内字面 Markdown 不当作文档语法。
  代码中明确路径可以主动打开，但不重新解释代码。含空格、括号、Unicode、% 字面量与 URL 编码区分。
  :line[:column] 先尝试真实完整路径，仅在不存在且数字后缀有效时尝试去后缀；
  行列按目标实际文本范围解析，复用 NativeTextLineIndex.offset(atLine:) 和 TextKit，
  不接受 0／负数／溢出、不将越界位置截到无关内容后宣称成功。
- **原生交互**：在 FocusReportingTextView／现有 SourceTextEditor.Coordinator 接入 Markdown 源码动作；
  NativeCodeTextView 是 Source/Diff 共用底座，只复用真实 TextKit 2 坐标接口。
  通过 characterIndex(for:) 与实际字形/行矩形核实命中，而非最近插入点；
  转换窗口坐标、滚动、折行及被截断的长行，空白／gutter／滚动条无命中。
  ⌘ 按住才显示手形及主题链接提示，松开、离开、失焦、源区间变化立即恢复。
  对语法明确的候选显示可操作提示；本机／SSH 文件存在性在实际打开时由后端确认，
  不在 hover 逐词 stat；失败明确提示，不把高亮颜色当授权结果。
  使用原生修饰键、tracking area、mouse down/up 与真实拖动判定，
  普通点击、多击、⌘拖选、Shift 选择、IME、右键及 Undo 保持原生输入，
  仅成功识别的 ⌘单击执行一次动作。可通过源码上下文菜单、键盘及 AX 触发同一动作。
  回调随 SourceTextEditor make/update/dismantle 和 retireObsoleteDocument 绑定／解除；
  不用全局 NSEvent monitor、透明覆盖层、修改正文 .link 属性或第二套语法着色。
- **统一导航**：改现有 Project.openMarkdownLink 与预览回调为同一真实文件动作入口，
  明确来源是源码还是预览、来源 DockItem/组及文件版本。Dock 的 canFocusGroup／focusGroup
  与当前 tab 归属负责发起许可，不允许后台窗或旧 companion 发起动作。
  捕获来源组、项目、文件版本、backend／机器及连接身份；异步授权后再次核对一次真实当前目标，
  不在多层重复相同 isCurrent()，也不以 key window 代替真实 Dock 目标。
  原有 request 变化、目录、连接及 FileTab membership 检查是实际不同的边界，
  复用 fileContentRevision/targetGeneration 与已有 SSHHostWorkspaces.connectionRevision，
  不新增平行 generation；动作取消后不再打开目标。
  新文件／Browser 从已确认的来源组打开，复用既有标签时选择其真实所在组而不移动标签；
  既有标签身份仍按 path+workspace，newBrowserTab 复用当前真实选中组的既有入口；
  用户后来切换标签／组／窗口，旧动作不抢焦点、不从事后 activeGroupID 取组。
  http(s) 明确点击走既有 Browser；GFM 邮件链接仅通过明确的 mailto 原生交接，不自动发信，
  不将其它任意 scheme 交给系统或执行脚本。
- **目标与路径**：同页锚点直接在当前源／阅读视图定位，避免走文件 IO；
  跨文件锚点及行列请求等待目标 FileTab 的实际内容版本就绪，通过既有 pendingMarkdownSource／
  pendingMarkdownFragment 和 locateMarkdownSource 的真实源码定位路径交付；
  已挂载编辑器立即按当前目标版本消费定位，未挂载时才由 pending 在挂载后消费；
  显式定位走 locateMarkdownSource，不受自动双向滚动开关限制。
  SourceTextEditor.makeNSView 当前在设置 restoreOnFirstLayout 前清空 pending，回调只 min(offset,length)，
  若其间编辑／更换目标会把过期位置截到新正文。真实首次布局、实际聚焦及消费时核对目标版本和身份，
  不把截断当成功；复用这一待定位机制支持普通文本行列，避免新增 Markdown 专属与通用定位双轨。
  必要时使用 Project.setFilePreviewMode／现有 Dock companion 显示对应面，
  不直接用 setFilePreview(true) 绕过并排状态，不因链接打开强制拆并排。
  T2 已统一仓库根／相对 Markdown URL；裸绝对路径／file: 是显式文件系统语义，
  不把 Markdown /assets 解释为 Mac 根路径，也不把裸 /Users/... 解释为 GitHub repo 根。
  不展开远端 tilde 到本机，不回退同名本机文件，不跟随越权 symlink。
  保留 PreviewResource 的实际授权及现有 backend confined read/checkConfinedFile；
  只允许真实文件，明确目录引用在当前阶段不创建文件标签；
  如需导航目录，使用已有 Files 目录入口而非另建树浏览器（现有 revealFile 只支持文件，
  不能把目录支持写成已具备；本阶段非目标）。未授权范围使用既有显式打开入口而非自动授权扩大。
  普通链接导航不主动保存草稿；沿现有失焦／切换自动保存设置，不承诺取消合法自动保存。
- **同任务清理**：删除 MarkdownFilePreview 与 MarkdownOutlineView 分别 parse 的旧任务和被共享结果替换的
  markdownOutlineRequest/markdownSourceIndex/markdownHeadingOutline 镜像存储；
  现有 collapsedHeadings/阅读及源码偏移保留真实归属。删除被统一动作取代的 preview-only 分支和
  只按项目／key window 判定的旧 isCurrent 入口；在执行边界保留必要身份检查，
  迁移仅测试硬编码「回调恰好两次」的断言，验证真实在途失效。
  不复刻 TerminalSession.existingFileURL 的本机 cwd／FileManager、不要新建 LinkManager。
- **验收 M04/M05/M06**：MarkdownResourceScopeTests（实际 SSH、Finder 同名隔离、旧目标编辑）、
  NativeEditorLayoutTests（现有 wrapped/unwrapped hit 与真实长行）、NativeEditorCompositionTests、
  NativeSyntaxHighlightingTests、TextCoordinateIndexTests、FileTabPersistenceTests、
  WindowOwnershipIntegrationTests、NativePaneRetentionIntegrationTests、MarkdownScrollPrecisionUITests；
  真实 App E2E 验证 ⌘点击、修饰键光标、Drag、目标文件／行列／锚点／Browser 可见、并排及跨窗。
  对同文档 preview/source/outline 计数共享请求，检查冷源码与未导航编辑成本、原生对象及草稿；
  不能只断言回调或 URL，验证实际目标归属、文件字节和读写路径。

<a id="p3-t5"></a>
### P3-T5 原生预览查找、命中定位与菜单焦点

**位置：** WorkspaceWindowModel.focusedPreviewFile/canFind/canReplace/performFindAction、
EditorFind.swift、MarkdownFilePreview、MarkdownPreview、MarkdownSelectionText、
MarkdownReaderCoordinates 与 MarkdownGlyphHit。

- 复用 Edit → Find 的 FindAction 和实际 Dock 表面判定：⌘F、⌘G／⇧⌘G、使用选区、Esc。
  源码仍由 NSTextFinder 负责查找和替换；Markdown 预览只读，替换置灰，即使源码并排挂载也不回落。
  SVG 等不支持的预览同样不应回落到源码（保留其现行真实能力），CSV／HTML／终端／Diff 按既有路由；
  共享表面判定只做一处，不为 Markdown 添加另一个主菜单或快捷键监听。
  FileTab 持有查找命令与查询状态，MarkdownPreview 持有实际结果、在途请求及字形坐标；
  不镜像查询和结果，关闭阅读面取消对应查找。参考 HTML/CSV 已有原生按需浮层与主题，
  不另建全局搜索服务。阅读器未挂载／仍解析中可显示准备状态，不能把 Find 发送至隐藏源文；
  收起浮层仅在当前有效 Dock/窗口恢复原生焦点。
- 复用 T1–T3 的真实可见内容和 MarkdownSelectionText.visible 语义遍历，
  构造当前查询所需的有界文本与实际映射；搜索全部已展开文档而非只搜 viewport。
  匹配可跨同一逻辑文字段的格式、链接、实体、软换行；不跨无关块、格或图像，
  不匹配隐藏 YAML、标签、折叠正文、已加载图片 alt／渲染公式的 TeX 或不可见标记。
  可见失败回退文字及实际 caption／代码／脚注可查找；生成的编号、分隔符或替代文字
  若没有真实字形及坐标，不作为可精确高亮的命中。明确不做 OCR。
  现有 MarkdownSelectionText.Piece 的 nil source 间隙推断只服务复制，
  不能拿它或整页剪贴板字符串反推搜索源区间。
  只有真实可见的合成文字（如 Emoji、实体、脚注编号）沿 T1–T3 的原文映射／实际字形定位，
  保持显示坐标和原文范围的区别；不为搜索另做全文渲染或屏外测量。
- 用当前文档版本、实际查询及 visibleBlockIndices/details 展开状态关联结果；
  图像／图表／公式实际失败回退时才将其可见文字纳入查询，恢复成功则移除；
  未布局或未加载的附件不猜测成失败文本，不为搜索触发额外 IO／全篇布局。
  复用资源视图的真实状态变化通知影响到的查询结果，不创建全篇资源状态镜像。
  复用现有 reader 的懒 row 定位、scroll(to:) 和 glyph hits 高亮，
  查找所有命中数、当前结果、前后环绕与无匹配；显示当前命中及可见范围其他匹配。
  不将查找选区写进 MarkdownReaderCoordinates.selectedRange 或源码 caret；
  共享现有 Canvas 的真实字形绘制，避免第二套选区或覆盖层抢事件。
  查询取消、编辑、展开、关闭和移动时清理过期结果，普通主题/滚动只重绘，不重新扫描；
  若主题选择改变 picture 候选或真实失败文字，则只因实际可见语义改变更新结果。
  空查询立即清除，不缓存整篇搜索文本直到标签关闭；首次打开/查询实际需要才准备，
  大文档使用后台查找并测内存，不能主线程先创建全篇副本再交后台。
- **同任务清理**：替换 canFind/canReplace 依赖 tabID 与 showsFilePreview 的表面推断，
  以当前实际表面一次判定命令目标；若共用现有表面判断即可解决，不新增分发表或协议。
  搜索与复制复用真实语义遍历，删除被替换的重复抽取代码，
  不能为精简删除复制用的附件语义、选区或原有 HTML/CSV Find。
- **验收 M07/M06/M08**：SwiftMarkdownSelectionTests、SwiftMarkdownLayoutTests、
  WindowOwnershipIntegrationTests、HTMLFilePreviewTests.testFindMenuTargetsReadOnlyHTMLPreviewRatherThanItsSource
  的现有宿主验证方式，以及 MarkdownPreviewUITests／MarkdownSelectionBoundaryUITests。
  先复现单独预览及并排预览 Find 均不可用；修复后确保并排不落回源码；检查匹配数、实际屏内高亮、真实第一响应者、
  下一处和上一处、使用选区、折叠与展开、无匹配、IME 查询、实时编辑和双窗。
  回归全部真实可达 Find 路由，保存字节、Undo 和原生编辑状态不变。

## 阶段验收

适用的 [P2 共同验收](plan-p2.md#p2-共同验收)、[R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)
及 [开发验收规范](../../../docs/testing.md#根因与回归覆盖) 全部保留。以下是 P3 的可执行专项条件，
各任务按自己的 M 编号核销；共享实现已有且未受影响的证据可以复用，不能替代本次改变的用户路径。
每项数值限制均测试临界值前／等于／后（N−1/N/N+1），以实施时真实单位和比较条件为准；
删除旧限制后仍验证原界限输入与更大的合法输入，不把无故拒绝当作安全通过。

### M01 静态 HTML 与原文投影（T1）

- 对经核实的每种标签／属性分别验证单独、连续、嵌套、跨 AST 子节点、行内与块级；
  在标题、段落、列表、引用、表格、链接内组合强调、上下标、下划线、实体、软硬换行、pre/code。
  覆盖普通／混合大小写、单双引号／无引号属性、属性顺序／重复／缺失、空标签、注释、错配与未闭合标签、
  合法隐式闭合及错误 HTML 修复后的真实源范围；检查 HTMLBlock 与 InlineHTML 交界、Markdown 空行和 MDX 字面表达式。
- Unicode 文本覆盖中文、日本语、RTL 与双向混排、组合音调、非 BMP、ZWJ、变体选择符、实体多码点、
  NBSP、tab、CR/LF/CRLF 混合及 U+2028/U+2029；重复文字、实体和转义必须逐字对应真实 UTF-16，
  不按归一化后字符串或最近偏移猜测。空白、隐藏注释、无字形节点与合成分隔符不产生虚假的选择／点击。
- 实测旧 InlineHTML 单标签 8192 字节、HTMLBlock 256 KiB、递归投影深度 32 的各侧；
  大量同层／深层节点、空子树、成对及不成对标签、超过预算后仍有尾部普通正文。
  对 script/style、iframe、事件属性、表单、外部 URL、未知／MDX 标签分别验证静态可见语义，
  不执行、不请求、不无声丢弃合法邻接内容；用隔离回环请求探针观察实际网络副作用，不只断言 parser 返回 nil。
- 判据：公开规范及明确对照样例的可见文字、格式、行距、真实原文区间、选择、剪贴板和 AX 一致；
  复制前后源缓冲与磁盘原字节不变。深层解析失败须在负责投影的路径有可读退化，不能吞掉子树。

### M02 富内容、静态布局及资源生命周期（T2）

- HTML details：无／空／带格式 summary、初始 open／closed、嵌套多层、两个相同标题、
  关闭子项后切父项、插入／删除前文、Undo/Redo、改变 open 属性、换主题、资产 refresh、模式切换与重挂载。
  核对实际展开内容、阅读坐标、隐藏正文不被复制或查找；非同一结构不能继承旧 disclosure 状态。
  picture：source 顺序、暗亮匹配／不匹配／无效 media、无 source、img fallback、空／缺失 alt、
  有效／损坏／越权候选，换同明暗主题、改图源及取消在途加载。带链接图片的成功／失败占位均可打开外层目标。
- 原生布局：已支持的表格跨度、列对齐、空格／缺格、caption、嵌套列表／表格、宽表横向滚动及长单元格；
  0/1/多行多列、极宽与长表；有／无显式尺寸的横竖图、HTML width/height 的 1 和 4096 两端，
  0、负值、溢出、非法单位以及已核实的百分比属性；同段多个图片、公式、链接与普通字形的换行、baseline、
  嵌套格式和拖选。检查水平滚动条、边缘裁切及实际点击区域，缩放不得放大错误的低分辨率替代物。
- 图片及 GIF：复用 ImageIO 实际类型识别与 SVGArtwork 测试，覆盖已支持的 PNG/JPEG/HEIC/WebP/GIF
  及 FileTab 其余实际可读栅格类型，扩展名大小写／错误后缀／无后缀、透明与 EXIF 方向、DPI、色彩配置、
  断尾／损坏 PNG CRC／JPEG 主图结束标记、错误 GIF 中间帧、空和伪造头。
  验证 MarkdownPicture 的 16 MiB 压缩输入、RasterPreview 的 32,000,000 原像素、
  2048 poster／1024 GIF 帧缩放边界，GIF 1/2/31/32/33 帧及 8,000,000 累计解码像素两侧。
  GIF 零／短／长时长、0.04s 最小时长、dispose／透明、系统动画偏好、后台暂停与复用；
  超限按现有策略显示完整首帧，不能发布损坏或半张图、残留解码任务。
- SVG：沿共享 SVGArtwork 测 1 MiB、8192 节点、48 层、16 层引用及实际 expanded geometry 上限，
  参照 SVGArtworkTests 的共享深度、实例引用、科研裁剪／图案样例；覆盖循环引用、负 viewBox、
  分数倍率、内嵌栅格、字体、样式中的外部引用、脚本与非法／空尺寸。比较实际图像和真实几何，
  不能因 HTML 路径不同绕开共享净化、预算或授权。
- 媒体：audio/video controls 与缺失 controls、src/source 的选择顺序、无效和不可读候选、大小写；
  NativeMedia.candidate 当前 mp4/mov/m4v、mp3/m4a/aac/wav/aif/aiff/caf/flac，
  用可实际解码的媒体覆盖支持组合；错误类型、损坏容器／轨道、DRM、外部引用媒体、64 MiB 暂存边界。
  明确区分原生可解码与文件后缀，不自动播放；真实加载、暂停、定位、背景切换、关闭、断线、
  同 URL 替换及暂存回收，检查真实 AVPlayerItem、实际帧／样本及暂存目录，而非只检查按钮。
  既有设备播放验收按共享 R09/R11 归属，只有本次改变的嵌入路径复验相应实际结果。
- 判据：正确可见的静态内容和实际动作，所有成功／失败／取消路径均回收资源；
  没有额外请求、错误目标或重复绘制，资产尺寸变化后真实阅读位置和源字节不变。

### M03 GFM、元数据、公式、脚注与锚点（T3；投影相关回归 T1）

- 遍历全部适用 CommonMark/GFM 规范例；重点区分 table span 扩展与标准 GFM，
  任务清单、五类 Alerts、列表缩进／编号／空项／紧松列表、六级 ATX/Setext、围栏长度及语言、
  引用式完整／折叠／快捷链接、引用定义前置／后置／重名、多行目的地、链接与图片嵌套、
  裸 www/http(s)/邮件、尾部标点与括号、代码及转义。对 HTML ordered start 的现有 ±1,000,000
  边界和整数溢出也验证真实编号，不因标签格式重构产生算术崩溃。
- Front Matter：有／无 BOM、空 header、空 mapping、sequence/scalar、重复键、多行字段、
  注释、自定义 tag、anchor/alias、深层 YAML、未闭合、无末行换行、非文首分隔符；
  64 KiB 输入及 limitMetadata 的 64 KiB 节点／文本计费预算分别造真实夹具测边界，
  包含小输入但展开复杂的 YAML。检查实际元数据菜单、首末正文、所有后续标题／脚注／公式／链接的源坐标，
  无磁盘改写或隐式文件／表达式求值。
- 脚注：首次／重复／相邻引用、重名、Unicode／大小写、空／无定义／未引用定义、列表／引用嵌套、
  空行后续段、4 空格／tab／代码缩进、表格／HTML／公式及真实链接在定义内。
  定义放在首／中／末，读者末尾重排、重复引用往返、跨折叠章节及 details；
  验证选区实际显示顺序与源区间非单调的情况，不能把不在拖选中的正文夹带进剪贴板。
  自定义锚点与内部脚注编号冲突、重复标题后缀碰撞、空标题、标点、Unicode 规范形／大小写、
  编码 fragment、同页空 fragment／不存在目标；确认实际可见的唯一目标，折叠只揭示真实祖先。
- 公式：单／双美元、块 math 围栏、行内与 display、货币、空／未闭合／转义、TeX 上下标／括号／矩阵、
  字面内部 math token 前缀与真实公式共存、Unicode、连续公式、畸形和超长表达式；
  现有 MarkdownMath 的 8 KiB 候选扫描距离和 16 KiB display 源码预算各侧，
  含大量未闭合美元、长转义串、交错 Markdown 分隔符、链接、图片、HTML 和脚注。
  判断实际 typeset／可读失败与精确源范围，不吞合法邻接文本或让字面占位符禁用全篇数学。
  emoji shortcode 的已知映射、相邻组合、未知、转义、代码内及链接文本同样核对显示／原文映射。
- Mermaid：依赖的全部 30 种当前图型，实际有代表性的每种语法变体、空／未知／错误源、Front Matter、
  换行和中文、图片查看／错误回退、同位置源码编辑和同明暗模式换主题；16 KiB/160 行/1024 字节行长
  旧边界、依赖 50,000 字符／flowchart 500 边边界、极长标签和稠密图；真实静态 click/link/links
  及含这些词的合法文本。检查图像非空、关键像素和源行号、无脚本执行／外部请求及峰值内存；
  不用缓存命中冒充新图，未知扩展保留原文。
- 判据：规范例、独立公开文件对照及可见字形／源区间同时正确；实际片段、折叠往返、剪贴板、
  图形及公式像素均能对应当前源版本，不用 AST 类型相等代替阅读结果。

### M04 原生源码命中与交互（T4）

- 源码／预览／并排，链接标签、目的地、引用定义、图片、HTML 属性、裸文件名与文件路径，
  同行多个候选与重复标签、行首／中／末、跨行／跨视口、图文混排、长 URL、
  左右滚动到不同位置；普通字符、标记、空白、gutter、滚动条、被裁切／遮挡的内容及最近插入点不误命中。
  全部 8192/12288/24576/showAll 长行设置 × 折行开关，原生视口不同宽度、字体／字号、
  中文／emoji/ZWJ／组合字符／RTL、软折行与 CRLF。路径行列定位还要覆盖非 Markdown 文本目标，
  文首／末行／空行及实际折行，不能把显示行当物理文件行。
- ⌘ 按下／释放时鼠标静止或移动、进入／离开、失焦、拖动、修饰键混合、左／右键、双／多击、
  Shift 选择、⌘拖选、键盘／AX 上下文动作、只读／编辑；IME 有 marked text、确认／取消候选期间，
  不抢占 NSTextView 编辑手势或 Undo。检查真实按键与原生 pointer 变化，不以内部 callback 作为成功。
  光标提示只表示明确候选，确认存在及授权在真实打开动作完成。
- 判据：点击到实际目标文件／锚点／行列／Browser；仅一次副作用，保留普通文本原生行为、
  输入法、已选文本、实际焦点、Undo 和源字节。复用 MarkdownScrollPrecisionUITests
  与 NativeEditorLayoutTests 的真实 glyph／scroll／TextKit 验证。

### M05 路径、编码与授权（T2 路径资源；T4 导航）

- 本机仓库、子目录、嵌套仓库、Git worktree、非仓库、Finder 外部文件、获授权 Windows Tailscale SSH；
  仓库根等于、位于或超出授权目录，路径同名不同机器，目录改名与连接更换。
  相对／仓库根／裸绝对／file:／http(s)／mailto／同页及跨文件 fragment，引用式和行列后缀；
  文件名真实含冒号数字、空格／单引号／括号／换行／tab、%/#/? 字面与编码、非法百分号、
  Unicode 规范形、大小写、255 字节路径分量、盘符／反斜杠／UNC、显式 tilde。
  分清原生裸路径和 Markdown URL：只解码一次，不把远端路径交给本机，不支持的路径语义明确拒绝。
- 真实目录、空文件、常规文件、目标不存在／无权限／悬空链接／循环链接／FIFO/socket、
  symlink 指向范围内外及 symlink/.. 实际语义，根路径相似前缀、混合转义和绝对路径逃逸；
  授权后、读／打开前替换路径或连接，真实读时增长／截短／权限改变及 SSH 超时、断线／重连。
  LocalWorkspaceBackend.readSync 已按打开的 fd 确认路径及类型；
  远端 PreviewResource.remoteResource 当前以 realpath 和 head 两步完成读取，
  检查授权与实际读取／新 FileTab 打开间替换目标的最终结果。
  有可达跨边界时修共享授权／实际 IO 所有者，而不是在每个 HTML 标签、预览按钮加相同 guard。
  用受控隔离夹具的不同内容标记证明没有读取外部字节；保留真实后端身份和非协作文件系统的已知边界。
- 以 TextFileEncoding.choices 的九种真实编码（UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM、
  GBK、GB18030、Shift-JIS、Windows-1252、ISO-8859-1）分别构造可往返的合法文本，验证 CR/LF/CRLF、
  混合行尾、无末换行、解码失败、编码声明矛盾、不可表示的编辑以及 NFC/NFD 差异。
  不要求 GBK 等编码表示不支持的字符；分别验证其拒绝和保留草稿。
  路径引用与实际 glyph、源 UTF-16、磁盘字节分开核对。行列测试 0/负数／溢出／越界／省略列，
  文首／末行与空行，只有真实存在的目标能定位。
- 判据：真正的目标机器、路径、可见位置及 Dock 正确，未经授权内容不读、不写、不发请求。
  失败不回退本机、不用无关位置冒充成功，普通导航遵守既有自动保存设置；
  预览、查找和纯浏览不写盘，实际编辑保存必须精确往返。

### M06 文件、窗口、版本与竞态（各任务；共享快照及导航由 T4）

- 冷源文未导航、首个 ⌘点击、热预览、源文打开大纲、并排同时请求、反复重挂载、
  无文本／加载失败／恢复；合并输入、撤销／重做、修改或删除命中链接、重复点击相同／不同链接、
  旧快照同页跳转、旧大纲选择、图片／公式／Mermaid 及查找结果晚到。
  对解析开始、每个真正异步 IO 的挂起、结果即将发布、首次布局还未发生的时间点分别插入变化，
  用现有可控制的宿主任务及 fixture 建立顺序，不用随意 sleep 代替前提。
- 目标已打开／未打开／正在加载、源码／预览／并排、同路径异项目／异机器、目标尚未挂载、
  源或目标编辑、重新编码、外部保存／重命名／删除、dirty／clean／readOnly、
  文件恢复或变成非 Markdown；点击后切 tab、切组、移动 companion、切项目、切窗口、关闭任意一侧、
  关闭源／目标／项目／窗口与会话恢复，连接中断后新连接、A→B→A 与乱序旧结果。
  显式跳转复验滚动同步开／关；查找浮层持焦点时仍作用真实阅读侧。
- 保存共享验证：自动保存开启／关闭、等待／在途／失败、同大小同 mtime 外部写入、编码更换、
  冲突比较／显式覆盖／取消、撤销回原字节、关闭保护、另一个标签并发写入。
  复用 FileTabPersistenceTests 的真实磁盘比较；只新增本次语义／导航／查找会触发的交叉场景。
- 判据：一次共享语义请求对应有效版本，普通源码编辑不新增富内容解析；
  同一原生文本对象及 Undo 不变，失效结果不发布、不夺焦、不打开错误文件。
  统计每个实际解析／资源加载／动作提交次数及关闭后保留对象、任务、临时文件、播放器，
  不把任务 cancellation flag 当作实际资源释放。

### M07 预览查找、复制与焦点（T5）

- 空／无／单／多／密集命中、大小写、组合 Unicode 与等价规范形、实体、ZWJ、中文／RTL、长查询、
  重叠匹配、同一段跨格式／链接／软换行、跨无关段／表格单元格／图像的负例、
  多段脚注及前置定义导致的阅读顺序、代码高亮、实际可见 caption 与回退文字。
  查找不匹配隐藏 YAML/注释/标签、折叠内容、不可见 alt／TeX／Mermaid 源码及无字形的复制分隔符；
  图片／图表／公式从 loading 到成功或失败、资产 refresh 与折叠状态变化后也更新真正可见内容，
  不因纯主题／滚动重新扫描整个文档。屏外内容按可读语义检索，不为搜索主动下载或布局所有资源。
- 当前第一／中／末个匹配、连续下一处／上一处及环绕、屏内和屏外高亮，
  大量结果、查询清空、Escape、使用选区、普通复制／选区拖动／⌘A/⌘C、查找输入框中文 IME；
  选区和搜索高亮共存，命中位置不写入 source caret。
  源码／预览／companion、不同 Dock 与双窗、冷解析、查找中编辑／撤销／换主题／折叠／关闭、
  终端／Diff／CSV／HTML／SVG／图片／媒体／Browser 的 Find 启用、替换、隐藏及使用选区路由。
- 判据：匹配计数与阅读顺序来自独立可见文本预期，真实匹配字形在屏内；
  使用当前实际焦点执行现有 FindAction 的全部六项（show/replace/hide/next/previous/useSelection）。
  替换仅作用既有可编辑表面，查找输入框与阅读器／源码间不串操作，关闭查找不误清普通选择。
  不用复制生成的替代文本冒充屏幕匹配，源正文、撤销栈与磁盘字节不因查询而改变。

### M08 实际运行环境与规模（各任务的受影响路径）

- 当前实际 macOS／SDK／Apple Silicon，保持 15.6 部署目标；Debug 与优化构建、签名及 Dev 隔离；
  默认与全部 Theme.commonLightThemes/commonDarkThemes 当前可选主题、系统跟随和明暗切换、
  同明暗模式切主题、中文／英文界面及 RTL 内容。原生字体／字号、折行、滚动同步、
  自动保存设置；实际 2×、获配显示倍率及无障碍设置。
  独立窗及双窗、多个 Dock 组，920/480/360/260/220/150pt 与超宽容器、连续改变尺寸；
  实体鼠标／触控板、键盘、VoiceOver、减弱动态／透明度及提高对比度按实际可执行条件核销。
  仍遵守用户延期的旧系统、物理显示设备、真实睡眠／旁白测试暂停条件，不要求未获授权的系统改动。
- 空／1／500／5000／20000 行及块、100000 条短标题／链接／脚注等密集边界，
  单一巨段／极长单行、深嵌套、超宽与长表、重复标题后缀、实体／引用／未闭合分隔符、
  富内容组合的 32 MiB 文件边界（包括实际编码后字节数）；不能以全相同短段落代替富文档。
  用合法小输入复现极端展开或几何开销，在隔离环境逐级扩大规模；不把耗尽宿主内存作为测试手段。
- 10/100 次冷／热打开、模式与窗口切换、关闭／重新打开、连续编辑／滚动／查找／图像加载与取消；
  持续实际工作会话，记录空闲、首帧、峰值、关闭后稳定 RSS/footprint 与 retained 对象，
  对比变更前后相同夹具的解析次数、主线程最长占用、真实可读首帧、输入／跳转／滚动延迟、
  P50/P95/P99 和尾部卡顿。按项目性能测量规范记录原始数据、设备及构建配置，
  不以平均值或一次峰值掩盖回归；没有证据不增加缓存、并发队列或刷新定时器。

### 组合与根因验收

使用 Bailey README、合法可读 SKILL.md、科研 Markdown 的隔离副本，以及一组共享的高密度主文档和相互链接文件，
包含正常／失败资源、非 Markdown 目标、真实 Git 仓库和授权 SSH。小规范例用于定位缺陷；完整主文档用于证明交付。
利用现有 XCTest fixture、参数循环和已锁定规范样例，优先在宿主层遍历有限组合；
条件过多时先覆盖每个适用取值和全部极值，再系统扩展两两及多因素组合，直至安全可行的上限。
下面列的是不可遗漏的共享根因组合，不是其余条件的豁免：

| 组合 | 实际需证明的最终结果 |
| --- | --- |
| M01×M02×M03×M07 | HTML／Markdown、脚注、实体、公式、图片与折叠混排；显示／精确回源／拖选／复制／查找一致 |
| M01×M03×M05×M06 | 九种编码与行尾、Front Matter、多次重写、编辑／撤销及保存冲突；原始字节与实际位置准确 |
| M02×M05×M06×M08 | 同 URL 换资源、symlink、权限变化、实际 SSH 断线重连、窄窗与主题；无越权／过期图片／媒体泄漏 |
| M03×M04×M05×M06 | 相同链接从源码及预览打开，跨锚点、跨普通代码文件行列、异机同名及目标尚未挂载；真实目标与焦点正确 |
| M04×M06×M07×M08 | 超长折行、Unicode/IME、⌘点击、拖选、双窗、查找浮层及实时编辑；原生输入与命中不串扰 |
| M02×M03×M07×M08 | 长富文档，图片／公式失败后恢复、Mermaid 原地更新与主题变化、展开／折叠、查询及连续滚动；计数、可见像素和锚点同步 |
| M05×M06×R06/R10 | 本机 Finder 文件在 SSH 项目、远端连接代次变化、保存冲突／关闭保护；同名本机文件及未保存草稿均未被错误操作 |
| M01–M08×R08/R09/R11 | 受影响的入口从真实 FileTab/Dock/原生视图到最终像素、目标和磁盘；100 次循环及长会话无持久泄漏 |

每项缺陷先用真实前提证明 Red（例如旧图确已加载、当前焦点确在 companion、远端通道确已失效、
原始源区间确非单调），随后在失效不变量的所有者修复并验证 Green，再删除旧实现与已证冗余的判断。
沿同一根因的所有实际入口补回归；不加任意等待、刷新整个 View、重试、吞错、限制正常输入或放宽断言来造绿。
新增测试以当前需求为准，不测试假想状态或为测试引入生产框架。
仅在能证明底层能力覆盖同一风险时删除上层保护；保留授权、真实文件身份、资源边界和数据完整性。
P3 各任务完成前均复查自身实现及清理，不能将本应完成的接入或失败留给最后验收。

### 执行及核销

宿主以现有测试类和 Makefile 执行定点 Red/Green/Refactor，再运行相关类；
例如 `make test:SwiftMarkdownNativeTests,SwiftMarkdownSelectionTests,SwiftMarkdownLayoutTests`。
实际资源专项按 M02/M05 补跑 SVGArtworkTests、NativeMediaFileTests、HTMLFilePreviewTests、
MarkdownResourceScopeTests、FileTabPersistenceTests；完整 App 独有的交互复用现有
MarkdownPreviewUITests、MarkdownInlineHTMLUITests、MarkdownMathUITests、
MarkdownSelectionBoundaryUITests 和 MarkdownScrollPrecisionUITests，
通过 `make test:ui ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests` 等选中真实方法执行。
每任务核对 `make build`；涉及依赖或发布路径时另按规范运行 `make build:release`，
GUI 前使用 `make build:dev` 或现有 `make build:ui`；阶段整合 `make test`，不为每项重复全量。
仅宿主不可替代的真实操作进入 GUI，不能借此缩减逻辑、实际文件或原生组件测试覆盖。

按 [共享验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment) 隔离 Dev、远端与图形会话。
用户先前暂停的 GUI／全量测试在获准恢复后执行；记录其待验，不写成已通过。
每项实际执行必须确认测试确被发现、真实前提、完整退出状态及最终像素／剪贴板／源区间／磁盘字节、
窗口身份和任务释放。阶段审计按上述 M/R 的实际取值与组合核销，不新增第二份永久测试清单；
每个不可执行条件明确原因、实际尝试、替代证据、影响、补验方法及 Gate 限制。
仍缺必要证据不得宣称全部通过或无保留 Go，不以旧 audit 抵销本轮验收。
每任务同步 docs/features/editor.md，只有共享契约变化才修改所属文档，
未实现能力不提前写入现行产品说明。
