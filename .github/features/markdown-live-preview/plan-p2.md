# P2｜实时预览、并排与富内容

交付原生 Markdown 阅读器的完整能力：源码实时更新、Dock 管理的并排、HTML/SVG/Mermaid/公式/脚注/媒体、可控链接和保存恢复。
**只保留 swift-markdown 一套 Markdown AST；所有静态 HTML、图片、音视频使用 Bailey 自己的原生渲染路径。**

## 方案

P1 交付 Markdown AST → `Sendable` 展示快照。
P2 在 `FileTab` 原生文本变更通知后合并连续修改，在非主 actor 解析；
只提交仍属于同一文件、项目、机器、路径、装载代次及编辑修订的结果。
SwiftUI 只消费当前快照；关闭／切换文件取消任务与媒体，旧图片不得覆盖新文件。

并排仍由 `DockNode` 唯一负责，不在标签内再造 Splitter：
同一 `FileTab` 的源码和预览可以分别展示，但**只有源码编辑器能写入**。
参照旧分支已经完成的 Dock companion 实现，按当前基线移植其最少必要差异；
不新建第二个 `PaneTab`、文件副本或 Undo。
`MarkdownResource` 仅接受获授权相对路径；本地检查真实文件／符号链接，SSH 在远端检查 realpath 并读取。
不采用旧分支 Textual 对 `AttributedString` 的后加工、`@_spi(Textual)` 数学附件或 Textual 私有补丁。

HTML：SwiftSoup 只解析白名单语义标签，转换成 SwiftUI 视图；不需要 WebKit、CSS 引擎或 JavaScript。
SVG：复用旧分支 SwiftDraw＋受限 XML 净化，生成 CGImage。
图像：ImageIO 按需解码与有界 GIF 动画。
Mermaid：`MermaidKit` 的本地原生渲染，不运行 Mermaid.js。
音视频：AVKit，用户主动加载；背景／不可见时停止。
公式：使用公开的本地原生公式排版 API；不引入 WebKit 和 CDN。
脚注：先核实 swift-markdown 的 AST 覆盖，未覆盖时仅对脚注语法补充源码范围解析，避免用正则重写 CommonMark。
不支持的语法就地保留可读原文，不能执行 MDX/JSX。

## 任务

<a id="p2-t1"></a>
### P2-T1 后台增量更新、Dock 并排和状态保持

- `FileTab.nativeStorageDidChange` 通知预览版本；后台生成当前文件展示快照。快速编辑、撤销、重载及切换时取消过期任务；同一底层文本缓冲、Undo、编码和保存状态不变。
- 在 `DockWorkspaceModel`、`PanelContentView` 和 `Project` 内复用唯一外层 Dock 的并排几何；显示者引用同一文件标签，不复制独立读写文档。
- 验证中文 IME、选区、原生源码滚动、预览滚动、撤销、关闭及恢复、多窗同名文件、失焦后自动保存规则；覆盖 500／5,000／20,000 行负载和旧快照抢占时序。

<a id="p2-t2"></a>
### P2-T2 保存、恢复、链接与真实文件行为

- 沿用 `FileTab.save`／外部修改检测／编码与 BOM；视图模式不入持久化文件正文、不自动保存，重开可以默认源码；单标签和 Dock companion 按同一保存保护关闭。
- 相对链接通过 `Project.openFile` 打开经原有 backend 授权的实际文件，复用已打开标签；外链显式送入 Bailey Browser，点击前无网络访问。
- 验证 CRLF／UTF-8 BOM／UTF-16、重命名、冲突、只读、SSH 断线、关闭否决、重启恢复及 VoiceOver。

<a id="p2-t3"></a>
### P2-T3 原生 HTML、SVG、GIF 与音视频

- 从 swift-markdown `HTMLBlock`／`InlineHTML` 和图片节点提取原始内容，交给 SwiftSoup／SwiftDraw／ImageIO／AVKit；完整保留段落前后的混排。
- `MarkdownHTML` 只支持可映射为原生 SwiftUI 的静态 HTML 标签：`img`、`svg`、`details`、表格、列表、标题、强调、带 controls 的音视频等。未知标签按可读文本降级；事件处理器、远端链接资源、iframe、表单和 script 不执行。
- 通过 `MarkdownResource` 读取实际项目内资源：PNG/JPEG/HEIC/WebP/GIF、渐变及滤镜 SVG；GIF 与媒体生命周期按资源预算限制。视图销毁时停止播放并清理临时文件。
- 宿主和实际 GUI 验证 HTML inline 连续排版、图片尺寸、Retina、相对链接、恶意 SVG 与 HTML、媒体 seek／暂停／释放，以及 SSH 与本地路径隔离。

<a id="p2-t4"></a>
### P2-T4 Mermaid、公式、脚注与完整离线验收

- 从 AST `CodeBlock` 的语言标记及原始正文识别 Mermaid，调用本地 MermaidKit；渲染失败回显源码与可读错误，禁止点击脚本、外链和远程字体。
- 原生数学排版支持 `$…$`／`$$…$$` 并正确区分普通代码围栏、转义字符与行内代码；脚注引用与定义稳定链接且不改变源文件。
- 使用真实包含全部内容的统一 Markdown 文档，记录首次／连续编辑／文中编辑、滚动、窗口调整、内存峰值与释放；隔离 Bailey Dev 验证跨段落与跨组件选择复制、主题、VoiceOver。
- 检查实际依赖图不含 Textual、MarkdownView、Mermaid.js、WKWebView 的 Markdown 入口，且无后台网络请求；补齐许可证、`NOTICE.md` 与 `docs/features/editor.md`，删除过时实现。

## P2 验收

- **端到端**：从真实 File Manager 打开 `SKILL.md`／科研混排文档，切换源码→预览→并排→源码，在并排时修改，Undo、Save、Close、Reopen 后源文件字节与预期一致。
- **规范**：GFM 表格／任务／删除线／自动链接，Front Matter，SVG 滤镜与渐变，Mermaid 流程／时序／类／状态图，GIF、音视频、公式、脚注、MDX 原文及不支持的语法退化。
- **隔离**：本地和 SSH 的目录越界、软链接、断线、异步过期结果、被删除资源；网络请求／WebKit 创建必须为零。
- **性能**：以相同测试夹具分别记录 AST 解析与 SwiftUI 布局。32 MiB 边界可安全返回无损源码；无法实际验收的条件写清原因与影响，不能用推断代替测试。
- **工程**：根 `Makefile` 隔离构建、所有适用宿主测试、必要 UI E2E、签名检查以及实际 GUI 截图；每个任务完成时同步代码与所属文档并原子提交，不积攒兼容旧路。
