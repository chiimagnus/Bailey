# P1｜同一文件标签的静态 HTML 预览

交付默认源码、可切换的安全静态预览，界面仅保留 Bailey 原有标签栏。

## 方案

沿 `Project.openFile` → `FileTab` → `FileViewerView` 添加 HTML 显示模式。源码仍由现有 `SourceTextEditor` 保存与 Undo。
预览使用被限制内容权限的 `WKWebView`；只加载经批准的 HTML／CSS／本地静态资源，不把源 HTML 交给现有可执行 Browser。
右键命令在 `WorkspaceDockView` 的文件标签上下文扩展，真实键盘命令在 `BaileyApp.swift` 的系统主菜单注册，仅对当前窗口活动的可渲染文件生效。

## 任务

<a id="p1-t1"></a>
### P1-T1 类型入口与静态内容安全边界

- **位置**：`FileTab` 文件类型判定、`FileViewerView`、新增 HTML 静态预览、安全测试。
- **实施**：源码默认；限定同一已授权工作区的相对静态资源。禁用脚本与主动内容，阻断外部网络／file URL／自动导航，明确缺失资源结果。不将完整 HTML 复制为另一个可编辑状态。
- **验证**：HTML/CSS、图片、SVG 静态资源、未授权 URL、脚本、表单、iframe、外部资源、无效编码和文件大小边界。验证无网络请求和脚本执行。

<a id="p1-t2"></a>
### P1-T2 主菜单命令与文件标签视图切换

- **位置**：`BaileyApp.swift` 系统菜单、`WorkspaceDockView` 标签右键、`FileViewerView`、`docs/features/editor.md`。
- **实施**：当前标签可选「源码／预览／并排」；`⌘⇧V` 在源码／预览切换；右键不复制键盘绑定，不显示快捷键提示。仅复用已有 Dock 标签，没有内容工具栏或路径栏。
- **验证**：两窗口及多 Dock、右键后台标签不误操作当前文件、原生菜单权限、无键盘重复派发、系统文本选择／输入法焦点保持。

## 阶段验收

`make build:ui`、host 内容安全测试与隔离 GUI。预览只读；打开和切换前后的原始文件字节完全一致。
