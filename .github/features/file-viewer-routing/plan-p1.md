# P1｜沿现有文件标签复用多格式预览

Markdown 已在 `swift-markdown` 分支接入文件标签、原生编辑器、Dock 并排和 File 菜单。
本计划不再等待“首个渲染器”，也不单独实施空壳路由；
**在接入下一种真实格式时，共用已有所有者，并删去被取代的 Markdown 专用分发代码。**
Markdown PR #101 已在 `main` 的 `4f336b88` 合并；所有后续格式直接以此为基线，不能从旧文件查看器路线重做一遍。

## 已确认的执行链

- 打开：`Project.openFile / openLocalFile`；恢复独立通过 `Project.restoreTab` 创建同一类 `FileTab`。
  本机 Finder 文件与 SSH 项目同路径时仍以本机身份打开。
- 读取：`FileTab.readContent → loadedContent`；现有 `.text / .image / .loading / .unavailable`。
  文本的 32 MiB、图片的 256 MiB／3200 万像素／4096px 缩略图及真实格式头检查均已有用途。
  不因出现新后缀而复制读取链或撤销这些限制。
- 展示：`FileViewerView` 是主入口；`TabContentThumbnail.filePreview` 是有界缩略图入口。
  Markdown 的 `MarkdownFilePreview` 只负责该格式的 AST／阅读交互，不能改造成万能文件渲染器。
- 编辑与并排：唯一可写正文是 `FileTab.nativeTextStorage`；
  `Project.setMarkdownMode → DockWorkspaceModel.setMarkdownPreview → DockItem.markdownPreview`
  已建立外层 Dock 双展示，`BaileyApp` 的 File 菜单已有唯一 `⌘⇧V`。
  `WorkspaceWindowModel` 判定前台有效目标；`WorkspaceDockView` 右键判定被右键的标签。

## 哪些能力共用，哪些不共用

| 已有代码 | 后续接入方式 |
| --- | --- |
| `FileTab`／`SourceTextEditor`／`WorkspaceBackend` | CSV／SVG／HTML 仍是 `.text`，继续共用正文、编码、Undo、读取与条件保存；不增加格式专属可写副本。 |
| `MarkdownResource`＋`LocalPathScope` | HTML 的 CSS／图片和 SVG 的授权相对资源应共用当前项目／机器的路径解析、范围与实际 IO 校验；第二种消费者落地时将公共部分改成中性名称，替换所有调用，不保留同义包装。WebKit 另需自己的执行／网络限制。 |
| `FileTab.imageThumbnail`／`MarkdownPicture.decode`／`MarkdownImageInspector` | 图片与 Markdown 插图已有部分共用；完整缩放改造须在同一查看组件和 ImageIO 解码路径完成，独立图片与内嵌图片均接入后删除旧缩略图查看分支。 |
| `MarkdownSVG.sanitizedXML`／`MarkdownSVG.render` | 共用一次安全解析与 SwiftDraw；Markdown 可用有界栅格，独立 SVG 要在相同净化结果上矢量重绘，不重写第二套 XML 校验／SVG parser。 |
| `MarkdownMedia.asset`／`MarkdownNativePlayer` | 音视频共用 AVAsset 验证，视频与 Markdown 嵌入播放器共用 `AVPlayerView` 适配；独立音频若需自有紧凑控件则直接操纵同一个 AVPlayer，不强加视频 UI。嵌入媒体才需要有界暂存，独立本机文件使用真实 URL，生命周期各归其主。 |
| `MarkdownViewMode`／`showsMarkdownPreview`／`DockItem.markdownPreview`／`rendersOnlyMarkdown` | 下一种文本预览落地时将**展示模式与 Dock companion** 收敛为文件通用语义，替换所有调用、菜单和测试，删除旧 Markdown 专用状态及分支；Markdown AST、滚动映射和独立的 `MarkdownFilePreview` 仍归 Markdown。 |

**不能强行共用：**完整 HTML 页面需隔离 `WKWebView`；Markdown 的 `MarkdownHTML`
只处理少量静态片段，不是全 HTML/CSS 引擎。CSV 字段源区间解析也不同于 GFM 表格渲染。
两者复用文件及安全边界，不复用不等价的内容语义。
源码高亮扩展名表、文件图标和可预览性是三个不同判断，不建立统一 Registry／`FileKind`。

## 任务

<a id="p1-t1"></a>
### P1-T1 核销读取与公共资源边界，移除新格式产生的重复路径

- **位置**：`FileTab.readContent / loadedContent / matches / reloadFromDiskIfClean`、
  `MarkdownResource`、`MarkdownFilePreview`、`MarkdownHTMLView`、`Project.openMarkdownLink`、
  `LocalWorkspaceBackend`、`BaileyTests/Files`。
- **实施**：文本格式仅接入现有 `.text`，不改写编码或保存；图片仍经现有 ImageIO 安全边界。
  HTML 首次消费外部资源时共用已验证的 `MarkdownResource` 授权与本机／SSH 读取，
  仅提取确实有第二个调用者的公共部分，立即删除旧命名与重复路径。
  本机音／视频真正接入时才增加**所需的**媒体读取结果及 `Content` 处理，
  在 `readContent` 读取整个二进制之前分流，直接验证有权限的真实本机 URL，SSH 明确拒绝；
  不用 32 MiB 文本读取、整文件内存缓存或回退同名 Mac 路径。
  纯图片更高分辨率查看不可绕过源文件版本和有界解码。
- **验收**：无扩展名、大小写、混淆后缀、伪造格式头、符号链接／`../`／URL 编码、
  非普通文件、权限错误、缺失／损坏、32 MiB 文本及 256 MiB 图片边界；
  Finder 本机文件、受控 SSH 同名文件、断线／重连、读中改名、刷新失败和关闭后迟到结果。
  检查真实读入字节、机器、权限、取消和资源释放，不以渲染器实例化代替最终结果。

<a id="p1-t2"></a>
### P1-T2 让下一种预览复用同一展示模式、Dock 和系统菜单

- **位置**：`FileViewerView`、`FileTab`、`DockWorkspaceModel`、`Project`、
  `WorkspaceDockView`、`WorkspaceWindowModel`、`BaileyApp.swift`、
  `SourceTextEditor`、`PanelContentView`、`TabSwitcherView` 及相关测试。
- **实施**：从现有 Markdown 源码／预览／并排入口出发，按第二个真实格式的需要
  **一次性替换**特有的模式与 Dock companion 命名／分发；各格式只拥有自己的渲染内容和附加状态。
  右键操作命中标签，主菜单操作前台焦点文件，`⌘⇧V` 只注册一次，
  不新增第二个工具栏、第二套 Splitter、保存模型或事件监听。
  CSV 默认表格、SVG 默认图形、HTML 默认源码；错误时源码仍可见，
  损坏数据不得凭后缀宣称已成功预览。
  主视图与 `TabContentThumbnail.filePreview` 同时覆盖新增内容，缩略图不再次读取全部文件、
  创建播放器或触发脚本；当场删除被新路径替代的旧视图／枚举分支及旧测试断言。
- **验收**：Files／`⌘O`／Finder／独立 `restoreTab`／跨窗口打开，
  单标签与并排、Dock 拖动／关闭、右键后台标签与 File 菜单、切模式、焦点／IME／Undo／保存，
  跨后缀重命名、可写草稿、外部冲突、权限变化、旧读取乱序以及真实关闭释放。
  对照 Markdown 和现有图片的实际 GUI，**纯架构复用不得改变其 UI/UX**。

## 阶段验收与执行顺序

此计划与**下一种格式的首个接入任务共同执行**，不作为单独“框架项目”先行。
推荐先完成 [图片 P1](../image-annotations/plan-p1.md) 的共用缩放视口，
再以 [SVG P1](../svg-source-preview/plan-p1.md) 为第一个非 Markdown 文本预览，
**在接入 SVG 的同一任务完成路由 P1-T2 通用化及删除旧分支**。
HTML／CSV 后续直接使用通用模式；音频 P1 首次复用 AVAsset，视频 P1 首次共用 AVPlayerView。
这些是依赖关系而非额外大阶段；已验证的功能可按实际准备情况并行。
若所选格式尚不需要修改读取或并排路径，记录核验结论，不制造提交。

按 `docs/testing.md`，宿主覆盖 `FileTabPersistenceTests`、`MarkdownResourceScopeTests`、
`NativePaneRetentionIntegrationTests`、`DockWorkspaceTests`、`SessionStoreTests`、
`FinderDeliveryIntegrationTests` 以及新格式的解析／权限／IO 用例；
涉及阅读位置与菜单时加 `SwiftMarkdownLayoutTests` 和隔离的 `MarkdownPreviewUITests`／Dock UI。
完整执行相关 `make test:...`、`make build`、阶段性 `make test` 和必要的隔离 Bailey Dev。
测试应覆盖 macOS 支持基线、编码和大小极值、错误恢复、真实本机与获授权 SSH、
多窗口、窄宽 Dock、深浅主题、键盘与手势，以及跨格式、切换、刷新、关闭的交互组合。
真实 SSH、系统缩放／触控板或特殊运行环境不可用时，逐项记明原因、影响、替代证据与补验方法；
未跑的组合不能冒称通过。完成后同步 `docs/features/editor.md`，只有所有权改变才改 `docs/architecture.md`。
