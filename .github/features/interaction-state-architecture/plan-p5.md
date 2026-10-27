# P5：跨域组合验收、可访问性与性能收尾

**目标：** P1～P4 分别通过审计后，验证**多个领域真正一起工作**时，
选中、Focus、Context、Displayed、Expanded、活动组和真实第一响应者仍各自正确；
在同一份源对照表下核销全部适用测试维度，而非只重复各模块“单独通过”的用例。

**非目标：** 绝不把本应在前一 task 完成的旧路径删除、源码接入、领域文档更新
统一堆到 P5；不重新实现 UI 状态框架；不因此修改 Settings。
新发现的某个组件缺陷在其真正 owner 修复，并作为本 task 的独立原子变更，
必要时更新对应 P1～P4 的验收证据与现行 plan，不伪装其他 task 已全绿。

**总证据来源：** [`source-review.md`](source-review.md) 的每条行为差距、
VS Code pinned refs 和 Git Graph 扩展的合法独立复现边界。
验证结果必须包含真实可见 UI/AX、真实 firstResponder 与磁盘、Git index/HEAD/refs、
Window/Dock/Tab identity；`XCTAssertTrue(button.exists)` 不能代表执行成功。

---

<a id="p5-t1"></a>

## P5-T1 跨 Files/Changes/Graph/Dock/Projects 的完整事件串回归

**触发流（相互依赖、不能只分开单测）：**

1. 本机 Project A 的 Files 多选 A/C → Shift 扩选/回缩 →
   右键其中一个选中/集合外 B → Copy/Cut/Paste；
   同时 Editor 保持未保存缓冲和原生输入；
   检查真实文件字节与错误路径未写入。
2. Files 单击浏览 → 另一组显示文件 → Git Changes 打开该文件 Diff →
   Graph 打开历史文件/展开 commit/比较两次提交 →
   返回 Files 导航，只移动游标而不重新打开编辑器；
   检查各时刻 Displayed/Focus/Selection/ActiveGroup 的真源。
3. Git Changes 在 Staged/Unstaged/Merge 多选 → 批量 Stage/Unstage →
   Graph 显示 Uncommitted、Stash/Worktree，右键一个 ref 时切到另一窗口；
   菜单不允许落到另一仓库，HEAD/index/refs 和相同路径都验证。
4. Dock 同一组 File+Diff+Terminal+Browser+工具 Tabs 的 ⌘/Shift 多选 →
   批量 Drag/移组/关闭部分标签 → 取消/成功/失败分支；
   Shell/WebKit/Native Editor 未重建；
   关闭脏 FileTab 保存失败时失败项和未处理标签保留，已确认关闭项不回滚；
   不得在保存保护完成前结束选中的 PTY/工具。
5. Projects A/B 切换、两个 NSWindow+多个 Dock Group：
   当前窗口本地项目 Files，另一窗口 Windows SSH Git/Files；
   断线/重新连接、快速刷新、异步 Git Diff 晚到、
   Tab Switcher Esc、Command Palette 取消；
   主菜单和第一响应者不作用于后台窗口或旧机器。
6. 原生 Cmd-C/Cmd-W 菜单打开中/取消后；
   普通键盘返回原编辑器/终端/输入框；Context 临时边框完全撤销。
   不利用额外的全局 key monitor 或修改用户真实剪贴板造测试。

**源码路径：** `FileTreeModel` ↔ `FileTreePanel` ↔
`WorkspaceWindowModel.performFileTreeCommand` ↔ `GitPanel/RecentCommitsView` ↔
`Project.openFile/openDiff` ↔ `DockWorkspaceModel/WorkspaceDockView` ↔
`WorkspaceApplication`；
输入检查 `TreeKeyboardView/ContextMenuClickView/DockGroupFocusReader`。

**执行：**
- 用现有各测试类的临时目录/真实 Git 夹具及 `WorkspaceUITestSupport.launch(in:project:)`，
  扩展已有 `SharedTreeUITests`、`GitChangesUITests`、
  `GitGraphUITests`、`WorkspaceDockUITests`、
  `WorkspaceWindowsUITests`，只把必须用原生系统键鼠证明的串联放进 UI E2E。
  真实数据的笛卡尔组合以宿主 `FileTreeTests`、
  `GitStatusModelTests`、`DockWorkspaceTests` 等承接，
  避免一套超长 GUI 脚本重复启动 App 干扰实际桌面。
- 每条链可见结果/AX/最终磁盘或 Git 结果分别断言；
  当前切项目/远端请求晚到必须由已有身份保护拒绝写入。
  如果某项失效，先记录 Red 与根因，修正真正 owner 并删替代路径，
  相关文档与测试**同任务**同步，禁止加跨模块 Manager 补丁。
- 完整测试：`make test`（宿主全集）和
  `make test:ui`（在独占/隔离的图形会话，仅 Dev bundle）；
  `make build:dev` 和签名、`git diff --check`；
  对已有 CI Head SHA 必须核对结果归属。
  测试期间正式 Bailey 不退出、不替换，不借用户 SSH master。
- 文档：仅发现与当前事实不符才修改所属 `docs/features/*.md`、
  `docs/ui.md`、`docs/architecture.md`，
  新增/修订串联测试与必要生产修复分别按独立职责原子提交；
  不提交临时截图/开发日志或虚构计划状态。

**验收：** 系统菜单/真实键鼠/跨窗等只有完整 App 才能证明的串联必须有 GUI E2E；
可由宿主证明的数据/异常组合全部留在宿主，不机械给每条数据链复制完整 GUI。
菜单/焦点/数据隔离及关闭后保留未保存编辑必须有反例断言。
macOS 15.6 真机、真实 Windows SSH 失联和连接恢复、
富类型系统剪贴板在无法安全完成时逐项列明无法核销的风险和后续操作。

---

<a id="p5-t2"></a>

## P5-T2 视觉/AX、多主题、多语言、极端容量与性能矩阵

**上游标准：** VS Code
`listWidget.ts:DefaultStyleController`、`abstractTree.ts`、
`scmHistory.ts`、`multiEditorTabsControl.ts`、
`multieditortabscontrol.css` 中各状态的意义；
Git Graph 扩展 `web/styles/main.css` 与 `web/graph.ts`
仅作**可观察样本**。不能因为测试转绿就从 extension 复制 CSS/图谱代码。

**状态组合：**
- 无/单/多岛 Selection；Focus 位于集合内/外；
  Anchor 先被取消；Context 先选中/未选中；Displayed 文件仍有旧底色；
  Expanded 目录/commit；hover/拖动/焦点失去后；两组与两窗口分别处于 active/inactive。
  树鼠标 Shift、树键盘 Shift、Tabs Shift 三套独立预期，以及
  Explorer 右键改 Selection、SCM/Dock 右键保留 Selection 的差异必须显式交叉覆盖。
- Files/Git Changes/History/Graph/Projects/Dock 标签的每一类行；
  图谱 branch/ref/Tag/Stash/Uncommitted/Worktree、merge/多父、
  历史文件与 Diff；快捷菜单和 AX 选中/展开/帮助/路径。
- macOS 系统浅/深、自定义 Ghostty 明暗、主题切换期间，
  中/英文、日文/中文 IME 输入；
  最小/最大 panelFontScale、最小/常规/超宽 Dock；
  中文/emoji/长路径/路径碰撞、紧凑目录、超长提交标题。
- 空/单行、1k/10k/100k 可见项（符合 UI 实际懒加载时），
  1k+ commits/12+ 颜色轨、30+ tabs、频繁键盘导航、
  大量多选/范围收缩/折叠/同步更新、外部文件事件风暴。

**执行：**
1. 在独立最小 NSHostingView/AppKit host 上测语义组合的像素/AX；
   当前生产主界面需要系统 firstResponder/菜单/窗口才能证实时，
   用隔离 `Bailey Dev` 的对应 UI 测试，而不是重复全部数据用例。
2. 渲染时测 Host View 结构、列表懒加载/滚动不回弹、可点击区域、
   背景和描边/图谱颜色/标签文字匹配真实 Selection 与 Focus；
   外观更改不重建同一个 TerminalSession/WebView/TextKit。
3. 性能先量基线（输入到可见响应、每次选择影响行数、帧间隔/重绘次数、
   大量选区转换、树/图谱 memory/分页）；所有修改在对应 owner 根因解决，
   不以无上限 NSHostingView 复制或定时刷新掩盖慢。
   没有客观性能提升时不得宣称“变快”；未量化的设备差异标明未知。
4. 对齐表逐项给出 **同义/等价/明确不复刻（产品或许可原因）/待决/未验收**，
   当行为和用户明示偏好冲突时列明原始与目标差异；
   与 P1–P4 决定一致，不临时改变 Settings 或 Tab preview 生命周期。
5. 如需实际修复，在源 owner 中独立提交其生产实现 + 对应回归和当前文档；
   不新建仅为了 P5 的抽象或二次视觉体系。

**验证：**
`make test` 的宿主全集（含 `FileTreeTests` 的 bitmap、
`CommitGraphLayoutTests`、`GitGraphPaletteTests`、
`DockWorkspaceTests`、`NativePaneRetentionIntegrationTests`）；
`make test:ui` 的完整 Dev GUI；
`make build:dev` 和实际签名、资源/多标签长期验收；
`git diff --check`。
不可获得 macOS 15.6 实体、实体触控板、辅助功能授权、第二显示器、
真实 SSH Windows 断线、富类型系统剪贴板时，
逐项记录阻塞、可能影响、替代证据和补验环境。

**文档：** 完成时核对 `docs/ui.md` 各共享视觉语义、
`docs/architecture.md` 各 owner、
`docs/features/files.md/git.md/dock.md/projects.md/command-palette.md` 的最终契约；
发生实际契约变化的文档随对应 task 的提交已经更新，
不把 P5 当作追补此前所有遗漏的独立文档重写任务。

---

## P5 阶段审计与结束标准

1. 运行 `feature_tool.py todo validate`、
   `phase-complete ... --phase p5`，随后通过 `plan-task-auditor`
   完成 `audit-p5.md`，报告 Go/No-Go 和逐项 Deferred 条件。
2. 审计不仅核对“是否全部 task 有提交”，还需检查：
   VS Code 上游源码映射没有未解释的交互缺项；
   Git Graph 扩展许可证约束始终遵守；
   Git Changes、Dock 的新增多选并非仅视觉；
   所有输入、文件、Git、Tab 的目标真实有效；
   旧重复分支在每个 task 完成时即已删除；
   Settings 完全保持先前回撤版本。
3. 检查提交 SHA、计划状态、受影响文档、完整 build/签名/测试退出状态、
   真机 GUI 和最终用户可见结果；
   **仅在实际完成的范围内**宣称验收通过。
4. 如果设备/环境不可达影响必要验收，结论明确给出未完成与补验条件；
   即使其它测试绿色，不编造全部环境通过。
5. 本轮计划修订不构建、安装或重启正式 App。
   后续功能实现完成且通过验证后，按 AGENTS 与 development.md 默认完成
   `make build`、验签和整包安装（用户明确跳过时除外），不启动/重启既有正式进程；
   测试、构建、安装、重启、发布分别报告，不以 Dev 构建代替正式包交付。
