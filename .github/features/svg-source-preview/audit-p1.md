# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go（独立文件的基本图形、源码与并排已实现；P1 的完整矩阵尚未核销）。
- **依据**：P1-T1、P1-T2 的图形、模式与接线均完成；完整 App 四象限 15.041 秒、高倍率 39.753 秒、修复后图案整包 20.585 秒和双窗 117 次通过。共用实体触控板捏合经用户确认通过，普通鼠标滚轮见图片 P1；基础 AX 缩放语义和动作已实测，共享最终整合留阶段，不再要求无关显示／输入组合，缺配物理 1× 延期。
- **现行 AX 验收**：依[共享验收环境](../../../docs/testing.md#文件预览共用验收)，下文 VoiceOver 记录仅为历史证据，专项语音不再阻塞。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../../../docs/testing.md#文件预览共用验收)；可执行项仍需验收。

## 任务与改动

- **P1-T1 复用 SVG 净化与 SwiftDraw，确认复杂 SVG 能力**：`SVGArtwork` 由 Markdown 与文件预览共同调用。
  独立文件使用 `FileTab` 当前文字快照，只在解析副本中统一 XML 编码声明；剔除内容同一次遍历产生提示，不写回原文。
- **P1-T2 接入共用图形视口和源码／预览／并排命令**：`SVGPreviewScrollView` 复用 `PreviewScrollView`，
  原生 NSView 按当前裁剪区域及设备倍率使用 SwiftDraw 绘制，再按原像素合成；不保留跨文档滤镜缓存或整张缩放位图。
  File 菜单、Dock companion 与 `FileTab` 模式归现有所有者。
  用户行为和边界记录在 [SVG 矢量预览](../../../docs/features/svg-preview.md)。

## 发现项

## 发现 F-11

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGArtwork.swift:9`
- 摘要：`真实 shale_shpb/data 中四份合法科研叠加 SVG 含 4155 至 7332 个直接节点，旧 4096 节点预算误拒。`
- 风险：`合法密集科研曲线无法预览。`
- 预期修复：`共用净化节点预算提高到8192，保留输入/展开字节、深度、本地引用和位图像素限制。`
- 验证：`实际273份原生视口绘制、源文件字节不变，8192/8193节点及引用/字节边界诊断、构建及相关回归。`
- 解决证据：`67c3c302：旧版直接链接产品原生诊断269/273，4个合法叠加图因节点超限被拒；新版本273/273适应视口、可见墨迹及源字节不变检查全部通过，115.90秒、峰值RSS275.55MiB。边界诊断20项通过，8191个圆全部显示，8192/8193总节点接受/拒绝、1MiB及引用深度和展开字节边界保留。Debug严格验签及宿主测试目标构建通过；XCTest执行仍受会话握手阻塞。`


## 发现 F-10

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift`
- 摘要：`真实科研 SVG 使用 pt 定义小画布，继承栅格 fit 的原像素上限而显示过小，400% 手动倍率亦限制细节检查。`
- 风险：`科研曲线与标记难以辨认，放大体验不符合矢量文件查看需求。`
- 预期修复：`SVG 沿用共用视口但独立采用可放大的 fit 与 6400% 或四倍 fit 的较大倍率上限，重新绘制当前可见矢量。栅格规则保持原样。`
- 验证：`直接链接实际 Debug 产品检查真实科研图 fit、400/1600/6400% 像素细节、极小 SVG 与视口恢复；构建及正式 XCTest/GUI。`
- 解决证据：`76330ab4 真实科研图 fit 136.26×114.28→572.33×480 点、400/1600/6400% 细线、极小图视口及栅格限制宿主验证通过。后续本机完整 App testNativeZoomResolvesFineVectorDetailInTheActualWindow 39.753s 通过，真实窗口从100%连续9次原生菜单放大至745%，四分之一单位色带超过30次转换，源字节不变。日志 /tmp/bailey-xc-recheck.hgaWdv/matrix.log；混合套件其它失败不作为该用例通过。`


## 发现 F-09

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`SwiftDraw 0.30.0 CGProvider.createSRGB/createColorSpace`
- 摘要：`实际原生视口截图的SVG颜色明显偏离sRGB参考；0.30.0 将SVG sRGB定义为DeviceRGB，导致显示设备色彩空间改变原色。上游b042daf已修复。`
- 风险：`图例、科研颜色编码、深浅及不同显示设备的颜色不一致。`
- 预期修复：`固定包含上游sRGB及pattern精确平铺修复的可复现SwiftDraw提交；不重写颜色规则。`
- 验证：`真实屏幕/位图色彩、sRGB与Display P3输出、SVG与Markdown全部相关回归和构建。`
- 解决证据：`1b6928bd：固定 SwiftDraw ad1eb8c20177afbbb8b00e0f706f84c64aa672cc（含 sRGB 与图案修复），经 ICC 转换核对实际 RGBA；23 项 SVG 专项及合计 180 项受影响宿主、Debug／Release 签名通过。实体显示设备仍归阶段门禁。`


## 发现 F-08

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGArtwork.swift:99`
- 摘要：`科研SVG实际全图的水平pattern网格相位偏移，参考y=320/360/400而当前PNG/native约y=339/379/419，曲线及坐标轴不偏移`
- 风险：`网格不能作为精确科研读数依据，且非对称pattern可能更明显`
- 预期修复：`定位SwiftDraw公开CGContext绘制与默认图案坐标变换，使用明确的设备基准并验证非对称图案和多倍率`
- 验证：`真实科研图与独立参考的网格像素、native及PNG输出、不同倍率及旋转图案`
- 解决证据：`1b6928bd：统一 SwiftDraw 绘制坐标；真实科研图网格位置与独立 WebKit 参考吻合，非对称图案在 PNG／Markdown／50%～400% 视口及裁剪平移下通过实际像素断言。`


## 发现 F-07

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGFilePreview.swift:113`
- 摘要：`真实七格式 GUI 中科研 SVG fit 只显示左上角约半宽半高；导出能显示完整内容，旧测试未验证可见范围。`
- 风险：`默认查看遗漏曲线、坐标轴和文字，科研图误读。`
- 预期修复：`复现原生视口实际整图像素，修复矢量绘制表面与滚动倍率/裁剪坐标不一致的根因。`
- 验证：`全图参考、多个实际窗格尺寸/倍率/平移、SVG 及共用视口宿主与完整 GUI、原始字节。`
- 解决证据：`1b6928bd 修复整图裁切；原生四窗格、科研图全图和像素对照通过。后续本机完整 App testLargeSVGFitShowsAllFourCornersAfterSourceRemount 实际 15.041s 通过，源码来回重挂载前后四象限真实像素和源文件字节均验证。混合套件另有失败，不宣称整个套件通过；日志 /tmp/bailey-xc-recheck.hgaWdv/matrix.log。`


## 发现 F-06

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/SVGArtwork.swift:152-210`
- 摘要：`用户新要求支持高级 SVG；SwiftDraw 已支持 pattern 和 PNG/JPEG 内嵌图像，Bailey 净化层一律删除`
- 风险：`真实科研图的图案填充及内嵌位图丢失；开放 href 不得引入外部读取或解码炸弹`
- 预期修复：`共享净化层允许原生支持的本地 pattern/继承引用和实际 PNG/JPEG base64 位图；复用扩展引用预算和 RasterPreview 类型/尺寸检查，拒绝外部 URL、循环与累计解码超限`
- 验证：`实际图案平铺/继承/变换、PNG/JPEG 内嵌像素和原生预览/导出；同文档引用循环/预算、错误 MIME、损坏/大尺寸位图，三入口恶意资源隔离，真实科研图与WebKit参考`
- 解决证据：`4e15407e：实际红蓝图案/继承平铺、PNG/JPEG 内嵌像素，外部 URI、引用循环、累计像素预算测试通过；SVGArtworkTests 20/20、实际科研 SVG 百次开闭、Markdown/HTML 共享净化回归通过。完整 App SVG 6项分轮通过（12:09:22 的5项与12:17:17的实时编辑/Undo/Redo/复制/导出）。`


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

- 2026-11-25：`48bbbd5d` 修复小数倍率图案接缝。旧版在 439 像素输出中出现 8,253 个非预期透明或错色像素；
  修复后测试的 5 个尺寸均为零。图案单元随当前倍率绘制，按连续坐标取样，不移动图案周期。
  宿主 92 项通过（含单独补验真实 GIF），核对半透明、真实留白、反射斜切、奇偶填充、虚线描边、科研图及原字节。
  WebKit 对照中 PNG 与原生画布不匹配均低于 0.08%；273/273 份科研 SVG 的真实视口检查通过。
  Debug、Release 与 UI Runner 构建并验签，未替换正式 App。
  原先失败的整包 Bailey Dev SVG 用例通过（未改断言），验证文件树打开、实际像素、源码与并排切换，以及源文件不变。
  证据：`/tmp/bailey-svg-pattern.VdeHsm/`。本条不核销实体设备门禁。

- 2026-11-25：本机完整 App XCTest 在 `testDefaultVectorPaintsAndSharesSourceAndCompanionActions` 的中心像素失败。录像显示红色图案已渲染，但实有半透明细缝；同一 SVG 用当前发布绘制链在分数缩放复现，439 px 图面内部 103,912 像素中 8,236 个 alpha 小于 250。用原生 `CGPattern` 独立复现，`.noDistortion` 分数像素周期时出缝，整数周期无缝；常间距并非通用修复：双彩图案在 37.5 px 周期下取整为 38 px，末侧边界由 x=656 移至 x=665；75 px 周期下半像素色段仍有细缝（`cg-phase.log`）。SwiftDraw `c1f274c` 的原始取舍也吻合。不能放宽截图断言或简单切回常间距。当时尚未修复；后由上条核销该缺陷，实体设备门禁不变。证据：`/private/tmp/bailey-xc-recheck.hgaWdv/` 的 `matrix.log`、`svg-evidence.png`、`svg-pattern-alpha.txt` 和 `cg-tiles.log`。

- 2026-11-25：在包含 `67c3c302` 的 macOS Bailey Dev 整包中，使用独立配置，
  通过系统文件打开实际科研图 `Fig3-5c.svg` 和此前误拒的 `Fig5e_impact1.svg`，均完整显示。
  前者从 100% 切换到 Fit 后，紫色曲线横向跨度由约 220 增至 753 个设备像素；
  放大后返回 Fit，视口像素与先前 Fit 一致。0.25 单位细线在实际窗口放大后仍可分辨；
  两份科研文件的 SHA-256 未变，正式 App 未替换。截图见 `/tmp/Bailey-UITest-SVG-Visual.sYG8ux/`。
  本轮 XCTest 的 `testmanagerd` 会话握手超时，零用例开始；此处只记录整包手动验收，不核销自动化或实体设备门禁。

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
- 最终 e4267d71：共享 330 项受影响回归全过（含 JPEG 边界补测），NativePaneRetentionIntegration 28 项全部通过；SVG 专项既有真实样本证据仍保留。共享执行记录见 文件路由 P1 审计（Git 历史 `dc78cad7:.github/features/file-viewer-routing/audit-p1.md`）。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 文件路由 P1 审计（同一历史记录）。
- d768f481：真实 GIF／SVG 原生文件视图的四个 AX 缩放动作、菜单一致性、像素倍率、中心位置及重挂载恢复、源字节均验证通过；不替代物理输入或 VoiceOver 实际语音播报。

- 2026-11-25：`1b6928bd` 修复整图裁切、图案坐标与颜色。23 项 SVG 专项包含真实科研图、非对称图案在不同倍率及裁剪平移下的位置、400% 细线、滤镜和 PNG 输出；与独立 WebKit 参考的抽样比较（1 像素邻域、通道容差 0.15），PNG 163/214984、原生视口 169/214984 不匹配，均低于 0.08%。真实科研 SVG 百次开闭 16.746 秒，首像素 P95 60.21 ms，后五次关闭采样 RSS 高水位较前五次增加 0.625 MiB。受影响宿主合计 180/180，零失败、零跳过，含真实 Windows SSH；Debug、Release（58 MiB）和 UI Runner 构建、严格签名通过。完整 App UI Runner 因 `Timed out while enabling automation mode` 未能发现或执行用例，新增四象限 fit 与 400% GUI 验证仍待执行；正式 App 未替换。首次宿主运行被命令默认超时中断，已清理本次专属临时 SSH 与本地／远端夹具；分段复验通过。日志：`/tmp/bailey-svg-affected-regression-20261125.log`、`/tmp/bailey-svg-affected-regression-resumed-20261125.log`、`/tmp/bailey-svg-enumeration-20261125.json`。

- 2026-11-25：`76330ab4`、`67c3c302`。Quick Look 正常的 Fig3-5c 在同一 620×480 点视口由 136.26×114.28 点扩大至 572.33×480 点；直接链接实际 Debug 产品的隔离原生诊断遍历 shale_shpb/data 全部 273 份，fit、可见墨迹及原字节不变 273/273 通过，400%／1600%／6400% 细线像素检查通过。总耗时 115.90 秒，峰值 RSS 约 276 MiB；另 20 项边界诊断及 8191 圆形像素通过。节点预算由 4096 提升至 8192，1 MiB 与其他预算保留。Debug 严格签名、宿主/UI测试目标构建通过，XCTest 会话握手阻塞（非断言失败），未运行正式用例或完整 GUI，未替换正式 App。诊断日志见 `/tmp/bailey-shale-native-diagnostic.LRfuQ8/node-fit/result.log`、`boundary.log`；构建日志 `/tmp/bailey-shale-svg-node-build-20261125.log` 与 `/tmp/bailey-shale-svg-node-host-build-20261125.log`。阶段仍 No-Go。

- 2026-11-25 `2f8482e0`：跨格式实际净化诊断及外链剔除回归与 SVG pattern 专项 2/2，零失败零跳过；见 [HTML P1](../html-live-preview/audit-p1.md)。不替代物理缩放验收。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；共享 P1 审计（同一历史记录） 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 2026-11-26：最终版 d542f533 的 VoiceOver 已实测 100%、125%（前轮）及 80%、Fit（本轮）各动作与播报，重新定位读出当前值；原 SVG 字节一致。共享图形旁白条件核销，其他阶段门禁独立保留。
  证据 `/tmp/bailey-final-vo-exclusive.sOoDThsY/vo.log`。
