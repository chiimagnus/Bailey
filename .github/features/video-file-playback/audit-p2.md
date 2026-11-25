# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：原生多音轨切换实际 PCM、中文字幕、定位、换源、系统全屏（含半速真实像素）、双窗 117 次跨格式会话和冷启动已验；内置输出软件通路已确认，物理听感、HDR 光学呈现（软件合成链已通过）及对应交叉项尚未核销；真实睡眠由用户延期亲验，缺配外接屏延期；蓝牙与内置输出实际切换通过。
- **本轮范围**：缺配设备延期、远端只用 Tailscale SSH，按[本轮验收环境](../file-viewer-routing/plan-p1.md#acceptance-environment)；可执行项仍需验收。

## 任务与改动

- **P2-T1 系统轨道选择、准确播放位置与全屏恢复**：NativeMedia／NativePlayerView：实际 AVMediaSelectionGroup 与 AVPlayerItemVideoOutput，快速连续 seek 最终帧；NativeMediaFileTests 使用恒定/可变帧率 H.264、双真实音轨及 HDR。
- **P2-T2 外部更换、睡眠恢复和全链路资源收尾**：FileTab、NativeMediaEnvironmentObservation：a9b298ed 原生暂停、换源/关闭退役、睡眠唤醒与输出变化通知，阻止旧 item 恢复。

## 发现项

## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/NativeMediaFileUITests.swift` 的全屏进度断言。
- 摘要：本机进入 AVKit 全屏后，测试未能从自动隐藏的原生控件读到后续时间；现有证据不能判定播放中断。
- 风险：测试把“滑块不在无障碍树”当作 0 秒，既可能误报，也不能证明暂停时播放位置不动。
- 验证缺口：进入系统全屏后主动移动指针唤回原生控件，读取实际时间或对照真实视频帧；观察不到控件时不代入默认值。确认画面真的冻结后，再查窗口失活与播放时序。
- 旧证据：`/tmp/bailey-seven-visual-ui-20261125.log` 的 13.94～14.14 秒能找到全屏滑块，15.22 和 16.19 秒只剩枚举；这次未记录同一时刻的实际画面变化。
- 当前显示器实测：隔离 Dev 进入 1800×1130 原生全屏。暂停两帧的中央 240,000 像素无明显变化，返回原窗前后时间同为 2.0066 秒；默认速度播放时中央 25,144 像素明显改变（阈值 32/255），从 1.5578 秒进全屏、回原窗仍在播放且为 8.6337 秒。源校验和不变。证据：`/tmp/bailey-video-data-generation.EONgtq/{fullscreen,full-pixels}.log`。
- 解决证据：`65c602e8` 本机隔离完整 App 半速原生全屏播放时，中央区域 30.89% 像素改变；暂停后连续三次真实画面采样，变化比例均不超过 0.2%。退出后播放推进、暂停位置恢复（0.1 秒容差）、源字节一致。27.389 秒，单项通过，无跳过。日志 `/tmp/bailey-preview-retry2.9NmlJE`。不以隐藏滑块的默认零值判断播放；不代替外接屏、HDR 或设备切换。


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`BaileyUITests/Editor/FilePreviewWorkspaceUITests.swift:197`
- 摘要：`完整 App 七格式双窗口真实 seek 后切回视频，时间变为0；等待稳定后仍不恢复。`
- 风险：`播放位置在窗口/标签切换后丢失。`
- 已证实一条触发路径：APFS 上仅写扩展属性会变动 ctime；旧实现误判为媒体内容更换，销毁了已定位的 player 与 item。原 GUI 的第一次普通切回仍显示 00:04，第二次从另一窗口由 Launch Services 重新投递时才变为 0；当时未采集文件属性，不能认定与该路径完全相同。
- `b029b857`：通过同一已打开的文件描述符读取 Darwin `ATTR_CMN_GEN_COUNT`。同一入口、权限模式、大小、mtime 均匹配时，只有相同的非零数据世代可证明内容未变；不可用时回退完整 stat 比较。源路径、文件可读性和真实解码检查保留。
- 验证：`make build:dev`、严格验签和两项新增 XCTest 源码类型检查通过；真实 Dev 动态库的 FileTab + AVPlayer 上，视频和音频此前均被重置，修复后仍是同一播放器、同一 item、同一 2 秒位置。验证了原位改坏并恢复同 inode／大小／纳秒 mtime、原子换回、共享映射时世代为 0 的严格回退。该验证器不是完整 App 或正式 XCTest。日志：`/tmp/bailey-video-data-generation.EONgtq/{red,green}.log`。
- 完整 App 定点复验：使用实际 12 秒内嵌字幕样本，从另一窗口通过 Launch Services 将原视频投递回原窗口。仅投递就使 ctime 改变，inode／大小／纳秒 mtime 不变，文件可见系统 `com.apple.lastuseddate#PS` 扩展属性。再次手动加标签并投递，两次均保留暂停、静音和原位置 4.013201320132013 秒。画面中央 45,600 像素对照原定位帧，两次均无明显差异（通道差 >32/255）；恢复播放 5.386→6.917 秒，同区域 3,190 像素发生变化，源 SHA-256 一致。证据：`/tmp/bailey-video-data-generation.EONgtq/smoke.log` 与同目录截图。此结果核销 F-01，不代替七格式综合正常退出／冷启动或硬件矩阵。


## 验证与未覆盖

- 最新本机隔离 App：真实内嵌字幕、播放中进出全屏、后台标签位置保持均通过；七格式双窗冷启动也已通过。外接 HDR／多屏、实体输出设备切换、真实睡眠及长会话仍待验收。

- NativeMediaFileTests 实际 4K 10-bit HDR、双音轨、固定/可变帧率红绿像素定位、长视频末段和真实替换；100 次多格式播放开闭及换源/通知退役已通过既有宿主验收。详见 P1 审计与 todo.toml。
- 远端 6102bf3e 完整 App 视频全屏连续播放和标签切换保留位置两项通过（Actions 45448818282）。45534516603（4575cddb）再次实际通过视频全屏及标签切换两项；新增真实字幕样本用例因云端未配置样本目录跳过，未核销。
- V09 的实体音轨听感／字幕组合、V11 多屏倍率/HDR 实际呈现、物理设备切换、真实睡眠与 V12×V13 完整 App 长会话仍待具备设备与独占图形会话；不能以通知注入、解码信号或宿主 AVPlayer 对象替代。
- 最新共享构建、冻结宿主与完整 App 结果以 [文件路由审计](../file-viewer-routing/audit-p1.md) 为准；现行行为归 [文件编辑器](../../../docs/features/editor.md)。

- 2026-11-25 环境复核：内置 Retina XDR、内置扬声器；无外接 HDR／1×屏、第二个实体输出或已确认独占图形会话。未重跑不受共享保存改动影响的既有字幕及全屏用例，未执行实体呈现、睡眠及长会话。阶段 No-Go。

- `35503954`：真实完整 App 七格式双窗117次切换及正常退出／冷启动、全部关闭、原始字节核对通过；[共享 P1 审计](../file-viewer-routing/audit-p1.md) 记录完整命令与日志。设备、输入、严格 CAS 等独立门禁仍按各任务实际范围保留。

- 2026-11-25：c7840ffa 新增自有合成样本 demo-audio-tracks.mov（16 秒、H.264 320×180、两路 48 kHz 单声道 AAC，440/880 Hz，经 AVMutableMovie 标记 en/fr 同一 alternate group）。系统 AVPlayer 原生混合 PCM tap 验证 en→fr→en 暂停切换、播放中切 fr、跨文件再回时保留所选轨／位置／同一 player/item，文件字节一致。每次采样 26,844 帧，播放中法语 880 Hz 功率 1166.47、440 Hz 0.000299；字幕实际中文 cue 与无字幕样本复验通过，2/2 零失败零跳过（/tmp/bailey-media-tracks-final.AhtZ6j）。macOS 27 混合 PCM API 只进入测试，旧系统明确跳过本项，不抬高 App 部署目标。完整隔离 Dev 已操作原生法语菜单并确认内置输出通路；菜单勾选标记复验被临时 Sheet 中断，实际轨道输出证据来自宿主，不声称完成物理听感或该菜单勾选复验。P2-T1 功能验收核销；P2-T2 真实睡眠、物理声音及相关阶段门禁保留。

- 2026-11-26：HDR 真实挂载与系统 EDR 像素见 P1 审计；同场真实扬声器频谱实验见音频 P2 审计，未可靠核销物理听感。真实睡眠仍需确定安全唤醒条件；未模拟成实机通过。

- 2026-11-26：用户明确将真实系统睡眠／唤醒延期至本人亲验；保留模拟通知与资源退役既有证据，不计作实机睡眠通过。

- 2026-11-26：共享原生播放器 `f1df034c` 的实际视频选轨 PCM 专项通过；同版隔离 Dev 独立 WAV 的扬声器到麦克风声学验证通过（见[音频 P2](../audio-file-playback/audit-p2.md)）。另用同频谱、真实 H.264/AAC 视频尝试完整 App 声学复验，前一次 AX 观测不完整、复试 ScreenCaptureKit 已被另一进程持有，均未到达播放/采集；未终止其他进程，未以 WAV 结果冒称视频实体输出通过。日志 `/tmp/bailey-video-speaker-check.20c8BG/{run.log,retry.log}`。真实睡眠已延期，视频物理声学结果保留未核销。

- 2026-11-26：用户连接 Beats Studio Pro 后恢复第二输出设备验收。`a2d9f21d` 实际 Core Audio Bluetooth（91）→内置扬声器（77）→Bluetooth，独立 M4A 与双音轨 MOV 各双向切换，系统事件自动暂停、保持 player/item/位置、手动恢复后时钟推进、Core Audio 进程活动输出设备与目标一致，关闭退役及原字节不变；1/1、零跳过、4.951 秒。退出后默认输出仍为原 Beats。不将真实路由与 PCM 等同于耳机主观空间听感或视频独立声学测量。日志 `/tmp/bailey-real-route.log`；复验命令 `TEST_RUNNER_BAILEY_REAL_AUDIO_ROUTE_TEST=1 make test ONLY_TESTING=BaileyTests/NativeMediaFileTests/testActualBuiltInAndBluetoothOutputRoutesPreserveTheFilePlayer`，仅在明确授权改变系统输出且蓝牙耳机已连接时运行。

- `3e421fd1`：扩展回归 58 项中同一选轨用例两条播放时钟断言失败、1 项真实七格式样本环境跳过；真实混合 PCM 正确，原因是音频 tap 在播放时钟推进前收到预缓冲。保留原断言，等待两条件同时满足；百次真实开闭压力与选轨同批复验 2/2，零跳过、零失败。扩展 58 项尚未整批复验。日志 `/tmp/bailey-spatial-expanded.log`、`/tmp/bailey-audio-clock-rerun.log`。
