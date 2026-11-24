# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：No-Go
- **依据**：静态 WebKit 与共享授权资源链已通过任务级验证；共用模式、真实窗口的已测路径通过，完整 H08 设备／无障碍与远端组合缺失。

## 任务与改动

- **P1-T1 建立一条安全 HTML 静态渲染与共用资源链**：HTMLFilePreview、PreviewResource、FileTab 的原始文本与版本链；真实 WebContent 异常退出和取消恢复，资源逐级按请求者路径授权，禁用脚本、主动内容和外部导航。
- **P1-T2 复用已有 File 菜单、标签右键及 Dock 预览**：复用 FilePreviewMode、FileViewerView、DockItem 和 File 菜单；源码原有 TextKit 查找、预览原生选取与复制。既有真实双窗、后台右键、前台快捷键及并排验收见 f7feb109、b9a8a571。

## 发现项

## 验证与未覆盖

- H01/H02：HTMLFilePreviewTests 中实际 WebKit 的默认源码、BOM/GBK/空页、32 MiB 边界的真实尾部像素／超限、综合样本样式与图片通过；源文本未改。
- H03/H04/H05：e5b9f939 实际 srcdoc、object/embed、javascript、Blob、下载、HTTP/HTTPS、外部字体、image-set 均零外连／脚本／导航，监听端有正对照；中文及 #/?/% 合法资源实际可见，query、FIFO、越界符号链接及伪 CSS 拒绝。嵌套 CSS、导入循环、精确资源预算、嵌套字体及图片像素已验证；46426dd8 的复选／单选 Red→Green，保留只读文本选择复制。
- H06/H07：独立页面所有者、跨窗口同图版本刷新（0e479782）、慢资源取消、真实 WebContent 退出恢复、坏 PNG 三入口拒绝与恢复、项目外路径及文件移走，实际 WebKit 快照和原始文件字节通过。
- 14 项 HTMLFilePreviewTests 与 5 项 MarkdownResourceScopeTests 在完整测试前段全部通过，包括获授权 Windows SSH（65.6 秒）；H08 的宿主百次挂载、实际窗口恢复证据与此前隔离 GUI 双窗路径通过。不把宿主 AX 和快照当成实际 VoiceOver 播报或完整 App 冷启动长会话。
- 仍未验证真实 1× 屏、VoiceOver、物理触控板／相关减弱动态效果和完整 App 多窗口长会话；需独立图形会话及设备。没有获授权 Linux SSH，需补实际 POSIX 资源路径和断线／重连。上述必要组合阻塞 P1；P1-T1 已核销不等于阶段通过。
- 文档归 [文件编辑器](../../../docs/features/editor.md)，无新增独立写入模型；本轮未进入 P2。
- 最终 e4267d71：14 项 HTMLFilePreviewTests、5 项 MarkdownResourceScopeTests、28 项 NativePaneRetentionIntegrationTests 全部通过；真实 Windows SSH 本轮再次通过。共享记录见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
- 最终 e4267d71：正式 Debug／Release 构建和精简后严格签名均通过，详见 [文件路由 P1 审计](../file-viewer-routing/audit-p1.md)。
