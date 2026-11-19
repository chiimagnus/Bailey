# P2｜源码与图像同步预览

交付并排实时编辑与明确的错误反馈，复用 TextKit 和同一文件保存链。

## 技术决定

沿用 P1 的 **SwiftDraw 0.30.0** 同一 SVG 解析结果和原生绘图、ImageIO／Core Graphics 负责明确的 PNG/NSPasteboard 导出；**无 WebKit、无独立 SVG 编辑器 SPM**。
实时编辑只从 `FileTab.nativeTextStorage` 复制当前请求所需的不可变源码版本，后台解析失败继续保留上一合法图形，并允许立即返回 TextKit 源码。
对复杂滤镜／蒙版的兼容性以 P1 验证为 Gate，不添加新的浏览器后备渲染路径掩盖不一致。

## 方案

`FileTab.nativeTextStorage` 更新后生成不可变渲染版本，短时合并任务；安全验证通过后仅替换 SVG 渲染内容。
并排源码／图形不得在标签内部新建通用 Splitter，必须复用 `DockNode` 外层布局职责，参照 [Markdown 并排门槛](../markdown-live-preview/plan-p2.md#p2-t1)，且只保留同一 FileTab 的唯一可写文本。
编辑中 XML 未闭合属于正常中间态，预览显示上一版并标记“预览未更新”，不把它当作当前有效内容。
`SwiftDraw.SVG`／图像绘制资源生命周期归当前 `FileTab`，按版本取消过期工作；切换不会累积旧绘图结果。

## 任务

<a id="p2-t1"></a>
### P2-T1 实时并排、错误定位与平滑缩放

- **位置**：SVG 预览组件、`FileTab` 内容版本、TextKit 编辑通知。
- **实施**：编辑快照、取消过期任务、记录最近有效渲染的版本；并排源码和图形，保持缩放／视口，错误提示精确但不遮挡文件。
- **验证**：同文件唯一编辑缓冲与 DockNode 唯一布局状态；快速输入、撤销、删除根标签、非法 XML→合法 XML、异步版本竞争、Dock 隐藏重现、关闭资源和大图性能。

<a id="p2-t2"></a>
### P2-T2 复制／导出与文件保存闭环

- **位置**：文件标签命令、既有 `FileTab.save`、新增 SVG 导出动作。
- **实施**：从原生 SVG 几何结果经 Core Graphics／ImageIO 输出 PNG，能选择像素尺寸、背景透明度和色彩空间；NSPasteboard 复制可用栅格图像。
  导出本身不写 SVG；源码保存仍经 TextKit 编码和字节版本保护。
- **验证**：实际原 SVG→并排编辑→⌘S→重开／Git Diff，外部变更与只读保护，剪贴板／目标导出结果的像素尺寸与颜色一致。

## 阶段验收

现有 `docs/testing.md` 与 Editor 真实输入验收；仅预览和导出不产生原 SVG 写入。
复杂特性若 SwiftDraw 不支持，不偷偷打开 WebKit／网络或放宽安全限制；明确标示未支持的 SVG 节点，并保持原始源码可访问。
