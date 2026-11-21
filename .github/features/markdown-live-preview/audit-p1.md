# P1｜阶段审查

审查对象：[P1 实施计划](plan-p1.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：Go
- **依据**：应用内的双向切换及主菜单可用性已有实测；文本读取、原生正文及保存路径保持唯一。
  并排、实时合并、SVG 和其它富内容由 P2 交付，不将 P1 结果扩展到这些能力。

## 任务与改动

- **P1-T1**：`df21403`。`MarkdownDocument` 以 Foundation 结构保留文档正文，Yams 提取文首；
  `MarkdownResource` 和 `MarkdownImageLoader` 都不使用默认网络读取。
  `FileTab.imageThumbnail` 合并像素校验，未删除原读取限额及真实图片头验证。
- **P1-T2**：`597df61`。`FileViewerView` 在现有 `.text` 分支挂载只读视图，
  `WorkspaceWindowModel.markdownPreviewTarget` 解析实际目标；File 菜单唯一注册 ⌘⇧V。
  Save 移到同一菜单，不另建命令；源码视图移除前的失焦不会写文件。

## 发现项

## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`BaileyTests/App/AppIdentityTests.swift:233`
- 摘要：`菜单契约宿主测试仍要求 Save 位于 Edit`
- 风险：`旧测试让完整宿主验收失败，且没有保护 File 菜单顺序或唯一预览快捷键`
- 预期修复：`验收实际 NSMenu 的 Open、Preview、Save 顺序和两个快捷键的唯一性，保留 Diff 原契约`
- 验证：`make test:AppIdentityTests,MarkdownPreviewTests SIGNING=adhoc`
- 解决证据：`06386f893d8b04d592cd37eaf922edde1dcea8e7；make test:AppIdentityTests,MarkdownPreviewTests SIGNING=adhoc 退出 0，35 项通过。`


## 验证与未覆盖

- macOS 27.3 arm64、Xcode 27.2。定点宿主组 10 项，以及 Markdown／原生内容身份组 19 项通过；
  包括真实 PNG、符号链接、编码路径、受控 SSH、Load 状态、跨后缀重命名及不写入脏稿。
  500／5,000／20,000 段解析约 0.02／0.21／0.87 秒；这不是完整 SwiftUI 布局指标。
- `make test:ui ONLY_TESTING=BaileyUITests/MarkdownPreviewUITests` 退出 0，1 项执行。
  实测普通文件禁用、MDX 动态启用、两次 ⌘⇧V、原生标题、磁盘无写入及 Undo 原值恢复。
  初次未等待系统菜单／未明确测试语言，不能作为有效 Red；补齐夹具后完成真实验证。
- 最低系统 15.6 无本机实例；部署目标不变，SDK 可用性由构建检查，仍需在 15.6 真机跑同样命令。
  实际 SSH／Windows 无专用获授权夹具，只有本机 shell 驱动的 SSH 命令验证，
  不代表远端传输或 MSYS2 实测。两窗、极限大小的实际布局、VoiceOver 和实体中文 IME
  尚未验收；原生保留行为有宿主身份和输入测试，P2 仍须补实机和容量验证。
- 现行编辑器、依赖文档与 P1 改动同步；没有 FileKind、Registry 或重复的文件读取分发。

