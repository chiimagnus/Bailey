# Audit P2 - git-graph-visual-parity

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/git-graph-visual-parity/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 符号远端Ref只读展示与原生接入
- [x] P2-T2 一次完成Ref分组复合标签与分段操作

## 任务到文件的映射

- P2-T1 — `a4f1e06`
  - `kero/Git/GitStatusModel.swift`：在当前 Ref 快照解析中用 `symref` 把远端别名分类为 `.remoteAlias`，删除无条件隐藏的旧过滤分支。
  - `kero/Git/RecentCommitsView.swift`：在现有右键与复制链中单独消费别名类型，不开放远端写菜单。
  - `KeroTests/Integration/Git/GitRemoteBranchActionTests.swift`、`GitStatusModelTests.swift` 和 `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：真实远端引用区分、完整状态和菜单证明。
  - `docs/features/git.md`：只读符号 Ref 的行为与写权限契约。
- P2-T2 — `04a6ec9`
  - `kero/Git/RecentCommitsView.swift`：单一 `GitGraphReferenceGroup` 分组与实际 `referenceStrip` 消费者、颜色图标、复合圆角标签、独立菜单、按真实 Ref 数计数的 `+N`、Stash 同款外观。
  - `kero/Git/GitPanel.swift`：唯一产品调用点传入现有 `model.remotes`，不修改 Git 操作决策链。
  - `KeroTests/NativeUI/Git/RecentCommitsViewTests.swift`：最长前缀、多个远端／Tag／别名、32+ 引用、实际三个 Button 点击＋菜单及不同侧栏宽度回归。
  - `docs/features/git.md`、`docs/ui.md`：引用分组和原生外观的唯一当前行为描述。

## 发现项

当前审查未发现具有源码／测试证据的未解决阻塞项。审查核对了 `a4f1e06` 与 `04a6ec9` 逐文件变更：分组只有 `RecentCommitsView` 这一个产品消费者，菜单仍由 `GitPanel` 调用现有 GitStatusModel 资格校验；无独立的全局事件层或重复 Remote 解析器。

## 修复日志

- 两个 task 在各自提交中完成接入、验证、文档同步与旧代码删除，审计无需增加补丁。P2-T2 离屏视觉验收发现 260pt 侧栏全部折叠成 `+4`，已在该 task 内改为主 `main` 可见、余下 `+3`；再次截图与实测通过。
- 为原生菜单测试曾探查离屏 AX 子树，因该宿主未暴露预期信息而直接删除探查 helper，继续复用现有 NSHostingView 的真实坐标命中测试；没有将测试辅助系统纳入产品。

## 验证日志

- `make test ONLY_TESTING=KeroTests/GitRemoteBranchActionTests` -> PASS，15/15，含符号 `upstream/HEAD` 与非 HEAD 别名的只读校验。
- `make test ONLY_TESTING=KeroTests/GitStatusModelTests` -> PASS，26/26（P2-T1 修改 Ref 解析后的模型集成测试）。
- `make test ONLY_TESTING=KeroTests/RecentCommitsViewTests` -> PASS，18/18，包含分段真实鼠标点击、独立菜单、剪贴板、最长已配置 remote、32+ Ref、窄面板不整体横滚、Tag/Stash 旧契约。
- `make test ONLY_TESTING=KeroTests/GitStashActionTests` -> PASS，12/12，未影响指定 Stash 实际操作及同 OID 选择器。
- 原生离屏视图视觉验证：`/tmp/kero-graph-p2-wide.png` 与 `/tmp/kero-graph-p2-compact.png`，分别对应 500pt 与 260pt 宽度；已检查彩色图标与节点同色、`main | origin | upstream` 单一外框、Tag 独立、主标签保留与 `+N` 访问。一次性截图 test 已从提交前的产品测试删除，截图保留在临时目录而非仓库。
- `git diff --check` -> PASS，两个提交仅纳入显式任务文件，未覆盖其他 AI 的暂存或工作树改动。
- 当前合同分别由 `docs/features/git.md`（Ref、权限、菜单）和 `docs/ui.md`（形状、颜色、密度）维护；未触碰 `Theme`、共享文件树或核心 Git 写操作。完整 build/test 和独立进程 UI 验收由 P3 完成，不冒充已通过。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：P2 两项均已接入产品链与真实 Git 操作所有者，Ref 分类、复合展示、分段点击和菜单均经真实原生／集成 XCTest 证明；旧胶囊与类型硬编码颜色已在实现 task 删除。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：P2 阶段结束时提交标题仍在标签左侧、Merge 标题未弱化、节点悬停尚未实现，按既定 P3 实施；深浅色完整 UI 整合、实际独立 App 运行与全量构建／测试尚未完成，绝不作为 P2 的假证据。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
