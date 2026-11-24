# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：P1-T2 已完成；P1-T1 的实体输入／屏幕及完整 App 验收仍未满足，不进入 P2。

## 任务与改动

- **P1-T1 用同一图片视口完成高精度缩放与资源按需解码**：RasterPreview、FileTab、PreviewScrollView：共用查看器、真实后端文件头识别、版本化详情请求和 JPEG／HEIC／PNG／普通 TIFF 区域像素。
- **P1-T2 在共用 ImageIO 解码链完成 GIF 及图片状态恢复**：GIFPlayback、GIFFrameSource 与 FileTab：共用有界帧解码、暂停恢复、重挂载和关闭释放。

## 发现项

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

- `dd58d4e8`：专项 13 项通过，真实 Windows SSH 无跳过；`make build` 与严格签名验证通过。
- `make test:FileTabPersistenceTests,PreviewScrollViewTests,SwiftMarkdownNativeTests,SVGArtworkTests,HTMLFilePreviewTests,RemoteCommandsTests,NativePaneRetentionIntegrationTests`：241 项执行，240 通过，1 项综合样本环境变量缺失跳过，0 失败，退出码 0；已启用真实图片与 120 秒长会话。
- 100 张真实图片开闭（34 JPEG／33 PNG／33 GIF），p95 首像素 0.258s，关闭后 RSS 稳定；720 帧索引解码及 120.8s 真实 GIF 播放（966 帧发布、68 绘制位置、CPU 7.34s）通过。此前 `e5ad40a9` 实际隔离 App 双窗口和菜单通过，`82a79a52` 真 Windows 改名、断线重连通过。
- `9a7d6835`：用固定版本 libpng／libtiff 接入共用 FileTab 版本化字节；PNG 扫描行／Adam7、普通 TIFF 条带／图块区域解码，消除几何变换引起的整图分配。24MP 三个区域与完整图像逐像素一致；独立 PNG 区域实验峰值 103→15.5 MiB。特殊不兼容 TIFF 仍走有界 ImageIO，不冒称支持所有 TIFF 布局。
- 关联宿主 251 项全通过无跳过；真实四格式各 25 次开闭（13.22s，首像素 P95 206ms），120 秒 GIF、实际 Windows SSH、80 EXIF／ICC／DPI 组合。新增 9286 次固定解码边界检查；独立 ASan／UBSan 10060 次检查通过（未开启 leak sanitizer）。Debug 签名及授权文件已核对。
- 缺少实体 1× 显示器／触控板、VoiceOver 和完整 App 多格式长会话验收；宿主结果不替代实际设备。无获授权的 Linux SSH 目标，仅验收实际 Windows SSH。以上保留为阶段 No-Go。
- `1492cf72`：80 组原生像素对照和最终 86 项相关回归全部通过，无跳过；先前跳过的真实七格式百次切换补测通过（3.495s）。正式 Debug 构建及严格签名通过。
- 已同步 `docs/features/editor.md`；任务状态及证据见 `todo.toml`。
- 最终 e4267d71：FileTabPersistence 73 项、真实 JPEG 32/256 MiB 两侧的精确容量边界单独补测全部通过。共享最终回归详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
