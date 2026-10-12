# P2：免费证书签名与 GitHub Actions

## P2-T1 免费证书发包、预检与文档

复用 prepare-ghostty、Xcode 和检查脚本。build-app.sh 选择两种构建，release-app.sh 验证证书签名、团队、版本和解包签名后生成 ZIP。ci.yml 在 main/PR 上做两种 ad hoc 构建与检查，不访问私钥。release.yml 对 vX.Y.Z 校验 main 归属、精确 SHA CI、已有 Release，然后导入临时钥匙串并生成两包，全部验证后才发布，always 清理私钥和钥匙串。

官方 API 核对 action SHA 与 runner/Xcode；本地验证 shell 语法、actionlint、失败路径、真实签名及 ZIP 解包，spctl 证据明确 Gatekeeper 边界。README 放安装说明，docs/RELEASE.md 放 Secrets、证书和维护约束，AGENTS 链接导航。

实现和本地验证不依赖外部授权。私钥上传、push、真实 Actions 运行须另获授权；否则记录远端未生效，不虚构验收。

## 阶段审计

完成后按 plan-task-auditor 创建 audit-p2.md，核对 Secrets、精确 SHA 门禁、重复发布与包签名。Go 只表示本地交付通过，远端证据单列。
