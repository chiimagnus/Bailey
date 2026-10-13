# 构建交付与发布

本页负责 CI、版本、发布包与分发流程。Makefile 或 workflow 改变时同步更新；本机开发见 [development.md](development.md)，证书与权限见 [signing.md](signing.md)。

## PR 检查

[CI workflow](../.github/workflows/ci.yml) 仅在面向 `main` 的 PR 上运行；普通 `main` 提交不会触发。Runner 为 `macos-26`，`DEVELOPER_DIR` 指定 Xcode 26.6。

当前 workflow 依次调用 `make test SIGNING=adhoc`、`make build:release SIGNING=adhoc`，再检查应用身份及签名。它不是完整 UI 或真实 SSH 验收，提交者仍须执行 [testing.md](testing.md#完成标准) 中与改动相关的检查。

`make test SIGNING=adhoc` 与 `make build:release SIGNING=adhoc` 都向 Xcode 传递临时签名参数。前者在 XCTest 成功后，使用 `codesign` 严格验签并确认测试宿主 `Kero.app` 和嵌入的 `KeroTests.xctest` 都实际采用 ad hoc 签名；校验失败会令 Make 失败，CI 和标签发布流程共用这一个门禁。本地 `make test` 未指定 `SIGNING` 时仍使用工程自己的 Apple Development 配置。临时签名不代表正式发布身份，本地成功也不代表 GitHub Actions 已通过。

## 本地打包

在已配置 [签名身份](signing.md) 的环境使用统一入口：

```sh
make package VERSION=X.Y.Z BUILD_NUMBER=N SIGNING_IDENTITY=证书SHA1 SIGNING_TEAM=团队ID
```

将参数替换成实际的三段版本、正整数构建号、证书 SHA-1 和 Team；需要特定钥匙串时再指定 `SIGNING_KEYCHAIN`。

Makefile 校验版本、凭据和输出路径，构建 Release，通过 `ditto` 生成 ZIP，再解包复验签名、身份、证书有效期、版本及 arm64 架构。输出为 `build/releases/kero-X.Y.Z-macos-arm64.zip`；已有同名包时拒绝覆盖，不在本地打包命令中发布。

## 正式发布

1. 通过 PR 完成相应检查并合入 `main`，将 App 的 Debug／Release `MARKETING_VERSION` 同步为待发布的 `X.Y.Z`。
2. 在获准发布后创建并推送 `vX.Y.Z` 标签。标签必须指向 `main` 中的提交，不能借文档或本地提交任务擅自推送。
3. [Release workflow](../.github/workflows/release.yml) 核对标签提交、版本一致性及现有 Releases，拒绝重复或倒退版本，重新执行测试，再导入临时签名身份。
4. 使用 `make package` 构建和复验唯一发布包，创建对应 GitHub Release；构建号来自 workflow 运行编号，最后清理临时凭据。

Tag、工程版本、App 版本、Release 标题和 ZIP 文件名保持一致。上传失败时先检查实际已有 Release 与附件，再按授权恢复，不自动重复发布。

## 分发边界

当前通过 GitHub Releases 分发 Apple Silicon ZIP，更新沿 README 的下载与替换流程进行。新增渠道或应用内更新须同步维护此页与用户入口。

用户安装入口是 [README](../README.md#安装)；自动生成的 Release notes 不能替代功能文档与未完成验收说明。

## 维护与验证

工程 `objectVersion` 当前为 `77`。使用更新 Xcode 保存工程时确认没有升到 Runner 不识别的格式；第三方 Action 固定完整 SHA。

本地签名包通过、真实 Actions 通过、Gatekeeper 接受和下载后首次运行是不同证据。分别记录结果和未测项；本地脚本成功不表示 GitHub 已发布。
