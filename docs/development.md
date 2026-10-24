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
make test:FileTabPersistenceTests,NativeFileTabTests,GitStatusModelTests  # Dev 定点测试
make build:dev SIGNING=adhoc       # 独立开发版，不安装正式 App
make test SIGNING=adhoc            # Bailey Dev 宿主测试
make test:ui ONLY_TESTING=BaileyUITests/WorkspaceSmokeUITests  # 本机定点 UI 测试
make build                         # 正式版 Debug
make build:release                 # 正式版 Release
```

也可以打开 `Bailey.xcodeproj`，使用现有 `Bailey`／`Bailey-UI` scheme。Makefile 通过构建参数选择正式版或开发版，不复制 App Target、scheme 或测试脚本。

正式版产物位于 `build/DerivedData/Build/Products/{Debug,Release}/Bailey.app`；测试版位于 `build/DerivedData-Dev/Build/Products/Debug/Bailey.app`，显示名称为 **Bailey Dev**（`chiimagnus.bailey.dev`）。两者使用独立 DerivedData 和 Bundle ID，测试不替换 `/Applications/Bailey.app`。正式 Debug／Release 继续共用 `chiimagnus.bailey`；包依赖仍在 `build/SourcePackages/`。开发版配置为 `~/.config/bailey-dev/`，历史与钥匙串服务也分开。

宿主与完整 App UI 的测试边界见 [testing.md](testing.md#测试层次)。日常按受影响类定点执行；`make test:ui` 不指定 `ONLY_TESTING` 时会运行整个 UI Target，留给阶段验收及 CI。本机完整 GUI 测试应使用已安装的 **Apple Development 签名**，不要强制 `SIGNING=adhoc`：本机实测 ad-hoc Runner 被 macOS 拒绝辅助功能自动化，开发签名的同一 Runner 则能够正常操作。CI 的 ad-hoc 环境单独验收，不得拿本机结果冒充 CI。即使正式 Bailey 仍在运行，Makefile 测试也只使用 Bailey Dev；两者仍共用桌面焦点，XCUI 操作会短暂激活开发版。若需完全不打断当前输入，请使用独立图形会话。

资源通过 Xcode Copy Files 打包；`ssh → bailey` 符号链接由现有 Build Phase 创建。不另建一套资源拷贝或终端安装脚本。

## 本地安装

功能代码通过测试、Debug 构建和签名检查后，默认整包更新 `/Applications/Bailey.app`，用户要求跳过时除外。纯文档改动不构建、不安装 App。

先在同一磁盘暂存完整新包并验签，再整包替换并复验。失败恢复原包；不逐文件覆盖，也不遗留旧版备份。**不退出、启动或重启用户现有 Bailey**：原进程继续使用旧代码，用户自行重启后新包生效。

安装与验收分别报告已构建、已验签、已安装、已重启和恢复检查结果；隔离实例成功不能代替正式包安装证据。

## 编辑器与工程

文件与 Diff 编辑器统一使用 Apple 原生 NSTextView + TextKit 2，不再维护旧文本控件；不为文档体系新增 LSP、格式化或 lint 配置。源文件注册、资源复制和依赖关系以 Xcode 工程为准；新增文件时核对它真实进入编译／测试路径。

测试目录按业务领域组织：`BaileyTests/<领域>/` 为宿主测试，`BaileyUITests/<领域>/` 为完整 App UI 测试，不再在宿主内分 Unit／Integration 目录；详见 [testing.md](testing.md#测试目录与入口)。生产目录及状态所有权见 [architecture.md](architecture.md#目录)。

## 依赖与本地补丁

依赖声明在 Xcode 工程与本地包清单，解析版本在 [Package.resolved](../Bailey.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。不要在别处维护第二份完整版本清单；升级时同步检查下面的必要契约和 [NOTICE](../NOTICE.md)。

### Ghostty

Xcode Package Dependencies 固定使用 `egoist-labs/libghostty-spm` 1.3.6；Swift 源码及 `GhosttyKit.xcframework` 的校验和由上游包清单管理。仓库不再维护 Ghostty submodule、本地二进制包装包或下载脚本。

首次解析须能访问 GitHub 发布资源；仅为 Shell 设置的代理不一定作用于 Xcode 的二进制下载。升级时检查 Swift API、XCFramework 版本和 SHA-256，并验证初始化、输入、重挂载及主题传播。

### 原生文件与 Diff 编辑器

文件与 Diff 共用系统 `NSTextView + TextKit 2`，原生视图由标签保留；不再依赖 STTextView 文本控件或插件。编辑器需要保留有限且一致的视图／文本容器宽度，否则远距导航可能意外排版全文。

输入法、Undo、保存、行号、只读辅助功能及视图重挂载的契约由[编辑器文档](features/editor.md)维护；相关测试选择与完成标准见 [testing.md](testing.md)。历史性能数据、取舍和验收限制见[固定提交中的 P1 证据](https://github.com/chiimagnus/Bailey/blob/e1b9fe700424a561910c6dedb0c5653150212740/.github/features/editor-rendering-performance/evidence-p1.md)，不作为所有版本的性能承诺。依赖变化同时核对 Debug／Release 构建与签名。

### Neon

[Vendor/Neon](../Vendor/Neon/README.md) 保留当前固定依赖的最小核心与原始许可证，以同一 package 身份替换远程 Neon，不引入第二份 parser 或队列。补丁让异步失效范围随尚未完成的编辑转换后再交付；只校验 token 版本不能补救旧坐标被当作有效的样式。

不引入未使用的旧 NSTextView／UIKit 适配，旧系统 actor／队列兼容桥由当前平台原生能力替代；不删除真实主队列约束。升级时检查上游是否已修复，运行 `NativeSyntaxHighlightingTests` 的连续语义编辑、前方插入与最终视口着色，以及 `NativeEditorCompositionTests`、`NativeEditorLayoutTests`、`TextCoordinateIndexTests`、`NativeDiffTabTests`。同时验证完整 XCTest、Debug／Release 构建和签名；不能以当前 Tree 正确代替实际颜色更新。

查询使用当前 SwiftTreeSitter 匹配序列，在后台取匹配、主线程读取谓词，读取前后都核对请求版本。正文编辑与嵌入语言查询首次就绪均推进同一个高亮交付代次，避免旧的根语言结果覆盖新片段颜色。未生效的可视范围前后配置已删除，实际请求长度由 `requestLengthLimit` 限制。未使用的同步查询模式、弃用游标及 noChange 样式叠加路径不保留；根解析仍使用原串行队列和现有同步阈值。

源码与 App 资源中的 BSD 许可证须保持一致，来源归 [NOTICE](../NOTICE.md)。

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
