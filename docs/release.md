# 构建交付与发布

本页负责 CI、版本、发布包与分发流程。Makefile 或 workflow 改变时同步更新；本机开发见 [development.md](development.md)，证书与权限见 [signing.md](signing.md)。

## PR 检查

[CI workflow](../.github/workflows/ci.yml) 仅在面向 `main` 的 PR 上运行。纯 Markdown、`docs/`、`.github/features/`、`.github/ISSUE_TEMPLATE/` 或 `LICENSE` 的独立 PR 会跳过；如果历史 PR 差异包含代码，即使本次只改文档，事件仍可能触发 CI。普通 `main` 提交不触发；版本 Tag 发布不受此过滤影响。Draft PR 的创建、推送和打标签会跳过 CI Job，切换为 Ready for review 后自动运行；重新设为 Draft 会取消同一 PR 的在途检查。Runner 和 Xcode 版本以 CI workflow 为准。

**日常增量检查**：`synchronize` 事件比较本次推送前后的 PR Head 提交，不重复把整份长期 PR 与 `main` 的所有历史差异当作新修改。仅改某个 XCTest 文件时运行该类；编辑器源码改动覆盖原生编辑器、Diff、输入法、文件标签、语法高亮、窗口保留等交叉测试；Diff 源码改动执行关联套件；不受支持的变更范围、缺失/改写的提交历史、工程或 CI 配置修改则运行全量。仅新增文档时检查差异，不运行无关 XCTest。所有实际执行的 XCTest 仍通过同一个 `make test SIGNING=adhoc`，并对 App 与测试 Bundle 做严格 ad hoc 验签，不另写测试执行器。

**合并前的完整检查不可省略**：非 Draft PR 首次打开、重新打开、由草稿转为可审查状态会跑全部 XCTest；正式准备合并时，在最新提交上给 PR 添加 `ci/full` 标签（已有标签则移除后重新添加），以 `labeled` 事件重新触发全量测试，核对对应 Head SHA 的绿色运行记录。只凭增量 CI 通过不得宣称整份 PR 已完整验收；Release workflow 继续在 Tag 阶段执行全量测试。若配置必需 CI 检查，应确保文档变更和显式跳过仍有预期状态，不制造永久 Pending。`AppIdentityTests` 继续负责验证宿主身份，CI 不等于完整 App 图形 E2E 或真实用户 SSH 验收；详见 [testing.md](testing.md#完成标准)。

PR 不再额外编译 Release，也不重复进行 YAML 中的验签；正式 Release 编译、版本和签名检查仍由标签触发的发布流程执行。**PR 通过不等于 Release 构建通过**：修改工程、依赖或发布路径时，提交前另运行 `make build:release`；无开发证书的隔离环境可用 `make build:release SIGNING=adhoc`。本地 `make test` 未指定 `SIGNING` 时使用工程自己的 Apple Development 配置；临时签名不代表正式发布身份，本地成功也不代表 GitHub Actions 已通过。

## 本地打包

在已配置 [签名身份](signing.md) 的环境使用统一入口：

```sh
make package VERSION=X.Y.Z BUILD_NUMBER=N SIGNING_IDENTITY=证书SHA1 SIGNING_TEAM=团队ID
```

将参数替换成实际的三段版本、正整数构建号、证书 SHA-1 和 Team；需要特定钥匙串时再指定 `SIGNING_KEYCHAIN`。

Makefile 校验版本、凭据和输出路径，构建 Release，通过 `ditto` 生成 ZIP，再解包复验签名、身份、证书有效期、版本及 arm64 架构。输出为 `build/releases/bailey-X.Y.Z-macos-arm64.zip`；已有同名包时拒绝覆盖，不在本地打包命令中发布。

## 正式发布

1. 通过 PR 完成相应检查并合入 `main`，将 App 的 Debug／Release `MARKETING_VERSION` 同步为待发布的 `X.Y.Z`。
2. 在获准发布后创建并推送 `vX.Y.Z` 标签。标签必须指向 `main` 中的提交，不能借文档或本地提交任务擅自推送。
3. [Release workflow](../.github/workflows/release.yml) 核对标签提交、版本一致性及现有 Releases，拒绝重复或倒退版本，重新执行测试，再导入临时签名身份。
4. 使用 `make package` 构建和复验唯一发布包，创建对应 GitHub Release；构建号来自 workflow 运行编号，最后清理临时凭据。

Tag、工程版本、App 版本、Release 标题和 ZIP 文件名保持一致。上传失败时先检查实际已有 Release 与附件，再按授权恢复，不自动重复发布。

已有版本可手动运行 `Release` 工作流，输入现有 `vX.Y.Z` Tag：它会在 GitHub Runner 上重新执行测试、导入签名身份、构建并复验 ZIP，但**不会再次创建或覆盖 GitHub Release**。正式 Tag 推送仍保留重复版本拦截。

## 分发边界

当前通过 GitHub Releases 分发 Apple Silicon ZIP，更新沿 README 的下载与替换流程进行。新增渠道或应用内更新须同步维护此页与用户入口。

用户安装入口是 [README](../README.md#安装)；自动生成的 Release notes 不能替代功能文档与未完成验收说明。

## 维护与验证

工程 `objectVersion` 当前为 `77`。使用更新 Xcode 保存工程时确认没有升到 Runner 不识别的格式；第三方 Action 固定完整 SHA。

本地签名包通过、真实 Actions 通过、Gatekeeper 接受和下载后首次运行是不同证据。分别记录结果和未测项；本地脚本成功不表示 GitHub 已发布。
