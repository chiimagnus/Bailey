# P1：已确认的面板与菜单改动

**Goal:** 逐问题修复快捷键、面板入口与菜单行为。
**Non-goals:** 不实现预览或合集，不改终端内核，不引入测试框架。
**Approach:** 每项先追真实调用与持久化边界，再最小实现、签名构建、隔离真机验证、原子提交。菜单闪烁的根因由实际复现与原生菜单观察确定，不预设为 SwiftUI 重建。
**Acceptance:** 下列六个独立结果成立，文案/文档一致，项目和未保存内容保留。
**Rules:** 正式 Kero 不退出；仅替换本任务的隔离测试应用。复用 Dock/Pane、文件创建与后端；计划不提交。

## P1-T1 删除 Control+数字快捷键

**Files:** kero/App/keroApp.swift 的 KeroCommands 标签切换菜单。
保留切换菜单动作，只删除 Control+1…9 绑定；不改变 Command+数字或 Control+Tab。
验证签名 Debug 的原生菜单键绑定与真实按键，确认没有切换且常用切换仍可用，然后提交。

## P1-T2 修复编辑与窗口菜单闪烁

**Files:** kero/App/keroApp.swift 的 WindowRootView/KeroCommands、Workspace/TerminalManager.swift 的项目观察和窗口 opener；必要时补现有 standalone App 菜单检查。
先在隔离实例打开两类菜单并观察菜单/窗口生命周期；追踪 FocusedObject 发布、Commands 重建、窗口标题与 AppKit 菜单更新。只在实际拥有失效不变量的位置修复，验证动态启用与跨窗口路由仍正确，不能用永久冻结菜单绕过。
最小可运行回归检查覆盖无关状态更新与真正的命令状态变化；实际菜单稳定后提交。

## P1-T3 统一面板名称

**Files:** UI/WorkspaceDockView.swift 的 DockItem.label 与新增菜单、App/keroApp.swift、UI/CommandPaletteView.swift、Resources/Localization/*.xcstrings，以及 README 与相关维护约束。
文件管理器与 Git 管理器在面板入口一致；项目、浏览器、终端与编辑器的对象名称不混用。不重命名配置键或用户文件。验证英语/中文菜单、标签与命令面板后提交。

## P1-T4 删除 Info 面板

**Files:** Workspace/DockWorkspaceModel.swift、Project.swift、UI/WorkspaceDockView.swift、UI/Panels/ToolPanelView.swift、App/keroApp.swift、UI/CommandPaletteView.swift、Info/、相关字符串、配置/快照与 panel-targets 检查。
先追 Info 的数据与转发调用，删除仅属于 Info 的 owner/操作；保留其他调用方的后端、连接与长期隧道。移除 Dock/配置/菜单入口。旧 Info 引用仅过滤该项，不丢整个项目、其他面板或编辑内容。
运行 dock-workspace、session-snapshot、settings、panel-targets 与远端生命周期检查；补旧 Info 配置/快照回归，真实 UI 不再有入口，剩余面板可操作后提交。

## P1-T5 项目根目录新建文件与文件夹

**Files:** Workspace/TerminalManager.swift、Files/FileTreeModel.swift/Panel、App/keroApp.swift、UI/CommandPaletteView.swift、相关字符串与文件/机器身份检查。
复用 FileTreeModel.beginNewFile/beginNewFolder/commitDraft 与 WorkspaceBackend；文件菜单、命令面板和每个标签栏的「＋」提供两个入口，新建文件为⌘N，新建文件夹为⌥⌘N。入口捕获当前项目和工作范围，默认项目根，不取当前文件父目录。必要时显示文件管理器并等待正确树目标，文件成功后在原项目打开；切换目标、取消、同名或失败不产生错误写入。
真实临时目录和受控远端检查最终字节、打开目标、同名保留、取消及切项目，隔离菜单/快捷键操作验证后提交。

## P1-T6 菜单重新分组

**Files:** App/keroApp.swift、UI/CommandPaletteView.swift、Resources/Localization/Interface.xcstrings、README 与维护约束。
文件菜单放创建、项目添加、保存与关闭；编辑菜单保持编辑/查找；视图菜单放面板与布局，浏览器菜单保持导航，窗口菜单保留系统窗口操作。已删除 Info 和 Control+数字不重新出现，不注册尚未实现预览。
验证每个新分组的实际动作与启用条件、Settings/空窗口和多窗口路由，并复测编辑/窗口菜单稳定后提交。

## Phase Audit

## P1-T7 统一加号创建分组并区分面板图标

每个加号中，新建文件、新建文件夹与新建终端连在一起，不用分隔线；即使 add-actions 自定义顺序也保持三项相邻。项目面板改用网格图标，文件管理器保留文件夹，不改变项目列表中的目录图标。构建、签名与隔离界面观察后独立提交。

全部任务验证并提交后进入 plan-task-auditor，逐项检查最终结果及测试证据。讨论项不作为待实现任务。
