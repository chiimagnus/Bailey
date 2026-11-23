# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go（仅 P1 基础交付；P2 功能和全量回归仍未完成）。
- **依据**：P1-T1～T3 均完成且有提交映射；Markdown Host 54/54、MarkdownPreview GUI 23/23 通过；F-01～F-03 已解决。P2 的跨组件选区、精确源码映射及全仓回归不属于本阶段通过范围。

## 任务与改动

- **P1-T1**：`MarkdownDocument.parse/project/projectInline` 使用 swift-markdown AST，`MarkdownFootnotes` 仅处理扩展语法，`MarkdownPreview` SwiftUI 排版；`MarkdownResource` + `LocalPathScope`、`MarkdownSVG` + SwiftDraw、`MarkdownHTML` + SwiftSoup 做受控资源／静态内容，宿主 `SwiftMarkdownNativeTests`、`MarkdownResourceScopeTests` 及真实图片 GUI 通过。提交 `9d8fa6f9`、`76c1b1c6`。
- **P1-T2**：`Project`、`FileTab`、`FileViewerView`、`BaileyApp`、`WorkspaceWindowModel` 和 `DockWorkspaceModel` 共用文本缓冲、Undo 与保存链路；同一文件切换源码／预览或在 Dock 并排。`AppIdentityTests`、`MarkdownPreviewUITests` 复验菜单、保存、窗口焦点及 Undo。提交 `9d8fa6f9`。
- **P1-T3**：`MarkdownPreview` 对齐 Primer 字阶、行距、分割线、列表／表格、代码块与悬停复制；`MarkdownLinkGlyph` 用真实字形定位手形指针，跟踪区域与 `NSClipView.documentView` 同坐标；标题锚点保留原生按钮与聚焦。真实中文仓库文档在窄/宽和明/暗窗口截图、末尾滚动、原文件字节保持不变。提交 `9ddc6f33`（原生公式作为同一可构建渲染增量一起提交，P2-T4 仍单独验收）。

## 发现项

## 发现 F-03

- 任务：`P1-T3`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:254-273`
- 摘要：`标题锚点完全透明时原生按钮失去可悬停命中区域`
- 风险：`GitHub 风格的隐藏锚点无法可靠显示手形、激活或被辅助功能定位`
- 预期修复：`保留可聚焦按钮，绘制透明度 0.001，明确 20x24 pt contentShape 矩形并在 Hover/Focus 显示`
- 验证：`MarkdownPreviewUITests/testHoverUsesHandOnlyForActualMarkdownLinks; 真实 I-beam/hand 光标截图及标题复制与返回导航 GUI`
- 解决证据：`commit 9ddc6f33; red /tmp/bailey-markdown-p1-final-ui.log; green /tmp/bailey-markdown-pointer-ibeam-and-anchor-fixed.log; 光标真实截图 /tmp/bailey-markdown-pointer-images-1122`


## 发现 F-02

- 任务：`P1-T3`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:159-202`
- 摘要：`链接光标跟踪区域曾绑定在固定窗口坐标，超长段落滚动后错位`
- 风险：`鼠标悬停文本链接不能稳定切换手形，命中区域可能落在其他内容上`
- 预期修复：`跟踪区域绑定最近的 NSClipView.documentView，以滚动内容坐标计算并在拆卸时释放`
- 验证：`SwiftMarkdownLayoutTests 长段落首屏及滚动后逐矩形坐标对齐，真实 GUI 链接悬停与点击`
- 解决证据：`commit 9ddc6f33; /tmp/bailey-markdown-host-baseline.log red -> /tmp/bailey-markdown-p1-p2-host-audit-1122.log Host 54/54; /tmp/bailey-markdown-all-ui-1122.log MarkdownPreview 23/23`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/MarkdownPreview.swift:750-778`（当前 `MarkdownNativeText.attributed`）
- 摘要：`Markdown 链接内的加粗、斜体与删除线被 plain(children) 扁平化`
- 风险：`GFM [**强调**](path.md) 的链接仍可点击，但文本格式丢失，违反 AST 原生语义渲染`
- 预期修复：`使用同一套 MarkdownInline 树构造带样式的 AttributedString，并给链接应用 destination；不再将子节点 flatten 成纯文本`
- 验证：`添加字体格式语义宿主回归，复跑 Markdown Host 与相关 native GUI 预览`
- 解决证据：`commit 76c1b1c6；Host 37/37：/tmp/bailey-markdown-audit-f01-retest2.log，原生 HTML／相对文件链接 GUI 2/2：/tmp/bailey-markdown-audit-f01-gui.log；回归覆盖粗体、斜体、删除线嵌套链接`


## 验证与未覆盖

- **Host**：`make test SIGNING=adhoc DERIVED_DATA=.build/DerivedData-Dev SOURCE_PACKAGES=.build/SourcePackages ONLY_TESTING='BaileyTests/SwiftMarkdownLayoutTests BaileyTests/SwiftMarkdownNativeTests BaileyTests/SwiftMarkdownMathPerformanceTests BaileyTests/MarkdownResourceScopeTests BaileyTests/AppIdentityTests'`，54/54 通过、退出码 0，证据 `/tmp/bailey-markdown-p1-p2-host-audit-1122.log`。
- **真实 GUI**：`MarkdownPreviewUITests` 23/23 通过（`/tmp/bailey-markdown-all-ui-1122.log`），含相对链接、图片、SVG、HTML、音频、代码复制、手形/I-beam、脚注、普通跨段落选择、并排编辑/保存、真实仓库长文档；原生公式两项独立运行均通过（`/tmp/bailey-markdown-math-{inline,nested}-isolated-final.log`）。**合并运行 25 项时仍有 2 个测试失败**：剪贴板 changeCount 与隔离窗口 0；完整合并测试为 `TEST FAILED`，不得改写为 25/25 通过。
- **渲染负载**：单独窗口 500/5,000/20,000 段落首屏约 7ms、滚动 13/51/180ms；含链接区域的对应滚动约 25/139/517ms，跟踪区域始终 20；20,000 混合公式段落解析约 1.19s。数字均来自宿主进程共享窗口负载，不能推断实际 GUI P95 或按文档独占内存。
- **隔离和构建**：`make build:dev`、`git diff --check`、`plutil -lint Bailey.xcodeproj/project.pbxproj`、`codesign --verify --deep --strict` Dev App 通过。GFM、BOM+CRLF、MDX 禁执行、HTML/SVG 净化、SSH 同名路径和符号链接逃逸均有独立宿主用例。编辑器 Markdown 渲染器无 WebKit／Textual 双实现；项目浏览器中的 `WKWebView` 属于另一个模块，不可误删。
- **未覆盖/交 P2**：实际授权 SSH、32 MiB 真实 GUI、UTF-16 重载、长文编辑时主线程停顿、VoiceOver 与多窗口 IME 尚待验证。现有跨段落复制依赖 12 段落一组的 `Text`；跨组、表格/代码/图片/公式的连续选区与精确源码映射尚未完成，分别由 P2-T5/T6/T9 负责，不得用 P1 的 23/23 代替其验收。
- **文档和提交**：`9d8fa6f9`（P1-T1/T2）、`76c1b1c6`（F-01）、`9ddc6f33`（P1-T3）均已核对代码和真实调用链；产品文档及 `NOTICE.md` 随源码提交。`.github/features/markdown-live-preview` 计划／todo／audit 仍单独作为执行记录维护，不混进功能提交。

