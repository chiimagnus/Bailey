# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：真实格式、读取预算、定位及播放器隔离已有原生和部分完整 GUI 证据；真实 CENC 保护判定及拒绝／恢复已通过；实际设备输出／切换、睡眠与 VoiceOver 尚未完成。

## 任务与改动

- **P1-T1 共用音视频实际文件校验与正确读取分支**：NativeMedia.open、LocalWorkspaceBackend.readableFile、FileTab.readContent；独立本机文件真实 URL，SSH 拒绝，首个实际解码缓冲、权限与文件身份校验；Markdown 仅有界授权暂存。
- **P1-T2 文件标签所有的 AVPlayer 和可用的紧凑控件**：FileTab、NativePlayerView、MarkdownMediaView；原生 AVPlayerView 样式，标签切换暂停、重挂载复用；关闭、刷新和改名退役旧 item。紧凑控件实际隔离 GUI 与宿主结果见 919d2c41、a85ed10f、d5698ca3。

## 发现项

## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Deferred`
- 位置：`Bailey/Editor/FileViewerView.swift:1868`
- 摘要：`原浮动 AVKit 与波形布局割裂；85022a8b 去除波形时误将 AVKit 替换为自行组合的 FileAudioControls。用户明确要求系统播放器，而非自定义控件。`
- 风险：`偏离原生播放器需求，并重复维护系统已有的按钮、进度、音量和观察逻辑。`
- 预期修复：`复用 NativePlayerView 的 AVPlayerView，删除 FileAudioControls 及专用字符串；不恢复波形。核查紧凑系统布局及原有播放器生命周期。`
- 验证：`真实音频窗口截图/实际控制和轴线，窄/宽/深浅窗口，seek/播放/音量/速率/焦点，Markdown 音频。`
- 解决证据：`4c304e53 恢复 AVKit，删除自建控件。宿主 5/5，完整 App 原生定位、音量及静音已验证；采用系统 floating 样式（inline 未暴露直接音量滑块）。播放队列启动但 AX 时间轴超时；完整播放／切换、窄窗可操作性与实体设备尚待核销。日志 /tmp/bailey-audio-avkit-verified.pulZ13uc、/tmp/bailey-audio-avkit-ui-retry.70HpEaHA。`


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/NativeMediaFileUITests.swift:190-198`
- 摘要：`隔离云端完整 App 的 AVKit 原生音量调节为 0.4375，测试硬编码指针比例 0.35±0.08 未通过`
- 风险：`未验证静音还原及切标签保持；不能仅凭失败断言推定播放器音量失效`
- 预期修复：`核对实际 AVKit 控件值、方向、范围和还原行为，区分系统控件指针到数值映射与 Bailey 自身故障；不替换原生控件或放宽任意误差`
- 验证：`读取 45448818282 真机截图/录屏及宿主 AVKit AX；运行实际音量和静音回归`
- 解决证据：`45534516603（4575cddb，macOS 27.0.1/Xcode 27.2 独立云端）：testNativeAudioControlsAndPauseWhenAnotherFileTakesFocus 实际通过，32.879 秒；音量低高及中间值、静音恢复、真实播放/暂停及文件切换通过。前次指针映射问题已核销。xcresult 与日志 /tmp/bailey-gui-45534516603.h0OonZ；实体设备与语音播报仍独立阻塞。`


## 验证与未覆盖

- 历史 `85022a8b` 的自定义 AppKit 播放条曾通过本机播放、进度、音量及失活暂停；不属于 AVKit 系统播放器验收。用户要求恢复系统控件，须复验。

- 2026-11-24：冻结提交 `05696bb5` 的 Debug、Release、UI Test Target 构建及签名通过；真实样本、授权 Windows SSH、隔离 APFS 卷与完整宿主 `make test` 1366/1366 通过，0 失败、0 跳过，2007.208 秒。日志：`/tmp/bailey-seven-20261124-svg-final-full.log`。仅核销宿主证据，完整 App GUI 与实体设备条件仍保留原阻塞，不据此改为 Go。

- NativeAudioTimingTests：真实样本派生 24 位单声道、32 位六声道、FLAC、裸 VBR AAC，真实 AVAsset 格式、声道、12 秒时长和 11 秒 seek，原字节一致。NativeMediaFileTests：MP3／AAC／WAV／AIFF／CAF 等实际音频缓冲、定位、大小写与链接。
- f9b124ca、fd055633：截断和置零、未知 codec、引用型容器拒绝，原子替换恢复；64 MiB−1／等于／+1 的真实 M4A，独立文件可读、嵌入精确限额；获授权 Windows 同名隔离已测。
- bc97976c：实际 48 kHz/16-bit 单声道 4 小时 PCM（1,382,400,044 字节），0／7200／14399 秒三个不同频率的每段一秒样本逐字节核对，真实播放推进；从加载至三处定位约 0.287 秒，过程峰值 RSS 增量 22,691,840 字节，关闭 item 清空、文件 SHA-256 不变。不声称连续播放四小时。
- a85ed10f 百次实际音视频项目开闭；d5698ca3、8c6b63b1 实际 M4A/WAV 与 MP4 的两所有者 AX 加载、私有暂存、seek/暂停/关闭互不干扰，源字节与暂存目录清理。七格式组合有一个 AVKit 私有空壳（暂停且 item=nil），不是活跃播放器；不宣称所有系统对象清零。
- 291 项补跑完整通过（零失败／跳过），含 17 项媒体、原生音频计时、28 项原生生命周期；之后 3 项长时间轴及共享媒体定点测试通过。此前真实隔离 GUI 的音量／静音、播放、调速与标签暂停已验证。
- bbb7b7f7：自有 AAC/H.264 的真实 ISO CENC 加密媒体通过原生保护判定；同时 playable=true，独立 FileTab 与 Markdown 暂存的共用入口均拒绝；原字节不变，未加密同源版本原子替换恢复。测试不依赖商业许可证，不验证受保护内容的授权播放。当前桌面有用户活动，不抢占 VoiceOver、音频设备切换、系统睡眠和完整 App 长会话；宿主 muted 播放及 AX 控件不证明物理声音输出或语音播报。需可切换输出设备和独占 Dev 会话。以上阻塞阶段。
- 用户确认 macOS 27.3／Xcode 27.2、Apple Silicon，无需 15.6 实机，保留部署目标。文档归 [文件编辑器](../../../docs/features/editor.md)。
- 最终 e4267d71：NativeMediaFileTests 20 项、NativeAudioTimingTests 1 项、NativePaneRetentionIntegrationTests 28 项全部通过。真实媒体首次加载中改名及关闭各 10 次均在 loading 状态触发，最终资产路径、轨道、源字节和旧播放器退役一致。共享记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。

- `4c304e53`：系统 AVKit 原生控件复验，五项宿主通过、零跳过，退出 0；直接验证 AVPlayerView 挂载、七次定位、三个精确音量值、真实编码、独立与嵌入生命周期、视频布局和双窗 100+100，Dev 严格验签通过。实际四种窗宽核对视图边界，不等于窄窗每个控件均可操作。原生 `.inline` 未暴露直接音量滑块，因此独立音频恢复 `.floating`（视频及 Markdown 保持原样）。
- 完整 App 媒体批次 2/4 通过（视频字幕、定位和前后台），另两项在启动时失败。音频单项复验成功进入系统控件，定位至 4.0706s、音量及静音恢复通过；点击播放后 CoreMedia 报告 Playing、内置扬声器 AudioQueue 启动、时间基速率 1，随后 UI 时间轴仍超时，不能据此判定实际声音或完整播放／切换通过。退出 2；保留未核销门禁，不另造控件或放宽断言。日志 `/tmp/bailey-audio-avkit-verified.pulZ13uc`、`/tmp/bailey-audio-avkit-ui.VaE9WYf2`、`/tmp/bailey-audio-avkit-ui-retry.70HpEaHA`。

- `4c304e53`：正式 Debug `make build` 退出 0，Debug 与 Dev 严格验签通过，未替换已安装 App。日志 `/tmp/bailey-audio-avkit-build.log`。
