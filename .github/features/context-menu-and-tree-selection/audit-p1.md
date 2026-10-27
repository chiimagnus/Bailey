# Audit P1 - context-menu-and-tree-selection

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/context-menu-and-tree-selection/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P1-T1 复现并确认原生菜单事件链
- [ ] P1-T2 统一 Files 菜单点击与快捷键执行
- [ ] P1-T3 Dock Cmd-W 菜单反馈与关闭保护

## 任务到文件的映射

- P1-T1（事件链诊断；仅结论、无独立生产提交）
  - `Bailey/App/BaileyApp.swift`：系统 Edit／Panel 命令归属。
  - `Bailey/App/FinderService.swift`：原生菜单快捷键展示格式。
  - `Bailey/Shared/Tree/TreeRowStyle.swift`：当前 `ContextMenuClickView.menu(for:)`、菜单跟踪及事件派发。
  - `build/p1-terminal-ascii-focus-e2e.log`、`build/p1-menu-chinese-focus-e2e.log`：隔离 GUI 事件链，诊断代码已清理。
- P1-T2（`6fe42c8` 选择状态基础、`8742a09` 菜单快捷键）
  - `Bailey/Files/FileTreeModel.swift`：右键集合和显式选择独立。
  - `Bailey/Files/FileTreePanel.swift`：原生菜单命令指向已有 SwiftUI 动作；菜单关闭释放目标。
  - `Bailey/Shared/Tree/TreeRowStyle.swift`：只在菜单跟踪期间注册临时键盘监听。
  - `Bailey/Workspace/WorkspaceWindowModel.swift`：既有文件命令后端、项目及 SSH 剪贴板身份检查。
  - `BaileyTests/App/AppIdentityTests.swift`、`BaileyTests/Workspace/WindowOwnershipIntegrationTests.swift`、`BaileyUITests/Files/SharedTreeUITests.swift`：宿主及真实 GUI 验收。
  - `AGENTS.md`、`docs/ui.md`、`docs/features/files.md`：单一菜单动作与原生焦点边界。
- P1-T3（`e31c9a8`）
  - `Bailey/UI/WorkspaceDockView.swift`：工具／文件标签菜单闭合与 Cmd-W 单次原生动作。
  - `Bailey/Workspace/DockWorkspaceModel.swift`、`Bailey/Workspace/WorkspaceWindowModel.swift`：既有 `contextTarget`、`closePanel`。
  - `BaileyUITests/Workspace/WorkspaceDockUITests.swift`：文件标签、工具面板菜单内 Cmd-W 实测。
  - `docs/features/dock.md`、`docs/ui.md`：菜单期间关闭目标和菜单关闭后的恢复。

## 发现项

## 发现 F-05

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`Bailey/Shared/Tree/TreeRowStyle.swift`、`Bailey/Files/FileTreePanel.swift`
- 摘要：`Files 右键菜单展开时 Cmd-C 实际复制成功，但 AppKit 仍响系统提示音`
- 根因证据：`build/p1-beep-breakpoints.log` 中隔离 Bailey Dev 的 `NSBeep` 断点命中；调用栈为 `NSMenuTrackingSession._keyDownEventHandler` → `NSBeep`。当前临时键盘监听执行 SwiftUI 菜单动作，但没有让原生菜单跟踪循环认领该快捷键。
- 已排除：`cancelTracking` 与 `performActionForItem` 调换顺序、在菜单开始前或开始后临时设置原生 `NSMenuItem.keyEquivalent`。原生等价项尝试没有建立可靠的无声、无重复且焦点恢复正确的证据；所有实验实现均已撤销。
- 验收要求：真实菜单仍展开时按 Cmd-C，正确写入右键目标的剪贴板记录，原生菜单不触发 NSBeep，动作只执行一次；菜单退出后 Terminal/Editor 真正恢复键盘输入。仍需针对真实 AppKit 菜单跟踪找到可验证的原生实现，禁止屏蔽系统音效或安装全局键盘钩子。
- 其它证据：`testContextMenuCommandCCopiesFileWithoutStealingTerminalFocus` 的终端输入断言有独立自动化问题：XCTest 注入时曾丢首字符，界面虽已关闭但旧菜单元素 `exists` 仍为 true，不得把这两项断言作为菜单蜂鸣已解决的证明。

## 发现 F-04

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`Bailey/Shared/Tree/TreeRowStyle.swift:166`
- 摘要：`跨窗口/菜单失效及 SSH 连接更换组合缺少完整 GUI 核销`
- 风险：`源码有当前窗口与项目有效性检查，但尚未在菜单打开的真实双窗口、远端断连、行删除与 Sheet 场景证明不会把临时命令送往过期目标。`
- 预期修复：`仅补明确的跨窗/失效/连接恢复验收；已有项目和剪贴板 token 后端不重复改写，出现场景 Red 再做根因修复。`
- 验证：`隔离 Bailey Dev 双窗口及授权 SSH 菜单跟踪 E2E；现有 WindowOwnershipIntegrationTests`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-03

- 任务：`P1-T3`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`Bailey/UI/WorkspaceDockView.swift:581`
- 摘要：`Dock Cmd-W 原生瞬时激活反馈经手动观察未出现`
- 风险：`E2E 证实关闭正确目标；用户手动验收明确观察不到瞬时高亮。这是尚未满足的交互要求，而非仅缺截图证据。`
- 预期修复：`确认 AppKit 是否提供真实可用的菜单键盘反馈机制；不能用模拟鼠标、人工动画或关闭成功冒充瞬时高亮。`
- 验证：`用户手动验收结论为未出现；若采用新的原生反馈实现，须重新观察按键瞬间并复验关闭目标仅执行一次。`
- 解决证据：`<commit diff note or test/build output>`


## 发现 F-02

- 任务：`P1-T2`
- 严重级别：`Medium`
- 状态：`Open`
- 位置：`Bailey/Files/FileTreePanel.swift:470`
- 摘要：`其它菜单快捷键及多选/禁用组合尚无等效真实菜单 E2E`
- 风险：`Cmd-X、Cmd-V、Delete、Cmd-N、Option-Cmd-N 使用同一菜单派发机制，但实际原生菜单启用条件和批量操作未逐组合完成 GUI 验收。`
- 预期修复：`用隔离夹具补齐可安全执行的目录创建/禁用/删除 GUI；剪贴板相关场景在剪贴板可保护时运行，验证实际文件结果与目标单次执行。`
- 验证：`make test:ui 定向 Files 菜单展开 Cmd-X/Cmd-V/Delete/Cmd-N/Option-Cmd-N E2E`
- 解决证据：`a6ee864` 中的菜单内新建用例、`19547bc` 的蓝框目标修复已通过联合 GUI 4/4；Cut、Paste、Delete 及禁用组合仍待核销。


## 发现 F-01

- 任务：`P1-T2`
- 严重级别：`High`
- 状态：`Open`
- 位置：`BaileyUITests/Files/SharedTreeUITests.swift:83`
- 摘要：`真实系统剪贴板 Cmd-C 私有 token 的两项 GUI 验收安全跳过`
- 风险：`只证明菜单按键进入既有文件后端，尚未在本轮实测 general pasteboard 最终路径和私有类型；不能宣称真实复制验收完整。`
- 预期修复：`保持现有复制后端不变；待用户剪贴板可无损备份的独立时段，仅运行两项已有真实 GUI 验收，并恢复原数据。`
- 验证：`make test:ui ONLY_TESTING=BaileyUITests/SharedTreeUITests/testContextMenuCommandCCopiesRightClickedFileWhileFilesOwnsFocus, BaileyUITests/SharedTreeUITests/testContextMenuCommandCCopiesFileWithoutStealingTerminalFocus`
- 解决证据：`<commit diff note or test/build output>`


<在此之下由 `finding add` 命令追加发现项，不要手工照抄模板>

## 修复日志

- <fill after fixes>

## 验证日志

- 2026-10-27：`make test:FileTreeTests,AppIdentityTests,WindowOwnershipIntegrationTests` -> PASS（106/106）。
- 2026-10-27：`make test:FileTreeTests` -> PASS（80/80，包含跨机器右键目标清理）。
- 2026-10-27：`make test:ui ONLY_TESTING=...` -> PASS（4/4：连续右键、新建文件／文件夹、Dock 文件标签／工具菜单内 ⌘W），日志 `build/p1-context-menu-final-e2e.log`。
- 2026-10-27：`0dd22f2` 消除了菜单桥接的 17 条 Swift 并发警告（AppKit selector 与同步主线程事件入口）；`make build` 与严格签名校验 PASS，`make test:AppIdentityTests,FileTreeTests` 88/88 PASS。
- 2026-10-27：隔离 Bailey Dev GUI 的 Files 菜单内 ⌘N／⌥⌘N、Dock 菜单内 ⌘W 联合 2/2 PASS（`build/p1-menu-selector-final-safe-ui.log`）。真实 Files ⌘C 复制路径和私有剪贴板类型已在单项 GUI 通过，但提示音仍按 F-05 保持 Open。
- `19547bc`：唯一右键描边目标、旧菜单结束不清除新目标；录屏核对连续右键的旧行不残留描边。
- F-01：普通可备份剪贴板下真实 Cmd-C GUI 的右键目标路径和私有类型已通过一次；另一条 Files 焦点 GUI 未稳定核销，富类型剪贴板及 Cut／Paste 仍待独立安全验收。
- F-02：Delete 会使用 `FileManager.trashItem` 移入实际系统废纸篓；未以用户废纸篓承载新的测试文件。
- F-03：用户手动验收确认 Dock Cmd-W 的菜单项瞬时高亮没有出现，仍是视觉验收缺口。
- F-04：真实双窗口与 SSH 断连后的过期目标 GUI 尚未核销；宿主窗口身份测试不能取代完整 GUI。

- `<command>` -> `PASS | FAIL`；完整退出码与测试后的必要构建/签名检查：`<实际结果>`
- 受影响功能全部已识别的适用环境、条件、异常／极端情况及组合：`<核销范围与实际结果；不以代表性用例替代>`
- 已核对的触发前提与最终用户可观察结果：`<实际证据>`
- 逐项跳过／未测条件、具体原因、影响、替代证据、补验方法与 Gate 影响：`<逐项记录；没有则写无>`
- 当前文档归属、事实、索引／锚点与未测声明：`<实际核对结果>`

## Gate（是否允许进入下一阶段）

- 结论：`Go | No-Go`
- 理由：`<一句话>`

## 最终状态与剩余风险

- 当前状态：`Open | Resolved`
- 剩余风险：`<if any>`

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

