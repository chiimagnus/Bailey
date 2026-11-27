# 依赖与资源维护

维护第三方依赖、必要本地补丁及生成资源；版本或资源来源改变时更新。
构建见 [development.md](development.md)，来源和许可证见 [第三方来源与许可证](#第三方来源与许可证)。

## 依赖与本地补丁

依赖声明在 Xcode 工程与本地包清单，解析版本以 [Package.resolved](../Bailey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。
不要在别处维护第二份完整版本清单；升级依赖或重新生成资源时同步核对必要契约与许可证索引，
保留原有许可证、版权和署名，不翻译、覆盖或删减许可证原文。

### Ghostty

Xcode Package Dependencies 固定使用 `egoist-labs/libghostty-spm` 1.3.6；
Swift 源码及 `GhosttyKit.xcframework` 的校验和由上游包清单管理。
仓库不再维护 Ghostty submodule、本地二进制包装包或下载脚本。

首次解析须能访问 GitHub 发布资源；仅为 Shell 设置的代理不一定作用于 Xcode 的二进制下载。
升级时检查 Swift API、XCFramework 版本和 SHA-256，并验证初始化、输入、重挂载及主题传播。

系统原生文本与 Diff 控件不依赖旧 STTextView；行为及验收见[文本编辑器](features/editor.md)和[Diff](features/diff.md)。

### Markdown 原生预览

Apple `swift-markdown`（经 `swift-cmark` 使用 cmark-gfm）仅负责解析 Markdown；
阅读 UI 由 Bailey 自己的 SwiftUI 组件渲染，不使用 Textual、MarkdownView 或 WebKit。
代码围栏复用现有 Tree-sitter 高亮；公式使用公开的 SwiftUIMath Canvas 排版 API，不使用私有 SPI。
Release 字体精简遵循[构建入口](development.md#构建与运行)。
资源范围见[文件查看](features/file-viewer.md#预览资源权限)，Markdown 富内容见[阅读预览](features/markdown-preview.md)。
### SVG 与栅格解码

SVG 共用 [本地 SwiftDraw](../Vendor/SwiftDraw/README.md)；版本、许可证及小数倍率图案补丁见对应包。
[Vendor/RasterRegions](../Vendor/RasterRegions/README.md) 固定 libpng 和 LibTIFF 的源码与许可，
仅负责版本化栅格数据的原像素区域提取。Xcode 通过本地 SwiftPM 包编译，压缩依赖仅为 SDK zlib，
不依赖 Homebrew 或额外安装；更新依赖时同时执行原像素专项、Debug／Release 构建及验签。

### Markdown HTML 源码映射

块 HTML 复用 [本地 SwiftSoup](../Vendor/SwiftSoup/README.md) 的分词和节点原文区间；
补丁只负责保留并公开文字和实体的字节位置，不替换 HTML 解析规则。

### Neon

[Vendor/Neon](../Vendor/Neon/README.md) 保留当前固定依赖的最小核心与原始许可证，
以同一 package 身份替换远程 Neon，不引入第二份 parser 或队列。
补丁让异步失效范围随尚未完成的编辑转换后再交付；只校验 token 版本不能补救旧坐标被当作有效的样式。

不引入未使用的旧 NSTextView／UIKit 适配，旧系统 actor／队列兼容桥由当前平台原生能力替代；
不删除真实主队列约束。
升级时检查上游是否已修复，运行 `NativeSyntaxHighlightingTests` 的连续语义编辑、
前方插入与最终视口着色，以及 `NativeEditorCompositionTests`、`NativeEditorLayoutTests`、
`TextCoordinateIndexTests`、`NativeDiffTabTests`。同时验证完整 XCTest、Debug／Release 构建和签名；
不能以当前 Tree 正确代替实际颜色更新。

查询使用当前 SwiftTreeSitter 匹配序列，在后台取匹配、主线程读取谓词，读取前后都核对请求版本。
正文编辑与嵌入语言查询首次就绪均推进同一个高亮交付代次，避免旧的根语言结果覆盖新片段颜色。
未生效的可视范围前后配置已删除，实际请求长度由 `requestLengthLimit` 限制。
未使用的同步查询模式、弃用游标及 noChange 样式叠加路径不保留；根解析仍使用原串行队列和现有同步阈值。

源码与 App 资源中的 BSD 许可证须保持一致。

### 语法解析与 Diff

`Vendor/BaileyGrammars` 从
[`STTextView-Plugin-Neon` 的固定提交](https://github.com/krzyzanowskim/STTextView-Plugin-Neon/tree/5a30db4ce7908a5414e7b499e2379bdc49991cd1)
独立保留 Bailey 实际使用的 20 种 Tree-sitter parser，以及 25 份实际读取的
高亮／JSX／嵌入语言查询；不再打包旧插件未使用的 tags、locals 等查询。
保留原许可，不含 STTextView／插件运行时。独立 `Vendor/TreeSitterTSX` 负责 TSX；
不能用普通 TypeScript grammar 代替，因为它不解析 JSX。
语法查询沿用 JavaScript／JSX 与 TypeScript、C 与 C++ 的继承合并，以及 Markdown／HTML 嵌入语言。

Neon 的默认配色是原生资源目录
[`NeonThemes.xcassets`](../Bailey/Resources/NeonThemes.xcassets)，不再通过插件资源 bundle 定位；
`SyntaxHighlightCoordinator` 只对原生 TextKit 2 渲染属性着色，不写入正文与 Undo。
资源迁移必须保持亮／暗外观颜色一致，并核对保存、快速编辑、重命名切换语法及 Diff 着色。

此前对 `STTextView-Plugin-TreeSitter` 的 2026-10-16 对照表明，它当时不能保留
TypeScript／JSX 基础着色及增量视口查询，因此仍使用 Neon 解析核心。
该结论只涉及高亮引擎，不代表重新引入 STTextView 文本控件。
Diff 共享系统 NSTextView/TextKit 2；不使用 WebKit 或另一个文本渲染器。
详见 [Diff 功能契约](features/diff.md)。

## 生成资源

应用图标由 Xcode 自带的 Icon Composer 维护，
源文件位于 [`Bailey/Resources/AppIcon.icon`](../Bailey/Resources/AppIcon.icon)；
浅色、深色和单色外观在同一文件中配置，由 Xcode 编译，无需手动生成 PNG。

文件图标与 Swift 查询表
由 [generate-material-file-icons.ts](../scripts/generate-material-file-icons.ts)
一起生成，仅打包最终查询表引用的图标及其浅色变体。按脚本指定的 Material Icon Theme 版本和提交准备上游源码，使用已有 Bun 环境：

```sh
bun scripts/generate-material-file-icons.ts /path/to/vscode-material-icon-theme
```

脚本校验版本；生成前另核对上游提交。
输出为 `Bailey/Resources/MaterialFileIcons/` 和 `Bailey/Editor/MaterialFileIcon.swift`，均入库，
禁止手改；普通构建不会重新生成或下载图标。

更新资源后检查明暗主题、常见扩展名与未知文件图标，保留生成的许可证和来源声明。
字体位于 `Bailey/Resources/Fonts/`，更换时保留相应许可。

## 第三方来源与许可证

以下索引列出仓库现有的第三方来源与许可，不替代许可证原文，也不代表完整的依赖许可审计。

| 组件 | 来源与许可证 |
| --- | --- |
| STTextView 原生行号索引 | [原许可证与署名](../Bailey/Resources/Licenses/LICENSE-sttextview-source.txt) |
| Tree-sitter 语法资源 | [来源与固定版本](../Vendor/BaileyGrammars/README.md) · [MIT](../Vendor/BaileyGrammars/LICENSE) |
| Neon | [来源与本地补丁](../Vendor/Neon/README.md) · [BSD](../Vendor/Neon/LICENSE) · [App 内许可证](../Bailey/Resources/Licenses/LICENSE-neon.txt) |
| Material Icon Theme | [来源与固定提交](../Bailey/Resources/MaterialFileIcons/NOTICE-material-icon-theme.txt) · [许可证原文](../Bailey/Resources/MaterialFileIcons/LICENSE-material-icon-theme.txt) |
| JetBrains Mono | [OFL](../Bailey/Resources/Fonts/OFL.txt) |
| Nerd Fonts | [许可证原文](../Bailey/Resources/Fonts/LICENSE-nerd-fonts.txt) |
| Ghostty / Swift packages | [Package.resolved](../Bailey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) · 许可证随上游源码维护 |
| Tree-sitter TSX | [来源与固定提交](#语法解析与-diff) |
| swift-markdown | [源码](https://github.com/swiftlang/swift-markdown) · [Apache-2.0](../Bailey/Resources/Licenses/LICENSE-swift-markdown.txt) |
| swift-cmark (cmark-gfm) | [源码](https://github.com/swiftlang/swift-cmark) · [许可证原文](../Bailey/Resources/Licenses/LICENSE-swift-cmark.txt) |
| SwiftSoup | [来源与本地补丁](../Vendor/SwiftSoup/README.md) · [MIT](../Bailey/Resources/Licenses/LICENSE-swiftsoup.txt) |
| Yams | [源码](https://github.com/jpsim/Yams) · [MIT](../Bailey/Resources/Licenses/LICENSE-yams.txt) |
| SwiftDraw | [来源与本地补丁](../Vendor/SwiftDraw/README.md) · [zlib](../Bailey/Resources/Licenses/LICENSE-swiftdraw.txt) |
| MermaidKit | [源码](https://github.com/2389-research/MermaidKit) · [MIT](../Bailey/Resources/Licenses/LICENSE-mermaidkit.txt) |
| RasterRegions（libpng／LibTIFF；LZW 代码源自加州大学伯克利分校） | [来源与固定版本](../Vendor/RasterRegions/README.md) · [libpng](../Bailey/Resources/Licenses/LICENSE-libpng.txt) · [LibTIFF](../Bailey/Resources/Licenses/LICENSE-libtiff.txt) |
| SwiftUIMath | [源码](https://github.com/gonzalezreal/swiftui-math) · [MIT](../Bailey/Resources/Licenses/LICENSE-swiftui-math.txt) |
