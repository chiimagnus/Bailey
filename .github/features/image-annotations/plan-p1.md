# P1｜一套原生图片查看器同时服务文件与 Markdown

交付真实像素、指针锚定缩放、平移及有界 GIF 播放。
**不得再新增一个仅用于独立文件的图片查看器。**

## 当前代码与方案

- `FileTab.readContent / loadedContent` 经 ImageIO 校验源数据与首帧，
  `.image(NSImage)` **仅保存最长边 4096px 的缩略图**。
  现有 `FileViewerView` 已使用 `MarkdownImageInspector`，不是旧的静态 `ScrollView + Image`。
- `MarkdownResource.picture → MarkdownPicture.decode` 的内嵌图片使用同一
  `FileTab.imageThumbnail`；内嵌 GIF 当前最多缓存 32 帧、800 万帧像素，超过预算只显示静态图。
  `MarkdownNativeImage` 弹出的放大窗口也使用 `MarkdownImageInspector`。
- `MarkdownImageInspector` 目前是 SwiftUI `ScrollView + MagnifyGesture`、固定倍率和底部缩放栏。
  它没有围绕光标／捏合中心维持锚点，也把缩略图 100% 当作原始像素。
  **直接替换这一个共用查看表面**：以系统 `NSScrollView` 处理惯性、
  `setMagnification(_:centeredAt:)` 处理锚定缩放，显示、查看和 Markdown 放大共用它。
  不为图片、SVG 和嵌入式富内容各实现一个手势坐标系统。
- 图片缩略图、元信息和有界原像素按需解码仍使用 ImageIO；
  将 `FileTab.imageThumbnail`／`MarkdownPicture.decode` 需要的公共解码逻辑收敛到同一处，
  支持文件预览和 Markdown 独立的尺寸／帧数预算，不复制解析器或缓冲。
  文件级 32MP 像素及 256MiB 原字节边界不变；原文件若高于 4096px，
  100% 必须按真实原图和屏幕 `backingScaleFactor` 显示，不能扩大旧缩略图。
  本机允许按需裁剪／分块解码；SSH 若无随机读能力须基于受控有界数据或临时文件实现，
  严格绑定机器／文件版本并释放，不能使用同名 Mac 文件或无限缓存。
- 不在每次 SwiftUI 重算中同步读取／解码大图、计算整个 Data 的哈希或重建滚动视图。
  实测 `loadedContent` 在当前主 actor 提交前的解码／指纹成本，耗时操作移出主 actor，
  按标签身份和加载代次接收结果。不可让过期图覆盖脏稿或新文件。
  Markdown 内嵌图片仍只负责布局尺寸、alt、来源定位和授权，不能持有第二套查看手势。

## 任务

<a id="p1-t1"></a>
### P1-T1 用同一图片视口完成高精度缩放与资源按需解码

- **位置**：`MarkdownImageInspector`、`MarkdownNativeImage`、`MarkdownResource`、
  `FileViewerView` 的 `.image`、`FileTab.imageThumbnail / loadedContent`，及相关宿主测试。
- **实施**：替换现有查看实现，不增加 `ImageViewerView` 平行路径；
  触控板双指平移／捏合、鼠标滚轮与 Shift 横移、⌘＋滚轮光标锚点、
  拖拽平移及双击 fit／原像素，倍率为 10%～400%，窗口与屏幕倍率变化不跳顶／重新居中。
  控件尽量使用原生系统手势，缩放入口放右键／辅助功能动作，不保留永久底部工具栏。
  在当前可见区域按实际像素／Exif／ICC 绘制原图；后台解码与输入版本保护共用已有 ImageIO 路径。
  Markdown 内嵌放大在同一任务接到新表面，立即删去旧 Inspector 缩放状态和废弃手势代码。
- **验证**：真实触控板双指惯性／捏合、鼠标与⌘／Shift 滚轮、不同锚点与反复缩放、
  10%／100%／400%、Fit、横竖大图、透明、Exif 旋转、ICC、Retina 与不同屏幕倍率，
  多 Dock／窗口与切焦点、真实像素截图、图块边界、文件改写及乱序解码；
  本机和获授权 SSH 的原始图片身份及大小预算必须得到实际验证。
  对比旧 Markdown 插图的尺寸、点击、alt、动画和放大交互，不得退化。

<a id="p1-t2"></a>
### P1-T2 在共用 ImageIO 解码链完成 GIF 及图片状态恢复

- **位置**：`MarkdownPicture.decode / image(at:)`、图片查看表面、`FileTab` 生命周期。
- **实施**：在相同 ImageIO 帧索引上有界缓存当前与邻近帧、正确处理帧时长，
  长动画不能因为现有内嵌 32 帧预算就伪装成“完整播放”。
  文件查看支持暂停／继续；Markdown 内嵌仍遵守非活动暂停与资源预算。
  替换旧计时与解码路径时同任务删除，关闭和换目标立即取消、释放。
- **验证**：单帧／多帧／超过 32 帧、损坏帧、超长时间、不同延时、
  窗口失活、Dock 重挂载、快速切换、关闭后残留任务及长时内存曲线；
  只读操作前后源文件字节和目录完全不变。

## 阶段验收

运行 `make test:SwiftMarkdownNativeTests,MarkdownResourceScopeTests,FileTabPersistenceTests,NativePaneRetentionIntegrationTests`
及新增的 ImageIO／原生 `NSScrollView` 宿主测试，再执行 `make build` 与阶段完整宿主测试。
隔离 Bailey Dev 验证真实 Mac 手势、前后像素、Retina 和 Markdown 插图放大；
按 `docs/testing.md` 扩展权限、容量、并发、恢复和极端组合，未测的实际设备条件逐项披露。
不把“4096px 缩略图可放大”算作原像素质量通过。
