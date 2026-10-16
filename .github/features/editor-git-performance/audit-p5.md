# Audit P5 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p5.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P5-T1 归因原生 Diff 完整流水线
- [x] P5-T2 修复共享 LF／CRLF 分行契约
- [x] P5-T3 收敛读取身份、错误与加载收尾
- [x] P5-T4 接入实测选中的原生性能措施

## 任务到文件的映射

- **P5-T1（本地实验，不提交）**：`Project.openDiff/openHistoricalDiff` → `DiffTab.reload/recomputeDisplay` → `DiffEngine/DiffSyntaxHighlighter` → `DiffNativeSurface/DiffTextView`；临时 `DiffPipelinePerformanceTests.swift` 只在测试期间挂载，最终源码与日志归忽略的 `build/performance/diff/`，永久项目中已删除。
- **P5-T2（`cae2cf6`）**：`kero/Git/DiffEngine.swift` 的唯一 `DiffLineSplitter` LF 标量扫描；`KeroTests/Unit/Git/DiffEngineTests.swift` 原始字节、Unicode 与 UTF-16 回归；`KeroTests/NativeUI/Git/DiffTabTests.swift` 原生 CRLF review/edit/undo/save；`docs/features/diff.md`。
- **P5-T3（`b87f360`）**：`DiffViewerView.swift` 的原有 `DiffTab.reload`、`GitLocation/gitObject/gitContent`、加载失败保留与旧 fold 身份，`Project.swift` 的历史标签重用；`DiffTabTests`、`GitHistoryFileTests`、`GitExecutionTests`、`WorkspaceIdentityTests`；`docs/features/diff.md`。
- **P5-T4（`0644d34`）**：`DiffTab.recomputeDisplay` 原有后台闭包中使用两侧 `async let`，无新 executor、缓存、渲染表面；`DiffTabTests`、`SyntaxHighlightingTests`、`EditorTextInputTests` 加交错 30 次 capture 等价及实际原生 30 次 A/B 的临时证据；`docs/features/diff.md`。

## 发现项

四项真实任务已按当前入口、源码所有者、调用路径、测试发现及原生最终副作用逐一核对，尚无证据支持新的独立未解决生产缺陷。T2 的 CRLF 漏行、T3 的无效 revision 错判及旧正文清空、重复历史 Git 读取均在各自任务内先 Red 后 Green 修复，不作为新 Open finding。

明确验收边界：本机真实 Git／NSWindow／TextKit 已验证**文字进入原生表面、编辑保存回磁盘**，但不能冒充独立 App 的菜单点击或合成像素 E2E；真实 SSH 需使用授权专属连接。性能 A/B 为同机同文本的 Debug 热路径，冷启动／峰值 RSS／渲染像素／完整交互只能在 P6 综合复测中继续取证，不由组件时间外推。

## 修复日志

- T2 从共享根因删除逐 `Character` LF 匹配，使用 Unicode scalar；CR 及原字节、UTF-16 坐标不转换，单一分行器继续供 review 和 edit 使用。
- T3 以原始 NUL index/tree metadata 选固定 OID 后读 size/blob，删除动态 Git spec、stderr 词汇猜错缺失和重复的 `isUnmerged` 查询；unborn HEAD、冲突 stage 及特殊路径有实际回归。读取错误保留之前已显示内容，失效 fold 不覆盖新输入；不可变历史已加载的重复点击不再读 Git，live 仍重读。未删除保存／只读／容量的必要保护。
- T4 只改双侧 captures 的并行方式，保留同一个 query 缓存、core/runs 和 `displayGeneration`；对同机原生文本安装中位约 5.8% 的两轮可比收益，不增加任务调度、缓存或新依赖。临时性能 XCTest 已退出正式目标，原始实验源码在忽略目录。
- 未发现需要本轮审计额外修改产品代码的有证据缺陷。

## 验证日志

- 最终 HEAD 0644d34，make test（build/performance/diff/p5-final-full.log）：315 项、0 失败、3 个需授权 SSH 的用例跳过；make build 与 make build:release 均 BUILD SUCCEEDED，两个 App 均通过严格 codesign 验签。
- 分层测试：DiffEngineTests 4/4、DiffTabTests 23/23、GitHistoryFileTests 16/16、GitExecutionTests 4/4、WorkspaceIdentityTests 4/4、SyntaxHighlightingTests 15/15、EditorTextInputTests 3/3，均 Green；验证真实 Git fixture、原生 TextKit、UTF-8 字节保存和异步失效。
- 同机 Apple M1 Pro、macOS 27.2、Debug 的 1200 行 Swift 样本：双侧 captures 30 次串行中位 74.670ms→并行 53.733ms，name/range 等价；Git→Diff→原生文本安装反向各 30 次中位 236.562ms→222.759ms，p95 242.726ms→237.101ms。内容安装不是屏幕合成或冷启动测量。
- 已读源码调用链与测试确认旧动态 Git spec、stderr 缺失猜测、重复 isUnmerged、逐 Character 分行、历史不可变重复读取均已替代，临时性能类从正式 XCTest 目标删除，实验源码留在忽略目录。
- 文档相关 8 个入口（docs/README、diff、git、editor、testing、development、idea、plan-p5）的相对 Markdown 文件路径均可达；git diff --check 通过。
- 独立 App 完整菜单／GUI E2E、授权真实 SSH 与长期资源占用仍由 P6 验收，不把自动测试的绿色扩展到它们。

## Gate（是否允许进入下一阶段）

- 结论：**Go，可进入 P6**。
- 理由：P5 四项已逐任务实施、核对真实消费者、同步必要文档与清理旧路，永久回归通过；全量 XCTest 与 Debug/Release 验签通过，性能改动有同机 A/B。完整独立 App、真实 SSH、内存和滚动的未测边界在既定 P6 明确处理。

## 最终状态与剩余风险

- 当前状态：P5-T1～T4 **Resolved**，没有已证实未修复的阶段生产代码 finding。
- 剩余风险：独立 App 前台真实 E2E、授权 SSH、长期 RSS/CPU 仍待 P6。P7 的官方插件迁移 No-Go 不影响现行 Neon 下的 P5 完成。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
