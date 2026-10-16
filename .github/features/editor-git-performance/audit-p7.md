# Audit P7 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p7.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P7-T1 隔离对照新旧Tree-sitter插件并判定迁移Gate
- [x] P7-T2 通过Gate后迁移官方插件并删除旧高亮依赖链

## 任务到文件的映射

- P7-T1：`build/performance/plugin-compare/upstream/Tests/STPluginTreeSitterCoreTests/KeroGateTests.swift`（仅隔离实验）、`build/performance/plugin-compare/{upstream-test,gate-debug,gate-release}.log`、`evidence-p7.md`；正式应用代码、依赖图不变。
- P7-T2：依赖 P7-T1 Gate；No-Go 后根据 `plan-p7.md` 不进行迁移，因此无生产源文件、依赖、NOTICE 或文档修改。

## 发现项

## 发现 F-02

- 任务：`P7-T1`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`build/performance/plugin-compare/upstream/Sources/STPluginTreeSitterAppKit/Coordinator.swift:37`
- 摘要：`新插件每次视口更新发起全文 reset，30 次同文档重算 Release 中位 65.22ms`
- 风险：`实际长文档滚动可能重复占用语法解析线程并延后着色；不能视为等价性能替换`
- 预期修复：`由上游在 viewport 变化时只更新受影响显示区，不全文 reset；相同窗口/语料重测热路径`
- 验证：`swift test --package-path build/performance/plugin-compare/upstream --configuration release --filter KeroGateTests`
- 解决证据：`未解决，外部上游候选 No-Go；复现与停止决定见 evidence-p7.md`


## 发现 F-01

- 任务：`P7-T1`
- 严重级别：`High`
- 状态：`Open`
- 位置：`build/performance/plugin-compare/upstream/Sources/TreeSitterResource/TreeSitterLanguage.swift:273`
- 摘要：`上游默认 TypeScript/TSX 未合并 JavaScript 与 JSX 高亮查询，隔离 XCTest 证实五条必要捕获缺失`
- 风险：`正式替换会导致核心 TypeScript/TSX 代码注释、字符串、JSX 标签和属性颜色回归`
- 预期修复：`优先由上游修复查询继承和 JSX 合并，并通过现有 Kero 的原生颜色等价测试；此前禁止接入`
- 验证：`swift test --package-path build/performance/plugin-compare/upstream --configuration release --filter KeroGateTests`
- 解决证据：`未解决，外部上游候选 No-Go；复现与停止决定见 evidence-p7.md`


以上两项均是候选上游的真实缺口，不是已经发布到 Kero 的新 Bug；Kero 仍使用既有 Neon 高亮实现。未为解决候选问题制造本地 fork。

## 修复日志

- F-01／F-02：候选上游未修复，本阶段明确不接入；Kero 正式代码保持原状。修复必须发生在上游并通过重评 Gate，不能以本地再造状态机替代。
- P7-T2：原始计划明确「Gate 不通过则不迁移」，故没有生成新插件依赖、重复包、兼容分支或多余产品提交。

## 验证日志

以下测试在 `crhllll@7f5352e` 派生隔离 worktree 中执行，并非后续代码版本的产品测试；日志原存忽略的临时 `build/`，清理 worktree 后以 `evidence-p7.md` 记载的版本、用例与结果为长期证据。

- `git fetch origin crhllll`：新工作树基于远程与本地一致的 `7f5352e`，且与原工作区未提交的 Git 测试变更隔离。
- `swift test --package-path build/performance/plugin-compare/upstream --jobs 4 --filter TreeSitterClientTests`：**PASS**；上游原有 2/2。
- `swift test --package-path build/performance/plugin-compare/upstream --jobs 4 --filter KeroGateTests`：**FAIL（预期中的验收反证）**；4 项中 2 项失败、5 条 TS/TSX 必需捕获缺失；另外 Swift／Rust／Markdown 基础解析及 30 次 reset 测试通过。
- `swift test --package-path build/performance/plugin-compare/upstream --configuration release --jobs 4 --filter KeroGateTests`：**FAIL（同一 5 条断言）**；Release 30 次全文 reset 中位／p95／最差 65.22／70.65／76.99 ms，源代码证明 viewport 路径会重新 reset。
- `xcodebuild -resolvePackageDependencies -project kero.xcodeproj -scheme kero -clonedSourcePackagesDirPath build/SourcePackages -skipPackageUpdates -disableAutomaticPackageResolution`：**PASS**。初次在独立 worktree 的包图解析卡住，是 Ghostty 二进制已有文件但 SwiftPM `workspace-state.json` 缺失 artifact 登记，导致 Xcode 再次联网。核对本地框架、上游 checksum 和 9 个远程依赖 pin 后，仅补全 worktree 的忽略缓存登记；详见 `package-resolution-fixed.log`。
- `make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`：**PASS**，15/15，0 失败（`kero-baseline-fixed.log`）。
- `make test ONLY_TESTING=KeroTests/HighlightQueryCacheTests`：**PASS**，2/2，0 失败（`kero-baseline-query-cache.log`）。
- `make test ONLY_TESTING=KeroTests/DiffTabTests`：**PASS**，19/19，0 失败（`kero-baseline-diff-tab.log`）。
- `make test ONLY_TESTING=KeroTests/EditorTextInputTests`：**PASS**，3/3，0 失败（`kero-baseline-text-input.log`）。**旧 Kero 相关原生回归合计 39/39 全部通过**，没有用上游组件两项测试替代真实编辑器和 Diff 路径验收。
- `todo validate`／`phase-complete --phase p7`：**PASS**；P7-T1 的试验结论与 P7-T2 的条件性不迁移均有证据与不提交原因。
- 现行 `docs/features/editor.md`／`docs/development.md` 与已交付产品一致，未虚构已迁移能力；历史基线、上游测试与候选源码版本见 `evidence-p7.md`。本次无产品变更，未对正式 App 声称新版本 build/test/安装通过。

## Gate（是否允许进入下一阶段）

- 结论：**No-Go（禁止将当前上游 Tree-sitter 插件接入 Kero）**
- 理由：TypeScript／TSX 基础高亮回归已被独立测试实证，且上游在视口更新时全文重算，不符合必须零用户可见退化的迁移门槛。暂停的是 P7 的替换路线，不是要删除现有工作正常的 Neon。

## 最终状态与剩余风险

- 当前状态：F-01、F-02 **Open（候选上游待修）**；P7 条件迁移已按失败 Gate 结束、无生产修改。
- 剩余风险：现有 Kero 无因 P7 引入的新回归；未来仍不能在未修复/未验证前迁移。用户当前运行的 Debug Kero 未退出、未替换，Git Diff 算法未修改。
- 允许重评时机：官方合并继承查询和 JSX 查询，避免视口触发全文解析，逐条证明 STTextView 补丁契约，并在新的候选版本上重跑 Kero 原生交互／高亮 A/B、滚动性能与 App 体积对照。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
