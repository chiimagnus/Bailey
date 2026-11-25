# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：实际恒定/可变帧率解码、轨道、HDR 信号、换源和退役已有证据；完整 App 原生全屏与普通标签切换通过部分云端路径；物理显示、声音输出／切换、真实睡眠与完整组合未核销。

## 任务与改动

- **P2-T1 系统轨道选择、准确播放位置与全屏恢复**：NativeMedia／NativePlayerView：实际 AVMediaSelectionGroup 与 AVPlayerItemVideoOutput，快速连续 seek 最终帧；NativeMediaFileTests 使用恒定/可变帧率 H.264、双真实音轨及 HDR。
- **P2-T2 外部更换、睡眠恢复和全链路资源收尾**：FileTab、NativeMediaEnvironmentObservation：a9b298ed 原生暂停、换源/关闭退役、睡眠唤醒与输出变化通知，阻止旧 item 恢复。

## 发现项

## 验证与未覆盖

- NativeMediaFileTests 实际 4K 10-bit HDR、双音轨、固定/可变帧率红绿像素定位、长视频末段和真实替换；100 次多格式播放开闭及换源/通知退役已通过既有宿主验收。详见 P1 审计与 todo.toml。
- 远端 6102bf3e 完整 App 视频全屏连续播放和标签切换保留位置两项通过（Actions 45448818282）。27c2b254 UI Test Target 构建及正式 Release 验签通过。
- V09 的实体音轨听感／字幕组合、V11 多屏倍率/HDR 实际呈现、物理设备切换、真实睡眠与 V12×V13 完整 App 长会话仍待具备设备与独占图形会话；不能以通知注入、解码信号或宿主 AVPlayer 对象替代。
- 最新共享构建、冻结宿主与完整 App 结果以 [文件路由审计](../file-viewer-routing/audit-p1.md) 为准；现行行为归 [文件编辑器](../../../docs/features/editor.md)。
