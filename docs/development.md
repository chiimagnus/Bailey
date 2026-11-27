# 本地开发

本页负责环境准备、构建、运行与安装。工具链或入口改变时同步更新；
验证见 [testing.md](testing.md)，分发见 [release.md](release.md)，证书见 [signing.md](signing.md)。

## 环境

Bailey 面向 Apple Silicon，最低 macOS 为 15.6。
构建使用完整 Xcode 的 SDK、Swift 6 编译器与 SwiftUI 宏支持，
不以 Command Line Tools 的存在代替完整开发环境。工程实际设置以 `Bailey.xcodeproj` 为准。

先运行 `make doctor` 查看工具链。若 `xcode-select` 指向错误位置，可对本次命令指定实际安装的 Xcode：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make doctor
```

本机构建需要有效的 Apple Development 证书，准备方式见 [signing.md](signing.md)。
不用 XcodeGen，不为本项目新增 `project.yml` 或根 SwiftPM 工程。

## 构建与运行

根 [Makefile](../Makefile) 是本机构建／测试与 Tag 发布打包的统一入口，直接调用 `xcodebuild`：

```sh
make build:dev SIGNING=adhoc       # 独立开发版，不安装正式 App
make build                         # 正式版 Debug
make build:release                 # 正式版 Release
```

也可以打开 `Bailey.xcodeproj`，使用现有 `Bailey`／`Bailey-UI` scheme。
Makefile 通过构建参数选择正式版或开发版，不复制 App Target、scheme 或测试脚本。
直接在 Xcode 中运行 scheme 不会自动带入 Makefile 的开发版参数；
需要隔离的 Bailey Dev 时，应使用 `make build:dev` 生成的开发版 App。

正式版产物位于 `.build/DerivedData/Build/Products/{Debug,Release}/Bailey.app`；
测试版位于 `.build/DerivedData-Dev/Build/Products/{Debug,Release}/Bailey Dev.app`（默认 Debug），
App 包名、菜单栏和 Dock 名称均为 **Bailey Dev**（`chiimagnus.bailey.dev`）。
两者使用独立 DerivedData 和 Bundle ID，
测试不替换 `/Applications/Bailey.app`。正式 Debug／Release 继续共用 `chiimagnus.bailey`；
包依赖仍在 `.build/SourcePackages/`。持久化路径见[设置](features/settings.md#隔离与关联数据)。

`make build:release` 关闭覆盖率插桩、启用未使用代码剔除，
并在构建后使用 `strip -x` 移除本地符号、仅保留公式渲染实际使用的 Latin Modern 字体。
精简后使用原构建签名的证书重新签名并严格验签；Debug 和测试包保持原样。
App 外的 dSYM 由[发布打包](release.md#本地打包)单独保存。
没有开发证书时，隔离的非 GUI 构建检查可用 `make build:release SIGNING=adhoc`；
不作为正式签名或 GUI 验收的证据。

测试入口见 [testing.md](testing.md#测试目录与入口)，隔离与 GUI 签名见 [testing-environment.md](testing-environment.md)。

资源通过 Xcode Copy Files 打包；`ssh → bailey` 符号链接由现有 Build Phase 创建。
不另建一套资源拷贝或终端安装脚本。

## 本地安装

功能代码通过测试、Debug 构建和签名检查后，默认整包更新 `/Applications/Bailey.app`，
用户要求跳过时除外。纯文档改动不构建、不安装 App。

先在同一磁盘暂存完整新包并验签，再整包替换并复验。失败恢复原包；不逐文件覆盖，也不遗留旧版备份。
**不退出、启动或重启用户现有 Bailey**：原进程继续使用旧代码，用户自行重启后新包生效。

安装与验收分别报告已构建、已验签、已安装、已重启和恢复检查结果；隔离实例成功不能代替正式包安装证据。

## 工程

Xcode 工程负责源文件注册、依赖和资源复制；新增文件时核对实际编译／测试路径。
生产目录见 [architecture.md](architecture.md#目录)，测试目录见 [testing.md](testing.md#测试目录与入口)。

依赖升级、本地补丁及资源生成见 [dependencies.md](dependencies.md)。

## 文档与收尾

修改本页中的命令或路径时，核对 Makefile、工程、scheme 与 workflow 的真实消费关系。
没有对应入口就不能把建议写成已配置的工具。

只清理本次能够确认归属的临时产物，不动用户项目、运行任务或共享缓存。
贡献流程见 [CONTRIBUTING.md](../CONTRIBUTING.md)。
