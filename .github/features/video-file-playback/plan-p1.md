# P1｜复用 Markdown 播放底座的本机视频文件标签

本机视频双击后，在同一个 `FileTab` 显示画面、播放、seek、音量、倍速和全屏。
采用 Apple AVFoundation＋AVKit，不引入 FFmpeg／VLC、第二个浏览器或工具栏框架。

## 当前代码与共用边界

- `NativeMedia.open` 共用禁止外部引用的 `AVURLAsset` 及实际轨道检查，
  `NativePlayerView` 将文件和 Markdown 的 `AVPlayer` 嵌入同一种原生 `AVPlayerView`。
  Markdown 内嵌视频通过授权的 `PreviewResource` 限制读取、点击后最多暂存 64 MiB，
  播放器由嵌入视图临时持有，离开时释放。
- **独立本机文件**的 `AVURLAsset` 应直接绑定实际有权限的 `file://`，
  不经过 Markdown 的暂存／整文件 64 MiB 限制，更不经过 32 MiB 文本读取。
  共享的是**AVAsset 验证、引用限制、AVPlayerView 控件适配**，
  不是 Markdown 的暂存任务或内嵌 View 生命周期。
  独立视频已成为 `NativePlayerView` 的第二个调用方；Markdown 的旧适配已删除，
  不再保留两个同功能的原生视频视图。
- `FileTab.Content.media` 按候选扩展名在文本整读前分流，
  再由系统 AVAsset.load 的实际 playable／轨道验证，
  文件身份、generation、错误、刷新、保存禁用、关闭和 `TabSwitcherView`
  由现有 `FileTab` 生命周期处理，保持文本／图片原路径不变。
  SSH 媒体在没有受控随机访问时明确不支持，绝不伪装同名本机视频。
- `AVPlayer` 由文件标签持有，Dock 只显示且重挂载不重新创建解码任务。
  **优先原生 `AVPlayerView` 的视频画面内播放、拖动、音量、全屏和轨道控制**；
  文件内使用已验证轨道的显示尺寸（包含首选变换）等比约束播放器，
  不用浮动控件样式猜测画幅，也不把窗格边缘当成画面边缘。
  Markdown 目前关闭其全屏按钮，独立视频按显示场景启用，
  只在系统控制确实缺少倍速入口时补最小控件。
  不重写一套悬浮控件状态机、遮罩、计时器或重复速度／音量工具栏。
  非活动标签默认暂停，不启用幽灵后台音频。

- 独立和 Markdown 内嵌媒体通过 `NativeMedia.makePlayer()` 统一设置 `AVPlayerItem.allowedAudioSpatializationFormats`，使用系统空间音频策略；不使用已弃用的布尔配置，不引入第二套播放器。macOS 26 及以上使用真实四声道 APAC 夹具验证解码、原生播放和定位；实体空间听感另验。

## 任务

<a id="p1-t1"></a>
### P1-T1 与音频共享的本机媒体检查、路由及版本保护

- **位置**：`FileTab.readContent / matches / reloadFromDiskIfClean`、
  `MarkdownMedia`／AVPlayerView 适配、`TabSwitcherView` 与宿主测试。
- **实施**：沿 [文件预览路由](../file-viewer-routing/plan-p1.md#p1-t1) 和
  [音频共同底座](../audio-file-playback/plan-p1.md#p1-t1) 接入，
  复用音频 P1 建立的同一文件媒体 `Content` 表示，
  按真实 AVAsset 音视频轨道决定呈现方式，
  不能重新实现媒体类型分发、单列 `.video` 读取分支或第二个 asset factory。
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
  真正关闭／`Project.terminateAll` 时清空 item／观察者、取消请求并释放后台解码任务；
  Dock 暂时卸载只暂停不销毁，不能把 View 消失当作文件生命周期结束。
- **验证**：真实视频画面、音频输出、seek、倍速／暂停修改、
  字幕按钮有无状态、静音与全屏往返、Mac 不同窗口尺寸／屏幕比例／Retina、
  点击／悬停／焦点／触控板、右键不重复控件；
  两视频／音视频混合切换、Dock 重挂载、关闭和系统唤醒不漏播放器。

## 阶段验收

本轮远端连接、现有设备及缺配设备延期规则统一遵循[共用验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；
任务独立核销与阶段共同验证按[验收归属](../file-viewer-routing/plan-p1.md#acceptance-ownership)，不复制公共测试。

复用音频的文件身份与 AVAsset 宿主测试、Markdown 嵌入视频回归，
新增 AVPlayerView 与多文件生命周期测试；执行相关 `make test:...`、
`make build`、阶段 `make test` 及隔离 Bailey Dev 的真实画面／声音／菜单／全屏操作。
按 `docs/testing.md` 核销权限、环境、设备、异常、容量和跨格式组合。

### 视频文件专项验收矩阵（P1）

共用文件与运行环境执行[共享 R01–R11](../file-viewer-routing/plan-p1.md#shared-verification)，
并回归音频 P1 的 A01–A08 中适用的 AVAsset／身份／生命周期场景；
只有真实 `AVPlayer` 输出可见画面且用户操作生效，才能判为视频功能成功。

| 编号 | 真实容器、轨道和交互 | 完成判据 |
| --- | --- | --- |
| V01 容器／编码 | MP4／MOV／M4V、H.264／HEVC、系统支持的 ProRes、零字节、损坏 moov／不完整索引、扩展名伪造、不支持 codec／受保护资源。 | 由 AVAsset.playable 和实际视频轨判定；缺少解码支持提示失败，不黑屏假装成功或试图绕过受保护媒体。 |
| V02 源文件与大容量 | 本机 10s／多小时、`32/64/256 MiB` 以上的真实大媒体、快速打开／重复暂停／外部替换、Finder 项目外文件、只读与文件被删除。 | 不经 TextKit 32 MiB 读入或 Markdown 64 MiB 暂存，按实际 `file://` 流读；播放器属于打开的本机文件且不写入源字节。 |
| V03 轨道与画幅 | 无音轨的视频、有音频无视频的 MP4、双音轨、竖屏、1:1／16:9／21:9、旋转元数据、字幕轨有／无、4K／HDR（系统支持时）。 | 音视频种类由真实轨道决定；视频等比显示，旋转、画面裁剪和色彩与原始文件一致，无轨道不给虚假的选择项。 |
| V04 原生控件 | `AVPlayerView` 播放、seek、静音／音量、0.5×／1×／2×、无字幕时隐藏控制、暂停悬停／播放闲置、全屏进入／退出。 | 优先原生画面内控制；每个动作真影响 AVPlayer，不加第二条悬浮播放器 UI；倍速缺失时仅补被实际系统证明缺失的控件。 |
| V05 输入与几何 | 全屏、极窄 Dock／双列、竖屏／超宽视频、黑边、1×2× 显示器、鼠标移动、系统 Space／方向键、中文 VoiceOver 和主菜单焦点。 | 控件跟随可见视频矩形、可用且不阻断画面操作；只有真实播放器焦点接受热键，不抢终端、文本编辑与另一窗口。 |
| V06 媒体身份 | Mac 与 SSH 同名字节不同，symlink／权限／路径重命名／文件被替换、AVAsset 慢加载时切另一文件或关标签、文件恢复后重载。 | 不跟随错误机器，不把旧轨道／旧封面显示到新标签；使用与音频共享的一条媒体 Content 及身份检查，遇到失效能恢复或明确报错。 |
| V07 外部引用和请求 | MOV 外部引用／相对媒体、真实 `AVURLAssetReferenceRestrictions.forbidAll`、文件本身合法但引用文件越界／不在项目目录。 | 实测系统是否阻止间接读取，不能只检查 AVAsset 配置字段；无法保证隔离时不得默许可执行或可读的外部来源。 |
| V08 多实例与回归 | 视频 A／B、视频与音频／Markdown 内嵌交替播放，项目／Dock 隐藏，真实关闭／重新打开，100 次播放暂停和 10／100 次标签开闭。 | 文件标签保持单一 player／原生表面和当前播放位置，非活动暂停、真正关闭回收，Markdown 内嵌按需加载仍可用且不漏临时文件／声音。 |

必须交叉 V01×V02、V03×V05、V04×V05、V06×V08、V07×V06 和 R09×V08。
宿主验证 AVAsset 轨道、身份和取消；真实画面／声音／全屏／手势由隔离 Bailey Dev 测试，
需要实际生成并验证有视频轨的合法媒体，不能用空文件只测试错误提示取代播放验收。
