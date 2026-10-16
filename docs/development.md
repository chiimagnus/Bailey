# 本地开发

本页负责环境准备、构建、运行、安装、依赖和生成资源。工具链或入口改变时同步更新；验证见 [testing.md](testing.md)，分发见 [release.md](release.md)，证书见 [signing.md](signing.md)。

## 环境

Kero 面向 Apple Silicon，最低 macOS 为 15.6。构建使用完整 Xcode 的 SDK、Swift 6 编译器与 SwiftUI 宏支持，不以 Command Line Tools 的存在代替完整开发环境。工程实际设置以 `kero.xcodeproj` 为准。

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

也可以打开 `kero.xcodeproj`，使用 `kero` scheme。App 与 `KeroTests` 由工程和共享 scheme 关联；不创建额外 scheme、独立构建／测试 shell 脚本或启动时断言自检。

构建产物位于 `build/DerivedData/Build/Products/Debug/Kero.app` 或 `Release/Kero.app`，包下载位于 `build/SourcePackages/`。`make build` 同时执行严格验签。两种配置使用同一 Bundle ID，不是两套应用；不会天然隔离用户数据。

测试筛选、目录和安全启动示例统一见 [testing.md](testing.md#测试目录与入口)。不要为了查看界面直接运行会触及用户配置或会话的另一实例。

资源通过 Xcode Copy Files 打包；`ssh → kero` 符号链接由现有 Build Phase 创建。不另建一套资源拷贝或终端安装脚本。

## 本地安装

功能代码通过测试、Debug 构建和签名检查后，默认整包更新 `/Applications/Kero.app`，用户要求跳过时除外。纯文档改动不构建、不安装 App。

先在同一磁盘暂存完整新包并验签，再整包替换并复验。失败恢复原包；不逐文件覆盖，也不遗留旧版备份。**不退出、启动或重启用户现有 Kero**：原进程继续使用旧代码，用户自行重启后新包生效。

安装与验收分别报告已构建、已验签、已安装、已重启和恢复检查结果；隔离实例成功不能代替正式包安装证据。

## 编辑器与工程

编辑器由开发者选择，不为文档体系新增 LSP、格式化或 lint 配置。源文件注册、资源复制和依赖关系以 Xcode 工程为准；新增文件时核对它真实进入编译／测试路径。

测试目录采用“层次 → 业务功能”，详见 [testing.md](testing.md#测试目录与入口)。生产目录及状态所有权见 [architecture.md](architecture.md#目录)。

## 依赖与本地补丁

依赖声明在 Xcode 工程与本地包清单，解析版本在 [Package.resolved](../kero.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)。不要在别处维护第二份完整版本清单；升级时同步检查下面的必要契约和 [NOTICE](../NOTICE.md)。

### Ghostty

Xcode Package Dependencies 固定使用 `egoist-labs/libghostty-spm` 1.3.6；Swift 源码及 `GhosttyKit.xcframework` 的校验和由上游包清单管理。仓库不再维护 Ghostty submodule、本地二进制包装包或下载脚本。

首次解析须能访问 GitHub 发布资源；仅为 Shell 设置的代理不一定作用于 Xcode 的二进制下载。升级时检查 Swift API、XCFramework 版本和 SHA-256，并验证初始化、输入、重挂载及主题传播。

### STTextView

`Vendor/STTextView` 是基于 2.3.11 的本地副本，用于保留仍需维护的修复，不用上游 changelog 代替副本版本证据。

| 修复 | 必须保持的行为 |
| --- | --- |
| 行号 | 字体或颜色变化后忽略已脱离视图的旧布局片段 |
| 横向滚动 | 按最大内容宽度计算范围，不因末行较短截断长行 |
| 短文档点击 | 文档高度至少覆盖视口，最后一行下方仍可聚焦 |
| 空范围高亮 | 空范围不加临时属性，避免 TextKit 崩溃 |
| Diff 固定行高 | 双栏只读文档高度准确，滚动范围一致 |
| 只读替换 | 展开上下文或重载只读文本时保留滚动，普通编辑仍跟随插入点 |
| 辅助功能只读 | 值／选中文本替换遵守原生 isEditable，文件与 Diff 共用底层保护 |
| 组合输入 | 结束标记保留已输入正文；最终输入按组合范围替换，默认／显式范围和普通撤销不删字或重复插入 |

补丁集中在 [STTextView+Gutter.swift](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Gutter.swift)、[STTextView.swift](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView.swift)、[STTextView+Accessibility.swift](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+Accessibility.swift)、[STTextView+NSTextInputClient.swift](../Vendor/STTextView/Sources/STTextViewAppKit/STTextView+NSTextInputClient.swift) 和 [STTextLayoutManager.swift](../Vendor/STTextView/Sources/STTextViewCommon/STTextLayoutManager.swift)。Kero 自己的裁切、内边距和字体初始化由 [SourceTextEditor.swift](../kero/Editor/SourceTextEditor.swift) 负责，不归入上游补丁。

升级时逐项检查上游是否已修复，删除不再需要的补丁，保留许可证和署名。运行 `FileTabTests`、`DiffTabTests`、`EditorTextInputTests` 并检查字体变化、组合输入、长行、短文档、Markdown、高亮空范围、固定行高和只读替换滚动。全部修复被上游覆盖后才考虑撤销副本，不以升级成功替代功能验收。

### Neon

[Vendor/Neon](../Vendor/Neon/README.md) 保留当前固定依赖的最小核心与原始许可证，以同一 package 身份替换远程 Neon，不引入第二份 parser 或队列。补丁让异步失效范围随尚未完成的编辑转换后再交付；只校验 token 版本不能补救旧坐标被当作有效的样式。

不引入未使用的旧 NSTextView／UIKit 适配，旧系统 actor／队列兼容桥由当前平台原生能力替代；不删除真实主队列约束。升级时检查上游是否已修复，运行 `SyntaxHighlightingTests` 的连续语义编辑、前方插入与最终视口着色，以及 `EditorTextInputTests`、`TextCoordinateIndexTests`、`DiffTabTests`。同时验证完整 XCTest、Debug／Release 构建和签名；不能以当前 Tree 正确代替实际颜色更新。

查询使用当前 SwiftTreeSitter 匹配序列，在后台取匹配、主线程读取谓词，读取前后都核对请求版本。未使用的同步查询模式、弃用游标及 noChange 样式叠加路径不保留；根解析仍使用原串行队列和现有同步阈值。

源码与 App 资源中的 BSD 许可证须保持一致，来源归 [NOTICE](../NOTICE.md)。

### 语法解析与 Diff

Kero 只使用 `STTextView-Plugin-Neon` 中的语法、查询和默认配色资源；插件桥接及颜色字典由 Kero 自己持有，不再调用上游的插件适配、Theme／Fonts／TokenName 包装。上游包清单仍依赖 Neon，但 SwiftPM 实际只解析一份 `Vendor/Neon` 核心，不是两套运行时。该包没有单独的资源产品，彻底去包需要另行接管语法资源，不能只删除包引用而丢失语言支持。

TSX 使用独立解析器，不能用普通 TypeScript 替代。`Vendor/TreeSitterTSX` 的来源是 `STTextView-Plugin-Neon` 固定提交 `5a30db4ce7908a5414e7b499e2379bdc49991cd1`，与工程依赖匹配。升级时从目标提交的 `Sources/TreeSitterTSX/` 更新 `include/` 和 `src/`，并核对插件查询与工程所用运行库的兼容性，不把查询或运行库一并复制进本地解析器包。

高亮查询由插件提供，Kero 合并 TypeScript 与 JSX 查询，不复制一份手工查询。更新后检查 TypeScript、TSX 元素／属性／表达式及 Markdown／HTML 嵌入语言。

Diff 复用现有 STTextView/TextKit 与语法依赖，不引入 PierreDiffsSwift 或 WebKit 渲染；约束见 [diff.md](features/diff.md)。

## 生成资源

文件图标与 Swift 查询表由 [generate-material-file-icons.ts](../scripts/generate-material-file-icons.ts) 一起生成。按脚本指定的 Material Icon Theme 版本和提交准备上游源码，使用已有 Bun 环境：

```sh
bun scripts/generate-material-file-icons.ts /path/to/vscode-material-icon-theme
```

脚本校验版本；生成前另核对上游提交。输出为 `kero/Resources/MaterialFileIcons/` 和 `kero/Editor/MaterialFileIcon.swift`，均入库，禁止手改；普通构建不会重新生成或下载图标。

更新资源后检查明暗主题、常见扩展名与未知文件图标，保留生成的许可证和来源声明。字体位于 `kero/Resources/Fonts/`，更换时保留相应许可；具体声明见 [NOTICE](../NOTICE.md)。

## 文档与收尾

修改本页中的命令或路径时，核对 Makefile、工程、scheme 与 workflow 的真实消费关系。没有对应入口就不能把建议写成已配置的工具。

只清理本次能够确认归属的临时产物，不动用户项目、运行任务或共享缓存。贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
