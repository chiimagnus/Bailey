# P1｜SVG 安全图形查看

交付默认渲染的 SVG 文件标签、缩放与源码切换，遵守原有文件身份和安全边界。

## 方案

仍从 `Project.openFile` → `FileTab` → `FileViewerView` 进入。
SVG 源码保留在原生 `NSTextStorage` 中；渲染层可用只读 `WKWebView`，通过独立受控 HTML 页面注入安全 SVG。
不能直接 `loadFileURL` 给无边界浏览器：需禁止 JavaScript、外链导航、任意 `file://` 资源、主动内容，设置明确 CSP。
文件级 zoom／fit 状态属于该 Tab，不建新窗口或 SVG 工具模块。

## 任务

<a id="p1-t1"></a>
### P1-T1 SVG 类型识别与安全内容边界

- **位置**：`FileTab.loadedContent`、`FileViewerView`、新增 SVG 预览视图和测试。
- **实施**：按扩展名路由有效 SVG；XML 内容检测与错误定位，脚本、外链、实体扩展和其它活动内容的加载权限界限。对复杂 SVG 样本验证 WebKit 原生支持，不能一概转位图导致细节丢失。
- **验证**：正常的 viewBox、clipPath、mask、filter、文字／渐变；无效 XML、恶意脚本、远端资源请求、深度嵌套与过大输入的拒绝语义。

<a id="p1-t2"></a>
### P1-T2 渲染视图与源码命令

- **位置**：`FileViewerView`、`BaileyApp.swift` 原生命令、`docs/features/editor.md`。
- **实施**：默认全幅矢量，捏合／双击及画布右键调整视口。文件标签右键切换源码，`⌘⇧V` 仅由系统主菜单注册，只在 SVG 标签生效；无常驻控件栏，保留 TextKit 编辑缓冲。
- **验证**：图像大小、透明背景、超宽 SVG、滚轮／键盘缩放、多 Dock、窗口恢复、无焦点抢夺和深浅外观。

## 阶段验收

`make build:ui`、SVG 安全宿主测试与隔离 GUI；未编辑的 SVG 与源字节一致。
导出只写入用户明确选择的目标路径，不覆盖源文件。
