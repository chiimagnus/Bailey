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
  - `Bailey/UI/WorkspaceDockView.swift.DockTabGroupView` 的 `isFocused/canFocusGroup` 与内描边；既有 Theme/TabItemChrome/TreeRowSurface 保持样式职责；`docs/ui.md`、`docs/features/dock.md`；提交 `eeb96f8`。
- P2-T2
  - `DockTabDragCoordinator.finish` → `DockWorkspaceModel.move/place/updateLayout`；`Project.selectTab`；`TerminalManager` 的 Palette 捕获/恢复/所有权检查；`CommandPaletteView.run`；`TerminalHostView` 的可见/停车宿主与 `TerminalFind/TerminalFindBar`。
  - `DockWorkspaceTests`、`PaneRetentionTests`、`WorkspaceWindowIsolationTests`；当前功能文档 `dock/terminal/command-palette/session-restore.md`；主体提交 `962abba`、审计根因修复 `9c95cc2`。像素测试夹具校正在独立提交 `5f12573`。

## 发现项

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

- 最终 Debug 完整 `make test`（含授权 Windows SSH）退出 0，579 passed、0 failed、0 skipped；最终 Release 相关 8 类为 119 passed、0 failed、0 skipped，均核对 xcresulttool。只有优化测试命令传 `SIGNING_FLAGS=ENABLE_TESTABILITY=YES`，随后普通构建恢复正式配置。日志和结果路径见 `evidence.md`。
- 模型穷举 3 工具 × 空组中央/四边；8 工作标签、6+ 横纵嵌套、无效 ID、关闭活动/后台 MRU、纯聚焦零快照；恢复新组 ID 后原编辑器身份不变。原生矩阵覆盖 2 外观 × 3 窗口尺寸 × 4 活动目标，Find 150/210/400/900 pt × 明暗。检查了源 Surface 真实父视图、回调清除时序、隐藏/停车/换项目/关闭后的所有权拒绝。
- 同源保存经过现有 FileTab/Diff 保存队列至最终磁盘，包括多个脏缓冲、失败/并发编辑/断线恢复；Ghostty 与 WebKit 身份、Undo、滚动和释放由原生测试核对。独立 App 已核对 Palette 取消/命令、工具输入不泄漏、真实拖放 Shell PID 不变、Unicode 字节与双主窗/Settings 快捷键；不是以事件派发充当 E2E。
- 最终窄 Find/空组独立 App 补验通过；通知横幅遮挡与输入焦点缺陷已区分。普通 `make build`、`make build:release` 及严格验签完整退出 0；Debug 全包原子安装、安装后签名及 SHA-256 核对通过，暂存备份清理完毕。正式 PID 48459 未退出/启动/重启，未推送/发布。
- 环境缺口逐项见 `evidence.md`：无 macOS 15.6 设备；Windows 不允许建立 symlink；无隔离图形登录的 VoiceOver 语音/长期五分屏专项；嵌入 WebKit 全网页 GUI E2E；真实 IME 候选交互和共享大字号设置。分别保留替代证据，不将其宣称为实测，最终 Gate 说明影响。
- 安装后追加 Release 独立 GUI 遇到自动化权限失效：Screen Recording/Accessibility/Event Synthesizing=false，System Events=-1743，不能把 AX 不可访问当产品无窗口。该追加项未完成；不冒充 Debug GUI/Release 原生测试的等价结果。未改隐私设置或重启正式 App，测试 PID 67650 已清理。权限恢复后补验，不阻塞已完成的签名 Debug App 验收；本 Gate 不是 Release 全 GUI 认证。
- 当前文档各有归属，未新增页面或失效导航。工具当前文件高亮仍使用工作上下文；Files 多选、行焦点样式与可编辑快捷键仍分别归 #5/#43，没有假称本功能已实现。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：本阶段代码、已发现根因、签名 Debug App 真实输入/拖放、两配置测试与构建/安装均完成；没有未解决的已证实缺陷。环境缺口已逐项保留，不将本机交付扩大为旧系统、任意用户设置、长期资源或 Release 全 GUI 的认证。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：上述逐项环境限制及安装后自动化权限补验；当前没有未解决的已证实生产缺陷。不承诺已证明不存在所有潜在 bug；发现项、真实副作用与未测边界都有证据可追溯。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板
