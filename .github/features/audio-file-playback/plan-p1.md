# P1｜复用现有 AVFoundation，原文件标签播放音频

本机音频双击后直接在同一个 `FileTab` 播放、暂停、定位和调节音量。
不增加音乐库、后台播放器服务或第二套媒体渲染框架。

## 当前代码与技术边界

- Markdown 内嵌 `<audio controls>`／`<video controls>` 已经使用
  `MarkdownMedia.stage → NativeMedia.open → AVPlayer → NativePlayerView`。
  独立音视频实际共用 `NativeMedia` 的普通文件、外部引用与轨道校验，
  与 Markdown 内嵌共用 `NativePlayerView`（`AVPlayerView`）；独立音频使用紧凑系统播放器，不另建控制条。
- Markdown 嵌入资源须通过 `PreviewResource` 授权并在**用户点击后**
  将最多 64 MiB 的资源暂存到受控临时目录，播放器由内嵌 View 暂时持有，卸载清理。
  **独立本机媒体不用这条暂存路径**：经当前 `FileTab` 真实本机身份／文件检查后，
  `AVURLAsset` 直接读取原始 `file://`；播放不经过 `WorkspaceBackend.read(maxBytes:)`
  整文件读入。SSH 媒体没有随机读取协议，本阶段明确不支持，
  不能把 SSH 路径转成同名 Mac 文件。
- `FileTab.Content.media` 在 `FileTab.readContent` 的文本 32 MiB 读取**之前**按扩展名筛选候选，
  再经本机文件身份／真实 AV 轨道和可播放性异步确认，
  让音视频共享一个经 AVFoundation 确认类型的文件媒体结果（如 `.media`），
  不在同一 `Content` 中分别增设 `.audio`／`.video` 两套读取、错误或生命周期；
  同步处理 `matches / reloadFromDiskIfClean / loadIfNeeded`、重新打开、
  `TabContentThumbnail`、关闭与过期结果，不能简单在 `FileViewerView` 根据后缀
  直接构造 `AVPlayer` 绕过原读入状态。
- `AVPlayer` 生命周期属于文件标签，跨 Dock 重挂载保留同一实例；
  Markdown 的内嵌播放器仍归内嵌内容所有，两者**共享 AVFoundation 核心，
  不强行共享互不相同的文件标签／嵌入生命周期**。
  仅真正可用的播放器控件接管 Space；不以全局事件监听抢终端焦点。
- 独立音频仅提供播放／暂停、进度、音量／静音。窄窗保持 520 点的同一原生 AVKit 内容宽度，使用系统横向滚动访问控件；不因压缩而隐藏必要操作。

## 任务

<a id="p1-t1"></a>
### P1-T1 共用音视频实际文件校验与正确读取分支

- **位置**：`FileTab.readContent / matches / reloadFromDiskIfClean`、
  `NativeMedia`／既有 Markdown 暂存、`TabSwitcherView` 及宿主测试。
- **实施**：同步 [文件路由 P1-T1](../file-viewer-routing/plan-p1.md#p1-t1)，
  真实本机音频先验证有权限且属于当前标签的普通文件，再用
  `AVURLAsset.load(.isPlayable)` 和实际音轨判断，异步展示时长与错误，
  不仅用扩展名断定编码可播放；资源引用、取消和回调绑定
  文件所属本机／机器、可验证的文件身份／元数据、路径和请求代次。
  大媒体不能为了凑 `WorkspaceFileVersion` 每次打开都做整文件 SHA-256；
  先检查真实本机文件的稳定身份／合法更新通知并在加载完成后复核，
  遇到外部替换必须停止旧来源并重试或报错，不能用仅凭文件后缀的断言替代。
  归并 `MarkdownMedia` 的共用 AV helper 时替换原调用并删除旧重复代码；
  不重写现有文本／图片解码分支。
- **验证**：MP3／M4A／WAV／AIFF／CAF、系统不支持 codec、
  有合法扩展名的伪二进制、零字节、超长录音、只读／损坏／改名／删除、
  无权限与符号链接、非 ASCII 名字、快速切换／关闭时旧异步结果，
  本机／SSH 同名文件必须证实绝不串读；检查实际源字节没有被修改。

<a id="p1-t2"></a>
### P1-T2 文件标签所有的 AVPlayer 和可用的紧凑控件

- **位置**：`FileViewerView`、`NativePlayerView`、`FileTab` 的播放器持有／释放、
  `PaneContent` 文件生命周期、`docs/features/editor.md`。
- **实施**：直接使用 AVKit 的系统播放／暂停、连续 seek、静音与音量；不自行组合按钮与滑块。
  Dock 隐藏或切标签默认暂停且不后台发声；重挂载复用同一 player，
  真实 `Project.remove/terminateAll`／FileTab 退役时取消加载、清空 item 和观察者、停止实际播放；
  不能仅依靠 SwiftUI `onDisappear` 当作最终关闭信号。
  Space 只在本播放器真的聚焦时起效，辅助功能要可操作。
- **验证**：真实播放设备能听到的音频、seek 边界／快进／静音、
  系统设备切换、多窗口／多音频标签、Dock 关闭再开，
  空／损坏／可变码率／多声道与设备睡眠，检查是否存在幽灵有声 player 和资源泄漏。

## 阶段验收

本轮远端连接、现有设备及缺配设备延期规则统一遵循[共用验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；
任务独立核销与阶段共同验证按[验收归属](../file-viewer-routing/plan-p1.md#acceptance-ownership)，不复制公共测试。

先运行现有 `MarkdownResourceScopeTests`、`FileTabPersistenceTests`、
`NativePaneRetentionIntegrationTests` 与新增 AVAsset／生命周期宿主测试；
确认 Markdown 内嵌音视频可加载且暂存文件会删除、独立文件直接用本机 URL。
执行 `make build`、受影响 `make test:...` 和阶段 `make test`，
隔离 Bailey Dev 验证实际播放、键盘、焦点、失活暂停、错误和多个标签，
按照 `docs/testing.md` 覆盖格式、权限、系统设备、并发、容量与恢复组合。

### 音频文件专项验收矩阵（P1）

共用文件身份、路径、授权、窗口及竞态要求见
[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)；
`SwiftMarkdownNativeTests.testMediaStageUsesAuthorizedBytesAndRejectsUnboundedFiles`
仅证明 Markdown 内嵌媒体的受限暂存，不能替代独立大音频直接播放验证。

| 编号 | 可执行媒体夹具／用户操作 | 真实判据 |
| --- | --- | --- |
| A01 类型与轨道 | MP3／M4A／AAC／WAV／AIFF／CAF／FLAC、PCM 16／24／32-bit、单声道／立体声、VBR、有声／静音、零字节、损坏头、无音轨、只有视频轨、DRM／不支持 codec。 | 由 AVAsset 实际 playable＋audio tracks 判定，拒绝无法正常解码的候选；不把二进制重新当 TextKit 源码读取，不伪显示时长／可播。 |
| A02 大文件 | 极短音频／1 秒／多小时、超过 `32/64/256 MiB` 的真实可播文件、慢磁盘、尚未索引完整时长与可变码率。 | 本机从实际 `file://` 流式播放，内存不随源文件长度线性增长。 |
| A03 来源安全 | Finder 明确选择项目外本机文件、SSH 同名路径、本机有效／悬空／越界 symlink、权限变化、非普通文件、修改中打开、外部引用型容器。 | 不播放错误主机/无效来源，AVAsset 只读取本次明确打开文件及平台允许的资源；`forbidAll` 的引用限制需在实际容器上验证而不只看配置。 |
| A04 播放控制 | 播放／暂停、0s／时长附近／结束后 seek、连续拖拽与快速反向 seek、音量 0／100%、静音及取消静音。 | 观察真正的 `AVPlayer.currentTime/rate/isMuted` 和声音输出；最后一次 seek 占优，不从旧完成回调回跳。 |
| A05 焦点与显示 | Space 在播放器／源编辑器／终端／查找栏的真实第一响应者上使用，系统菜单、暗亮、中文 VoiceOver、窄宽 Dock、窗口和多显示器。 | 仅已聚焦播放器处理本地按键；不抢终端输入、不创建第二个标题栏、可用 AX 操作选择。 |
| A06 生命周期 | 两个音频标签、同窗混合音视频及 Markdown 内嵌播放器、切项目／Dock 隐藏、重挂载、关闭项目／窗口、音频系统睡眠／唤醒、设备更换。 | 离开当前文件默认暂停且不继续有声；真正关闭清理唯一 FileTab player/item/观察者，重挂载沿用有效实例而不重复解码。 |
| A07 Markdown 回归 | 合法相对 `.wav/.mp4`、未授权／`../`、私有临时文件、`64 MiB-1/64 MiB/64 MiB+1`、加载中立刻关页面及重复打开。 | 内嵌仍按点击才暂存和 64 MiB 限制，临时文件在成功、失败、取消后正确清理；独立音频不再复制这份磁盘暂存。 |
| A08 长会话 | 10／100 次打开与关闭、多次换音频设备、停止和恢复、错误后重试、播放中切走并重新进入。 | 记录 MainActor 延迟、播放器数量、读盘量、RSS/CPU 与实际声音，关闭后没有幽灵音轨或残余 AV 观察者。 |

必须交叉 A01×A02、A02×A03、A03×A06、A04×A06、A05×A06、A07×A06、R03×A03。
宿主能证明资源和时间状态；真实有声输出、系统设备与焦点路径须在隔离 Bailey Dev 验证，
当前第二个音频输出设备及其切换组合按[共用验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)延期，
内置扬声器及系统可执行的生命周期仍须验收。缺少 DRM 合法样本时注明未测，不寻求绕过。
