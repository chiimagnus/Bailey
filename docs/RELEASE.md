# 构建与发包

本页供维护者构建、签名和发布应用。修改 `Makefile` 或 workflow 时同步更新；用户安装说明见 [README](../README.md#安装)。

## 本机构建

Kero 只有一个应用身份：`Kero.app` / `chiimagnus.kero`。Debug 与 Release 只是构建配置，不是两套应用。

```sh
make build
make test
make build:release
```

`Makefile` 直接调用 Xcode 原生 `xcodebuild`。CI 仅由面向 `main` 的 PR 触发，执行 `make test SIGNING=adhoc` 和 `make build:release SIGNING=adhoc`，不需要开发证书；普通 `main` 提交不会运行 CI。

产物分别位于 `build/DerivedData/Build/Products/Debug/Kero.app` 与 `Release/Kero.app`。本机构建需要 Apple Development 证书，团队设置见 [AGENTS](../AGENTS.md#构建)。CI 使用临时签名，不读取私钥。

## 配置签名

将有效的 Apple Development 证书及私钥导出为带密码的 `.p12`，在仓库 Actions Secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPMENT_P12_BASE64` | `.p12` 的 Base64 内容 |
| `APPLE_DEVELOPMENT_P12_PASSWORD` | 导出密码，不能为空 |
| `APPLE_DEVELOPMENT_IDENTITY` | 有效签名身份的 40 位大写 SHA-1 |
| `APPLE_DEVELOPMENT_TEAM` | 证书所属的 10 位 Team ID |

用 `security find-identity -v -p codesigning` 查 SHA-1；Team ID 取已签名包详情中的 `TeamIdentifier`。未经所有者授权不导出或上传私钥；`.p12`、密码不入库、不写日志。

Release 使用临时钥匙串，结束后清理。缺少凭据、证书过期或签名不匹配时停止，不降级为未签名或临时签名包。

## 发布版本

1. 通过 PR 完成 CI，合并到 `main`。发布前把 Xcode 项目中 Kero App 的 Debug、Release `MARKETING_VERSION` 都设为准备发布的 `X.Y.Z`。
2. 在 `main` 中的待发布提交创建并推送 `vX.Y.Z` 标签，例如 `v0.1.49`。只有版本 Tag 会触发 Release；Tag 必须与工程版本一致，重复或倒退版本会被拒绝。
3. Release 在标签对应的提交重新执行 `make test SIGNING=adhoc`；通过后构建唯一的 Release `Kero.app`，校验 Bundle ID、版本、架构和证书，打包后再解包复验签名，通过后创建 Release。

发布包为 `kero-X.Y.Z-macos-arm64.zip`：Tag、工程版本、App 版本、Release 标题和 ZIP 文件名使用同一版本；构建号取 workflow 运行编号。上传失败时人工核对已有 Release 和资产，不自动重发。

## 验证与维护

原生测试按 [AGENTS](../AGENTS.md#验证) 运行。设置 `SIGNING_IDENTITY` 和 `SIGNING_TEAM` 后，使用 `make package VERSION=0.1.49 BUILD_NUMBER=55` 验收本地签名包；输出到 `build/releases/`，不会发布，拒绝覆盖同名 ZIP。需要指定钥匙串时设置 `SIGNING_KEYCHAIN`。

- CI/Release 使用 Xcode 26.6；工程文件格式保持 `objectVersion = 77`。用更新版 Xcode 修改工程后须确认格式未升到 Runner 无法识别的 `110`；Action 固定完整 SHA。
- 分别记录测试、签名完整性、真实 Actions 运行、Gatekeeper 检查和下载包首次打开的结果。本地检查不能代替远端或首次打开验收。
