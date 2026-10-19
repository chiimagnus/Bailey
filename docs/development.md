# 本地开发

本页负责环境准备、构建、运行、安装、依赖和生成资源。工具链或入口改变时同步更新；验证见 [testing.md](testing.md)，分发见 [release.md](release.md)，证书见 [signing.md](signing.md)。

## 环境

Bailey 面向 Apple Silicon，最低 macOS 为 15.6。构建使用完整 Xcode 的 SDK、Swift 6 编译器与 SwiftUI 宏支持，不以 Command Line Tools 的存在代替完整开发环境。工程实际设置以 `Bailey.xcodeproj` 为准。

先运行 `make doctor` 查看工具链。若 `xcode-select` 指向错误位置，可对本次命令指定实际安装的 Xcode：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make doctor
```

本机构建需要有效的 Apple Development 证书，准备方式见 [signing.md](signing.md)。不用 XcodeGen，不为本项目新增 `project.yml` 或根 SwiftPM 工程。

## 构建与运行

根 [Makefile](../Makefile) 是本机和 CI 的统一入口，直接调用 `xcodebuild`：

```sh
make build
make test
make build:release
```

也可以打开 `Bailey.xcodeproj`，使用 `Bailey` scheme。App 与 `BaileyTests` 由工程和共享 scheme 关联；不创建额外 scheme、独立构建／测试 shell 脚本或启动时断言自检。

构建产物位于 `build/DerivedData/Build/Products/Debug/Bailey.app` 或 `Release/Bailey.app`，包下载位于 `build/SourcePackages/`。`make build` 同时执行严格验签。两种配置使用同一 Bundle ID，不是两套应用；不会天然隔离用户数据。

测试筛选、目录和安全启动示例统一见 [testing.md](testing.md#测试目录与入口)。不要为了查看界面直接运行会触及用户配置或会话的另一实例。

资源通过 Xcode Copy Files 打包；`ssh → bailey` 符号链接由现有 Build Phase 创建。不另建一套资源拷贝或终端安装脚本。

## 本地安装

功能代码通过测试、Debug 构建和签名检查后，默认整包更新 `/Applications/Bailey.app`，用户要求跳过时除外。纯文档改动不构建、不安装 App。

先在同一磁盘暂存完整新包并验签，再整包替换并复验。失败恢复原包；不逐文件覆盖，也不遗留旧版备份。**不退出、启动或重启用户现有 Bailey**：原进程继续使用旧代码，用户自行重启后新包生效。

安装与验收分别报告已构建、已验签、已安装、已重启和恢复检查结果；隔离实例成功不能代替正式包安装证据。

## 编辑器与工程

文件与 Diff 编辑器统一使用 Apple 原生 NSTextView + TextKit 2，不再维护旧文本控件；不为文档体系新增 LSP、格式化或 lint 配置。源文件注册、资源复制和依赖关系以 Xcode 工程为准；新增文件时核对它真实进入编译／测试路径。

测试目录采用“层次 → 业务功能”，详见 [testing.md](testing.md#测试目录与入口)。生产目录及状态所有权见 [architecture.md](architecture.md#目录)。

## 依赖与本地补丁

依赖声明在 Xcode 工程与本地包清单，解析版本在 [Package.resolved](../Bailey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。不要在别处维护第二份完整版本清单；升级时同步检查下面的必要契约和 [NOTICE](../NOTICE.md)。

### Ghostty

Xcode Package Dependencies 固定使用 `egoist-labs/libghostty-spm` 1.3.6；Swift 源码及 `GhosttyKit.xcframework` 的校验和由上游包清单管理。仓库不再维护 Ghostty submodule、本地二进制包装包或下载脚本。

首次解析须能访问 GitHub 发布资源；仅为 Shell 设置的代理不一定作用于 Xcode 的二进制下载。升级时检查 Swift API、XCFramework 版本和 SHA-256，并验证初始化、输入、重挂载及主题传播。

### 原生文件与 Diff 编辑器

Bailey 的唯一文本控件是系统 `NSTextView + TextKit 2`。
`NativeCodeTextView` 持有一份 `NSTextContentStorage` 与 `NSTextLayoutManager`，
由文件／Diff 标签保留，SwiftUI 重绘、窗口停靠与视图重挂载不重新创建正文或 Undo 栈。
不再引用、构建或维护 `Vendor/STTextView` 及其上游插件；不回退 TextKit 1，也不采用 WebKit／Electron 编辑器。

**性能的关键不变量是视图宽度与文本容器宽度一致且有限**。
不折行时同步扩大两者，避免 TextKit 2 因容器与拥有它的视图宽度不一致而沿途物化整个文档。
原生方案在 2026-10-19 当前 Mac 的 10 万行、文首插入 30 次测试中实测中位数约 1.54ms、
P95 约 1.73ms；这是原生 XCTest 宿主指标，不等于正式前台 E2E 帧延迟。
历史 STTextView 在远距跳转时累计创建大量段落；隔离研究与调用栈详见本地
`.github/features/editor-rendering-performance/evidence-p1.md`。

原生状态桥接仍必须保留以下可观察行为：组合输入的一次 Undo/Redo；
`NSTextStorage` 字符事件同步文件脏状态与增量高亮（包括撤销）；
离屏追加使用独立 Undo 事务；原生只读及辅助功能写入都拒绝修改；
Find、行号、选区和滚动可在标签重挂载后恢复。
如系统默认行为不符合这些数据／访问约束，应在拥有状态的原生编辑器层修复，
不能修改正文副本、跳过危险测试或恢复旧插件。

验收至少执行 `EditorNavigationTests`、`EditorTextInputTests`、
`SyntaxHighlightingTests`、`FileTabTests`、`DiffTabTests`、
`PaneRetentionTests`、`TextCoordinateIndexTests` 和完整 `make test`；
依赖变化还要求 Debug／Release 构建和签名。
原生迁移完成时（2026-10-19）的完整测试 **436/436、0 失败、0 跳过**，包含独立 Windows SSH 主机的实际操作；当时 Debug／Release 均完成严格签名校验。这是迁移提交的历史基线，不代表后续提交已验收；当前追加回归与环境限制记录于本地 `.github/features/editor-rendering-performance/evidence-p1.md`。没有 macOS 15.6 真机时不得写成实际验证过。

### Neon

[Vendor/Neon](../Vendor/Neon/README.md) 保留当前固定依赖的最小核心与原始许可证，以同一 package 身份替换远程 Neon，不引入第二份 parser 或队列。补丁让异步失效范围随尚未完成的编辑转换后再交付；只校验 token 版本不能补救旧坐标被当作有效的样式。

不引入未使用的旧 NSTextView／UIKit 适配，旧系统 actor／队列兼容桥由当前平台原生能力替代；不删除真实主队列约束。升级时检查上游是否已修复，运行 `SyntaxHighlightingTests` 的连续语义编辑、前方插入与最终视口着色，以及 `EditorTextInputTests`、`TextCoordinateIndexTests`、`DiffTabTests`。同时验证完整 XCTest、Debug／Release 构建和签名；不能以当前 Tree 正确代替实际颜色更新。

查询使用当前 SwiftTreeSitter 匹配序列，在后台取匹配、主线程读取谓词，读取前后都核对请求版本。正文编辑与嵌入语言查询首次就绪均推进同一个高亮交付代次，避免旧的根语言结果覆盖新片段颜色。未生效的可视范围前后配置已删除，实际请求长度由 `requestLengthLimit` 限制。未使用的同步查询模式、弃用游标及 noChange 样式叠加路径不保留；根解析仍使用原串行队列和现有同步阈值。

源码与 App 资源中的 BSD 许可证须保持一致，来源归 [NOTICE](../NOTICE.md)。

### 语法解析与 Diff

`Vendor/BaileyGrammars` 从
[`STTextView-Plugin-Neon` 的固定提交](https://github.com/krzyzanowskim/STTextView-Plugin-Neon/tree/5a30db4ce7908a5414e7b499e2379bdc49991cd1)
独立保留 Bailey 实际使用的 20 种 Tree-sitter parser 与查询，保留原许可，
不含 STTextView／插件运行时。独立 `Vendor/TreeSitterTSX` 负责 TSX；
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

应用图标由 Xcode 自带的 Icon Composer 维护，源文件位于 [`Bailey/Resources/AppIcon.icon`](../Bailey/Resources/AppIcon.icon)；浅色、深色和单色外观在同一文件中配置，由 Xcode 编译，无需手动生成 PNG。

文件图标与 Swift 查询表由 [generate-material-file-icons.ts](../scripts/generate-material-file-icons.ts) 一起生成。按脚本指定的 Material Icon Theme 版本和提交准备上游源码，使用已有 Bun 环境：

```sh
bun scripts/generate-material-file-icons.ts /path/to/vscode-material-icon-theme
```

脚本校验版本；生成前另核对上游提交。输出为 `Bailey/Resources/MaterialFileIcons/` 和 `Bailey/Editor/MaterialFileIcon.swift`，均入库，禁止手改；普通构建不会重新生成或下载图标。

更新资源后检查明暗主题、常见扩展名与未知文件图标，保留生成的许可证和来源声明。字体位于 `Bailey/Resources/Fonts/`，更换时保留相应许可；具体声明见 [NOTICE](../NOTICE.md)。

## 文档与收尾

修改本页中的命令或路径时，核对 Makefile、工程、scheme 与 workflow 的真实消费关系。没有对应入口就不能把建议写成已配置的工具。

只清理本次能够确认归属的临时产物，不动用户项目、运行任务或共享缓存。贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
