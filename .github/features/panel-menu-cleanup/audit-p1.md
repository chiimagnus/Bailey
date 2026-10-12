# Audit P1 - panel-menu-cleanup

- 审计方式：`plan-task-auditor`
- 审计范围：`plan-p1.md`
- feature 目录：`.github/features/panel-menu-cleanup/`
- 粒度：`phase`

## 任务看板

- [x] P1-T1 删除 Control+数字快捷键
- [x] P1-T2 修复编辑与窗口菜单闪烁
- [x] P1-T3 统一面板名称
- [x] P1-T4 删除 Info 面板
- [x] P1-T5 项目根目录新建文件
- [x] P1-T6 菜单重新分组
- [x] P1-T7 统一加号创建分组并区分面板图标

## 任务到文件的映射

- P1-T1
  - `kero/App/keroApp.swift`：切标签动作仍在，Control数字绑定已删除。
- P1-T2
  - `kero/App/keroApp.swift`、`kero/Workspace/TerminalManager.swift`：保留原生菜单动态更新与当前窗口路由；用户确认无闪烁，没有猜测性修复。
- P1-T3
  - `kero/UI/WorkspaceDockView.swift`、`kero/UI/CommandPaletteView.swift`、`kero/Resources/Localization/`、`README.md`：名称和表名一致，不改存储键。
- P1-T4
  - `kero/Workspace/DockWorkspaceModel.swift`、`kero/Workspace/Project.swift`、`kero/UI/Panels/ToolPanelView.swift`、`scripts/check-session-snapshot.swift`：Info只保留解码兼容标记，旧引用过滤；共享SSH与隧道保持。
- P1-T5
  - `kero/Workspace/TerminalManager.swift`、`kero/Files/FileTreeModel.swift`、`kero/Files/FileTreePanel.swift`、本机/SSH后端、`scripts/check-workspace-identity.swift`：根目录创建、目标核对、空文件打开、目录/取消/同名与远端失败边界。
- P1-T6
  - `kero/App/keroApp.swift`、`kero/Workspace/Panes.swift`、`kero/Workspace/TerminalManager.swift`、`scripts/check-workspace-identity.swift`：原生分组、启用条件、文件/diff未保存状态发布、实际保存与窗口隔离。
- P1-T7
  - `kero/UI/WorkspaceDockView.swift`：三项创建连续，不依赖add-actions顺序；项目网格与文件夹图标不同。

## 发现项

## 发现 F-02

- 任务：`P1-T1`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Workspace/Project.swift:48`
- 摘要：`标签最近使用顺序注释仍宣称Ctrl-number可切换`
- 风险：`注释与已删除快捷键事实不符`
- 预期修复：`移除注释中旧快捷键示例`
- 验证：`Control数字键绑定和引用核对`
- 解决证据：`5f2aa18：快捷键与注释核对通过`


## 发现 F-01

- 任务：`P1-T5`
- 严重级别：`Low`
- 状态：`Resolved`
- 位置：`kero/Resources/Localization/Workspace.xcstrings:218`
- 摘要：`创建失败的旧专用文案已无调用方`
- 风险：`保留无效翻译，后续维护容易误认仍有该错误分支`
- 预期修复：`删除未引用的旧文案`
- 验证：`引用搜索与JSON校验`
- 解决证据：`5f2aa18：引用搜索/JSON/差异校验通过`


## 修复日志

- `5f2aa18` 修复两个Low文案遗留；不修改行为，按纯文案规范核对引用与JSON，不重复实机验收。

## 验证日志

- `bash scripts/check.sh workspace-identity dock-workspace` → PASS；文件和diff脏/干净变化发布到窗口、保存真实字节、浏览器禁用保存、项目面板移动/重开不重复。
- `bash scripts/check.sh pane-retention` → PASS；原生重挂载保留未保存文件、页面、表单、滚动和历史。
- `bash scripts/check.sh session-snapshot settings file-tree-navigation panel-targets remote-commands remote-lifetime` → PASS；旧Info迁移、创建空字节、同名/悬空链接/并发、异步切目标、受控远端失败与SSH生命周期。
- Debug `xcodebuild` 与 `codesign --verify --deep --strict` → PASS；`/tmp/kero-menu-dirty-build.log`。
- 隔离真机：文件菜单创建、显示菜单分屏/文件/Git面板、菜单保存后读取`menu-validation.txt`字节一致；设置和空窗口关闭不删除后台项目；多个窗口保留各自项目。
- 编辑与窗口菜单分别保持打开4秒，前后截图稳定；`/tmp/kero-menu-edit-after.png`、`/tmp/kero-menu-window-after.png`。中文完整操作通过；英文启动菜单分组与资源引用已核对，未重复完整交互。
- 用户手动确认新建文件与文件夹通过；用户确认正常速度最小化动画无异常，不修改平台慢放动画。
- `todo validate`、`phase-complete`、`rtk git diff --check` → PASS。

## Gate（是否允许进入下一阶段）

- 结论：`Go`
- 理由：已确认实现任务全部完成并原子提交；正常路径与真实失败边界验证通过，审计发现均已解决，没有未解决的正确性或数据完整性问题。

## 最终状态与剩余风险

- 当前状态：`Resolved`
- 剩余风险：真实SSH文件传输未测，只覆盖命令实际执行及受控后端；英文完整交互未重复。正式应用未安装或替换。预览、合集仍为讨论项，本阶段不实现。计划与审计仅留本地。

## 审计约束

- 本文件对应一个 phase，不对应单个 task
- 如果由 `executing-plans` 自动进入审计，也沿用同一模板

