# Audit P1 - dockable-workspace

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/dockable-workspace/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 统一停靠状态与旧版恢复

## 任务到文件的映射

- P1-T1
  - `kero/Workspace/DockWorkspaceModel.swift`：唯一停靠树、标签身份及快照
  - `kero/Workspace/Project.swift`：Tab 更新与停靠订阅
  - `kero/Workspace/SessionStore.swift`、`kero/Terminal/TerminalManager.swift`：保存与旧版恢复
  - `scripts/check-dock-workspace.swift`：可运行回归

## 发现项

## 发现 F-02

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Workspace/DockWorkspaceModel.swift:321`
- 摘要：`同组重排源标签在目标之前时会产生偏移一位`
- 风险：`拖拽显示的插入位置与实际结果不一致`
- 预期修复：`插入前按删除原索引校准目标索引`
- 验证：`check-dock-workspace 新增同组两个方向的重排测试`
- 解决证据：`check-dock-workspace PASS; both reorder directions; commit d31ee32`


## 发现 F-01

- 任务：`P1-T1`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`kero/Workspace/DockWorkspaceModel.swift:277`
- 摘要：`关闭位于辅助组的最后一个标签后保留空组`
- 风险：`原本已空的辅助分屏占据窗口空间，违反空组自动折叠`
- 预期修复：`同步 tab 列表后递归折叠空 extra 组`
- 验证：`check-dock-workspace 新增关闭辅助组最后标签断言`
- 解决证据：`check-dock-workspace PASS; closing auxiliary last tab collapses; commit d31ee32`




## 修复日志

- F-01、F-02 均在 `d31ee32` 修复；同步清理空辅助组并校准同组插入下标。

## 验证日志

- `xcrun swiftc ... DockWorkspaceModel.swift scripts/check-dock-workspace.swift && /tmp/check-kero-dock` → PASS
- `xcodebuild ... -configuration Debug build` → BUILD SUCCEEDED（基础集成）
- `git diff --check` → PASS

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：状态模型已接入自动保存与旧快照恢复，实际回归覆盖分屏、标签移动及空组处理；UI 行为留待 P2 真机验收。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：P1 尚未接入新 UI，视觉/手势和性能留在 P2 验证。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
