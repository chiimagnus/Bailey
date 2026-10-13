# 签名

本页维护签名身份、证书、构建权限和验证边界。相关配置改变时同步更新；发布动作见 [release.md](release.md)，本地安装见 [development.md](development.md#本地安装)。

## 当前身份

Kero 的 Debug 和 Release 都使用唯一的 `Kero.app`／`chiimagnus.kero`，可执行文件名为 `kero`。工程使用 Apple Development 手动签名，当前 Team ID 为 `RDQHYSDFFG`；构建者须选择自己确实有权使用且有效的证书，不共享维护者私钥。

```sh
security find-identity -v -p codesigning
```

这里显示的身份 SHA-1 用于明确指定证书；Team 由证书与工程配置匹配。不能从证书名称或某次本地构建成功推断发布环境同样具备身份。

## 本机构建与校验

`make build` 构建 Debug 并执行 `codesign --verify --deep --strict`。`SIGNING=adhoc` 是 Makefile 的临时签名选项，不等于 Apple Development 签名；发布不能静默退回临时或未签名产物。

App 的 Debug／Release 配置当前启用 Hardened Runtime，关闭 App Sandbox，entitlements 由 [kero.entitlements](../kero/Resources/kero.entitlements) 定义。不要照搬另一个 App 的权限；增加受保护资源时同时核对用途文案、实际授权路径和构建权限。

签名完整性、证书身份、Gatekeeper 接受和公证不是同一个结果。Kero 的现有发布流程没有公证步骤，不能因严格验签通过就宣称产物已公证。

## 发布凭据

发布 workflow 从仓库 Actions Secrets 读取：

| Secret | 内容 |
| --- | --- |
| `APPLE_DEVELOPMENT_P12_BASE64` | 证书与私钥 `.p12` 的 Base64 |
| `APPLE_DEVELOPMENT_P12_PASSWORD` | 非空导出密码 |
| `APPLE_DEVELOPMENT_IDENTITY` | 有效身份的 40 位大写 SHA-1 |
| `APPLE_DEVELOPMENT_TEAM` | 对应的 10 位 Team ID |

未经所有者授权不导出或上传私钥。真实 `.p12`、密码和凭据不入库、不写日志；缺少、过期或不匹配时停止发布。

workflow 使用临时钥匙串，结束时删除临时签名材料并恢复钥匙串列表。本地包验证由 `make package` 执行，检查证书有效期、SHA-1、Team、Bundle ID、版本与架构；再对 ZIP 解包产物重复验签，见 [release.md](release.md#本地打包)。

## 下载隔离属性

下载后的首次运行与构建签名分别验收。直接下载者应先确认来自维护者发布的包；系统拦截时再按 [README](../README.md#安装) 对单个已确认可信的 App 处理，不关闭系统整体安全检查。

## 验证记录

分别报告构建、嵌套签名完整性、证书身份、打包后复验、Gatekeeper 和首次打开的实际结果。没有远端运行或真实首次启动证据时，明确保留未验收项，不能以本地检查替代。
