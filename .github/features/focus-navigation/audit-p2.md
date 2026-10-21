# Audit P2 - focus-navigation

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p2.md`
- feature 目录：`.github/features/focus-navigation/`
- 粒度：`phase`

## 任务快照

生成此审计时的任务快照；实时状态仍以 `todo.toml` 为准，不另维护一套进度。

- [x] P2-T1 区域 Focus 与 selected 视觉区分
- [x] P2-T2 拖放和多窗口焦点恢复验收

## 任务到文件的映射

- P2-T1
  - `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView` 的 `isFocused/canFocusGroup`、`Bailey/UI/Components/WorkspaceChrome.swift.TabItemChrome` 真实活动标签文字权重；最新用户要求取消内描边，不增额外下划线。当前实现 `f698e1c`，对应 `docs/ui.md`、`docs/features/dock.md`。旧 `eeb96f8` 只作为历史原型记录。
- P2-T2
  - `DockTabDragCoordinator.finish` → `DockWorkspaceModel.move/place/updateLayout`；`Project.selectTab`；`TerminalManager` 的 Palette 捕获/恢复/所有权检查；`CommandPaletteView.run`；`TerminalHostView` 的可见/停车宿主与 `TerminalFind/TerminalFindBar`。
  - `DockWorkspaceTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`；当前功能文档 `dock/terminal/command-palette/session-restore.md`；主体提交 `962abba`、审计根因修复 `9c95cc2`。像素测试夹具校正在独立提交 `5f12573`。

## 发现项

## 发现 F-04

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/TerminalManager.swift:984`
- 摘要：`从 Files/Git 树行打开并取消 Command Palette 时，旧树键盘 first responder 没有保存或恢复路径`
- 风险：`关闭搜索面板后方向键可能落在 Dock 背景/已消失的 TextField，文件或 Git 行选中留存但无法继续键盘导航；焦点视觉和真实输入不一致`
- 预期修复：`复用现有前台 key-window/活动组的焦点交接入口恢复当前可见树接收者；禁止恢复已切换或已隐藏组；不新增全局事件总线`
- 验证：`新增 WorkspaceWindowIsolationTests 原生窗口 Files 与 Git、Palette 取消/执行、旧编辑器接管的 Red→Green；make test ONLY_TESTING=BaileyTests/WorkspaceWindowIsolationTests；隔离 App 真实方向键`
- 解决证据：`Red: /tmp/bailey-focus-audit-palette-red-tree.log，Files取消 Palette 后 8 秒仍无法恢复 TreeKeyboardView；86f8ff8 修复 TerminalManager 对当前活动 Dock 组内 TreeKeyboardView 的保存与原生归属验证。Green: /tmp/bailey-focus-audit-palette-git-files-green.log 9 项/0 失败；/tmp/bailey-focus-audit-palette-command-execute.log 2 项/0 失败，覆盖 Git 清洁/脏仓库、Files 取消后 ↓、执行 Palette 新命令不夺回旧焦点。`


## 发现 F-03

- 任务：`P2-T1`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/UI/WorkspaceDockView.swift:305`
- 摘要：`未完整遵循Issue13已确认HTML的三层焦点视觉`
- 风险：`当前只有区域边框，活动标签栏和所选标签没有额外强调，与已确认UIUX不符`
- 预期修复：`沿DockTabGroupView和共享TabItemChrome表达活动标签栏底色与活动selected标签底色及下划线，不复制原型演示控件`
- 验证：`对照HTML交互，明暗窄宽标签原生像素，真实复杂布局前后台焦点与完整build/test`
- 解决证据：`用户最新 2026-10-21 决策明确不要旧 HTML 的高亮边框/标签下划线；f698e1c 采用 Zed 无描边标签文字层级；独立 GUI 深色截图 /tmp/bailey-focus-verify.kniA3O/p2-after-drag.png 证明无整框。旧发现是过时验收，不再应补标签装饰。`


## 发现 F-02

- 任务：`P2-T2`
- 严重级别：`Medium`
- 状态：`Deferred`
- 位置：`BaileyTests/WorkspaceUI/Windows/WorkspaceWindowIsolationTests.swift`
- 摘要：`工具内部控件与复杂布局的焦点集成验收不足`
- 风险：`既有组件点击测试与模型选组测试没有共同证明GitGraph、文件树及输入态在真实停靠布局内的命令和响应者归属`
- 预期修复：`在现有XCTest目标补齐实际控件事件与复杂布局交互矩阵，并单独记录独立App验收结果`
- 验证：`原生工作区真实Git仓库/文件树/重命名/新建/菜单与六组以上嵌套、移动、关闭、恢复；最终磁盘字节与对象身份`
- 解决证据：`P2 的窗口/区域/原生响应者基础已完成：本轮 62 项相关原生测试退出 0，隔离 App PID34267 从文件打开编辑器到 Git 再到 ⌘P→File Manager，菜单消失后编辑器未抢回焦点；真实 File Manager 标签拖动 x1467→310.5，AX 与截图均证实。此前完整回归 580 项 0 失败、8 项条件跳过。文件树单击和 Git 图谱行选择的剩余真实缺口已按用户要求明确定为 P3/P4 的实现任务，不能作为 P2 未完成重复实现，也不得误称已通过。`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Terminal/TerminalFindBar.swift:60`
- 摘要：`真实窄栏查找 Escape 后终端没有恢复输入`
- 风险：`关闭查找后 first responder 留在窗口，后续终端命令不执行`
- 预期修复：`沿查找真实消失及终端宿主恢复路径定位失效条件并在责任层修复`
- 验证：`原生回归及隔离 App 输入最终 marker 文件`
- 解决证据：`9c95cc2；原生两项归属Red→73项Green；隔离PID40540窄Find查询与Escape后真实Shell写出NARROW_RESTORED_OK，最终AXTextArea为源Surface；无延时/重试补丁`


独立 App 发现 F-01；根因在 `DockGroupFocusView.containsResponder`，并非查找消失时机。执行期间已经 Red→Green 的其它根因留在 `evidence.md`，不事后伪造为本阶段审计新发现。

## 修复日志

- F-01 原生有效 Red 两项归属断言；诊断实际控件 164×15、visibleRect 却为 1800×732。共享判断取与 bounds 的交集后 73 项相关原生/模型回归退出 0；独立 App 窄 Find 关闭后生成真实 Shell marker；最终全量 579 passed、0 failed、0 skipped。提交 `9c95cc2`，没有查找重试或延时。
- 已核对旧按 MRU 路由焦点、只凭 responder 类型或 window 恢复、停车依赖旧宿主拆卸，以及固定宽查找栏的替代路径均已删除；没有兼容焦点双轨或全局恢复协调器。`DockSavedItem.info` 是独立历史快照过滤契约，不是本计划替代的焦点路径，按现有会话文档保留，不破坏旧快照数据。

## 验证日志

- 2026-10-21 补验：62 项相关 XCTest 0 失败；独立 App PID 34267 打开隔离临时工程（`alpha.swift`、`beta.swift`），File Manager/编辑器/Git 分组的真实 AX 焦点、Palette 搜索字段到 Git/Files 菜单的输入归属及标签拖动后的实际位置均已复核。P3 的 Red 同时确认单击 `alpha.swift` 后 `AXTextArea` 获得焦点，这不属于 P2 的 Dock 组基础验收，已归 P3-T1 修复。屏幕图像保存在 `/tmp/bailey-focus-verify.kniA3O/`，隔离实例不读写用户项目，正式 Bailey 不曾被重启。
- 最终 Debug 完整 `make test`（含授权 Windows SSH）退出 0，579 passed、0 failed、0 skipped；最终 Release 相关 8 类为 119 passed、0 failed、0 skipped，均核对 xcresulttool。只有优化测试命令传 `SIGNING_FLAGS=ENABLE_TESTABILITY=YES`，随后普通构建恢复正式配置。日志和结果路径见 `evidence.md`。
- 模型穷举 3 工具 × 空组中央/四边；8 工作标签、6+ 横纵嵌套、无效 ID、关闭活动/后台 MRU、纯聚焦零快照；恢复新组 ID 后原编辑器身份不变。原生矩阵覆盖 2 外观 × 3 窗口尺寸 × 4 活动目标，Find 150/210/400/900 pt × 明暗。检查了源 Surface 真实父视图、回调清除时序、隐藏/停车/换项目/关闭后的所有权拒绝。
- 同源保存经过现有 FileTab/Diff 保存队列至最终磁盘，包括多个脏缓冲、失败/并发编辑/断线恢复；Ghostty 与 WebKit 身份、Undo、滚动和释放由原生测试核对。独立 App 已核对 Palette 取消/命令、工具输入不泄漏、真实拖放 Shell PID 不变、Unicode 字节与双主窗/Settings 快捷键；不是以事件派发充当 E2E。
- 最终窄 Find/空组独立 App 补验通过；通知横幅遮挡与输入焦点缺陷已区分。普通 `make build`、`make build:release` 及严格验签完整退出 0；Debug 全包原子安装、安装后签名及 SHA-256 核对通过，暂存备份清理完毕。正式 PID 48459 未退出/启动/重启，未推送/发布。
- 环境缺口逐项见 `evidence.md`：无 macOS 15.6 设备；Windows 不允许建立 symlink；无隔离图形登录的 VoiceOver 语音/长期五分屏专项；嵌入 WebKit 全网页 GUI E2E；真实 IME 候选交互和共享大字号设置。分别保留替代证据，不将其宣称为实测，最终 Gate 说明影响。
- 安装后追加 Release 独立 GUI 遇到自动化权限失效：Screen Recording/Accessibility/Event Synthesizing=false，System Events=-1743，不能把 AX 不可访问当产品无窗口。该追加项未完成；不冒充 Debug GUI/Release 原生测试的等价结果。未改隐私设置或重启正式 App，测试 PID 67650 已清理。权限恢复后补验，不阻塞已完成的签名 Debug App 验收；本 Gate 不是 Release 全 GUI 认证。
- 当前文档各有归属，未新增页面或失效导航。工具当前文件高亮仍使用工作上下文；Files 多选、行焦点样式与可编辑快捷键仍分别归 #5/#43，没有假称本功能已实现。

## Gate（是否允许进入下一阶段）

- 结论：`Go`（仅允许进入 P3 Files / P4 Git 行焦点实施，不代表它们已完成）
- 理由：本轮重新逐项核对 P2 范围：`make test ONLY_TESTING='BaileyTests/DockWorkspaceTests BaileyTests/WorkspaceWindowIsolationTests BaileyTests/PaneRetentionTests BaileyTests/WorkspaceContentIdentityTests'` 62 项 0 失败，隔离签名 Debug Bailey PID 34267 使用仅在 `/tmp/bailey-focus-verify.kniA3O/project` 的文件。真实 GUI 检查了文件显示/切到 Git 后旧编辑器焦点移除、⌘P 搜索 `File Manager` 执行后搜索框消失且旧编辑器未抢回焦点、`File Manager` 标签从右组 `x=1467` 拖动到中组 `x=310.5` 后仍真实可见；截图 `p2-files-before.png`、`p2-after-palette-command.png`、`p2-after-drag.png`。分屏无蓝色整框，标签高亮符合用户最新决定。此前相同产品代码的独立 GUI 更复杂场景、完整测试、Debug/Release 证据仍在 `evidence.md`；未用这次只覆盖一例的拖动冒称全部复杂布局重新跑完。
- F-03 属于过时原型要求，已按最新用户指示修订并 Resolved；F-02 剩余的 Files/Git **行选择、行边框和输入框**需要 P3/P4 的新模型才能验收，明确 Deferred 到 P3/P4，不再在已完成的 P2 重写两套选中状态。现有 P2 活动组、窗口隔离、临时焦点恢复已经具备可执行测试与真实 App 证据。

## 最终状态与剩余风险

- 当前状态：`Go`；`todo.toml` 的 P2 两任务完成，P3/P4 仍 pending。
- 剩余风险：F-02 所涉 Files/Git 行选择、Git Graph 展开与输入框间真实焦点交互**尚未实现**，不能称为 P2 已解决，它们的 Red/Green、数据字节/仓库副作用与全 GUI 验收分别由 P3/P4 交付。缺失 macOS 15.6、特殊 SSH/symlink、VoiceOver、共享输入法/字号条件仍按本页和 `evidence.md` 明确保留。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

## 2026-10-21 独立按提交复核（不采用上方历史 Gate 作依据）

| Task | 独立核对的提交 | 当前真实调用链与不变量 |
| --- | --- | --- |
| P2-T1 | `eeb96f8`、`f698e1c` | 旧整组强调边框来自先行原型，后续提交已删除；当前仅在 `DockTabGroupView` 对真正活动组的 selected 标签保留较高图标/文字对比度，灰底/行焦点环不等价于分屏焦点。不能再恢复旧边框。 |
| P2-T2 | `962abba`、`9c95cc2`、本轮 `86f8ff8` | `DockGroupFocusView` 以当前 window/group 判断 NativeResponder，`TerminalFind` 以实际可见终端宿主恢复，`CommandPaletteView.run` 显式放弃旧焦点；本轮发现原恢复链遗漏了 Files/Git 的 `TreeKeyboardView`，已补入相同焦点所有权校验入口，且只对当前可见活动 Dock 组生效。 |

本轮 **F-04** 有独立 Red：`/tmp/bailey-focus-audit-palette-red-tree.log`，取消 `⌘P` 后 Files 的原生键盘响应者没有恢复。修复 `86f8ff8` 的 Green：`/tmp/bailey-focus-audit-palette-git-files-green.log` 共 9 项/0 失败，`/tmp/bailey-focus-audit-palette-command-execute.log` 2 项/0 失败；覆盖 Files 方向键、Git 清洁图谱/有改动列表、Palette 取消和执行新命令不回抢旧树。现行 `NSWindow`/Dock 几何归属校验为防止后台窗口、停车终端和不同组交叉夺焦点的**实际必要条件**，不能为减少 guard 而删。最终跨套件复核另记，不使用历史 Go 代替新结果。

