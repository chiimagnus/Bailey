# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：读取、资源、媒体与模式归属的共享实现已接入七格式，实际跨格式数据和生命周期回归通过；完整设备／GUI／Linux SSH 矩阵尚未核销。

## 任务与改动

- **P1-T1 核销读取与公共资源边界，移除新格式产生的重复路径**：FileTab.readContent、NativeMedia.open、PreviewResource、LocalPathScope、RasterPreview、SVGArtwork 共用原文件／资源版本校验及安全边界；Windows SSH 与本机实际目标隔离，媒体不整读或跨机器降级。
- **P1-T2 让下一种预览复用同一展示模式、Dock 和系统菜单**：FilePreviewMode、DockItem.filePreview、Project、FileViewerView、系统 File 菜单及 TabContentThumbnail 已统一；CSV、SVG、HTML 与 Markdown 共用源码／预览／并排所有权。提交 49a9e09d、24019b00。

## 发现项

## 验证与未覆盖

- R02/R03/R04/R06/R07/R10：实际 FinderDeliveryIntegrationTests、FileTabPersistenceTests、MarkdownResourceScopeTests、SessionStoreTests、Git 和 SSH 文件测试覆盖投递、窗口／项目身份、特殊路径、真实文件类型、草稿与原字节、重命名、断线／恢复和取消。实际 Windows Tailscale 授权；未取得获授权 Linux 主机，不能声称 POSIX 远端 E2E 完成。
- R05/R11：32 MiB 文本与 256 MiB／3200 万像素图片边界；9a7d6835 解决 PNG／普通 TIFF 区域解码，24 MP 区域逐点一致、251 项回归、9286 次边界与 10060 次 ASan/UBSan。bc97976c 真实四小时 WAV（1,382,400,044 字节）与两小时 MP4（7200 秒）实际定位、解码和原文件校验和。容量、性能和特殊 TIFF 的退化边界见图片、媒体 audit。
- R08/R09：原生七格式百次切换、双窗口快照重新创建应用所有者、真实 PNG 三入口版本刷新、SVG 三入口安全像素、独立／嵌入媒体 AX 按钮与独立播放器（d5698ca3、8c6b63b1）；退役后实际资源和暂存文件核对。AVKit 私有控制器留有暂停且无 currentItem 的空壳，不将此写成所有对象零残留。
- R01/R08/R09/R11 的真实 1× 显示器、物理触控板、VoiceOver 播报、减弱动态效果及完整 App 多窗口长会话仍未完成。当前用户使用图形会话，不以抢占桌面或宿主视图替代独立 App；需相应设备与独占 Dev 图形会话。Linux SSH 的授权、实际设备／完整 App 交叉组合阻塞阶段门禁；分格式证据见其 audit。macOS 27.3／Xcode 27.2、Apple Silicon；按用户确认不要求 15.6 实机，部署目标保留。
- 初次全量 make test 到 1102 通过、1 失败、3 条件跳过后在 SSH 容量用例处超时；1064762f 修正 Git worktree 真实 FSEvents 路径、5 项定点通过，9ce6bad8 修正 .build 标记并用独立 APFS 卷补过全部 3 项。剩余 291 项带真实 SSH 和样本变量完整命令退出 0（零失败／跳过）；不同提交的分段证据不能冒充最终 HEAD 单次全量通过。
- 当前行为文档归 [文件编辑器](../../../docs/features/editor.md)；Git 监听修复同步 [文件管理](../../../docs/features/files.md)。
- 最终受影响回归（e4267d71）：`make test ONLY_TESTING` 选定 FileTabPersistence、FileTree、GitStatusModel、HTMLFilePreview、MarkdownResourceScope、NativeAudioTiming、NativeMediaFile、NativePaneRetentionIntegration 八类共 330 项；启用真实样本和 Windows SSH，实际 329 通过、1 JPEG 长测条件跳过、0 失败，退出 0。启用 JPEG 长测开关定点补测通过，退出 0；按测试身份合计 330/330 通过。初次中断全量、291 项剩余补跑、长媒体定点及本次回归按测试身份去重得到 1359 个最新通过结果；这是跨提交分段证据，不是最终 HEAD 单次全量通过。临时 APFS 测试镜像已卸载清理。日志 `/tmp/bailey-final-affected-20261124.log`、`/tmp/bailey-final-jpeg-boundaries-20261124.log`。
- 最终 e4267d71：正式 `make build` 与 `make build:release` 顺序执行，完整命令退出 0；Debug／Release 再次 `codesign --verify --deep --strict` 通过；Release 精简重新签名后约 56 MiB（du -h）。构建日志 `/tmp/bailey-final-debug-20261124.log`、`/tmp/bailey-final-release-20261124.log`。未替换用户已安装 App。
