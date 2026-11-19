# P1｜文件标签原生音频播放

交付可打开、播放、暂停和定位的本机音频文件标签，不需要新建独立工具面板。

## 技术决定

**不引入音频播放 SPM。** 只使用 Apple **AVFoundation**（`AVURLAsset`、`AVPlayer`、`AVPlayerItem`、`AVAsset.load(...)` 的异步元数据 API）、SwiftUI 原生按钮／进度反馈，必要时通过 AppKit 桥接媒体控件焦点。
媒体是本机 `file://` URL 只读播放；不借助 `WorkspaceBackend.read(maxBytes:)` 全量读入，不接入 FFmpeg、第三方播放器或音频数据库。
播放位置、音量、倍速、暂停及真实资源所有权由原有 `FileTab` 生命周期负责，后台／非活动标签的暂停策略统一管理而非为每个 SwiftUI View 新建播放器。
**SSH 音频暂不做**；当前 `SSHWorkspaceBackend` 只提供有上限的整文件读取，不能伪造可随机访问流，也绝不能回退到同名 Mac 路径。

## 方案

入口仍是 `Project.openFile` → `FileTab` → `FileViewerView`。
扩展文件类型的懒加载与展示路由，媒体 URL 是只读本机 `file://`，不通过 `WorkspaceBackend.read(maxBytes:)` 把完整音频载入内存。
AVFoundation 的 `AVPlayer` 生命周期归对应文件标签；只在需要时实例化，在真正关闭时释放。旧文本和图像路径不回归。
图形按钮、焦点与快捷键遵循 `docs/ui.md`，播放控制不写项目级“任务状态系统”。

## 任务

<a id="p1-t1"></a>
### P1-T1 媒体类型判定与安全加载

- **位置**：`FileTab` 内容路由、`FileViewerView`、本机文件 URL / 文件状态检查。
- **实施**：用 `AVURLAsset`／异步 `load` 取时长与音轨，构建 `AVPlayerItem`，在音轨不可用、损坏、权限错误时提供原生错误状态；基于 macOS 实际解码能力判断，不只按扩展名。
  绑定本机文件身份、重命名、替换及加载取消；SSH 明确提示暂不支持，不创建错误的本地 URL。
- **验证**：合法 MP3/M4A/WAV/AIF/CAF、无效 codec、损坏头、零字节、只读路径、符号链接及文件变动。

<a id="p1-t2"></a>
### P1-T2 原生播放控件与生命周期

- **位置**：新增音频播放内容视图、`PaneContent` 文件标签状态及 `docs/features/editor.md`。
- **实施**：音频正文直接提供原生播放／暂停、可拖动定位、倍速选择、静音和音量 Slider；下方紧凑一行左侧速度、中央播放、右侧音量，不创建额外工具栏。速度和音量不藏右键；右键只保留低频媒体信息与回到开头。暂停状态设置倍速应更新 `AVPlayer.defaultRate`，不可因为修改 `rate` 意外开始播放。
  `AVPlayer` 由 `FileTab` 保持身份，Dock 视图重挂载不重建，关闭时暂停、置空 item 并释放；Space 只由真正获得焦点的原生控件响应。
- **验证**：不经右键直接播放、拖动 seek、选择 0.5×～2×、调节音量／静音；暂停时改变倍速不得自动播放。再验证实际音频输出、设备变动、切窗、项目切换、多文件播放与错误恢复，源文件不变。

## 阶段验收

`make build:ui`、受控宿主 AVFoundation 测试、隔离 Bailey Dev 播放与焦点，明确哪些编码由系统不支持而非 Bailey bug。
