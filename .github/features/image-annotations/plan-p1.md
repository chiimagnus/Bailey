# P1｜原生图片查看闭环

在原有 FileTab 中正确预览与缩放图像，无需编辑也无需产生辅助文件。

## 方案

现有 `FileTab.loadedContent` 以 ImageIO 限制 256 MiB 源数据、3200 万像素及 4096px 缩略图；`FileViewerView` 只使用固定 ScrollView/Image。
在这个单一 viewer 上增加适合窗口、缩放和视口管理，实际 100% 放大区域按需异步解码，不默认把大图全量复制为内存 NSImage。
图片数据、请求版本及关闭释放沿用 `FileTab`。不为所有图片改写存储格式。

## 任务

<a id="p1-t1"></a>
### P1-T1 可靠缩放／透明背景／真实像素

- **位置**：`FileTab.loadedContent`、`FileViewerView`、新增轻量图片查看视图。
- **实施**：原生 `NSScrollView` 处理触控板双指平移（含惯性）和鼠标自然滚轮／Shift 横移；原生 `MagnifyGesture` 或 AppKit magnification 处理捏合。⌘＋滚轮缩放必须围绕指针锚点，双击切换 fit／100%，查看态拖拽平移；10%～400% 不因为每次重绘重新居中。区分 Retina backing scale、Exif 方向、透明度和图块按需解码，避免缩略图假放大及主线程内存峰值。
- **验证**：真实 Mac 触控板捏合／双指惯性、鼠标普通及⌘／Shift 滚轮、指针中心锚点位置、拖拽及双击、10%～400%、横竖／超宽／透明／多屏 Retina、窗口尺寸改变、文件切换释放；放大后不跳回中心，非活动 Dock 不捕捉手势。

<a id="p1-t2"></a>
### P1-T2 GIF 与图片入口一致性

- **位置**：ImageIO 的帧信息、文件标签控制条、`docs/features/editor.md`。
- **实施**：有界 GIF 动画播放／暂停，激活标签后恢复控件显示；动画不影响原文文件字节。只把动态预览适用于能按需读取的格式。
- **验证**：单帧／多帧／损坏帧／长动画、切换 Dock 与多窗口，播放暂停内存增长有限；低帧频文档不被强行重采样。

## 阶段验收

`make build:ui`、宿主 ImageIO 解码测试和隔离 Bailey Dev 图像查看操作。
只读操作必须证明未生成 sidecar；不可将小缩略图拉伸作为原图 100% 验收。
