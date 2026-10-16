# Audit P1 - editor-git-performance

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/editor-git-performance/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 准备最小可重复样本与动作
- [x] P1-T3 修正首次解析与字节坐标
- [x] P1-T2 取得真实基线并固定热点准入

## 任务到文件的映射

- P1-T1
  - `build/performance/editor-git-20261016/{generate.py,a,b}`；本地样本／manifest，无生产改动。
- P1-T3
  - `kero/Editor/SyntaxHighlightPlugin.swift`、`KeroTests/NativeUI/Editor/SyntaxHighlightingTests.swift`、`docs/features/editor.md`；提交 `b6d7368`。
- P1-T2
  - `evidence-p1.md`、`build/performance/editor-git-20261016/`；本地原生 XCTest 实验、独立 App 冷观察与 sample。

## 发现项

## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`evidence-p1.md:6`
- 摘要：`原生实验样本误标416KiB，实际409600字节/400KiB`
- 风险：`影响前后样本可比性说明`
- 预期修复：`按实验字符串实际UTF8/UTF16长度更正，不修改实验结果`
- 验证：`Python核对UTF8=409600、UTF16=360448`
- 解决证据：`实验字符串实际UTF8=409600、UTF16=360448；evidence-p1更正为400KiB，统计未改动`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- F-01 仅更正本地证据容量，实测数据不变；无代码改动，不制造提交。

## 验证日志

- `make test` → 241 tests / 0 failures / 3 SSH skipped；`make test ONLY_TESTING=KeroTests/SyntaxHighlightingTests`、`make build`／严格验签 → PASS。
- 独立复核初次 InputEdit 为空旧范围；transformer 按 code unit 的 LF 和两字节列转换，非法位置返回 nil；真实 Parser 范围／点测试通过。旧段落转换及伪造零点已删除，没有双轨。
- 原生热两批各 30、独立冷进程 5、Swift/TSX/Markdown 实际截图、单独 sample 归因均可追溯；manifest 两次相同。
- 当前 editor.md 同提交维护解析契约；Feature 链接／任务锚点存在。未读旧审计或旧 review。没有把 AX／nativeInstall／firstColor 称为绘制／全高亮稳定或完整 E2E。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：代表打开路径已有可比原生数据、实际 App 着色和线程归因，正确性修复通过真实 XCTest；beta 的 Instruments 不可用已用 sample 替代且保留测量边界，不据未测项批准优化。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：Git/Files/Diff、编辑后收敛、分配／释放及真实 SSH 尚未验收，分别在各自 phase 改动前补基线；不能把本 Gate 当作整项性能验收。DTServiceHub 的系统签名限制仍在，不绕过、不切 stable。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
