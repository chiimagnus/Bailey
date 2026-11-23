# P1｜复用 FileTab 和 Markdown 模式的安全 HTML 文件预览

HTML 文件默认源码；预览是同一文件标签内的**静态只读网页**，不是第二个 Browser。
Markdown 已完成的文件菜单、Dock 并排、源码状态和资源访问能力必须沿用。

## 已有代码与技术选择

- `.html/.htm` 按现有 `FileTab.readContent → .text` 获取编码后的原文；
  `SourceTextEditor`／`FileTab.save` 继续是唯一文本、Undo、条件保存和外部冲突所有者。
  不添加 HTML `Content` case、第二份可写 DOM 或新文件标签。
- `Project.setMarkdownMode → DockWorkspaceModel.setMarkdownPreview` 和 File 菜单 `⌘⇧V`
  已有单文件源码／预览／并排语义。**在首个非 Markdown 文本格式接入时**
  依 [文件查看器计划](../file-viewer-routing/plan-p1.md#p1-t2) 把该模式／Dock companion
  从 Markdown 专名改成通用文件预览，更新所有旧调用和测试，立即删除旧分支；
  不复制一套 HTML Mode／Splitter／菜单监听。
- `MarkdownHTML`＋SwiftSoup 是 Markdown 内嵌的**受限 HTML 片段语义**，
  不能负责完整 HTML 文档、CSS 级联、媒体查询或页面布局。
  全页 HTML 预览使用独立隔离的 `WKWebView`（macOS 系统 WebKit），
  **但不复用具有完整网页权限的 `BrowserTab`**，也不让 WebKit 取得第二份编辑权。
- `MarkdownResource.relativePath/read` 已有 `LocalPathScope`、本机及 SSH 的受控相对路径读取。
  HTML 的 CSS／图片／SVG 等从同一文件身份、项目、机器和获授权目录出发，
  复用这一条真实路径解析和 IO 范围；当第二位消费者落地，
  将公共代码转为中性资源职责，替换 Markdown 的旧调用并删除同义包装，
  不能新写一套 HTML 路径清洗或让 SSH 同路径回落到本机。
  CSS／SVG／图片自身的读取预算与内容验证仍分别执行；SVG 净化可复用 `MarkdownSVG`，
  但网页 SVG 的完整 CSS 能力不能以 Markdown 的栅格显示冒充。

## 静态预览信任边界

`WKWebViewConfiguration` 使用非持久化数据存储，禁用页面 JavaScript，
对页面和子资源实施强制 CSP；不允许自发导航、脚本、表单、iframe、
弹窗、下载、网络、`file://`、任意 `data:`／`blob:` URL 或未授权相对路径。
不能把“禁用 JS”或 `WKNavigationDelegate` 仅拦截顶层点击当作子资源隔离：
CSS `@import`、`url(...)`、`srcset`、外部字体、预加载与 SVG 引用都会请求资源。
用**一个受控自定义资源 scheme** 和 `WKURLSchemeHandler` 为页面及可读的静态资源返回
经项目／机器／路径校验的数据；请求和取消均绑定文件身份／代次，
禁止任何未经允许的 scheme，并在真实 WKWebView 中观察没有外部网络和文件读取。
WebKit 只是渲染末端，CSP、资源服务、导航拦截和权限每项都要有独立的失败测试。

## 任务

<a id="p1-t1"></a>
### P1-T1 建立一条安全 HTML 静态渲染与共用资源链

- **位置**：`FileViewerView` `.text` 分支、现有 `MarkdownResource`／`LocalWorkspaceBackend`，
  新增最小 WKWebView 文件预览及 WKScheme 请求测试。
- **实施**：按当前 TextKit 文本快照显示 HTML／CSS，禁用 JS 且不在磁盘写 HTML；
  受控 scheme 按文件当前原文／授权目录加载页面及 CSS／图像等静态资源，
  应用真实的 CSP 和请求限额、导航／表单／新窗口拒绝。
  不把文本交给 BrowserTab，也不用 SwiftSoup 全页序列化替换原始结构。
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

宿主测试覆盖路径权限、拒绝规则、版本竞争、保存字节与 WebKit 配置；
真实 Bailey Dev 核对网页渲染、实际网络／子资源拦截、焦点／菜单／Dock 与暗亮主题。
使用 `make test:MarkdownResourceScopeTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
和新增 HTML 专项及 `make build`／阶段 `make test`。
按 `docs/testing.md` 逐项核销权限、极端文件、窗口、取消、恢复及适用组合；
未执行的 Mac／SSH GUI 条件明确标注，不能以组件测试替代。
