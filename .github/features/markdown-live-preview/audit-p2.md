# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。以下历史 P2 验证记录不替代本轮复验。

## 结论

- **结果**：Go
- **依据**：源码始终只由原生文件标签持有。隔离 App 已验收并排、实时刷新、保存和富内容，
  没有在标签内部另建分屏、编辑器或 WebView。

## 任务与改动

- **P2-T1**：`eeae2dba`。并排只是 Dock 中同一标签的只读展示位置；
  原生编辑事件推进预览版本，异步结果核对请求身份，源码与预览保留各自阅读位置。
- **P2-T2**：`93c71f4b`。同机项目内链接复用已有后端及标签，恢复为源码，
  预览位置不进入会话文件，不改原编码、条件保存和冲突检查。
- **P2-T3**：`6995897e`。有界 ImageIO、SwiftDraw 静态 SVG、受限 HTML 和按需 AVKit，
  无外部资源或媒体引用。对新快照隔离 Textual 的在途附件结果。
- **P2-T4**：`04472cf7`。原生 Mermaid 位图及失败回显，Textual／SwiftUIMath 公式，
  本文脚注锚点。README 入口、功能文档、固定依赖及原许可证同步。

## 本轮独立复核（2026-11-21）

- 逐项追踪 Markdown P1-T1～P2-T4 与文件路由 P1-T1～T2；生产接线仍复用 `FileTab`、Dock 和 File 菜单，未建立第二份编辑或保存链路。
- 以 [github-markdown-css](https://github.com/sindresorhus/github-markdown-css) 为视觉基准，修复正文、标题、任务清单、表格、受限 HTML、折叠、Mermaid、公式及脚注；保留原生离线安全边界。
- `make test:MarkdownPreviewTests,AppIdentityTests,NativeFileTabTests,DockWorkspaceTests`：101 项、0 失败，退出 0；包含 32 MiB 文件测试。
- `make test:ui` 定向 Markdown 3 项、Finder 双向复制与显式移动 2 项：5 项、0 失败，退出 0；新增 HTML 折叠/表格 GUI 1 项在最终代码再次通过、退出 0。
- 隔离 Dev 实际截图：`/tmp/Bailey-GitHub-final-light-wide.png`、`/tmp/Bailey-GitHub-final-light-narrow.png`、`/tmp/Bailey-GitHub-final-dark-h6.png`、`/tmp/Bailey-GitHub-final-dark-narrow.png`；深浅色与宽窄窗口均完成视觉检查。
- 未覆盖：macOS 15.6 真机、真实 Windows SSH、VoiceOver 与实体中文 IME、32 MiB 文档的完整 GUI 布局/帧率、全部媒体编解码器与长时间多媒体并发。宿主/组件验证不冒充这些条件。

## 深度复验补充（2026-11-21）

上文所述 101 项宿主、旧 GUI 和截图均为先前版本的阶段证据，不能代替本次代码的回归。此次从原生 HTML 解析、Textual 文本合并、文件权限、图片实际绘制、代码输入到 Dock 实际导航重新逐项复核，新增 F-04～F-11 八项；其中四项先用真实失败用例复现再修复。

- HTML 解析、表格分组、32 MiB 容量、资源权限与原生编辑器输入的定向 Host 复测已通过（29/0 与 43/0），参见 `/tmp/bailey-md-deep-host-all.log`、`/tmp/bailey-deep-prose-source-green.log`。仅测解析不能代表 GUI。
- 实际 Dev GUI：`details open` 双向切换、HTML h2/ul、相对链接进入原项目标签、相邻内联 HTML 合并通过（`/tmp/bailey-md-deep-gui-green.log`、`/tmp/bailey-md-deep-inline-green2.log`）。
- HTML 图片几何实际红→绿：SVG 原图 320×120 声明 48×32 时旧行为绘成 48×18，新行为按 48×32；超宽 2000×800 在实际预览区域自适应。输入保持 ASCII 源代码、只改 HTML 属性到 96×16 的 GUI 复验已通过（`/tmp/bailey-deep-source-live-green-gui.log`），截图附于对应 `.xcresult`。
- 关键根因不在 Markdown：`NativeCodeTextView` 的四项默认自动文本替换会改写源文件，Host 曾 4 项断言失败；现统一关闭，保留既有原生 Undo 和 IME 管线。
- **仍不宣称**对任意复杂 HTML 达到浏览器逐像素一致，或已完成 VoiceOver、真实中文 IME、Windows SSH、32 MiB 全文 GPU 帧率／内存与长期音视频播放的真实验收。

## 发现项

## 发现 F-11

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/NativeCodeTextView.swift:412`
- 摘要：`代码编辑器默认启用智能引号、破折号、文本替换和拼写纠正；编辑 HTML 属性时把 ASCII 引号改为弯引号，导致原生 Markdown 图片失效`
- 风险：`源代码输入被系统语言功能静默篡改；实时预览与保存字节均可能错误，影响所有代码文件`
- 预期修复：`在唯一 NativeCodeTextView 初始化路径关闭四项会修改代码字节的自动语言替换，不改文档模型或预览解析`
- 验证：`NativeEditorCompositionTests 的属性 RED 转 GREEN；Dev GUI 将 HTML 48x32 改为 96x16 后逐字节对比编辑器内容并核对实际预览尺寸`
- 解决证据：`NativeEditorCompositionTests 原先 14 项含 4 断言失败，关闭自动替换后 Host 43/0；Dev GUI ASCII 源码逐字对比及图片尺寸实时更新通过：/tmp/bailey-deep-source-live-green-gui.log`


## 发现 F-10

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownResource.swift:202`
- 摘要：`HTML img 同时提供 width height 时仍由 scaledToFit 强制保留自然宽高比，像素高度错误`
- 风险：`缩略图、图标和页面结构实际形状与 HTML 声明不符，宽窄窗口可能布局错位`
- 预期修复：`由原生图片同一绘制器按声明像素绘制并在窄容器成比例适配，保留动画和 URL 行为`
- 验证：`GUI 针对 SVG 320x120、HTML 48x32 同时测量 width 与 height，检查窄窗口`
- 解决证据：`SVG 320x120 的 HTML 48x32 首先红（18px），原生单一图片绘制器精确尺寸绿；2000x800 响应式超宽图 GUI 通过，截图附在 xcresult`


## 发现 F-09

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:321`
- 摘要：`HTML 根节点连续 span strong a 被多个独立 View 渲染，断行并产生错误块间距`
- 风险：`无 p 包裹的合法内联 HTML 逐段竖排，和 GitHub 行内排版严重不符`
- 预期修复：`统一在原生 HTML 展示边界合并相邻的安全内联节点，保留真正块级节点边界`
- 验证：`定向 GUI 混合 span strong 链接排版回归及真实截图`
- 解决证据：`相邻 span/strong/em 真实 GUI 先红后绿，根节点及 details 内均为同一 Text：/tmp/bailey-md-deep-inline-green2.log`


## 发现 F-08

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift:287`
- 摘要：`HTML img 的 width height 属性完全丢失`
- 风险：`README 中图标、徽标和限定宽度图片被放大，窄 Dock 布局异常`
- 预期修复：`在静态图片节点保留安全尺寸声明并限定可见绘制大小，继续走既有图片资源权限`
- 验证：`make test:MarkdownPreviewTests; Dev GUI 图片尺寸与窄窗口截图`
- 解决证据：`Host 限定 width/height 与异常值 21/0；Dev GUI 48x32 实际布局与 SVG 截图核验，/tmp/bailey-md-deep-image-geometry-green.log`


## 发现 F-07

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift:263`
- 摘要：`常用 HTML 标题、列表和水平线被当成原始标签打印`
- 风险：`合法 Markdown 内联 HTML 文档大量内容不是原生阅读布局`
- 预期修复：`限定范围将常用静态块级标签映射到安全原生视图而不引入浏览器`
- 验证：`make test:MarkdownPreviewTests; Dev GUI HTML 样本逐屏验收`
- 解决证据：`原生 h1-h6/ul/ol/hr Host 断言 21/0；实际 GUI 标题列表及相对链接导航通过`


## 发现 F-06

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:435`
- 摘要：`details 展开状态在原始 open 属性修改后不跟随实时预览更新`
- 风险：`用户编辑源码时预览的展开状态与新 HTML 不一致`
- 预期修复：`在原声明 open 值变化时同步局部状态，保留未变声明时的手动交互`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests`
- 解决证据：`真实 Dev GUI 源码 <details>→<details open>→<details> 双向实时展开/收起通过：/tmp/bailey-md-deep-gui-green.log`


## 发现 F-05

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift:298`
- 摘要：`HTML 表格丢弃单元格富文本且斑马纹行与 GitHub 顺序相反`
- 风险：`链接、强调、换行在表格内变为普通字符串，深浅主题交替底色错误`
- 预期修复：`保留安全单元格节点并使用同一行内渲染规则；按表头与正文正确填色`
- 验证：`make test:MarkdownPreviewTests; Dev GUI 表格宽窄主题验收`
- 解决证据：`Host 富文本表格及 thead/tbody 与 flat tr:nth-child(2n) 断言 21/0；真实 Dev HTML details/table GUI 通过`


## 发现 F-04

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift:329`
- 摘要：`HTML a 链接被当成原始标签文本，无法点击`
- 风险：`普通 HTML 链接与 GitHub 阅读语义不一致`
- 预期修复：`在受控 HTML 节点和 Text 中保留链接，复用现有 openURL 与 Project 授权`
- 验证：`make test:MarkdownPreviewTests; make test:ui ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests`
- 解决证据：`Host MarkdownPreviewTests 21/0；真实 GUI HTML 链接点击后打开项目内 Guide.md Tab，3/0：/tmp/bailey-md-deep-gui-green.log`


## 发现 F-03

- 任务：`P2-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownDocument.swift:250`
- 摘要：`受限 HTML 将 p、blockquote 结构打平，行内 strong/em/code 被拆成独立视图`
- 风险：`段落与行内语义脱离，无法按 GitHub Markdown 连续排版`
- 预期修复：`解析时保留安全块结构及 table th；原生 Text 合并行内语义，保留 details open 状态，不执行 HTML`
- 验证：`宿主 MarkdownPreviewTests、隔离 Dev GUI HTML 逐屏对照`
- 解决证据：`HTML 结构/表头/details open 语义 Host 回归及真实 GUI 开合测试通过；无 WebView 或脚本执行`


## 发现 F-02

- 任务：`P2-T3`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:237`
- 摘要：`受限 HTML table 直接使用无分隔线无填充 Grid，与 Markdown 表格排版不一致`
- 风险：`原生 HTML 表格不易区分表头和数据行，尤其窄窗口及深色外观`
- 预期修复：`按 GitHub 表格规则对齐 1pt 边框、隔行底色、6×13pt 单元格边距，并保留真正的 th 表头语义`
- 验证：`隔离 Dev 受限 HTML 文档宽窄主题截图，Markdown 主机及 GUI 定向测试`
- 解决证据：`原生 Markdown/HTML 表格按 GitHub 1pt 线/6x13pt 内边距/隔行色渲染；实际 GUI 截图及 HTML GUI 用例通过`


## 发现 F-01

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:100`
- 摘要：`原先 20pt 边距、独立块间距与 Textual 旧 GitHub 配色不符合 GitHub 当前 CSS；深色 H6 对比度不足`
- 风险：`Markdown 作为正文阅读器缺乏清楚的标题层级与舒适行距，窄宽显示欠协调`
- 预期修复：`复用 Textual GitHub 排版，按开源 GitHub CSS 对齐 16pt 正文、980pt 版心、响应式边距、链接与代码配色、H6 对比度`
- 验证：`隔离 Bailey Dev 宽窄窗口深浅主题截图；make build:dev；make test:MarkdownPreviewTests；make test:ui ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests`
- 解决证据：`Textual GitHub 版心/字体/标题/配色按 GitHub CSS 校准；深浅宽窄 Dev 截图核对；101 Host+6 GUI 通过`


## 验证与未覆盖

- macOS 27.3 arm64、Xcode 27.2。阶段定点宿主：并排／Dock 47 项；
  Markdown／会话 20 项；SVG／媒体 12 项；公式／脚注／Mermaid 14 项，命令均退出 0。
  实测原缓冲身份、受控 SSH 无本机回退、BOM／CRLF 原字节、SVG 渐变实际像素、
  WAV 暂存原字节和精确 seek、Mermaid 四类图的深浅主题、有害点击和超限拒绝。
- `make test:ui ONLY_TESTING="BaileyUITests/MarkdownPreviewUITests BaileyUITests/WorkspaceWindowsUITests/testLaunchServicesOpensAndReusesFilesInTheExistingDevWindow"`：
  4 项通过，退出 0。真实 File 菜单、MDX、窄并排首屏、实时编辑到保存、Undo、
  SVG／表格／音频原生控件／Mermaid，以及系统投递后预览往返均实测。
  首帧空白和 SVG 标签被折小写分别经 GUI、像素回归验证修复。
- `make build`、`make build:release` 完整退出 0，按 Makefile 严格验签。
  正式 App 未安装或重启。
- 全量 `make test SIGNING=adhoc`：共 1,133 项，1,114 通过、18 项缺授权 SSH 跳过，
  唯一失败是宿主还要求 Save 位于 Edit。仅修订测试契约（`06386f89`）后，
  `make test:AppIdentityTests,MarkdownPreviewTests SIGNING=adhoc` 35 项通过、退出 0。
  其余宿主结果对应同一生产代码，未重跑全量。
- `4050ea95` 额外核验 32 MiB 文本容量下正文和文末标题均保留，
  全量及定点测试分别记录约 3.9 秒和 3.7 秒纯解析，不代表实际 SwiftUI 排版。
- 无 15.6 实机及获授权的 Windows SSH 目标；部署目标检查及受控 SSH 命令不能代替实机。
  未开启系统 VoiceOver 或真实中文 IME；已验证原生 AX 元素和宿主输入法逻辑，尚需实体交互。
  未穷举各视频编解码器、动图组合、真正离线／断网与多个媒体同时播放；有界 ImageIO、
  原生 WAV 及禁止外部引用的测试是替代证据。长文档解析与实际 GUI 帧延迟分开，
  未把宿主解析基准当成 20,000 段／32 MiB 的 SwiftUI 全布局验收。
- 资源路径变化在重新打开、内容请求或窗口重获焦点时读取；没有为每个资源或文档重复安装文件监听。
  预览外的独立媒体查看器不在两份计划的首个渲染接入范围内。

