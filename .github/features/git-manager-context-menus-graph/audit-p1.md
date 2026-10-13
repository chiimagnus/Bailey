# Audit P1 - git-manager-context-menus-graph

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/git-manager-context-menus-graph/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 保存完整父提交与解析有类型 Ref
- [x] P1-T2 Recent Commits 真实图谱与 Ref 独立命中

## 任务到文件的映射

- P1-T1（`2b336ba`，审计修复 `ea41b63`）
  - `kero/Git/GitStatusModel.swift`：一次 Git 日志保存完整父 SHA、全部分支/Tag 引用及类型，兼容本机/SSH 批量查询
  - `kero/UI/Panels/ToolPanelView.swift`：历史文件 Diff 仍只使用首父
  - `KeroTests/Integration/Git/GitStatusModelTests.swift`：真实临时仓库中检查双父合并、多个 Ref、带斜杠分支、独立分支
  - `docs/features/git.md`：记录正式数据契约
- P1-T2（`0c42e3a`）
  - `kero/Git/CommitGraphLayout.swift`：纯派生多车道拓扑、边与文件行继续连线
  - `kero/Git/RecentCommitsView.swift`：双行显示、按类型呈现和收纳 Ref、独立点击、真实 Canvas
  - `KeroTests/Unit/Git/CommitGraphLayoutTests.swift`：单车道、合并、同时活跃多分支、分页
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：宽/窄面板展开与合并提交的文件 Diff 命中
  - `kero/Resources/Localization/Git.xcstrings`、`docs/features/git.md`：本地化及 UI 契约
  - `kero/Git/GitPanel.swift` 原有接线仍直接调用 `RecentCommitsView`，未创建第二套入口

## 发现项

## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`kero/Git/GitStatusModel.swift:1498`
- 摘要：`真实合并提交的历史文件列表丢失`
- 风险：`git log 默认不输出 Merge Commit 的 name-status，Recent Commits 展开后错误提示无文件，无法打开该提交的实际第一父差异。`
- 预期修复：`在本机与 SSH 共用的单次 git log 参数中指定按第一父比较合并提交，补真实仓库集成回归。`
- 验证：`make test ONLY_TESTING=KeroTests/GitStatusModelTests; make test ONLY_TESTING=KeroTests/RecentCommitsViewTests; make test; make build`
- 解决证据：`ea41b63: 临时 Git 合并真实回归先失败（merge.files=[]）后通过（side.txt），完整 make test 102/102，make build 验签成功；本机和 SSH 使用同一条 log 参数。`


审计使用独立真实 Git 仓库补查合并提交文件输出，确认既有测试虽全部通过，但未覆盖 Merge Commit 的实际文件列表。重复 Git 文档段落已经合并，不另设 finding。

## 修复日志

- 原生窄面板截图暴露短 SHA 换行；P1-T2 提交前改为固定单行，由作者承担缩略，随后 260px/420px NativeUI 通过。
- Commit 行的旧右键复制入口恢复到整行，Ref Badge 独立命中；全量 102 项测试在最终源代码调整后复跑通过。
- 本地 `todo.toml` 被并行索引误入 `0c42e3a`，用 `63767f5` 恢复已提交版本中的该文件，保留工作区的本地进度；未重写历史。
- F-01：独立 Git 合并复现默认 log 隐藏 Merge Commit 的文件差异；新增真实仓库断言先红后绿。统一日志加入 `--diff-merges=first-parent`，不新增命令，本机和 SSH 同源（`ea41b63`）。

## 验证日志

- `make test ONLY_TESTING=KeroTests/GitStatusModelTests` → **PASS**（7/7；含本机与模拟 SSH 读取路径）。
- `make test ONLY_TESTING=KeroTests/CommitGraphLayoutTests` → **PASS**（4/4）。
- `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` → **PASS**（2/2）。
- `make test` → **PASS**（最终修复后再次执行，102/102，0 失败）。
- `make doctor && make build` → **PASS**（Xcode 27.0；Debug 构建和 `codesign --verify --deep --strict` 通过）。
- NativeUI 实机截图（不入仓）：多父合并与展开后的线条保持连续；宽/窄面板 Ref、SHA、作者、时间布局目测核对。
- CodeGraph 同步复核：`GitPanel → RecentCommitsView → CommitGraphLayout` 是真实使用路径；新增测试已覆盖对应类型，旧单线 Canvas、字符串 Ref 推断已删除。
- 当前文档归属：`docs/features/git.md` 是 Git 维护事实所属文件，已去除重复说明，Merge Commit 的文件 Diff 基线与源码一致；`docs/ui.md` 的共享树契约未变。feature 计划和 audit 继续本地维护，不加入本次提交。
- 未测：真实 Windows SSH 主机上的可视化交互和人工 VoiceOver/键盘逐项验收；模拟 SSH 与原生窗口 XCTest 已通过。

## Gate（是否允许进入下一阶段）

- 结论：**Go（仅 P1）**
- 理由：F-01 已按真实临时仓库红绿回归修复；完整 XCTest、原生窗口交互、Debug 构建和签名检查均通过，P2/P3 未实施。

## 最终状态与剩余风险

- 当前状态：**Resolved（F-01 已验证）**
- 剩余风险：真实 Windows SSH 主机上的人工图谱交互、VoiceOver/键盘逐项验收尚未执行；已有模拟 SSH 与原生 XCTest 证据，不能把它们冒充真实远程 E2E。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

