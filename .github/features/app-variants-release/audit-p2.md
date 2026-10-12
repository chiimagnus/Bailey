# Audit P2 - app-variants-release

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/app-variants-release/`
- 粒度：`phase`

## 任务看板

- [x] P2-T1 免费证书发包、预检与文档

## 任务到文件的映射

- P2-T1
  - `.github/workflows/ci.yml`、`release.yml`
  - `scripts/build-app.sh`、`release-app.sh`、`release-preflight.sh`、`check-release.sh`、`check.sh`
  - `docs/RELEASE.md`、README、AGENTS

## 发现项

无阻塞发现。签名构建、证书和团队验证、ZIP 解包再验证、GitHub 预检门禁及 always 清理已沿执行流核对。

## 修复日志

- 验证阶段修正 Bash 3.2 空数组、codesign 可选参数等号及 runner context 的作用域；修正后重跑相应真实构建与 actionlint。

## 验证日志

- /bin/bash -n 四个发布脚本 -> PASS。
- Ruby YAML 解析、校验 SHA-256 后的 actionlint 1.7.12 -> PASS。
- check.sh release -> PASS：正常标签、tag SHA、main 归属、最新精确 SHA CI、错误 SHA/branch、接口失败、重复及数值版本顺序、缺少和不存在的签名身份。
- build-app dev/stable adhoc -> PASS，build/ci-{dev,stable}-local.log；workspace-identity 原生检查 -> PASS。
- 十组独立行为检查 -> PASS，build/ci-independent-local.log，包含真实受控 LFS 接收端。
- release-app stable/dev 0.1.48 54 -> PASS，真实 Apple Development 签名、证书指纹/有效性/团队、ZIP 解包验证。
- verify-release-archives.py -> PASS：两包 ID/版本、ssh 相对链接保留；资源篡改后 strict verify 拒绝。
- SIGNING_TEAM=AAAAAAAAAA release-app -> 正确拒绝，未生成错误团队 ZIP；恢复标准构建 -> PASS。
- spctl --assess 正式安装包 -> rejected / exit 3，符合已文档化的免费签名边界，不是免弹窗通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：本地实现和验证完整；该 Gate 不表示远端已配置或已发布。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：未获凭据外传/推送授权，没有上传 Secrets、push 或真实 GitHub run；本机用 Xcode 27，官方 runner 的 Xcode 26.6 尚未实跑。免费开发证书不能公证，无法保证 Gatekeeper 放行。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

