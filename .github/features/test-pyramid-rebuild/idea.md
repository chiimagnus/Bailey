# Bailey 测试精简

## 目标

**只区分宿主测试与完整 App UI 测试**，不再维持 Unit／Integration 的目录、Target 或数量比例。

| 类别 | 路径 | 负责什么 |
| --- | --- | --- |
| 宿主 XCTest | `BaileyTests/<领域>/` | 纯逻辑、模型、真实 Git／文件／SSH、最小 AppKit／TextKit／IME／PTY 组件与异常组合 |
| 完整 App UI E2E | `BaileyUITests/<领域>/` | 宿主无法证明的系统菜单、真实点击／键盘焦点、选择器、跨窗路由与用户结果 |

**P2 的首选动作是尽可能把现有 UI E2E 的断言转交宿主，而不只是减少 UI 点击。** 可直接实例化生产 `NSAlert`，挂载必要的原生组件，使用真实临时 Git／文件和内存后端核对实际结果；仅在确实需要系统菜单、前台焦点、跨窗口、系统选择器／拖放或完整 App 重启时保留 E2E。不能因原测试位于 `BaileyUITests` 就默认它必须留在 UI。

## 范围

1. **统一宿主目录**：`BaileyTests/Unit/<领域>/` 与 `BaileyTests/Integration/<领域>/` 合并为 `BaileyTests/<领域>/`。保留所有测试断言、真实外部系统验证、fixture 和现有 Test Target。
2. **统一开发文档**：`docs/testing.md` 是唯一详细规则；AGENTS、开发／贡献规范、PR 模板及现行 Feature 计划引用它。历史审计保留当时证据，不改写。
3. **尽可能移交 UI E2E 给宿主**：当前源码基线为 Git Dialog 21、Graph／Geometry 45、其它 Git 24、Files／Editor／共享树 24、Workspace 19，合计 133 项 UI 方法。逐项拆解原断言、确认宿主覆盖缺口并实际补测；只有独有完整 App 接线必须继续在 UI 运行。对应系统行为已由另一条 UI 证明时，删除整条冗余 UI 用例及专用 helper，不仅缩减点击次数。

## 不做

不新增 Target、协议、Fake Git 或测试宿主 App，不为调整 Unit/Integration 比例而搬测试；不改业务语义、UI/UX、CI 全量策略或正式 `/Applications/Bailey.app`，不操作用户仓库及未授权 SSH。

## 完成标准

- 47 个宿主 Swift 文件内容字节不变，旧两层目录删除，Xcode 测试发现数不减少，受影响宿主 XCTest 实测通过。
- P2 为每条原 UI 用例记录原断言、宿主替代（已有或新增）、仍需的完整用户入口与实际执行证据；先转交可独立验证的内容，再删掉被完整替代的 UI 测试。宿主可自行证明整个行为时无需额外保留一条 UI；只有跨 App 的独有行为才必须保留真实 E2E。
- 本地按类定点运行 `make test:类名1,类名2`，真正需要完整 App 时才用 `make test:ui ONLY_TESTING=...`；核对 Xcode 实际发现、执行方法数、退出码及最终数据。记录 UI 方法与实际完整 App 启动／重复操作的前后变化，不以固定减少比例牺牲安全。阶段和 CI 全量策略、签名及 Bailey Dev 隔离均不变。
- 无法执行的 macOS 15.6、专用 SSH、实体触控板、中文 IME 和显示组合分别说明原因、影响与补验，不冒充已测。
