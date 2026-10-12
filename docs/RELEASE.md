# 构建与发包

本页供维护者构建、签名和发布应用。修改相关脚本或 workflow 时同步更新；用户安装说明见 [README](../README.md#安装)。

## 本机构建

```sh
bash scripts/build-app.sh stable
bash scripts/build-app.sh dev
```

产物位于 `build/DerivedData/Build/Products/`：

| 构建 | 应用包 | 用途 |
| --- | --- | --- |
| `stable` | `Release/Kero.app` | 正式发布 |
| `dev` | `Debug/Kero Dev.app` | 本地开发，不发 Release |

本机构建需要 Apple Development 证书，团队设置见 [AGENTS](../AGENTS.md#构建)。CI 检查两种应用，使用临时签名（`adhoc`），不读取私钥。

## 配置签名

将有效的 Apple Development 证书及私钥导出为带密码的 `.p12`，在仓库 Actions Secrets 中配置：

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPMENT_P12_BASE64` | `.p12` 的 Base64 内容 |
| `APPLE_DEVELOPMENT_P12_PASSWORD` | 导出密码，不能为空 |
| `APPLE_DEVELOPMENT_IDENTITY` | 有效签名身份的 40 位大写 SHA-1 |
| `APPLE_DEVELOPMENT_TEAM` | 证书所属的 10 位 Team ID |

用 `security find-identity -v -p codesigning` 查 SHA-1；Team ID 取已签名包详情中的 `TeamIdentifier`，不要取签名者姓名后的括号。未经所有者授权不导出或上传私钥；`.p12`、密码不入库、不写日志。

Release 使用临时钥匙串，结束后清理。缺少凭据、证书过期或签名不匹配时停止，不降级为未签名或临时签名包。

## 发布版本

1. 把待发布提交推到 `main`，等待该提交的 CI 成功。
2. 在该提交创建并推送 `vX.Y.Z` 标签，例如 `v0.1.49`。提交须属于 `main`；重复或倒退版本会被拒绝。
3. workflow 只构建正式版，校验身份、版本、架构和证书，打包后再解包验证签名，通过后创建 Release。

发布包为 `kero-X.Y.Z-macos-arm64.zip`：版本取标签，构建号取 workflow 运行编号。上传失败时人工核对已有 Release 和资产，不自动重发。

## 验证与维护

修改后运行 `bash scripts/check.sh release`。设置 `SIGNING_IDENTITY` 和 `SIGNING_TEAM` 后，可用 `bash scripts/release-app.sh stable 0.1.49 55` 验收本地签名包；输出到 `build/releases/`，不会发布，拒绝覆盖同名 ZIP。

- 升级 runner、Xcode 或 Action 时核对官方配置；Action 固定完整 SHA。
- 分别记录签名完整性、真实 Actions 运行、Gatekeeper 检查和下载包首次打开的结果。本地检查不能代替远端或首次打开验收。
