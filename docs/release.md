# 构建交付与发布

本页负责 Tag 发布、版本、发布包与分发流程。Makefile 或 workflow 改变时同步更新；
本机开发见 [development.md](development.md)，证书与权限见 [signing.md](signing.md)。

## 开发验收

GitHub Actions **不对 PR 或普通 `main` 提交运行构建与 XCTest**。
开发、合并及发布前按 [测试完成标准](testing.md#完成标准)在本机执行受影响测试，
阶段验收执行适用的完整回归，并记录未覆盖条件；测试未通过不能冒充已经验收。
合并前的结果由提交者负责，Tag 发布工作流不重复执行测试。

修改工程、依赖或发布路径时，提交前另运行 `make build:release`；
无开发证书的隔离环境可用 `make build:release SIGNING=adhoc`。
正式 Release 构建、版本一致性和签名检查由 Tag 发布工作流执行，
**成功发布仅证明发布包通过构建与校验，不代表测试已通过**。

## 本地打包

在已配置 [签名身份](signing.md) 的环境使用统一入口：

```sh
make package VERSION=X.Y.Z BUILD_NUMBER=N SIGNING_IDENTITY=证书SHA1 SIGNING_TEAM=团队ID
```

将参数替换成实际的三段版本、正整数构建号、证书 SHA-1 和 Team；
需要特定钥匙串时再指定 `SIGNING_KEYCHAIN`。

Makefile 校验版本、凭据和输出路径，构建 Release，通过 `ditto` 生成 ZIP，再解包复验签名、身份、
证书有效期、版本及 arm64 架构。输出为 `build/releases/bailey-X.Y.Z-macos-arm64.zip`；
已有同名包时拒绝覆盖，不在本地打包命令中发布。

## 正式发布

1. 在本机按 [完成标准](testing.md#完成标准)验收并将代码合入 `main`，
   将 App 的 Debug／Release `MARKETING_VERSION` 同步为待发布的 `X.Y.Z`。
2. 在获准发布后创建并推送 `vX.Y.Z` 标签。
   标签必须指向 `main` 中的提交，不能借文档或本地提交任务擅自推送。
3. [Release workflow](../.github/workflows/release.yml) 仅由 Tag 推送触发，使用 Xcode 27，
   核对标签提交、版本一致性及现有 Releases，拒绝重复或倒退版本，
   然后导入临时签名身份。
4. 使用 `make package` 构建和复验唯一发布包，创建对应 GitHub Release；
   构建号来自 workflow 运行编号，最后清理临时凭据。

Tag、工程版本、App 版本、Release 标题和 ZIP 文件名保持一致。
上传失败时先检查实际已有 Release 与附件，再按授权恢复，不自动重复发布。

发布工作流不提供手动触发入口，也不自动重发已有版本。
既有 Tag 的发布失败须先检查 Release 与附件状态，再单独决定恢复方案；
不能通过重复推送相同 Tag 绕过重复发布检查。

## 分发边界

当前通过 GitHub Releases 分发 Apple Silicon ZIP，更新沿 README 的下载与替换流程进行。
新增渠道或应用内更新须同步维护此页与用户入口。

用户安装入口是 [README](../README.md#安装)；
自动生成的 Release notes 不能替代功能文档与未完成验收说明。

## 维护与验证

工程 `objectVersion` 当前为 `77`。使用更新 Xcode 保存工程时确认没有升到 Runner 不识别的格式；
第三方 Action 固定完整 SHA。

本地签名包通过、真实 Actions 通过、Gatekeeper 接受和下载后首次运行是不同证据。分别记录结果和未测项；
本地脚本成功不表示 GitHub 已发布。
