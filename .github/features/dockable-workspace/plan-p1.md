# Plan P1 - 停靠状态与恢复

**Goal:** 建立窗口唯一停靠树，将项目所有工具及工作标签以稳定身份置入布局并正确恢复。
**Non-goals:** 此阶段不替换原生窗口 UI。
**Approach:** 独立的 DockWorkspaceModel 表示可递归切分的标签组与可移动元素；复用原 Project.tabs 和已有会话容器。将停靠快照写入 ProjectSnapshot，以 tab index 重新关联启动后变化的 UUID。
**Acceptance:** 纯状态回归通过：移动/分屏/合并/重排/空组折叠/恢复、旧快照。
**Rules:** 不销毁 PaneTab/Session/ FileTab，面板与项目的数据所有权保持原处。

---

## P1-T1 统一停靠状态与旧版恢复

**Files:** kero/Workspace/DockWorkspaceModel.swift, kero/Workspace/Project.swift, kero/Workspace/SessionStore.swift, kero/Terminal/TerminalManager.swift, scripts/check-dock-workspace.swift

复用 PaneTab 的身份与生命周期；递归分屏容纳有序标签组，维护 left/main/right 角色、空侧区和每组选中标签。新建、关闭或切换项目同步标签身份，布局变更转发自动存档。快照采用经过验证的 tab 下标，过滤不能恢复的 tab，旧版快照仍然恢复默认侧栏。

**Validation:** xcrun swiftc ... check-dock-workspace.swift；Debug 编译；git diff --check。
**Commit:** 中文原子提交。

---

## Phase Audit
- Audit file: audit-p1.md
- 审核模型不变量、恢复正确性和原始 tab 生命周期。
