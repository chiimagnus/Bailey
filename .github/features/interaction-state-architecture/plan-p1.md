# P1：Files Selection/Anchor 行为对齐 VS Code

**Goal：** 从真实事件与领域模型入手，修复不连续选择的 Shift 扩选，保留其它选中和焦点事实。
**Non-goals：** 不更换文件打开生命周期；不改 Settings；不新建通用选择 Store。
**Approach：** VS Code `listWidget.ts:MouseController.changeSelection` 的范围选择
会保留锚点外的其它选择并仅重算锚点附近原来的连续范围；
Bailey `FileTreeModel.selectRange(to:)` 当前直接覆盖 `selectedPaths`，
使 ⌘ 多选后 Shift 扩选丢失原有选择。直接修正这一最小领域真源，不在 View 补状态。
**Acceptance：** ⌘ 形成离散选中后 Shift/Shift+↑↓ 保持其它区段，来回收缩/扩展无多选残影；
普通↑↓不改变选择；点击、右键、Esc、全选、折叠与路径变更规则不退化。
**Rules：** 测试先 Red → Green；保持本机/SSH 机器、路径唯一性与数据保护；
不改菜单按键的既有任务状态。P1 完成后进行独立阶段审计。

---

## P1-T1 修正不连续选择的锚点范围扩选

**源码锚点：**
- `Bailey/Files/FileTreeModel.swift`: `select(_:extending:toggling:componentPath:)`、
  `moveSelection(by:extending:)`、`selectRange(to:)`、`selectionAnchorPath`、
  `selectedPaths`、`contextSelection(for:)`。
- `Bailey/Files/FileTreePanel.swift`: `FileTreeRow.selectForClick(componentPath:)`、
  `FileTreeScrollView.handleKey(_:) `；不复制模型状态。
- `BaileyTests/Files/FileTreeTests.swift`: `testFileTreeMultiSelectionRespectsVisibleOrderAndKeepsSingleCursor`。
- `docs/features/files.md`：共享呈现的范围选中说明。

**Step 1 / Red：** 真实临时目录中按可见列表顺序创建 5+ 文件，
先选 A、⌘选 C，再 Shift 到 E：A 必须继续选中，C/D/E 扩选；
改 Shift 到 D 时只移除 E，原先离散 A 仍在；
再验证 Anchor 未选中、Focus 位于集合外、反向区间、Shift+↑↓、普通↑↓、
空行及 Cmd+A/Esc 的行为。先运行目标用例并确认真实失败。

**Step 2 / Green：** 以 `selectionAnchorPath` 的可见索引为准，
仅移除以 Anchor 为中心、与之连续的旧选中区间，
再与新 Anchor→目标区间取并集；不得引入新私有选择状态或复制 VS Code helper。
当前目录锚点缺失时沿用现有 Focus/目标回退。保持 `contextSelection` 的集合语义、
普通焦点动作、右键菜单目标、真实文件操作与 AX 真源。

**Step 3 / Verify：** `make test ONLY_TESTING='BaileyTests/FileTreeTests'`，
`make build:dev`，`git diff --check`。
宿主覆盖单/多选、方向键与修饰键、紧凑目录、路径改名/刷新、消失项与根变动。
需要原生组合才能证明的 Finder/真实菜单/焦点使用现有隔离 UI 用例补验；
macOS 15.6、无实体触控板等条件如不可取得列为未核销。

**Step 4 / Commit：** 只提交本任务源码、测试和 `docs/features/files.md`；
回写 todo，不提交本地 feature 文件。

---

## Phase Audit

P1 所有任务完成后进入 `plan-task-auditor`，核对源码/测试/视觉/菜单受影响链与未覆盖清单。
