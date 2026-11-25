# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：宿主定位与资源退役、真实原生 AVKit 播放／暂停定位恢复、双窗 117 次切换与冷启动通过；内置扬声器软件及实际声学输出均已确认，P2-T2 独立核销；VoiceOver 和 P1 门禁仍未完成；真实睡眠由用户延期亲验，蓝牙耳机与内置扬声器双向切换已通过。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。

## 任务与改动

- 原 P2-T1（波形摘要、缩放与连续 seek）已取消，以下历史发现不再是现行验收项。
- **P2-T2 隐藏、重新激活与真实资源回收**：FileTab／NativePlayerView 同一 AVPlayer 的暂停、重挂载、换源取消和退役；a9b298ed、3f87e2e8。

## 发现项

## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/NativeMediaFileUITests.swift:126`
- 摘要：`云端首次点击波形实际 seek 和 AX 数值均通过，后续 press thenDragTo 产生 pathType=1 的触摸事件、buttonType=0；录像指针没有移动`
- 风险：`测试未向 macOS 波形交付真实鼠标拖动，无法核验连续 seek 与后续缩放`
- 预期修复：`使用项目已验证的 macOS click(forDuration:thenDragTo:) 鼠标拖拽 API，保留实际 AVPlayer 和 AX 时间断言`
- 验证：`独立云端完整 App 原用例点击、实际鼠标拖拽、缩放、切换及原字节；不放宽时间断言`
- 解决证据：`e05e3732：本机独占图形会话实际 testWaveformSeeksTheSameNativeTimelineAndZoomsItsVisibleInterval 通过（29.510s），macOS 鼠标真实拖动、seek/缩放与 AX 时间断言未放宽；NativeMediaFileUITests 5/5（149.935s），无跳过，含真实内嵌字幕与系统全屏。/tmp/bailey-seven-local-ui-e05e3732-20261125.log。`


## 发现 F-01

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/NativeMediaFileUITests.swift:113-124; Bailey/Editor/NativeAudioWaveformView.swift:148-172,275`
- 摘要：`隔离云端完整 App 首次点击波形后，时间和无障碍值联合断言超时；录屏显示实际 AVKit 及波形游标移动`
- 风险：`可能存在跨系统 AX 表达差异或波形时间反馈失配，后续真实拖动／缩放未验证`
- 预期修复：`分别验证已接受的 AVPlayer 时间、绘制游标及真实 AX 值，定位差异后修复所有者或无效测试假设`
- 验证：`实际宿主挂载波形与 AVPlayerView，核对原生 AX 时间；完整 App 点击／拖动／缩放／重挂载复测`
- 解决证据：`bd72f327：原生 AXSlider 替代旧 AXUnknown，宿主七次真实 AVPlayer 定位及 AX 数值/描述/步进通过。隔离云端 45534516603（4575cddb，macOS 27.0.1）：首次波形点击后 expectTime(9) 实际通过，验证 AVKit 与波形时间/AX 数值；原失败已核销。后续拖动没有交付 macOS 鼠标事件，单列 F-02，完整拖动与缩放仍不算通过。实际 xcresult /tmp/bailey-gui-45534516603.h0OonZ。`


## 验证与未覆盖

- `make test ONLY_TESTING` 联合图像标注、原生音频计时及真实 300 轮大图用例：27/27 通过、0 跳过、退出 0；实际 AVPlayer／AVKit／AX 验收在本机 27.3 完成。make build:ui、Dev 严格验签及 make build:release、Release 严格验签已通过；27c2b254 最新全量已实际启动，结果尚未结束（见文件路由 P1 审计）。
- 真实 4 小时 PCM、不同编码、定位、可见区间和资源退役的既有证据见 todo.toml 与 P1 审计；85022a8b 曾验证自定义 AppKit 控件的播放、进度、音量及失活暂停；恢复 AVKit 后需复验；独立音频已移除波形，不再以波形点击／拖动／缩放作为验收。实体声音输出、设备切换、真实睡眠、VoiceOver 与双窗口长会话仍未核销。需独占图形会话及对应设备。
- 现行行为同步 [文件编辑器](../../../docs/features/editor.md)。

- 2026-11-25 环境复核：仅内置扬声器，无第二个实体输出；未确认独占图形会话，未切设备或触发系统睡眠。不用 AVPlayer 状态或通知注入替代实际听感与系统事件。阶段 No-Go。

- `4c304e53`：恢复 AVKit 后五项宿主回归全部通过，含双窗 100+100、播放对象及暂存释放；完整 App 播放进度复验和真实设备仍未核销，详见 P1。

- `7bbfd8ab`：原生 AVPlayer 实际播放、显示计时、暂停保持及独立／嵌入资源隔离专项 3/3，零跳过；完整 App 修正后的标签切换测试已构建及验签，未运行。实体设备和阶段门禁仍未核销，见 P1。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 2026-11-25：当前 NativeMediaFileTests 睡眠／唤醒、输出变化通知路径及旧 item 退役、跨标签暂停并保留原位置均通过；独立 Dev 实际播放时 Core Audio 确认内置输出设备运行（详见 P1）。未改变系统输出、未触发真实睡眠，不以模拟通知或软件输出替代物理听感。用户正在使用共享桌面，P2-T2 blocked。

- 2026-11-26：在现有麦克风授权且无其他麦克风客户端的条件下，内置输入 44.1 kHz 实际采集短时已知 440／880 Hz 能量统计（不保存原始音频）；播放定点 1/1 通过，谱峰出现但当前系统音量较低且环境 RMS 波动，不能可靠对齐各选轨时刻。不改音量与权限，不核销物理听感。证据 `/tmp/bailey-physical-acceptance.veEc5t/acoustic-spectrum.log`、`acoustic-xctest.log`。真实睡眠尚无已保证的短时自动唤醒条件，不能中断当前会话；通知路径既有证据有效。

- 2026-11-26：用户明确将真实系统睡眠／唤醒延期至本人亲验。系统睡眠与唤醒通知路径原测试仍有效，真实睡眠不计通过且不再单独阻塞本轮。

- 2026-11-26：`f1df034c` 版本完整隔离 Dev 实际播放自制 14 s WAV（静音、440、880、静音、880、440、静音，各 2 s），原生播放复选框 0→1、timeline 3.309 s，源文件字节不变。现有内置麦克风授权下仅记录两频点能量／RMS／时间戳，系统输出 13%、未改音量或权限；128 个时间窗，按点击结束时间对齐、每段排除边缘 0.35 s，440 Hz 两段中位能量 7.91e-5／6.75e-5，880 Hz 两段 1.53e-5／1.35e-5，三静音段两频点均低于 4.2e-7，实际声音从内置扬声器传至麦克风的证据成立。未保存原始麦克风录音，未声称主观音质或实体空间听感通过。隔离 App 与采集进程正常退出；日志 `/tmp/bailey-speaker-check.l0h7Ol/{run.log,spectrum.log}`。真实睡眠及第二输出设备已延期；结合已有生命周期实测，P2-T2 独立核销，不把共享阶段未验重复计为任务阻塞。

- 2026-11-26：用户连接 Beats Studio Pro 后恢复第二输出设备验收。`a2d9f21d` 实际 Core Audio Bluetooth（91）→内置扬声器（77）→Bluetooth，独立 M4A 与双音轨 MOV 各双向切换，系统事件自动暂停、保持 player/item/位置、手动恢复后时钟推进、Core Audio 进程活动输出设备与目标一致，关闭退役及原字节不变；1/1、零跳过、4.951 秒。退出后默认输出仍为原 Beats。不将真实路由与 PCM 等同于耳机主观空间听感或视频独立声学测量。日志 `/tmp/bailey-real-route.log`；复验命令 `TEST_RUNNER_BAILEY_REAL_AUDIO_ROUTE_TEST=1 make test ONLY_TESTING=BaileyTests/NativeMediaFileTests/testActualBuiltInAndBluetoothOutputRoutesPreserveTheFilePlayer`，仅在明确授权改变系统输出且蓝牙耳机已连接时运行。
