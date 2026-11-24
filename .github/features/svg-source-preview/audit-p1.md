# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go（独立文件的基本图形、源码与并排已实现；P1 的完整矩阵尚未核销）。
- **依据**：真矢量、滤镜和换图有像素证据，真实复杂科研 SVG 百次压力发现的持续 RSS 增长已通过直接 Canvas 绘制修复；正式构建与冻结版完整宿主回归已通过；待物理手势、完整 App 长会话和剩余视觉矩阵。

## 任务与改动

- **P1-T1 复用 SVG 净化与 SwiftDraw，确认复杂 SVG 能力**：`SVGArtwork` 由 Markdown 与文件预览共同调用。
  独立文件使用 `FileTab` 当前文字快照，只在解析副本中统一 XML 编码声明；剔除内容同一次遍历产生提示，不写回原文。
- **P1-T2 接入共用图形视口和源码／预览／并排命令**：`SVGPreviewScrollView` 复用 `PreviewScrollView`，
  内容由原生 SwiftUI Canvas 直接调用同一 SwiftDraw 矢量绘制接口，不保留跨文档滤镜缓存；
  File 菜单、Dock companion 与 `FileTab` 模式归现有所有者。
  用户行为和边界记录在 [文件编辑器](../../../docs/features/editor.md#读取与原生内容)。

## 发现项

## 发现 F-05

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/Files/PreviewScrollViewTests.swift`
- 摘要：`真实复杂科研图的100次打开、缩放、退役与内存证据尚缺`
- 风险：`简单48点模糊图百次挂载及七格式百次混合仅覆盖少量真实科研图，无法单独核销S06×S08真实复杂图的重复绘制和释放`
- 预期修复：`沿FileTab与原生SVG文件视口执行真实科研图100次开闭，覆盖fit、100%、400%、深浅和两种窗口尺寸，核对当前绘制、实际画布释放、原字节及RSS/CPU`
- 验证：`make test ONLY_TESTING=BaileyTests/PreviewScrollViewTests/testHundredRealResearchSVGPreviewsRetireNativeCanvases; 启用BAILEY_SVG_ACCEPTANCE_ROOT`
- 解决证据：`05696bb5：真实复杂科研 SVG 百次开闭，旧共享滤镜缓存路径后段RSS增长162.2MiB，独立SwiftUI Canvas绘制后6.08MiB；真实像素、400%倍率、源字节与滤镜换图专项16/16。完整1366/1366无失败无跳过；百次12.4085秒，P95首像素67.01ms，关闭后的后五次最大RSS2796.75MiB不高于前五次2796.78125MiB，Debug/Release/UI target构建与签名通过。`


## 发现 F-04

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGFilePreview.swift:122`
- 摘要：`SVG 视口每次安装均无条件适应窗口，丢失标签缩放和平移`
- 风险：`切标签、源预览切换或移 Dock 时用户正在看的科研区域被重置`
- 预期修复：`让 SVG 复用 FileTab 和 PreviewScrollView 已有的图形视口位置所有权，跨类型与真实内容替换清理`
- 验证：`实际 FileViewerView 源码预览切换、改变窗口大小、两份同尺寸 SVG 独立位置、同类型改名、内容替换与关闭`
- 解决证据：`325ed5a6：真实 FileViewerView 的源码切换、双 SVG 各自缩放、窗口尺寸、同类型改名与内容替换；Red 11 个位置断言失败，Green 与图片共用回归 21 项全过。`


## 发现 F-03

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGArtwork.swift:57`
- 摘要：`无 use 时跳过本地资源引用展开预算`
- 风险：`大量重复 mask、clipPath、filter 或 gradient 引用可越过已定义的节点和字节预算，SwiftDraw 渲染负载与原始 XML 大小脱钩`
- 预期修复：`复用同一展开遍历覆盖无 use 的本地绘制资源引用，保持安全解析和正常画质`
- 验证：`SVGArtworkTests：分别核对重复裁剪、遮罩、滤镜的预算边界及有效 SVG 的像素；SwiftMarkdownNativeTests 和真实样本回归`
- 解决证据：`e68195e6：Red 四类超限未拒绝；Green SVG 12 项与 Markdown 原生 62 项，73 通过、1 GIF 样本条件跳过；真实科研图像素对照及正式构建验签通过。`


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

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- F-05：真实科研 SVG 百次 FileTab 开闭、fit／100%／400%、深浅与两种窗口尺寸，实际画布释放和原字节通过，但旧 SVGView 路径后半段 RSS 高水位增长 162.2 MiB，64 MiB 上限失败；显式释放截图临时对象仍重现。四个独立进程对照：无截图 62.4 MiB、固定尺寸 117.2 MiB、同尺寸简单 SVG 0.75 MiB、无缩放 61.9 MiB。定位到复杂 SVG 的绘制与共享滤镜缓存路径，不能以画布弱引用 nil 推断像素缓存已释放。
- 直接使用 SwiftUI Canvas + SwiftDraw 公开矢量绘制接口后，原完整科研图测试百次 12.68 秒、CPU 12.48 秒、首像素 P95 68.9 ms、后半段 RSS 高水位仅增 6.08 MiB；原 64 MiB 阈值及所有像素和关闭断言不变。SVG 专项 16/16 通过、零跳过，真实滤镜换图、400% 四分之一点条带均通过。旧路径失败日志 `/tmp/bailey-seven-20261124-svg-autorelease.log`，对照 `/tmp/bailey-seven-20261124-svg-probe-{noCapture,fixed,simple,noZoom}.log`，Green `/tmp/bailey-seven-20261124-svg-direct-canvas.log`。05696bb5 冻结版正式 Debug／Release、UI Target 构建及签名通过；完整宿主 1366/1366，零失败、零跳过，耗时 2007.208 秒。真实科研 SVG 百次 12.41 秒，P95 67.0 ms，后半段 RSS 峰值未增长。完整 App 与物理设备仍需独立补验。
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
- e68195e6 以真实科研文件和四种画笔引用边界验证共用预算；20e7a3f6 对独立 SVG 原生画布、Markdown 与 HTML 实际像素、
  实体拒绝、本机 TCP 零连接／正对照与原始文件字节进行交叉核验。
- `139ab5e9` 真实七格式 100 次原生挂载（4.61 秒），包含科研 SVG；验证同一标签身份、原始字节和真实关闭后的标签及资源释放。该宿主场景不替代完整 Bailey Dev GUI 的长会话。最新正式 `make build` 与严格验签通过。
- d8654917 已补字体、drop-shadow、4,000 线段和极端坐标剪裁的独立像素参考；325ed5a6 已补 SVG 重挂载位置恢复。尚缺复杂图完整 App 长会话与压力证据，阻塞完整 P1 门禁。
- 44e8ac42 的 780164 字节／13 万路径命令正常渲染约 0.91 秒；1 ms／12 ms 后取消，退役约 2.6 ms／85.4 ms，无图像返回。7873e5ea 在真实磁盘核对 32 MiB 两侧源码／预览边界与原字节。SVG 专项 15 项全部通过，P1-T1 已核销；仍保留 P1 阶段门禁。
- aa26f533：双窗口快照持久化后重新创建应用所有者，核对 SVG、CSV、HTML、Markdown 各自默认模式、临时 companion 移除、懒读取及标签复用，原字节不变。SessionStoreTests 11 项全部通过。
- 实体 1× 屏、触控板惯性／捏合、VoiceOver 和完整 App 的 SVG 多窗口冷恢复未验；实际 Retina 像素与共享 PNG
  缩放证明当前绘制路径，不证明物理设备行为。实际 Windows Tailscale 已有宿主验收结果。
- 最终 e4267d71：共享 330 项受影响回归全过（含 JPEG 边界补测），NativePaneRetentionIntegration 28 项全部通过；SVG 专项既有真实样本证据仍保留。共享执行记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- d768f481：真实 GIF／SVG 原生文件视图的四个 AX 缩放动作、菜单一致性、像素倍率、中心位置及重挂载恢复、源字节均验证通过；不替代物理输入或 VoiceOver 实际语音播报。
