# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go（独立文件的基本图形、源码与并排已实现；P1 的完整矩阵尚未核销）。
- **依据**：真矢量、滤镜收敛和换图有像素证据，两项发现均关闭；复杂图、物理手势与完整 App 长会话仍待核对。

## 任务与改动

- **P1-T1 复用 SVG 净化与 SwiftDraw，确认复杂 SVG 能力**：`SVGArtwork` 由 Markdown 与文件预览共同调用。
  独立文件使用 `FileTab` 当前文字快照，只在解析副本中统一 XML 编码声明；剔除内容同一次遍历产生提示，不写回原文。
- **P1-T2 接入共用图形视口和源码／预览／并排命令**：`SVGPreviewScrollView` 复用 `PreviewScrollView`，
  内容交给 SwiftDraw `SVGView`；File 菜单、Dock companion 与 `FileTab` 模式归现有所有者。
  用户行为和边界记录在 [文件编辑器](../../../docs/features/editor.md#读取与原生内容)。

## 发现项

## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/SVGArtworkTests.swift:18`
- 摘要：`已核对单图滤镜收敛，尚未证明重复重挂载和引入另一 SVG 后不保留旧图`
- 风险：`真实 SwiftDraw Canvas 缓存填充后可能保留旧子树或让另一个同尺寸图绘制旧滤镜`
- 预期修复：`在真实窗口覆盖同尺寸不同颜色滤镜替换及 100 次原生视口挂载和退役，记录可见像素与内存`
- 验证：`make test:SVGArtworkTests`
- 解决证据：`提交 a564658c。同尺寸红色→蓝色 Canvas 滤镜尾迹实际换色，旧色不再绘制；两种外观 100 次原生视口挂载与清空，约 0.45 秒，峰值 RSS 167952384→181977088 字节；61 项宿主全过。`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/MarkdownResourceScopeTests.swift:100`
- 摘要：`独立 SVG 尚未经过真实 SSH 与同名本机文件的组合`
- 风险：`Markdown 相对资源验证不能证明独立文件会发起正确的读取并使用远端原文`
- 预期修复：`在既有隔离 SSH 夹具中通过 FileTab 打开独立 SVG，核对像素、断线不降级和重连后实际远端版本`
- 验证：`已授权 Windows Tailscale 上的 make test:MarkdownResourceScopeTests`
- 解决证据：`提交 27ede424；获授权 Windows Tailscale 隔离 SSH，实际绿色像素、远端原图 40→52 点、断线时 FileTab 不读取本机同名原文，重连后代次变化；46 项有关宿主通过。`


## 验证与未覆盖

- 设备为本机 macOS 27.3／Xcode 27.2、Apple Silicon、内置 Retina。按用户确认不要求 macOS 15.6 实机；部署目标保持不变。
- 68 项相关宿主通过，包括 54 项 Markdown 原生回归。独立 `make test:SVGArtworkTests` 六项通过：
  仓库 `demo-plot.svg`、旋转和 mask 的像素、400% 真实窄线、滤镜异步后形状外像素、XML 声明和输入边界。
  XML 声明回归先因旧行为抛出解析错误，修复共享解析副本后通过。
- macOS 27.3 隔离 GUI 三项通过：打开大写后缀 SVG 后采图像中心像素，确认剔除提示和源码／并排；
  损坏和超限 SVG 实际点击链接后返回原始文本并核对字节；共享视口的 PNG 双击适合／原像素回归。
  `make build` 成功并完成 `codesign --verify --deep --strict`。
- 46 项资源、原生生命周期、CSV 索引和 SVG 有关宿主通过；真实 Windows Tailscale 同名隔离、断线和重连均验证。
- 随后 61 项宿主通过，包括 SVG 七项、原生 Markdown 54 项。同尺寸图由红色替换蓝色后，采到当前滤镜尾迹且无旧色；
  100 次深浅原生挂载均清空旧画布，约 0.45 秒，峰值 RSS 167952384→181977088 字节。
- 尚缺复杂科研文件的逐元素参考图（字体、drop-shadow 与极端路径）、主动内容与 SVG 子请求的监听组合、
  以及复杂图的完整 App 开关、进程保留量和压力证据。仓库样本、原生像素和已有白名单测试不能替代这些组合。
  需补真实样本、同解析器的隔离子资源零 IO／边界验证及复杂图长会话，阻塞 P1 完整门禁。
- 实体 1× 屏、触控板惯性／捏合、VoiceOver 和完整 SVG 多窗口冷恢复未验；实际 Retina 像素与共享 PNG
  缩放证明当前绘制路径，不证明物理设备行为。Windows Tailscale 已有宿主结果；没有获授权的 Linux 别名，不能替代 Linux E2E。

