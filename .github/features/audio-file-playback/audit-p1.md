# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：真实格式、读取预算、定位及播放器隔离已有原生和部分完整 GUI 证据；合法 DRM、实际设备输出／切换、睡眠与 VoiceOver 尚未完成。

## 任务与改动

- **P1-T1 共用音视频实际文件校验与正确读取分支**：NativeMedia.open、LocalWorkspaceBackend.readableFile、FileTab.readContent；独立本机文件真实 URL，SSH 拒绝，首个实际解码缓冲、权限与文件身份校验；Markdown 仅有界授权暂存。
- **P1-T2 文件标签所有的 AVPlayer 和可用的紧凑控件**：FileTab、NativePlayerView、MarkdownMediaView；原生 AVPlayerView 样式，标签切换暂停、重挂载复用；关闭、刷新和改名退役旧 item。紧凑控件实际隔离 GUI 与宿主结果见 919d2c41、a85ed10f、d5698ca3。

## 发现项

## 验证与未覆盖

- NativeAudioTimingTests：真实样本派生 24 位单声道、32 位六声道、FLAC、裸 VBR AAC，真实 AVAsset 格式、声道、12 秒时长和 11 秒 seek，原字节一致。NativeMediaFileTests：MP3／AAC／WAV／AIFF／CAF 等实际音频缓冲、定位、大小写与链接。
- f9b124ca、fd055633：截断和置零、未知 codec、引用型容器拒绝，原子替换恢复；64 MiB−1／等于／+1 的真实 M4A，独立文件可读、嵌入精确限额；获授权 Windows 同名隔离已测。
- bc97976c：实际 48 kHz/16-bit 单声道 4 小时 PCM（1,382,400,044 字节），0／7200／14399 秒三个不同频率的每段一秒样本逐字节核对，真实播放推进；从加载至三处定位约 0.287 秒，过程峰值 RSS 增量 22,691,840 字节，关闭 item 清空、文件 SHA-256 不变。不声称连续播放四小时。
- a85ed10f 百次实际音视频项目开闭；d5698ca3、8c6b63b1 实际 M4A/WAV 与 MP4 的两所有者 AX 加载、私有暂存、seek/暂停/关闭互不干扰，源字节与暂存目录清理。七格式组合有一个 AVKit 私有空壳（暂停且 item=nil），不是活跃播放器；不宣称所有系统对象清零。
- 291 项补跑完整通过（零失败／跳过），含 17 项媒体、原生音频计时、28 项原生生命周期；之后 3 项长时间轴及共享媒体定点测试通过。此前真实隔离 GUI 的音量／静音、播放、调速与标签暂停已验证。
- 合法 DRM 文件未提供，无法核对实际受保护资源；现有不支持／损坏／引用容器测试不替代 DRM。当前桌面有用户活动，不抢占 VoiceOver、音频设备切换、系统睡眠和完整 App 长会话；宿主 muted 播放及 AX 控件不证明物理声音输出或语音播报。需获授权 DRM、可切换输出设备和独占 Dev 会话。以上阻塞阶段。
- 用户确认 macOS 27.3／Xcode 27.2、Apple Silicon，无需 15.6 实机，保留部署目标。文档归 [文件编辑器](../../../docs/features/editor.md)。
- 最终 e4267d71：NativeMediaFileTests 20 项、NativeAudioTimingTests 1 项、NativePaneRetentionIntegrationTests 28 项全部通过。真实媒体首次加载中改名及关闭各 10 次均在 loading 状态触发，最终资产路径、轨道、源字节和旧播放器退役一致。共享记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
