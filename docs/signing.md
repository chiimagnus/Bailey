# 签名

本页维护签名身份、证书、构建权限和验证边界。相关配置改变时同步更新；
发布动作见 [release.md](release.md)，本地安装见 [development.md](development.md#本地安装)。

## 当前身份

正式 Bailey 的 Debug 和 Release 保持 `Bailey.app`／`chiimagnus.bailey`，可执行文件名为 `bailey`。
`make build:dev` 和 XCTest 使用另一 Bundle ID `chiimagnus.bailey.dev`，
构建在 `build/DerivedData-Dev/`，不作为发布包。工程使用 Apple Development 手动签名，
当前 Team ID 为 `RDQHYSDFFG`；开发版可用 `SIGNING=adhoc`，发布仍需所有者获授权的有效证书，
不共享维护者私钥。

```sh
security find-identity -v -p codesigning
```

这里显示的身份 SHA-1 用于明确指定证书；Team 由证书与工程配置匹配。
不能从证书名称或某次本地构建成功推断发布环境同样具备身份。

## 本机构建与校验

`make build` 构建 Debug 并执行 `codesign --verify --deep --strict`。
`SIGNING=adhoc` 是 Makefile 的临时签名选项，不等于 Apple Development 签名；
发布不能静默退回临时或未签名产物。

App 的 Debug／Release 配置当前启用 Hardened Runtime，关闭 App Sandbox，
entitlements 由 [bailey.entitlements](../Bailey/Resources/bailey.entitlements) 定义。
不要照搬另一个 App 的权限；增加受保护资源时同时核对用途文案、实际授权路径和构建权限。

签名完整性、证书身份、Gatekeeper 接受和公证不是同一个结果。
Bailey 的现有发布流程没有公证步骤，不能因严格验签通过就宣称产物已公证。

## 发布凭据

发布 workflow 从仓库 Actions Secrets 读取：

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPMENT_P12_BASE64` | 证书与私钥 `.p12` 的 Base64 |
| `APPLE_DEVELOPMENT_P12_PASSWORD` | 非空导出密码 |
| `APPLE_DEVELOPMENT_IDENTITY` | 有效身份的 40 位大写 SHA-1 |
| `APPLE_DEVELOPMENT_TEAM` | 对应的 10 位 Team ID |

未经所有者授权不导出或上传私钥。真实 `.p12`、密码和凭据不入库、不写日志；
缺少、过期或不匹配时停止发布。

workflow 使用临时钥匙串，结束时删除临时签名材料并恢复钥匙串列表。
本地包验证由 `make package` 执行，检查证书有效期、SHA-1、Team、Bundle ID、版本与架构；
再对 ZIP 解包产物重复验签，见 [release.md](release.md#本地打包)。

## 下载隔离属性

从 [GitHub Releases](https://github.com/chiimagnus/Bailey/releases) 下载后，先确认来源可信。
若 macOS 阻止首次打开，可在「系统设置 → 隐私与安全性」中选择允许打开该 App。

如果仍需手动移除下载隔离标记，**仅对已确认可信的 Bailey** 执行：

```sh
xattr -dr com.apple.quarantine "/Applications/Bailey.app"
open "/Applications/Bailey.app"
```

不要关闭系统级安全检查。Bailey 当前没有公证流程，代码签名验证通过不代表 Gatekeeper 一定放行。

## 验证记录

分别报告构建、嵌套签名完整性、证书身份、打包后复验、Gatekeeper 和首次打开的实际结果。
没有远端运行或真实首次启动证据时，明确保留未验收项，不能以本地检查替代。
