# P1｜复用现有 AVFoundation，原文件标签播放音频

本机音频双击后直接在同一个 `FileTab` 播放、暂停、定位和调节速度／音量。
不增加音乐库、后台播放器服务或第二套媒体渲染框架。

## 当前代码与技术边界

- Markdown 内嵌 `<audio controls>`／`<video controls>` 已经使用
  `MarkdownMedia.stage → MarkdownMedia.asset → AVPlayer → MarkdownNativePlayer`
  和系统 `AVPlayerView`。其中 `asset(at:)` 设置外部引用禁止策略；
  `MarkdownNativePlayer` 是仅限 Markdown 文件的私有 AppKit 适配。
  **独立音／视频首个落地任务**应共用受控 AVAsset 验证。
  只有独立视频需要第二处 `AVPlayerView` 时，再把 Markdown 的私有适配改成中性组件，
  替换所有调用并删除旧类；独立音频可直接以紧凑控件操作同一 AVPlayer，
  不强加视频控件，也不实现第二套 asset loader／PlayerRepresentable。
- Markdown 嵌入资源须通过 `MarkdownResource` 授权并在**用户点击后**
  将最多 64 MiB 的资源暂存到受控临时目录，播放器由内嵌 View 暂时持有，卸载清理。
  **独立本机媒体不用这条暂存路径**：经当前 `FileTab` 真实本机身份／文件检查后，
  `AVURLAsset` 直接读取原始 `file://`；播放不经过 `WorkspaceBackend.read(maxBytes:)`
  整文件读入。SSH 媒体没有随机读取协议，本阶段明确不支持，
  不能把 SSH 路径转成同名 Mac 文件。
- `FileTab.Content` 目前没有 `.media`。媒体真正接入时在
  `FileTab.readContent` 的文本 32 MiB 读取**之前**按扩展名筛选候选，
  再经本机文件身份／真实 AV 轨道和可播放性异步确认，
  只增加必要的媒体结果和 loading／error 表示；
  同步处理 `matches / reloadFromDiskIfClean / loadIfNeeded`、重新打开、
  `TabContentThumbnail`、关闭与过期结果，不能简单在 `FileViewerView` 根据后缀
  直接构造 `AVPlayer` 绕过原读入状态。
- `AVPlayer` 生命周期属于文件标签，跨 Dock 重挂载保留同一实例；
  Markdown 的内嵌播放器仍归内嵌内容所有，两者**共享 AVFoundation 核心，
  不强行共享互不相同的文件标签／嵌入生命周期**。
  仅真正可用的播放器控件接管 Space；不以全局事件监听抢终端焦点。
- 音频最常用的进度、倍速、播放／暂停、音量／静音放在内容区一行；
  不复制视频原生画面控件完整工具栏，也不提供未实现的全轨波形。
  P2 波形未准备好时，P1 普通 Slider 就能正常播放和定位。

## 任务

<a id="p1-t1"></a>
### P1-T1 共用音视频实际文件校验与正确读取分支

- **位置**：`FileTab.readContent / loadedContent / matches / reloadFromDiskIfClean`、
  `MarkdownMedia`／原生 `AVPlayerView` 适配、`TabSwitcherView` 及宿主测试。
- **实施**：同步 [文件路由 P1-T1](../file-viewer-routing/plan-p1.md#p1-t1)，
  真实本机音频先验证有权限且属于当前标签的普通文件，再用
  `AVURLAsset.load(.isPlayable)` 和实际音轨判断，异步展示时长与错误，
  不仅用扩展名断定编码可播放；资源引用、取消和回调绑定
  文件所属本机／机器、目标版本、文件路径和请求代次。
  归并 `MarkdownMedia` 的共用 AV helper 时替换原调用并删除旧重复代码；
  若音频没有第二处使用 `AVPlayerView`，本任务不为“通用化”迁移它。
  不重写现有文本／图片解码分支。
- **验证**：MP3／M4A／WAV／AIFF／CAF、系统不支持 codec、
  有合法扩展名的伪二进制、零字节、超长录音、只读／损坏／改名／删除、
  无权限与符号链接、非 ASCII 名字、快速切换／关闭时旧异步结果，
  本机／SSH 同名文件必须证实绝不串读；检查实际源字节没有被修改。

<a id="p1-t2"></a>
### P1-T2 文件标签所有的 AVPlayer 和可用的紧凑控件

- **位置**：新音频内容视图、`FileTab` 的播放器持有／释放、
  `PaneContent` 文件生命周期、`docs/features/editor.md`。
- **实施**：播放／暂停、连续 seek、0.5×～2×、静音与音量为直接可点击控件；
  速度与音量不塞进右键。修改暂停态的倍速只改期望 rate，不能触发播放。
  Dock 隐藏或切标签默认暂停且不后台发声；重挂载复用同一 player，
  关闭／换文件后取消加载、清空 item 和观察者，停止实际播放。
  Space 只在本播放器真的聚焦时起效，辅助功能要可操作。
- **验证**：真实播放设备能听到的音频、seek 边界／快进／调速／静音、
  暂停修改速度、系统设备切换、多窗口／多音频标签、Dock 关闭再开，
  空／损坏／可变码率／多声道与设备睡眠，检查是否存在幽灵有声 player 和资源泄漏。

## 阶段验收

先运行现有 `MarkdownResourceScopeTests`、`FileTabPersistenceTests`、
`NativePaneRetentionIntegrationTests` 与新增 AVAsset／生命周期宿主测试；
确认 Markdown 内嵌音视频可加载且暂存文件会删除、独立文件直接用本机 URL。
执行 `make build`、受影响 `make test:...` 和阶段 `make test`，
隔离 Bailey Dev 验证实际播放、键盘、焦点、失活暂停、错误和多个标签，
按照 `docs/testing.md` 覆盖格式、权限、系统设备、并发、容量与恢复组合。
