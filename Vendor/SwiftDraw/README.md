# SwiftDraw

来源：[SwiftDraw](https://github.com/swhitty/SwiftDraw/tree/ad1eb8c20177afbbb8b00e0f706f84c64aa672cc)。
保留库编译所需的 `DOM/Sources`、`SwiftDraw/Sources` 及 [zlib 许可证](LICENSE.txt)，
不导入 CLI 目标、示例或测试资源。
`Package.swift` 为 Bailey 的 macOS 本地包入口。

## Bailey 补丁

位图绘制在当前倍率绘制矢量图案单元，按连续坐标重复取样，再通过填充或描边轮廓合成。
不用按整数像素移动图案单元来遮掩半透明接缝，也不缓存整个 SVG 的位图。
保留非位图上下文的上游绘制行为。
升级时用 Bailey 的 `SVGArtworkTests` 核对小数倍率、图案相位、透明度、描边和实际图形像素。
