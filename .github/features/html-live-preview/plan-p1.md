# P1｜同一文件标签的静态 HTML 预览

交付默认源码、可切换的安全静态预览，界面仅保留 Bailey 原有标签栏。

## 技术决定

**HTML 是本次唯一明确使用 WebKit 的文件格式**，直接采用系统 **`WKWebView`／`WKWebViewConfiguration`／`WKNavigationDelegate`／`WKURLSchemeHandler`**，无额外网页渲染器 SPM、Electron 或 Chromium，也不复用有完整浏览器权限的 Bailey BrowserTab。
静态页面默认禁用 JavaScript，限制内容安全策略（CSP）、导航、窗口打开、表单提交、网络加载与任意 `file://`；使用非持久化 `WKWebsiteDataStore`，用户能访问的相对 CSS／图片／SVG 由专门的受控资源 scheme 经当前 `WorkspaceBackend` 路由，真实访问时重新检查项目／机器／路径权限。
这不是“把 WebKit 当安全沙盒”而放任内容执行：配置、导航拦截、CSP、资源访问限制必须分别验证；禁用 JS 不能代替限制 CSS、图片和 URL 侧的远程资源。
HTML 全页**不必**先用 SwiftSoup 重新序列化（那会破坏原页面 CSS 和文档结构）；Markdown 片段中的危险 HTML 则复用 Markdown 计划已选的 SwiftSoup 受限白名单。
源文件编辑继续复用已有 TextKit 2 的唯一缓冲与保存链；WebKit 只承载静态、只读渲染快照。

## 方案

沿 `Project.openFile` → `FileTab` → `FileViewerView` 添加 HTML 显示模式。源码仍由现有 `SourceTextEditor` 保存与 Undo。
预览使用独立受控 `WKWebView`／非持久化配置，通过受限自定义 scheme 加载可授权的 HTML／CSS／项目内静态资源，不以任意本地 file URL 或网络导航代替访问授权；不把源 HTML 交给现有可执行 Browser。
右键命令在 `WorkspaceDockView` 的文件标签上下文扩展，真实键盘命令在 `BaileyApp.swift` 的系统主菜单注册，仅对当前窗口活动的可渲染文件生效。

## 任务

<a id="p1-t1"></a>
### P1-T1 类型入口与静态内容安全边界

- **位置**：`FileTab` 文件类型判定、`FileViewerView`、新增 HTML 静态预览、安全测试。
- **实施**：源码默认，`WKWebViewConfiguration` 禁止网页 JavaScript，`WKURLSchemeHandler` 仅服务经当前工作区身份验证的相对静态资源；CSP 默认 deny，并由 `WKNavigationDelegate` 拒绝自动导航、外链／file URL、弹窗与表单提交。
  网络/权限被拒绝时显示具体资源占位或错误；渲染只从 FileTab 当前原生文本快照取得，不创建第二份可写 HTML。
- **验证**：不同 CSS 层叠与媒体查询、HTML/CSS、图片/SVG 静态资源、相对路径含 URL 编码/`../`/symlink、无权限本地与 SSH 同名文件。
  验证 `script`、内联事件、CSS import、remote font/image、iframe、form、target=blank、`data:`／`blob:`／`file:`／外部 HTTPS 均被正确约束；无效编码、过大页面和刷新期间身份变化不得泄漏本地数据、发出未授权网络请求或执行 JavaScript。

<a id="p1-t2"></a>
### P1-T2 主菜单命令与文件标签视图切换

- **位置**：`BaileyApp.swift` 系统菜单、`WorkspaceDockView` 标签右键、`FileViewerView`、`docs/features/editor.md`。
- **实施**：当前标签可选「源码／预览／并排」；`⌘⇧V` 在源码／预览切换；右键不复制键盘绑定，不显示快捷键提示。仅复用已有 Dock 标签，没有内容工具栏或路径栏。
- **验证**：两窗口及多 Dock、右键后台标签不误操作当前文件、原生菜单权限、无键盘重复派发、系统文本选择／输入法焦点保持。

## 阶段验收

`make build:ui`、host 内容安全测试与隔离 GUI。预览只读；打开和切换前后的原始文件字节完全一致。
