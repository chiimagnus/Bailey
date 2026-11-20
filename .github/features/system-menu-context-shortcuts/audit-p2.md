# P2｜阶段审查

审查对象：[P2 实施计划](plan-p2.md)。
实时任务状态以 `todo.toml` 为准。

## 结论

- **结果**：按修订后的需求范围完成；不等于全量平台／GUI 验收通过。
- **依据**：应用级命令已按原生菜单分发；Files 右键 Edit 是局部菜单动作，
  原本要求它额外触发顶部 Edit 高亮属于多余验收条件。
  保留正确的文件副作用、独立焦点及选区，不为视觉效果新增第二条命令路径。
  已有全量测试失败与未覆盖环境仍如实记录于下文。

## 任务与改动

- **P2-T1 系统菜单命令执行与反馈**：`43cf933c`。检查了 `BaileyApplicationDelegate`
  的实际 AppKit 跟踪通知、`MainMenuPresentation` 的原按键重投及 `BaileyCommands`
  的实际命令。没有新增快捷键注册；Dock 的保存／取消和业务关闭链未改。
- **P2-T2 Files 局部编辑**：重新核对 `FileTreePanel`／`ContextMenuClickView` 到
  `WorkspaceWindowModel.performFileTreeCommand` 的局部动作链，确认右键只设置临时目标；
  终端保有第一响应者时，文件菜单的 Copy 仍写入文件传输剪贴板。
  用户确认顶部 Edit 高亮不属于此类局部动作的要求，因此不改 Swift 代码。
- **P2-T3 临时目标**：`09f9d6b2`，检查 Dock、Files、Git Changes、Git Graph 的菜单结束及业务读目标路径。
  应用层按真实菜单、实际命令和单次事件决定何时释放；各业务仍拥有自己的目标。
  目录新建在异步前取得目录与工作范围；不再按快捷键字符推测是否保留目标。

## 发现项

## 发现 F-05

- 任务：`P2-T7`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Shared/Tree/TreeRowStyle.swift:24`
- 摘要：`构建明确警告闭包环境值可能使共享树依赖在每次更新时重复失效`
- 风险：`逐行重算与桥接更新；尚无实测耗时数据`
- 预期修复：`改用现有 Observable 菜单对象，不增加转发／新的状态所有者`
- 验证：`验证警告消失并复跑实际 Native 菜单与树目标回归`
- 解决证据：`7d053e88：直接注入现有 @Observable MainMenuPresentation 并移除环境闭包及转发字段；build/context-shortcuts-t7-review-build-ui.log 退出 0，原环境闭包警告消失；build/context-shortcuts-t7-review-host.log 176/176；build/context-shortcuts-t7-review-ui.log 4/4，退出 0。`


## 发现 F-04

- 任务：`P2-T6`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`BaileyUITests/Git/GitGraphUITests.swift:97`
- 摘要：`禁用 Finder 动作拿剪贴板作证，Diff 重复一次相同键与判据，P2 复制 P1 矩阵`
- 风险：`耗时增加且不能增加有效验收证据`
- 预期修复：`保留真实文案、切换、焦点／选区恢复与 Git 副作用；复用既有验收矩阵`
- 验证：`复跑 Graph 路径和 Diff 三个真实入口；校验 plan 和 todo`
- 解决证据：`b8cfd21f；build/context-shortcuts-slim-t6.gui.log：5/5；P2 验收引用原矩阵及需求。`


## 发现 F-03

- 任务：`P2-T5`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/Workspace/WorkspaceWindowModel.swift:731`
- 摘要：`文件新建同步接令重新读同一面板身份和同一树资格`
- 风险：`重复取证且容易误认为是异步安全边界`
- 预期修复：`首次接令读取一次目标，明确保留异步执行前后重新取证`
- 验证：`PanelContextTests 与真实右键新建的文件字节及目录`
- 解决证据：`3bcb3576；build/context-shortcuts-slim-t5-host.log、build/context-shortcuts-slim-t5.gui.log。`


## 发现 F-02

- 任务：`P2-T4`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`Bailey/App/BaileyApp.swift:156`
- 摘要：`同一次菜单跟踪的状态分散在多个可选字段，菜单结束接口暴露无须返回的分流信号`
- 风险：`清理需同步多个独立字段，容易引入不一致`
- 预期修复：`用一个记录持有同一次菜单跟踪，按原时点清理；统一重投资格谓词`
- 验证：`Bailey Dev 定点原生菜单与实际副作用回归`
- 解决证据：`4f6260ab；build/context-shortcuts-slim-t4.gui.log：10/10，原生首次高亮见同名 MP4，File 26.367 s、Panel 172.283 s。`


## 发现 F-01

- 任务：`P2-T2`
- 严重级别：`High`
- 状态：`Resolved`
- 位置：`Bailey/Files/FileTreePanel.swift:541`
- 摘要：`原计划将 Files 局部 Edit 缺少顶部 Edit 高亮误列为缺陷；该验收条件已取消。`
- 风险：`强制改走系统 Edit 菜单会改变既有文件动作与第一响应者语义。`
- 预期修复：`只保留本次右键菜单已有的文件动作；取消额外高亮目标，不新增分发代码。`
- 验证：`既有 SharedTreeUITests 通过文件剪贴板类型、内容、选区及终端后续输入验证 Copy；其它编辑行为沿用原有文件操作路径，未为本次文档收敛新增 GUI 验证。`
- 解决证据：`2026-11-20 需求复核：Files 右键局部编辑无需顶部 Edit 闪亮；保持既有菜单动作、焦点和选区。历史 Copy GUI 与 AppKit 事件证据见 audit-p1.md；无 Swift 变更。`

## 后续修复：Files 局部编辑提示音

旧版 `.badge` 不生成 `NSMenuItem.keyEquivalent`；手工执行了文件菜单动作，
系统仍可能发出未处理按键提示音。改为本次右键菜单原生 `.keyboardShortcut`，
并删除旧 `NSEvent` 局部监听与重复键位表，不改变文件动作、右键目标或原焦点。
用户实测修改版 `⌘C` 不再发声。

本轮 `make build:ui` 成功；宿主 176/176 通过；隔离 Dev GUI 中右键 Copy、
Cut→Paste→Delete、Escape 恢复选区、Dock `⌘W` 共 5 项通过。
第 6 项普通 Edit GUI 在第一次运行中被中断，单独重测后通过；合计 6/6。
自动化未录制系统音频；无提示音的直接证据为用户对实验版 `⌘C` 的实测。
旧的 Edit 菜单委托／重投实验仍未采用。

## 验证与未覆盖

- T1 `build:ui` 退出 0，Dev 和 Runner 严格验签通过；`AppIdentityTests,DockWorkspaceTests`
  57/57，宿主及 Dev 验签通过。两轮完整 Dev GUI 8/8、2/2 均退出 0，
  包含真实 Git HEAD/index、Diff 文本、文件创建／保存、取消、Control-Click、
  原生切换预览、Shell 标记和第二个窗口。日志及录屏为 `build/context-shortcuts-p2-t1*`。
- `context-shortcuts-p2-t1.mp4` 中，首次 File 闪亮包括 Stage All（93.133 s）、
  New File（124.817 s）、New Folder（130.083 s）、右键 Copy Path（205.400 s）；
  右键 Close Panel 仍在 191.883 s 原生闪亮，然后普通 Close 在 193.267 s 闪亮。
- T2 曾试验更改 Edit 项的显式 target 与重投按键：出现过顶部 Edit 高亮，
  但文件复制副作用不正确。两种方案均已撤回，不作为已实现功能。
  原始诊断证据保留在 `build/context-shortcuts-p2-t2*`。
- T2 相关失败候选的诊断和完整差异仍保存在
  `build/context-shortcuts-p2-t2-unverified.patch`；当前 Swift 代码无这些实验改动。
  右键只设置文件目标，不改变原第一响应者或选区，菜单局部 Copy 已有真实 GUI 副作用证据。
  未单独完成本机／SSH、快速连发与剪切／粘贴／删除全部场景的本轮验收。
- `make test:ui` 曾因 Automation Mode 要求重新认证发现 0 项并退出 2；
  用户重新确认授权后，聚焦复制用例确实运行并复现上述问题；认证不是 T2 的剩余阻塞。
- T3 定点宿主 76/76，新增用例确实将 0 字节文件写入被接受的目录，
  并核对项目切换后没有目标草稿或额外文件。13 项真实 GUI 第一轮 12/13：
  Git 压缩目录用例误命中含系统和弹出菜单的全局 AX 查询；
  限定窗口并使用实际坐标后，`context-shortcuts-p2-t3-final-gui.log` 的 4/4 通过、退出 0。
  包含历史／未提交工作树各目录段的相对路径快捷键及绝对路径鼠标动作，
  同时核对磁盘、Git index 和 HEAD；重跑 Stage All、Commit Staged 和 Diff。
  T3 原生录像确认右键及下一次普通 Close 的 Panel 脉冲（248.550 s、249.983 s）。
- 全量 `make test` 发现 1,112 项，18 项真实 SSH 用例跳过，退出 2；
  `GitPanelVisibilityTests.testDenseGraphSurvivesThemeFontModeAndViewportMatrix`
  在 120pt Graph 的 AXPress 及 1,026 项暂存后的展开共两条断言失败。
  该用例走直接 AXPress 而非右键菜单，未改它或宣称已归因。
- 最终 `make build` 与 `make build:ui` 都退出 0，正式 Debug 构建产物没有安装。
  UI 构建替换 Dev 包，需分别核对实际构建的包：先对 Debug、Dev 和 UI Runner 严格验签；
  再跑已提交版本定点宿主，76/76、退出 0，Dev 与宿主测试包严格验签通过。
- 未跑完整 GUI Target：Files 局部 Edit 改用当前弹出菜单的原生快捷键；
  旧的顶部 Edit 高亮用例不再构成阻塞，也不等于其它场景全部通过。
  录屏和副作用只覆盖已执行的定点场景；完整按键排列、极短间隔连发、
  右键期间的系统 Sheet 与真实保存失败确认仍未全面验收。
- 最低系统 macOS 15.6 无可用环境，真实 SSH 无授权主机／临时根路径，真实中文 IME 未复测。
  本机 27.3 视频、宿主 IME 组件与隔离身份测试不能替代这些验收；不能据此宣称全范围完成。
