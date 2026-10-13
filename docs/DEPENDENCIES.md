# 依赖与生成资源

本文负责 Kero 自有补丁、依赖来源和生成边界。升级依赖、调整补丁或重新生成资源时同步更新。
上游文档、许可证和署名保留原样，不随中文文档整理迁移或翻译。

## Ghostty

Ghostty 通过 Xcode Package Dependencies 直接引用 [`egoist-labs/libghostty-spm`](https://github.com/egoist-labs/libghostty-spm) 的 `1.3.6` 固定版本。
其 Swift 源码与校验和受上游 `Package.swift` 管理，Xcode 自动下载 `GhosttyKit.xcframework`，不再维护 Git submodule、本地二进制包装包或下载脚本。
升级时核对上游 Swift API、XCFramework 版本及 SHA-256，并验证终端初始化、输入和主题切换。
首次下载需保证 Xcode 能访问 GitHub 发布资源；只为 Shell 配置的代理不一定对 SwiftPM 二进制下载生效。

## STTextView

本地副本位于 `Vendor/STTextView`，基于上游 `2.3.11`。
保留副本是为了携带尚需维护的源码修复，不用上游变更日志推断副本版本。

当前修复覆盖六项行为：

- **行号**：字体或颜色变化后，排除已脱离视图的旧布局片段，避免行号错位。
- **横向滚动**：按已布局内容的最大宽度计算文档范围，避免末行较短时无法滚到长行尾部。
- **短文档点击**：文档高度至少覆盖视口，使最后一行下方的点击仍可聚焦编辑器。
- **空范围高亮**：跳过空文本范围上的临时属性，避免打开 Markdown 时触发 TextKit 崩溃。
- **Diff 固定行高**：为双栏只读 Diff 提供准确的文档高度，避免 TextKit 懒布局让左右列的滚动范围不一致。
- **只读替换不追光标**：Diff 展开上下文或重载只读文本时保留滚动位置，普通编辑器仍追随插入点。

这些修复集中在三个文件：
[行号](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Gutter.swift)、
[文档尺寸](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView.swift)、
[高亮属性](../Vendor/STTextView/Sources/STTextViewCommon/STTextLayoutManager.swift)。
视图裁切、内边距和字体初始化由 [Kero 的编辑器集成](../kero/Editor/SourceTextEditor.swift)负责，不是上游补丁。

升级副本时：

1. 对照新上游版本检查这些根因，已修复的补丁不再重复应用。
2. 比较源码差异，确认只保留必要修复，许可证和署名不丢失。
3. 构建后在真机检查字体变化后的行号、末行较短的长行、短文档下方点击和 Markdown 高亮。

全部问题被上游解决后，可撤销本地副本并改用固定版本的远程依赖；仍须运行上述验收。

## 原生 Git Diff

Git Diff 复用应用现有的 STTextView/TextKit 与语法解析依赖，**不再需要 PierreDiffsSwift 或 WKWebView**。`kero/Git/DiffEngine.swift` 计算行级与行内差异；`DiffSyntaxHighlighter.swift` 使用编辑器同一语法与主题；`DiffTextView.swift` 绘制行号、增删颜色和折叠上下文。`DiffNativeSurface.swift` 由 `DiffTab` 保留唯一原生视图，SwiftUI 重挂载不替换编辑缓冲区、撤销栈或滚动位置。

升级 STTextView 时除编辑器自身四项补丁外，必须检查固定行高和只读文档替换时的滚动行为，并运行 `make test ONLY_TESTING=KeroTests/DiffTabTests`（源码位于 `KeroTests/NativeUI/DiffTabTests.swift`），验证真实渲染、统一/分栏、编辑、撤销、保存与重新挂载。

## TSX 语法

`.tsx` 使用独立的 TSX 解析器，不能用普通 TypeScript 解析器替代。
`Vendor/TreeSitterTSX` 将解析器作为本地 Swift 包提供，因为当前高亮插件的公开产品没有导出它。

解析器来自 `STTextView-Plugin-Neon` 的固定提交 `5a30db4ce7908a5414e7b499e2379bdc49991cd1`，与工程依赖一致。
更新时从同一提交重新复制 `Sources/TreeSitterTSX/` 的 `include/` 和 `src/`，保持解析器、查询和运行库匹配。
高亮查询由插件提供，Kero 合并 TypeScript 与 JSX 查询，不另存一份查询副本。
更新后检查普通 TypeScript、TSX 元素、属性与嵌入表达式的高亮。

## 文件图标与字体

文件图标和 Swift 查询表由 [`generate-material-file-icons.ts`](../scripts/generate-material-file-icons.ts) 一起生成，不手改输出。
按脚本指定的 Material Icon Theme 版本与提交准备上游源码，在其依赖可用后，从 Kero 根目录运行：

```sh
bun scripts/generate-material-file-icons.ts /path/to/vscode-material-icon-theme
```

脚本验证版本，重新生成前另行核对上游提交。输出为 `kero/Resources/MaterialFileIcons/` 与 `kero/Editor/MaterialFileIcon.swift`，均入库；普通构建不下载或生成图标。
重新生成后检查明暗主题、常见扩展名和未知文件的图标，并保留输出中的许可证与来源说明。

内置字体位于 `kero/Resources/Fonts/`。替换字体或图标时核对各自的许可证和署名，不改写许可原文。
