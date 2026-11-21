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

## 发现项

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

