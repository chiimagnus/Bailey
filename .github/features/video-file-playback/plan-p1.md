# P1｜复用 Markdown 播放底座的本机视频文件标签

本机视频双击后，在同一个 `FileTab` 显示画面、播放、seek、音量、倍速和全屏。
采用 Apple AVFoundation＋AVKit，不引入 FFmpeg／VLC、第二个浏览器或工具栏框架。

## 当前代码与共用边界

- `MarkdownMedia.asset(at:)` 已包装禁止外部引用的 `AVURLAsset`，
  `MarkdownNativePlayer` 已将 `AVPlayer` 嵌入原生 `AVPlayerView`。
  Markdown 内嵌视频通过授权的 `MarkdownResource` 限制读取、点击后最多暂存 64 MiB，
  播放器由嵌入视图临时持有，离开时释放。
- **独立本机文件**的 `AVURLAsset` 应直接绑定实际有权限的 `file://`，
  不经过 Markdown 的暂存／整文件 64 MiB 限制，更不经过 32 MiB 文本读取。
  共享的是**AVAsset 验证、引用限制、AVPlayerView 控件适配**，
  不是 Markdown 的暂存任务或内嵌 View 生命周期。
  第一种独立音视频格式先复用 AVAsset 检查；当本计划实际需要
  第二处 `AVPlayerView` 时，才将 Markdown 的 `MarkdownNativePlayer` 收敛为中性组件，
  当场替换旧调用，绝不留下两个同功能的原生视频适配。
- 当前 `FileTab.Content` 无媒体 case；按候选扩展名在 `readContent` 前分流，
  再由系统 AVAsset.load 的实际 playable／轨道验证，
  文件身份、generation、错误、刷新、保存禁用、关闭和 `TabSwitcherView`
  由现有 `FileTab` 生命周期处理，保持文本／图片原路径不变。
  SSH 媒体在没有受控随机访问时明确不支持，绝不伪装同名本机视频。
- `AVPlayer` 由文件标签持有，Dock 只显示且重挂载不重新创建解码任务。
  **优先原生 `AVPlayerView` 的视频画面内播放、拖动、音量、全屏和轨道控制**；
  Markdown 目前关闭其全屏按钮，独立视频按显示场景启用，
  只在系统控制确实缺少倍速入口时补最小控件。
  不重写一套悬浮控件状态机、遮罩、计时器或重复速度／音量工具栏。
  非活动标签默认暂停，不启用幽灵后台音频。

## 任务

<a id="p1-t1"></a>
### P1-T1 与音频共享的本机媒体检查、路由及版本保护

- **位置**：`FileTab.readContent / matches / reloadFromDiskIfClean`、
  `MarkdownMedia`／AVPlayerView 适配、`TabSwitcherView` 与宿主测试。
- **实施**：沿 [文件预览路由](../file-viewer-routing/plan-p1.md#p1-t1) 和
  [音频共同底座](../audio-file-playback/plan-p1.md#p1-t1) 接入，
  只增加实际视频读取所需的 `Content` 表示，不能重新实现媒体类型分发和 asset factory。
  本机 URL 先检查普通文件／路径，再异步确认 AV 轨道可用和真实解码能力；
  绑定文件目标、加载代次、替换和取消，损坏文件给出可返回／关闭的错误。
  `TabSwitcherView` 只需轻量占位或有界静态缩略图，不启动第二个播放器。
- **验证**：MP4／MOV／M4V、实际 H.264／HEVC、无音轨／无画面、
  系统不支持 codec、错误扩展名／损坏／零字节、极大文件、权限／符号链接、
  中文路径、同名 SSH 路径、改名删除／替换及并发重载，
  不读取完整二进制到内存或对正式文件执行写入。

<a id="p1-t2"></a>
### P1-T2 原生 AVPlayerView 画面内操控与文件生命周期

- **位置**：共用原生 `AVPlayerView` 适配、当前视频 `FileTab` 和 Dock 内容。
- **实施**：原生播放器直接提供播放／暂停、连续拖动 seek、音量、静音、全屏，
  并按系统实际能力接入画面内倍速；没有时只补最小可见选择器，
  不复制原生控件整套功能。画面等比例，在竖屏／超宽画幅的实际内容内安放操作区域，
  不能以整个 Panel 底边当作视频底边。
  暂停控件可见，活动时指针／键盘操作可恢复；
  Space／方向键仅由真聚焦的 AVPlayerView 处理，关闭或离开标签暂停，
  关闭时清空 item／观察者、取消请求并释放后台解码任务。
- **验证**：真实视频画面、音频输出、seek、倍速／暂停修改、
  字幕按钮有无状态、静音与全屏往返、Mac 不同窗口尺寸／屏幕比例／Retina、
  点击／悬停／焦点／触控板、右键不重复控件；
  两视频／音视频混合切换、Dock 重挂载、关闭和系统唤醒不漏播放器。

## 阶段验收

复用音频的文件身份与 AVAsset 宿主测试、Markdown 嵌入视频回归，
新增 AVPlayerView 与多文件生命周期测试；执行相关 `make test:...`、
`make build`、阶段 `make test` 及隔离 Bailey Dev 的真实画面／声音／菜单／全屏操作。
按 `docs/testing.md` 核销权限、环境、设备、异常、容量和跨格式组合。
