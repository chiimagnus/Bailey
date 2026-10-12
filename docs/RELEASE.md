# 构建与发包

日常使用选 Kero，开发和测试选 Kero Dev。两者可同时安装，但设置和工作区独立；名称、身份与数据目录见[设置与恢复](SETTINGS.md)。只提供 Apple Silicon（arm64）包，需要 macOS 15.6+，没有自动更新。

## 本机构建

```sh
bash scripts/build-app.sh stable
bash scripts/build-app.sh dev
```

分别输出 `build/DerivedData/Build/Products/Release/Kero.app` 和 `build/DerivedData/Build/Products/Debug/Kero Dev.app`。默认使用本机 Apple Development 证书；其他团队按 [AGENTS](../AGENTS.md#构建) 调整。CI 使用 `adhoc` 模式，不接触证书私钥，也不产出公开发布包。

## 配置签名

仅使用免费账号可取得的 Apple Development 证书。证书须有效且带私钥；在钥匙串访问中导出为带密码的 `.p12`，只导出这一身份，不上传整个钥匙串。在 GitHub 仓库 Actions Secrets 配置：

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPMENT_P12_BASE64` | `.p12` 的 Base64 内容 |
| `APPLE_DEVELOPMENT_P12_PASSWORD` | 导出密码，不能为空 |
| `APPLE_DEVELOPMENT_IDENTITY` | 有效签名身份的 40 位大写 SHA-1 |
| `APPLE_DEVELOPMENT_TEAM` | 证书所属的 10 位 Team ID |

用 `security find-identity -v -p codesigning` 查有效身份。签名者姓名后括号不一定是 Team ID；用已签名包的 `codesign -dv --verbose=4 路径` 核对 `TeamIdentifier`。默认本地团队是 `RDQHYSDFFG`。私钥与导出包不入库，不在日志中打印；导出、上传或更换凭据须经所有者授权。

Release 在临时钥匙串导入身份，并在成功或失败时清理。缺少凭据、证书过期、签名身份或团队不一致都会停止，不降级成未签名或 ad hoc 发布。

## 发布版本

1. 把待发布提交推到 `main`，等待该提交的 CI 成功。
2. 在该提交创建并推送严格的 `vX.Y.Z` 标签，例如 `v0.1.49`。标签必须属于 `main`，但不必始终等于最新 HEAD；已有或低于已发布版本的标签不能发布。
3. Release workflow 使用标签指定版本，以运行编号作为构建号，分别构建两种应用。校验 Bundle ID、名称、版本、arm64、有效证书指纹和团队，打 ZIP 后再解包校验签名。两份都成功才创建 GitHub Release。

发布资产为 `kero-X.Y.Z-macos-arm64.zip` 与 `kero-dev-X.Y.Z-macos-arm64.zip`。workflow 固定 macOS 26 ARM64 与 Xcode 26.6，第三方 Action 固定完整 SHA；升级时核对官方 runner 与 Action。公开 CI 不读取私钥，发布只在标签触发。

本地验收可设置 `SIGNING_IDENTITY`、`SIGNING_TEAM`，运行 `bash scripts/release-app.sh stable 0.1.49 55`（开发版用 `dev`）。输出到 `build/releases/`，不会推送或发布，拒绝覆盖已有同名 ZIP。发布上传失败需人工核对已有 Release 和资产，不自动重发或删除。

修改发布流程后运行 `bash scripts/check.sh release`，检查标签、main 归属、精确提交 CI、接口失败、重复和倒退版本及缺少签名凭据；它使用受控 GitHub 响应，不执行推送或发布。再验收真实签名 ZIP 的解包结果；本地通过不能代替一次获准的远端 Actions 运行。

## 免费签名的限制

Apple Development 签名可校验签名者与包完整性，但不是面向公众分发的 Developer ID。Apple [公证服务](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)不接受 Apple Development 证书，因此本流程不能公证，也不能保证从 GitHub 下载后直接打开或免除 Gatekeeper 提醒。用户操作统一见 [首次打开被拦截时](../README.md#首次打开被拦截时)；workflow 会在 Release 说明顶部提示限制并链接到该版本的操作说明。

验收须分别记录 `codesign --verify --deep --strict` 的完整性结果、`spctl --assess --type execute --verbose=4` 的 Gatekeeper 结果，以及真实下载包的首次打开结果。后两项未通过或未测时明确说明，不能把签名有效、本地构建或静态 workflow 检查当作 Gatekeeper 放行或远端 CI/CD 成功。开发签名包被 Gatekeeper 拒绝时保留检查结果并告知上述操作，不因此降级签名或关闭安全检查。

发布包不预先清理下载隔离标记；用户确认信任后，可执行 README 中的命令，先校验签名、Apple 证书链和团队，再仅清理指定应用的 `com.apple.quarantine`。不提供额外首次打开脚本，不关闭全局 Gatekeeper、不清空其他属性，也不把其他证书冒充免费方案。应用内部权限仍由 macOS 单独管理。
