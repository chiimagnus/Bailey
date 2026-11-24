# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：已验证实际轨道、解码帧、源字节、画幅、HDR 元数据与原生播放器；真实 CENC 保护判定及拒绝／恢复已通过；物理 HDR／外接屏和设备、完整 App 组合尚未核销。

## 任务与改动

- **P1-T1 与音频共享的本机媒体检查、路由及版本保护**：NativeMedia.open 与音频共用文件权限、身份和版本，存在视频轨必须有实际可解码视频帧；不将损坏视频降级成音频，禁止引用外部媒体。
- **P1-T2 原生 AVPlayerView 画面内操控与文件生命周期**：NativePlayerView／FileTab 的 AVPlayerView 画面内控制、实际轨道呈现几何、字幕、原生全屏、生命周期及独立嵌入播放器。用户行为文档归文件编辑器。

## 发现项

## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Editor/NativeMedia.swift`
- 摘要：`有视频轨但视频样本完全损坏时被降级为音频`
- 风险：`独立文件与 Markdown 嵌入同时接受损坏视频，错误建立播放器`
- 预期修复：`以轨道存在性区分纯音频，存在视频轨必须实际解码成功`
- 验证：`testUndecodableVideoWithIntactAudioDoesNotMasqueradeAsAnAudioFile，真 MP4 192 帧样本置零、音频原样、两入口拒绝及原子替换恢复`
- 解决证据：`fd055633：真实 MP4 的 192 个 H.264 样本全部置零而音频原样，AVAsset 仍报告 playable；Red 三个最终行为断言失败，Green 两入口拒绝并恢复实际视频，17 项 NativeMediaFileTests 全过。d5698ca3 另验证真实嵌入与独立媒体的 AX 按钮、私有暂存和关闭隔离。`


## 验证与未覆盖

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- fd055633：F-01 Red→Green，真实视频损坏、音轨仍有效的容器两入口拒绝并恢复；未知 codec、截断、引用容器、真实文件身份、同名 Windows SSH 不回退及 64 MiB 嵌入限额验证。H.264／HEVC／ProRes／M4V 实际解码帧。
- 329,018,738 字节 512 秒 ProRes，seek 至 510 秒约 112 ms、实际像素吻合、峰值 RSS 增量约 5.6 MiB，源校验和与播放器退役。bc97976c：300 帧／30 秒夹具拼接 240 段，导出实际时长 7200 秒，首段／中段／末段／回首段定位，导出首个 H.264 压缩样本原字节一致；独立打开导出文件后的标准化 sRGB 像素完全一致，源文件校验和不变。不是连续播放两小时。
- 原生画面六种横／竖／方／超宽／非方形像素／Clean Aperture × 三种窗格，原生 AVPlayerView 实际 bounds、控件范围和播放器身份；真实 4K Main10 HEVC 解码、BT.2020/PQ 元数据和 10-bit 样本，实际双音轨、中文字幕 cue；既有隔离 GUI 实际全屏往返与字幕开关。并非 HDR 物理屏实测。
- 100 次独立媒体交替开闭、七格式百次真实宿主挂载、d5698ca3/8c6b63b1 的真实 WAV/MP4 与嵌入播放器 AX 操作、定位、暂停、关闭与暂存文件清理。291 项补跑完整通过；长时间轴及共享媒体 3 项再通过。
- bbb7b7f7：自有 H.264 视频与 AAC 音频真实 ISO CENC 加密，AVFoundation 识别 protected=true 且 playable=true；独立和 Markdown 共用入口拒绝，原字节不变，同源未加密版本原子替换恢复。测试不验证商业许可证或受保护内容的授权播放。实际 1×／外接 HDR／多屏、音频设备切换、系统睡眠、VoiceOver 和完整 App 多窗口长会话仍需独立图形会话与真实设备，不抢占当前用户桌面。当前系统 macOS 27.3／Xcode 27.2 Apple Silicon，原部署目标保留；不将宿主像素、真实解码元数据当作物理呈现。上述阻塞 P1。
- 文档见 [文件编辑器](../../../docs/features/editor.md)，不另建保存路径或专属工具条。
- 最终 e4267d71：NativeMediaFileTests 20 项及 NativePaneRetentionIntegrationTests 28 项全部通过；真实加载时改名、旧路径被音频替换及关闭重开各 10 次均在 loading 状态触发，未发布旧资产，源文件字节一致。共享记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
