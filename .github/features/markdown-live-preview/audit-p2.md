# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go
- **依据**：源码始终只由原生文件标签持有。隔离 App 已验收并排、实时刷新、保存和富内容，
  没有在标签内部另建分屏、编辑器或 WebView。

## 任务与改动

- **P2-T1**：`dbf8e688`。并排只是 Dock 中同一标签的只读展示位置；
  原生编辑事件推进预览版本，异步结果核对请求身份，源码与预览保留各自阅读位置。
- **P2-T2**：`f8eef109`。同机项目内链接复用已有后端及标签，恢复为源码，
  预览位置不进入会话文件，不改原编码、条件保存和冲突检查。
- **P2-T3**：`9334d775`。有界 ImageIO、SwiftDraw 静态 SVG、受限 HTML 和按需 AVKit，
  无外部资源或媒体引用。对新快照隔离 Textual 的在途附件结果。
- **P2-T4**：`db1b11f`。原生 Mermaid 位图及失败回显，Textual／SwiftUIMath 公式，
  本文脚注锚点。README 入口、功能文档、固定依赖及原许可证同步。

## 发现项

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

