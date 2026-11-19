# P1｜在现有 FileTab 中播放视频

交付视频文件默认渲染与系统播放器控制，不改变 Dock 或 Finder 的文件入口。

## 技术决定

**不新增视频播放器 SPM。** 在 macOS 15.6+ 直接使用 Apple **AVKit 的 AppKit `AVPlayerView`** 与 **AVFoundation 的 `AVPlayer`、`AVPlayerItem`、`AVURLAsset`**。优先使用 AVPlayerView 画面内原生播放／暂停、seek、全屏、音量与系统媒体选项；倍速若无法直接在系统控件中选择，则只在画面内增加最小速率控件并绑定当前 AVPlayer，不复制一整套播放工具栏，也不改藏到右键。
以 `NSViewRepresentable` 嵌入唯一 FileTab 的显示内容，SwiftUI 重挂载不重新创建播放器或后台解码进程。解码格式以 macOS 当前 AVFoundation 能力为准，不捆绑 FFmpeg、VLC、视频缩略图网络下载或自研字幕引擎。
只支持有权限的本机媒体 URL；SSH 视频需要后端随机访问和缓存改造，**当前不纳入**，也不使用下载完整视频到内存的兼容路径。

## 方案

沿 `Project.openFile` → `FileTab` → `FileViewerView` 路由视频；原文本／图片内容保留。
本机媒体以文件 URL 交给 `AVPlayer` / `AVPlayerView`，不通过 `WorkspaceBackend.read(maxBytes:)` 加载全部 bytes。
播放器由唯一 FileTab 持有，Dock 只是展示；不为一次文件打开创建第二层面板或应用级播放管理器。

## 任务

<a id="p1-t1"></a>
### P1-T1 媒体路由与可信资源处理

- **位置**：`FileTab.Content`、`FileTab.readContent`、`FileViewerView`、本机文件类型测试。
- **实施**：用 `AVURLAsset` 异步查询实际轨道／时长／可播放性，交 `AVPlayerItem`，错误经当前文件标签原生提示；播放仅允许本机获授权文件 URL，远端路径不伪装成 Mac 路径；无效资源也允许关闭标签并释放 item。
- **验证**：MP4/MOV/M4V、HEVC/H264 等实际系统可解码文件、损坏容器、无音轨、符号链接、文件改名／删除、未知扩展名。

<a id="p1-t2"></a>
### P1-T2 原生视频区和聚焦控制

- **位置**：新增视频播放视图、Dock 的文件标签生命周期及 `docs/features/editor.md`。
- **实施**：视频画面内必须能直接播放、拖动进度、改变音量、选择倍速和全屏；AVPlayerView 原生能力足够时不重复绘制，缺少倍速入口时只加该最小画面内附件。暂停／指针移动显示控件，播放闲置淡出；定位于实际视频矩形而非整个 Panel 底部，窄屏仍可操作，聚焦快捷键交由 AVKit。
  一个 `FileTab` 只保留一个 `AVPlayer`；非活动标签默认暂停，关闭时拆除 currentItem、观察者并释放解码资源。
- **验证**：真实 App 中不经右键直接播放／暂停、拖动 seek、静音／音量、倍速、全屏；右键无重复项。检查暂停／播放闲置／焦点、竖屏／超宽／窄 Dock、视频画幅黑边和控制层遮挡，再覆盖实际音频输出、窗口切换、关闭与双文件状态。

## 阶段验收

`make build:ui`、受影响宿主测试和隔离 Bailey Dev，检查真实解码而不是“呈现一个视频框”。
