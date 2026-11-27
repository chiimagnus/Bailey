# P1｜复用 FileTab 和 Markdown 模式的安全 HTML 文件预览

HTML 文件默认源码；预览是同一文件标签内的**静态只读网页**，不是第二个 Browser。
Markdown 已完成的文件菜单、Dock 并排、源码状态和资源访问能力必须沿用。

## 已有代码与技术选择

- `.html/.htm` 按现有 `FileTab.readContent → .text` 获取编码后的原文；
  `SourceTextEditor`／`FileTab.save` 继续是唯一文本、Undo、条件保存和外部冲突所有者。
  不添加 HTML `Content` case、第二份可写 DOM 或新文件标签。
- `Project.setFilePreviewMode → DockWorkspaceModel.setFilePreview` 和 File 菜单 `⌘⇧V`
  已随非 Markdown 文本格式接入统一为通用文件预览（见[文件查看](../../../docs/features/file-viewer.md)）；
  HTML 复用该模式／Dock companion，不另建 Mode／Splitter／菜单监听。
- `MarkdownHTML`＋SwiftSoup 是 Markdown 内嵌的**受限 HTML 片段语义**，
  不能负责完整 HTML 文档、CSS 级联、媒体查询或页面布局。
  全页 HTML 预览使用独立隔离的 `WKWebView`（macOS 系统 WebKit），
  **但不复用具有完整网页权限的 `BrowserTab`**，也不让 WebKit 取得第二份编辑权。
- `PreviewResource` 是从 Markdown 提取并替换了旧入口的共用权限读取：
  本机与 SSH 都使用文件所属项目／连接及授权目录。
  CSS 中的 `url(...)` 和 `@import` 由 WebKit 相对**当前 CSS 文件的受控 URL**计算；
  handler 将结果交给 Markdown 共用的范围校验，不自行解析 CSS、不回到 HTML 文档目录，
  也不让 SSH 的同路径回落到本机。
  CSS、图片与 SVG 的读取预算及 MIME 验证分别执行。
  **完整 HTML 中的 SVG 仍交由已选的 WebKit 页面渲染**，不另起 SwiftDraw 图像转换路径；
  可复用 `SVGArtwork` 已确认的危险 URL／主动内容测试样本与授权规则，
  但不能直接套用其仅适用于 Markdown 片段的剔除白名单，导致合法页面静默漏图。

## 静态预览信任边界

`WKWebViewConfiguration` 使用非持久化数据存储，禁用页面 JavaScript，
用 WebKit 内容规则阻断预连接等外部请求，并对页面和子资源实施强制 CSP；
不允许自发导航、脚本、表单、iframe、
弹窗、下载、网络、`file://`、任意 `data:`／`blob:` URL 或未授权相对路径。
不能把“禁用 JS”或 `WKNavigationDelegate` 仅拦截顶层点击当作子资源隔离：
CSS `@import`、`url(...)`、`srcset`、外部字体、预加载与 SVG 引用都会请求资源。
用**一个受控自定义资源 scheme** 和 `WKURLSchemeHandler` 为页面及可读的静态资源返回
经项目／机器／路径校验的数据；HTML `<base>` 不得扩展授权，
WebKit 自定义 scheme 的返回 MIME、CSP、失败与 `stop` 回调必须按真实 WebKit 行为验证。
请求和取消均绑定文件身份／代次，
禁止任何未经允许的 scheme，并在真实 WKWebView 中观察没有外部网络和文件读取。
WebKit 只是渲染末端，CSP、资源服务、导航拦截和权限每项都要有独立的失败测试。

## 任务

<a id="p1-t1"></a>
### P1-T1 建立一条安全 HTML 静态渲染与共用资源链

- **位置**：`FileViewerView` `.text` 分支、`PreviewResource`／`LocalWorkspaceBackend`、
  `HTMLFilePreview` 和真实 WebKit 宿主测试。
- **实施**：按当前 TextKit 文本快照显示 HTML／CSS，禁用 JS 且不在磁盘写 HTML；
  受控 scheme 按文件当前原文／授权目录加载页面及 CSS／图像等静态资源，
  应用真实的 CSP 和请求限额、导航／表单／新窗口拒绝。
  不把文本交给 BrowserTab，也不用 SwiftSoup 全页序列化替换原始结构。
  从第一版就让实际 `WKWebView` 及资源请求由所属 `FileTab` 持有，
  不能先放 SwiftUI `@State` 并在 P2 才迁移：源码／预览切换不应创建新的 WebKit 进程。
  共享资源权限归属完成后，当场删除旧 Markdown 专名和潜在的重复访问路径。
- **验证**：合法 HTML/CSS 及相对图片／SVG、层叠／媒体查询／HTML 空白语义、
  本机与 SSH 同名文件、Finder 项目外文件、URL 转义／`../`／符号链接、
  HTML/资源过限／损坏与内容身份变化；
  `script`、事件属性、`iframe`、`form`、`target=_blank`、`file:`、
  外部 HTTP(S)、CSS import／url、字体、`data:`／`blob:`、`srcset`、
  `meta refresh`、`base href`、恶意 SVG／外部资源及页面错误恢复。
  不仅检查配置字段，还应从真实 WebKit 的导航及资源结果证明未执行／未越权／未联网。

<a id="p1-t2"></a>
### P1-T2 复用已有 File 菜单、标签右键及 Dock 预览

- **位置**：`FileViewerView`、`FileTab`、`DockWorkspaceModel`、`Project`、
  `WorkspaceWindowModel`、`WorkspaceDockView`、`BaileyApp.swift`、`TabSwitcherView`。
- **实施**：HTML 默认源码，右键可切源码／预览／并排；
  `⌘⇧V` 继续为唯一 File 菜单命令，前台焦点目标与右键目标严格分离。
  WebKit 内容没有另一个地址栏／保存控件；切回源码仍是原 `NSTextStorage`／Undo。
  若 HTML 是第一个非 Markdown 预览，则与路由 P1-T2 **在同一提交**
  完成 Markdown 专名收敛和旧模式删除，不额外新建桥接协议／Manager。
- **验证**：双窗口、多 Dock、焦点切换、后台文件右键、
  同一 `FileTab` 在源码／预览／并排下的内容和恢复，
  Markdown 功能及菜单回归、TabSwitcher 有界缩略图、不额外启动 Browser；
  载入中、错误、不可预览文件均能返回源码。

## 阶段验收

远端连接、设备延期与任务／阶段验收统一遵循[文件预览共用验收](../../../docs/testing.md#文件预览共用验收)，
不重复公共测试。

宿主测试覆盖路径权限、拒绝规则、版本竞争、保存字节与 WebKit 配置；
真实 Bailey Dev 核对网页渲染、实际网络／子资源拦截、焦点／菜单／Dock 与暗亮主题。
使用 `make test:MarkdownResourceScopeTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
和新增 HTML 专项及 `make build`／阶段 `make test`。
按 `docs/testing.md` 逐项核销权限、极端文件、窗口、取消、恢复及适用组合；
未执行的 Mac／SSH GUI 条件明确标注，不能以组件测试替代。

### HTML 专项验收矩阵（P1）

共同文件、身份、容量、窗口与生命周期按[共享条件 R01–R11](../../../docs/testing.md#文件预览共用验收)执行；
以下每组均须准备完整的真实 HTML／CSS 夹具，通过**实际 `WKWebView` 子资源结果和本地测试监听器**判定，
不能仅检查 `WKWebViewConfiguration`、导航回调是否调用。

| 编号 | 输入和交叉条件 | 必须观察到的结果 |
| --- | --- | --- |
| H01 文档 | HTML5、`<style>`／内联 style、媒体查询、flex／grid、中文／emoji、HTML 实体、无效闭合标签、空页、UTF-8 BOM／UTF-16／用户指定编码、32 MiB 边界。 | 实际布局、文字、CSS 和错误提示符合 WebKit 静态解析；取自 FileTab **解码后的同一版本**，源文件字节不变，不能重新拿 WebKit 猜另一份编码。 |
| H02 引用链 | `page.html → styles/main.css → ../images/a.png`、CSS `@import` 多级目录、`url(...)`、中文／百分号编码文件名、相对图片／字体／SVG、资源不存在及被移走。 | 每一级以请求者自身路径解析，经同一个 root／机器授权；合法资源能真实加载，丢失只影响该资源且错误可读。 |
| H03 主动内容 | 内联及外链 `<script>`、事件属性、`javascript:`、`iframe/srcdoc`、`object/embed`、`contenteditable`、`form`、提交、`target=_blank`、下载、`meta refresh` 和 `<base>`。 | 没有脚本执行、表单提交、新窗口、重导航或越权写入；页面内控件不能把编辑器键盘／主菜单误接管，浏览器能力仍由用户显式触发。 |
| H04 子请求 | 本地测试 HTTP 监听器＋HTTPS 远链、CSS `@import/url/image-set`、`@font-face`、`srcset`、`link preload/prefetch`、SVG 的外链／`foreignObject`、`file:`／`data:`／`blob:`。 | 对被禁目标**没有 HTTP 连接或授权外资源读取**；拒绝的 CSS/图片仍有可见结果，CSP 和 scheme handler 不能互相代替。 |
| H05 范围及 MIME | 同路径 Mac／SSH、Finder 项目外文件、`../`／符号链接逃逸、带 `#/?/%` 的请求、非普通文件、HTML 装成 CSS／SVG、非法 Content-Type／MIME 嗅探。 | 受控 scheme 只按当前请求授权读取，拒绝超范围或类型混淆，不能通过 URL base 或重定向扩权；错机绝不回落本机。 |
| H06 资源预算 | 空 CSS、巨大／压缩比异常图片、单资源超限、多子资源同时请求、嵌套 CSS 循环、缓慢后端与突发取消。 | 各资源和并发加载的峰值有界；WebKit stop 与后端请求同源取消，失败不产生半成品、泄漏或无限重试。预算应根据已用 IO／解码器和实测确定，不盲加固定总量级。 |
| H07 WebKit 生命周期 | 首次预览、源码→预览→并排→源码、改项目／关标签、快速重新打开、资源尚未完成时退出、WebContent 进程异常退出。 | 同一 FileTab 的有效 WebView 与数据存储不因 SwiftUI 重绘反复新建；真关闭取消 scheme 请求并解绑 delegate。渲染进程异常退出时不自动重试，取消旧资源；切回源码再进预览能恢复，仍不执行脚本。 |
| H08 文件与 UI | `⌘⇧V`、右键背景标签、真实焦点和 IME、选择复制文字、系统 Find、不同 Dock 宽度、亮暗／1×2×。 | 单一 FileTab／Undo、同一原文、正确操作目标；预览刷新本身不会触发 FileTab 保存或新增临时 HTML。 |

按 H02×H05、H03×H04、H04×H06、H06×H07 和 H01×H08 扩展组合；
CSS／SVG 子请求安全只以隔离的本机监听和临时文件作证，禁止为验收实际请求外部恶意地址。
