# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：波形摘要、同一 AVPlayer 定位、原生 AX 滑块及资源退役已有真实宿主证据；完整 App 拖动／缩放复验、实际设备及 P1 阶段门禁仍未完成。

## 任务与改动

- **P2-T1 波形摘要、缩放与连续 seek**：NativeAudioWaveformView 可见区间 PCM 摘要、事件驱动播放头、同一播放器 AXSlider 步进；b2be63bd、3f87e2e8、bd72f327。
- **P2-T2 隐藏、重新激活与真实资源回收**：FileTab／NativePlayerView 同一 AVPlayer 的暂停、重挂载、换源取消和退役；a9b298ed、3f87e2e8。

## 发现项

## 发现 F-02

- 任务：`P2-T1`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`BaileyUITests/Editor/NativeMediaFileUITests.swift:126`
- 摘要：`云端首次点击波形实际 seek 和 AX 数值均通过，后续 press thenDragTo 产生 pathType=1 的触摸事件、buttonType=0；录像指针没有移动`
- 风险：`测试未向 macOS 波形交付真实鼠标拖动，无法核验连续 seek 与后续缩放`
- 预期修复：`使用项目已验证的 macOS click(forDuration:thenDragTo:) 鼠标拖拽 API，保留实际 AVPlayer 和 AX 时间断言`
- 验证：`独立云端完整 App 原用例点击、实际鼠标拖拽、缩放、切换及原字节；不放宽时间断言`
- 解决证据：`e05e3732：45534516603 事件归档及录像证实 press thenDragTo 发送触摸而非鼠标拖动；首次点击9秒及AX断言已通过。改用仓库已验证的 macOS click(forDuration:thenDragTo:) API，保持 seek/缩放断言；UI测试目标及严格验签通过，完整鼠标拖动用例需含新提交的隔离图形会话复验，当前本机被用户使用、远端未包含提交。按已批准环境延期，不声称实际拖动已通过。`


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
- 真实 4 小时 PCM、不同编码、定位、可见区间和资源退役的既有证据见 todo.toml 与 P1 审计；完整 App 的波形点击／拖动／缩放、双窗口重挂载、实体声音输出、设备切换、睡眠与 VoiceOver 未核销。需独占图形会话及对应设备。
- 现行行为同步 [文件编辑器](../../../docs/features/editor.md)。

