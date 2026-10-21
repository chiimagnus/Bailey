# Plan P1 — 应用与窗口职责

**目标：** 分离应用级生命周期与单窗口状态，消除领域对全局窗口登记的访问，再按职责修正命名。

**非目标：** 不集中焦点、不改变 UI/UX、快照格式、原生窗口 API 或后端算法。

**路径：** 沿现有 App／delegate 装配一个应用级所有者；窗口继续拥有项目。既有 SessionStore 和 TerminalHistoryStore 负责原有持久化，不新增 Registry／Router／Store 多层门面。

**验收：** 所有实际应用入口使用同一所有者；窗口间隔离，关闭保存与恢复结果不变；无 TerminalManager 兼容类或静态转发。P1 同样受 [UI/UX 零变化硬门槛](idea.md#uiux-零变化硬门槛) 与 [每任务放行条件](idea.md#每任务放行条件) 约束，不能因“不修改焦点策略”免做原生验收。当前仍是实施计划，不授权本轮修改产品代码。

<a id="p1-t1"></a>
## P1-T1 建立可重复的重构基线

### 源码入口

- `Bailey/App/{main,BaileyApp,FinderService}.swift`：SSH helper 分流、App／Scene／delegate、菜单与启动文件事件。
- `Bailey/Workspace/TerminalManager.swift`：init、requestSave、attach、外部文件排队／投递、windowClosed、saveBeforeTermination、restore。
- `Bailey/UI/Components/WindowChrome.swift`：原生附着、关闭否决及 SwiftUI delegate 转发。
- `BaileyTests/Integration/Workspace/SessionStoreTests.swift`、`BaileyTests/WorkspaceUI/Windows/`、`BaileyTests/NativeUI/Workspace/PaneRetentionTests.swift`。
- [本次源码审查](review-preflight.md)，不依赖其它 Feature 的历史 audit。

### 步骤与结果

1. 获准实施后重新核对 HEAD、未提交改动、规则、Makefile 和工具链。CodeGraph 使用 worktree 本地索引，覆盖不足再以当前源码／测试补证。
2. 检查环境、签名及数据／GUI 隔离条件，逐项登记 idea 的适用环境和缺口，不改用户设置或进程。
3. 运行已有基线；仅为缺失的必要行为补充现有 XCTest 目标中的特征测试。保留真实请求、挂载、保存和响应者前提，不将 XCTSkip 当作通过。
4. 核对新装配的关键问题：同一 Scene 身份重复生成 View 时，是否产生重复登记、提前消耗恢复快照或重复启动服务。用真实宿主和可计数登记／认领结果验证。当前 `@State` 初始化不能机械替换成带副作用的 `State(initialValue: ...)`；先查实际 SDK 和运行结果，不凭“@State 会保留对象”推导构造副作用只执行一次。
5. 按 idea 固定原始产品基线；在每个可安全执行的适用环境中配对记录几何／截图、完整动作录屏、真实输入和资源身份。工具树、Palette 三种结束分支、底栏分支 popover、空组、菜单／Sheet 和拖放均留证。确认旧版基线自身可重复，不允许从新实现反向生成旧基线。基线证据记录命令、完整退出码、环境／夹具、失败、跳过和逐项限制；按全部适用取值及组合展开，不能只保留默认外观的单张截图。

```sh
make doctor
make test:SessionStoreTests,WorkspaceWindowIsolationTests,WorkspaceWindowCloseTests,DockFocusP2RegressionTests,PaneRetentionTests DERIVED_DATA=build/DerivedData-workspace-refactor
```

### 准入与提交

本任务只建立当前证据，不要求在开始任何改动前完成所有实机／长期组合；不削减最终验收范围。受影响主路径的未解释失败先诊断，缺位条件按 idea 独立记录。初始化／认领若不能安全满足，就在 P1-T2 接入前解决，不增加通用生命周期状态机。

缺少某环境的基线不阻止其它已有可靠基线的独立工作，但不得宣布该环境验证完成；P1-T2 实际触及的主路径没有可比较原生基线时，不能先改后猜，也不能靠阶段末统一截图补救。

没有缺陷时不制造假 Red，也不为提交造产品代码。补充的必要测试与脱敏基线结果原子提交；本 Feature 文档按用户要求入库，不提交私人录屏或原始终端输出。

<a id="p1-t2"></a>
## P1-T2 分离应用级所有者并修正窗口命名

**依赖：** P1-T1 已解释受影响基线及装配前提。

### 真实修改点

| 位置 | 本任务结果 |
| --- | --- |
| `Bailey/Workspace/TerminalManager.swift` | 单窗口保留项目、选择、动作、单窗保存和快照构建；迁为 `WorkspaceWindowModel.swift` |
| `Bailey/App/{BaileyApp,FinderService}.swift` | delegate 持有一份应用级协作者，显式交给 WindowRootView、Commands 和 Settings；不经 NSApp.delegate 向下转型查询 |
| `Bailey/Remote/BaileySSHBridge.swift` | 保留认证和 socket 协议，仅替换 handle 中的全局会话定位依赖 |
| `Bailey/Terminal/TerminalNotificationService.swift` | 明确连接项目名查询／会话定位动作；保留原授权、主线程交付与隔离规则，不调用另一个全局窗口门面 |
| `Bailey/App/SettingsView.swift` | 重启前快照使用同一应用所有者；不改语言／重启行为 |
| `Bailey/Workspace/Project.swift` | 关闭确认从所属窗口取得呈现依赖，不再扫描全局 registry；syncFiles 不再接收整个窗口对象 |
| `Bailey/Git/{GitPanel,GitStatusModel}.swift` | 使用明确的 worktree 使用查询；syncSelectedProject 只接收项目及当前目标检查；ContentView 的刷新和 GitPanel 两处 Retry 一起迁移 |
| `Bailey/UI/` 中所有旧类型使用方 | ContentView／FinderWindowDrop、Dock、Palette、Projects／ToolPanel、TabSwitcher、focused value、菜单一次迁移 |
| `Bailey/App/AppSettings.swift` 及现行说明 | 该文件只有旧名注释而无运行依赖，更新引用，不改设置算法 |

### 实施顺序

1. **先守住应用级结果。** 用现有测试覆盖登记顺序、0／1／2+ 窗口、恢复认领、末窗重开、早到／延迟／混合文件请求、原窗口关闭／切项目／目标组消失。断言实际 FileTab、机器、磁盘和快照，不只检查队列变短。
2. **明确装配时机。** 应用协作者由现有 BaileyApplicationDelegate 持有，早于任何 WindowRootView 或外部文件消费。BaileyApp 从 adaptor 获取并显式传递同一对象；通知／SSH 定位回调在 GUI 启动装配处连接。main.swift 的 SSH passthrough 路径不创建应用工作区、读取窗口快照或启动 GUI 服务。测试显式构造应用所有者及恢复种子，并经同一装配入口连接自己的服务定位依赖；共享服务绑定随 fixture 恢复，不能让测试窗口属于一个 owner、实际 handoff 却查询测试宿主的另一个 owner。不要在每个 owner.init 中重绑全局服务，也不用隐藏默认单例补依赖。
3. **迁移真实状态。** 将 registry、待打开目录／文件、待认领恢复／历史、window opener、开窗合并状态、整体快照防抖和退出汇集放入应用所有者。复用现有 500ms 语义、当前快照格式和历史设置；窗口只提交快照变更及自身结果。P1-T1 证明的稳定窗口生命周期只登记和认领一次；不能把 IO／登记塞进重复求值的 View 初始化。
4. **连接领域依赖。** 新建、恢复及直接装配的项目走一致的所属窗口接入，不能只改 makeProject 而漏掉测试中的 projects 赋值／append。关闭呈现依赖读取届时真正附着的窗口，不能提前捕获 nil，也不能退回 keyWindow。保留未附着项目原有无窗口处理；不凭本任务另增窗口查找服务。Project.syncFiles 与 GitStatusModel.syncSelectedProject 的窗口选择检查缩为调用方提供的项目事实／闭包，保留 await 前后的项目、机器、连接和代次校验；Git 两处 Retry 必须使用届时的当前项目，而非旧闭包目标。
5. **完成所有使用方。** 系统打开、拖放、菜单、Settings、通知、认证 handoff 与 Git worktree 查询均接新入口。应用所有者提供动作／查询，不向业务层公开可遍历修改的窗口数组。worktree 使用判断先原样迁移并加混合机器特征测试；若证实原算法漏掉 SSH 项目中的本机标签，单独记录缺陷，不把修复悄悄混入纯重构。
6. **本任务删除旧路径。** 删除旧类／文件、应用级静态可变状态、activeManagers 公开登记、旧静态路由、每窗重复 willTerminate 订阅及旧名 alias。单一应用终止处理保留最后完整快照，单窗关闭仍幂等并先保存后销毁。纯快照转换 helper 可以保持 static；既有 SessionStore、通知和 SSH 服务不因静态形式而全盘重写。焦点策略暂原样保留在窗口侧，P2 再替换。

### 同任务删除与保留检查

- **删：** 旧应用级登记／路由／整体保存实现及其所有调用方，Project 的全局窗口扫描，两个领域 API 对整窗对象的反向依赖；不能只搬 extension 或留双注册。
- **留：** 关闭幂等、退出防覆盖、保存失败和新编辑否决、原生 delegate 转发、排队请求原目标、SSH 认证／端口／PID 校验、快照机器语义。
- 每项删除附对应替代入口和最终结果证据；没有证据的“多余检查”不批量清扫。旧关闭宿主不能清掉新窗口装配或复活已关闭目标。

### 验证

直接引用旧类型的 20 个测试类都要迁移并运行，不能仅验证会话恢复和窗口类。下列两组包含这 20 类及相邻应用／远端生命周期边界：

```sh
make test:SessionStoreTests,PanelContextTests,WorkspaceIdentityTests,FileTabTests,PaneRetentionTests,DockWorkspaceTests,WorkspaceContentIdentityTests,DockFocusP2RegressionTests,WorkspaceWindowCloseTests,WorkspaceWindowIsolationTests,AppMenuIsolationTests,AppIdentityTests,RemoteLifetimeTests DERIVED_DATA=build/DerivedData-workspace-refactor
make test:GitStatusModelTests,GitCommitDialogTests,GitExternalRefreshTests,GitHistoryFileTests,GitInteractiveRebaseTests,GitRefReplacementTests,GitRemoteBranchDialogTests,GitStashDialogTests,GitTagDialogTests,GitWorkspaceMenuTests DERIVED_DATA=build/DerivedData-workspace-refactor
make build DERIVED_DATA=build/DerivedData-workspace-refactor
```

新补类同时加入选择集合。重新枚举改动后的实际调用方，不以固定清单封顶。按 idea 尽可能执行所有应用／窗口／保存／连接条件及组合；核对完整 make 退出码与签名。新增多窗口 fixture 必须共享同一应用所有者，另测独立所有者不共享登记。保存完成后再次核对所有窗口的新编辑；最后窗口快照在重复关闭和退出回调后仍完整。

RemoteLifetimeTests 当前 private socket 用例使用自定义 handler，只证明 worker→main actor 的请求／响应，不证明 BaileySSHService.handle 的认证、会话定位或 Project 的真实连接交付。补充受控 socket→真实服务→所属 Session 的回归，覆盖有效／失效 token、已关闭 session、不同窗口／owner；不连接真实主机。GitInteractiveRebaseTests 的获准 SSH 用例另外检查独立 helper 握手后真正进入序列编辑器，不能被上述低层回归代替。通知的标题查询与点击定位也使用同一个 fixture owner；不为验证路由向真实设备发送通知。

Finder、通知点击、SSH handoff、菜单和语言重启分别按安全条件补系统入口 E2E；不启动或结束用户 App、SSH master、Bark 请求或真实任务。没有实际投递的分支明确记为进程内验证，不冒充端到端。

**P1-T2 零变化放行：** 按 idea 的 [组合覆盖与根因证明](idea.md#组合覆盖与根因证明) 和 [每任务放行条件](idea.md#每任务放行条件) 核销本任务全部可执行条件。原窗口外壳、初始／恢复布局、菜单顺序与启用条件、工具栏、弹窗默认值／归属、文件打开／错误／关闭恢复流程须与原始基线及上一验收点一致；覆盖创建、切换、失活、原生附着前后和末窗重开，而不只核对静止界面。逐条检查同一应用所有者覆盖所有真实入口、原静态路径已删除、保存和 Shell／文档身份未变。任一未解释 UI/UX 差异或主路径缺证阻塞本任务验收，不交给 P2 修。

### 文档与原子提交

同任务更新 AGENTS 的当前窗口所有者、docs/architecture.md，以及实际受影响的 docs/features/{dock,session-restore,projects,terminal,ssh,settings,editor}.md、docs/testing.md 和现行源码引用；未变契约不重写。保留历史记录当时的名称。

通读 diff、核对旧名运行引用已消失和 `git diff --check`。中文原子提交代码、测试、所属文档及用户要求入库的 Feature 计划／脱敏证据；feature_tool 单独回写真实 todo 状态与提交，不预填完成。验证后的安装遵守现有文档，不重启用户 App。

## 阶段审计

实施结束后由 executing-plans 进入 plan-task-auditor，再创建 audit-p1.md；按 idea 的硬门槛独立核对原始基线、真实输入／最终副作用、完整适用条件及每条删除证据，不能仅看名字消失或 XCTest 绿色。未解释 UI/UX 差异、漏掉可安全执行条件或主路径证据缺失时不给 Gate；P1 Gate 通过再进 P2。本轮不创建实施完成审计。
