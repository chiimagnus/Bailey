# P1｜原生图片查看闭环

在原有 FileTab 中正确预览与缩放图像，无需编辑也无需产生辅助文件。

## 技术决定

**不新增图片 SPM。** Bailey 当前已使用 ImageIO；继续以系统 **ImageIO / Core Graphics / AppKit** 完成 PNG/JPEG/HEIC/WebP/TIFF/BMP/ICNS/GIF 解码、Exif 方向、ICC 颜色及多帧信息。
查看区域使用 `NSScrollView` 原生滚动／惯性和放大倍率（`setMagnification(_:centeredAt:)`），底图由 `CGImage` 或按需解码图块提供；**100% 必须按原图像素与 Retina backing scale 定义**。
不引入 Kingfisher（主要解决网络图像下载／缓存）、SDWebImage、第三方 Zoomable ScrollView，也不为静态图加载 `WKWebView`。
GIF 多帧只通过 ImageIO 增量索引/缓存播放，限制当前帧和内存预算；本机隔离 UI 才能证明触控板实际惯性，HTML 原型的 wheel 仿真不等于产品验收。

## 方案

现有 `FileTab.loadedContent` 以 ImageIO 限制 256 MiB 源数据、3200 万像素及 4096px 缩略图；`FileViewerView` 只使用固定 ScrollView/Image。
当前缩略图生成和 `Data.hashValue` 从继承 MainActor 的重载任务同步调用，存在大图阻塞 UI 的风险；
本阶段须测量并将实际耗时解码／哈希移出主 actor，再按原文件身份与代次提交结果，不另建图片加载器。
在这条已有 ImageIO viewer 上增加适合窗口、锚点缩放及视口管理；超过 4096px 缩略图的原图，在真实 100% 放大区域按需解码，不将完整超大图重复保存在内存 NSImage。
图片数据、请求版本及关闭释放沿用 `FileTab`。不为所有图片改写存储格式。

## 任务

<a id="p1-t1"></a>
### P1-T1 可靠缩放／透明背景／真实像素

- **位置**：`FileTab.loadedContent`、`FileViewerView`、新增轻量图片查看视图。
- **实施**：以原生 `NSScrollView` 处理触控板双指平移（含惯性）和鼠标自然滚轮／Shift 横移，AppKit magnification 处理捏合；调用 `setMagnification(_:centeredAt:)` 或等价原生动作做指针／手势中心锚点缩放。
  ⌘＋滚轮不注册应用快捷键；双击 fit／100%、查看态拖拽平移、10%～400% 缩放不重新居中。
  根据实际 `backingScaleFactor` 和 Exif 取向做图块解码及绘制，保证 100% 是原像素，不让 4096px 缩略图误充原图。
  首帧的 ImageIO 缩略图与大数据指纹计算按实测结果离开 MainActor；取消、改名或编辑后丢弃过期结果，同时保留全部现有读取尺寸与格式头检查。
- **验证**：真实 Mac 触控板捏合／双指惯性、鼠标普通及⌘／Shift 滚轮、指针中心锚点位置、拖拽及双击、10%～400%、横竖／超宽／透明／多屏 Retina、窗口尺寸改变、文件切换释放；放大后不跳回中心，非活动 Dock 不捕捉手势。
  补充大图冷加载／刷新、快速切文件、主线程帧延迟与峰值内存测量；核对过期任务确实取消且不会覆盖后来加载的图片。

<a id="p1-t2"></a>
### P1-T2 GIF 与图片入口一致性

- **位置**：ImageIO 的帧信息、文件标签控制条、`docs/features/editor.md`。
- **实施**：使用 ImageIO 帧延时与增量读取维护有界 GIF 播放／暂停；仅绘制当前帧附近缓存，切换标签自动暂停且可恢复，不预解码所有帧或改变源字节。
- **验证**：单帧／多帧／损坏帧／长动画、切换 Dock 与多窗口，播放暂停内存增长有限；低帧频文档不被强行重采样。

## 阶段验收

`make build:ui`、宿主 ImageIO 解码测试和隔离 Bailey Dev 图像查看操作。
只读操作必须证明未生成 sidecar；不可将小缩略图拉伸作为原图 100% 验收。
