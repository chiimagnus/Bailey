# P1｜SVG 安全图形查看

交付默认渲染的 SVG 文件标签、缩放与源码切换，遵守原有文件身份和安全边界。

## 技术决定

- **SPM：[SwiftDraw 0.30.0](https://github.com/swhitty/SwiftDraw)**，纯 Swift 原生 SVG parser/renderer；以 `SVG(data:)`／`SVGView(svg:)` 展示，Core Graphics 导出，不在 SVG 文件预览中创建 `WKWebView`。
  支持 viewBox、路径、常见渐变等，**并非完整浏览器 SVG/CSS 实现**：filter、mask、clipPath、字体、外部引用、复杂 SVG 动画需要对照真实样本确认；不支持时应有明确提示／源码回退，不能默默输出错误图片。
- **系统框架：**AppKit `NSScrollView` 负责双指滚动、惯性及原生缩放，`setMagnification(_:centeredAt:)` 保障锚点；TextKit 2 继续编辑原始 SVG XML。无第二套 SVG 输入状态、图层缓存或手势框架 SPM。
- **实证：**SwiftDraw 0.30.0 在 Swift 6.4.2／Xcode 27.2 通过隔离 SwiftPM 构建，并成功解析本计划 `demo-plot.svg` 为 900×520；尚需验证滤镜／复杂文档的视觉精度、安全输入边界以及 Bailey GUI 手势。

## 方案

仍从 `Project.openFile` → `FileTab` → `FileViewerView` 进入。
SVG 源码仍保留在唯一原生 `NSTextStorage` 中；渲染时从该版本的不可变源数据建立 `SwiftDraw.SVG`，使用原生 SwiftUI/CG 图像展示，错误不覆盖上一次有效显示。
在传给 SVG parser 前限制文件字节、XML 层深、实体膨胀和外部 href；禁止未授权的本机路径、网络请求与活动脚本，不因为没有 WebKit 就略过 XML 信任边界。
文件级 zoom／fit 状态属于该 Tab，不建新窗口或 SVG 工具模块。

## 任务

<a id="p1-t1"></a>
### P1-T1 SVG 类型识别与安全内容边界

- **位置**：`FileViewerView` 的 `.text` 分支、`FileTab.nativeTextStorage`、新增 SVG 预览视图和测试；
  复用已验证的文本读取，按 [文件渲染接入边界](../file-viewer-routing/plan-p1.md) **不新增 SVG `Content` case 或改写 `loadedContent`**。
- **实施**：按扩展名路由有效 SVG，调用 SwiftDraw `SVG(data:)`；XML 输入和外部资源访问必须先有范围／权限限制，拒绝脚本、外链、扩展实体和主动内容。
  用官方 SVG fixture 和 Bailey 科研绘图检查 `clipPath`、`mask`、`filter`、pattern、gradient、变换和 text 渲染差异；未覆盖的 SVG 特性须有可见回退，不能假装 SwiftDraw 和 WebKit 完全等价。
- **验证**：与系统参考渲染的像素／结构对比正常 viewBox、clipPath、mask、filter、pattern、文字、渐变、透明度、复杂 path；识别支持矩阵和差异阈值。
  无效 XML、实体膨胀、恶意脚本、外部资源引用、深嵌套和过大输入必须拒绝或明确降级；无额外网络请求／本地越权。

<a id="p1-t2"></a>
### P1-T2 渲染视图与源码命令

- **位置**：`FileViewerView`、`BaileyApp.swift` 原生命令、`docs/features/editor.md`。
- **实施**：默认 fit 全幅矢量；复用图片查看同一 `NSScrollView` 平移／捏合／鼠标滚轮／⌘＋滚轮以指针为锚点缩放、拖拽与双击行为，直接重绘矢量，不通过 4096px 位图伪装原始精度。文件标签右键切换源码，`⌘⇧V` 仅由 **File 主菜单**的共同命令注册；无常驻控件栏，保留 TextKit 编辑缓冲。
- **验证**：图像大小、透明背景、超宽 SVG、滚轮／键盘缩放、多 Dock、窗口恢复、无焦点抢夺和深浅外观。

## 阶段验收

`make build:ui`、SVG 安全宿主测试与隔离 GUI；未编辑的 SVG 与源字节一致。
导出只写入用户明确选择的目标路径，不覆盖源文件。
