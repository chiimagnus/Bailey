# P1｜一套原生图片查看器同时服务文件与 Markdown

交付真实像素、指针锚定缩放、平移及有界 GIF 播放。
**不得再新增一个仅用于独立文件的图片查看器。**

## 当前代码与方案

- `FileTab.readContent` 在后台通过 `RasterPreview` 取得原始像素尺寸和最长边为 4096px 的缩略图，
  并记录实际读取字节的 `WorkspaceFileVersion`。标签切换器只用这份缩略图。
- `PreviewResource.picture → MarkdownPicture.decode` 使用同一 ImageIO 解码；
  `RasterPreview.gifFrame` 提供按索引解码和时长校验，局部帧与处置方式由 ImageIO 合成，
  不另写 GIF 合成器。内嵌 GIF 仍最多缓存 32 帧、800 万帧像素，超过预算只显示静态图。
- 独立 GIF 由图片标签保留播放位置，视口显示时走 `FileTab` 的同版本后端读取，
  `GIFFrameSource` 按需解码，`GIFPlayback` 与 Markdown 共用时钟，只预取下一帧。
  两处共用缺失图像数据块检查，保留可读首帧；不另做帧解码或像素合成。
- `ImageInspector → PreviewScrollView` 已替换旧 SwiftUI 缩放手势和底栏。
  文件图片、独立 SVG、内嵌 SVG 及 Mermaid 共用原生视口；Markdown 插图打开实际图片标签。
  文件图片的倍率和中心点归现有标签，重挂载后按新视口边界恢复；换帧不改查看位置。
- 当前放大时通过 `FileTab` 的后端同版本重读。
  符合条件的 8 位 RGB JPEG／HEIC 交给 Core Graphics，
  在后台只生成视口及附近的原像素缓冲，平移时继续复用这一版原数据。
  PNG、普通 TIFF 等仍使用同一 ImageIO 链的整图详情；
  这些格式的原生裁剪可能分配整图缓冲，不能以输出尺寸替代对解码峰值的验证。
  缩回缩略图足够的倍率时取消读取并释放详情像素；
  改名从新路径重新取详情，不改变原缩放和查看位置。
  文件级 32MP 像素及 256MiB 原字节边界不变；超过 3200 万像素的文件继续明确拒绝，
  不能在预算尚未升级前声称能查看它。原文件若高于 4096px，
  100% 必须按真实原图和屏幕 `backingScaleFactor` 显示，不能扩大旧缩略图。
  本机允许按需裁剪／分块解码；SSH 若无随机读能力须基于受控有界数据或临时文件实现，
  严格绑定机器／文件版本并释放，不能使用同名 Mac 文件或无限缓存。
- ImageIO 会容忍截断的 JPEG 或 PNG。共用入口核对 JPEG 主图的结束标记，
  不把元数据中的缩略图当成主图，也不拒绝完整主图后的合法尾随数据；
  PNG 在进入原生解码前检查实际块边界、CRC 和 IEND。
- 不在每次 SwiftUI 重算中同步读取／解码大图、计算整个 Data 的哈希或重建滚动视图。
  测量后台读入与前台提交的独立成本，按标签身份和加载代次接收结果。
  不可让过期图覆盖脏稿或新文件。
  Markdown 内嵌图片仍只负责布局尺寸、alt、来源定位和授权，不能持有第二套查看手势。

## 任务

<a id="p1-t1"></a>
### P1-T1 用同一图片视口完成高精度缩放与资源按需解码

- **位置**：`ImageInspector`、`PreviewScrollView`、`RasterPreview`、`MarkdownNativeImage`、
  `PreviewResource`、`FileTab.readContent / originalImageRequest` 及相关宿主测试。
- **实施**：替换现有查看实现，不增加 `ImageViewerView` 平行路径；
  触控板双指平移／捏合、鼠标滚轮与 Shift 横移、⌘＋滚轮光标锚点、
  拖拽平移及双击 fit／原像素。手动倍率为 10%～400%，fit 可低于下限以完整显示极端长宽比；
  窗口与屏幕倍率变化不跳顶／重新居中。
  控件尽量使用原生系统手势，缩放入口放右键／辅助功能动作，不保留永久底部工具栏。
  在当前可见区域按实际像素／Exif／ICC 绘制原图；后台解码与输入版本保护共用已有 ImageIO 路径。
  真实像素读取与标注的底图版本必须从**同一 FileTab 读取与代次**接入，
  不能自行打开另一个不受控文件句柄或将哈希值冒充文件版本。
  Markdown 内嵌放大在同一任务接到新表面，立即删去旧 Inspector 缩放状态和废弃手势代码。
- **验证**：真实触控板双指惯性／捏合、鼠标与⌘／Shift 滚轮、不同锚点与反复缩放、
  10%／100%／400%、Fit、横竖大图、透明、Exif 旋转、ICC、Retina 与不同屏幕倍率，
  多 Dock／窗口与切焦点、真实像素截图、图块边界、文件改写及乱序解码；
  本机和获授权 SSH 的原始图片身份及大小预算必须得到实际验证。
  对比旧 Markdown 插图的尺寸、点击、alt、动画和放大交互，不得退化。

<a id="p1-t2"></a>
### P1-T2 在共用 ImageIO 解码链完成 GIF 及图片状态恢复

- **位置**：`MarkdownPicture.decode`、`GIFPlayback`、`GIFFrameSource`、
  图片查看表面和 `FileTab` 生命周期。
- **实施**：在相同 ImageIO 帧索引上有界缓存当前与邻近帧、正确处理帧时长，
  同时正确处理 GIF 局部帧、透明混合、disposal／restore，而不是把每一帧当整图独立呈现。
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

### 图片查看专项验收矩阵（P1）

同时运行[共用 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)所有适用项；
当前 `SwiftMarkdownNativeTests.testStaticPNGJPEGHEICAndWebPUseNativeImageIODecoding`、
`testGIFFramesHonorTimingAndAnimationBudget` 和 `FileTabPersistenceTests` 的大图限额测试
只证明基础解码／缩略图，不证明完整 GIF 合成、原像素或指针锚定缩放。

| 编号 | 可执行夹具／动作 | 通过条件 |
| --- | --- | --- |
| I01 格式 | PNG／JPEG／GIF／HEIC／WebP／TIFF／BMP／ICNS；源格式与扩展名匹配、错配、伪造二进制、有效图片改名为 `.txt`。 | 实际 ImageIO 识别决定是否能看，不靠后缀执行其它内容；错误显示与原字节不变，旧 Markdown 图片照常可读。 |
| I02 尺寸／容量 | 1×1、4095／4096／4097px、极宽／极高、`32,000,000±1` 像素、`32 MiB` 分流点、`256 MiB±1` 字节、数据尾部截断。 | 符合上限才能看；边界外明确拒绝。大于 4096px 且不超 32MP 的真图片在 100% 时不放大缩略图；读／解码内存有界，不能因格式伪装绕过限制。 |
| I03 显示像素 | 8 位／16 位、灰度／索引色、ICC／Display P3、CMYK 转换、透明通道、Exif 旋转 1／3／6／8 与镜像取向、带 DPI 的图片。 | 100% 对照原始像素、朝向、alpha 和色彩参考，导出截图不把点数当像素数；不同显示器 1×／2× 结果一致。 |
| I04 视口／手势 | fit、10／100／400%、图中心／四角缩放、鼠标普通／Shift／⌘ 滚轮、触控板水平／垂直惯性／捏合、拖拽、双击、窗口大小与 backingScale 改变。 | 锚点下原图坐标保持不动（除合法边界夹紧）；不突然回零、居中或跳屏；可访问动作和原生手势一致。 |
| I05 GIF 语义 | 1／2／32／33／数百帧；`8,000,000±1` 帧像素、帧时长极短／为零／很长、局部矩形、透明叠加、restore-to-background／restore-to-previous、损坏中间帧。 | 文件查看正确合成且有界播放，停止／恢复时间轴准确；Markdown 内嵌仍遵守已有 32 帧预算并明确退化，不用独立文件的无界帧缓存替换它。 |
| I06 读写与时序 | 两个同名跨机器图片、远端文件断开／重连、外部同长替换、慢图片解码时切标签／关闭／改路径、首图尚未加载时打开第二图。 | 只显示当前机器／版本的图片；被取消解码不会晚到覆盖新图，关闭后不留未释放的 CGImageSource、预览缓冲或后台文件句柄。 |
| I07 交互复用 | 普通文件图片、Markdown 插图弹窗、Mermaid／SVG 图像放大；深浅主题、暗色背景／透明棋盘、多 Dock、VoiceOver、快捷键和右键。 | 共用同一缩放／平移实现，但各自保持原有点击、链接、alt、放大及退出语义；不形成第二套工具栏或事件处理。 |
| I08 长会话 | 依次打开 10／100 张大图，来回缩放、换主题、失活／激活、释放 GIF／PNG 后重新进入同一标签。 | 记录 RSS／CPU／首帧／解码峰值、真正关闭后的缓存与引用保留，不能因为窗口暂时卸载就错删 FileTab 的现行数据。 |

必须交叉 I02×I04、I03×I04、I05×I06、I06×I08、I07×I04 及 R03×I06。
I05 的 800 万像素门限不变。ImageIO 合成帧使用同一画布，
在内嵌帧最长边 1024、最多 32 帧的条件下，无法构造恰好 ±1 的有效输出；
验收采用最接近的可达两侧（7,999,992、8,000,010）及精确 8,000,000。
真实触控板与 ICC 对照在宿主像素测试之外另做隔离 Bailey Dev GUI；
对目前无法提供的屏幕、远端或物理输入设备，逐项写出缺口与影响，不以鼠标模拟捏合作为实测。
