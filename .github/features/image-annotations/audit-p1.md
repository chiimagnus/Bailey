# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：P1-T2 已完成；双窗长会话与宿主资源回收通过，P1-T1 的实际图形辅助功能名称及倍率已修复；用户确认实体触控板捏合通过，普通鼠标轮缩放已补齐；VoiceOver 实际播报仍待验，缺配 1× 显示延期。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。

## 任务与改动

- **P1-T1 用同一图片视口完成高精度缩放与资源按需解码**：RasterPreview、FileTab、PreviewScrollView：共用查看器、真实后端文件头识别、版本化详情请求和 JPEG／HEIC／PNG／普通 TIFF 区域像素。
- **P1-T2 在共用 ImageIO 解码链完成 GIF 及图片状态恢复**：GIFPlayback、GIFFrameSource 与 FileTab：共用有界帧解码、暂停恢复、重挂载和关闭释放。

## 发现项

## 发现 F-07

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:135; Bailey/Editor/SVGFilePreview.swift:224`
- 摘要：`共用视口已有原生缩放动作但实际AX树只有scroll area，无可辨认的图形类型或当前缩放值`
- 风险：`VoiceOver无法辨认当前图形表面及确认缩放反馈`
- 预期修复：`共用NSScrollView提供本地化label与实际fit/倍率value，沿现有位置状态派发必要的原生value变化`
- 验证：`PreviewScrollViewTests实际挂载/动作/重挂载及完整App外部AX树与VoiceOver`
- 解决证据：`5a4f5673：真实挂载 Red 14 条、Green 8/8（/tmp/bailey-viewport-ax-{red.M7OJCZ,green.Kd1ra9}）；完整 App SVG 高倍率真实细线、AX 名称及 Fit/100%/745% 值通过，图片名称/倍率及双向像素通过；make build 严格验签通过。实际 VoiceOver 服务未成功启动，不能冒充播报验收，留 P1-T1。`


## 发现 F-06

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/RasterFilePreviewUITests.swift:88`
- 摘要：`系统动画偏好接入后完整 App 的 GIF 测试仍假设默认一定自动播放`
- 风险：`关闭系统动画时真实产品正确遵循偏好，却会使完整 App 验收误判；也缺少系统禁止自动播放时的 GUI 最终像素和显式恢复路径核验`
- 预期修复：`完整 App 的文件 GIF 核对真实系统默认菜单并在禁用自动播放时通过原生菜单显式恢复；Markdown 内嵌按实际系统设置验证帧变化或静态首帧，不修改系统设置`
- 验证：`RasterFilePreviewUITests 与 MarkdownPreviewUITests.testAnimatedGIFChangesVisibleFramesAndSourceBytesStayUntouched，保持原像素、失活、手动控制与文件字节断言`
- 解决证据：`当前真实系统偏好下 Markdown GIF（/tmp/bailey-viewport-ui.q50NaZ，15.029 秒）与真实34帧文件GIF（/tmp/bailey-viewport-ui-recheck.8736K0，31.628 秒）均通过；两种偏好模型契约既有宿主通过。未修改系统偏好，不声称两种物理系统设置均已实际切换。`


## 发现 F-05

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:23`
- 摘要：`文件和 Markdown GIF 未遵守系统播放动画图像设置`
- 风险：`系统禁止自动播放动画时仍开始持续解码与展示，用户暂停意图不能由系统默认值正确表达`
- 预期修复：`从公开 SwiftUI 环境读取动画图像自动播放偏好，GIFPlayback 共用暂停判据；显式右键与 AX 操作仍可控制当前文件`
- 验证：`系统偏好允许／禁止、手动覆盖、重置、取消和真实 GIF 像素；两入口共用同一控制语义，完整回归与构建`
- 解决证据：`335278b1：共用 GIFPlayback 系统默认暂停及显式操作覆盖，独立和 Markdown 均接入公开 accessibilityPlayAnimatedImages。Red 偏好断言失败；Green 真帧、手动覆盖、重置取消和内嵌实际像素通过；19:13 全量中 14 个 GIF 名称相关用例均通过，含 120 秒真实播放，0 跳过；正式 Debug 构建与严格验签通过。系统实际偏好取当前值，双值由共用模型测试；不擅自切换用户系统设置。日志 /tmp/bailey-gif-system-pref-red2-20261124.log、/tmp/bailey-seven-features-full-20261124-final-1839.log、/tmp/bailey-seven-20261124-resume-debug.log。`


## 发现 F-04

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Editor/ImageInspector.swift:117`
- 摘要：`GIF 暂停和继续未向原生辅助功能暴露`
- 风险：`依赖辅助功能的用户无法从与右键菜单对应的动作控制动画`
- 预期修复：`从现有原生菜单派生辅助功能动作，不重复维护菜单状态；暂停继续沿原标签播放器`
- 验证：`PreviewScrollViewTests 真实 GIF 播放、原生 AX 动作、暂停继续与重挂载及关闭`
- 解决证据：`e3eb7d35：Red 两断言失败，Green 两项通过；真实 GIF 的 AX 暂停、继续、旧动作失效、重挂载及源字节均核验，SVG 共用四项缩放不退化；make build 及严格签名通过。`


## 发现 F-03

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/RasterPreview.swift:218`
- 摘要：`PNG 和普通 TIFF 的详情路径在区域请求时解码全图`
- 风险：`24MP 大图小区域也产生约 103/172MiB 解码峰值；高位深或多 Dock 并发将放大内存压力`
- 预期修复：`保持同一 FileTab 版本化字节、缩略图和视口；用成熟有界扫描行/图块接口获得实际区域像素，复用原生色彩/EXIF 展示`
- 验证：`24MP 真图区域内存、逐像素及多位置对照；PNG/TIFF 位深、ICC、透明、交错、条带/图块、方向与取消等组合`
- 解决证据：`9a7d6835：共用 FileTab 版本化原字节，PNG 扫描行／Adam7 区域和普通 TIFF 相交条带／图块提取，消除几何变换引起的整图解码；24MP 三位置逐像素核对；80 EXIF/ICC/DPI 组合；251 真实样本与 Windows SSH 回归零失败无跳过，新增 9286 次固定边界检查、独立 ASan/UBSan 10060 次取消／截断／变异检查。特殊不兼容 TIFF 保留有界 ImageIO 路径。`


## 发现 F-02

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/RasterPreview.swift:157`
- 摘要：`ImageIO 自动缩略图变换按印刷 DPI 改变像素宽高比`
- 风险：`横纵 DPI 不同的 PNG/TIFF 从 64×32 原像素被拉伸到 61×64，原像素读取失败，100% 查看失真`
- 预期修复：`保持原像素比例缩略，非方形 DPI 仅执行 EXIF 方位变换，并保留颜色空间及位深`
- 验证：`原生生成 8/16 位灰度、Display P3 透明、索引色 PNG/TIFF，横纵 300/144 DPI、8 种 EXIF 方位，独立原图采样、缩略尺寸和原像素颜色对照`
- 解决证据：`1492cf72：原生 80 组 PNG/TIFF 像素、位深、ICC、透明和 EXIF 对照全部通过；最终相关 86 项零失败无跳过（含真实七格式百次切换）；make build 及严格签名通过。`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/FileViewerView.swift:1085`
- 摘要：`真实栅格图片的可预览性受后缀而非内容决定`
- 风险：`同一图片改名后，热标签与冷打开/重载表现不一致；缺少后缀的大图受文本容量限制；带图片后缀的非栅格内容可能误路由`
- 预期修复：`仅依据 ImageIO 确认的栅格类型决定解码，按实际文件容量进行有界探测，复用后端普通文件读取`
- 验证：`真实文件的 PNG/JPEG/TIFF/BMP/ICNS/HEIC/GIF/WebP 后缀错配与无后缀，32 MiB 以上的真实图片，原字节和 SVG/普通文本路由；本机和获授权 SSH 回归`
- 解决证据：`dd58d4e8：真实八种格式、改名／冷开、超32MiB PNG、合法魔数文本、损坏图片、FIFO／设备／链接及真 Windows SSH，专项13项通过无跳过；make build及严格签名通过。`


## 验证与未覆盖

- 2026-11-25：真实 34 帧 GIF 用例的像素探针只采中央 280 像素。夹具蓝色方块横跨 320 点画布的 x=27…305，在 Retina 下不少帧会完全离开采样带；实际用例在已确认动画菜单正确后取样为 nil。在整幅截图中以蓝色强度区分精灵与边框，仍要求真实运动、暂停、恢复与原文件字节。同期合成双窗 GIF 暂停和原像素平移 GUI 用例均通过。Red：`/private/tmp/bailey-xc-recheck.hgaWdv/focused.log`；Green：`b17e156f`，签名后的隔离 Bailey Dev 实机 1 项通过、0 跳过（31.407 s），见同目录 `gif.log`。原文件字节未变。

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- 本轮独立／Markdown GIF 完整 UI 测试已改为验证实际系统动画偏好，禁用时核对静态首帧及显式恢复入口；新增和改动的 UI 源码 Swift 6 类型检查、实际 `make build:ui` 及 Dev 严格验签均退出 0。F-06 仍 Open，需独立 GUI 会话中的实际运行证据；不修改用户系统偏好或冒称两种设置均经完整 App 实测。
- `dd58d4e8`：专项 13 项通过，真实 Windows SSH 无跳过；`make build` 与严格签名验证通过。
- `make test:FileTabPersistenceTests,PreviewScrollViewTests,SwiftMarkdownNativeTests,SVGArtworkTests,HTMLFilePreviewTests,RemoteCommandsTests,NativePaneRetentionIntegrationTests`：241 项执行，240 通过，1 项综合样本环境变量缺失跳过，0 失败，退出码 0；已启用真实图片与 120 秒长会话。
- 100 张真实图片开闭（34 JPEG／33 PNG／33 GIF），p95 首像素 0.258s，关闭后 RSS 稳定；720 帧索引解码及 120.8s 真实 GIF 播放（966 帧发布、68 绘制位置、CPU 7.34s）通过。此前 `e5ad40a9` 实际隔离 App 双窗口和菜单通过，`82a79a52` 真 Windows 改名、断线重连通过。
- `9a7d6835`：用固定版本 libpng／libtiff 接入共用 FileTab 版本化字节；PNG 扫描行／Adam7、普通 TIFF 条带／图块区域解码，消除几何变换引起的整图分配。24MP 三个区域与完整图像逐像素一致；独立 PNG 区域实验峰值 103→15.5 MiB。特殊不兼容 TIFF 仍走有界 ImageIO，不冒称支持所有 TIFF 布局。
- 关联宿主 251 项全通过无跳过；真实四格式各 25 次开闭（13.22s，首像素 P95 206ms），120 秒 GIF、实际 Windows SSH、80 EXIF／ICC／DPI 组合。新增 9286 次固定解码边界检查；独立 ASan／UBSan 10060 次检查通过（未开启 leak sanitizer）。Debug 签名及授权文件已核对。
- 缺少实体 1× 显示器／触控板、VoiceOver 和完整 App 多格式长会话验收；宿主结果不替代实际设备。远端验收以实际 Windows SSH 为准。实际设备及完整 App 缺口保留为阶段 No-Go。
- `1492cf72`：80 组原生像素对照和最终 86 项相关回归全部通过，无跳过；先前跳过的真实七格式百次切换补测通过（3.495s）。正式 Debug 构建及严格签名通过。
- 已同步 `docs/features/editor.md`；任务状态及证据见 `todo.toml`。
- 最终 e4267d71：FileTabPersistence 73 项、真实 JPEG 32/256 MiB 两侧的精确容量边界单独补测全部通过。共享最终回归详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- d768f481：真实 GIF／SVG 原生文件视图的四个 AX 缩放动作、菜单一致性、像素倍率、中心位置及重挂载恢复、源字节均验证通过；不替代物理输入或 VoiceOver 实际语音播报。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 5a4f5673：共用原生 AX 类型／实际倍率和值通知，宿主 Red 14 条、Green 8/8；SVG 真实高倍细线和 AX 值 39.789 秒通过；Markdown GIF 15.029 秒、真实 34 帧文件 GIF 31.628 秒通过。JPEG 双向拖动及反向横滚像素断言均通过；整项 GUI 在清理时检测到系统剪贴板计数 3750→3753，写入者未定位，保留失败记录及原断言；同版独立复验 1/1 通过（24.196 秒，/tmp/bailey-raster-final.nv02PU），剪贴板、双向拖动、横滚像素及原字节断言全部满足。日志 /tmp/bailey-viewport-{ax-red.M7OJCZ,ax-green.Kd1ra9,ui.q50NaZ,ui-recheck.8736K0,build.a5ASB2}。构建、严格签名成功。macOS XCTest 不提供实际双指捏合接口；鼠标／滚轮不冒充物理触控板。尝试实际启动 VoiceOver 未成功，服务状态保持原关闭，见 /tmp/bailey-native-ime-auto.dL04QZ/vo.log。

- 2026-11-26：用户亲自验证实体触控板捏合无问题；64782817 将普通鼠标垂直滚轮纳入同一指针锚点缩放路径。合成原生 NSEvent 定点 Red 1 条／Green 4/4，图片、视口、SVG 扩大宿主 85 项中 73 通过、12 项既有环境跳过、零失败，make build 与严格验签退出 0。未声称实体鼠标或 VoiceOver 播报已亲验。
